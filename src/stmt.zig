const std = @import("std");
const Token = @import("token.zig").Token;
const Expr = @import("expr.zig").Expr;

/// A statement node. Analogous to Expr: tagged union, every variant a
/// pointer to its payload.
pub const Stmt = union(enum) {
    expression: *Expression,
    print: *Print,
    var_decl: *Var,
    block: *Block,
    if_stmt: *If,
    while_stmt: *While,
    function: *Function,
    return_stmt: *Return,
    class_stmt: *Class,

    pub const Expression = struct {
        expression: Expr,
    };

    pub const Print = struct {
        expression: Expr,
    };

    pub const Var = struct {
        name: Token,
        initializer: ?Expr,
    };

    pub const Block = struct {
        statements: []const Stmt,
    };

    /// `then_branch`/`else_branch` are of type `Stmt` (not `*Stmt`) -
    /// Stmt is already small (tag + pointer), another level of
    /// indirection would only load extra memory for nothing.
    pub const If = struct {
        condition: Expr,
        then_branch: Stmt,
        else_branch: ?Stmt,
    };

    pub const While = struct {
        condition: Expr,
        body: Stmt,
    };

    pub const Function = struct {
        name: Token,
        params: []const Token,
        body: []const Stmt,
    };

    /// `value` is optional because `return;` with no value (== `nil`) is allowed.
    pub const Return = struct {
        keyword: Token,
        value: ?Expr,
    };

    /// `superclass` is deliberately a `*Expr.Variable` (not just a
    /// Token): that way the resolver can treat it just like any other
    /// variable reference (pointer identity as the key). `methods` are
    /// all `.function` Stmt nodes, reused from the same parser code path
    /// as regular `fun` declarations.
    pub const Class = struct {
        name: Token,
        superclass: ?*Expr.Variable,
        methods: []const Stmt,
    };

    pub fn expressionStmt(gpa: std.mem.Allocator, expression: Expr) !Stmt {
        const node = try gpa.create(Expression);
        node.* = .{ .expression = expression };
        return .{ .expression = node };
    }

    pub fn printStmt(gpa: std.mem.Allocator, expression: Expr) !Stmt {
        const node = try gpa.create(Print);
        node.* = .{ .expression = expression };
        return .{ .print = node };
    }

    pub fn varDecl(gpa: std.mem.Allocator, name: Token, initializer: ?Expr) !Stmt {
        const node = try gpa.create(Var);
        node.* = .{ .name = name, .initializer = initializer };
        return .{ .var_decl = node };
    }

    pub fn blockStmt(gpa: std.mem.Allocator, statements: []const Stmt) !Stmt {
        const node = try gpa.create(Block);
        node.* = .{ .statements = statements };
        return .{ .block = node };
    }

    pub fn ifStmt(gpa: std.mem.Allocator, condition: Expr, then_branch: Stmt, else_branch: ?Stmt) !Stmt {
        const node = try gpa.create(If);
        node.* = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch };
        return .{ .if_stmt = node };
    }

    pub fn whileStmt(gpa: std.mem.Allocator, condition: Expr, body: Stmt) !Stmt {
        const node = try gpa.create(While);
        node.* = .{ .condition = condition, .body = body };
        return .{ .while_stmt = node };
    }

    pub fn functionStmt(gpa: std.mem.Allocator, name: Token, params: []const Token, body: []const Stmt) !Stmt {
        const node = try gpa.create(Function);
        node.* = .{ .name = name, .params = params, .body = body };
        return .{ .function = node };
    }

    pub fn returnStmt(gpa: std.mem.Allocator, keyword: Token, value: ?Expr) !Stmt {
        const node = try gpa.create(Return);
        node.* = .{ .keyword = keyword, .value = value };
        return .{ .return_stmt = node };
    }

    pub fn classStmt(gpa: std.mem.Allocator, name: Token, superclass: ?*Expr.Variable, methods: []const Stmt) !Stmt {
        const node = try gpa.create(Class);
        node.* = .{ .name = name, .superclass = superclass, .methods = methods };
        return .{ .class_stmt = node };
    }
};
