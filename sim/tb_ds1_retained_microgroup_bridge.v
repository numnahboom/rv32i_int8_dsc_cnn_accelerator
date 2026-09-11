`timescale 1ns/1ps
`default_nettype none

module tb_ds1_retained_microgroup_bridge;
    reg clk = 1'b0;
    always #1 clk = ~clk;

    reg rst_n = 1'b0;
    reg start_valid = 1'b0;
    wire start_ready;
    reg [31:0] input_base_addr = 32'h0010_0000;
    reg [7:0] input_zero_point = 8'h81;
    reg [3:0] start_epoch = 4'hb;

    wire job_valid;
    reg job_ready = 1'b0;
    wire [3:0] job_tile_index;
    wire [1:0] job_micro_row;
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

    ds1_retained_microgroup_bridge dut (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .input_base_addr(input_base_addr),
        .input_zero_point(input_zero_point), .start_epoch(start_epoch),
        .job_valid(job_valid), .job_ready(job_ready),
        .job_tile_index(job_tile_index), .job_micro_row(job_micro_row),
        .job_sequence(job_sequence), .job_bank(job_bank),
        .job_epoch(job_epoch), .job_global_y(job_global_y),
        .job_global_x(job_global_x),
        .job_global_pixel_base(job_global_pixel_base),
        .job_cout_base(job_cout_base), .job_pixel_count(job_pixel_count),
        .job_cout_count(job_cout_count), .fill_word_index(fill_word_index),
        .map_is_padding(map_is_padding), .map_addr(map_addr),
        .map_padding_word(map_padding_word), .done(done)
    );

    integer errors = 0;
    integer seen = 0;
    integer expected_y, expected_x, expected_base;
    integer py, px, pixel_idx, coverage_count = 0;
    reg [1023:0] pixel_seen = {1024{1'b0}};
    reg held_valid = 1'b0;
    reg [3:0] held_tile;
    reg [1:0] held_micro;
    reg [7:0] held_sequence;
    reg held_bank;
    reg [5:0] held_y, held_x;
    reg [9:0] held_base;

    /* The first and last jobs are deliberately held to exercise payload
     * stability and to inspect opposite SAME-padding corners. */
    always @(posedge clk) begin
        if (!rst_n) begin
            held_valid <= 1'b0;
        end else begin
            if (held_valid && job_valid && !job_ready) begin
                if (job_tile_index !== held_tile ||
                    job_micro_row !== held_micro ||
                    job_sequence !== held_sequence ||
                    job_bank !== held_bank || job_global_y !== held_y ||
                    job_global_x !== held_x ||
                    job_global_pixel_base !== held_base)
                    errors = errors + 1;
            end
            if (job_valid && !job_ready) begin
                held_valid <= 1'b1;
                held_tile <= job_tile_index;
                held_micro <= job_micro_row;
                held_sequence <= job_sequence;
                held_bank <= job_bank;
                held_y <= job_global_y;
                held_x <= job_global_x;
                held_base <= job_global_pixel_base;
            end else begin
                held_valid <= 1'b0;
            end
        end
    end

    task check_map;
        input [7:0] word_idx;
        input expected_padding;
        input [31:0] expected_addr;
        begin
            fill_word_index = word_idx;
            #0;
            if (map_is_padding !== expected_padding ||
                map_padding_word !== input_zero_point ||
                (!expected_padding && map_addr !== expected_addr)) begin
                $display("MAP_MISMATCH seq=%0d word=%0d pad=%b addr=%h expected_pad=%b expected_addr=%h zp=%h",
                    job_sequence, word_idx, map_is_padding, map_addr,
                    expected_padding, expected_addr, map_padding_word);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        start_valid = 1'b1;
        while (!start_ready) @(posedge clk);
        @(posedge clk);
        @(negedge clk);
        start_valid = 1'b0;

        /* Job 0 is tile (0,0), micro-row 0: top and left halo.  The source
         * word at footprint pixel (1,1) is global (0,0). */
        held_tile = job_tile_index;
        held_micro = job_micro_row;
        held_sequence = job_sequence;
        held_bank = job_bank;
        held_y = job_global_y;
        held_x = job_global_x;
        held_base = job_global_pixel_base;
        if (!job_valid || job_sequence !== 8'd0 || job_tile_index !== 4'd0 ||
            job_micro_row !== 2'd0 || job_bank !== 1'b0 ||
            job_epoch !== start_epoch || job_global_y !== 6'd0 ||
            job_global_x !== 6'd0 || job_global_pixel_base !== 10'd0 ||
            job_cout_base !== 6'd0 || job_pixel_count !== 8'd16 ||
            job_cout_count !== 8'd32)
            errors = errors + 1;
        check_map(8'd0, 1'b1, 32'd0);     // top halo, x=-1
        check_map(8'd4, 1'b1, 32'd0);     // top halo, x=3
        check_map(8'd40, 1'b1, 32'd0);    // left halo, y=0
        check_map(8'd44, 1'b0, input_base_addr); // global (0,0)

        /* Backpressure on the first job must not alter any metadata. */
        repeat (3) @(posedge clk);
        if (!job_valid) errors = errors + 1;
        job_ready = 1'b1;
        while (seen < 64) begin
            @(posedge clk);
            if (job_valid && job_ready) begin
                expected_y = ((seen / 16) * 8) + (((seen % 4)) * 2);
                /* Tile=(sequence/4), with four tile columns in row-major
                 * order. */
                expected_x = ((seen / 4) % 4) * 8;
                expected_base = expected_y * 32 + expected_x;
                if (job_sequence !== seen[7:0] ||
                    job_tile_index !== (seen / 4) ||
                    job_micro_row !== (seen % 4) ||
                    job_bank !== (seen % 2) || job_epoch !== start_epoch ||
                    job_global_y !== expected_y[5:0] ||
                    job_global_x !== expected_x[5:0] ||
                    job_global_pixel_base !== expected_base[9:0] ||
                    job_cout_base !== 6'd0 || job_pixel_count !== 8'd16 ||
                    job_cout_count !== 8'd32) begin
                    $display("JOB_MISMATCH seq=%0d seen=%0d tile=%0d micro=%0d bank=%b y=%0d x=%0d base=%0d",
                        job_sequence, seen, job_tile_index, job_micro_row,
                        job_bank, job_global_y, job_global_x,
                        job_global_pixel_base);
                    errors = errors + 1;
                end
                /* Every retained job owns a disjoint 2x8 output rectangle.
                 * Mark all sixteen pixels to prove exact-once 32x32 cover,
                 * rather than relying only on the descriptor coordinates. */
                for (py = 0; py < 2; py = py + 1) begin
                    for (px = 0; px < 8; px = px + 1) begin
                        pixel_idx = (expected_y + py) * 32 +
                                    expected_x + px;
                        if (pixel_seen[pixel_idx]) errors = errors + 1;
                        pixel_seen[pixel_idx] = 1'b1;
                        coverage_count = coverage_count + 1;
                    end
                end
                seen = seen + 1;

                /* Final job is tile (3,3), micro-row 3: bottom and right
                 * halo.  Footprint pixel (3,9) is (32,32), padding; pixel
                 * (2,8) is global (31,31), the final valid source word. */
                if (seen == 64) begin
                    check_map(8'd116, 1'b1, 32'd0); // right halo, y=31
                    check_map(8'd148, 1'b1, 32'd0); // bottom halo, x=31
                    check_map(8'd159, 1'b1, 32'd0);
                    check_map(8'd112, 1'b0,
                              input_base_addr + (31 * 32 + 31) * 16);
                end
            end
        end
        if (!done) begin
            @(posedge clk);
            if (!done) errors = errors + 1;
        end
        if (coverage_count !== 1024)
            errors = errors + 1;
        for (pixel_idx = 0; pixel_idx < 1024; pixel_idx = pixel_idx + 1)
            if (!pixel_seen[pixel_idx]) errors = errors + 1;
        if (seen !== 64 || errors != 0)
            $fatal(1, "FAIL tb_ds1_retained_microgroup_bridge errors=%0d seen=%0d done=%b",
                   errors, seen, done);
        $display("PASS tb_ds1_retained_microgroup_bridge jobs=%0d pixels=%0d epoch=%0d",
                 seen, 32*32, start_epoch);
        $finish;
    end

    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "WATCHDOG");
    end
endmodule

`default_nettype wire
