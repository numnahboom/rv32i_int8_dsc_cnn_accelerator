`timescale 1ns/1ps
`default_nettype none

module tb_d4_halo_geometry;
    reg clk=1'b0;
    reg rst_n=1'b0;
    reg start_valid=1'b0;
    wire start_ready;
    reg input_valid=1'b0;
    wire input_ready;
    reg [127:0] input_data=128'd0;
    wire logit_valid;
    reg logit_ready=1'b0;
    wire [3:0] logit_index;
    wire signed [31:0] logit_acc;
    wire done_valid;
    reg done_ready=1'b0;
    wire busy, error;
    wire [31:0] cycle_count, semantic_mac_count;
    wire trace_valid;
    wire [5:0] trace_op;
    wire [10:0] trace_index;
    wire [127:0] trace_data;

    reg [31:0] frozen_geometry [0:31];
    integer op_i, oy_i, ox_i, ky_i, kx_i;
    integer hin_i, win_i, hout_i, wout_i, kernel_i, stride_i;
    integer ref_y, ref_x, expected_halo;
    integer checked_cases=0, expected_halos=0;

    d4_fullnet_top #(
        .DATA_DIR("build/reports/d4_fullnet_halo_edges_20261018/vectors/sample_0")
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .input_valid(input_valid), .input_ready(input_ready), .input_data(input_data),
        .logit_valid(logit_valid), .logit_ready(logit_ready),
        .logit_index(logit_index), .logit_acc(logit_acc),
        .done_valid(done_valid), .done_ready(done_ready),
        .busy(busy), .error(error),
        .cycle_count(cycle_count), .semantic_mac_count(semantic_mac_count),
        .trace_valid(trace_valid), .trace_op(trace_op),
        .trace_index(trace_index), .trace_data(trace_data)
    );

    initial begin
        $readmemh("build/reports/d4_fullnet_halo_edges_20261018/frozen_geometry.mem",
                  frozen_geometry);
        #1;
        for (op_i=0; op_i<32; op_i=op_i+1) begin
            hin_i=frozen_geometry[op_i][27:22];
            win_i=frozen_geometry[op_i][21:16];
            hout_i=frozen_geometry[op_i][15:10];
            wout_i=frozen_geometry[op_i][9:4];
            kernel_i=frozen_geometry[op_i][3:2];
            stride_i=frozen_geometry[op_i][1:0];
            dut.kind=2'd0;
            dut.hin=hin_i[5:0];
            dut.win=win_i[5:0];
            dut.hout=hout_i[5:0];
            dut.wout=wout_i[5:0];
            dut.kernel=kernel_i[1:0];
            dut.stride2=(stride_i==2);
            for (oy_i=0; oy_i<hout_i; oy_i=oy_i+1) begin
                for (ox_i=0; ox_i<wout_i; ox_i=ox_i+1) begin
                    for (ky_i=0; ky_i<kernel_i; ky_i=ky_i+1) begin
                        for (kx_i=0; kx_i<kernel_i; kx_i=kx_i+1) begin
                            dut.oy=oy_i[5:0];
                            dut.ox=ox_i[5:0];
                            dut.ky=ky_i[1:0];
                            dut.kx=kx_i[1:0];
                            #1;
                            ref_y=oy_i*stride_i+ky_i-((kernel_i==3)?1:0);
                            ref_x=ox_i*stride_i+kx_i-((kernel_i==3)?1:0);
                            expected_halo=(ref_y<0 || ref_x<0 ||
                                           ref_y>=hin_i || ref_x>=win_i);
                            if (dut.halo !== (expected_halo!=0))
                                $fatal(1,"HALO_MISMATCH op=%0d h=%0d w=%0d k=%0d s=%0d oy=%0d ox=%0d ky=%0d kx=%0d ref=(%0d,%0d) expected=%0d actual=%0b",
                                       op_i,hin_i,win_i,kernel_i,stride_i,
                                       oy_i,ox_i,ky_i,kx_i,ref_y,ref_x,
                                       expected_halo,dut.halo);
                            checked_cases=checked_cases+1;
                            expected_halos=expected_halos+expected_halo;
                        end
                    end
                end
            end
        end

        // The FC tap is kernel one at the zero spatial coordinate.
        dut.kind=2'd3;
        dut.hin=6'd1;
        dut.win=6'd1;
        dut.hout=6'd1;
        dut.wout=6'd1;
        dut.kernel=2'd1;
        dut.stride2=1'b0;
        dut.oy=6'd0;
        dut.ox=6'd0;
        dut.ky=2'd0;
        dut.kx=2'd0;
        #1;
        if (dut.halo !== 1'b0)
            $fatal(1,"FC_KERNEL1_ZERO_COORDINATE_HALO actual=%0b",dut.halo);
        if (checked_cases!=33120 || expected_halos!=1621)
            $fatal(1,"HALO_GEOMETRY_COVERAGE cases=%0d halos=%0d",
                   checked_cases,expected_halos);
        $display("D4_HALO_GEOMETRY_PASS cases=%0d halos=%0d fc_halo=0",
                 checked_cases,expected_halos);
        $finish;
    end
endmodule

`default_nettype wire
