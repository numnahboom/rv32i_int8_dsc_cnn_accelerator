`timescale 1ns/1ps
`default_nettype none

module ds_block_tile_engine #(
    parameter MAX_CIN = 128,
    parameter MAX_COUT = 256,
    parameter MAX_IN_H = 17,
    parameter MAX_IN_W = 17
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              start,
    output reg                               busy,
    output reg                               done,

    input  wire [3:0]                        out_h,
    input  wire [3:0]                        out_w,
    input  wire [7:0]                        channels,
    input  wire [15:0]                       out_channels,
    input  wire [1:0]                        stride,
    input  wire signed [7:0]                 input_zero_point,
    input  wire signed [(MAX_IN_H*MAX_IN_W*MAX_CIN*8)-1:0] input_tile,

    input  wire signed [(MAX_CIN*9*8)-1:0]   dw_weight,
    input  wire signed [(MAX_CIN*32)-1:0]    dw_bias,
    input  wire signed [(MAX_CIN*32)-1:0]    dw_multiplier,
    input  wire        [(MAX_CIN*8)-1:0]     dw_shift,
    input  wire signed [31:0]                dw_output_zero_point,
    input  wire signed [31:0]                dw_activation_min,
    input  wire signed [31:0]                dw_activation_max,

    input  wire signed [(MAX_COUT*MAX_CIN*8)-1:0] pw_weight,
    input  wire signed [(MAX_COUT*32)-1:0]        pw_bias,
    input  wire signed [(MAX_COUT*32)-1:0]        pw_multiplier,
    input  wire        [(MAX_COUT*8)-1:0]         pw_shift,
    input  wire signed [31:0]                     pw_output_zero_point,
    input  wire signed [31:0]                     pw_activation_min,
    input  wire signed [31:0]                     pw_activation_max,

    output reg                               out_wr_en,
    output reg  [5:0]                        out_wr_pixel_idx,
    output reg  [7:0]                        out_wr_channel_idx,
    output reg  signed [7:0]                 out_wr_data_int8
);
    localparam ST_IDLE = 4'd0;
    localparam ST_DW_START = 4'd1;
    localparam ST_DW_WAIT = 4'd2;
    localparam ST_PW_READ = 4'd3;
    localparam ST_PW_READ_WAIT = 4'd4;
    localparam ST_PW_FEED = 4'd5;
    localparam ST_PW_WAIT = 4'd6;
    localparam ST_WRITE = 4'd7;
    localparam ST_DONE = 4'd8;
    localparam DW_LANES = 16;

    reg [3:0] state;
    reg dw_start;
    wire dw_busy;
    wire dw_done;
    wire [DW_LANES-1:0] dw_buf_wr_en_vec;
    wire [5:0] dw_buf_wr_pixel_idx;
    wire [6:0] dw_buf_wr_channel_base;
    wire signed [(DW_LANES*8)-1:0] dw_buf_wr_data_vec;

    reg buf_rd_en;
    reg [5:0] buf_rd_pixel_base;
    reg [6:0] buf_rd_channel_idx;
    wire signed [63:0] buf_rd_data_vector;

    reg pw_valid_in;
    wire pw_ready_in;
    reg pw_clear_acc;
    reg pw_k_last;
    reg signed [63:0] pw_act_vec;
    reg signed [63:0] pw_wgt_vec;
    wire pw_valid_out;
    wire signed [2047:0] pw_psum_out;

    reg [5:0] pixel_base;
    reg [8:0] cout_base;
    reg [7:0] k_idx;
    reg signed [63:0] wgt_vec_latched;
    reg signed [2047:0] psum_latched;
    reg [3:0] write_pixel_lane;
    reg [3:0] write_cout_lane;

    wire [13:0] out_pixels;
    integer lane;
    integer bit_base;
    integer channel;

    assign out_pixels = out_h * out_w;

    dw_tile_fusion_engine #(
        .MAX_CIN(MAX_CIN),
        .MAX_IN_H(MAX_IN_H),
        .MAX_IN_W(MAX_IN_W),
        .DW_LANES(DW_LANES)
    ) u_dw_engine (
        .clk(clk),
        .rst_n(rst_n),
        .start(dw_start),
        .busy(dw_busy),
        .done(dw_done),
        .out_h(out_h),
        .out_w(out_w),
        .channels(channels),
        .stride(stride),
        .input_zero_point(input_zero_point),
        .input_tile(input_tile),
        .dw_weight(dw_weight),
        .dw_bias(dw_bias),
        .dw_multiplier(dw_multiplier),
        .dw_shift(dw_shift),
        .dw_output_zero_point(dw_output_zero_point),
        .activation_min(dw_activation_min),
        .activation_max(dw_activation_max),
        .buf_wr_en_vec(dw_buf_wr_en_vec),
        .buf_wr_pixel_idx(dw_buf_wr_pixel_idx),
        .buf_wr_channel_base(dw_buf_wr_channel_base),
        .buf_wr_data_vec(dw_buf_wr_data_vec)
    );

    dw_tile_buffer #(
        .WRITE_LANES(DW_LANES)
    ) u_dw_tile_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en_vec(dw_buf_wr_en_vec),
        .wr_pixel_idx(dw_buf_wr_pixel_idx),
        .wr_channel_base(dw_buf_wr_channel_base),
        .wr_data_vec(dw_buf_wr_data_vec),
        .rd_en(buf_rd_en),
        .rd_pixel_base(buf_rd_pixel_base),
        .rd_channel_idx(buf_rd_channel_idx),
        .rd_data_vector(buf_rd_data_vector)
    );

    pw_systolic_array_8x8 u_pw_array (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(pw_valid_in),
        .ready_in(pw_ready_in),
        .clear_acc(pw_clear_acc),
        .k_last(pw_k_last),
        .act_vec(pw_act_vec),
        .wgt_vec(pw_wgt_vec),
        .ready_out(1'b1),
        .valid_out(pw_valid_out),
        .psum_out(pw_psum_out)
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
    function signed [7:0] requant_pw;
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
            bias = pw_bias[(co*32) +: 32];
            multiplier = pw_multiplier[(co*32) +: 32];
            shift_amount = pw_shift[(co*8) +: 8];
            x = {{32{acc[31]}}, acc} + {{32{bias[31]}}, bias};
            product = x * {{32{multiplier[31]}}, multiplier};
            x = round_shift_s64(product, 6'd31);
            x = x >>> shift_amount;
            x = x + {{32{pw_output_zero_point[31]}}, pw_output_zero_point};

            if (x > 64'sd127) begin
                x = 64'sd127;
            end else if (x < -64'sd128) begin
                x = -64'sd128;
            end

            act_min_ext = {{32{pw_activation_min[31]}}, pw_activation_min};
            act_max_ext = {{32{pw_activation_max[31]}}, pw_activation_max};
            if (x < act_min_ext) begin
                x = act_min_ext;
            end else if (x > act_max_ext) begin
                x = act_max_ext;
            end
            requant_pw = x[7:0];
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    always @(*) begin
        wgt_vec_latched = 64'sd0;
        bit_base = 0;
        channel = 0;
        for (lane = 0; lane < 8; lane = lane + 1) begin
            channel = cout_base + lane;
            if (channel < out_channels && k_idx < channels) begin
                bit_base = ((channel * MAX_CIN) + k_idx) * 8;
                wgt_vec_latched[(lane*8) +: 8] = pw_weight[bit_base +: 8];
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            dw_start <= 1'b0;
            buf_rd_en <= 1'b0;
            buf_rd_pixel_base <= 6'd0;
            buf_rd_channel_idx <= 7'd0;
            pw_valid_in <= 1'b0;
            pw_clear_acc <= 1'b0;
            pw_k_last <= 1'b0;
            pw_act_vec <= 64'sd0;
            pw_wgt_vec <= 64'sd0;
            pixel_base <= 6'd0;
            cout_base <= 9'd0;
            k_idx <= 8'd0;
            psum_latched <= 2048'sd0;
            write_pixel_lane <= 4'd0;
            write_cout_lane <= 4'd0;
            out_wr_en <= 1'b0;
            out_wr_pixel_idx <= 6'd0;
            out_wr_channel_idx <= 8'd0;
            out_wr_data_int8 <= 8'sd0;
        end else begin
            done <= 1'b0;
            dw_start <= 1'b0;
            buf_rd_en <= 1'b0;
            pw_valid_in <= 1'b0;
            pw_clear_acc <= 1'b0;
            pw_k_last <= 1'b0;
            out_wr_en <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        pixel_base <= 6'd0;
                        cout_base <= 9'd0;
                        k_idx <= 8'd0;
                        state <= ST_DW_START;
                    end
                end

                ST_DW_START: begin
                    dw_start <= 1'b1;
                    state <= ST_DW_WAIT;
                end

                ST_DW_WAIT: begin
                    if (dw_done) begin
                        pixel_base <= 6'd0;
                        cout_base <= 9'd0;
                        k_idx <= 8'd0;
                        state <= ST_PW_READ;
                    end
                end

                ST_PW_READ: begin
                    buf_rd_en <= 1'b1;
                    buf_rd_pixel_base <= pixel_base;
                    buf_rd_channel_idx <= k_idx[6:0];
                    state <= ST_PW_READ_WAIT;
                end

                ST_PW_READ_WAIT: begin
                    state <= ST_PW_FEED;
                end

                ST_PW_FEED: begin
                    if (pw_ready_in) begin
                        pw_valid_in <= 1'b1;
                        pw_clear_acc <= (k_idx == 8'd0);
                        pw_k_last <= ((k_idx + 8'd1) >= channels);
                        pw_act_vec <= buf_rd_data_vector;
                        pw_wgt_vec <= wgt_vec_latched;

                        if ((k_idx + 8'd1) >= channels) begin
                            state <= ST_PW_WAIT;
                        end else begin
                            k_idx <= k_idx + 8'd1;
                            state <= ST_PW_READ;
                        end
                    end
                end

                ST_PW_WAIT: begin
                    if (pw_valid_out) begin
                        psum_latched <= pw_psum_out;
                        write_pixel_lane <= 4'd0;
                        write_cout_lane <= 4'd0;
                        state <= ST_WRITE;
                    end
                end

                ST_WRITE: begin
                    if (({8'd0, pixel_base} + {10'd0, write_pixel_lane}) < out_pixels &&
                        (cout_base + write_cout_lane) < out_channels) begin
                        out_wr_en <= 1'b1;
                        out_wr_pixel_idx <= pixel_base + {2'b00, write_pixel_lane};
                        out_wr_channel_idx <= cout_base[7:0] + {4'b0000, write_cout_lane};
                        out_wr_data_int8 <= requant_pw(
                            psum_latched[((write_pixel_lane*8 + write_cout_lane)*32) +: 32],
                            cout_base + write_cout_lane
                        );
                    end

                    if (write_cout_lane == 4'd7) begin
                        write_cout_lane <= 4'd0;
                        if (write_pixel_lane == 4'd7) begin
                            write_pixel_lane <= 4'd0;
                            k_idx <= 8'd0;
                            if ((cout_base + 9'd8) < out_channels) begin
                                cout_base <= cout_base + 9'd8;
                                state <= ST_PW_READ;
                            end else begin
                                cout_base <= 9'd0;
                                if (({8'd0, pixel_base} + 14'd8) < out_pixels) begin
                                    pixel_base <= pixel_base + 6'd8;
                                    state <= ST_PW_READ;
                                end else begin
                                    state <= ST_DONE;
                                end
                            end
                        end else begin
                            write_pixel_lane <= write_pixel_lane + 4'd1;
                        end
                    end else begin
                        write_cout_lane <= write_cout_lane + 4'd1;
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
