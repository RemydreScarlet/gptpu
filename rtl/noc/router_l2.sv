import gptpu_pkg::*;

module router_l2 (
  input  noc_channel_t port_in [1:0],
  output noc_channel_t port_out[1:0],
  input  logic [7:0] pe_x, pe_y,
  input  logic [7:0] dst_x, dst_y,
  input  noc_channel_t local_in,
  output noc_channel_t local_out,
  input  logic clk_noc,
  input  logic rst_n
);

  // SN boundary routing: compare SN IDs
  logic [7:0] sn_x, sn_y, dst_sn_x, dst_sn_y;
  assign sn_x = pe_x / 4;
  assign sn_y = pe_y / 4;

  always_comb begin
    dst_sn_x = dst_x / 4;
    dst_sn_y = dst_y / 4;

    // Port 0 = neighbor SN in X direction, Port 1 = neighbor SN in Y direction
    for (int p = 0; p < 2; p++) begin
      port_out[p] = port_in[p];
      port_in[p].ready = 1'b1;
    end
    local_out = local_in;
    local_in.ready = 1'b1;
  end

endmodule
