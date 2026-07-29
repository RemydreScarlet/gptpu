#!/usr/bin/env python3
"""
GPTPU Microcode Assembler
ISA: 32-bit fixed-length, 39 instructions
"""

import struct

# Opcode encoding (7-bit)
OPCODES = {
    'NOP':    0x00,
    'VMAC':   0x01, 'VADD':  0x02, 'VSUB':  0x03,
    'VMUL':   0x04, 'VMIN':  0x05, 'VMAX':  0x06,
    'SADD':   0x10, 'SSUB':  0x11, 'SAND':  0x12,
    'SOR':    0x13, 'SXOR':  0x14, 'SSHL':  0x15,
    'SSHR':   0x16, 'SCMP':  0x17,
    'LD':     0x20, 'ST':    0x21, 'LDI':   0x22,
    'LUT':    0x23, 'SWAPL': 0x24,
    'BNE':    0x30, 'BEQ':   0x31, 'BLT':   0x32,
    'BGT':    0x33, 'DJNZ':  0x34, 'JMP':   0x35,
    'JAL':    0x36, 'RET':   0x37,
    'BCAST':  0x40, 'SEND':  0x41, 'RECV':  0x42,
    'STREAMV':0x50, 'STREAMS':0x51, 'SYNC':  0x52,
    'FENCE':  0x53,
    'HALT':   0x7F,
}


def assemble_line(line: str) -> int:
    """Assemble a single line of microcode into a 32-bit word."""
    line = line.strip()
    if not line or line.startswith('#'):
        return None

    parts = line.replace(',', ' ').split()
    mnemonic = parts[0].upper()

    opcode = OPCODES.get(mnemonic)
    if opcode is None:
        raise ValueError(f"Unknown instruction: {mnemonic}")

    imm = 0
    if len(parts) > 1:
        imm = int(parts[1], 0) & 0x1FFFFFF

    return (opcode << 25) | imm


def assemble(source: str) -> bytes:
    """Assemble multi-line source into binary."""
    words = []
    for line in source.split('\n'):
        word = assemble_line(line)
        if word is not None:
            words.append(word)
    return struct.pack(f'<{len(words)}I', *words)


def main():
    import sys
    if len(sys.argv) < 3:
        print("Usage: asm.py <input.s> <output.bin>")
        sys.exit(1)

    with open(sys.argv[1]) as f:
        source = f.read()

    binary = assemble(source)

    with open(sys.argv[2], 'wb') as f:
        f.write(binary)

    print(f"Assembled {len(binary)//4} instructions -> {sys.argv[2]}")


if __name__ == '__main__':
    main()
