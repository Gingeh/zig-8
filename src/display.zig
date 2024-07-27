const SDL = @import("sdl");

pub const Display = struct {
    window: SDL.Window,
    renderer: SDL.Renderer,
    texture: SDL.Texture,
    vblank: bool,
    lastPresent: u32,

    const PixelLock = struct {
        inner: SDL.Texture.PixelData,
        display: *Display,

        pub fn release(self: *PixelLock) void {
            self.inner.release();
            if (self.display.vblank) {
                while ((SDL.getTicks() - self.display.lastPresent) * 60 < 1000) SDL.delay(1);
                self.display.lastPresent = SDL.getTicks();
            }
            self.display.present() catch unreachable;
        }
    };

    pub fn init(title: [:0]const u8, scale: usize, vblank: bool) !Display {
        try SDL.init(.{
            .video = true,
            .events = true,
            .audio = true,
        });

        const window = try SDL.createWindow(
            title,
            .{ .centered = {} },
            .{ .centered = {} },
            64 * scale,
            32 * scale,
            .{ .vis = .shown },
        );

        const renderer = try SDL.createRenderer(window, null, .{});

        const texture = try SDL.createTexture(renderer, .rgb332, .streaming, 64, 32);

        return Display{
            .window = window,
            .renderer = renderer,
            .texture = texture,
            .vblank = vblank,
            .lastPresent = 0,
        };
    }

    pub fn destroy(self: Display) void {
        self.texture.destroy();
        self.renderer.destroy();
        self.window.destroy();
        SDL.quit();
    }

    pub fn present(self: *Display) !void {
        try self.renderer.copy(self.texture, null, null);
        self.renderer.present();
    }

    pub fn lock(self: *Display) !PixelLock {
        return PixelLock{ .inner = try self.texture.lock(null), .display = self };
    }

    pub fn clear(self: *Display) !void {
        var data = try self.lock();
        defer data.release();
        @memset(data.inner.pixels[0..(64 * 32)], 0x00);
    }
};
