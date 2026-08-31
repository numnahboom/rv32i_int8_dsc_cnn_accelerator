`timescale 1ns/1ps
`default_nettype none

/*
 * Non-production word-window DW producer island.
 *
 * This block is the narrow integration boundary between the passing
 * ds_word_window_pingpong_shell and the direct sixteen-lane DW core.  The
 * shell performs all source-word/BRAM ownership work and returns registered
 * 128-bit vectors.  A tile-local registered window store then walks those
 * vectors in the nine-tap order required by dw_direct_3x3_dsp.  Thus the
 * bank select and BRAM output are never used as live DSP operands.
 *
 * One compute command consumes one 8x8 output tile and one 16-channel tile.
 * The caller may run several commands for Cin=48/128, alternating banks and
 * epochs.  Stride one reads a 10x10 footprint (100 vectors); stride two reads
 * a 17x17 footprint (289 vectors).  The fill command remains independent so
 * that an inactive bank can be filled while the active tile is copied and
 * computed.
 */
module ds_word_window_dw_producer_island #(
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer MAX_CHANNEL_GROUPS = 3,
    parameter integer LAYOUT_GROUPS = 1,
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer VECTOR_ADDR_WIDTH =
        ((MAX_IN_H*MAX_IN_W*MAX_CHANNEL_GROUPS) > 1) ?
        $clog2(MAX_IN_H*MAX_IN_W*MAX_CHANNEL_GROUPS) : 1,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TAG_WIDTH = 16,
    parameter integer FIFO_DEPTH = 8,
    /* Non-production physical experiment hook.  The default preserves the
     * established direct core; the quad-local implementation is selected
     * only by dedicated OOC/test wrappers. */
    parameter integer USE_QUADLOCAL_CORE = 0,
    /* Output geometry is a generic so the 4x8 physical experiment can reuse
     * the exact word-window/session implementation without touching the
     * production runner.  The default is the established 8x8 island ABI. */
    parameter integer OUTPUT_HEIGHT = 8,
    parameter integer OUTPUT_WIDTH = 8
) (
    input wire clk,
    input wire rst_n,

    input wire fill_start_valid,
    output wire fill_start_ready,
    input wire fill_start_bank,
    input wire [EPOCH_WIDTH-1:0] fill_start_epoch,
    input wire [ADDR_WIDTH-1:0] fill_start_base_addr,
    input wire [WORD_COUNT_WIDTH-1:0] fill_start_word_count,
    output wire fill_done_valid,
    input wire fill_done_ready,
    output wire fill_done_bank,
    output wire [EPOCH_WIDTH-1:0] fill_done_epoch,

    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid,
    input wire [31:0] mem_resp_data,

    input wire cfg_valid,
    output wire cfg_ready,
    input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,

    input wire compute_start_valid,
    output wire compute_start_ready,
    input wire compute_bank,
    input wire [EPOCH_WIDTH-1:0] compute_epoch,
    input wire [15:0] compute_lane_mask,
    input wire [1:0] compute_stride,
    input wire [7:0] compute_footprint_height,
    input wire [7:0] compute_footprint_width,
    input wire [7:0] compute_pitch,
    output reg compute_done_valid,
    input wire compute_done_ready,
    output reg compute_done_bank,
    output reg [EPOCH_WIDTH-1:0] compute_done_epoch,
    output wire compute_busy,

    output wire valid_out,
    input wire ready_out,
    output wire [7:0] out_pixel_idx,
    output wire [15:0] out_lane_mask,
    output wire signed [511:0] out_raw_vec,
    output wire signed [511:0] out_bias_vec,
    output wire signed [511:0] out_multiplier_vec,
    output wire [95:0] out_shift_vec,

    output wire [1:0] bank0_state,
    output wire [1:0] bank1_state,
    output wire fill_busy,
    output wire read_busy,
    output wire [31:0] fill_word_count_seen,
    output wire [31:0] read_vector_count,
    output reg [31:0] token_count,
    output reg [31:0] overlap_cycles,
    output reg [31:0] stale_command_count
);
    localparam integer FOOTPRINT_CAP = MAX_IN_H * MAX_IN_W;
    localparam integer READ_COUNT_WIDTH =
        (FOOTPRINT_CAP > 1) ? $clog2(FOOTPRINT_CAP + 1) : 1;
    localparam integer OUTPUT_PIXEL_COUNT = OUTPUT_HEIGHT * OUTPUT_WIDTH;
    localparam integer OUTPUT_LAST_PIXEL = OUTPUT_PIXEL_COUNT - 1;

    localparam [2:0] ST_IDLE       = 3'd0;
    localparam [2:0] ST_READ_START = 3'd1;
    localparam [2:0] ST_COPY       = 3'd2;
    localparam [2:0] ST_PRIME      = 3'd3;
    localparam [2:0] ST_EMIT       = 3'd4;
    localparam [2:0] ST_DRAIN      = 3'd5;
    localparam [2:0] ST_RELEASE    = 3'd6;
    localparam [2:0] ST_DONE       = 3'd7;

    reg [2:0] state;
    reg compute_bank_reg;
    reg [EPOCH_WIDTH-1:0] compute_epoch_reg;
    reg [15:0] lane_mask_reg;
    reg [1:0] stride_reg;
    reg [7:0] footprint_h_reg, footprint_w_reg, pitch_reg;
    reg [READ_COUNT_WIDTH-1:0] total_reads_reg, copy_count;
    reg read_done_seen;
    reg final_output_seen;

    /* ---------------------- word-window shell ----------------------- */
    reg shell_read_start_valid;
    wire shell_read_start_ready;
    wire shell_read_done_valid;
    wire shell_read_done_ready = 1'b1;
    wire shell_read_done_bank;
    wire [EPOCH_WIDTH-1:0] shell_read_done_epoch;
    wire shell_rd_valid;
    reg shell_rd_ready;
    wire [VECTOR_ADDR_WIDTH-1:0] shell_rd_vector_addr;
    wire [15:0] shell_rd_lane_mask;
    wire [TAG_WIDTH-1:0] shell_rd_tag;
    wire [EPOCH_WIDTH-1:0] shell_rd_epoch;
    wire [127:0] shell_rd_data_vector;
    reg shell_release_valid;
    wire shell_release_ready;
    wire shell_release_resp_valid;
    wire shell_release_resp_ready = 1'b1;
    wire shell_release_resp_ok;
    wire [31:0] shell_overlap_cycles;
    /* During admission expose the proposed command to the shell's
     * combinational READY check.  This preserves epoch rejection without
     * adding an epoch/status port to the established shell ABI. */
    wire shell_read_bank_sel =
        ((state == ST_IDLE) && compute_start_valid) ? compute_bank : compute_bank_reg;
    wire [EPOCH_WIDTH-1:0] shell_read_epoch_sel =
        ((state == ST_IDLE) && compute_start_valid) ? compute_epoch : compute_epoch_reg;

    ds_word_window_pingpong_shell #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .MAX_CHANNEL_GROUPS(MAX_CHANNEL_GROUPS),
        .LAYOUT_GROUPS(LAYOUT_GROUPS), .ADDR_WIDTH(ADDR_WIDTH),
        .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH),
        .VECTOR_ADDR_WIDTH(VECTOR_ADDR_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH),
        .TAG_WIDTH(TAG_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)
    ) u_window_shell (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_base_addr(fill_start_base_addr),
        .fill_start_word_count(fill_start_word_count),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data),
        .read_start_valid(shell_read_start_valid),
        .read_start_ready(shell_read_start_ready),
        .read_start_bank(shell_read_bank_sel), .read_start_epoch(shell_read_epoch_sel),
        .read_height(footprint_h_reg), .read_width(footprint_w_reg),
        .read_stride(8'd1), .read_pitch(pitch_reg),
        .read_base_vector({VECTOR_ADDR_WIDTH{1'b0}}), .read_group(2'd0),
        .read_lane_mask(lane_mask_reg), .read_done_valid(shell_read_done_valid),
        .read_done_ready(shell_read_done_ready),
        .read_done_bank(shell_read_done_bank),
        .read_done_epoch(shell_read_done_epoch), .rd_valid(shell_rd_valid),
        .rd_ready(shell_rd_ready), .rd_vector_addr(shell_rd_vector_addr),
        .rd_lane_mask(shell_rd_lane_mask), .rd_tag(shell_rd_tag),
        .rd_epoch(shell_rd_epoch), .rd_data_vector(shell_rd_data_vector),
        .release_valid(shell_release_valid), .release_ready(shell_release_ready),
        .release_bank(compute_bank_reg), .release_epoch(compute_epoch_reg),
        .release_resp_valid(shell_release_resp_valid),
        .release_resp_ready(shell_release_resp_ready),
        .release_resp_ok(shell_release_resp_ok), .bank0_state(bank0_state),
        .bank1_state(bank1_state), .fill_busy(fill_busy), .read_busy(read_busy),
        .fill_word_count_seen(fill_word_count_seen),
        .read_vector_count(read_vector_count), .overlap_cycles(shell_overlap_cycles),
        .stale_command_count(stale_command_count)
    );

    assign compute_start_ready = rst_n && (state == ST_IDLE) &&
        !compute_done_valid && shell_read_start_ready;
    assign compute_busy = rst_n && (state != ST_IDLE);

    /* ------------------------- local window -------------------------- */
    /* Four narrower banks are explicitly implemented as synchronous RAM in
     * hardware.  A 128-bit inferred distributed RAM made copy_count fan out
     * to every RAMD64E address pin; the block-RAM boundary keeps both the
     * write address and the DSP operand path local. */
    localparam integer LOCAL_DEPTH = 512;
    wire [31:0] local_rd_data0, local_rd_data1, local_rd_data2, local_rd_data3;
    reg copy_wr_pending;
    reg [READ_COUNT_WIDTH-1:0] copy_wr_addr;
    reg signed [127:0] copy_wr_data;
    reg [READ_COUNT_WIDTH-1:0] emit_addr;
    reg [5:0] emit_pixel;
    reg [3:0] emit_tap;
    reg token_valid;
    reg token_first, token_last;
    reg [7:0] token_pixel;
    reg [3:0] token_tap;
    reg [15:0] token_lane_mask;
    reg signed [127:0] token_act;
    reg signed [127:0] token_weight;
    reg signed [127:0] sched_weight_mem [0:8];
    reg [READ_COUNT_WIDTH-1:0] prefetch_addr;
    reg [READ_COUNT_WIDTH-1:0] prefetch_rd_addr;
    reg signed [127:0] prefetch_data;
    reg prefetch_valid;
    reg [1:0] prefetch_wait;
    reg prefetch_rd_en;

    /* The address recurrence is intentionally registered.  It has no
     * per-token multiply or bank mux, and covers both stride values. */
    wire [READ_COUNT_WIDTH-1:0] emit_next_addr =
        (emit_tap < 2) ? (emit_addr + 1'b1) :
        (emit_tap == 2 || emit_tap == 5) ?
            (emit_addr + footprint_w_reg - 2) :
        (emit_tap == 8) ?
            ((emit_pixel[2:0] != 3'd7) ?
                (emit_addr + stride_reg - (footprint_w_reg * 2) - 2) :
                (stride_reg == 1) ?
                    (emit_addr - footprint_w_reg - 9) :
                    (emit_addr - 16)) :
        (emit_addr + 1'b1);
    wire [5:0] emit_next_pixel = (emit_tap == 8) ?
        (emit_pixel + 1'b1) : emit_pixel;
    wire [3:0] emit_next_tap = (emit_tap == 8) ? 4'd0 :
        (emit_tap + 1'b1);
    wire core_valid_in = token_valid;
    wire core_ready_in;
    wire core_input_fire = core_valid_in && core_ready_in;
    wire core_output_fire = valid_out && ready_out;

`ifdef SYNTHESIS
    xpm_memory_sdpram #(.ADDR_WIDTH_A(9), .ADDR_WIDTH_B(9), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(32), .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(LOCAL_DEPTH*32), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(32), .WRITE_MODE_B("read_first")) u_local_mem0 (
        .clka(clk), .clkb(clk), .ena(copy_wr_pending), .wea(copy_wr_pending),
        .addra(copy_wr_addr), .dina(copy_wr_data[31:0]), .addrb(prefetch_rd_addr),
        .enb(prefetch_rd_en), .doutb(local_rd_data0), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb());
    xpm_memory_sdpram #(.ADDR_WIDTH_A(9), .ADDR_WIDTH_B(9), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(32), .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(LOCAL_DEPTH*32), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(32), .WRITE_MODE_B("read_first")) u_local_mem1 (
        .clka(clk), .clkb(clk), .ena(copy_wr_pending), .wea(copy_wr_pending),
        .addra(copy_wr_addr), .dina(copy_wr_data[63:32]), .addrb(prefetch_rd_addr),
        .enb(prefetch_rd_en), .doutb(local_rd_data1), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb());
    xpm_memory_sdpram #(.ADDR_WIDTH_A(9), .ADDR_WIDTH_B(9), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(32), .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(LOCAL_DEPTH*32), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(32), .WRITE_MODE_B("read_first")) u_local_mem2 (
        .clka(clk), .clkb(clk), .ena(copy_wr_pending), .wea(copy_wr_pending),
        .addra(copy_wr_addr), .dina(copy_wr_data[95:64]), .addrb(prefetch_rd_addr),
        .enb(prefetch_rd_en), .doutb(local_rd_data2), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb());
    xpm_memory_sdpram #(.ADDR_WIDTH_A(9), .ADDR_WIDTH_B(9), .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(32), .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(LOCAL_DEPTH*32), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(32), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"), .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(32), .WRITE_MODE_B("read_first")) u_local_mem3 (
        .clka(clk), .clkb(clk), .ena(copy_wr_pending), .wea(copy_wr_pending),
        .addra(copy_wr_addr), .dina(copy_wr_data[127:96]), .addrb(prefetch_rd_addr),
        .enb(prefetch_rd_en), .doutb(local_rd_data3), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0), .dbiterrb(), .sbiterrb());
`else
    reg [31:0] local_mem0 [0:LOCAL_DEPTH-1];
    reg [31:0] local_mem1 [0:LOCAL_DEPTH-1];
    reg [31:0] local_mem2 [0:LOCAL_DEPTH-1];
    reg [31:0] local_mem3 [0:LOCAL_DEPTH-1];
    reg [31:0] local_rd_data0_reg, local_rd_data1_reg;
    reg [31:0] local_rd_data2_reg, local_rd_data3_reg;
    assign local_rd_data0 = local_rd_data0_reg;
    assign local_rd_data1 = local_rd_data1_reg;
    assign local_rd_data2 = local_rd_data2_reg;
    assign local_rd_data3 = local_rd_data3_reg;
    always @(posedge clk) begin
        if (copy_wr_pending) begin
            local_mem0[copy_wr_addr] <= copy_wr_data[31:0];
            local_mem1[copy_wr_addr] <= copy_wr_data[63:32];
            local_mem2[copy_wr_addr] <= copy_wr_data[95:64];
            local_mem3[copy_wr_addr] <= copy_wr_data[127:96];
        end
        if (prefetch_rd_en) begin
            local_rd_data0_reg <= local_mem0[prefetch_rd_addr];
            local_rd_data1_reg <= local_mem1[prefetch_rd_addr];
            local_rd_data2_reg <= local_mem2[prefetch_rd_addr];
            local_rd_data3_reg <= local_mem3[prefetch_rd_addr];
        end
    end
`endif

    generate
    if (USE_QUADLOCAL_CORE == 0) begin : gen_legacy_dw
    dw_direct_3x3_dsp_prefetched u_dw (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec), .valid_in(core_valid_in),
        .ready_in(core_ready_in), .first_tap(token_first),
        .last_tap(token_last), .tap_idx(token_tap), .pixel_idx(token_pixel),
        .lane_mask(token_lane_mask), .act_vec(token_act), .valid_out(valid_out),
        .weight_vec(token_weight),
        .ready_out(ready_out), .out_pixel_idx(out_pixel_idx),
        .out_lane_mask(out_lane_mask), .out_raw_vec(out_raw_vec),
        .out_bias_vec(out_bias_vec), .out_multiplier_vec(out_multiplier_vec),
        .out_shift_vec(out_shift_vec)
    );
    end else begin : gen_quadlocal_dw
    dw_direct_3x3_dsp_quadlocal u_dw (
        .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec), .valid_in(core_valid_in),
        .ready_in(core_ready_in), .first_tap(token_first),
        .last_tap(token_last), .tap_idx(token_tap), .pixel_idx(token_pixel),
        .lane_mask(token_lane_mask), .act_vec(token_act), .valid_out(valid_out),
        .weight_vec(token_weight), .ready_out(ready_out),
        .out_pixel_idx(out_pixel_idx), .out_lane_mask(out_lane_mask),
        .out_raw_vec(out_raw_vec), .out_bias_vec(out_bias_vec),
        .out_multiplier_vec(out_multiplier_vec), .out_shift_vec(out_shift_vec)
    );
    end
    endgenerate

    always @* begin
        shell_read_start_valid = (state == ST_READ_START);
        shell_rd_ready = (state == ST_COPY) &&
                         (copy_count < total_reads_reg);
        shell_release_valid = (state == ST_RELEASE);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            compute_bank_reg <= 1'b0;
            compute_epoch_reg <= {EPOCH_WIDTH{1'b0}};
            lane_mask_reg <= 16'd0;
            stride_reg <= 2'd1;
            footprint_h_reg <= 8'd10;
            footprint_w_reg <= 8'd10;
            pitch_reg <= 8'd10;
            total_reads_reg <= 0;
            copy_count <= 0;
            read_done_seen <= 1'b0;
            final_output_seen <= 1'b0;
            compute_done_valid <= 1'b0;
            compute_done_bank <= 1'b0;
            compute_done_epoch <= 0;
            emit_addr <= 0;
            emit_pixel <= 0;
            emit_tap <= 0;
            token_valid <= 1'b0;
            token_first <= 1'b0;
            token_last <= 1'b0;
            token_pixel <= 0;
            token_tap <= 0;
            token_lane_mask <= 0;
            token_act <= 0;
            token_weight <= 0;
            copy_wr_pending <= 1'b0;
            copy_wr_addr <= 0;
            copy_wr_data <= 0;
            prefetch_addr <= 0;
            prefetch_rd_addr <= 0;
            prefetch_data <= 0;
            prefetch_valid <= 1'b0;
            prefetch_wait <= 2'd0;
            prefetch_rd_en <= 1'b0;
            token_count <= 0;
            overlap_cycles <= 0;
            /* window_mem is completely overwritten by the accepted footprint
             * reads before ST_PRIME.  Deliberately do not reset this RAM:
             * resetting every entry would force Vivado to implement the
             * local store as 37k flip-flops and a huge read mux instead of
             * distributed RAM. */
        end else begin
            if (compute_done_valid && compute_done_ready)
                compute_done_valid <= 1'b0;

            if (shell_read_done_valid &&
                (shell_read_done_bank == compute_bank_reg) &&
                (shell_read_done_epoch == compute_epoch_reg))
                read_done_seen <= 1'b1;

            if (cfg_valid && cfg_ready && (cfg_tap_idx < 9))
                sched_weight_mem[cfg_tap_idx] <= cfg_weight_vec;

            if (compute_start_valid && compute_start_ready) begin
                compute_bank_reg <= compute_bank;
                compute_epoch_reg <= compute_epoch;
                lane_mask_reg <= compute_lane_mask;
                stride_reg <= (compute_stride == 0) ? 2'd1 : compute_stride;
                footprint_h_reg <= compute_footprint_height;
                footprint_w_reg <= compute_footprint_width;
                pitch_reg <= compute_pitch;
                total_reads_reg <= compute_footprint_height *
                                   compute_footprint_width;
                copy_count <= 0;
                read_done_seen <= 1'b0;
                final_output_seen <= 1'b0;
                token_count <= 0;
                state <= ST_READ_START;
            end

            if ((state == ST_READ_START) && shell_read_start_ready)
                state <= ST_COPY;

            if ((state == ST_COPY) && shell_rd_valid && shell_rd_ready) begin
                /* shell output is already registered and row-major; using
                 * the accepted sequence number also decouples the token
                 * scheduler from the shell's bank/address mux. */
                /* Capture the shell vector and address in a one-entry
                 * registered write stage.  The prior entry retires in the
                 * same edge, so continuous shell responses remain legal. */
                if (copy_count < FOOTPRINT_CAP) begin
                    copy_wr_pending <= 1'b1;
                    copy_wr_addr <= copy_count;
                    copy_wr_data <= shell_rd_data_vector;
                end
                copy_count <= copy_count + 1'b1;
                if ((copy_count + 1'b1) >= total_reads_reg) begin
                    emit_addr <= 0;
                    emit_pixel <= 0;
                    emit_tap <= 0;
                    token_valid <= 1'b0;
                    prefetch_addr <= 0;
                    prefetch_valid <= 1'b0;
                    state <= ST_PRIME;
                end
            end

            if (copy_wr_pending && !(shell_rd_valid && shell_rd_ready))
                copy_wr_pending <= 1'b0;

            if (state == ST_PRIME) begin
                token_valid <= 1'b0;
                prefetch_valid <= 1'b0;
                prefetch_addr <= emit_addr;
                prefetch_wait <= 2'd0;
                state <= ST_EMIT;
            end

            if (state == ST_EMIT) begin
                prefetch_rd_en <= 1'b0;
                /* The window RAM is read only through this registered
                 * address/data prefetch.  This is the physical boundary that
                 * keeps the 289-entry local store from becoming a 289:1
                 * combinational mux on the DSP operand path. */
                if (!token_valid && !prefetch_valid) begin
                    if (prefetch_wait == 2'd0) begin
                        prefetch_rd_addr <= prefetch_addr;
                        prefetch_rd_en <= 1'b1;
                        prefetch_wait <= 2'd1;
                    end else if (prefetch_wait == 2'd1) begin
                        /* The synchronous RAM output is updated at this
                         * edge; defer capture one more edge so both RTL
                         * simulation and XPM RAM have the same latency. */
                        prefetch_wait <= 2'd2;
                    end else begin
                        prefetch_data <= {local_rd_data3, local_rd_data2,
                                          local_rd_data1, local_rd_data0};
                        prefetch_valid <= 1'b1;
                        prefetch_wait <= 2'd0;
                    end
                end else if (!token_valid && prefetch_valid) begin
                    token_valid <= 1'b1;
                    token_first <= (emit_tap == 0);
                    token_last <= (emit_tap == 8);
                    token_pixel <= emit_pixel;
                    token_tap <= emit_tap;
                    token_lane_mask <= lane_mask_reg;
                    token_act <= prefetch_data;
                    token_weight <= sched_weight_mem[emit_tap];
                    prefetch_valid <= 1'b0;
                end else if (core_input_fire) begin
                    token_count <= token_count + 1'b1;
                    if ((emit_pixel == OUTPUT_LAST_PIXEL) &&
                        (emit_tap == 4'd8)) begin
                        token_valid <= 1'b0;
                        state <= ST_DRAIN;
                    end else begin
                        emit_addr <= emit_next_addr;
                        emit_pixel <= emit_next_pixel;
                        emit_tap <= emit_next_tap;
                        token_first <= (emit_next_tap == 0);
                        token_last <= (emit_next_tap == 8);
                        token_pixel <= emit_next_pixel;
                        token_tap <= emit_next_tap;
                        token_lane_mask <= lane_mask_reg;
                        token_valid <= 1'b0;
                        prefetch_addr <= emit_next_addr;
                        prefetch_valid <= 1'b0;
                        prefetch_wait <= 2'd0;
                    end
                end
            end

            if ((state == ST_DRAIN) && core_output_fire) begin
                final_output_seen <= 1'b1;
                if (read_done_seen)
                    state <= ST_RELEASE;
            end
            if ((state == ST_DRAIN) && read_done_seen && final_output_seen)
                state <= ST_RELEASE;

            if ((state == ST_RELEASE) && shell_release_ready)
                state <= ST_DONE;
            if ((state == ST_DONE) && shell_release_resp_valid) begin
                compute_done_valid <= shell_release_resp_ok;
                compute_done_bank <= compute_bank_reg;
                compute_done_epoch <= compute_epoch_reg;
                state <= ST_IDLE;
            end

            if (fill_busy && (state != ST_IDLE))
                overlap_cycles <= overlap_cycles + 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_IN_H < 1 || MAX_IN_H > 17 || MAX_IN_W < 1 || MAX_IN_W > 17)
            $error("window dimensions must be in 1..17");
        if (MAX_CHANNEL_GROUPS < 1 || MAX_CHANNEL_GROUPS > 3)
            $error("MAX_CHANNEL_GROUPS must be in 1..3");
        if (LAYOUT_GROUPS < 1 || LAYOUT_GROUPS > MAX_CHANNEL_GROUPS)
            $error("LAYOUT_GROUPS outside shell capacity");
        if (OUTPUT_HEIGHT < 1 || OUTPUT_HEIGHT > 8 ||
            OUTPUT_WIDTH != 8)
            $error("word-window producer supports output geometry Hx8, H=1..8");
    end
`endif
endmodule

`default_nettype wire
