const std = @import("std");

const libusb = @import("../libusb.zig");
const c = libusb.c;

const Probe = @import("../Probe.zig");
const ARM_DebugInterface = @import("../arch/ARM_DebugInterface.zig");

const CMSIS_DAP = @This();

dev: CMSIS_DAP_Device,
dap_index: u8 = 0,

buf: []u8,

adi: ARM_DebugInterface,

// TODO: implement read/write repeated functions

pub fn create(allocator: std.mem.Allocator, filter: libusb.DeviceIterator.Filter) !*CMSIS_DAP {
    var device_it: libusb.DeviceIterator = try libusb.DeviceIterator.init(filter);
    defer device_it.deinit();

    while (try device_it.next()) |device| {
        return create_with_device(allocator, device) catch |err| switch (err) {
            error.InvalidDevice => continue,
            else => return err,
        };
    } else return error.NoDeviceFound;
}

pub fn create_with_device(
    allocator: std.mem.Allocator,
    device: ?*c.struct_libusb_device,
) !*CMSIS_DAP {
    const dev: CMSIS_DAP_Device = try .init(device);
    errdefer dev.deinit();

    const buf = try allocator.alloc(u8, dev.packet_size);
    errdefer allocator.free(buf);

    const cmsis_dap: *CMSIS_DAP = try allocator.create(CMSIS_DAP);
    errdefer allocator.destroy(cmsis_dap);

    cmsis_dap.* = .{
        .dev = dev,
        .buf = buf,
        .adi = .{
            .allocator = allocator,
            .vtable = &.{
                .swj_sequence = adi_swj_sequence_impl,
                .raw_reg_read = adi_raw_reg_read_impl,
                .raw_reg_write = adi_raw_reg_write_impl,
                .raw_reg_read_repeated = adi_raw_reg_read_repeated_impl,
                .raw_reg_write_repeated = adi_raw_reg_write_repeated_impl,
            },
            .active_protocol = .swd,
        },
    };

    return cmsis_dap;
}

pub fn destroy(cmsis_dap: *CMSIS_DAP) void {
    const allocator = cmsis_dap.adi.allocator;

    cmsis_dap.adi.deinit();
    cmsis_dap.dev.deinit();

    allocator.free(cmsis_dap.buf);
    allocator.destroy(cmsis_dap);
}

pub fn probe(cmsis_dap: *CMSIS_DAP) Probe {
    return .{
        .ptr = cmsis_dap,
        .vtable = &.{
            .destroy = destroy_erased,
            .attach = attach,
            .detach = detach,
            .arm_debug_interface = arm_debug_interface,
        },
    };
}

fn destroy_erased(ptr: *anyopaque) void {
    const cmsis_dap: *CMSIS_DAP = @ptrCast(@alignCast(ptr));
    cmsis_dap.destroy();
}

fn attach(ptr: *anyopaque, speed: Probe.ProtocolSpeed) Probe.AttachError!void {
    const cmsis_dap: *CMSIS_DAP = @ptrCast(@alignCast(ptr));

    _ = cmsis_dap.connect(switch (cmsis_dap.adi.active_protocol) {
        .swd => .swd,
        .jtag => .jtag,
    }) catch |err| {
        std.log.err("failed to connect to probe: {t}", .{err});
        return error.AttachFailed;
    };
    errdefer cmsis_dap.disconnect() catch |err| {
        std.log.err("failed to disconnect from probe: {t}", .{err});
    };

    cmsis_dap.transfer_configure(2, 32, 32) catch |err| {
        std.log.err("failed to configure transfers: {t}", .{err});
        return error.AttachFailed;
    };

    std.log.debug("setting SWJ clock to {f}", .{speed});
    cmsis_dap.swj_clock(@intFromEnum(speed)) catch |err| {
        std.log.err("failed to set SWJ clock: {t}", .{err});
        return error.AttachFailed;
    };
}

fn detach(ptr: *anyopaque) void {
    const cmsis_dap: *CMSIS_DAP = @ptrCast(@alignCast(ptr));

    cmsis_dap.disconnect() catch |err| {
        std.log.err("failed to disconnect from probe: {t}", .{err});
    };
}

fn arm_debug_interface(ptr: *anyopaque) ?*ARM_DebugInterface {
    const cmsis_dap: *CMSIS_DAP = @ptrCast(@alignCast(ptr));
    return &cmsis_dap.adi;
}

pub fn connect(cmsis_dap: CMSIS_DAP, maybe_port: ?Protocol) !Protocol {
    cmsis_dap.buf[0] = @intFromEnum(CommandId.connect);
    cmsis_dap.buf[1] = if (maybe_port) |port| @intFromEnum(port) else 0;
    _ = try cmsis_dap.dev.write(cmsis_dap.buf);

    _ = try cmsis_dap.dev.read(cmsis_dap.buf);
    if (cmsis_dap.buf[0] != 0x02) return bad();
    if (cmsis_dap.buf[1] == 0x00) return error.FailedToConnect;
    const port = std.enums.fromInt(Protocol, cmsis_dap.buf[1]) orelse return bad();
    return port;
}

pub fn disconnect(cmsis_dap: CMSIS_DAP) !void {
    cmsis_dap.buf[0] = @intFromEnum(CommandId.disconnect);
    _ = try cmsis_dap.dev.write(cmsis_dap.buf);

    _ = try cmsis_dap.dev.read(cmsis_dap.buf);
    if (cmsis_dap.buf[0] != 0x03) return bad();
    try check_status(cmsis_dap.buf[1]);
}

pub fn reset_target(cmsis_dap: CMSIS_DAP) !void {
    cmsis_dap.buf[0] = @intFromEnum(CommandId.reset);
    _ = try cmsis_dap.dev.write(cmsis_dap.buf);

    _ = try cmsis_dap.dev.read(cmsis_dap.buf);
    if (cmsis_dap.buf[0] != 0x0A) return bad();
    try check_status(cmsis_dap.buf[1]);
    if (cmsis_dap.buf[2] != 0x01) return error.NoResetSequence;
}

pub fn swj_clock(cmsis_dap: CMSIS_DAP, clock: u32) !void {
    cmsis_dap.buf[0] = @intFromEnum(CommandId.swj_clock);
    std.mem.writeInt(u32, cmsis_dap.buf[1..5], clock, .little);

    _ = try cmsis_dap.dev.write(cmsis_dap.buf);

    _ = try cmsis_dap.dev.read(cmsis_dap.buf);
    if (cmsis_dap.buf[0] != 0x11) return bad();
    try check_status(cmsis_dap.buf[1]);
}

pub fn transfer_configure(cmsis_dap: CMSIS_DAP, idle_cycles: u8, wait_retries: u16, match_retries: u16) !void {
    cmsis_dap.buf[0] = @intFromEnum(CommandId.transfer_configure);
    cmsis_dap.buf[1] = idle_cycles;
    std.mem.writeInt(u16, cmsis_dap.buf[2..4], wait_retries, .little);
    std.mem.writeInt(u16, cmsis_dap.buf[4..6], match_retries, .little);
    _ = try cmsis_dap.dev.write(cmsis_dap.buf);

    _ = try cmsis_dap.dev.read(cmsis_dap.buf);
    if (cmsis_dap.buf[0] != 0x04) return bad();
    try check_status(cmsis_dap.buf[1]);
}

pub fn swj_sequence(
    cmsis_dap: *CMSIS_DAP,
    bit_count: u8,
    sequence: u64,
) !void {
    if (bit_count == 0 or bit_count > 64) return error.InvalidBitCount;

    cmsis_dap.buf[0] = @intFromEnum(CommandId.swj_sequence);
    cmsis_dap.buf[1] = bit_count;
    @memset(cmsis_dap.buf[2..][0..@sizeOf(u64)], 0);
    std.mem.writeVarPackedInt(cmsis_dap.buf[2..], 0, bit_count, sequence, .little);

    _ = try cmsis_dap.dev.write(cmsis_dap.buf);

    _ = try cmsis_dap.dev.read(cmsis_dap.buf);
    if (cmsis_dap.buf[0] != 0x12) return bad();
    try check_status(cmsis_dap.buf[1]);
}

pub fn reg_read(cmsis_dap: *CMSIS_DAP, port: ARM_DebugInterface.RegisterPort, addr: u4) !u32 {
    cmsis_dap.buf[0] = @intFromEnum(CommandId.transfer);
    cmsis_dap.buf[1] = cmsis_dap.dap_index;
    cmsis_dap.buf[2] = 1;
    cmsis_dap.buf[3] = @bitCast(TransferRequest{
        .port = switch (port) {
            .dp => .dp,
            .ap => .ap,
        },
        .cmd = .read,
        .addr23 = @intCast(addr >> 2),
    });
    _ = try cmsis_dap.dev.write(cmsis_dap.buf);

    _ = try cmsis_dap.dev.read(cmsis_dap.buf);
    const transfer_response: TransferResponse = @bitCast(cmsis_dap.buf[2]);
    if (transfer_response.protocol_error) return error.SWD_Protocol;
    switch (transfer_response.ack) {
        .ok => {},
        .wait => return error.WaitTimeout,
        .fault => return error.MemoryFault,
        .no_ack => return error.NoResponse,
    }
    return std.mem.readInt(u32, cmsis_dap.buf[3..7], .little);
}

pub fn reg_write(cmsis_dap: *CMSIS_DAP, port: ARM_DebugInterface.RegisterPort, addr: u4, value: u32) !void {
    cmsis_dap.buf[0] = @intFromEnum(CommandId.transfer);
    cmsis_dap.buf[1] = cmsis_dap.dap_index;
    cmsis_dap.buf[2] = 1;
    cmsis_dap.buf[3] = @bitCast(TransferRequest{
        .port = switch (port) {
            .dp => .dp,
            .ap => .ap,
        },
        .cmd = .write,
        .addr23 = @intCast(addr >> 2),
    });
    std.mem.writeInt(u32, cmsis_dap.buf[4..8], value, .little);
    _ = try cmsis_dap.dev.write(cmsis_dap.buf);

    _ = try cmsis_dap.dev.read(cmsis_dap.buf);
    const transfer_response: TransferResponse = @bitCast(cmsis_dap.buf[2]);
    if (transfer_response.protocol_error) return error.SWD_Protocol;
    switch (transfer_response.ack) {
        .ok => {},
        .wait => return error.WaitTimeout,
        .fault => return error.MemoryFault,
        .no_ack => return error.NoResponse,
    }
}

pub fn reg_read_repeated(cmsis_dap: *CMSIS_DAP, port: ARM_DebugInterface.RegisterPort, addr: u4, data: []u32) !void {
    const words_per_cmd = (cmsis_dap.buf.len - 5) / @sizeOf(u32);

    var offset: usize = 0;
    while (offset < data.len) {
        const words: u16 = @intCast(@min(words_per_cmd, data.len - offset)); // shouldn't fail as buf.len is max 512

        cmsis_dap.buf[0] = @intFromEnum(CommandId.transfer_block);
        cmsis_dap.buf[1] = cmsis_dap.dap_index;
        std.mem.writeInt(u16, cmsis_dap.buf[2..4], words, .little);
        cmsis_dap.buf[4] = @bitCast(TransferRequest{
            .port = switch (port) {
                .dp => .dp,
                .ap => .ap,
            },
            .cmd = .read,
            .addr23 = @intCast(addr >> 2),
        });

        _ = try cmsis_dap.dev.write(cmsis_dap.buf);

        _ = try cmsis_dap.dev.read(cmsis_dap.buf);
        const transfer_response: TransferResponse = @bitCast(cmsis_dap.buf[3]);
        if (transfer_response.protocol_error) return error.SWD_Protocol;
        switch (transfer_response.ack) {
            .ok => {},
            .wait => return error.WaitTimeout,
            .fault => return error.MemoryFault,
            .no_ack => return error.NoResponse,
        }

        for (data[offset..][0..words], 0..) |*value, i| {
            value.* = std.mem.readInt(u32, cmsis_dap.buf[4 + i * 4..][0..4], .little);
        }

        offset += words;
    }
}

pub fn reg_write_repeated(cmsis_dap: *CMSIS_DAP, port: ARM_DebugInterface.RegisterPort, addr: u4, data: []const u32) !void {
    const words_per_cmd = (cmsis_dap.buf.len - 5) / @sizeOf(u32);

    var offset: usize = 0;
    while (offset < data.len) {
        const words: u16 = @intCast(@min(words_per_cmd, data.len - offset)); // shouldn't fail as buf.len is max 512

        cmsis_dap.buf[0] = @intFromEnum(CommandId.transfer_block);
        cmsis_dap.buf[1] = cmsis_dap.dap_index;
        std.mem.writeInt(u16, cmsis_dap.buf[2..4], words, .little);
        cmsis_dap.buf[4] = @bitCast(TransferRequest{
            .port = switch (port) {
                .dp => .dp,
                .ap => .ap,
            },
            .cmd = .write,
            .addr23 = @intCast(addr >> 2),
        });

        for (data[offset..][0..words], 0..) |value, i| {
            std.mem.writeInt(u32, cmsis_dap.buf[5 + i * 4..][0..4], value, .little);
        }

        _ = try cmsis_dap.dev.write(cmsis_dap.buf);

        _ = try cmsis_dap.dev.read(cmsis_dap.buf);
        const transfer_response: TransferResponse = @bitCast(cmsis_dap.buf[3]);
        if (transfer_response.protocol_error) return error.SWD_Protocol;
        switch (transfer_response.ack) {
            .ok => {},
            .wait => return error.WaitTimeout,
            .fault => return error.MemoryFault,
            .no_ack => return error.NoResponse,
        }

        offset += words;
    }
}

fn adi_swj_sequence_impl(adi: *ARM_DebugInterface, bit_count: u8, sequence: u64) ARM_DebugInterface.Error!void {
    const cmsis_dap: *CMSIS_DAP = @fieldParentPtr("adi", adi);

    cmsis_dap.swj_sequence(bit_count, sequence) catch |err| {
        std.log.debug("failed to send SWJ sequence: {t}", .{err});
        return error.CommandFailed;
    };
}

fn adi_raw_reg_read_impl(adi: *ARM_DebugInterface, port: ARM_DebugInterface.RegisterPort, addr: u4) ARM_DebugInterface.Error!u32 {
    const cmsis_dap: *CMSIS_DAP = @fieldParentPtr("adi", adi);

    return cmsis_dap.reg_read(port, addr) catch |err| {
        std.log.debug("failed to read register: {t}", .{err});
        return error.CommandFailed;
    };
}

fn adi_raw_reg_write_impl(adi: *ARM_DebugInterface, port: ARM_DebugInterface.RegisterPort, addr: u4, value: u32) ARM_DebugInterface.Error!void {
    const cmsis_dap: *CMSIS_DAP = @fieldParentPtr("adi", adi);

    cmsis_dap.reg_write(port, addr, value) catch |err| {
        std.log.debug("failed to write register: {t}", .{err});
        return error.CommandFailed;
    };
}

fn adi_raw_reg_read_repeated_impl(adi: *ARM_DebugInterface, port: ARM_DebugInterface.RegisterPort, addr: u4, data: []u32) ARM_DebugInterface.Error!void {
    const cmsis_dap: *CMSIS_DAP = @fieldParentPtr("adi", adi);

    return cmsis_dap.reg_read_repeated(port, addr, data) catch |err| {
        std.log.debug("failed to read register: {t}", .{err});
        return error.CommandFailed;
    };
}

fn adi_raw_reg_write_repeated_impl(adi: *ARM_DebugInterface, port: ARM_DebugInterface.RegisterPort, addr: u4, data: []const u32) ARM_DebugInterface.Error!void {
    const cmsis_dap: *CMSIS_DAP = @fieldParentPtr("adi", adi);

    cmsis_dap.reg_write_repeated(port, addr, data) catch |err| {
        std.log.debug("failed to write register: {t}", .{err});
        return error.CommandFailed;
    };
}

fn bad() error{BadProbeResponse} {
    return error.BadProbeResponse;
}

fn check_status(ret: u8) !void {
    if (ret != 0x00) return error.CommandFailed;
}

// We only support v2 for now, we should make this an union otherwise
pub const CMSIS_DAP_Device = struct {
    handle: *c.struct_libusb_device_handle,
    interface_num: u8,
    ep_in: u8,
    ep_out: u8,
    packet_size: u32,

    pub fn init(device: ?*c.struct_libusb_device) !CMSIS_DAP_Device {
        var maybe_config_descriptor: ?*c.struct_libusb_config_descriptor = undefined;
        _ = try libusb.call(c.libusb_get_active_config_descriptor(device, &maybe_config_descriptor));
        defer c.libusb_free_config_descriptor(maybe_config_descriptor);
        const config_descriptor = maybe_config_descriptor.?;

        for (0..config_descriptor.bNumInterfaces) |interface_index| {
            const interface = config_descriptor.interface[interface_index];

            alt_setting_loop: for (0..@intCast(interface.num_altsetting)) |altsetting_index| {
                const alt_setting = interface.altsetting[altsetting_index];

                if (alt_setting.bInterfaceClass != c.LIBUSB_CLASS_VENDOR_SPEC)
                    continue;

                var maybe_ep_out: ?u8 = null;
                var maybe_ep_in: ?u8 = null;

                for (0..alt_setting.bNumEndpoints) |endpoint_index| {
                    const endpoint = alt_setting.endpoint[endpoint_index];

                    if (endpoint.bmAttributes & c.LIBUSB_TRANSFER_TYPE_MASK != c.LIBUSB_TRANSFER_TYPE_BULK)
                        continue;
                    switch (endpoint.bEndpointAddress & c.LIBUSB_ENDPOINT_DIR_MASK) {
                        c.LIBUSB_ENDPOINT_OUT => {
                            if (maybe_ep_out != null)
                                continue :alt_setting_loop;
                            maybe_ep_out = endpoint.bEndpointAddress;
                        },
                        c.LIBUSB_ENDPOINT_IN => {
                            if (maybe_ep_in != null)
                                continue :alt_setting_loop;
                            maybe_ep_in = endpoint.bEndpointAddress;
                        },
                        else => unreachable,
                    }
                }

                const ep_out = maybe_ep_out orelse continue;
                const ep_in = maybe_ep_in orelse continue;

                return CMSIS_DAP_Device.try_init_internal(
                    device,
                    alt_setting.bInterfaceNumber,
                    alt_setting.bAlternateSetting,
                    ep_in,
                    ep_out,
                ) catch continue;
            }
        }

        return error.InvalidDevice;
    }

    fn try_init_internal(device: ?*c.struct_libusb_device, interface_num: u8, alt_setting_num: u8, ep_in: u8, ep_out: u8) !CMSIS_DAP_Device {
        _ = alt_setting_num;

        var handle: ?*c.struct_libusb_device_handle = undefined;
        _ = try libusb.call(c.libusb_open(device, &handle));
        errdefer c.libusb_close(handle);

        _ = try libusb.call(c.libusb_claim_interface(handle, interface_num));
        errdefer _ = c.libusb_release_interface(handle, interface_num);

        // TODO: with this we get timeout on second program run
        // _ = try libusb.call(c.libusb_set_interface_alt_setting(handle, alt_setting.bInterfaceNumber, alt_setting.bAlternateSetting));

        var dev: CMSIS_DAP_Device = .{
            .handle = handle.?,
            .interface_num = interface_num,
            .ep_in = ep_in,
            .ep_out = ep_out,
            .packet_size = undefined,
        };

        _ = try dev.write(&.{
            @intFromEnum(CommandId.info),
            @intFromEnum(Info_ID.packet_size),
        });

        var resp: [4]u8 = undefined;
        const n = try dev.read(&resp);
        if (n != 4) return bad();
        if (resp[0] != 0x00) return bad();
        if (resp[1] != 0x02) return bad();
        dev.packet_size = std.mem.readInt(u16, resp[2..4], .little);

        return dev;
    }

    pub fn deinit(dev: CMSIS_DAP_Device) void {
        _ = c.libusb_release_interface(dev.handle, dev.interface_num);
        c.libusb_close(dev.handle);
    }

    pub fn read(dev: CMSIS_DAP_Device, buf: []u8) libusb.USB_Error!usize {
        var n: c_int = undefined;
        _ = try libusb.call(c.libusb_bulk_transfer(dev.handle, dev.ep_in, buf.ptr, @intCast(buf.len), &n, 1000));
        return @intCast(n);
    }

    pub fn write(dev: CMSIS_DAP_Device, buf: []const u8) libusb.USB_Error!usize {
        var n: c_int = undefined;
        _ = try libusb.call(c.libusb_bulk_transfer(dev.handle, dev.ep_out, @constCast(buf.ptr), @intCast(buf.len), &n, 1000));
        std.debug.assert(buf.len == @as(usize, @intCast(n)));
        return @intCast(n);
    }
};

pub const CommandId = enum(u8) {
    info = 0x00,
    connect = 0x02,
    disconnect = 0x03,
    transfer_configure = 0x04,
    transfer = 0x05,
    transfer_block = 0x06,
    reset = 0x0A,
    swj_clock = 0x11,
    swj_sequence = 0x12,
    queue_commands = 0x7E,
    execute_commands = 0x7F,
};

pub const Info_ID = enum(u8) {
    vendor_name = 0x01,
    product_name = 0x02,
    serial_number = 0x03,
    protocol_version = 0x04,
    target_device_vendor = 0x05,
    target_device_name = 0x06,
    target_board_vendor = 0x07,
    target_board_name = 0x08,
    product_firmware_version = 0x09,
    capabilities = 0xF0,
    test_domain_timer = 0xF1,
    uart_receive_buffer_size = 0xFB,
    uart_transmit_buffer_size = 0xFC,
    swo_trace_buffer_size = 0xFD,
    packet_count = 0xFE,
    packet_size = 0xFF,
};

pub const Protocol = enum(u2) {
    swd = 1,
    jtag = 2,
};

pub const Port = enum(u1) {
    dp = 0,
    ap = 1,
};

pub const TransferRequest = packed struct(u8) {
    port: Port,
    cmd: enum(u1) { write = 0, read = 1 },
    addr23: u2,
    value_match: bool = false,
    match_mask: bool = false,
    reserved6: u1 = 0,
    include_timestamp: bool = false,
};

pub const TransferResponse = packed struct(u8) {
    ack: enum(u3) {
        ok = 1,
        wait = 2,
        fault = 4,
        no_ack = 7,
    },
    protocol_error: bool,
    value_mismatch: bool,
    reserved5: u3 = 0,
};
