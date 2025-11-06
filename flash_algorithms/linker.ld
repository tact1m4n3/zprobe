PHDRS {
    text PT_LOAD;
    note PT_NOTE;
}

SECTIONS {
    . = 0;

    .text : {
        KEEP(*(.bkp))

        KEEP(*(.text*))
        *(.ram_text*)
        *(.rodata*)
        *(.data*)
        *(.bss*)
    } :text

    .meta : {
        KEEP(*(.meta))
    } :note

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
