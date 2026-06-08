`timescale 1ns/1ps
`default_nettype none

module npc_cnn_custom_bridge (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        cpu_cmd_valid,
    input  wire [2:0]  cpu_cmd_funct3,
    input  wire [31:0] cpu_cmd_rs1,
    input  wire [31:0] cpu_cmd_rs2,
    output reg  [31:0] cpu_cmd_rdata,

    output reg         acc_cmd_valid,
    output reg  [1:0]  acc_cmd,
    output reg  [31:0] acc_desc_base,
    output reg  [31:0] acc_layer_num,
    input  wire        acc_cmd_ready,
    input  wire [31:0] acc_status
);
    localparam CNN_START = 3'd0;
    localparam CNN_POLL  = 3'd1;
    localparam CNN_STAT  = 3'd2;

    always @(*) begin
        case (cpu_cmd_funct3)
            CNN_POLL: cpu_cmd_rdata = acc_status;
            CNN_STAT: cpu_cmd_rdata = {8'd0, acc_status[31:8]};
            default:  cpu_cmd_rdata = {31'd0, acc_cmd_ready};
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            acc_cmd_valid <= 1'b0;
            acc_cmd <= 2'd0;
            acc_desc_base <= 32'd0;
            acc_layer_num <= 32'd0;
        end else begin
            acc_cmd_valid <= 1'b0;
            if (cpu_cmd_valid && (cpu_cmd_funct3 == CNN_START) && acc_cmd_ready) begin
                acc_cmd_valid <= 1'b1;
                acc_cmd <= 2'd0;
                acc_desc_base <= cpu_cmd_rs1;
                acc_layer_num <= cpu_cmd_rs2;
            end
        end
    end
endmodule

`default_nettype wire
