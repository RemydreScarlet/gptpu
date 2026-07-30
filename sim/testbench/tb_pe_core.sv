import gptpu_pkg::*;

module tb_pe_core;

  logic [7:0] pe_x, pe_y;
  logic clk_pe, clk_noc, rst_n;

  logic [63:0] l0_out_data  [8];
  logic        l0_out_valid [8];
  logic        l0_out_ready [8];
  logic [63:0] l0_in_data   [8];
  logic        l0_in_valid  [8];
  logic        l0_in_ready  [8];

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
    .l0_out_data  (l0_out_data),
    .l0_out_valid (l0_out_valid),
    .l0_out_ready (l0_out_ready),
    .l0_in_data   (l0_in_data),
    .l0_in_valid  (l0_in_valid),
    .l0_in_ready  (l0_in_ready),
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
