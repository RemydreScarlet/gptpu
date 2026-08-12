import gptpu_pkg::*;

// Full DDR datapath integration: ddr_model + ddr_controller + stream_engine +
// edge_io.  Round trip: PE-grid flits -> edge_io aggregate -> STREAM.S write ->
// DDR; then STREAM.V read -> DDR -> edge_io broadcast -> PE SRAM words, and the
// two 512-bit words must re-assemble the original 1024-bit line.
module tb_pipeline;
  // ---- shared clock/reset for io domain (single domain in this TB) ----
  logic clk = 1'b0, rst_n = 1'b1;

  // ---- DDR bus between controller and model ----
  logic [DDR_BUS_WIDTH-1:0] ddr_bus;
  logic ddr_clk_p, ddr_clk_n, ddr_cke, ddr_cs_n;
  logic [1:0] ddr_bg, ddr_ba;
  logic [15:0] ddr_addr;
  logic ddr_ras_n, ddr_cas_n, ddr_we_n;

  // ---- stream engine <-> controller ----
  logic read_req_valid, read_req_ready; logic [31:0] read_req_addr;
  logic [DDR_CACHE_LINE*8-1:0] read_data_in; logic read_data_valid, read_data_ready;
  logic [DDR_CACHE_LINE*8-1:0] write_data_out; logic write_req_valid, write_req_ready; logic [31:0] write_req_addr;
  logic [15:0] credit_available; logic credit_consume;

  // ---- stream engine <-> edge_io ----
  logic [DDR_CACHE_LINE*8-1:0] edge_stream_out;
  logic edge_stream_out_valid, edge_stream_out_ready;
  logic [DDR_CACHE_LINE*8-1:0] edge_write_data;
  logic edge_write_valid, edge_write_ready;

  // ---- stream engine command decode (from CCE) ----
  logic stream_v, stream_s; logic [31:0] stream_addr, stream_length;

  // ---- edge_io <-> PE grid ----
  logic [63:0]  edge_flit_in [PE_GRID_X-1:0];
  logic         edge_valid   [PE_GRID_X-1:0];
  logic         edge_ready   [PE_GRID_X-1:0];
  logic [SRAM_LINE_WIDTH-1:0] pe_stream_data;
  logic pe_stream_valid, pe_stream_ready;

  ddr_controller ctrl (
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
    .read_data_out    (read_data_in),
    .read_data_valid  (read_data_valid),
    .read_data_ready  (read_data_ready),
    .write_req_valid  (write_req_valid),
    .write_req_ready  (write_req_ready),
    .write_req_addr   (write_req_addr),
    .write_data_in    (write_data_out),
    .credit_available (credit_available),
    .credit_consume   (credit_consume),
    .clk_ddr          (clk),
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

  stream_engine eng (
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
    .clk_io             (clk),
    .rst_n              (rst_n)
  );

  edge_io u_edge (
    .edge_flit_in     (edge_flit_in),
    .edge_valid       (edge_valid),
    .edge_ready       (edge_ready),
    .edge_write_data  (edge_write_data),
    .edge_write_valid (edge_write_valid),
    .edge_write_ready (edge_write_ready),
    .stream_in_data   (edge_stream_out),
    .stream_in_valid  (edge_stream_out_valid),
    .stream_in_ready  (edge_stream_out_ready),
    .pe_stream_data   (pe_stream_data),
    .pe_stream_valid  (pe_stream_valid),
    .pe_stream_ready  (pe_stream_ready),
    .clk_io           (clk),
    .rst_n            (rst_n)
  );

  always #5 clk = ~clk;
  assign ddr_clk_p = clk;
  assign ddr_clk_n = ~clk;
  assign ddr_cke = 1'b1;

  logic [1023:0] line_expected;

  initial begin
    integer errors = 0;
    // init
    stream_v = 1'b0; stream_s = 1'b0; stream_addr = '0; stream_length = '0;
    pe_stream_ready = 1'b1;
    for (int i = 0; i < PE_GRID_X; i++) begin
      edge_flit_in[i] = '0; edge_valid[i] = 1'b0;
    end
    #10; rst_n = 1'b0; #10; rst_n = 1'b1; #10;

    // ==================== STREAM.S: PE flits -> DDR ====================
    // build the expected 1024-bit line: flit i -> bits [i*64 +: 64]
    line_expected = '0;
    for (int i = 0; i < PE_GRID_X; i++) begin
      edge_flit_in[i] = 64'h0102_0304_0506_0700 + i;
      line_expected[i*64 +: 64] = edge_flit_in[i];
    end

    stream_addr = 32'h0000_1000; stream_length = 32'd1;
    stream_s = 1'b1;
    @(negedge clk); stream_s = 1'b0;
    // present all column flits
    for (int i = 0; i < PE_GRID_X; i++) edge_valid[i] = 1'b1;
    // let aggregation + write complete (~ write path latency)
    repeat (20) @(negedge clk);
    for (int i = 0; i < PE_GRID_X; i++) edge_valid[i] = 1'b0;
    repeat (8) @(negedge clk);

    // ==================== STREAM.V: DDR -> PE broadcast ====================
    // read back the same line; the 2 SRAM words must re-assemble it
    stream_addr = 32'h0000_1000; stream_length = 32'd1;
    stream_v = 1'b1;
    @(negedge clk); stream_v = 1'b0;

    // capture the two broadcast words
    begin
      integer guard = 0;
      while (!pe_stream_valid && guard < 100) begin @(negedge clk); guard++; end
      if (!pe_stream_valid) begin
        $display("PIPE read: no broadcast"); errors++;
      end else begin
        logic [1023:0] got;
        got = '0;
        got[511:0]   = pe_stream_data;
        @(negedge clk);            // advance to the word1 broadcast cycle
        if (!pe_stream_valid) begin
          $display("PIPE read: no word1"); errors++;
        end else begin
          got[1023:512] = pe_stream_data;
          if (got !== line_expected) begin
            $display("PIPE round-trip FAILED");
            $display("  exp=%0128x", line_expected);
            $display("  got=%0128x", got);
            errors++;
          end else $display("PIPE round-trip PASSED (line %0128x)", got);
        end
      end
    end

    if (errors == 0) $display("pipeline testbench PASSED");
    else              $display("pipeline testbench FAILED (%0d errors)", errors);
    $finish;
  end

endmodule