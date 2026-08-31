`timescale 1ns/1ps
`default_nettype none

/* Differential stress test for the two-slot 8x8 PW result drain.
 * Each accepted transaction is one 2048-bit result (64 signed accumulators)
 * and its own requant configuration.  The test intentionally fills both
 * slots, changes configuration while the first slot drains, and applies
 * irregular output backpressure.  The expected queue contains only masked
 * scalar lanes, in pixel-major/channel-minor order. */
module tb_requant_activation_stream2_slots;
    localparam integer BUNDLES = 2048;
    localparam integer MAX_EXPECT = BUNDLES * 64 + 8;

    reg clk;
    reg rst_n;
    reg valid_in;
    wire ready_in;
    reg signed [2047:0] psum_in;
    reg [63:0] lane_mask_in;
    reg [5:0] pixel_base;
    reg [8:0] cout_base;
    reg [7:0] output_pixels;
    reg [8:0] output_channels;
    reg signed [255:0] bias_vec;
    reg signed [255:0] multiplier_vec;
    reg [47:0] shift_vec;
    reg signed [31:0] output_zero_point_int32;
    reg signed [31:0] activation_min_int32;
    reg signed [31:0] activation_max_int32;
    reg ready_out;
    wire valid_out;
    wire [7:0] out_pixel_idx;
    wire [8:0] out_channel_idx;
    wire signed [7:0] out_data;
    wire busy;

    /* Independent combinational reference.  Width is made explicit before
     * multiplication so the reference cannot silently truncate operands. */
    wire signed [32:0] ref_sum [0:63];
    wire signed [64:0] ref_sum_ext [0:63];
    wire signed [64:0] ref_mul_ext [0:63];
    wire signed [129:0] ref_product_wide [0:63];
    wire signed [63:0] ref_product [0:63];
    wire signed [7:0] ref_data [0:63];
    genvar g;
    generate
        for (g = 0; g < 64; g = g + 1) begin : gen_ref
            /* The PW bundle has eight output-channel parameter lanes reused
             * for each of its eight spatial pixels. */
            assign ref_sum[g] =
                $signed({psum_in[(g*32)+31], psum_in[(g*32) +: 32]}) +
                $signed({bias_vec[((g&7)*32)+31],
                         bias_vec[((g&7)*32) +: 32]});
            assign ref_sum_ext[g] = {{32{ref_sum[g][32]}}, ref_sum[g]};
            assign ref_mul_ext[g] =
                {{33{multiplier_vec[((g&7)*32)+31]}},
                 multiplier_vec[((g&7)*32) +: 32]};
            assign ref_product_wide[g] = ref_sum_ext[g] * ref_mul_ext[g];
            assign ref_product[g] = ref_product_wide[g][63:0];
            requant_activation_core u_ref (
                .product_int64(ref_product[g]),
                .shift(shift_vec[((g&7)*6) +: 6]),
                .output_zero_point_int32(output_zero_point_int32),
                .activation_min_int32(activation_min_int32),
                .activation_max_int32(activation_max_int32),
                .output_int8(ref_data[g])
            );
        end
    endgenerate

    requant_activation_stream2_slots #(.FIFO_DEPTH(128)) dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .psum_in(psum_in), .lane_mask_in(lane_mask_in),
        .pixel_base(pixel_base), .cout_base(cout_base),
        .output_pixels(output_pixels), .output_channels(output_channels),
        .bias_vec(bias_vec), .multiplier_vec(multiplier_vec),
        .shift_vec(shift_vec),
        .output_zero_point_int32(output_zero_point_int32),
        .activation_min_int32(activation_min_int32),
        .activation_max_int32(activation_max_int32),
        .valid_out(valid_out), .ready_out(ready_out),
        .out_pixel_idx(out_pixel_idx), .out_channel_idx(out_channel_idx),
        .out_data(out_data), .busy(busy)
    );

    always #5 clk = ~clk;

    reg [7:0] expected_pixel [0:MAX_EXPECT-1];
    reg [8:0] expected_channel [0:MAX_EXPECT-1];
    reg signed [7:0] expected_data [0:MAX_EXPECT-1];
    integer expected_count;
    integer output_count;
    integer accepted_count;
    integer errors;
    integer cycle_no;
    integer seed;
    integer b;
    integer lane;
    integer v;
    reg stalled_prev;
    reg [7:0] stalled_pixel;
    reg [8:0] stalled_channel;
    reg signed [7:0] stalled_data;

    task record_expected;
        integer k;
        begin
            for (k = 0; k < 64; k = k + 1) begin
                if (lane_mask_in[k]) begin
                    expected_pixel[expected_count] = pixel_base + (k >> 3);
                    expected_channel[expected_count] = cout_base + (k & 7);
                    expected_data[expected_count] = ref_data[k];
                    expected_count = expected_count + 1;
                end
            end
            accepted_count = accepted_count + 1;
        end
    endtask

    /* Stable-output check catches any FIFO pointer or elastic-pipeline
     * update while the consumer is stalled. */
    always @(posedge clk) begin
        if (rst_n) begin
            if (stalled_prev) begin
                if (!valid_out || out_pixel_idx !== stalled_pixel ||
                    out_channel_idx !== stalled_channel ||
                    out_data !== stalled_data) begin
                    $display("STALL_CHANGED cycle=%0d valid=%b tag=%0d/%0d data=%0d",
                             cycle_no, valid_out, out_pixel_idx,
                             out_channel_idx, out_data);
                    errors = errors + 1;
                end
                if (ready_out)
                    stalled_prev = 1'b0;
            end
            if (valid_out && !ready_out) begin
                stalled_prev = 1'b1;
                stalled_pixel = out_pixel_idx;
                stalled_channel = out_channel_idx;
                stalled_data = out_data;
            end
            if (valid_out && ready_out) begin
                if (output_count >= expected_count) begin
                    $display("EARLY_OUTPUT cycle=%0d output=%0d expected=%0d",
                             cycle_no, output_count, expected_count);
                    errors = errors + 1;
                end else begin
                    if (out_pixel_idx !== expected_pixel[output_count] ||
                        out_channel_idx !== expected_channel[output_count] ||
                        out_data !== expected_data[output_count]) begin
                        $display("MISMATCH n=%0d got=%0d/%0d/%0d exp=%0d/%0d/%0d",
                                 output_count, out_pixel_idx, out_channel_idx,
                                 out_data, expected_pixel[output_count],
                                 expected_channel[output_count],
                                 expected_data[output_count]);
                        errors = errors + 1;
                    end
                end
                output_count = output_count + 1;
            end
        end
    end

    /* Output backpressure has short and long stalls plus a pseudo-random
     * phase; this also forces the internal FIFO near its capacity. */
    always @(negedge clk) begin
        if (!rst_n) begin
            ready_out <= 1'b1;
        end else begin
            cycle_no = cycle_no + 1;
            case (cycle_no % 23)
                1, 2, 3, 9, 10, 17, 18, 19: ready_out <= 1'b0;
                default: ready_out <= ((cycle_no * 29 + 7) % 11) > 2;
            endcase
        end
    end

    task make_bundle;
        input integer bi;
        integer q;
        integer mode;
        begin
            pixel_base = (bi * 5) & 6'h3f;
            cout_base = (bi * 11) & 9'h1ff;
            output_pixels = 8'd8;
            output_channels = 9'd8;
            lane_mask_in = 64'd0;
            mode = bi % 12;
            case (mode)
                0: lane_mask_in = 64'd0;
                1: lane_mask_in = 64'hffff_ffff_ffff_ffff;
                2: lane_mask_in = 64'h8000_0000_0000_0001;
                3: lane_mask_in = 64'h0102_0408_1020_4080;
                4: lane_mask_in = 64'h0000_ffff_0000_ffff;
                5: lane_mask_in = 64'hffff_0000_ffff_0000;
                6: lane_mask_in = 64'h1111_1111_1111_1111;
                7: lane_mask_in = 64'h5555_aaaa_5555_aaaa;
                8: lane_mask_in = 64'h0000_0000_ffff_ffff;
                default: lane_mask_in = {$urandom(seed), $urandom(seed)};
            endcase

            for (q = 0; q < 64; q = q + 1) begin
                if (mode == 1) begin
                    case (q & 3)
                        0: v = 32'sh7fffffff;
                        1: v = -32'sh80000000;
                        2: v = q * 1000 - 31000;
                        default: v = 0;
                    endcase
                end else if (mode == 2) begin
                    v = (q & 1) ? -32'sd777777 : 32'sd888888;
                end else if (mode == 3) begin
                    v = ($urandom(seed) % 2000001) - 1000000;
                end else begin
                    v = ($urandom(seed) % 1000001) - 500000;
                end
                psum_in[(q*32) +: 32] = v;

                if ((mode == 4) && ((q & 7) == 0))
                    v = 32'sh7fffffff;
                else if ((mode == 5) && ((q & 7) == 1))
                    v = -32'sh80000000;
                else
                    v = ($urandom(seed) % 200001) - 100000;
                bias_vec[(q*32) +: 32] = v;

                case ((mode + q) & 7)
                    0: v = 32'sh7fffffff;
                    1: v = -32'sh80000000;
                    2: v = 32'sh40000000;
                    3: v = -32'sh40000000;
                    default: v = ($urandom(seed) % 1000000001) - 500000000;
                endcase
                multiplier_vec[(q*32) +: 32] = v;
                shift_vec[(q*6) +: 6] = (bi * 13 + q * 7) & 6'h3f;
            end

            case (mode)
                0: begin output_zero_point_int32 = 0; activation_min_int32 = -128; activation_max_int32 = 127; end
                1: begin output_zero_point_int32 = 17; activation_min_int32 = -100; activation_max_int32 = 100; end
                2: begin output_zero_point_int32 = -23; activation_min_int32 = -64; activation_max_int32 = 63; end
                3: begin output_zero_point_int32 = 127; activation_min_int32 = 0; activation_max_int32 = 127; end
                4: begin output_zero_point_int32 = -128; activation_min_int32 = -128; activation_max_int32 = 0; end
                5: begin output_zero_point_int32 = 3; activation_min_int32 = -7; activation_max_int32 = 9; end
                6: begin output_zero_point_int32 = -1; activation_min_int32 = -127; activation_max_int32 = 126; end
                default: begin
                    output_zero_point_int32 = ($urandom(seed) % 511) - 255;
                    activation_min_int32 = -128 + ($urandom(seed) % 97);
                    activation_max_int32 = activation_min_int32 + 32 + ($urandom(seed) % 97);
                    if (activation_max_int32 > 127) activation_max_int32 = 127;
                end
            endcase
        end
    endtask

    task drive_bundle;
        input integer bi;
        begin
            @(negedge clk);
            make_bundle(bi);
            valid_in = 1'b1;
            while (1) begin
                @(posedge clk);
                if (ready_in) begin
                    record_expected();
                    break;
                end
                @(negedge clk);
            end
            @(negedge clk);
            valid_in = 1'b0;
            /* Deliberate source bubbles exercise empty pipeline slots and
             * make configuration changes occur while old data is active. */
            if ((bi % 9) == 0)
                repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        valid_in = 1'b0;
        psum_in = 0;
        lane_mask_in = 0;
        pixel_base = 0;
        cout_base = 0;
        output_pixels = 8'd8;
        output_channels = 9'd8;
        bias_vec = 0;
        multiplier_vec = 0;
        shift_vec = 0;
        output_zero_point_int32 = 0;
        activation_min_int32 = -128;
        activation_max_int32 = 127;
        ready_out = 1'b1;
        expected_count = 0;
        output_count = 0;
        accepted_count = 0;
        errors = 0;
        cycle_no = 0;
        seed = 32'h2d9f_81a7;
        stalled_prev = 1'b0;
        stalled_pixel = 0;
        stalled_channel = 0;
        stalled_data = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        for (b = 0; b < BUNDLES; b = b + 1)
            drive_bundle(b);
        @(negedge clk);
        valid_in = 1'b0;

        while ((output_count < expected_count || busy) && cycle_no < 200000)
            @(posedge clk);
        if (accepted_count != BUNDLES || output_count != expected_count || busy) begin
            $display("FAIL timeout accepted=%0d/%0d outputs=%0d/%0d busy=%b cycles=%0d",
                     accepted_count, BUNDLES, output_count, expected_count,
                     busy, cycle_no);
            $fatal;
        end
        if (errors != 0) begin
            $display("FAIL tb_requant_activation_stream2_slots errors=%0d",
                     errors);
            $fatal;
        end
        $display("PASS tb_requant_activation_stream2_slots bundles=%0d outputs=%0d cycles=%0d",
                 accepted_count, output_count, cycle_no);
        $finish;
    end
endmodule

`default_nettype wire
