import gptpu_pkg::*;
import fp8_pkg::*;

// SCMP/status/branch RTL test.
// Mirrors the emulator semantics:
//   LDI R1,5; LDI R2,5; SCMP R1,R2 -> status=0
//   BEQ +3 -> taken (lands at PC=7 HALT)
// Verifies branches consume the SCMP status (not live ALU cmp).
module tb_status;
  microcode_word_t instr;
  logic            instr_valid;
  logic [12:0]     pc;
  logic [63:0]     l0_N_data, l0_E_data, l0_S_data, l0_W_data;
  logic            l0_N_valid, l0_E_valid, l0_S_valid, l0_W_valid;
  logic            l0_N_ready, l0_E_ready, l0_S_ready, l0_W_ready;
  logic [63:0]     l0_N_in_data, l0_E_in_data, l0_S_in_data, l0_W_in_data;
  logic            l0_N_in_valid, l0_E_in_valid, l0_S_in_valid, l0_W_in_valid;
  logic            l0_N_in_ready, l0_E_in_ready, l0_S_in_ready, l0_W_in_ready;
  logic [63:0]     l1_N_data, l1_E_data, l1_S_data, l1_W_data;
  logic            l1_N_valid, l1_E_valid, l1_S_valid, l1_W_valid;
  logic            l1_N_ready, l1_E_ready, l1_S_ready, l1_W_ready;
  logic [63:0]     l1_N_in_data, l1_E_in_data, l1_S_in_data, l1_W_in_data;
  logic            l1_N_in_valid, l1_E_in_valid, l1_S_in_valid, l1_W_in_valid;
  logic            l1_N_in_ready, l1_E_in_ready, l1_S_in_ready, l1_W_in_ready;
  logic [63:0]     l2_E_data, l2_W_data;
  logic            l2_E_valid, l2_W_valid;
  logic            l2_E_ready, l2_W_ready;
  logic [63:0]     l2_E_in_data, l2_W_in_data;
  logic            l2_E_in_valid, l2_W_in_valid;
  logic            l2_E_in_ready, l2_W_in_ready;
  logic [511:0]    stream_data;
  logic            stream_valid, stream_ready;
  logic            lut_write_en;
  logic [3:0]      lut_write_table;
  logic [7:0]      lut_write_addr;
  fp8_e4m3_t       lut_write_data;
  logic            test_inject_valid;
  logic [63:0]     test_inject_data;
  logic            test_inject_ready;
  logic [63:0]     test_eject_data;
  logic            test_eject_valid;
  logic            test_l1_valid, test_l2_valid;
  logic            clk_pe, clk_noc, rst_n;

  pe_core dut (
    .pe_x (8'd0), .pe_y (8'd0),
    .l0_N_data(l0_N_data), .l0_N_valid(l0_N_valid), .l0_N_ready(l0_N_ready),
    .l0_N_in_data(l0_N_in_data), .l0_N_in_valid(l0_N_in_valid), .l0_N_in_ready(l0_N_in_ready),
    .l0_E_data(l0_E_data), .l0_E_valid(l0_E_valid), .l0_E_ready(l0_E_ready),
    .l0_E_in_data(l0_E_in_data), .l0_E_in_valid(l0_E_in_valid), .l0_E_in_ready(l0_E_in_ready),
    .l0_S_data(l0_S_data), .l0_S_valid(l0_S_valid), .l0_S_ready(l0_S_ready),
    .l0_S_in_data(l0_S_in_data), .l0_S_in_valid(l0_S_in_valid), .l0_S_in_ready(l0_S_in_ready),
    .l0_W_data(l0_W_data), .l0_W_valid(l0_W_valid), .l0_W_ready(l0_W_ready),
    .l0_W_in_data(l0_W_in_data), .l0_W_in_valid(l0_W_in_valid), .l0_W_in_ready(l0_W_in_ready),
    .l1_N_data(l1_N_data), .l1_N_valid(l1_N_valid), .l1_N_ready(l1_N_ready),
    .l1_N_in_data(l1_N_in_data), .l1_N_in_valid(l1_N_in_valid), .l1_N_in_ready(l1_N_in_ready),
    .l1_E_data(l1_E_data), .l1_E_valid(l1_E_valid), .l1_E_ready(l1_E_ready),
    .l1_E_in_data(l1_E_in_data), .l1_E_in_valid(l1_E_in_valid), .l1_E_in_ready(l1_E_in_ready),
    .l1_S_data(l1_S_data), .l1_S_valid(l1_S_valid), .l1_S_ready(l1_S_ready),
    .l1_S_in_data(l1_S_in_data), .l1_S_in_valid(l1_S_in_valid), .l1_S_in_ready(l1_S_in_ready),
    .l1_W_data(l1_W_data), .l1_W_valid(l1_W_valid), .l1_W_ready(l1_W_ready),
    .l1_W_in_data(l1_W_in_data), .l1_W_in_valid(l1_W_in_valid), .l1_W_in_ready(l1_W_in_ready),
    .l2_E_data(l2_E_data), .l2_E_valid(l2_E_valid), .l2_E_ready(l2_E_ready),
    .l2_E_in_data(l2_E_in_data), .l2_E_in_valid(l2_E_in_valid), .l2_E_in_ready(l2_E_in_ready),
    .l2_W_data(l2_W_data), .l2_W_valid(l2_W_valid), .l2_W_ready(l2_W_ready),
    .l2_W_in_data(l2_W_in_data), .l2_W_in_valid(l2_W_in_valid), .l2_W_in_ready(l2_W_in_ready),
    .instr(instr), .instr_valid(instr_valid), .pc(pc),
    .stream_data(stream_data), .stream_valid(stream_valid), .stream_ready(stream_ready),
    .lut_write_en(lut_write_en), .lut_write_table(lut_write_table),
    .lut_write_addr(lut_write_addr), .lut_write_data(lut_write_data),
    .test_inject_valid(test_inject_valid), .test_inject_data(test_inject_data),
    .test_inject_ready(test_inject_ready), .test_eject_data(test_eject_data),
    .test_eject_valid(test_eject_valid), .test_l1_valid(test_l1_valid),
    .test_l2_valid(test_l2_valid),
    .clk_pe(clk_pe), .clk_noc(clk_noc), .rst_n(rst_n)
  );

  initial begin
    int step;
    clk_pe = 1'b0; clk_noc = 1'b0;
    rst_n = 1'b0;
    instr = '0; instr_valid = 1'b0;
    test_inject_valid = 1'b0; test_inject_data = '0;
    lut_write_en = 1'b0;
    stream_data = '0; stream_valid = 1'b0;
    l0_N_in_valid = 1'b0; l0_E_in_valid = 1'b0; l0_S_in_valid = 1'b0; l0_W_in_valid = 1'b0;
    l1_N_in_valid = 1'b0; l1_E_in_valid = 1'b0; l1_S_in_valid = 1'b0; l1_W_in_valid = 1'b0;
    l2_E_in_valid = 1'b0; l2_W_in_valid = 1'b0;
    #50 rst_n = 1'b1;
    #20;

    // LDI R1, 5
    instr.instr = {7'h22, 25'((1 << 20) | 5)}; instr_valid = 1'b1; @(posedge clk_pe); #1;
    $display("step LDI1 done pc=%0d", pc);
    // LDI R2, 5
    instr.instr = {7'h22, 25'((2 << 20) | 5)}; @(posedge clk_pe); #1;
    $display("step LDI2 done pc=%0d", pc);
    // SCMP R1, R2 (equal -> status 0)
    instr.instr = {7'h17, 25'(1) | (2 << 3)}; @(posedge clk_pe); #1;
    $display("step SCMP done pc=%0d", pc);
    // BEQ +3: taken -> branch target pc = 3+1+3 = 7 (skips pc 4,5,6).
    // The three following NOPs execute at pc 7,8,9; HALT lands at pc 10 and
    // freezes pc there. (If the branch were NOT taken, HALT would freeze at 7.)
    instr.instr = {7'h31, 25'd3}; @(posedge clk_pe); #1;
    $display("step BEQ done pc=%0d", pc);

    // NOP (PC=4)
    instr.instr = {7'h00, 25'd0}; @(posedge clk_pe); #1;
    $display("step NOP done pc=%0d", pc);
    // NOP (PC=5)
    instr.instr = {7'h00, 25'd0}; @(posedge clk_pe); #1;
    $display("step NOP done pc=%0d", pc);
    // NOP (PC=6)
    instr.instr = {7'h00, 25'd0}; @(posedge clk_pe); #1;
    $display("step NOP done pc=%0d", pc);
    // HALT (PC=7)
    instr.instr = {7'h7F, 25'd0}; @(posedge clk_pe); #1;
    $display("step HALT done pc=%0d", pc);

    instr_valid = 1'b0;
    #60;
    $display("final pc=%0d", pc);

    // Emulator ref: BEQ taken -> final PC at HALT = 10 (vs 7 if not taken)
    if (pc == 13'd10)
      $display("tb_status PASSED (BEQ taken, final PC=%0d)", pc);
    else
      $display("tb_status FAILED (final PC=%0d, exp 10)", pc);
    $finish;
  end

  always #5 clk_pe = ~clk_pe;
  always #5 clk_noc = ~clk_noc;

endmodule