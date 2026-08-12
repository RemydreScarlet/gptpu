import gptpu_pkg::*;
import fp8_pkg::*;

module vector_lane (
  // SRAM line input (8 x FP8 = 64 bits)
  input  vector_line_t line_a,
  input  vector_line_t line_b,

  // Control
  input  logic [3:0]  opcode,  // 0=VMAC, 1=VADD, 2=VSUB, 3=VMUL, 4=VMIN, 5=VMAX
  input  logic        acc_en,  // accumulate enable (for VMAC)
  input  logic        sat_en,  // saturation enable

  // Result
  output vector_line_t result,
  output vector_line_t mac_acc_out,  // for VMAC writeback

  // Clock & reset
  input  logic clk_pe,
  input  logic rst_n
);

  // Fully packed accumulator (8 lanes x 8 bits). No unpacked arrays: iverilog
  // does not simulate variable-indexed unpacked-array access correctly inside
  // procedural blocks, so all lanes are accessed via packed part-selects.
  logic [VECTOR_LANE_WIDTH*8-1:0] acc_vec;

  // --- FP8 MAC accumulate (sequential) ---
  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n) begin
      acc_vec <= '0;
    end else if (acc_en && opcode == 4'd0) begin
      for (int i = 0; i < VECTOR_LANE_WIDTH; i++)
        acc_vec[i*8 +: 8] <= fp8_pkg::fp8_add(acc_vec[i*8 +: 8],
                                               fp8_pkg::fp8_mul(line_a[i*8 +: 8],
                                                                line_b[i*8 +: 8]));
    end else if (!acc_en) begin
      acc_vec <= '0;
    end
  end

  // --- Combinatorial ALU ---
  always_comb begin
    for (int i = 0; i < VECTOR_LANE_WIDTH; i++) begin
      unique case (opcode)
        4'd0: result[i*8 +: 8] = acc_vec[i*8 +: 8];                                              // VMAC (pipelined)
        4'd1: result[i*8 +: 8] = fp8_pkg::fp8_add(line_a[i*8 +: 8], line_b[i*8 +: 8]);           // VADD
        4'd2: result[i*8 +: 8] = fp8_pkg::fp8_sub(line_a[i*8 +: 8], line_b[i*8 +: 8]);           // VSUB
        4'd3: result[i*8 +: 8] = fp8_pkg::fp8_mul(line_a[i*8 +: 8], line_b[i*8 +: 8]);           // VMUL
        4'd4: result[i*8 +: 8] = fp8_pkg::fp8_lt (line_a[i*8 +: 8], line_b[i*8 +: 8])
                                   ? line_a[i*8 +: 8] : line_b[i*8 +: 8];                        // VMIN (signed)
        4'd5: result[i*8 +: 8] = fp8_pkg::fp8_gt (line_a[i*8 +: 8], line_b[i*8 +: 8])
                                   ? line_a[i*8 +: 8] : line_b[i*8 +: 8];                        // VMAX (signed)
        default: result[i*8 +: 8] = '0;
      endcase
    end
  end

  assign mac_acc_out = acc_vec;

endmodule