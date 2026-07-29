import gptpu_pkg::*;

module async_fifo_2stage #(
  parameter int DATA_WIDTH = 64
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

  // --- 2-stage FIFO storage ---
  logic [DATA_WIDTH-1:0] fifo [1:0];
  logic [1:0] wr_ptr, rd_ptr;
  logic full, empty;

  // --- Gray-coded pointers for CDC ---
  logic [1:0] wr_ptr_gray, wr_ptr_gray_sync;
  logic [1:0] rd_ptr_gray, rd_ptr_gray_sync;

  // --- Write logic ---
  always_ff @(posedge clk_wr or negedge rst_n_wr) begin
    if (!rst_n_wr) begin
      wr_ptr <= 2'b00;
    end else if (w_valid && !full) begin
      fifo[wr_ptr] <= w_data;
      wr_ptr <= wr_ptr + 1;
    end
  end

  assign full   = (wr_ptr_gray_sync == ~rd_ptr_gray[1:1] ? {~rd_ptr_gray[1], rd_ptr_gray[0]} : 2'b0) == wr_ptr;
  assign w_ready = !full;

  // --- Read logic ---
  always_ff @(posedge clk_rd or negedge rst_n_rd) begin
    if (!rst_n_rd) begin
      rd_ptr <= 2'b00;
    end else if (r_ready && !empty) begin
      rd_ptr <= rd_ptr + 1;
    end
  end

  assign r_data = fifo[rd_ptr];
  assign empty  = (rd_ptr == wr_ptr_gray_sync);
  assign r_valid = !empty;

  // -- Pointer Gray encoding & synchronization ---
  always_comb begin
    wr_ptr_gray = wr_ptr ^ (wr_ptr >> 1);
    rd_ptr_gray = rd_ptr ^ (rd_ptr >> 1);
  end

  // Synchronize write pointer to read clock domain
  always_ff @(posedge clk_rd or negedge rst_n_rd) begin
    if (!rst_n_rd) begin
      wr_ptr_gray_sync <= 2'b00;
    end else begin
      wr_ptr_gray_sync <= wr_ptr_gray;
    end
  end

  // Synchronize read pointer to write clock domain
  always_ff @(posedge clk_wr or negedge rst_n_wr) begin
    if (!rst_n_wr) begin
      rd_ptr_gray_sync <= 2'b00;
    end else begin
      rd_ptr_gray_sync <= rd_ptr_gray;
    end
  end

endmodule
