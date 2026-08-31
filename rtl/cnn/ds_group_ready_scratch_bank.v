`timescale 1ns/1ps
`default_nettype none

/*
 * Locally owned two-bank scratch for group-ready partial-K traffic.
 *
 * Each row/group address contains two 256-bit 4-channel halves.  A descriptor
 * is enqueued as soon as the second half retires; it is not delayed until the
 * whole tile is complete.  The bank remains DW-owned while these descriptors
 * are read, so the PW side can consume a ready group without observing a
 * global owner/state bus.  Commit is a separate, narrow fence after all half
 * writes have retired.  Release is legal only after the final group response
 * has drained.
 *
 * FENCE_MODE is a measurement control used by the prototype testbench.  With
 * it set, the exact same incoming stream and memories are used, but the
 * descriptor FIFO is held until all writes complete; this gives a same-shape
 * complete-tile fence comparison without seeding data or changing arithmetic.
 */
module ds_group_ready_scratch_bank #(
    parameter integer MAX_ROWS = 8,
    parameter integer MAX_GROUPS = 16,
    parameter integer ROW_WIDTH = 3,
    parameter integer GROUP_WIDTH = 4,
    parameter integer SESSION_WIDTH = 2,
    parameter integer EPOCH_WIDTH = 4,
    parameter integer DESC_DEPTH = 16,
    parameter integer FENCE_MODE = 0,
    parameter integer BANK_ID = 0
) (
    input wire clk, input wire rst_n,

    input wire acquire_valid, output wire acquire_ready,
    input wire acquire_bank,
    input wire [SESSION_WIDTH-1:0] acquire_session,
    input wire [EPOCH_WIDTH-1:0] acquire_epoch,
    input wire [ROW_WIDTH-1:0] acquire_rows,
    input wire [GROUP_WIDTH-1:0] acquire_groups,
    input wire [7:0] acquire_cin,
    input wire [7:0] acquire_pixel_mask,
    input wire [7:0] acquire_cout_mask,

    input wire half_valid, output wire half_ready,
    input wire half_bank,
    input wire [SESSION_WIDTH-1:0] half_session,
    input wire [EPOCH_WIDTH-1:0] half_epoch,
    input wire [ROW_WIDTH-1:0] half_row,
    input wire [GROUP_WIDTH-1:0] half_group,
    input wire half_sel,
    input wire [255:0] half_data,
    input wire [31:0] half_lane_mask,

    input wire commit_valid, output wire commit_ready,
    input wire commit_bank,
    input wire [SESSION_WIDTH-1:0] commit_session,
    input wire [EPOCH_WIDTH-1:0] commit_epoch,

    output wire group_req_valid, input wire group_req_ready,
    output wire group_bank,
    output wire [SESSION_WIDTH-1:0] group_session,
    output wire [EPOCH_WIDTH-1:0] group_epoch,
    output wire [ROW_WIDTH-1:0] group_row,
    output wire [GROUP_WIDTH-1:0] group_index,
    output wire group_first_k, output wire group_last_k,
    output wire [7:0] group_k_count,
    output wire [7:0] group_pixel_mask, output wire [7:0] group_cout_mask,

    output reg group_data_valid, input wire group_data_ready,
    output reg [511:0] group_data,
    output reg [ROW_WIDTH-1:0] group_data_row,
    output reg [GROUP_WIDTH-1:0] group_data_index,
    output reg group_data_first_k, output reg group_data_last_k,
    output reg [7:0] group_data_k_count,
    output reg [7:0] group_data_pixel_mask,
    output reg [7:0] group_data_cout_mask,

    input wire release_valid, output wire release_ready,
    input wire release_bank,
    input wire [SESSION_WIDTH-1:0] release_session,
    input wire [EPOCH_WIDTH-1:0] release_epoch,

    output wire all_writes_done,
    output wire all_descriptors_drained,
    output wire [15:0] write_count,
    output wire [15:0] descriptor_count,
    output wire [1:0] bank_state,
    output reg error
);
    localparam [1:0] OWNER_FREE = 2'd0;
    localparam [1:0] OWNER_DW = 2'd1;
    localparam [1:0] OWNER_COMMITTED = 2'd2;
    localparam [1:0] OWNER_PW = 2'd3;
    localparam integer ADDR_WIDTH = ROW_WIDTH + GROUP_WIDTH;
    localparam integer ADDR_DEPTH = (1 << ADDR_WIDTH);
    localparam integer COUNT_WIDTH = (DESC_DEPTH <= 1) ? 1 : $clog2(DESC_DEPTH+1);
    localparam integer PTR_WIDTH = (DESC_DEPTH <= 1) ? 1 : $clog2(DESC_DEPTH);

    reg [1:0] owner;
    reg [SESSION_WIDTH-1:0] session_reg;
    reg [EPOCH_WIDTH-1:0] epoch_reg;
    reg [ROW_WIDTH-1:0] rows_reg;
    reg [GROUP_WIDTH-1:0] groups_reg;
    reg [7:0] cin_reg;
    reg [7:0] pixel_mask_reg, cout_mask_reg;
    reg [15:0] target_writes;
    reg [15:0] writes_reg;

    /* The seen bits are compact write protocol state.  Address bits are
     * concatenated, not multiplied, keeping this fence-local and bounded. */
    reg [ADDR_DEPTH-1:0] top_seen, bottom_seen;
`ifndef SYNTHESIS
    reg [255:0] top_mem [0:1][0:ADDR_DEPTH-1];
    reg [255:0] bottom_mem [0:1][0:ADDR_DEPTH-1];
`else
    wire [255:0] top_mem_rd_data;
    wire [255:0] bottom_mem_rd_data;
`endif

    reg [ROW_WIDTH-1:0] desc_row_mem [0:DESC_DEPTH-1];
    reg [GROUP_WIDTH-1:0] desc_group_mem [0:DESC_DEPTH-1];
    reg [PTR_WIDTH-1:0] desc_wr_ptr, desc_rd_ptr;
    reg [COUNT_WIDTH-1:0] desc_count_reg;
    reg fence_emit_active;
    reg [15:0] fence_emit_count;
    reg [ROW_WIDTH-1:0] fence_emit_row;
    reg [GROUP_WIDTH-1:0] fence_emit_group;

    reg read_pending;
    reg [ROW_WIDTH-1:0] read_row_reg;
    reg [GROUP_WIDTH-1:0] read_group_reg;
    reg [SESSION_WIDTH-1:0] read_session_reg;
    reg [EPOCH_WIDTH-1:0] read_epoch_reg;
    reg read_first_reg, read_last_reg;
    reg [7:0] read_k_count_reg;
    reg [7:0] read_pixel_mask_reg, read_cout_mask_reg;

    localparam BANK_SELECT = (BANK_ID != 0) ? 1'b1 : 1'b0;
    wire bank_match_acq = (acquire_bank == BANK_SELECT);
    wire acquire_fire = acquire_valid && acquire_ready;
    assign acquire_ready = rst_n && (owner == OWNER_FREE) && bank_match_acq;

    wire addr_in_range = (half_row < rows_reg) && (half_group < groups_reg);
    wire [ADDR_WIDTH-1:0] half_addr = {half_group, half_row};
    wire half_seen = half_sel ? bottom_seen[half_addr] : top_seen[half_addr];
    wire half_owner = (owner == OWNER_DW) && (half_bank == BANK_SELECT) &&
                      (half_session == session_reg) &&
                      (half_epoch == epoch_reg);
    wire desc_room = (desc_count_reg < DESC_DEPTH) ||
                     (group_req_valid && group_req_ready);
    wire pair_complete = half_sel ? top_seen[half_addr] :
                                     bottom_seen[half_addr];
    assign half_ready = rst_n && half_owner && addr_in_range && !half_seen &&
                        (!pair_complete || desc_room);
    wire half_fire = half_valid && half_ready;

`ifdef SYNTHESIS
    /* Explicit SDP XPMs are required here.  A two-dimensional behavioral
     * array with a variable bank index maps to tens of thousands of FFs on
     * XC7Z020; these fixed 256-bit row/group ports map to local RAMB36s. */
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(ADDR_WIDTH), .ADDR_WIDTH_B(ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(32768), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(256), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(256),
        .WRITE_MODE_B("read_first")
    ) top_mem_xpm (
        .clka(clk), .clkb(clk), .ena(half_fire && !half_sel),
        .wea(32'hffff_ffff), .addra(half_addr), .dina(half_data),
        .addrb({desc_group_mem[desc_rd_ptr],desc_row_mem[desc_rd_ptr]}),
        .enb(group_req_fire),
        .doutb(top_mem_rd_data), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(ADDR_WIDTH), .ADDR_WIDTH_B(ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(32768), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(256), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(256),
        .WRITE_MODE_B("read_first")
    ) bottom_mem_xpm (
        .clka(clk), .clkb(clk), .ena(half_fire && half_sel),
        .wea(32'hffff_ffff), .addra(half_addr), .dina(half_data),
        .addrb({desc_group_mem[desc_rd_ptr],desc_row_mem[desc_rd_ptr]}),
        .enb(group_req_fire),
        .doutb(bottom_mem_rd_data), .regceb(1'b1), .rstb(!rst_n),
        .sleep(1'b0), .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .dbiterrb(), .sbiterrb()
    );
`endif

    wire expected_write_complete = (writes_reg >= target_writes);
    assign all_writes_done = expected_write_complete;
    assign write_count = writes_reg;

    wire commit_match = (owner == OWNER_DW) &&
                        (commit_bank == BANK_SELECT) &&
                        (commit_session == session_reg) &&
                        (commit_epoch == epoch_reg);
    assign commit_ready = rst_n && commit_match && expected_write_complete &&
                          !half_fire && !fence_emit_active;
    wire commit_fire = commit_valid && commit_ready;

    assign group_req_valid = (desc_count_reg != 0) && !read_pending &&
                             !group_data_valid;
    assign group_bank = BANK_SELECT;
    assign group_session = session_reg;
    assign group_epoch = epoch_reg;
    assign group_row = desc_row_mem[desc_rd_ptr];
    assign group_index = desc_group_mem[desc_rd_ptr];
    assign group_first_k = (desc_group_mem[desc_rd_ptr] == 0);
    assign group_last_k = (desc_group_mem[desc_rd_ptr] + 1'b1 >= groups_reg);
    /* Each descriptor is one 8-channel partial-K group.  The last group may
     * be a short Cin tail; invalid bytes are masked in the two halves. */
    assign group_k_count = group_last_k ?
        ((cin_reg > (({4'd0, groups_reg} - 1'b1) << 3)) ?
         (cin_reg - (({4'd0, groups_reg} - 1'b1) << 3)) : 8'd1) : 8'd8;
    assign group_pixel_mask = pixel_mask_reg;
    assign group_cout_mask = cout_mask_reg;
    wire group_req_fire = group_req_valid && group_req_ready;

    assign all_descriptors_drained = (desc_count_reg == 0) &&
                                     !read_pending && !group_data_valid;
    assign descriptor_count = desc_count_reg;

    wire release_match = ((owner == OWNER_COMMITTED) || (owner == OWNER_PW)) &&
                         (release_bank == BANK_SELECT) &&
                         (release_session == session_reg) &&
                         (release_epoch == epoch_reg);
    assign release_ready = rst_n && release_match && all_descriptors_drained;
    wire release_fire = release_valid && release_ready;

    /* A descriptor is pushed at the group completion edge in normal mode.
     * In fence mode a small row/group counter emits the same descriptors only
     * after all writes, allowing an apples-to-apples cycle comparison. */
    wire normal_pair_push = (!FENCE_MODE) && half_fire && pair_complete;
    wire fence_pair_push = FENCE_MODE && fence_emit_active &&
                           (desc_count_reg < DESC_DEPTH);
    wire desc_push = normal_pair_push || fence_pair_push;
    wire desc_pop = group_req_fire;

    integer bi;
    integer ai;
    always @(posedge clk) begin
        if (!rst_n) begin
            owner <= OWNER_FREE;
            session_reg <= 0; epoch_reg <= 0; rows_reg <= 0; groups_reg <= 0;
            cin_reg <= 0;
            pixel_mask_reg <= 0; cout_mask_reg <= 0; target_writes <= 0;
            writes_reg <= 0; top_seen <= 0; bottom_seen <= 0;
            desc_wr_ptr <= 0; desc_rd_ptr <= 0; desc_count_reg <= 0;
            fence_emit_active <= 0; fence_emit_count <= 0;
            fence_emit_row <= 0; fence_emit_group <= 0;
            read_pending <= 0; read_row_reg <= 0; read_group_reg <= 0;
            read_session_reg <= 0; read_epoch_reg <= 0; read_first_reg <= 0;
            read_last_reg <= 0; read_k_count_reg <= 0;
            read_pixel_mask_reg <= 0; read_cout_mask_reg <= 0;
            group_data_valid <= 0; group_data <= 0; group_data_row <= 0;
            group_data_index <= 0; group_data_first_k <= 0;
            group_data_last_k <= 0; group_data_k_count <= 0;
            group_data_pixel_mask <= 0; group_data_cout_mask <= 0;
            error <= 0;
        end else begin
            if (group_data_valid && group_data_ready)
                group_data_valid <= 1'b0;

            if (acquire_fire) begin
                owner <= OWNER_DW;
                session_reg <= acquire_session;
                epoch_reg <= acquire_epoch;
                rows_reg <= acquire_rows;
                groups_reg <= acquire_groups;
                cin_reg <= acquire_cin;
                pixel_mask_reg <= acquire_pixel_mask;
                cout_mask_reg <= acquire_cout_mask;
                target_writes <= ({8'd0, acquire_rows} *
                                  {8'd0, acquire_groups}) << 1;
                writes_reg <= 0;
                top_seen <= 0; bottom_seen <= 0;
                desc_wr_ptr <= 0; desc_rd_ptr <= 0; desc_count_reg <= 0;
                fence_emit_active <= 0; fence_emit_count <= 0;
                fence_emit_row <= 0; fence_emit_group <= 0;
            end

            if (half_fire) begin
                writes_reg <= writes_reg + 1'b1;
                if (half_sel) begin
`ifndef SYNTHESIS
                    bottom_mem[BANK_ID][half_addr] <= half_data;
`endif
                    bottom_seen[half_addr] <= 1'b1;
                end else begin
`ifndef SYNTHESIS
                    top_mem[BANK_ID][half_addr] <= half_data;
`endif
                    top_seen[half_addr] <= 1'b1;
                end
                if (FENCE_MODE && (writes_reg + 1'b1 >= target_writes)) begin
                    fence_emit_active <= 1'b1;
                    fence_emit_count <= 0;
                    fence_emit_row <= 0;
                    fence_emit_group <= 0;
                end
                if (!addr_in_range || half_seen)
                    error <= 1'b1;
            end

            if (desc_push) begin
                if (normal_pair_push) begin
                    desc_row_mem[desc_wr_ptr] <= half_row;
                    desc_group_mem[desc_wr_ptr] <= half_group;
                end else begin
                    desc_row_mem[desc_wr_ptr] <= fence_emit_row;
                    desc_group_mem[desc_wr_ptr] <= fence_emit_group;
                end
                if (desc_wr_ptr == DESC_DEPTH-1)
                    desc_wr_ptr <= 0;
                else
                    desc_wr_ptr <= desc_wr_ptr + 1'b1;
            end
            if (desc_pop) begin
                if (desc_rd_ptr == DESC_DEPTH-1)
                    desc_rd_ptr <= 0;
                else
                    desc_rd_ptr <= desc_rd_ptr + 1'b1;
            end
            case ({desc_push, desc_pop})
                2'b10: desc_count_reg <= desc_count_reg + 1'b1;
                2'b01: desc_count_reg <= desc_count_reg - 1'b1;
                default: ;
            endcase

            if (fence_pair_push) begin
                if (fence_emit_count + 1'b1 >=
                    ({8'd0, rows_reg} * {8'd0, groups_reg})) begin
                    fence_emit_active <= 1'b0;
                end else begin
                    fence_emit_count <= fence_emit_count + 1'b1;
                    if (fence_emit_group + 1'b1 >= groups_reg) begin
                        fence_emit_group <= 0;
                        fence_emit_row <= fence_emit_row + 1'b1;
                    end else begin
                        fence_emit_group <= fence_emit_group + 1'b1;
                    end
                end
            end

            if (group_req_fire) begin
                read_pending <= 1'b1;
                read_row_reg <= desc_row_mem[desc_rd_ptr];
                read_group_reg <= desc_group_mem[desc_rd_ptr];
                read_session_reg <= session_reg;
                read_epoch_reg <= epoch_reg;
                read_first_reg <= (desc_group_mem[desc_rd_ptr] == 0);
                read_last_reg <=
                    (desc_group_mem[desc_rd_ptr] + 1'b1 >= groups_reg);
                read_k_count_reg <=
                    ((desc_group_mem[desc_rd_ptr] + 1'b1 >= groups_reg) ?
                     ((cin_reg > (({4'd0, groups_reg} - 1'b1) << 3)) ?
                      (cin_reg - (({4'd0, groups_reg} - 1'b1) << 3)) : 8'd1) :
                     8'd8);
                read_pixel_mask_reg <= pixel_mask_reg;
                read_cout_mask_reg <= cout_mask_reg;
            end
            if (read_pending) begin
`ifdef SYNTHESIS
                group_data <= {bottom_mem_rd_data, top_mem_rd_data};
`else
                group_data <= {bottom_mem[BANK_ID][{read_group_reg,read_row_reg}],
                               top_mem[BANK_ID][{read_group_reg,read_row_reg}]};
`endif
                group_data_row <= read_row_reg;
                group_data_index <= read_group_reg;
                group_data_first_k <= read_first_reg;
                group_data_last_k <= read_last_reg;
                group_data_k_count <= read_k_count_reg;
                group_data_pixel_mask <= read_pixel_mask_reg;
                group_data_cout_mask <= read_cout_mask_reg;
                group_data_valid <= 1'b1;
                read_pending <= 1'b0;
            end
            if (commit_fire)
                owner <= OWNER_COMMITTED;
            if (release_fire)
                owner <= OWNER_FREE;
        end
    end

    assign bank_state = owner;
`ifndef SYNTHESIS
    initial begin
        if (MAX_ROWS > 8 || MAX_GROUPS > 16 || DESC_DEPTH > 32)
            $error("group-ready scratch bounds exceed fixed prototype ABI");
    end
`endif
endmodule

`default_nettype wire
