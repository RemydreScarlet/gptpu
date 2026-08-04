RTL_DIR  := ../rtl
TB_DIR   := testbench
BUILD    := build

COMMON   := $(RTL_DIR)/common/gptpu_pkg.sv \
            $(RTL_DIR)/common/fp8_types.sv \
            $(RTL_DIR)/common/async_handshake.sv \
            $(RTL_DIR)/common/async_fifo_2stage.sv
NOC      := $(RTL_DIR)/noc/deadlock_free_arbiter.sv \
            $(RTL_DIR)/noc/router_l0.sv \
            $(RTL_DIR)/noc/router_l1.sv \
            $(RTL_DIR)/noc/router_l2.sv
PE_SRAM  := $(RTL_DIR)/pe/sram_512kb.sv
PE_VL    := $(RTL_DIR)/pe/vector_lane.sv
PE_LUT   := $(RTL_DIR)/pe/configurable_lut.sv
PE_SCAL  := $(RTL_DIR)/pe/scalar_ctrl.sv
PE_CCE   := $(RTL_DIR)/pe/coupled_compute_engine.sv
PE_APC   := $(RTL_DIR)/pe/async_port_controller.sv
PE_TOP   := $(RTL_DIR)/pe/pe_core.sv
IO       := $(RTL_DIR)/io/ddr_controller.sv \
            $(RTL_DIR)/io/stream_engine.sv \
            $(RTL_DIR)/io/edge_io.sv

PE_ALL   := $(PE_SRAM) $(PE_VL) $(PE_LUT) $(PE_SCAL) $(PE_CCE) $(PE_APC) $(PE_TOP)

IVERILOG := iverilog -g2012 -Wall

.PHONY: all unit clean

all: unit

unit: $(BUILD) tb_async_fifo tb_router tb_lut_swap tb_pe_core tb_top

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/tb_async_fifo.vvp: $(COMMON) $(TB_DIR)/tb_async_fifo.sv
	$(IVERILOG) -o $@ $^

$(BUILD)/tb_router.vvp: $(COMMON) $(NOC) $(TB_DIR)/tb_router.sv
	$(IVERILOG) -o $@ $^

$(BUILD)/tb_lut_swap.vvp: $(RTL_DIR)/common/gptpu_pkg.sv $(RTL_DIR)/common/fp8_types.sv $(PE_LUT) $(TB_DIR)/tb_lut_swap.sv
	$(IVERILOG) -o $@ $^

$(BUILD)/tb_pe_core.vvp: $(COMMON) $(NOC) $(PE_ALL) $(TB_DIR)/tb_pe_core.sv
	$(IVERILOG) -o $@ $^

$(BUILD)/tb_top.vvp: $(COMMON) $(NOC) $(PE_ALL) $(IO) $(RTL_DIR)/top/gptpu_top.sv $(TB_DIR)/tb_top_moe_layer.sv
	$(IVERILOG) -o $@ $^

tb_async_fifo: $(BUILD)/tb_async_fifo.vvp
	vvp $<

tb_router: $(BUILD)/tb_router.vvp
	vvp $<

tb_lut_swap: $(BUILD)/tb_lut_swap.vvp
	vvp $<

tb_pe_core: $(BUILD)/tb_pe_core.vvp
	vvp $<

tb_top: $(BUILD)/tb_top.vvp
	vvp $<

clean:
	rm -rf $(BUILD)
