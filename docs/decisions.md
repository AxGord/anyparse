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
  `S222-merge`
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
