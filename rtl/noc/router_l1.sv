import gptpu_pkg::*;

// L1 Expressway router (highway nodes only, x%4==0 && y%4==0).
//
// Expressway semantics: each highway node owns its 4x4 tile
// [pe_x, pe_x+3] x [pe_y, pe_y+3]. A flit is forwarded to a link port only
// when its destination lies strictly beyond this tile; otherwise it is
// delivered to the attached PE via the local port. This makes routing
// monotonic in tile coordinates and avoids E/W or N/S bouncing when the
// destination does not lie exactly on a highway node.
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
  localparam int P_LOCAL = 4;

  // --- Tile bounds of this highway node ---
  logic [7:0] tile_x_hi, tile_y_hi;
  assign tile_x_hi = pe_x + 8'd3;
  assign tile_y_hi = pe_y + 8'd3;

  // --- Flit dst decode (generate assigns: iverilog cannot part-select a
  //     var-indexed unpacked-array element inside always_* processes) ---
  logic [7:0] f_dst_x[4];
  logic [7:0] f_dst_y[4];
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi++) begin : gen_f
      assign f_dst_x[gi] = port_in_data[gi][55:48];
      assign f_dst_y[gi] = port_in_data[gi][63:56];
    end
  endgenerate

  // --- Routing decision per link input (dimension-order on tile space).
  //     Directions are packed (target_p[p*4 +: 4]); 0 => deliver to local.
  //     Packed vectors are used so iverilog simulates correctly (unpacked
  //     arrays shared across always_comb blocks are not supported). ---
  logic [15:0] target_p;

  always_comb begin
    for (int p = 0; p < 4; p++) begin
      target_p[p*4 +: 4] = 4'd0;
      if (port_in_valid[p]) begin
        if (f_dst_x[p] > tile_x_hi)            target_p[p*4 + P_E] = 1'b1;
        else if (f_dst_x[p] < pe_x)            target_p[p*4 + P_W] = 1'b1;
        else if (f_dst_y[p] > tile_y_hi)       target_p[p*4 + P_S] = 1'b1;
        else if (f_dst_y[p] < pe_y)            target_p[p*4 + P_N] = 1'b1;
        // else: dst within this tile -> stays 0 -> deliver to local
      end
    end
  end

  // --- Routing decision for the local (offload) input ---
  logic [3:0] local_target;

  always_comb begin
    local_target = 4'd0;
    if (local_in_valid) begin
      if (local_in_data[55:48] > tile_x_hi)       local_target[P_E] = 1'b1;
      else if (local_in_data[55:48] < pe_x)       local_target[P_W] = 1'b1;
      else if (local_in_data[63:56] > tile_y_hi)  local_target[P_S] = 1'b1;
      else if (local_in_data[63:56] < pe_y)       local_target[P_N] = 1'b1;
      // dst inside this tile should never be offloaded; deliver straight back
    end
  end

  // --- Request matrix (packed): req_p[o*5 + i], input index 4 == local ---
  logic [19:0] req_p;

  always_comb begin
    for (int o = 0; o < 4; o++) begin
      for (int i = 0; i < 4; i++)
        req_p[o*5 + i] = port_in_valid[i] && target_p[i*4 + o];
      req_p[o*5 + P_LOCAL] = local_in_valid && local_target[o];
    end
  end

  // --- Fixed-priority arbitration per output (local highest, then N/E/S/W) ---
  logic [11:0] grant_p;  // grant_p[o*3 +: 3]
  logic [3:0]  any_p;    // any_p[o]

  always_comb begin
    for (int o = 0; o < 4; o++) begin
      grant_p[o*3 +: 3] = '0;
      any_p[o] = 1'b0;
      for (int i = P_LOCAL; i >= 0; i--) begin
        if (req_p[o*5 + i]) begin
          grant_p[o*3 +: 3] = i[2:0];
          any_p[o] = 1'b1;
        end
      end
    end
  end

  // --- Crossbar: link outputs ---
  always_comb begin
    for (int o = 0; o < 4; o++) begin
      port_out_valid[o] = any_p[o];
      port_out_data[o]  = (grant_p[o*3 +: 3] == P_LOCAL)
                            ? local_in_data : port_in_data[grant_p[o*3 +: 3]];
    end
  end

  // --- Local output: deliver flits whose destination is inside this tile ---
  logic [2:0] local_grant;  // granted link input (0..3), 3'b111 == local input
  logic       local_any;

  always_comb begin
    local_any    = 1'b0;
    local_grant  = '0;
    local_out_data = '0;
    for (int i = 0; i < 4; i++) begin
      if (port_in_valid[i] && (target_p[i*4 +: 4] == 4'd0) && !local_any) begin
        local_any   = 1'b1;
        local_grant = i[2:0];
      end
    end
    if (local_in_valid && (local_target == 4'd0) && !local_any) begin
      local_any   = 1'b1;
      local_grant = 3'b111;
    end
    local_out_valid = local_any;
    local_out_data  = (local_grant == 3'b111) ? local_in_data : port_in_data[local_grant];
  end

  // --- Backpressure: an input is ready only when its chosen output accepts ---
  always_comb begin
    for (int i = 0; i < 4; i++) begin
      port_in_ready[i] = 1'b0;
      if (target_p[i*4 +: 4] == 4'd0) begin
        port_in_ready[i] = local_any && (local_grant == i) && local_out_ready;
      end else begin
        for (int o = 0; o < 4; o++)
          if (target_p[i*4 + o] && any_p[o] && (grant_p[o*3 +: 3] == i))
            port_in_ready[i] = port_out_ready[o];
      end
    end

    local_in_ready = 1'b0;
    if (local_target == 4'd0) begin
      local_in_ready = local_any && (local_grant == 3'b111) && local_out_ready;
    end else begin
      for (int o = 0; o < 4; o++)
        if (local_target[o] && any_p[o] && (grant_p[o*3 +: 3] == P_LOCAL))
          local_in_ready = port_out_ready[o];
end
  end

  `ifdef L1_DBG
  always_ff @(posedge clk_noc or negedge rst_n) begin
    if (rst_n && (local_in_valid || local_out_valid ||
              port_out_valid[0] || port_out_valid[1] || port_out_valid[2] || port_out_valid[3]))
      $display("[%0t] L1(%0d,%0d) inV=%b liV=%b li_dst(%0d,%0d) li_tgt=%b loV=%b lo_dst(%0d,%0d) outV=%b out_dst(%0d,%0d)",
               $time, pe_x, pe_y,
               {port_in_valid[3],port_in_valid[2],port_in_valid[1],port_in_valid[0]},
               local_in_valid, local_in_data[55:48], local_in_data[63:56], local_target,
               local_out_valid, local_out_data[55:48], local_out_data[63:56],
               port_out_valid, port_out_data[0][55:48], port_out_data[0][63:56]);
  end
  `endif

endmodule
