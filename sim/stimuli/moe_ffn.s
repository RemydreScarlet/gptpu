# MoE FFN layer: stream expert weights through
# 1. STREAMV: DDR[line=0] -> Bank2[0x2000]
# 2. STREAMS: Bank2[0x2000] -> DDR[line=10]
# Tests streaming data through SRAM (no compute)

.equ DDR_IN,  0
.equ DDR_OUT, 10
.equ SRAM_BUF, 0x2000

.org 0
    # Load expert weights from DDR into SRAM
    STREAMV DDR_IN, SRAM_BUF

    # Store SRAM contents back to DDR (different line)
    STREAMS DDR_OUT, SRAM_BUF

    HALT
