`timescale 1ns/1ps
`default_nettype none

// DS1 compute datapath.  Storage is deliberately outside this block: the
// configuration and activation interfaces below are transaction boundaries,
// not memories hidden behind the datapath.
module ds12_stream_ds1_datapath #(
    parameter integer INPUT_BASE = 0,
    parameter integer SINK_BASE = 32'h00100000
) (
    input wire clk, input wire rst_n, input wire start,
    // External configuration-bank load/ownership boundary.
    output wire cfg_load_req_valid, input wire cfg_load_req_ready,
    output wire [1:0] cfg_load_req_layer, output wire [31:0] cfg_load_req_epoch,
    output wire [15:0] cfg_load_req_count,
    input wire cfg_load_done, input wire cfg_error,
    // Active configuration read port used by DW and PW (single outstanding).
    output wire cfg_active_rd_valid, input wire cfg_active_rd_ready,
    output wire [15:0] cfg_active_rd_addr,
    input wire cfg_active_rd_resp_valid, input wire [31:0] cfg_active_rd_resp_data,
    // DS2 prefetch is only a request; DS2 storage is owned by the caller.
    output wire ds2_prefetch_req_valid, input wire ds2_prefetch_req_ready,
    output wire [1:0] ds2_prefetch_req_layer, output wire [31:0] ds2_prefetch_req_epoch,
    output wire [15:0] ds2_prefetch_req_count,
    input wire ds2_prefetch_done,
    // DS1 input feature stream.
    output wire input_mem_req_valid, input wire input_mem_req_ready,
    output wire input_mem_req_write, output wire [31:0] input_mem_req_addr,
    output wire [127:0] input_mem_req_wdata, output wire [15:0] input_mem_req_strb,
    output wire [1:0] input_mem_req_context, output wire input_mem_req_owner,
    output wire [31:0] input_mem_req_epoch,
    input wire input_mem_resp_valid, input wire [127:0] input_mem_resp_data,
    // Activation write stream and commit fence.
    output wire activation_start_valid, input wire activation_start_ready,
    output wire activation_write_valid, input wire activation_write_ready,
    output wire [31:0] activation_write_addr, output wire [31:0] activation_write_data,
    output wire [3:0] activation_write_be, output wire activation_write_last,
    output wire activation_write_bank, output wire [31:0] activation_write_epoch,
    output wire [31:0] activation_write_count, output wire activation_write_drain,
    output wire activation_commit_req, input wire activation_commit_ack,
    output wire [1:0] activation_owner, output wire [31:0] activation_epoch,
    output reg layer_done, output reg error, output reg ds1_config_done,
    output reg ds2_preload_done, output reg [31:0] cycle_count,
    output reg [31:0] dw_first_cycle, output reg [31:0] dw_last_cycle,
    output reg [31:0] pw_first_cycle, output reg [31:0] pw_last_cycle,
    output reg [31:0] overlap_cycles, output reg [31:0] dw_idle_cycles,
    output reg [31:0] pw_idle_cycles, output wire [31:0] dw_mac_count,
    output wire [31:0] pw_mac_count, output wire [31:0] output_word_count,
    output wire [31:0] config_read_count, output wire [31:0] config_write_count,
    output wire [31:0] ds1_input_read_count, output wire [31:0] ds1_dw_vector_count
);
    localparam [4:0] IDLE=0,C1_REQ=1,C1_WAIT=2,DW_REQ=3,DW_WAIT=4,DW_SEND=5,
                     DW_LAUNCH=6,PW_CFG=7,PW_WAIT=8,PW_SEND=9,OPEN=10,LAUNCH=11,
                     D2_REQ=12,RUN=13,DRAIN=14,COMMIT=15,DONE=16;
    reg [4:0] state;
    reg [6:0] dw_i; reg [7:0] pw_i; reg [31:0] cfg_reads, cfg_writes;
    reg [31:0] dw_cfg_r, pw_cfg_r; reg dw_cfg_v, pw_resp_v;
    reg [1:0] drain; reg [31:0] token_prev; reg dw_seen,pw_seen;
    wire dw_ready, dw_stream_ready, dw_cfg_ready, dw_valid, dw_last, dw_err;
    wire [127:0] dw_data; wire [31:0] dw_inputs;
    wire [5:0] dw_row; wire [9:0] dw_pixel; wire [1:0] dw_ctx; wire dw_owner; wire [31:0] dw_epoch;
    wire pw_ready,pw_req_v,pw_cfg_ready,pw_cfg_resp_ready,pw_done,pw_err,pw_dw_ready;
    wire [31:0] pw_cfg_addr; wire [7:0] pw_cfg_idx; wire [1:0] pw_cfg_kind; wire pw_cfg_last;
    wire sink_v,sink_last; wire [31:0] sink_addr,sink_data; wire [3:0] sink_be;
    wire [31:0] pw_tokens,pw_macs,pw_outputs,pw_vectors;
    wire dw_fire = dw_valid && dw_stream_ready;
    wire pw_activity = pw_tokens != token_prev;
    assign dw_stream_ready = pw_dw_ready;
    // The local datapath serializes the single config-bank read port; expose
    // readiness to the PW requester only while its request state is active.
    assign pw_cfg_ready = (state == PW_CFG);
    assign cfg_load_req_valid = (state==C1_REQ) || (state==D2_REQ);
    assign cfg_load_req_layer = (state==D2_REQ) ? 2'd2 : 2'd1;
    assign cfg_load_req_epoch = (state==D2_REQ) ? 32'd2 : 32'd1;
    assign cfg_load_req_count = (state==D2_REQ) ? 16'd872 : 16'd308;
    assign ds2_prefetch_req_valid = (state==D2_REQ);
    assign ds2_prefetch_req_layer = 2'd2; assign ds2_prefetch_req_epoch=32'd2;
    assign ds2_prefetch_req_count=16'd872;
    assign cfg_active_rd_valid = (state==DW_REQ) || ((state==PW_CFG) && pw_req_v && pw_cfg_ready);
    assign cfg_active_rd_addr = (state==DW_REQ) ? {9'd0,dw_i} : (16'd84 + {8'd0,pw_cfg_idx});
    ds12_stream_ds1_dw_endpoint #(.INPUT_BASE(INPUT_BASE)) dw_ep (
      .clk(clk),.rst_n(rst_n),.start((state==LAUNCH)||(state==DW_LAUNCH)),.ready(dw_ready),
      .cfg_valid(dw_cfg_v),.cfg_ready(dw_cfg_ready),.cfg_data(dw_cfg_r),.cfg_last(dw_i==83),
      .mem_req_valid(input_mem_req_valid),.mem_req_ready(input_mem_req_ready),.mem_req_write(input_mem_req_write),.mem_req_addr(input_mem_req_addr),.mem_req_wdata(input_mem_req_wdata),.mem_req_strb(input_mem_req_strb),.mem_req_context(input_mem_req_context),.mem_req_owner(input_mem_req_owner),.mem_req_epoch(input_mem_req_epoch),.mem_resp_valid(input_mem_resp_valid),.mem_resp_rdata(input_mem_resp_data),.dw_valid(dw_valid),.dw_ready(dw_stream_ready),.dw_data(dw_data),.dw_row(dw_row),.dw_pixel(dw_pixel),.dw_context(dw_ctx),.dw_owner(dw_owner),.dw_epoch(dw_epoch),.dw_last(dw_last),.done(),.error(dw_err),.input_read_count(dw_inputs),.padding_tap_count(),.dw_mac_count(dw_mac_count),.context_peak());
    ds12_stream_ds1_pw_consumer pw_ep (
      .clk(clk),.rst_n(rst_n),.start((state==DW_LAUNCH)||(state==LAUNCH)),.ready(pw_ready),.cfg_req_valid(pw_req_v),.cfg_req_ready(pw_cfg_ready),.cfg_req_addr(pw_cfg_addr),.cfg_req_index(pw_cfg_idx),.cfg_req_kind(pw_cfg_kind),.cfg_req_last(pw_cfg_last),.cfg_resp_valid(pw_resp_v),.cfg_resp_ready(pw_cfg_resp_ready),.cfg_resp_data(pw_cfg_r),.dw_valid(dw_valid),.dw_ready(pw_dw_ready),.dw_data(dw_data),.dw_row(dw_row),.dw_pixel(dw_pixel),.dw_context(dw_ctx),.dw_owner(dw_owner),.dw_epoch(dw_epoch),.dw_last(dw_last),.sink_valid(sink_v),.sink_ready(activation_write_ready),.sink_addr(sink_addr),.sink_data(sink_data),.sink_strb(sink_be),.sink_row(),.sink_pixel(),.sink_word_in_pixel(),.sink_context(),.sink_owner(),.sink_epoch(),.sink_last(sink_last),.busy(),.done(pw_done),.error(pw_err),.cfg_read_count(),.cfg_weight_read_count(),.dw_vector_count(pw_vectors),.pw_token_count(pw_tokens),.pw_mac_count(pw_macs),.output_word_count(pw_outputs),.partial_context_peak());
    assign activation_start_valid = (state==OPEN);
    assign activation_write_valid = sink_v;
    assign activation_write_addr = sink_addr-SINK_BASE; assign activation_write_data=sink_data;
    assign activation_write_be=sink_be; assign activation_write_last=sink_last;
    assign activation_write_bank=1'b1; assign activation_write_epoch=32'd1;
    assign activation_write_count = pw_outputs << 2;
    assign activation_write_drain = (state==DRAIN);
    assign activation_commit_req = (state==COMMIT);
    assign activation_owner = 2'd1; assign activation_epoch=32'd1;
    assign config_read_count=cfg_reads; assign config_write_count=cfg_writes;
    assign output_word_count=pw_outputs; assign pw_mac_count=pw_macs;
    assign ds1_input_read_count=dw_inputs; assign ds1_dw_vector_count=pw_vectors;
    always @(posedge clk) begin
      if(!rst_n) begin state<=IDLE;dw_i<=0;pw_i<=0;dw_cfg_v<=0;pw_resp_v<=0;cfg_reads<=0;cfg_writes<=0;drain<=0;layer_done<=0;error<=0;ds1_config_done<=0;ds2_preload_done<=0;cycle_count<=0;dw_first_cycle<=0;dw_last_cycle<=0;pw_first_cycle<=0;pw_last_cycle<=0;overlap_cycles<=0;dw_idle_cycles<=0;pw_idle_cycles<=0;token_prev<=0;dw_seen<=0;pw_seen<=0; end
      else begin
        if(cfg_error||dw_err||pw_err) error<=1'b1;
        if(cfg_load_done && state==C1_WAIT) ds1_config_done<=1'b1;
        if(ds2_prefetch_done) ds2_preload_done<=1'b1;
        if(state!=IDLE && state!=DONE) cycle_count<=cycle_count+1'b1;
        token_prev<=pw_tokens;
        case(state)
          IDLE: if(start) state<=C1_REQ;
          C1_REQ: if(cfg_load_req_ready) state<=C1_WAIT;
          C1_WAIT: if(cfg_load_done) begin ds1_config_done<=1; dw_i<=0; state<=DW_REQ; end
          DW_REQ: if(cfg_active_rd_ready) state<=DW_WAIT;
          DW_WAIT: if(cfg_active_rd_resp_valid) begin dw_cfg_r<=cfg_active_rd_resp_data;dw_cfg_v<=1;state<=DW_SEND; end
          DW_SEND: if(dw_cfg_v&&dw_cfg_ready) begin dw_cfg_v<=0;cfg_reads<=cfg_reads+1;cfg_writes<=cfg_writes+1;if(dw_i==83) begin pw_i<=0;state<=DW_LAUNCH;end else begin dw_i<=dw_i+1;state<=DW_REQ;end end
          DW_LAUNCH: state<=PW_CFG;
          PW_CFG: if(pw_req_v&&pw_cfg_ready&&cfg_active_rd_ready) state<=PW_WAIT;
          PW_WAIT: if(cfg_active_rd_resp_valid) begin pw_cfg_r<=cfg_active_rd_resp_data;pw_resp_v<=1;state<=PW_SEND;end
          PW_SEND: if(pw_resp_v&&pw_cfg_resp_ready) begin pw_resp_v<=0;cfg_reads<=cfg_reads+1;cfg_writes<=cfg_writes+1;if(pw_i==223) state<=OPEN;else begin pw_i<=pw_i+1;state<=PW_CFG;end end
          OPEN: if(activation_start_ready&&pw_ready) state<=LAUNCH;
          LAUNCH: state<=D2_REQ;
          D2_REQ: if(cfg_load_req_ready&&ds2_prefetch_req_ready) state<=RUN;
          RUN: begin if(dw_fire) begin if(!dw_seen) begin dw_seen<=1;dw_first_cycle<=cycle_count;end dw_last_cycle<=cycle_count;end if(pw_activity) begin if(!pw_seen) begin pw_seen<=1;pw_first_cycle<=cycle_count;end pw_last_cycle<=cycle_count;end if(dw_fire&&pw_activity) overlap_cycles<=overlap_cycles+1; if(pw_activity&&!dw_fire) dw_idle_cycles<=dw_idle_cycles+1; if(dw_fire&&!pw_activity) pw_idle_cycles<=pw_idle_cycles+1; if(pw_done&&ds2_prefetch_done) begin drain<=0;state<=DRAIN;end end
          DRAIN: if(drain==2) state<=COMMIT; else drain<=drain+1;
          COMMIT: if(activation_commit_ack) state<=DONE;
          DONE: layer_done<=1;
          default: state<=IDLE;
        endcase
      end
    end
endmodule
`default_nettype wire
