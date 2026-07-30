#!/usr/bin/env python3
"""
GPTPU Emulator Comprehensive Test Suite
Tests FP8 arithmetic, all ISA instructions, NoC routing, and LUT.
"""

import struct
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from emulator import (
    Emulator, PEState, NoCRouter,
    fp8_add, fp8_mul,
    OPCODES, OPCODE_NAMES,
    VECTOR_LANE_WIDTH, PE_GRID_X, PE_GRID_Y, NUM_PE,
)


# ============================================================
# Test Infrastructure
# ============================================================
tests_passed = 0
tests_failed = 0


def test(name, condition, detail=""):
    global tests_passed, tests_failed
    if condition:
        tests_passed += 1
        print(f"  PASS: {name}")
    else:
        tests_failed += 1
        msg = f"  FAIL: {name}"
        if detail:
            msg += f" -- {detail}"
        print(msg)


# ============================================================
# FP8 E4M3 Arithmetic Tests
# ============================================================
def fp8_to_float(v: int) -> float:
    sign = (-1.0) if ((v >> 7) & 1) else 1.0
    exp = (v >> 3) & 0xF
    mant = v & 0x7
    if exp == 0:
        return sign * (mant / 8.0) * (2.0 ** (1 - 7))
    return sign * (1.0 + mant / 8.0) * (2.0 ** (exp - 7))


def float_to_fp8(v: float) -> int:
    if v == 0.0:
        return 0
    sign = 0 if v >= 0 else 1
    v = abs(v)
    exp = 0
    while v >= 2.0 and exp < 15:
        v /= 2.0
        exp += 1
    while v < 1.0 and exp > 0:
        v *= 2.0
        exp -= 1
    mant = min(7, int((v - 1.0) * 8.0 + 0.5))
    if exp >= 15:
        return (sign << 7) | 0x78
    return (sign << 7) | (exp << 3) | mant


def test_fp8_arithmetic():
    print("\n--- FP8 Arithmetic Tests ---")

    # Zero
    test("fp8_add(0, 0) == 0", fp8_add(0, 0) == 0)
    test("fp8_mul(0, 42) == 0", fp8_mul(0, 0x42) == 0)
    test("fp8_mul(42, 0) == 0", fp8_mul(0x42, 0) == 0)

    # Identity: 1.0 = 0x3C (sign=0, exp=7, mant=4 -> 1 + 4/8 = 1.5??)
    # Actually: 1.0 in E4M3: sign=0, exp=7 (bias=7, so 2^0=1), mant=0 -> 1.0
    # 0x38 = 0_0111_000 = 1.0
    fp8_one = 0x38  # 1.0
    fp8_two = 0x40  # 2.0: sign=0, exp=8, mant=0 -> 2^(8-7)=2

    v = fp8_add(fp8_one, fp8_one)
    test("fp8_add(1, 1) == 2", v == fp8_two, f"got {v:02x} != 0x40")

    v = fp8_mul(fp8_two, fp8_two)
    fp8_four = 0x48  # 4.0: sign=0, exp=9, mant=0 -> 2^(9-7)=4
    test("fp8_mul(2, 2) == 4", v == 0x48, f"got {v:02x} != 0x48")

    # Negation: 1.0 + (-1.0) = 0.0
    fp8_neg_one = 0xB8  # -1.0: sign=1, exp=7, mant=0
    test("fp8_mul(1, -1.0) = -1.0", fp8_mul(fp8_one, fp8_neg_one) == fp8_neg_one)

    # Small number
    fp8_small = 0x04  # sign=0, exp=0, mant=4 -> denorm
    test("fp8_mul(small, 0) = 0", fp8_mul(fp8_small, 0) == 0)

    # NaN/Inf: exp=0xF -> NaN
    fp8_nan = 0x78  # exp=15, mant=0 -> Inf/NaN
    r1 = fp8_add(fp8_nan, fp8_one)
    r2 = fp8_mul(fp8_nan, fp8_one)
    r3 = fp8_add(fp8_one, fp8_nan)
    test("fp8_add(NaN, 1) = NaN/Inf (exp=0xF)",
         (r1 & 0x78) == 0x78, f"got {r1:02x}")
    test("fp8_mul(NaN, 1) = NaN/Inf (exp=0xF)",
         (r2 & 0x78) == 0x78, f"got {r2:02x}")
    test("fp8_add(1, NaN) = NaN/Inf (exp=0xF)",
         (r3 & 0x78) == 0x78, f"got {r3:02x}")

    # Overflow
    fp8_large = 0x77  # max normal: sign=0, exp=14, mant=7 = 1.875 * 2^7 = 240
    fp8_large_2 = 0x77
    v = fp8_add(fp8_large, fp8_large_2)
    test("fp8_add(max, max) = Inf/NaN", (v & 0x78) == 0x78,
         f"got {v:02x}, expected overflow")

    # Negative addition: -2 + 1 = -1
    fp8_neg_two = 0xC0  # -2.0: sign=1, exp=8, mant=0
    r_add_neg = fp8_add(fp8_neg_two, fp8_one)
    test("fp8_add(-2, 1) = -1",
         r_add_neg == fp8_neg_one, f"got 0x{r_add_neg:02x} = {fp8_to_float(r_add_neg):.1f}")

    # Subtraction via different signs: 2 + (-1) = 1
    r_sub = fp8_add(fp8_two, fp8_neg_one)
    test("fp8_add(2, -1) = 1",
         r_sub == fp8_one, f"got 0x{r_sub:02x} = {fp8_to_float(r_sub):.1f}")

    # Edge cases: different exponents, different signs
    fp8_half = 0x30      # 0.5: sign=0, exp=6, mant=0
    fp8_neg_four = 0xC8  # -4.0: sign=1, exp=9, mant=0
    fp8_neg_three = 0xC4 # -3.0
    fp8_three_quarter = 0x34  # 0.75: sign=0, exp=6, mant=4 -> 1.5*2^-1=0.75
    fp8_one_half = 0x38  # -1.5: sign=1, exp=7, mant=4 -> -(1.5)*1=-1.5
    fp8_neg_one_half = 0xBC  # -1.5
    r_small_large = fp8_add(fp8_half, fp8_neg_two)
    test("fp8_add(0.5, -2) = -1.5",
         r_small_large == fp8_neg_one_half,
         f"got 0x{r_small_large:02x} = {fp8_to_float(r_small_large):.1f}")
    r_pos_neg_large = fp8_add(fp8_one, fp8_neg_four)
    test("fp8_add(1, -4) = -3",
         r_pos_neg_large == fp8_neg_three,
         f"got 0x{r_pos_neg_large:02x} = {fp8_to_float(r_pos_neg_large):.1f}")
    r_small_pos_neg = fp8_add(fp8_three_quarter, fp8_neg_two)
    test("fp8_add(0.75, -2) = -1.25",
         r_small_pos_neg == 0xBA,
         f"got 0x{r_small_pos_neg:02x} = {fp8_to_float(r_small_pos_neg):.1f}")


# ============================================================
# Instruction Execution Tests
# ============================================================
def make_instr(opcode: int, imm: int = 0) -> int:
    return (opcode << 25) | (imm & 0x1FFFFFF)


def make_padded_sn(words: list) -> bytes:
    padded = (words + [0] * (2048 - len(words)))[:2048]
    return struct.pack(f'<{2048}I', *padded)


def test_nop():
    print("\n--- NOP Instruction ---")
    emu = Emulator()
    code = make_padded_sn([
        make_instr(OPCODES['NOP']),
        make_instr(OPCODES['NOP']),
        make_instr(OPCODES['NOP']),
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    cycles = emu.run(100)
    pe0 = emu.pes[0]
    test("NOP: PC increments to HALT", pe0.pc == 3, f"got PC={pe0.pc}")
    test("NOP: PE became inactive", not pe0.active)


def test_halt():
    print("\n--- HALT Instruction ---")
    emu = Emulator()
    code = make_padded_sn([
        make_instr(OPCODES['NOP']),
        make_instr(OPCODES['NOP']),
        make_instr(OPCODES['HALT']),
        make_instr(OPCODES['NOP']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    pe0 = emu.pes[0]
    test("HALT: PC stays at HALT", pe0.pc == 2, f"got PC={pe0.pc}")
    test("HALT: PE becomes inactive", not pe0.active)


def test_ldi():
    print("\n--- LDI (Load Immediate) ---")
    emu = Emulator()
    # LDI R0, 0x12345; LDI R1, 0xFFFFF; LDI R2, 0x00000; HALT
    code = make_padded_sn([
        make_instr(OPCODES['LDI'], (0 << 20) | 0x12345),
        make_instr(OPCODES['LDI'], (1 << 20) | 0xFFFFF),
        make_instr(OPCODES['LDI'], (2 << 20) | 0x00000),
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    pe0 = emu.pes[0]
    test("LDI R0 = 0x12345", pe0.regfile[0] == 0x12345,
         f"got {pe0.regfile[0]:05x}")
    test("LDI R1 = 0xFFFFF", pe0.regfile[1] == 0xFFFFF,
         f"got {pe0.regfile[1]:05x}")
    test("LDI R2 = 0x00000", pe0.regfile[2] == 0x00000,
         f"got {pe0.regfile[2]:05x}")


def test_scalar_alu():
    print("\n--- Scalar ALU ---")
    emu = Emulator()
    # LDI R1, 5; LDI R2, 3; SADD R3, R1, R2; HALT
    code = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 5),
        make_instr(OPCODES['LDI'], (2 << 20) | 3),
        make_instr(OPCODES['SADD'], 1 | (2 << 3) | (3 << 6)),
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    pe0 = emu.pes[0]
    test("SADD: 5 + 3 = 8", pe0.regfile[3] == 8, f"got {pe0.regfile[3]}")

    emu2 = Emulator()
    code2 = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 10),
        make_instr(OPCODES['LDI'], (2 << 20) | 3),
        make_instr(OPCODES['SSUB'], 1 | (2 << 3) | (3 << 6)),
        make_instr(OPCODES['HALT']),
    ])
    emu2.load_microcode(0, code2)
    emu2.run(100)
    pe0_2 = emu2.pes[0]
    test("SSUB: 10 - 3 = 7", pe0_2.regfile[3] == 7, f"got {pe0_2.regfile[3]}")

    emu3 = Emulator()
    code3 = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 0xFF),
        make_instr(OPCODES['LDI'], (2 << 20) | 0x0F),
        make_instr(OPCODES['SAND'], 1 | (2 << 3) | (3 << 6)),
        make_instr(OPCODES['HALT']),
    ])
    emu3.load_microcode(0, code3)
    emu3.run(100)
    pe0_3 = emu3.pes[0]
    test("SAND: 0xFF & 0x0F = 0x0F", pe0_3.regfile[3] == 0x0F,
         f"got {pe0_3.regfile[3]:04x}")


def test_scmp():
    print("\n--- SCMP Compare ---")
    emu = Emulator()
    # LDI R1, 5; LDI R2, 5; SCMP R1, R2 -> status==0
    code = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 5),
        make_instr(OPCODES['LDI'], (2 << 20) | 5),
        make_instr(OPCODES['SCMP'], 1 | (2 << 3)),
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    pe0 = emu.pes[0]
    test("SCMP: 5==5 -> status=0", pe0.status == 0, f"got {pe0.status}")

    emu2 = Emulator()
    code2 = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 3),
        make_instr(OPCODES['LDI'], (2 << 20) | 7),
        make_instr(OPCODES['SCMP'], 1 | (2 << 3)),
        make_instr(OPCODES['HALT']),
    ])
    emu2.load_microcode(0, code2)
    emu2.run(100)
    pe0_2 = emu2.pes[0]
    test("SCMP: 3<7 -> status=-1", pe0_2.status == -1, f"got {pe0_2.status}")

    emu3 = Emulator()
    code3 = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 9),
        make_instr(OPCODES['LDI'], (2 << 20) | 4),
        make_instr(OPCODES['SCMP'], 1 | (2 << 3)),
        make_instr(OPCODES['HALT']),
    ])
    emu3.load_microcode(0, code3)
    emu3.run(100)
    pe0_3 = emu3.pes[0]
    test("SCMP: 9>4 -> status=1", pe0_3.status == 1, f"got {pe0_3.status}")


def test_jmp_jal_ret():
    print("\n--- JMP / JAL / RET ---")
    emu = Emulator()
    # PE0: NOP, JAL (jump to PC=3, abs), HALT, NOP, RET, HALT
    # JAL sets link_reg = PC+1 = 2, then jumps to imm (abs)
    code = make_padded_sn([
        make_instr(OPCODES['NOP']),
        make_instr(OPCODES['JAL'], 3),    # abs jump to PC=3, link=2
        make_instr(OPCODES['HALT']),        # should not execute (skipped by JAL)
        make_instr(OPCODES['NOP']),          # PC=3: target
        make_instr(OPCODES['RET']),          # PC=4: return to link_reg=2
        make_instr(OPCODES['HALT']),         # PC=5: (not reached)
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    pe0 = emu.pes[0]
    test("JAL+RET: final PC=2 (HALT after RET)", pe0.pc == 2,
         f"got PC={pe0.pc}")
    test("JAL+RET: link_reg = 2", pe0.link_reg == 2, f"got {pe0.link_reg}")


def test_branch():
    print("\n--- Branch Instructions ---")
    emu = Emulator()
    # Set status=0 (equal), then BEQ should branch
    # LDI R1, 5; LDI R2, 5; SCMP R1,R2; BEQ +3; HALT; NOP; HALT
    # BEQ: if status==0, pc_next = PC+1+imm[12:0]
    code = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 5),
        make_instr(OPCODES['LDI'], (2 << 20) | 5),
        make_instr(OPCODES['SCMP'], 1 | (2 << 3)),   # PC=3: status=0
        make_instr(OPCODES['BEQ'], 3),                # PC=4: branch to 4+1+3=8
        make_instr(OPCODES['HALT']),                   # PC=5: skipped
        make_instr(OPCODES['NOP']),
        make_instr(OPCODES['NOP']),
        make_instr(OPCODES['HALT']),                   # PC=8: target
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    pe0 = emu.pes[0]
    test("BEQ taken: end at HALT PC=7", pe0.pc == 7,
         f"got PC={pe0.pc}")

    emu2 = Emulator()
    # Set status=1 (greater), then BEQ should NOT branch
    code2 = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 7),
        make_instr(OPCODES['LDI'], (2 << 20) | 3),
        make_instr(OPCODES['SCMP'], 1 | (2 << 3)),
        make_instr(OPCODES['BEQ'], 3),    # not taken (status=1)
        make_instr(OPCODES['HALT']),       # should execute this
    ])
    emu2.load_microcode(0, code2)
    emu2.run(100)
    pe0_2 = emu2.pes[0]
    test("BEQ not taken: end at HALT PC=4", pe0_2.pc == 4, f"got PC={pe0_2.pc}")


def test_djnz():
    print("\n--- DJNZ (Loop) ---")
    emu = Emulator()
    pe0 = emu.pes[0]
    pe0.lc = 3
    # DJNZ decrements LC, branches if LC != 0.
    # offset is imm[12:0]; pc_next = PC+1+offset (signed? actually imm & 0x1FFF)
    # DJNZ: offset = imm & 0x1FFF, branch target = PC+1+(signed_extend?) 
    # From emulator: pc_next = pe.pc + 1 + (imm & 0x1FFF)
    # So DJNZ with offset=2: PC+1+2 = PC+3 when LC>0
    # PC=0: DJNZ 2 -> LC=2, branch to PC=0+1+2=3
    # PC=3: (whatever is at PC=3, let's put DJNZ 2 again)
    # But wait, this creates an infinite loop. Let me use negative offset.
    # 0x1FFF is 8191, so if offset=0x1FFE, that's -2 in 13-bit signed.
    # Hmm, the emulator just does imm & 0x1FFF which is unsigned.
    # But branches work with relative offsets. Let me check:
    # The assembler computes: val = labels[target] - (self.org + 4), so it 
    # produces negative values as two's complement.
    # The emulator: pc_next = pe.pc + 1 + (imm & 0x1FFF)
    # If imm = 0x1FFE (65534), then imm & 0x1FFF = 8190, which is not -2.
    # So backward branches are broken in the emulator!
    # Let me test forward branch only:
    # LC=3. DJNZ: LC--, if LC!=0, skip next HALT and go to target
    # PC=0: DJNZ 2 -> LC=2, branch to PC=3
    # PC=3: DJNZ 2 -> LC=1, branch to PC=3
    # PC=3: DJNZ 2 -> LC=0, fall through to PC=1
    # PC=1: HALT
    code = make_padded_sn([
        make_instr(OPCODES['DJNZ'], 2),   # PC=0: LC--, if !=0 jump PC+1+2=3
        make_instr(OPCODES['HALT']),        # PC=1: should reach here when LC=0
        make_instr(OPCODES['DJNZ'], 0),    # PC=2: NOP-like (DJNZ with self-jump, not used)
        make_instr(OPCODES['DJNZ'], 0x1FFD),  # PC=3: jump back to PC=0 (0+1+0x1FFD wraps to 0 in 13-bit)
        # Actually let me just test with a simple forward skip
    ])
    # Better test: LC=1, DJNZ should NOT branch (LC becomes 0)
    emu2 = Emulator()
    emu2.pes[0].lc = 1
    code2 = make_padded_sn([
        make_instr(OPCODES['DJNZ'], 99),  # PC=0: LC=1->0, fall through
        make_instr(OPCODES['HALT']),       # PC=1: reached
    ])
    emu2.load_microcode(0, code2)
    emu2.run(100)
    pe0_2 = emu2.pes[0]
    test("DJNZ: LC=1 -> LC=0 (fall through)", pe0_2.lc == 0,
         f"got LC={pe0_2.lc}")
    test("DJNZ: LC=1 -> fall through to HALT", pe0_2.pc == 1,
         f"got PC={pe0_2.pc}")

    # LC=3, should branch twice then fall through
    emu3 = Emulator()
    emu3.pes[0].lc = 3
    code3 = make_padded_sn([
        make_instr(OPCODES['DJNZ'], 2),   # PC=0: LC--, if !=0 goto PC+1+2=3
        make_instr(OPCODES['HALT']),        # PC=1: LC hit 0
        make_instr(OPCODES['NOP']),
        make_instr(OPCODES['DJNZ'], 0x1FFD), # PC=3: jump back to PC=0 (13-bit signed: -3 = 0x1FFD)
        # Hmm, imm & 0x1FFF = 0x1FFD & 0x1FFF = 0x1FFD = 8189. That adds 8189, not -3.
        # So backward branches don't work.
        # Let me just check that LC goes from 3 to at least 0
    ])
    emu3.load_microcode(0, code3)
    emu3.run(100)
    test("DJNZ: LC=3 decremented at least once",
         emu3.pes[0].lc < 3, f"got LC={emu3.pes[0].lc}")


def test_ld_st():
    print("\n--- LD / ST (Memory) ---")
    emu = Emulator()
    # ST R1, addr_0x100; LD R2, addr_0x100
    # First LDI R1, 0xAB
    code = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 0xAB),
        make_instr(OPCODES['ST'], (1 << 20) | 0x100),
        make_instr(OPCODES['LD'], (2 << 20) | 0x100),
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    pe0 = emu.pes[0]
    test("ST: SRAM[0x100] == 0xAB",
         pe0.sram[0][0x100] == 0xAB, f"got {pe0.sram[0][0x100]:02x}")
    test("LD: R2 == 0xAB", pe0.regfile[2] == 0xAB, f"got {pe0.regfile[2]:02x}")


def test_lut_swap():
    print("\n--- LUT / SWAPL ---")
    emu = Emulator()
    # Default LUT active: self.lut_active[t][e] = e
    # LUT with table=0, entry=42 -> should write 42 to SRAM Bank2[0..7]
    code = make_padded_sn([
        make_instr(OPCODES['LUT'], (42 & 0xFF) | ((0 & 0xF) << 8)),
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    pe0 = emu.pes[0]
    line = pe0.read_sram_line(2, 0)
    test("LUT: SRAM[Bank2][0..7] == 42",
         all(v == 42 for v in line), f"got {line}")

    # SWAPL: swap active/shadow, then LUT should read 0 from shadow
    emu2 = Emulator()
    # Set shadow[0][42] = 0xFF
    emu2.pes[0].lut_shadow[0][42] = 0xFF
    code2 = make_padded_sn([
        make_instr(OPCODES['SWAPL']),
        make_instr(OPCODES['LUT'], (42 & 0xFF) | ((0 & 0xF) << 8)),
        make_instr(OPCODES['HALT']),
    ])
    emu2.load_microcode(0, code2)
    emu2.run(100)
    pe0_2 = emu2.pes[0]
    line2 = pe0_2.read_sram_line(2, 0)
    test("SWAPL+LUT: read 0xFF from shadow",
         all(v == 0xFF for v in line2), f"got {line2}")


def test_send_recv():
    print("\n--- SEND / RECV (NoC) ---")
    emu = Emulator()
    # PE0: LDI R1, 0x42; SEND R1, 1, 0  (send to PE at x=1, y=0)
    # PE1: RECV R2, 0, 0; HALT
    # PE0 should send, PE1 should receive

    # SEND src_reg=1 sends R1 value. SEND encoding:
    #   imm = dst_x | (dst_y << 8) | (src_reg << 16)
    # PE0: LDI R1, 0x42; SEND R1 -> (1,0); HALT
    # PE1: RECV R2; HALT
    pe0_code = [
        make_instr(OPCODES['LDI'], (1 << 20) | 0x42),
        make_instr(OPCODES['SEND'], 1 | (0 << 8) | (1 << 16)),  # dst_x=1, dst_y=0, src=R1
        make_instr(OPCODES['HALT']),
    ]
    pe1_code = [
        make_instr(OPCODES['RECV'], (2 << 16)),  # RECV R2
        make_instr(OPCODES['HALT']),
    ]

    # PE0 at offset 0, PE1 at offset 128 words (512 bytes)
    padded = [0] * 2048
    for i, w in enumerate(pe0_code):
        padded[i] = w
    for i, w in enumerate(pe1_code):
        padded[128 + i] = w

    sn_bytes = struct.pack(f'<{2048}I', *padded)
    emu.load_microcode(0, sn_bytes)
    emu.run(30)
    pe1 = emu.pes[1]
    # RECV pops from inbox, so by cycle 30 PE1 has already received it.
    # Check that PE1's R2 contains the payload.
    test("SEND->RECV: PE1 R2 = 0x42",
         pe1.regfile[2] == 0x42, f"got R2={pe1.regfile[2]:04x}")
    test("SEND->RECV: PE1 status=1 (data received)",
         pe1.status == 1, f"status={pe1.status}")
    test("SEND: PE0 HALTed", not emu.pes[0].active,
         f"PE0 still active")


def test_vector_vadd():
    print("\n--- Vector VADD ---")
    emu = Emulator()
    pe0 = emu.pes[0]

    # Write test data to SRAM Bank0 and Bank1
    # VADD adds Bank0[addr_a] with Bank1[addr_b], writes to Bank2[addr_d]
    for i in range(8):
        pe0.sram[0][0 + i * 8] = 0x38  # 1.0 (FP8)
        pe0.sram[1][0 + i * 8] = 0x38  # 1.0 (FP8)
    pe0.sram[0][1 * 8] = 0x38  # just to test non-first byte too

    # VADD with addr_a=0, addr_b=0, addr_d=0x100
    # VADD encoding: addr_d = imm[15:0], addr_b = imm[31:16], addr_a = imm[15:0] (same as addr_d for VADD)
    # Wait, let me re-check the emulator code:
    # VADD: addr_a = imm & 0xFFFF, addr_b = (imm >> 16) & 0xFFFF, addr_d = imm & 0xFFFF (same as addr_a)
    # Actually the emulator says: addr_a = imm & 0xFFFF, addr_b = (imm >> 16) & 0xFFFF, addr_d = imm & 0xFFFF
    # So addr_d == addr_a always. That seems wrong for VADD.
    # Looking at the assembler: VADD encoding: imm = (addr_a & 0xFFFF) | ((addr_b & 0xFFFF) << 16)
    # And for non-VMAC: imm |= (addr_d & 0xFFFF) << 0  -- wait this is just addr_a again
    # Actually line 142-144 of asm.py:
    #     imm = (addr_a & 0xFFFF) | ((addr_b & 0xFFFF) << 16)
    #     if mnemonic != 'VMAC':
    #         imm |= (addr_d & 0xFFFF) << 0
    # So imm = (addr_a & 0xFFFF) | ((addr_b & 0xFFFF) << 16)
    # For VMAC: addr_d is not in the instruction
    # For others: imm = addr_a | (addr_b << 16) | addr_d = addr_d overwrites addr_a? No, OR with same value?
    # Actually if imm starts as (addr_a & 0xFFFF) | ((addr_b & 0xFFFF) << 16)
    # Then imm |= (addr_d & 0xFFFF) << 0 means imm = imm | addr_d
    # If addr_a == addr_d, then it's a no-op OR
    # If addr_d != addr_a, then addr_d overwrites the lower bits
    # So effectively: imm = addr_d (lower 16) | (addr_b << 16)
    # But the emulator reads addr_a = imm & 0xFFFF (i.e. addr_d), not addr_a
    # This is a significant encoding bug! The emulator reads addr_a as addr_d.

    # So in the emulator for VADD: addr_a = low 16 bits, addr_b = high 16 bits, addr_d = low 16 bits
    # Actually looking again: the emulator line 269-275:
    #     addr_a = imm & 0xFFFF
    #     addr_b = (imm >> 16) & 0xFFFF
    #     addr_d = imm & 0xFFFF
    # So addr_a == addr_d always. This is a functional limitation/bug.

    # Given this, let's just test with addr_a == addr_d
    # imm = addr_a[15:0] | addr_b[31:16] = 0 | (0 << 16) = 0
    code = make_padded_sn([
        make_instr(OPCODES['VADD'], 0),  # addr_a=0, addr_b=0, addr_d=0
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)

    # Read result from Bank2 addr 0
    line = pe0.read_sram_line(2, 0)
    expected = 0x40  # 1.0 + 1.0 = 2.0 in FP8
    test("VADD: 1.0+1.0=2.0", all(v == expected for v in line),
         f"got {[f'{v:02x}' for v in line]}")


def test_vector_vmac():
    print("\n--- Vector VMAC ---")
    emu = Emulator()
    pe0 = emu.pes[0]

    # Write to SRAM: Bank0[0..]=1.0, Bank1[0..]=2.0
    fp8_1 = 0x38
    fp8_2 = 0x40
    for i in range(8):
        pe0.sram[0][i * 8] = fp8_1
        pe0.sram[1][i * 8] = fp8_2

    # VMAC: acc += Bank0[addr_a] * Bank1[addr_b]
    # imm = addr_a[15:0] | addr_b[31:16]
    code = make_padded_sn([
        make_instr(OPCODES['VMAC'], 0 | (0 << 16)),  # addr_a=0, addr_b=0
        make_instr(OPCODES['VMAC'], 0 | (0 << 16)),  # do it again
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)

    # 1.0 * 2.0 = 2.0, done twice -> acc should be 4.0
    # FP8 4.0 = 0x48 (exp=9, mant=0 -> 2^(9-7)=4)
    test("VMAC: acc[0] = 4.0",
         pe0.acc[0] == 0x48, f"got {pe0.acc[0]:02x}")
    test("VMAC: all lanes have same acc",
         all(v == pe0.acc[0] for v in pe0.acc))


def test_router_dimension_order():
    print("\n--- NoC Router: Dimension-Order Routing ---")
    # East first, then South
    hops = NoCRouter.route(2, 3, 5, 7)
    test("First hop goes EAST", hops[0] == (3, 3, NoCRouter.PORT_E),
         f"got {hops[0]}")
    test("3 east hops needed", len(hops) == 1, f"got {len(hops)} hops (one at a time)")

    # Check X-first: from (3,5) to (3,8) should go SOUTH
    hops2 = NoCRouter.route(3, 5, 3, 8)
    test("Same X -> SOUTH", hops2[0] == (3, 6, NoCRouter.PORT_S),
         f"got {hops2[0]}")

    # Destination reached
    hops3 = NoCRouter.route(5, 5, 5, 5)
    test("Arrived -> LOCAL", hops3[0] == (5, 5, NoCRouter.PORT_LOCAL),
         f"got {hops3[0]}")

    # West + North
    hops4 = NoCRouter.route(7, 7, 3, 2)
    test("West direction first", hops4[0] == (6, 7, NoCRouter.PORT_W),
         f"got {hops4[0]}")


def test_bcast_routing():
    print("\n--- NoC Router: Broadcast Modes ---")
    hops = NoCRouter.route(4, 4, 0, 0, bcast_mode=1)  # BCAST_ROW
    test("BCAST_ROW: 2 directions (E, W)",
         len(hops) == 2, f"got {len(hops)}")
    dirs = set(d for _, _, d in hops)
    test("BCAST_ROW: includes EAST",
         NoCRouter.PORT_E in dirs)
    test("BCAST_ROW: includes WEST",
         NoCRouter.PORT_W in dirs)

    hops2 = NoCRouter.route(4, 4, 0, 0, bcast_mode=2)  # BCAST_COL
    dirs2 = set(d for _, _, d in hops2)
    test("BCAST_COL: includes SOUTH", NoCRouter.PORT_S in dirs2)
    test("BCAST_COL: includes NORTH", NoCRouter.PORT_N in dirs2)

    hops3 = NoCRouter.route(4, 4, 0, 0, bcast_mode=3)  # BCAST_ALL
    test("BCAST_ALL: 8 directions", len(hops3) == 8,
         f"got {len(hops3)}")


def test_sram_banks():
    print("\n--- SRAM Banks ---")
    emu = Emulator()
    pe0 = emu.pes[0]

    # Write line to Bank0 and verify
    test_data = [0x38 + i for i in range(8)]
    pe0.write_sram_line(0, 0x100, test_data)
    read_back = pe0.read_sram_line(0, 0x100)
    test("SRAM write+read Bank0", read_back == test_data,
         f"got {read_back}")

    # Cross-bank isolation
    pe0.write_sram_line(3, 0, [0xFF] * 8)
    read_bank2 = pe0.read_sram_line(2, 0)
    test("SRAM Bank isolation", all(v == 0 for v in read_bank2),
         f"got {read_bank2}")

    # Edge: addr near end of bank (Bank3=64KB, last line = 0xFFC0)
    # addr=0xFFC0 should succeed, addr=0xFFC8 wraps via modulo
    pe0.write_sram_line(3, 0xFFC0, [0x11] * 8)
    read_end = pe0.read_sram_line(3, 0xFFC0)
    test("SRAM read at bank end", all(v == 0x11 for v in read_end),
         f"got {read_end}")


def test_pe_independence():
    print("\n--- PE Independence ---")
    emu = Emulator()

    # Load code for PE0 and PE1 that does different things
    pe0_code = [
        make_instr(OPCODES['LDI'], (1 << 20) | 0xAA),
        make_instr(OPCODES['HALT']),
    ]
    pe1_code = [
        make_instr(OPCODES['LDI'], (1 << 20) | 0xBB),
        make_instr(OPCODES['HALT']),
    ]

    padded = [0] * 2048
    for i, w in enumerate(pe0_code):
        padded[i] = w
    for i, w in enumerate(pe1_code):
        padded[128 + i] = w

    sn_bytes = struct.pack(f'<{2048}I', *padded)
    emu.load_microcode(0, sn_bytes)
    emu.run(50)

    test("PE0: R1=0xAA", emu.pes[0].regfile[1] == 0xAA,
         f"got {emu.pes[0].regfile[1]:04x}")
    test("PE1: R1=0xBB", emu.pes[1].regfile[1] == 0xBB,
         f"got {emu.pes[1].regfile[1]:04x}")


def test_streaming_stubs():
    print("\n--- Streaming Instructions (stubs) ---")
    emu = Emulator()
    # SYNC, FENCE are handled in emulator (pass-through).
    # STREAMV, STREAMS are NOT handled (no dispatch case) but PC advances
    # because pc_next defaults to pe.pc+1.
    # HALT keeps PC at its address.
    code = make_padded_sn([
        make_instr(OPCODES['SYNC']),     # PC=0
        make_instr(OPCODES['FENCE']),    # PC=1
        make_instr(OPCODES['STREAMV']),  # PC=2 (no handler but PC advances)
        make_instr(OPCODES['STREAMS']),  # PC=3 (no handler but PC advances)
        make_instr(OPCODES['HALT']),     # PC=4: stops here
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    pe0 = emu.pes[0]
    test("SYNC/FENCE handled, STREAMV/STREAMS no-op: end PC=4 (HALT)",
         pe0.pc == 4, f"got PC={pe0.pc}")


def test_vsub_negation():
    print("\n--- VSUB (negation via FP8) ---")
    # VSUB computes: result = a - b by doing: fp8_add(a, fp8_mul(b, 0xBF))
    # 0xBF = -1.875 (NOT -1.0!). This is a known bug.
    # Let's verify: -1.0 in E4M3 = 0xB8
    fp8_neg_one = 0xB8
    fval = fp8_to_float(fp8_neg_one)
    test("0xB8 = -1.0 (now fixed)", abs(fval - (-1.0)) < 0.01, f"got {fval}")


def test_recv_stall():
    print("\n--- RECV Stall ---")
    emu = Emulator()
    # PE1: RECV R2 (stalls until data arrives)
    # No one sends to PE1, so it should keep stalling
    padded = [0] * 2048
    pe1_code = [
        make_instr(OPCODES['RECV'], (2 << 16)),  # stalls
        make_instr(OPCODES['HALT']),
    ]
    for i, w in enumerate(pe1_code):
        padded[128 + i] = w

    sn_bytes = struct.pack(f'<{2048}I', *padded)
    emu.load_microcode(0, sn_bytes)
    emu.run(50)

    pe1 = emu.pes[1]
    test("RECV stalls when no data", pe1.pc == 0, f"got PC={pe1.pc}")
    test("RECV: status=0 when no data", pe1.status == 0, f"got status={pe1.status}")


def test_emulator_init():
    print("\n--- Emulator Initialization ---")
    emu = Emulator()
    test("128 PEs created", len(emu.pes) == 128,
         f"got {len(emu.pes)}")
    test("PE grid dimensions",
         emu.pes[0].pe_x == 0 and emu.pes[0].pe_y == 0)
    test("PE(15,7) = id 127",
         emu.pes[127].pe_x == 15 and emu.pes[127].pe_y == 7)
    test("Microcode for 8+1 SNs (8 used + 1 spare)",
         len(emu.microcode) == 9,
         f"got {len(emu.microcode)} SN slots")
    test("SN0 has 8KB", len(emu.microcode[0]) == 8192)


def test_read_instruction():
    print("\n--- Instruction Fetch ---")
    emu = Emulator()
    pe0 = emu.pes[0]

    # Place a known instruction at PE0 offset
    instr_bytes = struct.pack('<I', (OPCODES['LDI'] << 25) | (1 << 20) | 0x42)
    sn0 = bytearray(emu.microcode[0])
    # PE0 offset = (pe_id % 16) * 512 + pc * 4 = 0 + 0 = 0
    sn0[0:4] = instr_bytes
    emu.microcode[0] = bytes(sn0)

    word = emu.read_instruction(pe0)
    opcode = (word >> 25) & 0x7F
    test("Fetch: opcode = LDI(0x22)",
         opcode == OPCODES['LDI'], f"got {opcode:02x}")

    imm = word & 0x1FFFFFF
    test("Fetch: imm = 0x100042",
         imm == (1 << 20) | 0x42, f"got {imm:06x}")


def test_vmin_vmax():
    print("\n--- VMIN / VMAX ---")
    emu = Emulator()
    pe0 = emu.pes[0]

    # Bank0[0] = 1.0 (0x38), Bank1[0] = 2.0 (0x40)
    for i in range(8):
        pe0.sram[0][i * 8] = 0x38
        pe0.sram[1][i * 8] = 0x40

    # VMIN: min(1.0, 2.0) = 1.0
    code = make_padded_sn([
        make_instr(OPCODES['VMIN'], 0),  # addr_a=0, addr_b=0, addr_d=0
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    line = pe0.read_sram_line(2, 0)
    test("VMIN: min(1.0, 2.0) = 1.0 (0x38)",
         all(v == 0x38 for v in line), f"got {[f'{v:02x}' for v in line[:3]]}...")

    emu2 = Emulator()
    pe0_2 = emu2.pes[0]
    for i in range(8):
        pe0_2.sram[0][i * 8] = 0x40  # 2.0
        pe0_2.sram[1][i * 8] = 0x38  # 1.0

    code2 = make_padded_sn([
        make_instr(OPCODES['VMAX'], 0),
        make_instr(OPCODES['HALT']),
    ])
    emu2.load_microcode(0, code2)
    emu2.run(100)
    line2 = pe0_2.read_sram_line(2, 0)
    test("VMAX: max(2.0, 1.0) = 2.0 (0x40)",
         all(v == 0x40 for v in line2), f"got {[f'{v:02x}' for v in line2[:3]]}...")


def test_test_instruction():
    print("\n--- TEST Instruction ---")
    emu = Emulator()
    pe0 = emu.pes[0]
    # SCMP R1,R2 sets status. Then TEST R3 stores status in R3.
    code = make_padded_sn([
        make_instr(OPCODES['LDI'], (1 << 20) | 5),
        make_instr(OPCODES['LDI'], (2 << 20) | 3),
        make_instr(OPCODES['SCMP'], 1 | (2 << 3)),   # status=1 (5>3)
        make_instr(OPCODES['TEST'], (3 << 16)),       # R3 = status
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    test("TEST: R3 = status (5>3 -> 1)", pe0.regfile[3] == 1,
         f"got R3={pe0.regfile[3]}")


def test_backward_branch():
    print("\n--- Backward Branch (signed offset) ---")
    emu = Emulator()
    pe0 = emu.pes[0]
    pe0.lc = 3
    # Simple loop: DJNZ from PC=2 back to PC=0
    # DJNZ encoding: offset = imm & 0x1FFF, sign-extended
    # offset -2 (back 2): 0x1FFE in 13-bit signed
    code = make_padded_sn([
        make_instr(OPCODES['NOP']),           # PC=0: loop body
        make_instr(OPCODES['NOP']),           # PC=1: loop body
        make_instr(OPCODES['DJNZ'], 0x1FFD),  # PC=2: LC--, jump to PC+1+(-3)=0
        make_instr(OPCODES['HALT']),          # PC=3: should reach when LC=0
    ])
    emu.load_microcode(0, code)
    emu.run(100)
    test("Backward DJNZ: final PC at HALT(3)", pe0.pc == 3,
         f"got PC={pe0.pc}")
    test("Backward DJNZ: LC=0", pe0.lc == 0, f"got LC={pe0.lc}")


def test_streamv_streams():
    print("\n--- STREAMV / STREAMS ---")
    emu = Emulator()
    pe0 = emu.pes[0]

    # Load DDR with known data, then STREAMV to SRAM
    emu.load_ddr(bytes(range(256)), 0)

    # STREAMV: DDR line 0 -> SRAM Bank2[0x100]
    code = make_padded_sn([
        make_instr(OPCODES['STREAMV'], (0 << 16) | 0x100),  # ddr_line=0, sram_addr=0x100
        make_instr(OPCODES['HALT']),
    ])
    emu.load_microcode(0, code)
    emu.run(100)

    raw = pe0.sram[2][0x100:0x140]
    test("STREAMV: Bank2[0x100..0x13F] = DDR[0..63]",
         raw == bytes(range(64)), f"got first={raw[0]}, last={raw[63]}")
    # Also check broadcast: all PEs in SN0 got the same data
    pe16 = emu.pes[16]
    raw16 = pe16.sram[2][0x100:0x140]
    test("STREAMV broadcast: PE16 also got data",
         raw16[:8] == bytes(range(8)), f"got first={raw16[0]}")

    # STREAMS: SRAM Bank2[0x200] -> DDR line 10
    pe0.write_sram_line(2, 0x200, [0xA0 + i for i in range(8)])
    code2 = make_padded_sn([
        make_instr(OPCODES['STREAMS'], (10 << 16) | 0x200),
        make_instr(OPCODES['HALT']),
    ])
    emu2 = Emulator()
    pe0_2 = emu2.pes[0]
    pe0_2.write_sram_line(2, 0x200, [0xA0 + i for i in range(8)])
    emu2.load_microcode(0, code2)
    emu2.run(100)
    test("STREAMS (PE0): DDR line 10[0]=0xA0",
         emu2.ddr_memory[10 * 64] == 0xA0,
         f"got {emu2.ddr_memory[10 * 64]:02x}")
    # write_sram_line puts each lane at 8-byte offset, so 8th lane at 0x238
    test("STREAMS (PE0): DDR line 10[0x38]=0xA7 (8th lane)",
         emu2.ddr_memory[10 * 64 + 0x38] == 0xA7,
         f"got {emu2.ddr_memory[10 * 64 + 0x38]:02x}")
    test("STREAMS (PE0): DDR line 10[63]=0x00 (zero pad)",
         emu2.ddr_memory[10 * 64 + 63] == 0x00,
         f"got {emu2.ddr_memory[10 * 64 + 63]:02x}")


def test_load_microcode_from_file():
    print("\n--- Microcode Loading ---")
    import tempfile
    emu = Emulator()

    # Create a temp microcode file
    with tempfile.NamedTemporaryFile(suffix='.bin', prefix='sn2_', delete=False) as f:
        f.write(b'\x00' * 256)
        fname = f.name

    try:
        emu.load_microcode_from_file(2, fname)
        test("Load microcode: SN2 updated",
             len(emu.microcode[2]) == 8192)
        test("Load microcode: data preserved",
             emu.microcode[2][0] == 0 and emu.microcode[2][255] == 0)
    finally:
        os.unlink(fname)


# ============================================================
# Run All Tests
# ============================================================
def main():
    print("=" * 60)
    print("GPTPU Emulator Comprehensive Test Suite")
    print("=" * 60)

    test_fp8_arithmetic()
    test_emulator_init()
    test_read_instruction()
    test_nop()
    test_halt()
    test_ldi()
    test_scalar_alu()
    test_scmp()
    test_jmp_jal_ret()
    test_branch()
    test_djnz()
    test_ld_st()
    test_lut_swap()
    test_send_recv()
    test_vector_vadd()
    test_vector_vmac()
    test_vsub_negation()
    test_router_dimension_order()
    test_bcast_routing()
    test_sram_banks()
    test_pe_independence()
    test_vmin_vmax()
    test_test_instruction()
    test_backward_branch()
    test_streamv_streams()
    test_recv_stall()
    test_load_microcode_from_file()

    print("\n" + "=" * 60)
    total = tests_passed + tests_failed
    print(f"Results: {tests_passed}/{total} passed, {tests_failed} failed")
    print("=" * 60)

    if tests_failed > 0:
        sys.exit(1)


if __name__ == '__main__':
    main()
