import gptpu_pkg::*;

module router_l0 (
  input  noc_channel_t port_in [7:0],
  output noc_channel_t port_out[7:0],

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
      assign f_dst_y[gi] = port_in[gi].data[63:56];
      assign f_dst_x[gi] = port_in[gi].data[55:48];
      assign f_bcast[gi] = port_in[gi].data[47:45];
    end
  endgenerate

  // --- Input routing logic: for each input, compute target output bitmap ---
  logic [7:0] in_target[7:0];

  always_comb begin
    for (int p = 0; p < 8; p++) begin
      in_target[p] = 8'd0;
      if (!port_in[p].valid) continue;

      logic x_done = (f_dst_x[p] == pe_x);
      logic y_done = (f_dst_y[p] == pe_y);

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

  // --- Inject path routing ---
  logic       inject_to_l1;
  logic [7:0] inject_target;
  logic       inject_local;

  always_comb begin
    inject_target = 8'd0;
    logic x_done = (inject_dst_x == pe_x);
    logic y_done = (inject_dst_y == pe_y);

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
        if (!x_done) begin
          if (inject_dst_x > pe_x) inject_target[P_E] = 1'b1;
          else                      inject_target[P_W] = 1'b1;
        end else if (!y_done) begin
          if (inject_dst_y > pe_y) inject_target[P_S] = 1'b1;
          else                      inject_target[P_N] = 1'b1;
        end
      end
    endcase
    inject_local = (inject_dst_x == pe_x && inject_dst_y == pe_y);
  end

  assign inject_to_l1 = is_highway_node && inject_valid &&
                        !inject_local && (inject_dst_x != pe_x || inject_dst_y != pe_y);

  // --- Output port arbitration ---
  logic [7:0] out_req [7:0]; // out_req[out_port][in_port]

  always_comb begin
    for (int p = 0; p < 8; p++) begin
      for (int in = 0; in < 8; in++) begin
        out_req[p][in] = port_in[in].valid && in_target[in][p];
      end
    end
  end

  logic [3:0] out_prio[7:0];
  logic [2:0] out_grant[7:0];
  logic [7:0] out_any;

  genvar ga;
  generate
    for (ga = 0; ga < 8; ga++) begin : gen_arb
      logic [3:0] next_prio;
      logic [2:0] grant;
      logic       any_g;

      deadlock_free_arbiter arb (
        .req           (out_req[ga]),
        .priority      (out_prio[ga]),
        .grant         (grant),
        .any_grant     (any_g),
        .priority_next (next_prio)
      );

      assign out_grant[ga] = grant;
      assign out_any[ga]   = any_g;

      always_ff @(posedge clk_noc or negedge rst_n) begin
        if (!rst_n) out_prio[ga] <= '0;
        else if (any_g) out_prio[ga] <= next_prio;
      end
    end
  endgenerate

  // --- Crossbar ---
  always_comb begin
    for (int p = 0; p < 8; p++) begin
      port_out[p].valid = 1'b0;
      port_out[p].data  = '0;
      if (out_any[p]) begin
        logic [2:0] src = out_grant[p];
        port_out[p].valid = 1'b1;
        port_out[p].data  = port_in[src].data;
      end
    end
  end

  // --- BACKPRESSURE: input ready when its target output granted and ready ---
  always_comb begin
    for (int in = 0; in < 8; in++) begin
      logic g;
      g = 1'b0;
      for (int p = 0; p < 8; p++) begin
        if (out_any[p] && out_grant[p] == in && in_target[in][p]) begin
          g = 1'b1;
        end
      end
      port_in[in].ready = g;
    end
  end

  // --- Inject ready: granted if not L1-offloaded and any target accepted ---
  assign inject_ready = inject_to_l1 ? l1_offload_ready :
                        inject_local ? 1'b1 : |inject_target;

  // --- L1 offload ---
  assign l1_offload_valid   = inject_to_l1;
  assign l1_offload_dst_x   = inject_dst_x;
  assign l1_offload_dst_y   = inject_dst_y;
  assign l1_offload_data    = inject_data;

endmodule
