# CLI query tool — roadmap

Phased delivery plan for the `apq` / `hxq` query tool. Design baseline lives in [cli-query-tool.md](cli-query-tool.md).

This is a **parallel track** to the main anyparse roadmap ([roadmap.md](roadmap.md)). The tool builds on the existing parser pipeline and grammar plugins; it does not block or unblock any phase of the main roadmap.

Each phase has a goal, deliverables, and an explicit exit condition. A phase is not "done" until the exit condition is met and the project is green.

## Phase 0: Design lock-in

**Goal**: validate the pattern syntax, selector syntax, and matcher semantics on paper, against real query needs, before writing any engine code.

**Deliverables**:
- 10 representative queries written by hand against the anyparse Haxe codebase, covering all four commands (`ast`, `search`, `refs`, `meta`).
- Each query annotated with what it returns and why it is useful in a real workflow.
- Resolution of the open questions parked in [cli-query-tool.md](cli-query-tool.md#open-questions):
  - Metavariable reuse semantics (structural equality vs unification).
  - Star-children matching (adjacent vs anywhere).
  - Whitespace and comments in patterns (ignored vs significant).
- Pattern syntax frozen and documented in the spec.
- Selector syntax frozen and documented in the spec.
- Output JSON schema **sketched** per command (locked at MVP commit per Phase 1/2/3; **finalized** in Phase 4 once shell-composition usage validates the shape).

**Exit condition**: 10 queries reviewed without prompting any backward-incompatible syntax change. Open questions answered with rationale recorded in the spec.

## Phase 1: `apq ast` MVP

**Goal**: ship the first usable command — AST dump — end-to-end. Establishes the binary, the CLI dispatch, the grammar plugin loader, the output formatters.

**Deliverables**:
- `bin/apq.hxml` neko target.
- `hxq` shell alias.
- CLI dispatch (`src/anyparse/query/Cli.hx`).
- Grammar plugin selection via `--lang` argument; preset alias machinery.
- `apq ast` command:
  - S-expr output (default).
  - JSON output (`--json`).
  - `--at <line>:<col>` cursor query.
  - `--select <path>` selector query.
  - `--depth <n>` truncation.
- Text and JSON formatters as separate modules.
- Unit tests for the selector matcher.
- Integration test: parse every `.hx` file under `src/anyparse/` and emit AST without crash.

**Exit condition**: `apq ast` runs cleanly on every `.hx` file in the anyparse repo on neko/js/interp. Selector matches verified by integration test on a small fixture corpus.

## Phase 2: `apq search` MVP

**Goal**: ship structural pattern search. The most architecturally load-bearing command — its design choices propagate to every subsequent feature.

**Deliverables**:
- Pattern parser (`src/anyparse/query/Pattern.hx`): reuses the active grammar plugin with the metavariable token extension declared by the plugin.
- Matcher engine (`src/anyparse/query/Engine.hx`): language-agnostic tree walker + unification.
- `apq search` command:
  - Text output: `file:line:col` plus match summary and bindings.
  - JSON output: structured matches with span and bindings array.
  - Glob input handling.
- Per-pattern parse error reporting with at least as much fidelity as the grammar's own parse errors.
- All 10 Phase 0 queries that use `search` return the expected matches.
- Perf measurement: `apq search` on the largest single file in the target corpus (~10k lines representative) — sub-second target on neko.

**Exit condition**: 10 Phase 0 queries pass; perf target met on the largest current file; no engine code references Haxe-specific AST types ([universalization invariant](cli-query-tool.md#universalization-invariant) enforced by code review).

## Phase 3: `apq refs`

**Goal**: ship lexical, scope-aware symbol queries.

**Deliverables**:
- Scope tracker (`src/anyparse/query/Scope.hx`): grammar-plugin-supplied list of scope-introducing nodes; engine walks both AST and a parallel scope stack.
- `apq refs` command with `--reads`, `--writes`, `--decls` filters.
- Test corpus exercising shadow vs reference cases (inner binding shadows outer, function-local vs class-field, for-loop variable scope, etc.).
- Plugin contract documented for new grammars: what to declare to enable scope-aware refs.

**Slice status**:
- 3.1 — name-only walker, decl/read classification.
- 3.2 — lexical scope + `bindingSpan` resolution.
- 3.3 — write classification via parent-context.
- 3.2b-α — loop-iterator binding via the `selfScopeDeclKinds` plugin contract field: a scope-introducer self-binds its own name into the frame it opens, so a `for`/comprehension induction variable is a declaration scoped to the loop body (shadows an outer same-named binding inside, falls through after).
- 3.2b-β — exception names in catch clauses and lambda parameter names. These sit on transparent typedef-structs that, by default, carry no addressable span (spans are synthesised only on enum-ctor nodes). Closed via a declarative `@:spanned('<Kind>')` grammar marker: a tagged Seq typedef opts out of transparency, its paired struct gains a per-instance `_span` + `_kind`, and the query plugin surfaces it as an addressable node. The mechanism is generic (any grammar marks its decl-bearing transparent structs the same way; no engine hardcoding). Catch-clause exceptions are self-scoped decls; lambda parameters are decl-hosts in the enclosing lambda scope.

**Exit condition**: hand-crafted shadow/reference corpus returns correct results for every case — scope shadowing, function-local vs class-field, write classification, loop-iterator scope, catch-clause exception scope, and lambda-parameter scope. Plugin contract is one page or less.

## Phase 4: `apq meta` + JSON stabilization

**Goal**: round out the v1 surface and make shell composition first-class.

**Deliverables**:
- `apq meta` command implemented as a wrapper over `search` with a tighter syntax for "this annotation on a declaration".
- `--arg-contains` and `--on <decl-kind>` filters.
- JSON output schema for all four commands **finalized** and documented (consolidates the per-command MVP-locked schemas from Phases 1–3). Subsequent versions may extend but not break.
- Shell-composition examples in the spec (piping `apq meta | jq`, batching with `xargs`, etc.).

**Slice status**:
- 4.1 — `MetaShape` plugin contract (`metaKinds` + `declHostKinds`, sharing the decl-host set with `RefShape`) + the language-agnostic `Meta.find` walker. An annotation attributes to the decl-host sibling whose span starts immediately after it (source order, not flattened child order), falling back to the nearest enclosing decl-host ancestor for expression-level metadata.
- 4.2 — `apq meta` command: `[<annotation>] <file-or-glob>` positional grammar, `--on <decl-kind>` and `--arg-contains <substring>` filters, text renderer.
- 4.3 — `meta` JSON schema fileset (macro-generated, dogfooding the writer) + `ast` schema finalization (`span` is now part of the `ast` Node contract, present when source-addressable).
- 4.4 — spec finalization wording (v1 stable, additive-only; envelope + omit-when-absent conventions documented) + five verified shell-composition examples + this close-out.

**Status**: ✅ done. All four deliverables landed; JSON schemas finalized in the spec; five shell-composition examples documented and verified end-to-end.

**Exit condition**: JSON schemas committed to the spec. Five shell-composition examples documented and verified. — **met.**

## Phase 5: Dogfood pass

**Goal**: use the tool on real anyparse work for a sustained period, log friction, fix.

**Deliverables**:
- Tool used on at least 5 real slices in the main anyparse roadmap.
- Friction log: every operation that was awkward, every query that surprised the user, every perf cliff hit.
- Targeted fixes for the top three friction items.
- Decision on whether an indexing layer is needed for perf (parked from Phase 2).

**Status**: 🔶 started.

**Friction log** (append as found):
- **F1 — grammar coverage gates everyday use.** Sampling `apq ast`
  over `src/**/*.hx`: only ~17% parse (≈20 of the first 120). The
  Phase 3 Haxe grammar is a skeleton — generics, complex
  expressions, and macro-heavy files (`WriterLowering.hx`,
  `Lowering.hx`, most `grammar/haxe/*`) fail (`expected HxDecl at N`).
  Consequence: `apq`/`hxq` is reliable today only on the simpler
  subset (`query/**`, `runtime/**`, `format/**` interfaces, schema
  typedefs — including apq's own source). The single highest-leverage
  Phase 5 fix is **widening the Haxe grammar by top parse-failure
  cause**, which also advances anyparse main-roadmap Phase 3 — the
  two tracks intersect here.
- **F2 — anon Star is strictly `,`-separated in plain mode. ✅
  RESOLVED (Slice 0).** Histogram of the F1 bucket (fresh `bin/apq.n`,
  full `src/**/*.hx`): the #1 cause (~99 files) is anonymous-structure
  types using class-notation fields (`{ var name:T; }`, `@:meta`
  prefixes). `HxType.Anon`'s `@:sep(',')` Star hard-required `,` in
  the non-trivia build, so only the SINGLE-field case parsed. The
  discriminator is `ctx.trivia` (the macro build flag), orthogonal to
  the Fast/Tolerant axis: both `HaxeParser` (Fast) and the span parser
  `apq` uses (`HaxeModuleSpanParser`, Tolerant) are non-trivia
  (`{trivia:false}`), so neither hit the tolerant trivia-mode path.
  The sep loop is generic across every `@:sep` Star (HxObjectLit,
  ArrayExpr `[1, 2]`, fn/type params), so a global `;` accept was
  unacceptable. **Resolution**: a new opt-in meta `@:sepAlt(';')`
  (registered in the `Lit` strategy → `lit.sepAltText`) gates a
  tolerant close-driven loop in `Lowering` that consumes an OPTIONAL
  `,` OR `;` between elements plus an optional trailing separator;
  the pre-existing strict loop is byte-identical when the meta is
  absent (zero global blast radius). The earlier "drop `@:trail(';')`
  from the class-notation branches" prescription was superseded by a
  lower-blast-radius refinement: `VarField`/`FinalField` KEEP
  `@:trail(';')` (the field eats its own `;`), so there is no
  synth/writer ctor-arity ripple; the close-driven loop tolerates
  field-eaten `;`, Required `;`-separated fields, classic `,`, mixed,
  trailing-sep, and `{}`. WriterLowering is verify-only (emits the
  canonical `,`; the haxe-formatter corpus has no `;`-anon and apq
  queries are read-only — per-element sep preservation for `;`-anon
  write-back deferred to Phase 4). Result: parse-rate **56 → 74 / 273
  (+18)**, neko 4743 / js 4740 / interp 4743 green, 0 regressions.
  Unblocks Slice B (function field) and Slice C (`@:meta` prefix),
  which shared the multi-field-anon prerequisite.
- **Slice B — anon-type `function` field. ✅ DONE.** Added
  `@:kw('function') FnField(decl:HxFnDecl)` to `HxAnonField`, a direct
  mirror of `HxClassMember.FnMember`. `typedef T = { function f():Void; }`
  and `{ var x:Int; function g(a:Int):Bool; }` now parse, riding the
  Slice 0 close-driven loop (the `;`/`}` terminator is owned by
  `HxFnBody`, not a per-branch `@:trail`). Pure additive Alt-enum
  branch: the writer auto-dispatches via WriterLowering generic Case 3
  single-Ref path (same as `VarField`/`FinalField`/`FnMember`) — zero
  writer/synth change. neko 4761 / js 4758 / interp 4761 green, 0
  regressions. Parse-rate sweep stays **flat at 74/273** — no
  `src/**/*.hx` corpus file uses anon-struct-with-function-field, so
  Slice B is correctness/coverage (unit-test-covered) rather than a
  sweep-mover. Sweep-moving F1 buckets remain: enum abstract (~39
  files); module-level `#if` was *thought* to be ~27 but Slice E
  disproved this (it already parses — the bucket was masked heritage
  failures; see Slice E). Slice C (`@:meta` prefix +
  `HxAnonField`→`HxAnonFieldKind` rename + wrapper typedef) is the
  remaining typedef-struct refinement.
- **Slice D — `enum abstract` (sweep-mover). ✅ DONE.** Added
  `@:kw('enum') EnumAbstractDecl(decl:HxAbstractDecl)` to `HxDecl`,
  ordered before `EnumDecl`. The `enum` keyword is consumed at the
  `HxDecl` level; the payload reuses `HxAbstractDecl` verbatim (its
  `name` owns `@:kw('abstract')`, the enum-value body is ordinary
  `HxMemberDecl`). Plain `enum Name { ... }` still routes to `EnumDecl`
  via the shared-keyword `tryBranch` rollback (same pattern as
  `PackageDecl`→`PackageEmpty`). Pure additive Alt-enum branch — zero
  core Lowering / synth / writer change (WriterLowering generic
  `@:kw`-ctor dispatch, `VarDecl`/`FnDecl` precedent). 8 new unit tests
  (`HxEnumAbstractSliceTest`) cover parse, `private` modifier,
  whitespace, plain-enum rollback regression, and writer round-trip;
  neko + js + interp green, 0 regressions. **Parse-rate sweep
  74/273 → 113/273 (+39)** — the predicted enum-abstract bucket
  cleared. First confirmed sweep-mover of the D-track.
- **Slice E — class/interface heritage (`extends`/`implements`).
  ✅ DONE (grammar gap closed; NOT a sweep-mover).** New
  `@:peg enum HxHeritageClause { @:kw('extends') ExtendsClause(type:HxType);
  @:kw('implements') ImplementsClause(type:HxType); }` — exact structural
  twin of `HxAbstractClause` (`from`/`to`). Consumed as a bare
  `@:trivia @:tryparse @:fmt(padLeading) var heritage:Array<HxHeritageClause>`
  field placed between `typeParams` and `members` on **both**
  `HxClassDecl` and `HxInterfaceDecl` (mirror of `HxAbstractDecl.clauses`).
  Pure additive — zero core Lowering / SpanTypeSynth / TriviaTypeSynth /
  WriterLowering change (the bare-Star Case-3-`@:kw` shape is already
  driven generically for `HxAbstractClause`). Parser is intentionally
  permissive (no policing of one-`extends`-per-class, `implements`-only-
  for-classes, etc.). 11 new unit tests (`HxHeritageSliceTest`) cover
  single/multi clauses, heritage-after-type-params, no-heritage-stays-
  empty, heritage-inside-`#if`, writer round-trip, keyword word boundary;
  neko + js + interp green, 0 regressions.
  **Probe-first correction:** the prior histogram tagged "module-level
  `#if` (~27)" as the next sweep-mover. Empirically **disproved** —
  module `#if` already parses; `Skip.hx`-type failures were masked
  *heritage* failures inside `#if macro` regions. But heritage is **also
  not a sweep-mover**: parse-rate moved only **113/273 → 115/274 (+2)**.
  29 of the 30 `extends`/`implements` failing files have *compounding*
  deeper blockers (complex member bodies / other unsupported constructs
  inside large `#if macro` regions), so closing heritage alone does not
  flip them. Same lesson as Slice B: "closes a grammar gap" and "moves
  the sweep" are independent; quantifying *files that contain* a
  construct over-counts when those files have multiple blockers. The gap
  was real and worth closing for correctness/coverage; the sweep-mover
  hunt continues (true movers require finding the *innermost* shared
  blocker, not the outermost visible construct).

- **Slice C — anon-struct field-level metadata (THE sweep-mover).
  ✅ DONE.** New `@:peg typedef HxAnonMember = { @:trivia @:tryparse
  var meta:Array<HxMetadata>; var field:HxAnonField; }` wrapper;
  `HxType.Anon` now iterates `Array<HxAnonMember>`. The exact
  `HxMemberDecl`→`HxClassMember` split applied at the anon-struct
  level (proven pattern, no rename, no core macro change). Closes
  `typedef T = { @:lead('(') var x:Y; }` — the anyparse grammar DSL's
  own shape and the dominant apq self-parse blocker. Drill-down +
  strip-test recon (not surface grep) found it present in **87/159**
  failures; the lesson applied *in reverse* — this time the visible
  file-count *was* the innermost shared blocker. Parse-rate
  **115/274 → 198/275 (+83)**, by far the largest single mover; the
  plan's compounding-blocker pessimism was over-conservative because
  typedef-field-meta was the *first* blocker for nearly all 87.
  `HxTestHelpers.expectAnon` projects `.field` to keep ~50 existing
  callers byte-unchanged; new `expectAnonMembers` for metadata-aware
  tests; shared `expectVarField/FinalField/FnField/ShortFieldBody`
  unwrap helpers promoted to the base (dedup with
  `HxAnonVarFieldSliceTest`). New `HxAnonMemberSliceTest` (10 cases:
  every field kind + multi-field mixed meta + no-meta byte-identical
  regression + `#if`-nested dogfood shape). neko 4855 / js 4852 /
  interp 4855, 0 regressions. This supersedes the earlier
  "Slice C — `@:meta` prefix (typedef-coverage, NOT a sweep-mover)"
  estimate: it is *the* sweep-mover.
- **Slice F — property accessors `var x(get,set):T` (sweep-mover).
  ✅ DONE.** New `@:peg typedef HxAccessClause = { @:sep(',')
  @:trail(')') var ids:Array<HxIdentLit>; }` (proven `HxNewExpr.args`
  inner shape); `HxVarDecl` gains one optional field
  `@:optional @:lead('(') var access:Null<HxAccessClause>;` between
  `name` and `type`. `@:lead('(')` is the optional commit point
  (same idiom as the existing `type`/`init` optional Refs). Zero core
  macro change; accessors parse in every `HxVarDecl` position (class
  member, anon-struct `VarField`/`FinalField`, var statement) —
  permissive per the `HxHeritageClause`/`HxDecl` philosophy.
  Strip-test recon at the post-Slice-C base (198/275) found accessors
  in 21/77 failures, the *sole/first* blocker for **15** (verified
  clean sweep, not masking — module `#if`'s 22-file bucket strip-tested
  as gap≠sweep and was correctly skipped). New `HxAccessorSliceTest`
  (keyword forms + method-name accessors + `final` + anon-struct +
  whitespace + 4-form null regression + writer round-trip). Parse-rate
  **198/275 → 214/276 (+16)**, exceeding the +15 estimate. neko 4887 /
  js 4884 / interp 4887, 0 regressions.

- **Slice G — typedef `&` intersection (`typedef X = A & B`). ✅ DONE.**
  New `@:peg typedef HxIntersectionClause = { @:fmt(typedefIntersection)
  @:lead('&') var type:HxType; }` consumed as a bare
  `@:trivia @:tryparse @:fmt(padLeading) var intersections:Array<
  HxIntersectionClause>` Star on `HxTypedefDecl` (structural sibling of
  `HxClassDecl.heritage` / `HxAbstractDecl.clauses`): first operand stays
  in `type`, each subsequent `& T` is one flat clause. **Scoped to the
  typedef RHS deliberately, NOT added as an `HxType` Pratt operator** —
  an `@:infix('&')` on `HxType` (the first-cut approach) made the
  `is`-operator right-operand parser greedily eat the first `&` of a
  following expression-level `&&` (the `HxType` Pratt op set has no
  `&&` to win longest-match), regressing `HxBinopGroupWrapSliceTest`.
  Scoping `&` to the tail keeps `HxType` `&`-free so the collision
  cannot arise, and matches real Haxe grammar (intersection is a
  typedef-rhs / constraint construct, not a general type operator).
  Around-spacing is split exactly like the heritage clauses: post-`&`
  space from the new `typedefIntersection:WhitespacePolicy` option
  (default `After`, mirrors `typedefAssign`'s 4-site wiring —
  `HxModuleWriteOptions` / `HaxeFormat` / `HaxeFormatConfigLoader` /
  `whitespacePolicyLead` flag list), pre-`&` space structural via the
  Star's `padLeading` + inter-element separator. `@:kw('&')` is
  rejected (Case 3 `expectKw` word-boundary check would reject `A&B`).
  Zero core macro change. New `HxTypeIntersectionSliceTest` (named /
  empty-anon / non-empty-anon / flat-chain / bare-unaffected / writer
  spacing / `is`-not-broken regression guard / round-trip). Parse-rate
  **214/276 → 223/277 (+8 corpus** — the 8 sole-blocker `*WriteOptions.hx`
  files, 62→54 fails; the new grammar file self-parses for the +1 total).
  neko 4913 / js 4910 / interp 4913, 0 regressions.

- **Slice H — pre/post increment & decrement (`++a`, `--a`, `a++`,
  `a--`). ✅ DONE.** Four new `HxExpr` constructors: `PreIncr`/`PreDecr`
  as `@:prefix` (declared before `@:prefix('-')` Neg — prefix branches
  dispatch in `tryBranch` declaration order with no longest-match sort,
  so `--` must precede `-` or `--a` folds to `Neg(Neg(a))`), and
  `PostIncr`/`PostDecr` as bare single-literal `@:postfix` (no close
  delimiter, no suffix child). The postfix shape required the **one
  approved core macro change**: `Lowering`'s postfix fold previously
  hard-`fatalError`'d on a single-child branch without a `(open,close)`
  pair (`ω-postfix-single-literal`); it now emits a real
  `left = Ctor(left)` body (the op literal is already consumed by the
  outer `matchExpr` dispatch, whitespace by the postfix loop wrapper's
  pre-dispatch `skipWs`). `WriterLowering` needed no change — its
  `children.length == 1` postfix arm already emits
  `_dc([operand, _dt(op + (close ?? ''))])`. `SpanTypeSynth` /
  `TriviaTypeSynth` needed no change (single-Ref postfix flows the
  generic paired-struct path, same shape as the prefix `Neg`/`Not`
  precedent). Longest-match collisions verified safe: infix `+`/`-`
  are in the separate Pratt loop (longest-sorted) and the postfix
  dispatch prepends `!peekLit(longerOp)` guards; prefix relies on the
  declaration-order placement. New `HxIncrDecrSliceTest` (pre/post
  ident, field-access compose, infix-binding, infix-`+`/`-` and
  prefix-`-` not-cannibalised regression guards, writer-form,
  round-trip); pre-existing `HxPrefixSliceTest.testDoubleNeg` updated
  to the spaced `- -a` form (the glued `--a` it used is now correctly
  `PreDecr`, not `Neg(Neg(a))`). Parse-rate **223/277 → 228/277 (+5
  corpus** — sole-blocker `DocMeasure` / `BlockCommentNormalizer` /
  `Scope` / `Selector` / `Span`, 54→49 fails). neko 4945 / js 4942 /
  interp 4945, 0 regressions.

- **Slice I — metadata on enum constructors (`enum E { @:kw('x')
  A; @:foo(1) B(p:Int); }`). ✅ DONE.** New `@:peg typedef
  HxEnumMember = { @:trivia @:tryparse var meta:Array<HxMetadata>;
  var ctor:HxEnumCtor; }`; `HxEnumDecl.ctors` now iterates
  `Array<HxEnumMember>`. The exact enum-body analog of Slice C's
  `HxAnonMember` (the `HxMemberDecl`↔`HxClassMember` split applied at
  the enum-ctor position) — zero core / synth / writer change (the
  generic paired-struct path + empty-`meta` transparency carry it,
  same as the `HxType.Anon → HxAnonMember` precedent). AST-contract
  shift: `ed.ctors[i]` is now `HxEnumMember`; `HxTestHelpers` grew
  `enumCtors(ed)` (projects `m.ctor`, mirror of `expectAnon`) +
  `enumMembers(ed)` (raw, mirror of `expectAnonMembers`);
  `HxForEnumVoidSliceTest` / `HxTopLevelSliceTest` route `.ctors`
  through `enumCtors`. Three new red-green cases
  (`testMetaCallBeforeSimpleCtor` / `testMixedMetaAndBareCtors` /
  `testNoMetaCtorStaysEmpty`). Parse-rate **228/277 → 246/278 (+17
  corpus** — every enum-grammar self-parse file: `HxModifier` /
  `HxDecl` / `HxType` / `HxExpr` / `HxStatement` / `HxParam` /
  `HxSwitchCase` / `JValue` / `SValue` / …, 49→32 fails; the new
  `HxEnumMember.hx` itself is the +1 to the file total). neko 4948 /
  js 4945 / interp 4948, 0 regressions. **Scope-estimate lesson:**
  the pre-build sed-strip ceiling (predicted single-digit) was a
  *gross under-estimate* — per-line strip masked multi-line `@:meta`
  and the all-`@:` over-strip created a false compounding picture.
  Enum-ctor metadata was the *sole* blocker for these grammar files
  (Slice C's `HxAnonMember` already covered anon-struct field metas).
  Confirms estimates are unreliable in *both* directions; only the
  post-build corpus measurement is truth.

- **Slice J — member-scope `#if` conditional compilation
  (`class C { #if sys function collect() {} #end }`). ✅ DONE.** New
  `@:peg typedef HxConditionalMember` (cond / body / elseifs / elseBody)
  + `HxElseifMember` twin, plus a `@:kw('#if') @:trail('#end')
  Conditional(inner:HxConditionalMember)` ctor on `HxClassMember`. The
  member-scope completion of the cond-comp arc — exact structural twin
  of `HxConditionalStmt` / `HxElseifStmt` (statement scope) with element
  type `HxMemberDecl`, the minimal shape WITHOUT the decl-scope
  import/using blank-line cascades (members carry their own
  `interMemberBlankLines` model; an import-ordering cascade has no
  meaning at member scope). Zero core / synth / writer change — the Star
  engine + `emitOptionalKwStarFieldSteps` + paired-struct synth carry
  it, same as the decl/stmt cond-comp precedent. One edit point covers
  class + interface + abstract (all three use `Array<HxMemberDecl>`). A
  member-level `#if` reaches the new ctor only after the pre-existing
  modifier-scope `HxMemberModifier.Conditional` is tried via the
  modifiers Star and rolls back on the member introducer keyword (same
  shared-`#if`, different-`@:trail` rollback as `PackageDecl` →
  `PackageEmpty`). `HxTestHelpers` grew `expectConditionalMember`
  (mirror of `expectFnMember`); ten red-green cases (single / then-plain
  / else / elseif / nested / no-cond-regression / Glob-dogfood /
  interface / abstract / empty-body-rejected). Parse-rate **246/278 →
  247/278 corpus-relative (+1, `Glob.hx` — the confirmed
  cond-comp-sole-blocker)**; total file count **246/278 → 249/280**
  (the two new grammar twins also self-parse, +2 num/denom). neko 5005 /
  js 5002 / interp 5005, 0 regressions. **Known limitation, shared
  verbatim with the decl-scope precedent:** an *empty* body
  (`#if cond #end`, zero members) is rejected, not accepted as a
  zero-element Star — `HxMemberDecl`'s empty meta/modifier prefix Stars
  consume nothing, then the mandatory `member:HxClassMember` field
  throws on the terminator before the tryparse Star rolls back.
  `HxConditionalDecl` behaves identically (`#if sys\n#end` at module
  scope throws `expected HxDecl`); member scope mirrors it rather than
  diverging. No real anyparse/dogfood source has an empty conditional
  member body. `testEmptyConditionalBodyRejectedLikeDeclScope` pins the
  actual contract via `Assert.raises(…, ParseError)` so a future
  decl-scope fix (a core Lowering tryparse-Star-of-struct rollback
  change spanning decl + stmt + member, out of additive-twin scope)
  updates all scopes consistently. **Recon lesson (reconfirmed):**
  post-build strip-test on the freshly rebuilt parser is the only
  truth — the cond-comp preprocess-proxy correctly predicted "+1 sole
  blocker" here; combined clean-additive ceiling (cond-comp + EReg +
  trailing-comma + hex) measured at 6/32, so no Slice-C/I-scale
  additive remains — the tail is heterogeneous with compounding
  blockers.

- **Slice K1 — named local function statement
  (`function g(){}` / `inline function g(){}` inside a body). ✅ DONE.**
  Two additive `HxStatement` ctors that reuse `HxFnDecl` (the exact
  payload of `HxClassMember.FnMember`, zero new grammar types):
  `@:kw('function') LocalFnStmt(decl:HxFnDecl)` and
  `@:kw('inline') @:lead('function') LocalInlineFnStmt(decl:HxFnDecl)`
  (the kw+lead single-Ref compose path, same as `HxDoWhileStmt`'s
  `@:kw('while') @:lead('(')`). Zero core / synth / writer change —
  same generic single-Ref `@:kw` path as the cond-comp `Conditional`
  ctor. An anonymous function expression `function() {}` /
  `function(x) e` has no name, so `HxFnDecl.name` fails on `(` and
  `tryBranch` rolls the consumed `function` keyword back to `ExprStmt`
  → `HxExpr.FnExpr` (shared-kw rollback, same as
  `SwitchStmt`/`SwitchStmtBare`). New `HxLocalFnStmtSliceTest` (9
  cases: plain / params+return / typeParams+bare-expr-body / inline /
  dogfood typed-inline-helper / nested / anon-assigned-rollback /
  anon-callarg-rollback / no-local-fn-regression), tests written from
  the probed `HxClassMember.FnMember` precedent contract. Parse-rate
  **247/278 → 250/278 corpus-relative (+3)**; total file count
  **249/280 → 252/280** (newly passing `Renderer.hx`,
  `BinaryChainEmit.hx`, `MethodChainEmit.hx`). neko 5036 / js 5033 /
  interp 5036, 0 regressions. **Strategic pivot:** fresh post-build
  recon contradicted the plan's proxy-ordered Slice K bundle —
  object-literal trailing comma was present in only 1/31 fail files
  (≈ +0, masked); the real dominant blockers are local-fn-stmt,
  `for (k => v in map)`, and multi-pattern `case A, B:`. User approved
  re-prioritising Slice K to the recon order; local-fn-stmt is the
  clean additive of the three and landed first. K2 = `for (k=>v)`,
  K3 = multi-pattern case — both lean core (`HxForStmt.varName` /
  `HxCaseBranch.pattern` shape changes), to be re-decided per
  sub-slice via a fresh fork. **Known pre-existing limitation
  (orthogonal, not a K1 regression):** an inline-call statement
  `inline foo();` is still rejected — `inline` was never a
  statement-start keyword and `ExprStmt` → `HxExpr` has no inline-call
  atom; `inline foo()` rolls back from `LocalInlineFnStmt` (no
  `function`) to `ExprStmt` exactly as before K1. A future additive
  HxExpr inline-call slice would close it.

**Design decision (do not re-attempt without new infrastructure):**
the flat one-line diagnostic renderers (`Text.renderRefs` /
`renderSearchMatches` / `renderMeta`) **stay on hand-rolled
`StringBuf`** and are NOT converted to the declarative writer. A full
attempt (commits d5579c7/6c833cc/70c9983, reverted in f98c8bd) proved
the writer intrinsically emits a softline space between every
adjacent struct field / array element; no `TextFormat` config
(`entrySep=''`, `tightLeads`, `spacedLeads`) suppresses it on the
required-field `@:lead` path, so a bespoke `path:line:col: [kind]
name` line cannot be produced byte-exactly. The JSON path
(`Ast*` schemas) and the tree S-expr path (`SValueWriter`) already
dogfood the writer; the line format is the writer model's boundary,
not a dogfood gap. Revisit only if the Doc pipeline gains a
no-separator (`Concat`) layout mode. See
`memory/feedback_anyparse_writer_intrinsic_field_space.md`.

**Exit condition**: friction log written, top three items addressed, indexing decision recorded with rationale.

## Phase 6: Universalization proof

**Goal**: prove the engine boundary by wiring a second grammar through the same code path.

**Deliverables**:
- Second grammar plugin (likely AS3 once Phase 4 of [main roadmap](roadmap.md) lands).
- Preset alias for the second grammar (`as3q`).
- All four commands working against the second grammar without engine changes.
- Cross-language smoke test: at least one `search` pattern that has the same semantic intent in both languages, run against both corpora, returns sensible results.

**Exit condition**: no engine code modified to support the second grammar. All commands work. Smoke test green.

## Non-goals across all phases

These remain out of scope until and unless explicit slices are scheduled:

- Rewriting / `--replace` / source modification.
- Type-based resolution of any kind.
- LSP / editor protocol.
- Incremental indexing across invocations.
- Cross-file dependency analysis.
- Project loader (`.hxml` parsing, classpath resolution).

When a future need pulls one of these in, it gets its own phase with its own design slice — not a backdoor extension of an existing phase.

## See also

- [cli-query-tool.md](cli-query-tool.md) — design baseline and spec.
- [roadmap.md](roadmap.md) — main anyparse roadmap.
- [architecture.md](architecture.md) — anyparse core architecture.
