import gptpu_pkg::*;

module router_l1 (
  // 4 links to adjacent highway nodes (N, E, S, W)
  input  logic [63:0] port_in_data [3:0],
  input  logic        port_in_valid[3:0],
  output logic        port_in_ready[3:0],
  output logic [63:0] port_out_data [3:0],
  output logic        port_out_valid[3:0],
  input  logic        port_out_ready[3:0],

  // Local link to the attached PE (offload in, delivery out)
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

  localparam int P_N = 0, P_E = 1, P_S = 2, P_W = 3;

  // Dimension-order: X then Y. dst decoded from embedded flit header.
  logic [7:0] f_dst_x[4], f_dst_y[4];
  logic [7:0] loc_dst_x, loc_dst_y;
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi++) begin : gen_f
      assign f_dst_x[gi] = port_in_data[gi][55:48];
      assign f_dst_y[gi] = port_in_data[gi][63:56];
    end
  endgenerate

  assign loc_dst_x = local_in_data[55:48];
  assign loc_dst_y = local_in_data[63:56];

  logic [3:0] route[4];
  logic [3:0] local_route;
  logic x_done, y_done;

  always_comb begin
    for (int p = 0; p < 4; p++) begin
      route[p] = 4'd0;
      if (port_in_valid[p]) begin
        x_done = (f_dst_x[p] == pe_x);
        y_done = (f_dst_y[p] == pe_y);
        if (!x_done) begin
          if (f_dst_x[p] > pe_x) route[p][P_E] = 1'b1;
          else                    route[p][P_W] = 1'b1;
        end else if (!y_done) begin
          if (f_dst_y[p] > pe_y) route[p][P_S] = 1'b1;
          else                    route[p][P_N] = 1'b1;
        end
      end
    end
  end

  always_comb begin
    local_route = 4'd0;
    if (local_in_valid) begin
      x_done = (loc_dst_x == pe_x);
      y_done = (loc_dst_y == pe_y);
      if (!x_done) begin
        if (loc_dst_x > pe_x) local_route[P_E] = 1'b1;
        else                  local_route[P_W] = 1'b1;
      end else if (!y_done) begin
        if (loc_dst_y > pe_y) local_route[P_S] = 1'b1;
        else                  local_route[P_N] = 1'b1;
      end
    end
  end

  // Crossbar: for each output, collect requests and select
  logic [3:0] sel[4];
  logic [3:0] sel_local;
  logic [4:0] r;

  always_comb begin
    for (int p = 0; p < 4; p++) begin
      r = '0;
      for (int i = 0; i < 4; i++) r[i] = port_in_valid[i] && route[i][p];
      r[4] = local_in_valid && local_route[p];
      sel[p] = '0;
      for (int i = 4; i >= 0; i--) if (r[i]) begin sel[p] = i; end
    end
  end

  always_comb begin
    r = '0;
    for (int i = 0; i < 4; i++) r[i] = port_in_valid[i] && (&route[i]);
    r[4] = 1'b0;
    sel_local = '0;
    for (int i = 4; i >= 0; i--) if (r[i]) begin sel_local = i; end
  end

  always_comb begin
    for (int p = 0; p < 4; p++) begin
      port_out_valid[p] = 1'b0;
      port_out_data[p]  = '0;
      port_in_ready[p]  = 1'b0;
      if (sel[p] < 4) begin
        port_out_valid[p] = 1'b1;
        port_out_data[p]  = port_in_data[sel[p]];
      end else if (sel[p] == 4) begin
        port_out_valid[p] = 1'b1;
        port_out_data[p]  = local_in_data;
      end
      if (sel[p] < 4 && sel[p] == p) port_in_ready[p] = 1'b1;
    end
    local_out_valid = (sel_local < 4);
    local_out_data  = (sel_local < 4) ? port_in_data[sel_local] : '0;
    local_in_ready  = (sel_local < 4);
  end

endmodule