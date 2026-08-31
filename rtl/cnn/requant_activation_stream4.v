`timescale 1ns/1ps
`default_nettype none

/* Throughput-one four-lane requant stream.  Unlike the transaction wrapper,
 * this accepts one channel quartet each cycle, so one set of four arithmetic
 * lanes can drain all four DW channel groups without four replicated wrappers. */
module requant_activation_stream4 (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire signed [127:0] acc_vec,
    input wire signed [127:0] bias_vec,
    input wire signed [127:0] multiplier_vec,
    input wire [23:0] shift_vec,
    input wire [5:0] pixel_idx, input wire [6:0] channel_idx,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    input wire ready_out, output wire valid_out,
    output wire [5:0] out_pixel_idx,
    output wire [6:0] out_channel_idx,
    output wire signed [31:0] out_data_int8,
    output wire busy
);
    wire [3:0] core_ready_in;
    wire [3:0] core_valid_out;
    wire [3:0] core_data_valid;
    wire signed [7:0] core_data [0:3];
    reg [9:0] tag_valid;
    reg [5:0] pixel_tag [0:9];
    reg [6:0] channel_tag [0:9];
    wire advance = &core_ready_in;
    /* Keep the wrapper quiescent during reset.  The child units are also
     * reset synchronously, so exposing a ready indication while rst_n is low
     * would make a producer believe that a beat was accepted. */
    assign ready_in = rst_n && advance;
    assign core_data_valid = {4{valid_in && ready_in}};
    assign valid_out = &core_valid_out;
    assign busy = valid_out | (|tag_valid);
    assign out_pixel_idx = pixel_tag[9];
    assign out_channel_idx = channel_tag[9];
    assign out_data_int8 = {core_data[3], core_data[2], core_data[1], core_data[0]};
    genvar g;
    generate for (g=0; g<4; g=g+1) begin : gen_core
        requant_activation_unit u_core (
            .clk(clk), .rst_n(rst_n), .valid_in(core_data_valid[g]),
            .ready_in(core_ready_in[g]),
            .acc_int32(acc_vec[(g*32) +: 32]),
            .bias_int32(bias_vec[(g*32) +: 32]),
            .multiplier_int32(multiplier_vec[(g*32) +: 32]),
            .shift(shift_vec[(g*6) +: 6]),
            .output_zero_point_int32(output_zero_point_int32),
            .activation_min_int32(activation_min_int32),
            .activation_max_int32(activation_max_int32),
            .ready_out(ready_out), .valid_out(core_valid_out[g]),
            .output_int8(core_data[g])
        );
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            tag_valid <= 10'd0;
            for (i=0; i<10; i=i+1) begin
                pixel_tag[i] <= 6'd0;
                channel_tag[i] <= 7'd0;
            end
        end else if (advance) begin
            tag_valid[0] <= valid_in;
            if (valid_in) begin pixel_tag[0] <= pixel_idx; channel_tag[0] <= channel_idx; end
            for (i=1; i<10; i=i+1) begin
                tag_valid[i] <= tag_valid[i-1];
                if (tag_valid[i-1]) begin
                    pixel_tag[i] <= pixel_tag[i-1];
                    channel_tag[i] <= channel_tag[i-1];
                end
            end
        end
    end
endmodule
`default_nettype wire
