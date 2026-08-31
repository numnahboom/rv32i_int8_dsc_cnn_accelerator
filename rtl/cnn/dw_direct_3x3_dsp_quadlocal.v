`timescale 1ns/1ps
`default_nettype none

/*
 * Four-quad physical variant of the prefetched sixteen-lane DW core.
 *
 * The external ABI is identical to dw_direct_3x3_dsp_prefetched.  The
 * sixteen lanes are split into four independent four-lane accumulator
 * islands.  Each island captures its own valid/first/last/pixel/mask and
 * operand records at ingress, and its own bias/multiplier/shift state at the
 * configuration handshake.  Only the four local DSP cells see those
 * records; the top-level buses cross the boundary once at the four-quad
 * ingress.  This is deliberately a non-production physical experiment.
 */
module dw_direct_3x3_dsp_quadlocal (
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
    input  wire signed [127:0]           act_vec,
    input  wire signed [127:0]           weight_vec,
    output wire                         valid_out,
    input  wire                         ready_out,
    output wire [7:0]                   out_pixel_idx,
    output wire [15:0]                  out_lane_mask,
    output wire signed [511:0]          out_raw_vec,
    output wire signed [511:0]          out_bias_vec,
    output wire signed [511:0]          out_multiplier_vec,
    output wire [95:0]                  out_shift_vec
);
    wire [3:0] q_cfg_ready;
    wire [3:0] q_ready_in;
    wire [3:0] q_valid_out;
    wire [7:0] q_pixel [0:3];
    wire [3:0] q_lane_mask [0:3];
    wire signed [127:0] q_raw [0:3];
    wire signed [127:0] q_bias [0:3];
    wire signed [127:0] q_multiplier [0:3];
    wire [23:0] q_shift [0:3];

    /* A single accepted token is admitted only when all quads can accept it.
     * The four-way reduction is intentionally at the boundary; all stateful
     * token controls below it are quad-local. */
    assign cfg_ready = rst_n && q_cfg_ready[0] && q_cfg_ready[1] &&
                       q_cfg_ready[2] && q_cfg_ready[3];
    assign ready_in = rst_n && q_ready_in[0] && q_ready_in[1] &&
                      q_ready_in[2] && q_ready_in[3];
    /* All quads are lockstep by construction.  ANDing valid_out retains a
     * fail-closed interface if a simulation protocol error desynchronizes an
     * island, while the four-term cone is local and shallow. */
    assign valid_out = q_valid_out[0] && q_valid_out[1] &&
                       q_valid_out[2] && q_valid_out[3];
    assign out_pixel_idx = q_pixel[0];
    assign out_lane_mask = {q_lane_mask[3], q_lane_mask[2],
                            q_lane_mask[1], q_lane_mask[0]};
    assign out_raw_vec = {q_raw[3], q_raw[2], q_raw[1], q_raw[0]};
    assign out_bias_vec = {q_bias[3], q_bias[2], q_bias[1], q_bias[0]};
    assign out_multiplier_vec = {q_multiplier[3], q_multiplier[2],
                                 q_multiplier[1], q_multiplier[0]};
    assign out_shift_vec = {q_shift[3], q_shift[2], q_shift[1], q_shift[0]};

    genvar q;
    generate
        for (q = 0; q < 4; q = q + 1) begin : gen_quad
            dw_direct_3x3_dsp_quadlocal_lane4 u_quad (
                .clk(clk), .rst_n(rst_n),
                .cfg_valid(cfg_valid), .cfg_ready(q_cfg_ready[q]),
                .cfg_tap_idx(cfg_tap_idx),
                .cfg_weight_vec(cfg_weight_vec[(q*32) +: 32]),
                .cfg_bias_vec(cfg_bias_vec[(q*128) +: 128]),
                .cfg_multiplier_vec(cfg_multiplier_vec[(q*128) +: 128]),
                .cfg_shift_vec(cfg_shift_vec[(q*24) +: 24]),
                .valid_in(valid_in), .ready_in(q_ready_in[q]),
                .first_tap(first_tap), .last_tap(last_tap),
                .tap_idx(tap_idx), .pixel_idx(pixel_idx),
                .lane_mask(lane_mask[(q*4) +: 4]),
                .act_vec(act_vec[(q*32) +: 32]),
                .weight_vec(weight_vec[(q*32) +: 32]),
                .valid_out(q_valid_out[q]), .ready_out(ready_out),
                .out_pixel_idx(q_pixel[q]),
                .out_lane_mask(q_lane_mask[q]), .out_raw_vec(q_raw[q]),
                .out_bias_vec(q_bias[q]),
                .out_multiplier_vec(q_multiplier[q]),
                .out_shift_vec(q_shift[q])
            );
        end
    endgenerate
endmodule

/* One physically local four-lane accumulator/control quad. */
module dw_direct_3x3_dsp_quadlocal_lane4 (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         cfg_valid,
    output wire                         cfg_ready,
    input  wire [3:0]                   cfg_tap_idx,
    input  wire signed [31:0]           cfg_weight_vec,
    input  wire signed [127:0]          cfg_bias_vec,
    input  wire signed [127:0]          cfg_multiplier_vec,
    input  wire [23:0]                  cfg_shift_vec,
    input  wire                         valid_in,
    output wire                         ready_in,
    input  wire                         first_tap,
    input  wire                         last_tap,
    input  wire [3:0]                   tap_idx,
    input  wire [7:0]                   pixel_idx,
    input  wire [3:0]                   lane_mask,
    input  wire signed [31:0]            act_vec,
    input  wire signed [31:0]            weight_vec,
    output reg                          valid_out,
    input  wire                         ready_out,
    output reg [7:0]                    out_pixel_idx,
    output reg [3:0]                    out_lane_mask,
    output reg signed [127:0]            out_raw_vec,
    output reg signed [127:0]            out_bias_vec,
    output reg signed [127:0]            out_multiplier_vec,
    output reg [23:0]                   out_shift_vec
);
    reg signed [127:0] bias_reg;
    reg signed [127:0] multiplier_reg;
    reg [23:0] shift_reg;

    /* These records are the explicit ingress-to-quad physical boundary. */
    (* max_fanout = 8 *) reg pipe_valid;
    reg pipe_first;
    reg pipe_last;
    reg [7:0] pipe_pixel_idx;
    reg [3:0] pipe_lane_mask;
    reg signed [31:0] act_pipe;
    reg signed [31:0] weight_pipe;

    wire cfg_idle = !pipe_valid && !valid_out;
    assign cfg_ready = rst_n && cfg_idle;
    /* Keep separate enables for the bias and scale state.  Vivado otherwise
     * merges the identical handshake expression and fans one cfg_fire net
     * into all 280 configuration flops in this quad. */
    (* KEEP = "TRUE" *) wire cfg_bias_fire = cfg_valid && cfg_ready;
    (* KEEP = "TRUE" *) wire cfg_scale_fire = cfg_valid && cfg_ready;
    wire input_fire = valid_in && ready_in;
    wire stage_fire = pipe_valid;
    assign ready_in = rst_n && !pipe_last && ((!valid_out) || ready_out);

    wire signed [31:0] sum_next [0:3];
    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : gen_lane
            dw_direct_3x3_mac_cell u_mac (
                .clk(clk), .rst_n(rst_n), .en(stage_fire),
                .clear_acc(pipe_first),
                .act_in(act_pipe[(lane*8) +: 8]),
                .wgt_in(weight_pipe[(lane*8) +: 8]),
                .bias_in(bias_reg[(lane*32) +: 32]),
                .sum_next(sum_next[lane])
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
            out_lane_mask <= 4'd0;
            out_raw_vec <= 128'sd0;
            out_bias_vec <= 128'sd0;
            out_multiplier_vec <= 128'sd0;
            out_shift_vec <= 24'd0;
            pipe_valid <= 1'b0;
            pipe_first <= 1'b0;
            pipe_last <= 1'b0;
            pipe_pixel_idx <= 8'd0;
            pipe_lane_mask <= 4'd0;
            act_pipe <= 32'sd0;
            weight_pipe <= 32'sd0;
            bias_reg <= 128'sd0;
            multiplier_reg <= 128'sd0;
            shift_reg <= 24'd0;
`ifndef SYNTHESIS
            sim_next_tap <= 0;
            sim_protocol_errors <= 0;
`endif
        end else begin
            if (valid_out && ready_out)
                valid_out <= 1'b0;

            if (cfg_bias_fire) begin
                bias_reg <= cfg_bias_vec;
            end
            if (cfg_scale_fire) begin
                /* Weight is supplied per token; accepting the weight slice
                 * keeps the configuration ABI and handshake identical to the
                 * prefetched core. */
                multiplier_reg <= cfg_multiplier_vec;
                shift_reg <= cfg_shift_vec;
            end

            if (stage_fire && pipe_last) begin
                out_pixel_idx <= pipe_pixel_idx;
                out_lane_mask <= pipe_lane_mask;
                out_bias_vec <= bias_reg;
                out_multiplier_vec <= multiplier_reg;
                out_shift_vec <= shift_reg;
                for (li = 0; li < 4; li = li + 1) begin
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
                /* Mask at each quad's registered operand ingress. */
                for (li = 0; li < 4; li = li + 1)
                    act_pipe[(li*8) +: 8] <= lane_mask[li]
                        ? act_vec[(li*8) +: 8] : 8'sd0;
                weight_pipe <= weight_vec;
`ifndef SYNTHESIS
                if ((first_tap && (tap_idx != 0)) ||
                    (!first_tap && (tap_idx != sim_next_tap))) begin
                    $display("DW_QUAD_ASSERT tap=%0d expected=%0d first=%b",
                             tap_idx, sim_next_tap, first_tap);
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
