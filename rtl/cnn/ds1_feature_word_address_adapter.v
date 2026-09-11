`timescale 1ns/1ps
`default_nettype none

/*
 * Pixel-major DS1 feature source adapter for the 4x8 DW producer.
 *
 * The word-window fill engine sees one linear footprint at a time.  DS1
 * storage is pixel-major (16 signed bytes per pixel), so this block translates
 * each accepted footprint word to the corresponding global source pixel and
 * returns padding in the same ordered response stream.  Context is changed
 * only at a fill completion fence; physical responses therefore cannot be
 * associated with the next macro.
 */
module ds1_feature_word_address_adapter #(
    parameter integer ADDR_WIDTH = 24,
    parameter integer FIFO_DEPTH = 8,
    parameter integer FOOTPRINT_HEIGHT = 6,
    parameter integer FOOTPRINT_WIDTH = 10,
    parameter integer GLOBAL_HEIGHT = 32,
    parameter integer GLOBAL_WIDTH = 32,
    parameter integer CHANNELS = 16,
    parameter integer PTR_WIDTH = (FIFO_DEPTH > 2) ? $clog2(FIFO_DEPTH) : 1,
    parameter integer COUNT_WIDTH = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH+1) : 1
) (
    input wire clk,
    input wire rst_n,

    input wire context_valid,
    output wire context_ready,
    input wire [ADDR_WIDTH-1:0] context_linear_base,
    input wire [ADDR_WIDTH-1:0] context_input_base,
    input wire [5:0] context_global_y,
    input wire [5:0] context_global_x,
    input wire [7:0] context_input_zero_point,
    input wire context_complete,

    input wire producer_req_valid,
    output wire producer_req_ready,
    input wire [ADDR_WIDTH-1:0] producer_req_addr,
    output wire producer_resp_valid,
    output wire [31:0] producer_resp_data,

    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid,
    input wire [31:0] mem_resp_data,
    output reg error
);
    reg context_active;
    reg [ADDR_WIDTH-1:0] linear_base_reg, input_base_reg;
    reg [5:0] global_y_reg, global_x_reg;
    reg [7:0] zero_point_reg;
    reg [PTR_WIDTH-1:0] wr_ptr, rd_ptr;
    reg [COUNT_WIDTH-1:0] fifo_count;
    reg padding_fifo [0:FIFO_DEPTH-1];

    wire fifo_empty = (fifo_count == 0);
    wire fifo_full = (fifo_count == FIFO_DEPTH);
    wire head_padding = !fifo_empty && padding_fifo[rd_ptr];
    wire [ADDR_WIDTH-1:0] producer_offset = producer_req_addr - linear_base_reg;
    wire [31:0] fill_word_index = producer_offset >> 2;
    wire [31:0] fill_pixel = fill_word_index >> 2;
    wire [31:0] fill_q = fill_word_index[1:0];
    wire [31:0] fill_sy = fill_pixel / FOOTPRINT_WIDTH;
    wire [31:0] fill_sx = fill_pixel % FOOTPRINT_WIDTH;
    wire signed [32:0] source_y = $signed({1'b0,global_y_reg}) - 1 +
                                   $signed({1'b0,fill_sy[7:0]});
    wire signed [32:0] source_x = $signed({1'b0,global_x_reg}) - 1 +
                                   $signed({1'b0,fill_sx[7:0]});
    wire mapped_padding = (fill_word_index >= (FOOTPRINT_HEIGHT*FOOTPRINT_WIDTH*4)) ||
                          (source_y < 0) || (source_y >= GLOBAL_HEIGHT) ||
                          (source_x < 0) || (source_x >= GLOBAL_WIDTH);
    wire [31:0] source_pixel = (source_y * GLOBAL_WIDTH) + source_x;
    wire [ADDR_WIDTH-1:0] mapped_addr = input_base_reg +
        (source_pixel * CHANNELS) + (fill_q << 2);
    wire request_allowed = context_active && !fifo_full &&
                           (mapped_padding || mem_req_ready);
    wire producer_request_fire = producer_req_valid && producer_req_ready;
    wire response_fire = producer_resp_valid;
    wire [31:0] padding_data = {4{zero_point_reg}};

    assign context_ready = rst_n && (!context_active ||
        (context_complete && fifo_empty));
    assign producer_req_ready = request_allowed;
    assign mem_req_valid = producer_req_valid && !mapped_padding && request_allowed;
    assign mem_req_addr = mapped_addr;
    assign producer_resp_valid = !fifo_empty && (head_padding || mem_resp_valid);
    assign producer_resp_data = head_padding ? padding_data : mem_resp_data;

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
            context_active <= 1'b0;
            linear_base_reg <= 0;
            input_base_reg <= 0;
            global_y_reg <= 0;
            global_x_reg <= 0;
            zero_point_reg <= 0;
            wr_ptr <= 0;
            rd_ptr <= 0;
            fifo_count <= 0;
            error <= 1'b0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1)
                padding_fifo[i] <= 1'b0;
        end else begin
            if (context_valid && context_ready) begin
                context_active <= 1'b1;
                linear_base_reg <= context_linear_base;
                input_base_reg <= context_input_base;
                global_y_reg <= context_global_y;
                global_x_reg <= context_global_x;
                zero_point_reg <= context_input_zero_point;
            end else if (context_complete && fifo_empty) begin
                context_active <= 1'b0;
            end

            if (producer_request_fire) begin
                padding_fifo[wr_ptr] <= mapped_padding;
                wr_ptr <= ptr_next(wr_ptr);
            end
            if (response_fire)
                rd_ptr <= ptr_next(rd_ptr);
            case ({producer_request_fire,response_fire})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: ;
            endcase

            if (mem_resp_valid && (fifo_empty || head_padding))
                error <= 1'b1;
            if (producer_request_fire &&
                (fill_word_index >= (FOOTPRINT_HEIGHT*FOOTPRINT_WIDTH*4)))
                error <= 1'b1;
        end
    end
endmodule

`default_nettype wire
