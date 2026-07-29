import gptpu_pkg::*;

module ddr_controller (
  // LPDDR5 external interface (PHY level)
  inout  wire [DDR_BUS_WIDTH-1:0] ddr_bus,
  output logic                     ddr_clk_p, ddr_clk_n,
  output logic                     ddr_cke, ddr_cs_n,
  output logic [1:0]               ddr_bg, ddr_ba,
  output logic [15:0]              ddr_addr,
  output logic                     ddr_ras_n, ddr_cas_n, ddr_we_n,

  // Stream engine interface
  input  logic [DDR_CACHE_LINE*8-1:0] read_data_in,
  input  logic                         read_valid,
  output logic                         read_ready,
  output logic [DDR_CACHE_LINE*8-1:0] write_data_out,
  output logic                         write_valid,
  input  logic                         write_ready,

  // Credit-based flow control
  input  logic [15:0] credit_available,  // from PE SRAM free space
  output logic        credit_consume,
  input  logic        credit_replenish,

  // Control
  input  logic [31:0] ddr_addr_start,
  input  logic [31:0] transfer_length,
  input  logic        read_not_write,

  // Clock & reset
  input  logic clk_ddr,
  input  logic rst_n
);

  // --- State machine ---
  typedef enum logic [1:0] {
    IDLE,
    ACTIVE,
    DRAIN
  } ddr_state_t;

  ddr_state_t state;
  logic [31:0] burst_counter;

  always_ff @(posedge clk_ddr or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      burst_counter <= '0;
    end else begin
      unique case (state)
        IDLE: begin
          if (read_not_write && read_valid && credit_available > 0) begin
            state <= ACTIVE;
            burst_counter <= transfer_length;
          end
        end
        ACTIVE: begin
          if (burst_counter > 0 && read_ready) begin
            burst_counter <= burst_counter - 1;
          end
          if (burst_counter == 0) begin
            state <= DRAIN;
          end
        end
        DRAIN: begin
          state <= IDLE;
        end
      endcase
    end
  end

  // --- Credit management ---
  assign credit_consume = (state == ACTIVE) && read_ready;

  // --- Output ---
  assign write_data_out = '0;  // Simplified
  assign write_valid = 1'b0;
  assign read_ready = 1'b1;    // Always ready to accept from stream engine

endmodule
