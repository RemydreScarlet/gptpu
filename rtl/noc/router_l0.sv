import gptpu_pkg::*;

module router_l0 (
  // Input links from peers (data/valid are inputs, ready is our backpressure output)
  input  logic [63:0] port_in_data [7:0],
  input  logic        port_in_valid[7:0],
  output logic        port_in_ready[7:0],

  // Output links to peers (data/valid are outputs, ready is the peer's backpressure input)
  output logic [63:0] port_out_data [7:0],
  output logic        port_out_valid[7:0],
  input  logic        port_out_ready[7:0],

  input  logic [7:0] pe_x, pe_y,

  input  logic       inject_valid,
  output logic       inject_ready,
  input  logic [7:0] inject_dst_x,
  input  logic [7:0] inject_dst_y,
  input  logic [2:0] inject_bcast_mode,
  input  logic [63:0] inject_data,

  output logic       l1_offload_valid,
  input  logic       l1_offload_ready,
  output logic [7:0] l1_offload_dst_x,
  output logic [7:0] l1_offload_dst_y,
  output logic [63:0] l1_offload_data,

  input  logic       is_highway_node,

  input  logic clk_noc,
  input  logic rst_n
);

  localparam int P_LOCAL = 0, P_N = 1, P_E = 2, P_S = 3;
  localparam int P_W = 4, P_NE = 5, P_SE = 6, P_NW = 7;

  // --- Flit format: {dst_y[7:0], dst_x[7:0], bcast[2:0], seq[3:0], payload[39:0]}
  // --- Routing fields from each input flit ---
  logic [7:0] f_dst_x[7:0];
  logic [7:0] f_dst_y[7:0];
  logic [2:0] f_bcast[7:0];

  genvar gi;
  generate
    for (gi = 0; gi < 8; gi++) begin : gen_decode
      assign f_dst_y[gi] = port_in_data[gi][63:56];
      assign f_dst_x[gi] = port_in_data[gi][55:48];
      assign f_bcast[gi] = port_in_data[gi][47:45];
    end
  endgenerate

  // --- Input routing logic: for each input, compute target output bitmap ---
  logic [7:0] in_target[7:0];
  logic x_done, y_done;

  always_comb begin
    for (int p = 0; p < 8; p++) begin
      in_target[p] = 8'd0;
      if (port_in_valid[p]) begin
        x_done = (f_dst_x[p] == pe_x);
        y_done = (f_dst_y[p] == pe_y);

        unique case (f_bcast[p])
          3'd1: begin
            in_target[p][P_E] = 1'b1;
            in_target[p][P_W] = 1'b1;
          end
          3'd2: begin
            in_target[p][P_N] = 1'b1;
            in_target[p][P_S] = 1'b1;
          end
          3'd3: begin
            in_target[p][P_N]=1'b1; in_target[p][P_NE]=1'b1;
            in_target[p][P_E]=1'b1; in_target[p][P_SE]=1'b1;
            in_target[p][P_S]=1'b1;
            in_target[p][P_W]=1'b1; in_target[p][P_NW]=1'b1;
          end
          default: begin
            if (!x_done) begin
              if (f_dst_x[p] > pe_x) in_target[p][P_E] = 1'b1;
              else                    in_target[p][P_W] = 1'b1;
            end else if (!y_done) begin
              if (f_dst_y[p] > pe_y) in_target[p][P_S] = 1'b1;
              else                    in_target[p][P_N] = 1'b1;
            end else begin
              in_target[p][P_LOCAL] = 1'b1;
            end
          end
        endcase
      end
    end
  end

  // --- Inject path routing ---
  logic       inject_to_l1;
  logic [7:0] inject_target;
  logic       inject_local;

  logic inj_x_done, inj_y_done;

  always_comb begin
    inject_target = 8'd0;
    inj_x_done = (inject_dst_x == pe_x);
    inj_y_done = (inject_dst_y == pe_y);

    unique case (inject_bcast_mode)
      3'd1: begin
        inject_target[P_E] = 1'b1; inject_target[P_W] = 1'b1;
      end
      3'd2: begin
        inject_target[P_N] = 1'b1; inject_target[P_S] = 1'b1;
      end
      3'd3: begin
        inject_target[P_N]=1'b1; inject_target[P_NE]=1'b1;
        inject_target[P_E]=1'b1; inject_target[P_SE]=1'b1;
        inject_target[P_S]=1'b1;
        inject_target[P_W]=1'b1; inject_target[P_NW]=1'b1;
      end
      default: begin
        if (!inj_x_done) begin
          if (inject_dst_x > pe_x) inject_target[P_E] = 1'b1;
          else                      inject_target[P_W] = 1'b1;
        end else if (!inj_y_done) begin
          if (inject_dst_y > pe_y) inject_target[P_S] = 1'b1;
          else                      inject_target[P_N] = 1'b1;
        end else begin
          inject_target[P_LOCAL] = 1'b1;
        end
      end
    endcase
    inject_local = (inject_dst_x == pe_x && inject_dst_y == pe_y);
  end

  assign inject_to_l1 = is_highway_node && inject_valid &&
                        !inject_local && (inject_dst_x != pe_x || inject_dst_y != pe_y);

  // --- Output port arbitration (WIDTH=9: 8 link ports + inject as input 8) ---
  localparam int P_INJ = 8;
  logic [8:0] out_req [7:0]; // out_req[out_port][in_port]; bit 8 == inject

  always_comb begin
    for (int p = 0; p < 8; p++) begin
      for (int in = 0; in < 8; in++) begin
        out_req[p][in] = port_in_valid[in] && in_target[in][p];
      end
      out_req[p][P_INJ] = !inject_to_l1 && inject_valid && inject_target[p];
    end
  end

  logic [3:0] out_prio[7:0];
  logic [3:0] out_grant[7:0];
  logic [7:0] out_any;

  genvar ga;
  generate
    for (ga = 0; ga < 8; ga++) begin : gen_arb
      logic [3:0] next_prio;
      logic [3:0] grant;
      logic       any_g;

      deadlock_free_arbiter #(.WIDTH(9)) arb (
        .req      (out_req[ga]),
        .prio     (out_prio[ga]),
        .grant    (grant),
        .any_grant(any_g),
        .prio_next(next_prio)
      );

      assign out_grant[ga] = grant;
      assign out_any[ga]   = any_g;

      always_ff @(posedge clk_noc or negedge rst_n) begin
        if (!rst_n) out_prio[ga] <= '0;
        else if (any_g) out_prio[ga] <= next_prio;
      end
    end
  endgenerate

  // --- Crossbar (input 8 == inject) ---
  always_comb begin
    for (int p = 0; p < 8; p++) begin
      port_out_valid[p] = 1'b0;
      port_out_data[p]  = '0;
      if (out_any[p]) begin
        port_out_valid[p] = 1'b1;
        port_out_data[p]  = (out_grant[p] == P_INJ) ? inject_data
                                                    : port_in_data[out_grant[p]];
      end
    end
  end

  // --- BACKPRESSURE: input ready when its granted output accepts AND the
  // intermediate output port is ready. Without the port_out_ready term an
  // input can pop while its target output FIFO is full, so the flit is
  // dropped at the output port (that output's valid clears once the input
  // de-asserts). The inject path (below) already gates on port_out_ready. ---
  always_comb begin
    for (int in = 0; in < 8; in++) begin
      logic g;
      g = 1'b0;
      for (int p = 0; p < 8; p++) begin
        if (out_any[p] && out_grant[p] == in && in_target[in][p] && port_out_ready[p]) begin
          g = 1'b1;
        end
      end
      port_in_ready[in] = g;
    end
  end

  // --- Inject ready: granted when its chosen output accepts (or L1-offloaded) ---
  always_comb begin
    logic g;
    g = 1'b0;
    for (int p = 0; p < 8; p++) begin
      if (out_any[p] && (out_grant[p] == P_INJ) && inject_target[p] && port_out_ready[p]) begin
        g = 1'b1;
      end
    end
    inject_ready = inject_to_l1 ? l1_offload_ready : g;
  end

  // --- L1 offload ---
  assign l1_offload_valid = inject_to_l1;
  assign l1_offload_dst_x = inject_dst_x;
  assign l1_offload_dst_y = inject_dst_y;
  assign l1_offload_data  = inject_data;

  `ifdef R0_DBG
  always_ff @(posedge clk_noc or negedge rst_n) begin
    if (rst_n && (inject_valid || port_in_valid[0] || port_out_valid[0]))
      $strobe("[%0t] R0(%0d,%0d) inV=%b in0.v=%b inj_v=%b local_v_out=%b dst(%0d,%0d) in0RDY=%b out0RDY=%b any0=%b grant0=%0d prio0=%0d req0=%b",
               $time, pe_x, pe_y,
               {port_in_valid[7],port_in_valid[6],port_in_valid[5],port_in_valid[4],
                port_in_valid[3],port_in_valid[2],port_in_valid[1],port_in_valid[0]},
               port_in_valid[0], inject_valid, port_out_valid[0],
               port_out_data[0][55:48], port_out_data[0][63:56],
               port_in_ready[0], port_out_ready[0], out_any[0], out_grant[0], out_prio[0],
               {out_req[0][8],out_req[0][7],out_req[0][6],out_req[0][5],
                out_req[0][4],out_req[0][3],out_req[0][2],out_req[0][1],out_req[0][0]});
  end
  `endif

endmodule