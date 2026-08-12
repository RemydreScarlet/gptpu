import gptpu_pkg::*;

// Testbench for stream_engine.  All stimulus is set on a negedge of clk_io and
// all engine outputs (flopped at posedge) are sampled on a following negedge,
// so reading is race-free.
module tb_stream;
  logic        stream_v, stream_s;
  logic [31:0] stream_addr, stream_length;

  logic        read_req_valid, read_req_ready; logic [31:0] read_req_addr;
  logic [DDR_CACHE_LINE*8-1:0] read_data_in; logic read_data_valid, read_data_ready;
  logic [DDR_CACHE_LINE*8-1:0] edge_stream_out; logic edge_stream_out_valid; logic edge_stream_out_ready;

  logic [DDR_CACHE_LINE*8-1:0] edge_write_data; logic edge_write_valid, edge_write_ready;
  logic        write_req_valid, write_req_ready; logic [31:0] write_req_addr;
  logic [DDR_CACHE_LINE*8-1:0] write_data_out;
  logic [15:0] credit_available; logic credit_consume;

  logic clk_io = 1'b0, rst_n = 1'b1;
  integer errors = 0;

  stream_engine dut (
    .stream_v           (stream_v),
    .stream_s           (stream_s),
    .stream_addr        (stream_addr),
    .stream_length      (stream_length),
    .read_req_valid     (read_req_valid),
    .read_req_ready     (read_req_ready),
    .read_req_addr      (read_req_addr),
    .read_data_in       (read_data_in),
    .read_data_valid    (read_data_valid),
    .read_data_ready    (read_data_ready),
    .edge_stream_out    (edge_stream_out),
    .edge_stream_out_valid (edge_stream_out_valid),
    .edge_stream_out_ready  (edge_stream_out_ready),
    .edge_write_data    (edge_write_data),
    .edge_write_valid   (edge_write_valid),
    .edge_write_ready   (edge_write_ready),
    .write_req_valid    (write_req_valid),
    .write_req_ready    (write_req_ready),
    .write_req_addr     (write_req_addr),
    .write_data_out     (write_data_out),
    .credit_available   (credit_available),
    .credit_consume     (credit_consume),
    .clk_io             (clk_io),
    .rst_n              (rst_n)
  );

  always #5 clk_io = ~clk_io;
  assign read_req_ready = 1'b1;
  assign write_req_ready = 1'b1;

  initial begin
    stream_v = 1'b0; stream_s = 1'b0;
    stream_addr = '0; stream_length = '0;
    read_data_in = '0; read_data_valid = 1'b0;
    edge_write_data = '0; edge_write_valid = 1'b0;
    edge_stream_out_ready = 1'b1;
    #10; rst_n = 1'b0; #10; rst_n = 1'b1; #10;

    // ===================== STREAM.V (read, 2 lines) =====================
    stream_addr = 32'h0000_2000; stream_length = 32'd2;
    stream_v = 1'b1;                 // negedge here
    @(negedge clk_io); stream_v = 1'b0; // N0

    @(negedge clk_io); // N1: engine posted req0 (addr 0x2000) at last posedge
    if (read_req_addr !== 32'h0000_2000) begin
      $display("STREAM.V req0 addr FAIL got=%x", read_req_addr); errors++;
    end

    @(negedge clk_io); // N2: engine moved REQ->WAIT
    @(negedge clk_io); // N3: engine in WAIT, read_data_ready=1

    // present line0 data on the next posedge
    read_data_in = 1024'h0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F_0F0F;
    read_data_valid = 1'b1;
    @(negedge clk_io); // N4: engine sampled line0 at posedge -> forwards, valid_out=1
    read_data_valid = 1'b0;
    if (!edge_stream_out_valid || edge_stream_out !== read_data_in) begin
      $display("STREAM.V line0 forward FAIL"); errors++;
    end else $display("STREAM.V line0 OK");

    @(negedge clk_io); // N5: engine posted req1 addr = 0x2000+0x80
    if (read_req_addr !== (32'h0000_2000 + DDR_CACHE_LINE)) begin
      $display("STREAM.V req1 addr FAIL got=%x exp=%x", read_req_addr, 32'h0000_2000 + DDR_CACHE_LINE); errors++;
    end else $display("STREAM.V req1 addr OK");

    @(negedge clk_io); // N6: engine in WAIT (rdy high)
    read_data_in = 1024'hA5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5_A5A5;
    read_data_valid = 1'b1;
    @(negedge clk_io); // N7: sampled line1 -> forwarded
    read_data_valid = 1'b0;
    if (!edge_stream_out_valid) begin $display("STREAM.V line1 fwd FAIL"); errors++; end
    else $display("STREAM.V line1 OK");

    @(negedge clk_io); // N8: engine back to IDLE

    // ===================== STREAM_S (write, 1 line) =====================
    stream_addr = 32'h0000_4000; stream_length = 32'd1;
    stream_s = 1'b1;
    @(negedge clk_io); stream_s = 1'b0; // M0
    @(negedge clk_io); // M1: engine in S_WRITE, edge_write_ready=1
    if (!edge_write_ready) begin $display("STREAM.S no edge_write_ready"); errors++; end
    edge_write_data = 1024'hABCD_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000;
    edge_write_valid = 1'b1;
    @(negedge clk_io); // M2
    edge_write_valid = 1'b0;
    if (!write_req_valid) begin $display("STREAM.S no write_req"); errors++; end
    else begin
      if (write_req_addr !== 32'h0000_4000) begin $display("STREAM.S addr FAIL got=%x", write_req_addr); errors++; end
      if (write_data_out !== edge_write_data) begin $display("STREAM.S data FAIL"); errors++; end
      else $display("STREAM.S PASSED");
    end

    if (errors == 0) $display("stream_engine testbench PASSED");
    else              $display("stream_engine testbench FAILED (%0d errors)", errors);
    $finish;
  end

endmodule