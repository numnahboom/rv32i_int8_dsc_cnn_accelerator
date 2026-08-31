`timescale 1ns/1ps
`default_nettype none

module mac16_stem_adapter (
    input wire clk, input wire rst_n, input wire valid_in, output wire ready_in,
    input wire first_token, input wire last_token, input wire [7:0] token_idx,
    input wire [15:0] lane_mask, input wire signed [7:0] act_scalar,
    input wire signed [127:0] weight_vec, input wire ready_out,
    output wire valid_out, output wire first_token_out, output wire last_token_out,
    output wire [7:0] token_idx_out, output wire [15:0] lane_mask_out,
    output wire signed [127:0] act_vec_out, output wire signed [127:0] weight_vec_out
);
    reg stage_valid, stage_first, stage_last;
    reg [7:0] stage_token_idx;
    reg [15:0] stage_lane_mask;
    reg signed [7:0] stage_act_scalar;
    reg signed [127:0] stage_weight_vec;
    wire source_fire = valid_in && ready_in;
    assign ready_in = rst_n && (!stage_valid || ready_out);
    assign valid_out = stage_valid;
    assign first_token_out = stage_first;
    assign last_token_out = stage_last;
    assign token_idx_out = stage_token_idx;
    assign lane_mask_out = stage_lane_mask;
    assign act_vec_out = {16{stage_act_scalar}};
    assign weight_vec_out = stage_weight_vec;
    always @(posedge clk) begin
        if (!rst_n) begin
            stage_valid <= 1'b0;
            stage_first <= 1'b0;
            stage_last <= 1'b0;
            stage_token_idx <= 8'd0;
            stage_lane_mask <= 16'd0;
            stage_act_scalar <= 8'sd0;
            stage_weight_vec <= 128'sd0;
        end else if (source_fire) begin
            stage_valid <= 1'b1;
            stage_first <= first_token;
            stage_last <= last_token;
            stage_token_idx <= token_idx;
            stage_lane_mask <= lane_mask;
            stage_act_scalar <= act_scalar;
            stage_weight_vec <= weight_vec;
        end else if (stage_valid && ready_out) begin
            stage_valid <= 1'b0;
        end
    end
endmodule

module mac16_dw_adapter (
    input wire clk, input wire rst_n, input wire valid_in, output wire ready_in,
    input wire first_token, input wire last_token, input wire [7:0] token_idx,
    input wire [15:0] lane_mask, input wire signed [127:0] act_vec,
    input wire signed [127:0] weight_vec, input wire ready_out,
    output wire valid_out, output wire first_token_out, output wire last_token_out,
    output wire [7:0] token_idx_out, output wire [15:0] lane_mask_out,
    output wire signed [127:0] act_vec_out, output wire signed [127:0] weight_vec_out
);
    reg stage_valid, stage_first, stage_last;
    reg [7:0] stage_token_idx;
    reg [15:0] stage_lane_mask;
    reg signed [127:0] stage_act_vec, stage_weight_vec;
    wire source_fire = valid_in && ready_in;
    assign ready_in = rst_n && (!stage_valid || ready_out);
    assign valid_out = stage_valid;
    assign first_token_out = stage_first;
    assign last_token_out = stage_last;
    assign token_idx_out = stage_token_idx;
    assign lane_mask_out = stage_lane_mask;
    assign act_vec_out = stage_act_vec;
    assign weight_vec_out = stage_weight_vec;
    always @(posedge clk) begin
        if (!rst_n) begin
            stage_valid <= 1'b0;
            stage_first <= 1'b0;
            stage_last <= 1'b0;
            stage_token_idx <= 8'd0;
            stage_lane_mask <= 16'd0;
            stage_act_vec <= 128'sd0;
            stage_weight_vec <= 128'sd0;
        end else if (source_fire) begin
            stage_valid <= 1'b1;
            stage_first <= first_token;
            stage_last <= last_token;
            stage_token_idx <= token_idx;
            stage_lane_mask <= lane_mask;
            stage_act_vec <= act_vec;
            stage_weight_vec <= weight_vec;
        end else if (stage_valid && ready_out) begin
            stage_valid <= 1'b0;
        end
    end
endmodule

/* One shared 16-lane core.  Operand mapping is registered in the adapters
 * before this selector; only the already-registered vectors are selected. */
module mac16_stream_shared_wrapper (
    input wire clk, input wire rst_n,
    input wire stem_valid_in, output wire stem_ready_in,
    input wire stem_first_token, input wire stem_last_token,
    input wire [7:0] stem_token_idx, input wire [15:0] stem_lane_mask,
    input wire signed [7:0] stem_act_scalar,
    input wire signed [127:0] stem_weight_vec, input wire stem_ready_out,
    output wire stem_valid_out, output wire [7:0] stem_token_idx_out,
    output wire [15:0] stem_lane_mask_out, output wire signed [511:0] stem_sum_out,
    input wire dw_valid_in, output wire dw_ready_in,
    input wire dw_first_token, input wire dw_last_token,
    input wire [7:0] dw_token_idx, input wire [15:0] dw_lane_mask,
    input wire signed [127:0] dw_act_vec, input wire signed [127:0] dw_weight_vec,
    input wire dw_ready_out, output wire dw_valid_out,
    output wire [7:0] dw_token_idx_out, output wire [15:0] dw_lane_mask_out,
    output wire signed [511:0] dw_sum_out
);
    wire stem_valid, stem_ready, stem_source_ready, stem_first, stem_last;
    wire [7:0] stem_idx; wire [15:0] stem_mask;
    wire signed [127:0] stem_act, stem_weight;
    wire dw_valid, dw_ready, dw_source_ready, dw_first, dw_last;
    wire [7:0] dw_idx; wire [15:0] dw_mask;
    wire signed [127:0] dw_act, dw_weight;
    reg mode_active, mode_latched;
    wire selected_mode = mode_active ? mode_latched : (stem_valid ? 1'b0 : 1'b1);
    wire selected_valid = selected_mode ? dw_valid : stem_valid;
    wire core_ready_in;
    wire core_input_fire = selected_valid && core_ready_in;
    assign stem_ready = core_ready_in && !selected_mode;
    assign dw_ready = core_ready_in && selected_mode;
    assign stem_ready_in = stem_source_ready;
    assign dw_ready_in = dw_source_ready;

    mac16_stem_adapter u_stem (
        .clk(clk), .rst_n(rst_n), .valid_in(stem_valid_in), .ready_in(stem_source_ready),
        .first_token(stem_first_token), .last_token(stem_last_token),
        .token_idx(stem_token_idx), .lane_mask(stem_lane_mask),
        .act_scalar(stem_act_scalar), .weight_vec(stem_weight_vec), .ready_out(stem_ready),
        .valid_out(stem_valid), .first_token_out(stem_first), .last_token_out(stem_last),
        .token_idx_out(stem_idx), .lane_mask_out(stem_mask), .act_vec_out(stem_act),
        .weight_vec_out(stem_weight)
    );
    mac16_dw_adapter u_dw (
        .clk(clk), .rst_n(rst_n), .valid_in(dw_valid_in), .ready_in(dw_source_ready),
        .first_token(dw_first_token), .last_token(dw_last_token),
        .token_idx(dw_token_idx), .lane_mask(dw_lane_mask), .act_vec(dw_act_vec),
        .weight_vec(dw_weight_vec), .ready_out(dw_ready), .valid_out(dw_valid),
        .first_token_out(dw_first), .last_token_out(dw_last), .token_idx_out(dw_idx),
        .lane_mask_out(dw_mask), .act_vec_out(dw_act), .weight_vec_out(dw_weight)
    );
    wire selected_first = selected_mode ? dw_first : stem_first;
    wire selected_last = selected_mode ? dw_last : stem_last;
    wire [7:0] selected_idx = selected_mode ? dw_idx : stem_idx;
    wire [15:0] selected_mask = selected_mode ? dw_mask : stem_mask;
    wire signed [127:0] selected_act = selected_mode ? dw_act : stem_act;
    wire signed [127:0] selected_weight = selected_mode ? dw_weight : stem_weight;
    wire core_valid_out, core_mode_out;
    wire [7:0] core_idx_out; wire [15:0] core_mask_out;
    wire signed [511:0] core_sum_out;
    wire core_ready_out = core_valid_out ?
        (core_mode_out ? dw_ready_out : stem_ready_out) : 1'b1;
    mac16_stream_core u_core (
        .clk(clk), .rst_n(rst_n), .valid_in(selected_valid), .ready_in(core_ready_in),
        .first_token(selected_first), .last_token(selected_last), .op_mode(selected_mode),
        .token_idx(selected_idx), .lane_mask(selected_mask), .act_vec(selected_act),
        .wgt_vec(selected_weight), .ready_out(core_ready_out), .valid_out(core_valid_out),
        .token_idx_out(core_idx_out), .lane_mask_out(core_mask_out),
        .op_mode_out(core_mode_out), .sum_out(core_sum_out)
    );
    assign stem_valid_out = core_valid_out && !core_mode_out;
    assign stem_token_idx_out = core_idx_out;
    assign stem_lane_mask_out = core_mask_out;
    assign stem_sum_out = core_sum_out;
    assign dw_valid_out = core_valid_out && core_mode_out;
    assign dw_token_idx_out = core_idx_out;
    assign dw_lane_mask_out = core_mask_out;
    assign dw_sum_out = core_sum_out;

`ifndef SYNTHESIS
    integer mode_change_errors;
    reg mode_change_seen;
`endif
    always @(posedge clk) begin
        if (!rst_n) begin
            mode_active <= 1'b0;
            mode_latched <= 1'b0;
`ifndef SYNTHESIS
            mode_change_errors <= 0;
            mode_change_seen <= 1'b0;
`endif
        end else begin
`ifndef SYNTHESIS
            if (!mode_active) begin
                mode_change_seen <= 1'b0;
            end else if ((mode_latched == 1'b0 && dw_valid) ||
                         (mode_latched == 1'b1 && stem_valid)) begin
                if (!mode_change_seen) begin
                    mode_change_errors <= mode_change_errors + 1;
                    $display("MAC16_ASSERT attempted_mode_change active_mode=%b", mode_latched);
                    mode_change_seen <= 1'b1;
                end
            end else begin
                mode_change_seen <= 1'b0;
            end
`endif
            if (core_input_fire) begin
                if (!mode_active)
                    mode_latched <= selected_mode;
                mode_active <= !selected_last;
            end
        end
    end
endmodule

`default_nettype wire
