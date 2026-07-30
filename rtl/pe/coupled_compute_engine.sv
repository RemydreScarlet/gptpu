import gptpu_pkg::*;

module coupled_compute_engine (
  // Microcode memory interface (shared SN-level)
  input  microcode_word_t instr,
  input  logic            instr_valid,
  output logic [12:0]     pc,

  // Vector lane control
  output logic [3:0]      vec_opcode,
  output logic            vec_acc_en,
  output logic            vec_sat_en,
  output logic            vec_nd,         // non-destructive: dest addr from R6
  output logic [15:0]     sram_addr_a, sram_addr_b, sram_addr_d,
  output logic            sram_we,

  // Scalar control
  output logic [2:0]      scalar_opcode,
  output logic [2:0]      scalar_rs, scalar_rt, scalar_rd,
  output logic            scalar_reg_we,
  output logic [15:0]     scalar_imm,
  output logic            lc_load, lc_dec,
  output logic [15:0]     lc_init,

  // Scalar extended
  output logic            scalar_imm_sel,  // 1=write imm to regfile (LDI)
  output logic            scalar_ld,        // 1=LD instruction
  output logic            scalar_st,        // 1=ST instruction
  output logic            scalar_test_en,   // 1=TEST instruction
  output logic            scalar_recv,      // 1=RECV instruction
  output logic [3:0]      scalar_send_src,  // SEND/BCAST source register addr
  output logic            status_we,        // 1=SCMP: update status reg
  input  logic [1:0]      status_in,        // current status value
  output logic [1:0]      status_out,       // new status value for SCMP
  input  logic            pc_stall,         // hold PC (RECV with no data)

  // LUT control
  output logic [7:0]      lut_addr,
  output logic [3:0]      lut_table_id,
  output logic            lut_swap,
  output logic            lut_read,         // 1=read LUT to SRAM

  // NoC / routing
  output logic [7:0]      noc_dst_x, noc_dst_y,
  output logic [2:0]      noc_mode,
  output logic            noc_send,

  // Branch
  input  logic            cmp_eq, cmp_lt, cmp_gt,
  input  logic            lc_zero,
  output logic            branch_taken,

  // Clock & reset
  input  logic clk_pe,
  input  logic rst_n
);

  // --- ISA opcode fields ---
  typedef enum logic [6:0] {
    OP_NOP    = 7'h00,
    OP_VMAC   = 7'h01,
    OP_VADD   = 7'h02,
    OP_VSUB   = 7'h03,
    OP_VMUL   = 7'h04,
    OP_VMIN   = 7'h05,
    OP_VMAX   = 7'h06,
    OP_SADD   = 7'h10,
    OP_SSUB   = 7'h11,
    OP_SAND   = 7'h12,
    OP_SOR    = 7'h13,
    OP_SXOR   = 7'h14,
    OP_SSHL   = 7'h15,
    OP_SSHR   = 7'h16,
    OP_SCMP   = 7'h17,
    OP_LD     = 7'h20,
    OP_ST     = 7'h21,
    OP_LDI    = 7'h22,
    OP_LUT    = 7'h23,
    OP_SWAPL  = 7'h24,
    OP_BNE    = 7'h30,
    OP_BEQ    = 7'h31,
    OP_BLT    = 7'h32,
    OP_BGT    = 7'h33,
    OP_DJNZ   = 7'h34,
    OP_JMP    = 7'h35,
    OP_JAL    = 7'h36,
    OP_RET    = 7'h37,
    OP_BCAST  = 7'h40,
    OP_SEND   = 7'h41,
    OP_RECV   = 7'h42,
    OP_STREAMV = 7'h50,
    OP_STREAMS = 7'h51,
    OP_SYNC   = 7'h52,
    OP_FENCE  = 7'h53,
    OP_HALT   = 7'h7F
  } opcode_t;

  // --- PC logic ---
  logic [12:0] pc_reg, pc_next;
  logic [12:0] link_reg;

  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n)
      pc_reg <= '0;
    else
      pc_reg <= pc_next;
  end

  // --- Instruction decode ---
  opcode_t op;
  logic [24:0] imm;

  assign op = opcode_t'(instr.instr[31:25]);
  assign imm = instr.instr[24:0];

  // --- Branch offset sign extension ---
  logic signed [12:0] branch_offset;
  assign branch_offset = imm[12:0];

  // --- Default outputs ---
  always_comb begin
    vec_opcode    = '0;
    vec_acc_en    = 1'b0;
    vec_sat_en    = 1'b0;
    vec_nd        = 1'b0;
    sram_addr_a   = '0;
    sram_addr_b   = '0;
    sram_addr_d   = '0;
    sram_we       = 1'b0;
    scalar_opcode = '0;
    scalar_rs     = '0;
    scalar_rt     = '0;
    scalar_rd     = '0;
    scalar_reg_we = 1'b0;
    scalar_imm    = '0;
    lc_load       = 1'b0;
    lc_dec        = 1'b0;
    lc_init       = '0;
    lut_addr      = '0;
    lut_table_id  = '0;
    lut_swap      = 1'b0;
    lut_read      = 1'b0;
    noc_dst_x     = '0;
    noc_dst_y     = '0;
    noc_mode      = '0;
    noc_send      = 1'b0;
    branch_taken  = 1'b0;
    scalar_imm_sel = 1'b0;
    scalar_ld     = 1'b0;
    scalar_st     = 1'b0;
    scalar_test_en = 1'b0;
    scalar_recv   = 1'b0;
    scalar_send_src = '0;
    status_we     = 1'b0;
    status_out    = status_in;
    pc_next       = pc_reg + 1;

    if (!instr_valid || pc_stall) begin
      pc_next = pc_reg;
    end else begin
      unique case (op)
        // --- Vector ops ---
        OP_VMAC: begin
          vec_opcode  = 4'd0;
          if (imm[24]) begin
            sram_addr_d = imm[15:0];
            sram_we     = 1'b1;
          end else begin
            sram_addr_a = imm[15:0];
            sram_addr_b = imm[23:16];
            vec_acc_en  = 1'b1;
          end
        end
        OP_VADD: begin
          vec_opcode  = 4'd1;
          sram_addr_a = imm[15:0];
          sram_addr_b = imm[23:16];
          sram_addr_d = imm[15:0];
          vec_nd      = imm[24];
          sram_we     = 1'b1;
        end
        OP_VSUB: begin
          vec_opcode  = 4'd2;
          sram_addr_a = imm[15:0];
          sram_addr_b = imm[23:16];
          sram_addr_d = imm[15:0];
          vec_nd      = imm[24];
          sram_we     = 1'b1;
        end
        OP_VMUL: begin
          vec_opcode  = 4'd3;
          sram_addr_a = imm[15:0];
          sram_addr_b = imm[23:16];
          sram_addr_d = imm[15:0];
          vec_nd      = imm[24];
          sram_we     = 1'b1;
        end
        OP_VMIN: begin
          vec_opcode  = 4'd4;
          sram_addr_a = imm[15:0];
          sram_addr_b = imm[23:16];
          sram_addr_d = imm[15:0];
          vec_nd      = imm[24];
          sram_we     = 1'b1;
        end
        OP_VMAX: begin
          vec_opcode  = 4'd5;
          sram_addr_a = imm[15:0];
          sram_addr_b = imm[23:16];
          sram_addr_d = imm[15:0];
          vec_nd      = imm[24];
          sram_we     = 1'b1;
        end

        // --- Scalar ops ---
        OP_SADD: begin
          scalar_opcode = 3'd0;
          scalar_rs     = imm[2:0];
          scalar_rt     = imm[5:3];
          scalar_rd     = imm[8:6];
          scalar_reg_we = 1'b1;
        end
        OP_SSUB: begin
          scalar_opcode = 3'd1;
          scalar_rs     = imm[2:0];
          scalar_rt     = imm[5:3];
          scalar_rd     = imm[8:6];
          scalar_reg_we = 1'b1;
        end
        OP_SAND: begin
          scalar_opcode = 3'd2;
          scalar_rs     = imm[2:0];
          scalar_rt     = imm[5:3];
          scalar_rd     = imm[8:6];
          scalar_reg_we = 1'b1;
        end
        OP_SOR: begin
          scalar_opcode = 3'd3;
          scalar_rs     = imm[2:0];
          scalar_rt     = imm[5:3];
          scalar_rd     = imm[8:6];
          scalar_reg_we = 1'b1;
        end
        OP_SXOR: begin
          scalar_opcode = 3'd4;
          scalar_rs     = imm[2:0];
          scalar_rt     = imm[5:3];
          scalar_rd     = imm[8:6];
          scalar_reg_we = 1'b1;
        end
        OP_SSHL: begin
          scalar_opcode = 3'd5;
          scalar_rs     = imm[2:0];
          scalar_rt     = imm[5:3];
          scalar_rd     = imm[8:6];
          scalar_reg_we = 1'b1;
        end
        OP_SSHR: begin
          scalar_opcode = 3'd6;
          scalar_rs     = imm[2:0];
          scalar_rt     = imm[5:3];
          scalar_rd     = imm[8:6];
          scalar_reg_we = 1'b1;
        end
        OP_SCMP: begin
          scalar_opcode = 3'd7;
          scalar_rs     = imm[2:0];
          scalar_rt     = imm[5:3];
          status_we     = 1'b1;
          status_out    = (cmp_eq ? 2'd0 : cmp_lt ? 2'd1 : 2'd2);
        end

        // --- LDI / LD / ST ---
        OP_LDI: begin
          scalar_rd      = imm[22:20];
          scalar_imm     = imm[19:0];
          scalar_imm_sel = 1'b1;
          scalar_reg_we  = 1'b1;
        end
        OP_LD: begin
          scalar_rd  = imm[22:20];
          sram_addr_a = imm[15:0];
          scalar_ld  = 1'b1;
          scalar_reg_we = 1'b1;
        end
        OP_ST: begin
          scalar_rs  = imm[22:20];
          sram_addr_a = imm[15:0];
          scalar_st  = 1'b1;
        end

        // --- LUT ops ---
        OP_LUT: begin
          lut_addr     = imm[7:0];
          lut_table_id = imm[11:8];
          lut_read     = 1'b1;
          sram_addr_d  = '0;
          sram_we      = 1'b1;
        end
        OP_SWAPL: begin
          lut_swap = 1'b1;
        end

        // --- Branch / control ---
        OP_BNE: begin
          if (!cmp_eq) begin
            pc_next = pc_reg + 13'(1) + $signed(branch_offset);
            branch_taken = 1'b1;
          end
        end
        OP_BEQ: begin
          if (cmp_eq) begin
            pc_next = pc_reg + 13'(1) + $signed(branch_offset);
            branch_taken = 1'b1;
          end
        end
        OP_BLT: begin
          if (cmp_lt) begin
            pc_next = pc_reg + 13'(1) + $signed(branch_offset);
            branch_taken = 1'b1;
          end
        end
        OP_BGT: begin
          if (cmp_gt) begin
            pc_next = pc_reg + 13'(1) + $signed(branch_offset);
            branch_taken = 1'b1;
          end
        end
        OP_DJNZ: begin
          lc_dec = 1'b1;
          if (!lc_zero) begin
            pc_next = pc_reg + 13'(1) + $signed(branch_offset);
            branch_taken = 1'b1;
          end
        end
        OP_JMP: begin
          pc_next = imm[12:0];
          branch_taken = 1'b1;
        end
        OP_JAL: begin
          link_reg = pc_reg + 1;
          pc_next = imm[12:0];
          branch_taken = 1'b1;
        end
        OP_RET: begin
          pc_next = link_reg;
          branch_taken = 1'b1;
        end

        // --- NoC ops ---
        OP_BCAST: begin
          noc_dst_x = imm[7:0];
          noc_dst_y = imm[15:8];
          noc_mode  = imm[18:16];
          scalar_send_src = imm[23:20];
          scalar_rs = imm[23:20];
          noc_send  = 1'b1;
        end
        OP_SEND: begin
          noc_dst_x = imm[7:0];
          noc_dst_y = imm[15:8];
          scalar_send_src = imm[19:16];
          scalar_rs = imm[19:16];
          noc_mode  = 3'd0;
          noc_send  = 1'b1;
        end
        OP_RECV: begin
          scalar_rd = imm[19:16];
          scalar_recv = 1'b1;
          if (!pc_stall) begin
            scalar_reg_we = 1'b1;
          end
        end

        // --- Status / TEST ---
        OP_TEST: begin
          scalar_rd      = imm[18:16];
          scalar_test_en = 1'b1;
          scalar_reg_we  = 1'b1;
        end

        // --- Stream ops ---
        OP_STREAMV: begin
        end
        OP_STREAMS: begin
        end

        OP_HALT: begin
          pc_next = pc_reg;
        end

        default: begin
        end
      endcase
    end
  end

  assign pc = pc_reg;

endmodule
