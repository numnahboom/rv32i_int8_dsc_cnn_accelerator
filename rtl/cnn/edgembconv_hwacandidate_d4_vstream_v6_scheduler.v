`timescale 1ns/1ps
`default_nettype none

/*
 * D4 vstream v6 scheduler.
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
module edgembconv_hwacandidate_d4_vstream_v6_scheduler #(
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

 /* All wide activation/weight payload storage lives behind the common bank
  * boundary.  The default simulation mode keeps the old cycle-visible
  * combinational response for the frozen v6 functional ledger; synthesis
  * selects the bank module's registered XPM read path. */
  reg [7:0] v6_input_rd_valid;
  reg [87:0] v6_input_rd_addr_vec;
  reg [15:0] v6_input_rd_desc;
  wire [63:0] v6_input_rd_data_vec;
  wire [15:0] v6_input_rd_resp_desc;
 wire v6_input_rd_ready;
 reg v6_input_rd_resp_ready;
 wire v6_input_rd_resp_valid;
 reg v6_scratch0_rd_valid;
 reg [10:0] v6_scratch0_rd_addr;
 wire [127:0] v6_scratch0_rd_data;
 wire v6_scratch0_rd_ready;
 reg v6_scratch0_rd_resp_ready;
 wire v6_scratch0_rd_resp_valid;
  reg [7:0] v6_scratch1_rd_valid;
  reg [63:0] v6_scratch1_rd_addr_vec;
  reg [15:0] v6_scratch1_rd_desc;
  wire [255:0] v6_scratch1_rd_data_vec;
  wire [15:0] v6_scratch1_rd_resp_desc;
 wire v6_scratch1_rd_ready;
 reg v6_scratch1_rd_resp_ready;
 wire v6_scratch1_rd_resp_valid;
  reg v6_scratch1_pool_rd_valid;
  reg [7:0] v6_scratch1_pool_rd_addr;
  reg [15:0] v6_scratch1_pool_rd_desc;
 wire v6_scratch1_pool_rd_ready;
 reg v6_scratch1_pool_rd_resp_ready;
  wire [31:0] v6_scratch1_pool_rd_data;
  wire [15:0] v6_scratch1_pool_rd_resp_desc;
 wire v6_scratch1_pool_rd_resp_valid;
 reg [15:0] v6_scratch0_wr_valid_vec;
 reg [10:0] v6_scratch0_wr_addr;
 reg [127:0] v6_scratch0_wr_data_vec;
 reg v6_scratch1_wr_valid;
 reg [2:0] v6_scratch1_wr_bank;
 reg [7:0] v6_scratch1_wr_addr;
 reg [31:0] v6_scratch1_wr_data;
  reg v6_ded_weight_rd_valid, v6_ded_weight_project, v6_ded_weight_group;
  reg [5:0] v6_ded_weight_k;
  reg [15:0] v6_ded_weight_rd_desc;
 wire v6_ded_weight_rd_ready;
 reg v6_ded_weight_rd_resp_ready;
  wire [127:0] v6_ded_weight_rd_data;
  wire [15:0] v6_ded_weight_rd_resp_desc;
 wire v6_ded_weight_rd_resp_valid;
  reg v6_pool_weight_rd_valid, v6_pool_weight_project, v6_pool_weight_group;
  reg [5:0] v6_pool_weight_k;
  reg [15:0] v6_pool_weight_rd_desc;
 wire v6_pool_weight_rd_ready;
 reg v6_pool_weight_rd_resp_ready;
   wire [127:0] v6_pool_weight_rd_data;
   wire [15:0] v6_pool_weight_rd_resp_desc;
  wire v6_pool_weight_rd_resp_valid;

  /* A fetch descriptor is the single transaction identity shared by the
   * activation and weight RAM response.  Keeping the pair boundary explicit
   * prevents a response from a bubble or a context switch from being MACed
   * with the following K. */
  wire [15:0] ded_req_desc = {epoch_reg,ded_slot,pw_project,ded_group,
                              ded_raw_phase,pw_req_k,(pw_req_k==0),
                              (pw_req_k==(pw_project?6'd31:6'd15))};
  wire [15:0] pool_req_desc = {epoch_reg,ded_slot,pw_project,ded_group,
                               pw_project,pool_req_k,(pool_req_k==0),
                               (pool_req_k==(pw_project?6'd31:6'd15))};
  wire ded_pair_req_valid = ded_active &&
                            (pw_req_k <= (pw_project?6'd31:6'd15));
  wire pool_pair_req_valid = pool_pw_active &&
                             (pool_req_k <= (pw_project?6'd31:6'd15));
  wire ded_pair_req_ready, pool_pair_req_ready;
  wire ded_act_req_valid, ded_wgt_req_valid;
  wire pool_act_req_valid, pool_wgt_req_valid;
  wire [15:0] ded_act_req_desc, ded_wgt_req_desc;
  wire [15:0] pool_act_req_desc, pool_wgt_req_desc;
  wire ded_act_resp_ready, ded_wgt_resp_ready;
  wire pool_act_resp_ready, pool_wgt_resp_ready;
  wire ded_pair_resp_valid, pool_pair_resp_valid;
  wire [255:0] ded_pair_act_data;
  wire [127:0] ded_pair_wgt_data, pool_pair_wgt_data;
  wire [31:0] pool_pair_act_data;
   wire [15:0] ded_pair_resp_desc, pool_pair_resp_desc;
   wire ded_descriptor_mismatch, pool_descriptor_mismatch;
   wire [5:0] ded_resp_k = ded_pair_resp_desc[7:2];
   wire ded_resp_pass = ded_pair_resp_desc[8];
   wire ded_resp_first = ded_pair_resp_desc[1];
   wire ded_resp_last = ded_pair_resp_desc[0];
   wire [5:0] pool_resp_k = pool_pair_resp_desc[7:2];

  /* v6-only registered operand/token boundary.  The pair response is the
   * accepted memory transaction; this stage decouples its banked payload from
   * the dedicated PW DSP A/B ports while retaining replacement at II=1. */
  wire ded_pw_stage_in_ready, ded_pw_stage_out_valid;
  wire [255:0] ded_pw_stage_act_data;
  wire [127:0] ded_pw_stage_wgt_data;
  wire [15:0] ded_pw_stage_resp_desc;
  wire ded_pw_stage_in_fire = ded_pair_resp_valid && ded_pw_stage_in_ready;
  wire [5:0] ded_stage_k = ded_pw_stage_resp_desc[7:2];
  wire ded_stage_pass = ded_pw_stage_resp_desc[8];
  wire ded_stage_first = ded_pw_stage_resp_desc[1];
  wire ded_stage_last = ded_pw_stage_resp_desc[0];
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

  /* Two-entry PW context ping-pong.  Keep the context representation identical
   * to the frozen v6 functional contract while the surrounding activation,
   * scratch, and weight stores are banked.  This is intentionally retained
   * until a separately verified context-memory response contract exists. */
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
 reg [5:0] pw_k,pw_req_k; reg pw_project,pw_slot;
 reg ded_active,ded_slot,ded_raw_phase; reg pool_pw_active,pool_pw_slot; reg [5:0] pool_pw_k;
  reg [5:0] pool_req_k;
  /* One descriptor is reserved for each producer-side fetch response.  The
   * activation and weight banks are issued from the same request K and are
   * consumed only when both response-valid bits agree with this descriptor. */
  reg [3:0] ded_fetch_epoch, pool_fetch_epoch;
  reg ded_fetch_slot, ded_fetch_project, ded_fetch_group, ded_fetch_pass;
  reg pool_fetch_slot, pool_fetch_project, pool_fetch_group, pool_fetch_pass;
  reg [5:0] ded_fetch_y, ded_fetch_x, ded_fetch_k;
  reg [5:0] pool_fetch_y, pool_fetch_x, pool_fetch_k;
  reg ded_fetch_first, ded_fetch_last, pool_fetch_first, pool_fetch_last;
  reg [7:0] rq_base; reg rq_active;

  /* DW source/capture path. */
  reg dw_active; reg [4:0] dw_job_y,dw_job_x; reg dw_job_group; reg [9:0] dw_jobs_started,dw_jobs_done;
  reg [4:0] dw_fifo_y[0:DW_FIFO_DEPTH-1],dw_fifo_x[0:DW_FIFO_DEPTH-1];
  reg dw_fifo_group[0:DW_FIFO_DEPTH-1];
  reg [2:0] dw_slot_resp_count[0:DW_FIFO_DEPTH-1];
  wire [6:0] dw_fifo_count;
  wire [5:0] dw_fifo_head,dw_fifo_tail;
  reg [5:0] dw_issue_slot; reg [1:0] dw_rq_base;
  reg [511:0] dw_raw_capture_q;
  reg dw_raw_loaded;
  wire dw_raw_push_ready,dw_raw_read_ready,dw_raw_resp_valid;
  wire dw_raw_pop_ready;
  wire [511:0] dw_raw_resp_data;
  wire dw_raw_read_fire = dw_raw_read_ready &&
                          (state==S_DW_RQ) && rq_active && !dw_raw_loaded;
  wire dw_raw_resp_ready = (state==S_DW_RQ) && !dw_raw_loaded;
  wire dw_raw_resp_fire = dw_raw_resp_valid && dw_raw_resp_ready;
 /* Capture and issue counts are separate.  FIFO occupancy only tells us how
  * many captured entries have not retired; it does not tell us whether those
  * entries have already been issued to the RQ pool.  Keep the per-group
  * issued total monotonic across S_DW_WAIT so a response backlog cannot be
  * mistaken for an unissued slot at the 256-entry boundary. */
 reg [9:0] dw_capture_jobs,dw_issue_jobs; reg dw_issue_active;
 reg [7:0] dw_cfg_idx; reg dw_cfg_group,dw_run_group;
 reg dw_req_pending; reg [31:0] dw_req_addr_reg;
  reg [31:0] dw_req_count,dw_resp_count,dw_config_count,dw_start_count,rq_accept_count;
  /* Number of DW RQ vectors accepted by the pool but not yet emitted.  The
   * raw FIFO can reach empty before the final registered-input pool result
   * drains, so FIFO occupancy alone is not a safe state-transition fence. */
  reg [7:0] dw_rq_inflight_count;
 reg [31:0] source_stall_count,bank_conflict_count,final_commit_count;
 reg [31:0] pw_rq_overlap_count,dw_rq_overlap_count;
 reg [8:0] expand_written_tiles;

 /* Persistent v6 A/B diagnostics.  These counters are intentionally
  * aggregate-only: they quantify pool service, mode fences, context waits,
  * and state occupancy without perturbing the datapath or printing traces. */
 reg [31:0] diag_pool_pw_accept_count,diag_pool_rq_accept_count;
 reg [31:0] diag_pool_total_input_count,diag_pool_total_output_count;
 reg [31:0] diag_pool_conservation_error_count;
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
 integer v6_bank_i,v6_read_y,v6_read_x,v6_read_p,v6_read_row,v6_bank_sel;
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
 wire [7:0] dw_src_req_pixel_idx; wire [3:0] dw_src_req_tap_idx; wire [31:0] dw_src_req_metadata;
 wire dw_src_resp_valid; wire dw_src_resp_ready; wire [127:0] dw_src_resp_data;
 wire dw_tile_resp_valid; wire [127:0] dw_tile_resp_data;
 wire dw_mem_req_valid; wire dw_mem_req_ready; wire [10:0] dw_mem_req_addr;
 wire dw_mem_resp_valid; wire dw_mem_resp_ready; wire [127:0] dw_mem_resp_data;
 wire dw_adapter_protocol_error;
 wire dw_out_valid,dw_out_last; wire [7:0] dw_out_pixel_idx;
 wire signed [511:0] dw_raw_psum;

 assign cfg_ready=rst_n&&(state==S_IDLE)&&!done_valid; assign start_ready=cfg_ready;
 assign busy=(state!=S_IDLE)&&(state!=S_DONE); assign scratch0_state=bank0_state_reg; assign scratch1_state=bank1_state_reg;
 assign active_epoch=epoch_reg;
 /* The legacy byte port remains present for interface compatibility, but v6
  * completion/output are driven by the worded bank service below. */
 assign out_valid=1'b0; assign out_index=16'd0; assign out_data=8'sd0;
 assign word_out_valid=rst_n && (word_drain_slot ? word_bank_valid1 : word_bank_valid0);
 assign word_out_data=word_drain_slot ? word_bank1[word_drain_index] : word_bank0[word_drain_index];
 assign word_out_index=word_global_index;
 assign word_out_epoch=epoch_reg;
   wire cfg_fire=cfg_valid&&cfg_ready;
   wire start_fire=start_valid&&start_ready;

    wire v6_ded_activation_rd_ready = pw_project ?
                                      v6_scratch1_rd_ready : v6_input_rd_ready;
    wire v6_ded_activation_resp_valid = pw_project ?
                                        v6_scratch1_rd_resp_valid :
                                        v6_input_rd_resp_valid;
   /* The pair modules own the request/response coupling.  Their request
    * ready is the conjunction of both physical RAM ports; no K advances until
    * that conjunction fires. */
   edgembconv_hwacandidate_d4_vstream_v6_fetch_pair #(.ACT_WIDTH(256),.WGT_WIDTH(128))
   u_ded_fetch_pair(
     .clk(clk),.rst_n(rst_n),.req_valid(ded_pair_req_valid),
     .req_ready(ded_pair_req_ready),.req_desc(ded_req_desc),
     .act_req_valid(ded_act_req_valid),.act_req_ready(v6_ded_activation_rd_ready),
     .act_req_desc(ded_act_req_desc),.wgt_req_valid(ded_wgt_req_valid),
     .wgt_req_ready(v6_ded_weight_rd_ready),.wgt_req_desc(ded_wgt_req_desc),
     .act_resp_valid(v6_ded_activation_resp_valid),.act_resp_ready(ded_act_resp_ready),
     .act_resp_data(pw_project ? v6_scratch1_rd_data_vec : {192'd0,v6_input_rd_data_vec}),
     .act_resp_desc(pw_project ? v6_scratch1_rd_resp_desc : v6_input_rd_resp_desc),
     .wgt_resp_valid(v6_ded_weight_rd_resp_valid),.wgt_resp_ready(ded_wgt_resp_ready),
      .wgt_resp_data(v6_ded_weight_rd_data),.wgt_resp_desc(v6_ded_weight_rd_resp_desc),
      .pair_resp_valid(ded_pair_resp_valid),
       .pair_resp_ready(ded_pw_stage_in_ready),
      .pair_act_data(ded_pair_act_data),.pair_wgt_data(ded_pair_wgt_data),
      .pair_resp_desc(ded_pair_resp_desc),.descriptor_mismatch(ded_descriptor_mismatch));

    edgembconv_hwacandidate_d4_vstream_v6_pw_operand_stage #(.ACT_WIDTH(256),.WGT_WIDTH(128))
    u_ded_pw_operand_stage(
      .clk(clk),.rst_n(rst_n),.in_valid(ded_pair_resp_valid),
      .in_ready(ded_pw_stage_in_ready),.in_act_data(ded_pair_act_data),
      .in_wgt_data(ded_pair_wgt_data),.in_desc(ded_pair_resp_desc),
      .out_valid(ded_pw_stage_out_valid),.out_ready(pw112_ready),
      .out_act_data(ded_pw_stage_act_data),.out_wgt_data(ded_pw_stage_wgt_data),
      .out_desc(ded_pw_stage_resp_desc));

   edgembconv_hwacandidate_d4_vstream_v6_fetch_pair #(.ACT_WIDTH(32),.WGT_WIDTH(128))
   u_pool_fetch_pair(
     .clk(clk),.rst_n(rst_n),.req_valid(pool_pair_req_valid),
     .req_ready(pool_pair_req_ready),.req_desc(pool_req_desc),
     .act_req_valid(pool_act_req_valid),.act_req_ready(v6_scratch1_pool_rd_ready),
     .act_req_desc(pool_act_req_desc),.wgt_req_valid(pool_wgt_req_valid),
     .wgt_req_ready(v6_pool_weight_rd_ready),.wgt_req_desc(pool_wgt_req_desc),
     .act_resp_valid(v6_scratch1_pool_rd_resp_valid),.act_resp_ready(pool_act_resp_ready),
     .act_resp_data(v6_scratch1_pool_rd_data),.act_resp_desc(v6_scratch1_pool_rd_resp_desc),
     .wgt_resp_valid(v6_pool_weight_rd_resp_valid),.wgt_resp_ready(pool_wgt_resp_ready),
     .wgt_resp_data(v6_pool_weight_rd_data),.wgt_resp_desc(v6_pool_weight_rd_resp_desc),
     .pair_resp_valid(pool_pair_resp_valid),
      .pair_resp_ready(pool_ready && !rq_offer),
     .pair_act_data(pool_pair_act_data),.pair_wgt_data(pool_pair_wgt_data),
     .pair_resp_desc(pool_pair_resp_desc),.descriptor_mismatch(pool_descriptor_mismatch));

   wire v6_ded_pair_request_offer = ded_pair_req_valid && ded_pair_req_ready;
   wire v6_pool_pair_request_offer = pool_pair_req_valid && pool_pair_req_ready;

   /* Bank service descriptors.  The expand PW tile uses spatial banks 0..6
   * for the dedicated seven-pixel pass and bank 7 for the shared eighth
   * pixel.  Project uses the same one-port-per-spatial-bank schedule on
   * scratch1.  No duplicate scratch1 read copies are instantiated. */
  always @* begin
    v6_input_rd_valid=8'd0;
    v6_input_rd_addr_vec=88'd0;
    v6_scratch1_rd_valid=8'd0;
     v6_scratch1_rd_addr_vec=64'd0;
     v6_input_rd_desc=16'd0;
     v6_scratch1_rd_desc=16'd0;
     v6_scratch1_pool_rd_valid=1'b0;
     v6_scratch1_pool_rd_addr=8'd0;
     v6_scratch1_pool_rd_desc=16'd0;
      v6_ded_weight_rd_valid=ded_wgt_req_valid;
      v6_ded_weight_project=pw_project;
      v6_ded_weight_group=ded_group;
      v6_ded_weight_k=pw_req_k;
      v6_ded_weight_rd_desc=ded_wgt_req_desc;
      v6_pool_weight_rd_valid=pool_wgt_req_valid;
      v6_pool_weight_project=pw_project;
      v6_pool_weight_group=pw_project ? ded_group :
                           (pool_pw_slot ? ctx_group1 : ctx_group0);
      v6_pool_weight_k=pool_req_k;
      v6_pool_weight_rd_desc=pool_wgt_req_desc;
      v6_input_rd_valid=8'd0;
      v6_scratch1_rd_valid=8'd0;
      v6_scratch1_pool_rd_valid=1'b0;
   if (!pw_project) begin
       if (ded_act_req_valid) begin
         if (pw_project) v6_scratch1_rd_desc=ded_act_req_desc;
         else v6_input_rd_desc=ded_act_req_desc;
        if (ded_raw_phase) begin
          v6_input_rd_valid[7]=1'b1;
          v6_input_rd_addr_vec[7*11 +: 11]=
            ((ded_y*4 + ((ded_x+7)>>3))*16) + pw_req_k;
        end else begin
          for (v6_read_p=0;v6_read_p<7;v6_read_p=v6_read_p+1) begin
            v6_bank_sel=(ded_x+v6_read_p)&7;
            v6_input_rd_valid[v6_bank_sel]=1'b1;
            v6_input_rd_addr_vec[v6_bank_sel*11 +: 11]=
              ((ded_y*4 + ((ded_x+v6_read_p)>>3))*16) + pw_req_k;
          end
        end
      end
      /* v6 expand has no concurrent pool PW producer; retain this branch for
       * the explicit bank-7 contract if a future schedule enables one. */
      /* Stop the physical read stream with the final accepted K token.  The
       * pool input may remain active until its arithmetic result drains, so
       * testing only pool_pw_active would keep issuing unconsumed reads after
       * K15.  Those speculative reads can leave a response queued across the
       * RQ fence and become stale data for the next context's K0. */
        if (pool_act_req_valid && (pool_req_k <= 6'd15)) begin
         v6_input_rd_desc=pool_act_req_desc;
        v6_input_rd_valid[7]=1'b1;
        v6_input_rd_addr_vec[7*11 +: 11]=
          (((pool_pw_slot?ctx_y1:ctx_y0)*4 +
            (((pool_pw_slot?ctx_x1:ctx_x0)+7)>>3))*16) + pool_req_k;
      end
    end else begin
       if (ded_act_req_valid) begin
         v6_scratch1_rd_desc=ded_act_req_desc;
        for (v6_read_p=0;v6_read_p<7;v6_read_p=v6_read_p+1) begin
          v6_bank_sel=(ded_x+v6_read_p)&7;
          v6_scratch1_rd_valid[v6_bank_sel]=1'b1;
          v6_scratch1_rd_addr_vec[v6_bank_sel*8 +: 8]=
            (((ded_y*16 + ded_x + v6_read_p)>>3)*8) +
            (pw_req_k>>2);
        end
      end
      /* See the expand-side comment above: pool_pw_active lasts through the
       * arithmetic drain, while source requests must end at K31. */
       if (pool_act_req_valid && (pool_req_k <= 6'd31)) begin
         v6_scratch1_pool_rd_desc=pool_act_req_desc;
        /* Producer and pool share the same project descriptor by contract;
         * bank 7 is consequently the dedicated seventh-bank owner. */
        v6_scratch1_pool_rd_valid=1'b1;
        v6_scratch1_pool_rd_addr=
          (((ded_y*16 + ded_x + 7)>>3)*8) +
          (pool_req_k>>2);
      end
    end
  end

  /* The three activation ports are decoupled synchronous reads.  A response
   * is held by the storage until its consumer can accept it; when the
   * response is consumed, the same edge may launch the next bank request. */
  always @* begin
     v6_input_rd_resp_ready = (!pw_project) && ded_act_resp_ready;
     v6_scratch1_rd_resp_ready = pw_project && ded_act_resp_ready;
     v6_scratch1_pool_rd_resp_ready = pool_act_resp_ready;
     v6_ded_weight_rd_resp_ready = ded_wgt_resp_ready;
     v6_pool_weight_rd_resp_ready = pool_wgt_resp_ready;
     v6_scratch0_rd_resp_ready = dw_mem_resp_ready;
  end

  wire v6_scratch0_write_fire=(state==S_E_RQ)&&pool_valid&&pool_mode_out;
  wire [10:0] v6_scratch0_write_row=((((ctx_slot_rq?ctx_y1:ctx_y0)*32)+
                                  (ctx_slot_rq?ctx_x1:ctx_x0)+
                                  (pool_metadata[7:0]/16))*2)+
                                  (ctx_slot_rq?ctx_group1:ctx_group0);
  wire [3:0] v6_scratch0_write_bank=pool_metadata[3:0];
  wire v6_scratch1_write_fire=(state==S_DW_RQ)&&pool_valid&&pool_mode_out;
  wire [10:0] v6_scratch1_write_index=((((dw_fifo_y[pool_metadata[13:8]]*16)+
                                    dw_fifo_x[pool_metadata[13:8]])>>3)*8)+
                                    (dw_fifo_group[pool_metadata[13:8]]?11'd4:11'd0)+
                                    (pool_metadata[7:0]/4);
  always @* begin
    /* The external service throttle is part of the physical request
     * acceptance contract.  Gate the bank-side valid as well as the adapter's
     * ready; otherwise a held adapter request would be accepted by the bank
     * while mem_req_ready was low, leaving an untagged response queued behind
     * the still-unsent adapter slot. */
    v6_scratch0_rd_valid=dw_mem_req_valid && scratch_read_ready;
    /* The source tile may present the next request while the previous
     * response is being consumed on the same edge.  The response data must
     * therefore address the saved request, just as the pre-bank v5 service
     * did; using the live request address here retags every response with the
     * following tap.  When no response is pending the live address is only a
     * look-ahead for the next request. */
    /* The bank owns the response register, so its read address must stay on
     * the live request when a response and the following request cross the
     * same edge.  The old async array selected dw_req_addr_reg here merely to
     * keep a combinational response tagged to the previous request; doing so
     * with synchronous BRAM would launch a duplicate previous address. */
    v6_scratch0_rd_addr=dw_mem_req_addr*2+(dw_job_group?11'd1:11'd0);
    v6_scratch0_wr_valid_vec=16'd0;
    v6_scratch0_wr_addr=v6_scratch0_write_row;
    v6_scratch0_wr_data_vec=128'd0;
    if (v6_scratch0_write_fire) begin
      /* Each RQ result is four adjacent bytes.  They land in four distinct
       * channel banks at the same pixel/group row. */
      for (v6_bank_i=0; v6_bank_i<4; v6_bank_i=v6_bank_i+1) begin
        v6_scratch0_wr_valid_vec[(pool_metadata[3:2]*4)+v6_bank_i]=1'b1;
        v6_scratch0_wr_data_vec[((pool_metadata[3:2]*4)+v6_bank_i)*8 +: 8]=
          pool_rq_result[v6_bank_i*8 +: 8];
      end
    end
    v6_scratch1_wr_valid=v6_scratch1_write_fire;
    v6_scratch1_wr_bank=dw_fifo_x[pool_metadata[13:8]][2:0];
    v6_scratch1_wr_addr=v6_scratch1_write_index[7:0];
    v6_scratch1_wr_data=pool_rq_result;
  end

  /* Activation payloads use the standalone synchronous bank boundary.  The
   * legacy common bank remains instantiated only for the deferred PW weight
   * stores; its activation generators are disabled so synthesis cannot count
   * a second copy of input/scratch memory. */
  edgembconv_hwacandidate_d4_vstream_v6_banked_storage u_v6_banked_storage(
    .clk(clk),.rst_n(rst_n),.cfg_valid(cfg_fire),.cfg_kind(cfg_kind),
    .cfg_addr(cfg_addr),.cfg_data(cfg_data),
     .input_rd_valid(v6_input_rd_valid),.input_rd_addr_vec(v6_input_rd_addr_vec),
     .input_rd_desc(v6_input_rd_desc),
     .input_rd_ready(v6_input_rd_ready),.input_rd_resp_ready(v6_input_rd_resp_ready),
     .input_rd_data_vec(v6_input_rd_data_vec),.input_rd_resp_desc(v6_input_rd_resp_desc),
     .input_rd_resp_valid(v6_input_rd_resp_valid),
    .scratch0_rd_valid(v6_scratch0_rd_valid),.scratch0_rd_addr(v6_scratch0_rd_addr),
    .scratch0_rd_ready(v6_scratch0_rd_ready),.scratch0_rd_resp_ready(v6_scratch0_rd_resp_ready),
    .scratch0_rd_data(v6_scratch0_rd_data),.scratch0_rd_resp_valid(v6_scratch0_rd_resp_valid),
    .scratch0_wr_valid_vec(v6_scratch0_wr_valid_vec),
    .scratch0_wr_addr(v6_scratch0_wr_addr),.scratch0_wr_data_vec(v6_scratch0_wr_data_vec),
     .scratch1_rd_valid(v6_scratch1_rd_valid),.scratch1_rd_addr_vec(v6_scratch1_rd_addr_vec),
     .scratch1_rd_desc(v6_scratch1_rd_desc),
     .scratch1_rd_ready(v6_scratch1_rd_ready),.scratch1_rd_resp_ready(v6_scratch1_rd_resp_ready),
     .scratch1_rd_data_vec(v6_scratch1_rd_data_vec),.scratch1_rd_resp_desc(v6_scratch1_rd_resp_desc),
     .scratch1_rd_resp_valid(v6_scratch1_rd_resp_valid),
     .scratch1_pool_rd_valid(v6_scratch1_pool_rd_valid),.scratch1_pool_rd_addr(v6_scratch1_pool_rd_addr),
     .scratch1_pool_rd_desc(v6_scratch1_pool_rd_desc),
     .scratch1_pool_rd_ready(v6_scratch1_pool_rd_ready),.scratch1_pool_rd_resp_ready(v6_scratch1_pool_rd_resp_ready),
     .scratch1_pool_rd_data(v6_scratch1_pool_rd_data),.scratch1_pool_rd_resp_desc(v6_scratch1_pool_rd_resp_desc),
     .scratch1_pool_rd_resp_valid(v6_scratch1_pool_rd_resp_valid),
    .scratch1_wr_valid(v6_scratch1_wr_valid),.scratch1_wr_bank(v6_scratch1_wr_bank),
    .scratch1_wr_addr(v6_scratch1_wr_addr),.scratch1_wr_data(v6_scratch1_wr_data));

  edgembconv_hwacandidate_d4_vstream_v6_common_bank #(.SYNC_READ(1),.ENABLE_ACTIVATION_BANKS(0)) u_v6_common_bank(
    .clk(clk),.rst_n(rst_n),.cfg_valid(cfg_fire),.cfg_kind(cfg_kind),
    .cfg_addr(cfg_addr),.cfg_data(cfg_data),
    .input_rd_valid(8'd0),.input_rd_addr_vec(88'd0),
    .input_rd_data_vec(),.input_rd_resp_valid(),
    .scratch0_rd_valid(1'b0),.scratch0_rd_addr(11'd0),
    .scratch0_rd_data(),.scratch0_rd_resp_valid(),
    .scratch0_wr_valid_vec(16'd0),.scratch0_wr_addr(11'd0),.scratch0_wr_data_vec(128'd0),
    .scratch1_rd_valid(8'd0),.scratch1_rd_addr_vec(64'd0),
    .scratch1_rd_data_vec(),.scratch1_rd_resp_valid(),
    .scratch1_wr_valid(1'b0),.scratch1_wr_bank(3'd0),
    .scratch1_wr_addr(8'd0),.scratch1_wr_data(32'd0),
     .ded_weight_rd_valid(v6_ded_weight_rd_valid),.ded_weight_project(v6_ded_weight_project),
      .ded_weight_group(v6_ded_weight_group),.ded_weight_k(v6_ded_weight_k),
      .ded_weight_rd_desc(v6_ded_weight_rd_desc),
      .ded_weight_rd_ready(v6_ded_weight_rd_ready),
      .ded_weight_rd_resp_ready(v6_ded_weight_rd_resp_ready),
      .ded_weight_rd_data(v6_ded_weight_rd_data),.ded_weight_rd_resp_desc(v6_ded_weight_rd_resp_desc),
      .ded_weight_rd_resp_valid(v6_ded_weight_rd_resp_valid),
      .pool_weight_rd_valid(v6_pool_weight_rd_valid),.pool_weight_project(v6_pool_weight_project),
      .pool_weight_group(v6_pool_weight_group),.pool_weight_k(v6_pool_weight_k),
      .pool_weight_rd_desc(v6_pool_weight_rd_desc),
      .pool_weight_rd_ready(v6_pool_weight_rd_ready),
      .pool_weight_rd_resp_ready(v6_pool_weight_rd_resp_ready),
      .pool_weight_rd_data(v6_pool_weight_rd_data),.pool_weight_rd_resp_desc(v6_pool_weight_rd_resp_desc),
      .pool_weight_rd_resp_valid(v6_pool_weight_rd_resp_valid));

  /* The DW raw result is a real sixteen-bank circular FIFO.  Metadata remains
   * in the scheduler because it is only a narrow descriptor; the 512-bit
   * arithmetic payload is written/read through the banked RAM boundary. */
  edgembconv_hwacandidate_d4_vstream_v6_raw_fifo u_dw_raw_fifo(
    .clk(clk),.rst_n(rst_n),
    .push_valid(dw_active && dw_out_valid),.push_ready(dw_raw_push_ready),
    .push_data(dw_raw_psum),
    /* Do not replace a response on the same edge that the scheduler captures
     * it.  The scheduler has one registered raw-vector holding register, so
     * allowing a simultaneous FIFO read would leave the replacement response
     * valid while dw_raw_loaded is already set; that response could then
     * never be consumed and the FIFO would remain permanently occupied.  A
     * one-cycle read bubble is the deliberate elastic boundary here. */
    .read_valid((state==S_DW_RQ) && rq_active && !dw_raw_loaded &&
                !dw_raw_resp_valid),
    .read_ready(dw_raw_read_ready),.resp_valid(dw_raw_resp_valid),
    .resp_ready(dw_raw_resp_ready),.resp_data(dw_raw_resp_data),
    .pop_valid(dw_fifo_pop),.pop_ready(dw_raw_pop_ready),
    .fifo_count(dw_fifo_count),.fifo_head(dw_fifo_head),.fifo_tail(dw_fifo_tail));

  edgembconv_hwacandidate_d4_vstream_v2_pw112 u_pw112(
   .clk(clk),.rst_n(rst_n),.valid_in(ded_pw_stage_out_valid),.ready_in(pw112_ready),
   .first_k(pw_first),.last_k(pw_last),.k_idx(pw_k_idx),.pixel_mask(pw_pix_mask[6:0]),.cout_mask(pw_cout_mask),
   .act_vec(pw_act7),.wgt_vec(pw_wgt),.ready_out(1'b1),.valid_out(pw112_valid),.psum_out(pw112_psum),.lane_mask_out(pw112_mask));

 /* The shared pool accepts exactly one selected transaction per cycle.  v5
  * presented both offers while deriving mode from rq_active; during an
  * overlap that made a PW offer look like an RQ transaction.  v6 gives RQ
  * priority while it is actively offered, and holds PW until the RQ burst
  * has been accepted.  The pool's own mode fence then guarantees that a mode
  * switch can happen only after the old pipeline has drained. */
  wire v6_input_rd_request_fire=(|v6_input_rd_valid)&&v6_input_rd_ready;
  wire v6_scratch1_rd_request_fire=(|v6_scratch1_rd_valid)&&v6_scratch1_rd_ready;
  wire v6_scratch1_pool_rd_request_fire=v6_scratch1_pool_rd_valid&&
                                        v6_scratch1_pool_rd_ready;
  /* A PW fetch is one transaction across activation and weight stores.  The
   * scheduler advances its request K only after both request-ready signals
   * accepted the same producer descriptor. */
  wire v6_pw_request_fire=v6_ded_pair_request_offer;
  /* Pair responses are consumed by the operand stage.  The PW island sees the
   * stage's registered output one cycle later; both sides remain II=1. */
  wire pool_pw_offer = pool_pw_active &&
                       (pool_pw_k <= (pw_project?6'd31:6'd15));
  wire rq_offer = rq_active &&
                  ((state==S_DW_RQ) ?
                   ((rq_base<=12) && dw_raw_loaded) :
                   (rq_base<=124));
 wire pool_selected_rq = rq_offer;
    wire pool_selected_pw = !rq_offer && pool_pw_offer && pw_project &&
                            pool_pair_resp_valid && pool_ready;
 assign pool_mode_rq = pool_selected_rq;
 assign pool_valid_in = pool_selected_rq || pool_selected_pw;
 wire pool_input_fire = pool_valid_in && pool_ready;
 assign pool_pw_act = pw_act_pool; assign pool_pw_wgt = pool_wgt;
 edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin u_pool(
   .clk(clk),.rst_n(rst_n),.mode_rq(pool_mode_rq),.valid_in(pool_valid_in),.ready_in(pool_ready),
   .rq_acc_vec(rq_acc),.rq_multiplier_vec(rq_mult),.rq_shift_vec(rq_shift),.rq_zero_point_vec(rq_zp),
   .rq_min_vec(rq_min),.rq_max_vec(rq_max),.pw_act_vec(pool_pw_act),.pw_wgt_vec(pool_pw_wgt),.metadata_in(pool_selected_rq?rq_metadata:pool_pw_metadata),
   .valid_out(pool_valid),.ready_out(1'b1),.mode_rq_out(pool_mode_out),.pw_product_vec(pool_pw_product),
   .rq_product_vec(pool_rq_product),.rq_result_vec(pool_rq_result),.metadata_out(pool_metadata));

 edgembconv_hwacandidate_d4_dw16_stream_tile u_dw(
   .clk(clk),.rst_n(rst_n),.cfg_valid(dw_cfg_valid),.cfg_ready(dw_cfg_ready),.cfg_kind(0),.cfg_addr(dw_cfg_addr),.cfg_data(dw_cfg_data),
   .start_valid(dw_start_valid),.start_ready(dw_start_ready),.start_in_w(32),.start_in_h(32),.start_out_w(16),.start_out_h(16),.start_stride(2),
   .start_tile_x({3'd0,dw_job_x}),.start_tile_y({3'd0,dw_job_y}),.start_tile_w(DW_TILE_W),.start_tile_h(DW_TILE_H),.start_channel_base(dw_job_group?16:0),.start_channel_mask(16'hffff),
   .start_padding_value(0),.start_output_zero_point(0),.start_activation_min(-2147483647),.start_activation_max(2147483647),.start_epoch(epoch_reg),.start_metadata({dw_job_group,dw_job_y,dw_job_x}),
   .src_req_valid(dw_src_req_valid),.src_req_ready(dw_src_req_ready),.src_req_addr(dw_src_req_addr),.src_req_pixel_idx(dw_src_req_pixel_idx),.src_req_tap_idx(dw_src_req_tap_idx),.src_req_first_tap(),.src_req_last_tap(),.src_req_metadata(dw_src_req_metadata),
   .src_resp_valid(dw_src_resp_valid),.src_resp_ready(dw_src_resp_ready),.src_resp_data(dw_src_resp_data),.out_ready(dw_fifo_count<DW_FIFO_DEPTH),.out_valid(dw_out_valid),.out_data_vec(),.out_raw_psum_vec(dw_raw_psum),.out_pixel_idx(dw_out_pixel_idx),.out_channel_base(),.out_lane_mask(),.out_first(),.out_last(dw_out_last),.out_metadata(),.done_valid(),.done_ready(1),.done_epoch(),.busy(),.cycle_count(),.tap_count(),.source_word_count(),.source_stall_count(),.output_stall_count(),.protocol_errors());

 assign dw_cfg_valid=(state==S_DW_CFG); assign dw_cfg_addr=dw_cfg_idx; assign dw_cfg_data=dw_weight_mem[(dw_cfg_group?144:0)+dw_cfg_idx];
 assign dw_start_valid=dw_active && !dw_req_pending && (dw_fifo_count<DW_FIFO_DEPTH);

 /* v6-only registered DW request boundary.  The tile-facing protocol remains
  * one-outstanding; only the physical scratch0 request is decoupled and held
  * in flops so BRAM enable/address no longer depend on the live tile cursors. */
 edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter u_dw_req_adapter(
   .clk(clk),.rst_n(rst_n),
   .enable(dw_active && (dw_fifo_count<DW_FIFO_DEPTH)),
   .command_start(dw_start_valid&&dw_start_ready),
   .in_req_valid(dw_src_req_valid),.in_req_ready(dw_src_req_ready),
   .in_req_addr(dw_src_req_addr),.in_req_pixel_idx(dw_src_req_pixel_idx),
   .in_req_tap_idx(dw_src_req_tap_idx),.in_req_metadata(dw_src_req_metadata),
    .in_resp_valid(dw_tile_resp_valid),.in_resp_ready(dw_src_resp_ready),
    .in_resp_data(dw_tile_resp_data),
   .mem_req_valid(dw_mem_req_valid),.mem_req_ready(dw_mem_req_ready),
   .mem_req_addr(dw_mem_req_addr),.service_ready(scratch_read_ready),
   .mem_resp_valid(dw_mem_resp_valid),.mem_resp_ready(dw_mem_resp_ready),
   .mem_resp_data(dw_mem_resp_data),.protocol_error(dw_adapter_protocol_error));

   assign dw_mem_req_ready=scratch_read_ready && v6_scratch0_rd_ready;
   assign dw_mem_resp_valid=v6_scratch0_rd_resp_valid;
   assign dw_mem_resp_data=v6_scratch0_rd_data;
  /* The adapter owns the tile-facing response boundary.  Physical scratch
   * response signals above are inputs to it; do not bypass the adapter here. */
  assign dw_src_resp_valid=dw_tile_resp_valid;
  assign dw_src_resp_data=dw_tile_resp_data;

 /* Current PW operands.  One horizontal 8-pixel tile is explicit; y/x/group
  * counters advance without an inferred divide/modulo datapath. */
  always @* begin
        pw_act7=0;pw_act_pool=0;pw_wgt=0;pool_wgt=0;pw_pix_mask=ded_stage_pass?8'h01:8'h7f;pw_cout_mask=16'hffff;pw_first=ded_stage_first;
       pw_last=ded_stage_last;pw_k_idx=ded_stage_k;pw_metadata={ded_pw_stage_resp_desc[10],ded_pw_stage_resp_desc[7:2],ded_pw_stage_resp_desc[9]};
   /* For project production the dedicated island and shared pool operate on
    * the same producer descriptor.  p_* is the independent consumer head and
    * may already point at an older context while this raw lane is captured. */
    pool_pw_metadata={pool_fetch_project,pool_fetch_y,pool_fetch_x,pool_fetch_group,pool_fetch_k};
     /* Producer coordinates are always carried by ded_*; p_* remains the
      * independent consumer descriptor while a project RQ burst is active. */
     ky=ded_y;kx=ded_x;kg=ded_group;
    /* The final response may still be resident in the operand stage after
     * ded_active is cleared on its accepting edge.  Include stage validity in
     * this guard so that the last token's registered payload is still driven
     * into u_pw112 on the following edge. */
    if(ded_active||pool_pw_active||ded_pw_stage_out_valid) begin
      /* The common bank returns seven independently addressed spatial banks.
       * During the expand raw pass only bank 7 is valid and is replicated by
       * the one-lane pixel mask; the inactive lanes are deterministic zero. */
       if (ded_pw_stage_resp_desc[10]) begin
           pw_act7[0*8 +:8]=ded_pw_stage_act_data[0*32 + (ded_stage_k[1:0]*8) +:8];
           pw_act7[1*8 +:8]=ded_pw_stage_act_data[1*32 + (ded_stage_k[1:0]*8) +:8];
           pw_act7[2*8 +:8]=ded_pw_stage_act_data[2*32 + (ded_stage_k[1:0]*8) +:8];
           pw_act7[3*8 +:8]=ded_pw_stage_act_data[3*32 + (ded_stage_k[1:0]*8) +:8];
           pw_act7[4*8 +:8]=ded_pw_stage_act_data[4*32 + (ded_stage_k[1:0]*8) +:8];
           pw_act7[5*8 +:8]=ded_pw_stage_act_data[5*32 + (ded_stage_k[1:0]*8) +:8];
           pw_act7[6*8 +:8]=ded_pw_stage_act_data[6*32 + (ded_stage_k[1:0]*8) +:8];
           pw_act_pool={16{pool_pair_act_data[(pool_resp_k[1:0]*8) +:8]}};
       end else begin
          pw_act7[0*8 +:8]=ded_stage_pass ? ded_pw_stage_act_data[7*8 +:8] : ded_pw_stage_act_data[0*8 +:8];
          pw_act7[1*8 +:8]=ded_stage_pass ? ded_pw_stage_act_data[7*8 +:8] : ded_pw_stage_act_data[1*8 +:8];
          pw_act7[2*8 +:8]=ded_stage_pass ? ded_pw_stage_act_data[7*8 +:8] : ded_pw_stage_act_data[2*8 +:8];
          pw_act7[3*8 +:8]=ded_stage_pass ? ded_pw_stage_act_data[7*8 +:8] : ded_pw_stage_act_data[3*8 +:8];
          pw_act7[4*8 +:8]=ded_stage_pass ? ded_pw_stage_act_data[7*8 +:8] : ded_pw_stage_act_data[4*8 +:8];
          pw_act7[5*8 +:8]=ded_stage_pass ? ded_pw_stage_act_data[7*8 +:8] : ded_pw_stage_act_data[5*8 +:8];
          pw_act7[6*8 +:8]=ded_stage_pass ? ded_pw_stage_act_data[7*8 +:8] : ded_pw_stage_act_data[6*8 +:8];
          pw_act_pool={16{pool_pair_act_data[0*8 +:8]}};
        end
        pw_wgt=ded_pw_stage_wgt_data;
        pool_wgt=pool_pair_wgt_data;
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
         if(state==S_DW_RQ) begin param_idx=160+(dw_fifo_group[dw_issue_slot]?16:0)+(rq_flat%16);rq_acc[rq_q*32 +:32]=dw_raw_capture_q[(rq_flat)*32 +:32];rq_min[rq_q*32 +:32]=0;rq_max[rq_q*32 +:32]=127;end
       else begin
         param_idx=(pw_project?96:64)+
                   (pw_project?(p_group?16:0):
                    (ctx_slot_rq?(ctx_group1?16:0):(ctx_group0?16:0)))+
                   (rq_flat%16);
         /* The dedicated 112-lane result and the sixteen appended pool lanes
          * retain the original packed ordering. */
         if(rq_flat<112) begin
           if(ctx_slot_rq) rq_acc[rq_q*32 +:32]=ctx_bus1[rq_flat*32 +:32];
           else rq_acc[rq_q*32 +:32]=ctx_bus0[rq_flat*32 +:32];
         end else begin
           if(ctx_slot_rq) rq_acc[rq_q*32 +:32]=ctx_raw1[rq_flat];
           else rq_acc[rq_q*32 +:32]=ctx_raw0[rq_flat];
         end
         rq_min[rq_q*32 +:32]=pw_project?-128:0;
         rq_max[rq_q*32 +:32]=127;
       end
       rq_acc[rq_q*32 +:32]=rq_acc[rq_q*32 +:32]+bias_mem[param_idx];rq_mult[rq_q*32 +:32]=multiplier_mem[param_idx];rq_shift[rq_q*6 +:6]=shift_mem[param_idx][5:0];
       end
   end
 end

 wire context_rq_ready=(ctx_slot_rq?ctx_ded_ready1&&ctx_pool_ready1:ctx_ded_ready0&&ctx_pool_ready0);
 wire p_slot0_ready=ctx_ded_ready0&&ctx_pool_ready0;
 wire p_slot1_ready=ctx_ded_ready1&&ctx_pool_ready1;
 wire p_wait_context_ready=p_wait_slot?p_slot1_ready:p_slot0_ready;
 wire p_wait_bank_ready=!p_wait_needs_bank || (word_write_slot ? !word_bank_valid1 : !word_bank_valid0);
   /* The response descriptor may legitimately name K-1 while the request
    * side has already advanced to K for an II=1 replacement.  The pair module
    * has already proved activation/weight identity; consume the tagged pair
    * itself rather than comparing it to the live next-request descriptor. */
   wire ded_fire=ded_active&&ded_pw_stage_in_fire;
 /* The PW island has one cycle of output latency.  Stop offering a new
  * token on the edge that accepts the last K value; otherwise the island's
  * ready signal reopens while the last result is being captured and a stale
  * extra token is issued into the following scheduler state. */
   wire ded_last_fire=ded_fire && ded_resp_last;
 wire pool_pw_fire=pool_input_fire&&pool_selected_pw;
 wire pool_rq_fire=pool_input_fire&&pool_selected_rq;
 wire pw_and_rq_active=(ded_active&&rq_active)||(pool_pw_active&&rq_active);
  wire dw_fifo_push=dw_active&&dw_out_valid&&dw_raw_push_ready;
  /* Once the four RQ inputs for a raw vector have been accepted, the
   * registered-input pool owns all of those operands.  Release that vector's
   * FIFO slot immediately so the next raw result can be prefetched while the
   * current pool pipeline drains.  Retired-output accounting remains tied to
   * dw_slot_retire below; the storage lifetime and the arithmetic lifetime are
   * intentionally separate. */
  wire dw_raw_release=(state==S_DW_RQ) && pool_rq_fire &&
                      (rq_base==8'd12) && dw_raw_loaded &&
                      dw_raw_pop_ready;
  wire dw_fifo_pop=dw_raw_release;
 wire word_out_fire=word_out_valid&&word_out_ready;
 wire dw_rq_output= (state==S_DW_RQ)&&pool_valid&&pool_mode_out;
 wire dw_slot_retire=dw_rq_output&&(dw_slot_resp_count[pool_metadata[13:8]]==3);
 wire diag_pool_scope=(state==S_E_BOTH)||(state==S_E_RQ)||(state==S_E_POOL)||
                      (state==S_DW_RQ)||(state==S_P_BOTH)||(state==S_P_WAIT)||
                      (state==S_P_RQ);
 wire diag_pool_input_fire=pool_input_fire;

 always @(posedge clk) begin
   if(!rst_n) begin
     state<=S_IDLE;done_valid<=0;done_epoch<=0;epoch_reg<=0;bank0_state_reg<=FREE;bank1_state_reg<=FREE;output_cursor<=0;
     word_bank_valid0<=0;word_bank_valid1<=0;word_write_slot<=0;word_drain_slot<=0;word_drain_index<=0;word_global_index<=0;p_bank_wait<=0;
     cycle_count<=0;pw_mac_count<=0;dw_mac_count<=0;overlap_cycles<=0;protocol_errors<=0;pw_project<=0;pw_slot<=0;pw_k<=0;pw_req_k<=0;ded_active<=0;ded_slot<=0;ded_raw_phase<=0;pool_pw_active<=0;pool_pw_slot<=0;pool_pw_k<=0;pool_req_k<=0;rq_active<=0;rq_base<=0;ctx_slot_rq<=0;
      e_y<=0;e_x<=0;e_group<=0;next_y<=0;next_x<=8;next_group<=0;ded_y<=0;ded_x<=0;ded_group<=0;ctx_bus0<=0;ctx_bus1<=0;e_done_tiles<=0;expand_written_tiles<=0;ctx_ded_ready0<=0;ctx_ded_ready1<=0;ctx_pool_ready0<=0;ctx_pool_ready1<=0;
      p_y<=0;p_x<=0;p_group<=0;p_next_y<=0;p_next_x<=0;p_next_group<=0;p_next_valid<=0;p_wait_next<=0;p_wait_slot<=0;p_wait_needs_bank<=0;p_wait_y<=0;p_wait_x<=0;p_wait_group<=0;dw_active<=0;dw_jobs_started<=0;dw_jobs_done<=0;dw_issue_slot<=0;dw_capture_jobs<=0;dw_issue_jobs<=0;dw_issue_active<=0;dw_raw_loaded<=0;dw_rq_base<=0;dw_job_y<=0;dw_job_x<=0;dw_job_group<=0;
      dw_req_count<=0;dw_resp_count<=0;dw_config_count<=0;dw_start_count<=0;rq_accept_count<=0;dw_rq_inflight_count<=0;source_stall_count<=0;bank_conflict_count<=0;final_commit_count<=0;pw_rq_overlap_count<=0;dw_rq_overlap_count<=0;dw_cfg_idx<=0;dw_cfg_group<=0;dw_run_group<=0;dw_req_pending<=0;dw_req_addr_reg<=0;
     diag_pool_pw_accept_count<=0;diag_pool_rq_accept_count<=0;diag_pool_total_input_count<=0;diag_pool_total_output_count<=0;diag_pool_conservation_error_count<=0;diag_pool_busy_cycles<=0;diag_pool_idle_cycles<=0;diag_pool_turnaround_cycles<=0;diag_pool_mode_switch_count<=0;diag_pool_pw_output_count<=0;diag_pool_rq_output_count<=0;diag_context_wait_cycles<=0;diag_e_wait_cycles<=0;diag_e_pool_cycles<=0;diag_p_wait_cycles<=0;diag_ded_normal_accept_count<=0;diag_ded_raw_accept_count<=0;diag_pool_prev_mode<=0;diag_pool_prev_valid<=0;
      for(i=0;i<13;i=i+1) diag_state_cycles[i]<=0;
      for(i=0;i<DW_FIFO_DEPTH;i=i+1) dw_slot_resp_count[i]<=0;
      ded_fetch_epoch<=0;ded_fetch_slot<=0;ded_fetch_project<=0;ded_fetch_group<=0;
      ded_fetch_pass<=0;ded_fetch_y<=0;ded_fetch_x<=0;ded_fetch_k<=0;
      ded_fetch_first<=0;ded_fetch_last<=0;
      pool_fetch_epoch<=0;pool_fetch_slot<=0;pool_fetch_project<=0;pool_fetch_group<=0;
      pool_fetch_pass<=0;pool_fetch_y<=0;pool_fetch_x<=0;pool_fetch_k<=0;
      pool_fetch_first<=0;pool_fetch_last<=0;
     end else begin
       /* Raw FIFO responses are synchronous and tagged by the FIFO head.  A
        * result is registered once, then remains stable for all four RQ
        * quads until the final quad retires the slot. */
       if (dw_raw_resp_fire) begin
         dw_raw_capture_q<=dw_raw_resp_data;
         dw_raw_loaded<=1'b1;
       end
       if (dw_fifo_pop)
         dw_raw_loaded<=1'b0;
       /* A completed epoch returns to S_IDLE and can be started again without
       * resetting the device.  Keep every measured counter epoch-local so the
       * two-epoch regression can compare each run against the same ledger. */
      if(start_fire) begin
     cycle_count<=0;pw_mac_count<=0;dw_mac_count<=0;overlap_cycles<=0;protocol_errors<=0;
         dw_req_count<=0;dw_resp_count<=0;dw_config_count<=0;dw_start_count<=0;rq_accept_count<=0;dw_rq_inflight_count<=0;source_stall_count<=0;bank_conflict_count<=0;final_commit_count<=0;pw_rq_overlap_count<=0;dw_rq_overlap_count<=0;
        diag_pool_pw_accept_count<=0;diag_pool_rq_accept_count<=0;diag_pool_total_input_count<=0;diag_pool_total_output_count<=0;diag_pool_conservation_error_count<=0;diag_pool_busy_cycles<=0;diag_pool_idle_cycles<=0;diag_pool_turnaround_cycles<=0;diag_pool_mode_switch_count<=0;diag_pool_pw_output_count<=0;diag_pool_rq_output_count<=0;diag_context_wait_cycles<=0;diag_e_wait_cycles<=0;diag_e_pool_cycles<=0;diag_p_wait_cycles<=0;diag_ded_normal_accept_count<=0;diag_ded_raw_accept_count<=0;diag_pool_prev_mode<=0;diag_pool_prev_valid<=0;
        for(i=0;i<13;i=i+1) diag_state_cycles[i]<=0;
        ded_fetch_epoch<=0;ded_fetch_slot<=0;ded_fetch_project<=0;ded_fetch_group<=0;
        ded_fetch_pass<=0;ded_fetch_y<=0;ded_fetch_x<=0;ded_fetch_k<=0;
        ded_fetch_first<=0;ded_fetch_last<=0;
        pool_fetch_epoch<=0;pool_fetch_slot<=0;pool_fetch_project<=0;pool_fetch_group<=0;
        pool_fetch_pass<=0;pool_fetch_y<=0;pool_fetch_x<=0;pool_fetch_k<=0;
        pool_fetch_first<=0;pool_fetch_last<=0;
      end
      if(busy) cycle_count<=cycle_count+1'b1;
     if(busy && (state<=S_DONE)) diag_state_cycles[state]<=diag_state_cycles[state]+1'b1;
     if(diag_pool_scope) begin
       if(diag_pool_input_fire) diag_pool_busy_cycles<=diag_pool_busy_cycles+1'b1;
       else diag_pool_idle_cycles<=diag_pool_idle_cycles+1'b1;
     end
     if(pool_pw_fire) diag_pool_pw_accept_count<=diag_pool_pw_accept_count+1'b1;
     if(pool_rq_fire) diag_pool_rq_accept_count<=diag_pool_rq_accept_count+1'b1;
     if(pool_input_fire) diag_pool_total_input_count<=diag_pool_total_input_count+1'b1;
     if(pool_valid) diag_pool_total_output_count<=diag_pool_total_output_count+1'b1;
     if(pool_valid && pool_mode_out) diag_pool_rq_output_count<=diag_pool_rq_output_count+1'b1;
     if(pool_valid && !pool_mode_out) diag_pool_pw_output_count<=diag_pool_pw_output_count+1'b1;
     if(pool_valid_in && !pool_ready && diag_pool_prev_valid && (pool_mode_rq!=diag_pool_prev_mode)) diag_pool_turnaround_cycles<=diag_pool_turnaround_cycles+1'b1;
     if(diag_pool_input_fire && (!diag_pool_prev_valid || (pool_mode_rq!=diag_pool_prev_mode))) diag_pool_mode_switch_count<=diag_pool_mode_switch_count+1'b1;
     if(diag_pool_input_fire) begin diag_pool_prev_mode<=pool_mode_rq;diag_pool_prev_valid<=1'b1;end
     if(done_valid && done_ready &&
        ((diag_pool_rq_accept_count!=diag_pool_rq_output_count) ||
         (diag_pool_pw_accept_count!=diag_pool_pw_output_count) ||
         (diag_pool_total_input_count!=diag_pool_total_output_count)))
       diag_pool_conservation_error_count<=diag_pool_conservation_error_count+1'b1;
     if(state==S_E_WAIT || state==S_E_POOL || state==S_P_WAIT) diag_context_wait_cycles<=diag_context_wait_cycles+1'b1;
     if(state==S_E_WAIT) diag_e_wait_cycles<=diag_e_wait_cycles+1'b1;
     if(state==S_E_POOL) diag_e_pool_cycles<=diag_e_pool_cycles+1'b1;
     if(state==S_P_WAIT) diag_p_wait_cycles<=diag_p_wait_cycles+1'b1;
     if(pw_and_rq_active) begin overlap_cycles<=overlap_cycles+1'b1;pw_rq_overlap_count<=pw_rq_overlap_count+1'b1;end
     if(dw_active&&rq_active) dw_rq_overlap_count<=dw_rq_overlap_count+1'b1;
      if(dw_src_req_valid&&!dw_src_req_ready) source_stall_count<=source_stall_count+1'b1;
      if(ded_descriptor_mismatch || pool_descriptor_mismatch || dw_adapter_protocol_error)
        protocol_errors<=protocol_errors+1'b1;
        if(cfg_fire) case(cfg_kind)
        /* INPUT and PW_WEIGHT payloads are accepted by u_v6_common_bank.
         * Keeping the cases here documents the host ABI without creating a
         * second storage array in the scheduler. */
        CFG_INPUT: ;
        CFG_PW_WEIGHT: ;
       CFG_DW_WEIGHT: if(cfg_addr<DW_WEIGHT_BYTES) dw_weight_mem[cfg_addr]<=cfg_data[7:0];
       CFG_BIAS: if(cfg_addr<192) bias_mem[cfg_addr]<=cfg_data;
       CFG_MULT: if(cfg_addr<192) multiplier_mem[cfg_addr]<=cfg_data;
       CFG_SHIFT: if(cfg_addr<192) shift_mem[cfg_addr]<=cfg_data[7:0];
       default: protocol_errors<=protocol_errors+1'b1;
     endcase
     if(dw_src_req_valid&&dw_src_req_ready) begin dw_req_pending<=1;dw_req_addr_reg<=dw_src_req_addr;dw_req_count<=dw_req_count+1;end
     else if(dw_src_resp_valid&&dw_src_resp_ready) dw_req_pending<=0;
     if(dw_src_resp_valid&&dw_src_resp_ready) dw_resp_count<=dw_resp_count+1;
     if(state==S_DW_RQ) begin
       case ({pool_rq_fire,dw_rq_output})
         2'b10: dw_rq_inflight_count<=dw_rq_inflight_count+1'b1;
         2'b01: dw_rq_inflight_count<=dw_rq_inflight_count-1'b1;
         default: dw_rq_inflight_count<=dw_rq_inflight_count;
       endcase
     end
      if(pool_pw_fire) pool_pw_k<=pool_pw_k+1'b1;
       /* Request and response K counters are separate because synchronous
        * activation banks return the request one edge after it is launched. */
       if(v6_pw_request_fire) pw_req_k<=pw_req_k+1'b1;
       if(v6_scratch1_pool_rd_request_fire) pool_req_k<=pool_req_k+1'b1;
       if(v6_ded_pair_request_offer) begin
         ded_fetch_epoch<=epoch_reg;ded_fetch_slot<=ded_slot;
         ded_fetch_project<=pw_project;ded_fetch_group<=ded_group;
         ded_fetch_pass<=ded_raw_phase;ded_fetch_y<=ded_y;ded_fetch_x<=ded_x;
         ded_fetch_k<=pw_req_k;ded_fetch_first<=(pw_req_k==0);
         ded_fetch_last<=(pw_req_k==(pw_project?6'd31:6'd15));
       end
       if(v6_pool_pair_request_offer) begin
         pool_fetch_epoch<=epoch_reg;pool_fetch_slot<=ded_slot;
         pool_fetch_project<=pw_project;pool_fetch_group<=ded_group;
         pool_fetch_pass<=pw_project;pool_fetch_y<=ded_y;pool_fetch_x<=ded_x;
         pool_fetch_k<=pool_req_k;pool_fetch_first<=(pool_req_k==0);
         pool_fetch_last<=(pool_req_k==(pw_project?6'd31:6'd15));
       end
       if(ded_fire) begin if(ded_raw_phase) diag_ded_raw_accept_count<=diag_ded_raw_accept_count+1'b1; else diag_ded_normal_accept_count<=diag_ded_normal_accept_count+1'b1;end
       if(dw_cfg_valid&&dw_cfg_ready) begin dw_config_count<=dw_config_count+1;if(dw_cfg_idx==143) begin dw_cfg_idx<=0;if(!dw_cfg_group) begin dw_cfg_group<=1;state<=S_E_BOTH;ded_active<=1;ded_raw_phase<=0;pool_pw_active<=0;pw_k<=0;pw_req_k<=0;pool_pw_k<=0;pool_req_k<=0;ded_y<=0;ded_x<=0;ded_group<=0;end else begin dw_run_group<=1;dw_capture_jobs<=0;dw_issue_jobs<=0;state<=S_DW_WAIT;end end else dw_cfg_idx<=dw_cfg_idx+1;end
     if(dw_start_valid&&dw_start_ready) dw_start_count<=dw_start_count+1;
      if(start_fire) begin state<=S_DW_CFG;epoch_reg<=start_epoch;done_epoch<=start_epoch;bank0_state_reg<=FILL;bank1_state_reg<=FREE;word_bank_valid0<=0;word_bank_valid1<=0;word_write_slot<=0;word_drain_slot<=0;word_drain_index<=0;word_global_index<=0;p_bank_wait<=0;pw_project<=0;pw_slot<=0;pw_k<=0;pw_req_k<=0;ded_active<=0;ded_slot<=0;ded_raw_phase<=0;pool_pw_active<=0;pool_pw_slot<=0;pool_pw_k<=0;pool_req_k<=0;e_y<=0;e_x<=0;e_group<=0;next_y<=0;next_x<=8;next_group<=0;ded_y<=0;ded_x<=0;ded_group<=0;e_done_tiles<=0;ctx_y0<=0;ctx_x0<=0;ctx_group0<=0;ctx_y1<=0;ctx_x1<=8;ctx_group1<=0;ctx_ded_ready0<=0;ctx_pool_ready0<=0;ctx_pool_ready1<=0;ctx_ded_ready1<=0;p_y<=0;p_x<=0;p_group<=0;p_next_y<=0;p_next_x<=0;p_next_group<=0;p_next_valid<=0;p_wait_next<=0;p_wait_slot<=0;p_wait_needs_bank<=0;p_wait_y<=0;p_wait_x<=0;p_wait_group<=0;rq_active<=0;dw_active<=0;dw_jobs_started<=0;dw_jobs_done<=0;dw_issue_slot<=0;dw_capture_jobs<=0;dw_issue_jobs<=0;dw_issue_active<=0;dw_raw_loaded<=0;dw_cfg_idx<=0;dw_cfg_group<=0;dw_run_group<=0;for(i=0;i<DW_FIFO_DEPTH;i=i+1) dw_slot_resp_count[i]<=0;end
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
            for(i=0;i<112;i=i+1) begin
              if(ded_slot) begin ctx_bus1<=pw112_psum;ctx_ded_ready1<=1;end
              else begin ctx_bus0<=pw112_psum;ctx_ded_ready0<=1; end
            end
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
             pw_k<=0;pw_req_k<=0;
           end
         end
       end
       if(pool_valid&& !pool_mode_out && pool_pw_active) begin
         for(i=0;i<16;i=i+1) begin
           if(pool_metadata[5:0]==0) begin
             if(pool_pw_slot) ctx_raw1[112+i]<={{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]};
             else ctx_raw0[112+i]<={{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]};
           end else begin
             if(pool_pw_slot) ctx_raw1[112+i]<=ctx_raw1[112+i]+$signed({{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]});
             else ctx_raw0[112+i]<=ctx_raw0[112+i]+$signed({{16{pool_pw_product[i*16+15]}},pool_pw_product[i*16 +:16]});
           end
         end
         if(pool_metadata[5:0]== (pw_project?31:15)) begin if(pool_pw_slot) ctx_pool_ready1<=1; else ctx_pool_ready0<=1;pool_pw_active<=0;end
       end
       case(state)
         S_E_BOTH: begin
           ctx_y0<=0;ctx_x0<=0;ctx_group0<=0;
            if(ded_fire) begin pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112); if(ded_last_fire) begin ded_active<=0;pw_k<=0;pw_req_k<=0;state<=S_E_WAIT;end else pw_k<=pw_k+1'b1;end
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
                if(ded_last_fire) begin ded_active<=0;pw_k<=0;pw_req_k<=0;end
                else pw_k<=pw_k+1'b1;
              end
              if((ctx_ded_ready0)&&(ctx_pool_ready0)) begin ctx_slot_rq<=0;rq_base<=0;rq_active<=1;ded_slot<=1;ded_active<=1;ded_raw_phase<=0;pw_slot<=1;pw_k<=0;pw_req_k<=0;ded_y<=0;ded_x<=0;ded_group<=1;/* The first context in the second slot is the missing x=0/group1 tile; continue with x=8/group0. */next_y<=0;next_x<=8;next_group<=0;ctx_y1<=0;ctx_x1<=0;ctx_group1<=1;state<=S_E_RQ;end
            end
         S_E_RQ: begin
           if(ded_fire) begin pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);if(ded_last_fire) begin ded_active<=0;pw_k<=0;pw_req_k<=0;end else pw_k<=pw_k+1'b1;end
           if(pool_rq_fire) begin rq_accept_count<=rq_accept_count+1;rq_base<=rq_base+4;end
           if(pool_valid&&pool_mode_out) begin
             /* Expansion scratch is written by the channel-bank processes
              * above; keeping the four-byte RQ result out of this large
              * control process is required for block-RAM inference. */
             if(pool_metadata[7:0]==124) begin rq_active<=0;if(ctx_slot_rq) begin ctx_ded_ready1<=0;ctx_pool_ready1<=0;end else begin ctx_ded_ready0<=0;ctx_pool_ready0<=0;end
             if(e_done_tiles==255) begin state<=S_DW_WAIT;pw_project<=1;p_y<=0;p_x<=0;p_group<=0;end
                else begin pw_k<=0;pw_req_k<=0;state<=S_E_POOL;e_done_tiles<=e_done_tiles+1;ctx_slot_rq<=ctx_slot_rq;end
             end
           end
         end
         S_E_POOL: begin
           if(ded_fire) begin pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);if(ded_last_fire) begin ded_active<=0;pw_k<=0;pw_req_k<=0;end else pw_k<=pw_k+1'b1;end
           if(!pool_pw_active && !ded_active && (!ctx_slot_rq?ctx_ded_ready1:ctx_ded_ready0)) begin
             rq_active<=1;rq_base<=0;ctx_slot_rq<=!ctx_slot_rq;
             ded_slot<=ctx_slot_rq;pw_k<=0;pw_req_k<=0;
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
               /* The raw FIFO head is the only authoritative descriptor
                * order.  Issue one vector at a time and select the head after
                * the preceding vector has retired; an independent issue
                * pointer can outrun the RAM head while the pool pipeline is
                * still draining. */
               dw_issue_slot<=dw_fifo_head;
                dw_issue_jobs<=dw_issue_jobs+1'b1;dw_raw_loaded<=1'b0;
               dw_issue_active<=1;ctx_slot_rq<=0;state<=S_DW_RQ;
             end
           else if(!dw_active && dw_run_group==0 && dw_jobs_done==256) begin dw_cfg_idx<=0;dw_jobs_started<=0;state<=S_DW_CFG;end
             else if(!dw_active && dw_run_group==1 && dw_jobs_done==512) begin state<=S_P_BOTH;pw_project<=1;pw_k<=0;pw_req_k<=0;ded_active<=1;ded_raw_phase<=0;ded_slot<=0;pool_pw_active<=1;pool_pw_slot<=0;pool_pw_k<=0;pool_req_k<=0;ded_y<=0;ded_x<=0;ded_group<=0;p_y<=0;p_x<=0;p_group<=0;p_next_y<=0;p_next_x<=0;p_next_group<=1;p_next_valid<=1;p_wait_next<=0;p_wait_needs_bank<=0;ctx_ded_ready0<=0;ctx_pool_ready0<=0;ctx_ded_ready1<=0;ctx_pool_ready1<=0;end
          end
          S_DW_RQ: begin
            /* Four requests form one DW vector.  Advance the issue pointer as
             * soon as those inputs fire; returns below are tagged by raw slot
             * and may retire independently of the current issue descriptor. */
            /* A source result may arrive one or more cycles after the last
             * issue burst stopped.  Re-arm the next slot in-place so the
             * response-retirement path remains live while the FIFO fills;
             * otherwise S_DW_RQ can sit forever with rq_active low. */
            if(!rq_active && !dw_issue_active && !dw_raw_loaded &&
               (dw_issue_jobs<10'd256) &&
               ((dw_issue_jobs < dw_capture_jobs) || dw_fifo_push)) begin
              rq_active<=1;rq_base<=0;
              dw_issue_slot<=dw_fifo_head;
               dw_issue_jobs<=dw_issue_jobs+1'b1;dw_issue_active<=1;dw_raw_loaded<=1'b0;
            end
            if(pool_rq_fire) begin
              rq_accept_count<=rq_accept_count+1;
              if(rq_base==8'd12) begin
                /* The pool has accepted all four quads, so the raw vector's
                 * storage lifetime is complete even though its four results
                 * still drain below.  Release the slot now and, when another
                 * captured vector is available, issue the next descriptor
                 * against the post-pop FIFO head.  This overlaps the next
                 * raw-vector read with the current vector's pool drain. */
                if(dw_raw_release &&
                   ((dw_issue_jobs<dw_capture_jobs) || dw_fifo_push)) begin
                  rq_active<=1;rq_base<=0;
                  dw_issue_slot<=dw_fifo_head+1'b1;
                  dw_issue_jobs<=dw_issue_jobs+1'b1;
                  dw_issue_active<=1;
                end else begin
                  rq_active<=0;dw_issue_active<=0;
                end
              end else rq_base<=rq_base+4;
            end
            if(dw_rq_output) begin
              dw_slot_idx=pool_metadata[13:8];
              /* DW scratch receives the complete aligned result word in the
               * dedicated single-write memory processes above. */
              if(dw_slot_resp_count[dw_slot_idx]==3) begin
                dw_slot_resp_count[dw_slot_idx]<=0;
                dw_jobs_done<=dw_jobs_done+1;
                 if(dw_jobs_done==511) begin state<=S_P_BOTH;pw_project<=1;pw_k<=0;pw_req_k<=0;ded_active<=1;ded_raw_phase<=0;ded_slot<=0;pool_pw_active<=1;pool_pw_slot<=0;pool_pw_k<=0;pool_req_k<=0;ded_y<=0;ded_x<=0;ded_group<=0;p_y<=0;p_x<=0;p_group<=0;p_next_y<=0;p_next_x<=0;p_next_group<=1;p_next_valid<=1;p_wait_next<=0;p_wait_needs_bank<=0;ctx_ded_ready0<=0;ctx_pool_ready0<=0;ctx_ded_ready1<=0;ctx_pool_ready1<=0;end
                /* The FIFO slot was released when its final request was
                 * accepted, so occupancy here describes only following
                 * vectors.  Enter the wait state only when none remain. */
                 else if(!rq_active && dw_fifo_count==0 && !dw_fifo_push &&
                         dw_rq_inflight_count==8'd1 && !pool_rq_fire)
                   state<=S_DW_WAIT;
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
              if(ded_last_fire) begin ded_active<=0;pw_k<=0;pw_req_k<=0;state<=S_P_WAIT;end
              else pw_k<=pw_k+1'b1;
            end
          end
          S_P_WAIT: begin
            /* Drain the raw eight-pixel pass, then launch the next producer
             * into the other slot at the same edge that starts this context's
             * RQ.  The dedicated island and shared RQ pool now overlap. */
            if(ded_fire) begin
              pw_mac_count<=pw_mac_count+(ded_raw_phase?32'd16:32'd112);
              if(ded_last_fire) begin ded_active<=0;pw_k<=0;pw_req_k<=0;end
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
                ded_active<=1;ded_raw_phase<=0;pw_k<=0;pw_req_k<=0;pool_pw_active<=1;pool_pw_slot<=~ded_slot;pool_pw_k<=0;pool_req_k<=0;
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
              if(ded_last_fire) begin ded_active<=0;pw_k<=0;pw_req_k<=0;end
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
                  ded_active<=1;ded_raw_phase<=0;pw_k<=0;pw_req_k<=0;pool_pw_active<=1;pool_pw_slot<=~p_wait_slot;pool_pw_k<=0;pool_req_k<=0;
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
                        ded_active<=1;ded_raw_phase<=0;pw_k<=0;pw_req_k<=0;pool_pw_active<=1;pool_pw_slot<=ctx_slot_rq;pool_pw_k<=0;pool_req_k<=0;
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
                          ded_active<=1;ded_raw_phase<=0;pw_k<=0;pw_req_k<=0;pool_pw_active<=1;pool_pw_slot<=ctx_slot_rq;pool_pw_k<=0;pool_req_k<=0;
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
           dw_fifo_y[dw_fifo_tail]<=dw_job_y+(dw_out_pixel_idx/DW_TILE_W);
           dw_fifo_x[dw_fifo_tail]<=dw_job_x+(dw_out_pixel_idx%DW_TILE_W);
           dw_fifo_group[dw_fifo_tail]<=dw_job_group;
           dw_slot_resp_count[dw_fifo_tail]<=0;
          if(dw_out_last) dw_active<=0;
        end
      end
  end
 end

endmodule
`default_nettype wire
