import gptpu_pkg::*;

module async_port_controller (
  // L0 interface (all PEs)
  output noc_channel_t l0_out [8],    // 8 directional + local
  input  noc_channel_t l0_in  [8],

  // L1 interface (highway nodes only)
  output noc_channel_t l1_out,
  input  noc_channel_t l1_in,

  // L2 interface (boundary highway nodes only)
  output noc_channel_t l2_out,
  input  noc_channel_t l2_in,

  // Local PE core interface
  input  noc_channel_t pe_in,
  output noc_channel_t pe_out,

  // Configuration
  input  logic is_highway_node,  // (x%4==0 && y%4==0)
  input  logic is_boundary_node, // SN boundary

  // Clock domains
  input  logic clk_pe,
  input  logic clk_noc,
  input  logic rst_n
);

  // --- L0 async FIFOs for each direction ---
  genvar d;

  generate
    for (d = 0; d < 8; d++) begin : gen_l0_fifos
      async_fifo_2stage #(.DATA_WIDTH(64)) l0_fifo (
        .w_data   (l0_out[d].data),
        .w_valid  (l0_out[d].valid),
        .w_ready  (l0_out[d].ready),
        .r_data   (l0_in[d].data),
        .r_valid  (l0_in[d].valid),
        .r_ready  (l0_in[d].ready),
        .clk_wr   (clk_pe),
        .clk_rd   (clk_noc),
        .rst_n_wr (rst_n),
        .rst_n_rd (rst_n)
      );
    end
  endgenerate

  // --- L1 FIFO (only if highway node) ---
  async_fifo_2stage #(.DATA_WIDTH(64)) l1_fifo (
    .w_data   (l1_out.data),
    .w_valid  (l1_out.valid),
    .w_ready  (l1_out.ready),
    .r_data   (l1_in.data),
    .r_valid  (l1_in.valid),
    .r_ready  (l1_in.ready),
    .clk_wr   (clk_pe),
    .clk_rd   (clk_noc),
    .rst_n_wr (rst_n),
    .rst_n_rd (rst_n)
  );

  // --- L2 FIFO (only if boundary node) ---
  async_fifo_2stage #(.DATA_WIDTH(64)) l2_fifo (
    .w_data   (l2_out.data),
    .w_valid  (l2_out.valid),
    .w_ready  (l2_out.ready),
    .r_data   (l2_in.data),
    .r_valid  (l2_in.valid),
    .r_ready  (l2_in.ready),
    .clk_wr   (clk_pe),
    .clk_rd   (clk_noc),
    .rst_n_wr (rst_n),
    .rst_n_rd (rst_n)
  );

  // --- Local PE port ---
  assign pe_out = pe_in;

endmodule
