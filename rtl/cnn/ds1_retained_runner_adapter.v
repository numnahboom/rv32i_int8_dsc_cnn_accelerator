`timescale 1ns/1ps
`default_nettype none

/*
 * Runner boundary for the retained DS1 orchestrator.
 *
 * The production runner's phase loader remains the owner of the external
 * descriptor/parameter bus.  This adapter observes the accepted scalar DS
 * configuration writes, repacks them into the retained producer's vector
 * configuration protocol, and translates the orchestrator's source requests
 * and vec4 result into the existing feature-SRAM word ABI.  The module is
 * instantiated only when USE_DS1_RETAINED_ORCHESTRATOR is enabled in the
 * runner; its disabled generate branch is pure tie-off logic.
 */
module ds1_retained_runner_adapter #(
    parameter integer ADDR_WIDTH = 24,
    parameter integer SRAM_ADDR_WIDTH = 15,
    parameter integer MAX_CIN = 128,
    parameter integer FIFO_DEPTH = 8
) (
    input wire clk,
    input wire rst_n,

    input wire layer_start_valid,
    output wire layer_start_ready,
    input wire [ADDR_WIDTH-1:0] input_base_addr,
    input wire [7:0] input_zero_point,

    input wire config_write_en,
    input wire [3:0] config_target,
    input wire [15:0] config_index,
    input wire [31:0] config_data,

    input wire [31:0] dw_output_zero_point,
    input wire [31:0] dw_activation_min,
    input wire [31:0] dw_activation_max,
    input wire signed [31:0] pw_output_zero_point,
    input wire signed [31:0] pw_activation_min,
    input wire signed [31:0] pw_activation_max,

    output wire source_word_en,
    output wire [SRAM_ADDR_WIDTH-1:0] source_word_addr,
    input wire source_word_valid,
    input wire [31:0] source_word_data,

    output wire output_word_en,
    output wire [15:0] output_word_addr,
    output wire [31:0] output_word_data,
    output wire [3:0] output_word_be,

    output wire done,
    output wire error,
    output wire busy
);
    localparam [3:0] CFG_DW_WEIGHT = 4'd1;
    localparam [3:0] CFG_DW_BIAS   = 4'd2;
    localparam [3:0] CFG_DW_MUL    = 4'd3;
    localparam [3:0] CFG_DW_SHIFT  = 4'd4;
    localparam [3:0] CFG_PW_WEIGHT = 4'd5;
    localparam [3:0] CFG_PW_BIAS   = 4'd6;
    localparam [3:0] CFG_PW_MUL    = 4'd7;
    localparam [3:0] CFG_PW_SHIFT  = 4'd8;

    reg signed [7:0] dw_weight_mem [0:143];
    reg signed [31:0] dw_bias_mem [0:15];
    reg signed [31:0] dw_mul_mem [0:15];
    reg [5:0] dw_shift_mem [0:15];
    reg signed [7:0] pw_weight_mem [0:511];
    reg signed [31:0] pw_bias_mem [0:31];
    reg signed [31:0] pw_mul_mem [0:31];
    reg [5:0] pw_shift_mem [0:31];
    reg config_complete;

    reg cfg_send_active;
    reg [3:0] cfg_send_idx;
    wire cfg_send_valid = cfg_send_active;
    wire cfg_send_ready;
    wire cfg_send_fire = cfg_send_valid && cfg_send_ready;

    reg signed [127:0] cfg_weight_vec;
    reg signed [511:0] cfg_bias_vec;
    reg signed [511:0] cfg_multiplier_vec;
    reg [95:0] cfg_shift_vec;
    integer cfg_i;
    always @* begin
        cfg_weight_vec = 128'sd0;
        cfg_bias_vec = 512'sd0;
        cfg_multiplier_vec = 512'sd0;
        cfg_shift_vec = 96'd0;
        for (cfg_i = 0; cfg_i < 16; cfg_i = cfg_i + 1) begin
            cfg_weight_vec[(cfg_i * 8) +: 8] =
                dw_weight_mem[(cfg_send_idx * 16) + cfg_i];
            cfg_bias_vec[(cfg_i * 32) +: 32] = dw_bias_mem[cfg_i];
            cfg_multiplier_vec[(cfg_i * 32) +: 32] = dw_mul_mem[cfg_i];
            cfg_shift_vec[(cfg_i * 6) +: 6] = dw_shift_mem[cfg_i];
        end
    end

    reg signed [1023:0] final_bias_table;
    reg signed [1023:0] final_multiplier_table;
    reg [191:0] final_shift_table;
    integer table_i;
    always @* begin
        final_bias_table = 1024'sd0;
        final_multiplier_table = 1024'sd0;
        final_shift_table = 192'd0;
        for (table_i = 0; table_i < 32; table_i = table_i + 1) begin
            final_bias_table[(table_i * 32) +: 32] = pw_bias_mem[table_i];
            final_multiplier_table[(table_i * 32) +: 32] = pw_mul_mem[table_i];
            final_shift_table[(table_i * 6) +: 6] = pw_shift_mem[table_i];
        end
    end

    wire orch_mem_req_valid;
    wire orch_mem_req_ready = 1'b1;
    wire [ADDR_WIDTH-1:0] orch_mem_req_addr;
    wire orch_start_ready;
    wire orch_done;
    wire orch_error;
    wire orch_busy;
    wire orch_cfg_ready;
    wire orch_weight_valid;
    wire [3:0] orch_weight_k_index;
    wire [1:0] orch_weight_cout_group;
    reg signed [63:0] orch_pw_weight_vec;
    integer weight_i;
    always @* begin
        orch_pw_weight_vec = 64'sd0;
        for (weight_i = 0; weight_i < 8; weight_i = weight_i + 1) begin
            orch_pw_weight_vec[(weight_i * 8) +: 8] =
                pw_weight_mem[(orch_weight_cout_group * 8) +
                              (orch_weight_k_index * 32) + weight_i];
        end
    end

    wire orch_out_valid;
    wire [15:0] orch_out_byte_addr;
    wire signed [31:0] orch_out_data;
    wire [3:0] orch_out_byte_be;

    assign layer_start_ready = config_complete && orch_start_ready;
    assign source_word_en = orch_mem_req_valid;
    assign source_word_addr = orch_mem_req_addr[SRAM_ADDR_WIDTH-1:0];
    assign output_word_en = orch_out_valid;
    assign output_word_addr = orch_out_byte_addr;
    assign output_word_data = orch_out_data;
    assign output_word_be = orch_out_byte_be;
    assign done = orch_done;
    assign error = orch_error;
    assign busy = orch_busy || cfg_send_active ||
                  (layer_start_valid && !layer_start_ready);

    ds1_retained_full_layer_orchestrator #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .WORD_COUNT_WIDTH(16),
        .EPOCH_WIDTH(4),
        .TILE_WIDTH(8),
        .FIFO_DEPTH(FIFO_DEPTH),
        .USE_FINAL_PARAM_TABLE(1)
    ) u_orchestrator (
        .clk(clk), .rst_n(rst_n),
        .start_valid(layer_start_valid && layer_start_ready),
        .start_ready(orch_start_ready),
        .input_base_addr(input_base_addr),
        .input_zero_point(input_zero_point),
        .start_epoch(4'd0),
        .mem_req_valid(orch_mem_req_valid),
        .mem_req_ready(orch_mem_req_ready),
        .mem_req_addr(orch_mem_req_addr),
        .mem_resp_valid(source_word_valid),
        .mem_resp_data(source_word_data),
        .cfg_valid(cfg_send_valid),
        .cfg_ready(cfg_send_ready),
        .cfg_tap_idx(cfg_send_idx),
        .cfg_weight_vec(cfg_weight_vec),
        .cfg_bias_vec(cfg_bias_vec),
        .cfg_multiplier_vec(cfg_multiplier_vec),
        .cfg_shift_vec(cfg_shift_vec),
        .dw_output_zero_point(dw_output_zero_point),
        .dw_activation_min(dw_activation_min),
        .dw_activation_max(dw_activation_max),
        .pw_weight_vec(orch_pw_weight_vec),
        .weight_valid(orch_weight_valid),
        .weight_k_index(orch_weight_k_index),
        .weight_cout_group(orch_weight_cout_group),
        .final_bias_vec(256'sd0),
        .final_multiplier_vec(256'sd0),
        .final_shift_vec(48'd0),
        .final_bias_table(final_bias_table),
        .final_multiplier_table(final_multiplier_table),
        .final_shift_table(final_shift_table),
        .final_output_zero_point_int32(pw_output_zero_point),
        .final_activation_min_int32(pw_activation_min),
        .final_activation_max_int32(pw_activation_max),
        .out_valid_vec4(orch_out_valid),
        .out_ready_vec4(1'b1),
        .out_data_int8_vec4(orch_out_data),
        .out_pixel_idx_vec4(),
        .out_channel_idx_vec4(),
        .out_byte_addr_vec4(orch_out_byte_addr),
        .out_word_addr_vec4(),
        .out_byte_en_vec4(orch_out_byte_be),
        .error(orch_error), .busy(orch_busy), .done(orch_done),
        .overlap_count(), .overlap_cycles()
    );

    integer reset_i;
    always @(posedge clk) begin
        if (!rst_n) begin
            config_complete <= 1'b0;
            cfg_send_active <= 1'b0;
            cfg_send_idx <= 4'd0;
            /* verilator lint_off BLKSEQ */
            for (reset_i = 0; reset_i < 144; reset_i = reset_i + 1)
                dw_weight_mem[reset_i] = 8'sd0;
            for (reset_i = 0; reset_i < 16; reset_i = reset_i + 1) begin
                dw_bias_mem[reset_i] = 32'sd0;
                dw_mul_mem[reset_i] = 32'sd0;
                dw_shift_mem[reset_i] = 6'd0;
            end
            for (reset_i = 0; reset_i < 512; reset_i = reset_i + 1)
                pw_weight_mem[reset_i] = 8'sd0;
            for (reset_i = 0; reset_i < 32; reset_i = reset_i + 1) begin
                pw_bias_mem[reset_i] = 32'sd0;
                pw_mul_mem[reset_i] = 32'sd0;
                pw_shift_mem[reset_i] = 6'd0;
            end
            /* verilator lint_on BLKSEQ */
        end else begin
            if (config_write_en) begin
                case (config_target)
                    CFG_DW_WEIGHT:
                        if (config_index < 16'd144)
                            dw_weight_mem[config_index] <= config_data[7:0];
                    CFG_DW_BIAS:
                        if (config_index < 16'd16)
                            dw_bias_mem[config_index] <= config_data;
                    CFG_DW_MUL:
                        if (config_index < 16'd16)
                            dw_mul_mem[config_index] <= config_data;
                    CFG_DW_SHIFT:
                        if (config_index < 16'd16)
                            dw_shift_mem[config_index] <= config_data[5:0];
                    CFG_PW_WEIGHT: begin
                        /* The legacy phase-loader index uses MAX_CIN stride;
                         * compact the strict DS1 Cin=16 table here. */
                        if ((config_index / MAX_CIN) < 16'd32 &&
                            (config_index % MAX_CIN) < 16'd16)
                            pw_weight_mem[((config_index / MAX_CIN) * 16) +
                                          (config_index % MAX_CIN)] <=
                                config_data[7:0];
                    end
                    CFG_PW_BIAS:
                        if (config_index < 16'd32)
                            pw_bias_mem[config_index] <= config_data;
                    CFG_PW_MUL:
                        if (config_index < 16'd32)
                            pw_mul_mem[config_index] <= config_data;
                    CFG_PW_SHIFT: begin
                        if (config_index < 16'd32) begin
                            pw_shift_mem[config_index] <= config_data[5:0];
                            if (config_index == 16'd31)
                                config_complete <= 1'b1;
                        end
                    end
                    default: begin end
                endcase
            end

            if (layer_start_valid && layer_start_ready) begin
                cfg_send_active <= 1'b1;
                cfg_send_idx <= 4'd0;
            end else if (cfg_send_fire) begin
                if (cfg_send_idx == 4'd8)
                    cfg_send_active <= 1'b0;
                else
                    cfg_send_idx <= cfg_send_idx + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
