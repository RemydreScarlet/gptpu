import gptpu_pkg::*;

module sram_512kb (
  // Bank 0 interface
  input  logic [15:0] addr0,
  input  logic         cs0, we0,
  input  logic [511:0] data0_w,
  output logic [511:0] data0_r,
  input  logic         bwe0,        // byte-write enable (scalar ST)
  input  logic [5:0]   baddr0,      // byte offset within the line

  // Bank 1 interface
  input  logic [15:0] addr1,
  input  logic         cs1, we1,
  input  logic [511:0] data1_w,
  output logic [511:0] data1_r,

  // Bank 2 interface
  input  logic [15:0] addr2,
  input  logic         cs2, we2,
  input  logic [511:0] data2_w,
  output logic [511:0] data2_r,

  // Bank 3 interface
  input  logic [15:0] addr3,
  input  logic         cs3, we3,
  input  logic [511:0] data3_w,
  output logic [511:0] data3_r,

  // Local clock & reset
  input  logic clk_pe,
  input  logic rst_n
);

  // --- 4 banks of single-port SRAM (separate read/write data buses) ---
  // Bank 0: 256 KB = 4096 lines x 512 bits
  logic [511:0] mem0 [4095:0];

  // Bank 1: 128 KB = 2048 lines x 512 bits
  logic [511:0] mem1 [2047:0];

  // Bank 2:  64 KB = 1024 lines x 512 bits
  logic [511:0] mem2 [1023:0];

  // Bank 3:  64 KB = 1024 lines x 512 bits
  logic [511:0] mem3 [1023:0];

  // --- Bank 0 ---
  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n) begin
      data0_r <= '0;
    end else if (cs0) begin
      if (we0) begin
        if (bwe0) begin
          mem0[addr0[15:6]][baddr0*8 +: 8] <= data0_w[7:0];  // byte-granular ST
        end else begin
          mem0[addr0[15:6]] <= data0_w;
        end
      end else begin
        data0_r <= mem0[addr0[15:6]];
      end
    end else begin
      data0_r <= '0;
    end
  end

  // --- Bank 1 ---
  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n) begin
      data1_r <= '0;
    end else if (cs1) begin
      if (we1) mem1[addr1[15:6]] <= data1_w;
      else     data1_r <= mem1[addr1[15:6]];
    end else begin
      data1_r <= '0;
    end
  end

  // --- Bank 2 ---
  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n) begin
      data2_r <= '0;
    end else if (cs2) begin
      if (we2) mem2[addr2[15:6]] <= data2_w;
      else     data2_r <= mem2[addr2[15:6]];
    end else begin
      data2_r <= '0;
    end
  end

  // --- Bank 3 ---
  always_ff @(posedge clk_pe or negedge rst_n) begin
    if (!rst_n) begin
      data3_r <= '0;
    end else if (cs3) begin
      if (we3) mem3[addr3[15:6]] <= data3_w;
      else     data3_r <= mem3[addr3[15:6]];
    end else begin
      data3_r <= '0;
    end
  end

endmodule