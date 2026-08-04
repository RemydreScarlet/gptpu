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

  // --- Unpacked FP8 lanes (packed vector_line_t <-> unpacked conversion below) ---
  fp8_e4m3_t a_arr [VECTOR_LANE_WIDTH-1:0];
  fp8_e4m3_t b_arr [VECTOR_LANE_WIDTH-1:0];
  fp8_e4m3_t res_arr[VECTOR_LANE_WIDTH-1:0];
  fp8_e4m3_t acc_arr[VECTOR_LANE_WIDTH-1:0];

  genvar gi;
  generate
    for (gi = 0; gi < VECTOR_LANE_WIDTH; gi++) begin : gen_lane_conv
      assign a_arr[gi] = line_a[gi*8 +: 8];
      assign b_arr[gi] = line_b[gi*8 +: 8];
      assign result[gi*8 +: 8] = res_arr[gi];
      assign mac_acc_out[gi*8 +: 8] = acc_arr[gi];
    end
  endgenerate

  // --- Local wrappers around package FP8 primitives ---
  function automatic fp8_e4m3_t vadd(input fp8_e4m3_t a, input fp8_e4m3_t b);
    return fp8_pkg::fp8_add(a, b);
  endfunction
  function automatic fp8_e4m3_t vsub(input fp8_e4m3_t a, input fp8_e4m3_t b);
    return fp8_pkg::fp8_sub(a, b);
  endfunction
  function automatic fp8_e4m3_t vmul(input fp8_e4m3_t a, input fp8_e4m3_t b);
    return fp8_pkg::fp8_mul(a, b);
  endfunction

  // --- FP8 MAC array ---
  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < VECTOR_LANE_WIDTH; i++) acc_arr[i] <= '0;
    end else if (acc_en && opcode == 4'd0) begin
      for (int i = 0; i < VECTOR_LANE_WIDTH; i++) begin
        acc_arr[i] <= vadd(acc_arr[i], vmul(a_arr[i], b_arr[i]));
      end
    end else if (!acc_en) begin
      for (int i = 0; i < VECTOR_LANE_WIDTH; i++) acc_arr[i] <= '0;
    end
  end

  // --- Combinatorial ALU ---
  always_comb begin
    for (int i = 0; i < VECTOR_LANE_WIDTH; i++) begin
      unique case (opcode)
        4'd0: res_arr[i] = acc_arr[i];                                         // VMAC (pipelined)
        4'd1: res_arr[i] = vadd(a_arr[i], b_arr[i]);                           // VADD
        4'd2: res_arr[i] = vsub(a_arr[i], b_arr[i]);                           // VSUB
        4'd3: res_arr[i] = vmul(a_arr[i], b_arr[i]);                           // VMUL
        4'd4: res_arr[i] = (a_arr[i] < b_arr[i]) ? a_arr[i] : b_arr[i];        // VMIN
        4'd5: res_arr[i] = (a_arr[i] > b_arr[i]) ? a_arr[i] : b_arr[i];        // VMAX
        default: res_arr[i] = '0;
      endcase
    end
  end

endmodule