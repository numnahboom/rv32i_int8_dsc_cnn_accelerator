`timescale 1ns/1ps
`default_nettype none
/* 8 ns XC7Z020 screen for the complete standalone wordstream feasibility
 * datapath.  The wrapper is intentionally closed locally and has no
 * production cnn_top/runner connection. */
module wordstream_feasibility_ooc_wrapper(
    input wire clk, input wire rst_n, input wire start,
    input wire mem_req_ready, input wire mem_resp_valid, input wire [31:0] mem_resp_data,
    output wire mem_req_valid, output wire [23:0] mem_req_addr,
    output wire busy, output wire done, output wire error,
    output wire debug_dw_checksum
);
    wire [31:0] perf_cycles, perf_mac_tokens, perf_mem_issues, perf_mem_responses, perf_consumes, perf_overlap;
    wire stem_wr_valid, pw_wr_valid;
    wire [15:0] stem_wr_index, pw_wr_index;
    wire signed [7:0] stem_wr_data, pw_wr_data;
    wordstream_feasibility_harness #(.STORAGE_ENABLED(0)) u_harness (
        .clk(clk), .rst_n(rst_n), .start(start),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr),
        .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data), .busy(busy), .done(done), .error(error),
        .perf_cycles(perf_cycles), .perf_mac_tokens(perf_mac_tokens),
        .perf_mem_issues(perf_mem_issues), .perf_mem_responses(perf_mem_responses),
        .perf_consumes(perf_consumes), .perf_overlap_cycles(perf_overlap),
        .stem_wr_valid(stem_wr_valid), .stem_wr_index(stem_wr_index), .stem_wr_data(stem_wr_data),
        .pw_wr_valid(pw_wr_valid), .pw_wr_index(pw_wr_index), .pw_wr_data(pw_wr_data),
        .debug_dw_checksum(debug_dw_checksum)
    );
endmodule
`default_nettype wire
