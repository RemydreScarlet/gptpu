import gptpu_pkg::*;

module scalar_ctrl (
  // 16-bit integer ALU
  input  logic [15:0] a, b,
  input  logic [2:0]  opcode,  // 0=ADD, 1=SUB, 2=AND, 3=OR, 4=XOR, 5=SHL, 6=SHR, 7=CMP

  // Register file (8 x 16-bit)
  input  logic [2:0]  rs_addr, rt_addr, rd_addr,
  input  logic        reg_we,
  input  logic [15:0] reg_wdata,
  output logic [15:0] reg_rs, reg_rt, reg_rd,
  output logic [15:0] reg_r6,           // R6 (used as D_ADDR for vector non-destructive)
  output logic [15:0] alu_result,

  // Comparison output (for branch)
  output logic        cmp_eq, cmp_lt, cmp_gt,

  // Loop counter (LC) — implicit register
  input  logic        lc_dec,     // DJNZ: decrement loop counter
  output logic        lc_zero,    // DJNZ condition
  input  logic [15:0] lc_init,
  input  logic        lc_load,

  // Clock & reset
  input  logic clk_pe,
  input  logic rst_n
);

  // --- Register file ---
  logic [15:0] regfile [7:0];

  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 8; i++) regfile[i] <= '0;
    end else if (reg_we) begin
      regfile[rd_addr] <= reg_wdata;
    end
  end

  assign reg_rs = regfile[rs_addr];
  assign reg_rt = regfile[rt_addr];
  assign reg_rd = regfile[rd_addr];
  assign reg_r6 = regfile[6];

  // --- Loop counter ---
  logic [15:0] lc;

  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n)
      lc <= '0;
    else if (lc_load)
      lc <= lc_init;
    else if (lc_dec)
      lc <= lc - 1;
  end

  assign lc_zero = (lc == 16'd0);

  // --- ALU ---
  always_comb begin
    unique case (opcode)
      3'd0: alu_result = a + b;
      3'd1: alu_result = a - b;
      3'd2: alu_result = a & b;
      3'd3: alu_result = a | b;
      3'd4: alu_result = a ^ b;
      3'd5: alu_result = a << b[3:0];
      3'd6: alu_result = a >> b[3:0];
      3'd7: begin
        cmp_eq = (a == b);
        cmp_lt = (a < b);
        cmp_gt = (a > b);
        alu_result = '0;
      end
      default: alu_result = '0;
    endcase
  end

endmodule
