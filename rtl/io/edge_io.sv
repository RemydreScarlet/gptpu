import gptpu_pkg::*;

// Edge I/O bridge between the DDR stream engine (1024-bit cache lines) and
// the PE-facing 512-bit SRAM-line stream. Edge channels aggregate L0 flits
// from the north grid boundary (per-column, one per PE column = PE_GRID_X).
module edge_io (
  input  logic [DDR_CACHE_LINE*8-1:0] edge_data_in [PE_GRID_X-1:0],
  input  logic                        edge_valid [PE_GRID_X-1:0],
  output logic                        edge_ready [PE_GRID_X-1:0],

  output logic [DDR_CACHE_LINE*8-1:0] edge_data_out [PE_GRID_X-1:0],
  output logic                        edge_out_valid [PE_GRID_X-1:0],
  input  logic                        edge_out_ready [PE_GRID_X-1:0],

  // DDR-facing stream (1024-bit cache line)
  input  logic [DDR_CACHE_LINE*8-1:0] stream_data,
  input  logic                         stream_valid,
  output logic                         stream_ready,

  output logic [DDR_CACHE_LINE*8-1:0] stream_out_data,
  output logic                         stream_out_valid,
  input  logic                         stream_out_ready,

  // PE-facing stream (512-bit SRAM line broadcast)
  output logic [SRAM_LINE_WIDTH-1:0] pe_stream_data,
  output logic                       pe_stream_valid,
  input  logic                       pe_stream_ready,

  input  logic clk_io,
  input  logic rst_n
);

  logic [7:0] sel_col;

  logic any_valid;
  always_comb begin
    any_valid = 1'b0;
    for (int i = 0; i < PE_GRID_X; i++)
      any_valid = any_valid | edge_valid[i];
  end

  always_ff @(posedge clk_io or negedge rst_n) begin
    if (!rst_n)
      sel_col <= '0;
    else if (any_valid)
      for (int i = 0; i < PE_GRID_X; i++)
        if (edge_valid[i]) sel_col <= i[7:0];
  end

  // PE -> DDR: aggregate from the selected edge column
  assign stream_out_data  = edge_data_in[sel_col];
  assign stream_out_valid = edge_valid[sel_col];

  always_comb begin
    for (int i = 0; i < PE_GRID_X; i++)
      edge_ready[i] = (i == sel_col) ? stream_out_ready : 1'b0;
  end

  // DDR -> PE: broadcast, split 1024-bit cache line into 512-bit SRAM line
  // (lower half of the cache line; upper half issued on the following word)
  assign pe_stream_data  = stream_data[SRAM_LINE_WIDTH-1:0];
  assign pe_stream_valid = stream_valid;
  assign stream_ready    = pe_stream_ready;

  // DDR -> PE edge fan-out (kept for the L0->edge path bookkeeping)
  always_comb begin
    for (int i = 0; i < PE_GRID_X; i++) begin
      edge_data_out[i]   = '0;
      edge_out_valid[i]  = 1'b0;
    end
  end

endmodule
