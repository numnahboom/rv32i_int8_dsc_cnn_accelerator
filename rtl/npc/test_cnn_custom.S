/*
 * CNN custom-instruction accuracy smoke test.
 *
 * Runs the 16 images exported to cnn_image.hex.  x10 counts correct
 * predictions, so the final accuracy is x10 / 16.
 *
 * Custom-0 instruction format:
 *   funct3=000: start CNN inference, rs1 = image index
 *   funct3=001: read status, bit1=busy, bit2=done, bits[11:8]=prediction
 *   funct3=010: read prediction, bits[3:0]=prediction
 *   funct3=011: read elapsed accelerator cycles
 */

    .option norvc
    .section .text
    .globl _start

    .macro cnn_start rd, rs1
        .insn r 0x0b, 0x0, 0x00, \rd, \rs1, x0
    .endm

    .macro cnn_status rd
        .insn r 0x0b, 0x1, 0x00, \rd, x0, x0
    .endm

    .macro cnn_result rd
        .insn r 0x0b, 0x2, 0x00, \rd, x0, x0
    .endm

    .macro cnn_cycles rd
        .insn r 0x0b, 0x3, 0x00, \rd, x0, x0
    .endm

    .macro run_image index, label
        addi x5, x0, \index
        cnn_start x0, x5
1:
        cnn_status x6
        andi x7, x6, 4
        beq  x7, x0, 1b
        cnn_result x12
        cnn_cycles x11
        addi x13, x0, \label
        bne  x12, x13, 2f
        addi x10, x10, 1
2:
    .endm

_start:
    addi x10, x0, 0

    /* Labels from cnn_labels.hex for MNIST test images 0..15. */
    run_image 0,  7
    run_image 1,  2
    run_image 2,  1
    run_image 3,  0
    run_image 4,  4
    run_image 5,  1
    run_image 6,  4
    run_image 7,  9
    run_image 8,  5
    run_image 9,  9
    run_image 10, 0
    run_image 11, 6
    run_image 12, 9
    run_image 13, 0
    run_image 14, 1
    run_image 15, 5

    ecall
