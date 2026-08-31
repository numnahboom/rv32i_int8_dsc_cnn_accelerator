`timescale 1ns/1ps
`default_nettype none

/*
 * Native 32-bit memory response alignment/completion pipe.
 *
 * A fill_start captures one compact destination context.  Each accepted
 * issue_valid creates one in-order token (the byte destination is base+4*i)
 * and drives an aligned native-word request.  mem_rvalid may arrive at any
 * later cycle (including with arbitrary bubbles); the token FIFO, rather than
 * a fixed valid shift register, keeps the response aligned.  A second FIFO
 * makes the write command elastic when the consumer is stopped.
 *
 * word_count is the number of native 32-bit words.  Each command is therefore
 * a complete native word (byte_mask=4'b1111); a non-multiple-of-four tail is
 * represented by the final word's last flag.  byte_addr intentionally retains
 * an unaligned base so a downstream byte-lane shell can apply its own rotate.
 * mem_req_addr is always aligned down to the native 32-bit boundary.
 *
 * There is no response-ready pin on purpose: native synchronous memories are
 * expected to return every accepted request in order.  The finite combined
 * token/command capacity prevents the pipe from issuing beyond what it can
 * absorb.  A response with no outstanding token is safely discarded and
 * counted as stale.  A new fill is accepted only after the previous fill and
 * all response traffic have drained, which is the required epoch fence when
 * the memory has no response tag.
 */
module native_word_response_pipe #(
    parameter ADDR_WIDTH = 24,
    parameter EPOCH_WIDTH = 4,
    parameter FIFO_DEPTH = 32,
    parameter MEM_RD_LATENCY = 1
) (
    input wire clk,
    input wire rst_n,

    input wire fill_start_valid,
    output wire fill_start_ready,
    input wire [EPOCH_WIDTH-1:0] fill_epoch,
    input wire fill_bank,
    input wire [ADDR_WIDTH-1:0] fill_base_byte_addr,
    input wire [31:0] fill_word_count,

    input wire issue_valid,
    output wire issue_ready,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_rvalid,
    input wire [31:0] mem_rdata,

    output wire wr_valid,
    input wire wr_ready,
    output wire [EPOCH_WIDTH-1:0] wr_epoch,
    output wire wr_bank,
    output wire [ADDR_WIDTH-1:0] wr_byte_addr,
    output wire [31:0] wr_data,
    output wire [3:0] wr_byte_mask,
    output wire wr_last,

    output reg fill_done_valid,
    output reg [EPOCH_WIDTH-1:0] fill_done_epoch,
    output reg fill_done_bank,
    output reg [31:0] stale_resp_count,
    output reg [31:0] issue_count,
    output reg [31:0] response_count
);
    localparam PTR_WIDTH = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam COUNT_WIDTH = $clog2(FIFO_DEPTH + 1);

    reg fill_active;
    reg [EPOCH_WIDTH-1:0] fill_epoch_reg;
    reg fill_bank_reg;
    reg [ADDR_WIDTH-1:0] fill_base_reg;
    reg [31:0] fill_word_count_reg;
    reg [31:0] issue_index_reg;

    reg [PTR_WIDTH-1:0] tok_wr_ptr, tok_rd_ptr;
    reg [COUNT_WIDTH-1:0] tok_count;
    reg [EPOCH_WIDTH-1:0] tok_epoch [0:FIFO_DEPTH-1];
    reg tok_bank [0:FIFO_DEPTH-1];
    reg [ADDR_WIDTH-1:0] tok_byte_addr [0:FIFO_DEPTH-1];
    reg tok_last [0:FIFO_DEPTH-1];

    reg [PTR_WIDTH-1:0] cmd_wr_ptr, cmd_rd_ptr;
    reg [COUNT_WIDTH-1:0] cmd_count;
    reg [EPOCH_WIDTH-1:0] cmd_epoch [0:FIFO_DEPTH-1];
    reg cmd_bank [0:FIFO_DEPTH-1];
    reg [ADDR_WIDTH-1:0] cmd_byte_addr [0:FIFO_DEPTH-1];
    reg [31:0] cmd_data [0:FIFO_DEPTH-1];
    reg [3:0] cmd_mask [0:FIFO_DEPTH-1];
    reg cmd_last [0:FIFO_DEPTH-1];

    wire output_fire = wr_valid && wr_ready;
    wire combined_has_space = (({1'b0, tok_count} + {1'b0, cmd_count}) < FIFO_DEPTH) || output_fire;
    wire issue_fire = issue_valid && issue_ready;
    /* A response is accepted only when an issued token and command slot are
     * both present.  The invariant combined occupancy <= FIFO_DEPTH means a
     * pending token always implies a free command slot, including a
     * simultaneous output pop. */
    wire response_fire = mem_rvalid && (tok_count != 0) &&
                         ((cmd_count < FIFO_DEPTH) || output_fire);
    wire stale_response = mem_rvalid && !response_fire;

    assign fill_start_ready = !fill_active && (tok_count == 0) && (cmd_count == 0) && !fill_done_valid;
    assign issue_ready = fill_active && (issue_index_reg < fill_word_count_reg) &&
                         combined_has_space && mem_req_ready;
    assign mem_req_valid = fill_active && issue_valid && (issue_index_reg < fill_word_count_reg) &&
                           combined_has_space;
    wire [ADDR_WIDTH-1:0] issue_byte_addr = fill_base_reg + (issue_index_reg << 2);
    assign mem_req_addr = {issue_byte_addr[ADDR_WIDTH-1:2], 2'b00};

    assign wr_valid = (cmd_count != 0);
    assign wr_epoch = (cmd_count != 0) ? cmd_epoch[cmd_rd_ptr] : {EPOCH_WIDTH{1'b0}};
    assign wr_bank = (cmd_count != 0) ? cmd_bank[cmd_rd_ptr] : 1'b0;
    assign wr_byte_addr = (cmd_count != 0) ? cmd_byte_addr[cmd_rd_ptr] : {ADDR_WIDTH{1'b0}};
    assign wr_data = (cmd_count != 0) ? cmd_data[cmd_rd_ptr] : 32'b0;
    assign wr_byte_mask = (cmd_count != 0) ? cmd_mask[cmd_rd_ptr] : 4'b0;
    assign wr_last = (cmd_count != 0) ? cmd_last[cmd_rd_ptr] : 1'b0;

    function [PTR_WIDTH-1:0] ptr_next;
        input [PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == FIFO_DEPTH-1) ptr_next = {PTR_WIDTH{1'b0}};
            else ptr_next = ptr + 1'b1;
        end
    endfunction

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            fill_active <= 1'b0;
            fill_epoch_reg <= '0;
            fill_bank_reg <= 1'b0;
            fill_base_reg <= '0;
            fill_word_count_reg <= 0;
            issue_index_reg <= 0;
            tok_wr_ptr <= '0; tok_rd_ptr <= '0; tok_count <= '0;
            cmd_wr_ptr <= '0; cmd_rd_ptr <= '0; cmd_count <= '0;
            fill_done_valid <= 1'b0;
            fill_done_epoch <= '0; fill_done_bank <= 1'b0;
            stale_resp_count <= 0; issue_count <= 0; response_count <= 0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
                tok_epoch[i] <= '0; tok_bank[i] <= 1'b0; tok_byte_addr[i] <= '0; tok_last[i] <= 1'b0;
                cmd_epoch[i] <= '0; cmd_bank[i] <= 1'b0; cmd_byte_addr[i] <= '0;
                cmd_data[i] <= '0; cmd_mask[i] <= 4'b0; cmd_last[i] <= 1'b0;
            end
        end else begin
            fill_done_valid <= 1'b0;

            if (fill_start_valid && fill_start_ready) begin
                fill_active <= (fill_word_count != 0);
                fill_epoch_reg <= fill_epoch;
                fill_bank_reg <= fill_bank;
                fill_base_reg <= fill_base_byte_addr;
                fill_word_count_reg <= fill_word_count;
                issue_index_reg <= 0;
                if (fill_word_count == 0) begin
                    fill_done_valid <= 1'b1;
                    fill_done_epoch <= fill_epoch;
                    fill_done_bank <= fill_bank;
                end
            end

            if (issue_fire) begin
                tok_epoch[tok_wr_ptr] <= fill_epoch_reg;
                tok_bank[tok_wr_ptr] <= fill_bank_reg;
                tok_byte_addr[tok_wr_ptr] <= fill_base_reg + (issue_index_reg << 2);
                tok_last[tok_wr_ptr] <= (issue_index_reg + 1 >= fill_word_count_reg);
                tok_wr_ptr <= ptr_next(tok_wr_ptr);
                issue_index_reg <= issue_index_reg + 1'b1;
                issue_count <= issue_count + 1'b1;
            end

            if (response_fire) begin
                cmd_epoch[cmd_wr_ptr] <= tok_epoch[tok_rd_ptr];
                cmd_bank[cmd_wr_ptr] <= tok_bank[tok_rd_ptr];
                cmd_byte_addr[cmd_wr_ptr] <= tok_byte_addr[tok_rd_ptr];
                cmd_data[cmd_wr_ptr] <= mem_rdata;
                cmd_mask[cmd_wr_ptr] <= 4'b1111;
                cmd_last[cmd_wr_ptr] <= tok_last[tok_rd_ptr];
                cmd_wr_ptr <= ptr_next(cmd_wr_ptr);
                tok_rd_ptr <= ptr_next(tok_rd_ptr);
                response_count <= response_count + 1'b1;
            end else if (stale_response) begin
                stale_resp_count <= stale_resp_count + 1'b1;
            end

            if (output_fire) begin
                cmd_rd_ptr <= ptr_next(cmd_rd_ptr);
                if (wr_last) begin
                    fill_active <= 1'b0;
                    fill_done_valid <= 1'b1;
                    fill_done_epoch <= wr_epoch;
                    fill_done_bank <= wr_bank;
                end
            end

            case ({response_fire, output_fire})
                2'b10: cmd_count <= cmd_count + 1'b1;
                2'b01: cmd_count <= cmd_count - 1'b1;
                default: ;
            endcase
            case ({issue_fire, response_fire})
                2'b10: tok_count <= tok_count + 1'b1;
                2'b01: tok_count <= tok_count - 1'b1;
                default: ;
            endcase
        end
    end

    // Keep the latency parameter visible in elaborated designs/documentation;
    // token matching intentionally tolerates variable response latency.
    wire unused_latency = (MEM_RD_LATENCY == 0);
endmodule
`default_nettype wire
