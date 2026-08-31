`timescale 1ns/1ps
`default_nettype none

/*
 * Isolated, transaction-level DS partial-K prototype.
 *
 * This module is deliberately not the production DS engine.  It defines the
 * smallest unambiguous ABI needed to test the dataflow change:
 *
 *   - ACT writes contain one byte of a flattened 3x3 window per output pixel
 *     and input channel: ((pixel * 9 + tap) * MAX_CIN + k).
 *   - DW_W writes contain one signed int8 depthwise coefficient at k*9+tap.
 *   - DW_B writes contain one signed int32 depthwise bias at k.
 *   - PW_W writes contain one signed int8 coefficient at k*MAX_COUT+cout.
 *
 * A job consumes one 8-pixel by 8-output-channel tile at a time.  The DW
 * worker computes one complete 8-pixel activation vector for K, then hands
 * that vector directly to the output-stationary PW array.  It does not first
 * compute all DW channels or wait for a complete DW tile.  Consequently K
 * group 0 is accepted by PW while DW is still computing group 1.  The PW
 * token carries first_k/last_k and a non-zero k_count; group boundaries are
 * informational only and never clear, requantize, or publish the psum.
 *
 * DW output in this prototype is the exact signed int32 depthwise sum plus
 * bias, saturated to int8.  PW output is the exact signed int32 psum.  This
 * intentionally keeps quantization parameters out of the ABI so this test
 * isolates the K-group/fence dataflow rather than silently substituting a
 * different production parameter layout.
 */
module ds_block_tile_engine_partialk #(
    parameter integer MAX_CIN = 48,
    parameter integer MAX_COUT = 16,
    parameter integer MAX_PIXELS = 17,
    parameter integer K_GROUP = 16
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         cfg_valid,
    output wire                         cfg_ready,
    input  wire [1:0]                   cfg_target,
    input  wire [15:0]                  cfg_index,
    input  wire [31:0]                  cfg_data,

    input  wire                         start,
    input  wire [7:0]                   start_cin,
    input  wire [7:0]                   start_pixels,
    input  wire [8:0]                   start_cout,
    input  wire [1:0]                   start_stride,
    output reg                          busy,
    output reg                          done,
    output reg                          error,

    output reg                          out_valid,
    input  wire                         out_ready,
    output reg [7:0]                    out_pixel_base,
    output reg [8:0]                    out_cout_base,
    output reg [63:0]                   out_lane_mask,
    output reg signed [2047:0]          out_psum,

    output reg [31:0]                   perf_total_cycles,
    output reg [31:0]                   perf_dw_cycles,
    output reg [31:0]                   perf_pw_issue_cycles,
    output reg [31:0]                   perf_transfer_wait_cycles,
    output reg [31:0]                   perf_output_tiles,
    output reg [1:0]                    perf_stride
);
    localparam [1:0] CFG_ACT = 2'd0;
    localparam [1:0] CFG_DW_W = 2'd1;
    localparam [1:0] CFG_DW_B = 2'd2;
    localparam [1:0] CFG_PW_W = 2'd3;

    localparam [3:0] ST_IDLE = 4'd0;
    localparam [3:0] ST_DW_START = 4'd1;
    localparam [3:0] ST_DW_READ = 4'd2;
    localparam [3:0] ST_DW_MUL = 4'd3;
    localparam [3:0] ST_DW_ACC = 4'd4;
    localparam [3:0] ST_DW_TOKEN = 4'd5;
    localparam [3:0] ST_PW_DRAIN = 4'd6;
    localparam [3:0] ST_OUTPUT = 4'd7;
    localparam [3:0] ST_DONE = 4'd8;

    /* These are byte-addressed logical memories.  Explicit distributed RAM
     * is suitable for this bounded prototype and, importantly, keeps the
     * storage contract visible in the testbench rather than hiding a seeded
     * DW result behind the PW input. */
    (* ram_style = "distributed" *) reg signed [7:0] act_mem [0:(MAX_PIXELS*9*MAX_CIN)-1];
    (* ram_style = "distributed" *) reg signed [7:0] dw_weight_mem [0:(MAX_CIN*9)-1];
    (* ram_style = "distributed" *) reg signed [31:0] dw_bias_mem [0:MAX_CIN-1];
    (* ram_style = "distributed" *) reg signed [7:0] pw_weight_mem [0:(MAX_CIN*MAX_COUT)-1];

    reg [7:0] cin_reg;
    reg [7:0] pixels_reg;
    reg [8:0] cout_reg;
    reg [1:0] stride_reg;
    reg [7:0] pixel_base;
    reg [8:0] cout_base;
    reg [7:0] k_idx;
    reg [3:0] pixel_slot;
    reg [3:0] tap_idx;
    reg signed [31:0] dw_acc;
    reg signed [63:0] dw_vec;
    reg signed [7:0] act_reg;
    reg signed [7:0] dw_wgt_reg;
    reg signed [15:0] product_reg;
    reg [3:0] state;

    wire cfg_fire = cfg_valid && cfg_ready;
    assign cfg_ready = rst_n && !busy;

    /* The narrow PW ABI is exactly the one independently validated by the
     * partial-K PW test.  Nonexistent tail pixels/channels are zeroed by the
     * DW vector and weight vector respectively, but remain part of the fixed
     * 8x8 transaction and are reported through out_lane_mask. */
    wire pw_ready_in;
    wire pw_valid_out;
    wire signed [2047:0] pw_psum_out;
    wire pw_token_valid = (state == ST_DW_TOKEN);
    wire pw_token_first = (k_idx == 8'd0);
    wire pw_token_last = (k_idx == (cin_reg - 8'd1));
    wire [7:0] pw_token_group = k_idx >> 4;
    wire [7:0] pw_token_count =
        (((k_idx & 8'h0f) + K_GROUP) <= cin_reg)
            ? K_GROUP[7:0] : (cin_reg - (k_idx & 8'h0f));
    wire pw_token_fire = pw_token_valid && pw_ready_in;

    reg signed [63:0] pw_wgt_vec;
    integer wg;
    always @* begin
        pw_wgt_vec = 64'sd0;
        for (wg = 0; wg < 8; wg = wg + 1) begin
            if ((cout_base + wg) < cout_reg)
                pw_wgt_vec[(wg*8) +: 8] =
                    pw_weight_mem[(k_idx * MAX_COUT) + cout_base + wg];
        end
    end

    /* One full 8x8 output-stationary block. */
    pw_systolic_array_8x8 u_pw (
        .clk(clk), .rst_n(rst_n),
        .valid_in(pw_token_valid), .ready_in(pw_ready_in),
        .first_k(pw_token_first), .last_k(pw_token_last),
        .k_group(pw_token_group), .k_count(pw_token_count),
        .clear_acc(1'b0), .k_last(1'b0),
        .act_vec(dw_vec), .wgt_vec(pw_wgt_vec),
        .ready_out(out_valid && out_ready),
        .valid_out(pw_valid_out), .psum_out(pw_psum_out)
    );

    /* The output is held in this wrapper while the consumer is stopped. */
    wire pw_capture = (state == ST_PW_DRAIN) && pw_valid_out && !out_valid;
    wire out_fire = out_valid && out_ready;

    integer act_addr;
    reg signed [7:0] act_tmp;
    reg signed [7:0] dw_wgt_tmp;
    reg signed [15:0] product_tmp;
    reg signed [32:0] final_sum_tmp;
    integer lane;
    integer cfg_addr;

    function signed [7:0] saturate_int8;
        input signed [32:0] value;
        begin
            if (value > 33'sd127)
                saturate_int8 = 8'sd127;
            else if (value < -33'sd128)
                saturate_int8 = -8'sd128;
            else
                saturate_int8 = value[7:0];
        end
    endfunction

    /* Keep the mask and tile cursor narrow and registered at the output
     * boundary.  The combinational expressions here are not on the PE or
     * DW arithmetic path. */
    reg [63:0] tile_mask_next;
    integer mr;
    integer mc;
    always @* begin
        tile_mask_next = 64'd0;
        for (mr = 0; mr < 8; mr = mr + 1)
            for (mc = 0; mc < 8; mc = mc + 1)
                if (((pixel_base + mr) < pixels_reg) &&
                    ((cout_base + mc) < cout_reg))
                    tile_mask_next[(mr*8)+mc] = 1'b1;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            out_valid <= 1'b0;
            out_pixel_base <= 8'd0;
            out_cout_base <= 9'd0;
            out_lane_mask <= 64'd0;
            out_psum <= 2048'sd0;
            perf_total_cycles <= 32'd0;
            perf_dw_cycles <= 32'd0;
            perf_pw_issue_cycles <= 32'd0;
            perf_transfer_wait_cycles <= 32'd0;
            perf_output_tiles <= 32'd0;
            perf_stride <= 2'd0;
            cin_reg <= 8'd0;
            pixels_reg <= 8'd0;
            cout_reg <= 9'd0;
            stride_reg <= 2'd0;
            pixel_base <= 8'd0;
            cout_base <= 9'd0;
            k_idx <= 8'd0;
            pixel_slot <= 4'd0;
            tap_idx <= 4'd0;
            dw_acc <= 32'sd0;
            dw_vec <= 64'sd0;
            act_reg <= 8'sd0;
            dw_wgt_reg <= 8'sd0;
            product_reg <= 16'sd0;
            state <= ST_IDLE;
        end else begin
            if (cfg_fire) begin
                cfg_addr = cfg_index;
                case (cfg_target)
                    CFG_ACT: if (cfg_addr < MAX_PIXELS*9*MAX_CIN)
                        act_mem[cfg_addr] <= cfg_data[7:0];
                    CFG_DW_W: if (cfg_addr < MAX_CIN*9)
                        dw_weight_mem[cfg_addr] <= cfg_data[7:0];
                    CFG_DW_B: if (cfg_addr < MAX_CIN)
                        dw_bias_mem[cfg_addr] <= cfg_data;
                    CFG_PW_W: if (cfg_addr < MAX_CIN*MAX_COUT)
                        pw_weight_mem[cfg_addr] <= cfg_data[7:0];
                    default: error <= 1'b1;
                endcase
            end

            if (busy)
                perf_total_cycles <= perf_total_cycles + 1;

            if (start && !busy && (start_cin != 0) && (start_pixels != 0) &&
                (start_cout != 0) && (start_cin <= MAX_CIN) &&
                (start_pixels <= MAX_PIXELS) && (start_cout <= MAX_COUT)) begin
                busy <= 1'b1;
                done <= 1'b0;
                error <= 1'b0;
                out_valid <= 1'b0;
                cin_reg <= start_cin;
                pixels_reg <= start_pixels;
                cout_reg <= start_cout;
                stride_reg <= start_stride;
                perf_stride <= start_stride;
                perf_total_cycles <= 32'd0;
                perf_dw_cycles <= 32'd0;
                perf_pw_issue_cycles <= 32'd0;
                perf_transfer_wait_cycles <= 32'd0;
                perf_output_tiles <= 32'd0;
                pixel_base <= 8'd0;
                cout_base <= 9'd0;
                k_idx <= 8'd0;
                state <= ST_DW_START;
            end else if (start && !busy) begin
                error <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    /* Configuration and a new start are handled above. */
                end
                ST_DW_START: begin
                    pixel_slot <= 4'd0;
                    tap_idx <= 4'd0;
                    dw_acc <= 32'sd0;
                    state <= ST_DW_READ;
                end
                /* Address/memory output is isolated from the multiplier. */
                ST_DW_READ: begin
                    perf_dw_cycles <= perf_dw_cycles + 1;
                    if ((pixel_base + pixel_slot) < pixels_reg)
                        act_addr = (((pixel_base + pixel_slot) * 9 + tap_idx) * MAX_CIN) + k_idx;
                    else
                        act_addr = 0;
                    if ((pixel_base + pixel_slot) < pixels_reg)
                        act_tmp = act_mem[act_addr];
                    else
                        act_tmp = 8'sd0;
                    dw_wgt_tmp = dw_weight_mem[(k_idx * 9) + tap_idx];
                    act_reg <= act_tmp;
                    dw_wgt_reg <= dw_wgt_tmp;
                    state <= ST_DW_MUL;
                end
                /* Keep the signed 8x8 product on a short registered path. */
                ST_DW_MUL: begin
                    product_reg <= $signed({{8{act_reg[7]}}, act_reg}) *
                                   $signed({{8{dw_wgt_reg[7]}}, dw_wgt_reg});
                    state <= ST_DW_ACC;
                end
                /* The accumulator carry chain is a separate cycle from the
                 * product and from the distributed-memory address mux. */
                ST_DW_ACC: begin
                    if (tap_idx == 0) begin
                        dw_acc <= $signed(product_reg) + dw_bias_mem[k_idx];
                        tap_idx <= 1;
                        state <= ST_DW_READ;
                    end else if (tap_idx == 8) begin
                        final_sum_tmp = $signed(dw_acc) + $signed(product_reg);
                        if ((pixel_base + pixel_slot) < pixels_reg)
                            dw_vec[(pixel_slot*8) +: 8] <= saturate_int8(final_sum_tmp);
                        else
                            dw_vec[(pixel_slot*8) +: 8] <= 8'sd0;
                        if (pixel_slot == 7) begin
                            state <= ST_DW_TOKEN;
                        end else begin
                            pixel_slot <= pixel_slot + 1;
                            tap_idx <= 0;
                            dw_acc <= 32'sd0;
                            state <= ST_DW_READ;
                        end
                    end else begin
                        dw_acc <= dw_acc + $signed(product_reg);
                        tap_idx <= tap_idx + 1;
                        state <= ST_DW_READ;
                    end
                end
                ST_DW_TOKEN: begin
                    if (pw_token_fire) begin
                        perf_pw_issue_cycles <= perf_pw_issue_cycles + 1;
                        if (pw_token_last) begin
                            state <= ST_PW_DRAIN;
                        end else begin
                            k_idx <= k_idx + 1;
                            state <= ST_DW_START;
                        end
                    end else begin
                        perf_transfer_wait_cycles <= perf_transfer_wait_cycles + 1;
                    end
                end
                ST_PW_DRAIN: begin
                    if (pw_capture) begin
                        out_pixel_base <= pixel_base;
                        out_cout_base <= cout_base;
                        out_lane_mask <= tile_mask_next;
                        out_psum <= pw_psum_out;
                        out_valid <= 1'b1;
                        perf_output_tiles <= perf_output_tiles + 1;
                        state <= ST_OUTPUT;
                    end
                end
                ST_OUTPUT: begin
                    if (out_fire) begin
                        out_valid <= 1'b0;
                        k_idx <= 8'd0;
                        if ((cout_base + 8) < cout_reg) begin
                            cout_base <= cout_base + 8;
                            state <= ST_DW_START;
                        end else if ((pixel_base + 8) < pixels_reg) begin
                            cout_base <= 9'd0;
                            pixel_base <= pixel_base + 8;
                            state <= ST_DW_START;
                        end else begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_DONE;
                        end
                    end
                end
                ST_DONE: begin
                    /* done is sticky until the next accepted start. */
                end
                default: begin
                    error <= 1'b1;
                    busy <= 1'b0;
                    state <= ST_DONE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
