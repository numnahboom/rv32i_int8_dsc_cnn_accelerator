`timescale 1ns/1ps
`default_nettype none

// Complete DS2 bank-to-bank layer shell.  The published DS1 bank is read
// through the real dual vector store; the other bank receives the PW 32-bit
// stream and is atomically published only after the final write response.
module ds12_stream_ds2_vector_bank_layer #(
    parameter integer LINE_WORDS = 8192,
    parameter integer CFG_WORDS = 872
) (
    input wire clk, input wire rst_n,
    input wire start, output wire ready,
    input wire [31:0] epoch,

    // Packed configuration-bank loader (the bank is committed by the host).
    input wire cfg_load_start, input wire [1:0] cfg_start_layer,
    input wire [31:0] cfg_start_base_addr, input wire [15:0] cfg_start_word_count,
    output wire cfg_start_ready, output wire cfg_mem_req_valid,
    input wire cfg_mem_req_ready, output wire [31:0] cfg_mem_req_addr,
    output wire [3:0] cfg_mem_req_strb, output wire [15:0] cfg_mem_req_word_index,
    input wire cfg_mem_resp_valid, output wire cfg_mem_resp_ready,
    input wire [31:0] cfg_mem_resp_rdata, input wire cfg_commit,
    output wire cfg_load_done, output wire cfg_active_valid,
    output wire cfg_active_bank, output wire [1:0] cfg_active_layer,
    output wire [31:0] cfg_active_epoch, output wire cfg_error,
    output wire [3:0] cfg_error_code,

    // DS1 hardware store write channel (used by the preceding layer).
    input wire ds1_write_valid, output wire ds1_write_ready,
    input wire ds1_write_bank, input wire [31:0] ds1_write_epoch,
    input wire [31:0] ds1_write_addr, input wire [31:0] ds1_write_data,
    input wire [3:0] ds1_write_be, input wire ds1_write_last,
    output wire ds1_write_resp_valid, input wire ds1_write_resp_ready,
    output wire ds1_write_resp_bank, output wire [31:0] ds1_write_resp_epoch,
    output wire [31:0] ds1_write_resp_addr,
    input wire ds1_layer_start_valid, input wire ds1_layer_start_bank,
    input wire [31:0] ds1_layer_start_epoch, input wire [31:0] ds1_layer_start_expected_words,
    input wire ds1_commit_valid, input wire ds1_commit_bank, input wire [31:0] ds1_commit_epoch,

    // Published output-bank read port (same tagged vector contract).
    input wire read_req_valid, output wire read_req_ready, input wire read_req_bank,
    input wire [31:0] read_req_epoch, input wire [31:0] read_req_addr,
    output wire read_resp_valid, input wire read_resp_ready,
    output wire [127:0] read_resp_data, output wire read_resp_bank,
    output wire [31:0] read_resp_epoch, output wire [31:0] read_resp_addr,

    output wire busy, output reg done, output wire error, output wire [7:0] error_code,
    output wire [31:0] window_count, output wire [31:0] dw_vector_count,
    output wire [31:0] dw_mac_count, output wire [31:0] pw_token_count,
    output wire [31:0] pw_mac_count, output wire [31:0] output_word_count,
    output wire [31:0] config_read_count, output wire [31:0] config_weight_read_count,
    output wire [31:0] write_count, output wire atomic_commit,
    output wire output_write_valid, input wire output_write_ready,
    output wire [31:0] output_write_addr, output wire [31:0] output_write_data,
    output wire [3:0] output_write_be
);
    localparam [2:0] S_IDLE=0, S_PW_CFG=1, S_DW_CFG=2, S_RUN=3, S_DRAIN=4;
    reg [2:0] state;
    reg [8:0] win_issue;
    reg target_bank;
    reg store_start_v, store_commit_v, pw_start_v, dw_start_v;
    wire store_start_any = store_start_v || ds1_layer_start_valid;
    wire store_commit_any = store_commit_v || ds1_commit_valid;
    wire store_start_ready, store_commit_ready, store_commit_done, store_swap;
    wire store_active_write, store_write_last_seen, store_error;
    wire [7:0] store_error_code;
    wire [31:0] store_write_count;
    wire sink_valid, sink_ready, sink_last, store_write_ready;
    wire [31:0] sink_addr, sink_data;
    wire [3:0] sink_strb;
    wire srd_req_valid,srd_req_ready,srd_req_bank,srd_resp_valid,srd_resp_ready,srd_resp_bank;
    wire [31:0] srd_req_epoch,srd_req_addr,srd_resp_epoch,srd_resp_addr;
    wire [127:0] srd_resp_data;
    wire s_active_read_bank;

    ds12_stream_dual_vector_activation_store #(.LINE_WORDS(LINE_WORDS)) store (
      .clk(clk),.rst_n(rst_n), .layer_start_valid(store_start_any),.layer_start_ready(store_start_ready),
      .layer_start_bank(ds1_layer_start_valid ? ds1_layer_start_bank : target_bank),.layer_start_epoch(ds1_layer_start_valid ? ds1_layer_start_epoch : epoch),.layer_start_expected_words(ds1_layer_start_valid ? ds1_layer_start_expected_words : 32'd4096),
      .write_valid(ds1_write_valid || (sink_valid && output_write_ready)),.write_ready(store_write_ready),
      .write_bank(ds1_write_valid ? ds1_write_bank : target_bank),
      .write_epoch(ds1_write_valid ? ds1_write_epoch : epoch),
      .write_addr(ds1_write_valid ? ds1_write_addr : (sink_addr - 32'h00200000)),
      .write_data(ds1_write_valid ? ds1_write_data : sink_data),.write_be(ds1_write_valid ? ds1_write_be : sink_strb),
      .write_last(ds1_write_valid ? ds1_write_last : sink_last),.write_resp_valid(ds1_write_resp_valid),
      .write_resp_ready(1'b1),.write_resp_bank(ds1_write_resp_bank),.write_resp_epoch(ds1_write_resp_epoch),.write_resp_addr(ds1_write_resp_addr),
      .layer_end_valid(store_commit_any),.layer_end_ready(),.layer_end_bank(ds1_commit_valid ? ds1_commit_bank : target_bank),.layer_end_epoch(ds1_commit_valid ? ds1_commit_epoch : epoch),
      .commit_valid(1'b0),.commit_ready(store_commit_ready),.commit_bank(target_bank),.commit_epoch(epoch),.commit_done(store_commit_done),.layer_end_done(),.atomic_swap(store_swap),
      .read_req_valid(srd_req_valid),.read_req_ready(srd_req_ready),.read_req_bank(srd_req_bank),.read_req_epoch(srd_req_epoch),.read_req_addr(srd_req_addr),.read_resp_valid(srd_resp_valid),.read_resp_ready(srd_resp_ready),.read_resp_data(srd_resp_data),.read_resp_bank(srd_resp_bank),.read_resp_epoch(srd_resp_epoch),.read_resp_addr(srd_resp_addr),
      .bank0_state(),.bank1_state(),.bank0_epoch(),.bank1_epoch(),.active_read_bank(s_active_read_bank),.active_read_epoch(),.active_write(store_active_write),.active_write_bank(),.write_epoch_active(),.write_count(store_write_count),.write_expected_words(),.write_last_seen(store_write_last_seen),.error(store_error),.error_code(store_error_code));

    assign output_write_valid = sink_valid && store_active_write;
    assign ds1_write_ready = store_write_ready && !sink_valid;
    assign output_write_addr = sink_addr - 32'h00200000;
    assign output_write_data = sink_data; assign output_write_be = sink_strb;
    assign sink_ready = output_write_ready && store_write_ready;
    assign ready = rst_n && (state == S_IDLE) && cfg_active_valid && (cfg_active_layer == 2'd2);
    assign busy = state != S_IDLE;
    assign write_count = store_write_count;
    assign atomic_commit = store_swap;

    wire c_dw_en,c_dw_bank,c_pw_en,c_pw_bank,cfg_rd_en;
    wire [15:0] c_dw_addr,c_pw_addr,cfg_rd_addr;
    wire [15:0] cfg_index; wire [31:0] cfg_payload;
    assign srd_req_valid = (state==S_RUN) ? r_req_valid : read_req_valid;
    assign srd_req_bank = (state==S_RUN) ? r_req_bank : read_req_bank;
    assign srd_req_epoch = (state==S_RUN) ? r_read_epoch : read_req_epoch;
    assign srd_req_addr = (state==S_RUN) ? r_req_addr : read_req_addr;
    assign srd_resp_ready = (state==S_RUN) ? r_resp_ready : read_resp_ready;
    assign read_req_ready = (state==S_RUN) ? 1'b0 : srd_req_ready;
    assign read_resp_valid = (state==S_RUN) ? 1'b0 : srd_resp_valid;
    assign read_resp_data=srd_resp_data; assign read_resp_bank=srd_resp_bank; assign read_resp_epoch=srd_resp_epoch; assign read_resp_addr=srd_resp_addr;
    wire [31:0] cfg_rd_data; wire cfg_rd_valid;
    assign cfg_rd_en = (state == S_PW_CFG) ? c_pw_en : c_dw_en;
    assign cfg_rd_bank = (state == S_PW_CFG) ? c_pw_bank : c_dw_bank;
    assign cfg_rd_addr = (state == S_PW_CFG) ? c_pw_addr : c_dw_addr;
    assign cfg_rd_data = cfg_rd_data_i; assign cfg_rd_valid = cfg_rd_valid_i;
    wire cfg_rd_bank; wire [31:0] cfg_rd_data_i; wire cfg_rd_valid_i;
    ds12_stream_config_banks #(.BANK_WORDS(CFG_WORDS),.REQUEST_FIFO_WORDS(8)) cfg (
      .clk(clk),.rst_n(rst_n),.start(cfg_load_start),.start_layer(cfg_start_layer),.start_base_addr(cfg_start_base_addr),.start_word_count(cfg_start_word_count),.start_epoch(epoch),.start_ready(cfg_start_ready),
      .mem_req_valid(cfg_mem_req_valid),.mem_req_ready(cfg_mem_req_ready),.mem_req_addr(cfg_mem_req_addr),.mem_req_strb(cfg_mem_req_strb),.mem_req_word_index(cfg_mem_req_word_index),.mem_resp_valid(cfg_mem_resp_valid),.mem_resp_ready(cfg_mem_resp_ready),.mem_resp_rdata(cfg_mem_resp_rdata),.commit_req(cfg_commit),.clear_error(1'b0),.cfg_rd_en(cfg_rd_en),.cfg_rd_bank(cfg_rd_bank),.cfg_rd_addr(cfg_rd_addr),.cfg_rd_data(cfg_rd_data_i),.cfg_rd_valid(cfg_rd_valid_i),.busy(),.active_bank(cfg_active_bank),.active_layer(cfg_active_layer),.active_epoch(cfg_active_epoch),.active_valid(cfg_active_valid),.bank_valid(),.expected_count(),.issued_count(),.received_count(),.load_crc32(),.load_done(cfg_load_done),.error(cfg_error),.error_code(cfg_error_code));

    wire r_start_ready,r_valid,r_ready,r_last,r_req_valid,r_req_ready,r_resp_valid,r_resp_ready;
    wire [127:0] r_data; wire [5:0] r_row,r_col; wire [1:0] r_tr,r_tc,r_ctx; wire r_slice,r_owner; wire [31:0] r_epoch,r_req_addr; wire r_req_bank;
    wire dw_ready_idle; wire dw_ready, dw_valid; wire [127:0] dw_data; wire [5:0] dw_row; wire [7:0] dw_pixel; wire dw_group; wire [1:0] dw_context; wire dw_owner; wire [31:0] dw_epoch; wire dw_last;
    wire [1:0] pw_context; wire pw_owner; wire [31:0] pw_epoch;
    assign pw_context = dw_pixel[4:3]; assign pw_owner = dw_pixel[5]; assign pw_epoch = epoch;
    wire dw_done,dw_error; wire [7:0] dw_ec; wire [31:0] dw_wc,dw_dc,dw_mc,dw_pc,dw_cfgc; wire [3:0] dw_peak;
    wire pw_ready,pw_done,pw_error; wire [7:0] pw_ec; wire [31:0] pw_cfgc,pw_wcfgc,pw_dwc,pw_tok,pw_mac,pw_out; wire [3:0] pw_peak;
    reg run_start;
    wire [31:0] r_read_epoch;
    ds12_stream_ds2_window_vector_reader reader(.clk(clk),.rst_n(rst_n),.window_start_valid(state==S_RUN && win_issue<256),.window_start_ready(r_start_ready),.window_start_row(win_issue[7:4]),.window_start_col(win_issue[3:0]),.window_start_bank(s_active_read_bank),.window_start_epoch(epoch),.window_start_last(win_issue==255),.window_valid(r_valid),.window_ready(r_ready),.window_data(r_data),.window_row(r_row),.window_col(r_col),.window_tap_row(r_tr),.window_tap_col(r_tc),.window_channel_slice(r_slice),.window_context(r_ctx),.window_owner(r_owner),.window_epoch(r_epoch),.window_last(r_last),.read_req_valid(r_req_valid),.read_req_ready(r_req_ready),.read_req_bank(r_req_bank),.read_req_epoch(r_read_epoch),.read_req_addr(r_req_addr),.read_resp_valid(r_resp_valid),.read_resp_ready(r_resp_ready),.read_resp_data(srd_resp_data),.read_resp_bank(srd_resp_bank),.read_resp_epoch(srd_resp_epoch),.read_resp_addr(srd_resp_addr),.busy(),.context_active(),.context_peak(),.read_count(),.window_count(),.error(),.error_code());
    // Reader owns the store read port while the layer runs.
    assign r_req_ready = srd_req_ready; assign r_resp_valid = srd_resp_valid; assign r_resp_ready = 1'b1;
    ds12_stream_ds2_dw_compute dw(.clk(clk),.rst_n(rst_n),.start(dw_start_v),.ready(),.cfg_rd_en(c_dw_en),.cfg_rd_bank(c_dw_bank),.cfg_rd_addr(c_dw_addr),.cfg_rd_data(cfg_rd_data_i),.cfg_rd_valid(cfg_rd_valid_i),.cfg_active_valid(cfg_active_valid),.cfg_active_layer(cfg_active_layer),.cfg_active_bank(cfg_active_bank),.cfg_active_epoch(cfg_active_epoch),.config_index(),.config_payload(),.window_valid(r_valid),.window_ready(r_ready),.window_data(r_data),.window_row(r_row),.window_col(r_col),.window_tap_row(r_tr),.window_tap_col(r_tc),.window_channel_slice(r_slice),.window_context(r_ctx),.window_owner(r_owner),.window_epoch(r_epoch),.window_last(r_last),.dw_valid(dw_valid),.dw_ready(dw_ready),.dw_data(dw_data),.dw_row(dw_row),.dw_pixel(dw_pixel),.dw_group(dw_group),.dw_context(dw_context),.dw_owner(dw_owner),.dw_epoch(dw_epoch),.dw_last(dw_last),.done(dw_done),.error(dw_error),.error_code(dw_ec),.window_vector_count(dw_wc),.dw_vector_count(dw_dc),.dw_mac_count(dw_mc),.padding_tap_count(dw_pc),.context_peak(dw_peak),.config_read_count(dw_cfgc));
    ds12_stream_ds2_pw_consumer pw(.clk(clk),.rst_n(rst_n),.start(pw_start_v),.ready(pw_ready),.cfg_rd_en(c_pw_en),.cfg_rd_bank(c_pw_bank),.cfg_rd_addr(c_pw_addr),.cfg_rd_data(cfg_rd_data_i),.cfg_rd_valid(cfg_rd_valid_i),.cfg_active_valid(cfg_active_valid),.cfg_active_layer(cfg_active_layer),.cfg_active_bank(cfg_active_bank),.cfg_active_epoch(cfg_active_epoch),.config_index(),.config_payload(),.dw_valid(dw_valid),.dw_ready(dw_ready),.dw_data(dw_data),.dw_row(dw_row),.dw_pixel(dw_pixel),.dw_group(dw_group),.dw_context(pw_context),.dw_owner(pw_owner),.dw_epoch(pw_epoch),.dw_last(dw_last),.sink_valid(sink_valid),.sink_ready(sink_ready),.sink_addr(sink_addr),.sink_data(sink_data),.sink_strb(sink_strb),.sink_row(),.sink_pixel(),.sink_word_in_pixel(),.sink_context(),.sink_owner(),.sink_epoch(),.sink_last(sink_last),.busy(),.done(pw_done),.error(pw_error),.error_code(pw_ec),.cfg_read_count(pw_cfgc),.cfg_weight_read_count(pw_wcfgc),.dw_vector_count(pw_dwc),.pw_token_count(pw_tok),.pw_mac_count(pw_mac),.output_word_count(pw_out),.partial_context_peak(pw_peak));

    assign error = store_error | dw_error | pw_error; assign error_code = store_error_code | dw_ec | pw_ec;
    assign window_count=dw_wc; assign dw_vector_count=dw_dc; assign dw_mac_count=dw_mc; assign pw_token_count=pw_tok; assign pw_mac_count=pw_mac; assign output_word_count=pw_out; assign config_read_count=dw_cfgc+pw_cfgc; assign config_weight_read_count=pw_wcfgc;
    always @(posedge clk) begin
      if(!rst_n) begin state<=S_IDLE; win_issue<=0; target_bank<=0; store_start_v<=0; store_commit_v<=0; pw_start_v<=0; dw_start_v<=0; done<=0; end else begin
        store_start_v<=0; store_commit_v<=0; pw_start_v<=0; dw_start_v<=0; done<=0;
        if(state==S_IDLE && start && ready) begin target_bank<=~s_active_read_bank; store_start_v<=1; pw_start_v<=1; state<=S_PW_CFG; end
        else if(state==S_PW_CFG && pw_wcfgc>=512 && pw_ready) begin pw_start_v<=1; dw_start_v<=1; state<=S_DW_CFG; end
        else if(state==S_DW_CFG && dw_cfgc>=168) begin dw_start_v<=1; state<=S_RUN; run_start<=1; end
        else if(state==S_RUN) begin if(r_start_ready && win_issue<256) win_issue<=win_issue+1; if(pw_done) state<=S_DRAIN; end
        else if(state==S_DRAIN && store_commit_ready && store_write_last_seen && store_write_count==4096) begin store_commit_v<=1; state<=S_IDLE; done<=1; end
      end
    end
endmodule
`default_nettype wire
