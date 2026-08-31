`timescale 1ns/1ps
`default_nettype none

/* Two-lane version of the exact shared requant operation.  It is intended
 * for draining a held 8x8 result: two adjacent result lanes are issued per
 * cycle while a small sideband pipe preserves their item index and mask. */
module requant_activation_stream2 (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire signed [63:0] acc_vec,
    input wire signed [63:0] bias_vec,
    input wire signed [63:0] multiplier_vec,
    input wire [11:0] shift_vec,
    input wire [6:0] item_idx,
    input wire [5:0] pixel_base,
    input wire [8:0] cout_base,
    input wire [1:0] lane_mask,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire ready_out, output wire valid_out,
    output wire [6:0] out_item_idx,
    output wire [5:0] out_pixel_base,
    output wire [8:0] out_cout_base,
    output wire [1:0] out_lane_mask,
    output wire signed [15:0] out_data_int8,
    output wire busy
);
    wire [1:0] core_ready;
    wire [1:0] core_valid;
    wire signed [7:0] core_data [0:1];
    wire advance = &core_ready;
    reg [9:0] tag_valid;
    reg [6:0] item_pipe [0:9];
    reg [5:0] pixel_pipe [0:9];
    reg [8:0] cout_pipe [0:9];
    reg [1:0] mask_pipe [0:9];
    genvar l;
    generate for (l=0; l<2; l=l+1) begin : gen_lane
        requant_activation_unit u_core (
            .clk(clk), .rst_n(rst_n), .valid_in(valid_in && ready_in),
            .ready_in(core_ready[l]),
            .acc_int32(acc_vec[(l*32) +: 32]),
            .bias_int32(bias_vec[(l*32) +: 32]),
            .multiplier_int32(multiplier_vec[(l*32) +: 32]),
            .shift(shift_vec[(l*6) +: 6]),
            .output_zero_point_int32(output_zero_point_int32),
            .activation_min_int32(activation_min_int32),
            .activation_max_int32(activation_max_int32),
            .ready_out(ready_out), .valid_out(core_valid[l]),
            .output_int8(core_data[l])
        );
    end endgenerate
    assign ready_in = rst_n && advance;
    assign valid_out = &core_valid;
    assign out_item_idx = item_pipe[9];
    assign out_pixel_base = pixel_pipe[9];
    assign out_cout_base = cout_pipe[9];
    assign out_lane_mask = mask_pipe[9];
    assign out_data_int8 = {core_data[1],core_data[0]};
    assign busy = valid_out | (|tag_valid);

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            tag_valid <= 10'd0;
            for (i=0; i<10; i=i+1) begin
                item_pipe[i] <= 0; pixel_pipe[i] <= 0;
                cout_pipe[i] <= 0; mask_pipe[i] <= 0;
            end
        end else if (advance) begin
            tag_valid[0] <= valid_in;
            if (valid_in) begin
                item_pipe[0] <= item_idx; pixel_pipe[0] <= pixel_base;
                cout_pipe[0] <= cout_base; mask_pipe[0] <= lane_mask;
            end else mask_pipe[0] <= 0;
            for (i=1; i<10; i=i+1) begin
                tag_valid[i] <= tag_valid[i-1];
                if (tag_valid[i-1]) begin
                    item_pipe[i] <= item_pipe[i-1];
                    pixel_pipe[i] <= pixel_pipe[i-1];
                    cout_pipe[i] <= cout_pipe[i-1];
                    mask_pipe[i] <= mask_pipe[i-1];
                end else mask_pipe[i] <= 0;
            end
        end
    end
endmodule

`default_nettype wire
