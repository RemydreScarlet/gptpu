import gptpu_pkg::*;

module edge_io (
  input  logic [DDR_CACHE_LINE*8-1:0] edge_data_in [PE_GRID_Y-1:0],
  input  logic                        edge_valid [PE_GRID_Y-1:0],
  output logic                        edge_ready [PE_GRID_Y-1:0],

  output logic [DDR_CACHE_LINE*8-1:0] edge_data_out [PE_GRID_Y-1:0],
  output logic                        edge_out_valid [PE_GRID_Y-1:0],
  input  logic                        edge_out_ready [PE_GRID_Y-1:0],

  input  logic [DDR_CACHE_LINE*8-1:0] stream_data,
  input  logic                         stream_valid,
  output logic                         stream_ready,

  output logic [DDR_CACHE_LINE*8-1:0] stream_out_data,
  output logic                         stream_out_valid,
  input  logic                         stream_out_ready,

  input  logic clk_io,
  input  logic rst_n
);

  logic [7:0] sel_row;

  always_ff @(posedge clk_io or negedge rst_n) begin
    if (!rst_n)
      sel_row <= '0;
    else if (|edge_valid)
      for (int i = 0; i < PE_GRID_Y; i++)
        if (edge_valid[i]) sel_row <= i[7:0];
  end

  // PE → DDR: aggregate from edge rows
  assign stream_out_data  = edge_data_in[sel_row];
  assign stream_out_valid = edge_valid[sel_row];

  always_comb begin
    for (int i = 0; i < PE_GRID_Y; i++)
      edge_ready[i] = (i == sel_row) ? stream_out_ready : 1'b0;
  end

  // DDR → PE: distribute to all edge rows
  always_comb begin
    for (int i = 0; i < PE_GRID_Y; i++) begin
      edge_data_out[i]   = stream_data;
      edge_out_valid[i]  = stream_valid;
    end
  end

  assign stream_ready = |edge_out_ready;

endmodule
