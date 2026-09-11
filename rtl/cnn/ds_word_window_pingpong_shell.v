`timescale 1ns/1ps
`default_nettype none

/*
 * Two-bank word-fed window shell.
 *
 * This is a storage/dataflow feasibility boundary, not the production DS
 * runner.  A single source-word fill engine writes one inactive bank.  A
 * separate registered reader walks a row-major window in the other bank.  A
 * bank can move FREE -> FILL -> READY -> ACTIVE -> FREE only through the
 * corresponding epoch descriptor; stale acquire/release commands are
 * rejected and counted.  The bank output is already registered by
 * ds_spatial_word_window_bank and is captured once more here, so a bank swap
 * cannot change the payload of an in-flight vector response.
 */
module ds_word_window_pingpong_shell #(
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer MAX_CHANNEL_GROUPS = 3,
    parameter integer LAYOUT_GROUPS = MAX_CHANNEL_GROUPS,
    parameter integer ADDR_WIDTH = 24,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer VECTOR_ADDR_WIDTH =
        ((MAX_IN_H*MAX_IN_W*MAX_CHANNEL_GROUPS) > 1) ?
        $clog2(MAX_IN_H*MAX_IN_W*MAX_CHANNEL_GROUPS) : 1,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer TAG_WIDTH = 16,
    parameter integer FIFO_DEPTH = 8,
    /* Producer-only mode: caller supplies tap addresses; ownership and
     * registered BRAM response handling remain local to this shell. */
    parameter integer DIRECT_READ_ENABLE = 0
) (
    input wire clk,
    input wire rst_n,

    input wire fill_start_valid,
    output wire fill_start_ready,
    input wire fill_start_bank,
    input wire [EPOCH_WIDTH-1:0] fill_start_epoch,
    input wire [ADDR_WIDTH-1:0] fill_start_base_addr,
    input wire [WORD_COUNT_WIDTH-1:0] fill_start_word_count,
    output reg fill_done_valid,
    input wire fill_done_ready,
    output reg fill_done_bank,
    output reg [EPOCH_WIDTH-1:0] fill_done_epoch,

    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid,
    input wire [31:0] mem_resp_data,
    output wire mem_resp_ready,

    input wire read_start_valid,
    output wire read_start_ready,
    input wire read_start_bank,
    input wire [EPOCH_WIDTH-1:0] read_start_epoch,
    input wire [7:0] read_height,
    input wire [7:0] read_width,
    input wire [7:0] read_stride,
    input wire [7:0] read_pitch,
    input wire [VECTOR_ADDR_WIDTH-1:0] read_base_vector,
    input wire [1:0] read_group,
    input wire [15:0] read_lane_mask,
    input wire direct_req_valid,
    output wire direct_req_ready,
    input wire [VECTOR_ADDR_WIDTH-1:0] direct_req_addr,
    input wire [15:0] direct_req_lane_mask,
    input wire [TAG_WIDTH-1:0] direct_req_tag,
    input wire [EPOCH_WIDTH-1:0] direct_req_epoch,
    input wire direct_req_last,
    output reg read_done_valid,
    input wire read_done_ready,
    output reg read_done_bank,
    output reg [EPOCH_WIDTH-1:0] read_done_epoch,

    output wire rd_valid,
    input wire rd_ready,
    output wire [VECTOR_ADDR_WIDTH-1:0] rd_vector_addr,
    output wire [15:0] rd_lane_mask,
    output wire [TAG_WIDTH-1:0] rd_tag,
    output wire [EPOCH_WIDTH-1:0] rd_epoch,
    output wire [127:0] rd_data_vector,

    input wire release_valid,
    output wire release_ready,
    input wire release_bank,
    input wire [EPOCH_WIDTH-1:0] release_epoch,
    output reg release_resp_valid,
    input wire release_resp_ready,
    output reg release_resp_ok,

    output reg [1:0] bank0_state,
    output reg [1:0] bank1_state,
    output wire fill_busy,
    output wire read_busy,
    output reg [31:0] fill_word_count_seen,
    output reg [31:0] read_vector_count,
    output reg [31:0] overlap_cycles,
    output reg [31:0] stale_command_count
);
    localparam [1:0] S_FREE = 2'd0;
    localparam [1:0] S_FILL = 2'd1;
    localparam [1:0] S_READY = 2'd2;
    localparam [1:0] S_ACTIVE = 2'd3;
    localparam integer DEPTH = MAX_IN_H * MAX_IN_W * MAX_CHANNEL_GROUPS;
    localparam integer COUNT_WIDTH = 17;

    reg [EPOCH_WIDTH-1:0] bank0_epoch, bank1_epoch;
    reg fill_bank_reg;
    reg read_bank_reg;
    reg [EPOCH_WIDTH-1:0] read_epoch_reg;
    reg read_active;
    reg read_complete;
    reg [7:0] read_h_reg, read_w_reg, read_stride_reg, read_pitch_reg;
    reg [VECTOR_ADDR_WIDTH-1:0] read_col_step_reg, read_row_delta_reg;
    reg [1:0] read_group_reg;
    reg [15:0] read_mask_reg;
    reg [7:0] read_row, read_col;
    reg [COUNT_WIDTH-1:0] read_total, read_issued;
    reg [VECTOR_ADDR_WIDTH-1:0] read_addr;
    reg direct_last_issued;
    /* Number of accepted synchronous reads not yet consumed by the shell
     * output register.  The bank now has a two-stage read pipe, so a single
     * in-flight bit would unnecessarily reintroduce the old stop-and-wait
     * bubble. */
    reg [9:0] read_outstanding;
    localparam integer READ_ADDR_FIFO_DEPTH = 8;
    reg [VECTOR_ADDR_WIDTH-1:0] read_addr_fifo [0:READ_ADDR_FIFO_DEPTH-1];
    reg [2:0] read_addr_wr_ptr, read_addr_rd_ptr;
    reg [3:0] read_addr_fifo_count;
    reg out_valid_q;
    reg [VECTOR_ADDR_WIDTH-1:0] out_addr_q;
    reg [15:0] out_mask_q;
    reg [TAG_WIDTH-1:0] out_tag_q;
    reg [EPOCH_WIDTH-1:0] out_epoch_q;
    reg [127:0] out_data_q;

    wire fill_engine_done_valid;
    wire fill_engine_done_ready;
    wire fill_engine_busy;
    wire fill_wr_valid;
    wire fill_wr_ready;
    wire [VECTOR_ADDR_WIDTH-1:0] fill_wr_addr;
    wire [1:0] fill_wr_quarter;
    wire [31:0] fill_wr_data;
    wire [EPOCH_WIDTH-1:0] fill_wr_epoch;

    wire b0_wr_ready, b1_wr_ready;
    wire b0_rd_req_ready, b1_rd_req_ready;
    wire b0_rd_resp_valid, b1_rd_resp_valid;
    wire [127:0] b0_rd_data, b1_rd_data;
    wire [15:0] b0_rd_mask, b1_rd_mask;
    wire [TAG_WIDTH-1:0] b0_rd_tag, b1_rd_tag;
    wire [EPOCH_WIDTH-1:0] b0_rd_epoch, b1_rd_epoch;

    wire selected_fill_ready = fill_bank_reg ? b1_wr_ready : b0_wr_ready;
    assign fill_wr_ready = selected_fill_ready;
    assign fill_busy = fill_engine_busy;
    assign read_busy = read_active;

    ds_word_window_fill_engine #(
        .ADDR_WIDTH(ADDR_WIDTH), .VECTOR_ADDR_WIDTH(VECTOR_ADDR_WIDTH),
        .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
        .EPOCH_WIDTH(EPOCH_WIDTH)
    ) u_fill (
        .clk(clk), .rst_n(rst_n),
        .start_valid(fill_start_valid && fill_start_ready),
        .start_ready(), .start_bank({3'd0,fill_start_bank}),
        .start_epoch(fill_start_epoch), .start_base_addr(fill_start_base_addr),
        .start_word_count(fill_start_word_count),
        .done_valid(fill_engine_done_valid), .done_ready(fill_engine_done_ready),
        .done_bank(), .done_epoch(), .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr),
        .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data),
        .mem_resp_ready(mem_resp_ready),
        .wr_valid(fill_wr_valid), .wr_ready(fill_wr_ready),
        .wr_vector_addr(fill_wr_addr), .wr_quarter(fill_wr_quarter),
        .wr_data(fill_wr_data), .wr_epoch(fill_wr_epoch),
        .busy(fill_engine_busy), .issue_count(), .response_count(),
        .write_count(), .stale_response_count()
    );

    /* The helper's ready is not exposed as a second global start condition:
     * the shell's bank state is the sole ownership arbiter. */
    assign fill_start_ready = rst_n && !fill_engine_busy &&
        !fill_engine_done_valid &&
        ((fill_start_bank ? bank1_state : bank0_state) == S_FREE);
    /* Hold the helper descriptor until the outward descriptor latch is free;
     * this permits a second bank to finish while the first completion is
     * being observed without dropping either fence. */
    assign fill_engine_done_ready = !fill_done_valid || fill_done_ready;

    ds_spatial_word_window_bank #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .MAX_CHANNEL_GROUPS(MAX_CHANNEL_GROUPS), .DEPTH(DEPTH),
        .ADDR_WIDTH(VECTOR_ADDR_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH),
        .TAG_WIDTH(TAG_WIDTH)
    ) u_bank0 (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(fill_wr_valid && !fill_bank_reg), .wr_ready(b0_wr_ready),
        .wr_vector_addr(fill_wr_addr), .wr_quarter(fill_wr_quarter),
        .wr_data(fill_wr_data), .wr_epoch(fill_wr_epoch), .wr_epoch_seen(),
        .rd_req_valid(read_active && !read_bank_reg && rd_req_fire),
        .rd_req_ready(b0_rd_req_ready), .rd_vector_addr(rd_req_addr),
        .rd_lane_mask(rd_req_mask), .rd_tag(rd_req_tag),
        .rd_epoch(rd_req_epoch), .rd_resp_valid(b0_rd_resp_valid),
        .rd_resp_ready((!read_bank_reg) && (!out_valid_q || rd_ready)),
        .rd_data_vector(b0_rd_data), .rd_resp_lane_mask(b0_rd_mask),
        .rd_resp_tag(b0_rd_tag), .rd_resp_epoch(b0_rd_epoch)
    );
    ds_spatial_word_window_bank #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .MAX_CHANNEL_GROUPS(MAX_CHANNEL_GROUPS), .DEPTH(DEPTH),
        .ADDR_WIDTH(VECTOR_ADDR_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH),
        .TAG_WIDTH(TAG_WIDTH)
    ) u_bank1 (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(fill_wr_valid && fill_bank_reg), .wr_ready(b1_wr_ready),
        .wr_vector_addr(fill_wr_addr), .wr_quarter(fill_wr_quarter),
        .wr_data(fill_wr_data), .wr_epoch(fill_wr_epoch), .wr_epoch_seen(),
        .rd_req_valid(read_active && read_bank_reg && rd_req_fire),
        .rd_req_ready(b1_rd_req_ready), .rd_vector_addr(rd_req_addr),
        .rd_lane_mask(rd_req_mask), .rd_tag(rd_req_tag),
        .rd_epoch(rd_req_epoch), .rd_resp_valid(b1_rd_resp_valid),
        .rd_resp_ready(read_bank_reg && (!out_valid_q || rd_ready)),
        .rd_data_vector(b1_rd_data), .rd_resp_lane_mask(b1_rd_mask),
        .rd_resp_tag(b1_rd_tag), .rd_resp_epoch(b1_rd_epoch)
    );

    wire read_bank_req_ready = read_bank_reg ? b1_rd_req_ready : b0_rd_req_ready;
    wire [VECTOR_ADDR_WIDTH-1:0] rd_req_addr =
        (DIRECT_READ_ENABLE != 0) ? direct_req_addr : read_addr;
    wire [15:0] rd_req_mask =
        (DIRECT_READ_ENABLE != 0) ? direct_req_lane_mask : read_mask_reg;
    wire [TAG_WIDTH-1:0] rd_req_tag =
        (DIRECT_READ_ENABLE != 0) ? direct_req_tag : read_issued[TAG_WIDTH-1:0];
    wire [EPOCH_WIDTH-1:0] rd_req_epoch =
        (DIRECT_READ_ENABLE != 0) ? direct_req_epoch : read_epoch_reg;
    wire rd_req_intent = (DIRECT_READ_ENABLE != 0) ? direct_req_valid : 1'b1;
    wire rd_req_has_room = (DIRECT_READ_ENABLE != 0) ? direct_req_valid :
                           (read_issued < read_total);
    wire rd_req_fire = read_active && !read_complete && rd_req_intent &&
                       (!out_valid_q || rd_ready) && rd_req_has_room &&
                       read_bank_req_ready &&
                       (read_addr_fifo_count < READ_ADDR_FIFO_DEPTH);
    assign direct_req_ready = (DIRECT_READ_ENABLE != 0) && read_active &&
                       !read_complete && (!out_valid_q || rd_ready) &&
                       read_bank_req_ready &&
                       (read_addr_fifo_count < READ_ADDR_FIFO_DEPTH);
    wire bank_resp_valid = read_bank_reg ? b1_rd_resp_valid : b0_rd_resp_valid;
    wire bank_resp_fire = bank_resp_valid && (!out_valid_q || rd_ready);
    wire out_fire = out_valid_q && rd_ready;

    assign rd_valid = out_valid_q;
    assign rd_vector_addr = out_addr_q;
    assign rd_lane_mask = out_mask_q;
    assign rd_tag = out_tag_q;
    assign rd_epoch = out_epoch_q;
    assign rd_data_vector = out_data_q;
    assign read_start_ready = rst_n && !read_active && !read_done_valid &&
        ((read_start_bank ? bank1_state : bank0_state) == S_READY) &&
        ((read_start_bank ? bank1_epoch : bank0_epoch) == read_start_epoch);
    assign release_ready = rst_n && !release_resp_valid &&
        ((release_bank ? bank1_state : bank0_state) == S_ACTIVE) &&
        ((release_bank ? bank1_epoch : bank0_epoch) == release_epoch) &&
        ((release_bank == read_bank_reg) && read_complete && !out_valid_q);

    always @(posedge clk) begin
        if (!rst_n) begin
            bank0_state <= S_FREE;
            bank1_state <= S_FREE;
            bank0_epoch <= 0;
            bank1_epoch <= 0;
            fill_bank_reg <= 0;
            fill_done_valid <= 0;
            fill_done_bank <= 0;
            fill_done_epoch <= 0;
            read_bank_reg <= 0;
            read_epoch_reg <= 0;
            read_active <= 0;
            read_complete <= 0;
            read_done_valid <= 0;
            read_done_bank <= 0;
            read_done_epoch <= 0;
            release_resp_valid <= 0;
            release_resp_ok <= 0;
            read_h_reg <= 0; read_w_reg <= 0; read_stride_reg <= 1;
            read_pitch_reg <= 0; read_group_reg <= 0; read_mask_reg <= 0;
            read_col_step_reg <= 0; read_row_delta_reg <= 0;
            read_row <= 0; read_col <= 0; read_total <= 0; read_issued <= 0;
            read_addr <= 0; read_outstanding <= 0;
            direct_last_issued <= 1'b0;
            read_addr_wr_ptr <= 0; read_addr_rd_ptr <= 0;
            read_addr_fifo_count <= 0;
            out_valid_q <= 0; out_addr_q <= 0; out_mask_q <= 0;
            out_tag_q <= 0; out_epoch_q <= 0; out_data_q <= 0;
            fill_word_count_seen <= 0;
            read_vector_count <= 0;
            overlap_cycles <= 0;
            stale_command_count <= 0;
        end else begin
            if (fill_done_valid && fill_done_ready) fill_done_valid <= 0;
            if (read_done_valid && read_done_ready) read_done_valid <= 0;
            if (release_resp_valid && release_resp_ready) release_resp_valid <= 0;

            if (fill_start_valid && fill_start_ready) begin
                fill_bank_reg <= fill_start_bank;
                if (fill_start_bank) begin
                    bank1_state <= S_FILL;
                    bank1_epoch <= fill_start_epoch;
                end else begin
                    bank0_state <= S_FILL;
                    bank0_epoch <= fill_start_epoch;
                end
            end

            if (fill_engine_done_valid && !fill_done_valid) begin
                fill_done_valid <= 1'b1;
                fill_done_bank <= fill_bank_reg;
                fill_done_epoch <= fill_wr_epoch;
                if (fill_bank_reg) bank1_state <= S_READY;
                else bank0_state <= S_READY;
            end

            if (read_start_valid && read_start_ready) begin
                read_bank_reg <= read_start_bank;
                read_epoch_reg <= read_start_epoch;
                read_h_reg <= read_height;
                read_w_reg <= read_width;
                read_stride_reg <= (read_stride == 0) ? 1 : read_stride;
                read_pitch_reg <= read_pitch;
                read_group_reg <= read_group;
                read_mask_reg <= read_lane_mask;
                read_row <= 0;
                read_col <= 0;
                read_total <= read_height * read_width;
                read_issued <= 0;
                read_addr <= read_base_vector + read_group;
                read_col_step_reg <= read_stride * LAYOUT_GROUPS;
                read_row_delta_reg <= (read_stride * read_pitch * LAYOUT_GROUPS) -
                                     ((read_width - 1) * read_stride * LAYOUT_GROUPS);
                read_active <= 1'b1;
                read_complete <= 1'b0;
                read_outstanding <= 0;
                read_addr_wr_ptr <= 0;
                read_addr_rd_ptr <= 0;
                read_addr_fifo_count <= 0;
                direct_last_issued <= 1'b0;
                if (read_start_bank) bank1_state <= S_ACTIVE;
                else bank0_state <= S_ACTIVE;
            end

            if (rd_req_fire) begin
                if (DIRECT_READ_ENABLE != 0) begin
                    if (direct_req_last)
                        direct_last_issued <= 1'b1;
                end else begin
                    read_issued <= read_issued + 1'b1;
                    if (read_col + 1 >= read_w_reg) begin
                        read_col <= 0;
                        read_row <= read_row + 1'b1;
                        read_addr <= read_addr + read_row_delta_reg;
                    end else begin
                        read_col <= read_col + 1'b1;
                        read_addr <= read_addr + read_col_step_reg;
                    end
                end
            end

            if (fill_wr_valid && fill_wr_ready)
                fill_word_count_seen <= fill_word_count_seen + 1'b1;
            if (bank_resp_fire) begin
                out_valid_q <= 1'b1;
                if (read_bank_reg) begin
                    out_addr_q <= read_addr_fifo[read_addr_rd_ptr];
                    out_mask_q <= b1_rd_mask;
                    out_tag_q <= b1_rd_tag;
                    out_epoch_q <= b1_rd_epoch;
                    out_data_q <= b1_rd_data;
                end else begin
                    out_addr_q <= read_addr_fifo[read_addr_rd_ptr];
                    out_mask_q <= b0_rd_mask;
                    out_tag_q <= b0_rd_tag;
                    out_epoch_q <= b0_rd_epoch;
                    out_data_q <= b0_rd_data;
                end
                read_vector_count <= read_vector_count + 1'b1;
            end else if (out_fire) begin
                out_valid_q <= 1'b0;
            end

            if (rd_req_fire) begin
                read_addr_fifo[read_addr_wr_ptr] <= rd_req_addr;
                read_addr_wr_ptr <= read_addr_wr_ptr + 1'b1;
            end
            if (bank_resp_fire)
                read_addr_rd_ptr <= read_addr_rd_ptr + 1'b1;
            case ({rd_req_fire, bank_resp_fire})
                2'b10: begin
                    read_outstanding <= read_outstanding + 1'b1;
                    read_addr_fifo_count <= read_addr_fifo_count + 1'b1;
                end
                2'b01: begin
                    read_outstanding <= read_outstanding - 1'b1;
                    read_addr_fifo_count <= read_addr_fifo_count - 1'b1;
                end
                default: ;
            endcase

            /* A response arriving on this edge is deliberately excluded: it
             * has just populated out_valid_q and must be drained before the
             * completion fence can be published. */
            if (read_active &&
                (((DIRECT_READ_ENABLE == 0) && (read_issued >= read_total)) ||
                 ((DIRECT_READ_ENABLE != 0) && direct_last_issued)) &&
                ((read_outstanding == 0) ||
                 ((read_outstanding == 1) && bank_resp_fire && !rd_req_fire)) &&
                !bank_resp_fire && !out_valid_q && !read_complete) begin
                read_complete <= 1'b1;
                read_active <= 1'b0;
                read_done_valid <= 1'b1;
                read_done_bank <= read_bank_reg;
                read_done_epoch <= read_epoch_reg;
            end

            if (release_valid && release_ready) begin
                release_resp_valid <= 1'b1;
                release_resp_ok <= 1'b1;
                if (release_bank) bank1_state <= S_FREE;
                else bank0_state <= S_FREE;
            end else if (release_valid && !release_ready) begin
                release_resp_valid <= 1'b1;
                release_resp_ok <= 1'b0;
                stale_command_count <= stale_command_count + 1'b1;
            end

            if (fill_engine_busy && read_active)
                overlap_cycles <= overlap_cycles + 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_IN_H < 1 || MAX_IN_H > 17 || MAX_IN_W < 1 || MAX_IN_W > 17)
            $error("window dimensions must be in 1..17");
        if (MAX_CHANNEL_GROUPS < 1 || MAX_CHANNEL_GROUPS > 3)
            $error("channel groups must be in 1..3");
    end
`endif
endmodule

`default_nettype wire
