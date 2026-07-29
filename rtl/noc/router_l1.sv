import gptpu_pkg::*;

module router_l1 (
  input  noc_channel_t port_in [3:0],  // N, E, S, W (expressway)
  output noc_channel_t port_out[3:0],

  input  logic [7:0] pe_x, pe_y,
  input  logic [7:0] dst_x, dst_y,

  input  noc_channel_t local_in,
  output noc_channel_t local_out,

  input  logic clk_noc,
  input  logic rst_n
);

  logic [7:0] dx, dy;
  logic x_done, y_done;

  assign dx = (dst_x > pe_x) ? dst_x - pe_x : pe_x - dst_x;
  assign dy = (dst_y > pe_y) ? dst_y - pe_y : pe_y - dst_y;
  assign x_done = (dst_x == pe_x);
  assign y_done = (dst_y == pe_y);

  // L1 routing: same dimensional order, skipping intermediate nodes
  logic [3:0] out_sel;

  always_comb begin
    out_sel = 4'd0;

    if (!x_done) begin
      if (dst_x > pe_x) out_sel[1] = 1'b1;  // E
      else              out_sel[3] = 1'b1;  // W
    end else if (!y_done) begin
      if (dst_y > pe_y) out_sel[2] = 1'b1;  // S
      else              out_sel[0] = 1'b1;  // N
    end
  end

  assign port_out[0] = port_in[0];
  assign port_out[1] = port_in[1];
  assign port_out[2] = port_in[2];
  assign port_out[3] = port_in[3];

  assign local_out = local_in;

endmodule
