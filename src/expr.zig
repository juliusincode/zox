const std = @import("std");
const Token = @import("token.zig").Token;

/// Runtime value of a literal node. Deliberately shaped so we can later
/// (step 5, evaluator) reuse it as the basis for our runtime value type
/// too - Lox's "Object" is at its core exactly these four cases.
pub const LiteralValue = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    nil,
};

/// An expression node. Every variant carries a pointer to its payload,
/// which keeps `Expr` itself small (tag + one pointer) and gives us the
/// self-reference (Binary contains Expr again) without infinite size.
pub const Expr = union(enum) {
    binary: *Binary,
    grouping: *Grouping,
    literal: *Literal,
    unary: *Unary,
    variable: *Variable,
    assign: *Assign,
    logical: *Logical,
    call: *Call,
    get: *Get,
    set: *Set,
    this_expr: *This,
    super_expr: *Super,

    pub const Binary = struct {
        left: Expr,
        operator: Token,
        right: Expr,
    };

    pub const Grouping = struct {
        expression: Expr,
    };

    pub const Literal = struct {
        value: LiteralValue,
    };

    pub const Unary = struct {
        operator: Token,
        right: Expr,
    };

    /// A variable reference, e.g. the `a` in `print a;`.
    pub const Variable = struct {
        name: Token,
    };

    /// An assignment, e.g. `a = 5`. This is itself an expression (it
    /// yields the assigned value), not a statement - that's why it lives
    /// here with Expr and not with Stmt.
    pub const Assign = struct {
        name: Token,
        value: Expr,
    };

    /// `and` / `or`. Deliberately separate from Binary: evaluation must be
    /// able to short-circuit (the right operand isn't always evaluated),
    /// which doesn't fit Binary's "evaluate both sides, then combine"
    /// scheme.
    pub const Logical = struct {
        left: Expr,
        operator: Token,
        right: Expr,
    };

    /// `paren` is the closing `)` - only used for error messages, so a
    /// runtime error at the call site can report a line number.
    pub const Call = struct {
        callee: Expr,
        paren: Token,
        arguments: []const Expr,
    };

    /// `instance.name` - reading access to a field or a method.
    pub const Get = struct {
        object: Expr,
        name: Token,
    };

    /// `instance.name = value` - writing access. Separate from `Assign`
    /// because the target isn't a simple identifier - `object` has to be
    /// evaluated first.
    pub const Set = struct {
        object: Expr,
        name: Token,
        value: Expr,
    };

    pub const This = struct {
        keyword: Token,
    };

    pub const Super = struct {
        keyword: Token,
        method: Token,
    };

    /// All constructors allocate through the given allocator. In practice
    /// that will be an arena: the whole tree of a statement lives together
    /// and dies together, no node needs to be freed individually.
    pub fn binaryExpr(gpa: std.mem.Allocator, left: Expr, operator: Token, right: Expr) !Expr {
        const node = try gpa.create(Binary);
        node.* = .{ .left = left, .operator = operator, .right = right };
        return .{ .binary = node };
    }

    pub fn groupingExpr(gpa: std.mem.Allocator, expression: Expr) !Expr {
        const node = try gpa.create(Grouping);
        node.* = .{ .expression = expression };
        return .{ .grouping = node };
    }

    pub fn literalExpr(gpa: std.mem.Allocator, value: LiteralValue) !Expr {
        const node = try gpa.create(Literal);
        node.* = .{ .value = value };
        return .{ .literal = node };
    }

    pub fn unaryExpr(gpa: std.mem.Allocator, operator: Token, right: Expr) !Expr {
        const node = try gpa.create(Unary);
        node.* = .{ .operator = operator, .right = right };
        return .{ .unary = node };
    }

    pub fn variableExpr(gpa: std.mem.Allocator, name: Token) !Expr {
        const node = try gpa.create(Variable);
        node.* = .{ .name = name };
        return .{ .variable = node };
    }

    pub fn assignExpr(gpa: std.mem.Allocator, name: Token, value: Expr) !Expr {
        const node = try gpa.create(Assign);
        node.* = .{ .name = name, .value = value };
        return .{ .assign = node };
    }

    pub fn logicalExpr(gpa: std.mem.Allocator, left: Expr, operator: Token, right: Expr) !Expr {
        const node = try gpa.create(Logical);
        node.* = .{ .left = left, .operator = operator, .right = right };
        return .{ .logical = node };
    }

    pub fn callExpr(gpa: std.mem.Allocator, callee: Expr, paren: Token, arguments: []const Expr) !Expr {
        const node = try gpa.create(Call);
        node.* = .{ .callee = callee, .paren = paren, .arguments = arguments };
        return .{ .call = node };
    }

    pub fn getExpr(gpa: std.mem.Allocator, object: Expr, name: Token) !Expr {
        const node = try gpa.create(Get);
        node.* = .{ .object = object, .name = name };
        return .{ .get = node };
    }

    pub fn setExpr(gpa: std.mem.Allocator, object: Expr, name: Token, value: Expr) !Expr {
        const node = try gpa.create(Set);
        node.* = .{ .object = object, .name = name, .value = value };
        return .{ .set = node };
    }

    pub fn thisExpr(gpa: std.mem.Allocator, keyword: Token) !Expr {
        const node = try gpa.create(This);
        node.* = .{ .keyword = keyword };
        return .{ .this_expr = node };
    }

    pub fn superExpr(gpa: std.mem.Allocator, keyword: Token, method: Token) !Expr {
        const node = try gpa.create(Super);
        node.* = .{ .keyword = keyword, .method = method };
        return .{ .super_expr = node };
    }
};
