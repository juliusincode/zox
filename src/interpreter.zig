const std = @import("std");
const tok = @import("token.zig");
const Token = tok.Token;
const expr_mod = @import("expr.zig");
const Expr = expr_mod.Expr;
const stmt_mod = @import("stmt.zig");
const Stmt = stmt_mod.Stmt;
const Environment = @import("environment.zig").Environment;
const value_mod = @import("value.zig");
pub const Value = value_mod.Value;
const LoxFunction = value_mod.LoxFunction;
const LoxClass = value_mod.LoxClass;
const LoxInstance = value_mod.LoxInstance;

pub const Interpreter = struct {
    /// Allocator for values that come into existence at runtime (e.g. the
    /// result of a string concatenation, new environments for blocks/
    /// calls). Usually an arena that lives as long as the whole program run.
    gpa: std.mem.Allocator,
    /// The *current* environment - changes when entering/leaving blocks
    /// and function calls.
    environment: *Environment,
    /// The outermost environment, never changes. Variables the resolver
    /// couldn't assign to any local scope live here.
    globals: *Environment,
    /// Filled in by the resolver: address of an `Expr.Variable`/
    /// `Expr.Assign` node -> how many environment levels up. The key is
    /// the AST node's pointer identity (stable, because we never free
    /// individually) - the same principle as Java's `Map<Expr, Integer>`
    /// in the original, just explicit via `@intFromPtr` instead of object
    /// identity.
    locals: std.AutoHashMap(usize, usize),
    had_runtime_error: bool = false,

    /// Carries the return value of a `return` statement back up. Zig
    /// errors can't carry a payload, hence this side channel: `execute`
    /// sets `return_value` and returns `error.Return`, `callFunction`
    /// catches exactly that and reads `return_value` back out.
    return_value: Value = .{ .nil = {} },

    pub const Error = error{ RuntimeError, Return } || std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator, environment: *Environment) Interpreter {
        return .{
            .gpa = gpa,
            .environment = environment,
            .globals = environment,
            .locals = std.AutoHashMap(usize, usize).init(gpa),
        };
    }

    /// Register a built-in function in the global environment.
    pub fn defineNative(self: *Interpreter, name: []const u8, arity: usize, call: *const fn (std.mem.Allocator, []const Value) Value) !void {
        const native = try self.gpa.create(value_mod.NativeFunction);
        native.* = .{ .name = name, .arity = arity, .call = call };
        try self.globals.define(name, .{ .native = native });
    }

    /// Called by the resolver as soon as it knows the lexical depth for a
    /// variable reference.
    pub fn resolve(self: *Interpreter, node_ptr: anytype, depth: usize) std.mem.Allocator.Error!void {
        try self.locals.put(@intFromPtr(node_ptr), depth);
    }

    /// Runs a whole program. A runtime error aborts - just like in the
    /// book - the entire run, not just the current statement.
    pub fn interpretProgram(self: *Interpreter, statements: []const Stmt) void {
        for (statements) |stmt| {
            self.execute(stmt) catch |e| {
                switch (e) {
                    error.RuntimeError => {},
                    error.Return => std.debug.print("Runtime Error: 'return' outside of a function.\n", .{}),
                    error.OutOfMemory => std.debug.print("Error: out of memory.\n", .{}),
                }
                self.had_runtime_error = true;
                return;
            };
        }
    }

    pub fn execute(self: *Interpreter, stmt: Stmt) Error!void {
        switch (stmt) {
            .expression => |e| _ = try self.evaluate(e.expression),
            .print => |p| {
                const value = try self.evaluate(p.expression);
                self.printValue(value);
            },
            .var_decl => |v| {
                const value: Value = if (v.initializer) |init_expr|
                    try self.evaluate(init_expr)
                else
                    .{ .nil = {} };
                try self.environment.define(v.name.lexeme, value);
            },
            .block => |blk| {
                const new_env = try self.gpa.create(Environment);
                new_env.* = Environment.initEnclosed(self.gpa, self.environment);
                try self.executeBlock(blk.statements, new_env);
            },
            .if_stmt => |s| {
                if (isTruthy(try self.evaluate(s.condition))) {
                    try self.execute(s.then_branch);
                } else if (s.else_branch) |else_branch| {
                    try self.execute(else_branch);
                }
            },
            .while_stmt => |s| {
                while (isTruthy(try self.evaluate(s.condition))) {
                    try self.execute(s.body);
                }
            },
            .function => |f| {
                const function = try self.gpa.create(LoxFunction);
                function.* = .{ .declaration = f, .closure = self.environment };
                try self.environment.define(f.name.lexeme, .{ .function = function });
            },
            .return_stmt => |r| {
                self.return_value = if (r.value) |value_expr| try self.evaluate(value_expr) else .{ .nil = {} };
                return error.Return;
            },
            .class_stmt => |c| try self.executeClass(c),
        }
    }

    /// Order matters here (mirrors the book): first evaluate and check
    /// the superclass, then declare the class name as a placeholder (so
    /// methods could reference themselves through the class name), then
    /// - if needed - introduce an extra environment just for `super`,
    /// then build the methods, and only then assign the real class value.
    fn executeClass(self: *Interpreter, c: *const Stmt.Class) Error!void {
        var superclass: ?*LoxClass = null;
        if (c.superclass) |sc| {
            const value = try self.evaluate(.{ .variable = sc });
            if (value != .class) {
                return self.runtimeError(sc.name, "Superclass must be a class.");
            }
            superclass = value.class;
        }

        try self.environment.define(c.name.lexeme, .{ .nil = {} });

        var methods_env = self.environment;
        if (superclass) |sc| {
            const super_env = try self.gpa.create(Environment);
            super_env.* = Environment.initEnclosed(self.gpa, self.environment);
            try super_env.define("super", .{ .class = sc });
            methods_env = super_env;
        }

        var methods = std.StringHashMap(*LoxFunction).init(self.gpa);
        for (c.methods) |method_stmt| {
            const method_decl = method_stmt.function;
            const function = try self.gpa.create(LoxFunction);
            function.* = .{
                .declaration = method_decl,
                .closure = methods_env,
                .is_initializer = std.mem.eql(u8, method_decl.name.lexeme, "init"),
            };
            try methods.put(method_decl.name.lexeme, function);
        }

        const class = try self.gpa.create(LoxClass);
        class.* = .{ .name = c.name.lexeme, .superclass = superclass, .methods = methods };

        // Can't fail (except OOM): we defined the name two lines up in
        // exactly this environment.
        self.environment.assign(c.name.lexeme, .{ .class = class }) catch |e| {
            switch (e) {
                error.UndefinedVariable => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
            }
        };
    }

    /// Swaps in a different environment for the duration of `statements`
    /// and restores the previous one afterward - like a stack frame,
    /// except `new_env` itself lives on the heap (arena). That's required:
    /// functions defined inside this block remember a pointer to exactly
    /// this environment (see `LoxFunction.closure`), and that pointer must
    /// still be valid after leaving `executeBlock`.
    fn executeBlock(self: *Interpreter, statements: []const Stmt, new_env: *Environment) Error!void {
        const previous = self.environment;
        self.environment = new_env;
        defer self.environment = previous;

        for (statements) |stmt| try self.execute(stmt);
    }

    pub fn evaluate(self: *Interpreter, expr: Expr) Error!Value {
        switch (expr) {
            .literal => |l| return Value.fromLiteral(l.value),
            .grouping => |g| return self.evaluate(g.expression),
            .unary => |u| return self.evaluateUnary(u),
            .binary => |b| return self.evaluateBinary(b),
            .variable => |v| return self.evaluateVariable(v),
            .assign => |a| return self.evaluateAssign(a),
            .logical => |l| return self.evaluateLogical(l),
            .call => |c| return self.evaluateCall(c),
            .get => |g| return self.evaluateGet(g),
            .set => |s| return self.evaluateSet(s),
            .this_expr => |t| return self.evaluateThis(t),
            .super_expr => |s| return self.evaluateSuper(s),
        }
    }

    fn evaluateGet(self: *Interpreter, g: *Expr.Get) Error!Value {
        const object = try self.evaluate(g.object);
        if (object != .instance) {
            return self.runtimeError(g.name, "Only instances have properties.");
        }
        const instance = object.instance;

        if (instance.fields.get(g.name.lexeme)) |field_value| {
            return field_value;
        }

        if (instance.class.findMethod(g.name.lexeme)) |method| {
            const bound = try value_mod.bind(self.gpa, method, instance);
            return .{ .function = bound };
        }

        var buf: [96]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "Undefined property '{s}'.", .{g.name.lexeme}) catch "Undefined property.";
        return self.runtimeError(g.name, message);
    }

    fn evaluateSet(self: *Interpreter, s: *Expr.Set) Error!Value {
        const object = try self.evaluate(s.object);
        if (object != .instance) {
            return self.runtimeError(s.name, "Only instances have fields.");
        }
        const value = try self.evaluate(s.value);
        try object.instance.fields.put(s.name.lexeme, value);
        return value;
    }

    fn evaluateThis(self: *Interpreter, t: *Expr.This) Error!Value {
        return self.lookUpVariable(t.keyword, t) catch |e| {
            switch (e) {
                error.UndefinedVariable => return self.runtimeError(t.keyword, "Undefined variable."),
            }
        };
    }

    fn evaluateSuper(self: *Interpreter, s: *Expr.Super) Error!Value {
        const distance = self.locals.get(@intFromPtr(s)) orelse {
            return self.runtimeError(s.keyword, "Could not resolve 'super'.");
        };
        const superclass_value = self.environment.getAt(distance, "super") catch {
            return self.runtimeError(s.keyword, "Could not resolve 'super'.");
        };
        const superclass = superclass_value.class;

        // "this" always sits exactly one level "closer" than "super" in
        // our environment layout (see resolveClass: super scope first,
        // then this scope on top of it).
        const instance_value = self.environment.getAt(distance - 1, "this") catch {
            return self.runtimeError(s.keyword, "Could not resolve 'this'.");
        };
        const instance = instance_value.instance;

        const method = superclass.findMethod(s.method.lexeme) orelse {
            var buf: [96]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "Undefined property '{s}'.", .{s.method.lexeme}) catch "Undefined property.";
            return self.runtimeError(s.method, message);
        };

        const bound = try value_mod.bind(self.gpa, method, instance);
        return .{ .function = bound };
    }

    fn evaluateCall(self: *Interpreter, c: *Expr.Call) Error!Value {
        const callee = try self.evaluate(c.callee);

        var arguments: std.ArrayList(Value) = .empty;
        for (c.arguments) |arg_expr| {
            try arguments.append(self.gpa, try self.evaluate(arg_expr));
        }

        if (callee == .function) {
            const function = callee.function;
            if (arguments.items.len != function.declaration.params.len) {
                return self.arityError(c.paren, function.declaration.params.len, arguments.items.len);
            }
            return self.callFunction(function, arguments.items);
        }

        if (callee == .native) {
            const native = callee.native;
            if (arguments.items.len != native.arity) {
                return self.arityError(c.paren, native.arity, arguments.items.len);
            }
            return native.call(self.gpa, arguments.items);
        }

        if (callee == .class) {
            const class = callee.class;
            const initializer = class.findMethod("init");
            const expected: usize = if (initializer) |init_fn| init_fn.declaration.params.len else 0;
            if (arguments.items.len != expected) {
                return self.arityError(c.paren, expected, arguments.items.len);
            }
            return self.instantiateClass(class, arguments.items);
        }

        return self.runtimeError(c.paren, "Can only call functions and classes.");
    }

    fn arityError(self: *Interpreter, paren: Token, expected: usize, got: usize) Error!Value {
        var buf: [96]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buf,
            "Expected {d} argument(s) but got {d}.",
            .{ expected, got },
        ) catch "Wrong number of arguments.";
        return self.runtimeError(paren, message);
    }

    /// A call `SomeClass(...)` creates a new, empty instance and calls -
    /// if present - its `init()` with the arguments. The result is always
    /// the instance, not whatever `init()` returns (see the
    /// `is_initializer` special case in `callFunction`).
    fn instantiateClass(self: *Interpreter, class: *LoxClass, arguments: []const Value) Error!Value {
        const instance = try self.gpa.create(LoxInstance);
        instance.* = LoxInstance.init(self.gpa, class);

        if (class.findMethod("init")) |initializer| {
            const bound = try value_mod.bind(self.gpa, initializer, instance);
            _ = try self.callFunction(bound, arguments);
        }

        return .{ .instance = instance };
    }

    /// Creates a fresh environment for the function body - chained not
    /// into the *current* scope, but into `function.closure`, the
    /// environment that was active when the function was defined. That's
    /// exactly what a closure is: the body sees the world as it was back
    /// then, not as it is now.
    fn callFunction(self: *Interpreter, function: *LoxFunction, arguments: []const Value) Error!Value {
        const call_env = try self.gpa.create(Environment);
        call_env.* = Environment.initEnclosed(self.gpa, function.closure);

        for (function.declaration.params, arguments) |param, arg| {
            try call_env.define(param.lexeme, arg);
        }

        self.executeBlock(function.declaration.body, call_env) catch |e| {
            switch (e) {
                error.Return => {
                    const value = self.return_value;
                    self.return_value = .{ .nil = {} };
                    if (function.is_initializer) {
                        // `return;` (with no value) inside init() still
                        // returns `this`, not `nil`.
                        return function.closure.get("this") catch unreachable;
                    }
                    return value;
                },
                else => return e,
            }
        };

        if (function.is_initializer) {
            return function.closure.get("this") catch unreachable;
        }
        // No `return` reached in the body -> Lox convention: `nil`.
        return .{ .nil = {} };
    }

    /// `and`/`or` only evaluate the right operand if it can still affect
    /// the result - and (Lox-style) return one of the two operand values,
    /// not necessarily `true`/`false`.
    fn evaluateLogical(self: *Interpreter, l: *Expr.Logical) Error!Value {
        const left = try self.evaluate(l.left);
        if (l.operator.type == .kw_or) {
            if (isTruthy(left)) return left;
        } else { // kw_and
            if (!isTruthy(left)) return left;
        }
        return self.evaluate(l.right);
    }

    fn evaluateVariable(self: *Interpreter, v: *Expr.Variable) Error!Value {
        return self.lookUpVariable(v.name, v) catch |e| {
            switch (e) {
                error.UndefinedVariable => return self.runtimeError(v.name, "Undefined variable."),
            }
        };
    }

    /// First checks `locals` to see whether the resolver computed a depth
    /// for exactly this node (pointer identity!). If yes: jump straight
    /// there via `getAt`. If no: the resolver couldn't assign the
    /// variable to any local scope, so it's a global - we look it up in
    /// `globals`, not in the current environment (which might well be
    /// deep inside a function call right now).
    fn lookUpVariable(self: *Interpreter, name: Token, node_ptr: anytype) Environment.GetError!Value {
        if (self.locals.get(@intFromPtr(node_ptr))) |distance| {
            return self.environment.getAt(distance, name.lexeme);
        }
        return self.globals.get(name.lexeme);
    }

    fn evaluateAssign(self: *Interpreter, a: *Expr.Assign) Error!Value {
        const value = try self.evaluate(a.value);

        const result = if (self.locals.get(@intFromPtr(a))) |distance|
            self.environment.assignAt(distance, a.name.lexeme, value)
        else
            self.globals.assign(a.name.lexeme, value);

        result catch |e| {
            switch (e) {
                error.UndefinedVariable => return self.runtimeError(a.name, "Undefined variable."),
                error.OutOfMemory => return error.OutOfMemory,
            }
        };
        return value;
    }

    fn evaluateUnary(self: *Interpreter, u: *Expr.Unary) Error!Value {
        const right = try self.evaluate(u.right);
        switch (u.operator.type) {
            .minus => return .{ .number = -(try self.checkNumber(u.operator, right)) },
            .bang => return .{ .boolean = !isTruthy(right) },
            else => unreachable, // the parser only ever produces these two unary operators
        }
    }

    fn evaluateBinary(self: *Interpreter, b: *Expr.Binary) Error!Value {
        const left = try self.evaluate(b.left);
        const right = try self.evaluate(b.right);
        const op = b.operator;

        switch (op.type) {
            .minus => return .{ .number = (try self.checkNumber(op, left)) - (try self.checkNumber(op, right)) },
            .slash => return .{ .number = (try self.checkNumber(op, left)) / (try self.checkNumber(op, right)) },
            .star => return .{ .number = (try self.checkNumber(op, left)) * (try self.checkNumber(op, right)) },
            .plus => return self.add(op, left, right),
            .greater => return .{ .boolean = (try self.checkNumber(op, left)) > (try self.checkNumber(op, right)) },
            .greater_equal => return .{ .boolean = (try self.checkNumber(op, left)) >= (try self.checkNumber(op, right)) },
            .less => return .{ .boolean = (try self.checkNumber(op, left)) < (try self.checkNumber(op, right)) },
            .less_equal => return .{ .boolean = (try self.checkNumber(op, left)) <= (try self.checkNumber(op, right)) },
            .bang_equal => return .{ .boolean = !isEqual(left, right) },
            .equal_equal => return .{ .boolean = isEqual(left, right) },
            else => unreachable, // the parser only ever produces these binary operators
        }
    }

    /// "+" is special: numbers get added, strings get concatenated.
    /// Anything else is a runtime error.
    fn add(self: *Interpreter, op: Token, left: Value, right: Value) Error!Value {
        if (left == .number and right == .number) {
            return .{ .number = left.number + right.number };
        }
        if (left == .string and right == .string) {
            const joined = try std.mem.concat(self.gpa, u8, &.{ left.string, right.string });
            return .{ .string = joined };
        }
        return self.runtimeError(op, "Operands must be two numbers or two strings.");
    }

    fn checkNumber(self: *Interpreter, op: Token, value: Value) Error!f64 {
        if (value == .number) return value.number;
        return self.runtimeError(op, "Operand must be a number.");
    }

    /// Lox truthiness rules: only `nil` and `false` are falsy, everything
    /// else (including `0` and `""`) is truthy.
    fn isTruthy(value: Value) bool {
        return switch (value) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    /// No implicit type coercion: different types are never equal, `nil`
    /// is only equal to itself.
    fn isEqual(a: Value, b: Value) bool {
        switch (a) {
            .nil => return b == .nil,
            .boolean => |ab| return switch (b) {
                .boolean => |bb| ab == bb,
                else => false,
            },
            .number => |an| return switch (b) {
                .number => |bn| an == bn,
                else => false,
            },
            .string => |as_| return switch (b) {
                .string => |bs| std.mem.eql(u8, as_, bs),
                else => false,
            },
            .function => |af| return switch (b) {
                .function => |bf| af == bf,
                else => false,
            },
            .native => |an| return switch (b) {
                .native => |bn| an == bn,
                else => false,
            },
            .class => |ac| return switch (b) {
                .class => |bc| ac == bc,
                else => false,
            },
            .instance => |ai| return switch (b) {
                .instance => |bi| ai == bi,
                else => false,
            },
        }
    }

    fn runtimeError(self: *Interpreter, token: Token, message: []const u8) Error {
        _ = self;
        std.debug.print("[line {d}] Runtime Error at '{s}': {s}\n", .{ token.line, token.lexeme, message });
        return error.RuntimeError;
    }

    fn printValue(self: *Interpreter, value: Value) void {
        _ = self;
        switch (value) {
            .nil => std.debug.print("nil\n", .{}),
            .boolean => |b| std.debug.print("{s}\n", .{if (b) "true" else "false"}),
            .number => |n| std.debug.print("{d}\n", .{n}),
            .string => |s| std.debug.print("{s}\n", .{s}),
            .function => |f| std.debug.print("<fn {s}>\n", .{f.declaration.name.lexeme}),
            .native => |n| std.debug.print("<native fn {s}>\n", .{n.name}),
            .class => |cl| std.debug.print("{s}\n", .{cl.name}),
            .instance => |inst| std.debug.print("{s} instance\n", .{inst.class.name}),
        }
    }
};

const Scanner = @import("scanner.zig").Scanner;
const Parser = @import("parser.zig").Parser;

fn evalSource(gpa: std.mem.Allocator, source: []const u8) !Value {
    var scanner = Scanner.init(source);
    defer scanner.deinit(gpa);
    const tokens = try scanner.scanTokens(gpa);

    var parser = Parser.init(gpa, tokens);
    const expression = try parser.parse();

    var environment = Environment.init(gpa);
    defer environment.deinit();

    var interpreter = Interpreter.init(gpa, &environment);
    return interpreter.evaluate(expression);
}

const Resolver = @import("resolver.zig").Resolver;

fn runProgram(gpa: std.mem.Allocator, source: []const u8, environment: *Environment) !void {
    var scanner = Scanner.init(source);
    defer scanner.deinit(gpa);
    const tokens = try scanner.scanTokens(gpa);

    var parser = Parser.init(gpa, tokens);
    const statements = try parser.parseProgram();

    var interpreter = Interpreter.init(gpa, environment);

    var resolver = Resolver.init(gpa, &interpreter);
    try resolver.resolveProgram(statements);

    for (statements) |stmt| try interpreter.execute(stmt);
}

test "arithmetic with correct precedence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = try evalSource(arena, "1 + 2 * 3");
    try std.testing.expectEqual(@as(f64, 7), value.number);
}

test "string concatenation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = try evalSource(arena, "\"foo\" + \"bar\"");
    try std.testing.expectEqualStrings("foobar", value.string);
}

test "comparison operators" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect((try evalSource(arena, "1 < 2")).boolean);
    try std.testing.expect(!(try evalSource(arena, "2 <= 1")).boolean);
    try std.testing.expect((try evalSource(arena, "3 == 3")).boolean);
    try std.testing.expect((try evalSource(arena, "3 != 4")).boolean);
}

test "nil and boolean equality without coercion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect((try evalSource(arena, "nil == nil")).boolean);
    try std.testing.expect(!(try evalSource(arena, "nil == false")).boolean);
    try std.testing.expect(!(try evalSource(arena, "0 == false")).boolean);
}

test "truthiness of unary bang" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect((try evalSource(arena, "!nil")).boolean);
    try std.testing.expect((try evalSource(arena, "!false")).boolean);
    try std.testing.expect(!(try evalSource(arena, "!0")).boolean);
    try std.testing.expect(!(try evalSource(arena, "!\"\"")).boolean);
}

test "type errors are reported as RuntimeError" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.RuntimeError, evalSource(arena, "1 + \"two\""));
    try std.testing.expectError(error.RuntimeError, evalSource(arena, "-\"muffin\""));
    try std.testing.expectError(error.RuntimeError, evalSource(arena, "\"a\" < 2"));
}

test "var declaration and read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var a = 1; var b = 2; var c = a + b;", &env);
    try std.testing.expectEqual(@as(f64, 3), (try env.get("c")).number);
}

test "var without initializer defaults to nil" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var a;", &env);
    try std.testing.expect((try env.get("a")) == .nil);
}

test "assignment mutates an existing variable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var a = 1; a = a + 1; a = a + 1;", &env);
    try std.testing.expectEqual(@as(f64, 3), (try env.get("a")).number);
}

test "block introduces a new scope that shadows the outer variable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var a = \"outer\"; { var a = \"inner\"; }", &env);
    try std.testing.expectEqualStrings("outer", (try env.get("a")).string);
}

test "block can see and mutate the outer variable without shadowing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var a = 1; { a = a + 10; }", &env);
    try std.testing.expectEqual(@as(f64, 11), (try env.get("a")).number);
}

test "reading an undefined variable is a runtime error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try std.testing.expectError(error.RuntimeError, runProgram(arena, "print notDefined;", &env));
}

test "assigning to an undefined variable is a runtime error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try std.testing.expectError(error.RuntimeError, runProgram(arena, "notDefined = 1;", &env));
}

test "if executes the then-branch when the condition is truthy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var result; if (1 < 2) { result = \"yes\"; } else { result = \"no\"; }", &env);
    try std.testing.expectEqualStrings("yes", (try env.get("result")).string);
}

test "if executes the else-branch when the condition is falsy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var result; if (1 > 2) { result = \"yes\"; } else { result = \"no\"; }", &env);
    try std.testing.expectEqualStrings("no", (try env.get("result")).string);
}

test "if without else is a no-op when the condition is falsy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var result = \"unchanged\"; if (false) { result = \"changed\"; }", &env);
    try std.testing.expectEqualStrings("unchanged", (try env.get("result")).string);
}

test "while loop accumulates a sum" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var i = 0; var sum = 0; while (i < 5) { sum = sum + i; i = i + 1; }", &env);
    try std.testing.expectEqual(@as(f64, 10), (try env.get("sum")).number);
}

test "for loop desugars into an equivalent while loop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var sum = 0; for (var i = 0; i < 5; i = i + 1) { sum = sum + i; }", &env);
    try std.testing.expectEqual(@as(f64, 10), (try env.get("sum")).number);

    // The for-header's loop variable belongs to the desugared outer
    // block and must not be visible outside of it.
    try std.testing.expectError(error.UndefinedVariable, env.get("i"));
}

test "logical or short-circuits and returns an operand value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var evaluated = false; var x = \"erstes\" or (evaluated = true);", &env);
    try std.testing.expectEqualStrings("erstes", (try env.get("x")).string);
    try std.testing.expect(!(try env.get("evaluated")).boolean);
}

test "logical and short-circuits and returns an operand value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var evaluated = false; var x = false and (evaluated = true);", &env);
    try std.testing.expect(!(try env.get("x")).boolean);
    try std.testing.expect(!(try env.get("evaluated")).boolean);
}

test "logical or falls through to the right operand when the left is falsy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "var x = nil or \"default\";", &env);
    try std.testing.expectEqualStrings("default", (try env.get("x")).string);
}

test "function call returns the evaluated return statement" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "fun add(a, b) { return a + b; } var result = add(2, 3);", &env);
    try std.testing.expectEqual(@as(f64, 5), (try env.get("result")).number);
}

test "function without a reached return statement yields nil" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "fun noop() {} var result = noop();", &env);
    try std.testing.expect((try env.get("result")) == .nil);
}

test "return exits the function early" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena, "fun early() { return 1; return 2; } var result = early();", &env);
    try std.testing.expectEqual(@as(f64, 1), (try env.get("result")).number);
}

test "recursive function calls itself correctly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\fun fact(n) {
        \\  if (n <= 1) { return 1; }
        \\  return n * fact(n - 1);
        \\}
        \\var result = fact(5);
    , &env);
    try std.testing.expectEqual(@as(f64, 120), (try env.get("result")).number);
}

test "closures capture their defining environment, not the call site" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\fun makeCounter() {
        \\  var i = 0;
        \\  fun counter() {
        \\    i = i + 1;
        \\    return i;
        \\  }
        \\  return counter;
        \\}
        \\var counter = makeCounter();
        \\var a = counter();
        \\var b = counter();
        \\var c = counter();
    , &env);

    try std.testing.expectEqual(@as(f64, 1), (try env.get("a")).number);
    try std.testing.expectEqual(@as(f64, 2), (try env.get("b")).number);
    try std.testing.expectEqual(@as(f64, 3), (try env.get("c")).number);
}

test "two counters from the same factory have independent state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\fun makeCounter() {
        \\  var i = 0;
        \\  fun counter() {
        \\    i = i + 1;
        \\    return i;
        \\  }
        \\  return counter;
        \\}
        \\var counterA = makeCounter();
        \\var counterB = makeCounter();
        \\var a1 = counterA();
        \\var a2 = counterA();
        \\var b1 = counterB();
    , &env);

    try std.testing.expectEqual(@as(f64, 1), (try env.get("a1")).number);
    try std.testing.expectEqual(@as(f64, 2), (try env.get("a2")).number);
    try std.testing.expectEqual(@as(f64, 1), (try env.get("b1")).number);
}

test "calling a value that is not a function is a runtime error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try std.testing.expectError(error.RuntimeError, runProgram(arena, "var x = 1; x();", &env));
}

test "calling a function with the wrong number of arguments is a runtime error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try std.testing.expectError(
        error.RuntimeError,
        runProgram(arena, "fun add(a, b) { return a + b; } add(1);", &env),
    );
}

test "closures resolve to the variable in scope at definition time, not call time" {
    // The classic resolver test case from chapter 11: `showA` is defined
    // *before* the local `a` exists in the same block. Lexical scoping
    // requires: both calls see the outer `a`. A purely dynamic
    // environment chain (our state before the resolver) would incorrectly
    // see "inner" on the second call.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\var a = "outer";
        \\var first;
        \\var second;
        \\{
        \\  fun showA() {
        \\    return a;
        \\  }
        \\  first = showA();
        \\  var a = "inner";
        \\  second = showA();
        \\}
    , &env);

    try std.testing.expectEqualStrings("outer", (try env.get("first")).string);
    try std.testing.expectEqualStrings("outer", (try env.get("second")).string);
}


test "resolver rejects reading a local variable inside its own initializer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    var scanner = Scanner.init("{ var a = a; }");
    defer scanner.deinit(arena);
    const tokens = try scanner.scanTokens(arena);

    var parser = Parser.init(arena, tokens);
    const statements = try parser.parseProgram();

    var interpreter = Interpreter.init(arena, &env);
    var resolver = Resolver.init(arena, &interpreter);
    try resolver.resolveProgram(statements);

    try std.testing.expect(resolver.had_error);
}

test "class instances store and retrieve dynamic fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\class Bagel {}
        \\var bagel = Bagel();
        \\bagel.flavor = "everything";
        \\var result = bagel.flavor;
    , &env);

    try std.testing.expectEqualStrings("everything", (try env.get("result")).string);
}

test "methods are bound to the instance and see 'this'" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\class Counter {
        \\  init() { this.count = 0; }
        \\  increment() {
        \\    this.count = this.count + 1;
        \\    return this.count;
        \\  }
        \\}
        \\var c = Counter();
        \\var a = c.increment();
        \\var b = c.increment();
    , &env);

    try std.testing.expectEqual(@as(f64, 1), (try env.get("a")).number);
    try std.testing.expectEqual(@as(f64, 2), (try env.get("b")).number);
}

test "calling a class runs init() and returns the new instance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\class Foo {
        \\  init(x) { this.x = x; }
        \\}
        \\var f = Foo(42);
        \\var result = f.x;
    , &env);

    try std.testing.expectEqual(@as(f64, 42), (try env.get("result")).number);
}

test "a bare return inside init still yields the instance, not nil" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\class Foo {
        \\  init() {
        \\    this.ready = true;
        \\    return;
        \\  }
        \\}
        \\var f = Foo();
        \\var result = f.ready;
    , &env);

    try std.testing.expect((try env.get("result")).boolean);
}

test "methods returning 'this' allow call chaining" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\class Counter {
        \\  init() { this.count = 0; }
        \\  increment() {
        \\    this.count = this.count + 1;
        \\    return this;
        \\  }
        \\}
        \\var f = Counter();
        \\f.increment().increment().increment();
        \\var result = f.count;
    , &env);

    try std.testing.expectEqual(@as(f64, 3), (try env.get("result")).number);
}

test "subclass inherits methods and super.method() reaches the parent implementation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\class Doughnut {
        \\  cook() { return "Fry until golden brown."; }
        \\}
        \\class BostonCream < Doughnut {
        \\  cook() {
        \\    var base = super.cook();
        \\    return base + " Pipe full of custard.";
        \\  }
        \\}
        \\var result = BostonCream().cook();
    , &env);

    try std.testing.expectEqualStrings(
        "Fry until golden brown. Pipe full of custard.",
        (try env.get("result")).string,
    );
}

test "subclass without overriding a method uses the inherited one directly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try runProgram(arena,
        \\class Doughnut {
        \\  cook() { return "Fry until golden brown."; }
        \\}
        \\class BostonCream < Doughnut {}
        \\var result = BostonCream().cook();
    , &env);

    try std.testing.expectEqualStrings("Fry until golden brown.", (try env.get("result")).string);
}

test "the superclass expression must actually evaluate to a class" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try std.testing.expectError(
        error.RuntimeError,
        runProgram(arena, "var NotAClass = \"just a string\"; class Oops < NotAClass {}", &env),
    );
}

test "accessing an undefined property on an instance is a runtime error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    try std.testing.expectError(
        error.RuntimeError,
        runProgram(arena, "class Empty {} var e = Empty(); print e.nothing;", &env),
    );
}

test "resolver rejects a class inheriting from itself" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = Environment.init(arena);
    defer env.deinit();

    var scanner = Scanner.init("class Oops < Oops {}");
    defer scanner.deinit(arena);
    const tokens = try scanner.scanTokens(arena);

    var parser = Parser.init(arena, tokens);
    const statements = try parser.parseProgram();

    var interpreter = Interpreter.init(arena, &env);
    var resolver = Resolver.init(arena, &interpreter);
    try resolver.resolveProgram(statements);

    try std.testing.expect(resolver.had_error);
}
