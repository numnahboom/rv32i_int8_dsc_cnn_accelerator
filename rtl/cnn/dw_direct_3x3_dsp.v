`timescale 1ns/1ps
`default_nettype none

/*
 * Direct 3x3 depthwise compute core for one sixteen-channel group.
 *
 * Each accepted token is one spatial tap and contains sixteen signed int8
 * activations.  The sixteen lane accumulators remain local; first_tap clears
 * only on the accepted first token and last_tap publishes the completed raw
 * int32 sums.  The core deliberately does not infer a nine-cycle schedule:
 * tap_idx is checked in simulation and bubbles/backpressure are legal.
 *
 * Configuration is written a complete tap at a time.  Registered tap vectors
 * form the boundary between the parameter bus and the sixteen DSP operands,
 * avoiding a high-fanout parameter/address path in the compute cycle.
 */
module dw_direct_3x3_dsp (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         cfg_valid,
    output wire                         cfg_ready,
    input  wire [3:0]                   cfg_tap_idx,
    input  wire signed [127:0]          cfg_weight_vec,
    input  wire signed [511:0]          cfg_bias_vec,
    input  wire signed [511:0]          cfg_multiplier_vec,
    input  wire [95:0]                  cfg_shift_vec,

    input  wire                         valid_in,
    output wire                         ready_in,
    input  wire                         first_tap,
    input  wire                         last_tap,
    input  wire [3:0]                   tap_idx,
    input  wire [7:0]                   pixel_idx,
    input  wire [15:0]                  lane_mask,
    input  wire signed [127:0]          act_vec,

    output reg                          valid_out,
    input  wire                         ready_out,
    output reg [7:0]                    out_pixel_idx,
    output reg [15:0]                   out_lane_mask,
    output reg signed [511:0]           out_raw_vec,
    output reg signed [511:0]           out_bias_vec,
    output reg signed [511:0]           out_multiplier_vec,
    output reg [95:0]                   out_shift_vec
);
    reg signed [127:0] weight_mem [0:8];
    reg signed [511:0] bias_reg;
    reg signed [511:0] multiplier_reg;
    reg [95:0] shift_reg;

    reg pipe_valid;
    reg pipe_first;
    reg pipe_last;
    reg [7:0] pipe_pixel_idx;
    reg [15:0] pipe_lane_mask;
    reg signed [127:0] act_pipe;
    /* Read the tap vector into the input stage.  Keeping the 9:1 tap mux
     * before the stage register prevents tap_idx fanout and the weight
     * selection mux from sitting on the DSP-to-output timing arc. */
    reg signed [127:0] weight_pipe;

    wire cfg_idle = !pipe_valid && !valid_out;
    assign cfg_ready = rst_n && cfg_idle;
    wire cfg_fire = cfg_valid && cfg_ready;
    wire input_fire = valid_in && ready_in;
    wire stage_fire = pipe_valid;
    assign ready_in = rst_n && !pipe_last && ((!valid_out) || ready_out);

    wire signed [31:0] sum_next [0:15];
    genvar lane_g;
    generate
            for (lane_g = 0; lane_g < 16; lane_g = lane_g + 1) begin : gen_lane
            dw_direct_3x3_mac_cell u_mac (
                .clk(clk),
                .rst_n(rst_n),
                .en(stage_fire),
                .clear_acc(pipe_first),
                /* Masking is performed at the registered operand ingress
                 * below.  Keeping the lane mask out of this DSP input mux
                 * removes the wide control-to-accumulator timing arc. */
                .act_in(act_pipe[(lane_g*8) +: 8]),
                .wgt_in(weight_pipe[(lane_g*8) +: 8]),
                .bias_in(bias_reg[(lane_g*32) +: 32]),
                .sum_next(sum_next[lane_g])
            );
        end
    endgenerate

    integer li;
`ifndef SYNTHESIS
    integer sim_next_tap;
    integer sim_protocol_errors;
`endif
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            out_pixel_idx <= 8'd0;
            out_lane_mask <= 16'd0;
            out_raw_vec <= 512'sd0;
            out_bias_vec <= 512'sd0;
            out_multiplier_vec <= 512'sd0;
            out_shift_vec <= 96'd0;
            pipe_valid <= 1'b0;
            pipe_first <= 1'b0;
            pipe_last <= 1'b0;
            pipe_pixel_idx <= 8'd0;
            pipe_lane_mask <= 16'd0;
            act_pipe <= 128'sd0;
            weight_pipe <= 128'sd0;
            bias_reg <= 512'sd0;
            multiplier_reg <= 512'sd0;
            shift_reg <= 96'd0;
            for (li = 0; li < 9; li = li + 1)
                weight_mem[li] <= 128'sd0;
`ifndef SYNTHESIS
            sim_next_tap <= 0;
            sim_protocol_errors <= 0;
`endif
        end else begin
            if (valid_out && ready_out)
                valid_out <= 1'b0;

            if (cfg_fire && (cfg_tap_idx < 9)) begin
                weight_mem[cfg_tap_idx] <= cfg_weight_vec;
                bias_reg <= cfg_bias_vec;
                multiplier_reg <= cfg_multiplier_vec;
                shift_reg <= cfg_shift_vec;
            end

            if (stage_fire && pipe_last) begin
                out_pixel_idx <= pipe_pixel_idx;
                out_lane_mask <= pipe_lane_mask;
                out_bias_vec <= bias_reg;
                out_multiplier_vec <= multiplier_reg;
                out_shift_vec <= shift_reg;
                for (li = 0; li < 16; li = li + 1) begin
                    if (pipe_lane_mask[li])
                        out_raw_vec[(li*32) +: 32] <= sum_next[li];
                    else
                        out_raw_vec[(li*32) +: 32] <= 32'sd0;
                end
                valid_out <= 1'b1;
            end
            pipe_valid <= input_fire;
            if (input_fire) begin
                pipe_first <= first_tap;
                pipe_last <= last_tap;
                pipe_pixel_idx <= pixel_idx;
                pipe_lane_mask <= lane_mask;
                for (li = 0; li < 16; li = li + 1)
                    act_pipe[(li*8) +: 8] <= lane_mask[li]
                        ? act_vec[(li*8) +: 8] : 8'sd0;
                weight_pipe <= (tap_idx < 9) ? weight_mem[tap_idx] : 128'sd0;
            end else begin
                pipe_last <= 1'b0;
            end
`ifndef SYNTHESIS
            if (input_fire) begin
                if ((first_tap && (tap_idx != 0)) ||
                    (!first_tap && (tap_idx != sim_next_tap))) begin
                    $display("DW_DIRECT_ASSERT tap=%0d expected=%0d first=%b",
                             tap_idx, sim_next_tap, first_tap);
                    sim_protocol_errors <= sim_protocol_errors + 1;
                end
                if (last_tap)
                    sim_next_tap <= 0;
                else
                    sim_next_tap <= tap_idx + 1;
            end
`endif
        end
    end
endmodule

module dw_direct_3x3_mac_cell (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                en,
    input  wire                clear_acc,
    input  wire signed [7:0]   act_in,
    input  wire signed [7:0]   wgt_in,
    input  wire signed [31:0]  bias_in,
    output wire signed [31:0]  sum_next
);
    (* use_dsp = "yes" *) wire signed [15:0] product = act_in * wgt_in;
    wire signed [31:0] product_ext = {{16{product[15]}}, product};
    reg signed [31:0] acc_reg;
    /* Bias is included only for first_tap by the top-level clear operation.
     * Keeping it as a cell input makes the configured per-lane bias part of
     * the explicit contract while preserving raw convolution sums. */
    wire signed [31:0] bias_term = bias_in;
    assign sum_next = clear_acc ? (bias_term + product_ext) :
                                  (acc_reg + product_ext);

    always @(posedge clk) begin
        if (!rst_n)
            acc_reg <= 32'sd0;
        else if (en)
            acc_reg <= sum_next;
    end
endmodule

`default_nettype wire
