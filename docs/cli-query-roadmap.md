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

- **Slice K2 — map key-value `for (k => v in m)` iteration. ✅ DONE.**
  An optional `valueName` field added to BOTH `HxForStmt` and
  `HxForExpr`: `@:optional @:lead('=>') var valueName:Null<HxIdentLit>`
  between `varName` and the `in` keyword — the same
  optional-single-Ref-with-literal-commit pattern as
  `HxParamBody.defaultValue` (`@:optional @:lead('=')`) /
  `HxFnDecl.returnType` (`@:optional @:lead(':')`). **Recon reversed
  the pivot's "leans core" premise:** the single-ident→list framing was
  wrong; the optional-second-ident framing is the established additive
  opt-Ref pattern (zero core/synth/writer; synth/writer auto-handle
  optional-Ref per the `returnType` precedent), so it landed additively
  with no fresh fork needed (consistent-with-established-system, not a
  genuine core-vs-additive choice). Plain `for (v in m)` keeps
  `valueName == null` (the `=>` peek fails on `in`) — strict regression
  guard. `HxForExpr`'s own doc had pre-tracked this as a future slice.
  New `HxForKeyValueSliceTest` (8 cases: stmt kv / stmt single-null /
  block-body / nested / expr-comprehension kv / expr single-null).
  Parse-rate **250/278 → 252/278 corpus (+2)**; total **252/280 →
  254/280** (newly passing `StrategyRegistry.hx`, `TriviaAnalysis.hx`).
  neko 5059 / js 5056 / interp 5059, 0 regressions. Surfacing
  `valueName` as a second apq-refs scope binding is a separate,
  non-parse-blocking enhancement (deferred).

- **Slice K3 — multi-value `case A, B, C:` patterns. ✅ DONE.**
  `HxCaseBranch.pattern:HxExpr` reshaped to
  `patterns:Array<HxExpr>` with `@:sep(',') @:trail(':')` — the same
  Star+sep+trail Lowering path as `HxFnDecl.typeParams`; a single
  `case A:` is the one-element form. User-approved via the fresh
  additive-vs-core fork (Option A "clean Star" over Option B
  "additive opt-Star + `:`-relocation", which had an unprecedented
  `@:optional @:lead+@:sep`-without-`@:trail` mechanism). It is a
  shape change to an existing field, but the only consumer was
  `test/unit/HxSwitchNewSliceTest.hx` (3 `.pattern` switch sites →
  `.patterns[0]`); writer/synth/`HaxeQueryPlugin` use generic
  reflection (zero ripple — confirmed by the gate). New
  `HxMultiPatternCaseSliceTest` (7 cases: single-1-elem regression /
  two / three-string / multi+block-body / mixed multi+single+default /
  ctor-patterns). Parse-rate **252/278 → 254/278 corpus (+2)**; total
  **254/280 → 256/280** (newly passing `HxExprUtil.hx` — the file
  originally drilled to identify this blocker — and `query/Cli.hx`).
  js 5083 / interp 5086, 0 regressions (neko dropped from the gate
  per user directive #2 — "neko слишком медленный"; js = real codegen
  target, interp = macro-VM divergence catch).

  **Slice K arc complete.** Pivot recap: the inherited plan's
  proxy-ordered bundle (objlit-comma → EReg → hex) was contradicted
  by fresh post-build recon and replaced (user-approved) by the
  drill-identified order — K1 local-fn-stmt (+3), K2 for-(k=>v) (+2),
  K3 multi-pattern-case (+2). Net Slice K = **247/278 → 254/278
  corpus (+7; total 249/280 → 256/280)**, 0 regressions across all
  three sub-slices. K2 and K3 each had their "leans core" premise
  tested by recon — K2 collapsed to a precedented additive opt-Ref;
  K3 was a genuine but minimal-ripple shape change taken via the
  explicit fork. Remaining 24 fail files are the chronic macro/query
  cluster (offset-25 rollback to `#if macro`, heterogeneous deep
  blockers) — no clean additive of K1/K2/K3 scale remains.

- **Slice L — closing the 24-fail tail (NOT additive; core forks).**
  Full strip-drill of all 24 self-parse fails (rollback offset is the
  `#if macro` token, never the blocker — drill past it keeping braces
  balanced) produced the innermost-blocker histogram: trailing comma
  in collection literals **8**, `$`-reification in `macro` **5**, EReg
  literal `~/.../` **4**, `switch` `case … if (c):` guard **2**, bare
  `$` in single-quoted string **2**, singletons **3** (`macro`
  member modifier, untyped fn param, hex `0x20`).

  - **Slice L1 — trailing sep before close. ✅ DONE.** (commit
    `a95ba68`.) The strict plain-mode sep loops in `Lowering`
    (postfix-call args, Case-4 enum-Alt `ArrayExpr`, struct-field
    Star `HxObjectLit.fields`, optional Star `HxTypeRef.params`)
    consumed a sep then forced another element parse, rejecting the
    universally-valid Haxe trailing comma. User-approved Option A
    (universal core fix): `if (!($closeNotNextExpr)) break;` after
    each sep consume, mirroring the trivia-mode postfix loop. Parser-
    only, AST-shape preserved. **254/278 → 261/278 corpus (+7;
    total 256/280 → 263/280)**: FormatReader, Bin,
    HaxeFormatConfigLoader, HaxeQueryPlugin, query/Json, query/Meta,
    + SpanTypeSynth (drilled "untyped fn param" innermost was a
    compounding mis-ID — post-build is the only truth). WrapList /
    TriviaTypeSynth stay red on a deeper compounding blocker. Three
    stale `testRejectsTrailingComma` guards encoded the old (wrong-
    vs-Haxe) reject-contract and were flipped to
    `testAcceptsTrailingComma`. js 5108/5108, 0 regressions.

  - **Slice L2 — EReg regex literal `~/pattern/flags`. ✅ DONE.**
    (commit `acb7a64`.) User-approved (additive track, chosen over the
    core switch-guard slice). New `HxRegexLit` — exact mirror of
    `HxDoubleStringLit` (`@:re('~/(?:[^/\\\n]|\\.)*/[a-z]*')` +
    `@:rawString` + transparent `abstract(String) from String to
    String`) — plus one `HxExpr.RegexLit(v:HxRegexLit)` ctor declared
    before `@:prefix('~')` so `~/` is tried before bitwise-not. Zero
    Lowering/writer/synth change (generic raw-String single-Ref path).
    **261/278 → 262/278 corpus (+1: CFamilyCommentFormat; total
    263/280 → 265/281, the +1 denom is the new self-parsing
    `HxRegexLit.hx`)**. The histogram's EReg "4" was a drilled-
    innermost count, not a flip count — JsonFormat / SExprFormat /
    HaxeFormat carry EReg AND deeper compounding blockers (post-build
    truth — drilled-innermost is not a flip predictor).
    New `HxRegexLitSliceTest` (raw slice / flags / escaped slash /
    corpus pattern / `~y` bitwise-not regression / round-trip). js
    5121/5121 + interp 5124/5124 (interp run because the slice touches
    EReg — literal pattern, not `EReg.escape`, so the interp bug does
    not bite), 0 regressions.
  - **Slice L3 — `macro` member modifier + hex literal bundle. ✅
    DONE.** (commit `6561bb8`.) The last clean additive of the tail
    (the user's option-2 at the L2 fork); pure additive, no core
    fork. Two zero-ripple grammar extensions: (a) `@:kw('macro')
    Macro;` added to `HxMemberModifier` (flat keyword enum, sibling
    of `Inline`/`Extern`) — the macro-function modifier (`public
    static macro function`), member-position only, deliberately NOT
    in `HxModifier` (`macro class`/`macro typedef` are invalid Haxe);
    (b) new `HxHexLit` — exact mirror of `HxRegexLit`
    (`@:re('0[xX][0-9A-Fa-f]+')` + `@:rawString` + transparent
    `abstract(String) from String to String`) — plus one
    `HxExpr.HexLit(v:HxHexLit)` ctor declared before `IntLit` so
    `0x20` is not split by the `[0-9]+` integer terminal. Zero
    Lowering/writer/synth change (generic raw-String single-Ref path,
    no hand-switch over either enum's ctors). **262/278 → 263/278
    corpus (+1: `query/Text.hx` flipped via hex; total 265/281 →
    267/282, the +1 denom is the new self-parsing `HxHexLit.hx`)**.
    Honest delta note: `Build.hx` did NOT flip despite `macro` being
    its drilled-innermost blocker — it is in the compounding
    `$`-reification/`macro` cluster and a deeper blocker (`error at
    25: expected HxDecl`) surfaced. The grammar gap is genuinely
    closed; histogram drilled-innermost is not a flip predictor (the
    documented lesson, confirmed both directions again). New
    `HxMacroModHexSliceTest` (8 methods: lowercase/uppercase hex,
    decimal/zero/float regression, round-trip, bare + Build-shape
    `macro` modifier). js 5142/5142 + interp 5145/5145 (interp run as
    the slice adds a new `@:re` terminal; literal pattern, interp bug
    does not bite), 0 regressions.

  - **Slice L4 — macro `$`-reification expression escapes. ✅ DONE.**
    (commit `70561fd`.) Recon **reframed the inherited "CORE" label**:
    `$x` / `${expr}` / `$i{}`-style escapes are an additive
    expression-position mirror of the existing `HxStringSegment`
    interpolation grammar (`Block`/`Ident`), not a Pratt/Lowering
    fork — the documented "recon can reverse inherited leans-core"
    pattern (opposite of L2's switch-guard). Three new `HxExpr` ctors,
    declared so `tryBranch` resolves the shared `$` prefix:
    `DollarBlockExpr` (`@:lead("${") @:trail("}")` + `HxExpr`),
    `DollarReifExpr` (`@:lead("$") @:trail("}")` wrapping the new
    `HxDollarReif` typedef — `name` ident then `@:lead("{")` recursive
    `HxExpr`, exact `NewExpr`/`HxNewExpr` ctor-wraps-typedef shape),
    `DollarIdentExpr` (`@:lead("$")` + ident). The first attempt put
    `@:lead("{")` inline on an enum-ctor param — Haxe rejects metadata
    there (`Unexpected @`); pivoting the brace lead onto a typedef
    field (where `HxVarDecl` already precedents it) fixed it with no
    core change. Zero Lowering/writer/synth edits, no hand-switch over
    `HxExpr` ctors in `src/`. **263/278 → 263/278 corpus (no flip);
    total 267/282 → 268/283** — the +1 num/denom is the new
    `HxDollarReif.hx` self-parsing. Honest delta: **gap closed but not
    a sweep-mover** — every `$`-reification cluster file (`Lowering`,
    `WriterLowering`, `Codegen`, …) compounds on `macro : Type` type
    reification (Codegen 34 / WriterCodegen 102 occurrences) plus
    deeper blockers, so none flips on `$`-reification alone. `macro :
    Type` is the next distinct sibling slice (cross-type Ref to
    `HxType`, the `is`-operator precedent). New `HxDollarReifSliceTest`
    (9 methods: each escape shape, `tryBranch` disambiguation,
    `$type(e)` postfix, `macro $x` nesting, plain-ident regression,
    round-trip). js 5179/5179, 0 regressions (interp not needed — no
    `@:re` terminal added).
  - **Slice L5 — macro `: Type` type-reification expression. ✅ DONE.**
    (commit `656c947`.) Recon **reversed the inherited "CORE" label**
    again (the L4 pattern, opposite of L2's switch-guard): `macro :
    Type` is one additive `HxExpr` atom ctor, `@:kw('macro')
    @:lead(':') MacroTypeExpr(t:HxType)`, declared before `MacroExpr`
    so `tryBranch` resolves the shared `macro` keyword (`macro :` →
    `MacroTypeExpr`, anything else → `MacroExpr`). It is an asymmetric
    cross-type Ref (right operand is `HxType`, not `HxExpr`) but flows
    through the generic single-Ref atom path the same way
    `MacroExpr(operand:HxExpr)` and `HxArrowParamBody.type:HxType` do —
    `is`-operator's asymmetric special-casing is INFIX-recursion-only,
    not needed for an atom. No typedef wrapper needed (single `HxType`
    field, no per-param metadata, unlike L4). Zero Lowering / writer /
    synth edits, no hand-switch over `HxExpr` ctors in `src/`. **263/278
    → 263/278 corpus (no flip); total 268/283 → 268/283 (no
    num/denom change — no new self-parsing file)**. Honest delta: **gap
    closed but not a sweep-mover, the 4th slice running** — probes
    confirm `macro : Int` / `macro : Array<String>` / `macro : Int ->
    Void` now parse with correct `tryBranch` disambiguation (`macro a
    + 1` stays `MacroExpr`, `macro { a; }` stays a block), but every
    cluster file (`Codegen`, `WriterCodegen`, `Lowering`, …) compounds
    on the remaining core blockers (switch-guard, bare-`$`
    single-quote, untyped fn param), so none flips on `macro : Type`
    alone. The pre-slice freq probe predicted the flat sweep; the
    dogfood-conceptual value (the macro pipeline's type-reification
    syntax now parses) is real and separate from the sweep number. New
    `HxMacroTypeExprSliceTest` (9 methods: simple / parametrized / map
    / function / anon type shapes, `macro a+1` and `macro {…}`
    regressions, `macro macro : Int` nesting, round-trip). js
    5199/5199, 0 regressions (interp not needed — no `@:re` terminal
    added).
  - **Slice M — switch-guard `case P if (cond):`. ✅ DONE.**
    (commit `e7479a9`.) Recon **reversed the inherited "CORE" label**
    a 3rd time (the L4/L5 pattern; L2 had confirmed CORE only for the
    *direct-mutation* shape — mutating `HxCaseBranch` itself hits two
    `Lowering` fatalErrors: a `@:sep` Star requires `@:trail`;
    `@:optional` + `@:trail` on a Ref is deferred). The **element-wrap**
    shape sidesteps every ban: `HxCaseBranch.patterns` keeps
    `@:sep(',') @:trail(':')` unchanged, only the element type widens
    `HxExpr` → new `@:peg typedef HxCasePattern = { var expr:HxExpr;
    @:optional @:kw('if') var guard:Null<HxExpr>; }` (K3
    element-widening precedent). The guard is the `@:optional
    @:kw('else')` word-keyword shape of `HxIfStmt.elseBody` /
    `HxIfExpr.elseBranch` — `@:kw` (word-boundary `matchKw`, D47), NOT
    `@:lead` (raw `matchLit`): caught in file-review, `case iffy:` must
    not be read as guard `if y`. Zero core / Lowering / writer / synth
    (generic optional-Ref keyword path, the same that emits ` else …`).
    Haxe binds one guard to the whole list → it attaches to the last
    parsed element; `case A, B if (c):` round-trips byte-identically.
    **Breaks the gap≠sweep streak (first L-arc tail slice to move the
    sweep): src self-parse 268/283 → 271/284** (+1 denom = new
    self-parsing `HxCasePattern.hx`; **+2 real flips: `MetaInspect` +
    `strategy/Pratt`** — the exact files the recon strip-drilled, which
    did NOT compound, unlike L3/L4/L5's predicted files; switch-guard
    was their genuine sole/innermost blocker). Corpus fixtures unchanged
    263/278 (no fixture exercises switch-guard). Fails 15 → 13. New
    `HxSwitchGuardSliceTest` (7 methods: guard present / absent,
    multi-pattern last-element binding, call-pattern guard,
    ternary-inside-guard `:` disambiguation, K3 non-guard regression,
    round-trip). js `test-js.hxml` ALL TESTS OK 5229/5229, 0
    regressions (interp not needed — no `@:re` terminal added).
  - **Slice N — lone `$` in single-quoted string. ✅ DONE.**
    (commit `0040804`.) Recon **reversed the inherited "CORE
    single-quote interp scan" label a 5th time** (the L4/L5/M
    additive-reversal pattern). The single-quote string grammar had
    no branch for a literal `$` that is NOT `$$`, `${`, or `$ident`
    — real Haxe treats such a `$` as a literal dollar (`'$'`,
    `'$ '`, `'$5'`, `'$'.code`). The fix is a segment-level enum
    branch that sidesteps the `HxStringLitSegment` regex entirely:
    one new zero-arg ctor `@:lit("$") LoneDollar;` declared LAST in
    `HxStringSegment` (tryBranch fallthrough after `Ident` so `$$`
    still binds `Dollar`, `${` `Block`, `$name` `Ident`). Exact
    twin of the sibling `Dollar` (`@:lit("$$")`) — generic `@:lit`
    codegen path, zero core / Lowering / writer / synth (the
    `HxFnBody.NoBody` `@:lit(';')` writer precedent; no exhaustive
    hand-switch over `HxStringSegment` ctors anywhere in `src/`).
    Double-quoted `@:lit("$")` per the metadata-interpolation
    gotcha. **2nd consecutive L-tail sweep-mover after Slice M:
    src self-parse 271/284 → 273/284** (+2 real flips:
    `query/Matcher.hx` + `query/Pattern.hx` — bare-`$` was their
    TRUE sole-blocker with no compounding, so the recon strip-drill
    predicted the flip; denom unchanged, `HxStringSegment.hx`
    pre-existing). Corpus unchanged 263/278 (no fixture exercises
    lone-`$`). Fails 13 → 11. New `HxStringSliceTest` methods (7:
    alone / then-space / then-digit / mixed, `$name` & `$$`
    ordering regressions, `'$'.code` round-trip). js `test-js.hxml`
    ALL TESTS OK 5247/5247, 0 regressions (interp not needed — no
    `@:re` terminal added).

  - **Query-value validation pass (dogfood). ✅ DONE (all 3 gaps
    closed).** A
    decisive battery (`hxq ast/refs/search/meta` over a probe
    exercising every L1–N construct + real grammar/macro files +
    whole-`src` robustness sweep) confirmed the L1–N arc is
    **parse-robust** (273/284, zero crashes/segfaults across all 284,
    all 11 unparseable files degrade cleanly EXIT 0) and that
    `refs`/`search` deliver real query-value — BUT surfaced that
    **parse-rate ≠ query-value**: the decoupling is worst exactly
    where parse-rate gained most. Three concrete gaps, the
    `HaxeQueryPlugin` contract never co-evolved with the grammar
    twins that raised parse-rate:
    - **#2 — `++`/`--` write classification. ✅ DONE** (commit
      `6f465ed`). Slice H added `PreIncr/PreDecr/PostIncr/PostDecr`
      to `HxExpr` but `RefShape.writeParentKinds` was never extended;
      `apq refs <v> --writes` misclassified `x++`/`--x` as `[read]`
      and returned 0 writes for an only-incremented binding (stale
      comment falsely claimed "Haxe has no ++/--"). Fix: 4 ctors
      added to `writeParentKinds` + comment rewrite; `Refs.walk`
      child-0 propagation already handles single-operand ctors (no
      `Refs.hx` change). Parser-neutral — **sweep flat 273/284,
      corpus 263/278**; this is a query-value fix, NOT a sweep-mover.
      New `ApqRefsIncrDecrSliceTest` (4/4); js `test-js.hxml`
      5258/5258 ALL TESTS OK, 0 reg.
    - **#1a — `meta` blind to enum-ctor annotations. ✅ DONE**
      (commit `e0f300f`). `DECL_HOST_KINDS` lacked
      `SimpleCtor`/`ParamCtor`; `hxq meta @:kw <grammarfile>`
      returned 0 hits despite real enum-ctor `@:kw` (Slice I locus,
      +17 parse). Fix = 2 ctor strings added to the shared
      `DECL_HOST_KINDS` + doc-comment; the `MetaCall`+ctor nodes were
      already flattened spanned siblings so `Meta.followingDeclHost`
      resolves once the kind is a host (no `Meta.hx` change). Shared
      array also makes `refs <Ctor>` see the enum ctor as a Decl —
      intended bonus, zero regressions. Parser-neutral — **sweep flat
      273/284, corpus 263/278**. `meta @:kw` on `HxStatement.hx` now
      16/16 (was 0). New `ApqMetaEnumCtorSliceTest` (4/4); js
      5270/5270 ALL TESTS OK, 0 reg (Slice #2 intact).
    - **#1b — `meta`/`refs` blind to anon-field members. ✅ DONE**
      (commit `d4b5cdb`). `appendNodes` unconditionally skipped the
      struct field named `type`, so a typedef's anon body
      (`HxType.Anon` members + metadata, Slice C locus +83) surfaced
      with `children:[]`. Fix = new `isAnonType(v)` gate: descend
      `type` only when it is an `HxType.Anon` enum (both skip sites;
      spanned-branch restructured, proven field-equivalent + the
      Anon exception) — `HxType` is an enum so `Named`/`Arrow`/
      `Parens`/`ArrowFn` type-refs stay skipped (no phantom child
      per typed binding, guarded by a dedicated test) + add
      `VarField/FinalField/FnField` to `DECL_HOST_KINDS` (bare
      `Required`/`Optional` anon forms reuse the existing HxParam
      entries). Generic gate also surfaces anon-in-var-hint members
      — a correct bonus, not typedef-special-cased. Parser-neutral —
      **sweep flat 273/284, corpus 263/278**; probe `TypedefDecl`
      now `Anon→[@:m1, VarField f, @:m2, FnField g]`; `meta @:lead`
      over `src` 0→86 lines, crash-free whole-tree. New
      `ApqMetaAnonFieldSliceTest` (7/7); js 5282/5282 ALL TESTS OK,
      0 reg (#2/#1a intact).
    - **#3 — `search` rejected bare stmt/expr patterns with a
      trailing `;`. ✅ DONE** (commit `a2cccb6`). `return $_;` /
      `trace($_);` → EXIT 1 "expected HxDecl". Executed-probe recon
      (not the inherited "fallback doesn't reach switch-stmt" label):
      `wrapAsStmt`/`wrapAsExpr` append their own `;`, so a user
      trailing `;` makes `…;;`, which the Haxe grammar rejects (no
      empty-statement production) — every cascade attempt fails and
      the `bestError ??` idiom leaks the FIRST (decl) attempt's
      meaningless wrapper-offset error. Fix = new
      `trimTrailingSemicolons` scoped to the two wrappers (the
      unwrapped decl attempt keeps the source so `typedef X = Y;`
      patterns still parse) + total-failure throw replaced with an
      actionable category-list message + dead `bestError` removed.
      `switch $_ { $_ }` is genuinely invalid Haxe (switch body needs
      `case`) — now rejected with the clear message, not the leaked
      decl error; `switch $_ { case $_: $_; }` parses fine.
      Parser-neutral — **sweep flat 273/284, corpus 263/278**. New
      `PatternParseProbe` +4 red-green methods; js 5282 → 5291
      assertions, 0 failures, ALL TESTS OK, 0 reg (#2/#1a/#1b
      intact). Validation arc closed — all recorded query-value gaps
      addressed.

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
