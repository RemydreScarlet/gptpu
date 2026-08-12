import gptpu_pkg::*;

module gptpu_top (
  inout  wire [DDR_BUS_WIDTH-1:0] ddr_bus,
  output logic                     ddr_clk_p, ddr_clk_n,
  output logic                     ddr_cke, ddr_cs_n,
  output logic [1:0]               ddr_bg, ddr_ba,
  output logic [15:0]              ddr_addr,
  output logic                     ddr_ras_n, ddr_cas_n, ddr_we_n,
  input  logic                     clk_ref,
  input  logic                     rst_n_ext,

  // LUT user-table programming (tables 9-15), broadcast to all PEs
  input  logic                     lut_write_en,
  input  logic [3:0]               lut_write_table,
  input  logic [7:0]               lut_write_addr,
  input  fp8_e4m3_t                lut_write_data,

  // --- Test hooks (tie off / ignored in normal operation) ---
  input  logic                     test_inject_valid [PE_GRID_X-1:0][PE_GRID_Y-1:0],
  input  logic [63:0]              test_inject_data  [PE_GRID_X-1:0][PE_GRID_Y-1:0],
  output logic                     test_inject_ready [PE_GRID_X-1:0][PE_GRID_Y-1:0],
  output logic [63:0]              test_eject_data   [PE_GRID_X-1:0][PE_GRID_Y-1:0],
  output logic                     test_eject_valid  [PE_GRID_X-1:0][PE_GRID_Y-1:0],
  output logic                     test_l1_valid     [PE_GRID_X-1:0][PE_GRID_Y-1:0],
  output logic                     test_l2_valid     [PE_GRID_X-1:0][PE_GRID_Y-1:0]
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

  // L1 expressway links between adjacent highway nodes (x%4==0 && y%4==0)
  logic [63:0] l1_N_data  [X-1:0][Y-1:0]; logic        l1_N_valid [X-1:0][Y-1:0]; logic        l1_N_ready [X-1:0][Y-1:0];
  logic [63:0] l1_E_data  [X-1:0][Y-1:0]; logic        l1_E_valid [X-1:0][Y-1:0]; logic        l1_E_ready [X-1:0][Y-1:0];
  logic [63:0] l1_S_data  [X-1:0][Y-1:0]; logic        l1_S_valid [X-1:0][Y-1:0]; logic        l1_S_ready [X-1:0][Y-1:0];
  logic [63:0] l1_W_data  [X-1:0][Y-1:0]; logic        l1_W_valid [X-1:0][Y-1:0]; logic        l1_W_ready [X-1:0][Y-1:0];
  logic [63:0] l1_N_in_data [X-1:0][Y-1:0]; logic l1_N_in_valid [X-1:0][Y-1:0]; logic l1_N_in_ready [X-1:0][Y-1:0];
  logic [63:0] l1_E_in_data [X-1:0][Y-1:0]; logic l1_E_in_valid [X-1:0][Y-1:0]; logic l1_E_in_ready [X-1:0][Y-1:0];
  logic [63:0] l1_S_in_data [X-1:0][Y-1:0]; logic l1_S_in_valid [X-1:0][Y-1:0]; logic l1_S_in_ready [X-1:0][Y-1:0];
  logic [63:0] l1_W_in_data [X-1:0][Y-1:0]; logic l1_W_in_valid [X-1:0][Y-1:0]; logic l1_W_in_ready [X-1:0][Y-1:0];

  // L2 SN-boundary crossing links (boundary highway nodes only)
  logic [63:0] l2_E_data [X-1:0][Y-1:0]; logic l2_E_valid [X-1:0][Y-1:0]; logic l2_E_ready [X-1:0][Y-1:0];
  logic [63:0] l2_W_data [X-1:0][Y-1:0]; logic l2_W_valid [X-1:0][Y-1:0]; logic l2_W_ready [X-1:0][Y-1:0];
  logic [63:0] l2_E_in_data [X-1:0][Y-1:0]; logic l2_E_in_valid [X-1:0][Y-1:0]; logic l2_E_in_ready [X-1:0][Y-1:0];
  logic [63:0] l2_W_in_data [X-1:0][Y-1:0]; logic l2_W_in_valid [X-1:0][Y-1:0]; logic l2_W_in_ready [X-1:0][Y-1:0];

  // ============================================================
  // Microcode memory
  // ============================================================
  microcode_word_t microcode [NUM_PE];
  logic            microcode_valid [NUM_PE];
  logic [12:0]     pc [NUM_PE];

  // ============================================================
  // Stream / DDR signals
  // ============================================================
  // North-edge L0 flit collection (one 64-bit flit per PE column, y=0)
  logic [63:0] edge_flit [X-1:0];
  logic        edge_flit_valid [X-1:0];
  logic        edge_flit_ready [X-1:0];

  // stream_engine <-> edge_io
  logic [1023:0] se_edge_stream;      logic se_edge_stream_valid, se_edge_stream_ready;
  logic [1023:0] se_edge_write;       logic se_edge_write_valid,  se_edge_write_ready;

  // PE-facing broadcast stream (512-bit SRAM line); ready AND-reduced over grid
  logic          pe_stream_valid;
  logic [511:0]  pe_stream_data;
  logic          pe_stream_ready;
  logic          pe_stream_ready_all [X-1:0][Y-1:0];

  // ddr_controller <-> stream_engine
  logic          ddr_read_req_valid, ddr_read_req_ready;
  logic [31:0]   ddr_read_req_addr;
  logic [1023:0] ddr_read_data;
  logic          ddr_read_data_valid, ddr_read_data_ready;
  logic          ddr_write_req_valid, ddr_write_req_ready;
  logic [31:0]   ddr_write_req_addr;
  logic [1023:0] ddr_write_data;

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

          // L1 expressway / L2 SN-boundary (clk_noc domain)
          .l1_N_data    (l1_N_data[x][y]),    .l1_N_valid   (l1_N_valid[x][y]),    .l1_N_ready   (l1_N_ready[x][y]),
          .l1_N_in_data (l1_N_in_data[x][y]), .l1_N_in_valid(l1_N_in_valid[x][y]), .l1_N_in_ready(l1_N_in_ready[x][y]),
          .l1_E_data    (l1_E_data[x][y]),    .l1_E_valid   (l1_E_valid[x][y]),    .l1_E_ready   (l1_E_ready[x][y]),
          .l1_E_in_data (l1_E_in_data[x][y]), .l1_E_in_valid(l1_E_in_valid[x][y]), .l1_E_in_ready(l1_E_in_ready[x][y]),
          .l1_S_data    (l1_S_data[x][y]),    .l1_S_valid   (l1_S_valid[x][y]),    .l1_S_ready   (l1_S_ready[x][y]),
          .l1_S_in_data (l1_S_in_data[x][y]), .l1_S_in_valid(l1_S_in_valid[x][y]), .l1_S_in_ready(l1_S_in_ready[x][y]),
          .l1_W_data    (l1_W_data[x][y]),    .l1_W_valid   (l1_W_valid[x][y]),    .l1_W_ready   (l1_W_ready[x][y]),
          .l1_W_in_data (l1_W_in_data[x][y]), .l1_W_in_valid(l1_W_in_valid[x][y]), .l1_W_in_ready(l1_W_in_ready[x][y]),

          .l2_E_data    (l2_E_data[x][y]),    .l2_E_valid   (l2_E_valid[x][y]),    .l2_E_ready   (l2_E_ready[x][y]),
          .l2_E_in_data (l2_E_in_data[x][y]), .l2_E_in_valid(l2_E_in_valid[x][y]), .l2_E_in_ready(l2_E_in_ready[x][y]),
          .l2_W_data    (l2_W_data[x][y]),    .l2_W_valid   (l2_W_valid[x][y]),    .l2_W_ready   (l2_W_ready[x][y]),
          .l2_W_in_data (l2_W_in_data[x][y]), .l2_W_in_valid(l2_W_in_valid[x][y]), .l2_W_in_ready(l2_W_in_ready[x][y]),

          .instr           (microcode[x * Y + y]),
          .instr_valid     (microcode_valid[x * Y + y]),
          .pc              (pc[x * Y + y]),

          .stream_data     (pe_stream_data),
          .stream_valid    (pe_stream_valid),
          .stream_ready    (pe_stream_ready_all[x][y]),

          .lut_write_en    (lut_write_en),
          .lut_write_table (lut_write_table),
          .lut_write_addr  (lut_write_addr),
          .lut_write_data  (lut_write_data),

          .test_inject_valid (test_inject_valid[x][y]),
          .test_inject_data  (test_inject_data[x][y]),
          .test_inject_ready (test_inject_ready[x][y]),
          .test_eject_data   (test_eject_data[x][y]),
          .test_eject_valid  (test_eject_valid[x][y]),
          .test_l1_valid     (test_l1_valid[x][y]),
          .test_l2_valid     (test_l2_valid[x][y]),

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
  //
  // GALS isolation: EVERY directed PE-to-PE link is buffered by a 2-stage
  // async FIFO so valid-forward / ready-backward handshakes never form a
  // combinational loop across PE boundaries (their GVAL reads only from
  // registered/synchronized pointers).
  // ============================================================
  generate
    for (x = 0; x < X; x++) begin : gen_noc_x
      for (y = 0; y < Y; y++) begin : gen_noc_y

        // --- North: PE(x,y).N-out → PE(x,y-1).N-in ---
        if (y > 0) begin : gen_n
          async_fifo_2stage #(.DATA_WIDTH(64)) l0_link_n (
            .w_data  (l0_N_data[x][y]),
            .w_valid (l0_N_valid[x][y]),
            .w_ready (l0_N_ready[x][y]),
            .r_data  (l0_N_in_data[x][y-1]),
            .r_valid (l0_N_in_valid[x][y-1]),
            .r_ready (l0_N_in_ready[x][y-1]),
            .clk_wr  (clk_noc),
            .clk_rd  (clk_noc),
            .rst_n_wr(rst_n_sync),
            .rst_n_rd(rst_n_sync)
          );
        end

        // --- South: PE(x,y).S-out → PE(x,y+1).S-in ---
        if (y < Y-1) begin : gen_s
          async_fifo_2stage #(.DATA_WIDTH(64)) l0_s (
            .w_data  (l0_S_data[x][y]),
            .w_valid (l0_S_valid[x][y]),
            .w_ready (l0_S_ready[x][y]),
            .r_data  (l0_S_in_data[x][y+1]),
            .r_valid (l0_S_in_valid[x][y+1]),
            .r_ready (l0_S_in_ready[x][y+1]),
            .clk_wr  (clk_noc),
            .clk_rd  (clk_noc),
            .rst_n_wr(rst_n_sync),
            .rst_n_rd(rst_n_sync)
          );
        end

        // --- East: PE(x,y).E-out → PE(x+1,y).E-in ---
        if (x < X-1) begin : gen_e
          async_fifo_2stage #(.DATA_WIDTH(64)) l0_e_link (
            .w_data  (l0_E_data[x][y]),
            .w_valid (l0_E_valid[x][y]),
            .w_ready (l0_E_ready[x][y]),
            .r_data  (l0_E_in_data[x+1][y]),
            .r_valid (l0_E_in_valid[x+1][y]),
            .r_ready (l0_E_in_ready[x+1][y]),
            .clk_wr  (clk_noc),
            .clk_rd  (clk_noc),
            .rst_n_wr(rst_n_sync),
            .rst_n_rd(rst_n_sync)
          );
        end

        // --- West: PE(x,y).W-out → PE(x-1,y).W-in ---
        if (x > 0) begin : gen_w
          async_fifo_2stage #(.DATA_WIDTH(64)) l0_w_link (
            .w_data  (l0_W_data[x][y]),
            .w_valid (l0_W_valid[x][y]),
            .w_ready (l0_W_ready[x][y]),
            .r_data  (l0_W_in_data[x-1][y]),
            .r_valid (l0_W_in_valid[x-1][y]),
            .r_ready (l0_W_in_ready[x-1][y]),
            .clk_wr  (clk_noc),
            .clk_rd  (clk_noc),
            .rst_n_wr(rst_n_sync),
            .rst_n_rd(rst_n_sync)
          );
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
  // L1 Expressway lattice: highway nodes (x%4==0 && y%4==0) link to
  // their adjacent highway nodes (step 4) in each cardinal direction.
  // A flit heading east from node A enters node B (x+4) on its west side.
  // ============================================================
  genvar hx, hy;
  generate
    for (hx = 0; hx < X; hx++) begin : gen_l1_x
      for (hy = 0; hy < Y; hy++) begin : gen_l1_y
        if ((hx % 4 == 0) && (hy % 4 == 0)) begin : gen_hw
          // East↔West: (hx,hy).E <-> (hx+4,hy).W  (two directed links, each FIFO-buffered)
          if (hx + 4 < X) begin : gen_l1_e
            async_fifo_2stage #(.DATA_WIDTH(64)) l1_e_waf (
              .w_data  (l1_E_data [hx][hy]),
              .w_valid (l1_E_valid[hx][hy]),
              .w_ready (l1_E_ready[hx][hy]),
              .r_data  (l1_W_in_data [hx+4][hy]),
              .r_valid (l1_W_in_valid[hx+4][hy]),
              .r_ready (l1_W_in_ready[hx+4][hy]),
              .clk_wr  (clk_noc), .clk_rd (clk_noc),
              .rst_n_wr(rst_n_sync), .rst_n_rd(rst_n_sync)
            );
            async_fifo_2stage #(.DATA_WIDTH(64)) l1_w_eaf (
              .w_data  (l1_W_data [hx+4][hy]),
              .w_valid (l1_W_valid[hx+4][hy]),
              .w_ready (l1_W_ready[hx+4][hy]),
              .r_data  (l1_E_in_data [hx][hy]),
              .r_valid (l1_E_in_valid[hx][hy]),
              .r_ready (l1_E_in_ready[hx][hy]),
              .clk_wr  (clk_noc), .clk_rd (clk_noc),
              .rst_n_wr(rst_n_sync), .rst_n_rd(rst_n_sync)
            );
          end else begin : gen_l1_e_none
            assign l1_E_ready[hx][hy]    = 1'b0;
            assign l1_E_in_valid[hx][hy] = 1'b0;
            assign l1_E_in_data[hx][hy]  = '0;
          end
          if (hx - 4 >= 0) begin : gen_l1_w
            // west pair handled by the (hx-4) east block above
          end else begin : gen_l1_w_none
            assign l1_W_ready[hx][hy]    = 1'b0;
            assign l1_W_in_valid[hx][hy] = 1'b0;
            assign l1_W_in_data[hx][hy]  = '0;
          end
          // North↔South: (hx,hy).N <-> (hx,hy-4).S  (two directed links)
          if (hy - 4 >= 0) begin : gen_l1_n
            async_fifo_2stage #(.DATA_WIDTH(64)) l1_n_saf (
              .w_data  (l1_N_data [hx][hy]),
              .w_valid (l1_N_valid[hx][hy]),
              .w_ready (l1_N_ready[hx][hy]),
              .r_data  (l1_S_in_data [hx][hy-4]),
              .r_valid (l1_S_in_valid[hx][hy-4]),
              .r_ready (l1_S_in_ready[hx][hy-4]),
              .clk_wr  (clk_noc), .clk_rd (clk_noc),
              .rst_n_wr(rst_n_sync), .rst_n_rd(rst_n_sync)
            );
            async_fifo_2stage #(.DATA_WIDTH(64)) l1_s_n (
              .w_data  (l1_S_data [hx][hy-4]),
              .w_valid (l1_S_valid[hx][hy-4]),
              .w_ready (l1_S_ready[hx][hy-4]),
              .r_data  (l1_N_in_data [hx][hy]),
              .r_valid (l1_N_in_valid[hx][hy]),
              .r_ready (l1_N_in_ready[hx][hy]),
              .clk_wr  (clk_noc), .clk_rd (clk_noc),
              .rst_n_wr(rst_n_sync), .rst_n_rd(rst_n_sync)
            );
          end else begin : gen_l1_n_none
            assign l1_N_ready[hx][hy]    = 1'b0;
            assign l1_N_in_valid[hx][hy] = 1'b0;
            assign l1_N_in_data[hx][hy]  = '0;
          end
          if (hy + 4 < Y) begin : gen_l1_s
            // south pair handled by the (hy+4) north block above
          end else begin : gen_l1_s_none
            assign l1_S_ready[hx][hy]    = 1'b0;
            assign l1_S_in_valid[hx][hy] = 1'b0;
            assign l1_S_in_data[hx][hy]  = '0;
          end
        end else begin : gen_nonhw
          // Non-highway nodes carry no L1 links; tie everything off.
          assign l1_N_ready[hx][hy]   = 1'b0;  assign l1_N_in_valid[hx][hy] = 1'b0;  assign l1_N_in_data[hx][hy]  = '0;
          assign l1_E_ready[hx][hy]   = 1'b0;  assign l1_E_in_valid[hx][hy] = 1'b0;  assign l1_E_in_data[hx][hy]  = '0;
          assign l1_S_ready[hx][hy]   = 1'b0;  assign l1_S_in_valid[hx][hy] = 1'b0;  assign l1_S_in_data[hx][hy]  = '0;
          assign l1_W_ready[hx][hy]   = 1'b0;  assign l1_W_in_valid[hx][hy] = 1'b0;  assign l1_W_in_data[hx][hy]  = '0;
        end
      end
    end
  endgenerate

  // ============================================================
  // L2 SN-boundary lattice: boundary highway nodes straddling an interior
  // SN boundary (x = SN_GRID_X, 2*SN_GRID_X, ...) are linked across it.
  // router_l2 is a cut-through, so this is a dedicated cross-SN path
  // (redundant with the L1 mesh when highway spacing == SN size).
  // ============================================================
  genvar bx, by;
  generate
    for (bx = 0; bx < X; bx += SN_GRID_X) begin : gen_l2_x
      if (bx != 0) begin : gen_l2_x_inner
        for (by = 0; by < Y; by += SN_GRID_Y) begin : gen_l2_y
          // east node (bx, by) and west node (bx-SN_GRID_X, by) cross the SN
          // boundary: two directed FIFO-buffered links
          if (bx - SN_GRID_X >= 0 && bx < X && by < Y) begin : gen_l2_link
            async_fifo_2stage #(.DATA_WIDTH(64)) l2_w_af (
              .w_data  (l2_E_data [bx-SN_GRID_X][by]),
              .w_valid (l2_E_valid[bx-SN_GRID_X][by]),
              .w_ready (l2_E_ready[bx-SN_GRID_X][by]),
              .r_data  (l2_W_in_data [bx][by]),
              .r_valid (l2_W_in_valid[bx][by]),
              .r_ready (l2_W_in_ready[bx][by]),
              .clk_wr  (clk_noc), .clk_rd (clk_noc),
              .rst_n_wr(rst_n_sync), .rst_n_rd(rst_n_sync)
            );
            async_fifo_2stage #(.DATA_WIDTH(64)) l2_e_af (
              .w_data  (l2_W_data [bx][by]),
              .w_valid (l2_W_valid[bx][by]),
              .w_ready (l2_W_ready[bx][by]),
              .r_data  (l2_E_in_data [bx-SN_GRID_X][by]),
              .r_valid (l2_E_in_valid[bx-SN_GRID_X][by]),
              .r_ready (l2_E_in_ready[bx-SN_GRID_X][by]),
              .clk_wr  (clk_noc), .clk_rd (clk_noc),
              .rst_n_wr(rst_n_sync), .rst_n_rd(rst_n_sync)
            );
          end
        end
      end
    end
    // tie off L2 ports everywhere else (only boundary highway nodes use L2)
    for (bx = 0; bx < X; bx++) begin : gen_l2_tie_x
      for (by = 0; by < Y; by++) begin : gen_l2_tie_y
        if (!((bx % SN_GRID_X == 0) && (by % SN_GRID_Y == 0))) begin : gen_l2_tie
          assign l2_E_ready[bx][by] = 1'b0;  assign l2_E_in_valid[bx][by] = 1'b0;  assign l2_E_in_data[bx][by] = '0;
          assign l2_W_ready[bx][by] = 1'b0;  assign l2_W_in_valid[bx][by] = 1'b0;  assign l2_W_in_data[bx][by] = '0;
        end
      end
    end
    // Edge L2 ties: westmost highway column (x=0) has no W link,
    // eastmost (x=X-4) has no E link.
    for (by = 0; by < Y; by += SN_GRID_Y) begin : gen_l2_edge_y
      assign l2_W_ready   [0][by] = 1'b0;
      assign l2_W_in_valid[0][by] = 1'b0;
      assign l2_W_in_data [0][by] = '0;
      assign l2_E_ready   [X-SN_GRID_X][by] = 1'b0;
      assign l2_E_in_valid[X-SN_GRID_X][by] = 1'b0;
      assign l2_E_in_data [X-SN_GRID_X][by] = '0;
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

  // North edge (y=0): each PE column presents one 64-bit L0 flit to DDR
  generate
    for (x = 0; x < X; x++) begin : gen_edge
      assign edge_flit[x]       = l0_N_data[x][0];
      assign edge_flit_valid[x] = l0_N_valid[x][0];
      assign l0_N_ready[x][0]   = edge_flit_ready[x];
    end
  endgenerate

  edge_io edge_io_inst (
    .edge_flit_in      (edge_flit),
    .edge_valid        (edge_flit_valid),
    .edge_ready        (edge_flit_ready),
    .edge_write_data   (se_edge_write),
    .edge_write_valid  (se_edge_write_valid),
    .edge_write_ready  (se_edge_write_ready),
    .stream_in_data    (se_edge_stream),
    .stream_in_valid   (se_edge_stream_valid),
    .stream_in_ready   (se_edge_stream_ready),
    .pe_stream_data    (pe_stream_data),
    .pe_stream_valid   (pe_stream_valid),
    .pe_stream_ready   (pe_stream_ready),
    .clk_io            (clk_io),
    .rst_n             (rst_n_sync)
  );

  // ============================================================
  // DDR Controller
  // ============================================================
  ddr_controller ddr_ctrl (
    .ddr_bus            (ddr_bus),
    .ddr_clk_p          (ddr_clk_p),
    .ddr_clk_n          (ddr_clk_n),
    .ddr_cke            (ddr_cke),
    .ddr_cs_n           (ddr_cs_n),
    .ddr_bg             (ddr_bg),
    .ddr_ba             (ddr_ba),
    .ddr_addr           (ddr_addr),
    .ddr_ras_n          (ddr_ras_n),
    .ddr_cas_n          (ddr_cas_n),
    .ddr_we_n           (ddr_we_n),
    .read_req_valid     (ddr_read_req_valid),
    .read_req_ready     (ddr_read_req_ready),
    .read_req_addr      (ddr_read_req_addr),
    .read_data_out      (ddr_read_data),
    .read_data_valid    (ddr_read_data_valid),
    .read_data_ready    (ddr_read_data_ready),
    .write_req_valid    (ddr_write_req_valid),
    .write_req_ready    (ddr_write_req_ready),
    .write_req_addr     (ddr_write_req_addr),
    .write_data_in      (ddr_write_data),
    .credit_available   (credit_available),
    .credit_consume     (credit_consume),
    .clk_ddr            (clk_ddr),
    .rst_n              (rst_n_sync)
  );

  // ============================================================
  // Stream Engine
  // ============================================================
  stream_engine stream_eng (
    .read_req_valid        (ddr_read_req_valid),
    .read_req_ready        (ddr_read_req_ready),
    .read_req_addr         (ddr_read_req_addr),
    .read_data_in          (ddr_read_data),
    .read_data_valid       (ddr_read_data_valid),
    .read_data_ready       (ddr_read_data_ready),
    .edge_stream_out       (se_edge_stream),
    .edge_stream_out_valid (se_edge_stream_valid),
    .edge_stream_out_ready (se_edge_stream_ready),
    .edge_write_data       (se_edge_write),
    .edge_write_valid      (se_edge_write_valid),
    .edge_write_ready      (se_edge_write_ready),
    .write_req_valid       (ddr_write_req_valid),
    .write_req_ready       (ddr_write_req_ready),
    .write_req_addr        (ddr_write_req_addr),
    .write_data_out        (ddr_write_data),
    .credit_available      (credit_available),
    .credit_consume        (credit_consume),
    .stream_v              (stream_v),
    .stream_s              (stream_s),
    .stream_addr           (stream_addr),
    .stream_length         (stream_length),
    .clk_io                (clk_io),
    .rst_n                 (rst_n_sync)
  );

  // Stream instructions are decoded from CCE microcode in a later phase;
  // tie off until the STREAM decode is wired.
  assign stream_v = 1'b0;
  assign stream_s = 1'b0;
  assign stream_addr  = '0;
  assign stream_length = '0;

endmodule
