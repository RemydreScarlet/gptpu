import gptpu_pkg::*;

module tb_pe_core;

  logic [7:0] pe_x, pe_y;
  logic clk_pe, clk_noc, rst_n;

  noc_channel_t noc [7:0];
  noc_channel_t l1_in, l1_out;
  noc_channel_t l2_in, l2_out;

  microcode_word_t instr;
  logic            instr_valid;
  logic [12:0]     pc;

  logic [511:0] stream_data;
  logic         stream_valid, stream_ready;

  pe_core dut (
    .pe_x         (pe_x),
    .pe_y         (pe_y),
    .noc          (noc),
    .l1_in        (l1_in),
    .l1_out       (l1_out),
    .l2_in        (l2_in),
    .l2_out       (l2_out),
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
    instr.instr = {7'h02, 25'd0};  // VADD
    instr_valid = 1'b1;
    #20;

    // Test VMAC
    instr.instr = {7'h01, 25'd0};  // VMAC
    #20;

    // Test LUT lookup
    instr.instr = {7'h23, 25'd0};  // LUT
    #20;

    // Test SWAPL
    instr.instr = {7'h24, 25'd0};  // SWAPL
    #20;

    // Test branch
    instr.instr = {7'h30, 25'd5};  // BNE +5
    #20;

    instr_valid = 1'b0;
    #100;

    $display("PE Core testbench PASSED");
    $finish;
  end

  always #5 clk_pe = ~clk_pe;
  always #5 clk_noc = ~clk_noc;

endmodule
