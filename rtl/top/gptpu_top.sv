import gptpu_pkg::*;

module gptpu_top (
  inout  wire [DDR_BUS_WIDTH-1:0] ddr_bus,
  output logic                     ddr_clk_p, ddr_clk_n,
  output logic                     ddr_cke, ddr_cs_n,
  output logic [1:0]               ddr_bg, ddr_ba,
  output logic [15:0]              ddr_addr,
  output logic                     ddr_ras_n, ddr_cas_n, ddr_we_n,
  input  logic                     clk_ref,
  input  logic                     rst_n_ext
);

  localparam int X = PE_GRID_X;
  localparam int Y = PE_GRID_Y;

  // --- Clocks ---
  logic clk_noc, clk_ddr, clk_io;
  logic clk_pe_grid [X-1:0][Y-1:0];

  // --- Reset ---
  logic rst_n_sync;

  // ============================================================
  // NoC interconnect signals (clk_noc domain)
  // ============================================================
  // L0: per-PE cardinal-direction scalar nets (router port map:
  // N=1, E=2, S=3, W=4).  *_data/*_valid/*_ready are a PE's OUT ports;
  // *_in_data/*_in_valid/*_in_ready are a PE's IN ports.
  logic [63:0] l0_N_data  [X-1:0][Y-1:0]; logic        l0_N_valid [X-1:0][Y-1:0]; logic        l0_N_ready [X-1:0][Y-1:0];
  logic [63:0] l0_E_data  [X-1:0][Y-1:0]; logic        l0_E_valid [X-1:0][Y-1:0]; logic        l0_E_ready [X-1:0][Y-1:0];
  logic [63:0] l0_S_data  [X-1:0][Y-1:0]; logic        l0_S_valid [X-1:0][Y-1:0]; logic        l0_S_ready [X-1:0][Y-1:0];
  logic [63:0] l0_W_data  [X-1:0][Y-1:0]; logic        l0_W_valid [X-1:0][Y-1:0]; logic        l0_W_ready [X-1:0][Y-1:0];
  logic [63:0] l0_N_in_data [X-1:0][Y-1:0]; logic l0_N_in_valid [X-1:0][Y-1:0]; logic l0_N_in_ready [X-1:0][Y-1:0];
  logic [63:0] l0_E_in_data [X-1:0][Y-1:0]; logic l0_E_in_valid [X-1:0][Y-1:0]; logic l0_E_in_ready [X-1:0][Y-1:0];
  logic [63:0] l0_S_in_data [X-1:0][Y-1:0]; logic l0_S_in_valid [X-1:0][Y-1:0]; logic l0_S_in_ready [X-1:0][Y-1:0];
  logic [63:0] l0_W_in_data [X-1:0][Y-1:0]; logic l0_W_in_valid [X-1:0][Y-1:0]; logic l0_W_in_ready [X-1:0][Y-1:0];

  // L1/L2 are folded into the L0 router's local port in this design
  // (see pe_core); no dedicated expressway nets at the top level.

  // ============================================================
  // Microcode memory
  // ============================================================
  microcode_word_t microcode [NUM_PE];
  logic            microcode_valid [NUM_PE];
  logic [12:0]     pc [NUM_PE];

  // ============================================================
  // Stream / DDR signals
  // ============================================================
  logic [1023:0] stream_data;
  logic          stream_valid, stream_ready;
  logic [1023:0] stream_out_data;
  logic          stream_out_valid, stream_out_ready;

  // PE-facing stream bus (512-bit = one SRAM line); ready AND-reduced over grid
  logic          pe_stream_valid;
  logic [511:0]  pe_stream_data;
  logic          pe_stream_ready;
  logic          pe_stream_ready_all [X-1:0][Y-1:0];

  logic [1023:0] edge_data_in [X-1:0];
  logic          edge_valid [X-1:0];
  logic          edge_ready [X-1:0];
  logic [1023:0] edge_data_out [X-1:0];
  logic          edge_out_valid [X-1:0];
  logic          edge_out_ready [X-1:0];
  logic [15:0]   credit_available;
  logic          credit_consume;
  logic [31:0]   stream_addr;
  logic [31:0]   stream_length;
  logic          stream_v, stream_s;

  // ============================================================
  // Reset synchronizer
  // ============================================================
  always_ff @(posedge clk_ref or negedge rst_n_ext) begin
    if (!rst_n_ext) rst_n_sync <= 1'b0;
    else            rst_n_sync <= 1'b1;
  end

  // ============================================================
  // Clock generation
  // ============================================================
  assign clk_noc = clk_ref;
  assign clk_ddr = clk_ref;
  assign clk_io  = clk_ref;

  genvar x, y;
  generate
    for (x = 0; x < X; x++) begin : gen_col
      for (y = 0; y < Y; y++) begin : gen_row
        assign clk_pe_grid[x][y] = clk_ref;
      end
    end
  endgenerate

  // ============================================================
  // PE instances
  // ============================================================
  generate
    for (x = 0; x < X; x++) begin : gen_pe_x
      for (y = 0; y < Y; y++) begin : gen_pe_y

        pe_core pe (
          .pe_x            (x[7:0]),
          .pe_y            (y[7:0]),

          .l0_N_data    (l0_N_data[x][y]),
          .l0_N_valid   (l0_N_valid[x][y]),
          .l0_N_ready   (l0_N_ready[x][y]),
          .l0_N_in_data (l0_N_in_data[x][y]),
          .l0_N_in_valid(l0_N_in_valid[x][y]),
          .l0_N_in_ready(l0_N_in_ready[x][y]),
          .l0_E_data    (l0_E_data[x][y]),
          .l0_E_valid   (l0_E_valid[x][y]),
          .l0_E_ready   (l0_E_ready[x][y]),
          .l0_E_in_data (l0_E_in_data[x][y]),
          .l0_E_in_valid(l0_E_in_valid[x][y]),
          .l0_E_in_ready(l0_E_in_ready[x][y]),
          .l0_S_data    (l0_S_data[x][y]),
          .l0_S_valid   (l0_S_valid[x][y]),
          .l0_S_ready   (l0_S_ready[x][y]),
          .l0_S_in_data (l0_S_in_data[x][y]),
          .l0_S_in_valid(l0_S_in_valid[x][y]),
          .l0_S_in_ready(l0_S_in_ready[x][y]),
          .l0_W_data    (l0_W_data[x][y]),
          .l0_W_valid   (l0_W_valid[x][y]),
          .l0_W_ready   (l0_W_ready[x][y]),
          .l0_W_in_data (l0_W_in_data[x][y]),
          .l0_W_in_valid(l0_W_in_valid[x][y]),
          .l0_W_in_ready(l0_W_in_ready[x][y]),

          // L1 (expressway) and L2 (SN-boundary) are folded into the L0
          // router's local port in this design; tie them off at the top.
          .l1_out_data     (),
          .l1_out_valid    (),
          .l1_out_ready    (1'b0),
          .l1_in_data      ('0),
          .l1_in_valid     (1'b0),
          .l1_in_ready     (),

          .l2_out_data     (),
          .l2_out_valid    (),
          .l2_out_ready    (1'b0),
          .l2_in_data      ('0),
          .l2_in_valid     (1'b0),
          .l2_in_ready     (),

          .instr           (microcode[x * Y + y]),
          .instr_valid     (microcode_valid[x * Y + y]),
          .pc              (pc[x * Y + y]),

          .stream_data     (pe_stream_data),
          .stream_valid    (pe_stream_valid),
          .stream_ready    (pe_stream_ready_all[x][y]),

          .clk_pe          (clk_pe_grid[x][y]),
          .clk_noc         (clk_noc),
          .rst_n           (rst_n_sync)
        );

      end
    end
  endgenerate

  // ============================================================
  // L0 Directional Interconnect (scalar cardinal nets)
  // Router port map: [1]=N, [2]=E, [3]=S, [4]=W.  [0]=LOCAL and
  // [5..7]=diagonals are handled inside pe_core (not routed at top).
  // ============================================================
  generate
    for (x = 0; x < X; x++) begin : gen_noc_x
      for (y = 0; y < Y; y++) begin : gen_noc_y

        // --- North: PE(x,y).N-out → PE(x,y-1).N-in ---
        if (y > 0) begin : gen_n
          assign l0_N_in_data[x][y-1]  = l0_N_data[x][y];
          assign l0_N_in_valid[x][y-1] = l0_N_valid[x][y];
          assign l0_N_ready[x][y]      = l0_N_in_ready[x][y-1];
        end

        // --- South: PE(x,y).S-out → PE(x,y+1).S-in ---
        if (y < Y-1) begin : gen_s
          assign l0_S_in_data[x][y+1]  = l0_S_data[x][y];
          assign l0_S_in_valid[x][y+1] = l0_S_valid[x][y];
          assign l0_S_ready[x][y]      = l0_S_in_ready[x][y+1];
        end

        // --- East: PE(x,y).E-out → PE(x+1,y).E-in ---
        if (x < X-1) begin : gen_e
          assign l0_E_in_data[x+1][y]  = l0_E_data[x][y];
          assign l0_E_in_valid[x+1][y] = l0_E_valid[x][y];
          assign l0_E_ready[x][y]      = l0_E_in_ready[x+1][y];
        end

        // --- West: PE(x,y).W-out → PE(x-1,y).W-in ---
        if (x > 0) begin : gen_w
          assign l0_W_in_data[x-1][y]  = l0_W_data[x][y];
          assign l0_W_in_valid[x-1][y] = l0_W_valid[x][y];
          assign l0_W_ready[x][y]      = l0_W_in_ready[x-1][y];
        end

        // --- Boundary ready ties (grid edge out-ports have no receiver) ---
        // N-ready at y==0 is supplied by the edge block below.
        if (y == Y-1)     assign l0_S_ready[x][Y-1] = 1'b0;
        if (x == X-1)     assign l0_E_ready[X-1][y] = 1'b0;
        if (x == 0)       assign l0_W_ready[0][y]   = 1'b0;

      end
    end
  endgenerate

  // ============================================================
  // Edge I/O: connect grid boundary PEs to stream engine
  // ============================================================
  // PE-facing stream ready: all PEs must accept to advance the broadcast
  always_comb begin
    pe_stream_ready = 1'b1;
    for (int ix = 0; ix < X; ix++)
      for (int iy = 0; iy < Y; iy++)
        pe_stream_ready = pe_stream_ready & pe_stream_ready_all[ix][iy];
  end

  // North edge (y=0): each row's PE(0..X-1, 0) provides DDR data
  generate
    for (x = 0; x < X; x++) begin : gen_edge
      assign edge_data_in[x]  = l0_N_data[x][0];
      assign edge_valid[x]    = l0_N_valid[x][0];
      assign l0_N_ready[x][0] = edge_ready[x];
    end
  endgenerate

  edge_io edge_io_inst (
    .edge_data_in    (edge_data_in),
    .edge_valid      (edge_valid),
    .edge_ready      (edge_ready),
    .edge_data_out   (edge_data_out),
    .edge_out_valid  (edge_out_valid),
    .edge_out_ready  (edge_out_ready),
    .stream_data     (stream_data),
    .stream_valid    (stream_valid),
    .stream_ready    (stream_ready),
    .stream_out_data (stream_out_data),
    .stream_out_valid(stream_out_valid),
    .stream_out_ready(stream_out_ready),
    .pe_stream_data  (pe_stream_data),
    .pe_stream_valid (pe_stream_valid),
    .pe_stream_ready (pe_stream_ready),
    .clk_io          (clk_io),
    .rst_n           (rst_n_sync)
  );

  // ============================================================
  // DDR Controller
  // ============================================================
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
    .read_data_in     (stream_out_data),
    .read_valid       (stream_out_valid),
    .read_ready       (stream_out_ready),
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

  // ============================================================
  // Stream Engine
  // ============================================================
  stream_engine stream_eng (
    .read_data_out   (stream_data),
    .read_valid      (stream_valid),
    .read_ready      (stream_ready),
    .pe_stream_data  (),
    .pe_stream_valid (),
    .pe_stream_ready (1'b1),
    .credit_available(credit_available),
    .credit_consume  (credit_consume),
    .stream_v        (stream_v),
    .stream_s        (stream_s),
    .stream_addr     (stream_addr),
    .stream_length   (stream_length),
    .clk_io          (clk_io),
    .rst_n           (rst_n_sync)
  );

endmodule
