`timescale 1ns/1ps
`default_nettype none

module tb_cnn_mmio_regs;
    localparam OFF_DESC_BASE = 32'h0000_0000;
    localparam OFF_LAYER_NUM = 32'h0000_0004;
    localparam OFF_CMD       = 32'h0000_0008;
    localparam OFF_STATUS    = 32'h0000_000c;
    localparam OFF_STAT      = 32'h0000_0010;

    reg clk;
    reg rst_n;
    reg bus_valid;
    reg bus_write;
    reg [31:0] bus_addr;
    reg [31:0] bus_wdata;
    wire bus_ready;
    wire bus_rvalid;
    wire [31:0] bus_rdata;
    wire acc_cmd_valid;
    wire [1:0] acc_cmd;
    wire [31:0] acc_desc_base;
    wire [31:0] acc_layer_num;
    reg acc_cmd_ready;
    reg [31:0] acc_status;

    integer error_count;
    reg [31:0] rd_value;

    cnn_mmio_regs dut (
        .clk(clk),
        .rst_n(rst_n),
        .bus_valid(bus_valid),
        .bus_write(bus_write),
        .bus_addr(bus_addr),
        .bus_wdata(bus_wdata),
        .bus_ready(bus_ready),
        .bus_rvalid(bus_rvalid),
        .bus_rdata(bus_rdata),
        .acc_cmd_valid(acc_cmd_valid),
        .acc_cmd(acc_cmd),
        .acc_desc_base(acc_desc_base),
        .acc_layer_num(acc_layer_num),
        .acc_cmd_ready(acc_cmd_ready),
        .acc_status(acc_status)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task check_cond;
        input condition;
        input [255:0] message;
        begin
            if (!condition) begin
                $display("MISMATCH %s", message);
                error_count = error_count + 1;
            end
        end
    endtask

    task mmio_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            bus_addr = addr;
            bus_wdata = data;
            bus_write = 1'b1;
            bus_valid = 1'b1;
            while (!bus_ready) begin
                @(posedge clk);
            end
            @(posedge clk);
            bus_valid = 1'b0;
            bus_write = 1'b0;
            @(posedge clk);
        end
    endtask

    task mmio_read;
        input [31:0] addr;
        output [31:0] data;
        begin
            bus_addr = addr;
            bus_wdata = 32'd0;
            bus_write = 1'b0;
            bus_valid = 1'b1;
            @(posedge clk);
            #1;
            check_cond(bus_rvalid == 1'b1, "mmio read should return rvalid");
            data = bus_rdata;
            bus_valid = 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        bus_valid = 1'b0;
        bus_write = 1'b0;
        bus_addr = 32'd0;
        bus_wdata = 32'd0;
        acc_cmd_ready = 1'b0;
        acc_status = 32'h1234_5678;
        error_count = 0;
        rd_value = 32'd0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        mmio_write(OFF_DESC_BASE, 32'h1000_2000);
        mmio_write(OFF_LAYER_NUM, 32'd9);
        mmio_read(OFF_DESC_BASE, rd_value);
        check_cond(rd_value == 32'h1000_2000, "desc base readback mismatch");
        mmio_read(OFF_LAYER_NUM, rd_value);
        check_cond(rd_value == 32'd9, "layer num readback mismatch");

        bus_addr = OFF_CMD;
        bus_wdata = 32'd0;
        bus_write = 1'b1;
        bus_valid = 1'b1;
        acc_cmd_ready = 1'b0;
        @(posedge clk);
        #1;
        check_cond(bus_ready == 1'b0, "cmd write should backpressure while accelerator not ready");
        check_cond(acc_cmd_valid == 1'b0, "cmd should not fire while not ready");

        acc_cmd_ready = 1'b1;
        @(posedge clk);
        #1;
        check_cond(bus_ready == 1'b1, "cmd write should accept when ready");
        check_cond(acc_cmd_valid == 1'b1, "cmd should fire when ready");
        check_cond(acc_cmd == 2'd0, "cmd type mismatch");
        check_cond(acc_desc_base == 32'h1000_2000, "cmd desc base mismatch");
        check_cond(acc_layer_num == 32'd9, "cmd layer num mismatch");
        bus_valid = 1'b0;
        bus_write = 1'b0;
        @(posedge clk);

        mmio_read(OFF_CMD, rd_value);
        check_cond(rd_value == 32'd0, "last command readback mismatch");
        mmio_read(OFF_STATUS, rd_value);
        check_cond(rd_value == 32'h1234_5678, "status read mismatch");
        acc_status = 32'h8765_4321;
        mmio_read(OFF_STAT, rd_value);
        check_cond(rd_value == 32'h0087_6543, "stat cycle count read mismatch");
        mmio_read(32'h0000_0014, rd_value);
        check_cond(rd_value == 32'hffff_ffff, "invalid offset read should return all ones");

        if (error_count == 0) begin
            $display("PASS tb_cnn_mmio_regs");
            $finish;
        end else begin
            $display("FAIL tb_cnn_mmio_regs errors=%0d", error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
