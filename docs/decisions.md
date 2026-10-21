# decisions — hypotheses this project tried and refuted

One line per idea that was proposed, believed, or half-built and then **did not survive contact
with the tree**: what was tried, why it is not here, and the commit that holds the detail. It
exists because git is searchable by text and not by idea — the next person to have one of these
thoughts should find the answer here instead of re-deriving it.

**What goes here:** a refutation. "We wanted X, we looked, and X is wrong / already there /
unreachable." One sentence, no chronicle.

**What does not:** a measurement. A reading is of one tree at one moment — it belongs in the
commit message that made it and in the campaign ledger, never in this file and never in a code
comment (`doc-measurement-claim` reports the latter). A line here may cite the number that
decided the question; it may not become a record of runs.

**Where the detail is:** the named commit. Most are merges of a slice branch, so read them with
`git log <sha>^1..<sha>^2` — `git show` on a merge prints the merge line and nothing else.

---

- `interfaceRequires` was to be priced as the cost of the widest index per candidate → a CPU
  profile of the narrow run put the whole cost in reading and parsing the declared scope under
  `widest()`; the interface gate was never called at all — `8fcb97e3`
- `subtypeMemberNames` was to get a memo for the same reason → it is called nowhere on this
  project's own sources and a handful of times on the largest external tree, so the memo would
  have been state without pain — `8fcb97e3`
- a method used as a value was to be treated as unsafe under `-dce full` → it compiles and runs
  on the project's Haxe; only reflection with a static call site is the real hazard, and that is
  what the gate reads now — `1d12e591`
- `patch`'s doc guard was to compare a declaration count across two containers → both counts
  already read the same container, so the guard needed a different question (the bytes the block
  documents), not a second container — `961e6d17`
- `&&=` and `||=` were to be added to the mutating-operator table → the language has no such
  operators and refuses them outright; only `>>>=` was really missing — `8fcb97e3`
- the grammar's `PlainMeta` constructor was to be given a projection → it is unreachable by
  construction: the sibling pattern is the same regex minus one optional group at the same
  anchor, so the sibling wins on every input — `f743471b`
- four rules were believed to read the subtype adjacency key that a simple name had collided in
  → the readers are eight, reached through four different accessors; the fix had to be at the
  key, not at the callers — `440ca9a5`
- `hxformat.json` was believed to be read by two formatting engines, so a change to it had to
  keep both happy → the other engine is never run over this tree; the only fork arm reads the
  fork's own config — `050c91bb`
- the string-literal table carve-out was to key on ARITY, the number of entries → the
  discriminator is homogeneity: a table is a collection literal of only literals, at any size and
  in the map spelling too — `a3588740`
- a stale doc claimed a live suffix guess (`endsWith('Lit')`) in the grammar-agnostic layer →
  both sites were plain membership tests; the guess had already been removed and only its doc
  survived — `9a16cbdc`
- a new `RefShape` field was proposed for the binder kinds → every kind already had a field; what
  was missing was a DERIVATION over eleven of them — `c07d514a`
- two builds of one commit were believed to drift in test counts → three independent builds of
  the same commit produced byte-identical counts; what moves the number is the ambient environment — a
  `haxelib setup`'d `$HOME`, a populated `bin/` — `53d58cd4`
- the addressing layer was believed to fail SILENTLY on a bad selector → it always exited
  non-zero with a name hint; what it lacked was a clause naming the KIND — `abda1bcd`
- a glue form was believed unable to force a body break, so a new primitive was scoped → glue
  already breaks the body itself, and the probe that shows it is one element wider — `56a02109`
- `comment-rewrite`'s refusal on an edit that widens a comment was filed as a defect → it is the
  intended guard against a silently over-wide line, and the way out is already named in its own
  message — `da0be5b8`
- metadata arguments were believed invisible to the query layer → they are children of the
  metadata node; only the metadata NAME is filtered, by the symbol-name rule — `e52665e5`
- the percent-share guard was to refuse a sign not followed by a digit or `(` → the `(` half
  silences the readings this project writes (`57% (anyparse)`, `9 % (5 of 54)`) and refuses no
  arithmetic the digit half already misses; the guard that works is per LINE — `99a8c023`
- the recording verb was to be read as SENTENCE-INITIAL and capitalised → a wrapped sentence
  starts its line mid-clause, this project writes emphasis in upper case, and the parenthetical
  and dash-introduced readings are the larger half; the discriminator is clause POSITION —
  `99a8c023`
- the renamed clone reading was to CONTAIN the exact one → it contains neither by coordinate nor
  by region: an earlier-starting renamed run suppresses the later-starting exact one through the
  earliest-start occurrence filter, so the exact run's tail can lie outside every renamed span.
  The two readings OVERLAP; a consumer takes their union, never one for the other — `3c85dfd8`
- the renamed reading's bare-declaration clones were to be a CONTENT-GATE artefact (the gate
  summed each copy's raw bytes, names included, so a name-heavy run was thought to pass on its
  names alone) → a declaration's bytes are mostly its keyword, type and initializer, not its
  name: measured on the renumbered text the gate drops about one finding in eighty and leaves
  nearly every bare-declaration run standing, and the exact reading reports the same runs under
  identical names; that population is STRUCTURAL (a run of nothing but local declarations has no
  extraction value under either reading), not a threshold question — and a statement-count floor
  keeps logic and declaration runs in the same proportion, so it does not separate them either —
  `c9fbce70`
- the writer's de-brace support was to move its two `'ExprBody'` literals onto
  `RefShape.expressionBodyKinds`, beside the siblings that went there → there is no `QueryNode`,
  `GrammarPlugin` or `RefShape` at the writer layer (the values are the writer's own enums,
  reached by reflection), so a kind-name seam has nothing to answer, and the two literals are a
  small fraction of the ctor names in that module, none of which has a seam either; paying the
  debt is a per-grammar de-brace POLICY the writer lowering asks for — `dd059696`
- `BodyFit.fitLineLayout`'s whole `flat != -1` arm was to be gated on the body's HONEST full flat
  width → it reproduces the fork on a brace-less function body and turns one corpus fixture and
  ten unit pins red, because the same arm places the two-link body of a statement `for`, where
  the head-fit glue is what the fork wants; the seam is shared by callers whose safe default
  points opposite ways, so a fix belongs at the function-body site — `dd059696`
- `WrapList` was to be split to clear its `oversized-type` finding → a cluster read puts the large
  majority of its members in ONE component and the obvious `shape*` seam lands inside that
  component, so cutting it leaves the type over both caps; clearing the finding is a designed
  decomposition of the cascade under a no-output-byte-may-change constraint, not a hygiene edit —
  `dd059696`
- the close-trail refusal was to be extended to `WrapList.shapeSingleArgGlue`, which builds the
  same closer-after-a-`//` seam → a `//`-tailed sole item does not occur over the real trees the
  reachability probe covered, and on the synthetic source that does fire it the gate does not move
  the fixed point: declining hands the pass back to the leading-break shape, whose output the next
  pass re-glues to the identical bytes, so the gate cost a normalisation pass and bought nothing —
  `dd059696`
- `StructuralTypes.comparableNominalOf`'s ANON-STRUCTURE nominal was to be narrowed so it refutes
  against a provably non-structural other side → even the loosest form of that refutation, on the
  anon nominal's own name, moves no finding on this project or on the Pony fork, so leaving the
  spelling open costs nothing — `2391816b`
- the unresolved-nominal default in `StructuralTypes.comparableNominalOf` was to be flipped from
  CLOSED to OPEN → it moves no finding either way; the older reading, that the closed default is
  what lets the refutation fire at all, stopped being true once the configured library joined the
  index, and every refutation that fires today has a resolved declaration on both sides —
  `2391816b`
- the repeated `checkstyle.json` walk was to be memoised at `HaxeNamingSupport.policyFor` → that
  bought nothing measurable on a full run; the walk had to be memoised at
  `CachingGrammarPlugin.maxComplexity`, the call site the whole ruleset reaches — `2391816b`
- `BodySlotGuard.scan` was to be skipped wherever the pre-filter already knows which edits blank
  something → a CPU profile of a whole `lint --all --fix` puts the entire source-side half well
  inside that command's own run-to-run spread, so no arm could show the difference; `reaching`'s
  RESULT parse is where that gate would get cheaper — `2391816b`
- `LexicalRegions.regionAt` was to become a binary search over its sorted, non-overlapping regions
  → a CPU profile of a whole `lint --all --fix` does not sample the function at all, nor
  `offsetWithinComment` beside it, and both of its loop consumers are bounded from outside —
  `2391816b`
- a comment-only slice was to be proved byte-inert by building both revisions to JS and comparing
  the bytes → the Haxe build is NOT reproducible: rebuilding the SAME tree twice moves the
  analyzer's switch-arm grouping, so `bin/test.js` and `bin/apq.js` both differ from themselves
  and an equal pair is one lucky draw, not a proof. The sound form of that oracle is the LINE
  MULTISET of the generated JS, which is stable across rebuilds and still catches a one-token
  mutation — `f742fe4c`
- `Doc.hx`'s module header was to be shortened as prose → most of its length was the `Primitives`
  list, which DUPLICATED the doc three ctors already carried and was the only doc the rest had;
  the fix is to move each entry onto its ctor and keep in the header only what belongs to the
  enum as a whole — `f742fe4c`

- a second reflection guard on `naming`'s cross-file public rename path → `otherFileRenameSpans`
  already refuses a name-shaped string literal in every affected file, the declaring file
  included; a second mechanism would only re-scan the scope for an answer the path holds —
  `5d510620`
- `ReflectionScan.scopeFiles` was to be memoised per `fix()` call to recover the cost of the
  widened reflection scope → the union is a sliver of the run; the cost sat in the quoted-name
  interpolation inside `Naming`'s per-file pre-filter, which was hoisted instead — `b80a7ff0`
- unreadable scope files were believed to contribute nothing to the reflection surface (a
  fixture read zero extra rewrites) → the fixture selected only the cell whose reflective string
  names a FIELD; selected by the form of the evidence, an unreadable sibling licensed rewrites a
  readable one refuses, so their raw source is kept and asked per name — `05fc93b4`
- `DefiniteAssignmentGuard` was to refuse on the closure asymmetry (a write inside a lambda not
  counting) → the compiler walks a lambda body as ordinary code at its position; the `if` is the
  construct that withholds an assignment, and a closure gate refused correct fixes — `19b89705`
- a source-tree pre-filter in front of `DefiniteAssignmentGuard`'s result parse → byte-identical
  outcome and not faster: the walk it saves costs about what the parse it skips does —
  `19b89705`
- `NullFlow.declInit` was to serve as `DefiniteAssignmentGuard`'s initializer test → it reports
  the continuation declarator of `var a, b = 1;` as `a`'s initializer, which the compiler
  refuses; the guard asks for a real non-type, non-continuation child instead — `19b89705`
- `orphan-accessor`'s second `ReflectionScan.scopeFiles` call was to be hoisted → invisible
  inside round-to-round noise, and a hoist must keep `ReflectionMemo`'s element-wise source key
  intact — `4ad5c407`
- a declared `resolutionLibs` alone was feared to silence `orphan-accessor` once its unreadable
  probe read the resolution scope → the probe is per name, so only a skip-parsed library source
  spelling the candidate's own accessor prefix whole-word declines, and that is the fail-closed
  precision loss it keeps — `4ad5c407`
- a `@:nativeGen` carve-out for `prefer-final-public-field` / `prefer-read-only-field` beside
  `inline-constant`'s → `var` -> `final` and `var` -> `(default, null)` emit byte-identical C#;
  only `inline` changes what the foreign side observes, so the gate stops at that one rule —
  `455e0bff`
- a cross-class `Other.A` reference arm for `inline-constant` → the corpus holds no non-inline
  qualified constant initializer (the idiom is written WITH the keyword), and the receiver need
  not be a type at all: a static field of the enclosing class spelled like an in-scope type wins
  in expression position, so the proof was never reachable — `b49726b2`
- `prefer-lambda-expression-body` was to exempt the trailing-argument population from its layout
  probe on the theory that its canonicality is structural → the exemption opened argument lists
  and split method chains on real code and was reverted; a site the probe refuses stays braced —
  `84c00aeb`
- `prefer-lambda-expression-body` was to require the collapse to SAVE a line → a construct body
  de-braces line-neutrally by construction, so the strictly-shrink test refused the whole
  population; the criterion is head-line identity plus an interior that survives — `84c00aeb`
- `BindingScope`'s local-function lower-bound clamp was expected to change answers → inert:
  `Refs` binds a read before the declaration to the outer binding, so the clamp is the
  fail-closed side of a resolver property and is kept for the day a frame hoists — `3977e25e`
- `VolatileMessage` masks were to keep every number that changes only when the code changes →
  `oversized-type`'s member count, `string-literal-dup`'s repetition count and `complexity`'s
  score all move with the code while the finding stands, and a blast-radius verdict then reports
  nothing but those bumps; the criterion is a configured threshold or a last discriminator —
  `38c99275`
- `prefer-ternary-return` was to be gated on the three-rung crossing → built and rejected: it
  removed every step the composed `--fix` uses to reach the if-expression canon and regressed the
  fixed-point test; the fix was put one step away, with the cascade owned by
  `prefer-if-expression-return` and the pair rules deferring by asking it — `f6df2bf5`
- `unused-return-value` was to resolve through `RefactorSupport.resolutionIndexOf` so declared
  `resolutionRoots` are honoured at any scope → that index folds the roots and every library
  into one undivided array, and a test tree then floods with `utest.Assert.*` calls whose result
  the framework's idiom discards; the split belongs in `ResolutionScope` — `38c99275`
- the ternary's `?` / `:` were to join `HxCondSpliceOpLit` so a half-ternary `#if` splice parses
  as two terms → a hand-indented ternary region follows the ternary's two-level convention and a
  FLAT term run has one indent level to give, so `fmt` starts rewriting a file it left alone;
  the ternary keeps the raw capture and its rename refusal — `76a7186c`
- a fifth paren-nesting level in `HxPpCondLit`'s `#if` condition regex → the `@:re` line runs past
  the column limit and no recursion-free shape exists (a JS regex has no `(?R)`, a counting scan is
  not a terminal); depth-limited nesting stays until a real site demands more — `07294564`
- a structured `HxConditionalSemiExpr` reading of a self-terminating expression-position `#if …;
  #end` region → its writer reflows the multi-line region onto one line and drifts modules the
  formatter leaves alone; the region stays a raw capture re-emitted line by line — `ab7270df`
- `@:sep(',', sepFaithful)` on the guarded anon-field body Star to admit the comma short form →
  it makes the separator mandatory between the `;`-terminated elements real source uses, trading
  working modules for a shape no dependency tree contains — `07294564`
- widening `HxAbstractDecl.clauses` to a cond-comp-aware wrapper struct instead of a
  `Conditional` branch on `HxAbstractClause` → forces every `clauses[i]` consumer through an
  unwrap for a rare construct and breaks the parallel with the heritage scope — `07294564`
- an optional alternate-header slot on `HxClassDecl` for the shared-body `#if` region → field
  position is load-bearing for the writer's trivia slots, so a slot between `heritage` and
  `members` moves every class declaration's slot, and a `#else`-keyed member ctor would make
  `HxConditionalMember.body` swallow the clause; the region is its own `HxDecl` ctor — `ea9977a9`
- a per-branch-`;` conditional as a new `HxExpr` ctor after `ConditionalExpr` (so `HxVarDecl.init`
  reaches it for free) → built and reverted: a statement-scope `@meta` routes through
  `HxExpr.MetaExpr`, so the ctor claimed statement regions too and the `ExprStmt` then lacked its
  `;` after `#end`; the widening lives at member scope — `414ce5d1`
- an unconditional ordered-comparison flip for the ternary / guard-chain reductions (no type
  resolver) → `!(a < b)` and `a >= b` differ under `null`, so `(s < t) ? false : a && b`
  miscompiled for a null `s:String`; every consumer threads `typeNominalOf` — `f323e0f9`
- `String` in `TOTAL_ORDER_TYPES` (no NaN, so the flip looked safe) → Haxe has no non-nullable
  string type, so a declared `String` proves nothing about null and the flip is unsound; only a
  string LITERAL is licensed — `26a571a6`
- deleting the comprehension carve-out in `reflowSourceMultiline` to admit `ForReifExpr` as a
  generator → fixed the reification fixture and broke a keep-wrapping one (net zero); the fix is
  positional in the parser, which clears the stash newline after the open `[` — `3417bc83`
- admitting `ForReifExpr` was said to need a depth-0 `=>` scan because the fork calls the
  reification fixture a map LITERAL → the fork's `determinBkChildren` returns `Comprehension`
  from its first-child loop before it scans for `=>`, and pads that very fixture — `ac425169`
- a general expression-position ctor for the self-terminating `#if …; #end` raw shape → it
  claimed a switch's guarded `case` region, which `HxConditionalCase` parses only because the
  case-body statement Star FAILS there; the ctor requires a leading metadata Ref — `c808ed0b`
- a Pratt-loop rewind for the dangling-operator `#if` splice → prefix and postfix do not live in
  the loop, so an ATOM-level operand plus a `@:tryparse` Star rewind parses the run without
  touching it — `76a7186c`
- source-faithful (trivia-replay) layout for a token-splice operand run → one expression laid out
  as many ways as the source spells it, with no break point on a flat source; the rule owns its
  layout through `fillParts` — `c80010de`
- an `import` arm on `HxCondDeclPrefix` so a `#if` region with dangling trailing metadata rides
  `HxTopLevelDecl.meta` → the metadata Star is tried before the decl dispatch, so every
  import-only region re-routes away from `HxConditionalDecl` and its blank-line cascades; a
  trailing meta Star is additive instead — `07294564`
- `padLeading` on the trailing-metadata Star of a conditional region → it fires on an EMPTY Star
  too and inserts a blank line before `#end` in every module-level region; `padTrailing` alone —
  `07294564`
- `#else` / `#elseif` branches needed no trailing-metadata slot ("no observed source dangles
  metadata off an alternative branch") → `#if macro <imports> #else @:autoBuild(...) #end
  interface X {}` is valid Haxe the grammar rejected, and `cond-region-merge` proposes that form
  — `b0050d10`
- `@:trailOpt(';')` on `HxFnBody.CondBody` to absorb a `;` written outside the region → the two
  trailers together make every `CondBody` source unparseable; the stray `;` stays a sibling
  `EmptySemiMember` — `142b7bb2`
- `bodyPolicyForCtor('CondBody', 'functionBody')` on `HxFnDecl.body` so a whole-body `#if` region
  keeps its own-line placement → the policy defaults to `Next` and breaks the same-line sources
  that round-trip today; it needs `Keep`-style source fidelity — `142b7bb2`
- `condInit` placed AFTER `init` on `HxVarDecl` → it shifts the trivia slot the writer reads for
  the blank line after a declaration and silently drops the blank after every `var x = try {...}
  catch {...}`; it sits between `type` and `init` — `73c1b711`
- the `expressionIfWithBrackets` hug folded into the layout policy inside `buildBodyCoreWrap`, one
  level below the outer `Keep` switch → `sameLine.expressionIf: keep` got the two close seams and
  not the open one; the hug keys on the policy VALUE at all three seams — `bd58ae13`
- refusing the arrow-body value-`if` reflow on a captured comment in ONE direction only → the
  chain rendered half re-flowed and half in policy shape; an `else`-spine walk covers members
  below and `_arrowValueIfBlocked` members above — `42d03a31`
- `loopBodyIfElseNext` gated on the `FitLine` LAYOUT alone → a config on `same` / `keep` could not
  decline the defect the key names; the substitution sits on the policy VALUE — `7ec1a81a`
- the fork's leading `lineLength >= 160` method-chain rule with a static width that descended into
  `BodyGroup` content → fired for chains the renderer keeps flat (multi-line lambda bodies
  inflated the total) and regressed the corpus; re-adopted once `chainItemLength` defers
  BodyGroup content as `fitsFlat` does — `4e74819d`
- `sameLine.expressionIf: next` mapped to `Keep` on `sameLineExpressionElse` as a stand-in for a
  shape-aware dispatch → a value-`if` with a `{ … }` branch and a source break before `else`
  kept that break forever while its statement twin joined to `} else {`; mapping it onto a plain
  `Same` instead glues a bracket-closed branch (`[] else {`); `next` maps to `SameOnBlock`, which
  is `Same` only after a CURLY close — `8e7b149e`
- `SameOnBlock` answering a BRACKET close from the source's `Keep` slot → the `]` of a branch the
  `next` layout had moved to its own line came back glued to a flat source's `else`
  (`[1] else if (b)` / `[] else`) and broken after a broken one; it now breaks like every non-curly
  close, and `expressionIfFit`'s soft pre-`else` seam is refused after a CURLY close only (and after
  a `]` the bracket knob glues), since the refusal exists for the `} else` glue — N4
- deriving the Haxe lexical-region scan from a full PARSE → refused permanently: the scan is
  handed raw source with no promise it parses, and a parsed tree carries no node for a string
  literal in a `#if` condition, a `#error` message or a quoted object key — an unmasked region
  costs a refusal, a missed one costs a delete — `8867c7e7`
- a writer-time `expressionWrapping` (paren) cascade at `WriterLowering`'s `isWrapShape` branch →
  when `obj.y = (expr)` exceeds the width the outer `opAddSubChain` cascade commits its break
  before the paren's probe runs, stacking two `Nest`s; needs a Doc-level "paren wrap first" order
  (the fork's two-pass marker phase) — `35585070`
- a lazy `#if`-region note in `fmt` (parse only the files `fmt` leaves unchanged, or only the ones
  it rewrites) → on an already-canonical tree the first is the identity and the second deletes
  the whole output; the second front end is the whole cost — `5c77e498`
- asking the WRITER's own tree for the declined `#if` regions instead of a second parse → the
  trivia parser's tree carries no spans and records nothing for a `@:rawString` terminal;
  exposing the decline from there is a parser change — `daf1a095`
- gating the comprehension cuddle on whether the BODY would break by itself under the glue → the
  layout became non-monotone in width (one line, then the ladder, then the cuddle as the width
  grows) because the closer's two columns and the pending space before `[` were outside the
  measure; the body is forced down and only the head is asked — `6b314d7d`
- retiring the prose census's `control` lines by minting an arm per line → the rate is about one
  arm per LINE, not per class, and a blunt arm on a fixture that is unchanged either way is the
  vacuous pin the layer exists to prevent — `8a849023`
- pinning the registered test classes as a COUNT → two branches that each add one class write the
  same incremented number and git merges them clean, so the tree claimed one class fewer than it
  registered; only a name list conflicts or merges both — `2caca4ed`
- checking fragment arms with a plain substring test over the host FILE → some arms match only
  through the whitespace-insensitive fallback and some occur twice in the file while once in the
  node, so a strict gate fails healthy arms; the matcher `hxq patch` itself uses runs on the raw
  slice and costs no writer round trip — `21d87213`
- deriving `lexicalRegions` from the parse tree instead of the byte scanner → directive text and
  quoted object-literal keys carry no node, a visible share of real sources does not parse at
  all, and every divergence is scanner-only — `8867c7e7`
- a build-macro route around `Context.getModule` answering `ok, 0 type(s)` for a `#if macro`
  module (`Context.defined('macro')`, `Type.resolveClass`, a `@:build` on a type inside
  `#if macro`) → each answers for the wrong context or is refused outright; the two answers are
  separated instead and such arms are deferred to the parser — `9fa8c596`
- arming the fourth block-ended Star rewind site (`lowerStarBlockEndedSepLast`) → its byte check
  is evaluated suite-wide and the rewind never moves, because the only grammar routing to it has
  no element rule that can leave trailing whitespace consumed — `7ad3ee1f`
- sweeping `selfBreakingBraceBody`'s threshold slack instead of bounding it → nothing between the
  two sampled thresholds moved anything in the suite or the corpus, so one fixture a column past
  the boundary closes that side — `9e1db129`
- demoting deleting (or shrinking) safe fixes to report-only when no compiler oracle is configured
  → the pure-deletion fixes are a fifth of a no-oracle run's edits (`unused-import`'s among
  them) and the shrinking replacements most of the rest, so the demotion would gut the edit loop
  that exists to say no compiler; `DefiniteAssignmentGuard` refuses the one deleting class the
  language itself refuses instead — `6f684346`
- a whole-resolution-scope (library included) write index for the field-immutability rules →
  loses findings and gains none: a skip-parsing library source that merely spells the member name
  vetoes, and structural conformance against a library structure vetoes past what can unify —
  `cd79cfb4`
- `import-block-order` blind to a foreign-package import splitting a `unit.*` run → a run ends
  only at a blank line, a `using` / wildcard / alias, a comment or a non-import declaration; the
  real file reported and one `--fix` sorted it — `2ed13deb`
- refusing `prefer-ternary-return` cascade tails on SHAPE alone → a fifth of the findings would
  have no replacement from any rule, so the narrowing is the conjunction of shape and comment —
  `12683df6`
- `TypeResolver.isProvablyNonNull` in place of the `Reflect.copy` name exclusion for the nullable
  seed → it needs `@:nullSafety` active at both ends and moves none of the real sites the
  exclusion moves — `daf1a095`
- a finer super-call gate for `field-init-at-declaration` keeping an init that precedes `super(…)`
  → a `super` call need not be a top-level statement (a branch-conditional one is legal Haxe), so
  "precedes THE super call" often has no answer; the coarse gate's one lost cleanup per hundreds
  of files is the accepted price — `508172fc`
- field-init-at-declaration: the coarse super gate (`508172fc`) and the early-init narrowing (`d383325d`) as the only ways
  across `super(...)` → PARTIALLY REVERSED: where the builds are declared complete and the facts are the truth, a crossing is
  proven instead — no crossed code reads the field (`mayReach`), and the right-hand side writes only what it allocates and
  reads nothing the crossed code changes (`freshOnlyReads`); the narrowing stays for the run without the truth, and the
  coarse gate for the chain path — branch `feat/field-init-across-super`
- `DocMeasure.flatTokenWidth` descending a `BodyGroup` to close the convergence tail → closes
  three files and opens one, reformats dozens of this tree's files and makes `CollapsePass.hx`
  itself a two-rewrite file — `f57325e5`
- resolving the `BodyFit` / case-sibling pivot for the convergence tail → reformats files here and
  on Pony and cannot be narrowed to the divergent population, because `HxExpr.ArrayExpr` is the
  only Star that reflows source newlines, so every call-parameter list is in the same population —
  `f57325e5`
- `BodyFit.fitLineLayout` sending a body that does not fit on its own line to the glue gate →
  closes one case-body file and glues a `for` / `if` body onto its header in ten others, plus two
  more Pony drifts — `5c1cffd5`
- charging a committed `BodyGroup` in BOTH first-line walkers (`flatFirstLineStep` and
  `restNodeWidth`) → a nested committed body then reads as committed to the rest-of-stack
  lookahead too and files reformat for the worse; charging the prefix without ending the line is
  free and closes nothing — `5c1cffd5`
- saturating a COMMITTED item's width in `WrapList.measureItems` to `MAX_ITEM_LEN` → closes two of
  the reduced tail shapes and takes one file from three rewrites to two while reformatting eleven
  files of this tree; saturating the `total` axis alone measures identically — `62ca1493`
- the modifier/metadata straddle (`#if x @:a #else extern #end`) blamed for a modifier-prefix
  region failing to parse → the bisection put the defect on the missing `#else` arm of
  `HxConditionalMod`; the straddle is a second, independent gap — `406a923d`
- reusing `@:fmt(suppressComplexItems)` to switch the rest probe off inside a case pattern → a
  switch SUBJECT sets it too, and a subject's call must still wrap at `maxLineLength + 1`, so the
  pattern needs a flag of its own — `e7c99aa5`
- the ungated `emitSepStarList` rest probe filed as plain-only and unreachable by any fixture → a
  struct Star without `@:trivia` routes the TRIVIA writer through the same dispatch, so `fmt` saw
  the gap — `7ea1182a`
- a static read for the `FitLine` glue overflow (a flat first-line walk, or
  `DocMeasure.breakableHead`) → the flat walk counts a condition the renderer will wrap and
  drifts corpus files, and `breakableHead` stops at the construct's own `(`; only the natural
  first-line walk from the live pen column answers — `76749df6`
- a renderer-wide rule that a run of close delimiters glues only when their openers share a line
  → a multi-argument list closing on a trailing lambda or object hug WANTS the glue and every
  corpus fixture pinning it broke; the rule lives at the sole-argument shape decision — `f11a2a75`
- `ExtractInterface` / `ExtractSuperclass` / `IntroduceParameterObject` bypassing the
  `docSplittingEdit` guard, as the brief said → they reach it through `editKeepingCanonical`;
  nothing fires because every insertion the family makes lands at a member list's end, at EOF or
  above a first declaration's trivia — `12988dbf`
- the comment-width gate comparing over-width line TEXTS before and after an edit → any edit of
  a wide line reads as a newly gained one and a SHORTENING rename is refused; the gate compares
  COUNT and WIDEST — `01c78ae6`
- `anyItemLength >= n` as a width proxy for the complex-element wrap condition, and declining the
  multi-arg-collection glue for a call-bearing container → the proxy also explodes `case [A, B]`
  patterns and switch-subject arrays, and declining the glue over this tree makes files worse —
  `d21e7783` (the proxy), `2f30b0bc` (the glue)
- modelling `import pkg.Module.*` as a binding rung for the move gate → it binds no TYPE (only the
  module's statics), the invented binding equalled the wanted one and cancelled the ambient
  refusal — `521d044c`
- `move` dropping a source import its departed declaration was the last TYPE-POSITION user of →
  `sourceStillUsesType` reads type positions only, so the arm deleted an import a remaining
  `Helper.go()` needs at rc 0; the hand-off is `unused-import`'s — `ab784602`
- refusing a rename whose name a `#if` CONDITION spells → a condition names build flags and no
  grammar resolves one against a binding, so the refusal declined correct work with a
  real-looking reason — `d5f6411b`
- a memo on the grammar plugin's lexical-region scan → the scan is a small share of a full
  `lint --all --fix` against a parse demanded once per check, and a speculative cache is the
  process-lifetime state invariant 1 forbids — `2ed13deb`
- `lint-diff` losing a normalization because a `66 added / 9 removed` verdict read as fewer
  findings → the headline's net is +57 and the reader's own per-rule tally already said so; the
  headline now states the net beside both surpluses — `a28edf4c`
- exempting a template slot from the token census by FIELD → the same structure's `bodyOpen: '{'`
  is a real token the parser captures and was freed with it; exemptions are addressed by
  `<field>#<slot>` — `c04f877e`
- deciding a `#if` region's opacity by whether its braces balance → most raw-captured regions
  balance and the one unbalanced count is a nested `#if` / `#else` adding both arms; the predicate
  is whether the bytes are a balanced subtree in their grammatical position — `f34c5db0`
- counting a comment-interior mention as a reference the move family owes an import for (on the
  reading that a redundant import costs an advisory while a missing one costs the build) → a
  comment is never compiled, and writing the import created the coupling the move was removing —
  `76982f3c`
- an `ERROR`-vs-`FAILURE` verdict kind as the tell for a flaky extra row in a whole-suite arm
  sweep → the extra rows were a function of LOAD (the same patch at a lower `--jobs` produced a
  different set), and the load was two suite processes deleting each other's fixtures under one
  `$TMPDIR`; never classify an extra row by verdict kind — `226b3653` (the rule), `9f3d453f`
  (the mechanism)
- `--check-apply` (apply an arm's cut and build, no suite) was asked for as a SPEED win → the
  `haxe test-js.hxml` build IS the cost of a track in every mode, so dropping the suite saves
  almost nothing against `--fast`; what the mode buys is a cut checked before it has a `@:killer`,
  and a `BUILD-FAIL` that names its cause — `a6ae7dbb`
- a static predicate over the arm record and the tree for the narrowed-nullable blind spot (a
  `find`/`replace` whose replacement reads a `Null<T>` local an enclosing `if` narrows) → Haxe's
  narrowing lattice decides one syntactic shape several ways and `TypeResolver` answers what a
  name is DECLARED as, so the predicate is unsound in both directions; only a compile of the cut
  answers — `a6ae7dbb`
- the `deBraceBodyAccess` gate-7 probe (`elseSiblingKeepsExpr`) was read as "held by the `||`
  partner for the fixtures we have" and kept → the partner answers for EVERY input (the chain
  probe ends on the byte-identical call, and gate 7 is constant `false` for an `IfStmt` else
  body), so it was dead logic and was deleted; the `elseFollows` argument beside it is dead in the
  current wiring for a different reason than the one stated and is kept because removing it
  deletes a predicate EVALUATION — `518e7d45`
- an arm on `DependencyCarry.packageOrTopLevelBinding` dropping `t.isMain`, the cut the
  fixture's own doc named → it changed nothing the fixture could see, so the arm was deleted
  rather than kept as an unverified claim and the pin repointed at the arm whose sweep had
  already killed the fixture as collateral — `93bdd299`
- a caller-side seam for `SingleStmtBraces.needsSymmetryWrap`, after both of its inner gates
  proved WIDER than the conjunction → its one live caller's blast is the member's own, the other
  caller is inert by PROOF (the next line returns the same `null` for every input that reaches
  it), and the position split that remains would manufacture a mechanism for a count of one; no
  ownable seam — `51ee9584`
- "the module is exhausted" after three slices of probing `SingleStmtBraces` gates → three
  never-probed MEMBERS of the same file still owned fixtures; what was refuted was more gates of
  two specific helpers, not the file — `7aa8455a` (the reading), `2a571a21` (its ceiling: the
  residue is structural)
- rewriting a chain-guarded fixture so an existing arm discriminates it, to retire a census row
  → the rewrite works and is refused: the discriminating shape is already pinned to the same arm
  in the same class, and the rewrite deletes the everyday shape the fixture exists to guard —
  net one census row for one real guarantee — `2d39cdf1`
- narrowing `ProseClaims` so a doc that names some OTHER fixture as its control stops counting →
  the same words carry both readings ("the control for the test above" IS a self-claim), so a
  phrase list would suppress real claims; the rows stay listed — `08015cd3`
- a type-level `@:pin` for the claims that live in CLASS docs → `ProseClaims` is asked of
  `ClassField.doc` only, so those claims contribute nothing to the census and a type-level pin
  would open a second, uncounted population; the honest record is the member pins it summarises
  — `9924b5cc`
- a confirmation threshold (a doc, an annotation, more than N lines) or a specificity rule before
  `remove-element` takes a member → in a tree whose lint enables `prefer-doc-comment` the
  threshold fires on nearly every correct use and the rule refuses an address that is already
  correct; the fix is the report line naming what was cut — `d91b8f43`
- a checked-in fixture corpus for the rules a real tree's `--fix` run never exercises, or
  excusing those rules from the closing arm → a corpus is a second codebase whose only reader is
  a gate, and excusing leaves the vacuous quote available; the `--fix` run prints a rule census
  instead — `087e33d2`
- `hxq lit '<phrase>' test/unit --include-comments` as the instrument for the prose-claim census
  → it counts comment NODES and string literals anywhere in a file where the census counts DOC
  COMMENTS ON FIXTURES; the two agree on nothing but the direction — `7331535c`
- `compilerOracleServer` for this project's lint branch → a macro-heavy build re-runs its `@:build`
  macros on the server so the warm path is no faster, and the server re-emits stale null-safety
  diagnostics the cold compiler accepts, so every warm verdict is re-run cold; off in
  `apqlint.json` — `21dcdd8a`
- keying the oracle verdict cache on mtime → the compilation server's one-second mtime rule
  reported a broken build as clean; the key is the CONTENT of every compile input, libraries
  included — `e4d0a9d9`
- `resolutionRoots: ["src"]` alone, to halve the read+parse tax → with `test/` out of the scope
  `lint src --all` reports deletion candidates whose only callers are tests, which is the hole
  the key closes; both roots — `c4a33dc1`
- widening the jvm probe's trigger claim to "a package" (`query`, `check`) → the probe compiles
  what `-main JvmPortability` reaches, and `query/cli` contributes zero jar entries, so a green
  probe after a `cli` slice proves js only; the battery's trigger diffs `src` — `a28edf4c` (the
  reach), `a4d15e21` (the trigger)
- CoreIR as a materialised IR between lowering and codegen (pass 3 emits `CoreIR`, pass 4
  serialises it to `Expr`) → the emitters produce `haxe.macro.Expr` directly and use CoreIR's
  vocabulary conceptually; a `CoreIR → Expr` serializer would double the code with no observable
  benefit, so nothing outside `Strategy.lower`'s signature builds or matches one — `b3e9d0dd`
- strategies lowering their own nodes (`Kw` to `Seq([Lit, Not(Re)])`, `Pratt` to a `Host` loop)
  → every shipped strategy is annotate-only and returns `null` from `lower`; `Lowering` reads
  the `lit.*` / `kw.*` / `pratt.*` slots and emits the shape itself — `b3e9d0dd`
- the registry catching a strategy that declares `ctxFields` without `cacheKeyContributors`, or
  two strategies with a same-named helper → only ownership conflicts and dependency cycles are
  checked; no shipped strategy contributes runtime state, so neither check was needed — `b3e9d0dd`
- formats composed by inheritance (`Json5Format extends JsonFormat`, an `override var` per
  differing field) → the reference formats are `final`, Haxe has no `override var`, and a
  `(default, null)` property cannot be assigned from a subclass; a derived format is a clone
  that spells its whole vocabulary — `b1cdccf3` (where the contradiction was born), `dd3e63d4`
  (where it was decided)
- "parsing loses formatting" as a principle (the writer never sees whitespace or comments) → the
  trivia-mode parser records comments and the blank / newline shape as data on the AST for the
  `keep` policies; the writer is still one `format(ast, options)` pass, but what it can keep is
  the grammar's decision, not a writer limitation — `d3d4778e`
- a shared module for the module-level typedefs under `WriterLowering` → nearly every one has a
  single consumer and each is the bundle the constructor BUILDS for one collaborator, so the
  declaration belongs at the producing end, and typedefs do not count toward `oversized-type` —
  `7777c4f0`
- the gated check-entry helper `RunScan.collectWith<S>` was to delegate to `collect` through a
  closure of its own → strict null safety then rejects every null test on a captured local inside
  the CALLER's lambda (a generic callee that forwards the callback), so both gated helpers restate
  the loop — `2f161084`
- a `{name, span}` helper for the two-slot presence gate every declaration reader opens with
  (`final name = decl.name; final span = decl.span; if (name == null || span == null) return …`)
  → the helper still leaves a null test at every site and turns two locals into field reads
  across bodies that read `name` a dozen times, so the gate stays spelled inline; the same
  verdict covers the seam ladders (`final k = shape.x; if (k == null) return null;` runs), which
  Haxe cannot fold without struct spread — `9955d66c`
- the structure track was to split every source file past two thousand lines of CODE once the
  comment slices had run → after them no file is past it: the threshold had been set against TOTAL
  lines, and the largest remaining module (`format/wrap/WrapList`) is one responsibility by its own
  class doc, its `oversized-type` grant and a fresh cluster read — a lower cap would only catch
  `Renderer` one edit later; the flat `check/` layout stays (fan-in is uniform, the verb prefix
  already groups, `Linter.builtins()` is the index) — `ddb1de08`
- the `importHxDirs` gate in `SubtypeGraph` was a blanket over every file under a directory
  holding an `import.hx` → it recognised such a directory from the INDEXED file list, so a run
  whose scope did not include the ambient file pinned the supertype to the same-package namesake
  and left the ambiently imported type unshielded — the exact shape the S200 review had fixed,
  reachable again through a narrow lint; the gate is now the chain's own `bounded` flag — `2c0f8087`
- one choke point in `SymbolIndexBuilder.extractFileInfo` was to carry the ambient imports too →
  that function sees ONE file, while a chain member is usually another indexed file whose own
  imports the same pass has not extracted yet, so the fold is a second pass over the built
  records and falls back to parsing only a member outside the indexed set — `2c0f8087`
- the ambient-import seam was to take the module's path alone → the chain must stop where the
  compiler stops it, at the source root, and that root is the module's directory minus one
  segment per package segment, so the seam takes the package the index already holds rather than
  inventing a second notion of root or reading a build's command line — `2c0f8087`
- ambient precedence was to be one flat order, own imports → ambient chain → same-package → the
  three bands the first pass of this slice shipped → the compiler ranks by import KIND before it
  ranks by distance or ownership: an explicit import outranks every wildcard one, so a farther
  ambient `import a.T;` beats a nearer ambient `import b.*;` and beats the reader's own `import
  b.*;`, and a flat order pinned the wrong declaration in both — two tiers, explicit above
  wildcard, with own > nearest > farther inside each — `2c0f8087`
- a ROOT-package type was to be reached only as a package-less global, never as an explicit import
  → `import T;` on a package-less module is an explicit import like any other and the compiler
  ranks it as one, so skipping the path comparison for an empty package let an ambient namesake
  outrank it — `2c0f8087`
- the CLI was blind where a direct `new UnusedPrivate().run(...)` reported, and the cause was to be
  the `LintCommand` / `wrapResolution` resolution gate → it is `unused-private`'s own documented
  reflection-surface gate: the CLI joins the Haxe std to the resolution scope unconditionally, the
  std spells a bare `"Z"` string literal, and the constructor arm asks the whole scope's literals
  about the CLASS name — so a fixture's type name must be one no report or std literal spells as a
  word before the CLI is a valid instrument for anything name-keyed — `1f8d2ecb`
- the pending-import machinery was to add an import the ambient chain already provides → the
  `importMap` path takes the file's path, so `shorten-type-ref` already shortens through an ambient
  binding and adds nothing, and it already refuses to shorten a type whose simple name the chain
  binds to a DIFFERENT declaration — `1f8d2ecb`
- the extension-rewrite fixes were to leave behind a `using` the ambient chain already puts in force
  → the insert happens, and the same `--fix` run removes it again once `redundant-import` knows an
  ambient source can provide a statement, so the net output is correct and a second run is a no-op;
  what is left is a transient edit, not a surviving one — but ONLY under a `compilerOracle`, since
  that removal is a `RiskyFix`, and only in a file carrying no other `using`, since a rival one makes
  the removal refuse — `1f8d2ecb`
- an IDENTICAL ambient statement was to prove a module's own copy of it deletable, whatever the
  statement names → true of an `import`, false of a `using`: a `using` binds a name AND a position in
  the static-extension order, every own statement outranks every ambient one, a nearer ambient group
  outranks a farther one, and the last declaration of a file wins — so deleting the own copy hands
  every method a rival `using` also declares to that rival, and only an empty field of rivals makes
  the two positions interchangeable — `1f8d2ecb`
- the group that decides a simple name was to be the nearest ambient group binding it UNGUARDED
  → guardedness may decide the verdict but not the search: filtered, the search walks past a nearer
  group whose only binder is `#if`-guarded and reports a farther identical group as the provider, so
  deleting the module's own statement retargets the name in the builds that guard is on — the nearest
  group binding the name at all is the one to land on, and a guarded binder there is a refusal —
  `1f8d2ecb`
- a governed module's own text was to be read as generously as possible, on the ground that a
  too-generous used-test only ever misses a dead statement → generous to the point of useless: the
  governed subtree holds the DECLARING module of the imported type, whose own declaration of it reads
  as a use, so a stale statement in an ambient source above its target was unreportable forever — a
  module is never a reader of an import that names it — `1f8d2ecb`
- dropping the DECLARING module from an ambient source's reader set was to hold for every statement
  kind, since a module is never a reader of an import that names it → true of an `import`, whose
  target a module's own declaration outranks anyway, and false of a `using`: a module does not `using`
  itself, so one that calls its own statics extension-style depends on exactly that statement, and
  dropping its file made the ambient `using` it needs read as dead and deletable — `1f8d2ecb`
- a hoisted statement was to land in the DEEPEST directory whose share reaches the threshold, with a
  parent then re-weighed counting a module an already-hoisting child serves as one that has it → that
  counting rule carries every statement to the source root anyway (the child's own modules all count)
  and leaves the child's copy repeating its parent, so the placement is SHALLOWEST-first instead: the
  widest position is weighed first and a nested one takes only what its parents did not — `0a2d5ebe`
- a statement was hoistable only where its simple name had exactly ONE declaration in the whole
  resolution scope → the gate is per BAND and per MODULE, not per name: an ambient explicit import
  outranks a governed module's own package, the root package and its own wildcard imports and nothing
  else, so a namesake in a library package no governed module reaches is not a retarget, and the global
  form refused the single most common import in the test tree on a namesake no test module can see —
  `0a2d5ebe`
- a TYPE PARAMETER sharing the hoisted statement's simple name was a retarget to refuse → the compiler
  ranks a type parameter ABOVE an ambient explicit import, so the parameter still wins and the addition
  is a no-op there — `0a2d5ebe`
- an ambient STATIC wildcard (`import p.Mod.*;`) was assumed at least as dangerous as an explicit type
  import → it is outranked by every binding a reader owns (its own members, its locals, its
  module-level statics and its own static wildcard), so the only retarget source is a FARTHER ambient
  wildcard; it stays refused for want of an ancestor-wildcard gate and an enumerable member set, not
  because the precedence forbids it — `0a2d5ebe`
- the stale ambient memo was to make pass N+1 of one `--fix` run resolve against pass N's chain → the
  pass loop writes nothing to disk until it has converged, so every pass of the first round reads one
  disk state; the two answers appear where a fix writes DURING a pass, which is what creating a file
  is, and in the follow-up round after the wave lands — `0a2d5ebe`
- the LEAF name was what an import statement binds, so a hoist and a deletion could be judged on it
  alone → a statement naming a MODULE binds every non-private type that module declares, and the
  compiler proved both readings wrong on a SIBLING nobody had written: creating an ambient
  `import a.Mod;` retargeted a governed module's own same-package `Oth` to `a.Oth`, and deleting an
  own `import a.Mod;` identical to a farther ambient one handed `Oth` to a nearer group's `ccc.Oth`
  — both still compiled, so no oracle would have caught either — `0a2d5ebe`
- prefer-value-loop's `bindsName` as "any node carrying the name in its `name` slot" → an `IdentExpr` carries
  its own name, so the gate held for the very `X[i]` read it was meant to admit and the rule never fired;
  it asks for a DECLARING slot — `d383325d`
- prefer-value-loop deferring to prefer-keyvalue-loop whenever the body OPENS with `final v = X[i];` → the
  sibling claims less than that opening (braced, two statements, exactly one `X[i]`), so the shape it
  refuses was left to neither rule; the deferral reads the sibling's full claim — `d383325d`
- an index occurrence inside a literal counted as inert by QUOTE style (single quotes stay visible) →
  `literalInterpolates` keys on `$` / the dollar escapes, not on the quote: a `$`-free literal of either
  quote is inert — `d383325d`
- `for (v in X)` as equivalent to `for (i in 0...X.length)` reading `X[i]` whenever the body leaves `X`
  alone → the Array iterator re-reads `length` each step while the range evaluates it once, a closure
  capturing `X[i]` sees a later slot, and a callee reached through the instance, a type or a constructor can
  grow `X`; closures refuse, such calls leave the finding report-only, and nested loops deriving one binder
  are not both fixed — `d383325d`
- the element binder derived only from a plural at the END of the collection name → `gridLinesVertical`,
  `itemsById` are as plural as `points` and had no binder; `singularOf` asks its whole-name rules at every
  camelCase word end from the last back, so the last plural word is singularized in place and an end that
  is plural answers exactly as before. A stop list for `s`-final non-plurals ahead of a non-plural tail
  (`posList`, `wasVisited`) was not built: no such name occurs among the loop findings of the haxelib
  corpus or of the client corpus, and a list of exceptions is a guess at English — branch `feat/binder-inner-plural`
- prefer-value-loop deriving its binder from the collection name as spelled → `_points` had "no singular"
  while prefer-keyvalue-loop, and the nested-binder clash both rules ask, read it as `points`; the leading
  underscores are dropped inside `binderFor`, the one derivation both rules use — branch `feat/binder-inner-plural`
- a compiler-oracle configuration whose compiled set cannot be probed excluded "like a red one" → its
  baseline is green, so it cannot vouch for an edit but can still refuse one; dropping it from verification
  applied a shared-code edit that compiled on mac and broke the other build — `d383325d`
- field-init-at-declaration: an init hoisted across `super(...)` as unobservable because an early reader
  "can only have crashed on the null" → a null String does not fault on hxcpp (`length` 0), a fault caught
  up the stack is working code, a lambda written inside a `try` runs there, and a shadowed `Map` / `Array`
  runs a `@:from`; the path narrows to faulting receivers of core collections outside any lexical `try`,
  and the catch up the stack stays a stated residual — `d383325d`
- redundant-isvar leaving a build-macro-reached owner report-only → without `@:isVar` every direct storage
  access, generated ones included, fails to compile, so the compiler oracle judges the removal; what it
  cannot see is native code pasted as a string, which the rule refuses, and reflection by a computed name,
  a stated residual — `d383325d`
- dropping an unread key (`for (k => v in E)` → `for (v in E)`) as behaviour-preserving → the Map
  key-value iterator re-reads each value by key (a removed entry reads null), and a value loop over a local
  re-reads the local while the key-value iterator captured it once; the drop needs a std Array/List,
  unaliased, not shadowed, never reassigned (redundant-map-iter-key shared the unsound drop) — `d383325d`
- prefer-final-field / prefer-final-public-field: every change a build macro can make to a `var` → `final` edit
  was assumed to be a compile error the oracle sees → the conditional-default FOLD changes a property's kind
  (FProp → FVar) and moves the initializer after builder-prepended code, and a builder that branches on finality
  compiles either way; the fold is never admitted on a macro-built owner and a finality-reading builder declines
  — `37ab06fb`
- unused-private: a string naming a private static was assumed to matter only where source SPELLS a class value
  of its owner → a build macro can register the class (`$p{path}` into a registry) and `Type.getClass(this)`
  inside a macro reification binds `this` to the expansion site; a reifying project macro and a macro-file
  `getClass(this)` now open the gate — `37ab06fb`
- prefer-comprehension: an empty `[]` declaration filled by `a[j] = v` was assumed to be an Array → a `Map`
  annotation makes the fold not compile and an abstract with an `@:arrayAccess` setter loses its side effect;
  the fold takes only an unannotated or `Array`-headed declaration — `37ab06fb`
- mayReach: "Proven unless a listed channel fires" → every unlisted way Haxe runs code (`toString`, an
  iterator, `@:structInit`, reflection, a region's own writes) became a silent unsound fix; Proven is positive
  (modelled node kinds only, every channel admitted, any blind spot Unknown) — `dea1314e`
- element loops: a body calling only bare, `this`-, super- or type-qualified callees was the growth hazard →
  setter writes (`a[i].x = v` runs `set_x`) and methods of other objects holding an alias were missed; the
  syntactic stop is replaced by MemberReach — `dea1314e`
- mayReach: a local escape searched up to the loop's end → an escape later in an enclosing loop precedes the
  next run of the region; the scan runs to the end of the outermost enclosing loop — `dea1314e`
- mayReach: callback-taking Array methods (`map`, `filter`, `sort`) run no user code → they call their argument;
  purity and callback use are read from the declaration's parameter types, not hand lists — `dea1314e`
- mayReach: library implicit members count only for types the run's code names → a factory returning `Dynamic`,
  a supertype or `Iterable` hands out an unnamed subclass; any indexed construction counts, independent of
  question order — `dea1314e`
- mayReach: an extern handed an object reaches only that object's members → `JSON.stringify` walks field values
  and native methods call their receiver by name; handed-object reach follows fields transitively and includes
  the receiver — `dea1314e`
- mayReach: three hand-rolled receiver relations (touch scan, library reflection, runtime types) agreed →
  interface fields, common subtypes and structures each slipped through a different one; one predicate,
  `ValueCarriers`, answers them all — `dea1314e`
- mayReach: a value typed `T` is `T` or a subtype → `Dynamic`, an unchecked cast, `Array<Dynamic>` variance or a
  hand-off to library code put any instance anywhere on js/interp; escaped types join the value side — `dea1314e`
- #if liveness: "dead in every oracle configuration" = "runs in no build" → shipped builds the list does not hold
  run it; skipping needs an explicit `reachConfigurationsComplete` — `dea1314e`
- #if liveness: defines seen after the init macros hold for every file → an earlier init macro can type a module
  before a later one defines a name; `defined` is what the first init macro sees — `dea1314e`
- reach define probe: a cache keyed by compile-input content → macros read files never parsed, file existence and
  the environment; the probe runs once per run, never stored — `dea1314e`
- reach classpath: resolution-scope directories vouch for what builds compile → a `-lib` only an unlisted build
  adds is invisible; only a declared-complete list, through an index declaring every typed type, does — `dea1314e`
- mayReach: a skip-parse file matters only if it spells the member → an override it declares is dispatched to
  without the name appearing; any unparsed project file is Unknown, a library one when it spells the dispatch —
  `dea1314e`
- StdResolver: the sibling std lookup covered the installed layouts → on Homebrew it indexed another install's std
  than the compiler reads; both layouts and a multi-entry `HAXE_STD_PATH` are resolved — `dea1314e`
- compilerOracle: a project script generating the oracle hxml before lint → configuration belongs in
  `apqlint.json`; each entry carries its own `generate` command, rerun when content (hxml, command, inputs,
  library state read off the hxml) says it is stale — `54150a0c`
- oracle generation: inputs hashed after the command / the old record kept while a stale command runs → an edit
  during the run or a killed run is recorded as current; hash before the spawn, delete the record first — `54150a0c`
- oracle generation: `libs.hxml` as the proxy for haxelib state, repo directories from `haxelib.json` names →
  the hxml names paths neither tracks (`os-utils` vs `os_utils`); library state is read off the hxml's paths — `54150a0c`
- oracle generation: one exclusive lock held for the whole run → every lint serialised behind one `--fix`; a
  reader/writer lock, exclusive only to regenerate, taken in one global order with nothing held while waiting — `54150a0c`
- oracle generation: re-sharing without re-judging, and re-judging by full staleness → a tree another run wiped
  was compiled half-written, and a no-inputs entry was never current; compare the snapshot this run observed — `54150a0c`
- oracle generation: state under `TMPDIR`, keyed by the declaring config, found from the hxml → runs with other
  `TMPDIR`s or configs share no lock, and a marker in the output tree put the state in what the command deletes;
  keyed by the tree's real paths at the declaring config's project root — `54150a0c`
- oracle generation: a `project.xml`-tested define in an entry's `defines` → it reaches haxe but not lime's
  project evaluation (`ASSET_TOOLS` → `HEADLESS`); such a define goes on the generate command — `54150a0c`
- "hxq ignores an oracle entry's `dir`" → on node every spawn kind honours it; pinned per spawn kind — `54150a0c`
- compiler facts: `-D no-inline` for the facts compile → it changes typing (client refuses inline calls in field
  initializers); compile as the build does, with `keep-inline-positions` — `758ab0c2`
- compiler facts: facts of an inlined body attributed by position → they carry the callee's file and range and
  nothing records the call site; inlined bodies are whole-node facts marked `inline-site-unknown` — `758ab0c2`
- compiler facts: a flow compared at the unified type of an if/switch/try → the branch value's own type is lost;
  the sink is pushed down to every value-producing leaf — `758ab0c2`
- compiler facts: a channel the typed tree cannot show (inlined js reflection, expression macros, a stale file)
  left silent → the consumer would read absence as "no code"; each carries a node marker — `758ab0c2`
- compiler facts: persistent/serialized with the interpreted `Json` / `Ref.get()` → eval decodes the whole class
  per call (169 s vs 16 s); `Ref.toString()` and JSON written by hand — `758ab0c2`
- spans: "a Span is a codepoint offset" → on js/jvm a Span counts UTF-16 units; the compiler's Position counts
  codepoints, converted by `CodepointIndex` — `758ab0c2`
- compiler facts: a faceted function's facts replace its syntactic edges → a directive outside it (conditional
  `using`, `import … as`, `import.hx`, conditional typedef) resolves a name otherwise in an unlisted build;
  every syntactic edge stays and the facts only add — `be636ec3`
- compiler facts: a type in a file importing under a condition is alike → its member may take another type and
  that type's `@:from` in an unlisted build; not alike — `be636ec3`
- compiler facts: a `fieldValue` call of a node the graph has not read records no edge → a library `dynamic`
  method's body is never read; the index's `isDynamic` keeps the edge — `be636ec3`
- reach: code reached only through a value / reflective / any-code channel admits conversion and iteration only →
  it may run any implicit member (`@:op`, `@:arrayAccess`, `@:from`/`@:to`, `@:resolve`); all are admitted — `be636ec3`
- reach: "an abstract's own `toString` runs on the abstract alone" → it may convert what it wraps (`Any`); a
  string site on such an abstract admits any — `be636ec3`
- reach: a call no member declares resolves to the file's `using`s → a `@:using` on the receiver's type chain,
  conditional or not, may supply another extension; such a call is Unknown — `be636ec3`
- index: metadata a conditional region holds alone was lifted as its nameless wrapper → a guarded `@:using` /
  `@:build` reached no declaration; each metadata inside is lifted — `be636ec3`
- mayReach step B measurement: 13 new sound loop fixes (anyparse 13, client 0) against the < 10 stop rule → the line
  continues — `be636ec3`
- mayReach step C: element-type (per-owner) discrimination of the arrays a callee changes → `ValueEscapes` escapes
  every library receiver (`Array.push` included) and answers "any" on live native code, so no Array receiver is ever
  CannotCarry on real code; callees are walked for ANY non-fresh array change instead — `987038ab`
- mayReach step C: a `dynamic`-method guard in the callee walk → every call of a `dynamic` method already carries an
  unresolved site (region or body); no test could make the guard fail, dropped — `987038ab`
- mayReach step C: a String/Array exemption from library-override loading → every such call is either a benign call
  (not followed) or refuses on its own; dropped — `987038ab`
- the implicit walk pushed a library dispatch's declared target only → a library override the graph has not read was
  never walked; `followEdge` loads the overrides or refuses — `987038ab`
- a local was taken as holding what a plain `=` last gave it → `??=`, a compound write and an assignment used as a
  value (`all = xs = [1]`) left an alias unseen; only a plain or `??=` write of a fresh value whose value is discarded
  keeps it unshared — `987038ab`
- an expression statement was taken as discarding its value → the last statement of a block, branch or arm in value
  position is that construct's value (`all = { xs = [1]; }`); a value counts as discarded only when a statement follows
  it or it ends a function's block body, a loop body, or a statement branch/block that is itself discarded — `987038ab`
- mayReach step C measurement: +3 sound loop fixes (anyparse 22, client 1); the remaining refusals are the
  implicit-conversion admission (hxnodejs `untyped` in a `@:from`) and the element-type relation. The mayReach line
  ends here, as planned — `987038ab`
- `compilerOracleServer` re-probed for the whole oracle (baselines, verifications, the facts compile) → a warm compile of
  an UNCHANGED tree still reports null-safety errors the cold compile does not (client `ModelValidator.hx`, anyparse
  `CliIo`/`LintCommand`/`OracleDeclaration`), so every warm rejection is re-run cold and an incremental re-typecheck
  after a `--fix` edit buys nothing; the facts compile's cost is its typed-tree walk, which a server does not keep. The
  compiles stay cold and are shared inside the run instead (`OracleRunMemo`) — `cb5c668e`
- one compile per configuration serving the facts, the baseline and the coverage → the facts compile is not the
  baseline's: its `-D keep-inline-positions` reaches every `#if` and `Context.defined`, and its `-cp` probe directory
  shadows a project's own `anyparse.check.TypedFacts*` (this tree), so its status proves nothing about the plain
  typecheck; the baseline and the coverage probe are ONE `-v` compile, run in the facts compile's batch — `cb5c668e`
- folding `ReachDefinesProbe` into the facts compile → both define sets it prints would carry the facts compile's
  `keep-inline-positions`, and it needs the `-v` and `--each` the facts compile does not pass, so its output would not
  be the separate probe's; it stays a compile of its own (and runs only under `reachConfigurationsComplete`) — `cb5c668e`
- the oracle's compile budget `min(4, cores/2, memory/2 GiB)`, taken from the parse fan-out knee → a compile is one
  single-threaded process the caller only waits on: thirteen client typechecks take 19.3 s four at a time, 12.2 s at eight
  and 8.0 s at thirteen on sixteen cores; the budget is `min(16, cores − 1, memory/2 GiB)` — `cb5c668e`
- the run memo keyed by `OracleCache.fingerprint` alone → its compiler classpath directories are hashed once per
  process, so a project whose own sources arrive through `-lib` (a local `.haxelib` dev path) fingerprinted an edit at
  its old content and a build-breaking `--fix` was verified from the baseline; the run key adds a fresh hash of every
  path the run may write, and a configuration reading outside the walked directories is never answered — `cb5c668e`
- `dead-safe-nav`'s `?.` → `.` as a SAFE fix wherever the flow facts hold → Haxe null-safety narrows only a direct
  `== null` / `!= null` of the name and a non-null assignment, never a Bool local (`ok = x != null`), an alias copy
  or a safe-navigation comparison (`x?.f == null`), so under null-safety those proofs broke a green build and aborted
  `--fix`; they now report with a `declineReason` instead — `ac54a198`
- making `dead-safe-nav` a `RiskyFix` instead of declining the invisible proofs → `RiskyFix` is per rule, so every
  plain-code fix and every compiler-visible one would go report-only on a run with no oracle, to recover only an
  invisible proof that typechecks anyway — neither of anyparse's two did — `ac54a198`
- deriving compiler visibility NEGATIVELY (every NullFlow fact visible except a Bool local, an alias or a `?.`
  comparison) → the compiler also drops what the body of a lone surviving `if` arm or `switch` branch proved and
  everything a `try` proved, so each missed construct was another build-breaking fix; visibility is now granted only
  by the probed forms, and every construct it does not name keeps what was visible before it — `ac54a198`
- matching `--macro nullSafety(path, …)` against the module to decide whether an oracle build enables null-safety →
  `addGlobalMetadata`, a `-lib`'s extraParams and any project macro reach the same metadata, so a build is plain
  only when every hxml line is a known inert flag — `ac54a198`
- clearing only the names a loop WRITES before its body → a `for` binder, a key-value value binder and a `case var` /
  `Some(var x)` capture are fresh bindings the flow never cleared, so an outer `x` proven non-null reached `x?.f` on the
  binder and `dead-safe-nav` / `dead-null-coalescing` rewrote it into a null dereference; every scope now shadows the
  names `BinderScan.binderKinds` says it binds and restores the outer fact on exit unless the construct writes it — `ac54a198`
- a declared nominal proves non-null under null safety by its NAME → `typedef MaybeR = Null<R>` reads as a plain nominal, so
  `?.` / `??` / `!= null` on it were dropped (a build break, and a runtime change for the `!= null` one); a written type now
  proves only once it resolves to a class / interface / enum / structure through every alias and abstract (`DeclaredNullity`) — `3537f901`
- compiler facts as the source of that proof → `TypedFactsMacro.typeString` prints a typedef by its own name, unfollowed, so
  a fact about `x:MaybeR` carries the same unresolved alias; the syntactic resolution is the one path — `3537f901`
- the value-type fast path for every `Int` / `Float` / `Bool` binding → a field with no initialiser reads null on `--interp`
  and `undefined` on js (`0` on hxcpp), so `n ?? 5` answered 5 there and `n` after the rewrite; such a field keeps only the
  null-safety arm — `3537f901`
- keeping `static function main()` only when an oracle hxml names its class in `-main` → the oracle configurations are not
  the set of all builds (a generated launcher, `--run`, an uncovered platform), so no list the linter reads proves an entry
  point unreached; it is kept by shape (`ImplicitReach.EntryPoint`) — `3537f901`
- a private constructor is unreached when no `new C` is written → `Type.createInstance(C, [])` runs it with none, and
  deleting it broke that call on `--interp`; a class used as a value, or aliased by a typedef, keeps its constructor — `3537f901`
- resolving a proof's type name through `TypeRefIndex.inScopeAll` → it unions the tiers and skips an import the index does
  not hold, so an alias (`import other.Opt as MaybeR`) or an unindexed import lost to a same-package class; the proof now
  walks the compiler's own order and stops at the first tier it cannot read (`TypeNameBinding`) — `3537f901`
- closing a `cast` into a non-null class or abstract (`@:from … return cast v`) → no nominal proof sees an unchecked cast; a
  residual of the unsafe-cast class, not of the name resolution — `3537f901`
- closing a value type that receives null from non-null-safe code on a dynamic target (`n ?? 7` -> `n` on an `Int` parameter)
  → the same dynamic-hole class; the value-type fast path keeps trusting a parameter or a local — `3537f901`
- closing a null that non-null-safe code passes into a parameter declared as a class (`x?.name` -> `x.name` in a Strict
  class called from a plain one) → the compiler checks only the code in its own null-safety scope, and every declared-type
  proof trusts the declaration; the same residual as the value-type one above — `3537f901`
- typing an oracle-assisted annotation with the display server → it compiles one configuration lazily: code no build compiles answers empty on every path form, a monomorph a later use binds answers `Unknown<0>`, and a disagreement between builds is invisible; the facts of every configuration answer all three — `2d7f06cf`
- asking the display server for code no configuration compiles → its hxml is one of those configurations, so the answer is empty by construction; the facts oracle declines instead — `2d7f06cf`
- dropping the facts of every file the `--fix` run rewrote → the facts compile may have read the REWRITTEN text (it starts on first demand), so they were current; keep the run-start text and invalidate only facts of that text — `2d7f06cf`
- writing the type the compiler gave a local a `Dynamic` value initializes → assignment from `Dynamic` binds no monomorph, so the type is whatever its uses bound (`{k:String}` for a `Json.parse` result read as a string), not the value's — `2d7f06cf`
- rewriting a `Dynamic` bag to `DynamicAccess<T>` whatever its initializer → a value of a typed structure must unify with the map field by field, which the writes do not show; only none, `{}` or a `Dynamic` value may become one — `2d7f06cf`
- placing a declaration of the compiled text in the rewritten one by a line diff → a diff sees no moves: after a reorder it matched a line to a same-shaped line of another member, and two identical bodies to each other, and both annotations compiled; the edits the run applied are the only placement — `2d7f06cf`
- placing a local by its declaration's own text alone → an edit elsewhere in its member (a changed parameter) changes what the compiler infers there; the whole member has to be untouched — `2d7f06cf`
- trusting the facts compile's `src` hash, read from disk at `onAfterTyping` → a `--fix` write landing while the early compile types certifies the new text for positions of the old one (`var r = big()` typed `Meters`, 7 -> 700); the run now waits for the early compiles before its first write, and a file written after the compile started is marked and has no facts — `2d7f06cf`
- `EditStep.back` counts a deletion exactly at a span's `from` as before the span → sound for every fix today; a future rule deleting an inference-relevant modifier or meta at a member's start must revisit it — `2d7f06cf`
- the facts compile's mtime check (`writtenSince`) as a guarantee on its own → a coarse-mtime filesystem (ext4 kernel
  tick, HFS+/SMB seconds) can date a write made during the compile before its start; the `--fix` barrier closes the
  run's own writes, only an outside writer during the compile (a parallel hxq) remains — `2d7f06cf`
- `prefer-arrow-callback` reading the callee signature off the facts' call target → the client's one site hands the literal to tink `Future.handle`, whose parameter is the abstract `Callback<T>` (its `@:from` casts choose the conversion; there is no function type whose `Void` return could be read), and anyparse's is macro-context code no facts compile types; no gain, not built — `7ca83e16`
- clearing `unused-private`'s `extends` veto because no supertype in the facts declares the name → a supertype's `@:autoBuild` builds the subclass as its own `@:build`, which the rule declines; 5 of the client's 6 sit under `openfl.display.Sprite`'s, so the facts clear only a chain that carries none — `7ca83e16`
- typing a concatenation operand with `FactsTypeOracle.expressionType` → it adds the source type of a flow at that range, so a check-type `(name() : Dir)` answered `String` and a merge crossed `Dir`'s overloaded `+`; an operand is read with `valueType`, the expression's own type — `7ca83e16`
- trusting a fact at the exact range of an expression inside an interpolated string → after an escape sequence the compiler shifts the ranges of the hole's code by the escapes before it (fifteen `\t` put the read of `n` in `${d.toString()}${n.label}` exactly at `d`), so `redundant-tostring` dropped an extern `Date`'s call; the facts oracle declines a range in a string after an escape — `7ca83e16`
- naming a facts-typed operand by its simple name for the overload table → the table judges a NAME, so `far.Path2` (an abstract overloading `+`, outside the resolution scope) read as the scope's plain class `other.Path2` and `hs[0].fp + 'x' + 'y'` folded from `r/x/y` to `rxy`; the facts name only a built-in scalar or a class, interface or enum — `7ca83e16`
- `prefer-static-extension` taking an unannotated local's type from the compiler facts → the facts hold the type after typing ended, which may be the one the rewritten call's own parameter bound; at `x.m()` the monomorph is not bound yet, the call becomes a dynamic field call that compiles and fails at run time — only a binding with a written type is asked — `8c72e335`
- a file's `using` outranking the receiver type's own `@:using` → the type's `@:using` wins (`t.tp()` calls `Other.tp` under `using Util`), so a receiver whose hierarchy carries one is never rewritten by the facts path — `8c72e335`
- an abstract first parameter that took the argument through `@:from` taking the receiver in extension form too → `using` binds by unification alone (`String has no field k`), so the facts path accepts only a class, an interface, a structure typedef, a structure, a function type or the function's own type parameter — `8c72e335`
- reading an overloaded static's parameters off the facts field → the field record holds only the first signature (`over` counted the rest and nothing read it), so an overload is refused by its count, never judged by a signature the call may not have chosen — `8c72e335`
- `prefer-static-extension` taking an empty set of call facts at a site as proof of which static it calls → an `inline` call leaves no fact at its own range, and `import Other as Util` then rewrote `Util.f(b)` (`Other.f`) to `b.f()` under `using Util` (`Util.f`); the written name is proven through `TypeNameBinding`, and an inlined call needs a splice of the configured function in the facts of the code holding it — `8c72e335`
- the conflict gate reading only the module-level `using` run → a `using` in a `#if` region binds in every build that compiles it (`#if !nope using Other; #end` retargeted the call); every `using` in the file, and the ambient chain's, is weighed — `8c72e335`
- the structural path proving a rewrite by member absence alone → a `@:using` on the receiver's type, a superclass or an interface binds its extensions before the file's `using`; the whole closure must resolve and carry none — `8c72e335`
- the conflict gate reading only the type a `using` path is named after → `using Zeta` brings the statics of every type `Zeta.hx` declares, the last-declared one winning (probed on 4.3.7), and `Extra.f` there took over `Util.f(b)` → `b.f()`; every type of the module is weighed, a sub-type path alone brings its own type — `8c72e335`
- weighing only the types a used module DECLARES → a `typedef` there brings the statics of the class it aliases (`typedef Extra = Hidden` bound `b.f()` to `Hidden.f`; `using tink.CoreApi` is built that way), so each alias is followed to its class and an unresolved one is `Unresolved` — `8c72e335`
- skipping the configured module in the conflict gate → the `using Util` the rewrite inserts (or the file has) brings every other type of `Util.hx`, and `Extra.f` there took over `Util.f(b)` → `b.f()`; the module's own `using` is weighed like any other, `Util` itself excepted — `8c72e335`
- judging an operator operand's declared type by its simple name in the resolution scope → `import far.Tag` (an abstract overloading `+`, outside the scope) beside an indexed class `Tag` read as the class, and `t + 'x' + 'y'` folded from `r/x/y` to `rxy` (alias, wildcard, `import.hx` and module sub-type imports the same, 4.3.7 `--interp`); the type is bound where it is WRITTEN, tier by tier (`TypeNameBinding`), and a tier whose target is not indexed is `Unproven` — `2bdac5ef`
- binding only the operand reads the file itself declares → lost 14 anyparse fixes, every one a call to the file's own function or a member read (`q(…)`, `n.owner`); a call binds through its written return type and a member's written type is bound in the file that declares the member — `2bdac5ef`
- the old resolver's `Json.stringify(s)` as a proven `String` → it matched anyparse's own `anyparse.query.format.Json` by name while the file imports the unindexed `haxe.Json`; the fix it licensed is lost on purpose — `2bdac5ef`
- teaching `Refs` that a `case` capture binds → every `Refs` consumer (rename, unused-local, the call graph) would move with it, and an extractor's function name (`case f(_) => v`) or an enum-abstract value in a pattern is a read, not a capture; the operand binder declines a read a capturing branch may shadow instead — `2bdac5ef`
- typing a call by its member's written return → an extern `@:overload(function(x:Int):ops.Tag {})` over `m(x:String):String` makes `Ext.m(1)` an `ops.Tag` (`r/x/y` folded to `rxy`), and a macro's written return is not the call site's type; both are unproven — `2bdac5ef`
- proving a member's return non-null through `returnNominal` → the last segment of `far.MaybeR` (an unindexed `Null<R>` alias) bound to a same-package class `MaybeR`, and `redundant-tostring` dropped a `.toString()` that throws on null; the written return is bound in the declaring file — `2bdac5ef`
- typing a `.toString()` receiver by its simple name (`identTypeName` → `returnNominalOf` → `isClassType`) → `h.get()` on the imported, unindexed `far.Holder` read as the same-package `u.Holder.get()`, a class, and `s + h.get().toString()` lost the call: `sTS` became `s/OP/r` through `far.Tagish`'s `@:op(A + B)`; the receiver, the member's written return and the null proof's owners are all bound (`OperandBinder`, `ofMemberReturn` over the bound declarations) — `2bdac5ef`
- `thread-safety` over several config chains run as one analysis per chain's partition → it cuts every cross-chain edge: a callee whose only callers sit in another chain turns caller-less and is assumed main, where a one-chain run of the same files reports the real chain; one graph, each call/registration/lock site judged by its own file's chain — `2fa8cb9b`
- `thread-safety` treating a node as a sink wherever ANY chain names it → a function one chain lists as a sink is a plain call in a chain that does not, and there its own sink call must taint its callers (a lock held across it went unreported); whether `from` is a sink is asked of the chain of the edge's file, which is `from`'s own body — `2fa8cb9b`
- a graph-scoped rule gated on its INPUT by `skipReason` → a file with no `sinks` still carries the edges and `spawns` registrations other files' contexts depend on, and dropping it before the graph reported a spawned callback as main-thread; the graph reads every file but an `exclude`d one and `skipReason` gates the report (`GraphScoped`) — `2fa8cb9b`
- per-file enablement applied in `Linter.run` alone → the risky verifier and the oracle-assisted phase read findings through `Linter.collect`, so a risky `--fix` rewrote a file whose config disabled the rule; the gate lives in `collect`, defaulting on whenever a resolver is given — `2fa8cb9b`
- a multi-file finding anchored at its earliest occurrence regardless of the per-file gates → a group whose first occurrence sits in a file that disables the rule was dropped whole, so whether it was reported at all followed file order; the check anchors where the linter's per-file answer (`CrossFileAnchored`) keeps it, and `duplicate-code` hands a disabled copy the anchor — `2fa8cb9b`
- `--rule` lifting the `languageVersion` gate with enablement → the version is a correctness floor, not a preference, and `--fix --rule prefer-safe-nav` wrote `?.` into a 4.0 project; `--rule` lifts enablement only — `2fa8cb9b`
- the `fmt` blow-up on nested parens living in the parser alone → five independent `2^depth` sources: the parser re-parsing the operand `(e : T)` and `(e)` share, `CollapsePass` rewriting and walking the writer's Doc DAG as a tree, the renderer's collapse-probe search doing the same, `groupifyInlineBodies` copying it out to a tree, and the `for`-body Allman probe writing every body a second time; `@:memo` covers only the first — `a0886fd7`
- a `@:memo` shell that steps aside while a trivia stash is pending → an arrow body drains the stash and re-stashes its own newline, so on formatted multi-line input the stash is live at every nested atom and the bypass stays exponential; the stash content is part of the memo key and its effect part of the record — `a0886fd7`
- dropping an emptied stash to null at the operator clear, so the memo sees none → covers only a stash its flags were cleared out of, not a live newline stash, and changes which record later comments are pushed into; the pending-aware memo made it unnecessary — `a0886fd7`
- memoizing `WrapList.groupifyInlineBodies` over the whole Doc → it merges copies of nodes the measure render records decisions for, and `CollapsePass` reads a decision by node identity, so a copy the render never reached started answering with the other path's decision (a call's argument wrap flipped); only decision-free subtrees are shared — `a0886fd7`
- indexing `CollapsePass`'s decision lookups (`opens` / `capturedIndent` / `capturedNestBase`) by node identity instead of a linear `find` → byte-identical but not visible in a `fmt` profile at all; the pass's cost is elsewhere — `a0886fd7`
- `prefer-switch` taking statement branch bodies verbatim because they "carry their own `;` / `{}`" → the `;` before an `else` is elided, so `if (c) a else b;` hands over a bare `a` (and a bare `return 1` / `throw e` / `break`), and the emitted `case 1: a case 2:` fails with `Missing ;`; a body not ending in `;` or `}` now gains one — `cc24d350`
- relying on the `--fix` re-parse gate to catch a `case` body with no `;` → this parser accepts `case 1: a case 2: b`, which `haxe` rejects, so only the compiler oracle's safe-pass build noticed and reverted the file — `cc24d350`
- detecting an elided `;` structurally, from a statement span ending past its child's → spans absorb trailing whitespace (bare `break ` is `ExprStmt @52-58` over `BreakExpr @52-57`), so a gap does not mean a `;`, and a childless `break` / `return` has no child to compare against — `cc24d350`
- `prefer-local-function` dropping a declared function type because "the literal's own signature reproduces it" → the declaration infers its result from the body, and an inferred `{ report: … }` does not unify with a declared structure of `final` fields; the declared result is now carried as the return hint, and a literal whose parameters do not spell the declared ones is refused — `cc24d350`
- carrying a declared `Void` result as `:Void` over a lambda's expression body → `return x + 1` in a `:Void` function is `Int should be Void`; that body is wrapped in a block instead — `cc24d350`
- `prefer-bind` accepting any identifier or dotted chain as a "stable" argument → `bind` reads it at creation time, so a local written later, a field or a static hands the callback a stale value (a `var` set to 5 after the lambda read 1), and a nullable capture the lambda passed on fails null safety as a `bind` argument; only never-written, non-nullable, nominally typed locals and parameters and literals are bound, and a field or longer-chain receiver is refused — `cc24d350`
- `prefer-bind` taking a bare callee name, `this.m` or `local.m` as a stable method because it is not a field → a `dynamic` method or a function-typed `var` rebound after the callback is created keeps the OLD function under `bind` (`dyn orig` instead of `dyn NEW`), and a macro, `@:generic`, `extern inline` or overloaded method has no closure at all (`Cannot create closure`, `Macro functions must be called immediately`); the callee is now proven through the index to be one plain method, and anything the index cannot answer is refused — `cc24d350`
- `prefer-local-function` checking only reads BEFORE the hoist point → a read of the binding's own name inside the literal meant an OUTER function (the local is not in scope in its own initializer) and the hoisted `function g` turned it into unbounded recursion — `cc24d350`
- `prefer-bind` proving a callee through whatever declaration the index holds → the index sees the target-shared std, while `std/js/_std` makes `String.charCodeAt` / `Array.contains` `extern inline` (`Can't create closure on an extern inline member method`); only a non-extern type from the project's own roots is bound now — `cc24d350`
- `prefer-bind` treating an implicit `this` as fixed for every type → an abstract's inline method may reassign `this` after the callback is created, and `plain.bind(v)` kept the old value (`200` became `6`); an abstract's instance method through an implicit `this` is refused, while a class `this` cannot be reassigned — `cc24d350`
- a `dropSingleStmtBraces` body never re-emitting its `@:trailOpt(';')` slot, on the premise that a statement owns its own terminator → a `#if … #end` region whose last branch ends unterminated (`if (x) a() else #if d b() #else c() #end;`) leaves the `;` after `#end` as the statement's ONLY terminator, and `fmt` dropped it into `Missing ;`; the slot is now kept from source presence for a region body (`@:fmt(trailOptKeepIf)`), and still dropped after a braced body — `a433a910`
- the block writer dropping a source `;` after the LAST element whenever `stmtNoSemi` holds for it → a `#if … #end;` region before `}` lost the only terminator of its last branch (`Missing ;`); the drop is now waived for the element `@:fmt(trailSepKeepIf)` names, and still applies after a `}` or a local function — `a433a910`
- a lint fix moving an if / loop body by its node span carrying the whole statement → a region body's `;` sits in the PARENT's span, so `collapsible-if`, `invert-negated-if-else` and `redundant-else-after-return` dropped it and `empty-statement` deleted it; `RegionTerminator` owns it now — `a433a910`
- an element separator the block writer keeps being written after the element's trailing comment → `#end; // c` commented out its own `;` and `fmt` refused the file as dropping `// c`; the separator now precedes the comment (`_sepGlued`) — `a433a910`
- `Refs` projecting a bare `case` pattern identifier as a READ of the outer binding ("an enum-pattern binding is not a declaration") → Haxe binds it as a new capture for the arm and never compares it with a same-named local, parameter or field (`--interp`), so `inline` spliced the outer initializer into the pattern and `rename` renamed a pattern the outer binding never reached; one definition (`CasePatterns.scan`) now feeds the resolver and the case-arm rules alike — `24ce03a4`
- an in-scope local deciding a bare pattern name as a capture → an `enum abstract` value of the subject's type outranks the local and compares (`--interp`), while a local outranks a `static inline` of the same name; a pattern name any constant declaration may claim therefore stays undecided, and a rewrite over it refuses — `24ce03a4`
- an outer binding of the same name deciding a bare pattern name as a capture → the subject's type decides (an `enum abstract` value or a lowercase enum constructor of it compares, ahead of the local), and so does a static import (`import X.c`, `import X.*`); a bare capture is proven only through the expected type — the subject's written type, a dynamic subject's element, an in-file constructor's parameter type — and anything else is undecided — `24ce03a4`
- a NEGATIVE list of what a bare pattern name may be a constant of (the subject's type, in-file constants, the file's own static imports) → it kept missing tiers: a module-level `final` / `inline final` compares, and so does a static the ambient `import.hx` chain brings in (`--interp`); the rule is now positive — decided only when no tier of the file's lookup order the compiler consults may bind the name (`PatternNameScope`), and undecided wherever a tier cannot be read — `24ce03a4`
- only a module's enum values reaching a file through `import pk.Mod;` → a whole-module import brings its module-level fields in too, and a bare pattern compares against them (`--interp`); `import pk.Mod.*` and `import pk.*` do not, so those capture — `24ce03a4`
- every name a lookup tier binds making a bare pattern compare → only a constant does: an instance field, a method, a `static var`, a supertype's static, a `using` static and `trace` all CAPTURE (`--interp`), so `PatternNameScope` asks the enclosing type's statics, module-level fields, the module's enums, explicit / alias / type-wildcard imports and the `import.hx` chain, and not the rest — `24ce03a4`
- a capture visible from its arm's first byte → an extractor's left side is an expression evaluated on the subject and reads the OUTER binding (`case add(_, n) => n:`); a capture is visible from the end of the pattern run — `24ce03a4`
- the or-pattern `A(n) | B(n)` staying outside the pattern whitelist as a safe refusal → it is an ordinary pattern shape whose sides bind the same names; modelled via `RefShape.orPatternKind` — `24ce03a4`
- a `static var` named bare in a pattern comparing like a `static inline` one → only the inline field compares, a plain static captures (`--interp`); the constant set keeps every static anyway, because it is only ever read as "may be a constant" — `24ce03a4`
- `inline`'s free-identifier check (every initializer name is a stable local) making the substitution safe → at a read site a lambda parameter or a `case` capture of the same name rebinds the substituted identifier, which the check never looked at; the rewrite is now re-resolved and refused when any initializer identifier binds elsewhere — `24ce03a4`
- checks hand-scanning type TEXT because `GrammarPlugin` has no way to parse a type fragment → half of it: a declaration's annotation was already the `QueryNode.type` slot (in `parseFile`), and `trivial-getter` still re-scanned the declaration it held; what was missing was a reader for a type that arrives as text, now `GrammarPlugin.typeSyntax`, into which the arity-only `FunctionTypeProvider` folds — `2a494fd0`
- every `'<'.code` depth counter in `check/` and `query/` reading a type → about half do not: the compiler-facts grammar (`FactsTypeSpelling`, `StaticExtensionFacts.firstParamOf`), declaration-header type-PARAMETER lists (four copies — the projection drops the names), a declaration head (`NewLiteral`), a `new` expression (`LiteralInfer`), a multi-declarator (`TailMerge`), selector / pattern / comment text; none is `typeSyntax`'s question — `2a494fd0`
- the `type` slot answering a declaration's annotation for every consumer → `parseFileTypeRefs` never fills it, so `prefer-map-type` reading the slot found no pin (seven fixtures red); the head scan stays, once, in `NewLiteral.pinningTypeHint`, which now hands the hint over instead of a second scan re-finding its colon — `2a494fd0`
- `avoid-dynamic`'s annotation scan moving to `typeSyntax` → its regions are not one type: an anonymous structure's fields project as flat `TypeRef` children with no `type` slot, so the region boundaries come from the projection rather than from a type text — `2a494fd0`
- a type text the grammar reads having to be undecorated (a comment around it answering null) → the parser treats comments as trivia, and declining them silently dropped `optional-param-shorthand`'s finding on `x:Int /* id */ = null`; comments are trivia, and a consumer that splices the text back checks `text == input` itself — `2a494fd0`
- a typed-AST span ending at the type's last token → an `ArrowFn` span runs on over the whitespace the parser skipped after it (`(Int) -> Int ` before `=`), which doubled a space in `prefer-local-function`'s return hint; `HxTypeSyntax` cuts the tail — `2a494fd0`
- a declaration header's type-PARAMETER names needing a text scan because the projection keeps only their constraints → the span-info walk already collected every name, for `importMap`, just not per declaration; keyed by the declaring node's span (`TypeInfoProvider.typeParamNames`) it replaces five header scanners, and the "names unreadable, arity known" state `paramsReadable` guarded cannot occur — `46960771`
- a comment before a typedef's target forcing the alias to fall back to the target's SIMPLE name → the comment is trivia to the grammar, so the written path is kept and a qualified target with a namesake resolves — `46960771`
- the type-refs tree needing a `type` slot for `prefer-map-type`'s pin → `declaredTypeSources` already keys that annotation by the same span, and a slot there prints every annotation twice in `ast --type-refs` — `46960771`
- `?` as the substituted placeholder that names no type → the grammar cannot read `Array<?>`, so every later read of a substituted type refused where the outer type used to resolve; `$_` is a splice the grammar reads as a type naming nothing — `46960771`
- an anonymous-structure field needing a `type` slot for `avoid-dynamic` → the slot doubles every such field in `ast`; `declaredTypeSources` has the type text and it ends the field's span — `46960771`
- `tail-merge`'s depth-0 comma scan catching declarators the tree misses → every continuation is its own node, `var a, b;` included, so the scan is a continuation-node test — `46960771`
- `thread-safety` counting callers in `exclude`d files as resolved callers, so a function only tests call stops being assumed main → it lost a real stall: the app reaches `VolumeWatcher.saveContent` through a type-parameter receiver (`watcher:W`) the graph cannot resolve, and the test was its only RESOLVED caller; an excluded file stays out of the graph — `5e812831`
- a `catch` entered from ANY point of its `try` (every call may throw) in the lock window → every lock taken and released inside a `try` whose `catch` returns read as leaked, so O(1) queue locks became long; an exception a call raises is out of the lock model, an explicit `throw` is not — `5e812831`
- a `throw` ending its path WITHOUT leaking the lock (an exception-safety defect, not a hold) → a lock a throw strands stalls every later taker for good, and it is the only written evidence that `ShardDatabase._mutex` is ever held long while SQL is not a configured sink; dropping it lost ten true main-thread stalls — `5e812831`
- every release with no take of the same lock in its body meaning a hold that crosses functions → `tryClose` takes `_mutex` by `tryAcquire`, which no `lockPairs` entry names, and made the lock long; a body that makes any other call on the lock is releasing what it took — `5e812831`
- `LockSites` keeping a member sealed through every method-call receiver occurrence, on the claim (made in `c2c941a1`) that a lock call through a receiver no member names could never fire → it fires: `d._m.acquire()` on a `Dynamic` `d`, `(cast o)._m`, `o._m` on a type-parameter `o:T` resolve no edge at all yet read like receivers, and kept `_m` sealed and short (review probes p8/p9); a receiver occurrence keeps a member sealed only when an invocation edge at that call names that member — `0d0452e6`
- the constructor exemption refusing any instance dispatch → every call on a lock field (`m.acquire()`) dispatches on the lock's type, so no constructor was ever exempt once the check covered the whole body; only a dispatch on the constructor's OWN type can hand `this` on — `c2c941a1`
- a type parameter's bounds read off the `QueryNode` projection (the `(Named A)` children of a `<T:A & B>` declaration) → the projection keeps only the FIRST bound of each parameter, untied to the parameter's name, and drops the `& B` tail; the bounds are a `TypeInfoProvider.typeParamConstraints` map from the span-info walk instead — branch `batch/typeparam-receiver`
- a type's parameter bounds keyed by the span of the node `CallGraphNames.typeNameOf` answers for → a `final class` is a `FinalDecl` wrapper whose parameters the span-info walk keys on the inner `ClassForm`; the lookup goes through `RefactorSupport.typeDeclOf(..).nameNode`, and the client's `final class StandardDiskSystem<W:VolumeWatcher>` resolved no `watcher.*` call until it did — branch `batch/typeparam-receiver`
- a receiver's type parameter looked up from the CALL site's scope (every function on the frame stack, then the type) → a function's own `<T:B>` captured the `T` a field or an outer parameter was declared with, and `item.m()` went to `B.m` instead of `A.m` + overrides (review probes p1/p2); the lookup now starts where the receiver's type was WRITTEN — a local/parameter's binding offset, a member's declaring type — and an unknown origin resolves nothing — branch `batch/typeparam-receiver`
- type-parameter bounds keyed by simple type name → `p1.Gen<T:A>` and `p2.Gen<T:B>` shared one entry, last walked wins; keyed by file + name now — branch `batch/typeparam-receiver`
- an abstract's underlying type read as its first annotation CHILD → a bounded `abstract X<T:B>(Foo)` projects `B` among the children first, so `this.m()` went to `B.m`; the declaration's `type` slot holds the underlying (since `8be07861`), and one of the abstract's own parameters (`abstract W<T:A>(T)`) resolves through its bound — branch `batch/typeparam-receiver`
- `comparison-to-boolean` honouring class-level type parameters and missing only method-level ones → neither was honoured: `DeclaredNullity`'s value-type fast path (`isValueType` / `ofBinding`) read a binding written `Bool` as the value type before any type-parameter scope was consulted, so `class B<Bool>` and `function f<Bool>` both fired and both fixed; the two resolved arms (member type, method return) had the same hole through the declaring type's parameters
- a `final class` addressed as `ClassDecl:X` costing only a documented `replace-node` quirk (its span excludes `final`) → the same span was `patch`'s search region, so no fragment spelling the header could match, and `remove-element` deleted the inner form and left `final` to glue onto the NEXT declaration (`final abstract class Y`, rc 0); `abstract class`, `interface`, `enum abstract` carry their keyword in their own span and were never affected, `extern` / `@:meta` sit beside the wrapper
- a `m[k] != null` guard proving a later `m[k]` read under the same name-keyed kill the `m.exists(k)` fact rides → an entry's VALUE changes under a call, a `new`, an index or field write and a loop's back edge without either operand's name being written, so value facts die at each of those; and a join of an `exists` fact on one path with a value fact on the other (`if (!m.exists(k)) m[k] = 1;`) stays unproven
- `private` making a predicate method non-overridable (so its `return i != null && …` body answers every call) → a Haxe `private` member is visible to and overridable by subclasses; only `inline`, `static` and `final` (and not `dynamic` / `macro` / `overload` / `@:overload`) pin the body a bare call runs, and a same-named local function, parameter or capture anywhere in the file refuses the proof
- a true non-null predicate call proving its ARGUMENT non-null → it proves its PARAMETER non-null, and an implicit conversion between the two (an abstract's `@:from` / `@:to`) turns a null argument into a non-null parameter (`valid(n:Null<Name>)` called with a null `String`); the argument now counts only when its binding is written with the parameter's own type text, and only `unguarded-nullable-deref` passes the written types, so no other `NullFlow` consumer (`dead-null-coalescing`, `dead-null-guard`, whose `--fix` rewrote `s ?? 'fallback'` to `s`) sees a predicate at all
- `thread-safety` lock wrappers only of a NAMED lock → the client's `_mutationMutex` is handed to `RemoteDiskSystemBase`'s constructor and so names no lock, and `acquireMutationMutex` stayed invisible with every hold under it (`saveXML`, `loadXML`); a wrapper of an unknown lock makes each call a take of an unknown lock, which the rule already reports whatever thread holds it — `ace2afd3`
- a take wrapper as any function whose one lock call is a take left held on SOME path out → 20 client functions qualified, cascading from `NetToken.apiSharedLock` through `doRequest`/`go`/`refresh` because their release sits in a callback or behind `#if !html5` (`apiSharedUnlock` releases on no path the walker can prove); the take must run on EVERY path in, reached through statement sequences alone, and client has 10 wrappers — `ace2afd3`
- "overrides nothing outside the scope" as `chainFullyIndexed` → no class extending an unindexed library type could wrap (`ShardDatabase extends EventDispatcher` lost `batchLock`); only an INDEXED outside declaration of the name refuses, the convention `ReachAdmission.overridesLibrary` already uses — `ace2afd3`
- `quietRoots` turning only the MAIN bit quiet → a background thread through a quiet root that marshals back to main was loud again (`DebugTunnel.runOnMainThread`); each thread carries its own quiet bit, and a callback registered from quiet code is quiet on whichever thread it lands — `ace2afd3`
- an expression body (`function lockIt() m.acquire();`) as an opaque step of the lock walker → such a function was never a wrapper; `RefShape.expressionBodyKinds` are sequences of their one expression — `ace2afd3`
- re-entrance dropping the client's 29 re-take holds under `ShardDatabase._batchMutex` → with `reentrantLocks: ["Mutex.acquire"]` the re-take evidence goes (11 grouped findings change their evidence), but none of those holds disappears: each held call also reaches `ShardDatabase._mutex` (through `addCloudAction2`), which is long because it is held across `Connection.request`; that class was triaged F (`nested-short-lock`) and only a verdict on SQL cost can drop it — `42a59b25`
- re-entrance built in for `Mutex` → the check is grammar-agnostic and every lock fact it knows is config (`lockPairs`); `reentrantLocks` names the take members whose lock the holder may take again, default none (`GateMutex` is a binary semaphore, a re-take of it under its own hold is a self-deadlock) — `42a59b25`
- the taint helpers as a private class inside `ThreadSafety.hx` → a sub-module type is no mutation-arm target (a record's `type` is also the file path the runner patches), so the moved `blocks`/`collectTaint` arms lost their member; `LockTaint` is its own module — `42a59b25`
- re-entrance by lock MEMBER (`lock == held`) → `other._m.acquire()` under a hold of `this._m` read as a free re-take and dropped a real cross-object wait (review probes q1/q2); re-entrance now needs both takes provably on one object — a static lock, or bare/`this` receivers and calls — and on the client corpus it frees nothing: every `_batchMutex` hold there is taken through `cloudDatabase.batchLock()`, another object's — `4397ba50`
- a quiet root quieting every path through it, and quiet carried into callbacks and marshalled work → a root a loud UI handler also calls silenced that handler's whole reach, and a listener it stores fired later from loud code unreported (probe q5); a root stays quiet only while no loud invocation reaches it, and a callback or spawned work never inherits quiet — so the client's roots move to the handlers (`Editor.applicationExitHandler`, `DebugTunnel.runOnMainThread#8`) — `4397ba50`
- the lock alias as a pure rename on the client corpus (16 `Mutex.acquire` holds -> `StandardDiskSystem._mutationMutex` — the commit message of c24d6c11 says 17, the 17th `Mutex.acquire` hold is `Logs.init#1`'s local mutex and stays; nothing else moves) → one more finding changed: `StandardDiskSystem.deleteItem`'s hold of `ShardDatabase._batchMutex` gained `VolumeWatcher.delete -> VolumeWatcher.lock -> GateMutex.lock`. The unknown `releaseMutationMutex()` used to count as a possible release of ANY `Mutex` pair lock (`lock == null || other == null || other == lock`), so it closed the `_batchMutex` window early; named, it no longer does, and the window runs on through the path where `if (!batch)` took the lock but skipped `batchUnlock()` — infeasible (both test one unchanged `batch`), a LockWindow branch-correlation limit the conflation had hidden, not a new defect — `c24d6c11`
- re-entrance across an alias (a take of `B._l` under a hold of `this.m`, both named `A.m`) → a subclass `B extends A` holds its own `A.m` and, in `_l`, the `A.m` of whoever built it: one name, two objects. No take of an aliased lock is `selfTake` (static locks aside); on the client corpus that frees nothing, since `_mutationMutex` was an unknown lock, never re-entrant, before — `c24d6c11`
- the alias proof inside `LockSites` → it took the type to 61 members (`oversized-type`, max 50) and `handOffs` to complexity 26; `LockAliases` is its own module, `handOffs` split into `newHandOff` / `superHandOff` — `c24d6c11`
- refusing a lock alias on ANY reflective construction whose class argument is not a literal type (review round 1) → client has three `Type.createInstance` sites: `Node.hx:121` (`resolveClass(name)`, `[]`), `Popup.hx:146` (`getPopupTabButtonClass()`, five arguments) and `FormGroup.hx:26` (`controlClass ?? cast RoundedTextField`, an unknown `cast controlParams ?? [...]`), so the rule as stated drops the client's alias on the last two. A class value is instead judged by its WRITTEN type: a `Class<T>` parameter or return (T a declared type, or a type parameter by its bounds — `FormGroup`'s `C:FormControl<T>`), a bare type name, through parens, unchecked casts and `??`; it is safe when every bound is unrelated to the aliased type's family (none of it, none of its supertypes). Otherwise the argument must be an array literal that stops before the first hand-off position (`[]`). `resolveClass` / `resolveEnum` / `Reflect.*` only produce values or touch fields — the construction they feed is the `createInstance` judged here; `createEmptyInstance` runs no constructor. Cost: `CallGraph` grows one accessor (`typeParamBoundsOf`), so its `oversized-type` finding reads 53 members instead of 52 — `a759d849`
- a static alias source counted one object like any static lock → `static var S`, `renew() S = new Mutex()`: `_l` keeps the OLD `S`, so a take of `S` under a hold of `_l` read as a free re-take (review probe r1). A static aliased lock whose member any code writes (outside its initializer) is no longer `selfTake` — `a759d849`
- walking constructions in `exclude`d files for the alias proof (review round 1, probe ex/e2) → on the client corpus it drops the alias: `src/tests/unit/RemoteDiskSystemBaseTest.hx:539` builds `new TestRemoteDiskSystem(_mockFs, new Mutex())`, a real second lock through `super(..., mutationMutex)`. `exclude` keeps meaning "this code is no part of the analysis", as it already does for sealing (main hides a leak in an excluded file the same way); a project whose excluded code shares the app's objects must not exclude it — `a759d849`
- `Reflect.setField(b, "_l", k)` writing an aliased member by string (review probes s9/s13) → pre-existing: sealing is judged by name over the AST and never saw string writes; the alias inherits that blind spot rather than opening it. `ExecutionShape.reflectiveNameCalls` is the seam that would close it for both — `a759d849`
- `--rule` as its own switch for the text report (a narrowed run always lists) → `--rule magic-number` over the client corpus `src/` is 5353 findings, the very flood the summary exists for; the one decision is the `reportSummaryThreshold` (default 200), and a one-rule summary is a by-file breakdown — branch `batch/lint-summary`
- per-file lint consumers never reaching a 200-finding threshold → with `--all` four client files do (`AnimationPhaseTest.hx` 610, `StringUtil.hx` 328, `RemoteDiskSystemBaseTest.hx` 285, `AnimationRoundTripFileTest.hx` 204); the lint-warn hook greps `<file>:<l>:<c>:` lines and now asks for `--full` when the engine offers it, and the workflow engine's `hxq-lint-file.sh` needs the same
- one more project key costing `LintConfig` one field and one accessor → it sat at exactly 50 members (`oversized-type` max 50); `describeOracle` / `oracleKey`, pure functions over an `OracleConfig`, moved to `OracleDeclaration`, the summary default to `LintFormat`
- `ignoreCallArguments` matching the RESOLVED callee (the declaration `t` binds to) → the rule is a per-file syntactic walk with no symbol index, and client writes `t` bare through `import macros.Lang.t;` in 190 files; the entry matches the tail of the callee path as WRITTEN, so `["t"]` is the client spelling and `Lang.t` deliberately does not reach a bare `t(…)` — branch `batch/lint-summary`
- a negated literal as a direct argument (`t('x', -5)`) → the grammar parses it as `Neg(IntLit 5)`, so the call is not the literal's parent; left flagged, the same "direct only" line that keeps `t('x', 100 + k)` flagged — SUPERSEDED by N29: Haxe has no negative literal, so `-5` IS the argument and `f(-18)` is exempt exactly when `f(18)` is (client `setHitArea(-16, 4, 80, 64)` under `["setHitArea"]`); the negation hands the key context to its operand alone, so `t('x', -k * 4)` keeps its `4` — branch `feat/infra-N29`
- the constructor spelling for `ignoreCallArguments` (N29): a bare `SpriteDescriptor` matching `new SpriteDescriptor(…)` → it would make one entry mean a call AND a constructor, and Haxe already spells a constructor used as a value `SpriteDescriptor.new`; an entry is matched against the constructed type's path followed by `RefShape.constructorName` (`new data.T(…)` is `[data, T, new]`), with the usual tail rule, type arguments excluded (`Map.new` reaches `new Map<String, Int>(…)`). Nothing is exempt unless listed; a bare `new` entry would reach every constructor — branch `feat/infra-N29`
- a `Point` built inside a listed constructor's argument (`new SpriteDescriptor(id, new Point(-18, -83.75))`, client AssetLibrary ×71) → listing `Point.new` would exempt every layout `new Point(x, y)` in the project; instead a constructor that is ITSELF a direct listed argument (a value object built in place) carries the key context to its arguments. Through `new` alone: an ordinary call (`make(5)`) or an operator inside the argument resets it, because its literals are that callee's or that expression's, not the listed one's — branch `feat/infra-N29`
- magic-number literal tables as an option (`literalTables`, default off) rather than a default (N29) → a default would silently drop findings in every project already linting; the shapes are positive: a switch whose every arm is `Plain` patterns of scalar data / `_` / or-patterns of those plus ONE `ExprStmt` of scalar data (`DefaultBranch`: the statement alone) — a guard, a capture, a block body, an unknown arm kind make it no table, and the subject is walked as logic; a collection literal (`LiteralTables.isCollectionTable`) only when NAMED — the direct initializer of a local, or the sole return of a function body (client `Base64.initDecodeChar`). An inline `draw([3, 4])` has no name. No naming requirement for a switch, whose patterns ARE the keys — branch `feat/infra-N29`
- the collection-table predicate moved out of `StringLiteralDup.isTable` / `isDataEntry` into `LiteralTables` (N29) so `magic-number` asks the same question instead of a second copy; the shared datum also admits a negation over a childless numeric literal (`-1`) — a negative number is data — which changes `string-literal-dup` only for a collection literal that holds a negative number beside its strings (a map `"aaaa" => -1`), now a table like its positive twin — branch `feat/infra-N29`
- a project-side `.apq/` line in every `.gitignore` → hxq owns the directory, so it writes `.apq/.gitignore` of `*` itself (the pytest / ruff / mypy cache shape); the write sits inline in `OracleGeneration.prepare` rather than in a helper member because the type is at `oversized-type` max 50 — branch `batch/interp-literal`
- `prefer-interpolation` writing the client's `'${0} ${i + 1}'` → it rewrites only `Std.string(x)`; the chain `0 + ' ' + (i + 1)` was merged by `fold-adjacent-string-literals`, whose seam decomposed the `0` operand as an expression — the fix is `StringFoldSupport.constantText` (a target-invariant literal decomposes as TEXT), which covers the chain and a literal's own `${0}` alike — branch `batch/interp-literal`
- cleaning an EXISTING `'${0} …'` inside `fold-adjacent-string-literals` → that rule reports on PARTITIONS, and a literal whose constant block becomes text keeps its one-group partition, so it never reports it; `prefer-interpolation` already walks interpolation blocks and re-renders the literal through the same seam
- a `${x}` → `$x` rule to host the constant case → none exists; the fold renderer already writes `$x` where it can, and the constant fix re-renders the whole literal through it
- splicing a `Float` literal as text → `1.0` prints `1` on js and interp and `1.0` on python; an `Int` past `0x7FFFFFFF` wraps (`0xFFFFFFFF` prints `-1`) or types as `Float` (a decimal past `2147483647`), so both keep their `${…}`
- `concatFoldingMacros` lifting the `prefer-interpolation` macro refusal too → the entry claims a macro folds a `+` chain of constants; every rewrite of that rule changes a literal's TEXT, which a text-keyed macro (the client's `Lang.t`) still reads as another key, so its gate runs with an empty whitelist — branch `batch/interp-literal`
- a separate engine for `prefer-count` beside `BoolLoopScan` → it is that engine's FLAG form with a counter for the sink and no short-circuit; a third `LambdaLoopKind` reuses the pairing, the `Iterable` proof, the shadow fallback and the `using` insertion, and the engine is renamed `LambdaLoopScan`, since it is no longer bool-only — branch `batch/prefer-count`
- a purity gate on `prefer-count`'s condition, as the flag forms of `prefer-exists` / `prefer-foreach` carry → `Lambda.count` walks the whole collection and calls `pred` once per element in order, never short-circuiting, so an effectful condition runs exactly as often as in the loop; the gate would only refuse sound sites — branch `batch/prefer-count`
- `xs.count()` for every UNFILTERED count → over the std `Array` / `List` the answer is the container's own `length`, so the fold emits `xs.length`: no walk, no closure, no `using`; which container that is is decided by the WRITTEN type (see the `length` entry below), so a `Null<Array<T>>` binding keeps `count()` — branch `batch/prefer-count`
- keeping `Map` out of `prefer-count`'s CALL-iterable accept list, as `ITERABLE_TYPE_NAMES` does for `exists` → no map declares `count`, and `m.count()` / `m.count(f)` compile on `Map` and every concrete `haxe.ds` map (`HashMap` and `Vector` answer `has no field count`), so that direction adds `DeadBinderCounterLoop.COUNT_TYPES` — branch `batch/prefer-count`
- claiming an identifier / field iterable with no type check at all, as the engine did for `exists` / `foreach` → a field typed `Iterator<T>` (`haxe.xml.Access.elements`) is iterable by `for` and rejected by every `Lambda` call; a receiver PROVEN an iterator and not an iterable (structurally, by its members) is now refused for all three directions, which also stops the trusted `prefer-foreach` fix from writing `it.foreach(…)` — branch `batch/prefer-count`
- `RefactorSupport.isSideEffectFree` as the flag-form purity test of `prefer-exists` / `prefer-foreach` → it refuses a field access outright, which is exactly the one convertible measured site's condition (`child.nodeType == CData`); `PurityScan.isPure` reads a field or index READ whose first hop is not a property getter as pure (moved from the `LambdaLoopScan` type doc) — branch `batch/prefer-count`
- claiming the GUARDED flag form (`var f = false; if (g) for … f = true;`) or a GAP between declaration and loop → the guarded sites fail the purity gate anyway and the non-adjacent ones are effectful, so both would buy nothing and owe the `&&` merge reasoning a second time (moved from the type doc) — branch `batch/prefer-count`
- the `foreach` mirror of the guarded return form (`if (g) for … return false;` + `return true;`) → it needs `!g`, a guard is typically a null test, `!(xs != null)` narrows nothing and strict null-safety narrows an `||` chain only from its first operand (moved from the type doc) — branch `batch/prefer-count`
- De Morgan for the `foreach` inversion → distributing `!` through an `&&` chain reorders the operands a null narrowing depends on; the inversion is a WRAP `!(…)`, and an already-negated condition drops its `!` (moved from the type doc) — branch `batch/prefer-count`
- a separate gate against the loop binder leaking out of the fold → the body is the `if` and the sink, so the binder can occur only in the condition by construction; a gate that cannot fail is one nothing can test (moved from the type doc) — branch `batch/prefer-count`
- `prefer-find`'s blanket refusal of every CALL iterable, for these directions → a call yielding an `Iterator` (`m.keys()`) is refused BY TYPE and `text.split(' ')` is provable, so only an unresolved call keeps the refusal (moved from the type doc) — branch `batch/prefer-count`
- scanning only the CONDITION for the sink's name → the fold moves the ITERABLE into the initializer too, and `for (x in rows[n]) n++;` became `final n = rows[n].count();`, reading an outer `n` and compiling; the scan covers both, and counts only UNQUALIFIED reads outside inert literals and comments (`item.found`, `'found'` are not reads of a local `found`), which is what keeps the pre-existing flag sites converting — review of `f86c0e4e`
- refusing a proven `Iterator` by the NAME `Iterator` → `haxe.iterators.ArrayIterator`, `IntIterator`, `StringIteratorUnicode` and a project class with `hasNext` / `next` are iterators under other names; the refusal is structural (`StructuralTypes.satisfiesIterator` and not `satisfiesIterable`), and a construction `new T(…)`, which the expression resolver does not type, is judged by the `T` it writes (`CodepointIndexTest`'s `new haxe.iterators.StringIteratorUnicode(s)`) — review of `f86c0e4e`
- the `length` spelling on a RESOLVED simple nominal `Array` / `List`, then on its written spelling (bare or `haxe.`), then on a list of things that could capture a bare name → each round of review found the next capture (`import p.List`, the same package, `using lib.List`, an unindexed module's sub-type, `haxe.mine.List`, a library's root `List`, a root-package project type outside the index); the proof is now POSITIVE and lives with type resolution — `SymbolIndex.resolvesToStdType`: exactly one declaration, under the discovered std root, every import / `using` / wildcard in scope resolved by the index and no alias spelling the name — over a run whose declared `resolutionRoots` all matched (`RefactorSupport.projectIsComplete`). It closes the same silent hole in `dead-binder-counter-loop`'s `length` arm. An unbounded ambient `import.hx` chain is no proof either. What remains is the cost, not a hole: the proof costs every project without complete `resolutionRoots` its `length` rewrite (`count()` in `prefer-count`, no claim in `dead-binder-counter-loop`) — review of `f86c0e4e` / `c3d002d0` / `932529fc`
- keeping `dead-binder-counter-loop`'s QUALIFIED `Lambda.count(coll)` arm for a container declaring `count` → with the container proved std, no `COUNT_TYPES` entry declares one, so the arm (`countShadowed`, `lazyQualified`) was unreachable and is gone; `prefer-count` keeps its own qualified fallback, which judges the receiver it actually iterates — review of `932529fc`
- deciding the comprehension object literal's Allman move by HOISTING its width decision above its `WrapBoundary` (or by reshaping the decision's break side into a real `Nest` + hardline) → the hoisted decision sits outside the boundary, so a NoWrap array's `Flatten` pins it flat and the line overflows; and every layout decision that measures the body's BREAK side (`DocMeasure.breakableHead` behind a declaration's `=`) reads a head that now ends at `)` instead of `{` and stops breaking the `=`. The Allman break is a render-only `Doc.LeadingBreak` on the literal's own break side, invisible to every walker — review of `fa078695`
- deciding the cuddled-open head for a comprehension whose literal may break STATICALLY — the item's flat width at the ladder indent (`IfIndentWidthExceeds`), gated off when the head could break first → a head decision that renders flat was still read as "can break", the literal's column after a head that DOES wrap is known only to the renderer, and the array's own mode rules (`hasMultilineItems`) read the break too. The list is now laid out both ways and a measure render picks the layout by whether the literal's break was taken (`Doc.BreakCommit`, `BreakCommits`) — review of `8fd5c65b`
- `ConditionalSemiExpr` as an `HxExpr` atom for `x = #if a v; #else w; #end` → Pratt keeps going after `#end`, so `#end (f)()` read as a call of the region and an else-less region was mis-read; the region is a STATEMENT (`CondSemiAssignStmt`) whose value is structural (`HxCondSemiRegion`, `#else` mandatory) with a no-`;`-after-`#end` guard (`HxNoSemiAhead`) — branch `fix/reach-library-precision`
- a raw regex region for the semicolon-carrying conditional value → raw is kept only where the branches cut the syntax itself (`CondSpliceCallOpen`, `CondSig`); a region whose branches are whole statements is parsed — branch `fix/reach-library-precision`
- per-shape heuristics to trust a build-macro type's text (`builtAsWritten`, inline/super exemptions) → point patches for one shape each; a body's text is trusted only when the compiler's facts ARE that text (`FactsProvenance.bodyIsSource`), and the general answer is the facts-as-truth campaign — branch `fix/reach-library-precision`
- `prefer-keyvalue-loop` refusing a binder spelled ANYWHERE in the outermost enclosing function → a sibling loop's own binder is no clash; the refusal is the loop's own text plus a declaration visible where the loop stands (`ShadowingLocal.boundAt`) plus a member/module value — branch `fix/reach-library-precision`
- dropping every `Untyped` / `Unmodelled` hazard of a faceted body under the truth, as the facts-as-truth design (S1b) proposed → `untyped this["items"].push(1)` types as an index read of `this` and a Dynamic `push`, and no fact names `items`, which the js build writes; an untyped BLOCK (`untyped { … }`) is `Unmodelled` and hides the same. Only an `untyped` expression built of identifiers, field accesses, calls, parentheses and constants gives way to the facts (`ReachHazards.untypedRecorded`); a native call gives way to the facts' `natives`; `Opaque` stays until a faceted body can hold a conditional region at all — branch `facts/s1b`
- reading a reflective call's literal NAME off the facts → `TypedFactsWalk.reflection` records the first string literal of ANY argument, so `Reflect.setField(o, computed, "v")` would name `v`; a reflective call only the facts see (an alias, an import) names nothing (`DynamicName`), and one the syntax sees keeps the syntax's name — branch `facts/s1b`
- compiler facts: a faceted function keeps every syntactic edge (`be636ec3`) and a body holding a directive, or resolved through a declaration some build may read otherwise, keeps its syntax — also under a list of builds declared complete → when the facts name exactly those builds (`FactsView.truth`) no unlisted build exists to read a name the syntax's way, and the facts hold every branch a listed build takes: `conditional` and `contextAlike` are skipped, and a faceted body's syntactic edge at a site its facts type (the same range) is dropped; one at a site they do not type — a spliced local `inline function`'s call, a branch no build compiles — stays — branch `facts/s1`
- a body an inlined function was spliced into (`inline-site-unknown`) keeps its syntax, since no range places the splice — also under a list of builds declared complete → under the truth it is faceted: the splice's facts are the body's, at the callee's positions, so a range question takes them from every faceted body it meets (`CompilerFacts.within` with `spliced`, `MemberReach.splicedInto`), and the `inlined` call is an edge to the callee's node; a macro's expansion and a stale file still keep the syntax — branch `facts/s2a`
- telling a spliced fact by its FILE (`at.file != node.file`), as the facts-as-truth design (S2a) proposed → an `inline` method of the caller's own file is spliced at ITS range in that same file (`TypedFactsProbe`: "another file or elsewhere in its own"); a fact is placed only inside its node's own range (`CompilerFacts.placed`), and an edge, unresolved site or access of any other fact carries no site (`CallGraphFacts.siteOf`), so no region at the callee claims it and no dead branch of the caller's file drops it (`MemberReach.isLive`) — branch `facts/s2a`
- leaving an inlined `Reflect`/`Type` body (`reflection-inlined`) to the syntax, as `FactsView.blindIn` did → true only while such a body keeps its syntax; faceted under the truth, its facts hold an `inlined` call of `Reflect.setField` and no reflective fact, and the syntax misses the call under an alias (`import Reflect.setField as sf`): the node is a `DynamicName` under the truth — branch `facts/s2a`
- retiring the property refusal (`MemberReach.answerReach`) for every `@:isVar` property under the truth, as the facts-as-truth design (S3) proposed → the facts do make every access of the storage a field access and every other one an accessor call, but a GETTER decides what a reader sees whatever the storage holds (`get_items() return other`), so a proof about the storage says nothing of the value read through the name; and a getter that does return the storage is a `value` read of it, an escape, so a `Mutate` question could be proven only where the proof is wrong. The refusal gives way only for a property every build reads straight from its storage (`MemberReach.readStraight`: a `default` / `null` read), whose setter, if any, is a call the facts name — branch `facts/s3a`
- taking every spliced fact of each faceted body a range question meets, as the truth's first reading of a splice did (`CompilerFacts.within` with `spliced`, `MemberReach.splicedInto`) → a splice anywhere in a function reached every region of it, and a body spliced in by a call of a method that runs no project code became the caller's own: `Std.parseFloat` inlined on js brought its `js.Syntax.code` in as the region's native code, `StringTools.fastCodeAt` on cpp its `untyped s.cca()` as a dynamic call, and a `push` on a fresh local of an inlined project method was an edge asked in the caller, where it has no call. An `inlined` call now records where it ran (`s`, the innermost expression of the caller's own range around the call site it replaced) and the method's declared range (`d`), and a body a spliced body spliced in turn is a call of its own at the same site (`TypedFactsWalk.nestedSplice`) — without that, the facts of a method inlined both there and elsewhere, deduplicated into one, ran at the other call alone. A spliced fact runs at the sites of the innermost declared range holding it (`CompilerFacts.spliceOf`, `CallGraph.SplicedSite`), and one no such range holds anywhere in its node; what a method that runs no project code (`ReachGraph.runsNoUserCode`) spliced in is dropped, its `inlined` edge answering for it (`FactsView.harmlessSplice`); a spliced edge is judged benign in the method it is written in (`MemberReach.benignWhereWritten`) — branch `facts/s2c`
- refusing every body of a type a build macro ran over (`ReachGraph.buildMacroOn`) also under the truth, or retiring that refusal for every body read from its facts, as the facts-as-truth design (S5) proposed → the facts are the code every listed build compiled after its macros ran, so where they show a type's code is its text (`FactsProvenance.typeIsItsText`: every body and initializer lies in its field's declaration with every fact on text spelling it, save what an inlined method spliced in; every field declared alike, accessors included) the macro changed nothing and is no blind spot (`ReachGraph.rewrittenBy`) — openfl's `@:autoBuild(initBinding())` on `Sprite` and tink's global `SyntaxHub` build over the client's `MeshScale`. A per-BODY retirement is not enough where a macro did change the type: it also changes what the analysis reads off the declarations and the whole project's text — a variable made a property behind a getter (the property refusal reads the text's accessors), an initializer (`sharedInitializer`), an escape in its code (`ValueEscapes` scans text) — so a changed type stays `Reification` wherever it is the owner, the entry's type or code the walk enters. What the facts show a method a macro made or placed outside its file TOUCHING is still found (`CallGraphFacts.adopt`: a graph node read by its id, a toucher by its facts), so a changed callee may be `Reached` instead — branch `facts/s5`
- deciding a simple name's ambiguity by the count of the qualified types the builds TYPED under it, as the facts-as-truth design (S4) proposed → a declaration no build typed is not one that never runs: a `@:genericBuild` class is never typed under its name yet runs under the one its macro builds, and a `#if never` declaration in a file a build compiles is typed by none either; and a declaration of a file no build reads stays in the index, whose union tables (`CallGraphTypes`, `ReachProject.siteOf`) then resolve the type the builds do compile through it. Under the truth the index drops every project file no build read (`ReachProject.readThrough`), and a name still declared more than once is one type only when every declaration the index holds is the one qualified type the builds typed and every typed type the graph calls so is it, an instance, its implementation class or an alias of it (`FactsView.soleType`) — branch `facts/s4`
- "a type in a file compiled differently per build" as a second declaration of its name, and "std per-target copies count twice", as the facts-as-truth design (S4) put it → the index keeps the FIRST declaration of a name among a file's `#if` regions (`SymbolIndexBuilder.collectGuardedDecls`), so `#if js class Grid … #else class Grid … #end` is one declaration and never `Ambiguous`; its members fold per member, which the truth now reads by id (`FactsView.foldedBodies`). Only copies in two files — a `_std` copy per target, a classpath per build — count twice, and a run lists copies of two targets only when its builds are of two targets (the client's are all cpp). Such a type's nodes are read by id too, but the walk still stops at them (`Ambiguous`): it read a node's hazards and sites over the first declaration's span alone (every declaration since `facts/sfix`), and the owner has no one declaration site (`ReachProject.siteOf`), so a member question about it ends `OutOfScope` — branch `facts/s4`
- following the object a member's value is handed to — a `new` of harmless library code held in a compiler temporary, its uses the object's — as the facts-as-truth design (S3b) proposed for the client's `for (i => p in _points)`, which the facts read as `_points` escaping into `new ArrayKeyValueIterator(_this)` → no list the analysis keeps calls that class harmless (`ReachGraph.isPureLibrary` wants inert parameters), and the object is only the inliner's rendering of `_points.keyValueIterator()`: the read is the RECEIVER of an inlined call, which the compiler binds to a local named `_this` at the spliced body's own range. It is recorded as that call's receiver (`u=call`, `m=keyValueIterator`, `TypedFactsWalk.receiverCall`), so the array's reader list decides as it does for the syntax, and a reader's result stored or returned is no escape under either (`nonMutatingArrayMethods`: it hands out nothing that can change the array); an argument of an inlined method, a local its code names `_this` and a parameter so named stay values — branch `facts/s3b`
- keeping the `macro-expansion` marker a refusal of `FactsProvenance.typeIsItsText` (S5's `UNTEXTUAL_MARKERS`), and reading what the client's last two Reification blockers (`GridUtils`, openfl `DisplayObject`) showed as macros that genuinely changed the types → neither type was changed: every refusal was a fact the whitelist had no shape for — code an expression macro built (the client's `t(...)` inside the inlined `WaitView.showNativeFileDialogAsyncMask`), a `Map` built at `[]`, `is` compiled to `Std.isOfType`, `new Map()` built through `Map_Impl_`, and in `TextField` a regex literal's `EReg`, a setter called by its own name and a range the compiler joined across files (`punion` of an inlined `Vector` access with the text's `.end`). The walk now records each expansion with the macro declared around it and the innermost expression of the code that called it (`TypedFactsWalk.expanded`, `exps`), and its code is the text's only where that expression writes a call of the macro (`FactsProvenance.expansionWritten`); a marker says nothing the records do not, and code no fact describes changes nothing the analysis reads. A per-body narrowing was not needed — branch `facts/s5b`
- answering whether build macros changed a type in the compiler, from the fields a global `@:build` sees before and after the others → measured on haxe 4.3.7: a type's `@:autoBuild` macros run first, the global ones next, its own `@:build` last, and a `@:build` added to the class while its macros run is never run, so no macro sees either the fields as declared or the fields as built — branch `facts/s5b`
- reading a graph node's code off its FIRST declaration (`MemberReach.bodySpans` returned `[node.span]`, `CallGraph.functionAt` searched `node.span`) → a member declared once per branch of a region is ONE node, and with `#if other function g() {} #else function g() { … } #end` the second body's untyped read, implicit sites and touches were never read: `Proven` with no facts, with facts and under the truth, and a touch there belonged to no function and so to the type's initializers. A node now lists every declaration it folds (`CallGraph.declarationsOf`), `functionAt` / `declarationAt` find a site in any of them, a call frame carries its own declaration's span, and every reader walks them all — hazards, implicit sites, `ReachGraph.enter`, library accesses, `bodyChangesSharedArray`, `benignEdge`, `splicedInto`, `FactsView.faceted`, `MemberTouchScan.nodeAccesses` / `recordTyped`, `CallGraphFacts.mute` / `graphNodeOf`; a reader that needs ONE text (`answersByText`, `FactsProvenance.bodyIsSource`, `FactsView.typedBodies`) requires exactly one declaration. The two-`Helper` fixture of `M-REACH-AMBIGUOUS` is `Reached` now (the other `tick` is read); what the ambiguity gate still guards is a declaration no body of the merged node shows, an extern twin — branch `facts/sfix`
- the index's member table keeping the FIRST declaration of a member name (`CallGraphTypes.recordMembers`: `if (!table.exists(m.name))`) → a getter, a `dynamic` modifier, a return or a field type only another branch declares was never seen, and an accessor behind a property, a call through a returned value, a field typed otherwise and a replaced method were `Proven`. One record joins the declarations (`CallGraphTypes.joined`: what runs code in either runs, a type they spell differently is none, a field in one and a function in the other is a `dynamic` function); the graph node is `dynamic` / bodied when any declaration is and keeps a return, parameter types or bounds only where all agree (`CallGraph.settle`, `paramTypesOf`); `sharedInitializer` reads every declaration's initializer; `ValueEscapes.macroMember` asks the declaration it walks — branch `facts/sfix`
- an `<init>` / `<static>` node made lazily, by the first edge an initializer records (`CallGraph.initNode` from `frameId`) → an initializer that calls nothing — an element write of the member, a string conversion, untyped code — ran under no node, so `new D()` over `var k = C.it.items[0] = 5;` was `Proven`; a type holding an initializer has its node (`collectEdges`), which reads the initializers of every file holding some (`initializerFiles`) in every branch of a region (`ReachHazards.initializerSpans`, `MemberBranchScan.eachMember`) — branch `facts/sfix`
- `FieldDeclFact.kind` as THE kind of a field → `FactMerge.fields` kept the first configuration's while `readStraight` trusted it, so a property the build defining `other` declares with a getter was read straight from its storage (a `Write` question over it `Proven`); `kinds` holds every configuration's and `readStraight`, `isMethod`, `overrides`, `declaredAlike`, `adoptType` and `StaticExtensionFacts` read them all — branch `facts/sfix`
- `FactsView.typedBodies` taking every typed body of the node's file whose range lies in the node's span → a node the table merged over configurations takes its `at` from the first dump (`CompilerFacts.materialize`), so a copy another build read from another file compared its offsets against this text; a body now counts only when its `at` is in the node's own file, of a node standing for one declaration. The other order — this file's range first, another copy's facts merged in — needs a second copy under one id the index does not hold: a project file outside the project set (outside the analysis's contract) or a library `_std` copy, whose body the walk asks whole, where a node inside the range gives every fact (`CompilerFacts.within`) — branch `facts/sfix`
- taking an edit into the analysis in place (`MemberReach.refresh`) whatever the graph folds → `CallGraph.removeFile` drops a node with its home file, and every edge its declaration in another file recorded with it, which re-adding the file alone does not bring back; an edit to a file holding a declaration of a node another file declares too rebuilds (`CallGraph.foldsAcrossFiles`) — branch `facts/sfix`
- `M-REACH-STRINGBUF-PURE`'s fixture of an EMPTY library `StringBuf.add` → since `0a55b617` (compiler facts step C: a shared collection's region may call code that changes no array) the walk reads the library body and proves it empty, so the pure-call list decided nothing and the arm survived; the fixture's `add` converts what it is handed, as the std one does, beside a project `toString` that changes an array — branch `facts/sfix`
- `testBodylessLibraryCallAdmitsImplicitlyCalledMethods` as `M-REACH-EXTERN-HANDS`' kill → since `647a9a7a` (step B fix round 1) every admission that may run unread code admits every implicitly-called member in play (`MemberReach.runsUnreadCode`, `ReachGraph.implicitIds`), which a project `toString` always is, so `Std.string(this)` is `Reached` without the extern's reading of what it is handed; that reading still decides for an abstract no code entered at the first such admission spells — its members run only where its name is written — which the test now converts too — branch `facts/sfix`
- retiring every implicit admission under the truth because there "an implicit call is an explicit call fact, or an inlined call, in the body that runs it", as the facts-as-truth design (S6, rows 6-8) put it → true of an operator, a conversion, an index access and a literal construction (a call, a `new` or a splice), false of two families: a string conversion is a site the facts keep (`strs`, and `Std.string`, which `CallGraphFacts.declaredCall` deliberately files no edge for) and so is a kept `for` (`iters`: the loop's `hasNext`/`next` run inside the `TFor`). A lambda the walk never enters, since it reaches no toucher by an edge, still converts or iterates what it is handed. So the unread admission (`MemberReach.admitUnread`) keeps those two families (`ReachGraph.typedImplicitIds`) and drops the rest, and sets `_syntaxEntered` only when the graph holds code one of the site's channels may run that is read by its syntax or not read at all (`ReachAdmission.runsSyntaxRead`), asked again whenever the graph grew — branch `facts/s6`
- the client's `MeshScale.hx:61` blocker (`TextField.set_text -> Vector.splice -> RequestModelsAccessDialog.next -> Iterator.next -> MeshScale.new`) as an implicit admission from a FACETED body → neither body was faceted: `openfl.Vector` and `haxe.ds.Vector` share the simple name (so `soleType` is null and the walk marked `Ambiguous` wherever it entered one), and `RequestModelsAccessDialog.next` carries `macro-expansion` (the client's `t(...)`), whose syntax records the `Iterator.next` edge and the extern site behind it — a faceted body's structural call is already an unresolved site by name (`FAnon`), no edge. A member only one typed type of its name declares, which no other declaration the index holds spells, is that type's member (`FactsView.soleMember`): read by id and no `Ambiguous` (`MemberReach.sharedName`). The walk still meets `Vector.get_length`, which both declare, and line 61 stays declined: the first blind spot it meets is now `Reification` at `model/Node.hx` (`@:rtti`), whose `toString` the string conversion of the `TypeError` `TextField.set_text` throws admits — a class-typed site that, with the project's escapes unknown (`ValueEscapes`, S7), may hold any object — branch `facts/s6`
- the exception wrapping the compiler adds after typing, as the facts-as-truth design (Q1, "unverified") left it → verified missing from the facts AND from the syntactic sites: a region `try throw o catch (e:Dynamic) {}` whose `Obj.toString` changes the member was `Proven` in all three readings. A thrown non-String value is now a string conversion both in the facts (`strs`, `TypedFactsWalk`) and in the syntax (`ImplicitSites`), so the non-truth reading changes here, by a soundness fix. The wrapping at a CATCH (`Exception.caught` wraps a value thrown natively into a `ValueException`) is not modelled — branch `facts/s6`
- "openfl's `TextField` was never changed by a macro — every refusal was a fact shape" (S5b) → one shape was still refused: the compiler positions the `EReg` it constructs at `~/\s+/g` without the flags, so `BodyText.builds` now accepts a literal that runs past the construction by letters only — branch `facts/s6`
- a `new` of an abstract, which the facts record as a call of its implementation class's `_new`, filed by `CallGraphFacts.declaredCall` under that name → `_new` is no member the graph holds, so every such call, inlined or not, was an `UnresolvedDispatch`; it is named through `FactsView.graphMember` — branch `facts/s6`
- an iteration site admitting the iteration members of what EVERY implicitly-called method of the iterated type returns (`ReachGraph.typesAt`) → what `next` returns is an element, which the loop runs nothing on; a `next` returning a type parameter or a type the index does not declare made every `next` in play a candidate. Under the truth only what `ExecutionShape.iterableMethodNames` return is iterated in turn; the syntactic reading keeps the old rule. Also open: a lambda held directly in a field's initializer is never faceted (its body is the `var` fact node, not in `FactsView.FUNCTION_KINDS`), and a facts type carrying a type parameter is no site type at all (`FactsView.simpleSource`) — branch `facts/s6`
- reading the client's escapes off the facts so that a class-typed string conversion admits only the `toString` of what may reach it (facts-as-truth design S7, rows 17-18; S6: "`Node.toString` is admitted because `ValueEscapes` returns null on the client corpus") → measured: the syntactic escapes are null on the client corpus for reasons that do not stack — the first, `MeshScale`, inherits openfl code whose supertype the index declares more than once, and behind it 122 classes inheriting library code, 1592 values the syntax cannot type, an `untyped` in `CrashReport`, a raw region. Read off the facts of every typed body, library and std included (`FactsEscapes`), they are null too: `model.Node.parse` makes a class value of a computed name (`Type.resolveClass(name)`, which may be any class), project target code (`video.GpuDownloadPipeline`), reflective bodies spliced in; with every such refusal waved through, ~1150 types escape — a type parameter's values are the types its instantiations bind, and std code hands `Array.T` to `Dynamic`, so every class ever stored in an array escapes. The escapes from facts stay (they narrow small programs: the client-shaped fixtures of `MemberReachFactsTest` are `Proven` where the syntax lets anything handed to library code escape), but the client's line 61 moved by another fact — branch `facts/s7`
- S6's "a non-String thrown value is a string conversion" for every thrown value → over-broad: `haxe.Exception.thrown` throws an exception as it is and hands only a non-exception to `ValueException`'s `Std.string`. An object of exactly a class extending `haxe.Exception` — a construction, or a local initialized with one of its own type and never written again (`TypedFactsWalk.exactObject`, `_built`) — is converted by nothing. the client's `TextField.set_text` throws `var error = new TypeError(...)`, and openfl's `Error` extends `haxe.Exception` under haxe ≥ 4.1: that throw was the site admitting every `toString` in play, `model.Node`'s among them. The same exactness narrows a converted fresh object to its own class's chain (`strs`/`flows` `x`, `ImplicitSite.exact`, `ReachGraph.exactTypes`) — branch `facts/s7`
- `model.Node`'s `typeIsItsText` refusal as `@:rtti` changing the type (S6's blocker (2)) → no field the RTTI adds was refused; the whitelist had no shape for a `Std.string` the compiler writes for `${rttiFields[child].type}` at a range it joined from the inlined `Map.get` and the text, nor for the value that conversion flows as (now `FactsProvenance.readJoined`: a fact at the range of a joined field read the text writes is that read's). The next refusal there is the `??` lowering's local `tmp`, positioned at the left operand, which no text spells — open, and off line 61's path now — branch `facts/s7`
- a facts type string as the type grammar reads it → two shapes it does not read were printed: the typedef of an enum's statics carries arguments after its name (`Enum<tink.core.Outcome><?,?>`), and an import alias (`import pack.T as U`) is a typedef no module lists, so the table held no type for it (`lime.math._Rectangle.LimeRectangle`, js `_Date.HaxeDate`). The probe prints the first as `Enum<…>` alone and writes a record per alias declaration (`TypedFactsMacro.printedAliases`) — branch `facts/s7`
- also open from this slice: a conversion call's operand is read off the FIRST argument flow inside it (`FactsView.sitesIn`), and a leaf of the same type as the parameter (`Dynamic` into `Std.string`) records none, so `Std.string(c ? obj : dyn)` reads as converting an `obj` only; an import alias's type parameters print as the aliased type's (`$haxe.ds.Option.T`), which no binding of the alias's own reaches (conservative: the escapes then take every instantiation) — branch `facts/s7`
- qualified graph ids under the truth throughout, as the facts-as-truth design (S9) proposed → not needed: what makes a name two typed types share `Ambiguous` is a walk entering its folded node, and a call fact already names the owner the compiler resolved (`CallEdge.typed`). A node of its own per (folded node, owner) is made where the walk enters the name by such an edge (`CallGraphFacts.qualify`, `MemberReach.qualifiedNode`): of the declarations the node folds, those of that type (`FactsView.qualifiedDeclarations`, refused unless every one is told and every file of the type is in the graph), faceted by the facts of the owner's member (`FactsView.ownerBodies`), its touches read off them (`MemberTouchScan.scanNode`), its hazards and sites read as that node's (`FactsView.faceted`), its build macros its own type's (`ReachGraph.rewrittenAs`). The graph's keys, `callers`, `thread-safety` and every other consumer are untouched. A name entered by an edge no fact names an owner of — a body read by its syntax, a dispatch to overrides, an admission — stays `Ambiguous`: a simple-name resolution may have picked neither type's member (an inherited one) — branch `facts/s9`
- what the client's walk needed besides the owner, each measured on `MeshScale.hx:61`: the index lists ONE type per name per file (the first branch), so `openfl/Vector.hx`'s second and third `abstract Vector` lay in no listed type — a declaration is told by the type its text declares it in (`MemberTouchScan.typeAt`); `ReachProject.siteOf` answers null for a shared name, so `loadType` read nothing — the owner's files are read first (`ReachGraph.loadOwner`); `tink.SyntaxHub.build()` runs over every type, and `typeIsItsText` refuses a shared name — asked per owner (`FactsProvenance.typeIsItsTextAs`); and the syntax's accessor edge of `v.length` was kept beside the inlined call's fact, because the compiler sites an inlined call at the enclosing expression, never at the call's own range, and that edge named no owner — a syntax edge to the node an inlined call of the facts reaches, inside its site, is that call (`CallGraphFacts.answered`) — branch `facts/s9`
- S7's open "a conversion call's operand is read off the FIRST argument flow inside it" → unsound, and RED on the old code: `Std.string(failing ? new Plain() : d)` with `d:Dynamic` converted a `Plain` only, `Proven` while a project `Obj.toString` touching the member may run. The value converted is the flow at EXACTLY the argument's range (or, for a conversion the compiler wrote for an operand, the call's), and of any type otherwise (`FactsView.conversionFlow`); a static extension's (`using Std; a.string()`) is its receiver. The `operand` guard on exactness went with it (arm `M-FACTS-VIEW-EXACT-OPERAND` retired, it survived): the flow at the whole argument's range IS the value converted, so its exactness is the site's — branch `facts/s9`
- `testAMemberAnotherTypeOfItsNameMayDeclareKeepsTheNameShared` expected `!Proven` → it is `Proven` now and soundly: the dead declaration of `Vec.splice` stays a reason `soleMember` refuses (pinned directly), but the call in `Box.put` names `lib.Vec`'s, which is the code that runs — branch `facts/s9`
- the client's `MeshScale.hx:61` after this slice: `Ambiguous(Vector)` and the `Reification` behind it are gone; it declines at `UnresolvedDispatch` of `IVector.get_length` — the inlined `openfl.Vector.get_length` reads `this.length` of the private interface `IVector`, a property whose accessor only the interface implies; `CallGraphFacts.declaredCall` files it as a plain external placeholder, never the body-less `interfaceDeclared` node the syntax makes (`CallGraph.externalNode`), so no indexed type declares it. Next slice. Behind it, names two client types share entered by an admission (`Color.toString`, `Points.toString` from the region's string conversion) still stay `Ambiguous` — branch `facts/s9`
- `testAReceiverTheFactsTypeAsANonExternClassLosesItsToString` as `M-TOSTRING-FACTS-EXTERN`'s kill → it held through one site per stage and lost both: `49ff0826` (same merge as the arm) put `d.toString()` after fifteen escapes, where `FactsTypeOracle` declines the range before its type is asked, and since `2bdac5ef` (fold-operand-binding) `Date.now()` is not provably non-null, because the unindexed `import haxe.io.Path` may declare a `Date` of its own (`TypeNameBinding.explicitTier` answers `Unknown`), so the arm survived from that merge on. The fixture now reads `'at ${d.toString()}'` of a non-null `d:Date` outside any escaped literal, which only the extern gate keeps, and the escaped site is asserted by its own text — branch `fix/tostring-extern-arm`
- a call the facts name of an interface's member no text declares (client: `IVector.get_length`, the accessor `length(get, set)` implies) filed as a library placeholder no indexed type declares (S9's blocker) → it is the body-less dispatch node the syntax makes for the same accessor (`CallGraphFacts.dispatchesOnly`: the facts say the owner is an interface in every build — off the truth the index must say so too); the implementations are its override edges. Two holes behind it, each RED on the old code: an implementer whose implementation it inherits from a superclass off the interface's chain was no dispatch target (`CallGraph.virtualTargets`), and that superclass's file was never read (`ReachGraph.loadOverrides` read only subtype files spelling the member) — the facts' own override list (`FactsView.overrides`) needs no such reading: every dispatch edge it adds is joined by the graph's targets, recomputed once the files are read, and a subtype the index does not hold is no proof anyway (`ValueCarriers.subtypesKnown`; an arm cutting it there survived); and an abstract's `this.x` inside its own accessor of `x` read as that accessor's storage though `this` is the value it wraps, so the syntax never followed openfl's `Vector.get_length` into `IVector` at all and was `Proven` beside a touching implementation (`CallGraph` `handleAccess`) — branch `facts/s10`
- S4/S9's "the index lists one type per name per file, the first branch" as a facts-only concern → a soundness hole of every reading, RED: the first branch declaring `Box.size` a plain field and the compiled one a property whose getter changes the member was `Proven` — no accessor edge, since the second declaration's members, supertypes and metadata were dropped. Each later declaration of a name a conditional region already declared is now an alternate folded into the one listed record (`SymbolIndexBuilder.withAlternate`): both member lists (a name both declare joins in `CallGraphTypes`), the supertypes unioned, what makes code run either's, what narrows both's, an alias or underlying only where both spell it alike. One type per name per file stays, so `declares` reports no ambiguity that does not exist (`SymbolIndexSliceTest` pinned the drop — `cppOnly` absent — and now pins both branches' members). A type only a later branch declares under its own name was always listed — pinned — branch `facts/s10`
- names two types share admitted by a string conversion or an iteration the facts typed staying `Ambiguous` (S9: the client's `Color.toString`, `Points.toString`) → such a site names the typed type of each operand (`ImplicitSite.owners`, `FactsView.typedOwner`), and each member it admits is entered as the member of each typed type a value of it may be (`ReachGraph.ownedTypesAt`, `ownedIdsAt`, `MemberReach` `apply`): the type, its typed subtypes unless the object is exactly its class, what they extend or implement, and every typed type whose instances escaped. Escapes are now kept by typed id as well (`FactsEscapes.typedIds`, `ValueEscapes.escapedIds`, `ValueCarriers.escapedIds`): by graph name, a converted `b.Color`'s own escape into `Std.string`'s `Dynamic` made every `Color` escaped. An operand of no typed class or interface keeps the simple-name reading, every declaration walked — `Reached` where one reaches a toucher: an admission holds a node only when it does, so for it "stays Ambiguous" is never what is observed — branch `facts/s10`
- a node of a name declared more than once that the facts read as one type (`FactsView.soleType`, `soleMember`) asked whether a build macro rewrote it by the simple name (`ReachGraph.rewrittenBy`), which `typeIsItsText` refuses for a shared name (client: `Vector.splice`, `Reification` at no file) → asked per owner (`rewrittenAs`), as a qualified node is; `rewrittenAs` no longer keeps a refusal computed before every file of the owner is read (not pinned: every reading that reaches it reads them first) — branch `facts/s10`
- the client's walk entering openfl's js-only `VectorData` (no build defines `js`) through `Vector.splice`'s `this.splice` in the `#else` of `#if (haxe_ver >= 4.2)`, which no define set decides → two holes, RED: a site no build compiles was live when a directive nested in it split its range across several dead ranges (`ReachLiveness.live` asked "inside ONE dead range"; it now asks whether the range holds code outside every dead range and directive, `holdsLiveCode`) — and `holdsLiveCode` took the directives before `deadOf` read them (Haxe hoists the `??` operand), so its first call per file counted directive text as code; and a node every declaration of which lies in code no build compiles was entered like any other, its build macro and hazards answering for a call no build runs — now it runs nothing (`MemberReach` walk). Open: a version comparison (`haxe_ver >= 4.2`) stays undecided — the probe records define names, not values — branch `facts/s10`
- not done in S10: `reachedArrayChange` (the local-collection question) keeps `sharedName` with no qualified reading — off client line 61's path, a member collection — branch `facts/s10`
- the client's `MeshScale.hx:61` after this slice: `IVector.get_length`, the `Color`/`Points` admissions and `VectorData` are gone; it declines at `Reification` of `haxe.Rest` (`std/haxe/Rest.hx:31`, reached from `TextField.set_text` through the inlined `Vector.splice(…, ...items)`): `tink.SyntaxHub` builds every type, and `FactsProvenance.typeIsItsText` refuses `haxe._Rest.Rest_Impl_._new`, the inline abstract constructor `this = array` (`nodeOnText`) — a provenance shape, next slice — branch `facts/s10`
- arms whose cut this slice moved, re-cut and KILLED again: `M-ESCAPE-ANY`, `M-ESCAPES-TRUTH-FACTS` (`ValueEscapes.compute` answers typed ids too), `M-REACH-IMPLICIT-ADMIT` (the walk's admission of a site's members now splits them by owner) — branch `facts/s10`
- S10's "`typeIsItsText` refuses `haxe._Rest.Rest_Impl_._new` in `nodeOnText`" read as a shape of the constructor's facts → the facts were fine; the DECLARATION was too short. The compiler places a field from its first modifier and an abstract's lowered constructor at that very start, while anyparse's member node starts at `function`. A declaration now spans its `@:meta`/modifier run (`FactsView.declarationRange` over `ElementSpan.declRunStart`) — in the provenance test and in which typed bodies a graph node reads (`typedBodies`): the second is what read `Rest.new` by its syntax, which admitted every implicit conversion of the program (the client's next blocker was `Ambiguous(Color)` from that) — branch `facts/s11`
- taking the provenance long tail one shape per slice → S11 forced `typeIsItsText` true over the client's whole walk and listed every refused fact (the table is in the S11 commit message): every shape that was the compiler's own lowering of text it reads is accepted on a positive whitelist — a local it binds a value to at the expression the text writes, `??`/`?.` temps, a commutative operator's `lhs`, an inline argument, a bound `.bind` value (`BodyText.binds`, a node's range taken without its trailing whitespace), a local placed at its declaration's keyword (`declares`), a read at an expression the text writes, interpolated values (whose range ends at the last part), a comprehension's `Array.push` (`ExecutionShape.comprehensionCalls`), positions inside an interpolated string past an escape or a multi-byte character (the compiler counts UTF-8 bytes of the unescaped value: `Interpolation`), `new` through a typedef the builds alias the class to (an import alias is one: the compiler types `import X as Y` as a typedef, so no import reading was needed), a call of an abstract's `_new` written `new`, an abstract's `toString` an interpolation or concatenation calls, an initializer wholly the inlined call of a method its declaration calls (by name, accessor, operator or construction, a different method per build), an expression macro's call in an inlined call's argument or handed to a sibling inline setter, a constructor the compiler made forwarding its parameters, a field joined across a splice and a site spelling it or the access another splice writes, and a typedef aliasing the type from another file. Not added: an interface's `:compilerGenerated` accessors (openfl's `IVector.get_length`) — refused only under the forced survey; no question asks `typeIsItsText` of an interface, whose nodes are body-less (traced on the client corpus, and the fixtures built for it stayed `Proven` with the rule cut). Refused on purpose: tink's `assert` builds `new Assertion` positioned on its argument (tests only; accepting code inside a macro call's argument would accept anything a macro chooses to place there), XmlSerializable's generated methods (a real build macro) — branch `facts/s11`
- an inherited-splices rule (a nested function reading its enclosing body's splices) and a bare-name `endsAccess`, written for the client's `ItemListTile`/`VolumeWatcher` getter reads → the facts walk was missing the splice: a field read the compiler joined across two methods' code (`base.folder`, from what the inline `base` returned to the getter's field) lay in no single method, so `nestedSplice` recorded none. It now records the method writing the field — the end the receiver does not supply, checked to spell `.` and the field there, since a field written in another file leaves that file's offset under the receiver's file (`TypedFactsWalk.fieldWriter`) — and both rules went: their arms survived once the walk was right. Recording the method around EACH end was tried first and is unsound for exactly that reason: S7's `${m[k].e}` fixture had its text offset land in an unrelated `Map.hx` method, recorded as spliced, and `M-FACTS-TEXT-JOINED-PLACED` survived. S7's `body.endsAccess` went the same way — every case it took a site of the splice spelling the member takes too (`siteSpells`); `M-FACTS-TEXT-JOINED-ACCESS` now cuts that — branch `facts/s11`
- a partial application's closure needing its own rule (reads at `f.bind`) → `f.bind` is a node of the text; the read-at-an-expression rule covers it, and the `partialApplicationName` shape field came out again — branch `facts/s11`
- an inline method of which only constants survive (`percentLimit(v)` = `limit(v, 0, 1)`) as a provenance shape → the walk left constants out of splice detection (a default argument's value sits at its declaration), so the outer method was never recorded; a constant inside a splice lying in ANOTHER inline method's range is that method's code and records it (`TypedFactsWalk.walk`, `writtenConstant`) — branch `facts/s11`
- version comparisons (`#if (haxe_ver >= 4.2)`) staying undecided because "the define set carries names" → the probe now prints every define's value at the first initialization macro and once typing ended; a value both agree on is every file's (`ReachConfiguration.values`), and `CondValues` evaluates exactly as `parserEntry.ml` (4.3) does — `is_true`, the string/number and string/version conversions, `cmp`'s undefined-is-false, SemVer — checked on `haxe --interp`; whatever it cannot reproduce exactly (a number `float_of_string` might read another way, non-ASCII string order, a comparison the compiler rejects) stays unknown. `OracleCoverage` keeps names only: its set is the `Defines:` line, printed before initialization macros, so no value there is proved for every file. `resolve-define --undefined X` now folds `(X >= 2)` to false, as the compiler does — branch `facts/s11`
- tests asserting `Proven` under the hub build passed on fixtures that did not compile (the facts were dropped and the syntax answered) → `hubAsk` fails the test on a dropped configuration; two S11 fixtures were exactly that — branch `facts/s11`
- found WRONG, not fixed here (grammar): anyparse parses `??` right-associative and below `==`; Haxe's is left-associative at precedence 6, tighter than comparisons (`parser.ml` `precedence`), so `a ?? b == c` is `(a ?? b) == c` and `a ?? b ?? c` binds its temp to `a ?? b` — the three `??` chains the client's survey still refuses (`AIPanel`, `MirrorFileMoveDetector`, `Image`) — branch `facts/s11`
- the client's `MeshScale.hx:61` after this slice: `Rest`, `TextEngine`, `Any` (a tink typedef) and the `Color` admission are gone; it declines at `DynamicName` (`src/model/Node.hx:198`, the client's RTTI serializer setting a field by a runtime name) — reflection, not provenance — branch `facts/s11`
- `??` as right-associative and looser than `==` / `&&` / `||` (`@:infix('??', 2, 'Right')` since the ternary slice) → Haxe 4.3 parses it LEFT-associative between the bitwise tier and the comparisons (`a ?? b == c` is `(a ?? b) == c`, `a ?? b ?? c` is `(a ?? b) ?? c`, `a ?? b | c` is `a ?? (b | c)`; every relation probed with `Context.parse` on 4.3.7); `is`, believed to share the comparison tier, binds tighter than every binary operator (`a + b is T` is `a + (b is T)`), so it moved too or `a ?? b is T` would have broken; and the `??`-emitting fixes' "ternary or assignment" paren lists were the same wrong table in three copies — they ask `ParenGuard` now — branch `fix/nullcoal-precedence`
- found WRONG, not fixed here (grammar): `...` shares the comparison tier but Haxe binds it one tier looser (`a ... b == c` is `a ... (b == c)`); `in` is Haxe's TIGHTEST binary operator (`a ?? b in c` is `a ?? (b in c)`), the grammar's loosest; an arrow lambda in operand position (`a ?? x -> b`) is `a ?? (x -> b)` in Haxe and `(a ?? x) -> b` here — none involves `??`'s own slot — branch `fix/nullcoal-precedence`
- `...` sharing the comparison tier, `in` the loosest operator, the arrow lambda an infix at prec 0 (`@:infix('->', 0, 'Right')`) → re-derived the whole binary table from Haxe 4.3.7 (`Context.parse` over every operator pair, ~2700 snippets, every binop printed parenthesised): `...` is one tier LOOSER than the comparisons (`a ... b == c` is `a ... (b == c)`); `in` and `->` are ASYMMETRIC — tighter than every operator on their left (`a + b in c` is `a + (b in c)`, `a ?? x -> b` is `a ?? (x -> b)`) and a whole expression on their right (`a in b = c` is `a in (b = c)`); no symmetric precedence says that, so `@:infix` took a fourth argument, the right operand's precedence (`@:infix('->', 13, 'Right', 0)`, `pratt.rightPrec`) — branch `fix/grammar-precedence-rest`
- the writer asking only a node's own precedence before parenthesising it → an asymmetric operator, a ternary or a keyword atom over a whole expression (`cast e`, `untyped e`) ending a LEFT operand runs on into the operator after it however tightly its root binds (`(x -> b) + c` bare is `x -> (b + c)`, `(a ? b : c) = d` bare is `a ? b : (c = d)`); a generated `<writeFn>OpenRight` walks the right spine and the left-operand sites (infix, chain leaves, assignment chains, ternary condition) take a pair from it. Parsed source never reaches the pair — the parser would have read such an operand into the spine — so `fmt --list` is unchanged — branch `fix/grammar-precedence-rest`
- `cast` binding its operand at atom level (`@:fmt(atomOperand)`, slice 46, "Haxe's unary-operator binding", never probed) → Haxe 4.3.7 gives a bare `cast` a WHOLE expression (`cast a + b` is `cast (a + b)`, `cast (x) is Bool` is `cast ((x) is Bool)`, the client's `cast controlParams ?? [...]` is `cast (controlParams ?? [...])`) and ends it only at a leading `(e : T)` — `@:fmt(atomOperandWhen('ECheckTypeExpr'))`; the formatter's tight `cast(x) is Bool` now reads the operand's LEFTMOST atom — branch `fix/grammar-precedence-rest`
- five copies of "parenthesise a ternary condition iff it is a ternary or an assignment" (`prefer-ternary-return`, `prefer-ternary-assignment`, `prefer-ternary-expression`, `return-reassign-ternary`, the ctor-field ternary fold) → they missed every other right-greedy condition (`if (untyped c)` folded to `untyped c ? 1 : 0`, which is `untyped (c ? 1 : 0)`); the condition is a `ParenGuard` hole now (`ParenGuard.ternaryEdit`) — branch `fix/grammar-precedence-rest`
- `andLowerPrecedenceKinds` routed through `ParenGuard` like the `??` fallbacks → refused: `&&` is associative and the guard is STRUCTURAL, so `if (a) if (b && c)` would merge to `a && (b && c)`; the list stays, gains `=>`, `->`, `in`, `cast`, and `HxPrecedenceTableTest` derives it from the parser — branch `fix/grammar-precedence-rest`
- found WRONG, not fixed (grammar): the compiler rotates a ternary OUT of `in`'s right operand (`a in b ? c : d` is `(a in b) ? c : d`) while letting an assignment in (`a in (b = c)`) — no precedence pair says both; it binds a metadata annotation to the LEFTMOST operand of a binary chain (`@:m a + b` is `(@:m a) + b`) but over a whole assignment (`make_meta`), a rotation rather than a precedence; it ends a `cast` at a leading block (`cast {a;} + b`); and `a is T << b` / `a is T <= b` do not parse here (the type parser takes `<` as a parameter list) — branch `fix/grammar-precedence-rest`
- the client's `MeshScale.hx:61` declining at `DynamicName` in `model/Node.hx:198` read as an over-broad `toString` owner (S10) → `Node.toString` was admitted by a string conversion the facts typed and the walk read as any: cpp's `StringBuf.add<T>` is inlined into `EReg.replace` (`TextField.set_text -> set_htmlText -> EReg.replace`), its `Std.string(x)` lies in `StringBuf.hx`, and `FactsView.conversionFlow` looked for the argument's flow in the text of the file it read only, so the spliced conversion converted a value of any type — every `toString` in play. The flows are no answer for a spliced call: the facts keep one flow per distinct type at the shared range and none for a value of the parameter's own type (`Dynamic`), so their union over the splices is not complete. The walk records the operand on the call fact itself (`CallFact.operand`, `o`/`x`: a call handing its first argument to a `Dynamic` parameter, one fact per distinct operand, each splice's included), and `conversionFlow` is gone (`M-FACTS-VIEW-CONVERSION-LEAF` retired with it; `M-FACTS-CALL-OPERAND-LEAF` cuts the same mistake now; `M-FACTS-FLOW-EXACT` keeps only its `TypedFactsProbeTest` kill) — branch `facts/s12`
- a reflective access by a computed name being `DynamicName` wherever it runs → under the truth its object is what the facts type the call's first argument (`ReflectionFact.receiver`, `refl` `r`/`x`/`h`): an instance of the non-extern class or interface the builds declare alike, of a typed subtype unless it is an object of exactly that class, and — unless it is `this` — of a type whose instances escaped; with what each extends or implements (`ReachGraph.reflectedMembers`). It is a blind spot only when one of those types is the member's declaring type; otherwise it admits their methods, accessors included, each as its typed owner's member, and the accessor's own call is not entered (`MemberReach` `boundedCall`): std's `Reflect.getProperty` is `untyped` code reaching members by the name it is handed, which made every bounded access blind again. `Dynamic`, `Any`, a structure, a type parameter, an abstract (its value is its underlying one), an enum and an extern class keep `DynamicName`, as does any access the facts do not type (a syntactic hazard with no fact at its range) — branch `facts/s12`
- found, not closed (the slice's own rule): `this` is bounded to its method's class and subclasses without the escapes because only a dispatch on such an instance runs the method — but `Reflect.callMethod(o, f, args)` rebinds `this` to `o` (js `apply`, hxcpp `__SetThis`, neko `$call`), so a method value handed to it with a foreign `o` runs with a `this` of another type. the client's builds compile such calls (openfl's `Vector.every`/`some`, `Lib.setTimeout`, `Event.formatToString`). Closing it means refusing the `this` exemption wherever some build's facts call `Reflect.callMethod`, which keeps the client's `Node.toString` blind — a decision for the campaign, not this slice — branch `facts/s12`
- the client's `MeshScale.hx:61` after this slice: `model/Node.hx:198` is no blind spot any more — its `this.getProperty(attr)` (a `using Reflect` call only the facts see) acts on a `model.Node`, and none of the 20 types that may be carries `_points` — and `EReg.replace` no longer admits `Node.toString`. The line now reads `Reached` through cpp's `EReg.new`: the receiver of `a.join("")` is an unannotated local the syntax cannot type (the facts: `Array<String>`), and typed or not, `ReachGraph.handedMemberIds` needs the escapes, which are null on the client corpus since S7, so the target code may run any function — `MeshScale.new` among them, whose touch of `_points` is excused only behind a `new` edge (`freshlyConstructed`), though a constructor run through any admission builds a fresh object. With that excuse widened (measured, not committed) it declines at `Ambiguous(Color)`. Also open: a generic inline body entered through its `inlined` edge is read through its own facts, where the converted value is the type parameter (`StringBuf.add<T>`'s `Std.string(x)`), so it admits every `toString` in play — branch `facts/s12`
- found WRONG, FIXED on branch `fix/add-element-doc-glue` (op + parser, next bullet): `add-element --after --select 'TypedefDecl:OwnedId'` on a module-level typedef glued the NEXT declaration's doc to the inserted typedef's closing brace (`} /** An implicitly-called … */`), and `fmt --list` accepts that layout as canonical — branch `facts/s12`
- the glued doc read as one writer defect → it was two, each sufficient on its own for the reported shape and each pinned by its own test. (1) THE OP: `--after` lands at the next declaration's doc (a module-level span is greedy, so `docExtendedSpan` walks back to the doc's start) and spliced `\n<new>` there — the break BEFORE the element and none after, so the doc ended up on the inserted closing brace's line. At an offset that starts its line the element now goes first and the break after it (`AddElement`, `SourceText.startsItsLine`); right after a member's last token it stays `\n<new>`. (2) THE PARSER: a one-line block comment on a code line was captured as the previous element's `trailingComment`, so the writer reproduced `} /** doc */` and `fmt` called it canonical (a MULTI-line doc was already left for the next element by the internal-newline rule, which is why only the one-line form survived). A doc documents the declaration AFTER it — the compiler attaches it there — so the generated `collectTrailing` / `collectTrailingFull` / `collectTrailingBlock` now refuse a token that opens with the format's doc opener and ends its line (`Codegen.docEndsLineRefusal`; the opener is DECLARED, `BlockCommentDelims.doc` = `/**` on `HaxeFormat`, read into `CommentPattern.docOpen`, so a format with no doc concept is untouched). Both conditions are positive: a doc with code after it on its line (`f(a /** c */, b)`) keeps its trailing slot, a plain `/* */` ending a line stays the previous element's note, and the empty `/**/` is no doc. Tests red on the unfixed code: `HxTriviaWriteTest.testDocEndingItsLine*` (module and member level) and `AddElementSliceTest.testInsertAfterTypeLeavesTheNeighboursOneLineDocOnItsOwnLine` (red on the base, green with either half) / `…LeavesASameLineDocWithItsDeclaration` (`/** Doc B. */ typedef B`: code follows the doc, so only the splice can keep it off the brace — still red with the parser half alone). The rule applies wherever a trailing slot is collected, so a doc ending its line inside an array/call list (`[a, /** d */` newline `b]`) also moves to the next element's line; no corpus file has that shape. Corpus: fork sweep 0 fixtures changed (781/121), client `src` 0 of 841 drifted under both engines, anyparse `src`/`test` one file — `CompilerFacts.hx`, the same glue written by an earlier op (`} /** A node's signature … */`), rewritten — branch `fix/add-element-doc-glue`
- found WRONG, not fixed here (writer): `add-element --after --select 'TypedefDecl:OwnedId'` on a module-level typedef glued the NEXT declaration's doc to the inserted typedef's closing brace (`} /** An implicitly-called … */`), and `fmt --list` accepts that layout as canonical — branch `facts/s12`
- `this` exempt from the escapes wherever a reflective access hands it (S12) → `Reflect.callMethod(o, f, args)` runs `f` with `o` as its `this`, so the exemption holds only where no function any build typed calls, splices in or reads as a value a rebinding call (`FactsMethodValues.REBINDING_CALLS`), or — once one exists — in an instance method no code may obtain as a value: no closure/`FDynamic`/`FAnon`/method-instance read naming it, no reflective call that may read a member's value (every `Reflect`/`Type` member outside `MEMBERLESS_REFLECTION`) naming it or computing the name, on an object that may be of its class (`mayBeOf`: typed, subtypes unless exact, escapes). A reflective member or class read as a value, a lost reflective splice, project target-language code and a stale fact answer no `this`; a constructor's or initializer's `this` is answered only while no rebinding call exists (a class value may be handed to one). `ReflectionFact.holder` names the node whose `this` it is. A method whose own `this` access READS by a computed name obtains itself, so on js — whose std rebinds in `Type.createEnum` and reads by computed name in `haxe.DynamicAccess` — no `this` is ever exempt; the fixtures that test the exemption run under `--interp` — branch `facts/s13`
- the client's `model.Node.toString` keeps no exemption: `video.GpuDownloadPipeline.initFlipResources` (project code) holds target-language code, and its own `this.getProperty(attr)` may read `toString` itself — branch `facts/s13`
- an extern call of the built-in array's own methods (`Array.join` on a local the syntax cannot type) admitting every function → the array's listed methods and its constructor reach what they hold or are handed only by converting it (an element of `Array<E>` converts as `E`, the receiver typed by the facts where the syntax cannot) or by calling a function value the call hands them (`values` only when `callsItsArgument`); measured on hxcpp: an `Array<String>` cast from an `Array<Dynamic>` keeps its objects and `join` runs their `toString`, so the element type, not the array's, is what the existing `String`-is-inert assumption covers — branch `facts/s13`
- found WRONG, fixed: `MemberReach.externSite` read a construction like a call — `NewExpr`'s children are its arguments alone, so `new Ext(o)` took `o` for the callee and handed nothing, and `new Array()` (no child) read as an unread site admitting every function; and it handed the enclosing type's `this` as a construction's receiver. No fixture tells the two apart (`M-REACH-EXTERN-NEW-ARGS`/`-EMPTY` were written and survived, so they are not declared): an extern site opens the value channel, which admits every implicitly-called member anyway, and the built-in array's constructor declares no parameter the index reads as taking an object — branch `facts/s13`
- a member admitted by a name two typed types share with no owner a fact names (an implicit conversion of any value, an edge of a body read by its syntax) being `Ambiguous` → under the truth it runs as the member of each typed type so named that declares it (`FactsView.ownersDeclaring`), each read as its own (`qualifiedNode`), when every indexed declaration declaring it is one of them. `M-REACH-SHARED-NAME-SOLE` is retired: with the owners read one by one, a member only one typed type declares reads the same whether `sharedName` asks `soleMember` or not — branch `facts/s13`
- a field initializer always read by its syntax (the `<init>`/`<static>` pseudo-node has no declaration, and `FUNCTION_KINDS` left `var` nodes out), which entered syntax-read code and so admitted every implicitly-called member (`admitAlways`) → under the truth the pseudo-node is faceted by its type's initializer nodes (`FactsView.initializerBodies`, `CallGraphFacts.recordInitializers`): what they call — a `@:from` the compiler wrote — is an edge, and an initializer one of them holds whole is read through its facts (`FactsView.faceted`) — branch `facts/s13`
- not done (S12's list): widening `freshlyConstructed` to a constructor reached by any admission — its path on the client corpus went with the array rule, and it is sound only where no rebinding call may run a constructor on another object (a class value handed to `callMethod` on js), which the client's builds hold; instantiating a generic inline body by its call site (`StringBuf.add<T>`) — its splice in the caller already converts the instantiated type, so the fix is not to read the callee's own generic facts when every visit is through an `inlined` edge, which the context-insensitive walk does not track — branch `facts/s13`
- the client's `MeshScale.hx:61` after this slice: `DynamicName` at `model/Node.hx:198` — `Node.toString` is admitted by `StringBuf.add`'s generic `Std.string(x)` and by `EReg.map`'s call of a function value (`f(this)`, the value channel), and its `this.getProperty(attr)` has no exemption (above); the escapes are still null on the client corpus (project target-language code), so every conversion of a value of no known type admits it — branch `facts/s13`
- project target-language code leaving the escapes unknown (S7: "natives refuse only in project code"; S13: `FactsMethodValues` the same) while a library's reached nothing it was not handed → USER DECISION: one assumption for both — target-language code reaches only the values handed to it. Handed are its arguments (`{0}` placeholders, which already flow into `Dynamic`) and what its text names (`FactsNativeReach`): a local or parameter by its name (the node's own and every enclosing function's `params`/`vars`); the object its method runs on by a spelling of `this` (`this`, `_hx_this`, `__this`, `__this__`, `self`, `_gthis`) or by the name of a member of its class or a superclass — hxcpp reaches one unqualified — and every name its class's own pasted code declares; a static variable by its name beside its class's simple name (`Store`, `Store_obj`, `pack_Store`), or alone in the code of its class or a subclass. A `_hx_`-mangled name stands for the name behind it. The facts now record the text: `native` `c` (the first argument when a string literal) and `cc` (a code-carrying call — `__cpp__`/`__js__`/… or `Syntax.code`/`plainCode` — whose text is computed), and a type's or field's `code` (the argument of `@:functionCode`, `@:functionTailCode`, `@:cppFileCode`, `@:cppNamespaceCode`, `@:headerCode`, `@:headerClassCode`, `@:headerNamespaceCode`, `@:classCode`; null for a non-literal). Computed text is the one refusal left. A body no build typed under a `@:functionCode` hands every parameter type. `FactsMethodValues` drops its project-only refusal under the same assumption (target code obtains and rebinds a method only inside the recorded reflection), and the lowered-`trace` exemption is gone from both: an identifier with no code names nothing — branch `facts/s14`
- found WRONG, fixed: a core type read as a value (`Std.isOfType(n, Int)` where the target does not inline it — the interpreter, hxcpp) is typed `Abstract<Int>`, which `FactsEscapes.escapeType` fell through to as a type named `Abstract` "no build typed": five sites on the client corpus refused the escapes for it. Such a value holds its abstract's statics, which its implementation class (`TypeFact.implementation`, read off the type record's `impl`) declares: a core type has none and holds nothing. The implementation branch is unpinned — an abstract that has one, read as a value, is typed `Class<…_Impl_>` by the compiler (measured on js and the interpreter, `@:runtimeValue`), so no fixture reaches `Abstract<X>` with one; its arms (`…-ABSTRACT-STATICS`, `M-FACTS-ABSTRACT-IMPL`) were written, SURVIVED, and are not declared — branch `facts/s14`
- the client's escapes after this slice: still null, for a different and genuine reason. Before: `video.GpuDownloadPipeline.initFlipResources` holds target-language code. After: `Type.resolveClass` makes a class value of a name computed at run time — 13 sites, one in the project (`model.Node.parse`, `Type.createInstance(Type.resolveClass(name), [])` over RTTI names) and twelve in libraries (`haxe._Unserializer.DefaultResolver.resolveClass`, lime's `AssetLibrary.fromManifest`/`__fromManifest`/`fromBundle`, openfl's `Lib.getDefinitionByName`, `ApplicationDomain.getDefinition`/`hasDefinition`, `Assets.resolveClass`, `AMF3Tools.object`, swf's `AnimateButtonSymbol`/`AnimateSpriteSymbol.__createObject`). Any class may be instantiated there, untyped: under S7's producer rule that is "any instance anywhere", which no general rule narrows without an assumption about what a computed name resolves to. Measured with every refusal ignored (unsound, for scale only): 1191 escaped types, and line 61 still declines — branch `facts/s14`
- the client's `MeshScale.hx:61` after this slice: unchanged, `DynamicName` at `model/Node.hx:198`. Item 2 of the slice (instantiating `StringBuf.add<T>`'s generic `Std.string(x)` by its call sites' type arguments; narrowing `EReg.map`'s `f(this)` value channel by the escapes) was not started: with the escapes null (the producers above) a conversion of any operand but a primitive admits every `toString`, so the first narrows only where every type `T` is instantiated at is a primitive, and the second needs the escapes outright. The next blocker is a decision about those producers — branch `facts/s14`
- a class value made from a name computed at run time being "any class" (S14: 13 producers on the client corpus, the escapes null for them) → USER DECISION: the project declares which classes may be made that way, as `reflectiveClasses` in `apqlint.json` — its responsibility, exactly like `reachConfigurationsComplete`, and read only under it. Globs over qualified type names (`Glob.qualifiedNames`: `*` within one dotted segment, `**` across segments), matched against the typed ids of the classes the builds typed (kinds `class`, `interface`, `impl`). A glob matches the class actually made by its own name — declaring `model.Node` declares none of its subtypes — so each declared class escapes as an instance of exactly itself (`FactsEscapes.anyClass` → `escapeInstance`, never `escapeClass`). It bounds every producer the escapes took as "any class" except one: a computed name and a producer read as a value (`ReflectionFact.isValue`/no name), and a class declaring a producer read as a value; a producer's body the compiler spliced in (`reflection-inlined`) still refuses, because the name it lost may have been a literal, which names its one class whatever the list says and which the declaration does not cover. Without the key nothing changes. Validation: a glob matching no typed class is reported once per run (`apq lint: reflectiveClasses "<g>" matches no class the builds typed`, `FactsEscapes.unmatchedGlobs`, printed where the facts are built); a run whose linted paths declare different lists, or some none, takes such a name to name any class (`LintCommand.reflectiveBound`). Plumbing: `LintConfig` → `LintCommand.withReachConfigurations` → `ReachBuilds.reflectiveClasses` → `MemberReach.configuredFor` → `ReachProject.reflectiveClasses` — branch `facts/s15`
- the client's declaration, derived site by site (the escapes are flow-insensitive, so a producer client never runs makes nothing and needs no entry): `model.Node.parse` → `model.nodes.*` (every `childNodes` field of a `model` node is typed by a class there); lime `AssetLibrary.fromManifest`/`__fromManifest`/`fromBundle` → `swf.exporters.animate.AnimateLibrary` (the `libraryType` of all ten bundles) and `__ASSET__fonts_*` (the only `className`s of the default manifest); swf `AnimateButtonSymbol`/`AnimateSpriteSymbol.__createObject` → nothing: the `Sprites.swf` classes in `haxe/_generated` are typed by no build (every glob naming them matched nothing), so `Type.resolveClass` cannot find them there; `haxe._Unserializer.DefaultResolver` → nothing (the default manifest's `assets` unserializes to anonymous objects only, measured; client calls no `readObject`, no `SharedObject`); openfl `Lib.getDefinitionByName`, `ApplicationDomain.getDefinition`/`hasDefinition`, `Assets.resolveClass`, `AMF3Tools.object` → nothing (no caller in the client corpus or in the libraries it runs: `SWFLibrary` is the flash path). With it the client's escapes are KNOWN for the first time: 1191 types (`model.**`, broader, gave 1192) — branch `facts/s15`
- `StringBuf.add<T>`'s own `Std.string(x)` read at `T` (S13/S14's channel (a)) → a node the walk queued only through inlined calls whose bodies' facts their callers hold (`CallEdge.inlined`, set by `CallGraphFacts.declaredCall` for an `inlined` call at a known site whose splice is filed — not `harmlessSplice`) runs nowhere as itself: each caller's splice already converts at the type that call instantiated it at (`FactsView.sitesIn` reads a spliced fact at its call sites), so its own implicit-call sites wait (`MemberReach.walk`: `spliceOnly`/`deferredSites`) and are admitted the moment anything else runs it — a non-inlined edge, an admission, a re-asked site (`pending`, which the outer loop drains before it may stop). Its touches, hazards and edges are read as before. The library declaration read on demand for such a node (`expandExternal`) stays spliced in. Under the truth only. Not per-call-site instantiation of the callee's facts (the slice's wording): the splice the compiler made IS that instantiation, already filed. Unpinned guards, no fixture found that reaches them: the release of a deferred node's sites when something else runs it, the reset to not-splice-only on a non-inlined queueing (arms written and SURVIVED, not declared: a method read as a value has its closure's body spliced into the READING function, at its declared types, so the declining conversion is the reader's; a dynamic call admits by name only what the touchers' closure holds), and the outer-loop drain (`pending.length == 0`) — branch `facts/s15`
- measured, not a bug: `FactsView.harmlessSplice` looked unstable on the client corpus (`StringBuf.add` true/false across records) — the true answers were `StringBuf.addChar`/`addSub`, which a substring match had folded in; `StringBuf.add` is never harmless — branch `facts/s15`
- the client's `MeshScale.hx:61` after this slice: still declines, now at `NativeCode` in the cpp `StringBuf` (`std/cpp/_std/StringBuf.hx:51`, offsets 1634..1644: a native fact of the class's code — `charBufAsString` holds `cpp.NativeArray.address`/`NativeString.fromGcPointer` — whose offsets land inside `get_length`'s header in the installed std, not yet checked against the std the oracle builds compile): `ReachHazards.underTruth` turns every native fact into a `Native` hazard, and the walk has no S14-style assumption for target code (it reaches only what it is handed). The `DynamicName` at `model/Node.hx:198` is gone — `Node.toString` is no longer admitted by `StringBuf.add`'s generic conversion. Channel (b) (`EReg.map`'s `f(this)`) was not needed to pass `Node.hx` and is not started. Next: a USER DECISION on applying "target code reaches only what it is handed" to the member-reach walk's native hazards — branch `facts/s15`
- the member-reach walk's native hazards under the truth (S15: `ReachHazards.underTruth` made EVERY native fact a `Native` hazard) → USER DECISION (S14's, applied uniformly): target-language code reaches only the values handed to it, for the walk as for the escapes. A native site the facts read (`ReachHazard.native`) is judged by `NativeSiteReach.judge` through `FactsNativeReach` — one name scanner, one set of rules, now taking a reader per call (`NativeHand`) instead of the escapes' callbacks fixed at construction. It is a blind spot (`NativeCode`, reported at the fact's own file — a spliced native used to be reported under the walked file) when its text is computed, when its text names the member or an accessor of it (any word: a static named in another class's code included — conservative), and when a value it reaches — handed (`NativeFact.handed`) or named (a local, `this` by a this-word or a member name of its class or superclasses, a static by S14's rule) — is no value type while an object carrying the member may have left the type system (`ValueCarriers.declaredValueTypes(declaring)` meets `ValueEscapes.escaped()`, or either is unknown): once such an object escaped, a value of any type may be one (`ValueCarriers.valueTypes`), and while none did, nothing handed to target code holds one, since what is handed escapes with all it holds. Any other site is an admission (`MemberReach.nativeSite`, kind `native`): the function values it is handed (the value channel) and, by name, the members of each object it is handed (`ReachGraph.handedMemberIds`, all for a type no source spells); the call at its span is then not followed or admitted again (`judged`). "No value type" is a positive list (`NativeSiteReach.noObject`): a primitive (`FactsEscapes.inertIds`), a type the compiler represents itself whose values are never null (`@:coreType` + `@:notNull`, the kind `Int` is — `cpp.Char`), a nullable one of those, an alias of one read through (`cpp.Star<T> = Null<T>`). Without the truth every native site stays a blind spot. A syntactic native meta (`@:functionCode` written on an expression) is no fact and stays one too — branch `facts/s16`
- found WRONG, fixed: the values a call hands target code reached neither the escapes nor the walk when the callee was not typed `Dynamic`. `untyped __cpp__("x({0})", this)` and `untyped __global__.foo(this)` type their callee as a monomorph unified with the arguments, so `argFlows` recorded each argument flowing into its OWN type and `flowText` dropped it — `this` never escaped although S14's README says arguments "flow into Dynamic, and so escape already" (true only of `Syntax.code`, typed `Rest<Dynamic>`). The facts now record them on the native site (`h`, `NativeFact.handed`, `TypedFactsWalk.handedText`), for a call of a native identifier, a `Syntax` call, and a call through a field chain rooted at a native identifier (`TypedFactsShapes.nativeRoot`); such a chain's root also records the chain as its code (`untyped __global__.String` → `c: "__global__.String"`), so its names count as the code's text (S14 read a bare native identifier as naming nothing). `FactsNativeReach.siteEscapes`/`nodeEscapes` hand each to the reader, so the escapes take them too — branch `facts/s16`
- the S15 report's StringBuf position was the fact's, read in the wrong file: the native fact behind `std/cpp/_std/StringBuf.hx:51` (offsets 1634..1644) is `__global__` in `cpp.NativeString.fromGcPointer` (`untyped __global__.String(inPtr.ptr, inLen)`), spliced into `StringBuf.charBufAsString`, whose `p` names file 6 (`std/cpp/NativeString.hx`); the walk reported every hazard under the walked file. The reported path is the installed 4.3.7 std the oracle builds compile; a cpp facts compile of a `StringBuf` fixture against it shows the same fact. Handed: `cpp.Star<cpp.Char>` (`Null<cpp.Char>`, a core value type) and `Int` — no object — branch `facts/s16`
- the client's `MeshScale.hx:61` after this slice: the `NativeCode` at StringBuf is gone and no native site is the first blind spot any more (`editor.stage.grid.MeshScale` is among the client's escaped types, so a site there handed or naming anything but a value type would still be one; the walk reports only its first blind spot); it now declines at `Reification` at `popups/account/UpgradeLoginPasswordPopup.hx:40` (1240..1470): the inner `API.login` callback, which holds an un-keyed `t('Unable to login.')` — an expression macro (`macros.Lang.t`) whose expansion `FactsView.blindIn` reads as `MACRO_EXPANSION`. How the walk reaches that lambda was not traced. `EReg.map`'s `f(this)` channel was not the blocker and is not narrowed. Next: what a macro expansion in reached code may run under the truth (its expanded code's facts), or narrowing the value channel that admits that callback — branch `facts/s16`
- an expression macro's expansion under the truth (the design's S2b) → read through its facts, not `Reification`. The facts hold the expanded code every build compiled (`exps`, `ExpansionFact`), at the macro's own positions; each fact a macro's declared range holds (`CompilerFacts.expansionOf`) runs where the call of the macro was (`expansionSites`): at its anchor when the body places it, at the sites of the inlined call whose method's code holds the anchor, or where the expansion whose code holds it runs, in turn; anywhere in the node when none says. `FactsView.unplaced` no longer counts `macro-expansion` under the truth, so such a body is faceted; `CompilerFacts.within` takes its facts where they run; `CallGraphFacts.splicedSite` files an expansion's edges, unresolved sites and accesses at those sites; `MemberTouchScan.nodeAccesses` reads an access in expansion code (`expansionCode`) at them (`expansionRuns`), and one it cannot read — of a shape `classifyTyped` does not answer for, a call of a field of the member's name, a function the macro placed that names it — leaves the node `Unread` (touches, lets escape), never to its syntax, which spells only the macro's call. `FactsView.blindIn` keeps `Reification` for a reader handed no graph — the local-collection question, `returnsFresh` and `bodyChangesSharedArray` read syntax, and a macro's code may name a local of the code calling it — and for a body that is not faceted (a fact lost to a file no build read: `stale-foreign`) — branch `facts/s17`
- a faceted body's syntax still records its edge to the expression macro it calls, into the macro's own code, which runs while compiling (`Mac.t`'s body admitted a `toString` no program runs) → under the truth such an edge is answered by the expansion: its site lies in an expansion's anchor whose expander is its target (`CallGraphFacts.expandedAt`), and it is dropped with the edges the facts answer — branch `facts/s17`
- the anchor of an expansion — and the site of an inlined call — was the whole block for a call written as a statement (the innermost own-code expression around it) → `TypedFactsWalk` places a statement at no range of the body's own code between the own-code statements around it (`between`): a block keeps its statements in source order — branch `facts/s17`
- the path to the client's `UpgradeLoginPasswordPopup.hx:40` lambda (S16's open question) → `MeshScale.set_scaleFactorsArray -> GridPoint.set_text -> TextField.set_text -> set_htmlText -> HTMLParser.parse -> EReg.map -[unresolved f(this)]-> UpgradeLoginPasswordPopup.onNext#1#2#3`: `EReg.map`'s call of its parameter `f` admitted every function value of the admission closure — branch `facts/s17`
- the function-value channel → `FunctionValueTypes`: under the truth a call of a value the facts type (`UnresolvedCall.called`, `calledAt`) admits only the functions that may reach it. A PARAMETER of an instance method the method never assigns holds what the method's invocations hand it: when no class of its hierarchy escaped (`ValueEscapes.escapedIds` — reading a method as a value or a field by a name lets the object escape), it runs only at the typed call facts naming it or a supertype's member it overrides, and when each hands that parameter a function expression with exactly as many arguments as the method takes, the parameter holds exactly those (`argumentValues`). Otherwise by TYPE (`mayRun`): every type a value may be held as is its own and those the recorded flows carry it into (`typedAs` — the compiler records a flow wherever a value moves between two types it spells differently); a function admits where one of those is the called type, or names a type parameter and may unify with it (`mayUnify`, positive refusals only); where one escaped (`FactsEscapes.functionTypes`: placed where no function type types it, or held by an escaped value — a flow between two function types is none); or where it is a method obtained as a value of no type. A `.bind` closure counts as a type of the method it runs (`callerSignatures`). A function the facts give no type of, a called type that is no function type, and escapes not known keep the broad admission — branch `facts/s17`
- found WRONG, fixed: a method obtained as a value by reflection or by a name read off an untyped receiver was no function value of the admission (`ReachAdmission.valueAdmitted` knew lambdas, `dynamic` methods, `Ref`'d methods and library overrides only): `fed = Reflect.field(o, "grow")` called through a `(Rx)->String` answered `Proven`, with the truth and without. Now `obtainedUntyped`: under the truth by the facts (`FactsMethodValues.obtainedUntyped`, the receiver read by `mayHold` — a value of no class holds only an object of an escaped class, a type parameter what an instantiation binds (`FactsEscapes.parameterTypes`), a class as a value its statics), without it by the syntax of every file the graph holds (`MemberReach.reflectedNames`) — branch `facts/s17`
- `testTargetCodeReachesTheMemberOnlyThroughWhatItIsHandedUnderTheTruth`'s `untyped console.log(this)` → no longer answers `NativeCode` alone but `Reached`: handed `this`, an escaped `Main`, the call admits the value channel, which now holds `g` (a static of an escaped class a computed name may read). The assertion is `!Proven`. Retired: `M-FACTS-TRUTH-FACETED` (its fixture, a body a macro expanded, is faceted now; the body kept by a fact lost to an unread file answers through `within`'s own refusal, and one no build kept — `-dce full` — is `Proven` by liveness, so no fixture tells the cut apart); unpinned guard: `FunctionValueTypes.invokedWith`'s `dynamic` refusal (a call of a `dynamic` field admits every function value at the call already) — branch `facts/s17`
- the client's `MeshScale.hx:61` after this slice: the `Reification` at `UpgradeLoginPasswordPopup.hx:40` is gone (expansions read through facts). It still declines, now `Reached` through `EReg.map`'s `f(this)`, which admits `StdUniquePointer_RwSyncMutex.get` -> `MeshScale.new`. The parameter reading does not apply there: `EReg` escaped (held, through its variables, by an escaped `swf.exporters.animate.AnimateSymbol` at `AnimateShapeSymbol.__createObject`), and the client's builds hold 69 reflective reads by a computed name, 21 of them `Reflect.field` off a `Dynamic`, so a method of every escaped class may be obtained untyped and the type reading admits it. Next: a USER DECISION on what a reflective read by a computed name may obtain (e.g. a project bound like `reflectiveClasses`, or "computed names read variables, not methods"), or an object-level escape analysis — branch `facts/s17`
- a method obtained by a name computed at run time being "any method of any object" (S17: the client's builds hold ~70 such reads, `FactsMethodValues.obtainedUntyped` admitting nearly every method of an escaped class at `EReg.map`'s `f(this)`) → USER DECISION: the project declares which classes' methods such a read may obtain, as `reflectiveMethodHolders` in `apqlint.json` — modelled on `reflectiveClasses` (S15): its responsibility, read only under `reachConfigurationsComplete`, globs over qualified type names (`Glob.qualifiedNames`), the same plumbing (`LintConfig` → `LintCommand.withReachConfigurations` → `ReachBuilds.reflectiveMethodHolders` → `MemberReach.configuredFor` → `ReachProject.reflectiveMethodHolders` → `ReachGraph.methodValues` → `FactsMethodValues`), the same agreement rule (`LintCommand.declaredBound`, now shared by both keys: paths declaring different lists, or some none, leave the run unbounded and say so) and the same validation (`apq lint: reflectiveMethodHolders "<g>" matches no class the builds typed`, `FactsEscapes.unmatchedGlobs`). Semantics: a read by a computed name (`MethodValueReads.computed`) obtains a method of a hierarchy only off an object of a class of it the globs match (`FactsMethodValues.declaredHolders`), in both questions that read it — `obtainedUntyped` (the function-value channel) and `selfBound` (whether a rebinding call may hand the method a `this` of its choosing). A reflective member, or `Reflect`/`Type` itself, read as a value no longer makes every method obtainable when the key is present: whatever calls it later hands a computed name to any object, so it is a computed read of a receiver of no type, and `Reflect`/`Type` as a value also rebinds (it may call `Reflect.callMethod`). Unchanged: a name a literal spells (it names its one member whatever the list says), a reflective body spliced in whose name is lost (`reflection-inlined`, which may have been a literal), every variable a computed name reads (`FactsEscapes` and `ReachGraph.reflectedMembers` take no account of the key), and everything without the key — branch `facts/s18`
- subclasses: a class is declared by its own qualified name, as in S15 — declaring a class declares neither its subclasses nor its superclass. Matched against the classes of the method's hierarchy (its owner and every subtype, the objects whose dispatch may run it), so a read off an object of exactly an undeclared class obtains nothing. Not discriminating where the escapes are not: `FactsEscapes.escapeInstance` records an escaped instance as one of every class it extends, and a value of a class type escapes every subtype, so a read off a value of no type obtains the method of a declared superclass when only a subclass instance escaped — conservative, not wrong; the own-name rule is pinned through an exactly-typed receiver (`testADeclaredMethodHolderIsMatchedByTheClassOfTheObjectItselfUnderTheTruth`) — branch `facts/s18`
- the client's declaration, derived from the ~70 computed reads its builds hold (classified by reading each): only two kinds obtain a method. lime's `JNI.onCallback(object, method, args)` reads by the name Java hands it a method of every object a build hands Java as a `HaxeObject` — `lime._internal.backend.native._NativeApplication.OrientationChangeListener`, `ext.store.android._IAP.IAPHandler`, `ext.filedlg._FileSave.AndroidHandler`, `_ImageSelect.AndroidHandler` (every `(Lorg/haxe/lime/HaxeObject;)` JNI signature in the libraries client compiles; a store extension's `Log.initialize` has no Haxe caller); openfl's `File.clone` reads every `Type.getInstanceFields(File)` name off `this`, its methods included → `openfl.filesystem.File`. Every other read obtains none: over `Reflect.fields` of the object read (hxcpp lists an instance's variables only: `Reflect.copy`, `Serializer.serializeFields`, `JsonPrinter.fieldsString` — which skips a function besides — the AMF encoders, `ProductDetails`/`Purchase.toString`, `URLVariables`, `Lib.navigateToURL`, `URLLoader`/`FileReference`/`BaseNativeURLReader` request data, `StyleSheet.setStyle`, `System.__copyMissingFields`), of parsed data or structures (`API.getErrorMessages`'s `ModelState`, `Form.set_data`, every `DynamicAccess` reader — `Store.loadStorage`, `NetEntity2.appendQuery`, `NetRequest2.buildMultipartBody`, `Mime` — openfl's `Object.__get`/`propertyIsEnumerable`, whose client receivers are event data and anonymous text props, `ApplicationMain.create`'s `config`, null on native), by names that are variables (`model.Node`'s attribute and child lists; Actuate's tweened property names, every client call site naming `x`/`y`/`alpha`/`scale*`/`rotation`; `Event.__formatToString`'s literal parameter lists; `Shader.__processGLData`'s GLSL names on `ShaderData`) — all five globs match a class the builds typed. Found imprecise, not changed: hxcpp's `Type.getEnumValueIndex`/`Type.nativeEnumEq` (8 sites: `Type.enumEq`/`enumIndex`, `EnumValueTools.equals`/`getIndex`, `EnumValueMap.compare`, `JsonPrinter.write`, `XmlParser.mergeRights`, `StageArea.resolveTextProp`) are recorded as computed member reads because `MEMBERLESS_REFLECTION` lists only the portable `Type` API; they read an enum index and compare enums, and could join that list (no fixture can pin it: the interpreter and js have no such members) — branch `facts/s18`
- the client's `MeshScale.hx:61` after this slice: the `Reached` through `EReg.map`'s `f(this)` (`HTMLParser.parse -> EReg.map -> StdUniquePointer_RwSyncMutex.get -> MeshScale.new`) is gone with the declaration (and with an empty one: the four JNI handlers and `File` reach no `MeshScale` code). It still declines, now `Reification` at `Editor.hx:106`: the facts say a build macro made `Editor`'s code other than its text (`ReachGraph.rewrittenBy`, `FactsView.built`) — a new question, out of this slice. Line 111 is rewritten with and without the key, as before — branch `facts/s18`
- "`Editor` is rewritten by a build macro" (the client's `MeshScale.hx:61` after S18) → no: openfl's `@:autoBuild(AssetsMacro.initBinding())`, inherited through `Resizable` from `Sprite`, returns null for a class without `@:bind`, and `typeIsItsText` was right to read the type off its facts. It refused one fact: `t('Starting Save dialog')` handed to the inline `WaitView.load` in `saveAs`, whose expansion's call no site of the splice spelled, because the site was `[end, end]` of the body. S17's `between` bounded the splice by the own-code statements before it, and the compiler binds the `this` a closure among an inlined call's arguments captures (`(fs, ready) -> … save …`) in a statement placed at the WHOLE block, ahead of the splice. A site must hold every own-code expression of the statement it places (`TypedFactsWalk.holdsOwnCode`), else it is the block (`outer`). No unsound answer was found behind the empty site: the `inlined` call's edge enters the callee whole, and the block holding the capture is a function's own, never a loop's region (a fixture growing the collection through such a splice stayed `Reached` with the check cut, so it is no test of it) — branch `facts/s19`
- the client's `MeshScale.hx:61` after this slice: `Editor` is its text. It still declines, now `Reification` at the generated `ApplicationMain.hx` (`ReachGraph.rewrittenAs`): each build reads `ApplicationMain`, `ManifestResources` and every `__ASSET__*` class from its own `dist/oracle/<name>/…/haxe` copy, so the typed type stands in twelve files and `typeIsItsTextAs` (one file) refuses. Behind it, lime's and openfl's `Preloader` refuse `new Event<Void->Void>()`, which the facts type as the `@:genericBuild` product `lime.app._Event_Void_Void` the text never spells. Both are new questions, out of this slice — branch `facts/s19`
- hxcpp's `Type.getEnumValueIndex` / `Type.nativeEnumEq` read as member reads by a computed name (S18: `MEMBERLESS_REFLECTION` lists the portable `Type` API only; the inlined `Type.enumIndex`/`enumEq` leave them in `Type.enumIndex`, `Type.enumEq`, `EnumValueTools.equals`/`getIndex`, `EnumValueMap.compare`, `JsonPrinter.write`, `XmlParser.mergeRights` — every cpp build's std, whether the program calls them or not — and in the client's `StageArea.resolveTextProp`) → classified by the FACTS, not by a longer list: a reflective member is memberless when it is listed (members whose result's type could hold a member's value but never does: name lists, calls, class/enum values) OR when every build declares it one signature (`FieldDeclFact.types`, no `overloads`) returning a type no value of which is a function — a positive whitelist of result types, `VALUE_RESULTS` = `Void`, `Bool`, `Int`, `Float`, `String` (`FactsMethodValues.memberless`). This is the list's own definition ("whose result never holds a member's value") read off the declaration, as `FactsEscapes.producer` reads class-value producers off theirs; a member no build declares, an overloaded one, a class read as a value, and any other result type (`Dynamic`, a parameter, an abstract, `Null<Bool>`) stay "may read". Shared by `scan` and the inlined-body check (`inlinedMemberless`, was `namedReflection`). Pinned on real hxcpp facts: a C++ build is typechecked by the test kit like the js/interp ones (`-cpp out`, `--no-output` needs no hxcpp), `MemberReachFactsTest.CPP_BUILD` — the std's own enum reads made a function value `keep` read off an escaped `Grower` by a LITERAL name (`"look"`) admit `Grower.grow` (`Reached`); now `Proven`, and a `Reflect.field` by a computed name in the same place still is not. The region must not lie in a function a reflective body was inlined into: `FactsView.blindIn` answers `DynamicName` for any such node under the truth (see below) — branch `facts/s20`
- `ReachGraph.reflectedMembers` (a reflective access by a computed name the syntax sees, `ReflectiveName(null)`) admitted every method of every class the object may be of, whatever `reflectiveMethodHolders` said → narrowed the way S18 narrowed `FactsMethodValues`: a method other than an accessor (a name with an `accessorMethodPrefixes` prefix, which `Reflect.getProperty`/`setProperty` run off an object of any class) is admitted only when it is a member of a class the project declares that the object may be of — by its own name (`FactsMethodValues.declaredHolders`, now public) — or of a type such a class extends (its inherited methods). The types it may touch (`types`, what decides `DynamicName` for a variable) are unchanged; without the key `declaredHolders` answers every object and nothing changes. Pinned by `testAComputedNameRunsOnlyAMethodOfAClassTheProjectDeclaresUnderTheTruth` (an `Other` whose `dump` reads `this` by a computed name runs `grow` without the key and with `Other` declared, not with `Main` declared; a getter of `Other` still runs; an object of exactly a declared `Other` runs `grow` it inherits from `Base`) — branch `facts/s20`
- found imprecise, not changed: `FactsView.blindIn` answers `DynamicName` under the truth for any region meeting a node marked `reflection-inlined`, whatever reflective body was spliced in — even one `scan` reads as memberless by its recorded `inlined` call (`Type.enumIndex`, `Type.enumEq`, both `inline` on hxcpp). A loop in a function that inlines `Type.enumIndex` on cpp therefore declines (`DynamicName`) though nothing it reaches is read by name. The same `inlinedMemberless` reading could apply there — branch `facts/s20`
- pin repaired: `M-GRAPH-REFLECT-SUPERTYPES` was already a MISMATCH on `94a826ea` — its pinned killer `testAReflectiveAccessOnAnObjectThatMayCarryTheMemberIsADynamicNameUnderTheTruth` answers `DynamicName` without the supertypes too (`this` of `Other` handed to reflection escapes `Other`, an escaped instance counts as one of every class it extends, so `Main` is reached through the escapes); the test that kills it is `testAComputedNameStillReadsAVariableOfAnyClassWhateverTheProjectDeclaresUnderTheTruth`, which now carries the pin — branch `facts/s20`
- the client's `MeshScale.hx:61` after this slice: unchanged, still `Reification` at `Editor.hx:106` (this slice is precision, not that blocker); line 111 is rewritten as before — branch `facts/s20`
- lime's and openfl's `Preloader` refusing `new Event<Void->Void>()` in `FactsProvenance.typeIsItsText` (S19's second blocker) → the facts type the construction as `lime.app._Event_Void_Void`, the class `Event`'s `@:genericBuild` defined, which no text names, and the compiler keeps no link from that class to `Event`. The walk now records the link per construction, as the compiler's own answer: where the text at a `new`'s range parses as a construction naming a `@:genericBuild` class of the compile (its name, and its package and module where the text writes them) and the compiler resolves that class, at the type arguments the text writes, to the constructed class (`Context.resolveType` after typing, once per class and arguments), the `new` carries `gb` (`TypedFactsMacro.genericBuilt`, `NewFact.generic`), and `factsOnText` reads it as the text's where the text spells the generic's name. Never by the product's name: lime's `_Event_<args>` mangling is lime's choice, not a fact. A build macro that constructs another product where the text writes `Ev<Int>` stays refused — the text's arguments resolve to another class. The arguments resolve in no module's imports (the hook runs after typing), so an argument only the site's imports name resolves to nothing and the construction stays refused, fail-closed; the client's `Event<Void->Void>` and `Event<Int->Int->Void>` name std types only. A type REFERENCE needs nothing: no provenance question compares a declared type with its text — branch `facts/s22`
- found WRONG, fixed: the facts hook opened its file anew on each round of `onAfterTyping`, which the compiler runs again over the types defined after the hook ran, so a second round left a complete-looking file of only those types — taken whole by the reader. Asking a `@:genericBuild` again where a build macro changed the construction defines a class (the swap fixture), so this slice hit it; any project hook defining a type after typing hit it before. Every round now continues the one writer (its file indices, homes and written ids), appended and closed by its own `end` record, which the reader skips but the last (`M-FACTS-ROUNDS`). A class only that asking defined is then a record of code the real build does not have: it adds code no fact calls, never removes one — branch `facts/s22`
- asking a `@:genericBuild` again after typing runs project macro code, which can fail the facts compile: an uncaught throw, `Context.error`, `Context.reportError`, `Context.fatalError` or a redefined type all end it non-zero (measured; none is caught by the walk's `try`). Accepted: the walk asks only at a construction the text writes, at the arguments it writes, of a class of that name the compiler built there through the same macro — and the compiler runs a genericBuild at every type reference, so a macro that cannot answer the same arguments twice fails every program writing its type twice. the client's five such classes (lime `Event`, `HTTPRequest`, tink `DirectType`, `TestSuite`, hx4compat `Proxy`) look the class up before defining it (`Context.getType`, tink's `BuildCache`) — branch `facts/s22`
- the product's own members: a call reached through it (`new Ev<Int>().fire()`, lime's `Event.dispatch`) answers `UnresolvedDispatch` ("`_Ev_Int.fire`, which no indexed type declares") with the truth and without: neither the generic's text nor the product's facts are read for it (the index declares no product). Sound; open: reading the members of a class a macro defined off its facts — branch `facts/s22`
- the client's `MeshScale.hx:61` after this slice: unchanged answer, `Reification` at the generated `ApplicationMain.hx:144` (S21's per-build copies; with `rewrittenAs` forced past `ApplicationMain`/`ManifestResources`/`__ASSET__*` in a traced engine the decline stays at `ApplicationMain.hx:144` with a span, through another path). Traced on the same walk: `typeIsItsTextAs(Preloader, lime.utils.Preloader)` and `(…, openfl.display.Preloader)` false → true, the refused fact having been each one's `onComplete` construction of `lime.app._Event_Void_Void`; `:111` still rewrites — branch `facts/s22`
- the switch rules converting every `==` chain whose constants are proven → an abstract declaring
  `@:op(A == B)` is bypassed by a switch, which matches by the built-in equality (`m = Op.B` took the
  `A` rung as a chain and the `B` case as a switch); and `OperatorSelection` cannot answer the
  PATTERN half, binding no type to a qualified `T.M`, so every such pattern reads `Unproven` in any
  scope holding the std `UInt` — gate 10 asks it for the discriminant only and proves the pattern
  from its own declaration — branch `feat/prefer-switch-enum-abstract`
- two `case` patterns with different TEXT denoting different values → `DEFAULT = 0; AUTO = 0`,
  `16` / `0x10` and `M.LINES` / `1` collide; the switch keeps the chain's first-match answer but
  carries a `case` the compiler reports unused, so values are now proved (`CaseValueKey`, with the
  member's initializer recorded by the index) and must be distinct — gate 9 — branch
  `feat/prefer-switch-enum-abstract`
- an else-less `if` chain needing the COMPILER's answer about its subject's type before it can
  become a switch (the gate-7 retreat, after a waiver that omitted the wildcard miscompiled a
  `Bool`, an enum-abstract and a tuple subject) → closing it with an EMPTY `case _:` asks no
  type question at all: the chain does nothing when no rung matches and neither does that arm,
  and the wildcard makes every subject exhaustive (compiled and run on `--interp` and `-js`, same
  output). What remains structural: the head must stand in a statement list and must not be
  followed by an `#if` region that may hold its `else` — branch `feat/prefer-switch-enum-abstract`
- the switch rules' `fix` proving constants against the `index` the lint driver hands it → that
  index is REPORT-scoped, so a one-file `--fix` could not see the enum abstract in a sibling module
  that `run` had resolved through the resolution scope: the client's `MeshScale.hx:105` reported and fixed
  nothing (`0 edit(s)`); `SwitchChain.lazyIndexOf` now asks the resolution index first — branch
  `feat/prefer-switch-enum-abstract`
- `FactsView.blindIn` answering `DynamicName` under the truth for any region of a function a `Reflect`/`Type` body was spliced into (S20: hxcpp's `Type.enumIndex`/`enumEq` too) → the region is blind unless the facts name every member whose body was spliced in and none reaches a member (`splicedReachesNoMember`): no member is an access by name (`ExecutionShape.reflectiveNameCalls` — js `Reflect.setField` is listed memberless, it reads no member's value, but its lost call wrote one by a computed name) and each is memberless by S20's reading (`FactsMethodValues.memberless`, now `public static` over a table). The members come off the PRODUCER, positively: each fact `TypedFactsWalk.at` places in a reflection module now also names the method whose declared code holds it (`reflection-from:<id>`, the innermost `InlineMethod`), or says none does (`reflection-unattributed`); `FactsView.splicedReflection` reads those plus every `inlined` call naming a `Reflect`/`Type` member (a body whose own code left no fact, its whole code being another splice), and answers null — blind — on an unattributed fact or none named. Channels union over builds, so one build's unattributed fact keeps the node blind. `FactsMethodValues.inlinedMemberless` reads the same members (was: the node's `inlined` calls alone, which a fact of a splice no call names escaped). Pinned on hxcpp facts: a loop beside `Type.enumIndex(mk())` is `Proven`, beside a call-site `inline Reflect.copy(…)` (its result may hold a member's value) still `DynamicName`. `Type.enumIndex(E.A)` of a constant is folded by the compiler and splices nothing, so it pins nothing — branch `facts/s23`
- the lint end-to-end path keeping the answer of the reading it asks first when that reading proves the question (S20: "facts are not consulted when the syntax already answers `Proven`") → found WRONG, fixed: that reading reads the facts only where they hold for every build, the syntax elsewhere, and the syntax misses what only the facts see. Measured by asking every truth fixture of `MemberReachFactsTest` both ways (a throwaway probe): nine answers the truth does not prove the first reading proves. Seven are false proofs, of four shapes — a static member imported under another name and pushed to in a declaration under `#if` (`import Main.items as stuff`), a body a build macro replaced (`Mac.loop`: a region, a local), a method a build macro added (two macros), a method obtained through `Reflect.field` read as a value (one fixture, asked by two tests) — and the e2e path rewrote such a loop: the program printed 8 instead of 3. Now a proved question escalates too when the run has facts (`MemberReach.escalation`) and takes the configured analysis's answer when its facts are the truth (`FactsView.truth`); without the truth the proof stands, as before. The other two are the truth being the more conservative reading (a member's method read as a value outside the region, the positive whitelist of spliced reflection). Cost: under the truth every proved question is asked twice; the client's `MeshScale.hx` `--fix` ran 7m21s. Pinned end-to-end by `FactsFixGateE2ETest.testAProofTheTruthContradictsKeepsTheLoop` — branch `facts/s23`
- found WRONG, not changed: the syntactic reading does not see a static member imported under another name (`import Main.items as stuff; … stuff.push(5)`): with no oracle at all, `prefer-keyvalue-loop` rewrites the loop calling it (`Proven`). Under the truth the facts now answer it (above); a run without `reachConfigurationsComplete` still gets the false proof. Its own slice: the resolver binding an import alias of a field — branch `facts/s23`
- the client's `MeshScale.hx` after this slice: `:61` still declines, `Reification` at the generated `dist/oracle/mac-release/macos/haxe/ApplicationMain.hx` (S21's area); `:111` is rewritten as before, now proved by the truth as well — branch `facts/s23`
- the owner of a collection a loop reads staying `Ambiguous` under the truth when another type shares its simple name (the client's `Grid.hx:1069-1070`: `editor.stage.grid.Grid` beside `common.ui.Grid`, a second PROJECT type in `src/common/ui/Grid.hx` — no library, alias or per-target copy) → the compiler's fact of the loop's own read names the type it resolved that read on (`FieldFact.owner`), and the question now carries the read (`MemberRef.site`, set by `mayMutateNamed` to the header's receiver). Under the truth only, every field fact of the member placed at exactly that range — at least one — must name the same declaring type, written (`rootOf`) as a type the index declares under the shared name (`FactsView.pinnedOwner`); the owner's site is then a file declaring it, every one of them a project file (`MemberReach.ownerFileOf`). Anything else stays `Ambiguous`: no site, no truth, a read the builds typed on different types, one on a supertype the index declares under another name (`a.Base` behind `a.Grid`). Why S4/S9 still answered `Ambiguous`: S9 qualifies a node the walk ENTERS by a call fact, and the owner check in `answerReach` knew only `soleType` (one qualified type per name), so the question's own owner was never read off a fact. Everything past the gate stays the simple-name union (touches by every typed type standing for the name), which over-approximates the pinned type, never under — branch `facts/s24`
- a pinned owner asked for a build macro by its simple name (S24's second stop, client `Reification` with no site): `rewrittenBy` refuses any name declared twice whose types carry a build macro, since `typeIsItsText` needs one declaration → the pinned owner asks its own (`ReachGraph.rewrittenAs`, which now takes the file to site a refusal at instead of a node), and an entry in a type of a shared name asks the one its file declares, when the builds typed it (`FactsView.typedIn`, `MemberReach.entryRewritten`, the local question's too). Another type's build macro is none of either's code; the pinned type's own still refuses (`M-REACH-PINNED-REWRITTEN-NONE`) — branch `facts/s24`
- client after this slice: `Grid.hx:1069`/`1070` decline at `Escape` — `Grid.hx:700`/`702`, `lineArray = gridLinesVertical;` (`…Horizontal`): the value is stored in a local, which is only iterated and whose elements' methods are called, but a store into a local is an escape and the local's uses are not followed. Next blocker: following a local alias of the member's value. `MeshScale.hx` carries no `prefer-value-loop` finding before or after (`:61` reads two collections by `i`) — branch `facts/s24`
- found imprecise, not changed: `ReachGraph.buildMacroOn` of a name declared twice reads no declaration's `@:build`/`@:autoBuild` (`ReachProject.siteOf` answers null) and asks only the facts' `built`; without the facts every such question is `Ambiguous` first, so it is latent — branch `facts/s24`
- the syntactic reach not seeing a static member imported under another name (S23: `import Main.items as stuff; … stuff = […]`, a false `Proven` wherever the facts are not the truth) → `CallGraphImports.fieldAliases` records each `import p.T.member as alias;` of a file, own and ambient, and `MemberTouchScan.scan` reads every alias of the member as the member: a file is scanned when it spells the member OR an alias of it (an `import.hx` beside it binds one the file never names), a raw conditional region spelling an alias is a blind spot, and a bare alias the file does not bind to a local or to a member of the enclosing type touches like the member's own name, never as the object a constructor builds. Positive whitelist: an alias is dropped only when its path names a type declared once that declares the name itself and is not the member's owner; one whose path does not decode stands for any static. Measured end to end with an oracle and no `reachConfigurationsComplete`: `prefer-keyvalue-loop` rewrote the loop calling `Other.go` and the program printed 3 instead of 21; it now declines (`FactsFixGateE2ETest.testAStaticImportedUnderAnotherNameKeepsTheLoopWithoutTheTruth`, both spellings). A plain `import p.T.member;` and a wildcard `import p.T.*;` were already read: they bind the member under its own name, which the scan matches wherever no local or member of the enclosing type holds it — branch `fix/import-alias-field`
- a static FUNCTION an import binds, read as a VALUE outside its own type (`cb = g` after `import p.D.grow as g;`, also a plain `import p.D.grow;` and `import p.D.*;`) → no `Ref` edge, so a call of a function value never admitted it: `CallGraph.identTarget` resolved a bare call through the imports (`resolveBareCallee`) but a method VALUE only through the enclosing type. A value now resolves through `CallGraphImports.importedStatics` too (`importedFunction`: every static the imports bind that is a function, or that a type the index cannot list may declare; a further candidate a `Ref` edge of its own), and an alias passes the value-use filter that only knew function NAMES (`aliasesFunction`) — branch `fix/import-alias-field`
- found WRONG, not changed: a wildcard import of a type the index cannot list (`imported.unknown`: not indexed, extern, or under a build macro) read as a value adds no edge — a library function value reaches project code only through values the walk already admits, and a static a build macro adds has no node to point at (S23's `Mac` shapes) — branch `fix/import-alias-field`
- a type each build reads from its OWN copy (the client's lime-generated `ApplicationMain`, `ManifestResources` and every `__ASSET__*` class, one per `dist/oracle/<name>/…/haxe`; twelve copies, measured: the index holds all twelve, `declarationCount` 12; the values differ, `hidden: true`/`false`, `width: 0`/`1080`, build numbers, so every position after the first difference shifts) as no text, because `typeIsItsTextAs` asked for exactly one file and the facts kept one declaration per type (the first configuration's) → the facts keep every declaration a build typed and which builds read it there (`CompilerFacts.typeHomes`), and a node as those builds alone typed it (`nodeAsBuiltBy`, the line's `builds`). `FactsProvenance.textual` judges each copy by its own builds' facts (`builtAsText`, the nested functions by the same builds), never by another build's, whose text differs; a type is its text only when it is in every copy, every copy a build read is a declaration of the index (`at < 0` refuses — the graph never reads one it does not hold), readable as the compile read it, and every declaration of the index is a copy some build read (`vouched` — a copy no build vouches for is text no build compiled, which the graph folds into the type's). The build macro on all of them is tink's global `tink.SyntaxHub.build()` (`addGlobalMetadata`), the same that every other client class carries: it is why `builtAs` asks at all, and the facts show it handing the fields back — branch `facts/s21`
- the graph is NOT built from one copy, contrary to the slice's premise: the index holds every copy (`resolutionRoots` names one generated tree, yet `declarationCount` is 12 on the client corpus), each a declaration the graph folds into the one node (`soleType`), read by id (`foldedBodies`) — the union over the builds — and asked by range per declaration (`MemberReach.bodySpans`). So a per-build type is the `#if`-region case spread over files: what the facts must give is the union by id, each copy's range asked of that copy's own code, and what `typeIsItsTextAs` must check is each copy against its own builds. Three things broke that on the client's `ApplicationMain.start` (`Reification` at `ApplicationMain.hx:144`, 3019..3910 — `FactsView.blindIn`, which the S22 stand-in for this fix also met; `rewrittenAs` was not it): (1) a further declaration from another file drops the node's facts (`CallGraph.registerNode`: "facts read before it arrived describe the others alone") and `mute` never asked again, since it walked only the nodes a file declared FIRST — copies loaded one file at a time (`loadOwner`) left the node read by its syntax. `mute` now walks every declaration of the file (`_fileDeclarations`), and a node asked again retracts the unresolved sites and accesses its facts recorded before and records them anew (`CallGraphFacts.retract`): a local function of a copy not read yet resolved to nothing (`Unseen('the local function …')`) and stayed; (2) a range of a copy read the union node, placed in the FIRST build's copy (`CompilerFacts.nodesIn`/`nodesAround` returned `node(id)`, whose `at` is the first line's), so `blindIn`'s `meets` and `faceted(g, file, n.at.span)` measured one file's offsets against another's text: on the client corpus the `mas-debug` copy ("Development Build" titles, 60 characters later) put `tests-mac`'s `start` inside its own `create` — a range of a copy now reads what the builds that homed it there typed (`CompilerFacts.homedIn`, `id@home`), keeping a body a macro placed at no range; (3) a node line two builds wrote alike was kept once under the first, although a path relative to each build's own directory (iOS's Xcode `haxe/` names `ApplicationMain.hx` relative) names two files — a line is now one only when it names the same home (`NodeLine.home`), and records every build that wrote it (`NodeLine.builds`) — branch `facts/s21`
- reading a copy's range by its own builds loses the code of a copy the graph does NOT hold, which the union node placed in the first copy used to carry by its whole range → a node whose member a build typed at a range of a file none of its declarations lies in cannot be located (`FactsView.typedElsewhere` → `MemberReach.bodySpans` null → `UnresolvedDispatch`), asked of the typed types its declarations' own types are written as, so a same-named type of another package is none of it. A shift of a copy smaller than the gap between a function's graph span and its facts' range (the modifiers) does not show (2) — the fixture shifts `b`'s `calm` past `a`'s into `idle`, as the client's `mas-debug` does; one shifted past the whole node is SKIPPED by `blindIn` (`meets` false) rather than refused, which no fixture tried could tell (the walk's other readers caught every blind spot: a reflective value, an inlined `Reflect.setField`). Unpinned guards: a copy's declaration whose text is not the compiled one (`home.at == null` — a node of it then fails to place, which refuses first) and a node of these builds no fact of which places (`n == null`), both refusals as before the slice — branch `facts/s21`
- the client's `MeshScale.hx:61` after this slice: `ApplicationMain`, `ManifestResources` and the `__ASSET__*` classes are their text in every copy, and `ApplicationMain.start` is read through its facts (the `Reification` at `ApplicationMain.hx:144` the S22 stand-in met was `blindIn` on the un-faceted node, not `rewrittenAs`). It still declines, now `DynamicName` at `ApplicationMain.hx:86` (1731..1766): `Reflect.hasField(attributes, field)` over `Reflect.fields(config)` in `ApplicationMain.create`, a member named at run time — reflection precision, S20's question. Line 111 is rewritten as before — branch `facts/s21`
- a field's value stored in a LOCAL being an escape whose local is never followed (S24's client blocker, `Grid.hx:700`/`702`, `lineArray = gridLinesVertical;` in either branch of an `if`, the local only iterated) → under the truth the facts follow the local by its identity (the compiler's `TVar` id), never its name, so shadowing, captures and `#if` (the facts are per build, their uses unioned) are what that identity answers. Every local a `var` declares is an alias of its node (`TypedFactsWalk._aliases`, was: only one initialized straight from a field read); an assignment STATEMENT storing a field's or a local's value in such a local of the same node uses the value as each read of that local (`storedLocal`, `Held`), and a read stored in another local of the node links the two (`Alias.links`, resolved transitively and to a fixpoint in `aliasUses`). A write of the local is no use of it (`Assigned`). Everything else stays a `value` read — an escape: a read from a nested function, an assignment whose own value goes on (`keep(l = items)`), a store into a local of an enclosing function, an argument, a return, a field or element store. What a read IS used as is the existing positive whitelist (`MemberTouchScan.classifyTyped`): iteration, an index, a `length`, a comparison, the array type's own readers — a `push`/`splice`/`sort` is a touch. One shape the facts had no use for: a local read spliced into an inline method that declares no parameter, of the local's own class, is that method's RECEIVER (`substitutedReceiver`, `InlineMethod.arity`) — `for (i => v in l)` over a local inlines `Array.keyValueIterator`, whose `new ArrayKeyValueIterator(this)` receives the local itself (a field receiver is bound to `_this` instead, `receiverCall`), and it reads `call:keyValueIterator` like the field does. No syntax path: without the truth a store into a local is still an escape — branch `facts/s26`
- found WRONG, fixed: a touch through a local holding the member was placed at the STORE, so `var l = items; for (i in 0...items.length) { if (l.length < 3) l.push(1); }` was `Proven` under the truth and `prefer-value-loop` rewrote it — the program printed 3 instead of 2 (the `var l = items` alias the facts already followed, and every alias above would have widened it). A read held in a local now says so (`FieldFact.held`, `"h"`), and a held touch counts as one anywhere in the declaration holding it, the region included when that declaration holds the region (`MemberTouchScan.recordTyped`). Conservative: a push through such a local anywhere else in the region's function keeps the loop too — branch `facts/s26`
- client after this slice: `Grid.hx:1069`/`1070` no longer decline at `Escape`; both decline at `Reached`: `Grid.set_gridData -> GridLine.redraw -> Graphics.clear -> ObjectPool.release -> Grid.onPointMove -> Grid.redrawGraphics` (`Grid.hx:245`/`287`, the pushes building the line arrays). openfl's `ObjectPool.release` calls its `dynamic function clean(object:T)`, and the function-value channel admits `Grid.onPointMove` there, a listener read as a value; why that admission holds was not traced. Next blocker, of another kind than this slice's: which functions an `ObjectPool<T>`'s `clean` may hold (`FunctionValueTypes`, S17) — branch `facts/s26`
- a reflective access by a computed name on an object the facts type by no class (S21's stop: client `MeshScale.hx:61` `DynamicName` at the generated `ApplicationMain.hx:86`, `Reflect.hasField(attributes, field)` in `ApplicationMain.create` — `attributes: lime.ui.WindowAttributes`, a typedef of a structure, for which `FactsView.objectClass` answers null, so `ReachGraph.reflectedMembers` answered "any member of any object"; `Reflect.hasField`'s `Bool` result was not it) → two positive readings, each only for an access of a field of the object itself (`FactsView.FIELD_ACCESSES`: `Reflect.field`/`setField`/`hasField`/`deleteField`; a property access runs an accessor, which a structure may hold as a function value — js reads it off `__properties__` — so `getProperty`/`setProperty` keep the old answer). (1) A structure the code built where it acts on it — an object literal, or a local initialized with one and never written again (`TypedFactsWalk.freshStructure`, recorded `"o"`, `ReflectionFact.receiverFresh`, the `_built` / `exactObject` pattern for literals) — is no instance of any class: the name reaches its own fields, no member, whatever escaped. A field of a literal (`attributes.context`) is none: a write by a computed name on the literal may have replaced it, here with a value read off `config`. (2) An object whose type names no class (`FactsView.classless`, a positive whitelist: a structure, `Dynamic`, `Null<T>` of one, a typedef every build declares alike whose every target is one; not an unknown, a type parameter, an abstract, a function type, an enum) is a structure or an instance that left the type system — `ValueEscapes`'s own definition: a class instance reaches a place of no class only by escaping — so it is of an escaped type alone (`ValueCarriers.escapedIds`), as a class-typed receiver that is not exactly its class already was. The value WRITTEN stays the escapes' question: `Reflect.setField(o, n, items)` hands the member's value to a call (pinned `!Proven`). Pinned on interpreter facts (js inlines `Reflect.setField`, a splice blind of its own): `testAComputedNameOnAStructureTheCodeBuiltReachesNoClassUnderTheTruth`, `testAComputedNameOnAnObjectOfNoClassReachesOnlyAnEscapedClassUnderTheTruth`; `testAReflectiveAccessOnAValueOfNoClassIsADynamicNameUnderTheTruth` pinned the old answer for a `Dynamic` and a structure parameter of a class that never escaped and is now `...OnceTheClassEscapedUnderTheTruth` — branch `facts/s27`
- deviation from the slice's sketch ("a parameter, a `Dynamic` of unknown origin stays `DynamicName`"): under (2) it stays so exactly when the member's class escaped — a parameter of a structure type handed only `{ items: [] }` is `Proven`, handed a `new Main()` is `DynamicName` (the argument escaped into the structure position). On the client corpus (2) moves nothing: 1201 types escaped, `MeshScale` (a `Sprite`) among them; (1) is what clears `attributes` — branch `facts/s27`
- found redundant, not an arm: `classless` reading a typedef's targets (a typedef of a class is no structure) is unobservable by a fixture — the receiver handed to a reflective call escapes through its `Dynamic` parameter, so a class it may be of is escaped anyway (`M-CLASSLESS-TYPEDEF-TARGETS` survived, dropped as equivalent; the check stays as the whitelist's own statement) — branch `facts/s27`
- the client's `MeshScale.hx:61` after this slice: still declines, now `DynamicName` at `ApplicationMain.hx:88` (1817..1845), `Reflect.field(config, field)`: `config` is `create`'s parameter, typed `Null<?>` (an unbound monomorph), so neither reading applies, and its class-typed values may be any escaped instance. The facts show what it holds only interprocedurally: `main` calls `create(null)` and hands `create` as a value to `lime.system.System.__registerEntryPoint`, which stores it in `__applicationEntryPoint`, a map only `System.embed` reads, under `js && html5`. Proving `config` null-only needs a parameter's values across invocations for a method read as a value into a place no build reads (`FunctionValueTypes.invokedWith` declines any method read as a value), and then the `config != null` guard, or the value flow through `Reflect.setField(attributes, field, …)` into `attributes.context` — not a small step. `:111` is rewritten as before — branch `facts/s27`
- an else-less assignment chain right after a declaration (`var a:Array<L> = null; if (h) a = v; else if (w) a = z;`, client `Grid.hx:698`) was claimed by nobody: `prefer-if-expression-assignment` needs a final `else`, `prefer-ternary-assignment` exactly if/else, `join-declaration-assignment` a bare declaration → a DECL arm on both rules, under ONE predicate (`DeclFallbackChain`, `ownedByTernary` splitting the sites: one plain branch → `var a:T = c ? v : init;`, two or more or a nested construct → `var a:T = if (h) v else if (w) z else init;`), keyed on the declaration, `var` kept for `prefer-final`. The initializer IS the missing `else`. Positive gates: single-declarator mutable local, explicit `:Type` (`declaredTypeSources`), initializer `MemberKinds.isMovableLiteral` (moved there from `TrivialGetter`, same question: a literal, `null`, a negated number — it now evaluates AFTER the conditions, on the fallback path only, so a call, a field or local read a condition could change, an allocation or an interpolating string is refused), adjacency in one statement list of the PLAIN projection (a statement, a `#if` region or a comment between refuses), every branch a hoistable unit assigning the bare name (`AssignmentTreeHoist.fallbackChainValue`, sharing `branchValues` with `ifChainValue`), and exactly as many `Refs` hits of the name in the chain as there are leaves — a read, a capture, a nested write or a shadow all name a variable that does not exist yet. The hoisted l-value must BE the declared name: `if (a) y = (x = 5);` writes `x` once per leaf too — branch `feat/elseless-decl-chain`
- typing, measured with `haxe --interp` (`$type`): with a written `:T` every branch is typed against `T` exactly as the replaced `x = v;` was (`Null<A>`, `Int` for `c ? (1:UInt) : 1`, an `@:from` abstract, a subclass first). WITHOUT one the declaration is typed from the if-expression instead of from its first write: `var x = null; if (c) x = a;` is `Null<A>`, `var x = if (c) a else null;` is `Null<Null<A>>`; `var x = 1; if (c) x = (1:UInt);` is `Int`, the ternary `UInt`; and `var x = null; if (c) x = a; else if (d) x = b;` (`B extends A`) compiles as `Null<A>` while the collapsed form fails (`A should be Null<Null<B>>`). So an unannotated declaration is refused outright — branch `feat/elseless-decl-chain`
- E2E: a 16-case program (null / negative / string / hex / bool initializers, `Null<A>` with a subclass branch, a Float with an Int branch, a nested `switch` branch, a nested if/else branch, conditions with side effects counting calls, `@:nullSafety(Strict)`) compiled and run before and after a `--fix` of the two rules + `prefer-final`: identical output on `--interp` and on js (node), and the two targets agree — branch `feat/elseless-decl-chain`
- the last branch of the folded chain is NON-terminal (` else <init>` is welded after it), so it takes the else-less gate the ordinary terminal is exempt from, and opens no comment slot (`seatGaps` with no terminal span): a comment there fails closed — branch `feat/elseless-decl-chain`
- found, not changed: a carried trailing line comment (`if (a) x = 1; // one\nelse if …`, `testTrailingLineCommentRidesItsBranch`) is built by the check but REFUSED by the writer-emit gate at `--fix` ("cannot be applied without losing the comment"), on the base engine too, and that refusal skips the WHOLE file for the run, so every other fix in it is lost with it — branch `feat/elseless-decl-chain`
- the collapse moves a field read from a store statement into a BRANCH VALUE of the initializer, which S26 followed only as the direct `TField`/`TLocal` of an initializer or a stored r-value → `TypedFactsWalk.heldValue`, a positive list of value-transparent constructs (parentheses, metadata, a block by its last expression, an `if` with an `else`, a `switch`, a `try`), used by the `TVar` initializer and by `storedLocal`; `visit` already walks exactly their value positions with the use it is handed. Measured: the typer wraps each branch of an if-/switch-expression in a `TBlock`, so without the block step `final l = if (c) items else null;` stayed an `Escape` — branch `feat/elseless-decl-chain`
- client after this slice (Grid.hx `--fix`, all rules, oracle on): `Grid.hx:698-702` becomes `final lineArray:Array<GridLine> = if (gridLine.id.charAt(0) == 'h') gridLinesVertical else if (gridLine.id.charAt(0) == 'v') gridLinesHorizontal else null;` (`prefer-final` upgrades it in the same run), and `Grid.hx:1069`/`1070` (1071/1072 after the fold) still decline at `Reached` through `ObjectPool.release` (`Grid.hx:245`/`287`), not at `Escape` on the new declaration. Report-only over the client corpus `src`: 5 new findings, all decl arm — `Grid.hx:698` (if-expression), `MeshScale.hx:140`/`159`, `CrashReport.hx:279`, `LanguageManager.hx:145` (ternary); the last keeps `key` a `var`, a later `if` still writes it — branch `feat/elseless-decl-chain`
- "the writer-emit refusal of `prefer-if-expression-assignment`'s carried trailing comment skips the WHOLE file" (the `feat/elseless-decl-chain` finding above) → refuted in part, measured on a CLI fixture: since `ce8480f3` the salvage already re-asks the gate one RULE at a time, so an unrelated rule's fix (`redundant-parens`) landed; what the refusal still cost was the SAME rule's other findings in the file (a comment-free second chain stayed unfixed) and, at collection, every finding of a check `BodySlotGuard` / `DefiniteAssignmentGuard` refused for one of them. Both now split per FINDING (`LintFixDriver.findingSplitter`, `ruleEditsFor`): a refused group of two or more findings is replaced in place by one part per finding, re-asked through `Check.fix(source, [v])`, and each part judged on its own; a refused part's stderr line names its site (`<rule> at L:C: …`), a whole group's stays the bare rule id. Sound on the contract `--range` already relies on — `Check.fix` answers any SUBSET of a file's findings, so one finding's edit set stands alone and inseparable edits (a signature and its call sites, an import and its rewrite) travel inside one finding; a single finding the gate refuses is refused whole, never bisected by edit. Cost: only on the `Err` arm, one `fix` call and one round trip per finding of the refused rule — branch `fix/refused-edit-keeps-file`
- the producer half: the rule's edit text was right, the WRITER lost the comment — under `sameLine.expressionIf: same` (the compiled default) the pre-`else` gap of a value `if` is a plain space, and `kwBeforeTrailingDoc` emitted the captured `// one` ahead of it, so `else` landed on the comment's line (`x = if (a) 1 // one\nelse 3;` refused by `fmt` itself, `next` / `fitLine` / `keep` fine). `kwBeforeTrailingDoc` now answers a flat gap (whitespace `Text`, `Line`, `OptSpace*`) with a hardline and prefixes every other gap with the forward guard `_dohsbh()`, which drops before a gap that already breaks — so only outputs the round trip used to refuse change. The rule test pinned the edit text alone, which is why it never saw the gate — branch `fix/refused-edit-keeps-file`
- found, not changed (designed per-file/per-check semantics or out of scope): the RISKY phase (`FixVerifier.verifyEntry`) answers a writer refusal of a check's FULL edit set on a canonical source with `Reverted(NotCanonical)` and no bisect, though its own bisect already treats a writer-refused probe as a failing subset — a per-(file, check) whole refusal that costs oracle compiles to narrow; the ORACLE-ASSISTED phase (`LintFixVerify.applyOracleAssistedFixes`) drops a file's whole assisted edit set on any `canonicalize` `Err` through `case _:`, with no decline line and no ledger row; a source the writer cannot round-trip at all still skips the whole file (correct: no subset changes that answer); a `// c` trailing a CLOSE brace before `while` / `else` (`} // c` + `while (x);`, `} // u` + `else 3;`) renders with a stray space (` while`, ` else`) on base and here alike — that comment goes through the close-trailing path, not `kwBeforeTrailingDoc` — branch `fix/refused-edit-keeps-file`
- why the client's `Grid.onPointMove` was admitted at openfl's `ObjectPool.release` (S26's open question) → no type was asked at all: `clean(object)` is a call of a `dynamic` method (a `fieldValue` call fact), which `CallGraphFacts.declaredCall` filed as `FunctionValue` with no called type, and `MemberReach` admitted the whole value channel there (`Admission.value`: every lambda, `dynamic` method, method with a `Ref` edge, library override of the closure). `onPointMove` is in it by its `Ref` edge, handed to `addEventListener`; the erasure of `ObjectPool<T>`'s `T` never came into it. → A call of a `dynamic` method names its field (`UnresolvedCall.stored`, `AdmissionSite.stored`, set for every `fieldValue` call and every replaceable field), and under the truth `FunctionValueTypes.storedIn` admits, of the value channel, only the values STORED into that field; its declared bodies and overrides run by the call's own edges, as before. A positive whitelist (`storedValues`): an instance `dynamic` method of a class every build types alike; every write the facts type naming it (`FieldFact`, `write`, of the field of the declaring hierarchy or of a supertype); each stores `null`, a function expression (by where it is written), or a parameter of the function writing it, in that function's own code (not a body spliced in, whose parameter its caller binds), which holds what the invocations hand it (`readArguments`). Anything else — a method or a field read as the value, a local, a static, a write the text does not read as an assignment — and escapes not known leave the broad admission. A static `dynamic` method and a `var` of a function type keep it too — branch `facts/s28`
- found WRONG, fixed: a CONSTRUCTOR's parameter held what no call fact hands it: `readArguments` asked `invokedWith`, whose invocations are call facts, and a `new` is none — so the parameter held NOTHING, and `class Runner { function new(f) f(1); }` constructed as `new Runner(keep)` (`keep` holding a function that grows `items`) answered `Proven` under the truth. A constructor's parameter now reads its constructions (`constructedWith`): no subclass (which runs it through `super` or inherits it), a constructor of kind `method` (an `inline` one splices in) and no `inlined` call of it; each `new` the facts record (`NewFact`), its arguments read off the text (`boundArguments`) — an argument binds its own position or, when the construction leaves optional parameters out, any later one up to the count left out (the compiler skips an optional parameter whose type the argument does not unify with); one that may bind it holds no function when it is `null` or another literal, or a function expression whose arity is not the parameter's (every build's `FactNode.params`); a function expression of that arity is one; anything else refuses; a parameter left out holds its default, which must be none or a literal. A reflective construction runs it too (`reflectiveConstructions`): `Type.createInstance` of a class value that may be the class — a `Class<T>` holds `T` or a class extending it, a type parameter what its instantiations bind, anything else any class — hands it the element of an array literal read the same way; any other argument comes out of an `Array<Dynamic>`, so a function value there escaped, and so do the arguments of `Type` or `Type.createInstance` read as a value or spliced in: those add every function value that escaped (`ESCAPED_VALUES`, `escapedValue`: one of its types is an escaped function type, or it is obtained as a value of no type) — branch `facts/s28`
- a `dynamic` field of an object that ESCAPED (the client's `ObjectPool`: an instance reaches a place no class types) → its field may be written by name, and those writes are read too (`untypedStores`): a write off a value of no class or a structure (`FDynamic`, `FAnon`) of the field's name, stored values read as above; a reflective write (`Reflect.setField`, `Reflect.setProperty`) naming it by a literal, its third argument read off the call's text (`reflectiveStore`). Refused: a reflective writer spliced in (its name is lost), target code whose text is computed or names the field (a native site, a metadata pasting code — target code writes a field only by its name or through the reflection whose call sites the facts record, the `FactsMethodValues` assumption), and a write by a name computed at run time (a writer's computed name, `Reflect` read as a value) — unless the project declares `reflectiveMethodHolders` and no class of the hierarchy is one (`FactsMethodValues.declaredHolders`): S18's declaration of which classes' methods a computed name may name, applied to the name a write computes as to the one a read does. Interpretation to confirm: S18's user decision spoke of reads (obtaining a method as a value); a write REPLACING a method by a computed name is the same name-to-method question, and nothing else bounds it — branch `facts/s28`
- unpinned guards (no fixture tells them apart from the refusals around them): the field kinds all `dynamic` and not static (`readStored`); a constructor of kind `inline` and an `inlined` call of a constructor (`constructedWith`: a call-site `inline new` needs an inline constructor, which the kind check refuses first); a reflective writer spliced in (`untypedStores`); metadata pasting target code (`untypedStores`); a literal-name reflective write's value (`reflectiveStore`); `Type` read as a value and a `Type.createInstance` spliced in (`reflectiveConstructions`) — branch `facts/s28`
- client after this slice: `Grid.hx:1069`/`1070` still decline at `Reached`, by the same chain (`… ObjectPool.release -> Grid.onPointMove -> Grid.redrawGraphics`), for another reason. `ObjectPool.clean` now reads its stores (measured by a trace): its one write is the constructor's `this.clean = clean`, and openfl's constructions hand it a function expression (`TouchData`, `Rectangle`, `Matrix`, `Point`, `DisplayObject`, `ColorTransform`) or leave it out (`Graphics`, `OpenGLRenderer`); the escaped `ObjectPool`'s untyped channels find no write. What keeps it open is the reflective-construction channel: three `Type.createInstance` calls hand an argument array no literal spells to a class value that may be an `ObjectPool` — the client's `FormGroup.new` (`Class<C>`, whose instantiations the escapes do not bind) and lime's `AssetLibrary.fromBundle`/`fromManifest` (`Class<Dynamic>`, made by `Type.resolveClass` of a computed name) — so `clean` may hold any function value that escaped, and `onPointMove`'s `(openfl.events.MouseEvent)->Void` is an escaped function type. Next blockers: a `Class<Dynamic>` made from a computed name is a class `reflectiveClasses` declares (S15) — the facts do not say where a class value at a `createInstance` came from; the bindings of `FormGroup`'s `C`; and why a `(MouseEvent)->Void` escaped — branch `facts/s28`
- a `// c` trailing a block's CLOSE brace before a continuation keyword (`} // c` + `while` / `else` / value `catch`) put the keyword one space past the statement indent (` while (x);`), and the file was its own fixed point that way, so nothing ever repaired it. The comment is the block's close-trailing slot, emitted with the forward hardline `_dohsbh()` that drops before a following break; under a same-line policy the parent's gap is a plain `Text(' ')`, which reached `Renderer.emitText` while that hardline was still PENDING, flushed it, and was then written after the newline. Measured per keyword x mode (`same` / `next` / `keep` / `fitLine`) on base: `doWhile` stray in 3 of 4, `ifElse` 2, `expressionIf` 3 (its `keep` cell also needed two writer passes), `expressionTry` 4; statement `tryCatch` 0 — its gap is `_dossh()`, the space that drops after a break, which is why `catch` alone came out right. Fixed at the one place both halves are visible: an all-blank, non-verbatim `Text` arriving while a forward hardline is pending is dropped (a pending `OptSpace` is dropped the same way by the flush); a blank written for a same-line follower has nothing left to separate once that line ends at the hardline, and an incoming break absorbs both. Rejected: switching every `sameLine` gap to `_dossh()` at the producers (`sameLinePolicySwitch`, the `keep` slot arm, the non-curly arm, other gap sites) — several sites, a Doc shape other code pattern-matches on (`kwBeforeTrailingDoc`'s flat-gap arm), and no protection for the next producer that writes `_dt(' ')` after a block. Blast: `hxq fmt --list` 0 files over anyparse `src`/`test` (1997) and over the client corpus `src` (841) on both engines — neither tree holds the shape — branch `fix/writer-close-trail-and-assisted-drop`
- the oracle-assisted phase's silent drop (the finding above) → `LintFixVerify.applyOracleAssistedFixes` builds one `RuleEdits` group per check (`assistedGroups`) and settles each file through `settleAssistedFile`: the whole set first (the one round trip an unrefused file pays, byte-identical to before), and on `Err` the safe loop's own `LintFixDriver.salvageFileLintEdits` with an assisted splitter that re-asks `fixWithOracle(source, [v], …)` per finding — sound on the same subset contract `fix` already carries. A refused file gets a line (`oracle-assisted REFUSED <file>: <rule[ at L:C]: why | file-level why> — N edit(s) left report-only`, capped by `DECLINE_LINES_SHOWN`), a summary tail (`N file(s) REFUSED by the writer (M edit(s) left report-only)`) and its refusals in the rule's ledger row (`refusals`, the gate-refusal block). The applied count is now the edits that landed, not the edits asked for. A drifted (non-canonical) file is the case that reaches it on a real tree: the safe loop never canonicalises a file it has no edits for, so an oracle-only annotation there was dropped with no word at all — branch `fix/writer-close-trail-and-assisted-drop`
- `FixVerifier.verifyEntry`'s `Reverted(NotCanonical)` on a writer refusal of the full set (the finding above) → routing it through the existing compile bisect would be SOUND (a refused probe already counts as a failing subset, and every kept complement is confirm-typechecked) but buys the answer with compiles: every probe that canonicalises is a typecheck in each covering configuration, spent to learn what a writer round trip answers for nothing. Implemented instead as `writerNarrowed`: units are kept greedily while the kept set still canonicalises (the salvage order, zero compiles), and the kept set takes the ordinary path recursively — one typecheck when it builds, the compile bisect when it does not. An accepted set never reaches it; a refused one pays round trips plus exactly what its writable units would cost alone (measured: 1 spawn for a 2-unit set with one refused unit). An outcome that lands nothing answers as before (`NotCanonical`); `OracleUnavailable` keeps its own cause; a landed part reports `Partial` with the refused units counted as reverted — branch `fix/writer-close-trail-and-assisted-drop`
- a `GroupWithRestProbe` measured the rest of its line FLAT, so an inline anon type hint (`wrapping.anonType` fit cascade) that fits was weighed against an object-literal initializer that breaks anyway — `final obj:{` / `cropRect:…, name:String` / `} = {` for a 99-column head line (client `Cones3D.hx`). The group now runs the sibling-aware rest walk (`siblingRestStep`, until now the `IfFullLineExceeds` probe's alone) with `RestSibling.groupAsker`: the rest is cut at the head of a later construct whose content does not fit flat even from `min(col, f.indent)` — a lower bound of where the rest starts in BOTH layouts, so the cut construct breaks whatever the group does and the kept line never exceeds the limit. Two consequences of the asker being a group: a later full-line probe is not a break point (it opens on a line that holds the group's own flat content, i.e. possibly only BECAUSE the group stayed flat — `t(…).chain(…)` keeps opening `t(`), and a construct that would fit once the group breaks is charged flat (`[…].contains(type)` keeps opening the array rather than `.contains(\n\ttype\n)`). Measuring from the flat-layout column instead was tried: together with full-line probes as break points it moved 6 client files and 13 anyparse files, two of the client ones to `.contains(\n\ttype\n)` — branch `fix/anontype-fit-own-line`
- the walk lost its column at every force-flat frame, which is how an anon NESTED in a flat hint reaches the literal (`cropRect:{ … }` broke inside a flat outer hint once the outer stopped breaking). A force-flat frame now keeps the column when its flat side `rendersAsMeasured`; a rest-aware group under a force-flat region renders flat; and, for a group asker only (`restProbeEnds`), a later rest-aware group keeps the column: it renders flat as measured or breaks, ending the asker's line before any later column matters. Corpus: anyparse `src`+`test` moves `RedundantMapIterKey.hx` (a function-type hint before a `proofOf(` call that breaks by itself — same class), client `src` moves `Cones3D.hx` only — branch `fix/anontype-fit-own-line`
- found, not changed: a hint whose initializer would FIT once the hint breaks still breaks the hint (client `CrashReport.hx`: `final data:{` / `version:String, …` / `} = { fileName: …, version: _hook.version };` rather than a flat hint over a broken literal), and a `fill`-packed argument list (`callParameter` fill modes) is measured flat because its first line runs to the limit — preferring the later break there is a which-break-is-better policy, not a measure, and the flat-column variant above shows what an unconditional preference costs — branch `fix/anontype-fit-own-line`
- `reflectiveMethodHolders` reads AND writes → USER DECISION (S28 review): one key bounds a name computed at run time whichever way it names a method — obtaining it as a value (S18) or replacing a `dynamic` method by a reflective write (S28's `untypedStores`). README states both. client audited against it over the facts of all 13 builds (a temporary dump of every `Reflect.setField`/`setProperty` call, `Reflect` read as a value, a hxcpp `__SetField` call off a `Dynamic`, an element write through a `Dynamic`, computed target code and reflective bodies spliced in): 92 computed-name `Reflect.setField`/`setProperty` sites by node and position (each `ApplicationMain` copy apart) and hxcpp's `__SetField` only in `Reflect`'s own two bodies; no `Reflect` read as a value, no writer spliced in (the six spliced bodies are `Type.enumIndex`/`enumEq`), no computed target code; the literal-name writes name none of the candidate methods. The classes a `dynamic` instance method makes candidates are the client's `ItemListPicker`, `VolumeWatcher`/`ModelsVolumeWatcher`, lime's `haxe.Timer`, openfl's and lime's `ObjectPool` and std's `haxe.rtti.XmlParser` (`haxe.Log.trace` and `API.changeOffline` are static: S28 leaves a static `dynamic` method broad). No site can reach one: each writes a fresh object or structure (`ApplicationMain.create`'s window and context attributes ×13 builds, lime `System.__copyMissingFields`/`__parseArguments`, `Form.get_data`, `Node.snapshot`, `Reflect.copy`, `JsonParser`, `JsonPrinter`, `URLVariables`, `StyleSheet`, `AMFTools.unwrapValue`, `Actuate.stop`, `MethodActuator.initialize`'s `param<i>`), a model node or its target by the node's declared attribute names (`Node.parse`/`fromTarget`/`restore`/`toTarget` — no attribute is named like a candidate method), a tween target by the property names the client's `Actuate.tween` literals spell (`x`, `y`, `alpha`, `scaleX`, `scaleY`, `rotation`, `width`, `ColorUtil`'s channels) on display objects, a `Shader`/`ShaderData` by GLSL names, a timeline symbol by its instance fields (a display object, no function), an `openfl.utils.Object` payload, an object `Unserializer`/AMF3 decodes (client reads neither untrusted streams nor `ByteArray.readObject`; lime's manifests decode plain data), or a `File` (`File.clone`, already declared). So client declares nothing more. A variable of a function type is not bounded by the key at all: S28 leaves it broad, and a value written into one by name passed through `Dynamic`, so the function-value channel admits it by its escaped type — branch `facts/s28b`
- a parameter whose values are unknown because its method is read as a value (S27's client stop: `config` of the generated `ApplicationMain.create`, typed `Null<?>`, `Reflect.field(config, field)` at `:88`) → a null guard of a parameter only ever handed null keeps its branch from running, under the truth (`NullGuardedCode`, asked by `MemberReach` wherever it asks liveness: `liveHazards`, `isLive` — edges, unresolved calls, accesses, declarations — and the facts `hazardsOf` reads, each only for a fact positioned in the walked file's own text). Decided branches (a positive whitelist, `guardedBranches`): the taken branch of `p != null` (either order, alone or an operand of an `&&`) and the `else` of `p == null`, `p` resolved by `Refs` to a parameter of a member method no function encloses. The parameter holds null in every run (`nullOnly`) when: the method is static, of a class every build declares alike, not extern, every build declaring it a plain `method` of one signature, no `@:expose`; the facts say no code replaces what a call hands the parameter (`FactNode.keptParams`, new `"pk"` node header, intersected over the builds: no assignment in the typed body — `TypedFactsShapes.writtenLocals` — and no default value, which replaces a null); its type is one whose `!=` is the language's own (a class, interface, enum, the catch-all, a structure, a function type, an unbound monomorph — no abstract, `builtinEquality`); no target code names the method (every native site's text, every `@:…Code` metadata) or the parameter inside the method; no read by a name off a value of no type or by reflection may obtain it (`FactsMethodValues.obtainedUntyped`, statics); every typed call of it (`FStatic`) hands the literal `null` there (read off the call's text); and every read of it as a value (`FieldFact` `value`, not held in a local) is never called (`neverCalled`) — the general rule asked for: a function value is followed, by the facts and the text of the code it reaches, only along a positive whitelist: an argument of a typed `FStatic`/`FInstance` call of a method the builds compiled (each override too) becomes that method's parameter, which must be kept, read only outside every nested function and only (a) as an argument of such a call again (depth 8), (b) as the value an assignment STATEMENT stores into a static plain variable whose every read is a comparison (`fieldSealed`), or (c) into an element of a static `Array`/`Map` (read through typedefs) whose every write builds the container right there (`FieldFact.fresh`, now including `new Map()`, `TypedFactsShapes.FRESH_CLASSES`) and whose every read is a comparison or the receiver of an element-store statement `x[k] = v;` (`containerSealed`). A sealed variable must also be no property (`var(default|null|never|ctor, …)` only), have no call of its value (`fieldValue` call facts), no target code naming it, and no access by name — a FDynamic/FAnon access of that name, or any reflection but one that reads no member's value and writes none (`FactsMethodValues.memberless`, `setField`/`setProperty` counted) — off a value that may be the class as a value (`holdsClassValue`: a `Class<C>`/`Abstract<C>` that may be one of the hierarchy, or — any other type — a class value that escaped; a class value reaches a place of another type only by a flow `FactsEscapes` counts as an escape, so `FactsMethodValues.mayHold`'s "an abstract, a type parameter, an unknown may hold anything" is not needed here; with it the variable check refused client on some access by name off a receiver it cannot bound — openfl's `Object_Impl_` reads off an `ObjectType`, an abstract, and several off type parameters). Everything else — a capture, a return, a local, a call of a value, an extern, an inlined call, a body a macro expanded into (`READABLE_BODY` = `inline-site-unknown` only) — keeps the guard undecided. No syntax path: without the truth nothing is decided — branch `facts/s29`
- the hypothesis the parameter question rests on is used, soundly: while `nullOnly(p)` is asked (`_assumed`), a reflective or untyped access positioned in a branch a guard of `p` itself decides is no way to read the sealed variable (`assumedDead`) — by induction on time, a first run handing `p` another value would need that code to have run before it, which needs such a run. One hypothesis at a time (`nullOnly` under a hypothesis answers false), and what is read under it (`sealed`) is cached by it, so no answer computed under one assumption serves another question — branch `facts/s29`
- (a) of the slice's sketch — "a computed-name access whose receiver is only the null literal reaches no member" — rejected for (b), pruning by the guard: it does not compose. The `if (config != null)` block of `ApplicationMain.create` also holds `Reflect.hasField(attributes.context, field)` and `Reflect.setField(attributes.context, …)`, whose receiver is a `Null<RenderContextAttributes>` field of the literal — classless, escaped types (`MeshScale` among them) — the next `DynamicName` after `:88`. Pruning the branch removes all seven reflective sites at once, and every edge, access and nested function in it — branch `facts/s29`
- found redundant, not an arm: `parameterNeverCalls`'s capture check (a read inside a function nested in the method) is backed by the node check after it — the read's call or field fact lives in the nested function's node, never in the method's, so `storedNowhereRead` refuses it anyway (`M-GUARDED-CAPTURE` dropped before running; the check stays as the whitelist's own statement) — branch `facts/s29`
- found equivalent, not arms (each survived its cut, `M-GUARDED-TRUTH`, `M-GUARDED-PLAIN-VARIABLE`, `M-GUARDED-WRITERS` dropped; the checks stay as the whitelist's own statements): `MemberReach.guardedDead`'s truth test — without the truth the escapes the variable check reads refuse already; the plain-variable kinds — a store through a property's setter is an accessor call, so no field write sits at the stored place and `storedNowhereRead` refuses; counting `setField`/`setProperty` — a reflective call handed the class as a value lets it escape (`FactsEscapes`), and `holdsClassValue` then answers for every receiver — branch `facts/s29`
- the client's `MeshScale.hx:61` after this slice: the `ApplicationMain` stop clears — `ApplicationMain.create:0` holds null in every run (`create(null)` in each build's `main`; the value handed to `lime.system.System.__registerEntryPoint` is stored into an element of `__applicationEntryPoint`, a fresh `Map` read only by a comparison and that store in every client build), so the `if (config != null)` block is no code of any run. It now declines `Ambiguous(License)` (`api.namespace.License` and `popups.settings.license.License`, a name two project types share, met where the walk reads a node by its name alone) — another kind than this slice's; the predicted `UnresolvedDispatch` through `lime.app._Event_Void_Void` was not reached. `:111` is rewritten as before. One-file `--fix` runs under heavy load (other agents' suites and mutation runs, this slice's own): 2026 s, 1358 s, 1597 s, 2752 s — branch `facts/s29`
- where the client's `MeshScale.hx:61` met `Ambiguous(License)` (S29's stop) → traced: the walk entered `License.doAction#2`, a lambda of `popups.settings.license.License`, by its name alone (the value channel at std's `EReg.map`), and with it 107 more nodes of names several typed types share (`Main`, `Grid`, `File`, `Timer`, `Stage`, `Vector`, …): functions nested in a member, field-initializer runs (`<init>`, `<static>`), a static `__init__`, members admitted by name, and members a fact names the owner of whose `qualify` refused. The walk keeps the FIRST blind, so every one of them had to go. The rule changed: code no call names by a member another type of its name may declare is read as the typed type(s) the facts give for where its text lies, never by its simple name — branch `facts/s30`
- a function nested in a member (`#` ids: a lambda, a local function) of a name several typed types share → under the truth its one declaration's file pins the type (`FactsView.nestedOwner`: the type of the node's name the file declares, which the builds typed — `typedIn`), it is read through its facts by range (`bodyFacts` falls back to `typedBodies` where `foldedBodies` has no id to read by), and so read it is no shared name (`MemberReach.ownTypes`, `sharedName`); only that type's build macro may rewrite it (`rewrittenAt` → `rewrittenAs`). A nested id two types' declarations fold, a file whose type no build typed, and a body the facts do not give by range (read by its syntax) stay shared — branch `facts/s30`
- the field-initializer runs of a name several typed types share (`Grid.<init>`) → no call names them by a member: a construction or an admission by the name runs the initializers of whichever type so named it is, so the node runs the union of every typed type's (`FactsView.initializerOwners`, `initializerBodies`, was: `soleType` only), when every declaration of the name the index holds is a type the builds typed (a `#if never` twin in a compiled file refuses, RED) and every initializer the walk reads is faceted (`ownTypes`). The union is an over-approximation: `new b.Grid()` reaches a touching initializer of `a.Grid` (pinned) — a construction fact names its type, but `CallGraphFacts.construction` puts no `typed` on its edges; making it do so is precision, left — branch `facts/s30`
- found WRONG, fixed: a constructor read as one of the types sharing its name (`CallGraphFacts.qualify`) lost the run of its field initializers — `qualify` copied only edges at a site inside the owner's declarations, and `ConstructorWiring`'s constructor→`<init>` edge has none. `new b.Grid()` with `a.Grid` beside it answered `Proven` though `b.Grid`'s own initializer grows `Main.items` (RED on `dab9a55b`). An edge of no site is now the qualified node's too (`M-FACTS-QUALIFY-SITELESS`) — branch `facts/s30`
- a member admitted by its name alone run as the member of a typed type whose field so named is a VARIABLE (client: `api.namespace.License.sendAnInvitation`, an `NetEntity2` field, beside `popups.settings.license.License.sendAnInvitation()`, a static method) → `ownersDeclaring` listed every typed type declaring a field so named, `qualify` then refused the variable's owner and the walk said `Ambiguous`. A variable is no code of the node (a read of it runs nothing, a call of it what it holds — the value channel's): owners are the types declaring a method so named in some build, and the index check accepts any declaration that is a type the builds typed — branch `facts/s30`
- unpinned, the whitelist's own statements (no fixture tells them apart): `ownTypes`' requirement that the node is faceted — the syntax read of a nested function in `b.Grid` resolved an inherited `poke` to `b.Base`'s even with `a.Grid` declaring a calm `poke` (the union tables), so dropping it survived; `nestedOwner`'s one-declaration and holder checks (`typedBodies` reads one declaration only, and a nested node's type is its declaration's); `ownTypes`' coverage of every initializer span by the facts. Found equivalent, not an arm: `initializerOwners`' check that every declaration of the name is a typed type (`M-FACTS-INIT-OWNERS-UNTYPED` survived) — a declaration no build typed holds initializers no fact the union reads covers, so the coverage refuses it anyway; each check backs the other — branch `facts/s30`
- the client's `MeshScale.hx:61` after this slice: no longer `Ambiguous` first; it declines `Reification` at `src/tests/unit/VolumeWatcherDeadlockTest.hx:23` — a test class (the `UNIT_TESTS` build compiles it) whose build macro (tink_unittest's) rewrites it, reached through the broad admissions (the value channel at `EReg.map`, the extern `Array.contains`). Another kind. Behind it, measured by a temporary trace, not first: `Main.__init__` (a static `__init__`, which the facts type as the class's init node, kind `init`, no field — neither `ownersDeclaring` nor `typedBodies` reads it), `Timer.stop` admitted by its name, and the initializer runs of `AssetLibrary`, `CreateDocPopup`, `Folders`, `File`, `ListNode`, `Stage`, `ThumbBitmap` (refused by the union — why not traced). The entries a fact names the owner of (`Timer.stop@haxe.Timer`, lime's `Application`, `Vector`, `AssetLibrary`, …) are a cascade, not blockers: after the first blind the walk stops growing the graph (`ReachGraph.stopGrowing`), so the owner's file is never read and `qualify` refuses. `:111` is rewritten as before; one-file `--fix` 548 s, 599 s (cmp-identical restore) — branch `facts/s30`
- why the client's `MeshScale.hx:61` met `Reification` at `VolumeWatcherDeadlockTest.hx:23` (S30's stop) → traced: `HTMLParser.parse -> EReg.map -[unresolved]-> VolumeWatcherDeadlockTest.testDeadlockReproduction#2`. `EReg.map`'s `f(this)` is a call of a parameter, but S17's parameter reading (`invokedWith`) refused every class of whose hierarchy an instance escaped (`EReg`, held by an escaped `AnimateSymbol`), and the type reading behind it admits a function value by its own type once that type left the type system, whatever the called type (`typedAs`, `meetsEscaped`) — the test's second lambda, a `Void->Void` handed to `Thread.create`'s target code. The rule changed, under the truth: an object that left the type system is reached by its method's NAME only (S28's model for `untypedStores`: reflection, a value of no class, a structure, target code), so its parameter still holds what the calls naming the method hand it — the typed calls as before, plus, a positive list, a call by the name off a value of no class or a structure (`FDynamic`/`FAnon`), whose argument must be a function expression of the arity too (`FunctionValueTypes.untypedInvocations`). Refused: the method read as a value (`FactsMethodValues.readAsValue` — a closure, a read by its name, reflection naming it, or a computed name off a class the project declares, S18; `selfBound` now reads the same), target code that names it or whose text is computed (`FactsNativeReach.targetNames`, a call's or a metadata's), and a call of an access no reader knows naming it (`CALL_ACCESSES`). A typed call names the class whose method it runs; an unchecked cast of an escaped object to an unrelated class stays outside the model, as in S28 — branch `facts/s32`
- the unread admission at a call of a value (`MemberReach.admitUnread`) admitted every typed implicit member of the program (each `toString` and `next`, `typedImplicitIds`) and every conversion (`alwaysIds`), and the whole implicit family (`implicitIds`) as soon as ANY function value of the graph was not faceted or ANY library node was not read (`ReachAdmission.runsSyntaxRead` is graph-wide: the client's `Main.new#1`, `openfl.geom.Point.new`) — so `EReg.map` met `DynamicAccessKeyValueIterator.next` and `WebGL2RenderContext.fromGL` once the value channel was narrowed → when the site runs only the function expressions the invocations hand the parameter it calls (`onlyValues`, `FunctionValueTypes.handedValues`), under the truth, the code it runs without the walk entering it is those functions and their forward closure over invocation and `Ref` edges, a dispatch's overrides included (a library type's loaded as `follow` loads them, `loadOverrides`, unless the builds type no subtype of it), every file read as the walk would read it (`ReachGraph.loadFile`, now public: the file each handed function is written in, the file declaring a library member not read yet); each body must be faceted (`FactsView.sitesIn`), a member that runs no project code (`runsNoUserCode`) is skipped, and a body-less member counts as the walk counts it (a dispatch-only declaration, a quiet extern). Then the site admits exactly the string conversions and iterations those facts spell (`sitesRunBy`) — no `alwaysIds` (facts spell every conversion as a call), no graph-wide syntax-read or unseen check. Anything else is null and keeps the old admission — branch `facts/s32`
- the handed functions must be complete, not the graph's: a first `sitesRunBy` (never committed) took them from the graph's nodes, so a function handed the parameter in a file the walk had not read was no candidate — the client's windows-only `openfl.filesystem.File.__replaceWindowsEnvVars` hands `EReg.map` a lambda calling `Sys.getEnv`. Each written position now loads its file and must match a declared function, or the site keeps the old admission (that last check is unpinned: with the file loaded nothing reaches it) — branch `facts/s32`
- a call through a chain of target names (`__global__.String.create(…)`, which `cpp.NativeString.fromGcPointer` splices into `StringBuf.charBufAsString`) was ALSO a dynamic call by name (`FAnon`, `UnresolvedReceiver(String)`): it admitted functions by the name and every function value, and through the unread admission the whole implicit family → under the truth a `FDynamic`/`FAnon` call whose receiver starts where a native fact with a literal chain ending in `.<name>` starts is that native site's (`CallGraphFacts.nativeChained`): no unresolved call is recorded, and the native verdict, which reads what the chain is handed, answers. Without the truth nothing changes — branch `facts/s32`
- `Sys.getEnv` → `pureLibraryCalls` (reads the process environment, no callback on any target) and `statefulLibraryCalls` (what it reads `Sys.putEnv` writes) — branch `facts/s32`
- direction (b), `Array.contains` as an admission → analysed, NOT changed: `runsNoUserCode` already whitelists the built-in array's own methods (`contains` is in `nonMutatingArrayMethods`; `join`, `toString` excluded by their `String` result — an element's `toString` runs; `sort`, `map`, `filter` by `callsItsArgument`), at a read call site (`externSite`'s `arrayOwn`) and at a spliced one (`harmlessSplice`). The one branch that ignores it — `externSite` at a call site no read text holds (`site.all = takesObject || onInstance` before the array narrowing) — was reached by no fixture tried (a spliced `indexOf` beside a project call, `--interp`), nor on the client's path after this slice; a fix there would be unpinned, so none was made — branch `facts/s32`
- unpinned, the whitelist's own statements (no fixture tells them apart): in `sitesRunBy` a name several types share, a body the graph cannot locate, a site with a channel besides its values (`onlyValues`' conjuncts other than `called`), a handed position no loaded function is declared at; found equivalent, not arms (each survived its cut): `sitesRunBy`'s own `virtualTargets` (the facts already give a dispatch its `Virtual` edges, `CallGraphFacts.virtualEdges`; the call mirrors `follow` for overrides `loadOverrides` reads later), its refusal of a body-less extern that is not quiet (once a value is admitted every such extern joins the admission closure as library code, so whatever calls it is entered by the walk), and `handedValues`' truth test (without the truth no site carries the range of the value it calls); in `untypedInvocations` target code a type's metadata pastes (no js fixture pastes code naming a method by a metadata); `nativeChained`'s name and position match (an `untyped console.log(1).foo(cb)` answers `Untyped` first) — branch `facts/s32`
- the client's `MeshScale.hx:61` after this slice: the value channel at `EReg.map` admits the three lambdas the builds hand it (`HTMLParser.parse`'s, `EReg.escape`'s, `File.__replaceWindowsEnvVars`'s), each converting nothing; `Reification` at `VolumeWatcherDeadlockTest.hx:23` is gone, with `DynamicAccessKeyValueIterator.next`, `WebGL2RenderContext.fromGL` and the `StringBuf` chain behind it. It now declines `DynamicName` at `StyleSheet.__applyStyleObject` (reported at `openfl/text/StyleSheet.hx:11`, a span `360..388` of `openfl/utils/Object.hx`): `styleObject.hasOwnProperty("color")` splices `Reflect.hasField(this, name)`, which the facts record with the literal, but `ReachHazards.underTruth` makes every reflective access the syntax does not see `ReflectiveName(null)`. Another kind (reflection, not an admission). `:111` is rewritten as before; one-file `--fix` 157-166 s, cmp-identical restore — branch `facts/s32`
- a reflective access by name whose name the facts record as a literal, read as computed under the truth (S32's stop: `styleObject.hasOwnProperty("color")` splices openfl's `Reflect.hasField(this, name)`, and `ReachHazards.underTruth` made every access the syntax does not see `ReflectiveName(null)`; the facts' literal was the first of ANY argument, S1b) → recorded precisely by the PRODUCER: each `refl` fact of a call of a member that names a member of its object carries the literal at that member's NAME argument (`"m"`, `ReflectionFact.memberName`), read through parentheses, metadata and an unchecked cast (`TypedFactsShapes.literalText`, as a native call's code is), in the typed tree, where an inlined call has already put its argument. The members are a positive table with the name's index (`TypedFactsShapes.NAME_ARGUMENTS`: `Reflect.field`, `setField`, `getProperty`, `setProperty`, `hasField`, `deleteField` → 1, the grammar's `reflectiveNameCalls`); a call of any other records no member name whatever literal it is handed (`Type.createEnum`'s constructor, `Type.resolveClass`'s class). The old `"n"` is unchanged, so the facts are byte-identical but for the new field, written only where a literal is. The reader: under the truth an access the syntax does not see is `ReflectiveName(memberName)`, and one the syntax reads a computed name off is the literal every build's fact at its span names (`literalAt`: an inline constant, `static inline final NAME = "x"`); while one fact there names none, the name stays computed. From there the existing literal machinery reads it (the literal admits the member of that name and its accessors; S15/S18's keys bound computed names only). Refused: a computed name; `setField(o, n, "v")`, whose only literal is the value; a call outside the table; builds that disagree. Without the whole list of builds the syntax answers as before. `hasField` stays a named access, not memberless: S20's reading (a `Bool` result) is about values a computed name hands out; a literal `hasField` touches nothing either way, and its admission of the member's own name and accessors is the conservative half. Pinned by `TypedFactsProbeTest.testAReflectiveCallRecordsTheLiteralItsNameArgumentHolds` and `MemberReachFactsTest.testAReflectiveAccessSplicedInNamesTheLiteralItsNameArgumentHoldsUnderTheTruth` / `testAReflectiveAccessTheSyntaxReadsAsComputedNamesTheLiteralTheTypedTreeHandsItUnderTheTruth` — branch `facts/s33`
- found imprecise, not changed: an inline method reached only by `inlined` edges is still walked as itself (S15 defers a splice-only node's implicit sites, not its hazards), and its own body reads its parameters at their declared types — so a literal handed through a parameter whose declared type may be the member's class still meets the callee's own computed `Reflect.hasField(o, name)` and declines. The S33 fixture passes the object as `this` of the callee's class (`Peek.has`, `this` of a `Peek` no code reads as a value), which the callee's own reading bounds and the splice's (`o:Peek`, possibly any escaped object) does not; the client's `Object.hasOwnProperty` reads `this` as `Dynamic`, which only an escaped object can be, and no `MeshScale`, whose `_points` the question asks of, escaped. Found WRONG, not changed: `NullGuardedCode.reachedByName` reads `ReflectionFact.name` — the first literal of ANY argument — as the field a writer names, so `Reflect.setField(o, n, "v")` with a computed `n` is skipped for every field not named `v`; it could read `memberName`. `FactsMethodValues.scan` reads `name` the same way but only for a member that is not memberless (`field`, `getProperty`: two arguments, the other literal the String receiver it already excludes), where no wrong answer was found — branch `facts/s33`
- the client's `MeshScale.hx:61` after this slice: the `DynamicName` at `StyleSheet.__applyStyleObject` is gone (`hasOwnProperty("color")` names `color`). It now declines `Reached` at the constructor's `_points.push(point)` (`MeshScale.hx:39`), by `Pointer.nativeArrayElem -> MeshScale.set_scaleFactorsArray -> GridPoint.set_text -> TextField.set_text -> TextField.set_htmlText -> EReg.replace -> StringBuf.flush -> StringBuf.charBufAsString -> Pointer.nativeArrayElem -> MeshScale.new`: hxcpp's `cpp.Pointer.nativeArrayElem`, target code `StringBuf.charBufAsString` hands its char buffer, is an admission that runs `MeshScale.new` — another kind (a native site's admission, not reflection). `:111` is rewritten as before; one-file `--fix` 104 s, cmp-identical restore — branch `facts/s33`
- found WRONG (S33's), fixed: `NullGuardedCode.reachedByName` read `ReflectionFact.name` — the first literal of ANY argument — as the field a reflective writer names, so `Reflect.setField(Boot, n, "v")` with a computed `n` was skipped for every field not named `v`, and the guarded `create`'s container read as sealed (`Proven`, RED on `bc0949e1`). It reads `ReflectionFact.memberName` (S33: the literal at the NAME argument, `TypedFactsShapes.NAME_ARGUMENTS`); null — a computed name, a call naming no member, facts that do not record it — is any field. Pinned by `M-GUARDED-MEMBER-NAME`. Audit of every other reader of `name`: `FunctionValueTypes.untypedStores` and `FactsMethodValues.scan` meant "the member named" too and now read `memberName` (both dropped their String-receiver exclusion, which `memberName` makes moot); no wrong answer was found in either — `untypedStores`' only other literal is the value a writer stores (a String, never a function value) and `scan`'s readers take two arguments — so neither is pinned. `FactsEscapes.produced` keeps `name`: it reads the CLASS a class-value producer names (`Type.resolveClass`'s only argument), not a member — branch `facts/s34`
- what native target code can run, the S14/S16 assumption ("target code reaches only the values handed to it") made a POSITIVE list (`NativeSiteReach` type doc), one for every target and for both kinds of site the walk meets — a call carrying code (`__cpp__`, `__js__`, `Syntax.code`, a native identifier or a chain rooted at one) and, new, a call of an extern under the truth: (a) what it is handed, read by type (`NativeSiteReach.take`): nothing through a value that is no object (`noObject`, now also the built-in array of such values, whose own methods are target code running none of the program's); for anything else the function values it is or holds (the value channel) and its members by name (`ReachGraph.handedMemberIds`, all when that set is unknown); once an object carrying the member left the type system, an object is a blind spot at a code site (S16) and any code at an extern; (b) what its text names globally: a class of the program's — not an extern, whose members are target code themselves — that a word of the text contains (`FactsNativeReach.classesNamed`, the `classNamed` rule S14 reads statics by) runs its static methods, its constructor (the generated one when it declares none) and an instance's members by name (`ReachGraph.namedClassIds`: `handedMemberIds`, which already counts every function the class and its supertypes declare, statics and constructor among them, plus a generated constructor); (c) reflection by name only on what it holds — its members by name, (a) — since it makes a class from a name only inside the reflection whose calls the facts record (S14's `FactsEscapes` assumption, unchanged). Anything the list does not bound is today's admission. Measured, hxcpp: `cpp.Pointer.nativeArrayElem` is `::cpp::Pointer_obj::arrayElem`, `inline AutoCast arrayElem(::Array<T> a, int i) { return AutoCast(&a[i]); }` (`include/cpp/Pointer.h:496`), and `__global__.String(ptr, len)` is `String(const char*, int) : __s(inPtr), length(inLen)` (`include/hxString.h:35`): neither calls anything — branch `facts/s34`
- found WRONG, fixed: target code naming a class ran none of its code — `untyped __cpp__("::Main_obj::g()")`, `"::Maker_obj::__new()"` judged `Hands([])`, no admission, `Proven` (RED on `bc0949e1`): S14 read a static VARIABLE beside its class's name, never a static method or a constructor. Now (b) above — branch `facts/s34`
- an extern call's admission under the truth read off the compiler facts (`MemberReach.externHanded`, `FactsView.externCalls`): the values each caller's calls of the extern hand it (`HandFact.from`) and each non-static call's receiver, in the caller's code with every splice (a harmless one's too), read by (a). An `Int`, an `Array<Int>`, nothing → no admission (was: every function value, and — at a call spliced in, which the syntax cannot see — every function of the closure); the built-in array's own methods keep their channel (`callsItsArgument`) and take (a)'s members only for a string conversion (`join`, `toString`). Null — the syntax reads the call as before — without the truth, when a declaration of the caller is not faceted or a fact there has no place, or when its facts hold no call or construction of the extern. Without the truth nothing changes (pinned: `Native.dyn(1)` stays `Reached`) — branch `facts/s34`
- a gap (a) opens, closed: an extern's admission read only the FIRST caller that queued it (`reach[id]`); a second caller handing it an object went unread — harmless while every extern admitted every function value, unsound once (a) bounds them (`h1(); h2();` answered `Proven` with (a) alone). Now every caller that queues it is read (`callers`), before its admission and after (`externRevisits`); a caller that runs nowhere as itself (`spliceOnly`, an inline body whose calls run spliced into its callers at their types — `cpp.NativeArray.address` hands `Array<$address.T>`) waits until something else runs it (`waitingExterns`, the `deferredSites` pattern). Without the truth the first caller still answers alone (unchanged, below) — branch `facts/s34`
- decision to confirm: the built-in array of values that are no object is no object (`noObject`) — the char buffer `StringBuf` hands `nativeArrayElem` (`Array<cpp.Char>`), and `EReg.new`'s `Array<String>` receiver of `join`, stay inert after an object carrying the member left the type system (client: `MeshScale` escaped, so without it both admitted every function). S16 already reads a `String` or an `Int` so; an unchecked cast of an escaped object to `Array<Int>` is the one way the rule can be wrong — branch `facts/s34`
- found equivalent, removed as an arm: `M-REACH-ARRAY-ELEMENTS` (the syntax converting an `Array<E>` receiver's elements as `E`) — under the truth the facts' reading of what `join` is handed answers first (`externHanded`), and without it the syntax-read code holding the call admits every conversion (`admitAlways`), so no fixture tells the cut apart any more; the code stays. `M-REACH-ARRAY-OWN` moved to the construction fixture's no-truth twin (`classpathComplete`), which still kills it — branch `facts/s34`
- unpinned (no fixture tells them apart): `externHanded`'s escape check (an escaped owner makes an extern handed an object admit everything; `handedMemberIds` already counts every escaped type, and an unknown one makes it null, so every fixture tried answered alike); `namedClassIds`' generated-constructor branch (and, in the fixtures, which of a named class's members runs: `handedMemberIds` adds every escaped type's, so `::Maker_obj::__new()` is `Reached` through `Other` as well); `externCalls`' constructions (`NewFact`) and its "no call there" refusal — branch `facts/s34`
- found WRONG, not changed: an extern instance method of a class closed over inert values (`ReachGraph.externQuiet` → `externClosed`) admits nothing, though its receiver may be a program subclass whose override the target code calls (`class Sub extends Peer` + `new Sub().poke()`: `Proven`); an extern handed an object carrying the member (escaped or not) may write it by name — a code site is a blind spot then (S16), an extern site never is; without the truth an extern still reads only its first caller; the value channel at a native or extern site admits every function value the graph holds, not only those handed (a); field metadata pasting code (`@:functionCode`, `@:cppFileCode`, …) is no walk site, so an extern implemented in pasted code naming a class runs nothing the walk sees — branch `facts/s34`
- the client's `MeshScale.hx:61` after this slice: the native admissions at `Pointer.nativeArrayElem` and `Array.join` (both `all` before: a spliced call / an escaped `MeshScale`) admit nothing. It now declines `Reification` at `openfl/utils/Endian.hx:22` (`enum abstract Endian(Null<Int>)`) — another kind: `FactsView.built` asks every typed type of the simple name `Endian` (openfl's, lime's, …) and one records a `@:build`; not traced further. `:111` is rewritten as before; one-file `--fix` 226-233 s (105-129 s before the array rule let the walk past `Array.join`), cmp-identical restore — branch `facts/s34`
- why the client's `MeshScale.hx:61` met `Reification` at openfl's `Endian.hx:22` (S34's stop) → traced: `ReachGraph.rewrittenBy('Endian')`. The index declares `Endian` once (openfl's `enum abstract Endian(Null<Int>)`), the facts type three types of that simple name — `openfl.utils.Endian` (kind `abstract`), its `openfl.utils._Endian.Endian_Impl_` (`impl`) and `lime.system.Endian` (an `enum` the index does not hold) — each recording `tink.SyntaxHub.build()` (the hub builds every type). `FactsView.built` answered for all three and `FactsProvenance.typeIsItsText` judged all three against openfl's file; lime's is read from no file of the index, so openfl's text was "not its code". The enum abstract itself is no part of it: its implementation class carries the abstract's own builds, nothing more, and reads as the abstract (`standingFor` → `implemented`); `enum abstract` is no `@:build`-family call and the facts record none for it — branch `facts/s36`
- build-macro provenance of a name the index declares once asked by the simple name → under the truth the type that declaration is pins it: the index's declarations of the name, a copy per build or one per branch counted once (`FactsView.declaredIds`, shared with `soleType`), naming one type the builds typed (`declaredTyped`), make the question that type's (`provenanceTypes` = `standingFor` of it), for both `built` and `typeIsItsText`. A typed type of the name the index does not hold is none of that text's code and its build macro rewrites none of it. Every remaining simple-name ask on the truth path goes through it (`answerReach` unpinned, `answersByText`, `entryRewritten` and `rewrittenAt` of a name declared once, `bodyNotItsSource`, `isBuilt`); a name declared under several ids keeps the S24/S30 pins (`rewrittenAs`). Without the truth, a name declared under several ids, or a declaration no build typed, every typed type of the name is asked as before. A region running the unheld type's rewritten method is still no text of the held one (`!Proven`, pinned) — branch `facts/s36`
- unpinned: `declaredTyped`'s requirement that the builds typed the declaration (no fixture reaches it — the one that would answers `Proven` either way, below), and `built`'s own pinning (under the truth `rewrittenBy` is `built` and not `typeIsItsText`, and a type with no build of its own is its text, so `built` asked by the simple name answers the same; `M-FACTS-PROVENANCE-SIMPLE` cuts both) — branch `facts/s36`
- found WRONG, not changed: the index's one `Endian` declared in `#if never` of a compiled file (`a/Endian.hx`), the `Endian` the builds compile one the index does not hold, whose build macro makes `calm` push onto `Main.items`; a region calling `Endian.calm()` answers `Proven` on `e4ef613a` and here — the graph reads the call as the never-typed declaration's `calm`. Not traced — branch `facts/s36`
- the client's `MeshScale.hx:61` after this slice: the `Endian` `Reification` is gone; it declines `OpaqueCond` at tink_core's `Error.hx:189` — `Stack.toString`'s `return #if error_stack … #else … #end`, an expression-level conditional the syntax does not parse (another kind: what each build compiled there is in the facts). `:111` is rewritten as before; one-file `--fix` 279 s (333 s beside a running test class), cmp-identical restore — branch `facts/s36`
- a fact naming a type the index holds no text of read as the graph's node of its simple name (S36's found-WRONG: the index's one `Endian` in `#if never` of a compiled file, the `Endian` the builds compile a root-package type the index does not hold, rewritten to push onto `Main.items` — a region calling `Endian.calm()` answered `Proven`, the call bound to the never-typed twin's `calm`) → under the truth a typed type whose simple name the index declares, but in no file a build read that type from (`CompilerFacts.typeHomes`, of the type or of the type it is written as) and with no stand-in of its very id in a file no build read (the built-in array type's, written nowhere), is UNHELD (`FactsView.unheld`): the graph's node of that name is another type's code. Every place a fact names a type and the graph took the node by its simple name refuses for one (`Unseen` → `UnresolvedDispatch`, or `DynamicName`): a call (`CallGraphFacts.declaredCall`), a super constructor, a construction, a method read as a value (`field`), an override a dispatch reaches (`virtualEdges` over `FactsView.overriders`), an implicit call (`ReachGraph.unheldAt` — the implicit candidates are the index's own, so an unheld type's `toString` was no candidate at all and the walk ran nothing for it) and a method reflection reaches by a computed name (`reflectedMembers` → null). A name the index declares nowhere stays the library placeholder it was; without the truth nothing changes. Pinned RED → green, six shapes, each with a held twin (`Reached` loud, `Proven` calm) — branch `facts/s37`
- matched by FILE, not by id (deviation from the sketch's "a declaration the builds typed as that id"): the index's `declaredId` misspells three kinds the builds read from the very files it holds — a guarded `private` type (`SymbolIndexBuilder` drops a modifier lifted out of a conditional region: openfl's `private interface IVector`, the client's `RwSyncMutex`), a platform file's module (`Sqlite.cpp.hx` → `_cpp`) and a private abstract's implementation (`implemented` drops the module: `haxe.xml._Access.AttribAccess_Impl_`) — and an id match refused all eight on the client corpus. A file holds one package and the index folds a name's declarations across one file's branches into one record, so a declaration in a file the type was read from is its text. Not covered: a type compiled from a raw (unparsed) region of a file whose other branch the index holds — branch `facts/s37`
- `FactsProvenance.subtypesIndexed` asked by the simple name (S36's note) → under the truth it asks the types the one typed declaration stands for (`provenanceTypes`): an unheld namesake's subtypes override none of its code. Pinned (precision): `a.Line().all()`'s fresh array beside an unheld `b.Line` with an unheld subtype was `Aliased`, now `Proven`; `a.Line`'s own unheld subtype still refuses — branch `facts/s37`
- a raw conditional region (an expression-level `#if` the syntax does not parse: tink's `Stack.toString`, `return #if error_stack … #else … #end`) an `OpaqueCond` under the truth → the facts of the function holding it are what each build compiled there, its edges, natives, reflection and implicit sites. The `Opaque` hazard gives way (`FactsView.rawRegionRead`) when the innermost graph node holding the region whole is faceted (`faceted`: one declaration holds it; a fact with no place keeps the syntax, and the region with it) and no field or call fact in the region names the member or an accessor of it — library code is searched for an access of the member by its text alone (`libraryAccesses`), which the region hides. Refusals pinned: no whole list of builds (`OutOfScope`, as before), a marker with no place (`OpaqueCond`), a write of the member in the region (`OpaqueCond`; `Proven` without the name check). Unchanged: the touch scan's own check of a project file's raw region spelling the member (`MemberTouchScan`), and the Aliased reading (`regionCulprit`, `bodyChangesSharedArray`), which reads the syntax's hazards — branch `facts/s37`
- unpinned (each survived its cut, backed by another statement): `rawRegionRead`'s faceted requirement (a fact with no place makes `CompilerFacts.within` refuse too) and its truth requirement (without the truth a body holding a directive is not faceted); its call-name check (an accessor call of the member — a property is an `UnresolvedDispatch` of its own before it); `unheldAt`'s fallback over each operand's own type and subtypes where the facts name no type per member (every fixture's site names one). The stand-in clause of `unheld` is pinned by the built-in array's fixtures (`M-FACTS-UNHELD-STAND-IN`) — branch `facts/s37`
- found WRONG, not changed: a type the index declares NOWHERE (no namesake), compiled and indexed by nothing — the root `Endian` of the S37 fixture with no twin — runs no implicit member and no method reflection reaches: a string conversion of one (`"" + e`) and `Reflect.field(e, "c" + i)` answer `Proven` though its `toString` and `calm` push onto `Main.items`. The implicit candidates and the reflected methods are the index's (`ReachGraph.indexImplicit`, `reflectedMembers`), so such a type has none; `unheld` leaves a name declared nowhere to the placeholder rules, which never see these two channels. A call or a construction of one is refused already (the placeholder's file does not read) — branch `facts/s37`
- the client's `MeshScale.hx:61` after this slice: the `OpaqueCond` at tink_core's `Error.hx:189` is gone; it declines `UnresolvedDispatch` at std's `cpp/_std/StringBuf.hx:99` — `b.join("")`, whose native admission converts what `Array.join` is handed to strings and admits every `toString` candidate by name, `Bytes.toString` among them, whose type the index does not declare once (another kind: the extern/native admission, S34/S35 territory). One client type is unheld on the way (`haxe.io.Error`: std's file is not indexed while client, openfl, tink and `haxe.macro.Expr` declare an `Error`). `:111` is rewritten as before; one-file `--fix` 330 s, cmp-identical restore — branch `facts/s37`
- USER DECISION (S35), REVERSES three assumptions — S16's "a `String`/`Int` handed to target code is no object", S28/S32's "an unchecked cast of an escaped object to an unrelated class stays outside the model" (a typed call or write names the class it runs on) and S34's "the built-in array of values that are no object is no object": each holds only where the compiler facts PROVE it, through ONE predicate, `UncheckedConversions` (`FactsView.unchecked`): a place typed `T` may hold a value that left the type system only where some build KEEPS what lands there. Asked by `NativeSiteReach.noObject` (S16, S34: `take`, `judge`, `MemberReach.externHanded`; a value no object by its type alone, at a place that keeps, is then an object of any type, `types` null) and by `FunctionValueTypes.invokedWith`/`readStored` (S28/S32: once the hierarchy escaped, a typed call or write naming a class outside it refuses where that class keeps — `holdsForeign`). Not by reading the flows, as the sketch proposed: the producer already records every unchecked cast (`FlowFact.via` `cast`, kept whatever the two types) and every flow into or out of a catch-all (the two types differ), and the escapes consume them — but a write by a NAME (`Reflect.setField`, a field written off a `Dynamic`, target code) lands a value in a typed field of an escaped object with no flow at all, so no reading of the flows bounds what a place holds once anything escaped. What decides is the build's TARGET, which the producer now records (`{"k":"target","n":S}`, `target.name`, the second record; `CompilerFacts.targets`; every other record byte-identical). hxcpp CONVERTS into a typed place (measured in its runtime): a core value type (`@:coreType @:notNull`: `Int`, `Float`, `Bool`, `cpp.Char`) is a C++ scalar (`Dynamic::operator int`, `include/Dynamic.h`), a `String` a value (`String::String(const Dynamic &)` calls `toString`, `src/String.cpp`), a program class and the built-in array a pointer whose conversion is checked, null for another class (`ObjectPtr::CastPtr`/`_hx_isInstanceOf`, `include/hx/Object.h`; an array of another element type copied element by element, `Array(const Array<SOURCE_> &)`, `include/Array.h`), a `cpp.Star` a C pointer, an alias of one the same place; it BOXES a nullable core value (`Null<Int>` is a `Dynamic`) and keeps at a catch-all, a structure, a function type, a type parameter, an enum, an interface, an extern class and any other abstract. Every other target (js, eval, …) keeps everywhere. So a value no object by its type is none where every build converts there, or while nothing escaped (`anyMayHaveEscaped`) — branch `facts/s35`
- measured, client (13 builds, all `cpp`), a temporary trace over the facts: 101 634 flows; 57 428 unchecked — 56 146 casts (the abstracts' `cast this` among them) and 1 282 from a catch-all; 8 124 of them into a place no object by its type, 1 182 of those at a place hxcpp keeps: boxed `Null<Int>` ×505 (`ext.store.Inventory.new`, `Dynamic -> Null<Int>`), `Null<Bool>` ×486 (`debug.DebugTunnel.handleKeyEvent`), `Null<Float>` ×191 (`ext.store.android.IAPHandler`); into a class place 13 161, 66 at one hxcpp keeps (extern classes). The proof HOLDS on the client corpus: every place the S16/S34 readings meet there — `Int`, `String`, `EReg.new`'s `Array<String>` receiver of `join`, `StringBuf`'s `Array<cpp.Char>` and `cpp.Star<cpp.Char>` — is one hxcpp converts into; no flow kills it. `MeshScale.hx:61` still declines `Reification` at `openfl/utils/Endian.hx:22`, `:111` is rewritten as before; one-file `--fix` 225-287 s (S34: 226-233 s), cmp-identical restore. On js and eval the readings fall back (their std alone casts a `String` into an `Int`, `HxOverrides.strDate`, and an escaped object may sit in any field there): S16's and S34's js/eval fixtures now answer the broader way, their cpp twins as before — branch `facts/s35`
- found WRONG, fixed (S34's report), RED on `e4ef613a`: (a) an extern closed over inert values (`ReachGraph.externQuiet`) ran nothing on a receiver that may be a program subclass overriding a method, which target code may call as a virtual dispatch does (`class Sub extends Peer { override function other() … }` + `new Sub().poke(1)`: `Proven`) → no longer quiet for an instance member while a type extending it that is no extern overrides a method (`overriddenBelow`); the admission hands the receiver, whose members by name it reaches. (b) an extern handed an object carrying the member could not write it by its name, where a code site handed one is a blind spot (S16) (`Native.dyn(this)`; `box.put(this)` at a `Box<T>` parameter its own type parameter types, where `this` never escapes: `Proven`) → a blind spot (`NativeCode`; `NativeHands.blind`, `AdmissionSite.blind`): under the truth a value that may be an object once one carrying the member escaped, or written with a type carrying it — itself, or a type argument whose values it holds (`Box<Array<Main>>`) — while none did (`declaredCarrier`; pinned on eval, whose std lets no `Main` leave the type system, where js's and hxcpp's computed class producers make every project class escape); by its syntax a value its type may carry the member in (`ValueCarriers.relation`) — a literal never, and a primitive only once an object carrying it escaped. Positive list of externs writing no member by name: the built-in array's own methods, a call known to run no code of the program's (`ReachGraph.runsNoUserCode`), and a reflective access by a name (`reflectiveNameCalls`), which the walk judges by the name it is handed. Judged where PROGRAM code hands values: an extern target code runs (an `extern`/`native` admission, `TARGET_ADMISSIONS`) was handed no more than the admitting target code holds, judged where that was handed (S14's assumption). (c) without the truth an extern read only its first caller, and of that caller one call (`h1(); h2();`, `h()` with two calls: `Proven`) → every caller, every call site (`callers` without the truth, keyed by site) — branch `facts/s35`
- found WRONG, fixed on the way (RED): `FunctionValueTypes.invokedWith` read the typed calls naming the owner or a supertype of it, so a call through an interface only a SUBCLASS implements (`var s:I = new Sub(); s.visitRx(f)`) handed the parameter nothing → the supertypes of every class of the hierarchy. And the string literal a native site records as its code (`NativeFact.code`) is no value handed to it (`FactsNativeReach.handed`): `js.Syntax.code("0")` was handed a `String`, which on js may now be any object — branch `facts/s35`
- the S28 typed-call/write readings are pinned on eval (`interpAsk`): on js and on cpp the std holds target code of a computed text, so `untypedInvocations`/`untypedStores` refuse an escaped hierarchy before a typed call is read, and both fixtures answer `Reached` on base already. The cpp side of `holdsForeign` is pinned by `UncheckedConversionsTest` over hand-written facts. Unpinned: `anyMayHaveEscaped` (every real std escapes some object, so no fixture has none), the `seen` guards of `converts`/`coreValueType` (no alias cycle reads). Found surviving on base already, not this slice's: `M-REACH-QUALIFIED-ESCAPE` (`e4ef613a`: 0 of 988 assertions fail) — branch `facts/s35`
- found WRONG, not changed: on hxcpp a conversion into a `String` place — `var s:String = dyn`, `cast obj`, an `Array<String>` copied from an `Array<Dynamic>` — runs the value's `toString` (`String::String(const Dynamic &)`), an implicit call the walk models for a `+` operand and a thrown value only (`strs`); the value channel at a native or extern site still admits every function value the graph holds (S34) — branch `facts/s35`
- a type the index declares NOWHERE (S37's found-WRONG: the root `Endian`, compiled, no namesake indexed) ran no implicit member and no method reflection reaches — a string conversion of one and `Reflect.field(e, "c" + i)` answered `Proven` though its `toString` and `calm` push onto `Main.items` — because every implicit candidate and every reflected method is the index's → under the truth such a typed type is TEXTLESS (`FactsView.textless`: typed, no typedef, no declaration of its simple name anywhere the index reads) and contributes its candidates as unresolved, never as nothing. One rule for both the unheld (S37) and the textless type, read off the facts as the index reads its own candidates (`FactsView.implicitUnheld`, `ImplicitMembers` per family — `ReachGraph.implicitMembers` mirrors `indexImplicit`): the type declares, itself or for an abstract its implementation, a method a call of that family runs — an instance method of a conversion's / an iteration's names (an abstract's statics count), one marked by an operator / index / conversion metadata, or the type is built from a literal (`@:structInit`). Positive clearances: an interface (no code of its own; each implementor is a type of its own), an extern's body-less method (target code, as `externQuiet` reads one), an extern's inline method at a conversion (the target's own conversion runs, not the Haxe body). Where it is asked: a site the facts type (`unheldAt`: the owned types, else each owner and its subtypes), a site whose operands' types are not known — every typed type the facts know that is in play as an index candidate would be (`textlessInPlay`: extern, a reflective producer, or its name / a subtype's spelled in the code the index reads; `mentions` now counts every typed type's simple name under the truth) — code the walk does not read (`admitUnread`: string conversions and iterations, every family once library code is read), conversions anywhere code read by its syntax runs (`unheldInPlay(..., always)`), and a method reflection reaches by a computed name (`reflectedMembers`: refuses only for a method it would admit, an extern's aside — target code, the native admission's). Pinned RED → green: `"" + e`, `Reflect.field`, `"" + d` for a `Dynamic d`, an unread lambda converting what it is handed, a local inline function's body converting (a `@:to`), unread library code running an `@:op` — each with a held twin; precision: a textless type with no `toString`, with a static one, one nothing names, an interface implemented by a held type — branch `facts/s38`
- the syntax path had the same hole: a value statically typed as a name the index declares nowhere is "any type" (`typesAt` → null), and "any type" admitted only the index's candidates → read by its syntax, such an operand refuses (`ReachGraph.undeclaredOperand`: `UnresolvedDispatch`), whether facts are absent or not the truth. The language's own pass: a primitive (`ValueCarriers.primitive`), the catch-all, the built-in array and map types the shape names — an index of the project alone declares none of them, and refusing those cost `prefer-keyvalue-loop` every array loop (pinned, precision) — branch `facts/s38`
- fixtures: the reach fixtures index std stand-ins beside the array type (`STD_STAND_INS`: `HxOverrides`, `haxe.Exception`, `haxe.ValueException`) — the js builds type and let escape those std classes, whose text a fixture index holds nothing of, and their `toString` / reflected methods now refuse every escaped conversion; a project index holds std (the client's `resolutionLibs`), where they are held — branch `facts/s38`
- found WRONG, not changed: (1) read by its SYNTAX alone, a value of the catch-all holding an instance of a type the index declares nowhere converts with the index's candidates only (`final d:Dynamic = e; "" + d` answers `Proven` without the truth; under the truth it refuses) — no syntax-side list of the compiled types exists to widen "any type" by; (2) a HELD type whose facts declare a method its indexed text lacks (a fixture stand-in without `toString`, a member a build macro adds where `Reification` does not answer) is a placeholder to reflection and no implicit candidate — the same silence, one level down; (3) an escaped extern's body-less method reflection reaches is skipped as before (target code; the native admission's, S35) — branch `facts/s38`
- the index misspelled three ids the builds read from the very files it holds (S37 matched `unheld` by FILE for them) → fixed at the producer: (1) a guarded `private` modifier (`#if cpp private extern class P {} #end`, the client's `RwSyncMutex.hx`, openfl's `IVector`) was dropped as "a lifted modifier other than extern" — `SymbolIndexBuilder.collectGuardedDecls` now lifts it onto the declaration the region holds, past the other modifiers marking it; a modifier SPLIT from its declaration (`#if cpp private #end class P`) marks it in some builds only and is still dropped (a type public in any build keeps the binding); (2) a platform variant's module (`Sqlite.cpp.hx`): measured on 4.3.7, `Foo.js.hx` is the module `Foo` on js (`_Foo.P`) and not found on `--interp` — a module name holds no dot, so `RefactorSupport.moduleNameOf` is the basename up to its first dot, used by the index (module, `isMain`) and `ModuleScan.moduleOf` (moves, renames); (3) a private abstract's implementation: measured, `private abstract A` in `pkg.Mod` is `pkg._Mod.A` with `pkg._Mod.A_Impl_`, a public sub-type `B` is `pkg.B` with `pkg._Mod.B_Impl_` — the id alone cannot tell them, so `FactsView.implemented` asks the facts (the abstract whose `implementation` it is) and keeps the spelling rule for none. Pinned per shape (`SymbolIndexSliceTest`, and a facts test that every index id equals the typed one) — branch `facts/s38`
- `unheld` keeps matching by FILE, measured on the client corpus (one-file `--fix` with a census of every typed type with a declaration of its name in a file a build read it from): ids that disagree went 92 of 2846 → 45 of 2846. Fixed: every guarded-private type (openfl's `_Vector.*Vector`/`IVector`, the client's `StdUniquePointer_RwSyncMutex`, lime's `_ThreadPool.JobQueue`, tink, actuate, openfl filters and AGAL types), `Sqlite.cpp.hx`'s two, and every private abstract's `_Impl_` (`haxe.xml._Access.*`, the client's `FloorColor`, `SquareParts`, `InitStep`, `AILanguagesState`). Left, and why the file stays the key: (1) `flash.*` types the builds read from openfl's files (`flash.Lib` <- `openfl.Lib`), the compiler's own renaming of a package, which no index id can spell; (2) a branch-folded record (`openfl.utils._Object.Iterable_`, a `private interface` in one branch and a public `typedef` in the `cs` one) is public by the fold's rule (`withAlternate`: private only when every branch is), so one id cannot be both; (3) the one-line SPLIT private in every branch, `#if (haxe_ver >= 4.0) private enum #else @:enum private #end abstract SystemDirectory(Int)` (lime's `SystemDirectory`, the 14 `_NativeApplication.*EventType`, `MouseCursorType`, `WindowFlags`, `ThresholdOperation`, with their `_Impl_`s): every branch holds `private`, but the region projects flat and the shared branch recovery (`CondBranchProjection.conditionalBranchRuns`) reads a directive only at a line start, so the branches of a one-line region are not recoverable and the split modifier is dropped — found, not changed (it needs a directive reading that is not the line-start scan). A file holds one package and the index folds a name's branches into one record, so a declaration in a file a build read the type from is its text whatever id the index spells — file matching is exact where ids are not. Other consumers of these ids: the full suite is green (906 classes / 16258 tests); client `unused-import --no-oracle --all` over `src` is identical on both engines (101 = 101) — branch `facts/s38`
- the client's `MeshScale.hx` after this slice (measured on the file as the coordinator's autofix left it — `:111` was already `for (i => point in _points)`): `:61` declines exactly as before, `UnresolvedDispatch` at std's `cpp/_std/StringBuf.hx:99` (`Bytes.toString` through `Array.join`'s native admission, S35's), on both engines; one-file `--fix` 4m02s (base 4m44s), `cmp`-identical restore of `MeshScale.hx` and `apqlint.json` — branch `facts/s38`
- found WRONG, fixed (S35's report), RED on `005afa7c`: a value put at a `String` place on hxcpp runs its `toString`, a call the walk modelled for a `+` operand and a thrown value only. Measured (S39, one probe compiled to hxcpp, js and eval, the object held in a `Dynamic`): a `var`, an assignment, an argument, a returned value, an unchecked cast, an element of an array literal, a `VirtualArray` converted into an `Array<String>` (in place: a later `join` of it runs nothing), a field of a `String` type set by `Reflect.setField` or through a catch-all receiver — each runs `toString` once on hxcpp and never on js or eval, which keep the object there (a later `join` then runs it). Under the facts (`FactsView.conversionSitesIn`): each flow into a `String` place — a nullable one, an alias, an abstract wrapping one — is a string conversion of the value, and into an array of strings one of each element copied (`UncheckedConversions.stringOperands`); a value of a type every value of which is a string (`stringValued`: an enum abstract over `String` among them) converts nothing. A reflective write by name (`Reflect.setField`/`setProperty`) and a write to a field of a catch-all are a conversion of any value. Only where some build converts (`convertsSomewhere`: a `cpp` target, or one whose facts do not say its target; without the truth any build may) — branch `facts/s39`
- the same hole read by the syntax → a positive list (`ImplicitSites.landings`), each site marked `landing` and dropped under the truth when no listed build converts (`MemberReach.sitesOf`): a value lands at an initialized declaration's annotated type (an unannotated one is typed as its value), an assignment's left side, the annotated return type of its function (a lambda's is unknown), and an unknown parameter for every argument of a call or a construction; it converts where the syntax reads the value as one that may have left the type system (`mayBeForeign`: an unchecked cast — whose own operand is then the site's —, untyped code, of a catch-all, of the built-in array, of no known type; a comparison, a negation, an interpolated string, a concatenation with a string are not) and the place as one that may convert (`mayConvertAt`: not a catch-all, a primitive other than `String`, or a class/interface/enum declared once other than the array). The operand is of any type: precision cost in the syntax reading where an argument is of no type the syntax knows — branch `facts/s39`
- refuted on the way, NOT taken: "a catch-all holds an object only once it left the type system, so converting one runs only the escaped types' `toString`" — `ValueEscapes` reads project code alone, and a library factory's `Dynamic` result is any library class it constructs (`MemberReachTest.testLibraryInstanceMadeOutOfSightRunsItsMembers` went red); a catch-all operand stays any `toString` in play — branch `facts/s39`
- the client's `MeshScale.hx:61` blocker at std's `cpp/_std/StringBuf.hx:99` (`b.join("")`) → the syntax types the field `b` as a bare `Array`, so the conversion site the extern admission adds had an operand of any type and admitted every `toString` by name, `Bytes.toString` among them. Under the truth an extern returning a string converts what the facts say its calls hand it (`MemberReach.handedConverted`): nothing of a value no object (`NativeSiteReach.take`; on hxcpp an `Array<String>` holds strings alone, S35), of the built-in array's own method the elements of the array (`Array<T>` → `T`'s `toString` and overrides), any for a type no source spells or a container. The built-in array's own method no longer hands its receiver's members by name besides (`hand`): it reaches them only by converting them, as its doc always said — branch `facts/s39`
- `Std.string(x)` and an interpolated or concatenated `Int`/`String` already convert nothing (`ReachGraph.inertType` at every `Text` site). Found WRONG, not changed: that skip is by the static type alone, on every target — on js and eval a `String`/`Int` place may hold an object an unchecked cast put there (S35), whose `toString` such a conversion runs; S35's proof (`UncheckedConversions.none`) is consulted by native and extern sites only — branch `facts/s39`
- `M-REACH-QUALIFIED-ESCAPE` (S35: survived on base) → it cuts the escape `scanNode` records for a node of a shared name read as one type's member, after the question checked every escape up front; the fixture's `keep = stuff` was found up front all along — the graph's folded `Grid.run` is not faceted, so the syntax read `b/Grid.hx`, which spells the import alias. Killed by a store through a library macro's expansion (`keep = Mac.grab()`), which no project text spells and only `b.Grid.run`'s facts show — branch `facts/s39`
- the conversions read off the facts stand at every flow of a body, and on the client corpus the walk did not finish in 20 min (`--prof`: 47% `Array.includes`, 29% `enqueueTyped`) → three quadratic scans the extra sites exposed: `enqueueTyped` looked for a known caller in the list (`callerKeys`, a set keyed as the old predicate compared: by caller under the truth, by caller and site without it), `apply` deduplicated its ids with `contains` (a set beside the list), and each site recomputed what it may run (`ReachGraph.ownedIdsAt` memoised by family, operand types, exactness and owners, dropped with `_implicit` — `dropImplicit`); the conversion operands of a pair of facts types are read once (`FactsView.conversionOperands`) and a body holds one site per operand. One-file `--fix` back to 261 s — branch `facts/s39`
- unpinned: a syntax-read body's landing sites dropped under the truth when no listed build converts (`MemberReach.sitesOf` — no fixture holds a body the truth does not facet on a js/eval list); an extern conversion with no call span admitting everything (`site.all`, conservative) — branch `facts/s39`
- found WRONG, not changed: `M-REACH-EXACT-SITE` SURVIVES on `005afa7c` too — under the truth `ownedTypesAt` answers every typed operand, so `typesAt`'s exactness is read only without the truth or for an operand of no typed owner, which no fixture of its killer reaches — branch `facts/s39`
- the client's `MeshScale.hx:61` after this slice: the `UnresolvedDispatch` at `StringBuf.hx:99` is gone (the `join` hands `Array<String>`, proven no object: no conversion site at all); it declines `UnresolvedDispatch` "the body of `TextFormat.<init>`, which the graph cannot locate" — reached by plain calls (`MeshScale.set_scaleFactorsArray -> GridPoint.set_text -> TextField.set_text -> set_htmlText -> HTMLParser.parse -> TextFormat.clone -> TextFormat.new -> TextFormat.<init>`), `bodySpans` finding no initializer span in openfl's `TextFormat.hx`, whose whole class sits in a module-level `#if !flash` (not traced further; another family). Behind it: `AggregateCommand.toString`, admitted by a conversion of any value in `StyleSheet.__applyStyleObject`, reaches unlocated `ApplicationMain.start`/`create` and `ManifestResources.init`. One-file `--fix` 261 s (S37: 330 s, base here 313 s), cmp-identical restore — branch `facts/s39`
- a BLOCK comment trailing a block's close brace (`} /* c */ else 3;`) forced a break before the continuation keyword under every same-line policy: the statement / value block arms (`HxStatement.BlockStmt`, `HxExpr.BlockExpr`, the only `appendHardlineAfterTrail` callers) pushed `_dohsbh()` after the close-trailing comment whatever its style, though `trailingCommentDocGuarded` already adds that forward hardline for a LINE comment and deliberately not for a block one. Measured on base, `same` mode: `ifElse` (statement, `else if` too), `doWhile`, `expressionIf`, `expressionTry` all broke; the statement `try` came out `} /* blk */` + newline + `catch` because a second producer, `buildCloseTrailingFirstSepOverride`, dropped the first-catch gap (`_de()`) after ANY close-trailing comment — with the extra hardline gone that turned into `} /* blk */catch` under every policy. Fixed at both sources: the Alt arms push nothing after the guarded emitter (the `trailFollowExpr` / `appendHardlineAfterTrail` plumbing is deleted), the empty-block arm uses the same guarded emitter instead of `Verbatim + _dhl()`, and the catch override fires only for a `//` comment. Result per keyword x mode (`same` / `next` / `keep` / `fitLine`): the output equals the UNCOMMENTED construct's layout with ` /* c */` after each `}` — glued where the policy glues, broken where it breaks (`next` for `ifElse` / `doWhile` / `tryCatch`; `expressionIf` / `expressionTry` keep `} else` / `} catch` glued under `next` with or without the comment). Also fixed on the way, same seam: an EMPTY block's line comment (`if (a) {} // c` + `else`) put the keyword one space out under every mode (its hard `_dhl()` was not a pending hardline, so the previous slice's absorb rule never saw it), and `{ /* n */ } // c` + `else` / `(/* n */) // c` + `{` emitted the line comment unguarded and swallowed the keyword / brace (comment-loss refusal) — the two empty-open-trail fast paths now use the guarded emitter too — branch `fix/writer-comment-fidelity`
- comments the writer DROPPED in a declaration's gaps (`fmt` / `--fix` refused the file): (1) `function f():Int /* c */ {`, `function f():Int // c` + `{`, `function f():Int /* c */ return 1;`, interface `function f():Int /* c */;` — the parser HAD the comment, in `HxFnDecl.body`'s `BeforeLeading` slot (the bare non-first Ref's `collectTrivia` run), but `emitLeftCurlyBody`, the brace-placement seat every `leftCurly` body field goes through, never read that slot (only `buildBareRefLeadingSep` did); without a return type the same comment trails `)` and rides the params' close-trailing slot, which is why that form was canonical. The seat now emits each captured comment through `trailingCommentDocGuarded` before the brace / body-policy separator, so the layout after it is decided exactly as after the params' slot (a line comment breaks, the brace on the next line at the declaration indent; an own-line block comment joins the signature line). (2) `var x /* c */ = 1`, `var x:Int /* c */ = 1`, `f(a /* c */ = 1)`, `f(a /* c */:Int)`, `var x(get, set) /* c */:Int`, `A(x /* c */:Int)`, `catch (e /* c */:T)`, `for (k /* c */ => v in m)`, `{x /* c */:Int}`, `{?x /* c */:Int}`, `{a /* c */: 1}`, `(a /* c */:Int) -> Void` — the gap before a `@:lead` literal had no slot: the optional lead commit (`emitOptionalRefLeadCommit`) and the mandatory lead-in (`emitFieldLeadIn`) ran `skipWs` before the literal. New `<field>BeforeLead:Null<String>` slot, the mirror of `BeforeTrail`: host `TriviaPairSlots.isBeforeLeadRef` (a Ref with `@:lead`, no `@:kw`, no `@:absentOn` / `@:absentOnEof`, NOT the first field — the gap before a first field is the enclosing rule's, and capturing there broke `HxWhileStmt`'s first-token claim at macro time), one predicate for synth / converter default / parse capture / writer seat; captured with `collectTrailingBlock` (block comments only, a miss rewinds so the enclosing rule still sees it), re-emitted with `trailingCommentDocVerbatim` ahead of the lead's own spacing. A LINE comment there stays uncaptured and refused, as for `BeforeTrail`. Side effect, kept: `function bar(): /* r */ Void {}` (a `HxInlineBlockCommentGapTest` slot-less entry) now round-trips as `function bar():Void /* r */ {}` — the comment after `:` was stashed by the lead commit into `pendingTrivia` and dropped; the body's `BeforeLeading` scan drains that stash, so it is now KEPT, after the type. Blast: `hxq fmt --list` 0 of 1999 over anyparse `src`/`test`, and 0 of 841 over the client corpus `src` on both engines (no client file holds any of the shapes) — branch `fix/writer-comment-fidelity`
- found, not changed (other gaps, same family, each still a comment-loss refusal on base and here): a kw-to-paren gap (`if /* c */ (a)`, `while`, `switch`, `for`, `cast /* c */ (`, `function f /* c */ ()`) — the gap before a FIRST field belongs to the enclosing kw branch, which has no slot; a gap before a kw that is not a lead (`for (k /* c */ in m)`); an arrow function type (`Int /* c */ -> Void`, the Pratt operator path); a LINE comment before a lead (`var x // c` + `= 1`); a function EXPRESSION's expression body (`function():Int /* c */ return 1;`, the `@:absentOn` body has no `BeforeLeading` slot — its block-body twin is kept but moved INSIDE the block as the first statement's leading comment). Mis-placed, not dropped: `var x /* c */;` and `var x = 1 /* d */;` move the comment after the `;` onto its own line. Also seen while editing: the grammar accepts `} else if (c)` + newline + `else if (d) …` as `IfStmt(c, OrphanElseStmt(…))`, so a `patch` that duplicated an `else if` line wrote invalid Haxe and reported success — branch `fix/writer-comment-fidelity`
- a wildcard import was to END every `import-order` run (both kinds — `import p.*;` and `import p.C.*;` — "bind names the ordering cannot see") → most bind names that provably decide nothing against their neighbours; the run admits one as an ordinary member (sorted by its full text, `*` below the dot and every letter) exactly when `WildcardImportGate` proves no permutation can change what a simple name means, and the insert seat reads the same runs (`ImportOrder.runsIn`). Precedence measured on 4.3.7, `--interp` and `-js` agreeing in every row — two namespaces, a value outranking a type of the same name in either order, so only same-namespace pairs can be order-dependent — branch `feat/import-order-wildcards`:

  | pair (both statement orders) | winner | order matters |
  |---|---|---|
  | `import p.*;` (module `p.T`) vs `import q.T;` | `q.T`, explicit, either order | no |
  | `import p.*;` vs `import q.*;`, both declaring `T` | the LAST | yes |
  | `import p.*;` vs a SECONDARY type `p.M.MSub` / a module-level field / an enum constructor | not bound (`Type not found` / `Unknown identifier`) | — |
  | `import p.C.*;` vs `import q.D.f;` (static `f` in both) | the LAST | yes |
  | `import p.C.*;` vs `import r.E.*;` (static `f` in both) | the LAST | yes |
  | `import p.K.*;` (static `modfn`) vs `import v.Fns;` (module-level `function modfn`) | the LAST | yes |
  | `import p.K.*;` vs `import v.Fns.modfn;` (explicit module-field import) | the LAST | yes |
  | `import p.C.*;` (static `Foo`) vs `import q.Foo;` / `import q.*;` (type `Foo`), expression position | the static, either order; type position: the type | no |
  | `import p.K.*;` (static `Red`) vs `import p.Col;` (enum ctor `Red`) | the constructor, either order | no |
  | `import p.K2.*;` (static `Blue`) vs `import p.Ab;` (enum abstract value `Blue`) | the abstract value, either order | no |
  | `import p.Col.*;` (ctor `Red`) vs `import p.K.*;` (static `Red`) | the LAST | yes |
  | `import p.Sub.*;` with `Sub extends Base` | `Sub`'s own statics only — `Base`'s are not bound | — |
  | `import p.C.*;` | binds every static, a `private` one too (`Cannot access private field`), never `C` itself or `p.C.CSub`; `import p.M.*;` = the statics of module `p.M`'s main type, not its module-level fields | — |
  | ambient `import.hx` `import q.T;` vs own `import p.*;` | `q.T` (explicit outranks the wildcard across the boundary) | outside the block |
  | ambient `import p.*;` vs same-package `app.T` | `p.T` — a wildcard outranks the same package | outside the block |
  | own `import p.*;` vs a type `T` the module itself declares | the module's own | outside the block |
  | own `import p.*;` vs ambient `import q.*;` / own `import p.C.*;` vs ambient `import r.E.*;` or `import q.D.f;` | the OWN statement (it comes later) | outside the block |
  | own `import p.C.*;` vs the class's own static `f` / a local `f` | the class's own / the local | outside the block |

  A statement outside the block keeps its position against every member under any permutation of the block, so the last five rows are no question the gate asks. Positive whitelist: an unindexed package or type, a `typedef`, a type with `@:build` / `@:autoBuild` / any supertype or interface, and — for a field wildcard — any explicit member whose VALUE names the index cannot enumerate (unindexed module, unparseable source, unresolved field import) keeps the wildcard a boundary — branch `feat/import-order-wildcards`
- a wildcard member below a wedged `using` was to be lifted into the merged block like any line → its order against a `using` was not measured, so the merge leaves it below the group (sound: its order against the imports that move up is free by the gate, against everything above unchanged), and one BETWEEN two wedged groups refuses the merge — branch `feat/import-order-wildcards`
- found WRONG, not changed: `import-order`'s same-simple-name refusal between two PLAIN imports reads only TYPE names, but `import v.Fns;` and `import v.Fns2;` each declaring a module-level `function modfn()` resolve `modfn` to the LAST of them (measured), so a reorder of two such module imports silently rebinds a value; the wildcard gate reads module-level fields (`WildcardImportGate.moduleFieldsOf`), the plain-pair refusal does not — branch `feat/import-order-wildcards`
- a `Map` key-value loop's discarded key was never dropped (`redundant-map-iter-key`, `unused-loop-binder`): a map's `keyValueIterator` is `MapKeyValueIterator` (`keys()` + `map.get(key)` per step), so it re-reads each value BY KEY while `iterator()` walks the values — an entry the body removes reads `null` through one and the stale value through the other, and a value the body replaces reads new through one and old through the other (measured: `--interp` `[a,c,b]` vs `[a,c,null]` after a remove, `[a,c,b]` vs `[a,c,X]` after `m[last] = 'X'`; hxcpp `[b,c,a]` vs `[b,c,null]` / `[b,c,X]`; js agrees because both its iterators are live). For a map NOTHING changes while the loop runs, the two yield the same values in the same order on every target measured (scratch program, Haxe 4.3.7, the haxelib `hxcpp` git checkout on this machine; each map with 100-300 entries, removals before the loop to leave holes, `__proto__`/numeric-string keys in the string maps, enum keys with arguments; `fails=0` on each):

  | container (static type) | `--interp` | js (node, ES5 and `-D js-es=3`) | hxcpp (macOS arm64) |
  |---|---|---|---|
  | `Map<Int, V>` / `Map<String, V>` / `Map<Obj, V>` / `Map<EnumValue, V>` (the `haxe.ds.Map` abstract) | equal | equal | equal |
  | `IntMap` / `StringMap` / `ObjectMap` / `EnumValueMap` | equal | equal | equal |
  | `BalancedTree` | equal | equal | equal |
  | empty `Map` | equal | equal | equal |
  | `haxe.Constraints.IMap` (interface) | equal | equal | equal — but a project class may implement it, so NOT admitted |
  | `WeakMap` | not measured — both iterators are `null` off hxcpp, so NOT admitted | | |

  → `RefShape.keyedIterationTypes` (Map, IntMap, StringMap, ObjectMap, EnumValueMap, BalancedTree, each with its standard path) and `NominalTypes.keyedIterationContainer`: the same resolution gates as `valueIterationProvable` (a std type no project type, import or alias rebinds; not a local written in its scope), plus a veto when a type outside the standard library extends a class a value of the iterable's type may be (a subclass may override `iterator()`): the type itself, and for the `Map` abstract `IntMap`/`StringMap`/`ObjectMap` (its `@:from` conversions) and `EnumValueMap` (`RefShape.keyedIterationHolders`). First written as a veto over EVERY keyed type, it refused the client's loop: tink_macro's `TypeMap extends BalancedTree`, a class no `Map` value is (`testASubclassOfAClassNoMapHoldsVetoesNothing`). Such a loop is `Keyed` (`ValueIterationProof.kindOf`), and its fix asks `MemberReach.mayMutateNamed` over the loop BODY — any answer but `Proven` keeps today's behaviour (`redundant-map-iter-key` report-only with the reach's reason, `unused-loop-binder` renames the key to `_`). The report never asks the reach (it builds a call graph), so a `Keyed` finding's message describes the drop as conditional instead of prescribing `for (v in …)`. hl, neko, php, python, lua, jvm not measured — a target whose `Map` iterators differ would need its own row
- what `MemberReach` needed to answer a MAP question (it only knew arrays): (1) the member's own methods — `arrayTyped: Bool` became `OwnMethods { reads, changes }` (`MemberTouchScan`), the array lists unchanged, and a member DECLARED `Map`/`IntMap`/… under a name no project type rebinds gets `ExecutionShape.nonMutatingMapMethods` (`get`, `exists`, `keys`, `iterator`, `keyValueIterator`, `copy`, `toString`) and `mutatingMapMethods` (`set`, `remove`, `clear`, `arrayWrite`) — every other method is still a change AND an escape (a static extension may store the map); `m[k] = v` is the index write it always was. (2) A LOCAL map (`localMutation(…, owns)`, opt-in, the array question unchanged): the region's own touches of it by name count (`MemberTouchScan.localTouch` — the array rules refuse those before asking, the map rule does not), and a local map that escaped is `Unknown(Escape)` rather than the array alias analysis, which does not know `set` changes a map. (3) `new Map()` and the other map types are fresh initializers (`isFresh`). (4) Under the compiler facts: an inlined abstract method reads its `this` through an identity cast (`Map.get` is `(cast this).get(key)`), which the facts walk recorded as a `value` — an escape — at EVERY map access; an unchecked cast to the type the value already has now passes its use through (`TypedFactsWalk.visit`), so `_byId[id]` reads `call:get`, `_byId[id] = v` `call:set`. And the loop's own iteration, which the facts splice into the body region (`for` lowered to `keyValueIterator()`/`hasNext()`/`next()`, its site the whole statement), walked into the library: `ObjectMap.keys` is a body-less extern on `--interp`, untyped on hxcpp, and admitted every project function. A standard map's own methods now run no project code (`ReachGraph.runsNoUserCode`, the array rule extended; vetoed for a map type a project class extends, since `BalancedTree.get` calls an overridable `compare`), so the splice is harmless and the walk stops there — branch `feat/map-value-iteration`
- refusals pinned: a body that removes an entry, sets an existing key (`m[k] = v` or `m.set`), calls a method that clears the map (directly, or a closure holding a local map), changes a local map through the static another function stored it in; a reassigned local map; a project `Map` class and a project subclass of `IntMap`; a field map in a run with no declared project roots (`OutOfScope`). E2E `FactsFixGateE2ETest.testAMapTheLoopLeavesUnchangedLosesItsKey*`: the same fixture under the facts as the truth and from the syntax alone, three provable loops rewritten (two field, one local; both rules), four refused loops each of which prints differently if rewritten — branch `feat/map-value-iteration`
- client after this slice (`src/fs/DiskSystemLinksRegistry.hx:236`, `for (_ => items in _itemsByCloudId)`, oracle on, the truth): now a `Keyed` finding, still declined — `Escape` at `:240`, `_itemsByCloudId.count()`: `count` is `Lambda.count` through `using Lambda`, a static extension the map is HANDED to, which the whitelist must read as an escape (an extension may store it). Proving it needs a library callee that provably keeps no argument (`Lambda.count` only iterates its `Iterable` and calls the absent `pred`) — not built. Report-only counts over the client corpus `src` unchanged: `redundant-map-iter-key` 1 → 1 (message now the conditional one), `unused-loop-binder` 0 → 0 — branch `feat/map-value-iteration`
- found WRONG, not changed (FIXED by branch `fix/import-order-module-fields`, below): `import-order`'s same-simple-name refusal between two PLAIN imports reads only TYPE names, but `import v.Fns;` and `import v.Fns2;` each declaring a module-level `function modfn()` resolve `modfn` to the LAST of them (measured), so a reorder of two such module imports silently rebinds a value; the wildcard gate reads module-level fields (`WildcardImportGate.moduleFieldsOf`), the plain-pair refusal does not — branch `feat/import-order-wildcards`
- the names a PLAIN import binds were read as its module's TYPE names (`ImportBlockOrder.boundNames`), and `WildcardImportGate` kept a second, partial reader of module-level fields → ONE reader, `ImportBindings`, lists what any import-family line binds by RANK, and `import-order` (plain pairs, the wildcard gate, the `using` wedge), `unused-import`, `redundant-import`, `hoist-common-import` and `import-outside-guard` all ask it. Measured on 4.3.7, `--interp` and `-js` agreeing in every row (each pair in both statement orders) — branch `fix/import-order-module-fields`:

  | pair | winner | order matters |
  |---|---|---|
  | `import v.Fns;` vs `import v.Fns2;`, each a module-level `function modfn` / `var` / `final` of one name | the LAST | yes |
  | `import v.Fns;` (module-level `modfn`) vs `import q.D.modfn;` (static field import) / `import v.Fns2.modfn;` | the LAST | yes |
  | `import p.Col;` vs `import p.Col2;`, both declaring the constructor `Red` | the LAST | yes |
  | `import p.Ab;` vs `import p.Ab2;` (enum-abstract values `Blue`); `import p.Ab;` vs `import p.Col;` (value vs constructor `Red`) | the LAST | yes |
  | `import p.M;` (SECONDARY enum `MSub.Red`) vs `import p.Col;` | the LAST — a module import binds its secondary enum's constructors | yes |
  | `import p.TAlias;` (`typedef TAlias = Col2`) / `import p.TNull;` (`typedef TNull = Null<Col2>`) / a typedef of that typedef, vs `import p.Col;` | the LAST — a typedef binds its target's constructors, through `Null<T>` too | yes |
  | `import p.Col;` (constructor `Red`) vs `import v.Fns;` (module-level `Red`) / `import q.D.Red;` | the constructor, either order | no |
  | `import p.Ab;` (value `Blue`) vs `import q.D.Blue;` / a module-level `Red` | the abstract value, either order | no |
  | `import p.Col.Red;` (field import of a constructor) vs `import q.D.Red;` | the LAST | yes |
  | `import p.Col.Red;` vs `import p.Col2;` | `Col2.Red`, either order | no |
  | `import v.Fns;` — main class `Fns`'s static `sfn` | not bound (`Unknown identifier`) | — |
  | `import p.Pm;` — a PRIVATE secondary `enum PE { Red; }` | not bound | — |
  | `import p.Ab3;` — enum abstract's `static function Red` / `static var` | not bound (its values only) | — |
  | `import p.Pl;` — a plain abstract's `static var Red` | not bound | — |
  | `@:enum abstract` (legacy) | binds its values like `enum abstract` | — |
  | `using v.Fns;` | binds NO module-level field (`Unknown identifier`); `using p.Col;` binds `Red` and the LAST wins against `import p.Col2;` | — |
  | ambient `import.hx` statement vs own import of the same rank | the OWN (ambient reads as written ahead of every own statement); the rank order holds across the boundary | — |
  | same package, NO import: module-level field of `p.PFns`, constructor of `p.Col`, of a secondary `p.M.MSub` | none bound (`Unknown identifier`) — a same-package import is load-bearing for values | — |

  Ranks: explicit TYPES; package-wildcard module names; TYPE VALUES (constructors / enum-abstract values of the non-private types a line imports, typedefs followed); FIELD VALUES (module-level fields of a module import, a field import's leaf, a field wildcard's set). A higher rank wins in either order; within one the LAST wins; so two lines' order matters only for a name both bind at one rank (`ImportBindings.collision`). Positive whitelist: a set the index cannot list — an enum / abstract carrying a build macro, a typedef whose target does not resolve or is a nullable wrapper, an unparseable module, a module the index never saw — collides with any line binding a name at its rank; two unlisted sets do not (the residual, the pre-index reading — every pair of library imports would refuse otherwise), and an unindexed module's only TYPE is its last segment. A legacy `@:enum abstract` projects as a plain abstract, so a plain abstract's instance fields are read as values (costs refusals, never a rewrite)
- `unused-import` kept a plain import alive by its types and its MAIN enum's constructors only → by every VALUE it binds (`valuesKeepAlive`): a secondary enum's constructors, a typedef target's, a legacy abstract's values, and a MODULE-LEVEL field — `modfn()` alone kept no import, so `--fix` deleted `import v.Fns;` (a build break), and beside `import v.Fns2;` deleted the LAST binder (a silent rebind); a known module whose values cannot be listed is an `Info` — branch `fix/import-order-module-fields`
- `redundant-import` deleted `import p.M.MSub;` beside `import p.M;` on its TYPE name alone → a third line binding one of `MSub`'s constructors (`import p.Col;` between them) vetoes, since the deletion hands it `Red`; the AMBIENT arm keeps any statement binding a value (its identity argument is per type name; own `import p.Col2; import p.Col;` with an ambient `import p.Col;` — deleting the own copy hands `Red` to `Col2`) — branch `fix/import-order-module-fields`
- `hoist-common-import` judged a candidate by its TYPE names → a statement binding any value is no candidate: the ambient copy outranks a module's own field imports / field wildcards with its constructors in either order. client: 263 → 248 findings (`openfl.net.URLRequestMethod`, and `openfl.display.MovieClip` through the residual below) — branch `fix/import-order-module-fields`
- `import-outside-guard` claimed import positions "carry no resolution order" and moved a stranded `using` below every guarded import → a move flipping two lines that bind one name at one rank is refused (a stranded `using p.Col;` over a guarded `import p.Col2;` rebinds `Red`; a `using a.T` over `import b.T` rebinds the TYPE `T` — that half predates this branch); an alias in a flipped pair refuses — branch `fix/import-order-module-fields`
- found WRONG, not changed: the insert seat (`ImportOrder.insertOffset`) places a fresh import by its TYPE simple name only, so a fresh line binding a constructor or module-level field another import already binds may land AFTER it (rebinding that value) — and a fresh higher-rank binder (an enum beside a field import of the same name) rebinds wherever it lands; the seat has no refusal path, so the cure is the inserting callers', not a slot — branch `fix/import-order-module-fields`
- found WRONG, not changed (residual over-refusal, measured on the client corpus): the resolution index holds no target-specific std package (`cpp.*`, `flash.*`), so `cpp.vm.Gc` is an unindexed module and openfl's `#if !flash class X … #else typedef X = flash.X; #end` idiom leaves every openfl module's constructor set UNLISTED — beside an enum-abstract import the block refuses (2 of the client's 33 `import-order` findings, 31 still fixed; base fixed 33), and an unused openfl import would be an `Info`. Precision needs the target std indexed or branch-aware typedef reading — branch `fix/import-order-module-fields`
- found WRONG, not changed: `lime.system.System`'s secondary `#if (haxe_ver >= 4.0) private enum #else @:enum private #end abstract SystemDirectory` is indexed as NON-private (the `private` sits in the conditional prefix), so its values keep an unused `import lime.system.System;` alive whenever a string spells one (`'%DOCUMENTS%'`) — a missed finding (client `HookEngine.hx`, guarded `Info`), the safe direction — branch `fix/import-order-module-fields`
- a value handed to a method as an argument being an escape whatever the method does with it (client `src/fs/DiskSystemLinksRegistry.hx:240`, `_itemsByCloudId.count()` — `Lambda.count` through `using Lambda` — declined the `:236` loop as "shared") → under the truth an argument of a call of a DECLARED method (`FStatic`, `FInstance`; not a `dynamic` method, a variable of a function type, a structure's or a dynamic receiver's field, `Reflect`/`Type`/`Syntax`) is that method's parameter, and the read does what the code it is handed to does with it. The facts walk records the argument as a `value` use naming the parameter (`TypedFactsWalk.Argument`, `"ag"`/`"aa"`/`"ai"`, `FieldFact.argument`) — so a reader that does not follow it reads the escape it always did — and every parameter is a local of its node (`_aliases`), whose reads' uses each node line records per parameter (`"pu"`, `FactNode.paramUses`, unioned over the configurations; null when one recorded none or two gave different parameters): S26's alias machinery, reads from a nested function as captures, stores into another local followed through its reads. `ArgumentUses` (once per argument per `FactsView`, dropped on `forget`) closes over the hand-offs: the uses of every parameter the value reaches, a parameter handed on adding the uses of the one it is handed to, a recursion adding nothing (a parameter answered once). `MemberTouchScan.classifyTyped` reads each such use as a read of its own (`classifyUse`: iteration, index, comparison, member read, the container's own readers are nothing; its own changers and element/member writes touch at the call site; a value — stored, returned, thrown, captured, handed to anything the facts do not follow — escapes). A POSITIVE list of the methods answered for: declared with a body (`method`/`inline`), no overload, no pasted target code on the field or its type, in a class or an abstract's implementation every configuration types alike and none as an extern, whose node — and every function nested in it — carries no marker but `inline-site-unknown` and no target-language code (which may name the parameter in a text no read records), with one parameter list. A call on an instance may run the method of every subtype of the declaring type, and each class a subtype inherits it from (an interface's implementation may come from a superclass outside it); an interface declares and runs nothing. Anything else is null — the escape. Generic methods need nothing more: the uses are of the parameter, whatever its type arguments. The claim is about the CONTAINER handed: a callback parameter (`count`'s `pred`) called with its elements is a `value` use of THAT parameter only, and what an element is handed to is not asked. A rest parameter takes its arguments into an array the compiler builds, so an argument at or past one stays a plain value. Without the truth nothing changes (`listed=false` keeps the escape, pinned) — branch `facts/s31`
- two casts the argument meets on its way (measured): `Lambda.count(m)` with `m:Map<K, V>` is typed `Lambda.count(cast m)` to `Iterable<V>`, and a `Map` PARAMETER iterated in the callee is spliced into `Map.iterator` as `(cast m : IMap<K, V>).iterator()`. An argument now passes through any unchecked cast (`TCast(_, null)`: the object is the one handed, and its uses name what is done to it by name), and an unchecked cast from an abstract to the type it wraps is an identity like a cast to the value's own type (`TypedFactsWalk.wrapped`, the abstract's declared type at its arguments — `TypeTools.followWithAbstracts` resolves `@:multiType` `Map<String, Int>` to `StringMap<Int>`, not `IMap`, so it cannot answer). A side effect of parameters being locals: an assignment statement storing a field in a parameter (`p = items;`) now follows `p`'s reads, as one into a `var` did — branch `facts/s31`
- fixtures re-cut: S26's `keep(a:Array<Int>):Void {}` stood for "an argument escapes" and now keeps nothing; it stores the argument in a static instead, as the escape it pins. `M-FACTS-IDENTITY-CAST-VALUE` re-cut on the widened condition (it now drops only the own-type comparison); `M-TOUCH-TYPED-CALL` / `M-TOUCH-TYPED-VALUE` re-addressed to `classifyUse`, where their fragments moved; all KILLED again. Observed, not changed: with `tools/mutation-check.sh`'s fixture cache on (`--jobs 3`) each track cutting `TypedFactsWalk` also failed `FactsFixGateE2ETest.testAMapTheLoopLeavesUnchangedLosesItsKeyUnderTheTruth` as collateral, which the same cut's own `test.js` passes, and so does the track under `APQ_MUTATION_NO_FIXTURE_CACHE=1` (server on or off, `--jobs` 1-2): a collateral reading of the cache or of concurrency, unattributed — branch `facts/s31`
- client after this slice (`src/fs/DiskSystemLinksRegistry.hx:236`, oracle on, the truth): `for (_ => items in _itemsByCloudId)` → `for (items in _itemsByCloudId)`; `Lambda.count`'s `it` is only `it.iterator()`, a reader of the map's own — branch `facts/s31`
- `MemberTouchScan.classifyUse` read every use it did not name as harmless (`case _`: no touch, no escape) — reached today only by `index`/`member`/`compare`/`iter`/`update`, since `typedShape` sends a field read of any other use to its syntax and the argument branch of `classifyTyped` escaped a parameter use outside `TYPED_USES` itself, but a negative default all the same → a POSITIVE list: those five are nothing, `call`/`elemWrite`/`memberWrite`/`value` answer as before, and any other code — one a grown facts producer writes, an empty one (`paramUsesOf` reads a missing `u` as `''`), none — touches and escapes. The argument branch's own `TYPED_USES` guard is gone: `classifyUse` is the one decider, so restoring the old default now lets a renamed parameter use keep nothing (`M-TOUCH-USE-UNKNOWN`) — branch `fix/classify-use-default`
- `FactsView.unplaced` was a NEGATIVE list (`UNPLACED`: `macro-expansion`, `inline-site-unknown`, `stale-foreign`): a node marker it did not list left the node faceted, its facts read as placed → a positive list of the markers that leave every fact placed: a spliced `Reflect`/`Type` body's (`reflection-inlined`, `reflection-unattributed`, `reflection-from:`, which `blindIn` answers for), and under the truth `inline-site-unknown` and `macro-expansion`; any other keeps the body's syntax. Same answer for every marker the producer writes (`M-FACTS-REACH-SPLICE` re-addressed to the new `return`, same cut) — branch `fix/classify-use-default`
- `CallGraphFacts.field` recorded no unresolved access for a field fact whose access it did not name (`case _: false`) → `FInstance`/`FStatic`/`FClosure`/`FEnum` are resolved, `FDynamic`/`FAnon` ask as before, and any other access is an unresolved access, as a dynamic receiver's. `CallGraphFacts.call` already sent an unknown call access to `Unseen` — branch `fix/classify-use-default`
- `CompilerFacts.add` skipped a line of a record kind it did not know → a dump holding any record but `facts`/`end`/`node`/`type`/`src`/`file` (`RECORD_KINDS`) is dropped whole, with its reason: such a record may say what a fact it does read leaves out — branch `fix/classify-use-default`
- decided per key, NOT changed: an unknown KEY inside a known record is not checked. Producer and reader are compiled from one tree in one engine build (`TypedFactsProbe.compileArgs` puts the engine's own hook after the project's class paths; facts are never kept across runs), so a key no reader reads is a fact nothing consumes, and checking would cost a key walk per fact. The values readers DO consume are whitelisted where read — a use (`classifyUse`, `typedShape`), a field access (`TYPED_ACCESSES`, `CallGraphFacts.field`), a call access (`CallGraphFacts.call`, `ArgumentUses.runs`), a marker (`unplaced`, `ArgumentUses.whole`, `NullGuardedCode.READABLE_BODY`, `FactsProvenance.factsMatch`), a field or type kind (`ArgumentUses.BODIED_KINDS`/`BODIED_TYPES`) — and a MISSING key reads as the decline: no `pu` is no parameter use (null), a `u` missing from a parameter use escapes, from a field read sends its function to the syntax, and an argument missing any of `ag`/`aa`/`ai` stays a plain `value`, an escape — branch `fix/classify-use-default`
- found WRONG, fixed by the `FactMarkers` bullet below: other readers of the node markers were still NEGATIVE lists — `FactsEscapes.escapesOf`, `FactsMethodValues` (method values), `FactsProvenance.factsOnText`, `CompilerFacts.within` and `FunctionValueTypes` decline only on the markers they name (`stale-foreign`, `reflection-inlined`, `macro-expansion`, `inline-site-unknown`), so a marker a grown producer writes passes there; and `FactsEscapes.constructorEscapes` reads a constructor type that is no function (`case _: true`) as holding nothing, `Unknown`/`Parameter`/`Structure` included where only `Named` (an argument-less constructor) is. Unreachable from today's producer — every marker it writes is named, a constructor's type is a function or its enum — but a new marker or type shape needs those readers reviewed with it — branch `fix/classify-use-default`
- tests: `testAUseTheFactsReaderDoesNotKnowIsAnEscapeUnderTheTruth` pins `classifyUse` on unknown codes (RED on the old default) and on every known one, and through the facts — `sum`'s every use renamed to `future` in its node record — that the argument escapes (green on the old code too, behind the guard this slice dropped); the marker, field-access and record-kind tests are RED on the old code. The node records are rewritten in the table (`rewrittenTruth`, `CompilerFacts._nodeLines`) before the question, which is what a producer grown past the reader hands it — branch `fix/classify-use-default`
- `OrphanElseStmt` was to be restricted in the GRAMMAR (or by a validator inside the parse) to
  `#if` seams → a PEG alternative cannot see the statement in front of it; a parse-time validator
  needs a second, span-carrying parse inside every `writeRoundTrip` (the Trivia tree has no spans),
  would turn a mid-edit file unreadable for every read-only tool, and the compiler's own verdict
  is define-dependent (`#if a if (c) f(); #end else g();` compiles only under `-D a`). The
  predicate (`OrphanContinuation`) instead runs at the write gate and compares the result to its
  input — branch `fix/orphan-else-leniency`
- `fmt` was to refuse an input that already holds an unjustified orphan `else` → the writer
  re-emits the tree it parsed, so the count cannot grow and the refusal would only make the file
  unformattable; it is formatted as it stands, and the gate refuses only a GROWING count —
  branch `fix/orphan-else-leniency`
- found WRONG, not changed: `HxCondBlockCloseRaw`'s doc says the `else if` after a
  block-closing region's `}` "reaches `HxStatement.OrphanElseStmt`"; it binds to the enclosing
  `if`'s own else slot (`IfStmt … (BlockStmt … CondSpliceBlockClose) (IfStmt …)`), so that shape
  produces no orphan at all — branch `fix/orphan-else-leniency`
- the suite's 1.6-core utilisation (`suite-shard.sh -n 8` 297–336 s wall, ~540 s CPU) read as load or a lock → it was ONE class: per-class timing (`APQ_TEST_TIMING`, new) measured `unit.query.MemberReachFactsTest` at 271 s of a 470 s suite (229 tests, 1007 fixture compiles, 265 s of them in `haxe`), so its shard ran 297 s while the other seven finished in 9–46 s. A class is the unit no LPT split can cut, so `apq shard-plan` now deals a class heavier than a shard's share as `#i/k` slices of its sorted test names (`ShardFilter`), bounded by the shard and test counts, never a pinned class, weights from the last green run (`--weights bin/.suite-timings.tsv`, the built-in table refreshed). `-n 8`: 297.2 s → 73.5 s (load 9→17-22; 901 classes, 16132 tests, 0 failures) — branch `perf/profile-and-optimize`
- the suite's fixture compiles replayed only inside a mutation run (`FixtureCompileCache`, per workroot), on the premise that a kept cache must survive a compiler upgrade → the key already holds every input by content (the probe macros' own source included), so what a kept cache adds is only the install outliving a run: the stamp now names the binary by path, `-version`, size and mtime (`tools/fixture-cache.sh`, shared by both runners), entries are gzipped (240 KB → ~30 KB; 31 MB for the whole suite) and renewed on every hit, and one unused for 7 days is dropped. `suite-shard.sh` keeps it in `~/.cache/anyparse/fixture-cache` (`APQ_SUITE_NO_FIXTURE_CACHE=1` opts out). Kept, it met a replay-fidelity hole a one-run cache had hidden: a compile writing into its cwd (`OracleRunMemoTest`'s compile counter appends to `compiles.log` there while the baseline compile beside it appends too) was replayed as the whole recorded file, losing the other writer's line; such a compile is no longer recorded (layout 3, arm `M-FIXTURE-CACHE-CWD-WRITE`). Warm, 1070 of 1127 probe compiles replay; `-n 8` 73.3 s → 34.0 s, `-n 4` 61.4 s, in-suite total 470 s → 244 s (load 7–9) — branch `perf/profile-and-optimize`
- the coordinator's report "with the fixture cache on, every `TypedFactsWalk` track also fails `FactsFixGateE2ETest.testAMapTheLoopLeavesUnchangedLosesItsKeyUnderTheTruth`" read as cache-key staleness → not the cache: every compile of that test was a `pass` (no record, no replay), and a bare `exec haxe` bash wrapper first on the PATH reproduced it exactly (3 failures against 1 without a wrapper). `StdResolver` finds the std beside `which haxe`, symlinks resolved; with any wrapper there it has none, falls to `KNOWN_LOCATIONS`, and on this machine its first entry `/usr/local/lib/haxe/std` is ANOTHER Haxe install — so every shimmed run (mutation tracks, and `suite-shard.sh` since it kept the cache) indexed a different std than a plain run. The runners now name the plain run's std through `HAXE_STD_PATH` for the test process (`fc_std_injection`, the resolver's first candidate, computed by `siblingStdOf`'s rule) and the shim strips it before the compiler or the cache sees it: the reproduction is back to the one real kill, the suite green at 16134 tests. Left open: `KNOWN_LOCATIONS` preferring `/usr/local` over the Homebrew prefix is the engine-side hole a plain run could fall into too — branch `perf/profile-and-optimize`
- client `lint src/editor/stage/grid/MeshScale.hx --rule prefer-keyvalue-loop --fix` (13 builds, the truth) read as "the compiles got slow" → the analysis after them was 80% of the run: profiled 533 s, of which `TypeRefIndex.declaringFiles` (a scan of every type of every file per name lookup, reached through `ReachProject.siteOf`) 140 s self, `ValueCarriers.valueTypes` + `ReachGraph.runtimeTypes` `Array.contains` dedupes over the escaped types 71 s, `FunctionValueTypes.mayRun` re-parsing facts type texts per escaped function type 72 s, `OracleRunMemo.fingerprints` walking the client root once per build 43 s. Each replaced by a table, a set beside the list, a per-text / per-type memo, or one walk per batch — iteration orders kept, every input of a memo its key, the fix output and every message byte-identical. Unprofiled, same command: 91bfa483 521 s → 170 s (load 5–13); on 0c152f67 (S31) 598 s → 178 s; e7f5f974 (before S18) 407 s. Reach report-only asks nothing (9.4 s, verdicts from the persisted cache). The questions (traced): 3 per run, each first answered by syntax in ~10 ms as `Unknown(Reification)` and escalated (S23) — the escalation builds the configured analysis once, 10.4 s (the defines probes, 13 compiles started only then), and the one question that ends `Ambiguous(License)` costs 65 s, the others 0.1 and 3.1 s. Not measurable: S31's `joinedParamUses` (0.3 s). Left, by size: waiting on the facts compiles (13 × 35–45 s, the facts macro costs ~3.5× a typecheck: anyparse 114 s against 43 s; `-D eval-times` puts `Context.getPosInfos` 12.9 M calls and `typeString` 5 M calls on top), the defines probes not overlapping them (~9 s wall), and two rounds of 13 verification typechecks (~14 s) — branch `perf/profile-and-optimize`
- memo guards kept though no test can kill them, each the invariant's own statement (equivalent mutants, `MemberReach` today never asks before it reads through the facts): `ReachProject.declarationsByName`'s index check (`readThrough` replaces the index in the constructor, before any question), `TypeRefIndex.named`'s once-per-file name dedupe (the index holds one type per name per file, so `declaringFiles`' `filter` semantics never see a second), `FunctionValueTypes.meetsEscaped`'s key (its one varying input; the escaped list is read once)
- `HxCondBlockCloseRaw`'s doc said the `else if` after a block-closing region's `}` "reaches
  `HxStatement.OrphanElseStmt`" → it binds to the enclosing `if`'s own else slot (`IfStmt …
  (BlockStmt … CondSpliceBlockClose) (IfStmt …)`), so that shape produces no orphan at all; the
  doc now says so — branch `fix/orphan-else-leniency`
- `editKeepingCanonical`'s fallback for a drifted source was believed to need only the bare splice
  ("reformatting a file the user never formatted is not a span-splice op's business") → it also
  threw away every refusal `canonicalize` asks of the EDIT, so `extract-superclass` on a file one
  stray space from canonical welded two comments its canonical twin refused. Every edit question
  (emptied slot, split doc, welded or hoisted comment, stranded `else`) is a fact about source,
  edits and splice, and is now asked of the fallback splice too; only the writer's own questions
  (comment loss in re-emission, convergence) have nothing to ask there. `extract-interface`'s one
  edit (` implements I`, zero-width, no newline) and `introduce-parameter-object`'s (non-empty
  replacements plus an EOF append) cannot trip any of them, so only `extract-superclass` was
  observably exposed — branch `fix/orphan-else-leniency`
- the node markers are read in ONE place: `FactMarkers.read` turns a marker's text into a `FactMarker` (`StaleForeign`, `InlineSite`, `MacroExpansion`, `ReflectionInlined`, `ReflectionUnattributed`, `ReflectionFrom(method)`) and any text the vocabulary lacks into `Unknown(text)`. Every reader that lets a marker through switches over the enum exhaustively (`FactMarkers.first` / `carries` with a value `switch`), so a constructor added to it is a compile error at each such reader until it decides; a reader that admits one marker only asks `match` of it (`ArgumentUses.whole`, `NullGuardedCode.parameterNeverCalls` — its `READABLE_BODY` gone — `MemberTouchScan.expansionCode`, `FactsView.splicedReflection`). `Unknown` declines everywhere: `FactsEscapes.escapesOf` and `FactsMethodValues.scan` refuse with `FactMarkers.unknownReason`, `FactsProvenance.factsOnText` is not the text, `CompilerFacts.within` is Unknown (null), `FunctionValueTypes.untypedStores` may store anything, `FunctionValueTypes.reflectiveConstructions` hands `ESCAPED_VALUES`, `FactsView.unplaced` keeps the syntax, and `FactsView.blindIn` — a negative reader the first report missed: a marker it did not name was no blind spot — answers `Unmodelled(file, span, 'facts marker <text>')`, as an expansion is a blind spot to a reader of the syntax. The producer (`TypedFactsWalk`, `CompilerFacts.materialize`) keeps writing the strings: it runs in the macro context. Answers are unchanged for every marker the producer writes, save the reason a node carrying two declining markers gives (`stale-foreign` and `reflection-inlined`; in `blindIn`, `macro-expansion` and `reflection-inlined`, `Reification` against `DynamicName`): the readers now meet them in the node's order. Arms re-cut onto the switches, same cuts: `M-FACTS-SITE-UNKNOWN`, `M-FACTS-SPLICED-WITHIN`, `M-FACTS-WITHIN-EXPANSION-NULL`, `M-FACTS-REACH-SPLICE`, `M-FACTS-TRUTH-SPLICE`, `M-FACTS-TRUTH-SPLICE-ALWAYS`, `M-FACTS-EXPANSION-PLACED`, `M-FACTS-UNPLACED-UNKNOWN`, `M-FACTS-TRUTH-REFLECTION-INLINED`, `M-FACTS-SPLICED-REFLECTION-READ`, `M-FACTS-REACH-MACRO`, `M-FACTS-EXPANSION-BLIND`, `M-METHODS-NATIVE-REFUSED` — branch `fix/classify-use-default`
- `FactsEscapes.constructorEscapes` read any constructor type that is no function as holding nothing (`case _: true`) → a positive list: `Named` — an argument-less constructor, typed as its enum — holds nothing; `Unknown`, `Parameter` and `Structure` refuse. Tested by typing `Mark.Plain` `?` in the table — branch `fix/classify-use-default`
- tests for the marker readers rewrite the table before the question (`MemberReachFactsTest.factsEdit`, applied by `withReach` right after the probe; `marking(id, marker)`), each on a node only that reader is asked of, so each restored negative list survives alone: `Main.other` off the region (`unplaced`), `Main.main` meeting it (`blindIn`), `lib.Text.keep` (`escapesOf`), `Third.calm` (`FactsMethodValues`), `Main.grow` asked of `FunctionValueTypes` itself, every `Hook` taken as escaped (`readStored`, `reflectiveConstructions`): in a question the escape set is read first and `escapesOf` already refuses such a node, so through `mayReach` the two `FunctionValueTypes` cases are defence in depth no reach answer can tell apart, `Util.other` under the hub build (`factsOnText`); `CompilerFacts.within` over a hand-written dump — branch `fix/classify-use-default`
- found WRONG, not changed: `FunctionValueTypes` reads a node marked `stale-foreign` as whole at both readers, and `reflectiveConstructions` skips a node whose facts cannot be placed at all (`table.node(id) == null`), where `untypedStores` declines on it: a store or a reflective construction lost with its file is missed. Kept as it was (`case StaleForeign: false`, `if (made == null) continue;`, both explicit now): every node of a file a `--fix` pass rewrote goes stale or null, so declining there costs every later fix in the run a function-value answer, a precision change not measured on the client corpus — branch `fix/classify-use-default`
- the facts macro read as "inherently ~3.5x a typecheck" → three avoidable costs under `-D eval-times` on a client build (48 s CPU, typecheck alone 6 s): `TypedFactsWalk.wrapped` called `a.get()` three times per call (47 k calls, 11% — each decodes the whole abstract), and a block asked the compiler for every other statement's position per spliced statement (`between`) plus once more per node in `holdsOwnCode` (6.9 M `getPosInfos`). An abstract's body is now read once per compile by path, a block's statement ranges once. Facts byte-identical on all 13 client builds and anyparse's own; per-build CPU 43.3–48.6 s → 30.7–36.1 s. Tried and dropped: an `ObjectMap` cache of each expression's own-code bounds (identity keys work in eval; identical facts, no gain) — branch `perf/round2`
- the define probes lazily at escalation → they ran alone after the facts (client 78.5–90 s of a 200 s run). An analysis with facts escalates on its first question (`escalation`), so `MemberReach.forRun` starts them just before waiting on the facts (`reachBuildsAhead`), only under `reachConfigurationsComplete` with an oracle; the first `reachBuilds` reads them; the run's first write drops unread ones and stops new starts, so a question after a write still probes the tree the write left. client `--fix` 200.6 s → 174.2 s (with the macro change; load 7–14), the probes at 0–18 s — branch `perf/round2`
- `StdResolver` stopping at the first `haxe` on PATH → a wrapper there (the fixture-cache shim, a version manager) has no std beside it and the fallback named `/usr/local` first: another install here, indexed by every shimmed run. It now takes the first `haxe` on PATH (`which -a`) with a std beside it — symlinks resolved, then the compiler's own search from its spelling (`../lib/haxe/std`, `../share/haxe/std`, `std`) — and lists `/opt/homebrew` before `/usr/local`. The runners' `HAXE_STD_PATH` workaround is gone: the `M-FACTS-READS` track no longer fails `FactsFixGateE2ETest`'s map tests as collateral — branch `perf/round2`
- after S30 (the `Ambiguous(License)` stop gone; client now declines on a build macro) the question costs ~22 s of a 150 s profiled run, spread thin; the largest owned item was `SubtypeGraph.eachSubtype` (12 s inclusive, `closure.contains` and `subtypeNames`/`subtypeFiles` `out.contains` quadratic over openfl's display-list subtypes, asked per question by `declaredValueTypes` and `ReachGraph.loadOverrides`): sets beside the lists, order kept. On S30 (942031af), with this branch's facts-macro and define-probe changes, client MeshScale `--fix` 163.0 s → 140.0 s, 905 → 790 s CPU (load 5–9), identical fix and messages; facts on S30's macro byte-identical on all 13 builds, 38.4–43.5 → 30.4–35.1 s CPU each. Next: `CompilerFacts`' cross-build dedupe `JSON.stringify`s every fact of every build (`fresh`, 7.3 s) — branch `perf/round2`
- "the cold full run is slow" read as one number → `APQ_TIMINGS=1` (new, stderr only, changes no finding or edit) prints a per-phase wall table and the process's own CPU. On the user's client working state (1058 files, 13 builds, `lint src --fix`, 13 edits over 4 passes; base `3917b37f`, 202–252 s wall, the spread is foreign load 11–40 on the 16-core box) one node thread does the analysis and the compilers run beside it: pass 1 ~60 s, each later pass ~15–20 s (the full-scope checks over all files: `field-init-at-declaration` 54 s summed over 4 passes, of it 26 s rebuilding the reach call graph per pass, `unused-private` 19 s, `prefer-static-extension` 12 s, `prefer-read-only-field` 8 s), library parse 10 s, the define probes waited on alone 11 s mid-pass-1, the risky phase 51–78 s (a 3-probe bisect of one `prefer-interpolation` revert, 39 compiles), the coverage probe 15 s, the safe-write net 13 s — branch `perf/round3`
- `MemberLookup`'s by-name questions (`supertypeDeclares`, `typeDeclaresMember`, `memberDeclarationsOf` and seven more) each scanning every type of every file → they read `TypeRefIndex.named`, the table round 1 built for `declaringFiles` (same index order, so every answer and its order are the same). `unused-private` on the client corpus 15.5 → 2.3 s over 4 passes; client `lint src --fix` 202 → 188 s wall, 148.6 → 134.2 s CPU in the node process, output identical — branch `perf/round3`
- `CompilerFacts.invalidate` dropping every made node for one rewritten file (`_nodeCache.clear()`) → a made node is a function of the texts its facts are placed in and of nothing else `invalidate` changes, so each records the files its making read (`indexOf`, `_madeFrom`) and a rewrite drops exactly those. Every `--fix` pass rewrites a few files, and the reach call graph re-made the whole table through `CallGraphFacts` each time. client `lint src --fix` 188 → 177 s wall, 134.2 → 123.4 s node CPU (`field-init-at-declaration` 46.7 → 35.9 s over 4 passes), output identical; arms `M-FACTS-MADE-FROM-ALL` / `-NONE` — branch `perf/round3`
- the define probes, started ahead only by the first reach question (`MemberReach.forRun` → `reachBuildsAhead`), read as "they overlap the facts" (round 2, measured on a `--rule prefer-keyvalue-loop` run whose first check asks) → on a full `--fix` the first question comes half-way through pass 1, after the facts are in, and the run waited on the probes alone (client 10.5 s). Started at the run's start beside the facts (tried) they took the cores the first pass and the facts needed and moved the converge end by nothing (106.6 → 106.7 s, the first index and library parse 11.2 → 18.9 s); started when a check first WAITS on the facts (`LintCommand.startBuildsWithFacts`, only in a run that started the facts early) they compile while the run is idle anyway: probe wait 10.5 → 1.0 s, converge end 106.6 → 104.1 s, total 177 → 176 s at load 30, output identical; arm `M-BUILDS-WITH-FACTS` — branch `perf/round3`
- the safe-write net's after-write typecheck compiled plainly → the risky phase asks for the coverage of exactly that tree next (`OracleCoverage.probedOnce`, a `-v` compile per configuration, which the memo can only answer from a `-v` run), so the net now compiles with `-v` (`CompilerOracle.typecheckAll(…, verbose)`; a red `-v` compile is compiled again plainly for its quote, as every remembered baseline is). client coverage probe 10.7 → 0.2 s, risky phase 53.4 → 42.8 s, `lint src --fix` 176 → 171 s, output identical; arm `M-SAFE-NET-PLAIN` — branch `perf/round3`
- the remaining profile of the reach call graph's builds read as "the graph is big" → per-call-site walks with list-membership dedupes: `CallGraph.virtualTargets` (`visited` / `result` `contains`, 7.2 s self), `FactMerge.closure` (`out.contains`, 3.0 s, behind `CompilerFacts.subtypesOf`), `FactsView.overriders` (every subtype's field list per call site, twice per site through `overrides`, 2.6 s), and `FieldWriteIndex.declsNamedIn` (every type of every file — through a COPY of the file list — per recorded write, 4 s). Sets beside the lists (order kept), the overriders settled once per `type`/`name` (a copy handed out; the table's types and subtype edges never change after it is built), the declarations read off `TypeRefIndex.named`. client `lint src --fix` 171 → 164 s wall, 125.1 → 111.3 s node CPU (`field-init-at-declaration` 35.9 → 21.0 s, `prefer-read-only-field` 8.2 → 1.3 s over 4 passes), output identical — branch `perf/round3`
- the `--fix` typechecks kept off every compilation server (README: one-second mtime granularity, stale null-safety diagnostics) → a run-scoped pool (`OracleServerPool`, user-approved): one `haxe --wait` per configuration, started when the facts compiles are in and warmed in the background, ended with the run as jobs of the process driver. Both hazards are designed out rather than accepted: every path the run may write whose TEXT moved since the server's last compile is `server/invalidate`d (content, never mtime), and only a warm green is believed — every warm red is compiled cold, the first configuration speculatively beside the warm compiles, since a rejected tree is rejected by the first configuration nearly always (client: all 13 red in each probe; a cold red alone 6–9 s against 11–14 s with 13 at once). Measured on the client corpus at load 30–60: a green covering compile 12 → 5 s, a red probe 11–14 → 9 s; risky phase round 1 45.9 → 37.1 s, round 2 (no edits, the same bisect) 35.6 → 30.9 s, output identical. Tried and dropped: `setPriority` on the later jobs of a first-failure batch, which under foreign load starves exactly the compiles a green verdict needs (round 2 risky 36 → 40–85 s at load 50–140). Arms `M-POOL-NO-INVALIDATE`, `M-POOL-TRUSTS-WARM-RED` — branch `perf/round3`
- the run-scoped servers were believed to die with the run because the process driver ends its jobs on a signal and when its parent is gone → the driver shares `apq`'s process group while each job leads its own, so a SIGKILL of that group (a timed-out or stopped agent's shell) killed the driver with no handler run and left every server running: 12 orphans with ppid 1, ~2.7 GB each, up to 2 h old, found on 2026-10-07. The display server (`CompilerDisplayOracle`) was worse, a direct child of `apq` that a plain SIGTERM or SIGKILL left behind. Each server now runs under a TETHER (`HaxeSpawn.TETHER`, `SpawnJob.tethered`): a node process between the driver and the server whose stdin is a pipe the driver alone holds, so its EOF is the driver's death by any means, on every OS; it then kills its own group (the server and anything the server started). A per-server process (~40 MB) rather than a watchdog per batch, because a batch-wide watchdog would need the pids handed to it and would itself die in the group kill unless detached. The persistent report-mode server (`CompilerServer`) is detached by design and untouched. Not covered: a SIGKILL aimed at the tether alone. e2e `ApqOracleServerLifetimeCliTest` (pool: SIGTERM / SIGKILL / group SIGKILL, display: SIGTERM / SIGKILL); arms `M-TETHER-IGNORES-EOF`, `M-POOL-SERVER-UNTETHERED`, `M-DISPLAY-SERVER-UNTETHERED` — branch `fix/server-leak`
- round 3 as a whole, measured A/B on the user's client working state with foreign load 14–68 on the box (another agent's builds and a headless browser — wall is noisy, the node process's own CPU is the steadier figure): the cold `lint src --fix` (round 1 of the autofix loop, 13 edits) 209 / 216 s → 161 / 168 s wall, the node process 148.6 → 118.6 s CPU; the workflow's second round (no edits, the same risky bisect) 127 / 128 s → 121 / 115 s; edits, report and stderr byte-identical every run. Not done, with the measurement that decided it: parallel check workers — on the client corpus the first pass's critical path is the 13 facts compiles (26 s CPU each, 57 MB of facts each), which the main thread already outlasts on an idle machine, so moving its facts-free work onto other cores only lengthens the wait; what follows the facts (the reach graph and its questions, ~20 s in pass 1 and ~5 s per later pass) needs the facts, the builds and the reach state mirrored in every worker. Keeping the reach analysis across passes — `MemberReach.refresh` refuses any declaration-signature change and every client pass makes one (`member-order`, imports), so it would have rebuilt anyway (traced: 6 builds, 0 refreshable). Next by size: the facts macro itself (`getPosInfos` 4.4 M calls, `typeString` 2.2 M, `ClassField.expr()` decoding per field), and the safe-write net's 13 cold `-v` compiles (~12 s), which the coverage probe needs — branch `perf/round3`
- the API-idiom and typed-event declarations were to be new top-level `apqlint.json` keys (`apiIdioms`,
  `typedEvents`) → each is ONE rule's declaration, and the rule option bag (`rules.<id>`) is where
  `thread-safety`'s `sinks` and `prefer-static-extension`'s `types` already live, with per-rule merge
  and `needs-config` gating for free — `21ff42da`
- `prefer-api-idiom`'s order gate was to refuse a right-hand side reading the SAME receiver's written
  fields → another receiver may alias it (`p.x = 1; p.y = q.x;` with `q == p`), so the gate is on the
  field NAME across every receiver — `21ff42da`
- an idiom window inside the declared type was to be rewritten like any other → `setTo`'s own body
  (`this.x = xa; this.y = ya;`) becomes `this.setTo(xa, ya)`, a self-call; the type and its subtypes
  are refused — `21ff42da`
- `typed-event-constant` was to insert the abstract's `import` with the retype → a shared import
  groups every constant of the file into one bisect unit, so one rejected listener reverted them all;
  a qualified spelling keeps each constant its own unit and `shorten-type-ref` adds the import — `21ff42da`
- a listener typed with a SUPERTYPE of the event class was believed to break under the retype → Haxe
  function parameters are contravariant: `(e:Event) -> …` for `EventType<ModalEvent>` compiles; only a
  subtype or an unrelated class is the mismatch — `21ff42da`
- the listener mismatch was to be read out of the oracle's revert → the verifier keeps no compiler
  text per reverted edit; the rule proves the common shapes (lambda, method, function-typed local)
  itself and reports them at the use, leaving the oracle the shapes it cannot type — `21ff42da`
- the option readers were to live in the two rules → a rule module naming `anyparse.grammar` breaks the
  grammar-agnostic seam (`LexicalRegionsSeamTest`); the JSON walk lives in `RuleDeclaration` on the
  config side and the rules receive plain records — `21ff42da`
- `default-repeated-argument` was to be safe once the parameter was trailing or followed only by
  defaulted ones, with full-arity calls standing in for positional binding → a full-arity call
  passes the LATER arguments explicitly, so cutting the constant slid them one slot left (the client's
  `samples(…, WIDE_BOTTOM, WIDE_STEP)` lost `WIDE_BOTTOM` on the second `--fix` pass); only a call's
  last argument, inside the leading run of required parameters, may be dropped — `776917c5`
- the same argument-slide was suspected in the other ops that edit argument lists → `remove-param` /
  `unused-parameter`, `change-sig`, `introduce-parameter-object` and `inline-method` all demand
  full arity and move the parameter and the argument as one slot, `add-param` only appends a
  defaulted parameter and touches no call — `776917c5`
- `var key:String = strKey ?? null;` was believed to need a simplification rule after the fact →
  it was MADE by `prefer-ternary-assignment`'s decl arm writing `strKey != null ? strKey : null`,
  which `prefer-null-coalescing` then turned into `?? null`; both producers now write the guarded
  value (`PreferNullCoalescing.nullPassThrough`), and a hand-written `x ?? null` is
  `redundant-null-coalescing`'s, type-free, because `??` types as its left operand (`i ?? null`
  with `i:Int` is `Int`, compiled) — branch `feat/rules-batch-1006`
- `scratch-field` was to prove no RE-ENTRY with `MemberReach` (the code between the first write and
  the last read writes the field) → it answered `Reached` for `KnobSlider.onButtonMove` through
  `Knob.set_x -> Event.new -> KnobSlider.onButtonMove`: a setter on a display object dispatches to
  every override by name. The gate is a syntactic one now (the method does not name itself), and
  indirect re-entry is the documented residual — branch `feat/rules-batch-1006`
- `scratch-field` was to drop a `new T()` initializer on `MemberReach.freshOnlyReads` → a field
  initializer is faceted only under its type's `<init>` pseudo-node, and entered there the walk
  admits every implicit `@:from` the syntax cannot rule out (`XmlFieldType.resolve`, a macro-only
  type); a constructor that only assigns its own fields is proven from its text instead — branch
  `feat/rules-batch-1006`
- `RefactorSupport.isPrivateMemberConfined` was the confinement both new rules started from → it
  refuses on the mere EXISTENCE of a subtype, and `KnobSliderBlue extends KnobSlider` mentions none
  of the field; `MemberWriteScan.referencesConfined` asks whether a subtype or grantee MENTIONS it —
  branch `feat/rules-batch-1006`
- `loop-bound-length-mismatch` compared `0...Y` with the length alone → the client's
  `for (row in 0...GridMesh.CELL_ROWS)` reading `FACTORS[row + 1]` of a `CELL_ROWS + 1` literal is
  correct code; a read of `xs[i + k]` moves the loop's reach by `k` — branch `feat/rules-batch-1006`
- `M-FIRST-LINE-FIT` and `M-DISPLAY-ORACLE-DROPS-DEFINES` SURVIVED their pins, on `main` `2377a672` as on the campaign base — neither is equivalent, both lost their killer's path. `M-FIRST-LINE-FIT` cut `fitLineLayout`'s `refuseGlue` branch, which the comprehension `fitLine` path reached with `refuseGlue = true` until `f6a59d80` moved it to `strictFitLineLayout` (KILLED at its parent, SURVIVED at it); the branch now serves only the case-body control-flow refusal. Re-cut onto `strictFitLineLayout` — a non-flat body takes the plain glue, whose gate measures its first line only — the same four failures its parent's run gave. `M-DISPLAY-ORACLE-DROPS-DEFINES`: since `8036f078` the oracle-assisted phase types a local from the compiler facts and starts the display server only as their fallback, so the killer's `lint --fix` run never warmed it (KILLED at its parent, SURVIVED at it); the killer now also asks the server `LintFixVerify.startDisplay` starts for `v` under `-D flag`, and keeps the run's `Int` as the facts' half — branch `fix/two-surviving-arms`
- Seven FACTS-group arms the 58eccffe full sweep read non-KILLED. Found equivalent, removed as an arm: `M-FACTS-DEAD-FILE-VALUES` (`ValueEscapes.compute` skipping a file no build runs) — `ReachProject.runsInNoBuild` is true only under the truth (`FactsView.truth`, final, read through once in `MemberReach`'s constructor before `ValueEscapes` exists), and since `f7676648` `compute` returns the facts' escapes (`FactsEscapes`, which read facts only, so such a file has none) before the syntactic loop is reached; the guard stays as the syntactic loop's own statement, its fixture is a `guard` now. Lost their killer's path, the killer now reaches the cut again: `M-FACTS-TRUTH-REFLECTION-TWIN` — since `d46b5f87` the duplicate a seen access gets off the facts carries the same literal (`memberName`), so `Reflect.field(this, "other")` changed nothing; the fixture adds a call whose name one build computes and the other reads as `"poke"` on an `Other`: read once, the name stays computed and bounded by the receiver (`Proven`), read twice the literal admits `Main.poke` (`Reached`). `M-FACTS-UNHELD-VALUE` — the region also CALLED the method value, an implicit call of `Endian` code that answers on its own; a region that only reads `Endian.calm` is asked of the value's edge alone. `M-FACTS-EARLY-DIRS-LEFT` — since `34e5bf90` a completed `--fix` run settles the early facts before its first write (`compilerFactsSettled`), whose `finish` deletes the directories, so `abandon` met none; the killer adds a run a failure ends (`endingCompiles` with a throwing body). `M-CODEPOINT-NATIVE` — one emoji shifts the unconverted offsets by one, which leaves them inside the declaration `localType` matches by containment; a dozen move them past it. Declared failing set corrected: `M-FACTS-SPLICE-HARMLESS` still kills its `CompilerFactsTest` pin, but the spliced `js.Syntax.code` of `Std.parseFloat` is judged by what it is handed (`NativeSiteReach.judge`), so keeping it in the region changed no answer; its reach fixture now asks of a member named `parseFloat`, which the target code's text names (`Blind` when kept). `M-FACTS-IDENTITY-CAST-VALUE` — since `bc09f144` its cut removes only the identity half of `same` (the wrapped-type half and the argument case stay), and under that cut the loop fixture stays green while the argument fixture goes red (`_counts`, handed to `Lambda.count` and to `widest`, keeps its key), so the argument fixture is its pin — branch `fix/arms-facts`

- `M-NULLITY-TYPE-PARAMS-IGNORED` SURVIVED its pins (on `main` `2377a672` too) — not equivalent: since `538cfdc1` `DeclaredNullity.ofBinding` refuses a binding whose written type is a type parameter in scope (`isTypeParamAt`) before `resolve`, so the two binding fixtures stopped reaching the cut; `resolve`'s own guard is still the only one on a hop's target (`typedef Id<T> = T`, `abstract Id<T>(T)`, a member's return). The arm keeps its cut and pins `testHopTargetTypeParameterIsUnproven`; the binding fixtures move to the new `M-NULLITY-BINDING-PARAMS-DROPPED`, which drops both guards of `ofBinding` in one cut (either one alone is the other's backstop) — branch `fix/arms-other`
- `M-EVENT-NO-USE-GATE` SURVIVED its pin and was EQUIVALENT: it cut `TypedEventConstant.run`'s `found != null` gate to hand `report` an empty list, and `report` returns at once on no event use (`eventUses.length == 0`), so the cut changed nothing for any input. The gate in `run` is gone (`report(candidate, uses[key] ?? [], …)`, the same behaviour) and the arm re-cuts `report`'s own guard — the one place a candidate with no event use, none at all or only a constructor of a class that is no event, is now kept out. Both fixtures name it — branch `fix/arms-other`
- `M-TOUCH-FOLDED-ACCESSES`, `M-TOUCH-TYPED-NEVER` and `M-TOUCH-TYPED-SHAPE-NONE` lost their pins to `3fdf05c6`: a static imported under another name is the member it names to the SYNTAX too since then, so the alias push their fixtures called "a touch only the facts see" was seen by both readings (FOLDED SURVIVED; the other two still killed twelve facts-only tests, but not their pin — MISMATCH). Not equivalent: each fixture now also pushes through a local holding the member, which the syntax reads as the value stored (an escape, `Unknown`) and the facts follow to the push (`Reached`) — in `go`'s second declaration for FOLDED — branch `fix/arms-other`
- `M-GRAPH-MAP-USER-CODE` read MISMATCH: it killed `testAMapHandedToMethodsThatKeepNothingLosesItsKeyUnderTheTruth`, not its pin `testAMapTheLoopLeavesUnchangedLosesItsKeyUnderTheTruth`. Bisected (pin test alone, cut applied, first-parent): the pin went green at the merge `e4ef613a` (`89c30728`, native and extern code runs only what it is handed) — the loop's extern map call is bounded by what it is handed since, with or without `runsNoUserCode`'s map clause. The clause still decides whether a map handed to a method that only calls its own methods may be changed there (`ArgumentUses`), which is the failing test, so the expectation moved there; the loop fixture keeps its other three killers — branch `fix/arms-other`
- `M-GRAPH-REFLECT-SUBTYPES` SURVIVED its pin since `78d3ad61` (`a6fa0a01`, bisected): `this` is its method's class's only where no rebinding call may run the method, and the js build's library code holds one (`Reflect.callMethod`), so on js `this` in `Base.dump` escapes and the escaped classes put `Main` among the types without the subtypes. Not equivalent: the interpreter's library holds no rebinding call, `this` keeps the exemption there, and only `subtypesOf(Base)` says it may be a `Main` — the pin asks that fixture on `--interp` too (cut: `Proven`) — branch `fix/arms-other`
- `M-ADMIT-SYNTAX-READ-FACETED` SURVIVED its pin since `e7f5f974` (`cad40413`, bisected): the expression macro's expansion the pin's lambda held is read through its facts there, so the graph held no function value read by its syntax and `runsSyntaxRead` never reached the cut clause. Not equivalent: a node folding the declarations of two types sharing a simple name (`Twin.k` beside `other.Twin.k`) has no one type's facts and stays syntax-read; held as a value, it makes the value call `f(new AE(1))` admit every implicit member, `AE`'s `==` among them (cut: `Proven`). An `Unknown` node marker is no substitute: it ends the facts' method-value reading for the whole program, the handed reading goes with it, and the site admits every function directly whatever the clause says — branch `fix/arms-other`
- The REACH group of the 58eccffe sweep — seven arms SURVIVED their pins and `M-REACH-TYPED-IMPLICIT-TEXT` MISMATCHED; none existed on `main` `2377a672`. Each pin had stopped reaching its cut; measured by running every candidate fixture under each cut (an extra `test.js` per arm) before moving any claim. `M-REACH-EXACT-SITE` and `M-REACH-ITERABLE-RETURNS` cut `ReachGraph.typesAt`, which under the truth answers only a site `ownedTypesAt` leaves open — a class operand's exactness and a class iterator's returns are read there, with their own guards — so their truth pins never met the cut: `EXACT-SITE` is pinned where the facts are no truth (`testAFreshObjectConvertedRunsOnlyItsOwnClassToStringUnderFactsThatAreNotTheTruth`), `ITERABLE-RETURNS` where a typedef naming the class owns the iteration (`testWhatAnIteratorReturnsIsNotIteratedInTurnUnderTheTruth`; the facts keep the alias's name, whose kind is no class). `TYPED-IMPLICIT-TEXT`/`-ITER`: the pinned lambdas converted or iterated what the CALL handed them, and the value call admits what it hands at its own `unresolved` step, so the unread admission was never the only path. `-ITER` is pinned by a lambda iterating a static it holds; no conversion shape isolates `-TEXT` (five tried: concatenation, interpolation, `Std.string`, through a typed local, a non-string result — the value call admits `Obj.toString` for each), so it moved to the two tests that already died of it, whose own comments describe its Text half (`testLibraryCodeNotReadYet…`), and the declared failing set of the MISMATCH row is exactly theirs. `DEAD-NODE-ENTERED`'s pin rested on "`haxe_ver >= 4.2` is no define a build's set decides": the builds' define values decide it now, so its `#else` edge to `Dead.go` is dead; a dead-declared node is still met BY NAME (`d.go()` on a catch-all), where the cut walks into it and its type's build macro answers `Reification` — added to the pin. `PROVEN-TRUTH`'s pin was the alias `import Main.items as stuff`, which the first reading has read itself since `3fdf05c6`; the first reading still falsely proves a region whose body a build macro replaces (`Mac.loop`, one of S23's shapes — `Proven` without the truth, `Reification` under it), but no loop rule asks that question end to end (they ask about the enclosing type's own member), so the pin is a unit wiring the two analyses as `MemberReach.forRun` does (`testAProofTheTruthContradictsIsAskedAgainUnderTheTruth`); the end-to-end alias test stays, unpinned and renamed `…KeepsTheLoopUnderTheTruth` — branch `fix/arms-reach`
- `M-REACH-EXTERN-FACTS-TYPE` DROPPED, equivalent on every shape found: it cut the compiler-typed fallback of `MemberReach.externSite`'s `typed`, which runs only when `externHanded` answers null under the truth (the fallback's own guard). Since `89c30728` `externHanded` reads from the facts what every caller hands the extern; under the truth it is null only for a caller with no declaration, no fact node or no call of that target in its facts — where the expression facts hold no type for the value either, or the edge is no call of that extern. Nine constructed shapes (the call in the region, in `Util.go`, in a nested lambda, in a local function, beside an abstract's inline constructor or an inline call that mark the caller's facts incomplete, a macro-made local) answered the same with and without the cut. The facts reading it guarded is pinned by `M-REACH-ARRAY-VALUES`, `M-REACH-HANDED-CONVERTED` and `M-EXTERN-HANDED-FACTS` (whose cut is the one way to the fallback) — branch `fix/arms-reach`
- `M-REACH-LOCAL-MAP-ALIAS-ARRAY` RE-CUT as `M-REACH-LOCAL-MAP-ALIAS-PROVEN`: its note ("the array alias analysis does not know a map's `set()` changes it") measured false. With the `owns` guard of `answerLocal` removed, every map change through another name — `set`, `remove`, `clear`, an index write, through a local alias, through the static another function stored it in, through a helper — is still refused (`Aliased`), in the unit and end to end; the cut changes only answers where nothing changes the map (`Escape` → `Aliased` in the unit; end to end the array path proves a body that only reads, and the key drops correctly). Equivalent in soundness, not in precision, so the arm is now `return Proven` at the same guard, killed by `FactsFixGateE2ETest.testAMapTheLoopLeavesUnchangedLosesItsKeyUnderTheTruth`. Whether the guard's precision cost is worth keeping is a separate question — branch `fix/arms-reach`
- `thread-safety`'s lock-left-held-by-a-throw finding following a `throw` up through the calls that reach it, as it
  follows a `throwers` entry → over the client's tree it flagged every hold across a call reaching an invariant guard
  (`DiskSystemItemData.get_master`, `GateMutex.lock`), throws that never fire; only a `throw` in the holding body and a
  call reaching a configured `throwers` entry raise — branch `fix/lock-order`
- `thread-safety`'s lock order read per hold — the hold's window reaching a taker of the other lock, under the
  holder's context, a re-take exempt only inside the same function → the client's fixed tree takes both mutation locks through
  a two-lock helper (`acquireMutationLocks`) and re-takes them under the tree lock, which read as an inversion; the
  order is a walk over (function, context, held locks) states, a re-take of any lock already held orders nothing, and a
  helper taking (giving back) several locks on every path holds (ends) them in its caller — branch `fix/lock-order`
- `thread-safety` reporting a lock order taken backwards by two background steps → one worker may run both, and the
  config cannot say which threads are distinct; only a main-thread step against a background one is reported —
  branch `fix/lock-order`
- `thread-safety` carrying the referencing function's context along every `Ref` edge → the client's `watcher.onBadNames =
  badNamesHandler` rooted the rename chain on the main thread in `StandardDiskSystem.new`, and `dispose`'s
  `removeEventListener(…, handler)` called the handler; a value assigned to a `dynamic` member runs where the member
  runs (`ThreadSafety.deriveStoredCalls`), the assignment carrying nothing while no unresolved call or access may name
  the member, and a call a `neverInvokes` entry names runs nothing it is handed — branch `fix/ts-precision`
- `thread-safety`'s contexts and lock-held taint read per FUNCTION → a branch a main-thread check sends to a worker
  (`NetEntity2.get`), or a parameter rules out (`if (!batch) _batchMutex.acquire()` reached with `batch = true`, `if
  (fileSystem != null)` reached with it left out), ran on every thread its function did; contexts, lock order and taint
  are walked over STATES (function, valuation of its tracked parameters, thread), a call cut where `EdgeConditions` says
  so — branch `fix/ts-precision`
- seeding every function the walk did not reach as an assumed-main root → once conditions cut calls, a function whose
  only callers the walk reached and cut (`blocked()` in `isMain ? async() : blocked()`) came back as a main root with a
  one-hop chain; only a function no walked function calls or references is seeded — branch `fix/ts-precision`
- binding arguments to parameters by position whenever a call passes fewer of them → Haxe skips an optional parameter
  whose type the argument does not unify with (`work(true)` against `(?n:Int, sleep:Bool = false)` binds `sleep`); each
  optional parameter an argument reaches must be written with the argument's own type — branch `fix/ts-precision`
- reading a parameter's type off the branch-aware projection's children → the projection holds no type annotation
  node; the plugin's `declaredTypeSources`, keyed by the declaration's binding offset, does — branch `fix/ts-precision`
- dropping every caller-less function as a dead root → a library's public API has no caller in its own run, and its
  findings would vanish; only under `closedWorld`, for a member nothing outside the run can invoke (no override, no
  metadata, no constructor or `main`, no unresolved call of its name, no supertype that may declare it) — branch
  `fix/ts-precision`
- measuring `thread-safety`'s precision by its messages → a message embeds a chain the rule re-renders whenever the
  graph finds another path, and caps it at 8 hops, so a label keyed on it rots on the first unrelated edit; every
  finding carries a structured `data` record (`family`, `function`, `subject`, the whole `chain`), and `lint-diff`,
  `--baseline` and `lint-score` key on `(file, rule, severity, family, function, subject)` wherever it is present —
  branch `feat/ts-precision`
- scoring a rule by matching findings to labels by `file:line` or one by one → a line moves under any edit above it,
  and a rule reporting one stall at three call sites would look three times as right; `lint-score` matches by the
  `(family, function, subject)` key, several findings of one key are one hit plus duplicates, and precision leaves
  `unknown` and unlabelled keys out — branch `feat/ts-precision`
- a finding's `function` as the id the graph gives it → a lambda's id is `Type.member#<n>`, renumbered by every lambda
  written before it; the key names the enclosing member and only the chain keeps the lambda's id — branch
  `feat/ts-precision`
- spelling the json key `member` because `function` is a Haxe keyword → a ByName schema field declares its wire key
  with `@:key('…')`, read by the generated parser and writer alike, which every format with keyword or hyphenated keys
  needs anyway — branch `feat/ts-precision`
- explaining a long lock by its first reason alone → the client's `_batchMutex` is long by leaks, a blind hold and a crossing
  release at once, and fixing one leaves it long; `--explain-long` lists every reason at every site, plus what the
  lock is long by once its own leak / blind / crossing reasons are set aside, solved after the report on a fresh taint
  so it moves no finding — branch `feat/ts-precision`
- reading `--explain-long`'s `spans-blocking` reasons off the solve as it grew → a lock is recorded at the first hold
  and the first blocking call of the round it turned long, the rest skipped once it is long, so a second hold across
  a second sleep went unlisted and "fix this one call" read as making the lock short; the reasons are read back from
  the converged taint over every hold, and the counterfactual's from its own — branch `feat/ts-precision`
- keeping the first lock-order step the walk records as an inversion's witness → swapping two main-thread calls
  (`fs.save(); fs.store();`) renamed the holder and moved the anchor; the walk runs in an order of ids and sites, and
  each order keeps, per thread, the step that precedes by (member, file, offset, path) — a holder whose state another
  holder's path reached first stays unseen, which is the walk's state collapse — branch `feat/ts-precision`
- a `lint-score` truth `rule` matching nothing scored as every recall entry lost (exit 1) → a misspelt rule, an
  empty report or a severity filter excluding everything reads as a precision regression; nothing to score is exit 2
  — branch `feat/ts-precision`
- deduplicating `--explain-long` reasons by site alone → a virtual call dispatching to three targets kept one in
  `reasons` and three in `aside`, so the two lists disagreed on one site; one normaliser keys on (kind, site, target),
  and a hold waiting for its own lock — long only because it already is — is counted apart, never a reason
  — branch `feat/ts-precision`
- a lock-order witness ranked off each state's first arrival, the walk sorted to make it stable → two holders reaching
  one downstream state left the second unseen, so renaming a function outside the key moved it; every state keeps
  every way in, and the holder is the least over all of them, ranked only for reported pairs — branch
  `feat/ts-precision`
- pairing old and new snapshots across `data` by the first message seen per identity key → one function reaching a
  sink by several chains still moved in `lint-diff` while `--baseline` called nothing new; both spend from one pool
  holding every message per key, every finding its own key first — branch `feat/ts-precision`
- grading a short sink by its own call site alone (`thread-safety` `shortSinks`) → the client's folder icon runs four COUNT
  queries once per icon and the folder delete one unlink per child: each call is single, the loop is up the main
  thread's way (`ItemListItemsController` per visible item, the delete per selected item); a main-thread short call is
  long when ANY main-thread path to it crosses a repeating call — branch `feat/ts-precision-2`
- reading that repetition off the finding's own chain (`ThreadStates.mainPath`) → the chain is one witness: the icon's
  ran through the one-icon-per-event handler and graded the four COUNTs short, while the file list's per-item path
  repeats them; the closure over every main-thread path is what grades — branch `feat/ts-precision-2`
- recursion as one strongly connected component over every edge kind → registrations close cycles that run nothing
  (a handler registering itself, a callback handed back), and the client's graph formed one component of 1080 functions, so
  every call in it repeated; recursion is a cycle of RUNS (call, `new`, override, accessor), and a callback repeats only
  through an `iterates` call — branch `feat/ts-precision-2`
- placing a call site under the function node the graph names for its caller → graph ids are simple names, so two
  same-named types share one node and every site of the other's file went unplaced (and so repeating); the loops
  around a site are read off its file's own tree from the root, counted afresh at every function or lambda around it
  — branch `feat/ts-precision-2`
- dropping every hold only the main thread runs, the main thread's own blocking being finding (a)'s → the client's
  multi-select move holds `_batchMutex` across a per-item loop on main, and that hold IS the labelled stall while (a)
  names only the calls below it; a main-only hold stays when the main thread itself works long under the lock
  (`LockTaint.ownWork`) — branch `feat/ts-precision-2`
- counting a take of another lock as a main-only holder's own work → `getFolderLastCloudActionAction2` holds
  `_batchMutex` only to take `_mutex`, a wait finding (a) already reports at the take; own work leaves every take out,
  repeated or not — branch `feat/ts-precision-2`
- also solving lock LONGNESS from the holds a main waiter can meet (no main-only hold making a lock long) → measured
  on the three client trees it moved no finding; left out until a case needs it — branch `feat/ts-precision-2`
- outer-lock dominance with blind holds breaking it outright → every client `ShardDatabase._mutex` hold is blind through
  a `trace` (client routes `trace` to its log writer), and the brief `getFileCount` holds take `_mutex` outside
  `_batchMutex`, so nothing was ever dominated; an unresolved call is a long point, except one a bare `shortSinks` name
  names and no loop under the hold repeats — branch `feat/ts-precision-2`
- carrying a must-held lock into a callee by `CallEdge.receiverField` alone → the graph names `o.f` on a typed `o` as
  `Owner.f` too, so `fileSystem.cloudDatabase.batchLock()` read as a lock on a field of the running object; only a bare
  field or `this.f` carries a lock onto the callee's `this`, and only a `final` one — branch `feat/ts-precision-2`
- must-held by "the take runs on every path INTO the function" (`LockWindow.runsOnEveryPath`) → the client's ShardDatabase
  holds open after an `if (…) return` and behind `if (!batch)`; a take counts at a point when the deepest node holding
  both is a sequence that runs the take's statement first, its way to the take through sequences and `if`s the
  valuation decides — branch `feat/ts-precision-2`
- a give before the point killing a must-held lock wherever it sits → `if (done) { releaseMutationLocks(); return; }`
  ahead of every call in the client's `moveItem`; a give in a block that ends in a `return` or `throw` after it, with no `catch`
  around it that holds the point, reaches no later call — branch `feat/ts-precision-2`
- counting every function that gives a lock back as a releaser → `if (!batch) _batchMutex.release()` where every caller
  passes `true` gives nothing, and a wrapper's or helper's own give is its caller's; releasers come from the crossing
  releases and helper gives that some state runs — branch `feat/ts-precision-2`
- attributing a short call that a caller repeats to EVERY repeating caller above it → client grew from 67 to 466 A keys
  warning, one per UI loop on any way to a helper; the nearest repeating call on any way owns it, one warning per call
  site — branch `feat/ts-precision-2`
- folding sibling entry points by "the nearest shared callee" of every sink → a finding already sits at the call of the
  sink, i.e. inside the shared callee, so siblings duplicate only through LOCK TAKES (`Store.put` / `remove` /
  `removeKeys` each taking `Store._mutex`); the rule is one warning per lock object, at its wrapper's take when one
  exists — branch `feat/ts-precision-2`
- grading a finding long whenever ANY way to its long call exists → 17 of the client's warnings were long only through
  `catch` → `Error.reportError` → a blocking PUT (`DiskSystemNativeExtensions.getMTime`'s catch under every watcher
  hold); the costs are solved a second time over the normal paths — a call inside a `catch` body leads nowhere — and a
  finding long only in the first solve is `info`, naming the catch. Demotion, not removal: an error that repeats is a
  real stall, so it stays visible — branch `feat/ts-precision-2`
- bare `shortSinks` names applied to dominance only (β1) → the costed solve still seeded every hold spanning an
  unresolved call as long on its own, so the client's `BinFile._mutex` was long by a `trace` in `BinFile.read` and the main
  thread's take of it warned; a hold's unresolved call is a long reason only where no bare `shortSinks` name makes it
  brief once under the hold — the same `briefBlind` the dominance reads — branch `feat/ts-precision-2`
- that narrowing alone → `VolumeWatcher.reset` (real-long: it takes the tree lock and leaves it for the next
  `update()`) was found only through `BinFile.remove` taking that long lock; a hold no path of its function gives back
  (`HoldGrade.handsOff`) is long whatever its window spans — the recall now rests on the mechanism, not the accident.
  A function that only takes the lock is left out: its caller's code is the hold — branch `feat/ts-precision-2`
- a function value registered in a loop repeating once per iteration → the client's `listenContent` registers one rename
  handler on every list item, and the handler (a `FileSystem.rename`) warned at the loop; a callback handed to a
  `registers` call (`addEventListener`) runs later as a run of its own, once per event however often it was registered,
  so no loop around the registration and nothing up the way to it repeats it. A config list, not a guess: whether a call
  runs what it is handed now or keeps it is the library's contract — branch `feat/ts-precision-2`
- dominance proven only at takes in the hold's OWN function (`underHold`) and through the entry meet → the client's
  `removeFileBlocked` holds `_cloudDatabase._batchMutex` and calls `_cloudDatabase.getFileByCloudId`, whose take of
  `_mutex` the meet over all its callers cannot prove under the batch; the hold being judged is carried down its own
  walk instead, its object through each call on it (`LockDominance.carry`), lost at any callee that may give it back —
  8 of the 13 `batch-x` holds of the brief turned info, 4 more once objects are PATHS of stable fields
  (`fileSystem.cloudDatabase`: a `var` with no write outside its constructor, the scan conservative — a bare or
  `this.` write counts in a type owning the field, any other receiver's always) — branch `feat/ts-precision-2`
- a take of a lock nothing ever takes exclusively counted as a wait → the client's `NetToken._refreshReadWriteLock` is taken only
  with `lockShared`, so `std::shared_mutex::lock_shared` never blocks; which pair members share is the library's
  contract, so a config list (`sharedLocks`), applied only when EVERY take of the sealed lock goes through one —
  branch `feat/ts-precision-2`
- γ4 items left open, by cause: `ShardDatabase.new` (already info) is refused as a constructor hold because its
  constructor calls `super()` (which may publish `this` first) and registers `enterFrameHandler` after the release;
  `FoldersIncrementalDeltaUpdatesRequest.start`'s lock is UNNAMED (`FoldersIncrementalDeltaUpdatesCache.lock` cannot be
  a wrapper while `lock` is a name some unresolved call is written with), so "no main-thread taker" cannot be asked
  of it; `ItemList.reload`'s `case _` needs every `cast` to `ItemListViewType` typed to prove the value set; and
  `StandardDiskSystem.listFolder`'s `Lock.wait` is no main-thread-check gap — `put` does take the async `request` on
  main, whose `urlLoader.load` → `this.go()` dispatches to every override, `BlockingNativeURLReader.go` included
  (the loader `doRequest` builds is never one) — branch `feat/ts-precision-2`
- multi-lock helper holds (`helperHolds`) fed to the throw and order findings only → finding (b) never judged
  them, so every caller of the client's `acquireMutationLocks` (saveXML, moveItem, deleteItem, renameItemInternal, …) held
  `_batchMutex` and `_mutationMutex` across nothing, while the helper itself warned for taking `_mutationMutex` under
  `_batchMutex`, and the twin's gives counted as crossing releases making both locks long on their own. The holds are
  judged at the caller like a wrapper's; the helper's takes and the twin's gives are the caller's — branch
  `feat/ts-precision-2`
- every `try` with a `catch` intercepting what its body raises → the client's `VolumeWatcher.update` became `try updateInternal()
  catch (e) { _resetMutex.release(); throw e; }` and its callers' holds stopped being seen leaking
  (`ProjectsVolumeWatcher.update`); a `catch` throwing its own variable is the `try`'s exception going on. Only that
  shape: a `throw` of anything else is the function's own throw, which stays unfollowed by design — a project function
  whose throw callers must expect goes in `throwers` by name (the client's `badNamesHandler`, not configured: on 1d1ba147 the
  healing runs outside the tree lock) — branch `feat/ts-precision-2`
- every override of a dispatch running wherever its receiver came from → the client's `NetRequest2.doRequest` builds
  `urlLoader` as a thread or simple loader and `BaseNativeURLReader.load`'s `go()` reached `BlockingNativeURLReader.go`
  anyway; the walk hands down the classes the receiver may be (`AllocationSets`: a `new`, a sealed allocation set of a
  field, the running object's) and drops a dispatch none resolves to. Path-sensitive on the hold walk only: the
  main-thread finding is per call site, and main does reach the blocking loader through `goBlocked`, so
  `A|BlockingNativeURLReader.go` stays (its witness chain is still the `request` one) — branch `feat/ts-precision-2`
- passing the oracle's compiler facts to this rule's graph by default → measured on the live client at 1d1ba147 (its `src`
  identical to the frozen tree, 13 configurations, verdicts reused): keys 86 → 123, precision 0.21 → 0.16, recall
  15/15 either way. A call the facts describe carries no `CallEdge.receiverField`, so `LockSites.lockOf` names no
  lock for its takes and every one becomes an unnamed, always-long lock (`BinFile.write` "holds Mutex.acquire",
  every `ShardDatabase._batchMutex` holder over its own `_mutex` take); and a lambda the facts record as a value made
  at its site inherited its maker's thread beside the syntax's `spawns` registration (now `ThreadGraph.madeWhereHanded`).
  Opt-in (`compilerFacts`) until the facts' call edges name their receiver field — branch `feat/ts-precision-2`
- every `catch` body a path → the client's `getMTime` / `setTimestamp` wrap hxcpp's `FileSystem.stat` (a missing path gives a
  zeroed record, no throw) and a native prim returning a status code in a `catch` that reports by a blocking PUT, and
  that leg was the long reason of most `VolumeWatcher.*` holds; a config list (`nonThrowing`, the project's word for
  the runtime) and a positive whitelist of what else a `try` body may hold make such a `catch` no path at all
  (`DeadCatches`, checked in `EdgeConditions.carried`) — branch `feat/ts-precision-2`
- main-thread repetition and its owner read per FUNCTION → the closure crossed calls the caller's valuation rules out:
  the client's project planner loops `ModelVOModel.loadModelData`, which calls `loadXML(path, false, …)`, and the
  `if (checkLimits)` count / animation check under it were "repeated" by that loop (three keys, two false, one rare);
  `MainRepeats` runs the closure and the owner walk over `ThreadStates`' states with `EdgeConditions.carried` / `bind`,
  as the hold taint already did — branch `feat/ts-precision-2`
- valuations knowing only `Bool` literals, `null` and `new` arguments, and conditions only on a parameter itself → the client's
  `Token.blockedPost` hands `blockedRequestInternal` an object literal, which tests it as `final simpleRequest = data
  == null && files == null; … simpleRequest ? fromMemory(id) : null`; an object, array or string literal is never
  null, and a `final` local bound to a condition is that condition, both where a parameter is tracked and where a
  call is decided — branch `feat/ts-precision-2`
- a main-only hold warning for its own long work beside finding (a) → after δ1 eight of the client's new caller holds were
  main-only (`deleteItem`, `moveItem`, `setXML`, `loadXML`, …), each a second key for work (a) already warns of at
  `deleteItemInternal` / `moveCloudFolderSubItemsAction2`; the hold turns info when (a) warns of every long call it
  names at another member (ζ1 dropped the exception that kept it where (a) reports the work at the holder itself,
  `ItemListMoveItems.moveItems`: the hold is still the main thread's own work) — branch `feat/ts-precision-2`
- folding nested holds only within one function (β3) → a multi-lock helper judged at a caller that runs inside the
  sync's own batch hold (`cloudLocalRenameAndMoveItem`, `removeCloudLocal` under `moveLocalQueue` /
  `removeLocalQueue`) was a second key for one hold; a hold whose lock every state of its function already must-holds
  on the same object at the take is the enclosing hold's (`LockDominance.enclosed`) — branch `feat/ts-precision-2`
- reporting every hold of a lock no sealed member names → the client's `FoldersIncrementalDeltaUpdatesCache` is reached through
  `_base._cache`, a field read for more than its calls, so no member names it; named in `lockPairs`
  (`fs.cloud.FoldersIncrementalDeltaUpdatesCache.lock/unlock`) it is told apart by that pair, and a pair the main
  thread never takes stalls no main thread — branch `feat/ts-precision-2`
- every `switch` branch a path → the client's `ItemList.reload` throws in the `case _` of a switch over `ItemListViewType`
  (LIST, GRID), a `C` finding no value can reach; the catch-all of a switch over a closed enum abstract whose values
  the cases all name is no path (`ExhaustiveSwitches`). Closed is positive: no `from` clause, every function handing
  back the abstract hands back only its values (`@:from fromString` maps every string onto LIST / GRID). A `cast`
  into the abstract is the hole the source cannot show — accepted, as the compiler's own exhaustiveness does —
  branch `feat/ts-precision-2`
- one repeating-owner finding (a) per short sink → the client's `ItemListMoveItems.moveItems` warned four times at one line
  (`File.getContent`, `FileSystem.rename`, `Connection.request`, `Mutex.acquire`), `repairShareAttr` twice per
  site; the site owns one warning keyed by the call it repeats, naming every sink — a sink set that grows with the
  code no longer renames the key — branch `feat/ts-precision-2`
- a hold of a lock warning both where it waits for another lock and where that lock's holder warns → the client's
  `StandardDiskSystem.saveXML` (mutation lock) waits for the tree lock `VolumeWatcher.updateInternal` holds long;
  one root cause, two warnings. `RootCauseFold`: a hold warning whose every long call is a wait for a lock every
  long-making hold of which is reported (a warning, or an info naming the warning that covers it), or a sink call
  another warned hold is long by too, turns info naming them; a cycle keeps the hold nearest its work. Positive: a
  lock long by a hand-off, an unresolved call, a crossing release or a hold with no finding stays uncovered. A finding
  (a) at that sink call covers a hold only when the hold runs on the main thread alone (its own work) — a background
  hold across the same call stalls the main thread through the lock even once the main thread stops calling it.
  The same-member exception of the main-only fold (ε4) went with it: the client's `moveItems` hold folds onto the loop's (a)
  warning — branch `feat/ts-precision-2`
- a local declaration, an array literal, `break` / `continue` as opaque steps of a hold's window → the client's
  `StandardDiskSystem.getXML` (`final xml = try … catch { unlock; throw }`) and `listFolder` (a comprehension with
  `continue` and a `catch` that releases before it returns) "leaked" their tree lock, which made every wait for it
  long by a leak no finding names; `LockWindow` walks them in place — branch `feat/ts-precision-2`
- one warning per call site of a sink a main-thread way runs → the client's `PathIO.deleteRecursive` warned three times (its
  `readDirectory`, `deleteDirectory`, `deleteFile` run on every run of it) and `repairShareAttr`'s session loop twice
  (`getXML`, `setXML`); one warning per way into a function, and per loop for the calls it repeats — branch
  `feat/ts-precision-2`
- every repetition long for a short sink (ζ2) → the client's `listFolder` per-child SELECTs (414 children × 2 × 0.04 ms = 33 ms),
  `createPathToItem`'s path segments, `deleteFileSystems`' four unlinks warned as repeated short work under the
  50 ms real-long line; `boundedRepeats` names the member (and call), the bound and the measured cost of one turn, and
  the check stays mechanical (`max × costMs < repeatBudgetMs`), the numbers and their evidence in the config. Not
  listed: the 401 retry cycle (`executeCompletion` ↔ `refreshTokenOrLogoutBlocked` has no retry cap in code) and
  `listFolderCloudCallback` (a turn that inserts the missing DB row costs 1.2 ms, 84 × 1.25 > 50) — branch
  `feat/ts-precision-2`
- `if (flag) lock(); … if (flag) unlock();` read as a leak → the client's `VolumeWatcher.rename(…, flush)` made the tree lock
  long by a leak no finding names, which kept every wait for it from folding; a parameter deciding two or more `if`s
  that nothing writes is a fixed flag, the window traced once per value (`FixedFlags`) — and a `throw` a `catch` around
  it intercepts no longer marks a leak (`copyFileAndCreateSlave`) — branch `feat/ts-precision-2`
- judging "inside a catch" off the witness chain the finding prints → the chain is one way; a second way outside every
  catch must keep the warning, which only a solve without the catch edges can see — branch `feat/ts-precision-2`
- a parameter as a fixed flag when nothing ASSIGNS it (`FixedFlags`) → `var flush = check()`, `final flush = flush &&
  check()`, a `for` binder, a `catch` variable or a lambda parameter of its name made a later `if (flush)` read another
  binding, and a take nothing gave back read as no leak (review r4 `L2`, `L2d`, r2 `h01`); a flag is now a parameter no
  other node of the function declares (`BareNames.stable`) — branch `fix/ts-A`
- a `final` local deciding a condition when the function declares its name once (`EdgeConditions.finalLocalInit`) → a
  read outside the local's block, or outside the lambda declaring it, means the member of that name (review r4 `A1`,
  `A2`); the local must sit in a block on the way to the read, before it (`BareNames.localOf`) — branch `fix/ts-A`
- a `try` with any `catch` stopping every throw (`LockWindow`, `ThrowReach`) → `catch (e:haxe.io.Eof)` does not catch
  `throw "x"`, and a `throwers` exception is of no known type (review r4 `L1`, `L1e`, `R5`); a catch stops a throw only
  when it provably catches it (`CatchTypes`: untyped, a catch-all type, the exception type, the thrown literal's or
  `new`'s type or a supertype) — branch `fix/ts-A`
- a `catch` re-raising only when it throws its own variable bare (`ThrowReach.rethrows`) → `throw new X("…", e)`,
  `throw (e)`, `final x = e; throw x` and any other value thrown there run only where the `try` failed (review r4 `R1`,
  `R2`, `R4`); a `catch` holding any `throw` lets the failure go on — branch `fix/ts-A`
- a catch-all of a switch over an enum abstract dead whenever the abstract has no `from` clause and its typed functions
  hand back values (`ExhaustiveSwitches`) → a guarded case, a value under `#if`, a constructor, an untyped `@:op`, a
  static field, a parameter or local shadowing the subject, a `Dynamic` write, an uninitialized String member, two
  abstracts of one name all reached it (review r4 `e1`–`e10`); closedness is now a whitelist of the abstract's members,
  and the member must HOLD only values — its getter, its initializer or a counting abstract's `0`, every assignment to a
  field of its name — which the client's `ItemListPicker.viewType` (uninitialized, LIST = 0, set through a `?viewType ??
  defaultViewType` whose getter converts a `Null<String>` by `@:from`) still passes — branch `fix/ts-A`
- a string literal inert, a bare name inert, a `nonThrowing` call off any receiver (`DeadCatches`) → `'${risky()}'`, a
  property with a throwing getter, `disk().istat(p)` and `d.istat(p)` on a null `d` throw (review r4 `d1`–`d5`); inert
  is a literal of text parts only, a read of a binding or a plain field, a call off a static path — branch `fix/ts-A`
- a call in any `catch` body, or in a lambda written there, only on an error path (`ErrorPaths`) → a catch inside a loop
  runs once per failing turn of the normal run, and a lambda a catch stores runs wherever it is called (review r4 `P1`,
  `P2`, r2 `f11`); a catch counts only with no loop above it in its function, and a nested function inherits it only when
  every way into it is an invocation inside that catch — branch `fix/ts-A`
- "a `var` written only in its constructor" judged by SPAN containment → a write in a lambda or a local function the
  constructor makes (`Runner.create(() -> db = b)`) sits inside the constructor's span yet runs any time later, a
  write of ANOTHER object's field inside the constructor counted as the constructor's own, and a `static var` the
  instance constructor assigns was taken for stable; the write's own function id must BE the constructor, on the
  running object, never for a static (`FieldWrites`, `ObjectPaths.writtenOnlyInConstructor`) — branch `fix/ts-C2`
- "every write" / "every value" of a field read off the run's files alone → a run over part of a project
  (`hxq lint core` where `plugins/` writes the field) sealed the field and the stall vanished; a `var` is stable and a
  field's allocation set sealed only when the run sees every write of the project — `closedWorld` declared AND the
  run holding every `.hx` file under the declaring document's `resolutionRoots` (else its directory), `exclude`d paths
  aside (`ProjectCoverage`); a `final` needs neither — branch `fix/ts-C2`
- an undeclared class name in a `new` taken for a library class → an import alias (`import a.Blocking as Blk`, `in
  Blk`) and a type parameter (`new T()`) spell a project class with a name the index does not declare, and the
  dispatch "ran no project override"; a name the run does not declare is a library's only when the run covers a closed
  project and the file writes it by a path or a plain import, and an alias names nothing, even when it reads as a
  project class's name (`AllocationSets.constructedClass`) — branch `fix/ts-C2`
- two write walkers re-walking every file per field (`ObjectPaths.writes`, `AllocationSets.writes`) → one write index
  per run over the graph's held trees, by name (`FieldWrites`); `FieldWriteIndex` was not reused: it re-parses every
  file, records neither a write's function nor its value, and attributes by DECLARED receiver type, which for this
  question needs the subtype closure to stay sound — branch `fix/ts-C2`
- each `thread-safety` option read where it is used, a wrong shape falling back to "absent" → a malformed config
  (`"shortSinks": "x"`, `"iterates": [1, 2]`, a typo key, `"max": "414"`, a `site` matching nothing) ran byte-identical
  to no config with nothing said; one reader (`ThreadSafetyOptions`) checks every key and reports each drop as an
  `info` finding naming no file — and those were never printed at all: the report grouped findings by input path, so
  a file-less finding (the old malformed-`lockPairs` one included) only counted in the summary line; it now closes the
  report under `''` — branch `fix/ts-C2`
- the fix brief's "dead" `boundedRepeats` entry `fs.DiskSystemManager.deleteFileSystems` → live: without it the client's
  `A deleteFileSystems | FileSystem.deleteFile` (four unlinks under `HelpMain.deleteCache`, real-short) warns on all
  three frozen trees; kept — branch `fix/ts-C2`
- a call repeats only when the graph PROVES a loop, an `iterates` callback or a recursion (a negative list) → a user
  `each(xs, f)`, an aliased `Lambda.iter`, `n.forEachKid(walk)`, a `Dynamic` handler loop, a custom iterator's `next`
  and a background loop posting 1000 `runInMainThread` tasks were all "once" and info, with a note claiming "no loop,
  `iterates` callback or recursion on the way"; repetition is POSITIVE now: a value handed to any call but a `runsOnce`
  / `registers` / `spawns` / `marshals` / `neverInvokes` one repeats, a marshalled value owns its repetition, a function
  no resolved call runs (the entry point and static initializers aside) warns "repetition unknown", and the info note
  says what it proved. client: +25 warnings on 1d1ba147 with a proposed `runsOnce` (API entity calls, `WaitView.load`, …)
  — branch `fix/ts-B`
- `registers` honoured for any call it names → a registration into project code (`Hub.addEventListener` pushing into an
  array a dispatch loop runs) counted once per event though the project's own loop runs it per item; only the
  runtime's registration (no body in the run) is once per event, and its info says "once per event" — a dispatch the
  RUNTIME makes in a project loop (`for (…) sprite.dispatchEvent(e)`) stays the known hole — branch `fix/ts-B`
- a `boundedRepeats` entry covering its whole member (nested, sibling and lambda loops became "once" with it) and a
  malformed `call` widening to the member → an entry binds ONE repetition of the member's code (the only one, its
  `loop` header, or the one around its `call`), a call inside several bound ones pays the product of their bounds, and
  an entry binding none or several, or with a field of the wrong type, a non-positive number, a pattern `site`, a
  `call` naming nothing or an unknown key, is dropped whole with a config `info` — branch `fix/ts-B`
- only the first of several equally near repeating callers warning, owners ordered by `'file:offset:to'` as TEXT, a
  loop's warning keyed by its first call by offset and a handed value's by its lambda's per-file number → every owner
  at the least distance warns, ordered by numeric offset; a repeating site is keyed by its loop's header (`#2` for a
  second of one header in a function), the call it hands a value to, or its recursion's target — an unrelated edit
  renames nothing. client truth keys remapped (9 entries, `for (session in sessions)`, `DiskSystemItemData.forEachChild`, …)
  — branch `fix/ts-B`
- a lambda's first parameter read as a reference to the lambda (`x -> f(x)`: the binder starts where the lambda does,
  and `fnBySpanFrom` answered the lambda) → a phantom `Ref` from every such lambda to itself; a name binds a local
  function only when that function carries the name — branch `fix/ts-B`
- a multi-lock helper taken for any function calling a lock pair, its takes delegated to its callers and its own window
  judged nowhere → a helper is POSITIVE: its body runs nothing but its lock calls (`WrapperOps.lockTrafficOnly`) and
  every invocation of it is a plain call (`plainCallsOnly`, no dispatch that may run another override); its own takes
  are judged over its own window (a thread waiting for its later lock while holding the earlier ones), a hold a helper
  call opens may hand its lock off (`HoldGrade.handsOff`), and `nestHolds` leaves a handed-off inner hold a warning of
  its own; a lock no member names is keyed by its class for "the main thread takes it" (`HoldGrade.takenKey`), so an
  exclusive take and a shared one meet (review r3 `c1` `c1b` `c4` `c8`–`c10`) — branch `fix/ts-C1`
- a `Site` root cause covering by any hold across the same sink call → it covers only by a hold of the SAME lock, in the
  same function, or one whose function the call's way passes: another lock's hold across the same work elsewhere is a
  stall of its own, and narrowing one frees nothing of the other (`RootCauseFold.covers`); a finding never covers
  itself (one warned hold per finding), and an info turned by a hold around it counts as reported only while a warning
  it was turned onto is (covers chain); `foldEnclosed` demotes only when a warned enclosing hold's trail reaches the
  function, and its note says so (review r3 `c5` `c5b` `c5c`) — branch `fix/ts-C1`
- the covered hold judged "once" along the covering hold's trail → the covered hold MAY repeat: a `Site` reason
  carries whether the call repeats under the hold, a hold reaching it once covers no repeating one, and the covered
  hold repeats whenever a function on its way is re-entered through a cycle of calls (`LockTaint.mayRepeatAlong`) —
  the client's `VolumeWatcher.updateInternal` (the recursive `checkNode` walk) warns again — branch `fix/ts-C1`
- the meet over callers seeding what a function holds on entry for any function → a function code outside the run may
  call holds nothing on entry (`MustHeld.enteredUnknown` via `seedable`) unless its chain's `closedWorld` holds and
  nothing outside can invoke it (`sealedFromOutside`); `closedWorld` is the coverage-adjusted one of `ChainLists`
  (`ProjectCoverage`), so a partial run reads the meet as open exactly where it reads the field writes as open — one
  predicate for both (merge `feat/ts-precision-3`) — branch `fix/ts-C1`
- a valuation's unknown parameters left unknown, so a take and a give under one undecided condition never met → each
  run of a function is split per value of the parameters a condition of its body reads (`BodyFacts.conditionNames`,
  `runsOf`), up to `KNOWN_UNKNOWNS` open ones, the rest kept as written; a `case`'s statements are a sequence for "runs
  on every path" — branch `fix/ts-C1`
- every lock that some take dominated counted as dominating → only a lock whose every take is exclusive through one
  pair, and that NO function gives back without having taken it (`MustHeld.releasedUntaken`), dominates
  (`LockDominance.excludes`); every give is a releaser candidate unless a take of its lock on the same object runs on
  every path before it in every run of its function with no give in between, a value handed on to run that gives the
  lock back gives it back where it is handed, a throw in a `try` body does not leave the function, and a re-take after
  the cover's give breaks the cover (review r1) — branch `fix/ts-C1`
- a 64-pass sweep over every entry state, its unsettled result silent → a worklist in `MustHeld.solveEntries`
  re-meets only the callees of a changed state, under the same bound per state on average (`PASSES`); an unsettled
  meet holds nothing for every entry and is reported as a file-less `info` — branch `fix/ts-C1`
- merging the four groups: `BoundedRepeats` read its own JSON beside `ThreadSafetyOptions` → B's per-entry checks (a
  pattern `site`, a non-positive `max` / `costMs`, a non-string `call` / `loop`, an unknown key) moved into the one
  reader (`readBounded`, which now reads `loop`); `BoundedRepeats.entries` keeps only the graph resolution (a `site`
  naming no member or several, a `call` naming nothing), and its notices, `CallRepetition.notices()` and the unsettled
  meet all close the report as file-less `info`s; C1's private copies of `collectNamed` / `writes` give way to A's
  `BareNames` — merge `feat/ts-precision-3`
- a `Site` cover by a hold of the same lock in another function, whatever thread runs either → the client's
  `StandardDiskSystem.loadModelContent` (the I/O worker writing a validated model back under `_mutationMutex`) folded
  onto `getText` / `getXmlAndText` on the sync worker, which reach the same `File.saveContent`: each thread stalls the
  main thread by itself, and narrowing one hold frees nothing of the other. A hold of the same lock covers another in
  another function only when every thread the covered one runs on runs the covering one too (`RootCauseFold.oneThread`);
  a thread is an origin (`ThreadStates.origins`): the main thread, or the callback a `spawns` call starts a worker
  with — two callbacks are two threads, whatever spawns them; a hold no origin reaches shares none. Requiring both
  holds on ONE origin was measured and rejected: `Store.remove` / `removeKeys` (main and workers) stopped folding onto
  `Store.put` (every thread) though `put` runs wherever they do — branch `feat/ts-precision-3`
- with no I/O in `shortSinks`, a long sink a loop up the main thread's way repeats warns at itself as a one-off → the client's
  `ItemListMoveItems.moveItems`, `repairShareAttr`, `deleteItemInternal`'s `forEachChild`, `listFolder`'s per-child
  SQL and `listFolderCloudCallback` lost their owner warnings, and nothing said the I/O runs per item. A main-thread
  sink warning now says what repeats its call — the nearest repeating calls up its ways (`MainRepeats.climb`), or the
  call itself where it stands in a loop — in its message (`— repeated by <member> at <loop header>`) and as
  `FindingData.repeatedBy`, which the json record writes as `data.repeatedBy`; the warning a way's sink calls fold
  into carries what repeats each of them. No key is added for it (decision 2026-10-14): the repetition RANKS the
  call's own warning on the work list, it is not a second finding of the same I/O — branch `feat/ts-precision-3`
- a hold only a `quietRoots` function runs judged as the main thread's own long work → the client's Help-menu cache wipe and
  the MAS-migration handlers stayed family (b) warnings after their roots went quiet, so quieting a maintenance path
  silenced its sink calls but not the locks it holds across them. A hold whose take no loud thread runs (its context
  quiet only) is reported by no finding (b): the root waits on purpose, on the main thread, which never waits for its
  own hold. It still makes its lock long, as any main-only hold does — branch `feat/ts-precision-3`
- an `@:isVar` getter returning the member's own stored field judged through `holdsValues` → the member being judged
  counts as holding values while it is, so `get_mode() return mode;` answered "values" through its own cycle and the
  stored writes (`mode = d`, `d:Dynamic`) were never read. A getter return that reads the member's own field (bare,
  or off `this`) is judged by what the field holds (`ExhaustiveSwitches.storedHolds`): its initializer and every
  write of its name (review round 2 `ex1-isvar-getter`) — branch `feat/ts-precision-3`
- `ExhaustiveSwitches` reading what a member is assigned off a whole-project write index of its own → that index
  covered only the files of the run and asked nothing about the rest, so `hxq lint core` read a member as holding
  values while `plugins/P.hx` assigned it a `Dynamic`. The check reads the run's one `FieldWrites` index and answers
  "dead" only when it is `complete` (a `closedWorld` declaration over a run covering the project); `FieldWrites` no
  longer needs `LockSites` (`FieldWrites.ownMemberRead`), so it is built before the sites that walk the switches
  (review round 2 `ex3-partial`) — branch `feat/ts-precision-3`
- a parameter written as an enum abstract taken to hold only its values → an untyped value handed to it was the hole
  `ExhaustiveSwitches` took as absent, so `setMode(v:V) mode = v;` called with a `Dynamic` read the member as closed.
  A parameter now holds values only where every call of its function hands it one (`callersPassValues`): the function
  is the graph's at exactly its span, code outside the run cannot call it (`mayRunFromOutside`; a constructor
  excepted — reflection is the hole left), it is never handed on as a value, and each call's argument — the value a
  plain `=` assigns through a setter included — is a value, or, to an optional parameter (read only through `??`),
  `null` or an optional parameter of the caller passing the same. Haxe's skip-by-type is honoured: an optional
  parameter BEFORE the one read makes a short call unknown. A function nothing calls hands nothing. the client's
  `ItemList.reload` stays dead (its `?viewType` relays through `ItemList.new` into `ItemListPicker.new`). The
  default `0` of a counting abstract is a static target's (hxcpp); on JS an `Int` field starts `null` (review round 2
  `ex2-param-dynamic`) — branch `feat/ts-precision-3`
- a bare name in a `try` body read as a binding whenever ANY node of the function binds the name → a lambda's
  parameter `limit` elsewhere in the function made `limit` (a property whose getter throws) inert, and the `catch`
  around it dead. `DeadCatches.plainRead` takes a read as a binding only where the one declaration of the name is a
  parameter of the function itself or a local before the read in a block around it (`BareNames.localOf`); any other
  read is judged as the member (review round 2 `dc1-prop-shadowed-elsewhere`) — branch `feat/ts-precision-3`
- a `catch` judged an error path by the loops of its own function alone → a per-item loop one call up (`for (p in
  paths) load(p)` under a hold, `load` catching a failed parse and sleeping) still made the hold and the main
  thread's take info "only on an error path". Every turn of a repeating caller may fail, so the `catch` is a path of
  the normal run: the normal-path taint skips a `catch` only where no call on the way from the hold repeats
  (`LockTaint.leadsNowhere`, the walk's `repeated` flag — loops, values handed on to a call that may repeat them,
  recursion), and a main-thread sink call in a `catch` is error-only only where no repeating call up the main
  thread's ways runs it (`MainSinkReport.caughtOnce`, `MainRepeats.climb` owners). An ASSUMED root (no resolved
  caller) is not counted as repeating there. A loop is ONE definition, `CallRepetition.loopKindsOf`, read by
  `ErrorPaths`, `LockWindow` and `CallRepetition` (the same five Haxe kinds the three derived separately). Not
  fixed: a hold's taint never walks a value handed on (`Lambda.iter(paths, load)` under the lock), base included,
  so `ep1b-iter-in-caller` stays silent under a hold — the taint follows invocations only (review round 2
  `ep1-loop-in-caller`) — branch `feat/ts-precision-3`
- a `boundedRepeats` `loop` label re-bound by its header alone, and a loop's rank counting every loop of its header →
  a loop added later with the same header (`for (i in 0...n)`, now running `xs.length` times) silently took the
  bound written for the first, and an unrelated loop that blocks nothing (`for (x in xs) n++;`) moved the rank, the
  label and so the KEY of the repeat warning it names. A loop's rank now counts only the loops of its header that
  repeat a call which may block (`Loops.labelOf`, `repeatsSink`), and a `loop` written with no rank that names
  several loops binds none, with a notice asking for `#1` / `#2` (`CallRepetition.bind`). Bounds in different
  functions on one way MULTIPLY (`CallRepetition.along`: 40 × 40 turns are 1600, over a 50 ms budget though each
  bound alone is under it) — down the main thread's ways (`MainRepeats.climb`) and under a hold (`LockTaint`'s walk,
  `WalkFlags.way`) alike; a short call run as once by bounds alone names them in its note, and a short hold under a
  chain that lists `boundedRepeats` says so (`CostNote.ShortBoundedHold`), never "none in a loop". The loop
  definition, labels and header spelling live in `Loops` (one normalisation, `Loops.spelled`, for labels and
  entries) (review round 2 `br1-a`, `br1-b`, `br2-nested-entries`, `ks2-a`, `ks2-b`) — branch `feat/ts-precision-3`
- a bare `runsOnce` name trusted for any call written with it → `"runsOnce": ["success"]` (meant for a library's
  promise callback) made a project `Batch.success`, which runs its value once per item, count as once, so the
  per-item request under it went info. A bare name now speaks for the runtime's calls only — the guard
  `registers` already had (`CallRepetition.runtimeCall`): a call resolved to an external or body-less function, or
  an unresolved one where no function of the run with a body bears the name. A `Type.member` entry stays the
  project's word on that member, and only a dotted entry yields ids (`runsOnceIds`). The unresolved half applies to
  `registers` too (review round 2 `cr1-runsonce-project`) — branch `feat/ts-precision-3`
- a repeat warning's subject for a value handed on named only the call it was handed to, and a sink warning's
  message spelled where it repeats (`— repeated by M at <loop header>`) → two `Lambda.iter` in one member shared ONE
  key, and a loop header rewritten or re-ranked in another file changed the message of a finding elsewhere, so
  `--baseline` / `lint-diff` churned. A value handed on is ranked among the values its function hands the same call
  that may block (`CallRepetition.handLabel`, `Lambda.iter #2`), as loops are ranked; the message names the
  repeating MEMBERS only (`MainSinkReport.repeaters`), the headers stay in `data.repeatedBy`, and the suffix is
  written last, on warnings only (review round 2 `ks1-two-iters`, `rb1`) — branch `feat/ts-precision-3`
- a helper's lock-call sites keyed by their start offset (`WrapperOps.lockTrafficOnly`) → a chained receiver
  `me()._b.release()` starts where `me()` does, so the blocking `me()` passed as lock traffic and the helper's caller
  held `_a` across it unreported. Every lock-call key is the whole span (`LockReleasers.callKey`, shared with
  `blindIn`) (review round 2 `h3`) — branch `feat/ts-precision-3`
- a worker's origin flowing along every edge whose UNION context carries a background bit → a worker running
  `f(false)` was taken to run `g` (which only `f(true)` calls, on another worker), so `g`'s hold "ran on both" and
  covered `h`'s on the first worker. Origins now walk the states: the valuation the worker hands down decides each
  call (`ThreadStates.workerStep`, `EdgeConditions.carried`) (review round 2 `s2`) — branch `feat/ts-precision-3`
- a `Site` cover comparing `FoldHold.lock`, the pair's take member for a lock no member names → every unnamed lock of
  a pair ("`Mutex.acquire`") was "the same lock", so `g` holding `getA()`'s mutex covered `h` holding `getB()`'s across
  the same sleep. An unnamed lock is never the same lock for the cover (`RootCauseFold.sameLock`); the `Waits` cover
  keeps the pair key, where requiring every unnamed hold of the pair to be reported is a superset of the real one
  (review round 2 `u2p`) — branch `feat/ts-precision-3`
- `LockTaint.onCycle` following invocations only → a recursion through a callback that runs (`n.each(k -> walk(k))`)
  was no cycle, so a whole-tree walk under a lock counted as once and a hold reaching the same sleep once covered
  it. The cycle walk now follows values handed on that run where they are handed (`ThreadStates.runsFrom`, the one
  predicate `LockReleasers.runsFrom` reads too), never one a `spawns` / `marshals` call runs elsewhere or a
  `registers` call keeps for later — following registrations too made the client's UI listener graph exceed the walk bound
  and answer "cycle" for `VolumeWatcher.setTimestamp` and two `_batchMutex` holds. `lockTrafficOnly` needs no Ref
  clause: a value handed on runs only through a call, which its tree walk already counts as other work. The residual
  `covers` clause "same function" had no lock condition: two holds of DIFFERENT locks one after the other in one
  function (`f` holding `_a` then `_b` across the same `io()`) folded into one; now a hold covers another of its
  function only when it is the same lock, opened by the same call (a helper taking both), or spans the other's take
  (`RootCauseFold.nests`). The "way passes" clause stays as decided for `renameCloudFolderBlocked` (review round 2
  `r1`, `s1`) — branch `feat/ts-precision-3`
- a give "takes back what its function took" whenever a take of its lock runs on every path before it → a give in a
  loop after ONE take (`_outer.acquire(); for (i in 0...2) _outer.release();`) gave back a hold begun elsewhere on
  every turn after the first, yet `_outer` still dominated. A take covers a give only when the give does not repeat
  after it (`GiveFacts.repeatsAfter` = `CallRepetition.repeatedUnder`: a loop around the give that is not around the
  take, a hand-on, a recursion) (review round 2 `k1`) — branch `feat/ts-precision-3`
- `FieldWrites.mayWrite` ignoring an own write whose declaring type is not the field's owner → an interface's `var db`
  is declared again by its implementer, so `Fs.db = b` (in a lambda) never counted as a write of `IFs.db` and
  `fs.db.batchLock()` named one object for good; and `Reflect.setField(f, "db", b)` was no write at all. When the
  owner is an interface, every own write of the name may be one of it; a constant-named `Reflect.setField` /
  `setProperty` is a write of that name on a value nothing here can tell (`FieldWrites.recordReflective`). A
  COMPUTED name (`Reflect.setField(o, key, v)`) stays unseen — a known gap, as `RedundantIsVar` documents for the
  same reason (review round 2 `o1`, `o3`) — branch `feat/ts-precision-3`
- `ProjectCoverage` built from the files handed to the run → a project file that fails to parse is in the run but
  not in the graph, so its writes and calls were invisible while the run still "covered" the project and
  `closedWorld` held. Coverage is built from the files the graph HOLDS (`CallGraph.heldFiles`): a file the run
  cannot parse leaves the project uncovered, and the `closedWorld` notice now says either cause (review round 2
  `o2`) — branch `feat/ts-precision-3`
- the project a `closedWorld` declaration closes taken from the NEAREST document declaring it → a nested
  `core/apqlint.json` restating `closedWorld` became "the project", so `hxq lint core` covered it while
  `plugins/Plugin.hx` assigned the field a `core` hold reads. The project is the OUTERMOST document of the chain
  declaring `closedWorld` or `resolutionRoots` (`ProjectCoverage.declaringDocument`), and the `closedWorld` notice
  names it (`projectOf`). A scratch config nested in another project's tree now closes the outer project too —
  conservative: such a run is read as open (review round 2 `pc`) — branch `feat/ts-precision-3`
- config problems said only for a chain that reports (`lists.reports`), and `run` returning before
  `reportConfigProblems` when no sink matches → a typo or a wrong shape of `sinks` itself (`"sink"`,
  `"sinks": "Sys.sleep"`, `[{…}]`) or a `sinks` naming no call of the run printed "no issues". A chain writing ANY
  `thread-safety` option is now scanned (`skipReason` gates only a chain writing none) and every problem of it said;
  a `sinks` written and lost says "lists no call", one matching nothing says so with its entries, and a run no sink
  matches still returns its notices; the rule drops its own findings in a file whose chain lists no sinks (`run`),
  the gate `skipReason` used to be. A chain writing no `sinks` on purpose (one that only shapes the graph) says
  nothing of it. A mistyped `enabled` / `severity` is a value of the wrong shape, not an unknown option. The old
  control "a malformed option of a non-reporting chain is silent" is reversed by this decision (review round 2
  `cfgA`–`cfgE`) — branch `feat/ts-precision-3`
- `sinks` a config-only list → a blocking call a project forgot to list was invisible, silently (client lacked
  `FileSystem.exists`, `isDirectory`, `nativeSetTimestamp`, `Sys.command` until they were added by hand). The sinks
  are now POSITIVE: the grammar names the runtime's blocking calls (`ExecutionShape.blockingLibraryCalls`, verified
  against the Haxe 4.3.7 std: `sys.io.File` / `FileInput` / `FileOutput`, `haxe.io.Input` / `Output` — a stream of
  unknown kind is read as one that blocks — `sys.FileSystem` but `absolutePath` (its cpp body is `Sys.getCwd` and a
  join), `Sys.sleep` / `command` / `getChar`, `sys.io.Process`, sockets, `Host` construction and `reverse` (not
  `localhost`: `gethostname`), `sys.db`, `sys.Http`, the `sys.thread` waits) and they apply wherever the rule runs,
  on a target the run holds no body for — a project function of the same name is read through its body; `sinks`
  ADDS; a new string-list key `nonBlocking` (named like `nonThrowing`) WAIVES one, each entry `"<pattern>
  <evidence>"`, an entry with no evidence dropped and said, one waiving nothing said, one naming a `sinks` call
  said and kept. The `sys.thread` waits are IN the set although the lock analysis grades takes: it grades only a take
  that is a sink (`LockTaint.blocks`), and `lockPairs` then narrows it to "long only when the lock is long", so a
  project writing `lockPairs` but no sink would have lost every main-thread take; a wait with no pair (`Lock.wait`,
  `Deque.pop` — `pop(false)` cannot be told from `pop(true)` by the graph) blocks every time. The project's own
  NATIVES block too (`ProjectNatives`, positive: an unknown native blocks): a body-less member of a project `extern`
  type, a `@:native` / `@:hlNative` / `@:functionCode` member whatever its stub body (the client's `nativeSetTimestamp` has one),
  a member a native loader initialised, `untyped __cpp__` / `__global__.f` and `cpp.Syntax.code`; a site with no
  node of its own gains an edge into a node standing for the native, its unresolved record kept. A LIBRARY's externs
  and natives stay calls of library code — measured on the client corpus 1d1ba147: 3108 main-context call sites into non-builtin
  library externs / native bodies, 2511 of them the std's memory primitives (`Array`, `String`, `Math`, `Std`), so
  sinking them would bury the list; the decision is the orchestrator's. A chain writing ANY option reports
  (`reports = declared`), and one `info` per run says the set applied with its size. client: dropping the 22 `sinks`
  entries the builtin covers leaves the json report byte-identical on all three frozen trees — branch
  `feat/ts-precision-4`
- a hold's taint following invocations only → a lock held across `Lambda.iter(paths, load)`, `load` blocking, was
  silent (review round 2 `ep1b-iter-in-caller`, base 338efc41 included), and so was every lambda handed on under a
  hold; the main thread never reached a sink handed on as a value (`Lambda.iter(paths, File.getContent)`). The hold's
  window now carries the values handed on there (`Ref` edges), and ONE predicate, `ThreadStates.runsHere` — the one
  `LockTaint.onCycle` used since FIX2 item 12, moved out of it — says which run under the hold, in the window and at
  every step of the walk (`LockTaint.reach`): a call, or a value the call it is handed to runs there, library or
  project, a call the graph resolves to nothing included (unknown = runs), never one a `spawns` / `marshals` call runs
  on another thread or a `registers` call keeps; a value enters its target knowing nothing of its parameters
  (`EdgeConditions.entered`), and repeats as the call it is handed to repeats it (`CallRepetition.handedOn`, so
  `Lambda.iter` repeats and a `runsOnce` call does not). A sink handed on as a value blocks wherever it runs
  (`LockTaint.blocks` asks `ThreadStates.runsFrom`), which is all finding (a) needed: `MainSinkReport` reads every
  edge `blocks` admits, and the main-thread climb (`MainRepeats.climb`) already followed values handed on — a short
  sink reached only through `Lambda.iter(paths, one)` was owned by that call before (probe `main-ref-short`). Another
  object's method handed on is no re-take of the holder's re-entrant lock (`retakesElsewhere`). Two readers of the
  window keep the calls alone: `HoldGrade.handsOff`, so a value that may give the lock back proves no give and the
  hold stays handed off (the long answer); `LockOrder` never looks a value's site up. The walk has no bound to hit: it
  is a memoised breadth-first walk over finitely many states, and `onCycle`'s `CYCLE_WALK` bound — whose answer when
  hit is "may lead back", the repeating one — was never reached on any of the three client trees (counted with a traced
  engine). client: every score row identical, no warning key new, lost or moved; one info key per tree (B
  `ItemList.reload|VolumeWatcher._mutex`, a main-only hold whose long call finding (a) reports); runtime unchanged
  (15.7 s → 15.8 s, three trees) — branch `feat/ts-precision-4`
- a call into a library with a Haxe body ends the graph, so blocking I/O inside lime/openfl (T1: 4852 main-context
  sites on the client corpus 1d1ba147) is invisible → EXPERIMENT, opt-in `libraryBodies` (`LibraryBodies`, `LibraryBuild`): the
  option names ONE `compilerOracle` entry's hxml; its library classpaths (every `-cp` holding no run file, every
  `-lib`) are read under its defines read off the hxml with no compile (the `-D`s, a dash read as `_`; the entry's
  `defines`; the target's own; `haxe`/`haxe_ver` from `haxe -version`), every branch they do not compile blanked
  (`ReachLiveness.skippedOf`, closed world), a file of another target's package / suffix or one its target's copy
  stands in for left out, and walked as a graph of their own — a SUMMARY, not a merged graph: the run's graph and its
  contexts are unchanged, each external call whose library member reaches a library sink (natives as `ProjectNatives`
  reads them, the runtime's blocking calls, `sinks`, less `nonBlocking`) through calls, overrides and values handed to a
  call that runs them there becomes a sink of the chains writing the option, so a finding stays keyed
  `A|<project function>|<library call>` and `data.chain` goes on to the library sink; a project type's call runs its
  nearest library superclass's member and no library override. Off by default (client: byte-identical reports on the three
  frozen trees). MEASURED on the client corpus 1d1ba147, mac-release defines, 1119 library files (lime, openfl, swf, actuate, mime,
  hx4compat, a video extension, a file-dialog extension), 4 unparsed (AS3 leftovers in swf): with every library
  native and wait as a sink (the positive default) 473 new warning keys, 0 of a 40-key sample real-long (17 reachable but
  no I/O — openfl's cpp `ObjectPool` mutex, `ImageDataUtil` prims, `System.getTimer` — and 23 false paths); with only
  the file / network / process / dialog prims as sinks (non-I/O natives, waits and target code waived for the
  measurement on both sides) 366 new keys, ~12% real-long (TextField layout → `TextEngine.findFont` → `Font.fromFile`
  opening a font file for an unregistered or default font; openfl `File` stats; `Lib.getURL` → `Sys.command`), 87%
  false: a constructor branch on a static only stage construction sets (`DisplayObject.__initStage`, 185 keys), an
  event-type branch (`TextField.__dispatch` opens a URL only on a link click, 71), an argument the call never passes
  (`Font.enumerateFonts()` reads the font directory only for `true`, 59), dispatch to a library subclass the receiver
  is not (`DatagramSocket`/`SWF` overrides, `Stage.__dispatchEvent`), a simple-name collision (`swf.runtime.Shape` for
  openfl's). It MISSES the loaders themselves: lime/openfl locals are un-annotated (`var symbol = new LibrarySymbol(id)`)
  and `import lime.utils.Assets as LimeAssets` is unresolved, so `Assets.getBitmapData` never reaches
  `lime_image_load_file`. The loader list as plain `sinks` (B) gives 50 new keys, 20 of a 40-key sample real-long
  (`getBitmapData`, `getText`) and 20 no I/O (`getMovieClip` on `preload="true"` SWF libraries, embedded `getFont`).
  Cost: thread-safety alone 4.65 s → 7.27 s (+56%, 655 → 996 MB), the plain lint 22.0 s → 25.0 s (+13–15%), all of
  it the rule's library work (parse 1.2 s, graph 0.5 s, defines 0.2 s, walk 0.1 s); B costs nothing measurable. The
  choice between A and B is the user's — branch `feat/ts-precision-4`
- the lock-order walk following invocations only → a lock taken inside a value handed to a call that runs it
  (`Lambda.iter(paths, p -> b.acquire())`, or a method value taking its own lock) under a hold of another was taken
  under no hold, so an AB/BA pair one side of which takes its lock that way went unreported. `LockOrder.visit` now
  follows the edges `ThreadStates.runsHere` says run there — the one predicate the hold window, `LockTaint.reach`,
  `blockingTrail` and `onCycle` read since dfb52d4a — entering the value under the locks held at the call it is
  handed to, knowing none of its parameters (`EdgeConditions.entered`); a value a `spawns` / `marshals` call runs on
  another thread, or one a `registers` call keeps, stays a callback entered holding nothing. Additive: the entry and
  callback seeding is unchanged, so every state the walk had stays and no step is lost. The same predicate means an
  UNLISTED call is taken to run the value in place — the old control `Ui.defer(takeB)` now declares `Ui.defer` in
  `registers`. Since runsHere over-approximates (a value handed to a project constructor that only STORES it is taken
  to run there), a pair's WITNESS ranks a step — and a way into a state (`climb`) — through calls alone before one
  through a value handed on (`Climb.handed`, `RankedStep.handed`), so a pair the old walk reported keeps its key: client
  bd943dac otherwise moved two real-long D keys onto `ItemList.reload`, whose handed `_source.getThumbnail` is stored
  by `new ItemListTile` and runs only after the hold (`ItemListItemTile.requestThumbnail`). Audit of the other lock
  analyses, each walking invocations only on purpose: `LockSites` (its window carries `Ref` edges since dfb52d4a; the
  wrapper / multi-lock-helper inference refuses any function with a `Ref` in-edge, `mayWrap`, so a value's take is a
  hold of its own), `MustHeld` (a function with a non-inert `Ref` in-edge holds nothing on entry — an under-approximation,
  sound for a must-analysis), `LockDominance` (reads `MustHeld`), `HoldGrade.handsOff` (a handed value that MAY give
  the lock back proves no give; keeping it out keeps the hand-off reported). Not followed: a lock primitive handed as a
  value itself (`Lambda.iter(ms, Mutex.acquire)`), never a take for `LockSites` (takes are `Call` edges). client: bd943dac
  byte-identical; 1d1ba147 and f81c2049 +2 D keys each (`ItemList.reload`, the stored thumbnail getter), labelled
  `false` — branch `feat/ts-precision-4`
- duplicate root causes on the client corpus 1d1ba147 (truth: 20 warned keys `dup-of` another warning) → fold only where the
  covering warning provably names the same blocking work. Three gaps, each with a positive criterion: (1) the two
  holds one call of a multi-lock helper opens (`acquireMutationLocks`: `_batchMutex`, then `_mutationMutex`) span the
  very same calls, yet `nestHolds` only turned a hold taken INSIDE another's window — and a helper pair's take edge is
  the same call, never inside the window; it now also turns the hold the helper takes later (`takenFirst`, by the
  helper's take order — the outer lock keeps the warning) when its long calls are the outer window's, naming it;
  (2) `RootCauseFold` read the helper twin's give (`releaseMutationLocks`) as a crossing release, so any wait for
  `_mutationMutex` / `_batchMutex` was `Uncovered`, though `solveLongLocks` never counts such a give as making a lock
  long — the fold now gets the same crossings the solve does; (3) a hold waiting for a lock some hold makes long with no
  finding reporting its work (the client's `listFolder` on the tree lock) can never fold, yet stayed open into the cycle pick,
  which then kept `acquireMutationLocks` (fewest calls, first by place) instead of the `_mutationMutex` holders it
  would have folded onto; such a hold is now kept from the start (`uncoverable`, `neverReported`). client 1d1ba147: dup-of
  20 → 15 (5 folded, `renameItemInternal`'s pair swaps which lock warns: both `dup-of`), precision 0.71 → 0.74, recall
  84/84; f81c2049 and bd943dac: no warning key changes. KEPT, no positive criterion: a callee re-taking the hold's own
  lock (`if (!batch) _batchMutex.acquire()` — the graph cannot tie the object, and the one trail computed through the
  call leaves its other work unexamined — that the call re-takes nothing is an argument value, `dbBatch = true`, the
  graph does not track); a hold on threads the covering one never runs on (`getModelsWatcher`); a
  different sink call site (A family: an argument value, a virtual dispatch, the release half of one hand-off); a
  representative the engine already keeps for the truth's target (`Store.removeKeys` over `Store.put`, threads
  superset) — branch `feat/ts-precision-4`
- a reflective write of a COMPUTED name unseen (`Reflect.setField(o, key, v)`, the gap the constant-name entry above
  left) → a field another code path rewrites by name stayed stable for `ObjectPaths` and sealed for `AllocationSets`.
  `FieldWrites` now files a computed-name write under every name (`of`), reads the `using Reflect` extension form
  (`o.setField(key, v)` — any call of that shape and arity; it cannot tell a `using` from a method so named, and
  over-counting only unsettles) and `deleteField`, and takes `o[key] = v` into a value declared `Dynamic` /
  `DynamicAccess` as a reflective write. Each reflective write is bounded by its target's DECLARED type (`reachOf`):
  a class or interface declared once → it, every subtype, and every type on the chain of each (the object is one of
  them; its fields are declared along its chain); anything else — `Dynamic`, `Any`, a type parameter (also one named
  like a class), a structure or an abstract (a value of any class may be one), a library or unknown type — reaches
  every type. No narrower bound is sound without tracking which objects flow into a dynamic value; the cost falls only
  on the fields a consumer asks about (lock paths, dispatched receivers, switch subjects). A reflective write is no
  respecter of `final`: `ObjectPaths.stable` holds a `final` stable only while none may reach it (client: same reports with
  and without that half). the client's three any-type writes (`model.Node.toTarget`: `targetObject:T`; `Node.snapshot` and
  `Form.get_data`: a `Dynamic` local) unsettle every field: 1d1ba147 +1 C key (`ItemList.reload`, the `viewType`
  switch no longer provably exhaustive), 1 B key info → warning, both already labelled; f81c2049 / bd943dac 1–2 B
  warnings fold to info. NOT covered: a reflective write a run that does not see the whole project leaves out (a
  `final` stays trusted there, as before), a reflective writer reached by another name (`final set = Reflect.setField`),
  an index write into a container whose type the declarations do not say, and the lock-member sealing of `LockSites`
  (`collectUnsealed` reads only syntactic occurrences of the member's name) — branch `feat/ts-precision-4`
- a hold folded from ONE blocking trail (review round 4 `f1`): `RootCauseFold` read each long call's reason off
  `LockTaint.blockingTrail`, the first way its walk finds, so a call reaching a sink another hold covers AND, deeper,
  one nobody covers folded, and nothing named the deeper sink (client r5 configs: `VolumeWatcher.saveContent|_mutex`).
  Now every blocking call a long call reaches is a reason (`LockTaint.blockingEnds`: an exhaustive walk over the same
  states — the root and per-call steps `rootsOf` / `stepOf` are shared with `reach` — keeping no answer across calls;
  states are finite, so no cap and no unexamined trail): the shortest way, repeated or may-repeat on ANY way, and the
  functions EVERY way passes (dominators over the walked states), which the "a hold on the way" cover now needs. The
  covering side stays the work a finding NAMES — the first way of each of its calls — since a warning shows no other
  way: with every reached sink as covering work instead, 1d1ba147 folded the recall entry
  `RemoteDiskSystemBase.setTimestamp|_mutationMutex` onto `StandardDiskSystem.getText`, whose message names a
  different stat. A kept warning appends the sink calls it stays for that its first ways do not show and no warning
  covers (`— its calls also reach …, which no warning names`). client: 1d1ba147 +4 B warning keys (`Store.put` rare,
  `Store.remove`, `DiskSystemBase.removeCloudQueue`, `RemoteDiskSystemBase.addCloudActionValidated` dup-of, all
  labelled), `acquireMutationLocks|_batchMutex` warning → info (dup-of); f81c2049 / bd943dac +2 / +3 B warnings; recall
  full; ~25 B warnings per tree gain the note.
- the fold onto a main-only "elsewhere" maker, stated (review round 4, point 1): a wait for lock K counts as covered
  when every hold making K long has its work reported — a warned maker kept or folded, OR an info maker whose finding
  names (a) warnings for its work (`FoldHold.elsewhere`: a hold only the main thread runs, its long work reported at
  finding (a)). The second half is sound for a reason the general rule does not give: the main thread inside such a
  holder cannot also be waiting for K there, so the waiter's stall under K is the holder's own main-thread work, which
  (a) reports; an inversion between the two locks is finding (d)'s. the client's `RemoteDiskSystemBase.setTimestamp` and
  `DiskSystemBase.moveLocalQueue` fold onto `StandardDiskSystem.listFolder` this way.
- a handed value took a way's warning (review round 4 `f10`): `runsHere` reads a value handed to an unlisted call as
  run there, and `new Later(File.getContent)` only stores it, yet `MainSinkReport.oneWarningPerWay` kept the first
  sink by offset — the handed one — and demoted the call the function makes itself. A call the function makes itself
  now keeps the way's warning before a sink handed on as a value; repeating owners at one distance rank a way through
  calls alone first (`MainRepeats`), as T2b ranks lock-order witnesses. Merged `repeatedBy` still follows the folded
  handed value onto the kept warning (it may run the value repeatedly; positive).
- a silenced finding as a cover (review round 4 `f2`): `// noqa` on the warning another hold folded onto left that
  stall named only by an info. `Suppression.silencer` (the predicate `apply` now uses) tells the check which of its own
  findings will be shown: a silenced warning covers no hold's work (`RootCauseFold`), makes a hold waiting for its lock
  stay, turns no hold inside or enclosed by it info (`nestHolds`, `foldEnclosed`), keeps no way's or lock's main-thread
  warning while another can stay, and reports no work for a main-only hold. Not covered: a finding a file's config
  disables or remaps (`Linter.gatedPerFile`), which the check does not see.
- review round 4 text nits: a hold turned info onto a finding that ended info itself says so (`INFO_COVER_NOTE`; T3's
  "whose finding names these calls" read as a warning); the warning a lock's main-thread takes fold into carries what
  repeats each folded take (the client's `Store.get` names `Main.reboot` again, lost when `Store.remove`'s take turned long) —
  branch `feat/ts-precision-4`
- a library type keyed apart from a project type of its simple name (review round 4 `f7`): the call graph keyed every
  type by its simple name, so `l:sys.thread.Lock` beside a project `extern class utils.Lock` called the project's
  native, and a waiver of that native (`nonBlocking: ["utils.Lock.wait …"]`) silenced the runtime's wait on main.
  Making `SymbolIndex` and every graph table package-aware was the full fix and touches every consumer; instead a type
  is keyed by its PATH only where it collides — written dotted, or bound by an import or an alias of the writing file,
  while a project type of that simple name lives elsewhere (`CallGraphImports.typeOf` / `pathType`) — so every id and
  config pattern of a project without a collision stays as it was (client: no import of a library path whose simple name a
  client type bears; reports byte-identical in that respect). A pattern finds a keyed node by its path or its simple name
  (`keyedIds`, `matchIds`). The resolution reads the writing file's imports for that file's own declarations only; a
  member type written by its simple name in ANOTHER file stays merged — hence the backstop: a `nonBlocking` entry naming
  a project native whose id is a builtin call's name is kept and said (`PositiveSinks.shadowing`), since a library call
  the graph cannot tell apart may resolve there.
- std signatures for receivers (review round 4 `f4`): `Sys.stdin().readLine()`, `socket.input.readLine()` and an
  unannotated `final h = new sys.Http(…)` left their calls unresolved, and `import sys.io.File as F` made `F.getContent`
  an unknown node. Reading the lint run's resolution index (std plus every `resolutionLibs` haxelib) was considered and
  refused: a thread-safety-only run would parse all of the client's twenty libraries, and it would type openfl receivers the
  question did not ask about. `StdTypes` reads the std core only (the toplevel, `haxe/`, `sys/` — the same core
  `StdResolver.resolutionSpecs` joins to the resolution scope), one module at a time on demand, by simple name like the
  graph, answering only where every std type of that name that declares the member says the same thing (type, accessors).
  The graph asks it for a placeholder's return type, a field's type on a type the project does not declare, and a
  property's getter — the last on a local or parameter receiver, or on a receiver the graph types, when the name is no
  project property. Import aliases go through `typeOf`; a `new T(…)` initialiser types an unannotated local (the static
  type Haxe infers). Limits kept: a local initialised by any other call stays untyped; `"resolutionStd": false` is not
  seen by the graph (`APQ_NO_STD` is), as for `HaxeQueryPlugin.knownExtensionMethods`. Builtin set +6:
  `UdpSocket.readFrom` / `sendTo`, `EventLoop.loop` / `wait`, `Thread.runWithEventLoop`, `ResultSet.get_length` (the
  cpp getter steps every row). client: 1d1ba147 +2 A warning keys, both rare (`QuietExit.exit|Output.flush` taking the way
  from `untyped.__cpp__`, `LanguageManager.t|Output.writeString` under `#if reportkeys`), +2 info keys (dup-of); f81c2049
  +2 / bd943dac +1 warning keys of the same two; recall full on all three.
- config text (review round 4 `f8`, `f9`): `libraryBodies` names the `-lib` haxelib cannot resolve and the `-cp` that does
  not exist instead of walking nothing in silence; the builtin notice counts the sinks the run's `nonBlocking` entries
  removed and the entries that removed one.
- the shared-graph change measured beyond the rule (FX2): full `hxq lint src --no-oracle` on the three client trees and on
  anyparse's own `src`, engine before vs after — every changed finding is a thread-safety one (the keys above, three
  messages re-rendered with the same-way calls the std receivers add, one uncovered-call count); no other rule moved, and
  anyparse's 2311 findings are identical. Time on the client corpus 1d1ba147 (median of 3): all rules 22.69 s -> 22.63 s, thread-safety
  alone 9.81 s -> 9.85 s — the std modules are read lazily and only a handful are asked for.
- the T4 cost (FX3): `--rule thread-safety` on the client corpus 1d1ba147 went 4.75 s -> 9.97 s (median of 5) with the computed-name
  reflective writes. Profiled, not guessed: none of it was the reach consumers (`of`, `mayWrite`, `ObjectPaths.stable`
  together ~0.02 s) — `FieldWrites.typeOf` asked `CheckScan.typeNominalResolver`, which builds the std + library
  resolution index on first use (5.0 of 10.8 s). `typeOf` now resolves through an index of the files the graph holds
  (`heldIndex`, built once on demand; `typeNominalResolver`'s new `resolution: false`). Checked side by side before the
  switch: every FieldWrites query answered the same under both typers (client 174/171/167 queries, the fixtures 1776), and
  the reports are byte-identical on the three trees and all 315 fixture runs; 9.97 s -> 5.82 s (a second session,
  median of 5 each: 3599e65b 5.01 s, 01ed3fe1 10.17 s, this fix 5.54 s, with the F3 / F11 entries below 5.60 s). What the narrower index
  loses — a member chain through a LIBRARY type — costs precision only once an index write into an unknown container is
  itself a reflective write (below). The remaining ~1 s over 3599e65b is FX1's all-ways walk and FX2's std typing.
- lock-member sealing vs reflective writes (review round 4 `f3`): `Reflect.setField(this, "_l", _m)` makes `_l` the lock
  `_m` is, yet `_l` stayed sealed, so the main thread's take of it waited for nothing. `LockSites.collectUnsealed` now
  unseals a lock member a reflective write may store a value in (`FieldWrites.reflectivelyWritten`): one filed under its
  name (a literal, on any value), or a computed one whose reach holds a type declaring the member on its chain. A
  computed name on a value of NO known class (`Dynamic`, `Any`, a type parameter: `reachOf` null) is deliberately not
  counted, and the run says so in one `info` naming the functions (`FieldWrites.notices`). Counting it was built and
  measured: the client's `Node.toTarget` (`targetObject:T`), `Node.snapshot` / `Form.get_data` (`Dynamic` locals) and
  `ShareGuestStore`'s enum-binder maps make every lock member of the client corpus hold any lock, so no lock keeps its name — 1d1ba147
  153 -> 225 findings and 37 of 102 recall keys re-keyed to the lock's class (f81c2049 0/5, bd943dac 1/9). Bounding
  those writes soundly needs the objects flowing into a `Dynamic` value or a type parameter (`Node`'s `T` is set through
  `cast` writes and `Type.createInstance(Type.resolveClass(name))`); left open, said in the run.
- reflective-write escapes (review round 4 `f11`): `DynamicAccess.set` / `remove` on a value declared `DynamicAccess`;
  `Reflect.setField` / `setProperty` / `deleteField` read as a VALUE rather than called (`final set = Reflect.setField`,
  `o.setField` under a `using`) — a computed-name write at the read, of any type off `Reflect`, of the receiver's as an
  extension, since where the value is later called is not tracked; and an index write `o[k] = v` into ANY value not
  declared an array, a map, a vector or a byte buffer (`ELEMENT_INDEXED_TYPES`, a positive list) — `untyped c[k]`
  (bounded by `c`'s class), `(cast c : Dynamic)[k]`, an enum binder whose type the declarations do not say. client: reports
  byte-identical but for the new notice (its any-type writes already unsettled every field); fixtures: the four review
  escapes warn, nothing that warned stopped.
- names a wildcard or a guarded import binds (review round 5 `N1`): beside a project `utils.Lock`, `import sys.thread.*;`
  or `#if sys import sys.thread.Lock; #end` left `Lock` keyed as the project type — `CallGraphImports.typeOf` read only
  unguarded explicit imports — so the runtime's `wait` went silent. A wildcard of a package now binds a name the project
  or the std core declares there (`StdTypes.declaresModule`), in the order Haxe searches (own module, explicit imports,
  wildcards last first, then the package — checked against the compiler); a guarded import or wildcard, or a wildcard of
  a package neither holds (a library's), MAY supply the name, so a call or a `new` on the type the file keys runs every
  candidate (`alternateTypes`). The candidates are read off the FILE, not the value: carrying a candidate list on every
  declared type, receiver and type source was the alternative, for a shape client does not have (all-rules reports
  identical on the three trees); the price is that a value of that type the file did not write takes the candidates
  too. Method values and member chains through such a name still use the first candidate only.
- dotted patterns (review round 5 `N3`): `pkg.Type.method` / `pkg.Type.*` also matched the bare simple name, so
  `nonBlocking: ["sys.thread.Lock.* …"]` waived the project native `utils.Lock.spin`. A pattern written with a package
  now names the type declared at that path alone (`CallGraphImports.pathKey`, `memberIds`, `typeKeys`): a project path
  is the simple key, any other path the path key while the project declares the simple name elsewhere. The old "matches
  by its last two segments" is gone for a package that is wrong — such an entry now matches nothing, said only for a
  `nonBlocking` entry (and a `sinks` list matching nothing at all); the client's four configs: all-rules reports identical.
- a local initialised by a call (review round 5 F4 residue): `final i = Sys.stdin(); i.readLine()` left `i` untyped. A
  local written with no type whose initializer is a call holds what `typeSourceOf` reads for that call — the reading a
  call receiver already got (`CallGraphKeys.callInitializers`, `throughInitializer` against a cycle). Any other
  initializer (a field read, a ternary) stays untyped — branch `feat/ts-precision-5`
- a computed reflective write on a value the run places on no class (review round 5 F3 middle ground + N2): it was NOT
  counted against the lock names ("names no lock at all" on the client corpus), so a value of a known class the typer missed —
  `owners.first()` off a `List<D>`, `arr[0]`, an un-annotated local of a library call, an enum binder `case Holder(d)` —
  left `_l` sealed and the stall silent. Now the SOUND default: such a write unseals every lock member
  (`FieldWrites.reflectivelyWritten`), named in an `info`; the exclusions are POSITIVE (`ReflectiveReach.placeOf`), each
  named with its reason: a `final` local bound to `{}` (reaches no class: whatever it escapes to, the write lands in that
  structure — escape does not matter, the binding cannot change) or to `new C()` (`C`'s chain); a `case` capture typed by
  the parameter of the one indexed enum constructor of its name (`binderType`; two enums declaring it type none); a type
  parameter bounded by its constraint, or a class's own under a covered `closedWorld` by its instantiations — each
  subtype's `extends` binding (written type / `Void` none / own param by constraint / free), the class and every free
  subtype never made (no `new`, name read as no value except as a static receiver, `reflectiveClasses` declared alike by
  every file and not naming it; the project's declaration, S15, covers library producers too). Trust level unchanged: a
  declared `T` is the instantiation's as a declared `D` is a `D` — a cast or a `Dynamic` view (`Node<Any>`) is the same hole
  every declared type has. MEASURED on the client corpus 1d1ba147 (score): full sound default 65/102 (f81c 0/5, bd94 1/9); fresh `{}`
  clears `Form.get_data` and `Node.snapshot`, binder typing `ShareGuestStore.getAllSharedUsers` (its `MIXED(folders, …)`
  captures are `Map`s: element writes), the type-parameter bound `Node.toTarget` — any one left unplaced costs the whole
  37 (one unplaced writer unseals every lock). With all four: rows == start (102/102, 5/5, 9/9). Two pre-existing holes
  the bound needed closed: a `final class`'s written supertypes were lost (`SymbolIndexBuilder.collectSupertypesWritten`
  read only the `FinalDecl` wrapper's children: `EventNode`/`LearningNode extends Node<Void>` had no argument), and a class
  extending a typedef alias was no subtype of the aliased type (`CallGraphTypes.merge` now files it there too).
  `CallGraph.typeParamBoundsOf` sees an enclosing function's parameter from a lambda, answers a type name, and takes
  `functionsOnly`. Precision side effect: the narrower reach sharpens `AllocationSets` (the client's `NetRequest2.urlLoader` no
  longer unknown), so 1d1ba147 loses the `false` info `StandardDiskSystem.listFolder|VolumeWatcher._mutex` and f81c/bd94
  turn `RemoteDiskSystemBase.setTimestamp|_mutationMutex` from a folded info into a warning — branch `feat/ts-precision-5`
- two calls of one hold reaching ONE sink by different ways (review round 5 R2 candidate, G3 — reproduced, pre-existing at
  aeeca953): `RootCauseFold.reasonsOf` de-duplicated the hold's `Site` reasons by key, repeat and named-ness only, keeping
  the FIRST call's way, and `covers` reads that way (`way.contains(by.hold.edge.from)`). So `outer { _a: f(); g(); }` with
  `f` holding `_b` around `g`'s read folded `outer` onto `f` ("long only through work D.f also holds a lock across") although
  its direct `g()` holds `_a` across the read outside `_b`; written `g(); f();` it warned. R2 could not reproduce it because
  with the lock's take itself a sink, `f`'s first way ends at the take, so its read is an UNNAMED reason and the two never
  compared equal; with the take only a `lockPairs` entry — the client's `Mutex.acquire` — both are named. Now `subsumes`: a reason
  is dropped only when the kept one's way is a SUBSET of its own (then it is covered whenever the kept one is: `covers`
  reads a way only by `contains`); otherwise both stay and each needs its own cover. A folded finding then says each
  covering part once (`turn`): two ways to one sink name the same holds — the client's `ShardDatabase.addCloudAction3` info
  already repeated "work ShardDatabase.addCloudAction2 also holds a lock across" four times before this. MEASURED: score
  rows == start on all three trees, no severity or key change on the client corpus (messages only: more "its calls also reach (+N
  more)" ways, de-duplicated fold parts); fixtures lost 0, gained the target — branch `feat/ts-precision-5`
- R3 review of round 5 (H1, `round6/g2-bound`): `ReflectiveReach.neverMade` compared RAW names, so `typedef NA = Node<D>;
  new NA()`, `Type.createInstance(NA, [])`, `import pkg.Node as NN; new NN<D>()` and `Type.resolveClass("Node")` kept the
  instantiation bound of `Node.T` — `_l` sealed, the stall silent, the notice claiming the bound. Now every name a held
  file makes or reads as a value is resolved as its file means it (`namedTypes`: as written, the key an import / alias /
  wildcard binds it to, every key an `#if`-guarded import or a wildcard MAY supply, each through `resolveAlias`), a literal
  handed to any `resolveClass` call names its class, and a `new` of a name that resolves to NO type (`unresolvedMade`: a
  typedef alias of a name declared nowhere — its target may be an alias its own file binds — or a name nothing binds that
  the run declares nowhere and the std core at none of its toplevel modules: a type parameter, a type the run does not
  hold) may be an alias of any class, so it voids every such bound. What counts as BOUND is positive: a path written out,
  an import / alias, a `using` (it brings the type into scope, which `CallGraphImports` recorded only as an extension
  source: the client's `using haxe.io.Path; new Path(p)` was the first "unresolved" name), a guarded import or a wildcard that may
  supply it (a library type: a project alias would be declared, and supplied for sure). One walk per run, memoised
  (`madeTypes`). MEASURED on the client corpus: before `using`/guarded imports counted as bound, 12 openfl/sys names were "unresolved"
  and the bound fell (65/102); after, none, rows == start. Also fixed on the way: `StdTypes.declaresModule('', name)`
  looked up `.name` and so answered false for every toplevel std module — branch `feat/ts-precision-5`
- R3 H2 (`round6/g2-binder`): a `case` capture was typed by the ONE indexed enum declaring a constructor of its name, so
  a project `enum Mine { Some(o:Other); }` typed the capture of a library `Option<D>`'s `Some(v)` as `Other` — sealed,
  silent, and no notice named it. Now `ReflectiveReach.subjectEnum`: only when the switch subject is declared of that
  enum (typed as any value is, resolved through the file's imports and aliases to ONE type on every build) and the pattern is a top-level one of its arm (an or-alternative counts; a nested pattern's subject is
  the outer constructor's parameter, which nothing here types). A parameter written with the enum's own type parameters
  types nothing (`enum Gen<Other> { Hold(x:Other); }` read `x` as the class `Other` before — pre-existing). The binder is
  an exclusion like the others: `placedBy` = "a capture of `E.Ctor`, typed by its parameter", so the notice names it —
  branch `feat/ts-precision-5`. The old "two enums declaring the constructor type none" gate (arm `M-TS-BINDER-UNIQUE`)
  is gone with the name match: two enums of the SUBJECT's name merge their constructors in `memberOnChain`, whose
  `agreed` leaves a parameter they write differently untyped, so a `declarationCount == 1` guard there survived its
  arm (redundant) and was dropped
- R3 M3 (`round6/g1-dotted/wrongpkg2`): since G1 a `sinks` entry written with a package names the type declared at that
  path alone, so a wrong package matched nothing, silently, while another entry matched (the notice fired only for a
  whole list naming nothing). The loose last-two-segments match is NOT restored; instead each entry written with its
  package (dotted, lowercase first segment) that matches no graph id is said (`PositiveSinks.unmatched`). Plain
  `Type.member` entries are left out on purpose: a shared config's list names calls a tree does not make (27 existing
  tests run such lists), and a simple name was never narrowed by G1. On the client corpus this adds 9 infos: the option-B loader
  entries (`openfl.utils.Assets.getSound`, …) client never calls — true, and worth seeing — branch `feat/ts-precision-5`
- R3 M4 cheap part (`round6/frag`): one unplaced reflective writer unseals every lock member, and on the client copy with
  an 8-line `ReflectHelper.assign` recall fell 37 while the only pointer was a file-less info. Now each finding of a hold
  (B), a hold left on a throw (C) or a main-thread take (A) whose lock lost its member name says after its message
  which member and which writers (`FieldWrites.unsealedNote`, from `reflectiveWritersOf`), and the reflective notice
  counts the holds that lost their name and, beside an unplaced write, names the failed preconditions of the
  instantiation bound (`ReflectiveReach.lacking`: `no closedWorld over the whole project`, `no reflectiveClasses`; a
  partial run has its own notice). The note lives in `FieldWrites`, not `LockSites` (at its 50-member cap), and is
  computed from the writes, so a member unsealed by a hand-off AND written reflectively names the writers too — true
  either way. README: `reflectiveClasses` was documented as read only under `reachConfigurationsComplete`; G2 reads it
  under `thread-safety`'s covered `closedWorld` — the doc now says both — branch `feat/ts-precision-5`
- R3 M1 (`round6/g1-alt/cross-*`): a member's declared type was keyed in the READING file — `A.hx` importing
  `sys.thread.Lock` (plain, wildcard or guarded) declares `static var lock:Lock`, `C.hx` calls `A.lock.wait()`, and the
  call resolved to a project `utils.Lock.wait` that never waits (silent, pre-existing, wider than G1: it held for a
  field read in its own file too, `this.own.wait()`). Now every type a declaration writes is read through the imports
  of the file that wrote it, at READ time (the declared paths a key depends on are global and grow with the graph):
  member types (`CallGraphImports.memberFilesOf`), returns and parameters (the node's declaration files,
  `CallGraphKeys.paramTypesOf`), a supertype's type arguments (`TypeParamTable.argumentsFor(…, keyIn)`), and, in the
  reading file where they are written, a type parameter's bound and an abstract's underlying type. `keyedIn` keys every
  nominal of a type, not only the outer one, so `Array<Lock>` and `(Lock) -> Void` keep the declaring file's meaning.
  Two declarations of one type whose files key a member's type apart type it as NEITHER (`keyedInFiles` null), like
  `CallGraphTypes.joined` for two spellings; before they took the simple name. Guarded/maybe names of the declaring
  file: the files read while typing a receiver are collected (`readFrom`) and each one's `alternateTypes` join the
  call's — a sound over-approximation (an inner link's file contributes too), chosen over threading a file through every
  type source. Measured: 0 changes all rules on 3 client trees + anyparse src; the 6 cross-* fixtures now warn — branch
  `feat/ts-precision-6`
- R3 M2 (`round6/g1-alt/guard-nowait`, `guard-waitfield`): the alternates of a guarded name were dispatched only in the
  last branch of `handleCall`, after the project namesake resolved the call to a member, so a namesake lacking the
  member (extension branch) or declaring it as a field never reached `sys.thread.Lock.wait`. Now each candidate type runs
  the whole resolution (`dispatchOn`: forward, field, static extension, member + overrides); the call's own target is
  the first one any candidate names. The namesake's own `UnresolvedReceiver`/`FunctionValue` record stays — on the
  build where the name is the project type the call is that — branch `feat/ts-precision-6`
- R3 M4 expensive part (`round6/frag`): one computed reflective write on a value the run places on no class unsealed
  EVERY lock member — an 8-line `ReflectHelper.assign(o:Dynamic, k, v)` on a client copy re-keyed 37 of 102 recall keys to
  `Mutex.acquire` / `GateMutex.lock`. R3's sketch ("a lock type never reaching an untyped value keeps its members
  sealed") was checked and REJECTED as unsound as stated: it misses the reflective-READ copy channel — `Reflect.field(dyn,
  k)` of a holder object yields its lock untyped, the unplaced write stores it in another member, and sealing never sees a
  read. Refined so ("no project reflective read may yield a lock either") it fails for every lock type on the client corpus: client has four
  unplaced computed reads (`API.getErrorMessages`, `BaseNativeURLReader`, `Form`, `Node.restore`) and holders reach
  `Dynamic` through library supertypes (`ShardDatabase extends EventDispatcher`: `event.target`), so neither the reads nor
  the holders can be bounded. Asked of the WRITE instead (`ReflectiveValues`): what an unplaced write stores, as the types
  of the objects its value may be — a POSITIVE list: nothing for a delete or `null`, a literal's type, an expression's
  declared type (only under a covered `closedWorld`, so every subtype is seen), and for a parameter — `Dynamic` / `Any`
  ones included — what every call of its function hands it, when every invocation is a call the graph holds
  (`ThreadSafety.callersSeen`: `seedable` false, no non-inert `Ref`), `reflectiveMethodHolders` is declared alike and names
  neither its class nor a subtype (a computed read cannot obtain it for `Reflect.callMethod`), and no string literal of the
  run spells its name; the argument at its index, any up to it after an optional parameter (type-based skipping moves
  the rest along), a static extension call's receiver first, an import-alias receiver refused. Anything else may be any
  lock. Per lock member (`FieldWrites.markLockMembers`: the `receiverField`s of the lock calls and the alias hand-offs) the
  write counts only when a stored type may be a lock of the member's declared type (`mayHold`: never a literal's type or an
  enum; a project class/interface only through a common subtype; a library member type only through a project subtype
  unless the value's chain leaves the run; anything else — library type, structure, abstract — may). Applied to unplaced
  writes only (literal-named ones too); placed writes keep G2's exclusions as they were. Notices: the unchanged line for
  writes that may store any object, one for a typed value storing a lock of some member type, one naming each write kept
  off every lock member with what it stores. MEASURED: client 1d1ba147 / f81c2049 / bd943dac rows == start (no unplaced write
  there); frag 65/102 -> 102/102 with `ReflectHelper.assign (it stores no object)` named; called with a literal 102/102
  (`it stores String`), through a second helper fed `1` / a `String` / nothing 102/102, called with `Reflect.field(from, k)`
  65/102 (today's default, named as before). Fixtures: lost 0, five round4/f11b holds re-keyed `Mutex.acquire` -> `C._m`
  (each stores `new Blocking()`). Rule time +1.2% (client 5.76 -> 5.83 s). The boundary is the one every reflective write
  already has: a write inside library code is not seen at all — branch `feat/ts-precision-6`
- R4 F1 (`round7/k2/reassign*`, `call-default`, `k2b/reassign-caller`): K2 followed a parameter to what its callers hand
  it and never looked at the function's own writes, so `assign(o, k, v:Dynamic) { if (v == null) v = lock; ... }` called
  with `null` was kept off every lock member. `ReflectiveValues.writesOf` walks the declaring function (closures and
  local functions included) for every write whose target BINDS to the parameter (`resolveBindingFrom`, so a shadowing
  closure parameter is not it): `=` / `??=` add their right side as one more source, an operator write
  (`RefShape.operatorWriteKinds`: compound assignments but `??=`, increments, decrements) stores a value of the target's
  own declared type, none for a catch-all one (an operator on `Dynamic` makes a number, a string or a boolean — so the
  reviewer's `v++` control stays kept), and any other write shape (a `#if` region as the value) makes the parameter
  Unknown. Chosen over "any write -> Unknown" (the reviewer's first option) because it keeps the literal-reassigned and
  increment controls precise at no soundness cost — branch `feat/ts-precision-6`
- R4 F2 (`round7/k2/struct-*typedef`, `k2b/*struct*`): `enumType` asked `CallGraphTypes.holdsNoFunction`, which is true
  for every typedef of an anonymous structure, so a value typed by `typedef Lockable = { function acquire():Void; }`,
  `{}` or `{ > Base, … }` "held no lock" — but structural typing admits any object with the fields. The question is the
  declaration KIND: `TypeMetaFacts.isEnum` (every declaration of the type is a `runtimeTaggedTypeKinds` one); a
  structure typedef or an abstract falls through to "may hold" — branch `feat/ts-precision-6`
- R4 F3 (`round7/k2/typeparam-shadow`): the typer's declared name was taken at face value, so `v:Other` inside
  `class Box<Other>` was typed as the project class `Other`. A written type whose outer name is a type parameter in
  scope at the value — the enclosing types' and functions' (`TypeParamTable.inScopeAt`, off
  `TypeInfoProvider.typeParamNames`; a type's keyed by its name node, a function's by its own start) — is Unknown, for a
  stored value and an operator write alike. A member read off another type's value (`b.v` with `b:Box<Mutex>`) was
  checked and is already right: the typer answers the substituted type or nothing — branch `feat/ts-precision-6`
- R4 F4 (`round7/k2/cast-local`), decided by the positive-whitelist policy: a declared type an unchecked value reached
  is a claim the compiler never checked, so it is no exclusion. `ReflectiveValues.claims` walks the held files once on
  first demand: a local or parameter (by binding) and a field (by NAME, whoever declares it) whose initializer or any
  write holds an unchecked `cast` or an `untyped` anywhere, or is itself declared `Dynamic` / `Any` (which the compiler
  lets into a variable of any type — the same lie without a cast), makes a read of it Unknown. A checked `cast(e, T)` is
  trusted. NOT covered, same class, left as reported: a typed PARAMETER whose callers pass an unchecked or `Dynamic`
  value, and a function whose declared return type is fed one — following those means the arguments and returns of
  every typed value, i.e. a typer, not a list. client: no row moves (no unplaced reflective write on the 3 trees) — branch
  `feat/ts-precision-6`
- R4 F5 (`round7/k1/tparam-shadow-*`): K1's `keyedIn` keyed a TYPE PARAMETER through its file's imports (`import
  sys.thread.Lock; class Box<Lock> { var v:Lock; }` -> `sys.thread.Lock`), so the receiver's type argument
  (`Box<utils.Lock>`) was never substituted and the call went to the std `wait` — a false A warning where the base had
  the right edge. Haxe: a type parameter shadows every import. `keyedIn` / `keyedInFiles` / `keyingsIn` take the names
  to leave as written: the owner's parameters for a member type, the owner's and the function's for a return or a
  parameter type (`CallGraph.readIn(files, written, owner, fn)`, `paramTypesOf`), the linking type's for a supertype's
  arguments, every type parameter in scope at a declaration of the file (`CallGraphKeys.unkeyedAt`), and
  `ReflectiveValues.memberTypeOf` leaves a member declared of one untyped (may hold). The argument is keyed where it is
  written, as K1 already did — branch `feat/ts-precision-6`
- R4 F6 (`round7/k1/two-decls-type`): K1 typed a member two declarations key apart (`mac/A.hx` `import
  sys.thread.Lock`, `web/A.hx` `import utils.Lock`, one per build) as NEITHER — silently, the unsound direction.
  `CallGraphKeys.keyingsIn` returns every keying; `readIn` types the receiver by the first and records what each other
  keying names in its place (`firstKeying` -> `keyedApart`), and the dispatch runs those types too (`apartFrom`), as it
  runs alternate types. Readers that need ONE type (`ReflectiveValues.memberTypeOf`, `paramTypesOf`) keep "none" via
  `keyedInFiles`. The return-type guard that turned a keyed-apart return into "no type" (and its arm
  `M-TS-DECL-RETURN-AGREE`) is gone; `testTwoDeclarationsThatKeyAMemberTypeApartTypeItAsNeither` became
  `testTwoDeclarationsKeyingAMemberApartDispatchOnBoth`. Left as is: two declarations whose RETURN texts differ are
  settled to no fact (`CallGraph.settle`), still "neither" — branch `feat/ts-precision-6`
- R4 F7 (K1 coverage holes, both engines silent: static imports, cross-module typedef chains, a project file in a library
  package, `@:forward` abstracts, iteration, function-typed fields, function type parameters, lambda parameters typed by
  the callee, a member declared twice under `#if`): backlog, not taken in K3.
- R4 K3 MEASURED (engine of the K3 tip vs a3c2b416): client 1d1ba147 / f81c2049 / bd943dac reports byte-identical (rows
  `153 146 102 … 0.70 102/102`, 5/5, 9/9), `round6/frag` 102/102; all rules byte-identical on the 3 client trees and
  anyparse src; fixtures r1..r5, round2, round4..round7 (499 runs): lost 2 = the F5 false positives, gained 27 = the 14
  F1..F6 targets, 5 info-only changes; rule time 5.56 -> 5.63 s (+1.3%), full lint 23.90 -> 23.17 s (noise) — branch
  `feat/ts-precision-6`
- R7 L1 (a) (`round7/k1/statics-wild`, `-field`, `-wild-ret`): a bare value name no binding, member or module function
  answers was never read through the imports that may bind it, so `import A.*;` + `lock.wait()` / `make().wait()` stayed
  unresolved and silent. `CallGraphKeys.importedStatic`: the ONE static `CallGraphImports.importedStatics` binds the name
  to, typed where its owner declares it (`memberTypeSource`), a bare call of one resolved the same way (`staticTarget`,
  shared with `importedFunction`). Refused (unresolved, as before): a member the reading type's chain declares, a chain
  the index does not hold whole (a library supertype may declare it), a module function, two imports binding the name
  (the compiler takes the last; kept unknown rather than ordered), an unlisted wildcard type — branch `feat/ts-precision-7`
- R7 L1 (b) (`typedef-chain`, `-sub`): `CallGraphTypes.resolveAlias` followed the alias's SIMPLE target, so
  `pkg/Alias.hx: import sys.thread.Lock; typedef MyLock = Lock;` beside a project `utils.Lock` dispatched to the project
  `wait` (a same-file alias too). Each declaration's `aliasTargetRaw` is kept with its file and keyed there
  (`CallGraphImports.typeOf`) at every hop. Two declarations keying one alias apart keep the simple target, as before —
  `resolveAlias` answers one type; not covered (no case in the fixtures or client) — branch `feat/ts-precision-7`
- R7 L1 (c) (`libpkg-samepkg`, `-noimp`): a name no import binds stayed as written, i.e. the project namesake. Checked
  with haxe 4.3 first: after the module, the imports and the wildcard imports (a wildcard import beats the own package),
  the compiler searches the file's own package and then each enclosing one. `CallGraphImports.packagePath` does the same
  after `wildcardPath`: the first `pkg.Name` the project declares (keys to the project type, unchanged) or the std core
  declares in a package it holds (`sys.thread.Lock`). A package neither holds (a library's: the client's `src/openfl/net`) answers
  nothing and the name stays as written, as before — such a package cannot be listed without the library's sources; the client's
  thread-safety reports are byte-identical with (a)..(c) (measured, below) — branch `feat/ts-precision-7`
- R7 L1 (d) (`fn-tparam-shadow`): a return type that is a type parameter the function declares itself was "no type"
  (K3's rule kept it unkeyed, correctly, but nothing bound it), so `A.id(s).wait()` with `id<Lock>(x:Lock):Lock` and the
  std lock was unresolved. `returnThrough` (receiver view first, then the function's own parameters) binds each of them
  from the declared types of the arguments passed to parameters written as that BARE parameter, rest arguments
  included, when they all agree (`CallGraphKeys.argumentBindings`) — the compiler's inference for the simple shape;
  disagreeing arguments, a parameter only nesting it (`Array<T>`: no structural unification), an argument with no
  declared type, and a function parameter shadowing its type's leave the result unknown (`UNKNOWN_TYPE`). Never keyed
  through the import the name shadows — branch `feat/ts-precision-7`
- R7 L1 (e) (`ifdef-decl-member`) + the R4 F6 remainder: a member declared twice under `#if` with different types was
  joined to "no type" (`CallGraphTypes.joined`), and two declarations whose return texts differ were settled to none
  (`CallGraph.settle`): "neither", silently. The index keeps each member declaration's written type with its file
  (`CallGraphImports.memberTypesOf`); a function's per-declaration return types are read on demand
  (`CallGraphKeys.returnsWritten`, only when the settled one is missing and there are several declarations). When the
  joined record / the settled fact has none, `readIn` keys each where written (`firstKeyingEach`) and the dispatch runs
  every type they name (`apartFrom`), exactly as K3 did for one text keyed apart; a return whose types differ in name
  takes the simple name of the one read. Unknown, as before: a branch writing no type, a declaration the graph cannot
  read, types that do not line up — `keyedApart` now answers null for a different shape or argument count instead of
  "no pairs" (which would have typed the value by the first alone). Readers needing ONE type (`paramTypesOf`,
  `ReflectiveValues.memberTypeOf`) still have none; a parameter list two declarations write differently stays unknown
  (`paramTypesOf`), not taken here — branch `feat/ts-precision-7`
- R7 L1 F7 remainder NOT taken (L2): `@:forward abstract H(Lock)` (`abstract-underlying`), iteration over `Array<Lock>`
  (`array-iter`), a function-typed field (`fn-type`), a lambda parameter typed by the callee's signature in another file
  (`param-decl-file`).
- R7 L1 MEASURED (engine of the L1 tip vs dc09aa52): fixtures r1..r5, round2, round4..round7 (499 runs): 480
  byte-identical; the 9 F7 targets now warn `A C.realWait|sys.thread.Lock.wait`; every other round7 fixture (k1, k2,
  k2b, controls, "not findings") byte-identical; the r5 trees (client 1d1ba147 src under the r5 configs) re-key from (e):
  `D RemoteDiskSystemBase.listFolderCloudCallback|…` (client-bad) disappear because `getFolderListingAPI()` (two `#if`
  declarations, FolderListingNewAPI / FolderListing) now types `loadContent`, whose callback runs through
  `NetRequest2.success` (spawns), not as if under the caller's hold; `B RemoteDiskSystemBase.setTimestamp|…` is demoted
  to info by the existing "long only through work … reported there" fold; `D ItemList.reload|…` (truth `false`) becomes
  `B ItemList.reload|VolumeWatcher._mutex`. client: 1d1ba147 `153 146 102 8 12 5 18 1 0 0.70 102/102` -> `164 157 102 8 12 8
  26 1 0 0.65 102/102` (13 keys gained, 10 already labelled dup-of / false, 3 labelled `false` R7-L1; 2 D false keys
  lost), f81c2049 198 -> 209 (5/5), bd943dac 199 -> 210 (9/9), round6/frag 102/102 — all from (e): the std/lib/client members
  and returns written per `#if` branch (std `Process.stdout`, openfl `DisplayObject.stage`, client `getFolderListingAPI`)
  are typed now; (a)..(d) leave the 3 reports byte-identical. All rules: only thread-safety moves on the 3 client trees,
  anyparse src identical. Rule time on client-1d1ba147 (interleaved, median of 3) 5.94 -> 7.40 s (+24.6%), full lint 25.44
  -> 26.95 s (+5.9%): (a)..(d) cost +2.5%; the rest is not the resolution (graph build +0.1 s) but the analysis over
  the larger reachable graph — `ThreadStates.origins` (one BFS per worker start) +1.0 s, `siteFacts` / `holds` /
  `carried` the remainder (cpu profile); accepted as the price of the edges, a faster `origins` is separate work —
  branch `feat/ts-precision-7`
- R7 L1b timing (`fb7b1342`): L1's +24% rule time (client-1d1ba147) was `ThreadStates.origins` re-evaluating, in every
  per-start BFS, `onWorker` (an `edgeContext` over all states of the edge's function) and `workerStep` (`carried` +
  `entered`) for every out-edge of every state — neither depends on the start. Each function's worker edges and each
  state's steps are now read once (`stepsOf`), the per-start BFS (`spread`) walks that memo; origins 1394 -> 119 ms
  (cpu profile), reports byte-identical on the 3 client trees. Not taken: one shared multi-source reachability (origins are
  a set per function; the memo already makes each BFS a walk over cached steps) — branch `feat/ts-precision-7`
- R7 L1b diagnosis of L1's 1d1ba147 delta (+13 / -2 warning keys): every key comes from ONE edge (e) added —
  `LanguageSelection.saveButtonHandler -> Main.languageReboot`: `Main.instance` is declared in root `Main` and in
  `logs.Main`, joined to no type before, keyed where each is written now. Measured: a copy of the tree with only that
  call made `Dynamic` reports exactly what dc09aa52 reports. The edge is right; it puts the editor UI on the worker
  origin `IAPStore.onPurchaseSuccess#5` (client config: `api.NetRequest2.success` is a `spawns` entry; `Timer.delay` and a
  handler registered with `addEventListener` keep the registrar's context), so holds the main-only rule turned info
  ("reported at (a)") are taken on a worker too and warn. No sound engine narrowing exists for that reach (it follows
  the config and the registrar rule); the 8 `dup-of` and 2 earlier-`false` keys stay, none meeting a RootCauseFold
  cover (their holds reach blocking calls no covering finding names, or the cover repeats where they do not). Three
  `false` keys rode a second, older imprecision — next entry. `getFolderListingAPI` (named by L1) is the r5 `client-bad`
  change only — branch `feat/ts-precision-7`
- R7 L1b stored values (`7014cabd`, `StoredValues`): a function value handed to a project constructor that only stores
  it into a `final` field runs where the field is called, not at the `new` (client `ItemList.reload` -> `new
  ItemListTile(..., _source.getThumbnail)` under the tree lock; ItemListTile / ItemListItemTile store it, only
  `ItemListItemTile.requestThumbnail` calls it). Each call of the field gets a derived `Call` edge to the value and the
  handing `Ref` runs nothing (`ThreadSafety.runsNothing`), like a value stored into a `dynamic` member
  (`deriveStoredCalls`). Positive whitelist: a whole argument of a `new` resolving to a constructor of one declaration,
  as many arguments as parameters (no rest); the parameter read only bare as the right-hand side of assignment
  STATEMENTS to `final` fields its class declares (any other node of its name refuses); every node of the held
  files carrying the field's name a field declaration, an assignment target, a call of it in a held function, or a
  whole argument of another such constructor's store (followed); no string literal spelling it, the class not a
  declared `reflectiveMethodHolders` (`ReflectiveValues.obtainableMember`, extracted from `obtainable`), its file under
  `closedWorld`. Anything else keeps the value running where handed. client 1d1ba147: the three `false` keys go
  (B ItemList.reload|VolumeWatcher._mutex, D ItemListMoveItems.moveItems|…, D StandardDiskSystem.createFolderItem|…);
  16 handed values are stores in the client corpus (thumbnails, dialog callbacks, animation-frame commands, share rows) — branch
  `feat/ts-precision-7`
- R7 L1b `B RemoteDiskSystemBase.setTimestamp` (truth real-long): on f81c2049 / bd943dac and 8 r5 configs L1 turned it
  info. Of its two long calls the stat (`getTimestamp -> getMTime -> FileSystem.stat`) was covered by warnings of the
  same lock over the same stat site on its thread (createFolderItem / moveItem / renameItemInternal, `_mutationMutex`,
  origin `DiskSystemBase.runCloud` among theirs — measured) — RootCauseFold's same-lock / same-site / same-thread rule,
  a different hold of the same root; the wait for `VolumeWatcher._mutex` was covered only because ItemList.reload's and
  listFolder's `_mutex` holds had turned warnings in L1 — both truth `false`. So the demotion rested on false covers:
  not the same stall. With stored values ItemList.reload's hold reports nothing, a `_mutex` maker has no finding again,
  and setTimestamp warns on f81c2049 / bd943dac / the r5 configs (where `B acquireMutationLocks|_batchMutex`, truth
  `dup-of`, now folds onto the `_mutationMutex` makers including it) — branch `feat/ts-precision-7`
- R7 L1b MEASURED (engine of the L1b tip vs dc09aa52 and the L1 tip): rule time on client-1d1ba147 (interleaved, median of
  3) dc09aa52 5.70 / L1 tip 7.03 / L1b tip 5.62 s (-1.4% vs dc09aa52); full lint 24.41 -> 25.10 s (+2.8%); cpu profile
  origins 415 / 1394 / 131 ms, carried 491 / 1029 / 326, edgeContext 208 / 625 / 80, StoredValues 53. client rows:
  1d1ba147 `161 154 102 8 12 5 26 1 0 0.67 102/102` (L1 164 … 0.65), f81c2049 207 (5/5), bd943dac 210 (9/9),
  round6/frag 102/102. Fixtures r1..r5, round2, round4..round7 (499 runs) vs the L1 tip: 490 byte-identical; only the r5
  client-derived trees move (the 3 false keys go, B setTimestamp warns, B acquireMutationLocks|_batchMutex — truth `dup-of`
  — folds onto the _mutationMutex makers); round7: the same 9 F7 targets as L1. All rules: only thread-safety moves on
  the 3 client trees, anyparse src identical — branch `feat/ts-precision-7`
- R7 L2 (a) (`round7/k1/abstract-underlying`): not a missing forward — `dispatchOn` already routed a member a `@:forward`
  abstract does not declare to its underlying type, but by the underlying's SIMPLE name (`TypeMetaFacts.forwardedTo`), so
  `H.hx: import sys.thread.Lock; @:forward abstract H(Lock)` beside a project `utils.Lock` sent `h.wait()` to the project
  `wait` — a wrong edge, not a missing one. Each declaration's written underlying head path is kept with its file
  (`TypeMetaFacts.forwardsWritten`) and keyed there (`CallGraphImports.keyedWhereWritten`, which `resolveAlias` now shares),
  then seen through an alias. An underlying that is a type parameter of the abstract (`@:forward abstract W<T>(T)`) names
  no type: it used to dispatch on a type of that name (an external `T.m` placeholder, or a project `T`); now unresolved.
  Not taken: forwarding through a second forwarding abstract (one hop, as before); the type argument of `W<X>` — branch
  `feat/ts-precision-7`
- R7 L2 (c) (`fn-type`): a call is typed by the declared return of the function it resolves to, and a function-typed
  field, parameter, local or call result names no function, so `A.get().wait()` with `get:() -> Lock` stayed unresolved.
  When the call resolves to no function, `typeSourceOf` takes the result of the callee's own written type when that is a
  function type (`Null<…>` peeled; `calledResult`), read where it was declared like any member type; `receiverType` falls
  through to that typing instead of stopping. A `Dynamic` callee stays untyped. The call itself still records
  `FunctionValue` (which function runs is unknown) — branch `feat/ts-precision-7`
- R7 L2 (b) (`array-iter`): nothing typed a loop binder. The edge walk now types it before the loop body is walked
  (`typeLoopBinder`, stored like a declared type at the binder's offset): the type argument a standard container names
  (`iterationElementTypeParams`: Array, Vector, List, Iterable, Iterator, a Map's values — the plugin's obligation that
  each of them yields the same element from `iterator()` and `keyValueIterator()` covers a key-value loop's VALUE binder,
  which takes nothing else); otherwise the return of the `next()` of the type `iterator()` returns (or the standard
  element of it), or the type's own `next()`, through the container's type arguments (`memberReturn` -> `throughParams`).
  Unknown: a key binder (a key or an index), both `iterator()` and `next()` declared and disagreeing (which one the
  compiler takes is not modelled), a member declaring type parameters of its own, a member the graph holds no body of
  (std / library) — branch `feat/ts-precision-7`
- R7 L2 (d) (`param-decl-file`): nothing typed a lambda parameter written without a type. The walk types such
  parameters before the lambda's body (`typeLambdaParams`) by the function type the lambda is expected to be — the
  existing `expectedAt` (which already typed construction literals): a call's parameter as `paramTypesOf` reads it, keyed
  in the callee's OWN file, through the receiver's type arguments, refused when it names a type parameter of the callee
  itself (`argumentTypeSource`); a `new`'s; a declaration's, an assignment's, a return's — through parentheses, ternary
  and `if`/`switch` arms. Only a function type (`Null<…>` peeled) of exactly the lambda's arity; a parameter written
  with a type keeps it. Not taken: optional-argument skipping (the arity check refuses a mismatch rather than skip), an
  `@:overload`ed callee beyond what `paramTypesOf` already refuses — branch `feat/ts-precision-7`
- R7 L2 (e) (R7 L1b remainder): `typeSourceOf` had no arm for a `new`, so `new Maker().make().wait()` was unresolved. A
  `new` types its value by the type it names, keyed where written; type arguments it does not spell are unknown
  (`throughParams` substitutes `UNKNOWN_TYPE`). `ThreadSafetyRepetitionTest`'s "call unresolved" case was
  `new Batch(…).success(…)`, which now resolves (its arm M-TS-RUNS-ONCE-UNRESOLVED survived); it reads a `cast` receiver
  instead — branch `feat/ts-precision-7`
- R7 L2 cleanup: `collectNodes` / `registerNode` move unchanged to `CallGraphNodes.collect` / `register`
  (`CallGraph` was 2083 lines over the 2000 cap); ten arms re-pointed — branch `feat/ts-precision-7`
- R7 L2 MEASURED (engine of the L2 tip vs the L1b tip 431f0c39): the 4 F7 targets (`abstract-underlying`, `array-iter`,
  `fn-type`, `param-decl-file`) now warn `A C.realWait|sys.thread.Lock.wait`; every other round7 fixture (k1, k2, k2b,
  controls, "not findings") keeps its keys — `tparam-shadow-lib-bg` / `-ctl` add "(also reachable from a background
  thread)" to `Mutex.release`, right: the spawned lambda's `new Mutex().release()` is typed by (e). Fixtures r1..r5,
  round2, round4..round7 (499 runs): 482 byte-identical, no warning lost; the r5 client-derived trees gain the Cones3D keys
  below. client 1d1ba147 `161 154 102 8 12 5 26 1 0 0.67 102/102` -> `164 157 102 8 15 5 26 1 0 0.65 102/102`: three keys,
  all from (e) — `new Cones3D().cropImagesAndSave()` in `AssetUtils.run` (`#elseif ASSET_TOOLS`, Main.hx:99) gains its
  edge, so `A Cones3D.cropImagesAndSave|File.saveContent`, `A Cones3D.saveCroppedImageToDiskSystem|File.saveBytes`,
  `A Cones3D.setCropAngle|Assets.getBitmapData` warn; labelled `rare` (debug-define path, R7-L2); f81c2049 207 -> 210
  (the same three; 5/5), bd943dac 210 (9/9, keys unchanged), round6/frag 102/102. (a), (c), (d) leave the 1d1ba147 report
  byte-identical; (b) re-renders chains only (loops over typed command / node arrays: `AggregateCommand.commit` now
  dispatches to every `Command.commit`, `Editor.setModelData` to the node `toObjectData` / `toTarget`). All rules: only
  thread-safety moves on the 3 client trees, anyparse src identical. Rule time on client-1d1ba147 (interleaved, median of 3)
  dc09aa52 5.96 / L1b tip 5.74 / L2 tip 5.92 s (+3.1% over L1b, -0.7% over dc09aa52); full lint 24.98 -> 25.83 s (+3.4%)
  — branch `feat/ts-precision-7`
- R7 L3 F1 (review R5, MUST; `sv/implicit-iterator`, `-iterator-local`, `-kv`, `-tostring`): StoredValues followed a
  value a constructor only stores to the occurrences of its field's NAME, but the compiler calls some fields by name with
  no node of it at the call — a `for` runs `iterator()` / `keyValueIterator()` (checked on --interp, a private field too:
  `for (x in this)`), a string conversion runs `toString()` on dynamic targets, `haxe.Serializer` reaches `hxSerialize`
  through `Reflect` — and std code reads a field structurally (`Lambda` iterating an `Iterable`). A stored field now
  counts only when its name is in neither `execution.implicitCallNames` nor the new `execution.reflectivelyCalledNames`
  (`hxSerialize`, `hxUnserialize`, `resolve`) and it is not public (`MemberKinds.fieldExposed`, moved from
  FieldInitAtDeclaration: explicit `public`, a `@:publicFields` / extern container). Cost: `sv/implicit-iterator-only-stored`
  (public, never iterated) warns again as on dc09aa52 — branch `feat/ts-precision-7`
- R7 L3 F2 (`h/loop-proj-list(-rev)`, `loop-proj-iterator-type`, `loop-modsub-list`, `loop-proj-vector`,
  `idx-proj-vector`): the element maps were looked up by the container's SIMPLE name, so a project `List<T>` was read as
  the std one (the index arm since K1). The listed parameter is now taken only when the name provably is the std type
  (`standardContainerPaths`, a new shape key; `CallGraphImports.namesStandard`): a dotted std path no declaration bears,
  or a simple name no indexed declaration bears — one that does makes the simple key mean that type — which the file
  binds to a std path or which is a toplevel std name. Otherwise the container's own `iterator()` / `next()`, an
  `iterator()` return read in the file declaring it (`memberReturn` hands it). An `#if`-guarded import binding the name
  elsewhere refuses; a wildcard of a package the tables cannot list does not (follow-up: refusing it lost every
  `Array<T>` loop in the client's Editor.hx, which imports library packages by wildcard — `typeOf` reads such a wildcard the same
  way). A declaration at a standard path or its module-qualified twin (`Array`, `Array.Array`, `haxe.ds.List.List`,
  `StdTypes.Iterator`) is the std itself, indexed as a library, and no namesake (follow-up 2: MemberReachTest indexes a
  `std/Array.hx` stub). Limit: a project module at exactly a std path is indistinguishable from the std by path — branch
  `feat/ts-precision-7`
- R7 L3 F3 (`h/lam-skip-shift(-rev)`): L2 d typed a lambda argument by the parameter at its POSITION, but Haxe skips an
  optional parameter an argument does not fit. `paramTypesOf` records the first skippable parameter (`?p` or a default
  value; every parameter of an external target, whose index entry does not say) and the declared count
  (`DeclarationFacts.skippable`); `argumentTypeSource` answers null when one sits at or before the argument and the call
  passes fewer arguments than declared, or a rest parameter takes the rest (`CallGraphKeys.mayShift`). The same place now
  counts a `new`'s own arguments only (`new Box<Int>(f)` read the type argument as argument 0) — branch
  `feat/ts-precision-7`
- R7 L3 F4 (`h/stat-modvar(-rev)`): a module-level `var` / `final` (the index lists none) lost to a static `import A.*`
  brings in. Each file's module-level names are recorded as its edges are collected (`CallGraphNames.moduleLevelNames`:
  named root children and, through nameless wrappers — a conditional region, a `final`'s VarForm — the named nodes they
  hold; an import alias names none) and `CallGraphImports.importedStatics` brings in nothing under them, for every
  consumer. The module field itself stays untyped (unknown, not the import's type) — branch `feat/ts-precision-7`
- R7 L3 F6 (pre-existing; `h/ovl-return(-rev)`, `ifdef-ovl`): `@:overload` signatures were ignored. CallGraphNodes
  compares each offered function's return and parameter list (kind + written type) with the declaration's: differing
  returns drop the node's return facts and mark `overloadedReturns` (`returnSourceOf` null, the `#if` twins of L1 e
  included), differing parameters mark `overloadedParams` (`paramTypesOf` null); a metadata holding no function differs
  in both; agreeing signatures type as before. A library function the graph holds no file for types no parameter when
  its index entry carries `hasOverloadMeta`. Not taken: dispatching on every signature (a call's selection is not
  modelled); StdTypes (the core std's one `@:overload`, Reflect.makeVarArgs, returns Dynamic either way) — branch
  `feat/ts-precision-7`
- R7 L3 F7 (pre-existing; `h/stat-super-static`): measured on 4.3.7 --interp — a supertype's static is not in a
  subtype's unqualified scope (`Unknown identifier`), an `import A.*` static of the name is read there, the type's own
  static and a module-level function of the module beat the import. `CallGraphKeys.staticOfSupertype` (the nearest
  declaration — a function the graph keys, else the index's field — is another type's static) keeps such a static out of
  the import gate, the bare-read typing and the bare-call targets. The module pseudo-type bears the main class's name and
  `memberOnChain` on it walked that class's supertypes, so module lookups take only what it declares itself
  (`CallGraphKeys.declaredOn`). `owner != typeName` carries no arm: a type's own member binds lexically before these
  lookups (the cut survives) — branch `feat/ts-precision-7`
- R7 L3 F5 (documented, not fixed): types are keyed by SIMPLE name where no path tells them apart, so a module-local
  `Maker` beside an imported `pkg.Maker` (`h/new-modsub-shadow*`) dispatches on both declarations' members since L1 e /
  L2 e — an over-approximation (both `make`s reachable), the mechanism that resolves the client's `Main.instance` correctly.
  Fixed only by qualified node ids (the open "graph by simple names" item) — branch `feat/ts-precision-7`
- R7 L3 MEASURED (engine of the L3 tip vs 23d4b78b): round8 runner — every F1..F4/F6/F7 fixture moves the right way
  (N fixtures `loop-proj-list-rev`, `loop-proj-iterator-type`, `loop-modsub-list`, `loop-proj-vector`, `idx-proj-vector`,
  `lam-skip-shift`, `stat-modvar-rev`, `ovl-return-rev` stop warning; W `loop-proj-list`, `stat-super-static` and the 4
  `sv/implicit-*` warn; `lam-skip-shift-rev`, `stat-modvar`, `ovl-return`, `ifdef-ovl` lose their wrong edge and stay
  silent), the hv twins follow (false B gone, `hv/stat-modvar` gains `A C.main|Mutex.acquire` as every unresolved hv
  row), `sv/implicit-iterator-only-stored` warns again (public field), every control and "not finding" keeps its keys.
  Fixtures r1..r5, round2, round4..round7 (499 runs): byte-identical. client 1d1ba147 / f81c2049 / bd943dac reports and
  round6/frag byte-identical (rows unchanged, recall full); all rules (`--no-oracle --all`) on the 3 client trees and
  anyparse src: JSON byte-identical. Rule time on client-1d1ba147 (interleaved, median of 3) dc09aa52 6.12 / 23d4b78b 6.05 /
  L3 6.01 s; full lint 25.59 / 24.96 / 24.80 s — branch `feat/ts-precision-7`
- `owned-types` was to match an INSTANCE member by name wherever its receiver is untyped → that reports every
  same-named method of every type; only a static, which Haxe reaches through a type receiver alone, is matched by name
  when the receiver's meaning is `Unknown` — branch `feat/infra-A`
- `owned-types` was to look a static member up through the receiver type's supertypes, as an instance member is →
  Haxe 4.3.7 rejects `B.make()` for a static of `B`'s superclass (`Class<B> has no field make`), so the type itself must
  declare it; instance members keep the supertype walk (`ConfiguredTypes.memberOf`) — branch `feat/infra-A`
- `owned-types` was to read a simple name with its own import / package lookup → it asks `TypeNameBinding.tierOf`, and
  a qualified one `TypeRefIndex.resolveTypeRefAll`: `Free` (no tier binds the name) is skipped as provably not the
  owned type, `Unknown` is REPORTED (positive whitelist — an unproved reach is a reach); the qualified path of the
  enclosing type comes from `TypeRefIndex.importPathFor`, made public rather than spelled a second time — branch
  `feat/infra-A`
- the module declaring an owned type was to be listed among its `owners` by hand → it always owns it: its own
  declaration and body are no reach past the boundary, and every declaration would otherwise repeat its own module —
  branch `feat/infra-A`
- every rule was to build the index its question needs (`SymbolIndex.build` in 63 places, `FieldWriteIndex.build` in 4,
  each choosing report vs resolution scope on its own) → `IndexScope` names the choice — `report` (exactly the files
  handed in), `resolution` (the host's report UNION library UNION std scope, else `report`), `widest` (the resolution
  scope only when DECLARED, else `report`), `over` (an explicit other set: an op's `--scope`, a per-file rebuild, a
  graph's held files) and `reportWrites` / `resolutionWrites` — and the run host builds: `CachingGrammarPlugin.indexOver`
  / `writeIndexOver` memoise one index per file set, keyed by the third-party tag and the length-prefixed ordered paths
  and validated by the sources, so a `--fix` pass that rewrote a file rebuilds it. `resolutionIndexOf`,
  `widestScopeIndex`, `lazySymbolIndex`, `fieldWriteIndexOf` moved there from `RefactorSupport`. Every site keeps its
  file set and its scope (a narrow site stays narrow: `redundant-map-exists`, `field-init-at-declaration` and the
  `fix` fallbacks are report / one-file builds on purpose), so answers are unchanged and only the build count drops —
  branch `feat/infra-B1`
- the index memo was to live as long as the run → it dies with the ambient-import memos (`invalidateAmbientChain`, the
  head of every `--fix` pass): `SymbolIndexBuilder` reads the ambient `import.hx` chain through the host, and a pass may
  have rewritten one without touching the report sources the memo validates — branch `feat/infra-B1`
- the `--fix` loop was to keep building the per-pass resolution index itself → the host rebuilds it
  (`rebuildResolutionIndex`) outside the memo, since every pass replaces it and a kept entry would pin a whole
  library-wide index per pass — branch `feat/infra-B1`
- a simple type name was read four ways (`TypeRefIndex.resolveTypeRefAll` concatenating tiers and refusing on two,
  `TypeNameBinding` in the compiler's order, `ImportBindings` re-deriving an import line's types, `CallGraphImports`) →
  ONE: `TypeNameBinding`, owned by `TypeRefIndex` (`refs.names`), which `resolveTypeRefAll` answers a simple reference
  through; the tier helpers of `TypeRefIndex` (`inScopeAll`, `tierOf`, `chainTier`, `hasGuardedImport`, the two
  `namedBy*Import` predicates, the tier arithmetic) are deleted. The order, each tier compiled on 4.3.7 in TYPE position
  (`final v:X`, probes kept in `../b2-scratch/hx/typepos`): the module's own types, a private one included, beat every
  import (`p1`, `p1b`); explicit `import` / `using` / alias, the LAST binding statement winning (`p2*`, `p3b/c`), a
  module import binding its non-private types only (`p9`); `import.hx` explicit, nearest first, below the file's own and
  above its wildcards (`p4*`); `StdTypes` (`Iterable` beats a same-package, wildcard and toplevel `Iterable`, loses to
  an explicit import, `t1..t5`); wildcards asked LAST FIRST (`p5c/d`, `p4f/g`), binding package MAIN types only (`p5a`,
  `r1`, `r2`: a module without a main type, or with a private one, is skipped), a field wildcard binding no type
  (`q1`), a static or constructor import binding no type (`q3`, `q4`); the package then each PARENT package (`p6*`),
  then the toplevel, main types only (`p6c`, `p7b`, `p7c`, `p8`) — branch `feat/infra-B2`
- an import path was to be split by asking the index which prefix is a module → by the compiler's case rule (lower-case
  segments are the package, the first other one the module): a lower-case module cannot be imported at all
  (`Module name must start with an uppercase letter`, 4.3.7), so the rule is exact and needs no index — branch
  `feat/infra-B2`
- fail-closed on an import of a module the index does not hold, as `TypeNameBinding` did → measured: the client's report
  index holds neither openfl nor the std, so every file importing either answered `Unknown` for every name and
  thread-safety lost 37 of 102 recall keys (lock members typed through report-index `MemberLookup`). The module is READ
  instead, never guessed: `SymbolIndexHost.moduleTypesInScope` parses only the resolution-scope files named after it
  (no resolution index is built), then `StdTypes.moduleTypes` reads the std file of that module (any std module, `js/`,
  `flash/` included: openfl wraps its imports in `#if (js && html5)`). A module that declares the name binds OUTSIDE
  the index (`Free`); one that does not lets the next tier answer; one nothing reads stays `Unknown` — branch
  `feat/infra-B2`
- a `#if`-guarded statement binding the name was to answer `Unknown` (old `TypeNameBinding`) or the union of an
  all-guards-present and an all-guards-absent reading (old `TypeRefIndex`) → the USE SITE decides (`tierOf(name, fi,
  at)`): a use inside the statement's own branch, or a branch of the same spelled condition chain
  (`CondBranchPath.within`, the shared `#if` layer), is compiled only by the builds holding the statement, so its answer
  stands (`coGuarded`; 4.3.7 probe `g2`: `#if !useB import a.T; class M extends T {} #else typedef M = b.Other; #end`
  compiles both builds, and the one without the import never names `T`); any other use is weighed against the order
  WITHOUT the statement (`bothBuilds`), where a package or toplevel module that nothing — index, scope, std — can read
  is `Unknown`, never taken as absent (a use outside the region, probe `g1`, is compiled by the other build too). A
  caller with no offset gets that strict reading. The callers that walk a declaration pass its start
  (`MemberLookup`, `SubtypeGraph`, `StructuralTypes`, `MemberPathWalk`, `TypeTraits`, `ConfiguredTypes`, `UsingScan`,
  `ImportBindings`, `OrphanAccessor`, `UnusedPublicMember`, `PreferArrowCallback`), `DeclaredNullity` / `OperandBinder`
  the written type's or the member's offset, `prefer-static-extension` the call's. An intermediate version took the
  other build's unread module as binding nothing — a guess; measured against it the strict rule alone lost 6
  `prefer-api-idiom` findings on bd943dac and 4 fold findings on anyparse, all inside a whole-file `#if`, which the use
  site keeps — branch `feat/infra-B2`
- `StdTypes` was not a tier → it is, between the explicit imports and the wildcards; read from the index when the std's
  own `StdTypes.hx` is in it (`StdResolver.isStdFile`), else from the std listing, else from `STD_TYPE_NAMES` (pinned
  against the std by `TypeNameBindingTest`), a name it declares binding a built-in (`Free`) — branch `feat/infra-B2`
- `ImportBindings` was to list an import line's types off its own module / package tables → it reads the binding's
  (`importedTypes`: a module's NON-PRIVATE types; `wildcardTypes`: a package's non-private MAIN types, where it listed
  module names), so the import ranks and the binding read one table; `PreferStaticExtension.moduleIfGuardedSelf`
  (subsumed by `bothBuilds`), `FieldWriteIndex.plainClassInScope`'s import-shadow loop (the binding answers it),
  `FieldInitAtDeclaration.coreNameShadowed`'s own import / wildcard scan (now `tierOf` + `isStdFile`),
  `SymbolIndex.importResolves` (subsumed by fail-closed binding) and `UnusedPrivate`'s alias scan
  (`TypeRefIndex.importAliasEdges`) are deleted — branch `feat/infra-B2`
- `CallGraphImports` keeps its own import reading for task B3; what it needs is now in the shared layer:
  `TypeNameBinding.splitPath` (module / type / field of an import path), `importedTypes`, `wildcardTypes`,
  `filesOfModule`, the compiler's statement order (`tierOf`'s own-then-chain, last-first lists) and
  `TypeRefIndex.ambientUsings` — branch `feat/infra-B2`
- `SymbolIndex.resolvesToStdType` answered a yes for the WRITTEN name → `stdDeclarationOf` answers the declaration, and
  `dead-binder-counter-loop` / `prefer-count` take the container's name from it: `import haxe.ds.StringMap as List;`
  binds `List` to the std `StringMap` (4.3.7: an alias binds its alias name to the aliased type, `p3`), which is not a
  `List`. The old proof refused any alias spelling the name; the binding now answers it, so the name must be the
  declaration's — branch `feat/infra-B2`
- test fixtures that put a type in a module of another name (`a.hx` declaring `Foo`, `F0.hx`, `L1.hx`, one `Res.hx`
  holding several model classes) or wrote `using Other;` for a same-package `p.Other` resolved only through the old
  lax reading: 4.3.7 sees no sub-type outside its module by its bare name (`p7c`) and reads every import path
  absolutely (`import Other;` in package `p` is `Type not found`, `u1`..`u4`). Fixed as fixtures, not as engine
  leniency: `QueryTestHelpers.rootModules` names each source after its first type under its package directory, a
  repeated module on a second class path (`cpN/`) — the shape two declarations of one module really have; 20
  `CrossRenameMemberSliceTest` fixtures renamed; `OrphanAccessorCheckTest`'s parent-package case is now RESOLVED (a
  proven orphan, `Warning`) and its speculative-fallback tests moved to an unrelated package — branch `feat/infra-B2`
- the binding was to read a module outside the index by parsing every scope file of its name, and the scope was to be
  read with one `haxelib libpath` per declared library → measured on the client corpus (`--rule thread-safety`, 5.8 → 7.8 s): 0.72 s
  was twenty serial `haxelib libpath` spawns, 0.45 s parsing imported library modules. `haxelib libpath a b …` takes
  several names and prints one root per line (`HaxelibResolver.libSourceDirs`; a failed or short answer — one name not
  installed fails the call whole — falls back to a call per name). The module is the file the compiler loads,
  `<root>/a/b/C.hx`, and it is parsed only when its text spells the asked name (a file that never spells it declares no
  type of it); a ROOT module's path is its bare file name, which any directory holds, so its candidates are parsed and
  their package compared — taking `openfl/events/EventDispatcher.hx` for a toplevel `EventDispatcher` lost 6 findings
  on bd943dac before that check — branch `feat/infra-B2`
- the call graph kept its own `bindFor` memo over a second `Refs.findMulti` walk of every file → the binding of a
  reference is `TypeResolver.bindingAt`, memoized per tree and name in the run's `RefsCache` (the walk every other
  `Refs.find` caller already shares); results are per-name independent, so nothing changes — branch `feat/infra-B3`
- the call graph read imported statics and the module's own module-level names its own way (`CallGraphImports.
  importedStatics` / `fieldAliases`, `CallGraphNames.moduleLevelNames` over any named module node) → the index records
  each module's module-level VALUE declarations (`FileInfo.moduleFields`: functions, `var`s, `final`s, a conditional
  region's too — no types, imports or aliases), and `ValueNameBinding` (the index's `values` layer) answers a bare
  value name by declaration: the module field first, then the statics each import binds, owners looked up in the
  binding's module table so a namesake in another package lends nothing. Probed on 4.3.7 (`b3-scratch/hx/{g5c,mf}`):
  a module function beats an `import A.*` static of the name; `import p.Mod.f;` binds a module-level field of module
  `p.Mod`, while `import p.Mod.*;` brings in only the TYPE `Mod`'s statics (`Unknown identifier : helper`); an alias
  whose path does not decode is now `unknown` (it may name any static) — branch `feat/infra-B3`
- a module-level function resolved a bare name through the module's MAIN CLASS's chain (the module pseudo-type shares
  its name), so `function helper() go();` in `C.hx` with `class C extends P` ran `P.go` (review L3 G5) → module-level
  code sees no class's members: 4.3.7 answers the main class's own static called bare there with `Unknown identifier`,
  and a static an import binds is what the name means, as a call and as a value — branch `feat/infra-B3`
- the graph's node ids stay `Simple.member`, namesakes folded into one node: 28 simple names are declared twice in the client corpus
  (`fs.VolumeWatcher` / `logs.VolumeWatcher`, `Main`, `Logs`…) and 37 thread-safety truth keys sit on them, so keying
  namesakes apart by path would rename those keys; B3 moves RESOLUTION onto the shared layers, not node identity —
  branch `feat/infra-B3`
- the call graph read import statements for TYPE names its own way (`CallGraphImports` `_typePaths` / `_wildPackages` /
  `_guardedPaths` / `_ownTypes` / `_packages`, `boundPath`, `wildcardPath`, `packagePath`, `typeImportOf`,
  `namesStandard`) → every type a name may be on some build is `TypeNameBinding.bindingsOf` — `bound` (what the order
  binds it to where it can read it), `guarded` (an `#if`-guarded statement's type on its builds), `unlisted` (a package
  wildcard the order cannot list) — in the compiler's order; the graph keys a declaration by its simple name and a type
  outside the indexes by its path when a declaration bears its simple name, as before. A module nothing reads binds
  only the type its import names (the old reading too), never every name written beside it; the package tier reads the
  std core's modules package by package, interleaved with the project's (4.3.7 finds both on its class paths) — branch
  `feat/infra-B3`
- a type written in a file is now SPELLED by the path of the type that file binds it to (`CallGraphImports.writtenAs`:
  a declaration's canonical path, `TypeNameBinding.canonicalPath` — a main type by its module, a sub-type by its module
  and name; 4.3.7: `p.Sub` for a sub-type is `Type not found`), every spelling keying as the bare name did. The text
  carries its file, so a container read in another file than its declaration's is decided as written there (review L3
  G6), and the std container is the std's only when the declaration at that path sits in a std file
  (`StdResolver.isStdFile`) — a project `haxe/ds/Vector.hx` or root `List.hx` shadows the std's (review L3 G2, probe
  `hx/g2`). Fixtures that stubbed the std at `std/Array.hx` stub it at the real std's path
  (`QueryTestHelpers.stdPath`) — branch `feat/infra-B3`
- the graph's wildcard candidates came from "a package the tables do not hold a declaration of the name in", which
  over a project package with an `import pkg.*;` invented `pkg.T` for every name: on the client corpus 980 of 37 k edges went to such
  placeholders (`components.editor.equipments.RightPanel.x`) → an indexed package lists its modules, so no candidate;
  thread-safety findings on the client corpus unchanged — branch `feat/infra-B3`
- a `using` of a module brought the static extensions of its last segment's type only → every non-private type of the
  module (`ValueNameBinding.usingTypes`; 4.3.7, `hx/us`: `using p.Mod;` brings `Sub`'s extensions too) — branch
  `feat/infra-B3`
- the graph's supertype tables unioned the SIMPLE names every declaration of a name wrote (`t.supertypes`), so `class
  Mine extends sys.thread.Lock` beside a project `utils.Lock` inherited the project's `wait` → each supertype is keyed
  where its declaration writes it (`CallGraphImports.typeOf` over the shared binding), the declarations of one name
  still folding into one node; client thread-safety findings unchanged — branch `feat/infra-B3`
- the graph's type tables had outside readers (`CatchTypes`, `ExhaustiveSwitches`, `LockWindow`, `ThrowReach`,
  `ThreadSafety.inheritsNothingNamed`, `AbstractReach`, `ReflectiveReach`, `ReflectiveValues`) → they read the index the
  graph was built over (`CallGraph.index`) through its layers: `SubtypeGraph.isSubtype` / `subtypeNamesClosure` /
  `supertypeNamesClosure`, `MemberLookup.supertypesDeclareNone` (new: a supertype link naming two declarations proves
  nothing, an unread interface may declare anything, an unread superclass only by an override), `MemberLookup.
  declaringHost` (new: the member's declaration and the type hosting it), `TypeRefIndex.aliasedName` (new: typedef hops
  each ONE declaration, resolved where written). The graph's generics table moved into the graph family
  (`TypeParamTable` → `CallGraphGenerics`); `ReflectiveReach` still asks it for the arguments a subtype's chain passes
  (`argumentsFor`), the one question no shared layer answers yet — branch `feat/infra-B3`
- the refactoring ops kept their shared steps as per-op copies, so a fix made in one had to be found and made in the
  others (`1740e907` went to both extract ops; ChangeSig / RemoveParam shared 11 of 15 commits) → one core per family,
  every op calling it and its copy deleted: `TypeExtraction` (`sourceClass`, `uniqueClass`, `superNameOf`,
  `referencedMembers`, `carriedImports`, `assembleTypeFile`, `headerInsertEdit`, `rewriteSource`, `rewritesNotes`) for
  `extract-interface` / `extract-superclass` / `pull-up` / `push-down`; `SignatureEdit` (`resolve`, `arityRefusal`,
  `commit`, `crossFileAdvisory`) for `change-sig` / `remove-param` / `add-param`; `ScopeFiles` (`ParsedFile`,
  `parseScope`, `unparsedRefusal`, `uniquenessRefusal`, `editsFor`, `applyAll`) for `rename --scope` (type and member),
  `move`, `move-member`, `pull-up`; `ParseGate` for the `<label> does not parse: …` gate both ends of those ops run;
  `RefactorSupport.typeDeclsNamed` / `typeBodyCloseOffset` / `valueBoundOffsets`, `ElementSpan.memberCutSpan` and
  `SourceText.lineStartAt` for the lookups and scans each op re-wrote (also `AddMember`, `SafeDelete`, `MakeFinal`,
  `ExtractVar`, `MoveScaffold`). Behaviour is byte-identical — the ops' suites and a corpus run of every op over the client corpus
  sources before and after compare equal; the three `*-RAW-SPLICE` arms are one, `M-SIGNATURE-EDIT-RAW-SPLICE`, on
  `SignatureEdit.commit`, the one `editKeepingCanonical` call those three ops have left — branch `feat/infra-B7`
- `InheritanceMove.parseScope` is NOT `ScopeFiles.parseScope`: it refuses on the FIRST file that does not parse and
  names only it (`cannot move across scope: <file> does not parse`), where the rename / move gate names every one;
  `MoveMember.resolveMove`'s own parse loop words it `<file> does not parse: <message>` without the `ParseError`
  position. Folding either would change an op's message, so both stay; they share `ParsedFile` — branch `feat/infra-B7`
- a name binding learns which types an imported library or std module declares by parsing that module whole (B3: 170
  modules, 2.7 MB per client run, +0.8 s of `--rule thread-safety`), and the substring pre-filter in front of it ("parse
  only a file that spells the name") filtered none of them out → a DECLARATIONS-ONLY read through the grammar: the
  span parser with a `BodySkip` jumps each `@:skimmable` function body (`HxFnBlock.stmts`) from `{` to its matching
  `}` over the grammar's own non-code regions (`lexicalRegions`) and directive marks (`CondDirectives.skipMarks`), and
  reads it element by element wherever the balance is not proven (a directive branch not back at its region's depth,
  a region opened in the body still open at its close, a directive of an outer region, no close). No keyword scanner
  of its own: the delimiters are the field's `@:lead` / `@:trail`, the vocabulary `RefShape`'s. One reader for every
  consumer of a module's declarations outside the index (`IndexScope.declarationsOf` → `SymbolIndexHost.
  declarationsOf`, memoised per file, off the run's full root when it already holds one; `StdTypes` and
  `moduleTypesInScope`); `DeclarationsReadTest` pins it equal to the full read on every `src/anyparse/query` source.
  Two answers change, both toward the compiler: a module whose BODY the grammar cannot read still declares its types
  (a body declares none), and a scope file at `a/b/C.hx` whose package is not `a.b` is no longer the module `a.b.C` for
  a name it never spells either — branch `feat/infra-B4`
- whether a stored value's field is exposed was asked of the node HOLDING the field, which under `#if` is the region, so
  a `@:publicFields` type's field read as private (review L3 G1, `f1x`) → `StoredValues` asks of the type declaration
  (`TypeResolver.enclosingTypeDecl`), and `MemberKinds.fieldExposed` reads the modifiers of a type declared through a
  `final` wrapper on the wrapper (`@:publicFields final class` exposed nothing to FIAD either) — branch `feat/infra-B4`
- a function's own type parameter was bound by argument POSITION even where a skipped optional parameter shifts the
  arguments (`f<T>(?n:Int, x:T, ?y:L)` called `f(s, u)` took `T` for `L`; review L3 G3) → from the first argument that
  may shift (`CallGraphKeys.mayShift`) no parameter is proven bound, and a type parameter one of them is written as is
  unknown — branch `feat/infra-B4`
- `@:overload` signatures agreed by return TEXT, so `function<T>(x:T):T` matched the class's `T` (review L3 G4) → a
  signature declaring type parameters of its own (`typeParamNames` by declaration offset) makes every signature disagree
  — branch `feat/infra-B4`
- `PatternNameScope` read the file's module-level names off the tree (package and import paths included, review L3
  low) and what an import brings by its own kind-by-kind reading; `MacroIndex` matched an import's last segments against
  ANY declared type name → both ask the shared bindings: `FileInfo.moduleFields`, `ValueNameBinding.mayImportValue`
  (4.3.7, `hx/pns`, `hx/ctor`: a whole-module import brings its module-level fields and its sub-type enum's
  constructors, a sub-type import and a wildcard over it the constructors, an alias of the main type neither) and
  `unlistedImportOf`, `TypeNameBinding.bindingsOf` for a written receiver. The gate's answer is now the path the
  compiler binds the name to — `import m.Lang as L;` and `import m.*;` name `m.Lang`, so a whitelisted `m.Lang.t`
  clears them — and the ambient chain's imports count as the file's own do — branch `feat/infra-B4`
- typing copies kept arcs the shared typer lacked: `PreferStaticExtension` typed a string literal and `this` inside an
  abstract itself, `LambdaLoopScan` a construction, and five readers took a container's element (or a type's path) off
  its written type each their own way (`PreferComprehension.elementTypeOf` keyed by the full written path, `MemberReach.
  elementType` arrays only, `FieldWriteIndex.elementTypeSource`, `CallGraph.elementTypeSource`, `NominalTypes`' own
  for-binder tail; `PreferArrowCallback.receiverNominal`, `CallGraphKeys.outerPathOf`) → the deep walk of `NominalTypes`
  reads a literal as its type, a construction as the type it writes (nominal only: `new Box(item)` spells no
  arguments), and `this` inside a `RefShape.underlyingThisTypeKinds` type as its underlying type (4.3.7 types `this` in
  `abstract A(T)` as `T`); `elementTypeSourceOf` / `outerPathOf` are the one written-type reading, keyed by the simple
  name, wrappers peeled to a fixed point, and which container it IS stays each caller's question
  (`isStandard`, `arrayTypeNames`). `NominalTypes.expressionTypeSource` is the SOURCE mode: the same deep walk at source
  level, plus a method call whose declarations write one return naming no type parameter. `DefaultRepeatedArgument`
  reads a receiver's declared type through `TypeResolver.identTypeName` instead of its own `Refs.find` memo. All-rules
  on the four trees unchanged — branch `feat/infra-B4`
- ONE structural walk, TWO resolution models (B4b design, recorded before the move). The call graph typed an expression
  with its own walk (`typeSourceOf`: identifier, field, element, call, construction, with `keys.throughInitializer`
  for an unannotated local) while `NominalTypes`' deep SOURCE mode walked the same shapes over the `SymbolIndex`. The two
  differ in what a type VALUE is, not in which shape answers what: the graph's is a type source spelled as it keys
  types (`CallGraphKeys.keyedIn`: every name in the canonical spelling of what the WRITING file binds it to, so the text
  resolves on its own and its node ids stay `Simple.member` — 28 client names are declared twice, 37 truth keys sit on
  them), the index's a written source whose names resolve in the file that wrote them (`MemberPathWalk` resolves each
  link where its member is declared). Neither can stand in for the other: re-keying the index's answers would hand
  its consumers spellings they copy into the user's file (`explicit-local-type`), and reading the graph's keyed text
  by declaration would resolve a canonical path twice. So the SEAM is `NominalTypes.typeWalk<T, C>` over a
  `TypingHost<T, C>`: the walk owns the shape dispatch (parentheses, literal, the self reference, a binding with its
  annotation, an unannotated binding's initializer and a loop binder's element under ONE cycle guard, an unbound name,
  a field access, an element, a call, a construction) and the host owns resolution in its own currency `T` — what a
  binding's annotation, a member, a call, an element ARE. `C` is what a walk threads (the graph's enclosing type). The
  host answers a field access and a call itself, given the walk to type a receiver with, because the index resolves a
  whole path from its root in one walk (`pathReceiverMemberTypeSource`: import-aware, then package-blind) where the graph
  goes link by link. An arc a host does not know answers null, never a guess; an arc one host learns is added to the
  other only as its own measured change. Moved first as a pure move (each host answering exactly what its walk did),
  all-rules byte-identical on the four trees — branch `feat/infra-B4b`
- the innermost type declaration holding a position had three walks: `TypeResolver.innermostTypeDecl` (by span),
  `MemberTouchScan.typeAt` (by offset, 19 callers across eight files) and `Rename.enclosingTypeDecl` (by offset), the
  second reading `CallGraphNames.typeNameOf`, whose `EXTRA_TYPE_DECL_KINDS` arm was dead (`MemberKinds.TYPE_DECL_KINDS`
  already lists `AbstractClassDecl` and `EnumAbstractDecl`) → ONE walk, `TypeResolver.enclosingTypeDeclAt(tree, at, ?to)`,
  entering only the nodes that hold the range (what `typeAt` did; the span walk visited the whole tree);
  `enclosingTypeDecl` / `enclosingTypeName` are its span spellings, `typeNameOf` callers ask `RefactorSupport.typeDeclOf`,
  and `ImplicitSites.typeOf` drops its own self-reference arm, which the walk answers the same way. All-rules
  byte-identical on the four trees — branch `feat/infra-B4b`
- which children of a construction are its TYPE arguments was decided three ways: `LiteralInfer` scanned the text after
  `new` for a balanced `<…>` (a `>` after `-` read as an arrow), while `ValueEscapes` and the graph's argument
  expectation (`expectedAt`) took the children of a `typeAnnotationKinds` kind — a list without `Parens` or
  `ConstStringType`, so `new Box<(Int)>(f)` handed `f` the constructor's SECOND parameter → `NominalTypes.
  writtenConstruction` reads the grammar's children and lets the separators between them say which list each belongs
  to (the first gap holding `(` starts the constructor's); a shape they do not spell consistently answers null. The
  three consumers read its `path` / `args` / `text` (the arguments verbatim). All-rules byte-identical on the four
  trees; `CallGraphTest` `C.paren` red on the start commit — branch `feat/infra-B4b`
- "the type of a local written with no type is its initializer's" had three copies: the graph recorded only a CALL
  initializer (`CallGraphKeys.callInitializers`, read by `throughInitializer`), `ValueEscapes` read any initializer
  ending before the use, `NominalTypes`' deep walk none → ONE arc: `NominalTypes.localInitializer` (a local declaration,
  no annotation, an initializer that ends before the use) behind the walk's `TypingHost.initializer`, under the walk's
  one cycle guard, for both hosts; `ValueEscapes` asks it too. 4.3.7 types `var l = lock;` as `lock`'s type, so a field
  read, another such local and a literal now type the local the way a call did; a `new` keeps its eager entry in
  `typeLocals` (the graph's `declaredTypes` reads it). All-rules byte-identical and the thread-safety score unchanged on
  the four trees (their locals are annotated); `ThreadSafetyPositiveSinksTest` `C.field` / `C.alias` red on the start
  commit. `M-TS-LOCAL-CALL-INIT` retired with the table it cut — branch `feat/infra-B4b`
- the graph typed an identifier receiver twice: `identDeclaredType` read the provider's simple-name table re-keyed
  (`CallGraphKeys.declaredTypes`, `Null<T>` peeled by `nullableInner`) ahead of the walk, which reads the keyed written
  annotation; and it typed a local a `new` initialises eagerly (`CallGraphKeys.typeLocals`) as well as through the
  walk → the walk alone: `receiverType`'s identifier arm keeps only the bare type-name receiver and lets the walk and
  `nominalOf` (type parameter bound, alias, keyed path) answer a value, the std-property read asks the same two, and
  `declaredTypes`, `nullableInner`, `typeLocals` are gone. All-rules and the thread-safety score unchanged on the four
  trees — branch `feat/infra-B4b`
- the graph typed a CALL two ways: the walk's call arm read the written return through `returnThrough`, while a call in
  RECEIVER position went through `returnedNominal`, which re-derived the return's simple name from the declaration
  facts (`returns`) and `keys.returnedPath` before the same `returnThrough` → one reading, `targetReturnSource`, behind
  both; the receiver keeps its policy that a call returning a nullable or dynamic wrapper names no dispatchable type.
  What stays the graph host's own, by design, is what the index model has no counterpart for: `nominalOf` (a keyed source
  to the type a member lookup dispatches on, a type parameter to its bound), `memberReturn` (a member's return on a keyed
  type, for `iterator()`/`next()`), `argumentTypeSource` (a call argument's expected type) and `receiverType`'s
  classification (value / type / dynamic receiver). All-rules and the thread-safety score unchanged on the four trees —
  branch `feat/infra-B4b`
- `MemberTouchScan.builtinTypeOf` typed a string literal and a binding's annotation itself, and `FieldWrites.typeOf`
  answered the self reference with the graph node's type ahead of the deep walk → both ask the walk: `builtinTypeOf`
  keeps only the array literal and the fresh-returning call (the freshness question's own arcs) and reads the rest off
  `NominalTypes.expressionTypeSource` with no index — the arcs that need no file: a literal, an annotation, an
  initializer, a loop binder — so `var s = text; s.split(",")` is a fresh array now (red on the start commit,
  `MemberReachTest`); `FieldWrites` drops its self arm, the walk answering the enclosing class the same way and, inside
  an abstract, its underlying type (4.3.7) — two reflective-write probes inside an abstract placed nothing either way.
  `RedundantToString.resolveReceiver` stays: its answer is a DECLARATION tier with a non-null proof (`OperandBinder`,
  `DeclaredNullity`), a currency the walk does not carry; its overlap with the walk is the node-kind dispatch alone.
  All-rules and the thread-safety score unchanged on the four trees — branch `feat/infra-B4b`
- rule tests ran a check the way production never does: 481 direct `check.run(files, new HaxeQueryPlugin())` sites
  skipped `Linter.collect` (reification gate, suppression, the per-file gates) on a bare plugin with no run host, 174
  classes re-implemented `violations`, a dozen `applyFix` helpers re-implemented the splice, `CheckFixture.applyEdits`
  was a copy of `CanonicalEdit.applyEdits` without its same-`from` tie-break, a fix was asked with no index although
  `LintFixDriver` always hands the report index, and 170 test sites built a `SymbolIndex` themselves → ONE test kit,
  `unit.CheckFixture`: `violations` / `violationsIn` read through `Linter.collect` on a `CachingGrammarPlugin` host (a
  given resolver is the run's, set on a `ConfigAware` check AND handed to `collect`, enablement off as under `--rule`);
  `fixRun` / `edits` / `fixOf` / `fixedSource` hand `fix` the same host and the report index of the run's files;
  `index` asks `IndexScope.over`. A class keeps a one-line `violations(src)` that names its check — the binding is the
  class's, the run is the fixture's. Kept on the raw path on purpose: the tests that PIN the raw `Check.run` contract
  (`ReificationGateTest`, `ReificationGateFixPathTest`) and the builder's own `SymbolIndex*Test`. A test that went red
  under the production path is a finding, not a fixture to bend: `RedundantParensCheckTest` (four splice-in-macro fixes
  production drops, the rule is not `QuotationAware`) and `PreferArrayLiteralCheckTest.testThisFieldAssignmentNeedsIndex`
  (the index-less refusal `lint --fix` never reaches) stay on the old call, commented; so does
  `ThreadSafetyCheckTest.testNoFindingInAFileWhoseChainWritesNoOption`, whose arm M-TS-REPORT-UNGATED survived through
  the fixture — `Linter.runGated` re-applies the rule's own `GraphScoped` report gate — branch `feat/infra-B8`
- the compiler's facts were said to be read by three parallel readers, `FactsView`, `FactsTypeOracle` and
  `TypedFactsWalk` → `TypedFactsWalk` is the macro-time WRITER of the dump and never sees the table; `TypedFactsProbe`
  builds the table. The layer has two reading doors over one table, by the question asked: `FactsView` reads the facts
  against the project (a `ReachProject`: the reach analyses, thread-safety's graph), `FactsTypeOracle` reads them placed
  in a file's text now (the journal, the member holding a range) and is the `TypeOracle` a structural rule asks
  (`forFix`). Every other class naming `CompilerFacts` is a part of the layer answering from the facts alone
  (`ArgumentUses`, `UncheckedConversions`, `StaticExtensionFacts`, …) or the producer and host; a rule or an analysis
  asks a door (`ownedTypes`). `FactsView.table` is private, granted to the layer's parts by `@:allow` — branch
  `feat/infra-B5`
- the rule-level readers kept copies of the doors' readings: the "every configuration contributed" gate three times
  (`FactsView.of`, `FactsTypeOracle.runFacts`, `StaticExtensionFacts.judge`), "the facts hold every build" in
  `MemberReach.factsAreTruth`, the agreed type of an expression at a range twice (`FactsTypeOracle.typedAt`,
  `StaticExtensionFacts.receiverType`), a facts signature's parts by a hand-rolled bracket scan twice
  (`FactsTypeOracle.resultOf`, `StaticExtensionFacts.firstParamOf`), a supertype chain's member by a scan of every typed
  id (`UnusedPrivate.supertypeDecline`) → one each: `CompilerFacts.complete`, `FactsView.of(table, scope,
  configurations)` (the truth is the view's to decide), `CompilerFacts.valueTypesAt`, `FactsTypeTree`,
  `FactsTypeOracle.inheritedMember`. The static-extension proof now places its receiver as the oracle places any
  expression (`factsTypeAt`): a range after an escape in a string, or one the facts hold in another member or type than
  the file does now (a module-level function's, which the oracle does not place yet), declines instead of being read
  raw, and a value only a flow types is typed. No finding of the oracle-assisted run on the client corpus changed — branch
  `feat/infra-B5`
- B5's leftover in a B4b-owned file: `MemberTouchScan` still read the facts table itself (`view.table.node` /
  `.keyOf`) and three `CompilerFacts` statics (`spliceOf`, `expansionOf`, `expansionSites`) → the view's facade
  answers all five (`FactsView.spliceOf` / `expansionOf` / `expansionSites` added beside `node` / `keyOf`), its
  `@:allow(MemberTouchScan)` grant is gone and the field is `_table`, read only by the facts layer's own parts.
  owned-types 12 -> 9 (CompilerFacts 3 -> 0) — branch `feat/infra-B4b`
- a fix asked with no index was pinned as a rule's behaviour (148 inline `check.fix(src, vs, plugin)` sites, the
  multi-file ones among them) → no production path passes none: `LintFixDriver` and `FixVerifier` both hand the
  report index (`fixGrouped` / `fixCarrying` too), so every site now goes through `CheckFixture` (`fixOf` / `fixIn`
  / `fixRun`, `fixIn` refusing a finding of another file), and the tests that pinned the index-less answer were
  restated: `PreferArrayLiteralCheckTest.testThisFieldAssignmentNeedsIndex`, `TypeResolverSliceTest.testNoIndexKept`
  and `NamingCheckMemberFixTest`'s two private-field refusals duplicated a production twin and are gone;
  `FieldInitInConstructorCheckTest`'s folds now assert the extracted constant the index lets in;
  `ExplicitTypeCheckTest.testFixWithoutIndexSkips` became the same-file interface it resolves; `EmptyCaseArmCheckTest`
  keeps only its indexed half — branch `feat/infra-B8b`
- `ThreadSafety.run` filtered its own findings by the report gate → `Linter.runGated` applies the same `GraphScoped`
  gate to every graph-scoped rule and is the one door a run goes through, so the rule's copy was unobservable in
  production; it is gone, and M-TS-REPORT-UNGATED cuts `runGated` — branch `feat/infra-B8b`
- `redundant-parens` was believed unsafe inside a `macro` quotation (the reification gate dropped every quoted finding,
  so its splice gates were unreachable) → a pair dropped in a delimited slot types the same (Haxe 4.3.7: `EParenthesis`
  is transparent to the typer; `$a{…}` arity is gated; a spliced `for` / `=>` array element does not compile with the
  pair; the operand arms stay opaque), so the rule is `QuotationAware`, its reason on the class doc — branch
  `feat/infra-B8b`
- five arms broken on main were read as dead mutation targets → each fixture had stopped reaching its gate (a type
  out of scope, a literal the resolver now types, an earlier decline, an alias the syntax now resolves, a call the
  graph resolves), and re-aimed fixtures kill all five; the sixth, M-ESCAPE-RECEIVER-CALL, cuts a `ValueEscapes.call`
  precision branch no probed shape reaches (28, syntax and facts) — left to the `ValueEscapes` owner — branch
  `feat/infra-B8b`
- `ValueEscapes`' call with no graph target had a fallback typing the receiver itself (`typeOf`) and handing on only the
  arguments of a project method's untyped parameters; B8b probed 28 shapes (21 syntax, 7 facts) and none reached it,
  and since the graph types a receiver through the same walk (`NominalTypes.typeWalk`) — annotation, initializer,
  member, call, construction — no receiver it leaves untyped is typed by `typeOf`'s syntax tier → the branch is gone and
  such a call hands everything on, the sound direction; `M-ESCAPE-RECEIVER-CALL` retired with it, its control re-pinned
  to `M-TS-NEW-RECEIVER`. The `new` argument split there reads `NominalTypes.writtenConstruction` like the graph's.
  All-rules unchanged on the four trees — branch `feat/infra-B4b`
- the grammar's derived vocabulary was respelled per rule — `functionKinds ∪ nestedFunctionKinds` three times,
  `localFunctionKinds ∪ inlineFunctionKinds` five, `functionKinds ∪ lambdaKinds` fifteen, the `try` / `if` / case-arm
  unions five to eight times each, the return kinds in three shapes, the loop kinds read raw beside `Loops.kindsOf`, and
  `NullFlow` carried the Haxe loop / conditional / `switch` / `try` sets as LITERAL lists read by `DeadStore`,
  `DefiniteAssignmentGuard` and `JoinSingleUseLocal` → one home, `anyparse.query.ShapeVocab` (`loopKinds`,
  `statementLoopKinds`, `nestedFunctionKinds` and `functionLikeKinds`, `localFunctionScopeKinds`, `functionOrLambdaKinds`,
  `lambdaOrLocalFunctionKinds`, `returnStatementKinds` / `returnKinds`, `tryKinds`, `ifKinds` / `conditionalKinds`,
  `switchArmKinds`); `Loops.kindsOf`, `MemberKinds.nestedFunctionKinds`, `ArgumentValues.conditionalKinds`,
  `IfExpressionChain.conditionalKinds` and `NullFlow.IF/LOOP/PRE_TEST_LOOP/SWITCH/TRY/BRANCHY_KINDS` are gone. Each
  union is replaced only where the site spelled exactly it (same seams; each kind once, which no reader's `contains`
  sees); a site that unions a NARROWER set keeps it and is named instead: `functionKinds ∪ lambdaKinds` misses
  `NamedFnExpr` and `LocalInlineFnStmt` (fifteen sites, now one spelling to widen), `PreferLambdaExpressionBody`'s
  control-flow kinds and `LoopGuard` read `loopStatementKinds` without `do … while` — candidates, not changed here.
  All-rules lint on the three client trees and anyparse: byte-identical — branch `feat/infra-B6a`
- `guard-continue` and `guard-return` decided the same `if` shape, glue comment, clean-inversion report gate, splice and
  fix lookup in two copies edited in step (15 shared commits) → `anyparse.check.GuardScan` (`seamsOf`, `guardedIf`,
  `headerHasComment`, `report`, `splice`, `index`, `edits`); each rule keeps where its `if` sits, its tail and what it
  emits — branch `feat/infra-B6a`
- "the operand compared with `null`" had nine answers — `NullFlow.nullComparisonOperand`, `BoolExprShape`'s private
  copy, and inline ones in eleven rules, some first-null-wins (`null == null` answered the null literal as the
  operand), one right-side-only (`CtorFieldFold` saw `p != null` but not `null != p`) → `NodeShape.nullComparedSide` /
  `nullComparedIdent`: exactly one side the null literal, each side optionally read through parentheses, the
  comparison kind the caller's. Haxe 4.3.7 treats `null != p` as the same guard (it narrows `p` under strict
  null-safety), so `prefer-final-public-field` now folds the swapped spelling too
  (`testCtorConditionalDefaultSwappedGuardFixed`, red on the start commit); `null == null` names no operand, which
  every former first-null-wins caller already discarded downstream — branch `feat/infra-B6a`
- the private `isIdentChar` / `isSpace` / `lineStartOf` / `lastSegment` / `nodeAt` copies were read as one question
  each → most were (byte-equal bodies, deleted for `SourceText` / `TreePath` / `MacroNames`), but not all, and the ones
  that differ stay: `CommentProse.isIdentChar` admits `$` (a macro splice in a comment's prose), `LintFixSafePass.isSpace`
  and `AccessorClauseText.isHorizontalSpace` are space-and-tab only, `BlockCommentNormalizer.isSpace` lives in the
  format layer, which reads nothing of `anyparse.query`. Two line-start answers are both right and are kept apart by
  name: `SourceText.lineStartOf` gives the line AFTER a newline offset, `lineStartAt` the line that newline ends
  (`FoldStringLiterals`, `PreferLineComment` and `PreferCaseGuard` scanned the second; no caller hands either a newline
  offset, so routing each to its own twin changed no answer). The macro layer and the macro-time facts probe
  (`TypedFactsMacro`, `TypedFactsWalk`) read nothing of `anyparse.query` either, so their dotted-path splits go to
  `MacroNames` or stay; the nodeAt copies' walk is `TreePath.firstAround` (pre-order, containment-pruned), which also
  finds a match past a first containing child the greedy descent of `FunctionTrees` / `LockAliases` gave up on — branch
  `feat/infra-B6b`
- hand-rolled `<` scans of type text were read as seven parsers → three were not type text at all (`MemberWriteScan`
  operator characters, `Pattern.isStarSlot` punctuation, `LintFormat` XML escaping) and `CompilerFacts.baseId` is the
  facts primitive; the real ones read through the reader of their grammar: SOURCE text through `TypeSyntax`
  (`PreferMapType` by the new `TypeSyntax.argumentsOpen`, `ExhaustiveSwitches` by the `Nominal` path — the path as
  written, as the split gave it), COMPILER text through the facts readers (`MemberReach.outerTypeName` by
  `FactsTypeTree`, `FactsView.unwrapped` by the new `FactsTypeText.unwrap`, which peels a wrapper only when its `<`
  closes at the end) — branch `feat/infra-B6b`
- the two compiler-diagnostic readers were read as one being merely terser → `LintFixVerify.errorMentionsFile` blamed
  the wrong file: a basename match (`other/A.hx` blamed `src/A.hx`), a warning counted as a cause, a pretty-reported
  error unread behind its ANSI badge. The oracle batch now asks `LintFixSafePass.blames` (the safe pass's
  `errorFiles` + segment-aligned `samePath`) and the copy is gone — branch `feat/infra-B6b`
- the token-based hxml reader (`OracleCache.hxmlRefs`: several flags per line, tab as a separator) was taken as the
  stronger of the two → Haxe 4.3.7 reads an hxml as an argv the other way round: a line is trimmed and unquoted, a `#`
  only leads a comment, and a line starting with `-` is split ONCE at its first space (`-cp a -cp b` is the one
  classpath `a -cp b`, `-cp<TAB>src` an unknown option, a flag's value may stand on the next line; probed with
  `--interp` builds). `OracleCache.hxmlArgs` reads that argv, `hxmlRefs` walks it, and
  `OracleDeclaration.relativeClasspaths` (line prefixes, quotes kept) asks `hxmlRefs`. A fingerprint over an hxml
  spelled the old way changes once. The compile-dir probe still does not follow an include: it resolves against the
  directory being decided — branch `feat/infra-B6b`
- the ops left outside `ParseGate` by B7 were read as needing their own catch → none did: 30 parse sites in 23 ops
  (the input gate and the rewritten-source gate) now ask `ParseGate.parse` / `refusal` under the label they printed,
  so the text is the gate's. Measured on 29 op entry points x 93 client files x a parsing and a broken source (11590
  answers, 5435 of them refusals): byte-identical. Two wordings change, both on paths the corpus never reached:
  `MakeFinal`'s rewritten-source refusal and `MoveMember`'s per-file scope parse (behind `ScopeFiles`' own refusal)
  quoted a grammar `ParseError` by its bare message and now quote it as every other gate does, with its `line:col`.
  The scope loops that word their refusal without a reason (`InheritanceMove`, `MakeFinal`, `SafeDelete`) keep their
  words and parse through the gate; `CanonicalEdit` and `NewFile` are writer round trips, not parses — branch
  `feat/infra-B6b`
- `ExplicitType` and `MoveMember` decoded `ImportKind` themselves → the name-resolution layer answers:
  `TypeRefIndex.plainImportPathOf` / `bindsUnderGuard` (moved from `ExplicitType`), `usings` / `plainImports` (what
  `MoveMember`'s scope guard reads). `MoveMember` now checks a file's `using` lines before its static imports, so a
  file carrying BOTH refusals names the `using` one whatever their order — branch `feat/infra-B6b`
- the enclosing-type copies B4b left beside `TypeResolver.enclosingTypeDeclAt` were read as other questions →
  `UnusedReturnValue.enclosingTypeName` was the same walk unpruned, `ParamAscription.enclosingTypeOf` the same answer
  read off an ancestor chain, `ExplicitType.enclosingType` the same answer over the index's type spans (Haxe nests no
  type, and the index and `typeDeclOf` read one kind list, `MemberKinds.TYPE_DECL_KINDS`); all three ask the walk now.
  `HaxeNamingSupport`'s `enclosingType` is a walk parameter, not a lookup — branch `feat/infra-B6b`
- `NominalTypes.typeWalk<T, C>` / `TypingHost<T, C>` carried a type parameter for the host's "currency", but both
  hosts (`INDEX_HOST`, the call graph's `graphTyping`) answer `String`: the currencies differ in how the source is
  SPELLED (keyed vs as written), which no type parameter distinguishes → `typeWalk<C>` / `TypingHost<C>`, answering a
  `Null<String>`; `C` (what a walk threads) still varies. All-rules byte-identical on the four trees — branch
  `feat/infra-B9`
- `IndexScope.fieldWriteIndexOf` had one caller, `resolutionWrites`, which it now is; the IndexScope docs named
  "FOUR call sites" of `widestScopeIndex` (seven by then) and a `resolutionProjectSourcesOf` "below" that lives in
  `RefactorSupport` → call-site lists dropped (they rot), the pointer qualified. `ScopeFiles.parseScope` caught a
  parse failure itself beside `ParseGate.parse` → asks the gate. Dead `SourceText.last/firstStandaloneIdentIndex` and
  `FactsView.typedElsewhere`'s unused graph parameter removed — branch `feat/infra-B9`
- a tolerant parse ("the tree, or null") had two homes and ~20 inline copies: `CheckScan.parseOrNull` for the check
  layer (118 callers), a `try plugin.parseFile(s) catch … null` written out at each graph, reach, op and CLI site that
  could not reach `check/` → ONE `ParseGate.parseOrNull` beside `parse` / `refusal` (moved there, every caller
  repointed by `move-member`, the inline copies replaced). Catching `Exception` alone is the old two-catch form: a
  `ParseError` IS an `Exception`. All-rules and both ops harnesses byte-identical — branch `feat/infra-B9`
- the compiler oracle was to turn the Haxe ANALYZER off (`--macro addGlobalMetadata("", "@:analyzer(ignore)", true, true, false)`)
  in every spawn that only typechecks or dumps facts → every spawn kind reads the compile's status or streams (a
  typecheck's verdict, a warm server's green, the facts compile's drop-on-error, the reach probe's `status != 0`), and
  the analyzer writes to both on haxe 4.3.7: it raises errors of its own ("Cannot use Void as value",
  `analyzerTexprTransformer.ml`, which an empty value `switch` relies on — `var a: Dynamic = cast v();` is rejected
  with it and accepted without it), and the ignore meta makes NEW warnings ("Unrecognized analyzer option: ignore",
  `filters.ml` `add_field_inits` runs the analyzer on a constructor under the class's meta — 481 lines on a client
  typecheck that printed none) and lands in the facts dump's type `meta`. The OCaml collector setting
  (`HaxeSpawn.DEFAULT_GC`) is the part kept — branch `feat/infra-O1`
- the narrower analyzer switches (`-D analyzer-no-fusion`, `analyzer-no-const-propagation`,
  `analyzer-no-copy-propagation`, `analyzer-no-local-dce`) were to keep the analyzer's own errors while dropping its
  cost → both break a build that compiles: without fusion the post-analyzer `sanitize` rejects the analyzer's own
  temporaries ("On static platforms, null can't be used as basic type Float"), and without const propagation an
  `inline` variable's initializer is no constant any more ("Inline variable initialization must be a constant
  value") — branch `feat/infra-O1`
- a larger minor heap than `s=16M` (`s=32M`, `s=64M`) was to buy more of the compile → no faster on a client typecheck or
  facts compile, and up to 0.4 GB more per process — branch `feat/infra-O1`
- the parallel process driver of `HaxeSpawn.runAll` hung about one run in thirty (`apq` asleep in `spawnSync`, the driver
  with no children blocked in `readFileSync(0)`, 13+ min until killed), and the suspicion was the stdin pipe's write end
  leaking into another child → not a leak: reproduced in plain node 20.18 with NO other process alive —
  `spawnSync(node, { input })` whose child reads its stdin hangs ~1 call in 700 at 200 KB (the real driver: 18 of 3000;
  inputs to 65 KB and 2.5 KB x 8000: none), and in each captured hang both socket queues were EMPTY
  (`netstat -f unix -A`: Recv-Q = Send-Q = 0) while the parent slept in `SyncProcessRunner` → `uv_run` → `kevent`: the
  writability wakeup for the rest of the input, or for the shutdown that is the child's EOF, never came. An oracle run's
  input grows with the invalidation jobs (configurations x moved paths). The jobs now reach the driver through a FILE
  (`writeJobs`, argv[5], the channel `PendingRuns` already used: the real driver, 0 of 3000) and the driver's stdin is
  the null device; it no longer reads stdin at all. A driver still running past `driverBound` (every round of
  `parallel` jobs the longest job's own timeout, 10 min for one naming none, + 60 s) is SIGKILLed — the one signal a
  node process blocked in a synchronous call, or stopped, cannot leave unanswered — in `runAll` (`spawnSync` timeout)
  and `PendingRuns.await` alike, and every job answers "did not answer within N ms and was killed". Not retried: a
  killed driver may have run any of its jobs (a generate command writes the tree). The cost of SIGKILL over SIGTERM: a
  wedged driver's non-tethered jobs are not killed with it (a compile runs to its end; a tethered server still dies, its
  stdin closing). Tests `HaxeSpawnTest.testTheDriverReadsItsJobsFromNoPipe` (deterministic: lsof/proc on the driver's
  fd 0), `testAWedgedDriverIsKilledAtItsBound`, `PendingRunsTest.testAWedgedBackgroundDriverIsKilledAtItsBound` (a job
  SIGSTOPs its driver, run in a `TestChild` so a failed bound cannot hang the suite) — branch `feat/infra-F1`
- the 40 functions over the cyclomatic threshold (C1) are split along their own decisions — a dispatch per kind, a
  validation ladder into named predicates, a loop body doing several jobs into one function per job — never into a
  closure or a ternary chain: a local function's branches count toward its enclosing function, and the point is the
  shape, not the number. Closures that carried an accumulator (`FactsEscapes.instances`, `CompilerFacts.within` /
  `materialize`, `NullGuardedCode.gathered`) became members threading it; a walk whose state crosses three per-body
  readers carries it in one struct (`MemberTouchScan.TouchWalk`). Two copies the split exposed now have one home:
  the per-argument classification `FunctionValueTypes.boundArguments` and `reflectiveConstructions` each spelled →
  `argumentFunction`; the lost-fact marker switch `FactsEscapes` and `FactsMethodValues` each spelled, differing in
  which spliced reflection is harmless → `FactMarkers.lossReason(id, n, harmlessSplice)`; and the four import-record
  literals of `SymbolIndexBuilder.extractFileInfo` → `importOf`. Kept whole: `Renderer.flatTokenWidthOfRestStack`'s
  frame loop (one stack machine threading five running values on the formatter's hot path; only its pure final
  combination moved out). Macro-time splits keep the generated parsers and writers byte-identical — branch
  `feat/infra-C1`
- a type is declared at its RUNTIME path too, its package and its name (`CallGraphImports.recordFile`), not because a
  source may write it: for a sub-type `T` of `pkg/Other.hx`, Haxe 4.3.7 answers `Type not found : pkg.T` to both
  `var x:pkg.T` and `import pkg.T`, while `Type.getClassName(pkg.Other.T)` is `pkg.T` and `Type.resolveClass("pkg.T")`
  finds it. What reads that path is a declaration of the classes made from a computed name (`reflectiveClasses`,
  `ReflectiveReach.neverMade`), which names a class as `Type.resolveClass` does. The old comment ("what an import reads
  when a file does not name its module") described a written path no compiler accepts, and its arm
  (`M-TS-PATH-DECLARED-PACKAGE`) survived because every pin wrote main types, whose package path is their module's path.
  Re-pinned on `ThreadSafetyReflectiveSealTest#testATypeParameterReceiverIsBoundedByItsInstantiations` (a sub-type of
  `pkg.Nodes` declared reflective as `pkg.Node`) — branch `feat/infra-N3`
- `TypeMetaFacts.isEnum` and its tables (`_enums`, `_nonEnums`, `_enumKinds`, the constructor's `enumKinds`) are
  deleted: since `ReflectiveValues.enumType` asks the only declaration's kind itself (`ReflectiveReach.onlyDeclaration`,
  branch `feat/infra-B3c`) nothing read them, and `M-TS-ENUM-KIND`, which cut their writer, SURVIVED every sweep. The arm
  is re-aimed at `enumType` with the same cut (a structure typedef taken for an enum) and kills its pin,
  `ThreadSafetyReflectiveSealTest#testAStructureTypedefMayHoldALock`. `M-TS-PATH-IMPORT` is re-pinned on
  `ThreadSafetyPositiveSinksTest#testStdResultsTypeTheirReceivers`, the test its cut breaks: the import case of
  `testALibraryTypeIsNotItsProjectNamesake` is typed through a path that does not ask `CallGraphImports.typeOf` — branch
  `feat/infra-N3`
- the two narrower function unions B6a named are gone: `ShapeVocab.functionOrLambdaKinds` (`functionKinds ∪
  lambdaKinds`, 15 readers) and `lambdaOrLocalFunctionKinds` (5 readers) both left out the named function expression
  `function g() …` written as a value and the local `inline function`, and every reader asked a question those two answer
  like any other function (Haxe 4.3.7 `--interp`: `function g` binds `g` in the enclosing scope AND in its own body, an
  `inline` local function has its own `return`, Haxe rejects a `final` field write in either). Readers asking "which
  function owns this — its scope, parameters, `return`s, return type, body" now read `functionLikeKinds`
  (`CasePatternScan`, `ExtractRepeatedExpression`, `JoinReturn`, `PreferSafeNavComparison`, `RedundantReplaceLoop`,
  `BinderScan.bindingScopeKinds` and through it `JoinSingleUseLocal` — whose own copy of the enclosing-function walk is
  deleted — `CrossRenameMember` (a pure respell: its body-child derivation already caught the named form),
  `ImplicitSites`, `MemberReach`, `MemberTouchScan.bodyDiscardsItsValue`, `NullGuardedCode`, `ValueEscapes`); readers
  asking "is this a body that runs later" read `nestedFunctionKinds` (`MemberTouchScan` capture, `LoopScan` /
  `PreferRangeLoop` capture, `CtorFieldWrite`, `ScratchField`). `ScratchField`'s own binder list is
  `BinderScan.binderKinds` now. A named function expression's name binds in the PARENT, so `bindingHostSubtree` steps out
  of it as out of a local function. Two of the old answers were unsound (`ValueEscapes` read a nested `return` against
  the enclosing METHOD's type, `MemberTouchScan.localEscape` missed a capture by a named function); the rest refused or
  missed a site. `loop-guard` visits a `do … while` (its `continue` goes on to the condition, the same equivalence;
  body = first child, a block body or an expression body holding the header `if`), and `guard-continue`'s deferral asks
  no loop kind any more. Kept: `prefer-lambda-expression-body` leaves `do … while` out (`() -> do x while (c)` does not
  parse in this grammar, Haxe accepts it); `ScratchField`'s `loopKinds` / `doWhileKinds` are two arms of one union (a
  do-while body all-conditional because a `continue` skips its rest); `FactsProvenance` reads the LOWERED loops (`for`
  and comprehensions), and no `do … while` is lowered — branch `feat/infra-N2`
- the 15 types over the oversized-type thresholds (C2) are split only where `hxq clusters` and the field census show a
  seam with state of its own or a natural home, never by member count: `LintConfig`'s document pipeline →
  `LintDocuments`; `HaxeQueryPlugin`'s 1229-line kind table → `HaxeRefShape` (answered the way `namingSupport` is);
  `SymbolIndexBuilder`'s type-body walk → `SymbolIndexMembers`; `Naming`'s rename proofs → `NamingRenames`, which
  `no-underscore-prefix` already drove through `@:access(Naming)`; `WriterLowering`'s `<writeFn>OpenRight` generator →
  `WriterPrattLowering`, beside `OPEN_NONE` and `guardOpenLeft`; `CompilerFacts`' node-record decoding →
  `FactNodeRecords` and its node-site queries → `FactSites`; `FactsEscapes`' type-parameter instances → `FactsInstances`;
  `ReachGraph`'s library-call predicates → `LibraryCalls` (and `declarationOf` → `ReachProject`, beside `siteOf`);
  `TypedFactsMacro`'s type-string printer → `TypedFactsTypeStrings`. Declined, each re-measured: `FactsView` (the
  owned-types door: 75 public questions, so no split reaches the threshold without forwarders, and every member shares
  `_table` / `_scope` / `truth`); `CallGraph` (as B9: 86 files read its public surface, `collectEdges` is one 1436-line
  member); `MemberReach`, `TypedFactsWalk`, `FunctionValueTypes`, `NullGuardedCode` (one component holds 85-90% of the
  non-hub members at every hub count tried, and that component holds every mutable field); the rest of
  `CompilerFacts`, `ReachGraph`, `FactsEscapes`, `TypedFactsMacro` (one table's caches, the graph's growth state, the
  escape walk, the record writer: every remaining member reads the same fields) — branch `feat/infra-C2`
- `apq rewrite` never hands a NAME-slot capture (`new $C()`, `final $x = …`, `a.$f`: the matcher's `NameOnly` binding)
  to `ParenGuard` as a hole (`Rewrite.isNameCapture`). The guard's premise that an illegal pair fails to parse is false
  after `new`: `new (A)()` parses as a call of an identifier `new`, so the type name looked both wrappable and
  unfaithful and `new $C()` came back as `new(A)()` (`new Zz${C}()` as `new Zz(A)()`). A name capture is one identifier
  or a dotted path, which no operator around it can re-read, so leaving it bare is exact rather than a guess (the
  type-argument capture recorded here as a limit is fixed by N9, below) — branch `feat/infra-N5`
- `try` and a braced block join the search-only kind-equivalence (`TryCatchStmt` / `TryCatchStmtBare` / `TryExpr`,
  `BlockStmt` / `BlockExpr`): a pattern parses through the Stmt attempt first, so `try $p.parseFile($s) catch
  (exception: Exception) null` rooted at `TryCatchStmtBare` and matched no initializer, argument or `return` — the 21
  sites a parse-or-null sweep was about, reported as 0 hits. The value form's children are the bare statement's, so
  the kinds alone make the shapes unify; `if` / `switch` are left out, their statement branches are `ExprStmt`-wrapped
  and their value branches are not. A statement owns its `;` and a value does not, so `Rewrite` now fits each expansion
  to its own site's terminator when the matches of one rewrite END differently (`Matcher.Match.node` + `trailer` /
  `alignTrailer`); matches that end alike are spliced exactly as before. Haxe 4.3.7: `final t:Int = foo(1);;` is
  `Expected }`, so the double terminator the unaligned splice produced does not compile — branch `feat/infra-N5`
- `patch` looks for a fragment the addressed declaration does not hold in that declaration's OWN leading doc block too
  (`ElementSpan.docExtendedSpan(…, docOnly = true)`), and only then: a fragment found in the declaration is matched
  there alone, so every payload that applied before applies identically and none turns ambiguous. The doc-orphan
  refusal told the caller to widen an insert-ahead fragment over the doc, which the refused address could not do (the
  doc is trivia outside the node), so the advice needed a second, wider address; a type's doc needed
  `comment-rewrite`. The insert-ahead itself stays a REFUSAL rather than being relocated above the doc: six
  `PatchSliceTest` cases pin that design, and the remedy now costs one widened fragment on the same address. The
  guard also reads a declaration's name through its nameless folding wrapper (`Patch.declName` →
  `RefactorSupport.typeDeclOf`): `final class C` is `FinalDecl(ClassForm C)`, the wrapper carried no name, every
  watch on such a class was dropped, and a `typedef` inserted ahead of a documented `final class` took its doc at rc 0
  — branch `feat/infra-N5`
- `replace-node --select 'ClassDecl:<Name>'` (reported unreliable by the consolidation agents, and so documented in
  the hxq skill: a mangled leading doc, a `final` left behind) does NOT reproduce on main `fa06ac46a`: an identity
  replace of every module-level type declaration with the text `source --select` prints, and again with its doc,
  comes back byte-identical over the client corpus `1d1ba147` (1114 types) and anyparse `src` (2199), and a CLI sample of 27 client
  files is identical too; the `final` half was fixed by the final-wrapper fold (`bf7c68763`). Pinned by
  `ReplaceNodeSliceTest#testWholeFinalClassReplaceKeepsItsDocAndNeighbour`; nothing to fix — branch `feat/infra-N5`
- `extract-method --member` extracts into a new PRIVATE member placed after the one holding the run, for a caller
  that must not leave the work inside the function (C1: a closure's branches count toward its enclosing function).
  Its parameters are the function's locals the run reads, typed by what their DECLARATIONS write
  minus the parameters whose written type is not the type their body reads (`TypeResolver.paramTypeSourceUnsafe`,
  the test `identDeclaredTypeSource` already applied, now public so both ask one place), never by inference; the return value is the closure mode's, typed the same way. Positive
  whitelist, because a parameter is a copy and nothing here type-checks: a local the function assigns ANYWHERE is
  refused (a write through a closure the run calls would miss the copy — the shape `--member` would otherwise
  silently change), and so is a local whose written type is not its read type (`?o:T` reads `Null<T>`, rest reads
  `haxe.Rest<T>`) or has none; a constructor, a host with type parameters (not projected, so read off the header: the
  name must be followed by `(`), a `macro` / `extern` host and a taken member name are refused too. Checked by
  compiling the result: `run`/`twice` before and after the extraction print the same values under Haxe 4.3.7
  `--interp` — branch `feat/infra-N5`
- a named function expression was to keep `HxFnDecl` and have its body's optional `;` gated by context → the `;`
  after `final g = function named() return 1` is the STATEMENT's for the compiler (Haxe 4.3.7 `--interp` runs it
  with a comment or an assignment around it), and no shape gate can tell an expression-position body from a member's;
  `NamedFnExpr` now carries `HxNamedFnExpr` — `HxFnDecl`'s signature, formatting knobs included, over the
  expression-position `HxFnExprBody`, which owns no terminator. Rejected the other fix, an absent optional literal
  rewinding the trivia it skipped: it would narrow every `@:trailOpt` node's span at once to cure one grammar error
  — branch `feat/infra-N8`
- a do-while is an expression in Haxe (4.3.7 `--interp`: a lambda body, an anonymous function body, an `if` branch,
  a paren operand) → `HxExpr.DoWhileExpr` over the statement's own `HxDoWhileStmt`, read wherever `DoWhileStmt` is
  (`doWhileLoopKinds`, `conditionLastChildKinds`, `branchKinds`, the execution model's kinds, the fixed-slot,
  case-glue and tail-seal tables). `@:meta do … while (c);` now projects as `ExprStmt(MetaExpr(DoWhileExpr))` like
  `@:meta while`, not `MetaStmt(DoWhileStmt)`, and keeps its layout; `MetaStmt`'s kind witness moved to
  `@:meta if (a) b(); c();`. `prefer-lambda-expression-body` still leaves `do … while` out: its terminator strip
  walks the LAST child, which is a do-while's condition — branch `feat/infra-N8`
- the conditional-arm redeclaration gate read ONE name per statement (`topLevelDeclaredName`) → a statement declares
  every continuation declarator (`var a = 1, v = 2`) and every named function literal outside a nested function
  (`final h = function v() …`; the compiler binds `v` in the enclosing scope), and renaming either past an arm that
  declares the name too broke every build that compiles the arm out (`--interp`: `Unknown identifier : v`).
  `BinderScan.statementDeclaredNames` answers all of them and replaces the single-name function; it over-counts a
  name nested in a block or a branch of the statement (a ternary branch scopes a named literal), which only refuses
  — branch `feat/infra-N8`
- `ImplicitSites.landings` asked `returnStatementKind` → an expression-bodied `function f():String return d;` is a
  `ReturnExpr` and landed nowhere; every `return` carrying a value is `valueReturnKinds` — branch `feat/infra-N8`
- `redundant-lambda-wrapper`'s own `binderKindsOf` and `prefer-range-loop`'s copy of the closure-capture walk are
  deleted. The binders are `BinderScan.binderKinds` less the local functions, which this rule reads as CALLEES
  (`localFns`); the one kind that adds, the named function literal, is a real shadow — read past, the member's
  signature answered for it and `foreach(ok)` was proposed for a `(v:Int, ?w:Int) -> Bool` literal Haxe 4.3.7
  rejects. `LoopScan.capturedByClosure` takes the two kind sets it reads instead of a whole `LoopSeams`, so
  `prefer-range-loop`'s bundle passes as it is — branch `feat/infra-N8`
- the PLAIN writer wrote `do i++; while (c)` for a do-while with an expression body, statement and expression form
  alike, which Haxe 4.3.7 rejects (`Expected while`; the trivia writer reproduced the source). `HxDoWhileBody.ExprBody`'s
  `@:trailOpt(';')` is parse leniency for the legacy spelling only, so it carries `@:fmt(trailOptParseOnly)`: the plain
  Case-3 writer emits nothing for it, the trivia writer still writes what the source wrote — branch `feat/infra-N9`
- `x = function n() { return 1; } trace(x());` and the `var` form did not parse, though Haxe 4.3.7 runs both:
  `endsWithCloseBrace` and `_stmtExprNoSemiAt` had the anonymous `FnExpr` arm and no `NamedFnExpr` one. Both now read a
  named literal's BLOCK body as `}`-terminated; its EXPRESSION body answers the body's own verdict at every depth,
  without the anonymous arm's byte-parity `nested ||` relaxation (`x = function n() return 1 trace(x());` is `Missing ;`).
  The plain writer therefore drops the optional `;` after `var g = function n() { … }` exactly as it does after the
  anonymous spelling — branch `feat/infra-N9`
- `branchKinds` (cyclomatic decision points; `prefer-local-function`'s conditional-evaluation stop;
  `join-single-use-local`'s field-chain refusal) lacked `WhileExpr` while `ForExpr` was in it, so a `while` comprehension
  or lambda body counted nothing and a binding under one was hoisted. Added; `ShapeVocabTest` now pins every
  `ShapeVocab.loopKinds` / `conditionalKinds` member into the list. `join-single-use-local` cannot change: its loop
  barrier (`ShapeVocab.loopKinds`) already refused a read under `WhileExpr` — branch `feat/infra-N9`
- a value metavariable bound a constructor's TYPE arguments: the projection lists `new Map<String, Int>()`'s
  `(Named String) (Named Int)` as children beside the value arguments, and the matcher unified one flat list, so
  `new $C($b, $a)` silently rewrote it to `new Map(Int, String)`. The grammar tags the field (`HxNewExpr.params`
  `@:queryTypeArgs`), the walker records how many children lead (`QueryNode.typeArgCount`), and the matcher unifies
  the two runs apart, one star allowed per run (`new $T<...>(...)` is now a valid pattern). Children are unchanged —
  `uses` keeps reading those `Named` nodes, and `NominalTypes.writtenConstruction` reads the count instead of
  re-deriving the split from the separators between the children (its scan deleted). A pattern that writes no type
  arguments constrains none, as the type slot does, so `new $T(...)` still counts every construction; `apq rewrite`
  refuses such a match on a construction that writes some (`Match.unwritten`): no metavariable holds them, so the
  splice would drop them — branch `feat/infra-N9`
- a module-level value inside `#if` hid the imported static of its name in EVERY build and was never typed → it is
  what a bare name means only in the builds compiling it (Haxe 4.3.7 `--interp`: `#if never final lock:Int #end` +
  `import A.*` prints `A.lock`; two module-level fields of one name in one build: `Duplicate module field
  declaration`). `ValueNameBinding.moduleValuesAt(fi, name, at)` answers it from the `#if` branches
  (`TypeNameBinding.branchPathAt`, `CondBranchPath.within` / `comparable`, as guarded imports are read): the one
  declaration every build compiling the use compiles, else each one some such build may compile plus what the imports
  supply in the builds compiling none. Coverage (`#if a … #else … #end` declaring the name in both branches) is not
  read, so the imports stay a candidate there — a build that may not exist, never a missed one. `importedStatics`
  takes the use's offset (no offset: only an unguarded declaration hides the import); `FileInfo.moduleFields` carries
  each declaration's span. In the call graph a member of the enclosing type's chain comes first (4.3.7: an inherited
  instance member beats a module-level field; a supertype's static is not in scope bare — `CallGraphKeys.memberMayBind`,
  extracted from `importedStatic`), then the module-level value — now typed by its annotation — and a call on a value
  only some builds declare dispatches on each build's type; one untyped build, or imports that may bind more than one
  static, leave the receiver unresolved. Refs is unchanged: it binds a module-level value to nothing (-1), the lexical
  answer `rename` and the unused checks read — branch `feat/infra-N7`
- the two `stripAnsi` copies disagreed: `LintFixSafePass` removed every CSI sequence, `TestTranscript` only an SGR
  colour code (`ESC[<digits;>m`) → one `SourceText.stripAnsi`, the CSI-wide reading. A transcript row behind an
  erase-line (`ESC[2K`, what a progress printer redraws with) kept its escape, failed the indent-anchored row
  regexes and was not counted (`ApqDxTier3CliTest#testTestSummaryReadsRowsBehindAnEraseLine`, RED on `b5a5bccac`)
  — branch `feat/infra-N6`
- the arguments a subtype's `extends` / `implements` chain passes to a supertype's parameters had one reading, the
  call graph's (`CallGraphGenerics`), which `ReflectiveReach.bindingsOf` borrowed though every other question it
  asks there goes to the index → the walk is `SubtypeGraph.chainArguments` over any keying of the written
  supertypes; the index answers it by simple name (`SubtypeGraph.argumentsPassed`, every declaration of a name
  folding in index order, as `supertypeNameUnion`) and the graph over its own tables, which read each argument
  through the writing file's imports (`keyIn`). Simple-name keying is kept, not narrowed to one declaration: the
  owner is already required to be ONE declaration (`onlyDeclaration`), and the subtypes come from the index's own
  simple-name closure — branch `feat/infra-N6`
- `NullableSource.receiverTypeName` asked a receiver's type in two steps — the identifier's own annotation
  (`TypeResolver.identTypeName`), then the shared typer as a fallback — and `nullable-switch-missing-null` passed no
  typer at all → the receiver is typed by the shared typer alone (`CheckScan.typeNominalResolver`, receiver mode,
  which reads the same annotation for an identifier and peels a member-transparent wrapper itself), every caller
  hands one, and `describe` lost its `declaredTypes` parameter. Byte-identical on the three client trees and anyparse;
  the switch rule now seeds a local bound from a field-path map read (`final u:Colour = b.cache[k]; switch u`),
  which it missed (`NullableSwitchMissingNullCheckTest#testDeclaredLocalFromAMapReadFlagged`, RED on `b5a5bccac`)
  — branch `feat/infra-N6`
- `RedundantToString.resolveReceiver` bound a construction's type itself (`OperandBinder.writtenTier` on the
  written name) beside the identifier it asked the shared binder for → `OperandBinder.tierOf` types a construction
  `new T(…)` as the type it writes, bound where written, so every consumer of the binder sees it: the operator gate
  now proves `new Tag() + 'a' + 'b'` built-in concatenation for a plain class and still refuses it for an unindexed
  import (`OperandBindingTest#testConstructionIsOfTheTypeItWrites`, RED on `b5a5bccac`). The literal arm stays in
  the rule: no consumer of the binder tells a literal's `Free` from `Unknown` (`OperatorSelection` decides a literal
  before it asks), so a binder arm for it would be unkillable. The non-null half is already the shared provers'
  (`TypeResolver.isProvablyNonNull`, `DeclaredNullity.ofMemberReturn`); the curated static-return table
  (`staticMethodReturns`) stays the rule's, read where the binder's static access has no declaration — branch
  `feat/infra-N6`
- `CallGraphImports` kept four tables of its own, filled file by file as the graph merged an index — the files
  declaring each member of a type name, the types each declaration writes for it, the enum constructors by name, the
  paths each type name is declared under → each is a question to the indexes the graph took its files from
  (`recordIndex`): `MemberLookup.memberDeclarationsOf` (now with each declaration's file, one shared
  `MemberDeclaration` typedef replacing three anonymous spellings and `SwitchChain.MemberDecl`),
  `MemberLookup.declaresMemberAs`, `TypeNameBinding.namingPaths` (a main type's package path is its module path, so it
  is listed once); only the paths keep a memo, cleared when an index is taken. A graph merges an index only over files
  it does not hold, so asking the whole index answers what the per-file tables held — byte-identical on the three client
  trees and anyparse — branch `feat/infra-N6`
- the last two readers of a construction's children as its arguments read `QueryNode.typeArgCount` now. `ImplicitSites.
  landings` landed EVERY child of a `new` as a value, so `new Box<Int>(d)` put a landing of no known type at `Int` — a
  string conversion of any object at every construction that writes type arguments. `CallGraph` (`handleNew`'s
  argument scan, `argumentSlot`, the expected type of a constructor argument) skips them too; there it was a pure
  move (a `Named` child is neither a lambda, a call nor a value read), and the expected-type slice no longer re-derives
  the count through `NominalTypes.writtenConstruction` — branch `feat/infra-N10`
- `apq rewrite 'final $x = $v' 'var $x = $v'` over `final f:Float = 1` wrote `var f = 1` — re-parseable, and an `Int`
  where there was a `Float`: a pattern with no type slot constrains none (kept — `search` still finds an annotated
  declaration with the plain spelling), and nothing recorded that the input HAD one. `Matcher.unifyType` records the
  input's type in `Match.unwritten` as it records unwritten type arguments, now an enum (`TypeArguments` /
  `TypeAnnotation`), and `rewrite` refuses the match naming the type and the spelling that carries it
  (`final $x:$T = $v`). Refusal rather than carry: the template is text, and which slot of it would take the type is
  not something the op can know — branch `feat/infra-N10`
- a moved declaration that names a SUB-module type of its own source module (`typedef Pair` beside `class Src`) was
  refused by `move` and `move-member` alike ("no import to carry"), and `testAStaticReceiverOnASiblingSubTypeIsRefused`
  documented the false premise that no statement can name such a type from another file. `import <module>.<Sub>;` does
  (compile-proved on 4.3.7, including a source module left with no main type after the move), so
  `DependencyCarry.ownSubModuleImport` carries it when the source binds the name through its module-own rung and holds
  no statement of its own; the collision gate then prices it as a carried statement. A `private` sub-type, which no
  spelling imports, still refuses, and the module's MAIN type is not covered (the package rung reaches it in the same
  package) — branch `feat/infra-N10`
- `move-member` refused a move whose bodies read a MUTABLE field ("shared mutable state cannot be mirrored") even when
  nothing but the moved members touched it, though listing the field by hand moved it fine. `MoveMemberFields.
  ownedFieldClosure` takes along, to a fixed point, every instance data field the moved members alone own — every bare
  reference `Refs` binds to it inside a moved member, no field access of its name outside them in any scope file, a
  plain field (a `var` with no accessor clause, a `final` with an initializer), not `#if`-guarded, no destination member
  of that name. Anything else stays, and the refusal now names the staying members that keep it (fail-closed as
  before; listing the field explicitly still routes those readers through the via field) — branch `feat/infra-N10`
- receiver-qualified callers of a moved INSTANCE member (`_g.x()` in another class) were left unrewritten by contract
  ("they fail the next compile loudly"), so a split into a nested object (`_g.x()` -> `_g.library.x()`, C2's
  `LibraryCalls`) ended in 24 hand edits. `MoveMemberReceivers` classifies every access named like a moved instance
  member by its receiver's type, through the checks' own typing door (`CheckScan.typeNominalResolver` over the move's
  scope index): the source type (declared once in scope) or a subtype routes through the via field; an in-scope type
  `SubtypeGraph.provablyNotSubtype` clears, or a std type declaring a member of that name (`StdTypes.memberOf`), is left
  alone; a type-namespace receiver is a static access; anything else — untyped, `Dynamic`, a type parameter, `super`, a
  null-safe access — REFUSES the move (positive whitelist), which turns some former successes that wrote a broken tree
  into refusals. A caller outside the source type needs the via field public. Known limit: a forwarding abstract over
  the source (`@:forward abstract A(Src)`) is read as unrelated — the result then fails to compile, loudly — branch
  `feat/infra-N10`
- `move-member --keep-bare` (opt-in, default unchanged) keeps the source's bare callers of moved statics bare through
  one `import <destModule>.*;` (C2 wrote it by hand for `TypedFactsTypeStrings`). The wildcard binds a name only
  after the file's own resolution fails — a local, a class or supertype static, a module-level value, an explicit field
  import each win (compile-probed on 4.3.7) — so the op proves it whole: destination is its module's main class in
  another module, the source's supertype chain resolves and declares none of the wildcard's names
  (`DependencyCarry.wildcardBoundNames`, the carry's own model of what such a wildcard binds), the source imports and
  declares none of them, and no identifier of the source spells one anywhere but at the kept callers; otherwise a
  refusal naming the reason. Opt-in because a default change would rewrite every pinned move-member result — branch
  `feat/infra-N10`
- two or more moved members needing private access to the source each got their own `@:access(<pkg>.<Src>)` line;
  they now share one on the destination TYPE, placed where `add-meta` places an entry (`AddMeta.entryEdit`, the
  placement `addMeta` itself now goes through). One member keeps the member-level line (the user's rule: method-level
  when only it needs the grant) — branch `feat/infra-N10`
- the N10 additions put `MoveMember` over the member limit (55 > 50); the owned-field closure and the receiver
  classification moved out to `MoveMemberFields` / `MoveMemberReceivers`, with `move-member` itself (`--keep-bare`, the
  class-level `@:access`, the sub-type import of `ReceiverHit`'s `move`). Two helpers moved to their shared homes for
  reuse rather than copied: `PreferReadOnlyField.isProperty` -> `SourceText.isProperty` and
  `DependencyCarry.memberAccessKinds` -> `ShapeVocab.memberAccessKinds` — branch `feat/infra-N10`
- `ImportBindings.readModuleFields` was a second reader of a module's module-level fields — it re-parsed the file's
  retained source and kept every named top-level declaration that was not a type or an import statement → it reads the
  index's `FileInfo.moduleFields` (each name once), the reading `ValueNameBinding` already used. The kinds agree
  (`RefShape.moduleValueDeclKinds` is every value binder the grammar spells), and every indexed file's source is
  retained, so the null "unparseable" set it could answer never arose for an indexed module: byte-identical on the three
  client trees, anyparse and the review fixtures — branch `feat/infra-N11`
- `CondBranchPath.comparable` read two positions as alternatives only when ONE region held both in different branches,
  so a use in `#if a … #else USE #end` could bind a module-level declaration in an earlier `#if a DECL #end` that no
  build compiling the use has → two branches of two regions are alternatives too when the earlier branch `j` spells, as
  its own condition, the `j`-th condition of the later one's chain (the earlier needs it, the later its negation; Haxe
  4.3.7 `v-N11-hx/p2`: `#if foo final w … #end` then `#if foo … #elseif bar USE #else USE #end` reads the imported `w` in
  both `USE`s). Read only where each chain splits back into exactly its branch's conditions — a condition spelling `|`
  (`a || b`) is never split — and an empty condition proves nothing; logical equivalence (`#if !a` against `#else`) is
  still not read (`ValueNameBindingTest#testAnotherRegionOfTheSameConditionIsAnAlternative`, RED on `d0f12ab9e`) —
  branch `feat/infra-N11`
- A module-level FUNCTION the module declares in several `#if` branches was ONE call-graph node (`Mod.f`, keyed by name,
  every body's edges folded in), and a bare call of it was bound by name only — from a class through the module
  pseudo-type, from module-level code not at all (`UnboundName`: `Refs` binds no module-level declaration) → each further
  body in the file is a node of its own (`Mod.f@2`, `Mod.f@3`, … in source order, `CallGraph.bodiesOf`), and a bare call or
  read binds per build the way a module-level value does (`ValueNameBinding.moduleValuesAt`): the body of each declaration
  some build compiling the use declares, plus the imported static in the builds declaring none, after a local, a
  parameter and a member of the enclosing chain (`CallGraphKeys.memberMayBind`) — Haxe 4.3.7 `v-N11-hx/p1` (`#if a` /
  `#elseif b` bodies: module-level caller, class caller, value read all run the build's body; the module's function beats
  `import B.*`; a class's own static beats the module's). Fail-closed by construction: every edge that names the function
  rather than a body — an import, a qualified access, a compiler fact, an earlier file's placeholder — reaches each body
  (`CallGraph.addEdge`), and so does a query (`resolveTarget`); a call or read that binds several bodies types nothing by
  them (`identTarget`, a call site's target). A build whose declaration is a module-level VALUE now records the call as a
  `FunctionValue`, not `UnboundName`: it runs the function the value holds, which is what `FunctionValue` means. A
  declaration of the module in another file (another class path) still folds into its node. Not done: a member declared in
  several branches of its class stays one folded node (`CallGraphBindingTest#testEachBodyOfAModuleLevelFunctionUnderIfIsANodeOfItsOwn`,
  RED on `d0f12ab9e`) — branch `feat/infra-N11`
- a receiver-qualified caller of a moved instance member was LEFT alone whenever `SubtypeGraph.provablyNotSubtype`
  cleared its receiver's type, and that proof's root refusal was a NEGATIVE list (`typedef` alias, plain `abstract`):
  a `@:forward enum abstract A(G)` read as unrelated to `G`, and so did a structure declaring `isPure`, which a `G`
  value unifies with — both moves wrote a tree 4.3.7 rejects (`p.A has no field isPure`, `p.G should be p.S`). Two
  positive lists now: the proof starts only from a kind whose supertype list is complete (`COMPLETE_SUPERTYPE_KINDS`:
  class, abstract class, interface, enum, or an anonymous structure), which also corrects `naming`'s receiver
  attribution for a forwarding enum abstract; and `MoveMemberReceivers` leaves a receiver alone only when it names ONE
  class or interface of the scope (`classOrInterface`) — a structure's provable non-subtyping says nothing about the
  `G` it may hold. Everything else refuses — branch `feat/infra-N12`
- `move-member` moved an instance member of the source's inheritance family: an `override` (the destination declared
  an override of nothing), the implementation of an interface method (the source no longer implemented it), a member
  a subclass overrides. `MoveMember.inheritanceRefusal` refuses all three, and — positive — a member an `implements`
  target or super-interface outside the scope may declare. An unresolved SUPERCLASS is not refused: a plain class
  ancestor's member could only be redeclared with `override`, which the modifier check sees; the residual is an
  `abstract class` outside the scope whose `abstract` method the member implements without the keyword (the same
  residual `CrossRenameMember` carries) — branch `feat/infra-N12`
- `--scaffold` appended `<via> = new Dest(...)` at the END of the source constructor. Under `@:nullSafety(Strict)` a
  constructor may use a method only once every field is initialized, so the C2 `FactsEscapes` -> `FactsInstances`
  replay no longer compiled ("Cannot use method escape until all instance fields are initialized"), and without null
  safety a method the constructor calls met a null via field. `MoveScaffold.viaWiringOffset` places it right after the
  last top-level statement writing one of the fields the destination is built from (and after a `super(...)` call):
  a constructor that compiles under Strict has written every field before its first method use, so that point
  precedes it. The replay now typechecks the whole engine (`haxe bin/apq-js.hxml --no-output`) — branch
  `feat/infra-N12`
- a move's carried statements landed in the order the moved members met them (`MoveMember` carries per member): with
  no ordered seat in the destination that put `using` lines between imports, and a destination with only `using` lines
  got the imports BELOW its run (`ImportOrder.lastHeaderEnd` answers the last statement of any kind there).
  `MoveSymbol.canonicalCarry` writes every import sorted (ascii), a blank line, then the `using` lines, then guarded
  regions; `importLessSeat` gives an import-less destination's `using` seat the imports too, ahead of the `using`
  lines; and `MoveMember` orders the union of the members' `using` lines by the source's own declaration order — that
  order decides which extension wins a method name. A `using` whose extension methods are KNOWN (the std probe, or a
  module the scope declares) and that the moved code calls none of is no longer carried: the same test `unused-import`
  deletes one by, now ONE function (`OccurrenceScan.usingExtensionCalled`) both call. Fixture consequence: four
  `MoveSymbolSliceTest` fixtures modelled `using q.Ext;` supplying `s.go()` with an EMPTY `class Ext {}` (no such
  extension exists); `Ext` now declares `go` — branch `feat/infra-N12`
- the name terminals took any identifier-shaped word: `final dynamic = 1;`, `var default:Int;`, `function f(macro:Int)`,
  `catch (null:Dynamic)` and 39 more reserved words parsed, so an op writing such a name passed its own re-parse gate
  with a tree Haxe rejects (each of the 45 words of the 4.3 keyword table refused as a local's name, verified on 4.3.7). `operator` (reserved since 4.0) and `overload` (4.2) are NOT refused: every branch of a `#if` region is parsed, and code gated on an older compiler declares them — lime's `Cairo` has `public var operator(get, set)` under `#if (haxe_ver < "4.0.0")`; refusing it made that module skip-parse and, through the library index, dropped 6 `prefer-api-idiom` findings on `client-bd943dac` (found by the all-rules gate).
  `HxIdentLit` (every declaration name: parameter, binder, type, enum constructor, structure field, type parameter),
  `HxVarNameLit` and `HxFnNameLit` (minus `new`, the constructor) now refuse all of them; the slots that DO take a
  keyword moved to `HxWordLit` (a property accessor `(default, null)` / `dynamic`, an interpolated `'$this'`, a `$name`
  reification). `HxExprIdentLit` additionally refuses the declaration words no expression is (`class`, `dynamic`,
  `static`, `using`, …) — `abstract` stays, it is the abstract's own value in `switch abstract { … }`. Not refused: an
  arrow over a check-type expression, `(null:Int) -> 1`, which reaches the general `ThinArrow` fallback rather than a
  name slot; `super`, which Haxe does not reserve. Refused although Haxe takes it: `this` as a `for` variable or a lambda parameter (`for (this in a)`, `(this) -> 1`: Haxe reads those heads as expressions, where `this` is an identifier), and `new` as the name of a function inside a `#if` name splice (`HxConditionalFnName`) — none is code an op writes or a project holds (both corpora parse unchanged), and a refusal is the loud direction. Writer and formatter are untouched: `fmt --write` over the client corpus src (876
  files) and anyparse src (1140) is byte-identical. Fixture consequence: a `CallGraphTest` fixture named a function
  `untyped` — branch `feat/infra-N12`
- `CallGraph` splits along its one internal seam: the per-file edge collection — `collectEdges` with its 69 closures and
  every local that lives for one file's walk (the frames, the resolved call sites, the types the walk gave values) — is
  `CallGraphEdges.collect(g, entry)`, the shape `CallGraphNodes.collect` already had, and `CallGraph` keeps the node
  table and the public surface its 86 readers use (2144 -> ~600 lines; 67 members, still over 50 — they are the table's
  fields and its query surface, which no reader may lose). The closures stay closures: they are the walk's own scope, and
  turning them into members of a per-file object would add ~60 fields of shape vocabulary for no reader. `ParsedEntry`
  is the one public typedef both collectors read (`CallGraphNodes`' private `Entry` copy is gone) — branch
  `feat/infra-N13`
- MEASURED, NOT IMPLEMENTED: a class member declared in several `#if` branches stays one folded node. Same-name methods
  of one type under exclusive branches: client `1d1ba147` / `f81c2049` / `bd943dac` / src `f979b1db` 4 each, all one name —
  `getFolderListingAPI` under `#if FEATURE_SHARE_EXTRA` / `#else` (the abstract twins in `RemoteDiskSystemBase`, the
  bodies in `ModelsRemoteDiskSystem`, `ProjectsRemoteDiskSystem`, the test's `TestRemoteDiskSystem`); anyparse 1
  (`CompilerDisplayOracle.new`, `#if nodejs`); no overloads, every pair sibling branches of one region. A node per body
  bound per build (N11's module-level shape) separates NOTHING there: the base's callers at 176/216/1013 are unguarded
  (they run in both builds: every body), the two guarded ones (1397, 1409) bind to the abstract twins, which run nothing
  and dispatch to subclasses in other files (no per-build answer across files: every body), and the one
  `new CompilerDisplayOracle` sits in the same file whose two constructor bodies make the same call. What it would cost:
  every reader that names a member by name gets the first body only — `ownMember` (10 sites), `memberOnChain` (11) and
  `virtualTargets` (10) in `CallGraphFacts`, `CallGraphKeys`, `MemberReach`, `ReachGraph`, `ConstructorWiring`,
  `FactsView`, `LockAliases`, `LockSites`, `ObjectPaths`, `LibraryBodies`, `ThreadSafety` — and each of those 31 that
  reads the body or walks on from it would have to expand through `bodiesOf` to stay fail-closed; only the ones feeding
  `addEdge` expand already. The module-level case has no such reader. The fold unions
  the bodies' edges, which is sound; it is left until a tree measures a call site a split would bind — branch
  `feat/infra-N13`
- an `oversized-type` grant (`"Name: reason"`) silenced its type at ANY size, so a granted type could grow without
  bound and nothing said so. A grant now carries a CEILING, `"<Name> <= <N> members / <M> lines: <reason>"` (either
  clause alone, members first when both are given; digits capped at nine, a type name an ASCII identifier), which
  REPLACES the threshold for that type and that dimension: silent within it, reported again past it with the grant
  named (`… (max 71) — beyond its grant 'Renderer <= 71 members / 4150 lines'`), the current size masked out of the
  finding key and the ceiling kept in it (a raised ceiling is a configuration change the blast-radius gate must
  show). A dimension the grant gives no ceiling keeps the threshold. The ceiling-less legacy shape is REFUSED, not
  read as an unbounded grant and not given a default margin: accepting it would keep exactly the silence the change
  exists to end, and a refusal costs one config edit whose numbers the type's own returning finding supplies. Every
  other unreadable entry — no reason, a ceiling at or below the threshold (it grants nothing, and reading it as a
  TIGHTER limit would report a type no other type its size is reported for), any other head, two grants for one type
  (two ceilings, neither obviously meant) — is refused the same way: it grants nothing and is reported once per run as
  a file-less `Warning`, the shape `thread-safety` reports an option it could not read in. Migrated grants: ceilings
  = current size + 5% rounded up (lines to the next 50) — `Renderer`, `WrapList`, `NullFlow`, the test tree's
  `TestDiscoveryParityTest`, and the types C2 measured and declined (`FactsView`, `MemberReach`, `TypedFactsWalk`,
  `FunctionValueTypes`, `NullGuardedCode`, `CompilerFacts`, `ReachGraph`, `FactsEscapes`, `TypedFactsMacro`), each
  with C2's reason; and `CallGraph`, still 67 members after N13 moved its edge collection out (its public question
  surface, which 86 files read) — branch `feat/infra-N14`
- `member-order` gains an opt-in, SPACING-ONLY option `separateInlineSubgroup` (default OFF, user request 2026-10-17
  from the client corpus `ItemListItemTile`, where `--fix` deleted the blank between `private static inline final CATEGORY_TAG_BOTTOM`
  and `private static final SHARED_WITH_ME_ICON_TEXT`): an `inline` and a non-`inline` FIELD of one rank, both
  unconditional and neither comment-led, want exactly one blank line between them instead of none. One predicate
  (`MemberSpacing.inlineSubgroupBoundary`) answers for all four readers — the report (`spacingViolation` via
  `firstSpacingIssue`), the spacing-only fallback (`emitSpacingOnly`), and both rebuild joins (`separatorBetween` in
  `joinMembers` and `buildConditionalRegion`) — so report and fix read the gap the same way, and the option is resolved
  from the file being linted on BOTH paths (`run` per entry, `fix` off its violations' file). Scope choices: unconditional
  pairs only, because the inline-leads sub-order (`subRank`) is a key of plain members alone and inside an `#if` block
  inline and non-inline members interleave freely; fields only, because same-rank methods keep their separators untouched
  and the rebuild already blank-separates every method; a comment-led slot keeps its exemption (a blank before a doc is
  never demanded or stripped, the writer keeps one after it); the order is untouched, so the content-ranking gates stay
  option-independent and the `movableArglessNew` argument for them still holds (the report path reads no ORDER option).
  `fixWalk` / `emitReorder` now take the two options as one `FixOptions` record instead of a growing parameter list —
  branch `feat/infra-N16`
- a negated ternary (`!c ? a : b`) and a negated value `if` were left as written, and the four rules that BUILD a
  ternary out of a guard (`prefer-ternary-return`, `return-reassign-ternary`, `prefer-ternary-assignment`,
  `prefer-ternary-expression`) wrote one themselves (`if (!x) return null; return f();` became
  `return !x ? null : f();`, client `ThumbnailLoader`). One owner now, `NegatedCondition`: the condition's top-level node
  (outer parens unwrapped) is a built-in `!` (`OperatorSelection`, the gate `invert-negated-if-else` already had), the
  positive form is the operand with one redundant paren dropped, and a comment the rebuild would drop (between the
  `!` and the kept operand) refuses. `invert-negated-if-else` gained the value forms in place of a sibling rule: the
  swap is the same exact complement and the same three edits, so a second rule would have been a second copy of the
  gate. Decisions inside it: a branch that is the same construct bare (a ternary chain `!c ? a : d ? e : f`, an
  else-if) is skipped — the swap would re-nest the chain, not invert it; a comment the positive condition drops, or
  one in the glue between condition and branches (it stays put while the branches move and would describe the other
  one), leaves a value form REPORT-ONLY (the statement form keeps its old "unreported"), and the walk descends into a
  report-only node since nothing of it is rewritten; each of the three value splices is a `ParenGuard` hole, so the
  parse round-trip — not a precedence table — decides `!(a = b) ? x : y` -> `(a = b) ? y : x` against
  `!(a || b) ? x : y` -> `a || b ? y : x`. The statement form now refuses only a DROPPED comment: one inside the kept
  operand travels verbatim (`if (!(a /* k */ && b))` used to be skipped). The builders swap the two values and make
  both of them holes too; `prefer-ternary-return` keeps the negated form when the guard carries its own trailing
  comment (it rides the `?` value, and moved to the `:` slot a `//` glued before the `;` would swallow it).
  `OperatorSelection.of` takes the fix's report index (`?report`): a builder DECIDES the orientation in `fix`, where
  `files` is the one file being fixed, so an `@:op(!A)` declared in a sibling module would otherwise go unseen —
  branch `feat/infra-N18`
- `simplify-boolean-ternary` and `simplify-boolean-return-chain` wrote a flat `||` that strands a null-safety
  narrowing: `prefer-ternary-return` folded `if (a == null || b == null) return true; return mayUnify(a, b);` into
  `a == null || b == null ? true : mayUnify(a, b)` (a ternary narrows its branch from the whole condition), and the
  boolean reduction then wrote `a == null || b == null || mayUnify(a, b)`, which Haxe 4.3.7 rejects ("Cannot pass
  nullable value"): a fact reaches a later `||` operand from the chain's FIRST operand only, while an `&&` chain carries
  every fact (`a != null && b != null && b.length` compiles). Two `--fix` safe edits over anyparse were reverted for it
  (`CallRepetition.repeatedUnder`, `FunctionValueTypes.sameOrGeneric`). The engine already knew this —
  `negateAndChain` right-nests a group at a stranded null test — but the two reductions joined through the plain
  binary `joinOr`. Both now write every `||` result through `narrowingOr` over the chain's operands (`orLeaves`: `||`
  sides, De Morgan'd `&&` sides under negation, parens transparent, also inside the kept branch and across guard
  rungs): flat and byte-identical when nothing is stranded, `a == null || (b == null || mayUnify(a, b))` when a bare
  null test past the first operand narrows a later one, and REFUSED (null — no finding) when a null comparison buried
  in a compound operand does (`!(a != null && b != null) || b.length > 0` does not compile and no grouping fixes it;
  the positive whitelist: only the bare-test shape is known to carry a fact) — branch `feat/infra-N15`
- `unused-local` declined its two refusals (a side-effecting initializer, a binding sharing its line) with no
  `Violation.declineReason`, so `--fix` printed "returned no edit … will not say which it is" for the client's six remaining
  findings (all call initializers). Each gate now writes its sentence — branch `feat/infra-N15`
- `unused-private` judged a FIELD initializer by the kind-only `MemberKinds.isSideEffectFree` while `unused-local`
  judges a local's by the type-aware `TypeResolver.isDeletionPure` (a pure array / map literal, a plain field read, a
  provably pure stdlib call): two answers to one question, and the client's `bitmapDataCollection: Map<String, Any> = []` was
  declined as "not provably side-effect-free". The field gate now asks `isDeletionPure` when the fix has an index
  (the kind-only answer without one) — branch `feat/infra-N15`
- `default-repeated-argument` changed what a call means: it took "a site passing something else keeps its explicit
  argument" for meaning-preserving, but Haxe hands a parameter its default for an explicit `null` too (`f(null)` with
  `x:Null<Int> = 7` answers 7 on 4.3.7, `--interp` and js). the client's `MirrorSyncLoopTest.seedGhost(cloudId:Null<Int>)`
  got `= GHOST_ID` from three agreeing sites, so the fourth, `seedGhost(null)`, silently became
  `seedGhost(GHOST_ID)` and the test it drove failed; it compiles, so the oracle cannot catch this class. Now EVERY
  call of the name (resolved or not) is read: an argument at the parameter's position that is not proven non-null
  refuses the finding. Proven = a POSITIVE list (`provenNonNull`): a non-null literal (also negated), `new`, an array /
  object literal, a function value, a comparison or boolean operator, a reference to an `inline` constant whose value
  is no `null` literal (such a constant is no default candidate either). A variable or a call is not proven — no
  types read, since a non-`Null<T>` declaration proves nothing without null safety — branch `feat/infra-N15`
- `naming` gains a PRIVATIZE arm for a public `_x` field nothing outside its type reads (user request 2026-10-17 from
  client `Slider.hx`, where `--fix` renamed `public final _labelTextField` of `private final class FloatingReadOut` to
  `labelTextField`; no reference outside the class). The rename came from `naming`'s public-field rule (its
  `crossFileFix`), NOT `no-underscore-prefix`, which flags parameters and locals only — so the arm lives in `naming`
  (`NamingPrivatize`) and `no-underscore-prefix` is unchanged. Decisions: (1) ONE finding, two arms: the privatize arm's
  finding carries the arm in its message (`… — nothing outside FloatingReadOut reads it, so the fix makes it private`),
  the rename arm keeps today's message byte-for-byte; `crossFileFix` declines the privatize finding with
  `RenameRefusal.PRIVATIZE_ARM`. (2) A positive candidate list: a FIELD, `public`, `_`-prefixed, with an owner, no
  `implicitReach`, not rename-unsafe, and the rule that would govern it once PRIVATE accepts the name — so the arm is
  the policy's, not a hard-coded `_`. (3) The verdict is `unused-public-member`'s reachability set, MOVED into
  `PublicReach` (token map, confirm, type gates, chain walk, member-run reading — UPM's copies deleted) and asked by
  both rules, with the allowed regions widened from the member's own declaration to the type's declaration plus every
  subtype's (`SubtypeGraph.subtypeDecls`, `RawSourceScan.nameOccursOutsideAll`): Haxe `private` is visible to a
  subclass. No supertype / interface / structure gate of its own, for UPM's reason — each of them spells the name, so
  the token count already refuses. (4) An `@:autoBuild` ANCESTOR does not refuse the arm (`chainOutOfReach(…,
  autoBuildCounts: false)`), while it still vetoes UPM's deletion: generated code may CALL a member, but it lands inside
  the descendant, where a private field stays visible — and openfl's `Sprite` carries `@:autoBuild`, so the veto would
  refuse every client UI class, the motivating one included. The residual (a macro that reads VISIBILITY and changes what
  it generates) is invisible to every source scan and is part of why the arm is risky. The type's OWN `@:build` still
  refuses. (5) RISKY per arm, not per rule: a new `Check.RiskyArm` capability (`riskyArmFindings` + `riskyFix`) keeps
  `naming` in the safe loop and adds it to the verified set only when an oracle is configured (`partitionChecks`), where
  `FixVerifier` asks the arm's findings of `riskyFix`; marking all of `naming` `RiskyFix` would have made every rename
  report-only without an oracle. Without an oracle the privatize finding is report-only and NOT renamed — the arm owns
  it. (6) Whole-project evidence is a precondition, not a hope (the lint-fix-scope incident: a narrowed report scope
  read a reference in an unlinted file as absent): the arm runs only when `RefactorSupport.projectIsComplete` (declared
  `resolutionRoots`, every one matched), where the token map spans the project however narrow the lint scope; without
  it the arm is off and the finding keeps the rename. client: `_labelTextField` (client-fix-before) is privatized and verified by
  all 13 oracle configurations; `_scrollContainer` (`ProjectPDFPreview`) is refused by the token count — three other
  classes declare a private `_scrollContainer` — and keeps the (already refused) rename. Known gap, stated rather than
  closed: the token count is NAME-keyed, so a common private-field name anywhere in the project refuses the arm; a
  resolution-based occurrence attribution (the rename's own `otherFileRenameSpans`) would lift that — branch
  `feat/infra-N19`
- `member-order` asks the WRITER's member-gap policy before its own (user request 2026-10-17, N21; found by N16): in the client corpus
  44 findings `members of one rank group are separated by a blank line` sat next to a field the writer renders over
  several lines under `emptyLines.aroundMultilineFields: 1`, so `--fix` emitted the edit, the canonical round-trip put
  the blank back, and the finding returned for ever; and a doc-commented field glued between two plain ones was exempt
  although `fmt` always sets it off. The writer is right in both — it is what the project's `hxformat.json` asks for —
  so its policy became ONE set of runtime predicates both sides call, `anyparse.format.MemberGap`: `docLed` (the
  `/**` leading-comment scan, previously four inline copies in `TriviaBlockLowering` / `TriviaSepLowering`),
  `docStrips` / `docVetoes` / `docAdds` (the `afterFieldsWithDocComments` / `beforeDocCommentEmptyLines` gates, the
  before-policy's `none` winning as the gap's last write) and `multiline` (the `_bamMulti` Doc measure of
  `blankAroundMultilineMembers`); `docGap` / `forcedBlanks` compose them in the writer's order for a reader that asks
  about a whole gap (the multi-line rule tops an EMPTY gap up after the doc rule, so it lifts a forced zero; a gap that
  already holds the doc blank keeps one). The check reaches them through `GrammarPlugin.memberGapPolicy(optsJson)` (the
  file's own `hxformat.json`, discovered as `fmt` discovers it; memoised per config by `CachingGrammarPlugin`); the
  Haxe plugin measures a slot by writing it through `HaxeModuleTriviaWriter.writeHxMemberDeclT`, the element the
  writer measures, with a per-slot memo. `MemberSpacing.wantedBlanks` is the one per-pair predicate the report, the
  spacing-only fix and both rebuild joins read: the writer's doc rule first (a comment-led slot the writer
  blank-separates is now REQUIRED to be — reported before `fmt` runs, and the fix lands the writer's blanks), else the
  check's own rule, and only where that rule wants a TIGHT gap the multi-line rule, measured lazily (the answer must
  depend on it). Scope: unconditional pairs only (an `#if` body is written with its source gaps); the four visibility
  containers the writer's class/abstract Stars cover (`MemberGapPolicy.containerKinds`); a slot the measure cannot read
  leaves the pair to the source (positive whitelist: no guessed one-line); a line / block (non-doc) comment-led slot
  stays exempt, as the writer keeps its gaps; same-rank methods and a rank boundary are not lifted (the multi-line rule
  only ever ADDS a blank there, and the rule already wants one or has no opinion); `afterFieldsWithDocComments: none`
  alone (`StripsSource`) is left to the check's own rule, since whether the gap ends blank depends on rules outside the
  policy. Known residue: an extern class's split-leading veto (`// x` then `/** doc */`, `_classExtern`) is not modelled
  — the check may demand the doc blank there and the writer keeps the source blank it then lands, so it converges.
  `separateInlineSubgroup` and `movableArglessNew` are unchanged; the spacing context is one `SpacingPolicy` record
  (`separateInline` + `writer`), resolved per file by `MemberSpacing.policyOf` on both paths — branch `feat/infra-N21`
- `lint --fix` returned `EXIT_RUNTIME` right after its safe-pass net rolled files back, BEFORE the risky and
  oracle-assisted phases, although every revert arm ends on a tree the oracle confirmed green (`Narrowed` on its last
  probe; the whole-wave revert on the very bytes the pre-write verdict judged — `classify` reverts only after a green
  one). One bad safe edit thus silently cancelled every verified fix of the run (anyparse: 13 `redundant-import`, 7
  `explicit-local-type`). The run now goes on: the notice is printed, then `the tree is back to a build the oracle
  confirmed green — the risky and oracle-assisted phases go on`; the reverted round's edits in the reverted files come
  off the summary count (`safeEditsOf`, per file, the follow-up round keeping its own) and `changedFiles` keeps only
  files still differing from the run's start; the summary carries `safe-pass REVERTED N file(s) …`; the exit code is
  still `EXIT_RUNTIME`, at the END — a revert is a fixer defect even when the run recovers. Fail-closed stays with the
  phases themselves: each takes its own baseline and skips on a red one. The per-rule ledger still counts the reverted
  edits as produced (it says what a rule PRODUCED; the notice names what went back). With it the follow-up revert now
  deletes only a file the reverted round's own snapshot lacks — a file an earlier round created is restored, where the
  old `created.contains` test deleted it under every importer — branch `feat/infra-N23`
- `simplify-boolean-return-chain`'s fix replaces the whole chain span (first guard .. closing return) with a `return`
  rebuilt from the conditions alone, so on the FLAT path (N15 already refuses a regrouping chain) a comment between two
  guards, between a guard's condition and its return, or in a condition's operator glue was dropped. The fix now
  declines a chain whose span holds a comment marker (`SourceComments.hasCommentMarker`, string-blind, so a `//`
  inside a string literal also declines — the conservative direction) with a `Violation.declineReason`; the finding
  stays reported, so report mode is unchanged. Refused rather than carried: the comment has no seat in a one-line
  boolean expression the writer would keep — branch `feat/infra-N23`
- the operator-overload gate typed operands with a walk of its own (`OperandBinder.tierOf`: identifier, call, field,
  construction), so every arc the shared walk had gained since — an unannotated local's initializer, the self reference,
  a static extension — was missing exactly where a rule asked whether `!` / `==` / `+` is the language's, and every client
  `!x` whose operand no annotation names stayed refused once `tink` put an `@:op(!A)` in scope → ONE operand typing:
  `OperandBinder` is the third host of `NominalTypes.typeWalk<T, C>` (`TypingHost` gains its currency `T`; the binder's is
  `TypeNameBinding.Tier`, what a written type BINDS to where it is written — the "decl-tier currency the walk does not
  carry" of the B4b entry above, now carried). The by-simple-NAME deep walk (`expressionTypeNominal`) is NOT the
  operator gate's source and must not become it: its answers are names, and the measured `2bdac5ef` cases (an unindexed
  import beside an indexed namesake, an `@:overload` extern, a `Null<R>` alias) are exactly the names it would misjudge.
  The binder answers the arcs in its own currency and fail-closed, each verified on 4.3.7 `--interp`: an inherited member
  (through a receiver or an implicit `this`) only up a closure that resolves link by link and brings no `@:using` (a
  covariant override may sit on an unread link; a supertype's static is not in scope bare — an `import Other.flag` wins);
  a static extension from the LAST `using` of the file whose module (EVERY type of it — `using Mod` binds
  `Mod.Other.tag`) declares the static, taking exactly the receiver's declaration first; refused under a receiver
  closure's own `@:using` (it binds ahead of every file `using`), a `#if`-guarded `using`, an unindexed one, an alias
  (`using` a typedef binds the aliased class's statics); an abstract's `@:op(a.b)` only when no `using` in scope, own or
  ambient, declares a static of the field's name (`r.foo` under `using Ext` is the extension even beside a resolver).
  Doors added to the shared layer for it: `MemberLookup.declarationFreeOfExtensionTypes` / `declarationLacksMember` /
  `declaringMember` (by declaration), `ValueNameBinding.usingHosts` / `usingDeclarations`. client: `ItemListPicker.hx:145`
  (`fileName.toLowerCase().endsWith(…)`) and `ThumbnailLoader.hx:85` (`model.hasNode.thumbnail`) become invertible; all
  other all-rules findings identical on the three client recall trees and anyparse — branch `feat/infra-N22`
- the compiler's facts were a second proof for ONE operator-gate consumer (fold's own `FactsTypeOracle.forFix` in its
  fix), so a site only the facts type stayed refused by every negation rule → the facts are the second source INSIDE
  `OperatorSelection` (`typingFor` hands every asking rule an `OperandTyping` { written, proven }), read only in a `--fix`
  run — the run whose edit journal marks it (`FactsTypeOracle.forFixRun`), whose fix gates compile them anyway — and
  lazily on the first operand the binding leaves unproven. A plain `lint` never compiles facts for it, so a site only
  the facts prove (client `DiskSystemItemData.hx:330`, an untyped lambda parameter) is reported and fixed by `--fix` and
  silent under `lint`: accepted, the alternative being report-only findings for every unproven negation. The facts vouch
  only for a built-in or a class/interface/enum every configuration agrees on (`nonOverloadingName`); an `@:op(a.b)`
  field's facts site names `resolve`, which the text never spells, so that shape is the binder's alone — branch
  `feat/infra-N22`
- `prefer-if-expression-chain` built a per-FILE `OperatorSelection` for the switch rule it defers to, which saw no `==`
  overload a sibling module declares: a ternary chain over such a type read as claimed by the switch rule, which itself
  (one table per run) refused it, so neither reported it; and the fold's fix judged a construct the run left report-only
  against its own file's overloads alone and merged it → one table per run, and a fix asks with the report index it is
  handed (`OperatorSelection.of`'s `report`). Found by `OperandTypingTest`'s parity matrix — branch `feat/infra-N22`
- the CLI ran its command from the entry script's own frame, where V8's verbose `v8::TryCatch` makes EVERY throw build a
  message object (the throw site's source position, decoded from an optimized frame) even when a JavaScript `catch` two
  frames up takes it; the generated parsers backtrack by throwing `ParseError.backtrack` ~400k times on the client tree, so
  that bookkeeping was a fifth of all parsing (5.47 s -> 4.37 s measured by hrtime, not by `--cpu-prof`, whose self time
  INSIDE the generated parser is misattributed — `parseHxCondSemiValueS` showed 1.2 s self against 145 ms measured) →
  `Cli.main` queues `run` as a microtask (`js.Node.queueMicrotask`), which V8 runs under a non-verbose catcher. Exit
  codes and an escaping crash's raw stack are unchanged. NOT done: the throws themselves (~2-3 µs each even now —
  doubling them costs ~1 s); removing them is a codegen change (lookahead before an alternative that cannot start
  here), out of N1's scope — branch `feat/infra-N1`
- `fold-adjacent-string-literals` re-rendered a candidate's whole member per candidate (the client's 120 KB generated
  `FallbackPhrasing2.getEN`: 18 renders, ~1.4 s) → a direct child of a function's block body, two indents deep, is
  measured inside a one-statement wrapper, but only with evidence for THAT statement (`rendersAlone`: the wrapper renders
  back to its own lines and the statement's lines appear verbatim in the member's rendering) — the measure compares a
  rendering with its baseline as a multiset of lines, so equal statement lines give equal widths. A `@formatter:off`
  guard was written and dropped: a statement inside an off region the member copies verbatim fails `rendersAlone`
  unless it is already canonical, and eight fixture families (merge / split / call-argument / interpolation shapes at
  the width boundary) found no input where the guard changed a finding, so it was a gate no test could tell from its
  absence — branch `feat/infra-N1`
- `ProjectCoverage` parsed each `apqlint.json` twice per run directory → a run-scoped `DocumentMemo` (directory +
  content -> parsed document) that the coverage OWNS; deliberately not shared with the lint run's own per-directory
  configs, whose `compilerOracle` entries `OracleGeneration.prepare` writes in place (`unavailable`, `raced`, `runs`), so
  one shared document would hand one directory's prepared entries to another — branch `feat/infra-N1`
- run-scoped memos added for pure per-run answers the checks re-derived per call, each where the answer's owner already
  keeps run state (never a `static`, `docs/design-principles.md` § 2): `CachingGrammarPlugin` (`refShape` once,
  `lexicalRegions` per source as a copy, `checkOverrides` per directory like `maxComplexity`), `RefsCache` (`@:nullSafety`
  scopes per tree), `FunctionTrees` (node per file + span), `SubtypeGraph` (member-name -> declaring types),
  `TypeNameBinding` (import path splits); and `lint` asks rule enablement per distinct config
  (`LintDocuments.distinctConfigs`) instead of per file — branch `feat/infra-N1`
- `empty-block` reported the empty body of a DRAIN loop (`while (gl.getError() != 0) {}`, client GlProgressCurtain /
  NativeURLReaderTimeoutTest) → a condition loop (`ShapeVocab.conditionLoopKinds`: the statement loops minus the
  iterating ones, a new derived vocabulary answer) whose condition is not side-effect-free (`MemberKinds.isSideEffectFree`,
  a positive whitelist — an unknown condition shape counts as working) is not flagged; a `for` gets no pass. The rule HAS
  a fix, so it does not declare `NoAutofix`: each flagged block the fix keeps carries its gate (`declineReason`: loop
  body, try / catch body, side-effecting condition, branch body, then-branch with an else) — branch `feat/infra-N28`
- `explicit-type` never fixed a `macro` function's return type: the oracle is blind in macro context and the structural
  pass skipped them → `:Expr` (through the file's printer, import added when needed) when EVERY own-scope return is a
  quotation `RefShape.quotationTypes` (new seam: `MacroExpr` → `haxe.macro.Expr`, `MacroTypeExpr` → `ComplexType`,
  `MacroClassExpr` → `TypeDefinition`) types `Expr`, directly / in a parenthesis / in both ternary arms, or a tabled static
  call answering `Dynamic` whose type name no project type shadows (`Context.error`, added to `staticMethodReturns` — its
  std signature is `:Dynamic`), at least one being a quotation. Measured with Haxe 4.3.7: `Expr` and `Dynamic` returns
  unify to `Expr` in either order, `macro : Int` is `ComplexType`. A build macro returning `Array<Field>` has no quotation
  return and declines; so does every macro parameter, in its own words — branch `feat/infra-N28`
- `unused-private` declined every private method of an `extends` class as a possible abstract-method impl whenever the
  compiler's facts could not clear the chain, although the resolution scope (client: openfl in `resolutionLibs`) holds the
  whole chain → `supertypeDecline` falls back to `MemberLookup.supertypeMemberProof` over the widest scope index, pinned to
  the owner's declaring file (new optional `file`): `Absent` clears, `Declares` keeps the old decline, `Unreachable` gets
  its own sentence. The shared walk now also answers `Unreachable` for an ancestor carrying `@:build` / `@:autoBuild`
  (its macro may add the member, or run over the subtype) — tightens `param-ascription`'s use of it in the same, safe,
  direction. `TypeResolver.isDeletionPure` takes a `String` method (`PURE_STRING_METHODS`, immutable receiver) on an
  identifier declared `String` (a `Null<String>` reads `Null` and is refused) — branch `feat/infra-N28`
- `shadowing-local` was `NoAutofix` → a fix for the mechanical subset, gated on the hidden binding NOT being read after
  the declaration inside the frame declaring it (a read there is the defect shape the rule exists for — the fix would
  bury it; that one stays report-only). A same-block redeclaration of a single-declarator `var` with the same written
  type becomes an assignment (no comment in the replaced run, no closure capturing the first binding, re-resolved: every
  read of the second must bind to the first afterwards); any other declaration is renamed to its written type's
  lower-camel name through `Rename.rename` (scope-correct, refuses captures and resolution blind spots), refusing a std
  root type name (`int`), a nested function rebinding the name, the name inside a string of the scope, and a name another
  rename of the same call takes in an overlapping frame. Local names carry no meaning a compiler reads, so the fix is not
  a `RiskyFix`; the binder is its verification. Shared pieces MOVED: `SourceText.lowerCamel` (was
  `IntroduceParameterObject`'s private first-letter copy; now lowers a leading acronym run, `URLPair` → `urlPair`) and
  `TypeNameBinding.AMBIENT_TYPE_NAMES` (was `ExplicitType.AMBIENT_TYPES`) — branch `feat/infra-N28`
- the static-extension arc of the deep type walk (`NominalTypes.staticExtensionNominal` → `StructuralTypes.extensionReturnNominal`)
  answered FAIL-OPEN in six shapes (each a 4.3.7 probe): it read only the MAIN type of a used module (an extension on a
  sub-type was missed), ignored a `@:using` on the receiver's type chain (which binds first), fell back to an EARLIER
  `using` past a later one whose first parameter it merely could not prove accepting (`<T>(s:T)` and `(s:Dynamic)` both
  bind there), past a `using` it could not read (unindexed, alias), counted no `#if`-guarded `using`, and took a
  `@:noUsing` static. → the walk over the `using`s is ONE shared door, `ValueNameBinding.extensionDeclaration` (POSITIVE:
  last `using` offering a static of the name — `@:noUsing` and instance members are not offered — on exactly one type of
  its module; null for an unreadable `using`, a build-macro type, two declaring types, a `#if`-guarded type or
  declaration), used by both `OperandBinder.extensionTier` (its own copy deleted) and the deep walk; a first parameter
  not proven to accept now ENDS the walk; the deep walk also requires `closureFreeOfExtensionTypes`, and a file with a
  guarded `using` gets no extension arc (`UsingScan.extensionUsings`, shared with the binder). Not followed: an alias
  `using` (`typedef AliasHost = B` binds `B`'s statics) stays a refusal like the binder's; `import.hx` usings are not
  read by the deep walk (a file's own `using` outranks them, 4.3.7, so the walk can only miss, never mis-answer) —
  branch `feat/infra-N31`
- N26 A1 — an `enum abstract`'s members were all projected as enum VALUES, so `public var vertical(get, never):Bool`
  and `public static var lock` read as "PascalCase or UPPER_SNAKE enum value" (client SelectionHandle, AgeGroup). Haxe 4.3.7
  makes a value of every NON-static field written as a plain variable (`private var C = 3` included) and of nothing else
  (`E.label` → "Cannot access non-static abstract field statically", `static var s` is `Int`). → `NamingSupport.project`
  takes a lazy property-facts thunk (`Naming.propertyFacts`, the plugin's `TypeInfoProvider.propertyAccessors` — the
  grammar-AST fact the tree projection drops), and `HaxeNamingSupport.isEnumAbstractValue` is the positive test (non-static,
  no accessor clause). Without the thunk the projection keeps its old reading, which is what `unused-private` (N28's
  file, not touched here) and `no-underscore-prefix` still get: they ask nothing of an enum-abstract member's category.
  A6 untouched: a PRIVATE property of an enum abstract now meets the same private-field rule a class's does, so whatever
  A6 decides for storage-less private properties covers both (no client site; both client shapes are `public`) — branch `feat/infra-N26`
- N26 A2 — `@:allow` was read off the FILE (`RefactorSupport.carriesAllowGrant`): one grant anywhere refused every private
  member's rename (client StageArea 24 + StageAreaField 4 + SpriteBase 1), and a member carrying only `@:allow` was refused
  as "carries metadata". Haxe 4.3.7: a member grant opens that member only; a type-path grant reaches the type and its
  SUBTYPES (`@:allow(B)` → `BSub extends B` compiles); a package grant reaches subpackages (`@:allow(foo)` → `foo.bar.Q`);
  the path is literal (`@:allow(G)` does not reach `foo.G`). → `AllowGrants.reaching` (member + enclosing-type grants via
  `Meta.find`; null when a code `@:allow` is not attributed — then the file-level answer stands) and `granteeFiles` (types
  whose dot path equals / lies under / is a prefix of the grant, plus `subtypeDecls`; name-keyed, so a superset; an
  unmatched path refuses with `crossAllowUnenumerable`). `isPrivateMemberConfined` / `privateMemberScanIsSound` take
  `?grants` (absent = file-level; other callers unchanged); `ImplicitReach.AllowGrant` for a run of only `@:allow` metas,
  asked LAST, so `unused-private` / the privatize arm still see a non-null reach. A public member asks nothing of a grant
  (its affected set is every file spelling it) — branch `feat/infra-N26`
- N26 A3 — the cross-file rename enumerated a public member's affected files from the LINT scope, so `lint X.hx --fix`
  renamed `public final _scrollContainer` in X while the whole-project run declined; and both the rename and the
  privatize arm counted an unrelated class's OWN `private final _scrollContainer` as a reference. → (1)
  `NamingRenames.outsideScopeFile`: a project file (`resolutionProjectSourcesOf`) outside the run that declares a subtype /
  `@:access` grant, or (public) holds an occurrence not all accounted for, refuses (`crossOutsideScope`) — a narrow scope can
  only refuse more; (2) `foreignBoundSpans`: the occurrences each OTHER same-named declaration resolves (its own
  `declaringFileRenameSpans`; a member of a type provably unrelated in both directions, a local, a parameter) are excluded
  in `otherFileRenameSpans` and become allowed regions of the privatize arm (`NamingPrivatize.foreignRegions`). In a
  subtype file the scope-correct foreign set WINS over the class-attributed bare half — the client census caught the
  opposite order renaming four overrides' `super.setup(accountScreen)` PARAMETER into the inherited field, which compiles;
  a receiver-typed access both halves claim refuses — branch `feat/infra-N26`
- N26 A4 — a local / parameter's decline read "only a member has a confinement proof": the cross-file path, asked first,
  wrote `NOT_A_MEMBER` and first-writer-wins buried the single-file path's collision. → body-scoped categories leave the
  cross-file path silently; `nameCollides(target)` / `qualifyFailed(target)` name the taken name. `no-underscore-prefix`
  writes a reason at every refusing gate. One finding per identifier: `Check.Supersedes` + `Linter.withoutSuperseded` drop
  a superseded rule's finding at the same file + start offset when the superseding check's finding SURVIVED every
  per-file gate and suppression (so it never leaves zero), and `LintFixDriver.applyLintPass` asks it again over the
  active + full-scope union. `no-underscore-prefix` supersedes `naming` (it is opted into and its options state the stance
  on exactly these bindings). No collision-free alternative name is invented: the finding stays report-only with the
  reason — branch `feat/infra-N26`
- N33 — `invert-negated-if-else` turned `!hasNext ? _changeEvent : null` into `hasNext ? null : _changeEvent` (client
  `RequestModelsAccessDialog`), burying the meaningful value behind the fallback. → option `keepDefaultElse` (default
  OFF, so no project changes silently): a negated choice whose CURRENT else arm is a default literal is neither reported
  nor rewritten. Decisions: (1) ONE gate, `NegatedCondition.invertibleOperand(cond, elseArm, site)` (and `positive`, which
  adds the comment check over it), asked with the else arm by the ternary, the value `if`, the `if` statement AND the four
  ternary builders (`ternaryEdit` takes the two value NODES now) — the builders orient `if (!c) return v; return null;`
  the same way the swap would, so they read the same option, spelled under `invert-negated-if-else`; `negatedOperand`
  became private, so no reader can bypass it. (2) "Default literal" is `CaseValueKey.isDefaultLiteral` — the value key the
  switch rules already prove (`null`, `false`, a number whose value is 0 in a spelling `of` reads: `0`, `0.0`, `0x0`,
  `-0`; a string with empty content, either quote), parentheses unwrapped; a spelling it does not read (`0i32`, a named
  constant) is no default — fail-closed, the choice is then inverted as before. (3) Statement form: the else branch counts
  only as `return <default>;`, bare or the sole statement of a block; `else y = null;`, `else null;` are no default arm.
  (4) Only the ELSE arm counts: `!x ? null : v` still inverts, which moves the default last — the option's own goal.
  (5) The config is read lazily per file, and only for a default arm, so a file without one never resolves it.
  Not routed: `double-negation` / `simplify-negated-compound` never swap branches (they rewrite the condition in place),
  and the guard inverters (`guard-return` / `guard-continue`) ADD a negation to build an early exit, which is a different
  reordering — branch `feat/infra-N33`
- N24 (a) — `prefer-keyvalue-loop` declined 30 anyparse loops (52 with `--no-oracle`) on "code at hxnodejs
  Writable.hx:350 may change it", though no call path leads there: `WritableNewOptionsAdapter.from` is an `@:from` of an
  abstract, admitted wherever code read by its syntax runs (`ReachGraph.alwaysIds`) once the abstract is in reach. It was
  in reach by accident: `ReachGraph.signatureWords` sends a structure's `function` field (`FnField`, e.g. std/hxnodejs
  `Iterator.next`, `PathModule.join`) to `inferredFrom` because its return type is not a data field's annotation, and
  `inferredFrom` looked only among `functionKinds` + `fieldDeclKinds`, found nothing, answered null, and
  `AbstractReach.inferred` then put EVERY indexed type in reach — so a `Map` spelled in the region made every library
  abstract's conversions run everywhere. → `inferredFrom` looks among every kind the index records a member under
  (`MemberKinds.FIELD_MEMBER_KINDS`) and reads the field's own text, which spells its declared type (Haxe 4.3.7 requires
  a structure function field's return type: `Explicit type required for field f`). A file that does not parse or a
  member truly not found still answers null and keeps every type in reach — branch `feat/infra-N24`
- N24 (b) — `prefer-static-extension` asked the compiler facts only for a receiver whose declaration WRITES its type, so
  109 anyparse sites (with the oracle) stayed report-only, 72 of them identifiers bound with no written type: 45
  constructor-pattern captures (`case Line(flat)`), 22 loop binders, 5 lambda parameters. The gate exists because an
  inferred binding may be typed by the very call being rewritten: Haxe 4.3.7 types `x.trim()` on a monomorph as a
  structure with a `trim` field, so `var xs = []; for (x in xs) StringTools.trim(x)` compiles and `x.trim()` does not
  (`String should be { trim : () -> Unknown<0> }`); a capture of a generic enum's `Box(v:T)` over `var g = Box(null)` is
  the same. → `FactsBindings.fixedAt`, a POSITIVE list of bindings the compiler typed when it bound them: a capture of a
  constructor argument every same-named constructor the facts hold types closed (`FactsTypeTree.isClosed`: no type
  parameter, no unknown; `FactsTypeOracle.constructorArgumentClosed`; one taking no argument or fewer is skipped — a
  pattern with that argument cannot be of it: `SiteFamily.Text` beside `Doc.Text(s)`), and a single-binder loop's binder over a call
  every call fact at its range dispatches to one non-macro, non-overloaded field with a closed result
  (`FactsTypeOracle.callResultClosed`). Facts are read through the `FactsTypeOracle` door (owned-types) and only on the
  text the compile read. Still refused, by design: a loop over a local or a generic call, a lambda's parameter (typed
  by the callee's expected function type, which may hold a monomorph), a whole-pattern capture, and a constructor name
  a generic enum's constructor shares. The facts' `macro` / `enum` kind spellings moved to `CompilerFacts`
  (`MACRO_FIELD_KIND`, `ENUM_TYPE_KIND`; the private copies in `StaticExtensionFacts` and `CallGraphFacts` deleted) —
  branch `feat/infra-N24`
- N34 — `keepDefaultElse` stopped the swap from CREATING `hasNext ? null : _changeEvent`, but earlier `--fix` runs had
  already written six such sites into client, and no rule turned them back. → option `defaultLast` (default OFF) under
  `invert-negated-if-else`: a choice whose THEN arm is a default literal and whose else arm is no literal is turned so
  the default goes last (`c ? null : v` -> `!c ? v : null`, `a != b ? null : v` -> `a == b ? v : null`; a value `if`;
  an `if` statement `if (c) return <default>; else return v;`). Decisions: (1) `defaultLast` IMPLIES `keepDefaultElse`
  (read together in `NegatedCondition.site`): with only the new option on, the swap would invert `!c ? v : null` back to
  `c ? null : v` and the two directions would ping-pong across `--fix` passes; a project asking for "default last" wants
  both halves. (2) ONE door for both directions, `NegatedCondition.swapOf(cond, thenArm, elseArm, site)`: the strip
  (`invertibleOperand`) first, then `defaultLastCondition`; `invert-negated-if-else`'s three forms ask only it, so a
  swapped choice can never qualify again (a turned `!c ? v : null` is a kept negation, a flipped `a == b ? v : null` has a
  non-default then arm). (3) Positive whitelist of turnable conditions: an atom that takes a bare `!`
  (`NegationSeams.atomicKinds` minus the paren and the bool literal) or an `==` / `!=`, which flips NaN-safely; the text
  is the shared engine's (`NegationScan.negateConditionText`). A compound, an ordered comparison (the engine would keep
  `!(a < b)` wrapped without a type proof), an `is` or a `?:` would need a wrap or a De Morgan rewrite, which reads worse
  than the order it fixes — untouched. A not the strip refuses (an overloaded `!`, a kept default else) is not turned
  either: no `!!`. (4) The operator gate is `OperatorSelection` over the operators the turn WRITES — the not it adds and
  the `==` / `!=` it flips (`NegatedCondition.builtin`, which the strip's not check now shares). (5) "Literal" for the
  else arm is `CaseValueKey.isLiteral` (any number, bool, `null`, string, a negated number) minus an interpolating
  string, which computes its value (client `folder ? null : '${incrementalCloudAction.cloudId}'`), so two literals
  (`_targetSelected ? 0.0 : 1.0`) are a mapping and stay; arms are read the way `keepDefaultElse` reads them
  (`armValue`), and both or neither must be a `return`. (6) The four ternary builders keep the orientation of the guard
  they collapse (`PreferTernaryReturn` quotes its condition byte for byte, so it cannot carry a rebuilt one); a
  default-first ternary one of them writes from a default-first guard is turned by the swap on the next pass, and
  nothing turns it back — the fixed point is pinned over all five rules (`testDefaultLastFixReachesAFixedPoint`) —
  branch `feat/infra-N34`
- N27 A5 — a type / enum-value finding had no fix (`NOT_A_MEMBER`) although `rename --scope` performs the cross-file
  rename. → `NamingCrossRename`, the CROSS-FILE half of `RiskyArm` (`riskyCrossFileFindings` / `riskyCrossFileFix`,
  edit sets of `RiskyCrossFileEdit`), driving `CrossRename.crossRenameType` / `CrossRenameMember.crossRenameMember` —
  no second engine; `FileChange.edits` hands their span edits out so several renames combine over one file.
  RISKY, because the engines' contract is "every miss is a compile error": `FixVerifierCrossFile.extend` (after every
  per-file arm) judges each edit set as a whole — components by shared file, coverage asked per component (an edited file
  no judging configuration compiles declines it), bisect over sets with `FixVerifier.isolateFailers`, the complement
  confirmed before anything is kept. Fail-closed POSITIVE gates for what a typecheck cannot see: whole project indexed;
  type kinds whose name the compiler erases (`compileTimeTypeDeclKinds` typedef / abstract / enum abstract — a class keeps
  its name at run time: `Type.getClassName`, `resolveClass`, serialization, so it is refused rather than proven unread);
  enum-abstract values only (a plain enum constructor's name is runtime-visible), valued by an initializer or an
  `indexValuedEnumAbstractUnderlyings` underlying (Haxe: an implicit `String` value is the name, an implicit `Int` one the
  previous plus one); not a main / guarded / metadata-carrying type; for a TYPE no `StringLiteral` naming it and no runtime type path
  (`ReflectionScan.runtimeTypePath`) — not for a value, which has no runtime name (client `'vertical'` literals are data); the old name declared once (a leftover would bind elsewhere — CrossRenameMember's own
  documented silent case is an imported homonym value); the new name declared nowhere (resolution index, std included) and
  spelled in no project file but a comment; an enum abstract's PROPERTY is no value for those homonym tests; every edited
  file in the run. Type / EnumValue rules carry `pascalCase` (the arm is their only consumer). Separately (A5's "5 private
  members" in a WHOLE-scope run: 1 renamed by N26, 2 correct refusals, 2 owner-name ambiguities):
  `isPrivateMemberConfined(?ownerFile)` passes the declaring file to `hasSubtype`, so only edges resolving to the owner's
  own declaration count (both naming paths pass it; other callers unchanged) — branch `feat/infra-N27`
- N35 (1) — `rename --scope` / `CrossRename.crossRenameType` missed five type-reference positions, found by renaming
  each type of a haxe-typechecked census fixture (simple and qualified spellings of every position) and compiling.
  The struct extension `{ > T, … }` is fixed in the SHARED projection, not in the op: `typeRefShape` lists
  `ExtendsField` (the walk-path node names its type) and `QueryWalkerLowering.typeRefsDescendCore` emits the head of
  a nominal reference `Seq` reached through a `type` slot (`isNominalRefRule`), which is how `> T` nested in an
  annotation (`Array<{ > T, }>`) projected its field types and never `T` — so `uses` / `blast` / `mentions` /
  `move-member`'s carry see it too. The rest is the op's own walk, each matched WHOLE against a path, never by last
  segment: a dotted path in ANY expression position (`var c = pkg.T;`; it was matched only as a receiver) unless its
  root identifier is a value binding of the file; an import whose path runs THROUGH the type's absolute module path
  (`import pkg.T.f;`, `import pkg.T.*;`) and an alias import's path (decoded by `ModuleScan.aliasTargetOf`, the one
  decoder); access grants by the TYPE path. Haxe 4.3.7, compile-checked: `@:access(p.Sub)` grants a sub-module type
  `Sub` of `p.M`, `@:access(p.M.Sub)` and `@:access(p.M)` grant nothing, and a simple `@:access(C)` does not resolve
  through `import p.C` — and a stale grant COMPILES, so this was the one silent miss. The grant metas are
  `RefShape.takesPrivateAccessMetaName` + `AllowGrants.TAG`; a metadata argument of any other meta (`@:op(T + T)`)
  is untouched. Left on purpose: a BARE type name in value position (`var c = T;`, `Std.isOfType(x, T)`) —
  unqualified, it is a nullary enum constructor or an inherited member as far as a by-name walk knows; it stays a
  loud compile error the advisory names — branch `feat/infra-N35`
- N35 (2) — `add-element --before --select 'ClassDecl:X'` on ANY `final class` spliced between `final` and `class`
  ("result does not parse"; the doc and `@:nullSafety` of the report were incidental): the selector resolves the
  inner form, and only `remove-element` lifted it to the `FinalDecl` wrapper (a private `liftedHit`). MOVED to
  `ElementSpan.liftedElementAt` / `liftedElement` (+ `ElementHit`), the RemoveElement copy deleted, `add-element`
  calls it; `RefactorSupport.elementAtFrom` now has that one caller — branch `feat/infra-N35`
- N35 (3) — no op inserted into a sorted list. → `add-element --sorted` (`AddElement.insertSorted`), a mode, not an
  op: same address as `--append` (the array), same canonical writer-emit. Entries are split by the PARSER (spliced
  at the array's front in a probe, read back as children), never by scanning the argument. POSITIVE: every element
  a constant string (`StringFoldSupport.literalOf`, or a `concatKind` of them) whose raw content holds no `\` and no
  `$` (raw text = value); the existing list strictly ascending in code-unit order (`TestDiscovery.compareStrings`);
  a present entry refused. `--append` stays the explicit unsorted form. JSON: no `GrammarPlugin` exists for the JSON
  grammar, so `mutation-arms.json` is out of reach of every op — branch `feat/infra-N35`
- N35 (2b) — `add-element --append` onto an array written WITH a trailing comma (`[…, 'b',]`) spliced `, x` after
  that comma (`,, x`, "result does not parse"; met appending to `TestDiscoveryParityTest`'s deferred-arm census). The
  element now follows the existing separator and takes it over (`'b', 'x',`), also past trailing comments.
  `NamingCrossRenameTest.testTheOracleRunRenamesAndRevertsTheMiss` needed a NEW miss for the oracle to revert, since
  the aliased import it used is renamed now: a typedef alias of a class read as a bare VALUE — branch `feat/infra-N35`
- N35 (2c) — `remove-element` of a comma-list element that holds a WHOLE line of a one-per-line list (`'x',` with
  its comma) left the line's indentation and break behind — a blank line inside the array, kept by the writer as
  trivia (met removing a pin from `TestDiscoveryParityTest`). `ElementSpan.elementCut` now line-extends the
  comma-extended cut (`lineExtendedSpan` changes nothing when the cut does not own its line) — branch `feat/infra-N35`
- N32 — ONE expected-type engine. The only typer of an untyped lambda parameter was a closure of `CallGraphEdges`
  (`expectedAt` / `returnExpectation` / `typeLambdaParams`), in the graph's keyed currency, so the shared walk
  (`NominalTypes.typeWalk`) answered Unknown for one and client `DiskSystemItemData.hx:330 !child.folder` (an inline-getter
  property, no compiler-facts site) stayed refused. → `query.ExpectedTypes`: the LADDER (parentheses, ternary / `if` /
  `switch` arms, the value a block ends with, array element, map value, object-literal field, a lambda's body, `return`
  — an untyped lambda's from its own expectation —, a declaration written with a type, an assignment, a call or `new`
  argument) moved verbatim, generic over a host currency `W` behind `ExpectationHost<W, C>` (declared / assigned /
  returned / argument — the callee's parameter type at an argument position — / element / field / read / part), plus
  `lambdaParamTypes` and `lineageOf` for a typer whose walk keeps no lineage. Every rung proved on 4.3.7 with `$type` of
  the untyped parameter (`v-N32-hx/ladder`, `fixture`). `TypingHost.parameter` is the walk's new arc (asked after the
  initializer and the loop element). Hosts: the CALL GRAPH pre-types a lambda's parameters into `typeSources` through the
  engine as its walk reaches the lambda (its answers unchanged: throughParams substitution of the receiver's type
  arguments, `mayShift`, rest, overloads — all-rules byte-identical on anyparse and client-now), so its `parameter` is null;
  the OPERAND BINDER answers in a `Located` currency (a type written in this file + the offset it is written at, bound
  there by `DeclaredNullity.headTier`, so a type parameter in scope there — the callee's own `<T>`, the enclosing type's —
  answers Unknown by construction: 4.3.7 binds `gen(new FlagOn(), c -> …)`'s `c` to `FlagOn`, never a class named `T`):
  a declaration's / an assigned binding's annotation, a function's written result, an anonymous structure's field, and
  the parameter of a BARE call to a member of this file. POSITIVE whitelist there: one declaration of the name in its
  type (a `#if` twin is another build's signature), no `@:overload` (4.3.7 retypes the lambda against the next
  signature when the first fails — `Foo has no field m`, then `Bar`), no skippable parameter before the bound one (an
  optional or defaulted one: 4.3.7 tries the lambda against it first, `Unknown<0>`), a rest parameter binding every
  argument from its position (4.3.7: the element type); a `Dynamic` parameter or a macro's `Expr` is no function type.
  The INDEX host (`INDEX_HOST`) answers null: it resolves no call to a declaration, and its currency spells a type
  parameter as a bare name its own later lookups would resolve package-blind. Not covered (follow-up): a member of
  another file / an inherited member / `recv.m(…)` / a local function / a construction (need the declaration's
  parameter list — optional and rest flags — read where it is written: `MemberInfo` carries `paramTypeSources` only),
  generic substitution in the binder (`Array<T>.map`, `Lambda.iter`, a `forEachChild<T>`), a typedef alias of a function
  type, a container element (no proof a written `Array` is the standard one), and a `BlockExpr` argument (4.3.7 types it;
  the grammar names no block-expression kind for the ladder). `CallGraphNames.paramsOf` splits the node half out of
  `declaredParams` (the binder holds the node) — branch `feat/infra-N32`
- N36 (1) — `PurityScan` kept its own stdlib list (`Math` / `Std` / `StringTools`, every member but `random`) beside
  `TypeResolver.isPureStdlibCall`'s enumerated one. → ONE owner, `anyparse.query.StdlibPurity`, a POSITIVE whitelist on
  both axes (the functions enumerated against the Haxe 4.3.7 std source; the callee resolved — a receiver root bound to
  no value, no project type declaring the simple name, a `String` method only on a binding declared `String`). Two
  levels, because hoisting and deleting ask different questions: `Transparent` (computable once and droppable — the
  old merged list plus `Std.is` / `Std.instance` / `StringTools.unsafeCodeAt` / `quoteUnixArg` / `quoteWinArg`, and the
  `String` methods but `split`) for `PurityScan`, `EffectFree` on top (`Date.now` / `fromTime` / `fromString`, the two
  `StringTools` iterators, `split`: a clock or a FRESH object per call) for the deletion predicate. The scan's negative
  list had admitted `StringTools.iterator` — hoisting one stateful iterator for three loops — and any project type named
  `Std`. `dead-store`'s fix deleted through its own walk over the scan's list; it now deletes by
  `TypeResolver.isDeletionPure`, the predicate `unused-local` uses. Residual, NOT changed (deletions would be behaviour
  deltas the task did not ask for): `Std.string` runs a user `toString`, `Date.fromString` / `StringTools.urlDecode` can
  throw, and a LIBRARY type (not a project one) named like a std type passes the shadow test — branch `feat/infra-N36`
- N36 (2) — a `RiskyArm` rule's risky tallies were folded into the ledger as if the rule were new to it: its findings
  reached `reported` a second time (the safe loop had counted them on pass 1) and `declined` a second time (the safe arm
  had declined them as hand-offs). → the safe loop records which declines are HAND-OFFS (`RuleFixOutcome.handedOff`,
  asked of the check's own `riskyArmFindings` / `riskyCrossFileFindings`), and `ledgerRiskyTallies` takes exactly that
  share back out and adds no `reported` for an arm rule, so the arm's own verdict is the one that stands. Rejected:
  matching the hand-off by its decline SENTENCE — `naming` writes `NOT_A_MEMBER` on class findings its arm does not own
  too. A run whose risky phase never ran keeps the hand-offs as declines, and the "absent from this ledger" footer no
  longer names a `RiskyArm` rule, which always has a row of its own — branch `feat/infra-N36`
- N36 (3) — `dead-null-guard` trusted every `NullFlow` fact, so `reads && node != null ? node : x` with
  `reads = node != null && …` lost its guard and failed `Cannot return nullable value` (the oracle reverted it in N25);
  `dead-null-coalescing` did the same as a SAFE fix with no net at all. → the `dead-safe-nav` answer, MOVED rather than
  copied: `NullSafetyGate` (its oracle-hxml reading, the `@:nullSafety` scope test and the `nonNullVisible` decision)
  is asked by all three, and under null-safety a proof the compiler does not follow keeps its finding with a
  `declineReason` and no edit. Probed on Haxe 4.3.7, guard dropped: a Bool local, a Bool alias of a conjunction, an
  alias copy, a lone surviving `if` arm and a `try` body fail; a nested guard, an early exit, an assignment, a `&&`
  chain, a `while` condition and two joined arms compile — exactly `nonNullVisible`'s positive list. Rejected: dropping
  the finding (the guard IS dead at run time; `dead-safe-nav` keeps its finding the same way), and dropping
  `RiskyFix` for `dead-null-guard` (the net still guards the control-flow rewrites) — branch `feat/infra-N36`
- N36 (4) — `hxq lint src --fix` over all anyparse src died at node's default heap (N25: OOM at 2371 s). Measured
  in-process (heapUsed after a forced GC at every pass and phase end, sampling heap profiles; RSS was useless on a
  swapping shared box): no per-pass leak — a 337-file run's live set was flat at 2.1-2.3 GB over 12 passes and the
  risky / oracle-assisted / follow-up phases — but the run kept, for its whole length, every text it ever PARSED:
  `CachingGrammarPlugin`'s memos are keyed by content, so every superseded version of a file and every speculative
  text `BodySlotGuard` splices to judge one check's edit set stayed parsed, with its `RefsCache` index. →
  `retainSources(live)` drops every content-keyed memo not keyed by a current source (and the refs index of each
  dropped tree); `applyLintPass` calls it at each pass head and before each file's fixes. Full src, default heap,
  the N25 input: completes (2361 s), output byte-identical to N25's 16 GB run; forced-GC live at pass-1 end
  3152 -> 1783 MB with the per-file prune. Rejected: not memoising speculative parses at all (a `GrammarPlugin` has no
  "transient parse" seam, and the canonical gate re-parses the same spliced text right after the guard, so the memo
  is worth keeping for the length of one file); an LRU bound (a size is a guess, the pass boundary is a fact) —
  branch `feat/infra-N36`
- N38 — `extract-repeated-expression` grouped occurrences by SPELLING alone, so `Std.int(i)` across `i++`,
  `source.charCodeAt(i)` in a `while (…) i++` loop and three comprehensions each binding their own `line` were one
  "repeated value" (anyparse 7 sites, client `HostReport.line.charAt(0)` with `line` reassigned in a loop). → a shared
  write layer, `WriteSites` (query/): every `RefShape.writeParentKinds` node with its target as an access PATH rooted
  at `Refs.bindingAt`'s binding — member, index, parenthesis and cast steps walked, `this.x` rooted at `x` under any
  binding, macro reification skipped, a target with no nameable root a NULL path that writes everything (positive).
  The rule buckets occurrences by the paths they read (a different binding is a different value), drops a bucket a
  write in a nested or sibling closure can reach, cuts at every overlapping write's EFFECT point (node end: the
  right-hand side is read first), drops a run a loop back edge carries a write into unless the statement list the
  `final` would go into is inside that loop, and no longer counts a write TARGET as an occurrence. Overlap is
  prefix-either-way over paths, except a write BELOW a group that is itself the chain (`a.b.c.d =` under `a.b.c`):
  same reference. Measured: root-only matching (any write rooted at the same local) killed real client findings
  (`layoutItem.displayObject.width` across `layoutItem.displayObject.x =`), hence paths. Rejected: `Refs`' own
  `Write` hits as the only write fact (they classify an identifier DIRECTLY at child 0 only — `(i) += 1`, `a.b = …`
  are reads there); killing a whole group at its first write (a run of three on either side is still one value); a
  member written in ANOTHER body through a call (not modelled — the purity rule already reads field chains as pure
  across calls) — branch `feat/infra-N38`
- N37 (1) — the parse was ~2.9 s of a 17 s `lint --all` (client + its libraries, 13.6 M chars), and ~1.6 s of that was ONE
  failed probe, `HxStatement.CondSemiAssignStmt`, tried before every expression statement. The throw is not the cost
  (~0.2 us at any depth, measured; a lookahead guard that skips the inner throw gained nothing): `sample(1)` showed
  the main thread in `Code::GetBytecodeOffsetForBaselinePC` / `GetBaselinePCForBytecodeOffset` — V8 unwinding through
  a Sparkplug (baseline) frame maps PC <-> bytecode offset by a LINEAR scan from the function's start, and the Alt
  dispatchers (`parseHxStatementS` ~600 JS lines, `parseHxExprSAtomCore` ~950) catch their late branches tens of KB
  in: ~20 us per failed late trial. `--no-sparkplug` confirms it (parse 2.9 -> 0.8 s) but costs the rest of the run.
  → `BranchOutlining`, codegen pass 4: every `Lowering.tryBranch` trial becomes a static helper `<rule>Alt<k>(ctx,
  <captured typed locals>)` answering its value or `null`; the rule keeps a call per branch. Positive whitelist
  (typed read-only captures, no `break`/`continue` leaving the trial, no `switch`, every `return` non-null by shape);
  on today's grammars 756 helpers, none declined. Every grammar's parser gets it (plain, span, trivia, binary). Parse
  2.9 -> 0.75 s, the 6519 lint-corpus parse trees and error messages identical, `--all` 16.9 -> 13.8 s. Rejected:
  first-token lookahead before the hot probes (the probes fail at their SECOND token or later — after a whole atom —
  so a first-set guard cannot skip them, and skipping the inner throw alone measured no gain); a node flag
  (`--no-sparkplug` slows everything that is not the parser; a codegen fix is portable and needs no shim) — branch
  `feat/infra-N37`
- N37 (2) — `NullFlow.analyze` ran once per consumer per file: eight consumers, six of them (`always-null-comparison`,
  `dead-null-guard`, `dead-safe-nav`, `dead-null-coalescing`, `null-dereference`, `possible-null-dereference`) with no
  seed, no `declaredNullable`, no `typeSources` — the same walk six times. → a seedless walk over a tree the run's
  `RefsCache` holds is recorded once (`RefsCache.nullFlowVisits`, dropped by `forget` with the tree's other memos)
  and replayed to every consumer in the recorded order; each visit's facts are frozen over a copy of the state, and
  consecutive visits under an unchanged state share one copy (client: 318k visits, 17k copies). A walk any of the three
  parameters changes is never answered from the recording. `SameItems.of` (runtime/) is the shared array equality it
  needed; `CondBranchProjection.sameNodes` and `FoldStringLiterals.sameBoundaries` were the same function and are
  deleted. client `--all` 13.96 -> 13.58 s; live heap at exit +43 MB (775 -> 818). Rejected: a copy per visit (+260 MB
  live); fanning one walk out to every consumer at once (the rules run one after another, each over all files; a
  shared walk would have to hold the other rules' callbacks and violations) — branch `feat/infra-N37`
- N37 (3) — two linear lookups in `thread-safety`'s hot path: `ArgumentValues.annotationOf` read the written type of
  a declaration by scanning EVERY key of the file's offset -> type map (an `IntMap.keys()` array built per call) for the
  smallest one inside the declaration's span, and `AllocationSets.fileOf` scanned every call-graph node per question.
  → the offsets are sorted once per file and answered by binary search (`SortedOffsets.firstIn`, runtime/, the
  smallest offset in `[from, to)` — the same answer); `fileOf` remembers each owner's answer for the run, like the
  class's other per-run memos (the graph does not change under it). `--rule thread-safety` 4.35 -> 4.06 s, `--all`
  13.41 -> 13.17 s — branch `feat/infra-N37`
- N37 (4) — `CondDirectives.scan`, read by fifteen callers per file, stepped through the source one character at a
  time, testing every character against the directive markers (`Array.contains`). → it jumps from one marker to the
  next with `indexOf` (a directive can start only at a marker; the non-code regions are skipped exactly as before, at
  the marker's offset instead of at every offset). `--all` 13.24 -> 13.11 s — branch `feat/infra-N37`
- N41 (A13) — `oversized-type` counted every member, so a table of constants (client `Colors`: 87 `static inline final`
  colours; `Dimensions`: 142 plus a constructor) was reported as a decomposition candidate that no member-reference
  seam could ever split. → the user's decision (2026-10-18): the size of a type is its BEHAVIOUR, so a constant is
  neither a member nor lines of its type. A constant is a positive whitelist (`OversizedType.isConstant`): a `static`
  final field, no accessor clause, with an initializer that is `inline` (Haxe's own proof: it refuses `inline` on an
  initializer it cannot fold — verified on 4.3.7, `Std.int(3.5)` accepted, `new Array()` / `[1]` / `O.S` refused) or
  that `ConstantFieldScan.isConstantExpression` accepts (a scalar or plain string literal, an operator or a paren over
  constants, a name of another constant of the same type, read to a fixpoint); and a non-`static` field of an `@:enum
  abstract` (an implicit value or a constant one). A `static var` (even `inline`: the whitelist names finals), a
  property, an instance field, a function, a `static final` built by a call / field access / cast / allocation /
  interpolation / `null`, or a name the type does not declare count as before. LINES: every line of a type belongs to
  the member that ends it (after the previous member's last line, or the header line, through its own last line), so a
  constant takes its doc, its annotations and the blank lines above it; a constant's lines are not counted, except a
  last line a behaviour member also starts on. Rejected: subtracting only a constant's own lines (a documented table
  then still measures its docs and blank lines as behaviour — a pure table of 900 constants with one-line docs reads
  900 lines); exempting a type from the line limit only when it is ALL constants (a mixed type would then measure its
  table as behaviour, the inconsistency the member half was fixed for). `StaticConstant.isConstantLiteral` moved to
  `ConstantFieldScan` (the one literal test both rules ask) — branch `feat/infra-N41`
- N40 — `swallowed-exception` reported `catch (exception:Exception) { threw = true; }` whose `threw` the code after the
  try reads (client `ApplicationSettingsStoragePathTest.hx:117, 222`): the failure became a value the function acts on, so
  nothing was swallowed (user decision 2026-10-18, A10). → exempt a catch body that is POSITIVELY an outcome record:
  every statement an expression statement assigning (plain `=`) a constant (`MemberKinds.isMovableLiteral`: a literal
  or a negated number, reading nothing) to an identifier `Refs` binds to a `localDeclKinds` declaration, and each such
  local read — a `Read` hit of the SAME binding — in a later statement of a statement list
  (`ControlFlowSupport.blockKinds`) enclosing the try, inside the innermost function around it
  (`ShapeVocab.functionLikeKinds`). Everything else keeps today's verdict: a field, a parameter, a loop or catch variable; a computed value or
  a compound assignment; a call or a nested statement in the body; a local read only before the try (a back edge
  through a loop is a path, but not one this proves), only in another arm of a branch the try sits in, or only through
  another declaration of its name; a read only outside the closure the try sits in (the closure runs whenever it is
  called). A first draft also required the declaration inside that function: its arm survived — the bounded read
  already rejects the closure case — and a captured local read after the try INSIDE the closure is a real outcome, so
  it went. The exception referenced in the
  body was already "handled", so `err = exception;` needed nothing new. No per-check binder: the write and the reads
  are `Refs.find` hits — branch `feat/infra-N40`
- N39 A6 — the built-in policy named every property by the FIELD rules: `private var active(get, never)` was told to
  take the private-field `_`, and `public static var LIBRARY_PATH(get, never)` to be camelCase (11 + 3 client sites). The
  user's rule reserves `_` for private FIELDS, not methods, and a property with no storage is a method in disguise;
  a static read-only one is read like a constant. → the user decided (2026-10-18): a private storage-less property is
  exempt from the prefix (`camelCase storage-less property`, `_` neither required nor forbidden — forbidding it would
  have added three report-only client findings the decision did not ask for), and a public static `(get, never)` takes the
  static-final format. Storage-less is a POSITIVE proof (Haxe 4.3.7: a `(get, never)` getter reading its own name is
  "not a real variable"; `@:isVar` or a `default` / `null` slot gives storage; `(never, never)` does not compile):
  both slots in `AccessorClauseText.STORAGELESS_ACCESSORS` (moved there from `RedundantIsVar`, which now asks
  `storageless`), no `@:isVar` in the leading run, and a run crossing no `#if` region (`HaxeNamingSupport.leadingRun`,
  which `metaInRun` now reads its answer off). Anything unproven keeps the field rule. The facts reach the projection
  through the existing `NamingSupport.project` thunk, widened from "has a clause" to a `PropertyClause`; the grammar
  confers the neutral modifiers `storageless` / `readOnly` and the built-in rules select on them, so a checkstyle
  policy (which never names them) is unchanged. The (b) fix is the ordinary rename machinery — a static property's
  accessors are always beside it, so it refuses as rename-unsafe; no new engine. Rejected: recategorising the
  property as a Method or Constant (it would move checkstyle's `MemberName` jurisdiction and every consumer that
  reads the category: hoist, privatize, the cross-file arms) — branch `feat/infra-N39`
- N42 — `TestDiscoveryParityTest` was 8193 lines, past its own `oversized-type` grant (7850), because every task
  appended to its inline lists. → split by concern, the SAME assertions: `TestDiscoveryParityTest` keeps the
  registration (`REGISTERED_CLASSES`, the base classes, the dead-fixture and discovery-only pins; `tools/suite-shard.sh`
  still counts `REGISTERED_CLASSES` there); `PinCensusParityTest` takes the pin census, `ArmCensusParityTest` the arm
  and deferred-arm censuses (methods moved with `move-member`, names unchanged). The lists became `public static
  final` data in `unit.census`, cut so every part stays well under the default 2000-line limit with no grant: the
  SORTED pin census by sorted range (`PinsCheckAToO` < `'unit.check.P'` <= `PinsCheckPToZ` < `'unit.cli.'` <=
  `PinsGrammarAndCli` < `'unit.query.'` <= `PinsQueryAndRuntime`, concatenated in that order, each part addressable by
  `add-element --sorted --select 'FinalMember:PINS >> ArrayExpr'`); the DECLARATION-ORDERED arm census in thirds
  (`DeclaredArms1..3`, appends go to the last part, a fourth part when it nears the limit); `DeferredArms`; the shared
  `diffedMsg` in `CensusDiff`. The grant is gone. Proof: the expected list of each of the 10 assertions digests to the
  same entry sequence before and after (sha1 over the folded string values), suite 17287 tests / 63601 assertions both
  sides, classes 977 -> 979 (the two new ones). Rejected: one assertion per part (a different assertion set, and
  a partition could leave an entry in no part); comparing the arm census SORTED so it could take `--sorted` inserts
  (drops the order the assertion pins today — a user decision, not a refactor) — branch `feat/infra-N42`
- N45 — thread-safety false positives on the client corpus e58762ed (all five false keys of `truth-1d1ba147.json`, plus its one
  unknown). `C|ItemList.reload|VolumeWatcher._mutex`: `ExhaustiveSwitches` already models the catch-all of a switch
  over a closed enum abstract (`ItemListViewType`), but `storedHolds` counted EVERY write of the member's NAME, and the client's
  `Form.get_data` writes a computed name reflectively (`result.setField(formGroup.field, …)` on a fresh `{}`), which
  `FieldWrites.of` files under every name → `ItemListPicker.viewType` "might hold any value". → a write counts only where
  `FieldWrites.mayWrite(site, owner)` says it may write the member's field — the shared answer the lock layer already
  uses: a reflective write only where `ReflectiveReach.placeOf` lets it reach the owner (a fresh structure reaches no
  class; a `Dynamic` target any), a write off another receiver always, an own write only where the running type's
  declaration of the name is the owner's. RED on 3c761cde2 (`testAWriteElsewhereWritesTheMemberOnlyWhereItMay`, 2 of
  3 asserts). Left reported, not soundly fixable: `A|RoundedTextField.new|Assets.getBitmapData` (`ArgumentValues.bind`
  binds no `new`; binding the client sites needs Haxe's optional-argument skipping by unification on arithmetic, foreign
  constants and openfl's `TextFormatAlign`, whose `@:from fromString(String)` makes a String literal unify with
  `textAlign`; the branch is `endsWith('.svg')` and valuations hold no string values); `B|StandardDiskSystem.listFolder`
  (the try body runs `DiskSystemItemData`'s inline accessors, and `get_master` THROWS — `DiskSystemItemData.hx:185`;
  the catch is dead only by a data invariant); `B|ShardDatabase.new` (`ownConstructorHold` refuses the super call into
  the LIBRARY constructor `EventDispatcher.new`, which runs with `this` before the hold — library bodies unread);
  `B|ShardDatabase.getFolderLastCloudActionAction2` (worker origins through `spawns` entries that do not say which
  argument runs on the worker: `NetRequest2.success`, `FileIO.readAndProcess`'s `onDone`). `A|GpuOutputPipeline.
  acquireGlContext|untyped.__cpp__` relabelled `real-short` (a GL context bind; reported by design, project native code
  is blocking unless `nonBlocking` names it) — branch `feat/infra-N45`
- N20 — no op could take a member that READS its type's state out of the type: `move-member` refuses `this` in a moved
  body, and `--scaffold` mirrors the fields the body reads onto the destination, a copy where the member needs the live
  object (N13 split `CallGraph.collectEdges` by a refs script, `hxq new --raw` and remove/patch ops). → `move-to-helper`
  (`MoveToHelper`, `MoveToHelperRefs`, `MoveToHelperTypes`, `MoveToHelperArms`, `MoveToHelperCommand`): the members
  become statics of a helper taking the source as an explicit first parameter. It is built ON `move-member`'s machinery,
  not beside it — the same resolution (`MoveMember.resolveMove` in a `helper` mode: no field travels, an instance move may
  cross packages), the same inheritance / `#if` / capture guards (`resolutionGuardError`, split out of `moveGuardError`
  without its `this` refusal), the same static-caller passes, promotion, `@:access` grant, destination assembly and
  import carry (`pushImportEdits` gained the extra declarations it carries and the names TRAVELLING, which
  `DependencyCarry.dependencyNames` no longer prices as dependencies), `MoveMemberReceivers` for receiver-qualified
  callers and `Refs` for every bare reference; nothing re-derives a binding from text. ACCESS: `@:access(<pkg>.<Src>)`
  on the helper side (the moved member, or the helper type for two or more), not `@:allow(<Helper>)` on the source: the
  grant sits on the code that needs it, the source's declaration is untouched, and it is `move-member`'s existing rule;
  compile-probed on 4.3.7 it also covers an inherited private field read through a subtype receiver (`@:access(a.Sub)`
  reads `Base`'s private `bp`) and a write of a `(default, null)` property. The grant is taken BY NAME (any receiver of a
  non-public member's name, or an inherited one), because a method may read another instance's private field (`o.x`);
  a same-named member of an unrelated type only over-grants. REFUSALS, positive: an unbound lower-case name is resolved
  only as an inherited member (`<param>.x`), a package root of a type path, a module-static wildcard name (which the
  carry moves), `trace` or the pattern wildcard `_`; everything else — including a field import `import p.M.f`, which the
  carry does not move, and a module-level value of the source module — is refused naming the reference. A property
  accessor is refused because inside `get_x` the bare `x` is the physical field and `<param>.x` would call the accessor
  again; an instance field because a static helper holds no state; a function-value use because a static method has no
  bound form. ARMS: hxq has no op that edits `test/testkit/mutation-arms.json`, so `--arms` prints a HINT (retarget a
  moved member's arm; flag an arm whose `find` no longer cuts its member, measured with `Patch.locate`, the matcher
  `tools/mutation-arm.sh` applies) instead of editing it. Rewriting the finds and replaces themselves is left as a gap:
  a `replace` is the author's text and can name a member the move qualified. Proof on a copy of 3fb1637a4 (N13's start):
  after `set-modifier -private` on `ParsedEntry` (which the op refused as a private type both sides name), one
  `move-to-helper CallGraph.hx collectEdges --to CallGraphEdges --param g` wrote `CallGraphEdges` equal to N13's
  hand-made one modulo the method's name, its doc and the `@:access` seat, compiled first time; 131 arm retargets
  (N13's 131) — branch `feat/infra-N20`
- N44 — two op bugs N42 met. (1) `hxq new <path>` into a directory that does not exist died on `ENOENT … <path>.apq-tmp`,
  and so did `extract-interface --out` / `extract-superclass --out`: the three file-CREATING ops all write through
  `CliIo.writeFiles`, whose staging temporary sits beside the target. → the writer creates the missing directories
  (`mkdir -p`, the conventional generator behaviour; the path already names the package, and refusing would only make
  every caller run a `mkdir` first), one at a time and recorded, so a change set that is not written takes back the
  ones it made, and one that fails part way leaves only those a committed member lives in. Every other op writes a file
  that exists (`move` needs an existing destination module: its own contract, not the writer's). Rejected: a refusal
  naming the missing directory (consistent, but it moves the same `mkdir` onto every caller for no safety gain — the
  write is still `--write`-gated and prints the path). (2)+(3) `move-member` carried a `using Lambda;` beside
  `a.concat(b)` on an `Array`, and `unused-import` kept the same statement, both on the TEXT scan
  `OccurrenceScan.usingExtensionCalled`: a `.concat` occurrence counted as a possible `Lambda.concat`. Haxe 4.3.7
  resolves a member of the receiver's type first (`[1].concat(list)` under `using Lambda` reads `haxe.ds.List<Int>
  should be Array<Int>`; an own or inherited instance `tag():Int` beats a `using E` `tag(d):String` — `Int should be
  String`; a STATIC `tag` of the receiver's type does NOT, the extension binds). → the scan takes a member-first door,
  `CheckScan.memberBoundAccesses`: an occurrence that is the name of a member access whose receiver the checks' typer
  types (`typeNominalResolver`, receiver mode) and whose type provably declares an unguarded INSTANCE member of that name
  on ONE declaration (`MemberLookup.instanceMemberBinds`, new; the std listing `StdTypes.declaresInstanceMember` for a
  type no index holds, unless a project type takes the name) is no extension use. Both consumers pass the same door, so
  the two answers cannot disagree (`UsingMemberFirstParityTest` runs both on each input). Positive whitelist: an
  untyped receiver, an unresolved or ambiguous type, a static, a `#if`-guarded member or declaring type, a source
  that does not parse, an occurrence no member access names (a comment, a string) keep the `using`. Not done: which of
  SEVERAL `using`s an extension call binds (`ValueNameBinding.extensionDeclaration` walks them, but only once the
  receiver is proven to LACK the member, and its null is "unproven", not "none") — a call on an unproven receiver still
  keeps every `using` whose module declares the name — branch `feat/infra-N44`
- N43 — two ops N42 had to script around. (1) `extract-constant` gains an ADDRESSED mode (`ExtractConstantTo`, CLI
  `ExtractConstantToMode`) instead of a new op: the literal modes stay, and the destination machinery is the one
  `--into` already had (`ExtractConstant.buildModuleSource`, now public). What moves is a POSITIVE whitelist read from
  the shared layers: no name read (`ExtractConstantTo.firstContextRead`, shared with `move-elements`), a compile-time
  constant by `ConstantFieldScan.isConstantExpression`, `inline` by `isConstantScalarInitializer` (the `inline-constant`
  proof). An array / object literal is NOT a constant — a static final is one shared instance where the local was a
  fresh one per evaluation — so it moves only under `--shared`, an operator assertion like `resolve-define
  --undefined`, never inferred. Types visible from another module = a dotted path or a std top-level type (`StdTypes`);
  anything else is refused and `--annotate` spells it. The import follows `RefactorSupport.bareNameResolves`, plus an
  explicit import whenever the source has a wildcard import that could shadow the bare name. (2) `move-elements`
  (`MoveElements`) cuts a slice with ONE span (`ElementSpan.commaListCut`, the comma half of `elementCut`, now shared)
  — per-element cuts collide when two elements share a line — and inserts through `AddElement.appendElement` /
  `insertSorted`, so the sorted-list rules are not copied. The target is addressed by selector / pattern only (a
  position does not survive the cut). The result is re-read and compared before it is returned (old minus slice, old
  plus slice); the digest the dry run prints is the MD5 of the whitespace-collapsed entry texts. Rejected: inferring
  an aggregate's immutability from its uses (a read passed to any call is unknowable), moving type-naming elements
  across modules with carried imports (needs the destination's binding ladder — `DependencyCarry` — not worth it for
  data lists) — branch `feat/infra-N43`
- N49 — thread-safety callback model. (1) `spawns` said "every function value handed to the call runs on a new thread"
  for EVERY argument, while the client's `FileIO.readAndProcess(path, process, onDone)` runs `process` on the I/O worker and
  `onDone` on the main thread, so `onDone` handlers (`ModelStageImageCacheItem.cacheReadHandler`) were worker
  callbacks and a false background origin kept the key `B|ShardDatabase.getFolderLastCloudActionAction2|…_batchMutex`.
  A `spawns` item may now be an object `{"call": <pattern>, "main": [<position>…], "evidence": "…"}`
  (`ThreadSafetyOptions.SpawnArguments`); the plain string keeps its meaning. A value at a `main` position runs as a
  `marshals` call's value does — MAIN context (`ThreadSafety.callbackContext`), once per post (`CallRepetition.marshalled`)
  — through ONE predicate, `ThreadStates.runsOnMain`; it stays out of the registrar's lock window and repetition as
  every `spawns` value does (the call is still in `spawnIds`). The position is the WRITTEN one, recorded on the `Ref`
  edge by `CallGraphEdges.scanArgs` (`CallEdge.argument`, `ArgumentPosition`); it counts only where the callee is
  proven to bind the parameter there (`CallGraphKeys.bindsItsPosition`, new, beside `mayShift`): the run declares the
  callee and its declarations read their parameters alike (`paramTypesOf`: an `@:overload` is none), no optional the
  language may skip shifts it (Haxe binds by type when a call writes fewer arguments than it declares), and it is no rest
  parameter. Everything else falls back to the plain entry: an argument no `main` names, an edge with no recorded
  position (the compiler facts' edges, a `dynamic` member's derived calls), a library callee. A malformed object naming
  its `call` is said and KEPT as a plain entry (what the call meant before the form existed), one naming none is dropped
  and said. Rejected: a `worker` list beside `main` (an unnamed argument already keeps the plain verdict, BG), the
  object form in `marshals` / `registers` (no consumer). (2) N46 E1: `CallRepetition.registered` required a runtime call
  for every `registers` entry, while `ThreadStates.runsHere` honoured a project member — the two disagreed. A
  `Type.member` entry is now the project's word on that member for repetition too, exactly as a dotted `runsOnce` entry
  already was (`ChainLists.registerMemberIds`); a bare name still speaks for the runtime's calls only (the `Hub.addEventListener`
  decision above stands). (3) N46 E2 NOT done: tying quiet->loud to `runsHere` would keep quiet a value handed to an
  ordinary call, and `runsHere`'s "runs here" is an over-approximation that is conservative for a lock window (more in
  the window) but UNSOUND for quietness — a plain call may store the value and run it later from the frame loop, loud.
  Proving "runs synchronously" needs a parameter-flow summary of the callee (E3's machinery); no list says it today
  (`iterates` is about repetition, `runsOnce` says "now or later"). (4) N46 E3 NOT done: a forwarding summary needs
  parameter dataflow (which parameter a function hands where, through `.bind` partial application and stored fields)
  that the graph does not keep — `ArgumentValues` is the layer that would own it; client measured 0 B/C/D findings on such a
  chain (N46). The residue it would close: FileIO's own wrappers (`read`, `write`, `modificationTime`, …) forward their
  `onDone` PARAMETER to `run`, which no edge records, so a callback handed to one runs in its registrar's context — right
  from the main thread, wrong from a worker — branch `feat/infra-N49`
- N47 — JSON editing goes through the EXISTING ops, not a second engine. (1) A `json` `GrammarPlugin`
  (`JsonQueryPlugin`) whose tree is the GENERATED query walker's (`JsonQueryWalker`, `Build.buildQueryWalker` over a new
  span parser `JValueSpanParser`), so the kinds are the grammar's ctor names — `JObject` / `JArray` / `JString` /
  `JNumber` / `JBool` / `JNull` — plus `Member` (`JEntry` gains `@:spanned('Member')`). A member is named by its key
  through a new walker opt-in, `@:queryName` on a `@:spanned` Seq's String field (`QueryWalkerLowering.lowerNameSeq`;
  positive: a tagged non-String stops the build); `JString` is named by its decoded value. Rejected: a hand-written
  projection over the paired `*S` types — the synthesised `spans.Pairs` module does not exist when a module importing it
  is loaded, and the walker is the one projection mechanism the Haxe plugin already uses. `JNumber` / `JBool` stay
  unnamed: naming a terminal ctor by its text would rename Haxe's literal nodes too. (2) A FORMAT-PRESERVING writer
  (`JsonLayoutWriter`): delimiters from `JsonFormat`, scalars and keys from their spans, gaps verbatim, so
  `writeRoundTrip` is the identity on every parseable document and the canonical gate never refuses one. The edit
  layout cannot live in `writeRoundTrip` (after a splice nothing tells a new node from an old one), so
  `CanonicalEdit.canonicalize` asks a new seam first, `GrammarPlugin.layoutSplice(source, edits)`: null for a writer
  that re-emits (Haxe — byte-identical), else the spliced text with each node inside an edit's footprint laid out like
  its nearest same-kind sibling (else its container's shape) and each gap the footprint touches re-derived from the
  container's untouched gaps. Indent unit and line end are the document's. (3) MOVED, not copied: the engine-held Haxe
  lists `MemberKinds.COMMA_CONTAINER_KINDS` and `AddElement.EXPR_CONTAINER_KINDS` become `RefShape.commaContainerKinds`
  / `delimitedContainerKinds` (Haxe values unchanged); `trailingCommaHostKinds` was NOT reused, because a Haxe anon
  type separates `var` fields with `;`. (4) A `.json` path selects the json plugin whatever `--lang` says
  (`CliArgs.pickPluginFor`), because the `hxq` shim prepends `--lang haxe` to every call; `json` stays out of
  `CliArgs.langNames`, the CODE-grammar registry whose Haxe-sized floors `RefShapeKindProjectionTest` applies —
  `JsonQueryPluginTest` checks its declared kinds against its projection instead. Not done: `patch`, `move-elements`,
  `--sorted` over objects by key, a key containing `>` in a selector — branch `feat/infra-N47`
- N58 — `owned-types` asks the binding AT the use site and reads an `Unknown`'s candidates; the deep typer types a local
  from the construction initialising it. (1) D1 (client `CrashReport.hx:171`, `QuietExit.exit(1)` reported as `Sys.exit`):
  `OwnedTypes.typesNamed` called `tierOf(name, info)` with no offset, so a `#if sys` import of an INDEXED module was never
  co-guarded with the `#if sys` use beside it — the other build's strict package tier read an unindexed `a.Tool` and
  the name went `Unknown`, which the static-member check matched by member name alone. Fix: the offset is passed (the
  memo is per name, per site only in a file holding a guarded import — `coGuarded` reads the file's own statements
  only); and `TypeNameBinding.unknownCandidates` (new, beside `tierOf`) names what an `Unknown` may be when each
  candidate is read — `bothBuilds` now merges the guarded statement's binding with the rest's (`Answer.Either`), where
  it used to drop both into `Unreadable(null)`. The rule reports such a name only when a candidate is the owned type: an
  indexed one by identity, one outside the index by its last segment (the reading an unresolved dotted spelling already
  got). Any candidate nothing reads — an import of a module outside the index, which may carry any sub-type, a skipped
  file, an unbounded ambient chain — keeps the name open and reported (fail-closed). The candidates are a separate query
  rather than a payload of `Tier.Unknown`: `Tier` is constructed and matched in ~35 places (`OperandBinder` builds its
  own `Unknown`s) that never read candidates, and `tierOf`'s answer is unchanged for every caller. (2) D2 (recall):
  `final x = new Box(); x.open()` was missed while `new Box().open()` and an annotated local were seen —
  `valueNominalDeep` fell back to `constructedNominal` for the `new` node itself only. Now it follows an identifier
  through `localInitializer` (the same un-annotated-local reading the source walk uses), local to local, to the
  construction. Kept at the NOMINAL level: the source walk still types no construction (`new Box(item)` is a `Box<Item>`
  nothing spells), and an initializer that is a call is not followed (no new arc, documented in the instance-member
  limits) — branch `feat/infra-N58`

## N51 (2026-10-19): add-meta by entry, add-import reads the project index, two re-checks

- `add-meta` refuses only an EXACT repeat of the entry (name AND arguments, whitespace runs folded; `AddMeta.sameEntry`).
  Haxe allows several `@:access(...)` on one declaration, and the old name-only refusal made a second one impossible.
  A sibling without a span counts as the same (refusal side of the doubt).
- `add-import` placed `haxe.ds.Either` between `LexRegion` and `MoveMemberFields.*`. Not a second comparator: the seat IS
  `ImportOrder.insertionFor`, but its wildcard gate needs the host's resolution index and the CLI op built its plugin with none,
  so every wildcard was a run boundary there while `import-order` (which has the index) read it as a member. The op now wraps
  its plugin through `cli.ProjectResolution.hostFor` (nearest `apqlint.json`, the scope `lint` builds through
  `LintCommand.resolutionThunk`, read lazily - only a header with a wildcard asks). Other single-file ops still pass no scope;
  they place no imports through the gate-aware seat except `move-*`/materialisers, which hold their own hosts.
- Re-check of the August F20 side findings: `dead-store` on a value read only through a closure capture does NOT reproduce
  (arrow, local function, `.map` lambda, capture before and after the store, loop capture: no finding; the one control store is
  still reported; the pins are `DeadStoreCheckTest.testClosureUseExcluded`). `tools/bench-ab.sh` still hard-wired the repo-root
  `hxformat.json`: it now takes `--config <path>`.
- N48 — how a call binds its arguments is ONE model, Haxe's (`ArgumentSlots`), and the argument types it is decided by
  come from the SHARED walk. (1) `ArgumentSlots.runs`: every way a call may bind, greedy and never backtracking as
  4.3.7 binds (`f(?a:Int, ?b:String, c:Int)` called `f(1)` is an error, not `c = 1`), over a THREE-valued fit
  (`Fits` / `Misfits` / `MayFit`): a misfit skips an optional parameter, an undecided fit is followed both ways, a run
  that cannot compile is dropped — so the answer is a superset of the compiler's (Haxe refuses some skips into a rest
  parameter the model keeps, `e(?n:Int, ...r:String)` called `e('a', 'b')`). It replaces `ArgumentValues.maySkip` /
  `sameWrittenType`, which only knew "every optional parameter an argument reaches is written with its own type".
  (2) The fit is a POSITIVE whitelist (`ArgumentTypes`): two core types (`RefShape.coreValueTypes`, each one no indexed
  type bears the name of) fit when equal or widening (`Int` to `Float`, probed) and misfit otherwise; `null` fits an
  optional parameter; the same plain name written in one file, no type parameter of it on either side, fits; EVERY other
  pair may fit — an abstract may take a `String` through `@:from` (openfl `TextFormatAlign` does), so a non-core
  parameter never misfits. A `Null<…>` peels on both sides (4.3.7: a `Null<Int>` binds `?f:Float`). (3) The argument
  types are `NominalTypes.typeWalk` over a fourth host (the call graph's tables: literals, annotations, a local's
  initializer, a field of the enclosing chain, a static off a type name) plus a NEW arc every host may answer,
  `TypingHost.arithmetic` (the binary `RefShape.arithmeticKinds` and the negation; `Int` unless an operand is
  `Float` or the operator is `Div`, probed with `$type`); the three existing hosts answer none. (4) A valuation char
  now stands for a SET of atoms (`t` `f` `n` `v`, a known string) — a value of several, or a string, spelled by a
  private-use char interned per `ArgumentValues` — and `EdgeConditions.carried` cuts a site only when, for some tested
  parameter, NO atom it may hold passes every fact there; another instance reading an unknown char reads it as
  undecided (`MustHeld`). (5) A `New` edge binds like a call (an inherited constructor takes the subtype's `new`), and
  a site with no function node (a field initializer, `<init>`) is found in the file tree. (6) A `null` handed to a
  parameter with a default holds the DEFAULT (4.3.7 on interp / js / cpp: `f(s:String = 'a')` called `f(null)` holds
  `'a'`) — the old valuation answered `null`, a real unsoundness. (7) A string literal is an atom only for a parameter
  a string affix guard of the callee tests (`p.endsWith('.svg')`, `RefShape.stringAffixTests`), where the call is
  provably the std `StringTools` one: the receiver written as the core string type, and the `using` the file binds the
  method to (`ValueNameBinding.bindingUsing`, the last one whose module is unread or declares it, every later one read)
  is `StringTools` with no indexed type of that name — printable ASCII literals only, which every target compares
  alike. Rejected: tabling std `UInt` as a core number (its arithmetic is `@:op`-typed, two `#if` declarations), and
  reading openfl's `TextFormatAlign` (a library under three `#if` variants the thread-safety graph does not index):
  those leave the client's `RoundedTextField.new` key open at six call sites. Measured on the client corpus 1d1ba147: the `withinBatch = true`
  every `addCloudAction3Validated` / `addCloudActionValidated` call passes is now read (`-1`, `PathIO.*`, `timestamp`
  typed), so the `batchLock` re-acquire under the batch lock is cut, and `RootCauseFold` turns two real-long B holds
  (`updateCloudActionsByDiskSystem`, `moveCloudFileBlocked`) into info: their only uncovered long call was that
  infeasible one — branch `feat/infra-N48`
- N48 — the operand binder types an untyped lambda by a callee declared ANYWHERE the index reads (`OperandCallees`):
  a bare call to a member of the file (as before), to a local function, to an inherited instance member; `recv.m(…)`
  off a value (instance) or a type name (static); `new T(…)` (the closure's constructor); a static extension whose first
  parameter is the receiver's own type. The parameter list is the index's (`MemberInfo.paramSkippableFrom` /
  `paramRest`, computed by `CallGraphNames.paramsBy`, which `paramsOf` now delegates to — `SymbolIndexMembers`'s own
  `paramTypeSourcesOf` deleted), read where the callee is written (`Located.host`: the declaring file and its type
  parameters, `DeclaredNullity.headTierIn`). Generic substitution is by NAME at the part the lambda takes
  (`Located.bindings`, read in `ExpectationHost.part`), never by rewriting the text: the receiver's annotation or the
  `new`'s written type arguments bind the declaring type's parameters only when that type declares the member itself;
  the method's own type parameters shadow them; a std `Iterable<A>` parameter of the method's own `A` binds `A` to the
  element of a std iterable handed to it (`RefShape.iterableElementTypeParams`: `Array`, `List`, `Iterable`, the value
  of a `Map` — 4.3.7 has no `iter` for a `haxe.ds.Vector`). Still unproven: a skippable parameter at or before the
  lambda's (4.3.7 types it against that one first), an overload, a macro, a `#if` twin, a type parameter nothing binds,
  an unannotated receiver, a supertype's parameters — branch `feat/infra-N48`
- N48 follow-up — `RootCauseFold` no longer lets a hold of the SAME lock in ANOTHER function cover a `Site` reason
  (reverses the same-lock / same-thread clause of `feat/ts-precision-3`, and with it `RootCauseFold.oneThread` and
  `ThreadStates.origins`, which existed only for it). A sink call is covered only by a hold that makes it its own work:
  around the covered hold in its function (`nests`) or on every way of it to the call (a callee holding a lock across
  it). Why: under the user's policy (any file / SQL / network I/O under a lock the main thread takes is long) each holder
  holding the lock across its OWN call to an I/O site is its own stall — narrowing one hold frees nothing of the other,
  the argument `ts-precision-3` already made for two threads holds on one thread too. Measured: on the client corpus 1d1ba147 the
  clause folded two truth real-long holds once N48 cut the infeasible `batchLock` re-acquire that had kept them warned
  (`moveCloudFileBlocked` across its own `getTimestamp` stat, `updateCloudActionsByDiskSystem` across its own
  `doesItemExist`), and on f81c2049 / bd943dac it folded the real-long `RemoteDiskSystemBase.setTimestamp` (R7 L1b's
  "different hold of the same root"); on main it decided no truth `dup-of` key for its own reason. Score 1d1ba147
  `all 161 152 102 9 15 4 22 0 0 0.67 102/102` (main `… 0.65 102/102`); the price is two `dup-of` keys warning
  (`DiskSystemBase.addCloudAction3Validated` — whose hold does span a stat, `addCloudAction2` takes its timestamp
  before its own locks — and `VolumeWatcher.setTimestamp`, enclosed by its caller's hold of another lock). The fold
  tests that modelled one hold's work as two peer holds now model it as two holds of one function (`nests`) or a callee
  hold on the way — branch `feat/infra-N48`
- N50 — the reach walk reads a library type by its CANONICAL PATH where its simple name is shared, and only COPIES of
  one path answer as one type. (1) An implicitly-called member's placeholder (`ReachGraph.idsOf`) records the canonical
  path (`TypeNameBinding.canonicalPath`) of each candidate type it stands for; reading the external node
  (`ReachGraph.loadHomes`, called by the one `MemberReach.libraryBodyOf` — `libraryBody` now delegates to it instead of
  repeating it) loads the one site of the simple name as before, and where several declarations share it, every
  declaration at each recorded path (`TypeNameBinding.declsAt`) with its supertypes — no namesake of another path. It
  loaded nothing there: `siteOf` answers null for a shared name, so `Host.toString` (std `sys/net/Host.hx` and
  `hxnodejs/src/sys/net/Host.hx`, which every hxcpp landing conversion of an untyped value admits) stayed Opaque. (2) A
  graph node of a name declared more than once is no `sharedName` when every declaration is a copy of ONE canonical path
  and the node folds a declaration of every copy's file, an extern copy also running nothing of the program
  (`ReachGraph.oneTypeEverywhere`, `LibraryCalls.externQuiet`): a build compiles one copy (the class path the compiler searches
  first — probed on 4.3.7: of two `-cp` holding `sys/net/Host.hx`, the one given LAST), and the union of the copies' bodies answers for whichever it is. A positive list: two
  paths sharing a name stay shared (their members fold by simple name, and a type inheriting the member is not in the
  node), a copy whose member the node holds no declaration of stays shared. Rejected for now: keying the graph's nodes by
  canonical path — `CallGraph`, `CallGraphTypes` and the facts layer key by simple name throughout (`CallGraphImports`
  keys a library type apart only beside a PROJECT namesake), so two-package namesakes (client `Grid`, openfl/lime
  `Rectangle`) still answer shared; and loading by path rather than by name changes no answer today (a name of two paths
  stays shared either way) — it keeps the walk from reading, and budgeting, another type's files. (3) What the walk cannot
  read is named: `MemberReach.reachedArrayChange` answers the `ReachUnknown` itself, an Opaque library node or a node the
  graph lacks as `AliasedUnread(file, shared, member)` ("library code `Rectangle.new` the walk cannot read") and the
  visit budget as `Budget`, where all three read "code at library code the run did not read". anyparse src
  prefer-keyvalue-loop: 39 such refusals -> 0 with and without the oracle, all 39 still declined by the next culprit the
  walk now reaches (std `haxe/Exception.hx`, project `toString`s) — branch `feat/infra-N50`

## N56 (2026-10-19): one typing service, its cache keyed by declaration, a conformance harness

- the typing layers hung off `SymbolIndex` side by side (`members`, `structural`) or stood alone (`NominalTypes.typeWalk`,
  a fresh `ExpectedTypes` per binder), so nothing owned "a typing question" and no answer was ever kept → ONE
  `TypingService` per index (`index.typing`): the signature layers (`MemberLookup`, `StructuralTypes`) built by it, the
  body walk (`typeWalk`, `TypingHost`) and the expectation ladder (`expectations`) on it, and a `QueryCache` of answers
  keyed by `DeclarationKey` (file + declaration offset, + member name). Moved as a pure move: all-rules byte-identical on
  the four trees — branch `feat/infra-N56`
- caching a closure walk keyed by the `seen` identity (`TypeRefIndex.seenKey`, file + NAME) was the obvious key and is
  not a declaration key: two types of one name in one file would share it. The index folds the branches of an `#if` into
  one declaration (`withAlternate`), so file + offset is the key that names exactly one declaration in every
  configuration. Only a walk's FRESH root is cached — a walk entered with a caller's `seen` answers relative to that
  caller, and a name-keyed question (`memberGetter`) unions every declaration of the name — branch `feat/infra-N56`
- the conformance harness types the upstream Haxe 4.3.7 display and misc suites from a pinned clone, never from a copy
  (the compiler is GPL, anyparse MIT), and a project's compiler facts. A first run read 46 DIFFERENT answers that were
  the harness's own: a display position on a seam (`main(1|)` is the call's, not the literal's), a cursor on a
  construction's type name (the display answers the constructor), the `... ` lines of an error chain, a macro's own
  `Context.warning` read as a `$type`, the compiler's `AbGeneric.T` for a type parameter, and a definition or use whose
  binding the reference walk does not resolve by scope (a member reached bare, a type name) — each is now a refusal the
  harness counts UNSCORED, never a match — branch `feat/infra-N56`

## N52b (2026-10-19): an `#if` branch literal's break is named; the measure follows the layout it committed

- An object literal that a branch of an expression-scope `#if` holds on the keyword's line breaks GLUED, by its own width
  decision (`WrapBoundary(IfFirstLineExceeds(..))` / `GroupWithRestProbe(IfBreak(..))`). A list around the `#if` (a
  comprehension's brackets, a call's arguments) used to lay itself out from the flat item, and the next write, reading the
  broken literal back as a source-multi-line one (`BodyGroup`), laid the list out by the multi-line-item rules: one write
  late, on main too (`x_condcomp` 626 drifting files of the 91,000-file harness, plus calls, nested calls, chains,
  lambdas, parens and `#elseif` bodies: ~5,800 more in its `in6` templates).
- DESIGN: a new Doc ctor, `BreakMark(inner, token)`, not a token field on the width decision. It sits on the decision's
  BREAK side, renders `inner` and nothing else, every walker reads it transparent (each switch got the arm its
  `ConditionalMarkerDecrease` / `CollapseProbe` siblings have — 40 switches, the exhaustive ones found by the compiler);
  the measure render records it when it renders it, i.e. when the decision takes its break side. A token field on
  `IfFirstLineExceeds` / `IfBreak` would have been silent at every rebuild site that does not copy it (`D.mapChildren`,
  `WrapList.groupifyShared`, the collapse rewrite), and would need a second field for the `IfBreak` shape; the ctor is
  rebuilt keeping its token in both rebuild walkers, which `testARebuiltMarkKeepsItsToken` / arm
  `M-BREAKMARK-REBUILD-FRESH-TOKEN` pin. `LeadingBreak` was not reused: it renders a hardline.
- `BreakCommits.named(body)` wraps the decision ITSELF in `BreakCommit(committed(brk, BodyGroup(brk)), decision-with-mark,
  token)`: the read-back form the next write builds, behind the same token. Every list around it already offers one
  alternative per nested token (`WrapList.emit` + `outermostPerToken`), so no list code changed, and a host that is not a
  list (an assignment) just gets the read-back literal when it breaks. The recogniser is positive twice over: the site is
  `WriterPolicyLowering.nestBodyOnSourceNewlineWrap`, whose only consumers are the three expression-scope `#if` body
  fields (`HxConditionalExpr.expr` / `elseExpr`, `HxElseifExpr.expr`), and only its SAME-line arm; the Doc shapes are the
  two `BodyAllman` already rewrote (`decisionMapped`, now shared by both — the walker moved out of `BodyAllman`).
- NOT under `sameLine.conditionalExprFit`: there the region is its own fit group whose directive seams also break, and the
  next write reads those seams back as source newlines, so the literal alone is not what it reads. Naming it there changed
  21 files main settles in one write (client config, k 80-100); arm `M-BREAKMARK-FIT-NAMED` pins the exclusion. The fit-mode
  residue (client: `z_condchain` 78, `z_condcall2` 74, `z_condelseif` 4) stays open.
- `BreakCommits.resolve` measures again: the layout one round committed can move a break the round before saw at another
  column (a call around a comprehension opens, pushing the second literal past the limit), so the committed layout is
  rendered again and, while a round takes a new break, resolved again from the original Doc with every break taken so
  far (at most `MEASURE_ROUNDS` = 4; a break taken once stays taken, which is what makes it terminate). A Doc where no
  break is taken costs the same one measure render as before; one where a break is taken costs one more. Arm
  `M-BREAKMARK-ONE-ROUND`.
- The layout a list is offered for an Allman body break (`BodyAllman.tailBreak`) kept the glued placement's
  `OptSpace(' ')` in front of the body; the hardline the Allman side opens with drops it at render, so the output never has
  it, but a first line measured on that layout (the cuddled `[for (…)` head) counted it: at exactly the limit the first
  write opened the bracket and the next, reading the Allman body back with no space before it, cuddled it (`u_fieldhead`
  k=87, `w_innercomp` k=96/101, `u_longiter` k=37/62: 17 files, the pending-space skew of the N52 brief). The read-back
  layout drops the space when the body is WHOLLY the decision (`decisionMapped` reads it); a body that only ENDS in one
  (a nested `for`, whose own space precedes a keyword, not a break) keeps it — dropping it there glued `)for` in 680
  files main settles in one write. Arms `M-ALLMAN-GLUED-SPACE-KEPT` / `-UNGUARDED`.
- A list a source trailing separator forces into the break-mode cascade (`forceExceeds`: `<field>TrailPresent` and the
  per-construct trailing-comma knob) went flat with no probe when a `noWrap` rule shadowing a break default answered the
  forced cascade (`objectLiteral` `totalItemLength <= 140 -> noWrap` over `defaultWrap: onePerLine`). The unforced path
  probes that flat layout's first line (`emitZeroThresholdAgree`), so the first write broke the literal and added its
  comma, and the next write, forced by that comma, flattened it past the limit: main's fixed point overflowed (`t_filter`
  under `trailingCommas.objectLiteralDefault: yes`, 142-162 columns at 140, 21 files; one more drifted). The forced path
  now takes the same probe when it answers `NoWrap` with no threshold rule and no hardline; the 21 fixed points main
  rewrote past the limit land within it (78-98). Arm `M-FORCED-NOWRAP-UNPROBED`.

## FU3 (2026-10-19): a dropped separator's comment is rehomed; a fit region is named; lineLength rules are width decisions

- **A comment after a separator the writer drops is written where the next parse reads it.** `[a, {b: 1}, // c]` keeps
  `// c` on the element (the parser reads the `,` first); under `wrapping.trailingComma: remove` the next parse meets
  `{b: 1} // c`, and the close capture of the element's last construct takes the comment, inside the element, where it
  forces breaks (a comprehension cuddles, a ternary or binop explodes). `TriviaTailRehome` generates, beside the
  `Converters` of each synth module, `TailComments.rehome_<T>(value, comment): Null<T>`: the tree the parser builds for
  `<value> <comment>`, read off the SAME shape the parser is lowered from — the capture points are a close-peek trivia Star
  branch and a postfix call (`closeTrailing`) and a struct trivia Star field with a `@:trail` (`<field>TrailingClose`); the
  answer passes through an infix right operand, a ternary's else operand, a prefix operand, the one operand of a keyword
  or lead ctor, and a struct's last PRESENT field. A positive whitelist: a meta the mirror does not know, a trail literal,
  a `@:wrap` pair, a `;` the source wrote (`<field>TrailPresent`), an occupied slot, a block comment — all answer null and
  the comment stays where it was. The paired ctor's argument positions are read off `TriviaPairAltCtor.buildEnumCtor`,
  not recounted. The sep-Star writer (`TriviaSepLowering`, both call sites) lays the list out from
  `DroppedSepComment.last(source, appendTrailingComma, rehome_<Elem>)`. The rehomed list keeps reading the source
  `trailPresent`: a separator is only dropped under the `Remove` veto, and every layout that reads source presence is
  vetoed with it (the arm cutting a separate read SURVIVED, so the read was dead and is gone).
- **A `conditionalExprFit` region is a named break.** The region is one `GroupWithRestProbe` whose seams break together;
  the next write reads the seams it printed as hardlines. `BreakCommits.namedRegion` keeps the group (an empty
  `IfBreak(BreakMark, Empty)` probe carries the mark, so every walker measures the group as before) and wraps it in a
  `BreakCommit` whose committed read-back has the seams as hardlines (`hardSeams` walks only `Concat`/`Nest`; every
  other node decides its own lines or renders the same in the broken group). A list (call arguments filling a line) then
  lays itself out as the next write does.
- **A list does not lay itself out for a break inside a fit body** (`BreakCommits.nested(item, false)` stops at
  `BodyGroup` for `WrapList.emit`'s offers). The next write re-decides the body's own seam from the body it reads back
  (`strictFitLineShape`: a multi-line comprehension body goes to the next line, with no `BodyGroup`), which the committed
  break alone does not say: offering through the body changed 156 main-stable fixed points (`z_condlambda`,
  `z_condparen` under client — an arrow or a paren around the comprehension measured the deferred `BodyGroup`). Rejected:
  `BreakCommits.follow` at the body (a `BreakCommit` around the slot) — every reader of the slot shape
  (`dropComprehensionBody`, `tailBodyGroup`, …) stops recognising it, 161 changed fixed points; measuring
  `BreakCommits` on the collapsed layout — no effect on any file, dropped.
- **The `#elseif` seams of a fit region carry no force-flat boundary of their own** (`TryparseStarCtx.regionSeams`): a
  `WrapBoundary` among one group's seams gave the region two modes inside an enclosing `Flatten`.
- **A `lineLength >= n` rule's decision is a width decision.** It is emitted as `Group(IfWidthExceeds(n, brk, flat))`;
  `decisionMapped` reads it beside `IfFirstLineExceeds` and `GroupWithRestProbe(IfBreak)`, and `BodyAllman.tailBreak`
  recognises its Allman break side. This was the whole `thr` harness family (5022 drifting files). 191 files main
  drifted on settle on another fixed point than main's second write: an outer `noWrap` literal keeps its fields glued
  around the Allman comprehension, where main's second write had broken it because the first had printed it multi-line.

## FU4 (2026-10-19): typer step T2 — the ancestor table, the unification of plain types, a member's READ type

- every closure walk of `MemberLookup` resolved each `supertypesRaw` link again (`resolveTypeRef(raw, cur.file, …)`), and
  three other places spelled "what a supertype chain passes to an ancestor's parameter" by SIMPLE name
  (`SubtypeGraph.chainArguments`, `CallGraphGenerics`) or not at all (`MemberPathWalk.substitutedMemberSource`
  substituted a DIRECTLY declared member only) → ONE `AncestorTable` on the typing service: each declaration's links
  resolved once with the arguments they pass, its alias target, and `argumentsTo(start, host)` — `tUnification.ml`'s
  `loop cs (List.map (apply_params c.cl_params tl) tls)` by DECLARATION, the first link reaching the ancestor in written
  order. The walks read it (a pure move); `substitutedMemberSource` is deleted, its job is `MemberLookup.memberReadType`.
  The call graph's simple-name chain stays: it keys types its own way and may run with no index — branch `feat/fu-FU4`
- the type a READ of a member carries is not its written type: 4.3.7 types `Base<T>.item` read off a `Sub extends
  Base<Int>` as `Int`, a structure's `?a: T` / `var ?b: T` / `@:optional var c: T` as `Null<T>` (an interface's
  `@:optional var e: Int` stays `Int`), and a parameter `?x: T` as `Null<T>` with or without a default (`x: T = v` stays
  `T`; `?x: Null<T>` is not wrapped twice) — verified with `$type` on `--interp` and `-js`. The facts harness read 4901
  (anyparse) / 996 (client) nominal answers that left the wrapper out and 232 client answers naming an ancestor's parameter →
  `memberReadType` binds the declaring type's parameters through the chain and wraps an optional structure field
  (`MemberInfo.optional`, recorded by the index); the index host wraps an optional parameter
  (`RefShape.optionalValueTypeName` / `optionalFieldMetaName`). Every consumer reads the wrapper exactly as it reads one
  written by hand — branch `feat/fu-FU4`
- "the compiler's answer or Unknown": a call whose declaration returns a type parameter of the method or of its type now
  has no nominal (`returnNominalWalk`), where it answered the parameter's NAME (`Std.downcast` → `S`); a written type that
  is no one type (`#if lime Image #else Dynamic #end`, a macro splice) is no answer (`NominalTypes.answerableType`).
  Inferring what a call binds its method's parameters to is overload / argument typing, step T5 — branch `feat/fu-FU4`
- `Unification` memoizes `unify` over PLAIN types only (a class, an interface or an enum with no type parameter, through
  plain aliases, not under `#if`), keyed by the pair: itself `Fits`, an ancestor its chain reaches `Fits`, an enum against
  anything else `Misfits`, a class or interface whose whole chain resolves without reaching the other `Misfits`, all else
  `MayFit` (abstract casts are step T4). Consumers: `ArgumentTypes.fit` (two plain types were always `MayFit`, so an
  argument of an unrelated class still bound an optional parameter the compiler skips) and
  `StructuralTypes.memberCouldUnify`, which compared nominals by SIMPLE name and invariantly for every member: a
  read-only structure member (`final`, a method) unifies covariantly in the compiler (`{final x:Base}` accepts `var
  x:Sub`), and two namesakes of two packages are two types — branch `feat/fu-FU4`

## FU11 (2026-10-19): a statement list is a barrier for the call-argument chain flag

- A leading-break call stamps `_callArgChainNest` on each argument's opt so a chain that IS the argument drops its own
  continuation Nest (the argument Nest already supplies `+1`). The flag was consumed only at a chain or a ternary, so an
  argument that is a lambda / anonymous `function` / arrow-body `switch` carried it into its BODY, and the first chain of
  the body (`return a && b`, `final v = a && b`, `x = a + b`) honoured it: the operator wrapped at the statement's own
  indent instead of one level deeper. Every engine since 2026-10-15 did it, and `fmt --list` called it canonical. The
  haxe-formatter fork gives `+1` there, as hxq does in a plain function body.
- Fix in the one place statements are written: both statement-list Stars (`TriviaBlockLowering.triviaBlockElemCallExpr` —
  `BlockExpr` / `BlockStmt` / `HxFnBlock.stmts` — and `TriviaTryparseLowering.triviaTryparseElemCallExprs` — case /
  default bodies) write every element, tail included, through `WriterOptFanout.statementListElemOpt`, which clears the
  flag. A statement is never itself a call argument, so the flag is stale there by construction.
- NOT changed, by fork parity: an object-literal field value and an arrow EXPRESSION body inside a call argument are not
  statements and keep the call-argument base (the fork wraps both at that column). Pinned by
  `HxCallArgLambdaBodyChainIndentTest`'s two non-discriminating pins.
- client: 3 files / 4 hunks, each this defect (`ItemListProjectsShare.hx:171`, `BucketMutationOffMainTest.hx:109/153`,
  `ItemListThumbnailTest.hx:106`). Arm `M-STMT-LIST-CALLARG-BARRIER`.

## FU14 (2026-10-19): typer step T3 — which static extension `recv.name` binds, in the compiler's `using` order

- three consumers each walked the file's `using`s on their own terms (`OperandBinder.extensionTier` and
  `OperandCallees.extensionParams` through `ValueNameBinding.extensionDeclaration`, `NominalTypes.staticExtensionNominal`
  through `ChainTypeContext.usings`), and every one refused a receiver whose type or a supertype carries `@:using`, stopped
  at the first `using` declaring the name whatever its first parameter, and refused two types of one used module
  declaring it → ONE body question on the typing service, `StaticExtensions.binding(file, receiver declaration, name)`,
  keyed `DeclarationKey.ofUse`, answered in `fields.ml`'s order (Haxe 4.3.7, every step compiled on `--interp` and `-js`,
  FU14 probes): the receiver's field; its type's `mt_using` — the own `@:using` arguments LAST FIRST (`@:using(E1, E2)`
  binds `E2`, two annotations the later), then the superclass's whole list, then each interface's (even when
  `implements` is written before `extends`), a typedef's own before the aliased type's; then the file's `using`s LAST
  FIRST; then each `import.hx`, the nearest first, its last `using` first. Inside one used module: the types in
  REVERSE declaration order (`filter_classes` prepends), a `typedef` alias of a class bringing that class, an anonymous
  structure nothing, module-level functions after every type. `@:using` paths are absolute (`@:using(Ext)` in package
  `pk` is `Type not found`) — branch `feat/fu-FU14`
- a candidate whose first parameter REJECTS the receiver is passed over, across every boundary (the next type, the next
  `using`, the type's `@:using` into the file's): probed with `A.r(s:String)` / `B.r(i:Int)`, `using A; using B;` →
  `A.r`. So `StructuralTypes.receiverFitsParameter` answers `Fits` / `Misfits` / `MayFit` over `Unification.unifies`
  (by declaration) instead of a simple-name `SubtypeGraph.isSubtype`, and only `MayFit` ends the walk. Probed answers:
  `Null<String>` accepts a `String`; bare `Dynamic` and `<T>(t:T)` accept anything, `<T:Int>(t:T)` rejects a `String`
  (constraints are not indexed, so a method type parameter is `MayFit`); `Any` accepts (an abstract: T4) — branch
  `feat/fu-FU14`
- `Unification` gains two arms the walk needs, both `tUnification.ml`: `a == b` first — one declaration with no type
  parameter is itself whatever its kind or `#if` (an anonymous structure `ItemListShareUsers` received by
  `LinkUtils.count(users:ItemListShareUsers)`, an `#if`-folded openfl `BitmapData`: 29 client answers would otherwise have
  turned Unknown), and a GIVEN type with type parameters against a PLAIN wanted one is decided by its chain alone
  (`TInst (c1, tl1)` vs `TInst (c2, [])` compares no argument) — branch `feat/fu-FU14`
- NOT proven, by the positive whitelist: a private static (`can_access`: reached from its class and subclasses only,
  probed — the same file's other class does not reach it; the key is the file, not the class), a default-visibility
  static of a non-extern type (`@:publicFields` is not indexed), a module-level function of a used module (no signature
  in the index), an `@:overload` / macro / non-function static, a candidate type built by a macro or under `#if`, a
  guarded `using` that may supply the name, a module the index holds in several files one of which supplies it (the
  class path decides; when NO file supplies it the walk passes on — the client's `using StringTools` with a std and a `_std`
  copy), a supertype only one `#if` branch of the receiver writes that brings a candidate, an unbounded ambient chain,
  and no binding at all (the global `haxe.EnumTools` / `EnumValueTools` come last and are not modelled). The old walk
  BOUND a private static (wrong outside its class) and passed over a module-level function (wrong: it binds) — branch
  `feat/fu-FU14`
- the using walk moved, it was not copied: `ValueNameBinding.usingTypes` / `usingHosts` / `usingDeclarations` /
  `extensionDeclaration` / `bindingUsing` / `extendsAs` → `StaticExtensions` (`usingTypes`, `usingHosts`, `maySupply`,
  `bindingUsing`), `ValueNameBinding.builtAtOrAbove` → `AncestorTable.builtAtOrAbove` (over the resolved links),
  `UsingScan.extensionUsings` and `ChainTypeContext.usings` deleted (their `#if`-guarded-`using` refusal is the walk's
  own, per statement), `StructuralTypes.extensionReturnNominal` deleted. `StaticExtensions` joins the owners of
  `ImportInfo` / `ImportKind` in `apqlint.json` (`owned-types`): it is the name-resolution layer for `recv.name`, and
  took the reads over from `ValueNameBinding`. Not moved: `PreferStaticExtension`'s `UsingScan.usingConflict`, which
  asks about a `using` the rewrite would INSERT — a hypothetical file this question does not model — branch `feat/fu-FU14`

## FU6 (2026-10-19): `prefer-if-expression-return` owns a return run of three values, rewrites it only when it merges

- The N55 self-fix turned `if (member == null) return null; return (isGet ? …) ? property : null;` into a six-line
  `return if … null else if … property else null;`: a guard return plus a final ternary was counted as three values and
  rewritten as a value chain, `null` spelled twice. Four more sites took the same road (`ArgumentTypes.fit`,
  `EdgeConditions.factsOf`, `OperandCallees.callParams`, `MoveToHelperRefs`). A value chain of three or more branches reads
  worse than the statements (the formatter's own `expressionIfFitMaxBranches: 2` keeps one exploded), so:
- OWNERSHIP is unchanged: three or more values are this rule's in either spelling (`claimsCascade` answers as before).
  It has to stay: without it `prefer-ternary-return` marches the cascade pairwise into the three-leaf ternary that
  `prefer-if-expression-chain` then turns into the very chain refused here.
- The REWRITE is narrower. (b) A run whose three values carry TWO merges into one ternary, in either spelling:
  `v1 == v2` → `c1 || c2 ? v1 : v3`, `v1 == v3` → `!c1 && c2 ? v2 : v1` (`NegationScan` negates, `ParenGuard` adds the
  pairs). Both keep every evaluation exactly where the statements had it — `c2` runs only when `c1` is false — so no
  purity proof is needed; `v2 == v3` would drop `c2`'s evaluation and is refused. The repeated value is on a POSITIVE
  list (a non-boolean case literal or a bare name): equal text is one value between sibling statements, but not one type
  — each branch is typed under its own condition's narrowing — and a literal or a name is what does not depend on it.
  Any comment in the region refuses the merge. (a) Otherwise a chain is written only where the author WROTE at least
  two conditions as an else-linked chain; a folded ternary's conditions do not count, a cascade never becomes one, and an
  owned run left alone is not reported (its statements are the canon). `claimsChain` now means "rewrites", so a
  two-branch chain with a ternary tail keeps `redundant-else-after-return`'s de-nest.
- Why both: (a) alone would leave `accessedProperty` as its two statements when one line says it better; (b) alone
  would still chain every non-merging guard cascade. A merge is limited to three values: a longer guard ladder that
  repeats a value (`if (a) return null; if (b) return null; if (c) return null; return x;`) reads as the ladder it is,
  and is left to it.
- anyparse src: the five N55 chains restored to statements (`ArgumentTypes.fit` reworded so the two null tests are not
  repeated); the rule's own `--fix` then writes `return member != null && (isGet ? member.hasGetter : member.hasSetter)
  ? property : null;` and changes nothing else — branch `feat/fu-FU6`

## FU5 (2026-10-19): an import argument may be the whole statement; `mentions` answers a dotted import

- client gap (a): an agent concluded `add-import` "cannot add a `using`" and patched `using Lambda;` in by hand. The flag
  `--using` existed; what did not was the spelling every caller reaches for — `add-import <file> 'using Lambda;'` was
  wrapped into `import using Lambda;;` and refused as `result does not parse: error at 5:14`, a column of a source the
  caller never wrote. `new`'s `@@ imports` had learnt both spellings in `e8ec6cc1` with its own reader; that reader MOVED
  to `query.ImportSpelling` (`split` + `isModulePath`, the copy in `NewFile` deleted) and now serves `add-import`,
  `remove-import` and `new` alike. A statement's keyword picks the kind; an `import …` statement under `--using` is
  refused by name; a bare path keeps its old meaning. `isModulePath` (a POSITIVE whitelist) also accepts the legacy
  alias spelling ` in <Alias>`, which `add-import` could always splice. `add-import` now refuses text that is neither a
  module path nor a statement BY NAME instead of as a parse error.
- `remove-import` takes the same statement spelling, and its keyword narrows the match: `using a.B;` names the `using`
  alone where a bare `a.B` beside `import a.B;` stays ambiguous. `--using` is the CLI's flag spelling of the same request
  (folded into the statement form, so the library entry point carries no second parameter). Its private copy of the
  import kinds is gone; it reads `ModuleScan.IMPORT_DECL_KINDS`.
- Placement of a `using`: Haxe ranks static extensions in REVERSE declaration order (verified, Haxe 4.3.7 `--interp`:
  `using A; using B;` resolves `x.who()` to B). `UsingScan.usingInsertEdit` — the seat every `using`-inserting rule takes —
  puts a fresh one ABOVE the header's first `using`, the lowest priority, so no call the file already makes moves.
  `add-import` used `ImportOrder`'s import ladder ("after the last plain import, else after the last import / using"),
  which agrees only when plain imports precede the usings: for a using-only header it appended BELOW the group (top
  priority). `add-import --using` now calls `UsingScan.usingInsertEdit` (guarded-body header included) — one answer for
  the op and the rules; `ImportOrder`'s doc, which claimed every caller APPENDS a `using`, is corrected.
  `HoistCommonImport` inserts several usings through the op, so it now inserts them last-first to keep their source
  order (= their priority) in the ambient source.
- Dedupe is unchanged in kind and reach: same-kind, top level and inside `#if` regions, whichever spelling was passed.
- client gap (b): `mentions Assets` answered the uses and NOT `import openfl.Assets;` — the import payload is ONE leaf, and the
  lit section compared names exactly. The last-segment test `uses` reads for a qualified type reference since `84b5aceaa`
  is now ONE shared predicate, `SourceText.answersSimpleName` (`Uses.matches` calls it), and `Lit.find` takes opt-in
  `qualifiedKinds` it applies under an exact match; `mentions` passes `ModuleScan.IMPORT_DECL_KINDS`, so a simple name
  also answers an import / using whose last segment it is, printing the node's own (full) path. A dotted query stays an
  exact compare (a last segment carries no dot, so the old explicit `indexOf('.')` guard was redundant and went).
  `lit` passes no kinds and is unchanged; `refs` has no import part; `rename` reads neither (its dotted-path arithmetic
  stays `CrossRename`'s).
- Arms: M-ADDIMPORT-STATEMENT-KEYWORD-IGNORED, M-ADDIMPORT-USING-TAKES-IMPORT-SEAT, M-ADDIMPORT-PATH-UNCHECKED,
  M-IMPORTSPELLING-FLAG-CONFLICT-UNCHECKED, M-REMOVEIMPORT-KEYWORD-IGNORED, M-REMOVEIMPORT-CLI-USING-FLAG-DROPPED,
  M-MENTIONS-IMPORT-KINDS-UNPASSED, M-LIT-QUALIFIED-KINDS-IGNORED, M-HOIST-USINGS-SOURCE-ORDER; re-aimed onto the moved
  code: M-NEWFILE-IMPORT-DOUBLED / -BARE-KEYWORD-WRAPPED (`ImportSpelling.split`), M-NEWFILE-IMPORT-ANY-LINE,
  M-USES-EXACT-ONLY, M-USES-TAIL-SUBSTRING (`SourceText.answersSimpleName`).

## FU12 (2026-10-19): an overflowing trailing comment moves above its element; comment-width declines code shapes

User report: client lines over `maxLineLength` the writer leaves alone. Census (client working tree, tab 4): 4 lines whose CODE
fits and a trailing `//` overflows (`ItemListModelsShare.hx:88/129`, `ExportPDFBuilder.hx:106`, `API.hx:362`), 24
over-wide COMMENT lines, 41 single long literals (unbreakable, left).

- (a) Writer knob `comments.trailingCommentOverflow: "keep" | "above"` (`opt.trailingCommentAbove`, default `"keep"`,
  so every other project is byte-unmoved). `"above"` moves a same-line `//` comment onto its own line above the
  statement or member it trails, at that element's indent, ONLY when the element alone renders as one line that fits
  and the comment is what carries it past the width. New Doc ctor `IfTrailingCommentOverflows(n, trailWidth, code,
  breakDoc, flatDoc)`: the render arm measures `code` with the natural first-line walk (`Renderer.naturalFirstLine`,
  now answering whether it stopped at a break — `naturalSingleLineEnd`), every static walker reads `flatDoc` (the
  pre-knob emit), so the knob changes nothing but the choice.
- Positive list, each a reason the second pass is provably the same layout: a block Star that opts in
  (`@:fmt(relocateTrailingComments)`: `HxFnBlock.stmts`, `BlockStmt`, `BlockExpr`, class / interface / abstract /
  macro-class members — every element starts on its own line, so the moved comment sits at the element's indent); a
  `//` comment that is not a directive (`CommentDirective.relocatableTrailing`); an element with NO leading comment
  (the moved one then reads back as the whole leading list, so the doc-led blank rules, the `//`-before-`/**` split
  blank, the line-comment run adapter and the blank-after-leading-comments flag answer as they did). Left alone, by
  the list: comments inside expressions (object fields, call arguments, operator chains — `ExportPDFBuilder.hx:106`,
  `API.hx:362`), case bodies (the first statement can share the label's line), block comments.
- The `uniformStatementBlanks: collapse` pre-pass needs NO gate although it refuses a list whose later element has a
  leading comment: a collapsing list loses every blank, and a blank-free list does not collapse on the second pass
  either. A first version gated the move on the collapse; the SECOND pass then moved the comment (fmt needed two
  rewrites). Pinned by `testUniformCollapseAndTheMoveLandInOnePass`.
- Fork comparison (haxe-formatter `feature/condition-wrapping`, measured): the fork counts a trailing comment into
  `TokenList.calcLineLength` and WRAPS THE CODE to make room (`x =` + newline + value, a call broken one argument per
  line), never moves a comment and never reflows one. Parity is unchanged under the default; `"above"` is an hxq-only
  layout choice: the code is what the reader reads, a comment's width should not lay it out. Not a parity defect (see
  the writer-vs-formatter note: a difference under an unset knob is a config question).
- (b) `comment-width` already had a `--fix` (`SourceComments.wrapCommentBody`, balanced fill). client run found two
  corruptions it made: a tab-aligned `@param` row lost its columns (`CrashReport.hx:85`) and commented-out XML attributes
  were broken at spaces (`StageArea.hx:157`). `reflowRefusal` now also declines a TAB-ALIGNED row and a line that does
  not read as prose — by `CommentProse.readsAsProse`, the positive criterion `prefer-doc-comment` already used (made
  public; asked with a leading `@tag` set aside, the tag's `@` being what it reads as code) rather than a second,
  negative code-shape list. `fillText` never breaks inside a backtick span.
- Consolidation: the directive list existed three times (`CommentProse.DIRECTIVE_MARKERS`, the `noqa`/`checkstyle:`
  test in `reflowRefusal`, and the new writer gate); it is ONE now, `anyparse.format.comment.CommentDirective`
  (`noqa`, `checkstyle:`, `@formatter:`, `#region`, `#endregion`, case-insensitive prefix — the safe direction for
  every consumer, each of which may only decline). `SourceComments.isNoqaComment` stays separate: it answers what the
  LINTER reads (`noqa` exactly or `noqa:`), a different question.
- client: `comments.trailingCommentOverflow: "above"` in `hxformat.json`, `"comment-width": {"enabled": true}` in
  `apqlint.json` (proposed; client config not changed here).
- Arms: M-TCO-KNOB-IGNORED, M-TCO-LEADING-IGNORED, M-TCO-DIRECTIVE-MOVED, M-TCO-OVERWIDE-CODE-MOVED, M-TCO-BOUNDARY,
  M-TCO-MULTILINE-MOVED, M-COMMENT-REFLOW-TAB-ROW, M-COMMENT-REFLOW-CODE-SHAPED, M-COMMENT-REFLOW-SPLITS-CODE-SPAN,
  M-COMMENT-DIRECTIVE-NONE.

## FU16 (2026-10-19) — `remove-element --select 'Literal:x'` removes the item, or refuses

- Defect: a `Literal` node's span is the content between a string's quotes, so `--select 'FinalMember:ARMS >> Literal:B'`
  resolved the cursor INSIDE the string, `elementAtFrom` picked the `Literal` itself and the cut left `''` at rc 0, while the
  position form (on the quote) removed the `SingleStringExpr` item.
- Decision: `ElementSpan.liftedElement` (shared by `remove-element` and `add-element`) lifts a `Literal` whose parent is the
  single-child quoted expression carrying its quotes to that parent (`literalWrapperOf`). `RemoveElement.strandedLiteral`
  then accepts the lift only when the parent is a `commaContainerKinds` container (the item IS the element) and refuses
  otherwise (positive whitelist: no confident cut of a shape that has no element). Arms: M-LITERAL-WRAPPER-SKIPPED,
  M-LITERAL-STRANDED-ACCEPTED; M-LIFT-FINAL-WRAPPER-SKIPPED re-aimed onto the new line.

## FU7 (2026-10-19) — four default-off rules enabled for anyparse; two of them gain an autofix

- Enabled in `apqlint.json` (N57 verdicts): `default-repeated-argument`, `prefer-count` (risky: applied WITH the
  `test-js.hxml` oracle, 19 files verified, 0 reverted), `asymmetric-branch-braces`, `shadowing-parameter`. src+test are
  at the fixed point of all four. `hoist-common-import` and `duplicate-code-renamed` stay off. `tools/` is outside the
  lint scope (battery lints src+test) and keeps its one `prefer-count` site.
- `asymmetric-branch-braces` fix = the writer's repair direction under `singleStatementBraces: "symmetric"`, never the
  removal one, over the whole if/else-if CHAIN the flagged pair ends (the writer's `chainForcesBraces`): only a chain's
  tail pair can be a finding, and bracing it alone left chains braced in the tail and bare in the head. Gates read
  RefShape seams (positive whitelist): a branch ending in `statementTerminator`, or closing on a block / switch, or an
  if / loop / try / catch whose last child closes so; else one that ENDS in an unterminated expression statement takes
  the terminator inside the braces (Haxe accepts `if (a) p() else {..}` and rejects `{ p() }` with `Missing ;`,
  verified with `haxe --interp`; `{ p(); }` is the same statement). Declined: a bare declaration (braces scope it), a
  conditional-compilation region (its terminator belongs to the parent's span), an edit overlapping another of the
  same call (next pass), a rewrite that does not parse back as the same chain fully braced. This goes one step past the
  writer's gate 3 (which leaves an unterminated expression bare): the terminator is inserted, not invented, and the
  reparse proves the shape.
- `shadowing-parameter` fix = `shadowing-local`'s rename (`ShadowingLocal.fixWith`), scoped to the declaring function;
  its readAfter gate does not apply to a parameter (bound by the call, so no write meant for the hidden binding can land
  on it). A parameter with no written nominal type (untyped arrow parameter, `Null<Array<T>>`, a std root type) stays
  reported.
- Known detection gap, not changed: an else-if chain with no final `else` (`if (a) { x; } else if (b) y();`) is not a
  finding, although the writer's symmetric mode braces it.

## FU21 (2026-10-19) — `prefer-if-expression-return` merges the LAST three values of a longer fall-through run

- client `DiskSystemBase.localPathBeforeMove`: `if (ownMove != null) return ownMove.localFilePath; if (heldAt == null)
  return null; return exists(…) ? heldAt : null;` is a run of four values, so FU6's "exactly three" left it as written
  although its last three carry two. A run of four or more now merges its LAST three (`mergeOf`): the guards in front
  keep their statements, the merged return replaces the tail from the `if` that returns the first of the three, and the
  finding is reported on that `if` (where the edit starts; `fix` keys on the same statement). Here:
  `return heldAt != null && exists(…) ? heldAt : null;` after the first guard.
- Only the last three: the merged text ends at the terminal, so two rungs and the terminal are what the rebuild copies;
  any other window would drop a condition.
- Soundness is FU6's, unchanged and applied to the three: the `Leading` / `Outer` merges keep every condition's
  evaluation and order (`c2` still runs only when `c1` was false), so a condition with a side effect is no obstacle;
  the `v2 == v3` merge that would DROP a condition's evaluation stays refused; the repeated value is a non-boolean
  literal or a bare name; any comment in the replaced tail refuses it. A comment in FRONT of the tail is outside the
  edit and stays above the merged return.
- Fall-through spelling only, from a WRITTEN rung. An else-linked chain is one statement with no tail to cut out, and
  keeps its chain fix. A tail whose first value is folded out of the terminal ternary (`if (a) return 0; return b ? 1 :
  c ? 1 : 3;`) sits inside that ternary, and re-shaping a ternary is not a cascade merge; the run stays owned.
- FU6's ladder decision is KEPT: a tail whose preceding value repeats one of the tail's values is refused
  (`repeatsTail`). Merging it would leave a run of three the next pass merges again, so `if (a) return null; if (b)
  return null; if (c) return null; return x;` would end as one nested `return a || (b || c) ? null : x;` over the `--fix`
  passes. With the gate a run merges at most once, so no composition across passes builds a nested condition. The
  repeat is compared on BOTH tail values: the one the merge repeats and the other one (`if (a) return 5; if (b)
  return null; if (c) return 5; return null;` would merge its tail to `!b && c ? 5 : null` and then the run again).

## FU18 (2026-10-19): typer step T4 — the cast graph of abstracts, an argument's implicit cast

- every pair an abstract took part in was `MayFit` (`Unification`, `ArgumentTypes.fit`, a static extension's first
  parameter, a read-only structure member) → ONE cast graph on the typing service (`AbstractCasts`, table `castGraphs`
  by `ofType`) over the header clauses the index now records per `#if` branch (`TypeDeclInfo.castClauses`), walked by
  `Unification` for a unification (`tUnification.ml`: `unify_to` / `unify_from` / `unify_abstracts`) and by
  `Unification.casts` for an argument (`abstractCast.ml`, `do_check_cast`) — branch `feat/fu-FU18`
- probed on Haxe 4.3.7 (`--interp`, two also `-js`): a static extension's first parameter is UNIFIED, never cast
  (`unify_static_extension`): an abstract taking the receiver only through an `@:from` member passes it over, an
  `@:to String` member does not bind `s:String`, and `Any` (`from Dynamic`) takes an abstract and a `String`; an
  argument IS cast, and optional-argument skipping uses the cast (`f(?a:Float, ?b:String)` binds `b` for an abstract
  with `@:to String`); `UInt` binds `?a:Float` — branch `feat/fu-FU18`
- a header `from` clause is no cast path of its own: `String` → `A from B` with `B(String) from String` is an error
  (`find_from` answers a unification by `Not_found`, and `B`'s clause would be a second abstract cast), `@:transitive A`
  compiles. Past the members the compiler casts to the FIRST `from` clause unequal to the abstract and to no other
  (`loop2` returns that recursion's answer): `Ab from Bs from Dz` takes a `String` through `Bs.fromS`, not a `Bool`
  through `Dz.fromB`, and `Ad from Dz from Bs` takes neither — a `Bool` is a `TAbstract`, so the abstract/abstract arm
  applies, which tries the two abstracts' members only. Hence `CoreValueTypes.classNames` (`String` is the one core class)
  — branch `feat/fu-FU18`
- "matches or Unknown": no graph (both halves of a pair `MayFit`) for an abstract with type parameters (its clauses read
  without the arguments binding them), `@:multiType` (cast by type arguments), one the compiler unifies by hand
  (`RefShape.handUnifiedAbstractPaths`: `EnumValue` takes every enum by an arm, not a clause — answering `Misfits` there
  would be another answer), a header with a clause under `#if` or a branch that declares no abstract
  (`openfl.text.TextFormatAlign`: two abstracts and a typedef). A type several branches declare answers what every
  branch agrees on; a conversion member is `certain` only on a one-branch declaration and not under `#if` (the members
  are the branches' union, so a fit there may be another build's while a misfit is every build's); a build macro leaves a
  member misfit open. A cycle of transitive clauses is `MayFit` (the compiler's `rec_stack` answers false; the walk does
  not claim it) — branch `feat/fu-FU18`
- the index's clauses replace a re-parse: `TypedEventConstant.isStringAbstract` re-parsed the declaring file to find the
  `FromClause` / `ToClause` nodes "because no seam names them" → `castClauses` (every branch converting both ways);
  `findDecl`, `convertsWith` and the two literal kind constants deleted, `abstractToClauseKind` joins
  `abstractFromClauseKind` (whose doc claimed a `thread-safety` reader it never had) — branch `feat/fu-FU18`
- NOT reached, measured: the call graph's index (`ArgumentTypes`' `heldFile`) holds the project and the library bodies
  the graph reads, never the std, so a std abstract (`UInt`) never resolves there and the client's `UInt` arguments stay
  `MayFit`; the client's `RoundedTextField.new` / `Assets.getBitmapData` false positive needs that AND typing `UInt - UInt`
  through `UInt`'s `@:op` overloads (`SaveDialog`'s first argument) — branch `feat/fu-FU18`

## FU20 (2026-10-19) — an `&&` / `||` / `+` / `-` chain counts its whole physical line

- Defect (found by FU11): a chain whose flat body ended on the limit but whose physical line ran one or two columns over
  (the statement `;`, an enclosing `)`, the un-flushed space after `=`) stayed glued, and the line broke at the first
  inner group that did count the rest: before a nested `==` (`requestedAnchors.count()` / `== 0 && ...`), after
  `return`, or not at all for a `+` chain. The fork breaks at the chain operator in every such case.
- Mechanism: TWO plain `Group`s decided on `col + flatWidth` alone, the chain pivot (`emitNoThreshold`'s
  `Group(IfBreak)`, and the addSub tagged pivot) and the FillLine shape's own `Group(Nest(Fill))`, which re-decided flat
  inside an already-broken pivot. Both now build through `D.groupOrRestProbe` (moved from `WrapList`'s private copy, the
  one spelling of "Group or its rest-aware twin") when the chain is `restAware`: everywhere except a paren that owns the
  wrap (`_keepChainInParen`, as for the ternary). A string interpolation and a condition wrap need no gate of their own
  (measured: dropping the condition-wrap conjunct moved nothing in the suite, client or anyparse) - the first collapses the
  chain to a groupless NoWrap shape, the second breaks its `(` first.
- CollapsePass reads both pivot kinds through `chainGroup` (tagged addSub chain, its probed form, FillLine parts, the
  bool re-eval payload, the fill forward glue) and keeps the kind on every rebuild. The forward glue
  (`chainGluedIfOpens`) takes a rest-aware pivot only when its flat side is an infix chain (`gluesInfixChain`, a
  positive list of ` && ` / ` || ` / ` + ` / ` - `): a ternary shares the rest-aware pivot but was never a glue
  candidate, and admitting it rewrote two client files and three suite fixtures away from the fork.
- Unarmed, equivalent by construction: the rebuild kind of the bool re-eval flip and of the fill forward glue (the
  flipped chain overflows by its call operand, the glued chain has no soft line left, so either group answers the same).

## FU27 (2026-10-20) — a lone arrow-lambda argument whose expression body breaks: no writer change

- Question (client `DiskSystemBase.localPathBeforeMove`): `_moveLocalItems.exists(` + `move ->` on its own line + the
  broken `&&` body, while `_moveLocalItems.find(move ->` two lines above keeps the head glued. Measured against the
  haxe-formatter fork (`0e8b54f`, two passes) with the client's `hxformat.json` beside each file: NOT a parity defect.
- The split is the config's own: `callParameter` pins a lone argument with `noWrap` only while
  `itemCount <= 1 && totalItemLength <= 100`. The `find` lambda is 99 chars (glued head, body on the next line); the
  `exists` lambda is 141 (`fillLineWithLeadingBreak` breaks after `(`, the body breaks after `->`). Both writers draw
  the line at the same place (a 94-char and a 101-char twin: glued in both, split in both), and both put `move ->` on
  its own line in `return x.exists(...)` and in `final e = x.find(...)`. the client's "`itemCount >= 2` keeps a lone callback
  glued" is about the two `onePerLine` rules and a BLOCK body (`iter(move -> {`): glued in both writers.
- The client statement as is (inside `heldAt != null && … ? heldAt : null`) differs in the fork, which glues
  `exists(move -> move.folder` and sets the lambda's `&&` operands at the outer statement's continuation indent - the
  level of the outer `&&` operand and the `?`/`:` branches, so the inner chain reads as the outer one. Its own isolated
  `return x.exists(...)` lays the same lambda out like anyparse; that is a context artifact of its opBool re-evaluation
  passes, not a target.
- Open (not head glue, not changed): inside that broken lambda body the fork puts the first `&&` operand alone
  (`move.folder` / `&& heldAt.startsWith(…)` / …) where anyparse fills (`move.folder && heldAt.startsWith(…)`); the
  same chain outside a lambda fills identically in both. The fork's fill seam reads like a decision taken before the
  arrow break moved the body (evaluate-before / apply-after). Evidence:
  `/Users/axg/dev/lab/ts-truth/infra-audit/FU27-fork-vs-anyparse.log` — branch `feat/fu-FU27`

## FU19 (2026-10-20) — writer one-pass drift residue: a chain cuddles after a region break; a committed collapse is a `BodyGroup`

- **A method chain is a host of the breaks nested in its parts.** `methodChainCuddledLinks` decides each link's cuddle
  once, at build time, from the predecessor's Doc (`DocMeasure.endsWithForcedCloseLine`), where a
  `conditionalExprFit` region is an undecided group: pass 1 kept `.build()` on its own line, pass 2 read the region's
  newlines from the source and cuddled `]).build()`. `MethodChainEmit.emit` now offers the chain once more per break
  nested in the receiver or a segment whose committed form ends on a closing line where the plain one does not; the
  committed part's closing line is read with `resolveForcedBreaks` (a conditional whose flat side carries a forced
  hardline is read on its break side, as `breakTailCloseNest` already did — the next rewrite reads that newline from
  the source). The per-item offer loop `WrapList.emit` and `BreakCommits.followBare` each carried is ONE shared
  `BreakCommits.offerItemBreaks(items, plain, laidOut, ?wanted, throughBodies)`; the chain is its third host.
- **A source-flat list the one-per-line collapse commits at build time is a `BodyGroup`** (`TriviaSepLowering`, the
  non-reflow sep-Star cascade branch). ω-flat-source-fixed-point collapsed a breaking cascade answer to the lines the
  next pass writes, but not to its Doc: the next pass reads those newlines and takes the force-multi path, whose Doc is
  `WrapBoundary(BodyGroup(…))`, which every width probe defers. So a chain, an arrow or a fill around the literal
  measured it full-width once and deferred the next time ("mechanism B" of the convergence tail,
  `WrapFlatSourceFixedPointTest`). Only a result that carries a hardline (`flatLength < 0`) is wrapped; an answer the
  renderer still decides stays counted. This is the opposite direction to the rejected `flatTokenWidth` descending a
  `BodyGroup` (`f57325e5`): the first pass defers as the second does, so nothing that already settled moves — this
  tree, client (903 files) and Pony (872) format byte-identically. Mechanism B's three pinned cases now converge in one
  write and the stacked three-rewrite file needs two (the mechanism-A link alone).
- Tried and dropped: naming a `conditionalExprFit` region's body literal (`BreakCommits.named` with a bare read-back)
  closed the minimal-config tail but gave client `z_condparen` 29 new drifts (a binop fill read the committed literal
  differently from the source-broken one); offers that commit two nested breaks together, `BinaryChainEmit` as a host,
  and a cascade-width gate on the chain offer changed nothing in the harness.
- Open, root causes measured: `z_condparen` pony/tc k 34-38 — the `#else` literal inside the comprehension's fit body
  breaks by width and the `+` chain around it reads the operand flat, while the next write reads it source-broken
  (`anyHardline`); the break sits behind the comprehension body's `BodyGroup`, which offers do not cross (FU3). `t_filter`
  tc k=27 — the comprehension `if` body seam is re-decided on read-back (`strictFitLineShape`), the same fit-body limit.

## FU28 (2026-10-20): typer facts harness — the DIFFERENT families, default type arguments, what a facts range holds

- the facts harness's DIFFERENT lists (`tools/TyperConformance.hx facts`) classified into families before any fix
  (anyparse 56 / 29 source / nominal, a client corpus 200 / 121, Pony 95 / 111). The largest client family, first
  attributed to "a typedef alias used without type arguments", is a class with a DEFAULT type parameter
  (`class Box<T = Void>` written `Box`; the compiler prints `Box<Void>`) — branch `feat/fu-FU28`
- probed on Haxe 4.3.7 (`--interp`): `Box` is `Box<Int>` for `class Box<T = Int>`, inside `Box` too (`get(): Box`
  returning `this` errors `Box.T should be Int`); trailing arguments only (`Two<Int>` is `Two<Int, String>`); a typedef,
  an abstract and an interface alike; `extends Box` passes `Int`; a default leaving out its own arguments is completed
  (`Outer<T = Inner>` is `Outer<Inner<Int>>`); a default naming another parameter is `Type not found`, a default naming
  its own type overflows the compiler; every std generic written without arguments is `Not enough type parameters`
  except `Dynamic` → `TypeDeclInfo.typeParamDefaults` + `AncestorTable.withDefaults` / `completed`, consumed by the
  source currency's binding, member and return arcs and by `linkOf` — branch `feat/fu-FU28`
- "matches or Unknown": a reference is completed only through a single resolved declaration, with every left-out
  parameter defaulted, its name not a type parameter of the file (a name a parameter may hold is that parameter or the
  type), and each default's types resolving from the reading file to the declarations they resolve to from the default's
  own file (the default is written into another file's text); anything else is no answer, never the reference as
  written. The nominal of a binding whose annotation's source is missing is not completed (the arguments were lost
  with it) — branch `feat/fu-FU28`
- a bare call's callee bound to a local declaration was refused by a NEGATIVE list (locals, parameters), so a local
  FUNCTION shadowing a member was typed by the member's return → positive: the member's return only when the name binds
  to a member declaration (`RefShape.memberDeclKinds`) or to nothing the scope walk sees (a supertype's member) —
  branch `feat/fu-FU28`
- the substituting path walk's package-blind fallback substitutes nothing, yet answered a member written with its
  declaring type's parameter (`Array<T>` for a receiver `Pri<String>`) → no answer when the member's written type names
  a parameter of its type or of the member (`NominalTypes.pathFinalHost` shared with `pathFinalMemberTypeSource`) —
  branch `feat/fu-FU28`
- the compiler side was the other half of the DIFFERENT lists: `CompilerFacts.typeOfExpressionAt` read a range's facts
  as the text's after passing over the sites it recognised as foreign, so what was left could be foreign too — the
  `this` an abstract's inlined property getter is handed is a local read placed at the member's name (a bare `whole`
  inside the abstract typed as its underlying `Float`), an inlined body's calls and fields at its call's range (a
  forwarded `brk()` typed `Array<Int>`). Positive instead: every fact at the range must be the text's — a local read
  carries the local's name (`LocalReadFact.name`, recorded by the facts macro) and counts under it, a receiver counts
  beside a call its own file spells at the call's range (a body inlined from another file takes the text as its
  receiver) or as the callee of a memberless call, a local the compiler declares at the range (`?.` / `??` temporaries,
  an inlined call's parameter, of the parameter's type) counts only beside a site of the text's own — and any other fact
  makes the range no answer. Measured: the passing-over form (first cut) turned conflicts that used to decline into a
  wrong single answer (Pony nominal DIFFERENT 111 → 135); the all-sites form ends at anyparse 11 / 19, the client corpus
  2 / 1, Pony 3 / 8 with MATCH within 0.2 % on anyparse and the client corpus and −2.2 % on Pony — branch `feat/fu-FU28`
- three harness spellings of one type (`TypeText`), each verified on 4.3.7 rather than assumed: an optional structure
  field's type is the optional value's (`{?a: Int}` and `{?a: Null<Int>}` assign both ways and print alike, an explicit
  `Null<…>` is not doubled); one unnamed type in parentheses before an arrow groups an argument of an old-style chain
  (`(A -> B) -> C -> D` is a two-argument function; `(x: A) -> (y: B) -> C` does not parse); and a typedef the index
  cannot follow (one declared in several `#if` branches) whose every compiled typedef of that name aliases the compiler's
  type is UNSCORED in both currencies — the same type in that build, not shown to be in every one — branch `feat/fu-FU28`
- an expression inside a reification (`macro { n; }`) was typed as the code its text spells (`Int` for the compiler's
  `Expr`) → neither currency types a node under a `RefShape.opaqueKinds` node with no `interpolationKinds` node between
  (`TypeResolver.reified`, the walk `Refs` reads `MacroEmit` by; `$v{n}` re-opens the code inside it). Findings inside a
  quotation were already dropped centrally (`ReificationScan.withoutQuoted`), so no lint verdict rests on those types —
  the all-rules lint of the four trees stays byte-identical; anyparse DIFFERENT 11 / 19 → 0 / 8, MATCH unchanged —
  branch `feat/fu-FU28`
- two guards measured rather than assumed: a word search for an empty name (`FactText.mentions` / `spellsCall`) never
  ended once its offset passed the text (an empty string's `indexOf` clamps at the length) — found by a mutant that
  recorded reads with no name, now answers false; the guard that stops a default reaching its own type is kept with no
  arm, since without it the recursion overflows into a throw a resolution step swallows and answers the same no type —
  branch `feat/fu-FU28`
- NOT closed, by size: `@:overload` returns (T5; an extern's `readFileSync` overloads, a socket's `on`); an inlined call with a default argument whose
  expansion leaves an argument flow at the call's range and no inline site (the facts macro records the inline call at
  the enclosing statement); a std member typed `Dynamic` that a library declares with a type — branch `feat/fu-FU28`

## FU26 (2026-10-20) — `asymmetric-branch-braces` asks the question of a whole chain, final `else` or not

- Gap (recorded by FU7): an else-if chain with no final `else` (`if (a) { x; } else if (b) y();`) was no finding, nor
  was a final-else chain braced in its tail and bare in its head (`if (a) x(); else if (b) { y(); } else { z(); }`):
  every non-tail link has an `if` as its else, so the pair test never saw them. `fmt` under
  `singleStatementBraces: "symmetric"` braces both (`chainForcesBraces`), measured on fixtures with the start engine.
- Detection now walks chain HEADS only (an `if` that is not another `if`'s else) and answers ONE finding per chain:
  the tail pair's own finding, span and message unchanged, when that pair is the asymmetric one, else a finding spanning
  the whole chain when a braced branch and a branch the writer would brace (`bareBranches`) coexist. The exemptions
  stay the rule's: an `else if` is the spine, not a branch; a terminal `else switch` is neutral (it was already exempt
  in a pair; `bareBranches` now leaves it out too, so the fix never braces it, as the writer glues it to its `else`).
  A declaration and a conditional-compilation region are flagged and declined by the fix's existing gates, exactly as
  in a pair; the fix is unchanged otherwise (all-or-nothing over the chain, terminator rules, reparse check).
- Not mirrored, unchanged on purpose (pre-existing, pinned by `testASwitchInThenPositionIsStillFlagged`): a branch in
  THEN position that is a `switch` or a bare `if` counts as bare and is braced by the fix, while the writer's
  symmetric wrap skips both ctors (`SYMMETRY_WRAP_SKIP_CTORS`); and an unterminated bare expression takes its `;`
  inside the braces where the writer leaves it bare (FU7's decision).
  Neither anyparse nor a client corpus has such a site.
- A bare branch's OWN comments - each opening a line of its own between its header and its statement - now go inside
  its braces (`bracesOpenAt`): the braces open right after the header. Left outside (FU7's edit started at the
  statement) they land between the header and the `{`, which is also what `fmt` does with such a branch under the
  symmetric policy - three anyparse sites (`ValueEscapes` x2, `MemberKinds`) read `)` / `// note` / `{`. A comment
  that shares its line with the header is the header's and stays. The "comment token directly above, opening its own
  line" step is one shared primitive, `SourceComments.ownLineCommentAbove`, which `ElementSpan.docExtendedSpan` now
  calls instead of its inline copy (block comments only there, as before).
- anyparse src+test at the fixed point: 68 chain findings in 53 files, 0 declined; only braces / `;` /
  whitespace differ; no follow-on rule fires. A client corpus with the rule enabled whose `fmt` runs
  `singleStatementBraces: "remove"` (which makes chains symmetric already): 0 sites.

## FU24 (2026-10-20): typer step T4b — std types for argument fits, `@:op` results, enum-abstract values

- `ArgumentTypes` resolved every argument / parameter type in the CALL GRAPH's index (the project and the library bodies
  the graph reads, no std), so a std abstract (`UInt`) or a library type the graph holds no body of never resolved and
  stayed `MayFit` → `heldFor`: the run's resolution index (`IndexScope.resolutionIndexOf`, report + libraries + std)
  where it holds the file writing the type, else the graph's entry (no resolution scope: as before). `coreName` keeps
  asking the CALL GRAPH whether an indexed type bears a core name — the resolution index holds the std's `Int` /
  `Float`, and asking it would make no name core — branch `feat/fu-FU24`
- the type of a field read (bare, off `this`, a static off a type name) carried no file (`ownField` / `accessType` read
  the graph's name-keyed `memberOnChain`), so a `UInt` field was never resolved → both read `MemberLookup.memberRead`
  (the old `memberReadType` with the declaration writing the member: `MemberReading.host`, `.member`) through the
  resolution index, the type carrying the declaring file — none for a supertype member whose type the chain substitutes
  (the arguments are written in another file). A static is read off its OWN type only (statics are not inherited) —
  branch `feat/fu-FU24`
- arithmetic over an abstract was untyped (core numbers only) → `OperatorOverloads` (`index.typing.operators`,
  `operators.ml` 4.3.7): the left operand's abstract first, the right one's when the left takes none
  (`try_abstract_binop_overloads`); the overloads of the operator in DECLARATION order (probed: `subA(A,A):String` before
  `subF(A,Float):Bool` gives `String`, the reverse order `Bool`); a candidate takes the operands when its first
  parameter EQUALS the left operand's type (`type_eq EqStrict`: `X - X` passes `subI(a:Int, b:X)` over though `X to Int`)
  and the right operand casts to the second (`Unification.casts`), mirrored for the right abstract, and a
  `@:commutative` one also swapped (`RefShape.commutativeOperatorMetaName`); `Null<U>` operands take `U`'s overload
  (probed, `type_eq` sees through `Null` there). Every `#if` branch of the abstract must pick an overload returning one
  type: `CastClauses.span` (the branch's range) tells which members a branch declares (`AbstractCasts.branchMembers`) —
  `UInt`'s flash branch picks `subI(UInt, Int):UInt`, the other `sub(UInt, UInt):UInt`, both `UInt` — branch `feat/fu-FU24`
- "matches or Unknown" for the overload: no answer for an operand or a parameter type the cast graph does not model, a
  candidate with type parameters, under `#if`, a signature overload, not taking two parameters (an instance overload
  takes one), a cast `Unification.casts` cannot decide, an abstract a build macro may add an overload to, branches that
  pick different types (`D - D` is `D` on `--interp`, `String` on `-js`, probed), and the language's own operator (no
  overload taken: the walk's core arithmetic answers that). The expected type's promotion (`type_non_assign_op`'s
  one-applicable-overload `with_type`) retypes an operand EXPRESSION only, never an identifier's or a field's type, which
  are the operands the walk types — branch `feat/fu-FU24`
- an enum-abstract value written with no type (`E.X`) had no type → `AbstractCasts.holdsUntypedValue`:
  every `#if` branch of the declaration an abstract declaring a non-static, unguarded field of the name with no written
  type — which an abstract declares only as an enum value ("Cannot declare member variable in abstract", probed), so the
  deprecated `@:enum abstract` qualifies too — and the value is of the declaration (`var A = 1` / `final B = 2` / `var F;`
  are `E`, `static var D = 4` is `Int`, probed). Asked by `ArgumentTypes.accessType` only; the index host's deep walk does
  not ask yet (the facts harness keeps its tables) — branch `feat/fu-FU24`
- NOT reached, measured on a client corpus: a library enum abstract of the shape of `openfl.text.TextFormatAlign` stays
  untyped, so a false positive whose remaining call chains each pass one of its values keeps them. Two facts stand in the
  way, each beyond this step: its first branch writes the `enum` keyword under `#if`
  (`#if (haxe_ver >= 4.0) enum #else @:enum #end abstract`), which the index reads as a split header (kind
  `AbstractDecl`, `castClauses` null); and its flash branch is a `typedef` to `flash.text.TextFormatAlign`, a std target
  subtree the resolution scope does not hold (`StdResolver.resolutionSpecs`: `*.hx`, `haxe/`, `sys/`), so what the value
  is there cannot be read. A chain whose argument is `a - b` over two `UInt` fields is pruned — branch `feat/fu-FU24`

## FU29 (2026-10-20) — no downstream project's names in this repository; the list that guards it lives outside

- **This repository is public, and the projects it is measured on are not.** Nothing committed here (docs, decisions,
  comments, tests, fixtures, tools, commit messages) names a downstream project or its code: no project name, no path
  into its tree, no type / file / member name taken from it, no code quoted from it. A finding is described by its SHAPE
  with neutral names, and a corpus effect as counts on "a client corpus". The details belong in private notes.
- **Fixtures were renamed, never reshaped.** Every name that came from a client corpus was replaced by a neutral one of
  the SAME LENGTH, so a width-, column- or order-sensitive fixture proves what it proved before (identical structure,
  identical assertions, the suite's test and assertion counts unchanged). Two renames had to respect more than length:
  an import-order fixture needs the new names to sort as the old ones did, and a parameter-naming fix derives its
  expected name from the type, so the field name follows the type's rename. Generic vocabulary a client also happens
  to use (`Main`, `Node`, `Grid`, `Store`, `Label`, `items`, ...) is anyparse's own and stays.
- **One scrub, three uses.** The scrub is a git-filter-repo `--replace-text` map applied to the tree with filter-repo's
  own semantics (literals first, then regexes, in file order; binary files skipped), so the same file rewrites the
  unpublished history and reproduces this tree. It lives OUTSIDE the repository — a list of the names to keep out would
  publish them — and is what `tools/scrub-guard.py` reads (`--list` or `ANYPARSE_SCRUB_LIST`): the tree, or with
  `--range A..B` the lines a range adds and its commit messages; matches are reported by rule number, never by text.
  `tools/hooks/pre-push-scrub.sh` runs it over what a push would publish. With no list configured both pass and say so,
  so a clone without the private list is not blocked.
- **A private corpus is named by the environment, never by the repository.** `tools/battery.sh` lints a second tree only
  when `--client <tree>` or `ANYPARSE_CLIENT_TREE` names it (it used to default to a path on one machine);
  `tools/bench-corpus.txt` includes its calibrated other half through `@${ANYPARSE_BENCH_EXTRA}`, a manifest kept outside
  the repository (`tools/ParseProf.hx` learned `@<manifest>` include lines for it). Blast-cache baselines written under the
  old file names are not read under the new `*-client.json` ones; a first run after this re-snapshots.

## FU25 (2026-10-20): typer step T5 — the signature a call selects among its overloads

- **The candidates and their order are the compiler's** (`callUnification.ml` `unify_field_call`, `typeload.ml`
  `init_meta_overloads`, Haxe 4.3.7, each probed on `--interp` and `-js`): an `@:overload` member's own signature first,
  then each annotation's function in WRITTEN order (`cf :: cf_overloads`), and the first one that compiles binds
  (`attempt_calls` stops there for `OverloadMeta`) — `h(a:String)` with `(a:Float)` written before `(a:Int)` takes
  `(a:Float)` for `h(1)` (`String`), the reverse order `(a:Int)`. A non-extern function may carry `@:overload` too.
  `MemberInfo.signatures` records the list; an annotation that writes no one function (a bare `@:overload`, a
  target-native overload) leaves it empty, so a call to such a member answers nothing. The `overload` modifier tries every
  candidate and keeps the most specific (`reduce_compatible`): modelled for a static only, and only when ONE candidate may
  compile; off a value its candidates include the supertypes' (`Overloads.get_overloads`), so no answer — branch
  `feat/fu-FU25`
- **Whether a candidate compiles** is the compiler's greedy path (`unify_call_args`) over `Unification.casts` per argument
  (`ArgumentSlots.compiles`): `Misfits` when no way to bind the arguments compiles (`ArgumentSlots.runs` answers none),
  `Fits` when that path is decided at every step and ends bound, `MayFit` otherwise. A skip of a parameter written with a
  default whose type is not nullable answers `MayFit`: Flash alone refuses it (`common.ml`
  `pf_can_skip_non_nullable_argument`; js, hl and cpp accept `g(n:Int = 3, a:String)` called `g('x')`, probed) —
  branch `feat/fu-FU25`
- **The code compiles**, as `ArgumentSlots` already assumes: a candidate whose fit is not decided binds when it is the last
  one that may compile (`readFileSync(entry)` takes `(filename:FsPath):Buffer`, every other candidate wanting two
  arguments). Where no candidate is decided, a call returns the type every candidate that may bind it returns (all written
  in one declaration), else nothing — branch `feat/fu-FU25`
- **A choice that depends on the expected type answers Unknown.** Arguments are typed ONCE, with no expected type
  (`CallArgument`): a literal, `null`, a binding whose annotation the call's file writes, a local by its initializer —
  each resolved where that file writes it. A lambda, an object or array literal, a member read, a call: untyped, so every
  candidate may take them. Measured: one MATCH of the old name walk is now Unknown on anyparse (`readFileSync(p,
  { encoding: 'utf8' })` — the object literal is typed against each candidate's structure; the own signature's return was
  right by luck). The table (`QueryCache.callArguments`) is keyed by the site and its declaration
  (`DeclarationKey.ofSite`) and also by the call's text and the file's length: a `lint --fix` run asks again of an index
  built before it rewrote the file — branch `feat/fu-FU25`
- **The superclass chain declares a member before an interface does** (`raw_class_field`: own fields, `cl_super`, then
  `cl_implements`): the name walk (`MemberLookup.returnNominalWalk`) used to pass over a supertype whose return it could
  not name (`EventEmitter<TSelf>.on(): TSelf`) and answer an interface's (`IEventEmitter`) — now such a supertype makes
  the walk unknown, and an overloaded member does too. The walk is by simple name, so a NAMESAKE's unknown poisons it as
  well (a std type sharing a simple name with a project's); that is not undone — the call is then typed through the declarations the call's
  file resolves (`CallReturns.selectedReturn`: the enclosing type of a bare call, the written type of a static call, every
  declaration of a value's type name agreeing, one no candidate of which compiles being a namesake the receiver is not),
  which binds the chain's arguments (`AncestorTable.boundType`: `S extends E<S>` reads `on()` as `S`) — branch
  `feat/fu-FU25`
- **An `@:overload` callee's body parameters are bound only when its own signature is selected.** The arguments reach the
  body by POSITION, typed and padded as the selected signature binds them: `go(new Foo(), true)` selecting
  `(?y:Int, x:Foo, flag:Bool)` over the own `(x:Bar, ?flag:Bool)` hands the body `x = null` (probed `-js`), where the
  own parameters' slots would read `x` as the `Foo`. `ArgumentValues` therefore binds through the own slots only when
  `CallSelection.chosen` picks the own signature, else hands the callee nothing known — branch `feat/fu-FU25`
- **A lambda's parameter is typed by the signature the call selects** (`OperandCallees`), decided by the arguments' count
  and `null` literals alone: every other argument the binder types is a lambda, which each candidate types differently —
  branch `feat/fu-FU25`
- **A function's written return type is read off the span info** (`SpanTypeInfo.returnTypeSources`, beside
  `returnTypes`): the query tree flattens a type parameter's bound beside the return (`function g<T:Int>(x:T) {}` has a
  `Named Int` child), so the last annotation child is a bound, not a return, for a function written with none. The
  signatures and `MemberInfo.returnSource` read the new map (`c.g(1)` over that `g` was typed `Int`); the query-tree
  reader (`CallGraphNames.returnSourceOf`) stayed for a function no index records (a local function, a lambda) until FU32
  moved it onto the same map — branch `feat/fu-FU25`
- **A method's own type parameter is bound by the arguments** (T5 step 2): a parameter written as one (`x:T`) takes any
  value, a bounded one (`<T:Int>`, `SpanTypeInfo.typeParamConstraints` into `CallSignature.typeParamConstraints`) a value
  unifying with every bound (`check_constraint`; `Unification.unifiesEnds`), so the bound takes part in the choice
  (`c<T:Int>(a:T)` with `@:overload(function(a:String):Bool {})` takes the annotation for `c('x')`, probed). The call's
  return names the type each such parameter is bound to (`TypeEnd.Param`, the type variable; `CallSelection.bindings`
  over the compiler's way to bind the arguments): `id(1)` is an `Int`, a declaration spelled by its module path so it
  resolves wherever the return is read. Unknown where two arguments bind it to types not known to be one (the second
  must unify with the first: decided only when equal), where an argument binding it is not typed, and where it is a
  `Null<…>`: `id(n)` over `?n:Int` binds `Null<Int>` (probed), which an end does not spell (`CallArgument.Nullable`).
  Measured: two calls of a library's generic `tween(target, …)` over a nullable target, in a client corpus, were the
  case that showed it — branch `feat/fu-FU25`
- **A generic abstract casts through the arguments it is applied to** (T5 step 3, `apply_params`): a type written
  `E2<String, Float>`, or a plain `typedef` aliasing it (`TypeDeclInfo.aliasTargetWritten` keeps the arguments
  `aliasTargetRaw` drops), stands for the abstract applied (`TypeEnd.Applied`), every argument an end the graph models
  (else `Open`); its graph reads a clause written as one of its type parameters as the argument at that position
  (`AbstractCasts.appliedGraph`) and every other clause or member naming one as no end. So `true` misfits
  `E2<String, Float>` (`from String`, `from Float`) and an `@:overload` `(x:Bool)` binds, and `1` fits it through
  `from Float` (probed: `g(1)` keeps the own signature). An applied abstract is itself applied ALIKE only — its type
  parameters are invariant (`Box<String>` to `Box<Int>`: "String should be Int", probed). An alias re-entering itself
  stands for no end — branch `feat/fu-FU25`
- **Typing by the declared builds (T5 step 4) is NOT done, and why.** An `#if` branch every shipped build leaves dead
  could be dropped when a split declaration is typed (a library enum abstract whose other branch is a `typedef` to a
  target std type the resolution scope does not hold — the shape of `openfl.text.TextFormatAlign`). Two facts stand in
  the way. The liveness of a branch across the builds is known only from their compiler facts (`ReachLiveness` over
  `ReachBuilds`: `everDefined` is what makes a define's ABSENCE evidence, a define list alone being positive-only), so it
  exists in a run that compiles them and in none under `--no-oracle`; and the index keeps no cast clauses or per-branch
  members for a declaration one branch of which is no abstract (`TypeDeclInfo.castClauses` null), so there is no branch
  record to drop. The split header `#if (haxe_ver >= 4.0) enum #else @:enum #end abstract` is a third, independent of
  any build: every alternative writes the same enum abstract, which `castClausesOf` refuses because the name node is not
  the declaration node — branch `feat/fu-FU25`


## FU32 (2026-10-20): typer small items — a return read off the span info everywhere, a namesake that inherits, a harness limit

- **Every reader of a function's written return reads the span info** (`CallGraphNames.returnSourceOf(fn, returns)` over
  `SpanTypeInfo.returnTypeSources`, `returnSourcesOf(plugin, source)`, the graph's door `CallGraph.returnSourcesIn`). FU25
  moved the index's members onto that map and left the query-tree reader (the last annotation child) for the functions no
  index records; it read a type parameter's bound as the return of a function written with none
  (`function g<T:Foo>(x:T) return new Bar();` — 4.3.7 runs `Bar.run` for `g(f).run()`, local function and member alike —
  and `mk<T:(c:Use)->Int>()` returning a lambda 4.3.7 types `(c : { on : Bool }) -> Int`). The tree reader is gone: the
  call graph's nodes (members included — `DeclarationFacts.returnSources` was filled from it), `@:overload` agreement,
  the per-declaration return list, the lock-alias class bounds and the operand binder's lambda expectation and local-call
  tier all take the one map. A plugin with no batched span info proves no return type (Unknown) — branch `feat/fu-FU32`
- **A namesake inheriting the member joins the agreement** (`MemberLookup.receiverDeclarationsOf`): the walk by simple
  name used to read only the declarations of the name that declare the member themselves, so a receiver of one that
  INHERITS it (`p.Socket extends Duplex`, `Duplex.write(...): Bool`) answered the other's own (`q.Socket.write(): Void`).
  Every declaration of the name declaring none now adds the member its supertype chain reaches (`declaringMember`, read
  where its file binds the links), and the name walk (`returnNominalWalk`) and the source currency's `returnSourceOf`
  require all to agree, else Unknown; `CallReturns.selectedReturn` then decides where the call's arguments exclude a
  namesake (`s.write('a', 1)` against a one-parameter namesake). Resolving the receiver to its one declaration needs a
  currency that carries the file a type was written in — not done. The first cut (Unknown whenever a namesake inherits)
  lost 12 MATCH per currency on a client corpus to std `_std` copies that agree; the agreement keeps them. Four
  stay lost there, correctly: `_std` copies of a std output class one of which inherits a `flush()` written with no
  return type — branch `feat/fu-FU32`
- **An inlined call leaving out an argument of the type the facts give its range is UNSCORED** (`TyperConformance`,
  `leavesAnInlinedArgumentOut`): the facts record an inlined call at the innermost expression around it (`CallFact.site`,
  the enclosing statement), never at the call, so what they hold at the call's range is the default the compiler hands the
  parameter left out (`json(140)` over `inline function json(w:Int, a:Bool = false):String` → `Bool`). A harness limit,
  not an engine answer: unscored only when an `inlined` call of the callee's name has a site holding the range and its node
  declares a parameter past the passed arguments of exactly that type — the first cut (any left-out parameter) also
  unscored four calls whose range held the call's own `Void` — branch `feat/fu-FU32`

- **Typing by the declared builds (T6, the step 4 T5 left).** The index keeps one record per `#if` branch of every
  declaration (`TypeDeclInfo.branches`: the kind the branch writes, its range, an abstract's header clauses), replacing
  `TypeDeclInfo.castClauses`, which a single branch of another kind (a `typedef` to a target type) nulled for the whole
  declaration. `BuildBranches` (`TypingService.builds`) answers which of them some build the run declares may compile:
  `ReachLiveness.live` over the builds the host probes (`SymbolIndexHost.reachBuilds`: the compiler oracle's
  configurations, declared complete), the defines each build reported deciding a condition against the branch, a define
  it never set (`everDefined`) counting as absent and one it set at any point as possibly present. `AbstractCasts` reads
  only those branches — `clausesOf` (also the `TypedEventConstant` consumer, moved off the record), `branchMembers` (so
  `holdsUntypedValue` and `OperatorOverloads`) and the cast graph's clauses and conversion members, a member only a dead
  branch declares converting nothing. Three edges, each the conservative one: a declaration written once never asks for
  the builds (the probe compiles every configuration, so it is asked only when the answer can change, and once); a run
  with no builds known reads every branch; and a declaration no build compiles at all is read whole (no answer about it
  can be checked against a build).
  **Without the oracle the builds are not known, by decision.** A configuration's `defines` list names only the `-D`s
  its command line adds; the target's own defines and those a library's `extraParams.hxml` or an initialization macro
  sets reach only the compile (probed on 4.3.7: `--macro haxe.macro.Compiler.define('foo')` turns `#if foo` on, and
  `-D flash` is refused from the command line, "a reserved compiler flag": a target define is set by the target alone),
  and the generated hxml a `generate` entry names does not exist before `generate` runs. So a define the config leaves
  out is no evidence that no build sets it — the positive-only list `LibraryBuild` reads for the opt-in library walk
  states the same limit. Under `--no-oracle` every branch is read and nothing changes; the client-corpus false positive
  this was built for goes in an oracle-enabled run only.
  **The split `enum` header was misdiagnosed in FU25.** `#if (haxe_ver >= 4.0) enum #else @:enum #end abstract E(T)`
  projects as a module-level conditional holding the keyword and the meta, followed by a plain abstract declaration
  node, so `castClausesOf` reads that node (its name node is the declaration) and answers its clauses; the null was the
  `typedef` branch's. 4.3.7 types `E.A` as `E` there (`$type`) and skips an optional `Float` parameter for it. The
  index's kind stays the plain abstract kind (it mirrors the node); reading it as the enum-abstract kind would move the
  answers of the rules keyed on that kind and is not this step — branch `feat/fu-FU31`

## C0 (2026-10-21) — two corpus fixtures that moved PASS→FAIL after 2026-09-20, bisected

- FU26 (`asymmetric-branch-braces`) broke `issue_339_line_comment_before_catch` → no: bisect names `7f60f9fa7`, whose glued-keyword rule also glued a block comment that ENDED its source line before the first `catch` (later catches kept it via `_t.newlineBefore`) → `7f60f9fa7`
- N52b (`Doc.BreakMark`) broke `opadd_chain_keep` → no: bisect names `85ea6604c`, whose `flatLength < 0` gate also opens a paren the source glued around a `keep` chain broken at its own operators, which the old `CollapseProbe(HardFlatten)` gate left glued without trailing content → `85ea6604c`
- a glued paren around a broken `keep` chain nests by the source break after `return` / `=` → no: the `return` policy (fitLine by default, decided at render) may drop or add that break, so one write stops being a fixed point; the paren co-indents with the line the value starts on → `batch/hxqb-C0`
