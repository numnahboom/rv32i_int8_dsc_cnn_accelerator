`timescale 1ns/1ps
`default_nettype none

/*
 * Tile-local depthwise window-reuse prototype.
 *
 * The external storage contract is the synchronous 128-bit read port of
 * ds_input_tile_buffer_bram: one read returns one complete 16-channel vector
 * for a pixel/channel tile.  A tile is first fetched into a local row-major
 * store and is then replayed to dw_direct_3x3_dsp as nine ordered tap tokens
 * per output pixel.  Consequently the storage is read once per footprint
 * pixel (100 reads for an 8x8, stride-1 tile), rather than once per MAC tap.
 *
 * The local store is deliberately tile-local.  A future production wrapper
 * can ping-pong this store against a DMA writer without changing the direct
 * DW token contract.  The footprint starts at the top-left tap of output
 * pixel (0,0); padding is therefore represented by zero vectors written into
 * the footprint by the loader.  STRIDE=2 uses a 17x17 footprint and the same
 * schedule (289 reads); STRIDE=1 is the measured target path.
 */
module dw_window_reuse_scheduler #(
    parameter integer MAX_CIN = 128,
    parameter integer MAX_IN_H = 17,
    parameter integer MAX_IN_W = 17,
    parameter integer LANES = 16,
    parameter integer TILE_H = 8,
    parameter integer TILE_W = 8,
    parameter integer STRIDE = 1,
    parameter integer LINEAR_ADDR_WIDTH =
        ((MAX_IN_H*MAX_IN_W*MAX_CIN + 1) > 1) ?
        $clog2(MAX_IN_H*MAX_IN_W*MAX_CIN + 1) : 1,
    parameter integer CHANNEL_TILE_WIDTH =
        ((MAX_CIN/LANES) > 1) ? $clog2(MAX_CIN/LANES) : 1
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         wr_en,
    input  wire [LINEAR_ADDR_WIDTH-1:0] wr_linear_idx,
    input  wire signed [7:0]            wr_data_int8,
    input  wire                         wr_vec4_en,
    input  wire [LINEAR_ADDR_WIDTH-1:0] wr_vec4_linear_idx,
    input  wire [31:0]                  wr_vec4_data_int8,

    input  wire                         cfg_valid,
    output wire                         cfg_ready,
    input  wire [3:0]                   cfg_tap_idx,
    input  wire signed [127:0]          cfg_weight_vec,
    input  wire signed [511:0]          cfg_bias_vec,
    input  wire signed [511:0]          cfg_multiplier_vec,
    input  wire [95:0]                  cfg_shift_vec,

    input  wire                         start,
    input  wire [8:0]                   start_channel_tile,
    input  wire [15:0]                  start_lane_mask,
    output reg                          busy,
    output reg                          done,

    output wire                         valid_out,
    input  wire                         ready_out,
    output wire [7:0]                   out_pixel_idx,
    output wire [15:0]                  out_lane_mask,
    output wire signed [511:0]          out_raw_vec,
    output wire signed [511:0]          out_bias_vec,
    output wire signed [511:0]          out_multiplier_vec,
    output wire [95:0]                  out_shift_vec,

    output reg [15:0]                   buffer_read_count,
    output reg [15:0]                   core_token_count,
    output reg [7:0]                    output_count
);
    localparam integer FOOTPRINT_H = ((TILE_H-1)*STRIDE) + 3;
    localparam integer FOOTPRINT_W = ((TILE_W-1)*STRIDE) + 3;
    localparam integer FOOTPRINT_PIXELS = FOOTPRINT_H * FOOTPRINT_W;
    localparam integer OUTPUT_PIXELS = TILE_H * TILE_W;
    localparam integer READ_COUNT_WIDTH =
        (FOOTPRINT_PIXELS > 1) ? $clog2(FOOTPRINT_PIXELS + 1) : 1;

    localparam [2:0] ST_IDLE          = 3'd0;
    localparam [2:0] ST_FILL          = 3'd1;
    localparam [2:0] ST_PREFETCH_ADDR = 3'd2;
    localparam [2:0] ST_EMIT          = 3'd3;
    localparam [2:0] ST_DRAIN         = 3'd4;
    reg [2:0] state;

    reg [READ_COUNT_WIDTH-1:0] issue_count;
    reg [READ_COUNT_WIDTH-1:0] capture_count;
    reg [READ_COUNT_WIDTH-1:0] local_wr_addr_reg;
    reg [8:0] channel_tile_reg;
    reg [15:0] lane_mask_reg;

    wire buffer_rd_en = (state == ST_FILL) &&
                        (issue_count < FOOTPRINT_PIXELS);
    wire [8:0] buffer_rd_pixel_idx = issue_count;
    wire [CHANNEL_TILE_WIDTH-1:0] buffer_rd_channel_tile =
        channel_tile_reg[CHANNEL_TILE_WIDTH-1:0];
    wire buffer_rd_valid;
    wire signed [(LANES*8)-1:0] buffer_rd_data;

    ds_input_tile_buffer_bram #(
        .MAX_CIN(MAX_CIN),
        .MAX_IN_H(MAX_IN_H),
        .MAX_IN_W(MAX_IN_W),
        .LANES(LANES),
        .LINEAR_ADDR_WIDTH(LINEAR_ADDR_WIDTH)
    ) u_input_tile_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_linear_idx(wr_linear_idx),
        .wr_data_int8(wr_data_int8),
        .wr_vec4_en(wr_vec4_en),
        .wr_vec4_linear_idx(wr_vec4_linear_idx),
        .wr_vec4_data_int8(wr_vec4_data_int8),
        .rd_en(buffer_rd_en),
        .rd_pixel_idx(buffer_rd_pixel_idx),
        .rd_channel_tile(buffer_rd_channel_tile),
        .rd_valid(buffer_rd_valid),
        .rd_data_vector(buffer_rd_data)
    );

    /* Each local entry is one native 16-channel vector.  Keeping the vector
     * packed (rather than sixteen separately written byte arrays) lets
     * Vivado infer a small distributed RAM for the footprint instead of
     * building a 100:1 register mux per lane.  It is populated only after the
     * synchronous BRAM response, so no live BRAM output is exposed to compute.
     */
    (* ram_style = "distributed" *)
    reg signed [(LANES*8)-1:0] local_mem_vec [0:FOOTPRINT_PIXELS-1];
    reg [5:0] emit_pixel_count;
    reg [3:0] emit_tap_count;
    reg token_valid;
    reg token_first;
    reg token_last;
    (* max_fanout = 2 *) reg [3:0] token_tap_idx;
    reg [7:0] token_pixel_idx;
    reg [15:0] token_lane_mask;
    reg signed [(LANES*8)-1:0] token_act_vec;
    reg signed [127:0] token_weight_vec;
    reg [READ_COUNT_WIDTH-1:0] prefetch_addr;
    reg signed [(LANES*8)-1:0] prefetch_data_vec;
    reg signed [127:0] prefetch_weight_vec;
    reg prefetch_valid;
    reg [3:0] prefetch_tap_addr;

    integer emit_mem_index;
    integer next_emit_pixel;
    integer next_emit_tap;
    integer next2_emit_pixel;
    integer next2_emit_tap;
    integer next3_emit_pixel;
    integer next3_emit_tap;
    integer next_emit_mem_index;
    integer next2_emit_mem_index;
    integer next3_emit_mem_index;
    integer emit_lane;
    reg signed [(LANES*8)-1:0] prefetch_vec;

    function integer token_mem_index;
        input integer pixel_arg;
        input integer tap_arg;
        integer ty, tx, py, px;
        begin
            if ((STRIDE == 1) && (TILE_W == 8)) begin
                py = pixel_arg >> 3;
                px = pixel_arg & 7;
                case (tap_arg)
                    0: token_mem_index = py*FOOTPRINT_W + px;
                    1: token_mem_index = py*FOOTPRINT_W + px + 1;
                    2: token_mem_index = py*FOOTPRINT_W + px + 2;
                    3: token_mem_index = (py+1)*FOOTPRINT_W + px;
                    4: token_mem_index = (py+1)*FOOTPRINT_W + px + 1;
                    5: token_mem_index = (py+1)*FOOTPRINT_W + px + 2;
                    6: token_mem_index = (py+2)*FOOTPRINT_W + px;
                    7: token_mem_index = (py+2)*FOOTPRINT_W + px + 1;
                    default: token_mem_index = (py+2)*FOOTPRINT_W + px + 2;
                endcase
            end else begin
                py = pixel_arg / TILE_W;
                px = pixel_arg - py * TILE_W;
                ty = tap_arg / 3;
                tx = tap_arg - ty * 3;
                token_mem_index = (py * STRIDE + ty) * FOOTPRINT_W +
                                  px * STRIDE + tx;
            end
        end
    endfunction

    /* A registered token stage decouples the local-store mux from the direct
     * DSP ingress.  When the previous token is accepted, the next one is
     * loaded at the same edge and is visible for the following cycle. */
    always @* begin
        emit_mem_index = token_mem_index(emit_pixel_count, emit_tap_count);
        if (emit_tap_count == 8) begin
            next_emit_pixel = emit_pixel_count + 1;
            next_emit_tap = 0;
        end else begin
            next_emit_pixel = emit_pixel_count;
            next_emit_tap = emit_tap_count + 1;
        end
        next2_emit_pixel = emit_pixel_count;
        next2_emit_tap = emit_tap_count + 2;
        if (next2_emit_tap >= 9) begin
            next2_emit_tap = next2_emit_tap - 9;
            next2_emit_pixel = next2_emit_pixel + 1;
        end
        next3_emit_pixel = emit_pixel_count;
        next3_emit_tap = emit_tap_count + 3;
        if (next3_emit_tap >= 9) begin
            next3_emit_tap = next3_emit_tap - 9;
            next3_emit_pixel = next3_emit_pixel + 1;
        end
        next_emit_mem_index = token_mem_index(next_emit_pixel, next_emit_tap);
        next2_emit_mem_index = token_mem_index(next2_emit_pixel,
                                               next2_emit_tap);
        next3_emit_mem_index = token_mem_index(next3_emit_pixel,
                                               next3_emit_tap);
        prefetch_vec = {(LANES*8){1'b0}};
        if (prefetch_addr < FOOTPRINT_PIXELS) begin
            prefetch_vec = local_mem_vec[prefetch_addr];
            for (emit_lane = 0; emit_lane < LANES; emit_lane = emit_lane + 1)
                if (!lane_mask_reg[emit_lane])
                    prefetch_vec[(emit_lane*8) +: 8] = 8'sd0;
        end
    end

    wire dw_ready_in;
    wire dw_input_fire = token_valid && dw_ready_in;
    wire dw_output_fire = valid_out && ready_out;

    reg signed [127:0] sched_weight_mem [0:8];
    reg signed [127:0] prefetch_weight_next;
    always @* begin
        if (prefetch_tap_addr < 9)
            prefetch_weight_next = sched_weight_mem[prefetch_tap_addr];
        else
            prefetch_weight_next = 128'sd0;
    end

    dw_direct_3x3_dsp_prefetched u_dw (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx),
        .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec),
        .valid_in(token_valid),
        .ready_in(dw_ready_in),
        .first_tap(token_first),
        .last_tap(token_last),
        .tap_idx(token_tap_idx),
        .pixel_idx(token_pixel_idx),
        .lane_mask(token_lane_mask),
        .act_vec(token_act_vec),
        .weight_vec(token_weight_vec),
        .valid_out(valid_out),
        .ready_out(ready_out),
        .out_pixel_idx(out_pixel_idx),
        .out_lane_mask(out_lane_mask),
        .out_raw_vec(out_raw_vec),
        .out_bias_vec(out_bias_vec),
        .out_multiplier_vec(out_multiplier_vec),
        .out_shift_vec(out_shift_vec)
    );

    integer li;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            issue_count <= {READ_COUNT_WIDTH{1'b0}};
            capture_count <= {READ_COUNT_WIDTH{1'b0}};
            local_wr_addr_reg <= {READ_COUNT_WIDTH{1'b0}};
            channel_tile_reg <= 9'd0;
            lane_mask_reg <= 16'd0;
            emit_pixel_count <= 6'd0;
            emit_tap_count <= 4'd0;
            token_valid <= 1'b0;
            token_first <= 1'b0;
            token_last <= 1'b0;
            token_tap_idx <= 4'd0;
            token_pixel_idx <= 8'd0;
            token_lane_mask <= 16'd0;
            token_act_vec <= {(LANES*8){1'b0}};
            token_weight_vec <= 128'sd0;
            prefetch_addr <= {READ_COUNT_WIDTH{1'b0}};
            prefetch_data_vec <= {(LANES*8){1'b0}};
            prefetch_weight_vec <= 128'sd0;
            prefetch_tap_addr <= 4'd0;
            prefetch_valid <= 1'b0;
            for (li = 0; li < 9; li = li + 1)
                sched_weight_mem[li] <= 128'sd0;
            buffer_read_count <= 16'd0;
            core_token_count <= 16'd0;
            output_count <= 8'd0;
        end else begin
            done <= 1'b0;

            if (cfg_valid && cfg_ready && (cfg_tap_idx < 9))
                sched_weight_mem[cfg_tap_idx] <= cfg_weight_vec;

            if (dw_output_fire)
                output_count <= output_count + 1'b1;

            if (state == ST_IDLE) begin
                busy <= 1'b0;
                token_valid <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    state <= ST_FILL;
                        issue_count <= {READ_COUNT_WIDTH{1'b0}};
                    capture_count <= {READ_COUNT_WIDTH{1'b0}};
                    local_wr_addr_reg <= {READ_COUNT_WIDTH{1'b0}};
                    channel_tile_reg <= start_channel_tile;
                    lane_mask_reg <= start_lane_mask;
                    buffer_read_count <= 16'd0;
                    core_token_count <= 16'd0;
                        output_count <= 8'd0;
                        prefetch_valid <= 1'b0;
                end
            end

            if (state == ST_FILL) begin
                if (buffer_rd_en) begin
                    issue_count <= issue_count + 1'b1;
                    buffer_read_count <= buffer_read_count + 1'b1;
                end
                if (buffer_rd_valid && (capture_count < FOOTPRINT_PIXELS)) begin
                    local_mem_vec[local_wr_addr_reg] <= buffer_rd_data;
                    local_wr_addr_reg <= local_wr_addr_reg + 1'b1;
                    capture_count <= capture_count + 1'b1;
                    if ((capture_count + 1'b1) >= FOOTPRINT_PIXELS) begin
                        state <= ST_PREFETCH_ADDR;
                        emit_pixel_count <= 6'd0;
                        emit_tap_count <= 4'd0;
                        token_valid <= 1'b0;
                    end
                end
            end

            if (state == ST_PREFETCH_ADDR) begin
                /* Register the first local-store address before reading its
                 * data.  This cuts the emit counter -> LUTRAM -> token path
                 * and gives the prefetch stage a regular one-word/cycle arc. */
                prefetch_addr <= emit_mem_index;
                prefetch_tap_addr <= emit_tap_count;
                prefetch_valid <= 1'b0;
                state <= ST_EMIT;
            end

            if (state == ST_EMIT) begin
                if (!token_valid) begin
                    if (!prefetch_valid) begin
                        /* First cycle performs the registered local-store
                         * read.  The following cycle consumes it. */
                        prefetch_data_vec <= prefetch_vec;
                        prefetch_weight_vec <= prefetch_weight_next;
                        prefetch_addr <= next_emit_mem_index;
                        prefetch_tap_addr <= next_emit_tap;
                        prefetch_valid <= 1'b1;
                    end else begin
                        token_valid <= 1'b1;
                        token_first <= (emit_tap_count == 0);
                        token_last <= (emit_tap_count == 8);
                        token_tap_idx <= emit_tap_count;
                        token_pixel_idx <= emit_pixel_count;
                        token_lane_mask <= lane_mask_reg;
                        token_act_vec <= prefetch_data_vec;
                        token_weight_vec <= prefetch_weight_vec;
                        /* Keep one asynchronous local-store read in flight;
                         * its result is consumed on the next edge. */
                        prefetch_data_vec <= prefetch_vec;
                        prefetch_weight_vec <= prefetch_weight_next;
                        prefetch_addr <= next2_emit_mem_index;
                        prefetch_tap_addr <= next2_emit_tap;
                    end
                end else if (dw_ready_in) begin
                    core_token_count <= core_token_count + 1'b1;
                    if ((emit_pixel_count == OUTPUT_PIXELS-1) &&
                        (emit_tap_count == 8)) begin
                        token_valid <= 1'b0;
                        state <= ST_DRAIN;
                    end else begin
                        if (emit_tap_count == 8) begin
                            emit_tap_count <= 4'd0;
                            emit_pixel_count <= emit_pixel_count + 1'b1;
                        end else begin
                            emit_tap_count <= emit_tap_count + 1'b1;
                        end
                        token_first <= (emit_tap_count == 7);
                        token_last <= (emit_tap_count == 7);
                        /* Metadata below is for the newly loaded token. */
                        if (emit_tap_count == 8) begin
                            token_first <= 1'b1;
                            token_last <= 1'b0;
                            token_tap_idx <= 4'd0;
                            token_pixel_idx <= emit_pixel_count + 1'b1;
                        end else begin
                            token_first <= 1'b0;
                            token_last <= (emit_tap_count == 7);
                            token_tap_idx <= emit_tap_count + 1'b1;
                            token_pixel_idx <= emit_pixel_count;
                        end
                        token_lane_mask <= lane_mask_reg;
                        token_act_vec <= prefetch_data_vec;
                        token_weight_vec <= prefetch_weight_vec;
                        prefetch_data_vec <= prefetch_vec;
                        prefetch_weight_vec <= prefetch_weight_next;
                        prefetch_addr <= next3_emit_mem_index;
                        prefetch_tap_addr <= next3_emit_tap;
                        prefetch_valid <= 1'b1;
                    end
                end
            end

            if (state == ST_DRAIN) begin
                busy <= 1'b1;
                if (dw_output_fire) begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    state <= ST_IDLE;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (STRIDE < 1 || STRIDE > 2)
            $error("dw_window_reuse_scheduler supports STRIDE=1 or 2");
        if (TILE_H != 8 || TILE_W != 8)
            $error("prototype contract assumes an 8x8 output tile");
        if (LANES != 16)
            $error("prototype contract assumes sixteen DW lanes");
    end
`endif
endmodule

`default_nettype wire
