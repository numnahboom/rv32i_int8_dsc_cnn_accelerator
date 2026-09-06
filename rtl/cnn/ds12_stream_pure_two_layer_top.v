`timescale 1ns/1ps
`default_nettype none
// Real DS1->DS2 composition.  The only stateful shared resources are the
// single configuration bank and dual activation store below.
module ds12_stream_pure_two_layer_top #(
  parameter integer LINE_WORDS=2048,
  parameter integer CFG1_BASE=0,
  parameter integer CFG2_BASE=32'h00001000
) (
 input wire clk,input wire rst_n,input wire start,
 output wire cfg_mem_req_valid,input wire cfg_mem_req_ready,
 output wire [31:0] cfg_mem_req_addr,output wire [15:0] cfg_mem_req_index,
 output wire [1:0] cfg_mem_req_layer,output wire [3:0] cfg_mem_req_strb,
 input wire cfg_mem_resp_valid,output wire cfg_mem_resp_ready,input wire [31:0] cfg_mem_resp_data,
 output wire input_mem_req_valid,input wire input_mem_req_ready,output wire input_mem_req_write,
 output wire [31:0] input_mem_req_addr,output wire [127:0] input_mem_req_wdata,
 output wire [15:0] input_mem_req_strb,output wire [1:0] input_mem_req_context,
 output wire input_mem_req_owner,output wire [31:0] input_mem_req_epoch,
 input wire input_mem_resp_valid,input wire [127:0] input_mem_resp_data,
 output wire ds1_output_valid,input wire ds1_output_ready,output wire [31:0] ds1_output_addr,
 output wire [31:0] ds1_output_data,output wire [3:0] ds1_output_be,output wire ds1_output_last,
 output wire ds2_output_valid,input wire ds2_output_ready,output wire [31:0] ds2_output_addr,
 output wire [31:0] ds2_output_data,output wire [3:0] ds2_output_be,output wire ds2_output_last,
 output wire ds1_done,output wire ds2_done,output wire done,output wire error,
 output wire [7:0] error_code,output wire [31:0] cycle_count,output wire [31:0] ds1_dw_mac_count,
 output wire [31:0] ds1_pw_mac_count,output wire [31:0] ds1_output_word_count,
 output wire [31:0] ds2_dw_mac_count,output wire [31:0] ds2_pw_mac_count,
 output wire [31:0] ds2_output_word_count,output wire atomic_swap
);
 localparam [2:0] IDLE=0,DS1=1,DS1_COMMIT=2,DS2=3,DS2_COMMIT=4,DONE=5;
 reg [2:0] st; reg d1_done,d2_done; reg [31:0] cycles; reg cfg_start_pending; reg [1:0] cfg_pending_layer; reg [1:0] cfg_loading_layer; reg prefetch_done_latched;
 wire c_start_v,c_start_ready,c_mem_v,c_load_done,c_err; wire [3:0] c_ec; wire [31:0] c_mem_addr; wire [15:0] c_mem_index; wire [3:0] c_mem_strb; wire [1:0] c_active_layer;
 wire c_active_bank,c_active_valid; wire [31:0] c_active_epoch; wire c_rd_v,c_rd_r,c_cfg_valid;
 wire [15:0] c_rd_addr; wire c_rd_bank; wire [31:0] c_rd_data;
 wire p1_cfg_v,p1_cfg_r,p1_cfg_done,p1_err,p1_pre_v,p1_pre_r,p1_pre_done;
 wire [1:0] p1_cfg_layer,p1_pre_layer; wire [31:0] p1_cfg_epoch,p1_pre_epoch;
 wire [15:0] p1_cfg_count,p1_pre_count; wire p1_cfg_resp_v; wire [31:0] p1_cfg_resp_data;
 wire p1_act_start,p1_act_start_r,p1_wv,p1_wr,p1_commit,p1_commit_ack,p1_bank; wire [31:0] p1_epoch,p1_addr,p1_data,p1_count;
 wire [3:0] p1_be; wire p1_last,p1_drain; wire [1:0] p1_owner; wire [31:0] p1_act_epoch;
 wire p2_cfg_v,p2_cfg_r,p2_err,p2_act_v,p2_act_r,p2_act_bank; wire [31:0] p2_act_epoch,p2_act_addr;
 wire p2_act_resp_v; wire [127:0] p2_act_resp_data; wire p2_act_resp_bank; wire [31:0] p2_act_resp_epoch,p2_act_resp_addr;
 wire p2_out_v,p2_out_r,p2_out_last,p2_start_v,p2_start_r,p2_commit,p2_commit_ack,p2_bank; wire [31:0] p2_out_addr,p2_out_data,p2_epoch;
 wire [3:0] p2_out_be; wire [31:0] p2_cfg_data; wire p2_cfg_resp_v; wire [15:0] p2_cfg_addr; wire p2_cfg_bank;
 wire s_start_v,s_start_r,s_wv,s_wr,s_end_v,s_end_r,s_commit_done,s_read_v,s_read_r,s_read_resp_v;
 wire [31:0] s_start_epoch,s_start_words,s_w_epoch,s_w_addr,s_w_data,s_end_epoch,s_read_epoch,s_read_addr;
 wire s_start_bank,s_w_bank,s_end_bank,s_read_bank; wire [3:0] s_w_be; wire s_w_last;
 wire [127:0] s_read_data; wire s_read_resp_bank; wire s_active_read_bank; wire [31:0] s_active_read_epoch; wire [31:0] s_read_resp_epoch,s_read_resp_addr; wire [1:0] unused_state0,unused_state1;
 assign p1_cfg_r = !cfg_start_pending;
 assign c_start_v = cfg_start_pending && c_start_ready;
 assign c_rd_bank = c_active_bank;
 assign cfg_mem_req_valid = c_mem_v; assign cfg_mem_req_index=c_mem_index; assign cfg_mem_req_addr=c_mem_addr; assign cfg_mem_req_strb=c_mem_strb; assign cfg_mem_req_layer=cfg_loading_layer; assign cfg_mem_resp_ready=1'b1;
 ds12_stream_config_banks cfg(.clk(clk),.rst_n(rst_n),.start(c_start_v),.start_layer(cfg_pending_layer),
  .start_base_addr((cfg_pending_layer==2)?CFG2_BASE:CFG1_BASE),.start_word_count((cfg_pending_layer==2)?16'd872:16'd308),.start_epoch((cfg_pending_layer==2)?32'd2:32'd1),.start_ready(c_start_ready),
  .mem_req_valid(c_mem_v),.mem_req_ready(cfg_mem_req_ready),.mem_req_addr(c_mem_addr),.mem_req_strb(c_mem_strb),.mem_req_word_index(c_mem_index),
  .mem_resp_valid(cfg_mem_resp_valid),.mem_resp_ready(cfg_mem_resp_ready),.mem_resp_rdata(cfg_mem_resp_data),.commit_req(1'b0),.clear_error(1'b0),
  .cfg_rd_en((st==DS2)?p2_cfg_v:c_rd_v),.cfg_rd_bank((st==DS2)?c_active_bank:c_rd_bank),.cfg_rd_addr((st==DS2)?p2_cfg_addr:c_rd_addr),.cfg_rd_data(c_rd_data),.cfg_rd_valid(c_cfg_valid),.busy(),.active_bank(c_active_bank),.active_layer(c_active_layer),.active_epoch(c_active_epoch),.active_valid(c_active_valid),.bank_valid(),.expected_count(),.issued_count(),.received_count(),.load_crc32(),.load_done(c_load_done),.error(c_err),.error_code(c_ec));
 ds12_stream_dual_vector_activation_store #(.LINE_WORDS(LINE_WORDS)) store(.clk(clk),.rst_n(rst_n),
  .layer_start_valid(s_start_v),.layer_start_ready(s_start_r),.layer_start_bank(s_start_bank),.layer_start_epoch(s_start_epoch),.layer_start_expected_words(s_start_words),
  .write_valid(s_wv),.write_ready(s_wr),.write_bank(s_w_bank),.write_epoch(s_w_epoch),.write_addr(s_w_addr),.write_data(s_w_data),.write_be(s_w_be),.write_last(s_w_last),.write_resp_valid(),.write_resp_ready(1'b1),.write_resp_bank(),.write_resp_epoch(),.write_resp_addr(),
  .layer_end_valid(s_end_v),.layer_end_ready(s_end_r),.layer_end_bank(s_end_bank),.layer_end_epoch(s_end_epoch),.commit_valid(1'b0),.commit_ready(),.commit_bank(1'b0),.commit_epoch(0),.commit_done(s_commit_done),.layer_end_done(),.atomic_swap(atomic_swap),.read_req_valid(s_read_v),.read_req_ready(s_read_r),.read_req_bank(s_read_bank),.read_req_epoch(s_read_epoch),.read_req_addr(s_read_addr),.read_resp_valid(s_read_resp_v),.read_resp_ready(1'b1),.read_resp_data(s_read_data),.read_resp_bank(s_read_resp_bank),.read_resp_epoch(s_read_resp_epoch),.read_resp_addr(s_read_resp_addr),.bank0_state(unused_state0),.bank1_state(unused_state1),.bank0_epoch(),.bank1_epoch(),.active_read_bank(s_active_read_bank),.active_read_epoch(s_active_read_epoch),.active_write(),.active_write_bank(),.write_epoch_active(),.write_count(),.write_expected_words(),.write_last_seen(),.error(),.error_code());
 ds12_stream_ds1_datapath d1(.clk(clk),.rst_n(rst_n),.start(start),.cfg_load_req_valid(p1_cfg_v),.cfg_load_req_ready(p1_cfg_r),.cfg_load_req_layer(p1_cfg_layer),.cfg_load_req_epoch(p1_cfg_epoch),.cfg_load_req_count(p1_cfg_count),.cfg_load_done(c_load_done),.cfg_error(c_err),.cfg_active_rd_valid(c_rd_v),.cfg_active_rd_ready(1'b1),.cfg_active_rd_addr(c_rd_addr),.cfg_active_rd_resp_valid(c_cfg_valid),.cfg_active_rd_resp_data(c_rd_data),.ds2_prefetch_req_valid(p1_pre_v),.ds2_prefetch_req_ready(p1_pre_r),.ds2_prefetch_req_layer(p1_pre_layer),.ds2_prefetch_req_epoch(p1_pre_epoch),.ds2_prefetch_req_count(p1_pre_count),.ds2_prefetch_done(prefetch_done_latched),.input_mem_req_valid(input_mem_req_valid),.input_mem_req_ready(input_mem_req_ready),.input_mem_req_write(input_mem_req_write),.input_mem_req_addr(input_mem_req_addr),.input_mem_req_wdata(input_mem_req_wdata),.input_mem_req_strb(input_mem_req_strb),.input_mem_req_context(input_mem_req_context),.input_mem_req_owner(input_mem_req_owner),.input_mem_req_epoch(input_mem_req_epoch),.input_mem_resp_valid(input_mem_resp_valid),.input_mem_resp_data(input_mem_resp_data),.activation_start_valid(p1_act_start),.activation_start_ready(p1_act_start_r),.activation_write_valid(p1_wv),.activation_write_ready(p1_wr),.activation_write_addr(p1_addr),.activation_write_data(p1_data),.activation_write_be(p1_be),.activation_write_last(p1_last),.activation_write_bank(p1_bank),.activation_write_epoch(p1_epoch),.activation_write_count(p1_count),.activation_write_drain(p1_drain),.activation_commit_req(p1_commit),.activation_commit_ack(p1_commit_ack),.activation_owner(p1_owner),.activation_epoch(p1_act_epoch),.layer_done(),.error(p1_err),.ds1_config_done(),.ds2_preload_done(),.cycle_count(cycles),.dw_first_cycle(),.dw_last_cycle(),.pw_first_cycle(),.pw_last_cycle(),.overlap_cycles(),.dw_idle_cycles(),.pw_idle_cycles(),.dw_mac_count(ds1_dw_mac_count),.pw_mac_count(ds1_pw_mac_count),.output_word_count(ds1_output_word_count),.config_read_count(),.config_write_count(),.ds1_input_read_count(),.ds1_dw_vector_count());
 assign p1_pre_r = (st==DS1); // config load completion is the prefetch fence
 assign s_start_v = (st==DS1)?p1_act_start:p2_start_v; assign s_start_bank=(st==DS1)?1'b1:p2_bank; assign s_start_epoch=(st==DS1)?p1_epoch:p2_epoch; assign s_start_words=(st==DS1)?32'd8192:32'd4096;
 // Gate the shared store command with downstream ready so a held valid beat
 // is accepted exactly once under randomized output backpressure.
 assign s_wv=(st==DS1)?(p1_wv && ds1_output_ready):(p2_out_v && ds2_output_ready); assign s_w_bank=(st==DS1)?p1_bank:p2_bank; assign s_w_epoch=(st==DS1)?p1_epoch:p2_epoch; assign s_w_addr=(st==DS1)?p1_addr:p2_out_addr; assign s_w_data=(st==DS1)?p1_data:p2_out_data; assign s_w_be=(st==DS1)?p1_be:p2_out_be; assign s_w_last=(st==DS1)?p1_last:p2_out_last; assign ds1_output_valid=p1_wv; assign ds1_output_addr=p1_addr; assign ds1_output_data=p1_data; assign ds1_output_be=p1_be; assign ds1_output_last=p1_last; assign ds2_output_valid=p2_out_v; assign ds2_output_addr=p2_out_addr; assign ds2_output_data=p2_out_data; assign ds2_output_be=p2_out_be; assign ds2_output_last=p2_out_last;
 assign p1_wr=s_wr && ds1_output_ready && st==DS1; assign p1_act_start_r=s_start_r && st==DS1; assign p1_commit_ack=s_commit_done && st==DS1; assign s_end_v=(st==DS1_COMMIT)?p1_commit:(st==DS2_COMMIT)?p2_commit:1'b0; assign s_end_bank=(st==DS1_COMMIT)?p1_bank:p2_bank; assign s_end_epoch=(st==DS1_COMMIT)?p1_epoch:p2_epoch; assign p2_out_r=s_wr && ds2_output_ready && (st==DS2); assign p2_start_r=s_start_r&&(st==DS2); assign p2_commit_ack=s_commit_done&&(st==DS2);
 assign p2_cfg_r=1'b1; assign p2_cfg_data=c_rd_data; assign p2_cfg_resp_v=c_cfg_valid; assign p2_act_r=s_read_r; assign p2_act_resp_v=s_read_resp_v; assign p2_act_resp_data=s_read_data; assign p2_act_resp_bank=s_read_resp_bank; assign p2_act_resp_epoch=s_read_resp_epoch; assign p2_act_resp_addr=s_read_resp_addr;
 assign p2_bank = ~s_active_read_bank;
 assign s_read_v=p2_act_v&&(st==DS2); assign s_read_bank=p2_act_bank; assign s_read_epoch=p2_act_epoch; assign s_read_addr=p2_act_addr;
 ds12_stream_ds2_datapath d2(.clk(clk),.rst_n(rst_n),.start(st==DS2),.active_valid(c_active_valid),.active_bank(s_active_read_bank),.active_layer(2'd2),.active_epoch(s_active_read_epoch),.cfg_rd_valid(p2_cfg_v),.cfg_rd_ready(p2_cfg_r),.cfg_rd_bank(p2_cfg_bank),.cfg_rd_addr(p2_cfg_addr),.cfg_rd_resp_valid(p2_cfg_resp_v),.cfg_rd_resp_data(p2_cfg_data),.activation_rd_valid(p2_act_v),.activation_rd_ready(p2_act_r),.activation_rd_bank(p2_act_bank),.activation_rd_epoch(p2_act_epoch),.activation_rd_addr(p2_act_addr),.activation_rd_resp_valid(p2_act_resp_v),.activation_rd_resp_data(p2_act_resp_data),.activation_rd_resp_bank(p2_act_resp_bank),.activation_rd_resp_epoch(p2_act_resp_epoch),.activation_rd_resp_addr(p2_act_resp_addr),.output_write_valid(p2_out_v),.output_write_ready(p2_out_r),.output_write_addr(p2_out_addr),.output_write_data(p2_out_data),.output_write_be(p2_out_be),.output_write_last(p2_out_last),.output_write_bank(),.output_write_epoch(p2_epoch),.bank_start_valid(p2_start_v),.bank_start_ready(p2_start_r),.bank_start_bank(),.bank_start_epoch(),.bank_start_expected_words(),.bank_commit_req(p2_commit),.bank_commit_ack(p2_commit_ack),.bank_commit_bank(),.bank_commit_epoch(),.busy(),.done(d2_done),.error(p2_err),.error_code(),.window_count(),.dw_vector_count(),.dw_mac_count(ds2_dw_mac_count),.pw_token_count(),.pw_mac_count(ds2_pw_mac_count),.output_word_count(ds2_output_word_count),.config_read_count(),.config_weight_read_count(),.write_count());
 assign ds1_done=d1_done; assign ds2_done=d2_done; assign done=(st==DONE); assign error=c_err|p1_err|p2_err; assign error_code=c_err?{4'd0,c_ec}:(p1_err?8'h11:(p2_err?8'h22:8'd0)); assign cycle_count=cycles;
 always @(posedge clk) if(!rst_n) begin st<=IDLE;d1_done<=0;d2_done<=0;cycles<=0;cfg_start_pending<=0;cfg_pending_layer<=0;cfg_loading_layer<=0;prefetch_done_latched<=0;end else begin
 if(p1_cfg_v && !cfg_start_pending) begin cfg_start_pending<=1; cfg_pending_layer<=p1_cfg_layer; end
 if(c_start_v) begin cfg_start_pending<=0; cfg_loading_layer<=cfg_pending_layer; end
 if(c_load_done && cfg_loading_layer==2) prefetch_done_latched<=1; if(st!=IDLE&&st!=DONE) cycles<=cycles+1; case(st) IDLE:if(start)st<=DS1; DS1:if(p1_commit)st<=DS1_COMMIT; DS1_COMMIT:if(s_commit_done)begin d1_done<=1;st<=DS2;end DS2:if(p2_commit)st<=DS2_COMMIT; DS2_COMMIT:if(s_commit_done)begin d2_done<=1;st<=DONE;end DONE:; default:st<=IDLE;endcase end
endmodule
