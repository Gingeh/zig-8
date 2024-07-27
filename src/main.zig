const std = @import("std");
const SDL = @import("sdl");

const Display = @import("display.zig").Display;
const System = @import("system.zig").System;

const cova = @import("cova");
const CommandT = cova.Command.Base();

const command = CommandT{
    .name = "zig-8",
    .description = "A CHIP-8 emulator written to learn Zig",
    .opts = &.{
        CommandT.OptionT{
            .name = "Rom Path",
            .description = "Path to a .ch8 rom. (required)",
            .long_name = "rom",
            .short_name = 'r',
            .mandatory = true,
            .val = CommandT.ValueT.ofType([]const u8, .{
                .alias_child_type = "path",
            }),
        },
        CommandT.OptionT{
            .name = "Scale",
            .description = "Size of displayed pixels. (default: 10px)",
            .long_name = "scale",
            .short_name = 's',
            .mandatory = false,
            .val = CommandT.ValueT.ofType(usize, .{
                .alias_child_type = "px",
                .default_val = 10,
            }),
        },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try command.init(alloc, .{});
    defer args.deinit();

    var args_iter = try cova.ArgIteratorGeneric.init(alloc);
    defer args_iter.deinit();

    const stdout = std.io.getStdOut().writer();
    cova.parseArgs(&args_iter, CommandT, args, stdout, .{}) catch |err| switch (err) {
        error.UsageHelpCalled => return,
        else => return err,
    };

    const opts = try args.getOpts(.{});

    const display = try Display.init("zig-8", try opts.get("Scale").?.val.getAs(usize));
    const program = try std.fs.cwd().readFileAlloc(alloc, try opts.get("Rom Path").?.val.getAs([]const u8), 0x1000 - 0x200);
    var rng = std.rand.DefaultPrng.init(@truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));

    var system = try System.init(program, display, alloc, rng.random());
    defer system.destroy();
    alloc.free(program);

    mainLoop: while (true) {
        while (SDL.pollEvent()) |ev| {
            if (ev == .quit) break :mainLoop;
        }

        try system.step();
    }
}
