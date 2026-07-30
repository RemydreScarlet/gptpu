import gptpu_pkg::*;

module tb_router;

  logic clk_noc, rst_n;

  noc_channel_t port_in [7:0];
  noc_channel_t port_out[7:0];

  logic [7:0] pe_x, pe_y;
  logic       inject_valid, inject_ready;
  logic [7:0] inject_dst_x, inject_dst_y;
  logic [2:0] inject_bcast_mode;
  logic [63:0]inject_data;
  logic       l1_offload_valid, l1_offload_ready;
  logic [7:0] l1_offload_dst_x, l1_offload_dst_y;
  logic [63:0]l1_offload_data;
  logic       is_highway_node;

  // Create flit with embedded routing: {dst_y, dst_x, mode, flags, payload}
  function automatic logic [63:0] make_flit(input logic [7:0] dy, dx,
                                            input logic [2:0] mode);
    return {dy, dx, mode, 5'd0, 40'd0};
  endfunction

  router_l0 dut (
    .port_in          (port_in),
    .port_out         (port_out),
    .pe_x             (pe_x),
    .pe_y             (pe_y),
    .inject_valid     (inject_valid),
    .inject_ready     (inject_ready),
    .inject_dst_x     (inject_dst_x),
    .inject_dst_y     (inject_dst_y),
    .inject_bcast_mode(inject_bcast_mode),
    .inject_data      (inject_data),
    .l1_offload_valid (l1_offload_valid),
    .l1_offload_ready (l1_offload_ready),
    .l1_offload_dst_x (l1_offload_dst_x),
    .l1_offload_dst_y (l1_offload_dst_y),
    .l1_offload_data  (l1_offload_data),
    .is_highway_node  (is_highway_node),
    .clk_noc          (clk_noc),
    .rst_n            (rst_n)
  );

  initial begin
    rst_n = 1'b0;
    #100 rst_n = 1'b1;

    // Clear all inputs
    for (int i = 0; i < 8; i++) begin
      port_in[i].valid = 1'b0;
      port_in[i].data  = '0;
    end
    inject_valid = 1'b0;
    inject_data  = '0;
    inject_dst_x = '0;
    inject_dst_y = '0;
    inject_bcast_mode = '0;
    is_highway_node = 1'b0;
    l1_offload_ready = 1'b0;
    #10;

    pe_x = 8'd4;
    pe_y = 8'd4;

    // Test 1: Inject to EAST (dest_x=8, dest_y=4)
    inject_dst_x = 8'd8;
    inject_dst_y = 8'd4;
    inject_bcast_mode = 3'd0;
    inject_data = make_flit(8'd4, 8'd8, 3'd0);
    inject_valid = 1'b1;
    #20;
    inject_valid = 1'b0;

    // Test 2: Transit from WEST (port 4) going EAST
    port_in[4].valid = 1'b1;
    port_in[4].data  = make_flit(8'd4, 8'd8, 3'd0);
    #20;
    port_in[4].valid = 1'b0;

    // Test 3: BCAST_ROW
    inject_dst_x = 8'd8;
    inject_dst_y = 8'd4;
    inject_bcast_mode = 3'd1;
    inject_data = make_flit(8'd4, 8'd8, 3'd1);
    inject_valid = 1'b1;
    #20;
    inject_valid = 1'b0;

    // Test 4: L1 offload (highway node, dx>=4)
    is_highway_node = 1'b1;
    pe_x = 8'd4; pe_y = 8'd4;
    inject_dst_x = 8'd12;
    inject_dst_y = 8'd4;
    inject_bcast_mode = 3'd0;
    inject_data = make_flit(8'd4, 8'd12, 3'd0);
    l1_offload_ready = 1'b1;
    inject_valid = 1'b1;
    #20;
    inject_valid = 1'b0;

    #100;
    $display("Router testbench PASSED");
    $finish;
  end

  always #5 clk_noc = ~clk_noc;

endmodule
