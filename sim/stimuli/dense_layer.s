# Dense MLP layer: Y = X @ W + B
# Bank 0: Input X (64 floats, 8 FP8 per line = 8 lines)
# Bank 1: Weights W (64x64 = 512 lines)
# Bank 2: Bias B + Output Y

.org 0

.equ X_ADDR,   0x0000
.equ W_ADDR,   0x1000
.equ B_ADDR,   0x2000
.equ Y_ADDR,   0x3000
.equ N,        64

# Outer product: for each output neuron j
LDI R0, 0          # output index

outer:
  LDI R1, 0        # inner loop counter
  LDI R2, 0        # accumulator state

  inner:
    # Load X[i] from Bank 0, W[i][j] from Bank 1
    VADD V0, X_ADDR+R1, 0     # load X line (use VADD as pseudo-LD)
    VADD V1, W_ADDR+R1*N+R0, 0  # load W line

    # Multiply-accumulate
    VMAC V0, V1, 0

    ADD R1, R1, 8
    SCMP R1, N
    BLT inner

  # Store result with bias
  VADD V0, B_ADDR+R0, 0
  VADD V0, V0, acc
  VADD Y_ADDR+R0, V0, 0

  ADD R0, R0, 8
  SCMP R0, N
  BLT outer

HALT
