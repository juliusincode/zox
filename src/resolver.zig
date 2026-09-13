const std = @import("std");
const tok = @import("token.zig");
const Token = tok.Token;
const expr_mod = @import("expr.zig");
const Expr = expr_mod.Expr;
const stmt_mod = @import("stmt.zig");
const Stmt = stmt_mod.Stmt;
const Interpreter = @import("interpreter.zig").Interpreter;

/// Runs once, statically, over the whole AST before the interpreter
/// executes even a single line. Unlike the interpreter it doesn't
/// evaluate anything - it just keeps track of how deeply nested blocks/
/// function bodies are, and records, for every variable reference, how
/// many levels lie between it and its declaration. It reports that
/// number (`distance`) back to the interpreter via `interpreter.resolve()`.
pub const Resolver = struct {
    gpa: std.mem.Allocator,
    interpreter: *Interpreter,
    /// A stack of scopes. `scopes[i].get(name)`:
    ///   - missing entirely -> name not declared in this scope
    ///   - `false`          -> declared, but the initializer hasn't
    ///                         finished evaluating yet (catches `var a = a;`)
    ///   - `true`           -> fully usable
    /// The global scope is NOT on this stack - the interpreter already
    /// does dynamic resolution through `globals` for that one.
    scopes: std.ArrayList(std.StringHashMap(bool)) = .empty,
    had_error: bool = false,

    /// For context-dependent errors: `return` only inside a function, no
    /// value on `return` from an initializer, `this`/`super` only inside
    /// a (sub)class.
    current_function: FunctionType = .none,
    current_class: ClassType = .none,

    const FunctionType = enum { none, function, method, initializer };
    const ClassType = enum { none, class, subclass };

    pub const Error = std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator, interpreter: *Interpreter) Resolver {
        return .{ .gpa = gpa, .interpreter = interpreter };
    }

    pub fn resolveProgram(self: *Resolver, statements: []const Stmt) Error!void {
        try self.resolveStatements(statements);
    }

    fn resolveStatements(self: *Resolver, statements: []const Stmt) Error!void {
        for (statements) |stmt| try self.resolveStmt(stmt);
    }

    fn resolveStmt(self: *Resolver, stmt: Stmt) Error!void {
        switch (stmt) {
            .expression => |e| try self.resolveExpr(e.expression),
            .print => |p| try self.resolveExpr(p.expression),
            .var_decl => |v| {
                try self.declare(v.name);
                if (v.initializer) |init_expr| try self.resolveExpr(init_expr);
                try self.define(v.name);
            },
            .block => |blk| {
                try self.beginScope();
                try self.resolveStatements(blk.statements);
                self.endScope();
            },
            .if_stmt => |s| {
                try self.resolveExpr(s.condition);
                try self.resolveStmt(s.then_branch);
                if (s.else_branch) |else_branch| try self.resolveStmt(else_branch);
            },
            .while_stmt => |s| {
                try self.resolveExpr(s.condition);
                try self.resolveStmt(s.body);
            },
            .function => |f| {
                // Declare+define the name before the body, so the
                // function can call itself recursively.
                try self.declare(f.name);
                try self.define(f.name);
                try self.resolveFunctionBody(f, .function);
            },
            .return_stmt => |r| {
                if (self.current_function == .none) {
                    self.reportError(r.keyword, "Can't use 'return' outside of a function.");
                }
                if (r.value) |value_expr| {
                    if (self.current_function == .initializer) {
                        self.reportError(r.keyword, "Can't return a value from an initializer.");
                    }
                    try self.resolveExpr(value_expr);
                }
            },
            .class_stmt => |c| try self.resolveClass(c),
        }
    }

    fn resolveClass(self: *Resolver, c: *const Stmt.Class) Error!void {
        const enclosing_class = self.current_class;
        self.current_class = .class;
        defer self.current_class = enclosing_class;

        try self.declare(c.name);
        try self.define(c.name);

        if (c.superclass) |sc| {
            if (std.mem.eql(u8, sc.name.lexeme, c.name.lexeme)) {
                self.reportError(sc.name, "A class can't inherit from itself.");
            }
            self.current_class = .subclass;
            try self.resolveLocal(sc, sc.name);

            try self.beginScope();
            try self.defineRaw("super");
        }
        defer if (c.superclass != null) self.endScope();

        try self.beginScope();
        try self.defineRaw("this");
        defer self.endScope();

        for (c.methods) |method_stmt| {
            const method = method_stmt.function;
            const fn_type: FunctionType = if (std.mem.eql(u8, method.name.lexeme, "init"))
                .initializer
            else
                .method;
            try self.resolveFunctionBody(method, fn_type);
        }
    }

    fn resolveFunctionBody(self: *Resolver, f: *const Stmt.Function, fn_type: FunctionType) Error!void {
        const enclosing_function = self.current_function;
        self.current_function = fn_type;
        defer self.current_function = enclosing_function;

        try self.beginScope();
        for (f.params) |param| {
            try self.declare(param);
            try self.define(param);
        }
        try self.resolveStatements(f.body);
        self.endScope();
    }

    fn resolveExpr(self: *Resolver, expr: Expr) Error!void {
        switch (expr) {
            .literal => {},
            .grouping => |g| try self.resolveExpr(g.expression),
            .unary => |u| try self.resolveExpr(u.right),
            .binary => |b| {
                try self.resolveExpr(b.left);
                try self.resolveExpr(b.right);
            },
            .logical => |l| {
                try self.resolveExpr(l.left);
                try self.resolveExpr(l.right);
            },
            .call => |c| {
                try self.resolveExpr(c.callee);
                for (c.arguments) |arg| try self.resolveExpr(arg);
            },
            .variable => |v| {
                if (self.scopes.items.len > 0) {
                    const current = &self.scopes.items[self.scopes.items.len - 1];
                    if (current.get(v.name.lexeme)) |ready| {
                        if (!ready) {
                            self.reportError(v.name, "Can't read a local variable in its own initializer.");
                        }
                    }
                }
                try self.resolveLocal(v, v.name);
            },
            .assign => |a| {
                try self.resolveExpr(a.value);
                try self.resolveLocal(a, a.name);
            },
            .get => |g| try self.resolveExpr(g.object),
            .set => |s| {
                try self.resolveExpr(s.value);
                try self.resolveExpr(s.object);
            },
            .this_expr => |t| {
                if (self.current_class == .none) {
                    self.reportError(t.keyword, "Can't use 'this' outside of a class.");
                    return;
                }
                try self.resolveLocal(t, t.keyword);
            },
            .super_expr => |s| {
                if (self.current_class == .none) {
                    self.reportError(s.keyword, "Can't use 'super' outside of a class.");
                } else if (self.current_class != .subclass) {
                    self.reportError(s.keyword, "Can't use 'super' in a class with no superclass.");
                }
                try self.resolveLocal(s, s.keyword);
            },
        }
    }

    /// Searches for `name` from the inside out on the scope stack. Found:
    /// report the number of levels in between to the interpreter. Not
    /// found: do nothing at all - then the interpreter treats it as
    /// global at runtime (see `lookUpVariable`).
    fn resolveLocal(self: *Resolver, node_ptr: anytype, name: Token) Error!void {
        if (self.scopes.items.len == 0) return;
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].contains(name.lexeme)) {
                try self.interpreter.resolve(node_ptr, self.scopes.items.len - 1 - i);
                return;
            }
        }
    }

    fn beginScope(self: *Resolver) Error!void {
        try self.scopes.append(self.gpa, std.StringHashMap(bool).init(self.gpa));
    }

    fn endScope(self: *Resolver) void {
        var scope = self.scopes.pop().?;
        scope.deinit();
    }

    fn declare(self: *Resolver, name: Token) Error!void {
        if (self.scopes.items.len == 0) return;
        var scope = &self.scopes.items[self.scopes.items.len - 1];
        if (scope.contains(name.lexeme)) {
            self.reportError(name, "Already a variable with this name in this scope.");
        }
        try scope.put(name.lexeme, false);
    }

    fn define(self: *Resolver, name: Token) Error!void {
        if (self.scopes.items.len == 0) return;
        var scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.put(name.lexeme, true);
    }

    fn defineRaw(self: *Resolver, name: []const u8) Error!void {
        if (self.scopes.items.len == 0) return;
        var scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.put(name, true);
    }

    fn reportError(self: *Resolver, token: Token, message: []const u8) void {
        self.had_error = true;
        std.debug.print("[line {d}] Error at '{s}': {s}\n", .{ token.line, token.lexeme, message });
    }
};
