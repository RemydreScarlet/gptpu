import gptpu_pkg::*;

// Parameterized round-robin arbiter (WIDTH inputs). The priority pointer is
// bumped after every grant, giving a rotating fairness that is deadlock-free
// (a request always remains granted until acknowledged, and the pointer
// rotates so no input can starve). Default WIDTH=8 preserves the original
// L0 mesh behavior; router_l0 instantiates WIDTH=9 to fold the local inject
// port into the same crossbar.
module deadlock_free_arbiter #(
  parameter int WIDTH = 8
) (
  input  logic [WIDTH-1:0]                req,
  input  logic [$clog2(WIDTH)-1:0]        prio,
  output logic [$clog2(WIDTH)-1:0]        grant,
  output logic                            any_grant,
  output logic [$clog2(WIDTH)-1:0]        prio_next
);

  logic [WIDTH-1:0] priority_mask;
  logic [WIDTH-1:0] masked_req;
  logic [WIDTH-1:0] grant_onehot;

  always_comb begin
    priority_mask = '1;
    for (int i = 0; i < WIDTH; i++) begin
      if (i < prio) priority_mask[i] = 1'b0;
    end
  end

  assign masked_req = req & priority_mask;

  always_comb begin
    grant_onehot = '0;
    if (|masked_req) begin
      for (int i = WIDTH-1; i >= 0; i--) begin
        if (masked_req[i]) begin
          grant_onehot = 1'b1 << i;
        end
      end
    end else if (|req) begin
      for (int i = WIDTH-1; i >= 0; i--) begin
        if (req[i]) begin
          grant_onehot = 1'b1 << i;
        end
      end
    end
  end

  assign any_grant = |req;

  always_comb begin
    grant = '0;
    for (int i = 0; i < WIDTH; i++) begin
      if (grant_onehot[i]) grant = i[$clog2(WIDTH)-1:0];
    end
  end

  assign prio_next = any_grant ? (grant + 1) : prio;

endmodule