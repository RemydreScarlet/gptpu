import gptpu_pkg::*;

module async_port_controller (
  // L0 data ports (clk_noc domain): direct NoC fabric connections
  // These are handled by the router directly; the controller only provides
  // clock domain crossing for the CCE inject/eject path.

  // Inject path: CCE → FIFO(clk_pe→clk_noc) → Router
  input  logic [63:0] inject_data,
  input  logic        inject_valid,
  output logic        inject_ready,
  output logic [63:0] inject_router_data,
  output logic        inject_router_valid,
  input  logic        inject_router_ready,

  // Eject path: Router → FIFO(clk_noc→clk_pe) → CCE
  input  logic [63:0] eject_router_data,
  input  logic        eject_router_valid,
  output logic        eject_router_ready,
  output logic [63:0] eject_data,
  output logic        eject_valid,
  input  logic        eject_ready,

  input  logic clk_pe,
  input  logic clk_noc,
  input  logic rst_n
);

  // --- Inject FIFO: clk_pe → clk_noc ---
  async_fifo_2stage #(.DATA_WIDTH(64)) inject_fifo (
    .w_data   (inject_data),
    .w_valid  (inject_valid),
    .w_ready  (inject_ready),
    .r_data   (inject_router_data),
    .r_valid  (inject_router_valid),
    .r_ready  (inject_router_ready),
    .clk_wr   (clk_pe),
    .clk_rd   (clk_noc),
    .rst_n_wr (rst_n),
    .rst_n_rd (rst_n)
  );

  // --- Eject FIFO: clk_noc → clk_pe ---
  async_fifo_2stage #(.DATA_WIDTH(64)) eject_fifo (
    .w_data   (eject_router_data),
    .w_valid  (eject_router_valid),
    .w_ready  (eject_router_ready),
    .r_data   (eject_data),
    .r_valid  (eject_valid),
    .r_ready  (eject_ready),
    .clk_wr   (clk_noc),
    .clk_rd   (clk_pe),
    .rst_n_wr (rst_n),
    .rst_n_rd (rst_n)
  );

endmodule
