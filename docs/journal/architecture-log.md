# Architecture journal

> **Journal, not contract.** Every number here is a reading of one tree at one moment; the
> contract lives in [`docs/architecture.md`](../architecture.md). Each block is the ORIGINAL text of a paragraph
> that the reference condensed or dropped, moved verbatim under the section it was written in
> (`From § …` names that section by its heading at the time), in the original order, so
> `git log -S` and the ledger's citations still resolve (the one edit: a link to a sibling doc
> gains `../`, and a same-file `#anchor` gains `../architecture.md`, since this file lives one
> directory down). A `§` pointer inside moved text names a heading of the reference
> (`docs/architecture.md`), not of this file. Nothing here is a norm, and nothing here is auto-loaded.

## From § Five-pass macro pipeline › Entry points — not every build runs all five

`Build` exposes one `@:build` entry per artefact, and each takes the passes it needs. `buildParser` runs all five. `buildWriter` and `buildQueryWalker` run 1, 3, 4, 5 over their own lowering. `buildTransform` and `buildLexicalScan` need only the BASE shape, so the strategy-annotate, trivia and span passes are skipped.

## From § CoreIR — the internal representation

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

## From § Strategies as plugins

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

## From § Formats as plugins

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

**Critical property**: there is no built-in notion of "JSON". `JsonFormat` is an ordinary Haxe class in a library package. Users who need JSON5, HJSON, or their own format write their own format class, inheriting from `JsonFormat` if useful, and apply it to their schemas. The library core knows nothing about specific formats.

## From § Runtime

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

## From § Two compilation modes per grammar › Tolerant

**Current implementation status: Fast-mode only.** The real pipeline is
`@:build`-driven (`Build.buildParser` on a marker class, e.g. `JValueFastParser`);
Tolerant-mode codegen is stubbed (see roadmap Phase 2 non-deliverables). The
mode-selection API below and the "Tolerant by default" policy are the *planned*
design, not current behavior:

## From § Writer and formatter › FormatOptions

Writer philosophy (load-bearing decision): **parsing is lossy, writing is `format(ast, options)`**. We do not preserve whitespace, comments, or formatting choices. Instead, we provide good formatters parameterized by options. If byte-identical round-trip matters, an optional detector pass can infer options from a sample; but the default is canonical output per chosen options.

See `testing.md` for why this is the right trade-off and what use cases are preserved.

## From § Writer and formatter › A `#if` region the parser captured raw

**The predicate is the grammar's fallback ctor, never a bracket count** — worth stating outright, because the bracket reading is the one the shape invites and it has been proposed and refuted twice. Measured 2026-09-07 over three trees (this project's `src`, 934 files; the Pony fork's `src`, 680; the haxe-formatter corpus inputs, the 897 of 946 that `fmt` processes) — 1580 `#if ... #end` regions, 59 captured raw, of which this project contributes 0:

| | braces EQUAL | braces UNEQUAL |
|---|---|---|
| **captured raw** | 34 | 25 |
| **formatted** | 1520 | 1 |

A brace rule would therefore report none of 34 raw regions, and would report one region that formats. That single false positive is a defect of the metric rather than a near miss: a brace count over the region's code bytes adds up BOTH mutually exclusive arms of `#if a … { #else … { #end … }`, and no configuration of the file ever holds both — so "how the brackets balance" is not even well defined over a region with an `#else`. `unit.query.OpaqueCondRegionScanTest` pins one fixture per class (construct-cutting with balanced braces, construct-cutting with unbalanced braces, unbalanced-yet-formatted), and the mutation arm `M-OPAQUE-REGION-BRACE-DELTA` is the refuted rule itself.

**What the refusal does NOT read is the region's own DIRECTIVES.** They lie in the unmodelled byte runs like everything else the model dropped, and they carry identifier-shaped tokens that name no binding: a `#if` condition names build flags, `#end` and `#else` name nothing. Read as ordinary bytes they refused correct work — a rename of a local `debug` standing beside `#if debug` was declined by the directive that guards it, fail-CLOSED and therefore invisible. `CondDirectives.scan` delimits the directive runs (keyword plus condition) and `CondRegionScan.opaqueCondRegionMentioning` scans only what is left; the branch bodies between them are untouched, so a reference written inside the region still refuses. The directive KEYWORDS were already exempt through `SourceText.mentionsIdent`, which skips an identifier directly preceded by `#`, which is why the CONDITION was the surviving half of the same mistake. Measured over the Pony fork: 20 of 872 files hold a raw region and 18 of them lose a name from their refusal set — 19 (file, name) pairs, every name a compile-time define (`haxe_ver` twelve times, then `starling`, `mobile`, `js`, `ios`, `hxbitmini`, `display`), and not one of them a name the file's own tree carries. This project's `src` + `test` hold no raw region at all, so a whole-tree lint is byte-identical across the change.

## From § The CLI layer › A command is a thing, not a `case` arm

Each of the CLI's 69 commands is the same four parts — a name, the line it contributes to `apq --help`, its own `--help` page, and the run. Written as a `case` arm plus a `printXUsage` plus a `runX` plus a literal in the top-level usage text, nothing holds the four together: a command can be dispatched and never listed, or listed and never dispatched, and only a reader notices.

The migration is **complete** (S69 piloted the seam on three commands of three shapes; S70 moved the other 66, merge `91bf07d9`). `Cli` is now four members — `main`, `run`, `dispatch`, `printUsage` — where `dispatch` is a registry lookup plus the unknown-subcommand path and `printUsage` a loop over `CliRegistry.commands()`. Every command lives under `src/anyparse/query/cli/command/`, one module per command, except the two whose exclusive members did not fit one type under the 50 / 2000 caps and are split by concern (`LintCommand` + `LintFixDriver` + `LintFixVerify` + `LintFixLedger`; `ReconCommand` + `ReconPredict`). `apq --help` is byte-identical to the pre-migration page: nine over-long names were hand-aligned to no rule, and `CliRegistry` carries that as data (`helpGap`) rather than normalising a user-visible column. Eight module-level types (`TestSummary*`, `ReconCluster`, `RuleEdits`, `FmtRunResult`, `RuleFixOutcome`) still sit in `Cli.hx` because tests in three packages resolve them through `import anyparse.query.Cli`.

## From § The CLI layer › Invariant 1 at this layer

What a run legitimately needs to remember goes on `CliContext`, an instance created per invocation and handed to the command. `--exit-on-empty` is the live example: parsed once by the dispatcher, consumed much later by whichever find-walker the run ended in. `Cli` carried it across that gap in a `private static var` — the one piece of process-scoped mutable state in the CLI, and the shape a second run in the same process can observe. A field on a per-run instance is the same value with none of that; that static went with the last `case` arm in S70; nothing in the CLI layer is process-scoped now, and nothing mechanical pins that a command stays stateless (a `static var` on a `CliCommand` is caught by no lint rule and no test — an open item).
