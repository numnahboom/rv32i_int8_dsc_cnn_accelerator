`timescale 1ns/1ps
`default_nettype none

/*
 * D4 vstream v5 scheduler.
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
module edgembconv_hwacandidate_d4_vstream_v5_scheduler #(
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
     output reg [31:0] protocol_errors,input wire scratch_read_ready,
     output wire word_out_valid,input wire word_out_ready,
     output wire [31:0] word_out_data,output wire [15:0] word_out_index,
     output wire [3:0] word_out_epoch
);
 localparam [2:0] CFG_INPUT=0,CFG_PW_WEIGHT=1,CFG_DW_WEIGHT=2,CFG_BIAS=3,CFG_MULT=4,CFG_SHIFT=5;
 localparam [1:0] FREE=0,FILL=1,READY=2,ACTIVE=3;
 localparam [5:0] S_IDLE=0,S_DW_CFG=1,S_E_BOTH=2,S_E_WAIT=3,S_E_RQ=4,S_E_POOL=5,
                  S_DW_RQ=6,S_DW_WAIT=7,S_P_BOTH=8,S_P_WAIT=9,S_P_RQ=10,
                  S_OUTPUT=11,S_DONE=12;
 localparam integer DW_TILE_W=8, DW_TILE_H=8, DW_TILE_PIXELS=64, DW_FIFO_DEPTH=64;

 (* ram_style="block" *) reg signed [7:0] input_mem[0:INPUT_BYTES-1];
 /* Expansion scratch is channel-bank mapped.  DW source reads consume all
  * sixteen channels of one expansion pixel at once, while the expansion RQ
  * writer emits four adjacent channels.  One 2K-deep bank per channel lane
  * gives Vivado one write and one read port per physical memory instead of a
  * 262,144-bit, 16-read-port monolithic RAM that cannot be inferred. */
 (* ram_style="block" *) reg signed [7:0] scratch0_bank[0:15][0:2047];
 /* DW scratch is written as aligned four-byte RQ words.  Keep seven
  * identical read copies: the project dedicated pass consumes seven
  * different spatial rows in one cycle, while each copy has only one
  * combinational read.  All copies receive the same single word write. */
 (* ram_style="block" *) reg signed [31:0] scratch1_word0[0:2047];
 (* ram_style="block" *) reg signed [31:0] scratch1_word1[0:2047];
 (* ram_style="block" *) reg signed [31:0] scratch1_word2[0:2047];
 (* ram_style="block" *) reg signed [31:0] scratch1_word3[0:2047];
 (* ram_style="block" *) reg signed [31:0] scratch1_word4[0:2047];
 (* ram_style="block" *) reg signed [31:0] scratch1_word5[0:2047];
 (* ram_style="block" *) reg signed [31:0] scratch1_word6[0:2047];
 (* ram_style="block" *) reg signed [7:0] output_mem[0:OUTPUT_BYTES-1];
 reg signed [7:0] pw_weight_mem[0:PW_WEIGHT_BYTES-1];
 reg signed [7:0] dw_weight_mem[0:DW_WEIGHT_BYTES-1];
 reg signed [31:0] bias_mem[0:191]; reg signed [31:0] multiplier_mem[0:191]; reg [7:0] shift_mem[0:191];
 reg [5:0] state; reg [3:0] epoch_reg; reg [1:0] bank0_state_reg,bank1_state_reg;
 reg [15:0] output_cursor;

 /* The project RQ stream is already four adjacent output channels wide.
  * Capture each result directly as one sink word in a pair of 256-byte
  * (64-word) context banks.  A bank is published only after both channel
  * groups have filled all 64 word slots; the other bank may then drain in
  * local index order while the next project context is computed. */
 reg [31:0] word_bank0[0:63],word_bank1[0:63];
 reg word_bank_valid0,word_bank_valid1,word_write_slot,word_drain_slot;
 reg [5:0] word_drain_index;
 reg [11:0] word_global_index;
 reg p_bank_wait;

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
 reg [5:0] p_next_y,p_next_x; reg p_next_group,p_next_valid;
 reg p_wait_next,p_wait_slot,p_wait_needs_bank;
 reg [5:0] p_wait_y,p_wait_x; reg p_wait_group;
 reg [5:0] pw_k; reg pw_project,pw_slot;
 reg ded_active,ded_slot,ded_raw_phase; reg pool_pw_active,pool_pw_slot; reg [5:0] pool_pw_k;
 reg [7:0] rq_base; reg rq_active;

 /* DW source/capture path. */
 reg dw_active; reg [4:0] dw_job_y,dw_job_x; reg dw_job_group; reg [9:0] dw_jobs_started,dw_jobs_done;
 reg [31:0] dw_fifo_raw[0:DW_FIFO_DEPTH-1][0:15];
 reg [4:0] dw_fifo_y[0:DW_FIFO_DEPTH-1],dw_fifo_x[0:DW_FIFO_DEPTH-1];
 reg dw_fifo_group[0:DW_FIFO_DEPTH-1];
 reg [2:0] dw_slot_resp_count[0:DW_FIFO_DEPTH-1];
 reg [6:0] dw_fifo_count; reg [5:0] dw_fifo_head,dw_fifo_tail,dw_issue_slot; reg [1:0] dw_rq_base;
 /* Capture and issue counts are separate.  FIFO occupancy only tells us how
  * many captured entries have not retired; it does not tell us whether those
  * entries have already been issued to the RQ pool.  Keep the per-group
  * issued total monotonic across S_DW_WAIT so a response backlog cannot be
  * mistaken for an unissued slot at the 256-entry boundary. */
 reg [9:0] dw_capture_jobs,dw_issue_jobs; reg dw_issue_active;
 reg [7:0] dw_cfg_idx; reg dw_cfg_group,dw_run_group;
 reg dw_req_pending; reg [31:0] dw_req_addr_reg;
 reg [31:0] dw_req_count,dw_resp_count,dw_config_count,dw_start_count,rq_accept_count;
 reg [31:0] source_stall_count,bank_conflict_count,final_commit_count;
 reg [31:0] pw_rq_overlap_count,dw_rq_overlap_count;
 reg [8:0] expand_written_tiles;

 /* Persistent v5 A/B diagnostics.  These counters are intentionally
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

 integer i,cap_i,q,pw_q,rq_q,src_q,idx,ky,kx,kg,flat,rq_flat,param_idx,src_idx,word_idx_local,dw_slot_idx;
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
 assign active_epoch=epoch_reg;
 /* The legacy byte port remains present for interface compatibility, but v5
  * completion/output are driven by the worded bank service below. */
 assign out_valid=1'b0; assign out_index=16'd0; assign out_data=8'sd0;
 assign word_out_valid=rst_n && (word_drain_slot ? word_bank_valid1 : word_bank_valid0);
 assign word_out_data=word_drain_slot ? word_bank1[word_drain_index] : word_bank0[word_drain_index];
 assign word_out_index=word_global_index;
 assign word_out_epoch=epoch_reg;
 wire cfg_fire=cfg_valid&&cfg_ready,start_fire=start_valid&&start_ready;

 edgembconv_hwacandidate_d4_vstream_v2_pw112 u_pw112(
   .clk(clk),.rst_n(rst_n),.valid_in(ded_active&&pw112_ready),.ready_in(pw112_ready),
   .first_k(pw_first),.last_k(pw_last),.k_idx(pw_k_idx),.pixel_mask(pw_pix_mask[6:0]),.cout_mask(pw_cout_mask),
   .act_vec(pw_act7),.wgt_vec(pw_wgt),.ready_out(1'b1),.valid_out(pw112_valid),.psum_out(pw112_psum),.lane_mask_out(pw112_mask));

 /* Shared pool is in RQ mode only when the scheduler presents RQ input.  Its
  * mode fence is therefore authoritative for every context transition. */
 assign pool_mode_rq = rq_active;
 wire pool_pw_offer = pool_pw_active && (pool_pw_k <= (pw_project?6'd31:6'd15));
 wire rq_offer = rq_active && ((state==S_DW_RQ) ? (rq_base<=12) : (rq_base<=124));
  assign pool_valid_in = rq_offer || pool_pw_offer;
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
   /* The DW tile explicitly permits a response and the following tap
    * request on the same edge.  Keep the registered source service one
    * request deep, but replace a consumed pending response immediately so
    * the 4418-read ledger does not pay an avoidable bubble per tap. */
   dw_src_req_ready=scratch_read_ready && dw_active &&
                    (!dw_req_pending || dw_src_resp_ready) &&
                    (dw_fifo_count<DW_FIFO_DEPTH) && !dw_start_ready;
   dw_src_resp_valid=dw_req_pending;
   dw_src_resp_data=128'd0;
   src_idx=dw_req_pending ? dw_req_addr_reg*32+(dw_job_group?16:0) : 0;
   dw_src_resp_data[0*8 +:8]=scratch0_bank[0][src_idx/16];
   dw_src_resp_data[1*8 +:8]=scratch0_bank[1][src_idx/16];
   dw_src_resp_data[2*8 +:8]=scratch0_bank[2][src_idx/16];
   dw_src_resp_data[3*8 +:8]=scratch0_bank[3][src_idx/16];
   dw_src_resp_data[4*8 +:8]=scratch0_bank[4][src_idx/16];
   dw_src_resp_data[5*8 +:8]=scratch0_bank[5][src_idx/16];
   dw_src_resp_data[6*8 +:8]=scratch0_bank[6][src_idx/16];
   dw_src_resp_data[7*8 +:8]=scratch0_bank[7][src_idx/16];
   dw_src_resp_data[8*8 +:8]=scratch0_bank[8][src_idx/16];
   dw_src_resp_data[9*8 +:8]=scratch0_bank[9][src_idx/16];
   dw_src_resp_data[10*8 +:8]=scratch0_bank[10][src_idx/16];
   dw_src_resp_data[11*8 +:8]=scratch0_bank[11][src_idx/16];
   dw_src_resp_data[12*8 +:8]=scratch0_bank[12][src_idx/16];
   dw_src_resp_data[13*8 +:8]=scratch0_bank[13][src_idx/16];
   dw_src_resp_data[14*8 +:8]=scratch0_bank[14][src_idx/16];
   dw_src_resp_data[15*8 +:8]=scratch0_bank[15][src_idx/16];
 end

 /* Current PW operands.  One horizontal 8-pixel tile is explicit; y/x/group
  * counters advance without an inferred divide/modulo datapath. */
 always @* begin
     pw_act7=0;pw_act_pool=0;pw_wgt=0;pool_wgt=0;pw_pix_mask=ded_raw_phase?8'h01:8'h7f;pw_cout_mask=16'hffff;pw_first=(pw_k==0);
     pw_last=pw_project?(pw_k==31):(pw_k==15);pw_k_idx=pw_k;pw_metadata={pw_project,ded_y,ded_x,ded_group,pw_k};
   /* For project production the dedicated island and shared pool operate on
    * the same producer descriptor.  p_* is the independent consumer head and
    * may already point at an older context while this raw lane is captured. */
   pool_pw_metadata={pw_project,pw_project?ded_y:(pool_pw_slot?ctx_y1:ctx_y0),pw_project?ded_x:(pool_pw_slot?ctx_x1:ctx_x0),pw_project?ded_group:(pool_pw_slot?ctx_group1:ctx_group0),pool_pw_k};
     /* Producer coordinates are always carried by ded_*; p_* remains the
      * independent consumer descriptor while a project RQ burst is active. */
     ky=ded_y;kx=ded_x;kg=ded_group;
   if(ded_active||pool_pw_active) begin
     /* Each unrolled project lane reads its own copy.  During the raw pass
      * all seven lanes intentionally use the same source offset (7), but
      * the copies remain distinct so synthesis sees one read per RAM. */
     pw_act7[0*8 +:8]=pw_project?scratch1_word0[((ky*16+kx+(ded_raw_phase?7:0))*8)+pw_k[5:2]][(pw_k[1:0]*8) +:8]:input_mem[(ky*32+kx+(ded_raw_phase?7:0))*16+pw_k];
     pw_act7[1*8 +:8]=pw_project?scratch1_word1[((ky*16+kx+(ded_raw_phase?7:1))*8)+pw_k[5:2]][(pw_k[1:0]*8) +:8]:input_mem[(ky*32+kx+(ded_raw_phase?7:1))*16+pw_k];
     pw_act7[2*8 +:8]=pw_project?scratch1_word2[((ky*16+kx+(ded_raw_phase?7:2))*8)+pw_k[5:2]][(pw_k[1:0]*8) +:8]:input_mem[(ky*32+kx+(ded_raw_phase?7:2))*16+pw_k];
     pw_act7[3*8 +:8]=pw_project?scratch1_word3[((ky*16+kx+(ded_raw_phase?7:3))*8)+pw_k[5:2]][(pw_k[1:0]*8) +:8]:input_mem[(ky*32+kx+(ded_raw_phase?7:3))*16+pw_k];
     pw_act7[4*8 +:8]=pw_project?scratch1_word4[((ky*16+kx+(ded_raw_phase?7:4))*8)+pw_k[5:2]][(pw_k[1:0]*8) +:8]:input_mem[(ky*32+kx+(ded_raw_phase?7:4))*16+pw_k];
     pw_act7[5*8 +:8]=pw_project?scratch1_word5[((ky*16+kx+(ded_raw_phase?7:5))*8)+pw_k[5:2]][(pw_k[1:0]*8) +:8]:input_mem[(ky*32+kx+(ded_raw_phase?7:5))*16+pw_k];
     pw_act7[6*8 +:8]=pw_project?scratch1_word6[((ky*16+kx+(ded_raw_phase?7:6))*8)+pw_k[5:2]][(pw_k[1:0]*8) +:8]:input_mem[(ky*32+kx+(ded_raw_phase?7:6))*16+pw_k];
     if(pw_project)
       pw_act_pool = {16{scratch1_word0[((ded_y*16+ded_x+7)*8)+pool_pw_k[5:2]][(pool_pw_k[1:0]*8) +:8]}};
     else
       pw_act_pool = {16{input_mem[((pool_pw_slot?ctx_y1:ctx_y0)*32+(pool_pw_slot?ctx_x1:ctx_x0)+7)*16+pool_pw_k]}};
     for(pw_q=0;pw_q<16;pw_q=pw_q+1) begin
       idx=(pw_project?3072:2048)+kg*16*(pw_project?32:16)+pw_k+pw_q*(pw_project?32:16);pw_wgt[pw_q*8 +:8]=pw_weight_mem[idx];
       idx=(pw_project?3072:2048)+(pw_project?ded_group:(pool_pw_slot?ctx_group1:ctx_group0))*16*(pw_project?32:16)+pool_pw_k+pw_q*(pw_project?32:16);pool_wgt[pw_q*8 +:8]=pw_weight_mem[idx];
     end
   end
 end

 /* RQ reads exactly four lane contexts. */
 always @* begin
   rq_acc=0;rq_mult=0;rq_shift=0;rq_zp=0;rq_min=0;rq_max=0;rq_metadata=0;
   if(rq_active) begin
       if(state==S_DW_RQ)
         /* low byte is the four-channel quad base; bits 13:8 tag the raw
          * capture slot so a later response never depends on FSM head state. */
         rq_metadata={18'd0,dw_issue_slot,rq_base};
       else
         rq_metadata={pw_project?1'b1:1'b0,pw_project?p_y:(ctx_slot_rq?ctx_y1:ctx_y0),pw_project?p_x:(ctx_slot_rq?ctx_x1:ctx_x0),pw_project?p_group:(ctx_slot_rq?ctx_group1:ctx_group0),rq_base};
       for(rq_q=0;rq_q<4;rq_q=rq_q+1) begin
       rq_flat=rq_base+rq_q;
        if(state==S_DW_RQ) begin param_idx=160+(dw_fifo_group[dw_issue_slot]?16:0)+(rq_flat%16);rq_acc[rq_q*32 +:32]=dw_fifo_raw[dw_issue_slot][rq_flat%16];rq_min[rq_q*32 +:32]=0;rq_max[rq_q*32 +:32]=127;end
       else begin param_idx=(pw_project?96:64)+(pw_project?(p_group?16:0):(ctx_slot_rq?(ctx_group1?16:0):(ctx_group0?16:0)))+(rq_flat%16);if(rq_flat<112) begin if(ctx_slot_rq) rq_acc[rq_q*32 +:32]=ctx_bus1[rq_flat*32 +:32]; else rq_acc[rq_q*32 +:32]=ctx_bus0[rq_flat*32 +:32];end else begin if(ctx_slot_rq) rq_acc[rq_q*32 +:32]=ctx_raw1[rq_flat]; else rq_acc[rq_q*32 +:32]=ctx_raw0[rq_flat];end rq_min[rq_q*32 +:32]=pw_project?-128:0;rq_max[rq_q*32 +:32]=127;end
       rq_acc[rq_q*32 +:32]=rq_acc[rq_q*32 +:32]+bias_mem[param_idx];rq_mult[rq_q*32 +:32]=multiplier_mem[param_idx];rq_shift[rq_q*6 +:6]=shift_mem[param_idx][5:0];
       end
   end
 end

 wire context_rq_ready=(ctx_slot_rq?ctx_ded_ready1&&ctx_pool_ready1:ctx_ded_ready0&&ctx_pool_ready0);
 wire p_slot0_ready=ctx_ded_ready0&&ctx_pool_ready0;
 wire p_slot1_ready=ctx_ded_ready1&&ctx_pool_ready1;
 wire p_wait_context_ready=p_wait_slot?p_slot1_ready:p_slot0_ready;
 wire p_wait_bank_ready=!p_wait_needs_bank || (word_write_slot ? !word_bank_valid1 : !word_bank_valid0);
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
 wire dw_fifo_pop=dw_slot_retire;
 wire word_out_fire=word_out_valid&&word_out_ready;
 wire dw_rq_output= (state==S_DW_RQ)&&pool_valid&&pool_mode_out;
 wire dw_slot_retire=dw_rq_output&&(dw_slot_resp_count[pool_metadata[13:8]]==3);
 /* Banked scratch write descriptors.  rq_base is always aligned to four, so
  * a vector never crosses the 16-channel group boundary. */
 wire scratch0_write_fire=(state==S_E_RQ)&&pool_valid&&pool_mode_out;
 wire [10:0] scratch0_write_row=((((ctx_slot_rq?ctx_y1:ctx_y0)*32)+
                                  (ctx_slot_rq?ctx_x1:ctx_x0)+
                                  (pool_metadata[7:0]/16))*2)+
                                  (ctx_slot_rq?ctx_group1:ctx_group0);
 wire [3:0] scratch0_write_bank=pool_metadata[3:0];
 wire [31:0] scratch0_write_data=pool_rq_result;
 genvar scratch0_bank_g;
 generate
   for(scratch0_bank_g=0;scratch0_bank_g<16;scratch0_bank_g=scratch0_bank_g+1) begin : gen_v5_scratch0_bank_write
     always @(posedge clk) begin
       if(scratch0_write_fire &&
          (scratch0_write_bank<=scratch0_bank_g) &&
          ((scratch0_write_bank+3)>=scratch0_bank_g))
         scratch0_bank[scratch0_bank_g][scratch0_write_row] <=
           scratch0_write_data[((scratch0_bank_g-scratch0_write_bank)*8) +:8];
     end
   end
 endgenerate
 /* A DW RQ result is already one complete 32-bit word.  The seven copies
  * below therefore each have one write port, avoiding the four-write-port
  * byte array that previously dissolved into 65,536 registers. */
 wire scratch1_write_fire=(state==S_DW_RQ)&&pool_valid&&pool_mode_out;
 wire [10:0] scratch1_write_index=((dw_fifo_y[pool_metadata[13:8]]*16)+
                                   dw_fifo_x[pool_metadata[13:8]])*8+
                                   (dw_fifo_group[pool_metadata[13:8]]?11'd4:11'd0)+
                                   (pool_metadata[7:0]/4);
 wire [31:0] scratch1_write_data=pool_rq_result;
 always @(posedge clk) if(scratch1_write_fire)
   scratch1_word0[scratch1_write_index] <= scratch1_write_data;
 always @(posedge clk) if(scratch1_write_fire)
   scratch1_word1[scratch1_write_index] <= scratch1_write_data;
 always @(posedge clk) if(scratch1_write_fire)
   scratch1_word2[scratch1_write_index] <= scratch1_write_data;
 always @(posedge clk) if(scratch1_write_fire)
   scratch1_word3[scratch1_write_index] <= scratch1_write_data;
 always @(posedge clk) if(scratch1_write_fire)
   scratch1_word4[scratch1_write_index] <= scratch1_write_data;
 always @(posedge clk) if(scratch1_write_fire)
   scratch1_word5[scratch1_write_index] <= scratch1_write_data;
 always @(posedge clk) if(scratch1_write_fire)
   scratch1_word6[scratch1_write_index] <= scratch1_write_data;
 wire diag_pool_scope=(state==S_E_BOTH)||(state==S_E_RQ)||(state==S_E_POOL)||
                      (state==S_DW_RQ)||(state==S_P_BOTH)||(state==S_P_WAIT)||
                      (state==S_P_RQ);
 wire diag_pool_input_fire=pool_pw_fire||pool_rq_fire;

 always @(posedge clk) begin
   if(!rst_n) begin
     state<=S_IDLE;done_valid<=0;done_epoch<=0;epoch_reg<=0;bank0_state_reg<=FREE;bank1_state_reg<=FREE;output_cursor<=0;
     word_bank_valid0<=0;word_bank_valid1<=0;word_write_slot<=0;word_drain_slot<=0;word_drain_index<=0;word_global_index<=0;p_bank_wait<=0;
     cycle_count<=0;pw_mac_count<=0;dw_mac_count<=0;overlap_cycles<=0;protocol_errors<=0;pw_project<=0;pw_slot<=0;pw_k<=0;ded_active<=0;ded_slot<=0;ded_raw_phase<=0;pool_pw_active<=0;pool_pw_slot<=0;pool_pw_k<=0;rq_active<=0;rq_base<=0;ctx_slot_rq<=0;
     e_y<=0;e_x<=0;e_group<=0;next_y<=0;next_x<=8;next_group<=0;ded_y<=0;ded_x<=0;ded_group<=0;ctx_bus0<=0;ctx_bus1<=0;e_done_tiles<=0;expand_written_tiles<=0;ctx_ded_ready0<=0;ctx_ded_ready1<=0;ctx_pool_ready0<=0;ctx_pool_ready1<=0;
     p_y<=0;p_x<=0;p_group<=0;p_next_y<=0;p_next_x<=0;p_next_group<=0;p_next_valid<=0;p_wait_next<=0;p_wait_slot<=0;p_wait_needs_bank<=0;p_wait_y<=0;p_wait_x<=0;p_wait_group<=0;dw_active<=0;dw_jobs_started<=0;dw_jobs_done<=0;dw_fifo_count<=0;dw_fifo_head<=0;dw_fifo_tail<=0;dw_issue_slot<=0;dw_capture_jobs<=0;dw_issue_jobs<=0;dw_issue_active<=0;dw_rq_base<=0;dw_job_y<=0;dw_job_x<=0;dw_job_group<=0;
     dw_req_count<=0;dw_resp_count<=0;dw_config_count<=0;dw_start_count<=0;rq_accept_count<=0;source_stall_count<=0;bank_conflict_count<=0;final_commit_count<=0;pw_rq_overlap_count<=0;dw_rq_overlap_count<=0;dw_cfg_idx<=0;dw_cfg_group<=0;dw_run_group<=0;dw_req_pending<=0;dw_req_addr_reg<=0;
     diag_pool_pw_accept_count<=0;diag_pool_rq_accept_count<=0;diag_pool_busy_cycles<=0;diag_pool_idle_cycles<=0;diag_pool_turnaround_cycles<=0;diag_pool_mode_switch_count<=0;diag_pool_pw_output_count<=0;diag_pool_rq_output_count<=0;diag_context_wait_cycles<=0;diag_e_wait_cycles<=0;diag_e_pool_cycles<=0;diag_p_wait_cycles<=0;diag_ded_normal_accept_count<=0;diag_ded_raw_accept_count<=0;diag_pool_prev_mode<=0;diag_pool_prev_valid<=0;
     for(i=0;i<13;i=i+1) diag_state_cycles[i]<=0;
     for(i=0;i<DW_FIFO_DEPTH;i=i+1) dw_slot_resp_count[i]<=0;
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
     else if(dw_src_resp_valid&&dw_src_resp_ready) dw_req_pending<=0;
     if(dw_src_resp_valid&&dw_src_resp_ready) dw_resp_count<=dw_resp_count+1;
      if(pool_pw_fire) pool_pw_k<=pool_pw_k+1'b1;
      if(ded_fire) begin if(ded_raw_phase) diag_ded_raw_accept_count<=diag_ded_raw_accept_count+1'b1; else diag_ded_normal_accept_count<=diag_ded_normal_accept_count+1'b1;end
       if(dw_cfg_valid&&dw_cfg_ready) begin dw_config_count<=dw_config_count+1;if(dw_cfg_idx==143) begin dw_cfg_idx<=0;if(!dw_cfg_group) begin dw_cfg_group<=1;state<=S_E_BOTH;ded_active<=1;ded_raw_phase<=0;pool_pw_active<=0;pw_k<=0;pool_pw_k<=0;ded_y<=0;ded_x<=0;ded_group<=0;end else begin dw_run_group<=1;dw_capture_jobs<=0;dw_issue_jobs<=0;state<=S_DW_WAIT;end end else dw_cfg_idx<=dw_cfg_idx+1;end
     if(dw_start_valid&&dw_start_ready) dw_start_count<=dw_start_count+1;
       if(start_fire) begin state<=S_DW_CFG;epoch_reg<=start_epoch;done_epoch<=start_epoch;bank0_state_reg<=FILL;bank1_state_reg<=FREE;word_bank_valid0<=0;word_bank_valid1<=0;word_write_slot<=0;word_drain_slot<=0;word_drain_index<=0;word_global_index<=0;p_bank_wait<=0;pw_project<=0;pw_slot<=0;pw_k<=0;ded_active<=0;ded_slot<=0;ded_raw_phase<=0;pool_pw_active<=0;pool_pw_slot<=0;pool_pw_k<=0;e_y<=0;e_x<=0;e_group<=0;next_y<=0;next_x<=8;next_group<=0;ded_y<=0;ded_x<=0;ded_group<=0;e_done_tiles<=0;ctx_y0<=0;ctx_x0<=0;ctx_group0<=0;ctx_y1<=0;ctx_x1<=8;ctx_group1<=0;ctx_ded_ready0<=0;ctx_pool_ready0<=0;ctx_pool_ready1<=0;ctx_ded_ready1<=0;p_y<=0;p_x<=0;p_group<=0;p_next_y<=0;p_next_x<=0;p_next_group<=0;p_next_valid<=0;p_wait_next<=0;p_wait_slot<=0;p_wait_needs_bank<=0;p_wait_y<=0;p_wait_x<=0;p_wait_group<=0;rq_active<=0;dw_active<=0;dw_jobs_started<=0;dw_jobs_done<=0;dw_fifo_count<=0;dw_fifo_head<=0;dw_fifo_tail<=0;dw_issue_slot<=0;dw_capture_jobs<=0;dw_issue_jobs<=0;dw_issue_active<=0;dw_cfg_idx<=0;dw_cfg_group<=0;dw_run_group<=0;for(i=0;i<DW_FIFO_DEPTH;i=i+1) dw_slot_resp_count[i]<=0;end
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
           /* Expansion still serializes its raw lane on the dedicated island.
            * Project uses the existing 16-DSP pool for that lane while the
            * 112-DSP island starts the next normal pass, so do not reopen a
            * second dedicated raw pass in project mode. */
           if(pw_project) begin
             ded_raw_phase<=0;
             ded_active<=0;
           end else begin
             ded_raw_phase<=1;
             ded_active<=1;
             pw_k<=0;
           end
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
             /* Expansion scratch is written by the channel-bank processes
              * above; keeping the four-byte RQ result out of this large
              * control process is required for block-RAM inference. */
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
             /* Start only when a captured slot has not yet been issued.  A
              * non-empty FIFO by itself is insufficient because it may
              * contain already-issued responses waiting for retirement. */
             if(dw_fifo_count!=0 && (dw_issue_jobs<dw_capture_jobs)) begin
               rq_active<=1;rq_base<=0;
               if(dw_issue_jobs==0) dw_issue_slot<=dw_fifo_head;
               else dw_issue_slot<=dw_issue_slot+1'b1;
               dw_issue_jobs<=dw_issue_jobs+1'b1;
               dw_issue_active<=1;ctx_slot_rq<=0;state<=S_DW_RQ;
             end
           else if(!dw_active && dw_run_group==0 && dw_jobs_done==256) begin dw_cfg_idx<=0;dw_jobs_started<=0;state<=S_DW_CFG;end
             else if(!dw_active && dw_run_group==1 && dw_jobs_done==512) begin state<=S_P_BOTH;pw_project<=1;pw_k<=0;ded_active<=1;ded_raw_phase<=0;ded_slot<=0;pool_pw_active<=1;pool_pw_slot<=0;pool_pw_k<=0;ded_y<=0;ded_x<=0;ded_group<=0;p_y<=0;p_x<=0;p_group<=0;p_next_y<=0;p_next_x<=0;p_next_group<=1;p_next_valid<=1;p_wait_next<=0;p_wait_needs_bank<=0;ctx_ded_ready0<=0;ctx_pool_ready0<=0;ctx_ded_ready1<=0;ctx_pool_ready1<=0;end
          end
          S_DW_RQ: begin
            /* Four requests form one DW vector.  Advance the issue pointer as
             * soon as those inputs fire; returns below are tagged by raw slot
             * and may retire independently of the current issue descriptor. */
            /* A source result may arrive one or more cycles after the last
             * issue burst stopped.  Re-arm the next slot in-place so the
             * response-retirement path remains live while the FIFO fills;
             * otherwise S_DW_RQ can sit forever with rq_active low. */
            if(!rq_active && !dw_issue_active && (dw_issue_jobs<10'd256) &&
               ((dw_issue_jobs < dw_capture_jobs) || dw_fifo_push)) begin
              rq_active<=1;rq_base<=0;
              if(dw_issue_jobs==0) dw_issue_slot<=dw_fifo_head;
              else dw_issue_slot<=dw_issue_slot+1'b1;
              dw_issue_jobs<=dw_issue_jobs+1'b1;dw_issue_active<=1;
            end
            if(pool_rq_fire) begin
              rq_accept_count<=rq_accept_count+1;
              if(rq_base==8'd12) begin
                /* Advance only when a genuinely new raw slot is already in
                 * the FIFO (or is being captured on this edge).  This keeps
                 * an issued-but-not-retired backlog from wrapping the 6-bit
                 * slot tag into a duplicate fifth quad. */
                if((dw_issue_jobs<10'd256)&&((dw_issue_jobs < dw_capture_jobs) || dw_fifo_push)) begin
                  rq_active<=1;rq_base<=0;dw_issue_slot<=dw_issue_slot+1'b1;dw_issue_jobs<=dw_issue_jobs+1'b1;dw_issue_active<=1;
                end else begin rq_active<=0;dw_issue_active<=0;end
              end else rq_base<=rq_base+4;
            end
            if(dw_rq_output) begin
              dw_slot_idx=pool_metadata[13:8];
              /* DW scratch receives the complete aligned result word in the
               * dedicated single-write memory processes above. */
              if(dw_slot_resp_count[dw_slot_idx]==3) begin
                dw_slot_resp_count[dw_slot_idx]<=0;
                dw_jobs_done<=dw_jobs_done+1;
                dw_fifo_head<=dw_fifo_head+1'b1;
                if(dw_jobs_done==511) begin state<=S_P_BOTH;pw_project<=1;pw_k<=0;ded_active<=1;ded_raw_phase<=0;ded_slot<=0;pool_pw_active<=1;pool_pw_slot<=0;pool_pw_k<=0;ded_y<=0;ded_x<=0;ded_group<=0;p_y<=0;p_x<=0;p_group<=0;p_next_y<=0;p_next_x<=0;p_next_group<=1;p_next_valid<=1;p_wait_next<=0;p_wait_needs_bank<=0;ctx_ded_ready0<=0;ctx_pool_ready0<=0;ctx_ded_ready1<=0;ctx_pool_ready1<=0;end
                else if(!rq_active && dw_fifo_count==1 && !dw_fifo_push) state<=S_DW_WAIT;
              end else dw_slot_resp_count[dw_slot_idx]<=dw_slot_resp_count[dw_slot_idx]+1'b1;
            end
          end
          S_P_BOTH: begin
            /* Producer coordinates are separate from the consumer p_*
             * descriptor.  This state may therefore be entered for either
             * context slot while the other slot is being RQ-drained. */
            if(ded_slot) begin
              ctx_y1<=ded_y;ctx_x1<=ded_x;ctx_group1<=ded_group;
              ctx_ded_ready1<=0;ctx_pool_ready1<=0;
            end else begin
              ctx_y0<=ded_y;ctx_x0<=ded_x;ctx_group0<=ded_group;
              ctx_ded_ready0<=0;ctx_pool_ready0<=0;
            end
            if(ded_fire) begin
              pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);
              if(ded_last_fire) begin ded_active<=0;pw_k<=0;state<=S_P_WAIT;end
              else pw_k<=pw_k+1'b1;
            end
          end
          S_P_WAIT: begin
            /* Drain the raw eight-pixel pass, then launch the next producer
             * into the other slot at the same edge that starts this context's
             * RQ.  The dedicated island and shared RQ pool now overlap. */
            if(ded_fire) begin
              pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);
              if(ded_last_fire) begin ded_active<=0;pw_k<=0;end
              else pw_k<=pw_k+1'b1;
            end
            if((ded_slot ? ctx_ded_ready1&&ctx_pool_ready1 : ctx_ded_ready0&&ctx_pool_ready0)) begin
              ctx_slot_rq<=ded_slot;
              p_y<=ded_y;p_x<=ded_x;p_group<=ded_group;
              rq_active<=1;rq_base<=0;state<=S_P_RQ;
              if(p_next_valid) begin
                ded_slot<=~ded_slot;ded_y<=p_next_y;ded_x<=p_next_x;ded_group<=p_next_group;
                if(ded_slot) begin ctx_y0<=p_next_y;ctx_x0<=p_next_x;ctx_group0<=p_next_group;ctx_ded_ready0<=0;ctx_pool_ready0<=0;end
                else begin ctx_y1<=p_next_y;ctx_x1<=p_next_x;ctx_group1<=p_next_group;ctx_ded_ready1<=0;ctx_pool_ready1<=0;end
                ded_active<=1;ded_raw_phase<=0;pw_k<=0;pool_pw_active<=1;pool_pw_slot<=~ded_slot;pool_pw_k<=0;
                if((p_next_y==15)&&(p_next_x==8)&&(p_next_group==1)) p_next_valid<=0;
                else if(p_next_group==0) p_next_group<=1;
                else if(p_next_x==8) begin p_next_group<=0;p_next_x<=0;p_next_y<=p_next_y+1'b1;end
                else begin p_next_group<=0;p_next_x<=8;end
               end else begin ded_active<=0;pool_pw_active<=0;end
            end
          end
          S_P_RQ: begin
            /* A pending transition means the next producer context is still
             * finishing or its output bank is still occupied.  Hold the RQ
             * source idle until both its descriptor and bank are safe. */
            /* The producer must continue through its raw pass even while the
             * consumer waits; otherwise a normal-pass-ready context can never
             * assert ctx_pool_ready and the two-context handoff deadlocks. */
            if(ded_fire) begin
              pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);
              if(ded_last_fire) begin ded_active<=0;pw_k<=0;end
              else pw_k<=pw_k+1'b1;
            end
            if(p_wait_next) begin
              if(p_wait_context_ready && p_wait_bank_ready) begin
                p_wait_next<=0;p_y<=p_wait_y;p_x<=p_wait_x;p_group<=p_wait_group;
                ctx_slot_rq<=p_wait_slot;rq_active<=1;rq_base<=0;
                if(p_next_valid) begin
                  ded_slot<=~p_wait_slot;ded_y<=p_next_y;ded_x<=p_next_x;ded_group<=p_next_group;
                  if(p_wait_slot) begin ctx_y0<=p_next_y;ctx_x0<=p_next_x;ctx_group0<=p_next_group;ctx_ded_ready0<=0;ctx_pool_ready0<=0;end
                  else begin ctx_y1<=p_next_y;ctx_x1<=p_next_x;ctx_group1<=p_next_group;ctx_ded_ready1<=0;ctx_pool_ready1<=0;end
                  ded_active<=1;ded_raw_phase<=0;pw_k<=0;pool_pw_active<=1;pool_pw_slot<=~p_wait_slot;pool_pw_k<=0;
                  if((p_next_y==15)&&(p_next_x==8)&&(p_next_group==1)) p_next_valid<=0;
                  else if(p_next_group==0) p_next_group<=1;
                  else if(p_next_x==8) begin p_next_group<=0;p_next_x<=0;p_next_y<=p_next_y+1'b1;end
                  else begin p_next_group<=0;p_next_x<=8;end
                 end else begin ded_active<=0;pool_pw_active<=0;end
              end
            end else begin
              if(pool_rq_fire) begin rq_accept_count<=rq_accept_count+1;rq_base<=rq_base+4;end
              if(pool_valid&&pool_mode_out) begin
                for(i=0;i<4;i=i+1) begin
                  flat=pool_metadata[7:0]+i;
                  idx=((p_y*16+p_x)+flat/16)*32+p_group*16+flat%16;
                  output_mem[idx]<=pool_rq_result[i*8 +:8];
                  final_commit_count<=final_commit_count+4;
                end
                /* One pool result is one complete 32-bit output word. */
                word_idx_local=(pool_metadata[7:0]/16)*8+p_group*4+(pool_metadata[7:0]%16)/4;
                if(word_write_slot) word_bank1[word_idx_local]<=pool_rq_result;
                else word_bank0[word_idx_local]<=pool_rq_result;
                if(pool_metadata[7:0]==124) begin
                  rq_active<=0;
                  if(p_group==0) begin
                    /* Group 1 of the same context is the next consumer. */
                    if(ctx_slot_rq) begin ctx_ded_ready1<=0;ctx_pool_ready1<=0;end else begin ctx_ded_ready0<=0;ctx_pool_ready0<=0;end
                    p_group<=1;
                    if((ctx_slot_rq ? p_slot0_ready : p_slot1_ready)) begin
                      p_y<=p_y;p_x<=p_x;ctx_slot_rq<=~ctx_slot_rq;rq_active<=1;rq_base<=0;
                      if(p_next_valid) begin
                        ded_slot<=ctx_slot_rq;ded_y<=p_next_y;ded_x<=p_next_x;ded_group<=p_next_group;
                        if(ctx_slot_rq) begin ctx_y0<=p_next_y;ctx_x0<=p_next_x;ctx_group0<=p_next_group;ctx_ded_ready0<=0;ctx_pool_ready0<=0;end
                        else begin ctx_y1<=p_next_y;ctx_x1<=p_next_x;ctx_group1<=p_next_group;ctx_ded_ready1<=0;ctx_pool_ready1<=0;end
                        ded_active<=1;ded_raw_phase<=0;pw_k<=0;pool_pw_active<=1;pool_pw_slot<=ctx_slot_rq;pool_pw_k<=0;
                        if((p_next_y==15)&&(p_next_x==8)&&(p_next_group==1)) p_next_valid<=0;
                        else if(p_next_group==0) p_next_group<=1;
                        else if(p_next_x==8) begin p_next_group<=0;p_next_x<=0;p_next_y<=p_next_y+1'b1;end
                        else begin p_next_group<=0;p_next_x<=8;end
                       end else begin ded_active<=0;pool_pw_active<=0;end
                    end else begin
                      p_wait_next<=1;p_wait_slot<=~ctx_slot_rq;p_wait_y<=p_y;p_wait_x<=p_x;p_wait_group<=1;p_wait_needs_bank<=0;
                    end
                  end else begin
                    /* Both groups filled this bank; publish before moving to
                     * the next spatial context and toggling the write bank. */
                    if(word_write_slot) word_bank_valid1<=1; else word_bank_valid0<=1;
                    word_write_slot<=~word_write_slot;
                    if(ctx_slot_rq) begin ctx_ded_ready1<=0;ctx_pool_ready1<=0;end else begin ctx_ded_ready0<=0;ctx_pool_ready0<=0;end
                    if((p_y==15)&&(p_x==8)) state<=S_OUTPUT;
                    else begin
                      if(p_x==8) begin p_wait_y<=p_y+1;p_wait_x<=0;end
                      else begin p_wait_y<=p_y;p_wait_x<=8;end
                      p_wait_group<=0;p_wait_slot<=~ctx_slot_rq;p_wait_needs_bank<=1;
                      if((ctx_slot_rq ? p_slot0_ready : p_slot1_ready) &&
                         (~word_write_slot ? !word_bank_valid1 : !word_bank_valid0)) begin
                        p_y<=p_x==8 ? p_y+1'b1 : p_y;
                        p_x<=p_x==8 ? 0 : 8;p_group<=0;ctx_slot_rq<=~ctx_slot_rq;rq_active<=1;rq_base<=0;
                        if(p_next_valid) begin
                          ded_slot<=ctx_slot_rq;ded_y<=p_next_y;ded_x<=p_next_x;ded_group<=p_next_group;
                          if(ctx_slot_rq) begin ctx_y0<=p_next_y;ctx_x0<=p_next_x;ctx_group0<=p_next_group;ctx_ded_ready0<=0;ctx_pool_ready0<=0;end
                          else begin ctx_y1<=p_next_y;ctx_x1<=p_next_x;ctx_group1<=p_next_group;ctx_ded_ready1<=0;ctx_pool_ready1<=0;end
                          ded_active<=1;ded_raw_phase<=0;pw_k<=0;pool_pw_active<=1;pool_pw_slot<=ctx_slot_rq;pool_pw_k<=0;
                          if((p_next_y==15)&&(p_next_x==8)&&(p_next_group==1)) p_next_valid<=0;
                          else if(p_next_group==0) p_next_group<=1;
                          else if(p_next_x==8) begin p_next_group<=0;p_next_x<=0;p_next_y<=p_next_y+1'b1;end
                          else begin p_next_group<=0;p_next_x<=8;end
                         end else begin ded_active<=0;pool_pw_active<=0;end
                      end else p_wait_next<=1;
                    end
                  end
                end
              end
            end
          end
          /* Word-bank drain is handled below; this state waits for the final
           * accepted word and never exposes the legacy byte cursor. */
          S_OUTPUT: ;
         S_DONE: if(done_valid&&done_ready) begin done_valid<=0;bank0_state_reg<=FREE;bank1_state_reg<=FREE;state<=S_IDLE;end
         default: ;
        endcase
        /* Account for the 16 pool lanes when project raw accumulation is
         * enabled.  This assignment follows the state-specific dedicated
         * update so a cycle carrying both normal and raw work is summed once. */
        if(pool_pw_fire) begin
          if(ded_fire) pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112)+32'd16;
          else pw_mac_count<=pw_mac_count+32'd16;
        end
       /* Drain one complete 256-byte context bank in local index order.  The
        * global index is what the external sink observes; it is deliberately
        * advanced only on a real word handshake. */
       if(word_out_fire) begin
         if(word_drain_index==6'd63) begin
           if(word_drain_slot) word_bank_valid1<=0; else word_bank_valid0<=0;
           word_drain_index<=0;
           word_drain_slot<=~word_drain_slot;
         end else word_drain_index<=word_drain_index+1'b1;
         word_global_index<=word_global_index+1'b1;
         if(word_global_index==12'd2047) begin
           done_valid<=1;
           state<=S_DONE;
         end
       end
       /* Launch one 8x8 DW command at a time.  A command emits 64 output
        * vectors into the deep FIFO; its RQ traffic drains concurrently. */
       if((state==S_E_RQ||state==S_E_POOL) && !dw_active && dw_fifo_count<DW_FIFO_DEPTH && dw_jobs_started<256 && dw_launch_dependency_ready) begin dw_active<=1;dw_job_y<=((dw_jobs_started/DW_TILE_PIXELS)/2)*DW_TILE_H;dw_job_x<=(dw_jobs_started/DW_TILE_PIXELS%2)*DW_TILE_W;dw_job_group<=dw_run_group;dw_jobs_started<=dw_jobs_started+DW_TILE_PIXELS;end
       if((state==S_DW_RQ||state==S_DW_WAIT) && !dw_active && dw_fifo_count<DW_FIFO_DEPTH && dw_jobs_started<256 && dw_launch_dependency_ready) begin dw_active<=1;dw_job_y<=((dw_jobs_started/DW_TILE_PIXELS)/2)*DW_TILE_H;dw_job_x<=(dw_jobs_started/DW_TILE_PIXELS%2)*DW_TILE_W;dw_job_group<=dw_run_group;dw_jobs_started<=dw_jobs_started+DW_TILE_PIXELS;end
         if(dw_fifo_push) begin
           dw_mac_count<=dw_mac_count+144;
           dw_capture_jobs<=dw_capture_jobs+1'b1;
          for(i=0;i<16;i=i+1) dw_fifo_raw[dw_fifo_tail][i]<=dw_raw_psum[i*32 +:32];
          dw_fifo_y[dw_fifo_tail]<=dw_job_y+(dw_out_pixel_idx/DW_TILE_W);
          dw_fifo_x[dw_fifo_tail]<=dw_job_x+(dw_out_pixel_idx%DW_TILE_W);
          dw_fifo_group[dw_fifo_tail]<=dw_job_group;
          dw_slot_resp_count[dw_fifo_tail]<=0;
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
