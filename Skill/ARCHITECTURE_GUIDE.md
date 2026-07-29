# GPTPU Architecture Implementation Guide

> This is the detailed reference for `gptpu-hardware-design` skill.
> Loaded on demand when deep implementation guidance is required.

## Repository Structure

```
gptpu/
├── rtl/
│   ├── top/gptpu_top.sv
│   ├── pe/
│   │   ├── pe_core.sv
│   │   ├── coupled_compute_engine.sv
│   │   ├── sram_512kb.sv
│   │   ├── vector_lane.sv
│   │   ├── scalar_ctrl.sv
│   │   ├── configurable_lut.sv
│   │   └── async_port_controller.sv
│   ├── noc/
│   │   ├── router_l0.sv
│   │   ├── router_l1.sv
│   │   ├── router_l2.sv
│   │   ├── async_fifo_2stage.sv
│   │   └── deadlock_free_arbiter.sv
│   ├── io/
│   │   ├── ddr_controller.sv
│   │   ├── stream_engine.sv
│   │   └── edge_io.sv
│   └── common/
│       ├── gptpu_pkg.sv
│       ├── fp8_types.sv
│       └── async_handshake.sv
├── sim/
│   ├── emulator/
│   └── testbench/
└── toolchain/
    ├── assembler/asm.py
    └── linker/microcode_linker.py
```

## Coding Conventions (SystemVerilog)

- **Module names**: snake_case (`pe_core`, `async_fifo_2stage`)
- **Parameters**: UPPER_SNAKE_CASE (`PE_GRID_X`, `SRAM_BANK_SIZE`)
- **Ports**: use `logic`. Async signals must have `_valid`, `_ready` suffixes.
- **Clocks**: prefix with `clk_pe`, `clk_noc` to indicate domain.
- **Reset**: async assert, sync de-assert local reset `rst_n` per module.

## Async Interface Standard

```systemverilog
typedef struct packed {
    logic [63:0] data;   // 8-wide FP8 = 64bit
    logic        valid;
    logic        ready;  // input from peer
} noc_channel_t;
```

- Data latches only when `valid && ready`.
- Always use `rtl/common/async_handshake.sv` template for FIFOs.

## Implementation Roadmap

1. **Phase 0**: `gptpu_pkg.sv`, `async_handshake.sv`, `async_fifo_2stage.sv`
2. **Phase 1**: `sram_512kb.sv`, `vector_lane.sv`, `scalar_ctrl.sv`, `configurable_lut.sv`
3. **Phase 2**: `coupled_compute_engine.sv`, microcode decoder
4. **Phase 3**: `router_l0.sv`, `async_port_controller.sv`, `pe_core.sv`
5. **Phase 4**: `router_l1.sv`, `router_l2.sv`
6. **Phase 5**: `ddr_controller.sv`, `stream_engine.sv`, `gptpu_top.sv`
7. **Phase 6**: Assembler, emulator, compiler

## Parameter Reference

```systemverilog
localparam int PE_GRID_X         = 16;
localparam int PE_GRID_Y         = 8;
localparam int SRAM_BANK0_SIZE   = 256*1024;  // 256KB
localparam int SRAM_BANK1_SIZE   = 128*1024;  // 128KB
localparam int SRAM_BANK2_SIZE   = 64*1024;   // 64KB (LUT + config)
localparam int SRAM_BANK3_SIZE   = 64*1024;   // 64KB (I/O + microcode)
localparam int VECTOR_LANE_WIDTH = 8;         // 8-wide FP8
localparam int MICROCODE_SIZE    = 8192;      // 8KB per SN
localparam int LUT_TABLES        = 16;
localparam int LUT_ENTRIES       = 256;
```

## Troubleshooting

- **Metastability in async FIFO**: Ensure 2-stage synchronizer is present. Run CDC checks.
- **LUT data race**: SWAPL is a selector switch, not a memory copy. Keep glitch-free.
- **MoE bandwidth starvation**: Fix DDR prefetch strategy, not RTL structure.
- **Area overrun**: This is a process-node/SRAM-macro issue, not an RTL topology issue.
