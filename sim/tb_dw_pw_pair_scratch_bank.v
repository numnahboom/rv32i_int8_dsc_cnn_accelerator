`timescale 1ns/1ps
`default_nettype none

module tb_dw_pw_pair_scratch_bank;
    localparam SW = 2;
    localparam EW = 2;
    localparam GW = 5;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg dw_acquire_valid; wire dw_acquire_ready; reg dw_acquire_bank;
    reg [SW-1:0] dw_acquire_session; reg [EW-1:0] dw_acquire_epoch;
    reg [GW-1:0] dw_acquire_group_count;
    reg dw_write_valid; wire dw_write_ready; reg dw_write_bank;
    reg [GW-1:0] dw_write_group; reg dw_write_half;
    reg [255:0] dw_write_data; reg [31:0] dw_write_lane_mask;
    reg dw_commit_valid; wire dw_commit_ready; reg dw_commit_bank;
    reg [SW-1:0] dw_commit_session; reg [EW-1:0] dw_commit_epoch;
    reg pw_acquire_valid; wire pw_acquire_ready; reg pw_acquire_bank;
    reg [SW-1:0] pw_acquire_session; reg [EW-1:0] pw_acquire_epoch;
    reg pw_read_valid; wire pw_read_ready; reg pw_read_bank;
    reg [GW-1:0] pw_read_group; wire pw_out_valid; reg pw_out_ready;
    wire [511:0] pw_out_data; wire [63:0] pw_out_lane_mask;
    reg pw_release_valid; wire pw_release_ready; reg pw_release_bank;
    wire [1:0] bank0_state, bank1_state;
    wire [GW-1:0] bank0_group_cursor, bank1_group_cursor;
    wire [5:0] bank0_retired_halves, bank1_retired_halves;
    wire [GW-1:0] bank0_retired_groups, bank1_retired_groups;

    dw_pw_pair_scratch_bank #(.SESSION_WIDTH(SW), .EPOCH_WIDTH(EW),
                               .GROUP_WIDTH(GW), .MAX_GROUPS(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid), .dw_acquire_ready(dw_acquire_ready),
        .dw_acquire_bank(dw_acquire_bank), .dw_acquire_session(dw_acquire_session),
        .dw_acquire_epoch(dw_acquire_epoch), .dw_acquire_group_count(dw_acquire_group_count),
        .dw_write_valid(dw_write_valid), .dw_write_ready(dw_write_ready),
        .dw_write_bank(dw_write_bank), .dw_write_group(dw_write_group),
        .dw_write_half(dw_write_half), .dw_write_data(dw_write_data),
        .dw_write_lane_mask(dw_write_lane_mask),
        .dw_commit_valid(dw_commit_valid), .dw_commit_ready(dw_commit_ready),
        .dw_commit_bank(dw_commit_bank), .dw_commit_session(dw_commit_session),
        .dw_commit_epoch(dw_commit_epoch),
        .pw_acquire_valid(pw_acquire_valid), .pw_acquire_ready(pw_acquire_ready),
        .pw_acquire_bank(pw_acquire_bank), .pw_acquire_session(pw_acquire_session),
        .pw_acquire_epoch(pw_acquire_epoch),
        .pw_read_valid(pw_read_valid), .pw_read_ready(pw_read_ready),
        .pw_read_bank(pw_read_bank), .pw_read_group(pw_read_group),
        .pw_out_valid(pw_out_valid), .pw_out_ready(pw_out_ready),
        .pw_out_data(pw_out_data), .pw_out_lane_mask(pw_out_lane_mask),
        .pw_release_valid(pw_release_valid), .pw_release_ready(pw_release_ready),
        .pw_release_bank(pw_release_bank),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .bank0_group_cursor(bank0_group_cursor), .bank1_group_cursor(bank1_group_cursor),
        .bank0_retired_halves(bank0_retired_halves), .bank1_retired_halves(bank1_retired_halves),
        .bank0_retired_groups(bank0_retired_groups), .bank1_retired_groups(bank1_retired_groups)
    );

    integer errors = 0;
    integer checks = 0;
    integer cycles = 0;
    integer case_i, bank_i, session_i, epoch_i, groups_i, active_pixels;
    integer g, h, p, ch, lane, stall, read_g;
    reg [255:0] data_i;
    reg [31:0] mask_top_i, mask_bottom_i;
    reg [511:0] exp_data;
    reg [63:0] exp_mask;
    reg [31:0] rng_state;

    always @(posedge clk) cycles = cycles + 1;

    task automatic random_step;
        begin
            rng_state = {rng_state[30:0], rng_state[31] ^ rng_state[21] ^
                         rng_state[1] ^ rng_state[0]};
        end
    endtask

    function automatic [7:0] value_for;
        input integer ci;
        input integer bi;
        input integer si;
        input integer gi;
        input integer pi;
        input integer ch_i;
        begin
            value_for = (8'h31 + ci*11 + bi*37 + si*19 + gi*7 + pi*13 + ch_i*5) & 8'hff;
        end
    endfunction

    task automatic defaults;
        begin
            dw_acquire_valid = 0; dw_write_valid = 0; dw_commit_valid = 0;
            pw_acquire_valid = 0; pw_read_valid = 0; pw_release_valid = 0;
            pw_out_ready = 0;
            dw_acquire_bank = 0; dw_acquire_session = 0; dw_acquire_epoch = 0;
            dw_acquire_group_count = 0;
            dw_write_bank = 0; dw_write_group = 0; dw_write_half = 0;
            dw_write_data = 0; dw_write_lane_mask = 0;
            dw_commit_bank = 0; dw_commit_session = 0; dw_commit_epoch = 0;
            pw_acquire_bank = 0; pw_acquire_session = 0; pw_acquire_epoch = 0;
            pw_read_bank = 0; pw_read_group = 0;
            pw_release_bank = 0;
        end
    endtask

    task automatic acquire_dw;
        input integer bi; input integer si; input integer ei; input integer ng;
        begin
            dw_acquire_bank = bi[0]; dw_acquire_session = si[SW-1:0];
            dw_acquire_epoch = ei[EW-1:0]; dw_acquire_group_count = ng[GW-1:0];
            dw_acquire_valid = 1;
            @(posedge clk); #1 dw_acquire_valid = 0;
        end
    endtask

    task automatic write_half_task;
        input integer ci; input integer bi; input integer si; input integer gi; input integer hi;
        begin
            data_i = 256'd0;
            for (p = 0; p < 4; p = p + 1)
                for (ch = 0; ch < 8; ch = ch + 1)
                    data_i[(p*8+ch)*8 +: 8] = value_for(ci, bi, si, gi,
                                                            hi ? p+4 : p, ch);
            mask_top_i = 32'd0; mask_bottom_i = 32'd0;
            for (p = 0; p < 4; p = p + 1)
                for (ch = 0; ch < 8; ch = ch + 1)
                    if ((hi ? p+4 : p) < active_pixels &&
                        !(ci == 128 && gi == 15 && ch >= 5))
                        if (hi) mask_bottom_i[p*8+ch] = 1'b1;
                        else mask_top_i[p*8+ch] = 1'b1;
            dw_write_bank = bi[0]; dw_write_group = gi[GW-1:0];
            dw_write_half = hi[0]; dw_write_data = data_i;
            dw_write_lane_mask = hi ? mask_bottom_i : mask_top_i;
            random_step();
            stall = rng_state % 3;
            dw_write_valid = 0;
            repeat (stall) @(posedge clk);
            dw_write_valid = 1;
            @(posedge clk); #1 dw_write_valid = 0;
        end
    endtask

    task automatic commit_dw_task;
        input integer bi; input integer si; input integer ei;
        begin
            dw_commit_bank = bi[0]; dw_commit_session = si[SW-1:0];
            dw_commit_epoch = ei[EW-1:0]; dw_commit_valid = 1;
            @(posedge clk); #1 dw_commit_valid = 0;
        end
    endtask

    task automatic acquire_pw_task;
        input integer bi; input integer si; input integer ei;
        begin
            pw_acquire_bank = bi[0]; pw_acquire_session = si[SW-1:0];
            pw_acquire_epoch = ei[EW-1:0]; pw_acquire_valid = 1;
            @(posedge clk); #1 pw_acquire_valid = 0;
        end
    endtask

    task automatic read_group_task;
        input integer ci; input integer bi; input integer si; input integer gi;
        begin
            pw_read_bank = bi[0]; pw_read_group = gi[GW-1:0]; pw_read_valid = 1;
            @(posedge clk); #1 pw_read_valid = 0;
            while (!pw_out_valid) @(posedge clk);
            exp_data = 512'd0; exp_mask = 64'd0;
            for (p = 0; p < 8; p = p + 1)
                for (ch = 0; ch < 8; ch = ch + 1) begin
                    exp_data[(p*8+ch)*8 +: 8] = value_for(ci, bi, si, gi, p, ch);
                    if (p < active_pixels && !(ci == 128 && gi == 15 && ch >= 5))
                        exp_mask[p*8+ch] = 1'b1;
                end
            checks = checks + 1;
            #1;
            if (pw_out_data !== exp_data || pw_out_lane_mask !== exp_mask) begin
                $display("FAIL read c=%0d b=%0d s=%0d g=%0d got=%h/%h exp=%h/%h",
                         ci, bi, si, gi, pw_out_data, pw_out_lane_mask,
                         exp_data, exp_mask);
                errors = errors + 1;
            end
            random_step();
            stall = rng_state % 4;
            repeat (stall) begin
                @(posedge clk); #1;
                if (!pw_out_valid || pw_out_data !== exp_data || pw_out_lane_mask !== exp_mask)
                    errors = errors + 1;
            end
            pw_out_ready = 1;
            @(posedge clk); #1 pw_out_ready = 0;
        end
    endtask

    task automatic release_pw_task;
        input integer bi;
        begin
            pw_release_bank = bi[0]; pw_release_valid = 1;
            @(posedge clk); #1 pw_release_valid = 0;
        end
    endtask

    task automatic run_case;
        input integer ci; input integer bi; input integer si; input integer ei;
        input integer ng; input integer ap;
        begin
            groups_i = ng; active_pixels = ap;
            acquire_dw(bi, si, ei, ng);
            /* A DW-owned bank cannot be read or reacquired before commit. */
            pw_read_bank = bi[0]; pw_read_group = 0; pw_read_valid = 1;
            #1;
            if (pw_read_ready) errors = errors + 1;
            pw_read_valid = 0;
            dw_acquire_bank = bi[0]; dw_acquire_session = si + 1;
            dw_acquire_epoch = ei[EW-1:0]; dw_acquire_group_count = ng[GW-1:0];
            dw_acquire_valid = 1;
            #1;
            if (dw_acquire_ready) errors = errors + 1;
            dw_acquire_valid = 0;
            /* A stale commit tag cannot close the write session. */
            dw_commit_bank = bi[0]; dw_commit_session = si + 1;
            dw_commit_epoch = ei[EW-1:0]; dw_commit_valid = 1;
            @(posedge clk); #1;
            if (dw_commit_ready) errors = errors + 1;
            dw_commit_valid = 0;
            for (g = 0; g < ng; g = g + 1) begin
                random_step();
                if (rng_state[0]) begin
                    write_half_task(ci, bi, si, g, 1);
                    write_half_task(ci, bi, si, g, 0);
                end else begin
                    write_half_task(ci, bi, si, g, 0);
                    write_half_task(ci, bi, si, g, 1);
                end
            end
            if (!bi && bank0_retired_halves !== ng*2) errors = errors + 1;
            if (bi && bank1_retired_halves !== ng*2) errors = errors + 1;
            /* A complete bank remains write-locked until commit/release. */
            dw_write_bank = bi[0]; dw_write_group = ng-1; dw_write_half = 0;
            dw_write_valid = 1;
            #1;
            if (dw_write_ready) errors = errors + 1;
            dw_write_valid = 0;
            commit_dw_task(bi, si, ei);
            /* Wrong read-side tag is rejected until the matching acquire. */
            pw_acquire_bank = bi[0]; pw_acquire_session = si + 1;
            pw_acquire_epoch = ei[EW-1:0]; pw_acquire_valid = 1;
            @(posedge clk); #1;
            if (pw_acquire_ready) errors = errors + 1;
            pw_acquire_valid = 0;
            pw_read_bank = bi[0]; pw_read_group = 0; pw_read_valid = 1;
            #1;
            if (pw_read_ready) errors = errors + 1;
            pw_read_valid = 0;
            acquire_pw_task(bi, si, ei);
            for (read_g = ng-1; read_g >= 0; read_g = read_g - 1)
                read_group_task(ci, bi, si, read_g);
            release_pw_task(bi);
        end
    endtask

    initial begin
        defaults();
        rng_state = 32'h1a2b_3c4d;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        #1;
        /* Bank 0: three groups and a 7-pixel spatial tail. */
        run_case(16, 0, 1, 1, 2, 7);
        /* Bank 1: six groups and a half-order swap on every other group. */
        run_case(48, 1, 2, 2, 6, 8);
        /* Reuse bank 0 with all 16 groups and a final Cin-group channel tail. */
        run_case(128, 0, 3, 3, 16, 5);
        if (errors == 0)
            $display("PASS paired-half scratch bank checks=%0d cycles=%0d", checks, cycles);
        else
            $display("FAIL paired-half scratch bank errors=%0d checks=%0d cycles=%0d", errors, checks, cycles);
        $finish;
    end
endmodule

`default_nettype wire
