`timescale 1ns/1ps
`default_nettype none

/*
 * Physically bounded implementation of the persistent DS feed contract.
 *
 * This is a replacement proof vehicle for ds_persistent_feed_contract.  It
 * deliberately keeps the external ABI unchanged, but separates every RAM
 * write/read into fixed banks:
 *
 *   source_mem : one 32-bit SDP BRAM, scalar loader writes and one read port;
 *   param_lo/hi: two 32-bit SDP BRAMs, one fixed row address and half-word
 *               phase per loader response;
 *   window rows: 32 x 64-bit registers with static generated write enables.
 *
 * The loader cursor is tile/k/halfword state, not a division by cin.  The
 * source gather cursor is a registered linear address.  A token reads a
 * registered parameter row one cycle ahead, so parameter BRAM latency is part
 * of the protocol and token payload remains stable during backpressure.
 *
 * The module is intentionally independent of cnn_top/cnn_layer_runner.  It
 * supports the same PW token contract and DS1/DS3/DS6 shape/traffic modes as
 * the original contract module.  mode=1 retains the original accounting
 * footprint; the token interface remains the PW-shaped interface, as in the
 * original proof vehicle.
 */
/* Keep the legacy module name in this standalone file so existing ABI tests
 * can be reused without a second wrapper port list.  The original contract
 * source file is intentionally not part of this file's filelist. */
module ds_persistent_feed_contract #(
    parameter integer MAX_SOURCE_WORDS = 32768,
    parameter integer MAX_PARAM_ROWS = 4096,
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 256,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer SESSION_WIDTH = 4
) (
    input wire clk, (* max_fanout = 500 *) input wire rst_n,
    input wire cfg_valid, output wire cfg_ready,
    input wire [2:0] cfg_layer_id, input wire cfg_mode,
    input wire [EPOCH_WIDTH-1:0] cfg_epoch,
    input wire [SESSION_WIDTH-1:0] cfg_session,
    output wire [15:0] cfg_output_pixels, output wire [7:0] cfg_cin,
    output wire [8:0] cfg_cout, output wire [15:0] cfg_source_pixels,
    output wire [15:0] cfg_source_words, output wire [15:0] cfg_param_words,
    input wire load_start_valid, output wire load_start_ready,
    input wire [31:0] load_source_base_addr, input wire [31:0] load_param_base_addr,
    output wire source_req_valid, input wire source_req_ready,
    output wire [31:0] source_req_addr, input wire source_resp_valid,
    output wire source_resp_ready, input wire [31:0] source_resp_data,
    output wire param_req_valid, input wire param_req_ready,
    output wire [31:0] param_req_addr, input wire param_resp_valid,
    output wire param_resp_ready, input wire [31:0] param_resp_data,
    output wire load_active, output wire load_done,
    output wire [15:0] source_external_word_count,
    output wire [15:0] param_external_word_count,
    output wire [15:0] source_request_stall_count,
    output wire [15:0] param_request_stall_count,
    input wire commit_valid, output wire commit_ready,
    output reg commit_reject, output wire committed_valid,
    output wire [EPOCH_WIDTH-1:0] committed_epoch,
    output wire [SESSION_WIDTH-1:0] committed_session,
    input wire job_valid, output wire job_ready,
    input wire [EPOCH_WIDTH-1:0] job_epoch,
    input wire [SESSION_WIDTH-1:0] job_session,
    input wire [9:0] job_pixel_base, input wire [4:0] job_cout_tile,
    input wire [7:0] job_pixel_mask, input wire [7:0] job_cout_mask,
    output wire job_reject_stale,
    output wire token_valid, input wire token_ready,
    output wire token_first, output wire token_last,
    output wire [7:0] token_k_idx, output wire [9:0] token_pixel_base,
    output wire [8:0] token_cout_base, output wire [7:0] token_pixel_mask,
    output wire [7:0] token_cout_mask,
    output wire signed [63:0] token_act_vec,
    output wire signed [63:0] token_wgt_vec,
    output wire job_done, output wire busy,
    output wire [15:0] local_source_word_read_count,
    output wire [31:0] local_param_row_read_count,
    output wire [31:0] token_count, output wire [15:0] window_reuse_count
);
    localparam integer SOURCE_AW = (MAX_SOURCE_WORDS > 1) ? $clog2(MAX_SOURCE_WORDS) : 1;
    localparam integer PARAM_AW = (MAX_PARAM_ROWS > 1) ? $clog2(MAX_PARAM_ROWS) : 1;
    localparam integer MAX_CIN_SHIFT = $clog2(MAX_CIN);
    localparam [2:0] LD_IDLE = 3'd0, LD_REQ = 3'd1, LD_WAIT = 3'd2,
                     LD_DONE = 3'd3;
    localparam [2:0] WIN_IDLE = 3'd0, WIN_REQ = 3'd1, WIN_WAIT = 3'd2,
                     WIN_WRITE = 3'd3, WIN_PREP = 3'd4, WIN_PWAIT = 3'd5,
                     WIN_TOKEN = 3'd6;

    function automatic [7:0] shape_cin(input [2:0] lid, input mode);
        begin
            case (lid)
                3'd1: shape_cin = 8'd16;
                3'd3: shape_cin = 8'd64;
                3'd6: shape_cin = 8'd128;
                default: shape_cin = 8'd0;
            endcase
        end
    endfunction
    function automatic [8:0] shape_cout(input [2:0] lid, input mode);
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
    function automatic [15:0] shape_pixels(input [2:0] lid);
        begin
            case (lid)
                3'd1: shape_pixels = 16'd1024;
                3'd3: shape_pixels = 16'd256;
                3'd6: shape_pixels = 16'd16;
                default: shape_pixels = 16'd0;
            endcase
        end
    endfunction
    function automatic [15:0] shape_source_pixels(input [2:0] lid, input mode);
        begin
            if (!mode) shape_source_pixels = shape_pixels(lid);
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
    function automatic [15:0] shape_source_words(input [2:0] lid, input mode);
        reg [23:0] n;
        begin n = shape_source_pixels(lid, mode) * shape_cin(lid, mode);
              shape_source_words = (n + 3) >> 2; end
    endfunction
    function automatic [15:0] shape_param_words(input [2:0] lid, input mode);
        reg [23:0] n;
        begin n = shape_cin(lid, mode) * shape_cout(lid, mode);
              if (mode) n = 9 * shape_cin(lid, mode);
              shape_param_words = (n + 3) >> 2; end
    endfunction

    reg [2:0] cfg_layer_reg;
    reg cfg_mode_reg, cfg_valid_reg;
    reg [EPOCH_WIDTH-1:0] cfg_epoch_reg;
    reg [SESSION_WIDTH-1:0] cfg_session_reg;
    reg [7:0] cin_reg;
    reg [8:0] cout_reg;
    reg [15:0] pixels_reg, source_pixels_reg, source_words_reg, param_words_reg;
    /* External bases are consumed by the request-address registers only.
     * Do not retain a second live copy: these two wide, otherwise-unused
     * registers used to become a high-fanout control island after synthesis.
     * The request cursor itself is the authoritative address state. */
    /* The external address ports use local monotonic cursors.  Keeping the
     * base snapshot out of a live adder/cursor cone avoids routing one base
     * bit to every carry stage and leaves only the four-byte increment in the
     * local request island. */
    (* keep = "true" *) reg [31:0] source_req_addr_reg;
    (* keep = "true" *) reg [31:0] param_req_addr_reg;
    reg [2:0] src_state, param_state;
    reg [15:0] source_cursor, param_cursor;
    reg [15:0] src_ext_count, param_ext_count, src_stall, param_stall;
    reg committed_reg;
    reg [EPOCH_WIDTH-1:0] committed_epoch_reg;
    reg [SESSION_WIDTH-1:0] committed_session_reg;
    reg load_done_reg;

    /* Physical parameter address state.  A row is always tile_base+k where
     * tile_base advances by MAX_CIN, independent of the active cin. */
    reg [PARAM_AW-1:0] param_row_addr;
    reg [4:0] param_tile_idx;
    reg [7:0] param_k_in_tile;
    reg param_half;

    wire cfg_shape_ok = (shape_cin(cfg_layer_id, cfg_mode) != 0) &&
                        (shape_cout(cfg_layer_id, cfg_mode) != 0) &&
                        (shape_source_words(cfg_layer_id, cfg_mode) <= MAX_SOURCE_WORDS) &&
                        (shape_param_words(cfg_layer_id, cfg_mode) <= (MAX_PARAM_ROWS*2));
    wire load_active_i = ((src_state != LD_IDLE) && (src_state != LD_DONE)) ||
                         ((param_state != LD_IDLE) && (param_state != LD_DONE));
    assign cfg_output_pixels = shape_pixels(cfg_layer_id);
    assign cfg_cin = shape_cin(cfg_layer_id, cfg_mode);
    assign cfg_cout = shape_cout(cfg_layer_id, cfg_mode);
    assign cfg_source_pixels = shape_source_pixels(cfg_layer_id, cfg_mode);
    assign cfg_source_words = shape_source_words(cfg_layer_id, cfg_mode);
    assign cfg_param_words = shape_param_words(cfg_layer_id, cfg_mode);
    assign cfg_ready = rst_n && !load_active_i && !job_active_reg &&
                       !job_launch_pending &&
                       (win_state == WIN_IDLE) && (!cfg_valid_reg_isolated || committed_reg);
    wire cfg_fire = cfg_valid && cfg_ready && cfg_shape_ok;
    assign load_start_ready = rst_n && cfg_valid_reg && !committed_reg &&
                              (src_state == LD_IDLE) && (param_state == LD_IDLE);
    wire load_start_fire = load_start_valid && load_start_ready;
    assign source_req_valid = (src_state == LD_REQ) && (source_cursor < source_words_reg);
    assign source_req_addr = source_req_addr_reg;
    assign source_resp_ready = (src_state_isolated == LD_WAIT);
    assign param_req_valid = (param_state == LD_REQ) && (param_cursor < param_words_reg);
    assign param_req_addr = param_req_addr_reg;
    assign param_resp_ready = (param_state_isolated == LD_WAIT);
    wire source_req_fire = source_req_valid && source_req_ready;
    wire param_req_fire = param_req_valid && param_req_ready;
    wire source_resp_fire = source_resp_valid && source_resp_ready;
    wire param_resp_fire = param_resp_valid && param_resp_ready;
    assign load_active = load_active_i;
    assign load_done = load_done_reg;
    assign source_external_word_count = src_ext_count;
    assign param_external_word_count = param_ext_count;
    assign source_request_stall_count = src_stall;
    assign param_request_stall_count = param_stall;
    assign commit_ready = rst_n && cfg_valid_reg && !committed_reg &&
                          (src_state == LD_DONE) && (param_state == LD_DONE);
    wire commit_fire = commit_valid && commit_ready;
    assign committed_valid = committed_reg;
    /* cfg_* are immutable for the duration of a committed image.  Reusing
     * those descriptor registers avoids a direct descriptor-to-descriptor
     * hold path while preserving the externally visible commit snapshot. */
    assign committed_epoch = cfg_epoch_reg;
    assign committed_session = cfg_session_reg;
    assign job_reject_stale = job_valid && committed_reg &&
                              ((job_epoch != cfg_epoch_reg) ||
                               (job_session != cfg_session_reg));

    /* Fixed-width BRAMs.  The simulation branches have identical synchronous
     * latency and read-first behavior to the XPM instances. */
    wire [31:0] source_rd_data;
    wire [31:0] param_lo_rd_data, param_hi_rd_data;
    wire [31:0] param_dout [0:1];
    wire [PARAM_AW-1:0] param_wr_addr_delayed;
    wire [SOURCE_AW-1:0] source_rd_addr_delayed;
    wire [SOURCE_AW-1:0] source_wr_addr_delayed;
    wire [SOURCE_AW-1:0] source_cursor_feedback;
    wire [9:0] launch_pixel_base_isolated;
    wire cfg_valid_reg_isolated;
    wire [2:0] param_state_isolated;
    wire [2:0] src_state_isolated;
    wire [2:0] win_state_isolated;
    wire [7:0] win_word_cursor_feedback;
    wire win_valid_isolated;
    wire source_wr_en = source_resp_fire;
    wire param_wr_en = param_resp_fire;
    reg source_rd_en;
    reg [SOURCE_AW-1:0] source_rd_addr;
    reg param_rd_en;
    reg [PARAM_AW-1:0] param_rd_addr;

`ifdef SYNTHESIS
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(SOURCE_AW), .ADDR_WIDTH_B(SOURCE_AW),
        .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(MAX_SOURCE_WORDS*32), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(32), .WRITE_MODE_B("read_first")
    ) u_source_mem (
        .clka(clk), .clkb(clk), .ena(source_wr_en), .enb(source_rd_en),
        .addra(source_wr_addr_delayed), .addrb(source_rd_addr_delayed),
        .dina(source_resp_data), .wea(4'hf), .doutb(source_rd_data),
        .regceb(1'b1), .rstb(!rst_n), .sleep(1'b0),
        .injectdbiterra(1'b0), .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb()
    );
    genvar pb;
    generate for (pb=0; pb<2; pb=pb+1) begin : gen_param_bank
        xpm_memory_sdpram #(
            .ADDR_WIDTH_A(PARAM_AW), .ADDR_WIDTH_B(PARAM_AW),
            .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
            .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
            .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
            .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
            .MEMORY_SIZE(MAX_PARAM_ROWS*32), .MESSAGE_CONTROL(0),
            .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
            .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
            .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
            .WRITE_DATA_WIDTH_A(32), .WRITE_MODE_B("read_first")
        ) u_param_mem (
            .clka(clk), .clkb(clk), .ena(param_wr_en && (param_half == pb[0])),
            .enb(param_rd_en), .addra(param_wr_addr_delayed), .addrb(param_rd_addr),
            .dina(param_resp_data), .wea(4'hf), .doutb(param_dout[pb]),
            .regceb(1'b1), .rstb(!rst_n), .sleep(1'b0),
            .injectdbiterra(1'b0), .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb()
        );
    end endgenerate
`else
    (* ram_style = "block" *) reg [31:0] source_mem [0:MAX_SOURCE_WORDS-1];
    (* ram_style = "block" *) reg [31:0] param_lo_mem [0:MAX_PARAM_ROWS-1];
    (* ram_style = "block" *) reg [31:0] param_hi_mem [0:MAX_PARAM_ROWS-1];
    reg [31:0] source_rd_data_reg, param_lo_rd_data_reg, param_hi_rd_data_reg;
    assign source_rd_data = source_rd_data_reg;
    assign param_lo_rd_data = param_lo_rd_data_reg;
    assign param_hi_rd_data = param_hi_rd_data_reg;
    always @(posedge clk) begin
        if (source_wr_en) source_mem[source_cursor] <= source_resp_data;
        if (source_rd_en) source_rd_data_reg <= source_mem[source_rd_addr];
        if (param_wr_en && !param_half) param_lo_mem[param_row_addr] <= param_resp_data;
        if (param_wr_en && param_half) param_hi_mem[param_row_addr] <= param_resp_data;
        if (param_rd_en) begin
            param_lo_rd_data_reg <= param_lo_mem[param_rd_addr];
            param_hi_rd_data_reg <= param_hi_mem[param_rd_addr];
        end
    end
`endif

`ifdef SYNTHESIS
    /* Keep a small physical isolation stage on the loader address.  Besides
     * making the write-address island local to the two parameter banks, this
     * avoids a near-zero hold path from the row cursor directly into a BRAM
     * address pin.  INIT=identity; it does not alter the address contract. */
    genvar da;
    generate for (da=0; da<PARAM_AW; da=da+1) begin : gen_param_addr_isolation
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_addr_iso
            (.I0(param_row_addr[da]), .O(param_wr_addr_delayed[da]));
    end endgenerate
    genvar sa;
    generate for (sa=0; sa<SOURCE_AW; sa=sa+1) begin : gen_source_addr_isolation
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_addr_iso
            (.I0(source_rd_addr[sa]), .O(source_rd_addr_delayed[sa]));
    end endgenerate
    genvar sw;
    generate for (sw=0; sw<SOURCE_AW; sw=sw+1) begin : gen_source_wr_addr_isolation
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_addr_iso
            (.I0(source_cursor[sw]), .O(source_wr_addr_delayed[sw]));
    end endgenerate
    genvar sf;
    generate for (sf=0; sf<SOURCE_AW; sf=sf+1) begin : gen_source_cursor_feedback
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_cursor_iso
            (.I0(source_cursor[sf]), .O(source_cursor_feedback[sf]));
    end endgenerate
    genvar lp;
    generate for (lp=0; lp<10; lp=lp+1) begin : gen_launch_pixel_isolation
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_pixel_iso
            (.I0(launch_pixel_base_reg[lp]), .O(launch_pixel_base_isolated[lp]));
    end endgenerate
    (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_cfg_valid_isolation
        (.I0(cfg_valid_reg), .O(cfg_valid_reg_isolated));
    genvar ps;
    generate for (ps=0; ps<3; ps=ps+1) begin : gen_param_state_isolation
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_state_iso
            (.I0(param_state[ps]), .O(param_state_isolated[ps]));
    end endgenerate
    genvar ss;
    generate for (ss=0; ss<3; ss=ss+1) begin : gen_src_state_isolation
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_state_iso
            (.I0(src_state[ss]), .O(src_state_isolated[ss]));
    end endgenerate
    genvar ws;
    generate for (ws=0; ws<3; ws=ws+1) begin : gen_win_state_isolation
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_state_iso
            (.I0(win_state[ws]), .O(win_state_isolated[ws]));
    end endgenerate
    genvar wc;
    generate for (wc=0; wc<8; wc=wc+1) begin : gen_win_cursor_feedback
        (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_cursor_iso
            (.I0(win_word_cursor[wc]), .O(win_word_cursor_feedback[wc]));
    end endgenerate
    (* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'b10)) u_win_valid_iso
        (.I0(win_valid), .O(win_valid_isolated));
    assign param_lo_rd_data = param_dout[0];
    assign param_hi_rd_data = param_dout[1];
`else
    assign param_wr_addr_delayed = param_row_addr;
    assign source_rd_addr_delayed = source_rd_addr;
    assign source_wr_addr_delayed = source_cursor;
    assign source_cursor_feedback = source_cursor;
    assign launch_pixel_base_isolated = launch_pixel_base_reg;
    assign cfg_valid_reg_isolated = cfg_valid_reg;
    assign param_state_isolated = param_state;
    assign src_state_isolated = src_state;
    assign win_state_isolated = win_state;
    assign win_word_cursor_feedback = win_word_cursor;
    assign win_valid_isolated = win_valid;
`endif

    /* ---------------- static eight-pixel transposed window ---------------- */
    reg [2:0] win_state;
    reg win_valid;
    reg [9:0] win_pixel_base_reg;
    reg [EPOCH_WIDTH-1:0] win_epoch_reg;
    reg [SESSION_WIDTH-1:0] win_session_reg;
    reg [7:0] win_pixel_mask_reg, win_cout_mask_reg;
    reg [7:0] win_word_cursor, win_pixel_slot, win_word_in_pixel;
    reg [7:0] win_words_per_pixel;
    reg [SOURCE_AW-1:0] win_source_addr_reg;
    reg [4:0] words_shift_reg;
    reg [7:0] job_k_reg;
    reg job_active_reg;
    reg job_launch_pending;
    reg [EPOCH_WIDTH-1:0] launch_epoch_reg;
    reg [SESSION_WIDTH-1:0] launch_session_reg;
    reg [9:0] launch_pixel_base_reg;
    reg [4:0] launch_cout_tile_reg;
    reg [7:0] launch_pixel_mask_reg, launch_cout_mask_reg;
    reg launch_reuse_reg;
    reg [4:0] job_cout_tile_reg;
    reg [9:0] job_pixel_base_reg;
    reg [7:0] job_pixel_mask_reg, job_cout_mask_reg;
    reg [PARAM_AW-1:0] job_param_base_reg;
    /* Registered look-ahead cursor removes job_k_reg from the BRAM address
     * path.  It is initialized to k=1 when a job launches; each accepted
     * token advances it, so WIN_TOKEN can issue the next row at II=1 without
     * a token-last/job-k priority cone. */
    reg [7:0] param_read_cursor_reg;
    reg [15:0] local_source_reads_reg, window_reuse_reg;
    reg [31:0] local_param_reads_reg, token_count_reg;
    reg job_done_reg;
    /* Eight cluster copies feed four channel-row banks each.  This is a
     * single-cycle, II-preserving fanout tree from the synchronous source
     * BRAM; each cluster is valid only under the window/epoch fence. */
    (* keep = "true" *) reg [31:0] source_cluster_data [0:7];
    integer sg;

    /* Each generated row has only fixed byte writes.  A group stores four
     * channel rows, each with eight pixels.  All writes below select a fixed
     * byte position; no variable-indexed RAM or variable part-select write is
     * present in this physical adapter. */
    genvar wrg;
    generate for (wrg=0; wrg<32; wrg=wrg+1) begin : gen_window_row
        reg [63:0] row0_reg, row1_reg, row2_reg, row3_reg;
        /* The cluster register is shared by only four adjacent channel-row
         * banks.  Keep the aliases local to this generated island so the
         * source word never becomes a device-wide data net. */
        wire [31:0] local_source_data = source_cluster_data[wrg/4];
        wire [7:0] local_src0 = local_source_data[7:0];
        wire [7:0] local_src1 = local_source_data[15:8];
        wire [7:0] local_src2 = local_source_data[23:16];
        wire [7:0] local_src3 = local_source_data[31:24];
        always @(posedge clk) begin
            /* Window storage is resetless by construction.  win_valid plus
             * the captured epoch/session below is the ownership fence; every
             * byte of a row image is rewritten before a token can be issued.
             * This keeps the 32x256-bit data image out of the global reset
             * network without exposing stale data to a job. */
            if ((win_state == WIN_WRITE) && (win_word_in_pixel == wrg[7:0])) begin
                case (win_pixel_slot)
                    8'd0: begin row0_reg[7:0] <= local_src0; row1_reg[7:0] <= local_src1; row2_reg[7:0] <= local_src2; row3_reg[7:0] <= local_src3; end
                    8'd1: begin row0_reg[15:8] <= local_src0; row1_reg[15:8] <= local_src1; row2_reg[15:8] <= local_src2; row3_reg[15:8] <= local_src3; end
                    8'd2: begin row0_reg[23:16] <= local_src0; row1_reg[23:16] <= local_src1; row2_reg[23:16] <= local_src2; row3_reg[23:16] <= local_src3; end
                    8'd3: begin row0_reg[31:24] <= local_src0; row1_reg[31:24] <= local_src1; row2_reg[31:24] <= local_src2; row3_reg[31:24] <= local_src3; end
                    8'd4: begin row0_reg[39:32] <= local_src0; row1_reg[39:32] <= local_src1; row2_reg[39:32] <= local_src2; row3_reg[39:32] <= local_src3; end
                    8'd5: begin row0_reg[47:40] <= local_src0; row1_reg[47:40] <= local_src1; row2_reg[47:40] <= local_src2; row3_reg[47:40] <= local_src3; end
                    8'd6: begin row0_reg[55:48] <= local_src0; row1_reg[55:48] <= local_src1; row2_reg[55:48] <= local_src2; row3_reg[55:48] <= local_src3; end
                    default: begin row0_reg[63:56] <= local_src0; row1_reg[63:56] <= local_src1; row2_reg[63:56] <= local_src2; row3_reg[63:56] <= local_src3; end
                endcase
            end
        end
    end endgenerate

    /* First choose the 4-channel group, then one fixed channel row.  This is
     * a shallow FF mux and is intentionally outside any RAM primitive. */
    reg [255:0] window_selected_group;
    reg [63:0] window_selected_row;
    always @* begin
        window_selected_group = 256'd0;
        case (job_k_reg[7:2])
            6'd0: window_selected_group = {gen_window_row[0].row3_reg, gen_window_row[0].row2_reg, gen_window_row[0].row1_reg, gen_window_row[0].row0_reg};
            6'd1: window_selected_group = {gen_window_row[1].row3_reg, gen_window_row[1].row2_reg, gen_window_row[1].row1_reg, gen_window_row[1].row0_reg};
            6'd2: window_selected_group = {gen_window_row[2].row3_reg, gen_window_row[2].row2_reg, gen_window_row[2].row1_reg, gen_window_row[2].row0_reg};
            6'd3: window_selected_group = {gen_window_row[3].row3_reg, gen_window_row[3].row2_reg, gen_window_row[3].row1_reg, gen_window_row[3].row0_reg};
            6'd4: window_selected_group = {gen_window_row[4].row3_reg, gen_window_row[4].row2_reg, gen_window_row[4].row1_reg, gen_window_row[4].row0_reg};
            6'd5: window_selected_group = {gen_window_row[5].row3_reg, gen_window_row[5].row2_reg, gen_window_row[5].row1_reg, gen_window_row[5].row0_reg};
            6'd6: window_selected_group = {gen_window_row[6].row3_reg, gen_window_row[6].row2_reg, gen_window_row[6].row1_reg, gen_window_row[6].row0_reg};
            6'd7: window_selected_group = {gen_window_row[7].row3_reg, gen_window_row[7].row2_reg, gen_window_row[7].row1_reg, gen_window_row[7].row0_reg};
            6'd8: window_selected_group = {gen_window_row[8].row3_reg, gen_window_row[8].row2_reg, gen_window_row[8].row1_reg, gen_window_row[8].row0_reg};
            6'd9: window_selected_group = {gen_window_row[9].row3_reg, gen_window_row[9].row2_reg, gen_window_row[9].row1_reg, gen_window_row[9].row0_reg};
            6'd10: window_selected_group = {gen_window_row[10].row3_reg, gen_window_row[10].row2_reg, gen_window_row[10].row1_reg, gen_window_row[10].row0_reg};
            6'd11: window_selected_group = {gen_window_row[11].row3_reg, gen_window_row[11].row2_reg, gen_window_row[11].row1_reg, gen_window_row[11].row0_reg};
            6'd12: window_selected_group = {gen_window_row[12].row3_reg, gen_window_row[12].row2_reg, gen_window_row[12].row1_reg, gen_window_row[12].row0_reg};
            6'd13: window_selected_group = {gen_window_row[13].row3_reg, gen_window_row[13].row2_reg, gen_window_row[13].row1_reg, gen_window_row[13].row0_reg};
            6'd14: window_selected_group = {gen_window_row[14].row3_reg, gen_window_row[14].row2_reg, gen_window_row[14].row1_reg, gen_window_row[14].row0_reg};
            6'd15: window_selected_group = {gen_window_row[15].row3_reg, gen_window_row[15].row2_reg, gen_window_row[15].row1_reg, gen_window_row[15].row0_reg};
            6'd16: window_selected_group = {gen_window_row[16].row3_reg, gen_window_row[16].row2_reg, gen_window_row[16].row1_reg, gen_window_row[16].row0_reg};
            6'd17: window_selected_group = {gen_window_row[17].row3_reg, gen_window_row[17].row2_reg, gen_window_row[17].row1_reg, gen_window_row[17].row0_reg};
            6'd18: window_selected_group = {gen_window_row[18].row3_reg, gen_window_row[18].row2_reg, gen_window_row[18].row1_reg, gen_window_row[18].row0_reg};
            6'd19: window_selected_group = {gen_window_row[19].row3_reg, gen_window_row[19].row2_reg, gen_window_row[19].row1_reg, gen_window_row[19].row0_reg};
            6'd20: window_selected_group = {gen_window_row[20].row3_reg, gen_window_row[20].row2_reg, gen_window_row[20].row1_reg, gen_window_row[20].row0_reg};
            6'd21: window_selected_group = {gen_window_row[21].row3_reg, gen_window_row[21].row2_reg, gen_window_row[21].row1_reg, gen_window_row[21].row0_reg};
            6'd22: window_selected_group = {gen_window_row[22].row3_reg, gen_window_row[22].row2_reg, gen_window_row[22].row1_reg, gen_window_row[22].row0_reg};
            6'd23: window_selected_group = {gen_window_row[23].row3_reg, gen_window_row[23].row2_reg, gen_window_row[23].row1_reg, gen_window_row[23].row0_reg};
            6'd24: window_selected_group = {gen_window_row[24].row3_reg, gen_window_row[24].row2_reg, gen_window_row[24].row1_reg, gen_window_row[24].row0_reg};
            6'd25: window_selected_group = {gen_window_row[25].row3_reg, gen_window_row[25].row2_reg, gen_window_row[25].row1_reg, gen_window_row[25].row0_reg};
            6'd26: window_selected_group = {gen_window_row[26].row3_reg, gen_window_row[26].row2_reg, gen_window_row[26].row1_reg, gen_window_row[26].row0_reg};
            6'd27: window_selected_group = {gen_window_row[27].row3_reg, gen_window_row[27].row2_reg, gen_window_row[27].row1_reg, gen_window_row[27].row0_reg};
            6'd28: window_selected_group = {gen_window_row[28].row3_reg, gen_window_row[28].row2_reg, gen_window_row[28].row1_reg, gen_window_row[28].row0_reg};
            6'd29: window_selected_group = {gen_window_row[29].row3_reg, gen_window_row[29].row2_reg, gen_window_row[29].row1_reg, gen_window_row[29].row0_reg};
            6'd30: window_selected_group = {gen_window_row[30].row3_reg, gen_window_row[30].row2_reg, gen_window_row[30].row1_reg, gen_window_row[30].row0_reg};
            6'd31: window_selected_group = {gen_window_row[31].row3_reg, gen_window_row[31].row2_reg, gen_window_row[31].row1_reg, gen_window_row[31].row0_reg};
            default: window_selected_group = {gen_window_row[31].row3_reg, gen_window_row[31].row2_reg, gen_window_row[31].row1_reg, gen_window_row[31].row0_reg};
        endcase
    end
    always @* begin
        case (job_k_reg[1:0])
            2'd0: window_selected_row = window_selected_group[63:0];
            2'd1: window_selected_row = window_selected_group[127:64];
            2'd2: window_selected_row = window_selected_group[191:128];
            default: window_selected_row = window_selected_group[255:192];
        endcase
    end

    wire job_shape_ok = (job_cout_tile < ((cout_reg + 7) >> 3)) &&
                        (job_pixel_base < pixels_reg);
    assign job_ready = rst_n && committed_reg && !job_active_reg &&
                       !job_launch_pending &&
                       (win_state == WIN_IDLE) && job_shape_ok &&
                       (job_epoch == cfg_epoch_reg) &&
                       (job_session == cfg_session_reg);
    wire job_fire = job_valid && job_ready;
    assign token_valid = job_active_reg && (win_state == WIN_TOKEN);
    assign token_first = (job_k_reg == 0);
    assign token_last = (job_k_reg == (cin_reg - 1'b1));
    assign token_k_idx = job_k_reg;
    assign token_pixel_base = launch_pixel_base_reg;
    assign token_cout_base = {launch_cout_tile_reg,3'b000};
    /* Masks belong to the job, not to the reusable source window.  Driving
     * them from the job capture removes a direct launch-mask -> window-mask
     * hold path and also makes tail changes on a reused window explicit. */
    assign token_pixel_mask = launch_pixel_mask_reg;
    assign token_cout_mask = launch_cout_mask_reg;
    assign token_act_vec = window_selected_row;
    assign token_wgt_vec = {param_hi_rd_data,param_lo_rd_data};
    wire token_fire = token_valid && token_ready;
    assign job_done = job_done_reg;
    assign local_source_word_read_count = local_source_reads_reg;
    assign local_param_row_read_count = local_param_reads_reg;
    assign token_count = token_count_reg;
    assign window_reuse_count = window_reuse_reg;
    assign busy = load_active_i || job_active_reg || job_launch_pending ||
                  (win_state != WIN_IDLE);

    /* State/control.  Source and parameter BRAM enables are registered
     * addresses; parameter look-ahead is active only on an accepted token,
     * preventing payload changes under output backpressure. */
    always @* begin
        source_rd_en = (win_state == WIN_REQ);
        source_rd_addr = win_source_addr_reg;
        param_rd_en = 1'b0;
        param_rd_addr = job_param_base_reg;
        if (win_state == WIN_PREP) begin
            param_rd_en = 1'b1;
            param_rd_addr = job_param_base_reg;
        end else if ((win_state == WIN_TOKEN) && token_ready &&
                     (param_read_cursor_reg < cin_reg)) begin
            param_rd_en = 1'b1;
            param_rd_addr = job_param_base_reg + param_read_cursor_reg;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_layer_reg<=0; cfg_mode_reg<=0; cfg_valid_reg<=0;
            cfg_epoch_reg<=0; cfg_session_reg<=0; cin_reg<=0; cout_reg<=0;
            pixels_reg<=0; source_pixels_reg<=0; source_words_reg<=0; param_words_reg<=0;
            source_req_addr_reg<=0; param_req_addr_reg<=0;
            src_state<=LD_IDLE; param_state<=LD_IDLE;
            source_cursor<=0; param_cursor<=0; src_ext_count<=0; param_ext_count<=0;
            src_stall<=0; param_stall<=0; committed_reg<=0; committed_epoch_reg<=0;
            committed_session_reg<=0; load_done_reg<=0; commit_reject<=0;
            param_row_addr<=0; param_tile_idx<=0; param_k_in_tile<=0; param_half<=0;
            win_state<=WIN_IDLE; win_valid<=0; win_pixel_base_reg<=0; win_epoch_reg<=0;
            win_session_reg<=0; win_pixel_mask_reg<=0; win_cout_mask_reg<=0;
            win_word_cursor<=0; win_pixel_slot<=0; win_word_in_pixel<=0;
            win_words_per_pixel<=0; win_source_addr_reg<=0; words_shift_reg<=0;
            job_k_reg<=0; job_active_reg<=0; job_cout_tile_reg<=0; job_pixel_base_reg<=0;
            job_launch_pending<=0; launch_epoch_reg<=0; launch_session_reg<=0;
            launch_pixel_base_reg<=0; launch_cout_tile_reg<=0;
            launch_pixel_mask_reg<=0; launch_cout_mask_reg<=0;
            launch_reuse_reg<=0;
            job_pixel_mask_reg<=0; job_cout_mask_reg<=0; job_param_base_reg<=0;
            param_read_cursor_reg<=0;
            local_source_reads_reg<=0; window_reuse_reg<=0; local_param_reads_reg<=0;
            token_count_reg<=0; job_done_reg<=0;
        end else begin
            load_done_reg<=0; commit_reject<=0; job_done_reg<=0;
            if (cfg_fire) begin
                cfg_layer_reg<=cfg_layer_id; cfg_mode_reg<=cfg_mode;
                cfg_epoch_reg<=cfg_epoch; cfg_session_reg<=cfg_session;
                cin_reg<=shape_cin(cfg_layer_id,cfg_mode);
                cout_reg<=shape_cout(cfg_layer_id,cfg_mode);
                pixels_reg<=shape_pixels(cfg_layer_id);
                source_pixels_reg<=shape_source_pixels(cfg_layer_id,cfg_mode);
                source_words_reg<=shape_source_words(cfg_layer_id,cfg_mode);
                param_words_reg<=shape_param_words(cfg_layer_id,cfg_mode);
                case (shape_cin(cfg_layer_id,cfg_mode))
                    8'd16: words_shift_reg<=2;
                    8'd64: words_shift_reg<=4;
                    default: words_shift_reg<=5;
                endcase
                cfg_valid_reg<=1'b1; committed_reg<=1'b0;
                src_state<=LD_IDLE; param_state<=LD_IDLE; win_valid<=1'b0; win_state<=WIN_IDLE;
            end
            if (load_start_fire) begin
                source_req_addr_reg<=load_source_base_addr;
                param_req_addr_reg<=load_param_base_addr;
                source_cursor<=0; param_cursor<=0; src_ext_count<=0; param_ext_count<=0;
                src_stall<=0; param_stall<=0; param_row_addr<=0; param_tile_idx<=0;
                param_k_in_tile<=0; param_half<=0; src_state<=LD_REQ; param_state<=LD_REQ;
            end
            if (source_req_valid && !source_req_ready) src_stall<=src_stall+1'b1;
            if (param_req_valid && !param_req_ready) param_stall<=param_stall+1'b1;
            if (source_req_fire) begin src_ext_count<=src_ext_count+1'b1; src_state<=LD_WAIT; end
            if (source_resp_fire) begin
                if (source_cursor == source_words_reg-1'b1) src_state<=LD_DONE;
                else begin
                    source_cursor<=source_cursor_feedback+1'b1;
                    source_req_addr_reg<=source_req_addr_reg+32'd4;
                    src_state<=LD_REQ;
                end
            end
            if (param_req_fire) begin param_ext_count<=param_ext_count+1'b1; param_state<=LD_WAIT; end
            if (param_resp_fire) begin
                if (param_cursor == param_words_reg-1'b1) param_state<=LD_DONE;
                else begin
                    param_cursor<=param_cursor+1'b1;
                    param_req_addr_reg<=param_req_addr_reg+32'd4;
                    param_state<=LD_REQ;
                    if (param_half) begin
                        param_half<=1'b0;
                        if (param_k_in_tile == cin_reg-1'b1) begin
                            param_k_in_tile<=0; param_tile_idx<=param_tile_idx+1'b1;
                            param_row_addr<=((param_tile_idx+1'b1) << MAX_CIN_SHIFT);
                        end else begin
                            param_k_in_tile<=param_k_in_tile+1'b1;
                            param_row_addr<=param_row_addr+1'b1;
                        end
                    end else param_half<=1'b1;
                end
            end
            if ((src_state==LD_DONE) && (param_state==LD_DONE)) load_done_reg<=1'b1;
            if (commit_valid && !commit_ready) commit_reject<=1'b1;
            if (commit_fire) committed_reg<=1'b1;

            /* Capture the external handshake first, then launch one cycle
             * later.  This isolates the wide job-shape comparator (and its
             * pixels_reg fanout) from the token/job state enables. */
            if (job_fire) begin
                job_launch_pending<=1'b1; launch_epoch_reg<=job_epoch;
                launch_session_reg<=job_session; launch_pixel_base_reg<=job_pixel_base;
                launch_cout_tile_reg<=job_cout_tile; launch_pixel_mask_reg<=job_pixel_mask;
                launch_cout_mask_reg<=job_cout_mask;
                /* Snapshot the reuse decision before replacing the window
                 * owner.  The owner base itself is captured directly from
                 * the external job handshake, avoiding launch->window hold
                 * timing and keeping the fence point explicit. */
                launch_reuse_reg <= win_valid_isolated && (win_pixel_base_reg == job_pixel_base) &&
                                    (win_epoch_reg == job_epoch) &&
                                    (win_session_reg == job_session);
                win_pixel_base_reg <= job_pixel_base;
                /* This is the active job's fixed BRAM row base.  Capturing it
                 * directly from the external handshake avoids a metadata
                 * FF-to-FF copy when the delayed launch starts. */
                job_param_base_reg <= (job_cout_tile << MAX_CIN_SHIFT);
            end
            if (job_launch_pending) begin
                job_launch_pending<=1'b0; job_active_reg<=1'b1;
                /* launch_* mask registers remain the active job metadata;
                 * avoid a second FF-to-FF mask copy on the token path. */
                job_k_reg<=0;
                param_read_cursor_reg<=1;
                if (launch_reuse_reg) begin
                    /* The job mask registers above are the sole token mask
                     * owner; the gathered source window remains mask-neutral. */
                    win_state<=WIN_PREP; window_reuse_reg<=window_reuse_reg+1'b1;
                end else begin
                    win_valid<=1'b0; win_state<=WIN_REQ;
                    /* The committed cfg descriptor is the epoch/session
                     * fence; no second live metadata copy is needed here. */
                    case (cin_reg)
                        8'd16: begin win_words_per_pixel<=8'd4; words_shift_reg<=2; end
                        8'd64: begin win_words_per_pixel<=8'd16; words_shift_reg<=4; end
                        default: begin win_words_per_pixel<=8'd32; words_shift_reg<=5; end
                    endcase
                    win_word_cursor<=0; win_pixel_slot<=0; win_word_in_pixel<=0;
                    /* source_mem is loaded from local cursor zero; the
                     * external byte base is used only on the request port. */
                    win_source_addr_reg <= (launch_pixel_base_reg << words_shift_reg);
                end
            end
            if (win_state_isolated == WIN_WAIT) begin
                /* Register the BRAM response locally before the generated
                 * row bank consumes it.  This breaks the long BRAM-output to
                 * distributed-row routing span. */
                for (sg=0; sg<8; sg=sg+1)
                    source_cluster_data[sg] <= source_rd_data;
                win_state<=WIN_WRITE;
            end
            if (win_state_isolated == WIN_WRITE) begin
                local_source_reads_reg<=local_source_reads_reg+1'b1;
                if (win_word_cursor == (8*win_words_per_pixel)-1'b1) begin
                    win_valid<=1'b1; win_epoch_reg<=cfg_epoch_reg;
                    win_session_reg<=cfg_session_reg; win_state<=WIN_PREP;
                end else begin
                    win_word_cursor<=win_word_cursor_feedback+1'b1; win_source_addr_reg<=win_source_addr_reg+1'b1;
                    if (win_word_in_pixel == win_words_per_pixel-1'b1) begin
                        win_word_in_pixel<=0; win_pixel_slot<=win_pixel_slot+1'b1;
                    end else win_word_in_pixel<=win_word_in_pixel+1'b1;
                    win_state<=WIN_REQ;
                end
            end
            if (win_state_isolated == WIN_REQ) begin
                /* The BRAM request is accepted in this cycle; its registered
                 * data is consumed by the WIN_WAIT state on the next edge. */
                win_state<=WIN_WAIT;
            end
            if (win_state_isolated == WIN_PREP) begin win_state<=WIN_PWAIT; end
            if (win_state_isolated == WIN_PWAIT) begin win_state<=WIN_TOKEN; end
            if (token_fire) begin
                local_param_reads_reg<=local_param_reads_reg+1'b1;
                local_source_reads_reg<=local_source_reads_reg+1'b1;
                token_count_reg<=token_count_reg+1'b1;
                if (token_last) begin job_active_reg<=1'b0; win_state<=WIN_IDLE; job_done_reg<=1'b1; end
                else begin
                    job_k_reg<=job_k_reg+1'b1;
                    param_read_cursor_reg<=param_read_cursor_reg+1'b1;
                end
            end
        end
    end
endmodule

/* One physical source-response stage per channel-row island.  Only the
 * protocol state is reset; source bytes are meaningful after WIN_WRITE has
 * completed the full valid window and hence do not need reset storage. */
(* keep_hierarchy = "yes" *)
module ds_source_row_stage (
    input wire clk,
    input wire [2:0] win_state,
    input wire [31:0] source_rd_data,
    output reg [7:0] src0,
    output reg [7:0] src1,
    output reg [7:0] src2,
    output reg [7:0] src3
);
    localparam [2:0] WIN_WAIT = 3'd2;
    always @(posedge clk) begin
        if (win_state == WIN_WAIT) begin
            src0 <= source_rd_data[7:0];
            src1 <= source_rd_data[15:8];
            src2 <= source_rd_data[23:16];
            src3 <= source_rd_data[31:24];
        end
    end
endmodule

`default_nettype wire
