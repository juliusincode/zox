const std = @import("std");
const expr_mod = @import("expr.zig");
const Stmt = @import("stmt.zig").Stmt;
const Environment = @import("environment.zig").Environment;

/// The runtime value. Up through step 6 this was identical to
/// `expr.LiteralValue` - not anymore, because a function is a runtime
/// value (you can store it in variables, pass it around, return it), but
/// there's no "function literal" in the grammar that a literal token from
/// the scanner could ever produce. Hence two types now: `LiteralValue`
/// (pure AST payload) and `Value` (everything that can exist at runtime).
/// `fromLiteral` converts the former into the latter.
pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    nil,
    function: *LoxFunction,
    native: *NativeFunction,
    class: *LoxClass,
    instance: *LoxInstance,

    pub fn fromLiteral(lit: expr_mod.LiteralValue) Value {
        return switch (lit) {
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .boolean = b },
            .nil => .{ .nil = {} },
        };
    }
};

/// A Lox function at runtime: the AST node of its declaration plus the
/// environment that was active at the time of declaration - that's the
/// whole trick behind closures. `closure` MUST point to a heap-allocated
/// environment (see environment.zig / interpreter.zig), or it would point
/// into thin air once the surrounding block is left.
pub const LoxFunction = struct {
    declaration: *const Stmt.Function,
    closure: *Environment,
    /// `init()` methods behave specially: a `return;` with no value (or
    /// simply reaching the end of the body) yields `this` instead of
    /// `nil`, so that `SomeClass(...)` always returns the new instance.
    is_initializer: bool = false,
};

/// Built-in / native function. `call` receives the interpreter's allocator
/// (for any temporary values it may need) and the already-evaluated
/// argument list. Arity is checked by the call site before invoking.
pub const NativeFunction = struct {
    name: []const u8,
    arity: usize,
    call: *const fn (gpa: std.mem.Allocator, args: []const Value) Value,
};

/// A class at runtime: name, optional superclass, and its own (not
/// inherited) methods. Inherited methods are not copied - `findMethod`
/// walks up the superclass chain instead.
pub const LoxClass = struct {
    name: []const u8,
    superclass: ?*LoxClass,
    methods: std.StringHashMap(*LoxFunction),

    pub fn findMethod(self: *const LoxClass, name: []const u8) ?*LoxFunction {
        if (self.methods.get(name)) |m| return m;
        if (self.superclass) |sc| return sc.findMethod(name);
        return null;
    }
};

/// An instance: a pointer to its class (for method lookup) plus its own
/// fields. Fields are entirely dynamic - unlike methods there's no
/// declaration for them; `instance.new = 1;` simply creates "new" the
/// moment it's assigned.
pub const LoxInstance = struct {
    class: *LoxClass,
    fields: std.StringHashMap(Value),

    pub fn init(gpa: std.mem.Allocator, class: *LoxClass) LoxInstance {
        return .{ .class = class, .fields = std.StringHashMap(Value).init(gpa) };
    }
};

/// Binds a (still "loose", straight from the class definition) method to
/// a concrete instance: creates a new environment that defines only
/// `this`, chained in front of the original method closure. That's why
/// the same method body can be reused for every instance - each
/// `instance.method` access binds fresh.
pub fn bind(gpa: std.mem.Allocator, function: *LoxFunction, instance: *LoxInstance) !*LoxFunction {
    const env = try gpa.create(Environment);
    env.* = Environment.initEnclosed(gpa, function.closure);
    try env.define("this", .{ .instance = instance });

    const bound = try gpa.create(LoxFunction);
    bound.* = .{
        .declaration = function.declaration,
        .closure = env,
        .is_initializer = function.is_initializer,
    };
    return bound;
}
