`timescale 1ns/1ps
`default_nettype none

/*
 * Local production adapter for the persistent DS dataflow.
 *
 * The runner has already loaded the DW result tile and the packed PW weight
 * rows into BRAM.  This adapter turns those two synchronous row ports into
 * the same one-token-per-K ABI used by the shared unified64 arithmetic
 * island.  An eight-pixel activation window is gathered once per pixel
 * block, then reused for all output-channel blocks.  There is no external
 * wide data bus and the activation cache is explicitly a register array
 * (not inferred LUTRAM); the generated write compares and two-level read
 * select keep the physical ownership local.
 *
 * The output side is intentionally a block fence: after the final token has
 * been accepted, the adapter waits for the final 8x8 result beat before
 * opening the next output-channel block.  This preserves exactly-once
 * block ordering under arbitrary shared-array output backpressure.
 */
module ds_persistent_pw_row_feed #(
    parameter integer MAX_CIN = 128,
    parameter integer MAX_COUT = 256,
    parameter integer MAX_PIXELS = 64
) (
    input wire clk,
    input wire rst_n,
    input wire start,
    output wire busy,
    output reg done,
    output reg error,
    input wire [7:0] channels,
    input wire [8:0] out_channels,
    input wire [7:0] output_pixels,

    output wire source_rd_en,
    output wire [5:0] source_rd_pixel_base,
    output wire [7:0] source_rd_channel_idx,
    input wire source_rd_valid,
    input wire signed [63:0] source_rd_data,

    output wire weight_rd_en,
    output wire [8:0] weight_rd_cout_base,
    output wire [7:0] weight_rd_channel_idx,
    input wire weight_rd_valid,
    input wire signed [63:0] weight_rd_data,

    output wire token_valid,
    input wire token_ready,
    output wire token_first,
    output wire token_last,
    output wire [7:0] token_k_idx,
    output wire signed [63:0] token_act_vec,
    output wire signed [63:0] token_wgt_vec,
    output wire [7:0] token_pixel_base,
    output wire [8:0] token_cout_base,
    output wire [7:0] token_pixel_mask,
    output wire [7:0] token_cout_mask,

    input wire result_valid,
    input wire result_ready,
    input wire [10:0] result_pixel_idx,
    input wire [8:0] result_channel_base,
    input wire [3:0] result_lane_mask,
    output wire [7:0] block_pixel_base,
    output wire [8:0] block_cout_base,
    output wire [31:0] metric_source_window_reads,
    output wire [31:0] metric_window_reuse,
    output wire [31:0] metric_token_count
);
    localparam [2:0] S_IDLE = 3'd0, S_GATHER = 3'd1,
                     S_FEED = 3'd2, S_DRAIN = 3'd3;
    reg [2:0] state;
    reg [7:0] channels_reg;
    reg [8:0] out_channels_reg;
    reg [7:0] output_pixels_reg;
    reg [7:0] pixel_base_reg;
    reg [8:0] cout_base_reg;
    reg [7:0] source_issue_idx;
    reg [7:0] source_resp_idx;
    reg [7:0] weight_issue_idx;
    reg [7:0] weight_resp_idx;
    reg token_valid_reg;
    reg token_first_reg, token_last_reg;
    reg [7:0] token_k_reg;
    reg signed [63:0] token_act_reg, token_wgt_reg;
    reg [31:0] source_window_reads_reg, window_reuse_reg, token_count_reg;

    /* Explicit registers are required here: a variable-indexed inferred
     * memory would turn this cache into distributed RAM in a full top. */
    (* ram_style = "registers" *) reg signed [63:0] act_row_mem [0:MAX_CIN-1];
    wire [7:0] act_select_idx = weight_resp_idx;
    reg signed [63:0] act_selected;
    integer ai;
    always @* begin
        act_selected = 64'sd0;
        /* Two-level static case select.  The default is the legal tail row. */
        case (act_select_idx[7:2])
            6'd0:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[0]; 2'd1: act_selected=act_row_mem[1];
                2'd2: act_selected=act_row_mem[2]; default: act_selected=act_row_mem[3]; endcase
            6'd1:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[4]; 2'd1: act_selected=act_row_mem[5];
                2'd2: act_selected=act_row_mem[6]; default: act_selected=act_row_mem[7]; endcase
            6'd2:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[8]; 2'd1: act_selected=act_row_mem[9];
                2'd2: act_selected=act_row_mem[10]; default: act_selected=act_row_mem[11]; endcase
            6'd3:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[12]; 2'd1: act_selected=act_row_mem[13];
                2'd2: act_selected=act_row_mem[14]; default: act_selected=act_row_mem[15]; endcase
            6'd4:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[16]; 2'd1: act_selected=act_row_mem[17];
                2'd2: act_selected=act_row_mem[18]; default: act_selected=act_row_mem[19]; endcase
            6'd5:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[20]; 2'd1: act_selected=act_row_mem[21];
                2'd2: act_selected=act_row_mem[22]; default: act_selected=act_row_mem[23]; endcase
            6'd6:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[24]; 2'd1: act_selected=act_row_mem[25];
                2'd2: act_selected=act_row_mem[26]; default: act_selected=act_row_mem[27]; endcase
            6'd7:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[28]; 2'd1: act_selected=act_row_mem[29];
                2'd2: act_selected=act_row_mem[30]; default: act_selected=act_row_mem[31]; endcase
            6'd8:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[32]; 2'd1: act_selected=act_row_mem[33];
                2'd2: act_selected=act_row_mem[34]; default: act_selected=act_row_mem[35]; endcase
            6'd9:  case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[36]; 2'd1: act_selected=act_row_mem[37];
                2'd2: act_selected=act_row_mem[38]; default: act_selected=act_row_mem[39]; endcase
            6'd10: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[40]; 2'd1: act_selected=act_row_mem[41];
                2'd2: act_selected=act_row_mem[42]; default: act_selected=act_row_mem[43]; endcase
            6'd11: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[44]; 2'd1: act_selected=act_row_mem[45];
                2'd2: act_selected=act_row_mem[46]; default: act_selected=act_row_mem[47]; endcase
            6'd12: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[48]; 2'd1: act_selected=act_row_mem[49];
                2'd2: act_selected=act_row_mem[50]; default: act_selected=act_row_mem[51]; endcase
            6'd13: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[52]; 2'd1: act_selected=act_row_mem[53];
                2'd2: act_selected=act_row_mem[54]; default: act_selected=act_row_mem[55]; endcase
            6'd14: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[56]; 2'd1: act_selected=act_row_mem[57];
                2'd2: act_selected=act_row_mem[58]; default: act_selected=act_row_mem[59]; endcase
            6'd15: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[60]; 2'd1: act_selected=act_row_mem[61];
                2'd2: act_selected=act_row_mem[62]; default: act_selected=act_row_mem[63]; endcase
            6'd16: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[64]; 2'd1: act_selected=act_row_mem[65];
                2'd2: act_selected=act_row_mem[66]; default: act_selected=act_row_mem[67]; endcase
            6'd17: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[68]; 2'd1: act_selected=act_row_mem[69];
                2'd2: act_selected=act_row_mem[70]; default: act_selected=act_row_mem[71]; endcase
            6'd18: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[72]; 2'd1: act_selected=act_row_mem[73];
                2'd2: act_selected=act_row_mem[74]; default: act_selected=act_row_mem[75]; endcase
            6'd19: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[76]; 2'd1: act_selected=act_row_mem[77];
                2'd2: act_selected=act_row_mem[78]; default: act_selected=act_row_mem[79]; endcase
            6'd20: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[80]; 2'd1: act_selected=act_row_mem[81];
                2'd2: act_selected=act_row_mem[82]; default: act_selected=act_row_mem[83]; endcase
            6'd21: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[84]; 2'd1: act_selected=act_row_mem[85];
                2'd2: act_selected=act_row_mem[86]; default: act_selected=act_row_mem[87]; endcase
            6'd22: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[88]; 2'd1: act_selected=act_row_mem[89];
                2'd2: act_selected=act_row_mem[90]; default: act_selected=act_row_mem[91]; endcase
            6'd23: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[92]; 2'd1: act_selected=act_row_mem[93];
                2'd2: act_selected=act_row_mem[94]; default: act_selected=act_row_mem[95]; endcase
            6'd24: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[96]; 2'd1: act_selected=act_row_mem[97];
                2'd2: act_selected=act_row_mem[98]; default: act_selected=act_row_mem[99]; endcase
            6'd25: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[100]; 2'd1: act_selected=act_row_mem[101];
                2'd2: act_selected=act_row_mem[102]; default: act_selected=act_row_mem[103]; endcase
            6'd26: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[104]; 2'd1: act_selected=act_row_mem[105];
                2'd2: act_selected=act_row_mem[106]; default: act_selected=act_row_mem[107]; endcase
            6'd27: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[108]; 2'd1: act_selected=act_row_mem[109];
                2'd2: act_selected=act_row_mem[110]; default: act_selected=act_row_mem[111]; endcase
            6'd28: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[112]; 2'd1: act_selected=act_row_mem[113];
                2'd2: act_selected=act_row_mem[114]; default: act_selected=act_row_mem[115]; endcase
            6'd29: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[116]; 2'd1: act_selected=act_row_mem[117];
                2'd2: act_selected=act_row_mem[118]; default: act_selected=act_row_mem[119]; endcase
            6'd30: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[120]; 2'd1: act_selected=act_row_mem[121];
                2'd2: act_selected=act_row_mem[122]; default: act_selected=act_row_mem[123]; endcase
            default: case (act_select_idx[1:0])
                2'd0: act_selected=act_row_mem[124]; 2'd1: act_selected=act_row_mem[125];
                2'd2: act_selected=act_row_mem[126]; default: act_selected=act_row_mem[127]; endcase
        endcase
    end

    wire source_issue = (state == S_GATHER) && (source_issue_idx < channels_reg);
    wire source_response_fire = source_rd_valid && (state == S_GATHER);
    assign source_rd_en = source_issue;
    assign source_rd_pixel_base = pixel_base_reg[5:0];
    assign source_rd_channel_idx = source_issue_idx;

    wire token_fire = token_valid_reg && token_ready;
    wire weight_issue = (state == S_FEED) &&
                        (weight_issue_idx < channels_reg) &&
                        (!token_valid_reg || token_ready);
    assign weight_rd_en = weight_issue;
    assign weight_rd_cout_base = cout_base_reg;
    assign weight_rd_channel_idx = weight_issue_idx;
    assign token_valid = token_valid_reg;
    assign token_first = token_first_reg;
    assign token_last = token_last_reg;
    assign token_k_idx = token_k_reg;
    assign token_act_vec = token_act_reg;
    assign token_wgt_vec = token_wgt_reg;
    assign token_pixel_base = pixel_base_reg;
    assign token_cout_base = cout_base_reg;
    assign token_pixel_mask = (pixel_base_reg + 8'd7 < output_pixels_reg) ? 8'hff :
                              ((8'h1 << (output_pixels_reg - pixel_base_reg)) - 1'b1);
    assign token_cout_mask = (cout_base_reg + 9'd8 <= out_channels_reg) ? 8'hff :
                             ((8'h1 << (out_channels_reg - cout_base_reg)) - 1'b1);
    wire result_fire = result_valid && result_ready;
    wire result_final = result_fire &&
                        (result_pixel_idx == ({3'd0,pixel_base_reg} + 11'd7)) &&
                        (result_channel_base == (cout_base_reg + 9'd4));
    assign block_pixel_base = pixel_base_reg;
    assign block_cout_base = cout_base_reg;
    assign busy = (state != S_IDLE);
    assign metric_source_window_reads = source_window_reads_reg;
    assign metric_window_reuse = window_reuse_reg;
    assign metric_token_count = token_count_reg;

    genvar ag;
    generate for (ag=0; ag<MAX_CIN; ag=ag+1) begin : gen_act_cache_write
        always @(posedge clk) begin
            if (rst_n && source_response_fire && (source_resp_idx == ag[7:0]))
                act_row_mem[ag] <= source_rd_data;
        end
    end endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; error <= 1'b0;
            channels_reg <= 0; out_channels_reg <= 0; output_pixels_reg <= 0;
            pixel_base_reg <= 0; cout_base_reg <= 0;
            source_issue_idx <= 0; source_resp_idx <= 0;
            weight_issue_idx <= 0; weight_resp_idx <= 0;
            token_valid_reg <= 0; token_first_reg <= 0; token_last_reg <= 0;
            token_k_reg <= 0; token_act_reg <= 0; token_wgt_reg <= 0;
            source_window_reads_reg <= 0; window_reuse_reg <= 0; token_count_reg <= 0;
        end else begin
            done <= 1'b0;
            if (state == S_IDLE && start) begin
                if ((channels == 0) || (channels > MAX_CIN) ||
                    (out_channels == 0) || (out_channels > MAX_COUT) ||
                    (output_pixels == 0) || (output_pixels > MAX_PIXELS)) begin
                    error <= 1'b1;
                    done <= 1'b1;
                end else begin
                    error <= 1'b0; channels_reg <= channels;
                    out_channels_reg <= out_channels; output_pixels_reg <= output_pixels;
                    pixel_base_reg <= 0; cout_base_reg <= 0;
                    source_issue_idx <= 0; source_resp_idx <= 0;
                    weight_issue_idx <= 0; weight_resp_idx <= 0;
                    token_valid_reg <= 0; state <= S_GATHER;
                end
            end
            if (state == S_GATHER) begin
                if (source_issue) source_issue_idx <= source_issue_idx + 1'b1;
                if (source_response_fire) begin
                    source_window_reads_reg <= source_window_reads_reg + 1'b1;
                    if (source_resp_idx + 1'b1 >= channels_reg) begin
                        state <= S_FEED; weight_issue_idx <= 0; weight_resp_idx <= 0;
                    end else source_resp_idx <= source_resp_idx + 1'b1;
                end
            end
            if (state == S_FEED) begin
                if (weight_issue) weight_issue_idx <= weight_issue_idx + 1'b1;
                if (weight_rd_valid) begin
                    token_valid_reg <= 1'b1;
                    token_first_reg <= (weight_resp_idx == 0);
                    token_last_reg <= (weight_resp_idx + 1'b1 >= channels_reg);
                    token_k_reg <= weight_resp_idx;
                    token_act_reg <= act_selected;
                    token_wgt_reg <= weight_rd_data;
                    weight_resp_idx <= weight_resp_idx + 1'b1;
                end else if (token_fire) begin
                    token_valid_reg <= 1'b0;
                end
                if (token_fire && token_last_reg) state <= S_DRAIN;
            end
            if (state == S_DRAIN && result_final) begin
                if (cout_base_reg + 9'd8 < out_channels_reg) begin
                    cout_base_reg <= cout_base_reg + 9'd8;
                    weight_issue_idx <= 0; weight_resp_idx <= 0;
                    token_valid_reg <= 0; state <= S_FEED;
                    window_reuse_reg <= window_reuse_reg + 1'b1;
                end else if (pixel_base_reg + 8'd8 < output_pixels_reg) begin
                    pixel_base_reg <= pixel_base_reg + 8'd8;
                    cout_base_reg <= 0; source_issue_idx <= 0; source_resp_idx <= 0;
                    weight_issue_idx <= 0; weight_resp_idx <= 0; token_valid_reg <= 0;
                    state <= S_GATHER;
                end else begin
                    state <= S_IDLE; done <= 1'b1; token_valid_reg <= 0;
                end
            end
            if (token_fire) token_count_reg <= token_count_reg + 1'b1;
        end
    end
endmodule
`default_nettype wire
