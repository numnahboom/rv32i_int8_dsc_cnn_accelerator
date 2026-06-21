`timescale 1ns/1ps
`default_nettype none

module tb_dw_mac_lanes;
    localparam LANES = 16;
    localparam DATA_BITS = LANES * 9 * 8;
    localparam ACC_BITS = LANES * 32;

    reg clk;
    reg rst_n;
    reg valid_in;
    wire ready_in;
    reg [LANES-1:0] lane_active;
    reg signed [DATA_BITS-1:0] window_vec;
    reg signed [DATA_BITS-1:0] weight_vec;
    reg ready_out;
    wire busy;
    wire valid_out;
    wire signed [ACC_BITS-1:0] acc_vec;

    integer fd;
    integer scan_count;
    integer num_cases;
    integer case_idx;
    integer stall_cycles;
    integer stall_idx;
    integer error_count;
    integer total_checks;
    reg [ACC_BITS-1:0] expected_acc_vec;
    reg [ACC_BITS-1:0] held_acc_vec;

    dw_mac_lanes #(
        .LANES(LANES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .ready_in(ready_in),
        .lane_active(lane_active),
        .window_vec(window_vec),
        .weight_vec(weight_vec),
        .ready_out(ready_out),
        .busy(busy),
        .valid_out(valid_out),
        .acc_vec(acc_vec)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task check_result;
        begin
            if (acc_vec !== expected_acc_vec) begin
                $display(
                    "MISMATCH case=%0d expected=%h actual=%h",
                    case_idx,
                    expected_acc_vec,
                    acc_vec
                );
                error_count = error_count + 1;
            end
            total_checks = total_checks + 1;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        valid_in = 1'b0;
        lane_active = {LANES{1'b0}};
        window_vec = {DATA_BITS{1'b0}};
        weight_vec = {DATA_BITS{1'b0}};
        ready_out = 1'b1;
        error_count = 0;
        total_checks = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tests/vectors/dw_mac_lanes_cases.hex", "r");
        if (fd == 0) begin
            $display("ERROR: cannot open tests/vectors/dw_mac_lanes_cases.hex");
            $fatal;
        end

        scan_count = $fscanf(fd, "%d\n", num_cases);
        if (scan_count != 1) begin
            $display("ERROR: missing DW MAC case count");
            $fatal;
        end

        for (case_idx = 0; case_idx < num_cases; case_idx = case_idx + 1) begin
            scan_count = $fscanf(
                fd,
                "%h %h %h %d\n",
                lane_active,
                window_vec,
                weight_vec,
                stall_cycles
            );
            if (scan_count != 4) begin
                $display(
                    "ERROR: bad DW MAC header case=%0d fields=%0d",
                    case_idx,
                    scan_count
                );
                $fatal;
            end

            scan_count = $fscanf(fd, "%h\n", expected_acc_vec);
            if (scan_count != 1) begin
                $display("ERROR: missing DW MAC expected case=%0d", case_idx);
                $fatal;
            end

            @(negedge clk);
            ready_out = (stall_cycles == 0);
            valid_in = 1'b1;
            if (!ready_in) begin
                $display("MISMATCH case=%0d input should be ready", case_idx);
                error_count = error_count + 1;
            end

            @(posedge clk);
            #1;
            valid_in = 1'b0;

            if (!busy || ready_in) begin
                $display(
                    "MISMATCH case=%0d expected busy=1 ready_in=0 after accept",
                    case_idx
                );
                error_count = error_count + 1;
            end

            while (!valid_out) begin
                @(posedge clk);
                #1;
            end

            check_result();
            held_acc_vec = acc_vec;

            for (stall_idx = 0; stall_idx < stall_cycles; stall_idx = stall_idx + 1) begin
                if (ready_in) begin
                    $display(
                        "MISMATCH case=%0d stall=%0d ready_in should be 0",
                        case_idx,
                        stall_idx
                    );
                    error_count = error_count + 1;
                end
                @(posedge clk);
                #1;
                if (!valid_out || acc_vec !== held_acc_vec) begin
                    $display(
                        "MISMATCH case=%0d stall=%0d output did not hold",
                        case_idx,
                        stall_idx
                    );
                    error_count = error_count + 1;
                end
                total_checks = total_checks + 1;
            end

            if (stall_cycles != 0) begin
                @(negedge clk);
                ready_out = 1'b1;
            end
            @(posedge clk);
            #1;
            if (valid_out) begin
                $display("MISMATCH case=%0d valid_out did not clear", case_idx);
                error_count = error_count + 1;
            end
        end

        $fclose(fd);
        if (error_count == 0 && total_checks > 0) begin
            $display(
                "PASS tb_dw_mac_lanes cases=%0d checks=%0d",
                num_cases,
                total_checks
            );
            $finish;
        end else begin
            $display(
                "FAIL tb_dw_mac_lanes checks=%0d errors=%0d",
                total_checks,
                error_count
            );
            $fatal;
        end
    end
endmodule

`default_nettype wire
