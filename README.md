# *log.zig*
a thread-safe logging library for zig.

## usage
```
const log = @import("log");
const Logger = log.Logger;

pub fn main() void {
    var logger = Logger.new(true);
    logger.logWarn("crime is afoot");
}
```
