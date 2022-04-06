const std = @import("std");
const toml = @import("toml");

const assert = std.debug.assert;

const common = @import("common.zig");

const string = []const u8;

const Kilo = 1024;
const Mega = Kilo * 1024;
const Giga = Mega * 1024;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const Test_Suite = struct {
    const Self = @This();
    const Tests_List = std.ArrayList(Test);

    path: string,
    continue_on_fail: bool = false,
    tests: Tests_List,

    pub fn init(_allocator: std.mem.Allocator, path: string) !Self {
        return Self{
            .path = path,
            .tests = Tests_List.init(_allocator),
        };
    }

    pub fn deinit(self: *Test_Suite) void {
        self.tests.deinit();
    }

    pub fn format(value: *const Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        try writer.print("Test_Suite{{{s}, {}, {s}}}", .{ value.path, value.continue_on_fail, value.tests.items });
    }
};

const Test = struct {
    const Self = @This();

    name: string,
    input: string,
    output: string,
    output_err: string,
    exit_code: i64,

    pub fn format(value: *const Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        try writer.print("Test{{{s}}}", .{value.name});
    }
};

fn toml_to_suite(table: *toml.Table) !Test_Suite {
    assert(std.mem.eql(u8, table.name, ""));

    var path_val = table.keys.get("path") orelse {
        common.ewriteln("Missing key 'path' required", .{});
        return error.Missing_Required_Key;
    };
    if (path_val != .String) {
        common.ewriteln("Expected String for 'path' got {s}", .{@tagName(path_val)});
        return error.Wrong_Value_Type;
    }

    var res = try Test_Suite.init(allocator, path_val.String);

    if (table.keys.get("continue_on_fail")) |cof| {
        if (cof != .Boolean) {
            common.ewriteln("Expected Boolean for 'continue_on_fail' got {s}", .{@tagName(cof)});
            return error.Wrong_Value_Type;
        }
        res.continue_on_fail = cof.Boolean;
    }

    var iterator = table.keys.valueIterator();
    while (iterator.next()) |val| {
        if (val.* != .Table) continue;
        var raw_test = val.Table;
        var t: Test = undefined;

        inline for (@typeInfo(Test).Struct.fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "name")) {
                t.name = raw_test.name;
            } else {
                var field_value = raw_test.keys.get(field.name) orelse {
                    common.ewriteln("Missing required key '" ++ field.name ++ "' on test {s}", .{raw_test.name});
                    return error.Missing_Required_Key;
                };

                const required_field_type = comptime switch (field.field_type) {
                    string => toml.Value.String,
                    i64 => toml.Value.Integer,
                    else => @compileError("Implement!"),
                };

                if (required_field_type != field_value) {
                    common.ewriteln("Expected " ++ @tagName(required_field_type) ++ " for '" ++ field.name ++ "' on {s} got {s}", .{ raw_test.name, @tagName(field_value) });
                    return error.Wrong_Value_Type;
                }

                @field(t, field.name) = @field(field_value, @tagName(required_field_type));
            }
        }

        try res.tests.append(t);
    }

    return res;
}

/// Calculates the absolute path of the executable relative to the
/// directory of the tests.toml file. Returns if the path of the
/// executable is already absolute.
fn fix_exe_path(suite: *Test_Suite, config_path: string) !void {
    if (std.fs.path.isAbsolute(suite.path)) {
        return;
    }

    var dir = std.fs.path.dirname(config_path) orelse &[_]u8{};
    var joined = try std.fs.path.join(allocator, &.{ dir, suite.path });
    defer allocator.free(joined);
    suite.path = try std.fs.realpathAlloc(allocator, joined);
}

fn run_suite(suite: *Test_Suite) !void {
    _ = suite;

    for (suite.tests.items) |t| {
        common.write("{s}", .{t.name});
        var i: usize = 0;
        while (i < (70 - t.name.len)) : (i += 1) {
            common.write(".", .{});
        }

        // @todo(may): actually run the program and test outputs/exit_code
        var exit_code: i64 = undefined;
        var output: []u8 = undefined;
        var output_err: []u8 = undefined;
        try run_test(suite.path, t, &exit_code, &output, &output_err);

        var fail = false;
        if (exit_code != t.exit_code) {
            fail = true;
            common.writeln("FAIL", .{});
            common.writeln("    > Expected exit code {} got {}", .{ t.exit_code, exit_code });
        }

        if (!std.mem.eql(u8, output, t.output)) {
            if (!fail) {
                common.writeln("FAIL", .{});
            }
            fail = true;
            common.writeln("    > Expected output '{s}' got '{s}'", .{ t.output, output });
        }

        if (!std.mem.eql(u8, output_err, t.output_err)) {
            if (!fail) {
                common.writeln("FAIL", .{});
            }
            fail = true;
            common.writeln("    > Expected output_err '{s}' got '{s}'", .{ t.output_err, output_err });
        }

        if (!fail) {
            common.writeln("OK", .{});
        } else if (!suite.continue_on_fail) {
            break;
        }
    }
}

pub const FILE = opaque {};
pub extern "c" fn mkfifo(path: [*:0]const u8, mode: c_int) c_int;
pub extern "c" fn run(path: [*:0]const u8, program_args: [*][*:0]const u8, arg_count: u32, stdout_fh: c_int, stderr_fh: c_int) c_int;

// TODO: Send data over a pipe/shared memory to avoid
//       writing it first to disk, closing the files,
//       opening the files again and reading them...
fn run_test(path: string, t: Test, exit_code: *i64, output: *[]u8, output_err: *[]u8) !void {
    const stdout_path = "/tmp/test_runner_stdout";
    const stderr_path = "/tmp/test_runner_stderr";

    // Assemble the cmd
    var cmd = try allocator.allocSentinel(u8, (path.len), 0);
    defer allocator.free(cmd);
    std.mem.copy(u8, cmd, path);

    // Assemble arguments
    var start: usize = 0;
    var args = std.ArrayList([*:0]u8).init(allocator);
    defer {
        // Destroy? We should call free but [*:u8] can't be freed
        // it must be [:u8]...
        for (args.items) |e| allocator.destroy(e);
        args.deinit();
    }
    for (t.input) |c, i| {
        if (c == ' ') {
            if (start != i) {
                var arg = try allocator.allocSentinel(u8, i - start, 0);
                std.mem.copy(u8, arg, t.input[start..i]);
                try args.append(arg);
            }
            start = i + 1;
        } else if (i == (t.input.len - 1)) {
            var arg = try allocator.allocSentinel(u8, i + 1 - start, 0);
            std.mem.copy(u8, arg, t.input[start..(i + 1)]);
            try args.append(arg);
        }
    }

    // create tmp files
    std.fs.cwd().deleteFile(stdout_path) catch {};
    std.fs.cwd().deleteFile(stderr_path) catch {};
    var stdout_fh = try std.fs.cwd().createFile(stdout_path, .{ .read = true, .mode = 0o666 });
    var stderr_fh = try std.fs.cwd().createFile(stderr_path, .{ .read = true, .mode = 0o666 });

    // Execute programm
    exit_code.* = run(cmd, args.items.ptr, @intCast(u32, args.items.len), stdout_fh.handle, stderr_fh.handle);

    // Cleanup
    stdout_fh.close();
    stderr_fh.close();

    // Read Outputs
    output.* = try std.fs.cwd().readFileAlloc(allocator, stdout_path, 100 * Mega);
    output_err.* = try std.fs.cwd().readFileAlloc(allocator, stderr_path, 100 * Mega);
}

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

    var file_content = file.readToEndAlloc(allocator, 100 * Mega) catch |err| {
        common.ewriteln("Unable to read tests.toml file.", .{});
        common.ewriteln("  Hint: {s}", .{@errorName(err)});
        return;
    };
    // defer allocator.free(file_content);

    var table = toml.parseContents(allocator, file_content, null) catch |err| {
        common.ewriteln("Error while parsing tests.toml file.", .{});
        common.ewriteln("  Hint: {s}", .{@errorName(err)});
        return;
    };
    // defer table.deinit();

    var suite = toml_to_suite(table) catch return;
    // defer suite.deinit();

    fix_exe_path(&suite, args[1]) catch |err| {
        common.ewriteHint("Invalid executable path provided.", err, .{});
        return;
    };

    common.writeln("Running Tests [{s}]", .{args[1]});
    run_suite(&suite) catch |err| {
        common.ewriteHint("Error while running tests.", err, .{});
    };
}
