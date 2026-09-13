const std = @import("std");
const Scanner = @import("scanner.zig").Scanner;
const Parser = @import("parser.zig").Parser;
const Interpreter = @import("interpreter.zig").Interpreter;
const Environment = @import("environment.zig").Environment;
const Resolver = @import("resolver.zig").Resolver;

pub fn main(init: std.process.Init) !void {
    // We deliberately only use the arena: per the docs it's "permanent
    // storage for the entire process, cleaned automatically on exit". For
    // a short-lived CLI tool like zox this saves a ton of manual
    // deinit/free calls for AST nodes, environment bindings, and runtime
    // string concatenations - it all dies together when the process exits.
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 2) {
        std.debug.print("Usage: zox <script.zox>\n", .{});
        std.process.exit(64);
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1024 * 1024));

    var scanner = Scanner.init(source);
    const tokens = try scanner.scanTokens(arena);
    if (scanner.had_error) std.process.exit(65);

    var parser = Parser.init(arena, tokens);
    const statements = try parser.parseProgram();
    if (parser.had_error) std.process.exit(65);

    var environment = Environment.init(arena);

    var interpreter = Interpreter.init(arena, &environment);

    var resolver = Resolver.init(arena, &interpreter);
    try resolver.resolveProgram(statements);
    if (resolver.had_error) std.process.exit(65);

    interpreter.interpretProgram(statements);

    if (interpreter.had_runtime_error) std.process.exit(70);
}
