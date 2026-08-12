import gptpu_pkg::*;

// Edge I/O bridge between the DDR stream path and the PE grid.
//
//  PE -> DDR: the north grid boundary (y=0) presents one 64-bit L0 flit per
//             PE column (PE_GRID_X columns).  edge_io aggregates PE_GRID_X
//             flits into one 1024-bit cache line and hands it to the stream
//             engine for the STREAM.S write path.
//  DDR -> PE: the 1024-bit cache line from the stream engine is broadcast to
//             the PE stream as 512-bit SRAM-line words (2 words per line).
module edge_io (
  // North-edge L0 flit inputs (one per PE column)
  input  logic [63:0]      edge_flit_in [PE_GRID_X-1:0],
  input  logic             edge_valid [PE_GRID_X-1:0],
  output logic             edge_ready [PE_GRID_X-1:0],

  // Aggregated write line -> stream engine (1024-bit)
  output logic [DDR_CACHE_LINE*8-1:0] edge_write_data,
  output logic                        edge_write_valid,
  input  logic                        edge_write_ready,

  // Broadcast read line from the stream engine (1024-bit)
  input  logic [DDR_CACHE_LINE*8-1:0] stream_in_data,
  input  logic                        stream_in_valid,
  output logic                        stream_in_ready,

  // PE-facing broadcast stream (512-bit SRAM-line words)
  output logic [SRAM_LINE_WIDTH-1:0] pe_stream_data,
  output logic                       pe_stream_valid,
  input  logic                       pe_stream_ready,

  input  logic clk_io,
  input  logic rst_n
);

  // --- North-edge aggregation: latch each column's flit, assemble a line ---
  logic [63:0]  flit_reg [PE_GRID_X-1:0];
  logic [7:0]   col_cnt;
  logic         aggr_valid;

  always_ff @(posedge clk_io or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < PE_GRID_X; i++) flit_reg[i] <= '0;
      col_cnt    <= '0;
      aggr_valid <= 1'b0;
    end else begin
      for (int i = 0; i < PE_GRID_X; i++)
        if (edge_valid[i] && edge_ready[i])
          flit_reg[i] <= edge_flit_in[i];
      if (aggr_valid && edge_write_ready)
        aggr_valid <= 1'b0;
      if (!aggr_valid) begin
        // wait until every column has delivered one flit
        aggr_valid <= 1'b1;
        for (int i = 0; i < PE_GRID_X; i++)
          if (!edge_valid[i] || !edge_ready[i]) aggr_valid <= 1'b0;
      end
    end
  end

  // Column ready: accept a flit from column i only while assembling
  always_comb begin
    for (int i = 0; i < PE_GRID_X; i++)
      edge_ready[i] = !aggr_valid;
  end

  // Pack the 16 latched flits into one 1024-bit line (flit i -> bits [i*64 +: 64])
  always_comb begin
    for (int i = 0; i < PE_GRID_X; i++)
      edge_write_data[i*64 +: 64] = flit_reg[i];
  end
  assign edge_write_valid = aggr_valid;

  // --- DDR -> PE broadcast: split 1024-bit line into 2 x 512-bit words ---
  logic half;
  logic [1023:0] line_buf;

  always_ff @(posedge clk_io or negedge rst_n) begin
    if (!rst_n) begin
      half      <= 1'b0;
      line_buf  <= '0;
      pe_stream_valid <= 1'b0;
    end else begin
      pe_stream_valid <= 1'b0;
      if (stream_in_valid && stream_in_ready && !half) begin
        line_buf  <= stream_in_data;
        half      <= 1'b1;
        pe_stream_valid <= 1'b1;
        pe_stream_data  <= stream_in_data[511:0];
      end else if (half && pe_stream_ready) begin
        pe_stream_valid <= 1'b1;
        pe_stream_data  <= line_buf[1023:512];
        half            <= 1'b0;
      end
    end
  end
  assign stream_in_ready = !half;

endmodule