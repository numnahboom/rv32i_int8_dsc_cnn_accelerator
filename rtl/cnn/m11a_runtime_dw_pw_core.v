`timescale 1ns/1ps
`default_nettype none

/*
 * M1.1-A independent runtime DW16 -> PW64 core.
 *
 * This top is intentionally standalone and not connected to a production
 * network shell or any legacy adapter.
 * It is the direct unit/OOC boundary used to validate the real DS1/DS2
 * descriptor, packed-configuration, arithmetic, and elastic-stream
 * contracts.  There is one DW16 producer, one eight-pixel packer, and one
 * PW64/PWRQ4 consumer.
 */
module m11a_runtime_dw_pw_core (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         cfg_valid,
    output wire         cfg_ready,
    input  wire [1:0]   cfg_layer,
    input  wire [9:0]   cfg_index,
    input  wire [31:0]  cfg_data,
    input  wire         cfg_commit_valid,
    output wire         cfg_commit_ready,
    input  wire [1:0]   cfg_commit_layer,

    input  wire         start_valid,
    output wire         start_ready,
    input  wire [1:0]   desc_layer,
    input  wire [5:0]   desc_in_h,
    input  wire [5:0]   desc_in_w,
    input  wire [5:0]   desc_cin,
    input  wire [6:0]   desc_cout,
    input  wire [1:0]   desc_stride,
    input  wire [31:0]  desc_input_base,
    input  wire [31:0]  desc_input_row_stride,
    input  wire [7:0]   desc_input_zero_point,
    input  wire [31:0]  desc_dw_output_zero_point,
    input  wire [31:0]  desc_pw_output_zero_point,
    input  wire [31:0]  desc_activation_min,
    input  wire [31:0]  desc_activation_max,
    input  wire [31:0]  desc_sink_base,

    output wire         mem_req_valid,
    input  wire         mem_req_ready,
    output wire [31:0]  mem_req_addr,
    input  wire         mem_resp_valid,
    input  wire [127:0] mem_resp_data,

    output wire         out_valid,
    input  wire         out_ready,
    output wire [31:0]  out_addr,
    output wire [31:0]  out_data,
    output wire [3:0]   out_be,
    output wire [1:0]   out_context,
    output wire         out_owner,
    output wire [31:0]  out_epoch,
    output wire         out_last,

    output wire         busy,
    output wire         done,
    output wire         error,
    output wire [7:0]   error_code,
    output wire [31:0]  dw_mac_count,
    output wire [31:0]  dw_vector_count,
    output wire [31:0]  padding_tap_count,
    output wire [31:0]  input_read_count,
    output wire [31:0]  pw_token_count,
    output wire [31:0]  pw_mac_count,
    output wire [31:0]  out_word_count
);
    localparam [1:0] TOP_IDLE = 2'd0;
    localparam [1:0] TOP_PREP = 2'd1;
    localparam [1:0] TOP_RUN  = 2'd2;
    localparam [1:0] TOP_DONE = 2'd3;

    reg [1:0] top_state;
    reg prep_issued;
    wire loaded_ds1, loaded_ds2;
    wire cfg_error;
    wire prepare_busy, prepare_done;
    wire prepare_ready;
    wire prepare_valid = (top_state == TOP_PREP) && !prep_issued;
    wire prepare_fire = prepare_valid && prepare_ready;
    wire engine_start_valid = (top_state == TOP_PREP) && prepare_done;

    wire [2303:0] dw_weight_bus;
    wire [2047:0] dw_bias_bus, dw_multiplier_bus;
    wire [1023:0] dw_shift_bus;
    wire [2047:0] pw_bias_bus, pw_multiplier_bus;
    wire [383:0] pw_shift_bus;
    wire pw_row_rd_en;
    wire [8:0] pw_row_rd_addr;
    wire pw_row_valid;
    wire [63:0] pw_row_rd_data;

    m11a_runtime_cfg_store cfg_store (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_layer(cfg_layer),
        .cfg_index(cfg_index), .cfg_data(cfg_data),
        .cfg_commit_valid(cfg_commit_valid), .cfg_commit_ready(cfg_commit_ready),
        .cfg_commit_layer(cfg_commit_layer), .loaded_ds1(loaded_ds1),
        .loaded_ds2(loaded_ds2), .error(cfg_error),
        .prepare_valid(prepare_valid), .prepare_ready(prepare_ready),
        .prepare_layer(desc_layer), .prepare_cin(desc_cin), .prepare_cout(desc_cout),
        .prepare_busy(prepare_busy), .prepare_done(prepare_done),
        .pw_row_rd_en(pw_row_rd_en), .pw_row_rd_addr(pw_row_rd_addr),
        .pw_row_valid(pw_row_valid), .pw_row_rd_data(pw_row_rd_data),
        .dw_weight_bus(dw_weight_bus), .dw_bias_bus(dw_bias_bus),
        .dw_multiplier_bus(dw_multiplier_bus), .dw_shift_bus(dw_shift_bus),
        .pw_bias_bus(pw_bias_bus), .pw_multiplier_bus(pw_multiplier_bus),
        .pw_shift_bus(pw_shift_bus)
    );

    wire dw_valid, dw_ready;
    wire [127:0] dw_data;
    wire [9:0] dw_pixel;
    wire [1:0] dw_group, dw_context;
    wire dw_owner;
    wire [31:0] dw_epoch, dw_context_ordinal;
    wire dw_last;
    wire dw_done, dw_error;
    wire [31:0] dw_mac_count_w, dw_vector_count_w, dw_pad_count_w, input_read_count_w;

    m11a_dw16_shared_line dw16 (
        .clk(clk), .rst_n(rst_n), .start_valid(engine_start_valid), .start_ready(),
        .desc_layer(desc_layer), .desc_in_h(desc_in_h), .desc_in_w(desc_in_w),
        .desc_cin(desc_cin), .desc_cout(desc_cout), .desc_stride(desc_stride),
        .desc_input_base(desc_input_base), .desc_input_row_stride(desc_input_row_stride),
        .desc_input_zero_point(desc_input_zero_point),
        .desc_dw_output_zero_point(desc_dw_output_zero_point),
        .desc_dw_activation_min(desc_activation_min), .desc_dw_activation_max(desc_activation_max),
        .dw_weight_bus(dw_weight_bus), .dw_bias_bus(dw_bias_bus),
        .dw_multiplier_bus(dw_multiplier_bus), .dw_shift_bus(dw_shift_bus),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid),
        .mem_resp_data(mem_resp_data), .dw_valid(dw_valid), .dw_ready(dw_ready),
        .dw_data(dw_data), .dw_pixel(dw_pixel), .dw_group(dw_group),
        .dw_context(dw_context), .dw_owner(dw_owner), .dw_epoch(dw_epoch),
        .dw_context_ordinal(dw_context_ordinal), .dw_last(dw_last), .done(dw_done),
        .error(dw_error), .dw_mac_count(dw_mac_count_w),
        .dw_vector_count(dw_vector_count_w), .padding_tap_count(dw_pad_count_w),
        .input_read_count(input_read_count_w)
    );

    wire token_valid, token_ready;
    wire [63:0] token_activation;
    wire [8:0] token_weight_row;
    wire [2:0] token_cout_tile;
    wire [5:0] token_k;
    wire token_first_k, token_last_k, token_last_tile, token_last_layer;
    wire [1:0] token_context;
    wire token_owner;
    wire [31:0] token_epoch, token_context_ordinal;
    wire pack_done, pack_error;
    wire [31:0] token_count_w;

    m11a_context_packer packer (
        .clk(clk), .rst_n(rst_n), .start_valid(engine_start_valid), .start_ready(),
        .desc_layer(desc_layer), .desc_cin(desc_cin), .desc_cout(desc_cout),
        .dw_valid(dw_valid), .dw_ready(dw_ready), .dw_data(dw_data), .dw_pixel(dw_pixel),
        .dw_group(dw_group), .dw_context(dw_context), .dw_owner(dw_owner),
        .dw_epoch(dw_epoch), .dw_context_ordinal(dw_context_ordinal), .dw_last(dw_last),
        .token_valid(token_valid), .token_ready(token_ready),
        .token_activation(token_activation), .token_weight_row(token_weight_row),
        .token_cout_tile(token_cout_tile), .token_k(token_k),
        .token_first_k(token_first_k), .token_last_k(token_last_k),
        .token_last_tile(token_last_tile), .token_last_layer(token_last_layer),
        .token_context(token_context),
        .token_owner(token_owner), .token_epoch(token_epoch),
        .token_context_ordinal(token_context_ordinal), .done(pack_done),
        .error(pack_error), .token_count(token_count_w)
    );

    wire pw_done, pw_error;
    wire [31:0] pw_token_count_w, pw_mac_count_w, out_word_count_w;

    m11a_pw64_shared_core pw64 (
        .clk(clk), .rst_n(rst_n), .start_valid(engine_start_valid), .start_ready(),
        .desc_layer(desc_layer), .desc_cin(desc_cin), .desc_cout(desc_cout),
        .desc_sink_base(desc_sink_base), .desc_pw_output_zero_point(desc_pw_output_zero_point),
        .desc_pw_activation_min(desc_activation_min), .desc_pw_activation_max(desc_activation_max),
        .pw_bias_bus(pw_bias_bus), .pw_multiplier_bus(pw_multiplier_bus),
        .pw_shift_bus(pw_shift_bus), .pw_row_rd_en(pw_row_rd_en),
        .pw_row_rd_addr(pw_row_rd_addr), .pw_row_valid(pw_row_valid),
        .pw_row_rd_data(pw_row_rd_data), .token_valid(token_valid),
        .token_ready(token_ready), .token_activation(token_activation),
        .token_weight_row(token_weight_row), .token_cout_tile(token_cout_tile),
        .token_k(token_k), .token_first_k(token_first_k), .token_last_k(token_last_k),
        .token_last_tile(token_last_tile), .token_last_layer(token_last_layer),
        .token_context(token_context),
        .token_owner(token_owner), .token_epoch(token_epoch),
        .token_context_ordinal(token_context_ordinal), .out_valid(out_valid),
        .out_ready(out_ready), .out_addr(out_addr), .out_data(out_data),
        .out_be(out_be), .out_context(out_context), .out_owner(out_owner),
        .out_epoch(out_epoch), .out_last(out_last), .done(pw_done), .error(pw_error),
        .pw_token_count(pw_token_count_w), .pw_mac_count(pw_mac_count_w),
        .out_word_count(out_word_count_w)
    );

    assign start_ready = rst_n && (top_state == TOP_IDLE) &&
                         ((desc_layer == 2'd1 && loaded_ds1) ||
                          (desc_layer == 2'd2 && loaded_ds2));
    assign busy = (top_state != TOP_IDLE) && (top_state != TOP_DONE);
    assign done = (top_state == TOP_DONE);
    assign error = cfg_error | dw_error | pack_error | pw_error;
    assign error_code = {4'd0, cfg_error, dw_error, pack_error, pw_error};
    assign dw_mac_count = dw_mac_count_w;
    assign dw_vector_count = dw_vector_count_w;
    assign padding_tap_count = dw_pad_count_w;
    assign input_read_count = input_read_count_w;
    assign pw_token_count = pw_token_count_w;
    assign pw_mac_count = pw_mac_count_w;
    assign out_word_count = out_word_count_w;

    always @(posedge clk) begin
        if (!rst_n) begin
            top_state <= TOP_IDLE;
            prep_issued <= 1'b0;
        end else begin
            if (start_valid && start_ready) begin
                top_state <= TOP_PREP;
                prep_issued <= 1'b0;
            end
            if (prepare_fire)
                prep_issued <= 1'b1;
            if (engine_start_valid)
                top_state <= TOP_RUN;
            if (pw_done)
                top_state <= TOP_DONE;
        end
    end
endmodule

`default_nettype wire
