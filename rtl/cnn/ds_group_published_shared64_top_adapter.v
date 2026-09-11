`timescale 1ns/1ps
`default_nettype none

/*
 * Descriptor-facing production boundary for the group-published shared64
 * DS backend.
 *
 * cnn_top already owns descriptor fetch and the feature-SRAM ping-pong
 * boundary.  This wrapper owns only the DS descriptor transaction: it reads
 * the canonical scalar/packed configuration arrays from the external 32-bit
 * bus, presents the adapter's scalar configuration ABI, and translates the
 * adapter's byte-addressed source/output word ports to feature SRAM.
 *
 * The wrapper is deliberately independent of cnn_layer_runner's DS FSM.  A
 * top build selecting USE_GROUP_SHARED64_DS omits the legacy DS engine at
 * elaboration and routes every OP_DS_BLOCK descriptor here.  Stem, GAP and
 * FC descriptors continue to use cnn_layer_runner.
 */
module ds_group_published_shared64_top_adapter #(
    parameter integer ADDR_WIDTH = 24,
    parameter integer SRAM_ADDR_WIDTH = 15,
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 256,
    parameter integer FIFO_DEPTH = 8
) (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [7:0] desc_layer,
    input wire [1023:0] desc_words,
    /* A descriptor look-ahead may arrive while the current DS layer is
     * running.  Its configuration is loaded into the inactive physical bank
     * and becomes the next layer's active bank at start. */
    input wire prefetch_valid,
    input wire [7:0] prefetch_layer,
    input wire [1023:0] prefetch_desc_words,
    /* The descriptor fetcher holds valid for one cycle only.  Keep the
     * current layer's completion fence open until that fetch has drained so
     * a late look-ahead cannot race the next foreground descriptor bus. */
    input wire prefetch_busy,

    output wire busy,
    output reg done,
    output wire error,

    output wire mem_req_valid,
    output wire mem_req_write,
    output wire [31:0] mem_req_addr,
    output wire [31:0] mem_req_wdata,
    input wire mem_req_ready,
    input wire mem_resp_valid,
    input wire [31:0] mem_resp_rdata,

    output wire sram_input_rd_en,
    output wire [SRAM_ADDR_WIDTH-1:0] sram_input_rd_addr,
    input wire sram_input_rd_valid,
    input wire signed [7:0] sram_input_rd_data,
    output wire sram_input_rd_word_en,
    output wire [SRAM_ADDR_WIDTH-1:0] sram_input_rd_word_addr,
    input wire sram_input_rd_word_valid,
    input wire [31:0] sram_input_rd_word_data,

    output wire sram_output_wr_en,
    output wire [SRAM_ADDR_WIDTH-1:0] sram_output_wr_addr,
    output wire signed [7:0] sram_output_wr_data,
    output wire sram_output_wr4_en,
    output wire [SRAM_ADDR_WIDTH-1:0] sram_output_wr4_addr,
    output wire [31:0] sram_output_wr4_data,
    output wire [3:0] sram_output_wr4_be,
    /* The feature-SRAM boundary is a one-entry elastic sink.  Production
     * cnn_top ties this high; directed benches may hold it low to prove that
     * the command and the layer completion fence remain stable. */
    input wire sram_output_wr_ready,
    input wire sram_output_wr_bank,

    output wire [31:0] perf_cycles,
    output wire [31:0] perf_dw_writes,
    output wire [31:0] perf_descriptors,
    output wire [31:0] perf_pw_tokens,
    output wire [31:0] perf_output_writes,
    output wire [31:0] perf_jobs,
    output wire [31:0] perf_stream_beats,
    output wire [31:0] config_read_count,
    output wire [31:0] config_word_accept_count,
    output wire [31:0] config_scalar_write_count,
    output wire [3:0] profile_state
);
    localparam [31:0] OP_DS_BLOCK = 32'd1;
    localparam integer FLAG_INPUT_FROM_SRAM = 1;
    localparam integer FLAG_OUTPUT_TO_SRAM = 2;
    localparam integer FLAG_TILED_DS_BLOCK = 5;
    localparam integer FLAG_PACKED_WEIGHTS = 7;

    localparam [3:0] CFG_DW_WEIGHT = 4'd1;
    localparam [3:0] CFG_DW_BIAS   = 4'd2;
    localparam [3:0] CFG_DW_MUL    = 4'd3;
    localparam [3:0] CFG_DW_SHIFT  = 4'd4;
    localparam [3:0] CFG_PW_WEIGHT = 4'd5;
    localparam [3:0] CFG_PW_BIAS   = 4'd6;
    localparam [3:0] CFG_PW_MUL    = 4'd7;
    localparam [3:0] CFG_PW_SHIFT  = 4'd8;

    localparam [3:0] ST_IDLE      = 4'd0;
    localparam [3:0] ST_VALIDATE  = 4'd1;
    localparam [3:0] ST_CFG_REQ   = 4'd2;
    localparam [3:0] ST_CFG_WAIT  = 4'd3;
    localparam [3:0] ST_CFG_SEND  = 4'd4;
    localparam [3:0] ST_START     = 4'd5;
    localparam [3:0] ST_RUN       = 4'd6;
    localparam [3:0] ST_FINISH    = 4'd7;
    localparam [3:0] ST_ERROR     = 4'd8;
    localparam [3:0] ST_PREFETCH_WAIT = 4'd9;
    /* A phase's byte geometry is prepared one cycle after its limit is
     * committed.  This keeps the descriptor-derived limit multiplier out of
     * the request/retire cursor cone. */
    localparam [3:0] ST_CFG_PREP  = 4'd10;

    localparam [2:0] PREF_IDLE = 3'd0, PREF_REQ = 3'd1,
                     PREF_WAIT = 3'd2, PREF_SEND = 3'd3,
                     PREF_PREP = 3'd4;

    reg [3:0] state;
    reg error_r;
    reg [7:0] layer_r;
    reg [31:0] input_base_r, output_base_r;
    reg [31:0] dw_weight_base_r, dw_bias_base_r, dw_mul_base_r;
    reg [31:0] dw_shift_base_r, pw_weight_base_r, pw_bias_base_r;
    reg [31:0] pw_mul_base_r, pw_shift_base_r;
    reg [15:0] input_height_r, input_width_r, input_channels_r;
    reg [15:0] output_channels_r;
    reg [7:0] stride_r, pad_r, input_zero_point_r;
    reg [31:0] dw_output_zero_point_r, pw_output_zero_point_r;
    reg signed [31:0] dw_activation_min_r, dw_activation_max_r;
    reg signed [31:0] pw_activation_min_r, pw_activation_max_r;
    reg [31:0] flags_r;
    reg packed_weights_r;

    reg [3:0] cfg_phase_r;
    reg [15:0] cfg_index_r;
    reg [31:0] cfg_data_r;
    /* Configuration geometry is captured once per phase.  The hot request
     * and retire decisions consume these flops rather than the descriptor
     * multipliers directly. */
    reg [31:0] cfg_limit_q;
    /* Cache the descriptor geometry once at the layer boundary.  Phase
     * transitions select one of these records instead of re-synthesizing a
     * Cin/Cout multiply from cfg_phase_r on the request cursor path. */
    reg [31:0] cfg_dw_weight_limit_q, cfg_param_limit_q;
    reg [31:0] cfg_pw_weight_limit_q, cfg_pw_param_limit_q;
    reg cfg_request_last_byte_q, cfg_request_last_word_q;
    reg [3:0] cfg_request_word_be_q;
    reg cfg_request_word_pw_weight_q;
    /* Metadata for the response currently being retired.  Keep the packed
     * PW write classification and byte-enable mask in flops beside the
     * response data so descriptor geometry cannot reach the physical RAM
     * write-enable cone in the same cycle. */
    reg [3:0] cfg_word_be_r;
    reg cfg_word_pw_weight_r;
    /* The response-to-send boundary is also the RAM write-port timing
     * boundary.  Keep the complete scalar/packed sideband in flops so the
     * BRAM write-enable cone is not selected directly by the FSM state. */
    reg cfg_send_valid_r, cfg_send_word_r, cfg_send_packed_r;
    reg [3:0] cfg_send_target_r;
    reg [15:0] cfg_send_index_r;
    reg [31:0] cfg_send_data_r;
    reg [3:0] cfg_send_be_r;
    reg cfg_send_bank_r;
    reg [6:0] cfg_send_dw_channel_r;
    reg [3:0] cfg_send_dw_tap_r;
    reg [31:0] config_reads_r [0:1];
    reg active_config_bank_r;
    reg [6:0] cfg_dw_channel_r;
    reg [3:0] cfg_dw_tap_r;

    reg [2:0] pref_state_r;
    reg [7:0] pref_layer_r;
    reg [1023:0] pref_desc_r;
    reg [3:0] pref_cfg_phase_r;
    reg [15:0] pref_cfg_index_r;
    reg [31:0] pref_cfg_data_r;
    reg [31:0] pref_cfg_limit_q;
    reg [31:0] pref_dw_weight_limit_q, pref_param_limit_q;
    reg [31:0] pref_pw_weight_limit_q, pref_pw_param_limit_q;
    reg pref_cfg_request_last_byte_q, pref_cfg_request_last_word_q;
    reg [3:0] pref_cfg_request_word_be_q;
    reg pref_cfg_request_word_pw_weight_q;
    reg [3:0] pref_cfg_word_be_r;
    reg pref_cfg_word_pw_weight_r;
    reg pref_cfg_send_valid_r, pref_cfg_send_word_r, pref_cfg_send_packed_r;
    reg [3:0] pref_cfg_send_target_r;
    reg [15:0] pref_cfg_send_index_r;
    reg [31:0] pref_cfg_send_data_r;
    reg [3:0] pref_cfg_send_be_r;
    reg pref_cfg_send_bank_r;
    reg [6:0] pref_cfg_send_dw_channel_r;
    reg [3:0] pref_cfg_send_dw_tap_r;
    reg pref_config_bank_r;
    reg pref_config_done_r;
    reg [6:0] pref_cfg_dw_channel_r;
    reg [3:0] pref_cfg_dw_tap_r;
    reg adapter_done_pending_r;
    reg output_last_committed_q;

    wire [31:0] desc_word0  = desc_words[(0*32) +: 32];
    wire [31:0] desc_word1  = desc_words[(1*32) +: 32];
    wire [31:0] desc_word2  = desc_words[(2*32) +: 32];
    wire [31:0] desc_word3  = desc_words[(3*32) +: 32];
    wire [31:0] desc_word4  = desc_words[(4*32) +: 32];
    wire [31:0] desc_word5  = desc_words[(5*32) +: 32];
    wire [31:0] desc_word6  = desc_words[(6*32) +: 32];
    wire [31:0] desc_word7  = desc_words[(7*32) +: 32];
    wire [31:0] desc_word8  = desc_words[(8*32) +: 32];
    wire [31:0] desc_word9  = desc_words[(9*32) +: 32];
    wire [31:0] desc_word10 = desc_words[(10*32) +: 32];
    wire [31:0] desc_word11 = desc_words[(11*32) +: 32];
    wire [31:0] desc_word12 = desc_words[(12*32) +: 32];
    wire [31:0] desc_word13 = desc_words[(13*32) +: 32];
    wire [31:0] desc_word14 = desc_words[(14*32) +: 32];
    wire [31:0] desc_word15 = desc_words[(15*32) +: 32];
    wire [31:0] desc_word16 = desc_words[(16*32) +: 32];
    wire [31:0] desc_word17 = desc_words[(17*32) +: 32];
    wire [31:0] desc_word18 = desc_words[(18*32) +: 32];

    wire [31:0] pref_desc_word0  = pref_desc_r[(0*32) +: 32];
    wire [31:0] pref_desc_word1  = pref_desc_r[(1*32) +: 32];
    wire [31:0] pref_desc_word2  = pref_desc_r[(2*32) +: 32];
    wire [31:0] pref_desc_word3  = pref_desc_r[(3*32) +: 32];
    wire [31:0] pref_desc_word4  = pref_desc_r[(4*32) +: 32];
    wire [31:0] pref_desc_word5  = pref_desc_r[(5*32) +: 32];
    wire [31:0] pref_desc_word6  = pref_desc_r[(6*32) +: 32];
    wire [31:0] pref_desc_word7  = pref_desc_r[(7*32) +: 32];
    wire [31:0] pref_desc_word8  = pref_desc_r[(8*32) +: 32];
    wire [31:0] pref_desc_word9  = pref_desc_r[(9*32) +: 32];
    wire [31:0] pref_desc_word10 = pref_desc_r[(10*32) +: 32];
    wire [31:0] pref_desc_word11 = pref_desc_r[(11*32) +: 32];
    wire [31:0] pref_desc_word12 = pref_desc_r[(12*32) +: 32];
    wire [31:0] pref_desc_word13 = pref_desc_r[(13*32) +: 32];
    wire [31:0] pref_desc_word14 = pref_desc_r[(14*32) +: 32];
    wire [31:0] pref_desc_word15 = pref_desc_r[(15*32) +: 32];
    wire [31:0] pref_desc_word16 = pref_desc_r[(16*32) +: 32];
    wire [31:0] pref_desc_word17 = pref_desc_r[(17*32) +: 32];
    wire [31:0] pref_desc_word18 = pref_desc_r[(18*32) +: 32];

    function [31:0] dw_weight_limit_for_cin;
        input [15:0] cin;
        begin
            /* Nine taps per input channel.  Keep this as a shift/add so the
             * fixed DW geometry cannot infer a DSP multiplier. */
            dw_weight_limit_for_cin = ({16'd0,cin} << 3) + {16'd0,cin};
        end
    endfunction

    function [31:0] pw_weight_limit_for_shape;
        input [15:0] cin;
        input [15:0] cout;
        begin
            pw_weight_limit_for_shape = {16'd0,cin} * {16'd0,cout};
        end
    endfunction

    /* Each entry is the limit for the phase immediately following the
     * registered phase.  The select is intentionally fed only by cached
     * values; no descriptor-derived multiplication remains in this cone. */
    wire [31:0] cfg_next_limit =
        (cfg_phase_r == CFG_DW_WEIGHT) ? cfg_param_limit_q :
        (cfg_phase_r == CFG_DW_BIAS)   ? cfg_param_limit_q :
        (cfg_phase_r == CFG_DW_MUL)    ? cfg_param_limit_q :
        (cfg_phase_r == CFG_DW_SHIFT)  ? cfg_pw_weight_limit_q :
        (cfg_phase_r == CFG_PW_WEIGHT) ? cfg_pw_param_limit_q :
        (cfg_phase_r == CFG_PW_BIAS)   ? cfg_pw_param_limit_q :
        (cfg_phase_r == CFG_PW_MUL)    ? cfg_pw_param_limit_q : 32'd0;
    wire [31:0] pref_cfg_next_limit =
        (pref_cfg_phase_r == CFG_DW_WEIGHT) ? pref_param_limit_q :
        (pref_cfg_phase_r == CFG_DW_BIAS)   ? pref_param_limit_q :
        (pref_cfg_phase_r == CFG_DW_MUL)    ? pref_param_limit_q :
        (pref_cfg_phase_r == CFG_DW_SHIFT)  ? pref_pw_weight_limit_q :
        (pref_cfg_phase_r == CFG_PW_WEIGHT) ? pref_pw_param_limit_q :
        (pref_cfg_phase_r == CFG_PW_BIAS)   ? pref_pw_param_limit_q :
        (pref_cfg_phase_r == CFG_PW_MUL)    ? pref_pw_param_limit_q : 32'd0;

    wire cfg_is_weight = (cfg_phase_r == CFG_DW_WEIGHT) ||
                         (cfg_phase_r == CFG_PW_WEIGHT);
    wire [31:0] cfg_base_addr =
        (cfg_phase_r == CFG_DW_WEIGHT) ? dw_weight_base_r :
        (cfg_phase_r == CFG_DW_BIAS)   ? dw_bias_base_r :
        (cfg_phase_r == CFG_DW_MUL)    ? dw_mul_base_r :
        (cfg_phase_r == CFG_DW_SHIFT)  ? dw_shift_base_r :
        (cfg_phase_r == CFG_PW_WEIGHT) ? pw_weight_base_r :
        (cfg_phase_r == CFG_PW_BIAS)   ? pw_bias_base_r :
        (cfg_phase_r == CFG_PW_MUL)    ? pw_mul_base_r : pw_shift_base_r;
    wire [31:0] cfg_word_offset = cfg_is_weight && packed_weights_r ?
                                  ({16'd0,cfg_index_r} & 32'hffff_fffc) :
                                  ({16'd0,cfg_index_r} << 2);
    wire [1:0] cfg_byte_lane = cfg_index_r[1:0];
    wire [31:0] cfg_external_addr = cfg_base_addr + cfg_word_offset;
    wire [7:0] cfg_weight_byte = packed_weights_r ?
                                  (cfg_data_r >> (cfg_byte_lane * 8)) :
                                  cfg_data_r[7:0];
    /* These are used only in ST_CFG_PREP.  The resulting predicates and
     * byte-enable are registered before ST_CFG_REQ, so the request handshake
     * and the send/retire path consume flops rather than this subtract/compare
     * cone. */
    wire [31:0] cfg_prep_remaining_bytes =
        cfg_limit_q - {16'd0,cfg_index_r};
    wire [3:0] cfg_prep_word_be =
        (cfg_prep_remaining_bytes >= 32'd4) ? 4'b1111 :
        (cfg_prep_remaining_bytes == 32'd3) ? 4'b0111 :
        (cfg_prep_remaining_bytes == 32'd2) ? 4'b0011 :
        (cfg_prep_remaining_bytes == 32'd1) ? 4'b0001 : 4'b0000;
    wire cfg_prep_last_byte =
        ({16'd0,cfg_index_r} + 32'd1 >= cfg_limit_q);
    wire cfg_prep_word_pw_weight = packed_weights_r &&
        (cfg_phase_r == CFG_PW_WEIGHT);
    wire cfg_prep_packed_weight = packed_weights_r && cfg_is_weight;
    wire cfg_prep_last_word = cfg_prep_packed_weight &&
        ({16'd0,cfg_index_r} + 32'd4 >= cfg_limit_q);

    wire pref_cfg_is_weight = (pref_cfg_phase_r == CFG_DW_WEIGHT) ||
                              (pref_cfg_phase_r == CFG_PW_WEIGHT);
    wire [15:0] pref_input_channels = pref_desc_word12[15:0];
    wire [15:0] pref_output_channels = pref_desc_word12[31:16];
    wire pref_packed_weights = pref_desc_word18[FLAG_PACKED_WEIGHTS];
    wire [31:0] pref_cfg_base_addr =
        (pref_cfg_phase_r == CFG_DW_WEIGHT) ? pref_desc_word3 :
        (pref_cfg_phase_r == CFG_DW_BIAS) ? pref_desc_word4 :
        (pref_cfg_phase_r == CFG_DW_MUL) ? pref_desc_word5 :
        (pref_cfg_phase_r == CFG_DW_SHIFT) ? pref_desc_word6 :
        (pref_cfg_phase_r == CFG_PW_WEIGHT) ? pref_desc_word7 :
        (pref_cfg_phase_r == CFG_PW_BIAS) ? pref_desc_word8 :
        (pref_cfg_phase_r == CFG_PW_MUL) ? pref_desc_word9 : pref_desc_word10;
    wire [31:0] pref_cfg_word_offset =
        pref_cfg_is_weight && pref_packed_weights ?
            ({16'd0,pref_cfg_index_r} & 32'hffff_fffc) :
            ({16'd0,pref_cfg_index_r} << 2);
    wire [31:0] pref_cfg_external_addr =
        pref_cfg_base_addr + pref_cfg_word_offset;
    wire [7:0] pref_cfg_weight_byte = pref_packed_weights ?
        (pref_cfg_data_r >> (pref_cfg_index_r[1:0] * 8)) :
        pref_cfg_data_r[7:0];
    /* Prefetch has the same phase-preparation fence as the foreground
     * loader.  Keep its geometry independent so a live foreground phase can
     * never feed the inactive bank's request metadata. */
    wire [31:0] pref_cfg_prep_remaining_bytes =
        pref_cfg_limit_q - {16'd0,pref_cfg_index_r};
    wire [3:0] pref_cfg_prep_word_be =
        (pref_cfg_prep_remaining_bytes >= 32'd4) ? 4'b1111 :
        (pref_cfg_prep_remaining_bytes == 32'd3) ? 4'b0111 :
        (pref_cfg_prep_remaining_bytes == 32'd2) ? 4'b0011 :
        (pref_cfg_prep_remaining_bytes == 32'd1) ? 4'b0001 :
        4'b0000;
    wire pref_cfg_prep_word_pw_weight = pref_packed_weights &&
                                        (pref_cfg_phase_r == CFG_PW_WEIGHT);
    wire pref_cfg_prep_packed_weight = pref_packed_weights &&
                                       pref_cfg_is_weight;
    wire pref_cfg_prep_last_byte =
        ({16'd0,pref_cfg_index_r} + 32'd1 >= pref_cfg_limit_q);
    wire pref_cfg_prep_last_word = pref_cfg_prep_packed_weight &&
        ({16'd0,pref_cfg_index_r} + 32'd4 >= pref_cfg_limit_q);
    wire pref_cfg_send = (pref_state_r == PREF_SEND);
    wire cfg_send = (state == ST_CFG_SEND);
    /* These selects are driven by response metadata flops rather than the
     * live FSM state.  Foreground and look-ahead loaders never retire a bus
     * response concurrently, so foreground validity has priority when both
     * records are present. */
    wire selected_cfg_send = cfg_send_valid_r || pref_cfg_send_valid_r;
    wire selected_cfg_word_pw_weight = cfg_send_valid_r ? cfg_send_word_r :
                                       pref_cfg_send_word_r;
    wire [3:0] selected_cfg_target = cfg_send_valid_r ? cfg_send_target_r :
                                     pref_cfg_send_target_r;
    wire [15:0] selected_cfg_index = cfg_send_valid_r ? cfg_send_index_r :
                                     pref_cfg_send_index_r;
    wire [31:0] selected_cfg_data = cfg_send_valid_r ? cfg_send_data_r :
                                    pref_cfg_send_data_r;
    wire [3:0] selected_cfg_be = cfg_send_valid_r ? cfg_send_be_r :
                                 pref_cfg_send_be_r;
    wire selected_cfg_bank = cfg_send_valid_r ? cfg_send_bank_r :
                             pref_cfg_send_bank_r;
    wire [6:0] selected_cfg_dw_channel = cfg_send_valid_r ?
                                         cfg_send_dw_channel_r :
                                         pref_cfg_send_dw_channel_r;
    wire [3:0] selected_cfg_dw_tap = cfg_send_valid_r ? cfg_send_dw_tap_r :
                                      pref_cfg_send_dw_tap_r;
    wire selected_cfg_packed = cfg_send_valid_r ? cfg_send_packed_r :
                               pref_cfg_send_packed_r;
    wire selected_cfg_is_weight = (selected_cfg_target == CFG_DW_WEIGHT) ||
                                  (selected_cfg_target == CFG_PW_WEIGHT);
    wire [7:0] selected_cfg_weight_byte = selected_cfg_packed ?
        (selected_cfg_data >> (selected_cfg_index[1:0] * 8)) :
        selected_cfg_data[7:0];
    wire [31:0] selected_cfg_scalar_data = selected_cfg_is_weight ?
        {24'd0,selected_cfg_weight_byte} : selected_cfg_data;
    wire selected_cfg_clear =
        ((state == ST_CFG_REQ) && (cfg_phase_r == CFG_DW_WEIGHT) &&
         (cfg_index_r == 16'd0)) ||
        ((pref_state_r == PREF_REQ) && (pref_cfg_phase_r == CFG_DW_WEIGHT) &&
         (pref_cfg_index_r == 16'd0));
    wire selected_cfg_clear_bank =
        (pref_state_r == PREF_REQ && !(state == ST_CFG_REQ)) ?
            pref_config_bank_r : active_config_bank_r;

    wire adapter_start_ready;
    wire adapter_source_word_en;
    wire [SRAM_ADDR_WIDTH-1:0] adapter_source_word_addr;
    wire adapter_output_word_en;
    wire [15:0] adapter_output_word_addr;
    wire [31:0] adapter_output_word_data;
    wire [3:0] adapter_output_word_be;
    wire adapter_output_word_last;
    wire adapter_error;
    wire adapter_done;

    /* Register the complete output command before it reaches feature SRAM.
     * The previous direct path put the runner's output address arithmetic,
     * bank decode, and byte-enable bypass compare in one cycle.  This is a
     * true one-entry elastic register: a command may retire and be replaced
     * on the same edge, preserving one write per cycle when the sink is
     * ready, while a stalled sink holds every field stable. */
    wire output_cmd_valid_q;
    wire sram_output_wr_ready_i = (sram_output_wr_ready === 1'b1);
    wire output_cmd_accept_ready;
    wire output_cmd_in_fire;
    wire output_cmd_out_fire;
    wire [SRAM_ADDR_WIDTH-1:0] output_cmd_addr_q;
    wire [31:0] output_cmd_data_q;
    wire [3:0] output_cmd_be_q;
    wire output_cmd_bank_q;
    wire output_cmd_last_q;

    ds_group_shared64_output_skid #(
        .ADDR_WIDTH(SRAM_ADDR_WIDTH)
    ) u_output_cmd_skid (
        .clk(clk), .rst_n(rst_n),
        .in_valid((state == ST_RUN) && adapter_output_word_en),
        .in_ready(output_cmd_accept_ready),
        .in_addr(adapter_output_word_addr[SRAM_ADDR_WIDTH-1:0]),
        .in_data(adapter_output_word_data), .in_be(adapter_output_word_be),
        .in_bank(sram_output_wr_bank), .in_last(adapter_output_word_last),
        .out_valid(output_cmd_valid_q), .out_ready(sram_output_wr_ready_i),
        .out_addr(output_cmd_addr_q), .out_data(output_cmd_data_q),
        .out_be(output_cmd_be_q), .out_bank(output_cmd_bank_q),
        .out_last(output_cmd_last_q), .in_fire(output_cmd_in_fire),
        .out_fire(output_cmd_out_fire)
    );

    /* Configuration writes are accepted unconditionally by the group
     * adapter.  Keep the write data canonical at this wrapper boundary: a
     * packed weight uses the selected byte lane; scalar weights already use
     * the low byte of their 32-bit word. */
    ds_group_published_shared64_runner_adapter #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH),
        .MAX_CIN(MAX_CIN),
        .MAX_COUT(MAX_COUT),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_group_adapter (
        .clk(clk), .rst_n(rst_n),
        .start_valid(state == ST_START), .start_ready(adapter_start_ready),
        .input_base_addr(input_base_r), .output_base_addr(output_base_r),
        .input_height(input_height_r), .input_width(input_width_r),
        .input_channels(input_channels_r), .output_channels(output_channels_r),
        .stride(stride_r), .input_zero_point(input_zero_point_r),
        .dw_output_zero_point(dw_output_zero_point_r),
        .dw_activation_min(dw_activation_min_r),
        .dw_activation_max(dw_activation_max_r),
        .pw_output_zero_point(pw_output_zero_point_r),
        .pw_activation_min(pw_activation_min_r),
        .pw_activation_max(pw_activation_max_r),
        .config_write_en(selected_cfg_send && !selected_cfg_word_pw_weight),
        .config_target(selected_cfg_target), .config_index(selected_cfg_index),
        .config_dw_channel(selected_cfg_dw_channel),
        .config_dw_tap(selected_cfg_dw_tap),
        .config_data(selected_cfg_scalar_data),
        .config_word_write_en(selected_cfg_send && selected_cfg_word_pw_weight),
        .config_word_target(selected_cfg_target), .config_word_index(selected_cfg_index),
        .config_word_data(selected_cfg_data), .config_word_be(selected_cfg_be),
        .config_write_bank(selected_cfg_bank),
        .config_read_bank(active_config_bank_r),
        .config_clear_en(selected_cfg_clear),
        .config_clear_bank(selected_cfg_clear_bank),
        .source_word_en(adapter_source_word_en),
        .source_word_addr(adapter_source_word_addr), .source_word_ready(1'b1),
        .source_word_valid(sram_input_rd_word_valid),
        .source_word_data(sram_input_rd_word_data),
        .output_word_en(adapter_output_word_en),
        .output_word_addr(adapter_output_word_addr),
        .output_word_data(adapter_output_word_data),
        .output_word_be(adapter_output_word_be),
        .output_word_last(adapter_output_word_last),
        .output_word_ready(output_cmd_accept_ready),
        .busy(), .done(adapter_done), .error(adapter_error),
        .perf_cycles(perf_cycles), .perf_dw_writes(perf_dw_writes),
        .perf_descriptors(perf_descriptors), .perf_pw_tokens(perf_pw_tokens),
        .perf_output_writes(perf_output_writes), .perf_jobs(perf_jobs),
        .perf_stream_beats(perf_stream_beats), .config_accept_count(),
        .config_phase_count(), .config_word_accept_count(config_word_accept_count),
        .config_scalar_write_count(config_scalar_write_count)
    );

    assign sram_input_rd_en = 1'b0;
    assign sram_input_rd_addr = {SRAM_ADDR_WIDTH{1'b0}};
    assign sram_input_rd_word_en = (state == ST_RUN) && adapter_source_word_en;
    assign sram_input_rd_word_addr = adapter_source_word_addr;
    assign sram_output_wr_en = 1'b0;
    assign sram_output_wr_addr = {SRAM_ADDR_WIDTH{1'b0}};
    assign sram_output_wr_data = 8'sd0;
    assign sram_output_wr4_en = (state == ST_RUN) && output_cmd_valid_q &&
                                sram_output_wr_ready_i;
    assign sram_output_wr4_addr = output_cmd_addr_q;
    assign sram_output_wr4_data = output_cmd_data_q;
    assign sram_output_wr4_be = output_cmd_be_q;

    assign mem_req_valid = (state == ST_CFG_REQ) ||
                           (pref_state_r == PREF_REQ);
    assign mem_req_write = 1'b0;
    assign mem_req_addr = (state == ST_CFG_REQ) ? cfg_external_addr :
                          pref_cfg_external_addr;
    assign mem_req_wdata = 32'd0;
    assign busy = rst_n && (state != ST_IDLE) && (state != ST_ERROR);
    assign error = error_r | adapter_error;
    assign config_read_count = config_reads_r[active_config_bank_r];
    assign profile_state = state;

    /* C0 is the supported promotion envelope for this backend.  Keep the
     * checks explicit so unsupported descriptors cannot silently wrap an
     * address or truncate a channel count at the group adapter boundary. */
    wire shape_supported =
        (((layer_r >= 8'd1) && (layer_r <= 8'd6)) &&
         (input_height_r == input_width_r) &&
         ((input_height_r == 16'd32) || (input_height_r == 16'd16) ||
          (input_height_r == 16'd8)) &&
         (input_channels_r >= 16'd1) && (input_channels_r <= MAX_CIN) &&
         (output_channels_r >= 16'd1) && (output_channels_r <= MAX_COUT) &&
         ((stride_r == 8'd1) || (stride_r == 8'd2)) && (pad_r == 8'd1));
    wire descriptor_supported =
        (desc_word0 == OP_DS_BLOCK) &&
        desc_word18[FLAG_INPUT_FROM_SRAM] &&
        desc_word18[FLAG_OUTPUT_TO_SRAM] &&
        desc_word18[FLAG_TILED_DS_BLOCK] &&
        (desc_word3[1:0] == 2'b00) && (desc_word4[1:0] == 2'b00) &&
        (desc_word5[1:0] == 2'b00) && (desc_word6[1:0] == 2'b00) &&
        (desc_word7[1:0] == 2'b00) && (desc_word8[1:0] == 2'b00) &&
        (desc_word9[1:0] == 2'b00) && (desc_word10[1:0] == 2'b00);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            error_r <= 1'b0;
            done <= 1'b0;
            layer_r <= 8'd0;
            input_base_r <= 32'd0; output_base_r <= 32'd0;
            dw_weight_base_r <= 32'd0; dw_bias_base_r <= 32'd0;
            dw_mul_base_r <= 32'd0; dw_shift_base_r <= 32'd0;
            pw_weight_base_r <= 32'd0; pw_bias_base_r <= 32'd0;
            pw_mul_base_r <= 32'd0; pw_shift_base_r <= 32'd0;
            input_height_r <= 16'd0; input_width_r <= 16'd0;
            input_channels_r <= 16'd0; output_channels_r <= 16'd0;
            stride_r <= 8'd1; pad_r <= 8'd0; input_zero_point_r <= 8'd0;
            dw_output_zero_point_r <= 32'd0; pw_output_zero_point_r <= 32'd0;
            dw_activation_min_r <= -32'sd128; dw_activation_max_r <= 32'sd127;
            pw_activation_min_r <= -32'sd128; pw_activation_max_r <= 32'sd127;
            flags_r <= 32'd0; packed_weights_r <= 1'b0;
            cfg_phase_r <= CFG_DW_WEIGHT; cfg_index_r <= 16'd0;
            cfg_data_r <= 32'd0;
            cfg_limit_q <= 32'd0;
            cfg_dw_weight_limit_q <= 32'd0;
            cfg_param_limit_q <= 32'd0;
            cfg_pw_weight_limit_q <= 32'd0;
            cfg_pw_param_limit_q <= 32'd0;
            cfg_request_last_byte_q <= 1'b0;
            cfg_request_last_word_q <= 1'b0;
            cfg_request_word_be_q <= 4'd0;
            cfg_request_word_pw_weight_q <= 1'b0;
            cfg_word_be_r <= 4'd0;
            cfg_word_pw_weight_r <= 1'b0;
            cfg_send_valid_r <= 1'b0;
            cfg_send_word_r <= 1'b0;
            cfg_send_packed_r <= 1'b0;
            cfg_send_target_r <= CFG_DW_WEIGHT;
            cfg_send_index_r <= 16'd0;
            cfg_send_data_r <= 32'd0;
            cfg_send_be_r <= 4'd0;
            cfg_send_bank_r <= 1'b0;
            cfg_send_dw_channel_r <= 7'd0;
            cfg_send_dw_tap_r <= 4'd0;
            config_reads_r[0] <= 32'd0; config_reads_r[1] <= 32'd0;
            active_config_bank_r <= 1'b0;
            cfg_dw_channel_r <= 7'd0;
            cfg_dw_tap_r <= 4'd0;
            pref_state_r <= PREF_IDLE;
            pref_layer_r <= 8'd0;
            pref_desc_r <= 1024'd0;
            pref_cfg_phase_r <= CFG_DW_WEIGHT;
            pref_cfg_index_r <= 16'd0;
            pref_cfg_data_r <= 32'd0;
            pref_cfg_limit_q <= 32'd0;
            pref_dw_weight_limit_q <= 32'd0;
            pref_param_limit_q <= 32'd0;
            pref_pw_weight_limit_q <= 32'd0;
            pref_pw_param_limit_q <= 32'd0;
            pref_cfg_request_last_byte_q <= 1'b0;
            pref_cfg_request_last_word_q <= 1'b0;
            pref_cfg_request_word_be_q <= 4'd0;
            pref_cfg_request_word_pw_weight_q <= 1'b0;
            pref_cfg_word_be_r <= 4'd0;
            pref_cfg_word_pw_weight_r <= 1'b0;
            pref_cfg_send_valid_r <= 1'b0;
            pref_cfg_send_word_r <= 1'b0;
            pref_cfg_send_packed_r <= 1'b0;
            pref_cfg_send_target_r <= CFG_DW_WEIGHT;
            pref_cfg_send_index_r <= 16'd0;
            pref_cfg_send_data_r <= 32'd0;
            pref_cfg_send_be_r <= 4'd0;
            pref_cfg_send_bank_r <= 1'b1;
            pref_cfg_send_dw_channel_r <= 7'd0;
            pref_cfg_send_dw_tap_r <= 4'd0;
            pref_config_bank_r <= 1'b1;
            pref_config_done_r <= 1'b0;
            pref_cfg_dw_channel_r <= 7'd0;
            pref_cfg_dw_tap_r <= 4'd0;
            adapter_done_pending_r <= 1'b0;
            output_last_committed_q <= 1'b0;
        end else begin
            done <= 1'b0;
            if (output_cmd_out_fire && output_cmd_last_q)
                output_last_committed_q <= 1'b1;

            /* The look-ahead descriptor is supplied by cnn_top only while a
             * group layer owns the datapath.  Configuration reads use the
             * same one-outstanding bus contract as the foreground loader, but
             * write the inactive physical bank. */
            if ((state == ST_RUN) && (pref_state_r == PREF_IDLE) &&
                !pref_config_done_r && prefetch_valid &&
                (prefetch_desc_words[31:0] == OP_DS_BLOCK)) begin
                pref_layer_r <= prefetch_layer;
                pref_desc_r <= prefetch_desc_words;
                pref_config_bank_r <= ~active_config_bank_r;
                pref_cfg_phase_r <= CFG_DW_WEIGHT;
                pref_cfg_index_r <= 16'd0;
                pref_cfg_data_r <= 32'd0;
                pref_dw_weight_limit_q <= dw_weight_limit_for_cin(
                    prefetch_desc_words[(12*32) +: 16]);
                pref_param_limit_q <=
                    {16'd0,prefetch_desc_words[(12*32) +: 16]};
                pref_pw_weight_limit_q <= pw_weight_limit_for_shape(
                    prefetch_desc_words[(12*32) +: 16],
                    prefetch_desc_words[(12*32 + 16) +: 16]);
                pref_pw_param_limit_q <=
                    {16'd0,prefetch_desc_words[(12*32 + 16) +: 16]};
                pref_cfg_limit_q <= dw_weight_limit_for_cin(
                    prefetch_desc_words[(12*32) +: 16]);
                pref_config_done_r <= 1'b0;
                pref_cfg_dw_channel_r <= 7'd0;
                pref_cfg_dw_tap_r <= 4'd0;
                config_reads_r[~active_config_bank_r] <= 32'd0;
                pref_state_r <= PREF_PREP;
            end else if (pref_state_r == PREF_PREP) begin
                /* The limit is now a registered phase record.  Capture all
                 * request geometry before issuing the first read; subsequent
                 * request handshakes only consume these predicates. */
                pref_cfg_request_last_byte_q <= pref_cfg_prep_last_byte;
                pref_cfg_request_last_word_q <= pref_cfg_prep_last_word;
                pref_cfg_request_word_be_q <= pref_cfg_prep_word_be;
                pref_cfg_request_word_pw_weight_q <=
                    pref_cfg_prep_word_pw_weight;
                pref_state_r <= PREF_REQ;
            end else if (pref_state_r == PREF_REQ) begin
                if (mem_req_valid && mem_req_ready) begin
                    config_reads_r[pref_config_bank_r] <=
                        config_reads_r[pref_config_bank_r] + 1'b1;
                    pref_state_r <= PREF_WAIT;
                end
            end else if (pref_state_r == PREF_WAIT) begin
                if (mem_resp_valid) begin
                    pref_cfg_data_r <= mem_resp_rdata;
                    pref_cfg_word_be_r <= pref_cfg_request_word_be_q;
                    pref_cfg_word_pw_weight_r <=
                        pref_cfg_request_word_pw_weight_q;
                    pref_cfg_send_target_r <= pref_cfg_phase_r;
                    pref_cfg_send_index_r <= pref_cfg_index_r;
                    pref_cfg_send_data_r <= mem_resp_rdata;
                    pref_cfg_send_be_r <= pref_cfg_request_word_be_q;
                    pref_cfg_send_word_r <= pref_cfg_request_word_pw_weight_q;
                    pref_cfg_send_packed_r <= pref_packed_weights;
                    pref_cfg_send_bank_r <= pref_config_bank_r;
                    pref_cfg_send_dw_channel_r <= pref_cfg_dw_channel_r;
                    pref_cfg_send_dw_tap_r <= pref_cfg_dw_tap_r;
                    pref_cfg_send_valid_r <= 1'b1;
                    pref_state_r <= PREF_SEND;
                end
            end else if (pref_state_r == PREF_SEND) begin
                /* The sideband flops above drive the physical configuration
                 * store for this entire cycle.  Retire the pulse after the
                 * store edge while the cursor advances below. */
                pref_cfg_send_valid_r <= 1'b0;
                /* DW weights are presented channel-major (nine taps per
                 * channel).  Carry the physical row/tap cursor alongside the
                 * canonical scalar index; this removes a divide/modulo cone
                 * from the RAM write path while retaining the same ABI. */
                if (pref_cfg_phase_r == CFG_DW_WEIGHT) begin
                    if (pref_cfg_request_last_byte_q) begin
                        pref_cfg_dw_channel_r <= 7'd0;
                        pref_cfg_dw_tap_r <= 4'd0;
                        pref_cfg_send_dw_channel_r <= 7'd0;
                        pref_cfg_send_dw_tap_r <= 4'd0;
                    end else if (pref_cfg_dw_tap_r == 4'd8) begin
                        pref_cfg_dw_channel_r <= pref_cfg_dw_channel_r + 1'b1;
                        pref_cfg_dw_tap_r <= 4'd0;
                        pref_cfg_send_dw_channel_r <=
                            pref_cfg_send_dw_channel_r + 1'b1;
                        pref_cfg_send_dw_tap_r <= 4'd0;
                    end else begin
                        pref_cfg_dw_tap_r <= pref_cfg_dw_tap_r + 1'b1;
                        pref_cfg_send_dw_tap_r <=
                            pref_cfg_send_dw_tap_r + 1'b1;
                    end
                end
                if (pref_cfg_word_pw_weight_r) begin
                    if (pref_cfg_request_last_word_q) begin
                        if (pref_cfg_phase_r == CFG_PW_SHIFT) begin
                            pref_state_r <= PREF_IDLE;
                            pref_config_done_r <= 1'b1;
                        end else begin
                            pref_cfg_phase_r <= pref_cfg_phase_r + 1'b1;
                            pref_cfg_index_r <= 16'd0;
                            pref_cfg_limit_q <= pref_cfg_next_limit;
                            pref_state_r <= PREF_PREP;
                        end
                    end else begin
                        pref_cfg_index_r <= pref_cfg_index_r + 16'd4;
                        pref_state_r <= PREF_PREP;
                    end
                end else if (pref_cfg_is_weight && pref_packed_weights) begin
                    /* DW packed words still retire four scalar bytes over
                     * four send cycles.  A partial final word stops at its
                     * last valid byte; a full final word stops after lane 3.
                     * The request metadata was prepared before the bus
                     * handshake, so neither case re-enters the limit cone. */
                    if (pref_cfg_request_last_byte_q) begin
                        if (pref_cfg_phase_r == CFG_PW_SHIFT) begin
                            pref_state_r <= PREF_IDLE;
                            pref_config_done_r <= 1'b1;
                        end else begin
                            pref_cfg_phase_r <= pref_cfg_phase_r + 1'b1;
                            pref_cfg_index_r <= 16'd0;
                            pref_cfg_limit_q <= pref_cfg_next_limit;
                            pref_state_r <= PREF_PREP;
                        end
                    end else if (pref_cfg_index_r[1:0] != 2'b11) begin
                        pref_cfg_index_r <= pref_cfg_index_r + 1'b1;
                        /* A packed DW word is unpacked over four send
                         * cycles.  Keep the registered write pulse alive
                         * and advance only its byte-lane metadata. */
                        pref_cfg_send_valid_r <= 1'b1;
                        pref_cfg_send_index_r <= pref_cfg_index_r + 1'b1;
                        pref_state_r <= PREF_SEND;
                    end else if (pref_cfg_request_last_word_q) begin
                        if (pref_cfg_phase_r == CFG_PW_SHIFT) begin
                            pref_state_r <= PREF_IDLE;
                            pref_config_done_r <= 1'b1;
                        end else begin
                            pref_cfg_phase_r <= pref_cfg_phase_r + 1'b1;
                            pref_cfg_index_r <= 16'd0;
                            pref_cfg_limit_q <= pref_cfg_next_limit;
                            pref_state_r <= PREF_PREP;
                        end
                    end else begin
                        pref_cfg_index_r <= pref_cfg_index_r + 1'b1;
                        pref_state_r <= PREF_PREP;
                    end
                end else if (pref_cfg_request_last_byte_q) begin
                    if (pref_cfg_phase_r == CFG_PW_SHIFT) begin
                        pref_state_r <= PREF_IDLE;
                        pref_config_done_r <= 1'b1;
                    end else begin
                        pref_cfg_phase_r <= pref_cfg_phase_r + 1'b1;
                        pref_cfg_index_r <= 16'd0;
                        pref_cfg_limit_q <= pref_cfg_next_limit;
                        pref_state_r <= PREF_PREP;
                    end
                end else begin
                    pref_cfg_index_r <= pref_cfg_index_r + 1'b1;
                    pref_state_r <= PREF_PREP;
                end
            end

            if (state == ST_IDLE) begin
                if (start) begin
                    error_r <= 1'b0;
                    layer_r <= desc_layer;
                    input_base_r <= desc_word1; output_base_r <= desc_word2;
                    dw_weight_base_r <= desc_word3; dw_bias_base_r <= desc_word4;
                    dw_mul_base_r <= desc_word5; dw_shift_base_r <= desc_word6;
                    pw_weight_base_r <= desc_word7; pw_bias_base_r <= desc_word8;
                    pw_mul_base_r <= desc_word9; pw_shift_base_r <= desc_word10;
                    input_height_r <= desc_word11[15:0];
                    input_width_r <= desc_word11[31:16];
                    input_channels_r <= desc_word12[15:0];
                    output_channels_r <= desc_word12[31:16];
                    stride_r <= desc_word13[7:0]; pad_r <= desc_word13[15:8];
                    input_zero_point_r <= desc_word14[7:0];
                    dw_output_zero_point_r <= desc_word15;
                    pw_output_zero_point_r <= desc_word16;
                    dw_activation_min_r <= $signed({{24{desc_word17[7]}},desc_word17[7:0]});
                    dw_activation_max_r <= $signed({{24{desc_word17[15]}},desc_word17[15:8]});
                    pw_activation_min_r <= $signed({{24{desc_word17[23]}},desc_word17[23:16]});
                    pw_activation_max_r <= $signed({{24{desc_word17[31]}},desc_word17[31:24]});
                    flags_r <= desc_word18;
                    packed_weights_r <= desc_word18[FLAG_PACKED_WEIGHTS];
                    adapter_done_pending_r <= 1'b0;
                    output_last_committed_q <= 1'b0;
                    state <= ST_VALIDATE;
                end
            end else if (state == ST_VALIDATE) begin
                if (!shape_supported || !descriptor_supported) begin
                    error_r <= 1'b1;
                    done <= 1'b1;
                    state <= ST_ERROR;
                end else if (pref_config_done_r &&
                             (pref_layer_r == layer_r)) begin
                    /* The next descriptor's complete configuration is
                     * already in the inactive bank. */
                    active_config_bank_r <= pref_config_bank_r;
                    pref_config_done_r <= 1'b0;
                    state <= ST_START;
                end else if ((pref_state_r != PREF_IDLE) &&
                             (pref_layer_r == layer_r)) begin
                    /* The engine completed before the look-ahead bus did;
                     * keep the layer boundary fenced until all writes land. */
                    state <= ST_PREFETCH_WAIT;
                end else begin
                    /* Reuse the bank no longer consumed by the previous
                     * layer.  The inner adapter clears its per-bank audit
                     * counters on the first request. */
                    active_config_bank_r <= ~active_config_bank_r;
                    config_reads_r[~active_config_bank_r] <= 32'd0;
                    cfg_phase_r <= CFG_DW_WEIGHT;
                    cfg_index_r <= 16'd0;
                    cfg_data_r <= 32'd0;
                    cfg_dw_weight_limit_q <=
                        dw_weight_limit_for_cin(input_channels_r);
                    cfg_param_limit_q <= {16'd0,input_channels_r};
                    cfg_pw_weight_limit_q <= pw_weight_limit_for_shape(
                        input_channels_r, output_channels_r);
                    cfg_pw_param_limit_q <= {16'd0,output_channels_r};
                    cfg_limit_q <= dw_weight_limit_for_cin(input_channels_r);
                    cfg_dw_channel_r <= 7'd0;
                    cfg_dw_tap_r <= 4'd0;
                    state <= ST_CFG_PREP;
                end
            end else if (state == ST_CFG_PREP) begin
                /* The phase limit has been committed for at least one full
                 * cycle.  Lock the terminal predicates and final word mask
                 * before exposing a request; the handshake below must not
                 * recompute them from descriptor geometry. */
                cfg_request_last_byte_q <= cfg_prep_last_byte;
                cfg_request_last_word_q <= cfg_prep_last_word;
                cfg_request_word_be_q <= cfg_prep_word_be;
                cfg_request_word_pw_weight_q <= cfg_prep_word_pw_weight;
                state <= ST_CFG_REQ;
            end else if (state == ST_CFG_REQ) begin
                if (mem_req_valid && mem_req_ready) begin
                    config_reads_r[active_config_bank_r] <=
                        config_reads_r[active_config_bank_r] + 1'b1;
                    state <= ST_CFG_WAIT;
                end
            end else if (state == ST_CFG_WAIT) begin
                if (mem_resp_valid) begin
                    cfg_data_r <= mem_resp_rdata;
                    cfg_word_be_r <= cfg_request_word_be_q;
                    cfg_word_pw_weight_r <= cfg_request_word_pw_weight_q;
                    cfg_send_target_r <= cfg_phase_r;
                    cfg_send_index_r <= cfg_index_r;
                    cfg_send_data_r <= mem_resp_rdata;
                    cfg_send_be_r <= cfg_request_word_be_q;
                    cfg_send_word_r <= cfg_request_word_pw_weight_q;
                    cfg_send_packed_r <= packed_weights_r;
                    cfg_send_bank_r <= active_config_bank_r;
                    cfg_send_dw_channel_r <= cfg_dw_channel_r;
                    cfg_send_dw_tap_r <= cfg_dw_tap_r;
                    cfg_send_valid_r <= 1'b1;
                    state <= ST_CFG_SEND;
                end
            end else if (state == ST_CFG_SEND) begin
                /* The sideband flops above drive the physical configuration
                 * store for this entire cycle.  Retire the pulse after the
                 * store edge while the cursor advances below. */
                cfg_send_valid_r <= 1'b0;
                /* Keep the physical DW row/tap address as a sequential
                 * traversal cursor.  config_index_r remains the canonical
                 * ABI index used for all other stores and bounds checks. */
                if (cfg_phase_r == CFG_DW_WEIGHT) begin
                    if (cfg_request_last_byte_q) begin
                        cfg_dw_channel_r <= 7'd0;
                        cfg_dw_tap_r <= 4'd0;
                        cfg_send_dw_channel_r <= 7'd0;
                        cfg_send_dw_tap_r <= 4'd0;
                    end else if (cfg_dw_tap_r == 4'd8) begin
                        cfg_dw_channel_r <= cfg_dw_channel_r + 1'b1;
                        cfg_dw_tap_r <= 4'd0;
                        cfg_send_dw_channel_r <= cfg_send_dw_channel_r + 1'b1;
                        cfg_send_dw_tap_r <= 4'd0;
                    end else begin
                        cfg_dw_tap_r <= cfg_dw_tap_r + 1'b1;
                        cfg_send_dw_tap_r <= cfg_send_dw_tap_r + 1'b1;
                    end
                end
                if (cfg_word_pw_weight_r) begin
                    /* PW packed words are physically unpacked across four
                     * Cin banks in one cycle.  Advance the canonical byte
                     * cursor by the accepted word width, while retaining a
                     * real external read/response for every word. */
                    if (cfg_request_last_word_q) begin
                        if (cfg_phase_r == CFG_PW_SHIFT) begin
                            state <= ST_START;
                        end else begin
                            cfg_phase_r <= cfg_phase_r + 1'b1;
                            cfg_index_r <= 16'd0;
                            cfg_limit_q <= cfg_next_limit;
                            state <= ST_CFG_PREP;
                        end
                    end else begin
                        cfg_index_r <= cfg_index_r + 16'd4;
                        state <= ST_CFG_PREP;
                    end
                end else if (cfg_is_weight && packed_weights_r) begin
                    /* DW packed words retire one scalar byte per send cycle.
                     * Use the registered byte/word terminal predicates so a
                     * full final word drains all four lanes while a tail word
                     * stops at its masked final byte. */
                    if (cfg_request_last_byte_q) begin
                        if (cfg_phase_r == CFG_PW_SHIFT) begin
                            state <= ST_START;
                        end else begin
                            cfg_phase_r <= cfg_phase_r + 1'b1;
                            cfg_index_r <= 16'd0;
                            cfg_limit_q <= cfg_next_limit;
                            state <= ST_CFG_PREP;
                        end
                    end else if (cfg_index_r[1:0] != 2'b11) begin
                        cfg_index_r <= cfg_index_r + 1'b1;
                        /* A packed DW word is unpacked over four send
                         * cycles.  Keep the registered write pulse alive
                         * and advance only its byte-lane metadata. */
                        cfg_send_valid_r <= 1'b1;
                        cfg_send_index_r <= cfg_index_r + 1'b1;
                        state <= ST_CFG_SEND;
                    end else if (cfg_request_last_word_q) begin
                        if (cfg_phase_r == CFG_PW_SHIFT) begin
                            state <= ST_START;
                        end else begin
                            cfg_phase_r <= cfg_phase_r + 1'b1;
                            cfg_index_r <= 16'd0;
                            cfg_limit_q <= cfg_next_limit;
                            state <= ST_CFG_PREP;
                        end
                    end else begin
                        cfg_index_r <= cfg_index_r + 1'b1;
                        state <= ST_CFG_PREP;
                    end
                end else if (cfg_request_last_byte_q) begin
                    if (cfg_phase_r == CFG_PW_SHIFT) begin
                        state <= ST_START;
                    end else begin
                        cfg_phase_r <= cfg_phase_r + 1'b1;
                        cfg_index_r <= 16'd0;
                        cfg_limit_q <= cfg_next_limit;
                        state <= ST_CFG_PREP;
                    end
                end else begin
                    cfg_index_r <= cfg_index_r + 1'b1;
                    state <= ST_CFG_PREP;
                end
            end else if (state == ST_PREFETCH_WAIT) begin
                if (pref_config_done_r && (pref_layer_r == layer_r)) begin
                    active_config_bank_r <= pref_config_bank_r;
                    pref_config_done_r <= 1'b0;
                    state <= ST_START;
                end else if ((pref_state_r == PREF_IDLE) &&
                             !pref_config_done_r) begin
                    /* A malformed or lost look-ahead cannot deadlock a
                     * descriptor.  Fall back to an ordinary foreground load. */
                    active_config_bank_r <= ~active_config_bank_r;
                    config_reads_r[~active_config_bank_r] <= 32'd0;
                    cfg_phase_r <= CFG_DW_WEIGHT;
                    cfg_index_r <= 16'd0;
                    cfg_data_r <= 32'd0;
                    cfg_dw_weight_limit_q <=
                        dw_weight_limit_for_cin(input_channels_r);
                    cfg_param_limit_q <= {16'd0,input_channels_r};
                    cfg_pw_weight_limit_q <= pw_weight_limit_for_shape(
                        input_channels_r, output_channels_r);
                    cfg_pw_param_limit_q <= {16'd0,output_channels_r};
                    cfg_limit_q <= dw_weight_limit_for_cin(input_channels_r);
                    cfg_dw_channel_r <= 7'd0;
                    cfg_dw_tap_r <= 4'd0;
                    state <= ST_CFG_PREP;
                end
            end else if (state == ST_START) begin
                if (adapter_start_ready) begin
                    state <= ST_RUN;
                end
            end else if (state == ST_RUN) begin
                if (adapter_error) begin
                    error_r <= 1'b1;
                    done <= 1'b1;
                    state <= ST_ERROR;
                end else begin
                    if (adapter_done)
                        adapter_done_pending_r <= 1'b1;
                    if ((adapter_done_pending_r || adapter_done) &&
                        !output_cmd_valid_q && !adapter_output_word_en &&
                        output_last_committed_q &&
                        (pref_state_r == PREF_IDLE) &&
                        !prefetch_busy &&
                        !(prefetch_valid &&
                          (prefetch_desc_words[31:0] == OP_DS_BLOCK))) begin
                    done <= 1'b1;
                    adapter_done_pending_r <= 1'b0;
                    state <= ST_FINISH;
                    end
                end
            end else if (state == ST_FINISH) begin
                state <= ST_IDLE;
            end else begin
                state <= ST_IDLE;
            end
        end
    end

endmodule

`default_nettype wire
