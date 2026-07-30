#!/usr/bin/env python3
"""
Microcode Linker: Place SN-level 8KB microcode blocks into PE memory map.
Supports multi-SN linking and section placement.
"""

import struct
import json

MICROCODE_SIZE = 8192
WORD_SIZE = 4
WORDS_PER_SN = MICROCODE_SIZE // WORD_SIZE


def link(sn_id: int, words: list, base_offset: int = 0) -> bytes:
    """Place code into an 8KB SN block (2048 words).
    Each PE gets 512 bytes (128 words). Code is replicated for all 16 PEs.
    base_offset: skip N words at the start of each PE's slot.
    """
    WORDS_PER_PE = 128
    assert len(words) + base_offset <= WORDS_PER_PE, \
        f"Code too long for SN {sn_id}: {len(words)}+{base_offset} > {WORDS_PER_PE}"
    pe_code = [0] * base_offset + words
    pe_code = pe_code + [0] * (WORDS_PER_PE - len(pe_code))
    full = pe_code * 16  # replicate for all 16 PEs
    assert len(full) == WORDS_PER_SN
    return struct.pack(f'<{WORDS_PER_SN}I', *full)


def link_multi(sn_map: dict) -> dict:
    """Link multiple SNs at once.
    sn_map: {sn_id: [word_list]} or {sn_id: {'words': [...], 'offset': N}}
    Returns: {sn_id: bytes}
    """
    result = {}
    for sn_id, config in sn_map.items():
        if isinstance(config, dict):
            words = config.get('words', [])
            offset = config.get('offset', 0)
        else:
            words = config
            offset = 0
        result[sn_id] = link(sn_id, words, offset)
    return result


def main():
    import sys
    if len(sys.argv) < 4:
        print("Usage:")
        print("  microcode_linker.py <sn_id> <input.bin> <output.bin>")
        print("  microcode_linker.py --multi <config.json> <output_dir>")
        sys.exit(1)

    if sys.argv[1] == '--multi':
        with open(sys.argv[2]) as f:
            config = json.load(f)
        out_dir = sys.argv[3]
        result = link_multi(config)
        import os
        os.makedirs(out_dir, exist_ok=True)
        for sn_id, binary in result.items():
            path = os.path.join(out_dir, f"sn{sn_id}.bin")
            with open(path, 'wb') as f:
                f.write(binary)
            print(f"Linked SN{sn_id}: {len(binary)} bytes -> {path}")
        return

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
