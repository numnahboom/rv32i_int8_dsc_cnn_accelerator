`timescale 1ns/1ps
`default_nettype none

/*
 * DS1 (32x32x16 -> 32x32x32, 3x3 stride-1 SAME) job/address bridge.
 *
 * This is the transaction-metadata half of the group-ready integration.  It
 * serialises the full layer into the exact units accepted by the existing
 * group-ready producer: an 8x8 tile is four 2x8 microgroups, each issued for
 * four 8-channel PW output groups.  Thus every layer invocation emits 256
 * jobs and every tile covers its 64 output pixels exactly once.
 *
 * The producer-facing fill adapter supplies fill_word_index (0..159).  This
 * module maps it to the global pixel-major input address, or marks it as a
 * SAME-padding word.  It intentionally does not own the external response
 * channel yet: the later producer adapter must preserve its ready/valid
 * ordering while injecting input_zero_point for map_is_padding words.
 */
module ds1_tiled_group_bridge (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_valid,
    output wire        start_ready,
    input  wire [31:0] input_base_addr,
    input  wire [7:0]  input_zero_point,
    input  wire [3:0]  start_epoch,

    output wire        job_valid,
    input  wire        job_ready,
    output wire [3:0]  job_tile_index,
    output wire [1:0]  job_micro_row,
    output wire [1:0]  job_cout_group,
    output wire [7:0]  job_sequence,
    output wire        job_bank,
    output wire [3:0]  job_epoch,
    output wire [5:0]  job_global_y,
    output wire [5:0]  job_global_x,
    output wire [9:0]  job_global_pixel_base,
    output wire [5:0]  job_cout_base,
    output wire [7:0]  job_pixel_count,
    output wire [7:0]  job_cout_count,

    input  wire [7:0]  fill_word_index,
    output reg         map_is_padding,
    output reg  [31:0] map_addr,
    output wire [7:0]  map_padding_word,

    output reg         done
);
    reg        active_reg;
    reg [7:0]  job_index_reg;
    reg [31:0] input_base_addr_reg;
    reg [7:0]  input_zero_point_reg;
    reg [3:0]  epoch_reg;

    wire start_fire = start_valid && start_ready;
    wire job_fire = job_valid && job_ready;
    wire [3:0] tile_index_i = job_index_reg[7:4];
    wire [1:0] micro_row_i = job_index_reg[3:2];
    wire [1:0] cout_group_i = job_index_reg[1:0];
    wire [5:0] global_y_i = {tile_index_i[3:2], 3'b000} +
                             {micro_row_i, 1'b0};
    wire [5:0] global_x_i = {tile_index_i[1:0], 3'b000};
    wire [9:0] pixel_base_i = (global_y_i * 10'd32) + global_x_i;

    /* Four Cin=16 packed words per source pixel.  A 2x8 output group has a
     * 4x10 halo footprint, hence 40 source pixels / 160 packed words. */
    reg [7:0] fill_pixel_i;
    reg [3:0] fill_sx_i;
    reg [2:0] fill_sy_i;
    reg [1:0] fill_q_i;
    reg signed [7:0] source_y_i;
    reg signed [7:0] source_x_i;
    reg [10:0] source_pixel_i;

    assign start_ready = rst_n && !active_reg;
    assign job_valid = active_reg;
    assign job_tile_index = tile_index_i;
    assign job_micro_row = micro_row_i;
    assign job_cout_group = cout_group_i;
    assign job_sequence = job_index_reg;
    /* The bridge is intentionally single-outstanding until the producer
     * adapter proves dual-bank overlap.  Toggling per microgroup keeps the
     * bank tag deterministic without allowing an early reuse. */
    assign job_bank = micro_row_i[0];
    assign job_epoch = epoch_reg;
    assign job_global_y = global_y_i;
    assign job_global_x = global_x_i;
    assign job_global_pixel_base = pixel_base_i;
    assign job_cout_base = {cout_group_i, 3'b000};
    assign job_pixel_count = 8'd16;
    assign job_cout_count = 8'd8;
    assign map_padding_word = {4{input_zero_point_reg}};

    always @* begin
        fill_pixel_i = fill_word_index >> 2;
        fill_q_i = fill_word_index[1:0];
        fill_sy_i = fill_pixel_i / 8'd10;
        fill_sx_i = fill_pixel_i % 8'd10;
        source_y_i = $signed({1'b0, global_y_i}) - 8'sd1 +
                     $signed({1'b0, fill_sy_i});
        source_x_i = $signed({1'b0, global_x_i}) - 8'sd1 +
                     $signed({1'b0, fill_sx_i});
        map_is_padding = (fill_word_index >= 8'd160) ||
                         (source_y_i < 0) || (source_y_i >= 32) ||
                         (source_x_i < 0) || (source_x_i >= 32);
        source_pixel_i = (source_y_i * 11'd32) + source_x_i;
        if (map_is_padding) begin
            map_addr = 32'd0;
        end else begin
            map_addr = input_base_addr_reg + (source_pixel_i * 11'd16) +
                       {29'd0, fill_q_i, 2'b00};
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            active_reg <= 1'b0;
            job_index_reg <= 8'd0;
            input_base_addr_reg <= 32'd0;
            input_zero_point_reg <= 8'd0;
            epoch_reg <= 4'd0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start_fire) begin
                active_reg <= 1'b1;
                job_index_reg <= 8'd0;
                input_base_addr_reg <= input_base_addr;
                input_zero_point_reg <= input_zero_point;
                epoch_reg <= start_epoch;
            end else if (job_fire) begin
                if (job_index_reg == 8'hff) begin
                    active_reg <= 1'b0;
                    done <= 1'b1;
                end else begin
                    job_index_reg <= job_index_reg + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
