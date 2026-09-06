`timescale 1ns/1ps
`default_nettype none

// Stand-alone 32 KiB activation store for the DS12 vector experiments.
//
// The storage is intentionally sixteen independent byte-wide memories.  A
// 32-bit write addresses one 16-byte line and updates four consecutive lane
// memories selected by addr[3:2] and byte-enable.  A vector read captures all
// sixteen lane values into a registered response.  Because the RHS of the
// memory reads is evaluated before the nonblocking write assignments at the
// same edge, a read and write of one line have READ_FIRST semantics.
module ds12_stream_vector_lane_bank #(
    parameter integer LINE_WORDS = 2048
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         write_valid,
    output wire         write_ready,
    input  wire [31:0]  write_addr,
    input  wire [31:0]  write_data,
    input  wire [3:0]   write_be,

    input  wire         vector_req_valid,
    output wire         vector_req_ready,
    input  wire [31:0]  vector_req_addr,
    output reg          vector_resp_valid,
    input  wire         vector_resp_ready,
    output reg  [127:0] vector_resp_data,
    output reg  [31:0]  vector_resp_addr,

    output reg          error,
    output reg  [3:0]   error_code
);
    localparam integer BANK_BYTES = LINE_WORDS * 16;
    localparam [3:0] ERR_WRITE_ALIGN = 4'h1;
    localparam [3:0] ERR_WRITE_RANGE = 4'h2;
    localparam [3:0] ERR_READ_ALIGN  = 4'h4;
    localparam [3:0] ERR_READ_RANGE  = 4'h8;

    // Keep these as separate arrays: each is a physical 8-bit lane bank,
    // rather than one packed memory followed by a combinational byte slice.
    reg [7:0] lane0_mem  [0:LINE_WORDS-1];
    reg [7:0] lane1_mem  [0:LINE_WORDS-1];
    reg [7:0] lane2_mem  [0:LINE_WORDS-1];
    reg [7:0] lane3_mem  [0:LINE_WORDS-1];
    reg [7:0] lane4_mem  [0:LINE_WORDS-1];
    reg [7:0] lane5_mem  [0:LINE_WORDS-1];
    reg [7:0] lane6_mem  [0:LINE_WORDS-1];
    reg [7:0] lane7_mem  [0:LINE_WORDS-1];
    reg [7:0] lane8_mem  [0:LINE_WORDS-1];
    reg [7:0] lane9_mem  [0:LINE_WORDS-1];
    reg [7:0] lane10_mem [0:LINE_WORDS-1];
    reg [7:0] lane11_mem [0:LINE_WORDS-1];
    reg [7:0] lane12_mem [0:LINE_WORDS-1];
    reg [7:0] lane13_mem [0:LINE_WORDS-1];
    reg [7:0] lane14_mem [0:LINE_WORDS-1];
    reg [7:0] lane15_mem [0:LINE_WORDS-1];

    // A response register is the one-entry elastic output.  The response
    // data/address are not changed while valid is stalled.  A response may
    // be consumed and replaced by a new request on the same edge, sustaining
    // one vector per cycle when ready remains asserted.
    assign write_ready = rst_n;
    assign vector_req_ready = rst_n && ((!vector_resp_valid) || vector_resp_ready);

    // Keep the address arithmetic shared, but make every physical lane's
    // write enable and read port explicit.  This is the RAM inference form:
    // each byte array has one variable row address and a fixed data path;
    // there is no variable-index memory selection or function/case mux.
    localparam integer INDEX_BITS = (LINE_WORDS <= 1) ? 1 : $clog2(LINE_WORDS);
    wire [INDEX_BITS-1:0] write_index = write_addr[INDEX_BITS+3:4];
    wire [INDEX_BITS-1:0] read_index  = vector_req_addr[INDEX_BITS+3:4];
    wire                  write_fire  = write_valid && write_ready &&
                                         (write_addr[1:0] == 2'b00) &&
                                         (write_addr < BANK_BYTES);
    wire [1:0]            write_group = write_addr[3:2];

    always @(posedge clk) begin
        if (!rst_n) begin
            vector_resp_valid <= 1'b0;
            vector_resp_data  <= 128'd0;
            vector_resp_addr  <= 32'd0;
            error             <= 1'b0;
            error_code        <= 4'd0;
        end else begin
            if (vector_resp_valid && vector_resp_ready)
                vector_resp_valid <= 1'b0;

            // Fixed lane write enables.  The four byte lanes in a word are
            // selected by the aligned word's offset within its 16-byte line.
            if (write_fire && write_be[0] && (write_group == 2'd0))
                lane0_mem[write_index] <= write_data[7:0];
            if (write_fire && write_be[1] && (write_group == 2'd0))
                lane1_mem[write_index] <= write_data[15:8];
            if (write_fire && write_be[2] && (write_group == 2'd0))
                lane2_mem[write_index] <= write_data[23:16];
            if (write_fire && write_be[3] && (write_group == 2'd0))
                lane3_mem[write_index] <= write_data[31:24];
            if (write_fire && write_be[0] && (write_group == 2'd1))
                lane4_mem[write_index] <= write_data[7:0];
            if (write_fire && write_be[1] && (write_group == 2'd1))
                lane5_mem[write_index] <= write_data[15:8];
            if (write_fire && write_be[2] && (write_group == 2'd1))
                lane6_mem[write_index] <= write_data[23:16];
            if (write_fire && write_be[3] && (write_group == 2'd1))
                lane7_mem[write_index] <= write_data[31:24];
            if (write_fire && write_be[0] && (write_group == 2'd2))
                lane8_mem[write_index] <= write_data[7:0];
            if (write_fire && write_be[1] && (write_group == 2'd2))
                lane9_mem[write_index] <= write_data[15:8];
            if (write_fire && write_be[2] && (write_group == 2'd2))
                lane10_mem[write_index] <= write_data[23:16];
            if (write_fire && write_be[3] && (write_group == 2'd2))
                lane11_mem[write_index] <= write_data[31:24];
            if (write_fire && write_be[0] && (write_group == 2'd3))
                lane12_mem[write_index] <= write_data[7:0];
            if (write_fire && write_be[1] && (write_group == 2'd3))
                lane13_mem[write_index] <= write_data[15:8];
            if (write_fire && write_be[2] && (write_group == 2'd3))
                lane14_mem[write_index] <= write_data[23:16];
            if (write_fire && write_be[3] && (write_group == 2'd3))
                lane15_mem[write_index] <= write_data[31:24];

            if (write_valid && write_ready) begin
                if (write_addr[1:0] != 2'b00) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_WRITE_ALIGN;
                end else if (write_addr >= BANK_BYTES) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_WRITE_RANGE;
                end
            end

            if (vector_req_valid && vector_req_ready) begin
                if (vector_req_addr[3:0] != 4'h0) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_READ_ALIGN;
                end else if (vector_req_addr > (BANK_BYTES - 16)) begin
                    error <= 1'b1;
                    error_code <= error_code | ERR_READ_RANGE;
                end else begin
                    // All RHS values are old-state values at this edge.  If
                    // a write targets this same line, this is READ_FIRST.
                    // Each lane is a fixed synchronous RAM read port.
                    vector_resp_data[7:0]    <= lane0_mem[read_index];
                    vector_resp_data[15:8]   <= lane1_mem[read_index];
                    vector_resp_data[23:16]  <= lane2_mem[read_index];
                    vector_resp_data[31:24]  <= lane3_mem[read_index];
                    vector_resp_data[39:32]  <= lane4_mem[read_index];
                    vector_resp_data[47:40]  <= lane5_mem[read_index];
                    vector_resp_data[55:48]  <= lane6_mem[read_index];
                    vector_resp_data[63:56]  <= lane7_mem[read_index];
                    vector_resp_data[71:64]  <= lane8_mem[read_index];
                    vector_resp_data[79:72]  <= lane9_mem[read_index];
                    vector_resp_data[87:80]  <= lane10_mem[read_index];
                    vector_resp_data[95:88]  <= lane11_mem[read_index];
                    vector_resp_data[103:96] <= lane12_mem[read_index];
                    vector_resp_data[111:104] <= lane13_mem[read_index];
                    vector_resp_data[119:112] <= lane14_mem[read_index];
                    vector_resp_data[127:120] <= lane15_mem[read_index];
                    vector_resp_addr <= vector_req_addr;
                    vector_resp_valid <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
