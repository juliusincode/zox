const std = @import("std");
const expr_mod = @import("expr.zig");
const Expr = expr_mod.Expr;
const token = @import("token.zig");

/// Returns a parenthesized notation of the expression, e.g. "(* (- 123) (group 45.67))".
/// The return value belongs to the caller (free with `gpa`).
pub fn print(gpa: std.mem.Allocator, expr: Expr) PrintError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printExpr(gpa, &out, expr);
    return out.toOwnedSlice(gpa);
}

const PrintError = std.mem.Allocator.Error || error{NoSpaceLeft};

fn printExpr(gpa: std.mem.Allocator, out: *std.ArrayList(u8), expr: Expr) PrintError!void {
    switch (expr) {
        .binary => |b| try parenthesize(gpa, out, b.operator.lexeme, &.{ b.left, b.right }),
        .grouping => |g| try parenthesize(gpa, out, "group", &.{g.expression}),
        .literal => |l| try printLiteral(gpa, out, l.value),
        .unary => |u| try parenthesize(gpa, out, u.operator.lexeme, &.{u.right}),
        .variable => |v| try out.appendSlice(gpa, v.name.lexeme),
        .assign => |a| {
            try out.appendSlice(gpa, "(= ");
            try out.appendSlice(gpa, a.name.lexeme);
            try out.append(gpa, ' ');
            try printExpr(gpa, out, a.value);
            try out.append(gpa, ')');
        },
        .logical => |l| try parenthesize(gpa, out, l.operator.lexeme, &.{ l.left, l.right }),
        .call => |c| {
            try out.appendSlice(gpa, "(call ");
            try printExpr(gpa, out, c.callee);
            for (c.arguments) |arg| {
                try out.append(gpa, ' ');
                try printExpr(gpa, out, arg);
            }
            try out.append(gpa, ')');
        },
        .get => |g| {
            try printExpr(gpa, out, g.object);
            try out.append(gpa, '.');
            try out.appendSlice(gpa, g.name.lexeme);
        },
        .set => |s| {
            try out.appendSlice(gpa, "(set ");
            try printExpr(gpa, out, s.object);
            try out.append(gpa, '.');
            try out.appendSlice(gpa, s.name.lexeme);
            try out.append(gpa, ' ');
            try printExpr(gpa, out, s.value);
            try out.append(gpa, ')');
        },
        .this_expr => try out.appendSlice(gpa, "this"),
        .super_expr => |s| {
            try out.appendSlice(gpa, "(super.");
            try out.appendSlice(gpa, s.method.lexeme);
            try out.append(gpa, ')');
        },
    }
}

fn printLiteral(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: expr_mod.LiteralValue) PrintError!void {
    switch (value) {
        .number => |n| {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
            try out.appendSlice(gpa, s);
        },
        .string => |s| try out.appendSlice(gpa, s),
        .boolean => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .nil => try out.appendSlice(gpa, "nil"),
    }
}

fn parenthesize(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, exprs: []const Expr) PrintError!void {
    try out.append(gpa, '(');
    try out.appendSlice(gpa, name);
    for (exprs) |e| {
        try out.append(gpa, ' ');
        try printExpr(gpa, out, e);
    }
    try out.append(gpa, ')');
}

test "ast printer produces the canonical lisp-like output" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build by hand: -123 * (45.67)
    const minus = token.Token{ .type = .minus, .lexeme = "-", .literal = .none, .line = 1 };
    const star = token.Token{ .type = .star, .lexeme = "*", .literal = .none, .line = 1 };

    const lit_123 = try Expr.literalExpr(arena, .{ .number = 123 });
    const neg = try Expr.unaryExpr(arena, minus, lit_123);

    const lit_4567 = try Expr.literalExpr(arena, .{ .number = 45.67 });
    const grouping = try Expr.groupingExpr(arena, lit_4567);

    const expression = try Expr.binaryExpr(arena, neg, star, grouping);

    const result = try print(gpa, expression);
    defer gpa.free(result);

    try std.testing.expectEqualStrings("(* (- 123) (group 45.67))", result);
}
