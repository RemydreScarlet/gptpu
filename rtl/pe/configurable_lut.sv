import gptpu_pkg::*;

module configurable_lut (
  // Lookup interface
  input  logic [7:0]  entry_addr,    // 256 entries
  input  logic [3:0]  table_id,      // 0-15
  output fp8_e4m3_t   entry_out,

  // Write interface (for user tables 9-15 via DDR)
  input  logic        write_en,
  input  logic [3:0]  write_table,
  input  logic [7:0]  write_addr,
  input  fp8_e4m3_t   write_data,

  // Active/Shadow select (SWAPL)
  input  logic        swap_lut,      // 0=Active, 1=Shadow
  output logic        swap_done,

  // Boot ROM init
  input  logic        boot_load,
  input  logic [3:0]  boot_table_id,

  // Clock & reset
  input  logic clk_pe,
  input  logic rst_n
);

  // --- Dual-bank LUT storage (Active / Shadow) ---
  fp8_e4m3_t active_mem [LUT_TABLES-1:0][LUT_ENTRIES-1:0];
  fp8_e4m3_t shadow_mem [LUT_TABLES-1:0][LUT_ENTRIES-1:0];

  logic active_sel;

  // SWAPL: glitch-free mux select (1 cycle toggle)
  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n)
      active_sel <= 1'b1;  // Active bank selected after reset
    else if (swap_lut)
      active_sel <= ~active_sel;
  end

  assign swap_done = 1'b1;

  // --- Read path ---
  always_comb begin
    if (active_sel)
      entry_out = active_mem[table_id][entry_addr];
    else
      entry_out = shadow_mem[table_id][entry_addr];
  end

  // --- Write path ---
  integer t, e;

  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (rst_n && write_en && write_table >= 9 && write_table <= 15) begin
      if (active_sel)
        shadow_mem[write_table][write_addr] <= write_data;
      else
        active_mem[write_table][write_addr] <= write_data;
    end
  end

  // --- Boot ROM initialization ---
  function automatic fp8_e4m3_t boot_value(input int idx, input logic [3:0] tid);
    case (tid)
      4'd0:    boot_value = gptpu_pkg::lut_boot_tanh(idx);
      4'd1:    boot_value = gptpu_pkg::lut_boot_exp(idx);
      4'd2:    boot_value = gptpu_pkg::lut_boot_rsqrt(idx);
      default: boot_value = fp8_e4m3_t'(idx);
    endcase
  endfunction

  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (rst_n && boot_load) begin
      for (e = 0; e < LUT_ENTRIES; e++) begin
        active_mem[boot_table_id][e] = boot_value(e, boot_table_id);
      end
    end
  end

endmodule
