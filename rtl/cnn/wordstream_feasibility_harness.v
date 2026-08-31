`timescale 1ns/1ps
`default_nettype none

/*
 * Stand-alone feasibility harness for the word-stream data path.  This is
 * deliberately not connected to cnn_layer_runner: it exercises the native
 * word feeder, one shared 16-lane MAC, the existing PW 8x8 DSP block, and a
 * real bank ownership hand-off at a layer boundary.
 *
 * The fixed shapes are the first two model layers: 32x32x3 -> 32x32x16
 * (3x3 stem, pad=1), followed by 32x32x16 -> 32x32x32 (DW 3x3 pad=1 and
 * PW).  The feeder's external port is a synchronous native 32-bit SRAM ABI;
 * the testbench supplies response latency and request backpressure.
 */
module wordstream_feasibility_harness #(
    parameter STEM_H = 32,
    parameter STEM_W = 32,
    parameter DS_CIN = 16,
    parameter DS_COUT = 32,
    parameter STORAGE_ENABLED = 1
) (
    input wire clk, input wire rst_n, input wire start,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [23:0] mem_req_addr,
    input wire mem_resp_valid, input wire [31:0] mem_resp_data,
    output reg busy, output reg done, output reg error,
    output reg [31:0] perf_cycles, output reg [31:0] perf_mac_tokens,
    output wire [31:0] perf_mem_issues, output wire [31:0] perf_mem_responses,
    output wire [31:0] perf_consumes, output reg [31:0] perf_overlap_cycles,
    output reg stem_wr_valid, output reg [15:0] stem_wr_index,
    output reg signed [7:0] stem_wr_data,
    output reg pw_wr_valid, output reg [15:0] pw_wr_index,
    output reg signed [7:0] pw_wr_data,
    output wire debug_dw_checksum
);
    localparam integer STEM_PIXELS = STEM_H*STEM_W;
    localparam integer STEM_TOKENS = 27;
    localparam integer DS_TOKENS = 9;
    localparam [23:0] STEM_BASE = 24'h000003;
    localparam [23:0] DS_BASE = 24'h004003;
    localparam [3:0] FILL_STEM=0, ACT_STEM=1, FILL_DS=2, STEM_REQ=3,
                     STEM_WAIT=4, STEM_SEND=5, STEM_OUT=6, WAIT_DS=7,
                     ACT_DS=8, DS_REQ=9, DS_WAIT=10, DS_SEND=11,
                     DS_OUT=12, PW_SEND=13, PW_OUT=14, FINISH=15;
    reg [3:0] state;
    reg [15:0] stem_pixel, ds_pixel;
    reg [5:0] stem_token;
    reg [3:0] ds_token;
    reg [4:0] ds_channel;
    reg [10:0] pw_pixel_base;
    reg [5:0] pw_cout_base;
    reg [4:0] pw_k;
    reg fill_ds_started, fill_ds_done;
    reg [7:0] stem_act_reg;
    reg [127:0] ds_act_reg;

    reg signed [7:0] stem_mem [0:(STORAGE_ENABLED ? STEM_PIXELS*16 : 1)-1];
    reg signed [7:0] ds_mem [0:(STORAGE_ENABLED ? STEM_PIXELS*DS_CIN : 1)-1];
    reg signed [7:0] pw_mem [0:(STORAGE_ENABLED ? STEM_PIXELS*DS_COUT : 1)-1];
    reg signed [7:0] stem_weight_mem [0:16*27-1];
    reg signed [7:0] ds_weight_mem [0:DS_CIN*9-1];
    reg signed [7:0] pw_weight_mem [0:DS_COUT*DS_CIN-1];
    integer init_i;
    initial begin
        for (init_i=0; init_i<16*27; init_i=init_i+1)
            stem_weight_mem[init_i] = (init_i*13 % 7) - 3;
        for (init_i=0; init_i<DS_CIN*9; init_i=init_i+1)
            ds_weight_mem[init_i] = (init_i*7 % 5) - 2;
        for (init_i=0; init_i<DS_COUT*DS_CIN; init_i=init_i+1)
            pw_weight_mem[init_i] = (init_i*11 % 7) - 3;
    end
    function signed [7:0] stem_value(input integer idx);
        begin if (STORAGE_ENABLED) stem_value=stem_mem[idx]; else stem_value=8'sd0; end
    endfunction
    function signed [7:0] ds_value(input integer idx);
        begin if (STORAGE_ENABLED) ds_value=ds_mem[idx]; else ds_value=8'sd0; end
    endfunction
    function signed [7:0] pw_value(input integer idx);
        begin if (STORAGE_ENABLED) pw_value=pw_mem[idx]; else pw_value=8'sd0; end
    endfunction
    /* Identity quantizer for the feasibility model: zero bias, Q31 unity
     * multiplier, zero shift, and the model's int8 activation clamp. */
    function signed [7:0] quant_identity(input signed [31:0] value);
        begin
            if (value > 32'sd127) quant_identity = 8'sd127;
            else if (value < -32'sd128) quant_identity = -8'sd128;
            else quant_identity = value[7:0];
        end
    endfunction

    wire fill_start_valid = busy && ((state == FILL_STEM) ||
                            ((state == FILL_DS) && !fill_ds_started));
    wire fill_start_ready;
    wire fill_bank = (state == FILL_DS);
    wire fill_done_valid, fill_done_bank;
    wire activate_valid = (state == ACT_STEM) || (state == ACT_DS);
    wire activate_bank = (state == ACT_DS);
    wire activate_ready;
    wire release_valid = (state == ACT_DS);
    wire release_ready;
    wire consume_req_valid;
    wire consume_req_ready;
    wire [31:0] consume_byte_offset;
    wire consume_resp_valid, consume_resp_ready;
    assign consume_resp_ready = 1'b1;
    wire [7:0] consume_resp_data;
    wire feeder_active_bank;
    wire [1:0] bank0_state, bank1_state;
    wire [7:0] feeder_tile_id;
    wire [3:0] feeder_epoch;
    assign feeder_tile_id = 8'h21;
    assign feeder_epoch = 4'h1;

    feature_tile_word_feeder #(
        .ADDR_WIDTH(24), .BANK_BYTES(16384), .MEM_RD_LATENCY(1),
        .TILE_ID_WIDTH(8), .EPOCH_WIDTH(4)
    ) u_feeder (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_bank(fill_bank), .fill_tile_id(feeder_tile_id),
        .fill_epoch(feeder_epoch),
        .fill_base_byte_addr(fill_bank ? DS_BASE : STEM_BASE),
        .fill_row_stride_bytes(fill_bank ? (STEM_W*DS_CIN) : (STEM_W*3)),
        .fill_tile_h(STEM_H), .fill_tile_w(STEM_W),
        .fill_channels(fill_bank ? DS_CIN : 8'd3),
        .fill_row_valid_mask(32'hffffffff), .fill_col_valid_mask(32'hffffffff),
        .fill_pad_value(8'h00), .fill_done_valid(fill_done_valid),
        .fill_done_bank(fill_done_bank), .fill_done_tile_id(), .fill_done_epoch(),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data),
        .activate_valid(activate_valid), .activate_ready(activate_ready),
        .activate_bank(activate_bank), .activate_tile_id(feeder_tile_id),
        .activate_epoch(feeder_epoch), .active_bank(feeder_active_bank),
        .active_tile_id(), .active_epoch(), .release_valid(release_valid),
        .release_ready(release_ready), .release_bank(1'b0),
        .release_tile_id(feeder_tile_id), .release_epoch(feeder_epoch),
        .consume_req_valid(consume_req_valid), .consume_req_ready(consume_req_ready),
        .consume_byte_offset(consume_byte_offset), .consume_resp_valid(consume_resp_valid),
        .consume_resp_ready(consume_resp_ready), .consume_resp_data(consume_resp_data),
        .consume_resp_tile_id(), .consume_resp_epoch(), .consume_resp_bank(),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .perf_mem_issue_count(perf_mem_issues),
        .perf_mem_resp_count(perf_mem_responses), .perf_consume_count(perf_consumes),
        .perf_consume_stall_count()
    );

    wire stem_valid_in = (state == STEM_SEND);
    wire stem_ready_in, stem_valid_out;
    wire [7:0] stem_idx_out;
    wire [15:0] stem_mask_out;
    wire signed [511:0] stem_sum_out;
    wire dw_valid_in = (state == DS_SEND);
    wire dw_ready_in, dw_valid_out;
    wire [7:0] dw_idx_out;
    wire [15:0] dw_mask_out;
    wire signed [511:0] dw_sum_out;
    wire mac_stem_last = (stem_token == STEM_TOKENS-1);
    wire mac_dw_last = (ds_token == DS_TOKENS-1);
    wire [127:0] stem_wgt_vec;
    wire [127:0] ds_wgt_vec;
    genvar vg;
    generate
        for (vg=0; vg<16; vg=vg+1) begin : GEN_W
            assign stem_wgt_vec[vg*8 +: 8] = stem_weight_mem[vg*27+stem_token];
            assign ds_wgt_vec[vg*8 +: 8] = ds_weight_mem[vg*9+ds_token];
        end
    endgenerate

    mac16_stream_shared_wrapper u_mac (
        .clk(clk), .rst_n(rst_n),
        .stem_valid_in(stem_valid_in), .stem_ready_in(stem_ready_in),
        .stem_first_token(stem_token==0), .stem_last_token(mac_stem_last),
        .stem_token_idx(stem_token), .stem_lane_mask(16'hffff),
        .stem_act_scalar(stem_act_reg), .stem_weight_vec(stem_wgt_vec),
        .stem_ready_out(1'b1), .stem_valid_out(stem_valid_out),
        .stem_token_idx_out(stem_idx_out), .stem_lane_mask_out(stem_mask_out),
        .stem_sum_out(stem_sum_out),
        .dw_valid_in(dw_valid_in), .dw_ready_in(dw_ready_in),
        .dw_first_token(ds_token==0), .dw_last_token(mac_dw_last),
        .dw_token_idx(ds_token), .dw_lane_mask(16'hffff),
        .dw_act_vec(ds_act_reg), .dw_weight_vec(ds_wgt_vec), .dw_ready_out(1'b1),
        .dw_valid_out(dw_valid_out), .dw_token_idx_out(dw_idx_out),
        .dw_lane_mask_out(dw_mask_out), .dw_sum_out(dw_sum_out)
    );
    assign debug_dw_checksum = ^dw_sum_out;

    wire pw_ready_in, pw_valid_out;
    wire signed [2047:0] pw_psum_out;
    wire [63:0] pw_lane_mask_out;
    wire [63:0] pw_act_vec;
    wire [63:0] pw_wgt_vec;
    generate
        for (vg=0; vg<8; vg=vg+1) begin : GEN_PW
            assign pw_act_vec[vg*8 +: 8] = ds_value((pw_pixel_base+vg)*DS_CIN+pw_k);
            assign pw_wgt_vec[vg*8 +: 8] = pw_weight_mem[(pw_cout_base+vg)*DS_CIN+pw_k];
        end
    endgenerate
    pw_direct_8x8_dsp u_pw (
        .clk(clk), .rst_n(rst_n), .valid_in(state==PW_SEND), .ready_in(pw_ready_in),
        .first_k(pw_k==0), .last_k(pw_k==DS_CIN-1), .k_idx(pw_k),
        .pixel_mask(8'hff), .cout_mask(8'hff), .act_vec(pw_act_vec),
        .wgt_vec(pw_wgt_vec), .ready_out(1'b1), .valid_out(pw_valid_out),
        .psum_out(pw_psum_out), .lane_mask_out(pw_lane_mask_out)
    );

    assign consume_req_valid = (state == STEM_REQ &&
                                (stem_pixel/STEM_W + (stem_token/9) != 0) &&
                                (stem_pixel%STEM_W + (stem_token/3)%3 != 0) &&
                                (stem_pixel/STEM_W + (stem_token/9) <= STEM_H) &&
                                (stem_pixel%STEM_W + (stem_token/3)%3 <= STEM_W)) ||
                               (state == DS_REQ &&
                                (ds_pixel/STEM_W + (ds_token/3) != 0) &&
                                (ds_pixel%STEM_W + (ds_token%3) != 0) &&
                                (ds_pixel/STEM_W + (ds_token/3) <= STEM_H) &&
                                (ds_pixel%STEM_W + (ds_token%3) <= STEM_W));
    assign consume_byte_offset = (state == STEM_REQ) ?
        (((stem_pixel/STEM_W + stem_token/9 - 1)*STEM_W +
          (stem_pixel%STEM_W + (stem_token/3)%3 - 1))*3 + stem_token%3) :
        (((ds_pixel/STEM_W + ds_token/3 - 1)*STEM_W +
          (ds_pixel%STEM_W + ds_token%3 - 1))*DS_CIN + ds_channel);

    integer wi, c_i;
    reg [31:0] acc_i;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= FILL_STEM; busy <= 1'b0; done <= 1'b0; error <= 1'b0;
            perf_cycles <= 0; perf_mac_tokens <= 0; perf_overlap_cycles <= 0;
            stem_pixel <= 0; stem_token <= 0; ds_pixel <= 0; ds_token <= 0;
            ds_channel <= 0; pw_pixel_base <= 0; pw_cout_base <= 0; pw_k <= 0;
            fill_ds_started <= 0; fill_ds_done <= 0; stem_act_reg <= 0; ds_act_reg <= 0;
            stem_wr_valid <= 0; pw_wr_valid <= 0; stem_wr_index <= 0; pw_wr_index <= 0;
            stem_wr_data <= 0; pw_wr_data <= 0;
        end else begin
            done <= 1'b0; stem_wr_valid <= 1'b0; pw_wr_valid <= 1'b0;
            if (busy) begin
                perf_cycles <= perf_cycles + 1;
                if (fill_ds_started && !fill_ds_done && (state >= ACT_STEM) && (state <= STEM_OUT))
                    perf_overlap_cycles <= perf_overlap_cycles + 1;
            end
            if (fill_done_valid && fill_done_bank) fill_ds_done <= 1'b1;
            if (start && state == FILL_STEM) begin busy <= 1'b1; end
            case (state)
                FILL_STEM: begin
                    if (fill_done_valid && !fill_done_bank) state <= ACT_STEM;
                end
                ACT_STEM: if (activate_valid && activate_ready) state <= FILL_DS;
                FILL_DS: begin
                    if (!fill_ds_started && fill_start_ready) begin
                        fill_ds_started <= 1'b1; state <= STEM_REQ;
                    end
                end
                STEM_REQ: begin
                    if (consume_req_valid) state <= STEM_WAIT;
                    else begin stem_act_reg <= 0; state <= STEM_SEND; end
                end
                STEM_WAIT: if (consume_resp_valid) begin stem_act_reg <= consume_resp_data; state <= STEM_SEND; end
                STEM_SEND: if (stem_valid_in && stem_ready_in) begin
                    perf_mac_tokens <= perf_mac_tokens + 1;
                    if (mac_stem_last) state <= STEM_OUT;
                    else begin stem_token <= stem_token + 1; state <= STEM_REQ; end
                end
                STEM_OUT: if (stem_valid_out) begin
                    if (STORAGE_ENABLED) for (wi=0; wi<16; wi=wi+1) stem_mem[stem_pixel*16+wi] <= quant_identity($signed(stem_sum_out[wi*32 +: 32]));
                    stem_wr_valid <= 1'b1; stem_wr_index <= stem_pixel*16;
                    stem_wr_data <= stem_sum_out[7:0];
                    if (stem_pixel == STEM_PIXELS-1) begin
                        if (fill_ds_done) state <= ACT_DS; else state <= WAIT_DS;
                    end else begin stem_pixel <= stem_pixel+1; stem_token <= 0; state <= STEM_REQ; end
                end
                WAIT_DS: if (fill_ds_done) state <= ACT_DS;
                /* Activation and release are independent ownership events.
                 * The consumer may launch as soon as bank N+1 is READY; a
                 * delayed release of bank N must not deadlock the hand-off. */
                ACT_DS: if (activate_ready || (feeder_active_bank && bank1_state == 2'd3)) begin
                    state <= DS_REQ; ds_pixel<=0; ds_token<=0; ds_channel<=0;
                end
                DS_REQ: begin
                    if (consume_req_valid) state <= DS_WAIT;
                    else begin ds_act_reg[ds_channel*8 +: 8] <= 0; if (ds_channel==15) state<=DS_SEND; else begin ds_channel<=ds_channel+1; state<=DS_REQ; end end
                end
                DS_WAIT: if (consume_resp_valid) begin
                    ds_act_reg[ds_channel*8 +: 8] <= consume_resp_data;
                    if (ds_channel==15) state<=DS_SEND; else begin ds_channel<=ds_channel+1; state<=DS_REQ; end
                end
                DS_SEND: if (dw_valid_in && dw_ready_in) begin
                    perf_mac_tokens <= perf_mac_tokens + 1;
                    if (mac_dw_last) state<=DS_OUT; else begin ds_token<=ds_token+1; ds_channel<=0; state<=DS_REQ; end
                end
                DS_OUT: if (dw_valid_out) begin
                    if (STORAGE_ENABLED) for (wi=0; wi<16; wi=wi+1) ds_mem[ds_pixel*16+wi] <= quant_identity($signed(dw_sum_out[wi*32 +: 32]));
                    if (ds_pixel==STEM_PIXELS-1) begin pw_pixel_base<=0; pw_cout_base<=0; pw_k<=0; state<=PW_SEND; end
                    else begin ds_pixel<=ds_pixel+1; ds_token<=0; ds_channel<=0; state<=DS_REQ; end
                end
                PW_SEND: if (pw_ready_in) begin
                    perf_mac_tokens <= perf_mac_tokens + 1;
                    if (pw_k==DS_CIN-1) state<=PW_OUT; else pw_k<=pw_k+1;
                end
                PW_OUT: if (pw_valid_out) begin
                    if (STORAGE_ENABLED) for (wi=0; wi<8; wi=wi+1) for (c_i=0; c_i<8; c_i=c_i+1)
                        pw_mem[(pw_pixel_base+wi)*DS_COUT+pw_cout_base+c_i] <= quant_identity($signed(pw_psum_out[((wi*8+c_i)*32) +: 32]));
                    pw_wr_valid<=1'b1; pw_wr_index<=pw_pixel_base*DS_COUT+pw_cout_base; pw_wr_data<=pw_psum_out[7:0];
                    if (pw_cout_base + 8 < DS_COUT) begin pw_cout_base<=pw_cout_base+8; pw_k<=0; state<=PW_SEND; end
                    else if (pw_pixel_base + 8 < STEM_PIXELS) begin pw_pixel_base<=pw_pixel_base+8; pw_cout_base<=0; pw_k<=0; state<=PW_SEND; end
                    else state<=FINISH;
                end
                FINISH: begin busy<=0; done<=1; state<=FILL_STEM; end
                default: begin error<=1; busy<=0; done<=1; state<=FILL_STEM; end
            endcase
        end
    end
    /* The feeder bank is the only legal consumer source.  A layer boundary
     * may not switch ownership while a byte response is outstanding. */
`ifndef SYNTHESIS
    always @(posedge clk) if (rst_n && activate_valid && activate_ready && consume_resp_valid)
        $display("WORDSTREAM_ASSERT activate_with_pending_response");
`endif
endmodule
`default_nettype wire
