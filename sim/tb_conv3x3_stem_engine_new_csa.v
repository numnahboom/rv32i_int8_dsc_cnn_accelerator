`timescale 1ns/1ps
`default_nettype none

// Directed signed-extrema regression for the Stem carry-save accumulator.
// Each run performs all 16 output channels and all 27 signed products per
// channel.  The first run exercises the most-negative product (-128*127),
// while the second exercises the largest positive product (127*127).  The
// requant multiplier is one and the activation range is int8, so saturation
// makes the expected result independent of any intermediate implementation.
module tb_conv3x3_stem_engine_new_csa;
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
    integer pass_no = 0;
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

    task automatic run_pass(input integer input_value,
                            input integer expected_value);
        integer start_cycles;
        begin
            for (i = 0; i < 300; i = i + 1)
                cfg_write(4'd0, i, input_value[7:0]);
            // Keep all three weight banks at +127.  The channel cursor is
            // intentionally shared by the production ABI; using one value
            // for every byte isolates the accumulator sign behavior.
            for (i = 0; i < 432; i = i + 1)
                cfg_write(4'd1, i, 32'h0000007f);
            for (i = 0; i < 16; i = i + 1) begin
                cfg_write(4'd2, i, 32'd0);
                // Q31 multiplier ~= 1.0, matching the production scale.
                cfg_write(4'd3, i, 32'h7fffffff);
                cfg_write(4'd4, i, 32'd0);
            end
            writes = 0;
            cycles = 0;
            pass_no = expected_value;
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            start_cycles = 0;
            while (!done && start_cycles < 20000) begin
                @(posedge clk);
                start_cycles = start_cycles + 1;
            end
            if (!done || error || writes != 16) begin
                $display("FAIL csa pass input=%0d expected=%0d done=%b error=%b writes=%0d cycles=%0d",
                         input_value, expected_value, done, error, writes,
                         start_cycles);
                errors = errors + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (out_wr_en) begin
            if (out_wr_pixel_idx !== 0 || out_wr_channel_idx !== writes[3:0] ||
                out_wr_data_int8 !== pass_no[7:0]) begin
                $display("FAIL csa write pass=%0d index=%0d pixel=%0d channel=%0d data=%0d",
                         pass_no, writes, out_wr_pixel_idx,
                         out_wr_channel_idx, out_wr_data_int8);
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
        // -128*127*27 = -438912, saturates to -128.
        run_pass(-128, -128);
        // 127*127*27 = 435483, saturates to +127.
        run_pass(127, 127);
        if (errors != 0) begin
            $display("FAIL tb_conv3x3_stem_engine_new_csa errors=%0d", errors);
            $fatal;
        end
        $display("PASS tb_conv3x3_stem_engine_new_csa runs=2 writes=32");
        $finish;
    end
endmodule

`default_nettype wire
