const std = @import("std");
const microzig = @import("microzig");

pub const microzig_options: microzig.Options = .{
    .logFn = microzig.hal.uart.log,
};

const uart = microzig.hal.uart.instance.num(1);
const uart_tx = microzig.hal.gpio.num(8);

pub fn main() !void {
    uart_tx.set_function(.uart);
    uart.apply(.{
        .clock_config = microzig.hal.clock_config,
    });
    microzig.hal.uart.init_logger(uart);

    std.log.info("HA HA HA!!! Hijacked control", .{});
    while (true) {
        std.log.info("HA!", .{});
        microzig.hal.time.sleep_ms(1_000);
    }
}
