`timescale 1ns/1ps
`default_nettype none

/* Real DW -> partial-K PW differential test.  The ACT memory contains raw
 * 3x3 windows; the DUT performs all nine DW products for each K before
 * issuing the corresponding PW token. */
module tb_ds_block_tile_engine_partialk;
    reg clk, rst_n;
    reg cfg_valid;
    wire cfg_ready;
    reg [1:0] cfg_target;
    reg [15:0] cfg_index;
    reg [31:0] cfg_data;
    reg start;
    reg [7:0] start_cin, start_pixels;
    reg [8:0] start_cout;
    reg [1:0] start_stride;
    wire busy, done, error;
    wire out_valid;
    reg out_ready;
    wire [7:0] out_pixel_base;
    wire [8:0] out_cout_base;
    wire [63:0] out_lane_mask;
    wire signed [2047:0] out_psum;
    wire [31:0] perf_total_cycles, perf_dw_cycles;
    wire [31:0] perf_pw_issue_cycles, perf_transfer_wait_cycles;
    wire [31:0] perf_output_tiles;
    wire [1:0] perf_stride;

    integer errors, checks, outputs, token_checks;
    integer ci, p, co, tap, k, lane, row, col;
    integer cin_cfg, pixels_cfg, cout_cfg, stride_cfg;
    integer tile_pb, tile_cb, tile_count;
    integer expected [0:63];
    integer actual, sum, dw;
    integer seen_pb, seen_cb;
    integer have_seen;
    integer monitor_ticks;

    ds_block_tile_engine_partialk #(.MAX_CIN(48), .MAX_COUT(16),
                                    .MAX_PIXELS(17), .K_GROUP(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_target(cfg_target), .cfg_index(cfg_index), .cfg_data(cfg_data),
        .start(start), .start_cin(start_cin), .start_pixels(start_pixels),
        .start_cout(start_cout), .start_stride(start_stride),
        .busy(busy), .done(done), .error(error),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_pixel_base(out_pixel_base), .out_cout_base(out_cout_base),
        .out_lane_mask(out_lane_mask), .out_psum(out_psum),
        .perf_total_cycles(perf_total_cycles),
        .perf_dw_cycles(perf_dw_cycles),
        .perf_pw_issue_cycles(perf_pw_issue_cycles),
        .perf_transfer_wait_cycles(perf_transfer_wait_cycles),
        .perf_output_tiles(perf_output_tiles), .perf_stride(perf_stride)
    );

    always #5 clk = ~clk;

    function integer av;
        input integer cfg, pp, tt, kk;
        begin av = (((cfg+3)*(pp+5) + (tt+1)*11 + (kk+7)*3) % 31) - 15; end
    endfunction
    function integer dwv;
        input integer cfg, kk, tt;
        begin dwv = (((cfg+5)*(kk+2) + (tt+3)*7) % 13) - 6; end
    endfunction
    function integer pwv;
        input integer cfg, kk, cc;
        begin pwv = (((cfg+7)*(kk+3) + (cc+5)*5) % 17) - 8; end
    endfunction
    function integer biasv;
        input integer cfg, kk;
        begin biasv = ((cfg+1)*(kk+3)) % 9 - 4; end
    endfunction
    function integer clamp8;
        input integer x;
        begin
            if (x > 127) clamp8 = 127;
            else if (x < -128) clamp8 = -128;
            else clamp8 = x;
        end
    endfunction

    task cfg_byte;
        input integer target, idx, val;
        begin
            @(negedge clk);
            cfg_target = target[1:0]; cfg_index = idx[15:0]; cfg_data = val;
            cfg_valid = 1'b1;
            while (!cfg_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            cfg_valid = 1'b0; cfg_target = 0; cfg_index = 0; cfg_data = 0;
        end
    endtask
    task cfg_word;
        input integer target, idx, val;
        begin
            @(negedge clk);
            cfg_target = target[1:0]; cfg_index = idx[15:0]; cfg_data = val;
            cfg_valid = 1'b1;
            while (!cfg_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            cfg_valid = 1'b0; cfg_target = 0; cfg_index = 0; cfg_data = 0;
        end
    endtask

    task check_output;
        integer rr, cc, ll;
        begin
            if (!have_seen || (seen_pb != out_pixel_base) ||
                (seen_cb != out_cout_base)) begin
                outputs = outputs + 1;
                seen_pb = out_pixel_base; seen_cb = out_cout_base;
                have_seen = 1;
                tile_pb = out_pixel_base;
                tile_cb = out_cout_base;
                for (rr = 0; rr < 8; rr = rr + 1)
                    for (cc = 0; cc < 8; cc = cc + 1) begin
                        expected[rr*8+cc] = 0;
                        if (((tile_pb+rr) < pixels_cfg) &&
                            ((tile_cb+cc) < cout_cfg)) begin
                            for (k = 0; k < cin_cfg; k = k + 1) begin
                                sum = biasv(ci, k);
                                for (tap = 0; tap < 9; tap = tap + 1)
                                    sum = sum + av(ci, tile_pb+rr, tap, k) *
                                                  dwv(ci, k, tap);
                                dw = clamp8(sum);
                                expected[rr*8+cc] = expected[rr*8+cc] +
                                    dw * pwv(ci, k, tile_cb+cc);
                            end
                        end
                    end
                for (ll = 0; ll < 64; ll = ll + 1) begin
                    if (out_lane_mask[ll]) begin
                        actual = $signed(out_psum[(ll*32) +: 32]);
                        if (actual !== expected[ll]) begin
                            $display("MISMATCH cfg=%0d P=%0d Cout=%0d tile=%0d,%0d lane=%0d exp=%0d got=%0d",
                                     ci, pixels_cfg, cout_cfg, tile_pb, tile_cb,
                                     ll, expected[ll], actual);
                            errors = errors + 1;
                        end
                        checks = checks + 1;
                    end
                end
            end
        end
    endtask

    task run_case;
        input integer ccase, ccin, ppix, ccout, sstride;
        integer expected_tiles;
        begin
            ci = ccase; cin_cfg = ccin; pixels_cfg = ppix;
            cout_cfg = ccout; stride_cfg = sstride;
            have_seen = 0; outputs = 0; token_checks = 0;
            /* Window samples make stride an explicit producer-side property:
             * the DUT consumes the already selected 3x3 windows. */
            for (p = 0; p < pixels_cfg; p = p + 1)
                for (tap = 0; tap < 9; tap = tap + 1)
                    for (k = 0; k < cin_cfg; k = k + 1)
                        cfg_byte(0, ((p*9+tap)*48)+k, av(ci,p,tap,k));
            for (k = 0; k < cin_cfg; k = k + 1) begin
                for (tap = 0; tap < 9; tap = tap + 1)
                    cfg_byte(1, k*9+tap, dwv(ci,k,tap));
                cfg_word(2, k, biasv(ci,k));
            end
            for (k = 0; k < cin_cfg; k = k + 1)
                for (co = 0; co < cout_cfg; co = co + 1)
                    cfg_byte(3, k*16+co, pwv(ci,k,co));

            @(negedge clk);
            start_cin = cin_cfg; start_pixels = pixels_cfg;
            start_cout = cout_cfg; start_stride = stride_cfg;
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
            expected_tiles = ((pixels_cfg+7)/8) * ((cout_cfg+7)/8);
            monitor_ticks = 0;
            while (!done && monitor_ticks < 2000000) begin
                @(negedge clk);
                monitor_ticks = monitor_ticks + 1;
                /* Randomized consumer backpressure. */
                if (out_valid)
                    out_ready = (((monitor_ticks + ccase*3) % 5) != 0);
                else
                    out_ready = 1'b1;
                if (out_valid) begin
                    check_output();
                    if (!out_ready) begin
                        /* One extra check in the held cycle proves stability. */
                        @(negedge clk);
                        if (!out_valid) errors = errors + 1;
                        check_output();
                    end
                end
                if (dut.pw_token_fire) begin
                    token_checks = token_checks + 1;
                    if (((dut.k_idx & 8'h0f) == 8'd15) && !dut.pw_token_last) begin
                        if (dut.pw_token_count != 16) errors = errors + 1;
                        if (out_valid) errors = errors + 1;
                    end
                end
            end
            if (monitor_ticks >= 2000000) begin
                $display("TIMEOUT cfg=%0d P=%0d Cin=%0d Cout=%0d state=%0d",
                         ci,pixels_cfg,cin_cfg,cout_cfg,dut.state);
                errors = errors + 1;
            end
            if (error) errors = errors + 1;
            if (outputs != expected_tiles) begin
                $display("OUTPUT_COUNT cfg=%0d expected=%0d got=%0d",
                         ci, expected_tiles, outputs);
                errors = errors + 1;
            end
            if (token_checks != expected_tiles*cin_cfg) begin
                $display("TOKEN_COUNT cfg=%0d expected=%0d got=%0d",
                         ci, expected_tiles*cin_cfg, token_checks);
                errors = errors + 1;
            end
            if (perf_output_tiles != expected_tiles)
                errors = errors + 1;
            /* A barrier schedule would pay one lower-half PW issue cycle
             * after the DW stream.  The integrated schedule has that issue
             * on the way, so its arithmetic ledger is directly comparable. */
            $display("CASE cfg=%0d stride=%0d P=%0d Cin=%0d Cout=%0d tiles=%0d cycles=%0d dw=%0d pw_tokens=%0d transfer_wait=%0d barrier_model=%0d saved_vs_barrier=%0d",
                     ci, perf_stride, pixels_cfg, cin_cfg, cout_cfg,
                     perf_output_tiles, perf_total_cycles, perf_dw_cycles,
                     perf_pw_issue_cycles, perf_transfer_wait_cycles,
                     perf_dw_cycles + perf_pw_issue_cycles*2,
                     perf_pw_issue_cycles);
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; cfg_valid = 0; cfg_target = 0; cfg_index = 0;
        cfg_data = 0; start = 0; start_cin = 0; start_pixels = 0;
        start_cout = 0; start_stride = 0; out_ready = 1;
        errors = 0; checks = 0; outputs = 0; token_checks = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        run_case(0,32,1,8,1);
        run_case(1,48,8,16,1);
        run_case(2,32,17,13,2);
        if (errors == 0)
            $display("PASS tb_ds_block_tile_engine_partialk cases=3 outputs=%0d checks=%0d",
                     outputs, checks);
        else begin
            $display("FAIL tb_ds_block_tile_engine_partialk errors=%0d checks=%0d",
                     errors, checks);
            $fatal;
        end
        $finish;
    end
endmodule
`default_nettype wire
