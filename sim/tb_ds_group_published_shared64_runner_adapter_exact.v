`timescale 1ns/1ps
`default_nettype none

/* DS1 exact value scoreboard for the scalar-memory bridge.  All source bytes,
 * DW taps, and PW weights are one, so the independent reference is the valid
 * 3x3 neighbour count followed by the bridge's fixed 1/2 requant scale. */
module tb_ds_group_published_shared64_runner_adapter_exact;
    reg clk=0; always #1 clk=~clk;
    reg rst_n=0, start_valid=0;
    wire start_ready;
    reg [31:0] input_base=32'h02000, output_base=0;
    reg [15:0] input_height=32, input_width=32, input_channels=16, output_channels=32;
    reg [7:0] stride=1, input_zero_point=0;
    reg signed [31:0] dw_output_zero_point=0, dw_activation_min=-128, dw_activation_max=127;
    reg signed [31:0] pw_output_zero_point=0, pw_activation_min=-128, pw_activation_max=127;
    reg config_write_en=0; reg [3:0] config_target=0; reg [15:0] config_index=0; reg [31:0] config_data=0;
    wire [6:0] config_dw_channel = config_index / 9;
    wire [3:0] config_dw_tap = config_index % 9;
    wire source_word_en; wire [14:0] source_word_addr; reg source_word_ready=1;
    reg source_word_valid=0; reg [31:0] source_word_data=0;
    wire output_word_en; wire [15:0] output_word_addr; wire [31:0] output_word_data; wire [3:0] output_word_be;
    reg output_word_ready=1; wire busy,done,error;
    wire [31:0] perf_cycles,perf_dw,perf_desc,perf_tokens,perf_out,perf_jobs,perf_beats;
    wire [31:0] config_accept_count,config_phase_count;

    ds_group_published_shared64_runner_adapter dut (
        .clk(clk),.rst_n(rst_n),.start_valid(start_valid),.start_ready(start_ready),
        .input_base_addr(input_base),.output_base_addr(output_base),
        .input_height(input_height),.input_width(input_width),.input_channels(input_channels),
        .output_channels(output_channels),.stride(stride),.input_zero_point(input_zero_point),
        .dw_output_zero_point(dw_output_zero_point),.dw_activation_min(dw_activation_min),
        .dw_activation_max(dw_activation_max),.pw_output_zero_point(pw_output_zero_point),
        .pw_activation_min(pw_activation_min),.pw_activation_max(pw_activation_max),
        .config_write_en(config_write_en),.config_target(config_target),.config_index(config_index),
        .config_data(config_data),.config_word_write_en(1'b0),.config_word_target(4'd0),
        .config_dw_channel(config_dw_channel),.config_dw_tap(config_dw_tap),
        .config_word_index(16'd0),.config_word_data(32'd0),.config_word_be(4'd0),
        .source_word_en(source_word_en),.source_word_addr(source_word_addr),
        .source_word_ready(source_word_ready),.source_word_valid(source_word_valid),.source_word_data(source_word_data),
        .output_word_en(output_word_en),.output_word_addr(output_word_addr),.output_word_data(output_word_data),
        .output_word_be(output_word_be),.output_word_ready(output_word_ready),.busy(busy),.done(done),.error(error),
        .perf_cycles(perf_cycles),.perf_dw_writes(perf_dw),.perf_descriptors(perf_desc),
        .perf_pw_tokens(perf_tokens),.perf_output_writes(perf_out),.perf_jobs(perf_jobs),
        .perf_stream_beats(perf_beats),.config_accept_count(config_accept_count),
        .config_phase_count(config_phase_count),.config_word_accept_count(),
        .config_scalar_write_count());

    /* One-cycle source response, with deterministic request backpressure. */
    reg pending_valid=0; reg [31:0] pending_data=0; integer source_cycle=0;
    always @(posedge clk) begin
        if (!rst_n) begin pending_valid<=0; source_word_valid<=0; source_word_data<=0; source_cycle<=0; end
        else begin
            source_word_valid<=pending_valid; source_word_data<=pending_data;
            pending_valid<=source_word_en && source_word_ready; pending_data<=32'h01010101;
            source_cycle<=source_cycle+1;
        end
    end
    reg [31:0] bp=32'h7a31_55c9;
    always @(negedge clk) begin
        if (!rst_n) begin output_word_ready<=1; source_word_ready<=1; bp<=32'h7a31_55c9; end
        else begin
            output_word_ready<=!(bp[2:0]==3'b101 || bp[8:6]==3'b011);
            source_word_ready<=!(bp[14:12]==3'b110);
            bp<={bp[30:0],bp[31]^bp[21]^bp[1]^bp[0]};
        end
    end

    integer errors=0, result_checks=0, internal_result_checks=0, source_checks=0, output_stalls=0;
    integer ch,tap,o,k,l, expected, got, row_idx,col_idx,py,px,dy,dx,neighbours;
    task cfg; input [3:0] t; input [15:0] i; input [31:0] d;
        begin @(negedge clk); config_target=t; config_index=i; config_data=d; config_write_en=1;
              @(posedge clk); @(negedge clk); config_write_en=0; end
    endtask
    function integer neighbour_count; input integer pix; integer yy,xx,dr,dc; begin
        /* sweep_result_pixel is the producer's global NHWC/raster pixel
         * index.  The internal scratch ownership is macro-major, but the
         * published result tag is converted back to this linear space. */
        yy=pix>>5; xx=pix&31;
        neighbour_count=0;
        for (dr=-1;dr<=1;dr=dr+1) for (dc=-1;dc<=1;dc=dc+1)
            if ((yy+dr>=0)&&(yy+dr<32)&&(xx+dc>=0)&&(xx+dc<32)) neighbour_count=neighbour_count+1;
    end endfunction

    always @(negedge clk) begin
        if (rst_n && output_word_en) begin
            if (!output_word_ready) output_stalls=output_stalls+1;
            else begin
                if (output_word_be !== 4'hf) begin $display("BAD_MASK %h",output_word_be); errors=errors+1; end
                /* The producer's local Q31 requant emits a two-count for a
                 * unit byte before the shared PW Q31 stage; with sixteen
                 * unit Cin channels this is neighbour_count*16. */
                expected=neighbour_count(dut.sweep_result_pixel)*16;
                if (expected > 127) expected=127;
                for (l=0;l<4;l=l+1) begin
                    if ($signed(output_word_data[l*8 +: 8]) !== expected) begin
                        if (errors<8) $display("MISMATCH pixel=%0d lane=%0d got=%0d exp=%0d",
                          dut.sweep_result_pixel,l,$signed(output_word_data[l*8 +: 8]),expected);
                        errors=errors+1;
                    end
                    result_checks=result_checks+1;
                end
            end
        end
        if (rst_n && source_word_en && source_word_ready) source_checks=source_checks+1;
    end
    /* Check the exact set of internal result handshakes as well; sampling the
     * registered external pins on an opposite edge can miss a final held
     * word when done and sink-ready change in the same delta cycle. */
    always @(posedge clk) begin
        if (rst_n && dut.u_sweep.result_fire) begin
            expected=neighbour_count(dut.sweep_result_pixel)*16;
            if (expected > 127) expected=127;
            for (l=0;l<4;l=l+1) begin
                if ($signed(dut.sweep_result_data[l*8 +: 8]) !== expected) begin
                    if (errors<8) $display("INTERNAL_MISMATCH pixel=%0d lane=%0d got=%0d exp=%0d",
                        dut.sweep_result_pixel,l,
                        $signed(dut.sweep_result_data[l*8 +: 8]),expected);
                    errors=errors+1;
                end
                internal_result_checks=internal_result_checks+1;
            end
        end
    end

    initial begin
        repeat(5) @(posedge clk); rst_n=1;
        for (ch=0;ch<16;ch=ch+1) for (tap=0;tap<9;tap=tap+1) cfg(1,ch*9+tap,1);
        for (ch=0;ch<16;ch=ch+1) begin cfg(2,ch,0); cfg(3,ch,32'h7fff_ffff); cfg(4,ch,0); end
        for (o=0;o<32;o=o+1) for (k=0;k<16;k=k+1) cfg(5,o*128+k,1);
        for (o=0;o<32;o=o+1) begin cfg(6,o,0); cfg(7,o,32'h7fff_ffff); cfg(8,o,0); end
        if (config_accept_count !== 800) begin $display("BAD_CONFIG_COUNT %0d",config_accept_count); errors=errors+1; end
        @(negedge clk); start_valid=1;
        while (!start_ready) @(posedge clk);
        @(posedge clk); @(negedge clk); start_valid=0;
        while (!done) begin @(posedge clk); if (perf_cycles>2000000) $fatal(1,"WATCHDOG"); end
        if (error) errors=errors+1;
        if (perf_dw!==4096 || perf_desc!==256 || perf_tokens!==8192 || perf_out!==8192 ||
            perf_jobs!==32 || perf_beats!==4096 || source_checks==0)
            errors=errors+1;
        if (internal_result_checks!==32768) errors=errors+1;
        if (errors==0) $display("PASS adapter DS1 exact cycles=%0d dw=%0d desc=%0d pw=%0d out=%0d source=%0d stalls=%0d cfg=%0d",
          perf_cycles,perf_dw,perf_desc,perf_tokens,perf_out,source_checks,output_stalls,config_accept_count);
        else begin $display("FAIL adapter DS1 exact errors=%0d checks=%0d cycles=%0d cfg=%0d",errors,result_checks,perf_cycles,config_accept_count); $fatal(1); end
        $finish;
    end
endmodule
`default_nettype wire
