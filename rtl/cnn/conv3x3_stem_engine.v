`timescale 1ns/1ps
`default_nettype none

module conv3x3_stem_engine (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    output reg                          busy,
    output reg                          done,

    input  wire [3:0]                   out_h,
    input  wire [3:0]                   out_w,
    input  wire signed [7:0]            input_zero_point,
    input  wire signed [(10*10*3*8)-1:0] input_tile,
    input  wire signed [(16*27*8)-1:0]  stem_weight,
    input  wire signed [(16*32)-1:0]    stem_bias,
    input  wire signed [(16*32)-1:0]    stem_multiplier,
    input  wire        [(16*8)-1:0]     stem_shift,
    input  wire signed [31:0]           output_zero_point,
    input  wire signed [31:0]           activation_min,
    input  wire signed [31:0]           activation_max,

    output reg                          out_wr_en,
    output reg  [5:0]                   out_wr_pixel_idx,
    output reg  [3:0]                   out_wr_channel_idx,
    output reg  signed [7:0]            out_wr_data_int8
);
    localparam ST_IDLE = 2'd0;
    localparam ST_WRITE = 2'd1;
    localparam ST_DONE = 2'd2;

    reg [1:0] state;
    reg [5:0] pixel_idx;
    reg [4:0] out_channel;
    wire [13:0] out_pixels;

    assign out_pixels = out_h * out_w;

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
    function signed [31:0] conv_acc;
        input integer pixel;
        input integer co;
        integer oh;
        integer ow;
        integer kh;
        integer kw;
        integer ci;
        integer input_bit_base;
        integer weight_bit_base;
        reg signed [7:0] act_value;
        reg signed [7:0] weight_value;
        reg signed [15:0] product;
        begin
            conv_acc = 32'sd0;
            oh = 0;
            ow = 0;
            if (out_w != 4'd0) begin
                oh = pixel / out_w;
                ow = pixel % out_w;
            end
            for (kh = 0; kh < 3; kh = kh + 1) begin
                for (kw = 0; kw < 3; kw = kw + 1) begin
                    for (ci = 0; ci < 3; ci = ci + 1) begin
                        if ((oh + kh) < 10 && (ow + kw) < 10) begin
                            input_bit_base = ((((oh + kh) * 10 * 3) + ((ow + kw) * 3) + ci) * 8);
                            act_value = input_tile[input_bit_base +: 8];
                        end else begin
                            act_value = input_zero_point;
                        end
                        weight_bit_base = (((co * 27) + ((kh * 3 + kw) * 3) + ci) * 8);
                        weight_value = stem_weight[weight_bit_base +: 8];
                        product = act_value * weight_value;
                        conv_acc = conv_acc + {{16{product[15]}}, product};
                    end
                end
            end
        end
    endfunction

    function signed [7:0] requant_stem;
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
            bias = stem_bias[(co*32) +: 32];
            multiplier = stem_multiplier[(co*32) +: 32];
            shift_amount = stem_shift[(co*8) +: 8];
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
            requant_stem = x[7:0];
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            pixel_idx <= 6'd0;
            out_channel <= 5'd0;
            out_wr_en <= 1'b0;
            out_wr_pixel_idx <= 6'd0;
            out_wr_channel_idx <= 4'd0;
            out_wr_data_int8 <= 8'sd0;
        end else begin
            done <= 1'b0;
            out_wr_en <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        pixel_idx <= 6'd0;
                        out_channel <= 5'd0;
                        state <= ST_WRITE;
                    end
                end

                ST_WRITE: begin
                    out_wr_en <= 1'b1;
                    out_wr_pixel_idx <= pixel_idx;
                    out_wr_channel_idx <= out_channel[3:0];
                    out_wr_data_int8 <= requant_stem(conv_acc(pixel_idx, out_channel), out_channel);

                    if (out_channel == 5'd15) begin
                        out_channel <= 5'd0;
                        if (({8'd0, pixel_idx} + 14'd1) >= out_pixels) begin
                            state <= ST_DONE;
                        end else begin
                            pixel_idx <= pixel_idx + 6'd1;
                        end
                    end else begin
                        out_channel <= out_channel + 5'd1;
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
