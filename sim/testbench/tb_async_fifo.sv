import gptpu_pkg::*;

module tb_async_fifo;

  logic clk_wr, clk_rd, rst_n;

  logic [63:0] w_data, r_data;
  logic        w_valid, w_ready;
  logic        r_valid, r_ready;

  async_fifo_2stage #(.DATA_WIDTH(64)) dut (
    .w_data   (w_data),
    .w_valid  (w_valid),
    .w_ready  (w_ready),
    .r_data   (r_data),
    .r_valid  (r_valid),
    .r_ready  (r_ready),
    .clk_wr   (clk_wr),
    .clk_rd   (clk_rd),
    .rst_n_wr (rst_n),
    .rst_n_rd (rst_n)
  );

  initial begin
    rst_n = 1'b0;
    #100 rst_n = 1'b1;

    // Write a word
    w_data = 64'hDEADBEEF;
    w_valid = 1'b1;
    @(posedge clk_wr);
    w_valid = 1'b0;

    // Read after CDC
    #30;
    r_ready = 1'b1;
    @(posedge clk_rd);
    r_ready = 1'b0;

    // Verify
    #10;
    assert (r_data == 64'hDEADBEEF) else $error("FIFO data mismatch");

    // Test full condition: write 3 words (depth=2, should stall)
    w_valid = 1'b1;
    w_data = 64'h1;
    @(posedge clk_wr);
    w_data = 64'h2;
    @(posedge clk_wr);
    w_data = 64'h3;
    @(posedge clk_wr);
    assert (!w_ready) else $error("FIFO should be full");
    w_valid = 1'b0;

    // Drain
    r_ready = 1'b1;
    #50;

    $display("Async FIFO testbench PASSED");
    $finish;
  end

  always #5 clk_wr = ~clk_wr;
  always #7 clk_rd = ~clk_rd;  // different frequency

endmodule
