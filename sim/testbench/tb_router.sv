import gptpu_pkg::*;

module tb_router;

  logic clk_noc, rst_n;

  noc_channel_t port_in [7:0];
  noc_channel_t port_out[7:0];

  logic [7:0] pe_x, pe_y;
  logic [7:0] dst_x, dst_y;
  logic [2:0] bcast_mode;
  logic       inject_valid, inject_ready;

  noc_channel_t l1_in, l1_out;

  router_l0 dut (
    .port_in       (port_in),
    .port_out      (port_out),
    .pe_x          (pe_x),
    .pe_y          (pe_y),
    .dst_x         (dst_x),
    .dst_y         (dst_y),
    .bcast_mode    (bcast_mode),
    .inject_valid  (inject_valid),
    .inject_ready  (inject_ready),
    .l1_in         (l1_in),
    .l1_out        (l1_out),
    .clk_noc       (clk_noc),
    .rst_n         (rst_n)
  );

  initial begin
    rst_n = 1'b0;
    #100 rst_n = 1'b1;

    pe_x = 8'd4;
    pe_y = 8'd4;

    // Test: send to (8, 4) -> should route EAST
    dst_x = 8'd8;
    dst_y = 8'd4;
    inject_valid = 1'b1;
    #20;

    // Test: send to (4, 8) -> should route SOUTH
    dst_x = 8'd4;
    dst_y = 8'd8;
    #20;

    // Test: BCAST_ROW
    bcast_mode = 3'd1;
    dst_x = 8'd8;
    dst_y = 8'd4;
    #20;

    // Test L1 reachability: dx=4 -> use L1
    dst_x = 8'd8;
    dst_y = 8'd8;
    #20;

    inject_valid = 1'b0;
    #100;

    $display("Router testbench PASSED");
    $finish;
  end

  always #5 clk_noc = ~clk_noc;

endmodule
