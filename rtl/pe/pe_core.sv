import gptpu_pkg::*;

module pe_core (
  // Position in grid
  input  logic [7:0] pe_x, pe_y,

  // NoC interfaces (L0, L1, L2)
  noc_channel_t noc [8],  // 8 directional L0

  // L1 (highway)
  input  noc_channel_t l1_in,
  output noc_channel_t l1_out,

  // L2 (SN boundary)
  input  noc_channel_t l2_in,
  output noc_channel_t l2_out,

  // Microcode memory interface (SN-level shared)
  input  microcode_word_t instr,
  input  logic            instr_valid,
  output logic [12:0]     pc,

  // DDR stream interface
  input  logic [511:0] stream_data,
  input  logic         stream_valid,
  output logic         stream_ready,

  // Local clocks
  input  logic clk_pe,
  input  logic clk_noc,
  input  logic rst_n
);

  logic is_highway_node;
  logic is_boundary_node;

  assign is_highway_node  = (pe_x % 4 == 0) && (pe_y % 4 == 0);
  assign is_boundary_node = (pe_x % 4 == 0) && (pe_y % 4 == 0);  // SN boundary

  // --- Internal signal wiring ---
  logic [3:0]  vec_opcode;
  logic        vec_acc_en, vec_sat_en;
  logic [15:0] sram_addr_a, sram_addr_b, sram_addr_d;
  logic        sram_we;

  logic [2:0]  scalar_opcode;
  logic [2:0]  scalar_rs, scalar_rt, scalar_rd;
  logic        scalar_reg_we;
  logic [15:0] scalar_imm;
  logic        lc_load, lc_dec;
  logic [15:0] lc_init;

  logic [7:0]  lut_addr;
  logic [3:0]  lut_table_id;
  logic        lut_swap;

  logic [7:0]  noc_dst_x, noc_dst_y;
  logic [2:0]  noc_mode;
  logic        noc_send;

  logic        cmp_eq, cmp_lt, cmp_gt;
  logic        lc_zero, branch_taken;

  // --- SRAM lines ---
  vector_line_t line_a, line_b, vec_result;
  logic [511:0] sram_data0_in, sram_data0_out;
  logic [511:0] sram_data1_in, sram_data1_out;
  logic [511:0] sram_data2_in, sram_data2_out;
  logic [511:0] sram_data3_in, sram_data3_out;

  // --- Sub-module instances ---

  sram_512kb sram (
    .addr0 (sram_addr_a[15:0]),
    .cs0   (1'b1),
    .we0   (1'b0),
    .data0 (sram_data0_out),
    .addr1 (sram_addr_b[15:0]),
    .cs1   (1'b1),
    .we1   (1'b0),
    .data1 (sram_data1_out),
    .addr2 (sram_addr_d[15:0]),
    .cs2   (sram_we),
    .we2   (sram_we),
    .data2 (sram_data2_in),
    .addr3 (sram_addr_d[15:0]),
    .cs3   (1'b0),
    .we3   (1'b0),
    .data3 (sram_data3_out),
    .clk_pe (clk_pe),
    .rst_n  (rst_n)
  );

  vector_lane vlane (
    .line_a   (line_a),
    .line_b   (line_b),
    .opcode   (vec_opcode),
    .acc_en   (vec_acc_en),
    .sat_en   (vec_sat_en),
    .result   (vec_result),
    .clk_pe   (clk_pe),
    .rst_n    (rst_n)
  );

  scalar_ctrl scalar (
    .a        (scalar_imm),
    .b        (16'd0),
    .opcode   (scalar_opcode),
    .rs_addr  (scalar_rs),
    .rt_addr  (scalar_rt),
    .rd_addr  (scalar_rd),
    .reg_we   (scalar_reg_we),
    .reg_wdata(16'd0),
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
    .swap_lut    (lut_swap),
    .clk_pe      (clk_pe),
    .rst_n       (rst_n)
  );

  coupled_compute_engine cce (
    .instr        (instr),
    .instr_valid  (instr_valid),
    .pc           (pc),
    .vec_opcode   (vec_opcode),
    .vec_acc_en   (vec_acc_en),
    .vec_sat_en   (vec_sat_en),
    .sram_addr_a  (sram_addr_a),
    .sram_addr_b  (sram_addr_b),
    .sram_addr_d  (sram_addr_d),
    .sram_we      (sram_we),
    .scalar_opcode(scalar_opcode),
    .scalar_rs    (scalar_rs),
    .scalar_rt    (scalar_rt),
    .scalar_rd    (scalar_rd),
    .scalar_reg_we(scalar_reg_we),
    .scalar_imm   (scalar_imm),
    .lc_load      (lc_load),
    .lc_dec       (lc_dec),
    .lc_init      (lc_init),
    .lut_addr     (lut_addr),
    .lut_table_id (lut_table_id),
    .lut_swap     (lut_swap),
    .noc_dst_x    (noc_dst_x),
    .noc_dst_y    (noc_dst_y),
    .noc_mode     (noc_mode),
    .noc_send     (noc_send),
    .cmp_eq       (cmp_eq),
    .cmp_lt       (cmp_lt),
    .cmp_gt       (cmp_gt),
    .lc_zero      (lc_zero),
    .branch_taken (branch_taken),
    .clk_pe       (clk_pe),
    .rst_n        (rst_n)
  );

  async_port_controller apc (
    .is_highway_node  (is_highway_node),
    .is_boundary_node (is_boundary_node),
    .pe_in            (noc[0]),
    .l1_in            (l1_in),
    .l1_out           (l1_out),
    .l2_in            (l2_in),
    .l2_out           (l2_out),
    .clk_pe           (clk_pe),
    .clk_noc          (clk_noc),
    .rst_n            (rst_n)
  );

  // --- Floorplan: SRAM line → Vector Lane → SRAM line ---
  assign line_a = vector_line_t'(sram_data0_out);
  assign line_b = vector_line_t'(sram_data1_out);
  assign sram_data2_in = vec_result;

endmodule
