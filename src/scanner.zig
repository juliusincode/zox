const std = @import("std");
const tok = @import("token.zig");
const Token = tok.Token;
const TokenType = tok.TokenType;

pub const Scanner = struct {
    source: []const u8,
    tokens: std.ArrayList(Token) = .empty,
    start: usize = 0,
    current: usize = 0,
    line: usize = 1,
    had_error: bool = false,

    pub fn init(source: []const u8) Scanner {
        return .{ .source = source };
    }

    pub fn deinit(self: *Scanner, gpa: std.mem.Allocator) void {
        self.tokens.deinit(gpa);
    }

    pub fn scanTokens(self: *Scanner, gpa: std.mem.Allocator) ![]const Token {
        while (!self.isAtEnd()) {
            self.start = self.current;
            try self.scanToken(gpa);
        }
        try self.tokens.append(gpa, .{
            .type = .eof, .lexeme = "", .literal = .none, .line = self.line,
        });
        return self.tokens.items;
    }

    fn isAtEnd(self: *const Scanner) bool {
        return self.current >= self.source.len;
    }

    fn advance(self: *Scanner) u8 {
        const c = self.source[self.current];
        self.current += 1;
        return c;
    }

    fn peek(self: *const Scanner) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *const Scanner) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd() or self.source[self.current] != expected) return false;
        self.current += 1;
        return true;
    }

    fn addToken(self: *Scanner, gpa: std.mem.Allocator, t: TokenType) !void {
        try self.addTokenLit(gpa, t, .none);
    }

    fn addTokenLit(self: *Scanner, gpa: std.mem.Allocator, t: TokenType, literal: tok.Literal) !void {
        try self.tokens.append(gpa, .{
            .type = t,
            .lexeme = self.source[self.start..self.current],
            .literal = literal,
            .line = self.line,
        });
    }

    fn scanToken(self: *Scanner, gpa: std.mem.Allocator) !void {
        const c = self.advance();
        switch (c) {
            '(' => try self.addToken(gpa, .left_paren),
            ')' => try self.addToken(gpa, .right_paren),
            '{' => try self.addToken(gpa, .left_brace),
            '}' => try self.addToken(gpa, .right_brace),
            ',' => try self.addToken(gpa, .comma),
            '.' => try self.addToken(gpa, .dot),
            '-' => try self.addToken(gpa, .minus),
            '+' => try self.addToken(gpa, .plus),
            ';' => try self.addToken(gpa, .semicolon),
            '*' => try self.addToken(gpa, .star),
            '!' => try self.addToken(gpa, if (self.match('=')) .bang_equal else .bang),
            '=' => try self.addToken(gpa, if (self.match('=')) .equal_equal else .equal),
            '<' => try self.addToken(gpa, if (self.match('=')) .less_equal else .less),
            '>' => try self.addToken(gpa, if (self.match('=')) .greater_equal else .greater),
            '/' => {
                if (self.match('/')) {
                    while (self.peek() != '\n' and !self.isAtEnd()) _ = self.advance();
                } else {
                    try self.addToken(gpa, .slash);
                }
            },
            ' ', '\r', '\t' => {},
            '\n' => self.line += 1,
            '"' => try self.string(gpa),
            else => {
                if (isDigit(c)) {
                    try self.number(gpa);
                } else if (isAlpha(c)) {
                    try self.identifier(gpa);
                } else {
                    std.debug.print("[line {d}] Error: unexpected character '{c}'\n", .{ self.line, c });
                    self.had_error = true;
                }
            },
        }
    }

    fn string(self: *Scanner, gpa: std.mem.Allocator) !void {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
        }
        if (self.isAtEnd()) {
            std.debug.print("[line {d}] Error: unterminated string\n", .{self.line});
            self.had_error = true;
            return;
        }
        _ = self.advance(); // closing "
        const value = self.source[self.start + 1 .. self.current - 1];
        try self.addTokenLit(gpa, .string, .{ .string = value });
    }

    fn number(self: *Scanner, gpa: std.mem.Allocator) !void {
        while (isDigit(self.peek())) _ = self.advance();
        if (self.peek() == '.' and isDigit(self.peekNext())) {
            _ = self.advance();
            while (isDigit(self.peek())) _ = self.advance();
        }
        const text = self.source[self.start..self.current];
        const value = std.fmt.parseFloat(f64, text) catch unreachable;
        try self.addTokenLit(gpa, .number, .{ .number = value });
    }

    fn identifier(self: *Scanner, gpa: std.mem.Allocator) !void {
        while (isAlphaNumeric(self.peek())) _ = self.advance();
        const text = self.source[self.start..self.current];
        const ttype = tok.keywords.get(text) orelse .identifier;
        try self.addToken(gpa, ttype);
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
    fn isAlphaNumeric(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }
};
