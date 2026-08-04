import gptpu_pkg::*;

module ddr_controller (
  inout  wire [DDR_BUS_WIDTH-1:0] ddr_bus,
  output logic                     ddr_clk_p, ddr_clk_n,
  output logic                     ddr_cke, ddr_cs_n,
  output logic [1:0]               ddr_bg, ddr_ba,
  output logic [15:0]              ddr_addr,
  output logic                     ddr_ras_n, ddr_cas_n, ddr_we_n,

  input  logic [DDR_CACHE_LINE*8-1:0] read_data_in,
  input  logic                         read_valid,
  output logic                         read_ready,
  output logic [DDR_CACHE_LINE*8-1:0] write_data_out,
  output logic                         write_valid,
  input  logic                         write_ready,

  input  logic [15:0] credit_available,
  output logic        credit_consume,
  input  logic        credit_replenish,

  input  logic [31:0] ddr_addr_start,
  input  logic [31:0] transfer_length,
  input  logic        read_not_write,

  input  logic clk_ddr,
  input  logic rst_n
);

  typedef enum logic [2:0] {
    IDLE, ACTIVATE, READ, WRITE, PRECHARGE, DRAIN
  } ddr_state_t;

  ddr_state_t state, next_state;
  logic [31:0] burst_cnt;
  logic [31:0] row_addr;
  logic [15:0] credit;

  always_ff @(posedge clk_ddr or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      burst_cnt <= '0;
      credit <= '0;
      ddr_cke <= 1'b0;
      ddr_cs_n <= 1'b1;
      ddr_ras_n <= 1'b1;
      ddr_cas_n <= 1'b1;
      ddr_we_n <= 1'b1;
      read_ready <= 1'b0;
      write_valid <= 1'b0;
    end else begin
      state <= next_state;
      ddr_cke <= 1'b1;

      unique case (state)
        IDLE: begin
          credit <= credit_available;
          if (read_not_write && read_valid && credit_available > 0) begin
            row_addr <= ddr_addr_start[31:16];
            burst_cnt <= transfer_length;
            ddr_cs_n <= 1'b0;
          end
        end
        ACTIVATE: begin
          ddr_ras_n <= 1'b0;
          ddr_addr[15:0] <= {row_addr[15:0]};
          ddr_cs_n <= 1'b0;
          burst_cnt <= transfer_length;
        end
        READ: begin
          ddr_ras_n <= 1'b1;
          ddr_cas_n <= 1'b0;
          ddr_addr[15:0] <= ddr_addr_start[15:0];
          if (burst_cnt > 0) begin
            read_ready <= 1'b1;
            credit <= credit - 1;
            burst_cnt <= burst_cnt - 1;
          end else begin
            read_ready <= 1'b0;
          end
        end
        WRITE: begin
          ddr_ras_n <= 1'b1;
          ddr_cas_n <= 1'b0;
          ddr_we_n <= 1'b0;
          ddr_addr[15:0] <= ddr_addr_start[15:0];
          if (write_ready && burst_cnt > 0) begin
            write_valid <= 1'b1;
            write_data_out <= '0;
            burst_cnt <= burst_cnt - 1;
          end else begin
            write_valid <= 1'b0;
          end
        end
        DRAIN: begin
          ddr_cas_n <= 1'b1;
          ddr_we_n <= 1'b1;
          read_ready <= 1'b0;
          write_valid <= 1'b0;
        end
      endcase
    end
  end

  always_comb begin
    next_state = state;
    unique case (state)
      IDLE: if (read_valid && credit_available > 0)
              next_state = ddr_state_t'(read_not_write ? ACTIVATE : WRITE);
      ACTIVATE: next_state = READ;
      READ: if (burst_cnt == 0 && read_ready) next_state = DRAIN;
      WRITE: if (burst_cnt == 0) next_state = DRAIN;
      DRAIN: next_state = IDLE;
    endcase
  end

  assign credit_consume = (state == READ) && read_ready;
  assign ddr_clk_p = clk_ddr;
  assign ddr_clk_n = ~clk_ddr;

endmodule
