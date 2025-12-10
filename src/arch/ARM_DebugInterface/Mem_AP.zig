const std = @import("std");

const ADI = @import("../ARM_DebugInterface.zig");
const AP_Address = ADI.AP_Address;
const AP_Register = ADI.AP_Register;
const Target = @import("../../Target.zig");
const Memory = @import("../../Memory.zig");

const Mem_AP = @This();

adi: *ADI,
address: AP_Address,
is_big_endian: bool,
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

pub fn init(adi: *ADI, ap_address: AP_Address) !Mem_AP {
    const idr = try ADI.regs.ap.IDR.read(adi, ap_address);
    // TODO: is there a better way to check this?
    if (@as(u32, @bitCast(idr)) == 0 or idr.CLASS != .mem_ap) return error.NoMem_AP_Found;

    const cfg = try regs.CFG.read(adi, ap_address);

    const is_big_endian = cfg.BE;
    const support_large_address_ext = cfg.LA;
    const support_large_data_ext = cfg.LD;

    const support_other_sizes = switch (idr.TYPE) {
        .amba_ahb3_bus,
        .amba_ahb5_bus,
        .amba_ahb5_with_enhanced_hprot,
        .amba_axi3_or_axi4_bus,
        .amba_axi5_bus,
        => true,
        .amba_apb2_or_apb3_bus,
        .amba_apb4_or_apb5_bus,
        => false,
        else => return error.Unexpected,
    };

    var mem_ap: Mem_AP = .{
        .adi = adi,
        .address = ap_address,
        .is_big_endian = is_big_endian,
        .support_other_sizes = support_other_sizes,
        .support_large_address_ext = support_large_address_ext,
        .support_large_data_ext = support_large_data_ext,
    };

    try mem_ap.reinit();

    return mem_ap;
}

pub fn reinit(mem_ap: *Mem_AP) !void {
    const idr = try ADI.regs.ap.IDR.read(mem_ap.adi, mem_ap.address);
    const csw = try regs.CSW.read(mem_ap.adi, mem_ap.address);
    switch (idr.TYPE) {
        .amba_ahb3_bus,
        .amba_ahb5_with_enhanced_hprot,
        => try regs.ahb3_ahb5_hprot.CSW.modify(mem_ap.adi, mem_ap.address, .{
            .DbgSwEnable = true,
            .SIZE = mem_ap.current_access_size,
            .AddrInc = .single,
            .HNONSEC = !csw.SDeviceEn,
            .MasterType = true,
            .Cacheable = true,
            .Priviledged = true,
            .Data = true,
        }),
        .amba_ahb5_bus => try regs.ahb5.CSW.modify(mem_ap.adi, mem_ap.address, .{
            .DbgSwEnable = true,
            .SIZE = mem_ap.current_access_size,
            .AddrInc = .single,
            .HNONSEC = !csw.SDeviceEn,
            .MasterType = true,
            .Priviledged = true,
            .Data = true,
        }),
        else => return error.Unimplemented,
    }
}

pub fn memory(mem_ap: *Mem_AP) Memory {
    return .{
        .ptr = mem_ap,
        .vtable = comptime &.{
            .read_u8 = type_erased_read_u8,
            .read_u16 = type_erased_read_u16,
            .read_u32 = type_erased_read_u32,
            .write_u8 = type_erased_write_u8,
            .write_u16 = type_erased_write_u16,
            .write_u32 = type_erased_write_u32,
            .read = type_erased_read,
            .write = type_erased_write,
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

pub fn read_u8(mem_ap: *Mem_AP, addr: u64, data: []u8) !void {
    if (!mem_ap.support_other_sizes) return error.Unsupported;

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
            var shift_amount = ((base_addr + i) & 0b11) * 8;
            if (mem_ap.is_big_endian) shift_amount = 32 - shift_amount;
            data[offset + i] = @truncate(mem_ap.tmp_buf[i] >> @intCast(shift_amount));
        }

        offset += count;
    }
}

pub fn read_u16(mem_ap: *Mem_AP, addr: u64, data: []u16) !void {
    if (!mem_ap.support_other_sizes) return error.Unsupported;
    if (addr & 0b1 != 0) return error.AddressMisaligned;

    try mem_ap.set_access_size(.half_word);

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset * @sizeOf(u16);
        const max_count = max_transfer_size(base_addr) / @sizeOf(u16);

        try mem_ap.set_tar_address(base_addr);

        const count = @min(data.len - offset, max_count);

        try mem_ap.adi.ap_reg_read_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]);

        for (0..count) |i| {
            var shift_amount = ((base_addr + i) & 0b1) * 16;
            if (mem_ap.is_big_endian) shift_amount = 32 - shift_amount;
            data[offset + i] = @truncate(mem_ap.tmp_buf[i] >> @intCast(shift_amount));
        }

        offset += count;
    }
}

pub fn read_u32(mem_ap: *Mem_AP, addr: u64, data: []u32) !void {
    if (addr & 0b11 != 0) return error.AddressMisaligned;

    try mem_ap.set_access_size(.word);

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset * @sizeOf(u32);
        const max_count = max_transfer_size(base_addr) / @sizeOf(u32);

        try mem_ap.set_tar_address(base_addr);

        const count = @min(data.len - offset, max_count);
        try mem_ap.adi.ap_reg_read_repeated(mem_ap.address, regs.DRW.addr, data[offset..][0..count]);
        offset += count;
    }
}

pub fn write_u8(mem_ap: *Mem_AP, addr: u64, data: []const u8) !void {
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
            var shift_amount = ((base_addr + i) & 0b11) * 8;
            if (mem_ap.is_big_endian) shift_amount = 32 - shift_amount;
            mem_ap.tmp_buf[i] = @as(u32, data[offset + i]) << @intCast(shift_amount);
        }
        try mem_ap.adi.ap_reg_write_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]);

        offset += count;
    }
}

pub fn write_u16(mem_ap: *Mem_AP, addr: u64, data: []const u16) !void {
    if (!mem_ap.support_other_sizes) return error.Unsupported;
    if (addr & 0b1 != 0) return error.AddressMisaligned;

    try mem_ap.set_access_size(.half_word);

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset * @sizeOf(u16);
        const max_count = max_transfer_size(base_addr) / @sizeOf(u16);

        try mem_ap.set_tar_address(base_addr);

        const count = @min(data.len - offset, max_count);
        for (0..count) |i| {
            var shift_amount = ((base_addr + i) & 0b1) * 16;
            if (mem_ap.is_big_endian) shift_amount = 32 - shift_amount;
            mem_ap.tmp_buf[i] = @as(u32, data[offset + i]) << @intCast(shift_amount);
        }
        try mem_ap.adi.ap_reg_write_repeated(mem_ap.address, regs.DRW.addr, mem_ap.tmp_buf[0..count]);
        offset += count;
    }
}

pub fn write_u32(mem_ap: *Mem_AP, addr: u64, data: []const u32) !void {
    if (addr & 0b11 != 0) return error.AddressMisaligned;

    try mem_ap.set_access_size(.word);

    var offset: u64 = 0;
    while (offset < data.len) {
        const base_addr = addr + offset * @sizeOf(u32);
        const max_count = max_transfer_size(base_addr) / @sizeOf(u32);

        try mem_ap.set_tar_address(base_addr);

        const count = @min(data.len - offset, max_count);
        try mem_ap.adi.ap_reg_write_repeated(mem_ap.address, regs.DRW.addr, data[offset..][0..count]);
        offset += count;
    }
}

pub fn read(mem_ap: *Mem_AP, addr: u64, data: []u8) !void {
    const bytes_before_start = std.mem.alignForward(u64, addr, 4) - addr;
    const bytes_until_end = addr + data.len - std.mem.alignBackward(u64, addr + data.len, 4);

    if (bytes_before_start + bytes_until_end + @sizeOf(u32) < data.len) {
        if (bytes_before_start > 0) {
            try mem_ap.read_u8(addr, data[0..bytes_before_start]);
        }

        const aligned_data_len = data.len - bytes_before_start - bytes_until_end;
        const aligned_data_words = aligned_data_len / @sizeOf(u32);

        var offset: usize = 0;
        while (offset < aligned_data_words) {
            const count = @min(aligned_data_words - offset, mem_ap.tmp_buf.len);
            try mem_ap.read_u32(addr + bytes_before_start + offset * @sizeOf(u32), mem_ap.tmp_buf[0..count]);
            for (mem_ap.tmp_buf[0..count], 0..) |word, i| {
                std.mem.writeInt(u32, data[bytes_before_start + (offset + i) * @sizeOf(u32) ..][0..4], word, .little);
            }
            offset += count;
        }

        if (bytes_until_end > 0) {
            try mem_ap.read_u8(
                addr + bytes_before_start + aligned_data_len,
                data[data.len - bytes_until_end ..],
            );
        }
    } else {
        try mem_ap.read_u8(addr, data);
    }
}

pub fn write(mem_ap: *Mem_AP, addr: u64, data: []const u8) !void {
    const bytes_before_start = std.mem.alignForward(u64, addr, 4) - addr;
    const bytes_until_end = addr + data.len - std.mem.alignBackward(u64, addr + data.len, 4);

    // if we have at least 1 aligned word
    if (bytes_before_start + bytes_until_end + @sizeOf(u32) < data.len) {
        if (bytes_before_start > 0) {
            try mem_ap.write_u8(addr, data[0..bytes_before_start]);
        }

        const aligned_data_len = data.len - bytes_before_start - bytes_until_end;
        const aligned_data_words = aligned_data_len / @sizeOf(u32);

        var offset: usize = 0;
        while (offset < aligned_data_words) {
            const count = @min(aligned_data_words - offset, mem_ap.tmp_buf.len);
            for (mem_ap.tmp_buf[0..count], 0..) |*word, i| {
                word.* = std.mem.readInt(u32, data[bytes_before_start + (offset + i) * @sizeOf(u32) ..][0..4], .little);
            }
            try mem_ap.write_u32(addr + bytes_before_start + offset * @sizeOf(u32), mem_ap.tmp_buf[0..count]);
            offset += count;
        }

        if (bytes_until_end > 0) {
            try mem_ap.write_u8(
                addr + bytes_before_start + aligned_data_len,
                data[data.len - bytes_until_end ..],
            );
        }
    } else {
        try mem_ap.write_u8(addr, data);
    }
}

fn type_erased_read_u8(ptr: *anyopaque, addr: u64, data: []u8) Memory.ReadError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    mem_ap.read_u8(addr, data) catch |err| return switch (err) {
        error.Unsupported => error.Unsupported,
        else => error.ReadFailed,
    };
}

fn type_erased_read_u16(ptr: *anyopaque, addr: u64, data: []u16) Memory.ReadError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    mem_ap.read_u16(addr, data) catch |err| return switch (err) {
        error.Unsupported => error.Unsupported,
        error.AddressMisaligned => error.AddressMisaligned,
        else => error.ReadFailed,
    };
}

fn type_erased_read_u32(ptr: *anyopaque, addr: u64, data: []u32) Memory.ReadError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    mem_ap.read_u32(addr, data) catch |err| return switch (err) {
        error.Unsupported => error.Unsupported,
        error.AddressMisaligned => error.AddressMisaligned,
        else => error.ReadFailed,
    };
}

fn type_erased_write_u8(ptr: *anyopaque, addr: u64, data: []const u8) Memory.WriteError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    mem_ap.write_u8(addr, data) catch |err| return switch (err) {
        error.Unsupported => error.Unsupported,
        else => error.WriteFailed,
    };
}

fn type_erased_write_u16(ptr: *anyopaque, addr: u64, data: []const u16) Memory.WriteError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    mem_ap.write_u16(addr, data) catch |err| return switch (err) {
        error.Unsupported => error.Unsupported,
        error.AddressMisaligned => error.AddressMisaligned,
        else => error.WriteFailed,
    };
}

fn type_erased_write_u32(ptr: *anyopaque, addr: u64, data: []const u32) Memory.WriteError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    mem_ap.write_u32(addr, data) catch |err| return switch (err) {
        error.Unsupported => error.Unsupported,
        error.AddressMisaligned => error.AddressMisaligned,
        else => error.WriteFailed,
    };
}

fn type_erased_read(ptr: *anyopaque, addr: u64, data: []u8) Memory.ReadError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    mem_ap.read(addr, data) catch |err| return switch (err) {
        error.Unsupported => error.Unsupported,
        error.AddressMisaligned => unreachable,
        else => error.ReadFailed,
    };
}

fn type_erased_write(ptr: *anyopaque, addr: u64, data: []const u8) Memory.WriteError!void {
    const mem_ap: *Mem_AP = @ptrCast(@alignCast(ptr));
    mem_ap.write(addr, data) catch |err| return switch (err) {
        error.Unsupported => error.Unsupported,
        error.AddressMisaligned => unreachable,
        else => error.WriteFailed,
    };
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
        DeviceEn: bool,
        TrInProg: bool,
        Mode: u4,
        Type: u3,
        MTE: bool,
        ERRNPASS: bool,
        ERRSTOP: bool,
        RES1: u3,
        RMEEN: u2,
        SDeviceEn: bool,
        PROT: u7,
        DbgSwEnable: bool,
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
        BE: bool,
        LA: bool,
        LD: bool,
        RES0: u29,
    });

    pub const ahb3_ahb5_hprot = struct {
        pub const CSW = AP_Register(0xD00, packed struct(u32) {
            SIZE: AccessSize,
            RES0: u1,
            AddrInc: AddressIncrement,
            DeviceEn: bool,
            TrInProg: bool,
            Mode: u4,
            Type: u3,
            @"HPROT[6]": bool,
            ERRNPASS: bool,
            ERRSTOP: bool,
            RES1: u5,
            SDeviceEn: bool,
            Data: bool, // HPROT[0]
            Priviledged: bool, // HPROT[1]
            Bufferable: bool, // HPROT[2]
            Cacheable: bool, // HPROT[3]
            Allocate: bool, // HPROT[4]
            MasterType: bool,
            HNONSEC: bool,
            DbgSwEnable: bool,
        });
    };

    pub const ahb5 = struct {
        pub const CSW = AP_Register(0xD00, packed struct(u32) {
            SIZE: AccessSize,
            RES0: u1,
            AddrInc: AddressIncrement,
            DeviceEn: bool,
            TrInProg: bool,
            Mode: u4,
            Type: u4,
            ERRNPASS: bool,
            ERRSTOP: bool,
            RES1: u5,
            SDeviceEn: bool,
            Data: bool, // HPROT[0]
            Priviledged: bool, // HPROT[1]
            Bufferable: bool, // HPROT[2]
            @"HPROT[3&4&6]": bool,
            RES2: u1,
            MasterType: bool,
            HNONSEC: bool,
            DbgSwEnable: bool,
        });
    };
};
