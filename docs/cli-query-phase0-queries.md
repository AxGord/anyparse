# Phase 0 — ten representative queries

Hand-written queries against the anyparse Haxe codebase that exercise the v1 syntax of all four `apq` commands. These are the artefacts the roadmap's Phase 0 exit condition gates on — they have been reviewed without prompting a backward-incompatible syntax change, so the syntax tables in [cli-query-tool.md](cli-query-tool.md) are now frozen for v1.

The queries use the anyparse repository as their concrete corpus because that is the codebase the tool will first dogfood against. Their **annotations are framed generically** — each one shows a class of analysis question the tool answers, not an anyparse-internal recipe. A future second-grammar consumer (Phase 6) will rewrite the invocations against its own corpus but keep the same shape.

All invocations below use the `hxq` alias (= `apq --lang haxe`). Same behaviour with `apq --lang haxe …` written out.

## Q1 — extract one subtree from a known file

```
hxq ast src/anyparse/grammar/haxe/HxFnDecl.hx --select 'class > field:params'
```

Returns the AST of the `params` field declaration inside the top-level class declaration of the file, with no surrounding context.

**Workflow class:** "open this file, jump to this declaration, paste the AST into a scratch pad" — replaced by one invocation. Useful when a 95-file directory makes "open the right file" the slow step.

**Syntax stressed:** `kind > kind:name` selector with the direct-child combinator; default text output.

## Q2 — what AST node is at this cursor

```
hxq ast src/anyparse/macro/WriterLowering.hx --at 3295:0
```

Returns the **smallest enclosing AST node** at line 3295, column 0. Output prints the node kind, span, and one-line summary.

**Workflow class:** answer "what am I looking at" from an editor cursor position without opening the file in a structured editor. The tool acts as a poor man's "expand selection".

**Syntax stressed:** `--at <line>:<col>` cursor query; smallest-enclosing-node semantics.

## Q3 — file table-of-contents at JSON depth 2

```
hxq ast src/anyparse/grammar/haxe/HxFnDecl.hx --depth 2 --json
```

Returns the file's top-level declaration plus its direct children, in JSON, truncated beyond depth 2.

**Workflow class:** machine-readable overview of a file structure for piping into other tools (`jq`, scripts, editor extensions). Avoids flooding the terminal when the goal is "what's in this file" rather than "show me everything".

**Syntax stressed:** `--depth` truncation; `--json` output and its `Node` schema.

## Q4 — pattern with metavariable reuse

```
hxq search 'if ($x != null) return $x.$f($_)' src/anyparse/
```

Returns every conditional null-guarded method call where the same receiver appears on both sides of the check. Each match binds `$x` to the receiver, `$f` to the called method name, and `$_` to the argument list (no binding).

**Workflow class:** locate refactoring candidates by structural shape — here, places where an optional-chain operator (`?.`) could replace an `if (x != null)` guard. Text grep cannot express the "same `x` on both sides" constraint.

**Syntax stressed:** [structural-identity unification rule](cli-query-tool.md#metavariable-reuse-structural-identity-unification) for `$x` reused; bound metavar `$f`; wildcard `$_`.

## Q5 — annotated declarations with field name and type captured

```
hxq search '@:fmt($_) var $name:$type' src/anyparse/grammar/
```

Returns every `@:fmt`-annotated field declaration, binding `$name` and `$type` per match. The annotation's argument list is matched by `$_` (wildcard, no binding).

**Workflow class:** enumerate decls carrying a specific annotation along with their full signature. Bridges between `meta` (annotation-only) and `search` (full structural) — useful when the workflow needs both the annotation match and the surrounding context.

**Syntax stressed:** annotation as part of a structural pattern; mixed wildcard `$_` and bound `$name`/`$type` in one pattern.

## Q6 — independent wildcards in tuple positions

```
hxq search 'throw new $E($_)' src/anyparse/
```

Returns every `throw new SomeException(args)` site, binding `$E` to the exception class. The constructor args are matched by `$_` without constraint.

**Workflow class:** enumerate every site that throws a constructed exception, grouped by class. Useful for audit ("which exceptions are thrown where") and migration ("rename all throws of ClassA").

**Syntax stressed:** bare metavar `$E` in a type-name position; single `$_` wildcard.

## Q7 — multiple independent wildcards in fixed-arity position

```
hxq search '@:fmt($x, $y, $z)' src/anyparse/grammar/
```

Returns every `@:fmt(...)` annotation called with **exactly three** arguments, binding each to `$x`, `$y`, `$z`.

**Workflow class:** find structural shapes with a specific argument count. Exposes when an annotation's arity changes meaning, or when one signature variant dominates.

**Syntax stressed:** multiple bare metavars in leaf positions; arity-fixed match (no ellipsis available in v1 — three args means three args, not "three or more").

## Q8 — write-only refs for a flag-style local

```
hxq refs --writes _hasTrivia src/anyparse/macro/WriterLowering.hx
```

Returns every position in the file where `_hasTrivia` is **written**. Reads and declarations are excluded by the `--writes` filter.

**Workflow class:** blast-radius audit before changing a predicate's semantics. "What sets this flag?" must answer before "what reads this flag?" — `refs --writes` answers the first; `refs --reads` answers the second.

**Syntax stressed:** `--writes` filter on `refs`; lexical scope tracking distinguishes the file-scope binding from any shadowed locals with the same name.

## Q9 — annotated decls filtered by an arg substring

```
hxq meta @:fmt --arg-contains groupRestProbe src/anyparse/grammar/
```

Returns every declaration carrying a `@:fmt(...)` annotation whose argument list contains the substring `groupRestProbe`.

**Workflow class:** opt-in audit — enumerate every consumer of a configurable feature flag before adding a new one or removing an obsolete one. The `meta` command is the right tool when the question is "who uses this annotation", not "what's the surrounding code".

**Syntax stressed:** `--arg-contains <substring>` filter on `meta`; cross-file enumeration.

## Q10 — full annotation inventory per file

```
hxq meta --on field src/anyparse/grammar/haxe/HxFnDecl.hx --json
```

Returns every annotation attached to any field declaration in the file, in JSON, with field name, annotation, args, and span.

**Workflow class:** inventory pass — "what does this file declare and with which annotations" — useful when porting a grammar to a new variant or when bootstrapping a doc that lists annotated decls.

**Syntax stressed:** `--on <decl-kind>` filter on `meta`; `--json` schema for `meta` results.

## Syntax-coverage matrix

Confirms the 10 queries exercise every v1 syntax feature at least once.

| Feature                                              | Queries        |
|------------------------------------------------------|----------------|
| `$X` bound metavar                                   | Q4, Q5, Q6, Q7 |
| `$X` reused (structural-identity rule)               | Q4             |
| `$_` wildcard, non-binding                           | Q4, Q5, Q6     |
| Metavar in type-name position                        | Q5, Q6         |
| Metavar / wildcard in annotation argument position   | Q5, Q7         |
| Annotation literal as part of a pattern              | Q5, Q7         |
| `kind:name` selector                                 | Q1             |
| `A > B` direct-child combinator                      | Q1             |
| `ast --at <line>:<col>`                              | Q2             |
| `ast --depth <n>`                                    | Q3             |
| `--json` output                                      | Q3, Q10        |
| `refs --writes`                                      | Q8             |
| `meta --arg-contains <substring>`                    | Q9             |
| `meta --on <decl-kind>`                              | Q10            |

## Validation notes from Phase 0 review

- **Q4's `$x` reuse depends on the [structural-identity rule](cli-query-tool.md#metavariable-reuse-structural-identity-unification).** If the rule were "any unify", `obj.foo` and `obj.foo()` could both match `$x` in different positions and yield false-positive matches with semantically different receivers. Structural identity is the correct semantics here.
- **No query exercises Star-children matching.** Each pattern is a single decl, expr, or stmt in isolation. The [ordered-and-adjacent rule](cli-query-tool.md#star-children-matching-ordered-and-adjacent-by-default) does not bite on any of the 10 queries. The first real consumer will be a future query like "two consecutive `var` fields with the same type" which the v1 syntax already supports under the adjacent rule.
- **No query relies on whitespace or comments inside the pattern.** The [ignored-whitespace rule](cli-query-tool.md#whitespace-and-comments-in-patterns-both-ignored) is consistent with all 10.
- **Q8's `_hasTrivia` is a private field in anyparse's macro layer.** A user with a different corpus would invoke `refs --writes` against any flag-like local in their own code; the workflow generalises.

## See also

- [cli-query-tool.md](cli-query-tool.md) — design baseline, frozen syntax tables, and JSON schemas these queries reference.
- [cli-query-roadmap.md](cli-query-roadmap.md) — Phase 0 sits in §Phase 0 of this roadmap; the next phase (`apq ast` MVP) implements the surface these queries call into.
