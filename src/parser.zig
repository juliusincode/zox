const std = @import("std");
const tok = @import("token.zig");
const Token = tok.Token;
const TokenType = tok.TokenType;
const expr_mod = @import("expr.zig");
const Expr = expr_mod.Expr;
const stmt_mod = @import("stmt.zig");
const Stmt = stmt_mod.Stmt;
const Scanner = @import("scanner.zig").Scanner;
const ast_printer = @import("ast_printer.zig");

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,
    gpa: std.mem.Allocator,
    had_error: bool = false,

    pub const Error = error{ParseError} || std.mem.Allocator.Error;

    pub fn init(gpa: std.mem.Allocator, tokens: []const Token) Parser {
        return .{ .tokens = tokens, .gpa = gpa };
    }

    pub fn parse(self: *Parser) Error!Expr {
        return self.expression();
    }

    /// A whole program: a list of declarations up to EOF. An error in a
    /// single statement doesn't take the whole script down with it
    /// (panic-mode recovery via `synchronize`) - it's just left out of the
    /// result.
    pub fn parseProgram(self: *Parser) Error![]const Stmt {
        var statements: std.ArrayList(Stmt) = .empty;
        while (!self.isAtEnd()) {
            if (try self.declaration()) |stmt| {
                try statements.append(self.gpa, stmt);
            }
        }
        return statements.toOwnedSlice(self.gpa);
    }

    fn declaration(self: *Parser) Error!?Stmt {
        const result: Error!Stmt = if (self.match(&.{.kw_class}))
            self.classDeclaration()
        else if (self.match(&.{.kw_fun}))
            self.functionDeclaration()
        else if (self.match(&.{.kw_var}))
            self.varDeclaration()
        else
            self.statement();

        return result catch |e| {
            switch (e) {
                error.ParseError => {
                    self.synchronize();
                    return null;
                },
                else => return e,
            }
        };
    }

    fn functionDeclaration(self: *Parser) Error!Stmt {
        const name = try self.consume(.identifier, "Expect function name.");
        return self.finishFunction(name);
    }

    /// Shared by `fun` declarations and methods inside a class body -
    /// both have exactly the same shape from the name onward,
    /// `(params) { body }`; a method just has no leading `fun`.
    fn finishFunction(self: *Parser, name: Token) Error!Stmt {
        _ = try self.consume(.left_paren, "Expect '(' after name.");

        var params: std.ArrayList(Token) = .empty;
        if (!self.check(.right_paren)) {
            try params.append(self.gpa, try self.consume(.identifier, "Expect parameter name."));
            while (self.match(&.{.comma})) {
                if (params.items.len >= 255) {
                    self.reportError(self.peek(), "Can't have more than 255 parameters.");
                }
                try params.append(self.gpa, try self.consume(.identifier, "Expect parameter name."));
            }
        }
        _ = try self.consume(.right_paren, "Expect ')' after parameters.");

        _ = try self.consume(.left_brace, "Expect '{' before body.");
        const body_stmt = try self.blockStatement();

        return try Stmt.functionStmt(self.gpa, name, try params.toOwnedSlice(self.gpa), body_stmt.block.statements);
    }

    fn classDeclaration(self: *Parser) Error!Stmt {
        const name = try self.consume(.identifier, "Expect class name.");

        var superclass: ?*Expr.Variable = null;
        if (self.match(&.{.less})) {
            const superclass_name = try self.consume(.identifier, "Expect superclass name.");
            const superclass_expr = try Expr.variableExpr(self.gpa, superclass_name);
            superclass = superclass_expr.variable;
        }

        _ = try self.consume(.left_brace, "Expect '{' before class body.");

        var methods: std.ArrayList(Stmt) = .empty;
        while (!self.check(.right_brace) and !self.isAtEnd()) {
            const method_name = try self.consume(.identifier, "Expect method name.");
            try methods.append(self.gpa, try self.finishFunction(method_name));
        }

        _ = try self.consume(.right_brace, "Expect '}' after class body.");

        return try Stmt.classStmt(self.gpa, name, superclass, try methods.toOwnedSlice(self.gpa));
    }

    fn varDeclaration(self: *Parser) Error!Stmt {
        const name = try self.consume(.identifier, "Expect variable name.");
        var initializer: ?Expr = null;
        if (self.match(&.{.equal})) {
            initializer = try self.expression();
        }
        _ = try self.consume(.semicolon, "Expect ';' after variable declaration.");
        return try Stmt.varDecl(self.gpa, name, initializer);
    }

    fn statement(self: *Parser) Error!Stmt {
        if (self.match(&.{.kw_if})) return self.ifStatement();
        if (self.match(&.{.kw_while})) return self.whileStatement();
        if (self.match(&.{.kw_for})) return self.forStatement();
        if (self.match(&.{.kw_print})) return self.printStatement();
        if (self.match(&.{.kw_return})) return self.returnStatement();
        if (self.match(&.{.left_brace})) return self.blockStatement();
        return self.expressionStatement();
    }

    fn returnStatement(self: *Parser) Error!Stmt {
        const keyword = self.previous();
        var value: ?Expr = null;
        if (!self.check(.semicolon)) {
            value = try self.expression();
        }
        _ = try self.consume(.semicolon, "Expect ';' after return value.");
        return try Stmt.returnStmt(self.gpa, keyword, value);
    }

    fn ifStatement(self: *Parser) Error!Stmt {
        _ = try self.consume(.left_paren, "Expect '(' after 'if'.");
        const condition = try self.expression();
        _ = try self.consume(.right_paren, "Expect ')' after condition.");

        const then_branch = try self.statement();
        var else_branch: ?Stmt = null;
        if (self.match(&.{.kw_else})) {
            else_branch = try self.statement();
        }
        return try Stmt.ifStmt(self.gpa, condition, then_branch, else_branch);
    }

    fn whileStatement(self: *Parser) Error!Stmt {
        _ = try self.consume(.left_paren, "Expect '(' after 'while'.");
        const condition = try self.expression();
        _ = try self.consume(.right_paren, "Expect ')' after condition.");
        const body = try self.statement();
        return try Stmt.whileStmt(self.gpa, condition, body);
    }

    /// `for` is not its own AST node - we build it directly out of Block +
    /// While ("desugaring", just like in the book). A
    /// `for (init; cond; incr) body` becomes:
    ///   { init; while (cond) { body; incr; } }
    fn forStatement(self: *Parser) Error!Stmt {
        _ = try self.consume(.left_paren, "Expect '(' after 'for'.");

        var initializer: ?Stmt = null;
        if (self.match(&.{.semicolon})) {
            initializer = null;
        } else if (self.match(&.{.kw_var})) {
            initializer = try self.varDeclaration();
        } else {
            initializer = try self.expressionStatement();
        }

        var condition: ?Expr = null;
        if (!self.check(.semicolon)) {
            condition = try self.expression();
        }
        _ = try self.consume(.semicolon, "Expect ';' after loop condition.");

        var increment: ?Expr = null;
        if (!self.check(.right_paren)) {
            increment = try self.expression();
        }
        _ = try self.consume(.right_paren, "Expect ')' after for clauses.");

        var body = try self.statement();

        if (increment) |inc| {
            const stmts = try self.gpa.alloc(Stmt, 2);
            stmts[0] = body;
            stmts[1] = try Stmt.expressionStmt(self.gpa, inc);
            body = try Stmt.blockStmt(self.gpa, stmts);
        }

        const loop_condition = condition orelse try Expr.literalExpr(self.gpa, .{ .boolean = true });
        body = try Stmt.whileStmt(self.gpa, loop_condition, body);

        if (initializer) |init_stmt| {
            const stmts = try self.gpa.alloc(Stmt, 2);
            stmts[0] = init_stmt;
            stmts[1] = body;
            body = try Stmt.blockStmt(self.gpa, stmts);
        }

        return body;
    }

    fn printStatement(self: *Parser) Error!Stmt {
        const value = try self.expression();
        _ = try self.consume(.semicolon, "Expect ';' after value.");
        return try Stmt.printStmt(self.gpa, value);
    }

    fn expressionStatement(self: *Parser) Error!Stmt {
        const value = try self.expression();
        _ = try self.consume(.semicolon, "Expect ';' after expression.");
        return try Stmt.expressionStmt(self.gpa, value);
    }

    fn blockStatement(self: *Parser) Error!Stmt {
        var statements: std.ArrayList(Stmt) = .empty;
        while (!self.check(.right_brace) and !self.isAtEnd()) {
            if (try self.declaration()) |s| try statements.append(self.gpa, s);
        }
        _ = try self.consume(.right_brace, "Expect '}' after block.");
        return try Stmt.blockStmt(self.gpa, try statements.toOwnedSlice(self.gpa));
    }

    // expression -> assignment
    fn expression(self: *Parser) Error!Expr {
        return self.assignment();
    }

    // assignment -> ( call "." )? IDENTIFIER "=" assignment | logic_or
    fn assignment(self: *Parser) Error!Expr {
        const expr = try self.orExpr();

        if (self.match(&.{.equal})) {
            const equals = self.previous();
            const value = try self.assignment();

            if (expr == .variable) {
                return Expr.assignExpr(self.gpa, expr.variable.name, value);
            }
            if (expr == .get) {
                const get = expr.get;
                return Expr.setExpr(self.gpa, get.object, get.name, value);
            }

            // No `throw`: an invalid assignment target doesn't throw the
            // parser off track, we just report it and keep going.
            self.reportError(equals, "Invalid assignment target.");
            return expr;
        }

        return expr;
    }

    // logic_or -> logic_and ( "or" logic_and )*
    fn orExpr(self: *Parser) Error!Expr {
        var expr = try self.andExpr();
        while (self.match(&.{.kw_or})) {
            const operator = self.previous();
            const right = try self.andExpr();
            expr = try Expr.logicalExpr(self.gpa, expr, operator, right);
        }
        return expr;
    }

    // logic_and -> equality ( "and" equality )*
    fn andExpr(self: *Parser) Error!Expr {
        var expr = try self.equality();
        while (self.match(&.{.kw_and})) {
            const operator = self.previous();
            const right = try self.equality();
            expr = try Expr.logicalExpr(self.gpa, expr, operator, right);
        }
        return expr;
    }

    // equality -> comparison ( ( "!=" | "==" ) comparison )*
    fn equality(self: *Parser) Error!Expr {
        var expr = try self.comparison();
        while (self.match(&.{ .bang_equal, .equal_equal })) {
            const operator = self.previous();
            const right = try self.comparison();
            expr = try Expr.binaryExpr(self.gpa, expr, operator, right);
        }
        return expr;
    }

    // comparison -> term ( ( ">" | ">=" | "<" | "<=" ) term )*
    fn comparison(self: *Parser) Error!Expr {
        var expr = try self.term();
        while (self.match(&.{ .greater, .greater_equal, .less, .less_equal })) {
            const operator = self.previous();
            const right = try self.term();
            expr = try Expr.binaryExpr(self.gpa, expr, operator, right);
        }
        return expr;
    }

    // term -> factor ( ( "-" | "+" ) factor )*
    fn term(self: *Parser) Error!Expr {
        var expr = try self.factor();
        while (self.match(&.{ .minus, .plus })) {
            const operator = self.previous();
            const right = try self.factor();
            expr = try Expr.binaryExpr(self.gpa, expr, operator, right);
        }
        return expr;
    }

    // factor -> unary ( ( "/" | "*" ) unary )*
    fn factor(self: *Parser) Error!Expr {
        var expr = try self.unary();
        while (self.match(&.{ .slash, .star })) {
            const operator = self.previous();
            const right = try self.unary();
            expr = try Expr.binaryExpr(self.gpa, expr, operator, right);
        }
        return expr;
    }

    // unary -> ( "!" | "-" ) unary | call
    fn unary(self: *Parser) Error!Expr {
        if (self.match(&.{ .bang, .minus })) {
            const operator = self.previous();
            const right = try self.unary();
            return Expr.unaryExpr(self.gpa, operator, right);
        }
        return self.call();
    }

    // call -> primary ( "(" arguments? ")" | "." IDENTIFIER )*
    fn call(self: *Parser) Error!Expr {
        var expr = try self.primary();
        while (true) {
            if (self.match(&.{.left_paren})) {
                expr = try self.finishCall(expr);
            } else if (self.match(&.{.dot})) {
                const name = try self.consume(.identifier, "Expect property name after '.'.");
                expr = try Expr.getExpr(self.gpa, expr, name);
            } else {
                break;
            }
        }
        return expr;
    }

    // arguments -> expression ( "," expression )*
    fn finishCall(self: *Parser, callee: Expr) Error!Expr {
        var arguments: std.ArrayList(Expr) = .empty;
        if (!self.check(.right_paren)) {
            try arguments.append(self.gpa, try self.expression());
            while (self.match(&.{.comma})) {
                if (arguments.items.len >= 255) {
                    self.reportError(self.peek(), "Can't have more than 255 arguments.");
                }
                try arguments.append(self.gpa, try self.expression());
            }
        }
        const paren = try self.consume(.right_paren, "Expect ')' after arguments.");
        return Expr.callExpr(self.gpa, callee, paren, try arguments.toOwnedSlice(self.gpa));
    }

    // primary -> NUMBER | STRING | "true" | "false" | "nil" | "(" expression ")"
    fn primary(self: *Parser) Error!Expr {
        if (self.match(&.{.kw_false})) return Expr.literalExpr(self.gpa, .{ .boolean = false });
        if (self.match(&.{.kw_true})) return Expr.literalExpr(self.gpa, .{ .boolean = true });
        if (self.match(&.{.kw_nil})) return Expr.literalExpr(self.gpa, .{ .nil = {} });

        if (self.match(&.{.number})) {
            const literal = self.previous().literal;
            return Expr.literalExpr(self.gpa, .{ .number = literal.number });
        }
        if (self.match(&.{.string})) {
            const literal = self.previous().literal;
            return Expr.literalExpr(self.gpa, .{ .string = literal.string });
        }
        if (self.match(&.{.identifier})) {
            return Expr.variableExpr(self.gpa, self.previous());
        }
        if (self.match(&.{.kw_this})) {
            return Expr.thisExpr(self.gpa, self.previous());
        }
        if (self.match(&.{.kw_super})) {
            const keyword = self.previous();
            _ = try self.consume(.dot, "Expect '.' after 'super'.");
            const method = try self.consume(.identifier, "Expect method name after 'super.'.");
            return Expr.superExpr(self.gpa, keyword, method);
        }
        if (self.match(&.{.left_paren})) {
            const inner = try self.expression();
            _ = try self.consume(.right_paren, "Expect ')' after expression.");
            return Expr.groupingExpr(self.gpa, inner);
        }

        return self.fail(self.peek(), "Expect expression.");
    }

    fn match(self: *Parser, types: []const TokenType) bool {
        for (types) |t| {
            if (self.check(t)) {
                _ = self.advance();
                return true;
            }
        }
        return false;
    }

    fn check(self: *const Parser, t: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == t;
    }

    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    fn isAtEnd(self: *const Parser) bool {
        return self.peek().type == .eof;
    }

    fn peek(self: *const Parser) Token {
        return self.tokens[self.current];
    }

    fn previous(self: *const Parser) Token {
        return self.tokens[self.current - 1];
    }

    fn consume(self: *Parser, t: TokenType, message: []const u8) Error!Token {
        if (self.check(t)) return self.advance();
        return self.fail(self.peek(), message);
    }

    fn fail(self: *Parser, token: Token, message: []const u8) Error {
        self.reportError(token, message);
        return error.ParseError;
    }

    fn reportError(self: *Parser, token: Token, message: []const u8) void {
        self.had_error = true;
        if (token.type == .eof) {
            std.debug.print("[line {d}] Error at end: {s}\n", .{ token.line, message });
        } else {
            std.debug.print("[line {d}] Error at '{s}': {s}\n", .{ token.line, token.lexeme, message });
        }
    }

    /// Discards tokens until the next likely statement boundary. Not
    /// called yet at this point (that needs statements from step 4
    /// first), but already in place.
    fn synchronize(self: *Parser) void {
        _ = self.advance();
        while (!self.isAtEnd()) {
            if (self.previous().type == .semicolon) return;
            switch (self.peek().type) {
                .kw_class, .kw_fun, .kw_var, .kw_for, .kw_if, .kw_while, .kw_print, .kw_return => return,
                else => {},
            }
            _ = self.advance();
        }
    }
};

test "parser respects operator precedence" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var scanner = Scanner.init("1 + 2 * 3 - -4");
    defer scanner.deinit(gpa);
    const tokens = try scanner.scanTokens(gpa);

    var parser = Parser.init(arena, tokens);
    const expression = try parser.parse();

    const result = try ast_printer.print(gpa, expression);
    defer gpa.free(result);

    try std.testing.expectEqualStrings("(- (+ 1 (* 2 3)) (- 4))", result);
}

test "parser handles grouping" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var scanner = Scanner.init("(1 + 2) * 3");
    defer scanner.deinit(gpa);
    const tokens = try scanner.scanTokens(gpa);

    var parser = Parser.init(arena, tokens);
    const expression = try parser.parse();

    const result = try ast_printer.print(gpa, expression);
    defer gpa.free(result);

    try std.testing.expectEqualStrings("(* (group (+ 1 2)) 3)", result);
}

test "parser reports an error on unterminated grouping" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var scanner = Scanner.init("(1 + 2");
    defer scanner.deinit(gpa);
    const tokens = try scanner.scanTokens(gpa);

    var parser = Parser.init(arena, tokens);
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expect(parser.had_error);
}
