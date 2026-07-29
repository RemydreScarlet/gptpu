import gptpu_pkg::*;

module router_l2 (
  input  noc_channel_t port_in [1:0],  // SN boundary ports
  output noc_channel_t port_out[1:0],

  input  logic [7:0] pe_x, pe_y,
  input  logic [7:0] dst_x, dst_y,

  input  noc_channel_t local_in,
  output noc_channel_t local_out,

  input  logic clk_noc,
  input  logic rst_n
);

  logic [7:0] dx, dy;

  assign dx = (dst_x > pe_x) ? dst_x - pe_x : pe_x - dst_x;
  assign dy = (dst_y > pe_y) ? dst_y - pe_y : pe_y - dst_y;

  assign port_out[0] = port_in[0];
  assign port_out[1] = port_in[1];
  assign local_out = local_in;

endmodule
