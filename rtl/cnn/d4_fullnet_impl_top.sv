`timescale 1ns/1ps
`default_nettype none
// Physical top packs four little-endian 32-bit beats into a core image word.
// CLG400 exposes 125 PL I/O pins, so the 128-bit core bus stays internal.
// No simulator-only source of activations, intermediate results, or FC outputs.
module d4_fullnet_impl_top (
    input wire clk, rst_n, start_valid,
    output wire start_ready,
    input wire input_valid, output wire input_ready,
    input wire [31:0] input_data,
    output wire logit_valid, input wire logit_ready,
    output wire [3:0] logit_index, output wire signed [31:0] logit_acc,
    output wire done_valid, input wire done_ready,
    output wire busy, error
);
    wire core_clk,core_rst_n,clock_locked,operational;
    d4_fullnet_clocking u_clocking (
        .clk_in(clk),.external_reset_n(rst_n),.core_clk(core_clk),
        .core_reset_n(core_rst_n),.locked(clock_locked),.operational(operational)
    );
    reg [127:0] packed_data;
    reg [1:0] chunk_index;
    reg [12:0] image_chunks;
    reg packed_valid;
    (* IOB = "FALSE" *) reg pack_input_ready;
    wire core_input_ready,core_start_ready;
    wire core_logit_valid,core_done_valid,core_busy,core_error;
    reg pending_start;
    wire core_start_valid;
    // The core only reaches IDLE after consuming the final packed image word,
    // so packed_valid is clear whenever its registered start_ready is high.
    // One registered token breaks the external start_valid -> core state-CE
    // path. The external handshake enqueues; the core handshake dequeues.
    assign start_ready=core_start_ready & ~pending_start & operational;
    assign core_start_valid=pending_start & operational;
    assign input_ready=pack_input_ready & core_busy & operational;
    always @(posedge core_clk or negedge core_rst_n) begin
        if(!core_rst_n) pending_start<=0;
        else if(!pending_start && start_valid && start_ready) pending_start<=1;
        else if(pending_start && core_start_ready) pending_start<=0;
    end
    always @(posedge core_clk or negedge core_rst_n) begin
        if(!core_rst_n) begin
            packed_data<=0;chunk_index<=0;image_chunks<=0;packed_valid<=0;
            pack_input_ready<=0;
        end else if(start_valid && start_ready) begin
            chunk_index<=0;image_chunks<=0;packed_valid<=0;
            pack_input_ready<=1;
        end else begin
            if(packed_valid && core_input_ready) packed_valid<=0;
            if(input_valid && input_ready) begin
                packed_data[chunk_index*32+:32]<=input_data;
                image_chunks<=image_chunks+1;
                if(image_chunks==4095) pack_input_ready<=0;
                if(chunk_index==3) begin packed_valid<=1;chunk_index<=0;end
                else chunk_index<=chunk_index+1;
            end
        end
    end
    d4_fullnet_top u_core (
        .clk(core_clk),.rst_n(core_rst_n),
        .start_valid(core_start_valid),.start_ready(core_start_ready),
        .input_valid(packed_valid),.input_ready(core_input_ready),.input_data(packed_data),
        .logit_valid(core_logit_valid),.logit_ready(logit_ready),
        .logit_index(logit_index),.logit_acc(logit_acc),
        .done_valid(core_done_valid),.done_ready(done_ready & operational),
        .busy(core_busy),.error(core_error),
        .cycle_count(),.semantic_mac_count(),
        .trace_valid(),.trace_op(),.trace_index(),.trace_data()
    );
    assign logit_valid=core_logit_valid & operational;
    assign done_valid=core_done_valid & operational;
    assign busy=(core_busy | pending_start) & operational;
    // External admission starts a new transaction, so hide the previous
    // completion's sticky error while its core-start token is pending.
    assign error=core_error & ~pending_start & operational;
endmodule
`default_nettype wire
