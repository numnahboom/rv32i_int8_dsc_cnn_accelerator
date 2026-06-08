`include "defines.vh"

module soc_top(
	input wire clk,
	input wire rst
);
/* verilator lint_off UNUSEDSIGNAL */
	wire[31:0] inst_addr, mem_addr;
/* verilator lint_on UNUSEDSIGNAL */
	wire[31:0] inst;
	wire[31:0] mem_wdata, mem_rdata;
	wire mem_wen;
	wire[2:0] mem_width;
	wire cnn_cmd_valid;
	wire[2:0] cnn_cmd_funct3;
	wire[31:0] cnn_cmd_rs1, cnn_cmd_rs2, cnn_cmd_rdata;
	wire[31:0] cnn_img_addr0, cnn_img_addr1, cnn_img_addr2;
	wire[31:0] cnn_img_addr3, cnn_img_addr4, cnn_img_addr5;
	wire[31:0] cnn_img_addr6, cnn_img_addr7, cnn_img_addr8;
	wire signed[7:0] cnn_img_data0, cnn_img_data1, cnn_img_data2;
	wire signed[7:0] cnn_img_data3, cnn_img_data4, cnn_img_data5;
	wire signed[7:0] cnn_img_data6, cnn_img_data7, cnn_img_data8;

	rv_core u_core(
		.clk(clk), .rst(rst),
		.inst_addr(inst_addr), .inst(inst),
		.mem_addr(mem_addr), .mem_wdata(mem_wdata),
		.mem_wen(mem_wen), .mem_width(mem_width),
		.mem_rdata(mem_rdata),
		.cnn_cmd_valid(cnn_cmd_valid),
		.cnn_cmd_funct3(cnn_cmd_funct3),
		.cnn_cmd_rs1(cnn_cmd_rs1),
		.cnn_cmd_rs2(cnn_cmd_rs2),
		.cnn_cmd_rdata(cnn_cmd_rdata)
	);

	cnn_accelerator u_cnn_accelerator(
		.clk(clk), .rst(rst),
		.cmd_valid(cnn_cmd_valid),
		.cmd_funct3(cnn_cmd_funct3),
		.cmd_rs1(cnn_cmd_rs1),
		.cmd_rs2(cnn_cmd_rs2),
		.cmd_rdata(cnn_cmd_rdata),
		.img_addr0(cnn_img_addr0),
		.img_addr1(cnn_img_addr1),
		.img_addr2(cnn_img_addr2),
		.img_addr3(cnn_img_addr3),
		.img_addr4(cnn_img_addr4),
		.img_addr5(cnn_img_addr5),
		.img_addr6(cnn_img_addr6),
		.img_addr7(cnn_img_addr7),
		.img_addr8(cnn_img_addr8),
		.img_data0(cnn_img_data0),
		.img_data1(cnn_img_data1),
		.img_data2(cnn_img_data2),
		.img_data3(cnn_img_data3),
		.img_data4(cnn_img_data4),
		.img_data5(cnn_img_data5),
		.img_data6(cnn_img_data6),
		.img_data7(cnn_img_data7),
		.img_data8(cnn_img_data8)
	);

	cnn_image_ram #(
		.DEPTH(16 * 28 * 28),
		.HEX_FILE("cnn_image.hex")
	) u_cnn_image_ram (
		.addr0(cnn_img_addr0),
		.addr1(cnn_img_addr1),
		.addr2(cnn_img_addr2),
		.addr3(cnn_img_addr3),
		.addr4(cnn_img_addr4),
		.addr5(cnn_img_addr5),
		.addr6(cnn_img_addr6),
		.addr7(cnn_img_addr7),
		.addr8(cnn_img_addr8),
		.data0(cnn_img_data0),
		.data1(cnn_img_data1),
		.data2(cnn_img_data2),
		.data3(cnn_img_data3),
		.data4(cnn_img_data4),
		.data5(cnn_img_data5),
		.data6(cnn_img_data6),
		.data7(cnn_img_data7),
		.data8(cnn_img_data8)
	);

	rom u_rom(
		.pc(inst_addr), .inst(inst)
	);

	ram u_ram(
		.clk(clk), .wen(mem_wen),
		.addr(mem_addr[19:0]), .width(mem_width),
		.wdata(mem_wdata), .rdata(mem_rdata)
	);
	always@(posedge clk) begin
		if(inst[6:0] == `OP_SYSTEM) begin
			$display("Halt.");
			$finish;
		end
	end
endmodule
