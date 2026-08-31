`timescale 1ns/1ps
`default_nettype none

// Directed non-zero MAC check for the cursor/operand stage split.
module tb_conv3x3_stem_engine_new_addr_split;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg cfg_wr_en = 1'b0;
    wire cfg_ready;
    reg [3:0] cfg_target;
    reg [15:0] cfg_index;
    reg [31:0] cfg_data;
    reg start = 1'b0;
    wire busy, done, error;
    wire out_wr_en;
    wire [5:0] out_wr_pixel_idx;
    wire [3:0] out_wr_channel_idx;
    wire signed [7:0] out_wr_data_int8;
    integer writes = 0;
    integer errors = 0;
    integer cycles = 0;
    integer mac_cycles = 0;
    integer mac_runs = 0;
    integer mac_run_len = 0;
    integer ii_errors = 0;
    reg last_mac = 1'b0;
    integer i;

    always #5 clk = ~clk;

    conv3x3_stem_engine_new dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_wr_en(cfg_wr_en), .cfg_ready(cfg_ready),
        .cfg_target(cfg_target), .cfg_index(cfg_index), .cfg_data(cfg_data),
        .start(start), .busy(busy), .done(done), .error(error),
        .out_h(4'd1), .out_w(4'd1),
        .output_zero_point(32'sd0),
        .activation_min(-32'sd128), .activation_max(32'sd127),
        .out_wr_en(out_wr_en), .out_wr_pixel_idx(out_wr_pixel_idx),
        .out_wr_channel_idx(out_wr_channel_idx),
        .out_wr_data_int8(out_wr_data_int8)
    );

    task automatic cfg_write(input [3:0] target, input integer index,
                             input [31:0] data);
        begin
            while (!cfg_ready) @(posedge clk);
            @(negedge clk);
            cfg_target = target;
            cfg_index = index;
            cfg_data = data;
            cfg_wr_en = 1'b1;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        // A registered-read fill is allowed at the start of each output
        // channel, but every tap after that must consume one MAC per clock.
        if (dut.state == 4'd1) begin
            mac_cycles = mac_cycles + 1;
            if (!last_mac) begin
                mac_runs = mac_runs + 1;
                mac_run_len = 1;
            end else begin
                mac_run_len = mac_run_len + 1;
            end
            last_mac = 1'b1;
        end else begin
            if (last_mac && mac_run_len != 9) begin
                $display("FAIL sync-read II run=%0d taps=%0d", mac_runs, mac_run_len);
                ii_errors = ii_errors + 1;
            end
            last_mac = 1'b0;
        end
        if (out_wr_en) begin
            if (out_wr_pixel_idx !== 0 || out_wr_channel_idx !== writes[3:0] ||
                out_wr_data_int8 !== 8'sd9) begin
                $display("FAIL addr_split write=%0d pixel=%0d channel=%0d data=%0d",
                         writes, out_wr_pixel_idx, out_wr_channel_idx,
                         out_wr_data_int8);
                errors = errors + 1;
            end
            writes = writes + 1;
        end
    end

    initial begin
        cfg_target = 0;
        cfg_index = 0;
        cfg_data = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        for (i = 0; i < 300; i = i + 1) cfg_write(4'd0, i, 32'd0);
        for (i = 0; i < 432; i = i + 1) cfg_write(4'd1, i, 32'd0);
        // The 1x1 output walks input addresses 0,3,6 then 30,33,36,
        // then 60,63,66.  Use one for every operand in those tap positions.
        cfg_write(4'd0, 0, 32'd1);
        cfg_write(4'd0, 3, 32'd1);
        cfg_write(4'd0, 6, 32'd1);
        cfg_write(4'd0, 30, 32'd1);
        cfg_write(4'd0, 33, 32'd1);
        cfg_write(4'd0, 36, 32'd1);
        cfg_write(4'd0, 60, 32'd1);
        cfg_write(4'd0, 63, 32'd1);
        cfg_write(4'd0, 66, 32'd1);
        for (i = 0; i < 432; i = i + 1) cfg_write(4'd1, i, 32'd1);
        for (i = 0; i < 16; i = i + 1) begin
            cfg_write(4'd2, i, 32'd0);
            cfg_write(4'd3, i, 32'h7fffffff);
            cfg_write(4'd4, i, 32'd0);
        end
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        while (!done && cycles < 20000) begin @(posedge clk); cycles = cycles + 1; end
        if (last_mac && mac_run_len != 9) begin
            ii_errors = ii_errors + 1;
        end
        if (!done || error || writes != 16 || errors != 0 || ii_errors != 0 ||
            mac_runs != 16 || mac_cycles != 144) begin
            $display("FAIL addr_split done=%b error=%b writes=%0d errors=%0d cycles=%0d mac_runs=%0d mac_cycles=%0d ii_errors=%0d",
                     done, error, writes, errors, cycles, mac_runs, mac_cycles,
                     ii_errors);
            $fatal;
        end
        $display("PASS tb_conv3x3_stem_engine_new_addr_split writes=%0d cycles=%0d mac_runs=%0d mac_cycles=%0d II=1",
                 writes, cycles, mac_runs, mac_cycles);
        $finish;
    end
endmodule

`default_nettype wire
