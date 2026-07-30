#!/usr/bin/env python3
"""
GPTPU Cycle-Accurate Emulator
==============================
Models: PE core (SRAM, CCE, Vector, Scalar, LUT), NoC routing, DDR streaming.
Same memory map and ISA as the RTL implementation.
"""

import struct
import sys
from typing import Optional

# === Constants (matches gptpu_pkg.sv) ===
PE_GRID_X = 16
PE_GRID_Y = 8
NUM_PE = PE_GRID_X * PE_GRID_Y
SRAM_BANK0_SIZE = 256 * 1024
SRAM_BANK1_SIZE = 128 * 1024
SRAM_BANK2_SIZE = 64 * 1024
SRAM_BANK3_SIZE = 64 * 1024
SRAM_BANK_SIZE = [SRAM_BANK0_SIZE, SRAM_BANK1_SIZE, SRAM_BANK2_SIZE, SRAM_BANK3_SIZE]
VECTOR_LANE_WIDTH = 8
FP8_E4M3_WIDTH = 8

# === ISA Opcodes ===
OPCODES = {
    'NOP': 0x00, 'VMAC': 0x01, 'VADD': 0x02, 'VSUB': 0x03,
    'VMUL': 0x04, 'VMIN': 0x05, 'VMAX': 0x06,
    'SADD': 0x10, 'SSUB': 0x11, 'SAND': 0x12, 'SOR': 0x13,
    'SXOR': 0x14, 'SSHL': 0x15, 'SSHR': 0x16, 'SCMP': 0x17,
    'LD': 0x20, 'ST': 0x21, 'LDI': 0x22,
    'LUT': 0x23, 'SWAPL': 0x24,
    'BNE': 0x30, 'BEQ': 0x31, 'BLT': 0x32, 'BGT': 0x33,
    'DJNZ': 0x34, 'JMP': 0x35, 'JAL': 0x36, 'RET': 0x37,
    'BCAST': 0x40, 'SEND': 0x41, 'RECV': 0x42, 'TEST': 0x43,
    'STREAMV': 0x50, 'STREAMS': 0x51, 'SYNC': 0x52, 'FENCE': 0x53,
    'HALT': 0x7F,
}

OPCODE_NAMES = {v: k for k, v in OPCODES.items()}


# === FP8 E4M3 Arithmetic ===
def fp8_add(a: int, b: int) -> int:
    sign_a = (a >> 7) & 1
    exp_a = (a >> 3) & 0xF
    mant_a = a & 0x7
    sign_b = (b >> 7) & 1
    exp_b = (b >> 3) & 0xF
    mant_b = b & 0x7

    if exp_a == 0xF:
        return (sign_a << 7) | 0xF8
    if exp_b == 0xF:
        return (sign_b << 7) | 0xF8

    mant_a_ext = (1 << 3) | mant_a if exp_a != 0 else mant_a
    mant_b_ext = (1 << 3) | mant_b if exp_b != 0 else mant_b

    if exp_a >= exp_b:
        exp_r = exp_a
        shift = exp_a - exp_b
        if shift > 7: shift = 7
        mant_b_ext >>= shift
        sign_r = sign_a
    else:
        exp_r = exp_b
        shift = exp_b - exp_a
        if shift > 7: shift = 7
        mant_a_ext >>= shift
        sign_r = sign_b

    if sign_a == sign_b:
        mant_r = mant_a_ext + mant_b_ext
        sign_r = sign_a
        if mant_r & 0x10:
            mant_r >>= 1
            exp_r += 1
    else:
        if mant_a_ext >= mant_b_ext:
            mant_r = mant_a_ext - mant_b_ext
            sign_r = sign_a
        else:
            mant_r = mant_b_ext - mant_a_ext
            sign_r = sign_b
        while mant_r > 0 and not (mant_r & 0x8):
            mant_r <<= 1
            exp_r -= 1
            if exp_r <= 0:
                return 0

    if exp_r >= 0xF:
        return (sign_r << 7) | 0xF8
    if mant_r == 0:
        return 0
    return (sign_r << 7) | (exp_r << 3) | (mant_r & 0x7)


def fp8_mul(a: int, b: int) -> int:
    sign_r = ((a >> 7) & 1) ^ ((b >> 7) & 1)
    exp_a = (a >> 3) & 0xF
    exp_b = (b >> 3) & 0xF
    mant_a = a & 0x7
    mant_b = b & 0x7

    if exp_a == 0 or exp_b == 0:
        return 0
    if exp_a == 0xF or exp_b == 0xF:
        return (sign_r << 7) | 0xF8

    exp_r = exp_a + exp_b - 7
    mant_prod = ((1 << 3) | mant_a) * ((1 << 3) | mant_b)
    if mant_prod & 0x20:
        mant_r = (mant_prod >> 2) & 0x7
        exp_r += 1
    else:
        mant_r = (mant_prod >> 1) & 0x7
    if exp_r >= 0xF:
        return (sign_r << 7) | 0xF8
    if exp_r <= 0:
        return 0
    return (sign_r << 7) | (exp_r << 3) | mant_r


# === PE State ===
class PEState:
    def __init__(self, pe_id: int, pe_x: int, pe_y: int):
        self.pe_id = pe_id
        self.pe_x = pe_x
        self.pe_y = pe_y
        self.pc = 0
        self.link_reg = 0
        self.lc = 0  # loop counter
        self.regfile = [0] * 8  # scalar registers
        self.vector_regs = [[0] * VECTOR_LANE_WIDTH for _ in range(16)]  # V0-V15
        self.acc = [0] * VECTOR_LANE_WIDTH  # MAC accumulator
        self.active = True
        self.status = 0

        # SRAM: 4 banks
        self.sram = [
            bytearray(SRAM_BANK0_SIZE),
            bytearray(SRAM_BANK1_SIZE),
            bytearray(SRAM_BANK2_SIZE),
            bytearray(SRAM_BANK3_SIZE),
        ]

        # LUT: 16 tables x 256 entries
        self.lut_active = [[i for i in range(256)] for _ in range(16)]
        self.lut_shadow = [[0] * 256 for _ in range(16)]
        self.lut_sel = True  # True = active

        # NoC
        self.inbox = []  # received flits

    def read_sram_line(self, bank: int, addr: int) -> list:
        """Read 8 FP8 values (64 bytes) from SRAM at line address."""
        ba = addr % SRAM_BANK_SIZE[bank]
        if ba + 64 > len(self.sram[bank]):
            return [0] * 8
        raw = self.sram[bank][ba:ba + 64]
        return [raw[i] for i in range(0, 64, 8)]

    def write_sram_line(self, bank: int, addr: int, data: list):
        ba = addr % SRAM_BANK_SIZE[bank]
        for i, val in enumerate(data[:8]):
            if ba + i * 8 < SRAM_BANK_SIZE[bank]:
                self.sram[bank][ba + i * 8] = val & 0xFF

    def lut_lookup(self, table_id: int, entry: int) -> int:
        tbl = self.lut_active if self.lut_sel else self.lut_shadow
        return tbl[table_id % 16][entry % 256]

    def swap_lut(self):
        self.lut_sel = not self.lut_sel


# === NoC Router ===
class NoCRouter:
    PORT_LOCAL = 0
    PORT_N = 1
    PORT_E = 2
    PORT_S = 3
    PORT_W = 4
    PORT_NE = 5
    PORT_SE = 6
    PORT_NW = 7
    PORT_SW = 8

    @staticmethod
    def route(src_x, src_y, dst_x, dst_y, bcast_mode=0):
        """Return list of (next_x, next_y, dir) for the next hop."""
        if bcast_mode == 1:  # BCAST_ROW
            return [(src_x + 1, src_y, NoCRouter.PORT_E),
                    (src_x - 1, src_y, NoCRouter.PORT_W)]
        if bcast_mode == 2:  # BCAST_COL
            return [(src_x, src_y + 1, NoCRouter.PORT_S),
                    (src_x, src_y - 1, NoCRouter.PORT_N)]
        if bcast_mode == 3:  # BCAST_ALL (8 Moore neighbors)
            dirs = [(1, 0, NoCRouter.PORT_E), (-1, 0, NoCRouter.PORT_W),
                    (0, 1, NoCRouter.PORT_S), (0, -1, NoCRouter.PORT_N),
                    (1, -1, NoCRouter.PORT_NE), (1, 1, NoCRouter.PORT_SE),
                    (-1, -1, NoCRouter.PORT_NW), (-1, 1, NoCRouter.PORT_SW)]
            return [(src_x + dx, src_y + dy, d) for dx, dy, d in dirs]

        # Dimension-order: X first, Y second
        dx = dst_x - src_x
        dy = dst_y - src_y
        if dx != 0:
            return [(src_x + (1 if dx > 0 else -1), src_y,
                     NoCRouter.PORT_E if dx > 0 else NoCRouter.PORT_W)]
        if dy != 0:
            return [(src_x, src_y + (1 if dy > 0 else -1),
                     NoCRouter.PORT_S if dy > 0 else NoCRouter.PORT_N)]
        return [(src_x, src_y, NoCRouter.PORT_LOCAL)]  # arrived


# === Cycle-Accurate Emulator ===
class Emulator:
    def __init__(self, ddr_latency: int = 10):
        self.cycle = 0
        self.pes = []
        self.noc_packets = []  # (curr_x, curr_y, dst_x, dst_y, data, mode)
        self.microcode = [bytearray(8192) for _ in range(NUM_PE // 16 + 1)]
        self.trace = False
        self.running = True
        self.ddr_latency = ddr_latency  # cycles for DDR→SRAM / SRAM→DDR
        self.stream_queue = []  # (ddr_line, sram_addr, sn_x, sn_y, direction, remaining)

        for pid in range(NUM_PE):
            px = pid % PE_GRID_X
            py = pid // PE_GRID_X
            self.pes.append(PEState(pid, px, py))

    def load_microcode(self, sn_id: int, binary: bytes):
        if sn_id < len(self.microcode):
            self.microcode[sn_id][:len(binary)] = binary

    def load_microcode_from_file(self, sn_id: int, path: str):
        with open(path, 'rb') as f:
            self.load_microcode(sn_id, f.read())

    def load_ddr(self, data: bytes, offset: int = 0):
        if not hasattr(self, 'ddr_memory'):
            self.ddr_memory = bytearray(1024 * 1024)
        end = min(offset + len(data), len(self.ddr_memory))
        self.ddr_memory[offset:end] = data[:end - offset]

    def load_ddr_from_file(self, path: str, offset: int = 0):
        with open(path, 'rb') as f:
            self.load_ddr(f.read(), offset)

    def load_sram(self, pe_id: int, bank: int, addr: int, data: bytes):
        pe = self.pes[pe_id]
        ba = addr % len(pe.sram[bank])
        pe.sram[bank][ba:ba + len(data)] = data

    def read_instruction(self, pe: PEState) -> int:
        sn_id = (pe.pe_y // 4) * (PE_GRID_X // 4) + (pe.pe_x // 4)
        sn_mem = self.microcode[sn_id] if sn_id < len(self.microcode) else bytearray(8192)
        # PE position within the 4x4 SN block determines its 512-byte microcode slot
        slot = (pe.pe_x % 4) + (pe.pe_y % 4) * 4
        offset = slot * 512 + pe.pc * 4
        if offset + 4 > len(sn_mem):
            return (OPCODES['NOP'] << 25)
        word = struct.unpack_from('<I', sn_mem, offset)[0]
        return word

    def step_pe(self, pe: PEState):
        if not pe.active:
            return
        instr_word = self.read_instruction(pe)
        opcode = (instr_word >> 25) & 0x7F
        imm = instr_word & 0x1FFFFFF

        op_name = OPCODE_NAMES.get(opcode, '???')
        if self.trace:
            print(f"  PE{pe.pe_id:3d} @ PC={pe.pc:3d}: {op_name:8s} imm=0x{imm:06x}")

        pc_next = pe.pc + 1

        if opcode == OPCODES['NOP']:
            pass

        elif opcode == OPCODES['VMAC']:
            writeback = (imm >> 24) & 1
            if writeback:
                addr_d = imm & 0xFFFF
                pe.write_sram_line(2, addr_d, pe.acc)
            else:
                addr_a = imm & 0xFFFF
                addr_b = (imm >> 16) & 0xFFFF
                line_a = pe.read_sram_line(0, addr_a)
                line_b = pe.read_sram_line(1, addr_b)
                for i in range(VECTOR_LANE_WIDTH):
                    product = fp8_mul(line_a[i], line_b[i])
                    pe.acc[i] = fp8_add(pe.acc[i], product)

        elif opcode in (OPCODES['VADD'], OPCODES['VSUB'], OPCODES['VMUL'],
                        OPCODES['VMIN'], OPCODES['VMAX']):
            addr_a = imm & 0xFFFF
            addr_b = (imm >> 16) & 0xFFFF
            if (imm >> 24) & 1:
                addr_d = pe.regfile[6]  # D_ADDR register, pre-loaded via LDI
            else:
                addr_d = addr_a  # destructive mode
            line_a = pe.read_sram_line(0, addr_a)
            line_b = pe.read_sram_line(1, addr_b)
            if opcode == OPCODES['VADD']:
                result = [fp8_add(line_a[i], line_b[i]) for i in range(VECTOR_LANE_WIDTH)]
            elif opcode == OPCODES['VSUB']:
                result = [fp8_add(line_a[i], fp8_mul(line_b[i], 0xB8))
                          for i in range(VECTOR_LANE_WIDTH)]
            elif opcode == OPCODES['VMUL']:
                result = [fp8_mul(line_a[i], line_b[i]) for i in range(VECTOR_LANE_WIDTH)]
            elif opcode == OPCODES['VMIN']:
                result = [line_a[i] if line_a[i] < line_b[i] else line_b[i]
                          for i in range(VECTOR_LANE_WIDTH)]
            elif opcode == OPCODES['VMAX']:
                result = [line_a[i] if line_a[i] > line_b[i] else line_b[i]
                          for i in range(VECTOR_LANE_WIDTH)]
            pe.write_sram_line(2, addr_d, result)

        elif opcode == OPCODES['LUT']:
            entry = imm & 0xFF
            table = (imm >> 8) & 0xF
            result = [pe.lut_lookup(table, entry)] * VECTOR_LANE_WIDTH
            pe.write_sram_line(2, 0, result)

        elif opcode == OPCODES['SWAPL']:
            pe.swap_lut()

        elif opcode == OPCODES['SEND']:
            src_reg = (imm >> 16) & 0xF
            dst_x = imm & 0xFF
            dst_y = (imm >> 8) & 0xFF
            payload = pe.regfile[src_reg] & 0xFFFFFFFFFF
            flit_data = (pe.pe_y << 56) | (pe.pe_x << 48) | payload
            self.noc_packets.append((
                pe.pe_x, pe.pe_y,
                dst_x, dst_y,
                flit_data,
                0  # bcast_mode = unicast
            ))

        elif opcode == OPCODES['BCAST']:
            src_reg = (imm >> 20) & 0xF
            dst_x = imm & 0xFF
            dst_y = (imm >> 8) & 0xFF
            bcast_mode = (imm >> 16) & 0x7
            payload = pe.regfile[src_reg] & 0xFFFFFFFFFF
            flit_data = (pe.pe_y << 56) | (pe.pe_x << 48) | (bcast_mode << 45) | payload
            self.noc_packets.append((
                pe.pe_x, pe.pe_y,
                dst_x, dst_y,
                flit_data,
                bcast_mode
            ))

        elif opcode == OPCODES['RECV']:
            dst_reg = (imm >> 16) & 0xF
            if pe.inbox:
                flit = pe.inbox.pop(0)
                payload = flit & 0xFFFFFFFFFF
                pe.regfile[dst_reg] = payload & 0xFFFF
                pe.status = 1
            else:
                pe.status = 0
                pc_next = pe.pc  # stall until data arrives

        elif opcode == OPCODES['JMP']:
            pc_next = imm & 0x1FFF

        elif opcode == OPCODES['JAL']:
            pe.link_reg = pe.pc + 1
            pc_next = imm & 0x1FFF

        elif opcode == OPCODES['RET']:
            pc_next = pe.link_reg

        elif opcode in (OPCODES['BNE'], OPCODES['BEQ'], OPCODES['BLT'], OPCODES['BGT']):
            cond_map = {
                OPCODES['BNE']: lambda: pe.status != 0,
                OPCODES['BEQ']: lambda: pe.status == 0,
                OPCODES['BLT']: lambda: pe.status < 0,
                OPCODES['BGT']: lambda: pe.status > 0,
            }
            offset = imm & 0x1FFF
            if offset >= 0x1000:
                offset -= 0x2000  # sign-extend 13-bit
            if cond_map[opcode]():
                pc_next = pe.pc + 1 + offset

        elif opcode == OPCODES['DJNZ']:
            rd = (imm >> 20) & 0xF
            if rd == 0:
                # rd=0: use internal loop counter (backward compat with direct tests)
                pe.lc -= 1
                lc_val = pe.lc
            else:
                pe.regfile[rd] = (pe.regfile[rd] - 1) & 0xFFFF
                lc_val = pe.regfile[rd]
            offset = imm & 0x1FFF
            if offset >= 0x1000:
                offset -= 0x2000  # sign-extend 13-bit
            if lc_val != 0:
                pc_next = pe.pc + 1 + offset

        elif opcode == OPCODES['LDI']:
            rd = (imm >> 20) & 0x7
            val = imm & 0xFFFFF
            if rd < 8:
                pe.regfile[rd] = val

        elif opcode in (OPCODES['SADD'], OPCODES['SSUB'], OPCODES['SAND'],
                        OPCODES['SOR'], OPCODES['SXOR'], OPCODES['SSHL'],
                        OPCODES['SSHR']):
            rs = imm & 0x7
            rt = (imm >> 3) & 0x7
            rd = (imm >> 6) & 0x7
            a = pe.regfile[rs]
            b = pe.regfile[rt]
            if opcode == OPCODES['SADD']:
                pe.regfile[rd] = (a + b) & 0xFFFF
            elif opcode == OPCODES['SSUB']:
                pe.regfile[rd] = (a - b) & 0xFFFF
            elif opcode == OPCODES['SAND']:
                pe.regfile[rd] = (a & b) & 0xFFFF
            elif opcode == OPCODES['SOR']:
                pe.regfile[rd] = (a | b) & 0xFFFF
            elif opcode == OPCODES['SXOR']:
                pe.regfile[rd] = (a ^ b) & 0xFFFF
            elif opcode == OPCODES['SSHL']:
                pe.regfile[rd] = (a << (b & 0xF)) & 0xFFFF
            elif opcode == OPCODES['SSHR']:
                pe.regfile[rd] = (a >> (b & 0xF)) & 0xFFFF

        elif opcode == OPCODES['SCMP']:
            rs = imm & 0x7
            rt = (imm >> 3) & 0x7
            a = pe.regfile[rs] & 0xFFFF
            b = pe.regfile[rt] & 0xFFFF
            if a == b:
                pe.status = 0
            elif a < b:
                pe.status = -1
            else:
                pe.status = 1

        elif opcode == OPCODES['LD']:
            rd = (imm >> 20) & 0x7
            addr = imm & 0xFFFF
            pe.regfile[rd] = pe.sram[0][addr % len(pe.sram[0])]

        elif opcode == OPCODES['ST']:
            rs = (imm >> 20) & 0x7
            addr = imm & 0xFFFF
            pe.sram[0][addr % len(pe.sram[0])] = pe.regfile[rs] & 0xFF

        elif opcode == OPCODES['HALT']:
            pe.active = False
            pc_next = pe.pc

        elif opcode == OPCODES['TEST']:
            rd = (imm >> 16) & 0x7
            if rd < 8:
                pe.regfile[rd] = pe.status & 0xFFFF

        elif opcode == OPCODES['STREAMV']:
            ddr_line = (imm >> 16) & 0xFFFF
            sram_addr = imm & 0xFFFF
            if not hasattr(self, 'ddr_memory'):
                self.ddr_memory = bytearray(1024 * 1024)
            # Only top-left PE of the 4x4 SN block initiates the transfer
            sn_origin = (pe.pe_y // 4) * PE_GRID_X * 4 + (pe.pe_x // 4) * 4
            if pe.pe_id == sn_origin:
                sn_x = (pe.pe_x // 4) * 4
                sn_y = (pe.pe_y // 4) * 4
                self.stream_queue.append(
                    (ddr_line, sram_addr, sn_x, sn_y, 0, self.ddr_latency)
                )

        elif opcode == OPCODES['STREAMS']:
            ddr_line = (imm >> 16) & 0xFFFF
            sram_addr = imm & 0xFFFF
            if not hasattr(self, 'ddr_memory'):
                self.ddr_memory = bytearray(1024 * 1024)
            sn_origin = (pe.pe_y // 4) * PE_GRID_X * 4 + (pe.pe_x // 4) * 4
            if pe.pe_id == sn_origin:
                sn_x = (pe.pe_x // 4) * 4
                sn_y = (pe.pe_y // 4) * 4
                self.stream_queue.append(
                    (ddr_line, sram_addr, sn_x, sn_y, 1, self.ddr_latency)
                )

        elif opcode == OPCODES['SYNC']:
            pass

        elif opcode == OPCODES['FENCE']:
            pass

        pe.pc = pc_next & 0x1FFF

    def route_packets(self):
        """Advance unicast one hop per cycle; deliver broadcast to neighbors."""
        remaining = []
        for curr_x, curr_y, dst_x, dst_y, data, mode in self.noc_packets:
            if mode == 0:
                hops = NoCRouter.route(curr_x, curr_y, dst_x, dst_y, 0)
                nx, ny, _ = hops[0]
                if nx == dst_x and ny == dst_y:
                    if 0 <= nx < PE_GRID_X and 0 <= ny < PE_GRID_Y:
                        self.pes[ny * PE_GRID_X + nx].inbox.append(data)
                else:
                    if 0 <= nx < PE_GRID_X and 0 <= ny < PE_GRID_Y:
                        remaining.append((nx, ny, dst_x, dst_y, data, mode))
            else:
                hops = NoCRouter.route(curr_x, curr_y, dst_x, dst_y, mode)
                for nx, ny, _ in hops:
                    if 0 <= nx < PE_GRID_X and 0 <= ny < PE_GRID_Y:
                        self.pes[ny * PE_GRID_X + nx].inbox.append(data)
        self.noc_packets = remaining

    def process_stream_queue(self):
        """Advance pending DDR transfers; complete when remaining hits 0."""
        completed = []
        remaining = []
        for ddr_line, sram_addr, sn_x, sn_y, direction, rem in self.stream_queue:
            if rem > 0:
                remaining.append((ddr_line, sram_addr, sn_x, sn_y, direction, rem - 1))
            else:
                completed.append((ddr_line, sram_addr, sn_x, sn_y, direction))
        self.stream_queue = remaining
        for ddr_line, sram_addr, sn_x, sn_y, direction in completed:
            ddr_base = ddr_line * 64
            if direction == 0:  # STREAMV: DDR → SRAM (all PEs in SN block)
                for dy in range(4):
                    for dx in range(4):
                        target_id = (sn_y + dy) * PE_GRID_X + (sn_x + dx)
                        if 0 <= target_id < len(self.pes):
                            target_pe = self.pes[target_id]
                            for i in range(64):
                                ba = (sram_addr + i) % SRAM_BANK_SIZE[2]
                                da = ddr_base + i
                                if da < len(self.ddr_memory):
                                    target_pe.sram[2][ba] = self.ddr_memory[da]
                                else:
                                    target_pe.sram[2][ba] = 0
            else:  # STREAMS: SRAM → DDR (only from top-left PE in SN)
                origin_id = sn_y * PE_GRID_X + sn_x
                if 0 <= origin_id < len(self.pes):
                    src_pe = self.pes[origin_id]
                    for i in range(64):
                        ba = (sram_addr + i) % SRAM_BANK_SIZE[2]
                        da = ddr_base + i
                        if da < len(self.ddr_memory):
                            self.ddr_memory[da] = src_pe.sram[2][ba]

    def step(self):
        """Execute one cycle across all PEs."""
        self.cycle += 1

        self.route_packets()
        self.process_stream_queue()

        for pe in self.pes:
            self.step_pe(pe)

        if self.trace:
            active = sum(1 for p in self.pes if p.active)
            print(f"\nCycle {self.cycle}: {active}/{NUM_PE} PEs active, "
                  f"{len(self.noc_packets)} NoC packets in-flight, "
                  f"{len(self.stream_queue)} DDR transfers pending")

    def run(self, max_cycles: int = 1000):
        while self.running and self.cycle < max_cycles:
            self.step()
            if not any(p.active for p in self.pes) and not self.stream_queue \
               and not self.noc_packets:
                self.running = False
        return self.cycle

    def dump_sram(self, pe_id: int, bank: int, addr: int, length: int) -> bytes:
        pe = self.pes[pe_id]
        ba = addr % len(pe.sram[bank])
        return bytes(pe.sram[bank][ba:ba + length])

    def dump_state(self, pe_id: int):
        pe = self.pes[pe_id]
        print(f"\nPE{pe_id} ({pe.pe_x},{pe.pe_y}):")
        print(f"  PC={pe.pc} {'ACTIVE' if pe.active else 'HALTED'}")
        print(f"  LC={pe.lc}, Link={pe.link_reg}")
        print(f"  Regs: {[f'R{i}={pe.regfile[i]:04x}' for i in range(8)]}")
        print(f"  Inbox: {len(pe.inbox)} flits")


def main():
    import argparse
    parser = argparse.ArgumentParser(description='GPTPU Cycle-Accurate Emulator')
    parser.add_argument('--microcode', '-m', nargs='+',
                        help='SN microcode files (sn<id>.bin)')
    parser.add_argument('--cycles', '-c', type=int, default=100,
                        help='Max cycles to simulate')
    parser.add_argument('--trace', '-t', action='store_true',
                        help='Enable instruction trace')
    parser.add_argument('--dump', '-d', type=int, nargs='*',
                        help='Dump PE state after run (PE IDs)')
    args = parser.parse_args()

    emu = Emulator()
    emu.trace = args.trace

    if args.microcode:
        for path in args.microcode:
            import os.path
            basename = os.path.basename(path)
            # Extract SN ID from filename (e.g., sn3.bin -> 3)
            for part in basename.replace('.', '_').split('_'):
                if part.startswith('sn'):
                    try:
                        sn_id = int(part[2:])
                        emu.load_microcode_from_file(sn_id, path)
                        print(f"Loaded {path} -> SN{sn_id}")
                    except ValueError:
                        pass

    print(f"Running {args.cycles} cycles...")
    cycles = emu.run(args.cycles)
    print(f"Done: {cycles} cycles executed")

    if args.dump is not None:
        for pid in args.dump:
            if 0 <= pid < NUM_PE:
                emu.dump_state(pid)

    return emu


if __name__ == '__main__':
    main()
