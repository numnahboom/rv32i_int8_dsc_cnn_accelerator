`timescale 1ns/1ps
`default_nettype none

module rv_cnn_custom_if (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        instr_valid,
    input  wire [31:0] instr_opcode,
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,

    input  wire        acc_cmd_ready,
    input  wire [31:0] acc_status,

    output wire        instr_ready,
    output reg         acc_cmd_valid,
    output reg  [1:0]  acc_cmd,
    output reg  [31:0] acc_desc_base,
    output reg  [31:0] acc_layer_num,
    output reg  [31:0] rd_data,
    output reg         rd_valid
);
    localparam CUSTOM0_OPCODE = 7'b0001011;
    localparam CNN_START = 3'd0;
    localparam CNN_POLL = 3'd1;
    localparam CNN_STAT = 3'd2;

    wire is_rv_custom0;
    wire [2:0] decoded_cmd;
    wire is_start;
    wire is_poll;
    wire is_stat;
    wire accepted;

    assign is_rv_custom0 = (instr_opcode[6:0] == CUSTOM0_OPCODE);
    assign decoded_cmd = is_rv_custom0 ? instr_opcode[14:12] : {1'b0, instr_opcode[1:0]};
    assign is_start = (decoded_cmd == CNN_START);
    assign is_poll = (decoded_cmd == CNN_POLL);
    assign is_stat = (decoded_cmd == CNN_STAT);
    assign instr_ready = is_start ? acc_cmd_ready : 1'b1;
    assign accepted = instr_valid && instr_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            acc_cmd_valid <= 1'b0;
            acc_cmd <= 2'd0;
            acc_desc_base <= 32'd0;
            acc_layer_num <= 32'd0;
            rd_data <= 32'd0;
            rd_valid <= 1'b0;
        end else begin
            acc_cmd_valid <= 1'b0;
            rd_valid <= 1'b0;

            if (accepted) begin
                if (is_start) begin
                    acc_cmd_valid <= 1'b1;
                    acc_cmd <= 2'd0;
                    acc_desc_base <= rs1_data;
                    acc_layer_num <= rs2_data;
                end else if (is_poll) begin
                    rd_data <= acc_status;
                    rd_valid <= 1'b1;
                end else if (is_stat) begin
                    rd_data <= {8'd0, acc_status[31:8]};
                    rd_valid <= 1'b1;
                end else begin
                    rd_data <= 32'hffff_ffff;
                    rd_valid <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
