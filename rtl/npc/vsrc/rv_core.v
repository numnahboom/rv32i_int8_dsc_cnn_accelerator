`include "defines.vh"

module rv_core(
	input wire clk,
	input wire rst,
	
	output wire[31:0] inst_addr,
	input wire[31:0] inst,

	output wire[31:0] mem_addr,
	output wire[31:0] mem_wdata,
	output wire mem_wen,
	output wire [2:0] mem_width,
	input wire [31:0] mem_rdata,

	output wire cnn_cmd_valid,
	output wire [2:0] cnn_cmd_funct3,
	output wire [31:0] cnn_cmd_rs1,
	output wire [31:0] cnn_cmd_rs2,
	input wire [31:0] cnn_cmd_rdata
);
	wire pc_en;
	wire[31:0] if_pc, next_pc;

	pc_reg u_pc_reg(
		.clk(clk), .rst(rst), .en(pc_en), .next_pc(next_pc), .pc(if_pc)
	);
	
	assign inst_addr = if_pc;

	wire stall, flush;
	wire[31:0] id_pc, id_inst;

	reg_if_id u_reg_if_id(
		.clk(clk), .rst(rst), .stall(stall), .flush(flush),
		.in_pc(if_pc), .in_inst(inst),
		.out_pc(id_pc), .out_inst(id_inst)
	);
	
	wire id_reg_wen, id_mem_wen, id_alu_src_a, id_alu_src_b, id_is_branch, id_is_jal, id_is_jalr, id_mem_ren, id_is_cnn, id_halt;
	wire[3:0] id_alu_ctrl;
	wire[1:0] id_wb_sel;
	wire[31:0] id_imm;
	
	ctrl_unit u_ctrl_unit(
		.op(id_inst[6:0]), .f3(id_inst[14:12]),
		.f7(id_inst[31:25]), .reg_wen(id_reg_wen), 
		.alu_src_a(id_alu_src_a), .alu_src_b(id_alu_src_b), 
		.alu_ctrl(id_alu_ctrl),
		.mem_wen(id_mem_wen), .wb_sel(id_wb_sel), .is_branch(id_is_branch), 
		.is_jal(id_is_jal), .is_jalr(id_is_jalr), .mem_ren(id_mem_ren),
		.is_cnn(id_is_cnn),
		.halt(id_halt)
	);

	imm_gen u_imm_gen(
		.inst(id_inst), .imm(id_imm)
	);

	wire ex_reg_wen, ex_alu_src_a, ex_alu_src_b, ex_mem_wen, ex_is_branch, ex_is_jal, ex_is_jalr, ex_mem_ren, ex_is_cnn, ex_halt;
	wire wb_reg_wen;
	wire[1:0] ex_wb_sel;
	wire[3:0] ex_alu_ctrl;
	wire[4:0] id_rs1, id_rs2, id_rd, ex_rs1, ex_rs2, ex_rd;
	wire[31:0] ex_pc, ex_imm, id_rdata1, id_rdata2, ex_rdata1, ex_rdata2;
	wire[31:0] wb_reg_wdata;
	wire[2:0] ex_f3;

	assign id_rs1 = id_inst[19:15];
	assign id_rs2 = id_inst[24:20];
	assign id_rd = id_inst[11:7];

	reg_file u_reg_file(
		.clk(clk), .rs1(id_rs1), .rs2(id_rs2), .rd(wb_rd), 
		.wen(wb_reg_wen), .wdata(wb_reg_wdata), 
		.rdata1(id_rdata1), .rdata2(id_rdata2)
	);

	reg_id_ex u_reg_id_ex(
		.clk(clk), .rst(rst), .stall(stall), .flush(flush),
		.in_pc(id_pc), .in_imm(id_imm),
		.in_rdata1(id_rdata1), .in_rdata2(id_rdata2),
		.in_rs1(id_rs1), .in_rs2(id_rs2), .in_rd(id_rd),
		.in_reg_wen(id_reg_wen), 
		.in_alu_src_a(id_alu_src_a), .in_alu_src_b(id_alu_src_b),
		.in_mem_wen(id_mem_wen), .in_is_branch(id_is_branch),
		.in_is_jal(id_is_jal), .in_is_jalr(id_is_jalr),
		.in_is_cnn(id_is_cnn),
		.in_alu_ctrl(id_alu_ctrl), .in_wb_sel(id_wb_sel),
		.in_mem_ren(id_mem_ren),
		.in_halt(id_halt),
		.in_f3(id_inst[14:12]),
		.out_pc(ex_pc), .out_imm(ex_imm), 
		.out_rdata1(ex_rdata1), .out_rdata2(ex_rdata2),
		.out_rs1(ex_rs1), .out_rs2(ex_rs2), .out_rd(ex_rd),
		.out_reg_wen(ex_reg_wen), 
		.out_alu_src_a(ex_alu_src_a), .out_alu_src_b(ex_alu_src_b),
		.out_mem_wen(ex_mem_wen), .out_is_branch(ex_is_branch), 
		.out_is_jal(ex_is_jal), .out_is_jalr(ex_is_jalr),
		.out_is_cnn(ex_is_cnn),
		.out_alu_ctrl(ex_alu_ctrl), .out_wb_sel(ex_wb_sel),
		.out_mem_ren(ex_mem_ren),
		.out_f3(ex_f3),
		.out_halt(ex_halt)
	);

	wire[4:0] mem_rd, wb_rd;
	wire[1:0] for_sel1, for_sel2;
	wire mem_reg_wen;

	forward_unit u_forward_unit(
		.ex_rs1(ex_rs1), .ex_rs2(ex_rs2), .mem_rd(mem_rd), .wb_rd(wb_rd),
		.mem_wen(mem_reg_wen), .wb_wen(wb_reg_wen),
		.for_sel1(for_sel1), .for_sel2(for_sel2)
	);
	
	wire[31:0] a, b, forward_rdata1, forward_rdata2;
	assign forward_rdata1 = (for_sel1 == 2'b0) ? ex_rdata1 :
		(for_sel1 == 2'b01) ? wb_reg_wdata : mem_alu_pc_imm;
	assign forward_rdata2 = (for_sel2 == 2'b0) ? ex_rdata2 :
		(for_sel2 == 2'b01) ? wb_reg_wdata : mem_alu_pc_imm;
	assign a = ex_alu_src_a ? ex_pc : forward_rdata1;
	assign b = ex_alu_src_b ? ex_imm : forward_rdata2;

	wire[31:0] ex_alu_result;
	alu u_alu(
		.a(a), .b(b), .ctrl(ex_alu_ctrl), .result(ex_alu_result)
	);

	assign cnn_cmd_valid = ex_is_cnn;
	assign cnn_cmd_funct3 = ex_f3;
	assign cnn_cmd_rs1 = forward_rdata1;
	assign cnn_cmd_rs2 = forward_rdata2;

	wire[31:0] ex_exec_result;
	assign ex_exec_result = ex_is_cnn ? cnn_cmd_rdata : ex_alu_result;

	wire ex_taken, ex_is_jump;

	branch_cond u_branch_cond(
		.rdata1(forward_rdata1), .rdata2(forward_rdata2), 
		.cond(ex_f3),
		.taken(ex_taken)
	);

	assign ex_is_jump = ex_is_jal | ex_is_jalr | (ex_taken && ex_is_branch);

	hazard_unit u_hazard_unit(
		.mem_r(ex_mem_ren), .is_jump(ex_is_jump),
		.id_rs1(id_rs1), .id_rs2(id_rs2), .ex_rd(ex_rd),
		.flush(flush), .stall(stall), .pc_en(pc_en)
	);
	
	reg[31:0] ex_alu_pc_imm;

	always@(*) begin
		case(ex_wb_sel)
			2'b00: ex_alu_pc_imm = ex_exec_result;
			2'b10: ex_alu_pc_imm = ex_pc + 32'h4;
			2'b11: ex_alu_pc_imm = ex_imm;	
			default: ex_alu_pc_imm = ex_exec_result;
		endcase
	end

	assign next_pc = ex_is_jump ? (ex_alu_result & 32'hfffffffe) : if_pc + 32'h4;

	wire[31:0] mem_alu_pc_imm;
	wire mem_ren;
	wire mem_halt;

	reg_ex_mem u_reg_ex_mem(
		.clk(clk), .rst(rst),
		.in_alu_result(ex_alu_pc_imm), .in_rdata2(forward_rdata2),
		.in_rd(ex_rd),
		.in_reg_wen(ex_reg_wen), .in_mem_wen(ex_mem_wen), .in_mem_ren(ex_mem_ren),
		.in_mem_width(ex_f3),
		.in_halt(ex_halt),
		.out_alu_result(mem_alu_pc_imm), .out_rdata2(mem_wdata),
		.out_rd(mem_rd),
		.out_reg_wen(mem_reg_wen), .out_mem_wen(mem_wen), .out_mem_ren(mem_ren),
		.out_mem_width(mem_width),
		.out_halt(mem_halt)
	);

	wire wb_halt;

	assign mem_addr = mem_alu_pc_imm;

	wire[31:0] mem_reg_wdata;
	assign mem_reg_wdata = mem_ren ? mem_rdata : mem_alu_pc_imm;

	reg_mem_wb u_reg_mem_wb(
		.clk(clk), .rst(rst),
		.in_reg_wdata(mem_reg_wdata), .in_rd(mem_rd),
		.in_reg_wen(mem_reg_wen), 
		.in_halt(mem_halt),
		.out_reg_wdata(wb_reg_wdata),
		.out_rd(wb_rd),
		.out_reg_wen(wb_reg_wen),
		.out_halt(wb_halt)
	);

	always@(posedge clk)begin
		if(wb_halt) $finish;
	end
endmodule
