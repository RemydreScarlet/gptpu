package gptpu_pkg;

  // ============================================================
  // GPTPU Common Parameters & Types
  // ============================================================

  // --- Grid Dimensions ---
  localparam int PE_GRID_X       = 16;
  localparam int PE_GRID_Y       = 8;
  localparam int NUM_PE          = PE_GRID_X * PE_GRID_Y;
  localparam int SN_GRID_X       = 4;
  localparam int SN_GRID_Y       = 4;
  localparam int PES_PER_SN      = (PE_GRID_X / SN_GRID_X) * (PE_GRID_Y / SN_GRID_Y);

  // --- SRAM Sizes (bytes) ---
  localparam int SRAM_BANK0_SIZE = 256 * 1024;  // 256 KB - Matrix tiles
  localparam int SRAM_BANK1_SIZE = 128 * 1024;  // 128 KB - Activations / KV cache
  localparam int SRAM_BANK2_SIZE = 64 * 1024;   //  64 KB - LUTs + scratch
  localparam int SRAM_BANK3_SIZE = 64 * 1024;   //  64 KB - scratch / spill
  localparam int SRAM_TOTAL_SIZE = SRAM_BANK0_SIZE + SRAM_BANK1_SIZE
                                   + SRAM_BANK2_SIZE + SRAM_BANK3_SIZE;

  // --- Vector Lane ---
  localparam int VECTOR_LANE_WIDTH  = 8;       // 8-wide
  localparam int FP8_E4M3_WIDTH     = 8;
  localparam int SRAM_LINE_WIDTH    = 64 * 8;  // 64 bytes = 512 bits
  localparam int SRAM_LINE_BYTES    = 64;

  // --- Microcode ---
  localparam int MICROCODE_SIZE    = 8192;     // 8 KB per SN
  localparam int MICROCODE_WIDTH   = 32;       // 32-bit fixed-length ISA
  localparam int MICROCODE_WORDS   = MICROCODE_SIZE / (MICROCODE_WIDTH / 8);

  // --- LUT ---
  localparam int LUT_TABLES       = 16;
  localparam int LUT_ENTRIES      = 256;
  localparam int LUT_ENTRY_WIDTH  = 8;         // FP8

  // --- NoC ---
  localparam int NOC_DATA_WIDTH   = 64;        // 8-wide FP8 = 64 bits
  localparam int NOC_FLIT_WIDTH   = NOC_DATA_WIDTH;
  localparam int NOC_FIFO_DEPTH   = 2;         // 2-stage async FIFO

  // --- DDR / Stream ---
  localparam int DDR_CACHE_LINE   = 128;       // bytes
  localparam int DDR_BUS_WIDTH    = 512;       // bits (LPDDR5-6400 x64)
  localparam int DDR_CREDIT_MAX   = 256;

  // --- SKU Parameters ---
  typedef enum int {
    GPTPU_S  = 0,
    GPTPU_M  = 1,
    GPTPU_L  = 2,
    GPTPU_XL = 3
  } sku_t;

  // ============================================================
  // Type Definitions
  // ============================================================

  typedef logic [7:0] fp8_e4m3_t;

  typedef struct packed {
    logic [63:0] data;
    logic        valid;
    logic        ready;
  } noc_channel_t;

  typedef struct packed {
    logic [FP8_E4M3_WIDTH-1:0] data [VECTOR_LANE_WIDTH-1:0];
  } vector_line_t;

  typedef struct packed {
    logic [7:0] dst_x;
    logic [7:0] dst_y;
    logic [2:0] mode;  // 000=UNICAST, 001=BCAST_ROW, 010=BCAST_COL, 011=BCAST_ALL
  } routing_info_t;

  typedef struct packed {
    logic [MICROCODE_WIDTH-1:0] instr;
  } microcode_word_t;

  // Boot ROM LUT initializers (Tanh, Exp, 1/sqrt)
  function automatic fp8_e4m3_t lut_boot_tanh(input int idx);
    return fp8_e4m3_t'(idx);
  endfunction

  function automatic fp8_e4m3_t lut_boot_exp(input int idx);
    return fp8_e4m3_t'(idx);
  endfunction

  function automatic fp8_e4m3_t lut_boot_rsqrt(input int idx);
    return fp8_e4m3_t'(idx);
  endfunction

endpackage
