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
- **F2 — anon Star is strictly `,`-separated in plain mode.**
  Histogram of the F1 bucket (fresh `bin/apq.n`, full `src/**/*.hx`,
  52/273 baseline): the #1 cause (99 files) is anonymous-structure
  types using class-notation fields (`{ var name:T; }`, `@:meta`
  prefixes). Grammar branches `HxAnonField.VarField`/`FinalField`
  landed (additive, +4 → 56/273, 0 regressions), but only the
  SINGLE-field case parses: `HxType.Anon`'s `@:sep(',')` Star
  hard-requires `,` in plain/fast mode (`Lowering.hx:1376-1389`),
  while the dominant schema shape is multi `;`-separated
  (`{ var a:T; var b:T; }`). Closing the bucket needs a **core
  Lowering change**: an opt-in dual `,`/`;` separator + optional
  trailing separator on the anon Star (drop `@:trail(';')` from the
  class-notation branches; `;` becomes the Star separator), plus the
  WriterLowering mirror. This invalidates the earlier "purely
  additive, no core change" estimate — the trivia-mode path
  (`Lowering.hx:1349`) is tolerant but both `HaxeParser` (Fast) and
  the span parser used by `apq` (`HaxeModuleSpanParser`, Tolerant) are
  non-trivia builds (`{trivia:false}`); the discriminator is
  `ctx.trivia`, orthogonal to the Fast/Tolerant axis, so neither hits
  the tolerant loop. High blast radius (the sep loop is generic across every
  `@:sep` Star), so the dual-sep behavior must be annotation-gated to
  `HxType.Anon`, not global. Decision pending before continuing the
  grammar-widening track.

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
