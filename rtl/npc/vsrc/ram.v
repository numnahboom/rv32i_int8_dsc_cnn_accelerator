`include "defines.vh"

module ram#(
	parameter DEPTH = 262144
)(
	input wire clk,
	input wire wen,
	input wire[$clog2(DEPTH)+1:0] addr,
	input wire[2:0] width,
	input wire[31:0] wdata,
	output reg[31:0] rdata
);
	reg[31:0] mem[0:DEPTH-1];
	wire[$clog2(DEPTH)-1:0] word_addr = addr[$clog2(DEPTH)+1:2];
	wire[1:0] offset = addr[1:0];

	initial begin
		$readmemh("ram.hex", mem);
	end
	always @(posedge clk) begin
		if(wen) begin
			case(width)
				`SL_BYTE:
					case(offset)
						2'b00: mem[word_addr][7:0] <= wdata[7:0];
						2'b01: mem[word_addr][15:8] <= wdata[7:0];
						2'b10: mem[word_addr][23:16] <= wdata[7:0];
						2'b11: mem[word_addr][31:24] <= wdata[7:0];
					endcase
				`SL_HALF:
					if(offset[1] == 0)
						mem[word_addr][15:0] <= wdata[15:0];
					else
						mem[word_addr][31:16] <= wdata[15:0];
				`SL_WORD:
					mem[word_addr] <= wdata;
				default:
					mem[word_addr] <= mem[word_addr];
			endcase
		end
	end

	always @(*) begin
		case(width)
			`SL_BYTE: 
				case(offset)
					2'b00: rdata = {{24{mem[word_addr][7]}}, mem[word_addr][7:0]};
					2'b01: rdata = {{24{mem[word_addr][15]}}, mem[word_addr][15:8]};
					2'b10: rdata = {{24{mem[word_addr][23]}}, mem[word_addr][23:16]};
					2'b11: rdata = {{24{mem[word_addr][31]}}, mem[word_addr][31:24]};
				endcase
			`SL_HALF:
				if(offset[1] == 0)
					rdata = {{16{mem[word_addr][15]}}, mem[word_addr][15:0]};
				else
					rdata = {{16{mem[word_addr][31]}}, mem[word_addr][31:16]};
			`SL_WORD:
				rdata = mem[word_addr];
			`L_BYTE_U:
				case(offset)
					2'b00: rdata = {24'b0, mem[word_addr][7:0]};
					2'b01: rdata = {24'b0, mem[word_addr][15:8]};
					2'b10: rdata = {24'b0, mem[word_addr][23:16]};
					2'b11: rdata = {24'b0, mem[word_addr][31:24]};
				endcase
			`L_HALF_U:
				if(offset[1] == 0) 
					rdata = {16'b0, mem[word_addr][15:0]};
				else
					rdata = {16'b0, mem[word_addr][31:16]};
			default:
				rdata = 32'b0;
		endcase
	end

endmodule
