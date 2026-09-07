`timescale 1ns/1ps
`default_nettype none

/*
 * M1.1-A single runtime DW16 engine.
 *
 * The engine is deliberately layer-agnostic: DS1 is one 16-channel group and
 * DS2 is two sequential 16-channel groups.  For every output group it loads
 * three source rows into a fixed 3-line 128-bit store, then consumes the nine
 * taps in raster order.  A halo tap never emits a memory request and is
 * supplied with the descriptor's zero-point value.  Row bases and the row
 * increment are registered once at start; the request address thereafter is
 * only an incrementing cursor.
 */
module m11a_dw16_shared_line (
    input  wire         clk,
    input  wire         rst_n,
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
    input  wire [31:0]  desc_dw_activation_min,
    input  wire [31:0]  desc_dw_activation_max,

    input  wire [2303:0] dw_weight_bus,
    input  wire [2047:0] dw_bias_bus,
    input  wire [2047:0] dw_multiplier_bus,
    input  wire [1023:0] dw_shift_bus,

    output wire         mem_req_valid,
    input  wire         mem_req_ready,
    output wire [31:0]  mem_req_addr,
    input  wire         mem_resp_valid,
    input  wire [127:0] mem_resp_data,

    output wire         dw_valid,
    input  wire         dw_ready,
    output wire [127:0] dw_data,
    output wire [9:0]   dw_pixel,
    output wire [1:0]   dw_group,
    output wire [1:0]   dw_context,
    output wire         dw_owner,
    output wire [31:0]  dw_epoch,
    output wire [31:0]  dw_context_ordinal,
    output wire         dw_last,

    output wire         done,
    output wire         error,
    output wire [31:0]  dw_mac_count,
    output wire [31:0]  dw_vector_count,
    output wire [31:0]  padding_tap_count,
    output wire [31:0]  input_read_count
);
    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_LOAD_PREP  = 4'd1;
    localparam [3:0] ST_LOAD_REQ   = 4'd2;
    localparam [3:0] ST_LOAD_WAIT  = 4'd3;
    localparam [3:0] ST_TAP        = 4'd4;
    localparam [3:0] ST_RQ         = 4'd5;
    localparam [3:0] ST_OUT        = 4'd6;
    localparam [3:0] ST_DONE       = 4'd7;
    localparam [3:0] ST_RQ_WAIT    = 4'd8;
    localparam [3:0] ST_RQ_FIRE    = 4'd9;

    reg [3:0] state;
    reg [1:0] layer_r;
    reg [5:0] in_h_r, in_w_r, cin_r;
    reg [6:0] cout_r;
    reg [1:0] stride_r;
    reg [31:0] input_base_r, row_stride_r, row_step_r;
    reg [7:0] input_zp_r;
    reg signed [31:0] dw_zp_r, dw_min_r, dw_max_r;
    reg [5:0] out_h_r, out_w_r;
    reg [1:0] group_count_r;

    /* Four 36-bit-equivalent RAM-shaped slices per logical line can be
     * inferred from these three 128-bit arrays by Vivado.  The active design
     * never allocates a layer-sized feature frame. */
    (* ram_style = "block" *) reg [127:0] line0_mem [0:31];
    (* ram_style = "block" *) reg [127:0] line1_mem [0:31];
    (* ram_style = "block" *) reg [127:0] line2_mem [0:31];
    reg line0_valid, line1_valid, line2_valid;

    reg [1:0] load_slot;
    reg [5:0] load_x;
    reg [31:0] load_addr;
    reg [31:0] center_row_addr;
    reg [5:0] center_row;
    reg [5:0] out_row, out_col;
    reg [1:0] group_r;
    reg [3:0] tap_idx;
    reg [1:0] rq_group;
    /* Keep each requantized group in its own register bank.  A variable
     * part-select here made rq_group a long control-to-data timing arc and
     * forced Vivado to build a 128-bit dynamic writeback mux. */
    reg [31:0] dw_data_r0, dw_data_r1, dw_data_r2, dw_data_r3;
    reg dw_valid_r;
    reg done_r, error_r;
    reg [9:0] pixel_r;
    reg [31:0] context_ordinal_r;
    reg [2:0] context_pixel_r;
    reg [31:0] dw_mac_count_r, dw_vector_count_r, pad_count_r, input_count_r;

    wire signed [47:0] dw_accum_dsp [0:15];
    wire [31:0] dw_rq_data;
    wire dw_rq_valid, dw_rq_ready;
    wire dw_rq_start = (state == ST_RQ_FIRE) && dw_rq_ready;
    reg [127:0] dw_rq_acc_bus_c, dw_rq_bias_bus_c, dw_rq_multiplier_bus_c;
    reg [23:0] dw_rq_shift_bus_c;
    reg [127:0] dw_rq_acc_bus_r, dw_rq_bias_bus_r, dw_rq_multiplier_bus_r;
    reg [23:0] dw_rq_shift_bus_r;

    wire start_fire = start_valid && start_ready;
    wire dw_fire = dw_valid_r && dw_ready;
    assign start_ready = rst_n && (state == ST_IDLE);
    assign mem_req_valid = (state == ST_LOAD_REQ);
    assign mem_req_addr = load_addr;
    assign dw_valid = dw_valid_r;
    assign dw_data = {dw_data_r3, dw_data_r2, dw_data_r1, dw_data_r0};
    assign dw_pixel = pixel_r;
    assign dw_group = group_r;
    assign dw_context = context_ordinal_r[1:0];
    assign dw_owner = context_ordinal_r[0];
    assign dw_epoch = context_ordinal_r >> 1;
    assign dw_context_ordinal = context_ordinal_r;
    assign dw_last = dw_valid_r && (out_row == out_h_r - 1'b1) &&
                     (out_col == out_w_r - 1'b1) &&
                     (group_r == group_count_r - 1'b1);
    assign done = done_r;
    assign error = error_r;
    assign dw_mac_count = dw_mac_count_r;
    assign dw_vector_count = dw_vector_count_r;
    assign padding_tap_count = pad_count_r;
    assign input_read_count = input_count_r;

    reg [1:0] tap_line;
    reg signed [1:0] tap_dx;
    reg tap_spatial_valid;
    reg [5:0] tap_center_x;
    reg tap_line_valid;
    reg [5:0] tap_x_addr;
    reg [127:0] tap_word;
    reg signed [7:0] tap_act [0:15];
    reg signed [7:0] tap_wgt [0:15];
    integer li;

    /* The nine tap positions are decoded explicitly.  This keeps the live
     * address cone free of division/modulo operators. */
    always @* begin
        tap_line = 2'd0;
        tap_dx = 2'sd0;
        case (tap_idx)
            4'd0: begin tap_line = 2'd0; tap_dx = -1; end
            4'd1: begin tap_line = 2'd0; tap_dx =  0; end
            4'd2: begin tap_line = 2'd0; tap_dx =  1; end
            4'd3: begin tap_line = 2'd1; tap_dx = -1; end
            4'd4: begin tap_line = 2'd1; tap_dx =  0; end
            4'd5: begin tap_line = 2'd1; tap_dx =  1; end
            4'd6: begin tap_line = 2'd2; tap_dx = -1; end
            4'd7: begin tap_line = 2'd2; tap_dx =  0; end
            default: begin tap_line = 2'd2; tap_dx =  1; end
        endcase
        tap_center_x = (stride_r == 2) ? {out_col, 1'b0} : out_col;
        tap_spatial_valid = 1'b1;
        if ((tap_dx < 0 && tap_center_x == 0) ||
            (tap_dx > 0 && tap_center_x >= in_w_r - 1'b1))
            tap_spatial_valid = 1'b0;
        if (!tap_spatial_valid)
            tap_x_addr = 0;
        else if (tap_dx < 0)
            tap_x_addr = tap_center_x - 1'b1;
        else if (tap_dx > 0)
            tap_x_addr = tap_center_x + 1'b1;
        else
            tap_x_addr = tap_center_x;

        tap_line_valid = 1'b1;
        if ((tap_line == 2'd0) && !line0_valid) tap_line_valid = 1'b0;
        if ((tap_line == 2'd1) && !line1_valid) tap_line_valid = 1'b0;
        if ((tap_line == 2'd2) && !line2_valid) tap_line_valid = 1'b0;
        tap_word = 128'd0;
        if (tap_spatial_valid && tap_line_valid) begin
            case (tap_line)
                2'd0: if (line0_valid) tap_word = line0_mem[tap_x_addr[4:0]];
                2'd1: if (line1_valid) tap_word = line1_mem[tap_x_addr[4:0]];
                default: if (line2_valid) tap_word = line2_mem[tap_x_addr[4:0]];
            endcase
        end else begin
            tap_word = {16{input_zp_r}};
        end
        for (li = 0; li < 16; li = li + 1) begin
            tap_act[li] = tap_word[li*8 +: 8];
            if (group_r == 2'd0)
                tap_wgt[li] = dw_weight_bus[(li*72 + tap_idx*8) +: 8];
            else
                tap_wgt[li] = dw_weight_bus[(1152 + li*72 + tap_idx*8) +: 8];
        end
    end
    /* One physical DSP accumulator per active DW lane. */
    genvar gd;
    generate
        for (gd = 0; gd < 16; gd = gd + 1) begin : GEN_DW16_MAC
            m11a_dsp48e1_int8_accum u_dsp48e1 (
                .clk(clk), .rst_p(!rst_n), .ce(state == ST_TAP),
                .clear_acc((state == ST_TAP) && (tap_idx == 4'd0)),
                .a_in(tap_act[gd]), .b_in(tap_wgt[gd]),
                .p_out(dw_accum_dsp[gd])
            );
        end
    endgenerate

    integer i;
    integer global_ch;
    integer rq_lane;
    always @* begin
        dw_rq_acc_bus_c = 128'd0;
        dw_rq_bias_bus_c = 128'd0;
        dw_rq_multiplier_bus_c = 128'd0;
        dw_rq_shift_bus_c = 24'd0;
        for (rq_lane = 0; rq_lane < 4; rq_lane = rq_lane + 1) begin
            global_ch = (group_r == 0) ? ((rq_group * 4) + rq_lane) :
                                         (16 + (rq_group * 4) + rq_lane);
            dw_rq_acc_bus_c[rq_lane*32 +: 32] =
                dw_accum_dsp[(rq_group * 4) + rq_lane][31:0];
            dw_rq_bias_bus_c[rq_lane*32 +: 32] = dw_bias_bus[global_ch*32 +: 32];
            dw_rq_multiplier_bus_c[rq_lane*32 +: 32] =
                dw_multiplier_bus[global_ch*32 +: 32];
            dw_rq_shift_bus_c[rq_lane*6 +: 6] = dw_shift_bus[global_ch*32 +: 6];
        end
        /* The four-lane DWRQ4 is time-multiplexed over the 16-channel
         * vector.  It therefore remains exactly 16 DSPs while the output
         * ABI still carries all sixteen bytes in one held vector. */
    end

    /* DWRQ4 is issued once per DW vector.  Its four lanes use 16 DSPs. */
    m11a_rq4 dwrq4 (
        .clk(clk), .rst_p(!rst_n), .in_valid(dw_rq_start),
        .in_ready(dw_rq_ready), .acc_bus(dw_rq_acc_bus_r),
        .bias_bus(dw_rq_bias_bus_r), .multiplier_bus(dw_rq_multiplier_bus_r),
        .shift_bus(dw_rq_shift_bus_r), .zero_point(dw_zp_r),
        .activation_min(dw_min_r), .activation_max(dw_max_r),
        .out_valid(dw_rq_valid), .out_ready(dw_ready),
        .out_data(dw_rq_data)
    );
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            layer_r <= 0;
            in_h_r <= 0; in_w_r <= 0; cin_r <= 0; cout_r <= 0;
            stride_r <= 0; input_base_r <= 0; row_stride_r <= 0; row_step_r <= 0;
            input_zp_r <= 0; dw_zp_r <= 0; dw_min_r <= 0; dw_max_r <= 127;
            out_h_r <= 0; out_w_r <= 0; group_count_r <= 0;
            line0_valid <= 0; line1_valid <= 0; line2_valid <= 0;
            load_slot <= 0; load_x <= 0; load_addr <= 0; center_row_addr <= 0;
            center_row <= 0; out_row <= 0; out_col <= 0; group_r <= 0;
            tap_idx <= 0;
            dw_data_r0 <= 0; dw_data_r1 <= 0; dw_data_r2 <= 0; dw_data_r3 <= 0;
            dw_valid_r <= 0; done_r <= 0; error_r <= 0;
            rq_group <= 0;
            dw_rq_acc_bus_r <= 0; dw_rq_bias_bus_r <= 0;
            dw_rq_multiplier_bus_r <= 0; dw_rq_shift_bus_r <= 0;
            pixel_r <= 0; context_ordinal_r <= 0; context_pixel_r <= 0;
            dw_mac_count_r <= 0; dw_vector_count_r <= 0; pad_count_r <= 0; input_count_r <= 0;
        end else begin
            if (start_fire) begin
                layer_r <= desc_layer;
                in_h_r <= desc_in_h;
                in_w_r <= desc_in_w;
                cin_r <= desc_cin;
                cout_r <= desc_cout;
                stride_r <= desc_stride;
                input_base_r <= desc_input_base;
                row_stride_r <= desc_input_row_stride;
                row_step_r <= (desc_stride == 2) ? (desc_input_row_stride << 1) : desc_input_row_stride;
                input_zp_r <= desc_input_zero_point;
                dw_zp_r <= $signed(desc_dw_output_zero_point);
                dw_min_r <= $signed(desc_dw_activation_min);
                dw_max_r <= $signed(desc_dw_activation_max);
                out_h_r <= (desc_stride == 2) ? (desc_in_h >> 1) : desc_in_h;
                out_w_r <= (desc_stride == 2) ? (desc_in_w >> 1) : desc_in_w;
                group_count_r <= (desc_cin == 32) ? 2 : 1;
                center_row <= 0;
                center_row_addr <= desc_input_base;
                out_row <= 0;
                out_col <= 0;
                group_r <= 0;
                pixel_r <= 0;
                context_ordinal_r <= 0;
                context_pixel_r <= 0;
                dw_mac_count_r <= 0;
                dw_vector_count_r <= 0;
                pad_count_r <= 0;
                input_count_r <= 0;
                dw_valid_r <= 1'b0;
                dw_data_r0 <= 32'd0;
                dw_data_r1 <= 32'd0;
                dw_data_r2 <= 32'd0;
                dw_data_r3 <= 32'd0;
                rq_group <= 2'd0;
                done_r <= 0;
                error_r <= 0;
                state <= ST_LOAD_PREP;
            end

            if (state == ST_LOAD_PREP) begin
                /* Invalid top/bottom rows are represented by valid bits and
                 * never enter the input request channel. */
                if ((load_slot == 0 && center_row == 0) ||
                    (load_slot == 2 && center_row + 1'b1 >= in_h_r)) begin
                    if (load_slot == 0) line0_valid <= 1'b0;
                    else if (load_slot == 1) line1_valid <= 1'b0;
                    else line2_valid <= 1'b0;
                    if (load_slot == 2) begin
                        tap_idx <= 0;
                        state <= ST_TAP;
                    end else begin
                        load_slot <= load_slot + 1'b1;
                    end
                end else begin
                    if (load_slot == 0) line0_valid <= 1'b1;
                    else if (load_slot == 1) line1_valid <= 1'b1;
                    else line2_valid <= 1'b1;
                    load_x <= 0;
                    if (load_slot == 0)
                        load_addr <= center_row_addr - row_stride_r + ((group_r == 1) ? 32'd16 : 32'd0);
                    else if (load_slot == 1)
                        load_addr <= center_row_addr + ((group_r == 1) ? 32'd16 : 32'd0);
                    else
                        load_addr <= center_row_addr + row_stride_r + ((group_r == 1) ? 32'd16 : 32'd0);
                    state <= ST_LOAD_REQ;
                end
            end else if (state == ST_LOAD_REQ) begin
                if (mem_req_ready)
                    state <= ST_LOAD_WAIT;
            end else if (state == ST_LOAD_WAIT) begin
                if (mem_resp_valid) begin
                    if (load_slot == 0) line0_mem[load_x[4:0]] <= mem_resp_data;
                    else if (load_slot == 1) line1_mem[load_x[4:0]] <= mem_resp_data;
                    else line2_mem[load_x[4:0]] <= mem_resp_data;
                    input_count_r <= input_count_r + 1'b1;
                    if (load_x == in_w_r - 1'b1) begin
                        if (load_slot == 2) begin
                            tap_idx <= 0;
                            state <= ST_TAP;
                        end else begin
                            load_slot <= load_slot + 1'b1;
                            state <= ST_LOAD_PREP;
                        end
                    end else begin
                        load_x <= load_x + 1'b1;
                        /* A DS2 pixel occupies two 128-bit beats.  The
                         * second channel group starts at +16 bytes, but the
                         * next pixel advances by the full 32-byte pixel
                         * stride; a fixed +16 cursor aliased group-1 reads
                         * onto the next pixel's group-0 beat. */
                        load_addr <= load_addr + ((cin_r == 32) ? 32'd32 : 32'd16);
                        state <= ST_LOAD_REQ;
                    end
                end
            end else if (state == ST_TAP) begin
                dw_mac_count_r <= dw_mac_count_r + 32'd16;
                if ((!tap_spatial_valid || !tap_line_valid) && group_r == 0)
                    pad_count_r <= pad_count_r + 1'b1;
                if (tap_idx == 4'd8) begin
                    rq_group <= 2'd0;
                    dw_data_r0 <= 32'd0;
                    dw_data_r1 <= 32'd0;
                    dw_data_r2 <= 32'd0;
                    dw_data_r3 <= 32'd0;
                    state <= ST_RQ;
                end else begin
                    tap_idx <= tap_idx + 1'b1;
                end
            end else if (state == ST_RQ) begin
                /* Capture the dynamic channel/bias selection at a real
                 * register boundary before starting the four-lane RQ DSP
                 * pipeline.  rq_group no longer fans directly into DWRQ4. */
                if (dw_rq_ready) begin
                    dw_rq_acc_bus_r <= dw_rq_acc_bus_c;
                    dw_rq_bias_bus_r <= dw_rq_bias_bus_c;
                    dw_rq_multiplier_bus_r <= dw_rq_multiplier_bus_c;
                    dw_rq_shift_bus_r <= dw_rq_shift_bus_c;
                    state <= ST_RQ_FIRE;
                end
            end else if (state == ST_RQ_FIRE) begin
                if (dw_rq_start)
                    state <= ST_RQ_WAIT;
            end else if (state == ST_RQ_WAIT) begin
                if (dw_rq_valid && dw_ready) begin
                    case (rq_group)
                        2'd0: dw_data_r0 <= dw_rq_data;
                        2'd1: dw_data_r1 <= dw_rq_data;
                        2'd2: dw_data_r2 <= dw_rq_data;
                        default: dw_data_r3 <= dw_rq_data;
                    endcase
                    if (rq_group == 2'd3) begin
                        dw_valid_r <= 1'b1;
                        state <= ST_OUT;
                    end else begin
                        rq_group <= rq_group + 1'b1;
                        state <= ST_RQ;
                    end
                end
            end else if (state == ST_OUT) begin
                if (dw_fire) begin
                    dw_valid_r <= 1'b0;
                    dw_vector_count_r <= dw_vector_count_r + 1'b1;
                    if (group_r == group_count_r - 1'b1) begin
                        if (out_col == out_w_r - 1'b1) begin
                            if (out_row == out_h_r - 1'b1) begin
                                done_r <= 1'b1;
                                state <= ST_DONE;
                            end else begin
                                out_row <= out_row + 1'b1;
                                out_col <= 0;
                                pixel_r <= pixel_r + 1'b1;
                                if (context_pixel_r == 3'd7) begin
                                    context_pixel_r <= 0;
                                    context_ordinal_r <= context_ordinal_r + 1'b1;
                                end else begin
                                    context_pixel_r <= context_pixel_r + 1'b1;
                                end
                                center_row <= center_row + ((stride_r == 2) ? 2 : 1);
                                center_row_addr <= center_row_addr + row_step_r;
                                group_r <= 0;
                                load_slot <= 0;
                                state <= ST_LOAD_PREP;
                            end
                        end else begin
                            out_col <= out_col + 1'b1;
                            pixel_r <= pixel_r + 1'b1;
                            if (context_pixel_r == 3'd7) begin
                                context_pixel_r <= 0;
                                context_ordinal_r <= context_ordinal_r + 1'b1;
                            end else begin
                                context_pixel_r <= context_pixel_r + 1'b1;
                            end
                            group_r <= 0;
                            tap_idx <= 0;
                            /* DS2 reuses the one three-line store for the
                             * second 16-channel group.  Once group 1 has
                             * been emitted, group 0 must be reloaded before
                             * the next output column; otherwise the next
                             * group-0 vector consumes group-1 activations. */
                            load_slot <= 0;
                            state <= (group_count_r == 2) ? ST_LOAD_PREP : ST_TAP;
                        end
                    end else begin
                        group_r <= group_r + 1'b1;
                        load_slot <= 0;
                        state <= ST_LOAD_PREP;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
