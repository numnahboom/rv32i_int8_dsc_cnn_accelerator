`timescale 1ns/1ps
`default_nettype none

/* Direct DW producer: the active shell bank is read in tap order. */
module ds_word_window_dw_producer_island #(
    parameter integer MAX_IN_H = 17, parameter integer MAX_IN_W = 17,
    parameter integer MAX_CHANNEL_GROUPS = 3, parameter integer LAYOUT_GROUPS = 1,
    parameter integer ADDR_WIDTH = 24, parameter integer WORD_COUNT_WIDTH = 16,
    parameter integer VECTOR_ADDR_WIDTH = ((MAX_IN_H*MAX_IN_W*MAX_CHANNEL_GROUPS) > 1) ? $clog2(MAX_IN_H*MAX_IN_W*MAX_CHANNEL_GROUPS) : 1,
    parameter integer EPOCH_WIDTH = 4, parameter integer TAG_WIDTH = 16,
    parameter integer FIFO_DEPTH = 8, parameter integer USE_QUADLOCAL_CORE = 0,
    parameter integer OUTPUT_HEIGHT = 8, parameter integer OUTPUT_WIDTH = 8
) (
    input wire clk, input wire rst_n,
    input wire fill_start_valid, output wire fill_start_ready,
    input wire fill_start_bank, input wire [EPOCH_WIDTH-1:0] fill_start_epoch,
    input wire [ADDR_WIDTH-1:0] fill_start_base_addr,
    input wire [WORD_COUNT_WIDTH-1:0] fill_start_word_count,
    output wire fill_done_valid, input wire fill_done_ready,
    output wire fill_done_bank, output wire [EPOCH_WIDTH-1:0] fill_done_epoch,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    input wire mem_resp_valid, input wire [31:0] mem_resp_data,
    output wire mem_resp_ready,
    input wire cfg_valid, output wire cfg_ready, input wire [3:0] cfg_tap_idx,
    input wire signed [127:0] cfg_weight_vec,
    input wire signed [511:0] cfg_bias_vec,
    input wire signed [511:0] cfg_multiplier_vec,
    input wire [95:0] cfg_shift_vec,
    input wire compute_start_valid, output wire compute_start_ready,
    input wire compute_bank, input wire [EPOCH_WIDTH-1:0] compute_epoch,
    input wire [15:0] compute_lane_mask, input wire [1:0] compute_stride,
    input wire [7:0] compute_footprint_height, input wire [7:0] compute_footprint_width,
    input wire [7:0] compute_pitch, output reg compute_done_valid,
    input wire compute_done_ready, output reg compute_done_bank,
    output reg [EPOCH_WIDTH-1:0] compute_done_epoch, output wire compute_busy,
    output wire valid_out, input wire ready_out, output wire [7:0] out_pixel_idx,
    output wire [15:0] out_lane_mask, output wire signed [511:0] out_raw_vec,
    output wire signed [511:0] out_bias_vec,
    output wire signed [511:0] out_multiplier_vec, output wire [95:0] out_shift_vec,
    output wire [1:0] bank0_state, output wire [1:0] bank1_state,
    output wire fill_busy, output wire read_busy,
    output wire [31:0] fill_word_count_seen, output wire [31:0] read_vector_count,
    output reg [31:0] token_count, output reg [31:0] overlap_cycles,
    output wire [31:0] stale_command_count
);
    localparam integer OUTPUT_PIXEL_COUNT = OUTPUT_HEIGHT * OUTPUT_WIDTH;
    localparam integer OUTPUT_LAST_PIXEL = OUTPUT_PIXEL_COUNT - 1;
    localparam integer TOTAL_TAPS = OUTPUT_PIXEL_COUNT * 9;
    localparam integer READ_COUNT_WIDTH = ((MAX_IN_H*MAX_IN_W) > 1) ? $clog2(MAX_IN_H*MAX_IN_W+1) : 1;
    localparam integer QDEPTH = 4;
    localparam [2:0] ST_IDLE=0, ST_ACQUIRE=1, ST_DIRECT_EMIT=2,
                     ST_DRAIN=3, ST_RELEASE=4, ST_DONE=5;
    reg [2:0] state;
    reg compute_bank_reg;
    reg [EPOCH_WIDTH-1:0] compute_epoch_reg;
    reg [15:0] lane_mask_reg;
    reg [1:0] stride_reg;
    reg [7:0] footprint_h_reg, footprint_w_reg, pitch_reg;
    reg read_done_seen, final_output_seen;
    reg [2:0] final_output_wait;

    reg shell_read_start_valid, shell_rd_ready, shell_release_valid;
    wire shell_read_start_ready, shell_read_done_valid, shell_rd_valid;
    wire [VECTOR_ADDR_WIDTH-1:0] shell_rd_vector_addr;
    wire [15:0] shell_rd_lane_mask;
    wire [TAG_WIDTH-1:0] shell_rd_tag;
    wire [EPOCH_WIDTH-1:0] shell_rd_epoch;
    wire [127:0] shell_rd_data_vector;
    wire shell_release_ready, shell_release_resp_valid, shell_release_resp_ok;
    wire shell_direct_req_ready;
    reg shell_direct_req_valid, shell_direct_req_last;
    reg [VECTOR_ADDR_WIDTH-1:0] shell_direct_req_addr;
    reg [15:0] shell_direct_req_lane_mask;
    reg [TAG_WIDTH-1:0] shell_direct_req_tag;
    reg [EPOCH_WIDTH-1:0] shell_direct_req_epoch;

    reg [7:0] meta_pixel [0:QDEPTH-1];
    reg [3:0] meta_tap [0:QDEPTH-1];
    reg [1:0] meta_wr_ptr, meta_rd_ptr;
    reg [2:0] meta_count;
    reg signed [127:0] resp_data [0:QDEPTH-1];
    reg [7:0] resp_pixel [0:QDEPTH-1];
    reg [3:0] resp_tap [0:QDEPTH-1];
    reg [EPOCH_WIDTH-1:0] resp_epoch [0:QDEPTH-1];
    reg [1:0] resp_wr_ptr, resp_rd_ptr;
    reg [2:0] resp_count;
    reg [READ_COUNT_WIDTH-1:0] issue_addr;
    reg [7:0] issue_pixel;
    reg [3:0] issue_tap;
    reg [10:0] issue_count;
    reg token_valid, token_first, token_last;
    reg [7:0] token_pixel; reg [3:0] token_tap; reg [15:0] token_lane_mask;
    reg signed [127:0] token_act, token_weight;
    reg signed [127:0] sched_weight_mem [0:8];
    wire core_ready_in;
    wire core_input_fire = token_valid && core_ready_in;
    wire shell_resp_fire = shell_rd_valid && shell_rd_ready;
    wire meta_push = shell_direct_req_valid && shell_direct_req_ready;
    wire meta_pop = shell_resp_fire;
    wire resp_pop = (!token_valid && resp_count != 0) || (core_input_fire && resp_count != 0);
    wire resp_bypass = shell_resp_fire && (resp_count == 0) && (!token_valid || core_input_fire);
    wire resp_push = shell_resp_fire && !resp_bypass;

    wire shell_read_bank_sel = ((state==ST_IDLE) && compute_start_valid) ? compute_bank : compute_bank_reg;
    wire [EPOCH_WIDTH-1:0] shell_read_epoch_sel = ((state==ST_IDLE) && compute_start_valid) ? compute_epoch : compute_epoch_reg;
    ds_word_window_pingpong_shell #(
        .MAX_IN_H(MAX_IN_H), .MAX_IN_W(MAX_IN_W), .MAX_CHANNEL_GROUPS(MAX_CHANNEL_GROUPS),
        .LAYOUT_GROUPS(LAYOUT_GROUPS), .ADDR_WIDTH(ADDR_WIDTH), .WORD_COUNT_WIDTH(WORD_COUNT_WIDTH),
        .VECTOR_ADDR_WIDTH(VECTOR_ADDR_WIDTH), .EPOCH_WIDTH(EPOCH_WIDTH), .TAG_WIDTH(TAG_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH), .DIRECT_READ_ENABLE(1)
    ) u_window_shell (
        .clk(clk), .rst_n(rst_n), .fill_start_valid(fill_start_valid), .fill_start_ready(fill_start_ready),
        .fill_start_bank(fill_start_bank), .fill_start_epoch(fill_start_epoch), .fill_start_base_addr(fill_start_base_addr),
        .fill_start_word_count(fill_start_word_count), .fill_done_valid(fill_done_valid), .fill_done_ready(fill_done_ready),
        .fill_done_bank(fill_done_bank), .fill_done_epoch(fill_done_epoch), .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready), .mem_req_addr(mem_req_addr), .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data), .mem_resp_ready(mem_resp_ready),
        .read_start_valid(shell_read_start_valid), .read_start_ready(shell_read_start_ready), .read_start_bank(shell_read_bank_sel),
        .read_start_epoch(shell_read_epoch_sel), .read_height(footprint_h_reg), .read_width(footprint_w_reg), .read_stride(1),
        .read_pitch(pitch_reg), .read_base_vector({VECTOR_ADDR_WIDTH{1'b0}}), .read_group(0), .read_lane_mask(lane_mask_reg),
        .direct_req_valid(shell_direct_req_valid), .direct_req_ready(shell_direct_req_ready), .direct_req_addr(shell_direct_req_addr),
        .direct_req_lane_mask(shell_direct_req_lane_mask), .direct_req_tag(shell_direct_req_tag), .direct_req_epoch(shell_direct_req_epoch),
        .direct_req_last(shell_direct_req_last), .read_done_valid(shell_read_done_valid), .read_done_ready(1), .read_done_bank(), .read_done_epoch(),
        .rd_valid(shell_rd_valid), .rd_ready(shell_rd_ready), .rd_vector_addr(shell_rd_vector_addr), .rd_lane_mask(shell_rd_lane_mask),
        .rd_tag(shell_rd_tag), .rd_epoch(shell_rd_epoch), .rd_data_vector(shell_rd_data_vector), .release_valid(shell_release_valid),
        .release_ready(shell_release_ready), .release_bank(compute_bank_reg), .release_epoch(compute_epoch_reg),
        .release_resp_valid(shell_release_resp_valid), .release_resp_ready(1), .release_resp_ok(shell_release_resp_ok),
        .bank0_state(bank0_state), .bank1_state(bank1_state), .fill_busy(fill_busy), .read_busy(read_busy),
        .fill_word_count_seen(fill_word_count_seen), .read_vector_count(read_vector_count), .overlap_cycles(), .stale_command_count(stale_command_count)
    );
    assign compute_start_ready = rst_n && state==ST_IDLE && !compute_done_valid && shell_read_start_ready;
    assign compute_busy = rst_n && state!=ST_IDLE;

    wire [READ_COUNT_WIDTH-1:0] issue_next_addr =
        (issue_tap < 2) ? issue_addr + 1'b1 :
        ((issue_tap==2)||(issue_tap==5)) ? issue_addr + footprint_w_reg - 2 :
        (issue_tap==8) ? ((issue_pixel[2:0]!=7) ? issue_addr + stride_reg - (footprint_w_reg<<1) - 2 :
                          (stride_reg==1) ? issue_addr - footprint_w_reg - 9 : issue_addr - 16) : issue_addr + 1'b1;
    wire [7:0] issue_next_pixel = (issue_tap==8) ? issue_pixel+1'b1 : issue_pixel;
    wire [3:0] issue_next_tap = (issue_tap==8) ? 0 : issue_tap+1'b1;

    always @* begin
        shell_read_start_valid = (state == ST_ACQUIRE);
        shell_release_valid = (state == ST_RELEASE);
        shell_rd_ready = (meta_count != 0) && ((resp_count < QDEPTH) || resp_pop);
        shell_direct_req_valid = (state == ST_DIRECT_EMIT) && (issue_count < TOTAL_TAPS) &&
                                 ((meta_count < QDEPTH) || shell_resp_fire);
        shell_direct_req_addr = issue_addr;
        shell_direct_req_lane_mask = lane_mask_reg;
        shell_direct_req_tag = issue_count;
        shell_direct_req_epoch = compute_epoch_reg;
        shell_direct_req_last = (issue_count == TOTAL_TAPS-1);
    end

    generate
    if (USE_QUADLOCAL_CORE == 0) begin : gen_legacy_dw
        dw_direct_3x3_dsp_prefetched u_dw (
            .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_tap_idx(cfg_tap_idx),
            .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
            .valid_in(token_valid), .ready_in(core_ready_in), .first_tap(token_first), .last_tap(token_last), .tap_idx(token_tap), .pixel_idx(token_pixel),
            .lane_mask(token_lane_mask), .act_vec(token_act), .valid_out(valid_out), .weight_vec(token_weight), .ready_out(ready_out),
            .out_pixel_idx(out_pixel_idx), .out_lane_mask(out_lane_mask), .out_raw_vec(out_raw_vec), .out_bias_vec(out_bias_vec),
            .out_multiplier_vec(out_multiplier_vec), .out_shift_vec(out_shift_vec));
    end else begin : gen_quadlocal_dw
        dw_direct_3x3_dsp_quadlocal u_dw (
            .clk(clk), .rst_n(rst_n), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_tap_idx(cfg_tap_idx),
            .cfg_weight_vec(cfg_weight_vec), .cfg_bias_vec(cfg_bias_vec), .cfg_multiplier_vec(cfg_multiplier_vec), .cfg_shift_vec(cfg_shift_vec),
            .valid_in(token_valid), .ready_in(core_ready_in), .first_tap(token_first), .last_tap(token_last), .tap_idx(token_tap), .pixel_idx(token_pixel),
            .lane_mask(token_lane_mask), .act_vec(token_act), .valid_out(valid_out), .weight_vec(token_weight), .ready_out(ready_out),
            .out_pixel_idx(out_pixel_idx), .out_lane_mask(out_lane_mask), .out_raw_vec(out_raw_vec), .out_bias_vec(out_bias_vec),
            .out_multiplier_vec(out_multiplier_vec), .out_shift_vec(out_shift_vec));
    end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            state<=ST_IDLE; compute_bank_reg<=0; compute_epoch_reg<=0; lane_mask_reg<=0; stride_reg<=1;
            footprint_h_reg<=10; footprint_w_reg<=10; pitch_reg<=10; read_done_seen<=0; final_output_seen<=0; final_output_wait<=0;
            compute_done_valid<=0; compute_done_bank<=0; compute_done_epoch<=0; meta_wr_ptr<=0; meta_rd_ptr<=0; meta_count<=0;
            resp_wr_ptr<=0; resp_rd_ptr<=0; resp_count<=0; issue_addr<=0; issue_pixel<=0; issue_tap<=0; issue_count<=0;
            token_valid<=0; token_first<=0; token_last<=0; token_pixel<=0; token_tap<=0; token_lane_mask<=0; token_act<=0; token_weight<=0;
            token_count<=0; overlap_cycles<=0;
        end else begin
            if (compute_done_valid && compute_done_ready) compute_done_valid<=0;
            if (shell_read_done_valid) read_done_seen<=1;
            if (cfg_valid && cfg_ready && cfg_tap_idx<9) sched_weight_mem[cfg_tap_idx]<=cfg_weight_vec;
            if (compute_start_valid && compute_start_ready) begin
                compute_bank_reg<=compute_bank; compute_epoch_reg<=compute_epoch; lane_mask_reg<=compute_lane_mask;
                stride_reg<=(compute_stride==0)?1:compute_stride; footprint_h_reg<=compute_footprint_height; footprint_w_reg<=compute_footprint_width; pitch_reg<=compute_pitch;
                read_done_seen<=0; final_output_seen<=0; final_output_wait<=0; meta_wr_ptr<=0; meta_rd_ptr<=0; meta_count<=0; resp_wr_ptr<=0; resp_rd_ptr<=0; resp_count<=0;
                issue_addr<=0; issue_pixel<=0; issue_tap<=0; issue_count<=0; token_valid<=0; token_count<=0; state<=ST_ACQUIRE;
            end
            if (state==ST_ACQUIRE && shell_read_start_ready) state<=ST_DIRECT_EMIT;

            if (meta_push) begin meta_pixel[meta_wr_ptr]<=issue_pixel; meta_tap[meta_wr_ptr]<=issue_tap; meta_wr_ptr<=meta_wr_ptr+1'b1; end
            if (meta_pop) meta_rd_ptr<=meta_rd_ptr+1'b1;
            case ({meta_push,meta_pop}) 2'b10: meta_count<=meta_count+1'b1; 2'b01: meta_count<=meta_count-1'b1; default:; endcase
            if (resp_push) begin
                resp_data[resp_wr_ptr]<=shell_rd_data_vector; resp_pixel[resp_wr_ptr]<=meta_pixel[meta_rd_ptr]; resp_tap[resp_wr_ptr]<=meta_tap[meta_rd_ptr]; resp_epoch[resp_wr_ptr]<=shell_rd_epoch; resp_wr_ptr<=resp_wr_ptr+1'b1;
            end
            if (resp_pop) resp_rd_ptr<=resp_rd_ptr+1'b1;
            case ({resp_push,resp_pop}) 2'b10: resp_count<=resp_count+1'b1; 2'b01: resp_count<=resp_count-1'b1; default:; endcase
            if (meta_push) begin issue_addr<=issue_next_addr; issue_pixel<=issue_next_pixel; issue_tap<=issue_next_tap; issue_count<=issue_count+1'b1; end

            if (core_input_fire) begin
                token_count<=token_count+1'b1;
                if (resp_count!=0) begin token_valid<=1; token_first<=resp_tap[resp_rd_ptr]==0; token_last<=resp_tap[resp_rd_ptr]==8; token_pixel<=resp_pixel[resp_rd_ptr]; token_tap<=resp_tap[resp_rd_ptr]; token_lane_mask<=lane_mask_reg; token_act<=resp_data[resp_rd_ptr]; token_weight<=sched_weight_mem[resp_tap[resp_rd_ptr]]; end
                else if (resp_bypass) begin token_valid<=1; token_first<=meta_tap[meta_rd_ptr]==0; token_last<=meta_tap[meta_rd_ptr]==8; token_pixel<=meta_pixel[meta_rd_ptr]; token_tap<=meta_tap[meta_rd_ptr]; token_lane_mask<=lane_mask_reg; token_act<=shell_rd_data_vector; token_weight<=sched_weight_mem[meta_tap[meta_rd_ptr]]; end
                else token_valid<=0;
            end else if (!token_valid && resp_count!=0) begin
                token_valid<=1; token_first<=resp_tap[resp_rd_ptr]==0; token_last<=resp_tap[resp_rd_ptr]==8; token_pixel<=resp_pixel[resp_rd_ptr]; token_tap<=resp_tap[resp_rd_ptr]; token_lane_mask<=lane_mask_reg; token_act<=resp_data[resp_rd_ptr]; token_weight<=sched_weight_mem[resp_tap[resp_rd_ptr]];
            end else if (!token_valid && resp_bypass) begin
                token_valid<=1; token_first<=meta_tap[meta_rd_ptr]==0; token_last<=meta_tap[meta_rd_ptr]==8; token_pixel<=meta_pixel[meta_rd_ptr]; token_tap<=meta_tap[meta_rd_ptr]; token_lane_mask<=lane_mask_reg; token_act<=shell_rd_data_vector; token_weight<=sched_weight_mem[meta_tap[meta_rd_ptr]];
            end
            if (state==ST_DIRECT_EMIT && issue_count>=TOTAL_TAPS && !token_valid && meta_count==0 && resp_count==0) state<=ST_DRAIN;
            /* The downstream stream4 adapter serializes four lanes after the
             * core's final raw beat.  Keep the bank/half ownership fence
             * closed through that retirement window. */
            if (valid_out && ready_out && out_pixel_idx==OUTPUT_LAST_PIXEL) begin final_output_seen<=1; final_output_wait<=16; end
            else if (final_output_wait != 0) final_output_wait<=final_output_wait-1'b1;
            if (state==ST_DRAIN && read_done_seen && final_output_seen && final_output_wait==0 && !token_valid && meta_count==0 && resp_count==0) state<=ST_RELEASE;
            if (state==ST_RELEASE && shell_release_ready) state<=ST_DONE;
            if (state==ST_DONE && shell_release_resp_valid) begin compute_done_valid<=shell_release_resp_ok; compute_done_bank<=compute_bank_reg; compute_done_epoch<=compute_epoch_reg; state<=ST_IDLE; end
            if (fill_busy && state!=ST_IDLE) overlap_cycles<=overlap_cycles+1'b1;
        end
    end
`ifndef SYNTHESIS
    initial if (MAX_IN_H<1 || MAX_IN_H>17 || MAX_IN_W<1 || MAX_IN_W>17 || OUTPUT_HEIGHT<1 || OUTPUT_HEIGHT>8 || OUTPUT_WIDTH!=8) $error("invalid direct producer geometry");
`endif
endmodule
`default_nettype wire
