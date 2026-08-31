`timescale 1ns/1ps
`default_nettype none

/* Two local 2048-bit result slots plus a narrow scalar writeback FIFO.
 * Capturing the next PW result into the idle slot lets the two-lane
 * requantizer and external scalar drain proceed concurrently. */
module requant_activation_stream2_slots #(
    parameter integer FIFO_DEPTH = 128
) (
    input wire clk, input wire rst_n,
    input wire valid_in, output wire ready_in,
    input wire signed [2047:0] psum_in,
    input wire [63:0] lane_mask_in,
    input wire [5:0] pixel_base,
    input wire [8:0] cout_base,
    input wire [7:0] output_pixels,
    input wire [8:0] output_channels,
    input wire signed [255:0] bias_vec,
    input wire signed [255:0] multiplier_vec,
    input wire [47:0] shift_vec,
    input wire signed [31:0] output_zero_point_int32,
    input wire signed [31:0] activation_min_int32,
    input wire signed [31:0] activation_max_int32,
    output wire valid_out, input wire ready_out,
    output wire [7:0] out_pixel_idx,
    output wire [8:0] out_channel_idx,
    output wire signed [7:0] out_data,
    output wire busy
);
    localparam integer CW = $clog2(FIFO_DEPTH+1);
    localparam integer PW = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    reg slot_valid [0:1];
    reg signed [2047:0] slot_psum [0:1];
    reg [63:0] slot_mask [0:1];
    reg [5:0] slot_pixel [0:1];
    reg [8:0] slot_cout [0:1];
    reg [7:0] slot_pixels [0:1];
    reg [8:0] slot_channels [0:1];
    reg signed [255:0] slot_bias [0:1];
    reg signed [255:0] slot_multiplier [0:1];
    reg [47:0] slot_shift [0:1];
    /* Requant configuration belongs to the captured result, just like its
     * operands.  Keeping the top-level inputs live here would let a producer
     * change configuration while the older slot is still draining. */
    reg signed [31:0] slot_output_zero_point [0:1];
    reg signed [31:0] slot_activation_min [0:1];
    reg signed [31:0] slot_activation_max [0:1];
    integer si;

    wire any_free = !slot_valid[0] || !slot_valid[1];
    wire cap_sel = slot_valid[0] ? 1'b1 : 1'b0;
    assign ready_in = rst_n && any_free;
    wire capture_fire = valid_in && ready_in;

    reg drain_active;
    reg drain_sel;
    reg [6:0] issue_idx;
    wire [6:0] item0 = issue_idx;
    wire [6:0] item1 = issue_idx + 1'b1;
    wire [5:0] db_pixel = slot_pixel[drain_sel];
    wire [8:0] db_cout = slot_cout[drain_sel];
    wire [5:0] item0_idx = item0[5:0];
    wire [5:0] item1_idx = item1[5:0];
    wire [1:0] issue_mask = {slot_mask[drain_sel][item1_idx],
                             slot_mask[drain_sel][item0_idx]};
    wire issue_valid = drain_active && (issue_idx < 7'd64);

    /* Break the variable 2048-bit slot extraction away from the arithmetic
     * unit.  Without this small elastic staging beat, issue_idx fans out to
     * the wide result mux and then directly into the first requant DSP input;
     * that path is the physical timing limiter. */
    reg stage_valid;
    reg signed [63:0] stage_acc;
    reg signed [63:0] stage_bias;
    reg signed [63:0] stage_multiplier;
    reg [11:0] stage_shift;
    reg [6:0] stage_item_idx;
    reg [5:0] stage_pixel;
    reg [8:0] stage_cout;
    reg [1:0] stage_mask;
    reg signed [31:0] stage_output_zero_point;
    reg signed [31:0] stage_activation_min;
    reg signed [31:0] stage_activation_max;

    wire rq_ready;
    wire rq_valid;
    wire [6:0] rq_item;
    wire [6:0] rq_item1 = rq_item + 1'b1;
    wire [5:0] rq_pixel_base;
    wire [8:0] rq_cout_base;
    wire [1:0] rq_mask;
    wire signed [15:0] rq_data;
    wire rq_busy;
    /* A stream2 beat can enqueue zero, one, or two scalar results.  Reserve
     * two entries before accepting it; the explicit two-bit increment below
     * is important because Verilog's unsized expression rules otherwise make
     * (mask[0] + mask[1]) a one-bit sum (and 2'b10 wraps to zero). */
    wire fifo_space_two = (fifo_count <= FIFO_DEPTH-2);
    requant_activation_stream2 u_rq (
        .clk(clk), .rst_n(rst_n), .valid_in(stage_valid), .ready_in(rq_ready),
        .acc_vec(stage_acc), .bias_vec(stage_bias),
        .multiplier_vec(stage_multiplier), .shift_vec(stage_shift),
        .item_idx(stage_item_idx), .pixel_base(stage_pixel),
        .cout_base(stage_cout), .lane_mask(stage_mask),
        .output_zero_point_int32(stage_output_zero_point),
        .activation_min_int32(stage_activation_min),
        .activation_max_int32(stage_activation_max),
        .ready_out(fifo_space_two), .valid_out(rq_valid), .out_item_idx(rq_item),
        .out_pixel_base(rq_pixel_base), .out_cout_base(rq_cout_base),
        .out_lane_mask(rq_mask), .out_data_int8(rq_data), .busy(rq_busy)
    );

    reg [7:0] fifo_pixel [0:FIFO_DEPTH-1];
    reg [8:0] fifo_channel [0:FIFO_DEPTH-1];
    reg signed [7:0] fifo_data [0:FIFO_DEPTH-1];
    reg [CW-1:0] fifo_count;
    reg [PW-1:0] fifo_wr_ptr, fifo_rd_ptr;
    wire rq_fire = rq_valid && fifo_space_two;
    wire fifo_push = rq_fire && (rq_mask != 2'b00);
    wire [1:0] rq_count_inc = {1'b0,rq_mask[0]} + {1'b0,rq_mask[1]};
    wire pop_fire = valid_out && ready_out;
    assign valid_out = (fifo_count != 0);
    assign out_pixel_idx = fifo_pixel[fifo_rd_ptr];
    assign out_channel_idx = fifo_channel[fifo_rd_ptr];
    assign out_data = fifo_data[fifo_rd_ptr];
    assign busy = slot_valid[0] || slot_valid[1] || drain_active || stage_valid || rq_busy ||
                  (fifo_count != 0);

    wire drain_start = !drain_active &&
        !stage_valid && (slot_valid[0] || slot_valid[1]);
    /* drain_sel is the round-robin age pointer.  A freshly captured result
     * can refill the slot just released, so always preferring slot zero would
     * reorder the two-slot FIFO (new data could overtake the older slot one).
     * Prefer the age pointer when occupied and fall back to the other slot. */
    wire start_sel = slot_valid[drain_sel] ? drain_sel : ~drain_sel;
    wire stage_load = issue_valid && (!stage_valid || rq_ready);
    wire stage_fire = stage_valid && rq_ready;
    always @(posedge clk) begin
        if (!rst_n) begin
            slot_valid[0] <= 0; slot_valid[1] <= 0;
            drain_active <= 0; drain_sel <= 0; issue_idx <= 0;
            stage_valid <= 1'b0;
            stage_acc <= 64'sd0; stage_bias <= 64'sd0;
            stage_multiplier <= 64'sd0; stage_shift <= 12'd0;
            stage_item_idx <= 7'd0; stage_pixel <= 6'd0;
            stage_cout <= 9'd0; stage_mask <= 2'd0;
            stage_output_zero_point <= 32'sd0;
            stage_activation_min <= 32'sd0;
            stage_activation_max <= 32'sd0;
            fifo_count <= 0; fifo_wr_ptr <= 0; fifo_rd_ptr <= 0;
            for (si=0; si<2; si=si+1) begin
                slot_psum[si] <= 0; slot_mask[si] <= 0; slot_pixel[si] <= 0;
                slot_cout[si] <= 0; slot_pixels[si] <= 0;
                slot_channels[si] <= 0; slot_bias[si] <= 0;
                slot_multiplier[si] <= 0; slot_shift[si] <= 0;
                slot_output_zero_point[si] <= 0;
                slot_activation_min[si] <= 0;
                slot_activation_max[si] <= 0;
            end
        end else begin
            if (capture_fire) begin
                slot_valid[cap_sel] <= 1'b1;
                slot_psum[cap_sel] <= psum_in; slot_mask[cap_sel] <= lane_mask_in;
                slot_pixel[cap_sel] <= pixel_base; slot_cout[cap_sel] <= cout_base;
                slot_pixels[cap_sel] <= output_pixels;
                slot_channels[cap_sel] <= output_channels;
                slot_bias[cap_sel] <= bias_vec;
                slot_multiplier[cap_sel] <= multiplier_vec;
                slot_shift[cap_sel] <= shift_vec;
                slot_output_zero_point[cap_sel] <= output_zero_point_int32;
                slot_activation_min[cap_sel] <= activation_min_int32;
                slot_activation_max[cap_sel] <= activation_max_int32;
            end
            if (drain_start) begin
                drain_active <= 1'b1;
                drain_sel <= start_sel;
                issue_idx <= 0;
            end else if (stage_load) begin
                stage_valid <= 1'b1;
                stage_acc <= slot_psum[drain_sel][(issue_idx*32) +: 64];
                stage_bias <= {slot_bias[drain_sel][((item1[2:0])*32) +: 32],
                               slot_bias[drain_sel][((item0[2:0])*32) +: 32]};
                stage_multiplier <=
                    {slot_multiplier[drain_sel][((item1[2:0])*32) +: 32],
                     slot_multiplier[drain_sel][((item0[2:0])*32) +: 32]};
                stage_shift <= {slot_shift[drain_sel][((item1[2:0])*6) +: 6],
                                slot_shift[drain_sel][((item0[2:0])*6) +: 6]};
                stage_item_idx <= issue_idx;
                stage_pixel <= db_pixel;
                stage_cout <= db_cout;
                stage_mask <= issue_mask;
                stage_output_zero_point <= slot_output_zero_point[drain_sel];
                stage_activation_min <= slot_activation_min[drain_sel];
                stage_activation_max <= slot_activation_max[drain_sel];
                if (issue_idx >= 7'd62) begin
                    drain_active <= 1'b0;
                    slot_valid[drain_sel] <= 1'b0;
                    drain_sel <= ~drain_sel;
                end else issue_idx <= issue_idx + 7'd2;
            end else if (stage_fire)
                stage_valid <= 1'b0;

            if (rq_fire) begin
                if (rq_mask[0]) begin
                    fifo_pixel[fifo_wr_ptr] <= rq_pixel_base + (rq_item >> 3);
                    fifo_channel[fifo_wr_ptr] <= rq_cout_base + rq_item[2:0];
                    fifo_data[fifo_wr_ptr] <= rq_data[7:0];
                    fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
                end
                if (rq_mask[1]) begin
                    fifo_pixel[fifo_wr_ptr + rq_mask[0]] <=
                        rq_pixel_base + ((rq_item + 1'b1) >> 3);
                    fifo_channel[fifo_wr_ptr + rq_mask[0]] <=
                        rq_cout_base + rq_item1[2:0];
                    fifo_data[fifo_wr_ptr + rq_mask[0]] <= rq_data[15:8];
                    fifo_wr_ptr <= fifo_wr_ptr + rq_mask[0] + 1'b1;
                end
            end
            if (pop_fire) fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
            case ({fifo_push,pop_fire})
                2'b10: fifo_count <= fifo_count + rq_count_inc;
                2'b01: fifo_count <= fifo_count - 1'b1;
                2'b11: fifo_count <= fifo_count + rq_count_inc - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end
endmodule

`default_nettype wire
