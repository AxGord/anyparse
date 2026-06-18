package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using anyparse.macro.MetaInspect;

/**
 * ω₄c — Atomic synthesis of paired `*T` typedefs / enums for
 * trivia-bearing grammar rules.
 *
 * Every rule that `TriviaAnalysis` marked with `trivia.bearing = true`
 * gets a sibling type suffixed `T`, placed in a dedicated synth module
 * at `<rootPack>.trivia.Pairs`. The synthesised types mirror the
 * originating rules structurally with three mechanical rewrites:
 *
 *  1. `Ref` fields/args whose target is itself bearing switch to the
 *     target's `*T` variant — non-bearing refs (e.g. `HxExpr`,
 *     `HxIdentLit`) stay unchanged.
 *  2. `Array<T>` containers whose Star carries `trivia.starCollects`
 *     wrap the element type in `anyparse.runtime.Trivial<…>` so the
 *     element's source-fidelity trivia (leading comments, blank-line
 *     marker, trailing comment) sits alongside the wrapped node.
 *  3. `Null<T>` wrapping + `@:optional` meta are preserved so downstream
 *     struct-literal construction in Trivia-mode Lowering compiles
 *     against the same surface the Plain-mode code compiles against.
 *
 * **Why atomic `defineModule`, not per-type `defineType`?** The grammar
 * reference graph is cyclic — `HxStatementT` references `HxIfStmtT`
 * which references `HxStatementT`. `defineType` eagerly type-checks
 * each TypeDefinition's field types on insertion, so the first call
 * fails the moment it encounters a sibling reference that hasn't been
 * registered yet. `Context.onTypeNotFound` was investigated as the
 * cycle-safe alternative but empirically does **not** fire for
 * references discovered during typing of a callback-returned
 * TypeDefinition — Haxe only consults the hook for the initial
 * top-level lookup. `defineModule` takes the whole batch at once and
 * types them as a single compilation unit, so within-batch cycles
 * resolve naturally.
 *
 * **Access path.** Each synthesised type's canonical name becomes
 * `<rootPack>.trivia.Pairs.<Leaf>T` — sub-module reference through
 * the synth module. Consumers import via
 * `import anyparse.grammar.haxe.trivia.Pairs.HxModuleT;` (direct
 * short-name alias) or `import anyparse.grammar.haxe.trivia.Pairs;`
 * followed by `Pairs.HxModuleT`. The separate subpackage keeps the
 * original grammar package free of generated artefacts.
 *
 * `arm(shape)` is called from `Build.buildParser` after
 * `TriviaAnalysis.run` when `ctx.trivia` is true. Repeated calls with
 * the same `ShapeResult` are idempotent — the per-name `defined` map
 * short-circuits already-synthesised types. A future second trivia
 * grammar would get its own synth module under its own root pack.
 *
 * See `feedback_definetype_cycles.md` for the rolled-back ω₄b attempt
 * and the `onTypeNotFound` probe that led to this pivot.
 */
class TriviaTypeSynth {

	/**
	 * ω-issue-316 — suffixes for kw-trivia sibling slots synthesised on
	 * paired Seq types alongside `@:optional @:kw(...)` Ref fields.
	 * Exposed so `Lowering` and `WriterLowering` can reference the same
	 * names without risk of silent divergence.
	 */
	public static inline final AFTER_KW_SUFFIX: String = 'AfterKw';

	public static inline final KW_LEADING_SUFFIX: String = 'KwLeading';

	/**
	 * ω-keep-policy — two additional source-shape slots captured
	 * alongside `AfterKw` / `KwLeading` for the same `@:optional @:kw(...)`
	 * Ref fields. `BeforeKwNewline` records whether the source had a
	 * newline between the preceding token and the keyword (consumed by
	 * `sameLineSeparator`'s `Keep` branch). `BodyOnSameLine` records
	 * whether the body's first token followed the keyword on the same
	 * line (consumed by `bodyPolicyWrap`'s `Keep` branch). Both default
	 * to `false` on the commit-miss path.
	 */
	public static inline final BEFORE_KW_NEWLINE_SUFFIX: String = 'BeforeKwNewline';

	public static inline final BODY_ON_SAME_LINE_SUFFIX: String = 'BodyOnSameLine';

	/**
	 * ω-trivia-before-kw — own-line comments captured BEFORE the optional
	 * keyword commit point (e.g. `if (x) { }\n// comment\nelse { }`). The
	 * pre-commit `skipWs` previously discarded this trivia; the new path
	 * collects it and stashes here on commit-success. Empty array on the
	 * commit-miss path (rewind discards the captured trivia).
	 */
	public static inline final BEFORE_KW_LEADING_SUFFIX: String = 'BeforeKwLeading';

	/**
	 * ω-trivia-before-kw-trailing — same-line trailing comment captured
	 * BEFORE the optional keyword commit point but ON THE SAME LINE as the
	 * preceding sibling's last token (e.g. `resize(); // first\nelse`).
	 * Differs from `BeforeKwLeading` (own-line comments separated by `\n`):
	 * `BeforeKwTrailing` is a single comment on the same line as the prior
	 * `;`, captured via `collectTrailing` (single comment, no internal
	 * newline). Stripped body, line-style only by construction. Writer
	 * emits as ` //<body>` cuddled to the previous token before the
	 * pre-kw hardline. `null` on the commit-miss path or when the source
	 * has no same-line comment between the prior sibling and the keyword.
	 */
	public static inline final BEFORE_KW_TRAILING_SUFFIX: String = 'BeforeKwTrailing';

	/**
	 * ω-trivia-after-trail — same-line trailing comment captured immediately
	 * AFTER a mandatory Ref field's `@:trail(LIT)` literal (e.g.
	 * `if (cond) // afterCond\n\tbody` — the `// afterCond` cuddles to the
	 * `)`). Synthesised on Ref fields carrying `@:trail` in trivia-bearing
	 * rules. The next sibling field (typically a bodyPolicy-wrapped Ref)
	 * reads `value.<priorField>AfterTrail` and threads it into the body's
	 * leading separator so the comment survives round-trip. `null` when the
	 * source had no same-line comment after the trail literal.
	 */
	public static inline final AFTER_TRAIL_SUFFIX: String = 'AfterTrail';

	/**
	 * ω-issue-48-v2 — source-shape slot synthesised on paired Seq types
	 * alongside bare non-first Ref fields (no `@:optional`, no `@:kw`, no
	 * `@:lead`). Records whether the source had a newline in the gap
	 * between the preceding content and the sub-rule's first token.
	 * Consumed by the writer's inter-field separator so that
	 * `@:allow(...)\n\tvar x` round-trips with the newline intact even
	 * when the member's `modifiers` Star is empty — the first element of
	 * that empty Star cannot carry the `newlineBefore` signal, so the
	 * parser drains the stashed trivia here instead.
	 */
	public static inline final BEFORE_NEWLINE_SUFFIX: String = 'BeforeNewline';

	/**
	 * ω-598-member-leading-comment — sibling source-shape slot synthesised on
	 * paired Seq types alongside the same bare non-first Ref fields that grow
	 * `BeforeNewline` (`isBareNonFirstRef`). Records the verbatim comments
	 * captured in the gap between the preceding content and the sub-rule's
	 * first token — the run that `BeforeNewline`'s `collectTrivia` scans but
	 * whose `.leadingComments` was previously discarded (only the
	 * `.newlineBefore` bool was kept). Load-bearing for
	 * `lineends/issue_598_multiline_comment_var`: a multiline block comment
	 * between a member modifier (`public`) and the `var` keyword is rejected
	 * by the modifier Star's `collectTrailingFull` (internal newline) and
	 * lands in this gap with no slot — dropped at parse. Empty array (the
	 * common case, including the empty-modifiers path where the comment is
	 * captured upstream) is byte-inert at write time. Consumed by the
	 * writer's bare-Ref non-first inter-field separator.
	 */
	public static inline final BEFORE_LEADING_SUFFIX: String = 'BeforeLeading';

	/**
	 * ω-cond-comp-expr-multiline — source-shape slot synthesised on
	 * paired Seq types alongside bare-Ref fields that carry
	 * `@:fmt(captureSourceNewlineAfter)`. Records whether the source
	 * had a newline immediately AFTER this field's last token (and
	 * before the next outer sibling — typically the parent ctor's
	 * `@:trail` literal).
	 *
	 * Sister to `BeforeNewline` (which captures the gap BEFORE the
	 * field's first token); together they let a bare-Ref field
	 * source-shape its own pad-trailing boundary regardless of
	 * which downstream sibling owns the visible token. Consumed by
	 * `WriterLowering.padTrailingDoc`'s `collectFollowingNewlineSignals`
	 * walker as a terminal-fallback signal (no guard) — fires only
	 * when every preceding signal in the chain falls through (all
	 * downstream optional siblings are absent).
	 *
	 * Currently consumed by `HxConditionalExpr.expr`'s `expr → '#end'`
	 * boundary when both `elseifs` is empty AND `elseExpr` is absent.
	 */
	public static inline final NEWLINE_AFTER_SUFFIX: String = 'NewlineAfter';

	/**
	 * ω-condition-wrap-keep — source-shape slot synthesised on paired Seq
	 * types alongside the mandatory-Ref condition field of a `@:fmt(condWrap)`
	 * struct (`HxIfStmt.cond` / `HxWhileStmt.cond`) that opts in via
	 * `@:fmt(captureCondOpenNewline)`. Records whether the source placed a
	 * newline right AFTER the condition's open paren `@:lead('(')` and before
	 * the cond's first token (`if (\n\tcond` vs `if (cond`). Read by the
	 * single-Ref condWrap emit in `WriterLowering`, which threads it into
	 * `WrapList.emitCondition`'s `sourceOpenNewline` arg so a `WrapMode.Keep`
	 * condition reproduces the author's post-`(` break verbatim.
	 *
	 * Sister to `NewlineAfter` (which captures the gap AFTER a bare-Ref
	 * field's last token); this captures the gap AFTER the field's lead
	 * literal. Plain mode keeps the original struct shape (no slot); the
	 * writer falls back to the width-driven glue.
	 */
	public static inline final CONDITION_OPEN_NEWLINE_SUFFIX: String = 'CondOpenNewline';

	/**
	 * ω-orphan-trivia — suffixes for trailing-trivia sibling slots
	 * synthesised on paired Seq types alongside `@:trivia` Star fields.
	 * `TrailingLeading` carries the own-line comments captured AFTER
	 * the last element and BEFORE the close (or EOF); `TrailingBlankBefore`
	 * records whether the captured run crossed a blank line so the writer
	 * can reproduce the source's vertical separation between the final
	 * member and the orphan comments.
	 */
	public static inline final TRAILING_BLANK_BEFORE_SUFFIX: String = 'TrailingBlankBefore';

	public static inline final TRAILING_LEADING_SUFFIX: String = 'TrailingLeading';

	/**
	 * ω-keep-fnsig-newline — suffix for a `Bool` flag recording whether the
	 * source placed at least one newline between the last `@:trivia` Star
	 * element and the close literal (`param7:Int\n)` vs `param7:Int)`).
	 * Sibling of `TrailingBlankBefore` (which records a BLANK line — 2+
	 * newlines), captured from the same terminal `_lead.newlineBefore` at the
	 * Star's close-peek. Consumed ONLY by `triviaSepStarExpr`'s `_keepEmit`
	 * close-placement: under a kept function signature, the close `)` breaks
	 * onto its own line iff the author put a newline there, so a kept
	 * signature round-trips both `param7:Int)` (glued — e.g.
	 * `wrapping_of_function_signature_keep`) and `\n\t):FastMatrix3` (own line
	 * — e.g. `issue_238_keep_wrapping_function_signature`). Synthesised
	 * unconditionally alongside `TrailingBlankBefore` so the slot arity stays
	 * in lockstep (struct field, name-matched — no positional ctor risk).
	 * Default `false` (no newline before close) for every non-keep / non-
	 * bearing consumer — byte-inert.
	 */
	public static inline final TRAILING_NEWLINE_BEFORE_SUFFIX: String = 'TrailingNewlineBefore';

	/**
	 * ω-close-trailing — suffix for the same-line trailing comment
	 * captured immediately after a `@:trivia` Star's close literal.
	 * Synthesised only for close-peek Stars (those with `@:trail`);
	 * EOF-mode Stars have no close to trail, and `@:trivia + @:tryparse`
	 * already rejects `@:trail` at compile time. `Null<String>` — `null`
	 * when the source had no same-line comment after the close.
	 */
	public static inline final TRAILING_CLOSE_SUFFIX: String = 'TrailingClose';

	/**
	 * ω-open-trailing — suffix for the same-line trailing comment
	 * captured immediately after a `@:trivia` Star's open literal
	 * (e.g. `{ // foo` before the first element). Mirror of
	 * `TrailingClose`. Synthesised only for Stars that carry `@:lead`
	 * (the open delimiter); bare Stars have no open lit to trail.
	 * `Null<String>` — `null` when the source had no same-line comment
	 * after the open. Captured via `collectTrailing` so the body has its
	 * delimiters stripped (line-style only, by construction — internal
	 * newline disqualifies the match).
	 */
	public static inline final TRAILING_OPEN_SUFFIX: String = 'TrailingOpen';

	/**
	 * ω-trail-blank-after — suffix for a `Bool` flag recording whether
	 * the source had a blank line between an orphan trail comment and the
	 * next outer-Star sibling (e.g. `case A: // X\n\n case B:`). Set by
	 * the tryparse+nestBody catch path when the failed-element trivia
	 * carried `blankAfterLeadingComments`; consumed by
	 * `triviaTryparseStarExpr` to emit an extra hardline after the trail
	 * Doc so the blank survives round-trip. Synthesised only for Stars
	 * that combine `@:tryparse` with `@:fmt(nestBody)` — currently
	 * `HxCaseBranch.body` and `HxDefaultBranch.stmts`. Other tryparse
	 * shapes either rewind on failure (no trail capture path) or have no
	 * nestBody wrap (no body-vs-parent indent distinction).
	 */
	public static inline final TRAILING_BLANK_AFTER_SUFFIX: String = 'TrailingBlankAfter';

	/**
	 * ω-objectlit-source-trail-comma — suffix for a `Bool` slot recording
	 * whether the source had a separator (e.g. trailing `,`) after the
	 * last element of a `@:trivia` sep-Star with a close literal. Set by
	 * the parser's per-iteration `matchLit(sepText)` capture; consumed by
	 * the writer's `WrapList.emit` call as a `forceExceeds` flag so that
	 * source-trailing-comma + an opt-in `@:fmt(trailingComma(...))` knob
	 * forces the wrap cascade into break-mode (typically `OnePerLine`),
	 * round-tripping the source's "I want this list multi-line" intent.
	 * First consumer: `HxObjectLit.fields`.
	 *
	 * Dual consumer (Session 14 Phase 2 scaffold,
	 * `buildStructFieldTrailPresentSlot`): struct typedef Ref fields with
	 * `@:trailOpt(LIT)` reuse the same suffix on an `@:optional Null<Bool>`
	 * slot. Both consumers encode "trail literal was present in source";
	 * disjoint host kinds (Star vs Ref) within one Seq cannot collide on
	 * field name. Until Phase 4 wires the writer, the Phase 2 consumer's
	 * slot is omitted from struct literals (no `Lowering` touch) and reads
	 * `null` at runtime.
	 */
	public static inline final TRAIL_PRESENT_SUFFIX: String = 'TrailPresent';

	/**
	 * ω-condcomp-body-leading-sep — suffix for a `Bool` slot recording
	 * whether the source had a leading separator INSIDE a `@:sep+@:tryparse`
	 * (no-trail) Star body, between the enclosing keyword and the first
	 * body element. Set by `Lowering.emitStarFieldSteps`'s pre-loop
	 * sep-peek; consumed by `WriterLowering.emitWriterStarField`'s
	 * padLeading branch as a runtime gate that swaps the leading-pad
	 * `_dt(' ')` for `_dt(', ')`. Synthesised only for Stars opting in via
	 * `@:fmt(sepBeforeOpt)` (which additionally REQUIRES `@:fmt(padLeading)`
	 * and a `@:sep + @:tryparse` no-trail shape); other Stars skip the
	 * slot. First consumer: `HxConditionalParam.body` (Slice 18f,
	 * `whitespace/issue_582_type_hints_conditionals`).
	 *
	 * Limitation: an empty body (`#if X, #end`) drops the leading sep at
	 * write time because the padLeading branch's empty-array short-circuit
	 * returns `_de()` before any push runs. No corpus fixture exercises
	 * the empty-body-with-leading-sep shape; rejected by parser-side rewind
	 * as well (the body Star's first iter would have to fail on `#end`
	 * AFTER the leading sep was consumed — rare and harmless).
	 */
	public static inline final SEP_BEFORE_SUFFIX: String = 'SepBefore';

	/**
	 * ω-trailopt-source-track — positional arg name appended to paired
	 * Alt ctors that carry `@:trailOpt(...)`. The parser's `matchLit`
	 * result lands here so the writer can gate trail emission on source
	 * presence (`true` → emit literal; `false` → omit). Plain mode keeps
	 * the original ctor arity and falls back to AST-shape gates such as
	 * `@:fmt(trailOptShapeGate(...))`. First consumers: `HxDeclT.TypedefDecl`
	 * and `HxDeclT.VarDecl` (top-level) plus `HxStatementT.VarStmt` /
	 * `FinalStmt` (function-body locals).
	 */
	public static inline final TRAIL_PRESENT_ARG_NAME: String = 'trailPresent';

	/**
	 * ω-string-interp-noformat — positional arg name appended to paired
	 * Alt ctors that carry `@:fmt(captureSource)`. The parser captures the
	 * input slice between the ctor's `@:lead` and `@:trail` literals here
	 * so the writer can emit it verbatim under
	 * `opt.formatStringInterpolation == false`. First (and currently only)
	 * consumer: `HxStringSegmentT.Block` for `${expr}` interpolation.
	 */
	public static inline final SOURCE_TEXT_ARG_NAME: String = 'sourceText';

	/**
	 * ω-issue-257-firstline — positional arg name appended to paired Alt
	 * ctors carrying `@:fmt(bodyPolicy(...))` on a single-Ref kw-led
	 * branch (e.g. `HxStatementT.ReturnStmt`). The parser captures
	 * whether the body's first token followed the keyword on the same
	 * source line so `bodyPolicyWrap`'s `Keep` branch can pick between
	 * `sameLayoutExpr` and `nextLayoutExpr` at writer time — the ctor-
	 * level mirror of the struct-field `<field>BodyOnSameLine` slot.
	 * Plain mode keeps the original ctor arity (no slot, default Same
	 * layout via `widthAware`). First consumer: `HxStatementT.ReturnStmt`.
	 */
	public static inline final BODY_ON_SAME_LINE_ARG_NAME: String = 'bodyOnSameLine';

	/**
	 * ω-paren-wrap-source-newline — positional arg name appended to paired
	 * Alt ctors carrying `@:fmt(captureWrapOpenNewline)` on a `@:wrap(...)`
	 * (no kw, has lead+trail) single-Ref branch. The parser captures
	 * whether the source had a newline in the gap between the open
	 * delimiter (`@:lead`) and the inner sub-rule's first token — i.e.
	 * source author wrote `(\n\tinner)` (newline) vs `(inner)` (tight).
	 * The writer threads the flag into the wrap shape so a chain inner
	 * rendered as OnePerLine round-trips the source-author distinction
	 * between `((items[0]\n\titems[1]\n))` (no leading newline → glued)
	 * and `(\n\titems[0]\n\titems[1]\n)` (open broken → first item on
	 * its own line). Without the slot the writer can only emit one of
	 * the two shapes uniformly. Plain mode keeps the original ctor arity
	 * and the writer falls back to the always-glue shape from
	 * `OptHardlineSkipAtOpenDelim`. First consumer: `HxExpr.ParenExpr`.
	 */
	public static inline final WRAP_OPEN_NEWLINE_ARG_NAME: String = 'wrapOpenNewline';

	/**
	 * ω-keep-kw-newline (increment 1b) — positional arg name appended to
	 * paired Alt ctors carrying `@:fmt(captureKwNewline)` on the mandatory-
	 * `@:kw` VarStmt-family enum ctors (`VarStmt` / `FinalStmt` /
	 * `StaticVarStmt` / `StaticFinalStmt`). The parser captures whether the
	 * source had a newline between the LAST keyword / lead literal
	 * (`var` / `final`) and the inner `decl` Ref's first token — i.e. the
	 * author wrote `var\n\trawRead` (newline) vs `var rawRead` (same line).
	 * The writer threads the flag into the `HxVarDecl` multiVar fold's
	 * `WrapMode.Keep` head break (`_breaks[0]`) so a kept multi-var decl
	 * round-trips the source-author `var`→head newline. Plain mode keeps
	 * the original ctor arity (no slot; head always glued to `var `).
	 * Sister to `bodyOnSameLine` / `wrapOpenNewline` — same parser-capture-
	 * onto-synth-arg channel, but on the mandatory-kw enum-ctor path rather
	 * than the optional-kw Ref path.
	 */
	public static inline final KW_NEWLINE_ARG_NAME: String = 'kwNewline';

	/**
	 * ω-keep-chain (increment 2) — positional arg name appended to paired
	 * infix enum ctors carrying `@:fmt(captureChainNewline)` (the Pratt
	 * binary-chain ctors `HxExpr.Add` / `Sub` / `And` / `Or`). The parser
	 * captures, at the `lowerPrattLoop` operator-match site, whether the
	 * source had a newline anywhere in the gap before this ctor's RIGHT
	 * operand (covering both `a\n&& b` and `a +\n b` shapes). The writer's
	 * chain `_gather` reads it into a `_breaks` array parallel to `_ops`
	 * and threads it to `BinaryChainEmit.emit(..., sourceBreakBefore)` so a
	 * `WrapMode.Keep` chain round-trips the source per-operator line breaks.
	 * Plain mode keeps the original 2-operand ctor arity (no slot; chain
	 * always glues via `shapeNoWrap`). Sister to `kwNewline` — same parser-
	 * capture-onto-synth-arg channel, but on the Pratt/infix enum-ctor path.
	 */
	public static inline final CHAIN_NEWLINE_ARG_NAME: String = 'chainNewline';

	/**
	 * ω-keep-chain-receiver-comment — positional arg name appended to the
	 * `@:postfix('.')` method-chain ctor `HxExpr.FieldAccess` (alongside its
	 * `chainNewline:Bool` slot). Holds the verbatim same-line trailing comment
	 * captured by the parser in the gap BEFORE the `.` dispatch — i.e. the
	 * trailing comment of the FieldAccess's operand. For a chain whose receiver
	 * is a bare value (`owner // test\n\t.addEntity()…`) the inner-most
	 * FieldAccess's operand IS that receiver, so this slot carries the
	 * receiver's trailing comment; the chain dispatch threads it onto the
	 * receiver Doc under `WrapMode.Keep` so the comment survives the per-segment
	 * break. Null for operands whose trailing comment is already captured
	 * elsewhere — a Call operand's `)`-trailing comment is held by the Call's
	 * `closeTrailing` slot, so `collectTrailingFull` finds nothing left at the
	 * dot gap and this slot stays null (byte-inert). Postfix-only (the infix
	 * chain ctors capture operand trivia through the Pratt stash, not here).
	 * Plain mode keeps the original 2-arg FieldAccess ctor (no slot).
	 */
	public static inline final CHAIN_LEAD_COMMENT_ARG_NAME: String = 'chainLeadComment';

	private static inline final PAIRED_SUFFIX: String = 'T';
	private static inline final SYNTH_SUBPACK: String = 'trivia';
	private static inline final SYNTH_MODULE_LEAF: String = 'Pairs';
	private static inline final CONVERTERS_CLASS_NAME: String = 'Converters';
	private static final shapes: Array<ShapeBuilder.ShapeResult> = [];
	private static final defined: Map<String, Bool> = [];
	private static var convertersAdded: Bool = false;

	public static function arm(shape: ShapeBuilder.ShapeResult): Void {
		if (shapes.indexOf(shape) == -1) shapes.push(shape);
		final rootPack: Array<String> = packOf(shape.root);
		final synthPack: Array<String> = rootPack.concat([SYNTH_SUBPACK]);
		final modulePath: String = synthPack.concat([SYNTH_MODULE_LEAF]).join('.');
		final paired: Array<TypeDefinition> = [];
		final convertedNames: Array<String> = [];
		for (origName => node in shape.rules) {
			if (node.annotations.get('trivia.bearing') != true) continue;
			final pairedFqn: String = origName + PAIRED_SUFFIX;
			if (defined.exists(pairedFqn)) continue;
			defined.set(pairedFqn, true);
			paired.push(buildTypeDefinition(origName, node, synthPack));
			convertedNames.push(origName);
		}
		if (paired.length == 0) return;
		// ω-paired-converters (Phase A1): emit a single `Converters` class
		// in the same synth module carrying static `pairedToRaw_<T>` /
		// `rawToPaired_<T>` helpers for every paired type. The engine
		// (`WriterLowering.wrapWithPreWrite`) routes preWrite plugins
		// through these helpers in trivia mode, so plugin sigs stay raw
		// (`(<T>, WriteOptions) -> Null<<T>>`) regardless of trivia
		// propagation. One Converters class per `Context.defineModule`
		// batch — additional `arm()` calls for the same module batch
		// must not re-emit (Haxe rejects duplicate type defs); the
		// `convertersAdded` flag guards repeat invocations.
		if (!convertersAdded) {
			convertersAdded = true;
			paired.push(buildConvertersClass(convertedNames, synthPack));
		}
		Context.defineModule(modulePath, paired);
		#if anyparse_trivia_dump
		for (td in paired) Sys.println('// trivia.synth: defined ${td.pack.join('.')}.${td.name} in module $modulePath');
		#end
	}

	/**
	 * ω-paired-converters (Phase A1) — emit a `Converters` class with
	 * `pairedToRaw_<T>` static helpers for every paired type in the
	 * batch. Phase A2 appends `rawToPaired_<T>` siblings.
	 *
	 * Routed at runtime by `WriterLowering.wrapWithPreWrite` to unwrap
	 * a paired-T `value` into raw form, hand it to the plugin's raw
	 * preWrite signature, and (when the plugin rewrites) re-wrap via
	 * `rawToPaired_<T>` with empty default trivia. Plugin authors never
	 * see paired types regardless of trivia propagation up the chain.
	 *
	 * Each helper is recursive across the paired-type graph: a Ref to
	 * another paired type calls that type's `pairedToRaw_`, terminals
	 * / non-paired refs pass through, `Trivial<X>`-wrapped Star elements
	 * unwrap via `.node`. Cyclic graphs (HxStatementT ↔ HxIfStmtT) work
	 * because all helpers land in one `Context.defineModule` batch
	 * alongside the paired types.
	 */
	private static function buildConvertersClass(convertedNames: Array<String>, synthPack: Array<String>): TypeDefinition {
		final pos: Position = Context.currentPos();
		convertedNames.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));
		final shape: ShapeBuilder.ShapeResult = shapes[shapes.length - 1];
		final fns: Array<Field> = [];
		for (origName in convertedNames) {
			final node: Null<ShapeNode> = shape.rules.get(origName);
			if (node == null) continue;
			fns.push(buildPairedToRawFn(origName, node, synthPack));
			fns.push(buildRawToPairedFn(origName, node, synthPack));
		}
		return {
			pos: pos,
			pack: synthPack,
			name: CONVERTERS_CLASS_NAME,
			kind: TDClass(null, [], false, true, false),
			fields: fns,
			meta: [{ name: ':nullSafety', params: [macro Strict], pos: pos }],
		};
	}

	/**
	 * Build the `pairedToRaw_<Leaf>` static method for a single paired
	 * type. Signature: `(value:<Leaf>T):<RawLeaf>` — raw return type
	 * lives at the original module path, paired arg type lives in the
	 * synth module.
	 *
	 * Body shape:
	 *  - Seq paired type → object literal `{ fieldA: unwrap(value.fieldA), ... }`.
	 *  - Alt paired type → `switch value { case Ctor(args, _extras): RawType.Ctor(unwrap(args)); ... }`.
	 *  - Terminal → unreachable (terminals never gain `trivia.bearing`).
	 */
	private static function buildPairedToRawFn(origName: String, origNode: ShapeNode, synthPack: Array<String>): Field {
		final pairedSimple: String = leafOf(origName) + PAIRED_SUFFIX;
		final rawSimple: String = leafOf(origName);
		final rawCT: ComplexType = TPath({ pack: packOf(origName), name: rawSimple, params: [] });
		final pairedCT: ComplexType = TPath({ pack: synthPack, name: pairedSimple, params: [] });
		final pos: Position = Context.currentPos();
		final body: Expr = switch origNode.kind {
			case Seq: buildPairedToRawSeqBody(origNode, pos);
			case Alt: buildPairedToRawAltBody(origName, origNode, pos);
			case _:
				Context.fatalError('TriviaTypeSynth: pairedToRaw unsupported kind ${origNode.kind} for $origName', pos);
				throw 'unreachable';
		};
		return {
			name: 'pairedToRaw_' + rawSimple,
			access: [APublic, AStatic],
			pos: pos,
			kind: FFun({ args: [{ name: 'value', type: pairedCT }], ret: rawCT, expr: body }),
		};
	}

	private static function buildPairedToRawSeqBody(origNode: ShapeNode, pos: Position): Expr {
		final entries: Array<{ field: String, expr: Expr }> = [];
		for (child in origNode.children) {
			final fieldName: String = child.annotations.get('base.fieldName');
			final access: Expr = { expr: EField(macro value, fieldName), pos: pos };
			entries.push({ field: fieldName, expr: shapePairedToRawUnwrap(access, child, pos) });
		}
		final structLit: Expr = { expr: EObjectDecl([for (e in entries) { field: e.field, expr: e.expr }]), pos: pos };
		return macro return $structLit;
	}

	private static function buildPairedToRawAltBody(origName: String, origNode: ShapeNode, pos: Position): Expr {
		final rawSimple: String = leafOf(origName);
		final rawPack: Array<String> = packOf(origName);
		final cases: Array<Case> = [];
		for (branch in origNode.children) {
			final ctorName: String = branch.annotations.get('base.ctor');
			final origArgCount: Int = branch.children.length;
			final extraCount: Int = countAltExtras(branch);
			if (origArgCount == 0 && extraCount == 0) {
				// Bare ctor `case CtorName: RawType.CtorName;`
				final pattern: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
				final raw: Expr = MacroStringTools.toFieldExpr(rawPack.concat([rawSimple, ctorName]));
				cases.push({ values: [pattern], guard: null, expr: raw });
				continue;
			}
			// Pattern: CtorName(arg0, arg1, _, _, ...)
			final binders: Array<Expr> = [];
			for (i in 0...origArgCount) {
				final argName: String = branch.children[i].annotations.get('base.fieldName');
				binders.push({ expr: EConst(CIdent(argName)), pos: pos });
			}
			for (_ in 0...extraCount) binders.push({ expr: EConst(CIdent('_')), pos: pos });
			final pattern: Expr = { expr: ECall({ expr: EConst(CIdent(ctorName)), pos: pos }, binders), pos: pos };
			// Body: RawType.CtorName(unwrap(arg0), unwrap(arg1), ...)
			final unwrapArgs: Array<Expr> = [];
			for (i in 0...origArgCount) {
				final argNode: ShapeNode = branch.children[i];
				final argName: String = argNode.annotations.get('base.fieldName');
				final argAccess: Expr = { expr: EConst(CIdent(argName)), pos: pos };
				unwrapArgs.push(shapePairedToRawUnwrap(argAccess, argNode, pos));
			}
			final rawCtorFn: Expr = MacroStringTools.toFieldExpr(rawPack.concat([rawSimple, ctorName]));
			final body: Expr = { expr: ECall(rawCtorFn, unwrapArgs), pos: pos };
			cases.push({ values: [pattern], guard: null, expr: body });
		}
		final switchExpr: Expr = { expr: ESwitch(macro value, cases, null), pos: pos };
		return macro return $switchExpr;
	}

	/**
	 * Build the unwrap expression for one paired-type access. Handles
	 * the four shape kinds — Ref / Star / Terminal / Null-wrap — and
	 * recurses into element types via the same helper.
	 */
	private static function shapePairedToRawUnwrap(access: Expr, node: ShapeNode, pos: Position): Expr {
		switch node.kind {
			case Ref:
				final refName: String = node.annotations.get('base.ref');
				final optional: Bool = node.annotations.get('base.optional') == true;
				if (!refIsBearing(refName)) return access; // raw type already
				final fnName: String = 'pairedToRaw_' + leafOf(refName);
				final call: Expr = { expr: ECall({ expr: EConst(CIdent(fnName)), pos: pos }, [access]), pos: pos };
				return optional ? macro ($access == null ? null : $call) : call;
			case Star:
				final elem: ShapeNode = node.children[0];
				final triviaWrap: Bool = node.annotations.get('trivia.starCollects') == true;
				final optional: Bool = node.annotations.get('base.optional') == true;
				final innerAccess: Expr = triviaWrap ? (macro t.node) : (macro e);
				final iterVar: String = triviaWrap ? 't' : 'e';
				final inner: Expr = shapePairedToRawUnwrap(innerAccess, elem, pos);
				final loopExpr: Expr = {
					expr: EArrayDecl([
						{
							expr: EFor(macro $i{iterVar} in $access, inner),
							pos: pos,
						}
					]),
					pos: pos,
				};
				// Wadler trick — `[for (x in arr) expr]` is the comprehension; produce it via EFor inside EArrayDecl
				// Actually Haxe accepts EMeta? Simpler: build via parser-friendly Expr
				final compr: Expr = {
					expr: EArrayDecl([
						{
							expr: EFor({ expr: EBinop(OpIn, { expr: EConst(CIdent(iterVar)), pos: pos }, access), pos: pos }, inner),
							pos: pos,
						}
					]),
					pos: pos
				};
				return optional ? macro ($access == null ? null : $compr) : compr;
			case Terminal:
				return access;
			case _:
				Context.fatalError('TriviaTypeSynth: shapePairedToRawUnwrap unexpected kind ${node.kind}', pos);
				throw 'unreachable';
		}
	}

	/**
	 * Count the trivia-only positional args appended to an Alt branch
	 * AFTER the original ctor children. Must mirror exactly the gates
	 * applied in `buildEnumCtor`'s second half — every predicate there
	 * adds a positional arg; this function adds the same arg counts.
	 */
	private static function countAltExtras(branch: ShapeNode): Int {
		var n: Int = 0;
		if (isAltCloseTrailingBranch(branch)) {
			n++; // closeTrailing
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) {
				n += 3; // openTrailing + trailingBlankBefore + trailingLeading
				// ω-arraylit-source-trail-comma: + trailPresent when @:sep is
				// present (mirrors `buildEnumCtor` gate).
				// ω-blockended-trivia-meta-arity (Session 3): hasMeta over
				// readMetaString — must match `buildEnumCtor` L1093 gate so the
				// paired-to-raw switch pattern's `_` placeholder count stays
				// in sync with the Alt ctor's extra-arg count. Latent today
				// (no `:trivia + :lead + :trail + :sep(>1-arg)` Alt branch
				// in the live grammar) but blocks the next BlockStmt /
				// BlockExpr migration.
				if (branch.hasMeta(':sep')) n++;
			}
		}
		if (isAltTrailOptBranch(branch)) n++; // trailPresent
		if (isCaptureSourceBranch(branch)) n++; // sourceText
		if (isAltBodyPolicyKwBranch(branch)) n++; // bodyOnSameLine
		if (isAltWrapOpenNewlineBranch(branch)) n++; // wrapOpenNewline
		if (isAltKwNewlineBranch(branch)) n++; // kwNewline (increment 1b)
		if (isAltChainNewlineBranch(branch)) n++; // chainNewline (increment 2)
		if (isPostfixChainCommentBranch(branch)) n++; // chainLeadComment (receiver-comment)
		// ω-D9A-keep-callargs-v2: postfix close-trailing gate adds TWO slots
		// — closeTrailing + argsOpenNewline (see `buildEnumCtor`). Keep the
		// count in sync so the `pairedToRaw` switch pattern's `_` placeholder
		// count matches the paired ctor's arity.
		if (isPostfixCloseTrailingBranch(branch)) n += 2;
		return n;
	}

	/**
	 * Build the `rawToPaired_<Leaf>` static method for a single paired
	 * type. Signature: `(value:<RawLeaf>):<Leaf>T`. Wraps a raw value
	 * into paired form with empty default trivia.
	 *
	 * Called by `WriterLowering.wrapWithPreWrite` after a preWrite
	 * plugin rewrite — the plugin returns raw, engine must hand the
	 * writer a paired-T. The rewrite typically produces a different
	 * ctor shape (e.g. `ArrowFn → Arrow(Parens, ...)`); original trivia
	 * doesn't fit the new ctor and is correctly lost.
	 */
	private static function buildRawToPairedFn(origName: String, origNode: ShapeNode, synthPack: Array<String>): Field {
		final pairedSimple: String = leafOf(origName) + PAIRED_SUFFIX;
		final rawSimple: String = leafOf(origName);
		final rawCT: ComplexType = TPath({ pack: packOf(origName), name: rawSimple, params: [] });
		final pairedCT: ComplexType = TPath({ pack: synthPack, name: pairedSimple, params: [] });
		final pos: Position = Context.currentPos();
		final body: Expr = switch origNode.kind {
			case Seq: buildRawToPairedSeqBody(origNode, pos);
			case Alt: buildRawToPairedAltBody(origName, origNode, synthPack, pos);
			case _:
				Context.fatalError('TriviaTypeSynth: rawToPaired unsupported kind ${origNode.kind} for $origName', pos);
				throw 'unreachable';
		};
		return {
			name: 'rawToPaired_' + rawSimple,
			access: [APublic, AStatic],
			pos: pos,
			kind: FFun({ args: [{ name: 'value', type: rawCT }], ret: pairedCT, expr: body }),
		};
	}

	private static function buildRawToPairedSeqBody(origNode: ShapeNode, pos: Position): Expr {
		final entries: Array<{ field: String, expr: Expr }> = [];
		for (child in origNode.children) {
			final fieldName: String = child.annotations.get('base.fieldName');
			final access: Expr = { expr: EField(macro value, fieldName), pos: pos };
			entries.push({ field: fieldName, expr: shapeRawToPairedWrap(access, child, pos) });
			// Append trivia-only sibling fields with default empty values —
			// mirror the gates applied in `buildTypeDefinition`'s Seq path.
			if (isOptionalKw(child)) {
				entries.push({ field: fieldName + AFTER_KW_SUFFIX, expr: macro (null: Null<String>) });
				entries.push({ field: fieldName + KW_LEADING_SUFFIX, expr: macro ([]: Array<String>) });
				entries.push({ field: fieldName + BEFORE_KW_NEWLINE_SUFFIX, expr: macro false });
				entries.push({ field: fieldName + BODY_ON_SAME_LINE_SUFFIX, expr: macro false });
				entries.push({ field: fieldName + BEFORE_KW_LEADING_SUFFIX, expr: macro ([]: Array<String>) });
				entries.push({ field: fieldName + BEFORE_KW_TRAILING_SUFFIX, expr: macro (null: Null<String>) });
			}
			if (isTriviaStarField(child)) {
				entries.push({ field: fieldName + TRAILING_BLANK_BEFORE_SUFFIX, expr: macro false });
				// ω-keep-fnsig-newline: sibling default for the close-newline
				// slot (raw→paired upcast). Mirrors TRAILING_BLANK_BEFORE_SUFFIX.
				entries.push({ field: fieldName + TRAILING_NEWLINE_BEFORE_SUFFIX, expr: macro false });
				entries.push({ field: fieldName + TRAILING_LEADING_SUFFIX, expr: macro ([]: Array<String>) });
				if (child.readMetaString(':trail') != null)
					entries.push({ field: fieldName + TRAILING_CLOSE_SUFFIX, expr: macro (null: Null<String>) });
				if (child.readMetaString(':lead') != null && !child.hasMeta(':tryparse'))
					entries.push({ field: fieldName + TRAILING_OPEN_SUFFIX, expr: macro (null: Null<String>) });
				if (child.hasMeta(':tryparse') && child.fmtHasFlag('nestBody'))
					entries.push({ field: fieldName + TRAILING_BLANK_AFTER_SUFFIX, expr: macro false });
				// ω-blockended-trivia-meta-arity (Session 3): hasMeta over
				// readMetaString — gate must match `buildStarTrailingSlots`
				// at L1002. Multi-arg `@:sep('text', tailRelax, blockEnded)`
				// (3-arg form) lands on the same code path as 1-arg `@:sep(',')`.
				if (child.hasMeta(':sep') && child.hasMeta(':trail'))
					entries.push({ field: fieldName + TRAIL_PRESENT_SUFFIX, expr: macro false });
			}
			// ω-condcomp-body-leading-sep: trivia-independent SepBefore
			// default for raw→paired upcasts (Slice 18f). Sibling of the
			// gate in `buildTypeDefinition`.
			if (isSepBeforeOptStarField(child)) entries.push({ field: fieldName + SEP_BEFORE_SUFFIX, expr: macro false });
			if (isBareNonFirstRef(child, origNode) || isBareFirstStarNlOptIn(child, origNode))
				entries.push({ field: fieldName + BEFORE_NEWLINE_SUFFIX, expr: macro false });
			// ω-598-member-leading-comment: raw→paired upcast default — preWrite
			// plugin rewrites carry no source comments, so the slot defaults to
			// the empty array (byte-inert emit). Mirrors the BeforeNewline
			// sibling above, gated on the same bare-Ref host.
			if (isBareNonFirstRef(child, origNode))
				entries.push({ field: fieldName + BEFORE_LEADING_SUFFIX, expr: macro ([]: Array<String>) });
			if (isTrailRef(child)) entries.push({ field: fieldName + AFTER_TRAIL_SUFFIX, expr: macro (null: Null<String>) });
			if (isPadTrailingTerminalRef(child)) entries.push({ field: fieldName + NEWLINE_AFTER_SUFFIX, expr: macro false });
			// ω-condition-wrap-keep: raw→paired upcast default for the
			// `<field>CondOpenNewline:Bool` slot. preWrite plugin rewrites
			// don't preserve the source's post-`(` break, so the upcast
			// defaults to `false` → the writer falls back to the width-
			// driven glue. Mirrors the `isPadTrailingTerminalRef` sibling.
			if (isCondOpenNewlineRef(child)) entries.push({ field: fieldName + CONDITION_OPEN_NEWLINE_SUFFIX, expr: macro false });
			// ω-struct-trailopt-source-track (Session 14 Phase 3): struct
			// typedef fields carrying `@:trailOpt(LIT)` grow a
			// `<field>TrailPresent:Null<Bool>` slot on the paired-T struct
			// (synthesised by `buildStructFieldTrailPresentSlot`). Default
			// to `null` on raw→paired upcasts — preWrite plugin rewrites
			// don't preserve source presence, so the writer falls back to
			// canonical re-emission. The slot is `@:optional` so omission
			// would also compile, but explicit `null` push mirrors the
			// `isTrailRef` / `isPadTrailingTerminalRef` sibling pattern and
			// keeps the raw→paired struct literal shape stable.
			if (isStructFieldTrailOpt(child)) entries.push({ field: fieldName + TRAIL_PRESENT_SUFFIX, expr: macro (null: Null<Bool>) });
		}
		final structLit: Expr = { expr: EObjectDecl([for (e in entries) { field: e.field, expr: e.expr }]), pos: pos };
		return macro return $structLit;
	}

	private static function buildRawToPairedAltBody(origName: String, origNode: ShapeNode, synthPack: Array<String>, pos: Position): Expr {
		final pairedSimple: String = leafOf(origName) + PAIRED_SUFFIX;
		final pairedPath: Array<String> = synthPack.concat([SYNTH_MODULE_LEAF, pairedSimple]);
		final cases: Array<Case> = [];
		for (branch in origNode.children) {
			final ctorName: String = branch.annotations.get('base.ctor');
			final origArgCount: Int = branch.children.length;
			if (origArgCount == 0) {
				final pattern: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
				final pairedCtor: Expr = MacroStringTools.toFieldExpr(pairedPath.concat([ctorName]));
				cases.push({ values: [pattern], guard: null, expr: pairedCtor });
				continue;
			}
			// Pattern: CtorName(arg0, arg1, ...) — raw ctors have no extras.
			final binders: Array<Expr> = [
				for (i in 0...origArgCount)
					{ expr: EConst(CIdent(branch.children[i].annotations.get('base.fieldName'))), pos: pos }
			];
			final pattern: Expr = { expr: ECall({ expr: EConst(CIdent(ctorName)), pos: pos }, binders), pos: pos };
			// Body: PairedType.CtorName(wrap(arg0), wrap(arg1), ...defaults).
			final pairedArgs: Array<Expr> = [
				for (i in 0...origArgCount) {
					final argNode: ShapeNode = branch.children[i];
					final argName: String = argNode.annotations.get('base.fieldName');
					final argAccess: Expr = { expr: EConst(CIdent(argName)), pos: pos };
					shapeRawToPairedWrap(argAccess, argNode, pos);
				}
			];
			for (extra in buildAltExtraDefaults(branch, pos)) pairedArgs.push(extra);
			final pairedCtorFn: Expr = MacroStringTools.toFieldExpr(pairedPath.concat([ctorName]));
			final body: Expr = { expr: ECall(pairedCtorFn, pairedArgs), pos: pos };
			cases.push({ values: [pattern], guard: null, expr: body });
		}
		final switchExpr: Expr = { expr: ESwitch(macro value, cases, null), pos: pos };
		return macro return $switchExpr;
	}

	/**
	 * Default-value expressions for Alt branch trivia-only positional
	 * extras. Order MUST mirror `buildEnumCtor`'s push order so the
	 * paired ctor's positional arg list is satisfied position-by-position.
	 */
	private static function buildAltExtraDefaults(branch: ShapeNode, pos: Position): Array<Expr> {
		final defaults: Array<Expr> = [];
		if (isAltCloseTrailingBranch(branch)) {
			defaults.push(macro (null: Null<String>)); // closeTrailing
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) {
				defaults.push(macro (null: Null<String>)); // openTrailing
				defaults.push(macro false); // trailingBlankBefore
				defaults.push(macro ([]: Array<String>)); // trailingLeading
				// ω-arraylit-source-trail-comma: trailPresent default for
				// raw-to-paired wraps. `false` matches the parser's initial
				// state — preWrite plugin rewrites don't preserve source
				// trailing-sep presence, so the writer falls back to the
				// knob-only path (`appendTrailingCommaExpr = knob`).
				// ω-blockended-trivia-meta-arity (Session 3): hasMeta over
				// readMetaString — must match `buildEnumCtor` L1076 gate so
				// raw-to-paired ctor arg count matches the paired ctor's arity.
				if (branch.hasMeta(':sep')) defaults.push(macro false);
			}
		}
		if (isAltTrailOptBranch(branch)) defaults.push(macro false); // trailPresent
		if (isCaptureSourceBranch(branch)) defaults.push(macro ''); // sourceText
		if (isAltBodyPolicyKwBranch(branch)) defaults.push(macro false); // bodyOnSameLine
		if (isAltWrapOpenNewlineBranch(branch)) defaults.push(macro false); // wrapOpenNewline
		if (isAltKwNewlineBranch(branch)) defaults.push(macro false); // kwNewline (increment 1b)
		if (isAltChainNewlineBranch(branch)) defaults.push(macro false); // chainNewline (increment 2)
		if (isPostfixChainCommentBranch(branch)) defaults.push(macro (null: Null<String>)); // chainLeadComment (receiver-comment)
		if (isPostfixCloseTrailingBranch(branch)) {
			defaults.push(macro (null: Null<String>)); // closeTrailing
			// ω-D9A-keep-callargs-v2: argsOpenNewline default for raw→paired
			// wraps. `false` matches the parser's initial state for source
			// without a leading-newline after the postfix open. preWrite
			// plugin rewrites don't preserve open-paren source shape, so the
			// writer falls back to default (glued first arg) — consistent
			// with the existing closeTrailing=null fallback.
			defaults.push(macro false); // argsOpenNewline
			// ω-keep-callclose-newline: argsCloseNewline default for raw→paired
			// wraps. `false` matches the parser's initial state for source whose
			// close glued (no newline before the postfix close). preWrite plugin
			// rewrites don't preserve close-paren source shape, so the writer
			// falls back to the glued close — consistent with the sibling
			// argsOpenNewline=false / closeTrailing=null fallbacks.
			defaults.push(macro false); // argsCloseNewline
		}
		return defaults;
	}

	/**
	 * Build the wrap expression for one raw-value access. Mirror of
	 * `shapePairedToRawUnwrap` — same shape kinds, opposite direction.
	 * Star elements gain a fresh `Trivial<T>` envelope with empty
	 * trivia siblings; inner refs that are themselves paired recurse
	 * through `rawToPaired_<Inner>`.
	 */
	private static function shapeRawToPairedWrap(access: Expr, node: ShapeNode, pos: Position): Expr {
		switch node.kind {
			case Ref:
				final refName: String = node.annotations.get('base.ref');
				final optional: Bool = node.annotations.get('base.optional') == true;
				if (!refIsBearing(refName)) return access;
				final fnName: String = 'rawToPaired_' + leafOf(refName);
				final call: Expr = { expr: ECall({ expr: EConst(CIdent(fnName)), pos: pos }, [access]), pos: pos };
				return optional ? macro ($access == null ? null : $call) : call;
			case Star:
				final elem: ShapeNode = node.children[0];
				final triviaWrap: Bool = node.annotations.get('trivia.starCollects') == true;
				final optional: Bool = node.annotations.get('base.optional') == true;
				final iterVar: String = 'e';
				final iterExpr: Expr = { expr: EConst(CIdent(iterVar)), pos: pos };
				final innerWrap: Expr = shapeRawToPairedWrap(iterExpr, elem, pos);
				final perElem: Expr = triviaWrap
					? macro ({
						blankBefore: false,
						blankAfterLeadingComments: false,
						newlineBefore: false,
						leadingComments: ([]: Array<String>),
						trailingComment: (null: Null<String>),
						trailingBeforeSep: false,
						sepAfter: true,
						node: $innerWrap,
					})
					: innerWrap;
				final compr: Expr = {
					expr: EArrayDecl([
						{
							expr: EFor({ expr: EBinop(OpIn, { expr: EConst(CIdent(iterVar)), pos: pos }, access), pos: pos }, perElem),
							pos: pos,
						}
					]),
					pos: pos
				};
				return optional ? macro ($access == null ? null : $compr) : compr;
			case Terminal:
				return access;
			case _:
				Context.fatalError('TriviaTypeSynth: shapeRawToPairedWrap unexpected kind ${node.kind}', pos);
				throw 'unreachable';
		}
	}

	private static function buildTypeDefinition(origName: String, origNode: ShapeNode, synthPack: Array<String>): TypeDefinition {
		final pairedSimple: String = leafOf(origName) + PAIRED_SUFFIX;
		final pos: Position = Context.currentPos();
		return switch origNode.kind {
			case Seq:
				final fields: Array<Field> = [];
				for (child in origNode.children) {
					fields.push(buildStructField(child, pos, synthPack));
					// ω-issue-316: `@:optional @:kw(...)` Ref fields grow two
					// sibling trivia slots — a same-line trailing comment
					// captured right after the kw (`AfterKw`), and own-line
					// comments captured between kw and body (`KwLeading`).
					// Writer consumes these to preserve source layout; absent
					// consumers read `null` / `[]` with no harm.
					if (isOptionalKw(child)) for (extra in buildKwTriviaSlots(child, pos)) fields.push(extra);
					// ω-orphan-trivia: `@:trivia` Star fields grow two
					// sibling slots capturing trailing trivia (own-line
					// comments between the last element and the close /
					// EOF). Without them a class body like `{ /* orphan */ }`
					// would lose its comment at parse time.
					if (isTriviaStarField(child)) for (extra in buildStarTrailingSlots(child, pos)) fields.push(extra);
					// ω-condcomp-body-leading-sep: independent of @:trivia.
					// Add a `<field>SepBefore:Bool` slot for Stars opting into
					// `@:fmt(sepBeforeOpt)` (Slice 18f). First consumer is
					// `HxConditionalParam.body`, which is a NON-trivia Star —
					// the slot synthesis must not be gated on `isTriviaStarField`.
					if (isSepBeforeOptStarField(child)) {
						final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
						final fieldName: String = child.annotations.get('base.fieldName');
						fields.push({
							name: fieldName + SEP_BEFORE_SUFFIX,
							kind: FVar(boolCT),
							pos: pos,
							access: []
						});
					}
					// ω-issue-48-v2: bare non-first Ref fields grow a
					// `BeforeNewline:Bool` slot capturing whether the source
					// had a newline in the gap between the preceding content
					// and the sub-rule's first token. Consumed by the
					// writer's inter-field separator.
					if (isBareNonFirstRef(child, origNode) || isBareFirstStarNlOptIn(child, origNode))
						fields.push(buildBeforeNewlineSlot(child, pos));
					// ω-598-member-leading-comment: only the bare non-first Ref
					// host (e.g. `HxMemberDecl.member`) grows the leading-comment
					// companion — its `BeforeNewline` `collectTrivia` scan owns
					// the pre-field gap. The Star-opt-in host reads a different
					// parser local, so it keeps `BeforeNewline` only.
					if (isBareNonFirstRef(child, origNode)) fields.push(buildBeforeLeadingSlot(child, pos));
					// ω-trivia-after-trail: any mandatory Ref field with
					// `@:trail` grows a `<field>AfterTrail:Null<String>` slot
					// holding a same-line `// comment` captured right after
					// the trail literal. Currently consumed by the next
					// sibling's `bodyPolicyWrap` (HxIfStmt's `cond` →
					// `thenBody`); other Ref+trail fields without a
					// bodyPolicy sibling synthesise the slot harmlessly and
					// can opt in later.
					if (isTrailRef(child)) fields.push(buildAfterTrailSlot(child, pos));
					// ω-cond-comp-expr-multiline: bare Ref fields opted in via
					// `@:fmt(captureSourceNewlineAfter)` grow a `NewlineAfter:Bool`
					// slot capturing whether the source had a newline AFTER
					// this field's last token. Read by the writer's
					// `padTrailingDoc` terminal-fallback signal when no
					// downstream sibling carries a slot (e.g.
					// `HxConditionalExpr.expr → '#end'` when both `elseifs`
					// and `elseExpr` are absent).
					if (isPadTrailingTerminalRef(child)) fields.push(buildNewlineAfterSlot(child, pos));
					// ω-condition-wrap-keep: the mandatory-Ref condition field
					// of a `@:fmt(condWrap)` struct opted in via
					// `@:fmt(captureCondOpenNewline)` grows a `CondOpenNewline:Bool`
					// slot capturing whether the source broke right after the
					// condition's open paren (`if (\n\tcond`). Read by the
					// single-Ref condWrap emit so a `WrapMode.Keep` condition
					// reproduces the author's post-`(` break.
					if (isCondOpenNewlineRef(child)) fields.push(buildCondOpenNewlineSlot(child, pos));
					// ω-struct-trailopt-source-track (Session 14 Phase 2 scaffold):
					// struct typedef fields carrying `@:trailOpt(LIT)` grow an
					// `@:optional` `<field>TrailPresent:Null<Bool>` slot. The
					// `@:optional` + `Null<>` shape lets Phase 2 land additively
					// without forcing every paired-struct literal in `Lowering`
					// to populate the slot — Phase 3 will wire parser capture
					// (matchLit result), Phase 4 will wire writer emit (gate
					// trail re-emission on source presence). Until then, the
					// slot is omitted from struct literals (no Lowering touch)
					// and `null` at runtime, semantically "no source info".
					//
					// Sister to `buildStarTrailingSlots`'s `<field>TrailPresent`
					// for Star `@:sep+@:trail` (same suffix constant — both
					// encode "trail literal was present in source"; disjoint
					// host context, no name collision possible within one Seq).
					//
					// Beneficiary fixtures (Session 14 design): `wrapping/
					// issue_366_nested_array_comprehension` (nested `;` preserved),
					// `whitespace/issue_195`/`221` (do-while bare-body — Slice 36
					// pivot). See [[project-blockbody-star-session14-design]].
					if (isStructFieldTrailOpt(child)) fields.push(buildStructFieldTrailPresentSlot(child, pos));
				}
				final anon: ComplexType = TAnonymous(fields);
				{
					pos: pos,
					pack: synthPack,
					name: pairedSimple,
					kind: TDAlias(anon),
					fields: []
				};
			case Alt:
				final fields: Array<Field> = [for (branch in origNode.children) buildEnumCtor(branch, pos, synthPack)];
				{
					pos: pos,
					pack: synthPack,
					name: pairedSimple,
					kind: TDEnum,
					fields: fields
				};
			case _:
				Context.fatalError('TriviaTypeSynth: unsupported bearing kind ${origNode.kind} for $origName', pos);
				throw 'unreachable';
		};
	}

	private static function buildStructField(child: ShapeNode, pos: Position, synthPack: Array<String>): Field {
		final fieldName: String = child.annotations.get('base.fieldName');
		final ct: ComplexType = shapeToComplexType(child, synthPack);
		final optional: Bool = child.annotations.get('base.optional') == true;
		final meta: Metadata = optional ? [{ name: ':optional', params: [], pos: pos }] : [];
		return {
			name: fieldName,
			kind: FVar(ct),
			pos: pos,
			access: [],
			meta: meta
		};
	}

	private static function isOptionalKw(child: ShapeNode): Bool {
		// Generalised over kind=Ref|Star — both shapes need the kw-trivia
		// sibling slots (`<f>BeforeKwLeading` / `<f>BeforeKwTrailing` /
		// `<f>AfterKw` / `<f>KwLeading` / `<f>BeforeKwNewline` /
		// `<f>BodyOnSameLine`) so the writer can round-trip the kw→body
		// gap regardless of whether the body is a single Ref or a Star
		// of decls/statements.
		//
		// Ref consumer: `HxIfStmt.elseBody` (`@:optional @:kw('else')`
		// Ref to HxStatement). Star consumer: `HxConditionalDecl.elseBody`
		// (`@:optional @:kw('#else')` Star of HxTopLevelDecl, slice
		// ω-cond-comp-engine). Lowering's `isOptionalKwStar` mirrors this
		// predicate's Star branch on the parser side.
		return (child.kind == Ref || child.kind == Star)
			&& (child.annotations.get('base.optional') == true && child.readMetaString(':kw') != null);
	}

	private static function isBareNonFirstRef(child: ShapeNode, parent: ShapeNode): Bool {
		return child.kind == Ref && (child.annotations.get('base.optional') != true && (child.readMetaString(':kw') == null && (
			child.readMetaString(':lead') == null && (
				child != parent.children[0] || child.fmtHasFlag('beforeNewlineSlotFirst')
			)
		)));
	}

	/**
	 * ω-casepattern-keep — true for a bare (lead-less, kw-less,
	 * non-optional) trivia Star that is the FIRST field of its struct and
	 * opts into the source-newline-before channel via
	 * `@:fmt(beforeNewlineSlotFirst)`. Sister of `isBareNonFirstRef`'s
	 * first-field allowance, but for a Star value (`HxCaseBranch.patterns`,
	 * `@:sep(',') @:trail(':')`) rather than a bare Ref. Such a field grows
	 * a `<field>BeforeNewline:Bool` slot recording whether the source broke
	 * right after the parent's `case` keyword (whose post-kw `skipWs` the
	 * parent ctor omits via `@:fmt(forwardNewlineForBody)`). Read by the
	 * writer's struct-Star emit under `opt.leftCurly == Next`.
	 */
	private static function isBareFirstStarNlOptIn(child: ShapeNode, parent: ShapeNode): Bool {
		return child.kind == Star && (child.annotations.get('base.optional') != true && (child.readMetaString(':kw') == null && (
			child.readMetaString(':lead') == null && (
				child == parent.children[0] && child.fmtHasFlag('beforeNewlineSlotFirst')
			)
		)));
	}

	private static function buildBeforeNewlineSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations.get('base.fieldName');
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		return {
			name: fieldName + BEFORE_NEWLINE_SUFFIX,
			kind: FVar(boolCT),
			pos: pos,
			access: []
		};
	}

	/**
	 * ω-598-member-leading-comment — `<field>BeforeLeading:Array<String>`
	 * companion to `buildBeforeNewlineSlot`, gated on the same
	 * `isBareNonFirstRef` host. Holds the verbatim comments the
	 * `BeforeNewline` `collectTrivia` scan captured in the pre-field gap.
	 */
	private static function buildBeforeLeadingSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations.get('base.fieldName');
		final arrayStrCT: ComplexType = TPath({
			pack: [],
			name: 'Array',
			params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
		});
		return {
			name: fieldName + BEFORE_LEADING_SUFFIX,
			kind: FVar(arrayStrCT),
			pos: pos,
			access: []
		};
	}

	/**
	 * True for mandatory Ref fields carrying `@:trail(LIT)`. Reads
	 * `@:trail` from `base.meta` directly (TriviaTypeSynth.arm runs
	 * BEFORE the Lit strategy populates `lit.trailText`, same ordering
	 * constraint as `isOptionalKw` / star-trailing predicates).
	 * Optional Refs with `@:lead` + `@:trail` ARE included (Slice 40):
	 * the lead-led commit branch in `Lowering` consumes the trail and
	 * captures a same-line `// comment` into `<field>AfterTrail`, same as
	 * the mandatory path. The absent branch leaves the slot null.
	 */
	private static function isTrailRef(child: ShapeNode): Bool {
		return child.kind == Ref && child.readMetaString(':trail') != null;
	}

	private static function buildAfterTrailSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations.get('base.fieldName');
		final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
		final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
		return {
			name: fieldName + AFTER_TRAIL_SUFFIX,
			kind: FVar(nullStrCT),
			pos: pos,
			access: []
		};
	}

	/**
	 * Session 14 Phase 2 scaffold: build the `<field>TrailPresent` slot for
	 * struct typedef fields gated by `isStructFieldTrailOpt`. Slot is
	 * `@:optional Null<Bool>` so paired-struct construction in `Lowering`
	 * can omit it until Phase 3 (parser capture) and Phase 4 (writer emit)
	 * land. After Phase 4, the slot semantically becomes "true → source
	 * had trail literal; false → absent; null → no source info (e.g.
	 * synthesised paired-T from a writer-only path)". Suffix shared with
	 * `buildStarTrailingSlots`'s `@:sep+@:trail` Star case (disjoint host
	 * — Ref vs Star within one Seq cannot collide on field name).
	 */
	private static function buildStructFieldTrailPresentSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations.get('base.fieldName');
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		final nullBoolCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(boolCT)] });
		final meta: Metadata = [{ name: ':optional', params: [], pos: pos }];
		return {
			name: fieldName + TRAIL_PRESENT_SUFFIX,
			kind: FVar(nullBoolCT),
			pos: pos,
			access: [],
			meta: meta
		};
	}

	/**
	 * True for any Ref field opted in via `@:fmt(captureSourceNewlineAfter)`.
	 * The slot records whether the source had a newline AFTER this
	 * field's parse position — used by the writer's `padTrailingDoc`
	 * walker as a per-field source-shape signal for the boundary
	 * between this field and the parent ctor's trail literal (or
	 * the next non-signal-bearing sibling).
	 *
	 * Bare Ref, optional Ref, and optional-kw Ref are all eligible —
	 * the capture position is "wherever ctx.pos lands after this
	 * field's parse case branch settles", which is well-defined for
	 * all three kinds (post-parse for present case, post-rewind for
	 * absent case).
	 *
	 * Currently consumed by:
	 *   - `HxConditionalExpr.expr` (mandatory bare Ref) — captures the
	 *     `expr → '#end'` boundary newline when both `elseifs` is empty
	 *     and `elseExpr` is absent.
	 *   - `HxConditionalExpr.elseExpr` (optional kw Ref) — captures the
	 *     `elseExpr → '#end'` boundary newline.
	 */
	private static function isPadTrailingTerminalRef(child: ShapeNode): Bool {
		return child.kind == Ref && child.fmtHasFlag('captureSourceNewlineAfter');
	}

	private static function buildNewlineAfterSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations.get('base.fieldName');
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		return {
			name: fieldName + NEWLINE_AFTER_SUFFIX,
			kind: FVar(boolCT),
			pos: pos,
			access: []
		};
	}

	/**
	 * ω-condition-wrap-keep — true for the mandatory-Ref condition field of a
	 * `@:fmt(condWrap)` struct (`HxIfStmt.cond` / `HxWhileStmt.cond`) that opts
	 * into source-shape capture via `@:fmt(captureCondOpenNewline)`. Such a
	 * field grows a `<field>CondOpenNewline:Bool` slot recording whether the
	 * source broke right after the open paren. Requires `condWrap` (the field
	 * carries the `@:lead('(')` open delimiter whose post-`(` gap is probed)
	 * and a bare mandatory Ref (the condWrap contract). Disjoint from
	 * `isPadTrailingTerminalRef` (which keys on `captureSourceNewlineAfter`).
	 * Reads the flags via `fmtHasFlag`, which works at arm-time (`base.meta`
	 * populated by `ShapeBuilder` before `arm()` runs — same path the sister
	 * predicates rely on).
	 */
	private static function isCondOpenNewlineRef(child: ShapeNode): Bool {
		return child.kind == Ref && (
			child.annotations.get('base.optional') != true && (child.fmtHasFlag('condWrap') && child.fmtHasFlag('captureCondOpenNewline'))
		);
	}

	private static function buildCondOpenNewlineSlot(child: ShapeNode, pos: Position): Field {
		final fieldName: String = child.annotations.get('base.fieldName');
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		return {
			name: fieldName + CONDITION_OPEN_NEWLINE_SUFFIX,
			kind: FVar(boolCT),
			pos: pos,
			access: []
		};
	}

	private static function buildKwTriviaSlots(child: ShapeNode, pos: Position): Array<Field> {
		final fieldName: String = child.annotations.get('base.fieldName');
		final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
		final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
		final arrayStrCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(strCT)] });
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		// Slots are mandatory (no `@:optional`). The parser always
		// populates them — `AfterKw` gets a captured same-line trailing
		// or `null`; `KwLeading` gets a list of own-line comments
		// (possibly empty); `BeforeKwNewline` / `BodyOnSameLine` carry
		// source-shape booleans for the `Keep` policy branches.
		// Mandatory typing keeps Null-Safety strict happy in the
		// writer's `kwGapDoc` / `bodyPolicyWrap` call sites.
		return [
			{
				name: fieldName + AFTER_KW_SUFFIX,
				kind: FVar(nullStrCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + KW_LEADING_SUFFIX,
				kind: FVar(arrayStrCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + BEFORE_KW_NEWLINE_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + BODY_ON_SAME_LINE_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + BEFORE_KW_LEADING_SUFFIX,
				kind: FVar(arrayStrCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + BEFORE_KW_TRAILING_SUFFIX,
				kind: FVar(nullStrCT),
				pos: pos,
				access: []
			},
		];
	}

	private static function isTriviaStarField(child: ShapeNode): Bool {
		return child.kind == Star && child.annotations.get('trivia.starCollects') == true;
	}

	/**
	 * Slice 18f opt-in: non-trivia `@:sep + @:tryparse` no-`@:trail` Star
	 * field with `@:fmt(sepBeforeOpt)` requesting a `<field>SepBefore:Bool`
	 * synth slot. The slot captures whether the source had a leading
	 * separator inside the body (`#if cond, body` shape) for byte-roundtrip
	 * re-emission by the writer.
	 *
	 * Independent of `@:trivia` (the gate fires for both trivia and plain
	 * Stars) but coupled to the @:sep+@:tryparse no-trail shape — those
	 * are the only Lowering / WriterLowering paths that interpret the
	 * slot. Macro shape validation lives in `Lowering.emitStarFieldSteps`
	 * (fatalError on missing `:sep` / `:tryparse` / present `:trail`) and
	 * `WriterLowering.emitWriterStarField` (fatalError on missing
	 * `padLeading`).
	 */
	private static function isSepBeforeOptStarField(child: ShapeNode): Bool {
		return child.kind == Star && child.fmtHasFlag('sepBeforeOpt');
	}

	private static function buildStarTrailingSlots(child: ShapeNode, pos: Position): Array<Field> {
		final fieldName: String = child.annotations.get('base.fieldName');
		final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
		final arrayStrCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(strCT)] });
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		final fields: Array<Field> = [
			{
				name: fieldName + TRAILING_BLANK_BEFORE_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			},
			// ω-keep-fnsig-newline: sibling slot recording a single newline (not
			// a blank line) before the close. Defined unconditionally alongside
			// TrailingBlankBefore so the arity stays locked.
			{
				name: fieldName + TRAILING_NEWLINE_BEFORE_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			},
			{
				name: fieldName + TRAILING_LEADING_SUFFIX,
				kind: FVar(arrayStrCT),
				pos: pos,
				access: []
			},
		];
		// ω-close-trailing: close-peek Stars (those with `@:trail`)
		// additionally carry a same-line trailing comment captured right
		// after the close literal. EOF-mode Stars omit this slot —
		// there's no close to trail. `@:trivia + @:tryparse` already
		// rejects `@:trail`, so tryparse cannot reach this branch.
		//
		// Reads `@:trail` directly from `base.meta` rather than the
		// Lit-strategy-derived `lit.trailText` annotation: `TriviaTypeSynth.arm`
		// runs BEFORE `registry.runAnnotate` in `Build.buildParser` /
		// `buildWriter` (the paired type must exist before Lowering /
		// WriterLowering reference it), so at this point the Lit pass has
		// not yet populated `lit.trailText`. Mirrors `isOptionalKw`'s
		// direct-meta read pattern.
		if (child.readMetaString(':trail') != null) {
			final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
			fields.push({
				name: fieldName + TRAILING_CLOSE_SUFFIX,
				kind: FVar(nullStrCT),
				pos: pos,
				access: []
			});
		}
		// ω-open-trailing: same-line `// comment` after the open literal
		// is captured here for Stars that carry `@:lead`. Read directly
		// from `base.meta` for the same TriviaTypeSynth/Lit-pass ordering
		// reason as `:trail` above.
		//
		// Skipped for `@:tryparse` Stars: their writer helper
		// (`triviaTryparseStarExpr`) does not consume an open-trail slot,
		// so capturing one would silently drop the comment at write time.
		// `HxDefaultBranch.stmts` (`@:lead(':') @:trivia @:tryparse`) is
		// the lone current consumer of this gate.
		if (child.readMetaString(':lead') != null && !child.hasMeta(':tryparse')) {
			final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
			fields.push({
				name: fieldName + TRAILING_OPEN_SUFFIX,
				kind: FVar(nullStrCT),
				pos: pos,
				access: []
			});
		}
		// ω-trail-blank-after: tryparse + nestBody Stars need a Bool slot
		// to carry the source's blank-line-between-trail-and-next-sibling
		// signal (`_lead.blankAfterLeadingComments` from the failed-element
		// trivia run). Other tryparse shapes either rewind on failure (no
		// stash) or have no nestBody indent wrap. Reads `:fmt` directly from
		// `base.meta` for the same TriviaTypeSynth/Lit-pass ordering reason
		// as `:trail` / `:lead` above.
		if (child.hasMeta(':tryparse') && child.fmtHasFlag('nestBody')) {
			fields.push({
				name: fieldName + TRAILING_BLANK_AFTER_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			});
		}
		// ω-objectlit-source-trail-comma: sep-Stars with a close literal
		// grow a `Bool` slot capturing whether the source had a trailing
		// separator after the last element. The writer reads it via
		// `<field>TrailPresent` to force the wrap-rules cascade into
		// break-mode when the source committed to a multi-line list.
		// Reads `:sep` / `:trail` directly from `base.meta` for the same
		// pre-Lit-pass ordering reason as the gates above.
		//
		// ω-blockended-trivia-meta-arity (Session 3): `hasMeta` instead of
		// `readMetaString` so multi-arg `@:sep('text', tailRelax, blockEnded)`
		// counts the same as 1-arg `@:sep(',')`. Parser-side gate reads
		// `lit.sepText` (set by Lit strategy after both 1- and 3-arg forms)
		// — synth must match the parser to keep ctor / struct arity in sync.
		if (child.hasMeta(':sep') && child.hasMeta(':trail')) {
			fields.push({
				name: fieldName + TRAIL_PRESENT_SUFFIX,
				kind: FVar(boolCT),
				pos: pos,
				access: []
			});
		}
		return fields;
	}

	private static function buildEnumCtor(branch: ShapeNode, pos: Position, synthPack: Array<String>): Field {
		final ctorName: String = branch.annotations.get('base.ctor');
		if (branch.children.length == 0) return {
			name: ctorName,
			kind: FVar(null),
			pos: pos,
			access: []
		};
		final args: Array<FunctionArg> = [
			for (arg in branch.children)
				{
					name: (arg.annotations.get('base.fieldName'): String),
					type: shapeToComplexType(arg, synthPack),
				}
		];
		// ω-close-trailing-alt: close-peek `@:trivia` Alt-branch Stars
		// (only `HxStatement.BlockStmt` in the current grammar) grow a
		// positional `closeTrailing:Null<String>` arg alongside the
		// existing Trivial-wrapped Star array. Mirrors the Seq-struct
		// close-trailing slot synthesised by `buildStarTrailingSlots`,
		// but the arg has no field-name prefix — Alt ctors are
		// positional so the writer reads it via `argNames[1]`.
		//
		// ω-open-trailing-alt: when the branch ALSO carries `@:lead`
		// (which all three current consumers — BlockStmt, ArrayExpr,
		// BlockExpr — do), append a parallel positional `openTrailing:
		// Null<String>` arg captured via `collectTrailingFull` right
		// after the open literal. Mirrors the Seq-struct open-trailing
		// slot. Writer reads it via `argNames[2]`. Without this, an
		// inline same-line comment between open and first element
		// (or, when the Star is empty, between open and close) is lost
		// at parse — the synth ctor had no slot for it.
		if (isAltCloseTrailingBranch(branch)) {
			final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
			final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
			args.push({ name: 'closeTrailing', type: nullStrCT });
			// `:tryparse` excluded for parity with `buildStarTrailingSlots` —
			// the writer's tryparse helper does not consume an open-trail
			// slot, so capturing one would silently drop the comment at
			// write time. Today no Alt branch combines `:trivia + :tryparse`
			// + `:lead` so the guard is dormant; kept for forward parity.
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) {
				args.push({ name: 'openTrailing', type: nullStrCT });
				// ω-orphan-trivia-alt: orphan trivia between the last Star
				// element and the close literal (e.g. trailing line comment
				// inside `try { p(); /* dropped */ }`). Mirror of the Seq-
				// struct `<field>TrailingBlankBefore` / `<field>TrailingLeading`
				// slots from `buildStarTrailingSlots` — the Lowering Case 4
				// trivia loop captures `_lead.blankBefore` and `_lead.leadingComments`
				// on close-peek break and pushes them as the next two
				// positional args. Writer reads via `argNames[3]` /
				// `argNames[4]`. Gated on `@:lead`-present for predictable arg
				// position; today's `isAltCloseTrailingBranch` consumers all
				// carry `@:lead`.
				final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
				final arrayStrCT: ComplexType = TPath({
					pack: [],
					name: 'Array',
					params: [TPType(strCT)]
				});
				args.push({ name: 'trailingBlankBefore', type: boolCT });
				args.push({ name: 'trailingLeading', type: arrayStrCT });
				// ω-arraylit-source-trail-comma: enum-Alt sep+trail+lead+@:trivia
				// branches (HxExpr.ArrayExpr, HxType.Anon) grow an additional
				// `trailPresent:Bool` arg recording whether the source had a
				// trailing separator before the close literal. Parser captures
				// the last-iteration `matchLit(sepText)` result; writer reads
				// via `argNames[5]` (position 5 inside this block, after
				// closeTrailing/openTrailing/trailingBlankBefore/trailingLeading)
				// and threads as `trailPresentAccess` to the trivia-sep helper
				// so `appendTrailingCommaExpr = trailPresent || knob` preserves
				// the source `,` on multi-line shapes. Disjoint from the lower
				// `isAltTrailOptBranch`'s `trailPresent` arg (Star vs Ref child
				// shape — comment at line 1009 already calls out the disjoint
				// invariant). Reuses `TRAIL_PRESENT_ARG_NAME` so the writer's
				// runtime field-name probe stays consistent. Gated on `@:sep`
				// so block-style trivia ctors (`BlockStmt`, `BlockExpr`) keep
				// their pre-slice 5-arg shape.
				// ω-blockended-trivia-meta-arity (Session 3): `hasMeta` over
				// `readMetaString` so `@:sep('text', tailRelax, blockEnded)`
				// (3-arg form) gates the same as 1-arg `@:sep(',')`. Sister
				// fix in `buildStarTrailingSlots`.
				if (branch.hasMeta(':sep')) {
					args.push({ name: TRAIL_PRESENT_ARG_NAME, type: boolCT });
				}
			}
		}
		// ω-trailopt-source-track: `@:trailOpt(...)` Alt branches with a
		// single Ref child grow a positional `trailPresent:Bool` arg
		// holding the parser's `matchLit` result. Disjoint from
		// `isAltCloseTrailingBranch` (Star vs Ref child shapes), so the
		// two cannot collide on the same ctor. Read `@:trailOpt` from
		// `base.meta` directly since `arm()` runs BEFORE the Lit pass
		// populates `lit.trailOptional` on the branch.
		if (isAltTrailOptBranch(branch)) {
			final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
			args.push({ name: TRAIL_PRESENT_ARG_NAME, type: boolCT });
		}
		// ω-string-interp-noformat: ctors carrying `@:fmt(captureSource)`
		// grow a positional `sourceText:String` arg holding the parser-
		// captured byte slice between the ctor's `@:lead` and `@:trail`
		// literals. Disjoint from `isAltCloseTrailingBranch` (Star vs Ref
		// child) and from `isAltTrailOptBranch` (the `@:trailOpt` predicate
		// requires a trail literal that can be matched optionally; the
		// captureSource ctors have unconditional `@:lead`/`@:trail`). When
		// all three were ever to coexist on a single ctor, the arg order
		// would be: closeTrailing → trailPresent → sourceText.
		if (isCaptureSourceBranch(branch)) {
			final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
			args.push({ name: SOURCE_TEXT_ARG_NAME, type: strCT });
		}
		// ω-issue-257-firstline: single-Ref kw-led Alt branches carrying
		// `@:fmt(bodyPolicy(...))` grow a positional `bodyOnSameLine:Bool`
		// arg holding the parser's source-shape capture (post-kw whitespace
		// crossed a newline → false; same-line → true). Co-occurs with
		// `isAltTrailOptBranch` on the first consumer `HxStatement.ReturnStmt`
		// (`@:kw('return') @:trailOpt(';')`); the arg order in this block
		// (trailPresent → sourceText → bodyOnSameLine) handles the overlap.
		// Disjoint from the close-trailing predicates (single Ref child
		// shape, no Star child).
		if (isAltBodyPolicyKwBranch(branch)) {
			final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
			args.push({ name: BODY_ON_SAME_LINE_ARG_NAME, type: boolCT });
		}
		// ω-paren-wrap-source-newline: single-Ref @:wrap(open, close) Alt
		// branches opting into source-shape capture via
		// @:fmt(captureWrapOpenNewline) grow a positional `wrapOpenNewline:Bool`
		// arg holding hasNewlineIn(_leadEndPos, ctx.pos) over the gap between
		// the open lead literal and the inner sub-rule's first token.
		// Disjoint from isAltBodyPolicyKwBranch (which requires @:kw; wrap
		// ctors have no kw) and from the close/postfix trailing predicates
		// (single Ref child shape, no Star). The arg follows bodyOnSameLine
		// and precedes the postfix closeTrailing in buildEnumCtor's ordering
		// so indices in WriterLowering stay deterministic. First consumer:
		// HxExpr.ParenExpr.
		if (isAltWrapOpenNewlineBranch(branch)) {
			final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
			args.push({ name: WRAP_OPEN_NEWLINE_ARG_NAME, type: boolCT });
		}
		// ω-keep-kw-newline (increment 1b): mandatory-`@:kw` VarStmt-family Alt
		// branches opting into source-shape capture via `@:fmt(captureKwNewline)`
		// grow a positional `kwNewline:Bool` arg holding `hasNewlineIn` over the
		// gap between the last keyword / lead literal (`var` / `final`) and the
		// inner `decl` Ref's first token. Disjoint from isAltWrapOpenNewlineBranch
		// (those are kw-less @:wrap ctors) and isAltBodyPolicyKwBranch (VarStmt
		// carries no @:fmt(bodyPolicy(...))) — composes additively. The arg
		// follows wrapOpenNewline and precedes the postfix closeTrailing in this
		// ordering so indices in WriterLowering stay deterministic. First
		// consumers: HxStatement.{VarStmt, FinalStmt, StaticVarStmt, StaticFinalStmt}.
		if (isAltKwNewlineBranch(branch)) {
			final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
			args.push({ name: KW_NEWLINE_ARG_NAME, type: boolCT });
		}
		// ω-keep-chain (increment 2): Pratt/infix enum ctors opting into
		// per-operand source-newline capture via `@:fmt(captureChainNewline)`
		// (`HxExpr.Add` / `Sub` / `And` / `Or`) grow a positional
		// `chainNewline:Bool` arg holding `hasNewlineIn` over the gap before
		// this ctor's RIGHT operand. Disjoint from every predicate above
		// (these ctors carry no @:trivia / @:lead / @:kw / @:wrap / bodyPolicy),
		// so it composes additively as the LAST appended slot. Follows
		// kwNewline in the ordering so WriterLowering's `altSlotAccess` walker
		// reaches it as the terminal `ChainNewline` slot. First consumers:
		// HxExpr.{Add, Sub, And, Or}.
		if (isAltChainNewlineBranch(branch)) {
			final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
			args.push({ name: CHAIN_NEWLINE_ARG_NAME, type: boolCT });
		}
		// ω-keep-chain-receiver-comment: the `@:postfix('.')` FieldAccess ctor
		// grows a `chainLeadComment:Null<String>` slot immediately after its
		// `chainNewline:Bool` slot, holding the verbatim trailing comment of its
		// operand captured at the dot gap. Postfix-only (isPostfixChainCommentBranch
		// excludes the infix chain ctors), so it appends after chainNewline on the
		// single FieldAccess branch and stays disjoint from the closeTrailing
		// family below (FieldAccess carries no close delimiter).
		if (isPostfixChainCommentBranch(branch)) {
			final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
			final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
			args.push({ name: CHAIN_LEAD_COMMENT_ARG_NAME, type: nullStrCT });
		}
		// ω-postfix-call-trailing: Star-suffix `@:postfix(open, close) @:sep(...)`
		// branches whose Star already auto-collects per-arg trivia
		// (`trivia.starCollects=true`, set by `TriviaAnalysis.markPostfixStarSuffix`)
		// grow a positional `closeTrailing:Null<String>` arg holding the
		// trailing comment captured by the parser AFTER the close literal,
		// before the next postfix step or Pratt iteration. Without this
		// slot, `lowerPostfixLoop`'s per-iteration `skipWs(ctx)` eats
		// inter-segment line/block comments — losing them silently for the
		// writer (e.g. `.alt(x) // c\n.height(y)` chain segments lose `// c`).
		// Disjoint from the four predicates above (different shape predicates),
		// so at most one of these adds applies to any given branch.
		if (isPostfixCloseTrailingBranch(branch)) {
			final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
			final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
			args.push({ name: 'closeTrailing', type: nullStrCT });
			// ω-D9A-keep-callargs-v2: parallel positional `argsOpenNewline:Bool`
			// slot capturing whether source had `\n` between the postfix open
			// literal (e.g. `(`) and the first arg's leading non-whitespace.
			// Drives `WriterLowering.lowerPostfixStar`'s Keep-mode args[0]
			// hardline + trailing-before-close hardline. The per-element
			// `Trivial.newlineBefore` for args[0] is polluted by upstream
			// `ctx.pendingTrivia` drained from kw-Ref rules (see
			// project_phase3_slice_d9a_revert "Critical engine finding"),
			// so the open-newline signal needs its own slot captured by
			// `Lowering` BEFORE the per-iter `skipWs(ctx)` / `collectTrivia(ctx)`
			// can lose it. Co-occurs with `closeTrailing` so the writer
			// reads via `argNames[3]` (closeTrailing stays at argNames[2]).
			final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
			args.push({ name: 'argsOpenNewline', type: boolCT });
			// ω-keep-callclose-newline: sibling positional `argsCloseNewline:Bool`
			// recording whether source had `\n` between the last arg (or the open
			// lit for an empty list) and the postfix close literal (e.g. `arg\n)`
			// vs `arg)`). Sibling of `argsOpenNewline` — captured by `Lowering`'s
			// close-peek `skipWs(ctx)` window right before `expectLit(close)`.
			// Consumed ONLY by `WriterLowering.lowerPostfixStar`'s Keep-mode
			// method-chain close placement: when the Call's `methodChain` rules are
			// `Keep` and this is false (source glued the close), the outer call's
			// close `)` stays glued to the chain's last token (`})));`) instead of
			// the `shapeFillLine` `isChainOPLBreak` own-line break. Reads via
			// `argNames[4]` (argsOpenNewline stays at argNames[3]).
			args.push({ name: 'argsCloseNewline', type: boolCT });
		}
		return {
			name: ctorName,
			kind: FFun({ args: args, ret: null, expr: null }),
			pos: pos,
			access: []
		};
	}

	/**
	 * True when the branch is a postfix Star-suffix ctor (e.g.
	 * `Call(operand:T, args:Array<T>)` from `@:postfix('(', ')') @:sep(',')`)
	 * whose Star child carries `trivia.starCollects=true` (set by
	 * `TriviaAnalysis.markPostfixStarSuffix`). Such branches grow a
	 * positional `closeTrailing:Null<String>` arg holding the trailing
	 * comment captured by the parser right after the postfix close literal,
	 * before the next postfix step's `skipWs` would eat it.
	 *
	 * Single-Ref-suffix postfix (e.g. `FieldAccess(operand, field)` from
	 * `@:postfix('.')`) doesn't qualify — child[1] is Ref, not Star, so
	 * `TriviaAnalysis.markPostfixStarSuffix` never sets `trivia.starCollects`
	 * on it. Pair-lit postfix (1 child + close lit) likewise misses. Both
	 * shapes can grow their own slot in a follow-up if a fixture demands
	 * it; today the only failing fixture is the Star-suffix Call form
	 * (`indentation/method_chain_with_line_comment`).
	 *
	 * Discriminator is `trivia.starCollects` on a 2nd Star child — the
	 * marker function only sets that for the postfix Star-suffix shape it
	 * detects via `:postfix(open, close)` + `[Ref, Star]`. We can't read
	 * `postfix.op`/`postfix.close` from `branch.annotations` here because
	 * the Postfix strategy runs LATER (see `Build.run`: TriviaAnalysis →
	 * TriviaTypeSynth.arm → registry.runAnnotate); only the marker's
	 * `trivia.starCollects` flag is reliably present at arm-time.
	 */
	public static function isPostfixCloseTrailingBranch(branch: ShapeNode): Bool {
		if (branch.children.length != 2) return false;
		if (branch.children[0].kind != Ref) return false;
		final star: ShapeNode = branch.children[1];
		if (star.kind != Star) return false;
		if (star.annotations.get('trivia.starCollects') != true) return false;
		// Tighten: `trivia.starCollects` is also set by `markStarsWithTrivia`
		// for `:trivia` Seq branches with a single Star child. Those are NOT
		// postfix and must not grow a `closeTrailing` slot — Lowering's
		// `lowerPostfixLoop` is the only producer for the slot. Read
		// `:postfix` from raw `base.meta` (Postfix strategy hasn't run yet)
		// to ensure the branch is a postfix ctor.
		final meta: Null<Metadata> = branch.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':postfix' && entry.params.length == 2) return true;
		return false;
	}

	/**
	 * True when the branch is a close-peek `@:trivia` Alt-ctor wrapping
	 * a single Star child — structurally equivalent to the Seq Case 4
	 * shape that grows a `TrailingClose` slot in `buildStarTrailingSlots`.
	 * Reads `@:trail` from `base.meta` directly since `arm()` runs
	 * before the Lit strategy populates `lit.trailText`.
	 */
	public static function isAltCloseTrailingBranch(branch: ShapeNode): Bool {
		if (branch.children.length != 1) return false;
		final star: ShapeNode = branch.children[0];
		return star.kind == Star && (star.annotations.get('trivia.starCollects') == true && branch.readMetaString(':trail') != null);
	}

	/**
	 * True when the branch is a single-Ref Alt-ctor carrying `@:trailOpt(...)`.
	 * Such ctors grow a positional `trailPresent:Bool` arg in the synth
	 * pair so the writer can preserve source presence of the optional
	 * trail literal. Reads `@:trailOpt` from `base.meta` directly since
	 * `arm()` runs before the Lit strategy populates `lit.trailOptional`.
	 *
	 * Disjoint from `isAltCloseTrailingBranch`: that function requires a
	 * single Star child with `@:trail`, this requires a single Ref child
	 * with `@:trailOpt`. The two never coexist on the same branch.
	 */
	public static function isAltTrailOptBranch(branch: ShapeNode): Bool {
		return branch.children.length == 1 && (branch.children[0].kind == Ref && branch.readMetaString(':trailOpt') != null);
	}

	/**
	 * True when a struct typedef field carries `@:trailOpt(...)`. The
	 * struct-field analog of `isAltTrailOptBranch` — destined to gate
	 * synthesis of a `_trailPresent_<fieldName>:Bool` slot on the
	 * paired-T struct so the writer can preserve source presence of
	 * the optional trail literal in trivia mode (today struct-field
	 * `@:trailOpt` is parser-permissive but writer-canonical — always
	 * re-emits, breaking source-preservation contracts for fixtures
	 * like `wrapping/issue_366_nested_array_comprehension` where
	 * fork's section-3 preserves the optional `;`).
	 *
	 * Phase 2 (Session 14) wires this as the gate inside `buildTypeDefinition`'s
	 * Seq arm — every matching field grows an `@:optional Null<Bool>`
	 * `<field>TrailPresent` slot via `buildStructFieldTrailPresentSlot`.
	 * Phase 3 will add the parser-side capture (`matchLit` result),
	 * Phase 4 the writer-side emit (gate trail re-emission on source
	 * presence). See [[project-blockbody-star-session14-design]].
	 *
	 * Disjoint from `isAltTrailOptBranch` (struct typedef field vs
	 * enum Alt branch — orthogonal contexts; same `@:trailOpt` meta
	 * but different host kind).
	 */
	public static function isStructFieldTrailOpt(field: ShapeNode): Bool {
		return field.readMetaString(':trailOpt') != null;
	}

	/**
	 * True when the branch opts into source-byte capture via
	 * `@:fmt(captureSource('<optionFieldName>'))`. The synth-pair ctor
	 * grows a positional `sourceText:String` arg; the parser fills it
	 * with the input slice between the ctor's `@:lead` and `@:trail`
	 * literals (inclusive of any whitespace inside) so the writer can
	 * emit verbatim when the named runtime `Bool` option is `false`.
	 *
	 * Requires single Ref child + `@:lead` + `@:trail` (the parser has
	 * an unambiguous slice to capture). Disjoint from
	 * `isAltTrailOptBranch` since `@:trailOpt` and unconditional
	 * `@:trail` are mutually exclusive on the same ctor.
	 */
	public static function isCaptureSourceBranch(branch: ShapeNode): Bool {
		return branch.children.length == 1
			&& (branch.children[0].kind == Ref
				&& (branch.readMetaString(':lead') != null
					&& (branch.readMetaString(':trail') != null && branch.fmtReadString('captureSource') != null)));
	}

	/**
	 * True when the branch is a single-Ref kw-led Alt-ctor carrying
	 * `@:fmt(bodyPolicy(...))`. Such ctors grow a positional
	 * `bodyOnSameLine:Bool` arg in the synth pair so `bodyPolicyWrap`'s
	 * `Keep` branch can dispatch source-shape-aware between
	 * `sameLayoutExpr` and `nextLayoutExpr` at writer time. Reads
	 * `@:fmt(bodyPolicy(...))` via `fmtReadString`, which works at arm-time
	 * because `base.meta` is populated by `ShapeBuilder` before
	 * `TriviaTypeSynth.arm()` runs (see `Build.run` ordering — same path
	 * `isCaptureSourceBranch` relies on).
	 *
	 * Requires `@:kw(...)` for the parser's commit point — bodyPolicy
	 * without a kw has no anchor for the post-kw newline probe.
	 * Co-occurs with `isAltTrailOptBranch` on the first consumer
	 * `HxStatement.ReturnStmt` (`@:kw('return') @:trailOpt(';')`); the
	 * `buildEnumCtor` push order (trailPresent → sourceText →
	 * bodyOnSameLine) keeps the layout deterministic. Disjoint from the
	 * close-trailing predicates (single Ref child, no Star child). First
	 * consumer: `HxStatement.ReturnStmt`.
	 */
	public static function isAltBodyPolicyKwBranch(branch: ShapeNode): Bool {
		return branch.children.length == 1
			&& (branch.children[0].kind == Ref && (branch.readMetaString(':kw') != null && branch.fmtReadString('bodyPolicy') != null));
	}

	/**
	 * ω-paren-wrap-source-newline: True when the branch is a single-Ref
	 * `@:wrap(open, close)` Alt-ctor (no `@:kw`, has both `@:lead` and
	 * `@:trail`) opting in via parameterless `@:fmt(captureWrapOpenNewline)`.
	 * Such ctors grow a positional `wrapOpenNewline:Bool` arg in the synth
	 * pair so the writer can route between two break shapes at write time:
	 *   - source had `\n` after open delim (`paramOpenedNewline=true`)  -->
	 *     break shape `(\n<inner>\n)` (open delim followed by hardline,
	 *     close on its own line); matches author intent for chains where
	 *     the source already broke after `(`.
	 *   - source had no `\n` after open delim (`paramOpenedNewline=false`)
	 *     --> existing glue shape `(<inner>\n)` from the chain emit's
	 *     `OptHardlineSkipAtOpenDelim`. Items[0] glued to enclosing `(`.
	 *
	 * Disjoint from `isAltBodyPolicyKwBranch` (kw absent vs required) and
	 * from the close/postfix-trailing predicates (Ref vs Star child).
	 * Plain mode keeps the original ctor arity and the writer falls back
	 * to the unconditional glue shape. First consumer: `HxExpr.ParenExpr`.
	 */
	public static function isAltWrapOpenNewlineBranch(branch: ShapeNode): Bool {
		if (branch.children.length != 1) return false;
		if (branch.children[0].kind != Ref) return false;
		if (branch.hasMeta(':kw')) return false;
		// `@:wrap(o,c)` is the canonical shorthand for `@:lead(o) + @:trail(c)`
		// at this opt-in's first consumer. `Lit.annotate` populates
		// `lit.leadText`/`lit.trailText` from either form, but that runs AFTER
		// `arm()` (see `Build.run` ordering -- same constraint motivating
		// raw-meta probes elsewhere in this file). Use `hasMeta` rather than
		// `readMetaString` because `@:wrap` carries TWO params (open + close)
		// and `readMetaString` requires exactly one. Both authoring forms
		// grow the same lit pair downstream.
		final hasWrap: Bool = branch.hasMeta(':wrap');
		final hasLeadTrail: Bool = branch.hasMeta(':lead') && branch.hasMeta(':trail');
		return (hasWrap || hasLeadTrail) && branch.fmtHasFlag('captureWrapOpenNewline');
	}

	/**
	 * ω-keep-kw-newline (increment 1b) — true when the branch is a single-Ref
	 * mandatory-`@:kw` Alt ctor carrying `@:fmt(captureKwNewline)` (the
	 * VarStmt-family: `VarStmt` / `FinalStmt` / `StaticVarStmt` /
	 * `StaticFinalStmt`). Such ctors grow a positional `kwNewline:Bool` arg in
	 * the synth pair so the `HxVarDecl` multiVar fold can reproduce the
	 * source-author `var`→head newline under `WrapMode.Keep`. Requires the
	 * mandatory `@:kw` for the parser commit point. Disjoint from
	 * `isAltWrapOpenNewlineBranch` (those are kw-less @:wrap ctors). Reads the
	 * flag via `fmtHasFlag`, which works at arm-time (`base.meta` populated by
	 * `ShapeBuilder` before `arm()` runs — same path the sister predicates
	 * rely on). First consumers: `HxStatement.{VarStmt, FinalStmt,
	 * StaticVarStmt, StaticFinalStmt}`.
	 */
	public static function isAltKwNewlineBranch(branch: ShapeNode): Bool {
		return branch.children.length == 1
			&& (branch.children[0].kind == Ref && (branch.hasMeta(':kw') && branch.fmtHasFlag('captureKwNewline')));
	}

	/**
	 * ω-keep-chain — true when the branch is a binary chain enum ctor
	 * carrying `@:fmt(captureChainNewline)`. Two consumer families:
	 *  - `@:infix` Pratt chain ctors `HxExpr.Add` / `Sub` / `And` / `Or`
	 *    (increment 2 — the `lowerPrattLoop` operator-match site captures the
	 *    gap newline before the ctor's RIGHT operand);
	 *  - `@:postfix('.')` method-chain ctor `HxExpr.FieldAccess` (increment 9
	 *    — the `lowerPostfixLoop` gap before the `.` dispatch captures the
	 *    source newline before the `.field` segment).
	 * Such ctors grow a positional `chainNewline:Bool` arg in the synth pair
	 * so the chain emit (`BinaryChainEmit` / `MethodChainEmit`) can reproduce
	 * the source per-boundary line breaks under `WrapMode.Keep`. Requires
	 * exactly two operand children (`left,right` infix / `operand,field`
	 * postfix). Disjoint from every sister predicate (chain ctors carry no
	 * `@:kw` / `@:lead` / `@:trail` / `@:wrap` / bodyPolicy, and the
	 * `@:postfix('.')` FieldAccess carries no close delimiter so it is NOT a
	 * postfix-close-trailing branch). Consumers: `HxExpr.{Add, Sub, And, Or,
	 * FieldAccess}`.
	 */
	public static function isAltChainNewlineBranch(branch: ShapeNode): Bool {
		return branch.children.length == 2
			&& ((branch.hasMeta(':infix') || branch.hasMeta(':postfix')) && branch.fmtHasFlag('captureChainNewline'));
	}

	/**
	 * ω-keep-chain-receiver-comment — true when the branch is the
	 * `@:postfix('.')` method-chain ctor (`HxExpr.FieldAccess`): a postfix
	 * branch carrying `@:fmt(captureChainNewline)`. Such a branch grows a
	 * positional `chainLeadComment:Null<String>` slot (in addition to
	 * `chainNewline:Bool`) holding the verbatim trailing comment of its operand
	 * captured before the `.` dispatch. Strictly narrower than
	 * `isAltChainNewlineBranch` — the infix chain ctors (Add/Sub/And/Or) are
	 * excluded since they capture operand trivia through the Pratt stash, not a
	 * dedicated slot. Two operand children (`operand,field`).
	 */
	public static function isPostfixChainCommentBranch(branch: ShapeNode): Bool {
		return branch.children.length == 2 && (branch.hasMeta(':postfix') && branch.fmtHasFlag('captureChainNewline'));
	}

	private static function shapeToComplexType(node: ShapeNode, synthPack: Array<String>): ComplexType {
		return switch node.kind {
			case Ref:
				final refName: String = node.annotations.get('base.ref');
				final base: ComplexType = refIsBearing(refName)
					? TPath({ pack: synthPack, name: leafOf(refName) + PAIRED_SUFFIX, params: [] })
					: TPath({ pack: packOf(refName), name: leafOf(refName), params: [] });
				return wrapOptional(node, base);
			case Star:
				final elementCT: ComplexType = shapeToComplexType(node.children[0], synthPack);
				final wrapped: ComplexType = node.annotations.get('trivia.starCollects') == true
					? TPath({ pack: ['anyparse', 'runtime'], name: 'Trivial', params: [TPType(elementCT)] })
					: elementCT;
				return wrapOptional(node, TPath({ pack: [], name: 'Array', params: [TPType(wrapped)] }));
			case Terminal:
				final tp: Null<String> = node.annotations.get('base.typePath');
				if (tp != null) return wrapOptional(node, TPath({ pack: packOf(tp), name: leafOf(tp), params: [] }));
				final under: String = node.annotations.get('base.underlying');
				return wrapOptional(node, TPath({ pack: [], name: under, params: [] }));
			case _:
				Context.fatalError('TriviaTypeSynth: unexpected node kind ${node.kind} in field-shape', Context.currentPos());
				throw 'unreachable';
		};
	}

	private static inline function wrapOptional(node: ShapeNode, base: ComplexType): ComplexType {
		return node.annotations.get('base.optional') == true ? TPath({ pack: [], name: 'Null', params: [TPType(base)] }) : base;
	}

	private static function refIsBearing(refName: String): Bool {
		for (shape in shapes) {
			final node: Null<ShapeNode> = shape.rules.get(refName);
			if (node != null) return node.annotations.get('trivia.bearing') == true;
		}
		return false;
	}

	private static function packOf(qualifiedName: String): Array<String> {
		final idx: Int = qualifiedName.lastIndexOf('.');
		return idx == -1 ? [] : qualifiedName.substring(0, idx).split('.');
	}

	private static function leafOf(qualifiedName: String): String {
		final idx: Int = qualifiedName.lastIndexOf('.');
		return idx == -1 ? qualifiedName : qualifiedName.substring(idx + 1);
	}

}
#end
