`timescale 1ns/1ps
`default_nettype none

/*
 * Small, non-production paired-half scratch bank.
 *
 * One logical bank holds one 8-pixel by 8-channel DW tile for every
 * configured Cin group.  The tile is written as two 4-pixel by 8-channel
 * halves.  A write session must retire both halves of group 0, then both
 * halves of group 1, and so on; the half order inside a group is arbitrary.
 * The two logical banks are independently owned so that one may be consumed
 * while the other is filled.
 *
 * The data plane deliberately carries no session/epoch tags.  Session and
 * epoch are checked only at acquire/commit (and the read-side acquire), while
 * the ownership FSM prevents read-before-commit and overwrite.  Completion
 * uses a group cursor plus two one-bit local half-retired flags, not a wide
 * write-seen bitmap.
 */
module dw_pw_pair_scratch_bank #(
    parameter SESSION_WIDTH = 2,
    parameter EPOCH_WIDTH = 2,
    parameter GROUP_WIDTH = 5,
    parameter MAX_GROUPS = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         dw_acquire_valid,
    output wire                         dw_acquire_ready,
    input  wire                         dw_acquire_bank,
    input  wire [SESSION_WIDTH-1:0]     dw_acquire_session,
    input  wire [EPOCH_WIDTH-1:0]       dw_acquire_epoch,
    input  wire [GROUP_WIDTH-1:0]       dw_acquire_group_count,

    input  wire                         dw_write_valid,
    output wire                         dw_write_ready,
    input  wire                         dw_write_bank,
    input  wire [GROUP_WIDTH-1:0]       dw_write_group,
    input  wire                         dw_write_half,
    input  wire [255:0]                 dw_write_data,
    input  wire [31:0]                  dw_write_lane_mask,

    input  wire                         dw_commit_valid,
    output wire                         dw_commit_ready,
    input  wire                         dw_commit_bank,
    input  wire [SESSION_WIDTH-1:0]     dw_commit_session,
    input  wire [EPOCH_WIDTH-1:0]       dw_commit_epoch,

    input  wire                         pw_acquire_valid,
    output wire                         pw_acquire_ready,
    input  wire                         pw_acquire_bank,
    input  wire [SESSION_WIDTH-1:0]     pw_acquire_session,
    input  wire [EPOCH_WIDTH-1:0]       pw_acquire_epoch,

    input  wire                         pw_read_valid,
    output wire                         pw_read_ready,
    input  wire                         pw_read_bank,
    input  wire [GROUP_WIDTH-1:0]       pw_read_group,
    output reg                          pw_out_valid,
    input  wire                         pw_out_ready,
    output reg [511:0]                  pw_out_data,
    output reg [63:0]                   pw_out_lane_mask,

    input  wire                         pw_release_valid,
    output wire                         pw_release_ready,
    input  wire                         pw_release_bank,

    output reg [1:0]                    bank0_state,
    output reg [1:0]                    bank1_state,
    output reg [GROUP_WIDTH-1:0]        bank0_group_cursor,
    output reg [GROUP_WIDTH-1:0]        bank1_group_cursor,
    output reg [5:0]                    bank0_retired_halves,
    output reg [5:0]                    bank1_retired_halves,
    output reg [GROUP_WIDTH-1:0]        bank0_retired_groups,
    output reg [GROUP_WIDTH-1:0]        bank1_retired_groups
);
    localparam MEM_ADDR_WIDTH = (MAX_GROUPS <= 1) ? 1 : $clog2(MAX_GROUPS);
    localparam OWNER_FREE      = 2'd0;
    localparam OWNER_DW        = 2'd1;
    localparam OWNER_COMMITTED = 2'd2;
    localparam OWNER_PW        = 2'd3;

    reg [1:0] owner [0:1];
    reg [SESSION_WIDTH-1:0] session_id [0:1];
    reg [EPOCH_WIDTH-1:0] epoch_id [0:1];
    reg [GROUP_WIDTH-1:0] expected_groups [0:1];
    reg [GROUP_WIDTH-1:0] group_cursor [0:1];
    reg [GROUP_WIDTH-1:0] retired_groups [0:1];
    reg [5:0] retired_halves [0:1];
    reg top_retired [0:1];
    reg bottom_retired [0:1];
    reg all_groups_retired [0:1];

    /* Lane masks are metadata, not completion state.  For a fixed 4x8
     * spatial tile the pixel part of a mask is invariant across Cin groups;
     * only the final Cin group can carry a channel tail.  Keep two compact
     * descriptors per half (first/full-group and final-group) instead of a
     * dynamically addressed [bank][group] register array.  Apart from
     * removing a large group-index CE decode, this retains the exact tail
     * semantics of the original ABI: the first descriptor is used for every
     * non-final group and the final descriptor is used for the last group.
     * The first and final descriptors are captured independently for top and
     * bottom halves, so either half order remains legal. */
    reg [31:0] top_lane_mask_base [0:1];
    reg [31:0] bottom_lane_mask_base [0:1];
    reg [31:0] top_lane_mask_last [0:1];
    reg [31:0] bottom_lane_mask_last [0:1];

    wire acq_bank_free = (owner[dw_acquire_bank] == OWNER_FREE);
    wire acq_count_valid = (dw_acquire_group_count != {GROUP_WIDTH{1'b0}}) &&
                           (dw_acquire_group_count <= MAX_GROUPS);
    assign dw_acquire_ready = rst_n && acq_bank_free && acq_count_valid;
    wire dw_acquire_fire = dw_acquire_valid && dw_acquire_ready;

    wire write_bank_dw = (owner[dw_write_bank] == OWNER_DW);
    wire write_group_match = (dw_write_group == group_cursor[dw_write_bank]);
    wire write_half_new = dw_write_half ? !bottom_retired[dw_write_bank]
                                        : !top_retired[dw_write_bank];
    assign dw_write_ready = rst_n && write_bank_dw && write_group_match &&
                            write_half_new &&
                            !all_groups_retired[dw_write_bank];
    wire dw_write_fire = dw_write_valid && dw_write_ready;
    wire write_first_group = (dw_write_group == {GROUP_WIDTH{1'b0}});
    wire write_last_group = ((dw_write_group + 1'b1) ==
                             expected_groups[dw_write_bank]);

    wire commit_bank_dw = (owner[dw_commit_bank] == OWNER_DW);
    wire commit_tag_match = (session_id[dw_commit_bank] == dw_commit_session) &&
                            (epoch_id[dw_commit_bank] == dw_commit_epoch);
    assign dw_commit_ready = rst_n && commit_bank_dw && commit_tag_match &&
                             all_groups_retired[dw_commit_bank] &&
                             !dw_write_fire;
    wire dw_commit_fire = dw_commit_valid && dw_commit_ready;

    wire pw_commit_match = (owner[pw_acquire_bank] == OWNER_COMMITTED) &&
                           (session_id[pw_acquire_bank] == pw_acquire_session) &&
                           (epoch_id[pw_acquire_bank] == pw_acquire_epoch);
    assign pw_acquire_ready = rst_n && pw_commit_match;
    wire pw_acquire_fire = pw_acquire_valid && pw_acquire_ready;

    reg read_pending;
    reg read_pending_bank;
    reg [GROUP_WIDTH-1:0] read_pending_group;
    /* Register the accepted read before driving the BRAM enable/address.
     * This keeps a consumer's live group selector (which may include a
     * reverse-order mux) off the BRAM ENARDEN path. */
    reg read_issue_valid;
    reg read_issue_bank;
    reg [GROUP_WIDTH-1:0] read_issue_group;
    wire pw_read_bank_owned = (owner[pw_read_bank] == OWNER_PW);
    wire pw_read_group_valid = (pw_read_group < expected_groups[pw_read_bank]);
    assign pw_read_ready = rst_n && pw_read_bank_owned && pw_read_group_valid &&
                           !read_pending && !read_issue_valid &&
                           (!pw_out_valid || pw_out_ready);
    wire pw_read_fire = pw_read_valid && pw_read_ready;

    assign pw_release_ready = rst_n && (owner[pw_release_bank] == OWNER_PW) &&
                              !read_pending && !pw_out_valid;
    wire pw_release_fire = pw_release_valid && pw_release_ready;

    wire [255:0] top_rd_data [0:1];
    wire [255:0] bottom_rd_data [0:1];
    wire [3:0] top_rd_en;
    wire [3:0] bottom_rd_en;
    wire [MEM_ADDR_WIDTH-1:0] mem_write_group = dw_write_group[MEM_ADDR_WIDTH-1:0];
    wire [MEM_ADDR_WIDTH-1:0] mem_read_group =
        read_issue_group[MEM_ADDR_WIDTH-1:0];
    wire read_last_group = ((read_pending_group + 1'b1) ==
                            expected_groups[read_pending_bank]);
    wire [31:0] read_top_lane_mask = read_last_group ?
        top_lane_mask_last[read_pending_bank] :
        top_lane_mask_base[read_pending_bank];
    wire [31:0] read_bottom_lane_mask = read_last_group ?
        bottom_lane_mask_last[read_pending_bank] :
        bottom_lane_mask_base[read_pending_bank];

    genvar b;
    generate
        for (b = 0; b < 2; b = b + 1) begin : gen_bank
            wire wr_top_en = dw_write_fire && (dw_write_bank == b[0:0]) &&
                             !dw_write_half;
            wire wr_bottom_en = dw_write_fire && (dw_write_bank == b[0:0]) &&
                                dw_write_half;
            wire rd_en = read_issue_valid && (read_issue_bank == b[0:0]);
            assign top_rd_en[b] = rd_en;
            assign bottom_rd_en[b] = rd_en;
`ifdef SYNTHESIS
            xpm_memory_sdpram #(
                .ADDR_WIDTH_A(MEM_ADDR_WIDTH), .ADDR_WIDTH_B(MEM_ADDR_WIDTH),
                .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8),
                .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"),
                .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
                .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
                .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(4096),
                .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(256),
                .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
                .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
                .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
                .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
                .WRITE_DATA_WIDTH_A(256), .WRITE_MODE_B("read_first")
            ) top_mem (
                .clka(clk), .clkb(clk), .ena(wr_top_en), .enb(rd_en),
                .addra(mem_write_group), .addrb(mem_read_group),
                .dina(dw_write_data), .wea(32'hffff_ffff),
                .doutb(top_rd_data[b]), .rstb(!rst_n), .regceb(1'b1),
                .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
                .dbiterrb(), .sbiterrb()
            );
            xpm_memory_sdpram #(
                .ADDR_WIDTH_A(MEM_ADDR_WIDTH), .ADDR_WIDTH_B(MEM_ADDR_WIDTH),
                .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8),
                .CASCADE_HEIGHT(0), .CLOCKING_MODE("common_clock"),
                .ECC_MODE("no_ecc"), .MEMORY_INIT_FILE("none"),
                .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
                .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(4096),
                .MESSAGE_CONTROL(0), .READ_DATA_WIDTH_B(256),
                .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"),
                .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
                .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
                .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
                .WRITE_DATA_WIDTH_A(256), .WRITE_MODE_B("read_first")
            ) bottom_mem (
                .clka(clk), .clkb(clk), .ena(wr_bottom_en), .enb(rd_en),
                .addra(mem_write_group), .addrb(mem_read_group),
                .dina(dw_write_data), .wea(32'hffff_ffff),
                .doutb(bottom_rd_data[b]), .rstb(!rst_n), .regceb(1'b1),
                .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
                .dbiterrb(), .sbiterrb()
            );
`else
            reg [255:0] top_mem [0:MAX_GROUPS-1];
            reg [255:0] bottom_mem [0:MAX_GROUPS-1];
            reg [255:0] top_rd_reg;
            reg [255:0] bottom_rd_reg;
            integer byte_i;
            always @(posedge clk) begin
                if (wr_top_en)
                    top_mem[dw_write_group] <= dw_write_data;
                if (wr_bottom_en)
                    bottom_mem[dw_write_group] <= dw_write_data;
                if (rd_en) begin
                    top_rd_reg <= top_mem[pw_read_group];
                    bottom_rd_reg <= bottom_mem[pw_read_group];
                end
            end
            assign top_rd_data[b] = top_rd_reg;
            assign bottom_rd_data[b] = bottom_rd_reg;
`endif
        end
    endgenerate

    integer bi;
    integer gi;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (bi = 0; bi < 2; bi = bi + 1) begin
                owner[bi] <= OWNER_FREE;
                session_id[bi] <= {SESSION_WIDTH{1'b0}};
                epoch_id[bi] <= {EPOCH_WIDTH{1'b0}};
                expected_groups[bi] <= {GROUP_WIDTH{1'b0}};
                group_cursor[bi] <= {GROUP_WIDTH{1'b0}};
                retired_groups[bi] <= {GROUP_WIDTH{1'b0}};
                retired_halves[bi] <= 6'd0;
                top_retired[bi] <= 1'b0;
                bottom_retired[bi] <= 1'b0;
                all_groups_retired[bi] <= 1'b0;
                top_lane_mask_base[bi] <= 32'd0;
                bottom_lane_mask_base[bi] <= 32'd0;
                top_lane_mask_last[bi] <= 32'd0;
                bottom_lane_mask_last[bi] <= 32'd0;
            end
            pw_out_valid <= 1'b0;
            pw_out_data <= 512'd0;
            pw_out_lane_mask <= 64'd0;
            read_pending <= 1'b0;
            read_pending_bank <= 1'b0;
            read_pending_group <= {GROUP_WIDTH{1'b0}};
            read_issue_valid <= 1'b0;
            read_issue_bank <= 1'b0;
            read_issue_group <= {GROUP_WIDTH{1'b0}};
        end else begin
            if (dw_acquire_fire) begin
                owner[dw_acquire_bank] <= OWNER_DW;
                session_id[dw_acquire_bank] <= dw_acquire_session;
                epoch_id[dw_acquire_bank] <= dw_acquire_epoch;
                expected_groups[dw_acquire_bank] <= dw_acquire_group_count;
                group_cursor[dw_acquire_bank] <= {GROUP_WIDTH{1'b0}};
                retired_groups[dw_acquire_bank] <= {GROUP_WIDTH{1'b0}};
                retired_halves[dw_acquire_bank] <= 6'd0;
                top_retired[dw_acquire_bank] <= 1'b0;
                bottom_retired[dw_acquire_bank] <= 1'b0;
                all_groups_retired[dw_acquire_bank] <= 1'b0;
                top_lane_mask_base[dw_acquire_bank] <= 32'd0;
                bottom_lane_mask_base[dw_acquire_bank] <= 32'd0;
                top_lane_mask_last[dw_acquire_bank] <= 32'd0;
                bottom_lane_mask_last[dw_acquire_bank] <= 32'd0;
            end

            if (dw_write_fire) begin
                retired_halves[dw_write_bank] <= retired_halves[dw_write_bank] + 6'd1;
                if (dw_write_half) begin
                    bottom_retired[dw_write_bank] <= 1'b1;
                    if (write_first_group)
                        bottom_lane_mask_base[dw_write_bank] <= dw_write_lane_mask;
                    if (write_last_group)
                        bottom_lane_mask_last[dw_write_bank] <= dw_write_lane_mask;
                end else begin
                    top_retired[dw_write_bank] <= 1'b1;
                    if (write_first_group)
                        top_lane_mask_base[dw_write_bank] <= dw_write_lane_mask;
                    if (write_last_group)
                        top_lane_mask_last[dw_write_bank] <= dw_write_lane_mask;
                end

                if ((top_retired[dw_write_bank] || !dw_write_half) &&
                    (bottom_retired[dw_write_bank] || dw_write_half)) begin
                    retired_groups[dw_write_bank] <= retired_groups[dw_write_bank] + 1'b1;
                    if (group_cursor[dw_write_bank] + 1'b1 ==
                        expected_groups[dw_write_bank]) begin
                        all_groups_retired[dw_write_bank] <= 1'b1;
                    end else begin
                        group_cursor[dw_write_bank] <= group_cursor[dw_write_bank] + 1'b1;
                        top_retired[dw_write_bank] <= 1'b0;
                        bottom_retired[dw_write_bank] <= 1'b0;
                    end
                end
            end

            if (dw_commit_fire)
                owner[dw_commit_bank] <= OWNER_COMMITTED;

            if (pw_acquire_fire)
                owner[pw_acquire_bank] <= OWNER_PW;

            if (pw_read_fire) begin
                read_issue_valid <= 1'b1;
                read_issue_bank <= pw_read_bank;
                read_issue_group <= pw_read_group;
            end

            /* The BRAM sees the registered issue above for one full cycle.
             * Promote it to the response-pending stage only after the BRAM
             * read edge, preserving the original one-vector-at-a-time
             * protocol while adding a clean timing boundary. */
            if (read_issue_valid) begin
                read_issue_valid <= 1'b0;
                read_pending <= 1'b1;
                read_pending_bank <= read_issue_bank;
                read_pending_group <= read_issue_group;
            end

            if (read_pending) begin
                pw_out_data <= {bottom_rd_data[read_pending_bank],
                                top_rd_data[read_pending_bank]};
                pw_out_lane_mask <= {read_bottom_lane_mask, read_top_lane_mask};
                pw_out_valid <= 1'b1;
                read_pending <= 1'b0;
            end else if (pw_out_valid && pw_out_ready) begin
                pw_out_valid <= 1'b0;
            end

            if (pw_release_fire)
                owner[pw_release_bank] <= OWNER_FREE;
        end
    end

    always @* begin
        bank0_state = owner[0];
        bank1_state = owner[1];
        bank0_group_cursor = group_cursor[0];
        bank1_group_cursor = group_cursor[1];
        bank0_retired_halves = retired_halves[0];
        bank1_retired_halves = retired_halves[1];
        bank0_retired_groups = retired_groups[0];
        bank1_retired_groups = retired_groups[1];
    end
endmodule

`default_nettype wire
