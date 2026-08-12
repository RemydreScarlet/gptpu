import gptpu_pkg::*;

// Stream engine: decodes the CCE STREAM.V / STREAM.S instructions and drives
// the DDR controller one cache line at a time.
//
//   STREAM.V (read):  issues a read request; the returned 1024-bit line is
//                     forwarded to edge_io (which splits it into 512-bit
//                     SRAM-line words and broadcasts to the PE grid).
//   STREAM.S (write): accepts a 1024-bit line from the edge aggregator and
//                     issues a write request to DDR.
module stream_engine (
  // CCE stream instruction decode
  input  logic         stream_v,
  input  logic         stream_s,
  input  logic [31:0]  stream_addr,
  input  logic [31:0]  stream_length,     // in cache lines

  // Controller read request / response
  output logic                          read_req_valid,
  input  logic                          read_req_ready,
  output logic [31:0]                   read_req_addr,
  input  logic [DDR_CACHE_LINE*8-1:0]   read_data_in,
  input  logic                          read_data_valid,
  output logic                          read_data_ready,

  // Broadcast line forwarded to edge_io (DDR -> PE)
  output logic [DDR_CACHE_LINE*8-1:0]   edge_stream_out,
  output logic                          edge_stream_out_valid,
  input  logic                          edge_stream_out_ready,

  // Write data from the edge aggregator (PE -> DDR)
  input  logic [DDR_CACHE_LINE*8-1:0]   edge_write_data,
  input  logic                          edge_write_valid,
  output logic                          edge_write_ready,

  // Controller write request
  output logic                          write_req_valid,
  input  logic                          write_req_ready,
  output logic [31:0]                   write_req_addr,
  output logic [DDR_CACHE_LINE*8-1:0]   write_data_out,

  output logic [15:0]                   credit_available,
  input  logic                          credit_consume,

  input  logic clk_io,
  input  logic rst_n
);

  typedef enum logic [2:0] {
    S_IDLE = 3'd0, S_READ_REQ = 3'd1, S_READ_WAIT = 3'd2, S_WRITE = 3'd3
  } st_t;

  st_t        state;
  logic [31:0] addr_reg;
  logic [31:0] remaining;
  logic [15:0] credit;

  always_ff @(posedge clk_io or negedge rst_n) begin
    if (!rst_n) begin
      state        <= S_IDLE;
      addr_reg     <= '0;
      remaining    <= '0;
      credit       <= DDR_CREDIT_MAX;
      read_req_valid    <= 1'b0;
      read_req_addr     <= '0;
      read_data_ready   <= 1'b0;
      edge_stream_out_valid <= 1'b0;
      edge_stream_out    <= '0;
      edge_write_ready   <= 1'b0;
      write_req_valid    <= 1'b0;
      write_req_addr     <= '0;
      write_data_out     <= '0;
    end else begin
      credit <= credit - credit_consume;

      read_req_valid       <= 1'b0;
      read_data_ready      <= 1'b0;
      edge_stream_out_valid<= 1'b0;
      edge_write_ready     <= 1'b0;
      write_req_valid      <= 1'b0;

      unique case (state)
        S_IDLE: begin
          if (stream_v && stream_length > 0) begin
            addr_reg  <= stream_addr;
            remaining <= stream_length;
            read_req_addr  <= stream_addr;
            read_req_valid <= 1'b1;
            state <= S_READ_REQ;
          end else if (stream_s && stream_length > 0) begin
            addr_reg  <= stream_addr;
            remaining <= stream_length;
            write_req_addr <= stream_addr;
            state <= S_WRITE;
          end
        end

        S_READ_REQ: begin
          read_req_valid <= 1'b1;
          read_req_addr  <= addr_reg;
          if (read_req_ready) begin
            read_req_valid <= 1'b0;
            state <= S_READ_WAIT;
          end
        end

        S_READ_WAIT: begin
          read_data_ready <= 1'b1;          // accept a returned line
          if (read_data_valid) begin
            edge_stream_out        <= read_data_in;   // forward to broadcast
            edge_stream_out_valid <= 1'b1;
            if (edge_stream_out_ready) begin
              if (remaining <= 1) begin
                state <= S_IDLE;
              end else begin
                addr_reg  <= addr_reg + DDR_CACHE_LINE;
                remaining <= remaining - 1;
                read_req_addr  <= addr_reg + DDR_CACHE_LINE;
                read_req_valid <= 1'b1;
                state <= S_READ_REQ;
              end
            end
          end
        end

        S_WRITE: begin
          edge_write_ready <= 1'b1;
          if (edge_write_valid) begin
            write_req_valid <= 1'b1;
            write_req_addr  <= addr_reg;
            write_data_out  <= edge_write_data;
            if (write_req_ready) begin
              if (remaining <= 1) begin
                state <= S_IDLE;
              end else begin
                addr_reg   <= addr_reg + DDR_CACHE_LINE;
                remaining  <= remaining - 1;
              end
            end
          end
        end
      endcase
    end
  end

  assign credit_available = credit;

endmodule