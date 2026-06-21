`timescale 1ns/1ps
`default_nettype none

module tb_dw_tile_buffer_bram;
    reg clk;
    reg rst_n;
    reg wr_en;
    reg [5:0] wr_pixel_idx;
    reg [6:0] wr_channel_idx;
    reg signed [7:0] wr_data_int8;
    reg rd_en;
    reg [5:0] rd_pixel_base;
    reg [6:0] rd_channel_idx;
    wire rd_valid;
    wire signed [63:0] rd_data_vector;

    integer fd;
    integer scan_count;
    integer cycle_count;
    integer cycle_idx;
    integer error_count;
    reg expected_rd_valid;
    reg signed [63:0] expected_rd_data;

    dw_tile_buffer_bram dut (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_pixel_idx(wr_pixel_idx),
        .wr_channel_idx(wr_channel_idx),
        .wr_data_int8(wr_data_int8),
        .rd_en(rd_en),
        .rd_pixel_base(rd_pixel_base),
        .rd_channel_idx(rd_channel_idx),
        .rd_valid(rd_valid),
        .rd_data_vector(rd_data_vector)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        wr_en = 1'b0;
        wr_pixel_idx = 6'd0;
        wr_channel_idx = 7'd0;
        wr_data_int8 = 8'sd0;
        rd_en = 1'b0;
        rd_pixel_base = 6'd0;
        rd_channel_idx = 7'd0;
        error_count = 0;

        fd = $fopen(
            "tests/vectors/dw_tile_buffer_bram_cases.hex",
            "r"
        );
        if (fd == 0) begin
            $display(
                "ERROR: cannot open tests/vectors/dw_tile_buffer_bram_cases.hex"
            );
            $fatal;
        end

        scan_count = $fscanf(fd, "%d\n", cycle_count);
        if (scan_count != 1) begin
            $display("ERROR: missing BRAM tile-buffer cycle count");
            $fatal;
        end

        for (cycle_idx = 0;
             cycle_idx < cycle_count;
             cycle_idx = cycle_idx + 1) begin
            @(negedge clk);
            scan_count = $fscanf(
                fd,
                "%d %d %d %d %h %d %d %d %d %h\n",
                rst_n,
                wr_en,
                wr_pixel_idx,
                wr_channel_idx,
                wr_data_int8,
                rd_en,
                rd_pixel_base,
                rd_channel_idx,
                expected_rd_valid,
                expected_rd_data
            );
            if (scan_count != 10) begin
                $display(
                    "ERROR: bad BRAM tile-buffer vector cycle=%0d fields=%0d",
                    cycle_idx,
                    scan_count
                );
                $fatal;
            end

            @(posedge clk);
            #1;
            if (rd_valid !== expected_rd_valid) begin
                $display(
                    "MISMATCH cycle=%0d rd_valid expected=%0b actual=%0b",
                    cycle_idx,
                    expected_rd_valid,
                    rd_valid
                );
                error_count = error_count + 1;
            end
            if (rd_data_vector !== expected_rd_data) begin
                $display(
                    "MISMATCH cycle=%0d rd_data expected=%h actual=%h",
                    cycle_idx,
                    expected_rd_data,
                    rd_data_vector
                );
                error_count = error_count + 1;
            end
        end
        $fclose(fd);

        if (error_count == 0 && cycle_count > 0) begin
            $display(
                "PASS tb_dw_tile_buffer_bram cycles=%0d",
                cycle_count
            );
            $finish;
        end else begin
            $display(
                "FAIL tb_dw_tile_buffer_bram cycles=%0d errors=%0d",
                cycle_count,
                error_count
            );
            $fatal;
        end
    end
endmodule

`default_nettype wire
