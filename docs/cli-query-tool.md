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

Five commands:

| Command  | Purpose                                                |
|----------|--------------------------------------------------------|
| `ast`    | Dump parsed AST as S-expr or JSON                      |
| `search` | Structural pattern search with metavariables           |
| `refs`   | Value-binding references with lexical scope awareness  |
| `uses`   | Type-position references (field/param/return/heritage) |
| `meta`   | Metadata-on-declaration shortcut (specialization)      |

### `apq ast`

Parse a file and emit its AST.

```
apq ast <file>                     # S-expr default, full tree
apq ast <file> --json              # JSON output
apq ast <file> --at <line>:<col>   # smallest node enclosing cursor
apq ast <file> --select <path>     # subtree(s) matching a selector
apq ast <file> --depth <n>         # truncate beyond depth n (counted from
                                   # the displayed root: module by default,
                                   # the matched node when paired with
                                   # --select / --at; --depth 0 = root only)
apq ast <file> --select <path> --doc --source   # + doc-comment / verbatim slice
```

Output is deterministic so the tool is usable in CI and diff-based workflows.

### `apq search`

Find AST subtrees matching a pattern.

```
apq search <pattern> <file-or-dir-or-glob>
apq search <pattern> <files> --json
apq search --kind <Kind> <pattern> <files>   # only match nodes of that AST kind
```

The pattern is a fragment of the target language, parsed by the same grammar plugin, with the metavariable extension described in [Pattern syntax](#pattern-syntax-for-search) below. Each match prints the source location and the bindings of any metavariables.

`--kind <Kind>` restricts matches to nodes whose AST kind equals `<Kind>` (e.g. `VarStmt`, `ParamCtor`, `ClassDecl` — the same vocabulary `ast --select`/`refs --on` use); the pattern still has to match structurally, this only narrows *where*.

`search` is a **structural** query: the pattern is parsed as code shape. A degenerate pattern that resolves to a single leaf (a bare identifier, a lone metavar, a bare literal — no children) carries no shape and only ever matches that name in expression position. The CLI detects this and emits a non-fatal stderr nudge pointing at the right tool (`refs <name> --decls` for a declaration, `uses <Type>` for a type's consumers, `ast --select` for a subtree), then runs the search anyway.

### `apq refs`

Find references to a named symbol, with lexical scope awareness.

```
apq refs <name> <file-or-dir-or-glob>
apq refs --writes <name> <files>     # only assignment positions
apq refs --reads <name> <files>      # only read positions
apq refs --decls <name> <files>      # only declaration positions
apq refs --decls <name> <files> --doc --source   # + doc-comment / verbatim slice
```

Scope awareness is lexical only: a local declaration shadows an outer name with the same identifier, and the tool correctly attributes references to the innermost binding. A loop iterator (e.g. a `for`/comprehension induction variable) is a declaration scoped to the loop body: references inside the loop resolve to it and shadow an outer same-named binding, while references after the loop fall through to the enclosing scope. A catch-clause exception name is scoped the same way (visible only inside the clause body); a lambda parameter is a declaration scoped to the lambda body. No type-based resolution. No cross-file resolution.

Write classification is based on parent-context: an identifier reference is a `write` when it sits as the direct first operand of an assignment-shaped node declared by the grammar plugin (bare, compound, and null-coalescing assignments all qualify). Identifiers nested deeper on the LHS — e.g. inside field access or index access — remain `read`s, matching the semantic intent of the `--writes` query (the modified binding is the host, not the inner operands). Each LHS occurrence produces one hit: compound assignments (`x += 1`) are reported as a single `write` — the implicit read on the LHS is not emitted as a separate hit.

### `apq uses`

Find **type-position** references to a named type — the sister of
`refs` for the type axis. `refs` resolves value/identifier bindings and
is deliberately blind to type positions; `uses` covers exactly those:
field / var type annotations, enum-constructor and function parameter
types, function/lambda return types, type-parameter constraints,
`extends`/`implements` heritage, and `new T(...)`.

```
apq uses <type-name> <file-or-dir-or-glob>
```

A parameterized type reports every nominal name it contains:
`Array<HxVarMore>` yields a hit for `Array` **and** for `HxVarMore`
(the inner type is usually what a grammar blast-radius query cares
about). No scope/binding resolution — a type occurrence has no
shadowing semantics. No cross-file resolution.

Implementation note: the default parse tree (consumed by
`ast`/`search`/`refs`/`meta`) intentionally drops type-position nodes
to stay lean; `uses` runs on a separate projection
(`GrammarPlugin.parseFileTypeRefs`), so adding it leaves the other four
commands byte-identical by construction.

### `--doc` / `--source` (opt-in, on `refs` / `uses` / `ast`)

For each declaration hit, also emit prose alongside the
`file:line:col`, so a locate step doesn't force a follow-up full-file
read (in this codebase the leading doc-comment *is* the spec).

```
apq refs <name> <files> --decls --doc      # + the hit's leading doc-comment block
apq refs <name> <files> --decls --source   # + the hit's verbatim source slice
apq uses <type> <files> --doc --source     # both (uses: text output only)
apq ast <file> --select <path> --source    # the selected subtree's verbatim slice
apq ast <file> --at <l>:<c> --doc          # the matched node's leading doc-comment
```

- `--doc` walks back from the hit's `span.from` over blank and
  single-line `@…` annotation lines to the immediately-preceding
  block-style or line-style comment and emits it verbatim. Multi-line
  paren-continued metadata between the comment and the decl is a known
  v1 limitation.
- `--source` is the verbatim `source[span.from .. span.to]` cut — for a
  declaration that is the whole decl including its body.
- Both are **opt-in and purely additive**. Default `refs`/`uses`/`ast`
  output (text and JSON) is byte-identical: the reconstruction is from
  source offsets only — never a tree node — and the JSON `doc` /
  `source` keys are `@:optional`, omitted unless the flag is set
  (the `parseFileTypeRefs` separate-projection discipline at the
  slice layer). `refs --json` and `ast --json` carry the extra keys;
  `uses` has no JSON form, so `--doc`/`--source` there are text-only.

### `apq meta`

Shortcut for "find declarations carrying a specific metadata annotation". Technically expressible as a `search` query, but common enough to deserve a first-class command.

```
apq meta <annotation> <file-or-dir-or-glob>
apq meta <annotation> --arg-contains <substring> <files>
apq meta --on <decl-kind> <files>    # list every annotation on a kind
```

`<annotation>` syntax is the **target language's user-source annotation syntax**, not anyparse grammar metadata — for Haxe it is `@:foo` or `@bar`; for AS3 it would be `[Foo]`; for Python it would be `@foo`. The preset alias picks the syntax.

### Input path forms

The trailing positional of `search` / `refs` / `meta` accepts one of three
forms (resolved in-process — no shell expansion required, quote globs to
avoid the shell pre-expanding them):

- a **file** — parsed directly;
- a **directory** — walked recursively, every `.hx` file parsed;
- a **glob** — `*` (within a path segment), `**` (across segments;
  `**/` also matches zero directories), `?` (one char), `[...]`
  (character class, leading `!` negates). The literal prefix before the
  first metacharacter is the walk root, so `src/grammar/haxe/*.hx` scans
  only that directory while `src/**/Hx*.hx` scans the whole subtree.

### Parse-failure locus

When the parser cannot parse a file it reports the **farthest input
position any terminal reached** (PEG max-position heuristic), not the
position where the outermost rule bailed. Without this, recursive-descent
backtracking collapses every failure to the file head (`expected <root>`);
with it, the reported span points at the innermost blocking token, which
is what diagnostics and recon tooling need.

## Mutation commands (source rewriting)

Distinct from the read-only query commands above: these **rewrite** source. Without `--write` the rewrite goes to stdout; with `--write` it overwrites the file in place. Cursor positions use the same column convention `apq refs` prints. Two sub-families differ in how they format the result:

- **Refactoring ops** — scope-correct edits driven by the `refs` / `Scope` binding resolver, **format-preserving** (span-splice — everything outside the edit is byte-verbatim) and re-parse-validated: `rename` (`--scope <dir>` for cross-file type rename), `inline`, `extract-var`, `change-sig`, `move`, `add-param`, `remove-param`. These move EXISTING tokens, so no new code is formatted.

- **Structural insert / replace ops** — these introduce NEW code, so they are **writer-emitted**, not spliced as-is: the raw new text is placed, then the WHOLE file is re-emitted through the writer (the trivia/comment-preserving pipeline), which formats the inserted code by the grammar's own rules and re-parse-validates in one step (an unparseable result is rejected). Because a whole-file rewrite would also reflow any unrelated hand-wrapping, the file must already be **writer-canonical** (`write(parse(f)) == f`); a non-canonical file is refused unless `--reformat` is passed (which opts into canonicalising the whole file — the gofmt workflow). Requires a grammar with a writer.

| Command | Purpose |
|---|---|
| `apq add-member <file> --type <T> '<memberText>' [--reformat]` | Append `<memberText>` to the body of type `<T>` (writer-formatted); append-only — ordering is the formatting layer's job |
| `apq add-import <file> <module.path> [--using] [--reformat]` | Add an `import` (or `using`) after the last import / using, else after `package`, else at file top; a same-kind duplicate is refused |
| `apq replace-node <file> (--select <sel> \| --at <l>:<c>) '<newSource>' [--reformat]` | Replace one node's source span (writer-formatted); `--select` reuses the `ast` selector (must match exactly one node), `--at` the innermost node at the cursor |

Run `apq <op> --help` for the full per-op flag reference and safety boundary. The hxq skill (`~/.claude/skills/hxq/SKILL.md`) carries the authoritative safety-boundary table for every mutation op.

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
| `<kind> <name>`     | Space is an accepted alias for `:`               |
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

Per-command schemas were MVP-locked at the phase that shipped each command (`ast` in Phase 1, `search` in Phase 2, `refs` in Phase 3) and are now **finalized** (Phase 4) after shell-composition usage validated the shape. The schemas below are the **v1 stable contract**: subsequent versions may extend them additively (new optional keys) but will not rename, remove, or retype an existing key.

Two cross-cutting finalized conventions:

- **Envelope.** Multi-result commands (`search`, `refs`, `meta`) wrap their result array in a single top-level object — `{ "matches": [...] }` for `search`, `{ "hits": [...] }` for `refs` and `meta` — so the output is one well-formed JSON value per invocation. Consumers that want the bare array unwrap the single envelope key.
- **Optional keys are omitted, not null.** When a value is absent (a node with no name, an unresolved reference's binding, a node with no source span) the key is left out of the object entirely rather than emitted as `null`. `jq` filters should use `// empty` or `?` accordingly.

### Output JSON schemas (v1, finalized)

All schemas share one span type:

```
Span = { start: [line, col], end: [line, col] }
```

`line` is 1-based, `col` is 0-based.

**Kind vocabulary.** The string values of `kind` (in `ast.Node.kind`, `meta.decl.kind`, and the `ast --select` selector input) come from one **plugin-defined vocabulary** shared across all three surfaces. For a typical curly-brace language the kinds are short lowercase names like `class`, `function`, `field`, `case`. The vocabulary is published by each grammar plugin as part of its public contract. See [Kind vocabulary](#kind-vocabulary) for the Haxe plugin's published list and how to discover any kind via `apq ast`.

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
  "span": Span                                     // omitted when node has no source coordinates
}
```

`span` is present on source-addressable nodes (declarations, statements, expressions) and omitted on transparent inner structural nodes and the synthetic root, the same way `name` is omitted when absent. This is the finalized rule — earlier drafts left `span` out of the `ast` schema entirely; it is now part of the v1 contract.

When `--select` is used, the response is `{ "file": "...", "matches": Node[] }`. When `--at` is used, `tree` is the smallest enclosing node only.

#### `search`

```
{
  "matches": [
    {
      "file": "path/to/input",
      "span": Span,
      "bindings": [
        { "name": "X", "text": "matched source text", "span": Span },
        ...
      ]
    },
    ...
  ]
}
```

`bindings` is a **static array** of `{ name, text, span }` objects (finalized v1 shape). The dynamic-object form sketched in earlier drafts (`{ "X": {...} }`, metavar names as JSON keys) was rejected so the schema stays static and macro-generated. `name` drops the leading `$` — pattern metavariable `$X` produces `"name": "X"`. The array is empty (`[]`) for patterns that contain only literals or `$_` wildcards.

#### `refs`

```
{
  "hits": [
    {
      "file": "path/to/input",
      "kind": "read" | "write" | "decl",
      "span": Span,
      "name": "the_symbol",
      "binding": Span                        // optional; see below
    },
    ...
  ]
}
```

The optional `binding` field carries the span of the declaration this hit
resolves to. Declarations self-bind (`binding == span`). Reads and writes
point to the innermost enclosing in-file declaration with a matching name.
The field is omitted when a read or write is unresolved — typically a
cross-file reference or an inherited member from a base type. Loop-iterator
bindings (`for` / comprehension induction variables), catch-clause
exception names, and lambda parameter names ARE resolved: a grammar marks
the relevant transparent structs so each carries a per-instance binding
span, surfacing as an addressable node.

#### `meta`

```
{
  "hits": [
    {
      "file": "path/to/input",
      "annotation": "@:foo",                     // verbatim from source
      "args": ["arg1", "arg2"],                  // [] when annotation takes no args
      "decl": {
        "kind": "class" | "function" | "field" | ...,
        "name": "thingItIsAttachedTo",           // omitted for anonymous decls
        "span": Span                             // span of the attached declaration
      }
    },
    ...
  ]
}
```

An annotation attributes to the declaration it precedes in source. When an annotation has no following declaration in its container (expression-level metadata) it attributes to the nearest enclosing declaration — a deliberate v1 simplification, not a finer expression-level target.

### Kind vocabulary

`kind` strings — in `Node.kind`, `meta.decl.kind`, and every `ast --select` segment — are exactly the grammar plugin's AST node-constructor names. There is no separate display mapping and the engine never enumerates kinds: each plugin publishes its own set as part of its public contract. Two practical consequences:

- **Discovery is self-documenting.** `apq ast <file>` (S-expr) and `apq ast <file> --json` print the real `kind` of every node. That is the authoritative way to learn the kind of any construct in any language — the index below is a convenience list for the Haxe plugin, not a second source of truth.
- **One surface keyword can be several kinds.** Kinds track the *construct*, not the spelling (see the `enum` example below).

The Haxe grammar plugin publishes the following commonly-navigated declaration kinds — the values you pass to `ast --select`, read back as `decl.kind`, and (for declaration-host kinds) pass to `meta --on`. Another plugin publishes its own; this list is illustrative of the per-plugin contract, not part of the engine. It is the common subset, not the whole grammar — every node constructor is a valid `--select` segment, so when in doubt run `apq ast` and read the kind off the tree.

| Group | Kinds |
|---|---|
| Module type decls | `ClassDecl`, `InterfaceDecl`, `EnumDecl`, `EnumAbstractDecl`, `AbstractDecl`, `TypedefDecl` |
| Module var / fn | `VarDecl`, `FnDecl` |
| Type members | `VarMember`, `FinalMember`, `FnMember` |
| Anonymous-type fields | `VarField`, `FinalField`, `FnField` |
| Local declarations | `VarStmt`, `FinalStmt` |
| Enum constructors | `SimpleCtor`, `ParamCtor` |
| Params & bindings | `Required`, `Optional`, `Rest`, `LambdaParam` |

**Distinct constructs get distinct kinds — `enum` vs `enum abstract`.** These two look alike in source but parse to different kinds with different child shapes:

```
$ apq ast x.hx
(module
  (EnumDecl E (SimpleCtor A) (ParamCtor B (Required x)))
  (EnumAbstractDecl EA (VarMember X (IntLit)) (VarMember Y (IntLit)) (Named Int)))
```

`EnumDecl` is an algebraic enum — its children are constructors (`SimpleCtor`, `ParamCtor`). `EnumAbstractDecl` is a typed-constant abstract — its children are `VarMember`s plus the underlying `Named` type. They are deliberately separate kinds because they are separate constructs, so `ast --select EnumDecl` does **not** match an `enum abstract`, and vice versa — by design. Select the kind that matches the construct, or run `apq ast` to see which kind a given declaration parsed to. The tool keeps these precise rather than collapsing them under one lossy `enum` label.

**`final` is a wrapper shape, and `--select` folds it.** The `final` modifier wraps a declaration in an extra node: `final class C` parses to `FinalDecl(ClassForm C …)` — the named node is `ClassForm`, not `ClassDecl` — and `final function f()` parses to `FinalModifiedMember` rather than `FnMember`. Unlike `enum` vs `enum abstract` (genuinely different constructs), a `final class` *is* a class and a `final function` *is* a method — same construct, just a wrapper. So `ast --select` deliberately **folds** these: `--select ClassDecl` also matches a `final class`'s `ClassForm`, and `--select FnMember` also matches a `final function`'s `FinalModifiedMember` (chains too — `--select 'ClassDecl > FnMember'` reaches a final method inside a final class). This folding is `--select`-only and limited to the `final` wrappers; the precise per-position kinds (`VarMember` vs `VarStmt`, `EnumDecl` vs `EnumAbstractDecl`) are unchanged. A `final` FIELD (`final x:Int` → `FinalMember`) is **not** folded into `VarMember` — it is its own kind, not a wrapper.

## Shell composition

The JSON envelopes are designed for `jq` / `xargs` pipelines. The
five examples below were each run end-to-end against a real corpus
and their output trimmed verbatim. Decl-kind tokens (`FnMember`,
`VarMember`, …) are the Haxe grammar plugin's published vocabulary;
another plugin publishes its own.

**1 — names of every declaration carrying an annotation:**

```
$ apq meta @:inject --json src/ | jq -r '.hits[].decl.name'
cache
db
```

**2 — annotation inventory on functions in one file:**

```
$ apq meta --on FnMember --json Service.hx \
    | jq -r '.hits[] | "\(.annotation) -> \(.decl.name)"'
@:route -> list
@:auth -> list
@:route -> get
```

**3 — count occurrences of a configurable flag annotation:**

```
$ apq meta @:route --json src/ | jq '.hits | length'
2
```

**4 — blast-radius check: how many sites write a symbol:**

```
$ apq refs --writes n --json Repo.hx | jq '.hits | length'
2
```

**5 — batch a glob with `xargs`, project name + tag per hit:**

```
$ ls *.hx | xargs -I{} apq meta --on VarMember --json {} \
    | jq -r '.hits[] | "\(.decl.name):\(.annotation)"'
cache:@:inject
db:@:inject
```

These compose because every command emits exactly one JSON value
(the envelope), absent values are omitted rather than `null`, and
spans are a stable two-element-array shape `jq` can index directly.

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
