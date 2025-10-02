SECTIONS {
    . = 0;

    .text : {
        KEEP(*(.image_header*))

        *(.text*)
        *(.ram_text*)
        *(.rodata*)
        *(.data*)
        *(.bss*)

        _stack_start = .;
        . = ALIGN(32);
        . += 1024;
        _stack_end = .;
    }

    /DISCARD/ : {
        *(.ARM.exidx*)
        *(.dynamic*)
        *(.dynsym*)
        *(.dynstr*)
        *(.gnu.hash*)
        *(.hash*)
        *(.rel.dyn*)
        *(.rela.dyn*)
    }
}
