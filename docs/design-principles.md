# Design principles

These are the non-negotiable rules of anyparse. Each one exists because of a specific pain point or failure mode observed in existing tools (particularly ax3 and haxe-formatter, which directly motivate this project). Breaking a principle should require equally specific justification.

## 1. Grammar is data, not code

**Rule**: every format and language is described as a Haxe type with metadata. The macro reads this description at compile time and generates a specialized parser. Hand-writing a parser for a format is always a fallback, never the default path.

**Why**: hand-written parsers accumulate ad-hoc decisions, contextual lexer modes, and undocumented quirks. ax3's `Scanner.hx` has `MNormal`, `MNoRightShift`, `MExprStart` — three contextual modes — and still only supports "a small commonly used subset" of E4X. Every new feature is another mode, every bug is a game of whack-a-mole. A declarative grammar forces all this information into one place where it can be inspected, tested, and changed safely.

**Consequence**: if something cannot be expressed declaratively, we extend the strategy/metadata vocabulary rather than drop to imperative code. The macro is complex because the grammar is simple.

## 2. Zero global mutable state

**Rule**: no `static var` in hot paths. No global singletons. No thread-local equivalents of `TokenStream.MODE`. The macro refuses to compile rules that read or write non-`ctx` mutable state. Every piece of runtime state lives inside a `Parser` instance passed as the first argument to generated functions.

**Why**: haxe-formatter has `tokentree.TokenStream.MODE` as a global static. `Formatter.format()` crashes randomly when called from multiple threads. ax3 knows this and forces its output phase single-threaded as a workaround, losing a 5x speedup on a 2000-file codebase. The user's own fork patches around the consequences but cannot fix the root cause without rewriting the library.

**Consequence**: thread safety is a compile-time guarantee. An 8-core machine gets 8x throughput, not 1x. When we replace haxe-formatter, parallelism works by construction — not as a feature we add later.

## 3. Pure Haxe delivery, no JVM dependency

**Rule**: anyparse runs on Haxe targets: neko, js, hxcpp, and anything else Haxe compiles to. It does not require a JVM, a .NET runtime, or any external binary. CLI tools built on anyparse are single-file executables or single node scripts.

**Why**: ax3 ships as `converter.jar` on JVM. Java is required to run the AS3→Haxe conversion tool, which is absurd for a Haxe project. The original author attempted a JS port and abandoned it because of GC pressure in 2020 — before modern Node, arena allocators, and tuned GC. That's a decade of runtime progress we can use now.

**Consequence**: native binaries via hxcpp become real tools users can install. No "install a JDK first" friction. Cross-platform distribution is a haxelib install or a downloaded binary, not a runtime setup.

## 4. One AST, one writer — no two-pass pipelines

**Rule**: a writer takes typed AST and produces formatted output in one pass through the Doc-based pretty printer. There is no stage where the writer emits text, another component re-parses that text, and a third stage reformats it.

**Why**: ax3's pipeline is `TypedTree → GenHaxe (string concatenation, 38KB monolith) → haxe-formatter (re-parse + reformat)`. Two passes, two error sources, two places to patch when formatting breaks. The re-parse stage is also where thread safety dies, because the formatter is not thread-safe. Any output change means editing `GenHaxe.hx` and praying the formatter doesn't re-break what you just fixed.

**Consequence**: all formatting decisions live in one place — the Doc construction for a given grammar. Changing output means changing how that grammar builds its Doc, not editing two files that must stay in sync. And because there is no re-parse, thread safety is preserved.

## 5. Format and schema are separate, both are declarative

**Rule**: a format describes what a file looks like (JSON's syntax rules, policies, escape handling). A schema describes what a specific document of that format means (a `User` type with `id`, `name`, `email` fields). The macro combines format + schema at compile time to generate a parser specialized for that pair. Both format and schema are ordinary Haxe classes — no hidden profiles, no magic metatags that only the library knows about.

**Why**: this prevents scope creep into "which formats are supported". There is no library decision of "we support JSON, XML, YAML". There is an interface, `TextFormat`, and anyone writing a class that implements it gets a format. Users adding JSON5 or their own config format do not file a PR against anyparse — they write a 50-line class in their own project.

**Consequence**: the project's responsibility is the engine and a handful of reference format implementations (JSON first, eventually XML, YAML flow, INI). Third parties ship their own formats as haxelib packages without touching core.

## 6. Parsing loses formatting; writing is `format(ast, options)`

**Rule**: the parser does not preserve whitespace, comments, or stylistic choices (quote styles, trailing commas). The writer regenerates output from AST + FormatOptions. If byte-identical round-trip matters, an optional pass detects options from a sample and passes them to the writer.

**Why**: preserving trivia adds complexity at every AST node, doubles memory usage, and creates an implicit contract that is almost impossible to honor under modifications. Prettier, gofmt, black, rustfmt — all successful formatters adopt "there is one canonical output for each AST, configurable by options". This model also makes the AST simpler to work with: AST transformations (renames, inserts, deletes) don't have to reason about where comments should travel.

**Consequence**: "I parsed this file, modified one line, and want to write it back with minimal diff" is handled by configuring the writer with options that match the original file's style. The detector pass to infer those options from a sample is a small utility, not a core feature.

## 7. Two compilation modes: Fast and Tolerant

**Rule**: every grammar can be compiled in two modes. Fast returns bare types and throws on error; it is used when you trust the input and want maximum throughput. Tolerant returns `ParseResult<Node<T>>` with errors collected, spans on every node, and recovery enabled via `@:commit`/`@:recover`; it is used for user-facing tools, linters, and IDEs. Both modes come from the same grammar declaration.

**Why**: IDE features (error recovery, spans, `ParseResult`, cache integration, cancellation) have real cost. If we always pay for them, Fast mode has no reason to exist, and high-throughput use cases underperform. If we never pay for them, IDE use cases are impossible without rewriting. Two explicit modes give users the choice per use case without trying to be clever.

**Consequence**: Fast mode is truly fast — no `ParseResult` wrapping, no `Node` allocation, no error collection. Tolerant mode is feature-complete for IDE scenarios. The two are separate generated classes chosen at the call site, not a runtime flag.

## 8. Cross-family round-trip as an architectural invariant

**Rule**: the CoreIR must support structural round-trip between language families. The canonical test is curly-brace ↔ Lisp: a program expressed via `CurlyBraceFamilyAst`, converted to `LispFamilyAst`, written out in a Lisp syntax, parsed back, converted back through the bridge, should return to an equivalent `CurlyBraceFamilyAst`. Any primitive in CoreIR that leaks family-specific assumptions (e.g., a `MethodCall` node that only makes sense for dot-syntax languages) is a bug.

**Why**: a platform that claims to handle any format or language cannot have curly-specific assumptions baked into its core. If we validate only on curly grammars, bugs like "oh, this only works with infix operators" never surface until someone tries to add Lisp. By running the round-trip invariant from the start, we force the core to stay neutral.

**Consequence**: decisions about CoreIR primitives get tested against "how does this project onto Lisp?" — a concrete question that rules out many temptations. The bridge test doesn't need to produce idiomatic output; layer 1 structural equivalence is enough. Layer 2 (idiom translation) and layer 3 (semantic translation) are user-level concerns, not architecture.

## 9. Strategies are plugins, families are plugins, formats are plugins

**Rule**: `Strategy`, `Format`, and family IR types are all implemented as plugins — classes or packages that compose with anyparse core without modifying it. Adding a new strategy (e.g., `IndentStrategy` for Python) is a new file plus one registration line. Adding a new format (e.g., `Json5Format`) is a new class. Adding a new family IR (e.g., `SqlFamilyAst` for SQL dialects) is a new haxelib package.

**Why**: the project exists to be *ready* for formats and languages that do not exist yet. If adding a new language requires modifying core, the project fails its purpose. Every new thing must be a plugin, period.

**Consequence**: core stays minimal. Core owns the macro pipeline, CoreIR, runtime, and a few reference implementations. Everything else is shipping as separate packages, written by anyone, maintained on any schedule.

## 10. Validate on real regression corpuses

**Rule**: test on real-world corpuses, not just synthetic examples. The user's ax3 fork has ~2000 AS3 files. The user's haxe-formatter fork has a commit log of specific wrapping bugs with before/after test cases. These are non-negotiable regression corpuses once we start replacing those tools. Any anyparse replacement that does not match or exceed their behavior on these corpuses is not yet ready.

**Why**: synthetic test cases hide bugs. Real-world corpuses contain the edge cases that took years to find and document. The user has already paid the cost of finding those edge cases by maintaining the existing tools; we should not re-pay it.

**Consequence**: the validation criterion for a replacement tool is "passes the existing regression corpus, preferably with better performance and identical or better output". Not "looks correct on JSON sample files".

## Decision-making heuristic

When in doubt, ask both questions. If a decision satisfies both, it is probably right. If only one, reconsider.

1. **Does this solve a concrete validation case?** (ax3, haxe-formatter, or any explicit target grammar)
2. **Does this generalize to the next ten formats or languages we have not thought of yet?**

A decision that only solves a concrete case without generalizing makes the project narrower. A decision that only generalizes without solving anything concrete makes the project abstract and unshippable. We need both at every step.
