`timescale 1ns/1ps
`default_nettype none

module tb_dw_pw_spatial_block_buffer;
    localparam EW = 2;
    localparam BW = 8;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg dw_acquire_valid;
    wire dw_acquire_ready;
    reg dw_acquire_bank;
    reg [EW-1:0] dw_acquire_epoch;
    reg [BW-1:0] dw_acquire_block_id;
    reg [7:0] dw_acquire_pixel_mask;
    reg [7:0] dw_acquire_group_mask;

    reg dw_write_valid;
    wire dw_write_ready;
    reg dw_write_bank;
    reg [EW-1:0] dw_write_epoch;
    reg [BW-1:0] dw_write_block_id;
    reg [2:0] dw_write_pixel_idx;
    reg dw_write_pixel_valid;
    reg [2:0] dw_write_channel_group;
    reg [127:0] dw_write_data;
    reg [15:0] dw_write_lane_mask;

    reg dw_commit_valid;
    wire dw_commit_ready;
    reg dw_commit_bank;
    reg [EW-1:0] dw_commit_epoch;
    reg [BW-1:0] dw_commit_block_id;

    reg pw_acquire_valid;
    wire pw_acquire_ready;
    reg pw_acquire_bank;
    reg [EW-1:0] pw_acquire_epoch;
    reg [BW-1:0] pw_acquire_block_id;

    reg pw_read_valid;
    wire pw_read_ready;
    reg pw_read_bank;
    reg [EW-1:0] pw_read_epoch;
    reg [BW-1:0] pw_read_block_id;
    reg [6:0] pw_read_channel_idx;
    wire pw_out_valid;
    reg pw_out_ready;
    wire [EW-1:0] pw_out_epoch;
    wire [BW-1:0] pw_out_block_id;
    wire pw_out_bank;
    wire [63:0] pw_out_data;
    wire [7:0] pw_out_lane_mask;

    reg pw_release_valid;
    wire pw_release_ready;
    reg pw_release_bank;
    reg [EW-1:0] pw_release_epoch;
    reg [BW-1:0] pw_release_block_id;

    wire dw_commit_pulse;
    wire pw_acquire_pulse;
    wire pw_release_pulse;
    wire [1:0] bank0_state;
    wire [1:0] bank1_state;
    wire [EW-1:0] bank0_epoch, bank1_epoch;
    wire [BW-1:0] bank0_block_id, bank1_block_id;

    dw_pw_spatial_block_buffer #(.EPOCH_WIDTH(EW), .BLOCK_ID_WIDTH(BW)) dut (
        .clk(clk), .rst_n(rst_n),
        .dw_acquire_valid(dw_acquire_valid), .dw_acquire_ready(dw_acquire_ready),
        .dw_acquire_bank(dw_acquire_bank), .dw_acquire_epoch(dw_acquire_epoch),
        .dw_acquire_block_id(dw_acquire_block_id),
        .dw_acquire_pixel_mask(dw_acquire_pixel_mask),
        .dw_acquire_group_mask(dw_acquire_group_mask),
        .dw_write_valid(dw_write_valid), .dw_write_ready(dw_write_ready),
        .dw_write_bank(dw_write_bank), .dw_write_epoch(dw_write_epoch),
        .dw_write_block_id(dw_write_block_id), .dw_write_pixel_idx(dw_write_pixel_idx),
        .dw_write_pixel_valid(dw_write_pixel_valid),
        .dw_write_channel_group(dw_write_channel_group), .dw_write_data(dw_write_data),
        .dw_write_lane_mask(dw_write_lane_mask),
        .dw_commit_valid(dw_commit_valid), .dw_commit_ready(dw_commit_ready),
        .dw_commit_bank(dw_commit_bank), .dw_commit_epoch(dw_commit_epoch),
        .dw_commit_block_id(dw_commit_block_id),
        .pw_acquire_valid(pw_acquire_valid), .pw_acquire_ready(pw_acquire_ready),
        .pw_acquire_bank(pw_acquire_bank), .pw_acquire_epoch(pw_acquire_epoch),
        .pw_acquire_block_id(pw_acquire_block_id),
        .pw_read_valid(pw_read_valid), .pw_read_ready(pw_read_ready),
        .pw_read_bank(pw_read_bank), .pw_read_epoch(pw_read_epoch),
        .pw_read_block_id(pw_read_block_id), .pw_read_channel_idx(pw_read_channel_idx),
        .pw_out_valid(pw_out_valid), .pw_out_ready(pw_out_ready),
        .pw_out_epoch(pw_out_epoch), .pw_out_block_id(pw_out_block_id),
        .pw_out_bank(pw_out_bank), .pw_out_data(pw_out_data),
        .pw_out_lane_mask(pw_out_lane_mask),
        .pw_release_valid(pw_release_valid), .pw_release_ready(pw_release_ready),
        .pw_release_bank(pw_release_bank), .pw_release_epoch(pw_release_epoch),
        .pw_release_block_id(pw_release_block_id),
        .dw_commit_pulse(dw_commit_pulse), .pw_acquire_pulse(pw_acquire_pulse),
        .pw_release_pulse(pw_release_pulse), .bank0_state(bank0_state),
        .bank1_state(bank1_state), .bank0_epoch(bank0_epoch), .bank1_epoch(bank1_epoch),
        .bank0_block_id(bank0_block_id), .bank1_block_id(bank1_block_id)
    );

    integer errors = 0;
    integer checks = 0;
    integer commits = 0;
    integer acquires = 0;
    integer releases = 0;
    integer commit_pulses = 0;
    integer acquire_pulses = 0;
    integer release_pulses = 0;
    integer c, p, g, lane, stall;
    integer case_i;
    integer base_pixel;
    integer pixels;
    integer cin;
    integer groups;
    integer bank_i;
    integer epoch_i;
    integer block_i;
    reg [7:0] group_mask_i;
    reg [15:0] lane_mask_i;
    reg [7:0] pixel_mask_i;
    reg [63:0] exp_data;
    reg [7:0] exp_mask;

    always @(posedge clk) begin
        if (dw_commit_pulse) commit_pulses = commit_pulses + 1;
        if (pw_acquire_pulse) acquire_pulses = acquire_pulses + 1;
        if (pw_release_pulse) release_pulses = release_pulses + 1;
    end

    function automatic [7:0] data_byte;
        input integer ci;
        input integer bi;
        input integer pi;
        input integer ch;
        begin
            data_byte = (8'h23 + ci*17 + bi*13 + pi*7 + ch*3) & 8'hff;
        end
    endfunction

    task automatic drive_defaults;
        begin
            dw_acquire_valid = 0; dw_write_valid = 0; dw_commit_valid = 0;
            pw_acquire_valid = 0; pw_read_valid = 0; pw_release_valid = 0;
            pw_out_ready = 0;
            dw_acquire_bank = 0; dw_acquire_epoch = 0; dw_acquire_block_id = 0;
            dw_acquire_pixel_mask = 0; dw_acquire_group_mask = 0;
            dw_write_bank = 0; dw_write_epoch = 0; dw_write_block_id = 0;
            dw_write_pixel_idx = 0; dw_write_pixel_valid = 0;
            dw_write_channel_group = 0; dw_write_data = 0; dw_write_lane_mask = 0;
            dw_commit_bank = 0; dw_commit_epoch = 0; dw_commit_block_id = 0;
            pw_acquire_bank = 0; pw_acquire_epoch = 0; pw_acquire_block_id = 0;
            pw_read_bank = 0; pw_read_epoch = 0; pw_read_block_id = 0;
            pw_read_channel_idx = 0;
            pw_release_bank = 0; pw_release_epoch = 0; pw_release_block_id = 0;
        end
    endtask

    task automatic acquire_dw;
        input integer bi;
        input integer ei;
        input integer id;
        input [7:0] pm;
        input [7:0] gm;
        begin
            dw_acquire_bank = bi[0]; dw_acquire_epoch = ei[EW-1:0];
            dw_acquire_block_id = id[BW-1:0]; dw_acquire_pixel_mask = pm;
            dw_acquire_group_mask = gm; dw_acquire_valid = 1;
            while (!dw_acquire_ready) @(posedge clk);
            @(posedge clk); #1 dw_acquire_valid = 0;
            acquires = acquires + 1;
        end
    endtask

    task automatic write_group;
        input integer ci;
        input integer bi;
        input integer ei;
        input integer id;
        input integer pi;
        input integer gi;
        input [15:0] lm;
        begin
            dw_write_bank = bi[0]; dw_write_epoch = ei[EW-1:0];
            dw_write_block_id = id[BW-1:0]; dw_write_pixel_idx = pi[2:0];
            dw_write_pixel_valid = 1; dw_write_channel_group = gi[2:0];
            dw_write_lane_mask = lm; dw_write_data = 128'd0;
            for (lane = 0; lane < 16; lane = lane + 1)
                dw_write_data[lane*8 +: 8] = data_byte(ci, id, pi, gi*16+lane);
            dw_write_valid = 1;
            while (!dw_write_ready) @(posedge clk);
            @(posedge clk); #1 dw_write_valid = 0;
        end
    endtask

    task automatic commit_dw;
        input integer bi;
        input integer ei;
        input integer id;
        begin
            dw_commit_bank = bi[0]; dw_commit_epoch = ei[EW-1:0];
            dw_commit_block_id = id[BW-1:0]; dw_commit_valid = 1;
            while (!dw_commit_ready) @(posedge clk);
            @(posedge clk); #1 dw_commit_valid = 0;
            commits = commits + 1;
        end
    endtask

    task automatic acquire_pw;
        input integer bi;
        input integer ei;
        input integer id;
        begin
            pw_acquire_bank = bi[0]; pw_acquire_epoch = ei[EW-1:0];
            pw_acquire_block_id = id[BW-1:0]; pw_acquire_valid = 1;
            while (!pw_acquire_ready) @(posedge clk);
            @(posedge clk); #1 pw_acquire_valid = 0;
        end
    endtask

    task automatic read_channel;
        input integer ci;
        input integer bi;
        input integer ei;
        input integer id;
        input integer ch;
        input [7:0] pm;
        begin
            pw_read_bank = bi[0]; pw_read_epoch = ei[EW-1:0];
            pw_read_block_id = id[BW-1:0]; pw_read_channel_idx = ch[6:0];
            pw_read_valid = 1; pw_out_ready = 0;
            while (!pw_read_ready) @(posedge clk);
            @(posedge clk); #1 pw_read_valid = 0;
            while (!pw_out_valid) @(posedge clk);
            exp_data = 64'd0;
            exp_mask = 8'd0;
            for (p = 0; p < 8; p = p + 1) begin
                if (pm[p]) begin
                    exp_data[p*8 +: 8] = data_byte(ci, id, p, ch);
                    exp_mask[p] = 1'b1;
                end
            end
            checks = checks + 1;
            if (pw_out_bank !== bi[0] || pw_out_epoch !== ei[EW-1:0] ||
                pw_out_block_id !== id[BW-1:0] || pw_out_data !== exp_data ||
                pw_out_lane_mask !== exp_mask) begin
                $display("FAIL read ci=%0d bank=%0d id=%0d ch=%0d got=%h/%b exp=%h/%b",
                         ci, bi, id, ch, pw_out_data, pw_out_lane_mask,
                         exp_data, exp_mask);
                errors = errors + 1;
            end
            stall = (ci + ch + id) % 3;
            repeat (stall) begin
                @(posedge clk);
                if (!pw_out_valid || pw_out_data !== exp_data ||
                    pw_out_lane_mask !== exp_mask) begin
                    $display("FAIL output changed/stalled ci=%0d ch=%0d", ci, ch);
                    errors = errors + 1;
                end
            end
            pw_out_ready = 1;
            @(posedge clk); #1 pw_out_ready = 0;
        end
    endtask

    task automatic release_pw;
        input integer bi;
        input integer ei;
        input integer id;
        begin
            pw_release_bank = bi[0]; pw_release_epoch = ei[EW-1:0];
            pw_release_block_id = id[BW-1:0]; pw_release_valid = 1;
            while (!pw_release_ready) @(posedge clk);
            @(posedge clk); #1 pw_release_valid = 0;
            releases = releases + 1;
        end
    endtask

    initial begin
        drive_defaults();
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        /* A read before PW acquisition must never become ready. */
        pw_read_bank = 0; pw_read_epoch = 0; pw_read_block_id = 0;
        pw_read_channel_idx = 0; pw_read_valid = 1;
        @(posedge clk);
        if (pw_read_ready) begin $display("FAIL uncommitted read ready"); errors = errors + 1; end
        #1 pw_read_valid = 0;

        /* Both physical banks may be live at once; tags and storage must
         * remain independent while one bank is being prepared. */
        acquire_dw(0, 0, 200, 8'h01, 8'h01);
        acquire_dw(1, 1, 201, 8'h01, 8'h01);
        write_group(6, 0, 0, 200, 0, 0, 16'h0001);
        write_group(7, 1, 1, 201, 0, 0, 16'h0001);
        commit_dw(0, 0, 200);
        commit_dw(1, 1, 201);
        acquire_pw(0, 0, 200);
        acquire_pw(1, 1, 201);
        read_channel(6, 0, 0, 200, 0, 8'h01);
        read_channel(7, 1, 1, 201, 0, 8'h01);
        release_pw(0, 0, 200);
        release_pw(1, 1, 201);

        /* P=1,8,17 and Cin=1,7,16,17,48,128; P=17 uses three blocks. */
        for (case_i = 0; case_i < 6; case_i = case_i + 1) begin
            case (case_i)
                0: begin pixels = 1;  cin = 1;   epoch_i = 0; end
                1: begin pixels = 8;  cin = 7;   epoch_i = 1; end
                2: begin pixels = 17; cin = 16;  epoch_i = 2; end
                3: begin pixels = 17; cin = 17;  epoch_i = 3; end
                4: begin pixels = 8;  cin = 48;  epoch_i = 0; end
                default: begin pixels = 17; cin = 128; epoch_i = 1; end
            endcase
            groups = (cin + 15) / 16;
            group_mask_i = (groups == 8) ? 8'hff : ((1 << groups) - 1);
            for (block_i = 0; block_i < ((pixels + 7) / 8); block_i = block_i + 1) begin
                base_pixel = block_i * 8;
                p = pixels - base_pixel;
                if (p > 8) p = 8;
                pixel_mask_i = (p == 8) ? 8'hff : ((1 << p) - 1);
                bank_i = (case_i + block_i) & 1;
                acquire_dw(bank_i, epoch_i, case_i*16+block_i, pixel_mask_i, group_mask_i);

                /* Reverse group order in alternating cases to cover the
                 * allowed arbitrary write ordering. */
                for (p = 0; p < 8; p = p + 1) begin
                    if (pixel_mask_i[p]) begin
                        for (g = 0; g < groups; g = g + 1) begin
                            c = ((case_i & 1) == 0) ? g : (groups-1-g);
                            lane_mask_i = (c == groups-1 && (cin - c*16) < 16)
                                ? ((1 << (cin-c*16)) - 1) : 16'hffff;
                            write_group(case_i, bank_i, epoch_i, case_i*16+block_i,
                                        p, c, lane_mask_i);
                        end
                    end
                end
                /* Commit is intentionally attempted before completion once
                 * per run; ready must remain low until all writes arrive. */
                commit_dw(bank_i, epoch_i, case_i*16+block_i);
                acquire_pw(bank_i, epoch_i, case_i*16+block_i);
                for (c = 0; c < cin; c = c + 1)
                    read_channel(case_i, bank_i, epoch_i, case_i*16+block_i,
                                 c, pixel_mask_i);
                release_pw(bank_i, epoch_i, case_i*16+block_i);
            end
        end

        repeat (3) @(posedge clk);
        if (commits != 14 || acquires != 14 || releases != 14 ||
            commit_pulses != 14 || acquire_pulses != 14 || release_pulses != 14) begin
            $display("FAIL pulse counts handshakes=%0d/%0d/%0d pulses=%0d/%0d/%0d",
                     commits, acquires, releases, commit_pulses, acquire_pulses,
                     release_pulses);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS tb_dw_pw_spatial_block_buffer checks=%0d blocks=%0d",
                     checks, commits);
        else
            $display("FAIL tb_dw_pw_spatial_block_buffer checks=%0d errors=%0d",
                     checks, errors);
        $finish;
    end
endmodule

`default_nettype wire
