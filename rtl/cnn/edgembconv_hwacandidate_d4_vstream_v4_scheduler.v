`timescale 1ns/1ps
`default_nettype none

/*
 * D4 vstream v3 scheduler.
 *
 * The scheduler is deliberately a small control-plane experiment around the
 * already characterized 112-PW island, 16-DSP elastic shared pool and DW16
 * source contract.  Two context slots hold one complete 128-lane PW psum and
 * its tags.  During a context's shared-pool RQ burst, the dedicated PW island
 * is allowed to produce the following context.  A two-entry DW raw capture
 * FIFO is also live while expansion RQ is being serviced.  All arithmetic
 * inputs and all writeback tags remain transaction-local; no result depends on
 * an assumed fixed RQ latency.
 *
 * This module intentionally keeps the project phase conservative (one tile at
 * a time) until the expand/DW overlap is characterized.  It is a candidate,
 * not a production-runner replacement.
 */
module edgembconv_hwacandidate_d4_vstream_v4_scheduler #(
    parameter integer INPUT_BYTES=32*32*16,
    parameter integer EXP_BYTES=32*32*32,
    parameter integer DW_OUT_BYTES=16*16*32,
    parameter integer OUTPUT_BYTES=16*16*32,
    parameter integer PW_WEIGHT_BYTES=4096,
    parameter integer DW_WEIGHT_BYTES=288,
    parameter integer CFG_ADDR_WIDTH=16
) (
    input wire clk,input wire rst_n,
    input wire cfg_valid,output wire cfg_ready,input wire [2:0] cfg_kind,
    input wire [CFG_ADDR_WIDTH-1:0] cfg_addr,input wire [31:0] cfg_data,
    input wire start_valid,output wire start_ready,input wire [3:0] start_epoch,
    output reg done_valid,input wire done_ready,output reg [3:0] done_epoch,
    output wire out_valid,input wire out_ready,output wire [15:0] out_index,
    output wire signed [7:0] out_data,output wire busy,
    output wire [1:0] scratch0_state,output wire [1:0] scratch1_state,
    output wire [3:0] active_epoch,
    output reg [31:0] cycle_count,output reg [31:0] pw_mac_count,
    output reg [31:0] dw_mac_count,output reg [31:0] overlap_cycles,
    output reg [31:0] protocol_errors,input wire scratch_read_ready
);
 localparam [2:0] CFG_INPUT=0,CFG_PW_WEIGHT=1,CFG_DW_WEIGHT=2,CFG_BIAS=3,CFG_MULT=4,CFG_SHIFT=5;
 localparam [1:0] FREE=0,FILL=1,READY=2,ACTIVE=3;
 localparam [5:0] S_IDLE=0,S_DW_CFG=1,S_E_BOTH=2,S_E_WAIT=3,S_E_RQ=4,S_E_POOL=5,
                  S_DW_RQ=6,S_DW_WAIT=7,S_P_BOTH=8,S_P_WAIT=9,S_P_RQ=10,
                  S_OUTPUT=11,S_DONE=12;
 localparam integer DW_TILE_W=8, DW_TILE_H=8, DW_TILE_PIXELS=64, DW_FIFO_DEPTH=64;

 (* ram_style="block" *) reg signed [7:0] input_mem[0:INPUT_BYTES-1];
 (* ram_style="block" *) reg signed [7:0] scratch0[0:EXP_BYTES-1];
 (* ram_style="block" *) reg signed [7:0] scratch1[0:DW_OUT_BYTES-1];
 (* ram_style="block" *) reg signed [7:0] output_mem[0:OUTPUT_BYTES-1];
 reg signed [7:0] pw_weight_mem[0:PW_WEIGHT_BYTES-1];
 reg signed [7:0] dw_weight_mem[0:DW_WEIGHT_BYTES-1];
 reg signed [31:0] bias_mem[0:191]; reg signed [31:0] multiplier_mem[0:191]; reg [7:0] shift_mem[0:191];
 reg [5:0] state; reg [3:0] epoch_reg; reg [1:0] bank0_state_reg,bank1_state_reg;
 reg [15:0] output_cursor;

 /* Two-entry PW context ping-pong.  Lanes are stored separately so RQ reads
  * select only four 32-bit words, not a 3584-bit dynamic bus. */
 reg signed [31:0] ctx_raw0[0:127],ctx_raw1[0:127];
 reg signed [3583:0] ctx_bus0,ctx_bus1;
 reg ctx_ded_ready0,ctx_ded_ready1,ctx_pool_ready0,ctx_pool_ready1;
 reg [5:0] ctx_y0,ctx_y1,ctx_x0,ctx_x1; reg ctx_group0,ctx_group1;
 reg ctx_slot_rq;

 reg [5:0] e_y,e_x; reg e_group; reg [8:0] e_done_tiles;
 reg [5:0] next_y,next_x,ded_y,ded_x; reg next_group,ded_group;
 reg [5:0] p_y,p_x; reg p_group;
 reg [5:0] pw_k; reg pw_project,pw_slot;
 reg ded_active,ded_slot,ded_raw_phase; reg pool_pw_active,pool_pw_slot; reg [5:0] pool_pw_k;
 reg [7:0] rq_base; reg rq_active;

 /* DW source/capture path. */
 reg dw_active; reg [4:0] dw_job_y,dw_job_x; reg dw_job_group; reg [9:0] dw_jobs_started,dw_jobs_done;
 reg [31:0] dw_fifo_raw[0:DW_FIFO_DEPTH-1][0:15];
 reg [4:0] dw_fifo_y[0:DW_FIFO_DEPTH-1],dw_fifo_x[0:DW_FIFO_DEPTH-1];
 reg dw_fifo_group[0:DW_FIFO_DEPTH-1];
 reg [6:0] dw_fifo_count; reg [5:0] dw_fifo_head,dw_fifo_tail; reg [1:0] dw_rq_base;
 reg [7:0] dw_cfg_idx; reg dw_cfg_group,dw_run_group;
 reg dw_req_pending; reg [31:0] dw_req_addr_reg;
 reg [31:0] dw_req_count,dw_resp_count,dw_config_count,dw_start_count,rq_accept_count;
 reg [31:0] source_stall_count,bank_conflict_count,final_commit_count;
 reg [31:0] pw_rq_overlap_count,dw_rq_overlap_count;
 reg [8:0] expand_written_tiles;

 /* Persistent v4 A/B diagnostics.  These counters are intentionally
  * aggregate-only: they quantify pool service, mode fences, context waits,
  * and state occupancy without perturbing the datapath or printing traces. */
 reg [31:0] diag_pool_pw_accept_count,diag_pool_rq_accept_count;
 reg [31:0] diag_pool_busy_cycles,diag_pool_idle_cycles;
 reg [31:0] diag_pool_turnaround_cycles,diag_pool_mode_switch_count;
 reg [31:0] diag_pool_pw_output_count,diag_pool_rq_output_count;
 reg [31:0] diag_context_wait_cycles,diag_e_wait_cycles,diag_e_pool_cycles,diag_p_wait_cycles;
 reg [31:0] diag_ded_normal_accept_count,diag_ded_raw_accept_count;
 reg [31:0] diag_state_cycles[0:12];
 reg diag_pool_prev_mode,diag_pool_prev_valid;

 /* A DW output (y,x) consumes the 3x3 source window beginning at (2*y,2*x).
  * Expansion is emitted in row-major 8-pixel tiles, with two channel groups
  * per tile.  Do not launch a capture until the last required source tile is
  * committed; this is the dependency fence that makes the asynchronous DW
  * capture FIFO numerically safe while later expansion tiles are still being
  * produced. */
  function integer dw_expand_fence;
    input integer command;
    integer jy,jx,tx,cmd_y,cmd_x;
    begin
      /* Fence against the bottom-right pixel of each 8x8 DW command. */
      cmd_y=command/2; cmd_x=command%2;
      jy=cmd_y*DW_TILE_H+(DW_TILE_H-1);
      jx=cmd_x*DW_TILE_W+(DW_TILE_W-1); tx=jx/4;
      dw_expand_fence=((2*jy)+2)*8+(tx*2)+2;
      /* The terminal expansion tile transitions directly to DW_WAIT instead
       * of incrementing the saturating completion counter, so 255 denotes
       * the fully committed 256-tile frame. */
      if (dw_expand_fence > 255) dw_expand_fence=255;
    end
  endfunction
  wire dw_launch_dependency_ready =
      (dw_run_group==1'b1) ||
      (e_done_tiles >= dw_expand_fence(dw_jobs_started/DW_TILE_PIXELS));

 integer i,cap_i,q,pw_q,rq_q,src_q,idx,ky,kx,kg,flat,rq_flat,param_idx,src_idx;
 reg signed [55:0] pw_act7; reg [127:0] pw_act_pool,pw_wgt,pool_wgt; reg [7:0] pw_pix_mask; reg [15:0] pw_cout_mask;
 reg pw_first,pw_last; reg [7:0] pw_k_idx; reg [31:0] pw_metadata,pool_pw_metadata;
 reg signed [127:0] rq_acc,rq_mult; reg [23:0] rq_shift; reg signed [127:0] rq_zp,rq_min,rq_max; reg [31:0] rq_metadata;
 wire pw112_ready,pw112_valid; wire signed [3583:0] pw112_psum; wire [111:0] pw112_mask;
 wire pool_ready,pool_valid,pool_mode_out; wire [255:0] pool_pw_product; wire signed [31:0] pool_rq_result; wire [31:0] pool_metadata;
 wire signed [255:0] pool_rq_product;
 wire pool_valid_in,pool_mode_rq;
 wire [127:0] pool_pw_act,pool_pw_wgt;
 wire rq_fire=pool_valid_in&&pool_ready&&pool_mode_rq;

 /* DW primitive signals. */
 reg dw_cfg_valid; wire dw_cfg_ready; reg [7:0] dw_cfg_addr; reg [31:0] dw_cfg_data;
 reg dw_start_valid; wire dw_start_ready; wire dw_src_req_valid; reg dw_src_req_ready; wire [31:0] dw_src_req_addr;
 reg dw_src_resp_valid; wire dw_src_resp_ready; reg [127:0] dw_src_resp_data;
 wire dw_out_valid,dw_out_last; wire [7:0] dw_out_pixel_idx;
 wire signed [511:0] dw_raw_psum;

 assign cfg_ready=rst_n&&(state==S_IDLE)&&!done_valid; assign start_ready=cfg_ready;
 assign busy=(state!=S_IDLE)&&(state!=S_DONE); assign scratch0_state=bank0_state_reg; assign scratch1_state=bank1_state_reg;
 assign active_epoch=epoch_reg; assign out_valid=(state==S_OUTPUT); assign out_index=output_cursor; assign out_data=output_mem[output_cursor];
 wire cfg_fire=cfg_valid&&cfg_ready,start_fire=start_valid&&start_ready;

 edgembconv_hwacandidate_d4_vstream_v2_pw112 u_pw112(
   .clk(clk),.rst_n(rst_n),.valid_in(ded_active&&pw112_ready),.ready_in(pw112_ready),
   .first_k(pw_first),.last_k(pw_last),.k_idx(pw_k_idx),.pixel_mask(pw_pix_mask[6:0]),.cout_mask(pw_cout_mask),
   .act_vec(pw_act7),.wgt_vec(pw_wgt),.ready_out(1'b1),.valid_out(pw112_valid),.psum_out(pw112_psum),.lane_mask_out(pw112_mask));

 /* Shared pool is in RQ mode only when the scheduler presents RQ input.  Its
  * mode fence is therefore authoritative for every context transition. */
 assign pool_mode_rq = rq_active;
 wire pool_pw_offer = 1'b0;
 wire rq_offer = rq_active && ((state==S_DW_RQ) ? (rq_base<=12) : (rq_base<=124));
 assign pool_valid_in = rq_offer;
 assign pool_pw_act = pw_act_pool; assign pool_pw_wgt = pool_wgt;
 edgembconv_hwacandidate_d4_vstream_elastic_rq_pool u_pool(
   .clk(clk),.rst_n(rst_n),.mode_rq(pool_mode_rq),.valid_in(pool_valid_in),.ready_in(pool_ready),
   .rq_acc_vec(rq_acc),.rq_multiplier_vec(rq_mult),.rq_shift_vec(rq_shift),.rq_zero_point_vec(rq_zp),
   .rq_min_vec(rq_min),.rq_max_vec(rq_max),.pw_act_vec(pool_pw_act),.pw_wgt_vec(pool_pw_wgt),.metadata_in(rq_active?rq_metadata:pool_pw_metadata),
   .valid_out(pool_valid),.ready_out(1'b1),.mode_rq_out(pool_mode_out),.pw_product_vec(pool_pw_product),
   .rq_product_vec(pool_rq_product),.rq_result_vec(pool_rq_result),.metadata_out(pool_metadata));

 edgembconv_hwacandidate_d4_dw16_stream_tile u_dw(
   .clk(clk),.rst_n(rst_n),.cfg_valid(dw_cfg_valid),.cfg_ready(dw_cfg_ready),.cfg_kind(0),.cfg_addr(dw_cfg_addr),.cfg_data(dw_cfg_data),
   .start_valid(dw_start_valid),.start_ready(dw_start_ready),.start_in_w(32),.start_in_h(32),.start_out_w(16),.start_out_h(16),.start_stride(2),
   .start_tile_x({3'd0,dw_job_x}),.start_tile_y({3'd0,dw_job_y}),.start_tile_w(DW_TILE_W),.start_tile_h(DW_TILE_H),.start_channel_base(dw_job_group?16:0),.start_channel_mask(16'hffff),
   .start_padding_value(0),.start_output_zero_point(0),.start_activation_min(-2147483647),.start_activation_max(2147483647),.start_epoch(epoch_reg),.start_metadata({dw_job_group,dw_job_y,dw_job_x}),
   .src_req_valid(dw_src_req_valid),.src_req_ready(dw_src_req_ready),.src_req_addr(dw_src_req_addr),.src_req_pixel_idx(),.src_req_tap_idx(),.src_req_first_tap(),.src_req_last_tap(),.src_req_metadata(),
   .src_resp_valid(dw_src_resp_valid),.src_resp_ready(dw_src_resp_ready),.src_resp_data(dw_src_resp_data),.out_ready(dw_fifo_count<DW_FIFO_DEPTH),.out_valid(dw_out_valid),.out_data_vec(),.out_raw_psum_vec(dw_raw_psum),.out_pixel_idx(dw_out_pixel_idx),.out_channel_base(),.out_lane_mask(),.out_first(),.out_last(dw_out_last),.out_metadata(),.done_valid(),.done_ready(1),.done_epoch(),.busy(),.cycle_count(),.tap_count(),.source_word_count(),.source_stall_count(),.output_stall_count(),.protocol_errors());

 assign dw_cfg_valid=(state==S_DW_CFG); assign dw_cfg_addr=dw_cfg_idx; assign dw_cfg_data=dw_weight_mem[(dw_cfg_group?144:0)+dw_cfg_idx];
 assign dw_start_valid=dw_active && !dw_req_pending && (dw_fifo_count<DW_FIFO_DEPTH);
 /* Source is a one-cycle registered read service. */
 always @* begin
   dw_src_req_ready=scratch_read_ready && dw_active && !dw_req_pending && (dw_fifo_count<DW_FIFO_DEPTH) && !dw_start_ready;
   dw_src_resp_valid=dw_req_pending;
   dw_src_resp_data=128'd0;
   src_idx=dw_req_pending ? dw_req_addr_reg*32+(dw_job_group?16:0) : 0;
   for(src_q=0;src_q<16;src_q=src_q+1) dw_src_resp_data[src_q*8 +:8]=scratch0[src_idx+src_q];
 end

 /* Current PW operands.  One horizontal 8-pixel tile is explicit; y/x/group
  * counters advance without an inferred divide/modulo datapath. */
 always @* begin
   pw_act7=0;pw_act_pool=0;pw_wgt=0;pool_wgt=0;pw_pix_mask=ded_raw_phase?8'h01:8'h7f;pw_cout_mask=16'hffff;pw_first=(pw_k==0);
   pw_last=pw_project?(pw_k==31):(pw_k==15);pw_k_idx=pw_k;pw_metadata={pw_project,pw_project?p_y:ded_y,pw_project?p_x:ded_x,pw_project?1'b0:ded_group,pw_k};
   pool_pw_metadata={pw_project,pw_project?p_y:(pool_pw_slot?ctx_y1:ctx_y0),pw_project?p_x:(pool_pw_slot?ctx_x1:ctx_x0),pw_project?p_group:(pool_pw_slot?ctx_group1:ctx_group0),pool_pw_k};
   ky=pw_project?p_y:ded_y;kx=pw_project?p_x:ded_x;kg=pw_project?p_group:ded_group;
   if(ded_active||pool_pw_active) begin
     for(pw_q=0;pw_q<7;pw_q=pw_q+1) pw_act7[pw_q*8 +:8]=pw_project?scratch1[(ky*16+kx+(ded_raw_phase?7:pw_q))*32+pw_k]:input_mem[(ky*32+kx+(ded_raw_phase?7:pw_q))*16+pw_k];
     for(pw_q=0;pw_q<16;pw_q=pw_q+1) begin
       if(pw_project) pw_act_pool[pw_q*8 +:8]=scratch1[(p_y*16+p_x+7)*32+pool_pw_k];
       else pw_act_pool[pw_q*8 +:8]=input_mem[((pool_pw_slot?ctx_y1:ctx_y0)*32+(pool_pw_slot?ctx_x1:ctx_x0)+7)*16+pool_pw_k];
     end
     for(pw_q=0;pw_q<16;pw_q=pw_q+1) begin
       idx=(pw_project?3072:2048)+kg*16*(pw_project?32:16)+pw_k+pw_q*(pw_project?32:16);pw_wgt[pw_q*8 +:8]=pw_weight_mem[idx];
       idx=(pw_project?3072:2048)+(pw_project?p_group:(pool_pw_slot?ctx_group1:ctx_group0))*16*(pw_project?32:16)+pool_pw_k+pw_q*(pw_project?32:16);pool_wgt[pw_q*8 +:8]=pw_weight_mem[idx];
     end
   end
 end

 /* RQ reads exactly four lane contexts. */
 always @* begin
   rq_acc=0;rq_mult=0;rq_shift=0;rq_zp=0;rq_min=0;rq_max=0;rq_metadata=0;
   if(rq_active) begin
       if(state==S_DW_RQ)
         rq_metadata={dw_fifo_group[dw_fifo_head],dw_fifo_y[dw_fifo_head],dw_fifo_x[dw_fifo_head],rq_base};
       else
         rq_metadata={pw_project?1'b1:1'b0,pw_project?p_y:(ctx_slot_rq?ctx_y1:ctx_y0),pw_project?p_x:(ctx_slot_rq?ctx_x1:ctx_x0),pw_project?p_group:(ctx_slot_rq?ctx_group1:ctx_group0),rq_base};
       for(rq_q=0;rq_q<4;rq_q=rq_q+1) begin
       rq_flat=rq_base+rq_q;
       if(state==S_DW_RQ) begin param_idx=160+(dw_fifo_group[dw_fifo_head]?16:0)+(rq_flat%16);rq_acc[rq_q*32 +:32]=dw_fifo_raw[dw_fifo_head][rq_flat%16];rq_min[rq_q*32 +:32]=0;rq_max[rq_q*32 +:32]=127;end
       else begin param_idx=(pw_project?96:64)+(pw_project?(p_group?16:0):(ctx_slot_rq?(ctx_group1?16:0):(ctx_group0?16:0)))+(rq_flat%16);if(rq_flat<112) begin if(ctx_slot_rq) rq_acc[rq_q*32 +:32]=ctx_bus1[rq_flat*32 +:32]; else rq_acc[rq_q*32 +:32]=ctx_bus0[rq_flat*32 +:32];end else begin if(ctx_slot_rq) rq_acc[rq_q*32 +:32]=ctx_raw1[rq_flat]; else rq_acc[rq_q*32 +:32]=ctx_raw0[rq_flat];end rq_min[rq_q*32 +:32]=pw_project?-128:0;rq_max[rq_q*32 +:32]=127;end
       rq_acc[rq_q*32 +:32]=rq_acc[rq_q*32 +:32]+bias_mem[param_idx];rq_mult[rq_q*32 +:32]=multiplier_mem[param_idx];rq_shift[rq_q*6 +:6]=shift_mem[param_idx][5:0];
       end
   end
 end

 wire context_rq_ready=(ctx_slot_rq?ctx_ded_ready1&&ctx_pool_ready1:ctx_ded_ready0&&ctx_pool_ready0);
 wire ded_fire=ded_active&&pw112_ready;
 /* The PW island has one cycle of output latency.  Stop offering a new
  * token on the edge that accepts the last K value; otherwise the island's
  * ready signal reopens while the last result is being captured and a stale
  * extra token is issued into the following scheduler state. */
 wire ded_last_fire=ded_fire && (pw_k==(pw_project?6'd31:6'd15));
 wire pool_pw_fire=pool_pw_offer&&pool_ready&&!pool_mode_rq;
 wire pool_rq_fire=rq_offer&&pool_ready;
 wire pw_and_rq_active=(ded_active&&rq_active)||(pool_pw_active&&rq_active);
 wire dw_fifo_push=dw_active&&dw_out_valid&&(dw_fifo_count<DW_FIFO_DEPTH);
 wire dw_fifo_pop=(state==S_DW_RQ)&&pool_valid&&pool_mode_out&&(pool_metadata[7:0]==8'd12);
 wire diag_pool_scope=(state==S_E_BOTH)||(state==S_E_RQ)||(state==S_E_POOL)||
                      (state==S_DW_RQ)||(state==S_P_BOTH)||(state==S_P_WAIT)||
                      (state==S_P_RQ);
 wire diag_pool_input_fire=pool_pw_fire||pool_rq_fire;

 always @(posedge clk) begin
   if(!rst_n) begin
     state<=S_IDLE;done_valid<=0;done_epoch<=0;epoch_reg<=0;bank0_state_reg<=FREE;bank1_state_reg<=FREE;output_cursor<=0;
     cycle_count<=0;pw_mac_count<=0;dw_mac_count<=0;overlap_cycles<=0;protocol_errors<=0;pw_project<=0;pw_slot<=0;pw_k<=0;ded_active<=0;ded_slot<=0;ded_raw_phase<=0;pool_pw_active<=0;pool_pw_slot<=0;pool_pw_k<=0;rq_active<=0;rq_base<=0;ctx_slot_rq<=0;
     e_y<=0;e_x<=0;e_group<=0;next_y<=0;next_x<=8;next_group<=0;ded_y<=0;ded_x<=0;ded_group<=0;ctx_bus0<=0;ctx_bus1<=0;e_done_tiles<=0;expand_written_tiles<=0;ctx_ded_ready0<=0;ctx_ded_ready1<=0;ctx_pool_ready0<=0;ctx_pool_ready1<=0;
     p_y<=0;p_x<=0;p_group<=0;dw_active<=0;dw_jobs_started<=0;dw_jobs_done<=0;dw_fifo_count<=0;dw_fifo_head<=0;dw_fifo_tail<=0;dw_rq_base<=0;dw_job_y<=0;dw_job_x<=0;dw_job_group<=0;
     dw_req_count<=0;dw_resp_count<=0;dw_config_count<=0;dw_start_count<=0;rq_accept_count<=0;source_stall_count<=0;bank_conflict_count<=0;final_commit_count<=0;pw_rq_overlap_count<=0;dw_rq_overlap_count<=0;dw_cfg_idx<=0;dw_cfg_group<=0;dw_run_group<=0;dw_req_pending<=0;dw_req_addr_reg<=0;
     diag_pool_pw_accept_count<=0;diag_pool_rq_accept_count<=0;diag_pool_busy_cycles<=0;diag_pool_idle_cycles<=0;diag_pool_turnaround_cycles<=0;diag_pool_mode_switch_count<=0;diag_pool_pw_output_count<=0;diag_pool_rq_output_count<=0;diag_context_wait_cycles<=0;diag_e_wait_cycles<=0;diag_e_pool_cycles<=0;diag_p_wait_cycles<=0;diag_ded_normal_accept_count<=0;diag_ded_raw_accept_count<=0;diag_pool_prev_mode<=0;diag_pool_prev_valid<=0;
     for(i=0;i<13;i=i+1) diag_state_cycles[i]<=0;
   end else begin
     if(busy) cycle_count<=cycle_count+1'b1;
     if(busy && (state<=S_DONE)) diag_state_cycles[state]<=diag_state_cycles[state]+1'b1;
     if(diag_pool_scope) begin
       if(diag_pool_input_fire) diag_pool_busy_cycles<=diag_pool_busy_cycles+1'b1;
       else diag_pool_idle_cycles<=diag_pool_idle_cycles+1'b1;
     end
     if(pool_pw_fire) diag_pool_pw_accept_count<=diag_pool_pw_accept_count+1'b1;
     if(pool_rq_fire) diag_pool_rq_accept_count<=diag_pool_rq_accept_count+1'b1;
     if(pool_valid && pool_mode_out) diag_pool_rq_output_count<=diag_pool_rq_output_count+1'b1;
     if(pool_valid && !pool_mode_out) diag_pool_pw_output_count<=diag_pool_pw_output_count+1'b1;
     if(pool_valid_in && !pool_ready && diag_pool_prev_valid && (pool_mode_rq!=diag_pool_prev_mode)) diag_pool_turnaround_cycles<=diag_pool_turnaround_cycles+1'b1;
     if(diag_pool_input_fire && (!diag_pool_prev_valid || (pool_mode_rq!=diag_pool_prev_mode))) diag_pool_mode_switch_count<=diag_pool_mode_switch_count+1'b1;
     if(diag_pool_input_fire) begin diag_pool_prev_mode<=pool_mode_rq;diag_pool_prev_valid<=1'b1;end
     if(state==S_E_WAIT || state==S_E_POOL || state==S_P_WAIT) diag_context_wait_cycles<=diag_context_wait_cycles+1'b1;
     if(state==S_E_WAIT) diag_e_wait_cycles<=diag_e_wait_cycles+1'b1;
     if(state==S_E_POOL) diag_e_pool_cycles<=diag_e_pool_cycles+1'b1;
     if(state==S_P_WAIT) diag_p_wait_cycles<=diag_p_wait_cycles+1'b1;
     if(pw_and_rq_active) begin overlap_cycles<=overlap_cycles+1'b1;pw_rq_overlap_count<=pw_rq_overlap_count+1'b1;end
     if(dw_active&&rq_active) dw_rq_overlap_count<=dw_rq_overlap_count+1'b1;
     if(dw_src_req_valid&&!dw_src_req_ready) source_stall_count<=source_stall_count+1'b1;
     done_valid<=0;
     if(cfg_fire) case(cfg_kind)
       CFG_INPUT: if(cfg_addr<INPUT_BYTES) input_mem[cfg_addr]<=cfg_data[7:0];
       CFG_PW_WEIGHT: if(cfg_addr<PW_WEIGHT_BYTES) pw_weight_mem[cfg_addr]<=cfg_data[7:0];
       CFG_DW_WEIGHT: if(cfg_addr<DW_WEIGHT_BYTES) dw_weight_mem[cfg_addr]<=cfg_data[7:0];
       CFG_BIAS: if(cfg_addr<192) bias_mem[cfg_addr]<=cfg_data;
       CFG_MULT: if(cfg_addr<192) multiplier_mem[cfg_addr]<=cfg_data;
       CFG_SHIFT: if(cfg_addr<192) shift_mem[cfg_addr]<=cfg_data[7:0];
       default: protocol_errors<=protocol_errors+1'b1;
     endcase
     if(dw_src_req_valid&&dw_src_req_ready) begin dw_req_pending<=1;dw_req_addr_reg<=dw_src_req_addr;dw_req_count<=dw_req_count+1;end
     if(dw_src_resp_valid&&dw_src_resp_ready) begin dw_req_pending<=0;dw_resp_count<=dw_resp_count+1;end
      if(pool_pw_fire) pool_pw_k<=pool_pw_k+1'b1;
      if(ded_fire) begin if(ded_raw_phase) diag_ded_raw_accept_count<=diag_ded_raw_accept_count+1'b1; else diag_ded_normal_accept_count<=diag_ded_normal_accept_count+1'b1;end
      if(dw_cfg_valid&&dw_cfg_ready) begin dw_config_count<=dw_config_count+1;if(dw_cfg_idx==143) begin dw_cfg_idx<=0;if(!dw_cfg_group) begin dw_cfg_group<=1;state<=S_E_BOTH;ded_active<=1;ded_raw_phase<=0;pool_pw_active<=0;pw_k<=0;pool_pw_k<=0;ded_y<=0;ded_x<=0;ded_group<=0;end else begin dw_run_group<=1;state<=S_DW_WAIT;end end else dw_cfg_idx<=dw_cfg_idx+1;end
     if(dw_start_valid&&dw_start_ready) dw_start_count<=dw_start_count+1;
       if(start_fire) begin state<=S_DW_CFG;epoch_reg<=start_epoch;done_epoch<=start_epoch;bank0_state_reg<=FILL;bank1_state_reg<=FREE;pw_project<=0;pw_slot<=0;pw_k<=0;ded_active<=0;ded_slot<=0;ded_raw_phase<=0;pool_pw_active<=0;pool_pw_slot<=0;pool_pw_k<=0;e_y<=0;e_x<=0;e_group<=0;next_y<=0;next_x<=8;next_group<=0;ded_y<=0;ded_x<=0;ded_group<=0;e_done_tiles<=0;ctx_y0<=0;ctx_x0<=0;ctx_group0<=0;ctx_y1<=0;ctx_x1<=8;ctx_group1<=0;ctx_ded_ready0<=0;ctx_pool_ready0<=0;ctx_pool_ready1<=0;ctx_ded_ready1<=0;rq_active<=0;dw_active<=0;dw_jobs_started<=0;dw_jobs_done<=0;dw_fifo_count<=0;dw_fifo_head<=0;dw_fifo_tail<=0;dw_cfg_idx<=0;dw_cfg_group<=0;dw_run_group<=0;end
     else begin
       /* Capture the last token even though ded_active is cleared on the
        * accepting edge above; this keeps the output token and context slot
        * aligned without reopening the input handshake. */
       if(pw112_valid) begin
         if(ded_raw_phase) begin
           for(i=0;i<16;i=i+1) begin
             if(ded_slot) ctx_raw1[112+i]<=pw112_psum[i*32 +:32];
             else ctx_raw0[112+i]<=pw112_psum[i*32 +:32];
           end
           if(ded_slot) ctx_pool_ready1<=1; else ctx_pool_ready0<=1;
           ded_raw_phase<=0;
           ded_active<=0;
         end else begin
           if(ded_slot) begin ctx_bus1<=pw112_psum;ctx_ded_ready1<=1;end
           else begin ctx_bus0<=pw112_psum;ctx_ded_ready0<=1; end
           /* Reuse the existing 112-DSP island for the eight-pixel tile's
            * final pixel.  The raw half is captured from lanes 0..15 on the
            * following pass, eliminating shared-pool PW traffic without
            * adding multipliers. */
           ded_raw_phase<=1;
           ded_active<=1;
           pw_k<=0;
         end
       end
       if(pool_valid&& !pool_mode_out && pool_pw_active) begin
         for(i=0;i<16;i=i+1) begin
           if(pool_metadata[5:0]==0) begin if(pool_pw_slot) ctx_raw1[112+i]<={{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]}; else ctx_raw0[112+i]<={{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]};end
           else begin if(pool_pw_slot) ctx_raw1[112+i]<=ctx_raw1[112+i]+$signed({{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]}); else ctx_raw0[112+i]<=ctx_raw0[112+i]+$signed({{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]});end
         end
         if(pool_metadata[5:0]== (pw_project?31:15)) begin if(pool_pw_slot) ctx_pool_ready1<=1; else ctx_pool_ready0<=1;pool_pw_active<=0;end
       end
       case(state)
         S_E_BOTH: begin
           ctx_y0<=0;ctx_x0<=0;ctx_group0<=0;
            if(ded_fire) begin pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112); if(ded_last_fire) begin ded_active<=0;pw_k<=0;state<=S_E_WAIT;end else pw_k<=pw_k+1'b1;end
          end
            S_E_WAIT: begin
              /* The normal seven-pixel pass changes state on the input edge
               * that accepts its final K value, but the PW island returns
               * that token one cycle later and only then arms the raw
               * eight-pixel pass.  Keep accepting that second pass here;
               * otherwise pw_k remains zero forever while the context waits
               * for ctx_pool_ready0. */
              if(ded_fire) begin
                pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);
                if(ded_last_fire) begin ded_active<=0;pw_k<=0;end
                else pw_k<=pw_k+1'b1;
              end
              if((ctx_ded_ready0)&&(ctx_pool_ready0)) begin ctx_slot_rq<=0;rq_base<=0;rq_active<=1;ded_slot<=1;ded_active<=1;ded_raw_phase<=0;pw_slot<=1;pw_k<=0;ded_y<=0;ded_x<=0;ded_group<=1;/* The first context in the second slot is the missing x=0/group1 tile; continue with x=8/group0. */next_y<=0;next_x<=8;next_group<=0;ctx_y1<=0;ctx_x1<=0;ctx_group1<=1;state<=S_E_RQ;end
            end
         S_E_RQ: begin
            if(ded_fire) begin pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);if(ded_last_fire) begin ded_active<=0;pw_k<=0;end else pw_k<=pw_k+1'b1;end
           if(pool_rq_fire) begin rq_accept_count<=rq_accept_count+1;rq_base<=rq_base+4;end
           if(pool_valid&&pool_mode_out) begin
             for(i=0;i<4;i=i+1) begin flat=pool_metadata[7:0]+i;idx=((ctx_slot_rq?ctx_y1:ctx_y0)*32+(ctx_slot_rq?ctx_x1:ctx_x0)+flat/16)*32+(ctx_slot_rq?ctx_group1:ctx_group0)*16+flat%16;scratch0[idx]<=pool_rq_result[i*8 +:8];end
             if(pool_metadata[7:0]==124) begin rq_active<=0;if(ctx_slot_rq) begin ctx_ded_ready1<=0;ctx_pool_ready1<=0;end else begin ctx_ded_ready0<=0;ctx_pool_ready0<=0;end
             if(e_done_tiles==255) begin state<=S_DW_WAIT;pw_project<=1;p_y<=0;p_x<=0;p_group<=0;end
                else begin pw_k<=0;state<=S_E_POOL;e_done_tiles<=e_done_tiles+1;ctx_slot_rq<=ctx_slot_rq;end
             end
           end
         end
         S_E_POOL: begin
            if(ded_fire) begin pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);if(ded_last_fire) begin ded_active<=0;pw_k<=0;end else pw_k<=pw_k+1'b1;end
           if(!pool_pw_active && !ded_active && (!ctx_slot_rq?ctx_ded_ready1:ctx_ded_ready0)) begin
             rq_active<=1;rq_base<=0;ctx_slot_rq<=!ctx_slot_rq;
             ded_slot<=ctx_slot_rq;pw_k<=0;
             /* The pool just consumed the inactive slot.  Refill that same
              * slot for the following RQ turn; the previous branch wrote the
              * slot being consumed and replayed x=0 every other tile. */
             if(ctx_slot_rq) begin ctx_y1<=next_y;ctx_x1<=next_x;ctx_group1<=next_group;end else begin ctx_y0<=next_y;ctx_x0<=next_x;ctx_group0<=next_group;end
             /* When the final context is about to enter RQ, both its
              * dedicated and pooled halves are already present.  Do not
              * advance next_* into a phantom y=32 tile. */
              if(e_done_tiles!=9'd255) begin
                ded_active<=1;
                ded_raw_phase<=0;
                ded_y<=next_y;ded_x<=next_x;ded_group<=next_group;
               if(next_group==1) begin next_group<=0;if(next_x==24) begin next_x<=0;next_y<=next_y+1;end else next_x<=next_x+8;end else next_group<=1;
             end else begin
               ded_active<=0;
             end
             state<=S_E_RQ;
           end
         end
         S_DW_WAIT: begin
           /* Expansion has fenced before DW RQ, but the DW source work above
            * was real and may already have filled the two-entry capture. */
           if(dw_fifo_count!=0) begin rq_active<=1;rq_base<=0;ctx_slot_rq<=0;state<=S_DW_RQ;end
           else if(!dw_active && dw_run_group==0 && dw_jobs_done==256) begin dw_cfg_idx<=0;dw_jobs_started<=0;state<=S_DW_CFG;end
            else if(!dw_active && dw_run_group==1 && dw_jobs_done==512) begin state<=S_P_BOTH;pw_project<=1;pw_k<=0;ded_active<=1;ded_raw_phase<=0;ded_slot<=0;pool_pw_active<=0;pool_pw_slot<=0;pool_pw_k<=0;ded_y<=0;ded_x<=0;ded_group<=0;end
         end
         S_DW_RQ: begin
           if(pool_rq_fire) begin rq_accept_count<=rq_accept_count+1;rq_base<=rq_base+4;end
           if(pool_valid&&pool_mode_out) begin
             for(i=0;i<4;i=i+1) begin idx=dw_fifo_y[dw_fifo_head]*16+dw_fifo_x[dw_fifo_head];scratch1[idx*32+dw_fifo_group[dw_fifo_head]*16+pool_metadata[7:0]+i]<=pool_rq_result[i*8 +:8];end
              if(pool_metadata[7:0]==12) begin rq_active<=0;dw_fifo_head<=dw_fifo_head+1;dw_jobs_done<=dw_jobs_done+1;if(dw_jobs_done==511) begin state<=S_P_BOTH;pw_project<=1;pw_k<=0;ded_active<=1;ded_raw_phase<=0;ded_slot<=0;pool_pw_active<=0;pool_pw_slot<=0;pool_pw_k<=0;ded_y<=0;ded_x<=0;ded_group<=0;end else if((dw_fifo_count>1)||dw_fifo_push) begin rq_active<=1;rq_base<=0;end else state<=S_DW_WAIT;end
           end
         end
         S_P_BOTH: begin
           ctx_y0<=p_y;ctx_x0<=p_x;ctx_group0<=p_group;ded_y<=p_y;ded_x<=p_x;ded_group<=p_group;ctx_ded_ready0<=0;ctx_pool_ready0<=0;
            if(ded_fire) begin pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);if(ded_last_fire) begin ded_active<=0;pw_k<=0;state<=S_P_WAIT;end else pw_k<=pw_k+1'b1;end
         end
         S_P_WAIT: begin
           /* As in S_E_WAIT, drain the raw eight-pixel pass after the normal
            * pass has moved the FSM into its context wait state. */
           if(ded_fire) begin
             pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);
             if(ded_last_fire) begin ded_active<=0;pw_k<=0;end
             else pw_k<=pw_k+1'b1;
           end
           if(ctx_ded_ready0&&ctx_pool_ready0) begin rq_active<=1;rq_base<=0;state<=S_P_RQ;end
         end
          S_P_RQ: begin
           if(pool_rq_fire) begin rq_accept_count<=rq_accept_count+1;rq_base<=rq_base+4;end
            if(pool_valid&&pool_mode_out) begin for(i=0;i<4;i=i+1) begin flat=pool_metadata[7:0]+i;idx=((p_y*16+p_x)+flat/16)*32+p_group*16+flat%16;output_mem[idx]<=pool_rq_result[i*8 +:8];final_commit_count<=final_commit_count+4;end if(pool_metadata[7:0]==124) begin rq_active<=0;ctx_ded_ready0<=0;ctx_pool_ready0<=0;if(p_group==0) begin p_group<=1;state<=S_P_BOTH;pw_k<=0;ded_active<=1;ded_raw_phase<=0;pool_pw_active<=0;pool_pw_k<=0;ded_y<=p_y;ded_x<=p_x;ded_group<=1;end else if(p_x==8) begin p_group<=0;p_x<=0;if(p_y==15) begin output_cursor<=0;state<=S_OUTPUT;end else begin p_y<=p_y+1;state<=S_P_BOTH;pw_k<=0;ded_active<=1;ded_raw_phase<=0;pool_pw_active<=0;pool_pw_k<=0;ded_y<=p_y+1;ded_x<=0;ded_group<=0;end end else begin p_x<=8;p_group<=0;state<=S_P_BOTH;pw_k<=0;ded_active<=1;ded_raw_phase<=0;pool_pw_active<=0;pool_pw_k<=0;ded_y<=p_y;ded_x<=8;ded_group<=0;end end end
         end
         S_OUTPUT: if(out_valid&&out_ready) begin if(output_cursor==OUTPUT_BYTES-1) begin done_valid<=1;state<=S_DONE;end else output_cursor<=output_cursor+1;end
         S_DONE: if(done_valid&&done_ready) begin done_valid<=0;bank0_state_reg<=FREE;bank1_state_reg<=FREE;state<=S_IDLE;end
         default: ;
       endcase
       /* Launch one 8x8 DW command at a time.  A command emits 64 output
        * vectors into the deep FIFO; its RQ traffic drains concurrently. */
       if((state==S_E_RQ||state==S_E_POOL) && !dw_active && dw_fifo_count<DW_FIFO_DEPTH && dw_jobs_started<256 && dw_launch_dependency_ready) begin dw_active<=1;dw_job_y<=((dw_jobs_started/DW_TILE_PIXELS)/2)*DW_TILE_H;dw_job_x<=(dw_jobs_started/DW_TILE_PIXELS%2)*DW_TILE_W;dw_job_group<=dw_run_group;dw_jobs_started<=dw_jobs_started+DW_TILE_PIXELS;end
       if((state==S_DW_RQ||state==S_DW_WAIT) && !dw_active && dw_fifo_count<DW_FIFO_DEPTH && dw_jobs_started<256 && dw_launch_dependency_ready) begin dw_active<=1;dw_job_y<=((dw_jobs_started/DW_TILE_PIXELS)/2)*DW_TILE_H;dw_job_x<=(dw_jobs_started/DW_TILE_PIXELS%2)*DW_TILE_W;dw_job_group<=dw_run_group;dw_jobs_started<=dw_jobs_started+DW_TILE_PIXELS;end
       if(dw_fifo_push) begin
         dw_mac_count<=dw_mac_count+144;
         for(i=0;i<16;i=i+1) dw_fifo_raw[dw_fifo_tail][i]<=dw_raw_psum[i*32 +:32];
         dw_fifo_y[dw_fifo_tail]<=dw_job_y+(dw_out_pixel_idx/DW_TILE_W);
         dw_fifo_x[dw_fifo_tail]<=dw_job_x+(dw_out_pixel_idx%DW_TILE_W);
         dw_fifo_group[dw_fifo_tail]<=dw_job_group;
         dw_fifo_tail<=dw_fifo_tail+1'b1;
         if(dw_out_last) dw_active<=0;
       end
       if(dw_fifo_push&&!dw_fifo_pop) dw_fifo_count<=dw_fifo_count+1'b1;
       else if(!dw_fifo_push&&dw_fifo_pop) dw_fifo_count<=dw_fifo_count-1'b1;
     end
   end
 end
endmodule
`default_nettype wire
