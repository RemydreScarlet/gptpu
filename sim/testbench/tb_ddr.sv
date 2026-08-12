import gptpu_pkg::*;

module tb_ddr;
  logic [DDR_BUS_WIDTH-1:0] ddr_bus;
  logic ddr_clk_p, ddr_clk_n, ddr_cke, ddr_cs_n;
  logic [1:0] ddr_bg, ddr_ba;
  logic [15:0] ddr_addr;
  logic ddr_ras_n, ddr_cas_n, ddr_we_n;

  logic        read_req_valid, read_req_ready; logic [31:0] read_req_addr;
  logic [1023:0] read_data_out; logic read_data_valid, read_data_ready;
  logic        write_req_valid, write_req_ready; logic [31:0] write_req_addr;
  logic [1023:0] write_data_in;
  logic [15:0] credit_available;
  logic        credit_consume;
  logic clk_ddr = 1'b0, rst_n = 1'b1;

  ddr_controller dut (
    .ddr_bus          (ddr_bus),
    .ddr_clk_p        (ddr_clk_p),
    .ddr_clk_n        (ddr_clk_n),
    .ddr_cke          (ddr_cke),
    .ddr_cs_n         (ddr_cs_n),
    .ddr_bg           (ddr_bg),
    .ddr_ba           (ddr_ba),
    .ddr_addr         (ddr_addr),
    .ddr_ras_n        (ddr_ras_n),
    .ddr_cas_n        (ddr_cas_n),
    .ddr_we_n         (ddr_we_n),
    .read_req_valid   (read_req_valid),
    .read_req_ready   (read_req_ready),
    .read_req_addr    (read_req_addr),
    .read_data_out    (read_data_out),
    .read_data_valid  (read_data_valid),
    .read_data_ready  (read_data_ready),
    .write_req_valid  (write_req_valid),
    .write_req_ready  (write_req_ready),
    .write_req_addr   (write_req_addr),
    .write_data_in    (write_data_in),
    .credit_available (credit_available),
    .credit_consume   (credit_consume),
    .clk_ddr          (clk_ddr),
    .rst_n            (rst_n)
  );

  ddr_model u_ddr (
    .ddr_bus    (ddr_bus),
    .ddr_clk_p  (ddr_clk_p),
    .ddr_cke    (ddr_cke),
    .ddr_cs_n   (ddr_cs_n),
    .ddr_bg     (ddr_bg),
    .ddr_ba     (ddr_ba),
    .ddr_addr   (ddr_addr),
    .ddr_ras_n  (ddr_ras_n),
    .ddr_cas_n  (ddr_cas_n),
    .ddr_we_n   (ddr_we_n)
  );

  always #5 clk_ddr = ~clk_ddr;

  logic [1023:0] wr_pattern;

  initial begin
    read_req_valid = 1'b0; read_req_addr = '0; read_data_ready = 1'b1;
    write_req_valid = 1'b0; write_req_addr = '0; write_data_in = '0;
    credit_available = 16'hFFFF;
    $dumpfile("/tmp/opencode/ddr2.vcd");
    $dumpvars(0, dut, u_ddr);
    #20; rst_n = 1'b0; #20; rst_n = 1'b1; #20;

    // --- Write a 1024-bit line to DDR ---
    for (int k = 0; k < 1024; k++) wr_pattern[k] = (k == 0) ? 1'b1 : ((k % 7) == 0); 
    write_data_in = wr_pattern;
    write_req_addr = 32'h0000_1000;
    write_req_valid = 1'b1;
    @(posedge clk_ddr); #1;
    // keep valid until accepted
    while (!write_req_ready) begin @(posedge clk_ddr); #1; end
    write_req_valid = 1'b0;
    // await controller returning to IDLE (~ write + precharge)
    repeat (16) @(posedge clk_ddr); #1;
    read_req_addr = 32'h0000_1000;
    read_req_valid = 1'b1;
    @(posedge clk_ddr); #1;
    while (!read_req_ready && !read_data_valid) begin @(posedge clk_ddr); #1; end
    read_req_valid = 1'b0;
    while (!read_data_valid) begin @(posedge clk_ddr); #1; end
    #1;
    $display("DDR read_data_out = %0128x", read_data_out);
    if (read_data_out == wr_pattern) begin
      $display("DDR controller+model testbench PASSED");
    end else begin
      $display("DDR controller+model testbench FAILED");
    end
    $finish;
  end

endmodule