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

                const required_field_type = switch (field.field_type) {
                    string => toml.Value.String,
                    i64 => toml.Value.Integer,
                    else => @compileError("Implement!"),
                };

                if (required_field_type != field_value) {
                    common.ewriteln("Expected " ++ @typeName(field.field_type) ++ " for '" ++ field.name ++ "' on {s} got {s}", .{ raw_test.name, @tagName(field_value) });
                    return error.Wrong_Value_Type;
                }

                @field(t, field.name) = @field(field_value, @tagName(required_field_type));
            }
        }

        try res.tests.append(t);
    }

    return res;
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

    // Get the absolute path to the executable of the suite relative
    // to the tests.toml file
    @compileLog("TODO");

    common.writeln("Running Tests [{s}]", .{args[1]});
    common.writeln("{}", .{suite});
    //common.writeln("", .{});
}
