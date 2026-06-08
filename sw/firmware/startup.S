    .section .text.start
    .globl _start

_start:
    la sp, _stack_top
    la t0, _sbss
    la t1, _ebss

2:
    bgeu t0, t1, 3f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 2b

3:
    call main

1:
    j 1b
