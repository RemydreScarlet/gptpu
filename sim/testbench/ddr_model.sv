import gptpu_pkg::*;

// Behavioral DDR memory model for testbench use.
// Decodes ACTIVATE / READ / WRITE commands from the controller's command
// pins and presents/samples 512-bit bus words.  A full 1024-bit cache line
// is assembled from two consecutive READ or WRITE commands.  The line
// address is captured at ACTIVATE from the bank/row/col pins.
module ddr_model #(
  parameter int MEM_LINES = 16384
) (
  inout  wire [511:0] ddr_bus,
  input  logic        ddr_clk_p,
  input  logic        ddr_cke,
  input  logic        ddr_cs_n,
  input  logic [1:0]  ddr_bg,
  input  logic [1:0]  ddr_ba,
  input  logic [15:0] ddr_addr,
  input  logic        ddr_ras_n,
  input  logic        ddr_cas_n,
  input  logic        ddr_we_n
);

  wire act = !ddr_cs_n && !ddr_ras_n &&  ddr_cas_n &&  ddr_we_n;  // ACTIVATE
  wire rd  = !ddr_cs_n &&  ddr_ras_n && !ddr_cas_n &&  ddr_we_n;  // READ
  wire wr  = !ddr_cs_n &&  ddr_ras_n && !ddr_cas_n && !ddr_we_n;  // WRITE

  logic [1023:0] mem [0:MEM_LINES-1];
  logic [31:0]   line_addr;
  logic          rd_word, wr_word;
  logic [1023:0] wacc;

  // Drive the bus only during a READ command (controller drives during WRITE).
  assign ddr_bus = rd ? (rd_word ? mem[line_addr % MEM_LINES][1023:512]
                                 : mem[line_addr % MEM_LINES][511:0])
                      : {512{1'bz}};

  always @(posedge ddr_clk_p) begin
    if (!ddr_cs_n) begin
      if (act) begin
        line_addr <= {ddr_bg, ddr_ba, ddr_addr};
      end else if (rd) begin
        rd_word <= ~rd_word;
      end else if (wr) begin
        if (!wr_word) begin
          wacc <= {512'd0, ddr_bus};
        end else begin
          mem[line_addr % MEM_LINES] <= {ddr_bus, wacc[511:0]};
        end
        wr_word <= ~wr_word;
      end
    end
  end

endmodule