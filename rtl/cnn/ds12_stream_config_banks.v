`timescale 1ns/1ps
`default_nettype none

// Stand-alone packed DS1/DS2 configuration loader.  This block deliberately
// has no dependency on cnn_layer_runner or on a particular compute engine.
// A load is issued into the bank opposite active_bank; the active bank is
// therefore never written.  Requests may be accepted every cycle and the
// response FIFO preserves the word index when memory adds arbitrary delay.
module ds12_stream_config_banks #(
    parameter integer BANK_WORDS = 872,
    parameter integer REQUEST_FIFO_WORDS = 1024
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [1:0]  start_layer,
    input  wire [31:0] start_base_addr,
    input  wire [15:0] start_word_count,
    input  wire [31:0] start_epoch,
    output wire        start_ready,

    output wire        mem_req_valid,
    input  wire        mem_req_ready,
    output wire [31:0] mem_req_addr,
    output wire [3:0]  mem_req_strb,
    output wire [15:0] mem_req_word_index,

    input  wire        mem_resp_valid,
    output wire        mem_resp_ready,
    input  wire [31:0] mem_resp_rdata,

    // Optional host commit request exists to make an early-commit violation
    // observable.  Normal operation commits automatically on the final
    // response after all issued requests have drained.
    input  wire        commit_req,
    input  wire        clear_error,

    input  wire        cfg_rd_en,
    input  wire        cfg_rd_bank,
    input  wire [15:0] cfg_rd_addr,
    output reg  [31:0] cfg_rd_data,
    output reg         cfg_rd_valid,

    output reg         busy,
    output reg         active_bank,
    output reg  [1:0]  active_layer,
    output reg  [31:0] active_epoch,
    output reg         active_valid,
    output reg  [1:0]  bank_valid,
    output reg  [15:0] expected_count,
    output reg  [15:0] issued_count,
    output reg  [15:0] received_count,
    output reg  [31:0] load_crc32,
    output reg         load_done,
    output reg         error,
    output reg  [3:0]  error_code
);
    localparam [3:0] ERR_NONE         = 4'd0;
    localparam [3:0] ERR_STALE        = 4'd1;
    localparam [3:0] ERR_OVERRUN      = 4'd2;
    localparam [3:0] ERR_EARLY_COMMIT = 4'd3;
    localparam [3:0] ERR_READ_INVALID = 4'd4;
    localparam [3:0] ERR_SPURIOUS_RESP= 4'd5;
    localparam [3:0] ERR_INDEX         = 4'd6;
    localparam [3:0] ERR_BAD_LAYER     = 4'd7;

    reg [31:0] bank_mem [0:1][0:BANK_WORDS-1];
    reg [1:0]  bank_layer [0:1];
    reg [31:0] bank_epoch [0:1];
    reg [15:0] bank_count [0:1];

    reg        load_bank;
    reg [1:0]  load_layer;
    reg [31:0] load_epoch;
    reg [31:0] load_base_addr;
    reg [15:0] load_count;
    reg [31:0] crc_reg;

    // FIFO entries are the issued source word indices.  Data is returned in
    // source order by the external memory contract; retaining the index here
    // also makes a malformed/overrun response detectable locally.
    reg [15:0] req_index_fifo [0:REQUEST_FIFO_WORDS-1];
    integer fifo_head;
    integer fifo_tail;
    integer fifo_count;

    wire valid_layer = (start_layer == 2'd1) || (start_layer == 2'd2);
    wire [15:0] layer_words = (start_layer == 2'd1) ? 16'd308 :
                              (start_layer == 2'd2) ? 16'd872 : 16'd0;
    wire valid_count = valid_layer && (start_word_count == layer_words) &&
                       (start_word_count != 16'd0) &&
                       (start_word_count <= BANK_WORDS[15:0]);
    wire stale_epoch = active_valid && (start_epoch <= active_epoch);
    assign start_ready = !busy;
    assign mem_req_valid = busy && (issued_count < expected_count) &&
                           (fifo_count < REQUEST_FIFO_WORDS);
    assign mem_req_addr = load_base_addr + ({16'd0, issued_count} << 2);
    assign mem_req_strb = 4'b1111;
    assign mem_req_word_index = issued_count;
    // Keep ready asserted so a response arriving without an outstanding
    // request is consumed and reported instead of being silently hidden.
    assign mem_resp_ready = 1'b1;

    function [31:0] crc32_word;
        input [31:0] crc_in;
        input [31:0] data;
        integer k;
        reg [31:0] c;
        begin
            c = crc_in ^ data;
            for (k = 0; k < 32; k = k + 1)
                c = c[0] ? ((c >> 1) ^ 32'hedb88320) : (c >> 1);
            crc32_word = c;
        end
    endfunction

    task set_error;
        input [3:0] code;
        begin
            error <= 1'b1;
            if (error_code == ERR_NONE)
                error_code <= code;
        end
    endtask

    wire req_fire = mem_req_valid && mem_req_ready;
    wire resp_fire = mem_resp_valid && mem_resp_ready;
    integer resp_index;

    always @(posedge clk) begin
        cfg_rd_valid <= 1'b0;
        load_done <= 1'b0;

        if (!rst_n) begin
            busy <= 1'b0;
            active_bank <= 1'b0;
            active_layer <= 2'd0;
            active_epoch <= 32'd0;
            active_valid <= 1'b0;
            bank_valid <= 2'b00;
            expected_count <= 16'd0;
            issued_count <= 16'd0;
            received_count <= 16'd0;
            load_crc32 <= 32'd0;
            crc_reg <= 32'hffff_ffff;
            error <= 1'b0;
            error_code <= ERR_NONE;
            load_bank <= 1'b0;
            load_layer <= 2'd0;
            load_epoch <= 32'd0;
            load_base_addr <= 32'd0;
            load_count <= 16'd0;
            fifo_head <= 0;
            fifo_tail <= 0;
            fifo_count <= 0;
            cfg_rd_data <= 32'd0;
            bank_layer[0] <= 2'd0; bank_layer[1] <= 2'd0;
            bank_epoch[0] <= 32'd0; bank_epoch[1] <= 32'd0;
            bank_count[0] <= 16'd0; bank_count[1] <= 16'd0;
        end else begin
            if (clear_error) begin
                error <= 1'b0;
                error_code <= ERR_NONE;
            end

            // Synchronous readable view of either committed bank.  A bank
            // under load is not readable until its atomic commit.
            if (cfg_rd_en) begin
                cfg_rd_valid <= 1'b1;
                if (!bank_valid[cfg_rd_bank] || (cfg_rd_addr >= bank_count[cfg_rd_bank])) begin
                    cfg_rd_data <= 32'd0;
                    set_error(ERR_READ_INVALID);
                end else begin
                    cfg_rd_data <= bank_mem[cfg_rd_bank][cfg_rd_addr[9:0]];
                end
            end

            if (start && start_ready) begin
                if (!valid_layer)
                    set_error(ERR_BAD_LAYER);
                else if (!valid_count)
                    set_error(ERR_OVERRUN);
                else if (stale_epoch)
                    set_error(ERR_STALE);
                else begin
                    busy <= 1'b1;
                    load_bank <= ~active_bank;
                    load_layer <= start_layer;
                    load_epoch <= start_epoch;
                    load_base_addr <= start_base_addr;
                    load_count <= start_word_count;
                    expected_count <= start_word_count;
                    issued_count <= 16'd0;
                    received_count <= 16'd0;
                    crc_reg <= 32'hffff_ffff;
                    load_crc32 <= 32'd0;
                    fifo_head <= 0;
                    fifo_tail <= 0;
                    fifo_count <= 0;
                end
            end else if (start && !start_ready) begin
                set_error(ERR_OVERRUN);
            end

            if (commit_req)
                set_error(ERR_EARLY_COMMIT);

            // Enqueue each accepted request.  The index is the index at the
            // request edge, independent of later response timing.
            if (req_fire) begin
                req_index_fifo[fifo_tail] <= issued_count;
                if (fifo_tail == REQUEST_FIFO_WORDS-1) fifo_tail <= 0;
                else fifo_tail <= fifo_tail + 1;
                issued_count <= issued_count + 1'b1;
            end

            if (resp_fire) begin
                if (fifo_count == 0) begin
                    set_error(ERR_SPURIOUS_RESP);
                end else begin
                    resp_index = {16'd0, req_index_fifo[fifo_head]};
                    if ((resp_index < 0) || (resp_index >= load_count) ||
                        (resp_index >= BANK_WORDS)) begin
                        set_error(ERR_INDEX);
                    end else begin
                        bank_mem[load_bank][resp_index] <= mem_resp_rdata;
                        received_count <= received_count + 1'b1;
                        crc_reg <= crc32_word(crc_reg, mem_resp_rdata);
                        load_crc32 <= crc32_word(crc_reg, mem_resp_rdata) ^ 32'hffff_ffff;
                    end
                    if (fifo_head == REQUEST_FIFO_WORDS-1) fifo_head <= 0;
                    else fifo_head <= fifo_head + 1;
                end
            end

            // Maintain outstanding request count with simultaneous push/pop.
            case ({req_fire, resp_fire && (fifo_count != 0)})
                2'b10: fifo_count <= fifo_count + 1;
                2'b01: fifo_count <= fifo_count - 1;
                default: fifo_count <= fifo_count;
            endcase

            // Final response is the only commit fence.  Because the request
            // FIFO is drained here, every source word has been captured.
            if (busy && resp_fire && (fifo_count == 1) &&
                (received_count + 1'b1 == expected_count) &&
                (issued_count == expected_count)) begin
                busy <= 1'b0;
                active_bank <= load_bank;
                active_layer <= load_layer;
                active_epoch <= load_epoch;
                active_valid <= 1'b1;
                bank_valid[load_bank] <= 1'b1;
                bank_layer[load_bank] <= load_layer;
                bank_epoch[load_bank] <= load_epoch;
                bank_count[load_bank] <= load_count;
                load_done <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
