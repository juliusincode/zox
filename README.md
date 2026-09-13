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

## Features beyond the book baseline

- **Interactive REPL** — run `zox` with no arguments for a line-oriented
  read-eval-print loop. Each line is resolved and interpreted independently
  while sharing the same global environment (variables and functions persist
  across lines). Ctrl-D exits.
- **Native functions** — `clock()` returns the current Unix time in seconds
  as a floating-point number (identical semantics to the book's §10.2
  example). Natives are first-class `Value`s and participate in the same
  call machinery as user-defined functions.
- **Process-lifetime arena** — all AST nodes, environments, strings from
  concatenation, and native wrappers live in a single arena that is freed
  only on process exit. This eliminates almost all manual `deinit` calls
  for a short-lived CLI/REPL tool.

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
- **Native functions** are a new `Value` tag (`.native`) holding an arity
  and a function pointer; the call site in the interpreter dispatches on
  the tag the same way it does for user functions and classes.

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
  value.zig         Runtime Value type, LoxFunction, NativeFunction,
                    LoxClass, LoxInstance
  resolver.zig      Static pass: resolves every variable reference to a
                    lexical scope depth before interpretation starts
  interpreter.zig   Tree-walking evaluator + statement execution + natives
  main.zig          CLI entry point (script mode + REPL)
```

## Building & running

Requires Zig 0.16.

```bash
zig build                 # produces zig-out/bin/zox
zig build run -- script.zox
zig build test            # unit tests (51 tests)
./zig-out/bin/zox         # interactive REPL
./zig-out/bin/zox script.zox
```

### Quick examples

```lox
// script.zox
print clock();                    // e.g. 1726...
fun fib(n) {
  if (n < 2) return n;
  return fib(n - 2) + fib(n - 1);
}
print fib(10);                    // 55

class Point {
  init(x, y) {
    this.x = x;
    this.y = y;
  }
  distance() {
    return this.x * this.x + this.y * this.y;
  }
}
var p = Point(3, 4);
print p.distance();               // 25
```

In the REPL the same environment is shared across lines, so you can
define a function on one line and call it on the next.

## Status

Complete tree-walking implementation of jlox (Part II of the book) plus
REPL and the `clock` native. A bytecode VM (clox / Part III) is future
work.
