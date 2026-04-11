# anyparse

Declarative parser, writer and pretty-printer library for Haxe.

**Status: early walking skeleton.** Not usable yet.

## Goals

- **Format-agnostic**: grammars for any format (JSON, XML, YAML, binary, custom) are described declaratively as Haxe types with metadata.
- **Language-agnostic**: the same engine handles programming languages through PEG, Pratt and indent-sensitive strategies.
- **Plugin architecture**: grammars and format descriptions live in their own packages. Adding a new language or format is a haxelib package, not a core change.
- **Cross-family ready**: common AST types for language families (curly-brace, Lisp, ML) are themselves plugins. A structural round-trip test between families is part of the architectural contract.
- **Performance**: generated parsers and writers are specialized per type at compile time, targeting speed comparable to hand-written code.
- **Two build modes per grammar**: `Fast` for maximum throughput (bare types, throw on error) and `Tolerant` for IDE-class use cases (error recovery, spans, incremental-ready).
- **One AST, one writer**: no "generate string, then parse and reformat" two-pass pipeline. Writers work directly on typed AST through a Doc-based pretty-printer.

## Non-goals (by design)

- Automatic deep semantic translation between radically different languages (e.g., Python ↔ Rust). The framework provides infrastructure for user-written transforms, not magic.
- Own native code generator. Integrate with LLVM/WASM if binary emission is needed.
- Continuous live-background incremental parsing. Use tree-sitter for that class of use case.

## Running tests

```
haxe test.hxml          # neko (fast compile, fast run, default)
haxe test-js.hxml       # js/node
haxe test-interp.hxml   # Haxe macro interpreter (no compile step)
```

## License

MIT. See `LICENSE`.
