`timescale 1ns/1ps
`default_nettype none

module tb_ds1_tiled_group_bridge;
    reg clk = 1'b0;
    always #1 clk = ~clk;
    reg rst_n = 1'b0;
    reg start_valid = 1'b0;
    wire start_ready;
    reg [31:0] input_base_addr = 32'h0010_0000;
    reg [7:0] input_zero_point = 8'h81;
    reg [3:0] start_epoch = 4'h5;
    wire job_valid;
    reg job_ready = 1'b0;
    wire [3:0] job_tile_index;
    wire [1:0] job_micro_row, job_cout_group;
    wire [7:0] job_sequence;
    wire job_bank;
    wire [3:0] job_epoch;
    wire [5:0] job_global_y, job_global_x;
    wire [9:0] job_global_pixel_base;
    wire [5:0] job_cout_base;
    wire [7:0] job_pixel_count, job_cout_count;
    reg [7:0] fill_word_index = 8'd0;
    wire map_is_padding;
    wire [31:0] map_addr;
    wire [7:0] map_padding_word;
    wire done;

    ds1_tiled_group_bridge dut (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid),
        .start_ready(start_ready), .input_base_addr(input_base_addr),
        .input_zero_point(input_zero_point), .start_epoch(start_epoch),
        .job_valid(job_valid), .job_ready(job_ready),
        .job_tile_index(job_tile_index), .job_micro_row(job_micro_row),
        .job_cout_group(job_cout_group), .job_sequence(job_sequence),
        .job_bank(job_bank), .job_epoch(job_epoch),
        .job_global_y(job_global_y), .job_global_x(job_global_x),
        .job_global_pixel_base(job_global_pixel_base),
        .job_cout_base(job_cout_base), .job_pixel_count(job_pixel_count),
        .job_cout_count(job_cout_count), .fill_word_index(fill_word_index),
        .map_is_padding(map_is_padding), .map_addr(map_addr),
        .map_padding_word(map_padding_word), .done(done)
    );

    integer errors = 0;
    integer seen = 0;
    integer expected;
    reg [3:0] held_tile;
    reg [1:0] held_micro, held_cout;
    reg [9:0] held_base;

    task expect_map;
        input [7:0] word_idx;
        input expected_padding;
        input [31:0] expected_addr;
        begin
            fill_word_index = word_idx;
            #0;
            if (map_is_padding !== expected_padding ||
                (!expected_padding && map_addr !== expected_addr)) begin
                $display("MAP_MISMATCH job=%0d word=%0d pad=%b addr=%h expected_pad=%b expected_addr=%h",
                    job_sequence, word_idx, map_is_padding, map_addr,
                    expected_padding, expected_addr);
                errors = errors + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && job_valid && !job_ready) begin
            if (job_tile_index !== held_tile || job_micro_row !== held_micro ||
                job_cout_group !== held_cout || job_global_pixel_base !== held_base)
                errors = errors + 1;
        end
        if (rst_n && job_valid && job_ready) begin
            expected = seen;
            if (job_sequence !== expected[7:0] ||
                job_tile_index !== expected[7:4] ||
                job_micro_row !== expected[3:2] ||
                job_cout_group !== expected[1:0] ||
                job_global_y !== ((expected[7:6] * 8) + (expected[3:2] * 2)) ||
                job_global_x !== ((expected[5:4]) * 8) ||
                job_global_pixel_base !== (((expected[7:6] * 8) +
                                            (expected[3:2] * 2)) * 32 +
                                           ((expected[5:4]) * 8)) ||
                job_cout_base !== (expected[1:0] * 8) ||
                job_pixel_count !== 16 || job_cout_count !== 8 ||
                job_epoch !== 4'h5) begin
                $display("JOB_MISMATCH seen=%0d tile=%0d micro=%0d cout=%0d y=%0d x=%0d base=%0d",
                    seen, job_tile_index, job_micro_row, job_cout_group,
                    job_global_y, job_global_x, job_global_pixel_base);
                errors = errors + 1;
            end
            seen = seen + 1;
        end
        held_tile <= job_tile_index;
        held_micro <= job_micro_row;
        held_cout <= job_cout_group;
        held_base <= job_global_pixel_base;
    end

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        start_valid = 1'b1;
        while (!start_ready) @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        start_valid = 1'b0;

        /* Hold the first job to prove ready/valid metadata stability and
         * inspect its top-left SAME padding / in-bounds word mapping. */
        held_tile = job_tile_index;
        held_micro = job_micro_row;
        held_cout = job_cout_group;
        held_base = job_global_pixel_base;
        expect_map(8'd0, 1'b1, 32'd0);
        /* The first ten source pixels are the top halo row.  The second
         * footprint row begins at word 40; its x=0 halo is padded and x=1
         * is the global (0,0) source pixel. */
        expect_map(8'd4, 1'b1, 32'd0);
        expect_map(8'd39, 1'b1, 32'd0);
        expect_map(8'd40, 1'b1, 32'd0);
        expect_map(8'd44, 1'b0, 32'h0010_0000);
        expect_map(8'd79, 1'b0, 32'h0010_008c);
        expect_map(8'd160, 1'b1, 32'd0);

        job_ready = 1'b1;
        while (!done) @(posedge clk);
        if (seen != 256) begin
            $display("COVERAGE_MISMATCH seen=%0d", seen);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS ds1_tiled_group_bridge jobs=%0d epoch=%0d", seen, start_epoch);
        else begin
            $display("FAIL ds1_tiled_group_bridge errors=%0d seen=%0d", errors, seen);
            $fatal(1);
        end
        $finish;
    end
    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "WATCHDOG");
    end
endmodule

`default_nettype wire
