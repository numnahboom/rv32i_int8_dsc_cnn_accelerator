module requant_activation_unit (
    input  wire clk,
    input  wire rst_n,

    input  wire valid_in,
    output wire  ready_in,

    input  wire signed [31:0] acc_int32,
    input  wire signed [31:0] bias_int32,
    input  wire signed [31:0] multiplier_int32,
    input  wire [5:0] shift,

    input  wire signed [31:0] output_zero_point_int32,
    input  wire signed [31:0] activation_min_int32,
    input  wire signed [31:0] activation_max_int32,

    input  wire ready_out,
    output reg  valid_out,
    output reg signed [7:0] output_int8
);

    reg valid_s1;
    reg valid_s2;

    wire ready_s1;
    wire ready_s2;
    wire ready_s3;

    assign ready_s1 = !valid_s1 || ready_s2;
    assign ready_s2 = !valid_s2 || ready_s3;
    assign ready_s3 = !valid_out || ready_out;
    assign ready_in = ready_s1;

    reg signed [63:0] product_s1;
    reg [5:0] shift_s1;

    reg signed [31:0] output_zero_point_s1;
    reg signed [31:0] activation_min_s1;
    reg signed [31:0] activation_max_s1;

    reg signed [63:0] shifted_s2;

    reg signed [31:0] output_zero_point_s2;
    reg signed [31:0] activation_min_s2;
    reg signed [31:0] activation_max_s2;

    wire signed [63:0] acc_ext;
    wire signed [63:0] bias_ext;
    wire signed [63:0] multiplier_ext;
    wire signed [63:0] acc_bias_w;
    wire signed [63:0] product_w;

    assign acc_ext        = {{32{acc_int32[31]}}, acc_int32};
    assign bias_ext       = {{32{bias_int32[31]}}, bias_int32};
    assign multiplier_ext = {{32{multiplier_int32[31]}}, multiplier_int32};

    assign acc_bias_w = acc_ext + bias_ext;
    assign product_w  = acc_bias_w * multiplier_ext;

    function signed [63:0] round_shift_s64;
        input signed [63:0] x;
        input [5:0] sh;

        reg signed [63:0] abs_x;
        reg signed [63:0] rounded_abs;
        reg signed [63:0] offset;

        begin
            if (sh == 6'd0) begin
                round_shift_s64 = x;
            end else begin
                offset = 64'sd1 <<< (sh - 1);

                if (x >= 0) begin
                    round_shift_s64 = (x + offset) >>> sh;
                end else begin
                    abs_x = -x;
                    rounded_abs = (abs_x + offset) >>> sh;
                    round_shift_s64 = -rounded_abs;
                end
            end
        end
    endfunction

    function signed [7:0] clamp_to_int8;
        input signed [63:0] x;
        input signed [31:0] act_min;
        input signed [31:0] act_max;

        reg signed [63:0] act_min_ext;
        reg signed [63:0] act_max_ext;
        reg signed [63:0] y;

        begin
            act_min_ext = {{32{act_min[31]}}, act_min};
            act_max_ext = {{32{act_max[31]}}, act_max};

            if (x < act_min_ext)
                y = act_min_ext;
            else if (x > act_max_ext)
                y = act_max_ext;
            else
                y = x;

            if (y > 64'sd127)
                clamp_to_int8 = 8'sd127;
            else if (y < -64'sd128)
                clamp_to_int8 = -8'sd128;
            else
                clamp_to_int8 = y[7:0];
        end
    endfunction

    wire signed [63:0] shifted_w;
    wire signed [63:0] scaled_w;

    assign shifted_w = round_shift_s64(product_s1, shift_s1);
    assign scaled_w  = shifted_s2 + {{32{output_zero_point_s2[31]}}, output_zero_point_s2};

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_s1 <= 1'b0;
            valid_s2 <= 1'b0;
            valid_out <= 1'b0;

            product_s1 <= 64'sd0;
            shift_s1 <= 6'd0;

            output_zero_point_s1 <= 32'sd0;
            activation_min_s1 <= 32'sd0;
            activation_max_s1 <= 32'sd0;

            shifted_s2 <= 64'sd0;

            output_zero_point_s2 <= 32'sd0;
            activation_min_s2 <= 32'sd0;
            activation_max_s2 <= 32'sd0;

            output_int8 <= 8'sd0;
        end else begin

            // stage 1: acc + bias, multiply
            if (ready_s1) begin
                valid_s1 <= valid_in;

                if (valid_in) begin
                    product_s1 <= product_w;
                    shift_s1 <= shift;

                    output_zero_point_s1 <= output_zero_point_int32;
                    activation_min_s1 <= activation_min_int32;
                    activation_max_s1 <= activation_max_int32;
                end
            end

            // stage 2: round and shift
            if (ready_s2) begin
                valid_s2 <= valid_s1;

                if (valid_s1) begin
                    shifted_s2 <= shifted_w;

                    output_zero_point_s2 <= output_zero_point_s1;
                    activation_min_s2 <= activation_min_s1;
                    activation_max_s2 <= activation_max_s1;
                end
            end

            // stage 3: zero point, clamp, int8
            if (ready_s3) begin
                valid_out <= valid_s2;

                if (valid_s2) begin
                    output_int8 <= clamp_to_int8(
                        scaled_w,
                        activation_min_s2,
                        activation_max_s2
                    );
                end
            end
        end
    end

endmodule