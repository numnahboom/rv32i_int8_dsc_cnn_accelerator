`timescale 1ns/1ps
`default_nettype none

module ds_spatial_word_window_bank_ooc_wrapper (
    input wire clk,
    input wire rst_n,
    input wire wr_valid,
    input wire [9:0] wr_vector_addr,
    input wire [1:0] wr_quarter,
    input wire [31:0] wr_data,
    input wire [3:0] wr_epoch,
    input wire rd_req_valid,
    input wire [9:0] rd_vector_addr,
    input wire [15:0] rd_lane_mask,
    input wire [8:0] rd_tag,
    input wire [3:0] rd_epoch,
    input wire rd_resp_ready,
    output wire wr_ready,
    output wire [3:0] wr_epoch_seen,
    output wire rd_req_ready,
    output wire rd_resp_valid,
    output wire [127:0] rd_data_vector,
    output wire [15:0] rd_resp_lane_mask,
    output wire [8:0] rd_resp_tag,
    output wire [3:0] rd_resp_epoch
);
    ds_spatial_word_window_bank #(
        .MAX_IN_H(17), .MAX_IN_W(17), .MAX_CHANNEL_GROUPS(3),
        .DEPTH(867), .ADDR_WIDTH(10), .EPOCH_WIDTH(4), .TAG_WIDTH(9)
    ) u_bank (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_vector_addr(wr_vector_addr), .wr_quarter(wr_quarter),
        .wr_data(wr_data), .wr_epoch(wr_epoch), .wr_epoch_seen(wr_epoch_seen),
        .rd_req_valid(rd_req_valid), .rd_req_ready(rd_req_ready),
        .rd_vector_addr(rd_vector_addr), .rd_lane_mask(rd_lane_mask),
        .rd_tag(rd_tag), .rd_epoch(rd_epoch),
        .rd_resp_valid(rd_resp_valid), .rd_resp_ready(rd_resp_ready),
        .rd_data_vector(rd_data_vector), .rd_resp_lane_mask(rd_resp_lane_mask),
        .rd_resp_tag(rd_resp_tag), .rd_resp_epoch(rd_resp_epoch)
    );
endmodule

`default_nettype wire
