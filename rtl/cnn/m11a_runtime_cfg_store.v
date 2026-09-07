`timescale 1ns/1ps
`default_nettype none

/*
 * M1.1-A runtime configuration store.
 *
 * The external stream is the packed C0 ABI used by ds12_stream_reference.py:
 * four INT8 values per word for weights and one 32-bit value per word for
 * bias/multiplier/shift.  The store keeps the packed words in two independent
 * block-RAM-shaped banks, then performs a deterministic, one-word-at-a-time
 * unpack/transpose pass.  PW rows are written in the physical order consumed
 * by the shared PW64 core: {Cout-tile,K} -> eight INT8 weights.
 *
 * The preparation pass is deliberately fenced from execution.  No core can
 * observe a partially decoded descriptor and no runtime datapath needs a
 * divide/modulo address expression.  The active layer overwrites the small
 * decoded views only after a successful config commit.
 */
module m11a_runtime_cfg_store (
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
    output reg          loaded_ds1,
    output reg          loaded_ds2,
    output reg          error,

    input  wire         prepare_valid,
    output wire         prepare_ready,
    input  wire [1:0]   prepare_layer,
    input  wire [5:0]   prepare_cin,
    input  wire [6:0]   prepare_cout,
    output reg          prepare_busy,
    output reg          prepare_done,

    input  wire         pw_row_rd_en,
    input  wire [8:0]   pw_row_rd_addr,
    output reg          pw_row_valid,
    output reg [63:0]   pw_row_rd_data,

    output wire [2303:0] dw_weight_bus,
    output wire [2047:0] dw_bias_bus,
    output wire [2047:0] dw_multiplier_bus,
    output wire [1023:0] dw_shift_bus,
    output wire [2047:0] pw_bias_bus,
    output wire [2047:0] pw_multiplier_bus,
    output wire [383:0]  pw_shift_bus
);
    localparam integer DS1_WORDS = 308;
    localparam integer DS2_WORDS = 872;
    localparam integer DS1_DW_WEIGHT_WORDS = 36;
    localparam integer DS2_DW_WEIGHT_WORDS = 72;
    localparam integer DS1_DW_BIAS_BASE = 36;
    localparam integer DS2_DW_BIAS_BASE = 72;
    localparam integer DS1_DW_MUL_BASE = 52;
    localparam integer DS2_DW_MUL_BASE = 104;
    localparam integer DS1_DW_SHIFT_BASE = 68;
    localparam integer DS2_DW_SHIFT_BASE = 136;
    localparam integer DS1_PW_WEIGHT_BASE = 84;
    localparam integer DS2_PW_WEIGHT_BASE = 168;
    localparam integer DS1_PW_BIAS_BASE = 212;
    localparam integer DS2_PW_BIAS_BASE = 680;
    localparam integer DS1_PW_MUL_BASE = 244;
    localparam integer DS2_PW_MUL_BASE = 744;
    localparam integer DS1_PW_SHIFT_BASE = 276;
    localparam integer DS2_PW_SHIFT_BASE = 808;

    localparam [3:0] P_IDLE       = 4'd0;
    localparam [3:0] P_DW_WEIGHT  = 4'd1;
    localparam [3:0] P_DW_BIAS    = 4'd2;
    localparam [3:0] P_DW_MUL     = 4'd3;
    localparam [3:0] P_DW_SHIFT   = 4'd4;
    localparam [3:0] P_PW_BIAS    = 4'd5;
    localparam [3:0] P_PW_MUL     = 4'd6;
    localparam [3:0] P_PW_SHIFT   = 4'd7;
    localparam [3:0] P_PW_BYTES   = 4'd8;
    localparam [3:0] P_PW_ROW     = 4'd9;
    localparam [3:0] P_PW_WRITE   = 4'd10;
    localparam [3:0] P_DONE       = 4'd11;

    /* Packed external words.  One bank is selected by cfg_layer; the active
     * layer is never changed while prepare_busy is asserted. */
    (* ram_style = "block" *) reg [31:0] cfg_ds1_mem [0:DS1_WORDS-1];
    (* ram_style = "block" *) reg [31:0] cfg_ds2_mem [0:DS2_WORDS-1];

    /* The decoded views are bounded by DS2's 32/64 shape. */
    reg signed [7:0]  dw_weight [0:31][0:8];
    reg signed [31:0] dw_bias [0:31];
    reg signed [31:0] dw_multiplier [0:31];
    reg [5:0]         dw_shift [0:31];
    reg signed [31:0] pw_bias [0:63];
    reg signed [31:0] pw_multiplier [0:63];
    reg [5:0]         pw_shift [0:63];

    /* Linear PW source bytes are only a preparation-time staging store.  The
     * execution-facing memory is the 64-bit row store below. */
    (* ram_style = "block" *) reg [7:0]  pw_byte_mem [0:2047];
    (* ram_style = "block" *) reg [63:0] pw_row_mem [0:255];

    reg [9:0] cfg_count_ds1, cfg_count_ds2;
    reg [3:0] prep_state;
    reg [1:0] prep_layer;
    reg [5:0] prep_cin;
    reg [6:0] prep_cout;
    reg [9:0] prep_word;
    reg [1:0] prep_byte_lane;
    reg [5:0] prep_dw_ch;
    reg [3:0] prep_dw_tap;
    reg [6:0] prep_pw_ch;
    reg [11:0] prep_pw_byte;
    reg [8:0] prep_pw_row;
    reg [6:0] prep_pw_tile;
    reg [5:0] prep_pw_k;
    reg [2:0] prep_pw_lane;
    reg [11:0] prep_pw_src_addr;
    reg [11:0] prep_pw_tile_base;
    reg [63:0] prep_pw_row_buf;

    wire cfg_layer_ok = (cfg_layer == 2'd1) || (cfg_layer == 2'd2);
    wire [9:0] cfg_limit = (cfg_layer == 2'd1) ? 10'd308 : 10'd872;
    assign cfg_ready = rst_n && !prepare_busy && cfg_layer_ok &&
                       (cfg_index < cfg_limit);
    assign cfg_commit_ready = rst_n && !prepare_busy;
    assign prepare_ready = rst_n && !prepare_busy &&
                           ((prepare_layer == 2'd1 && loaded_ds1) ||
                            (prepare_layer == 2'd2 && loaded_ds2));

    wire cfg_fire = cfg_valid && cfg_ready;
    wire commit_fire = cfg_commit_valid && cfg_commit_ready;
    wire prepare_fire = prepare_valid && prepare_ready;

    /* Unpack source word view.  This is a fenced configuration pass, not a
     * runtime address generator; all counters advance without / or %. */
    reg [31:0] prep_cfg_word;
    always @* begin
        prep_cfg_word = 32'd0;
        if (prep_layer == 2'd1)
            prep_cfg_word = cfg_ds1_mem[prep_word[8:0]];
        else if (prep_layer == 2'd2)
            prep_cfg_word = cfg_ds2_mem[prep_word];
    end

    genvar gb;
    generate
        for (gb = 0; gb < 32; gb = gb + 1) begin : GEN_DW_BUS
            for (genvar gt = 0; gt < 9; gt = gt + 1) begin : GEN_DW_TAP_BUS
                assign dw_weight_bus[((gb*9+gt)*8) +: 8] = dw_weight[gb][gt];
            end
            assign dw_bias_bus[(gb*32) +: 32] = dw_bias[gb];
            assign dw_multiplier_bus[(gb*32) +: 32] = dw_multiplier[gb];
            assign dw_shift_bus[(gb*32) +: 32] = {26'd0, dw_shift[gb]};
            assign pw_bias_bus[(gb*32) +: 32] = pw_bias[gb];
            assign pw_multiplier_bus[(gb*32) +: 32] = pw_multiplier[gb];
            assign pw_shift_bus[(gb*6) +: 6] = pw_shift[gb];
        end
        for (genvar gp = 32; gp < 64; gp = gp + 1) begin : GEN_PW_BUS
            assign dw_bias_bus[(gp*32) +: 32] = 32'd0;
            assign dw_multiplier_bus[(gp*32) +: 32] = 32'd0;
            assign pw_bias_bus[(gp*32) +: 32] = pw_bias[gp];
            assign pw_multiplier_bus[(gp*32) +: 32] = pw_multiplier[gp];
            assign pw_shift_bus[(gp*6) +: 6] = pw_shift[gp];
        end
    endgenerate

    integer i, j;
    always @(posedge clk) begin
        if (!rst_n) begin
            loaded_ds1 <= 1'b0;
            loaded_ds2 <= 1'b0;
            error <= 1'b0;
            cfg_count_ds1 <= 10'd0;
            cfg_count_ds2 <= 10'd0;
            prep_state <= P_IDLE;
            prep_layer <= 2'd0;
            prep_cin <= 6'd0;
            prep_cout <= 7'd0;
            prep_word <= 10'd0;
            prep_byte_lane <= 2'd0;
            prep_dw_ch <= 6'd0;
            prep_dw_tap <= 4'd0;
            prep_pw_ch <= 7'd0;
            prep_pw_byte <= 12'd0;
            prep_pw_row <= 9'd0;
            prep_pw_tile <= 7'd0;
            prep_pw_k <= 6'd0;
            prep_pw_lane <= 3'd0;
            prep_pw_src_addr <= 12'd0;
            prep_pw_tile_base <= 12'd0;
            prep_pw_row_buf <= 64'd0;
            prepare_busy <= 1'b0;
            prepare_done <= 1'b0;
            pw_row_valid <= 1'b0;
            pw_row_rd_data <= 64'd0;
            for (i = 0; i < 32; i = i + 1) begin
                dw_bias[i] <= 32'sd0;
                dw_multiplier[i] <= 32'sd0;
                dw_shift[i] <= 6'd0;
                pw_bias[i] <= 32'sd0;
                pw_multiplier[i] <= 32'sd0;
                pw_shift[i] <= 6'd0;
                for (j = 0; j < 9; j = j + 1)
                    dw_weight[i][j] <= 8'sd0;
            end
            for (i = 32; i < 64; i = i + 1) begin
                pw_bias[i] <= 32'sd0;
                pw_multiplier[i] <= 32'sd0;
                pw_shift[i] <= 6'd0;
            end
        end else begin
            prepare_done <= 1'b0;
            pw_row_valid <= 1'b0;

            if (cfg_fire) begin
                if (cfg_layer == 2'd1) begin
                    cfg_ds1_mem[cfg_index[8:0]] <= cfg_data;
                    if (cfg_index >= cfg_count_ds1)
                        cfg_count_ds1 <= cfg_index + 1'b1;
                end else begin
                    cfg_ds2_mem[cfg_index] <= cfg_data;
                    if (cfg_index >= cfg_count_ds2)
                        cfg_count_ds2 <= cfg_index + 1'b1;
                end
            end
            if (commit_fire) begin
                if (cfg_commit_layer == 2'd1 && cfg_count_ds1 == DS1_WORDS)
                    loaded_ds1 <= 1'b1;
                else if (cfg_commit_layer == 2'd2 && cfg_count_ds2 == DS2_WORDS)
                    loaded_ds2 <= 1'b1;
                else
                    error <= error | 1'b1;
            end

            if (prepare_fire) begin
                prepare_busy <= 1'b1;
                prep_state <= P_DW_WEIGHT;
                prep_layer <= prepare_layer;
                prep_cin <= prepare_cin;
                prep_cout <= prepare_cout;
                prep_word <= 10'd0;
                prep_byte_lane <= 2'd0;
                prep_dw_ch <= 6'd0;
                prep_dw_tap <= 4'd0;
                prep_pw_ch <= 7'd0;
                prep_pw_byte <= 12'd0;
                prep_pw_row <= 9'd0;
                prep_pw_tile <= 7'd0;
                prep_pw_k <= 6'd0;
                prep_pw_lane <= 3'd0;
                prep_pw_src_addr <= 12'd0;
                prep_pw_tile_base <= 12'd0;
                prep_pw_row_buf <= 64'd0;
            end

            if (pw_row_rd_en) begin
                pw_row_rd_data <= pw_row_mem[pw_row_rd_addr[7:0]];
                pw_row_valid <= 1'b1;
            end

            if (prepare_busy) begin
                case (prep_state)
                    P_DW_WEIGHT: begin
                        if (prep_layer == 2'd1)
                            dw_weight[prep_dw_ch[4:0]][prep_dw_tap[3:0]] <=
                                $signed(prep_cfg_word[prep_byte_lane*8 +: 8]);
                        else
                            dw_weight[prep_dw_ch[4:0]][prep_dw_tap[3:0]] <=
                                $signed(prep_cfg_word[prep_byte_lane*8 +: 8]);
                        if (prep_byte_lane == 2'd3) begin
                            prep_byte_lane <= 2'd0;
                            prep_word <= prep_word + 1'b1;
                        end else begin
                            prep_byte_lane <= prep_byte_lane + 1'b1;
                        end
                        if (prep_dw_tap == 4'd8) begin
                            prep_dw_tap <= 4'd0;
                            if (prep_dw_ch == prep_cin - 1'b1) begin
                                prep_dw_ch <= 6'd0;
                                prep_word <= (prep_layer == 2'd1) ? DS1_DW_BIAS_BASE : DS2_DW_BIAS_BASE;
                                prep_state <= P_DW_BIAS;
                            end else begin
                                prep_dw_ch <= prep_dw_ch + 1'b1;
                            end
                        end else begin
                            prep_dw_tap <= prep_dw_tap + 1'b1;
                        end
                    end
                    P_DW_BIAS: begin
                        dw_bias[prep_dw_ch[4:0]] <= $signed(prep_cfg_word);
                        if (prep_dw_ch == prep_cin - 1'b1) begin
                            prep_dw_ch <= 6'd0;
                            prep_word <= (prep_layer == 2'd1) ? DS1_DW_MUL_BASE : DS2_DW_MUL_BASE;
                            prep_state <= P_DW_MUL;
                        end else begin
                            prep_dw_ch <= prep_dw_ch + 1'b1;
                            prep_word <= prep_word + 1'b1;
                        end
                    end
                    P_DW_MUL: begin
                        dw_multiplier[prep_dw_ch[4:0]] <= $signed(prep_cfg_word);
                        if (prep_dw_ch == prep_cin - 1'b1) begin
                            prep_dw_ch <= 6'd0;
                            prep_word <= (prep_layer == 2'd1) ? DS1_DW_SHIFT_BASE : DS2_DW_SHIFT_BASE;
                            prep_state <= P_DW_SHIFT;
                        end else begin
                            prep_dw_ch <= prep_dw_ch + 1'b1;
                            prep_word <= prep_word + 1'b1;
                        end
                    end
                    P_DW_SHIFT: begin
                        dw_shift[prep_dw_ch[4:0]] <= prep_cfg_word[5:0];
                        if (prep_dw_ch == prep_cin - 1'b1) begin
                            prep_word <= (prep_layer == 2'd1) ? DS1_PW_BIAS_BASE : DS2_PW_BIAS_BASE;
                            prep_pw_ch <= 7'd0;
                            prep_state <= P_PW_BIAS;
                        end else begin
                            prep_dw_ch <= prep_dw_ch + 1'b1;
                            prep_word <= prep_word + 1'b1;
                        end
                    end
                    P_PW_BIAS: begin
                        pw_bias[prep_pw_ch] <= $signed(prep_cfg_word);
                        if (prep_pw_ch == prep_cout - 1'b1) begin
                            prep_pw_ch <= 7'd0;
                            prep_word <= (prep_layer == 2'd1) ? DS1_PW_MUL_BASE : DS2_PW_MUL_BASE;
                            prep_state <= P_PW_MUL;
                        end else begin
                            prep_pw_ch <= prep_pw_ch + 1'b1;
                            prep_word <= prep_word + 1'b1;
                        end
                    end
                    P_PW_MUL: begin
                        pw_multiplier[prep_pw_ch] <= $signed(prep_cfg_word);
                        if (prep_pw_ch == prep_cout - 1'b1) begin
                            prep_pw_ch <= 7'd0;
                            prep_word <= (prep_layer == 2'd1) ? DS1_PW_SHIFT_BASE : DS2_PW_SHIFT_BASE;
                            prep_state <= P_PW_SHIFT;
                        end else begin
                            prep_pw_ch <= prep_pw_ch + 1'b1;
                            prep_word <= prep_word + 1'b1;
                        end
                    end
                    P_PW_SHIFT: begin
                        pw_shift[prep_pw_ch] <= prep_cfg_word[5:0];
                        if (prep_pw_ch == prep_cout - 1'b1) begin
                            prep_word <= (prep_layer == 2'd1) ? DS1_PW_WEIGHT_BASE : DS2_PW_WEIGHT_BASE;
                            prep_byte_lane <= 2'd0;
                            prep_pw_byte <= 12'd0;
                            prep_state <= P_PW_BYTES;
                        end else begin
                            prep_pw_ch <= prep_pw_ch + 1'b1;
                            prep_word <= prep_word + 1'b1;
                        end
                    end
                    P_PW_BYTES: begin
                        pw_byte_mem[prep_pw_byte[10:0]] <= prep_cfg_word[prep_byte_lane*8 +: 8];
                        if (prep_byte_lane == 2'd3) begin
                            prep_byte_lane <= 2'd0;
                            prep_word <= prep_word + 1'b1;
                        end else begin
                            prep_byte_lane <= prep_byte_lane + 1'b1;
                        end
                        if (prep_pw_byte == (prep_cin * prep_cout) - 1'b1) begin
                            prep_pw_row <= 9'd0;
                            prep_pw_tile <= 7'd0;
                            prep_pw_k <= 6'd0;
                            prep_pw_lane <= 3'd0;
                            prep_pw_tile_base <= 12'd0;
                            prep_pw_src_addr <= 12'd0;
                            prep_state <= P_PW_ROW;
                        end else begin
                            prep_pw_byte <= prep_pw_byte + 1'b1;
                        end
                    end
                    P_PW_ROW: begin
                        prep_pw_row_buf[prep_pw_lane*8 +: 8] <= pw_byte_mem[prep_pw_src_addr[10:0]];
                        if (prep_pw_lane == 3'd7) begin
                            prep_state <= P_PW_WRITE;
                        end else begin
                            prep_pw_lane <= prep_pw_lane + 1'b1;
                            prep_pw_src_addr <= prep_pw_src_addr + prep_cin;
                        end
                    end
                    P_PW_WRITE: begin
                        /* P_PW_ROW captures all eight lanes, including lane 7,
                         * before advancing to this state.  Reconstructing the
                         * word with a direct lane-7 read and [63:8] used to
                         * drop lane 0 and duplicate lane 7. */
                        pw_row_mem[prep_pw_row[7:0]] <= prep_pw_row_buf;
                        if (prep_pw_row == ((prep_cout >> 3) * prep_cin) - 1'b1) begin
                            prep_state <= P_DONE;
                        end else begin
                            prep_pw_row <= prep_pw_row + 1'b1;
                            prep_pw_lane <= 3'd0;
                            if (prep_pw_k == prep_cin - 1'b1) begin
                                prep_pw_k <= 6'd0;
                                prep_pw_tile <= prep_pw_tile + 1'b1;
                                prep_pw_tile_base <= prep_pw_tile_base + (prep_cin << 3);
                                prep_pw_src_addr <= prep_pw_tile_base + (prep_cin << 3);
                            end else begin
                                prep_pw_k <= prep_pw_k + 1'b1;
                                prep_pw_src_addr <= prep_pw_tile_base + prep_pw_k + 1'b1;
                            end
                            prep_state <= P_PW_ROW;
                        end
                    end
                    P_DONE: begin
                        prepare_busy <= 1'b0;
                        prepare_done <= 1'b1;
                        prep_state <= P_IDLE;
                    end
                    default: begin
                        prepare_busy <= 1'b0;
                        error <= error | 1'b1;
                        prep_state <= P_IDLE;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
