`timescale 1ns/1ps
`default_nettype none

/*
 * D4 persistent-stream v2 arithmetic boundary.
 *
 * The request boundary is deliberately the accepted boundary: the shared
 * pool sees valid_in only when op_valid && op_ready.  This prevents a
 * backpressured RQ request from entering the pool without its controller tag.
 * The seven-pixel island and the shared 16-DSP pool are separate issue
 * streams; the controller fences PW and RQ phases, while the pool itself
 * provides the RQ elastic pipeline.
 */
module edgembconv_hwacandidate_d4_vstream_v2_datapath (
    input wire clk, input wire rst_n,
    input wire op_mode_rq, input wire op_valid, output wire op_ready,
    input wire [55:0] pw_act_7pixel_vec,
    input wire [127:0] pw_act_pool_vec, input wire [127:0] pw_wgt_vec,
    input wire [7:0] pw_pixel_mask, input wire [15:0] pw_cout_mask,
    input wire pw_first_k, input wire pw_last_k, input wire [7:0] pw_k_idx,
    input wire signed [127:0] rq_acc_vec,
    input wire signed [127:0] rq_multiplier_vec, input wire [23:0] rq_shift_vec,
    input wire signed [127:0] rq_zero_point_vec,
    input wire signed [127:0] rq_min_vec, input wire signed [127:0] rq_max_vec,
    input wire [31:0] metadata_in,
    input wire out_ready, output reg out_valid, output reg out_mode_rq,
    output reg signed [4095:0] pw_psum_vec, output reg [127:0] pw_lane_mask,
    output reg signed [255:0] rq_product_vec, output reg signed [31:0] rq_result_vec,
    output reg [31:0] metadata_out,
    input wire dw_cfg_valid, output wire dw_cfg_ready,
    input wire [7:0] dw_cfg_addr, input wire signed [7:0] dw_cfg_data,
    input wire dw_start_valid, output wire dw_start_ready,
    input wire [7:0] dw_in_w, input wire [7:0] dw_in_h,
    input wire [7:0] dw_out_x, input wire [7:0] dw_out_y,
    input wire [1:0] dw_stride, input wire [31:0] dw_metadata_in,
    output wire dw_src_req_valid, input wire dw_src_req_ready,
    output wire [31:0] dw_src_req_addr,
    input wire dw_src_resp_valid, output wire dw_src_resp_ready,
    input wire [127:0] dw_src_resp_data, input wire dw_out_ready,
    output wire dw_out_valid, output wire signed [511:0] dw_raw_psum_vec,
    output wire [31:0] dw_metadata_out, output wire dw_done
);
    wire pw_fire = op_valid && op_ready && !op_mode_rq;
    wire rq_fire = op_valid && op_ready && op_mode_rq;
    wire pool_ready, pool_valid, pool_mode;
    wire [255:0] pool_pw_product;
    wire signed [255:0] pool_rq_product;
    wire signed [31:0] pool_rq_result;
    wire [31:0] pool_metadata;
    wire output_space = !out_valid || out_ready;

    /* The pool receives the same accepted pulse as the composite boundary. */
    edgembconv_hwacandidate_d4_vstream_elastic_rq_pool u_shared_pool (
        .clk(clk), .rst_n(rst_n), .mode_rq(op_mode_rq),
        /* For PW the other half of the tile can stall independently, so the
         * pool offer is explicitly withdrawn when the seven-pixel island is
         * not able to accept.  In RQ mode pool_ready is the complete external
         * ready contract, hence valid_in is exactly the offered transaction
         * and no unaccepted token can enter the pool. */
        .valid_in(op_valid && (op_mode_rq || pw112_ready)), .ready_in(pool_ready),
        .rq_acc_vec(rq_acc_vec), .rq_multiplier_vec(rq_multiplier_vec),
        .rq_shift_vec(rq_shift_vec), .rq_zero_point_vec(rq_zero_point_vec),
        .rq_min_vec(rq_min_vec), .rq_max_vec(rq_max_vec),
        .pw_act_vec(pw_act_pool_vec), .pw_wgt_vec(pw_wgt_vec),
        .metadata_in(metadata_in), .valid_out(pool_valid),
        .ready_out((!out_mode_rq && !op_mode_rq) ? 1'b1 : output_space),
        .mode_rq_out(pool_mode), .pw_product_vec(pool_pw_product),
        .rq_product_vec(pool_rq_product), .rq_result_vec(pool_rq_result),
        .metadata_out(pool_metadata)
    );
    wire pw112_ready, pw112_valid;
    wire signed [3583:0] pw112_psum;
    wire [111:0] pw112_mask;
    edgembconv_hwacandidate_d4_vstream_v2_pw112 u_pw112 (
        .clk(clk), .rst_n(rst_n), .valid_in(pw_fire), .ready_in(pw112_ready),
        .first_k(pw_first_k), .last_k(pw_last_k), .k_idx(pw_k_idx),
        .pixel_mask(pw_pixel_mask[6:0]), .cout_mask(pw_cout_mask),
        .act_vec(pw_act_7pixel_vec), .wgt_vec(pw_wgt_vec), .ready_out(1'b1),
        .valid_out(pw112_valid), .psum_out(pw112_psum),
        .lane_mask_out(pw112_mask)
    );
    /* PW can accept only when both portions of the 128-lane tile accept. RQ
     * is allowed to use the pool as soon as the common output has capacity. */
    assign op_ready = rst_n && pool_ready && (op_mode_rq || pw112_ready);

    /* The pool's PW result is the eighth pixel. Accumulate it to the same
     * k-boundary as the dedicated seven-pixel island. */
    reg signed [16*32-1:0] pool_acc;
    reg signed [16*32-1:0] pool_final_hold;
    reg [15:0] pool_final_mask_hold;
    reg [31:0] pool_final_meta_hold;
    reg pool_final_valid;
    reg signed [112*32-1:0] pw112_final_hold;
    reg [111:0] pw112_final_mask_hold;
    reg pw112_final_valid;
    integer i;
    wire pool_pw_event = pool_valid && !pool_mode;
    wire pool_first = pool_pw_event && (pool_metadata[5:0] == 0);
    /* Expand has K=16; project has K=32.  Do not mark k=15 as final for the
     * project stream: the dedicated island finishes at k=31 considerably
     * earlier than the elastic pool, and an early combine would publish a
     * stale k=15 pool accumulator. */
    wire pool_last = pool_pw_event &&
        (pool_metadata[24] ? (pool_metadata[5:0] == 6'd31) :
                             (pool_metadata[5:0] == 6'd15));
    always @(posedge clk) begin
        if (!rst_n) begin
            pool_acc <= 512'sd0; pool_final_hold <= 512'sd0;
            pool_final_mask_hold <= 16'd0; pool_final_meta_hold <= 32'd0;
            pool_final_valid <= 1'b0; pw112_final_hold <= 3584'sd0;
            pw112_final_mask_hold <= 112'd0; pw112_final_valid <= 1'b0;
            out_valid <= 1'b0; out_mode_rq <= 1'b0;
            pw_psum_vec <= 4096'sd0; pw_lane_mask <= 128'd0;
            rq_product_vec <= 256'sd0; rq_result_vec <= 32'sd0;
            metadata_out <= 32'd0;
            for (i=0;i<16;i=i+1) pool_acc[i*32 +: 32] <= 32'sd0;
        end else begin
            if (out_valid && out_ready) out_valid <= 1'b0;
            if (pool_pw_event) begin
                for (i=0;i<16;i=i+1)
                    pool_acc[i*32 +: 32] <= pool_first
                        ? {{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]}
                        : pool_acc[i*32 +:32] +
                          {{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]};
                if (pool_last) begin
                    for (i=0;i<16;i=i+1)
                        pool_final_hold[i*32 +:32] <= pool_first
                            ? {{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]}
                            : pool_acc[i*32 +:32] +
                              {{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]};
                    pool_final_mask_hold <= 16'hffff;
                    pool_final_meta_hold <= pool_metadata;
                    pool_final_valid <= 1'b1;
                end
            end
            if (pw112_valid) begin
                pw112_final_hold <= pw112_psum;
                pw112_final_mask_hold <= pw112_mask;
                pw112_final_valid <= 1'b1;
            end
            if (pool_final_valid && pw112_final_valid && output_space) begin
                for (i=0;i<112;i=i+1)
                    pw_psum_vec[i*32 +:32] <= pw112_final_hold[i*32 +:32];
                for (i=0;i<16;i=i+1)
                    pw_psum_vec[(112+i)*32 +:32] <= pool_final_hold[i*32 +:32];
                pw_lane_mask <= {pool_final_mask_hold,pw112_final_mask_hold};
                metadata_out <= pool_final_meta_hold;
                out_mode_rq <= 1'b0; out_valid <= 1'b1;
                pool_final_valid <= 1'b0; pw112_final_valid <= 1'b0;
            end
            if (pool_valid && pool_mode && output_space) begin
                rq_product_vec <= pool_rq_product;
                rq_result_vec <= pool_rq_result;
                metadata_out <= pool_metadata;
                out_mode_rq <= 1'b1; out_valid <= 1'b1;
            end
        end
    end

    /* Standalone DW16 tile. Its 16 DW cells are the only DW arithmetic; the
     * two scheduler cells below are explicit DSP resources for address/tap
     * scheduling and do not carry data-path results. */
    edgembconv_hwacandidate_d4_dw16_stream_tile u_dw16 (
        .clk(clk), .rst_n(rst_n), .cfg_valid(dw_cfg_valid), .cfg_ready(dw_cfg_ready),
        .cfg_kind(2'd0), .cfg_addr(dw_cfg_addr), .cfg_data({24'd0,dw_cfg_data}),
        .start_valid(dw_start_valid), .start_ready(dw_start_ready),
        .start_in_w(dw_in_w), .start_in_h(dw_in_h), .start_out_w(8'd16),
        .start_out_h(8'd16), .start_stride(dw_stride), .start_tile_x(dw_out_x),
        .start_tile_y(dw_out_y), .start_tile_w(4'd1), .start_tile_h(4'd1),
        .start_channel_base(8'd0), .start_channel_mask(16'hffff),
        .start_padding_value(8'sd0), .start_output_zero_point(32'sd0),
        .start_activation_min(-32'sd2147483647),
        .start_activation_max(32'sd2147483647), .start_epoch(4'd0),
        .start_metadata(dw_metadata_in), .src_req_valid(dw_src_req_valid),
        .src_req_ready(dw_src_req_ready), .src_req_addr(dw_src_req_addr),
        .src_req_pixel_idx(), .src_req_tap_idx(), .src_req_first_tap(),
        .src_req_last_tap(), .src_req_metadata(), .src_resp_valid(dw_src_resp_valid),
        .src_resp_ready(dw_src_resp_ready), .src_resp_data(dw_src_resp_data),
        .out_ready(dw_out_ready), .out_valid(dw_out_valid), .out_data_vec(),
        .out_raw_psum_vec(dw_raw_psum_vec), .out_pixel_idx(),
        .out_channel_base(), .out_lane_mask(), .out_first(), .out_last(),
        .out_metadata(dw_metadata_out), .done_valid(dw_done), .done_ready(1'b1),
        .done_epoch(), .busy(), .cycle_count(), .tap_count(),
        .source_word_count(), .source_stall_count(), .output_stall_count(),
        .protocol_errors()
    );
    wire signed [24:0] sched_a = 25'sd0;
    wire signed [17:0] sched_b = 18'sd0;
    (* keep_hierarchy = "yes", dont_touch = "yes" *)
    edgembconv_hwacandidate_d4_dsp_pool_dsp u_dw_sched0 (
        .clk(clk),.rst_n(rst_n),.a_in(sched_a),.b_in(sched_b),.p_out()
    );
    (* keep_hierarchy = "yes", dont_touch = "yes" *)
    edgembconv_hwacandidate_d4_dsp_pool_dsp u_dw_sched1 (
        .clk(clk),.rst_n(rst_n),.a_in(sched_a),.b_in(sched_b),.p_out()
    );
endmodule

/* Correctly aligned seven-pixel PW island.  The DSP inputs are driven
 * directly from the accepted request.  The older extracted island inserted
 * an extra operand register, so its product register and token tag could be
 * one cycle apart after a bubble. */
module edgembconv_hwacandidate_d4_vstream_v2_pw112 (
    input wire clk,input wire rst_n,input wire valid_in,output wire ready_in,
    input wire first_k,input wire last_k,input wire [7:0] k_idx,
    input wire [6:0] pixel_mask,input wire [15:0] cout_mask,
    input wire signed [55:0] act_vec,input wire signed [127:0] wgt_vec,
    input wire ready_out,output reg valid_out,
    output reg signed [3583:0] psum_out,output reg [111:0] lane_mask_out
);
    localparam integer LANES=112;
    reg token_valid,token_first,token_last; reg [6:0] token_pixel_mask;
    reg [15:0] token_cout_mask; reg signed [LANES*32-1:0] acc;
    wire input_fire=valid_in&&ready_in;
    assign ready_in=rst_n&&!token_last&&(!valid_out||ready_out);
    wire signed [47:0] dsp_p[0:LANES-1];
    genvar g;
    generate for(g=0;g<LANES;g=g+1) begin: gen_v2_pw_dsp
        localparam integer P=g/16; localparam integer C=g%16;
        wire signed [7:0] a= pixel_mask[P] ? $signed(act_vec[P*8 +:8]) : 8'sd0;
        wire signed [7:0] b= cout_mask[C] ? $signed(wgt_vec[C*8 +:8]) : 8'sd0;
        edgembconv_hwacandidate_d4_dsp_pool_dsp u_dsp(.clk(clk),.rst_n(rst_n),
            .a_in({{17{a[7]}},a}),.b_in({{10{b[7]}},b}),.p_out(dsp_p[g]));
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if(!rst_n) begin
            token_valid<=0;token_first<=0;token_last<=0;token_pixel_mask<=0;
            token_cout_mask<=0;valid_out<=0;psum_out<=0;lane_mask_out<=0;acc<=0;
        end else begin
            if(valid_out&&ready_out) valid_out<=0;
            for(i=0;i<LANES;i=i+1) begin
                if(token_valid) begin
                    if(token_first) acc[i*32 +:32]<=dsp_p[i];
                    else acc[i*32 +:32]<=acc[i*32 +:32]+dsp_p[i];
                    if(token_last) psum_out[i*32 +:32]<=token_first
                        ? dsp_p[i][31:0] : acc[i*32 +:32]+dsp_p[i];
                end
            end
            if(token_valid&&token_last) begin
                valid_out<=1;
                for(i=0;i<LANES;i=i+1)
                    lane_mask_out[i]<=token_pixel_mask[i/16]&&token_cout_mask[i%16];
            end
            token_valid<=input_fire;
            if(input_fire) begin
                token_first<=first_k;token_last<=last_k;
                token_pixel_mask<=pixel_mask;token_cout_mask<=cout_mask;
            end else begin token_first<=0;token_last<=0; end
        end
    end
endmodule
`default_nettype wire
