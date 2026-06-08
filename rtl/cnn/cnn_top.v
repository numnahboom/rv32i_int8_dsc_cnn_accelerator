`timescale 1ns/1ps
`default_nettype none

module cnn_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [1:0]  cmd_type,
    input  wire [31:0] desc_base_addr,
    input  wire [31:0] layer_num,

    output wire [31:0] status,

    output wire        mem_req_valid,
    output wire        mem_req_write,
    output wire [31:0] mem_req_addr,
    output wire [31:0] mem_req_wdata,
    input  wire        mem_req_ready,

    input  wire        mem_resp_valid,
    input  wire [31:0] mem_resp_rdata
);
    localparam CMD_START = 2'd0;

    wire cmd_fire;
    wire ctrl_start;
    wire ctrl_busy;
    wire ctrl_done;
    wire ctrl_error;
    wire [7:0] current_layer;
    wire fetch_start;
    wire [31:0] fetch_layer_index;
    wire desc_busy;
    wire desc_valid;
    wire [1023:0] desc_words;
    wire [31:0] desc_op_type;
    wire layer_start;
    wire layer_busy;
    wire layer_done;
    wire layer_error;
    wire layer_mem_req_valid;
    wire layer_mem_req_write;
    wire [31:0] layer_mem_req_addr;
    wire [31:0] layer_mem_req_wdata;
    wire layer_sram_input_rd_en;
    wire [14:0] layer_sram_input_rd_addr;
    wire layer_sram_input_rd_valid;
    wire signed [7:0] layer_sram_input_rd_data;
    wire layer_sram_output_wr_en;
    wire [14:0] layer_sram_output_wr_addr;
    wire signed [7:0] layer_sram_output_wr_data;
    wire desc_mem_req_valid;
    wire desc_mem_req_write;
    wire [31:0] desc_mem_req_addr;
    wire [31:0] desc_mem_req_wdata;
    wire desc_bus_active;
    wire [31:0] total_cycles;
    wire [31:0] layer_cycles;
    wire [7:0] counter_layer;
    wire [31:0] ctrl_layer_num;
    wire feature_input_bank_sel;
    wire feature_output_bank_sel;
    wire feature_host_rd_valid_unused;
    wire signed [7:0] feature_host_rdata_unused;
    wire desc_sram_swap_on_done;

    reg [31:0] desc_base_latched;
    reg [31:0] layer_num_latched;
    reg done_latched;
    reg error_latched;

    assign cmd_ready = !ctrl_busy;
    assign cmd_fire = cmd_valid && cmd_ready;
    assign ctrl_start = cmd_fire && (cmd_type == CMD_START);
    assign ctrl_layer_num = ctrl_start ? layer_num : layer_num_latched;

    cnn_top_ctrl u_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .start(ctrl_start),
        .layer_num(ctrl_layer_num),
        .desc_valid(desc_valid),
        .desc_op_type(desc_op_type),
        .layer_done(layer_done),
        .layer_error(layer_error),
        .busy(ctrl_busy),
        .done(ctrl_done),
        .error(ctrl_error),
        .current_layer(current_layer),
        .fetch_start(fetch_start),
        .fetch_layer_index(fetch_layer_index),
        .layer_start(layer_start)
    );

    descriptor_fetch u_descriptor_fetch (
        .clk(clk),
        .rst_n(rst_n),
        .start(fetch_start),
        .desc_base_addr(desc_base_latched),
        .layer_index(fetch_layer_index),
        .busy(desc_busy),
        .valid(desc_valid),
        .desc_words(desc_words),
        .op_type(desc_op_type),
        .mem_req_valid(desc_mem_req_valid),
        .mem_req_write(desc_mem_req_write),
        .mem_req_addr(desc_mem_req_addr),
        .mem_req_wdata(desc_mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid(desc_bus_active ? mem_resp_valid : 1'b0),
        .mem_resp_rdata(mem_resp_rdata)
    );

    cnn_layer_runner u_layer_runner (
        .clk(clk),
        .rst_n(rst_n),
        .start(layer_start),
        .desc_words(desc_words),
        .busy(layer_busy),
        .done(layer_done),
        .error(layer_error),
        .mem_req_valid(layer_mem_req_valid),
        .mem_req_write(layer_mem_req_write),
        .mem_req_addr(layer_mem_req_addr),
        .mem_req_wdata(layer_mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid(desc_bus_active ? 1'b0 : mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata),
        .sram_input_rd_en(layer_sram_input_rd_en),
        .sram_input_rd_addr(layer_sram_input_rd_addr),
        .sram_input_rd_valid(layer_sram_input_rd_valid),
        .sram_input_rd_data(layer_sram_input_rd_data),
        .sram_output_wr_en(layer_sram_output_wr_en),
        .sram_output_wr_addr(layer_sram_output_wr_addr),
        .sram_output_wr_data(layer_sram_output_wr_data)
    );

    feature_sram_pingpong u_feature_sram (
        .clk(clk),
        .rst_n(rst_n),
        .reset_to_a(ctrl_start),
        .layer_done(layer_done && desc_sram_swap_on_done),
        .input_bank_sel(feature_input_bank_sel),
        .output_bank_sel(feature_output_bank_sel),
        .input_rd_en(layer_sram_input_rd_en),
        .input_rd_addr(layer_sram_input_rd_addr),
        .input_rd_valid(layer_sram_input_rd_valid),
        .input_rd_data(layer_sram_input_rd_data),
        .output_wr_en(layer_sram_output_wr_en),
        .output_wr_addr(layer_sram_output_wr_addr),
        .output_wr_data(layer_sram_output_wr_data),
        .host_wr_en(1'b0),
        .host_bank_sel(1'b0),
        .host_addr(15'd0),
        .host_wdata(8'sd0),
        .host_rd_en(1'b0),
        .host_rd_valid(feature_host_rd_valid_unused),
        .host_rdata(feature_host_rdata_unused)
    );

    status_counter u_status_counter (
        .clk(clk),
        .rst_n(rst_n),
        .clear(ctrl_start),
        .enable(ctrl_busy),
        .layer_start(layer_start),
        .layer_idx(current_layer),
        .total_cycles(total_cycles),
        .layer_cycles(layer_cycles),
        .active_layer(counter_layer)
    );

    assign desc_bus_active = desc_busy || fetch_start;
    assign desc_sram_swap_on_done = desc_words[(18*32) + 4];
    assign mem_req_valid = desc_bus_active ? desc_mem_req_valid : layer_mem_req_valid;
    assign mem_req_write = desc_bus_active ? desc_mem_req_write : layer_mem_req_write;
    assign mem_req_addr = desc_bus_active ? desc_mem_req_addr : layer_mem_req_addr;
    assign mem_req_wdata = desc_bus_active ? desc_mem_req_wdata : layer_mem_req_wdata;

    assign status = {
        total_cycles[23:0],
        current_layer[3:0],
        1'b0,
        error_latched || ctrl_error,
        done_latched,
        ctrl_busy
    };

    always @(posedge clk) begin
        if (!rst_n) begin
            desc_base_latched <= 32'd0;
            layer_num_latched <= 32'd0;
            done_latched <= 1'b0;
            error_latched <= 1'b0;
        end else begin
            if (cmd_fire) begin
                done_latched <= 1'b0;
                error_latched <= (cmd_type != CMD_START);
                if (cmd_type == CMD_START) begin
                    desc_base_latched <= desc_base_addr;
                    layer_num_latched <= layer_num;
                end
            end

            if (ctrl_done) begin
                done_latched <= 1'b1;
            end
            if (ctrl_error) begin
                error_latched <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
