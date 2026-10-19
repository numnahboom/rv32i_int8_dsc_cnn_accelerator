`timescale 1ns/1ps
`default_nettype none
// Independent fixed-network D4 implementation. Resident weights, streamed image.
// FC returns signed accumulators; channel scales are part of the deployment ABI.
module d4_fullnet_top #(
    parameter DATA_DIR = "build/d4_fullnet_vectors/sample_0",
    parameter integer OP_COUNT = 41,
    parameter integer WEIGHT_WORDS = 4096,
    parameter integer QUANT_WORDS = 256,
    parameter integer LUT_WORDS = 4096,
    parameter integer IMAGE_WORDS = 1024
) (
    input wire clk, rst_n,
    input wire start_valid, (* IOB = "TRUE" *) output reg start_ready,
    input wire input_valid, (* IOB = "TRUE" *) output reg input_ready, input wire [127:0] input_data,
    output wire logit_valid, input wire logit_ready,
    output wire [3:0] logit_index, output wire signed [31:0] logit_acc,
    (* IOB = "TRUE" *) output reg done_valid, input wire done_ready,
    (* IOB = "TRUE" *) output reg busy, output reg error,
    output reg [31:0] cycle_count, semantic_mac_count,
    output wire trace_valid, output wire [5:0] trace_op,
    output wire [10:0] trace_index, output wire [127:0] trace_data
);
    localparam [5:0] IDLE=0, IMAGE=1, DECODE=2, INIT=3, READ=4,
        MULT=5, ACC=6, STORE=10,
        NEXT=11, OP_NEXT=12, ADD_READ=13, ADD_ADDR=14, ADD_USE=15,
        GAP_INIT=16, GAP_READ=17, GAP_ACC=18, GAP_ROUND=19,
        FC_OUT=20, STREAM=22, LAUNCH=23, FC_LOAD=24, ADDR_INIT=25,
        RESIDUAL_PIPE=27;
    reg [5:0] state, op_index;
    reg [5:0] ox, oy;
    reg [8:0] oc, ic;
    reg [1:0] ky, kx;
    reg [10:0] image_index, vector_index;
    reg [4:0] lane_index;
    reg [4:0] gap_pixel;
    reg [127:0] result_vector;
    reg signed [31:0] accum [0:15];
    reg signed [15:0] product [0:15][0:3];
    reg signed [7:0] operand_a [0:15][0:3], operand_b [0:15][0:3];
    reg signed [17:0] mac_sum [0:15];
    wire signed [63:0] rq_product [0:15];
    reg signed [63:0] rq_value [0:15];
    reg [63:0] rq_bias [0:15];
    wire signed [31:0] rq_engine_a [0:15], rq_engine_b [0:15];
    wire [15:0] rq_lane_valid;
    reg [7:0] quant_cursor;
    reg issue_done, read_valid, product_valid, read_last, product_last, read_halo;
    reg operand_valid, operand_last, sum_valid, sum_last;
    reg [3:0] read_channel;
    reg [2:0] read_inputs, product_inputs;
    reg [2:0] operand_inputs, sum_inputs;
    reg [11:0] weight_cursor, group_weight_base;
    // Two independent accumulator banks permit one K-word group to leave the
    // MAC while the other bank's prior result advances through requantization.
    reg active_bank;
    reg signed [31:0] bank_accum [0:1][0:15];
    reg signed [31:0] bank_bias [0:1][0:15];
    reg [511:0] bank_multiplier [0:1];
    reg [95:0] bank_shift [0:1];
    reg bank_busy [0:1];
    reg [31:0] group_sequence, bank_sequence [0:1];
    reg read_bank, operand_bank, product_bank, sum_bank;
    reg read_first, operand_first, product_first, sum_first;
    reg read_op_last, operand_op_last, product_op_last, sum_op_last;
    reg [10:0] read_vector, operand_vector, product_vector, sum_vector;
    reg [8:0] read_oc, operand_oc, product_oc, sum_oc;
    reg [31:0] read_sequence, operand_sequence, product_sequence, sum_sequence;
    reg rq_pending_valid, rq_pending_bank, rq_pending_op_last, rq_pending_relu;
    reg [10:0] rq_pending_vector;
    reg [8:0] rq_pending_oc;
    reg [31:0] rq_pending_sequence;
    reg rq_input_valid, rq_partial_valid, rq_merge_valid;
    reg rq_product_valid, rq_round_valid, rq_clamp_valid;
    reg [95:0] rq_shift, rq_partial_shift, rq_merge_shift, rq_product_shift;
    reg [15:0] rq_negative, rq_partial_negative, rq_merge_negative;
    reg [10:0] rq_index, rq_partial_index, rq_merge_index;
    reg [10:0] rq_product_index, rq_round_index, rq_clamp_index;
    reg [8:0] rq_oc, rq_partial_oc, rq_merge_oc, rq_product_oc, rq_round_oc;
    reg rq_op_last, rq_product_op_last, rq_round_op_last, rq_clamp_op_last;
    reg rq_partial_op_last, rq_merge_op_last;
    reg rq_relu, rq_partial_relu, rq_merge_relu, rq_product_relu, rq_round_relu;
    reg [31:0] rq_sequence, rq_partial_sequence, rq_merge_sequence, rq_product_sequence;
    reg [10:0] row_stride, source_center, source_row_center;
    reg [10:0] row_prepare, tap_row_start, tap_address;
    reg [4:0] pixel_stride;
    (* IOB = "true" *) reg signed [31:0] logit_data_reg;
    (* IOB = "true" *) reg [3:0] logit_index_reg;
    (* IOB = "true" *) reg logit_valid_reg;
    reg signed [31:0] logit_queue [0:8];
    (* rom_style = "block" *) reg [511:0] weights [0:WEIGHT_WORDS-1];
    (* rom_style = "distributed" *) reg [511:0] biases [0:QUANT_WORDS-1];
    (* rom_style = "distributed" *) reg [511:0] multipliers [0:QUANT_WORDS-1];
    (* rom_style = "distributed" *) reg [511:0] shifts [0:QUANT_WORDS-1];
    (* rom_style = "distributed" *) reg [31:0] descriptors [0:OP_COUNT*32-1];
`ifndef SYNTHESIS
    integer halo_geom_op;
    integer halo_geom_hin, halo_geom_win, halo_geom_hout, halo_geom_wout;
    integer halo_geom_kernel, halo_geom_stride;
`endif
    // Four dual-port replicas issue four independent branch pairs each cycle.
    // The checked-in 32-bit ROM words are exactly representable as signed 9-bit
    // values; the proof artifact checks the complete table and every ADD range.
    (* rom_style = "block" *) reg signed [8:0] residual_lut0 [0:LUT_WORDS-1];
    (* rom_style = "block" *) reg signed [8:0] residual_lut1 [0:LUT_WORDS-1];
    (* rom_style = "block" *) reg signed [8:0] residual_lut2 [0:LUT_WORDS-1];
    (* rom_style = "block" *) reg signed [8:0] residual_lut3 [0:LUT_WORDS-1];
    (* ram_style = "block" *) reg [127:0] features [0:6143];
    reg [127:0] fm_a, fm_b;
    reg [511:0] weight_q;
    reg signed [8:0] residual_lut0_a_q, residual_lut0_b_q;
    reg signed [8:0] residual_lut1_a_q, residual_lut1_b_q;
    reg signed [8:0] residual_lut2_a_q, residual_lut2_b_q;
    reg signed [8:0] residual_lut3_a_q, residual_lut3_b_q;
    reg residual_lut_valid, residual_sum_valid;
    reg [2:0] residual_issue_chunk;
    reg [1:0] residual_lut_chunk_q, residual_sum_chunk_q;
    reg signed [9:0] residual_sum_q [0:3];
    initial begin
        $readmemh({DATA_DIR,"/weights.mem"}, weights);
        $readmemh({DATA_DIR,"/bias.mem"}, biases);
        $readmemh({DATA_DIR,"/multiplier.mem"}, multipliers);
        $readmemh({DATA_DIR,"/shift.mem"}, shifts);
        $readmemh({DATA_DIR,"/descriptors.mem"}, descriptors);
        $readmemh({DATA_DIR,"/residual_lut.mem"}, residual_lut0);
        $readmemh({DATA_DIR,"/residual_lut.mem"}, residual_lut1);
        $readmemh({DATA_DIR,"/residual_lut.mem"}, residual_lut2);
        $readmemh({DATA_DIR,"/residual_lut.mem"}, residual_lut3);
`ifndef SYNTHESIS
        // Candidate N specializes only the frozen D4 convolution geometry.
        // Reject unsupported descriptor tables in simulation while keeping
        // this guard out of the synthesized hardware.
        for (halo_geom_op=0; halo_geom_op<OP_COUNT; halo_geom_op=halo_geom_op+1) begin
            if (descriptors[halo_geom_op*32+0] == 32'd0) begin
                halo_geom_hin=descriptors[halo_geom_op*32+4];
                halo_geom_win=descriptors[halo_geom_op*32+5];
                halo_geom_hout=descriptors[halo_geom_op*32+8];
                halo_geom_wout=descriptors[halo_geom_op*32+9];
                halo_geom_kernel=descriptors[halo_geom_op*32+10];
                halo_geom_stride=descriptors[halo_geom_op*32+11];
                if (((halo_geom_kernel != 1) && (halo_geom_kernel != 3)) ||
                    ((halo_geom_stride != 1) && (halo_geom_stride != 2)) ||
                    (halo_geom_hin < 1) || (halo_geom_hin > 32) ||
                    (halo_geom_win < 1) || (halo_geom_win > 32) ||
                    (halo_geom_hout < 1) || (halo_geom_hout > 32) ||
                    (halo_geom_wout < 1) || (halo_geom_wout > 32) ||
                    (halo_geom_hin != halo_geom_hout*halo_geom_stride) ||
                    (halo_geom_win != halo_geom_wout*halo_geom_stride))
                    $fatal(1,"D4_HALO_UNSUPPORTED_CONV_GEOMETRY op=%0d",halo_geom_op);
            end
        end
`endif
    end
    reg [1:0] kind,src_slot,dst_slot,id_slot,kernel;
    reg [5:0] hin,win,hout,wout;
    reg [8:0] cin,cout;
    reg stride2,dw,relu;
    reg [11:0] weight_base,lut_a_base,lut_b_base;
    reg [7:0] quant_base;
    reg [2:0] log_w,log_groups;
    reg [11:0] output_words;
    wire [7:0] qaddr=quant_cursor;
    wire [511:0] bias_word=biases[qaddr];
    wire [511:0] mul_word=multipliers[qaddr];
    wire [511:0] shift_word=shifts[qaddr];
    wire issue_first=(ic==0) && (kx==0) && (ky==0);
    reg [10:0] spatial_word;
    reg halo;
    reg [12:0] read_a, read_b, write_addr;
    reg [31:0] weight_addr;
    wire write_en_a=(state==STORE && kind!=0) || (state==IMAGE && input_valid);
    wire write_en_b=(state==STREAM && kind==0 && rq_clamp_valid);
    wire [127:0] write_data=state==IMAGE ? input_data : result_vector;
    wire issue_last=(dw || ic+4>=cin) && kx+1>=kernel && ky+1>=kernel;
    wire issue_op_last=issue_last && (oc+16>=cout) && (ox+1>=wout) && (oy+1>=hout);
    wire [10:0] next_x_center=source_center+(pixel_stride<<stride2);
    wire [10:0] next_y_center=source_row_center+(row_stride<<stride2);
    wire [10:0] tap_pad_x=(kernel==3)?{6'd0,pixel_stride}:11'd0;
    wire [10:0] tap_pad_y=(kernel==3)?row_stride:11'd0;
    wire [10:0] current_tap_base=source_center-tap_pad_y-tap_pad_x;
    wire [10:0] next_x_tap_base=next_x_center-tap_pad_y-tap_pad_x;
    wire [10:0] next_y_tap_base=next_y_center-tap_pad_y-tap_pad_x;
    always @* begin
        halo=(kernel==2'd3) &&
             ((ky==2'd0 && oy==6'd0) || (kx==2'd0 && ox==6'd0) ||
              (!stride2 && ((ky==2'd2 && oy+6'd1==hout) ||
                            (kx==2'd2 && ox+6'd1==wout))));
        // Each slot has 2048 words and channel groups are powers of two.
        // Concatenation/OR preserves these disjoint fields without carry chains.
        spatial_word=tap_address|(dw?(oc>>4):(ic>>4));
        read_a={src_slot,spatial_word};
        read_b={id_slot,vector_index};
        weight_addr={20'd0,weight_cursor};
        write_addr={dst_slot,vector_index};
        // Halo samples may read any word within their allocated source slot.
        // Their registered metadata forces zero operands before multiplication.
        // Keeping halo out of the address mux removes a coordinate-to-BRAM path.
        if(state==ADD_READ || state==ADD_ADDR || state==ADD_USE) begin
            read_a={src_slot,vector_index};
        end
        if(state==GAP_READ || state==GAP_ACC || state==GAP_ROUND) begin
            read_a={src_slot,11'd0}|(gap_pixel<<log_groups)|(oc>>4);
        end
        if(state==IMAGE) write_addr={2'b00,image_index};
    end
    // Port A continuously serves affine reads. Port B commits affine results
    // and otherwise reads residual identity data, which never overlaps conv.
    wire [12:0] port_a_addr=write_en_a?write_addr:read_a;
    wire issue_read=state==STREAM && !issue_done;
    wire fm_read_a=issue_read || state==ADD_READ || state==GAP_READ;
    wire [12:0] port_b_addr=write_en_b?{dst_slot,rq_clamp_index}:read_b;
    wire fm_read_b=state==ADD_READ;
    wire port_a_en=write_en_a || fm_read_a;
    wire port_b_en=write_en_b || fm_read_b;
    wire [4:0] residual_lane0={residual_issue_chunk,2'b00};
    wire [4:0] residual_lane1=residual_lane0+5'd1;
    wire [4:0] residual_lane2=residual_lane0+5'd2;
    wire [4:0] residual_lane3=residual_lane0+5'd3;
    wire [11:0] residual_addr_a0=lut_a_base+(fm_b[residual_lane0*8+:8]^8'h80);
    wire [11:0] residual_addr_b0=lut_b_base+(fm_a[residual_lane0*8+:8]^8'h80);
    wire [11:0] residual_addr_a1=lut_a_base+(fm_b[residual_lane1*8+:8]^8'h80);
    wire [11:0] residual_addr_b1=lut_b_base+(fm_a[residual_lane1*8+:8]^8'h80);
    wire [11:0] residual_addr_a2=lut_a_base+(fm_b[residual_lane2*8+:8]^8'h80);
    wire [11:0] residual_addr_b2=lut_b_base+(fm_a[residual_lane2*8+:8]^8'h80);
    wire [11:0] residual_addr_a3=lut_a_base+(fm_b[residual_lane3*8+:8]^8'h80);
    wire [11:0] residual_addr_b3=lut_b_base+(fm_a[residual_lane3*8+:8]^8'h80);
    always @(posedge clk) begin
        if(issue_read) weight_q<=weights[weight_addr];
        // Each replica supplies both branches for one lane in a four-lane chunk.
        // Tables enumerate signed -128..127, so index = raw byte XOR 0x80.
        if(state==RESIDUAL_PIPE && residual_issue_chunk<4) begin
            residual_lut0_a_q<=residual_lut0[residual_addr_a0];
            residual_lut0_b_q<=residual_lut0[residual_addr_b0];
            residual_lut1_a_q<=residual_lut1[residual_addr_a1];
            residual_lut1_b_q<=residual_lut1[residual_addr_b1];
            residual_lut2_a_q<=residual_lut2[residual_addr_a2];
            residual_lut2_b_q<=residual_lut2[residual_addr_b2];
            residual_lut3_a_q<=residual_lut3[residual_addr_a3];
            residual_lut3_b_q<=residual_lut3[residual_addr_b3];
        end
    end
    always @(posedge clk) begin
        if(port_a_en) begin
            if(write_en_a) features[port_a_addr]<=write_data;
            fm_a<=features[port_a_addr];
        end
    end
    always @(posedge clk) begin
        if(port_b_en) begin
            if(write_en_b) features[port_b_addr]<=result_vector;
            fm_b<=features[port_b_addr];
        end
    end
    function automatic [7:0] saturate8(input signed [63:0] x);
        if(x>127) saturate8=8'h7f;
        else if(x< -128) saturate8=8'h80;
        else saturate8=x[7:0];
    endfunction
    function automatic [7:0] saturate10(input signed [9:0] x);
        if(x>10'sd127) saturate10=8'h7f;
        else if(x< -10'sd128) saturate10=8'h80;
        else saturate10=x[7:0];
    endfunction
    function automatic [63:0] make_round_bias(input [5:0] sh,input negative);
        if(sh==0) make_round_bias=0;
        else make_round_bias=(64'd1<<(sh-6'd1))-{{63{1'b0}},negative};
    endfunction
    function automatic signed [63:0] round_biased(
        input signed [63:0] x,input [63:0] bias,input [5:0] sh
    );
        reg signed [64:0] adjusted;
        begin
            // The extra bit keeps positive x+bias from overflowing at sh=63.
            adjusted=$signed({x[63],x})+$signed({1'b0,bias});
            round_biased=adjusted>>>sh;
        end
    endfunction
    function automatic signed [63:0] round_shift(input signed [63:0] x,input [5:0] sh);
        round_shift=round_biased(x,make_round_bias(sh,x[63]),sh);
    endfunction
    function automatic signed [17:0] reduce4(
        input signed [15:0] a,b,c,d
    );
        reg signed [16:0] left_sum,right_sum;
        begin
            left_sum=$signed({a[15],a})+$signed({b[15],b});
            right_sum=$signed({c[15],c})+$signed({d[15],d});
            reduce4=$signed({left_sum[16],left_sum})+$signed({right_sum[16],right_sum});
        end
    endfunction
    assign logit_valid=logit_valid_reg;
    assign logit_index=logit_index_reg;
    assign logit_acc=logit_data_reg;
    assign trace_valid=(state==STORE) || (state==STREAM && kind==0 && rq_clamp_valid);
    assign trace_op=op_index;
    assign trace_index=(state==STORE)?vector_index:rq_clamp_index;
    assign trace_data=result_vector;
    integer l, j, b;
    integer valid_outputs, valid_inputs;
    reg signed [32:0] add_value;
    genvar rq_lane;
    generate for(rq_lane=0;rq_lane<16;rq_lane=rq_lane+1) begin: rq_mul_lanes
        assign rq_engine_a[rq_lane]=bank_accum[rq_pending_bank][rq_lane];
        assign rq_engine_b[rq_lane]=
            $signed(bank_multiplier[rq_pending_bank][rq_lane*32+:32]);
        d4_rq_partial_multiplier_lane rq_mul(
            .clk(clk),.rst_n(rst_n),.in_valid(rq_pending_valid),
            .a(rq_engine_a[rq_lane]),.b(rq_engine_b[rq_lane]),
            .product(rq_product[rq_lane]),.out_valid(rq_lane_valid[rq_lane])
        );
    end endgenerate
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE; op_index<=0; error<=0;
            start_ready<=1;input_ready<=0;done_valid<=0;busy<=0;
            cycle_count<=0; semantic_mac_count<=0;
            ox<=0;oy<=0;oc<=0;ic<=0;kx<=0;ky<=0;
            image_index<=0;vector_index<=0;lane_index<=0;gap_pixel<=0;
            result_vector<=0;
            quant_cursor<=0;
            issue_done<=0;read_valid<=0;product_valid<=0;read_last<=0;product_last<=0;
            operand_valid<=0;operand_last<=0;sum_valid<=0;sum_last<=0;
            operand_inputs<=0;sum_inputs<=0;
            active_bank<=0;group_sequence<=0;
            read_bank<=0;operand_bank<=0;product_bank<=0;sum_bank<=0;
            read_first<=0;operand_first<=0;product_first<=0;sum_first<=0;
            read_op_last<=0;operand_op_last<=0;product_op_last<=0;sum_op_last<=0;
            read_vector<=0;operand_vector<=0;product_vector<=0;sum_vector<=0;
            read_oc<=0;operand_oc<=0;product_oc<=0;sum_oc<=0;
            read_sequence<=0;operand_sequence<=0;product_sequence<=0;sum_sequence<=0;
            rq_pending_valid<=0;rq_pending_bank<=0;rq_pending_op_last<=0;rq_pending_relu<=0;
            rq_pending_vector<=0;rq_pending_oc<=0;rq_pending_sequence<=0;
            rq_input_valid<=0;rq_partial_valid<=0;rq_merge_valid<=0;
            rq_product_valid<=0;rq_round_valid<=0;rq_clamp_valid<=0;
            rq_shift<=0;rq_partial_shift<=0;rq_merge_shift<=0;rq_product_shift<=0;
            rq_negative<=0;rq_partial_negative<=0;rq_merge_negative<=0;
            rq_index<=0;rq_partial_index<=0;rq_merge_index<=0;
            rq_product_index<=0;rq_round_index<=0;rq_clamp_index<=0;
            rq_oc<=0;rq_partial_oc<=0;rq_merge_oc<=0;rq_product_oc<=0;rq_round_oc<=0;
            rq_op_last<=0;rq_partial_op_last<=0;rq_merge_op_last<=0;
            rq_product_op_last<=0;rq_round_op_last<=0;rq_clamp_op_last<=0;
            rq_relu<=0;rq_partial_relu<=0;rq_merge_relu<=0;
            rq_product_relu<=0;rq_round_relu<=0;
            rq_sequence<=0;rq_partial_sequence<=0;rq_merge_sequence<=0;rq_product_sequence<=0;
            residual_lut_valid<=0;residual_sum_valid<=0;
            residual_issue_chunk<=0;residual_lut_chunk_q<=0;residual_sum_chunk_q<=0;
            for(l=0;l<4;l=l+1) residual_sum_q[l]<=0;
            read_halo<=0;read_channel<=0;read_inputs<=0;product_inputs<=0;
            weight_cursor<=0;group_weight_base<=0;
            row_stride<=0;pixel_stride<=0;source_center<=0;source_row_center<=0;
            row_prepare<=0;tap_row_start<=0;tap_address<=0;
            kind<=0;src_slot<=0;dst_slot<=0;id_slot<=0;kernel<=0;
            hin<=0;win<=0;hout<=0;wout<=0;cin<=0;cout<=0;
            stride2<=0;dw<=0;relu<=0;weight_base<=0;quant_base<=0;
            lut_a_base<=0;lut_b_base<=0;log_w<=0;log_groups<=0;output_words<=0;
            logit_data_reg<=0;logit_index_reg<=0;logit_valid_reg<=0;
            for(l=0;l<9;l=l+1) logit_queue[l]<=0;
            for(b=0;b<2;b=b+1) begin
                bank_busy[b]<=0;bank_sequence[b]<=0;
                    bank_multiplier[b]<=0;bank_shift[b]<=0;
                for(l=0;l<16;l=l+1) begin
                    bank_accum[b][l]<=0;bank_bias[b][l]<=0;
                end
            end
            for(l=0;l<16;l=l+1) begin
                accum[l]<=0;rq_value[l]<=0;rq_bias[l]<=0;
                mac_sum[l]<=0;
                for(j=0;j<4;j=j+1) begin
                    product[l][j]<=0;operand_a[l][j]<=0;operand_b[l][j]<=0;
                end
            end
        end else begin
            if(busy) cycle_count<=cycle_count+1;
`ifndef SYNTHESIS
            if(rq_lane_valid!=={16{rq_lane_valid[0]}} ||
               rq_lane_valid[0]!==rq_product_valid)
                $fatal(1,"RQ_LANE_VALID_MISMATCH lanes=%h meta=%0d",
                       rq_lane_valid,rq_product_valid);
`endif
            if(done_valid && done_ready) begin
                done_valid<=0;
                start_ready<=1;
            end
            case(state)
                IDLE: if(start_valid && start_ready) begin
                    cycle_count<=0;semantic_mac_count<=0;error<=0;
                    start_ready<=0;input_ready<=1;busy<=1;
                    op_index<=0;image_index<=0;state<=IMAGE;
                end
                IMAGE: if(input_valid) begin
                    if(image_index==IMAGE_WORDS-1) begin
                        input_ready<=0;state<=DECODE;
                    end
                    else image_index<=image_index+1;
                end
                DECODE: begin
                    kind<=descriptors[{op_index,5'b0}+0][1:0];
                    src_slot<=descriptors[{op_index,5'b0}+1][1:0];
                    dst_slot<=descriptors[{op_index,5'b0}+2][1:0];
                    id_slot<=descriptors[{op_index,5'b0}+3][1:0];
                    hin<=descriptors[{op_index,5'b0}+4][5:0];
                    win<=descriptors[{op_index,5'b0}+5][5:0];
                    cin<=descriptors[{op_index,5'b0}+6][8:0];
                    cout<=descriptors[{op_index,5'b0}+7][8:0];
                    hout<=descriptors[{op_index,5'b0}+8][5:0];
                    wout<=descriptors[{op_index,5'b0}+9][5:0];
                    kernel<=descriptors[{op_index,5'b0}+10][1:0];
                    stride2<=descriptors[{op_index,5'b0}+11]==2;
                    dw<=descriptors[{op_index,5'b0}+12]!=0;
                    relu<=descriptors[{op_index,5'b0}+13]!=0;
                    weight_base<=descriptors[{op_index,5'b0}+14][11:0];
                    quant_base<=descriptors[{op_index,5'b0}+15][7:0];
                    lut_a_base<=descriptors[{op_index,5'b0}+16][11:0];
                    lut_b_base<=descriptors[{op_index,5'b0}+17][11:0];
                    log_w<=descriptors[{op_index,5'b0}+18][2:0];
                    log_groups<=descriptors[{op_index,5'b0}+19][2:0];
                    output_words<=descriptors[{op_index,5'b0}+20][11:0];
                    state<=LAUNCH;
                end
                LAUNCH: begin
                    ox<=0;oy<=0;oc<=0;ic<=0;kx<=0;ky<=0;
                    group_weight_base<=weight_base;
                    quant_cursor<=quant_base;
                    row_stride<=11'd1<<({1'b0,log_w}+{1'b0,log_groups});
                    pixel_stride<=5'd1<<log_groups;
                    source_center<=0;source_row_center<=0;
                    vector_index<=0;lane_index<=0;
                    case(kind)
                        0: begin
                            issue_done<=0;active_bank<=0;group_sequence<=0;
                            read_valid<=0;product_valid<=0;operand_valid<=0;sum_valid<=0;
                            rq_pending_valid<=0;rq_input_valid<=0;rq_partial_valid<=0;
                            rq_merge_valid<=0;rq_product_valid<=0;rq_round_valid<=0;
                            rq_clamp_valid<=0;
                            weight_cursor<=weight_base;group_weight_base<=weight_base;
                            row_prepare<=11'd0-(kernel==3?
                                (11'd1<<({1'b0,log_w}+{1'b0,log_groups})):11'd0);
                            state<=ADDR_INIT;
                        end
                        3: state<=INIT;
                        1: state<=ADD_READ;
                        2: state<=GAP_INIT;
                        default: begin
                            error<=1;state<=IDLE;input_ready<=0;done_valid<=1;
                            busy<=0;start_ready<=0;
                        end
                    endcase
                end
                INIT: begin
                    for(l=0;l<16;l=l+1) begin
                        accum[l]<=$signed(bias_word[l*32+:32]);
                    end
                    ic<=0;ky<=0;kx<=0;
                    issue_done<=0;read_valid<=0;product_valid<=0;
                    operand_valid<=0;sum_valid<=0;
                    weight_cursor<=group_weight_base;
                    row_prepare<=source_center-(kernel==3?row_stride:11'd0);
                    state<=ADDR_INIT;
                end
                ADDR_INIT: begin
                    tap_row_start<=row_prepare-(kernel==3?pixel_stride:5'd0);
                    tap_address<=row_prepare-(kernel==3?pixel_stride:5'd0);
                    state<=STREAM;
                end
                STREAM: begin
                    // Continuous affine issue: counters move at group boundaries,
                    // while every arithmetic decision uses issue-aligned metadata.
                    read_valid<=issue_read;
                    read_last<=issue_read && issue_last;
                    read_halo<=halo;
                    read_channel<=ic[3:0];
                    read_inputs<=dw?1:((cin-ic<4)?cin-ic:4);
                    read_bank<=active_bank;
                    read_first<=issue_read && issue_first;
                    read_op_last<=issue_read && issue_op_last;
                    read_vector<=vector_index;
                    read_oc<=oc;
                    read_sequence<=group_sequence;
                    operand_valid<=read_valid;
                    operand_last<=read_last;
                    operand_inputs<=read_inputs;
                    operand_bank<=read_bank;
                    operand_first<=read_first;
                    operand_op_last<=read_op_last;
                    operand_vector<=read_vector;
                    operand_oc<=read_oc;
                    operand_sequence<=read_sequence;
                    product_valid<=operand_valid;
                    product_last<=operand_last;
                    product_inputs<=operand_inputs;
                    product_bank<=operand_bank;
                    product_first<=operand_first;
                    product_op_last<=operand_op_last;
                    product_vector<=operand_vector;
                    product_oc<=operand_oc;
                    product_sequence<=operand_sequence;
                    sum_valid<=product_valid;
                    sum_last<=product_last;
                    sum_inputs<=product_inputs;
                    sum_bank<=product_bank;
                    sum_first<=product_first;
                    sum_op_last<=product_op_last;
                    sum_vector<=product_vector;
                    sum_oc<=product_oc;
                    sum_sequence<=product_sequence;
                    rq_pending_valid<=sum_valid && sum_last && kind==0;
                    rq_input_valid<=rq_pending_valid;
                    rq_partial_valid<=rq_input_valid;
                    rq_merge_valid<=rq_partial_valid;
                    rq_product_valid<=rq_merge_valid;
                    rq_round_valid<=rq_product_valid;
                    rq_clamp_valid<=rq_round_valid;

                    if(issue_read && kind==0 && issue_first) begin
`ifndef SYNTHESIS
                        if(bank_busy[active_bank] &&
                           !(rq_pending_valid && rq_pending_bank==active_bank))
                            $fatal(1,"ACC_BANK_OVERWRITE bank=%0d group=%0d old=%0d",
                                   active_bank,group_sequence,bank_sequence[active_bank]);
`endif
                        bank_busy[active_bank]<=1;
                        bank_sequence[active_bank]<=group_sequence;
                        bank_multiplier[active_bank]<=mul_word;
                        for(l=0;l<16;l=l+1) begin
                            bank_bias[active_bank][l]<=$signed(bias_word[l*32+:32]);
                            bank_shift[active_bank][l*6+:6]<=shift_word[l*32+:6];
                        end
                    end
                    if(rq_pending_valid) begin
`ifndef SYNTHESIS
                        if(!bank_busy[rq_pending_bank] ||
                           bank_sequence[rq_pending_bank]!=rq_pending_sequence)
                            $fatal(1,"ACC_BANK_CAPTURE bank=%0d expected=%0d owner=%0d busy=%0d",
                                   rq_pending_bank,rq_pending_sequence,
                                   bank_sequence[rq_pending_bank],bank_busy[rq_pending_bank]);
`endif
                        // A K=4 group can release and reacquire a bank on the
                        // same edge. Preserve ownership for that new first issue.
                        bank_busy[rq_pending_bank]<=issue_read && kind==0 &&
                            issue_first && active_bank==rq_pending_bank;
                        for(l=0;l<16;l=l+1) begin
                            rq_shift[l*6+:6]<=bank_shift[rq_pending_bank][l*6+:6];
                            rq_negative[l]<=bank_accum[rq_pending_bank][l][31]^
                                bank_multiplier[rq_pending_bank][l*32+31];
                        end
                        rq_index<=rq_pending_vector;
                        rq_oc<=rq_pending_oc;
                        rq_op_last<=rq_pending_op_last;
                        rq_relu<=rq_pending_relu;
                        rq_sequence<=rq_pending_sequence;
                    end
                    if(rq_input_valid) begin
                        rq_partial_shift<=rq_shift;
                        rq_partial_negative<=rq_negative;
                        rq_partial_index<=rq_index;
                        rq_partial_oc<=rq_oc;
                        rq_partial_op_last<=rq_op_last;
                        rq_partial_relu<=rq_relu;
                        rq_partial_sequence<=rq_sequence;
                    end
                    if(rq_partial_valid) begin
                        rq_merge_shift<=rq_partial_shift;
                        rq_merge_negative<=rq_partial_negative;
                        rq_merge_index<=rq_partial_index;
                        rq_merge_oc<=rq_partial_oc;
                        rq_merge_op_last<=rq_partial_op_last;
                        rq_merge_relu<=rq_partial_relu;
                        rq_merge_sequence<=rq_partial_sequence;
                    end
                    if(sum_valid && kind==0 && sum_last) begin
`ifndef SYNTHESIS
                        if(!bank_busy[sum_bank] || bank_sequence[sum_bank]!=sum_sequence)
                            $fatal(1,"ACC_BANK_FINAL_SUM bank=%0d group=%0d owner=%0d busy=%0d",
                                   sum_bank,sum_sequence,bank_sequence[sum_bank],bank_busy[sum_bank]);
`endif
                        rq_pending_bank<=sum_bank;
                        rq_pending_vector<=sum_vector;
                        rq_pending_oc<=sum_oc;
                        rq_pending_op_last<=sum_op_last;
                        rq_pending_relu<=relu;
                        rq_pending_sequence<=sum_sequence;
                    end
                    if(read_valid) begin
                        for(l=0;l<16;l=l+1)
                            for(j=0;j<4;j=j+1) begin
                                if(read_halo || read_oc+l>=cout || (dw && j!=0) || (!dw && j>=read_inputs)) begin
                                    operand_a[l][j]<=0;operand_b[l][j]<=0;
                                end else begin
                                    operand_a[l][j]<=dw?fm_a[l*8+:8]:fm_a[(read_channel+j)*8+:8];
                                    operand_b[l][j]<=weight_q[l*32+j*8+:8];
                                end
                            end
                    end
                    if(operand_valid) begin
                        for(l=0;l<16;l=l+1)
                            for(j=0;j<4;j=j+1)
                                product[l][j]<=$signed(operand_a[l][j])*$signed(operand_b[l][j]);
                    end
                    if(product_valid)
                        for(l=0;l<16;l=l+1)
                            mac_sum[l]<=reduce4(product[l][0],product[l][1],product[l][2],product[l][3]);
                    if(sum_valid) begin
                        if(kind==0) begin
                            for(l=0;l<16;l=l+1)
                                bank_accum[sum_bank][l]<=sum_first?
                                    bank_bias[sum_bank][l]+$signed(mac_sum[l]):
                                    bank_accum[sum_bank][l]+$signed(mac_sum[l]);
                        end else begin
                            for(l=0;l<16;l=l+1)
                                accum[l]<=accum[l]+$signed(mac_sum[l]);
                        end
                        valid_outputs=(cout-sum_oc<16)?cout-sum_oc:16;
                        semantic_mac_count<=semantic_mac_count+valid_outputs*sum_inputs;
                        if(sum_last && kind==3) begin lane_index<=0;state<=FC_LOAD;end
                    end
                    if(rq_merge_valid) begin
                        for(l=0;l<16;l=l+1)
                            rq_bias[l]<=make_round_bias(rq_merge_shift[l*6+:6],
                                rq_merge_negative[l]);
                        rq_product_shift<=rq_merge_shift;
                        rq_product_index<=rq_merge_index;
                        rq_product_oc<=rq_merge_oc;
                        rq_product_op_last<=rq_merge_op_last;
                        rq_product_relu<=rq_merge_relu;
                        rq_product_sequence<=rq_merge_sequence;
                    end
                    if(rq_product_valid) begin
                        for(l=0;l<16;l=l+1)
                            rq_value[l]<=round_biased(rq_product[l],rq_bias[l],
                                rq_product_shift[l*6+:6]);
                        rq_round_index<=rq_product_index;
                        rq_round_oc<=rq_product_oc;
                        rq_round_op_last<=rq_product_op_last;
                        rq_round_relu<=rq_product_relu;
                    end
                    if(rq_round_valid) begin
                        for(l=0;l<16;l=l+1)
                            result_vector[l*8+:8]<=rq_round_oc+l>=cout?0:
                                (rq_round_relu && rq_value[l]<0?0:saturate8(rq_value[l]));
                        rq_clamp_index<=rq_round_index;
                        rq_clamp_op_last<=rq_round_op_last;
                    end
                    if(rq_clamp_valid && rq_clamp_op_last) state<=OP_NEXT;

                    if(issue_read) begin
                        weight_cursor<=weight_cursor+1;
                        if(issue_last) begin
                            ic<=0;kx<=0;ky<=0;
                            active_bank<=~active_bank;
                            group_sequence<=group_sequence+1;
                            if(issue_op_last) issue_done<=1;
                            else if(oc+16<cout) begin
                                oc<=oc+16;vector_index<=vector_index+1;
                                quant_cursor<=quant_cursor+1;
                                group_weight_base<=weight_cursor+1;
                                weight_cursor<=weight_cursor+1;
                                tap_row_start<=current_tap_base;
                                tap_address<=current_tap_base;
                            end else begin
                                oc<=0;quant_cursor<=quant_base;
                                group_weight_base<=weight_base;weight_cursor<=weight_base;
                                if(ox+1<wout) begin
                                    ox<=ox+1;vector_index<=vector_index+1;
                                    source_center<=next_x_center;
                                    tap_row_start<=next_x_tap_base;
                                    tap_address<=next_x_tap_base;
                                end else if(oy+1<hout) begin
                                    ox<=0;oy<=oy+1;vector_index<=vector_index+1;
                                    source_row_center<=next_y_center;
                                    source_center<=next_y_center;
                                    tap_row_start<=next_y_tap_base;
                                    tap_address<=next_y_tap_base;
                                end
                            end
                        end else if(!dw && ic+4<cin) ic<=ic+4;
                        else begin
                            ic<=0;
                            if(kx+1<kernel) begin
                                kx<=kx+1;tap_address<=tap_address+pixel_stride;
                            end else begin
                                kx<=0;ky<=ky+1;
                                tap_row_start<=tap_row_start+row_stride;
                                tap_address<=tap_row_start+row_stride;
                            end
                        end
                    end
                end
                STORE: begin
                    if(kind==0) state<=NEXT;
                    else if(kind==1) begin
                        if(vector_index+1==output_words) state<=OP_NEXT;
                        else begin vector_index<=vector_index+1;lane_index<=0;state<=ADD_READ;end
                    end else if(kind==2) begin
                        if(oc+16>=cout) state<=OP_NEXT;
                        else begin oc<=oc+16;vector_index<=vector_index+1;state<=GAP_INIT;end
                    end
                end
                NEXT: begin
                    vector_index<=vector_index+1;
                    if(oc+16<cout) begin
                        oc<=oc+16;quant_cursor<=quant_cursor+1;
                        group_weight_base<=weight_cursor;state<=INIT;
                    end
                    else begin
                        oc<=0;
                        quant_cursor<=quant_base;
                        group_weight_base<=weight_base;
                        if(ox+1<wout) begin
                            ox<=ox+1;source_center<=source_center+(pixel_stride<<stride2);state<=INIT;
                        end
                        else begin
                            ox<=0;
                            if(oy+1<hout) begin
                                oy<=oy+1;
                                source_row_center<=source_row_center+(row_stride<<stride2);
                                source_center<=source_row_center+(row_stride<<stride2);
                                state<=INIT;
                            end
                            else state<=OP_NEXT;
                        end
                    end
                end
                ADD_READ: begin
                    residual_issue_chunk<=0;
                    residual_lut_valid<=0;
                    residual_sum_valid<=0;
                    state<=RESIDUAL_PIPE;
                end
                RESIDUAL_PIPE: begin
                    // Stage 1 registers the two independently indexed ROM
                    // results for four lanes in parallel.
                    if(residual_issue_chunk<4) begin
                        residual_lut_valid<=1;
                        residual_lut_chunk_q<=residual_issue_chunk[1:0];
                        residual_issue_chunk<=residual_issue_chunk+1'b1;
                    end else begin
                        residual_lut_valid<=0;
                    end

                    // Stage 2 adds sign-extended 9-bit branch values.  The
                    // 10-bit result covers the full possible [-284, 282] range.
                    if(residual_lut_valid) begin
                        residual_sum_q[0]<=$signed({residual_lut0_a_q[8],residual_lut0_a_q})+
                                              $signed({residual_lut0_b_q[8],residual_lut0_b_q});
                        residual_sum_q[1]<=$signed({residual_lut1_a_q[8],residual_lut1_a_q})+
                                              $signed({residual_lut1_b_q[8],residual_lut1_b_q});
                        residual_sum_q[2]<=$signed({residual_lut2_a_q[8],residual_lut2_a_q})+
                                              $signed({residual_lut2_b_q[8],residual_lut2_b_q});
                        residual_sum_q[3]<=$signed({residual_lut3_a_q[8],residual_lut3_a_q})+
                                              $signed({residual_lut3_b_q[8],residual_lut3_b_q});
                        residual_sum_valid<=1;
                        residual_sum_chunk_q<=residual_lut_chunk_q;
                    end else begin
                        residual_sum_valid<=0;
                    end

                    // Stage 3 independently clamps all four registered sums.
                    if(residual_sum_valid) begin
                        result_vector[({residual_sum_chunk_q,2'b00}+5'd0)*8+:8]<=saturate10(residual_sum_q[0]);
                        result_vector[({residual_sum_chunk_q,2'b00}+5'd1)*8+:8]<=saturate10(residual_sum_q[1]);
                        result_vector[({residual_sum_chunk_q,2'b00}+5'd2)*8+:8]<=saturate10(residual_sum_q[2]);
                        result_vector[({residual_sum_chunk_q,2'b00}+5'd3)*8+:8]<=saturate10(residual_sum_q[3]);
                    end

                    // The final clamp is committed before STORE can write the
                    // completed vector to feature memory on the next edge.
                    if(residual_issue_chunk==4 && !residual_lut_valid && residual_sum_valid)
                        state<=STORE;
                end
                GAP_INIT: begin
                    for(l=0;l<16;l=l+1) accum[l]<=0;
                    gap_pixel<=0;state<=GAP_READ;
                end
                GAP_READ: state<=GAP_ACC;
                GAP_ACC: begin
                    for(l=0;l<16;l=l+1) accum[l]<=accum[l]+$signed(fm_a[l*8+:8]);
                    if(gap_pixel==15) state<=GAP_ROUND;
                    else begin gap_pixel<=gap_pixel+1;state<=GAP_READ;end
                end
                GAP_ROUND: begin
                    for(l=0;l<16;l=l+1)
                        result_vector[l*8+:8]<=saturate8(round_shift({{32{accum[l][31]}},accum[l]},6'd4));
                    state<=STORE;
                end
                FC_LOAD: begin
                    logit_data_reg<=accum[0];
                    logit_index_reg<=0;logit_valid_reg<=1;
                    for(l=0;l<9;l=l+1) logit_queue[l]<=accum[l+1];
                    state<=FC_OUT;
                end
                FC_OUT: if(logit_ready) begin
                    if(logit_index_reg+1>=cout) begin
                        logit_valid_reg<=0;state<=OP_NEXT;
                    end else begin
                        logit_data_reg<=logit_queue[logit_index_reg];
                        logit_index_reg<=logit_index_reg+1;
                    end
                end
                OP_NEXT: begin
                    if(op_index==OP_COUNT-1) begin
                        state<=IDLE;input_ready<=0;done_valid<=1;busy<=0;start_ready<=0;
                    end
                    else begin op_index<=op_index+1;state<=DECODE;end
                end
                default: begin
                    error<=1;state<=IDLE;input_ready<=0;done_valid<=1;busy<=0;start_ready<=0;
                end
            endcase
        end
    end
endmodule

// One exact signed32 x signed32 RQ lane. The common operands, four partial
// products, balanced cross/base merge, and final product occupy separate
// registers so no DSP feeds another DSP combinationally.
module d4_rq_partial_multiplier_lane(
    input wire clk, rst_n, in_valid,
    input wire signed [31:0] a, b,
    output reg signed [63:0] product,
    output reg out_valid
);
    reg signed [31:0] a_common, b_common;
    reg common_valid, partial_valid;
    (* DONT_TOUCH = "TRUE" *) reg merge_valid;

    wire [16:0] a_lo17={1'b0,a_common[15:0]};
    wire [16:0] b_lo17={1'b0,b_common[15:0]};
    wire signed [16:0] a_hi17={a_common[31],a_common[31:16]};
    wire signed [16:0] b_hi17={b_common[31],b_common[31:16]};
    wire [31:0] p00_full=a_lo17*b_lo17;
    wire signed [31:0] p01_full=a_hi17*$signed(b_lo17);
    wire signed [31:0] p10_full=b_hi17*$signed(a_lo17);
    wire signed [31:0] p11_full=a_hi17*b_hi17;

    (* use_dsp = "yes" *) reg [31:0] p00_q;
    (* use_dsp = "yes" *) reg signed [32:0] p01_q, p10_q;
    (* use_dsp = "yes" *) reg signed [31:0] p11_q;
    reg signed [33:0] cross_q;
    reg signed [63:0] base_q;
    wire signed [63:0] cross_term={{30{cross_q[33]}},cross_q} <<< 16;

    always @(posedge clk) begin
        if(!rst_n) begin
            a_common<=0;b_common<=0;
            common_valid<=0;partial_valid<=0;merge_valid<=0;out_valid<=0;
            p00_q<=0;p01_q<=0;p10_q<=0;p11_q<=0;
            cross_q<=0;base_q<=0;product<=0;
        end else begin
            if(in_valid) begin
                a_common<=a;b_common<=b;
            end
            if(common_valid) begin
                p00_q<=p00_full;
                p01_q<={p01_full[31],p01_full};
                p10_q<={p10_full[31],p10_full};
                p11_q<=p11_full;
            end
            if(partial_valid) begin
                cross_q<=$signed({p01_q[32],p01_q})+
                    $signed({p10_q[32],p10_q});
                base_q<=$signed({p11_q,p00_q});
            end
            if(merge_valid)
                product<=base_q+cross_term;
            common_valid<=in_valid;
            partial_valid<=common_valid;
            merge_valid<=partial_valid;
            out_valid<=merge_valid;
        end
    end
endmodule
`default_nettype wire
