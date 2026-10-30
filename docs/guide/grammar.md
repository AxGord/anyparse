# The grammar platform

A `@:build` macro reads a grammar (Haxe types annotated with `@:lit`, `@:kw`,
`@:infix`, `@:prefix`, `@:postfix`, …) plus a `@:schema(Format)` and emits:

- **`buildParser`** — a specialized parser, in either **Fast** mode (bare types, throw
  on error, maximum throughput) or **Tolerant** mode (spans, error recovery, IDE-class
  use). Two parsers from one grammar, chosen at the call site.
- **`buildWriter`** — a writer/pretty-printer driving a Wadler-style Doc IR. **One AST,
  one writer** — no "emit text, then re-parse and reformat" two-pass pipeline.
- **`buildTransform`** — a deep, bottom-up whole-tree rewrite with per-node-type hooks
  (the multi-type generalization of `ExprTools.map`).

Parsing strategies are plugins (`Pratt`, `Kw`, `Lit`, `Prefix`/`Postfix`/`Ternary`,
`Re`, `Skip`, and `Bin` for binary formats). Grammars shipped today:

- **haxe** — the full language grammar (all five top-level decls, members, control flow,
  31 binary + prefix/postfix operators via Pratt, string interpolation, lambdas,
  literals) — parser + writer + the query plugin behind `hxq`.
- **json** — a text format: parser + writer.
- **ar** — a binary archive (Unix `ar`): byte-perfect parser + writer through the same
  pipeline.
- **sexpr** — S-expression writer, used for the `ast` dump output.

## Design goals

The project deliberately started from a universal-parser framing: be ready for the next
format or language rather than rewrite the same parser machinery each time. The points
below are the design direction — the [README](../../README.md) and the [roadmap](../roadmap.md) mark what is
delivered today.

- **Format-agnostic** — grammars for any format (JSON, XML, YAML, binary, custom)
  described declaratively as Haxe types with metadata. *Today: JSON, Haxe and the `ar`
  binary format.*
- **Language-agnostic** — programming languages handled by the same engine through
  Pratt, keyword/literal and (planned) indent-sensitive strategies.
- **Plugin architecture** — grammars and format descriptions live in their own packages;
  adding a language or format is a new package, not a core change.
- **Cross-family ready** — common AST types for language families (curly-brace, Lisp, ML)
  are themselves plugins, with a structural round-trip between families as an
  architectural contract. *Not yet implemented — see
  [`docs/cross-family-contract.md`](../cross-family-contract.md).*
- **Performance** — generated parsers and writers are specialized per type at compile
  time, targeting hand-written speed.

The **Fast/Tolerant** two-mode build and the **one-AST-one-writer** guarantee (described
at the top of this page) are part of this direction and already in place.

## Non-goals (by design)

- **Not an automatic cross-language translator.** Deep semantic translation between
  unlike languages (Python ↔ Rust) is out of scope; the platform provides infrastructure
  for *user-written* transforms, not magic.
- **Not a native code generator.** Integrate with LLVM/WASM if binary emission is needed.
- **Not a live-background incremental parser.** On-demand reparse with caching is in
  scope; continuous tree-sitter-style incrementality is not.
