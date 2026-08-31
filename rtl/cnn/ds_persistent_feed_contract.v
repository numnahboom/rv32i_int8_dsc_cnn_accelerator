`timescale 1ns/1ps
`default_nettype none

/*
 * DS feed-contract prototype.
 *
 * This module is intentionally independent of cnn_top/cnn_layer_runner.  It
 * proves the storage contract needed before changing the production runner:
 *
 *   - one 32-bit source stream fills a persistent source-word bank;
 *   - one 32-bit parameter stream fills a packed {cout_tile,k} row bank;
 *   - an eight-pixel source window is gathered once and then reused for every
 *     output-channel tile at that spatial position;
 *   - each accepted K token reads one local source-window row and one packed
 *     parameter row, with all metadata captured by epoch/session.
 *
 * The source and parameter memories are deliberately narrow BRAM-shaped
 * arrays.  There is no wide dynamic register image or 2048-bit live mux in
 * this proof vehicle.  The consumer ABI is the same logical 8-pixel x
 * 8-output-channel K token used by pw_direct_8x8_dsp_rowbank.
 *
 * layer_id/mode select the real C10 DS shapes.  mode=0 is the PW handoff
 * (source pixels are the preceding DW output pixels); mode=1 records the DW
 * source/parameter footprint for accounting and future tap-token extension.
 * The current token contract is deliberately PW-only so it cannot silently
 * claim a 3x3 DW schedule that it does not implement.
 */
module ds_persistent_feed_contract #(
    parameter integer MAX_SOURCE_WORDS = 32768,
    parameter integer MAX_PARAM_ROWS = 4096,
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 256,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer SESSION_WIDTH = 4
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         cfg_valid,
    output wire                         cfg_ready,
    input  wire [2:0]                   cfg_layer_id,
    input  wire                         cfg_mode,       // 0=PW, 1=DW accounting
    input  wire [EPOCH_WIDTH-1:0]       cfg_epoch,
    input  wire [SESSION_WIDTH-1:0]     cfg_session,
    output wire [15:0]                  cfg_output_pixels,
    output wire [7:0]                   cfg_cin,
    output wire [8:0]                   cfg_cout,
    output wire [15:0]                  cfg_source_pixels,
    output wire [15:0]                  cfg_source_words,
    output wire [15:0]                  cfg_param_words,

    input  wire                         load_start_valid,
    output wire                         load_start_ready,
    input  wire [31:0]                  load_source_base_addr,
    input  wire [31:0]                  load_param_base_addr,
    output wire                         source_req_valid,
    input  wire                         source_req_ready,
    output wire [31:0]                  source_req_addr,
    input  wire                         source_resp_valid,
    output wire                         source_resp_ready,
    input  wire [31:0]                  source_resp_data,
    output wire                         param_req_valid,
    input  wire                         param_req_ready,
    output wire [31:0]                  param_req_addr,
    input  wire                         param_resp_valid,
    output wire                         param_resp_ready,
    input  wire [31:0]                  param_resp_data,
    output wire                         load_active,
    output wire                         load_done,
    output wire [15:0]                  source_external_word_count,
    output wire [15:0]                  param_external_word_count,
    output wire [15:0]                  source_request_stall_count,
    output wire [15:0]                  param_request_stall_count,

    input  wire                         commit_valid,
    output wire                         commit_ready,
    output reg                          commit_reject,
    output wire                         committed_valid,
    output wire [EPOCH_WIDTH-1:0]       committed_epoch,
    output wire [SESSION_WIDTH-1:0]     committed_session,

    input  wire                         job_valid,
    output wire                         job_ready,
    input  wire [EPOCH_WIDTH-1:0]       job_epoch,
    input  wire [SESSION_WIDTH-1:0]     job_session,
    input  wire [9:0]                   job_pixel_base,
    input  wire [4:0]                   job_cout_tile,
    input  wire [7:0]                   job_pixel_mask,
    input  wire [7:0]                   job_cout_mask,
    output reg                          job_reject_stale,

    output wire                         token_valid,
    input  wire                         token_ready,
    output wire                         token_first,
    output wire                         token_last,
    output wire [7:0]                   token_k_idx,
    output wire [9:0]                   token_pixel_base,
    output wire [8:0]                   token_cout_base,
    output wire [7:0]                   token_pixel_mask,
    output wire [7:0]                   token_cout_mask,
    output wire signed [63:0]           token_act_vec,
    output wire signed [63:0]           token_wgt_vec,
    output wire                         job_done,
    output wire                         busy,
    output wire [15:0]                  local_source_word_read_count,
    output wire [31:0]                  local_param_row_read_count,
    output wire [31:0]                  token_count,
    output wire [15:0]                  window_reuse_count
);
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_LOAD = 2'd1;
    localparam [2:0] LD_IDLE = 3'd0;
    localparam [2:0] LD_SRC_REQ = 3'd1;
    localparam [2:0] LD_SRC_WAIT = 3'd2;
    localparam [2:0] LD_PARAM_REQ = 3'd3;
    localparam [2:0] LD_PARAM_WAIT = 3'd4;
    localparam [2:0] LD_DONE = 3'd5;
    localparam [1:0] WIN_IDLE = 2'd0;
    localparam [1:0] WIN_REQ = 2'd1;
    localparam [1:0] WIN_WAIT = 2'd2;
    localparam [1:0] WIN_TOKEN = 2'd3;

    function automatic [7:0] shape_cin;
        input [2:0] lid; input mode;
        begin
            if (mode) begin
                case (lid)
                    3'd1: shape_cin = 8'd16;
                    3'd3: shape_cin = 8'd64;
                    3'd6: shape_cin = 8'd128;
                    default: shape_cin = 8'd0;
                endcase
            end else begin
                case (lid)
                    3'd1: shape_cin = 8'd16;
                    3'd3: shape_cin = 8'd64;
                    3'd6: shape_cin = 8'd128;
                    default: shape_cin = 8'd0;
                endcase
            end
        end
    endfunction
    function automatic [8:0] shape_cout;
        input [2:0] lid; input mode;
        begin
            if (mode) begin
                case (lid)
                    3'd1: shape_cout = 9'd16;
                    3'd3: shape_cout = 9'd64;
                    3'd6: shape_cout = 9'd128;
                    default: shape_cout = 9'd0;
                endcase
            end else begin
                case (lid)
                    3'd1: shape_cout = 9'd32;
                    3'd3: shape_cout = 9'd64;
                    3'd6: shape_cout = 9'd256;
                    default: shape_cout = 9'd0;
                endcase
            end
        end
    endfunction
    function automatic [15:0] shape_pixels;
        input [2:0] lid;
        begin
            case (lid)
                3'd1: shape_pixels = 16'd1024;
                3'd3: shape_pixels = 16'd256;
                3'd6: shape_pixels = 16'd16;
                default: shape_pixels = 16'd0;
            endcase
        end
    endfunction
    function automatic [15:0] shape_source_pixels;
        input [2:0] lid; input mode;
        begin
            if (!mode)
                shape_source_pixels = shape_pixels(lid);
            else begin
                case (lid)
                    3'd1: shape_source_pixels = 16'd1024;
                    3'd3: shape_source_pixels = 16'd256;
                    3'd6: shape_source_pixels = 16'd64;
                    default: shape_source_pixels = 16'd0;
                endcase
            end
        end
    endfunction
    function automatic [15:0] shape_source_words;
        input [2:0] lid; input mode;
        reg [23:0] prod;
        begin
            prod = shape_source_pixels(lid, mode) * shape_cin(lid, mode);
            shape_source_words = (prod + 3) >> 2;
        end
    endfunction
    function automatic [15:0] shape_param_words;
        input [2:0] lid; input mode;
        reg [23:0] prod;
        begin
            prod = shape_cin(lid, mode) * shape_cout(lid, mode);
            if (mode) prod = 9 * shape_cin(lid, mode);
            shape_param_words = (prod + 3) >> 2;
        end
    endfunction
    /* The external stream is tile-major with two 32-bit words per
     * {cout_tile,k} row.  Keep the physical bank stride fixed at MAX_CIN so
     * different layer widths can share the same persistent row address. */
    function automatic integer param_physical_row;
        input [15:0] word_idx;
        integer logical_row, tile_i, k_i;
        begin
            logical_row = word_idx >> 1;
            tile_i = logical_row / cin_reg;
            k_i = logical_row - tile_i * cin_reg;
            param_physical_row = tile_i * MAX_CIN + k_i;
        end
    endfunction

    wire cfg_shape_ok = (shape_cin(cfg_layer_id, cfg_mode) != 0) &&
                        (shape_cout(cfg_layer_id, cfg_mode) != 0) &&
                        (shape_source_words(cfg_layer_id, cfg_mode) <= MAX_SOURCE_WORDS) &&
                        (shape_param_words(cfg_layer_id, cfg_mode) <= (MAX_PARAM_ROWS*2));
    reg [1:0] state;
    reg [2:0] cfg_layer_reg;
    reg cfg_mode_reg;
    reg [EPOCH_WIDTH-1:0] cfg_epoch_reg;
    reg [SESSION_WIDTH-1:0] cfg_session_reg;
    reg cfg_valid_reg;
    reg [7:0] cin_reg;
    reg [8:0] cout_reg;
    reg [15:0] pixels_reg, source_pixels_reg, source_words_reg, param_words_reg;
    reg [31:0] source_base_reg, param_base_reg;
    reg [2:0] src_ld_state, param_ld_state;
    reg [15:0] source_cursor, param_cursor;
    reg [15:0] source_req_count_reg, param_req_count_reg;
    reg [15:0] source_stall_reg, param_stall_reg;
    reg committed_reg;
    reg [EPOCH_WIDTH-1:0] committed_epoch_reg;
    reg [SESSION_WIDTH-1:0] committed_session_reg;
    reg load_done_reg;

    (* ram_style = "block" *) reg [31:0] source_mem [0:MAX_SOURCE_WORDS-1];
    (* ram_style = "block" *) reg [63:0] param_mem [0:MAX_PARAM_ROWS-1];

    assign cfg_output_pixels = shape_pixels(cfg_layer_id);
    assign cfg_cin = shape_cin(cfg_layer_id, cfg_mode);
    assign cfg_cout = shape_cout(cfg_layer_id, cfg_mode);
    assign cfg_source_pixels = shape_source_pixels(cfg_layer_id, cfg_mode);
    assign cfg_source_words = shape_source_words(cfg_layer_id, cfg_mode);
    assign cfg_param_words = shape_param_words(cfg_layer_id, cfg_mode);
    assign cfg_ready = rst_n && (state == ST_IDLE) && !load_active &&
                       !job_active_reg && (win_state == WIN_IDLE) &&
                       (!cfg_valid_reg || committed_reg);
    wire cfg_fire = cfg_valid && cfg_ready && cfg_shape_ok;

    assign load_start_ready = rst_n && cfg_valid_reg && !committed_reg &&
                              (state == ST_IDLE) && (src_ld_state == LD_IDLE) &&
                              (param_ld_state == LD_IDLE);
    wire load_start_fire = load_start_valid && load_start_ready;
    assign source_req_valid = (src_ld_state == LD_SRC_REQ) &&
                              (source_cursor < source_words_reg);
    assign source_req_addr = source_base_reg + {source_cursor, 2'b00};
    assign source_resp_ready = (src_ld_state == LD_SRC_WAIT);
    assign param_req_valid = (param_ld_state == LD_PARAM_REQ) &&
                             (param_cursor < param_words_reg);
    assign param_req_addr = param_base_reg + {param_cursor, 2'b00};
    assign param_resp_ready = (param_ld_state == LD_PARAM_WAIT);
    wire source_req_fire = source_req_valid && source_req_ready;
    wire param_req_fire = param_req_valid && param_req_ready;
    assign load_active = (src_ld_state != LD_IDLE && src_ld_state != LD_DONE) ||
                         (param_ld_state != LD_IDLE && param_ld_state != LD_DONE);
    assign load_done = load_done_reg;
    assign source_external_word_count = source_req_count_reg;
    assign param_external_word_count = param_req_count_reg;
    assign source_request_stall_count = source_stall_reg;
    assign param_request_stall_count = param_stall_reg;
    assign commit_ready = rst_n && cfg_valid_reg && !committed_reg &&
                          (src_ld_state == LD_DONE) && (param_ld_state == LD_DONE);
    wire commit_fire = commit_valid && commit_ready;
    assign committed_valid = committed_reg;
    assign committed_epoch = committed_epoch_reg;
    assign committed_session = committed_session_reg;

    /* ---------------- persistent eight-pixel source window ---------------- */
    reg [1:0] win_state;
    reg win_valid;
    reg [9:0] win_pixel_base_reg;
    reg [EPOCH_WIDTH-1:0] win_epoch_reg;
    reg [SESSION_WIDTH-1:0] win_session_reg;
    reg [7:0] win_pixel_mask_reg, win_cout_mask_reg;
    reg [7:0] win_word_cursor;
    reg [7:0] win_pixel_slot;
    reg [7:0] win_words_per_pixel;
    reg [7:0] win_word_in_pixel;
    reg [31:0] win_rd_data_reg;
    reg [31:0] win_base_word_reg;
    reg [15:0] local_source_reads_reg;
    reg [15:0] window_reuse_reg;
    reg [7:0] job_k_reg;
    reg job_active_reg;
    reg [4:0] job_cout_tile_reg;
    reg [9:0] job_pixel_base_reg;
    reg [7:0] job_pixel_mask_reg, job_cout_mask_reg;
    reg [31:0] local_param_reads_reg;
    reg [31:0] token_count_reg;
    reg job_done_reg;
    reg stale_reject_reg;

    (* ram_style = "distributed" *) reg signed [63:0] window_mem [0:MAX_CIN-1];
    wire job_shape_ok = (job_cout_tile < ((cout_reg + 7) >> 3)) &&
                        (job_pixel_base < pixels_reg);
    assign job_ready = rst_n && committed_reg && !job_active_reg &&
                       (win_state == WIN_IDLE) && job_shape_ok &&
                       (job_epoch == committed_epoch_reg) &&
                       (job_session == committed_session_reg);
    wire job_fire = job_valid && job_ready;
    assign token_valid = job_active_reg && (win_state == WIN_TOKEN);
    assign token_first = (job_k_reg == 0);
    assign token_last = (job_k_reg == (cin_reg - 1'b1));
    assign token_k_idx = job_k_reg;
    assign token_pixel_base = job_pixel_base_reg;
    assign token_cout_base = {job_cout_tile_reg, 3'b000};
    assign token_pixel_mask = win_pixel_mask_reg;
    assign token_cout_mask = win_cout_mask_reg;
    assign token_act_vec = window_mem[job_k_reg];
    assign token_wgt_vec = param_mem[(job_cout_tile_reg * MAX_CIN) + job_k_reg];
    wire token_fire = token_valid && token_ready;
    assign job_done = job_done_reg;
    assign local_source_word_read_count = local_source_reads_reg;
    assign local_param_row_read_count = local_param_reads_reg;
    assign token_count = token_count_reg;
    assign window_reuse_count = window_reuse_reg;
    assign busy = load_active || job_active_reg || (win_state != WIN_IDLE);

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            cfg_layer_reg <= 0; cfg_mode_reg <= 0; cfg_epoch_reg <= 0;
            cfg_session_reg <= 0; cfg_valid_reg <= 0;
            cin_reg <= 0; cout_reg <= 0; pixels_reg <= 0;
            source_pixels_reg <= 0; source_words_reg <= 0; param_words_reg <= 0;
            source_base_reg <= 0; param_base_reg <= 0;
            src_ld_state <= LD_IDLE; param_ld_state <= LD_IDLE;
            source_cursor <= 0; param_cursor <= 0;
            source_req_count_reg <= 0; param_req_count_reg <= 0;
            source_stall_reg <= 0; param_stall_reg <= 0;
            committed_reg <= 0; committed_epoch_reg <= 0; committed_session_reg <= 0;
            load_done_reg <= 0; commit_reject <= 0;
            win_state <= WIN_IDLE; win_valid <= 0; win_pixel_base_reg <= 0;
            win_epoch_reg <= 0; win_session_reg <= 0;
            win_pixel_mask_reg <= 0; win_cout_mask_reg <= 0;
            win_word_cursor <= 0; win_pixel_slot <= 0; win_words_per_pixel <= 0;
            win_word_in_pixel <= 0; win_rd_data_reg <= 0; win_base_word_reg <= 0;
            local_source_reads_reg <= 0; window_reuse_reg <= 0;
            job_k_reg <= 0; job_active_reg <= 0; job_cout_tile_reg <= 0;
            job_pixel_base_reg <= 0; job_pixel_mask_reg <= 0; job_cout_mask_reg <= 0;
            local_param_reads_reg <= 0; token_count_reg <= 0; job_done_reg <= 0;
            stale_reject_reg <= 0; job_reject_stale <= 0;
            /* window_mem is completely overwritten before WIN_TOKEN; leaving
             * it uninitialised avoids a simulator-only nonblocking array
             * reset loop and maps the small local store more naturally. */
        end else begin
            load_done_reg <= 1'b0;
            commit_reject <= 1'b0;
            job_done_reg <= 1'b0;
            job_reject_stale <= 1'b0;

            if (cfg_fire) begin
                cfg_layer_reg <= cfg_layer_id;
                cfg_mode_reg <= cfg_mode;
                cfg_epoch_reg <= cfg_epoch;
                cfg_session_reg <= cfg_session;
                cin_reg <= shape_cin(cfg_layer_id, cfg_mode);
                cout_reg <= shape_cout(cfg_layer_id, cfg_mode);
                pixels_reg <= shape_pixels(cfg_layer_id);
                source_pixels_reg <= shape_source_pixels(cfg_layer_id, cfg_mode);
                source_words_reg <= shape_source_words(cfg_layer_id, cfg_mode);
                param_words_reg <= shape_param_words(cfg_layer_id, cfg_mode);
                cfg_valid_reg <= 1'b1;
                committed_reg <= 1'b0;
                src_ld_state <= LD_IDLE;
                param_ld_state <= LD_IDLE;
                win_valid <= 1'b0;
                win_state <= WIN_IDLE;
                state <= ST_IDLE;
            end
            if (load_start_fire) begin
                source_base_reg <= load_source_base_addr;
                param_base_reg <= load_param_base_addr;
                source_cursor <= 0; param_cursor <= 0;
                source_req_count_reg <= 0; param_req_count_reg <= 0;
                source_stall_reg <= 0; param_stall_reg <= 0;
                src_ld_state <= LD_SRC_REQ;
                param_ld_state <= LD_PARAM_REQ;
                state <= ST_LOAD;
            end
            if (source_req_valid && !source_req_ready)
                source_stall_reg <= source_stall_reg + 1'b1;
            if (param_req_valid && !param_req_ready)
                param_stall_reg <= param_stall_reg + 1'b1;

            if (source_req_fire) begin
                source_req_count_reg <= source_req_count_reg + 1'b1;
                src_ld_state <= LD_SRC_WAIT;
            end
            if ((src_ld_state == LD_SRC_WAIT) && source_resp_valid) begin
                source_mem[source_cursor] <= source_resp_data;
                if (source_cursor == (source_words_reg - 1'b1)) begin
                    source_cursor <= source_cursor;
                    src_ld_state <= LD_DONE;
                end else begin
                    source_cursor <= source_cursor + 1'b1;
                    src_ld_state <= LD_SRC_REQ;
                end
            end
            if (param_req_fire) begin
                param_req_count_reg <= param_req_count_reg + 1'b1;
                param_ld_state <= LD_PARAM_WAIT;
            end
            if ((param_ld_state == LD_PARAM_WAIT) && param_resp_valid) begin
                if (param_cursor[0] == 1'b0)
                    param_mem[param_physical_row(param_cursor)][31:0] <= param_resp_data;
                else
                    param_mem[param_physical_row(param_cursor)][63:32] <= param_resp_data;
                if (param_cursor == (param_words_reg - 1'b1)) begin
                    param_cursor <= param_cursor;
                    param_ld_state <= LD_DONE;
                end else begin
                    param_cursor <= param_cursor + 1'b1;
                    param_ld_state <= LD_PARAM_REQ;
                end
            end
            if ((src_ld_state == LD_DONE) && (param_ld_state == LD_DONE))
                load_done_reg <= 1'b1;
            if (commit_valid && !commit_ready)
                commit_reject <= 1'b1;
            if (commit_fire) begin
                committed_reg <= 1'b1;
                committed_epoch_reg <= cfg_epoch_reg;
                committed_session_reg <= cfg_session_reg;
                /* Return to the quiescent controller state.  cfg_ready is
                 * intentionally still gated by the live load/job state, so a
                 * later layer may replace the descriptor without a reset. */
                state <= ST_IDLE;
            end

            /* A job for a new spatial block gathers the source words exactly
             * once.  Repeated cout tiles at that pixel use the same window. */
            if (job_fire) begin
                job_active_reg <= 1'b1;
                job_cout_tile_reg <= job_cout_tile;
                job_pixel_base_reg <= job_pixel_base;
                job_pixel_mask_reg <= job_pixel_mask;
                job_cout_mask_reg <= job_cout_mask;
                job_k_reg <= 0;
                if (win_valid && (win_pixel_base_reg == job_pixel_base) &&
                    (win_epoch_reg == job_epoch) && (win_session_reg == job_session)) begin
                    /* The gathered data is reusable, but masks are per job
                     * because a spatial/channel tail may differ between
                     * adjacent output tiles. */
                    win_pixel_mask_reg <= job_pixel_mask;
                    win_cout_mask_reg <= job_cout_mask;
                    win_state <= WIN_TOKEN;
                    window_reuse_reg <= window_reuse_reg + 1'b1;
                end else begin
                    win_valid <= 1'b0;
                    win_state <= WIN_REQ;
                    win_pixel_base_reg <= job_pixel_base;
                    win_epoch_reg <= job_epoch;
                    win_session_reg <= job_session;
                    win_pixel_mask_reg <= job_pixel_mask;
                    win_cout_mask_reg <= job_cout_mask;
                    win_word_cursor <= 0;
                    win_pixel_slot <= 0;
                    win_word_in_pixel <= 0;
                    win_words_per_pixel <= cin_reg >> 2;
                    win_base_word_reg <= (job_pixel_base * (cin_reg >> 2));
                end
            end
            if (job_valid && !job_ready && committed_reg &&
                ((job_epoch != committed_epoch_reg) ||
                 (job_session != committed_session_reg))) begin
                job_reject_stale <= 1'b1;
            end

            if (win_state == WIN_REQ) begin
                /* synchronous local BRAM read */
                win_rd_data_reg <= source_mem[win_base_word_reg + win_word_cursor];
                local_source_reads_reg <= local_source_reads_reg + 1'b1;
                win_state <= WIN_WAIT;
            end
            if ((win_state == WIN_WAIT)) begin
                /* Each dense source word contains four adjacent channels of
                 * one pixel.  The local window is transposed once; subsequent
                 * K tokens are narrow row reads, not a wide image mux. */
                window_mem[(win_word_in_pixel << 2) + 0][(win_pixel_slot*8) +: 8] <= win_rd_data_reg[7:0];
                window_mem[(win_word_in_pixel << 2) + 1][(win_pixel_slot*8) +: 8] <= win_rd_data_reg[15:8];
                window_mem[(win_word_in_pixel << 2) + 2][(win_pixel_slot*8) +: 8] <= win_rd_data_reg[23:16];
                window_mem[(win_word_in_pixel << 2) + 3][(win_pixel_slot*8) +: 8] <= win_rd_data_reg[31:24];
                if (win_word_cursor == ((8 * (cin_reg >> 2)) - 1'b1)) begin
                    win_valid <= 1'b1;
                    win_state <= WIN_TOKEN;
                end else begin
                    win_word_cursor <= win_word_cursor + 1'b1;
                    if (win_word_in_pixel == ((cin_reg >> 2) - 1'b1)) begin
                        win_word_in_pixel <= 0;
                        win_pixel_slot <= win_pixel_slot + 1'b1;
                    end else begin
                        win_word_in_pixel <= win_word_in_pixel + 1'b1;
                    end
                    win_state <= WIN_REQ;
                end
            end
            if (token_fire) begin
                local_param_reads_reg <= local_param_reads_reg + 1'b1;
                local_source_reads_reg <= local_source_reads_reg + 1'b1;
                token_count_reg <= token_count_reg + 1'b1;
                if (job_k_reg == (cin_reg - 1'b1)) begin
                    job_active_reg <= 1'b0;
                    win_state <= WIN_IDLE;
                    job_done_reg <= 1'b1;
                end else begin
                    job_k_reg <= job_k_reg + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
