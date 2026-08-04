import gptpu_pkg::*;

// Two-entry async (CDC) FIFO with Valid/Ready handshake.
// Pointers are transported across clock domains as GRAY codes through
// two-flop synchronizers; full/empty are evaluated in each own domain using
// the synchronized (gray -> binary decoded) counterpart pointer.
module async_fifo_2stage #(
  parameter int DATA_WIDTH = 64,
  parameter int DEPTH       = 2
) (
  // Write (sender) interface
  input  logic [DATA_WIDTH-1:0] w_data,
  input  logic                  w_valid,
  output logic                  w_ready,

  // Read (receiver) interface
  output logic [DATA_WIDTH-1:0] r_data,
  output logic                  r_valid,
  input  logic                  r_ready,

  // Write clock domain
  input  logic                  clk_wr,
  input  logic                  rst_n_wr,

  // Read clock domain
  input  logic                  clk_rd,
  input  logic                  rst_n_rd
);

  localparam int PTR_W = $clog2(DEPTH) + 1;
  localparam int STS_W = 2 * DEPTH;      // pointer state count = 2x depth

  // --- Pointer regs (binary) ---
  logic [PTR_W-1:0] wr_ptr, wr_ptr_next;
  logic [PTR_W-1:0] rd_ptr, rd_ptr_next;

  // --- Gray transports (2-flop syncs) ---
  logic [PTR_W-1:0] wr_gray,   wr_gray_s1, wr_gray_s2;  // into rd domain
  logic [PTR_W-1:0] rd_gray,   rd_gray_s1, rd_gray_s2;  // into wr domain
  logic [PTR_W-1:0] wr_ptr_sync, rd_ptr_sync;          // gray-decoded binaries

  // --- Fill-level signals (own-domain evaluations) ---
  logic [$clog2(DEPTH):0] fill_wr, fill_rd;

  // --- Storage ---
  logic [DATA_WIDTH-1:0] fifo [DEPTH-1:0];

  // Gray <-> binary conversions
  function automatic [PTR_W-1:0] bin2gray(input [PTR_W-1:0] b);
    return b ^ (b >> 1);
  endfunction
  function automatic [PTR_W-1:0] gray2bin(input [PTR_W-1:0] g);
    logic [PTR_W-1:0] b;
    b[PTR_W-1] = g[PTR_W-1];
    for (int i = PTR_W-2; i >= 0; i--)
      b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  // ==================== Write domain ====================
  always_ff @(posedge clk_wr or negedge rst_n_wr) begin
    if (!rst_n_wr) wr_ptr <= '0;
    else           wr_ptr <= wr_ptr_next;
  end

  always_comb begin
    wr_ptr_next = wr_ptr;
    if (w_valid && w_ready)
      wr_ptr_next = (wr_ptr == STS_W - 1) ? '0 : wr_ptr + 1;
  end

  always_ff @(posedge clk_wr or negedge rst_n_wr) begin
    if (rst_n_wr && w_valid && w_ready)
      fifo[wr_ptr[$clog2(DEPTH)-1:0]] <= w_data;
  end

  // 2-flop sync of read pointer (gray) into write domain
  always_ff @(posedge clk_wr or negedge rst_n_wr) begin
    if (!rst_n_wr) begin
      rd_gray_s1 <= '0;
      rd_gray_s2 <= '0;
    end else begin
      rd_gray_s1 <= rd_gray;
      rd_gray_s2 <= rd_gray_s1;
    end
  end
  assign rd_ptr_sync = gray2bin(rd_gray_s2);

  assign fill_wr = (wr_ptr >= rd_ptr_sync) ? (wr_ptr - rd_ptr_sync)
                                           : (STS_W - rd_ptr_sync + wr_ptr);
  assign w_ready = (fill_wr < DEPTH);

  // ==================== Read domain ====================
  always_ff @(posedge clk_rd or negedge rst_n_rd) begin
    if (!rst_n_rd) rd_ptr <= '0;
    else           rd_ptr <= rd_ptr_next;
  end

  always_comb begin
    rd_ptr_next = rd_ptr;
    if (r_ready && r_valid)
      rd_ptr_next = (rd_ptr == STS_W - 1) ? '0 : rd_ptr + 1;
  end

  assign r_data = fifo[rd_ptr[$clog2(DEPTH)-1:0]];

  // 2-flop sync of write pointer (gray) into read domain
  always_ff @(posedge clk_rd or negedge rst_n_rd) begin
    if (!rst_n_rd) begin
      wr_gray_s1 <= '0;
      wr_gray_s2 <= '0;
    end else begin
      wr_gray_s1 <= wr_gray;
      wr_gray_s2 <= wr_gray_s1;
    end
  end
  assign wr_ptr_sync = gray2bin(wr_gray_s2);

  assign fill_rd = (wr_ptr_sync >= rd_ptr) ? (wr_ptr_sync - rd_ptr)
                                           : (STS_W - rd_ptr + wr_ptr_sync);
  assign r_valid = (fill_rd != 0);

  // ==================== Gray encoders ====================
  always_comb begin
    wr_gray = bin2gray(wr_ptr);
    rd_gray = bin2gray(rd_ptr);
  end

endmodule
