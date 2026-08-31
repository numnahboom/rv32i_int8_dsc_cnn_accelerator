`timescale 1ns/1ps
`default_nettype none

module tb_dw_window_reuse_scheduler;
    localparam integer MAX_CIN = 128;
    localparam integer MAX_IN_H = 17;
    localparam integer MAX_IN_W = 17;
    localparam integer LANES = 16;
    localparam integer LINEAR_ADDR_WIDTH = 16;

    reg clk, rst_n;
    reg wr_en;
    reg [LINEAR_ADDR_WIDTH-1:0] wr_linear_idx;
    reg signed [7:0] wr_data_int8;
    reg wr_vec4_en;
    reg [LINEAR_ADDR_WIDTH-1:0] wr_vec4_linear_idx;
    reg [31:0] wr_vec4_data_int8;
    reg cfg_valid;
    wire cfg_ready;
    reg [3:0] cfg_tap_idx;
    reg signed [127:0] cfg_weight_vec;
    reg signed [511:0] cfg_bias_vec;
    reg signed [511:0] cfg_multiplier_vec;
    reg [95:0] cfg_shift_vec;
    reg start;
    reg [8:0] start_channel_tile;
    reg [15:0] start_lane_mask;
    wire busy, done;
    wire valid_out;
    reg ready_out;
    wire [7:0] out_pixel_idx;
    wire [15:0] out_lane_mask;
    wire signed [511:0] out_raw_vec;
    wire signed [511:0] out_bias_vec;
    wire signed [511:0] out_multiplier_vec;
    wire [95:0] out_shift_vec;
    wire [15:0] buffer_read_count;
    wire [15:0] core_token_count;
    wire [7:0] output_count;

    integer errors;
    integer case_id;
    integer case_tile;
    integer case_mask_count;
    integer footprint;
    integer px, py, lane, tap, outx, outy;
    integer out_seen;
    integer stall_phase;
    integer sim_cycle;
    integer start_cycle;
    integer expected_raw [0:15];
    integer got_raw;
    integer bias_value;

    dw_window_reuse_scheduler #(
        .MAX_CIN(MAX_CIN), .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W),
        .LANES(LANES), .TILE_H(8), .TILE_W(8), .STRIDE(1),
        .LINEAR_ADDR_WIDTH(LINEAR_ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_linear_idx(wr_linear_idx),
        .wr_data_int8(wr_data_int8), .wr_vec4_en(wr_vec4_en),
        .wr_vec4_linear_idx(wr_vec4_linear_idx),
        .wr_vec4_data_int8(wr_vec4_data_int8),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec), .start(start),
        .start_channel_tile(start_channel_tile),
        .start_lane_mask(start_lane_mask), .busy(busy), .done(done),
        .valid_out(valid_out), .ready_out(ready_out),
        .out_pixel_idx(out_pixel_idx), .out_lane_mask(out_lane_mask),
        .out_raw_vec(out_raw_vec), .out_bias_vec(out_bias_vec),
        .out_multiplier_vec(out_multiplier_vec), .out_shift_vec(out_shift_vec),
        .buffer_read_count(buffer_read_count),
        .core_token_count(core_token_count), .output_count(output_count)
    );

    always #5 clk <= ~clk;
    always @(posedge clk) sim_cycle = sim_cycle + 1;

    function integer act_value;
        input integer yy, xx, ll, cc;
        begin
            /* The footprint contains explicit one-pixel zero padding. */
            if ((yy == 0) || (xx == 0) || (yy == 9) || (xx == 9))
                act_value = 0;
            else
                act_value = (((yy*19 + xx*11 + ll*7 + cc*13 + 17) % 253) - 126);
        end
    endfunction

    function integer wgt_value;
        input integer tt, ll, cc;
        begin
            wgt_value = (((tt*23 + ll*17 + cc*29 + 31) % 251) - 125);
        end
    endfunction

    task write_footprint;
        begin
            for (py = 0; py < footprint; py = py + 1) begin
                for (px = 0; px < footprint; px = px + 1) begin
                    for (lane = 0; lane < LANES; lane = lane + 1) begin
                        @(negedge clk);
                        wr_en = 1'b1;
                        wr_linear_idx = ((py*footprint + px) * MAX_CIN) +
                                        case_tile*LANES + lane;
                        wr_data_int8 = act_value(py, px, lane, case_id);
                        @(posedge clk);
                        @(negedge clk);
                        wr_en = 1'b0;
                    end
                end
            end
            @(negedge clk);
            wr_en = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task configure_weights;
        begin
            bias_value = -4000 + case_id*1733;
            for (tap = 0; tap < 9; tap = tap + 1) begin
                @(negedge clk);
                cfg_weight_vec = 128'sd0;
                for (lane = 0; lane < LANES; lane = lane + 1)
                    cfg_weight_vec[(lane*8) +: 8] = wgt_value(tap, lane, case_id);
                cfg_bias_vec = 512'sd0;
                cfg_multiplier_vec = 512'sd0;
                cfg_shift_vec = 96'd0;
                for (lane = 0; lane < LANES; lane = lane + 1) begin
                    cfg_bias_vec[(lane*32) +: 32] = bias_value + lane*37;
                    cfg_multiplier_vec[(lane*32) +: 32] = 32'sd1;
                    cfg_shift_vec[(lane*6) +: 6] = 0;
                end
                cfg_tap_idx = tap;
                cfg_valid = 1'b1;
                while (!cfg_ready) @(negedge clk);
                @(posedge clk);
                @(negedge clk);
                cfg_valid = 1'b0;
            end
        end
    endtask

    task calculate_pixel_expected;
        input integer pixel_arg;
        begin
            for (lane = 0; lane < LANES; lane = lane + 1)
                expected_raw[lane] = bias_value + lane*37;
            for (tap = 0; tap < 9; tap = tap + 1)
                for (lane = 0; lane < LANES; lane = lane + 1)
                    if ((lane < case_mask_count) ||
                        (case_mask_count == 16))
                        expected_raw[lane] = expected_raw[lane] +
                            act_value(pixel_arg/8 + tap/3,
                                      pixel_arg%8 + tap%3,
                                      lane, case_id) *
                            wgt_value(tap, lane, case_id);
        end
    endtask

    task run_case;
        begin
            footprint = 10;
            write_footprint();
            configure_weights();
            @(negedge clk);
            start_channel_tile = case_tile;
            start_lane_mask = (16'h0001 << case_mask_count) - 1;
            if (case_mask_count == 16)
                start_lane_mask = 16'hffff;
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
            start_cycle = sim_cycle;
            out_seen = 0;
            stall_phase = 0;
            ready_out = 1'b1;
            while (!done) begin
                @(negedge clk);
                if (valid_out) begin
            calculate_pixel_expected(out_seen);
                    if (out_pixel_idx !== out_seen[7:0]) begin
                        $display("PIXEL mismatch case=%0d exp=%0d got=%0d",
                                 case_id, out_seen, out_pixel_idx);
                        errors = errors + 1;
                    end
                    if (out_lane_mask !== start_lane_mask)
                        errors = errors + 1;
                    for (lane = 0; lane < LANES; lane = lane + 1) begin
                        got_raw = $signed(out_raw_vec[(lane*32) +: 32]);
                        if (lane < case_mask_count) begin
                            if (got_raw !== expected_raw[lane]) begin
                                $display("RAW mismatch case=%0d pix=%0d lane=%0d exp=%0d got=%0d",
                                    case_id, out_seen, lane, expected_raw[lane], got_raw);
                                errors = errors + 1;
                            end
                        end else if (got_raw !== 0) begin
                            errors = errors + 1;
                        end
                    end
                    /* Periodic output stalls exercise the direct core's
                     * one-entry output hold and the scheduler token hold. */
                    stall_phase = stall_phase + 1;
                    if ((stall_phase % 7) == 0)
                        ready_out = 1'b0;
                    else
                        ready_out = 1'b1;
                    if (valid_out && ready_out)
                        out_seen = out_seen + 1;
                end else begin
                    ready_out = 1'b1;
                end
            end
            $display("CASE %0d latency_cycles=%0d reads=%0d tokens=%0d outputs=%0d",
                     case_id, sim_cycle-start_cycle, buffer_read_count,
                     core_token_count, output_count);
            if (out_seen !== 64) errors = errors + 1;
            if (buffer_read_count !== 100) begin
                $display("READ count mismatch case=%0d got=%0d", case_id,
                         buffer_read_count);
                errors = errors + 1;
            end
            if (dut.core_token_count !== 576) errors = errors + 1;
            if (dut.output_count !== 64) errors = errors + 1;
            while (busy) @(negedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        wr_en = 1'b0;
        wr_linear_idx = 0;
        wr_data_int8 = 0;
        wr_vec4_en = 1'b0;
        wr_vec4_linear_idx = 0;
        wr_vec4_data_int8 = 0;
        cfg_valid = 1'b0;
        cfg_tap_idx = 0;
        cfg_weight_vec = 0;
        cfg_bias_vec = 0;
        cfg_multiplier_vec = 0;
        cfg_shift_vec = 0;
        start = 1'b0;
        start_channel_tile = 0;
        start_lane_mask = 0;
        ready_out = 1'b1;
        errors = 0;
        sim_cycle = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        case_id = 0; case_tile = 0; case_mask_count = 3;  run_case();
        case_id = 1; case_tile = 0; case_mask_count = 16; run_case();
        case_id = 2; case_tile = 1; case_mask_count = 16; run_case();
        case_id = 3; case_tile = 2; case_mask_count = 5;  run_case();

        if (errors == 0)
            $display("PASS tb_dw_window_reuse_scheduler cases=4 reads=400 tokens=2304");
        else begin
            $display("FAIL tb_dw_window_reuse_scheduler errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end
endmodule

`default_nettype wire
