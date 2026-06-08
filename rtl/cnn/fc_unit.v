`timescale 1ns/1ps
`default_nettype none

module fc_unit (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    output reg                          busy,
    output reg                          done,
    input  wire signed [(256*8)-1:0]    input_vec,
    input  wire signed [(10*256*8)-1:0] fc_weight,
    input  wire signed [(10*32)-1:0]    fc_bias,
    input  wire signed [(10*32)-1:0]    fc_multiplier,
    input  wire        [(10*8)-1:0]     fc_shift,
    input  wire signed [31:0]           output_zero_point,
    input  wire signed [31:0]           activation_min,
    input  wire signed [31:0]           activation_max,
    output reg  signed [(10*8)-1:0]     logits
);
    localparam ST_IDLE = 2'd0;
    localparam ST_RUN = 2'd1;
    localparam ST_DONE = 2'd2;

    reg [1:0] state;
    reg [3:0] class_idx;

    /* verilator lint_off BLKSEQ */
    function signed [63:0] round_shift_s64;
        input signed [63:0] value;
        input        [5:0]  shift_amount;
        reg signed [63:0] abs_value;
        reg signed [63:0] rounded_abs;
        reg signed [63:0] offset;
        begin
            if (shift_amount == 6'd0) begin
                round_shift_s64 = value;
            end else begin
                offset = 64'sd1 <<< (shift_amount - 6'd1);
                if (value >= 64'sd0) begin
                    round_shift_s64 = (value + offset) >>> shift_amount;
                end else begin
                    abs_value = -value;
                    rounded_abs = (abs_value + offset) >>> shift_amount;
                    round_shift_s64 = -rounded_abs;
                end
            end
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    /* verilator lint_off BLKSEQ */
    function signed [31:0] fc_acc;
        input integer co;
        integer ci;
        integer input_bit_base;
        integer weight_bit_base;
        reg signed [7:0] act_value;
        reg signed [7:0] weight_value;
        reg signed [15:0] product;
        begin
            fc_acc = 32'sd0;
            for (ci = 0; ci < 256; ci = ci + 1) begin
                input_bit_base = ci * 8;
                weight_bit_base = ((co * 256 + ci) * 8);
                act_value = input_vec[input_bit_base +: 8];
                weight_value = fc_weight[weight_bit_base +: 8];
                product = act_value * weight_value;
                fc_acc = fc_acc + {{16{product[15]}}, product};
            end
        end
    endfunction

    function signed [7:0] requant_fc;
        input signed [31:0] acc;
        input integer co;
        reg signed [63:0] x;
        reg signed [63:0] product;
        reg signed [31:0] bias;
        reg signed [31:0] multiplier;
        reg [5:0] shift_amount;
        reg signed [63:0] act_min_ext;
        reg signed [63:0] act_max_ext;
        begin
            bias = fc_bias[(co*32) +: 32];
            multiplier = fc_multiplier[(co*32) +: 32];
            shift_amount = fc_shift[(co*8) +: 8];
            x = {{32{acc[31]}}, acc} + {{32{bias[31]}}, bias};
            product = x * {{32{multiplier[31]}}, multiplier};
            x = round_shift_s64(product, 6'd31);
            x = x >>> shift_amount;
            x = x + {{32{output_zero_point[31]}}, output_zero_point};
            if (x > 64'sd127) begin
                x = 64'sd127;
            end else if (x < -64'sd128) begin
                x = -64'sd128;
            end
            act_min_ext = {{32{activation_min[31]}}, activation_min};
            act_max_ext = {{32{activation_max[31]}}, activation_max};
            if (x < act_min_ext) begin
                x = act_min_ext;
            end else if (x > act_max_ext) begin
                x = act_max_ext;
            end
            requant_fc = x[7:0];
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            class_idx <= 4'd0;
            logits <= 80'sd0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        class_idx <= 4'd0;
                        state <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    logits[(class_idx*8) +: 8] <= requant_fc(fc_acc(class_idx), class_idx);
                    if (class_idx == 4'd9) begin
                        state <= ST_DONE;
                    end else begin
                        class_idx <= class_idx + 4'd1;
                    end
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
