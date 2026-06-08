/*
 * RV32I five-stage pipeline self-check program for this npc project.
 *
 * Pass rule used by csrc/sim_main.cpp:
 *   x10/a0 == 0 when ecall is fetched  -> Good trap
 *   x10/a0 != 0                        -> Bad trap, value is the failing case
 *
 * Assemble for RV32I only. Example GNU flow:
 *   riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
 *     -Ttext=0 -Wl,--oformat=binary -o test_rv32i_pipeline.bin test_rv32i_pipeline.S
 *
 * Then convert each little-endian 32-bit instruction word in the binary to one
 * hex line in rom.hex.
 */

    .option norvc
    .section .text
    .globl _start

_start:
    /* x0 must stay zero. */
    addi x1, x0, 123
    add  x0, x1, x1
    addi x2, x0, 0
    addi x10, x0, 1
    bne  x0, x2, fail

    /* ALU register/immediate operations and EX/MEM forwarding. */
    addi x3, x0, 5
    addi x4, x0, 7
    add  x5, x3, x4
    add  x6, x5, x4
    addi x7, x0, 19
    addi x10, x0, 2
    bne  x6, x7, fail

    sub  x8, x6, x3
    addi x9, x0, 14
    addi x10, x0, 3
    bne  x8, x9, fail

    addi x11, x0, -1
    addi x12, x11, 1
    addi x10, x0, 4
    bne  x12, x0, fail

    addi x3, x0, 240
    addi x4, x0, 51
    and  x5, x3, x4
    addi x6, x0, 48
    addi x10, x0, 5
    bne  x5, x6, fail

    or   x5, x3, x4
    addi x6, x0, 243
    addi x10, x0, 6
    bne  x5, x6, fail

    xor  x5, x3, x4
    addi x6, x0, 195
    addi x10, x0, 7
    bne  x5, x6, fail

    addi x3, x0, 1
    slli x4, x3, 8
    addi x5, x0, 256
    addi x10, x0, 8
    bne  x4, x5, fail

    srli x6, x4, 8
    addi x10, x0, 9
    bne  x6, x3, fail

    addi x5, x0, -8
    srai x6, x5, 1
    addi x7, x0, -4
    addi x10, x0, 10
    bne  x6, x7, fail

    addi x3, x0, -1
    addi x4, x0, 1
    slt  x5, x3, x4
    addi x10, x0, 11
    bne  x5, x4, fail

    sltu x5, x3, x4
    addi x10, x0, 12
    bne  x5, x0, fail

    slti x5, x4, 2
    addi x10, x0, 13
    bne  x5, x4, fail

    sltiu x5, x3, 1
    addi x10, x0, 14
    bne  x5, x0, fail

    /* LUI: 0x00001000 >> 12 == 1. */
    lui  x3, 0x1
    srli x4, x3, 12
    addi x5, x0, 1
    addi x10, x0, 15
    bne  x4, x5, fail

    /* AUIPC and JAL: check link address and jump flush. */
    auipc x3, 0
    jal  x4, 1f
    addi x10, x0, 16
    jal  x0, fail
1:
    addi x4, x4, -8
    addi x10, x0, 17
    bne  x3, x4, fail

    /* JALR: compute target from PC, check link address, and flush fall-through. */
    auipc x3, 0
    addi x3, x3, 20
    jalr x4, 0(x3)
    addi x10, x0, 18
    jal  x0, fail
2:
    addi x5, x3, -8
    addi x10, x0, 19
    bne  x4, x5, fail

    /* Branch conditions, both signed and unsigned. */
    addi x3, x0, 5
    addi x4, x0, 5
    addi x10, x0, 20
    beq  x3, x4, 3f
    jal  x0, fail
3:
    addi x4, x0, 6
    addi x10, x0, 21
    bne  x3, x4, 4f
    jal  x0, fail
4:
    addi x3, x0, -1
    addi x4, x0, 1
    addi x10, x0, 22
    blt  x3, x4, 5f
    jal  x0, fail
5:
    addi x10, x0, 23
    bge  x4, x3, 6f
    jal  x0, fail
6:
    addi x10, x0, 24
    bltu x4, x3, 7f
    jal  x0, fail
7:
    addi x10, x0, 25
    bgeu x3, x4, 8f
    jal  x0, fail
8:

    /* Data memory: byte/half/word stores and signed/unsigned loads. */
    addi x2, x0, 256

    addi x3, x0, 68
    sb   x3, 0(x2)
    lbu  x4, 0(x2)
    addi x5, x0, 68
    addi x10, x0, 26
    bne  x4, x5, fail

    addi x3, x0, -1
    sb   x3, 1(x2)
    lb   x4, 1(x2)
    addi x10, x0, 27
    bne  x4, x3, fail

    lbu  x4, 1(x2)
    addi x5, x0, 255
    addi x10, x0, 28
    bne  x4, x5, fail

    sh   x3, 2(x2)
    lh   x4, 2(x2)
    addi x10, x0, 29
    bne  x4, x3, fail

    lhu  x4, 2(x2)
    addi x5, x0, -1
    srli x5, x5, 16
    addi x10, x0, 30
    bne  x4, x5, fail

    lui  x3, 0x12345
    addi x3, x3, 0x678
    sw   x3, 4(x2)
    lw   x4, 4(x2)
    addi x10, x0, 31
    bne  x4, x3, fail

    /* Load-use hazard: the add consumes the lw result immediately. */
    lw   x5, 4(x2)
    add  x6, x5, x5
    add  x7, x3, x3
    addi x10, x0, 32
    bne  x6, x7, fail

    /* Store-data forwarding from a just-produced register value. */
    addi x3, x0, 85
    addi x3, x3, 1
    sw   x3, 8(x2)
    lw   x4, 8(x2)
    addi x5, x0, 86
    addi x10, x0, 33
    bne  x4, x5, fail

    /* Branch operand forwarding from the immediately previous ALU result. */
    addi x3, x0, 3
    addi x4, x3, 4
    addi x10, x0, 34
    addi x5, x0, 7
    beq  x4, x5, pass
    jal  x0, fail

pass:
    addi x10, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    ecall

fail:
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    ecall
