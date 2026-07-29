#!/usr/bin/env python3
"""
Microcode Linker: Place SN-level 8KB microcode blocks into PE memory map.
"""

import struct

MICROCODE_SIZE = 8192  # 8KB per SN
WORD_SIZE = 4          # 32-bit
WORDS_PER_SN = MICROCODE_SIZE // WORD_SIZE  # 2048


def link(sn_id: int, words: list) -> bytes:
    """Place 2048 words into an 8KB block for a given SN."""
    assert len(words) <= WORDS_PER_SN, f"Too many words for SN {sn_id}"

    padded = words + [0] * (WORDS_PER_SN - len(words))
    return struct.pack(f'<{WORDS_PER_SN}I', *padded)


def main():
    import sys
    if len(sys.argv) < 4:
        print("Usage: microcode_linker.py <sn_id> <input.bin> <output.bin>")
        sys.exit(1)

    sn_id = int(sys.argv[1])
    with open(sys.argv[2], 'rb') as f:
        data = f.read()

    words = list(struct.unpack(f'<{len(data)//WORD_SIZE}I', data))
    binary = link(sn_id, words)

    with open(sys.argv[3], 'wb') as f:
        f.write(binary)

    print(f"Linked SN{sn_id}: {len(words)} words -> {sys.argv[3]}")


if __name__ == '__main__':
    main()
