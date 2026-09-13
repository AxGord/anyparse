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
