const std = @import("std");
const SDL = @import("sdl");

const Display = @import("display.zig").Display;
const Instruction = @import("instruction.zig").Instruction;
const RawInstruction = @import("instruction.zig").RawInstruction;

const FONT = [_]u8{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

pub const System = struct {
    alloc: std.mem.Allocator,
    rng: std.Random,
    memory: *[0x1000]u8,
    display: Display,
    counter: u16,
    index: u16,
    registers: [16]u8,
    stack: std.ArrayList(u16),
    delay: i64,

    pub fn init(program: []const u8, display: Display, alloc: std.mem.Allocator, rng: std.Random) !System {
        var memory = try alloc.create([0x1000]u8);
        @memcpy(memory[0x200 .. 0x200 + program.len], program);
        @memcpy(memory[0x50..0xA0], &FONT);

        return System{
            .alloc = alloc,
            .rng = rng,
            .memory = memory,
            .display = display,
            .counter = 0x200,
            .index = 0,
            .registers = [_]u8{0} ** 16,
            .stack = std.ArrayList(u16).init(alloc),
            .delay = std.time.milliTimestamp(),
        };
    }

    pub fn destroy(self: System) void {
        self.alloc.destroy(self.memory);
        self.display.destroy();
        self.stack.deinit();
    }

    fn fetch(self: *System) Instruction {
        const raw = RawInstruction{ .aabb = .{ .aa = self.memory[self.counter], .bb = self.memory[self.counter + 1] } };
        self.counter += 2;
        return Instruction.decode(raw);
    }

    fn execute(self: *System, instruction: Instruction) !void {
        switch (instruction) {
            Instruction.no_op => {},
            Instruction.clear => try self.display.clear(),
            Instruction.@"return" => self.counter = self.stack.pop(),
            Instruction.jump => |args| self.counter = args.target,
            Instruction.call => |args| {
                try self.stack.append(self.counter);
                self.counter = args.target;
            },
            Instruction.if_neq_val => |args| if (self.registers[args.vx] == args.value) {
                self.counter += 2;
            },
            Instruction.if_eq_val => |args| if (self.registers[args.vx] != args.value) {
                self.counter += 2;
            },
            Instruction.if_neq_reg => |args| if (self.registers[args.vx] == self.registers[args.vy]) {
                self.counter += 2;
            },
            Instruction.set_const => |args| self.registers[args.vx] = args.value,
            Instruction.add_const => |args| self.registers[args.vx] +%= args.value,
            Instruction.set_reg => |args| self.registers[args.vx] = self.registers[args.vy],
            Instruction.@"or" => |args| {
                self.registers[args.vx] |= self.registers[args.vy];
                self.registers[0xF] = 0;
            },
            Instruction.@"and" => |args| {
                self.registers[args.vx] &= self.registers[args.vy];
                self.registers[0xF] = 0;
            },
            Instruction.xor => |args| {
                self.registers[args.vx] ^= self.registers[args.vy];
                self.registers[0xF] = 0;
            },
            Instruction.add_reg => |args| {
                const result = @addWithOverflow(self.registers[args.vx], self.registers[args.vy]);
                self.registers[args.vx] = result[0];
                self.registers[0xF] = result[1];
            },
            Instruction.sub_reg => |args| {
                const result = @subWithOverflow(self.registers[args.vx], self.registers[args.vy]);
                self.registers[args.vx] = result[0];
                self.registers[0xF] = 1 - result[1];
            },
            Instruction.shr_reg => |args| {
                const value = self.registers[args.vy];
                self.registers[args.vx] = value >> 1;
                self.registers[0xF] = value & 1;
            },
            Instruction.reg_sub => |args| {
                const result = @subWithOverflow(self.registers[args.vy], self.registers[args.vx]);
                self.registers[args.vx] = result[0];
                self.registers[0xF] = 1 - result[1];
            },
            Instruction.shl_reg => |args| {
                const result = @shlWithOverflow(self.registers[args.vy], 1);
                self.registers[args.vx] = result[0];
                self.registers[0xF] = result[1];
            },
            Instruction.if_eq_reg => |args| if (self.registers[args.vx] != self.registers[args.vy]) {
                self.counter += 2;
            },
            Instruction.set_index => |args| self.index = args.value,
            Instruction.jump_offset => |args| self.counter = args.target + self.registers[0x0],
            Instruction.random => |args| self.registers[args.vx] = self.rng.int(u8) & args.mask,
            Instruction.draw => |args| {
                // reset the flags register
                self.registers[15] = 0;

                // get start pos from registers and wrap
                const x: usize = self.registers[args.vx] & 63;
                const y: usize = self.registers[args.vy] & 31;

                // access pixel data
                var data = try self.display.lock();
                defer data.release();

                // each row in the sprite, moving downwards
                for (0..args.height) |row| {
                    // don't go past the edge of the screen
                    if (y + row >= 32) break;

                    // a row of 8 pixels is stored in a byte
                    const line = self.memory[self.index + row];

                    // each pixel in the row, moving to the left
                    for (0..8) |col| {
                        // don't go past the edge of the screen
                        if (x + col >= 64) break;

                        // pointer to the screen pixel (a byte)
                        const pixel = &data.inner.pixels[(x + col) + (y + row) * 64];

                        // grab the col'th bit from the sprite (from high to low)
                        const new = (line >> @intCast(7 - col)) & 1;
                        // grab any bit from screen pixel (should all be the same)
                        const old = pixel.* & 1;

                        if (new == 1 and old == 1) {
                            pixel.* = 0;
                            // sprite hit an existing pixel, set the flag
                            self.registers[15] = 1;
                        } else if (new == 1 and old == 0) {
                            pixel.* = 0xFF;
                        }
                    }
                }
            },
            Instruction.if_not_key => |args| if (SDL.getKeyboardState().isPressed(toScancode(@truncate(self.registers[args.vx])))) {
                self.counter += 2;
            },
            Instruction.if_key => |args| if (!SDL.getKeyboardState().isPressed(toScancode(@truncate(self.registers[args.vx])))) {
                self.counter += 2;
            },
            Instruction.get_delay => |args| {
                const remaining_ms = @max(0, self.delay - std.time.milliTimestamp());
                const remaining_60ths = @min(0xFF, (remaining_ms * 60) / 1000);
                self.registers[args.vx] = remaining_60ths;
            },
            Instruction.get_key => |args| {
                const keyboard = SDL.getKeyboardState();
                var pressed: ?u4 = null;
                for (0x0..(0xF + 1)) |key| {
                    if (keyboard.isPressed(toScancode(@truncate(key)))) {
                        pressed = @truncate(key);
                        break;
                    }
                }
                if (pressed) |key| {
                    self.registers[args.vx] = key;
                } else {
                    self.counter -= 2;
                }
            },
            Instruction.set_delay => |args| {
                const offset_ms = (@as(u32, @intCast(self.registers[args.vx])) * 1000) / 60;
                const timestamp = std.time.milliTimestamp() + offset_ms;
                self.delay = timestamp;
            },
            // set_sound
            Instruction.add_index => |args| {
                self.index += self.registers[args.vx];
            },
            Instruction.get_character => |args| {
                const char = self.registers[args.vx] & 0x0F;
                self.index = 0x50 + char * 5;
            },
            Instruction.binary_coded_decimal => |args| {
                var value = self.registers[args.vx];
                for (0..3) |n| {
                    self.memory[self.index + 2 - n] = value % 10;
                    value /= 10;
                }
            },
            Instruction.store => |args| {
                for (0..(@as(usize, args.vx) + 1)) |vn| {
                    self.memory[self.index + vn] = self.registers[vn];
                }
                self.index += @as(u16, args.vx) + 1;
            },
            Instruction.load => |args| {
                for (0..(@as(usize, args.vx) + 1)) |vn| {
                    self.registers[vn] = self.memory[self.index + vn];
                }
                self.index += @as(u16, args.vx) + 1;
            },
            else => undefined,
        }
    }

    pub fn step(self: *System) !void {
        const instruction = self.fetch();
        try self.execute(instruction);
    }
};

fn toScancode(n: u4) SDL.Scancode {
    return switch (n) {
        0x0 => .@"0",
        0x1 => .@"1",
        0x2 => .@"2",
        0x3 => .@"3",
        0x4 => .@"4",
        0x5 => .@"5",
        0x6 => .@"6",
        0x7 => .@"7",
        0x8 => .@"8",
        0x9 => .@"9",
        0xA => .a,
        0xB => .b,
        0xC => .c,
        0xD => .d,
        0xE => .e,
        0xF => .f,
    };
}
