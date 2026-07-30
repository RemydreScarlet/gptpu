import gptpu_pkg::*;

module stream_engine (
  output logic [DDR_CACHE_LINE*8-1:0] read_data_out,
  output logic                         read_valid,
  input  logic                         read_ready,
  output logic [DDR_CACHE_LINE*8-1:0] pe_stream_data,
  output logic                         pe_stream_valid,
  input  logic                         pe_stream_ready,
  output logic [15:0]                  credit_available,
  input  logic                         credit_consume,
  input  logic                         stream_v,
  input  logic                         stream_s,
  input  logic [31:0]                  stream_addr,
  input  logic [31:0]                  stream_length,
  input  logic                         clk_io,
  input  logic                         rst_n
);

  typedef enum logic [1:0] {
    ST_IDLE, ST_READ, ST_WRITE, ST_DONE
  } state_t;

  state_t state;
  logic [31:0] ptr;
  logic [31:0] remaining;
  logic [15:0] credit;
  logic [1023:0] buf;
  logic buf_valid;

  always_ff @(posedge clk_io or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      ptr <= '0;
      remaining <= '0;
      credit <= DDR_CREDIT_MAX;
      buf_valid <= 1'b0;
      buf <= '0;
      read_valid <= 1'b0;
      pe_stream_valid <= 1'b0;
    end else begin
      credit <= credit - credit_consume;

      unique case (state)
        ST_IDLE: begin
          read_valid <= 1'b0;
          pe_stream_valid <= 1'b0;
          if (stream_v || stream_s) begin
            state <= ST_READ;
            ptr <= stream_addr;
            remaining <= stream_length;
          end
        end

        ST_READ: begin
          if (stream_v && remaining > 0 && credit > 0) begin
            read_valid <= 1'b1;
            read_data_out <= '0;
            if (read_ready) begin
              buf <= read_data_out;
              buf_valid <= 1'b1;
              ptr <= ptr + DDR_CACHE_LINE;
              remaining <= remaining - 1;
            end
          end else if (remaining == 0 || credit == 0) begin
            state <= stream_v ? ST_DONE : ST_WRITE;
            read_valid <= 1'b0;
          end
        end

        ST_WRITE: begin
          if (stream_s && buf_valid && pe_stream_ready) begin
            pe_stream_valid <= 1'b1;
            pe_stream_data <= buf;
            buf_valid <= 1'b0;
          end
          if (!buf_valid && remaining > 0) begin
            state <= ST_READ;
          end else if (!buf_valid && remaining == 0) begin
            state <= ST_DONE;
          end
        end

        ST_DONE: begin
          pe_stream_valid <= 1'b0;
          read_valid <= 1'b0;
          state <= ST_IDLE;
        end
      endcase
    end
  end

  assign credit_available = credit;

endmodule
