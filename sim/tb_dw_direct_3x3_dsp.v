`timescale 1ns/1ps
`default_nettype none

module tb_dw_direct_3x3_dsp;
    reg clk, rst_n, cfg_valid;
    reg [3:0] cfg_tap_idx;
    reg signed [127:0] cfg_weight_vec;
    reg signed [511:0] cfg_bias_vec;
    reg signed [511:0] cfg_multiplier_vec;
    reg [95:0] cfg_shift_vec;
    wire cfg_ready;

    reg valid_in, first_tap, last_tap, ready_out;
    reg [3:0] tap_idx;
    reg [7:0] pixel_idx;
    reg [15:0] lane_mask;
    reg signed [127:0] act_vec;
    wire ready_in, valid_out;
    wire [7:0] out_pixel_idx;
    wire [15:0] out_lane_mask;
    wire signed [511:0] out_raw_vec;
    wire signed [511:0] out_bias_vec;
    wire signed [511:0] out_multiplier_vec;
    wire [95:0] out_shift_vec;

    integer errors;
    integer case_id, lane_count, tap, lane;
    integer pixel_tag, bias_value, multiplier_value, shift_value;
    integer expected [0:15];
    integer actual;
    reg [15:0] expected_mask;
    reg [15:0] held_mask;
    reg [7:0] held_pixel;
    reg signed [31:0] held_raw [0:15];
    reg signed [31:0] held_bias [0:15];
    reg signed [31:0] held_multiplier [0:15];
    reg [5:0] held_shift [0:15];

    dw_direct_3x3_dsp dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec),
        .valid_in(valid_in), .ready_in(ready_in),
        .first_tap(first_tap), .last_tap(last_tap), .tap_idx(tap_idx),
        .pixel_idx(pixel_idx), .lane_mask(lane_mask), .act_vec(act_vec),
        .valid_out(valid_out), .ready_out(ready_out),
        .out_pixel_idx(out_pixel_idx), .out_lane_mask(out_lane_mask),
        .out_raw_vec(out_raw_vec), .out_bias_vec(out_bias_vec),
        .out_multiplier_vec(out_multiplier_vec), .out_shift_vec(out_shift_vec)
    );

    always #5 clk <= ~clk;

    function integer activation_value;
        input integer tap_arg;
        input integer lane_arg;
        input integer tag_arg;
        input integer test_arg;
        begin
            if (test_arg == 1)
                activation_value = (((tap_arg + lane_arg + tag_arg) & 1) == 0)
                                 ? -128 : 127;
            else if (test_arg == 2)
                activation_value = ((tap_arg * 29 + lane_arg * 17 + tag_arg * 7 + 31) % 255) - 127;
            else
                activation_value = ((tap_arg * 37 + lane_arg * 19 + tag_arg * 11 + 23) % 97) - 48;
        end
    endfunction

    function integer weight_value;
        input integer tap_arg;
        input integer lane_arg;
        input integer tag_arg;
        input integer test_arg;
        begin
            if (test_arg == 1)
                weight_value = (((tap_arg * 3 + lane_arg + tag_arg) & 1) == 0)
                             ? 127 : -128;
            else if (test_arg == 2)
                weight_value = ((tap_arg * 13 + lane_arg * 31 + tag_arg * 5 + 47) % 251) - 125;
            else
                weight_value = ((tap_arg * 23 + lane_arg * 7 + tag_arg * 13 + 9) % 83) - 41;
        end
    endfunction

    task configure_case;
        begin
            bias_value = (case_id == 1) ? -123456 : ((case_id == 2) ? 765432 : -3217);
            multiplier_value = (case_id == 1) ? 98765 : ((case_id == 2) ? -45678 : 1337);
            shift_value = (case_id == 1) ? 3 : ((case_id == 2) ? 17 : 29);
            for (tap = 0; tap < 9; tap = tap + 1) begin
                @(negedge clk);
                cfg_weight_vec = 128'sd0;
                for (lane = 0; lane < 16; lane = lane + 1)
                    cfg_weight_vec[(lane*8) +: 8] = weight_value(tap, lane, pixel_tag, case_id);
                cfg_bias_vec = 512'sd0;
                cfg_multiplier_vec = 512'sd0;
                cfg_shift_vec = 96'd0;
                for (lane = 0; lane < 16; lane = lane + 1) begin
                    cfg_bias_vec[(lane*32) +: 32] = bias_value + lane * 101;
                    cfg_multiplier_vec[(lane*32) +: 32] = multiplier_value - lane * 37;
                    cfg_shift_vec[(lane*6) +: 6] = shift_value + lane;
                end
                cfg_tap_idx = tap[3:0];
                cfg_valid = 1'b1;
                while (!cfg_ready)
                    @(negedge clk);
                @(posedge clk);
                @(negedge clk);
                cfg_valid = 1'b0;
            end
        end
    endtask

    task feed_tap;
        input integer tap_arg;
        begin
            @(negedge clk);
            act_vec = 128'sd0;
            for (lane = 0; lane < 16; lane = lane + 1)
                act_vec[(lane*8) +: 8] = activation_value(tap_arg, lane, pixel_tag, case_id);
            tap_idx = tap_arg[3:0];
            first_tap = (tap_arg == 0);
            last_tap = (tap_arg == 8);
            lane_mask = (lane_count == 16) ? 16'hffff : ((16'h0001 << lane_count) - 1);
            pixel_idx = pixel_tag[7:0];
            valid_in = 1'b1;
            while (!ready_in)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            valid_in = 1'b0;
            first_tap = 1'b0;
            last_tap = 1'b0;
            tap_idx = 4'd0;
            lane_mask = 16'd0;
            /* Deliberate source bubbles. */
            if ((tap_arg == 2) || (tap_arg == 6))
                repeat (2) @(posedge clk);
        end
    endtask

    task check_output;
        begin
            while (!valid_out)
                @(posedge clk);
            held_pixel = out_pixel_idx;
            held_mask = out_lane_mask;
            for (lane = 0; lane < 16; lane = lane + 1) begin
                held_raw[lane] = $signed(out_raw_vec[(lane*32) +: 32]);
                held_bias[lane] = $signed(out_bias_vec[(lane*32) +: 32]);
                held_multiplier[lane] = $signed(out_multiplier_vec[(lane*32) +: 32]);
                held_shift[lane] = out_shift_vec[(lane*6) +: 6];
            end
            ready_out = 1'b0;
            repeat (3) begin
                @(posedge clk);
                if (!valid_out || out_pixel_idx !== held_pixel || out_lane_mask !== held_mask)
                    errors = errors + 1;
                for (lane = 0; lane < 16; lane = lane + 1) begin
                    if ($signed(out_raw_vec[(lane*32) +: 32]) !== held_raw[lane])
                        errors = errors + 1;
                    if ($signed(out_bias_vec[(lane*32) +: 32]) !== held_bias[lane])
                        errors = errors + 1;
                    if ($signed(out_multiplier_vec[(lane*32) +: 32]) !== held_multiplier[lane])
                        errors = errors + 1;
                    if (out_shift_vec[(lane*6) +: 6] !== held_shift[lane])
                        errors = errors + 1;
                end
            end
            if (out_pixel_idx !== pixel_tag[7:0])
                errors = errors + 1;
            if (out_lane_mask !== expected_mask)
                errors = errors + 1;
            for (lane = 0; lane < 16; lane = lane + 1) begin
                actual = $signed(out_raw_vec[(lane*32) +: 32]);
                if (actual !== expected[lane]) begin
                    $display("MISMATCH case=%0d tag=%0d lane=%0d exp=%0d got=%0d",
                             case_id, pixel_tag, lane, expected[lane], actual);
                    errors = errors + 1;
                end
                if ($signed(out_bias_vec[(lane*32) +: 32]) !== bias_value + lane * 101)
                    errors = errors + 1;
                if ($signed(out_multiplier_vec[(lane*32) +: 32]) !== multiplier_value - lane * 37)
                    errors = errors + 1;
                if (out_shift_vec[(lane*6) +: 6] !== ((shift_value + lane) & 63))
                    errors = errors + 1;
            end
            ready_out = 1'b1;
            @(posedge clk);
            if (valid_out)
                errors = errors + 1;
        end
    endtask

    task run_case;
        input integer lane_arg;
        input integer tag_arg;
        begin
            lane_count = lane_arg;
            pixel_tag = tag_arg;
            configure_case();
            expected_mask = (lane_count == 16) ? 16'hffff : ((16'h0001 << lane_count) - 1);
            for (lane = 0; lane < 16; lane = lane + 1) begin
                expected[lane] = 0;
                if (lane < lane_count)
                    expected[lane] = bias_value + lane * 101;
            end
            for (tap = 0; tap < 9; tap = tap + 1)
                for (lane = 0; lane < 16; lane = lane + 1)
                    if (lane < lane_count)
                        expected[lane] = expected[lane] +
                            activation_value(tap, lane, pixel_tag, case_id) *
                            weight_value(tap, lane, pixel_tag, case_id);

            /* Hold the completed transaction under backpressure. */
            for (tap = 0; tap < 9; tap = tap + 1)
                feed_tap(tap);
            check_output();
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cfg_valid = 1'b0;
        cfg_tap_idx = 4'd0;
        cfg_weight_vec = 128'sd0;
        cfg_bias_vec = 512'sd0;
        cfg_multiplier_vec = 512'sd0;
        cfg_shift_vec = 96'd0;
        valid_in = 1'b0;
        first_tap = 1'b0;
        last_tap = 1'b0;
        tap_idx = 4'd0;
        pixel_idx = 8'd0;
        lane_mask = 16'd0;
        act_vec = 128'sd0;
        ready_out = 1'b1;
        errors = 0;
        case_id = 0;
        lane_count = 16;
        pixel_tag = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        case_id = 0;
        run_case(16, 7);
        case_id = 1;
        run_case(5, 203);
        case_id = 2;
        run_case(13, 91);

        if (dut.sim_protocol_errors != 0)
            errors = errors + dut.sim_protocol_errors;
        if (errors == 0)
            $display("PASS tb_dw_direct_3x3_dsp cases=3 taps=27 lanes=34");
        else begin
            $display("FAIL tb_dw_direct_3x3_dsp errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule

`default_nettype wire
