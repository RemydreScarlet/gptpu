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
  // L0: per-PE 8-direction arrays
  logic [63:0] l0_out_data [X-1:0][Y-1:0][8];
  logic        l0_out_valid[X-1:0][Y-1:0][8];
  logic        l0_out_ready[X-1:0][Y-1:0][8];
  logic [63:0] l0_in_data  [X-1:0][Y-1:0][8];
  logic        l0_in_valid [X-1:0][Y-1:0][8];
  logic        l0_in_ready [X-1:0][Y-1:0][8];

  // L1: expressway between highway nodes (x%4==0, y%4==0)
  logic [63:0] l1_out_data [X-1:0][Y-1:0];
  logic        l1_out_valid[X-1:0][Y-1:0];
  logic        l1_out_ready[X-1:0][Y-1:0];
  logic [63:0] l1_in_data  [X-1:0][Y-1:0];
  logic        l1_in_valid [X-1:0][Y-1:0];
  logic        l1_in_ready [X-1:0][Y-1:0];

  // L2: SN boundary
  logic [63:0] l2_out_data [X-1:0][Y-1:0];
  logic        l2_out_valid[X-1:0][Y-1:0];
  logic        l2_out_ready[X-1:0][Y-1:0];
  logic [63:0] l2_in_data  [X-1:0][Y-1:0];
  logic        l2_in_valid [X-1:0][Y-1:0];
  logic        l2_in_ready [X-1:0][Y-1:0];

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
  logic [1023:0] edge_data_in [Y-1:0];
  logic          edge_valid [Y-1:0];
  logic          edge_ready [Y-1:0];
  logic [1023:0] edge_data_out [Y-1:0];
  logic          edge_out_valid [Y-1:0];
  logic          edge_out_ready [Y-1:0];
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

          .l0_out_data     (l0_out_data[x][y]),
          .l0_out_valid    (l0_out_valid[x][y]),
          .l0_out_ready    (l0_out_ready[x][y]),
          .l0_in_data      (l0_in_data[x][y]),
          .l0_in_valid     (l0_in_valid[x][y]),
          .l0_in_ready     (l0_in_ready[x][y]),

          .l1_out_data     (l1_out_data[x][y]),
          .l1_out_valid    (l1_out_valid[x][y]),
          .l1_out_ready    (l1_out_ready[x][y]),
          .l1_in_data      (l1_in_data[x][y]),
          .l1_in_valid     (l1_in_valid[x][y]),
          .l1_in_ready     (l1_in_ready[x][y]),

          .l2_out_data     (l2_out_data[x][y]),
          .l2_out_valid    (l2_out_valid[x][y]),
          .l2_out_ready    (l2_out_ready[x][y]),
          .l2_in_data      (l2_in_data[x][y]),
          .l2_in_valid     (l2_in_valid[x][y]),
          .l2_in_ready     (l2_in_ready[x][y]),

          .instr           (microcode[x * Y + y]),
          .instr_valid     (microcode_valid[x * Y + y]),
          .pc              (pc[x * Y + y]),

          .stream_data     (stream_data[511:0]),
          .stream_valid    (stream_valid),
          .stream_ready    (stream_ready),

          .clk_pe          (clk_pe_grid[x][y]),
          .clk_noc         (clk_noc),
          .rst_n           (rst_n_sync)
        );

      end
    end
  endgenerate

  // ============================================================
  // L0 Directional Interconnect
  // Port map: [0]=LOCAL, [1]=N, [2]=E, [3]=S, [4]=W, [5]=NE, [6]=SE, [7]=NW
  // ============================================================
  // Port 1 (N) ↔ neighbor (x, y-1) Port 3 (S)
  // Port 2 (E) ↔ neighbor (x+1, y) Port 4 (W)
  // Port 5 (NE) ↔ neighbor (x+1, y-1) Port 7 (NW) on the neighbor side
  // Port 6 (SE) ↔ neighbor (x+1, y+1) Diagonal opposite is complex

  generate
    for (x = 0; x < X; x++) begin : gen_noc_x
      for (y = 0; y < Y; y++) begin : gen_noc_y

        // --- East-West (port 2 ↔ port 4) ---
        if (x < X-1) begin : gen_ew
          // PE(x,y) East → PE(x+1,y) West
          assign l0_in_data[x+1][y][4]  = l0_out_data[x][y][2];
          assign l0_in_valid[x+1][y][4] = l0_out_valid[x][y][2];
          assign l0_out_ready[x][y][2]  = l0_in_ready[x+1][y][4];
          // PE(x+1,y) West → PE(x,y) East
          assign l0_in_data[x][y][2]  = l0_out_data[x+1][y][4];
          assign l0_in_valid[x][y][2] = l0_out_valid[x+1][y][4];
          assign l0_out_ready[x+1][y][4] = l0_in_ready[x][y][2];
        end

        // --- North-South (port 1 ↔ port 3) ---
        if (y < Y-1) begin : gen_ns
          assign l0_in_data[x][y+1][3]  = l0_out_data[x][y][1];
          assign l0_in_valid[x][y+1][3] = l0_out_valid[x][y][1];
          assign l0_out_ready[x][y][1]  = l0_in_ready[x][y+1][3];
          assign l0_in_data[x][y][1]  = l0_out_data[x][y+1][3];
          assign l0_in_valid[x][y][1] = l0_out_valid[x][y+1][3];
          assign l0_out_ready[x][y+1][3] = l0_in_ready[x][y][1];
        end

        // --- Diagonal NE-SW (port 5 ↔ port 7 logic) ---
        if (x < X-1 && y > 0) begin : gen_ne
          assign l0_in_data[x+1][y-1][7] = l0_out_data[x][y][5];
          assign l0_in_valid[x+1][y-1][7] = l0_out_valid[x][y][5];
          assign l0_out_ready[x][y][5] = l0_in_ready[x+1][y-1][7];
          assign l0_in_data[x][y][5] = l0_out_data[x+1][y-1][7];
          assign l0_in_valid[x][y][5] = l0_out_valid[x+1][y-1][7];
          assign l0_out_ready[x+1][y-1][7] = l0_in_ready[x][y][5];
        end

        // --- Diagonal SE-NW (port 6 ↔ port 7 logic) ---
        if (x < X-1 && y < Y-1) begin : gen_se
          assign l0_in_data[x+1][y+1][7] = l0_out_data[x][y][6];
          assign l0_in_valid[x+1][y+1][7] = l0_out_valid[x][y][6];
          assign l0_out_ready[x][y][6] = l0_in_ready[x+1][y+1][7];
          assign l0_in_data[x][y][6] = l0_out_data[x+1][y+1][7];
          assign l0_in_valid[x][y][6] = l0_out_valid[x+1][y+1][7];
          assign l0_out_ready[x+1][y+1][7] = l0_in_ready[x][y][6];
        end

        // --- Edge ports: tie off unused directions on grid boundaries ---
        if (x == 0) begin : gen_we_edge
          assign l0_in_data[x][y][4] = '0;
          assign l0_in_valid[x][y][4] = 1'b0;
          assign l0_out_ready[x][y][4] = 1'b0;
        end
        if (x == X-1) begin : gen_ee_edge
          assign l0_in_data[x][y][2] = '0;
          assign l0_in_valid[x][y][2] = 1'b0;
          assign l0_out_ready[x][y][2] = 1'b0;
        end
        if (y == 0) begin : gen_ne_edge
          assign l0_in_data[x][y][1] = '0;
          assign l0_in_valid[x][y][1] = 1'b0;
          assign l0_out_ready[x][y][1] = 1'b0;
        end
        if (y == Y-1) begin : gen_se_edge
          assign l0_in_data[x][y][3] = '0;
          assign l0_in_valid[x][y][3] = 1'b0;
          assign l0_out_ready[x][y][3] = 1'b0;
        end
      end
    end
  endgenerate

  // ============================================================
  // L1 Expressway Interconnect (highway nodes only)
  // ============================================================
  generate
    for (x = 0; x < X; x++) begin : gen_l1_x
      for (y = 0; y < Y; y++) begin : gen_l1_y
        if ((x % 4 == 0) && (y % 4 == 0)) begin : gen_l1_hw
          // L1 horizontal: connect to next highway node in X direction (x+4)
          if (x + 4 < X) begin : gen_l1_h
            assign l1_in_data[x+4][y]  = l1_out_data[x][y];
            assign l1_in_valid[x+4][y] = l1_out_valid[x][y];
            assign l1_out_ready[x][y]  = l1_in_ready[x+4][y];
            assign l1_in_data[x][y]    = l1_out_data[x+4][y];
            assign l1_in_valid[x][y]   = l1_out_valid[x+4][y];
            assign l1_out_ready[x+4][y] = l1_in_ready[x][y];
          end
          // L1 vertical: connect to next highway node in Y direction (y+4)
          if (y + 4 < Y) begin : gen_l1_v
            assign l1_in_data[x][y+4]  = l1_out_data[x][y];
            assign l1_in_valid[x][y+4] = l1_out_valid[x][y];
            assign l1_out_ready[x][y]  = l1_in_ready[x][y+4];
            assign l1_in_data[x][y]    = l1_out_data[x][y+4];
            assign l1_in_valid[x][y]   = l1_out_valid[x][y+4];
            assign l1_out_ready[x][y+4] = l1_in_ready[x][y];
          end
        end else begin : gen_l1_tie
          assign l1_out_data[x][y]  = '0;
          assign l1_out_valid[x][y] = 1'b0;
          assign l1_in_ready[x][y]  = 1'b0;
        end
      end
    end
  endgenerate

  // ============================================================
  // L2 SN-Boundary Interconnect
  // ============================================================
  generate
    for (x = 0; x < X; x++) begin : gen_l2_x
      for (y = 0; y < Y; y++) begin : gen_l2_y
        if ((x % 4 == 0) && (y % 4 == 0)) begin : gen_l2_hw
          if (x + 4 < X) begin : gen_l2_h
            assign l2_in_data[x+4][y]  = l2_out_data[x][y];
            assign l2_in_valid[x+4][y] = l2_out_valid[x][y];
            assign l2_out_ready[x][y]  = l2_in_ready[x+4][y];
          end
          if (x > 0 && x - 4 >= 0) begin : gen_l2_v
            assign l2_in_data[x][y]    = l2_out_data[x-4][y];
            assign l2_in_valid[x][y]   = l2_out_valid[x-4][y];
            assign l2_out_ready[x-4][y] = l2_in_ready[x][y];
          end
        end else begin : gen_l2_tie
          assign l2_out_data[x][y]  = '0;
          assign l2_out_valid[x][y] = 1'b0;
          assign l2_in_ready[x][y]  = 1'b0;
        end
      end
    end
  endgenerate

  // ============================================================
  // Edge I/O: connect grid boundary PEs to stream engine
  // ============================================================
  // North edge (y=0): each row's PE(0..X-1, 0) provides DDR data
  generate
    for (x = 0; x < X; x++) begin : gen_edge
      assign edge_data_in[x]  = l0_out_data[x][0][1];
      assign edge_valid[x]    = l0_out_valid[x][0][1];
      assign l0_out_ready[x][0][1] = edge_ready[x];
    end
  endgenerate

  edge_io edge (
    .edge_data_in    (edge_data_in),
    .edge_valid      (edge_valid),
    .edge_ready      (edge_ready),
    .edge_data_out   (edge_data_out),
    .edge_out_valid  (edge_out_valid),
    .edge_out_ready  (edge_out_ready),
    .stream_data     (stream_data[1023:0]),
    .stream_valid    (stream_valid),
    .stream_ready    (stream_ready),
    .stream_out_data (stream_out_data),
    .stream_out_valid(stream_out_valid),
    .stream_out_ready(stream_out_ready),
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
