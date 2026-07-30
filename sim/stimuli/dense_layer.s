# Dense layer: 8-wide element-wise MAC accumulation
# Y[i] = sum_{j=0..7} X[i] * W[i][j]
# Bank0[0x0000]: X input (1 line = 8 FP8 values)
# Bank1[0x0000..0x0038]: W weights (8 lines, within 9-bit addr_b range)
# Bank2[0x0000]: Y output
.equ X_ADDR, 0x0000
.equ W_ADDR, 0x0000
.equ Y_ADDR, 0x0000

.org 0
VMAC X_ADDR, W_ADDR
VMAC X_ADDR, W_ADDR+8
VMAC X_ADDR, W_ADDR+16
VMAC X_ADDR, W_ADDR+24
VMAC X_ADDR, W_ADDR+32
VMAC X_ADDR, W_ADDR+40
VMAC X_ADDR, W_ADDR+48
VMAC X_ADDR, W_ADDR+56
VMAC 0, 0, Y_ADDR             # writeback: acc -> Bank2[Y_ADDR]
HALT
