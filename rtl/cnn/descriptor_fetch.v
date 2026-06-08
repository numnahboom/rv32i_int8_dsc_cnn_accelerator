`timescale 1ns/1ps
`default_nettype none

module descriptor_fetch #(
    parameter DESC_WORDS = 32,
    parameter DESC_STRIDE_BYTES = 128
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         start,
    input  wire [31:0]                  desc_base_addr,
    input  wire [31:0]                  layer_index,
    output reg                          busy,
    output reg                          valid,
    output reg  [(DESC_WORDS*32)-1:0]   desc_words,
    output wire [31:0]                  op_type,

    output reg                          mem_req_valid,
    output wire                         mem_req_write,
    output reg  [31:0]                  mem_req_addr,
    output wire [31:0]                  mem_req_wdata,
    input  wire                         mem_req_ready,
    input  wire                         mem_resp_valid,
    input  wire [31:0]                  mem_resp_rdata
);
    localparam ST_IDLE = 2'd0;
    localparam ST_REQ = 2'd1;
    localparam ST_RESP = 2'd2;

    reg [1:0] state;
    reg [5:0] word_idx;
    wire [31:0] layer_byte_offset;
    wire [31:0] word_byte_offset;

    assign layer_byte_offset = layer_index * DESC_STRIDE_BYTES;
    assign word_byte_offset = {24'd0, word_idx, 2'b00};
    assign mem_req_write = 1'b0;
    assign mem_req_wdata = 32'd0;
    assign op_type = desc_words[31:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            word_idx <= 6'd0;
            busy <= 1'b0;
            valid <= 1'b0;
            desc_words <= {(DESC_WORDS*32){1'b0}};
            mem_req_valid <= 1'b0;
            mem_req_addr <= 32'd0;
        end else begin
            valid <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    mem_req_valid <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        word_idx <= 6'd0;
                        desc_words <= {(DESC_WORDS*32){1'b0}};
                        state <= ST_REQ;
                    end
                end

                ST_REQ: begin
                    mem_req_valid <= 1'b1;
                    mem_req_addr <= desc_base_addr + layer_byte_offset + word_byte_offset;
                    if (mem_req_valid && mem_req_ready) begin
                        mem_req_valid <= 1'b0;
                        state <= ST_RESP;
                    end
                end

                ST_RESP: begin
                    if (mem_resp_valid) begin
                        desc_words[(word_idx*32) +: 32] <= mem_resp_rdata;
                        if (word_idx == (DESC_WORDS - 1)) begin
                            busy <= 1'b0;
                            valid <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            word_idx <= word_idx + 6'd1;
                            state <= ST_REQ;
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
