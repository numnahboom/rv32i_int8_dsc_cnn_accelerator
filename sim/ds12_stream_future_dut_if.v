`timescale 1ns/1ps
`default_nettype none

// Port-only future boundary.  It is intentionally non-functional: if this
// module is selected as a DUT, the harness must time out waiting for output.
// A real candidate can be supplied with -DDS12_STREAM_DUT_MODULE=<module>
// when its ports obey this contract.
module ds12_stream_future_dut_if (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output wire        ready,
    input  wire        cfg_valid,
    output wire        cfg_ready,
    input  wire [31:0] cfg_data,
    input  wire        cfg_last,
    output wire        mem_req_valid,
    input  wire        mem_req_ready,
    output wire        mem_req_write,
    output wire [31:0] mem_req_addr,
    output wire [31:0] mem_req_wdata,
    output wire [3:0]  mem_req_strb,
    input  wire        mem_resp_valid,
    input  wire [31:0] mem_resp_rdata,
    output wire        stream_valid,
    input  wire        stream_ready,
    output wire [7:0]  stream_data,
    output wire [15:0] stream_pixel,
    output wire [1:0]  stream_context,
    output wire        stream_owner,
    output wire [31:0] stream_epoch,
    output wire        stream_last,
    output wire        sink_valid,
    input  wire        sink_ready,
    output wire [31:0] sink_addr,
    output wire [31:0] sink_data,
    output wire [3:0]  sink_strb,
    output wire        sink_owner,
    output wire [31:0] sink_epoch,
    output wire [1:0]  sink_context
);
    assign ready = 1'b0;
    assign cfg_ready = 1'b0;
    assign mem_req_valid = 1'b0;
    assign mem_req_write = 1'b0;
    assign mem_req_addr = 32'd0;
    assign mem_req_wdata = 32'd0;
    assign mem_req_strb = 4'd0;
    assign stream_valid = 1'b0;
    assign stream_data = 8'd0;
    assign stream_pixel = 16'd0;
    assign stream_context = 2'd0;
    assign stream_owner = 1'b0;
    assign stream_epoch = 32'd0;
    assign stream_last = 1'b0;
    assign sink_valid = 1'b0;
    assign sink_addr = 32'd0;
    assign sink_data = 32'd0;
    assign sink_strb = 4'd0;
    assign sink_owner = 1'b0;
    assign sink_epoch = 32'd0;
    assign sink_context = 2'd0;

    initial begin
        $display("DUT_STUB_SELECTED no datapath behavior; the harness must not report architecture PASS");
    end
endmodule

`default_nettype wire
