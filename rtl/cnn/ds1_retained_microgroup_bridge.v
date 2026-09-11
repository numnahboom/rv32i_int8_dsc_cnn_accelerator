`timescale 1ns/1ps
`default_nettype none

/*
 * Global job scheduler for the retained DS1 path.
 *
 * A DS1 invocation (32x32x16 -> 32x32x32, 3x3 stride-1 SAME) is decomposed
 * into sixteen 8x8 tiles.  Each tile is issued as four 2x8 microgroups;
 * unlike ds1_tiled_group_bridge, one job here owns the complete 32-channel
 * Cout replay for that microgroup.  The downstream retained-bank path does
 * the four Cout groups after the one DW result has been committed, so this
 * scheduler emits exactly 64 jobs.
 *
 * The scheduler is deliberately single-outstanding.  A job is held until
 * job_ready, and the bank tag alternates only after that handshake.  This
 * makes bank reuse safe for a retained session while preserving stable
 * ready/valid metadata under backpressure.
 *
 * fill_word_index addresses the producer's linear 4x10 footprint (four
 * packed Cin=16 words per source pixel).  The map is the global pixel-major
 * DS1 input layout: valid words map to input_base_addr + pixel*16 + q*4,
 * while SAME halo words are marked padding and supplied as zero_point.
 */
module ds1_retained_microgroup_bridge #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer EPOCH_WIDTH = 4
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         start_valid,
    output wire                         start_ready,
    input  wire [ADDR_WIDTH-1:0]        input_base_addr,
    input  wire [7:0]                   input_zero_point,
    input  wire [EPOCH_WIDTH-1:0]       start_epoch,

    output wire                         job_valid,
    input  wire                         job_ready,
    output wire [3:0]                   job_tile_index,
    output wire [1:0]                   job_micro_row,
    output wire [7:0]                   job_sequence,
    output wire                         job_bank,
    output wire [EPOCH_WIDTH-1:0]       job_epoch,
    output wire [5:0]                   job_global_y,
    output wire [5:0]                   job_global_x,
    output wire [9:0]                   job_global_pixel_base,
    output wire [5:0]                   job_cout_base,
    output wire [7:0]                   job_pixel_count,
    output wire [7:0]                   job_cout_count,

    input  wire [7:0]                   fill_word_index,
    output reg                          map_is_padding,
    output reg  [ADDR_WIDTH-1:0]        map_addr,
    output wire [7:0]                   map_padding_word,

    output reg                          done
);
    localparam [5:0] LAST_JOB = 6'd63;

    reg                         active_reg;
    reg [5:0]                   job_index_reg;
    reg [ADDR_WIDTH-1:0]        input_base_addr_reg;
    reg [7:0]                   input_zero_point_reg;
    reg [EPOCH_WIDTH-1:0]       epoch_reg;

    wire start_fire = start_valid && start_ready;
    wire job_fire = job_valid && job_ready;

    /* Four microgroups per tile, tile order is row-major. */
    wire [3:0] tile_index_i = job_index_reg[5:2];
    wire [1:0] micro_row_i = job_index_reg[1:0];
    wire [5:0] global_y_i = {1'b0, job_index_reg[5:4], 3'b000} +
                            {3'b000, job_index_reg[1:0], 1'b0};
    wire [5:0] global_x_i = {1'b0, job_index_reg[3:2], 3'b000};
    wire [9:0] pixel_base_i = (global_y_i * 10'd32) + global_x_i;

    assign start_ready = rst_n && !active_reg;
    assign job_valid = active_reg;
    assign job_tile_index = tile_index_i;
    assign job_micro_row = micro_row_i;
    assign job_sequence = {2'b00, job_index_reg};
    assign job_bank = job_index_reg[0];
    assign job_epoch = epoch_reg;
    assign job_global_y = global_y_i;
    assign job_global_x = global_x_i;
    assign job_global_pixel_base = pixel_base_i;
    /* One retained job covers all four 8-channel Cout groups. */
    assign job_cout_base = 6'd0;
    assign job_pixel_count = 8'd16;
    assign job_cout_count = 8'd32;
    assign map_padding_word = input_zero_point_reg;

    /* Address-map temporaries are intentionally signed for the halo test. */
    reg [7:0] fill_pixel_i;
    reg [3:0] fill_sx_i;
    reg [3:0] fill_sy_i;
    reg [1:0] fill_q_i;
    reg signed [7:0] source_y_i;
    reg signed [7:0] source_x_i;
    reg [10:0] source_pixel_i;

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
        if (map_is_padding)
            map_addr = {ADDR_WIDTH{1'b0}};
        else
            map_addr = input_base_addr_reg + (source_pixel_i * 11'd16) +
                       {{(ADDR_WIDTH-5){1'b0}}, fill_q_i, 2'b00};
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            active_reg <= 1'b0;
            job_index_reg <= 6'd0;
            input_base_addr_reg <= {ADDR_WIDTH{1'b0}};
            input_zero_point_reg <= 8'd0;
            epoch_reg <= {EPOCH_WIDTH{1'b0}};
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start_fire) begin
                active_reg <= 1'b1;
                job_index_reg <= 6'd0;
                input_base_addr_reg <= input_base_addr;
                input_zero_point_reg <= input_zero_point;
                epoch_reg <= start_epoch;
            end else if (job_fire) begin
                if (job_index_reg == LAST_JOB) begin
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
