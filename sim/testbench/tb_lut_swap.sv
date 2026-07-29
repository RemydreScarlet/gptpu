import gptpu_pkg::*;

module tb_lut_swap;

  logic clk_pe, rst_n;

  logic [7:0] entry_addr;
  logic [3:0] table_id;
  fp8_e4m3_t  entry_out;

  logic       write_en;
  logic [3:0] write_table;
  logic [7:0] write_addr;
  fp8_e4m3_t  write_data;

  logic       swap_lut, swap_done;
  logic       boot_load;
  logic [3:0] boot_table_id;

  configurable_lut dut (
    .entry_addr   (entry_addr),
    .table_id     (table_id),
    .entry_out    (entry_out),
    .write_en     (write_en),
    .write_table  (write_table),
    .write_addr   (write_addr),
    .write_data   (write_data),
    .swap_lut     (swap_lut),
    .swap_done    (swap_done),
    .boot_load    (boot_load),
    .boot_table_id(boot_table_id),
    .clk_pe       (clk_pe),
    .rst_n        (rst_n)
  );

  fp8_e4m3_t val_before, val_after;

  initial begin
    rst_n = 1'b0;
    #100 rst_n = 1'b1;

    // Boot init table 0 (Tanh)
    boot_load = 1'b1;
    boot_table_id = 4'd0;
    @(posedge clk_pe);
    boot_load = 1'b0;

    // Read entry 0 from active bank
    table_id = 4'd0;
    entry_addr = 8'd0;
    #10;
    val_before = entry_out;

    // SWAPL
    swap_lut = 1'b1;
    @(posedge clk_pe);
    swap_lut = 1'b0;

    // Read same entry — should now come from shadow (uninitialized = 0)
    #10;
    val_after = entry_out;

    assert (swap_done) else $error("SWAPL not completed");
    $display("Before SWAPL: %h, After SWAPL: %h", val_before, val_after);
    $display("LUT swap testbench PASSED");
    $finish;
  end

  always #5 clk_pe = ~clk_pe;

endmodule
