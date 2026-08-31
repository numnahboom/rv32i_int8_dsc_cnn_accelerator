`timescale 1ns/1ps
`default_nettype none

module tb_feature_tile_vector16_bank;
    localparam integer DS_BYTES = 10*10*48;
    localparam integer DS_BAW = 9;
    localparam integer DS_AW = 13;
    localparam integer ST_BYTES = 10*10*3;
    localparam integer ST_BAW = 5;
    localparam integer ST_AW = 9;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg ds_wr_valid, ds_rd_valid, ds_rd_use;
    wire ds_wr_ready, ds_wr_drain_ready, ds_rd_ready, ds_resp_valid;
    reg [DS_AW-1:0] ds_wr_base;
    reg [31:0] ds_wr_data;
    reg [3:0] ds_wr_be;
    reg [6:0] ds_pixel;
    reg [1:0] ds_group;
    reg [15:0] ds_mask;
    reg [7:0] ds_tag;
    reg [16*DS_BAW-1:0] ds_lane_addr;
    reg ds_resp_ready;
    wire [127:0] ds_data;
    wire [15:0] ds_resp_mask;
    wire [7:0] ds_resp_tag;

    reg st_wr_valid, st_rd_valid, st_rd_use;
    wire st_wr_ready, st_wr_drain_ready, st_rd_ready, st_resp_valid;
    reg [ST_AW-1:0] st_wr_base;
    reg [31:0] st_wr_data;
    reg [3:0] st_wr_be;
    reg [6:0] st_pixel;
    reg st_group;
    reg [15:0] st_mask;
    reg [7:0] st_tag;
    reg [16*ST_BAW-1:0] st_lane_addr;
    reg st_resp_ready;
    wire [127:0] st_data;
    wire [15:0] st_resp_mask;
    wire [7:0] st_resp_tag;

    feature_tile_vector16_bank #(.MAX_CHANNELS(48), .MAX_IN_H(10), .MAX_IN_W(10)) u_ds (
        .clk(clk), .rst_n(rst_n), .wr_valid(ds_wr_valid), .wr_ready(ds_wr_ready), .wr_drain_ready(ds_wr_drain_ready),
        .wr_base_byte_addr(ds_wr_base), .wr_data(ds_wr_data), .wr_byte_en(ds_wr_be),
        .rd_req_valid(ds_rd_valid), .rd_req_ready(ds_rd_ready), .rd_pixel_idx(ds_pixel),
        .rd_channel_group(ds_group), .rd_lane_mask(ds_mask), .rd_tag(ds_tag),
        .rd_use_lane_addr(ds_rd_use), .rd_lane_addr(ds_lane_addr),
        .rd_resp_valid(ds_resp_valid), .rd_resp_ready(ds_resp_ready),
        .rd_data_vector(ds_data), .rd_resp_lane_mask(ds_resp_mask), .rd_resp_tag(ds_resp_tag)
    );
    feature_tile_vector16_bank #(.MAX_CHANNELS(3), .MAX_IN_H(10), .MAX_IN_W(10)) u_st (
        .clk(clk), .rst_n(rst_n), .wr_valid(st_wr_valid), .wr_ready(st_wr_ready), .wr_drain_ready(st_wr_drain_ready),
        .wr_base_byte_addr(st_wr_base), .wr_data(st_wr_data), .wr_byte_en(st_wr_be),
        .rd_req_valid(st_rd_valid), .rd_req_ready(st_rd_ready), .rd_pixel_idx(st_pixel),
        .rd_channel_group(st_group), .rd_lane_mask(st_mask), .rd_tag(st_tag),
        .rd_use_lane_addr(st_rd_use), .rd_lane_addr(st_lane_addr),
        .rd_resp_valid(st_resp_valid), .rd_resp_ready(st_resp_ready),
        .rd_data_vector(st_data), .rd_resp_lane_mask(st_resp_mask), .rd_resp_tag(st_resp_tag)
    );

    reg [7:0] ds_ref [0:DS_BYTES-1];
    reg [7:0] st_ref [0:ST_BYTES-1];
    integer errors = 0;
    integer checks = 0;
    integer i, j, base_i, lin_i, got_i;
    reg [127:0] expected_data;

    function automatic [7:0] pattern;
        input integer n;
        begin pattern = (n*37 + 8'h5b) & 8'hff; end
    endfunction

    task automatic ds_write_word;
        input integer base;
        input [31:0] data;
        input [3:0] be;
        begin
            ds_wr_base = base; ds_wr_data = data; ds_wr_be = be; ds_wr_valid = 1'b1;
            while (!ds_wr_ready) @(posedge clk);
            @(posedge clk); #1 ds_wr_valid = 1'b0;
            for (j = 0; j < 4; j = j + 1)
                if (be[j] && (base+j < DS_BYTES)) ds_ref[base+j] = data[(j*8) +: 8];
        end
    endtask

    task automatic st_write_word;
        input integer base;
        input [31:0] data;
        input [3:0] be;
        begin
            st_wr_base = base; st_wr_data = data; st_wr_be = be; st_wr_valid = 1'b1;
            while (!st_wr_ready) @(posedge clk);
            @(posedge clk); #1 st_wr_valid = 1'b0;
            for (j = 0; j < 4; j = j + 1)
                if (be[j] && (base+j < ST_BYTES)) st_ref[base+j] = data[(j*8) +: 8];
        end
    endtask

    task automatic ds_read_check;
        input integer pixel;
        input integer group;
        input [15:0] mask;
        input [7:0] tag;
        input integer hold_cycles;
        begin
            ds_pixel = pixel; ds_group = group; ds_mask = mask; ds_tag = tag;
            ds_rd_use = 1'b0; ds_rd_valid = 1'b1; ds_resp_ready = 1'b0;
            while (!ds_rd_ready) @(posedge clk);
            @(posedge clk); #1 ds_rd_valid = 1'b0;
            while (!ds_resp_valid) @(posedge clk);
            expected_data = 128'd0;
            for (i = 0; i < 16; i = i + 1) begin
                lin_i = pixel*48 + group*16 + i;
                if (mask[i] && lin_i < DS_BYTES) expected_data[(i*8) +: 8] = ds_ref[lin_i];
            end
            for (i = 0; i < hold_cycles; i = i + 1) begin
                @(posedge clk); #1;
                if (!ds_resp_valid || ds_data !== expected_data || ds_resp_mask !== mask || ds_resp_tag !== tag) begin
                    errors = errors + 1;
                    $display("DS hold mismatch pixel=%0d group=%0d got=%h exp=%h mask=%h/%h tag=%h/%h valid=%b", pixel, group, ds_data, expected_data, ds_resp_mask, mask, ds_resp_tag, tag, ds_resp_valid);
                end
            end
            if (ds_data !== expected_data || ds_resp_mask !== mask || ds_resp_tag !== tag) begin
                errors = errors + 1;
                $display("DS mismatch pixel=%0d group=%0d got=%h exp=%h mask=%h/%h tag=%h/%h", pixel, group, ds_data, expected_data, ds_resp_mask, mask, ds_resp_tag, tag);
            end
            checks = checks + 1;
            ds_resp_ready = 1'b1; @(posedge clk); #1; ds_resp_ready = 1'b0;
        end
    endtask

    task automatic st_read_check;
        input integer pixel;
        input [15:0] mask;
        input [7:0] tag;
        begin
            st_pixel = pixel; st_group = 1'b0; st_mask = mask; st_tag = tag;
            st_rd_use = 1'b0; st_rd_valid = 1'b1; st_resp_ready = 1'b0;
            while (!st_rd_ready) @(posedge clk);
            @(posedge clk); #1 st_rd_valid = 1'b0;
            while (!st_resp_valid) @(posedge clk);
            expected_data = 128'd0;
            for (i = 0; i < 16; i = i + 1)
                if (mask[i] && pixel*3+i < ST_BYTES) expected_data[(i*8) +: 8] = st_ref[pixel*3+i];
            if (st_data !== expected_data || st_resp_mask !== mask || st_resp_tag !== tag) begin
                errors = errors + 1;
                $display("ST mismatch pixel=%0d got=%h exp=%h mask=%h/%h tag=%h/%h", pixel, st_data, expected_data, st_resp_mask, mask, st_resp_tag, tag);
            end
            checks = checks + 1;
            st_resp_ready = 1'b1; @(posedge clk); #1; st_resp_ready = 1'b0;
        end
    endtask

    task automatic ds_custom_read_check;
        input [16*DS_BAW-1:0] addrs;
        input [15:0] mask;
        input [7:0] tag;
        begin
            ds_lane_addr = addrs; ds_rd_use = 1'b1; ds_mask = mask; ds_tag = tag;
            ds_rd_valid = 1'b1; ds_resp_ready = 1'b1;
            while (!ds_rd_ready) @(posedge clk);
            @(posedge clk); #1 ds_rd_valid = 1'b0;
            while (!ds_resp_valid) @(posedge clk);
            expected_data = 128'd0;
            for (i = 0; i < 16; i = i + 1) begin
                lin_i = (addrs[(i*DS_BAW) +: DS_BAW] / 3) * 48 +
                        (addrs[(i*DS_BAW) +: DS_BAW] % 3) * 16 + i;
                if (mask[i]) expected_data[(i*8) +: 8] = ds_ref[lin_i];
            end
            if (ds_data !== expected_data || ds_resp_mask !== mask || ds_resp_tag !== tag) errors = errors + 1;
            checks = checks + 1;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        ds_wr_valid=0; ds_rd_valid=0; ds_rd_use=0; ds_resp_ready=0; ds_wr_base=0; ds_wr_data=0; ds_wr_be=0;
        ds_pixel=0; ds_group=0; ds_mask=0; ds_tag=0; ds_lane_addr=0;
        st_wr_valid=0; st_rd_valid=0; st_rd_use=0; st_resp_ready=0; st_wr_base=0; st_wr_data=0; st_wr_be=0;
        st_pixel=0; st_group=0; st_mask=0; st_tag=0; st_lane_addr=0;
        for (i=0; i<DS_BYTES; i=i+1) ds_ref[i]=0;
        for (i=0; i<ST_BYTES; i=i+1) st_ref[i]=0;
        repeat (3) @(posedge clk); rst_n=1'b1;

        /* Fill every logical byte with native words, then exercise unaligned
         * and masked scatters (including a bank-boundary crossing). */
        for (base_i=0; base_i<DS_BYTES; base_i=base_i+4)
            ds_write_word(base_i, {pattern(base_i+3),pattern(base_i+2),pattern(base_i+1),pattern(base_i)}, 4'hf);
        ds_write_word(1, 32'hd4c3b2a1, 4'b1111);
        ds_write_word(15, 32'h44332211, 4'b1011);
        ds_write_word(DS_BYTES-3, 32'h88776655, 4'b0111);
        for (base_i=0; base_i<ST_BYTES; base_i=base_i+4)
            st_write_word(base_i, {pattern(base_i+3),pattern(base_i+2),pattern(base_i+1),pattern(base_i)}, 4'hf);
        st_write_word(1, 32'h78563412, 4'b1111);

        ds_read_check(0, 0, 16'hffff, 8'h10, 2);
        ds_read_check(1, 1, 16'hffff, 8'h11, 1);
        ds_read_check(7, 2, 16'h00ff, 8'h12, 3);
        ds_read_check(99, 2, 16'h0fff, 8'h13, 0);
        ds_lane_addr = 0;
        for (i=0; i<16; i=i+1) ds_lane_addr[(i*DS_BAW) +: DS_BAW] = (i+3);
        ds_custom_read_check(ds_lane_addr, 16'hf0f3, 8'h21);

        /* A request accepted alongside a write must observe the new bytes. */
        ds_pixel=2; ds_group=0; ds_mask=16'hffff; ds_tag=8'he1; ds_rd_use=0;
        ds_wr_base=2*48+4; ds_wr_data=32'hcafebabe; ds_wr_be=4'hf;
        ds_wr_valid=1; ds_rd_valid=1; ds_resp_ready=1;
        while (!ds_rd_ready || !ds_wr_ready) @(posedge clk);
        @(posedge clk); #1 ds_wr_valid=0; ds_rd_valid=0;
        ds_ref[100]=8'hbe; ds_ref[101]=8'hba; ds_ref[102]=8'hfe; ds_ref[103]=8'hca;
        while (!ds_resp_valid) @(posedge clk);
        expected_data=128'd0;
        for (i=0;i<16;i=i+1) expected_data[(i*8)+:8]=ds_ref[96+i];
        if (ds_data !== expected_data) begin errors=errors+1; $display("collision mismatch got=%h exp=%h", ds_data, expected_data); end checks=checks+1;
        @(posedge clk); #1;

        st_read_check(0, 16'h0007, 8'h31);
        st_read_check(33, 16'h0007, 8'h32);

        if (errors != 0) $fatal(1, "feature_tile_vector16_bank FAIL errors=%0d checks=%0d", errors, checks);
        $display("feature_tile_vector16_bank PASS checks=%0d", checks);
        $finish;
    end
endmodule

`default_nettype wire
