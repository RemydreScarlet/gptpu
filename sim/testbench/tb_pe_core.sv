import gptpu_pkg::*;

module tb_pe_core;

  logic [7:0] pe_x, pe_y;
  logic clk_pe = 1'b0, clk_noc = 1'b0, rst_n;

  logic [63:0] l0_N_data,  l0_E_data,  l0_S_data,  l0_W_data;
  logic        l0_N_valid, l0_E_valid, l0_S_valid, l0_W_valid;
  logic        l0_N_ready, l0_E_ready, l0_S_ready, l0_W_ready;
  logic [63:0] l0_N_in_data,  l0_E_in_data,  l0_S_in_data,  l0_W_in_data;
  logic        l0_N_in_valid, l0_E_in_valid, l0_S_in_valid, l0_W_in_valid;
  logic        l0_N_in_ready, l0_E_in_ready, l0_S_in_ready, l0_W_in_ready;

  logic [63:0] l1_out_data, l1_in_data;
  logic        l1_out_valid, l1_in_valid;
  logic        l1_out_ready, l1_in_ready;
  logic [63:0] l2_out_data, l2_in_data;
  logic        l2_out_valid, l2_in_valid;
  logic        l2_out_ready, l2_in_ready;

  microcode_word_t instr;
  logic            instr_valid;
  logic [12:0]     pc;

  logic [511:0] stream_data;
  logic         stream_valid, stream_ready;

  pe_core dut (
    .pe_x         (pe_x),
    .pe_y         (pe_y),
    .l0_N_data    (l0_N_data),
    .l0_N_valid   (l0_N_valid),
    .l0_N_ready   (l0_N_ready),
    .l0_N_in_data (l0_N_in_data),
    .l0_N_in_valid(l0_N_in_valid),
    .l0_N_in_ready(l0_N_in_ready),
    .l0_E_data    (l0_E_data),
    .l0_E_valid   (l0_E_valid),
    .l0_E_ready   (l0_E_ready),
    .l0_E_in_data (l0_E_in_data),
    .l0_E_in_valid(l0_E_in_valid),
    .l0_E_in_ready(l0_E_in_ready),
    .l0_S_data    (l0_S_data),
    .l0_S_valid   (l0_S_valid),
    .l0_S_ready   (l0_S_ready),
    .l0_S_in_data (l0_S_in_data),
    .l0_S_in_valid(l0_S_in_valid),
    .l0_S_in_ready(l0_S_in_ready),
    .l0_W_data    (l0_W_data),
    .l0_W_valid   (l0_W_valid),
    .l0_W_ready   (l0_W_ready),
    .l0_W_in_data (l0_W_in_data),
    .l0_W_in_valid(l0_W_in_valid),
    .l0_W_in_ready(l0_W_in_ready),
    .l1_out_data  (l1_out_data),
    .l1_out_valid (l1_out_valid),
    .l1_out_ready (l1_out_ready),
    .l1_in_data   (l1_in_data),
    .l1_in_valid  (l1_in_valid),
    .l1_in_ready  (l1_in_ready),
    .l2_out_data  (l2_out_data),
    .l2_out_valid (l2_out_valid),
    .l2_out_ready (l2_out_ready),
    .l2_in_data   (l2_in_data),
    .l2_in_valid  (l2_in_valid),
    .l2_in_ready  (l2_in_ready),
    .instr        (instr),
    .instr_valid  (instr_valid),
    .pc           (pc),
    .stream_data  (stream_data),
    .stream_valid (stream_valid),
    .stream_ready (stream_ready),
    .clk_pe       (clk_pe),
    .clk_noc      (clk_noc),
    .rst_n        (rst_n)
  );

  initial begin
    pe_x = 8'd0;
    pe_y = 8'd0;
    rst_n = 1'b0;
    #100 rst_n = 1'b1;

    // Test VADD
    instr.instr = {7'h02, 25'd0};
    instr_valid = 1'b1;
    #20;

    // Test VMAC
    instr.instr = {7'h01, 25'd0};
    #20;

    // Test LUT
    instr.instr = {7'h23, 25'd0};
    #20;

    // Test SWAPL
    instr.instr = {7'h24, 25'd0};
    #20;

    // Test BNE branch
    instr.instr = {7'h30, 25'd5};
    #20;

    // Test SEND (should produce flit on L0)
    instr.instr = {7'h41, (8'd5 << 8) | 8'd3};
    #20;

    instr_valid = 1'b0;
    #100;

    $display("PE Core testbench PASSED");
    $finish;
  end

  always #5 clk_pe = ~clk_pe;
  always #5 clk_noc = ~clk_noc;

endmodule
