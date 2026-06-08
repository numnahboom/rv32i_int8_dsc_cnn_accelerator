ENTRY(_start)

PROVIDE(_stack_top = ORIGIN(RAM) + LENGTH(RAM));

MEMORY
{
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 256K
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 512K
}

SECTIONS
{
  .text : {
    *(.text.start)
    *(.text*)
    *(.rodata*)
  } > ROM

  .data : {
    *(.data*)
  } > RAM AT > ROM

  .bss : {
    _sbss = .;
    *(.bss*)
    *(COMMON)
    _ebss = .;
  } > RAM
}
