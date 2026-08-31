`timescale 1ns/1ps
`default_nettype none

/*
 * Isolated packed pointwise-weight feeder.
 *
 * The loader presents one 32-bit word per cycle.  Two successive words form
 * one 64-bit row in a 4096 x 64 memory.  The physical row address is
 * {cout_tile[4:0], k[6:0]}; bits [31:0] contain output lanes 0..3 and bits
 * [63:32] contain lanes 4..7.  The compute side has no cout_base address
 * dependency: cout_base is captured solely as an output tag.
 *
 * This is deliberately a non-production proof vehicle.  It owns the cursor,
 * one registered BRAM response, and one elastic response slot, then reuses
 * the exact two-lane output-stationary row-bank PW core.
 */
module pw_packed_rowstore_feeder #(
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 256,
    parameter integer ROWBANK_ACT_REPLICATE = 0
) (
    input wire clk,
    input wire rst_n,

    input wire load_begin_valid,
    output wire load_begin_ready,
    input wire [1:0] load_epoch,
    input wire [7:0] load_cin,
    input wire [8:0] load_cout,
    input wire load_word_valid,
    output wire load_word_ready,
    input wire [31:0] load_word_data,
    input wire load_commit_valid,
    output wire load_commit_ready,
    output reg load_commit_reject,
    output reg load_extra_error,
    output wire load_active,
    output wire committed_valid,
    output wire [1:0] committed_epoch,
    output wire [13:0] expected_word_count,
    output wire [13:0] load_word_count,
    output wire [15:0] packed_load_count,

    input wire job_valid,
    output wire job_ready,
    input wire [4:0] job_cout_tile,
    input wire [1:0] job_epoch,
    input wire [4:0] job_group_count,
    input wire job_reverse_groups,
    input wire [5:0] job_pixel_base,
    input wire [8:0] job_cout_base,
    input wire [7:0] job_output_pixels,
    input wire [8:0] job_output_channels,
    input wire signed [255:0] job_bias_vec,
    input wire signed [255:0] job_multiplier_vec,
    input wire [47:0] job_shift_vec,
    input wire signed [31:0] job_output_zero_point_int32,
    input wire signed [31:0] job_activation_min_int32,
    input wire signed [31:0] job_activation_max_int32,
    output reg job_reject_stale,

    input wire group_cmd_valid,
    output wire group_cmd_ready,
    input wire [4:0] group_cmd_index,

    input wire act_valid,
    output wire act_ready,
    input wire [7:0] act_pixel_mask,
    input wire [7:0] act_cout_mask,
    input wire signed [63:0] act_vec,

    input wire out_ready,
    output wire out_valid,
    output wire [2:0] out_row_idx,
    output wire [1:0] out_beat_idx,
    output wire [5:0] out_pixel_idx,
    output wire [8:0] out_channel_base,
    output wire [1:0] out_lane_mask,
    output wire signed [15:0] out_data,

    output reg job_done,
    output wire busy,
    output wire [15:0] packed_read_count,
    output wire [15:0] activation_accept_count,
    output wire [15:0] activation_stall_count
);
    localparam integer ROWS = 4096;
    localparam integer GROUPS_MAX = (MAX_CIN + 7) / 8;

    function automatic [13:0] calc_words;
        input [7:0] cin_i;
        input [8:0] cout_i;
        integer tiles_i;
        reg [13:0] product_i;
        begin
            tiles_i = (cout_i + 7) >> 3;
            /* Shift/add decomposition intentionally keeps this loader
             * arithmetic in LUT/carry fabric.  A variable multiply here
             * otherwise consumes an avoidable DSP beside the 72-DSP PW core. */
            product_i = 14'd0;
            if (tiles_i[0]) product_i = product_i + cin_i;
            if (tiles_i[1]) product_i = product_i + (cin_i << 1);
            if (tiles_i[2]) product_i = product_i + (cin_i << 2);
            if (tiles_i[3]) product_i = product_i + (cin_i << 3);
            if (tiles_i[4]) product_i = product_i + (cin_i << 4);
            calc_words = product_i << 1;
        end
    endfunction

    function automatic [4:0] calc_groups;
        input [7:0] cin_i;
        begin
            calc_groups = (cin_i + 7) >> 3;
        end
    endfunction

    reg load_active_reg, committed_valid_reg;
    reg [1:0] load_epoch_reg, committed_epoch_reg;
    reg [7:0] load_cin_reg;
    reg [4:0] load_tile_count_reg;
    reg [13:0] expected_words_reg, load_word_count_reg;
    reg [4:0] load_tile_cursor_reg;
    reg [6:0] load_k_cursor_reg;
    reg load_half_reg;
    reg [15:0] packed_load_count_reg;

    assign load_active = load_active_reg;
    assign committed_valid = committed_valid_reg;
    assign committed_epoch = committed_epoch_reg;
    assign expected_word_count = expected_words_reg;
    assign load_word_count = load_word_count_reg;
    assign packed_load_count = packed_load_count_reg;
    wire load_begin_shape_valid = (load_cin > 0) && (load_cin <= MAX_CIN) &&
                                  (load_cout > 0) && (load_cout <= MAX_COUT);
    assign load_begin_ready = rst_n && !load_active_reg && load_begin_shape_valid;
    assign load_word_ready = rst_n && load_active_reg &&
                             (load_word_count_reg < expected_words_reg);
    assign load_commit_ready = rst_n && load_active_reg &&
                               (load_word_count_reg == expected_words_reg);

    wire load_begin_fire = load_begin_valid && load_begin_ready;
    wire load_word_fire = load_word_valid && load_word_ready;
    wire load_commit_fire = load_commit_valid && load_commit_ready;
    /* The sequential config stream is tile-major, K-minor, with two words
     * per row.  A small registered cursor maps that stream to the sparse
     * physical layout {cout_tile,k}; no runtime division or wide address
     * arithmetic is present in the compute cone. */
    wire [11:0] load_row_addr = {load_tile_cursor_reg, load_k_cursor_reg};
    wire load_half = load_half_reg;
    wire [63:0] load_row_data = load_half ? {load_word_data, 32'd0} :
                                             {32'd0, load_word_data};
    /* XPM exposes byte granularity for a 64-bit BRAM port.  Each logical
     * 32-bit half therefore asserts four adjacent byte enables. */
    wire [7:0] load_we = load_half ? 8'b11110000 : 8'b00001111;

    wire [63:0] weight_rd_data_raw;
    reg [63:0] weight_mem [0:ROWS-1];
    reg [11:0] weight_rd_addr;
    reg weight_rd_en;

`ifdef SYNTHESIS
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(12), .ADDR_WIDTH_B(12), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8), .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(ROWS*64), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(64), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(64),
        .WRITE_MODE_B("read_first")
    ) u_weight_row_store (
        .clka(clk), .clkb(clk), .ena(load_word_fire),
        .enb(weight_rd_en), .addra(load_row_addr), .addrb(weight_rd_addr),
        .dina(load_row_data), .wea(load_we), .doutb(weight_rd_data_raw),
        .rstb(!rst_n), .regceb(1'b1), .sleep(1'b0),
        .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
`else
    reg [63:0] weight_rd_data_reg;
    assign weight_rd_data_raw = weight_rd_data_reg;
    integer wi;
    always @(posedge clk) begin
        if (!rst_n) begin
            weight_rd_data_reg <= 64'd0;
        end else begin
            if (load_word_fire) begin
                if (load_half)
                    weight_mem[load_row_addr][63:32] <= load_word_data;
                else
                    weight_mem[load_row_addr][31:0] <= load_word_data;
            end
            if (weight_rd_en)
                weight_rd_data_reg <= weight_mem[weight_rd_addr];
        end
    end
`endif

    /* ---------------- job/group cursor ---------------- */
    reg job_active_reg, group_active_reg;
    reg [4:0] job_cout_tile_reg, job_group_count_reg;
    reg job_reverse_reg;
    reg [4:0] group_seq_reg, group_phys_reg;
    reg [2:0] k_cursor_reg;
    reg [5:0] pixel_base_reg;
    reg [8:0] cout_base_reg;
    reg [7:0] output_pixels_reg;
    reg [8:0] output_channels_reg;
    reg signed [255:0] bias_reg, multiplier_reg;
    reg [47:0] shift_reg;
    reg signed [31:0] zp_reg, min_reg, max_reg;

    wire [4:0] loaded_group_count = calc_groups(load_cin_reg);
    wire job_shape_valid = (job_group_count != 0) &&
                           (job_group_count <= GROUPS_MAX) &&
                           (job_group_count == loaded_group_count) &&
                           (job_cout_tile < load_tile_count_reg);
    assign job_ready = rst_n && !job_active_reg && committed_valid_reg &&
                       (job_epoch == committed_epoch_reg) && job_shape_valid;
    wire job_fire = job_valid && job_ready;
    assign group_cmd_ready = rst_n && job_active_reg && !group_active_reg &&
                             (group_seq_reg < job_group_count_reg) &&
                             (group_cmd_index == group_seq_reg);
    wire group_cmd_fire = group_cmd_valid && group_cmd_ready;

    reg response_valid;
    reg response_first, response_last;
    reg [7:0] response_k_idx;
    reg [7:0] response_pixel_mask, response_cout_mask;
    reg signed [63:0] response_act_vec;
    reg [15:0] packed_read_count_reg;
    reg [15:0] activation_accept_count_reg, activation_stall_count_reg;
    assign packed_read_count = packed_read_count_reg;
    assign activation_accept_count = activation_accept_count_reg;
    assign activation_stall_count = activation_stall_count_reg;

    wire core_valid_out, core_ready_in, core_busy;
    wire [2:0] core_row;
    wire [1:0] core_beat, core_mask;
    wire [5:0] core_pixel;
    wire [8:0] core_cout;
    wire signed [15:0] core_data;
    reg sink_valid;
    reg [2:0] sink_row;
    reg [1:0] sink_beat, sink_mask;
    reg [5:0] sink_pixel;
    reg [8:0] sink_cout;
    reg signed [15:0] sink_data;
    wire sink_in_ready = !sink_valid || out_ready;

    /* A group is eight K rows.  Cin<=128 therefore needs seven K address
     * bits; the fifth group-command bit is only a range-check/sentinel bit
     * and must not widen the physical row address. */
    wire [6:0] current_weight_k = {group_phys_reg[3:0], k_cursor_reg};
    wire act_fire = act_valid && act_ready;
    assign act_ready = rst_n && job_active_reg && group_active_reg &&
                       (!response_valid || core_ready_in);
    wire core_valid_in = response_valid;
    wire core_fire = core_valid_in && core_ready_in;

    /* Address is generated only from registered tile/group/K cursors. */
    always @* begin
        weight_rd_addr = {job_cout_tile_reg, current_weight_k};
        weight_rd_en = act_fire;
    end

    wire [7:0] core_pixel_mask = response_pixel_mask;
    wire [7:0] core_cout_mask = response_cout_mask;
    wire signed [63:0] core_wgt_vec = weight_rd_data_raw;

    pw_direct_8x8_dsp_rowbank #(
        .ACT_REPLICATE(ROWBANK_ACT_REPLICATE)
    ) u_pw_rowbank2 (
        .clk(clk), .rst_n(rst_n), .valid_in(core_valid_in),
        .ready_in(core_ready_in), .first_k(response_first),
        .last_k(response_last), .k_idx(response_k_idx),
        .pixel_mask(core_pixel_mask), .cout_mask(core_cout_mask),
        .act_vec(response_act_vec), .wgt_vec(core_wgt_vec),
        .pixel_base(pixel_base_reg), .cout_base(cout_base_reg),
        .output_pixels(output_pixels_reg),
        .output_channels(output_channels_reg), .bias_vec(bias_reg),
        .multiplier_vec(multiplier_reg), .shift_vec(shift_reg),
        .output_zero_point_int32(zp_reg),
        .activation_min_int32(min_reg), .activation_max_int32(max_reg),
        .ready_out(sink_in_ready), .valid_out(core_valid_out),
        .out_row_idx(core_row), .out_beat_idx(core_beat),
        .out_pixel_idx(core_pixel), .out_channel_base(core_cout),
        .out_lane_mask(core_mask), .out_data(core_data), .busy(core_busy)
    );

    /* A narrow elastic sink is part of the proof boundary and preserves the
     * row-bank record under arbitrary output backpressure. */
    wire sink_in_fire = core_valid_out && sink_in_ready;
    wire sink_out_fire = sink_valid && out_ready;
    assign out_valid = sink_valid;
    assign out_row_idx = sink_row;
    assign out_beat_idx = sink_beat;
    assign out_pixel_idx = sink_pixel;
    assign out_channel_base = sink_cout;
    assign out_lane_mask = sink_mask;
    assign out_data = sink_data;
    assign busy = job_active_reg || group_active_reg || response_valid ||
                  core_busy || sink_valid;

    integer mi;
    always @(posedge clk) begin
        if (!rst_n) begin
            load_active_reg <= 1'b0;
            committed_valid_reg <= 1'b0;
            load_epoch_reg <= 0; committed_epoch_reg <= 0;
            load_cin_reg <= 0;
            load_tile_count_reg <= 0;
            expected_words_reg <= 0; load_word_count_reg <= 0;
            load_tile_cursor_reg <= 0; load_k_cursor_reg <= 0;
            load_half_reg <= 1'b0;
            packed_load_count_reg <= 0;
            load_commit_reject <= 1'b0; load_extra_error <= 1'b0;
            job_reject_stale <= 1'b0; job_done <= 1'b0;
            job_active_reg <= 1'b0; group_active_reg <= 1'b0;
            job_cout_tile_reg <= 0; job_group_count_reg <= 0;
            job_reverse_reg <= 1'b0; group_seq_reg <= 0; group_phys_reg <= 0;
            k_cursor_reg <= 0; pixel_base_reg <= 0; cout_base_reg <= 0;
            output_pixels_reg <= 0; output_channels_reg <= 0;
            bias_reg <= 0; multiplier_reg <= 0; shift_reg <= 0;
            zp_reg <= 0; min_reg <= 0; max_reg <= 0;
            response_valid <= 1'b0; response_first <= 1'b0;
            response_last <= 1'b0; response_k_idx <= 0;
            response_pixel_mask <= 0; response_cout_mask <= 0;
            response_act_vec <= 0;
            packed_read_count_reg <= 0;
            activation_accept_count_reg <= 0;
            activation_stall_count_reg <= 0;
            sink_valid <= 1'b0; sink_row <= 0; sink_beat <= 0;
            sink_mask <= 0; sink_pixel <= 0; sink_cout <= 0; sink_data <= 0;
        end else begin
            load_commit_reject <= 1'b0;
            load_extra_error <= 1'b0;
            job_reject_stale <= 1'b0;
            job_done <= 1'b0;

            if (load_begin_fire) begin
                load_active_reg <= 1'b1;
                committed_valid_reg <= 1'b0;
                load_epoch_reg <= load_epoch;
                load_cin_reg <= load_cin;
                load_tile_count_reg <= (load_cout + 7) >> 3;
                expected_words_reg <= calc_words(load_cin, load_cout);
                load_word_count_reg <= 0;
                load_tile_cursor_reg <= 0;
                load_k_cursor_reg <= 0;
                load_half_reg <= 1'b0;
                packed_load_count_reg <= 0;
            end
            if (load_word_fire) begin
                load_word_count_reg <= load_word_count_reg + 1'b1;
                packed_load_count_reg <= packed_load_count_reg + 1'b1;
                if (!load_half_reg) begin
                    load_half_reg <= 1'b1;
                end else begin
                    load_half_reg <= 1'b0;
                    if (load_k_cursor_reg == (load_cin_reg - 1'b1)) begin
                        load_k_cursor_reg <= 0;
                        load_tile_cursor_reg <= load_tile_cursor_reg + 1'b1;
                    end else begin
                        load_k_cursor_reg <= load_k_cursor_reg + 1'b1;
                    end
                end
            end
            if (load_word_valid && load_active_reg &&
                (load_word_count_reg >= expected_words_reg))
                load_extra_error <= 1'b1;
            if (load_commit_valid && load_active_reg && !load_commit_ready)
                load_commit_reject <= 1'b1;
            if (load_commit_fire) begin
                load_active_reg <= 1'b0;
                committed_valid_reg <= 1'b1;
                committed_epoch_reg <= load_epoch_reg;
            end

            if (job_valid && !job_ready && !job_active_reg &&
                committed_valid_reg && (job_epoch != committed_epoch_reg))
                job_reject_stale <= 1'b1;
            if (job_fire) begin
                job_active_reg <= 1'b1;
                group_active_reg <= 1'b0;
                job_cout_tile_reg <= job_cout_tile;
                job_group_count_reg <= job_group_count;
                job_reverse_reg <= job_reverse_groups;
                group_seq_reg <= 0;
                pixel_base_reg <= job_pixel_base;
                cout_base_reg <= job_cout_base;
                output_pixels_reg <= job_output_pixels;
                output_channels_reg <= job_output_channels;
                bias_reg <= job_bias_vec;
                multiplier_reg <= job_multiplier_vec;
                shift_reg <= job_shift_vec;
                zp_reg <= job_output_zero_point_int32;
                min_reg <= job_activation_min_int32;
                max_reg <= job_activation_max_int32;
            end
            if (group_cmd_fire) begin
                group_active_reg <= 1'b1;
                k_cursor_reg <= 0;
                if (job_reverse_reg)
                    group_phys_reg <= job_group_count_reg - 1'b1 - group_seq_reg;
                else
                    group_phys_reg <= group_seq_reg;
            end
            if (act_fire) begin
                response_valid <= 1'b1;
                response_first <= (group_seq_reg == 0) && (k_cursor_reg == 0);
                response_last <= (group_seq_reg == (job_group_count_reg - 1'b1)) &&
                                 (k_cursor_reg == 3'd7);
                response_k_idx <= current_weight_k;
                response_pixel_mask <= act_pixel_mask;
                response_cout_mask <= act_cout_mask;
                response_act_vec <= act_vec;
                packed_read_count_reg <= packed_read_count_reg + 1'b1;
                activation_accept_count_reg <= activation_accept_count_reg + 1'b1;
                if (k_cursor_reg == 3'd7) begin
                    group_active_reg <= 1'b0;
                    group_seq_reg <= group_seq_reg + 1'b1;
                end else begin
                    k_cursor_reg <= k_cursor_reg + 1'b1;
                end
            end else if (core_fire) begin
                response_valid <= 1'b0;
            end
            if (act_valid && !act_ready)
                activation_stall_count_reg <= activation_stall_count_reg + 1'b1;

            if (sink_in_fire) begin
                sink_valid <= 1'b1;
                sink_row <= core_row; sink_beat <= core_beat;
                sink_mask <= core_mask; sink_pixel <= core_pixel;
                sink_cout <= core_cout; sink_data <= core_data;
            end else if (sink_out_fire) begin
                sink_valid <= 1'b0;
            end
            if (sink_out_fire && (sink_row == 3'd7) &&
                (sink_beat == 2'd3)) begin
                job_active_reg <= 1'b0;
                job_done <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
