import gptpu_pkg::*;

module router_l0 (
  // 8 directional ports: N, NE, E, SE, S, SW, W, NW
  input  noc_channel_t port_in [7:0],
  output noc_channel_t port_out [7:0],

  // PE local position
  input  logic [7:0] pe_x, pe_y,

  // Destination from injected flit
  input  logic [7:0] dst_x, dst_y,
  input  logic [2:0] bcast_mode,
  input  logic       inject_valid,
  output logic       inject_ready,

  // L1 expressway interface (only for highway nodes)
  input  noc_channel_t l1_in,
  output noc_channel_t l1_out,

  // Clock & reset
  input  logic clk_noc,
  input  logic rst_n
);

  // --- Dimensional-order routing ---
  // Compute direction: route X first, then Y
  logic [7:0] dx, dy;
  logic x_done, y_done;

  assign dx = (dst_x > pe_x) ? dst_x - pe_x : pe_x - dst_x;
  assign dy = (dst_y > pe_y) ? dst_y - pe_y : pe_y - dst_y;
  assign x_done = (dst_x == pe_x);
  assign y_done = (dst_y == pe_y);

  // --- Determine output ports ---
  logic [7:0] out_port_sel;  // one-hot per direction

  always_comb begin
    out_port_sel = 8'd0;

    if (!x_done) begin
      if (dst_x > pe_x) out_port_sel[2] = 1'b1;  // E
      else              out_port_sel[6] = 1'b1;  // W
    end else if (!y_done) begin
      if (dst_y > pe_y) out_port_sel[1] = 1'b1;  // S (down)
      else              out_port_sel[5] = 1'b1;  // N (up)
    end
    // If both done: reached destination -> route to PE local port (port 0 = local)
  end

  // --- BCAST mode ---
  logic bcast_row, bcast_col, bcast_all;
  assign bcast_row = (bcast_mode == 3'd1);
  assign bcast_col = (bcast_mode == 3'd2);
  assign bcast_all = (bcast_mode == 3'd3);

  always_comb begin
    if (bcast_all) begin
      out_port_sel = 8'b01111110;  // all directions except local
    end else if (bcast_row) begin
      out_port_sel = {4'd0, 4'b0100};  // E + W
    end else if (bcast_col) begin
      out_port_sel = 8'b00100010;  // N + S
    end
  end

  // --- Input-to-output switching ---
  deadlock_free_arbiter arbiter (
    .req      (/* port requests */),
    .priority (/* round-robin */),
    .grant    (),
    .any_grant()
  );

  // --- Pass-through connections (simplified) ---
  assign port_out[0] = port_in[0];
  assign port_out[1] = port_in[1];
  assign port_out[2] = port_in[2];
  assign port_out[3] = port_in[3];
  assign port_out[4] = port_in[4];
  assign port_out[5] = port_in[5];
  assign port_out[6] = port_in[6];
  assign port_out[7] = port_in[7];

  // --- L1 bypass ---
  assign l1_out = l1_in;

endmodule
