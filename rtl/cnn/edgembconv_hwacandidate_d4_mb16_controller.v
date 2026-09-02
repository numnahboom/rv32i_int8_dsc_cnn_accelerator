`timescale 1ns/1ps
`default_nettype none

/*
 * D4 mb16_down block controller backed by the physical composite datapath.
 *
 * This is an independent integration gate.  It is intentionally a complete
 * 32x32x16 -> 16x16x32 stride-2 transaction, not a datapath-only unit:
 *
 *   PW(expand) -> local scratch0 -> DW16 -> local scratch1 -> PW(project)
 *
 * The controller reuses one composite instance for every phase.  In
 * particular, all PW products, DW products, and INT32->INT8 requantization
 * transactions pass through edgembconv_hwacandidate_d4_composite_datapath;
 * no second arithmetic island is hidden in this controller.  Scratch bank
 * state transitions are explicit FREE/FILL/READY/ACTIVE fences.  The source
 * read-ready input is a controllable local-scratch backpressure point so the
 * testbench can exercise a registered read response with randomized stalls.
 */
module edgembconv_hwacandidate_d4_mb16_controller #(
    parameter integer INPUT_BYTES = 32*32*16,
    parameter integer EXP_BYTES = 32*32*32,
    parameter integer DW_OUT_BYTES = 16*16*32,
    parameter integer OUTPUT_BYTES = 16*16*32,
    parameter integer PW_WEIGHT_BYTES = 4096,
    parameter integer DW_WEIGHT_BYTES = 288,
    parameter integer CFG_ADDR_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,

    input wire cfg_valid,
    output wire cfg_ready,
    input wire [2:0] cfg_kind,
    input wire [CFG_ADDR_WIDTH-1:0] cfg_addr,
    input wire [31:0] cfg_data,

    input wire start_valid,
    output wire start_ready,
    input wire [3:0] start_epoch,
    output reg done_valid,
    input wire done_ready,
    output reg [3:0] done_epoch,

    output wire out_valid,
    input wire out_ready,
    output wire [15:0] out_index,
    output wire signed [7:0] out_data,

    output wire busy,
    output wire [1:0] scratch0_state,
    output wire [1:0] scratch1_state,
    output wire [3:0] active_epoch,
    output reg [31:0] cycle_count,
    output reg [31:0] pw_mac_count,
    output reg [31:0] dw_mac_count,
    output reg [31:0] overlap_cycles,
    output reg [31:0] protocol_errors,

    /* Backpressure at the local scratch read port used by the DW scheduler. */
    input wire scratch_read_ready
);
    localparam [2:0] CFG_INPUT = 3'd0;
    localparam [2:0] CFG_PW_WEIGHT = 3'd1;
    localparam [2:0] CFG_DW_WEIGHT = 3'd2;
    localparam [2:0] CFG_BIAS = 3'd3;
    localparam [2:0] CFG_MULTIPLIER = 3'd4;
    localparam [2:0] CFG_SHIFT = 3'd5;

    localparam [1:0] BANK_FREE = 2'd0;
    localparam [1:0] BANK_FILL = 2'd1;
    localparam [1:0] BANK_READY = 2'd2;
    localparam [1:0] BANK_ACTIVE = 2'd3;

    /* Shell-compatible parameter slots: block 1 uses op2/op3 and DW slot 1. */
    localparam integer EXP_WEIGHT_BASE = 2048;
    localparam integer PROJ_WEIGHT_BASE = 3072;
    localparam integer EXP_PARAM_BASE = 64;
    localparam integer PROJ_PARAM_BASE = 96;
    localparam integer DW_PARAM_BASE = 160;
    localparam integer DW_WEIGHT_BASE = 0;

    localparam [4:0] ST_IDLE = 5'd0;
    localparam [4:0] ST_EXP_PW = 5'd1;
    localparam [4:0] ST_EXP_PW_WAIT = 5'd2;
    localparam [4:0] ST_EXP_RQ = 5'd3;
    localparam [4:0] ST_DW_CFG = 5'd4;
    localparam [4:0] ST_DW_START = 5'd5;
    localparam [4:0] ST_DW_WAIT = 5'd6;
    localparam [4:0] ST_DW_RQ = 5'd7;
    localparam [4:0] ST_PROJ_PW = 5'd8;
    localparam [4:0] ST_PROJ_PW_WAIT = 5'd9;
    localparam [4:0] ST_PROJ_RQ = 5'd10;
    localparam [4:0] ST_OUTPUT = 5'd11;
    localparam [4:0] ST_DONE = 5'd12;

    (* ram_style = "block" *) reg signed [7:0] input_mem [0:INPUT_BYTES-1];
    (* ram_style = "block" *) reg signed [7:0] scratch0 [0:EXP_BYTES-1];
    (* ram_style = "block" *) reg signed [7:0] scratch1 [0:DW_OUT_BYTES-1];
    (* ram_style = "block" *) reg signed [7:0] output_mem [0:OUTPUT_BYTES-1];
    reg signed [7:0] pw_weight_mem [0:PW_WEIGHT_BYTES-1];
    reg signed [7:0] dw_weight_mem [0:DW_WEIGHT_BYTES-1];
    reg signed [31:0] bias_mem [0:192-1];
    reg signed [31:0] multiplier_mem [0:192-1];
    reg [7:0] shift_mem [0:192-1];

    reg [4:0] state;
    reg [3:0] epoch_reg;
    reg [1:0] bank0_state_reg, bank1_state_reg;
    reg [31:0] output_cursor;

    /* PW coordinates.  Every tile is eight pixels x sixteen output lanes. */
    reg pw_phase_project;
    reg [5:0] pw_y, pw_x;
    reg pw_group;
    reg [5:0] pw_k;
    reg [7:0] rq_base;
    reg [4095:0] pw_capture;

    /* DW coordinate/group and composite configuration cursor. */
    reg [4:0] dw_y, dw_x;
    reg dw_group;
    reg [7:0] dw_cfg_idx;
    reg [511:0] dw_capture;

    /* One-outstanding registered read response for the composite DW island. */
    reg scratch_read_pending;
    reg [31:0] scratch_read_addr_reg;

    integer i, p, c, q;
    integer source_idx, weight_idx, param_idx, flat_lane, lane_pixel, lane_c;
    integer scratch_idx, output_idx;
    integer dw_source_idx;

    function integer pw_src_addr;
        input integer y; input integer x; input integer k; input integer cin;
        begin pw_src_addr = (y * 32 + x) * cin + k; end
    endfunction
    function integer pw_addr;
        input integer y; input integer x; input integer ch; input integer cout;
        begin pw_addr = (y * 16 + x) * cout + ch; end
    endfunction

    /* The composite has a four-lane exact RQ transaction. */
    /* Do not present the next RQ request on the same edge that the current
     * composite result is being observed.  The composite intentionally
     * permits ready/valid replacement when ready_out=1; without this local
     * fence the controller would accept the old RQ operands once more before
     * advancing rq_base, shifting every subsequent four-lane group. */
    wire comp_op_ready;
    reg [55:0] comp_pw_act_7;
    reg [127:0] comp_pw_act_pool, comp_pw_wgt;
    reg [7:0] comp_pw_pixel_mask;
    reg [15:0] comp_pw_cout_mask;
    reg comp_pw_first, comp_pw_last;
    reg [7:0] comp_pw_k_idx;
    reg signed [127:0] comp_rq_acc, comp_rq_multiplier;
    reg [23:0] comp_rq_shift;
    reg signed [127:0] comp_rq_zp, comp_rq_min, comp_rq_max;
    reg [31:0] comp_metadata;
    wire comp_out_valid, comp_out_mode_rq;
    wire signed [4095:0] comp_pw_psum;
    wire [127:0] comp_pw_lane_mask;
    wire signed [255:0] comp_rq_product;
    wire signed [31:0] comp_rq_result;
    wire [31:0] comp_metadata_out;
    wire comp_op_mode_rq = (state == ST_EXP_RQ) || (state == ST_DW_RQ) ||
                            (state == ST_PROJ_RQ);
    wire comp_op_valid = (state == ST_EXP_PW) || (state == ST_PROJ_PW) ||
                         (((state == ST_EXP_RQ) || (state == ST_DW_RQ) ||
                           (state == ST_PROJ_RQ)) && !comp_out_valid);

    reg comp_dw_cfg_valid;
    wire comp_dw_cfg_ready;
    reg [7:0] comp_dw_cfg_addr;
    reg signed [7:0] comp_dw_cfg_data;
    reg comp_dw_start_valid;
    wire comp_dw_start_ready;
    reg [7:0] comp_dw_in_w, comp_dw_in_h, comp_dw_out_x, comp_dw_out_y;
    reg [1:0] comp_dw_stride;
    reg [31:0] comp_dw_metadata;
    wire comp_dw_src_req_valid;
    reg comp_dw_src_req_ready;
    wire [31:0] comp_dw_src_req_addr;
    reg comp_dw_src_resp_valid;
    wire comp_dw_src_resp_ready;
    reg [127:0] comp_dw_src_resp_data;
    reg comp_dw_out_ready;
    wire comp_dw_out_valid;
    wire signed [511:0] comp_dw_raw_psum;
    wire [31:0] comp_dw_metadata_out;
    wire comp_dw_done;

    edgembconv_hwacandidate_d4_composite_datapath u_composite (
        .clk(clk), .rst_n(rst_n), .op_mode_rq(comp_op_mode_rq),
        .op_valid(comp_op_valid), .op_ready(comp_op_ready),
        .pw_act_7pixel_vec(comp_pw_act_7), .pw_act_pool_vec(comp_pw_act_pool),
        .pw_wgt_vec(comp_pw_wgt), .pw_pixel_mask(comp_pw_pixel_mask),
        .pw_cout_mask(comp_pw_cout_mask), .pw_first_k(comp_pw_first),
        .pw_last_k(comp_pw_last), .pw_k_idx(comp_pw_k_idx),
        .rq_acc_vec(comp_rq_acc), .rq_multiplier_vec(comp_rq_multiplier),
        .rq_shift_vec(comp_rq_shift), .rq_zero_point_vec(comp_rq_zp),
        .rq_min_vec(comp_rq_min), .rq_max_vec(comp_rq_max),
        .metadata_in(comp_metadata), .out_ready(1'b1),
        .out_valid(comp_out_valid), .out_mode_rq(comp_out_mode_rq),
        .pw_psum_vec(comp_pw_psum), .pw_lane_mask(comp_pw_lane_mask),
        .rq_product_vec(comp_rq_product), .rq_result_vec(comp_rq_result),
        .metadata_out(comp_metadata_out), .dw_cfg_valid(comp_dw_cfg_valid),
        .dw_cfg_ready(comp_dw_cfg_ready), .dw_cfg_addr(comp_dw_cfg_addr),
        .dw_cfg_data(comp_dw_cfg_data), .dw_start_valid(comp_dw_start_valid),
        .dw_start_ready(comp_dw_start_ready), .dw_in_w(comp_dw_in_w),
        .dw_in_h(comp_dw_in_h), .dw_out_x(comp_dw_out_x),
        .dw_out_y(comp_dw_out_y), .dw_stride(comp_dw_stride),
        .dw_metadata_in(comp_dw_metadata),
        .dw_src_req_valid(comp_dw_src_req_valid),
        .dw_src_req_ready(comp_dw_src_req_ready),
        .dw_src_req_addr(comp_dw_src_req_addr),
        .dw_src_resp_valid(comp_dw_src_resp_valid),
        .dw_src_resp_ready(comp_dw_src_resp_ready),
        .dw_src_resp_data(comp_dw_src_resp_data),
        .dw_out_ready(comp_dw_out_ready), .dw_out_valid(comp_dw_out_valid),
        .dw_raw_psum_vec(comp_dw_raw_psum),
        .dw_metadata_out(comp_dw_metadata_out), .dw_done(comp_dw_done)
    );

    assign cfg_ready = rst_n && (state == ST_IDLE) && !done_valid;
    assign start_ready = rst_n && (state == ST_IDLE) && !done_valid;
    assign busy = rst_n && (state != ST_IDLE) && (state != ST_DONE);
    assign scratch0_state = bank0_state_reg;
    assign scratch1_state = bank1_state_reg;
    assign active_epoch = epoch_reg;
    assign out_valid = (state == ST_OUTPUT);
    assign out_index = output_cursor[15:0];
    assign out_data = output_mem[output_cursor];

    wire cfg_fire = cfg_valid && cfg_ready;
    wire start_fire = start_valid && start_ready;
    wire pw_fire = comp_op_valid && comp_op_ready && !comp_op_mode_rq;
    wire rq_fire = comp_op_valid && comp_op_ready && comp_op_mode_rq;

    /* PW issue operands are generated solely from the selected local bank. */
    always @* begin
        comp_pw_act_7 = 56'd0;
        comp_pw_act_pool = 128'd0;
        comp_pw_wgt = 128'd0;
        comp_pw_pixel_mask = 8'hff;
        comp_pw_cout_mask = 16'hffff;
        comp_pw_first = (pw_k == 0);
        comp_pw_last = pw_phase_project ? (pw_k == 31) : (pw_k == 15);
        comp_pw_k_idx = pw_k;
        comp_metadata = {pw_phase_project, pw_y, pw_x, pw_group, pw_k};
        source_idx = 0;
        weight_idx = 0;
        if ((state == ST_EXP_PW) || (state == ST_PROJ_PW)) begin
            for (p = 0; p < 7; p = p + 1) begin
                source_idx = pw_src_addr(pw_y, pw_x + p, pw_k,
                    pw_phase_project ? 32 : 16);
                if (pw_phase_project)
                    comp_pw_act_7[p*8 +: 8] = scratch1[
                        (pw_y*16 + pw_x + p)*32 + pw_k];
                else begin
                    comp_pw_act_7[p*8 +: 8] = input_mem[source_idx];
                end
            end
            /* The shared pool represents the eighth pixel and has sixteen
             * copies of that activation, one for each Cout DSP. */
            for (c = 0; c < 16; c = c + 1)
                comp_pw_act_pool[c*8 +: 8] = pw_phase_project
                    ? scratch1[(pw_y*16 + pw_x + 7)*32 + pw_k]
                    : input_mem[pw_src_addr(pw_y, pw_x + 7, pw_k, 16)];
            for (c = 0; c < 16; c = c + 1) begin
                weight_idx = (pw_phase_project ? PROJ_WEIGHT_BASE : EXP_WEIGHT_BASE)
                    + pw_group*16* (pw_phase_project ? 32 : 16) + pw_k
                    + c * (pw_phase_project ? 32 : 16);
                comp_pw_wgt[c*8 +: 8] = pw_weight_mem[weight_idx];
            end
        end
    end

    /* RQ operands are selected from the just-completed PW tile or DW vector. */
    always @* begin
        comp_rq_acc = 128'd0;
        comp_rq_multiplier = 128'd0;
        comp_rq_shift = 24'd0;
        comp_rq_zp = 128'd0;
        comp_rq_min = 128'd0;
        comp_rq_max = 128'd0;
        flat_lane = 0; lane_c = 0; param_idx = 0; lane_pixel = 0;
        if ((state == ST_EXP_RQ) || (state == ST_PROJ_RQ)) begin
            for (q = 0; q < 4; q = q + 1) begin
                flat_lane = rq_base + q;
                lane_pixel = flat_lane / 16;
                lane_c = flat_lane % 16;
                param_idx = (pw_phase_project ? PROJ_PARAM_BASE : EXP_PARAM_BASE)
                    + pw_group*16 + lane_c;
                comp_rq_acc[q*32 +: 32] = pw_capture[flat_lane*32 +: 32]
                    + bias_mem[param_idx];
                comp_rq_multiplier[q*32 +: 32] = multiplier_mem[param_idx];
                comp_rq_shift[q*6 +: 6] = shift_mem[param_idx][5:0];
                comp_rq_min[q*32 +: 32] = pw_phase_project ? -128 : 0;
                comp_rq_max[q*32 +: 32] = pw_phase_project ? 127 : 127;
            end
        end else if (state == ST_DW_RQ) begin
            for (q = 0; q < 4; q = q + 1) begin
                lane_c = rq_base + q;
                param_idx = DW_PARAM_BASE + dw_group*16 + lane_c;
                comp_rq_acc[q*32 +: 32] = dw_capture[lane_c*32 +: 32]
                    + bias_mem[param_idx];
                comp_rq_multiplier[q*32 +: 32] = multiplier_mem[param_idx];
                comp_rq_shift[q*6 +: 6] = shift_mem[param_idx][5:0];
                comp_rq_min[q*32 +: 32] = 0;
                comp_rq_max[q*32 +: 32] = 127;
            end
        end
    end

    /* The DW source adapter is a registered local-scratch read port. */
    always @* begin
        comp_dw_src_req_ready = scratch_read_ready && (state == ST_DW_WAIT);
        comp_dw_src_resp_valid = scratch_read_pending;
        comp_dw_src_resp_data = 128'd0;
        dw_source_idx = scratch_read_addr_reg * 32 + dw_group*16;
        for (q = 0; q < 16; q = q + 1)
            comp_dw_src_resp_data[q*8 +: 8] = scratch0[dw_source_idx + q];
        comp_dw_out_ready = (state == ST_DW_WAIT);
    end

    /* DW configuration/start operands. */
    always @* begin
        comp_dw_cfg_valid = (state == ST_DW_CFG);
        comp_dw_cfg_addr = dw_cfg_idx;
        comp_dw_cfg_data = dw_weight_mem[dw_group*144 + dw_cfg_idx];
        comp_dw_start_valid = (state == ST_DW_START);
        comp_dw_in_w = 32; comp_dw_in_h = 32;
        comp_dw_out_x = dw_x; comp_dw_out_y = dw_y;
        comp_dw_stride = 2; comp_dw_metadata = {dw_group, dw_y, dw_x};
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            done_valid <= 1'b0;
            done_epoch <= 0;
            epoch_reg <= 0;
            bank0_state_reg <= BANK_FREE;
            bank1_state_reg <= BANK_FREE;
            output_cursor <= 0;
            pw_phase_project <= 0; pw_y <= 0; pw_x <= 0; pw_group <= 0; pw_k <= 0;
            rq_base <= 0; pw_capture <= 0; dw_capture <= 0;
            dw_y <= 0; dw_x <= 0; dw_group <= 0; dw_cfg_idx <= 0;
            scratch_read_pending <= 0; scratch_read_addr_reg <= 0;
            cycle_count <= 0; pw_mac_count <= 0; dw_mac_count <= 0;
            overlap_cycles <= 0; protocol_errors <= 0;
        end else begin
            if (busy) cycle_count <= cycle_count + 1'b1;
            done_valid <= 1'b0;

            /* Host configuration is accepted only while the transaction is idle. */
            if (cfg_fire) begin
                case (cfg_kind)
                    CFG_INPUT: if (cfg_addr < INPUT_BYTES) input_mem[cfg_addr] <= cfg_data[7:0];
                    CFG_PW_WEIGHT: if (cfg_addr < PW_WEIGHT_BYTES) pw_weight_mem[cfg_addr] <= cfg_data[7:0];
                    CFG_DW_WEIGHT: if (cfg_addr < DW_WEIGHT_BYTES) dw_weight_mem[cfg_addr] <= cfg_data[7:0];
                    CFG_BIAS: if (cfg_addr < 192) bias_mem[cfg_addr] <= cfg_data;
                    CFG_MULTIPLIER: if (cfg_addr < 192) multiplier_mem[cfg_addr] <= cfg_data;
                    CFG_SHIFT: if (cfg_addr < 192) shift_mem[cfg_addr] <= cfg_data[7:0];
                    default: protocol_errors <= protocol_errors + 1'b1;
                endcase
            end

            if (start_fire) begin
                epoch_reg <= start_epoch;
                done_epoch <= start_epoch;
                bank0_state_reg <= BANK_FILL;
                bank1_state_reg <= BANK_FREE;
                pw_phase_project <= 1'b0;
                pw_y <= 0; pw_x <= 0; pw_group <= 0; pw_k <= 0; rq_base <= 0;
                dw_y <= 0; dw_x <= 0; dw_group <= 0; dw_cfg_idx <= 0;
                output_cursor <= 0;
                state <= ST_EXP_PW;
            end else begin
                case (state)
                    ST_EXP_PW: begin
                        if (pw_fire) begin
                            pw_mac_count <= pw_mac_count + 128;
                            if (pw_k == 15) begin
                                state <= ST_EXP_PW_WAIT;
                            end else pw_k <= pw_k + 1'b1;
                        end
                    end
                    ST_EXP_PW_WAIT: begin
                        if (comp_out_valid && !comp_out_mode_rq) begin
                            pw_capture <= comp_pw_psum;
                            rq_base <= 0;
                            state <= ST_EXP_RQ;
                        end
                    end
                    ST_EXP_RQ: begin
                        if (rq_fire) begin
                            /* Composite RQ output is visible after its registered pipeline. */
                        end
                        if (comp_out_valid && comp_out_mode_rq) begin
                            for (q = 0; q < 4; q = q + 1) begin
                                scratch_idx = (pw_y*32 + pw_x + (rq_base+q)/16)*32
                                    + pw_group*16 + (rq_base+q)%16;
                                scratch0[scratch_idx] <= comp_rq_result[q*8 +: 8];
                            end
                            if (rq_base == 124) begin
                                rq_base <= 0;
                                if (pw_group == 0) begin
                                    pw_group <= 1'b1; pw_k <= 0; state <= ST_EXP_PW;
                                end else if (pw_x == 24) begin
                                    pw_group <= 0; pw_k <= 0; pw_x <= 0;
                                    if (pw_y == 31) begin
                                        bank0_state_reg <= BANK_READY;
                                        bank1_state_reg <= BANK_FILL;
                                        dw_y <= 0; dw_x <= 0; dw_group <= 0;
                                        dw_cfg_idx <= 0; state <= ST_DW_CFG;
                                    end else begin
                                        pw_y <= pw_y + 1'b1; state <= ST_EXP_PW;
                                    end
                                end else begin
                                    pw_x <= pw_x + 8; pw_group <= 0;
                                    pw_k <= 0; state <= ST_EXP_PW;
                                end
                            end else rq_base <= rq_base + 4;
                        end
                    end
                    ST_DW_CFG: begin
                        if (dw_group == 0 && dw_cfg_idx == 0)
                            bank0_state_reg <= BANK_ACTIVE;
                        if (comp_dw_cfg_valid && comp_dw_cfg_ready) begin
                            if (dw_cfg_idx == 143) begin
                                dw_cfg_idx <= 0; state <= ST_DW_START;
                            end else dw_cfg_idx <= dw_cfg_idx + 1'b1;
                        end
                    end
                    ST_DW_START: begin
                        if (comp_dw_start_valid && comp_dw_start_ready)
                            state <= ST_DW_WAIT;
                    end
                    ST_DW_WAIT: begin
                        if (comp_dw_src_req_valid && comp_dw_src_req_ready) begin
                            scratch_read_pending <= 1'b1;
                            scratch_read_addr_reg <= comp_dw_src_req_addr;
                        end
                        if (comp_dw_src_resp_valid && comp_dw_src_resp_ready)
                            scratch_read_pending <= 1'b0;
                        if (comp_dw_out_valid) begin
                            dw_capture <= comp_dw_raw_psum;
                            dw_mac_count <= dw_mac_count + 144;
                            rq_base <= 0;
                            state <= ST_DW_RQ;
                        end
                    end
                    ST_DW_RQ: begin
                        if (comp_out_valid && comp_out_mode_rq) begin
                            for (q = 0; q < 4; q = q + 1) begin
                                output_idx = (dw_y*16 + dw_x)*32 + dw_group*16
                                    + rq_base + q;
                                scratch1[output_idx] <= comp_rq_result[q*8 +: 8];
                            end
                            if (rq_base == 12) begin
                                rq_base <= 0;
                                if (dw_group == 0) begin
                                    dw_group <= 1'b1; dw_cfg_idx <= 0; state <= ST_DW_CFG;
                                end else if (dw_x == 15) begin
                                    dw_group <= 0; dw_x <= 0;
                                    if (dw_y == 15) begin
                                        bank0_state_reg <= BANK_FREE;
                                        bank1_state_reg <= BANK_READY;
                                        pw_phase_project <= 1'b1;
                                        pw_y <= 0; pw_x <= 0; pw_group <= 0; pw_k <= 0;
                                        state <= ST_PROJ_PW;
                                    end else begin
                                        dw_y <= dw_y + 1'b1; state <= ST_DW_CFG;
                                    end
                                end else begin
                                    /* A coordinate has two 16-channel DW
                                     * groups.  Return to group zero before
                                     * advancing x; the previous version
                                     * accidentally ran group one for every
                                     * x>0 and therefore completed only
                                     * 272/512 vectors. */
                                    dw_group <= 1'b0;
                                    dw_x <= dw_x + 1'b1; state <= ST_DW_CFG;
                                end
                            end else rq_base <= rq_base + 4;
                        end
                    end
                    ST_PROJ_PW: begin
                        if (pw_k == 0)
                            bank1_state_reg <= BANK_ACTIVE;
                        if (pw_fire) begin
                            pw_mac_count <= pw_mac_count + 128;
                            if (pw_k == 31) state <= ST_PROJ_PW_WAIT;
                            else pw_k <= pw_k + 1'b1;
                        end
                    end
                    ST_PROJ_PW_WAIT: begin
                        if (comp_out_valid && !comp_out_mode_rq) begin
                            pw_capture <= comp_pw_psum;
                            rq_base <= 0; state <= ST_PROJ_RQ;
                        end
                    end
                    ST_PROJ_RQ: begin
                        if (comp_out_valid && comp_out_mode_rq) begin
                            for (q = 0; q < 4; q = q + 1) begin
                                output_idx = (pw_y*16 + pw_x + (rq_base+q)/16)*32
                                    + pw_group*16 + (rq_base+q)%16;
                                output_mem[output_idx] <= comp_rq_result[q*8 +: 8];
                            end
                            if (rq_base == 124) begin
                                rq_base <= 0;
                                if (pw_group == 0) begin
                                    pw_group <= 1; pw_k <= 0; state <= ST_PROJ_PW;
                                end else if (pw_x == 8) begin
                                    pw_group <= 0; pw_x <= 0; pw_k <= 0;
                                    if (pw_y == 15) begin
                                        bank1_state_reg <= BANK_FREE;
                                        output_cursor <= 0; state <= ST_OUTPUT;
                                    end else begin
                                        pw_y <= pw_y + 1'b1; state <= ST_PROJ_PW;
                                    end
                                end else begin
                                    pw_x <= pw_x + 8; pw_group <= 0;
                                    pw_k <= 0; state <= ST_PROJ_PW;
                                end
                            end else rq_base <= rq_base + 4;
                        end
                    end
                    ST_OUTPUT: begin
                        if (out_ready) begin
                            if (output_cursor == OUTPUT_BYTES-1) begin
                                state <= ST_DONE; done_valid <= 1'b1;
                            end else output_cursor <= output_cursor + 1'b1;
                        end
                    end
                    ST_DONE: begin
                        if (done_valid && done_ready) begin
                            bank0_state_reg <= BANK_FREE;
                            bank1_state_reg <= BANK_FREE;
                            state <= ST_IDLE;
                        end
                    end
                    default: state <= ST_IDLE;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
