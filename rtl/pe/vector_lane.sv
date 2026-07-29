import gptpu_pkg::*;

module vector_lane (
  // SRAM line input (64B = 8 x FP8)
  input  vector_line_t line_a,
  input  vector_line_t line_b,

  // Control
  input  logic [3:0]  opcode,  // 0=VMAC, 1=VADD, 2=VSUB, 3=VMUL, 4=VMIN, 5=VMAX
  input  logic        acc_en,  // accumulate enable (for VMAC)
  input  logic        sat_en,  // saturation enable

  // Result
  output vector_line_t result,

  // Clock & reset
  input  logic clk_pe,
  input  logic rst_n
);

  // --- FP8 MAC array ---
  fp8_e4m3_t mac_acc [VECTOR_LANE_WIDTH-1:0];

  always_ff @(posedge clk_pe or negedge rst_n) begin
    for (int i = 0; i < VECTOR_LANE_WIDTH; i++) begin
      if (!rst_n) begin
        mac_acc[i] <= '0;
      end else if (acc_en && opcode == 4'd0) begin
        mac_acc[i] <= fp8_e4m3_t'(mac_acc[i] + line_a.data[i] * line_b.data[i]);
      end else if (!acc_en) begin
        mac_acc[i] <= '0;
      end
    end
  end

  // --- Combinatorial ALU ---
  always_comb begin
    for (int i = 0; i < VECTOR_LANE_WIDTH; i++) begin
      unique case (opcode)
        4'd0: result.data[i] = mac_acc[i];                          // VMAC (pipelined)
        4'd1: result.data[i] = fp8_e4m3_t'(line_a.data[i] + line_b.data[i]); // VADD
        4'd2: result.data[i] = fp8_e4m3_t'(line_a.data[i] - line_b.data[i]); // VSUB
        4'd3: result.data[i] = fp8_e4m3_t'(line_a.data[i] * line_b.data[i]); // VMUL
        4'd4: result.data[i] = (line_a.data[i] < line_b.data[i]) ? line_a.data[i] : line_b.data[i]; // VMIN
        4'd5: result.data[i] = (line_a.data[i] > line_b.data[i]) ? line_a.data[i] : line_b.data[i]; // VMAX
        default: result.data[i] = '0;
      endcase
    end
  end

endmodule
