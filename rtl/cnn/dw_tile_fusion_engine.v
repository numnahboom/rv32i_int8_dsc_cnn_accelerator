`timescale 1ns/1ps
`default_nettype none

module dw_tile_fusion_engine #(
    parameter MAX_CIN = 128,
    parameter MAX_IN_H = 17,
    parameter MAX_IN_W = 17,
    parameter DW_LANES = 16
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              start,
    output reg                               busy,
    output reg                               done,

    input  wire [3:0]                        out_h,
    input  wire [3:0]                        out_w,
    input  wire [7:0]                        channels,
    input  wire [1:0]                        stride,
    input  wire signed [7:0]                 input_zero_point,
    input  wire signed [(MAX_IN_H*MAX_IN_W*MAX_CIN*8)-1:0] input_tile,
    input  wire signed [(MAX_CIN*9*8)-1:0]   dw_weight,
    input  wire signed [(MAX_CIN*32)-1:0]    dw_bias,
    input  wire signed [(MAX_CIN*32)-1:0]    dw_multiplier,
    input  wire        [(MAX_CIN*8)-1:0]     dw_shift,
    input  wire signed [31:0]                dw_output_zero_point,
    input  wire signed [31:0]                activation_min,
    input  wire signed [31:0]                activation_max,

    output reg                               buf_wr_en,
    output reg  [5:0]                        buf_wr_pixel_idx,
    output reg  [6:0]                        buf_wr_channel_idx,
    output reg  signed [7:0]                 buf_wr_data_int8
);
    localparam ST_IDLE = 3'd0;
    localparam ST_MAC_START = 3'd1;
    localparam ST_MAC_WAIT = 3'd2;
    localparam ST_WRITE = 3'd3;
    localparam ST_DONE = 3'd4;

    reg [2:0] state;
    reg [5:0] pixel_idx;
    reg [7:0] ch_base;
    reg [4:0] write_lane;
    reg mac_start;
    reg [DW_LANES-1:0] lane_active;
    reg signed [(DW_LANES*9*8)-1:0] mac_window_vec;
    reg signed [(DW_LANES*9*8)-1:0] mac_weight_vec;
    reg signed [(DW_LANES*32)-1:0] mac_acc_latched;

    wire mac_busy;
    wire mac_valid;
    wire signed [(DW_LANES*32)-1:0] mac_acc_vec;
    wire [13:0] out_pixels;

    integer lane;
    integer kh;
    integer kw;
    integer oh;
    integer ow;
    integer iy;
    integer ix;
    integer channel_idx;
    integer input_bit_base;
    integer weight_bit_base;

    assign out_pixels = out_h * out_w;

    dw_mac_lanes #(
        .LANES(DW_LANES)
    ) u_mac_lanes (
        .clk(clk),
        .rst_n(rst_n),
        .start(mac_start),
        .lane_active(lane_active),
        .window_vec(mac_window_vec),
        .weight_vec(mac_weight_vec),
        .busy(mac_busy),
        .valid_out(mac_valid),
        .acc_vec(mac_acc_vec)
    );

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
    function signed [7:0] requant_dw;
        input signed [31:0] acc;
        input integer channel;
        reg signed [63:0] x;
        reg signed [63:0] product;
        reg signed [31:0] bias;
        reg signed [31:0] multiplier;
        reg [5:0] shift_amount;
        reg signed [63:0] act_min_ext;
        reg signed [63:0] act_max_ext;
        begin
            bias = dw_bias[(channel*32) +: 32];
            multiplier = dw_multiplier[(channel*32) +: 32];
            shift_amount = dw_shift[(channel*8) +: 8];
            x = {{32{acc[31]}}, acc} + {{32{bias[31]}}, bias};
            product = x * {{32{multiplier[31]}}, multiplier};
            x = round_shift_s64(product, 6'd31);
            x = x >>> shift_amount;
            x = x + {{32{dw_output_zero_point[31]}}, dw_output_zero_point};

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
            requant_dw = x[7:0];
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    always @(*) begin
        lane_active = {DW_LANES{1'b0}};
        mac_window_vec = {(DW_LANES*9*8){1'b0}};
        mac_weight_vec = {(DW_LANES*9*8){1'b0}};
        oh = 0;
        ow = 0;
        iy = 0;
        ix = 0;
        input_bit_base = 0;
        weight_bit_base = 0;
        if (out_w != 4'd0) begin
            oh = pixel_idx / out_w;
            ow = pixel_idx % out_w;
        end

        for (lane = 0; lane < DW_LANES; lane = lane + 1) begin
            channel_idx = ch_base + lane;
            if (channel_idx < channels) begin
                lane_active[lane] = 1'b1;
                for (kh = 0; kh < 3; kh = kh + 1) begin
                    for (kw = 0; kw < 3; kw = kw + 1) begin
                        iy = oh * stride + kh;
                        ix = ow * stride + kw;
                        if (iy < MAX_IN_H && ix < MAX_IN_W) begin
                            input_bit_base = ((iy * MAX_IN_W * MAX_CIN) + (ix * MAX_CIN) + channel_idx) * 8;
                            mac_window_vec[((lane*9 + kh*3 + kw)*8) +: 8] =
                                input_tile[input_bit_base +: 8];
                        end else begin
                            mac_window_vec[((lane*9 + kh*3 + kw)*8) +: 8] =
                                input_zero_point;
                        end
                        weight_bit_base = ((channel_idx * 9) + (kh * 3) + kw) * 8;
                        mac_weight_vec[((lane*9 + kh*3 + kw)*8) +: 8] =
                            dw_weight[weight_bit_base +: 8];
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            pixel_idx <= 6'd0;
            ch_base <= 8'd0;
            write_lane <= 5'd0;
            mac_start <= 1'b0;
            mac_acc_latched <= {(DW_LANES*32){1'b0}};
            buf_wr_en <= 1'b0;
            buf_wr_pixel_idx <= 6'd0;
            buf_wr_channel_idx <= 7'd0;
            buf_wr_data_int8 <= 8'sd0;
        end else begin
            done <= 1'b0;
            mac_start <= 1'b0;
            buf_wr_en <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        pixel_idx <= 6'd0;
                        ch_base <= 8'd0;
                        write_lane <= 5'd0;
                        state <= ST_MAC_START;
                    end
                end

                ST_MAC_START: begin
                    mac_start <= 1'b1;
                    state <= ST_MAC_WAIT;
                end

                ST_MAC_WAIT: begin
                    if (mac_valid) begin
                        mac_acc_latched <= mac_acc_vec;
                        write_lane <= 5'd0;
                        state <= ST_WRITE;
                    end
                end

                ST_WRITE: begin
                    if ((ch_base + write_lane) < channels && write_lane < DW_LANES) begin
                        buf_wr_en <= 1'b1;
                        buf_wr_pixel_idx <= pixel_idx;
                        buf_wr_channel_idx <= ch_base[6:0] + {2'b00, write_lane};
                        buf_wr_data_int8 <= requant_dw(
                            mac_acc_latched[(write_lane*32) +: 32],
                            ch_base + write_lane
                        );
                    end

                    if ((write_lane == (DW_LANES - 1)) || ((ch_base + write_lane + 1) >= channels)) begin
                        write_lane <= 5'd0;
                        if ((ch_base + DW_LANES) >= channels) begin
                            ch_base <= 8'd0;
                            if (({8'd0, pixel_idx} + 14'd1) >= out_pixels) begin
                                state <= ST_DONE;
                            end else begin
                                pixel_idx <= pixel_idx + 6'd1;
                                state <= ST_MAC_START;
                            end
                        end else begin
                            ch_base <= ch_base + DW_LANES;
                            state <= ST_MAC_START;
                        end
                    end else begin
                        write_lane <= write_lane + 5'd1;
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
