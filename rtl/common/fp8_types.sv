package fp8_pkg;
  import gptpu_pkg::*;

  // FP8 E4M3 arithmetic primitives (referenced by vector_lane and emulator)

  // FP8 addition (E4M3)
  function automatic fp8_e4m3_t fp8_add(input fp8_e4m3_t a, input fp8_e4m3_t b);
    logic [7:0] sign_a, sign_b, sign_r;
    logic [3:0] exp_a, exp_b, exp_r;
    logic [2:0] mant_a, mant_b;
    logic [3:0] mant_a_ext, mant_b_ext;
    logic [4:0] mant_sum;
    logic [3:0] exp_diff;
    logic [7:0] result;

    sign_a = a[7]; exp_a = a[6:3]; mant_a = a[2:0];
    sign_b = b[7]; exp_b = b[6:3]; mant_b = b[2:0];

    if (exp_a == 4'd0) mant_a_ext = {1'b0, mant_a};
    else               mant_a_ext = {1'b1, mant_a};

    if (exp_b == 4'd0) mant_b_ext = {1'b0, mant_b};
    else               mant_b_ext = {1'b1, mant_b};

    if (exp_a == 4'd15) begin
      return {sign_a, 4'd15, 3'b000};  // NaN/Inf
    end

    if (exp_a >= exp_b) begin
      exp_diff = exp_a - exp_b;
      mant_b_ext = mant_b_ext >> exp_diff;
      exp_r = exp_a;
    end else begin
      exp_diff = exp_b - exp_a;
      mant_a_ext = mant_a_ext >> exp_diff;
      exp_r = exp_b;
      sign_a = sign_b;
    end

    if (sign_a == sign_b) begin
      mant_sum = mant_a_ext + mant_b_ext;
      sign_r = sign_a;
    end else begin
      mant_sum = mant_a_ext - mant_b_ext;
      sign_r = sign_a;
    end

    if (mant_sum[4]) begin
      mant_sum = mant_sum >> 1;
      exp_r = exp_r + 1;
    end

    if (exp_r >= 4'd15) begin
      result = {sign_r, 4'd15, 3'b000};
    end else if (mant_sum == 0) begin
      result = {1'b0, 4'd0, 3'b000};
    end else begin
      result = {sign_r, exp_r, mant_sum[2:0]};
    end

    return fp8_e4m3_t'(result);
  endfunction

  // FP8 multiplication (E4M3)
  function automatic fp8_e4m3_t fp8_mul(input fp8_e4m3_t a, input fp8_e4m3_t b);
    logic        sign_r;
    logic [3:0]  exp_r;
    logic [5:0]  mant_prod;
    logic [2:0]  mant_r;

    sign_r = a[7] ^ b[7];

    if (a[6:3] == 4'd0 || b[6:3] == 4'd0) begin
      return fp8_e4m3_t'(8'd0);
    end

    exp_r = a[6:3] + b[6:3] - 4'd7;

    // mantissa: 1.xxx * 1.xxx = 2 bits before decimal
    mant_prod = {1'b1, a[2:0]} * {1'b1, b[2:0]};

    if (mant_prod[5]) begin
      mant_r = mant_prod[4:2];
      exp_r = exp_r + 1;
    end else begin
      mant_r = mant_prod[3:1];
    end

    if (exp_r >= 4'd15) begin
      return {sign_r, 4'd15, 3'b000};
    end else if (exp_r <= 4'd0) begin
      return fp8_e4m3_t'(8'd0);
    end

    return {sign_r, exp_r, mant_r};
  endfunction

  // FP8 subtraction (E4M3): add the negation of b (sign-flip), matching the emulator
  function automatic fp8_e4m3_t fp8_sub(input fp8_e4m3_t a, input fp8_e4m3_t b);
    return fp8_add(a, fp8_mul(b, fp8_e4m3_t'(8'hB8)));
  endfunction

  // FP8 signed less-than (E4M3 sign-magnitude compare)
  // Handles the sign bit correctly: -x < +y regardless of raw bit pattern.
  function automatic logic fp8_lt(input fp8_e4m3_t a, input fp8_e4m3_t b);
    logic [6:0] mag_a, mag_b;
    mag_a = a[6:0];
    mag_b = b[6:0];
    if (mag_a == '0 && mag_b == '0)
      fp8_lt = 1'b0;                       // -0.0 and +0.0 compare equal
    else if (a[7] != b[7])
      fp8_lt = a[7];                       // negative < positive
    else if (a[7] == 1'b1)
      fp8_lt = mag_a > mag_b;              // both negative: larger mag is smaller
    else
      fp8_lt = mag_a < mag_b;              // both positive
  endfunction

  // FP8 signed greater-than
  function automatic logic fp8_gt(input fp8_e4m3_t a, input fp8_e4m3_t b);
    return fp8_lt(b, a);
  endfunction

endpackage