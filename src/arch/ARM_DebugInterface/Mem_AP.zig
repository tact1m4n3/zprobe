const std = @import("std");

const ARM_DebugInterface = @import("../ARM_DebugInterface.zig");
const AP_Address = ARM_DebugInterface.AP_Address;
const AP_Register = ARM_DebugInterface.AP_Register;
const Memory = @import("../../Memory.zig");

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

pub fn memory(mem_ap: *Mem_AP) Memory {
    return .{
        .ptr = mem_ap,
        .vtable = &.{
            .read_u8 = read_u8,
            .read_u16 = read_u16,
            .read_u32 = read_u32,
            // .read_u64 = read_u64,
            .write_u8 = write_u8,
            .write_u16 = write_u16,
            .write_u32 = write_u32,
            // .write_u64 = write_u64,
        },
    };
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

fn read_u8(ptr: *anyopaque, addr: u64, data: []u8) Memory.ReadError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    if (!mem_ap.support_other_sizes)
        return error.Unsupported;

    mem_ap.set_access_size(.byte) catch return error.ReadFailed;

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset;
        const max_count = max_transfer_size(base_addr);

        mem_ap.set_tar_address(base_addr) catch |err| switch (err) {
            error.Unsupported => return error.Unsupported,
            else => return error.ReadFailed,
        };

        // Bytes are aligned according to byte lanes
        const count = @min(data.len - offset, max_count);

        mem_ap.adi.ap_reg_read_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]) catch return error.ReadFailed;

        for (0..count) |i| {
            data[offset + i] = @truncate(mem_ap.tmp_buf[i] >> @intCast(((base_addr + i) & 0b11) * 8));
        }

        offset += count;
    }
}

fn read_u16(ptr: *anyopaque, addr: u64, data: []u16) Memory.ReadError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    if (!mem_ap.support_other_sizes)
        return error.Unsupported;
    if (addr & 0x1 != 0) return error.AddressMisaligned;

    mem_ap.set_access_size(.half_word) catch return error.ReadFailed;

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset * @sizeOf(u16);
        const max_count = max_transfer_size(base_addr) / @sizeOf(u16);

        mem_ap.set_tar_address(base_addr) catch |err| switch (err) {
            error.Unsupported => return error.Unsupported,
            else => return error.ReadFailed,
        };

        const count = @min(data.len - offset, max_count);

        mem_ap.adi.ap_reg_read_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]) catch return error.ReadFailed;

        for (0..count) |i| {
            data[offset + i] = @truncate(mem_ap.tmp_buf[i] >> @intCast(((base_addr + i * @sizeOf(u16)) & 0b11) * 8));
        }

        offset += count;
    }
}

fn read_u32(ptr: *anyopaque, addr: u64, data: []u32) Memory.ReadError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    if (addr & 0x3 != 0) return error.AddressMisaligned;

    mem_ap.set_access_size(.word) catch return error.ReadFailed;

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset * @sizeOf(u32);
        const max_count = max_transfer_size(base_addr) / @sizeOf(u32);

        mem_ap.set_tar_address(base_addr) catch |err| switch (err) {
            error.Unsupported => return error.Unsupported,
            else => return error.ReadFailed,
        };

        const count = @min(data.len - offset, max_count);
        mem_ap.adi.ap_reg_read_repeated(mem_ap.address, regs.DRW.addr, data[offset..][0..count]) catch return error.ReadFailed;

        offset += count;
    }
}

// fn read_u64(ptr: *anyopaque, addr: u64, data: []u64) Memory.ReadError!void {
//     const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
//     if (!mem_ap.support_large_data_ext) return error.Unsupported;
//
//     mem_ap.set_tar_address(addr) catch |err| switch (err) {
//         error.Unsupported => return error.Unsupported,
//         else => return error.ReadFailed,
//     };
//
//     mem_ap.set_access_size(.double_word) catch return error.ReadFailed;
//     mem_ap.adi.ap_reg_read_repeated(mem_ap.address, regs.DRW.addr, data) catch return error.ReadFailed;
// }

fn write_u8(ptr: *anyopaque, addr: u64, data: []const u8) Memory.WriteError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    if (!mem_ap.support_other_sizes) return error.Unsupported;

    mem_ap.set_access_size(.byte) catch return error.WriteFailed;

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset;
        const max_count = max_transfer_size(base_addr);

        mem_ap.set_tar_address(base_addr) catch |err| switch (err) {
            error.Unsupported => return error.Unsupported,
            else => return error.WriteFailed,
        };

        // Bytes need to be aligned according to byte lanes
        const count = @min(data.len - offset, max_count);
        for (0..count) |i| {
            mem_ap.tmp_buf[i] = @as(u32, data[offset + i]) << @intCast(((base_addr + i) & 0b11) * 8);
        }
        mem_ap.adi.ap_reg_write_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]) catch return error.WriteFailed;

        offset += count;
    }
}

fn write_u16(ptr: *anyopaque, addr: u64, data: []const u16) Memory.WriteError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    if (!mem_ap.support_other_sizes) return error.Unsupported;
    if (addr & 0x1 != 0) return error.AddressMisaligned;

    mem_ap.set_access_size(.half_word) catch return error.WriteFailed;

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset * @sizeOf(u16);
        const max_count = max_transfer_size(base_addr) / @sizeOf(u16);

        mem_ap.set_tar_address(base_addr) catch |err| switch (err) {
            error.Unsupported => return error.Unsupported,
            else => return error.WriteFailed,
        };

        const count = @min(data.len - offset, max_count);
        for (0..count) |i| {
            mem_ap.tmp_buf[i] = @as(u32, data[offset + i]) << @intCast(((base_addr + i * @sizeOf(u16)) & 0b11) * 8);
        }
        mem_ap.adi.ap_reg_write_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]) catch return error.WriteFailed;

        offset += count;
    }
}

fn write_u32(ptr: *anyopaque, addr: u64, data: []const u32) Memory.WriteError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    if (addr & 0x3 != 0) return error.AddressMisaligned;

    mem_ap.set_access_size(.word) catch return error.WriteFailed;

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset * @sizeOf(u32);
        const max_count = max_transfer_size(base_addr) / @sizeOf(u32);

        mem_ap.set_tar_address(base_addr) catch |err| switch (err) {
            error.Unsupported => return error.Unsupported,
            else => return error.WriteFailed,
        };

        const count = @min(data.len - offset, max_count);
        mem_ap.adi.ap_reg_write_repeated(mem_ap.address, regs.DRW.addr, data[offset..][0..count]) catch return error.WriteFailed;
        offset += count;
    }
}

// fn write_u64(ptr: *anyopaque, addr: u64, data: []const u64) Memory.WriteError!void {
//     const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
//     if (!mem_ap.support_large_data_ext) return error.Unsupported;
//
//     mem_ap.set_tar_address(addr) catch |err| switch (err) {
//         error.Unsupported => return error.Unsupported,
//         else => return error.WriteFailed,
//     };
//
//     mem_ap.set_access_size(.double_word) catch return error.WriteFailed;
//     mem_ap.adi.ap_reg_write_repeated(mem_ap.address, regs.DRW.addr, data) catch return error.WriteFailed;
// }

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
