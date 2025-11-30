const std = @import("std");
const log = std.log.scoped(.ADI);

const ARM_DebugInterface = @This();

const Timeout = @import("../Timeout.zig");

pub const Mem_AP = @import("ARM_DebugInterface/Mem_AP.zig");
pub const Cortex_M = @import("ARM_DebugInterface/Cortex_M.zig");

allocator: std.mem.Allocator,

vtable: *const Vtable,
active_protocol: Protocol,

active_dp_state: ?DP_State = null,
other_dp_states: std.AutoHashMapUnmanaged(DP_Address, DP_State) = .empty,

pub const Error = error{
    CommandFailed,
};

pub const Vtable = struct {
    /// Send swj sequence with a max of 64 bits
    swj_sequence: *const fn (adi: *ARM_DebugInterface, bit_count: u8, sequence: u64) Error!void,
    raw_reg_read: *const fn (adi: *ARM_DebugInterface, port: RegisterPort, addr: u4) Error!u32,
    raw_reg_write: *const fn (adi: *ARM_DebugInterface, port: RegisterPort, addr: u4, value: u32) Error!void,
    raw_reg_read_repeated: *const fn (adi: *ARM_DebugInterface, port: RegisterPort, addr: u4, data: []u32) Error!void = default_raw_reg_read_repeated,
    raw_reg_write_repeated: *const fn (adi: *ARM_DebugInterface, port: RegisterPort, addr: u4, data: []const u32) Error!void = default_raw_reg_write_repeated,
};

pub fn deinit(adi: *ARM_DebugInterface) void {
    adi.other_dp_states.deinit(adi.allocator);
}

pub fn reinit(adi: *ARM_DebugInterface) !void {
    adi.active_dp_state = null;

    // Clear DP states because we may have to run the setup again.
    adi.other_dp_states.clearRetainingCapacity();
}

pub fn dp_reg_read(
    adi: *ARM_DebugInterface,
    dp: DP_Address,
    address: DP_RegisterAddress,
) !u32 {
    try adi.select_dp(adi.allocator, dp);
    if (address.bank) |bank| try adi.select_dp_bank(bank);
    return adi.raw_reg_read(.dp, address.offset);
}

pub fn dp_reg_write(
    adi: *ARM_DebugInterface,
    dp: DP_Address,
    address: DP_RegisterAddress,
    value: u32,
) !void {
    try adi.select_dp(adi.allocator, dp);
    if (address.bank) |bank| try adi.select_dp_bank(bank);
    return adi.raw_reg_write(.dp, address.offset, value);
}

pub fn ap_reg_read(
    adi: *ARM_DebugInterface,
    ap: AP_Address,
    address: u12,
) !u32 {
    try adi.select_dp(adi.allocator, ap.dp);
    try adi.select_ap_and_ap_bank(ap, address);
    return adi.raw_reg_read(.ap, @truncate(address));
}

pub fn ap_reg_write(
    adi: *ARM_DebugInterface,
    ap: AP_Address,
    address: u12,
    value: u32,
) !void {
    try adi.select_dp(adi.allocator, ap.dp);
    try adi.select_ap_and_ap_bank(ap, address);
    return adi.raw_reg_write(.ap, @truncate(address), value);
}

pub fn ap_reg_read_repeated(
    adi: *ARM_DebugInterface,
    ap: AP_Address,
    address: u12,
    data: []u32,
) !void {
    try adi.select_dp(adi.allocator, ap.dp);
    try adi.select_ap_and_ap_bank(ap, address);
    try adi.raw_reg_read_repeated(.ap, @truncate(address), data);
}

pub fn ap_reg_write_repeated(
    adi: *ARM_DebugInterface,
    ap: AP_Address,
    address: u12,
    value: []const u32,
) !void {
    try adi.select_dp(adi.allocator, ap.dp);
    try adi.select_ap_and_ap_bank(ap, address);
    return adi.raw_reg_write_repeated(.ap, @truncate(address), value);
}

pub fn swj_sequence(
    adi: *ARM_DebugInterface,
    bit_count: u8,
    sequence: u64,
) Error!void {
    return adi.vtable.swj_sequence(adi, bit_count, sequence);
}

pub fn raw_reg_read(
    adi: *ARM_DebugInterface,
    port: RegisterPort,
    addr: u4,
) Error!u32 {
    return adi.vtable.raw_reg_read(adi, port, addr);
}

pub fn raw_reg_write(
    adi: *ARM_DebugInterface,
    port: RegisterPort,
    addr: u4,
    value: u32,
) Error!void {
    return adi.vtable.raw_reg_write(adi, port, addr, value);
}

pub fn raw_reg_read_repeated(
    adi: *ARM_DebugInterface,
    port: RegisterPort,
    addr: u4,
    data: []u32,
) Error!void {
    return adi.vtable.raw_reg_read_repeated(adi, port, addr, data);
}

pub fn raw_reg_write_repeated(
    adi: *ARM_DebugInterface,
    port: RegisterPort,
    addr: u4,
    data: []const u32,
) Error!void {
    return adi.vtable.raw_reg_write_repeated(adi, port, addr, data);
}

pub fn default_raw_reg_read_repeated(
    adi: *ARM_DebugInterface,
    port: RegisterPort,
    addr: u4,
    data: []u32,
) Error!void {
    for (data) |*value| {
        value.* = try adi.vtable.raw_reg_read(adi, port, addr);
    }
}

pub fn default_raw_reg_write_repeated(
    adi: *ARM_DebugInterface,
    port: RegisterPort,
    addr: u4,
    data: []const u32,
) Error!void {
    for (data) |value| {
        try adi.vtable.raw_reg_write(adi, port, addr, value);
    }
}

fn select_dp(adi: *ARM_DebugInterface, allocator: std.mem.Allocator, dp_address: DP_Address) !void {
    if (adi.active_dp_state) |state| {
        if (state.address.eql(dp_address)) return;

        try adi.other_dp_states.put(allocator, state.address, state);
        adi.active_dp_state = null;

        try adi.debug_port_connect(dp_address);
    } else {
        try adi.debug_port_setup(dp_address);
    }

    if (adi.other_dp_states.get(dp_address)) |dp_state| {
        adi.active_dp_state = dp_state;
    } else {
        // We haven't started this debug port yet

        try adi.debug_port_start();

        const dpidr: regs.dp.DPIDR.Type = @bitCast(try adi.raw_reg_read(.dp, regs.dp.DPIDR.addr.offset));

        const dp_state: DP_State = .{
            .address = dp_address,
            .dpidr = dpidr,
            .current_select = switch (dpidr.VERSION) {
                .DPv1, .DPv2 => blk: {
                    const init_select: regs.dp.SELECT_V1.Type = .{};
                    try adi.raw_reg_write(.dp, regs.dp.SELECT_V1.addr.offset, @bitCast(init_select));
                    break :blk .{ .v1 = init_select };
                },
                .DPv3 => blk: {
                    // Set DP bank to SELECT1.bank to be able to read it
                    const init_select: regs.dp.SELECT_V3.Type = .{
                        .DPBANKSEL = regs.dp.SELECT1.addr.bank.?,
                    };
                    try adi.raw_reg_write(.dp, regs.dp.SELECT_V1.addr.offset, @bitCast(init_select));

                    break :blk .{ .v3 = .{
                        .select = init_select,
                        .select1 = @bitCast(try adi.raw_reg_read(.dp, regs.dp.SELECT1.addr.offset)),
                    } };
                },
            },
        };

        adi.active_dp_state = dp_state;
    }
}

fn select_dp_bank(adi: *ARM_DebugInterface, bank: u4) !void {
    if (adi.active_dp_state) |*active_dp| {
        var current_select = active_dp.current_select;
        var should_update = false;

        switch (current_select) {
            .v1 => |*current_select_v1| if (current_select_v1.DPBANKSEL != bank) {
                current_select_v1.DPBANKSEL = bank;
                should_update = true;
            },
            .v3 => |*current_select_v3| if (current_select_v3.select.DPBANKSEL != bank) {
                current_select_v3.select.DPBANKSEL = bank;
                should_update = true;
            },
        }

        if (should_update) {
            try adi.raw_reg_write(.dp, regs.dp.SELECT_V1.addr.offset, switch (active_dp.current_select) {
                .v1 => |current_select_v1| @bitCast(current_select_v1),
                .v3 => |current_select_v3| @bitCast(current_select_v3.select),
            });
        }
    } else return error.NoActiveDP;
}

fn select_ap_and_ap_bank(adi: *ARM_DebugInterface, ap: AP_Address, address: u12) !void {
    if (adi.active_dp_state) |*active_dp| {
        var current_select = active_dp.current_select;

        var should_update = false;

        switch (current_select) {
            .v1 => |*current_select_v1| switch (ap.address) {
                .v1 => |apsel| {
                    if (current_select_v1.APSEL != apsel) {
                        current_select_v1.APSEL = apsel;
                        should_update = true;
                    }

                    if (current_select_v1.APBANKSEL != address >> 4) {
                        current_select_v1.APBANKSEL = @truncate(address >> 4);
                        should_update = true;
                    }
                },
                .v2 => |_| return error.AP_V2_NotSupported,
            },
            .v3 => |*current_select_v3| switch (ap.address) {
                .v1 => |_| return error.AP_V1_NotSupported,
                .v2 => |ap_addr| {
                    const current_addr = current_select_v3.select.ADDR + @as(u60, current_select.v3.select1.ADDR) << 28;
                    const expected_addr = ap_addr + address;
                    if (current_addr != expected_addr) {
                        current_select_v3.select.ADDR = @truncate(expected_addr);
                        current_select_v3.select1.ADDR = @truncate(expected_addr >> 28);
                        should_update = true;
                    }
                },
            },
        }

        if (should_update) {
            switch (current_select) {
                .v1 => |current_select_v1| try adi.raw_reg_write(.dp, regs.dp.SELECT_V1.addr.offset, @bitCast(current_select_v1)),
                .v3 => |*current_select_v3| {
                    current_select_v3.select.DPBANKSEL = regs.dp.SELECT_V1.addr.bank.?;
                    try adi.raw_reg_write(.dp, regs.dp.SELECT.addr, @bitCast(current_select_v3.select));
                    try adi.raw_reg_write(.dp, regs.dp.SELECT_V1.addr.offset, @bitCast(current_select_v3.select1));
                },
            }
            active_dp.current_select = current_select;
        }
    } else return error.NoActiveDP;
}

// SWJ Sequences (used in dp select).

fn alert_sequence(adi: *ARM_DebugInterface) !void {
    // >=8 cycles high
    try adi.swj_sequence(8, 0xFF);

    // 128-bit selection alert sequence
    try adi.swj_sequence(64, 0x86852D95_6209F392);
    try adi.swj_sequence(64, 0x19BC0EA2_E3DDAFE9);
}

fn line_reset_sequence(adi: *ARM_DebugInterface) !void {
    // Line reset
    try adi.swj_sequence(51, 0x0007FFFF_FFFFFFFF);
}

// https://open-cmsis-pack.github.io/Open-CMSIS-Pack-Spec/main/html/debug_description.html#debugPortSetup
fn debug_port_setup(adi: *ARM_DebugInterface, dp_address: DP_Address) !void {
    // A multidrop address implies SWD version 2 and dormant state.  In
    // cases where SWD version 2 is used but not multidrop addressing
    // (ex. ADIv6), the SWD version 1 sequence is attempted before trying
    // the SWD version 2 sequence.
    var is_v1: bool = dp_address == .default;

    for (0..5) |i| {
        log.debug("trying to setup debug port with address {f}... Attempt {}", .{ dp_address, i + 1 });

        // Line reset
        try adi.line_reset_sequence();

        switch (adi.active_protocol) {
            .swd => {
                if (is_v1) {
                    try adi.swj_sequence(16, 0xE79E);

                    // > 50 cycles SWDIO/TMS High, at least 2 idle cycles (SWDIO/TMS Low).
                    // -> done in debug_port_connect
                } else {
                    // JTAG to dormant
                    try adi.swj_sequence(31, 0x33BBBBBA);

                    // alert sequence
                    try adi.alert_sequence();

                    // 4 cycles low + SWD activation code
                    try adi.swj_sequence(12, 0x1A0);

                    // > 50 cycles SWDIO/TMS High, at least 2 idle cycles (SWDIO/TMS Low).
                    // -> done in debug_port_connect
                }
            },
            .jtag => @panic("TODO"),
        }

        if (adi.debug_port_connect(dp_address)) |_| {
            break;
        } else |_| {
            if (is_v1 and i > 1) {
                // If we've tried SWD version 1 and failed, try SWD version 2
                is_v1 = false;
            }
        }
    } else return error.DebugPortSetupFailed;
}

fn debug_port_connect(adi: *ARM_DebugInterface, dp_address: DP_Address) !void {
    log.debug("connecting to debug port with address {f}...", .{dp_address});

    if (adi.active_protocol == .jtag) return;

    // NOTE: SWD specific

    const timeout: Timeout = try .init(.{
        .after = 100 * std.time.ns_per_ms,
        .sleep_per_tick_ns = 5 * std.time.ns_per_ms,
    });
    while (true) {
        try adi.line_reset_sequence();

        // >=2 cycles low
        try adi.swj_sequence(3, 0b000);

        // Write to TARGETSEL (if multidrop).
        switch (dp_address) {
            .multidrop => |targetsel| {
                const parity = @popCount(targetsel) % 2;
                const data = (@as(u48, parity) << 45) | (@as(u48, targetsel) << 13) | 0x1F99;
                try adi.swj_sequence(6 * 8, data);
            },
            else => {},
        }

        // Read DPIDR to enable SWD interface (SW-DPv1 and SW-DPv2)
        if (adi.raw_reg_read(.dp, 0x0)) |_| {
            break;
        } else |_| {}

        try timeout.tick();
    }

    // Clear WDATAERR, STICKYORUN, STICKYCMP, and STICKYERR bits of CTRL/STAT Register by write to ABORT register
    try adi.raw_reg_write(.dp, 0x0, 0x0000001E);

    // Check we are connected to the right DP (probe-rs)
    switch (dp_address) {
        .multidrop => |targetsel| {
            try adi.raw_reg_write(.dp, 0x8, 0x00000002);
            const target_id = try adi.raw_reg_read(.dp, 0x4);

            try adi.raw_reg_write(.dp, 0x8, 0x00000003);
            const dlpidr = try adi.raw_reg_read(.dp, 0x4);

            const TARGETID_MASK: u32 = 0x0FFF_FFFF;
            const DLPIDR_MASK: u32 = 0xF000_0000;

            const targetid_match = (target_id & TARGETID_MASK) == (targetsel & TARGETID_MASK);
            const dlpdir_match = (dlpidr & DLPIDR_MASK) == (targetsel & DLPIDR_MASK);
            if (!targetid_match or !dlpdir_match) {
                log.err("Target ID and DLPIDR do not match, failed to select debug port. Target ID: {x}, DLPIDR: {x}", .{
                    target_id,
                    dlpidr,
                });
                return error.WrongDP;
            }
        },
        else => {},
    }

    log.debug("connected to debug port", .{});
}

fn debug_port_start(adi: *ARM_DebugInterface) !void {
    log.debug("starting debug port...", .{});

    // Switch to DP Register Bank 0
    try adi.raw_reg_write(.dp, 0x8, 0x00000000);

    // Read DP CTRL/STAT Register and check if CSYSPWRUPACK and CDBGPWRUPACK bits are set
    const ctrl_stat_val = try adi.raw_reg_read(.dp, 0x4);
    const is_powered_down = ctrl_stat_val & 0xA0000000 != 0xA0000000;

    if (ctrl_stat_val & 0x000000B2 != 0) {
        // Clear SWD-DP sticky error bits by writing to DP ABORT
        try adi.raw_reg_write(.dp, 0x0, 0x0000001E);
    }

    if (is_powered_down) {
        // Request Debug/System Power-Up
        try adi.raw_reg_write(.dp, 0x4, 0x50000000);

        // Wait for Power-Up Request to be acknowledged
        const timeout: Timeout = try .init(.{
            .after = 100 * std.time.ns_per_ms,
            .sleep_per_tick_ns = 5 * std.time.ns_per_ms,
        });
        while (try adi.raw_reg_read(.dp, 0x4) & 0xA0000000 != 0xA0000000) {
            try timeout.tick();
        }

        // Init AP Transfer Mode, Transaction Counter, and Lane Mask (Normal Transfer Mode, Include all Byte Lanes)
        try adi.raw_reg_write(.dp, 0x4, 0x50000F00);

        // Clear WDATAERR, STICKYORUN, STICKYCMP, and STICKYERR bits of CTRL/STAT Register by write to ABORT register
        try adi.raw_reg_write(.dp, 0x0, 0x0000001E);
    }

    log.debug("debug port ready", .{});
}

pub const DP_RegisterAddress = struct {
    bank: ?u4,
    offset: u4,
};

pub const DP_Address = union(enum) {
    default,
    multidrop: u32,

    pub fn eql(a: DP_Address, b: DP_Address) bool {
        return switch (a) {
            .default => switch (b) {
                .default => true,
                else => false,
            },
            .multidrop => |targetsel| switch (b) {
                .multidrop => |targetsel2| targetsel == targetsel2,
                else => false,
            },
        };
    }

    pub fn format(self: DP_Address, writer: *std.Io.Writer) !void {
        switch (self) {
            .default => try writer.writeAll("default"),
            .multidrop => |targetsel| try writer.print("multidrop 0x{x}", .{targetsel}),
        }
    }
};

pub const AP_Address = struct {
    dp: DP_Address = .default,
    address: union(enum) {
        v1: u8,
        v2: u60,
    },
};

pub const DP_State = struct {
    address: DP_Address,
    dpidr: regs.dp.DPIDR.Type,
    current_select: CurrentSelect,

    pub const CurrentSelect = union(enum) {
        v1: regs.dp.SELECT_V1.Type,
        v3: struct {
            select: regs.dp.SELECT_V3.Type,
            select1: regs.dp.SELECT1.Type,
        },
    };
};

pub const Protocol = enum {
    swd,
    jtag,
};

pub const RegisterPort = enum {
    dp,
    ap,
};

pub const regs = struct {
    pub const dp = struct {
        pub const ABORT = DP_Register(.{ .bank = null, .offset = 0x0 }, packed struct(u32) {
            DAPABORT: u1 = 0,
            STKCMPCLR: u1 = 0,
            STKERRCLR: u1 = 0,
            WDERRCLR: u1 = 0,
            ORUNDETECTCLR: u1 = 0,
            RES0: u27 = 0,
        });

        // TODO
        pub const DLPIDR = DP_Register(.{ .bank = 0x3, .offset = 0x4 }, packed struct(u32) {
            RESERVED: u32 = 0,
        });

        pub const DPIDR = DP_Register(.{ .bank = null, .offset = 0x0 }, packed struct(u32) {
            RAO: u1,
            DESIGNER: u11,
            VERSION: Version,
            MIN: u1,
            RES0: u3,
            PARTNO: u8,
            REVISION: u4,

            pub const Version = enum(u4) {
                DPv1 = 0x1,
                DPv2 = 0x2,
                DPv3 = 0x3,
            };
        });

        pub const DPIDR1 = DP_Register(.{ .bank = 0x1, .offset = 0x0 }, packed struct(u32) {
            ASIZE: u6 = 0,
            ERRMODE: u1 = 0,
            RES0: u25 = 0,
        });

        pub const CTRL_STAT = DP_Register(.{ .bank = 0x0, .offset = 0x4 }, packed struct(u32) {
            ORUNDETECT: u1 = 0,
            STICKYORUN: u1 = 0,
            TRNMODE: u2 = 0,
            STICKYCMP: u1 = 0,
            STICKYERR: u1 = 0,
            READOK: u1 = 0,
            WDATAERR: u1 = 0,
            MASKLANE: u4 = 0,
            TRNCNT: u12 = 0,
            ERRMODE: u1 = 0,
            RES0: u1 = 0,
            CDBGRSTREQ: u1 = 0,
            CDBGRSTACK: u1 = 0,
            CDBGPWRUPREQ: u1 = 0,
            CDBGPWRUPACK: u1 = 0,
            CSYSPWRUPREQ: u1 = 0,
            CSYSPWRUPACK: u1 = 0,
        });

        pub const RDBUFF = DP_Register(.{ .bank = null, .offset = 0xC }, packed struct(u32) {
            RES0: u32 = 0,
        });

        pub const SELECT_V1 = DP_Register(.{ .bank = null, .offset = 0x8 }, packed struct(u32) {
            DPBANKSEL: u4 = 0,
            APBANKSEL: u4 = 0,
            RES0: u16 = 0,
            APSEL: u8 = 0,
        });

        pub const SELECT_V3 = DP_Register(.{ .bank = null, .offset = 0x8 }, packed struct(u32) {
            DPBANKSEL: u4 = 0,
            ADDR: u28 = 0,
        });

        pub const SELECT1 = DP_Register(.{ .bank = 0x5, .offset = 0x4 }, packed struct(u32) {
            ADDR: u32 = 0,
        });

        pub const TARGETID = DP_Register(.{ .bank = 0x2, .offset = 0x4 }, packed struct(u32) {
            /// This bit is always set to 1
            ALWAYS_ONE: u1 = 1,
            TDESIGNER: u11 = 0,
            TPARTNO: u16 = 0,
            TVERSION: u4 = 0,
        });
    };

    pub const ap = struct {
        pub const IDR = AP_Register(0xDFC, packed struct(u32) {
            TYPE: u4,
            VARIANT: u4,
            RES0: u5,
            CLASS: u4,
            DESIGNER: u11,
            REVISION: u4,
        });
    };
};

pub fn DP_Register(reg_addr: DP_RegisterAddress, T: type) type {
    return struct {
        pub const Type = T;
        pub const addr = reg_addr;

        pub inline fn read(adi: *ARM_DebugInterface, dp: DP_Address) !T {
            return @bitCast(try adi.dp_reg_read(dp, addr));
        }

        pub inline fn write(adi: *ARM_DebugInterface, dp: DP_Address, value: T) !void {
            try adi.dp_reg_write(dp, addr, @bitCast(value));
        }

        pub inline fn modify(adi: *ARM_DebugInterface, dp: DP_Address, value: anytype) !void {
            var new = try read(adi, dp);
            inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
                @field(new, field.name) = @field(value, field.name);
            }
            try write(adi, dp, new);
        }
    };
}

pub fn AP_Register(reg_addr: u12, T: type) type {
    return struct {
        pub const Type = T;
        pub const addr = reg_addr;

        pub inline fn read(adi: *ARM_DebugInterface, ap_address: ARM_DebugInterface.AP_Address) !T {
            return @bitCast(try adi.ap_reg_read(ap_address, addr));
        }

        pub inline fn write(adi: *ARM_DebugInterface, ap_address: ARM_DebugInterface.AP_Address, value: T) !void {
            try adi.ap_reg_write(ap_address, addr, @bitCast(value));
        }

        pub inline fn modify(adi: *ARM_DebugInterface, ap_address: ARM_DebugInterface.AP_Address, value: anytype) !void {
            var new = try read(adi, ap_address);
            inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
                @field(new, field.name) = @field(value, field.name);
            }
            try write(adi, ap_address, new);
        }
    };
}
