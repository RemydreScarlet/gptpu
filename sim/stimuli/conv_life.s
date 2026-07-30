# Conway's Game of Life: neighbor communication test
# Each PE broadcasts state to all 8 neighbors (BCAST mode=3)
# Then receives and counts live neighbors
# Verifies BCAST + RECV + SADD + DJNZ work end-to-end

.org 0
    LDI R0, 1                # R0 = current state (alive)
    LDI R7, 0                # R7 = zero register

    # BCAST state to all 8 neighbors (mode=3 = BCAST_ALL)
    BCAST R0, 0, 0, 3

    # RECV and count neighbors (up to 8)
    LDI R1, 0                # R1 = neighbor count
    LDI R2, 8                # R2 = loop counter
recv_loop:
    RECV R3                  # R3 = neighbor state (0 or 1)
    SADD R1, R1, R3          # R1 += R3
    DJNZ R2, recv_loop

    # R1 should be 8 (all 8 neighbors sent 1)
    HALT
