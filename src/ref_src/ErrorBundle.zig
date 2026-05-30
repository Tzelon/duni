const std = @import("std");
const ErrorBundle = @This();
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

//TODO: ErrorBundle should render errors into stdout we the relevant information.

pub fn renderToStdErr(eb: ErrorBundle) void {
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr();
    return renderToWriter(eb, options, stderr.writer()) catch return;
}
