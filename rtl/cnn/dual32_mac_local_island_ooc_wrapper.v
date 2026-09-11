`timescale 1ns/1ps
`default_nettype none

/* OOC shell keeps every mode/word path observable during XC7Z020 P&R. */
module dual32_mac_local_island_ooc_wrapper (
    input wire clk, input wire rst_n,
    input wire [1:0] mode_i,
    input wire cfg_valid_i, output wire cfg_ready_o, input wire cfg_island_i,
    input wire [5:0] cfg_lane_i, input wire signed [31:0] cfg_bias_i,
    input wire signed [31:0] cfg_multiplier_i, input wire [5:0] cfg_shift_i,
    input wire valid_in, output wire ready_in, input wire first_k, input wire last_k,
    input wire [7:0] k_idx, input wire [7:0] block_tag_i,
    input wire [7:0] pixel_base_i, input wire [8:0] cout_base_i,
    input wire [7:0] pixel_mask_i, input wire [15:0] cout_mask_i,
    input wire signed [31:0] output_zero_point_i,
    input wire signed [31:0] activation_min_i,
    input wire signed [31:0] activation_max_i,
    input wire [31:0] src_word0_i, input wire [31:0] src_word1_i,
    input wire [31:0] param_word0_i, input wire [31:0] param_word1_i,
    input wire [31:0] param_word2_i, input wire [31:0] param_word3_i,
    output wire valid_out, input wire ready_out, output wire [31:0] out_word,
    output wire [3:0] out_word_mask, output wire [7:0] out_pixel_idx,
    output wire [8:0] out_channel_base, output wire [2:0] out_group_idx,
    output wire [7:0] out_block_tag, output wire [1:0] out_mode,
    output wire busy_o
);
    /* Register the external configuration transaction before it reaches the
     * island's distributed memories.  This is a one-entry ready/valid
     * boundary: an accepted record is held until the island accepts it, so
     * cfg_bias/mult/shift and their address remain cycle-aligned and the
     * wrapper does not expose a zero-input-delay hold path to bias_mem. */
    reg cfg_pending;
    reg cfg_island_reg;
    reg [5:0] cfg_lane_reg;
    reg signed [31:0] cfg_bias_reg, cfg_multiplier_reg;
    reg [5:0] cfg_shift_reg;
    wire cfg_ready_int;
    wire cfg_fire_int = cfg_pending && cfg_ready_int;
    assign cfg_ready_o = rst_n && !cfg_pending;

    /* The OOC shell intentionally models the real wrapper input boundary.
     * With the required zero input-delay constraint, a direct top-port to
     * same-edge register is an artificial hold path.  These kept, paired
     * inverters add only physical input buffering (no logical change) before
     * the transaction register; they are not timing exceptions and do not
     * alter ready/valid semantics. */
    (* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire cfg_valid_pad0, cfg_valid_pad1;
    (* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire cfg_island_pad0, cfg_island_pad1;
    (* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire [5:0] cfg_lane_pad0, cfg_lane_pad1;
    (* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire [31:0] cfg_bias_pad0, cfg_bias_pad1;
    (* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire [31:0] cfg_multiplier_pad0, cfg_multiplier_pad1;
    (* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) wire [5:0] cfg_shift_pad0, cfg_shift_pad1;
    LUT1 #(.INIT(2'b01)) u_cfg_valid_pad0 (.I0(cfg_valid_i), .O(cfg_valid_pad0));
    LUT1 #(.INIT(2'b01)) u_cfg_valid_pad1 (.I0(cfg_valid_pad0), .O(cfg_valid_pad1));
    LUT1 #(.INIT(2'b01)) u_cfg_island_pad0 (.I0(cfg_island_i), .O(cfg_island_pad0));
    LUT1 #(.INIT(2'b01)) u_cfg_island_pad1 (.I0(cfg_island_pad0), .O(cfg_island_pad1));
    genvar cfg_pad_i;
    generate
        for (cfg_pad_i = 0; cfg_pad_i < 6; cfg_pad_i = cfg_pad_i + 1) begin : gen_cfg_lane_shift_pad
            LUT1 #(.INIT(2'b01)) u_cfg_lane_pad0 (.I0(cfg_lane_i[cfg_pad_i]), .O(cfg_lane_pad0[cfg_pad_i]));
            LUT1 #(.INIT(2'b01)) u_cfg_lane_pad1 (.I0(cfg_lane_pad0[cfg_pad_i]), .O(cfg_lane_pad1[cfg_pad_i]));
            LUT1 #(.INIT(2'b01)) u_cfg_shift_pad0 (.I0(cfg_shift_i[cfg_pad_i]), .O(cfg_shift_pad0[cfg_pad_i]));
            LUT1 #(.INIT(2'b01)) u_cfg_shift_pad1 (.I0(cfg_shift_pad0[cfg_pad_i]), .O(cfg_shift_pad1[cfg_pad_i]));
        end
        for (cfg_pad_i = 0; cfg_pad_i < 32; cfg_pad_i = cfg_pad_i + 1) begin : gen_cfg_data_pad
            LUT1 #(.INIT(2'b01)) u_cfg_bias_pad0 (.I0(cfg_bias_i[cfg_pad_i]), .O(cfg_bias_pad0[cfg_pad_i]));
            LUT1 #(.INIT(2'b01)) u_cfg_bias_pad1 (.I0(cfg_bias_pad0[cfg_pad_i]), .O(cfg_bias_pad1[cfg_pad_i]));
            LUT1 #(.INIT(2'b01)) u_cfg_multiplier_pad0 (.I0(cfg_multiplier_i[cfg_pad_i]), .O(cfg_multiplier_pad0[cfg_pad_i]));
            LUT1 #(.INIT(2'b01)) u_cfg_multiplier_pad1 (.I0(cfg_multiplier_pad0[cfg_pad_i]), .O(cfg_multiplier_pad1[cfg_pad_i]));
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_pending <= 1'b0;
            cfg_island_reg <= 1'b0;
            cfg_lane_reg <= 6'd0;
            cfg_bias_reg <= 32'sd0;
            cfg_multiplier_reg <= 32'sd0;
            cfg_shift_reg <= 6'd0;
        end else begin
            if (cfg_valid_pad1 && cfg_ready_o) begin
                cfg_pending <= 1'b1;
                cfg_island_reg <= cfg_island_pad1;
                cfg_lane_reg <= cfg_lane_pad1;
                cfg_bias_reg <= cfg_bias_pad1;
                cfg_multiplier_reg <= cfg_multiplier_pad1;
                cfg_shift_reg <= cfg_shift_pad1;
            end else if (cfg_fire_int) begin
                cfg_pending <= 1'b0;
            end
        end
    end

    dual32_mac_local_island u_dut (
        .clk(clk), .rst_n(rst_n), .mode_i(mode_i),
        .cfg_valid_i(cfg_pending), .cfg_ready_o(cfg_ready_int),
        .cfg_island_i(cfg_island_reg), .cfg_lane_i(cfg_lane_reg),
        .cfg_bias_i(cfg_bias_reg), .cfg_multiplier_i(cfg_multiplier_reg),
        .cfg_shift_i(cfg_shift_reg), .valid_in(valid_in), .ready_in(ready_in),
        .first_k(first_k), .last_k(last_k), .k_idx(k_idx),
        .block_tag_i(block_tag_i), .pixel_base_i(pixel_base_i),
        .cout_base_i(cout_base_i), .pixel_mask_i(pixel_mask_i),
        .cout_mask_i(cout_mask_i), .output_zero_point_i(output_zero_point_i),
        .activation_min_i(activation_min_i), .activation_max_i(activation_max_i),
        .src_word0_i(src_word0_i), .src_word1_i(src_word1_i),
        .param_word0_i(param_word0_i), .param_word1_i(param_word1_i),
        .param_word2_i(param_word2_i), .param_word3_i(param_word3_i),
        .valid_out(valid_out), .ready_out(ready_out), .out_word(out_word),
        .out_word_mask(out_word_mask), .out_pixel_idx(out_pixel_idx),
        .out_channel_base(out_channel_base), .out_group_idx(out_group_idx),
        .out_block_tag(out_block_tag), .out_mode(out_mode), .busy_o(busy_o)
    );
endmodule
`default_nettype wire
