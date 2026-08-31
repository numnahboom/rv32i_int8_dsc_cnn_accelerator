`timescale 1ns/1ps
`default_nettype none

/* Exact source/consumer bench for the non-production word-window DW island. */
module tb_ds_word_window_dw_producer_island #(
    parameter integer TB_CIN = 16,
    parameter integer TB_STRIDE = 1,
    parameter integer TB_USE_QUADLOCAL = 0
);
    localparam integer FW = (TB_STRIDE == 2) ? 17 : 10;
    localparam integer FH = FW;
    localparam integer WORDS = (FW*FH*16)/4;
    localparam integer TILES = (TB_CIN + 15) / 16;
    localparam [23:0] BASE0 = 24'h100000;
    localparam [23:0] BASE1 = 24'h200000;
    localparam integer ADDR_WIDTH = 24;
    localparam integer VAW = $clog2(17*17*3);

    reg clk = 0, rst_n = 0;
    always #1 clk = ~clk;

    reg fill_start_valid = 0, fill_start_bank = 0;
    reg [3:0] fill_start_epoch = 0;
    reg [23:0] fill_start_base_addr = 0;
    reg [15:0] fill_start_word_count = 0;
    wire fill_start_ready, fill_done_valid, fill_done_bank;
    wire [3:0] fill_done_epoch;
    reg fill_done_ready = 0;
    wire mem_req_valid; reg mem_req_ready = 1;
    wire [23:0] mem_req_addr;
    reg mem_resp_valid = 0; reg [31:0] mem_resp_data = 0;
    reg cfg_valid = 0; wire cfg_ready;
    reg [3:0] cfg_tap_idx = 0;
    reg signed [127:0] cfg_weight_vec = 0;
    reg signed [511:0] cfg_bias_vec = 0;
    reg signed [511:0] cfg_multiplier_vec = 0;
    reg [95:0] cfg_shift_vec = 0;
    reg compute_start_valid = 0, compute_bank = 0;
    reg [3:0] compute_epoch = 0;
    reg [15:0] compute_lane_mask = 16'hffff;
    reg [1:0] compute_stride = TB_STRIDE;
    reg [7:0] compute_footprint_height = FW;
    reg [7:0] compute_footprint_width = FW;
    reg [7:0] compute_pitch = FW;
    wire compute_start_ready, compute_done_valid;
    reg compute_done_ready = 1;
    wire compute_done_bank; wire [3:0] compute_done_epoch;
    wire compute_busy;
    wire valid_out; reg ready_out = 1;
    wire [7:0] out_pixel_idx; wire [15:0] out_lane_mask;
    wire signed [511:0] out_raw_vec, out_bias_vec, out_multiplier_vec;
    wire [95:0] out_shift_vec;
    wire [1:0] bank0_state, bank1_state;
    wire fill_busy, read_busy;
    wire [31:0] fill_word_count_seen, read_vector_count;
    wire [31:0] token_count, overlap_cycles, stale_command_count;

    ds_word_window_dw_producer_island #(
        .MAX_IN_H(17), .MAX_IN_W(17), .MAX_CHANNEL_GROUPS(3),
        .LAYOUT_GROUPS(1), .ADDR_WIDTH(24), .WORD_COUNT_WIDTH(16),
        .VECTOR_ADDR_WIDTH(VAW), .EPOCH_WIDTH(4), .TAG_WIDTH(16), .FIFO_DEPTH(8),
        .USE_QUADLOCAL_CORE(TB_USE_QUADLOCAL)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch),
        .fill_start_base_addr(fill_start_base_addr),
        .fill_start_word_count(fill_start_word_count),
        .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_tap_idx(cfg_tap_idx), .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec), .compute_start_valid(compute_start_valid),
        .compute_start_ready(compute_start_ready), .compute_bank(compute_bank),
        .compute_epoch(compute_epoch), .compute_lane_mask(compute_lane_mask),
        .compute_stride(compute_stride),
        .compute_footprint_height(compute_footprint_height),
        .compute_footprint_width(compute_footprint_width), .compute_pitch(compute_pitch),
        .compute_done_valid(compute_done_valid), .compute_done_ready(compute_done_ready),
        .compute_done_bank(compute_done_bank), .compute_done_epoch(compute_done_epoch),
        .compute_busy(compute_busy),
        .valid_out(valid_out), .ready_out(ready_out), .out_pixel_idx(out_pixel_idx),
        .out_lane_mask(out_lane_mask), .out_raw_vec(out_raw_vec),
        .out_bias_vec(out_bias_vec), .out_multiplier_vec(out_multiplier_vec),
        .out_shift_vec(out_shift_vec), .bank0_state(bank0_state),
        .bank1_state(bank1_state), .fill_busy(fill_busy), .read_busy(read_busy),
        .fill_word_count_seen(fill_word_count_seen), .read_vector_count(read_vector_count),
        .token_count(token_count), .overlap_cycles(overlap_cycles),
        .stale_command_count(stale_command_count)
    );

    function integer signed value_for;
        input integer bank_arg, tile_arg, vector_arg, lane_arg;
        integer row, col, v;
        begin
            row = vector_arg / FW;
            col = vector_arg % FW;
            /* Make the outer footprint ring explicit padding. */
            if ((row == 0) || (col == 0) || (row == FW-1) || (col == FW-1))
                v = 0;
            else begin
                v = (tile_arg*17 + vector_arg*3 + lane_arg*5 + bank_arg*7 + 11) % 31;
                v = v - 15;
            end
            value_for = v;
        end
    endfunction

    function [31:0] source_word;
        input [23:0] addr;
        integer bank_arg, tile_arg, off, vec, lane, byte_v;
        begin
            bank_arg = (addr >= BASE1) ? 1 : 0;
            off = addr - (bank_arg ? BASE1 : BASE0);
            tile_arg = off / 24'h010000;
            off = off - tile_arg * 24'h010000;
            vec = off / 16;
            source_word = 0;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                byte_v = value_for(bank_arg, tile_arg, vec, (off % 16) + lane);
                source_word[lane*8 +: 8] = byte_v[7:0];
            end
        end
    endfunction

    /* Four-cycle response latency and deterministic request bubbles. */
    reg pipe_valid [0:3]; reg [31:0] pipe_data [0:3];
    integer pi, cycle_count = 0, errors = 0;
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (!rst_n) begin
            mem_resp_valid <= 0;
            mem_req_ready <= 1;
            for (pi = 0; pi < 4; pi = pi + 1) begin
                pipe_valid[pi] <= 0; pipe_data[pi] <= 0;
            end
        end else begin
            mem_resp_valid <= pipe_valid[0];
            mem_resp_data <= pipe_data[0];
            for (pi = 0; pi < 3; pi = pi + 1) begin
                pipe_valid[pi] <= pipe_valid[pi+1];
                pipe_data[pi] <= pipe_data[pi+1];
            end
            pipe_valid[3] <= 0;
            mem_req_ready <= ((cycle_count % 19) != 6);
            if (mem_req_valid && mem_req_ready) begin
                pipe_valid[3] <= 1;
                pipe_data[3] <= source_word({mem_req_addr[23:2],2'b00});
            end
        end
    end

    task configure;
        integer t, l;
        begin
            for (t = 0; t < 9; t = t + 1) begin
                @(negedge clk);
                cfg_tap_idx = t; cfg_weight_vec = 0; cfg_bias_vec = 0;
                cfg_multiplier_vec = 0; cfg_shift_vec = 0;
                for (l = 0; l < 16; l = l + 1) begin
                    cfg_weight_vec[l*8 +: 8] = 8'sd1;
                    cfg_multiplier_vec[l*32 +: 32] = 32'sd1;
                end
                cfg_valid = 1;
                while (!cfg_ready) @(negedge clk);
                @(posedge clk); @(negedge clk); cfg_valid = 0;
            end
        end
    endtask

    task start_fill;
        input integer bank_arg, epoch_arg, tile_arg;
        integer wait_cycles;
        begin
            @(negedge clk); fill_start_bank = bank_arg; fill_start_epoch = epoch_arg;
            fill_start_base_addr = (bank_arg ? BASE1 : BASE0) + tile_arg*24'h010000;
            fill_start_word_count = WORDS; fill_start_valid = 1;
            wait_cycles = 0;
            begin : wait_fill_accept
                while (1) begin
                    @(posedge clk); wait_cycles = wait_cycles + 1;
                    if (fill_start_ready) disable wait_fill_accept;
                    if (wait_cycles > 100000) begin
                        $display("START_FILL timeout bank=%0d epoch=%0d states=%b/%b busy=%b",bank_arg,epoch_arg,bank0_state,bank1_state,fill_busy);
                        errors = errors + 1; disable wait_fill_accept;
                    end
                end
            end
            @(negedge clk); fill_start_valid = 0;
        end
    endtask

    task wait_fill;
        input integer bank_arg, epoch_arg;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            begin : wait_fill_loop
                while (!fill_done_valid) begin
                    @(negedge clk); wait_cycles = wait_cycles + 1;
                    if (wait_cycles > 100000) begin
                        $display("WAIT_FILL timeout bank=%0d epoch=%0d states=%b/%b busy=%b req=%b resp=%b",bank_arg,epoch_arg,bank0_state,bank1_state,fill_busy,mem_req_valid,mem_resp_valid);
                        errors = errors + 1; disable wait_fill_loop;
                    end
                end
            end
            if (fill_done_bank !== bank_arg || fill_done_epoch !== epoch_arg)
                errors = errors + 1;
            fill_done_ready = 1;
            @(posedge clk); @(negedge clk); fill_done_ready = 0;
        end
    endtask

    integer active_tile, active_lanes, out_seen, l, t, yy, xx, vec;
    integer expected;
    reg signed [511:0] held_raw;
    reg [7:0] held_pixel;
    task run_compute;
        input integer bank_arg, epoch_arg, tile_arg, lane_count_arg;
        input integer launch_next, next_bank_arg, next_epoch_arg, next_tile_arg;
        begin
            active_tile = tile_arg; active_lanes = lane_count_arg;
            @(negedge clk); compute_bank = bank_arg; compute_epoch = epoch_arg;
            compute_lane_mask = 0;
            for (l = 0; l < lane_count_arg; l = l + 1) compute_lane_mask[l] = 1'b1;
            compute_start_valid = 1;
            begin : wait_compute_accept
                while (1) begin @(posedge clk); if (compute_start_ready) disable wait_compute_accept; end
            end
            @(negedge clk); compute_start_valid = 0;
            if (launch_next != 0)
                start_fill(next_bank_arg, next_epoch_arg, next_tile_arg);
            out_seen = 0; ready_out = 1;
            while (!compute_done_valid) begin
                @(negedge clk);
                ready_out = ((cycle_count % 23) != 7);
                if (valid_out) begin
                    if (!ready_out) begin
                        /* Stability is checked on the next cycle by keeping
                         * ready low; the direct core must hold valid/data. */
                        held_raw = out_raw_vec;
                        held_pixel = out_pixel_idx;
                        @(negedge clk);
                        if (!valid_out || out_pixel_idx !== held_pixel ||
                            out_raw_vec !== held_raw) errors = errors + 1;
                        ready_out = 1;
                    end
                    if (valid_out && ready_out) begin
                        if (out_pixel_idx !== out_seen[7:0]) errors = errors + 1;
                        if (out_lane_mask !== compute_lane_mask) errors = errors + 1;
                        yy = out_seen / 8; xx = out_seen % 8;
                        for (l = 0; l < 16; l = l + 1) begin
                            expected = 0;
                            if (l < lane_count_arg)
                                for (t = 0; t < 9; t = t + 1) begin
                                    vec = (yy*TB_STRIDE + t/3) * FW +
                                          xx*TB_STRIDE + t%3;
                                    expected = expected + value_for(bank_arg, tile_arg, vec, l);
                                end
                            if ($signed(out_raw_vec[l*32 +: 32]) !== expected) begin
                                if (errors < 12)
                                    $display("MISMATCH s=%0d tile=%0d p=%0d lane=%0d got=%0d exp=%0d addr=%0d",TB_STRIDE,tile_arg,out_seen,l,$signed(out_raw_vec[l*32 +: 32]),expected,vec);
                                errors = errors + 1;
                            end
                        end
                        out_seen = out_seen + 1;
                    end
                end
            end
            ready_out = 1;
            if (out_seen !== 64 || token_count !== 576) errors = errors + 1;
            while (compute_busy) @(negedge clk);
        end
    endtask

    integer ti, b, ep;
    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        configure();
        /* Prime bank zero.  Each accepted compute command launches the next
         * inactive-bank fill before consuming its first output. */
        start_fill(0, 1, 0); wait_fill(0, 1);
        for (ti = 0; ti < TILES; ti = ti + 1) begin
            b = ti & 1; ep = ti + 1;
            run_compute(b, ep, ti, ((TB_CIN - ti*16) >= 16) ? 16 : (TB_CIN-ti*16),
                        1, (ti+1)&1, ti+2, ti+1);
            wait_fill((ti+1)&1, ti+2);
        end
        if (fill_word_count_seen !== ((TILES+1)*WORDS)) errors = errors + 1;
        if (read_vector_count !== (TILES*FW*FH)) errors = errors + 1;
        if (overlap_cycles == 0) errors = errors + 1;
        if (errors == 0)
            $display("PASS ds_word_window_dw_producer_island CIN=%0d stride=%0d tiles=%0d words=%0d reads=%0d overlap=%0d cycles=%0d",TB_CIN,TB_STRIDE,TILES,fill_word_count_seen,read_vector_count,overlap_cycles,cycle_count);
        else begin
            $display("FAIL ds_word_window_dw_producer_island CIN=%0d stride=%0d errors=%0d words=%0d/%0d reads=%0d/%0d overlap=%0d",TB_CIN,TB_STRIDE,errors,fill_word_count_seen,TILES*WORDS,read_vector_count,TILES*FW*FH,overlap_cycles);
            $fatal(1);
        end
        $finish;
    end
    initial begin repeat (250000) @(posedge clk); $fatal(1,"WATCHDOG"); end
endmodule
`default_nettype wire
