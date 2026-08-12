// Top-level L1 expressway functional test.
// Verifies highway-lattice routing end-to-end through gptpu_top:
//  - T1: long-range E-W delivery via the L1 lattice (source (0,0) -> dest (8,0))
//  - T2: long-range N-S delivery via the L1 lattice (source (4,0) -> dest (4,4))
//  - T3: short-range L0-only mesh delivery from a NON-highway node
//        (source (2,2) -> dest (3,3)); asserts no L1 activity
// Test hooks (test_inject_* / test_eject_* / test_l1_valid) were added to
// pe_core and gptpu_top to bypass the CCE for injection.
import gptpu_pkg::*;

module tb_top_l1;
  localparam int X = PE_GRID_X;  // 16
  localparam int Y = PE_GRID_Y;  // 8

  // ---- top-level IO (DDR/stream pins tied inert here) ----
  logic [DDR_BUS_WIDTH-1:0] ddr_bus;
  logic ddr_clk_p, ddr_clk_n, ddr_cke, ddr_cs_n;
  logic [1:0]  ddr_bg, ddr_ba;
  logic [15:0] ddr_addr;
  logic ddr_ras_n, ddr_cas_n, ddr_we_n;
  logic clk_ref = 1'b0, rst_n_ext;
  logic lut_write_en; logic [3:0] lut_write_table; logic [7:0] lut_write_addr; fp8_e4m3_t lut_write_data;

  logic test_inject_valid [X-1:0][Y-1:0];
  logic [63:0] test_inject_data  [X-1:0][Y-1:0];
  logic test_inject_ready [X-1:0][Y-1:0];
  logic [63:0] test_eject_data   [X-1:0][Y-1:0];
  logic test_eject_valid  [X-1:0][Y-1:0];
  logic test_l1_valid     [X-1:0][Y-1:0];
  logic test_l2_valid     [X-1:0][Y-1:0];

  gptpu_top dut (
    .ddr_bus(ddr_bus), .ddr_clk_p(ddr_clk_p), .ddr_clk_n(ddr_clk_n),
    .ddr_cke(ddr_cke), .ddr_cs_n(ddr_cs_n), .ddr_bg(ddr_bg), .ddr_ba(ddr_ba),
    .ddr_addr(ddr_addr), .ddr_ras_n(ddr_ras_n), .ddr_cas_n(ddr_cas_n), .ddr_we_n(ddr_we_n),
    .clk_ref(clk_ref), .rst_n_ext(rst_n_ext),
    .lut_write_en(lut_write_en), .lut_write_table(lut_write_table),
    .lut_write_addr(lut_write_addr), .lut_write_data(lut_write_data),
    .test_inject_valid(test_inject_valid), .test_inject_data(test_inject_data),
    .test_inject_ready(test_inject_ready),
    .test_eject_data(test_eject_data), .test_eject_valid(test_eject_valid),
    .test_l1_valid(test_l1_valid), .test_l2_valid(test_l2_valid)
  );

  always #5 clk_ref = ~clk_ref;  // 10 ns period
  integer fails = 0;

  // Build the 64-bit unicast flit: {dst_y, dst_x, bcast[2:0], flags[4:0], payload}
  function automatic logic [63:0] mkflit(int dx, int dy, logic [39:0] payload);
    return {dy[7:0], dx[7:0], 3'd0, 5'd0, payload};
  endfunction

  // Hold valid across at least one clk_pe posedge so the async inject FIFO
  // performs a real write cycle (w_valid && w_ready). clk_pe == clk_ref here.
  task automatic inj(int sx, int sy, logic [63:0] flit);
    @(negedge clk_ref);
    test_inject_data[sx][sy] = flit;
    test_inject_valid[sx][sy] = 1'b1;
    while (!test_inject_ready[sx][sy]) @(posedge clk_ref);
    @(posedge clk_ref);          // write lands on this posedge (valid && ready)
    @(negedge clk_ref);
    test_inject_valid[sx][sy] = 1'b0;
    $display("  [%0t] injected %h at (%0d,%0d)", $time, flit, sx, sy);
  endtask

  task automatic await_eject(int x, int y, logic [63:0] expected);
    int cycles = 0;
    while (!test_eject_valid[x][y]) begin
      @(negedge clk_ref);
      cycles = cycles + 1;
      if (cycles > 5000) begin
        $display("  [L1] TIMEOUT waiting eject at (%0d,%0d)", x, y); fails=fails+1; return;
      end
    end
    if (test_eject_data[x][y] !== expected) begin
      $display("  [L1] FAIL dst(%0d,%0d): got %h expected %h", x, y, test_eject_data[x][y], expected);
      fails = fails + 1;
    end else begin
      $display("  [L1] PASS dst(%0d,%0d): %h", x, y, test_eject_data[x][y]);
    end
  endtask

  initial begin
    rst_n_ext = 1'b0;
    lut_write_en = 1'b0; lut_write_table='0; lut_write_addr=8'd0; lut_write_data=8'h00;
    for (int x = 0; x < X; x++)
      for (int y = 0; y < Y; y++) begin
        test_inject_valid[x][y] = 1'b0;
        test_inject_data[x][y]  = 64'h0;
      end
    #100 rst_n_ext = 1'b1;
    repeat (8) @(posedge clk_ref);

    // ---- T1: (0,0) -> (8,0) via the L1 E-W lattice ----
    $display("== T1: L1 E-W (0,0)->(8,0) ==");
    begin
      logic [63:0] flit;
      logic saw_l1 = 1'b0;
      int i;
      flit = mkflit(8, 0, 40'hA5A5A5A5A5);
      inj(0, 0, flit);
      for (i = 0; i < 4000; i++) begin
        @(negedge clk_ref);
        if (test_l1_valid[0][0] || test_l1_valid[4][0] || test_l1_valid[8][0]) saw_l1 = 1'b1;
        if (test_eject_valid[8][0]) break;
      end
      if (!saw_l1) begin $display("  [L1] FAIL: no L1 lattice activity observed on E-W spine"); fails=fails+1; end
      else         begin $display("  [L1] info: L1 lattice activity observed on E-W"); end
      await_eject(8, 0, flit);
    end

    // ---- T2: (4,0) -> (4,4) via the L1 N-S lattice ----
    $display("== T2: L1 N-S (4,0)->(4,4) ==");
    begin
      logic [63:0] flit;
      logic saw_l1 = 1'b0;
      int i;
      flit = mkflit(4, 4, 40'h5C5C5C5C5C);
      inj(4, 0, flit);
      for (i = 0; i < 4000; i++) begin
        @(negedge clk_ref);
        if (test_l1_valid[4][0] || test_l1_valid[4][4]) saw_l1 = 1'b1;
        if (test_eject_valid[4][4]) break;
      end
      if (!saw_l1) begin $display("  [L1] FAIL: no L1 lattice activity observed on N-S"); fails=fails+1; end
      else         begin $display("  [L1] info: L1 lattice activity observed on N-S"); end
      await_eject(4, 4, flit);
    end

    // ---- T3: L0-only mesh, source NON-highway (2,2)->(3,3) ----
    $display("== T3: L0-only mesh (2,2)->(3,3) ==");
    begin
      logic [63:0] flit;
      flit = mkflit(3, 3, 40'h1234567890);
      inj(2, 2, flit);
      @(negedge clk_ref);
      if (test_l1_valid[2][2]) begin $display("  [L1] FAIL: non-highway (2,2) produced L1"); fails=fails+1; end
      await_eject(3, 3, flit);
    end

    if (fails == 0) $display("TOP-LEVEL L1 testbench PASSED");
    else            $display("TOP-LEVEL L1 testbench FAILED (%0d)", fails);
    $finish;
  end
endmodule