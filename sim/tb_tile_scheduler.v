`timescale 1ns/1ps
`default_nettype none

module tb_tile_scheduler;
    reg clk;
    reg rst_n;
    reg start;
    reg next;
    reg [7:0] out_h;
    reg [7:0] out_w;
    reg [1:0] stride;
    wire valid;
    wire [7:0] tile_h_start;
    wire [7:0] tile_w_start;
    wire [7:0] tile_h_size;
    wire [7:0] tile_w_size;
    wire [7:0] input_tile_h;
    wire [7:0] input_tile_w;
    wire is_last_tile;

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer num_tiles;
    integer t;
    integer error_count;
    integer total_checks;
    integer exp_h_start;
    integer exp_w_start;
    integer exp_h_size;
    integer exp_w_size;
    integer exp_input_h;
    integer exp_input_w;
    integer exp_last;

    tile_scheduler dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .next(next),
        .out_h(out_h),
        .out_w(out_w),
        .stride(stride),
        .valid(valid),
        .tile_h_start(tile_h_start),
        .tile_w_start(tile_w_start),
        .tile_h_size(tile_h_size),
        .tile_w_size(tile_w_size),
        .input_tile_h(input_tile_h),
        .input_tile_w(input_tile_w),
        .is_last_tile(is_last_tile)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task pulse_next;
        begin
            @(posedge clk);
            next = 1'b1;
            @(posedge clk);
            next = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        start = 1'b0;
        next = 1'b0;
        out_h = 8'd0;
        out_w = 8'd0;
        stride = 2'd1;
        error_count = 0;
        total_checks = 0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/tile_scheduler_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/tile_scheduler_cases.hex");
            $finish;
        end
        scan_count = $fscanf(fd, "%d\n", num_cases);

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            scan_count = $fscanf(fd, "%d %d %d %d\n", out_h, out_w, stride, num_tiles);
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            for (t = 0; t < num_tiles; t = t + 1) begin
                while (!valid) begin
                    @(posedge clk);
                end
                scan_count = $fscanf(
                    fd,
                    "%d %d %d %d %d %d %d\n",
                    exp_h_start,
                    exp_w_start,
                    exp_h_size,
                    exp_w_size,
                    exp_input_h,
                    exp_input_w,
                    exp_last
                );
                if (tile_h_start !== exp_h_start[7:0] ||
                    tile_w_start !== exp_w_start[7:0] ||
                    tile_h_size !== exp_h_size[7:0] ||
                    tile_w_size !== exp_w_size[7:0] ||
                    input_tile_h !== exp_input_h[7:0] ||
                    input_tile_w !== exp_input_w[7:0] ||
                    is_last_tile !== exp_last[0]) begin
                    $display(
                        "MISMATCH case=%0d tile=%0d expected=(%0d,%0d,%0d,%0d,%0d,%0d,%0d) actual=(%0d,%0d,%0d,%0d,%0d,%0d,%0d)",
                        case_idx,
                        t,
                        exp_h_start,
                        exp_w_start,
                        exp_h_size,
                        exp_w_size,
                        exp_input_h,
                        exp_input_w,
                        exp_last,
                        tile_h_start,
                        tile_w_start,
                        tile_h_size,
                        tile_w_size,
                        input_tile_h,
                        input_tile_w,
                        is_last_tile
                    );
                    error_count = error_count + 1;
                end
                total_checks = total_checks + 1;
                pulse_next();
            end
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display("PASS tb_tile_scheduler cases=%0d checks=%0d", num_cases, total_checks);
            $finish;
        end else begin
            $display("FAIL tb_tile_scheduler checks=%0d errors=%0d", total_checks, error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
