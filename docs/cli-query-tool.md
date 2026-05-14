# CLI query tool (`apq` / `hxq`)

This document specifies the CLI query tool built on top of anyparse. It is the design baseline — the phased work plan lives in [cli-query-roadmap.md](cli-query-roadmap.md).

## What this is

A command-line tool for **read-only AST queries** over source files in any language anyparse has a grammar for.

The long-term ambition is a **universal AST-grep**: structural search, navigation, and metadata indexing that works identically across every grammar plugin. The engine is parameterised over `(GrammarPlugin, ParseResult, Query)` — nothing in the engine references concrete AST node types of any single language.

Day-1 scope is Haxe-only, but the engine boundary is set up so that adding the next language is a config-only change (a preset alias + the grammar plugin itself), not a code change in the query engine.

## What this is NOT

These are deliberate decisions for v1, not limitations to be lifted opportunistically:

- **Not a rewriter.** v1 reads, it does not modify. Rewriting needs careful handling of formatting and comments and will reuse the anyparse writer pipeline; that is a separate slice.
- **Not type-aware.** Symbol queries are lexical with scope tracking — no type resolution, no overload selection, no completion. A typed query layer is a deferred extension, not a v1 deliverable.
- **Not an LSP.** No editor protocol, no language server, no incremental indexer. The tool is a one-shot CLI invocation per query.
- **Not a dependency graph builder.** Cross-file analysis (call graphs, import graphs) is out of scope. Queries operate on one file at a time, or on a glob of files in a stateless batch.
- **Not a project loader.** No `.hxml` parsing, no classpath resolution. Inputs are files passed on the command line or via glob.

## Naming convention

- `apq` is the engine and the canonical binary name. It always takes a `--lang <name>` argument selecting the grammar plugin.
- `hxq` is a thin alias that pre-selects the Haxe grammar: `hxq <args>` is `apq --lang haxe <args>`.

Future language presets follow the same pattern: `as3q`, `pyq`, etc. Each preset is a one-line alias; the engine binary is always `apq`.

This convention exists so that the user does not lock themselves into a Haxe-coloured name now that the long-term scope is multi-language. If only one language existed for the foreseeable future, the alias would be unnecessary.

## Command surface

Four commands in v1:

| Command  | Purpose                                                |
|----------|--------------------------------------------------------|
| `ast`    | Dump parsed AST as S-expr or JSON                      |
| `search` | Structural pattern search with metavariables           |
| `refs`   | Symbol references with lexical scope awareness         |
| `meta`   | Metadata-on-declaration shortcut (specialization)      |

### `apq ast`

Parse a file and emit its AST.

```
apq ast <file>                     # S-expr default, full tree
apq ast <file> --json              # JSON output
apq ast <file> --at <line>:<col>   # smallest node enclosing cursor
apq ast <file> --select <path>     # subtree(s) matching a selector
apq ast <file> --depth <n>         # truncate beyond depth n
```

Output is deterministic so the tool is usable in CI and diff-based workflows.

### `apq search`

Find AST subtrees matching a pattern.

```
apq search <pattern> <file-or-glob>
apq search <pattern> <files> --json
```

The pattern is a fragment of the target language, parsed by the same grammar plugin, with the metavariable extension described in [Pattern syntax](#pattern-syntax-for-search) below. Each match prints the source location and the bindings of any metavariables.

### `apq refs`

Find references to a named symbol, with lexical scope awareness.

```
apq refs <name> <file-or-glob>
apq refs --writes <name> <files>     # only assignment positions
apq refs --reads <name> <files>      # only read positions
apq refs --decls <name> <files>      # only declaration positions
```

Scope awareness is lexical only: a local declaration shadows an outer name with the same identifier, and the tool correctly attributes references to the innermost binding. No type-based resolution. No cross-file resolution.

### `apq meta`

Shortcut for "find declarations carrying a specific metadata annotation". Technically expressible as a `search` query, but common enough to deserve a first-class command.

```
apq meta <annotation> <file-or-glob>
apq meta <annotation> --arg-contains <substring> <files>
apq meta --on <decl-kind> <files>    # list every annotation on a kind
```

`<annotation>` syntax is the **target language's user-source annotation syntax**, not anyparse grammar metadata — for Haxe it is `@:foo` or `@bar`; for AS3 it would be `[Foo]`; for Python it would be `@foo`. The preset alias picks the syntax.

## Pattern syntax for `search` (frozen for v1)

The pattern is parsed by the active grammar plugin **with a metavariable extension**: any identifier-shaped token starting with `$` is treated as a metavariable rather than a concrete identifier.

| Form              | Meaning                                                                    |
|-------------------|----------------------------------------------------------------------------|
| `$X`              | Bind one node. Reusing the same name must match the same subtree.          |
| `$_`              | Wildcard. Matches one node. Does not bind. Multiple `$_` in one pattern are independent — each matches any subtree without cross-constraint. |

The matcher walks the input AST and tries to unify each subtree with the pattern AST node-for-node, treating metavariables as holes.

Example concept:

```
apq search '$x = $x + 1' file.hx
```

matches every self-increment-by-1 in `file.hx` and binds `$x` to the actual variable expression at each site.

### Non-features in v1

These are intentionally deferred to keep the v1 surface small and the semantics tight:

- Ellipsis `...` for "any number of nodes". Phase 2+ candidate.
- Type filters (`$X:Int` to constrain matches by type). Requires type resolution — deferred indefinitely.
- Regex on identifiers (`$X /pattern/`). Phase 2+ candidate.
- Negative patterns / `not(...)`. Phase 2+ candidate.
- Sibling / ancestor combinators. Phase 2+ candidate.

The v1 syntax is the **smallest set that is still useful** — concrete fragments with hole metavariables. Every deferred feature can be added later without breaking the existing syntax.

## Selector syntax for `ast --select` (frozen for v1)

The selector is a minimal path language for navigating to subtrees.

| Form                | Meaning                                          |
|---------------------|--------------------------------------------------|
| `<kind>`            | Match any node of this kind                      |
| `<kind>:<name>`     | Match a node of this kind with the given name    |
| `A > B`             | `B` is a direct child of `A`                     |

Kind names come from the grammar plugin's public AST vocabulary — typically the user-facing node names (class, function, field, etc.), not internal type-name details.

Example concept:

```
apq ast file.hx --select 'class:Foo > function:bar'
```

Returns the AST of the `bar` method inside class `Foo`.

### Non-features in v1

- Attribute filters (`class[name=Foo]` style). Phase 2+ candidate.
- Descendant combinator (` ` between selectors). Phase 2+ candidate.
- Pseudo-selectors (`:first-child`, `:has(...)`). Phase 2+ candidate.

A more expressive selector layer can be added later; the v1 grammar is forward-compatible.

## Output formats

Every command supports two output formats:

- **Text** (default). Human-readable, single-line-per-match summaries; intended for terminal consumption.
- **JSON** (`--json`). Machine-readable, stable schema documented per command. Intended for shell composition (`apq … --json | jq …`).

Both formats include source spans (`file:line:col` or structured `{file, start, end}`) so results can be fed into editors and other tools.

Per-command schemas are **MVP-locked** at the phase that ships each command (`ast` in Phase 1, `search` in Phase 2, `refs` in Phase 3) and **finalized** in Phase 4 once shell-composition usage validates the shape. Subsequent versions may extend schemas additively but not break them.

### Output JSON schemas (MVP sketches)

All schemas share one span type:

```
Span = { start: [line, col], end: [line, col] }
```

`line` is 1-based, `col` is 0-based.

**Kind vocabulary.** The string values of `kind` (in `ast.Node.kind`, `meta.decl.kind`, and the `ast --select` selector input) come from one **plugin-defined vocabulary** shared across all three surfaces. For a typical curly-brace language the kinds are short lowercase names like `class`, `function`, `field`, `case`. The vocabulary is published by each grammar plugin as part of its public contract.

#### `ast`

```
{
  "file": "path/to/input",
  "tree": Node
}

Node = {
  "kind": "class" | "function" | "field" | ...,   // plugin-defined; see above
  "name": "Foo",                                   // omitted when node has no name
  "children": Node[],
  "span": Span
}
```

When `--select` is used, the response wraps results in an array:

```
{ "file": "...", "matches": Node[] }
```

When `--at` is used, `tree` is the smallest enclosing node only.

#### `search`

```
[
  {
    "file": "path/to/input",
    "span": Span,
    "bindings": {
      "X": { "text": "matched source text", "span": Span },
      ...
    }
  },
  ...
]
```

Binding keys drop the leading `$` — pattern metavariable `$X` produces JSON key `"X"`. `bindings` is empty (`{}`) for patterns that contain only literals or `$_` wildcards.

#### `refs`

```
[
  {
    "file": "path/to/input",
    "kind": "read" | "write" | "decl",
    "span": Span,
    "name": "the_symbol"
  },
  ...
]
```

#### `meta`

```
[
  {
    "file": "path/to/input",
    "annotation": "@:foo",                       // verbatim from source
    "args": ["arg1", "arg2"],                    // [] when annotation takes no args
    "decl": {
      "kind": "class" | "function" | "field" | ...,
      "name": "thingItIsAttachedTo",             // omitted for anonymous decls
      "span": Span                               // span of the attached declaration
    }
  },
  ...
]
```

## Universalization invariant

This is the load-bearing architectural rule. **The query engine must not contain any code that references a specific language's AST node types.**

The engine sees:

- A `GrammarPlugin` (parser, AST type vocabulary, metavariable token marker).
- A `ParseResult` produced by that plugin from an input file.
- A `Query` — for `search`, a pattern parsed by the same plugin into an AST + metavariable bindings; for `ast/refs/meta`, a structural request.

The matcher walks both ASTs through a generic tree-traversal interface that the plugin exposes. Adding a new language means:

1. The grammar plugin already exists (anyparse needs it for parsing/formatting anyway).
2. A preset alias is added (one line).
3. The plugin declares its metavariable token marker (`$` for most languages — configurable for languages where `$` has lexical meaning, e.g. shell).

Engine code that switches on Haxe-specific types is a bug. This invariant is the difference between "Haxe AST-grep" and "universal AST-grep" — and must be enforced from the first commit.

See [strategies.md](strategies.md) and [formats.md](formats.md) for the existing anyparse plugin-interface vocabulary that this engine builds on top of.

## Architecture sketch

```
┌───────────────────────────────────────────────────────────┐
│  CLI dispatch (parse argv, pick command, pick grammar)    │
└─────────────────────────────┬─────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────┐
│  GrammarPlugin (loaded by --lang)                         │
│  - Parser (anyparse-generated)                            │
│  - AST traversal interface                                │
│  - Metavariable token marker                              │
└─────────────────────────────┬─────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────┐
│  Parser pipeline (anyparse runtime)                       │
│  Input file ──► parse ──► AST                             │
│  Pattern string ──► parse-with-metavars ──► Pattern AST   │
└─────────────────────────────┬─────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────┐
│  Engine (language-agnostic)                               │
│  - Tree walker                                            │
│  - Unification (Pattern AST × Input AST → bindings)       │
│  - Scope tracker (for refs)                               │
│  - Selector matcher (for ast --select / meta)             │
└─────────────────────────────┬─────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────┐
│  Output formatter                                         │
│  - Text                                                   │
│  - JSON (--json)                                          │
└───────────────────────────────────────────────────────────┘
```

Key points:

- **Pattern parsing reuses the grammar plugin.** A pattern is just source code with a marker for holes; the same parser produces a pattern AST. This is what makes the system universal — no separate query DSL grammar per language.
- **Unification is structural.** The matcher walks the pattern AST and the input AST in lockstep. A metavariable accepts any subtree (with binding consistency across reuses); every other node must match by kind and child structure.
- **Scope tracking is plugin-supplied.** Each grammar plugin exposes which nodes introduce a lexical scope. The engine does not hard-code that knowledge.
- **No caching across invocations in v1.** The CLI is stateless. Within a single run, parsed inputs may be memoised across queries; that is a perf detail, not an API surface.

## Project structure

Forward reference — files do not exist yet. When v1 ships:

```
src/anyparse/query/
  Engine.hx             # tree walker + unification, language-agnostic
  Pattern.hx            # metavariable extension over grammar parse
  Selector.hx           # path-language matcher
  Scope.hx              # lexical scope tracker
  Cli.hx                # argv dispatch, command routing
  format/
    Text.hx             # text output
    Json.hx             # JSON output
bin/
  apq.hxml              # neko target build config
  hxq                   # shell alias script
```

The library code lives inside `src/anyparse/` (no separate haxelib package). The `bin/apq.hxml` target produces a single-file binary; `hxq` is a tiny shell wrapper that prepends `--lang haxe`.

## Resolved decisions (Phase 0)

The three Phase-0 questions parked in the original draft of this spec are decided. Rationale and rejected alternatives recorded here so future contributors can see why the rules are what they are.

### Metavariable reuse: structural-identity unification

When the same metavariable name (e.g. `$X`) appears twice in a pattern, both occurrences must match **AST-structurally-identical** subtrees: same node kind, same children recursively, same leaf token text.

This is the semgrep convention and matches user intuition for patterns like `$x = $x + 1`.

- Rejected: pure textual identity — too restrictive, parenthesised vs bare forms of the same expression would fail to match.
- Rejected: type-driven unification — requires the deferred typed query layer.

Cost: cheap structural compare. No type info needed.

### Star-children matching: ordered and adjacent by default

A pattern matching a container of children (a class body, a block of statements) walks the input's children **left-to-right** and unifies positionally. Adjacent matches only — the matcher does not skip ahead.

So `class { var $X; var $Y; }` matches a class whose body **begins with** two consecutive `var` fields (in source order). It does not match a class with the two `var`s separated by other members.

- Rejected: order-insensitive set matching — exponentially expensive and rarely the intended semantics for code patterns.
- The "anywhere in this container" form is reserved for a future ellipsis syntax (`...`), deferred to Phase 2+.

### Whitespace and comments in patterns: both ignored

Whitespace between tokens in a pattern is not an AST node and never participates in matching. Comments inside the pattern are discarded by the parser before the matcher sees the pattern AST. Comments in the **input** are similarly ignored when matching unless a future feature explicitly queries against a comment slot on a node.

- Rejected: treating comments as wildcard-matched nodes — adds matcher complexity for negligible real-world value.

## Open questions deferred to later phases

These remain open and will be answered in the phase that needs them:

- **Perf budget for `apq search` on large files.** Target is sub-second on the largest realistic single file (~10k lines). If unification turns out to be unacceptably slow, an indexing layer is added in Phase 5+. (Phase 2 measurement, Phase 5 action.)
- **Error reporting for malformed patterns.** Pattern parse errors must be at least as helpful as the grammar's own parse errors. (Phase 2 design.)

## See also

- [cli-query-roadmap.md](cli-query-roadmap.md) — phased delivery plan with exit criteria.
- [cli-query-phase0-queries.md](cli-query-phase0-queries.md) — the 10 hand-written queries that exercise the v1 syntax across all four commands.
- [architecture.md](architecture.md) — anyparse core architecture, parser pipeline, runtime.
- [strategies.md](strategies.md) — plugin contract for grammar strategies.
- [formats.md](formats.md) — plugin contract for formats.
