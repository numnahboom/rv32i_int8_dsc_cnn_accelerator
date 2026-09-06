`timescale 1ns/1ps
`default_nettype none

// Pure DS2 streaming datapath.  There are deliberately no memories in this
// module: the configuration and activation ports are owned by the caller.
// The protocol is the same one used by the original vector-bank layer, so the
// wrapper can provide the local config bank and dual activation store.
module ds12_stream_ds2_datapath #(
    parameter integer SINK_BASE = 32'h00200000
) (
    input wire clk, input wire rst_n, input wire start,
    input wire active_valid, input wire active_bank, input wire [1:0] active_layer,
    input wire [31:0] active_epoch,
    output wire cfg_rd_valid, input wire cfg_rd_ready, output wire cfg_rd_bank,
    output wire [15:0] cfg_rd_addr, input wire cfg_rd_resp_valid,
    input wire [31:0] cfg_rd_resp_data,
    output wire activation_rd_valid, input wire activation_rd_ready,
    output wire activation_rd_bank, output wire [31:0] activation_rd_epoch,
    output wire [31:0] activation_rd_addr, input wire activation_rd_resp_valid,
    input wire [127:0] activation_rd_resp_data, input wire activation_rd_resp_bank,
    input wire [31:0] activation_rd_resp_epoch, input wire [31:0] activation_rd_resp_addr,
    output wire output_write_valid, input wire output_write_ready,
    output wire [31:0] output_write_addr, output wire [31:0] output_write_data,
    output wire [3:0] output_write_be, output wire output_write_last,
    output wire output_write_bank, output wire [31:0] output_write_epoch,
    output wire bank_start_valid, input wire bank_start_ready,
    output wire bank_start_bank, output wire [31:0] bank_start_epoch,
    output wire [31:0] bank_start_expected_words,
    output wire bank_commit_req, input wire bank_commit_ack,
    output wire bank_commit_bank, output wire [31:0] bank_commit_epoch,
    output wire busy, output reg done, output wire error, output wire [7:0] error_code,
    output wire [31:0] window_count, output wire [31:0] dw_vector_count,
    output wire [31:0] dw_mac_count, output wire [31:0] pw_token_count,
    output wire [31:0] pw_mac_count, output wire [31:0] output_word_count,
    output wire [31:0] config_read_count, output wire [31:0] config_weight_read_count,
    output wire [31:0] write_count
);
    localparam [2:0] IDLE=0, CFG_PW=1, CFG_DW=2, RUN=3, DRAIN=4, COMMIT=5;
    reg [2:0] state; reg [8:0] win_issue; reg run_start;
    wire c_dw_en,c_dw_bank,c_pw_en,c_pw_bank; wire [15:0] c_dw_addr,c_pw_addr;
    wire [31:0] cfg_data = cfg_rd_resp_data;
    wire cfg_valid = cfg_rd_resp_valid;
    wire r_start_ready,r_valid,r_ready,r_last,r_req_valid,r_req_ready,r_resp_valid,r_resp_ready;
    wire [127:0] r_data; wire [5:0] r_row,r_col; wire [1:0] r_tr,r_tc,r_ctx;
    wire r_slice,r_owner; wire [31:0] r_epoch,r_req_addr,r_read_epoch; wire r_req_bank;
    wire dw_ready,dw_valid,dw_last,dw_group,dw_owner; wire [127:0] dw_data;
    wire [5:0] dw_row; wire [7:0] dw_pixel; wire [1:0] dw_context; wire [31:0] dw_epoch;
    wire pw_ready,pw_done,pw_error; wire [7:0] pw_ec; wire [31:0] pw_cfgc,pw_wcfgc,pw_dwc,pw_tok,pw_mac,pw_out;
    wire sink_valid,sink_ready,sink_last; wire [31:0] sink_addr,sink_data; wire [3:0] sink_strb;
    wire dw_done,dw_error; wire [7:0] dw_ec; wire [31:0] dw_wc,dw_dc,dw_mc,dw_cfgc; wire [3:0] dw_peak;
    wire [1:0] pw_context = dw_pixel[4:3]; wire pw_owner = dw_pixel[5];
    wire [31:0] pw_epoch = active_epoch;
    assign cfg_rd_valid = (state==CFG_PW) ? c_pw_en : c_dw_en;
    assign cfg_rd_bank = (state==CFG_PW) ? c_pw_bank : c_dw_bank;
    assign cfg_rd_addr = (state==CFG_PW) ? c_pw_addr : c_dw_addr;
    assign activation_rd_valid=r_req_valid;
    assign activation_rd_bank=r_req_bank; assign activation_rd_epoch=r_read_epoch;
    assign activation_rd_addr=r_req_addr;
    assign output_write_valid=sink_valid; assign sink_ready=output_write_ready;
    assign output_write_addr=sink_addr-SINK_BASE; assign output_write_data=sink_data;
    assign output_write_be=sink_strb; assign output_write_last=sink_last;
    assign output_write_bank=active_bank; assign output_write_epoch=active_epoch;
    assign bank_start_valid=(state==IDLE)&&start; assign bank_start_bank=~active_bank;
    assign bank_start_epoch=active_epoch; assign bank_start_expected_words=32'd4096;
    assign bank_commit_req=(state==COMMIT); assign bank_commit_bank=~active_bank;
    assign bank_commit_epoch=active_epoch; assign busy=(state!=IDLE);
    assign write_count=pw_out; assign window_count=dw_wc; assign dw_vector_count=dw_dc;
    assign dw_mac_count=dw_mc; assign pw_token_count=pw_tok; assign pw_mac_count=pw_mac;
    assign output_word_count=pw_out; assign config_read_count=dw_cfgc+pw_cfgc;
    assign config_weight_read_count=pw_wcfgc; assign error=dw_error|pw_error;
    assign error_code=dw_ec|pw_ec;
    ds12_stream_ds2_window_vector_reader reader(
      .clk(clk),.rst_n(rst_n),.window_start_valid(state==RUN&&win_issue<256),.window_start_ready(r_start_ready),
      .window_start_row({2'd0,win_issue[7:4]}),.window_start_col({2'd0,win_issue[3:0]}),.window_start_bank(active_bank),.window_start_epoch(active_epoch),.window_start_last(win_issue==255),
      .window_valid(r_valid),.window_ready(r_ready),.window_data(r_data),.window_row(r_row),.window_col(r_col),.window_tap_row(r_tr),.window_tap_col(r_tc),.window_channel_slice(r_slice),.window_context(r_ctx),.window_owner(r_owner),.window_epoch(r_epoch),.window_last(r_last),
      .read_req_valid(r_req_valid),.read_req_ready(r_req_ready),.read_req_bank(r_req_bank),.read_req_epoch(r_read_epoch),.read_req_addr(r_req_addr),.read_resp_valid(r_resp_valid),.read_resp_ready(r_resp_ready),.read_resp_data(activation_rd_resp_data),.read_resp_bank(activation_rd_resp_bank),.read_resp_epoch(activation_rd_resp_epoch),.read_resp_addr(activation_rd_resp_addr),.busy(),.context_active(),.context_peak(),.read_count(),.window_count(),.error(),.error_code());
    assign r_resp_valid=activation_rd_resp_valid; assign r_resp_ready=1'b1; assign r_req_ready=activation_rd_ready;
    ds12_stream_ds2_dw_compute dw(.clk(clk),.rst_n(rst_n),.start(state==CFG_DW),.ready(),.cfg_rd_en(c_dw_en),.cfg_rd_bank(c_dw_bank),.cfg_rd_addr(c_dw_addr),.cfg_rd_data(cfg_data),.cfg_rd_valid(cfg_valid),.cfg_active_valid(active_valid),.cfg_active_layer(active_layer),.cfg_active_bank(active_bank),.cfg_active_epoch(active_epoch),.config_index(),.config_payload(),.window_valid(r_valid),.window_ready(r_ready),.window_data(r_data),.window_row(r_row),.window_col(r_col),.window_tap_row(r_tr),.window_tap_col(r_tc),.window_channel_slice(r_slice),.window_context(r_ctx),.window_owner(r_owner),.window_epoch(r_epoch),.window_last(r_last),.dw_valid(dw_valid),.dw_ready(dw_ready),.dw_data(dw_data),.dw_row(dw_row),.dw_pixel(dw_pixel),.dw_group(dw_group),.dw_context(dw_context),.dw_owner(dw_owner),.dw_epoch(dw_epoch),.dw_last(dw_last),.done(dw_done),.error(dw_error),.error_code(dw_ec),.window_vector_count(dw_wc),.dw_vector_count(dw_dc),.dw_mac_count(dw_mc),.padding_tap_count(),.context_peak(dw_peak),.config_read_count(dw_cfgc));
    ds12_stream_ds2_pw_consumer pw(.clk(clk),.rst_n(rst_n),.start(state==CFG_PW),.ready(pw_ready),.cfg_rd_en(c_pw_en),.cfg_rd_bank(c_pw_bank),.cfg_rd_addr(c_pw_addr),.cfg_rd_data(cfg_data),.cfg_rd_valid(cfg_valid),.cfg_active_valid(active_valid),.cfg_active_layer(active_layer),.cfg_active_bank(active_bank),.cfg_active_epoch(active_epoch),.config_index(),.config_payload(),.dw_valid(dw_valid),.dw_ready(dw_ready),.dw_data(dw_data),.dw_row(dw_row),.dw_pixel(dw_pixel),.dw_group(dw_group),.dw_context(pw_context),.dw_owner(pw_owner),.dw_epoch(pw_epoch),.dw_last(dw_last),.sink_valid(sink_valid),.sink_ready(sink_ready),.sink_addr(sink_addr),.sink_data(sink_data),.sink_strb(sink_strb),.sink_row(),.sink_pixel(),.sink_word_in_pixel(),.sink_context(),.sink_owner(),.sink_epoch(),.sink_last(sink_last),.busy(),.done(pw_done),.error(pw_error),.error_code(pw_ec),.cfg_read_count(pw_cfgc),.cfg_weight_read_count(pw_wcfgc),.dw_vector_count(pw_dwc),.pw_token_count(pw_tok),.pw_mac_count(pw_mac),.output_word_count(pw_out),.partial_context_peak());
    always @(posedge clk) begin
      if(!rst_n) begin state<=IDLE;win_issue<=0;done<=0; end else begin done<=0;
        case(state)
          IDLE: if(start&&bank_start_ready) state<=CFG_PW;
          CFG_PW: if(pw_wcfgc>=512&&pw_ready) state<=CFG_DW;
          CFG_DW: if(dw_cfgc>=168) begin state<=RUN; win_issue<=0; end
          RUN: begin if(r_start_ready&&win_issue<256) win_issue<=win_issue+1; if(pw_done) state<=DRAIN; end
          DRAIN: if(output_write_ready&&(sink_last || pw_out>=32'd4096)) state<=COMMIT;
          COMMIT: if(bank_commit_ack) begin state<=IDLE;done<=1;end
          default: state<=IDLE;
        endcase
      end
    end
endmodule
`default_nettype wire
