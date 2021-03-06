const std = @import("std");

const Token = union(enum) {
    Identifier: []const u8,
    Bool: bool,
    String: []const u8,
    Integer: i64,
    OpenBracket: void,
    CloseBracket: void,
    Equals_Sign: void,
    EOF: void,
};

const Tokenizer = struct {
    data: []const u8,
    col: u64 = 0,
    line: u64 = 1,
    i: u64 = 0,

    /// Lex next token without consuming it
    pub fn peekToken(self: *Tokenizer) !Token {
        var tmp = self.*;
        return tmp.nextToken();
    }

    pub fn nextToken(self: *Tokenizer) !Token {
        // Skip whitespace and check for EOF
        {
            var skip_whitespace = true;
            var skip_comment = false;
            while (skip_whitespace) {
                if (self.i >= self.data.len) {
                    return Token{ .EOF = undefined };
                }

                var c = self.data[self.i];
                if (c == '#') {
                    skip_comment = true;
                    self.step(1);
                } else if (c == '\n') {
                    self.col = 0;
                    self.line += 1;
                    self.i += 1;
                    skip_comment = false;
                } else if (c == ' ' or c == '\r' or c == '\t') {
                    self.step(1);
                } else {
                    if (skip_comment) self.step(1) else skip_whitespace = false;
                }
            }
        }

        var state: Token = switch (self.data[self.i]) {
            '[' => val: {
                self.step(1);
                break :val Token{ .OpenBracket = undefined };
            },
            ']' => val: {
                self.step(1);
                break :val Token{ .CloseBracket = undefined };
            },
            '=' => val: {
                self.step(1);
                break :val Token{ .Equals_Sign = undefined };
            },
            '"' => val: {
                // Parse string literal

                // skip first quote char
                self.step(1);

                // TODO(may): Handle \r\n
                if ((self.i < self.data.len - 1) and self.data[self.i] == '\n') {
                    self.step(1);
                }

                const start = self.i;

                while ((self.i < self.data.len) and self.data[self.i] != '"') {
                    if (self.data[self.i] == '\n') {
                        self.i += 1;
                        self.line += 1;
                        self.col = 0;
                    } else {
                        self.step(1);
                    }
                } else {
                    if (self.i >= self.data.len) {
                        return error.StringNotClosed;
                    }
                }

                defer self.step(1); // skip the quote at the end

                break :val Token{ .String = self.data[start..self.i] };
            },
            '0'...'9' => val: {
                var number = self.data[self.i] - '0';
                self.step(1);
                while ((self.i < self.data.len) and (self.data[self.i] >= '0' and self.data[self.i] <= '9')) : (self.step(1)) {
                    number *= 10;
                    number += self.data[self.i] - '0';
                }

                break :val Token{ .Integer = number };
            },
            else => val: {
                // Parse boolean
                if (caseInsensitiveStartsWith("true", self.data[self.i..])) {
                    self.step(4);
                    break :val Token{ .Bool = true };
                } else if (caseInsensitiveStartsWith("false", self.data[self.i..])) {
                    self.step(5);
                    break :val Token{ .Bool = false };
                }

                // Parse identifier
                // TODO: break on [,],",WHITESPACE
                const start = self.i;

                var c = self.data[self.i];
                while ((self.i < self.data.len)) : (c = self.data[self.i]) {
                    if (isWhitespace(c)) break;
                    if (c == '[') break;
                    if (c == ']') break;
                    if (c == '"') break;
                    if (c == '=') break;

                    self.step(1);
                }

                break :val Token{ .Identifier = self.data[start..self.i] };
            },
        };

        return state;
    }
    /// Check if b starts with a
    fn caseInsensitiveStartsWith(prefix: []const u8, str: []const u8) bool {
        if (str.len - prefix.len >= 0) {
            return caseInsensitiveCompare(prefix, str[0..prefix.len]);
        } else {
            return false;
        }
    }

    fn caseInsensitiveCompare(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;

        for (a) |c, i| {
            var c1 = if (c >= 'A' and c <= 'Z') c + 32 else c;
            var c2 = if (c >= 'A' and c <= 'Z') b[i] + 32 else b[i];
            if (c1 != c2) return false;
        }

        return true;
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\r' or c == '\n' or c == '\t';
    }

    /// Returns true  if next is a line ending e.g. \n or \r\n
    /// Returns false if not next is not a line ending or no data left
    fn isLineEnding(self: *Tokenizer) bool {
        if (self.i >= self.data.len) return false;

        return (self.data[self.i] == '\n');
    }

    /// Increases both col and index value
    fn step(self: *Tokenizer, count: u32) void {
        self.i += count;
        self.col += count;
    }
};

pub const Value = union(enum) {
    Bool: bool,
    String: []const u8,
    Integer: i64,
    Table: Table,
};

pub const Table = struct {
    const Item_Type = std.StringHashMap(Value);

    name: []const u8,
    items: Item_Type,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Table {
        return .{
            .name = name,
            .items = Item_Type.init(allocator),
        };
    }

    pub fn deinit(self: *Table) void {
        var iterator = self.items.valueIterator();
        while (iterator.next()) |item| {
            if (item.* == Value.Table) {
                item.Table.deinit();
            }
        }

        self.items.deinit();
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Parser {
        return .{
            .allocator = allocator,
            .tokenizer = Tokenizer{ .data = data },
        };
    }

    pub fn parse(self: *Parser) !Table {
        var result = Table.init(self.allocator, "");
        errdefer result.deinit();

        var state: enum {
            Key_Or_Header,
            Equals_Sign,
            Value,
        } = .Key_Or_Header;
        var name: []const u8 = undefined;
        var value: Value = undefined;
        var current_table = &result;
        while (true) {
            var token = try self.tokenizer.nextToken();

            if (token == .EOF) {
                if (state == .Equals_Sign) {
                    return error.Expected_Equals_Sign;
                } else if (state == .Value) {
                    return error.Expected_Value;
                } else {
                    break;
                }
            }

            switch (state) {
                .Key_Or_Header => {
                    if (token == .Identifier) {
                        name = token.Identifier;
                        state = .Equals_Sign;
                    } else if (token == .OpenBracket) {
                        token = try self.tokenizer.nextToken();
                        if (token != .Identifier) {
                            return error.Expected_Identifier;
                        }
                        name = token.Identifier;

                        token = try self.tokenizer.nextToken();
                        if (token != .CloseBracket) {
                            return error.Expected_Closing_Bracket;
                        }

                        value = Value{ .Table = Table.init(self.allocator, name) };
                        try result.items.put(name, value);
                        current_table = &(result.items.getPtr(name) orelse unreachable).Table;
                    } else {
                        std.debug.print("\n\n{}\n\n", .{token});
                        return error.Expected_Key_Or_Value;
                    }
                },
                .Equals_Sign => {
                    if (token != .Equals_Sign) {
                        return error.Expected_Equals_Sign;
                    } else {
                        state = .Value;
                    }
                },
                .Value => {
                    if (token == .String) {
                        value = Value{ .String = token.String };
                        try current_table.items.put(name, value);
                        state = .Key_Or_Header;
                    } else if (token == .Bool) {
                        value = Value{ .Bool = token.Bool };
                        try current_table.items.put(name, value);
                        state = .Key_Or_Header;
                    } else if (token == .Integer) {
                        value = Value{ .Integer = token.Integer };
                        try current_table.items.put(name, value);
                        state = .Key_Or_Header;
                    } else {
                        return error.Expected_Value;
                    }
                },
            }
        }

        return result;
    }
};

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "Simple Tokenizer Test" {
    var test_string =
        \\tstring = "hello" # Here is a Comment
        \\tbool   = true
        \\b       = false
        \\[htest]
        \\s="#"
    ;

    var tokenizer = Tokenizer{ .data = test_string };

    // 1. Line
    var token = try tokenizer.nextToken();
    try expectEqual(Token.Identifier, token);
    try expectEqualStrings("tstring", token.Identifier);

    token = try tokenizer.nextToken();
    try expectEqual(Token.Equals_Sign, token);

    token = try tokenizer.nextToken();
    try expectEqual(Token.String, token);
    try expectEqualStrings("hello", token.String);

    try expectEqual(@as(u64, 1), tokenizer.line);
    try expectEqual(@as(u64, 17), tokenizer.col); // Tokenizer should be on the \n

    // 2. Line
    token = try tokenizer.nextToken();
    try expectEqual(Token.Identifier, token);
    try expectEqualStrings("tbool", token.Identifier);

    token = try tokenizer.nextToken();
    try expectEqual(Token.Equals_Sign, token);

    token = try tokenizer.nextToken();
    try expectEqual(Token.Bool, token);
    try expectEqual(true, token.Bool);

    try expectEqual(@as(u64, 2), tokenizer.line);
    try expectEqual(@as(u64, 14), tokenizer.col); // Tokenizer should be on the \n

    // 3. Line
    token = try tokenizer.nextToken();
    try expectEqual(Token.Identifier, token);
    try expectEqualStrings("b", token.Identifier);

    token = try tokenizer.nextToken();
    try expectEqual(Token.Equals_Sign, token);

    token = try tokenizer.nextToken();
    try expectEqual(Token.Bool, token);
    try expectEqual(false, token.Bool);

    try expectEqual(@as(u64, 3), tokenizer.line);
    try expectEqual(@as(u64, 15), tokenizer.col); // Tokenizer should be on the \n

    // 4. Line
    token = try tokenizer.nextToken();
    try expectEqual(Token.OpenBracket, token);

    token = try tokenizer.nextToken();
    try expectEqual(Token.Identifier, token);
    try expectEqualStrings("htest", token.Identifier);

    token = try tokenizer.nextToken();
    try expectEqual(Token.CloseBracket, token);

    try expectEqual(@as(u64, 4), tokenizer.line);
    try expectEqual(@as(u64, 7), tokenizer.col); // Tokenizer should be on the \n

    // 5. Line
    token = try tokenizer.nextToken();
    try expectEqual(Token.Identifier, token);
    try expectEqualStrings("s", token.Identifier);

    token = try tokenizer.nextToken();
    try expectEqual(Token.Equals_Sign, token);

    token = try tokenizer.nextToken();
    try expectEqual(Token.String, token);
    try expectEqualStrings("#", token.String);

    token = try tokenizer.nextToken();
    try expectEqual(Token.EOF, token);
}

fn range(comptime n: comptime_int) [n]void {
    return undefined;
}

test "Peek Token Test" {
    const test_string =
        \\some = "value"
    ;

    var tokenizer = Tokenizer{ .data = test_string };

    for (range(5)) |_| {
        var token = try tokenizer.peekToken();
        try expectEqual(Token.Identifier, token);
    }

    try expectEqual(@as(u64, 0), tokenizer.i);
    try expectEqual(@as(u64, 1), tokenizer.line);
    try expectEqual(@as(u64, 0), tokenizer.col);
}

test "Multiline String Tokenizer Test" {
    const test_string =
        \\tstring  = "hello
        \\world"
        \\tstring2 = "
        \\hello world"
        \\tstring3 = "
        \\
        \\"
    ;

    var tokenizer = Tokenizer{ .data = test_string };

    var token = try tokenizer.nextToken();
    token = try tokenizer.nextToken();
    token = try tokenizer.nextToken();
    try expectEqual(Token.String, token);
    try expectEqualStrings("hello\nworld", token.String);

    token = try tokenizer.nextToken();
    token = try tokenizer.nextToken();
    token = try tokenizer.nextToken();
    try expectEqual(Token.String, token);
    try expectEqualStrings("hello world", token.String);

    token = try tokenizer.nextToken();
    token = try tokenizer.nextToken();
    token = try tokenizer.nextToken();
    try expectEqual(Token.String, token);
    try expectEqualStrings("\n", token.String);
}

test "Simple Parser Test" {
    const test_string =
        \\tstring = "hello"
        \\tbool   = true
        \\[header]
        \\some_string = "Thats a string" #dwadw
    ;

    var parser = Parser.init(std.testing.allocator, test_string);
    var result = try parser.parse();
    defer result.deinit();

    try expectEqual(@as(u32, 3), result.items.count());

    try expectEqualStrings("hello", result.items.get("tstring").?.String);
    try expectEqual(true, result.items.get("tbool").?.Bool);

    var header_table = result.items.get("header").?.Table;
    try expectEqual(@as(usize, 1), header_table.items.count());
    try expectEqualStrings("Thats a string", header_table.items.get("some_string").?.String);
}

test "Simple Parser Error Test" {
    const test_string =
        \\ [jwad]
        \\ waddaw = 12
        \\ tstring =
        \\ # some comment
    ;

    var parser = Parser.init(std.testing.allocator, test_string);
    var result = parser.parse();
    try std.testing.expectError(error.Expected_Value, result);
}

test "Parser Application Test" {
    const test_string =
        \\    # This is the general configuration.
        \\    path = "example_program" # Relative to this file
        \\    continue_on_fail = true
        \\
        \\    [Green_Test]
        \\    input      = "-some -program -arguments"
        \\    output     = "-some -program -arguments"
        \\    output_err = "error_output"
        \\    exit_code  = 69
        \\
        \\    [Failing_Test]
        \\    input      = "ARG2"
        \\    output     = "OUT2"
        \\    output_err = "OUT_ERR2"
        \\    exit_code  = 222
    ;

    var parser = Parser.init(std.testing.allocator, test_string);
    var result = try parser.parse();
    defer result.deinit();

    try expectEqual(@as(usize, 4), result.items.count());

    // TODO(may): test the rest of the stuff...
}
