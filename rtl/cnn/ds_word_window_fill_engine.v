`timescale 1ns/1ps
`default_nettype none

/*
 * One-source-word-at-a-time producer for ds_spatial_word_window_bank.
 *
 * The source response channel is in order and has no ready signal.  A small
 * descriptor FIFO therefore records the vector address and quarter for every
 * accepted request.  The FIFO is intentionally bounded; requests stop before
 * it fills, while responses may continue to retire at one word per clock.
 * There is only one instance of this engine in the ping-pong shell.  The
 * shell selects the destination bank at the fill command edge and never
 * changes it until the completion fence.
 */
module ds_word_window_fill_engine #(
    parameter integer ADDR_WIDTH = 24,
    parameter integer VECTOR_ADDR_WIDTH = 10,
    parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer FIFO_DEPTH = 8,
    parameter integer FIFO_PTR_WIDTH = (FIFO_DEPTH > 2) ? $clog2(FIFO_DEPTH) : 1,
    parameter integer FIFO_COUNT_WIDTH = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH+1) : 1,
    parameter integer EPOCH_WIDTH = 4
) (
    input wire clk,
    input wire rst_n,
    input wire start_valid,
    output wire start_ready,
    input wire [3:0] start_bank,
    input wire [EPOCH_WIDTH-1:0] start_epoch,
    input wire [ADDR_WIDTH-1:0] start_base_addr,
    input wire [WORD_COUNT_WIDTH-1:0] start_word_count,
    output reg done_valid,
    input wire done_ready,
    output reg done_bank,
    output reg [EPOCH_WIDTH-1:0] done_epoch,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid,
    input wire [31:0] mem_resp_data,
    output wire wr_valid,
    input wire wr_ready,
    output wire [VECTOR_ADDR_WIDTH-1:0] wr_vector_addr,
    output wire [1:0] wr_quarter,
    output wire [31:0] wr_data,
    output wire [EPOCH_WIDTH-1:0] wr_epoch,
    output reg busy,
    output reg [31:0] issue_count,
    output reg [31:0] response_count,
    output reg [31:0] write_count,
    output reg [31:0] stale_response_count
);
    reg active;
    reg selected_bank;
    reg [EPOCH_WIDTH-1:0] epoch_reg;
    reg [ADDR_WIDTH-1:0] base_addr_reg;
    reg [WORD_COUNT_WIDTH-1:0] word_count_reg;
    reg [WORD_COUNT_WIDTH-1:0] issue_index;
    reg [FIFO_PTR_WIDTH-1:0] desc_wr_ptr;
    reg [FIFO_PTR_WIDTH-1:0] desc_rd_ptr;
    reg [FIFO_COUNT_WIDTH-1:0] desc_count;
    reg [VECTOR_ADDR_WIDTH-1:0] desc_addr [0:FIFO_DEPTH-1];
    reg [1:0] desc_quarter [0:FIFO_DEPTH-1];

    wire response_available = (desc_count != 0);
    wire response_fire = mem_resp_valid && response_available && wr_ready;
    wire issue_space = (desc_count < FIFO_DEPTH) || response_fire;
    wire issue_fire = mem_req_valid && mem_req_ready;

    assign start_ready = rst_n && !active && !done_valid && (desc_count == 0);
    assign mem_req_valid = active && (issue_index < word_count_reg) && issue_space;
    assign mem_req_addr = base_addr_reg + (issue_index << 2);
    assign wr_valid = mem_resp_valid && response_available;
    assign wr_vector_addr = response_available ? desc_addr[desc_rd_ptr] : {VECTOR_ADDR_WIDTH{1'b0}};
    assign wr_quarter = response_available ? desc_quarter[desc_rd_ptr] : 2'd0;
    assign wr_data = mem_resp_data;
    assign wr_epoch = epoch_reg;

    function [FIFO_PTR_WIDTH-1:0] ptr_next;
        input [FIFO_PTR_WIDTH-1:0] ptr;
        begin
            if (ptr == FIFO_DEPTH-1) ptr_next = {FIFO_PTR_WIDTH{1'b0}};
            else ptr_next = ptr + 1'b1;
        end
    endfunction

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0;
            selected_bank <= 1'b0;
            epoch_reg <= {EPOCH_WIDTH{1'b0}};
            base_addr_reg <= {ADDR_WIDTH{1'b0}};
            word_count_reg <= {WORD_COUNT_WIDTH{1'b0}};
            issue_index <= {WORD_COUNT_WIDTH{1'b0}};
            desc_wr_ptr <= {FIFO_PTR_WIDTH{1'b0}};
            desc_rd_ptr <= {FIFO_PTR_WIDTH{1'b0}};
            desc_count <= {FIFO_COUNT_WIDTH{1'b0}};
            done_valid <= 1'b0;
            done_bank <= 1'b0;
            done_epoch <= {EPOCH_WIDTH{1'b0}};
            busy <= 1'b0;
            issue_count <= 0;
            response_count <= 0;
            write_count <= 0;
            stale_response_count <= 0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1) begin
                desc_addr[i] <= 0;
                desc_quarter[i] <= 0;
            end
        end else begin
            if (done_valid && done_ready)
                done_valid <= 1'b0;

            if (start_valid && start_ready) begin
                selected_bank <= start_bank[0];
                epoch_reg <= start_epoch;
                base_addr_reg <= {start_base_addr[ADDR_WIDTH-1:2],2'b00};
                word_count_reg <= start_word_count;
                issue_index <= 0;
                active <= (start_word_count != 0);
                busy <= (start_word_count != 0);
                if (start_word_count == 0) begin
                    done_valid <= 1'b1;
                    done_bank <= start_bank[0];
                    done_epoch <= start_epoch;
                end
            end

            if (issue_fire) begin
                desc_addr[desc_wr_ptr] <= issue_index >> 2;
                desc_quarter[desc_wr_ptr] <= issue_index[1:0];
                desc_wr_ptr <= ptr_next(desc_wr_ptr);
                issue_index <= issue_index + 1'b1;
                issue_count <= issue_count + 1'b1;
            end

            if (response_fire) begin
                desc_rd_ptr <= ptr_next(desc_rd_ptr);
                response_count <= response_count + 1'b1;
                write_count <= write_count + 1'b1;
            end else if (mem_resp_valid && !response_available) begin
                stale_response_count <= stale_response_count + 1'b1;
            end

            case ({issue_fire,response_fire})
                2'b10: desc_count <= desc_count + 1'b1;
                2'b01: desc_count <= desc_count - 1'b1;
                default: ;
            endcase

            /* Completion is deliberately one cycle after the last response.
             * This keeps the done descriptor behind every accepted write and
             * makes the bank state transition an explicit fence. */
            if (active && (issue_index >= word_count_reg) &&
                (desc_count == 0)) begin
                active <= 1'b0;
                busy <= 1'b0;
                done_valid <= 1'b1;
                done_bank <= selected_bank;
                done_epoch <= epoch_reg;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH-1)) != 0)
            $error("FIFO_DEPTH must be a power of two >= 2");
        if (VECTOR_ADDR_WIDTH < 3 || ADDR_WIDTH < 3)
            $error("address widths are too small");
    end
`endif
endmodule

`default_nettype wire
