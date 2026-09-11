`timescale 1ns/1ps
`default_nettype none

/*
 * One-entry elastic write-command register for the group shared64 output
 * boundary.  The command is captured before the feature-SRAM port, so the
 * producer's address arithmetic cannot feed the SRAM byte-enable/bypass
 * compare in the same cycle.  A full entry may retire and be replaced on
 * one edge; when the sink stalls, all command fields remain registered and
 * stable.
 */
module ds_group_shared64_output_skid #(
    parameter integer ADDR_WIDTH = 15
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    in_valid,
    output wire                    in_ready,
    input  wire [ADDR_WIDTH-1:0]   in_addr,
    input  wire [31:0]             in_data,
    input  wire [3:0]              in_be,
    input  wire                    in_bank,
    input  wire                    in_last,
    output wire                    out_valid,
    input  wire                    out_ready,
    output wire [ADDR_WIDTH-1:0]   out_addr,
    output wire [31:0]             out_data,
    output wire [3:0]              out_be,
    output wire                    out_bank,
    output wire                    out_last,
    output wire                    in_fire,
    output wire                    out_fire
);
    reg valid_q;
    reg [ADDR_WIDTH-1:0] addr_q;
    reg [31:0] data_q;
    reg [3:0] be_q;
    reg bank_q;
    reg last_q;

    wire out_ready_i = (out_ready === 1'b1);

    assign in_ready = !valid_q || out_ready_i;
    assign in_fire = in_valid && in_ready;
    assign out_valid = valid_q;
    assign out_fire = valid_q && out_ready_i;
    assign out_addr = addr_q;
    assign out_data = data_q;
    assign out_be = be_q;
    assign out_bank = bank_q;
    assign out_last = last_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            valid_q <= 1'b0;
            addr_q <= {ADDR_WIDTH{1'b0}};
            data_q <= 32'd0;
            be_q <= 4'd0;
            bank_q <= 1'b0;
            last_q <= 1'b0;
        end else begin
            if (out_fire)
                valid_q <= 1'b0;
            if (in_fire) begin
                valid_q <= 1'b1;
                addr_q <= in_addr;
                data_q <= in_data;
                be_q <= in_be;
                bank_q <= in_bank;
                last_q <= in_last;
            end
        end
    end
endmodule

`default_nettype wire
