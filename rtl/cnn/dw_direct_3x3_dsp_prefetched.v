`timescale 1ns/1ps
`default_nettype none

/*
 * Window-reuse variant of the direct DW core.  The tap weight vector is
 * supplied with each token by a registered producer-side prefetch stage;
 * this removes the tap-index fanout and 9:1 weight-memory mux from the
 * producer-to-DSP timing arc.  The arithmetic and fixed-point contract is
 * identical to dw_direct_3x3_dsp.
 */
module dw_direct_3x3_dsp_prefetched (
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
    input  wire signed [127:0]          weight_vec,
    output reg                          valid_out,
    input  wire                         ready_out,
    output reg [7:0]                    out_pixel_idx,
    output reg [15:0]                   out_lane_mask,
    output reg signed [511:0]           out_raw_vec,
    output reg signed [511:0]           out_bias_vec,
    output reg signed [511:0]           out_multiplier_vec,
    output reg [95:0]                   out_shift_vec
);
    reg signed [511:0] bias_reg;
    reg signed [511:0] multiplier_reg;
    reg [95:0] shift_reg;
    (* max_fanout = 32 *) reg pipe_valid;
    reg pipe_first;
    reg pipe_last;
    reg [7:0] pipe_pixel_idx;
    reg [15:0] pipe_lane_mask;
    reg signed [127:0] act_pipe;
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
                .clk(clk), .rst_n(rst_n), .en(stage_fire),
                .clear_acc(pipe_first),
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
`ifndef SYNTHESIS
            sim_next_tap <= 0;
            sim_protocol_errors <= 0;
`endif
        end else begin
            if (valid_out && ready_out)
                valid_out <= 1'b0;
            if (cfg_fire) begin
                /* cfg_weight_vec is retained at the producer; accepting it
                 * here keeps the same externally visible configuration
                 * handshake as the original direct core. */
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
                for (li = 0; li < 16; li = li + 1)
                    if (pipe_lane_mask[li])
                        out_raw_vec[(li*32) +: 32] <= sum_next[li];
                    else
                        out_raw_vec[(li*32) +: 32] <= 32'sd0;
                valid_out <= 1'b1;
            end
            pipe_valid <= input_fire;
            if (input_fire) begin
                pipe_first <= first_tap;
                pipe_last <= last_tap;
                pipe_pixel_idx <= pixel_idx;
                pipe_lane_mask <= lane_mask;
                act_pipe <= act_vec;
                weight_pipe <= weight_vec;
`ifndef SYNTHESIS
                if ((first_tap && (tap_idx != 0)) ||
                    (!first_tap && (tap_idx != sim_next_tap))) begin
                    sim_protocol_errors <= sim_protocol_errors + 1;
                end
                if (last_tap)
                    sim_next_tap <= 0;
                else
                    sim_next_tap <= tap_idx + 1;
`endif
            end else begin
                pipe_last <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
