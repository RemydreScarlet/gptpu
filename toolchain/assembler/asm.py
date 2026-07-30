#!/usr/bin/env python3
"""
GPTPU Microcode Assembler
ISA: 32-bit fixed-length, 39 instructions
Supports: labels, registers, .org, .equ directives
"""

import struct
import re

OPCODES = {
    'NOP':    0x00, 'VMAC':  0x01, 'VADD':  0x02, 'VSUB':  0x03,
    'VMUL':   0x04, 'VMIN':  0x05, 'VMAX':  0x06,
    'SADD':   0x10, 'SSUB':  0x11, 'SAND':  0x12,
    'SOR':    0x13, 'SXOR':  0x14, 'SSHL':  0x15,
    'SSHR':   0x16, 'SCMP':  0x17,
    'LD':     0x20, 'ST':    0x21, 'LDI':   0x22,
    'LUT':    0x23, 'SWAPL': 0x24,
    'BNE':    0x30, 'BEQ':   0x31, 'BLT':   0x32,
    'BGT':    0x33, 'DJNZ':  0x34, 'JMP':   0x35,
    'JAL':    0x36, 'RET':   0x37,
    'BCAST':  0x40, 'SEND':  0x41, 'RECV':  0x42, 'TEST':  0x43,
    'STREAMV':0x50, 'STREAMS':0x51, 'SYNC':  0x52, 'FENCE': 0x53,
    'HALT':   0x7F,
}


def is_reg(name: str) -> bool:
    return re.match(r'^[VR]\d+$', name) is not None


def parse_val(s: str, labels: dict, equ: dict) -> int:
    s = s.strip()
    if is_reg(s):
        reg = int(s[1:])
        reg_type = s[0]
        return reg & 0xF
    if s in equ:
        return equ[s]
    if s in labels:
        return labels[s]
    try:
        return int(s, 0)
    except ValueError:
        raise ValueError(f"Undefined symbol: {s}")


class Assembler:
    def __init__(self):
        self.labels = {}
        self.org = 0
        self.equ = {}
        self.output = bytearray()

    def assemble_line(self, line: str, line_num: int = 0):
        line = line.strip()
        if not line or line.startswith('#'):
            return

        if line.endswith(':'):
            label = line[:-1].strip()
            self.labels[label] = self.org
            return

        if line.startswith('.'):
            parts = line.split(None, 1)
            directive = parts[0].lower()
            args = parts[1] if len(parts) > 1 else ''
            if directive == '.org':
                self.org = parse_val(args.strip(), self.labels, self.equ)
            elif directive == '.equ':
                m = re.match(r'(\w+)\s*,\s*(.+)', args)
                if m:
                    self.equ[m.group(1)] = parse_val(m.group(2).strip(),
                                                     self.labels, self.equ)
            return

        tokens = [t for t in re.split(r'[,\s()]+', line) if t]
        mnemonic = tokens[0].upper()
        opcode = OPCODES.get(mnemonic)
        if opcode is None:
            raise ValueError(f"Line {line_num}: Unknown instruction '{mnemonic}'")

        ops = tokens[1:]
        imm = 0

        if mnemonic in ('JMP', 'JAL', 'BNE', 'BEQ', 'BLT', 'BGT', 'DJNZ'):
            target = ops[0] if ops else ''
            val = parse_val(target, self.labels, self.equ) if target else 0
            if target in self.labels:
                val = self.labels[target] - (self.org + 4)
            imm = val & 0x1FFFFFF

        elif mnemonic == 'LDI':
            rd = parse_val(ops[0], self.labels, self.equ) if len(ops) > 0 else 0
            val = parse_val(ops[1], self.labels, self.equ) if len(ops) > 1 else 0
            imm = ((rd & 0x7) << 20) | (val & 0xFFFFF)

        elif mnemonic == 'SEND':
            src_reg = parse_val(ops[0], self.labels, self.equ) if len(ops) > 0 else 0
            dst_x = parse_val(ops[1], self.labels, self.equ) if len(ops) > 1 else 0
            dst_y = parse_val(ops[2], self.labels, self.equ) if len(ops) > 2 else 0
            imm = (dst_x & 0xFF) | ((dst_y & 0xFF) << 8) | ((src_reg & 0xF) << 16)

        elif mnemonic == 'BCAST':
            src_reg = parse_val(ops[0], self.labels, self.equ) if len(ops) > 0 else 0
            dst_x = parse_val(ops[1], self.labels, self.equ) if len(ops) > 1 else 0
            dst_y = parse_val(ops[2], self.labels, self.equ) if len(ops) > 2 else 0
            mode = parse_val(ops[3], self.labels, self.equ) if len(ops) > 3 else 0
            imm = (dst_x & 0xFF) | ((dst_y & 0xFF) << 8) | ((mode & 0x7) << 16) | ((src_reg & 0xF) << 20)

        elif mnemonic == 'RECV':
            dst_reg = parse_val(ops[0], self.labels, self.equ) if len(ops) > 0 else 0
            imm = (dst_reg & 0xF) << 16

        elif mnemonic == 'LUT':
            entry = parse_val(ops[0], self.labels, self.equ) if len(ops) > 0 else 0
            table = parse_val(ops[1], self.labels, self.equ) if len(ops) > 1 else 0
            imm = (entry & 0xFF) | ((table & 0xF) << 8)

        elif mnemonic in ('STREAMV', 'STREAMS'):
            val = parse_val(ops[0], self.labels, self.equ) if ops else 0
            imm = val & 0x1FFFFFF

        elif mnemonic in ('SADD', 'SSUB', 'SAND', 'SOR', 'SXOR', 'SSHL', 'SSHR'):
            rd = parse_val(ops[0], self.labels, self.equ) if len(ops) > 0 else 0
            rs = parse_val(ops[1], self.labels, self.equ) if len(ops) > 1 else 0
            rt = parse_val(ops[2], self.labels, self.equ) if len(ops) > 2 else 0
            # RTL: imm[2:0]=rs, imm[5:3]=rt, imm[8:6]=rd
            imm = (rs & 0x7) | ((rt & 0x7) << 3) | ((rd & 0x7) << 6)

        elif mnemonic == 'SCMP':
            rs = parse_val(ops[0], self.labels, self.equ) if len(ops) > 0 else 0
            rt = parse_val(ops[1], self.labels, self.equ) if len(ops) > 1 else 0
            # RTL: imm[2:0]=rs, imm[5:3]=rt (no rd)
            imm = (rs & 0x7) | ((rt & 0x7) << 3)

        elif mnemonic in ('VMAC', 'VADD', 'VSUB', 'VMUL', 'VMIN', 'VMAX'):
            addr_a = parse_val(ops[0], self.labels, self.equ) if len(ops) > 0 else 0
            addr_b = parse_val(ops[1], self.labels, self.equ) if len(ops) > 1 else 0
            addr_d = parse_val(ops[2], self.labels, self.equ) if len(ops) > 2 else 0
            imm = (addr_a & 0xFFFF) | ((addr_b & 0xFFFF) << 16)
            if mnemonic != 'VMAC':
                imm |= (addr_d & 0xFFFF) << 0

        else:
            if ops:
                imm = parse_val(ops[-1], self.labels, self.equ) & 0x1FFFFFF

        word = (opcode << 25) | imm
        self.output.extend(struct.pack('<I', word))
        self.org += 4
        return word

    def assemble(self, source: str) -> bytes:
        self.labels.clear()
        self.org = 0
        self.output = bytearray()
        self.equ.clear()

        lines = source.split('\n')

        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped.endswith(':') and not stripped.startswith('.'):
                label = stripped[:-1].strip()
                self.labels[label] = self.org
                continue
            if stripped.startswith('.org'):
                parts = stripped.split(None, 1)
                if len(parts) > 1:
                    self.org = parse_val(parts[1].strip(), self.labels, self.equ)

        self.org = 0
        self.output = bytearray()
        for i, line in enumerate(lines):
            self.assemble_line(line, i)

        return bytes(self.output)


def main():
    import sys
    asm = Assembler()
    if len(sys.argv) < 3:
        print("Usage: asm.py <input.s> <output.bin>")
        sys.exit(1)

    with open(sys.argv[1]) as f:
        source = f.read()

    binary = asm.assemble(source)

    with open(sys.argv[2], 'wb') as f:
        f.write(binary)

    print(f"Assembled {len(binary)//4} instructions ({len(binary)} bytes) -> {sys.argv[2]}")
    if asm.labels:
        print(f"Labels: {', '.join(f'{k}=0x{v:x}' for k, v in asm.labels.items())}")


if __name__ == '__main__':
    main()
