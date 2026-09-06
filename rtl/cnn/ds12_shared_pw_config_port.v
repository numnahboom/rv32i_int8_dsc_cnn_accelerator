`timescale 1ns/1ps
`default_nettype none

// Serialized packed-configuration port for the shared DS1/DS2 slice.
// External memory sees one request at a time and may delay its response.  A
// response is held until the broadcast word is accepted by the service and
// (for the DW prefix) the selected adapter.  Thus configuration ownership is
// one bank/one epoch at the top-level rather than a pair of hidden loaders.
module ds12_shared_pw_config_port #(
    parameter [31:0] DS1_BASE = 32'd0,
    parameter [31:0] DS2_BASE = 32'd168
) (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [1:0] start_layer,
    input wire [15:0] start_word_count,
    input wire [31:0] start_base_addr,
    output wire start_ready,

    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire [31:0] mem_req_addr,
    output wire [15:0] mem_req_index,
    output wire [1:0] mem_req_layer,
    output wire [3:0] mem_req_strb,
    input wire mem_resp_valid,
    output wire mem_resp_ready,
    input wire [31:0] mem_resp_data,

    output wire word_valid,
    input wire word_ready,
    output wire [1:0] word_layer,
    output wire [9:0] word_index,
    output wire [31:0] word_data,
    output reg busy,
    output reg load_done,
    output reg error
);
    reg [1:0] layer_r;
    reg [15:0] count_r;
    reg [31:0] base_r;
    reg [15:0] index_r;
    reg req_waiting;
    reg word_valid_r;
    reg [31:0] word_data_r;
    reg error_r;

    assign start_ready = rst_n && !busy && !word_valid_r && !req_waiting;
    // A consumed response word and the next request may share one edge.
    // This keeps the external request channel at its natural memory-latency
    // rate while still retaining the response word under a downstream stall.
    wire word_replace = word_valid_r && word_ready;
    wire [15:0] req_index_next = index_r + {{15{1'b0}}, word_replace};
    assign mem_req_valid = rst_n && busy && !req_waiting &&
                           (!word_valid_r || word_ready) &&
                           (req_index_next < count_r);
    assign mem_req_addr = base_r + ({16'd0, req_index_next} << 2);
    assign mem_req_index = req_index_next;
    assign mem_req_layer = layer_r;
    assign mem_req_strb = 4'hf;
    assign mem_resp_ready = rst_n && req_waiting;

    assign word_valid = word_valid_r;
    assign word_layer = layer_r;
    assign word_index = index_r[9:0];
    assign word_data = word_data_r;
    assign error = error_r;

    wire start_fire = start && start_ready;
    wire req_fire = mem_req_valid && mem_req_ready;
    wire resp_fire = mem_resp_valid && mem_resp_ready;
    wire word_fire = word_valid_r && word_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            layer_r <= 0;
            count_r <= 0;
            base_r <= 0;
            index_r <= 0;
            req_waiting <= 0;
            word_valid_r <= 0;
            word_data_r <= 0;
            busy <= 0;
            load_done <= 0;
            error_r <= 0;
        end else begin
            load_done <= 1'b0;
            if (start_fire) begin
                if ((start_layer != 2'd1 && start_layer != 2'd2) ||
                    start_word_count == 0) begin
                    error_r <= 1'b1;
                end else begin
                    layer_r <= start_layer;
                    count_r <= start_word_count;
                    base_r <= start_base_addr;
                    index_r <= 0;
                    req_waiting <= 0;
                    word_valid_r <= 0;
                    busy <= 1'b1;
                end
            end

            if (req_fire)
                req_waiting <= 1'b1;

            if (resp_fire) begin
                req_waiting <= 1'b0;
                word_data_r <= mem_resp_data;
                word_valid_r <= 1'b1;
            end

            if (word_fire) begin
                word_valid_r <= 1'b0;
                if (index_r == count_r - 1'b1) begin
                    busy <= 1'b0;
                    load_done <= 1'b1;
                end else begin
                    index_r <= index_r + 1'b1;
                end
            end

            if (mem_resp_valid && !req_waiting)
                error_r <= 1'b1;
        end
    end
endmodule

`default_nettype wire
