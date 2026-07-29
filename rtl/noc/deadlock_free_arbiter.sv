import gptpu_pkg::*;

module deadlock_free_arbiter (
  input  logic [7:0] req,        // 8 requestors
  input  logic [3:0] priority,   // round-robin priority
  output logic [2:0] grant,
  output logic       any_grant
);

  logic [7:0] priority_mask;
  logic [7:0] masked_req;
  logic [7:0] grant_onehot;

  // Priority mask: requests below priority are masked out
  always_comb begin
    priority_mask = '1;
    for (int i = 0; i < 8; i++) begin
      if (i < priority) priority_mask[i] = 1'b0;
    end
  end

  assign masked_req = req & priority_mask;

  // Priority encoder on masked requests; fallback to unmasked
  always_comb begin
    if (|masked_req) begin
      for (int i = 7; i >= 0; i--) begin
        if (masked_req[i]) begin
          grant_onehot = 8'b1 << i;
        end
      end
    end else begin
      for (int i = 7; i >= 0; i--) begin
        if (req[i]) begin
          grant_onehot = 8'b1 << i;
        end
      end
    end
  end

  assign any_grant = |req;

  always_comb begin
    unique case (grant_onehot)
      8'b00000001: grant = 3'd0;
      8'b00000010: grant = 3'd1;
      8'b00000100: grant = 3'd2;
      8'b00001000: grant = 3'd3;
      8'b00010000: grant = 3'd4;
      8'b00100000: grant = 3'd5;
      8'b01000000: grant = 3'd6;
      8'b10000000: grant = 3'd7;
      default:     grant = 3'd0;
    endcase
  end

endmodule
