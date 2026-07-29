import gptpu_pkg::*;

module stream_engine (
  // DDR controller interface
  output logic [DDR_CACHE_LINE*8-1:0] read_data_out,
  output logic                         read_valid,
  input  logic                         read_ready,

  // PE core interface (data distribution)
  output logic [DDR_CACHE_LINE*8-1:0] pe_stream_data,
  output logic                         pe_stream_valid,
  input  logic                         pe_stream_ready,

  // Credit flow
  output logic [15:0] credit_available,
  input  logic        credit_consume,

  // Microcode stream commands
  input  logic        stream_v,       // STREAM.V active
  input  logic        stream_s,       // STREAM.S active
  input  logic [31:0] stream_addr,    // DDR source addr
  input  logic [31:0] stream_length,  // Transfer length

  // Clock & reset
  input  logic clk_io,
  input  logic rst_n
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_READ,
    ST_DISTRIBUTE
  } stream_state_t;

  stream_state_t state;
  logic [31:0] read_ptr;
  logic [31:0] words_remaining;

  // Simplified streaming state machine
  always_ff @(posedge clk_io or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      read_ptr <= '0;
      words_remaining <= '0;
    end else begin
      unique case (state)
        ST_IDLE: begin
          if (stream_v || stream_s) begin
            state <= ST_READ;
            read_ptr <= stream_addr;
            words_remaining <= stream_length;
          end
        end
        ST_READ: begin
          if (read_ready && words_remaining > 0) begin
            read_ptr <= read_ptr + DDR_CACHE_LINE;
            words_remaining <= words_remaining - 1;
          end
          if (words_remaining == 0) begin
            state <= ST_DISTRIBUTE;
          end
        end
        ST_DISTRIBUTE: begin
          if (pe_stream_ready) begin
            state <= ST_IDLE;
          end
        end
      endcase
    end
  end

  // --- Credits (simplified) ---
  assign credit_available = 16'd256;

  // --- Data path ---
  assign pe_stream_data  = read_data_out;
  assign pe_stream_valid = read_valid;
  assign read_data_out   = '0;

endmodule
