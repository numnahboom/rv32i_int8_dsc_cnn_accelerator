`timescale 1ns/1ps
`default_nettype none

/* Exact source/consumer harness for the non-production DMA/window shell. */
module tb_ds_dma_window_pingpong_shell #(
    parameter integer TB_LAYOUT_CIN = 16
);
    localparam integer EXTENT = 100 * TB_LAYOUT_CIN;
    localparam integer BASE0 = 0;
    localparam integer BASE1 = 20000;
    localparam integer NUM_TILES = (TB_LAYOUT_CIN + 15) / 16;
    reg clk = 0, rst_n = 0;
    reg fill_start_valid = 0, fill_start_bank = 0;
    reg [3:0] fill_start_epoch = 0;
    reg [23:0] fill_base_byte_addr = 0;
    reg [15:0] fill_extent = 0;
    wire fill_start_ready, fill_done_valid, fill_done_bank;
    wire [3:0] fill_done_epoch;
    reg fill_done_ready = 1;
    wire mem_req_valid; reg mem_req_ready = 1;
    wire [23:0] mem_req_addr;
    reg mem_resp_valid = 0; reg [31:0] mem_resp_data = 0;
    reg cfg_valid = 0; wire cfg_ready; reg [3:0] cfg_tap_idx = 0;
    reg signed [127:0] cfg_weight_vec = 0;
    reg signed [511:0] cfg_bias_vec = 0;
    reg signed [511:0] cfg_multiplier_vec = 0;
    reg [95:0] cfg_shift_vec = 0;
    reg compute_start_valid = 0, compute_bank = 0;
    reg [3:0] compute_epoch = 0;
    reg [8:0] compute_channel_tile = 0;
    reg [15:0] compute_lane_mask = 16'hffff;
    reg compute_last_tile = 1;
    wire compute_start_ready, compute_done_valid, compute_done_bank;
    wire [3:0] compute_done_epoch;
    reg compute_done_ready = 1;
    wire valid_out; reg ready_out = 1;
    wire [7:0] out_pixel_idx; wire [15:0] out_lane_mask;
    wire signed [511:0] out_raw_vec, out_bias_vec, out_multiplier_vec;
    wire [95:0] out_shift_vec;
    wire [1:0] bank0_state, bank1_state; wire compute_busy;
    wire [31:0] active_read_count, scheduler_write_count, overlap_cycles;
    wire [15:0] scheduler_buffer_read_count, scheduler_core_token_count;
    wire [7:0] scheduler_output_count;
    wire [31:0] stale_compute_count;

    reg [7:0] source_mem [0:65535];
    reg pipe_valid [0:3]; reg [31:0] pipe_data [0:3];
    reg inject_stale = 0;
    integer cycle_count = 0, errors = 0, i, d;
    integer current_case = 0, current_tile = 0, current_lane_count = 16;
    integer out_seen = 0, output_stall = 0, stall_phase = 0;
    integer expected_raw [0:15];

    ds_dma_window_pingpong_shell #(.LAYOUT_CIN(TB_LAYOUT_CIN)) dut (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_base_byte_addr(fill_base_byte_addr), .fill_extent(fill_extent),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec), .compute_start_valid(compute_start_valid),
        .compute_start_ready(compute_start_ready), .compute_bank(compute_bank),
        .compute_epoch(compute_epoch), .compute_channel_tile(compute_channel_tile),
        .compute_lane_mask(compute_lane_mask), .compute_last_tile(compute_last_tile),
        .compute_done_valid(compute_done_valid), .compute_done_ready(compute_done_ready),
        .compute_done_bank(compute_done_bank), .compute_done_epoch(compute_done_epoch),
        .valid_out(valid_out), .ready_out(ready_out), .out_pixel_idx(out_pixel_idx),
        .out_lane_mask(out_lane_mask), .out_raw_vec(out_raw_vec),
        .out_bias_vec(out_bias_vec), .out_multiplier_vec(out_multiplier_vec),
        .out_shift_vec(out_shift_vec), .bank0_state(bank0_state),
        .bank1_state(bank1_state), .compute_busy(compute_busy),
        .active_read_count(active_read_count), .scheduler_write_count(scheduler_write_count),
        .scheduler_buffer_read_count(scheduler_buffer_read_count),
        .scheduler_core_token_count(scheduler_core_token_count),
        .scheduler_output_count(scheduler_output_count), .overlap_cycles(overlap_cycles),
        .stale_compute_count(stale_compute_count)
    );

    always #5 clk = ~clk;
    function [7:0] value_for;
        input integer bank, off;
        integer p, c, y, x, v;
        begin
            p = off / TB_LAYOUT_CIN; c = off % TB_LAYOUT_CIN;
            y = p / 10; x = p % 10;
            if ((y == 0) || (x == 0) || (y == 9) || (x == 9))
                v = 0;
            else begin
                v = ((bank * 19 + p * 7 + c * 5 + 23) % 61) - 30;
            end
            value_for = v[7:0];
        end
    endfunction
    function [31:0] source_word;
        input [23:0] addr;
        integer q, bank, off;
        begin
            source_word = 0;
            bank = (addr >= BASE1) ? 1 : 0;
            for (q = 0; q < 4; q = q + 1) begin
                off = (addr - (bank ? BASE1 : BASE0)) + q;
                source_word[q*8 +: 8] = source_mem[addr + q];
            end
        end
    endfunction
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (!rst_n) begin
            mem_resp_valid <= 0;
            for (d = 0; d < 4; d = d + 1) begin pipe_valid[d] <= 0; pipe_data[d] <= 0; end
        end else begin
            mem_resp_valid <= inject_stale ? 1'b1 : pipe_valid[0];
            mem_resp_data <= inject_stale ? 32'hdeadbeef : pipe_data[0];
            for (d = 0; d < 3; d = d + 1) begin
                pipe_valid[d] <= pipe_valid[d+1]; pipe_data[d] <= pipe_data[d+1];
            end
            pipe_valid[3] <= 0;
            if (mem_req_valid && mem_req_ready) begin
                pipe_valid[3] <= 1;
                pipe_data[3] <= source_word({mem_req_addr[23:2],2'b00});
            end
        end
    end

    task issue_fill;
        input integer bank, epoch;
        begin
            @(negedge clk); fill_start_bank = bank; fill_start_epoch = epoch;
            fill_base_byte_addr = bank ? BASE1 : BASE0; fill_extent = EXTENT;
            fill_start_valid = 1;
            /* Observe ready on the accepting rising edge.  Waiting for ready
             * at a later falling edge can miss the one-cycle ready window,
             * since the shell deliberately removes it after acceptance. */
            begin : wait_fill_accept
                while (1) begin
                    @(posedge clk);
                    if (fill_start_ready) disable wait_fill_accept;
                end
            end
            @(negedge clk); fill_start_valid = 0;
            while (!fill_done_valid || (fill_done_bank !== bank) ||
                   (fill_done_epoch !== epoch)) @(posedge clk);
            if ((fill_done_bank !== bank) || (fill_done_epoch !== epoch)) begin
                $display("FILL descriptor mismatch bank=%0d epoch=%0d", fill_done_bank, fill_done_epoch);
                errors = errors + 1;
            end
            @(posedge clk);
        end
    endtask
    task start_fill_only;
        input integer bank, epoch;
        begin
            @(negedge clk); fill_start_bank = bank; fill_start_epoch = epoch;
            fill_base_byte_addr = bank ? BASE1 : BASE0; fill_extent = EXTENT;
            fill_start_valid = 1;
            begin : wait_fill_only_accept
                while (1) begin
                    @(posedge clk);
                    if (fill_start_ready) disable wait_fill_only_accept;
                end
            end
            @(negedge clk); fill_start_valid = 0;
        end
    endtask
    task configure;
        integer t, l;
        begin
            for (t = 0; t < 9; t = t + 1) begin
                @(negedge clk); cfg_tap_idx = t; cfg_weight_vec = 0;
                cfg_bias_vec = 0; cfg_multiplier_vec = 0; cfg_shift_vec = 0;
                for (l = 0; l < 16; l = l + 1) begin
                    cfg_weight_vec[l*8 +: 8] = 8'sd1;
                    cfg_bias_vec[l*32 +: 32] = 100 + l;
                    cfg_multiplier_vec[l*32 +: 32] = 1;
                end
                cfg_valid = 1;
                while (!cfg_ready) @(negedge clk);
                @(posedge clk); @(negedge clk); cfg_valid = 0;
            end
        end
    endtask
    task expected_for;
        input integer p;
        integer l, t, yy, xx, off, ch, av;
        begin
            for (l = 0; l < 16; l = l + 1) expected_raw[l] = 100 + l;
            yy = p / 8; xx = p % 8;
            for (t = 0; t < 9; t = t + 1) begin
                for (l = 0; l < 16; l = l + 1) begin
                    ch = current_tile*16 + l;
                    if ((l < current_lane_count) && (ch < TB_LAYOUT_CIN)) begin
                        off = ((yy + t/3)*10 + xx + t%3) * TB_LAYOUT_CIN + ch;
                        av = value_for(current_case, off);
                        if (av >= 128) av = av - 256;
                        expected_raw[l] = expected_raw[l] + av;
                    end
                end
            end
        end
    endtask
    task issue_compute;
        input integer bank, epoch, tile, lane_count, last_tile;
        integer l;
        begin
            current_case = bank; current_tile = tile; current_lane_count = lane_count;
            @(negedge clk); compute_bank = bank; compute_epoch = epoch;
            compute_channel_tile = tile; compute_lane_mask = 0;
            for (l = 0; l < lane_count; l = l + 1) compute_lane_mask[l] = 1'b1;
            compute_last_tile = last_tile; compute_start_valid = 1;
            begin : wait_compute_accept
                while (1) begin
                    @(posedge clk);
                    if (compute_start_ready) disable wait_compute_accept;
                end
            end
            @(negedge clk); compute_start_valid = 0;
            out_seen = 0; stall_phase = 0;
            while (!compute_done_valid) begin
                @(negedge clk);
            if (valid_out) begin
                expected_for(out_seen);
                    if (out_pixel_idx !== out_seen[7:0]) errors = errors + 1;
                    if (out_lane_mask !== compute_lane_mask) errors = errors + 1;
                    for (l = 0; l < 16; l = l + 1) begin
                        if (l < lane_count) begin
                            if ($signed(out_raw_vec[l*32 +: 32]) !== expected_raw[l]) begin
                                errors = errors + 1;
                            end
                        end else if ($signed(out_raw_vec[l*32 +: 32]) !== 0) errors = errors + 1;
                    end
                    stall_phase = stall_phase + 1;
                    ready_out = ((stall_phase % 11) != 0);
                    if (valid_out && ready_out) out_seen = out_seen + 1;
                end else ready_out = 1;
            end
            ready_out = 1;
            if (out_seen !== 64) errors = errors + 1;
            if (active_read_count !== 100) errors = errors + 1;
            if (scheduler_write_count !== 400) errors = errors + 1;
            if (scheduler_buffer_read_count !== 100) errors = errors + 1;
            if (scheduler_core_token_count !== 576) errors = errors + 1;
            if (scheduler_output_count !== 64) errors = errors + 1;
            $display("CASE layout=%0d bank=%0d tile=%0d reads=%0d writes=%0d buf_reads=%0d tokens=%0d overlap=%0d", TB_LAYOUT_CIN,bank,tile,active_read_count,scheduler_write_count,scheduler_buffer_read_count,scheduler_core_token_count,overlap_cycles);
            while (compute_busy) @(negedge clk);
        end
    endtask
    initial begin
        integer bank, off;
        for (bank = 0; bank < 2; bank = bank + 1)
            for (off = 0; off < EXTENT; off = off + 1)
                source_mem[(bank ? BASE1 : BASE0) + off] = value_for(bank, off);
        repeat (4) @(posedge clk); rst_n = 1;
        configure();
        issue_fill(0, 1);
        /* This deliberately holds the first consumer long enough for the
         * inactive writer to complete, proving a real post-start overlap. */
        output_stall = (TB_LAYOUT_CIN == 48) ? 5000 : 2200;
        ready_out = 1;
        @(negedge clk); compute_bank = 0; compute_epoch = 1; compute_channel_tile = 0;
        compute_lane_mask = 16'hffff; compute_last_tile = (TB_LAYOUT_CIN == 16);
        compute_start_valid = 1;
        begin : wait_first_compute_accept
            while (1) begin
                @(posedge clk);
                if (compute_start_ready) disable wait_first_compute_accept;
            end
        end
        @(negedge clk); compute_start_valid = 0;
        /* Start inactive DMA while bank zero is being copied/consumed. */
        start_fill_only(1, 2);
        /* The first output is intentionally released only after the fill
         * command has had time to drain; subsequent outputs are checked. */
        /* The consumer remains ready, so the first output is sampled on the
         * same edge it is presented; the inactive DMA runs concurrently. */
        /* Compute tile zero (and remaining channel tiles for CIN=48). */
        out_seen = 0; current_case = 0; current_tile = 0; current_lane_count = 16;
        while (!compute_done_valid) begin
            @(negedge clk);
            if (valid_out) begin
                expected_for(out_seen); if (out_pixel_idx !== out_seen[7:0]) errors = errors + 1;
                if (out_lane_mask !== 16'hffff) errors = errors + 1;
                for (bank = 0; bank < 16; bank = bank + 1)
                    if ($signed(out_raw_vec[bank*32 +: 32]) !== expected_raw[bank]) begin
                        errors = errors + 1;
                    end
                out_seen = out_seen + valid_out;
            end
        end
        while (!fill_done_valid || (fill_done_bank !== 1'b1) ||
               (fill_done_epoch !== 4'd2)) @(posedge clk);
        @(posedge clk);
        if (out_seen !== 64 || active_read_count !== 100 || scheduler_write_count !== 400 || scheduler_buffer_read_count !== 100 || scheduler_core_token_count !== 576) errors = errors + 1;
        ready_out = 1;
        while (compute_busy) @(negedge clk);
        /* Invalid epoch must not acquire a READY bank. */
        @(negedge clk); compute_bank = 1; compute_epoch = 4'hf; compute_channel_tile = 0; compute_last_tile = 1; compute_start_valid = 1;
        @(posedge clk); @(negedge clk); compute_start_valid = 0;
        if (stale_compute_count == 0) errors = errors + 1;
        if (TB_LAYOUT_CIN == 48) begin
            issue_compute(1, 2, 0, 16, 0);
            issue_compute(1, 2, 1, 16, 0);
            issue_compute(1, 2, 2, 16, 1);
        end else begin
            issue_compute(1, 2, 0, 16, 1);
        end
        if (overlap_cycles == 0) begin $display("ERROR no overlap"); errors = errors + 1; end
        if (errors == 0) $display("PASS tb_ds_dma_window_pingpong_shell layout=%0d sim_cycles=%0d overlap_cycles=%0d", TB_LAYOUT_CIN, cycle_count, overlap_cycles);
        else begin $display("FAIL tb_ds_dma_window_pingpong_shell layout=%0d errors=%0d", TB_LAYOUT_CIN, errors); $fatal(1); end
        $finish;
    end
    initial begin repeat (30000) @(posedge clk); $fatal(1,"WATCHDOG"); end
endmodule
`default_nettype wire
