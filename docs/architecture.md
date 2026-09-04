# Architecture

This document describes the full architectural model of anyparse. For the short strategic framing, see `../CLAUDE.md`. For non-negotiable rules, see `design-principles.md`.

## Two questions this architecture answers

Every decision in anyparse answers one or both of these questions:

1. **How do we describe an arbitrary format or language once, declaratively, so the macro can generate a fast specialized parser and writer for it?**
2. **How do we keep that description separate from the engine, so adding a new format is a plugin and not a core change?**

The entire architecture is a specific answer to these questions. When in doubt, check: does this decision serve declarative description, or plugin separation, or both?

## Core insight: grammar as data

A grammar in anyparse is **a Haxe type annotated with metadata**. The type's structure carries the tree shape; the metadata carries the literals, separators, operators, keywords, and policies.

```haxe
@:schema(JsonFormat)
enum JValue {
  @:lead("{") @:sep(",") @:trail("}")
  Object(entries:Array<JEntry>);

  @:lead("[") @:sep(",") @:trail("]")
  Array(items:Array<JValue>);

  Str(s:JString);
  Num(n:JNumber);

  @:lit("true")  True;
  @:lit("false") False;
  @:lit("null")  Null;
}
```

The macro reads this at compile time and generates specialized `parseJValue` and `writeJValue` functions. No runtime interpretation of grammar rules. No dynamic dispatch. No reflection. The generated code looks like hand-written recursive descent.

This matches the performance profile of serde in Rust, typia in TypeScript, kotlinx.serialization in Kotlin — all projects that use compile-time code generation from typed descriptions. The difference is that anyparse is **format-agnostic** (not tied to JSON like json2object or serde_json), **language-agnostic** (handles programming languages through Pratt and indent-aware strategies), and **cross-platform** (runs anywhere Haxe targets).

## Five-pass macro pipeline

```
User type annotated with metadata
         │
         ▼  ┌────────────────────────────────────┐
            │ 1. Shape analysis                  │
            │    Type → ShapeTree                │
            │    enum→Alt, class→Seq,            │
            │    Array<T>→Star, Null<T>→Opt      │
            └────────────────────────────────────┘
                          │
         ┌────────────────▼────────────────────┐
         │ 2. Strategy annotation (per-plugin) │
         │    Each strategy walks ShapeTree    │
         │    and writes to its own namespaced │
         │    annotation slots                 │
         └────────────────┬────────────────────┘
                          │
         ┌────────────────▼────────────────────┐
         │ 3. Lowering                         │
         │    ShapeTree → CoreIR               │
         │    Strategies with specialized      │
         │    lowering run here                │
         └────────────────┬────────────────────┘
                          │
         ┌────────────────▼────────────────────┐
         │ 4. Codegen                          │
         │    CoreIR → haxe.macro.Expr         │
         │    One mapper per CoreIR node       │
         │    Separate Fast/Tolerant variants  │
         └────────────────┬────────────────────┘
                          │
         ┌────────────────▼────────────────────┐
         │ 5. Runtime assembly                 │
         │    Parser class with contributed    │
         │    state fields and helper methods  │
         └─────────────────────────────────────┘
```

Passes 1, 3, 4, 5 are the common framework. Pass 2 is where all strategies live. Adding a new strategy = adding one file with an implementation of the `Strategy` interface. See `strategies.md` for the plugin contract.

### Entry points — not every build runs all five

`Build` exposes one `@:build` entry per artefact, and each takes the passes it needs. `buildParser` runs all five. `buildWriter` and `buildQueryWalker` run 1, 3, 4, 5 over their own lowering. `buildTransform` and `buildLexicalScan` need only the BASE shape, so the strategy-annotate, trivia and span passes are skipped.

`buildLexicalScan` is the smallest of them and the one worth knowing about, because it answers a question no parse can: **which bytes of a source are not code**, over raw and possibly unparseable text. It reads the grammar's `@:lexical` / `@:balanced` / `@:re` / `@:lead` / `@:trail` / `@:lit` plus the format's comment delimiters, lowers them to one region spec per non-code shape (`LexicalLowering`) and emits a specialised byte walk plus the two entries every consumer calls (`LexicalCodegen`). `anyparse.grammar.haxe.HaxeLexicalRegions` is its production consumer, `unit.minilex.MiniLexScan` the second-grammar pin that proves nothing about Haxe survives inside the macro. See `strategies.md` § Lexical.

## CoreIR — the internal representation

CoreIR is a small enum of parser primitives that strategies lower into and codegen consumes. It is intentionally minimal. Any node that cannot be expressed in existing primitives is either wrapped in `Host` (an escape hatch) or is a signal that CoreIR needs to grow.

```haxe
enum CoreIR {
  // structural
  Empty;
  Seq(items:Array<CoreIR>);
  Alt(items:Array<CoreIR>);
  Star(item:CoreIR, ?sep:CoreIR);
  Opt(item:CoreIR);
  Ref(ruleName:String);

  // lexical
  Lit(s:String);
  Re(pattern:String);

  // lookahead
  And(item:CoreIR);   // positive
  Not(item:CoreIR);   // negative

  // capture and backreference
  Capture(label:String, inner:CoreIR);
  Backref(label:String);

  // binding and expression-reference for context-dependent fields
  Bind(name:String, inner:CoreIR);
  ExprRef(e:haxe.macro.Expr);

  // construction
  Build(typePath:String, ctor:String, fields:Array<{name:String, ir:CoreIR}>);

  // binary primitives (used by BinaryStrategy)
  Bin(kind:BinKind);
  Count(len:CoreIR, item:CoreIR);
  Switch(discr:CoreIR, cases:Map<Int,CoreIR>);

  // transformation (bytes → typed value)
  Decode(name:String, inner:CoreIR);

  // escape hatch: opaque host code wrapping an inner CoreIR
  Host(code:haxe.macro.Expr, inner:CoreIR);
}

enum BinKind {
  U8; U16LE; U16BE; U32LE; U32BE; U64LE; U64BE;
  I8; I16LE; I16BE; I32LE; I32BE; I64LE; I64BE;
  F32LE; F32BE; F64LE; F64BE;
  Varint; Zigzag;
  BytesFixed(n:Int);
  BytesVar(len:CoreIR);
  Magic(expected:haxe.io.Bytes);
}
```

### Design principles for CoreIR

- **Family-agnostic primitives.** `Call(callee, args)` would be curly-specific. Instead, a "method call" is just `Seq([fieldAccess, Lit("("), args, Lit(")")])` — same shape as `(method obj a b)` in Lisp.
- **No statement/expression distinction.** Lisp has none. Curly languages introduce it in their family IR, not here.
- **Host as escape hatch only.** Strategies emit `Host` when a behavior genuinely cannot be expressed in other primitives (typically Pratt loops and indent push/pop). Overuse of `Host` is a code smell — it means a primitive is missing from CoreIR.
- **Every primitive must be reversible.** The writer walks CoreIR in reverse to emit output. If a node has no sensible "write" semantics, either the primitive is wrong or it needs an explicit write-side counterpart.

## Strategies as plugins

A strategy is a Haxe class implementing the `Strategy` interface. Each strategy owns a set of metadata tags, knows how to annotate ShapeTree nodes, and optionally lowers them into CoreIR. Strategies never emit Haxe code directly — they work through CoreIR.

Current plan for strategies:

| Strategy | Owns meta | Purpose |
|---|---|---|
| `BaseShape` | — | `enum→Alt`, `class→Seq`, `Array<T>→Star`, `Null<T>→Opt`, `abstract→Terminal`. |
| `Lit` | `@:lit`, `@:lead`, `@:trail`, `@:wrap`, `@:sep` | Literal text glue between fields. |
| `Re` | `@:re` | Regex terminals for primitive-wrapping abstracts. |
| `Kw` | `@:kw` | Keyword with word boundary — sugar for `Lit + Not`. |
| `Skip` | `@:skip`, `@:ws` | Cross-cutting whitespace/comment consumption. |
| `Capture` | `@:capture`, `@:match` | Backreferences for context-dependent grammars like XML tag matching. |
| `Pratt` | `@:infix`, `@:prefix`, `@:op` | Operator-precedence parsing for expression languages. |
| `Indent` | `@:indent(same/block/gt/suspend)` | Indent-sensitive grammars (Python, YAML block). |
| `Binary` | `@:u8/u16/.../magic/tag/tagMask/fromTag/lenPrefix/countPrefix/decode` | Binary format primitives. |
| `Recovery` (future) | `@:commit`, `@:recover` | Error recovery for tolerant mode. |

Strategies compose through ordered annotation passes with declared dependencies (`runsAfter`, `runsBefore`). Conflicts on metadata ownership are caught at registration time.

See `strategies.md` for the full interface and per-strategy details.

## Formats as plugins

A format is a separate layer from a strategy. A **strategy** is a way of parsing (PEG descent, Pratt, indent-aware). A **format** is a description of a specific format's literal vocabulary and policies (JSON's `{`, `}`, `:`, `,`; its string escape rules; whether trailing commas are allowed; etc.).

The macro reads a format singleton's field initializers at compile time:

```haxe
final class JsonFormat implements TextFormat {
  public static final instance:JsonFormat = new JsonFormat();

  public var mappingOpen(default, null):String     = "{";
  public var mappingClose(default, null):String    = "}";
  public var sequenceOpen(default, null):Null<String>  = "[";
  public var sequenceClose(default, null):Null<String> = "]";
  public var keyValueSep(default, null):String     = ":";
  public var entrySep(default, null):String        = ",";
  public var whitespace(default, null):String      = " \t\n\r";
  public var lineComment(default, null):Null<String>     = null;
  public var blockComment(default, null):Null<BlockComment> = null;
  public var keySyntax(default, null):KeySyntax    = KeySyntax.Quoted;
  public var stringQuote(default, null):Array<String> = ['"'];
  public var fieldLookup(default, null):FieldLookup    = FieldLookup.ByName;
  public var trailingSep(default, null):TrailingSepPolicy = TrailingSepPolicy.Disallowed;
  public var onMissing(default, null):MissingPolicy    = MissingPolicy.Error;
  public var onUnknown(default, null):UnknownPolicy    = UnknownPolicy.Skip;
  // ... escape/unescape functions

  private function new() {}
}
```

Format classes expose a `public static final instance` singleton because their fields are pure configuration with no per-parse state. The writer and macro both read through the singleton; no allocation is needed per parse.

User schemas reference a format:

```haxe
@:schema(JsonFormat)
class User {
  @:field("id")    public var id:Int;
  @:field("name")  public var name:String;
}
```

The macro:
1. Resolves `JsonFormat` type via `Context.getType`.
2. Reads its field initializers as compile-time constants.
3. Generates a parser specialized for `User` using JsonFormat's literals and policies.

**Critical property**: there is no built-in notion of "JSON". `JsonFormat` is an ordinary Haxe class in a library package. Users who need JSON5, HJSON, or their own format write their own format class, inheriting from `JsonFormat` if useful, and apply it to their schemas. The library core knows nothing about specific formats.

Format families:

- `TextFormat` — structured text (JSON, YAML flow, TOML, INI). Mapping/sequence/scalar model.
- `BinaryFormat` — binary with tagged or length-prefixed layout. MessagePack, CBOR, protobuf.
- `TagTreeFormat` (future) — XML/HTML with elements + attributes + text content.
- `SectionedFormat` (future) — INI-like flat formats with section headers.
- `IndentedFormat` (future) — YAML block, Python subset.
- `TabularFormat` (future) — CSV, TSV, fixed-width.

Each family has its own interface with fields specific to that family's structural model. They all inherit from `Format` (which has only version, name, and encoding). Using one universal interface for all families was considered and rejected — it forces either tiny common denominator (useless) or giant union type (unmanageable).

See `formats.md` for interface details and how to write a format.

## Runtime

The runtime is what macro-generated parsers use at runtime. It is small and has zero knowledge of specific grammars.

```
anyparse.runtime/
├── Input.hx         — byte stream abstraction (StringInput, BytesInput, ...)
├── Span.hx          — {from, to} with lazy line/col resolution
├── LineIndex.hx     — per-source line-start prefix index for repeated line/col lookups
├── ParseError.hx    — span + message + expected + severity
├── ParseResult.hx   — wrapper: { value, span, errors, complete }
├── Node.hx          — AST node metadata wrapper for Tolerant mode
├── Parser.hx        — context: input, pos, errors, cache, indentStack, captures, cancelled
└── ParseCache.hx    — interface + NoOpCache (real cache used in incremental mode)
```

Key design properties:

- **Thread-safe by construction.** No global mutable state. The entire runtime state lives in a `Parser` instance, passed as the first argument to every generated function.
- **Allocation minimized in Fast mode.** `ParseResult` and `Node` wrappers are only used in Tolerant mode. Fast mode returns bare AST values.
- **Cache opt-in.** By default, `Parser.cache` is `NoOpCache` — zero overhead. Real caching is plugged in only in incremental scenarios.
- **Cancellation optional.** `Parser.cancelled` is `() -> false` by default. Hot loops check it; if never true, cost is one inlined comparison.
- **Line/col lazy.** `Span` stores only byte offsets and resolves line/col by a linear walk per call. A caller resolving many offsets in the same text builds a `LineIndex` over it instead — a newline prefix index plus binary search, owned by the caller, not shared.

## Two compilation modes per grammar

Every `@:peg`-annotated type generates two parser artifacts:

### Fast

- Returns bare type `T`, not `ParseResult<Node<T>>`.
- Throws on first error — no collection, no recovery.
- Strict PEG — `@:commit`/`@:recover` metadata is ignored.
- No span tracking in AST nodes.
- No cache, cancellation, or token stream.
- Maximum throughput. Targets hand-written C speeds on hxcpp.

### Tolerant

- Returns `ParseResult<Node<T>>` with errors collected.
- Recovers from errors via `@:commit`/`@:recover` where declared.
- Every AST node wrapped in `Node<T>` with `span`, `errors`, `id`.
- Cache, cancellation, token stream — all configurable on the `Parser` context.
- Required for IDE, linters, refactor tools, anything showing user-facing error messages.

**Current implementation status: Fast-mode only.** The real pipeline is
`@:build`-driven (`Build.buildParser` on a marker class, e.g. `JValueFastParser`);
Tolerant-mode codegen is stubbed (see roadmap Phase 2 non-deliverables). The
mode-selection API below and the "Tolerant by default" policy are the *planned*
design, not current behavior:

```haxe
// PLANNED — not implemented yet
@:peg @:generate([Fast, Tolerant])
class JValue { ... }

// Use Fast for hot paths:
var v1 = JValueParser.parse(bytes);              // bare JValue

// Use Tolerant for diagnostics and IDE:
var v2 = JValueTolerantParser.parse(bytes, ctx);     // ParseResult<Node<JValue>>
```

**Planned default is Tolerant** (Fast opt-in per grammar when profiling justifies it).

## Writer and formatter

Writers are the inverse of parsers on the same CoreIR. The macro generates both from one grammar description. No separate formatter library, no two-pass `AST → text → re-parse → format` pipeline.

### Doc IR for text formats

Text writers build a `Doc` tree (Wadler-style pretty-printer IR) and hand it to `Renderer` which lays it out within a target line width. Binary writers emit bytes directly, skipping Doc entirely.

Doc primitives:

- `Empty`
- `Text(s)`
- `Line(flat)` — line break or its flat replacement
- `Nest(n, inner)` — indent
- `Group(inner)` — unit of flat-vs-broken decision
- `Concat(items)`

The renderer commits a group to flat mode if its flat content fits within the remaining width; otherwise it breaks and the inner line breaks become real newlines with current indent.

### FormatOptions

Writers take a runtime `FormatOptions` parameter controlling indent, line width, comma placement, quote style, and other stylistic choices. The macro generates code that consults these options at each decision point. One writer, multiple outputs — pretty, compact, canonical — without code duplication.

Writer philosophy (load-bearing decision): **parsing is lossy, writing is `format(ast, options)`**. We do not preserve whitespace, comments, or formatting choices. Instead, we provide good formatters parameterized by options. If byte-identical round-trip matters, an optional detector pass can infer options from a sample; but the default is canonical output per chosen options.

See `testing.md` for why this is the right trade-off and what use cases are preserved.

## The CLI layer

`apq` / `hxq` is the platform's own first consumer: a query, refactor and lint CLI written entirely against the public parser, writer and check layers. It is where the architecture is dogfooded, so its own shape is part of the architecture rather than an accident of one binary.

```
anyparse.query/
├── Cli.hx                  — the process entry point: argv -> exit status
└── cli/
    ├── CliIo.hx            — process IO: the two streams, file reads, the staged
    │                         (crash-safe) file write, stdin, the progress line
    ├── CliArgs.hx          — argv -> values: one flag's value, --limit, <line>:<col>,
    │                         the plugin --lang names, the hxformat.json a file is
    │                         governed by, a glob or directory -> the file list
    ├── CliWalk.hx          — the shared multi-file walk: parse-or-record-a-skip,
    │                         hit capping, the nudge a 0-hit walk prints
    ├── CliEdit.hx          — the edit pipeline: resolve an address, then turn an
    │                         EditResult into a written file, a stdout preview or a
    │                         diagnostic — so --write means one thing everywhere
    ├── WriteFailure.hx     — a write that did not happen, carrying its file
    ├── CliCommand.hx       — one subcommand: name, summary, usage, run
    ├── CliContext.hx       — what ONE invocation knows about itself
    ├── CliRegistry.hx      — the inventory the dispatcher and --help both read
    └── command/            — one module per migrated command
```

### A command is a thing, not a `case` arm

Each of the CLI's 69 commands is the same four parts — a name, the line it contributes to `apq --help`, its own `--help` page, and the run. Written as a `case` arm plus a `printXUsage` plus a `runX` plus a literal in the top-level usage text, nothing holds the four together: a command can be dispatched and never listed, or listed and never dispatched, and only a reader notices.

`CliCommand` makes the four parts one type and `CliRegistry` makes the inventory explicit — the same answer the test suite got when its hand-written runner became a generated registry. A command that is not in the registry does not exist; one that is gets its `--help` line from its own `summary()`.

This is a **migration in progress**. The registry owns three commands — one read-only walk, one single-file edit, one `--scope` edit, chosen so the seam is proved against three different shapes — and `Cli.dispatch` still carries a `case` arm for the other 66. The dispatcher consults the registry first and falls through to the switch, so each later batch is a mechanical move: the members go to a command module, the arm goes away, the usage literal becomes a `CliRegistry.helpLine` call. When the switch is empty, `dispatch` is the lookup.

### Invariant 1 at this layer

The support modules hold no state — every member is a pure function of its arguments plus the process — and `CliRegistry.commands()` allocates a fresh command per call rather than memoising a shared array, because a shared registry is the process-scoped shape invariant 1 exists to keep out, however stateless today's implementations happen to be.

What a run legitimately needs to remember goes on `CliContext`, an instance created per invocation and handed to the command. `--exit-on-empty` is the live example: parsed once by the dispatcher, consumed much later by whichever find-walker the run ended in. `Cli` carried it across that gap in a `private static var` — the one piece of process-scoped mutable state in the CLI, and the shape a second run in the same process can observe. A field on a per-run instance is the same value with none of that; the static survives only for the commands the registry does not own yet, and goes with the last `case` arm.

## Cross-family IR

Not in scope for initial implementation. When it appears:

- `CurlyBraceFamilyAst` — common IR for C-family OO languages.
- `LispFamilyAst` — common IR for Lisp family.
- `MLFamilyAst` — functional ML family.

Each grammar projects onto the relevant family IR through a standard transformation. A bridge between two family IRs is a separate package (`anyparse-bridge-curly-lisp`, `anyparse-bridge-curly-ml`). Bridges are optional and ship only for pairs that matter.

The round-trip invariant for CoreIR is that curly ↔ Lisp structural conversion must work at layer 1 (structural transfer). See `cross-family-contract.md`.

## What is missing and why

Honest list of things that are *not* in the architecture and *why*:

- **Continuous incremental parsing.** Requires background threads, rope buffers, edit streaming. Tree-sitter territory. We do on-demand reparse with caching, which covers most non-live use cases.
- **Deep semantic translation.** Translating Python to Rust requires type inference, library mapping, ownership analysis. We provide AST transformation framework; semantic translation is user code built on top.
- **Native code backends.** LLVM IR writer is feasible as "just another format writer". A full native backend is not. Integrate, don't compete.
- **Full error recovery at tree-sitter quality.** Our Tolerant mode handles `@:commit`/`@:recover` at rule boundaries, which is enough for CLI tools and batch linters. True IDE-grade partial parsing of intentionally broken code is a research-level problem beyond our scope.

These gaps are deliberate. Attempting them would bloat the core beyond what one or two developers can maintain, and would not meaningfully serve the use cases this platform actually targets.

## Further reading

- `design-principles.md` — why each invariant exists, which pain point motivated it.
- `roadmap.md` — the phased plan from walking skeleton to AS3 replacement and beyond.
- `strategies.md` — writing a plugin strategy.
- `formats.md` — writing a format.
- `testing.md` — test layers and when to use each.
- `cross-family-contract.md` — round-trip invariant specifics.
