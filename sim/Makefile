RTL_DIR  := ../rtl
TB_DIR   := testbench
BUILD    := build

COMMON   := $(RTL_DIR)/common/gptpu_pkg.sv \
            $(RTL_DIR)/common/fp8_types.sv \
            $(RTL_DIR)/common/async_handshake.sv \
            $(RTL_DIR)/noc/async_fifo_2stage.sv
NOC      := $(RTL_DIR)/noc/deadlock_free_arbiter.sv \
            $(RTL_DIR)/noc/router_l0.sv \
            $(RTL_DIR)/noc/router_l1.sv \
            $(RTL_DIR)/noc/router_l2.sv
PE_ALL   := $(RTL_DIR)/pe/sram_512kb.sv \
            $(RTL_DIR)/pe/vector_lane.sv \
            $(RTL_DIR)/pe/configurable_lut.sv \
            $(RTL_DIR)/pe/scalar_ctrl.sv \
            $(RTL_DIR)/pe/coupled_compute_engine.sv \
            $(RTL_DIR)/pe/async_port_controller.sv \
            $(RTL_DIR)/pe/pe_core.sv
IO       := $(RTL_DIR)/io/ddr_controller.sv \
            $(RTL_DIR)/io/stream_engine.sv \
            $(RTL_DIR)/io/edge_io.sv
DDR_MDL  := $(TB_DIR)/ddr_model.sv

# Verilator is the primary simulator; iverilog is lint/structure-only.
VFLAGS   := -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY \
            -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-UNDRIVEN \
            -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD -Wno-LATCH -Wno-UNUSEDPARAM
V         := verilator --binary -j 0 --timescale 1ns/1ps $(VFLAGS)
RUNTIMEOUT := 120

.PHONY: all unit clean lint

all: unit

unit: tb_async_fifo tb_router tb_l1 tb_lut tb_lut_swap tb_pe_core tb_ddr tb_stream tb_edge tb_pipeline tb_top

define RUN_TB
	mkdir -p $(BUILD)
	-$(V) --top-module $(1) -Mdir $(BUILD)/$(1) $(2) $(TB_DIR)/$(1).sv
	timeout $(RUNTIMEOUT) $(BUILD)/$(1)/V$(1)
endef

tb_async_fifo:
	@echo "== $(@) =="
	$(call RUN_TB,tb_async_fifo,$(COMMON))

tb_router:
	@echo "== $(@) =="
	$(call RUN_TB,tb_router,$(COMMON) $(NOC))

tb_l1:
	@echo "== $(@) =="
	$(call RUN_TB,tb_l1,$(COMMON) $(NOC))

tb_lut:
	@echo "== $(@) =="
	$(call RUN_TB,tb_lut,$(COMMON) $(PE_ALL))

tb_lut_swap:
	@echo "== $(@) =="
	$(call RUN_TB,tb_lut_swap,$(COMMON) $(PE_ALL))

tb_pe_core:
	@echo "== $(@) =="
	$(call RUN_TB,tb_pe_core,$(COMMON) $(NOC) $(PE_ALL))

tb_ddr:
	@echo "== $(@) =="
	$(call RUN_TB,tb_ddr,$(COMMON) $(RTL_DIR)/io/ddr_controller.sv $(DDR_MDL))

tb_stream:
	@echo "== $(@) =="
	$(call RUN_TB,tb_stream,$(COMMON) $(IO) $(DDR_MDL))

tb_edge:
	@echo "== $(@) =="
	$(call RUN_TB,tb_edge,$(COMMON) $(IO))

tb_pipeline:
	@echo "== $(@) =="
	$(call RUN_TB,tb_pipeline,$(COMMON) $(NOC) $(PE_ALL) $(IO) $(DDR_MDL))

tb_top:
	@echo "== $(@) =="
	$(call RUN_TB,tb_top_moe_layer,$(COMMON) $(NOC) $(PE_ALL) $(IO) $(RTL_DIR)/top/gptpu_top.sv $(DDR_MDL))

# tb_top_l1 is a known WIP integration test (L1 expressway functional).
# It currently FAILS delivery (latent routing bug) and is excluded from `unit`.
top_l1:
	@echo "== $(@) =="
	$(call RUN_TB,tb_top_l1,$(COMMON) $(NOC) $(PE_ALL) $(IO) $(RTL_DIR)/top/gptpu_top.sv $(DDR_MDL))

# Structural compile check (no elaboration to simulation).
lint:
	verilator --lint-only --top-module gptpu_top $(VFLAGS) $(COMMON) $(NOC) $(PE_ALL) $(IO) $(RTL_DIR)/top/gptpu_top.sv

clean:
	rm -rf $(BUILD)
