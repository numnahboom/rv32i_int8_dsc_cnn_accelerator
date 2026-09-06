`timescale 1ns/1ps
`default_nettype none

// Non-preemptive DS1 -> DS2 scheduler.  Configuration, activation-bank
// ownership, and the single PW service all change only at explicit fences.
module ds12_shared_pw_scheduler (
    input wire clk,
    input wire rst_n,
    input wire start,

    output wire cfg_start_valid,
    input wire cfg_start_ready,
    output wire [1:0] cfg_start_layer,
    output wire [15:0] cfg_start_count,
    output wire [31:0] cfg_start_base,
    input wire cfg_load_done,

    output wire service_start_valid,
    input wire service_start_ready,
    output wire [1:0] service_start_layer,
    input wire service_done,

    output wire ds1_start_valid,
    input wire ds1_start_ready,
    input wire ds1_done,
    output wire ds2_start_valid,
    input wire ds2_start_ready,
    input wire ds2_done,

    output wire activation_start_valid,
    input wire activation_start_ready,
    output wire activation_start_bank,
    output wire [31:0] activation_start_epoch,
    output wire [31:0] activation_start_words,
    output wire activation_commit_valid,
    input wire activation_commit_ready,
    input wire activation_commit_done,

    output wire running,
    output wire done,
    output wire ds1_active,
    output wire ds2_active,
    output wire [31:0] cycle_count
);
    localparam [3:0] S_IDLE = 4'd0;
    localparam [3:0] S_CFG1_REQ = 4'd1;
    localparam [3:0] S_CFG1_WAIT = 4'd2;
    localparam [3:0] S_RUN1_START = 4'd3;
    localparam [3:0] S_RUN1 = 4'd4;
    localparam [3:0] S_COMMIT1 = 4'd5;
    localparam [3:0] S_CFG2_REQ = 4'd6;
    localparam [3:0] S_CFG2_WAIT = 4'd7;
    localparam [3:0] S_RUN2_START = 4'd8;
    localparam [3:0] S_RUN2 = 4'd9;
    localparam [3:0] S_DONE = 4'd10;

    reg [3:0] state;
    reg [31:0] cycles;

    assign cfg_start_valid = (state == S_CFG1_REQ) || (state == S_CFG2_REQ);
    assign cfg_start_layer = (state == S_CFG2_REQ) ? 2'd2 : 2'd1;
    assign cfg_start_count = (state == S_CFG2_REQ) ? 16'd872 : 16'd308;
    assign cfg_start_base = (state == S_CFG2_REQ) ? 32'd168 : 32'd0;

    assign service_start_valid = (state == S_RUN1_START) || (state == S_RUN2_START);
    assign service_start_layer = (state == S_RUN2_START) ? 2'd2 : 2'd1;
    assign ds1_start_valid = (state == S_RUN1_START);
    assign ds2_start_valid = (state == S_RUN2_START);

    assign activation_start_valid = (state == S_RUN1_START);
    assign activation_start_bank = 1'b1;
    assign activation_start_epoch = 32'd1;
    assign activation_start_words = 32'd8192;
    assign activation_commit_valid = (state == S_COMMIT1);

    assign running = (state != S_IDLE) && (state != S_DONE);
    assign done = (state == S_DONE);
    assign ds1_active = (state == S_RUN1) || (state == S_COMMIT1);
    assign ds2_active = (state == S_RUN2);
    assign cycle_count = cycles;

    wire cfg_fire = cfg_start_valid && cfg_start_ready;
    wire service_start_fire = service_start_valid && service_start_ready &&
                              ((state == S_RUN1_START) ? ds1_start_ready &&
                              activation_start_ready : ds2_start_ready);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            cycles <= 0;
        end else begin
            if (running)
                cycles <= cycles + 1'b1;
            case (state)
                S_IDLE: if (start) state <= S_CFG1_REQ;
                S_CFG1_REQ: if (cfg_fire) state <= S_CFG1_WAIT;
                S_CFG1_WAIT: if (cfg_load_done) state <= S_RUN1_START;
                S_RUN1_START: if (service_start_fire) state <= S_RUN1;
                S_RUN1: if (service_done && ds1_done) state <= S_COMMIT1;
                // The bank raises commit_done on the edge that accepts the
                // command; the scheduler observes that registered pulse on
                // the following edge, after active_write has already been
                // cleared.  Do not re-qualify it with ready here.
                S_COMMIT1: if (activation_commit_done)
                    state <= S_CFG2_REQ;
                S_CFG2_REQ: if (cfg_fire) state <= S_CFG2_WAIT;
                S_CFG2_WAIT: if (cfg_load_done) state <= S_RUN2_START;
                S_RUN2_START: if (service_start_fire) state <= S_RUN2;
                S_RUN2: if (service_done && ds2_done) state <= S_DONE;
                S_DONE: state <= S_DONE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
