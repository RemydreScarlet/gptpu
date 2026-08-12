import gptpu_pkg::*;

// LPDDR5-style DDR controller with tristate data bus and a POSITIVE-edge
// command sequence:
//   IDLE -> ACTIVATE -> tRCD wait -> READ/WRITE burst (2 bus words per
//   1024-bit cache line) -> PRECHARGE -> tRP wait -> IDLE
//
// The 1024-bit cache line is wider than the 512-bit DDR bus, so the
// controller assembles (read) or splits (write) two 512-bit words per line.
module ddr_controller (
  inout  wire [DDR_BUS_WIDTH-1:0] ddr_bus,
  output logic                     ddr_clk_p, ddr_clk_n,
  output logic                     ddr_cke, ddr_cs_n,
  output logic [1:0]               ddr_bg, ddr_ba,
  output logic [15:0]              ddr_addr,
  output logic                     ddr_ras_n, ddr_cas_n, ddr_we_n,

  // Read request (issued by the stream engine)
  input  logic                        read_req_valid,
  output logic                        read_req_ready,
  input  logic [31:0]                 read_req_addr,

  // Read response (assembled 1024-bit cache line)
  output logic [DDR_CACHE_LINE*8-1:0] read_data_out,
  output logic                        read_data_valid,
  input  logic                        read_data_ready,

  // Write request (cache line from the stream engine / edge aggregator)
  input  logic                        write_req_valid,
  output logic                        write_req_ready,
  input  logic [31:0]                 write_req_addr,
  input  logic [DDR_CACHE_LINE*8-1:0] write_data_in,

  input  logic [15:0] credit_available,
  output logic        credit_consume,

  input  logic clk_ddr,
  input  logic rst_n
);

  localparam int TCY_T_RCD = 2;
  localparam int TCY_T_RP  = 2;

  typedef enum logic [3:0] {
    IDLE = 4'd0, ACTIVATE = 4'd1, TRCD_WAIT = 4'd2,
    READ0 = 4'd3, READ1 = 4'd4, WRITE0 = 4'd5, WRITE1 = 4'd6,
    PRECHARGE = 4'd7, TRP_WAIT = 4'd8
  } ddr_state_t;

  ddr_state_t state;
  logic [$clog2(TCY_T_RCD+1)-1:0] cd_wait;
  logic [$clog2(TCY_T_RP+1)-1:0]  rp_wait;
  logic [31:0] addr_reg;
  logic        rw_reg;
  logic        ddr_oe;
  logic [511:0] wdata_word;
  logic [1023:0] line_lo;

  // --- Command drive ---
  always_comb begin
    ddr_cs_n = 1'b1; ddr_ras_n = 1'b1; ddr_cas_n = 1'b1; ddr_we_n = 1'b1;
    case (state)
      ACTIVATE : begin ddr_cs_n=1'b0; ddr_ras_n=1'b0; end
      READ0, READ1 : begin ddr_cs_n=1'b0; ddr_cas_n=1'b0; end
      WRITE0, WRITE1 : begin ddr_cs_n=1'b0; ddr_cas_n=1'b0; ddr_we_n=1'b0; end
      PRECHARGE: begin ddr_cs_n=1'b0; ddr_ras_n=1'b0; ddr_we_n=1'b0; end
      default : ;
    endcase
    ddr_oe = (state == WRITE0 || state == WRITE1);
  end

  assign ddr_bg = addr_reg[27:26];
  assign ddr_ba = addr_reg[25:24];

  always_comb begin
    case (state)
      ACTIVATE : ddr_addr = {8'h0, addr_reg[31:24]};
      READ0, READ1, WRITE0, WRITE1 : ddr_addr = addr_reg[15:0];
      default  : ddr_addr = '0;
    endcase
  end

  // --- Write data word selection (512-bit half of the 1024-bit line) ---
  always_comb begin
    wdata_word = (state == WRITE1) ? write_data_in[1023:512]
                                   : write_data_in[511:0];
  end
  assign ddr_bus = ddr_oe ? wdata_word : {DDR_BUS_WIDTH{1'bz}};

  // --- Read data assembly ---
  always_ff @(posedge clk_ddr or negedge rst_n) begin
    if (!rst_n) begin
      line_lo <= '0; read_data_out <= '0;
    end else begin
      case (state)
        READ0: line_lo <= ddr_bus;
        READ1: begin
          read_data_out <= {ddr_bus, line_lo[511:0]};
        end
        default: ;
      endcase
    end
  end

  // --- FSM ---
  always_ff @(posedge clk_ddr or negedge rst_n) begin
    if (!rst_n) begin
      state       <= IDLE;
      cd_wait     <= '0;
      rp_wait     <= '0;
      addr_reg    <= '0;
      rw_reg      <= 1'b1;
      read_data_valid <= 1'b0;
      read_req_ready  <= 1'b0;
      write_req_ready <= 1'b0;
    end else begin
      read_data_valid <= 1'b0;
      read_req_ready  <= 1'b0;
      write_req_ready <= 1'b0;

      unique case (state)
        IDLE: begin
          if (read_req_valid && credit_available > 0) begin
            read_req_ready <= 1'b1;
            addr_reg  <= read_req_addr;
            rw_reg    <= 1'b1;
            cd_wait   <= TCY_T_RCD;
            state     <= ACTIVATE;
          end else if (write_req_valid && credit_available > 0) begin
            write_req_ready <= 1'b1;
            addr_reg  <= write_req_addr;
            rw_reg    <= 1'b0;
            cd_wait   <= TCY_T_RCD;
            state     <= ACTIVATE;
          end
        end

        ACTIVATE: begin
          if (cd_wait == 0) state <= (rw_reg ? READ0 : WRITE0);
          else              cd_wait <= cd_wait - 1;
        end

        READ0: state <= READ1;
        READ1: begin
          read_data_valid <= 1'b1;
          state <= PRECHARGE;
        end

        WRITE0: state <= WRITE1;
        WRITE1: state <= PRECHARGE;

        PRECHARGE: begin
          rp_wait <= TCY_T_RP;
          state   <= TRP_WAIT;
        end

        TRP_WAIT: begin
          if (rp_wait == 0) state <= IDLE;
          else              rp_wait <= rp_wait - 1;
        end
      endcase
    end
  end

  assign credit_consume = read_data_valid;  // one line per completed read

  assign ddr_clk_p = clk_ddr;
  assign ddr_clk_n = ~clk_ddr;

endmodule