`timescale 1ns/1ps
`default_nettype none

/*
 * Pixel-major source adapter for the group-published 4x8 producer.
 *
 * The producer issues a contiguous local word stream.  This boundary keeps
 * that stream's order, but maps it to NHWC without putting a divide/modulo or
 * a per-request multiply in the producer ready/address cone.  A context is
 * captured at the fill fence, prepared for two cycles, and then the steady
 * state mapper advances only row, pixel, and quarter registers.  The one-bit
 * FIFO records padding versus SRAM responses; one address/padding skid entry
 * decouples producer acceptance from source SRAM ready.
 */
module ds_group_feature_word_address_adapter #(
    parameter integer ADDR_WIDTH = 24,
    parameter integer FIFO_DEPTH = 8,
    parameter integer PTR_WIDTH = (FIFO_DEPTH > 2) ? $clog2(FIFO_DEPTH) : 1,
    parameter integer COUNT_WIDTH = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH+1) : 1
) (
    input wire clk, input wire rst_n,
    input wire context_valid, output wire context_ready,
    input wire [ADDR_WIDTH-1:0] context_linear_base,
    input wire [ADDR_WIDTH-1:0] context_input_base,
    input wire [7:0] context_global_y, input wire [7:0] context_global_x,
    input wire [7:0] context_input_zero_point,
    input wire [7:0] context_stride,
    input wire [15:0] context_input_width,
    input wire [15:0] context_input_height,
    input wire [15:0] context_input_channels,
    input wire [15:0] context_channel_offset,
    input wire [7:0] context_footprint_width,
    input wire [7:0] context_footprint_height,
    input wire context_complete,
    input wire producer_req_valid,
    output wire producer_req_ready,
    input wire [ADDR_WIDTH-1:0] producer_req_addr,
    output wire producer_resp_valid, input wire producer_resp_ready,
    output wire [31:0] producer_resp_data,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid, input wire [31:0] mem_resp_data,
    output reg error
);
    localparam [1:0] PREP_IDLE = 2'd0, PREP_ORIGIN = 2'd1,
                     PREP_ADDRESS = 2'd2, PREP_READY = 2'd3;

    reg context_active;
    reg [1:0] prep_state;
    reg prepared;
    reg [ADDR_WIDTH-1:0] linear_base_reg, input_base_reg;
    reg [7:0] global_y_reg, global_x_reg, zero_point_reg, stride_reg;
    reg [15:0] input_width_reg, input_height_reg, input_channels_reg;
    reg [15:0] channel_offset_reg;
    reg [7:0] footprint_width_reg, footprint_height_reg;

    /* Signed coordinates are used only for validity; address generation is
     * from the registered row/pixel bases below. */
    reg signed [16:0] origin_y_reg, origin_x_reg;
    reg signed [16:0] source_y_reg, source_x_reg;
    reg [ADDR_WIDTH-1:0] row_stride_reg;
    reg [ADDR_WIDTH-1:0] origin_y_offset_reg, origin_x_offset_reg;
    reg [ADDR_WIDTH-1:0] row_base_reg, row_pixel_base_reg, pixel_base_reg;
    reg [ADDR_WIDTH-1:0] x_offset_bytes_reg;
    reg [7:0] fill_row_reg, fill_col_reg;
    reg [1:0] quarter_reg;
    reg [31:0] word_index_reg;
    reg [ADDR_WIDTH-1:0] expected_linear_addr_reg;

    reg [PTR_WIDTH-1:0] wr_ptr, rd_ptr;
    reg [COUNT_WIDTH-1:0] fifo_count;
    reg [COUNT_WIDTH-1:0] padding_count;
    reg [COUNT_WIDTH:0] nonpad_inflight_count;
    reg padding_fifo [0:FIFO_DEPTH-1];
    /* Source SRAM responses are untagged but ordered.  Buffer payloads so
     * several requests can be in flight without losing a one-cycle response
     * pulse behind producer ready. */
    reg [31:0] response_data_fifo [0:FIFO_DEPTH-1];
    reg [PTR_WIDTH-1:0] response_wr_ptr, response_rd_ptr;
    reg [COUNT_WIDTH:0] response_data_count;
    reg dispatch_padding_reg;

    reg source_pending_valid;
    reg source_pending_padding;
    reg [ADDR_WIDTH-1:0] source_pending_addr;

    wire fifo_empty = (fifo_count == 0);
    wire fifo_full = (fifo_count == FIFO_DEPTH);
    wire head_padding = !fifo_empty && padding_fifo[rd_ptr];
    wire current_row_valid = (source_y_reg >= 0) &&
                              (source_y_reg < $signed({1'b0,input_height_reg}));
    wire current_col_valid = (source_x_reg >= 0) &&
                              (source_x_reg < $signed({1'b0,input_width_reg}));
    wire current_channel_valid =
        ((channel_offset_reg + {14'd0,quarter_reg,2'b00}) < input_channels_reg);
    wire mapped_padding = !current_row_valid || !current_col_valid ||
                           !current_channel_valid;
    wire [ADDR_WIDTH-1:0] mapped_addr = pixel_base_reg +
        {{(ADDR_WIDTH-16){1'b0}},channel_offset_reg} +
        {{(ADDR_WIDTH-4){1'b0}},quarter_reg,2'b00};
    /* The next row base is an increment, not a coordinate multiply.  The
     * origin can be -1 for the top halo row, hence the explicit transition to
     * input_base when source_y advances from a negative value to zero. */
    wire signed [17:0] next_source_y = source_y_reg + 17'sd1;
    wire [ADDR_WIDTH-1:0] next_row_base =
        (next_source_y < 0) ? input_base_reg :
        (source_y_reg < 0) ? input_base_reg : row_base_reg + row_stride_reg;
    /* row_pixel_base_reg is the row-start cursor (row_base plus the fixed
     * origin-x channel offset); pixel_base_reg then walks across that row.
     * Advance the row-start cursor directly at a row boundary instead of
     * rebuilding it as (row_base + row_stride) + x_offset.  The latter put
     * row_stride through two adders on the row_stride_reg -> pixel_base_reg
     * timing path. */
    wire [ADDR_WIDTH-1:0] next_row_pixel_base =
        (source_y_reg < 0) ? (input_base_reg + x_offset_bytes_reg) :
                             (row_pixel_base_reg + row_stride_reg);
    /* These products are formed once per fill context, before the producer
     * starts issuing words.  Registering the products separately keeps the
     * origin multipliers out of the row-base/pixel-base adders in the
     * accepted-request path. */
    wire signed [16:0] origin_y_calc = (stride_reg == 2) ?
        ($signed({1'b0,global_y_reg,1'b0}) - 17'sd1) :
        ($signed({1'b0,global_y_reg}) - 17'sd1);
    wire signed [16:0] origin_x_calc = (stride_reg == 2) ?
        ($signed({1'b0,global_x_reg,1'b0}) - 17'sd1) :
        ($signed({1'b0,global_x_reg}) - 17'sd1);
    (* use_dsp = "yes" *) wire [ADDR_WIDTH-1:0] origin_y_offset_product =
        origin_y_calc * row_stride_reg;
    (* use_dsp = "yes" *) wire [ADDR_WIDTH-1:0] origin_x_offset_product =
        origin_x_calc * input_channels_reg;
    wire [ADDR_WIDTH-1:0] origin_y_row_offset_product = origin_y_offset_reg;
    wire [ADDR_WIDTH-1:0] origin_x_channel_offset_product = origin_x_offset_reg;
    wire [ADDR_WIDTH-1:0] initial_row_base =
        input_base_reg + origin_y_row_offset_product;
    wire [ADDR_WIDTH-1:0] initial_pixel_base =
        initial_row_base + origin_x_channel_offset_product;

    wire response_fire = producer_resp_valid && producer_resp_ready;
    wire nonpad_response_fire = response_fire && !head_padding;
    wire fifo_full_now = (fifo_count == FIFO_DEPTH);
    wire fifo_space = !fifo_full_now || response_fire;
    wire padding_response_fire = response_fire && head_padding;
    wire padding_order_safe = (padding_count == 0) || padding_response_fire;
    /* Do not place a halo descriptor behind an SRAM request or buffered
     * response.  The external response channel has no tag, so this fence
     * preserves request order while contiguous non-padding payloads pipeline. */
    wire padding_response_order_safe =
        (nonpad_inflight_count == 0) && (response_data_count == 0);
    wire dispatch_order_safe = dispatch_padding_reg ? padding_response_order_safe :
                                                     padding_order_safe;
    wire request_allowed = rst_n && context_active && prepared && fifo_space &&
                            producer_resp_ready &&
                            (!source_pending_valid || mem_req_ready) &&
                            dispatch_order_safe;
    wire request_fire = producer_req_valid && producer_req_ready;
    wire mem_fire = mem_req_valid && mem_req_ready;
    /* The external SRAM model has no response tag.  Ignore a stale valid
     * pulse after the last outstanding non-padding request has retired; it
     * must not create an orphan payload FIFO entry for the next context. */
    wire mem_resp_fire = mem_resp_valid && (nonpad_inflight_count != 0) &&
                         ((response_data_count < FIFO_DEPTH) ||
                          nonpad_response_fire);
    wire [ADDR_WIDTH-1:0] current_expected_addr = expected_linear_addr_reg;

    assign context_ready = rst_n &&
        ((!context_active && (prep_state == PREP_IDLE)) ||
         (context_complete && fifo_empty && !source_pending_valid));
    /* Acceptance depends only on prepared context, FIFO capacity, and the
     * registered one-entry dispatch state.  It is independent of address
     * coordinate arithmetic. */
    assign producer_req_ready = request_allowed;

    /* Bypass an empty skid when SRAM is ready; otherwise capture exactly one
     * non-padding request and drain it later.  A pending entry has priority. */
    assign mem_req_valid = rst_n && context_active && prepared &&
        (source_pending_valid ||
         (producer_req_valid && producer_req_ready && !dispatch_padding_reg));
    assign mem_req_addr = source_pending_valid ? source_pending_addr : mapped_addr;
    assign producer_resp_valid = !fifo_empty &&
        (head_padding || (response_data_count != 0));
    assign producer_resp_data = head_padding ? {4{zero_point_reg}} :
        response_data_fifo[response_rd_ptr];
    function [PTR_WIDTH-1:0] ptr_next;
        input [PTR_WIDTH-1:0] ptr;
        begin
            ptr_next = (ptr == FIFO_DEPTH-1) ? {PTR_WIDTH{1'b0}} : ptr + 1'b1;
        end
    endfunction

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            context_active <= 1'b0;
            prep_state <= PREP_IDLE;
            prepared <= 1'b0;
            linear_base_reg <= 0; input_base_reg <= 0;
            global_y_reg <= 0; global_x_reg <= 0;
            zero_point_reg <= 0; stride_reg <= 1;
            input_width_reg <= 0; input_height_reg <= 0;
            input_channels_reg <= 0; channel_offset_reg <= 0;
            footprint_width_reg <= 0; footprint_height_reg <= 0;
            origin_y_reg <= 0; origin_x_reg <= 0;
            source_y_reg <= 0; source_x_reg <= 0;
            row_stride_reg <= 0; origin_y_offset_reg <= 0; origin_x_offset_reg <= 0;
            row_base_reg <= 0; row_pixel_base_reg <= 0;
            pixel_base_reg <= 0; x_offset_bytes_reg <= 0;
            fill_row_reg <= 0; fill_col_reg <= 0; quarter_reg <= 0;
            word_index_reg <= 0; expected_linear_addr_reg <= 0;
            wr_ptr <= 0; rd_ptr <= 0; fifo_count <= 0;
            padding_count <= 0;
            nonpad_inflight_count <= 0;
            response_wr_ptr <= 0; response_rd_ptr <= 0;
            response_data_count <= 0;
            dispatch_padding_reg <= 1'b1;
            source_pending_valid <= 1'b0;
            source_pending_padding <= 1'b0; source_pending_addr <= 0;
            error <= 1'b0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1) padding_fifo[i] <= 1'b0;
            for (i = 0; i < FIFO_DEPTH; i = i + 1) response_data_fifo[i] <= 0;
        end else begin
            if (context_valid && context_ready) begin
                context_active <= 1'b1;
                prep_state <= PREP_ORIGIN;
                prepared <= 1'b0;
                linear_base_reg <= context_linear_base;
                input_base_reg <= context_input_base;
                global_y_reg <= context_global_y;
                global_x_reg <= context_global_x;
                zero_point_reg <= context_input_zero_point;
                stride_reg <= (context_stride == 0) ? 1 : context_stride;
                input_width_reg <= context_input_width;
                input_height_reg <= context_input_height;
                input_channels_reg <= context_input_channels;
                row_stride_reg <= context_input_width * context_input_channels;
                channel_offset_reg <= context_channel_offset;
                footprint_width_reg <= context_footprint_width;
                footprint_height_reg <= context_footprint_height;
                wr_ptr <= 0; rd_ptr <= 0; fifo_count <= 0;
                padding_count <= 0;
                nonpad_inflight_count <= 0;
                response_wr_ptr <= 0; response_rd_ptr <= 0;
                response_data_count <= 0;
                source_pending_valid <= 1'b0;
            end else if (prep_state == PREP_ORIGIN) begin
                /* stride is restricted by the caller to one or two. */
                if (stride_reg == 2) begin
                    origin_y_reg <= $signed({1'b0,global_y_reg,1'b0}) - 17'sd1;
                    origin_x_reg <= $signed({1'b0,global_x_reg,1'b0}) - 17'sd1;
                end else begin
                    origin_y_reg <= $signed({1'b0,global_y_reg}) - 17'sd1;
                    origin_x_reg <= $signed({1'b0,global_x_reg}) - 17'sd1;
                end
                origin_y_offset_reg <= origin_y_offset_product;
                origin_x_offset_reg <= origin_x_offset_product;
                prep_state <= PREP_ADDRESS;
            end else if (prep_state == PREP_ADDRESS) begin
                source_y_reg <= origin_y_reg;
                source_x_reg <= origin_x_reg;
                fill_row_reg <= 0; fill_col_reg <= 0; quarter_reg <= 0;
                word_index_reg <= 0;
                expected_linear_addr_reg <= linear_base_reg;
                if (origin_x_reg < 0)
                    x_offset_bytes_reg <= 0;
                else
                    x_offset_bytes_reg <= origin_x_channel_offset_product;
                if (origin_y_reg < 0)
                    row_base_reg <= input_base_reg;
                else
                    row_base_reg <= initial_row_base;
                if (origin_x_reg < 0)
                    pixel_base_reg <= input_base_reg;
                else
                    pixel_base_reg <= initial_pixel_base;
                if (origin_x_reg < 0)
                    row_pixel_base_reg <= input_base_reg;
                else if (origin_y_reg < 0)
                    row_pixel_base_reg <= input_base_reg +
                                          origin_x_channel_offset_product;
                else
                    row_pixel_base_reg <= initial_pixel_base;
                dispatch_padding_reg <= (origin_y_reg < 0) ||
                                        (origin_y_reg >= $signed({1'b0,input_height_reg})) ||
                                        (origin_x_reg < 0) ||
                                        (origin_x_reg >= $signed({1'b0,input_width_reg})) ||
                                        (channel_offset_reg >= input_channels_reg);
                prepared <= 1'b1;
                prep_state <= PREP_READY;
            end

            if (request_fire) begin
                padding_fifo[wr_ptr] <= dispatch_padding_reg;
                wr_ptr <= ptr_next(wr_ptr);
                word_index_reg <= word_index_reg + 1'b1;
                expected_linear_addr_reg <= expected_linear_addr_reg + 4;
                if (producer_req_addr != current_expected_addr)
                    error <= 1'b1;

                if (quarter_reg != 2'd3) begin
                    dispatch_padding_reg <= !current_row_valid ||
                        !current_col_valid ||
                        ((channel_offset_reg +
                          {14'd0,quarter_reg + 2'd1,2'b00}) >= input_channels_reg);
                end else if (fill_col_reg + 1 >= footprint_width_reg) begin
                    dispatch_padding_reg <= (next_source_y < 0) ||
                        (next_source_y >= $signed({1'b0,input_height_reg})) ||
                        (origin_x_reg < 0) ||
                        (origin_x_reg >= $signed({1'b0,input_width_reg})) ||
                        (channel_offset_reg >= input_channels_reg);
                end else begin
                    dispatch_padding_reg <= !current_row_valid ||
                        ((source_x_reg + 17'sd1) < 0) ||
                        ((source_x_reg + 17'sd1) >= $signed({1'b0,input_width_reg})) ||
                        (channel_offset_reg >= input_channels_reg);
                end

                if (quarter_reg == 2'd3) begin
                    quarter_reg <= 0;
                    if (fill_col_reg + 1 >= footprint_width_reg) begin
                        fill_col_reg <= 0;
                        fill_row_reg <= fill_row_reg + 1'b1;
                        source_y_reg <= source_y_reg + 17'sd1;
                        source_x_reg <= origin_x_reg;
                        row_base_reg <= next_row_base;
                        row_pixel_base_reg <= next_row_pixel_base;
                        pixel_base_reg <= next_row_pixel_base;
                    end else begin
                        fill_col_reg <= fill_col_reg + 1'b1;
                        source_x_reg <= source_x_reg + 17'sd1;
                        if (source_x_reg < 0)
                            pixel_base_reg <= row_base_reg;
                        else
                            pixel_base_reg <= pixel_base_reg + input_channels_reg;
                    end
                end else begin
                    quarter_reg <= quarter_reg + 1'b1;
                end
            end

            /* A pending request is drained by the source handshake.  If a
             * producer request arrives in the same cycle, retain it as the
             * next pending entry, preserving II=1. */
            if (mem_fire) begin
                if (source_pending_valid && request_fire && !dispatch_padding_reg) begin
                    source_pending_valid <= 1'b1;
                    source_pending_padding <= 1'b0;
                    source_pending_addr <= mapped_addr;
                end else begin
                    source_pending_valid <= 1'b0;
                end
            end else if (request_fire && !dispatch_padding_reg) begin
                source_pending_valid <= 1'b1;
                source_pending_padding <= 1'b0;
                source_pending_addr <= mapped_addr;
            end

            if (mem_resp_fire) begin
                response_data_fifo[response_wr_ptr] <= mem_resp_data;
                response_wr_ptr <= ptr_next(response_wr_ptr);
            end
            if (nonpad_response_fire)
                response_rd_ptr <= ptr_next(response_rd_ptr);
            case ({mem_resp_fire,nonpad_response_fire})
                2'b10: response_data_count <= response_data_count + 1'b1;
                2'b01: response_data_count <= response_data_count - 1'b1;
                default: ;
            endcase

            case ({mem_fire,mem_resp_fire})
                2'b10: nonpad_inflight_count <= nonpad_inflight_count + 1'b1;
                2'b01: if (nonpad_inflight_count != 0)
                           nonpad_inflight_count <= nonpad_inflight_count - 1'b1;
                default: ;
            endcase

            if (response_fire) rd_ptr <= ptr_next(rd_ptr);
            case ({request_fire,response_fire})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: ;
            endcase
            case ({request_fire && dispatch_padding_reg,
                  response_fire && head_padding})
                2'b10: padding_count <= padding_count + 1'b1;
                2'b01: padding_count <= padding_count - 1'b1;
                default: ;
            endcase
            /* When a pending non-padding request drains, a new padding
             * producer request may be accepted in the same cycle.  The
             * source mem_req_valid then belongs to the pending entry, so it
             * is not an illegal padding SRAM request. */

            if (context_complete && fifo_empty && !source_pending_valid &&
                !request_fire && !response_fire) begin
                context_active <= 1'b0;
                prepared <= 1'b0;
                prep_state <= PREP_IDLE;
            end
        end
    end
endmodule

`default_nettype wire
