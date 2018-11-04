//  Copyright (c) 2018 emekoi
//
//  This library is free software; you can redistribute it and/or modify it
//  under the terms of the MIT license. See LICENSE for details.
//

const std = @import("std");
const io = std.io;
const os = std.os;

const time = os.time;

const Allocator = std.mem.Allocator;
const Mutex = std.Mutex;

/// TODO use these
const TtyColor = enum.{
    Red,
    Green,
    Cyan,
    White,
    Dim,
    Bold,
    Reset,
};

fn setTtyColor(tty_color: TtyColor) void {
    const S = struct.{
        var attrs: windows.WORD = undefined;
        var init_attrs = false;
    };
    if (!S.init_attrs) {
        S.init_attrs = true;
        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        // TODO handle error
        _ = windows.GetConsoleScreenBufferInfo(stderr_file.handle, &info);
        S.attrs = info.wAttributes;
    }

    // TODO handle errors
    switch (tty_color) {
        TtyColor.Red => {
            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_RED | windows.FOREGROUND_INTENSITY);
        },
        TtyColor.Green => {
            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_GREEN | windows.FOREGROUND_INTENSITY);
        },
        TtyColor.Cyan => {
            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_GREEN | windows.FOREGROUND_BLUE | windows.FOREGROUND_INTENSITY);
        },
        TtyColor.White, TtyColor.Bold => {
            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_RED | windows.FOREGROUND_GREEN | windows.FOREGROUND_BLUE | windows.FOREGROUND_INTENSITY);
        },
        TtyColor.Dim => {
            _ = windows.SetConsoleTextAttribute(stderr_file.handle, windows.FOREGROUND_INTENSITY);
        },
        TtyColor.Reset => {
            _ = windows.SetConsoleTextAttribute(stderr_file.handle, S.attrs);
        },
    }
}

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

    fn color(self: Self) []const u8 {
        return switch (self) {
            Self.Trace => "\x1b[94m",
            Self.Debug => "\x1b[36m",
            Self.Info =>  "\x1b[32m",
            Self.Warn =>  "\x1b[33m",
            Self.Error => "\x1b[31m",
            Self.Fatal => "\x1b[35m",
        };
    }
};

/// a simple thread-safe logger
pub const Logger = struct.{
    const Self = @This();

    var stderr_file: os.File = undefined;
    var stderr_file_out_stream: os.File.OutStream = undefined;
    var stderr_stream: ?Mutexed(*io.OutStream(os.File.WriteError)) = null;

    level: Mutexed(Level),
    quiet: Mutexed(bool),
    use_color: bool,

    /// create `Logger`.
    pub fn new(use_color: bool) Self {
        return Self.{
            .level = Mutexed(Level).init(Level.Trace),
            .quiet = Mutexed(bool).init(false),
            .use_color = use_color,
        };
    }

    fn getStderrStream() !Mutexed(*io.OutStream(os.File.WriteError)) {
        if (stderr_stream) |st| {
            return st;
        } else {
            stderr_file = try io.getStdErr();
            stderr_file_out_stream = stderr_file.outStream();
            const st = &stderr_file_out_stream.stream;
            stderr_stream = Mutexed(*io.OutStream(os.File.WriteError)).init(st);
            return stderr_stream.?;
        }
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

        var stderr = getStderrStream() catch return;
        var stderr_held = stderr.acquire();
        defer stderr_held.release();

        const quiet_held = self.quiet.acquire();
        defer quiet_held.release();

        /// TODO get time as a string
        // time includes the year

        if (!quiet_held.value.*) {
            if (self.use_color) {
                stderr_held.value.*.print("{} {}[{s5}]\x1b[0m: ", "time", level.color(), level.toString()) catch return;
                /// TODO get filename and number

                // stderr_held.value.*.print("{} {}[{s5}]\x1b[0m: \x1b[90m{}:{}:\x1b[0m", "time", level.color(), level.toString(), filename, line);
            } else {
                stderr_held.value.*.print("{} [{s5}]: ", "time", level.toString()) catch return;
            }
            stderr_held.value.*.print(fmt, args) catch return;
            stderr_held.value.*.print("\n") catch return;
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
    var logger = Logger.new(true);
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
    logger.logDebug("hey");
    logger.logInfo("hello");
    logger.logWarn("greetings");
    logger.logError("salutations");
    logger.logFatal("goodbye");
}


test "log_thread_safe" {
    var logger = Logger.new(true);
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
