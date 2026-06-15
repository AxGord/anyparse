# anyparse

**Structural code tooling for Haxe — query and transform source through typed ASTs instead of text.**

anyparse parses source into a typed AST and gives you two things on top of it:

- **`hxq` / `apq` — a structural alternative to grep.** Find code by its *shape*
  (every `return $x;`, every `a * b`, every declaration named `area`) instead of by
  regex over lines.
- **Scope-correct, AST-level editing.** Rename, inline, extract, reorder parameters,
  move types between files — each resolved against real scopes and re-parse-validated,
  so the rewrite is correct by construction and the rest of the file stays byte-for-byte
  intact. These are the kind of edits that automated tools — and AI coding assistants —
  can apply safely, because the tool understands the code rather than pattern-matching it.

Underneath sits a macro-based **platform**: describe a grammar declaratively as Haxe
types with metadata, and a `@:build` macro generates a specialized parser, writer and
AST-transform for it. The Haxe grammar that powers `hxq` is itself just one such
plugin; JSON and the `ar` binary archive format are others.

## Status

**Working and dogfooded** — `hxq`/`apq` are used to query and restyle this repo's own
source — not the "walking skeleton" earlier revisions described.

- `hxq`/`apq` ship a full structural-query CLI plus a set of scope-correct
  refactoring operations (listed below), all exercised by the test suite.
- **3179 tests / 7355 assertions / 0 failures** on the JS target.
- The Haxe writer round-trips against the AxGord/haxe-formatter corpus
  (945 fixtures: 755 byte-exact, 113 formatting deltas, 75 not-yet-parsed) with a hard
  no-regression invariant.

What is **not** done yet, stated plainly:

- The **query/refactoring CLI is Haxe-only** today. The grammar platform handles
  multiple formats (JSON / Haxe / `ar` binary / S-expr), but `hxq`/`apq` resolve only
  the Haxe grammar plugin — JSON-aware refactoring is not wired up.
- The Haxe grammar covers the language broadly but not exhaustively (75 corpus fixtures
  still fail to parse).
- The generic `buildTransform` walks plain typed ASTs; a *format-preserving* transform
  (carrying comments/spans through) is a later slice.

This is **Phase 3** of the roadmap (Haxe grammar + formatter). See
[`docs/roadmap.md`](docs/roadmap.md).

## Install / build

Requires [Haxe](https://haxe.org) 4.x and Node.js (for the JS-based CLI).

```sh
git clone https://github.com/AxGord/anyparse
cd anyparse
haxe bin/apq-js.hxml          # builds bin/apq.js — the query/refactor CLI
```

`bin/hxq` is a thin launcher that runs `apq` with the Haxe grammar preselected. Put it
on your `PATH` for a global `hxq`:

```sh
ln -s "$PWD/bin/hxq" ~/.local/bin/hxq
```

After that, `hxq <cmd> …` == `node bin/apq.js <cmd> --lang haxe …`. The launcher
auto-rebuilds when `src/` changes.

## Quickstart

Given `Sample.hx`:

```haxe
class Sample {
	public function area(width:Int, height:Int):Int {
		final total = width * height;
		return total;
	}
}
```

**Find by structure, not regex.** Match every multiplication, every `return`, or a
declaration by name:

```sh
$ hxq search '$a * $b' Sample.hx
Sample.hx:
  3:16: match (a=width, b=height)

$ hxq ast Sample.hx --select 'FnMember:area'
(FnMember
  area
  (Required width)
  (Required height)
  (Named Int)
  (BlockBody
    (FinalStmt total (Mul (IdentExpr width) (IdentExpr height)))
    (ReturnStmt (IdentExpr total))))
```

**Resolve a symbol with scope awareness** — declarations, reads and writes, each
pointing back at its binding:

```sh
$ hxq refs total Sample.hx
Sample.hx:
  3:2: [decl] total
  4:9: [read] total -> 3:2
```

**Refactor at the AST level.** Operations take a `<line>:<col>` cursor (the exact
coordinate `refs` prints), print the rewrite to stdout, and apply in place with
`--write`. Everything but the touched span stays byte-identical, and a result that does
not re-parse is rejected rather than written.

```sh
$ hxq rename Sample.hx 3:8 prod          # rename the binding at the cursor + its uses
class Sample {
	public function area(width:Int, height:Int):Int {
		final prod = width * height;
		return prod;
	}
}

$ hxq inline Sample.hx 3:8               # inline the local into its single use
class Sample {
	public function area(width:Int, height:Int):Int {
		return (width * height);
	}
}

$ hxq change-sig Sample.hx 2:18 1,0      # reorder params (+ resolvable call sites)
class Sample {
	public function area(height:Int, width:Int):Int {
		final total = width * height;
		return total;
	}
}
```

Every query and most refactors accept `--json` for machine-readable output — the
combination of stable line:col coordinates, JSON, and re-parse validation is what makes
these operations safe to drive from scripts or coding agents.

For the full flag set on any command: `hxq <cmd> --help`.

## Features

### Structural query (read-only)

| Command | Finds |
|---|---|
| `ast` | the parsed AST (S-expr or `--json`), or a subtree by `--select` / `--at` |
| `search` | expression/statement **shapes** with `$x` metavars (`recv.add($x)`) |
| `refs` | value bindings — `--decls` / `--reads` / `--writes`, scope-resolved |
| `uses` | type-position references (fields, params, type params) |
| `blast` | full change-impact for a type (uses + refs + member access) |
| `mentions` / `lit` / `cases` | every named occurrence / string-or-ident leaves / switch case-patterns |
| `meta` | declarations carrying a given `@:metadata` |
| `diff` | structural AST diff between two files |
| `source` | raw verbatim lines — `--range`, or one node's source by name/position (`--select` / `--at`); no-parse mode reads files the grammar can't yet read |

### Scope-correct refactoring (rewrites)

All resolve against real scopes (never by-name text replace), preserve formatting
(span-splice; everything else verbatim), and are re-parse-validated.

| Command | Operation |
|---|---|
| `rename` | rename the binding at the cursor + its in-file occurrences; `--scope <dir>` does a cross-file **type** rename (decl, type positions, `new`/cast/`extends`, import/using segments, `T.staticMethod()`) atomically |
| `inline` / `inline-method` | inline a local variable into its reads / a single-return function into its call sites |
| `extract-var` / `extract-method` | hoist an expression into a `final`, or a statement run into a local function |
| `change-sig` / `add-param` / `remove-param` | reorder params + call-site args / append a backward-compatible param / drop a param + its arguments |
| `move` | move a type declaration to another file in the same package, carrying deps and repointing importers |
| `symbols` / `importers` / `declares` | list top-level type declarations across a scope / files importing a module / the declaration site(s) of one named type |

A second family — `add-member`, `add-import`, `add-element`, `replace-node` — *inserts*
new code: the snippet is placed at an AST-resolved position, then the file is re-emitted
through the writer so the new code is formatted by the grammar's own rules and
re-parse-validated in one step. Their inverses `remove-element` / `remove-import` /
`remove-member` delete a node (with its doc-comment) the same way. `set-doc` adds or
replaces a declaration's doc-comment, and `set-modifier` flips its visibility / adds or
removes modifiers (`public`, `+static`, `-inline`, …) — both at a cursor, without
retyping the declaration (the safe replacement for editing a modifier via `replace-node`).
`set-comment` is the comment counterpart of `set-doc`: it replaces the comment at a
cursor — a block comment whole, a contiguous run of full-line `//` comments as one unit,
or a trailing `//` — reaching inline comments that aren't declaration doc-blocks.

`rewrite '<pattern>' '<replacement>'` is structural search-and-replace — the fusion of
the structural `search` with a span-replace. Every node matching the pattern (with `$x`
metavariables) is rewritten from a template in one pass: `$x` / `${x}` expand to the
captured node's source, and `${x+N}` / `${x-N}` shift an integer-literal metavariable by
N (`gofmt -r` / comby for the grammar's own AST).

`comment-rewrite '<find>' '<replace>' <path>…` is the write-twin of `lit`: a text
find/replace scoped to comment **bodies** — the gap `rewrite` (AST nodes only) and
`set-comment` (one block at a time) leave open. `--regex` makes `<find>` a regex and
`<replace>` a template where `${1}` expands a capture group and `${1+N}` shifts an
integer group by N. Code and the comment delimiters are never touched; strings are
skipped. A mechanical convention change cited across many doc-comments (e.g. bumping a
coordinate) becomes one command instead of a hand-rolled script.

### File creation & formatting

The create-side and whole-file counterparts of the insert ops — a new file gets the same
guarantees: it parses or is rejected, comes out byte-canonical, and is written atomically.

| Command | Operation |
|---|---|
| `new` | create a new module deterministically — `--kind class` (default; `--implements <iface>` stubs every method with its real sliced signature and carries the imports so it type-checks) / `interface` / `enum` / `typedef` / `abstract` (`--underlying <T>` [`--from`/`--to`]), plus `--extends <T>` (class superclass / interface super-interfaces / typedef `> Base` struct extension, qualified names imported), `--open` (non-final class), `--field` verbatim members, and `@@` stdin sections (`@@ <method>` bodies / `@@ members` free-form member block / `@@ imports` / `@@ doc`). `--raw -` instead takes the COMPLETE file from stdin — the validated atomic equivalent of a raw write, for shapes no spec covers |
| `fmt` | canonicalise files / dirs through the writer round-trip — gofmt-style `--write` (rewrite in place) / `--list` (report drift) |

Because raw text editing has no such guarantee, `new` is the way to create a file and
`fmt` the way to bring one back to canonical form.

### Analysis (lint)

`lint <scope> [--rule <id>] [--fix]` runs grammar-agnostic checks and reports violations
grouped by file; `--fix` applies the auto-fixable subset (re-parse-validated like every
rewrite). A check is a plugin — a new one is a new class, not a core change.

Findings are suppressible inline: a trailing `// noqa` (or `// noqa: <rule>,<rule>` for
named rules) clears findings on its line, and `// CHECKSTYLE:OFF` … `// CHECKSTYLE:ON`
clears a region — so one stubborn false positive never makes a rule unusable. `--fail-on
<error|warning|info>` exits non-zero when a finding at or above that severity survives
(default: report-only, exit 0), and `--format <text|json|checkstyle>` switches the
output — checkstyle XML the same CI tooling that reads `checkstyle.json` can ingest.

An `apqlint.json` discovered by walking up from a linted file configures the run: per
rule it can disable the rule (`"enabled": false`, dropped from the default set — an
explicit `--rule` still runs it), override its reported severity (`"severity":
"error|warning|info"`, applied before `--fail-on` and the report), or set a
rule-specific option (e.g. complexity's `"max"`, which takes precedence over a
`checkstyle.json` threshold). A missing or malformed file is a no-op.

```json
{ "rules": {
  "naming":                        { "severity": "error" },
  "complexity":                    { "max": 15 },
  "fold-adjacent-string-literals": { "enabled": false }
} }
```

| Check | Flags |
|---|---|
| `unused-import` | an import whose bound name is never referenced in the file |
| `unused-local` | a local `var` / `final` never read in its enclosing scope |
| `duplicate-import` | an import / using declared more than once in the same file |
| `naming` | a declaration name violating the convention — the built-in default, or one adapted from a project's `checkstyle.json` |
| `unused-private` | a `private` field / method never referenced — flagged only when the type is provably confined to its file (no subtype, `@:access`, `@:allow`, or skip-parse) |
| `complexity` | a function whose cyclomatic complexity exceeds the threshold — the built-in default (10), or a `CyclomaticComplexity` max adapted from a project's `checkstyle.json` (decision points: `if`/`while`/`for`/`case`/`catch`/`&&`/`\|\|`/`?:`/`??`) — report-only |
| `fold-adjacent-string-literals` | a `+` chain of adjacent same-quote plain string literals that can be merged into one (`"a" + "b"` → `"ab"`); `--fix` folds it (interpolated / mixed-quote / non-literal operands left alone) |

### Grammar platform

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
below are the design direction — the Status and Features sections above mark what is
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
  [`docs/cross-family-contract.md`](docs/cross-family-contract.md).*
- **Performance** — generated parsers and writers are specialized per type at compile
  time, targeting hand-written speed.

The **Fast/Tolerant** two-mode build and the **one-AST-one-writer** guarantee (described
under *Grammar platform* above) are part of this direction and already in place.

## Non-goals (by design)

- **Not an automatic cross-language translator.** Deep semantic translation between
  unlike languages (Python ↔ Rust) is out of scope; the platform provides infrastructure
  for *user-written* transforms, not magic.
- **Not a native code generator.** Integrate with LLVM/WASM if binary emission is needed.
- **Not a live-background incremental parser.** On-demand reparse with caching is in
  scope; continuous tree-sitter-style incrementality is not.

## Running the tests

```sh
haxe test.hxml          # neko (fast compile, fast run, default)
haxe test-js.hxml       # js/node — then: node bin/test.js
haxe test-interp.hxml   # Haxe macro interpreter (no compile step)
```

The corpus round-trip layer runs only when `ANYPARSE_HXFORMAT_FORK` points at a
haxe-formatter fixtures checkout.

## Documentation

Deeper reference lives in [`docs/`](docs/): `architecture.md`, `design-principles.md`,
`roadmap.md`, `strategies.md`, `formats.md`, `cli-query-tool.md`, and `testing.md`.

## License

MIT. See `LICENSE`.
