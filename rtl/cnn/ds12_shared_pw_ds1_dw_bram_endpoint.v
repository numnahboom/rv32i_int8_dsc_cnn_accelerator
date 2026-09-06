`timescale 1ns/1ps
`default_nettype none

// Storage-oriented DS1 DW endpoint used only by the shared M1 adapter.
// Instead of a layer-sized feature_reg that Vivado dissolves into 131072
// flops, this endpoint keeps three rolling source rows and advances the SAME
// window one tap row at a time.  The row store is bounded to 3*32*16 INT8
// values; the pointwise service remains the only 64-MAC block.
module ds12_shared_pw_ds1_dw_bram_endpoint #(
    parameter integer IMAGE_H = 32,
    parameter integer IMAGE_W = 32,
    parameter integer CHANNELS = 16,
    parameter integer CONTEXT_PIXELS = 8,
    parameter integer CONTEXTS = 4,
    parameter integer INPUT_BASE = 0
) (
    input wire clk, input wire rst_n, input wire start, output wire ready,
    input wire cfg_valid, output wire cfg_ready, input wire [31:0] cfg_data,
    input wire cfg_last,
    output wire mem_req_valid, input wire mem_req_ready, output wire mem_req_write,
    output wire [31:0] mem_req_addr, output wire [127:0] mem_req_wdata,
    output wire [15:0] mem_req_strb, output wire [1:0] mem_req_context,
    output wire mem_req_owner, output wire [31:0] mem_req_epoch,
    input wire mem_resp_valid, input wire [127:0] mem_resp_rdata,
    output wire dw_valid, input wire dw_ready, output wire [127:0] dw_data,
    output wire [5:0] dw_row, output wire [9:0] dw_pixel, output wire [1:0] dw_context,
    output wire dw_owner, output wire [31:0] dw_epoch, output wire dw_last,
    output wire done, output wire error, output wire [31:0] input_read_count,
    output wire [31:0] padding_tap_count, output wire [31:0] dw_mac_count,
    output wire [3:0] context_peak
);
    localparam integer CFG_WORDS = 84;
    localparam [3:0] ST_CFG=4'd0, ST_LOAD_REQ=4'd1, ST_LOAD_WAIT=4'd2,
                     ST_CALC=4'd3, ST_RQ=4'd4, ST_OUT=4'd5, ST_DONE=4'd6;
    reg [3:0] state;
    reg [6:0] cfg_index;
    reg [10:0] load_pixel, load_end_pixel;
    reg [5:0] out_row, out_col;
    reg [2:0] rq_group;
    reg [127:0] dw_data_r;
    reg dw_valid_r, done_r, error_r;
    reg signed [7:0] dw_weight [0:15][0:8];
    reg signed [31:0] dw_bias [0:15], dw_multiplier [0:15];
    reg [5:0] dw_shift [0:15];
    // Three rolling rows, one fixed byte-wide lane per channel.  The depth
    // and address are constant at synthesis, so these are RAM-shaped stores,
    // unlike the old full-frame 3-D feature register.
    (* ram_style = "block" *) reg signed [7:0] row_mem [0:2][0:31][0:15];
    reg signed [31:0] accum [0:15];
    reg [31:0] input_count_r, padding_count_r, mac_count_r;
    reg [3:0] context_peak_r;
    integer i, j, c, tap, iy, ix, tap_value, tap_sum, pad_tmp;

    function automatic signed [7:0] requant_dw;
        input signed [31:0] acc_value, bias_value, multiplier_value;
        input [5:0] shift_value;
        reg signed [63:0] product, magnitude, rounded, shifted, value;
        begin
            product = (acc_value + bias_value) * multiplier_value;
            if (product < 0) begin
                magnitude = -product;
                rounded = -((magnitude + 64'sd1073741824) >>> 31);
            end else rounded = (product + 64'sd1073741824) >>> 31;
            shifted = rounded >>> shift_value;
            value = shifted;
            if (value > 127) value = 127;
            else if (value < -128) value = -128;
            if (value < 0) value = 0;
            else if (value > 127) value = 127;
            requant_dw = value[7:0];
        end
    endfunction

    assign ready = (state == ST_CFG) && (cfg_index >= CFG_WORDS);
    assign cfg_ready = (state == ST_CFG) && (cfg_index < CFG_WORDS);
    assign mem_req_valid = (state == ST_LOAD_REQ);
    assign mem_req_write = 1'b0;
    assign mem_req_addr = INPUT_BASE + (load_pixel * 32'd16);
    assign mem_req_wdata = 128'd0;
    assign mem_req_strb = 16'd0;
    assign mem_req_context = ((load_pixel / CONTEXT_PIXELS) & 2'd3);
    assign mem_req_owner = ((load_pixel / CONTEXT_PIXELS) & 1'd1);
    assign mem_req_epoch = ((load_pixel / CONTEXT_PIXELS) >> 1);
    assign dw_valid = dw_valid_r;
    assign dw_data = dw_data_r;
    assign dw_row = out_row;
    assign dw_pixel = (out_row * IMAGE_W) + out_col;
    assign dw_context = (((out_row * IMAGE_W) + out_col) / CONTEXT_PIXELS) & 2'd3;
    assign dw_owner = (((out_row * IMAGE_W) + out_col) / CONTEXT_PIXELS) & 1'd1;
    assign dw_epoch = (((out_row * IMAGE_W) + out_col) / CONTEXT_PIXELS) >> 1;
    assign dw_last = dw_valid_r && (out_row == IMAGE_H-1) && (out_col == IMAGE_W-1);
    assign done = done_r;
    assign error = error_r;
    assign input_read_count = input_count_r;
    assign padding_tap_count = padding_count_r;
    assign dw_mac_count = mac_count_r;
    assign context_peak = context_peak_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_CFG;
            cfg_index <= 0;
            load_pixel <= 0;
            load_end_pixel <= 63;
            out_row <= 0;
            out_col <= 0;
            rq_group <= 0;
            dw_data_r <= 0;
            dw_valid_r <= 0;
            done_r <= 0;
            error_r <= 0;
            input_count_r <= 0;
            padding_count_r <= 0;
            mac_count_r <= 0;
            context_peak_r <= 4'd4;
            for (i = 0; i < 16; i = i + 1) begin
                dw_bias[i] <= 0;
                dw_multiplier[i] <= 0;
                dw_shift[i] <= 0;
                accum[i] <= 0;
                for (j = 0; j < 9; j = j + 1)
                    dw_weight[i][j] <= 0;
            end
        end else begin
            if (state == ST_CFG) begin
                if (cfg_valid && cfg_ready) begin
                    if (cfg_index < 36) begin
                        for (j = 0; j < 4; j = j + 1)
                            if ((cfg_index*4+j) < 144)
                                dw_weight[(cfg_index*4+j)/9][(cfg_index*4+j)%9] <=
                                    $signed(cfg_data[j*8 +: 8]);
                    end else if (cfg_index < 52)
                        dw_bias[cfg_index-36] <= $signed(cfg_data);
                    else if (cfg_index < 68)
                        dw_multiplier[cfg_index-52] <= $signed(cfg_data);
                    else
                        dw_shift[cfg_index-68] <= cfg_data[5:0];
                    cfg_index <= cfg_index + 1'b1;
                end
                if (start && ready) begin
                    state <= ST_LOAD_REQ;
                    load_pixel <= 0;
                    load_end_pixel <= 63;
                    out_row <= 0;
                    out_col <= 0;
                    input_count_r <= 0;
                    padding_count_r <= 0;
                    mac_count_r <= 0;
                    done_r <= 0;
                    error_r <= 0;
                end
            end else if (state == ST_LOAD_REQ) begin
                if (mem_req_ready)
                    state <= ST_LOAD_WAIT;
            end else if (state == ST_LOAD_WAIT) begin
                if (mem_resp_valid) begin
                    for (j = 0; j < CHANNELS; j = j + 1)
                        row_mem[(load_pixel/IMAGE_W)%3][load_pixel%IMAGE_W][j] <=
                            $signed(mem_resp_rdata[j*8 +: 8]);
                    input_count_r <= input_count_r + 1'b1;
                    if (load_pixel == load_end_pixel) begin
                        out_row <= (load_end_pixel == 63) ? 0 : out_row;
                        out_col <= 0;
                        state <= ST_CALC;
                    end else begin
                        load_pixel <= load_pixel + 1'b1;
                        state <= ST_LOAD_REQ;
                    end
                end
            end else if (state == ST_CALC) begin
                pad_tmp = 0;
                for (c = 0; c < CHANNELS; c = c + 1) begin
                    tap_sum = 0;
                    for (tap = 0; tap < 9; tap = tap + 1) begin
                        iy = out_row + (tap/3) - 1;
                        ix = out_col + (tap%3) - 1;
                        if (iy < 0 || iy >= IMAGE_H || ix < 0 || ix >= IMAGE_W) begin
                            tap_value = 0;
                            if (c == 0) pad_tmp = pad_tmp + 1;
                        end else begin
                            tap_value = row_mem[iy%3][ix][c];
                        end
                        tap_sum = tap_sum + tap_value * dw_weight[c][tap];
                    end
                    accum[c] <= tap_sum;
                end
                padding_count_r <= padding_count_r + pad_tmp;
                mac_count_r <= mac_count_r + 32'd144;
                rq_group <= 0;
                state <= ST_RQ;
            end else if (state == ST_RQ) begin
                for (c = 0; c < 4; c = c + 1)
                    dw_data_r[c*8 +: 8] <= requant_dw(accum[rq_group*4+c],
                        dw_bias[rq_group*4+c], dw_multiplier[rq_group*4+c],
                        dw_shift[rq_group*4+c]);
                if (rq_group == 3) begin
                    dw_valid_r <= 1'b1;
                    state <= ST_OUT;
                end else rq_group <= rq_group + 1'b1;
            end else if (state == ST_OUT) begin
                if (dw_valid_r && dw_ready) begin
                    dw_valid_r <= 1'b0;
                    if (out_col == IMAGE_W-1) begin
                        if (out_row == IMAGE_H-1) begin
                            done_r <= 1'b1;
                            state <= ST_DONE;
                        end else begin
                            out_row <= out_row + 1'b1;
                            out_col <= 0;
                            if (out_row < IMAGE_H-2) begin
                                load_pixel <= (out_row + 2) * IMAGE_W;
                                load_end_pixel <= (out_row + 2) * IMAGE_W + IMAGE_W-1;
                                state <= ST_LOAD_REQ;
                            end else state <= ST_CALC;
                        end
                    end else begin
                        out_col <= out_col + 1'b1;
                        state <= ST_CALC;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
