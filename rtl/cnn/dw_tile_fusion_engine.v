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

    output reg  [DW_LANES-1:0]               buf_wr_en_vec,
    output reg  [5:0]                        buf_wr_pixel_idx,
    output reg  [6:0]                        buf_wr_channel_base,
    output reg  signed [(DW_LANES*8)-1:0]    buf_wr_data_vec
);
    localparam ST_IDLE = 3'd0;
    localparam ST_LOAD_INPUT = 3'd1;
    localparam ST_ACC_INIT = 3'd2;
    localparam ST_ACCUM = 3'd3;
    localparam ST_WRITE = 3'd4;
    localparam ST_DONE = 3'd5;
    localparam INPUT_COUNT = MAX_IN_H * MAX_IN_W * MAX_CIN;
    localparam INPUT_BITS = INPUT_COUNT * 8;

    reg [2:0] state;
    reg [15:0] load_idx;
    reg [INPUT_BITS-1:0] input_shift_reg;
    (* ram_style = "distributed" *) reg signed [7:0] input_mem [0:INPUT_COUNT-1];
    reg [5:0] pixel_idx;
    reg [7:0] channel_idx;
    reg [3:0] kernel_idx;
    reg signed [31:0] acc_reg;
    reg signed [31:0] acc_latched;
    wire [13:0] out_pixels;

    integer write_lane;

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

    /* verilator lint_off BLKSEQ */
    function signed [7:0] input_at_current;
        integer oh;
        integer ow;
        integer kh;
        integer kw;
        integer iy;
        integer ix;
        integer input_addr;
        begin
            oh = 0;
            ow = 0;
            if (out_w != 4'd0) begin
                oh = pixel_idx / out_w;
                ow = pixel_idx % out_w;
            end
            kh = kernel_idx / 3;
            kw = kernel_idx % 3;
            iy = (oh * stride) + kh;
            ix = (ow * stride) + kw;
            if (iy < MAX_IN_H && ix < MAX_IN_W && channel_idx < channels) begin
                input_addr = (iy * MAX_IN_W * MAX_CIN) + (ix * MAX_CIN) + channel_idx;
                input_at_current = input_mem[input_addr];
            end else begin
                input_at_current = input_zero_point;
            end
        end
    endfunction

    function signed [7:0] weight_at_current;
        integer weight_bit_base;
        begin
            if (channel_idx < channels) begin
                weight_bit_base = ((channel_idx * 9) + kernel_idx) * 8;
                weight_at_current = dw_weight[weight_bit_base +: 8];
            end else begin
                weight_at_current = 8'sd0;
            end
        end
    endfunction

    function signed [31:0] current_product;
        reg signed [7:0] a;
        reg signed [7:0] w;
        reg signed [15:0] p;
        begin
            a = input_at_current();
            w = weight_at_current();
            p = a * w;
            current_product = {{16{p[15]}}, p};
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            load_idx <= 16'd0;
`ifndef SYNTHESIS
            input_shift_reg <= {INPUT_BITS{1'b0}};
`endif
            pixel_idx <= 6'd0;
            channel_idx <= 8'd0;
            kernel_idx <= 4'd0;
            acc_reg <= 32'sd0;
            acc_latched <= 32'sd0;
            buf_wr_en_vec <= {DW_LANES{1'b0}};
            buf_wr_pixel_idx <= 6'd0;
            buf_wr_channel_base <= 7'd0;
            buf_wr_data_vec <= {(DW_LANES*8){1'b0}};
        end else begin
            done <= 1'b0;
            buf_wr_en_vec <= {DW_LANES{1'b0}};
            buf_wr_data_vec <= {(DW_LANES*8){1'b0}};

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        load_idx <= 16'd0;
                        input_shift_reg <= input_tile;
                        pixel_idx <= 6'd0;
                        channel_idx <= 8'd0;
                        state <= ST_LOAD_INPUT;
                    end
                end

                ST_LOAD_INPUT: begin
                    input_mem[load_idx] <= input_shift_reg[7:0];
                    input_shift_reg <= {{8{1'b0}}, input_shift_reg[INPUT_BITS-1:8]};
                    if (load_idx == (INPUT_COUNT - 1)) begin
                        state <= ST_ACC_INIT;
                    end else begin
                        load_idx <= load_idx + 16'd1;
                    end
                end

                ST_ACC_INIT: begin
                    acc_reg <= 32'sd0;
                    kernel_idx <= 4'd0;
                    state <= ST_ACCUM;
                end

                ST_ACCUM: begin
                    acc_reg <= acc_reg + current_product();
                    if (kernel_idx == 4'd8) begin
                        acc_latched <= acc_reg + current_product();
                        state <= ST_WRITE;
                    end else begin
                        kernel_idx <= kernel_idx + 4'd1;
                    end
                end

                ST_WRITE: begin
                    buf_wr_pixel_idx <= pixel_idx;
                    buf_wr_channel_base <= channel_idx[6:0];
                    /* verilator lint_off BLKSEQ */
                    for (write_lane = 0; write_lane < DW_LANES; write_lane = write_lane + 1) begin
                        if (write_lane == 0 && channel_idx < channels) begin
                            buf_wr_en_vec[write_lane] <= 1'b1;
                            buf_wr_data_vec[(write_lane*8) +: 8] <= requant_dw(acc_latched, channel_idx);
                        end
                    end
                    /* verilator lint_on BLKSEQ */

                    if ((channel_idx + 8'd1) >= channels) begin
                        channel_idx <= 8'd0;
                        if (({8'd0, pixel_idx} + 14'd1) >= out_pixels) begin
                            state <= ST_DONE;
                        end else begin
                            pixel_idx <= pixel_idx + 6'd1;
                            state <= ST_ACC_INIT;
                        end
                    end else begin
                        channel_idx <= channel_idx + 8'd1;
                        state <= ST_ACC_INIT;
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
