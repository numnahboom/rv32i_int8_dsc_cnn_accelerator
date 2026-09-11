`timescale 1ns/1ps
`default_nettype none

/*
 * Direct output-stationary 8x8 pointwise block.
 *
 * One accepted token represents one K position.  The 8 activation bytes are
 * shared by eight output-channel multipliers, producing 64 signed int8 MACs
 * per token.  The accumulators stay local to the block; unlike the replay
 * implementation, no K vector is written to an intermediate RAM.  A token
 * with first_k set seeds the accumulators and a token with last_k set captures
 * the completed sums.  Group boundaries are deliberately not interpreted as
 * completion boundaries: a caller may split a reduction arbitrarily while
 * keeping first_k/last_k at the whole-reduction boundaries.
 *
 * pixel_mask and cout_mask are per-token masks.  A masked activation or
 * output channel contributes zero to the corresponding MACs.  At last_k the
 * same masks select which output lanes are published; masked lanes are
 * explicitly zeroed.  The output transaction is a one-entry elastic buffer.
 */
module pw_direct_8x8_dsp (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 valid_in,
    output wire                 ready_in,
    input  wire                 first_k,
    input  wire                 last_k,
    input  wire [7:0]           k_idx,
    input  wire [7:0]           pixel_mask,
    input  wire [7:0]           cout_mask,
    input  wire signed [63:0]   act_vec,
    input  wire signed [63:0]   wgt_vec,
    input  wire                 ready_out,
    output reg                  valid_out,
    output reg  signed [2047:0] psum_out,
    output reg  [63:0]          lane_mask_out
);
    wire fire = valid_in && ready_in;
    reg                 pipe_valid;
    reg                 pipe_last;
    reg                 pipe_first;
    reg signed [63:0]   act_pipe;
    reg signed [63:0]   wgt_pipe;
    reg [7:0]           pixel_mask_pipe;
    reg [7:0]           cout_mask_pipe;
    wire stage_fire = pipe_valid;

    /* A token can replace a consumed output in the same cycle. */
    /* The one-token input stage is part of the elastic protocol.  Once a
     * last token is staged, stop accepting until its accumulated result has
     * been published; this prevents a following block from updating the
     * same local psums before the final token is captured. */
    assign ready_in = rst_n && !pipe_last && ((!valid_out) || ready_out);

    /* The cell owns each accumulator register; the top only consumes its
     * registered next-sum value at the final token. */
    wire signed [31:0] psum_next [0:7][0:7];

    genvar r;
    genvar c;
    generate
        for (r = 0; r < 8; r = r + 1) begin : gen_rows
            for (c = 0; c < 8; c = c + 1) begin : gen_cols
                pw_direct_mac_cell u_mac (
                    .clk(clk),
                    .rst_n(rst_n),
                    .en(stage_fire),
                    .clear_acc(pipe_first),
                    .act_in(act_pipe[(r*8) +: 8]),
                    .wgt_in(wgt_pipe[(c*8) +: 8]),
                    .sum_next(psum_next[r][c])
                );
            end
        end
    endgenerate

    integer i;
    integer j;
`ifndef SYNTHESIS
    integer sim_next_k_idx;
    integer sim_protocol_errors;
    /* Simulation-only semantic ledger: each accepted K token contains the
     * eight activation by eight output-channel products. */
    integer sim_mac_count;
`endif
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            psum_out <= 2048'sd0;
            lane_mask_out <= 64'd0;
            pipe_valid <= 1'b0;
            pipe_last <= 1'b0;
            pipe_first <= 1'b0;
            act_pipe <= 64'sd0;
            wgt_pipe <= 64'sd0;
            pixel_mask_pipe <= 8'd0;
            cout_mask_pipe <= 8'd0;
`ifndef SYNTHESIS
            sim_next_k_idx <= 0;
            sim_protocol_errors <= 0;
            sim_mac_count <= 0;
`endif
        end else begin
            if (valid_out && ready_out)
                valid_out <= 1'b0;

            if (stage_fire && pipe_last) begin
                /* sum_next includes this accepted token, including the
                 * first_k seed when Cin is one. */
                for (i = 0; i < 8; i = i + 1) begin
                    for (j = 0; j < 8; j = j + 1) begin
                        lane_mask_out[(i*8) + j] <= pixel_mask_pipe[i] && cout_mask_pipe[j];
                        if (pixel_mask_pipe[i] && cout_mask_pipe[j])
                            psum_out[(((i*8) + j)*32) +: 32] <= psum_next[i][j];
                        else
                            psum_out[(((i*8) + j)*32) +: 32] <= 32'sd0;
                    end
                end
                valid_out <= 1'b1;
            end
            /* Register operands and narrow control before the DSP48 cells.
             * This preserves one accepted K token per cycle while separating
             * BRAM/configuration routing from the multiply-accumulate path. */
            pipe_valid <= fire;
            if (fire) begin
`ifndef SYNTHESIS
                sim_mac_count <= sim_mac_count + 64;
`endif
                act_pipe <= act_vec;
                wgt_pipe <= wgt_vec;
                pipe_first <= first_k;
                pipe_last <= last_k;
                pixel_mask_pipe <= pixel_mask;
                cout_mask_pipe <= cout_mask;
            end else begin
                pipe_last <= 1'b0;
            end
`ifndef SYNTHESIS
            if (fire) begin
                if ((first_k && (k_idx != 0)) ||
                    (!first_k && (k_idx != sim_next_k_idx))) begin
                    $display("PW_DIRECT_ASSERT k_idx=%0d expected=%0d first=%b",
                             k_idx, sim_next_k_idx, first_k);
                    sim_protocol_errors <= sim_protocol_errors + 1;
                end
                if (last_k)
                    sim_next_k_idx <= 0;
                else
                    sim_next_k_idx <= k_idx + 1;
            end
`endif
        end
    end
endmodule

/*
 * Keep the multiply and accumulator in one small registered cell.  Vivado's
 * use_dsp directive is intentional: this candidate is a physical DSP48
 * screen, not a LUT multiplier disguised as a functional model.
 */
module pw_direct_mac_cell (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                en,
    input  wire                clear_acc,
    input  wire signed [7:0]   act_in,
    input  wire signed [7:0]   wgt_in,
    output wire signed [31:0]  sum_next
);
    (* use_dsp = "yes" *) wire signed [15:0] product = act_in * wgt_in;
    wire signed [31:0] product_ext = {{16{product[15]}}, product};
    reg signed [31:0] psum_reg;
    assign sum_next = clear_acc ? product_ext : (psum_reg + product_ext);

    always @(posedge clk) begin
        if (!rst_n)
            psum_reg <= 32'sd0;
        else if (en)
            psum_reg <= sum_next;
    end
endmodule

`default_nettype wire
