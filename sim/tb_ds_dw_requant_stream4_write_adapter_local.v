`timescale 1ns/1ps
`default_nettype none

/* Differential protocol test for the four-local-island DW write adapter. */
module tb_ds_dw_requant_stream4_write_adapter_local;
    reg clk=0, rst_n=0; always #5 clk=~clk;
    reg valid_in=0; wire ready_in;
    reg [5:0] pixel_idx_in=0; reg [15:0] lane_mask_in=0;
    reg signed [511:0] raw_vec_in=0, multiplier_vec_in=0;
    reg [95:0] shift_vec_in=0;
    reg signed [31:0] output_zero_point=0, activation_min=-128, activation_max=127;
    reg ready_out=1; wire valid_out; wire [5:0] pixel_idx_out;
    wire [1:0] lane_base_out; wire [31:0] data_out; wire [3:0] lane_mask_out;
    wire busy;

    ds_dw_requant_stream4_write_adapter_local dut (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in), .ready_in(ready_in),
        .pixel_idx_in(pixel_idx_in), .lane_mask_in(lane_mask_in),
        .raw_vec_in(raw_vec_in), .multiplier_vec_in(multiplier_vec_in),
        .shift_vec_in(shift_vec_in), .output_zero_point(output_zero_point),
        .activation_min(activation_min), .activation_max(activation_max),
        .valid_out(valid_out), .ready_out(ready_out),
        .pixel_idx_out(pixel_idx_out), .lane_base_out(lane_base_out),
        .data_out(data_out), .lane_mask_out(lane_mask_out), .busy(busy)
    );

    wire signed [63:0] ref_product [0:15];
    wire signed [7:0] ref_data [0:15];
    genvar g;
    generate for (g=0; g<16; g=g+1) begin : gen_ref
        assign ref_product[g] = $signed({{32{raw_vec_in[(g*32)+31]}},
                                          raw_vec_in[(g*32) +: 32]}) *
                                $signed({{32{multiplier_vec_in[(g*32)+31]}},
                                          multiplier_vec_in[(g*32) +: 32]});
        requant_activation_core u_ref (
            .product_int64(ref_product[g]),
            .shift(shift_vec_in[(g*6) +: 6]),
            .output_zero_point_int32(output_zero_point),
            .activation_min_int32(activation_min),
            .activation_max_int32(activation_max),
            .output_int8(ref_data[g])
        );
    end endgenerate

    localparam integer BUNDLES=24;
    reg signed [511:0] raw_cases [0:BUNDLES-1];
    reg signed [511:0] mul_cases [0:BUNDLES-1];
    reg [95:0] shift_cases [0:BUNDLES-1];
    reg [15:0] mask_cases [0:BUNDLES-1];
    reg [5:0] pixel_cases [0:BUNDLES-1];
    reg signed [31:0] zp_cases [0:BUNDLES-1];
    reg signed [31:0] min_cases [0:BUNDLES-1];
    reg signed [31:0] max_cases [0:BUNDLES-1];
    reg signed [31:0] exp_data [0:BUNDLES*4-1];
    reg [5:0] exp_pixel [0:BUNDLES*4-1];
    reg [1:0] exp_base [0:BUNDLES*4-1];
    reg [3:0] exp_mask [0:BUNDLES*4-1];
    integer accepted, produced, errors, cycles, seed, b, l, n;
    reg held; reg [5:0] held_pixel; reg [1:0] held_base;
    reg [3:0] held_mask; reg [31:0] held_data;

    always @(posedge clk) begin
        if (rst_n) begin
            cycles = cycles + 1;
            if (held) begin
                if (!valid_out || pixel_idx_out!==held_pixel ||
                    lane_base_out!==held_base || lane_mask_out!==held_mask ||
                    data_out!==held_data) errors = errors + 1;
                if (ready_out) held = 0;
            end
            if (valid_out && !ready_out) begin
                held=1; held_pixel=pixel_idx_out; held_base=lane_base_out;
                held_mask=lane_mask_out; held_data=data_out;
            end
            if (valid_out && ready_out) begin
                if (produced >= accepted || pixel_idx_out!==exp_pixel[produced] ||
                    lane_base_out!==exp_base[produced] ||
                    lane_mask_out!==exp_mask[produced] ||
                    data_out!==exp_data[produced]) begin
                    $display("LOCAL_MISMATCH n=%0d got pix=%0d base=%0d mask=%h data=%h exp pix=%0d base=%0d mask=%h data=%h",
                             produced,pixel_idx_out,lane_base_out,lane_mask_out,data_out,
                             exp_pixel[produced],exp_base[produced],exp_mask[produced],exp_data[produced]);
                    errors=errors+1;
                end
                produced=produced+1;
            end
        end
    end

    always @(negedge clk) begin
        if (!rst_n) ready_out <= 1;
        else ready_out <= ((cycles % 13)==2 || (cycles % 13)==3 ||
                           (cycles % 13)==8) ? 0 : 1;
    end

    task drive_bundle; input integer bi; integer q; begin
        @(negedge clk); raw_vec_in=raw_cases[bi]; multiplier_vec_in=mul_cases[bi];
        shift_vec_in=shift_cases[bi]; lane_mask_in=mask_cases[bi];
        pixel_idx_in=pixel_cases[bi]; output_zero_point=zp_cases[bi];
        activation_min=min_cases[bi]; activation_max=max_cases[bi]; valid_in=1;
        while (!ready_in) @(posedge clk);
        for (q=0;q<4;q=q+1) begin
            exp_data[accepted+q] = {ref_data[q*4+3],ref_data[q*4+2],
                                    ref_data[q*4+1],ref_data[q*4+0]};
            exp_pixel[accepted+q] = pixel_idx_in;
            exp_base[accepted+q] = q[1:0];
            exp_mask[accepted+q] = lane_mask_in[(q*4) +: 4];
        end
        accepted=accepted+4;
        @(negedge clk); valid_in=0;
    end endtask

    initial begin
        errors=0; accepted=0; produced=0; cycles=0; seed=32'h61a5_2026; held=0;
        for (b=0;b<BUNDLES;b=b+1) begin
            raw_cases[b]=0; mul_cases[b]=0; shift_cases[b]=0;
            mask_cases[b]=$urandom(seed); pixel_cases[b]=b*3;
            zp_cases[b]=(b*19)-200; min_cases[b]=-128+(b%23);
            max_cases[b]=min_cases[b]+40+(b%61); if (max_cases[b]>127) max_cases[b]=127;
            for (l=0;l<16;l=l+1) begin
                raw_cases[b][l*32 +: 32] = ($urandom(seed)%2000001)-1000000;
                mul_cases[b][l*32 +: 32] = ($urandom(seed)%1800000001)-900000000;
                shift_cases[b][l*6 +: 6] = (b*7+l*3)&63;
            end
            if (b==0) begin
                mask_cases[b]=16'hffff; raw_cases[b]=0; mul_cases[b]=0;
                zp_cases[b]=0; min_cases[b]=-128; max_cases[b]=127;
            end
            if (b==1) begin mask_cases[b]=16'h8001; raw_cases[b][31:0]=32'sh7fffffff; end
        end
        repeat(5) @(posedge clk); rst_n=1;
        for (b=0;b<BUNDLES;b=b+1) drive_bundle(b);
        while (produced < BUNDLES*4 && cycles < 10000) @(posedge clk);
        if (produced != BUNDLES*4 || errors != 0) begin
            $display("FAIL local adapter accepted=%0d produced=%0d errors=%0d cycles=%0d",
                     accepted,produced,errors,cycles); $fatal(1);
        end
        $display("PASS tb_ds_dw_requant_stream4_write_adapter_local bundles=%0d beats=%0d cycles=%0d",
                 BUNDLES,produced,cycles); $finish;
    end
endmodule
`default_nettype wire
