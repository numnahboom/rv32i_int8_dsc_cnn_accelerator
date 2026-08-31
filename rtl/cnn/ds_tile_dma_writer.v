`timescale 1ns/1ps
`default_nettype none

/*
 * Registered native-word DMA writer for ds_input_tile_buffer_bram.
 *
 * A fill command describes one contiguous byte tile in a synchronous native
 * 32-bit memory.  Requests are aligned to a word boundary and an in-order
 * token records which byte lanes of each response belong to this tile.  The
 * response side is deliberately byte-serial: one selected byte is consumed
 * per clock by a small registered parser, which keeps the response-to-BRAM
 * timing cone independent of the source-word mux.  Four source bytes are
 * assembled in a registered accumulator and emitted as one 32-bit vec4
 * write.  A short final group is emitted as registered scalar writes.
 *
 * The writer owns one ds-style 128-bit input buffer.  The bank/epoch fields
 * are carried through the completion fence so a future ping-pong shell can
 * use this exact protocol without accepting a new untagged-memory epoch
 * before the old response stream has drained.
 */
module ds_tile_dma_writer #(
    parameter integer MAX_CIN = 128,
    parameter integer LAYOUT_CIN = 48,
    parameter integer MAX_IN_H = 10,
    parameter integer MAX_IN_W = 10,
    parameter integer LANES = 16,
    parameter integer ADDR_WIDTH = 24,
    parameter integer EXTENT_WIDTH = 16,
    parameter integer TOKEN_DEPTH = 8,
    parameter integer RESPONSE_DEPTH = 8,
    parameter integer COMMAND_DEPTH = 8,
    parameter integer LINEAR_ADDR_WIDTH =
        ((MAX_IN_H*MAX_IN_W*MAX_CIN + 1) > 1) ?
        $clog2(MAX_IN_H*MAX_IN_W*MAX_CIN + 1) : 1,
    parameter integer CHANNEL_TILE_WIDTH =
        ((MAX_CIN/LANES) > 1) ? $clog2(MAX_CIN/LANES) : 1
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         fill_start_valid,
    output wire                         fill_start_ready,
    input  wire                         fill_bank,
    input  wire [3:0]                   fill_epoch,
    input  wire [ADDR_WIDTH-1:0]        fill_base_byte_addr,
    input  wire [EXTENT_WIDTH-1:0]      fill_extent,

    output wire                         mem_req_valid,
    input  wire                         mem_req_ready,
    output wire [ADDR_WIDTH-1:0]        mem_req_addr,
    input  wire                         mem_resp_valid,
    input  wire [31:0]                  mem_resp_data,

    output reg                          fill_done_valid,
    input  wire                         fill_done_ready,
    output reg                          fill_done_bank,
    output reg [3:0]                    fill_done_epoch,

    input  wire                         rd_en,
    input  wire [8:0]                   rd_pixel_idx,
    input  wire [CHANNEL_TILE_WIDTH-1:0] rd_channel_tile,
    output wire                         rd_valid,
    output wire signed [(LANES*8)-1:0]  rd_data_vector,

    output reg                          busy,
    output reg [31:0]                   stale_resp_count,
    output reg [31:0]                   issue_count,
    output reg [31:0]                   response_count,
    output reg [31:0]                   write_count
);
    localparam integer TOKEN_PTR_WIDTH = (TOKEN_DEPTH <= 2) ? 1 : $clog2(TOKEN_DEPTH);
    localparam integer TOKEN_COUNT_WIDTH = (TOKEN_DEPTH <= 1) ? 1 : $clog2(TOKEN_DEPTH + 1);
    localparam integer RESPONSE_PTR_WIDTH = (RESPONSE_DEPTH <= 2) ? 1 : $clog2(RESPONSE_DEPTH);
    localparam integer RESPONSE_COUNT_WIDTH = (RESPONSE_DEPTH <= 1) ? 1 : $clog2(RESPONSE_DEPTH + 1);
    localparam integer COMMAND_PTR_WIDTH = (COMMAND_DEPTH <= 2) ? 1 : $clog2(COMMAND_DEPTH);
    localparam integer COMMAND_COUNT_WIDTH = (COMMAND_DEPTH <= 1) ? 1 : $clog2(COMMAND_DEPTH + 1);
    localparam integer GROUP_BYTES = (LAYOUT_CIN < 4) ? LAYOUT_CIN : 4;

    reg fill_active;
    reg [ADDR_WIDTH-1:0] base_aligned_reg;
    reg [1:0] base_offset_reg;
    reg [EXTENT_WIDTH-1:0] extent_reg;
    reg [31:0] word_count_reg;
    reg [31:0] issue_index_reg;
    reg [2:0] first_count_reg;
    reg [2:0] last_count_reg;
    reg [3:0] fill_epoch_reg;
    reg fill_bank_reg;

    reg [1:0] tok_first_lane [0:TOKEN_DEPTH-1];
    reg [2:0] tok_byte_count [0:TOKEN_DEPTH-1];
    reg [TOKEN_PTR_WIDTH-1:0] tok_wr_ptr, tok_rd_ptr;
    reg [TOKEN_COUNT_WIDTH-1:0] tok_count;

    reg [1:0] resp_first_lane [0:RESPONSE_DEPTH-1];
    reg [2:0] resp_byte_count [0:RESPONSE_DEPTH-1];
    reg [31:0] resp_data_mem [0:RESPONSE_DEPTH-1];
    reg [RESPONSE_PTR_WIDTH-1:0] resp_wr_ptr, resp_rd_ptr;
    reg [RESPONSE_COUNT_WIDTH-1:0] resp_count;

    /* One active response is consumed one byte per cycle. */
    reg parser_active;
    reg [31:0] parser_data_reg;
    reg [2:0] parser_lane_reg;
    reg [2:0] parser_remaining_reg;

    reg [2:0] accum_count_reg;
    reg [31:0] accum_data_reg;
    reg [LINEAR_ADDR_WIDTH-1:0] accum_linear_reg;
    reg [31:0] bytes_seen_reg;
    reg [LINEAR_ADDR_WIDTH-1:0] parser_linear_reg;
    reg [31:0] parser_row_reg;
    reg [7:0] parser_channel_reg;

    reg [2:0] tail_count_reg;
    reg [31:0] tail_data_reg;
    reg [LINEAR_ADDR_WIDTH-1:0] tail_linear_reg;

    reg cmd_vec4_mem [0:COMMAND_DEPTH-1];
    reg [LINEAR_ADDR_WIDTH-1:0] cmd_idx_mem [0:COMMAND_DEPTH-1];
    reg [31:0] cmd_data_mem [0:COMMAND_DEPTH-1];
    reg [COMMAND_PTR_WIDTH-1:0] cmd_wr_ptr, cmd_rd_ptr;
    reg [COMMAND_COUNT_WIDTH-1:0] cmd_count;

    wire cmd_out_valid = (cmd_count != 0);
    wire cmd_pop_fire = cmd_out_valid;
    wire cmd_room = (cmd_count < COMMAND_DEPTH) || cmd_pop_fire;
    wire response_fire = mem_resp_valid && (tok_count != 0);
    wire response_load_fire = (!parser_active) && (resp_count != 0);
    wire parser_byte_fire = parser_active && (tail_count_reg == 0) && cmd_room;
    wire tail_push_fire = (tail_count_reg != 0) && cmd_room;
    wire issue_fire;
    /* Keep one response slot empty.  Besides making full/empty unambiguous,
     * this prevents a same-cycle load/enqueue from reading and overwriting
     * the same distributed-RAM word when the source runs continuously. */
    wire response_room = (resp_count < (RESPONSE_DEPTH-1)) || response_load_fire;
    /* Every accepted native word eventually needs either the active parser
     * slot or a response-FIFO slot.  Since the response channel has no
     * ready signal, bound total outstanding words by those slots rather than
     * by the token FIFO alone; this makes overflow impossible even when the
     * source returns one word per cycle. */
    wire outstanding_room =
        (({1'b0, tok_count} + {1'b0, resp_count} +
          (parser_active ? 1 : 0)) < RESPONSE_DEPTH);

    assign fill_start_ready = rst_n && !fill_active && !fill_done_valid &&
                              (tok_count == 0) && (resp_count == 0) &&
                              !parser_active && (tail_count_reg == 0) &&
                              (cmd_count == 0);
    assign mem_req_valid = fill_active &&
                           (issue_index_reg < word_count_reg) &&
                           (tok_count < TOKEN_DEPTH) && response_room &&
                           outstanding_room;
    assign mem_req_addr = base_aligned_reg + (issue_index_reg << 2);
    assign issue_fire = mem_req_valid && mem_req_ready;

    wire buf_wr_vec4_en = cmd_out_valid && cmd_vec4_mem[cmd_rd_ptr];
    wire [LINEAR_ADDR_WIDTH-1:0] buf_wr_vec4_linear_idx =
        cmd_out_valid ? cmd_idx_mem[cmd_rd_ptr] : {LINEAR_ADDR_WIDTH{1'b0}};
    wire [31:0] buf_wr_vec4_data_int8 =
        cmd_out_valid ? cmd_data_mem[cmd_rd_ptr] : 32'd0;
    wire buf_wr_en = cmd_out_valid && !cmd_vec4_mem[cmd_rd_ptr];
    wire [LINEAR_ADDR_WIDTH-1:0] buf_wr_linear_idx =
        cmd_out_valid ? cmd_idx_mem[cmd_rd_ptr] : {LINEAR_ADDR_WIDTH{1'b0}};
    wire signed [7:0] buf_wr_data_int8 =
        cmd_out_valid ? cmd_data_mem[cmd_rd_ptr][7:0] : 8'sd0;

    ds_input_tile_buffer_bram #(
        .MAX_CIN(MAX_CIN), .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .LANES(LANES), .LINEAR_ADDR_WIDTH(LINEAR_ADDR_WIDTH)
    ) u_input_buffer (
        .clk(clk), .rst_n(rst_n),
        .wr_en(buf_wr_en), .wr_linear_idx(buf_wr_linear_idx),
        .wr_data_int8(buf_wr_data_int8),
        .wr_vec4_en(buf_wr_vec4_en),
        .wr_vec4_linear_idx(buf_wr_vec4_linear_idx),
        .wr_vec4_data_int8(buf_wr_vec4_data_int8),
        .rd_en(rd_en), .rd_pixel_idx(rd_pixel_idx),
        .rd_channel_tile(rd_channel_tile), .rd_valid(rd_valid),
        .rd_data_vector(rd_data_vector)
    );

    function [TOKEN_PTR_WIDTH-1:0] tok_ptr_next;
        input [TOKEN_PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == TOKEN_DEPTH-1) tok_ptr_next = '0;
            else tok_ptr_next = ptr + 1'b1;
        end
    endfunction
    function [RESPONSE_PTR_WIDTH-1:0] resp_ptr_next;
        input [RESPONSE_PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == RESPONSE_DEPTH-1) resp_ptr_next = '0;
            else resp_ptr_next = ptr + 1'b1;
        end
    endfunction
    function [COMMAND_PTR_WIDTH-1:0] cmd_ptr_next;
        input [COMMAND_PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == COMMAND_DEPTH-1) cmd_ptr_next = '0;
            else cmd_ptr_next = ptr + 1'b1;
        end
    endfunction

    reg [2:0] next_accum_count;
    reg [31:0] next_accum_data;
    reg [LINEAR_ADDR_WIDTH-1:0] next_accum_linear;
    reg [31:0] next_bytes_seen;
    reg [LINEAR_ADDR_WIDTH-1:0] next_parser_linear;
    reg [31:0] next_parser_row;
    reg [7:0] next_parser_channel;
    reg next_group_complete;
    reg next_tail_complete;
    reg [7:0] current_byte_value;
    reg [31:0] emitted_group_data;
    reg [31:0] emitted_tail_data;
    reg [2:0] emitted_tail_count;

    always @* begin
        current_byte_value = parser_data_reg[parser_lane_reg[1:0]*8 +: 8];
        next_accum_count = accum_count_reg;
        next_accum_data = accum_data_reg;
        next_accum_linear = accum_linear_reg;
        next_bytes_seen = bytes_seen_reg;
        next_parser_linear = parser_linear_reg;
        next_parser_row = parser_row_reg;
        next_parser_channel = parser_channel_reg;
        next_group_complete = 1'b0;
        next_tail_complete = 1'b0;
        emitted_group_data = 32'd0;
        emitted_tail_data = 32'd0;
        emitted_tail_count = 3'd0;
        if (parser_byte_fire) begin
            if (next_accum_count == 0) begin
                next_accum_linear = parser_linear_reg;
                next_accum_data = 0;
            end
            next_accum_data[next_accum_count*8 +: 8] = current_byte_value;
            next_accum_count = next_accum_count + 1'b1;
            next_bytes_seen = bytes_seen_reg + 1'b1;
            if (next_accum_count == GROUP_BYTES) begin
                emitted_group_data = next_accum_data;
                next_group_complete = 1'b1;
                next_accum_count = 0;
                next_accum_data = 0;
            end else if ((bytes_seen_reg + 1) >= extent_reg &&
                         (next_accum_count != 0)) begin
                emitted_tail_data = next_accum_data;
                emitted_tail_count = next_accum_count;
                next_tail_complete = 1'b1;
                next_accum_count = 0;
                next_accum_data = 0;
            end
            if (parser_channel_reg == LAYOUT_CIN-1) begin
                next_parser_channel = 0;
                next_parser_row = parser_row_reg + 1'b1;
                next_parser_linear = parser_linear_reg +
                                     (MAX_CIN - LAYOUT_CIN + 1);
            end else begin
                next_parser_channel = parser_channel_reg + 1'b1;
                next_parser_linear = parser_linear_reg + 1'b1;
            end
        end
    end

    integer i;
    integer offset_i;
    integer extent_i;
    integer first_count_i;
    integer last_count_i;
    always @(posedge clk) begin
        if (!rst_n) begin
            fill_active <= 1'b0;
            base_aligned_reg <= '0;
            base_offset_reg <= 0;
            extent_reg <= 0;
            word_count_reg <= 0;
            issue_index_reg <= 0;
            first_count_reg <= 0;
            last_count_reg <= 0;
            fill_bank_reg <= 0;
            fill_epoch_reg <= 0;
            fill_done_valid <= 1'b0;
            fill_done_bank <= 0;
            fill_done_epoch <= 0;
            tok_wr_ptr <= '0; tok_rd_ptr <= '0; tok_count <= '0;
            resp_wr_ptr <= '0; resp_rd_ptr <= '0; resp_count <= '0;
            parser_active <= 1'b0;
            parser_data_reg <= 0; parser_lane_reg <= 0;
            parser_remaining_reg <= 0;
            accum_count_reg <= 0; accum_data_reg <= 0;
            accum_linear_reg <= '0; bytes_seen_reg <= 0;
            parser_linear_reg <= '0; parser_row_reg <= 0;
            parser_channel_reg <= 0;
            tail_count_reg <= 0; tail_data_reg <= 0; tail_linear_reg <= '0;
            cmd_wr_ptr <= '0; cmd_rd_ptr <= '0; cmd_count <= '0;
            busy <= 1'b0; stale_resp_count <= 0; issue_count <= 0;
            response_count <= 0; write_count <= 0;
            for (i = 0; i < TOKEN_DEPTH; i = i + 1) begin
                tok_first_lane[i] <= 0; tok_byte_count[i] <= 0;
            end
            for (i = 0; i < RESPONSE_DEPTH; i = i + 1) begin
                resp_first_lane[i] <= 0; resp_byte_count[i] <= 0;
                resp_data_mem[i] <= 0;
            end
            for (i = 0; i < COMMAND_DEPTH; i = i + 1) begin
                cmd_vec4_mem[i] <= 0; cmd_idx_mem[i] <= 0;
                cmd_data_mem[i] <= 0;
            end
        end else begin
            if (fill_done_valid && fill_done_ready)
                fill_done_valid <= 1'b0;

            if (fill_start_valid && fill_start_ready) begin
                fill_bank_reg <= fill_bank;
                fill_epoch_reg <= fill_epoch;
                base_aligned_reg <= {fill_base_byte_addr[ADDR_WIDTH-1:2],2'b00};
                base_offset_reg <= fill_base_byte_addr[1:0];
                extent_reg <= fill_extent;
                offset_i = fill_base_byte_addr[1:0];
                extent_i = fill_extent;
                word_count_reg <= (offset_i + extent_i + 3) >> 2;
                first_count_i = extent_i;
                if (first_count_i > (4-offset_i)) first_count_i = 4-offset_i;
                if (first_count_i < 0) first_count_i = 0;
                first_count_reg <= first_count_i[2:0];
                /* Number of valid lanes in the final aligned word.  Using
                 * the inclusive final-byte offset is important for a
                 * one-byte fill at lane 3 (the old end-exclusive form
                 * incorrectly produced four lanes in that case). */
                last_count_i = (offset_i + extent_i - 1) & 3;
                if (extent_i != 0) last_count_i = last_count_i + 1;
                last_count_reg <= last_count_i[2:0];
                issue_index_reg <= 0;
                fill_active <= (fill_extent != 0);
                busy <= (fill_extent != 0);
                if (fill_extent == 0) begin
                    fill_done_valid <= 1'b1;
                    fill_done_bank <= fill_bank;
                    fill_done_epoch <= fill_epoch;
                    busy <= 1'b0;
                end
            end

            if (issue_fire) begin
                tok_first_lane[tok_wr_ptr] <=
                    (issue_index_reg == 0) ? base_offset_reg : 2'd0;
                tok_byte_count[tok_wr_ptr] <=
                    (issue_index_reg == 0) ? first_count_reg :
                    ((issue_index_reg + 1 >= word_count_reg) ?
                     last_count_reg : 3'd4);
                tok_wr_ptr <= tok_ptr_next(tok_wr_ptr);
                issue_index_reg <= issue_index_reg + 1'b1;
                issue_count <= issue_count + 1'b1;
            end

            if (response_fire) begin
                resp_first_lane[resp_wr_ptr] <= tok_first_lane[tok_rd_ptr];
                resp_byte_count[resp_wr_ptr] <= tok_byte_count[tok_rd_ptr];
                resp_data_mem[resp_wr_ptr] <= mem_resp_data;
                resp_wr_ptr <= resp_ptr_next(resp_wr_ptr);
                tok_rd_ptr <= tok_ptr_next(tok_rd_ptr);
                response_count <= response_count + 1'b1;
            end else if (mem_resp_valid) begin
                stale_resp_count <= stale_resp_count + 1'b1;
            end

            if (response_load_fire) begin
                parser_active <= 1'b1;
                parser_data_reg <= resp_data_mem[resp_rd_ptr];
                parser_lane_reg <= resp_first_lane[resp_rd_ptr];
                parser_remaining_reg <= resp_byte_count[resp_rd_ptr];
                resp_rd_ptr <= resp_ptr_next(resp_rd_ptr);
            end

            if (parser_byte_fire) begin
                accum_count_reg <= next_accum_count;
                accum_data_reg <= next_accum_data;
                accum_linear_reg <= next_accum_linear;
                bytes_seen_reg <= next_bytes_seen;
                parser_linear_reg <= next_parser_linear;
                parser_row_reg <= next_parser_row;
                parser_channel_reg <= next_parser_channel;
                if (parser_remaining_reg == 1) begin
                    parser_active <= 1'b0;
                    parser_remaining_reg <= 0;
                end else begin
                    parser_remaining_reg <= parser_remaining_reg - 1'b1;
                    parser_lane_reg <= parser_lane_reg + 1'b1;
                end
                if (next_tail_complete) begin
                    tail_count_reg <= emitted_tail_count;
                    tail_data_reg <= emitted_tail_data;
                    tail_linear_reg <= next_accum_linear;
                end
            end

            /* A complete group is enqueued on the byte that completes it. */
            if (parser_byte_fire && next_group_complete) begin
                cmd_vec4_mem[cmd_wr_ptr] <= 1'b1;
                cmd_idx_mem[cmd_wr_ptr] <= next_accum_linear;
                cmd_data_mem[cmd_wr_ptr] <= emitted_group_data;
                cmd_wr_ptr <= cmd_ptr_next(cmd_wr_ptr);
            end

            /* Emit one tail scalar command per cycle. */
            if (tail_push_fire) begin
                cmd_vec4_mem[cmd_wr_ptr] <= 1'b0;
                cmd_idx_mem[cmd_wr_ptr] <= tail_linear_reg;
                cmd_data_mem[cmd_wr_ptr] <= {24'd0,tail_data_reg[7:0]};
                cmd_wr_ptr <= cmd_ptr_next(cmd_wr_ptr);
                tail_data_reg <= tail_data_reg >> 8;
                tail_linear_reg <= tail_linear_reg + 1'b1;
                tail_count_reg <= tail_count_reg - 1'b1;
            end

            if (cmd_pop_fire) begin
                cmd_rd_ptr <= cmd_ptr_next(cmd_rd_ptr);
                write_count <= write_count + 1'b1;
            end
            case ({(tail_push_fire || (parser_byte_fire && next_group_complete)),cmd_pop_fire})
                2'b10: cmd_count <= cmd_count + 1'b1;
                2'b01: cmd_count <= cmd_count - 1'b1;
                default: ;
            endcase
            case ({response_fire,response_load_fire})
                2'b10: resp_count <= resp_count + 1'b1;
                2'b01: resp_count <= resp_count - 1'b1;
                default: ;
            endcase
            case ({issue_fire,response_fire})
                2'b10: tok_count <= tok_count + 1'b1;
                2'b01: tok_count <= tok_count - 1'b1;
                default: ;
            endcase

            if (fill_active && (issue_index_reg >= word_count_reg) &&
                (tok_count == 0) && (resp_count == 0) && !parser_active &&
                (tail_count_reg == 0) && (cmd_count == 0) &&
                (bytes_seen_reg >= extent_reg)) begin
                fill_active <= 1'b0;
                busy <= 1'b0;
                fill_done_valid <= 1'b1;
                fill_done_bank <= fill_bank_reg;
                fill_done_epoch <= fill_epoch_reg;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((MAX_CIN % LANES) != 0) $error("MAX_CIN must be a multiple of LANES");
        if (LAYOUT_CIN != 3 && LAYOUT_CIN != 16 && LAYOUT_CIN != 48)
            $error("LAYOUT_CIN must be 3, 16, or 48 for this DMA writer");
        if (LAYOUT_CIN > MAX_CIN) $error("LAYOUT_CIN exceeds MAX_CIN");
        if (MAX_IN_H < 1 || MAX_IN_W < 1) $error("tile dimensions must be positive");
        if ((TOKEN_DEPTH & (TOKEN_DEPTH-1)) != 0 ||
            (RESPONSE_DEPTH & (RESPONSE_DEPTH-1)) != 0 ||
            (COMMAND_DEPTH & (COMMAND_DEPTH-1)) != 0)
            $error("FIFO depths must be powers of two");
    end
`endif
endmodule

`default_nettype wire
