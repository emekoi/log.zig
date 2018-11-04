# *log.zig*
a cross-platform, thread-safe logging library for zig.

## usage
```
const io = @import("std").io;
const log = @import("log");
const Logger = log.Logger;

pub fn main() !void {
    var logger = Logger.new(try io.getStdOut(), true);
    logger.setBright(false);
    logger.logWarn("crime is afoot");
    logger.setColor(false);
    logger.logInfo("crime has been stopped");
}
```

## supports
  - window's console
  - any terminal supporting ansi escape codes
