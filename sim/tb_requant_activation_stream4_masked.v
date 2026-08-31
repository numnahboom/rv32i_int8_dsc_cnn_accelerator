`timescale 1ns/1ps
`default_nettype none

/*
 * Differential scheduling test for the masked four-lane stream.  A logical
 * sixteen-lane DW result is represented by four consecutive four-lane beats;
 * the test changes the configuration between bundles and deliberately lets
 * several bundles overlap the ten-stage arithmetic pipe.  The combinational
 * core is the independent fixed-point reference, while the DUT uses the
 * elastic sequential implementation.
 */
module tb_requant_activation_stream4_masked;
    reg clk;
    reg rst_n;
    reg valid_in;
    wire ready_in;
    reg signed [127:0] acc_vec;
    reg signed [127:0] bias_vec;
    reg signed [127:0] multiplier_vec;
    reg [23:0] shift_vec;
    reg [5:0] pixel_idx;
    reg [6:0] channel_idx;
    reg [3:0] lane_mask;
    reg signed [31:0] output_zero_point_int32;
    reg signed [31:0] activation_min_int32;
    reg signed [31:0] activation_max_int32;
    reg ready_out;
    wire valid_out;
    wire [5:0] out_pixel_idx;
    wire [6:0] out_channel_idx;
    wire [3:0] out_lane_mask;
    wire signed [31:0] out_data_int8;
    wire busy;

    wire signed [63:0] ref_product [0:3];
    wire signed [7:0] ref_data [0:3];
    wire signed [32:0] ref_sum [0:3];
    wire signed [63:0] ref_sum_ext [0:3];
    wire signed [63:0] ref_mul_ext [0:3];
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_ref
            assign ref_sum[g] = $signed(acc_vec[(g*32) +: 32]) +
                                $signed(bias_vec[(g*32) +: 32]);
            assign ref_sum_ext[g] = {{31{ref_sum[g][32]}}, ref_sum[g]};
            assign ref_mul_ext[g] = {{32{multiplier_vec[(g*32)+31]}},
                                     multiplier_vec[(g*32) +: 32]};
            assign ref_product[g] = ref_sum_ext[g] * ref_mul_ext[g];
            requant_activation_core u_ref (
                .product_int64(ref_product[g]),
                .shift(shift_vec[(g*6) +: 6]),
                .output_zero_point_int32(output_zero_point_int32),
                .activation_min_int32(activation_min_int32),
                .activation_max_int32(activation_max_int32),
                .output_int8(ref_data[g])
            );
        end
    endgenerate

    requant_activation_stream4_masked dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .acc_vec(acc_vec), .bias_vec(bias_vec),
        .multiplier_vec(multiplier_vec), .shift_vec(shift_vec),
        .pixel_idx(pixel_idx), .channel_idx(channel_idx),
        .lane_mask(lane_mask),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32),
        .ready_out(ready_out), .valid_out(valid_out),
        .out_pixel_idx(out_pixel_idx), .out_channel_idx(out_channel_idx),
        .out_lane_mask(out_lane_mask), .out_data_int8(out_data_int8),
        .busy(busy)
    );

    always #5 clk = ~clk;

    localparam integer BUNDLES = 16;
    localparam integer BEATS = BUNDLES * 4;
    reg signed [127:0] acc_cases [0:BEATS-1];
    reg signed [127:0] bias_cases [0:BEATS-1];
    reg signed [127:0] mul_cases [0:BEATS-1];
    reg [23:0] shift_cases [0:BEATS-1];
    reg [5:0] pixel_cases [0:BEATS-1];
    reg [6:0] channel_cases [0:BEATS-1];
    reg [3:0] mask_cases [0:BEATS-1];
    reg signed [31:0] zp_cases [0:BUNDLES-1];
    reg signed [31:0] min_cases [0:BUNDLES-1];
    reg signed [31:0] max_cases [0:BUNDLES-1];

    reg signed [31:0] expected_data [0:BEATS-1];
    reg [5:0] expected_pixel [0:BEATS-1];
    reg [6:0] expected_channel [0:BEATS-1];
    reg [3:0] expected_mask [0:BEATS-1];
    integer accepted_count;
    integer output_count;
    integer errors;
    integer i;
    integer b;
    integer lane;
    integer seed;
    integer cycle_no;
    reg stalled_prev;
    reg [5:0] stalled_pixel;
    reg [6:0] stalled_channel;
    reg [3:0] stalled_mask;
    reg signed [31:0] stalled_data;

    /* Keep the input transaction stable until ready_in, and check every
     * output handshake in the same clock edge. */
    task sample_output;
        begin
            if (stalled_prev) begin
                if (!valid_out || out_pixel_idx !== stalled_pixel ||
                    out_channel_idx !== stalled_channel ||
                    out_lane_mask !== stalled_mask ||
                    out_data_int8 !== stalled_data) begin
                    $display("STALL_CHANGED valid=%b tag=%0d/%0d mask=%h data=%h",
                             valid_out, out_pixel_idx, out_channel_idx,
                             out_lane_mask, out_data_int8);
                    errors = errors + 1;
                end
                if (ready_out)
                    stalled_prev = 1'b0;
            end
            if (valid_out && !ready_out) begin
                stalled_prev = 1'b1;
                stalled_pixel = out_pixel_idx;
                stalled_channel = out_channel_idx;
                stalled_mask = out_lane_mask;
                stalled_data = out_data_int8;
            end
            if (valid_out && ready_out) begin
                if (output_count >= accepted_count) begin
                    $display("EARLY_OUTPUT count=%0d accepted=%0d", output_count,
                             accepted_count);
                    errors = errors + 1;
                end else begin
                    if (out_pixel_idx !== expected_pixel[output_count] ||
                        out_channel_idx !== expected_channel[output_count] ||
                        out_lane_mask !== expected_mask[output_count] ||
                        out_data_int8 !== expected_data[output_count]) begin
                        $display("MISMATCH n=%0d tag=%0d/%0d mask=%h data=%h exp=%0d/%0d mask=%h data=%h",
                                 output_count, out_pixel_idx, out_channel_idx,
                                 out_lane_mask, out_data_int8,
                                 expected_pixel[output_count],
                                 expected_channel[output_count],
                                 expected_mask[output_count],
                                 expected_data[output_count]);
                        errors = errors + 1;
                    end
                end
                output_count = output_count + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n)
            sample_output();
    end

    task drive_beat;
        input integer n;
        begin
            @(negedge clk);
            acc_vec = acc_cases[n];
            bias_vec = bias_cases[n];
            multiplier_vec = mul_cases[n];
            shift_vec = shift_cases[n];
            pixel_idx = pixel_cases[n];
            channel_idx = channel_cases[n];
            lane_mask = mask_cases[n];
            valid_in = 1'b1;
            while (1) begin
                @(posedge clk);
                if (ready_in) begin
                    expected_data[accepted_count] =
                        {ref_data[3], ref_data[2], ref_data[1], ref_data[0]};
                    expected_pixel[accepted_count] = pixel_idx;
                    expected_channel[accepted_count] = channel_idx;
                    expected_mask[accepted_count] = lane_mask;
                    accepted_count = accepted_count + 1;
                    break;
                end
                @(negedge clk);
            end
            @(negedge clk);
            valid_in = 1'b0;
        end
    endtask

    /* A deterministic pseudo-random ready pattern includes long enough
     * stalls to fill the pipe, while retaining frequent forward progress. */
    always @(negedge clk) begin
        if (!rst_n) begin
            ready_out <= 1'b1;
        end else begin
            cycle_no = cycle_no + 1;
            case (cycle_no % 11)
                1, 2, 6, 7: ready_out <= 1'b0;
                default: ready_out <= 1'b1;
            endcase
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid_in = 1'b0;
        acc_vec = 0;
        bias_vec = 0;
        multiplier_vec = 0;
        shift_vec = 0;
        pixel_idx = 0;
        channel_idx = 0;
        lane_mask = 0;
        output_zero_point_int32 = 0;
        activation_min_int32 = -32'sd128;
        activation_max_int32 = 32'sd127;
        ready_out = 1'b1;
        accepted_count = 0;
        output_count = 0;
        errors = 0;
        cycle_no = 0;
        stalled_prev = 1'b0;
        stalled_pixel = 0;
        stalled_channel = 0;
        stalled_mask = 0;
        stalled_data = 0;
        seed = 32'h5eeda11;

        /* Sixteen bundles: zero, positive/negative extrema, overflow-safe
         * signed extrema, varied shifts, clamps, and deterministic random
         * moderate operands. */
        zp_cases[0] = 0; min_cases[0] = -128; max_cases[0] = 127;
        zp_cases[1] = 17; min_cases[1] = -100; max_cases[1] = 100;
        zp_cases[2] = -23; min_cases[2] = -64; max_cases[2] = 63;
        zp_cases[3] = 127; min_cases[3] = 0; max_cases[3] = 127;
        zp_cases[4] = -128; min_cases[4] = -128; max_cases[4] = 0;
        zp_cases[5] = 3; min_cases[5] = -7; max_cases[5] = 9;
        zp_cases[6] = 0; min_cases[6] = -128; max_cases[6] = 127;
        zp_cases[7] = -1; min_cases[7] = -127; max_cases[7] = 126;

        for (b = 8; b < BUNDLES; b = b + 1) begin
            /* Additional independently configured random bundles keep
             * configurations in flight while the output is backpressured. */
            zp_cases[b] = ((b * 37) % 511) - 255;
            min_cases[b] = -128 + ((b * 13) % 97);
            max_cases[b] = min_cases[b] + 32 + ((b * 17) % 97);
            if (max_cases[b] > 127) max_cases[b] = 127;
        end

        for (b = 0; b < BUNDLES; b = b + 1) begin
            for (lane = 0; lane < 4; lane = lane + 1) begin
                i = b*4 + lane;
                /* Four beats are one logical sixteen-lane pixel bundle. */
                pixel_cases[i] = b*3;
                channel_cases[i] = lane*4;
                shift_cases[i] = {4{1'b0}};
                shift_cases[i][5:0] = (b*9 + lane*7) & 6'h3f;
                mask_cases[i] = 4'hf;
                acc_cases[i] = 0;
                bias_cases[i] = 0;
                mul_cases[i] = 0;
                if (b == 0) begin
                    acc_cases[i] = lane - 2;
                    bias_cases[i] = 0;
                    mul_cases[i] = 32'sh40000000;
                end else if (b == 1) begin
                    acc_cases[i] = (lane == 0) ? 32'sh7fffffff :
                                   ((lane == 1) ? 32'sh80000000 :
                                   (lane*1000 - 1000));
                    bias_cases[i] = (lane == 2) ? 32'sh7fffffff : 0;
                    mul_cases[i] = (lane == 0) ? 32'sh7fffffff :
                                   ((lane == 1) ? 32'sh80000000 :
                                   32'sh40000000);
                end else if (b == 2) begin
                    acc_cases[i] = (lane == 0) ? 32'sh80000000 :
                                   (lane*12345 - 22222);
                    bias_cases[i] = (lane == 1) ? 32'sh7fffffff :
                                    ((lane == 2) ? 32'sh80000000 : 0);
                    mul_cases[i] = (lane[0]) ? -32'sh40000000 :
                                   32'sh40000000;
                end else if (b == 3) begin
                    acc_cases[i] = (lane - 2) * 32'sd100000;
                    bias_cases[i] = (lane - 1) * 32'sd77777;
                    mul_cases[i] = (lane == 0) ? 32'sh80000000 :
                                   ((lane == 1) ? 32'sh7fffffff :
                                   32'sh20000000);
                end else begin
                    /* Keep random products well inside signed 64 bits so
                     * the independent product_int64 reference is exact. */
                    acc_cases[i] = ($urandom(seed) % 2000001) - 1000000;
                    bias_cases[i] = ($urandom(seed) % 200001) - 100000;
                    mul_cases[i] = ($urandom(seed) % 2000000001) - 1000000000;
                    if (b == 5) begin
                        acc_cases[i] = (lane - 2) * 32'sd31;
                        bias_cases[i] = lane * 32'sd3;
                        mul_cases[i] = (lane & 1) ? 32'sh60000000 :
                                       32'sh20000000;
                    end
                end
                if (b == 4) mask_cases[i] = (lane == 0) ? 4'b0001 :
                                             ((lane == 1) ? 4'b1010 : 4'b0011);
                if (b == 5) mask_cases[i] = (lane == 0) ? 4'b0000 : 4'b1000;
                if (b == 6) mask_cases[i] = (lane == 3) ? 4'b0111 : 4'b1111;
                if (b == 7) mask_cases[i] = (lane == 0) ? 4'b0101 :
                                             ((lane == 1) ? 4'b0010 : 4'b1111);
                if (b >= 8) begin
                    mask_cases[i] = $urandom(seed) & 4'hf;
                    if ((b == 8) && (lane == 0)) mask_cases[i] = 4'b0000;
                end
            end
        end
        /* Bundle zero is all zeros, bundle seven reaches a tight activation
         * clamp; all outputs remain meaningful even when a mask bit is clear. */
        for (i = 0; i < BEATS; i = i + 1) begin
            /* Config is sampled by the driver before each bundle. */
            expected_data[i] = 0;
            expected_pixel[i] = 0;
            expected_channel[i] = 0;
            expected_mask[i] = 0;
        end

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        for (b = 0; b < BUNDLES; b = b + 1) begin
            @(negedge clk);
            output_zero_point_int32 = zp_cases[b];
            activation_min_int32 = min_cases[b];
            activation_max_int32 = max_cases[b];
            for (lane = 0; lane < 4; lane = lane + 1)
                drive_beat(b*4 + lane);
        end

        @(negedge clk);
        valid_in = 1'b0;
        /* Drain all accepted beats; each iteration samples the handshake
         * before the following edge updates the elastic pipeline. */
        while (output_count < BEATS && cycle_no < 2000) begin
            @(posedge clk);
        end
        if (accepted_count != BEATS || output_count != BEATS) begin
            $display("FAIL timeout accepted=%0d output=%0d busy=%0d cycles=%0d",
                     accepted_count, output_count, busy, cycle_no);
            $fatal;
        end
        if (errors != 0) begin
            $display("FAIL tb_requant_activation_stream4_masked errors=%0d",
                     errors);
            $fatal;
        end
        $display("PASS tb_requant_activation_stream4_masked beats=%0d outputs=%0d cycles=%0d",
                 accepted_count, output_count, cycle_no);
        $finish;
    end
endmodule

`default_nettype wire
