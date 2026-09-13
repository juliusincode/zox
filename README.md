# zox

A tree-walking interpreter for [Lox](https://craftinginterpreters.com/the-lox-language.html),
the teaching language from Robert Nystrom's book
[*Crafting Interpreters*](https://craftinginterpreters.com/) — implemented from
scratch in [Zig](https://ziglang.org) 0.16, instead of the book's Java (jlox).

zox implements the full jlox feature set: scanning, a recursive-descent
parser, a tree-walking evaluator, statements and lexical scoping, control
flow, first-class functions with closures, a static resolver, and classes
with single inheritance. It does not (yet) implement Part III of the book
(clox, the bytecode VM).

## Why Zig instead of Java?

Zig has no garbage collector, no exceptions, and no inheritance. Every
design decision in this codebase that would be trivial in Java had to be
rethought:

- **AST nodes** are tagged unions of pointers instead of a class hierarchy
  with a Visitor pattern.
- **Closures** need environments that outlive the stack frame that created
  them, so every block/call environment is heap-allocated (via a
  process-lifetime arena) rather than living on the Zig call stack.
- **`return` and runtime errors** are modeled as Zig errors, not
  exceptions. Since Zig errors carry no payload, the interpreter uses a
  side channel (`Interpreter.return_value`) to carry a `return`
  statement's value back out through the call stack.
- **The resolver's `Map<Expr, Integer>`** (Java, keyed by object identity)
  becomes a plain `AutoHashMap(usize, usize)` keyed by AST node pointer
  addresses in Zig.

## Project structure

```
src/
  token.zig        Token types, lexeme/literal representation, keyword table
  scanner.zig       Source text -> token stream
  expr.zig          Expression AST (tagged union) + LiteralValue
  stmt.zig          Statement AST (tagged union)
  ast_printer.zig   Debug: prints an Expr as parenthesized Lisp-like notation
  parser.zig        Recursive-descent parser: tokens -> statements
  environment.zig   Variable bindings with lexical scope chaining
  value.zig         Runtime Value type, LoxFunction, LoxClass, LoxInstance
  resolver.zig      Static pass: resolves every variable reference to a
                    lexical scope depth before interpretation starts
  interpreter.zig   Tree-walking evaluator + statement execution
  main.zig          CLI entry point
```

Roughly this mirrors the book's chapter order (scanning -> parsing ->
evaluating -> statements/state -> control flow -> functions -> resolving
-> classes), and the codebase grew up chapter by chapter, each stage
compiled and unit-tested before moving to the next.

## Building and running

Requires Zig 0.16.0 (the standard library API — particularly `ArrayList`,
`std.Io`, and process argument/file access — changed significantly in this
release; earlier or later Zig versions are not guaranteed to build this
project unmodified).

```sh
zig build            # builds ./zig-out/bin/zox
zig build run -- path/to/script.zox
zig build test       # runs the full unit test suite
```

Example:

```sh
cat > hello.zox <<'EOF'
class Greeter {
  init(name) { this.name = name; }
  greet() { return "Hello, " + this.name + "!"; }
}
var g = Greeter("World");
print g.greet();
EOF
zig build run -- hello.zox
# Hello, World!
```

## Known limitations / things that are intentionally simple

- **No garbage collector.** Every environment and heap-allocated runtime
  object lives in one process-lifetime arena. This is correct (nothing is
  freed too early) but not memory-efficient for long-running programs
  with many loop iterations or many short-lived closures — each iteration
  that creates a new closure leaks its environment until the process
  exits. Fine for a teaching interpreter and short scripts, not fine for
  a long-running service.
- **No native/foreign functions** (no `clock()` or similar) — only what
  the Lox grammar itself provides.
- **Exit codes** follow the book's convention: `64` for CLI usage errors,
  `65` for a parse/resolve error, `70` for an uncaught runtime error.

## License

MIT — see [LICENSE](LICENSE). The Lox language itself and its design are
Robert Nystrom's; this is an independent implementation written for
learning purposes.
