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
integer group by N. A literal `<find>` matches even across a comment's line breaks (a
phrase wrapped over two ` * ` doc lines). Code and the comment delimiters are never
touched; strings are skipped. A mechanical convention change cited across many doc-comments (e.g. bumping a
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
named rules) clears any finding whose source span covers its line — so a directive the
writer reflowed onto a continuation line still lands — and `// CHECKSTYLE:OFF` …
`// CHECKSTYLE:ON` clears a region (matching the finding's reported line) — so one stubborn false positive never makes a rule unusable. `--fail-on
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
| `unused-import` | an import whose bound name is never referenced in the file; a `using` counts as referenced when one of its extension methods is called (`.method`) — known stdlib modules (`StringTools` / `Lambda`) are resolved and a verified-unused `using` is a deletable `Warning`, while an unknown `using` stays an unverifiable `Info`. A project `checkstyle.json` `UnusedImport.ignoreModules` skip-list is honoured — a listed module (matched by full path or last segment) is never flagged |
| `unused-local` | a local `var` / `final` never read in its enclosing scope |
| `duplicate-import` | an import / using declared more than once in the same file |
| `naming` | a declaration name violating the convention — the built-in default, or one adapted from a project's `checkstyle.json` |
| `unused-private` | a `private` field / method never referenced — flagged only when the type is provably confined to its file (no subtype, `@:access`, `@:allow`, or skip-parse) |
| `unused-parameter` | a function parameter never referenced in its body — purely structural. `Warning` (with a delete `--fix`) for the autofixable subset — a named local function, or a confined private method (the same `isPrivateMemberConfined` proof `unused-private` uses) — whose call set can be proven complete WITHIN the file by the shared `RemoveParam.paramSlotEdits` core; `fix` removes the parameter AND its positional argument at every in-file call site (one parameter per function per pass, the rest follow as the fixed-point loop re-runs the proof). Everything else stays `Info`, report-only: a public / unconfined method is a cross-file signature change the `remove-param` op performs with its own advisory, and a function passed as a fixed-signature callback (or referenced by a `@:fmt(preWrite(…))`-style hook) may mandate an unread parameter a structural scan cannot rule out. Skipped entirely: an `_`-prefixed name (the intentional-discard convention), a body-less interface / abstract method declaration, and a method of a type carrying a supertype clause (`extends` / `implements`), whose signature may be a fixed contract — a local function and a method of a supertype-less type stay in scope |
| `complexity` | a function whose cyclomatic complexity exceeds the threshold — the built-in default (10), or a `CyclomaticComplexity` max adapted from a project's `checkstyle.json` (decision points: `if`/`while`/`for`/`case`/`catch`/`&&`/`\|\|`/`?:`/`??`) — report-only |
| `magic-number` | a numeric literal (`IntLit` / `FloatLit` / `HexLit`) used in logic — inside a function body — whose value is not a small conventional one, which should be extracted into a named constant; `Warning`, report-only (a literal cannot be auto-named). Exempt: the values `{0, 1, 2}` (a negative literal parses as a negation over a non-negative one, so `-1` / `-2` are exempt too), plus any number in the `magic-number` `ignore` array of a discovered `apqlint.json`; a literal outside any function (a member field initializer, an enum-abstract value, a typedef default, a metadata argument) and a literal directly naming a local binding (`var x = 5000` / `final x = 5000`, which already is the named extraction) are left alone. A project `checkstyle.json` `MagicNumber.ignoreNumbers` (default `[-1, 0, 1, 2]`, compared by magnitude) replaces the built-in exempt base; an `apqlint.json` `ignore` list adds to it |
| `fold-adjacent-string-literals` | a `+` chain of adjacent same-quote plain string literals that can be merged into one (`"a" + "b"` → `"ab"`); `--fix` folds it (interpolated / mixed-quote / non-literal operands left alone) |
| `dead-code` | a statement made unreachable by a preceding unconditional `return` / `throw` / `break` / `continue` in the same block — purely structural (no type information); `--fix` deletes the whole dead run (every statement from the first unreachable one to the block's end) |
| `empty-block` | an empty control-flow block — an `if` / `else` / loop / `try` / `catch` body written as `{}` with no statements (a comment-only block is left alone, an empty function body is not flagged) — purely structural; `--fix` removes the provably-safe subset (an empty `else {}`, and an empty no-else `if (cond) {}` with a side-effect-free condition), leaving an empty loop / `try` / `catch` body report-only. Disabled for a file whose `checkstyle.json` `EmptyBlock.option` is `empty` (the project deliberately allows empty blocks) |
| `swallowed-exception` | a statement-context `catch` (`try { … } catch (e) { … }`) whose non-empty block silently swallows the caught exception — it neither references the exception variable, rethrows, nor returns (a generic log, an unrelated side effect) — `Warning`, report-only; purely structural. Only the statement form is considered: an expression-position try (`var x = try … catch (e) fallback`) recovers by producing the catch value and is never a swallow. Skipped: an empty catch (left to `empty-block`), a body that uses the variable (handled), a body that rethrows / wraps-and-rethrows or returns a fallback (deliberate escalation / recovery), and a `_`-named variable (the explicit intentional-discard convention) |
| `identical-operands` | a binary operator whose two operands are textually identical (`a == a`, `a != a`, `a && a`, `a.x == a.x`) — almost always a bug; an operand containing a call (`g() == g()`) is left alone — report-only |
| `self-assignment` | a LOCAL variable assigned to itself (`x = x`), a provable no-op — flagged only when `x` resolves to a local declaration; a field / property self-assignment (`p = p` or `this.x = this.x`) may invoke a setter and is left alone; `--fix` deletes a flagged local self-assignment |
| `duplicate-case` | a switch branch whose pattern repeats an earlier branch in the same switch (dead code); guarded branches with the same pattern but different guards are left alone — report-only |
| `redundant-parens` | a parenthesized expression redundantly wrapped in another (`((e))` / `(((e)))`); `Info`, `--fix` unwraps to a single pair (`(e)`) |
| `redundant-this` | a `this.field` access whose `this.` is redundant — no local / parameter / loop-var / local-function in the enclosing member shadows `field`, so it reduces to bare `field`; `Info`, `--fix` drops the `this.`. A shadowed access (the `this.x = x` constructor pattern) is kept, and a compile-time `abstract`'s `this.field` (where `this` is the underlying value) is never matched |
| `constant-condition` | a boolean literal as an `if` condition (`if (true)` / `if (false)`) — a branch always or never taken; loops are left alone (`while (true)` is an idiomatic infinite loop) — purely structural; `--fix` replaces the `if` with the always-taken branch (`if (true) A [else B]` → `A`, `if (false) A else B` → `B`, a no-else `if (false) A` statement is deleted), leaving only a no-else `if (false)` in expression position report-only |
| `empty-statement` | a stray empty statement (a lone `;`); `--fix` deletes it (the whole line when the `;` sits alone, otherwise just the `;`) — purely structural |
| `redundant-else-after-return` | an `else` whose `if` then-branch always exits (`return` / `throw` / `break` / `continue`), so the `else` is needless nesting — flagged only for a block-statement `if` (an expression `if` keeps its required `else`); `Info`, `--fix` de-nests the else body, skipping a body that declares a local (its scope would widen) |
| `comparison-to-boolean` | a comparison against a boolean literal (`x == true` / `x != false`) where the literal adds nothing; `Info`. `--fix` rewrites a comparison whose operand is a boolean-operator result (`&&` / `||` / `!` / a comparison, possibly parenthesized — provably non-null `Bool`): `(a && b) == true` → `(a && b)`, `x < y == false` → `!(x < y)`, `!flag != false` → `!flag` (a non-atomic negated operand is parenthesized). A bare identifier is NOT auto-stripped — it may be a `Null<Bool>` local whose `== true` is load-bearing under strict null-safety (`if (x)` would not compile), and without types the check cannot rule that out — so it stays reported for a human. Operands skipped from the report entirely: those whose nullness cannot be ruled out (a `?.` access, a call / `Map.get` result, a possibly-`@:optional` field — `obj?.flag == true`, `map.get(k) == true`, `obj.flag == true`), and comparisons inside macro reification |
| `collapsible-if` | an `if` whose sole then-branch is another `if`, neither carrying an `else` (`if (a) { if (b) … }`) — the two conditions merge with `&&`; `Warning`, `--fix` rewrites to `if (a && b) …` (behaviour-preserving via short-circuit), parenthesizing a lower-precedence operand (`if (a || c) if (b)` → `if ((a || c) && b)`) |
| `double-negation` | a redundant double logical negation (`!!x`); `Info`, `--fix` strips the redundant pair (`!!x` → `x`, `!!!x` → `!x`) — but only when the operand is provably non-null (its subtree reaches no `Call` / `FieldAccess` / `?.` access), since `!!maybeNull` coerces to a definite Bool that bare `maybeNull` would not |
| `prefer-null-coalescing` | a null-guard ternary that `??` replaces — `x != null ? x : y` / `null != x ? x : y` / `x == null ? y : x` / `null == x ? y : x` all collapse to `x ?? y`; `Info`, `--fix` rewrites it (a guarded value containing a call is left alone — `??` evaluates it once, the ternary twice; a bare-ternary fallback is parenthesized since `??` binds tighter than `?:`) |
| `prefer-array-literal` | an empty-argument `new Array()` / `new Array<T>()` replaceable with the array literal `[]`; `Info`, `--fix` rewrites it (the element type carries through the assignment target's annotation; an unannotated `var x = new Array<Int>()`, whose only type source is the constructor's own parameter, is left alone) |
| `prefer-map-literal` | an empty-argument `new Map()` / `new Map<K, V>()` replaceable with the map literal `[]`; `Info`, `--fix` rewrites it (same annotation caveat as `prefer-array-literal`) |
| `prefer-interpolation` | a single-argument `Std.string(x)` replaceable with string interpolation (`'$x'` for a simple identifier, `'${expr}'` for any other interpolation-safe expression); `Info`, `--fix` rewrites it (an argument whose source carries a quote or `$` is left alone; surrounding string concatenation is not merged) |
| `prefer-final` | a local `var x = …` never reassigned in its scope, replaceable with `final`; `Info`, `--fix` swaps `var`→`final`. Reassignment is detected with the scope-resolved write walker (complete — every write is a structural `=`/`+=`/`++` node), so the fix is always sound. Only a single `var` with an initializer is a candidate (a no-init or multi-declaration `var a = 1, b = 2` is skipped); a never-read `var` is left to `unused-local` (the read gate keeps the two from overlapping); a generic-typed `var x:Map<K, V>` is conservatively skipped (its type-parameter comma is indistinguishable from a declaration separator without tracking `<>`) |
| `prefer-ternary-return` | an `if (cond) return a;` whose immediately-following sibling is a `return b;`, collapsible to a single `return cond ? a : b;`; `Info`, `--fix` rewrites the pair. Only a no-else `if` that is a direct block statement with a value-returning then-branch (`return e;`, or a `{ … }` wrapping exactly one) and an immediately-following value `return` qualifies — a value-less `return;`, an intervening statement, or an inline non-block `if` is left alone. A pair whose one return is a boolean literal and the other is not a provably non-null `Bool` (`if (c) return true; return g();`) is left alone too — collapsing it would make a stuck `c ? true : g()` boolean ternary with no typer-free reduction; a fully-reducible boolean chain is `simplify-boolean-return-chain`'s job, a value ternary still collapses here. The condition is parenthesised only when it binds no tighter than `?:` (a ternary or an assignment); the `else`-form (`if (c) return a; else return b;`) is `redundant-else-after-return`'s job, which de-nests it into the form this check then collapses |
| `prefer-single-quotes` | a double-quoted string literal that can use single quotes (the Haxe default); `Info`, `--fix` swaps the delimiters. A literal whose content has a `$` (the double quotes deliberately suppress interpolation that single quotes would trigger) or a `'` (which would terminate the single-quoted form) is left alone; every other escape (`\"`, `\n`, …) stays valid verbatim, so only the two delimiter characters change. Without types the rare case of a macro that branches on a literal's quote kind cannot be detected — hence `Info` + opt-in `--fix`, never auto-applied. Disabled for a file whose `checkstyle.json` `StringLiteral.policy` prefers double quotes (`onlyDouble` / `doubleAndInterpolation`) |
| `simplify-boolean-ternary` | a ternary with a boolean-literal branch that reduces to plain boolean logic — `cond ? false : x` → `!cond && x`, `cond ? x : true` → `!cond \|\| x`, `cond ? true : false` → `cond`, and the mirror forms; `Info`, `--fix` rewrites it. Any negation is pushed inward by De Morgan (`!(a == null \|\| b == null)` → `a != null && b != null`) so no `!( … )` is left over a compound, and operands are parenthesised only where precedence requires. A real-valued ternary, or one with the same literal both sides (collapsing would drop `cond`'s side effect), is left alone. Composes with `prefer-ternary-return` through the `--fix` fixed-point loop; a guard chain whose conditions are provably non-null `Bool` collapses to one flat boolean `return`, while one whose conditions are a `Call` / `switch` (unprovable without a typer) is reduced on the guard form by `simplify-boolean-return-chain` instead |
| `simplify-boolean-return-chain` | a contiguous run of two-or-more `if (cond) return true/false;` guards (no `else`, each boolean return bare or a `{ … }` wrapping exactly one) closed by a final `return true/false;`, reducible to one flat boolean `return` — `if (a) return true; if (b) return true; return false;` → `return a \|\| b;` (`!a && !b` / `a \|\| !b` by De Morgan); `Info`, `--fix` rewrites it. It reduces on the guard form, where each `cond` is an `if` condition (non-null `Bool` under strict null-safety, since the source already compiles) — so joining with `\|\|` / `&&` is sound and conditions are kept verbatim (an `if (a() == true)` stays `a() == true \|\| …`), succeeding where the ternary path stalls on a `Call` / `switch` condition. Registered before `prefer-ternary-return` so it reaches the chain first; a degenerate chain that would drop a condition's evaluation is left alone |
| `assignment-in-condition` | an assignment (`=`) used as a condition — `if (a = b)`, `while (a = b)`, `do … while (a = b)` — almost always a `==` typo (a Haxe condition must be `Bool`, so the assign even compiles only in the narrow case that matches a typo); `Warning`, report-only (`=` vs `==` is the author's intent). The condition slot is pinned by position (first child for `if` / `while`, last for `do … while`, unwrapping one paren layer), so an assignment in a branch body (`if (c) x = y`) is not flagged |
| `duplicate-ternary-branches` | a ternary whose then- and else-branches are textually identical (`cond ? x : x`), so it always yields `x` and the condition is dead; `Warning`. `--fix` collapses it to the branch only when `cond` is side-effect-free; a side-effecting condition (`f() ? x : x`) is report-only |
| `prefer-bind` | a zero-parameter arrow lambda wrapping a single call with arguments (`() -> f(a, b)`), replaceable with the partial application `f.bind(a, b)`; `Info`, `--fix` rewrites it. A parameter-bearing lambda (`x -> f(x)`), a block body, and a zero-argument `() -> f()` are left alone. `.bind` evaluates the callee and arguments at bind time rather than call time — equivalent for the common case, hence `Info` |
| `redundant-map-iter-key` | a key-value `for` loop that discards its key with `_` (`for (_ => v in m)`), replaceable with `for (v in m)` since Haxe iterates values by default; `Info`, `--fix` drops the `_ => ` prefix. A value-only `for (_ in m)` (no `=>`) is a legitimate ignore-value loop and is left alone |
| `prefer-switch` | an `if` / `else if` chain testing one expression against literal values (`if (x == 'a') … else if (x == 'b') …`), which reads more clearly as a `switch`; `Info`, `--fix` rewrites the chain to a `switch` (each rung's literal becomes a `case`, the trailing `else` a `case _`, then-branch bodies carried verbatim). Flagged only when every rung is an equality (`==`) comparing the *same* discriminant against a constant literal (int / float / bool / null / non-interpolated string), the discriminant is call-free (a `switch` evaluates it once where the chain evaluates it per rung — a behaviour change), and there are at least two rungs. A `!=` chain, a non-equality or mixed condition, differing discriminants, and a non-literal or interpolated operand are left alone |
| `missing-visibility` | a class / abstract member declared without an explicit `public` or `private` modifier; `Warning`. Interface members (implicitly public) and enum-abstract values are exempt. Haxe defaults an unmodified member to `private`, so the omission is not a bug — but stating visibility on every member is a documented project rule. `--fix` inserts `private` (the Haxe default, so a behaviour-preserving change) at the canonical position, after any `override` / meta and before `static` / `inline` |
| `modifier-order` | a member whose modifier keywords are not in the canonical order `override` → `public` / `private` → `static` → `inline`; `Info`, `--fix` reorders the run (each ranked keyword moves to its slot; unranked modifiers stay in place). Purely cosmetic — the order carries no meaning to the compiler. Modifiers with no documented order (`extern`, `dynamic`, `macro`, …) are ignored. A project `checkstyle.json` `ModifierOrder.modifiers` overrides the canonical order (mapped to the ranked kinds; `PUBLIC_PRIVATE` expands to public/private, unranked tokens dropped) |
| `member-order` | a type whose members are not in the canonical declaration order; `Info`, `--fix` reorders them. The order: constants (static fields, public then private), instance fields (public final, public var, private final, private var), constructor, property accessors (`get_*`/`set_*`), instance methods (public then private), static methods (public then private). The sibling of `modifier-order` one level up — that orders one member's keywords, this orders one type's members (the same slot-permutation). Reordering METHODS is always safe; reordering FIELDS can change init order, so the autofix BAILS a container (report-only) when the canonical sort would change the relative order of any side-effecting field initializer, or move a field before a sibling it reads — but only among fields of the SAME init phase (static fields init at class-load, instance fields in the constructor, so a static const reorders freely past instance fields). Pure literal consts (even many at one rank) reorder freely under the stable sort. Members guarded by `#if` conditional-compilation blocks reorder too: each member is collected with the condition it is declared under (nested `#if` conditions conjoin, an identical conjunct deduping), and the autofix regroups the sorted members under regenerated `#if … #end` directives, coalescing a maximal run of one condition into a single block; a doc comment written before a member's `#if` travels with it inside the regenerated block. It bails on an `#else`/`#elseif` (the flattened projection cannot split a then-body from its else-body) or an orphan comment stranded in a directive gap |
| `fragmented-doc-comment` | a declaration documented by SEVERAL adjacent doc-comment blocks (each opened and closed separately, on consecutive lines) instead of one — a confusing duplicate, usually from a doc edit that inserted a second block rather than replacing the first; `Info`, `--fix` merges the run into a single doc comment (block bodies concatenated). A pure comment-token scan (comments are dropped from the query projection). Only `/**` DOC blocks join a run: a plain block (license header, section banner), a blank line, a line comment, or any code between blocks breaks it — so license/section comments are never absorbed. Behaviour-safe (comments never affect compilation) |
| `explicit-type` | a member field with no `:Type`, a function parameter with no `:Type`, or a function with no return type; `Warning`, report-only (a missing type cannot be filled in without inference). A constructor (`new`) is exempt from the return-type rule and enum-abstract values from the field rule; interface members are checked like any other. Stating types everywhere is a documented project rule. The enum-abstract-value exemption follows `checkstyle.json` `Type.ignoreEnumAbstractValues` (default `true`; set `false` to flag untyped enum-abstract values too) |
| `redundant-void-return` | a value-less `return;` as the last statement of a function body — redundant, since control falls off the end to the same effect; `Info`, `--fix` deletes it (with its line). Only the body's final statement qualifies: a `return;` nested in an `if` / loop (where it guards the statements it would skip) and a value-returning `return e;` are left alone — purely structural |
| `unnecessary-block` | a bare `{ … }` statement block nested in another block rather than used as a control-flow body, declaring no local of its own — a pure scope with no effect; `Info`, `--fix` unwraps it (splices the statements into the parent). A block that declares a local is a real scope and is left alone, as is a metaprogramming-reification block — purely structural |
| `prefer-final-field` | a private `var` field assigned only at its declaration — a mutable field the immutable `final` should replace; `Info`, `--fix` swaps `var` → `final`. Flagged only when the field has an initializer, is not a property, its enclosing type is confined to its file (`unused-private`'s gate), and no other write to its name appears in the file (a conservative, complete text scan — `x = …` / `this.x = …` / `x++` all count), so the initializer is provably the sole assignment. A public field is `prefer-final-public-field`'s / `prefer-read-only-field`'s job, a no-initializer field or a field of a non-confined type is left alone |
| `prefer-final-public-field` | a public `var` field assigned only at its declaration and never reassigned anywhere in the project — the cross-file counterpart of `prefer-final-field`; `Info`, `--fix` swaps `var` → `final`. A `FieldWriteIndex` resolves every `recv.field = …` / `this.field = …` / bare `field = …` write to its receiver's declared type, so no reassignment of this type's field exists across the whole file set. Flagged only when the field has an initializer, is not a property, its enclosing type has no subtype, and no write to the field — resolved or unresolved-receiver — targets it; whole-project scope is required for soundness (like `unused-private`) |
| `prefer-read-only-field` | a public `var` field written ONLY inside its declaring class, never from another file — `Info`, `--fix` inserts `(default, null)` after the name, making it externally read-only while internally mutable. Uses the same `FieldWriteIndex`: flagged only when the field is written somewhere (else it is `prefer-final-public-field`'s job), its type has no subtype, no write to its name is unresolved, the type is declared in exactly one file, and no resolved write lies outside that decl — whole-project scope required |
| `unnecessary-null-check` | a comparison against `null` (`x != null` / `null == x`) whose operand is provably non-null, so the test is constant; `Info`, report-only. Type-aware and conservative: the operand must be a plain identifier whose declared type is recovered (`TypeInfoProvider.declaredTypes`) and is either a value type the language never nulls (`Int` / `Float` / `Bool` / `UInt`), or any non-`Null<…>` nominal type while the enclosing type is `@:nullSafety` (and not `@:nullSafety(Off)`). An optional parameter (`?x:T`, nullable despite its annotation), a `Null<…>` / `Dynamic` / `Any` operand, a method-call or field-access operand, and an unannotated local are left alone — so a load-bearing null guard is never flagged. The correct rewrite (drop the guard, or collapse an `&&` operand) is context-dependent, hence report-only |
| `redundant-cast` | a typed cast whose target type already equals its operand's declared type — `cast(x, T)` / `(x : T)` where `x` is declared `T`, a no-op; `Info`, `--fix` unwraps it to the operand. Type-aware: the operand must be a plain identifier whose declared-type SOURCE is recovered (`declaredTypeSources`) and the cast's target-type SOURCE via `castTargetSources`; the two written forms are compared whitespace-insensitively. That is sound within one file — a byte-identical type spelling cannot denote two different types — so it distinguishes `Array<Int>` from `Array<String>` and `haxe.io.Eof` from `sys.io.Eof`, and the unwrap autofix is safe. The untyped `cast x` (no target type), a type mismatch, a non-identifier operand, and an operand with no recovered type are left alone. A bare name and its qualified spelling ARE reconciled when an explicit `import` justifies it — `import haxe.io.Eof; … final x:haxe.io.Eof = cast(e, haxe.io.Eof)` where `e:Eof` is flagged — via `TypeInfoProvider.importMap` (imported simple name → FQN) + `TypeResolver.canonicalTypeName` (qualified path = its own FQN, bare name resolved through the import map, sound because an unqualified name binds to one type per file). A bare name with no matching import (wildcard / implicit-std), or a differing-spelling generic, stays a conservative miss |
| `redundant-null-coalescing` | a null-coalescing `a ?? b` whose left operand is provably non-null, so the right operand is dead — `Info`, `--fix` unwraps it to the left operand. Shares `unnecessary-null-check`'s non-null prover (`TypeResolver.isProvablyNonNull`): the left operand must be a plain identifier whose declared type is recovered (`TypeInfoProvider.declaredTypes`) and is either a value type the language never nulls (`Int` / `Float` / `Bool` / `UInt`), or a non-`Null<…>` nominal type while the enclosing type is `@:nullSafety` (and not `@:nullSafety(Off)`). An optional parameter (`?x:T`), a `Null<…>` / `Dynamic` / `Any` operand, a non-identifier left operand (call / field access), and an unannotated local are left alone — so a load-bearing fallback is never removed. The unwrap is sound because a non-null value makes the right operand unreachable |
| `unnecessary-safe-nav` | a null-safe access `a?.b` (or `a?.m()`) whose receiver is provably non-null, so the `?.` guard can never short-circuit — `Info`, `--fix` rewrites `?.` to `.`. Shares the non-null prover (`TypeResolver.isProvablyNonNull`) with `unnecessary-null-check` / `redundant-null-coalescing`: the receiver must be a plain identifier whose declared type is recovered (`TypeInfoProvider.declaredTypes`) and is either a value type the language never nulls (`Int` / `Float` / `Bool` / `UInt`), or a non-`Null<…>` nominal type while the enclosing type is `@:nullSafety` (and not `@:nullSafety(Off)`). An optional parameter (`?x:T`), a `Null<…>` / `Dynamic` / `Any` receiver, a non-identifier receiver (a chained `a.b?.c` / `a()?.c`), and an unannotated local are left alone — so a load-bearing `?.` is never removed. Unlike `unnecessary-null-check`, the rewrite is unambiguous (`?.` → `.` preserves semantics when the receiver is non-null), hence auto-fixable |
| `redundant-is-check` | an `is` type-check `x is T` that is provably ALWAYS TRUE — `x` is a plain identifier whose declared type already equals the checked type `T` AND is provably non-null; `Info`, report-only. Shares the non-null prover (`TypeResolver.isProvablyNonNull`) and the written-source type comparison (`TypeResolver.sameTypeSource`, whitespace- and import-aware — so `e:Eof is haxe.io.Eof` reconciles via `TypeInfoProvider.importMap`) with `redundant-cast`. Non-null is REQUIRED — `null is T` is `false`, so a nullable operand's check is not constant. Only the always-TRUE, exact-same-type case is flagged: a subtype check (`x:Sub is Base`) is a safe miss, while the always-FALSE direction (two unrelated classes) is handled by the sibling `impossible-is-check`. A `Null<…>` / `Dynamic` operand, an optional param, a non-identifier operand, and a differing checked type are left alone. Report-only: the right rewrite (drop the `if`, keep the body) is context-dependent |
| `impossible-is-check` | an `is` type-check `x is T` that is provably ALWAYS FALSE — `x`'s declared type `S` and the checked type `T` are two **unrelated classes**, so under Haxe single inheritance no value of `S` can ever be a `T`; `Warning`, report-only. Sound via the cross-file class hierarchy `SymbolIndex` already indexes: flags only when BOTH `S` and `T` resolve to a unique indexed CLASS decl (interface / abstract / enum / typedef on either side → open world or implicit conversions → skip), are distinct, and neither is a transitive supertype of the other with BOTH supertype closures **fully resolved inside the index** (`SymbolIndex.unrelatedClasses`). An unindexed supertype link (an external type, or a project file not in the lint set) makes the relation unknown → skip; generics / parametric / `Null<…>` / `Dynamic` operands or checked types never resolve to an indexed class → skip. No non-null proof is needed (`null is T` is also `false`). Every skip is a safe miss. Report-only: the dead branch's right rewrite is context-dependent |
| `impossible-cast` | the cast-sibling of `impossible-is-check`: a runtime-checked cast `cast(x, T)` that can never succeed — `x`'s declared type `S` and the target `T` are two **unrelated classes**, so the runtime `Std.isOfType` test always fails and the cast can never yield a usable `T` (it throws for any non-null value, yields `null` for a null one); `Warning`, report-only. Only the runtime `cast(x, T)` form (`RefShape.checkedCastKind` = `TypedCastExpr`) is inspected — the compile-time `(x : T)` ascription would simply not compile for unrelated types. Same soundness and conservative skips as `impossible-is-check` (both sides a unique indexed CLASS, distinct, unrelated with fully-resolved closures via `SymbolIndex.unrelatedClasses`); operand type via `TypeResolver.identTypeName`, target via the shared `TypeResolver.castTargetWithin`. No non-null proof needed. Report-only: correct the type / drop the cast is context-dependent |
| `redundant-upcast` | completes the cast triad (same type → `redundant-cast`, subtype → this, unrelated → `impossible-cast`): a runtime-checked cast `cast(x, T)` whose operand type `S` is a strict **subtype** of `T`, so the test always passes and the cast is a no-op upcast (an `S` is usable as a `T` without casting); `Info`, report-only. The subtype relation is `SymbolIndex.isSubtype` (extends + implements), so an interface target `cast(impl, I)` is flagged too. Only the runtime `cast(x, T)` form is inspected; operand type via `TypeResolver.identTypeName`, target via `TypeResolver.castTargetWithin`. No non-null proof needed (a no-op for any value). Report-only: an explicit upcast is occasionally load-bearing (overload disambiguation), so removal is left to the author |
| `unreachable-catch` | a `catch` clause that can never run because an EARLIER clause in the same `try` already catches everything it would; `Warning`, report-only. Three covered-by relations: a **catch-all** earlier clause (`RefShape.catchAllTypeNames` — `Dynamic` / `Any` — or an untyped `catch (e)`, which binds the exception root); a **duplicate** (same written type source, reconciled import-aware via `TypeResolver.sameTypeSource` — so `e:Eof` and `e:haxe.io.Eof` match); and **subtype-after-supertype** (the later type transitively extends/implements the earlier one — `SymbolIndex.isSubtype`, the cross-file hierarchy the index builds). The exception type is recovered from the clause header source (between the first `:` and the closing `)`, bounded by the handler block); a non-nominal type (generic / function / anon) yields no simple name → safe miss; the subtype check is simple-name based (an unindexed supertype link ends the chain — a safe miss). Report-only: removing the dead clause vs. fixing its type / order is context-dependent |
| `dead-null-guard` | a null comparison (`x != null` / `x == null`) whose operand is already non-null **by flow** on every path reaching it — a dead guard whose controlled branch is constant; `Info`, report-only. The flow-only complement of `unnecessary-null-check`: non-null-ness comes from a prior `!= null` guard or a syntactically non-null assignment (`x = new T()`, including `x ??= <non-null>`), tracked by the intra-procedural `NullFlow` engine — a per-variable-**name** `Unknown`/`NonNull` lattice with sound joins (after an `if` the two arms' exit states are intersected — an arm that exits via `return`/`throw`/`break`/`continue` contributes no path, so `if (x == null) return;` narrows the fall-through; a `switch` intersects its branches' exit states the same way, plus the no-branch-matched path unless a `default:` or an unguarded `case _:` proves exhaustiveness, with case-pattern captures cleared as fresh bindings; a `try` intersects the body's exit state with each catch clause's, where a clause starts from the entry state with every body-written name cleared — the throw may fire at any point inside — and its catch variable cleared; a loop clears every name it assigns *before* its body so a back-edge carries no stale fact; closure-captured names plus `macro` reification subtrees are excluded). An operand the declared type already proves non-null (`TypeResolver.isProvablyNonNull`) is left to `unnecessary-null-check`, so a redundant null check is reported exactly once. Soundness-first: any uncertainty collapses to `Unknown` (a safe miss), never a false positive. Report-only: the correct rewrite (drop the guard, or collapse an `&&` conjunct) is context-dependent |
| `dead-safe-nav` | a null-safe access `a?.b` whose receiver is already non-null **by flow** on every path reaching it — the `?.` can never short-circuit; `Info`, report-only. The flow-only complement of `unnecessary-safe-nav`: non-null-ness comes from `NullFlow` (a prior `!= null` guard's then-arm, an `== null` guard's else-arm, or a syntactically non-null assignment), and an operand the declared type already proves non-null (`TypeResolver.isProvablyNonNull`) is left to `unnecessary-safe-nav`, so a redundant `?.` is reported exactly once. Same soundness as `dead-null-guard` (any uncertainty → `Unknown`, a safe miss). `--fix` rewrites `?.`→`.` (the same unambiguous rewrite `unnecessary-safe-nav` applies) |
| `dead-null-coalescing` | a null-coalescing `a ?? b` whose left operand is already non-null **by flow** on every path reaching it — the fallback is dead; `Info`, report-only. The flow-only complement of `redundant-null-coalescing`: non-null-ness comes from `NullFlow` (a prior `!= null` guard's then-arm, an `== null` guard's else-arm, or a syntactically non-null assignment), and a left operand the declared type already proves non-null is left to `redundant-null-coalescing`, so a dead fallback is reported exactly once. Same soundness as `dead-null-guard`. `--fix` unwraps to the left operand (the same rewrite `redundant-null-coalescing` applies) |
| `always-null-comparison` | a null comparison (`x == null` / `x != null`) whose operand is provably **null** by flow on every path reaching it — a constant comparison (`== null` always true, `!= null` always false), so the controlled branch is dead; `Info`, report-only. The mirror of `dead-null-guard` (the non-null operand) on the same `NullFlow` engine, now three-valued (`NonNull` / `Null` / `Unknown`): null-ness is established only by flow events — an earlier `x = null` / `var x = null`, or the `== null` arm of a guard narrowing this path — with the same sound joins and conservative `Unknown` collapse (reassignment, loop back-edge, closure capture, `macro` subtree). Only a function unit's own names (its parameters and locally-declared `var`/`final`s) are narrowed — a captured outer variable or an implicit-`this` field is a non-local a call could mutate, so it is left `Unknown` (mirroring the language's own strict null-safety). No point-wise twin (no declared type is "always null"), so unlike `dead-null-guard` there is nothing to defer to. Report-only: the correct rewrite (drop the dead branch) is context-dependent |
| `null-dereference` | a field / method access (`a.b` / `a.m()`) whose receiver is provably **null** by flow on every path reaching it — a guaranteed runtime NPE; `Warning`, report-only. The headline bug-finder of the definite-null arc — the first check that reports an actual defect rather than a redundancy. One node kind covers both forms: `x.field` is a `FieldAccess` on `x`, and `x.method()` a `Call` whose callee is that same `FieldAccess`; the null-safe `x?.b` is a distinct kind that short-circuits and is never flagged. Null-ness comes purely from `NullFlow` (an `x = null` / `var x = null`, or the `== null` arm of a guard) and only a function unit's own names are narrowed, so a static access (`SomeClass.staticFn()`), `this`, or an enum is never reported. Same conservative `Unknown` collapse as the rest of the arc. Report-only — a null dereference has no mechanical fix (the surrounding logic is wrong) |
| `dead-store` | an assignment to a local / parameter whose value is provably never read on any path (overwritten, or the function exits first) — a wasted computation that usually indicates a logic slip; `Info`, report-only. Two forms: a plain assignment (`x = e;` then never read) and a `var` initializer reassigned before any read (`var x = e; x = f;`). Backward-**liveness** engine embedded in the check (the dual of `NullFlow`, over-approximated in the opposite direction — every uncertainty makes MORE names live, so a report means dead-on-all-paths): branches union their arms; a loop keeps every name read anywhere inside it live at its boundaries and branch seams (back-edge safety, and the pre-loop state survives a zero-iteration run — a reassign-then-reassign within one straight-line run is still caught), `switch` / `try` seeded likewise; a `return` clears the state but a `throw` makes every name live (its continuation is an unmodeled `catch`); `break` / `continue` (which project as plain identifier expressions — `RefShape.loopJumpNames`) make every name live; a short-circuit right operand (`&&` / `\|\|` / `??`) or the arguments of a call whose callee chain contains a `?.` evaluate conditionally, so their kills never leak into the skip path; a name a closure reads or writes is excluded entirely, as is a name bound more than once in the unit (name-keyed liveness cannot tell shadowed bindings apart); a multi-binding `var a = 1, b = 2;` (projected as one node) is never reported though its initializers' reads still count; `macro` reification makes everything live; a `'$name'` interpolation counts as a read (`RefShape.stringInterpIdentKind`). Partition with `unused-local`: that check owns the binding never referenced at all (its text scan counts a write as a reference), so a written-then-never-read local is this check's finding, and a dead `var` initializer is reported only when the name IS referenced elsewhere in its enclosing scope; a `final` initializer is never flagged. Report-only: deleting a store is behavior-preserving only when its right-hand side is side-effect-free — an autofix promotion can follow once the engine has earned trust |

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
