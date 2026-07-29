---
name: gptpu-hardware-design
description: GPTPU (General Purpose Tensor Processing Unit) RTL implementation skill. Use when designing, verifying, or modifying SystemVerilog modules for the GPTPU architecture — including PE cores, NoC routers, DDR stream engines, microcode toolchain, or cycle-accurate emulator. Enforces GALS async mesh, memory-centric design, and layer-wise streaming constraints.
license: Proprietary
metadata:
  version: "0.1"
  arch_spec: "GPTPU_Architecture_Spec_v0.1.md"
  target_language: "SystemVerilog"
---

# GPTPU Hardware Design Skill

## When to Use This Skill

Activate this skill when the task involves any of the following:

- Writing or modifying RTL for GPTPU PE, router, SRAM, or I/O modules
- Implementing the ISA (39 instructions, 32-bit fixed length)
- Developing the cycle-accurate emulator or microcode assembler
- Verifying async FIFO, deadlock-free routing, or LUT swapping behavior
- Optimizing area/timing for the GALS 2D mesh architecture
- Porting workloads (MoE LLM, CNN, DNN, Cellular Automaton) to GPTPU microcode

If the task is unrelated to GPTPU hardware or toolchain, do not load the full references.

---

## Core Architectural Principles (Non-Negotiable)

1. **GALS (Globally Asynchronous, Locally Synchronous)**
   - Each PE has an independent local clock. No global clock tree.
   - Inter-PE communication is strictly via 2-stage async FIFO + Valid/Ready handshake.
   - Never introduce synchronous cross-clock bridges or a global reset tree.

2. **Memory-Centric**
   - SRAM wide-line (64B) → Vector ALU → SRAM wide-line is the primary datapath.
   - Do not revert to a traditional register-file-centric pipeline.
   - Bank 0 (256KB matrix tiles) and Bank 1 (128KB activation/KV) are the hot paths.

3. **Distance-Adaptive Routing**
   - Hardware-autonomous routing; microcode only specifies `(dst_x, dst_y)`.
   - Dimensional-order routing: resolve X completely before Y. This prevents deadlock.
   - L1 Expressway exists only at PEs where `(x%4==0 && y%4==0)`.

4. **Layer-Wise Streaming**
   - Weights and KV cache are streamed from DDR per layer, not stored on-chip entirely.
   - Credit-Based Flow Control generates backpressure automatically when SRAM is full.

---

## Before You Start: Checklist

- [ ] Read `AGENTS.md` in the project root for full coding conventions and module guidelines.
- [ ] Confirm which SKU (S/M/L/XL) the change targets; parameters live in `rtl/common/gptpu_pkg.sv`.
- [ ] Verify the ISA opcode space before adding new instructions (see `toolchain/assembler/asm.py`).
- [ ] Check if the change affects async timing; if so, plan CDC (Clock Domain Crossing) validation.

---

## Module-Specific Quick References

| Module | Key Constraint | Reference |
|--------|---------------|-----------|
| `pe_core.sv` | 4-bank SRAM, independent clocks, L0 always / L1+L2 conditional | See references/PE_GUIDE.md |
| `coupled_compute_engine.sv` | Per-PE PC (MIMD), shared SN-level 8KB microcode | See references/CCE_GUIDE.md |
| `router_l0/l1/l2.sv` | Dimensional-order, deadlock-free, distance-adaptive | See references/NOC_GUIDE.md |
| `configurable_lut.sv` | Active/Shadow dual-bank, SWAPL in 1 cycle glitch-free | See references/LUT_GUIDE.md |
| `ddr_controller.sv` | Credit-Based FC, 128B cache line, LPDDR5-6400 | See references/IO_GUIDE.md |

---

## Prohibited Changes

The following would destroy the GPTPU architecture. Never do them:

- Introducing a global clock or synchronous mesh
- Replacing Valid/Ready with AXI/Credit-direct protocols between PEs
- Abandoning dimensional-order routing
- Replacing SRAM banks with small register files
- Storing entire model weights on-chip (violates layer-wise streaming)

---

## Testing Requirements

After any RTL change, ensure these testbenches still pass:

- `tb_pe_core.sv` — arithmetic, LUT, branch, SRAM bank conflicts
- `tb_router.sv` — 8-way concurrent traffic, L1 reachability, deadlock freedom
- `tb_async_fifo.sv` — CDC metastability, full/empty corner cases
- `tb_lut_swap.sv` — SWAPL glitch-free switching

For integration: Conway's Life (CA), Dense DNN layer, MoE FFN layer.

---

## Toolchain & Emulator

- Assembler: `toolchain/assembler/asm.py` — opcode table is the source of truth
- Emulator: `sim/emulator/` — must match RTL memory map and ISA exactly
- Discrepancies between emulator and RTL should trigger a spec review before RTL changes

---

*For detailed implementation guidelines per module, see the `references/` directory.*
