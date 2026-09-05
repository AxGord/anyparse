package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.macro.MacroNames.*;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * How a paired `*T` value converts to and from its raw sibling.
 *
 * `TriviaTypeSynth` synthesises, for every trivia-bearing rule, a `*T`
 * twin carrying the source-fidelity slots the plain type has no room
 * for. Both surfaces stay live — a transform written against the plain
 * AST must be able to run on a trivia parse and hand the result back —
 * so each pair needs two total functions: `pairedToRaw` drops the
 * slots, `rawToPaired` supplies the defaults that make a plain value a
 * legal trivia value. This module answers what those two function
 * bodies look like for one rule shape: a Seq (struct field by field),
 * an Alt (constructor arm by arm, with the extra synthesized arguments
 * counted and defaulted), and the per-shape wrap / unwrap that carries
 * `Null<T>`, `Array<T>` and `Trivial<T>` through unchanged.
 *
 * The whole family enters through `buildConvertersClass`, which
 * `TriviaTypeSynth.arm` calls once per synth module, and it is closed
 * apart from `countAltExtras` — the Alt extra-argument arity, which the
 * writer side reads too.
 *
 * Split out of `TriviaTypeSynth`. Nothing here reads state: that class
 * declares no instance field, so the seam is the QUESTION its members
 * answer, not a state boundary. Unlike the other two splits it leans
 * hard on what stayed: 39 references across 27 of `TriviaTypeSynth`'s
 * names — the slot-name vocabulary and the shape predicates — reached
 * QUALIFIED under the class-level `@:access`.
 */
@:access(anyparse.macro.TriviaTypeSynth)
final class TriviaPairConverters {

	private static inline final CONVERTERS_CLASS_NAME: String = 'Converters';

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

	public static function buildConvertersClass(convertedNames: Array<String>, synthPack: Array<String>): TypeDefinition {
		final pos: Position = Context.currentPos();
		convertedNames.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		final shape: ShapeBuilder.ShapeResult = TriviaTypeSynth.shapes[TriviaTypeSynth.shapes.length - 1];
		final fns: Array<Field> = [];
		for (origName in convertedNames) {
			final node: Null<ShapeNode> = shape.rules[origName];
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
			meta: [{ name: ':nullSafety', params: [macro Strict], pos: pos }]
		};
	}

	/**
	 * Count the trivia-only positional args appended to an Alt branch
	 * AFTER the original ctor children. Must mirror exactly the gates
	 * applied in `buildEnumCtor`'s second half — every predicate there
	 * adds a positional arg; this function adds the same arg counts.
	 */
	public static function countAltExtras(branch: ShapeNode): Int {
		var n: Int = 0;
		if (TriviaPairAltCtor.isAltCloseTrailingBranch(branch)) {
			n++; // closeTrailing
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) {
				// openTrailing + trailingBlankBefore + trailingLeading
				n += 3; // noqa: magic-number
				// ω-arraylit-source-trail-comma: + trailPresent when @:sep is
				// present (mirrors `buildEnumCtor` gate).
				// ω-blockended-trivia-meta-arity: hasMeta over
				// readMetaString — must match `buildEnumCtor` L1093 gate so the
				// paired-to-raw switch pattern's `_` placeholder count stays
				// in sync with the Alt ctor's extra-arg count. Latent today
				// (no `:trivia + :lead + :trail + :sep(>1-arg)` Alt branch
				// in the live grammar) but blocks the next BlockStmt /
				// BlockExpr migration.
				if (branch.hasMeta(':sep')) n++;
			}
		}
		if (TriviaPairAltCtor.isAltTrailOptBranch(branch)) n++; // trailPresent
		if (TriviaPairAltCtor.isCaptureSourceBranch(branch)) n++; // sourceText
		if (TriviaPairAltCtor.isAltBodyPolicyKwBranch(branch)) n++; // bodyOnSameLine
		if (TriviaPairAltCtor.isAltWrapOpenNewlineBranch(branch)) n++; // wrapOpenNewline
		if (TriviaPairAltCtor.isAltKwNewlineBranch(branch)) n++; // kwNewline (increment 1b)
		if (TriviaPairAltCtor.isAltChainNewlineBranch(branch)) n++; // chainNewline (increment 2)
		if (TriviaPairAltCtor.isAltChainNewlineBranch(branch)) n++; // chainLeadComment (chain receiver/operand comment)
		if (TriviaPairAltCtor.isInfixChainBranch(branch)) n++; // opAfterComment (infix post-operator comment)
		if (TriviaPairAltCtor.isRhsTrailBranch(branch)) n++; // opRhsTrailComment (infix right-operand trailing comment)
		if (TriviaPairAltCtor.isTernaryTrailBranch(branch)) n += 2; // condTrailComment + thenTrailComment (ω-keep-ternary-operand-comment)
		if (TriviaPairAltCtor.isPostfixOpSpaceBranch(branch)) n++; // opSpaceBefore (ω-postfix-op-space)
		// ω-D9A-keep-callargs-v2 + siblings: the postfix close-trailing gate adds
		// FIVE slots in `buildEnumCtor` — closeTrailing, argsOpenNewline,
		// argsCloseNewline, argsInnerComment, callLeadingComment. Keep the count in
		// sync so the `pairedToRaw` switch pattern's `_` placeholder count matches
		// the paired ctor's arity.
		if (TriviaPairAltCtor.isPostfixCloseTrailingBranch(branch)) n += 5; // noqa: magic-number
		return n;
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
		final pairedSimple: String = TriviaTypeSynth.leafOf(origName) + TriviaTypeSynth.PAIRED_SUFFIX;
		final rawSimple: String = TriviaTypeSynth.leafOf(origName);
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
			name: 'pairedToRaw_$rawSimple',
			access: [APublic, AStatic],
			pos: pos,
			kind: FFun({ args: [{ name: 'value', type: pairedCT }], ret: rawCT, expr: body })
		};
	}

	private static function buildPairedToRawSeqBody(origNode: ShapeNode, pos: Position): Expr {
		final entries: Array<{ field: String, expr: Expr }> = [];
		for (child in origNode.children) {
			final fieldName: String = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			final access: Expr = { expr: EField(macro value, fieldName), pos: pos };
			entries.push({ field: fieldName, expr: shapePairedToRawUnwrap(access, child, pos) });
		}
		final structLit: Expr = { expr: EObjectDecl([for (e in entries) { field: e.field, expr: e.expr }]), pos: pos };
		return macro return $structLit;
	}

	private static function buildPairedToRawAltBody(origName: String, origNode: ShapeNode, pos: Position): Expr {
		final rawSimple: String = TriviaTypeSynth.leafOf(origName);
		final rawPack: Array<String> = packOf(origName);
		final cases: Array<Case> = [];
		for (branch in origNode.children) {
			final ctorName: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
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
			final binders: Array<Expr> = [
				for (i in 0...origArgCount)
					{
						expr: EConst(CIdent((branch.children[i].annotations.get(AnnotationKeys.BASE_FIELD_NAME): String))),
						pos: pos
					}
			];
			for (_ in 0...extraCount) binders.push({ expr: EConst(CIdent('_')), pos: pos });
			final pattern: Expr = { expr: ECall({ expr: EConst(CIdent(ctorName)), pos: pos }, binders), pos: pos };
			// Body: RawType.CtorName(unwrap(arg0), unwrap(arg1), ...)
			final unwrapArgs: Array<Expr> = [];
			for (i in 0...origArgCount) {
				final argNode: ShapeNode = branch.children[i];
				final argName: String = argNode.annotations[AnnotationKeys.BASE_FIELD_NAME];
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
				final refName: String = node.annotations[AnnotationKeys.BASE_REF];
				final optional: Bool = node.annotations[AnnotationKeys.BASE_OPTIONAL] == true;
				if (!TriviaTypeSynth.refIsBearing(refName)) return access; // raw type already
				final fnName: String = 'pairedToRaw_${TriviaTypeSynth.leafOf(refName)}';
				final call: Expr = { expr: ECall({ expr: EConst(CIdent(fnName)), pos: pos }, [access]), pos: pos };
				return optional ? macro ($access == null ? null : $call) : call;
			case Star:
				final elem: ShapeNode = node.children[0];
				final triviaWrap: Bool = node.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
				final optional: Bool = node.annotations[AnnotationKeys.BASE_OPTIONAL] == true;
				final innerAccess: Expr = triviaWrap ? (macro t.node) : (macro e);
				final iterVar: String = triviaWrap ? 't' : 'e';
				final inner: Expr = shapePairedToRawUnwrap(innerAccess, elem, pos);
				// Wadler trick — `[for (x in arr) expr]` is the comprehension; produce it via EFor inside EArrayDecl
				// Actually Haxe accepts EMeta? Simpler: build via parser-friendly Expr
				final compr: Expr = {
					expr: EArrayDecl([
						{
							expr: EFor({ expr: EBinop(OpIn, { expr: EConst(CIdent(iterVar)), pos: pos }, access), pos: pos }, inner),
							pos: pos
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
		final pairedSimple: String = TriviaTypeSynth.leafOf(origName) + TriviaTypeSynth.PAIRED_SUFFIX;
		final rawSimple: String = TriviaTypeSynth.leafOf(origName);
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
			name: 'rawToPaired_$rawSimple',
			access: [APublic, AStatic],
			pos: pos,
			kind: FFun({ args: [{ name: 'value', type: rawCT }], ret: pairedCT, expr: body })
		};
	}

	private static function buildRawToPairedSeqBody(origNode: ShapeNode, pos: Position): Expr {
		final entries: Array<{ field: String, expr: Expr }> = [];
		for (child in origNode.children) {
			final fieldName: String = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			final access: Expr = { expr: EField(macro value, fieldName), pos: pos };
			entries.push({ field: fieldName, expr: shapeRawToPairedWrap(access, child, pos) });
			// Append trivia-only sibling fields with default empty values —
			// mirror the gates applied in `buildTypeDefinition`'s Seq path.
			if (TriviaPairSlots.isOptionalKw(child)) {
				entries.push({ field: fieldName + TriviaTypeSynth.AFTER_KW_SUFFIX, expr: macro (null: Null<String>) });
				entries.push({ field: fieldName + TriviaTypeSynth.KW_LEADING_SUFFIX, expr: macro ([]: Array<String>) });
				entries.push({ field: fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX, expr: macro false });
				entries.push({ field: fieldName + TriviaTypeSynth.BODY_ON_SAME_LINE_SUFFIX, expr: macro false });
				entries.push({ field: fieldName + TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX, expr: macro ([]: Array<String>) });
				entries.push({ field: fieldName + TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX, expr: macro (null: Null<String>) });
			}
			if (TriviaPairSlots.isTriviaStarField(child)) pushRawToPairedStarSlots(entries, fieldName, child);
			// ω-condcomp-body-leading-sep: trivia-independent SepBefore
			// default for raw→paired upcasts. Sibling of the
			// gate in `buildTypeDefinition`.
			if (TriviaPairSlots.isSepBeforeOptStarField(child))
				entries.push({ field: fieldName + TriviaTypeSynth.SEP_BEFORE_SUFFIX, expr: macro false });
			if (TriviaPairSlots.isBareNonFirstRef(child, origNode) || TriviaPairSlots.isBareFirstStarNlOptIn(child, origNode))
				entries.push({ field: fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX, expr: macro false });
			// ω-598-member-leading-comment: raw→paired upcast default — preWrite
			// plugin rewrites carry no source comments, so the slot defaults to
			// the empty array (byte-inert emit). Mirrors the BeforeNewline
			// sibling above, gated on the same bare-Ref host.
			if (TriviaPairSlots.isBareNonFirstRef(child, origNode))
				entries.push({ field: fieldName + TriviaTypeSynth.BEFORE_LEADING_SUFFIX, expr: macro ([]: Array<String>) });
			// ω-region-prefix-blank: raw→paired upcast default — a preWrite plugin
			// rewrite carries no source blank, so the slot defaults to `false`
			// (byte-inert emit). Same host gate as the synth.
			if (TriviaPairSlots.isBeforeBlankRef(child, origNode))
				entries.push({ field: fieldName + TriviaTypeSynth.BEFORE_BLANK_SUFFIX, expr: macro false });
			if (TriviaPairSlots.isTrailRef(child))
				entries.push({ field: fieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX, expr: macro (null: Null<String>) });
			if (TriviaPairSlots.isBeforeTrailRef(child))
				entries.push({ field: fieldName + TriviaTypeSynth.BEFORE_TRAIL_SUFFIX, expr: macro (null: Null<String>) });
			if (TriviaPairSlots.isPadTrailingTerminalRef(child))
				entries.push({ field: fieldName + TriviaTypeSynth.NEWLINE_AFTER_SUFFIX, expr: macro false });
			// ω-condition-wrap-keep: raw→paired upcast default for the
			// `<field>CondOpenNewline:Bool` slot. preWrite plugin rewrites
			// don't preserve the source's post-`(` break, so the upcast
			// defaults to `false` → the writer falls back to the width-
			// driven glue. Mirrors the `isPadTrailingTerminalRef` sibling.
			if (TriviaPairSlots.isCondOpenNewlineRef(child))
				entries.push({ field: fieldName + TriviaTypeSynth.CONDITION_OPEN_NEWLINE_SUFFIX, expr: macro false });
			// ω-struct-trailopt-source-track: struct
			// typedef fields carrying `@:trailOpt(LIT)` grow a
			// `<field>TrailPresent:Null<Bool>` slot on the paired-T struct
			// (synthesised by `buildStructFieldTrailPresentSlot`). Default
			// to `null` on raw→paired upcasts — preWrite plugin rewrites
			// don't preserve source presence, so the writer falls back to
			// canonical re-emission. The slot is `@:optional` so omission
			// would also compile, but explicit `null` push mirrors the
			// `isTrailRef` / `isPadTrailingTerminalRef` sibling pattern and
			// keeps the raw→paired struct literal shape stable.
			if (TriviaPairAltCtor.isStructFieldTrailOpt(child))
				entries.push({ field: fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX, expr: macro (null: Null<Bool>) });
		}
		final structLit: Expr = { expr: EObjectDecl([for (e in entries) { field: e.field, expr: e.expr }]), pos: pos };
		return macro return $structLit;
	}

	/**
	 * The raw→paired upcast defaults for ONE trivia Star field's trailing slots.
	 * Extracted from `buildRawToPairedSeqBody` so that function stays under the
	 * complexity gate; the gates here must keep matching `buildStarTrailingSlots`.
	 */
	private static function pushRawToPairedStarSlots(
		entries: Array<{ field: String, expr: Expr }>, fieldName: String, child: ShapeNode
	): Void {
		entries.push({ field: fieldName + TriviaTypeSynth.TRAILING_BLANK_BEFORE_SUFFIX, expr: macro false });
		// ω-keep-fnsig-newline: sibling default for the close-newline
		// slot (raw→paired upcast). Mirrors TRAILING_BLANK_BEFORE_SUFFIX.
		entries.push({ field: fieldName + TriviaTypeSynth.TRAILING_NEWLINE_BEFORE_SUFFIX, expr: macro false });
		entries.push({ field: fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX, expr: macro ([]: Array<String>) });
		if (child.readMetaString(':trail') != null)
			entries.push({ field: fieldName + TriviaTypeSynth.TRAILING_CLOSE_SUFFIX, expr: macro (null: Null<String>) });
		if (child.readMetaString(':lead') != null && !child.hasMeta(':tryparse'))
			entries.push({ field: fieldName + TriviaTypeSynth.TRAILING_OPEN_SUFFIX, expr: macro (null: Null<String>) });
		if (child.hasMeta(':tryparse') && child.fmtHasFlag('nestBody'))
			entries.push({ field: fieldName + TriviaTypeSynth.TRAILING_BLANK_AFTER_SUFFIX, expr: macro false });
		// ω-blockended-trivia-meta-arity: hasMeta over
		// readMetaString — gate must match `buildStarTrailingSlots`
		// at L1002. Multi-arg `@:sep('text', tailRelax, blockEnded)`
		// (3-arg form) lands on the same code path as 1-arg `@:sep(',')`.
		if (child.hasMeta(':sep') && child.hasMeta(':trail'))
			entries.push({ field: fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX, expr: macro false });
	}

	private static function buildRawToPairedAltBody(origName: String, origNode: ShapeNode, synthPack: Array<String>, pos: Position): Expr {
		final pairedSimple: String = TriviaTypeSynth.leafOf(origName) + TriviaTypeSynth.PAIRED_SUFFIX;
		final pairedPath: Array<String> = synthPack.concat([TriviaTypeSynth.SYNTH_MODULE_LEAF, pairedSimple]);
		final cases: Array<Case> = [];
		for (branch in origNode.children) {
			final ctorName: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
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
					{ expr: EConst(CIdent(branch.children[i].annotations.get(AnnotationKeys.BASE_FIELD_NAME))), pos: pos }
			];
			final pattern: Expr = { expr: ECall({ expr: EConst(CIdent(ctorName)), pos: pos }, binders), pos: pos };
			// Body: PairedType.CtorName(wrap(arg0), wrap(arg1), ...defaults).
			final pairedArgs: Array<Expr> = [
				for (i in 0...origArgCount) {
					final argNode: ShapeNode = branch.children[i];
					final argName: String = argNode.annotations[AnnotationKeys.BASE_FIELD_NAME];
					final argAccess: Expr = { expr: EConst(CIdent(argName)), pos: pos };
					shapeRawToPairedWrap(argAccess, argNode, pos);
				}
			];
			for (extra in buildAltExtraDefaults(branch)) pairedArgs.push(extra);
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
	private static function buildAltExtraDefaults(branch: ShapeNode): Array<Expr> {
		final defaults: Array<Expr> = [];
		if (TriviaPairAltCtor.isAltCloseTrailingBranch(branch)) {
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
				// ω-blockended-trivia-meta-arity: hasMeta over
				// readMetaString — must match `buildEnumCtor` L1076 gate so
				// raw-to-paired ctor arg count matches the paired ctor's arity.
				if (branch.hasMeta(':sep')) defaults.push(macro false);
			}
		}
		if (TriviaPairAltCtor.isAltTrailOptBranch(branch)) defaults.push(macro false); // trailPresent
		if (TriviaPairAltCtor.isCaptureSourceBranch(branch)) defaults.push(macro ''); // sourceText
		if (TriviaPairAltCtor.isAltBodyPolicyKwBranch(branch)) defaults.push(macro false); // bodyOnSameLine
		if (TriviaPairAltCtor.isAltWrapOpenNewlineBranch(branch)) defaults.push(macro false); // wrapOpenNewline
		if (TriviaPairAltCtor.isAltKwNewlineBranch(branch)) defaults.push(macro false); // kwNewline (increment 1b)
		if (TriviaPairAltCtor.isAltChainNewlineBranch(branch)) defaults.push(macro false); // chainNewline (increment 2)
		if (TriviaPairAltCtor.isAltChainNewlineBranch(branch))
			defaults.push(macro (null: Null<String>)); // chainLeadComment (chain receiver/operand comment)
		if (TriviaPairAltCtor.isInfixChainBranch(branch))
			defaults.push(macro (null: Null<String>)); // opAfterComment (infix post-operator comment)
		if (TriviaPairAltCtor.isRhsTrailBranch(branch))
			defaults.push(macro (null: Null<String>)); // opRhsTrailComment (infix right-operand trailing comment)
		if (TriviaPairAltCtor.isTernaryTrailBranch(branch)) {
			defaults.push(macro (null: Null<String>)); // condTrailComment (ω-keep-ternary-operand-comment)
			defaults.push(macro (null: Null<String>)); // thenTrailComment
		}
		if (TriviaPairAltCtor.isPostfixOpSpaceBranch(branch)) defaults.push(macro true); // opSpaceBefore (spaced fallback)
		if (TriviaPairAltCtor.isPostfixCloseTrailingBranch(branch)) {
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
			// ω-callarg-empty-inner-comment: argsInnerComment default for
			// raw→paired wraps. `null` matches the parser's initial state for a
			// call with no empty-parens inner comment.
			defaults.push(macro (null: Null<String>)); // argsInnerComment
			// ω-keep-call-leading-comment: callLeadingComment default for raw→paired
			// wraps. `null` matches the parser's initial state for a call with no
			// pre-callee leading comment.
			defaults.push(macro (null: Null<String>)); // callLeadingComment
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
				final refName: String = node.annotations[AnnotationKeys.BASE_REF];
				final optional: Bool = node.annotations[AnnotationKeys.BASE_OPTIONAL] == true;
				if (!TriviaTypeSynth.refIsBearing(refName)) return access;
				final fnName: String = 'rawToPaired_${TriviaTypeSynth.leafOf(refName)}';
				final call: Expr = { expr: ECall({ expr: EConst(CIdent(fnName)), pos: pos }, [access]), pos: pos };
				return optional ? macro ($access == null ? null : $call) : call;
			case Star:
				final elem: ShapeNode = node.children[0];
				final triviaWrap: Bool = node.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
				final optional: Bool = node.annotations[AnnotationKeys.BASE_OPTIONAL] == true;
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
							pos: pos
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

}
#end
