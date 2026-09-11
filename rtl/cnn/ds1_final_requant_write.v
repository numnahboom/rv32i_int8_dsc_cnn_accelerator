`timescale 1ns/1ps
`default_nettype none

/*
 * Final DS1 PW block requantization and output packing.
 *
 * A retained-session block contains eight pixels by eight output channels,
 * represented as 64 signed int32 accumulators in pixel-major order.  The
 * production requant_activation_unit is instantiated once per output
 * channel.  Each lane consumes the eight pixels in order; its results are
 * captured in a small register file and drained as two four-byte writes per
 * pixel.  Thus the arithmetic remains exactly the scalar production
 * operation, while the external write boundary is the required vec4/NHWC
 * ordering.
 *
 * The input and output boundaries are elastic.  Once an output write is
 * valid, all payload fields are derived only from the held block and the
 * write cursor, both of which advance only on ready/valid handshakes.
 */
module ds1_final_requant_write (
    input wire clk,
    input wire rst_n,

    input wire valid_in,
    output wire ready_in,
    input wire signed [2047:0] psum_in,
    input wire [9:0] pixel_base,
    input wire [5:0] cout_base,
    input wire signed [255:0] bias_vec,
    input wire signed [255:0] multiplier_vec,
    input wire [47:0] shift_vec,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,

    output wire valid_out_vec4,
    input wire ready_out_vec4,
    output wire signed [31:0] out_data_int8_vec4,
    output wire [9:0] out_pixel_idx_vec4,
    output wire [5:0] out_channel_idx_vec4,
    output wire [15:0] out_byte_addr_vec4,
    output wire [15:0] out_word_addr_vec4,
    output wire [3:0] out_byte_en_vec4,
    output wire busy
);
    localparam [1:0] ST_IDLE    = 2'd0;
    localparam [1:0] ST_ISSUE   = 2'd1;
    localparam [1:0] ST_COLLECT = 2'd2;
    localparam [1:0] ST_WRITE   = 2'd3;

    reg [1:0] state;

    reg signed [2047:0] psum_reg;
    reg signed [255:0] bias_reg;
    reg signed [255:0] multiplier_reg;
    reg [47:0] shift_reg;
    reg signed [31:0] output_zero_point_reg;
    reg signed [31:0] activation_min_reg;
    reg signed [31:0] activation_max_reg;
    reg [9:0] pixel_base_reg;
    reg [5:0] cout_base_reg;

    reg [2:0] issue_pixel;
    reg [2:0] collect_pixel [0:7];
    reg [6:0] collected_count;
    reg [3:0] write_index;
    reg signed [7:0] result_mem [0:7][0:7];

    /* This name is intentionally retained for focused watchdogs and probes. */
    /* verilator lint_off UNUSED */
    wire issue_fire;
    /* verilator lint_on UNUSED */

    wire [7:0] rq_ready_in;
    wire [7:0] rq_valid_out;
    wire signed [7:0] rq_data [0:7];

    /* A block is accepted only while the serializer is idle. */
    assign ready_in = rst_n && (state == ST_IDLE);
    assign busy = rst_n && (state != ST_IDLE);

    /* All eight units advance together.  valid_in is withheld from every
     * lane until all lanes can accept, so no lane can lose pixel alignment. */
    assign issue_fire = (state == ST_ISSUE) && (&rq_ready_in);

    genvar lane_g;
    generate
        for (lane_g = 0; lane_g < 8; lane_g = lane_g + 1) begin : gen_requant_lane
            localparam integer LANE = lane_g;
            wire signed [31:0] lane_acc =
                psum_reg[(issue_pixel * 256) + (LANE * 32) +: 32];
            wire signed [31:0] lane_bias = bias_reg[(LANE * 32) +: 32];
            wire signed [31:0] lane_multiplier =
                multiplier_reg[(LANE * 32) +: 32];
            wire [5:0] lane_shift = shift_reg[(LANE * 6) +: 6];

            requant_activation_unit u_requant (
                .clk(clk),
                .rst_n(rst_n),
                .valid_in(issue_fire),
                .ready_in(rq_ready_in[lane_g]),
                .acc_int32(lane_acc),
                .bias_int32(lane_bias),
                .multiplier_int32(lane_multiplier),
                .shift(lane_shift),
                .output_zero_point_int32(output_zero_point_reg),
                .activation_min_int32(activation_min_reg),
                .activation_max_int32(activation_max_reg),
                .ready_out(1'b1),
                .valid_out(rq_valid_out[lane_g]),
                .output_int8(rq_data[lane_g])
            );
        end
    endgenerate

    wire [2:0] write_pixel = write_index[3:1];
    wire [2:0] write_lane_base = write_index[0] ? 3'd4 : 3'd0;
    wire [9:0] write_global_pixel =
        pixel_base_reg + {7'd0, write_pixel};
    wire [5:0] write_global_channel =
        cout_base_reg + {3'd0, write_lane_base};
    wire [15:0] write_byte_address =
        ({6'd0, write_global_pixel} << 5) +
        {10'd0, write_global_channel};

    wire signed [7:0] write_byte [0:3];
    genvar byte_g;
    generate
        for (byte_g = 0; byte_g < 4; byte_g = byte_g + 1) begin : gen_write_byte
            assign write_byte[byte_g] =
                result_mem[write_pixel][write_lane_base + byte_g];
        end
    endgenerate

    assign valid_out_vec4 = rst_n && (state == ST_WRITE);
    assign out_data_int8_vec4 = {
        write_byte[3], write_byte[2], write_byte[1], write_byte[0]
    };
    assign out_pixel_idx_vec4 = write_global_pixel;
    assign out_channel_idx_vec4 = write_global_channel;
    assign out_byte_addr_vec4 = write_byte_address;
    assign out_word_addr_vec4 = write_byte_address >> 2;
    assign out_byte_en_vec4 = 4'b1111;

    integer i;
    integer j;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            psum_reg <= 2048'sd0;
            bias_reg <= 256'sd0;
            multiplier_reg <= 256'sd0;
            shift_reg <= 48'd0;
            output_zero_point_reg <= 32'sd0;
            activation_min_reg <= -32'sd128;
            activation_max_reg <= 32'sd127;
            pixel_base_reg <= 10'd0;
            cout_base_reg <= 6'd0;
            issue_pixel <= 3'd0;
            collected_count <= 7'd0;
            write_index <= 4'd0;
            for (i = 0; i < 8; i = i + 1) begin
                collect_pixel[i] <= 3'd0;
            end
            for (i = 0; i < 8; i = i + 1) begin
                for (j = 0; j < 8; j = j + 1)
                    result_mem[i][j] <= 8'sd0;
            end
        end else begin
            /* Requant outputs are always accepted by their private units, so
             * each lane's result order is its eight issued pixel order. */
            for (i = 0; i < 8; i = i + 1) begin
                if (rq_valid_out[i]) begin
                    result_mem[collect_pixel[i]][i] <= rq_data[i];
                    collect_pixel[i] <= collect_pixel[i] + 3'd1;
                end
            end
            if (&rq_valid_out)
                collected_count <= collected_count + 7'd8;

            case (state)
                ST_IDLE: begin
                    if (valid_in && ready_in) begin
                        psum_reg <= psum_in;
                        bias_reg <= bias_vec;
                        multiplier_reg <= multiplier_vec;
                        shift_reg <= shift_vec;
                        output_zero_point_reg <= output_zero_point_int32;
                        activation_min_reg <= activation_min_int32;
                        activation_max_reg <= activation_max_int32;
                        pixel_base_reg <= pixel_base;
                        cout_base_reg <= cout_base;
                        issue_pixel <= 3'd0;
                        collected_count <= 7'd0;
                        write_index <= 4'd0;
                        for (i = 0; i < 8; i = i + 1)
                            collect_pixel[i] <= 3'd0;
                        state <= ST_ISSUE;
                    end
                end

                ST_ISSUE: begin
                    if (issue_fire) begin
                        if (issue_pixel == 3'd7) begin
                            issue_pixel <= 3'd0;
                            state <= ST_COLLECT;
                        end else begin
                            issue_pixel <= issue_pixel + 3'd1;
                        end
                    end
                end

                ST_COLLECT: begin
                    /* Eight simultaneous final outputs are the collection
                     * fence.  The same edge writes the last result row; the
                     * serializer exposes it on the following cycle. */
                    if (&rq_valid_out && (collected_count == 7'd56)) begin
                        write_index <= 4'd0;
                        state <= ST_WRITE;
                    end
                end

                ST_WRITE: begin
                    if (valid_out_vec4 && ready_out_vec4) begin
                        if (write_index == 4'd15) begin
                            write_index <= 4'd0;
                            state <= ST_IDLE;
                        end else begin
                            write_index <= write_index + 4'd1;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
