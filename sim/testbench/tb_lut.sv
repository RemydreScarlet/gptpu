import gptpu_pkg::*;

module tb_lut;
  logic [7:0] entry_addr;
  logic [3:0] table_id;
  fp8_e4m3_t  entry_out;
  logic       write_en, swap_lut, swap_done, boot_load;
  logic [3:0] write_table, boot_table_id;
  logic [7:0] write_addr;
  fp8_e4m3_t  write_data;
  logic clk_pe = 1'b0, rst_n = 1'b1;

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

  always #5 clk_pe = ~clk_pe;

  initial begin
    write_en = 1'b0; write_table = '0; write_addr = '0; write_data = '0;
    swap_lut = 1'b0; boot_load = 1'b0; boot_table_id = '0;
    entry_addr = '0; table_id = '0;

    // reset
    rst_n = 1'b0; #20; rst_n = 1'b1;
    #10;

    // --- Boot tables 0,1,2 over 3 cycles (same as pe_core loader) ---
    for (int i = 0; i < 3; i++) begin
      boot_table_id = 3'd0 + i[1:0];
      boot_load = 1'b1;
      @(posedge clk_pe); #1;
    end
    boot_load = 1'b0;
    #5;

    // --- Check table 0 populated (identity init: entry n -> n) ---
    table_id = 4'd0;
    entry_addr = 8'd5;
    #5;
    $display("T: booted table0 entry5 = %02h (exp 05)", entry_out);
    if (entry_out == 8'h05) begin
      $display("LUT boot testbench PASSED (boot)");
    end else begin
      $display("LUT boot testbench FAILED (entry=%02h)", entry_out);
    end

    // --- Write path: program user table 9 entry 3 = 0xAA (goes to shadow bank),
    //     then SWAPL so it becomes readable from Active ---
    write_en = 1'b1; write_table = 4'd9; write_addr = 8'd3; write_data = 8'hAA;
    @(posedge clk_pe); #1;
    write_en = 1'b0;
    swap_lut = 1'b1; @(posedge clk_pe); #1; swap_lut = 1'b0;

    table_id = 4'd9; entry_addr = 8'd3;
    #5;
    $display("Twrite: table9 entry3 = %02h (exp AA after swap)", entry_out);
    if (entry_out == 8'hAA)
      $display("LUT write/swap testbench PASSED");
    else
      $display("LUT write/swap testbench FAILED (entry=%02h)", entry_out);
    $finish;
  end
endmodule