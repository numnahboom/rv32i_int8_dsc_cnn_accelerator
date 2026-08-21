`timescale 1ns/1ps
`default_nettype none

module tb_cnn_top_ctrl_bounds;
    reg clk;
    reg rst_n;
    reg start;
    reg [31:0] layer_num;
    reg desc_valid;
    reg [31:0] desc_op_type;
    reg layer_done;
    reg layer_error;

    wire busy;
    wire done;
    wire error;
    wire [7:0] current_layer;
    wire fetch_start;
    wire [31:0] fetch_layer_index;
    wire layer_start;

    integer errors;
    integer fetch_count;
    integer layer_start_count;
    integer cycles;
    integer expected_fetch_index;

    cnn_top_ctrl dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .layer_num(layer_num),
        .desc_valid(desc_valid),
        .desc_op_type(desc_op_type),
        .layer_done(layer_done),
        .layer_error(layer_error),
        .busy(busy),
        .done(done),
        .error(error),
        .current_layer(current_layer),
        .fetch_start(fetch_start),
        .fetch_layer_index(fetch_layer_index),
        .layer_start(layer_start)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        desc_valid <= 1'b0;
        layer_done <= 1'b0;

        if (fetch_start) begin
            if (fetch_layer_index !== expected_fetch_index[31:0]) begin
                $display("MISMATCH fetch_index got=%0d expected=%0d",
                         fetch_layer_index, expected_fetch_index);
                errors = errors + 1;
            end
            fetch_count = fetch_count + 1;
            expected_fetch_index = expected_fetch_index + 1;
            desc_valid <= 1'b1;
        end

        if (layer_start) begin
            layer_start_count = layer_start_count + 1;
            layer_done <= 1'b1;
        end
    end

    task apply_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            start = 1'b0;
            layer_num = 32'd0;
            desc_valid = 1'b0;
            desc_op_type = 32'd0;
            layer_done = 1'b0;
            layer_error = 1'b0;
            fetch_count = 0;
            layer_start_count = 0;
            expected_fetch_index = 0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task run_case;
        input [31:0] requested_layers;
        input integer expected_fetches;
        input integer expected_starts;
        input expected_error;
        begin
            apply_reset();
            @(negedge clk);
            layer_num = requested_layers;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            cycles = 0;
            while (!done && (cycles < 5000)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end

            if (!done) begin
                $display("TIMEOUT layer_num=%0d", requested_layers);
                errors = errors + 1;
            end
            if (error !== expected_error) begin
                $display("MISMATCH error layer_num=%0d got=%0b expected=%0b",
                         requested_layers, error, expected_error);
                errors = errors + 1;
            end
            if (fetch_count != expected_fetches) begin
                $display("MISMATCH fetch_count layer_num=%0d got=%0d expected=%0d",
                         requested_layers, fetch_count, expected_fetches);
                errors = errors + 1;
            end
            if (layer_start_count != expected_starts) begin
                $display("MISMATCH layer_start_count layer_num=%0d got=%0d expected=%0d",
                         requested_layers, layer_start_count, expected_starts);
                errors = errors + 1;
            end
            @(posedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        layer_num = 32'd0;
        desc_valid = 1'b0;
        desc_op_type = 32'd0;
        layer_done = 1'b0;
        layer_error = 1'b0;
        errors = 0;
        fetch_count = 0;
        layer_start_count = 0;
        expected_fetch_index = 0;

        run_case(32'd0,   0,   0, 1'b0);
        run_case(32'd1,   1,   1, 1'b0);
        run_case(32'd255, 255, 255, 1'b0);
        run_case(32'd256, 256, 256, 1'b0);
        run_case(32'd257, 0,   0, 1'b1);

        if (errors == 0) begin
            $display("PASS tb_cnn_top_ctrl_bounds cases=5");
        end else begin
            $display("FAIL tb_cnn_top_ctrl_bounds errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end
endmodule

`default_nettype wire
