const std = @import("std");

const ARM_DebugInterface = @import("../ARM_DebugInterface.zig");
const AP_Address = ARM_DebugInterface.AP_Address;
const AP_Register = ARM_DebugInterface.AP_Register;
const Target = @import("../../Target.zig");

const Mem_AP = @This();

adi: *ARM_DebugInterface,
address: AP_Address,
support_other_sizes: bool,
support_large_address_ext: bool,
support_large_data_ext: bool,

current_access_size: AccessSize = .word,

tmp_buf: [TAR_MAX_INCREMENT]u32 = undefined,

// TAR auto-increment works with 10bits at minimum
const TAR_MAX_INCREMENT = 1 << 10;
fn max_transfer_size(address: u64) usize {
    const a = (address + 1) / TAR_MAX_INCREMENT;
    return (a + 1) * TAR_MAX_INCREMENT - address;
}

pub fn init(adi: *ARM_DebugInterface, ap_address: AP_Address) !Mem_AP {
    const idr = try adi.ap_reg_read(ap_address, ARM_DebugInterface.regs.ap.IDR.addr);
    if (idr == 0) return error.NoAP_Found;

    const cfg = try regs.CFG.read(adi, ap_address);

    const support_large_address_ext = cfg.LA == 1;
    const support_large_data_ext = cfg.LD == 1;

    // We check if the AP supports other sizes than 32-bits by trying to set
    // SIZE to something else. If it is read-only then the AP does not support
    // other sizes.
    try regs.CSW.modify(adi, ap_address, .{
        .SIZE = .byte,
        .AddrInc = .single,
        .DbgSwEnable = 1,
    });

    var csw = try regs.CSW.read(adi, ap_address);
    const support_other_sizes = csw.SIZE == .byte;
    csw.SIZE = .word; // default to word

    try regs.CSW.write(adi, ap_address, csw);

    return .{
        .adi = adi,
        .address = ap_address,
        .support_other_sizes = support_other_sizes,
        .support_large_address_ext = support_large_address_ext,
        .support_large_data_ext = support_large_data_ext,
    };
}

pub fn reinit(mem_ap: *Mem_AP) !void {
    try regs.CSW.modify(mem_ap.adi, mem_ap.address, .{
        .SIZE = mem_ap.current_access_size,
        .AddrInc = .single,
        .DbgSwEnable = 1,
    });
}

fn set_tar_address(mem_ap: Mem_AP, addr: u64) !void {
    if (!mem_ap.support_large_address_ext and addr > std.math.maxInt(u32)) {
        return error.Unsupported;
    } else if (mem_ap.support_large_address_ext) {
        try regs.TAR_MS.write(mem_ap.adi, mem_ap.address, .{
            .ADDR = @truncate(addr >> 32),
        });
    }

    try regs.TAR_LS.write(mem_ap.adi, mem_ap.address, .{
        .ADDR = @truncate(addr),
    });
}

fn set_access_size(mem_ap: *Mem_AP, size: AccessSize) !void {
    if (mem_ap.current_access_size == size) return;
    try regs.CSW.modify(mem_ap.adi, mem_ap.address, .{
        .SIZE = size,
    });
    mem_ap.current_access_size = size;
}

pub fn read_u32(mem_ap: *Mem_AP, addr: u64) !u32 {
    if (addr & 0x3 != 0) return error.AddressMisaligned;

    try mem_ap.set_access_size(.word);
    return try mem_ap.adi.ap_reg_read(mem_ap.address, regs.DRW.addr);
}

pub fn write_u32(mem_ap: *Mem_AP, addr: u64, value: u32) !void {
    if (addr & 0x3 != 0) return error.AddressMisaligned;

    try mem_ap.set_access_size(.word);
    try mem_ap.adi.ap_reg_write(mem_ap.address, regs.DRW.addr, value);
}

pub fn read(mem_ap: *Mem_AP, addr: u64, data: []u8) !void {
    if (!mem_ap.support_other_sizes)
        return error.Unsupported;

    try mem_ap.set_access_size(.byte);

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset;
        const max_count = max_transfer_size(base_addr);

        try mem_ap.set_tar_address(base_addr);

        // Bytes are aligned according to byte lanes
        const count = @min(data.len - offset, max_count);

        try mem_ap.adi.ap_reg_read_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]);

        for (0..count) |i| {
            data[offset + i] = @truncate(mem_ap.tmp_buf[i] >> @intCast(((base_addr + i) & 0b11) * 8));
        }

        offset += count;
    }
}

pub fn write(mem_ap: *Mem_AP, addr: u64, data: []const u8) !void {
    const bytes_before_start = std.mem.alignForward(u64, addr, 4) - addr;
    const bytes_until_end = addr + data.len - std.mem.alignBackward(u64, addr + data.len, 4);

    // if we have at least 1 aligned word
    if (bytes_before_start + bytes_until_end + @sizeOf(u32) < data.len) {
        if (bytes_before_start > 0) {
            try mem_ap.write_u8_buf(addr, data[0..bytes_before_start]);
        }

        const aligned_data_len = data.len - bytes_before_start - bytes_until_end;
        {
            const aligned_data_words = aligned_data_len / @sizeOf(u32);

            var offset: u64 = 0;
            while (offset < aligned_data_words) {
                const base_addr = addr + bytes_before_start + offset * @sizeOf(u32);
                const max_count = max_transfer_size(base_addr) / @sizeOf(u32);

                try mem_ap.set_tar_address(base_addr);

                const count = @min(data.len - offset, max_count);

                for (mem_ap.tmp_buf[0..count], 0..count) |*word, i| {
                    word.* = std.mem.readInt(u32, data[bytes_before_start + offset + i * @sizeOf(u32) ..][0..4], .little);
                }

                try mem_ap.adi.ap_reg_write_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]);
                offset += count;
            }
        }

        if (bytes_until_end > 0) {
            try mem_ap.write_u8_buf(
                addr + bytes_before_start + aligned_data_len,
                data[data.len - bytes_until_end ..],
            );
        }
    } else {
        try mem_ap.write_u8_buf(addr, data);
    }
}

fn write_u8_buf(mem_ap: *Mem_AP, addr: u64, data: []const u8) !void {
    if (!mem_ap.support_other_sizes) return error.Unsupported;

    try mem_ap.set_access_size(.byte);

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset;
        const max_count = max_transfer_size(base_addr);

        try mem_ap.set_tar_address(base_addr);

        // Bytes need to be aligned according to byte lanes
        const count = @min(data.len - offset, max_count);
        for (0..count) |i| {
            mem_ap.tmp_buf[i] = @as(u32, data[offset + i]) << @intCast(((base_addr + i) & 0b11) * 8);
        }
        try mem_ap.adi.ap_reg_write_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]);

        offset += count;
    }
}

pub fn target_memory_vtable(Parent: type, comptime target_name: []const u8, mem_ap_name: []const u8) Target.MemoryVtable {
    return struct {
        const Self = @This();

        const vtable: Target.MemoryVtable = .{
            .read = Self.read,
            .write = Self.write,
        };

        pub fn read(target: *Target, addr: u64, data: []u8) Target.MemoryReadError!void {
            const parent: *Parent = @fieldParentPtr(target_name, target);
            @field(parent, mem_ap_name).read(addr, data) catch |err| switch (err) {
                error.Unsupported => return error.Unsupported,
                else => return error.ReadFailed,
            };
        }

        pub fn write(target: *Target, addr: u64, data: []const u8) Target.MemoryWriteError!void {
            const parent: *Parent = @fieldParentPtr(target_name, target);
            @field(parent, mem_ap_name).write(addr, data) catch |err| switch (err) {
                error.Unsupported => return error.Unsupported,
                else => return error.WriteFailed,
            };
        }
    }.vtable;
}

pub const AccessSize = enum(u3) {
    byte = 0b000,
    half_word = 0b001,
    word = 0b010,
    double_word = 0b011,
    @"128bits" = 0b100,
    @"256bits" = 0b101,
};

pub const AddressIncrement = enum(u2) {
    off = 0b00,
    single = 0b01,
    @"packed" = 0b10,
};

pub const regs = struct {
    pub const CSW = AP_Register(0xD00, packed struct(u32) {
        SIZE: AccessSize,
        RES0: u1,
        AddrInc: AddressIncrement,
        DeviceEn: u1,
        TrInProg: u1,
        Mode: u4,
        Type: u3,
        MTE: u1,
        ERRNPASS: u1,
        ERRSTOP: u1,
        RES1: u3,
        RMEEN: u2,
        SDeviceEn: u1,
        PROT: u7,
        DbgSwEnable: u1,
    });

    pub const TAR_LS = AP_Register(0xD04, packed struct(u32) {
        ADDR: u32,
    });

    pub const TAR_MS = AP_Register(0xD08, packed struct(u32) {
        ADDR: u32,
    });

    pub const DRW = AP_Register(0xD0C, packed struct(u32) {
        DATA: u32,
    });

    pub const CFG = AP_Register(0xDF4, packed struct(u32) {
        BE: u1,
        LA: u1,
        LD: u1,
        RES0: u29,
    });
};
