import gptpu_pkg::*;

module pe_core (
  input  logic [7:0] pe_x, pe_y,

  // L0 NoC: individual signals per direction to avoid struct direction issues
  output logic [63:0] l0_out_data  [8],
  output logic        l0_out_valid [8],
  input  logic        l0_out_ready [8],
  input  logic [63:0] l0_in_data   [8],
  input  logic        l0_in_valid  [8],
  output logic        l0_in_ready  [8],

  // L1 expressway (clk_noc domain)
  output logic [63:0] l1_out_data,
  output logic        l1_out_valid,
  input  logic        l1_out_ready,
  input  logic [63:0] l1_in_data,
  input  logic        l1_in_valid,
  output logic        l1_in_ready,

  // L2 SN-boundary (clk_noc domain)
  output logic [63:0] l2_out_data,
  output logic        l2_out_valid,
  input  logic        l2_out_ready,
  input  logic [63:0] l2_in_data,
  input  logic        l2_in_valid,
  output logic        l2_in_ready,

  // Microcode memory interface (clk_pe domain)
  input  microcode_word_t instr,
  input  logic            instr_valid,
  output logic [12:0]     pc,

  // DDR stream interface (clk_pe domain)
  input  logic [511:0] stream_data,
  input  logic         stream_valid,
  output logic         stream_ready,

  // Local clocks
  input  logic clk_pe,
  input  logic clk_noc,
  input  logic rst_n
);

  logic is_highway_node, is_boundary_node;
  assign is_highway_node  = (pe_x % 4 == 0) && (pe_y % 4 == 0);
  assign is_boundary_node = (pe_x % 4 == 0) && (pe_y % 4 == 0);

  // --- CCE control signals (clk_pe domain) ---
  logic [3:0]  vec_opcode;
  logic        vec_acc_en, vec_sat_en, vec_nd;
  logic [15:0] cce_sram_addr_a, cce_sram_addr_b, cce_sram_addr_d;
  logic [15:0] sram_addr_d_final;
  logic        sram_we;
  logic [2:0]  scalar_opcode;
  logic [2:0]  scalar_rs, scalar_rt, scalar_rd;
  logic        scalar_reg_we;
  logic [15:0] scalar_imm;
  logic        lc_load, lc_dec;
  logic [15:0] lc_init;
  logic [7:0]  lut_addr;
  logic [3:0]  lut_table_id;
  logic        lut_swap, lut_read;
  logic [7:0]  noc_dst_x, noc_dst_y;
  logic [2:0]  noc_mode;
  logic        noc_send;
  logic        cmp_eq, cmp_lt, cmp_gt;
  logic        lc_zero, branch_taken;
  logic        scalar_imm_sel, scalar_ld, scalar_st, scalar_test_en, scalar_recv;
  logic [3:0]  scalar_send_src;
  logic        status_we, pc_stall;
  logic [1:0]  status_in, status_out;

  // --- Vector data path (clk_pe domain) ---
  vector_line_t line_a, line_b, vec_result, mac_acc_out;
  logic [511:0] sram_data0_out;
  logic [511:0] sram_data1_out;
  logic [511:0] sram_data2_in, sram_data2_out;
  logic [511:0] sram_data3_out;

  // --- Scalar data path ---
  logic [15:0] alu_result, reg_r6, scalar_wdata;
  logic [15:0] status_reg;
  fp8_e4m3_t   lut_entry_out;

  // --- Router inject/eject (async_port_controller interface) ---
  logic [63:0]  inject_data;
  logic         inject_valid;
  logic         inject_ready;
  logic [63:0]  inject_router_data;
  logic         inject_router_valid;
  logic         inject_router_ready;
  logic [63:0]  eject_router_data;
  logic         eject_router_valid;
  logic         eject_router_ready;
  logic [63:0]  eject_data;
  logic         eject_valid;
  logic         eject_ready;

  // --- Router internal ports (clk_noc domain) ---
  noc_channel_t router_pin  [7:0];
  noc_channel_t router_pout [7:0];

  // --- L1 offload signals ---
  logic        l1_offload_valid;
  logic        l1_offload_ready;
  logic [7:0]  l1_offload_dst_x;
  logic [7:0]  l1_offload_dst_y;
  logic [63:0] l1_offload_data;

  // ============================================================
  // Sub-module Instances
  // ============================================================

  sram_512kb sram (
    .addr0 (cce_sram_addr_a),
    .cs0   (1'b1),
    .we0   (1'b0),
    .data0 (sram_data0_out),
    .addr1 (cce_sram_addr_b),
    .cs1   (1'b1),
    .we1   (1'b0),
    .data1 (sram_data1_out),
    .addr2 (sram_addr_d_final),
    .cs2   (sram_we | scalar_st | lut_read),
    .we2   (sram_we | scalar_st | lut_read),
    .data2 (sram_data2_in),
    .addr3 ('0),
    .cs3   (1'b0),
    .we3   (1'b0),
    .data3 (sram_data3_out),
    .clk_pe (clk_pe),
    .rst_n  (rst_n)
  );

  vector_lane vlane (
    .line_a      (line_a),
    .line_b      (line_b),
    .opcode      (vec_opcode),
    .acc_en      (vec_acc_en),
    .sat_en      (vec_sat_en),
    .result      (vec_result),
    .mac_acc_out (mac_acc_out),
    .clk_pe      (clk_pe),
    .rst_n       (rst_n)
  );

  scalar_ctrl scalar (
    .a        (scalar.reg_rs),
    .b        (scalar.reg_rt),
    .opcode   (scalar_opcode),
    .rs_addr  (scalar_rs),
    .rt_addr  (scalar_rt),
    .rd_addr  (scalar_rd),
    .reg_we   (scalar_reg_we),
    .reg_wdata(scalar_wdata),
    .reg_r6   (reg_r6),
    .alu_result(alu_result),
    .cmp_eq   (cmp_eq),
    .cmp_lt   (cmp_lt),
    .cmp_gt   (cmp_gt),
    .lc_dec   (lc_dec),
    .lc_zero  (lc_zero),
    .lc_init  (lc_init),
    .lc_load  (lc_load),
    .clk_pe   (clk_pe),
    .rst_n    (rst_n)
  );

  configurable_lut lut (
    .entry_addr  (lut_addr),
    .table_id    (lut_table_id),
    .entry_out   (lut_entry_out),
    .swap_lut    (lut_swap),
    .clk_pe      (clk_pe),
    .rst_n       (rst_n)
  );

  coupled_compute_engine cce (
    .instr          (instr),
    .instr_valid    (instr_valid),
    .pc             (pc),
    .vec_opcode     (vec_opcode),
    .vec_acc_en     (vec_acc_en),
    .vec_sat_en     (vec_sat_en),
    .vec_nd         (vec_nd),
    .sram_addr_a    (cce_sram_addr_a),
    .sram_addr_b    (cce_sram_addr_b),
    .sram_addr_d    (cce_sram_addr_d),
    .sram_we        (sram_we),
    .scalar_opcode  (scalar_opcode),
    .scalar_rs      (scalar_rs),
    .scalar_rt      (scalar_rt),
    .scalar_rd      (scalar_rd),
    .scalar_reg_we  (scalar_reg_we),
    .scalar_imm     (scalar_imm),
    .lc_load        (lc_load),
    .lc_dec         (lc_dec),
    .lc_init        (lc_init),
    .scalar_imm_sel (scalar_imm_sel),
    .scalar_ld      (scalar_ld),
    .scalar_st      (scalar_st),
    .scalar_test_en (scalar_test_en),
    .scalar_recv    (scalar_recv),
    .scalar_send_src(scalar_send_src),
    .status_we      (status_we),
    .status_in      (status_reg[1:0]),
    .status_out     (status_out),
    .pc_stall       (pc_stall),
    .lut_addr       (lut_addr),
    .lut_table_id   (lut_table_id),
    .lut_swap       (lut_swap),
    .lut_read       (lut_read),
    .noc_dst_x      (noc_dst_x),
    .noc_dst_y      (noc_dst_y),
    .noc_mode       (noc_mode),
    .noc_send       (noc_send),
    .cmp_eq         (cmp_eq),
    .cmp_lt         (cmp_lt),
    .cmp_gt         (cmp_gt),
    .lc_zero        (lc_zero),
    .branch_taken   (branch_taken),
    .clk_pe         (clk_pe),
    .rst_n          (rst_n)
  );

  router_l0 router (
    .port_in          (router_pin),
    .port_out         (router_pout),
    .pe_x             (pe_x),
    .pe_y             (pe_y),
    .inject_valid     (inject_router_valid),
    .inject_ready     (inject_router_ready),
    .inject_dst_x     (inject_router_data[55:48]),
    .inject_dst_y     (inject_router_data[63:56]),
    .inject_bcast_mode(inject_router_data[47:45]),
    .inject_data      (inject_router_data),
    .l1_offload_valid (l1_offload_valid),
    .l1_offload_ready (l1_offload_ready),
    .l1_offload_dst_x (l1_offload_dst_x),
    .l1_offload_dst_y (l1_offload_dst_y),
    .l1_offload_data  (l1_offload_data),
    .is_highway_node  (is_highway_node),
    .clk_noc          (clk_noc),
    .rst_n            (rst_n)
  );

  async_port_controller apc (
    .inject_data         (inject_data),
    .inject_valid        (inject_valid),
    .inject_ready        (inject_ready),
    .inject_router_data  (inject_router_data),
    .inject_router_valid (inject_router_valid),
    .inject_router_ready (inject_router_ready),
    .eject_router_data   (eject_router_data),
    .eject_router_valid  (eject_router_valid),
    .eject_router_ready  (eject_router_ready),
    .eject_data          (eject_data),
    .eject_valid         (eject_valid),
    .eject_ready         (eject_ready),
    .clk_pe              (clk_pe),
    .clk_noc             (clk_noc),
    .rst_n               (rst_n)
  );

  // ============================================================
  // Router to NoC wiring (clk_noc domain)
  // ============================================================
  genvar d;
  generate
    for (d = 1; d < 8; d++) begin : gen_noc_dirs
      assign l0_out_data[d]  = router_pout[d].data;
      assign l0_out_valid[d] = router_pout[d].valid;
      assign router_pout[d].ready = l0_out_ready[d];
      assign router_pin[d].data  = l0_in_data[d];
      assign router_pin[d].valid = l0_in_valid[d];
      assign l0_in_ready[d]     = router_pin[d].ready;
    end
  endgenerate

  // LOCAL port (0)
  assign eject_router_valid = router_pout[0].valid;
  assign eject_router_data  = router_pout[0].data;
  assign router_pout[0].ready = eject_router_ready;

  assign router_pin[0].data  = is_highway_node ? l1_in_data  : '0;
  assign router_pin[0].valid = is_highway_node ? l1_in_valid : 1'b0;
  assign l1_in_ready = is_highway_node ? router_pin[0].ready : 1'b0;

  // L1 offload → l1_out
  assign l1_out_data  = l1_offload_data;
  assign l1_out_valid = l1_offload_valid;
  assign l1_offload_ready = l1_out_ready;

  // L2: direct pass-through
  assign l2_out_data  = l2_in_data;
  assign l2_out_valid = l2_in_valid;
  assign l2_in_ready  = l2_out_ready;

  // ============================================================
  // SEND / BCAST: flit generation with scalar register payload
  // ============================================================
  // Flit: {dst_y[7:0], dst_x[7:0], mode[2:0], flags[4:0], payload[39:0]}
  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n) begin
      inject_valid <= 1'b0;
      inject_data  <= '0;
    end else begin
      inject_valid <= noc_send;
      if (noc_send) begin
        inject_data <= {
          noc_dst_y,
          noc_dst_x,
          noc_mode,
          5'd0,
          scalar.reg_rs  // payload from scalar register specified by scalar_send_src
        };
      end
    end
  end

  // ============================================================
  // RECV: eject data → scalar register file
  // ============================================================
  assign eject_ready = scalar_recv;  // accept eject data when RECV is issued
  assign pc_stall = scalar_recv & ~eject_valid;  // stall if RECV with no data

  // ============================================================
  // Status register (SCMP → TEST)
  // ============================================================
  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n)
      status_reg <= '0;
    else if (status_we)
      status_reg <= {14'd0, status_out};
  end

  // ============================================================
  // Scalar register write data mux
  // ============================================================
  always_comb begin
    if (scalar_imm_sel)
      scalar_wdata = scalar_imm[15:0];       // LDI
    else if (scalar_test_en)
      scalar_wdata = status_reg;              // TEST
    else if (scalar_ld)
      scalar_wdata = sram_data0_out[cce_sram_addr_a[5:0]*8 +: 8];  // LD (Bank0 byte at addr)
    else if (scalar_recv & eject_valid)
      scalar_wdata = eject_data[15:0];       // RECV
    else
      scalar_wdata = alu_result;              // Scalar ALU ops
  end

  // ============================================================
  // Memory-Centric Datapath
  // ============================================================
  // Vector ops: read from Bank0, Bank1; write to Bank2
  assign line_a = vector_line_t'(sram_data0_out);
  assign line_b = vector_line_t'(sram_data1_out);

  assign sram_addr_d_final = vec_nd ? reg_r6 : (scalar_st ? cce_sram_addr_a : cce_sram_addr_d);

  // SRAM Bank2 write data mux
  always_comb begin
    if (scalar_st) begin
      sram_data2_in = '0;
      sram_data2_in[sram_addr_d_final[5:0]*8 +: 8] = scalar.reg_rs[7:0];
    end else if (lut_read) begin
      for (int i = 0; i < VECTOR_LANE_WIDTH; i++)
        sram_data2_in[i*8 +: 8] = lut_entry_out;
    end else begin
      sram_data2_in = vec_result;
    end
  end

endmodule
