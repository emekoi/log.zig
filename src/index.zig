//  Copyright (c) 2018 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const std = @import("std");
const builtin = @import("builtin");

const io = std.io;
const os = std.os;

const windows = os.windows;
const posix = os.posix;

const Allocator = std.mem.Allocator;
const Mutex = std.Mutex;

const TtyColor = enum.{
    Red,
    Green,
    Yellow,
    Magenta,
    Cyan,
    Blue,
    Reset,
};

fn Mutexed(comptime T: type) type {
    return struct.{
        const Self = @This();

        mutex: Mutex,
        private_data: T,


        const HeldMutex = struct.{
            value: *T,
            held: Mutex.Held,

            pub fn release(self: HeldMutex) void {
                self.held.release();
            }
        };

        pub fn init(data: T) Self {
            return Self.{
                .mutex = Mutex.init(),
                .private_data = data,
            };
        }

        pub fn acquire(self: *Self) HeldMutex {
            return HeldMutex.{
            // TODO guaranteed allocation elision
                .held = self.mutex.acquire(),
                .value = &self.private_data,
            };
        }
    };
}

pub const FOREGROUND_BLUE = 1;
pub const FOREGROUND_GREEN = 2;
pub const FOREGROUND_AQUA= 3;
pub const FOREGROUND_RED = 4;
pub const FOREGROUND_MAGENTA = 5;
pub const FOREGROUND_YELLOW = 6;


/// different levels of logging
pub const Level = enum.{
    const Self = @This();

    Trace,
    Debug,
    Info,
    Warn,
    Error,
    Fatal,

    fn toString(self: Self) []const u8 {
        return switch (self) {
            Self.Trace => "TRACE",
            Self.Debug => "DEBUG",
            Self.Info =>  "INFO",
            Self.Warn =>  "WARN",
            Self.Error => "ERROR",
            Self.Fatal => "FATAL",
        };
    }

    fn color(self: Self) TtyColor {
        return switch (self) {
            Self.Trace => TtyColor.Blue,
            Self.Debug => TtyColor.Cyan,
            Self.Info =>  TtyColor.Green,
            Self.Warn =>  TtyColor.Yellow,
            Self.Error => TtyColor.Red,
            Self.Fatal => TtyColor.Magenta,
        };
    }
};

pub fn isTty(handle: os.FileHandle) bool {
    if (builtin.os == builtin.Os.windows) {
        var out: windows.DWORD = undefined;
        return windows.GetConsoleMode(handle, &out) == 0;
    } else {
        if (builtin.link_libc) {
            return std.c.isatty(handle) != 0;
        } else {
            return posix.isatty(handle);
        }
    }
}

/// a simple thread-safe logger
pub const Logger = struct.{
    const Self = @This();
    const MutexedOutStream = Mutexed(*io.OutStream(os.File.WriteError));

    file: os.File,
    file_stream: os.File.OutStream,
    out_stream: ?MutexedOutStream,

    level: Mutexed(Level),
    quiet: Mutexed(bool),
    use_color: bool,
    use_bright: bool,
    
    /// create `Logger`.
    pub fn new(file: os.File, use_color: bool) Self {
        var result = Self.{
            .file = file,
            .file_stream = undefined,
            .out_stream = undefined,
            .level = Mutexed(Level).init(Level.Trace),
            .quiet = Mutexed(bool).init(false),
            .use_color = use_color,
            .use_bright = true,
        };
        result.file_stream = result.file.outStream();
        return result;
    }

    // can't be done in `Logger.new` because of no copy-elision
    fn getOutStream(self: *Self) MutexedOutStream {
        if (self.out_stream) |out_stream| {
            return out_stream;
        } else {
            self.out_stream = MutexedOutStream.init(&self.file_stream.stream);
            return self.out_stream.?;
        }
    }

    fn setTtyColorWindows(self: *Self, color: TtyColor) void {
        // basically static vars in c
        const Context = struct.{
            var attrs: windows.WORD = undefined;
            var init_attrs = false;
        };

        if (!Context.init_attrs) {
            Context.init_attrs = true;
            var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            // TODO handle error
            _ = windows.GetConsoleScreenBufferInfo(self.file.handle, &info);
            Context.attrs = info.wAttributes;
        }

        // TODO handle errors
        const bright = if (self.use_bright) windows.FOREGROUND_INTENSITY else u16(0);
        _ = windows.SetConsoleTextAttribute(self.file.handle, switch (color) {
            TtyColor.Red     => FOREGROUND_RED | bright,
            TtyColor.Green   => FOREGROUND_GREEN | bright,
            TtyColor.Yellow  => FOREGROUND_YELLOW | bright,
            TtyColor.Magenta => FOREGROUND_MAGENTA | bright,
            TtyColor.Cyan    => FOREGROUND_AQUA | bright,
            TtyColor.Blue    => FOREGROUND_BLUE | bright,
            TtyColor.Reset   => Context.attrs,
        });
    }

    fn setTtyColor(self: *Self, color: TtyColor) void {
        if (builtin.os == builtin.Os.windows and !isTty(self.file.handle)) {
            self.setTtyColorWindows(color);
        } else {
            var out = self.getOutStream();
            var out_held = out.acquire();
            defer out_held.release();

            const bright = if (self.use_bright) "\x1b[1m" else "";

            switch (color) {
                TtyColor.Red     => out_held.value.*.print("{}\x1b[31m", bright) catch return,
                TtyColor.Green   => out_held.value.*.print("{}\x1b[32m", bright) catch return,
                TtyColor.Yellow  => out_held.value.*.print("{}\x1b[33m", bright) catch return,
                TtyColor.Magenta => out_held.value.*.print("{}\x1b[35m", bright) catch return,
                TtyColor.Cyan    => out_held.value.*.print("{}\x1b[36m", bright) catch return,
                TtyColor.Blue    => out_held.value.*.print("{}\x1b[34m", bright) catch return,
                TtyColor.Reset   => out_held.value.*.write("\x1b[0m") catch return,
            }
        }
    }

    /// enable or disable color.
    pub fn setColor(self: *Self, use_color: bool) void {
        self.use_color = use_color;
    }

    /// enable or disable bright versions of the colors.
    pub fn setBright(self: *Self, use_bright: bool) void {
        self.use_bright = use_bright;
    }

    /// set the minimum logging level.
    pub fn setLevel(self: *Self, level: Level) void {
        var held = self.level.acquire();
        defer held.release();
        held.value.* = level;
    }

    /// outputs to stderr if true. true by default.
    pub fn setQuiet(self: *Self, quiet: bool) void {
        var held = self.quiet.acquire();
        defer held.release();
        held.value.* = quiet;
    }

    /// TODO error union or `catch return`?
    /// general purpose log function.
    pub fn log(self: *Self, level: Level, comptime fmt: []const u8, args: ...) void {
        const level_held = self.level.acquire();
        defer level_held.release();

        if (@enumToInt(level) < @enumToInt(level_held.value.*)) {
            return;
        }

        var out = self.getOutStream();
        var out_held = out.acquire();
        defer out_held.release();
        var out_stream = out_held.value.*;

        const quiet_held = self.quiet.acquire();
        defer quiet_held.release();

        /// TODO get time as a string
        /// TODO get filename and number
        // time includes the year

        if (!quiet_held.value.*) {
            if (self.use_color and self.file.isTty()) {
                out_stream.print("{} ", os.time.timestamp()) catch return;
                self.setTtyColor(level.color());
                out_stream.print("[{}]", level.toString()) catch return;
                self.setTtyColor(TtyColor.Reset);
                out_stream.print(": ") catch return;

                // out_stream.print("\x1b[90m{}:{}:", filename, line);
                // self.resetTtyColor();

            } else {
                out_stream.print("{} [{s5}]: ", os.time.timestamp(), level.toString()) catch return;
            }
            out_stream.print(fmt, args) catch return;
            out_stream.print("\n") catch return;
        }

        /// TODO add ability for log files

        // log_file.print("{} [{s5}]: ", "time", level.toString());
        // log_file.print(fmt, args);
        // log_file.print("\n");
    }

    /// log at level `Level.Trace`.
    pub fn logTrace(self: *Self, comptime fmt: []const u8, args: ...) void {
        self.log(Level.Trace, fmt, args);
    }

    /// log at level `Level.Debug`.
    pub fn logDebug(self: *Self, comptime fmt: []const u8, args: ...) void {
        self.log(Level.Debug, fmt, args);
    }

    /// log at level `Level.Info`.
    pub fn logInfo(self: *Self, comptime fmt: []const u8, args: ...) void {
        self.log(Level.Info, fmt, args);
    }

    /// log at level `Level.Warn`.
    pub fn logWarn(self: *Self, comptime fmt: []const u8, args: ...) void {
        self.log(Level.Warn, fmt, args);
    }

    /// log at level `Level.Error`.
    pub fn logError(self: *Self, comptime fmt: []const u8, args: ...) void {
        self.log(Level.Error, fmt, args);
    }

    /// log at level `Level.Fatal`.
    pub fn logFatal(self: *Self, comptime fmt: []const u8, args: ...) void {
        self.log(Level.Fatal, fmt, args);
    }
};

test "log_with_color" {
    var logger = Logger.new(try io.getStdOut(), true);
    std.debug.warn("\n");

    logger.logTrace("hi");
    logger.logDebug("hey");
    logger.logInfo("hello");
    logger.logWarn("greetings");
    logger.logError("salutations");
    logger.logFatal("goodbye");
}

fn worker(logger: *Logger) void {
    logger.logTrace("hi");
    os.time.sleep(100);
    logger.logDebug("hey");
    os.time.sleep(100);
    logger.logInfo("hello");
    os.time.sleep(100);
    logger.logWarn("greetings");
    os.time.sleep(100);
    logger.logError("salutations");
    os.time.sleep(100);
    logger.logFatal("goodbye");
    os.time.sleep(1000000000);
}


test "log_thread_safe" {
    var logger = Logger.new(try io.getStdOut(), true);
    std.debug.warn("\n");

    const thread_count = 10;
    var threads: [thread_count]*std.os.Thread = undefined;
    
    for (threads) |*t| {
        t.* = try std.os.spawnThread(&logger, worker);
    }

    for (threads) |t| {
        t.wait();
    }
}
