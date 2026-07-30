# Conway's Life for GPTPU (8x8 grid, 1 PE per cell)
# Cell state layout: Bank 0[row*8 + col] = 1 if alive, 0 if dead
# Uses LUT[15] for Life rules

.org 0

# Initialize: set initial pattern (glider)
LDI R0, 1
LDI R1, 3
LDI R2, 4
LDI R3, 5
LDI R4, 10

# Step: for each cell, count live neighbors via SEND/RECV
# then compute next state via LUT[15]

loop:
  # Phase 1: Send current state to all 8 neighbors
  SEND R0, pe_x+1, pe_y     # east
  SEND R0, pe_x-1, pe_y     # west
  SEND R0, pe_x, pe_y+1     # south
  SEND R0, pe_x, pe_y-1     # north
  SEND R0, pe_x+1, pe_y+1   # southeast
  SEND R0, pe_x+1, pe_y-1   # northeast
  SEND R0, pe_x-1, pe_y+1   # southwest
  SEND R0, pe_x-1, pe_y-1   # northwest

  # Phase 2: Receive neighbor states
  RECV R1, pe_x+1, pe_y
  RECV R2, pe_x-1, pe_y
  RECV R3, pe_x, pe_y+1
  RECV R4, pe_x, pe_y-1
  RECV R5, pe_x+1, pe_y+1
  RECV R6, pe_x+1, pe_y-1
  RECV R7, pe_x-1, pe_y+1
  RECV R8, pe_x-1, pe_y-1

  # Phase 3: Count neighbors (add all received values)
  ADD R9, R1, R2
  ADD R9, R9, R3
  ADD R9, R9, R4
  ADD R9, R9, R5
  ADD R9, R9, R6
  ADD R9, R9, R7
  ADD R9, R9, R8

  # Phase 4: Lookup next state from LUT[15]
  # LUT[15][current*9 + neighbor_count] = next_state
  MUL R10, R0, 9
  ADD R10, R10, R9
  LUT R0, 15, R10

  DJNZ R0, loop

HALT
