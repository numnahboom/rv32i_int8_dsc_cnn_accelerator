`timescale 1ns/1ps
`default_nettype none

/*
 * Native-word feature tile feeder.
 *
 * The external port is deliberately the same shape as feature_sram_bank's
 * synchronous word port, with an explicit request ready.  A request is
 * accepted only on mem_req_valid && mem_req_ready and its response is
 * matched through a fixed-latency registered token pipe.  Consequently this
 * module never treats a request as data, and a real synchronous SRAM may be
 * connected directly (mem_req_ready tied high, mem_resp_valid one cycle
 * after each accepted request).
 *
 * A fill owns one bank and writes its bytes while the other bank is ACTIVE.
 * A compact tile/extent/edge-mask/epoch record is captured at fill_start.
 * Once the native words have arrived, an optional row/column mask scrubber
 * overwrites invalid edge bytes with pad_value.  Interior tiles skip the
 * scrubber.  Consumption is a one-cycle synchronous byte read with a small
 * elastic response register, so consumer backpressure cannot reorder data.
 */
module feature_tile_word_feeder #(
    parameter ADDR_WIDTH = 24,
    parameter BANK_BYTES = 16384,
    parameter MEM_RD_LATENCY = 1,
    parameter TILE_ID_WIDTH = 8,
    parameter EPOCH_WIDTH = 4
) (
    input wire clk, input wire rst_n,

    input wire fill_start_valid, output wire fill_start_ready,
    input wire fill_bank,
    input wire [TILE_ID_WIDTH-1:0] fill_tile_id,
    input wire [EPOCH_WIDTH-1:0] fill_epoch,
    input wire [ADDR_WIDTH-1:0] fill_base_byte_addr,
    input wire [15:0] fill_row_stride_bytes,
    input wire [5:0] fill_tile_h, input wire [5:0] fill_tile_w,
    input wire [7:0] fill_channels,
    input wire [31:0] fill_row_valid_mask,
    input wire [31:0] fill_col_valid_mask,
    input wire [7:0] fill_pad_value,

    output reg fill_done_valid, output reg fill_done_bank,
    output reg [TILE_ID_WIDTH-1:0] fill_done_tile_id,
    output reg [EPOCH_WIDTH-1:0] fill_done_epoch,

    output wire mem_req_valid, input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid, input wire [31:0] mem_resp_data,

    input wire activate_valid, output wire activate_ready,
    input wire activate_bank,
    input wire [TILE_ID_WIDTH-1:0] activate_tile_id,
    input wire [EPOCH_WIDTH-1:0] activate_epoch,
    output wire active_bank,
    output wire [TILE_ID_WIDTH-1:0] active_tile_id,
    output wire [EPOCH_WIDTH-1:0] active_epoch,

    input wire release_valid, output wire release_ready,
    input wire release_bank,
    input wire [TILE_ID_WIDTH-1:0] release_tile_id,
    input wire [EPOCH_WIDTH-1:0] release_epoch,

    input wire consume_req_valid, output wire consume_req_ready,
    input wire [31:0] consume_byte_offset,
    output wire consume_resp_valid, input wire consume_resp_ready,
    output wire [7:0] consume_resp_data,
    output wire [TILE_ID_WIDTH-1:0] consume_resp_tile_id,
    output wire [EPOCH_WIDTH-1:0] consume_resp_epoch,
    output wire consume_resp_bank,

    output wire [1:0] bank0_state, output wire [1:0] bank1_state,
    output reg [31:0] perf_mem_issue_count,
    output reg [31:0] perf_mem_resp_count,
    output reg [31:0] perf_consume_count,
    output reg [31:0] perf_consume_stall_count
);
    localparam BANK_WORD_ADDR_WIDTH = (BANK_BYTES <= 4) ? 1 : $clog2(BANK_BYTES / 4);
    localparam S_FREE = 2'd0;
    localparam S_FILL = 2'd1;
    localparam S_READY = 2'd2;
    localparam S_ACTIVE = 2'd3;
    localparam ST_IDLE = 2'd0;
    localparam ST_FILL = 2'd1;
    localparam ST_SCRUB = 2'd2;
    localparam ST_FINISH = 2'd3;
    localparam LAT = (MEM_RD_LATENCY < 1) ? 1 : MEM_RD_LATENCY;

`ifndef SYNTHESIS
    reg [7:0] bank0_mem [0:BANK_BYTES-1];
    reg [7:0] bank1_mem [0:BANK_BYTES-1];
`endif
    reg [1:0] state0, state1;
    reg active_bank_reg;
    reg [TILE_ID_WIDTH-1:0] tile0_reg, tile1_reg;
    reg [EPOCH_WIDTH-1:0] epoch0_reg, epoch1_reg;

    reg [1:0] fill_state;
    reg fill_bank_reg;
    reg [TILE_ID_WIDTH-1:0] fill_tile_reg;
    reg [EPOCH_WIDTH-1:0] fill_epoch_reg;
    reg [ADDR_WIDTH-1:0] fill_base_reg;
    reg [15:0] fill_stride_reg;
    reg [5:0] fill_h_reg, fill_w_reg;
    reg [7:0] fill_channels_reg;
    reg [31:0] fill_row_mask_reg, fill_col_mask_reg;
    reg [7:0] fill_pad_reg;
    reg [5:0] fill_row_reg;
    reg [31:0] fill_row_src_reg;
    reg [31:0] fill_row_dst_reg;
    reg [31:0] fill_row_bytes_reg;
    reg [31:0] fill_row_word_idx_reg, fill_row_word_count_reg;
    reg [31:0] scrub_index_reg, scrub_total_reg;
    reg scrub_needed_reg;
    reg [5:0] scrub_y_reg, scrub_x_reg;
    reg [7:0] scrub_c_reg;
    // ST_FINISH is held until the registered command and lane-memory write
    // stages have drained the final response/scrub byte.
    reg finish_wait_reg;

    reg pipe_valid [0:LAT-1];
    reg [31:0] pipe_dst_base [0:LAT-1];
    reg pipe_dst_valid [0:LAT-1];
    reg [3:0] pipe_byte_mask [0:LAT-1];
    reg pipe_last [0:LAT-1];
    reg [1:0] pipe_end_mod [0:LAT-1];
    reg [31:0] pipe_row_dst_base [0:LAT-1];
    reg [31:0] pipe_row_bytes [0:LAT-1];
    integer pi;
    integer li;
    integer dst_i;
    integer scrub_y_i, scrub_x_i, scrub_c_i;
    reg [31:0] issue_row_addr;
    reg [31:0] issue_aligned_addr;
    reg signed [31:0] issue_local;
    reg signed [31:0] issue_dst;
    reg [31:0] issue_last_addr;
    reg [3:0] issue_byte_mask;
    reg [1:0] issue_end_mod;
    reg [31:0] consume_byte_i;
    reg consume_fire;
    reg fill_fire;
    reg activate_fire;
    reg release_fire;
    reg resp_fire;

    assign bank0_state = state0;
    assign bank1_state = state1;
    assign active_bank = active_bank_reg;
    assign active_tile_id = active_bank_reg ? tile1_reg : tile0_reg;
    assign active_epoch = active_bank_reg ? epoch1_reg : epoch0_reg;

    assign fill_start_ready = (fill_state == ST_IDLE) &&
                              (fill_bank ? (state1 == S_FREE) : (state0 == S_FREE));
    assign activate_ready = !consume_resp_valid &&
        (activate_bank ? (state1 == S_READY && tile1_reg == activate_tile_id && epoch1_reg == activate_epoch) :
                         (state0 == S_READY && tile0_reg == activate_tile_id && epoch0_reg == activate_epoch));
    assign release_ready = (release_bank != active_bank_reg) &&
        (release_bank ? (state1 == S_ACTIVE && tile1_reg == release_tile_id && epoch1_reg == release_epoch) :
                        (state0 == S_ACTIVE && tile0_reg == release_tile_id && epoch0_reg == release_epoch));
    assign consume_req_ready = (active_bank_reg ? (state1 == S_ACTIVE) : (state0 == S_ACTIVE)) &&
                                (!consume_resp_valid || consume_resp_ready);

    assign mem_req_valid = (fill_state == ST_FILL) &&
                           (fill_row_word_idx_reg < fill_row_word_count_reg);
    assign mem_req_addr = issue_aligned_addr[ADDR_WIDTH-1:0];

    reg consume_valid_reg;
    reg [7:0] consume_data_reg;
    reg [TILE_ID_WIDTH-1:0] consume_tile_reg;
    reg [EPOCH_WIDTH-1:0] consume_epoch_reg;
    reg consume_bank_reg;
    reg [31:0] consume_addr_reg;
    reg consume_pending_reg;
    wire [7:0] consume_lane_data0 [0:3];
    wire [7:0] consume_lane_data1 [0:3];
    wire [BANK_WORD_ADDR_WIDTH-1:0] consume_word_addr = consume_addr_reg >> 2;
    wire [7:0] consume_mem_data = consume_bank_reg ?
        consume_lane_data1[consume_addr_reg[1:0]] : consume_lane_data0[consume_addr_reg[1:0]];
    reg [BANK_WORD_ADDR_WIDTH-1:0] bank_wr_addr0 [0:3];
    reg [BANK_WORD_ADDR_WIDTH-1:0] bank_wr_addr1 [0:3];
    reg [7:0] bank_wr_data0 [0:3];
    reg [7:0] bank_wr_data1 [0:3];
    reg bank_wr_en0 [0:3];
    reg bank_wr_en1 [0:3];
    reg [BANK_WORD_ADDR_WIDTH-1:0] bank_wr_addr0_q [0:3];
    reg [BANK_WORD_ADDR_WIDTH-1:0] bank_wr_addr1_q [0:3];
    reg [7:0] bank_wr_data0_q [0:3];
    reg [7:0] bank_wr_data1_q [0:3];
    reg bank_wr_en0_q [0:3];
    reg bank_wr_en1_q [0:3];
    // Decoded response command stage.  This stage is intentionally separate
    // from the lane-memory write register: destination-byte decode and bank
    // selection terminate here, while the XPM CE/WE sees only registered
    // point-to-point commands.
    reg [3:0] resp_cmd_en0_vec, resp_cmd_en1_vec;
    reg [4*BANK_WORD_ADDR_WIDTH-1:0] resp_cmd_addr0_vec, resp_cmd_addr1_vec;
    reg [31:0] resp_cmd_data0_vec, resp_cmd_data1_vec;
    wire [3:0] resp_source_mask = pipe_byte_mask[LAT-1] &
        (pipe_last[LAT-1] ?
         ((pipe_end_mod[LAT-1] == 2'd0) ? 4'b1111 :
          (pipe_end_mod[LAT-1] == 2'd1) ? 4'b0001 :
          (pipe_end_mod[LAT-1] == 2'd2) ? 4'b0011 : 4'b0111) : 4'b1111);
    // Byte lanes rotate according to the two low destination bits.  This
    // packed form lets the registered command stage capture all four writes
    // without a variable-index procedural assignment or a wide adder tree.
    function [3:0] rotate_mask;
        input [3:0] source_mask;
        input [1:0] base_lane;
        begin
            case (base_lane)
                2'd0: rotate_mask = source_mask;
                2'd1: rotate_mask = {source_mask[2:0], source_mask[3]};
                2'd2: rotate_mask = {source_mask[1:0], source_mask[3:2]};
                default: rotate_mask = {source_mask[0], source_mask[3:1]};
            endcase
        end
    endfunction
    function [31:0] rotate_data;
        input [31:0] source_data;
        input [1:0] base_lane;
        begin
            case (base_lane)
                2'd0: rotate_data = source_data;
                2'd1: rotate_data = {source_data[23:16], source_data[15:8], source_data[7:0], source_data[31:24]};
                2'd2: rotate_data = {source_data[15:8], source_data[7:0], source_data[31:24], source_data[23:16]};
                default: rotate_data = {source_data[7:0], source_data[31:24], source_data[23:16], source_data[15:8]};
            endcase
        end
    endfunction
    wire [3:0] resp_rot_mask = rotate_mask(resp_source_mask, pipe_dst_base[LAT-1][1:0]);
    wire [31:0] resp_rot_data = rotate_data(mem_resp_data, pipe_dst_base[LAT-1][1:0]);
    wire [BANK_WORD_ADDR_WIDTH-1:0] resp_word_base = pipe_dst_base[LAT-1] >> 2;
    reg [4*BANK_WORD_ADDR_WIDTH-1:0] resp_addr_vector;
    always @(*) begin
        resp_addr_vector = {4{resp_word_base}};
        case (pipe_dst_base[LAT-1][1:0])
            2'd1: resp_addr_vector[0*BANK_WORD_ADDR_WIDTH +: BANK_WORD_ADDR_WIDTH] = resp_word_base + 1'b1;
            2'd2: begin
                resp_addr_vector[0*BANK_WORD_ADDR_WIDTH +: BANK_WORD_ADDR_WIDTH] = resp_word_base + 1'b1;
                resp_addr_vector[1*BANK_WORD_ADDR_WIDTH +: BANK_WORD_ADDR_WIDTH] = resp_word_base + 1'b1;
            end
            2'd3: begin
                resp_addr_vector[0*BANK_WORD_ADDR_WIDTH +: BANK_WORD_ADDR_WIDTH] = resp_word_base + 1'b1;
                resp_addr_vector[1*BANK_WORD_ADDR_WIDTH +: BANK_WORD_ADDR_WIDTH] = resp_word_base + 1'b1;
                resp_addr_vector[2*BANK_WORD_ADDR_WIDTH +: BANK_WORD_ADDR_WIDTH] = resp_word_base + 1'b1;
            end
            default: ;
        endcase
    end
    reg [BANK_WORD_ADDR_WIDTH-1:0] scrub_word_addr;
    reg [1:0] scrub_lane_addr;
    reg [7:0] scrub_data;
    integer wi;
    integer wr_byte_i;
    assign consume_resp_valid = consume_valid_reg;
    assign consume_resp_data = consume_mem_data;
    assign consume_resp_tile_id = consume_tile_reg;
    assign consume_resp_epoch = consume_epoch_reg;
    assign consume_resp_bank = consume_bank_reg;

    /* Each physical byte lane is an independent single-write/single-read
     * RAM.  Four consecutive response bytes therefore remain one write per
     * RAM even when the source word is unaligned. */
    always @(*) begin
        for (wi = 0; wi < 4; wi = wi + 1) begin
            bank_wr_en0[wi] = 1'b0; bank_wr_en1[wi] = 1'b0;
            bank_wr_addr0[wi] = 0; bank_wr_addr1[wi] = 0;
            bank_wr_data0[wi] = 0; bank_wr_data1[wi] = 0;
        end
        for (wi = 0; wi < 4; wi = wi + 1) begin
            bank_wr_en0[wi] = resp_cmd_en0_vec[wi]; bank_wr_en1[wi] = resp_cmd_en1_vec[wi];
            bank_wr_addr0[wi] = resp_cmd_addr0_vec[wi*BANK_WORD_ADDR_WIDTH +: BANK_WORD_ADDR_WIDTH];
            bank_wr_addr1[wi] = resp_cmd_addr1_vec[wi*BANK_WORD_ADDR_WIDTH +: BANK_WORD_ADDR_WIDTH];
            bank_wr_data0[wi] = resp_cmd_data0_vec[wi*8 +: 8];
            bank_wr_data1[wi] = resp_cmd_data1_vec[wi*8 +: 8];
        end
        if (fill_state == ST_SCRUB) begin
            if (!fill_row_mask_reg[scrub_y_reg] || !fill_col_mask_reg[scrub_x_reg]) begin
                scrub_word_addr = scrub_index_reg >> 2;
                scrub_lane_addr = scrub_index_reg[1:0];
                scrub_data = fill_pad_reg;
                if (fill_bank_reg) begin bank_wr_en1[scrub_lane_addr] = 1'b1; bank_wr_addr1[scrub_lane_addr] = scrub_word_addr; bank_wr_data1[scrub_lane_addr] = scrub_data; end
                else begin bank_wr_en0[scrub_lane_addr] = 1'b1; bank_wr_addr0[scrub_lane_addr] = scrub_word_addr; bank_wr_data0[scrub_lane_addr] = scrub_data; end
            end
        end
    end

    genvar lane_mem;
    generate for (lane_mem = 0; lane_mem < 4; lane_mem = lane_mem + 1) begin : gen_lane_mem
`ifdef SYNTHESIS
        xpm_memory_sdpram #(.ADDR_WIDTH_A(BANK_WORD_ADDR_WIDTH), .ADDR_WIDTH_B(BANK_WORD_ADDR_WIDTH),
          .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8), .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
          .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(BANK_BYTES*2), .MESSAGE_CONTROL(0),
          .READ_DATA_WIDTH_B(8), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
          .WRITE_DATA_WIDTH_A(8), .WRITE_MODE_B("read_first")) b0 (
          .clka(clk), .ena(bank_wr_en0_q[lane_mem]), .wea(bank_wr_en0_q[lane_mem]), .addra(bank_wr_addr0_q[lane_mem]), .dina(bank_wr_data0_q[lane_mem]),
          .injectsbiterra(1'b0), .injectdbiterra(1'b0), .sleep(1'b0), .clkb(clk), .rstb(!rst_n), .enb(1'b1), .regceb(1'b1), .addrb(consume_word_addr), .doutb(consume_lane_data0[lane_mem]), .sbiterrb(), .dbiterrb());
        xpm_memory_sdpram #(.ADDR_WIDTH_A(BANK_WORD_ADDR_WIDTH), .ADDR_WIDTH_B(BANK_WORD_ADDR_WIDTH),
          .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(8), .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
          .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"), .MEMORY_OPTIMIZATION("true"),
          .MEMORY_PRIMITIVE("block"), .MEMORY_SIZE(BANK_BYTES*2), .MESSAGE_CONTROL(0),
          .READ_DATA_WIDTH_B(8), .READ_LATENCY_B(1), .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
          .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0), .WAKEUP_TIME("disable_sleep"),
          .WRITE_DATA_WIDTH_A(8), .WRITE_MODE_B("read_first")) b1 (
          .clka(clk), .ena(bank_wr_en1_q[lane_mem]), .wea(bank_wr_en1_q[lane_mem]), .addra(bank_wr_addr1_q[lane_mem]), .dina(bank_wr_data1_q[lane_mem]),
          .injectsbiterra(1'b0), .injectdbiterra(1'b0), .sleep(1'b0), .clkb(clk), .rstb(!rst_n), .enb(1'b1), .regceb(1'b1), .addrb(consume_word_addr), .doutb(consume_lane_data1[lane_mem]), .sbiterrb(), .dbiterrb());
`else
        reg [7:0] lane0_mem [0:BANK_BYTES/4-1];
        reg [7:0] lane1_mem [0:BANK_BYTES/4-1];
        reg [7:0] lane0_rd, lane1_rd;
        assign consume_lane_data0[lane_mem] = lane0_rd;
        assign consume_lane_data1[lane_mem] = lane1_rd;
        always @(posedge clk) begin
          if (bank_wr_en0_q[lane_mem]) lane0_mem[bank_wr_addr0_q[lane_mem]] <= bank_wr_data0_q[lane_mem];
          if (bank_wr_en1_q[lane_mem]) lane1_mem[bank_wr_addr1_q[lane_mem]] <= bank_wr_data1_q[lane_mem];
          lane0_rd <= lane0_mem[consume_word_addr]; lane1_rd <= lane1_mem[consume_word_addr];
        end
`endif
    end endgenerate

    /* Word issue address and destination.  The first word of each row may
     * begin before the row's byte address; response-lane validity clips that
     * prefix/suffix without any alignment assumption. */
    always @(*) begin
        issue_row_addr = fill_base_reg + fill_row_src_reg;
        issue_aligned_addr = {issue_row_addr[31:2], 2'b00} +
                             (fill_row_word_idx_reg * 32'd4);
        issue_local = issue_aligned_addr - issue_row_addr;
        issue_dst = fill_row_dst_reg + issue_local;
        issue_last_addr = issue_row_addr + fill_row_bytes_reg - 1;
        issue_byte_mask = 4'b1111;
        issue_end_mod = issue_row_addr[1:0] + fill_row_bytes_reg[1:0];
        if (fill_row_word_idx_reg == 0) begin
            case (issue_row_addr[1:0])
                2'd0: issue_byte_mask = 4'b1111;
                2'd1: issue_byte_mask = 4'b1110;
                2'd2: issue_byte_mask = 4'b1100;
                default: issue_byte_mask = 4'b1000;
            endcase
        end
    end

    always @(*) begin
        fill_fire = fill_start_valid && fill_start_ready;
        activate_fire = activate_valid && activate_ready;
        release_fire = release_valid && release_ready;
        consume_fire = consume_req_valid && consume_req_ready;
        resp_fire = mem_resp_valid && pipe_valid[LAT-1];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state0 <= S_FREE; state1 <= S_FREE;
            active_bank_reg <= 1'b0;
            tile0_reg <= '0; tile1_reg <= '0;
            epoch0_reg <= '0; epoch1_reg <= '0;
            fill_state <= ST_IDLE;
            fill_bank_reg <= 1'b0; fill_tile_reg <= '0; fill_epoch_reg <= '0;
            fill_base_reg <= '0; fill_stride_reg <= '0;
            fill_h_reg <= '0; fill_w_reg <= '0; fill_channels_reg <= '0;
            fill_row_mask_reg <= '0; fill_col_mask_reg <= '0; fill_pad_reg <= '0;
            fill_row_reg <= '0; fill_row_src_reg <= '0; fill_row_dst_reg <= '0;
            fill_row_bytes_reg <= '0; fill_row_word_idx_reg <= '0;
            fill_row_word_count_reg <= '0;
            scrub_index_reg <= '0; scrub_total_reg <= '0; scrub_needed_reg <= 1'b0;
            scrub_y_reg <= 0; scrub_x_reg <= 0; scrub_c_reg <= 0;
            fill_done_valid <= 1'b0; fill_done_bank <= 1'b0;
            fill_done_tile_id <= '0; fill_done_epoch <= '0;
            consume_valid_reg <= 1'b0; consume_data_reg <= '0;
            consume_tile_reg <= '0; consume_epoch_reg <= '0; consume_bank_reg <= 1'b0;
            consume_addr_reg <= 0; consume_pending_reg <= 1'b0;
            perf_mem_issue_count <= 0; perf_mem_resp_count <= 0;
            perf_consume_count <= 0; perf_consume_stall_count <= 0;
            finish_wait_reg <= 1'b0;
            resp_cmd_en0_vec <= 4'b0; resp_cmd_en1_vec <= 4'b0;
            resp_cmd_addr0_vec <= '0; resp_cmd_addr1_vec <= '0;
            resp_cmd_data0_vec <= 32'b0; resp_cmd_data1_vec <= 32'b0;
            for (pi = 0; pi < LAT; pi = pi + 1) begin
                pipe_valid[pi] <= 1'b0;
                pipe_dst_base[pi] <= 0;
                pipe_dst_valid[pi] <= 1'b0;
                pipe_byte_mask[pi] <= 4'b0;
                pipe_last[pi] <= 1'b0;
                pipe_end_mod[pi] <= 0;
                pipe_row_dst_base[pi] <= 0;
                pipe_row_bytes[pi] <= 0;
            end
            for (wi = 0; wi < 4; wi = wi + 1) begin
                bank_wr_en0_q[wi] <= 1'b0; bank_wr_en1_q[wi] <= 1'b0;
                bank_wr_addr0_q[wi] <= 0; bank_wr_addr1_q[wi] <= 0;
                bank_wr_data0_q[wi] <= 0; bank_wr_data1_q[wi] <= 0;
            end
        end else begin
            fill_done_valid <= 1'b0;
            // The decode stage is a one-cycle command record.  Clearing the
            // enables here permits a response every cycle while preserving
            // the prior command long enough for bank_wr_*_q to capture it.
            resp_cmd_en0_vec <= 4'b0; resp_cmd_en1_vec <= 4'b0;
            for (wi = 0; wi < 4; wi = wi + 1) begin
                bank_wr_en0_q[wi] <= bank_wr_en0[wi]; bank_wr_en1_q[wi] <= bank_wr_en1[wi];
                bank_wr_addr0_q[wi] <= bank_wr_addr0[wi]; bank_wr_addr1_q[wi] <= bank_wr_addr1[wi];
                bank_wr_data0_q[wi] <= bank_wr_data0[wi]; bank_wr_data1_q[wi] <= bank_wr_data1[wi];
            end
            // Shift the fixed-latency response alignment pipe every cycle.
            for (pi = LAT-1; pi > 0; pi = pi - 1) begin
                pipe_valid[pi] <= pipe_valid[pi-1];
                pipe_dst_base[pi] <= pipe_dst_base[pi-1];
                pipe_dst_valid[pi] <= pipe_dst_valid[pi-1];
                pipe_byte_mask[pi] <= pipe_byte_mask[pi-1];
                pipe_last[pi] <= pipe_last[pi-1];
                pipe_end_mod[pi] <= pipe_end_mod[pi-1];
                pipe_row_dst_base[pi] <= pipe_row_dst_base[pi-1];
                pipe_row_bytes[pi] <= pipe_row_bytes[pi-1];
            end
            pipe_valid[0] <= mem_req_valid && mem_req_ready;
            pipe_dst_base[0] <= issue_dst;
            // Per-lane row clipping below handles unaligned prefix/suffix;
            // no source-address arithmetic is needed on this registered
            // control bit.
            pipe_dst_valid[0] <= 1'b1;
            pipe_byte_mask[0] <= issue_byte_mask;
            pipe_last[0] <= (fill_row_reg + 1 >= fill_h_reg) &&
                            ((fill_row_word_idx_reg[BANK_WORD_ADDR_WIDTH:0] + 1'b1) >=
                             fill_row_word_count_reg[BANK_WORD_ADDR_WIDTH:0]);
            pipe_end_mod[0] <= issue_end_mod;
            pipe_row_dst_base[0] <= fill_row_dst_reg;
            pipe_row_bytes[0] <= fill_row_bytes_reg;

            consume_valid_reg <= consume_pending_reg;
            consume_pending_reg <= 1'b0;
            if (consume_resp_valid && consume_resp_ready)
                consume_valid_reg <= 1'b0;
            if (consume_fire) begin
                consume_pending_reg <= 1'b1;
                consume_addr_reg <= consume_byte_offset;
                consume_tile_reg <= active_bank_reg ? tile1_reg : tile0_reg;
                consume_epoch_reg <= active_bank_reg ? epoch1_reg : epoch0_reg;
                consume_bank_reg <= active_bank_reg;
                perf_consume_count <= perf_consume_count + 1;
            end else if ((consume_req_valid && !consume_req_ready) ||
                         (consume_resp_valid && !consume_resp_ready))
                perf_consume_stall_count <= perf_consume_stall_count + 1;

            if (fill_fire) begin
                fill_bank_reg <= fill_bank;
                fill_tile_reg <= fill_tile_id;
                fill_epoch_reg <= fill_epoch;
                fill_base_reg <= fill_base_byte_addr;
                fill_stride_reg <= fill_row_stride_bytes;
                fill_h_reg <= fill_tile_h;
                fill_w_reg <= fill_tile_w;
                fill_channels_reg <= fill_channels;
                fill_row_mask_reg <= fill_row_valid_mask;
                fill_col_mask_reg <= fill_col_valid_mask;
                fill_pad_reg <= fill_pad_value;
                scrub_needed_reg <= (fill_row_valid_mask != {32{1'b1}}) ||
                                    (fill_col_valid_mask != {32{1'b1}});
                fill_row_reg <= 0;
                fill_row_src_reg <= 0;
                fill_row_dst_reg <= 0;
                fill_row_bytes_reg <= {27'd0, fill_tile_w} * {24'd0, fill_channels};
                fill_row_word_idx_reg <= 0;
                fill_row_word_count_reg <= ((fill_base_byte_addr[1:0] +
                                              ({27'd0, fill_tile_w} * {24'd0, fill_channels}) + 3) >> 2);
                finish_wait_reg <= 1'b0;
                fill_state <= ST_FILL;
                if (fill_bank) begin state1 <= S_FILL; tile1_reg <= fill_tile_id; epoch1_reg <= fill_epoch; end
                else begin state0 <= S_FILL; tile0_reg <= fill_tile_id; epoch0_reg <= fill_epoch; end
            end

            if (mem_req_valid && mem_req_ready) begin
                perf_mem_issue_count <= perf_mem_issue_count + 1;
                if (fill_row_word_idx_reg + 1 >= fill_row_word_count_reg) begin
                    fill_row_word_idx_reg <= 0;
                    if (fill_row_reg + 1 < fill_h_reg) begin
                        fill_row_reg <= fill_row_reg + 1;
                        fill_row_src_reg <= fill_row_src_reg + fill_stride_reg;
                        fill_row_dst_reg <= fill_row_dst_reg + fill_row_bytes_reg;
                        fill_row_word_count_reg <=
                            (((fill_base_reg + fill_row_src_reg + fill_stride_reg) & 32'd3) +
                             fill_row_bytes_reg + 3) >> 2;
                    end
                end else begin
                    fill_row_word_idx_reg <= fill_row_word_idx_reg + 1;
                end
            end

            if (resp_fire) begin
                perf_mem_resp_count <= perf_mem_resp_count + 1;
                // Capture one complete four-lane command every response
                // cycle.  The packed rotation preserves one write per byte
                // RAM and does not serialize unaligned responses.
                if (fill_bank_reg) begin
                    resp_cmd_en1_vec <= resp_rot_mask;
                    resp_cmd_addr1_vec <= resp_addr_vector;
                    resp_cmd_data1_vec <= resp_rot_data;
                end else begin
                    resp_cmd_en0_vec <= resp_rot_mask;
                    resp_cmd_addr0_vec <= resp_addr_vector;
                    resp_cmd_data0_vec <= resp_rot_data;
                end
`ifndef SYNTHESIS
                for (li = 0; li < 4; li = li + 1) begin
                    dst_i = pipe_dst_base[LAT-1] + li;
                    if (pipe_dst_valid[LAT-1] && dst_i >= pipe_row_dst_base[LAT-1] &&
                        dst_i < pipe_row_dst_base[LAT-1] + pipe_row_bytes[LAT-1] &&
                        dst_i < BANK_BYTES) begin
                        if (fill_bank_reg) bank1_mem[dst_i] <= mem_resp_data[(li*8) +: 8];
                        else bank0_mem[dst_i] <= mem_resp_data[(li*8) +: 8];
                    end
                end
`endif
                if (pipe_last[LAT-1]) begin
                    if (scrub_needed_reg) begin
                        fill_state <= ST_SCRUB;
                        scrub_index_reg <= 0;
                        scrub_total_reg <= fill_h_reg * fill_row_bytes_reg;
                        scrub_y_reg <= 0; scrub_x_reg <= 0; scrub_c_reg <= 0;
                    end else begin
                        finish_wait_reg <= 1'b1;
                        fill_state <= ST_FINISH;
                    end
                end
            end

            if (fill_state == ST_SCRUB) begin
`ifndef SYNTHESIS
                if (!fill_row_mask_reg[scrub_y_reg] || !fill_col_mask_reg[scrub_x_reg]) begin
                    if (fill_bank_reg) bank1_mem[scrub_index_reg] <= fill_pad_reg;
                    else bank0_mem[scrub_index_reg] <= fill_pad_reg;
                end
`endif
                if (scrub_index_reg + 1 >= scrub_total_reg) begin
                    finish_wait_reg <= 1'b1;
                    fill_state <= ST_FINISH;
                end
                else begin
                    scrub_index_reg <= scrub_index_reg + 1;
                    if (scrub_c_reg + 1 >= fill_channels_reg) begin
                        scrub_c_reg <= 0;
                        if (scrub_x_reg + 1 >= fill_w_reg) begin
                            scrub_x_reg <= 0;
                            scrub_y_reg <= scrub_y_reg + 1;
                        end else scrub_x_reg <= scrub_x_reg + 1;
                    end else scrub_c_reg <= scrub_c_reg + 1;
                end
            end

            if (fill_state == ST_FINISH) begin
                if (finish_wait_reg) begin
                    finish_wait_reg <= 1'b0;
                end else begin
                    fill_state <= ST_IDLE;
                    fill_done_valid <= 1'b1;
                    fill_done_bank <= fill_bank_reg;
                    fill_done_tile_id <= fill_tile_reg;
                    fill_done_epoch <= fill_epoch_reg;
                    if (fill_bank_reg) state1 <= S_READY; else state0 <= S_READY;
                end
            end

            if (activate_fire) begin
                active_bank_reg <= activate_bank;
                if (activate_bank) state1 <= S_ACTIVE; else state0 <= S_ACTIVE;
            end
            if (release_fire) begin
                if (release_bank) state1 <= S_FREE; else state0 <= S_FREE;
            end
        end
    end

endmodule

`default_nettype wire
