`timescale 1ns/1ps
`default_nettype none

module tb_rv_cnn_custom_if;
    localparam CUSTOM0_OPCODE = 7'b0001011;

    reg clk;
    reg rst_n;
    reg instr_valid;
    reg [31:0] instr_opcode;
    reg [31:0] rs1_data;
    reg [31:0] rs2_data;
    reg acc_cmd_ready;
    reg [31:0] acc_status;
    wire instr_ready;
    wire acc_cmd_valid;
    wire [1:0] acc_cmd;
    wire [31:0] acc_desc_base;
    wire [31:0] acc_layer_num;
    wire [31:0] rd_data;
    wire rd_valid;

    integer error_count;

    rv_cnn_custom_if dut (
        .clk(clk),
        .rst_n(rst_n),
        .instr_valid(instr_valid),
        .instr_opcode(instr_opcode),
        .rs1_data(rs1_data),
        .rs2_data(rs2_data),
        .acc_cmd_ready(acc_cmd_ready),
        .acc_status(acc_status),
        .instr_ready(instr_ready),
        .acc_cmd_valid(acc_cmd_valid),
        .acc_cmd(acc_cmd),
        .acc_desc_base(acc_desc_base),
        .acc_layer_num(acc_layer_num),
        .rd_data(rd_data),
        .rd_valid(rd_valid)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function [31:0] custom_instr;
        input [2:0] funct3;
        begin
            custom_instr = {17'd0, funct3, 5'd0, CUSTOM0_OPCODE};
        end
    endfunction

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
        instr_valid = 1'b0;
        instr_opcode = 32'd0;
        rs1_data = 32'd0;
        rs2_data = 32'd0;
        acc_cmd_ready = 1'b0;
        acc_status = 32'h0000_00a5;
        error_count = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        instr_opcode = custom_instr(3'd0);
        rs1_data = 32'h1000_2000;
        rs2_data = 32'd16;
        instr_valid = 1'b1;
        acc_cmd_ready = 1'b0;
        @(posedge clk);
        #1;
        check_cond(instr_ready == 1'b0, "start should wait for acc_cmd_ready");
        check_cond(acc_cmd_valid == 1'b0, "start should not fire while not ready");

        acc_cmd_ready = 1'b1;
        @(posedge clk);
        #1;
        check_cond(acc_cmd_valid == 1'b1, "start should emit one command");
        check_cond(acc_cmd == 2'd0, "start command type should be 0");
        check_cond(acc_desc_base == 32'h1000_2000, "start desc base mismatch");
        check_cond(acc_layer_num == 32'd16, "start layer num mismatch");
        check_cond(rd_valid == 1'b0, "start should not write rd");
        instr_valid = 1'b0;
        acc_cmd_ready = 1'b0;
        @(posedge clk);

        instr_opcode = custom_instr(3'd1);
        instr_valid = 1'b1;
        acc_status = 32'h0000_00b3;
        @(posedge clk);
        #1;
        check_cond(rd_valid == 1'b1, "poll should return rd_valid");
        check_cond(rd_data == 32'h0000_00b3, "poll status mismatch");
        instr_valid = 1'b0;
        @(posedge clk);

        instr_opcode = custom_instr(3'd2);
        instr_valid = 1'b1;
        acc_status = 32'h1234_5678;
        @(posedge clk);
        #1;
        check_cond(rd_valid == 1'b1, "stat should return rd_valid");
        check_cond(rd_data == 32'h0012_3456, "stat cycle count mismatch");
        instr_valid = 1'b0;
        @(posedge clk);

        instr_opcode = custom_instr(3'd7);
        instr_valid = 1'b1;
        @(posedge clk);
        #1;
        check_cond(rd_valid == 1'b1, "invalid command should return rd_valid");
        check_cond(rd_data == 32'hffff_ffff, "invalid command should return all ones");
        instr_valid = 1'b0;
        @(posedge clk);

        if (error_count == 0) begin
            $display("PASS tb_rv_cnn_custom_if");
            $finish;
        end else begin
            $display("FAIL tb_rv_cnn_custom_if errors=%0d", error_count);
            $fatal;
        end
    end
endmodule

`default_nettype wire
