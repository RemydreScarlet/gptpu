import gptpu_pkg::*;

// Testbench for edge_io: verifies (1) north-edge PE->DDR aggregation of
// PE_GRID_X 64-bit flits into a 1024-bit line, and (2) DDR->PE broadcast
// split of a 1024-bit line into two 512-bit SRAM-line words.
module tb_edge;
  logic [63:0]  edge_flit_in [PE_GRID_X-1:0];
  logic         edge_valid   [PE_GRID_X-1:0];
  logic         edge_ready   [PE_GRID_X-1:0];

  logic [DDR_CACHE_LINE*8-1:0] edge_write_data;
  logic                        edge_write_valid;
  logic                        edge_write_ready;

  logic [DDR_CACHE_LINE*8-1:0] stream_in_data;
  logic                        stream_in_valid;
  logic                        stream_in_ready;

  logic [SRAM_LINE_WIDTH-1:0]  pe_stream_data;
  logic                        pe_stream_valid;
  logic                        pe_stream_ready;

  logic clk_io = 1'b0, rst_n = 1'b1;
  integer errors = 0;

  edge_io dut (
    .edge_flit_in     (edge_flit_in),
    .edge_valid       (edge_valid),
    .edge_ready       (edge_ready),
    .edge_write_data  (edge_write_data),
    .edge_write_valid (edge_write_valid),
    .edge_write_ready (edge_write_ready),
    .stream_in_data   (stream_in_data),
    .stream_in_valid  (stream_in_valid),
    .stream_in_ready  (stream_in_ready),
    .pe_stream_data   (pe_stream_data),
    .pe_stream_valid  (pe_stream_valid),
    .pe_stream_ready  (pe_stream_ready),
    .clk_io           (clk_io),
    .rst_n            (rst_n)
  );

  always #5 clk_io = ~clk_io;

  // Watch for pipelined handshake errors
  always @(posedge clk_io) begin
    if (edge_write_valid && edge_write_ready) begin
      // late-check done in main initial; kept minimal
    end
  end

  initial begin
    // reset all drives
    stream_in_valid = 1'b0; stream_in_data = '0;
    pe_stream_ready = 1'b0;
    edge_write_ready = 1'b0;
    for (int i = 0; i < PE_GRID_X; i++) begin
      edge_flit_in[i] = '0;
      edge_valid[i] = 1'b0;
    end
    #10; rst_n = 1'b0; #10; rst_n = 1'b1; #10;

    // ===== North-edge aggregation test =====
    for (int i = 0; i < PE_GRID_X; i++) edge_flit_in[i] = 64'h1010_0000_0000_0000 + i;
    foreach (edge_valid[i]) edge_valid[i] = 1'b1;
    edge_write_ready = 1'b1;
    repeat (3) @(posedge clk_io); #1;

    if (edge_write_valid) begin
      // 16 flits packed: flit i -> bits [i*64 +: 64]
      integer ok = 1;
      for (int i = 0; i < PE_GRID_X; i++) begin
        if (edge_write_data[i*64 +: 64] !== (64'h1010_0000_0000_0000 + i)) ok = 0;
      end
      if (ok) $display("edge_io AGGR PASSED");
      else begin $display("edge_io AGGR FAILED (data mismatch)"); errors++; end
    end else begin
      $display("edge_io AGGR FAILED (no write_valid)"); errors++;
    end

    // release aggregation
    for (int i = 0; i < PE_GRID_X; i++) edge_valid[i] = 1'b0;
    @(posedge clk_io); #1;

    // ================= DDR -> PE broadcast =================
    stream_in_data = 1024'hBEEF_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_5555_4444_3333_2222_1111_AAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0001_CAFE_FACE_F00D_0002;
    stream_in_valid = 1'b1;
    pe_stream_ready = 1'b1;
    // first word should be lower 512 bits
    @(posedge clk_io); #1;
    if (!pe_stream_valid || pe_stream_data !== stream_in_data[511:0]) begin
      $display("edge_io BCST FAILED (word0)"); errors++;
    end else begin
      $display("edge_io BCST word0      = %0128x", pe_stream_data);
      $display("edge_io BCST expect  w0 = %0128x", stream_in_data[511:0]);
      // second word on next cycle
      @(posedge clk_io); #1;
      if (!pe_stream_valid || pe_stream_data !== stream_in_data[1023:512]) begin
        $display("edge_io BCST FAILED (word1)");
        errors++;
      end else begin
        $display("edge_io BCST word1 OK");
        $display("edge_io BCST PASSED");
      end
    end
    stream_in_valid = 1'b0;

    // ================= Combined: PE flits -> broadcast (round line) =================
    // optional

    if (errors == 0) $display("edge_io testbench PASSED");
    else              $display("edge_io testbench FAILED (%0d errors)", errors);
    $finish;
  end

endmodule