`timescale 1ns/1ps
`default_nettype none

/*
 * Four-local-island replacement for ds_dw_requant_stream4_write_adapter.
 *
 * The external protocol is deliberately unchanged: one sixteen-lane DW
 * result is accepted and drained as four four-lane writes, in lane order.
 * The old adapter kept a 512-bit record in one block and selected a 128-bit
 * slice with a live issue counter.  That creates a wide, high-fanout
 * issue/enable and variable-slice data cone.  Here each island owns one
 * 128-bit quartet, its mask, multiplier/shift record, and output tag.  The
 * only common signal at the ingress is the one-bit bundle acceptance; the
 * island-local fire then drives only that island's registers.
 *
 * Each island has four exact requant_activation_unit instances (16 DSPs in
 * total), a one-entry registered beat output, and no arithmetic change.
 * Island outputs are retired by a shallow round-robin serializer.  Since a
 * bundle is single-outstanding, all islands are lockstep before retirement;
 * arbitrary output backpressure therefore freezes only the selected local
 * beat and cannot reorder lanes.
 */
module ds_dw_requant_stream4_write_adapter_local (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire [5:0] pixel_idx_in,
    input wire [15:0] lane_mask_in,
    input wire signed [511:0] raw_vec_in,
    input wire signed [511:0] multiplier_vec_in,
    input wire [95:0] shift_vec_in,
    input wire signed [31:0] output_zero_point,
    input wire signed [31:0] activation_min,
    input wire signed [31:0] activation_max,
    output wire valid_out, input wire ready_out,
    output wire [5:0] pixel_idx_out,
    output wire [1:0] lane_base_out,
    output wire [31:0] data_out,
    output wire [3:0] lane_mask_out,
    output wire busy
);
    wire [3:0] island_ready;
    wire [3:0] island_valid;
    wire [3:0] island_busy;
    wire [5:0] island_pixel [0:3];
    wire [1:0] island_lane_base [0:3];
    wire [31:0] island_data [0:3];
    wire [3:0] island_mask [0:3];
    wire [3:0] island_ready_out;

    reg bundle_active;
    reg [1:0] retire_idx;

    /* The distributor is intentionally shallow: valid_in is observed by
     * four island ports only.  The islands capture their own records on the
     * same bundle handshake and thereafter use local enables. */
    wire bundle_ready = !bundle_active &&
                        island_ready[0] && island_ready[1] &&
                        island_ready[2] && island_ready[3];
    wire bundle_fire = valid_in && bundle_ready;
    assign ready_in = rst_n && bundle_ready;

    assign valid_out = bundle_active && island_valid[retire_idx];
    assign pixel_idx_out = island_pixel[retire_idx];
    assign lane_base_out = island_lane_base[retire_idx];
    assign data_out = island_data[retire_idx];
    assign lane_mask_out = island_mask[retire_idx];
    assign busy = bundle_active || island_busy[0] || island_busy[1] ||
                  island_busy[2] || island_busy[3];

    genvar q;
    generate
        for (q = 0; q < 4; q = q + 1) begin : gen_local_island
            (* KEEP_HIERARCHY = "yes" *)
            ds_dw_requant_stream4_local_island #(.LANE_BASE(q[1:0])) u_island (
                .clk(clk), .rst_n(rst_n),
                .valid_in(bundle_fire), .ready_in(island_ready[q]),
                .pixel_idx_in(pixel_idx_in),
                .lane_mask_in(lane_mask_in[(q*4) +: 4]),
                .raw_vec_in(raw_vec_in[(q*128) +: 128]),
                .multiplier_vec_in(multiplier_vec_in[(q*128) +: 128]),
                .shift_vec_in(shift_vec_in[(q*24) +: 24]),
                .output_zero_point(output_zero_point),
                .activation_min(activation_min),
                .activation_max(activation_max),
                .ready_out(island_ready_out[q]),
                .valid_out(island_valid[q]),
                .pixel_idx_out(island_pixel[q]),
                .lane_base_out(island_lane_base[q]),
                .data_out(island_data[q]),
                .lane_mask_out(island_mask[q]), .busy(island_busy[q])
            );
        end
    endgenerate

    /* Only the selected island sees the external ready signal.  This
     * produces four independent local backpressure enables instead of a
     * shared live data/control enable across all result registers. */
    assign island_ready_out[0] = ready_out && bundle_active && (retire_idx == 2'd0);
    assign island_ready_out[1] = ready_out && bundle_active && (retire_idx == 2'd1);
    assign island_ready_out[2] = ready_out && bundle_active && (retire_idx == 2'd2);
    assign island_ready_out[3] = ready_out && bundle_active && (retire_idx == 2'd3);

    wire retire_fire = valid_out && ready_out;
    always @(posedge clk) begin
        if (!rst_n) begin
            bundle_active <= 1'b0;
            retire_idx <= 2'd0;
        end else begin
            if (bundle_fire) begin
                bundle_active <= 1'b1;
                retire_idx <= 2'd0;
            end else if (retire_fire) begin
                if (retire_idx == 2'd3)
                    bundle_active <= 1'b0;
                else
                    retire_idx <= retire_idx + 1'b1;
            end
        end
    end
endmodule

/* One physically local quartet.  One exact scalar requant unit is
 * time-multiplexed across the four captured lanes; consequently four local
 * islands retain the original sixteen-DSP requant budget (not 64 DSPs).
 * The 4:1 selects below are only 32-bit local quartet selects, after the
 * ingress record has already been captured. */
module ds_dw_requant_stream4_local_island #(
    parameter [1:0] LANE_BASE = 2'd0
) (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire [5:0] pixel_idx_in,
    input wire [3:0] lane_mask_in,
    input wire signed [127:0] raw_vec_in,
    input wire signed [127:0] multiplier_vec_in,
    input wire [23:0] shift_vec_in,
    input wire signed [31:0] output_zero_point,
    input wire signed [31:0] activation_min,
    input wire signed [31:0] activation_max,
    input wire ready_out, output wire valid_out,
    output wire [5:0] pixel_idx_out,
    output wire [1:0] lane_base_out,
    output wire [31:0] data_out,
    output wire [3:0] lane_mask_out,
    output wire busy
);
    localparam [1:0] ST_IDLE = 2'd0, ST_ISSUE = 2'd1,
                     ST_COLLECT = 2'd2, ST_OUTPUT = 2'd3;
    reg [1:0] state;
    reg [2:0] issue_idx;
    reg [2:0] collect_idx;
    (* max_fanout = 64 *) reg [5:0] pixel_reg;
    (* max_fanout = 64 *) reg [3:0] mask_reg;
    reg signed [127:0] raw_reg;
    reg signed [127:0] multiplier_reg;
    reg [23:0] shift_reg;
    reg signed [31:0] zp_reg, min_reg, max_reg;

    wire core_ready_in;
    wire core_valid_out;
    wire signed [7:0] core_data;
    wire core_valid_in = (state == ST_ISSUE);
    wire core_ready_out = (state == ST_ISSUE) || (state == ST_COLLECT);
    wire core_input_fire = core_valid_in && core_ready_in;
    wire core_output_fire = core_valid_out && (state == ST_COLLECT);
    reg signed [31:0] packed_data;

    assign ready_in = rst_n && (state == ST_IDLE);
    assign valid_out = (state == ST_OUTPUT);
    assign pixel_idx_out = pixel_reg;
    assign lane_base_out = LANE_BASE;
    assign data_out = packed_data;
    assign lane_mask_out = mask_reg;
    assign busy = (state != ST_IDLE);

    requant_activation_unit u_core (
        .clk(clk), .rst_n(rst_n), .valid_in(core_valid_in),
        .ready_in(core_ready_in),
        .acc_int32(raw_reg[(issue_idx*32) +: 32]),
        .bias_int32(32'sd0),
        .multiplier_int32(multiplier_reg[(issue_idx*32) +: 32]),
        .shift(shift_reg[(issue_idx*6) +: 6]),
        .output_zero_point_int32(zp_reg),
        .activation_min_int32(min_reg),
        .activation_max_int32(max_reg),
        .ready_out(core_ready_out), .valid_out(core_valid_out),
        .output_int8(core_data)
    );

    /* Encourage physical replication of the local ingress enable at the
     * quartet boundary.  This is deliberately scoped per island; unlike the
     * former adapter, no one 512-bit record enable is allowed to span all
     * four quartets. */
    (* max_fanout = 64 *) wire input_fire = valid_in && ready_in;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            issue_idx <= 3'd0;
            collect_idx <= 3'd0;
            pixel_reg <= 6'd0; mask_reg <= 4'd0;
            raw_reg <= 128'sd0; multiplier_reg <= 128'sd0;
            shift_reg <= 24'd0;
            zp_reg <= 32'sd0; min_reg <= 32'sd0; max_reg <= 32'sd0;
            packed_data <= 32'sd0;
        end else begin
            if (input_fire) begin
                state <= ST_ISSUE;
                issue_idx <= 3'd0;
                collect_idx <= 3'd0;
                pixel_reg <= pixel_idx_in;
                mask_reg <= lane_mask_in;
                raw_reg <= raw_vec_in;
                multiplier_reg <= multiplier_vec_in;
                shift_reg <= shift_vec_in;
                zp_reg <= output_zero_point;
                min_reg <= activation_min;
                max_reg <= activation_max;
            end

            if (core_input_fire) begin
                if (issue_idx == 3'd3) begin
                    collect_idx <= 3'd0;
                    state <= ST_COLLECT;
                end else begin
                    issue_idx <= issue_idx + 1'b1;
                end
            end

            if (core_output_fire) begin
                packed_data[(collect_idx*8) +: 8] <= core_data;
                if (collect_idx == 3'd3)
                    state <= ST_OUTPUT;
                else
                    collect_idx <= collect_idx + 1'b1;
            end

            if ((state == ST_OUTPUT) && ready_out) begin
                state <= ST_IDLE;
            end
        end
    end
endmodule

`default_nettype wire
