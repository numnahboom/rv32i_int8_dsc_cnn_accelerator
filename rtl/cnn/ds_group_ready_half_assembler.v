`timescale 1ns/1ps
`default_nettype none

/*
 * Assemble the registered stream4 DW response into the two 4-channel
 * halves consumed by the output-stationary PW block.
 *
 * A producer result is sixteen signed bytes for one pixel.  stream4 presents
 * those bytes as four 32-bit beats.  Eight pixels form one spatial row block;
 * channels [g*8 +: 8] are one partial-K group, represented by two 256-bit
 * writes (four channels per write).  The assembler is deliberately an
 * elastic, single-row island: no wide variable-address mux is placed on the
 * downstream bank interface and the next source beat is not accepted while
 * the four writes for a completed row/bundle are draining.
 */
module ds_group_ready_half_assembler #(
    parameter integer MAX_PIXELS = 17,
    parameter integer MAX_BUNDLES = 8,
    parameter integer PIXEL_WIDTH = 6,
    parameter integer BUNDLE_WIDTH = 3
) (
    input wire clk,
    input wire rst_n,

    input wire [7:0] total_pixels,
    input wire [7:0] total_bundles,
    input wire config_valid,
    output wire config_ready,

    input wire stream_valid,
    output wire stream_ready,
    input wire [PIXEL_WIDTH-1:0] stream_pixel,
    input wire [BUNDLE_WIDTH-1:0] stream_bundle,
    input wire [1:0] stream_lane_base,
    input wire [31:0] stream_data,
    input wire [3:0] stream_lane_mask,

    output reg half_valid,
    input wire half_ready,
    output reg [2:0] half_row,
    output reg [BUNDLE_WIDTH:0] half_group,
    output reg half_sel,
    output reg [255:0] half_data,
    output reg [31:0] half_lane_mask,
    output reg half_done,
    output reg error
);
    localparam [1:0] ST_COLLECT = 2'd0;
    localparam [1:0] ST_EMIT = 2'd1;
    localparam [1:0] ST_DONE = 2'd2;

    reg [1:0] state;
    reg [7:0] pixels_reg;
    reg [7:0] bundles_reg;
    reg [7:0] current_row;
    reg [BUNDLE_WIDTH-1:0] current_bundle;
    reg [2:0] emit_idx;
    reg [2:0] emit_row_q;
    reg [BUNDLE_WIDTH:0] emit_group_q;
    reg [7:0] next_pixel;

    /* Eight pixel slots, each preserving all sixteen stream4 bytes. */
    reg [127:0] pixel_data [0:7];
    reg [15:0] pixel_mask [0:7];

    wire stream_fire = stream_valid && stream_ready;
    wire half_fire = half_valid && half_ready;
    wire pixel_last_in_row = (stream_pixel[2:0] == 3'd7) ||
                             (stream_pixel + 1'b1 >= pixels_reg);
    wire beat_last = (stream_lane_base == 2'd3);
    wire row_complete = stream_fire && beat_last && pixel_last_in_row;

    assign stream_ready = rst_n && (state == ST_COLLECT) &&
                          (stream_pixel < MAX_PIXELS) &&
                          (stream_bundle < MAX_BUNDLES);
    assign config_ready = rst_n && (state == ST_COLLECT) && (next_pixel == 0);
    wire config_fire = config_valid && config_ready;

    integer p;
    integer q;
    integer src_ch;
    integer slot;
    always @* begin
        half_row = emit_row_q;
        half_group = emit_group_q + (emit_idx >> 1);
        half_sel = emit_idx[0];
        half_data = 256'd0;
        half_lane_mask = 32'd0;
        /* Fixed loop bounds synthesize to byte wiring.  The source channel
         * is a constant offset for each emitted half/group. */
        for (p = 0; p < 8; p = p + 1) begin
            for (q = 0; q < 4; q = q + 1) begin
                src_ch = ((emit_idx >> 1) * 8) + (emit_idx[0] * 4) + q;
                half_data[(p*32)+(q*8) +: 8] = pixel_data[p][(src_ch*8) +: 8];
                if (((current_row * 8) + p) < pixels_reg)
                    half_lane_mask[(p*4)+q] = pixel_mask[p][src_ch];
            end
        end

        /* The output is only meaningful in EMIT.  Keeping this as a
         * registered-valid boundary prevents the metadata mux from entering
         * the source ready path. */
        half_valid = (state == ST_EMIT);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_COLLECT;
            pixels_reg <= 0;
            bundles_reg <= 0;
            current_row <= 0;
            current_bundle <= 0;
            emit_idx <= 0;
            emit_row_q <= 0;
            emit_group_q <= 0;
            next_pixel <= 0;
            half_done <= 1'b0;
            error <= 1'b0;
            for (p = 0; p < 8; p = p + 1) begin
                pixel_data[p] <= 128'd0;
                pixel_mask[p] <= 16'd0;
            end
        end else begin
            half_done <= 1'b0;
            if (config_fire) begin
                pixels_reg <= (total_pixels == 0) ? 8'd1 : total_pixels;
                bundles_reg <= (total_bundles == 0) ? 8'd1 : total_bundles;
                current_row <= 0;
                current_bundle <= 0;
                next_pixel <= 0;
                state <= ST_COLLECT;
            end
            if (stream_fire) begin
                slot = stream_pixel[2:0];
                if ((stream_lane_base > 2'd3) ||
                    (stream_bundle >= bundles_reg) ||
                    (stream_pixel >= pixels_reg) ||
                    ((stream_pixel[2:0] != next_pixel[2:0]) &&
                     (stream_pixel[2:0] != 3'd0))) begin
                    error <= 1'b1;
                end
                pixel_data[slot][(stream_lane_base*32) +: 32] <= stream_data;
                pixel_mask[slot][(stream_lane_base*4) +: 4] <= stream_lane_mask;
                next_pixel <= stream_pixel;
                if (beat_last) begin
                    if (pixel_last_in_row) begin
                        current_row <= stream_pixel >> 3;
                        current_bundle <= stream_bundle;
                        emit_row_q <= stream_pixel >> 3;
                        emit_group_q <= stream_bundle * 2;
                        emit_idx <= 0;
                        state <= ST_EMIT;
                        next_pixel <= 0;
                    end else begin
                        next_pixel <= stream_pixel + 1'b1;
                    end
                end
            end

            if (half_fire) begin
                if (emit_idx == 3'd3) begin
                    if ((current_bundle + 1'b1 >= bundles_reg) &&
                        (current_row + 1'b1 >= ((pixels_reg + 7) >> 3))) begin
                        state <= ST_DONE;
                        half_done <= 1'b1;
                    end else begin
                        state <= ST_COLLECT;
                        emit_idx <= 0;
                        next_pixel <= 0;
                    end
                end else begin
                    emit_idx <= emit_idx + 1'b1;
                end
            end

            /* A source is allowed to present bundle-major traffic (the
             * established DW producer does so).  The explicit row/group in
             * each emitted write is therefore the ownership contract; no
             * assumption about an inter-bundle row order is hidden here. */
            if (state == ST_DONE)
                half_done <= 1'b1;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_PIXELS > 64 || MAX_BUNDLES > 8)
            $error("group-ready assembler bounds exceed fixed ABI");
    end
`endif
endmodule

`default_nettype wire
