import gptpu_pkg::*;

// 2-stage (2-entry) asynchronous FIFO with Valid/Ready handshake on both
// domains. Write/read pointers are transported across clock domains as GRAY
// codes through two-flop synchronizers and decoded back to binary on the
// opposite domain. The fill level is computed on its own domain from the
// synchronized counterpart pointer, giving a correct full/empty decision. A
// 2-entry FIFO needs 2*DEPTH = 4 pointer states (PTR_W = 2 bits) to
// distinguish "full" (wptr = rptr + DEPTH) from "empty" (wptr == rptr).
module async_fifo_2stage #(
  parameter int DATA_WIDTH = 64
) (
  // Write side (clk_wr domain)
  input  logic [DATA_WIDTH-1:0] w_data,
  input  logic                  w_valid,
  output logic                  w_ready,

  // Read side (clk_rd domain)
  output logic [DATA_WIDTH-1:0] r_data,
  output logic                  r_valid,
  input  logic                  r_ready,

  // Per-domain clocks / async-assert reset
  input  logic                  clk_wr,
  input  logic                  clk_rd,
  input  logic                  rst_n_wr,
  input  logic                  rst_n_rd
);

  localparam int DEPTH = 2;
  localparam int STS_W = 2 * DEPTH;        // 4 pointer states
  localparam int PTR_W = $clog2(STS_W);    // 2 bits

  // --- Binary pointers (own domains) ---
  logic [PTR_W-1:0] wptr_q, rptr_q;

  // --- Gray codings ---
  logic [PTR_W-1:0] wptr_g, rptr_g;

  // --- Two-flop synchronizers (Gray) ---
  logic [PTR_W-1:0] rptr_sync1, rptr_sync2;   // r -> w
  logic [PTR_W-1:0] wptr_sync1, wptr_sync2;   // w -> r

  // --- Storage (2 entries) ---
  logic [DATA_WIDTH-1:0] mem[0:DEPTH-1];

  // --- Write pointer (clk_wr) ---
  always_ff @(posedge clk_wr or negedge rst_n_wr) begin
    if (!rst_n_wr)               wptr_q <= '0;
    else if (w_valid && w_ready) wptr_q <= wptr_q + 1'b1;
  end

  // --- Read pointer (clk_rd) ---
  always_ff @(posedge clk_rd or negedge rst_n_rd) begin
    if (!rst_n_rd)               rptr_q <= '0;
    else if (r_valid && r_ready) rptr_q <= rptr_q + 1'b1;
  end

  // --- Gray conversion ---
  assign wptr_g = (wptr_q >> 1) ^ wptr_q;
  assign rptr_g = (rptr_q >> 1) ^ rptr_q;

  // --- Synchronize read pointer into write domain ---
  always_ff @(posedge clk_wr or negedge rst_n_wr) begin
    if (!rst_n_wr) begin
      rptr_sync1 <= '0;
      rptr_sync2 <= '0;
    end else begin
      rptr_sync1 <= rptr_g;
      rptr_sync2 <= rptr_sync1;
    end
  end

  // --- Synchronize write pointer into read domain ---
  always_ff @(posedge clk_rd or negedge rst_n_rd) begin
    if (!rst_n_rd) begin
      wptr_sync1 <= '0;
      wptr_sync2 <= '0;
    end else begin
      wptr_sync1 <= wptr_g;
      wptr_sync2 <= wptr_sync1;
    end
  end

  // --- Gray -> binary decode of synchronized pointers ---
  function automatic logic [PTR_W-1:0] gray2bin(input logic [PTR_W-1:0] g);
    logic [PTR_W-1:0] b;
    b = g;
    for (int i = PTR_W-2; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  logic [PTR_W-1:0] rptr_bin_sync;   // read ptr seen in write domain
  logic [PTR_W-1:0] wptr_bin_sync;   // write ptr seen in read domain
  logic [PTR_W-1:0] fill_wr, fill_rd;

  assign rptr_bin_sync = gray2bin(rptr_sync2);
  assign wptr_bin_sync = gray2bin(wptr_sync2);

  // --- Fill level, own-domain arithmetic (STS_W wraparound) ---
  assign fill_wr = (wptr_q >= rptr_bin_sync) ? (wptr_q - rptr_bin_sync)
                                             : (PTR_W'(STS_W) - rptr_bin_sync + wptr_q);
  assign fill_rd = (wptr_bin_sync >= rptr_q) ? (wptr_bin_sync - rptr_q)
                                             : (PTR_W'(STS_W) - rptr_q + wptr_bin_sync);

  // --- Storage write (clk_wr) ---
  always_ff @(posedge clk_wr or negedge rst_n_wr) begin
    if (!rst_n_wr) begin
      for (int i = 0; i < DEPTH; i++) mem[i] <= '0;
    end else if (w_valid && w_ready)
      mem[wptr_q[$clog2(DEPTH)-1:0]] <= w_data;
  end

  // --- Combinational head-of-line read: rptr only advances on a pop, so the
  //     head word is stable while r_valid is asserted. No registered read
  //     data is used, so r_data never trails r_valid by a cycle. ---
  assign r_data = mem[rptr_q[$clog2(DEPTH)-1:0]];

  assign w_ready = (fill_wr < DEPTH);
  assign r_valid = (fill_rd != 0);

  `ifdef FIFO_DBG
  always_ff @(posedge clk_wr or negedge rst_n_wr) begin
    if (rst_n_wr && w_valid && w_ready)
      $display("[%0t] FIFO-WR clk_wr w_data=%h wptr=%0d", $time, w_data, wptr_q);
  end
  always_ff @(posedge clk_rd or negedge rst_n_rd) begin
    if (rst_n_rd && r_valid && r_ready)
      $display("[%0t] FIFO-RD clk_rd r_data=%h rptr=%0d", $time, r_data, rptr_q);
  end
  `endif

endmodule
