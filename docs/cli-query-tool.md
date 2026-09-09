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

The five original commands:

| Command  | Purpose                                                |
|----------|--------------------------------------------------------|
| `ast`    | Dump parsed AST as S-expr or JSON                      |
| `search` | Structural pattern search with metavariables           |
| `refs`   | Value-binding references with lexical scope awareness  |
| `uses`   | Type-position references (field/param/return/heritage) |
| `meta`   | Metadata-on-declaration shortcut (specialization)      |

(The surface has grown well past five — `apq --help` lists the live registry. The
sections below document the ones whose CONTRACT needs stating; `lit` and `cond` are
among them.)

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
apq ast <file> --type-refs         # the type-position projection instead of the
                                   # default tree (see `apq uses` below)
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
apq refs <name>... -- <files> --decls            # SEVERAL names, one walk (see below)
```

Scope awareness is lexical only: a local declaration shadows an outer name with the same identifier, and the tool correctly attributes references to the innermost binding. A name RE-declared in the SAME block shadows its own predecessor from that point on — `var x:Int = 1; … var x:String = null;` is legal Haxe and the second declaration is what a read past it binds to, so occurrences on either side of it attribute to different declarations. A loop iterator (e.g. a `for`/comprehension induction variable) is a declaration scoped to the loop body: references inside the loop resolve to it and shadow an outer same-named binding, while references after the loop fall through to the enclosing scope. A catch-clause exception name is scoped the same way (visible only inside the clause body); a lambda parameter is a declaration scoped to the lambda body. No type-based resolution. No cross-file resolution.

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

A QUALIFIED spelling answers a simple `<type-name>` too. `pkg.Mod.T`
reaches the tree as ONE node whose name is the whole dotted string, so an
exact compare reported zero uses for a type every one of whose annotations
went through its module path — and a deadness census built on that answer
deleted eleven live sub-module typedefs, for `Type not found` in six
modules. The match is on the LAST SEGMENT, not on the text: `Mod.WrapBodyOpts`
does not answer `BodyOpts`. Each hit prints the spelling it found, so a
same-simple-name type from another module is visible as one; pass the dotted
name to pin a single module (a dotted query stays an exact compare). The
same widening reaches the `uses` section of `mentions` and `blast`.

It is deliberately OPT-IN at the API (`Uses.find(..., includeQualified)`)
and off for the rewriters. Renaming `T` has to splice the last segment of
`Mod.T` and must first prove the path resolves to THIS `T`; `CrossRename`
owns that arithmetic (`RefactorSupport.qualifiedPaths` /
`lastSegmentOffset`) and reads the walker for its plain-name arm only.

Implementation note: the default parse tree (consumed by
`ast`/`search`/`refs`/`meta`) drops type-position nodes from its
CHILDREN to stay lean; `uses` runs on a separate projection
(`GrammarPlugin.parseFileTypeRefs`), so adding it leaves the other four
commands byte-identical by construction.

#### The `type` slot — a binding's declared type in the DEFAULT tree

What a binding is DECLARED as is a different question from what types a
file references, and it is answered in the default tree, on the binding
itself. `QueryNode.type` is a slot beside `name`, not a child: a
declaration's children are its initializer and its comma-continuations,
and the rules read them positionally, so an annotation among them would
move every one of those indices — but only where the source happened to
be annotated.

The slot is filled for every BINDING: local `var` / `final`, class and
static members, anon-struct `var` / `final` fields, the bindings after a
comma in `var a, b`, function and lambda parameters, and a `catch`
binding. Its subtree is the type's own shape — kind = the grammar's type
constructor, name = the nominal head, children = the type ARGUMENTS:

```
$ apq probe 'class C { function f() { final xs:Array<CodePoint> = mk(); } }'
(module
  (ClassDecl
    C
    (FnMember
      f
      (BlockBody (FinalStmt xs (: (Named Array (Named CodePoint))) (Call (IdentExpr mk)))))))
```

`(: …)` is how the S-expr renderer prints the slot — between the name
and the children, with a `:` head so it does not read as one of them. In
`--json` it is the node's own `type` key, again beside `children`.

A rule asks the tree instead of the text: `prefer-for-in` derives its
loop binder from `decl.type` (head in `Array` / `Iterator` / `Iterable`,
element = `type.children[0]`) where it used to match a regular
expression against the declaration's source slice.

A KIND could not have carried this. In Haxe `Arrow` is both
`HxType.Arrow` (`Int->Void`, an annotation) and `HxExpr.Arrow`
(`k => v`, an initializer), so "which child is the type" has no
kind-level answer — the same reason `name` is a slot.

The `--type-refs` projection is unaffected: it keeps its flat `TypeRef`
run and fills no slot, so `uses` / `blast` / `mentions` and the
rewriting ops see exactly the tree they always saw.

#### `apq ast --type-refs` — dump that projection

`uses` answers "where is type `T` used"; it cannot answer "what types
does this file reference at all". `--type-refs` renders the
`parseFileTypeRefs` tree itself, through the very same S-expr / JSON
path a plain `ast` uses — so `--select`, `--at`, `--depth`,
`--children-limit`, `--count`, `--spans` and `--json` all compose with
it unchanged. (`--writer-output` does not: the type-ref projection is
not a writable tree, and the combination exits `EXIT_USAGE`.)

```
apq ast <file> --type-refs                      # whole type-ref tree
apq ast <file> --type-refs --select TypeRef     # just the nominal references
apq ast <file> --type-refs --json               # same tree, JSON form
apq probe '<code>' --type-refs                  # inline probe
```

```
$ apq probe 'class C { var a: Int; final b: Map<String, Foo>; }' --type-refs
(module
  (ClassDecl
    C
    (VarMember a (TypeRef Int))
    (FinalMember b (TypeRef Map) (TypeRef String) (TypeRef Foo))))
```

Note the shape: a parameterized type flattens into **sibling**
`TypeRef` nodes (`Map`, `String`, `Foo`), matching what `uses` reports.

**The dump is deliberately RAW — it shows the projection as it is
today, gaps included.** It is not a curated view of "the types this
file references", and a missing node here means `uses` and `blast` are
blind to that position too.

**Anonymous structures are covered.** The field *types* of an anon
structure project wherever the structure itself can appear — as the
annotation (`var v:{f:Doc}`), inside a type parameter
(`Array<{f:Doc}>`, `Map<String,{f:Doc}>`, `Null<{f:Doc}>`), as an arrow
operand (`{f:Doc} -> Void`) or arrow-function parameter
(`(q:{f:Doc}) -> Void`), behind `(` `)` or the `?` optional-arg marker,
and on a typedef right-hand side —

```
$ apq probe 'class C { function f(?d: Array<{ node: Doc }>): Void {} }' --type-refs
(module
  (ClassDecl C (FnMember f (Optional d (TypeRef Array) (TypeRef Doc)) (Named Void) (BlockBody))))
```

Field **names** never project as *type references*: `apq uses node` on
that source is 0 hits. (The raw dump still shows a field name as a
node's own name — `var v:{node:Doc}` renders
`(Anon (Required node (TypeRef Doc)))` — but that node's kind is not one
of `TypeRefShape.typeRefKinds`, so no consumer reads it as a type.) A
name that *did* project as a type reference would be read as one by
every consumer — `Naming` discounts these spans from its completeness
gate and `CrossRename` rewrites at each of them, so a leak would
silently orphan a value reference or rename a field label. Nesting does
not duplicate either: an anon inside an anon reports each type once.

Residual gap: the **head** of a structural extension —
`typedef Ext = { > Base, var x:Doc; }` — does not project `Base`, because
`ExtendsField(type:HxTypeRef)` is not a nominal-name constructor. Only
the head is missing: `{ > Base<Doc>, … }` still projects `Doc`
(`(ExtendsField Base (TypeRef Doc))`), and every field type in the same
body projects normally.

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

### `apq lit`

`apq lit <text> <file-or-dir-or-glob>...` — string-literal / leaf-name probe:
every captured leaf whose `name` slot matches `<text>` (substring by default,
`--exact` for full equality).

**The default `--kind` is the grammar's string-content vocabulary, in EVERY quote
spelling it has.** One string value can be spelled several ways and the spellings
do not project alike: Haxe's single-quoted literal is a composite whose text lives
in `stringInterpTextKind` child segments, while the double-quoted one is a single
raw terminal whose own `name` slot is the source slice WITH its quotes. So the
default set is `stringInterpTextKind` plus every `stringLiteralKinds` entry that is
not itself an `interpolatingStringKinds` one (a segmented literal's own name slot
is empty, so listing it could only mislead), and the declared quotes
(`stringLiteralDelimiters`) come off before the compare — a WIDENING, so a query
that spells the quotes itself still matches. `apq mentions`' third section reads
the same delimiters, which is what lets its exact match reach a dotted path written
in either spelling.

Until S188 the default named ONE kind, and the failure was silent rather than
merely narrow: over a directory holding `'needle'` and `"needle"`, `apq lit needle`
printed the single-quoted hit and said nothing at all about the other — the 0-hit
auto-widen retry fires only when NOTHING matched — while `--exact` could never
reach the quoted spelling. The 0-hit nudge made it worse by suggesting a widening
(`--kind Literal,IdentExpr`) that could not have found the missing hit either.

**An explicit `--kind` is honoured and ANNOUNCED.** Naming only part of that
vocabulary is a legitimate narrowing, so it still narrows — but a stderr note says
which spelling is no longer searched and what the full set is, hit or no hit,
because nothing in the output would otherwise say that a spelling is missing:

```
apq lit: NOTE --kind Literal covers 1 of this grammar's 2 string-literal content kind(s)
  — content written as DoubleStringExpr is NOT searched. Add it, or pass
  --kind Literal,DoubleStringExpr / --any-kind.
```

**Smart default:** a camelCase / snake_case `<text>` is unambiguously an identifier
query, so the default also takes `identKind`. A pure-lowercase or all-uppercase
single word stays content-only — it matches string content ambiguously and the
identifier widening would flood prose hits. `--any-kind` matches every named leaf
and also scans comments; `--include-comments` / `--include-directives` add those
scans alongside the AST walk (see the `Comment` / `Directive` synthetic kinds).

Escapes are decoded on NEITHER side: this is about the quotes, not the escaping,
and a grammar's segmented spelling carries its escapes raw too — a consumer that
wants the runtime value decodes it itself.

### `apq cond`

`apq cond <DEFINE> <file-or-dir-or-glob>...` — for every conditional-compilation
region whose own `#if` / `#elseif` conditions mention `<DEFINE>` as a standalone
identifier, print one head line per branch (its position, its verbatim directive,
its tags) with that branch's own source indented under it.

```
apq cond FEATURE_X src                      # bodies of every branch of every matching region
apq cond FEATURE_X src --active --names     # only what can run with the flag, as symbol names
apq cond FEATURE_X src --inactive           # only the branches that cannot run with it
```

**A branch is not a node — it is delimited by its DIRECTIVES.** A whole
`#if A … #elseif B … #else … #end` region projects as ONE node whose span covers
every branch, with all the branches' constructs flattened into a single sibling
list: nothing in the tree marks a boundary, so no selector addresses a branch and
no node span can be sliced into one. `cond` takes a branch's body to be the byte
run `[end of its own directive, start of the next directive at the same nesting
depth)`, replayed from `CondDirectives.scan` through a depth stack. Three things
follow, and they are the contract:

- **Nest-safe by construction.** An inner region's directives are consumed while
  its own frame is on top of the stack, so an outer branch simply runs across the
  whole inner region. A region that itself mentions the define is reported as its
  own entry too, tagged `nested`; its text therefore appears twice, once inside
  its parent's body.
- **Parse-free.** The scan is lexical, so an unparseable file is walked rather
  than skipped, and — more importantly — so are the shapes where the grammar
  parses but projects nothing. An expression-position `#if`
  (`return #if nodejs a; #else b; #end`) is a single childless `CondSplice*` node;
  such a branch is tagged `raw span` and printed verbatim, never silently skipped.
- **A body never carries a directive**, so it starts and stops where the branch
  does. That is the whole point: the route this replaces is
  `lit --include-directives` for the `#if` line plus one `source --range` per site
  over a window whose end is a guess. Measured for the define `nodejs` over
  `src/anyparse/query`: 87 regions → 88 commands and 57 497 bytes of stdout, with
  25 of the 87 guessed windows never reaching their own `#end`. `apq cond nodejs
  src/anyparse/query` is one command and 40 750 bytes (27 807 with `--names`).

**Matching is by CONDITION, not by directive text.** `#if (sys || nodejs)` is a
site of both flags and answers a query for either — where `lit '#if nodejs'` sees
neither. In the scope above that is the difference between 12 sites and 87.

**Tags** on each head line:

| Tag | Meaning |
|---|---|
| `[live]` | taken whenever `<DEFINE>` is set |
| `[dead]` | never taken when `<DEFINE>` is set |
| `[maybe]` | a flag outside the query decides |
| `[raw span]` | the body holds text no node covers — printed verbatim; `--names` has nothing to answer with, so it keeps the source |
| `[no parse]` | the FILE has no tree, so every non-blank branch of it is unmodelled for THAT reason and not for want of a node — printed verbatim like `[raw span]`. In a multi-file walk nothing else says so: a parse failure is reported only for a single file |
| `[nested]` | the region sits inside another one |

Liveness is `CondRegionLiveness.branchStep` folded over the region's directives
under the hypothesis that `<DEFINE>` is set and every other flag is unknown — the
same step the `oracle`-coverage question uses, so the two cannot disagree about
which branch a define selects. It is three-valued because a positive-only define
set cannot prove a flag absent: an `#elseif <DEFINE>` after an `#if other` is
`maybe`, not `live`, since nothing refuted `other`.

**Options.** `--active` keeps every branch that is not `[dead]`, `--inactive`
exactly the `[dead]` ones, and the two partition a region's branches (neither flag,
or both, keeps everything). `--names` prints the distinct `<Kind> <name>` rows of
the branch instead of its source — the "what does this flag reach" answer without
paying for the bodies. `--max-body N` bounds each body (default 20, `0` for no cap)
and names what it dropped; `--limit` counts REGIONS (so a region is never
half-printed) and cannot bound a define used as a whole-file guard — `--max-body` is the flag that does. `--flat` prefixes
each head line with the file instead of printing a group header.

**What `--names` counts as a symbol, and why a metadata NAME is one.** A row is
emitted for every node inside the branch whose `name` slot is symbol-shaped: an
identifier, a dotted path of them (a guarded `import js.node.ChildProcess` is one
row, and the most useful one such a block produces), or — since S188 — a metadata
name written with one of the grammar's own sigils, printed WITH the sigil
(`MetaCall @:build`). The kind column already separated the two, so keeping the
sigil costs a reader nothing and tells a script which it has.

The argument for including it is not a claim about what `@:meta` *is*; it is an
asymmetry INSIDE one construct. Metadata ARGUMENTS were always counted — they are
ordinary children of the annotation node — so `@:access(pkg.Other)` under a `#if`
reported `IdentExpr pkg` and `FieldAccess Other` while the annotation deciding
what those two mean reported nothing, and `@:native('nativeSpelling')` reported
nothing at all. A census of what a flag reaches that counts a build macro's
argument and hides the build macro is not a census.

Two things this does NOT change. A metadata argument that is a string LITERAL
stays out: `--names` answers symbol names, not literal content, and that drop is
the same kind filter described below — which is why such an annotation used to
contribute nothing whatsoever, its name dropped by shape and its argument by kind.
And a grammar that declares no sigil (`RefShape.metadataNamePrefixes`) keeps every
metadata name out, exactly as before the field existed.

**A literal's CONTENT is never a row, in either quote spelling.** That is asked by
KIND, not of the text — `'probe.hx'` IS a dotted pair of identifiers — so the
`stringInterpTextKind` fragment and every `stringLiteralKinds` entry contribute no
row while their CHILDREN still do: a `$name` shorthand and a `${ … }` hole are real
references the branch really does touch. `apq lit` reads the same two fields with
the opposite polarity (see below), so the two commands cannot disagree about which
kinds carry content.

### `apq resolve-define`

`apq resolve-define <DEFINE> <file-or-dir-or-glob>...` — the WRITE-TWIN of `apq cond`,
the same relation `comment-rewrite` has to `lit`. Every conditional-compilation region
whose own `#if` / `#elseif` conditions mention `<DEFINE>` and whose branches are ALL
decided is replaced, from its `#if` marker to the end of its `#end`, by the body of its
one live branch — or deleted when no branch is live.

```
apq resolve-define FEATURE_X src --list          # which files would change
apq resolve-define FEATURE_X src/A.hx            # the rewritten file on stdout (preview)
apq resolve-define FEATURE_X src --write         # apply
apq resolve-define FEATURE_Y src --undefined -w  # retire a flag that is never SET
```

Retiring a define is a one-time procedure, not a standing policy, which is why this is
an op and not a lint rule — and why no `--fix` covers these shapes: the `if-false` check
matches only a literal `#if true` / `#if false`, and withholds its fix when the
eliminated branch is non-trivial.

**DECIDED vs UNDECIDED.** A branch is decided when it is provably taken or provably not;
a region is decided when every one of its branches is — the same three-valued answer
`cond` prints as `[live]` / `[dead]` / `[maybe]`, folded by the same
`CondRegionLiveness.branchStep`, so the two commands cannot disagree about which branch a
define selects. A region carrying a `[maybe]` branch — a flag outside the query decides,
as in `#if (mobile && X)` or an `#elseif X` after an unrefuted `#if other` — is **left as
is** and reported on stderr by position:

```
src/popups/Foo.hx:91:3: #if (mobile && X) - left as is: a flag outside the query decides
```

**Conditions are never SIMPLIFIED.** `(mobile && X)` does not become `mobile`. That is a
rewrite of the condition TEXT, a separate job with separate failure modes, and mixing it
in would make a refusal indistinguishable from a partial edit.

**`--undefined` is the negative hypothesis** — the define is asserted ABSENT rather than
set, which is what a never-defined flag needs. It is an assertion the operator signs for:
no compile output can prove a flag undefined (the compiler prints its `Defines:` line
before init macros run), so `CondRegionLiveness.evaluate` stays positive-only and only
the explicit `evaluateFacts` entry point can read a name as false.

**Nesting.** A decided region inside a decided one is folded into its parent's
replacement in the same pass and counted separately in the summary. A decided region
inside an **undecided** one is folded on its own and the parent stays — the parent
contributes no edit, so nothing collides.

**Whole-line deletion.** A region whose `#if` starts its line and whose `#end` ends one
takes those lines with it when nothing is live, so no blank line is left behind. A region
sharing its lines with code keeps the narrow span, and the replacement is re-indented by
the writer like any other emitted code — which is what folds the mid-expression shape
`x = #if X c ? new A() : #end new B();` into `x = c ? new A() : new B();`.

**What is refused** is the shared write gate's list, because the whole result goes through
`CanonicalEdit.canonicalize` and never through a bare splice:

| Refusal | Why |
|---|---|
| a region that was the whole body slot of a brace-less `if` | folding it to nothing leaves the `if` to swallow the FOLLOWING statement; the result parses, so only `BodySlotGuard` can see it |
| `file is not in canonical form` | a whole-file rewrite would reflow unrelated hand-wrapping into a surprise diff — run `apq fmt --write`, or pass `--reformat` |
| a source the grammar cannot parse | the deliberate difference from `cond`, which walks an unparseable file happily: reading a region needs no tree, writing one needs a re-parse |

Each is a per-file failure — the walk continues, the file is left byte-identical, and the
run exits non-zero.

**Multi-file UX is `comment-rewrite`'s**: one file with no flag previews the rewritten
source on stdout (diagnostics on stderr, so a preview redirects and diffs cleanly), a
directory or glob lists the paths that would change, `--write` rewrites in place. A walk
that matched nothing says so rather than reporting `0 region(s)`.

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

### An argv mistake is not a bug, and no longer exits like one (T787)

Three argument faults used to leave the CLI through the same path an internal
error takes — a bare `throw` from `CliArgs` that nothing caught, so
`apq cond f.hx --max-body` printed a Node stack trace and exited 1:

- a flag given no value (`--max-body`, `--lang`, … at the end of argv);
- a `--limit` that is not a non-negative integer;
- a `--lang` naming no registered grammar plugin.

They now raise `UsageFailure` (its own type beside `WriteFailure`, for the
same reason that one has one) and `Cli.run` catches it: one sentence on
stderr, named with the subcommand, and `EXIT_USAGE`. Everything else — a
plain `String`/`Dynamic` throw, a real exception — still reaches `main` as a
raw stack, which is what an internal bug wants. Adding a new flag that reads
a value through `CliArgs.expectValue` inherits this; a hand-rolled `throw` in
a command module does not.

### An unknown subcommand answers with names, not with the help page (S197)

`apq <not-a-command>` used to print the whole `--help` listing — measured **5440
bytes** on `apq members Foo`, ~1360 tokens — at a reader who mistyped one word.
It now prints two lines: the miss with the nearest real names, and where the
full list is. Same command, **169 bytes**:

```
apq: unknown subcommand "members" — did you mean: add-member, move-member, remove-member?
apq: run `apq --help` for all 71 commands, or `apq <command> --help` for one
```

The ranking is `CliWalk.findFuzzy`, the same two-tier matcher (contiguous
substring, then Levenshtein within 3) the walkers' own "did you mean" uses, so
a near-miss cannot come to mean two different things at two entry points.
`CliRegistry.nearest` adds exactly one thing to it: a **plural probe**. The
command vocabulary is singular (`add-member`, `move-member`, `remove-member`)
while the miss a reader actually makes is `members` — five edits from the
nearest of them and a substring of none, so the shared matcher answers nothing.
Dropping a trailing `s` and asking again is what turns that miss into the right
answer. Nothing close enough ⇒ no `did you mean` clause at all, rather than a
fabricated one.

### `apq lint --baseline <path>`: report the delta, not the standing findings (S197)

A `PostToolUse` nudge behind a write op has to answer *"did THIS edit introduce a
finding"*, and it only has the file AFTER the edit. `--baseline <path>` gives it
the other half:

- with a readable snapshot at `<path>` (a previous `--format json` report), the
  run reports **only** the findings that snapshot does not already carry;
- either way it then **rewrites `<path>` with every finding of this run**, so the
  next invocation compares against the current state.

The comparison is `lint-diff`'s: a MULTISET over `(file, rule, severity,
message)` with that module's path and measurement normalizations. That is the
whole reason it is not a text diff in the hook — `line` and `col` are not part
of the key, so an edit that inserts a line above a finding does not manufacture
a delta. Measured: two lines inserted above a finding ⇒ `0 new of 1 finding(s)`.

It narrows the report, the severity summary and `--fail-on` alike, so a caller
can gate on "my edit introduced something" without the exit code and the printed
lines disagreeing. A missing or unreadable snapshot reports everything and says
which it was — silence would read as "your edit introduced nothing". It is
REFUSED with `--fix`: `--baseline` narrows what the run reports, `--fix` acts on
what it finds, and a fixer handed a thinned set would claim a converged run.
`--range` is the flag that narrows both.

### `apq lint --verbose`: what a quiet `--fix` run stops saying (S197)

Two blocks are statements about what a `--fix` run WROTE, and `--fix` behind a
write op is scoped to the lines one edit touched, so it lands zero edits most
times it is asked:

- the per-rule unfixed ledger + never-asked list + `rule census`, now printed
  only when the run produced an edit (or under `--verbose`);
- `compiler oracle SKIPPED (--no-oracle) …`, now printed only under `--verbose`
  — it narrates back a flag the reader passed (a write op's `--fix` passes it
  for them), and the run's own summary line already carries both consequences it
  states. The OTHER netless arm, `no compilerOracle configured …`, still speaks
  always: it reports something the reader may not know and names a remedy they
  have not taken.

Measured on one `hxq lint <one file> --fix --no-oracle` with no edit to make:
**1819 → 206 bytes** of stderr, the 206 being the summary line that carries the
verdict. `--verbose` restores 1407.

### The cost of a ROUND: batched queries, the TTY progress gate, and the whole-file read guard

Three properties of the read-only commands that are about the price a CALLER
pays per invocation rather than about what the walk finds. All three were
user-reported on 2026-09-07 from one real session, and all three carry a
measured before/after on this tree (935 `.hx` under `src`).

**Progress is printed only to a TERMINAL.** `CliIo.streamProgress` writes
`apq <cmd>: scanned N/M files…` every 25 files plus once at completion. That is
38 stderr lines / 1289 bytes per `src`-wide walk — measured for `lit`, `refs`
and `mentions` alike — and `2>/dev/null` is not an available answer, because the
same stream carries the `--limit` cap line, the `refs` member-access warning and,
for every mutation op, the ONLY channel a refusal has. So the heartbeat now asks
whether stderr is a terminal: a human watching a run still gets it, a pipe gets
nothing — and a watchdog reading a redirected stream, which is the other caller
the heartbeat was written for, asks for it back with `HXQ_PROGRESS=1`.
`HXQ_PROGRESS=0` and the older `HXQ_NO_PROGRESS` force it off. Under `HXQ_PROGRESS=1` the stderr is
byte-identical to what the pre-gate binary printed by default.

**A bare `--` separates SEVERAL queries from the scope.** `refs`, `mentions`,
`lit` and `declares` take a list:

```
apq refs alphaOne betaTwo -- src --decls     # two names, ONE walk
apq lit 'todo' 'fixme' -- src test           # two texts, ONE parse per file
apq declares Alpha Beta -- src               # one symbol listing, two answers
apq source F.hx --select 'FnMember:a' --select 'FnMember:b'
```

Each query prints under its own `=== <query> ===` banner on stdout, in the order
given (`source --select` orders by document position instead, since it prints
source), and each gets its own `--limit` budget, its own 0-hit nudge and — for
`lit` — its own smart `--kind` default. ONE query prints exactly what it printed
before the separator existed: no banner, no reordering, byte for byte, which is
what the skill, the hooks and every existing fixture depend on. `refs --json`
takes ONE name, because two concatenated JSON documents are not JSON.

Why a separator and not "the last positional is the scope": the second positional
IS a scope spec today and SEVERAL of them are legal (`apq refs X src test`), so a
last-positional rule would silently reinterpret an existing call. A bare `--`
appears in no invocation that works today, so it costs nothing. `--name A --name B`
was the other candidate and doubles the typing at exactly the call the feature
exists for. The shape the separator disambiguates used to be SILENT: `apq refs A
B C src` walked `src` alone, dropped `B` and `C` without a word and exited 0; it
now names the dropped positionals and the `--` form on stderr.

What a batch buys is ROUNDS, not CPU. The walkers pre-filter by raw substring, so
a name costs ~0.23 s whether it is alone or not; three separate
`refs <name> src --decls` calls cost 5108 bytes over 3 rounds, the batched call
1191 bytes over 1.

**A long whole-file read is refused, with the selector menu instead.**
`apq source <file>` with no `--range` / `--select` / `--at` printed the file
whole, which is `cat`, and that is what a caller reaches for. Measured over one
session: 7 files, 1270 lines dumped, ~100 used (≈8%), two files needed nothing.
The reason is not discipline — `--select` needs a member NAME, and on first
contact the only way to learn one was to dump the file — so past a line budget
the command answers the NAMES instead of the bytes:

```
apq source: <file> is 3101 lines and nothing narrowed the read (budget 120 lines, HXQ_SOURCE_MAX_LINES; 0 disables).
Narrow it — `apq source <file> --select '<sel>'` (repeatable):
  InterfaceDecl:GrammarPlugin   lines 19-306
  TypedefDecl:MetaShape   lines 3016-3020
  …
Or read a line window with `--range L:L2`. `--all` prints the whole file.
```

Exit is `EXIT_USAGE`; `--all` prints the file whole; `HXQ_SOURCE_MAX_LINES` moves
the budget and `0` switches the refusal off. On this tree the three largest `src`
files cost 617 585 bytes of stdout whole against 6 994 bytes for the three
refusals. The budget counts LINES, not Haxe: a long `.md`, `.json` or log read
through `source` is refused the same way and answers the no-menu form, so a habit
of reading one whole needs `--all`.

Two properties of the menu are deliberate. Each entry's selector is
`Address.describe`'s canonical, EDIT-STABLE address, and its line range is the
window `--select` will actually print (`CliEdit.sourceWindows`), so an entry
states what following it costs — which also exposes a greedy module-level span
as a thousand-line entry rather than hiding it — an entry whose own window is
past the budget says so, so nobody follows a "narrowing" that narrows nothing.
And "top-level" is counted in
NAMED ANCESTORS with one-line nodes dropped, never in grammar kind names: that
keeps the package line, the imports and the typedef fields out of the menu on
Haxe and still works on a grammar this code has never seen. A file that does not
parse has no menu, so its refusal names `--range` and `--all` and nothing else.

### Parse-failure locus

When the parser cannot parse a file it reports the **farthest input
position any terminal reached** (PEG max-position heuristic), not the
position where the outermost rule bailed. Without this, recursive-descent
backtracking collapses every failure to the file head (`expected <root>`);
with it, the reported span points at the innermost blocking token, which
is what diagnostics and recon tooling need.

### `apq probe`: the staged scratch slot resolves per PROCESS (T700)

`apq probe '<code>'` persists the bytes it was handed so the next command can
target the same source without re-heredoc-ing it, and prints the path on
stderr:

```
apq probe: staged source -> /var/folders/…/T/anyparse-last-probe.19905.hx (use it with `apq strip …` or `apq recon --probe …`).
```

**Read that path out of the nudge — never spell one yourself.** It is resolved,
in this order:

1. `$APQ_PROBE_PATH`, when set and non-empty — the slot outright.
2. otherwise `<temp root>/anyparse-last-probe.<pid>.hx`, where the temp root is
   the OS one — on the node runner literally `os.tmpdir()`, so `$TMPDIR` when
   the caller set one.

Both halves are load-bearing, measured. The temp root answers the caller's own
isolation, so a process that claimed a private root — the suite does, via
`CliFixture.isolateTempDir` — stages inside it and has the slot reaped with it.
The pid is what separates two CONCURRENT probes: on macOS every process of one
user inherits the same `/var/folders/…/T`, so a temp root alone separates
nothing between two agents on one machine.

Until this landed the slot was the fixed constant `/tmp/anyparse-last-probe.hx`.
Two workers then shared one file and the failure was silent: worker A staged,
worker B staged a second later, and A's `strip` / `recon --probe` parsed B's
source — exit 0, no exception, a plausible WRONG answer, which is the worst
shape a measurement harness can be handed. Measured on 12 interleaved rounds
each: A read foreign bytes 4 times of 12 and B 8 of 12, and one read came back
`class A1 { var a:Int; }}` — A's 23 bytes carrying a residual `}` of B's
24-byte content, a source neither process ever wrote (two truncating opens
interleaved). The same probe after the fix reads 0 of 12 in both directions and
12 of 12 byte-exact.

`$APQ_PROBE_PATH` is an escape hatch, not an isolation mechanism: two workers
exporting the SAME value re-create this defect exactly. Give each one its own
value, or leave it unset and let the pid do the work.

Nothing reaps the slot. `tools/tmp-lifecycle.sh` sweeps claimed
`<prefix>.XXXXXX` DIRECTORIES, and this is a bare file, so a slot survives its
process. Inside the suite that costs nothing — the run's private
`apq-suite.XXXXXX` root is the temp root, and the slot goes with it — but
interactive use leaves one small file per `probe` invocation in `$TMPDIR`,
where the old design left exactly one per machine. Measured on a session that
ran ~40 probes: 3 files, 12 KB, the rest having landed inside reaped roots.

Single-slot is unchanged where it was ever meant: WITHIN one process a chained
`recon --probe` still targets the LAST probe, not a history — the second probe
of a process overwrites the first one's slot.

Staging never fails a probe. A write error (read-only temp root, disk full,
permission) skips the nudge and the probe still answers. So does a REFUSAL: a
target that exists and is not a regular file is not written through, because
`File.saveContent` FOLLOWS a symlink and a slot in a shared directory would
otherwise be a write-anywhere primitive with this process's rights. That
refusal is the NODE runner's (`lstat`); the `sys` fallback has no portable
`lstat` and catches a directory only — no build in this repo compiles it, and
`ProbeCommand.isStageTargetSafe` says so at the branch. A HARD link is outside
either check by construction: it *is* the regular file.

```
apq probe: not staged — "…/planted.hx" exists and is not a regular file (symlink, directory or device); set APQ_PROBE_PATH to stage somewhere else.
```

### `apq test-summary` has no path default, and `apq stdlib-dup` stages per PROCESS (T810 / T811)

Two more commands carried the defect the section above closed for `apq probe`,
and neither had a symptom: both processes exit 0 and both answers look right.

**`apq test-summary` used to read `/tmp/test.out` when given no positional
source.** It now reads `$APQ_TEST_OUT`, and a run with neither is a USAGE error
naming the env var. A per-process path could not have fixed this and none is
offered: the transcript is written by a DIFFERENT process (`node bin/test.js >
…`), so nothing this one knows about itself can name the file it is meant to
read. Measured on the pre-fix binary — two workers each writing their own suite
log to that constant and each summarising it, 12 interleaved rounds — one read a
transcript it had not written 7 times and the other 6, every one at exit 0 with
plausible counts; in one round BOTH read a TORN interleave (`6 tests / 5
assertions`) that neither had written. Nothing in the repo relied on the
default: `tools/suite-shard.sh` always passes a path, and so does every recipe in
`CLAUDE.md`.

**`apq stdlib-dup` used to stage its generated probe into
`<temp root>/apq-stdlib-dup/Probe.hx`** — one directory and one fixed module name
for the whole machine — and then spawn `haxe -cp <dir> --run Probe`. The write
and the spawn are two steps, so two runs sharing that directory race, and the
loser compiles the OTHER run's program. The verdict that comes back is not a
crash; it is a fully-formed differential finding about the wrong function.
Measured: two one-candidate scopes driven concurrently, 12 rounds, the two
processes reported IDENTICAL findings in EVERY round — 7 of 12 wrong for one and
5 of 12 for the other, one of them reading

```
AlphaBegins.hx:3:16: info: AlphaBegins.beginsWith looks like StringTools.endsWith(s, p) — agreed on 484 generated inputs, 6 mapping(s) tried [stdlib-dup]
```

for a function that begins-with. The work directory is
`<temp root>/apq-stdlib-dup.<pid>` now and the run ANNOUNCES it, because the
generated probe is the only artifact a reader can go inspect when a verdict
surprises them and a per-process path is not something the docs can spell:

```
apq stdlib-dup: staging probes in /var/folders/…/T/apq-stdlib-dup.19905
```

`--work <dir>` still names it outright; a caller passing one owns the same rule.

**Where the temp root comes from.** `anyparse.core.TempScratch` is the single
answer to "where may this process write scratch, and what keeps it apart from
another process's". Five copies had drifted before it — `OracleCache.tempDir`,
`CompilerServer.stateFile`, `ProbeCommand.probeTempRoot`,
`StdlibDupCommand.stdlibDupWorkDir` and the suite's `CliFixture.tempDir` — over
`?? '/tmp'` versus a `length > 0` guard, `TMPDIR` alone versus
`TMPDIR`-then-`TEMP`, and whether the trailing slash macOS exports gets trimmed.
`TempScratch.root()` stays a FUNCTION on purpose (`TMPDIR` is mutated at
runtime, which is how the suite's private root reaches every producer), while
the process token is resolved once, which is what makes a slot single per
process rather than per call.

## Mutation commands (source rewriting)

Distinct from the read-only query commands above: these **rewrite** source. Without `--write` the rewrite goes to stdout; with `--write` it overwrites the file in place. Cursor positions are 1-based `line:col` — the same convention `apq refs` prints (and `ast --at` / `source`). Two sub-families differ in how they format the result:

- **Refactoring ops** — scope-correct edits driven by the `refs` / `Scope` binding resolver, **format-preserving** (span-splice — everything outside the edit is byte-verbatim) and re-parse-validated: `rename` (`--scope <dir>` for cross-file type rename), `inline`, `extract-var`, `change-sig`, `move`, `add-param`, `remove-param`. These move EXISTING tokens, so no new code is formatted.

- **Structural insert / replace ops** — these introduce NEW code, so they are **writer-emitted**, not spliced as-is: the raw new text is placed, then the WHOLE file is re-emitted through the writer (the trivia/comment-preserving pipeline), which formats the inserted code by the grammar's own rules and re-parse-validates in one step (an unparseable result is rejected). Because a whole-file rewrite would also reflow any unrelated hand-wrapping, the file must already be **writer-canonical** (`write(parse(f)) == f`); a non-canonical file is refused unless `--reformat` is passed (which opts into canonicalising the whole file — the gofmt workflow). Requires a grammar with a writer.

| Command | Purpose |
|---|---|
| `apq add-member <file> --type <T> '<memberText>' [--reformat]` | Append `<memberText>` to the body of type `<T>` (writer-formatted); append-only — ordering is the formatting layer's job |
| `apq add-import <file> <module.path> [--using] [--reformat]` | Add an `import` (or `using`) after the last import / using, else after `package`, else at file top; a same-kind duplicate is refused |
| `apq replace-node <file> (--select <sel> \| --at <l>:<c>) '<newSource>' [--reformat]` | Replace one node's source span (writer-formatted); `--select` reuses the `ast` selector (must match exactly one node), `--at` the innermost node at the cursor |

Run `apq <op> --help` for the full per-op flag reference and safety boundary. The hxq skill (`~/.claude/skills/hxq/SKILL.md`) carries the authoritative safety-boundary table for every mutation op.

### Choosing between `patch` and `replace-node`, and what NOT to type (S197)

`patch` matches its `old` fragment **verbatim** inside the resolved node —
byte-exact first, then dedent-tolerant — and refuses with `the old fragment
does not occur in the resolved <Kind> node` when it does not. That refusal is
the tool being correct, so the cost of `patch` is retyping the fragment
exactly, and it grows with the fragment.

The rule of thumb: **when the replacement covers more than about half the
node, address the node and pass only the new text** —
`replace-node --select '<Kind>:<name>'`. `patch` earns its keep on a few lines
inside a bigger body, where a whole-node replacement would make you retype
what you are not changing. Two boundary cases stay with `replace-node`
whatever the size: a macro-time local (`rename` cannot see a bare `$name`
reification splice), and any change to a leading modifier group — and there
`replace-node`'s span **includes** the modifiers, so spell them verbatim.

A leading `/** */` on a TYPE is trivia BEFORE that type's node, so no `patch`
address reaches it; use `comment-rewrite` for a sentence inside it or
`set-doc` for the whole block. A MEMBER's doc is inside the enclosing type's
node, so `patch --select 'ClassDecl:T'` does reach it.

**What you do not have to type: layout. What you do: types.** Every
writer-emit op re-emits the file through the writer, so the text you hand it
is canonicalised — measured on `add-member`: a body written with no leading
tabs and `xs: Array<String>): Int` came back tab-indented and spaced by the
project's own `hxformat.json`. Explicit types are the opposite: hxq does not
infer them for you (`explicit-type` / `explicit-local-type` are
OracleAssisted, so under a write op's `--fix` — which forces `--no-oracle` —
they are inert and report-only). So skip the indentation and write every
annotation.

### `--fix` on a write op: the lint pass, scoped to the lines the write changed

Eleven ops — `patch`, `replace-node`, `add-member`, `add-element`, `remove-element`, `remove-member`, `remove-import`, `add-meta`, `set-doc`, `set-comment`, `extract-method` — take `--fix` alongside `--write`. After the write lands and reports, the op lints the file it just wrote and applies the safe fixes. The op's own exit status is unaffected: the write already happened, so a lint that finds nothing, or refuses, must not turn a successful edit into a failure.

Three things about it are load-bearing, and each was measured rather than assumed.

**The scope is the lines the write CHANGED**, computed by trimming the common leading and trailing LINES between the file as it was and the text the op emitted, and printed (`apq: --fix over lines 9-10 of <file>`) so the reader can check it. Byte-level trimming was tried first and is wrong: it returns the minimal EDIT, which for an insertion is not line-aligned, so the window ran eight characters into the line *after* the insertion and `--fix` duly rewrote a standing finding there. Several changed regions still give their HULL — first differing line to last — which is wider than the truth; a multi-pair `patch` spanning a whole file narrows to almost nothing.

**Why a scope at all**, given that a whole-file `--fix` over this repository changes nothing on an untouched file (measured: 0 edits in 0 files across five real files, with and without the oracle — the tree is a fixer fixed point): because that property is this tree's, not the tool's. On a codebase with fixable debt standing, an unscoped `--fix` behind a one-line edit rewrites code nobody asked about.

**`--no-oracle` is hardcoded.** The compiler oracle is a project-wide build — 46.5s against 4.8s without it, measured on this tree — which no per-edit step can pay. The consequence is stated rather than hidden: with no oracle there is no revert net, so every `RiskyFix` and `OracleAssisted` rule stays report-only and only the SAFE half of the fixer can land behind someone's edit. `runLint` prints that it had no net.

The window is a `lint` feature, not an op feature: `apq lint <file> --range <from>:<to>` takes a 1-based inclusive line window over a scope of exactly one file, and narrows the report AND `--fix` alike. It selects FINDINGS, never EDITS — a check whose fix is atomic across sites (`unused-parameter` rewrites the signature and every call-site argument) still writes wherever its own fix says, off a finding inside the window; clipping that would leave the file broken. Under `--fix` the window is re-applied on every fixed-point pass against the file's current bytes, so a fix that changes the line count shifts what a later pass sees — bounded, and documented on `LintRange`.

### `comment-width`: the one width nothing measured

`apq lint --rule comment-width` reports a COMMENT line — a `//` run, a `/* … */` banner or a `/** … */` doc block — rendered wider than the project's own `wrapping.maxLineLength`. It is `DefaultOff` and `Info`: the threshold is a project's style choice, so a project opts in through `apqlint.json` (`"comment-width": { "enabled": true }`), and a rule that can report several hundred lines of standing prose must not flip a warning-gated build the day it is switched on.

The gap it closes is that the writer owns every CODE line's width and re-emits a comment interior BYTE FOR BYTE. An over-wide comment line therefore leaves `fmt --list` clean and no other rule reads a comment's shape: 468 lines of this repository stood past its configured 140, one of them at 6641 columns, and the only gate any of them had ever met was a human reading a diff.

**The comment has to be what puts the line over.** A line is measured whole (`CheckScan.displayColumn` — the writer's own answer to what a tab is worth), but a comment sharing its line with code that is ALREADY past the width is not this rule's finding: the comment could vanish and the line would still be too long, and the code's width is the formatter's concern. That single gate is the difference between 470 over-width comment lines in this tree and the 468 the rule reports — the two it drops are `// noqa` markers riding 160-column string-literal fixtures. The code is read on BOTH sides of the comment, which this tree cannot show: a short banner between a call head and a long argument leaves nothing to its left and everything to its right, so a left-only gate calls a 162-column line the comment's doing when deleting the comment leaves 154. The census is 468 either way here; the shape came out of a constructed probe.

**The fix** breaks the line back at spaces into the block it already lives in, carrying the prefix that position needs — `SourceComments.wrapCommentBody`, the same reflow `comment-rewrite` repairs its own edits with. Only the lines the findings NAME are wrapped, addressed by body-line INDEX (`wrapAt`) rather than by the content matching the repair caller uses: two identical over-width lines in one block would otherwise protect each other, and the line a finding named would come back unwrapped with nothing to say why. That is what keeps a whole-body edit answerable to the findings that asked for it. Measured: of the 468 standing at this slice's base, 418 are fixable and 50 decline; the dogfood run over the 465 left after the slice reflowed 3 in its own file wrote 387 edits in 210 files over two passes and then reached a fixed point at 0 edits. Those 418 were swept later, so it is exactly S164's 50 declines that stand on this tree today — the numeral means the DECLINING subset in that sentence and the whole standing census in the next one. Every gate on that copy: AST identity on all 210 changed files (`apq diff`), comment prose word-for-word identical on all 210, `fmt --list` 0 of 1780, and a `lint-diff` over every OTHER rule at 0 added / 0 removed (all 210 removed keys are this rule's own).

**The 30 of those 50 it still declines stand with the reason in the message** (and in `Violation.declineReason`, which `--fix`'s unfixed ledger reads), because wrapping is not always meaning-preserving and the shapes where it is not are corruptions nothing downstream can see:

| reason | count here | why |
|---|---|---|
| `indentation the author wrote` | 15 | a code sample or a hanging indent, laid out at the bare gutter |
| `a bullet` / `a table row` / a heading / a numbered item | 15 | `SourceComments.reflowRefusal`, the per-line predicate shared with the reflow itself |
| `a suppression directive` | 0 | `Suppression.parseNoqa` reads an empty rule list as EVERY rule, so a broken `// noqa: x` widens to a blanket exemption |
| `it is inside a fenced code block` | 0 | `reflowRefusal` is per-line and cannot see the triple-backtick fence that opened above it; tracked per comment unit instead |
| `it trails after code` | 0 | its continuation would be a NEW own-line comment the writer then relocates |
| a raw `#if` region / the file does not parse | 0 | nothing inside an opaque `CondRegionScan` region projects, so no edit there can be corroborated — fail-closed, as every mutating op is |

**A seventh row used to sit in that table and no longer does: `the block closer shares this line`, which carried 20 of those 50.** The body span of a `/* … */` stops two characters short of the `*/`, so the reflow measured a 141-column one-line doc block as 139 and declined it, and the rule reported the closer as the reason. `wrapCommentBody` now takes a `closerCols` and adds it to the LAST body line's measured width, taking the same columns off that line's wrap budget — zero for a `//` run or an unterminated block, so nothing without a closer moves. Measured on the base of the slice that did it, on a COPY — the tree itself was not swept: those same 50 became 20 fixable + 30 declining, `--fix` wrote 20 edits in 19 files over two passes, and the whole set was AST-identical (`apq diff` on all 19), prose word-for-word identical on all 19, `fmt --list` 0 of 1795, with a `lint-diff` of `0 added / 20 removed` whose per-rule line reads `comment-width 50->30 (+0 -20)` — every removed key this rule's own.

**The same blindness had a louder second victim, which is why the fix belongs in the reflow and not in the rule.** `comment-rewrite` runs the same reflow to repair the width its own edit broke, and then checks the result with a gate that measures the PHYSICAL line. Those two disagreed by exactly the closer: an edit leaving a one-line doc block at 141 or 142 columns was declined by the reflow and then REFUSED outright — `the replacement leaves a comment line at 141 columns, past the configured 140` — with nothing to do about it but `--allow-wide`. At 143 the same edit went through, because the body measure finally saw 141. Both now reflow. The A/B that sizes the change: one growing `comment-rewrite` over the 1778 files of `src` + `test` that both arms processed (of 1795), run under the base engine and under this one, wrote byte-IDENTICAL output on 1743 of them. The 35 that differ are the whole class — 34 the base engine refused outright, at exactly 141 (15 files) or 142 (19), plus one it wrote over-width. No file gained a refusal: the new arm's 15 remaining ones are a strict subset of the base arm's 49, and they sit at 141 to 1043 columns on lines `reflowRefusal` owns (the 141 is a bullet).

#### What the reflow does with the two shapes nothing had described

**A one-line PLAIN `/* … */` that an edit grows past the width wraps with NO gutter.** `commentContinuation` reads a block's continuation off its own first interior line, so a starred block keeps its star and a gutter-less one keeps only its indentation; a ONE-LINE block has no interior line to read, and the fallback follows the same rule — a `/**` opener means a guttered block, a plain `/*` means none. Inventing a ` * ` there would change the comment's KIND permanently, since the writer re-emits a comment interior byte for byte. The continuation it does emit is the block's own indent, and the reported "column 0" is the WRITER's canonical form rather than the reflow's choice: a gutter-less block's interior lines are re-indented under the opener (`\t/* a` + `\tb */` canonicalises to `\t\tb */`), and a block at column 0 has nothing to be indented under. The result is writer-canonical and lint-clean, so it stands as the answer.

**A DELETION does not own a paragraph separator, on either side of its match.** A blank comment line folds into the same single space an ordinary break does, so a literal find reads straight across one; that has been refused for a REPLACEMENT since the reflow shipped, but a deletion was exempt on the reading that it takes its own separator with it. It does not own this one: the blank line in front of a list's FIRST item is the lead's boundary with the list, and deleting ` - first bullet` off it glued the rest of the list onto the lead — silently, since the join lands inside the width. `interiorParagraphBreak` now governs both, with the same two ways out the message already named (narrow the find to one paragraph, or use `--regex`, which matches the raw body). Adjacency is still a deletion's to take: a find spelling the break AFTER its match (`- first bullet `) removes the item's whole line rather than leaving an empty gutter, and the separator above it stays.

### `apq rewrite`: a template is a TREE, so it is spliced as one

`apq rewrite <file> <pattern> <replacement>` matches with `search` syntax and splices
`<replacement>` over each matched span, expanding `$x` / `${x}` to the captured source.
The template is written in AST terms — `$A * 2` reads "the capture, times two" — but text
has no precedence, so a raw splice can hand back a different program: `$A * 2` over
`v + 1` used to emit `v + 1 * 2`, and `f($A)` -> `$A + 1` over `q * f(1)` used to emit
`q * 1 + 1`. Both re-parse, so nothing complained. Over the Haxe grammar, 400 of 1530
(capture shape x template context) pairs came out that way.

Every splice — each expanded metavariable, and the replacement as a whole against the
context the PATTERN matched inside — now keeps the parse it was written to have, with the
fewest parentheses that achieves it:

- A pair appears only where its absence is observable in the tree, so `$x * 2` over `v`
  stays `v * 2` and over `-1` stays `-1 * 2`.
- Nested splices share one pair where one is enough: `q * (v + 2 + 1)`, not
  `q * ((v + 2) + 1)`.
- A metavariable in a position that cannot take parentheses — a declaration NAME, a type
  annotation — is left alone, because the probe that would have wrapped it does not parse
  or does not change the shape.
- A raw splice that does not parse at all (`$A < 5` over `a is C` reads `C < 5` as a type
  parameter) is a rewrite that used to be refused and now succeeds parenthesised.

The mechanism is a differential parse, not a precedence table: a grammar declares
`parenKind` and `parenDelimiters` and gets the whole behaviour, and one that declares
neither keeps the raw splice.

### `apq fmt`: canonicalise source through the writer (T718)

```
apq fmt <file/dir/glob>... [--write] [--list] [--verify] [--one-pass] [--lang <name>]
```

Re-emits each file through the writer — the same whole-file pipeline the
writer-emitted mutation ops above use — formatted by the project's
`hxformat.json` discovered from the file's own directory. This is the
file-level counterpart of those ops and the measuring stick for the
canonical gate (`writeRoundTrip(s) == s`); unlike them it takes whole
files/directories/globs rather than a cursor or `--select`.

- No flags, one concrete file: the formatted source goes to stdout (gofmt's
  one-file default).
- No flags, multiple files or a directory: `--list` mode is implied — prints
  the paths whose output would differ (gofmt `-l`); nothing is rewritten.
- `--write` / `-w` — rewrite each file in place with its canonical form.
- `--list` / `-l` — force list mode explicitly. An EXPLICIT `--list` also
  turns off the `#if` region notes below (see there) — the machine mode a
  whole-tree gate spells, one line per drifted path.
- `--verify` — audit mode: the output must differ from the input by
  WHITESPACE only; every other divergence is reported and the file is never
  written. Catches what the writer round trip itself cannot — a writer
  defect whose output the parser still accepts is invisible to `--list`,
  self-status and lint alike, all of which can read green on a tree that no
  longer compiles. Some formatting policies change tokens on purpose (a
  trailing comma, braces around a single statement, an optional semicolon)
  and are reported too; read the diff rather than treating every hit as a
  bug.
- `--one-pass` — also require every file to reach its fixed point in ONE
  writer rewrite; exits non-zero otherwise. Composes with every mode above
  and changes none of them. Catches a class no other tree-level gate can
  see: `fmt` writes the writer's FIXED POINT, so a file the writer only
  settles on its second rewrite is reported canonical by `--list` while the
  next writer-emit op refuses it as non-canonical (that op's own gate is one
  round trip, not the fixed point). Off by default — a project whose config
  reaches the writer's convergence tail must still be able to run
  `--write`; on for a gate.
- `--lang <name>` — grammar plugin (default: `haxe`).

A file that fails to parse is reported and skipped; the run's exit code is
non-zero if any file failed. A file whose re-emission would DROP a comment
(an inline comment in a seam the parser has no capture slot for, e.g.
`if (/* c */ x)`) is reported with the comment and left byte-identical
rather than rewritten without it.

**The `#if` region note.** A conditional-compilation region whose bytes are
not a balanced subtree in their position (a `try {` whose `catch` closes in
another region, an `else` whose `if` is outside it, a dangling operator) is
captured raw by the parser, so the writer has no tree to format there and
re-emits it byte-for-byte while reformatting everything around it — a note,
not a failure; the rest of the file is formatted and written. Surveying a
directory needs no flag at all (`apq fmt <dir>` implies listing and keeps
the notes, as do `--write`, `--verify` and a single file to stdout); an
EXPLICIT `--list` is the one mode that turns them off, because the second
parse behind them costs one extra parse per file that has a `#if` (+19.9%
on a whole-tree `--list` gate, measured). Mechanism, the two-sentence split
between wholly-raw and head-only regions, and the measured region census
across this project / the Pony fork / the haxe-formatter corpus:
`docs/architecture.md` § "A `#if` region the parser captured raw".

## Pattern syntax for `search` (frozen for v1)

The pattern is parsed by the active grammar plugin **with a metavariable extension**: any identifier-shaped token starting with `$` is treated as a metavariable rather than a concrete identifier.

| Form              | Meaning                                                                    |
|-------------------|----------------------------------------------------------------------------|
| `$X`              | Bind one node. Reusing the same name must match the same subtree.          |
| `$_`              | Wildcard. Matches one node. Does not bind. Multiple `$_` in one pattern are independent — each matches any subtree without cross-constraint. |
| `...`             | Ellipsis. Matches a RUN of siblings, zero or more, in one child list. Does not bind. At most one per child list. |

The matcher walks the input AST and tries to unify each subtree with the pattern AST node-for-node, treating metavariables as holes.

Example concept:

```
apq search '$x = $x + 1' file.hx
```

matches every self-increment-by-1 in `file.hx` and binds `$x` to the actual variable expression at each site.

### The `...` ellipsis

Without it a pattern cannot say "any arity", because the matcher's child loop
gates on an exact length. "A `new` of ANY arity" therefore needed one pattern
per arity — measured over TM's `src/`, `new $T()` / `new $T($a)` /
`new $T($a, $b)` see 932 / 881 / 1104 sites and the tail up to arity 12 adds
1323 more, so a census written as the first pattern alone under-counts by 78 %.
`new $T(...)` is all 4240 in one, and the count is exactly the sum of the
per-arity counts.

```
apq search 'new $T(...)'   every construction, any arity
apq search 'f(...)'        every call to f
apq search '[...]'         every array literal
apq search 'g(1, ...)'     calls whose FIRST argument is 1
apq search 'g(..., 1)'     calls whose LAST argument is 1
apq search 'g(1, ..., 1)'  calls with 1 at both ends
```

**Anchored, not greedy.** The pattern children before the `...` anchor
left-to-right from the start of the input's child list; those after it anchor
right-to-left from the end; the star absorbs the (possibly empty) run between.
Both anchors must FIT — `g(1, ..., 1)` does not match `g(1)`, because one
argument cannot serve both ends. There is no backtracking and no ambiguity,
which is exactly what **one star per child list** buys; a second one in the same
list is refused with a message rather than guessed at.

**It does not bind.** A star absorbs a run of nodes, and a match binding is one
name to one node (`search --json`'s binding schema is frozen as
`{name, text, span}`). So nothing can reference what a star took, and
`apq rewrite` **refuses** a pattern containing one — its replacement template
would silently delete the absorbed children. The `--match` op locator does
accept a star: it only addresses a node, and the op that follows edits it under
its own semantics.

**A bare `...` is refused**, as is `...` in a name slot (`new ...()`). "Any one
node" is `$_`; "any node at all" is not a pattern.

**Constructor type arguments.** A `new T<K,V>(a)` projects its type arguments and
its value arguments into ONE flat child list (`NewExpr T (Named K) (Named V)
(IdentExpr a)`), so `new $T(...)` counts `new Map<String,Int>()` as a
construction too — it is one. It is not a new confusion: `new $T($a, $b)`
already matches `new Map<String,Int>()` today. When the type arguments are the
question, write them out — `new $T<$K>(...)` matches only a construction that
carries at least one type argument, because a metavar in a type-argument slot
projects as `Named` and no value argument ever does (the partition is the
plugin's own `typeAnnotationKinds`). Measured over TM's `src/`: 56 of the 4240
constructions carry an explicit type argument, 21 carry two.

Note also that the projection of type arguments is shallow and `NewExpr`-only:
`new Map<String, Array<Int>>()` projects `(Named String) (Named Array)` — the
nested `Int` is gone — and `extends Base<Int,String>`, `implements IFace<Float>`,
`function f<T,U>()`, a `typedef`'s parameters and every type annotation project
their type arguments as no node at all. A type-parameter census over anything
but `new` is therefore not a `search` question today.

### Non-features in v1

These are intentionally deferred to keep the v1 surface small and the semantics tight:

- Type filters (`$X:Int` to constrain matches by type). Requires type resolution — deferred indefinitely.
- Regex on identifiers (`$X /pattern/`). Phase 2+ candidate.
- Negative patterns / `not(...)`. Phase 2+ candidate.
- Sibling / ancestor combinators. Phase 2+ candidate.

The v1 syntax is the **smallest set that is still useful** — concrete fragments with hole metavariables. Every deferred feature can be added later without breaking the existing syntax.

## Selector syntax for `ast --select` (v2)

The selector is a minimal path language for navigating to subtrees.

| Form                | Meaning                                          |
|---------------------|--------------------------------------------------|
| `<kind>`            | Match any node of this kind                      |
| `<kind>:<name>`     | Match a node of this kind with the given name    |
| `<kind> <name>`     | Space is an accepted alias for `:`               |
| `A > B`             | `B` is a direct child of `A`                     |
| `A >> B`            | `B` is an any-depth descendant of `A` (v2)       |

Kind names come from the grammar plugin's public AST vocabulary — typically the user-facing node names (class, function, field, etc.), not internal type-name details.

Example concept:

```
apq ast file.hx --select 'class:Foo > function:bar'
apq ast file.hx --select 'function:bar >> VarStmt:tmp'   # a local, nesting-agnostic
```

The descendant combinator is what makes the `file → class → method → local`
addressing path practical: `>` requires knowing the exact intermediate nesting
(method body blocks etc.), `>>` does not.

### Non-features

- Attribute filters (`class[name=Foo]` style). Phase 2+ candidate.
- Pseudo-selectors (`:first-child`, `:has(...)`). Phase 2+ candidate.
- Ordinals inside the selector (`#n`) — disambiguation is the CLI-level
  `--nth <k>` flag (1-based, document order), shared by every op that accepts
  `--select` / `--match`.

A more expressive selector layer can be added later; the grammar is forward-compatible.

## Op addressing: `--select` / `--match` / `--nth` / positions

Every mutation op resolves its target through one shared address layer
(`anyparse.query.Address`). Accepted forms:

| Form                 | Meaning |
|----------------------|---------|
| `<line>[:<col>]`     | 1-based position; **column omitted = the line's first non-whitespace character** (line numbers come from lint / compiler output; the column is the fiddly part), then past the declaration's modifier / metadata prefix — `public static function f` resolves the `FnMember`, not the `Public` sibling node, and `@:keep` on its own line reaches the declaration below it. The walk stops at anything that is not a node START, so a comment between the prefix and the declaration keeps the address on the prefix rather than widening it to the enclosing type. Spell the column explicitly to address a modifier or annotation itself |
| `--select '<sel>'`   | Selector v2 path; must resolve to exactly one node |
| `--match '<pattern>'`| An `apq search` structural pattern (`$x` metavars); the matched node is the target |
| `--nth <k>`          | Picks the k-th (1-based, document order) of several `--select` / `--match` matches |

Rules and properties:

- Exactly one of position / `--select` / `--match` per op invocation.
- An ambiguous `--select` / `--match` fails with a candidate listing (position
  + kind of the first few matches) ready for an `--nth` pick — and each row that
  a NAME can address alone also carries the selector that does it, the same
  canonical address `Address.describe` hands to a position-addressed op and to
  the `source` read-guard menu. A row only an ordinal separates stays bare,
  since `--nth <k>` is what the message already offers. So a `--select
  'Conditional'` that matched a module-level region and a member-level one
  answers both rows — `#2 4:2 Conditional  --select 'ClassDecl:C >> Conditional'`
  for the member-level one and `#1 1:1 Conditional  --select 'module >
  Conditional'` for the other — instead of leaving the reader to guess that such
  a path exists. The second row reaches its address a different way: every
  widening step prepends a NAMED ancestor with `>>`, so the walk can say
  "somewhere under X" and cannot say "at the TOP LEVEL", and the root is the one
  ancestor every node shares and the one that is always nameless. A node hanging
  directly off it therefore has no named ancestor at all, and its bare segment
  matches every same-kind node in the file; a final root-anchored attempt with
  the direct-child combinator is what singles it out. It is tried only for a
  direct child of the root — deeper, the ordinal is genuinely what separates the
  candidates. The listing asks
  `AddressIndex.uniqueSelector`, which reports "names cannot single this out"
  as an ABSENCE — reading it off `describe`'s rendered string cannot work,
  because a node's name is arbitrary text: a literal spelling ` --nth 2` looks
  like the ordinal form, and a literal holding a `>` sends the widened selector
  down a child path that matches nothing, so `describe` falls back to
  `<line>:<col>` and a string-sniffing listing offered `--select '6:10'`.
- Named/pattern addresses are **edit-stable**: they survive edits above them,
  so a chain of ops needs no re-locate step between edits (a position rots as
  soon as an earlier edit shifts lines).
- On a position / `--match` resolution the op echoes the target's **canonical
  selector** to stderr (`apq <op>: target FnMember:walk`) — the edit-stable
  address to use for follow-ups.
- `replace-node --kind <Kind>` combined with `--select` / `--match` LIFTS the
  resolved node to its innermost enclosing `<Kind>` — a pattern matches the
  expression (`addCase(x)` = the `Call`), while a statement edit wants the
  `ExprStmt`. (With `--at` it keeps its original meaning: the innermost node
  of `<Kind>` at the cursor.)
- `lint --format json` records carry an `address` field — the finding's
  canonical selector, directly usable as an op's `--select` argument.
- `remove-element` NAMES WHAT IT CUT on both the write and the preview line:
  `wrote F.hx (removed FnMember f: 8 lines, with its doc comment and 2
  annotations)`. The address is not the problem it solves — `FnMember:f` and
  `Meta:@:keep` on the same declaration are distinct and each removes exactly
  what it names, measured — the problem was that both reported `wrote <file>`,
  so a selector typed while meaning the annotation ON a member read exactly like
  the one-line edit that was meant. See "What a removal reports" below.
- `remove-member` takes the same three forms and REDUCES the resolved node to
  the `(enclosing type, member)` NAME pair its by-name form takes, lifting an
  address that lands inside a body to the member holding it. The removal itself
  stays BY NAME, so every conditional-compilation twin of that name goes,
  whichever branch's declaration the address happened to resolve — an address
  SPELLS the pair, it never narrows the removal to one branch. Twins are
  declarations in DIFFERENT branches: two of one name inside ONE branch are an
  illegal duplicate no build can compile — the state a `replace-node` leaves
  when its replacement re-declares the member it was aimed at — and taking both
  is data loss, so that is a refusal naming the count and pointing at
  `remove-element --select … --nth <k>`, which addresses one node. (Until S168
  the check was region-level, so it caught two unguarded declarations and a
  guarded/unguarded mix and was blind to the same-branch pair; `safe-delete`
  shares the path and the fix.) "One branch" includes two SIBLING regions
  spelling the same condition (`#if a f #end #if a f #end`): no build compiles
  one without the other, so the pair is as uncompilable as two declarations
  inside one region. That half was open until S176, because a `CondFrame` was
  keyed by region OCCURRENCE and the two read as different branches; the frame
  now carries its branch's condition CHAIN (`a`, `a|b` for an `#elseif b`, `a|`
  for an `#else`, normalised so `#if (a)` and `#if a` compare equal) and
  `CondBranchPath.sameBranch` compares that. `CondBranchPath.comparable` keeps
  the region ordinal — it asks "is this the same region", which is the right key
  for `duplicate-case` and the wrong one for a refusal. Two chains that are
  logically equivalent but spelled apart (`#if !a` against an `#else`) are still
  different keys, and both declarations then go, which is the direction that
  keeps the conditional-twin removal the op exists for. Giving both an
  address and `--type <T> <memberName>` is a usage error, and an address that
  resolves to something that is not a member is refused with a pointer at
  `remove-element`. (The ops that accept no address form are the ones whose
  target is not a node: `add-member` appends by `--type`, `add-import` /
  `remove-import` take a module path, `new` / `fmt` are whole-file.)

### A module-level declaration's RAW span reaches the next one — the ops do not

A module-level declaration's node span runs to the first byte of the
declaration after it, so it holds the whitespace AND the comments between them,
the next declaration's own doc block included. Member spans are tight, which is
why the asymmetry keeps being rediscovered from a reading command and filed as
a greedy-window bug. Census over `src` + `test` (S168): **1013 of 14 055
module-level declarations (7.2%)** have a span longer than their own last token
— **5062 lines / 239 001 bytes** in total, worst single **140 lines**
(`TypedefDecl` in `src/anyparse/check/PreferMapType.hx`); 668 of them are
`FinalDecl`, 345 `TypedefDecl`, no other kind.

None of that reaches an op. Every addressed op folds the node through
`ElementSpan.declEditSpan`, whose `trailingTrimmedSpan` walks the swallowed
whitespace and comments back off before anything reads or writes them — so
`source --select` prints the declaration's own bytes, `patch` cannot find a
fragment that lives only in the gap, and `replace-node` / `set-doc` /
`remove-element` / `add-element` leave the neighbour's doc standing. Measured on
`PreferMapType.hx`: `TypedefDecl:Site`'s raw span is 10 267 bytes and
`source --select` prints 6 lines.

The report that opened this question measured
`GrammarPlugin.hx --select 'TypedefDecl:RefShape'` at 2648 lines and read that
as the greedy span. `RefShape` is a genuinely 2648-line declaration (line 365 to
line 3010, mostly its own field documentation) and the window was exactly its
own bytes. `unit.query.GreedyDeclSpanEditBoundarySliceTest` pins the trim, and
that the raw span really is greedy — a fixture whose span went tight would
otherwise make the suite green and meaningless.

### What a removal reports, and why it is a report rather than a refusal

`apq remove-element --select 'FnMember:<name>'` removes that member together
with its modifier / `@:meta` group and its leading doc block. That is its job —
it is the DELETE verb of the op family — and the fold is what makes the file
still parse afterwards. What it could not do until S125 was SAY so: a
twenty-line annotated test and a one-line statement produced the identical
`apq remove-element: wrote <file>`.

Three fixes were on the table and the measurement picked the third.

A **specificity rule** (refuse a member address when the member carries
annotations, print both addresses) refuses an address that is already correct.
Probed on one file: `--select 'FnMember:f'` removes the member and its group,
`--select 'Meta:@:keep'` removes the annotation and leaves the doc block
standing. Nothing is ambiguous; a refusal there costs a flag at every
deliberate use and still says nothing about the un-annotated twenty-line member.

A **confirmation threshold** (an unqualified member address that would take a
doc, an annotation, or more than N lines needs an explicit flag) was measured
against the codebase it would run in. Driving the op in preview mode over every
`FnMember` in `src/anyparse/query` — 1647 members over 70 files — gives:

| what the cut carries | members | share |
|---|---|---|
| a leading doc block | 1502 | 91.2 % |
| an annotation | 1 | 0.1 % |
| more than 10 lines | 1215 | 73.8 % |
| doc, annotation, or more than 20 lines | 1513 | 91.9 % |
| doc, annotation, or more than 5 lines | 1581 | 96.0 % |

In a tree whose lint config enables `prefer-doc-comment`, "the member has a doc"
is the norm and carries no signal. A gate firing on 92–96 % of correct uses is
ceremony that gets bypassed by reflex, and the reflex is what the guard was for.

So the fix is the **report**. It costs no behaviour: every deliberate removal
works exactly as before, with no new flag, and the 17 `RemoveElementSliceTest`
fixtures plus the 21 pre-existing `AddressCliTest` ones stay green untouched.
And it is strictly wider than either refusal would have been — it fires for a
position and a `--match` address too, and it names the DECLARATION rather than
the node the cursor resolved, so a position landing on `public` reports
`removed FnMember f`, not `removed Public`.

The count is the LINES THE CUT SPANS, which is not always the file's line delta:
removing the only statement of a block lets the writer collapse the block on top
of the cut, so the file loses two lines where the report says one. The report
describes the element that was addressed; `git diff` describes the file.

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

`line` and `col` are both 1-based — the single coordinate convention shared by every `apq` / `hxq` surface (`refs`, `ast --at`, `source`, the refactoring ops, and this JSON output).

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
| Params & bindings | `Required`, `Optional`, `Rest` |

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

**Where it stands, measured rather than asserted (S188, on `e11018f5`).** The rule
is about TYPES, and the engine names a Haxe type in exactly two places: the CLI
registry, which has to construct the plugin it selects (`cli/CliArgs.hx`), and one
real remainder — `query/FormatConfigDiscovery.hx` reaches for
`HaxeFormatConfigDiagnostics` to warn about a config it found. A kind name spelled as
a STRING is the same coupling with none of the compiler's help, and there are
**549 occurrences of 126 distinct projected ctor names across 62 files** of
`src/anyparse/query` + `src/anyparse/check` (761 / 168 / 73 if names that are also
ordinary English words — `Static`, `Public`, `Inline` — are counted; that inclusive
triple is the reproducible one — a second reviewer's word list gave 560 / 129 / 61
for the exclusive count, so the narrow number is a reading of one word list, not a
measurement). The census is
one command against `HaxeQueryWalker.projectedKinds()`, which is the same generated
vocabulary `unit.query.RefShapeKindProjectionTest` compares the declared side
against:

```
hxq lit '' src/anyparse/query src/anyparse/check --kind Literal --flat   # then intersect
```

The repair per site is a `RefShape` field, and the reason to do it site by site
rather than in one sweep is that each one is a CONTRACT question — what does this
consumer actually need to know about the grammar — not a rename. Two shapes of that
question have been answered so far and are worth reading as precedent: the
string-literal vocabulary (`apq lit` / `InertRegions`, above) and the metadata
sigils (`apq cond --names`). The biggest remaining block is the operator /
precedence tables — `MemberKinds.SAFE_KINDS`, `InlineMethod.PURE_ARG_KINDS` and
`ATOMIC_ROOT_KINDS`, ~78 ctor names between them — each paired with a SUFFIX
heuristic (`kind.endsWith('Lit')`, `kind.endsWith('StringExpr')`) that guesses the
grammar's naming CONVENTION rather than reading a declaration.

A hardcoded list is invisible to the declared-vs-projected differential, which is
its own hazard: that fixture reads `RefShape` fields, so a name moved into the shape
gains a build-time check that it is a kind the grammar still projects, and a name
left in an engine-side array has none. `LambdaParam` sat dead in three kind lists
for three months on the shape side, where something eventually looked; nothing at
all looks at the engine-side arrays.

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

The skeleton this spec projected, as it actually shipped (`src/anyparse/query/`
has grown well past the five modules named here):

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
  apq-js-common.hxml    # shared build flags (no output line)
  apq-js.hxml           # leaf: writes bin/apq.js
  hxq                   # shell alias script
```

The library code lives inside `src/anyparse/` (no separate haxelib package). `bin/apq-js.hxml` produces the single-file `bin/apq.js`; `hxq` is a tiny shell wrapper that prepends `--lang haxe`. The Phase-1 neko target (`bin/apq.hxml`) is gone: the CLI spawns processes through `js.node`, and the neko artifact it built died at module load before it ran a query.

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
- The "anywhere in this container" form is the `...` ellipsis, now implemented — see "The `...` ellipsis" above. It is anchored (prefix from the left, suffix from the right), one per child list, and does not bind.

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
- [haxe-format-config.md](haxe-format-config.md) — the `hxformat.json` values the Haxe writer accepts (`wrapping.*` modes and `cond` spellings), and why an unknown one is silent.
