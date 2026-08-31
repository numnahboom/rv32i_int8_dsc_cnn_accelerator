`timescale 1ns/1ps
`default_nettype none

/*
 * Compact left-half proof for the spatial DS data path.
 *
 * The established word-window producer supplies one registered sixteen-lane
 * DW result per output pixel.  The stream4 adapter requantizes that result
 * as four four-lane beats, and a pair of session scratch banks stores the
 * beats without carrying epoch/tile tags on the data plane.  Epoch/tile are
 * checked only on acquire and commit; each bank's ordered retirement counter
 * is the completion fence.  The two banks permit a committed bank to be
 * read while the producer computes the next bank.
 *
 * This is an integration/profiling helper.  It deliberately has no PW
 * multiplier, runner, or top-level integration and therefore cannot change
 * the production network ABI.
 */
module ds_word_window_dw_tagless_stream4_pipeline #(
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TILE_WIDTH = 8,
    parameter integer FIFO_DEPTH = 8,
    /* Non-production physical experiment hook; zero preserves the existing
     * prefetched core and one selects the four-quad local-control core. */
    parameter integer USE_QUADLOCAL_CORE = 0,
    /* Non-production sink experiment hook; zero preserves the existing
     * stream4 adapter and one selects four local requant islands. */
    parameter integer USE_LOCAL_REQUANT = 0,
    /* When set, expose the real requantized stream4 beats instead of writing
     * the legacy tagless scratch sink.  This is an integration-only mode;
     * default behavior and ABI remain unchanged. */
    parameter integer STREAM4_ONLY = 0,
    /* Keep the established 8x8 default while allowing a dedicated 4x8
     * producer shell to be screened without changing runner/PW RTL. */
    parameter integer OUTPUT_HEIGHT = 8,
    parameter integer OUTPUT_WIDTH = 8
) (
    input wire clk, input wire rst_n,

    input wire fill_start_valid, output wire fill_start_ready,
    input wire fill_start_bank,
    input wire [EPOCH_WIDTH-1:0] fill_start_epoch,
    input wire [ADDR_WIDTH-1:0] fill_start_base_addr,
    input wire [WORD_COUNT_WIDTH-1:0] fill_start_word_count,
    output wire fill_done_valid, input wire fill_done_ready,
    output wire fill_done_bank,
    output wire [EPOCH_WIDTH-1:0] fill_done_epoch,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid, input wire [31:0] mem_resp_data,

    input wire cfg_valid, output wire cfg_ready,
    input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,

    input wire dw_job_valid, output wire dw_job_ready,
    input wire dw_source_bank,
    input wire [EPOCH_WIDTH-1:0] dw_source_epoch,
    input wire [ADDR_WIDTH-1:0] dw_source_base_addr,
    input wire [15:0] dw_source_lane_mask,
    input wire [1:0] dw_source_stride,
    input wire [7:0] dw_footprint_height,
    input wire [7:0] dw_footprint_width,
    input wire [7:0] dw_footprint_pitch,
    input wire dw_target_bank,
    input wire [EPOCH_WIDTH-1:0] dw_target_epoch,
    input wire [TILE_WIDTH-1:0] dw_target_tile,
    input wire [2:0] dw_channel_group,
    input wire [3:0] dw_group_count,
    input wire [7:0] dw_pixel_count,
    input wire [31:0] dw_output_zero_point,
    input wire [31:0] dw_activation_min,
    input wire [31:0] dw_activation_max,
    output reg dw_done_valid, input wire dw_done_ready,
    output reg dw_done_bank,
    output reg [EPOCH_WIDTH-1:0] dw_done_epoch,
    output reg [TILE_WIDTH-1:0] dw_done_tile,
    output reg [2:0] dw_done_group,

    /* Raw/int8 storage readback protocol. */
    input wire read_acquire_valid, output wire read_acquire_ready,
    input wire read_bank,
    input wire [EPOCH_WIDTH-1:0] read_epoch,
    input wire [TILE_WIDTH-1:0] read_tile,
    input wire read_valid, output wire read_ready,
    input wire [6:0] read_channel_idx,
    input wire [5:0] read_pixel_base,
    output wire read_out_valid, input wire read_out_ready,
    output wire [63:0] read_out_data, output wire [7:0] read_out_lane_mask,
    input wire read_release_valid, output wire read_release_ready,
    output wire [1:0] scratch0_state, output wire [1:0] scratch1_state,
    output reg [31:0] dw_write_count,
    output reg [31:0] overlap_cycles,
    output reg [31:0] read_count,
    output wire stream4_valid,
    input wire stream4_ready,
    output wire [5:0] stream4_pixel,
    output wire [1:0] stream4_lane_base,
    output wire [31:0] stream4_data,
    output wire [3:0] stream4_lane_mask
);
    localparam integer VAW = (MAX_IN_H*MAX_IN_W*3 > 1) ?
                             $clog2(MAX_IN_H*MAX_IN_W*3) : 1;
    localparam [2:0] ST_IDLE = 3'd0, ST_ACQUIRE = 3'd1,
                     ST_START = 3'd2, ST_WAIT = 3'd3,
                     ST_DRAIN = 3'd4, ST_COMMIT = 3'd5;

    reg [2:0] state;
    reg target_bank_reg;
    reg [EPOCH_WIDTH-1:0] target_epoch_reg;
    reg [TILE_WIDTH-1:0] target_tile_reg;
    reg [2:0] group_reg;
    reg [3:0] group_count_reg;
    reg [7:0] pixel_count_reg;
    reg [31:0] zp_reg, min_reg, max_reg;
    reg [15:0] lane_mask_reg;
    reg [1:0] stride_reg;
    reg [7:0] footprint_h_reg, footprint_w_reg, pitch_reg;
    reg source_bank_reg;
    reg [EPOCH_WIDTH-1:0] source_epoch_reg;
    reg [ADDR_WIDTH-1:0] source_base_reg;
    reg [9:0] write_target_count;

    wire compute_start_valid = (state == ST_START);
    wire compute_start_ready;
    wire compute_done_valid;
    wire compute_done_ready = (state == ST_WAIT);
    wire compute_busy;
    wire producer_out_valid;
    wire producer_out_ready;
    wire [7:0] producer_out_pixel;
    wire [15:0] producer_out_mask;
    wire signed [511:0] producer_out_raw;
    wire signed [511:0] producer_out_bias;
    wire signed [511:0] producer_out_multiplier;
    wire [95:0] producer_out_shift;
    wire fill_busy;

    ds_word_window_dw_producer_island #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .MAX_CHANNEL_GROUPS(3), .LAYOUT_GROUPS(1),
        .ADDR_WIDTH(ADDR_WIDTH), .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH),
        .VECTOR_ADDR_WIDTH(VAW), .EPOCH_WIDTH(EPOCH_WIDTH),
        .TAG_WIDTH(16), .FIFO_DEPTH(FIFO_DEPTH),
        .USE_QUADLOCAL_CORE(USE_QUADLOCAL_CORE),
        .OUTPUT_HEIGHT(OUTPUT_HEIGHT), .OUTPUT_WIDTH(OUTPUT_WIDTH)
    ) u_producer (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_base_addr(fill_start_base_addr),
        .fill_start_word_count(fill_start_word_count),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec), .compute_start_valid(compute_start_valid),
        .compute_start_ready(compute_start_ready), .compute_bank(source_bank_reg),
        .compute_epoch(source_epoch_reg), .compute_lane_mask(lane_mask_reg),
        .compute_stride(stride_reg), .compute_footprint_height(footprint_h_reg),
        .compute_footprint_width(footprint_w_reg), .compute_pitch(pitch_reg),
        .compute_done_valid(compute_done_valid), .compute_done_ready(compute_done_ready),
        .compute_done_bank(), .compute_done_epoch(), .compute_busy(compute_busy),
        .valid_out(producer_out_valid), .ready_out(producer_out_ready),
        .out_pixel_idx(producer_out_pixel), .out_lane_mask(producer_out_mask),
        .out_raw_vec(producer_out_raw), .out_bias_vec(producer_out_bias),
        .out_multiplier_vec(producer_out_multiplier), .out_shift_vec(producer_out_shift),
        .bank0_state(), .bank1_state(), .fill_busy(fill_busy), .read_busy(),
        .fill_word_count_seen(), .read_vector_count(), .token_count(),
        .overlap_cycles(), .stale_command_count()
    );

    wire adapter_valid, adapter_ready;
    wire [5:0] adapter_pixel;
    wire [1:0] adapter_lane_base;
    wire [31:0] adapter_data;
    wire [3:0] adapter_mask;
    wire adapter_busy;
    generate if (USE_LOCAL_REQUANT == 0) begin : gen_legacy_requant
    ds_dw_requant_stream4_write_adapter u_requant (
        .clk(clk), .rst_n(rst_n), .valid_in(producer_out_valid),
        .ready_in(producer_out_ready), .pixel_idx_in(producer_out_pixel[5:0]),
        .lane_mask_in(producer_out_mask), .raw_vec_in(producer_out_raw),
        .multiplier_vec_in(producer_out_multiplier),
        .shift_vec_in(producer_out_shift),
        .output_zero_point(zp_reg), .activation_min(min_reg),
        .activation_max(max_reg), .valid_out(adapter_valid),
        .ready_out(adapter_ready), .pixel_idx_out(adapter_pixel),
        .lane_base_out(adapter_lane_base), .data_out(adapter_data),
        .lane_mask_out(adapter_mask), .busy(adapter_busy)
    );
    end else begin : gen_local_requant
    ds_dw_requant_stream4_write_adapter_local u_requant_local (
        .clk(clk), .rst_n(rst_n), .valid_in(producer_out_valid),
        .ready_in(producer_out_ready), .pixel_idx_in(producer_out_pixel[5:0]),
        .lane_mask_in(producer_out_mask), .raw_vec_in(producer_out_raw),
        .multiplier_vec_in(producer_out_multiplier),
        .shift_vec_in(producer_out_shift), .output_zero_point(zp_reg),
        .activation_min(min_reg), .activation_max(max_reg),
        .valid_out(adapter_valid), .ready_out(adapter_ready),
        .pixel_idx_out(adapter_pixel), .lane_base_out(adapter_lane_base),
        .data_out(adapter_data), .lane_mask_out(adapter_mask),
        .busy(adapter_busy)
    );
    end endgenerate

    wire dw_acquire_valid = (state == ST_ACQUIRE);
    wire dw_acquire_ready;
    wire dw_write_ready;
    wire dw_commit_valid = (state == ST_COMMIT);
    wire dw_commit_ready;
    wire [1:0] s0_state, s1_state;
    wire s0_acq_ready, s1_acq_ready, s0_wr_ready, s1_wr_ready;
    wire s0_cm_ready, s1_cm_ready;
    wire s0_rd_acq_ready, s1_rd_acq_ready;
    wire s0_rd_ready, s1_rd_ready;
    wire s0_rel_ready, s1_rel_ready;
    wire s0_out_valid, s1_out_valid;
    wire [63:0] s0_out_data, s1_out_data;
    wire [7:0] s0_out_mask, s1_out_mask;
    wire read_bank_valid = read_bank;

    ds_pw_spatial_tile_bank_tagless #(.EPOCH_WIDTH(EPOCH_WIDTH),
        .TILE_WIDTH(TILE_WIDTH), .BANK_ID(0)) u_scratch0 (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid && !target_bank_reg),
        .dw_acquire_ready(s0_acq_ready), .dw_acquire_bank(1'b0),
        .dw_acquire_epoch(target_epoch_reg), .dw_acquire_tile(target_tile_reg),
        .dw_acquire_pixel_mask(pixel_mask), .dw_acquire_group_mask(group_mask),
        .dw_acquire_expected_count(expected_write_count),
        .dw_write_valid(adapter_valid && !target_bank_reg), .dw_write_ready(s0_wr_ready),
        .dw_write_pixel_idx(adapter_pixel), .dw_write_group(group_reg),
        .dw_write_lane_base(adapter_lane_base), .dw_write_data(adapter_data),
        .dw_write_lane_mask(adapter_mask),
        .dw_commit_valid(dw_commit_valid && !target_bank_reg), .dw_commit_ready(s0_cm_ready),
        .dw_commit_bank(1'b0), .dw_commit_epoch(target_epoch_reg),
        .dw_commit_tile(target_tile_reg),
        .pw_acquire_valid(read_acquire_valid && !read_bank_valid),
        .pw_acquire_ready(s0_rd_acq_ready), .pw_acquire_bank(1'b0),
        .pw_acquire_epoch(read_epoch), .pw_acquire_tile(read_tile),
        .pw_read_valid(read_valid && !read_bank_valid), .pw_read_ready(s0_rd_ready),
        .pw_read_channel_idx(read_channel_idx), .pw_read_pixel_base(read_pixel_base),
        .pw_out_valid(s0_out_valid), .pw_out_ready(read_out_ready && !s1_out_valid),
        .pw_out_data(s0_out_data), .pw_out_lane_mask(s0_out_mask),
        .pw_release_valid(read_release_valid && !read_bank_valid),
        .pw_release_ready(s0_rel_ready), .pw_release_bank(1'b0),
        .pw_release_epoch(read_epoch), .pw_release_tile(read_tile),
        .state(s0_state), .state_epoch(), .state_tile(), .commit_pulse(),
        .acquire_pulse(), .release_pulse(), .retired_write_count(),
        .expected_count(), .read_count()
    );
    ds_pw_spatial_tile_bank_tagless #(.EPOCH_WIDTH(EPOCH_WIDTH),
        .TILE_WIDTH(TILE_WIDTH), .BANK_ID(1)) u_scratch1 (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid && target_bank_reg),
        .dw_acquire_ready(s1_acq_ready), .dw_acquire_bank(1'b1),
        .dw_acquire_epoch(target_epoch_reg), .dw_acquire_tile(target_tile_reg),
        .dw_acquire_pixel_mask(pixel_mask), .dw_acquire_group_mask(group_mask),
        .dw_acquire_expected_count(expected_write_count),
        .dw_write_valid(adapter_valid && target_bank_reg), .dw_write_ready(s1_wr_ready),
        .dw_write_pixel_idx(adapter_pixel), .dw_write_group(group_reg),
        .dw_write_lane_base(adapter_lane_base), .dw_write_data(adapter_data),
        .dw_write_lane_mask(adapter_mask),
        .dw_commit_valid(dw_commit_valid && target_bank_reg), .dw_commit_ready(s1_cm_ready),
        .dw_commit_bank(1'b1), .dw_commit_epoch(target_epoch_reg),
        .dw_commit_tile(target_tile_reg),
        .pw_acquire_valid(read_acquire_valid && read_bank_valid),
        .pw_acquire_ready(s1_rd_acq_ready), .pw_acquire_bank(1'b1),
        .pw_acquire_epoch(read_epoch), .pw_acquire_tile(read_tile),
        .pw_read_valid(read_valid && read_bank_valid), .pw_read_ready(s1_rd_ready),
        .pw_read_channel_idx(read_channel_idx), .pw_read_pixel_base(read_pixel_base),
        .pw_out_valid(s1_out_valid), .pw_out_ready(read_out_ready && !s0_out_valid),
        .pw_out_data(s1_out_data), .pw_out_lane_mask(s1_out_mask),
        .pw_release_valid(read_release_valid && read_bank_valid),
        .pw_release_ready(s1_rel_ready), .pw_release_bank(1'b1),
        .pw_release_epoch(read_epoch), .pw_release_tile(read_tile),
        .state(s1_state), .state_epoch(), .state_tile(), .commit_pulse(),
        .acquire_pulse(), .release_pulse(), .retired_write_count(),
        .expected_count(), .read_count()
    );

    wire [63:0] pixel_mask = (pixel_count_reg >= 64) ? 64'hffff_ffff_ffff_ffff :
        ((pixel_count_reg == 0) ? 64'd0 : ((64'h1 << pixel_count_reg) - 1));
    wire [7:0] group_mask = (group_count_reg >= 8) ? 8'hff :
        ((group_count_reg == 0) ? 8'd0 : ((8'h1 << group_count_reg) - 1));
    wire [31:0] expected_write_count =
        ({24'd0, pixel_count_reg} * {28'd0, group_count_reg}) << 2;
    assign dw_job_ready = rst_n && (state == ST_IDLE) && !dw_done_valid;
    assign dw_acquire_ready = target_bank_reg ? s1_acq_ready : s0_acq_ready;
    assign dw_write_ready = target_bank_reg ? s1_wr_ready : s0_wr_ready;
    assign adapter_ready = (STREAM4_ONLY != 0) ? stream4_ready : dw_write_ready;
    assign stream4_valid = (STREAM4_ONLY != 0) ? adapter_valid : 1'b0;
    assign stream4_pixel = adapter_pixel;
    assign stream4_lane_base = adapter_lane_base;
    assign stream4_data = adapter_data;
    assign stream4_lane_mask = adapter_mask;
    assign dw_commit_ready = target_bank_reg ? s1_cm_ready : s0_cm_ready;
    assign read_acquire_ready = read_bank_valid ? s1_rd_acq_ready : s0_rd_acq_ready;
    assign read_ready = read_bank_valid ? s1_rd_ready : s0_rd_ready;
    assign read_release_ready = read_bank_valid ? s1_rel_ready : s0_rel_ready;
    assign read_out_valid = s0_out_valid | s1_out_valid;
    assign read_out_data = s1_out_valid ? s1_out_data : s0_out_data;
    assign read_out_lane_mask = s1_out_valid ? s1_out_mask : s0_out_mask;
    assign scratch0_state = s0_state; assign scratch1_state = s1_state;

    wire dw_job_fire = dw_job_valid && dw_job_ready;
    wire dw_acquire_fire = dw_acquire_valid && dw_acquire_ready;
    wire producer_done_fire = compute_done_valid && compute_done_ready;
    wire adapter_write_fire = adapter_valid && dw_write_ready &&
                              (STREAM4_ONLY == 0);
    wire dw_commit_fire = dw_commit_valid && dw_commit_ready;
    wire read_fire = read_valid && read_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE; target_bank_reg <= 0; target_epoch_reg <= 0;
            target_tile_reg <= 0; group_reg <= 0; group_count_reg <= 0;
            pixel_count_reg <= 0; zp_reg <= 0; min_reg <= 0; max_reg <= 0;
            lane_mask_reg <= 0; stride_reg <= 1; footprint_h_reg <= 0;
            footprint_w_reg <= 0; pitch_reg <= 0; source_bank_reg <= 0;
            source_epoch_reg <= 0; source_base_reg <= 0; write_target_count <= 0;
            dw_done_valid <= 0;
            dw_done_bank <= 0; dw_done_epoch <= 0; dw_done_tile <= 0;
            dw_done_group <= 0; dw_write_count <= 0; overlap_cycles <= 0;
            read_count <= 0;
        end else begin
            if (dw_done_valid && dw_done_ready) dw_done_valid <= 0;
            if (dw_job_fire) begin
                source_bank_reg <= dw_source_bank;
                source_epoch_reg <= dw_source_epoch;
                source_base_reg <= dw_source_base_addr;
                lane_mask_reg <= dw_source_lane_mask;
                stride_reg <= (dw_source_stride == 0) ? 1 : dw_source_stride;
                footprint_h_reg <= dw_footprint_height;
                footprint_w_reg <= dw_footprint_width;
                pitch_reg <= dw_footprint_pitch;
                target_bank_reg <= dw_target_bank;
                target_epoch_reg <= dw_target_epoch;
                target_tile_reg <= dw_target_tile;
                group_reg <= dw_channel_group;
                group_count_reg <= dw_group_count;
                pixel_count_reg <= dw_pixel_count;
                write_target_count <= ({2'd0, dw_pixel_count} << 2);
                zp_reg <= dw_output_zero_point;
                min_reg <= dw_activation_min;
                max_reg <= dw_activation_max;
                dw_write_count <= 0;
                state <= (dw_channel_group == 0) ? ST_ACQUIRE : ST_START;
            end
            if ((state == ST_ACQUIRE) &&
                ((STREAM4_ONLY != 0) || dw_acquire_fire)) state <= ST_START;
            if ((state == ST_START) && compute_start_ready) state <= ST_WAIT;
            if ((state == ST_WAIT) && producer_done_fire) begin
                if (STREAM4_ONLY != 0) begin
                    dw_done_valid <= 1'b1;
                    dw_done_bank <= target_bank_reg;
                    dw_done_epoch <= target_epoch_reg;
                    dw_done_tile <= target_tile_reg;
                    dw_done_group <= group_reg;
                    state <= ST_IDLE;
                end else state <= ST_DRAIN;
            end
            if (adapter_write_fire) dw_write_count <= dw_write_count + 1'b1;
            if ((state == ST_DRAIN) && (dw_write_count >= write_target_count)) begin
                if (group_reg + 1 >= group_count_reg) state <= ST_COMMIT;
                else state <= ST_IDLE;
            end
            if (dw_commit_fire) begin
                dw_done_valid <= 1'b1; dw_done_bank <= target_bank_reg;
                dw_done_epoch <= target_epoch_reg; dw_done_tile <= target_tile_reg;
                dw_done_group <= group_reg; state <= ST_IDLE;
            end
            if (read_fire) read_count <= read_count + 1'b1;
            /* A PW session in the other bank may remain active while this
             * producer computes/fills the next bank.  This counter is an
             * observable overlap proof, not a functional dependency. */
            if ((compute_busy || fill_busy) &&
                (target_bank_reg ? (s0_state == 2'd3) : (s1_state == 2'd3)))
                overlap_cycles <= overlap_cycles + 1'b1;
        end
    end
endmodule

`default_nettype wire
