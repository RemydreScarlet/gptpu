import gptpu_pkg::*;

module pe_core (
  input  logic [7:0] pe_x, pe_y,

  // L0 NoC cardinal ports (flattened per-direction to avoid iverilog array-slice
  // limitation on continuous assignment in generate grids). Router port map is
  // [1]=N, [2]=E, [3]=S, [4]=W; [0]=LOCAL and [5..7]=diagonals stay internal.
  output logic [63:0] l0_N_data,  l0_E_data,  l0_S_data,  l0_W_data,
  output logic        l0_N_valid, l0_E_valid, l0_S_valid, l0_W_valid,
  input  logic        l0_N_ready, l0_E_ready, l0_S_ready, l0_W_ready,
  input  logic [63:0] l0_N_in_data,  l0_E_in_data,  l0_S_in_data,  l0_W_in_data,
  input  logic        l0_N_in_valid, l0_E_in_valid, l0_S_in_valid, l0_W_in_valid,
  output logic        l0_N_in_ready, l0_E_in_ready, l0_S_in_ready, l0_W_in_ready,

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
  logic [15:0] sc_reg_rs, sc_reg_rt;
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
  logic [63:0] router_pin_data [8];
  logic        router_pin_valid[8];
  logic        router_pin_ready[8];
  logic [63:0] router_pout_data [8];
  logic        router_pout_valid[8];
  logic        router_pout_ready[8];

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
    .addr0  (cce_sram_addr_a),
    .cs0    (1'b1),
    .we0    (1'b0),
    .data0_w('0),
    .data0_r(sram_data0_out),
    .addr1  (cce_sram_addr_b),
    .cs1    (1'b1),
    .we1    (1'b0),
    .data1_w('0),
    .data1_r(sram_data1_out),
    .addr2  (sram_addr_d_final),
    .cs2    (sram_we | scalar_st | lut_read),
    .we2    (sram_we | scalar_st | lut_read),
    .data2_w(sram_data2_in),
    .data2_r(),
    .addr3  ('0),
    .cs3    (1'b0),
    .we3    (1'b0),
    .data3_w('0),
    .data3_r(sram_data3_out),
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
    .a        (sc_reg_rs),
    .b        (sc_reg_rt),
    .opcode   (scalar_opcode),
    .rs_addr  (scalar_rs),
    .rt_addr  (scalar_rt),
    .rd_addr  (scalar_rd),
    .reg_we   (scalar_reg_we),
    .reg_wdata(scalar_wdata),
    .reg_rs   (sc_reg_rs),
    .reg_rt   (sc_reg_rt),
    .reg_rd   (),
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
    .entry_addr   (lut_addr),
    .table_id     (lut_table_id),
    .entry_out    (lut_entry_out),
    .write_en     (1'b0),
    .write_table  (4'd0),
    .write_addr   (8'd0),
    .write_data   (8'd0),
    .swap_lut     (lut_swap),
    .swap_done    (),
    .boot_load    (1'b0),
    .boot_table_id(4'd0),
    .clk_pe       (clk_pe),
    .rst_n        (rst_n)
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
    .port_in_data     (router_pin_data),
    .port_in_valid    (router_pin_valid),
    .port_in_ready    (router_pin_ready),
    .port_out_data    (router_pout_data),
    .port_out_valid   (router_pout_valid),
    .port_out_ready   (router_pout_ready),
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
  // N (router port 1)
  assign l0_N_data  = router_pout_data[1];
  assign l0_N_valid = router_pout_valid[1];
  assign router_pout_ready[1] = l0_N_ready;
  assign router_pin_data[1]   = l0_N_in_data;
  assign router_pin_valid[1]  = l0_N_in_valid;
  assign l0_N_in_ready        = router_pin_ready[1];

  // E (router port 2)
  assign l0_E_data  = router_pout_data[2];
  assign l0_E_valid = router_pout_valid[2];
  assign router_pout_ready[2] = l0_E_ready;
  assign router_pin_data[2]   = l0_E_in_data;
  assign router_pin_valid[2]  = l0_E_in_valid;
  assign l0_E_in_ready        = router_pin_ready[2];

  // S (router port 3)
  assign l0_S_data  = router_pout_data[3];
  assign l0_S_valid = router_pout_valid[3];
  assign router_pout_ready[3] = l0_S_ready;
  assign router_pin_data[3]   = l0_S_in_data;
  assign router_pin_valid[3]  = l0_S_in_valid;
  assign l0_S_in_ready        = router_pin_ready[3];

  // W (router port 4)
  assign l0_W_data  = router_pout_data[4];
  assign l0_W_valid = router_pout_valid[4];
  assign router_pout_ready[4] = l0_W_ready;
  assign router_pin_data[4]   = l0_W_in_data;
  assign router_pin_valid[4]  = l0_W_in_valid;
  assign l0_W_in_ready        = router_pin_ready[4];

  // Diagonals (router ports 5,6,7) tied off: dimension-order routing uses
  // only cardinal directions.
  assign router_pin_data[5] = '0;   assign router_pin_valid[5] = 1'b0;   assign router_pout_ready[5] = 1'b0;
  assign router_pin_data[6] = '0;   assign router_pin_valid[6] = 1'b0;   assign router_pout_ready[6] = 1'b0;
  assign router_pin_data[7] = '0;   assign router_pin_valid[7] = 1'b0;   assign router_pout_ready[7] = 1'b0;

  // LOCAL port (0)
  assign eject_router_valid = router_pout_valid[0];
  assign eject_router_data  = router_pout_data[0];
  assign router_pout_ready[0] = eject_router_ready;

  assign router_pin_data[0]  = is_highway_node ? l1_in_data  : '0;
  assign router_pin_valid[0] = is_highway_node ? l1_in_valid : 1'b0;
  assign l1_in_ready = is_highway_node ? router_pin_ready[0] : 1'b0;

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
          sc_reg_rs  // payload from scalar register specified by scalar_send_src
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
      sram_data2_in[sram_addr_d_final[5:0]*8 +: 8] = sc_reg_rs[7:0];
    end else if (lut_read) begin
      for (int i = 0; i < VECTOR_LANE_WIDTH; i++)
        sram_data2_in[i*8 +: 8] = lut_entry_out;
    end else begin
      sram_data2_in = vec_result;
    end
  end

endmodule
