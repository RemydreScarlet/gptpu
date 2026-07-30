# MoE FFN layer: Y = sum(Expert_i(X) * Gate_i(X))
# Simplified: 4 experts, 8 PEs per expert

.equ EXPERT_0, 0
.equ EXPERT_1, 1
.equ EXPERT_2, 2
.equ EXPERT_3, 3

.org 0

# Each PE loads its expert weights via STREAM.V
STREAMV V0, DDR_ADDR_EXPERT, expert_size

# Forward pass through expert FFN
# Expert FFN: gate = SiLU(x @ W1), output = gate * (x @ W2)
# Layer 1: x @ W1
VADD V2, addr_x, 0          # load x
VMAC V2, addr_w1_0, 0       # x @ W1[0]
VMAC V2, addr_w1_1, 0       # x @ W1[1]
LUT V3, 6, V2               # SiLU gate

# Layer 2: x @ W2
VADD V4, addr_x, 0
VMAC V4, addr_w2_0, 0
VMAC V4, addr_w2_1, 0
VMUL V5, V4, V3             # gate * value

# Store expert output
VADD addr_out, V5, 0

# Send output to router PE (top-4 aggregation)
SEND V5, ROUTER_X, ROUTER_Y

HALT
