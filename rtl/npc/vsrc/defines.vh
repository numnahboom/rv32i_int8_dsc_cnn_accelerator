`ifndef DEFINES_VH
`define DEFINES_VH

`define ALU_ADD   4'b0000
`define ALU_SUB   4'b1000
`define ALU_SLL   4'b0001
`define ALU_SLT   4'b0010
`define ALU_SLTU  4'b0011
`define ALU_XOR   4'b0100
`define ALU_SRL   4'b0101
`define ALU_SRA   4'b1101
`define ALU_OR    4'b0110
`define ALU_AND   4'b0111

`define F3_ADD_SUB 3'b000
`define F3_SLL     3'b001
`define F3_SLT     3'b010
`define F3_SLTU    3'b011
`define F3_XOR     3'b100
`define F3_SRL_SRA 3'b101
`define F3_OR      3'b110
`define F3_AND     3'b111

`define BR_BEQ     3'b000
`define BR_BNE     3'b001
`define BR_BLT     3'b100
`define BR_BGE     3'b101
`define BR_BLTU    3'b110
`define BR_BGEU    3'b111

`define SL_BYTE    3'b000
`define SL_HALF    3'b001
`define SL_WORD    3'b010
`define L_BYTE_U   3'b100
`define L_HALF_U   3'b101

`define F7_DEFAULT 7'b0000000
`define F7_ALT     7'b0100000

`define OP_R_TYPE  7'b0110011
`define OP_I_TYPE  7'b0010011
`define OP_LOAD    7'b0000011
`define OP_STORE   7'b0100011
`define OP_BRANCH  7'b1100011
`define OP_JAL     7'b1101111
`define OP_JALR    7'b1100111
`define OP_LUI     7'b0110111
`define OP_AUIPC   7'b0010111
`define OP_SYSTEM  7'b1110011
`define OP_CUSTOM0 7'b0001011

`define CNN_CMD_START   3'b000
`define CNN_CMD_STATUS  3'b001
`define CNN_CMD_RESULT  3'b010
`define CNN_CMD_CYCLES  3'b011

`endif
