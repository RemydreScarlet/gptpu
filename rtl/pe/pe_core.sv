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

  // L1 expressway links (clk_noc domain); highway nodes only (x%4==0,y%4==0)
  output logic [63:0] l1_N_data,  l1_E_data,  l1_S_data,  l1_W_data,
  output logic        l1_N_valid, l1_E_valid, l1_S_valid, l1_W_valid,
  input  logic        l1_N_ready, l1_E_ready, l1_S_ready, l1_W_ready,
  input  logic [63:0] l1_N_in_data,  l1_E_in_data,  l1_S_in_data,  l1_W_in_data,
  input  logic        l1_N_in_valid, l1_E_in_valid, l1_S_in_valid, l1_W_in_valid,
  output logic        l1_N_in_ready, l1_E_in_ready, l1_S_in_ready, l1_W_in_ready,

  // L2 SN-boundary links (clk_noc domain); boundary highway nodes only
  output logic [63:0] l2_E_data, l2_W_data,
  output logic        l2_E_valid, l2_W_valid,
  input  logic        l2_E_ready, l2_W_ready,
  input  logic [63:0] l2_E_in_data, l2_W_in_data,
  input  logic        l2_E_in_valid, l2_W_in_valid,
  output logic        l2_E_in_ready, l2_W_in_ready,

  // Microcode memory interface (clk_pe domain)
  input  microcode_word_t instr,
  input  logic            instr_valid,
  output logic [12:0]     pc,

  // DDR stream interface (clk_pe domain)
  input  logic [511:0] stream_data,
  input  logic         stream_valid,
  output logic         stream_ready,

  // LUT user-table programming (clk_pe domain; tables 9-15 via DDR)
  input  logic         lut_write_en,
  input  logic [3:0]   lut_write_table,
  input  logic [7:0]   lut_write_addr,
  input  fp8_e4m3_t    lut_write_data,

  // --- Test hooks (tie off / ignored in normal operation) ---
  // Direct NoC injection (bypasses CCE): holds valid until test_inject_ready.
  input  logic         test_inject_valid,
  input  logic [63:0]  test_inject_data,   // {dst_y, dst_x, bcast, flags, payload}
  output logic         test_inject_ready,
  output logic [63:0]  test_eject_data,
  output logic         test_eject_valid,
  output logic         test_l1_valid,      // any L1 egress active at this PE
  output logic         test_l2_valid,      // any L2 egress active at this PE

  // Local clocks
  input  logic clk_pe,
  input  logic clk_noc,
  input  logic rst_n
);

  logic is_highway_node, is_boundary_node;
  assign is_highway_node  = (pe_x % 4 == 0) && (pe_y % 4 == 0);
  // Boundary highway node: a highway node sitting on an SN boundary
  // (x multiple of SN_GRID_X but not the outer edge, or y likewise).
  assign is_boundary_node = is_highway_node &&
        (((pe_x % SN_GRID_X == 0) && (pe_x != 0)) ||
         ((pe_y % SN_GRID_Y == 0) && (pe_y != 0)));

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

  // --- LUT boot loader: after reset deassert, populate tables 0-15 over 16 cycles ---
  logic [3:0]  lut_boot_cnt;
  logic        lut_booting;
  logic        lut_boot_load;
  logic [3:0]  lut_boot_table_id;

  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n) begin
      lut_booting  <= 1'b1;
      lut_boot_cnt <= 4'd0;
    end else if (lut_booting) begin
      if (lut_boot_cnt == 4'd15)
        lut_booting <= 1'b0;
      else
        lut_boot_cnt <= lut_boot_cnt + 4'd1;
    end
  end

  assign lut_boot_load     = lut_booting;
  assign lut_boot_table_id = lut_boot_cnt;
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
  // Declared with descending [7:0] forms so element alignment matches Verilator's
  // positional flattening of unpacked arrays; an ascending [8] declaration here
  // would connect port_in[7] <-> router_pin[0] (index reversed).
  logic [63:0] router_pin_data [7:0];
  logic        router_pin_valid[7:0];
  logic        router_pin_ready[7:0];
  logic [63:0] router_pout_data [7:0];
  logic        router_pout_valid[7:0];
  logic        router_pout_ready[7:0];

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
    .we0    (scalar_st),
    .data0_w({504'h0, sc_reg_rs[7:0]}),
    .data0_r(sram_data0_out),
    .bwe0   (scalar_st),
    .baddr0 (cce_sram_addr_a[5:0]),
    .addr1  (cce_sram_addr_b),
    .cs1    (1'b1),
    .we1    (1'b0),
    .data1_w('0),
    .data1_r(sram_data1_out),
    .addr2  (sram_addr_d_final),
    .cs2    (sram_we | lut_read),
    .we2    (sram_we | lut_read),
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
    .write_en     (lut_write_en),
    .write_table  (lut_write_table),
    .write_addr   (lut_write_addr),
    .write_data   (lut_write_data),
    .swap_lut     (lut_swap),
    .swap_done    (),
    .boot_load    (lut_boot_load),
    .boot_table_id(lut_boot_table_id),
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
    .inject_data         (test_inject_valid ? test_inject_data : inject_data),
    .inject_valid        (test_inject_valid ? test_inject_valid : inject_valid),
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

  assign test_inject_ready = inject_ready;
  assign test_eject_data   = eject_data;
  assign test_eject_valid  = eject_valid;
  assign test_l1_valid     = l1_N_valid | l1_E_valid | l1_S_valid | l1_W_valid;
  assign test_l2_valid     = l2_E_valid | l2_W_valid;

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

  // ============================================================
  // L1 Expressway router (highway nodes only; inert elsewhere)
  // L1 offload from the L0 router enters via local_in; flits whose
  // destination is inside this highway node's tile are returned through
  // local_out into the L0 router's LOCAL port for final delivery.
  // ============================================================
  logic [63:0] l1_deliver_data;
  logic        l1_deliver_valid;
  logic        l1_deliver_ready;

  router_l1 l1_router (
    .port_in_data     ({l1_W_in_data, l1_S_in_data, l1_E_in_data, l1_N_in_data}),
    .port_in_valid    ({l1_W_in_valid, l1_S_in_valid, l1_E_in_valid, l1_N_in_valid}),
    .port_in_ready    ({l1_W_in_ready, l1_S_in_ready, l1_E_in_ready, l1_N_in_ready}),
    .port_out_data    ({l1_W_data,     l1_S_data,     l1_E_data,     l1_N_data}),
    .port_out_valid   ({l1_W_valid,    l1_S_valid,    l1_E_valid,    l1_N_valid}),
    .port_out_ready   ({l1_W_ready,    l1_S_ready,    l1_E_ready,    l1_N_ready}),
    .local_in_data    (l1_offload_data),
    .local_in_valid   (l1_offload_valid),
    .local_in_ready   (l1_offload_ready),
    .local_out_data   (l1_deliver_data),
    .local_out_valid  (l1_deliver_valid),
    .local_out_ready  (l1_deliver_ready),
    .pe_x             (pe_x),
    .pe_y             (pe_y),
    .clk_noc          (clk_noc),
    .rst_n            (rst_n)
  );

  // L1 delivery re-injects into the L0 router via the LOCAL port
  assign router_pin_data[0]  = l1_deliver_data;
  assign router_pin_valid[0] = l1_deliver_valid;
  assign l1_deliver_ready    = router_pin_ready[0];

  // ============================================================
  // L2 SN-boundary router (boundary highway nodes only; inert elsewhere).
  // Router port [0]=E (to the east of the SN boundary), [1]=W (west).
  // ============================================================
  logic [63:0] l2_deliver_data;
  logic        l2_deliver_valid;
  logic        l2_deliver_ready;
  logic        l2_local_ready;

  router_l2 l2_router (
    .port_in_data    ({l2_W_in_data, l2_E_in_data}),
    .port_in_valid   ({l2_W_in_valid, l2_E_in_valid}),
    .port_in_ready   ({l2_W_in_ready, l2_E_in_ready}),
    .port_out_data   ({l2_W_data, l2_E_data}),
    .port_out_valid  ({l2_W_valid, l2_E_valid}),
    .port_out_ready  ({l2_W_ready, l2_E_ready}),
    .local_in_data   (l1_offload_data),
    .local_in_valid  (l1_offload_valid),
    .local_in_ready  (l2_local_ready),
    .local_out_data  (l2_deliver_data),
    .local_out_valid (l2_deliver_valid),
    .local_out_ready (l2_deliver_ready),
    .pe_x            (pe_x),
    .pe_y            (pe_y),
    .clk_noc         (clk_noc),
    .rst_n           (rst_n)
  );

  assign l2_deliver_ready = 1'b0;  // L2 local egress unused (pass-through mesh)
  // l2_local_ready is driven by the l2_router's local_in_ready output
  // (== local_out_ready == 0), so no external drive is needed here.

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
      status_reg <= {{14{status_out[1]}}, status_out};  // sign-extend: -1 -> 0xFFFF
    else if (scalar_recv)
      status_reg <= {15'd0, eject_valid};                // RECV: 1=received, 0=empty
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

  assign sram_addr_d_final = vec_nd ? reg_r6 : cce_sram_addr_d;

  // SRAM Bank2 write data mux
  always_comb begin
    if (lut_read) begin
      for (int i = 0; i < VECTOR_LANE_WIDTH; i++)
        sram_data2_in[i*8 +: 8] = lut_entry_out;
    end else begin
      sram_data2_in = vec_result;
    end
  end

  `ifdef PE_DBG
  always_ff @(posedge clk_noc or negedge rst_n) begin
    if (rst_n && (inject_router_valid || eject_router_valid || eject_valid ||
                  l1_deliver_valid || router_pin_valid[7]))
      $strobe("[%0t] PE(%0d,%0d) l1dV=%0b pinV7=%0b pinV0=%0b ejRV=%0b ejRRDY=%0b injRV=%0b dst(%0d,%0d)",
               $time, pe_x, pe_y, l1_deliver_valid, router_pin_valid[7], router_pin_valid[0],
               eject_router_valid, eject_router_ready, inject_router_valid,
               eject_router_data[55:48], eject_router_data[63:56]);
  end
  `endif

endmodule
