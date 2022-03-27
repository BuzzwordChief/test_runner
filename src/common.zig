const std = @import("std");

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const stdin = std.io.getStdErr().reader();

pub fn write(comptime fmt: []const u8, args: anytype) void {
    stdout.print(fmt, args) catch unreachable;
}

pub fn writeln(comptime fmt: []const u8, args: anytype) void {
    write(fmt ++ "\n", args);
}

pub fn ewrite(comptime fmt: []const u8, args: anytype) void {
    stderr.print(fmt, args) catch unreachable;
}

pub fn ewriteln(comptime fmt: []const u8, args: anytype) void {
    ewrite(fmt ++ "\n", args);
}

pub fn ewriteHint(comptime fmt: []const u8, err: anytype, args: anytype) void {
    ewriteln(fmt, args);
    ewriteln("  Hint: {s}", .{@errorName(err)});
}
