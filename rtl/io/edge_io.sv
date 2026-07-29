import gptpu_pkg::*;

module edge_io (
  // Grid boundary DDR interfaces
  input  logic [DDR_CACHE_LINE*8-1:0] edge_data_in [PE_GRID_Y-1:0],
  input  logic                        edge_valid [PE_GRID_Y-1:0],
  output logic                        edge_ready [PE_GRID_Y-1:0],

  // Stream engine
  input  logic [DDR_CACHE_LINE*8-1:0] stream_data,
  input  logic                         stream_valid,
  output logic                         stream_ready,

  // Clock & reset
  input  logic clk_io,
  input  logic rst_n
);

  // Aggregate grid boundary data into a single stream
  logic [PE_GRID_Y-1:0] valid_any;
  logic [7:0] sel_row;

  assign valid_any = edge_valid;

  // Round-robin selection of edge rows
  always_ff @(posedge clk_io or negedge rst_n) begin
    if (!rst_n)
      sel_row <= '0;
    else if (|valid_any) begin
      for (int i = 0; i < PE_GRID_Y; i++) begin
        if (valid_any[i]) begin
          sel_row <= i[7:0];
        end
      end
    end
  end

  // Pass through to stream engine
  assign stream_data  = edge_data_in[sel_row];
  assign stream_valid = edge_valid[sel_row];
  assign stream_ready = 1'b1;

  // Per-row ready
  always_comb begin
    for (int i = 0; i < PE_GRID_Y; i++) begin
      edge_ready[i] = (i == sel_row) ? stream_ready : 1'b0;
    end
  end

endmodule
