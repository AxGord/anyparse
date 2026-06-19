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
rewrite), iterating to a fixed point so a fix that exposes another finding — a deleted
dead-code run leaving a local unused, a de-nested `else` revealing the next — is resolved
in the same run. A check is a plugin — a new one is a new class, not a core change.

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
| `unused-import` | an import whose bound name is never referenced in the file; a `using` counts as referenced when one of its extension methods is called (`.method`) — known stdlib modules (`StringTools` / `Lambda`) are resolved and a verified-unused `using` is a deletable `Warning`, while an unknown `using` stays an unverifiable `Info` |
| `unused-local` | a local `var` / `final` never read in its enclosing scope |
| `duplicate-import` | an import / using declared more than once in the same file |
| `naming` | a declaration name violating the convention — the built-in default, or one adapted from a project's `checkstyle.json` |
| `unused-private` | a `private` field / method never referenced — flagged only when the type is provably confined to its file (no subtype, `@:access`, `@:allow`, or skip-parse) |
| `unused-parameter` | a function parameter never referenced in its body — purely structural; `Info`, report-only (removing a parameter is a cross-file signature change the `remove-param` op performs with a call-site completeness proof; `Info` because a function passed as a fixed-signature callback or referenced by a `@:fmt(preWrite(…))`-style hook may mandate an unread parameter, which a structural scan cannot rule out). Skipped: an `_`-prefixed name (the intentional-discard convention), a body-less interface / abstract method declaration, and a method of a type carrying a supertype clause (`extends` / `implements`), whose signature may be a fixed contract — a local function and a method of a supertype-less type stay in scope |
| `complexity` | a function whose cyclomatic complexity exceeds the threshold — the built-in default (10), or a `CyclomaticComplexity` max adapted from a project's `checkstyle.json` (decision points: `if`/`while`/`for`/`case`/`catch`/`&&`/`\|\|`/`?:`/`??`) — report-only |
| `fold-adjacent-string-literals` | a `+` chain of adjacent same-quote plain string literals that can be merged into one (`"a" + "b"` → `"ab"`); `--fix` folds it (interpolated / mixed-quote / non-literal operands left alone) |
| `dead-code` | a statement made unreachable by a preceding unconditional `return` / `throw` / `break` / `continue` in the same block — purely structural (no type information); `--fix` deletes the whole dead run (every statement from the first unreachable one to the block's end) |
| `empty-block` | an empty control-flow block — an `if` / `else` / loop / `try` / `catch` body written as `{}` with no statements (a comment-only block is left alone, an empty function body is not flagged) — purely structural; `--fix` removes the provably-safe subset (an empty `else {}`, and an empty no-else `if (cond) {}` with a side-effect-free condition), leaving an empty loop / `try` / `catch` body report-only |
| `swallowed-exception` | a statement-context `catch` (`try { … } catch (e) { … }`) whose non-empty block silently swallows the caught exception — it neither references the exception variable, rethrows, nor returns (a generic log, an unrelated side effect) — `Warning`, report-only; purely structural. Only the statement form is considered: an expression-position try (`var x = try … catch (e) fallback`) recovers by producing the catch value and is never a swallow. Skipped: an empty catch (left to `empty-block`), a body that uses the variable (handled), a body that rethrows / wraps-and-rethrows or returns a fallback (deliberate escalation / recovery), and a `_`-named variable (the explicit intentional-discard convention) |
| `identical-operands` | a binary operator whose two operands are textually identical (`a == a`, `a != a`, `a && a`, `a.x == a.x`) — almost always a bug; an operand containing a call (`g() == g()`) is left alone — report-only |
| `self-assignment` | a LOCAL variable assigned to itself (`x = x`), a provable no-op — flagged only when `x` resolves to a local declaration; a field / property self-assignment (`p = p` or `this.x = this.x`) may invoke a setter and is left alone; `--fix` deletes a flagged local self-assignment |
| `duplicate-case` | a switch branch whose pattern repeats an earlier branch in the same switch (dead code); guarded branches with the same pattern but different guards are left alone — report-only |
| `redundant-parens` | a parenthesized expression redundantly wrapped in another (`((e))` / `(((e)))`); `Info`, `--fix` unwraps to a single pair (`(e)`) |
| `constant-condition` | a boolean literal as an `if` condition (`if (true)` / `if (false)`) — a branch always or never taken; loops are left alone (`while (true)` is an idiomatic infinite loop) — purely structural; `--fix` replaces the `if` with the always-taken branch (`if (true) A [else B]` → `A`, `if (false) A else B` → `B`, a no-else `if (false) A` statement is deleted), leaving only a no-else `if (false)` in expression position report-only |
| `empty-statement` | a stray empty statement (a lone `;`); `--fix` deletes it (the whole line when the `;` sits alone, otherwise just the `;`) — purely structural |
| `redundant-else-after-return` | an `else` whose `if` then-branch always exits (`return` / `throw` / `break` / `continue`), so the `else` is needless nesting — flagged only for a block-statement `if` (an expression `if` keeps its required `else`); `Info`, `--fix` de-nests the else body, skipping a body that declares a local (its scope would widen) |
| `comparison-to-boolean` | a comparison against a boolean literal (`x == true` / `x != false`) where the literal adds nothing; `Info`, report-only — an operand reached through a null-safe access (`obj?.flag == true`) is skipped, since that `== true` may be load-bearing on a `Null<Bool>` under strict null-safety, and removing it cannot be proven safe without type information |
| `collapsible-if` | an `if` whose sole then-branch is another `if`, neither carrying an `else` (`if (a) { if (b) … }`) — the two conditions merge with `&&`; `Warning`, `--fix` rewrites to `if (a && b) …` (behaviour-preserving via short-circuit), parenthesizing a lower-precedence operand (`if (a || c) if (b)` → `if ((a || c) && b)`) |
| `double-negation` | a redundant double logical negation (`!!x`); `Info`, report-only — removing it could change behaviour if the operand drives a property getter, so the cleanup is left to a human |
| `prefer-null-coalescing` | a null-guard ternary that `??` replaces — `x != null ? x : y` / `null != x ? x : y` / `x == null ? y : x` / `null == x ? y : x` all collapse to `x ?? y`; `Info`, `--fix` rewrites it (a guarded value containing a call is left alone — `??` evaluates it once, the ternary twice; a bare-ternary fallback is parenthesized since `??` binds tighter than `?:`) |
| `prefer-array-literal` | an empty-argument `new Array()` / `new Array<T>()` replaceable with the array literal `[]`; `Info`, `--fix` rewrites it (the element type carries through the assignment target's annotation; an unannotated `var x = new Array<Int>()`, whose only type source is the constructor's own parameter, is left alone) |
| `prefer-map-literal` | an empty-argument `new Map()` / `new Map<K, V>()` replaceable with the map literal `[]`; `Info`, `--fix` rewrites it (same annotation caveat as `prefer-array-literal`) |
| `prefer-interpolation` | a single-argument `Std.string(x)` replaceable with string interpolation (`'$x'` for a simple identifier, `'${expr}'` for any other interpolation-safe expression); `Info`, `--fix` rewrites it (an argument whose source carries a quote or `$` is left alone; surrounding string concatenation is not merged) |
| `prefer-final` | a local `var x = …` never reassigned in its scope, replaceable with `final`; `Info`, `--fix` swaps `var`→`final`. Reassignment is detected with the scope-resolved write walker (complete — every write is a structural `=`/`+=`/`++` node), so the fix is always sound. Only a single `var` with an initializer is a candidate (a no-init or multi-declaration `var a = 1, b = 2` is skipped); a never-read `var` is left to `unused-local` (the read gate keeps the two from overlapping); a generic-typed `var x:Map<K, V>` is conservatively skipped (its type-parameter comma is indistinguishable from a declaration separator without tracking `<>`) |
| `prefer-ternary-return` | an `if (cond) return a;` whose immediately-following sibling is a `return b;`, collapsible to a single `return cond ? a : b;`; `Info`, `--fix` rewrites the pair. Only a no-else `if` that is a direct block statement with a value-returning then-branch (`return e;`, or a `{ … }` wrapping exactly one) and an immediately-following value `return` qualifies — a value-less `return;`, an intervening statement, or an inline non-block `if` is left alone. The condition is parenthesised only when it binds no tighter than `?:` (a ternary or an assignment); the `else`-form (`if (c) return a; else return b;`) is `redundant-else-after-return`'s job, which de-nests it into the form this check then collapses |
| `prefer-single-quotes` | a double-quoted string literal that can use single quotes (the Haxe default); `Info`, `--fix` swaps the delimiters. A literal whose content has a `$` (the double quotes deliberately suppress interpolation that single quotes would trigger) or a `'` (which would terminate the single-quoted form) is left alone; every other escape (`\"`, `\n`, …) stays valid verbatim, so only the two delimiter characters change. Without types the rare case of a macro that branches on a literal's quote kind cannot be detected — hence `Info` + opt-in `--fix`, never auto-applied |
| `simplify-boolean-ternary` | a ternary with a boolean-literal branch that reduces to plain boolean logic — `cond ? false : x` → `!cond && x`, `cond ? x : true` → `!cond \|\| x`, `cond ? true : false` → `cond`, and the mirror forms; `Info`, `--fix` rewrites it. Any negation is pushed inward by De Morgan (`!(a == null \|\| b == null)` → `a != null && b != null`) so no `!( … )` is left over a compound, and operands are parenthesised only where precedence requires. A real-valued ternary, or one with the same literal both sides (collapsing would drop `cond`'s side effect), is left alone. Composes with `prefer-ternary-return` through the `--fix` fixed-point loop, so a boolean-returning guard chain collapses all the way to one flat boolean `return` |
| `assignment-in-condition` | an assignment (`=`) used as a condition — `if (a = b)`, `while (a = b)`, `do … while (a = b)` — almost always a `==` typo (a Haxe condition must be `Bool`, so the assign even compiles only in the narrow case that matches a typo); `Warning`, report-only (`=` vs `==` is the author's intent). The condition slot is pinned by position (first child for `if` / `while`, last for `do … while`, unwrapping one paren layer), so an assignment in a branch body (`if (c) x = y`) is not flagged |
| `duplicate-ternary-branches` | a ternary whose then- and else-branches are textually identical (`cond ? x : x`), so it always yields `x` and the condition is dead; `Warning`. `--fix` collapses it to the branch only when `cond` is side-effect-free; a side-effecting condition (`f() ? x : x`) is report-only |
| `prefer-bind` | a zero-parameter arrow lambda wrapping a single call with arguments (`() -> f(a, b)`), replaceable with the partial application `f.bind(a, b)`; `Info`, `--fix` rewrites it. A parameter-bearing lambda (`x -> f(x)`), a block body, and a zero-argument `() -> f()` are left alone. `.bind` evaluates the callee and arguments at bind time rather than call time — equivalent for the common case, hence `Info` |
| `redundant-map-iter-key` | a key-value `for` loop that discards its key with `_` (`for (_ => v in m)`), replaceable with `for (v in m)` since Haxe iterates values by default; `Info`, `--fix` drops the `_ => ` prefix. A value-only `for (_ in m)` (no `=>`) is a legitimate ignore-value loop and is left alone |
| `prefer-switch` | an `if` / `else if` chain testing one expression against literal values (`if (x == 'a') … else if (x == 'b') …`), which reads more clearly as a `switch`; `Info`, report-only (converting a chain to a `switch` is a follow-up). Flagged only when every rung is an equality (`==`) comparing the *same* discriminant against a constant literal (int / float / bool / null / non-interpolated string), the discriminant is call-free (a `switch` evaluates it once where the chain evaluates it per rung — a behaviour change), and there are at least two rungs. A `!=` chain, a non-equality or mixed condition, differing discriminants, and a non-literal or interpolated operand are left alone |
| `missing-visibility` | a class / abstract member declared without an explicit `public` or `private` modifier; `Warning`, report-only. Interface members (implicitly public) and enum-abstract values are exempt. Haxe defaults an unmodified member to `private`, so the omission is not a bug — but stating visibility on every member is a documented project rule. Inserting the keyword is left to a follow-up |
| `modifier-order` | a member whose modifier keywords are not in the canonical order `override` → `public` / `private` → `static` → `inline`; `Info`, report-only. Purely cosmetic — the order carries no meaning to the compiler. Modifiers with no documented order (`extern`, `dynamic`, `macro`, …) are ignored |
| `explicit-type` | a member field with no `:Type`, a function parameter with no `:Type`, or a function with no return type; `Warning`, report-only (a missing type cannot be filled in without inference). A constructor (`new`) is exempt from the return-type rule and enum-abstract values from the field rule; interface members are checked like any other. Stating types everywhere is a documented project rule |

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
