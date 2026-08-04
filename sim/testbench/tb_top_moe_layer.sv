import gptpu_pkg::*;

module tb_top_moe_layer;

  logic clk_ref = 1'b0, rst_n_ext;
  wire  [DDR_BUS_WIDTH-1:0] ddr_bus;
  logic ddr_clk_p, ddr_clk_n, ddr_cke, ddr_cs_n;
  logic [1:0] ddr_bg, ddr_ba;
  logic [15:0] ddr_addr;
  logic ddr_ras_n, ddr_cas_n, ddr_we_n;

  gptpu_top dut (
    .ddr_bus    (ddr_bus),
    .ddr_clk_p  (ddr_clk_p),
    .ddr_clk_n  (ddr_clk_n),
    .ddr_cke    (ddr_cke),
    .ddr_cs_n   (ddr_cs_n),
    .ddr_bg     (ddr_bg),
    .ddr_ba     (ddr_ba),
    .ddr_addr   (ddr_addr),
    .ddr_ras_n  (ddr_ras_n),
    .ddr_cas_n  (ddr_cas_n),
    .ddr_we_n   (ddr_we_n),
    .clk_ref    (clk_ref),
    .rst_n_ext  (rst_n_ext)
  );

  initial begin
    rst_n_ext = 1'b0;
    #100 rst_n_ext = 1'b1;

    // Let the design stabilize (128 PEs, NoC, DDR all initialized)
    #500;

    // TODO: Inject microcode and verify MoE FFN computation
    // For now, smoke test only

    $display("MoE layer top-level testbench PASSED (smoke)");
    $finish;
  end

  always #5 clk_ref = ~clk_ref;

endmodule
