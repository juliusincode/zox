const std = @import("std");
const Scanner = @import("scanner.zig").Scanner;
const Parser = @import("parser.zig").Parser;
const Interpreter = @import("interpreter.zig").Interpreter;
const Environment = @import("environment.zig").Environment;
const Resolver = @import("resolver.zig").Resolver;
const Value = @import("value.zig").Value;

pub fn main(init: std.process.Init) !void {
    // We deliberately only use the arena: per the docs it's "permanent
    // storage for the entire process, cleaned automatically on exit". For
    // a short-lived CLI tool like zox this saves a ton of manual
    // deinit/free calls for AST nodes, environment bindings, and runtime
    // string concatenations - it all dies together when the process exits.
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 2) {
        std.debug.print("Usage: zox [script.zox]\n", .{});
        std.debug.print("  (no args = interactive REPL)\n", .{});
        std.process.exit(64);
    }

    var environment = Environment.init(arena);
    var interpreter = Interpreter.init(arena, &environment);

    // Built-in natives (Crafting Interpreters §10.2)
    try interpreter.defineNative("clock", 0, nativeClock);

    if (args.len == 1) {
        try runRepl(arena, &interpreter);
    } else {
        try runFile(arena, io, args[1], &interpreter);
    }
}

fn nativeClock(gpa: std.mem.Allocator, args: []const Value) Value {
    _ = gpa;
    _ = args;
    // seconds since Unix epoch as f64 (matches the book's clock())
    var ts: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return .{ .number = 0 };
    const secs = @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1_000_000_000.0;
    return .{ .number = secs };
}

fn runFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, interpreter: *Interpreter) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
    try runSource(arena, source, interpreter, true);
    if (interpreter.had_runtime_error) std.process.exit(70);
}

fn runRepl(arena: std.mem.Allocator, interpreter: *Interpreter) !void {
    std.debug.print("zox REPL (Ctrl-D to exit)\n", .{});

    var line_buf: [4096]u8 = undefined;
    const stdin = std.posix.STDIN_FILENO;
    while (true) {
        std.debug.print("> ", .{});
        const n = std.posix.read(stdin, line_buf[0..]) catch |err| {
            if (err == error.InputOutput) break;
            return err;
        };
        if (n == 0) break; // EOF
        const line = std.mem.trimEnd(u8, line_buf[0..n], "\r\n");
        if (line.len == 0) continue;

        // Each REPL line gets a fresh sub-arena so temporary AST nodes
        // from previous lines don't keep growing forever.
        var line_arena = std.heap.ArenaAllocator.init(arena);
        defer line_arena.deinit();
        const line_gpa = line_arena.allocator();

        // Reset error flags so one bad line doesn't kill the session.
        interpreter.had_runtime_error = false;

        runSource(line_gpa, line, interpreter, false) catch |e| {
            std.debug.print("Error: {s}\n", .{@errorName(e)});
            continue;
        };
    }
    std.debug.print("\n", .{});
}

fn runSource(gpa: std.mem.Allocator, source: []const u8, interpreter: *Interpreter, exit_on_error: bool) !void {
    var scanner = Scanner.init(source);
    const tokens = try scanner.scanTokens(gpa);
    if (scanner.had_error) {
        if (exit_on_error) std.process.exit(65);
        return;
    }

    var parser = Parser.init(gpa, tokens);
    const statements = try parser.parseProgram();
    if (parser.had_error) {
        if (exit_on_error) std.process.exit(65);
        return;
    }

    var resolver = Resolver.init(gpa, interpreter);
    try resolver.resolveProgram(statements);
    if (resolver.had_error) {
        if (exit_on_error) std.process.exit(65);
        return;
    }

    interpreter.interpretProgram(statements);
}
