import gptpu_pkg::*;

module async_handshake #(
  parameter int DATA_WIDTH = 64
) (
  // Sender interface
  input  logic [DATA_WIDTH-1:0] s_data,
  input  logic                  s_valid,
  output logic                  s_ready,

  // Receiver interface
  output logic [DATA_WIDTH-1:0] m_data,
  output logic                  m_valid,
  input  logic                  m_ready,

  // Sender clock domain
  input  logic                  clk_src,
  input  logic                  rst_n_src,

  // Receiver clock domain
  input  logic                  clk_dst,
  input  logic                  rst_n_dst
);

  // --- 2-stage synchronizer for valid ---
  logic sync_valid_meta, sync_valid_dst;
  logic valid_dst;

  always_ff @(posedge clk_dst or negedge rst_n_dst) begin
    if (!rst_n_dst) begin
      sync_valid_meta <= 1'b0;
      sync_valid_dst  <= 1'b0;
    end else begin
      sync_valid_meta <= s_valid;
      sync_valid_dst  <= sync_valid_meta;
    end
  end

  assign valid_dst = sync_valid_dst;

  // --- Data sampling on destination clock ---
  logic [DATA_WIDTH-1:0] data_sampled;

  always_ff @(posedge clk_dst or negedge rst_n_dst) begin
    if (!rst_n_dst)
      data_sampled <= '0;
    else if (valid_dst && m_ready)
      data_sampled <= s_data;
  end

  assign m_data  = data_sampled;
  assign m_valid = valid_dst;

  // --- Ready synchronization back to source ---
  logic sync_ready_meta, sync_ready_src;

  always_ff @(posedge clk_src or negedge rst_n_src) begin
    if (!rst_n_src) begin
      sync_ready_meta <= 1'b0;
      sync_ready_src  <= 1'b0;
    end else begin
      sync_ready_meta <= m_ready;
      sync_ready_src  <= sync_ready_meta;
    end
  end

  assign s_ready = sync_ready_src;

endmodule
