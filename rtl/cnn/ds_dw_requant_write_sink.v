`timescale 1ns/1ps
`default_nettype none

/* Registered 16-lane DW raw-result -> int8 scratch-write boundary. */
module ds_dw_requant_write_sink (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire [5:0] pixel_idx_in, input wire [15:0] lane_mask_in,
    input wire signed [511:0] raw_vec_in,
    input wire signed [511:0] multiplier_vec_in,
    input wire [95:0] shift_vec_in,
    input wire signed [31:0] output_zero_point,
    input wire signed [31:0] activation_min,
    input wire signed [31:0] activation_max,
    output reg valid_out, input wire ready_out,
    output reg [5:0] pixel_idx_out,
    output reg [15:0] lane_mask_out,
    output reg [127:0] data_out
);
    wire slot_ready = !valid_out || ready_out;
    wire [15:0] rq_ready;
    wire [15:0] rq_valid;
    wire signed [7:0] rq_data [0:15];
    wire rq_fire = valid_in && ready_in;
    assign ready_in = rst_n && slot_ready && (&rq_ready);

    reg [9:0] tag_valid;
    reg [5:0] tag_pixel [0:9];
    reg [15:0] tag_mask [0:9];

    genvar l;
    generate for (l = 0; l < 16; l = l + 1) begin : gen_rq
        requant_activation_unit u_rq (
            .clk(clk), .rst_n(rst_n), .valid_in(valid_in && ready_in),
            .ready_in(rq_ready[l]),
            .acc_int32(raw_vec_in[(l*32) +: 32]), .bias_int32(32'sd0),
            .multiplier_int32(multiplier_vec_in[(l*32) +: 32]),
            .shift(shift_vec_in[(l*6) +: 6]),
            .output_zero_point_int32(output_zero_point),
            .activation_min_int32(activation_min),
            .activation_max_int32(activation_max),
            .ready_out(slot_ready), .valid_out(rq_valid[l]),
            .output_int8(rq_data[l])
        );
    end endgenerate

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= 1'b0; pixel_idx_out <= 6'd0;
            lane_mask_out <= 16'd0; data_out <= 128'd0;
            tag_valid <= 10'd0;
            for (i = 0; i < 10; i = i + 1) begin
                tag_pixel[i] <= 6'd0;
                tag_mask[i] <= 16'd0;
            end
        end else begin
            if (valid_out && ready_out) valid_out <= 1'b0;
            if (slot_ready) begin
                tag_valid[0] <= rq_fire;
                if (rq_fire) begin
                    tag_pixel[0] <= pixel_idx_in;
                    tag_mask[0] <= lane_mask_in;
                end
                for (i = 1; i < 10; i = i + 1) begin
                    tag_valid[i] <= tag_valid[i-1];
                    if (tag_valid[i-1]) begin
                        tag_pixel[i] <= tag_pixel[i-1];
                        tag_mask[i] <= tag_mask[i-1];
                    end
                end
            end
            if (&rq_valid && tag_valid[9] && slot_ready) begin
                valid_out <= 1'b1;
                pixel_idx_out <= tag_pixel[9];
                lane_mask_out <= tag_mask[9];
                for (i = 0; i < 16; i = i + 1)
                    data_out[(i*8) +: 8] <= tag_mask[9][i] ? rq_data[i] : 8'd0;
            end
        end
    end
endmodule

`default_nettype wire
