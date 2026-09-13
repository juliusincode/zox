const std = @import("std");
const Value = @import("value.zig").Value;

/// A binding table for variables. `enclosing` points to the surrounding
/// scope (null = global scope) - variable resolution walks the chain
/// upward until it finds a match or reaches the top.
pub const Environment = struct {
    enclosing: ?*Environment = null,
    values: std.StringHashMap(Value),

    pub fn init(gpa: std.mem.Allocator) Environment {
        return .{ .values = std.StringHashMap(Value).init(gpa) };
    }

    pub fn initEnclosed(gpa: std.mem.Allocator, enclosing: *Environment) Environment {
        return .{ .enclosing = enclosing, .values = std.StringHashMap(Value).init(gpa) };
    }

    pub fn deinit(self: *Environment) void {
        self.values.deinit();
    }

    pub fn define(self: *Environment, name: []const u8, value: Value) std.mem.Allocator.Error!void {
        try self.values.put(name, value);
    }

    pub const GetError = error{UndefinedVariable};

    pub fn get(self: *Environment, name: []const u8) GetError!Value {
        if (self.values.get(name)) |v| return v;
        if (self.enclosing) |enc| return enc.get(name);
        return error.UndefinedVariable;
    }

    pub const AssignError = error{UndefinedVariable} || std.mem.Allocator.Error;

    pub fn assign(self: *Environment, name: []const u8, value: Value) AssignError!void {
        if (self.values.contains(name)) {
            try self.values.put(name, value);
            return;
        }
        if (self.enclosing) |enc| return enc.assign(name, value);
        return error.UndefinedVariable;
    }

    /// Jumps up exactly `distance` environments and looks up the name
    /// directly there - no more probing whether the variable lives at
    /// this level or not. `distance` comes from the resolver, which
    /// computed it statically once at parse time for every variable
    /// reference.
    pub fn getAt(self: *Environment, distance: usize, name: []const u8) GetError!Value {
        return self.ancestor(distance).values.get(name) orelse error.UndefinedVariable;
    }

    pub fn assignAt(self: *Environment, distance: usize, name: []const u8, value: Value) AssignError!void {
        try self.ancestor(distance).values.put(name, value);
    }

    fn ancestor(self: *Environment, distance: usize) *Environment {
        var env: *Environment = self;
        var i: usize = 0;
        while (i < distance) : (i += 1) {
            env = env.enclosing.?;
        }
        return env;
    }
};

test "define and get" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.define("a", .{ .number = 42 });
    try std.testing.expectEqual(@as(f64, 42), (try env.get("a")).number);
}

test "get on undefined variable fails" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectError(error.UndefinedVariable, env.get("nope"));
}

test "enclosed environment sees outer variables" {
    var outer = Environment.init(std.testing.allocator);
    defer outer.deinit();
    try outer.define("a", .{ .number = 1 });

    var inner = Environment.initEnclosed(std.testing.allocator, &outer);
    defer inner.deinit();

    try std.testing.expectEqual(@as(f64, 1), (try inner.get("a")).number);
}

test "assign in inner scope mutates outer binding" {
    var outer = Environment.init(std.testing.allocator);
    defer outer.deinit();
    try outer.define("a", .{ .number = 1 });

    var inner = Environment.initEnclosed(std.testing.allocator, &outer);
    defer inner.deinit();

    try inner.assign("a", .{ .number = 2 });
    try std.testing.expectEqual(@as(f64, 2), (try outer.get("a")).number);
}

test "shadowing in inner scope does not touch outer binding" {
    var outer = Environment.init(std.testing.allocator);
    defer outer.deinit();
    try outer.define("a", .{ .number = 1 });

    var inner = Environment.initEnclosed(std.testing.allocator, &outer);
    defer inner.deinit();
    try inner.define("a", .{ .number = 99 });

    try std.testing.expectEqual(@as(f64, 99), (try inner.get("a")).number);
    try std.testing.expectEqual(@as(f64, 1), (try outer.get("a")).number);
}

test "getAt/assignAt jump exactly the given number of hops" {
    var global = Environment.init(std.testing.allocator);
    defer global.deinit();
    try global.define("a", .{ .number = 1 });

    var middle = Environment.initEnclosed(std.testing.allocator, &global);
    defer middle.deinit();
    try middle.define("a", .{ .number = 2 });

    var innermost = Environment.initEnclosed(std.testing.allocator, &middle);
    defer innermost.deinit();

    // No `a` in `innermost` itself -> distance 0 would be wrong/missing.
    try std.testing.expectEqual(@as(f64, 2), (try innermost.getAt(1, "a")).number);
    try std.testing.expectEqual(@as(f64, 1), (try innermost.getAt(2, "a")).number);

    try innermost.assignAt(2, "a", .{ .number = 42 });
    try std.testing.expectEqual(@as(f64, 42), (try global.get("a")).number);
    // middle stayed untouched.
    try std.testing.expectEqual(@as(f64, 2), (try middle.get("a")).number);
}
