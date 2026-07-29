import gptpu_pkg::*;

module sram_512kb (
  // Bank 0 interface
  input  logic [15:0] addr0,
  input  logic         cs0, we0,
  inout  wire  [511:0] data0,

  // Bank 1 interface
  input  logic [15:0] addr1,
  input  logic         cs1, we1,
  inout  wire  [511:0] data1,

  // Bank 2 interface
  input  logic [14:0] addr2,
  input  logic         cs2, we2,
  inout  wire  [511:0] data2,

  // Bank 3 interface
  input  logic [14:0] addr3,
  input  logic         cs3, we3,
  inout  wire  [511:0] data3,

  // Local clock & reset
  input  logic clk_pe,
  input  logic rst_n
);

  // --- 4 banks of single-port SRAM ---
  // Bank 0: 256 KB = 4096 lines x 512 bits
  logic [511:0] mem0 [4095:0];

  // Bank 1: 128 KB = 2048 lines x 512 bits
  logic [511:0] mem1 [2047:0];

  // Bank 2:  64 KB = 1024 lines x 512 bits
  logic [511:0] mem2 [1023:0];

  // Bank 3:  64 KB = 1024 lines x 512 bits
  logic [511:0] mem3 [1023:0];

  // --- Bank 0 ---
  always_ff @(posedge clk_pe) begin
    if (cs0) begin
      if (we0) mem0[addr0] <= data0;
      else     data0 <= mem0[addr0];
    end else begin
      data0 <= 'Z;
    end
  end

  // --- Bank 1 ---
  always_ff @(posedge clk_pe) begin
    if (cs1) begin
      if (we1) mem1[addr1] <= data1;
      else     data1 <= mem1[addr1];
    end else begin
      data1 <= 'Z;
    end
  end

  // --- Bank 2 ---
  always_ff @(posedge clk_pe) begin
    if (cs2) begin
      if (we2) mem2[addr2] <= data2;
      else     data2 <= mem2[addr2];
    end else begin
      data2 <= 'Z;
    end
  end

  // --- Bank 3 ---
  always_ff @(posedge clk_pe) begin
    if (cs3) begin
      if (we3) mem3[addr3] <= data3;
      else     data3 <= mem3[addr3];
    end else begin
      data3 <= 'Z;
    end
  end

endmodule
