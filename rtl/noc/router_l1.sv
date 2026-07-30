import gptpu_pkg::*;

module router_l1 (
  input  noc_channel_t port_in [3:0],
  output noc_channel_t port_out[3:0],
  input  logic [7:0] pe_x, pe_y,
  input  logic [7:0] dst_x, dst_y,
  input  noc_channel_t local_in,
  output noc_channel_t local_out,
  input  logic clk_noc,
  input  logic rst_n
);

  localparam int P_N = 0, P_E = 1, P_S = 2, P_W = 3;

  // Dimension-order: X then Y
  logic [7:0] f_dst_x[4], f_dst_y[4];
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi++) begin : gen_f
      assign f_dst_x[gi] = port_in[gi].data[55:48];
      assign f_dst_y[gi] = port_in[gi].data[63:56];
    end
  endgenerate

  logic [3:0] route[4];
  logic [3:0] local_route;

  always_comb begin
    for (int p = 0; p < 4; p++) begin
      route[p] = 4'd0;
      if (port_in[p].valid) begin
        logic xd = (f_dst_x[p] == pe_x);
        logic yd = (f_dst_y[p] == pe_y);
        if (!xd) begin
          if (f_dst_x[p] > pe_x) route[p][P_E] = 1;
          else                    route[p][P_W] = 1;
        end else if (!yd) begin
          if (f_dst_y[p] > pe_y) route[p][P_S] = 1;
          else                    route[p][P_N] = 1;
        end
      end
    end
  end

  always_comb begin
    local_route = 4'd0;
    if (local_in.valid) begin
      logic xd = (dst_x == pe_x);
      logic yd = (dst_y == pe_y);
      if (!xd) begin
        if (dst_x > pe_x) local_route[P_E] = 1;
        else              local_route[P_W] = 1;
      end else if (!yd) begin
        if (dst_y > pe_y) local_route[P_S] = 1;
        else              local_route[P_N] = 1;
      end
    end
  end

  // Crossbar: for each output, collect requests and select
  logic [3:0] sel[4];
  logic [3:0] sel_local;

  always_comb begin
    for (int p = 0; p < 4; p++) begin
      logic [4:0] r;
      for (int i = 0; i < 4; i++) r[i] = port_in[i].valid && route[i][p];
      r[4] = local_in.valid && local_route[p];
      sel[p] = '0;
      for (int i = 4; i >= 0; i--) if (r[i]) begin sel[p] = i; end
    end

    r = '0;
    for (int i = 0; i < 4; i++) r[i] = port_in[i].valid && (&route[i]);
    r[4] = 1'b0;
    sel_local = '0;
    for (int i = 4; i >= 0; i--) if (r[i]) begin sel_local = i; end
  end

  always_comb begin
    for (int p = 0; p < 4; p++) begin
      port_out[p].valid = 1'b0;
      port_out[p].data  = '0;
      port_in[p].ready  = 1'b0;
      if (sel[p] < 4) begin
        port_out[p].valid = 1'b1;
        port_out[p].data  = port_in[sel[p]].data;
      end else if (sel[p] == 4) begin
        port_out[p].valid = 1'b1;
        port_out[p].data  = local_in.data;
      end
      if (sel[p] < 4 && sel[p] == p) port_in[p].ready = 1'b1;
    end
    local_out.valid = (sel_local < 4);
    local_out.data  = (sel_local < 4) ? port_in[sel_local].data : '0;
    local_in.ready  = (sel_local < 4);
  end

endmodule
