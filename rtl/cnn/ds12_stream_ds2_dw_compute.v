`timescale 1ns/1ps
`default_nettype none

// Isolated DS2 depthwise endpoint.  The input is the vector-reader contract:
// one accepted beat is one complete 16-channel slice of one 3x3 tap.  Four
// context accumulators are sufficient because a context is released only
// after both 16-channel output groups have been accepted.  No feature/tile
// buffer is used here, so this block can feed the PW vector consumer directly.
module ds12_stream_ds2_dw_compute #(
    parameter integer CONTEXTS = 4,
    parameter integer INPUT_ZERO_POINT = 0,
    parameter integer OUTPUT_ZERO_POINT = 0,
    parameter integer ACTIVATION_MIN = 0,
    parameter integer ACTIVATION_MAX = 127
) (
    input wire clk, input wire rst_n,
    input wire start, output wire ready,

    // Synchronous read port of ds12_stream_config_banks.  DS2 words 0..167
    // are DW weights/bias/multiplier/shift in the packed C0 ABI.
    output wire cfg_rd_en, output wire cfg_rd_bank,
    output wire [15:0] cfg_rd_addr, input wire [31:0] cfg_rd_data,
    input wire cfg_rd_valid, input wire cfg_active_valid,
    input wire [1:0] cfg_active_layer, input wire cfg_active_bank,
    input wire [31:0] cfg_active_epoch,
    output wire [15:0] config_index, output wire [31:0] config_payload,

    input wire window_valid, output wire window_ready,
    input wire [127:0] window_data,
    input wire [5:0] window_row, input wire [5:0] window_col,
    input wire [1:0] window_tap_row, input wire [1:0] window_tap_col,
    input wire window_channel_slice, input wire [1:0] window_context,
    input wire window_owner, input wire [31:0] window_epoch,
    input wire window_last,

    output wire dw_valid, input wire dw_ready, output wire [127:0] dw_data,
    output wire [5:0] dw_row, output wire [7:0] dw_pixel,
    output wire dw_group, output wire [1:0] dw_context,
    output wire dw_owner, output wire [31:0] dw_epoch, output wire dw_last,

    output wire done, output wire error, output wire [7:0] error_code,
    output wire [31:0] window_vector_count, output wire [31:0] dw_vector_count,
    output wire [31:0] dw_mac_count, output wire [31:0] padding_tap_count,
    output wire [3:0] context_peak, output wire [31:0] config_read_count
);
    localparam [3:0] ST_IDLE=4'd0, ST_CFG_ISSUE=4'd1, ST_CFG_WAIT=4'd2,
                     ST_RUN=4'd3, ST_DONE=4'd4;
    localparam [1:0] CTX_IDLE=2'd0, CTX_ACCUM=2'd1;
    localparam integer DW_CFG_WORDS = 168;
    localparam integer RESULT_SLOTS = 8;

    reg [3:0] state;
    reg [15:0] cfg_index_r;
    reg cfg_bank_r;
    reg [31:0] cfg_epoch_r;
    reg signed [7:0] dw_weight [0:31][0:8];
    reg signed [31:0] dw_bias [0:31];
    reg signed [31:0] dw_multiplier [0:31];
    reg [5:0] dw_shift [0:31];

    reg [1:0] ctx_state [0:CONTEXTS-1];
    reg [5:0] ctx_row [0:CONTEXTS-1], ctx_col [0:CONTEXTS-1];
    reg [3:0] ctx_tap [0:CONTEXTS-1];
    reg ctx_slice [0:CONTEXTS-1], ctx_owner [0:CONTEXTS-1];
    reg [31:0] ctx_epoch [0:CONTEXTS-1];
    reg signed [31:0] accum [0:CONTEXTS-1][0:31];
    // Per-context completed-window FIFOs decouple the 4-lane RQ (8 cycles
    // for both groups) from the reader's continuous 18-beat cadence.
    reg signed [31:0] result_accum [0:CONTEXTS-1][0:RESULT_SLOTS-1][0:31];
    reg [5:0] result_row [0:CONTEXTS-1][0:RESULT_SLOTS-1], result_col [0:CONTEXTS-1][0:RESULT_SLOTS-1];
    reg result_owner [0:CONTEXTS-1][0:RESULT_SLOTS-1]; reg [31:0] result_epoch [0:CONTEXTS-1][0:RESULT_SLOTS-1];
    reg [3:0] result_count [0:CONTEXTS-1];
    reg [2:0] result_head [0:CONTEXTS-1], result_tail [0:CONTEXTS-1];

    reg rq_active, rq_valid;
    reg [1:0] rq_ctx;
    reg [2:0] rq_head_slot;
    reg rq_group;
    reg [1:0] rq_lane;
    reg [127:0] rq_data;
    reg [5:0] rq_row;
    reg [7:0] rq_pixel;
    reg rq_owner;
    reg [31:0] rq_epoch;
    reg [1:0] rq_rr;
    reg done_r, error_r;
    reg [7:0] error_code_r;
    reg [31:0] window_count_r, dw_count_r, mac_count_r, pad_count_r;
    reg [31:0] cfg_read_count_r;
    reg [3:0] context_peak_r;
    reg [3:0] active_count;
    integer i, j, c, tap_i, ctx_i, pick;
    integer signed prod_i;
    integer signed sum_i;
    integer signed iy_i, ix_i;
    reg pick_found;

    function automatic signed [7:0] requant_dw;
        input signed [31:0] acc_value, bias_value, multiplier_value;
        input [5:0] shift_value;
        reg signed [63:0] product;
        reg signed [63:0] magnitude;
        reg signed [63:0] rounded, shifted, value;
        begin
            product = (acc_value + bias_value) * multiplier_value;
            if (product < 0) begin
                magnitude = -product;
                rounded = -((magnitude + 64'sd1073741824) >>> 31);
            end else rounded = (product + 64'sd1073741824) >>> 31;
            shifted = rounded >>> shift_value;
            value = shifted + OUTPUT_ZERO_POINT;
            if (value > 127) value = 127;
            else if (value < -128) value = -128;
            if (value < ACTIVATION_MIN) value = ACTIVATION_MIN;
            else if (value > ACTIVATION_MAX) value = ACTIVATION_MAX;
            requant_dw = value[7:0];
        end
    endfunction

    always @* begin
        active_count = 0;
        for (i=0; i<CONTEXTS; i=i+1)
            if (ctx_state[i] != CTX_IDLE || result_count[i] != 0) active_count = active_count + 1'b1;
        pick_found = 1'b0; pick = 0;
        for (i=0; i<CONTEXTS; i=i+1)
            if (!pick_found && (result_count[(rq_rr+i)%CONTEXTS] != 0)) begin
                pick_found = 1'b1; pick = (rq_rr+i)%CONTEXTS;
            end
    end

    assign ready = (state == ST_IDLE) && cfg_active_valid && (cfg_active_layer == 2'd2);
    assign cfg_rd_en = (state == ST_CFG_ISSUE);
    assign cfg_rd_bank = cfg_bank_r;
    assign cfg_rd_addr = cfg_index_r;
    assign config_index = cfg_index_r;
    assign config_payload = cfg_rd_data;
    assign window_ready = (state == ST_RUN) && (result_count[window_context] < RESULT_SLOTS) &&
                          !(rq_valid && dw_ready && rq_group && (rq_ctx == window_context));
    assign dw_valid = rq_valid;
    assign dw_data = rq_data;
    assign dw_row = rq_row;
    assign dw_pixel = rq_pixel;
    assign dw_group = rq_group;
    assign dw_context = rq_ctx;
    assign dw_owner = rq_owner;
    assign dw_epoch = rq_epoch;
    assign dw_last = rq_valid && rq_group && (rq_pixel == 8'd255);
    assign done = done_r;
    assign error = error_r;
    assign error_code = error_code_r;
    assign window_vector_count = window_count_r;
    assign dw_vector_count = dw_count_r;
    assign dw_mac_count = mac_count_r;
    assign padding_tap_count = pad_count_r;
    assign context_peak = context_peak_r;
    assign config_read_count = cfg_read_count_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE; cfg_index_r <= 0; cfg_bank_r <= 0; cfg_epoch_r <= 0;
            rq_active <= 0; rq_valid <= 0; rq_ctx <= 0; rq_head_slot <= 0; rq_group <= 0; rq_lane <= 0;
            rq_data <= 0; rq_row <= 0; rq_pixel <= 0; rq_owner <= 0; rq_epoch <= 0; rq_rr <= 0;
            done_r <= 0; error_r <= 0; error_code_r <= 0; window_count_r <= 0;
            dw_count_r <= 0; mac_count_r <= 0; pad_count_r <= 0; context_peak_r <= 0;
            cfg_read_count_r <= 0;
            for (i=0; i<CONTEXTS; i=i+1) begin
                ctx_state[i] <= CTX_IDLE; result_count[i] <= 0; result_head[i] <= 0; result_tail[i] <= 0; ctx_tap[i] <= 0;
                ctx_slice[i] <= 0; ctx_row[i] <= 0; ctx_col[i] <= 0; ctx_owner[i] <= 0; ctx_epoch[i] <= 0;
                for (j=0; j<32; j=j+1) accum[i][j] <= 0;
            end
            for (i=0; i<32; i=i+1) begin
                dw_bias[i] <= 0; dw_multiplier[i] <= 0; dw_shift[i] <= 0;
                for (j=0; j<9; j=j+1) dw_weight[i][j] <= 0;
            end
        end else begin
            if (state == ST_IDLE && start) begin
                if (!cfg_active_valid || cfg_active_layer != 2'd2) begin
                    error_r <= 1'b1; error_code_r <= error_code_r | 8'h01;
                end else begin
                    cfg_bank_r <= cfg_active_bank; cfg_epoch_r <= cfg_active_epoch;
                    cfg_index_r <= 0; state <= ST_CFG_ISSUE; done_r <= 0; error_r <= 0;
                    window_count_r <= 0; dw_count_r <= 0; mac_count_r <= 0; pad_count_r <= 0; cfg_read_count_r <= 0;
                end
            end

            if (state == ST_CFG_ISSUE) state <= ST_CFG_WAIT;
            else if (state == ST_CFG_WAIT && cfg_rd_valid) begin
                cfg_read_count_r <= cfg_read_count_r + 1'b1;
                if (cfg_index_r < 72) begin
                    for (j=0; j<4; j=j+1)
                        dw_weight[(cfg_index_r*4+j)/9][(cfg_index_r*4+j)%9] <= $signed(cfg_rd_data[j*8 +: 8]);
                end else if (cfg_index_r < 104) dw_bias[cfg_index_r-72] <= $signed(cfg_rd_data);
                else if (cfg_index_r < 136) dw_multiplier[cfg_index_r-104] <= $signed(cfg_rd_data);
                else if (cfg_index_r < 168) dw_shift[cfg_index_r-136] <= cfg_rd_data[5:0];
                if (cfg_index_r == DW_CFG_WORDS-1) begin
                    state <= ST_RUN;
                    for (i=0; i<CONTEXTS; i=i+1) begin
                        ctx_state[i] <= CTX_IDLE; result_count[i] <= 0; result_head[i] <= 0; result_tail[i] <= 0;
                    end
                end else begin cfg_index_r <= cfg_index_r + 1'b1; state <= ST_CFG_ISSUE; end
            end

            if (state == ST_RUN) begin
                if (window_valid && window_ready) begin
                    ctx_i = window_context;
                    tap_i = window_tap_row * 3 + window_tap_col;
                    if (window_tap_row > 2 || window_tap_col > 2 || tap_i > 8 ||
                        window_context >= CONTEXTS || result_count[ctx_i] >= RESULT_SLOTS) begin
                        error_r <= 1'b1; error_code_r <= error_code_r | 8'h02;
                    end else if (ctx_state[ctx_i] == CTX_IDLE) begin
                        if (tap_i != 0 || window_channel_slice != 0) begin
                            error_r <= 1'b1; error_code_r <= error_code_r | 8'h04;
                        end
                        ctx_state[ctx_i] <= CTX_ACCUM; ctx_row[ctx_i] <= window_row; ctx_col[ctx_i] <= window_col;
                        // slice 0 was consumed by this beat; slice 1 is next.
                        ctx_tap[ctx_i] <= 0; ctx_slice[ctx_i] <= 1; ctx_owner[ctx_i] <= window_owner; ctx_epoch[ctx_i] <= window_epoch;
                        for (c=0; c<16; c=c+1) begin
                            prod_i = $signed(window_data[c*8 +: 8]) * dw_weight[c][0];
                            accum[ctx_i][c] <= prod_i;
                        end
                    end else begin
                        if (window_last != (window_row == 6'd15 && window_col == 6'd15 && tap_i == 8 && window_channel_slice)) begin
                            error_r <= 1'b1; error_code_r <= error_code_r | 8'h10;
                        end
                        if (window_row != ctx_row[ctx_i] || window_col != ctx_col[ctx_i] ||
                            window_owner != ctx_owner[ctx_i] || window_epoch != ctx_epoch[ctx_i] ||
                            tap_i != ctx_tap[ctx_i] || window_channel_slice != ctx_slice[ctx_i]) begin
                            error_r <= 1'b1; error_code_r <= error_code_r | 8'h08;
                        end
                        for (c=0; c<16; c=c+1) begin
                            prod_i = $signed(window_data[c*8 +: 8]) * dw_weight[window_channel_slice*16+c][tap_i];
                            accum[ctx_i][window_channel_slice*16+c] <= accum[ctx_i][window_channel_slice*16+c] + prod_i;
                        end
                        if (window_channel_slice) begin
                            if (tap_i == 8) begin
                                // Copy the final slice's products into the
                                // per-context result FIFO.  The explicit
                                // addition is needed because the last MAC is
                                // written to accum on this same clock edge.
                                for (c=0; c<16; c=c+1)
                                    result_accum[ctx_i][result_tail[ctx_i]][16+c] <= accum[ctx_i][16+c] +
                                        ($signed(window_data[c*8 +: 8]) * dw_weight[16+c][tap_i]);
                                for (c=0; c<16; c=c+1)
                                    result_accum[ctx_i][result_tail[ctx_i]][c] <= accum[ctx_i][c];
                                result_row[ctx_i][result_tail[ctx_i]] <= ctx_row[ctx_i];
                                result_col[ctx_i][result_tail[ctx_i]] <= ctx_col[ctx_i];
                                result_owner[ctx_i][result_tail[ctx_i]] <= ctx_owner[ctx_i];
                                result_epoch[ctx_i][result_tail[ctx_i]] <= ctx_epoch[ctx_i];
                                result_tail[ctx_i] <= result_tail[ctx_i] + 1'b1;
                                result_count[ctx_i] <= result_count[ctx_i] + 1'b1;
                                ctx_state[ctx_i] <= CTX_IDLE;
                            end else begin ctx_tap[ctx_i] <= tap_i + 1'b1; ctx_slice[ctx_i] <= 1'b0; end
                        end else ctx_slice[ctx_i] <= 1'b1;
                    end
                    window_count_r <= window_count_r + 1'b1;
                    mac_count_r <= mac_count_r + 32'd16;
                    iy_i = window_row * 2 + window_tap_row - 1;
                    ix_i = window_col * 2 + window_tap_col - 1;
                    if (!window_channel_slice && ((iy_i < 0) || (iy_i >= 32) || (ix_i < 0) || (ix_i >= 32)))
                        pad_count_r <= pad_count_r + 1'b1;
                end

                if (!rq_active && pick_found) begin
                    rq_active <= 1'b1; rq_valid <= 1'b0; rq_ctx <= pick[1:0]; rq_head_slot <= result_head[pick]; rq_group <= 1'b0; rq_lane <= 0;
                    rq_row <= result_row[pick][result_head[pick]]; rq_pixel <= result_row[pick][result_head[pick]] * 16 + result_col[pick][result_head[pick]];
                    rq_owner <= result_owner[pick][result_head[pick]]; rq_epoch <= result_epoch[pick][result_head[pick]];
                end else if (rq_active && !rq_valid) begin
                    // Four-lane requant issue.  Four cycles form one
                    // 16-channel group; the result FIFO hides this work
                    // behind the continuous reader stream.
                    rq_data[rq_lane*8 +: 8] <= requant_dw(result_accum[rq_ctx][rq_head_slot][rq_group*16+rq_lane],
                        dw_bias[rq_group*16+rq_lane], dw_multiplier[rq_group*16+rq_lane], dw_shift[rq_group*16+rq_lane]);
                    if (rq_lane == 3) begin rq_valid <= 1'b1; rq_lane <= 0; end
                    else rq_lane <= rq_lane + 1'b1;
                end else if (rq_valid && dw_ready) begin
                    rq_valid <= 1'b0; dw_count_r <= dw_count_r + 1'b1;
                    if (rq_group) begin
                        result_head[rq_ctx] <= result_head[rq_ctx] + 1'b1;
                        result_count[rq_ctx] <= result_count[rq_ctx] - 1'b1;
                        rq_active <= 1'b0;
                        rq_rr <= rq_ctx + 1'b1;
                        if (rq_pixel == 8'd255) begin done_r <= 1'b1; state <= ST_DONE; end
                    end else begin rq_group <= 1'b1; rq_lane <= 0; end
                end
                if (active_count > context_peak_r) context_peak_r <= active_count;
            end
        end
    end
endmodule
`default_nettype wire
