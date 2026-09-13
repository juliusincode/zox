const std = @import("std");

pub const TokenType = enum {
    // Single-character tokens
    left_paren, right_paren, left_brace, right_brace,
    comma, dot, minus, plus, semicolon, slash, star,

    // One or two character tokens
    bang, bang_equal,
    equal, equal_equal,
    greater, greater_equal,
    less, less_equal,

    // Literals
    identifier, string, number,

    // Keywords
    kw_and, kw_class, kw_else, kw_false, kw_fun, kw_for,
    kw_if, kw_nil, kw_or, kw_print, kw_return, kw_super,
    kw_this, kw_true, kw_var, kw_while,

    eof,
};

pub const Literal = union(enum) {
    number: f64,
    string: []const u8,
    none,
};

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    literal: Literal,
    line: usize,
};

pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "and", .kw_and }, .{ "class", .kw_class }, .{ "else", .kw_else },
    .{ "false", .kw_false }, .{ "for", .kw_for }, .{ "fun", .kw_fun },
    .{ "if", .kw_if }, .{ "nil", .kw_nil }, .{ "or", .kw_or },
    .{ "print", .kw_print }, .{ "return", .kw_return }, .{ "super", .kw_super },
    .{ "this", .kw_this }, .{ "true", .kw_true }, .{ "var", .kw_var },
    .{ "while", .kw_while },
});
