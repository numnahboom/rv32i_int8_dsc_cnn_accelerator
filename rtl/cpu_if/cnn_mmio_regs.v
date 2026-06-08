`timescale 1ns/1ps
`default_nettype none

module cnn_mmio_regs (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        bus_valid,
    input  wire        bus_write,
    input  wire [31:0] bus_addr,
    input  wire [31:0] bus_wdata,
    output wire        bus_ready,
    output reg         bus_rvalid,
    output reg  [31:0] bus_rdata,

    output reg         acc_cmd_valid,
    output reg  [1:0]  acc_cmd,
    output reg  [31:0] acc_desc_base,
    output reg  [31:0] acc_layer_num,
    input  wire        acc_cmd_ready,
    input  wire [31:0] acc_status
);
    localparam OFF_DESC_BASE = 5'h00;
    localparam OFF_LAYER_NUM = 5'h04;
    localparam OFF_CMD       = 5'h08;
    localparam OFF_STATUS    = 5'h0c;
    localparam OFF_STAT      = 5'h10;

    localparam CMD_START = 2'd0;

    reg [31:0] desc_base_reg;
    reg [31:0] layer_num_reg;
    reg [31:0] last_cmd_reg;

    wire [4:0] offset;
    wire access_cmd;
    wire accepted;

    assign offset = bus_addr[4:0];
    assign access_cmd = bus_valid && bus_write && (offset == OFF_CMD) && (bus_wdata[1:0] == CMD_START);
    assign bus_ready = access_cmd ? acc_cmd_ready : 1'b1;
    assign accepted = bus_valid && bus_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            desc_base_reg <= 32'd0;
            layer_num_reg <= 32'd0;
            last_cmd_reg <= 32'd0;
            acc_cmd_valid <= 1'b0;
            acc_cmd <= 2'd0;
            acc_desc_base <= 32'd0;
            acc_layer_num <= 32'd0;
            bus_rvalid <= 1'b0;
            bus_rdata <= 32'd0;
        end else begin
            acc_cmd_valid <= 1'b0;
            bus_rvalid <= 1'b0;

            if (accepted) begin
                if (bus_write) begin
                    case (offset)
                        OFF_DESC_BASE: begin
                            desc_base_reg <= bus_wdata;
                        end
                        OFF_LAYER_NUM: begin
                            layer_num_reg <= bus_wdata;
                        end
                        OFF_CMD: begin
                            last_cmd_reg <= bus_wdata;
                            if (bus_wdata[1:0] == CMD_START) begin
                                acc_cmd_valid <= 1'b1;
                                acc_cmd <= CMD_START;
                                acc_desc_base <= desc_base_reg;
                                acc_layer_num <= layer_num_reg;
                            end
                        end
                        default: begin
                            last_cmd_reg <= last_cmd_reg;
                        end
                    endcase
                end else begin
                    bus_rvalid <= 1'b1;
                    case (offset)
                        OFF_DESC_BASE: bus_rdata <= desc_base_reg;
                        OFF_LAYER_NUM: bus_rdata <= layer_num_reg;
                        OFF_CMD:       bus_rdata <= last_cmd_reg;
                        OFF_STATUS:    bus_rdata <= acc_status;
                        OFF_STAT:      bus_rdata <= {8'd0, acc_status[31:8]};
                        default:       bus_rdata <= 32'hffff_ffff;
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
