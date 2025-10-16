const std = @import("std");

pub const c = @cImport({
    @cInclude("libusb.h");
});

var instances: std.atomic.Value(usize) = .init(0);

pub fn lib_init() USB_Error!void {
    if (instances.fetchAdd(1, .acq_rel) == 0)
        _ = try call(c.libusb_init(null));
}

pub fn lib_deinit() void {
    std.debug.assert(instances.load(.acquire) != 0);
    if (instances.fetchSub(1, .acq_rel) == 1)
        c.libusb_exit(null);
}

pub fn call(ret: isize) USB_Error!isize {
    switch (ret) {
        c.LIBUSB_ERROR_ACCESS => return error.Access,
        c.LIBUSB_ERROR_NO_DEVICE => return error.NoDevice,
        c.LIBUSB_ERROR_NOT_FOUND => return error.NotFound,
        c.LIBUSB_ERROR_BUSY => return error.Busy,
        c.LIBUSB_ERROR_TIMEOUT => return error.Timeout,
        c.LIBUSB_ERROR_OVERFLOW => return error.Overflow,
        c.LIBUSB_ERROR_PIPE => return error.Pipe,
        c.LIBUSB_ERROR_INTERRUPTED => return error.Interrupted,
        c.LIBUSB_ERROR_NO_MEM => return error.NoMemory,
        c.LIBUSB_ERROR_INVALID_PARAM => return error.InvalidParam,
        c.LIBUSB_ERROR_IO => return error.IO,
        c.LIBUSB_ERROR_OTHER => return error.Other,
        else => return ret,
    }
}

pub const Device = *c.struct_libusb_device;
pub const Handle = *c.struct_libusb_device_handle;

pub const DeviceIterator = struct {
    filter: Filter,
    list: [*c]?*c.struct_libusb_device,
    len: usize,
    index: usize = 0,

    pub const Filter = struct {
        vid: ?u16 = null,
        pid: ?u16 = null,
        serial_number: ?u8 = null,
    };

    pub fn init(filter: Filter) USB_Error!DeviceIterator {
        try lib_init();
        errdefer lib_deinit();

        var list: [*c]?*c.struct_libusb_device = undefined;
        const len: usize = @intCast(try call(c.libusb_get_device_list(null, &list)));
        errdefer c.libusb_free_device_list(list, 1);

        return .{
            .filter = filter,
            .list = list,
            .len = len,
        };
    }

    pub fn deinit(self: *DeviceIterator) void {
        c.libusb_free_device_list(self.list, 1);
        lib_deinit();
    }

    pub fn next(self: *DeviceIterator) USB_Error!?Device {
        while (self.index < self.len) {
            defer self.index += 1;
            const device = self.list[self.index].?;
            var device_desc: c.struct_libusb_device_descriptor = undefined;
            _ = try call(c.libusb_get_device_descriptor(device, &device_desc));

            if (self.filter.vid) |vid| {
                if (device_desc.idVendor != vid) continue;
            }
            if (self.filter.pid) |pid| {
                if (device_desc.idProduct != pid) continue;
            }
            if (self.filter.serial_number) |serial_number| {
                if (device_desc.iSerialNumber != serial_number) continue;
            }

            return self.list[self.index];
        } else return null;
    }

    pub fn reset(self: *DeviceIterator) void {
        self.index = 0;
    }
};

pub const USB_Error = error{
    Access,
    NoDevice,
    NotFound,
    Busy,
    Timeout,
    Overflow,
    Pipe,
    Interrupted,
    NoMemory,
    InvalidParam,
    IO,
    Other,
    Unknown,
};
