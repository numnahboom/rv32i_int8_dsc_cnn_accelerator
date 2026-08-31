`timescale 1ns/1ps
`default_nettype none

/*
 * Four independent copies of the exact ten-stage requantizer.  A vector is
 * accepted as one elastic transaction and is consumed in four-wide groups;
 * the four result streams remain independently elastic so a scalar legacy
 * output port can drain them without dropping a result.  The arithmetic is
 * intentionally delegated to requant_activation_unit: this module changes
 * only scheduling/parallelism, not the int32->int8 operation.
 */
module requant_activation_vector4 #(
    /* PW retains the fixed 8-channel/8-pixel issue cadence.  DW uses four
     * active channels per instance and opts into an early stop at the first
     * inactive group. */
    parameter EARLY_STOP_INACTIVE = 1'b0
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 valid_in,
    output wire                 ready_in,
    input  wire signed [2047:0] psum_in,
    input  wire [5:0]           pixel_base,
    input  wire [8:0]           cout_base,
    input  wire [7:0]           output_pixels,
    input  wire [8:0]           output_channels,
    input  wire signed [255:0]  bias_vec,
    input  wire signed [255:0]  multiplier_vec,
    input  wire [47:0]          shift_vec,
    input  wire signed [31:0]   output_zero_point_int32,
    input  wire signed [31:0]   activation_min_int32,
    input  wire signed [31:0]   activation_max_int32,
    output wire [3:0]           valid_out,
    input  wire [3:0]           ready_out,
    output wire [23:0]          out_pixel_idx_vec,
    output wire [31:0]          out_channel_idx_vec,
    output wire signed [31:0]   out_data_int8_vec,
    output wire                 busy
);
    reg active;
    reg issue_done;
    reg [5:0] issue_idx;
    reg [6:0] pending_count;
    reg signed [2047:0] psum_reg;
    reg [5:0] pixel_base_reg;
    reg [8:0] cout_base_reg;
    reg [7:0] output_pixels_reg;
    reg [8:0] output_channels_reg;
    reg signed [255:0] bias_reg;
    reg signed [255:0] multiplier_reg;
    reg [47:0] shift_reg;
    reg signed [31:0] output_zero_point_reg;
    reg signed [31:0] activation_min_reg;
    reg signed [31:0] activation_max_reg;

    wire [3:0] core_ready_in;
    wire [3:0] core_valid_out;
    wire [3:0] core_valid_in;
    wire [3:0] core_ready_out;
    wire [3:0] issue_active;
    wire [3:0] issue_fire_bits;
    wire [3:0] output_fire_bits;
    wire [3:0] enqueue_bits;
    wire all_core_ready;
    wire capture_fire;
    wire issue_fire;
    wire [2:0] issue_count;
    wire [2:0] enqueue_count;
    wire [7:0] pending_next;
    wire issue_any_active;

    wire signed [31:0] core_acc [0:3];
    wire signed [31:0] core_bias [0:3];
    wire signed [31:0] core_multiplier [0:3];
    wire [5:0] core_shift [0:3];
    wire signed [7:0] core_data [0:3];
    wire [7:0] issue_item_pixel [0:3];
    wire [8:0] issue_item_cout [0:3];

    reg [9:0] tag_valid [0:3];
    reg [5:0] tag_pixel [0:3][0:9];
    reg [7:0] tag_cout [0:3][0:9];
    reg [5:0] fifo_count [0:3];
    reg [4:0] fifo_wr_ptr [0:3];
    reg [4:0] fifo_rd_ptr [0:3];
    reg signed [7:0] fifo_data [0:3][0:31];
    reg [5:0] fifo_pixel [0:3][0:31];
    reg [7:0] fifo_cout [0:3][0:31];

    genvar lane_g;
    integer g;
    integer s;

    assign busy = active;
    assign all_core_ready = &core_ready_in;
    assign ready_in = !active &&
                      (fifo_count[0] <= 6'd16) &&
                      (fifo_count[1] <= 6'd16) &&
                      (fifo_count[2] <= 6'd16) &&
                      (fifo_count[3] <= 6'd16);
    assign capture_fire = valid_in && ready_in;
    assign issue_any_active = |issue_active;
    assign issue_fire = active && !issue_done && all_core_ready &&
                        ((!EARLY_STOP_INACTIVE) || issue_any_active);
    assign core_valid_in = issue_fire ? issue_active : 4'b0;
    assign issue_fire_bits = core_valid_in;
    assign valid_out[0] = (fifo_count[0] != 6'd0);
    assign valid_out[1] = (fifo_count[1] != 6'd0);
    assign valid_out[2] = (fifo_count[2] != 6'd0);
    assign valid_out[3] = (fifo_count[3] != 6'd0);
    assign output_fire_bits = valid_out & ready_out;
    assign enqueue_bits = core_valid_out & core_ready_out;
    assign issue_count = {2'b0, issue_fire_bits[0]} +
                         {2'b0, issue_fire_bits[1]} +
                         {2'b0, issue_fire_bits[2]} +
                         {2'b0, issue_fire_bits[3]};
    assign enqueue_count = {2'b0, enqueue_bits[0]} +
                           {2'b0, enqueue_bits[1]} +
                           {2'b0, enqueue_bits[2]} +
                           {2'b0, enqueue_bits[3]};
    assign pending_next = {1'b0, pending_count} + {5'd0, issue_count} -
                          {5'd0, enqueue_count};

    generate
        for (lane_g = 0; lane_g < 4; lane_g = lane_g + 1) begin : gen_vector_lane
            localparam [7:0] LANE_CONST = lane_g;
            wire [7:0] item_idx = {2'b0, issue_idx} + LANE_CONST;
            wire [7:0] item_pixel = {2'b0, pixel_base_reg} + (item_idx >> 3);
            wire [2:0] item_cout_lane = item_idx[2:0];
            wire [8:0] item_cout = cout_base_reg + {6'd0, item_cout_lane};

            assign issue_item_pixel[lane_g] = item_pixel;
            assign issue_item_cout[lane_g] = item_cout;

            assign issue_active[lane_g] =
                (item_pixel < output_pixels_reg) &&
                (item_cout < output_channels_reg);
            assign core_acc[lane_g] = psum_reg[(item_idx * 32) +: 32];
            assign core_bias[lane_g] = bias_reg[(item_cout_lane * 32) +: 32];
            assign core_multiplier[lane_g] =
                multiplier_reg[(item_cout_lane * 32) +: 32];
            assign core_shift[lane_g] = shift_reg[(item_cout_lane * 6) +: 6];
            assign core_ready_out[lane_g] = (fifo_count[lane_g] < 6'd32);
            assign out_pixel_idx_vec[(lane_g * 6) +: 6] =
                fifo_pixel[lane_g][fifo_rd_ptr[lane_g]];
            assign out_channel_idx_vec[(lane_g * 8) +: 8] =
                fifo_cout[lane_g][fifo_rd_ptr[lane_g]];
            assign out_data_int8_vec[(lane_g * 8) +: 8] =
                fifo_data[lane_g][fifo_rd_ptr[lane_g]];

            requant_activation_unit u_requant (
                .clk(clk),
                .rst_n(rst_n),
                .valid_in(core_valid_in[lane_g]),
                .ready_in(core_ready_in[lane_g]),
                .acc_int32(core_acc[lane_g]),
                .bias_int32(core_bias[lane_g]),
                .multiplier_int32(core_multiplier[lane_g]),
                .shift(core_shift[lane_g]),
                .output_zero_point_int32(output_zero_point_reg),
                .activation_min_int32(activation_min_reg),
                .activation_max_int32(activation_max_reg),
                .ready_out(core_ready_out[lane_g]),
                .valid_out(core_valid_out[lane_g]),
                .output_int8(core_data[lane_g])
            );
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 1'b0;
            issue_done <= 1'b0;
            issue_idx <= 6'd0;
            pending_count <= 7'd0;
            psum_reg <= 2048'sd0;
            pixel_base_reg <= 6'd0;
            cout_base_reg <= 9'd0;
            output_pixels_reg <= 8'd0;
            output_channels_reg <= 9'd0;
            bias_reg <= 256'sd0;
            multiplier_reg <= 256'sd0;
            shift_reg <= 48'd0;
            output_zero_point_reg <= 32'sd0;
            activation_min_reg <= 32'sd0;
            activation_max_reg <= 32'sd0;
            for (g = 0; g < 4; g = g + 1) begin
                tag_valid[g] <= 10'd0;
                fifo_count[g] <= 6'd0;
                fifo_wr_ptr[g] <= 5'd0;
                fifo_rd_ptr[g] <= 5'd0;
                for (s = 0; s < 10; s = s + 1) begin
                    tag_pixel[g][s] <= 6'd0;
                    tag_cout[g][s] <= 8'd0;
                end
                for (s = 0; s < 32; s = s + 1) begin
                    fifo_data[g][s] <= 8'sd0;
                    fifo_pixel[g][s] <= 6'd0;
                    fifo_cout[g][s] <= 8'd0;
                end
            end
        end else begin
            for (g = 0; g < 4; g = g + 1) begin
                if (core_ready_in[g]) begin
                    tag_valid[g][0] <= core_valid_in[g];
                    if (core_valid_in[g]) begin
                        tag_pixel[g][0] <= issue_item_pixel[g][5:0];
                        tag_cout[g][0] <= issue_item_cout[g][7:0];
                    end
                    for (s = 1; s < 10; s = s + 1) begin
                        tag_valid[g][s] <= tag_valid[g][s-1];
                        if (tag_valid[g][s-1]) begin
                            tag_pixel[g][s] <= tag_pixel[g][s-1];
                            tag_cout[g][s] <= tag_cout[g][s-1];
                        end
                    end
                end
                if (enqueue_bits[g]) begin
                    fifo_data[g][fifo_wr_ptr[g]] <= core_data[g];
                    fifo_pixel[g][fifo_wr_ptr[g]] <= tag_pixel[g][9];
                    fifo_cout[g][fifo_wr_ptr[g]] <= tag_cout[g][9];
                    fifo_wr_ptr[g] <= fifo_wr_ptr[g] + 5'd1;
                end
                if (output_fire_bits[g]) begin
                    fifo_rd_ptr[g] <= fifo_rd_ptr[g] + 5'd1;
                end
                case ({enqueue_bits[g], output_fire_bits[g]})
                    2'b10: fifo_count[g] <= fifo_count[g] + 6'd1;
                    2'b01: fifo_count[g] <= fifo_count[g] - 6'd1;
                    default: fifo_count[g] <= fifo_count[g];
                endcase
            end

            pending_count <= pending_next[6:0];

            if (capture_fire) begin
                active <= 1'b1;
                issue_done <= 1'b0;
                issue_idx <= 6'd0;
                pending_count <= 7'd0;
                psum_reg <= psum_in;
                pixel_base_reg <= pixel_base;
                cout_base_reg <= cout_base;
                output_pixels_reg <= output_pixels;
                output_channels_reg <= output_channels;
                bias_reg <= bias_vec;
                multiplier_reg <= multiplier_vec;
                shift_reg <= shift_vec;
                output_zero_point_reg <= output_zero_point_int32;
                activation_min_reg <= activation_min_int32;
                activation_max_reg <= activation_max_int32;
            end else if (EARLY_STOP_INACTIVE && active && !issue_done &&
                         !issue_any_active) begin
                issue_done <= 1'b1;
            end else if (issue_fire) begin
                if (issue_idx >= 6'd60) begin
                    issue_done <= 1'b1;
                end else begin
                    issue_idx <= issue_idx + 6'd4;
                end
            end

            if (active && issue_done && (pending_next == 8'd0)) begin
                active <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
