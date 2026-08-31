`timescale 1ns/1ps
`default_nettype none

/*
 * Reusable sixteen-lane signed int8 streaming MAC.
 *
 * The operation-specific adapters own operand staging and present a fixed
 * lane-wise contract to this module.  There is intentionally no operation
 * mode or operand-shape mux in the core: each lane is one registered-input
 * int8 multiply followed by a signed int32 accumulation.  A first_token
 * seeds all lanes and a last_token publishes the next sums, including the
 * last token.  A masked lane contributes no product and is published as
 * zero on the corresponding output lane.
 */
module mac16_stream_core (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         valid_in,
    output wire                         ready_in,
    input  wire                         first_token,
    input  wire                         last_token,
    input  wire                         op_mode,
    input  wire [7:0]                   token_idx,
    input  wire [15:0]                  lane_mask,
    input  wire signed [127:0]           act_vec,
    input  wire signed [127:0]           wgt_vec,
    input  wire                         ready_out,
    output reg                          valid_out,
    output reg [7:0]                    token_idx_out,
    output reg [15:0]                   lane_mask_out,
    output reg                          op_mode_out,
    output reg signed [511:0]           sum_out
);
    reg signed [31:0] acc [0:15];

    wire input_fire = valid_in && ready_in;
    reg pipe_valid;
    reg pipe_first;
    reg pipe_last;
    reg pipe_mode;
    reg [7:0] pipe_token_idx;
    reg [15:0] pipe_lane_mask;
    reg signed [15:0] pipe_product [0:15];
    /* A registered product boundary keeps DSP output and accumulation in
     * separate cycles while preserving one-token-per-cycle throughput. */
    assign ready_in = rst_n && (!valid_out || ready_out);
    wire pipe_fire = pipe_valid && (!valid_out || ready_out);

    wire signed [15:0] raw_product [0:15];
    wire signed [15:0] lane_product [0:15];
    wire signed [31:0] pipe_product_ext [0:15];
    wire signed [31:0] sum_next [0:15];

    genvar lane_g;
    generate
        for (lane_g = 0; lane_g < 16; lane_g = lane_g + 1) begin : gen_lane
            /* Keep multiply unconditional so Vivado can infer DSPs; mask at
             * the registered product boundary instead. */
            (* use_dsp = "yes" *)
            wire signed [15:0] lane_raw_product =
                $signed(act_vec[(lane_g*8) +: 8]) *
                $signed(wgt_vec[(lane_g*8) +: 8]);
            assign raw_product[lane_g] = lane_raw_product;
            assign lane_product[lane_g] = lane_mask[lane_g]
                ? raw_product[lane_g] : 16'sd0;
            assign pipe_product_ext[lane_g] =
                {{16{pipe_product[lane_g][15]}}, pipe_product[lane_g]};
            assign sum_next[lane_g] = pipe_first
                ? pipe_product_ext[lane_g]
                : (pipe_lane_mask[lane_g]
                   ? (acc[lane_g] + pipe_product_ext[lane_g])
                   : acc[lane_g]);
        end
    endgenerate

    integer lane_i;
`ifndef SYNTHESIS
    integer sim_protocol_errors;
    integer sim_accept_count;
    integer sim_output_count;
    integer sim_last_count;
    reg [7:0] sim_expected_idx;
    reg       sim_transaction_active;
`endif

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            token_idx_out <= 8'd0;
            lane_mask_out <= 16'd0;
            op_mode_out <= 1'b0;
            sum_out <= 512'sd0;
            pipe_valid <= 1'b0;
            pipe_first <= 1'b0;
            pipe_last <= 1'b0;
            pipe_mode <= 1'b0;
            pipe_token_idx <= 8'd0;
            pipe_lane_mask <= 16'd0;
            for (lane_i = 0; lane_i < 16; lane_i = lane_i + 1)
                pipe_product[lane_i] <= 16'sd0;
            for (lane_i = 0; lane_i < 16; lane_i = lane_i + 1)
                acc[lane_i] <= 32'sd0;
`ifndef SYNTHESIS
            sim_protocol_errors <= 0;
            sim_accept_count <= 0;
            sim_output_count <= 0;
            sim_last_count <= 0;
            sim_expected_idx <= 8'd0;
            sim_transaction_active <= 1'b0;
`endif
        end else begin
            if (valid_out && ready_out) begin
                valid_out <= 1'b0;
`ifndef SYNTHESIS
                sim_output_count <= sim_output_count + 1;
`endif
            end

            if (pipe_fire) begin
                for (lane_i = 0; lane_i < 16; lane_i = lane_i + 1)
                    acc[lane_i] <= sum_next[lane_i];

                if (pipe_last) begin
                    token_idx_out <= pipe_token_idx;
                    lane_mask_out <= pipe_lane_mask;
                    op_mode_out <= pipe_mode;
                    for (lane_i = 0; lane_i < 16; lane_i = lane_i + 1) begin
                        if (pipe_lane_mask[lane_i])
                            sum_out[(lane_i*32) +: 32] <= sum_next[lane_i];
                        else
                            sum_out[(lane_i*32) +: 32] <= 32'sd0;
                    end
                    valid_out <= 1'b1;
                end
            end

            if (input_fire) begin
                pipe_valid <= 1'b1;
                pipe_first <= first_token;
                pipe_last <= last_token;
                pipe_mode <= op_mode;
                pipe_token_idx <= token_idx;
                pipe_lane_mask <= lane_mask;
                for (lane_i = 0; lane_i < 16; lane_i = lane_i + 1)
                    pipe_product[lane_i] <= lane_product[lane_i];
            end else if (pipe_fire) begin
                pipe_valid <= 1'b0;
            end
`ifndef SYNTHESIS
            if (input_fire) begin
                sim_accept_count <= sim_accept_count + 1;
                if (first_token) begin
                    if (sim_transaction_active || (token_idx != 8'd0)) begin
                        $display("MAC16_ASSERT bad_first token=%0d active=%b",
                                 token_idx, sim_transaction_active);
                        sim_protocol_errors <= sim_protocol_errors + 1;
                    end
                end else if (!sim_transaction_active ||
                             (token_idx != sim_expected_idx)) begin
                    $display("MAC16_ASSERT token=%0d expected=%0d active=%b",
                             token_idx, sim_expected_idx, sim_transaction_active);
                    sim_protocol_errors <= sim_protocol_errors + 1;
                end
                if (last_token) begin
                    sim_last_count <= sim_last_count + 1;
                    sim_transaction_active <= 1'b0;
                    sim_expected_idx <= 8'd0;
                end else begin
                    sim_transaction_active <= 1'b1;
                    sim_expected_idx <= token_idx + 8'd1;
                end
            end
`endif
        end
    end
endmodule

`default_nettype wire
