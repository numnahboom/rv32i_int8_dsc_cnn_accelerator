`timescale 1ns/1ps
`default_nettype none

module tb_npc_cnn_custom_bridge;
    reg clk;
    reg rst_n;
    reg cpu_cmd_valid;
    reg [2:0] cpu_cmd_funct3;
    reg [31:0] cpu_cmd_rs1;
    reg [31:0] cpu_cmd_rs2;
    wire [31:0] cpu_cmd_rdata;
    wire acc_cmd_valid;
    wire [1:0] acc_cmd;
    wire [31:0] acc_desc_base;
    wire [31:0] acc_layer_num;
    reg acc_cmd_ready;
    reg [31:0] acc_status;
    integer error_count;

    npc_cnn_custom_bridge dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_cmd_valid(cpu_cmd_valid),
        .cpu_cmd_funct3(cpu_cmd_funct3),
        .cpu_cmd_rs1(cpu_cmd_rs1),
        .cpu_cmd_rs2(cpu_cmd_rs2),
        .cpu_cmd_rdata(cpu_cmd_rdata),
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

    initial begin
        rst_n = 1'b0;
        cpu_cmd_valid = 1'b0;
        cpu_cmd_funct3 = 3'd0;
        cpu_cmd_rs1 = 32'd0;
        cpu_cmd_rs2 = 32'd0;
        acc_cmd_ready = 1'b0;
        acc_status = 32'h0000_0055;
        error_count = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        cpu_cmd_funct3 = 3'd0;
        cpu_cmd_valid = 1'b1;
        cpu_cmd_rs1 = 32'h1000_0000;
        cpu_cmd_rs2 = 32'd16;
        acc_cmd_ready = 1'b0;
        @(posedge clk);
        #1;
        check_cond(acc_cmd_valid == 1'b0, "start must not fire when cnn_top is not ready");
        check_cond(cpu_cmd_rdata == 32'd0, "start rdata bit0 should mirror not-ready");

        acc_cmd_ready = 1'b1;
        @(posedge clk);
        #1;
        check_cond(acc_cmd_valid == 1'b1, "start should fire when ready");
        check_cond(acc_cmd == 2'd0, "start cmd type mismatch");
        check_cond(acc_desc_base == 32'h1000_0000, "desc base mismatch");
        check_cond(acc_layer_num == 32'd16, "layer count mismatch");
        check_cond(cpu_cmd_rdata == 32'd1, "start rdata bit0 should mirror ready");

        cpu_cmd_valid = 1'b0;
        @(posedge clk);

        cpu_cmd_funct3 = 3'd1;
        acc_status = 32'h1234_00a3;
        #1;
        check_cond(cpu_cmd_rdata == 32'h1234_00a3, "poll should return accelerator status");

        cpu_cmd_funct3 = 3'd2;
        acc_status = 32'h8765_4321;
        #1;
        check_cond(cpu_cmd_rdata == 32'h0087_6543, "stat should return accelerator cycle count");

        if (error_count == 0) begin
            $display("PASS tb_npc_cnn_custom_bridge");
            $finish;
        end else begin
            $display("FAIL tb_npc_cnn_custom_bridge errors=%0d", error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
