package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Expr;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * What one synthesized paired Alt CONSTRUCTOR looks like, and which
 * extra positional argument each branch shape earns.
 *
 * An `@:trivia` enum's paired `*T` twin mirrors its constructors arm by
 * arm, and a branch whose SHAPE opts into a source-fidelity signal
 * grows extra positional arguments beyond the ones the plain ctor has:
 * a `closeTrailing` comment after a postfix close, a `trailPresent`
 * flag for an optional trail literal, a verbatim `sourceText` slice, a
 * `kwNewline` / `chainNewline` / `bodyOnSameLine` layout witness. Each
 * `is…Branch` member here answers "does THIS shape earn THAT argument"
 * off the branch's raw metadata and children, `extraAltArgs` folds the
 * answers into the argument list, and `buildEnumCtor` assembles the
 * constructor around it.
 *
 * The predicates run at `arm()` time — BEFORE the strategy annotate
 * pass — so each reads `base.meta` / `trivia.*` directly rather than
 * the `lit.*` and `postfix.*` slots that do not exist yet. That
 * timing constraint is the reason they are a family rather than
 * open-coded at their call sites, and the reason the writer side asks
 * the SAME questions through these same members instead of re-deriving
 * them.
 *
 * Split out of `TriviaTypeSynth`, which kept the name vocabulary, the
 * atomic `defineModule` arm and the type-definition assembler. Nothing
 * here reads state: that class declares no instance field, so the seam
 * is the QUESTION each member answers, not a state boundary.
 */
@:access(anyparse.macro.TriviaTypeSynth)
final class TriviaPairAltCtor {

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
		if (star.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] != true) return false;
		// Tighten: `trivia.starCollects` is also set by `markStarsWithTrivia`
		// for `:trivia` Seq branches with a single Star child. Those are NOT
		// postfix and must not grow a `closeTrailing` slot — Lowering's
		// `lowerPostfixLoop` is the only producer for the slot. Read
		// `:postfix` from raw `base.meta` (Postfix strategy hasn't run yet)
		// to ensure the branch is a postfix ctor.
		final meta: Null<Metadata> = branch.annotations[AnnotationKeys.BASE_META];
		return meta != null && meta.exists(entry -> entry.name == ':postfix' && entry.params.length == 2);
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
		return star.kind == Star
			&& (star.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true && branch.readMetaString(':trail') != null);
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
	 * struct-field analog of `isAltTrailOptBranch`. Gates the
	 * `buildTypeDefinition` Seq arm where every matching field grows an
	 * `@:optional Null<Bool>` `<field>TrailPresent` slot (via
	 * `buildStructFieldTrailPresentSlot`); the parser captures the
	 * `matchLit` result into it. The writer does not yet read the slot —
	 * struct-field `@:trailOpt` stays writer-canonical (always re-emits
	 * the trail literal), so source presence of the optional trail (e.g.
	 * the nested `;` in `wrapping/issue_366_nested_array_comprehension`)
	 * is not yet preserved; wiring the writer-side gate is the remaining
	 * step.
	 *
	 * Disjoint from `isAltTrailOptBranch` (struct typedef field vs
	 * enum Alt branch — orthogonal contexts; same `@:trailOpt` meta
	 * but different host kind).
	 *
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
	 * ω-keep-infix-postop-comment — true for an `@:infix` chain ctor
	 * (Add/Sub/And/Or) carrying `@:fmt(captureChainNewline)`. Such ctors grow a
	 * positional `opAfterComment:Null<String>` slot (after `chainLeadComment`)
	 * holding the verbatim same-line comment trailing the OPERATOR (before the
	 * right operand). Excludes the postfix FieldAccess ctor (no such operator
	 * gap), so its arity is unchanged.
	 */
	public static function isInfixChainBranch(branch: ShapeNode): Bool {
		return branch.children.length == 2 && branch.hasMeta(':infix') && branch.fmtHasFlag('captureChainNewline');
	}

	/**
	 * ω-keep-infix-rhs-comment — true for any `@:infix` binop ctor carrying
	 * `@:fmt(captureRhsTrail)`. Grows an `opRhsTrailComment:Null<String>` slot
	 * (the LAST chain-family slot) holding the verbatim same-line comment
	 * trailing the RIGHT operand (position #3). Independent of
	 * `captureChainNewline`, so a chain ctor may carry both.
	 */
	public static function isRhsTrailBranch(branch: ShapeNode): Bool {
		return branch.children.length == 2 && branch.hasMeta(':infix') && branch.fmtHasFlag('captureRhsTrail');
	}

	/**
	 * ω-keep-ternary-operand-comment — true for a `@:ternary(op, sep, prec)`
	 * mixfix ctor carrying `@:fmt(captureTernaryTrail)` (`HxExpr.Ternary`).
	 * Such a branch grows TWO positional `Null<String>` slots holding the
	 * verbatim same-line comments trailing its first two operands: the
	 * condition (before `?`) and the then-branch (before `:`). Three operand
	 * children by construction, so it is disjoint from every two-child chain
	 * predicate above — the slots append after the whole chain family.
	 *
	 * The else-branch needs no slot: its trailing comment sits at the end of
	 * the enclosing construct and is already captured by that construct's own
	 * trailing slot (statement `;`, call-arg sep, …).
	 */
	public static function isTernaryTrailBranch(branch: ShapeNode): Bool {
		return branch.children.length == 3 && branch.hasMeta(':ternary') && branch.fmtHasFlag('captureTernaryTrail');
	}

	/**
	 * ω-postfix-op-space — true when the branch is a word-op postfix ctor
	 * opting into source-faithful operator spacing via
	 * `@:fmt(capturePostfixOpSpace)` (`HxExpr.CondSpliceTail`). Such a
	 * branch grows a positional `opSpaceBefore:Bool` slot capturing
	 * whether whitespace separated the operand from the operator; the
	 * writer's word-postfix pad reads it instead of hardcoding `' op '`.
	 */
	public static function isPostfixOpSpaceBranch(branch: ShapeNode): Bool {
		return branch.children.length == 2 && branch.hasMeta(':postfix') && branch.fmtHasFlag('capturePostfixOpSpace');
	}

	/**
	 * Number of positional synth args `buildEnumCtor` appends to a paired
	 * Alt ctor beyond its declared children — the single source of truth
	 * for the trivia-mode ctor arity every pattern-building consumer
	 * (`WriterLowering.branchExtraArgs`, `AstPredLowering`) must agree
	 * on with the synth side. See the per-slot ω-comments in
	 * `buildEnumCtor` for what each slot captures. The term↔push-block
	 * mapping is NOT one-to-one:
	 *
	 *  - the `(hasCloseTrailing || hasTrailOptFlag || hasCaptureSource)`
	 *    OR-collapse counts THREE push blocks as at most one slot. That
	 *    rests on an exclusivity ASSUMPTION: close-trailing is
	 *    structurally disjoint from the other two (Star vs single-Ref
	 *    child), but trailOpt and captureSource are both single-Ref
	 *    predicates excluded only by convention — no current ctor
	 *    carries both metas. A ctor combining them would push two slots
	 *    while being counted as one, leaving every pattern one wildcard
	 *    short.
	 *  - the `hasOpenTrailing` / postfix-close groups reserve multiple
	 *    slots at once (open-trailing brings THREE — `openTrailing` +
	 *    `trailingBlankBefore` + `trailingLeading`; postfix-close the
	 *    five call-trivia positionals).
	 *  - `isInfixChainBranch` / `isRhsTrailBranch` / `isTernaryTrailBranch`
	 *    have push blocks with no dedicated `has*` local — they contribute
	 *    directly in the return expression. `isTernaryTrailBranch` reserves
	 *    TWO (`condTrailComment` + `thenTrailComment`).
	 */
	public static function extraAltArgs(branch: ShapeNode): Int {
		final hasCloseTrailing: Bool = isAltCloseTrailingBranch(branch);
		final hasTrailOptFlag: Bool = isAltTrailOptBranch(branch);
		final hasCaptureSource: Bool = isCaptureSourceBranch(branch);
		final hasBodyPolicyKw: Bool = isAltBodyPolicyKwBranch(branch);
		final hasWrapOpenNewline: Bool = isAltWrapOpenNewlineBranch(branch);
		final hasKwNewline: Bool = isAltKwNewlineBranch(branch);
		final hasChainNewline: Bool = isAltChainNewlineBranch(branch);
		// Deliberately the SAME predicate as `hasChainNewline`, not a
		// copy-paste bug: `buildEnumCtor` pushes the `chainLeadComment`
		// slot under the same gate as `chainNewline`, so the arity
		// reserves both (the writer's FieldAccess pattern destructures
		// them separately).
		final hasChainLeadComment: Bool = isAltChainNewlineBranch(branch);
		final hasPostfixOpSpace: Bool = isPostfixOpSpaceBranch(branch);
		final hasOpenTrailing: Bool = hasCloseTrailing && branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse');
		final hasPostfixCloseTrailing: Bool = isPostfixCloseTrailingBranch(branch);
		final hasArrayLitTrailPresent: Bool = hasOpenTrailing && branch.hasMeta(':sep');
		// CHECKSTYLE:OFF
		return ((hasCloseTrailing || hasTrailOptFlag || hasCaptureSource) ? 1 : 0) + (hasOpenTrailing ? 3 : 0)
			+ (hasArrayLitTrailPresent ? 1 : 0) + (hasBodyPolicyKw ? 1 : 0) + (hasWrapOpenNewline ? 1 : 0) + (hasKwNewline ? 1 : 0)
			+ (hasChainNewline ? 1 : 0) + (hasChainLeadComment ? 1 : 0) + (hasPostfixOpSpace ? 1 : 0) + (hasPostfixCloseTrailing ? 5 : 0)
			+ (isInfixChainBranch(branch) ? 1 : 0) + (isRhsTrailBranch(branch) ? 1 : 0) + (isTernaryTrailBranch(branch) ? 2 : 0);
		// CHECKSTYLE:ON
	}


	public static function buildEnumCtor(branch: ShapeNode, pos: Position, synthPack: Array<String>): Field {
		final ctorName: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		if (branch.children.length == 0) return {
			name: ctorName,
			kind: FVar(null),
			pos: pos,
			access: []
		};
		final args: Array<FunctionArg> = [
			for (arg in branch.children)
				{
					name: (arg.annotations.get(AnnotationKeys.BASE_FIELD_NAME): String),
					type: TriviaTypeSynth.shapeToComplexType(arg, synthPack)
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
				// their 5-arg shape.
				// ω-blockended-trivia-meta-arity: `hasMeta` over
				// `readMetaString` so `@:sep('text', tailRelax, blockEnded)`
				// (3-arg form) gates the same as 1-arg `@:sep(',')`. Sister
				// fix in `buildStarTrailingSlots`.
				if (branch.hasMeta(':sep')) {
					args.push({ name: TriviaTypeSynth.TRAIL_PRESENT_ARG_NAME, type: boolCT });
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
			args.push({ name: TriviaTypeSynth.TRAIL_PRESENT_ARG_NAME, type: boolCT });
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
			args.push({ name: TriviaTypeSynth.SOURCE_TEXT_ARG_NAME, type: strCT });
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
			args.push({ name: TriviaTypeSynth.BODY_ON_SAME_LINE_ARG_NAME, type: boolCT });
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
			args.push({ name: TriviaTypeSynth.WRAP_OPEN_NEWLINE_ARG_NAME, type: boolCT });
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
			args.push({ name: TriviaTypeSynth.KW_NEWLINE_ARG_NAME, type: boolCT });
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
			args.push({ name: TriviaTypeSynth.CHAIN_NEWLINE_ARG_NAME, type: boolCT });
		}
		// ω-keep-chain-receiver-comment + ω-keep-infix-operand-comment: every chain
		// ctor — the `@:postfix('.')` FieldAccess AND the `@:infix` Add/Sub/And/Or —
		// grows a `chainLeadComment:Null<String>` slot immediately after its
		// `chainNewline:Bool` slot, holding the verbatim trailing comment of its left
		// operand captured before the operator (the dot gap for FieldAccess, the
		// operator gap for the infix chain ctors). Gated by isAltChainNewlineBranch so
		// it appends after chainNewline and stays disjoint from the closeTrailing
		// family below (chain ctors carry no close delimiter).
		if (isAltChainNewlineBranch(branch)) {
			final strCT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
			final nullStrCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT)] });
			args.push({ name: TriviaTypeSynth.CHAIN_LEAD_COMMENT_ARG_NAME, type: nullStrCT });
		}
		// ω-keep-infix-postop-comment: infix chain ctors also grow an
		// `opAfterComment:Null<String>` slot (after chainLeadComment) holding the
		// comment trailing the operator. Infix-only (FieldAccess excluded).
		if (isInfixChainBranch(branch)) {
			final strCT2: ComplexType = TPath({ pack: [], name: 'String', params: [] });
			final nullStrCT2: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT2)] });
			args.push({ name: TriviaTypeSynth.OP_AFTER_COMMENT_ARG_NAME, type: nullStrCT2 });
		}
		// ω-keep-infix-rhs-comment: `opRhsTrailComment` slot on any @:infix ctor
		// carrying @:fmt(captureRhsTrail) (position #3, right-operand trailing).
		if (isRhsTrailBranch(branch)) {
			final strCT3: ComplexType = TPath({ pack: [], name: 'String', params: [] });
			final nullStrCT3: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT3)] });
			args.push({ name: TriviaTypeSynth.OP_RHS_TRAIL_COMMENT_ARG_NAME, type: nullStrCT3 });
		}
		// ω-keep-ternary-operand-comment: the `@:ternary` mixfix ctor grows TWO
		// operand-trailing slots (cond before `?`, then-branch before `:`).
		// Three operand children, so this gate is disjoint from every two-child
		// chain gate above and the pair appends after the whole chain family.
		if (isTernaryTrailBranch(branch)) {
			final strCT4: ComplexType = TPath({ pack: [], name: 'String', params: [] });
			final nullStrCT4: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(strCT4)] });
			args.push({ name: TriviaTypeSynth.TERNARY_COND_TRAIL_ARG_NAME, type: nullStrCT4 });
			args.push({ name: TriviaTypeSynth.TERNARY_THEN_TRAIL_ARG_NAME, type: nullStrCT4 });
		}
		// ω-postfix-op-space: word-op postfix ctors opting into source-faithful
		// operator spacing grow `opSpaceBefore:Bool` as the LAST appended slot
		// (mirrors the AltSlot declaration order the writer's walker relies on).
		if (isPostfixOpSpaceBranch(branch)) {
			final opSpaceBoolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
			args.push({ name: TriviaTypeSynth.POSTFIX_OP_SPACE_ARG_NAME, type: opSpaceBoolCT });
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
			// `ctx.pendingTrivia` drained from kw-Ref rules
			// ahead of the per-iter trivia collection,
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
			// ω-callarg-empty-inner-comment: empty-parens inner comment slot
			// (`f(/* c */)`). Holds a comment captured between the postfix open
			// and close when no argument consumed it; null otherwise. Sibling of
			// closeTrailing (reuses `nullStrCT`), read by the writer via
			// `argNames[5]`.
			args.push({ name: 'argsInnerComment', type: nullStrCT });
			// ω-keep-call-leading-comment: an inline block comment that precedes
			// the callee of a call (`/* c */ f()` / `a * /* c */ f()`) — captured
			// by the parser from `ctx.pendingTrivia` BEFORE the args loop can
			// drain it into an argument's leading slot. Holds the pre-callee
			// comment so the writer emits it before the operand instead of
			// relocating it inside the argument list; null otherwise. Read by the
			// writer via `argNames[6]`.
			args.push({ name: 'callLeadingComment', type: nullStrCT });
		}
		return {
			name: ctorName,
			kind: FFun({ args: args, ret: null, expr: null }),
			pos: pos,
			access: []
		};
	}

}
#end
