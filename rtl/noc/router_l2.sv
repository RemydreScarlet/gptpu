import gptpu_pkg::*;

module router_l2 (
  // 2 links to adjacent SN-boundary highway nodes
  input  logic [63:0] port_in_data [1:0],
  input  logic        port_in_valid[1:0],
  output logic        port_in_ready[1:0],
  output logic [63:0] port_out_data [1:0],
  output logic        port_out_valid[1:0],
  input  logic        port_out_ready[1:0],

  // Local link to the attached PE
  input  logic [63:0] local_in_data,
  input  logic        local_in_valid,
  output logic        local_in_ready,
  output logic [63:0] local_out_data,
  output logic        local_out_valid,
  input  logic        local_out_ready,

  input  logic [7:0] pe_x, pe_y,
  input  logic clk_noc,
  input  logic rst_n
);

  // SN-boundary expressway: simple cut-through pass-through per port.
  genvar gi;
  generate
    for (gi = 0; gi < 2; gi++) begin : gen_pass
      assign port_out_valid[gi] = port_in_valid[gi];
      assign port_out_data[gi]  = port_in_data[gi];
      assign port_in_ready[gi]  = port_out_ready[gi];
    end
  endgenerate

  assign local_out_valid = local_in_valid;
  assign local_out_data  = local_in_data;
  assign local_in_ready  = local_out_ready;

endmodule