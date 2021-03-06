const std = @import("std");

const assert = std.debug.assert;

const common = @import("common.zig");
const toml = @import("toml.zig");

const string = []const u8;
const Allocator = std.mem.Allocator;

const Kilo = 1024;
const Mega = Kilo * 1024;
const Giga = Mega * 1024;

const RST = "\x1B[0m";
const BLK = "\x1B[0;30m";
const RED = "\x1B[0;31m";
const GRN = "\x1B[0;32m";
const YEL = "\x1B[0;33m";
const BLU = "\x1B[0;34m";
const MAG = "\x1B[0;35m";
const CYN = "\x1B[0;36m";
const WHT = "\x1B[0;37m";
const BBLK = "\x1B[1;30m";
const BRED = "\x1B[1;31m";
const BGRN = "\x1B[1;32m";
const BYEL = "\x1B[1;33m";
const BBLU = "\x1B[1;34m";
const BMAG = "\x1B[1;35m";
const BCYN = "\x1B[1;36m";
const BWHT = "\x1B[1;37m";

const Test_Suite = struct {
    const Self = @This();
    const Tests_List = std.ArrayList(Test);

    path: string,
    continue_on_fail: bool    = false,
    line_endings_strict: bool = false,
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

fn tomlToSuite(allocator: Allocator, table: *toml.Table) !Test_Suite {
    var path_val = table.items.get("path") orelse {
        common.ewriteln("Missing key 'path' required", .{});
        return error.Missing_Required_Key;
    };
    if (path_val != .String) {
        common.ewriteln("Expected String for 'path' got {s}", .{@tagName(path_val)});
        return error.Wrong_Value_Type;
    }

    var res = try Test_Suite.init(allocator, path_val.String);

    if (table.items.get("continue_on_fail")) |cof| {
        if (cof != .Bool) {
            common.ewriteln("Expected Boolean for 'continue_on_fail' got {s}", .{@tagName(cof)});
            return error.Wrong_Value_Type;
        }
        res.continue_on_fail = cof.Bool;
    }
    if (table.items.get("line_endings_strict")) |cof| {
        if (cof != .Bool) {
            common.ewriteln("Expected Boolean for 'line_endings_strict' got {s}", .{@tagName(cof)});
            return error.Wrong_Value_Type;
        }
        res.line_endings_strict = cof.Bool;
    }

    var iterator = table.items.valueIterator();
    while (iterator.next()) |val| {
        if (val.* != .Table) continue;
        var raw_test = val.Table;
        var t: Test = undefined;

        inline for (@typeInfo(Test).Struct.fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "name")) {
                t.name = raw_test.name;
            } else {
                var field_value = raw_test.items.get(field.name) orelse {
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
fn fixExePath(allocator: Allocator, suite: *Test_Suite) !void {
    if (std.fs.path.isAbsolute(suite.path)) {
        return;
    }

    suite.path = try std.fs.cwd().realpathAlloc(allocator, suite.path);
}

fn runSuite(allocator: Allocator, suite: *Test_Suite) !void {
    _ = suite;

    for (suite.tests.items) |t| {
        common.write("{s}", .{t.name});

        var i: usize = (70 - t.name.len);
        while (i != 0) : (i -= 1) {
            common.write(".", .{});
        }

        var result = try runTest(allocator, suite.path, t);
        defer {
            allocator.free(result.stderr);
            allocator.free(result.stdout);
        }

        if (result.term != .Exited) {
            common.writeln(BRED ++ "FAIL" ++ RST, .{});
            common.writeln("    > Program did not exit correctly (exit code could not be attained)", .{});
            return;
        }

        var fail = false;
        if (result.term.Exited != t.exit_code) {
            fail = true;
            common.writeln(BRED ++ "FAIL" ++ RST, .{});
            printDifference("exit code", t.exit_code, result.term.Exited);
        }

        if (!CompareStrings(suite.line_endings_strict, result.stdout, t.output)) {
            if (!fail) {
                common.writeln(BRED ++ "FAIL" ++ RST, .{});
            }
            fail = true;
            printDifference("output", t.output, result.stdout);
        } 

        if (!CompareStrings(suite.line_endings_strict, result.stderr, t.output_err)) {
            if (!fail) {
                common.writeln(BRED ++ "FAIL" ++ RST, .{});
            }
            fail = true;
            printDifference("output_err", t.output_err, result.stderr);
        }

        if (!fail) {
            common.writeln(BGRN ++ "OK" ++ RST, .{});
        } else if (!suite.continue_on_fail) {
            break;
        }
    }
}

/// Compares the two strings. If strict is enabled it ignores differences in line-endings.
/// Returns true if equal.
fn CompareStrings(strict: bool, str1: string, str2: string) bool 
{
    if (strict) 
    {
        return std.mem.eql(u8, str1, str2);
    }
    else 
    {
        if (str1.len == 0 or str2.len == 0) return str1.len == str2.len;

        // Check ignoring line-endings
        var i : u64 = 0;
        while (i < str1.len) : (i += 1)
        {
            if (i >= str2.len) return false;

            if (str1[i] == str2[i]) 
            {
                // Ignored
            }
            else if (str1[i] == '\r' and str2[i] == '\n') 
            {
                if ( (i + 1 < str1.len) and str1[i + 1] == '\n' ) 
                {
                    i += 1;
                } 
                else 
                {
                    return false; // str1 \r got \n
                }
            } 
            else if (str1[i] == '\n' and str2[i] == '\r') 
            {
                if ( (i + 1 < str2.len) and str2[i + 1] == '\n' ) 
                {
                    i += 1;
                } 
                else
                {
                    return false; // str1 \n got \r
                }
            }
            else
            {
                return false;
            }
        }

        return true;
    }
}

fn printDifference(comptime name: string, expected: anytype, got: @TypeOf(expected)) void {
    const format = switch (@TypeOf(expected)) {
        string => "s",
        else => "",
    };

    common.writeln("    > " ++ name ++ " differs:", .{});
    common.writeln("       Expected: " ++ GRN ++ "{" ++ format ++ "}" ++ RST, .{expected});
    common.writeln("       Got     : " ++ RED ++ "{" ++ format ++ "}" ++ RST, .{got});
}

/// switch the cwd to the dir of the path
fn setCwd(allocator: Allocator, path: string) !void {
    var config_path = try std.fs.realpathAlloc(allocator, path);
    defer allocator.free(config_path);

    var dir_path = std.fs.path.dirname(config_path) orelse &([_]u8{std.fs.path.delimiter});
    var dir      = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();

    try dir.setAsCwd();
}

fn runTest(allocator: Allocator, path: string, t: Test) !std.ChildProcess.ExecResult {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(path);
    var start: usize = 0;
    for (t.input) |c, i| {
        if (c == ' ') {
            try argv.append(t.input[start..i]);
            start = i + 1;
        }
    }
    if (start != t.input.len) {
        try argv.append(t.input[start..]);
    }

    return std.ChildProcess.exec(.{ .allocator = allocator, .argv = argv.items });
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        common.ewriteln("Unable to get process arguments", .{});
        return;
    };
    defer std.process.argsFree(allocator, args);

    mainProc(allocator, args);
}

/// Used to easily test for leaking memory
fn mainProc(allocator: Allocator, args: []const []const u8) void {
    if (args.len < 2) {
        common.ewriteln("No path to tests.toml provided.", .{});
        return;
    }

    var file_content = std.fs.cwd().readFileAlloc(allocator, args[1], 100 * Mega) catch |err| {
        common.ewriteln("Unable to read tests.toml file.", .{});
        common.ewriteln("  Hint: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(file_content);

    setCwd(allocator, args[1]) catch |err| {
        common.ewriteln("Unable to switch current working directory.", .{});
        common.ewriteln("  Hint: {s}", .{@errorName(err)});
    };

    var parser = toml.Parser.init(allocator, file_content);
    var table = parser.parse() catch |err| {
        common.ewriteln("Error while parsing tests.toml file.", .{});
        common.ewriteln("  Hint: {s}", .{@errorName(err)});
        return;
    };
    defer table.deinit();

    var suite = tomlToSuite(allocator, &table) catch return;
    defer suite.deinit();

    fixExePath(allocator, &suite) catch |err| {
        common.ewriteHint("Unable to resolve executable path.", err, .{});
    };

    common.writeln("Running Tests [{s}]", .{args[1]});
    runSuite(allocator, &suite) catch |err| {
        common.ewriteHint("Error while running tests.", err, .{});
    };
}

test "Memory leak test" {
    mainProc(std.testing.allocator, &.{ "", "/Users/bc/source/test_runner/test/tests.toml.example" });
}
