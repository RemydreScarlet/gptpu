import gptpu_pkg::*;

module gptpu_top (
  // DDR interfaces
  inout  wire [DDR_BUS_WIDTH-1:0] ddr_bus,
  output logic                     ddr_clk_p, ddr_clk_n,
  output logic                     ddr_cke, ddr_cs_n,
  output logic [1:0]               ddr_bg, ddr_ba,
  output logic [15:0]              ddr_addr,
  output logic                     ddr_ras_n, ddr_cas_n, ddr_we_n,

  // Clocks & resets (external oscillators per region)
  input  logic clk_ref,       // 100 MHz reference
  input  logic rst_n_ext
);

  // --- PE grid configuration ---
  localparam int X = PE_GRID_X;
  localparam int Y = PE_GRID_Y;

  // --- Internal clocks ---
  logic clk_pe_grid [X-1:0][Y-1:0];
  logic clk_noc;
  logic clk_ddr;
  logic clk_io;

  // --- Reset ---
  logic rst_n_sync;

  // --- PE NoC interconnect wires ---
  // L0: 3D array of channels [x][y][dir]
  noc_channel_t noc_l0 [X-1:0][Y-1:0][8];

  // L1 (highway): only at (x%4==0, y%4==0)
  noc_channel_t noc_l1_x [X/4][Y][4];  // row highway segments
  noc_channel_t noc_l1_y [X][Y/4][4];  // col highway segments

  // L2 (SN boundary)
  noc_channel_t noc_l2 [X][Y];

  // --- Microcode memory (SN-level) ---
  microcode_word_t microcode [NUM_PE];

  // --- DDR / Stream ---
  logic [511:0] stream_data;
  logic         stream_valid, stream_ready;
  logic [15:0]  credit_available;
  logic         credit_consume;

  // --- Reset synchronizer ---
  always_ff @(posedge clk_ref or negedge rst_n_ext) begin
    if (!rst_n_ext)
      rst_n_sync <= 1'b0;
    else
      rst_n_sync <= 1'b1;
  end

  // --- Clock generation (simplified PLL model) ---
  // In real implementation: PLL per PE for GALS
  assign clk_noc = clk_ref;
  assign clk_ddr = clk_ref;
  assign clk_io  = clk_ref;

  genvar x, y;
  generate
    for (x = 0; x < X; x++) begin : gen_pe_col
      for (y = 0; y < Y; y++) begin : gen_pe_row
        assign clk_pe_grid[x][y] = clk_ref;

        pe_core pe (
          .pe_x        (x[7:0]),
          .pe_y        (y[7:0]),
          .noc         (noc_l0[x][y]),
          .l1_in       (noc_l1_x[x/4][y][0]),
          .l1_out      (noc_l1_x[x/4][y][1]),
          .l2_in       (noc_l2[x][y]),
          .l2_out      (noc_l2[x][y]),
          .instr       (microcode[x * Y + y]),
          .instr_valid (1'b1),
          .pc          (),
          .stream_data (stream_data),
          .stream_valid(stream_valid),
          .stream_ready(stream_ready),
          .clk_pe      (clk_pe_grid[x][y]),
          .clk_noc     (clk_noc),
          .rst_n       (rst_n_sync)
        );
      end
    end
  endgenerate

  // --- DDR controller ---
  ddr_controller ddr_ctrl (
    .ddr_bus          (ddr_bus),
    .ddr_clk_p        (ddr_clk_p),
    .ddr_clk_n        (ddr_clk_n),
    .ddr_cke          (ddr_cke),
    .ddr_cs_n         (ddr_cs_n),
    .ddr_bg           (ddr_bg),
    .ddr_ba           (ddr_ba),
    .ddr_addr         (ddr_addr),
    .ddr_ras_n        (ddr_ras_n),
    .ddr_cas_n        (ddr_cas_n),
    .ddr_we_n         (ddr_we_n),
    .read_data_in     ('0),
    .read_valid       (1'b0),
    .read_ready       (),
    .write_data_out   (),
    .write_valid      (),
    .write_ready      (1'b0),
    .credit_available (credit_available),
    .credit_consume   (credit_consume),
    .ddr_addr_start   ('0),
    .transfer_length  ('0),
    .read_not_write   (1'b1),
    .clk_ddr          (clk_ddr),
    .rst_n            (rst_n_sync)
  );

  // --- Stream engine ---
  stream_engine stream_eng (
    .read_data_out    (),
    .read_valid       (),
    .read_ready       (1'b1),
    .pe_stream_data   (stream_data),
    .pe_stream_valid  (stream_valid),
    .pe_stream_ready  (stream_ready),
    .credit_available (credit_available),
    .credit_consume   (credit_consume),
    .stream_v         (1'b0),
    .stream_s         (1'b0),
    .stream_addr      ('0),
    .stream_length    ('0),
    .clk_io           (clk_io),
    .rst_n            (rst_n_sync)
  );

endmodule
