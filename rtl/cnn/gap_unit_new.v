`timescale 1ns/1ps
`default_nettype none

/*
 * Streaming global-average pool for a fixed 4x4x256 tensor.
 * The 16 spatial samples are accumulated as they are loaded, so no 32 KiBit
 * packed feature register or 16-input combinational adder is required.
 */
module gap_unit_new (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              cfg_wr_en,
    output wire              cfg_ready,
    input  wire [15:0]       cfg_index,
    input  wire signed [7:0] cfg_data_int8,
    input  wire              start,
    output reg               busy,
    output reg               done,
    input  wire [7:0]        out_rd_index,
    output wire signed [7:0] out_rd_data
);
    (* ram_style = "distributed" *)
    reg signed [12:0] sum_mem [0:255];

    wire [7:0] cfg_channel;
    wire first_spatial_sample;
    wire signed [12:0] cfg_value_ext;
    wire signed [12:0] selected_sum;

    assign cfg_ready = !busy;
    assign cfg_channel = cfg_index[7:0];
    assign first_spatial_sample = (cfg_index < 16'd256);
    assign cfg_value_ext = {{5{cfg_data_int8[7]}}, cfg_data_int8};
    assign selected_sum = sum_mem[out_rd_index];
    assign out_rd_data = selected_sum >>> 4;

    always @(posedge clk) begin
        if (cfg_wr_en && cfg_ready && (cfg_index < 16'd4096)) begin
            if (first_spatial_sample) begin
                sum_mem[cfg_channel] <= cfg_value_ext;
            end else begin
                sum_mem[cfg_channel] <= sum_mem[cfg_channel] + cfg_value_ext;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
            end else if (busy) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
