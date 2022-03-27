const std = @import("std");

const common = @import("common.zig");

const Kilo = 1024;
const Mega = Kilo * 1024;
const Giga = Mega * 1024;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() void {
    // defer arena.deinit();
    const args = std.process.argsAlloc(allocator) catch unreachable;
    //defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        common.ewriteln("No path to tests.toml provided.", .{});
        return;
    }

    var file = std.fs.cwd().openFile(args[1], .{ .mode = .read_only }) catch {
        common.ewriteln("Unable to open the tests.toml file.", .{});
        return;
    };
    defer file.close();

    var file_content = file.readToEndAlloc(allocator, 0 * Mega) catch |err| {
        common.ewriteln("Unable to read tests.toml file.", .{});
        common.ewriteln("  Hint: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(file_content);

    common.writeln("Running Tests [{s}]", .{args[1]});
    common.writeln("{s}", .{file_content});
}
