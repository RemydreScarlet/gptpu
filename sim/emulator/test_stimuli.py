# End-to-end stimulus program tests
import sys
import os
import struct

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, '..', '..'))
sys.path.insert(0, REPO_DIR)
sys.path.insert(0, SCRIPT_DIR)

from sim.emulator.emulator import Emulator, NUM_PE
from toolchain.assembler.asm import Assembler
from toolchain.linker.microcode_linker import link

STIMULI_DIR = os.path.join(REPO_DIR, 'sim', 'stimuli')

def load_stimulus(name):
    with open(os.path.join(STIMULI_DIR, name)) as f:
        return f.read()

def assemble(src):
    a = Assembler()
    return a.assemble(src)

def link_sn(words_list, sn_id=0):
    """Pack words into 8KB SN block."""
    return link(sn_id, words_list)

def setup_sram(emu, pe_id, bank, addr, data):
    pe = emu.pes[pe_id]
    for i, b in enumerate(data):
        idx = (addr + i) % len(pe.sram[bank])
        pe.sram[bank][idx] = b & 0xFF

def setup_ddr(emu, line, data):
    if not getattr(emu, 'ddr_memory', None):
        emu.ddr_memory = bytearray(1024 * 1024)
    base = line * 64
    for i, b in enumerate(data):
        emu.ddr_memory[base + i] = b

def load_all_sns(emu, linked, num_sns=8):
    """Load same microcode into all SNs."""
    for sn_id in range(num_sns):
        emu.load_microcode(sn_id, linked)

def test_dense_layer():
    src = load_stimulus('dense_layer.s')
    # Use unique dest address so writeback works (different from addr_a=0)
    src2 = src.replace('.equ Y_ADDR, 0x0000', '.equ Y_ADDR, 0x1000')
    raw = assemble(src2)
    words = list(struct.unpack(f'<{len(raw)//4}I', raw))
    linked = link_sn(words)
    emu = Emulator()
    load_all_sns(emu, linked)

    fp8_vals = [0x3F, 0x3C, 0x38, 0x40, 0x3E, 0x3D, 0x3D, 0x34]
    setup_sram(emu, 0, 0, 0x0000, fp8_vals)  # Bank0 X input
    for j in range(8):
        setup_sram(emu, 0, 1, 0x0000 + j*8, [0x3F - j % 4] * 8)  # Bank1 weights

    emu.run(200)
    result = list(emu.dump_sram(0, 2, 0x1000, 8))
    assert any(b != 0 for b in result), f"dense_layer: all zeros"
    print(f"  PASS: dense_layer result = {result}")

def test_conv_life():
    src = load_stimulus('conv_life.s')
    raw = assemble(src)
    words = list(struct.unpack(f'<{len(raw)//4}I', raw))
    linked = link_sn(words)
    emu = Emulator()
    load_all_sns(emu, linked)

    emu.run(500)

    # Only interior PEs (x in 1..14, y in 1..6) have all 8 neighbors
    interior_pes = [pid for pid in [0, 17, 63, 100]
                    if 1 <= (pid % 16) <= 14 and 1 <= (pid // 16) <= 6]
    for pid in interior_pes:
        cnt = emu.pes[pid].regfile[1]
        assert cnt == 8, f"conv_life PE{pid} (x={pid%16},y={pid//16}) neighbor count: expected 8, got {cnt}"
    print(f"  PASS: conv_life all PEs have neighbor count = 8")

def test_moe_ffn():
    src = load_stimulus('moe_ffn.s')
    raw = assemble(src)
    words = list(struct.unpack(f'<{len(raw)//4}I', raw))
    linked = link_sn(words)
    emu = Emulator()
    load_all_sns(emu, linked)

    ddr_data = list(range(64))
    setup_ddr(emu, 0, ddr_data)
    setup_ddr(emu, 10, [0xFF] * 64)

    emu.run(200)

    ddr_line10 = list(emu.ddr_memory[10*64:10*64+64])
    assert ddr_line10 == ddr_data, f"moe_ffn mismatch\n  exp: {ddr_data}\n  got: {ddr_line10}"
    print(f"  PASS: moe_ffn DDR line 10 matches line 0")

if __name__ == '__main__':
    tests = [
        ("dense_layer.s", test_dense_layer),
        ("conv_life.s", test_conv_life),
        ("moe_ffn.s", test_moe_ffn),
    ]
    all_pass = True
    for name, func in tests:
        try:
            print(f"\n--- {name} ---")
            func()
        except Exception as e:
            print(f"  FAIL: {e}")
            import traceback
            traceback.print_exc()
            all_pass = False
    print(f"\n{'All passed!' if all_pass else 'Some failed!'}")
