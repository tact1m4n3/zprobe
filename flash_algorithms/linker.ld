PHDRS {
    load PT_LOAD;
    note PT_NOTE;
}

SECTIONS {
    . = 0;

    .text : {
        KEEP(*(.text*))
        *(.ram_text*)
        *(.rodata*)
        data_section_offset = .;
        *(.data*)
        *(.bss*)
    } :load

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
