import gptpu_pkg::*;

// Wrapper that packs router_l1's unpacked port arrays so the testbench can
// read them reliably (Verilator's direct read of unpacked-array output port
// elements from the TB is unreliable in this setup).
module dut_l1 #(parameter P_X = 4, parameter P_Y = 4) (
  output logic [3:0]  out_valid,
  output logic [63:0] out_data0, out_data1, out_data2, out_data3,
  output logic        local_out_valid,
  output logic [63:0] local_out_data,
  output logic [3:0]  in_ready,
  output logic        local_in_ready,
  input  logic [63:0] in_data [3:0],
  input  logic        in_valid [3:0],
  input  logic [3:0]  out_ready,
  input  logic [63:0] local_in_data,
  input  logic        local_in_valid,
  input  logic        local_out_ready,
  input  logic clk_noc,
  input  logic rst_n
);
  logic [63:0] port_in_data [3:0];
  logic        port_in_valid[3:0];
  logic        port_in_ready[3:0];
  logic [63:0] port_out_data [3:0];
  logic        port_out_valid[3:0];
  logic        port_out_ready[3:0];
  logic [7:0]  pe_x, pe_y;

  assign pe_x = P_X[7:0];
  assign pe_y = P_Y[7:0];

  for (genvar qi = 3; qi >= 0; qi--) begin : g_outer_in
    assign port_in_data[qi]  = in_data[qi];
    assign port_in_valid[qi] = in_valid[qi];
    assign port_out_ready[qi] = out_ready[qi];
  end

  router_l1 u (
    .port_in_data   (port_in_data),
    .port_in_valid  (port_in_valid),
    .port_in_ready  (port_in_ready),
    .port_out_data  (port_out_data),
    .port_out_valid (port_out_valid),
    .port_out_ready (port_out_ready),
    .local_in_data  (local_in_data),
    .local_in_valid (local_in_valid),
    .local_in_ready (local_in_ready),
    .local_out_data (local_out_data),
    .local_out_valid(local_out_valid),
    .local_out_ready(local_out_ready),
    .pe_x           (pe_x),
    .pe_y           (pe_y),
    .clk_noc        (clk_noc),
    .rst_n          (rst_n)
  );

  assign out_valid   = {port_out_valid[3], port_out_valid[2],
                        port_out_valid[1], port_out_valid[0]};
  assign out_data0   = port_out_data[0];
  assign out_data1   = port_out_data[1];
  assign out_data2   = port_out_data[2];
  assign out_data3   = port_out_data[3];
  assign in_ready    = {port_in_ready[3], port_in_ready[2],
                        port_in_ready[1], port_in_ready[0]};
endmodule

module tb_l1;
  logic [3:0]  out_valid;
  logic [63:0] od0, od1, od2, od3;
  logic        local_out_valid;
  logic [63:0] local_out_data;
  logic [3:0]  in_ready;
  logic        local_in_ready;
  logic [63:0] in_data [3:0];
  logic        in_valid [3:0];
  logic [3:0]  out_ready;
  logic [63:0] local_in_data;
  logic        local_in_valid;
  logic        local_out_ready;
  logic clk_noc = 1'b0, rst_n = 1'b1;

  // P_N=0, P_E=1, P_S=2, P_W=3 ; tile = [4,7]x[4,7]
  dut_l1 #(.P_X(4), .P_Y(4)) dut (
    .out_valid      (out_valid),
    .out_data0      (od0), .out_data1(od1), .out_data2(od2), .out_data3(od3),
    .local_out_valid(local_out_valid),
    .local_out_data (local_out_data),
    .in_ready       (in_ready),
    .local_in_ready (local_in_ready),
    .in_data        (in_data),
    .in_valid       (in_valid),
    .out_ready      (out_ready),
    .local_in_data  (local_in_data),
    .local_in_valid (local_in_valid),
    .local_out_ready(local_out_ready),
    .clk_noc        (clk_noc),
    .rst_n          (rst_n)
  );

  always #5 clk_noc = ~clk_noc;

  task automatic flit(input logic [7:0] dx, input logic [7:0] dy, output logic [63:0] f);
    f = {dy, dx, 3'd0, 5'd0, 16'h0, 24'h0};
  endtask

  integer pass;
  initial begin
    pass = 0;
    for (int q = 0; q < 4; q++) begin
      in_valid[q] = 1'b0;
      in_data[q]  = '0;
    end
    out_ready = '0;
    local_in_valid = 1'b0;
    local_out_ready = 1'b1;
    #10;

    // T1: local offload dst(10,7) -> E (bit 1)
    local_in_data = {8'd7, 8'd10, 3'd0, 5'd0, 16'h0, 24'h0};
    local_in_valid = 1'b1;
    out_ready = 4'b1111;
    #2;
    $display("T1 local(10,7): out_valid=%b (bit1=E,expect 0010)", out_valid);
    if (out_valid == 4'b0010) pass++;
    local_in_valid = 1'b0;

    // T2: local offload dst(1,1) -> W (bit 3)
    local_in_data = {8'd1, 8'd1, 3'd0, 5'd0, 16'h0, 24'h0};
    local_in_valid = 1'b1;
    #2;
    $display("T2 local(1,1): out_valid=%b (bit3=W,expect 1000)", out_valid);
    if (out_valid == 4'b1000) pass++;
    local_in_valid = 1'b0;

    // T3: port N(0) in dst(5,5) inside tile -> local deliver
    in_valid[0] = 1'b1;
    in_data[0]  = {8'd5, 8'd5, 3'd0, 5'd0, 16'h0, 24'h0};
    #2;
    $display("T3 portN(5,5): local_out_valid=%0d(outside valid=%b)", local_out_valid, out_valid);
    if (local_out_valid == 1'b1 && out_valid == 4'b0000) pass++;
    in_valid[0] = 1'b0;

    // T4: port E(1) in dst(10,4): dx>7 -> E onward only, NOT local
    in_valid[1] = 1'b1;
    in_data[1]  = {8'd4, 8'd10, 3'd0, 5'd0, 16'h0, 24'h0};
    #2;
    $display("T4 portE(10,4): out_valid=%b(bit1,expect 0010) local_out=%0d(expect 0)", out_valid, local_out_valid);
    if (out_valid == 4'b0010 && local_out_valid == 1'b0) pass++;
    in_valid[1] = 1'b0;

    // T5: port W(3) in dst(7,7) inside tile -> local deliver
    in_valid[3] = 1'b1;
    in_data[3]  = {8'd7, 8'd7, 3'd0, 5'd0, 16'h0, 24'h0};
    #2;
    $display("T5 portW(7,7): local_out_valid=%0d(outside valid=%b)", local_out_valid, out_valid);
    if (local_out_valid == 1'b1 && out_valid == 4'b0000) pass++;
    in_valid[3] = 1'b0;

    if (pass == 5) $display("L1 router testbench PASSED (%0d/5)", pass);
    else            $display("L1 router testbench FAILED (%0d/5)", pass);
    $finish;
  end
endmodule