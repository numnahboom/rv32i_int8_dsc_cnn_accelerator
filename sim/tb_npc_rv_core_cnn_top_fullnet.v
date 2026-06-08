`timescale 1ns/1ps
`default_nettype none

module tb_npc_rv_core_cnn_top_fullnet;
    localparam ROM_WORDS = 262144;
    localparam RAM_WORDS = 262144;
    localparam MAX_LOGITS = 10;
    localparam TIMEOUT_CYCLES = 50000000;

    localparam SL_BYTE  = 3'b000;
    localparam SL_HALF  = 3'b001;
    localparam SL_WORD  = 3'b010;
    localparam L_BYTE_U = 3'b100;
    localparam L_HALF_U = 3'b101;

    reg clk;
    reg rst;

    wire [31:0] inst_addr;
    wire [31:0] inst;
    wire [31:0] cpu_mem_addr;
    wire [31:0] cpu_mem_wdata;
    wire cpu_mem_wen;
    wire [2:0] cpu_mem_width;
    reg [31:0] cpu_mem_rdata;

    wire cpu_cnn_cmd_valid;
    wire [2:0] cpu_cnn_cmd_funct3;
    wire [31:0] cpu_cnn_cmd_rs1;
    wire [31:0] cpu_cnn_cmd_rs2;
    wire [31:0] cpu_cnn_cmd_rdata;

    wire bridge_acc_cmd_valid;
    wire [1:0] bridge_acc_cmd;
    wire [31:0] bridge_acc_desc_base;
    wire [31:0] bridge_acc_layer_num;
    wire acc_cmd_ready;
    wire [31:0] acc_status;

    wire mem_req_valid;
    wire mem_req_write;
    wire [31:0] mem_req_addr;
    wire [31:0] mem_req_wdata;
    wire mem_req_ready;
    reg mem_resp_valid;
    reg [31:0] mem_resp_rdata;

    reg [31:0] rom [0:ROM_WORDS-1];
    reg [31:0] ram [0:RAM_WORDS-1];
    reg [7:0] expected_logits [0:MAX_LOGITS-1];
    reg [7:0] captured_logits [0:MAX_LOGITS-1];
    reg [31:0] expected_argmax_mem [0:0];
    reg [8*256-1:0] expected_logits_path;
    reg [8*256-1:0] expected_argmax_path;

    integer i;
    integer timeout;
    integer error_count;
    integer start_count;
    integer stat_count;
    integer cnn_write_count;
    integer stat_mismatch_count;
    integer expected_best_idx;
    integer actual_best_idx;
    reg signed [7:0] expected_best_val;
    reg signed [7:0] actual_best_val;

    assign inst = rom[inst_addr[19:2]];
    assign mem_req_ready = 1'b1;

    rv_core u_core (
        .clk(clk),
        .rst(rst),
        .inst_addr(inst_addr),
        .inst(inst),
        .mem_addr(cpu_mem_addr),
        .mem_wdata(cpu_mem_wdata),
        .mem_wen(cpu_mem_wen),
        .mem_width(cpu_mem_width),
        .mem_rdata(cpu_mem_rdata),
        .cnn_cmd_valid(cpu_cnn_cmd_valid),
        .cnn_cmd_funct3(cpu_cnn_cmd_funct3),
        .cnn_cmd_rs1(cpu_cnn_cmd_rs1),
        .cnn_cmd_rs2(cpu_cnn_cmd_rs2),
        .cnn_cmd_rdata(cpu_cnn_cmd_rdata)
    );

    npc_cnn_custom_bridge u_bridge (
        .clk(clk),
        .rst_n(~rst),
        .cpu_cmd_valid(cpu_cnn_cmd_valid),
        .cpu_cmd_funct3(cpu_cnn_cmd_funct3),
        .cpu_cmd_rs1(cpu_cnn_cmd_rs1),
        .cpu_cmd_rs2(cpu_cnn_cmd_rs2),
        .cpu_cmd_rdata(cpu_cnn_cmd_rdata),
        .acc_cmd_valid(bridge_acc_cmd_valid),
        .acc_cmd(bridge_acc_cmd),
        .acc_desc_base(bridge_acc_desc_base),
        .acc_layer_num(bridge_acc_layer_num),
        .acc_cmd_ready(acc_cmd_ready),
        .acc_status(acc_status)
    );

    cnn_top u_cnn_top (
        .clk(clk),
        .rst_n(~rst),
        .cmd_valid(bridge_acc_cmd_valid),
        .cmd_ready(acc_cmd_ready),
        .cmd_type(bridge_acc_cmd),
        .desc_base_addr(bridge_acc_desc_base),
        .layer_num(bridge_acc_layer_num),
        .status(acc_status),
        .mem_req_valid(mem_req_valid),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function [31:0] read_cpu_mem;
        input [31:0] addr;
        input [2:0] width;
        reg [31:0] word;
        reg [1:0] offset;
        begin
            word = addr[31] ? ram[addr[19:2]] : rom[addr[19:2]];
            offset = addr[1:0];
            case (width)
                SL_BYTE:
                    case (offset)
                        2'b00: read_cpu_mem = {{24{word[7]}}, word[7:0]};
                        2'b01: read_cpu_mem = {{24{word[15]}}, word[15:8]};
                        2'b10: read_cpu_mem = {{24{word[23]}}, word[23:16]};
                        default: read_cpu_mem = {{24{word[31]}}, word[31:24]};
                    endcase
                SL_HALF:
                    if (offset[1] == 1'b0) begin
                        read_cpu_mem = {{16{word[15]}}, word[15:0]};
                    end else begin
                        read_cpu_mem = {{16{word[31]}}, word[31:16]};
                    end
                SL_WORD:
                    read_cpu_mem = word;
                L_BYTE_U:
                    case (offset)
                        2'b00: read_cpu_mem = {24'd0, word[7:0]};
                        2'b01: read_cpu_mem = {24'd0, word[15:8]};
                        2'b10: read_cpu_mem = {24'd0, word[23:16]};
                        default: read_cpu_mem = {24'd0, word[31:24]};
                    endcase
                L_HALF_U:
                    if (offset[1] == 1'b0) begin
                        read_cpu_mem = {16'd0, word[15:0]};
                    end else begin
                        read_cpu_mem = {16'd0, word[31:16]};
                    end
                default:
                    read_cpu_mem = 32'd0;
            endcase
        end
    endfunction

    always @(*) begin
        cpu_mem_rdata = read_cpu_mem(cpu_mem_addr, cpu_mem_width);
    end

    task write_cpu_ram;
        input [31:0] addr;
        input [2:0] width;
        input [31:0] data;
        reg [1:0] offset;
        begin
            offset = addr[1:0];
            if (addr[31]) begin
                case (width)
                    SL_BYTE:
                        case (offset)
                            2'b00: ram[addr[19:2]][7:0] <= data[7:0];
                            2'b01: ram[addr[19:2]][15:8] <= data[7:0];
                            2'b10: ram[addr[19:2]][23:16] <= data[7:0];
                            default: ram[addr[19:2]][31:24] <= data[7:0];
                        endcase
                    SL_HALF:
                        if (offset[1] == 1'b0) begin
                            ram[addr[19:2]][15:0] <= data[15:0];
                        end else begin
                            ram[addr[19:2]][31:16] <= data[15:0];
                        end
                    SL_WORD:
                        ram[addr[19:2]] <= data;
                    default:
                        ram[addr[19:2]] <= ram[addr[19:2]];
                endcase
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 32'd0;
        end else begin
            mem_resp_valid <= 1'b0;

            if (cpu_mem_wen) begin
                write_cpu_ram(cpu_mem_addr, cpu_mem_width, cpu_mem_wdata);
            end

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    ram[mem_req_addr[19:2]] <= mem_req_wdata;
                    if (cnn_write_count < MAX_LOGITS) begin
                        captured_logits[cnn_write_count] <= mem_req_wdata[7:0];
                    end
                    cnn_write_count <= cnn_write_count + 1;
                end else begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= mem_req_addr[31] ? ram[mem_req_addr[19:2]] :
                                                        rom[mem_req_addr[19:2]];
                end
            end

            if (bridge_acc_cmd_valid && acc_cmd_ready && (bridge_acc_cmd == 2'd0)) begin
                start_count <= start_count + 1;
            end

            if (cpu_cnn_cmd_valid && (cpu_cnn_cmd_funct3 == 3'd2)) begin
                stat_count <= stat_count + 1;
                if (cpu_cnn_cmd_rdata !== {8'd0, acc_status[31:8]}) begin
                    stat_mismatch_count <= stat_mismatch_count + 1;
                end
            end
        end
    end

    initial begin
        for (i = 0; i < ROM_WORDS; i = i + 1) begin
            rom[i] = 32'd0;
        end
        for (i = 0; i < RAM_WORDS; i = i + 1) begin
            ram[i] = 32'd0;
        end
        for (i = 0; i < MAX_LOGITS; i = i + 1) begin
            expected_logits[i] = 8'd0;
            captured_logits[i] = 8'd0;
        end
        expected_argmax_mem[0] = 32'd0;

        expected_logits_path = "tests/vectors/training_smoke/expected_fullnet_logits.hex";
        expected_argmax_path = "tests/vectors/training_smoke/expected_argmax.hex";
        if (!$value$plusargs("expected_logits_hex=%s", expected_logits_path)) begin
        end
        if (!$value$plusargs("expected_argmax_hex=%s", expected_argmax_path)) begin
        end

        $readmemh("build/firmware/rom.hex", rom);
        $readmemh(expected_logits_path, expected_logits);
        $readmemh(expected_argmax_path, expected_argmax_mem);

        rst = 1'b1;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = 32'd0;
        timeout = 0;
        error_count = 0;
        start_count = 0;
        stat_count = 0;
        cnn_write_count = 0;
        stat_mismatch_count = 0;

        repeat (10) @(posedge clk);
        rst = 1'b0;

        while (((start_count == 0) || !acc_status[1] || (stat_count == 0)) &&
               (timeout < TIMEOUT_CYCLES)) begin
            timeout = timeout + 1;
            @(posedge clk);
        end

        repeat (20) @(posedge clk);

        if (timeout >= TIMEOUT_CYCLES) begin
            $display(
                "MISMATCH timeout start_count=%0d stat_count=%0d status=%08x writes=%0d",
                start_count,
                stat_count,
                acc_status,
                cnn_write_count
            );
            error_count = error_count + 1;
        end
        if (start_count == 0) begin
            $display("MISMATCH CPU did not issue cnn.start");
            error_count = error_count + 1;
        end
        if (!acc_status[1]) begin
            $display("MISMATCH cnn_top did not report done status=%08x", acc_status);
            error_count = error_count + 1;
        end
        if (acc_status[2]) begin
            $display("MISMATCH cnn_top reported error status=%08x", acc_status);
            error_count = error_count + 1;
        end
        if (stat_count == 0) begin
            $display("MISMATCH CPU did not issue cnn.stat");
            error_count = error_count + 1;
        end
        if (stat_mismatch_count != 0) begin
            $display("MISMATCH cnn.stat cycle count mismatches=%0d", stat_mismatch_count);
            error_count = error_count + 1;
        end
        if (cnn_write_count != MAX_LOGITS) begin
            $display("MISMATCH expected %0d cnn output writes actual=%0d", MAX_LOGITS, cnn_write_count);
            error_count = error_count + 1;
        end

        expected_best_idx = 0;
        actual_best_idx = 0;
        expected_best_val = $signed(expected_logits[0]);
        actual_best_val = $signed(captured_logits[0]);
        for (i = 0; i < MAX_LOGITS; i = i + 1) begin
            if (captured_logits[i] !== expected_logits[i]) begin
                $display(
                    "MISMATCH logit[%0d] expected=%0d actual=%0d",
                    i,
                    $signed(expected_logits[i]),
                    $signed(captured_logits[i])
                );
                error_count = error_count + 1;
            end
            if ($signed(expected_logits[i]) > expected_best_val) begin
                expected_best_val = $signed(expected_logits[i]);
                expected_best_idx = i;
            end
            if ($signed(captured_logits[i]) > actual_best_val) begin
                actual_best_val = $signed(captured_logits[i]);
                actual_best_idx = i;
            end
        end

        if (expected_best_idx != expected_argmax_mem[0]) begin
            $display(
                "MISMATCH expected_argmax_file=%0d logits_argmax=%0d",
                expected_argmax_mem[0],
                expected_best_idx
            );
            error_count = error_count + 1;
        end
        if (actual_best_idx != expected_argmax_mem[0]) begin
            $display(
                "MISMATCH actual_argmax=%0d expected_argmax=%0d",
                actual_best_idx,
                expected_argmax_mem[0]
            );
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display(
                "PASS tb_npc_rv_core_cnn_top_fullnet cycles=%0d status=%08x start_count=%0d stat_count=%0d argmax=%0d",
                acc_status[31:8],
                acc_status,
                start_count,
                stat_count,
                actual_best_idx
            );
            $finish;
        end else begin
            $display(
                "FAIL tb_npc_rv_core_cnn_top_fullnet errors=%0d status=%08x writes=%0d",
                error_count,
                acc_status,
                cnn_write_count
            );
            $fatal;
        end
    end
endmodule

`default_nettype wire
