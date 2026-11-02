# How a layout rule stays small — audit for a decision

Role: journal. Every number is a reading of main at `3956aad58`, 2026-11-02. No code landed with this document.
The prototype lives on the scratch branch `scratch/hxqb-proto-WRITER-RULES-AUDIT` (`487d69ff6`), never to be merged; the
measuring scripts are in its `scratch-audit/`.

## The answer

Your suspicion is right about the symptom and needs one correction about the cause.

1. **A rule does not cost hundreds of lines on the day it is added.** The median rule cost 64 lines of macro code. Adding
   flags accounts for 12 % of all macro lines ever written. The cost is what comes after: a rule is an `if` inside
   a generated emitter, so every later fix has to happen inside the macro as well (38 % of all lines written).
2. **The macro writes code it has no need to write.** A rule usually looks at finished Docs, and finished Docs exist at
   write time, in ordinary Haxe. A macro is only needed to walk the grammar shape. So the answer to "maybe we need proper
   rule code generators?" is the reverse: **the macro should generate less. It offers a few generic hooks, a grammar flag
   names a plain Haxe function, and the rule is that function.** No new rule language.
3. **The proof holds on the hardest case.** Case sibling symmetry, retired by H8 at 1,097 source lines (455 of them code),
   came back at +219 / −21 lines (about 170 code), byte-equal to pre-H8 on everything measured but one fixture at one width, and
   no worse one-pass. Review caught a form the first version missed and every tree here lacks (§ 3.1), so "everything measured"
   is the honest limit of that claim. It is not "tens of lines": about 130 code lines without the one-pass offer, about 170 with it.
4. **A wrap rule moved the same way** lost 117 macro lines for 62 runtime lines, byte-equal. **A gap rule fits the form but
   saved nothing**, because it was already small. The expensive gap machinery was not tried.
5. **Stop early, and know what the stop buys.** Two slices land the hooks, and then a new rule stays out of the macro only on the
   shapes the hooks cover: 76 of 829 flag uses (9 %) sit on them today, and 135 of 221 flags belong to families with no hook at
   all (§ 2.1). So this slows the growth in part and does not stop it. Moving the old rules is optional, and most of it should
   wait for CANON or not happen.

### What you decide

| # | Question | Options |
|---|---|---|
| 1 | Which trigger for case sibling symmetry | `anyBreak` (any branch below its label moves all) or `widthOnly` (only an over-wide branch does). Real output is in § 3.2 |
| 2 | Land the prototype as the small config key | `sameLine.caseSiblings`, default `off`, so nothing moves until a config asks |
| 3 | Adopt "a new layout rule is a function behind a hook" | yes means steps 1–2 of § 5 and then measure. It covers only the shapes of § 2.1 |
| 4 | Go past the stop point | only after that measurement, § 5 |

## 1. Inventory

### What exists

| Measure | Reading |
|---|---|
| `@:fmt` flag names in the grammars | **221**, used 829 times across 367 `@:fmt` annotations (Haxe alone: 220, 823, 361; the queue line said 178). Counted by a balanced scan over comment-stripped source |
| `src/anyparse/macro`, `strategy/` included | 48,645 lines, of which 25,819 code; the rest is comments and blanks |
| `Writer*` + `Trivia*` macro files | 30,194 lines, of which 15,101 code |
| Macro functions | 1,450, of which only **160** name a flag (4,953 code lines) |
| Code in functions naming no flag | 18,997 lines: 14,915 reached from several flags, 2,480 from exactly one, 1,602 from none |

Half the macro by line count is prose. That is why H8's "about 1,300 lines" reads larger than the code it removed.

### What one flag costs

Lines attributed to one flag today (a function's code split evenly among the flags it names, plus helpers only that flag
reaches; the call graph is by name, so it over-reaches): **median 11, p90 57**, maximum 874 (`dropSingleStmtBraces`, which
is mostly that over-reach). Attribution covers 7,434 of 25,819 code lines. The other two thirds belong to no one flag.

What the commit that introduced a flag added, over the 148 commits that introduced exactly one:

| Area | Median | p90 | Max |
|---|---|---:|---:|
| macro | 64 | 159 | 368 |
| grammar (mostly doc comments) | 33 | 104 | 237 |
| format | 0 | 64 | 908 |
| tests | 45 | 213 | 455 |

After that, the median flag's name appears in the added lines of 10 commits (p90 24, max 89).

### Where the macro lines actually came from

875 commits added 132,128 macro lines and deleted 83,569. Classified by subject words, so read this as rough:

| Cause | Lines added | Share |
|---|---:|---:|
| commit introduces a flag | 15,503 | 12 % |
| layout behaviour fixed or extended | 50,552 | 38 % |
| restructuring and cleanup | 51,801 | 39 % |
| comments and trivia | 7,638 | 6 % |
| source layout, `keep` | 3,410 | 3 % |
| one-pass compensation | 3,224 | 2 % |

137 of the 221 flags existed by the end of May, with the macro at about 1 MB. It is 2.2 MB today with 84 more flags.

### Why one rule still gets expensive: the multipliers

- **A rule has no home.** It is a branch inside a shape emitter (Star, Ref, Pratt…). `docs/strategies.md` says so: "a flag
  is a branch INSIDE one of those emitters, not a unit of its own".
- **Two sides.** 51 flags (23 %) are named on both sides of the plain/trivia module split.
- **Plumbing.** `triviaTryparseStarExpr` takes 40 positional parameters, `triviaBlockStarExpr` takes 38, and context records
  carry the same values again. Each new input crosses all of them.
- **Options.** 208 option fields, 25 of them `_`-prefixed context channels. A user knob touches 5 places.
- **Width probes.** `Doc` has 13 `If…Exceeds/Fits` constructors, mentioned 851 times in code across core, format and macro (and
  244 more in comments), about 65 each in code. A new probe is about 60 switch arms: `IfIndentWidthExceeds` has 56. They live in `Renderer` (4,399 lines), `DocMeasure` (1,146), `WrapList` (4,877).
- **One-pass compensation.** A decision that reads the source's line shape needs `BreakCommit` machinery so the next rewrite
  agrees with this one.

### H8 as the specimen

The 1,097 deleted source lines: 642 comment or blank, 455 code. Of the code: **231 macro plumbing, 136 AST predicates in the
grammar, 75 runtime, 13 option fields and grammar flags**. What that code did:

- wrote every case element twice, once to measure and once to emit;
- carried a marker down the tree so nested switches would not cost 2^depth because of that double write;
- wrote three AST predicates to answer what the Doc already shows (is this body below its label, is it control flow);
- wrote a flattener because a `#if` region was one opaque element to the AST walk;
- passed the verdict through option fields to reach the bodies.

All five exist only because the decision was made *before* the Docs were written. See § 3 for what is left when it is made
after.

### What CANON-1..6 removes anyway

The Q-AUTH reading, on the tree of its day: about 1.0–1.5k lines of macro/format/core, plus the 49 + 42 grammar flag uses for layout and tokens,
plus the compensation (about 0.7k lines, 2.3k of tests) if CANON-6's re-measure allows. In this audit's terms: the whole
`source` family of § 2 (11 flags), the `keep` arms inside `placement`, and the offer inside the prototype.

CANON removes branches and does not change how the next rule is written: about 210 flags and the multipliers stay, except the
source-reading one. **CANON and this audit are complementary and neither replaces the other.**

## 2. Families

Macro lines are today's attribution from § 1, so `gap` reads low: its cost sits in the cascade files no flag names.
"Sites" are flag uses. "Intro" is what the flags' introducing commits added to the macro.

| Family | Flags | Sites | Macro lines | Intro | What the rules do | Smallest form | Proved? |
|---|---:|---:|---:|---:|---|---|---|
| spacing | 51 | 225 | 1,192 | 1,330 | a space or not between two tokens, by a knob | one flag `space('<knob>', side)`; no new Doc. `LEAD_POLICY_FLAGS` already has ten flags whose name is the knob's name | no |
| placement | 40 | 173 | 1,474 | 2,783 | body on the head's line or below, braces | a runtime `(head, body, policy) → Doc`; `BodyFit` is already half of it | no; do after CANON |
| wrap | 43 | 144 | 1,451 | 3,165 | breaking by width | `listLayout('<fn>', '<knob>')`: the macro hands over the item Docs. Separately, one `IfFits(measure, n, brk, flat)` in place of the 13 probes | one rule on one Star shape; the probes no |
| gap | 31 | 98 | 660 | 3,504 | blank lines between siblings | `gapRule('<fn>', '<knob>')`; the ctor cascade (2,151 lines in two files) as a table read at write time | one rule on one Star shape; the cascade no |
| sibling | 12 | 30 | 306 | 802 | siblings share a decision | slots plus one Doc pass over the list | **yes** |
| tokenEdit | 11 | 41 | 1,133 | 640 | a token added or dropped | really transforms, § 4: AST → AST before the write. `preWrite` exists | no |
| source | 11 | 26 | 725 | 1,345 | reads the author's line breaks | CANON deletes them | — |
| context | 12 | 50 | 153 | 1,115 | hands a fact down the tree | shrinks by itself when decisions move after the write; no form of its own | partly: the sibling channel went |
| comment | 7 | 37 | 326 | 690 | where a comment goes | stays hand-written | not worth it |
| other | 3 | 5 | 14 | 130 | | | — |

Doc combinators this needs: **none new** for what was proved. The slot is an existing `IfIndentWidthExceeds` holding a
negative vote. What holds of it is narrower than "every walker takes the flat branch":

- **Flat side:** the renderer and the flat-side walkers (`WrapList.flatLength` among them) take the flat form, because a negative width
  never exceeds. Those are the ones the slot relies on, and it is why an unresolved slot renders as "this sibling decides alone".
- **Break side:** `WrapList.isTopLevelTernary`, `topLevelOperatorClass`, `breaksAtOwnAddSubOperator`, `lastVisibleText`, `isTopLevelChain`,
  `DocMeasure.breakableHeadStep` and `Renderer.unresolvedAlternative` take the break branch only. `DocMeasure.scanTailAt` and
  `Renderer.twoSides` read both.

So the slot is safe only while nothing but the flat side sees it unresolved, and that depends on every whole-switch list opting in.
Measured with those nine walkers plus the renderer's probe arm instrumented for a negative width: **0 reaches** on all four trees of § 3.1
and on its two switch-open fixtures. The positive control is the same engine with the switch-open list not opted in: **12 reaches**
on those two fixtures, all at the renderer, so the instrument fires and the slots there stayed unresolved through the render.
Those are the walkers read by name, and not all 56 code mentions were read. Nothing structural enforces the opt-in: a new list of case
branches without `siblingShare` would silently ship unresolved slots. A landing should fail the build on that, or carry a guard.

The reuse is a trade: it is cheap, and it is also an overloaded number with that hole in it. A dedicated constructor would make the
hole a compile error in every walker and costs about 60 switch arms, which is exactly what unifying the probes would remove. Decision 3
does not depend on this choice, but **"no new constructor" is a prototype's shortcut and not a finding.**

The three forms keep invariants 3, 4 and 6: one writer and no re-parsing, since a pass runs on Docs; a flag names a function
in the plugin's own package, so the macro spells less grammar than today (it hard-codes `implementsExtendsWrap` now);
the flag points at a real Haxe path, checked by the compiler, with no hidden meaning.

### 2.1 What the hooks cover

A hook is wired into one Star emitter, and it is not a general door out of the macro. As prototyped:

| Hook | Wired into | Family | That family's uses on this shape |
|---|---|---|---:|
| `listLayout` | `@:trivia @:tryparse` Stars (`triviaTryparseHeritageExpr`) | wrap | 25 of 144 |
| `gapRule` | `@:trivia @:trail` block Stars (`blankAroundMultilineExprs`) | gap | 41 of 98 |
| `siblingShare`, `siblingSlot`, `siblingLead` | block Stars for the list, tryparse Stars for the body | sibling | 10 of 30 |

**76 of 829 flag uses (9 %) sit on a hooked shape in a hooked family.** 25 of 221 flags have at least one such use, and 21 have only such
uses. That is an upper bound on what could move, since being on the shape does not mean a rule fits a function over Docs.

`wrapRules` itself is none of these: its 29 uses are on 18 plain Stars, 8 `@:sep` trivia Stars and 3 constructors, so `HxClassDecl.typeParams`,
right beside the ported clause list, does not pass through `listLayout`. **135 of 221 flags (61 %), in spacing, placement, tokenEdit, source,
context, comment and other, have no hook at all.**

## 3. The proof

### 3.1 Case sibling symmetry in the proposed form

A body emits a **slot** holding both its forms (below the label, or its own) and a vote: *measure me*, or *I lead*. The list
runs one pass over its finished Doc: count the slots, take the widest measurable unit, write one verdict into every slot.

```haxe
// grammar: the only additions
@:fmt(..., siblingShare('caseSiblings')) var cases: Array<HxSwitchCase>;    // HxSwitchStmt, HxSwitchStmtBare
@:fmt(..., siblingShare('caseSiblings')) var cases: Array<HxSwitchCase>;    // HxCondSpliceSwitchOpen: a switch opened inside #if
@:fmt(..., siblingSlot('caseSiblings')) var body: Array<HxStatement>;       // case and default bodies
@:fmt(padLeading, siblingLead('caseSiblings')) var rest: Array<HxStatement>; // a label-splice region always leads
```

So it is four declarations of three flags on six grammar sites, not one flag: the scope (a switch, and a switch opened inside `#if`, which
IS the whole switch with no list above it), the member, and the one shape that always leads.

Gone against pre-H8: the double write and with it the exponential guard, all five generated predicates and the flattener (a
`#if` region's cases are simply found in its Doc), the `_caseSiblingFlatWidth` and `_caseSiblingOffer` channels, and the sentinels'
travel through options.

| | H8 removed | Prototype `c6cc45a93`, `d9d1c5e82` |
|---|---:|---:|
| Source lines | 1,097 | +219 −21 |
| Code lines | 455 | about 170 |
| of which the rule itself | | `SiblingShare.hx`, 134 code (160 lines) |
| of which the one-pass offer | | about 40 of those; CANON-6 may remove it |
| Macro wiring | 231 code | about 25 |
| Config key | | 10 lines |

Tests are not counted on either side: the prototype has none of its own, so the retired 538-line test still has to be ported.

### Byte comparison against the pre-H8 engine (`288899429`)

Under `sameLine.caseSiblings: anyBreak`, with all three prototype rules in the engine:

| Tree | Files | Differ from pre-H8 | Main differs from pre-H8 (shows the test can tell) |
|---|---:|---:|---:|
| corpus, each fixture's own config | 946 | 0 | 0 (no fixture sets `fitLine`, so this row proves nothing) |
| corpus, `fitLine` forced | 946 | 0 | 13 files, 138 lines |
| Pony copy, its config + `fitLine` | 680 | 0 | 50 files, 755 lines |
| anyparse `src` + `test`, `fitLine` forced | 2,667 | 0 | 420 files, 6,349 lines |
| sweep: 8 configs (width 40–140, align flip) over corpus + Pony + 159 fixtures lifted from 18 pre-H8 test files | 14,280 | **1** | — |

With the key off the prototype equals main on all four trees.

**A form the trees above cannot see.** The first version of the prototype opted in only `HxSwitchStmt` and `HxSwitchStmtBare`, and every row
above read as it does now, yet it was wrong: a `switch` opened inside `#if` (`HxCondSpliceSwitchOpen`) kept the mix under `anyBreak`.
Review found it by reading what H8 deleted. Two fixtures, one with an over-wide `case 2` and one with `case 2: if (x) y;` beside
`case _: a; b;`: pre-H8 moves all siblings, main and that first version do not. With `siblingShare` on that list (`d9d1c5e82`), both
are byte-equal to pre-H8. **So 0 in the table means 0 on these trees, and this form needs a pin of its own.**

**The one divergence**: `sameline/issue_306_case_bropen_keep_curly_both` at width 100. A case label holds a source break after
`case`, so pre-H8 measured the whole unit as unmeasurable and it had no vote. The prototype measures the label's last line
plus the body, finds it over the width, and spreads, so `case _:` goes below its label. The line really is over the width, so
the prototype's answer is the more symmetric one. It is still a divergence, and the mechanism comes from reading the output, not
from instrumenting the run.

The first run differed in 3 anyparse files. Two fixes closed them: empty bodies had no slot, and a glue-refused body whose unit
carries a trailing comment has to lead. A third change, tying the offer to the widest break through an alias token as pre-H8 did,
was kept without separate proof that it is needed. So **the form is not self-evidently right. The byte test made it right, and
that test is the part that carries over to any later port.**

### One-pass

`fmt --one-pass --list` from source on corpus, Pony and anyparse: the same result for pre-H8, main, and both prototype triggers.
Pony and anyparse report none. The corpus reports the same three pre-existing files (`lineends/issue_598_multiline_comment_var`
and two `whitespace/issue_583_*`).

A warning about what this proves: **those trees do not exercise the offer.** With the offer cut out, all four stay byte-equal and
one-pass clean, and only the retired pin's own fixture (`testPivotCaseUnitDoesNotLeadTheSiblingSpread`) fails `--one-pass`. The
prototype with the offer passes that fixture with the same bytes as pre-H8. So keep that pin when landing.

### Not run

The test suite, the arms and the `--jvm` probe, on the scratch branch. `FmtFlagOwnershipTest` would fail as it stands, because the
new flags are not in `docs/strategies.md`. The plain writer has no symmetry; by H8's diff the same was true before it. `fmt` time over anyparse was
20.1–21.0 s for every engine in one run each, so the removed double write shows no measurable gain there; bundle size equals
main (+67 bytes), 19 KB under pre-H8.

### 3.2 The two triggers on real output

Both are in the prototype, one `if` apart.

| From main to | corpus forced | Pony | anyparse forced |
|---|---:|---:|---:|
| `widthOnly` | 2 files, 12 lines | 10 files, 111 lines | 82 files, 1,336 lines |
| `anyBreak` | 13 files, 138 lines | 50 files, 755 lines | 420 files, 6,349 lines |

A branch **too wide** for its line. `off` leaves the mix; `widthOnly` and `anyBreak` both fix it:

```haxe
// off (today)
return switch d.length {
	case 1: fromSeconds(d[0] == '' ? 0 : d[0].parseInt());
	case 2: fromSeconds(d[1] == '' ? 0 : d[1].parseInt()) + fromMinutes(d[0] == '' ? 0 : d[0].parseInt());
	case 3:
		fromSeconds(d[2] == '' ? 0 : d[2].parseInt()) + fromMinutes(d[0] == '' ? 0 : d[1].parseInt())
			+ fromHours(d[0] == '' ? 0 : d[0].parseInt());
	case _: throw 'Invalid time format';
}

// widthOnly, anyBreak
return switch d.length {
	case 1:
		fromSeconds(d[0] == '' ? 0 : d[0].parseInt());
	case 2:
		fromSeconds(d[1] == '' ? 0 : d[1].parseInt()) + fromMinutes(d[0] == '' ? 0 : d[0].parseInt());
	case 3:
		fromSeconds(d[2] == '' ? 0 : d[2].parseInt()) + fromMinutes(d[0] == '' ? 0 : d[1].parseInt())
			+ fromHours(d[0] == '' ? 0 : d[0].parseInt());
	case _:
		throw 'Invalid time format';
}
```

A branch below its label **for its shape**, not its width. Only `anyBreak` moves the siblings:

```haxe
// off, widthOnly
return switch [a.listener, b.listener] {
	case [LFunction0(a), LFunction0(b)]: SignalTools.functionHashCompare(a, b);
	case [LEvent0(a, _), LEvent0(b, _)]: a == b;
	case [LBind1(_, a), LBind1(_, b)]: a == b;
	case [LBind2(_, a1, a2), LBind2(_, b1, b2)]:
		a1 == b1 && a2 == b2;
	case _: false;
}

// anyBreak
return switch [a.listener, b.listener] {
	case [LFunction0(a), LFunction0(b)]:
		SignalTools.functionHashCompare(a, b);
	case [LEvent0(a, _), LEvent0(b, _)]:
		a == b;
	case [LBind1(_, a), LBind1(_, b)]:
		a == b;
	case [LBind2(_, a1, a2), LBind2(_, b1, b2)]:
		a1 == b1 && a2 == b2;
	case _:
		false;
}
```

`anyBreak` is the rule you called symmetry and is exactly pre-H8. `widthOnly` is the smaller diff and keeps K14's per-branch
reading for short branches, but leaves the second shape mixed. A multi-statement branch behaves like `a1 == b1 && a2 == b2`
above: only `anyBreak` spreads it.

### 3.3 A wrap rule and a gap rule

**Wrap: the clause list after a declaration head** (`heritageWrap`, `6e57c25f5`). The whole rule, cascade included, moved from
generated code to `ClauseWrap.layout(items, cols, rules, lineWidth)`. The macro keeps writing the items and keeps the
comment-bearing path, which any list needs.

| | Lines |
|---|---:|
| macro | +7 −124 |
| runtime `ClauseWrap.hx` | +62 |
| grammar, 4 flags | +8 −4 |
| net | −51 |

The next list-layout rule on a `@:trivia @:tryparse` Star costs 0 macro lines; on any other Star shape it needs the hook wired there first
(§ 2.1). Plain Haxe over Docs is also testable without building a writer. The flag now
names its knob, so the macro no longer spells `implementsExtendsWrap`.

**Gap: the blank around multi-line members** (`blankAroundMultilineMembers`, `1aea73ee9`). Macro +7 −17, runtime +5, grammar +10 −5,
so net 0. It fits, and the next rule of this shape on a trivia block Star costs 0 macro lines, but this rule was small to begin with. **This is not
evidence for the expensive gap code.** The ctor cascade (`WriterCtorBlankLowering`, `WriterCascadeLowering`, 2,151 lines) was not
tried, and a gap that must read a comment or a source blank needs more than this hook hands over.

All three together passed every row of the comparison above.

## 4. Transforms and lint fixes are rules too

`src/anyparse/check`: 209 rules, 388 files, 138,890 lines, 76,914 code. Median rule file 169 code lines, p90 432.

A sample of every fifth rule (42), classified by reading each one's stated contract, not its code:

| Class | Sample | Scaled to 209 | Examples |
|---|---:|---:|---|
| **Pure** `pattern → rewrite` | 11 | about 55 | `Std.isOfType($x, $t)` → `($x is $t)`; `new Map()` → `[]`; `prefer-lambda-expression-body`, `prefer-count` |
| **Pattern plus one guard** from the query layer (use count, type, "always exits") | 16 | about 80 | `unused-local`, `redundant-else-after-return`, `prefer-keyvalue-loop`, `redundant-map-iter-key` |
| **Stays hand-written**: flow, cross-file, census, trivia | 15 | about 75 | `possible-null-dereference`, `map-as-set`, `unused-public-member`, `string-literal-dup`, `prefer-comprehension` |

The sampled pure rules average 154 code lines. At about 5 lines each that is **at most about 8k code lines, 10 % of `check`**.

**That is an upper bound, and a check on Pony says why.** The bare pattern against the rule's real finding count:

| Rule | Lint | `hxq search` on the pattern |
|---|---:|---:|
| `prefer-map-literal` | 25 | 25 |
| `prefer-is-operator` | 4 | 10 (the rule's contract also requires the argument to name a type; not checked site by site) |
| `prefer-safe-nav-comparison` | 0 | 7 (not diagnosed; the rule's contract names a Haxe version gate) |

Lint ran with `--no-oracle`. Two more patterns, for `prefer-lambda-expression-body` and `simplify-negated-compound`, found nothing on
either side.

So even "pure" rules carry guards, which is where their hundred-odd lines go, and a bare pattern would have flagged and rewritten
sites the rule refuses.

The language has `hxq search` and `hxq rewrite` with `$x` metavariables and parenthesis-safe splicing. It lacks declaration
patterns (`search` covers expressions and statements), list metavariables for "and the rest of the block", and a way to name a
guard.

**Proof obligations for a declarative rule**, each already carried by hand somewhere:

1. A repeated `$x` means structurally equal and free of side effects, or the rewrite changes evaluation count.
2. The result re-parses to the intended tree (the splice does this).
3. No comment inside the matched span is lost.
4. A `#if` crossing the span refuses.
5. A name in the pattern (`Std`) resolves to the real one, not a shadow.
6. Language-version gates are stated.
7. The rewrite converges against other fixes.
8. Each rule still needs a pin that fails when it is mutated. A rule derived from one declaration cannot be pinned by a fixture built
   from the same declaration.

`FixVerifier` is the natural owner for the ones it does not already check; which those are was not audited here.

**The same form on the writer side** is the `tokenEdit` family: 11 flags, 1,133 attributed macro lines. An AST → AST step before the
write keeps invariant 3 and takes `dropSingleStmtBraces` out of the emitters. Not prototyped.

**AS3→Haxe, on paper only (frozen).** The mechanical share fits: `for each ($x in $e)` → `for ($x in $e)`, `Vector.<$T>` →
`Vector<$T>`. It needs what the form lacks: the pattern in one grammar and the template in another, plus a conversion between the
two ASTs, whereas `TransformLowering` works inside one grammar. The other share is type-driven (array versus vector methods, method
closures, getters) and needs the typer, and that is the hard part of a converter. No percentage: nothing was counted.

## 5. Migration

Costs in queue-line difficulty (`lib/difficulty.md`) and lines; H8, a comparable slice, took 544k tokens.

| Step | What | Cost | Removes | Risk |
|---|---|---|---|---|
| 1 | Land case sibling symmetry from the prototype. Port the retired test and carry two pins it must keep: the offer's fixture (§ One-pass) and the switch opened inside `#if` (§ 3.1). Close the opt-in hole of § 2 | one slice, 6–7 | adds about 170 code lines; default off, so 0 output change | low; the byte test exists |
| 2 | Land `listLayout` and `gapRule`; a new layout rule on a hooked shape uses a hook | one slice, 5–6 | −50 lines; a new rule stays out of the macro on 9 % of today's uses (§ 2.1), and the rest still grow it | low |
| **STOP** | **Measure the next 5 new rules: macro lines each, against the median 64, counting eligible (hooked shape) and non-eligible rules separately.** A run of non-eligible rules says the next hook to build, or that this was not worth it | | | |
| 3 | CANON-1..6 as queued, independent of this audit | as queued | 1.0–1.5k lines, `source` family | as queued |
| 4 | `spacing` to one flag | 1–2 slices, 6; mechanical through hxq | est. 50 flags → 3, about −1k macro lines; 0 output change | low; estimate unproved |
| 5 | The 13 width probes into one `IfFits` | one slice, 7 | est. most of the 851 code mentions; a dedicated slot ctor becomes cheap | medium, the renderer is hot |
| 6 | `placement` to runtime, after CANON | re-measure first | up to about 2k | high |
| 7 | Gap cascade as a table | prototype first | up to about 2k | high; not tried |
| 8 | Lint: new mechanical rules as `pattern → rewrite` | language work, 2–3 slices, 7 | 0 at first | medium |

Steps 4–8 show estimates, not measurements, apart from the mentions and line counts they start from.

### What is not worth doing

- **A rule language for layout.** A function is shorter, typed and debuggable. The rules that matter need measuring, and a DSL would
  grow into Haxe.
- **Migrating the 55 mechanical lint rules wholesale.** They work and have pins. At most 10 % of `check`, against real risk. Use the
  form for new rules only.
- **Comments and trivia.** The hard, exact part, and the corpus depends on every branch.
- **`placement` before CANON.** It would port `keep` arms that are about to be deleted.
- **Moving old rules for tidiness alone.** The hook's value is the next rule. The wrap port saved 51 lines; the gap port saved none.

### What the current design does better

- **No interpretation at write time.** Generated code knows its shape at compile time, and a hook call stays a direct call, but every pass
  over a finished Doc is a new walk over it.
- **Rules that read the AST or the trivia keep working there.** A Doc has no idea about comments, source blanks or statement kinds: the
  prototype still takes `caseBodyRefusesFlat` and `caseBodyControlFlowRoot` from the AST, and a Doc pass cannot do what they do.
- **A pass that runs late can only choose among forms already built.** That suits "share a decision", but a rule changing what gets built
  belongs earlier, as a transform.
- **It is proven.** 19,214 tests, and a corpus that has absorbed many edge cases. Every port pays to reproduce those, as this one's first run
  showed.
- **An overloaded width in the slot is a shortcut**, tolerable in a prototype, and the first thing a reviewer should challenge.

## Reproducing

On the scratch branch, `scratch-audit/`: `scan.js`, `inventory.js`, `history.js`, `growth.js`, `families.js`, `coverage.js`, `mentions.js` (§ 1–2), `harness.js`, `sweep.js`
(§ 3; reference engine `node bin/dev.js base-engine a94950485~1`), `rulesample.js` (§ 4). Families are a hand classification by name, and
"cause" in § 1 goes by commit subject words.
