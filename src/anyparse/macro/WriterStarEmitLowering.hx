package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import anyparse.macro.MacroNames.*;
import anyparse.macro.WriterBlankLowering.*;
import anyparse.macro.WriterBraceSymmetryLowering.*;
import anyparse.macro.WriterCtorPatternLowering.*;
import anyparse.macro.WriterFieldSepLowering.*;
import anyparse.macro.WriterLowering.CascadeInfos;
import anyparse.macro.WriterLowering.EnumStarCtx;
import anyparse.macro.WriterLowering.PadFlags;
import anyparse.macro.WriterLowering.PlainStarCtx;
import anyparse.macro.WriterLowering.PrevBodyInfo;
import anyparse.macro.WriterLowering.SepStarMapWrap;
import anyparse.macro.WriterLowering.StarFieldArgs;
import anyparse.macro.WriterLowering.TriviaAltSlots;
import anyparse.macro.WriterLowering.TriviaStarCtx;
import anyparse.macro.WriterLowering.TryparseSepOverrides;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterPolicyLowering.*;
import anyparse.macro.WriterStarPadLowering.*;
import anyparse.macro.WriterTriviaSlotLowering.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using StringTools;
using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W - BOTH writer halves of the Star fork, in one module.
 *
 * A repetition emits differently depending on where it sits: a `Star` FIELD
 * of a Seq rule enters at `emitStarField` / `emitWriterStarField`, an
 * Alt-branch `Star` (`Lowering.lowerEnumBranch`'s Case 4) at `lowerEnumStar`.
 * Underneath both sit the per-policy leaves - the plain, sep, close-peek and
 * tryparse variants, and the trivia-mode entries into
 * `TriviaTryparseLowering`, `TriviaEofLowering`, `TriviaSepLowering` and
 * `TriviaBlockLowering`.
 *
 * ⚠️ Star emission FORKS across FOUR sites - `StarFieldLowering.emitStarFieldSteps`
 * and the `lowerStar*Branch` leaves beside it on the PARSE side, and these two
 * here on the writer side. The two writer halves must be read together, which
 * is why an extraction that took one and left the other was refused: it would
 * put the pair in two files with nothing naming the other half. Taking BOTH is
 * what makes the move legitimate, and this doc is where the pair is now named.
 * `WriterStarPadLowering` holds plain-Star LEAF emitters taken out from under
 * `emitWriterStarField`; none of them is reachable from `lowerEnumStar`, so
 * neither fork half is separated from its twin by that split either.
 *
 * Two members that read as Seq-walker helpers are here because both their
 * callers are: `blockEndedPredCheck` (called by `emitBlockEndedPlainStar` and
 * `lowerEnumStarPlain`) and `arrayBracketInsidePolicySpace` (by
 * `lowerEnumStarPlain` and `triviaSepStarBuild`). `buildKeepBlankAfterCtorGate`
 * is the one that genuinely stayed: `lowerStruct` calls it too.
 */
@:access(anyparse.macro.TriviaBlockLowering, anyparse.macro.TriviaEofLowering, anyparse.macro.TriviaSepLowering,
	anyparse.macro.TriviaTryparseLowering, anyparse.macro.WriterBlankLowering, anyparse.macro.WriterBraceSymmetryLowering,
	anyparse.macro.WriterCascadeLowering, anyparse.macro.WriterChainLowering, anyparse.macro.WriterCondWrapLowering,
	anyparse.macro.WriterCtorBlankLowering, anyparse.macro.WriterCtorPatternLowering, anyparse.macro.WriterFieldSepLowering,
	anyparse.macro.WriterLowering, anyparse.macro.WriterLoweringSupport, anyparse.macro.WriterPolicyLowering,
	anyparse.macro.WriterRefLeadLowering, anyparse.macro.WriterStarPadLowering, anyparse.macro.WriterTriviaSlotLowering,
	anyparse.macro.WriterTriviaStarDispatch)
final class WriterStarEmitLowering {

	/**
	 * The three-way blockEnded predicate channel, shared by the plain
	 * writer's sep-elision sites: no predicate → inert `false`; an
	 * `astPreds` format → the generated typed predicate of the build's
	 * AST family; otherwise the legacy `<schema>.instance.<predicate>`
	 * channel (the pilot formats' path — byte-identical to the
	 * pre-campaign emission).
	 */
	private static function blockEndedPredCheck(ctx: StarEmitCtx, predicateName: Null<String>, elemAccess: Expr): Expr {
		if (predicateName == null) return macro false;
		if (ctx.formatInfo.astPreds) return AstPredLowering.predCallExpr(ctx.shape.root, false, false, predicateName, [elemAccess]);
		final fmtParts: Array<String> = ctx.formatInfo.schemaTypePath.split('.');
		return {
			expr: ECall({ expr: EField(macro $p{fmtParts}.instance, predicateName), pos: Context.currentPos() }, [elemAccess]),
			pos: Context.currentPos()
		};
	}

	/** Enum Case 4 Star: `@:lead @:trail` with optional `@:sep`. */
	private static function lowerEnumStar(
		ctx: StarEmitCtx, branch: ShapeNode, typePath: String, writeFnName: String, hasPratt: Bool, argNames: Array<String>
	): Expr {
		final leadText: String = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: String = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final kwLead: Null<String> = branch.annotations[AnnotationKeys.KW_LEAD_TEXT];
		final starNode: ShapeNode = branch.children[0];
		final inner: ShapeNode = starNode.children[0];
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final isSelfRef: Bool = simpleName(elemRefName) == simpleName(typePath);
		final elemFn: String = isSelfRef ? writeFnName : ctx.writeFnFor(elemRefName);

		final elemCallArgs: Array<Expr> = [macro _args[_i], macro opt];
		if (isSelfRef && hasPratt) elemCallArgs.push(macro -1);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, elemCallArgs),
			pos: Context.currentPos()
		};

		final argsAccess: Expr = macro $i{argNames[0]};
		final parts: Array<Expr> = [];
		if (kwLead != null) parts.push(macro _dt($v{kwLead + ' '}));

		// ω-arrow-lambda-body-context: enum-Case Star branches opting into
		// `@:fmt(leftCurlyAnonFnOverride('<knob>'))` (currently
		// `HxExpr.BlockExpr`) prepend a runtime-gated hardline before the
		// open delimiter — when the writer was descended through
		// `@:fmt(propagateAnonFnContext)` (parent flips `_inAnonFnBody=true`
		// via `_setAnonFnBody`) AND the named knob is `Next`, the hardline
		// fires and the renderer drops the parent's preceding `_dop(' ')`
		// OptSpace (e.g. `arrowFunctions=Both` after `->`), placing `{` on
		// its own line at the parent indent. When the override knob is
		// `Same` OR `_inAnonFnBody=false` (non-lambda context like
		// `HxIfExpr.thenBranch` reaching `BlockExpr`), the prefix is `_de()`
		// and the pre-slice cuddled `{` layout is preserved. The flag is
		// then cleared on per-element opt by `triviaBlockStarExpr` so
		// nested BlockExpr inside body statements falls back to default
		// `blockLeftCurly`.
		final anonFnOverrideKnob: Null<String> = branch.fmtReadString('leftCurlyAnonFnOverride');
		if (anonFnOverrideKnob != null) {
			final knobAccess: Expr = optFieldAccess(anonFnOverrideKnob);
			final nextPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
			parts.push(macro opt._inAnonFnBody && $knobAccess == $nextPat ? _dhl() : _de());
		}

		final c: EnumStarCtx = {
			branch: branch,
			argNames: argNames,
			argsAccess: argsAccess,
			elemFn: elemFn,
			elemCall: elemCall,
			leadText: leadText,
			trailText: trailText,
			sepText: sepText,
			starNode: starNode
		};
		final isTriviaStar: Bool = ctx.ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		final emission: Expr = isTriviaStar ? lowerEnumStarTrivia(ctx, c) : lowerEnumStarPlain(ctx, c);
		parts.push(emission);
		return parts.length == 1 ? parts[0] : dcCall(parts);
	}

	/**
	 * Emit a Star struct field (the `if (isStar)` branch of `lowerStruct`).
	 * Dispatches the optional close-peek Star (`emitOptionalStarField`) vs the
	 * bare / `@:tryparse` Star (inter-Star separator + `emitWriterStarField` +
	 * multiVar gate), then folds this field's padTrailing / metaLineEnd pad and
	 * transparent guard into `prevPadTrailing` and recomputes the cumulative
	 * `prevAnyStarNonEmpty` signal. Pushes into `parts`; returns the two
	 * recomputed loop accumulators (the caller resets `prevBodyField` /
	 * `prevTrailFieldName` to null and `isFirstField` to false).
	 */
	private static function emitStarField(
		ctx: StarEmitCtx, child: ShapeNode, parts: Array<Expr>, node: ShapeNode, typePath: String, isFirstField: Bool, isRaw: Bool,
		stalePrevBareRefBody: Null<PrevBodyInfo>, prevTrailFieldName: Null<String>, kwLead: Null<String>, fieldName: String,
		prevBodyField: Null<PrevBodyInfo>, prevPadTrailing: Null<Expr>, fieldAccess: Expr, prevAnyStarNonEmpty: Null<Expr>,
		multiVarMoreField: Null<String>, isOptional: Bool, afterAlwaysEmits: Bool = false
	): { prevAnyStarNonEmpty: Null<Expr>, prevPadTrailing: Null<Expr> } {
		if (isOptional) {
			// Optional close-peek Star (first consumer: `HxTypeRef.params`).
			// Empty Doc (`_de()`) is the absent shape.
			emitOptionalStarField(
				ctx, child, parts, node, typePath, isFirstField, isRaw, stalePrevBareRefBody, prevTrailFieldName, kwLead, fieldName,
				prevBodyField, prevPadTrailing, fieldAccess
			);
			// ω-pad-trailing-ref: optional Star with @:fmt(padTrailing) fires
			// its trailing-pad ONLY when both `_optVal != null` AND
			// `_optVal.length > 0`; it is transparent when absent OR empty.
			// ω-line-comment-directive-break: no empty-arm disjunct here (unlike
			// the non-optional path below). The only consumers are the cond-comp
			// `elseBody` fields, and `elseBody` is the LAST field of every
			// conditional rule - no sibling separator follows it, so an empty
			// comment-only `#else` arm has nothing to suppress. Add the disjunct
			// if a kw-led optional padTrailing Star ever gains a follower.
			final thisPadTrailing: Null<Expr> = child.fmtHasFlag('padTrailing')
				? (macro $fieldAccess != null && $fieldAccess.length > 0)
				: null;
			final thisTransparent: Expr = macro $fieldAccess == null || $fieldAccess.length == 0;
			return {
				prevAnyStarNonEmpty: null,
				prevPadTrailing: composePadTrailing(prevPadTrailing, thisPadTrailing, thisTransparent)
			};
		}
		// ω-member-meta: inter-Star separator — a non-first bare-tryparse Star
		// following another that may have emitted content gets a leading
		// separator double-gated on prev non-empty AND this non-empty (drops
		// the next field's leading sep when prev fired padTrailing).
		if (isBareTryparseStar(child) && !isFirstField && prevAnyStarNonEmpty != null)
			parts.push(buildInterStarSep(
				ctx, prevAnyStarNonEmpty, fieldAccess, prevPadTrailing, ctx.buildKeepBlankAfterCtorGate(child, node, typePath)
			));
		// ω-multivar-wrap: gate the `<moreField>` Star emit on the runtime
		// `_suppressMore` entry flag (a head-only recursive self-call drops it
		// to `_de()`).
		final isMultiVarMoreField: Bool = multiVarMoreField != null && fieldName == multiVarMoreField;
		final multiVarPartsStart: Int = parts.length;
		emitWriterStarField(
			ctx, child, fieldAccess, parts, child == node.children[node.children.length - 1], typePath, isFirstField, isRaw,
			stalePrevBareRefBody, prevTrailFieldName
		);
		if (isMultiVarMoreField) gateMultiVarMoreParts(parts, multiVarPartsStart);
		// ω-pad-trailing-ref / ω-metadata-line-end-function: non-optional Star
		// pad fires when non-empty (and, for metaLineEndPolicy, the knob is
		// non-None); the Star is transparent when empty.
		final thisPadTrailing: Null<Expr> = starPadTrailing(ctx, child, fieldAccess, typePath);
		final thisTransparent: Expr = macro $fieldAccess.length == 0;
		// ω-metastmt-sep: a bare-tryparse Star right after a mandatory Ref
		// seeds the cumulative signal with `true` — the Ref's content is
		// already on the line, so the NEXT bare Ref's separator must fire
		// even when this Star is empty (`@:nullSafety(Off) if` keeps its
		// space). Seeding in the RETURN (not before the inter-Star
		// separator above) keeps that separator quiet for this Star.
		return {
			prevAnyStarNonEmpty: !isBareTryparseStar(child)
				? null
				: afterAlwaysEmits ? (macro true) : orStarNonEmpty(prevAnyStarNonEmpty, fieldAccess),
			prevPadTrailing: composePadTrailing(prevPadTrailing, thisPadTrailing, thisTransparent)
		};
	}

	private static function emitWriterStarField(
		ctx: StarEmitCtx, starNode: ShapeNode, fieldAccess: Expr, parts: Array<Expr>, isLastField: Bool, typePath: String,
		isFirstField: Bool, isRaw: Bool, ?prevBareRefBody: PrevBodyInfo, ?prevTrailFieldName: String
	): Void {
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) Context.fatalError('WriterLowering: Star struct field must contain a Ref', Context.currentPos());

		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = ctx.writeFnFor(elemRefName);
		final openText: Null<String> = starNode.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final closeText: Null<String> = starNode.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final isTriviaStar: Bool = ctx.ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		final args: StarFieldArgs = {
			starNode: starNode,
			fieldAccess: fieldAccess,
			elemFn: elemFn,
			elemRefName: elemRefName,
			isFirstField: isFirstField,
			isLastField: isLastField,
			isRaw: isRaw,
			typePath: typePath,
			openText: openText,
			closeText: closeText,
			sepText: sepText,
			prevBareRefBody: prevBareRefBody,
			prevTrailFieldName: prevTrailFieldName
		};

		// Trivia Star: the Array element type is Trivial<elemT>, and the
		// write call targets `_t.node` instead of the raw array element.
		// Leading/trailing comments and blank-line markers attach around
		// each element via the generated layout below. Sep / @:raw
		// combinations with @:trivia are rejected by the parser side
		// upstream — valid modes are block (close + no sep), EOF (no
		// close, last field), and try-parse (no close, last field,
		// `@:tryparse`).
		if (isTriviaStar) {
			emitTriviaStar(ctx, args, parts);
			return;
		}

		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro _arr[_si], macro opt]),
			pos: Context.currentPos()
		};
		final plainCtx: PlainStarCtx = {
			starNode: starNode,
			fieldAccess: fieldAccess,
			elemCall: elemCall,
			elemFn: elemFn,
			elemRefName: elemRefName,
			isFirstField: isFirstField,
			isLastField: isLastField,
			isRaw: isRaw,
			typePath: typePath,
			openText: openText,
			closeText: closeText,
			sepText: sepText,
			prevBareRefBody: prevBareRefBody
		};

		// @:raw types (string content): concatenate items with no whitespace,
		// wrapping in lead/trail if present. No block/sep layout.
		if (isRaw && closeText != null && sepText == null) {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [_dt($v{openText ?? ''})];
				var _si: Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					_si++;
				}
				_docs.push(_dt($v{closeText}));
				_dc(_docs);
			});
			return;
		}

		// Block-ended exemption (Session 2 pilot → Session 8 layout fix +
		// writer-side predicate consultation). When the Star carries
		// `@:sep(<text>, tailRelax, blockEnded[('<predicate>')])`,
		// between-element sep is suppressed when EITHER:
		//   (a) the prior element's rendered Doc ends with `}` OR `;`
		//       (per-stmt `@:trail/@:trailOpt(';')` baked terminator —
		//       `DocMeasure.endsWithStmtTerminator` one-walk check), OR
		//   (b) the blockEnded predicate (generated typed for astPreds
		//       formats, schema-instance for pilots) returns true on the
		//       prior element's AST (Session 7 option b2 — e.g.
		//       `HxStatement.Conditional(#if…#end)` ends `#end`
		//       byte-wise so (a) misses, but the predicate accepts the
		//       AST shape).
		// Mirrors the parser-side blockEnded branch in
		// `StarFieldLowering.emitStarFieldSteps`: byte-check `}`∪`;` (or-extended
		// `b == '}'.code || b == ';'.code || $predicateCall`). Predicate
		// is omitted iff `lit.sepBlockEndedPredicate` is absent — the
		// `false` fallback keeps the byte-check fast path untouched.
		//
		// Layout mirrors `blockBody` (WriterCodegen.hx:730-758): empty →
		// flat `open+close`; non-empty → `_dc([_dt(open), _dn(cols,
		// _dc([_dhl, item, [sep?]]*)), _dhl, _dt(close)])`. This replaces
		// the prior flat `_dc([open, item, _dt(' '), item, …, close])`
		// that had no multiline primitive — Session 7's HxFnBlock.stmts
		// smoke test regressed 35 unit tests because function bodies
		// collapsed to one line; the blockBody-shape layout restores
		// parity with the non-`@:sep` path at L3981.
		final blockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		if (closeText != null && sepText != null && blockEnded) {
			emitBlockEndedPlainStar(ctx, plainCtx, parts);
			return;
		}

		if (closeText != null && sepText != null) {
			emitSepStar(ctx, plainCtx, parts);
		} else if (closeText != null) {
			emitClosePlainStar(ctx, plainCtx, parts);
		} else if (!isLastField || starNode.hasMeta(':tryparse')) {
			emitTryparseOrPadStar(ctx, plainCtx, parts);
		} else {
			emitEofPlainStar(plainCtx, parts);
		}
	}

	/**
	 * Plain-mode block-ended sep Star dispatch (the
	 * `closeText != null && sepText != null && blockEnded` branch of
	 * `emitWriterStarField`). Emits the blockBody-shape multiline layout with the
	 * `;`/`}`-terminator + format-predicate sep suppression. Extracted to keep the
	 * orchestrator under the complexity gate.
	 */
	private static function emitBlockEndedPlainStar(ctx: StarEmitCtx, c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		final predicateName: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE];
		final predicateCheck: Expr = blockEndedPredCheck(ctx, predicateName, macro _arr[_si]);
		// Phase G2 (Session 10) — trail-emit-on-last for plain mode.
		// Mirror of between-element gate below, queried on the last
		// element. Required when per-stmt `@:trailOpt(';')` is removed
		// from a ctor (Session 10 migration) — the element's Doc no
		// longer bakes `;`, so the Star owns trailing emit. Mirrors
		// trivia mode's `blockTrailSepEmitExpr` (L7002-7009) minus the
		// source-fidelity `sepAfter` gate (plain mode has no per-pair
		// state — always emit when non-block-ended).
		final lastPredicateCheck: Expr = blockEndedPredCheck(ctx, predicateName, macro _arr[_arr.length - 1]);
		parts.push(macro {
			final _arr = $fieldAccess;
			if (_arr.length == 0) {
				_dc([_dt($v{openText ?? ''}), _dt($v{closeText})]);
			} else {
				final _items: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				var _lastElemDoc: Null<anyparse.core.Doc> = null;
				while (_si < _arr.length) {
					final _elemDoc: anyparse.core.Doc = $elemCall;
					_items.push(_dhl());
					_items.push(_elemDoc);
					if (_si < _arr.length - 1 && !anyparse.core.DocMeasure.endsWithSemi(_elemDoc) && !($predicateCheck)) {
						_items.push(_dt($v{sepText}));
					}
					_lastElemDoc = _elemDoc;
					_si++;
				}
				if (_lastElemDoc != null && !anyparse.core.DocMeasure.endsWithSemi(_lastElemDoc) && !($lastPredicateCheck)) {
					_items.push(_dt($v{sepText}));
				}
				final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				_dc([_dt($v{openText ?? ''}), _dn(_cols, _dc(_items)), _dhl(), _dt($v{closeText})]);
			}
		});
	}

	/**
	 * Plain-mode sep Star dispatch (the `closeText != null && sepText != null`
	 * branch of `emitWriterStarField`). Handles the `\n`-join shortcut and the
	 * leading-space placement, then delegates the list emission to
	 * `emitSepStarList`. Extracted to keep the orchestrator under the complexity
	 * gate.
	 */
	private static function emitSepStar(ctx: StarEmitCtx, c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final isFirstField: Bool = c.isFirstField;
		final isRaw: Bool = c.isRaw;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		// Newline as separator — semantically a hardline between
		// elements, not a soft-fit-or-break token. `sepList` uses a
		// soft-line (space-in-flat / newline-in-break) which doesn't
		// match "newlines are structure." Route `@:sep('\n')` to a
		// flat hardline-join emission: `open + \n + item + \n + … + \n + close`.
		// No Nest — enclosing scope's indent reaches interior lines
		// unchanged. Format-neutral — any grammar using `@:sep('\n')`
		// gets this layout.
		if (sepText == '\n') {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [_dt($v{openText ?? ''})];
				var _si: Int = 0;
				while (_si < _arr.length) {
					if (_si > 0) _docs.push(_dhl());
					_docs.push($elemCall);
					_si++;
				}
				_docs.push(_dt($v{closeText}));
				_dc(_docs);
			});
			return;
		}
		// ω-E-whitespace: spaced leads (`{`) get a plain leading space;
		// a Star with `@:fmt(funcParamParens)` opts into a runtime-
		// switched space before its open delim. The two branches are
		// structurally exclusive so a grammar site that ever combined
		// them (spaced-lead `{` with a funcParamParens-style flag)
		// cannot produce a double space.
		//
		// ω-typeparam-spacing: `@:fmt(typeParamOpen)` extends the same
		// outside-before-open path — `Before`/`Both` on `<` emit a
		// space before the delim (`Foo <Int>`). `After`/`Both` on
		// `<` and `Before`/`Both` on `>` route through `delimInsidePolicySpace`
		// below to splice padding INSIDE the delimiters via `sepList`'s
		// `openInside` / `closeInside` Doc args.
		if (!isFirstField && !isRaw) {
			if (ctx.isSpacedLead(openText)) {
				parts.push(macro _dt(' '));
			} else {
				final paramSpace: Null<Expr> = openDelimPolicySpace(starNode, ['funcParamParens', 'typeParamOpen']);
				if (paramSpace != null) parts.push(paramSpace);
			}
		}
		emitSepStarList(ctx, c, parts);
	}

	/**
	 * Plain-mode sep Star dispatch (the `closeText != null && sepText != null`
	 * branch of `emitWriterStarField`). Routes the list through sepList / fillList
	 * / WrapList per the wrap `@:fmt` flags and emits the first-field pattern-list
	 * keep. Extracted to keep the orchestrator under the complexity gate.
	 * Plain-mode sep Star list emission — the tail of `emitSepStar` after the
	 * `\n`-join and leading-space handling. Builds the sepList / fillList /
	 * WrapList call and the first-field pattern-list keep, then pushes onto
	 * `parts`. Extracted to keep the helper under the complexity gate.
	 */
	private static function emitSepStarList(ctx: StarEmitCtx, c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final isFirstField: Bool = c.isFirstField;
		final typePath: String = c.typePath;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		final tcExpr: Expr = trailingCommaExpr(starNode);
		final openInsideExpr: Expr = delimInsidePolicySpace(starNode, ['typeParamOpen', 'objectLiteralBracesOpen'], false) ?? macro _de();
		final closeInsideExpr: Expr = delimInsidePolicySpace(starNode, ['typeParamClose', 'objectLiteralBracesClose'], true) ?? macro _de();
		final keepInnerExpr: Expr = keepInnerWhenEmptyExpr(starNode);
		// ω-fill-primitive: `@:fmt(fill)` on the Star routes the list
		// through `fillList` (Wadler fillSep) instead of `sepList`,
		// packing items inline up to the line budget and breaking the
		// separator before each overflow item at the list's indent.
		//
		// ω-wraprules-objlit: `@:fmt(wrapRules('<optionFieldName>'))`
		// supersedes both above paths — routes the list through the
		// runtime `WrapList.emit` engine driven by the named
		// `WrapRules` cascade on `opt`. The cascade picks one of
		// `NoWrap` / `OnePerLine` / `OnePerLineAfterFirst` /
		// `FillLine` per call from item count, max/total flat width
		// and an `exceedsMaxLineLength` flag — the engine evaluates
		// the cascade twice (`exceeds=false` + `exceeds=true`) and
		// emits `Group(IfBreak(brkDoc, flatDoc))` when the two runs
		// disagree, so the renderer's flat/break decision picks the
		// right mode at layout time. First consumer is `HxObjectLit`
		// (`objectLiteralWrap`); future slices wire `arrayWrap`,
		// `anonTypeWrap`, `callParameterWrap`, … through the same
		// engine. `@:fmt(fill)` / `@:fmt(fillDoubleIndent)` are
		// orthogonal — they continue to drive `fillList` for sites
		// that opt into Wadler fillSep without per-construct rules.
		final wrapRulesField: Null<String> = starNode.fmtReadString('wrapRules');
		final useFill: Bool = starNode.fmtHasFlag('fill');
		final fillDouble: Bool = starNode.fmtHasFlag('fillDoubleIndent');
		// ω-functionsignature-body-aware-indent: `@:fmt(bodyAwareCompactIndent)`
		// on the Star threads `true` into `WrapList.emit`'s `compactContinuation`
		// param for EVERY function-signature wrap. Such signatures carry
		// `ignoreSourceNewlinesForWrap`, so their ONLY break source is the
		// cascade leading-break, which lands at `calcIndent + additionalIndent`
		// (the additional-only continuation regime) — the same indent the
		// multi-param one-per-line path uses. Threading `opt._fnSigBodyEmpty`
		// here was too narrow: a NON-empty single-param signature (cascade
		// `itemCount <= 1 -> noWrap`, its default fillLineWithLeadingBreak
		// owning the overflow break) then took the fit-driven `1 + additional`
		// paren-bump regime and gained an extra indent level. Fields without
		// the flag pass `false` so only the opt-in site reacts. That slot had no
		// other reader, and its producer `@:fmt(propagateFnBodyEmpty)` is gone, so
		// re-narrowing now means re-deriving the emptiness, not reading an opt field.
		final bodyAware: Bool = starNode.fmtHasFlag('bodyAwareCompactIndent');
		// ω-group-rest-probe slice 2: `@:fmt(groupRestProbe)` opt-in for
		// Star fields whose outer Group should bias toward MBreak when
		// significant same-line content trails (typedef LHS typeParams,
		// followed by ` = Rhs<…>;`). Mirrors fork's `lengthAfter` rule
		// at Group layer. Non-trivia-dispatch `groupRestProbe` option of
		// `WrapList.emit`; trivia path mirror lives in `triviaSepStarExpr`
		// (dual-dispatch per [[feedback-wraprules-dispatch-dual-path]]).
		final groupRestProbe: Bool = starNode.fmtHasFlag('groupRestProbe');
		// ω-pattern-rest-probe (T169): gated at RUNTIME, like the trivia mirror
		// in `TriviaSepLowering` and the postfix-Star `Call` site — the
		// suppression is a property of the DESCENT (a case pattern is a matching
		// shape and never owns the line's overflow), not of the Star. The
		// backlog note that stood here called this gap plain-only and therefore
		// invisible to `fmt`; that was wrong. 14 of the 18 struct-field Star
		// carriers have no `@:trivia` (every declare-site `<T, …>` list plus
		// `HxNewExpr.params`, `HxTypeRef.params` and `HxArrowFnType.args`) and
		// this is their ONLY dispatch in BOTH writers, so
		// `case (x : Map<A, B>) if (…):` exploded its type parameters in the
		// trivia writer too. Census and per-assertion killers:
		// `HxGroupRestProbeStructStarTest`. Reading `opt._suppressPatternRestProbe`
		// couples the emit to a grammar that DECLARES that option — the same
		// coupling the postfix gate already carries, and it binds only for a Star
		// that opted into `groupRestProbe`, which no grammar but Haxe does.
		//
		// STILL OPEN, and the other half of the note that stood here: this call
		// passes 3 of the ~15 options its trivia mirror does, `complexItemKinds`
		// among them — the same plain/trivia asymmetry one option over.
		final groupRestProbeExpr: Expr = groupRestProbe ? (macro !opt._suppressPatternRestProbe) : (macro false);
		final listCall: Expr = if (wrapRulesField != null) {
			final rulesExpr: Expr = optFieldAccess(wrapRulesField);
			final compactContExpr: Expr = macro $v{bodyAware};
			macro anyparse.format.wrap.WrapList.emit(
				$v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $openInsideExpr, $closeInsideExpr, $keepInnerExpr, $rulesExpr, {
					appendTrailingComma: $tcExpr,
					compactContinuation: $compactContExpr,
					groupRestProbe: $groupRestProbeExpr
				}
			);
		} else if (useFill) {
			macro fillList(
				$v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, $keepInnerExpr,
				$v{fillDouble}
			);
		} else {
			macro sepList(
				$v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, $keepInnerExpr,
				false
			);
		};
		// ω-casepattern-keep: a FIRST-field bare Star that opts into
		// `@:fmt(beforeNewlineSlotFirst)` (only `HxCaseBranch.patterns`)
		// reads the synth `<field>BeforeNewline:Bool` slot. When the
		// source broke right after the parent `case` keyword AND
		// `opt.leftCurly == Next` (the `lineEnds.leftCurly: before`/`both`
		// configs where fork puts a line-end before the pattern's `{`),
		// wrap the pattern list Doc in `_dn(_cols, _dc([_dhl, …]))` so
		// `case\n\t{pattern}` round-trips verbatim. The body field follows
		// on the `:`-glued line, governed by its own `caseBody`/
		// `expressionCase` keep. Gated on trivia + bearing + the opt-in
		// flag so every non-bearing / plain-mode emit (no slot) keeps the
		// unconditional glued list; gated on `leftCurly == Next` at
		// runtime so `Same` configs and the absent-newline source shape
		// (`case {pattern}`) stay byte-identical. The parent
		// `HxSwitchCase.CaseBranch` ctor carries `@:fmt(deferKwSpace)`, so
		// the `case ` trailing space drops cleanly before the hardline.
		// Mirrors the bare-Ref first-field channel (`HxTryCatchStmt.body`
		// / `bodyPolicyWrap` Next branch `_dn(_cols, [_dhl, body])`).
		final firstStarNlKeep: Bool = isFirstField && ctx.ctx.trivia && ctx.isTriviaBearing(typePath)
			&& starNode.fmtHasFlag(WriterLowering.BEFORE_NEWLINE_SLOT_FIRST);
		final patternListExpr: Expr = if (firstStarNlKeep) {
			final nlFieldName: String = starNode.annotations[AnnotationKeys.BASE_FIELD_NAME];
			final beforeNlAccess: Expr = {
				expr: EField(macro value, nlFieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX),
				pos: Context.currentPos()
			};
			macro {
				final _patListDoc: anyparse.core.Doc = $listCall;
				final _patBeforeNl: Bool = $beforeNlAccess && opt.leftCurly == anyparse.format.BracePlacement.Next;
				final _patCols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				_patBeforeNl ? _dn(_patCols, _dc([_dhl(), _patListDoc])) : _patListDoc;
			};
		} else
			macro $listCall;
		parts.push(macro {
			final _arr = $fieldAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			var _si: Int = 0;
			while (_si < _arr.length) {
				_docs.push($elemCall);
				_si++;
			}
			$patternListExpr;
		});
	}

	/**
	 * Plain-mode close-peek (`@:trail`, no sep) Star dispatch (the
	 * `else if (closeText != null)` branch of `emitWriterStarField`). Emits the
	 * leftCurly separator then the `blockBody` layout. Extracted to keep the
	 * orchestrator under the complexity gate.
	 */
	private static function emitClosePlainStar(ctx: StarEmitCtx, c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final isFirstField: Bool = c.isFirstField;
		final isRaw: Bool = c.isRaw;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		// Mirror of the trivia-path gate: knob-form leftCurly fires
		// even on a first-field Star (outer-side OptSpace owns the
		// inter-token space; see leftCurlySeparator's `_de()` branch).
		final hasKnobLeftCurly2: Bool = starNode.fmtReadString('leftCurly') != null;
		if ((!isFirstField || hasKnobLeftCurly2) && !isRaw && ctx.isSpacedLead(openText)) parts.push(leftCurlySeparator(starNode));
		parts.push(macro {
			final _arr = $fieldAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			var _si: Int = 0;
			while (_si < _arr.length) {
				_docs.push($elemCall);
				_si++;
			}
			blockBody($v{openText ?? '{'}, $v{closeText}, _docs, opt);
		});
	}

	/**
	 * Plain-mode try-parse / pad Star dispatch (the
	 * `else if (!isLastField || @:tryparse)` branch of `emitWriterStarField`).
	 * Emits the lead, then routes to the `@:fmt(sameLine)` block-shape path or the
	 * pad path. Extracted to keep the orchestrator under the complexity gate.
	 */
	private static function emitTryparseOrPadStar(ctx: StarEmitCtx, c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final openText: Null<String> = c.openText;
		// Try-parse mode. Emit lead if present (e.g. ':' in default:).
		if (openText != null) parts.push(macro _dt($v{openText}));
		final sameLineName: Null<String> = starNode.fmtReadString('sameLine');
		if (sameLineName != null) {
			emitTryparseSameLineStar(ctx, c, sameLineName, parts);
		} else {
			emitTryparsePadStar(ctx, c, parts);
		}
	}

	/**
	 * Plain-mode try-parse / pad Star dispatch (the
	 * `else if (!isLastField || @:tryparse)` branch of `emitWriterStarField`).
	 * Handles the `@:fmt(sameLine)` block-shape separator path and the
	 * `padLeading` / `padTrailing` / `softFill` / `lineLengthAwareSeps` pad paths.
	 * Extracted to keep the orchestrator under the complexity gate.
	 * Plain-mode try-parse `@:fmt(sameLine)` block-shape separator path (the
	 * `sameLineName != null` branch of `emitTryparseOrPadStar`). Emits the
	 * per-element runtime-conditional separator with the block-ctor / bare-body
	 * shape switch. Extracted to keep the helper under the complexity gate.
	 */
	private static function emitTryparseSameLineStar(ctx: StarEmitCtx, c: PlainStarCtx, sameLineName: String, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final elemRefName: String = c.elemRefName;
		final prevBareRefBody: Null<PrevBodyInfo> = c.prevBareRefBody;
		// @:fmt(sameLine(...)) on a try-parse Star: each element is preceded by
		// a runtime-conditional separator (space or hardline), so the
		// first element's leading separator acts as the boundary with
		// the preceding struct field (τ₁ — catches against try body).
		// Per-element shape is not captured today, so `Keep` degrades
		// to `Same` at this site (ω-keep-policy).
		final optFlag: Expr = optFieldAccess(sameLineName);
		final sepExpr: Expr = sameLinePolicySwitch(optFlag, macro _dt(' '));
		// ω-block-shape-aware: when the Star carries
		// `@:fmt(blockBodyKeepsInline)` AND the prev struct field's
		// body has block ctors AND the element type carries a same-
		// typed body field, force `_dt(' ')` for any iteration whose
		// preceding body was a block ctor. Mirrors the trivia path;
		// the plain path's element access drops the `.node`
		// indirection.
		//
		// ω-statement-bare-break: dual flag `@:fmt(bareBodyBreaks)`
		// inverts the cases — block bodies fall through to `sepExpr`
		// (policy-driven), bare bodies force `_dhl()`. See trivia-
		// path comment for rationale.
		final blockShapeAware: Bool = starNode.fmtHasFlag('blockBodyKeepsInline');
		final bareShapeAware: Bool = starNode.fmtHasFlag('bareBodyBreaks');
		final shapeAware: Bool = blockShapeAware || bareShapeAware;
		final blockPatterns: Array<Expr> = prevBareRefBody != null && shapeAware
			? (
				bareShapeAware
					? collectBlockShapeEquivalentPatterns(ctx.ctorPat, prevBareRefBody.typePath)
					: collectBlockCtorPatterns(ctx.ctorPat, prevBareRefBody.typePath)
			)
			: [];
		final elemBodyField: Null<String> = blockPatterns.length > 0
			? findElementBodyField(ctx.ctorPat, elemRefName, prevBareRefBody.typePath)
			: null;
		if (blockPatterns.length == 0) {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				while (_si < _arr.length) {
					_docs.push($sepExpr);
					_docs.push($elemCall);
					_si++;
				}
				_dc(_docs);
			});
		} else {
			final blockKeepsInlineBranch: Expr = blockBodyKeepsInlineBranch(starNode);
			final firstBlockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
			final firstBareBranch: Expr = blockShapeAware ? sepExpr : (macro _dhl());
			final firstShapeCases: Array<Case> = [
				{ values: blockPatterns, expr: firstBlockBranch, guard: null },
				{ values: [macro _], expr: firstBareBranch, guard: null }
			];
			final firstSepShape: Expr = {
				expr: ESwitch(prevBareRefBody.access, firstShapeCases, null),
				pos: Context.currentPos()
			};
			final subsequentSepExpr: Expr = if (elemBodyField == null)
				sepExpr;
			else {
				final prevElemBodyAccess: Expr = {
					expr: EField(macro _arr[_si - 1], elemBodyField),
					pos: Context.currentPos()
				};
				final subBlockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
				final subBareBranch: Expr = blockShapeAware ? sepExpr : (macro _dhl());
				final cases: Array<Case> = [
					{ values: blockPatterns, expr: subBlockBranch, guard: null },
					{ values: [macro _], expr: subBareBranch, guard: null }
				];
				{ expr: ESwitch(prevElemBodyAccess, cases, null), pos: Context.currentPos() };
			};
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				while (_si < _arr.length) {
					_docs.push(_si == 0 ? $firstSepShape : $subsequentSepExpr);
					_docs.push($elemCall);
					_si++;
				}
				_dc(_docs);
			});
		}
	}

	private static function emitTryparsePadStar(ctx: StarEmitCtx, c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		// `@:fmt(padLeading)` / `@:fmt(padTrailing)` — when the Star
		// is bracketed by surrounding tokens emitted OUTSIDE this
		// struct (an outer enum ctor's kwLead / trailText, or a
		// sibling Ref before it) AND has no own `@:lead`/`@:trail`
		// to carry the space, the internal-only sep leaves
		// `prevTok<elem1 elem2>nextTok` glued together. Opting into
		// `padLeading` emits a leading space when the array is non-
		// empty (`prevTok elem1 elem2>nextTok`); `padTrailing` does
		// the same on the trailing side; combine for the symmetric
		// `prevTok elem1 elem2 nextTok` shape (used by
		// `HxConditionalMod.body` to fence between `#if cond`/`#end`).
		// Empty arrays still degrade to `_de()` (no padding, no
		// stray space). Format-neutral — any grammar nesting a
		// padded Star inside a surrounding-token sandwich can adopt
		// either flag without touching the macro.
		final padLeading: Bool = starNode.fmtHasFlag('padLeading');
		final padTrailing: Bool = starNode.fmtHasFlag('padTrailing');
		// ω-abstract-clauses-linewrap: when a bare-Star with padLeading
		// (and/or padTrailing) opts in via `@:fmt(lineLengthAwareSeps)`,
		// replace each hard padding/inter-element space with an
		// `IfLineExceeds(opt.lineWidth, _dhl(), _dt(' '))` probe and
		// wrap the body in `Nest(_cols, ...)` so break-mode hardlines
		// indent +1 from the enclosing decl. Mirrors fork's
		// `wrapAfter` + `CodeLine.applyWrapping` mechanism for
		// `abstract <T>(...) [from X]*` clauses (MarkWhitespace.hx:79
		// + codedata/CodeLine.hx:47). Single-clause and short-multi-
		// clause cases decide correctly without a multi-pass marker
		// because `IfLineExceeds`'s rest-of-stack walker sees the
		// trailing same-line content (members `{}` + close-trailing
		// comment). First consumer is `HxAbstractDecl.clauses`.
		final lineLengthAwareSeps: Bool = starNode.fmtHasFlag('lineLengthAwareSeps');
		// ω-condcomp-body-leading-sep: read the runtime
		// `<field>SepBefore:Bool` slot synthesised by
		// `TriviaTypeSynth.isSepBeforeOptStarField`. When true at
		// write time, prepend the sep literal to the leading pad
		// (`_dt(', ')` in place of `_dt(' ')`). Requires `padLeading`
		// — the leading pad is the only Doc slot in this branch that
		// fires adjacent to the enclosing kw (`#if cond`). Combining
		// with `lineLengthAwareSeps` is rejected at macro time (no
		// current consumer; the line-wrap probe would have to
		// swallow the comma into the breakable probe, which the
		// fork semantics for `#if cond, body` does NOT do).
		//
		// The slot lives on the trivia-paired typedef only (sister
		// gate in `StructSeqLowering.lowerStruct` skips the plain-mode
		// struct literal). Plain writer keeps the
		// `_dt(' ')` pad — no slot
		// to read.
		final sepBeforeOpt: Bool = starNode.fmtHasFlag('sepBeforeOpt');
		if (sepBeforeOpt && !padLeading)
			Context.fatalError('WriterLowering: @:fmt(sepBeforeOpt) requires @:fmt(padLeading)', Context.currentPos());
		if (sepBeforeOpt && lineLengthAwareSeps)
			Context.fatalError(
				'WriterLowering: @:fmt(sepBeforeOpt) is not compatible with @:fmt(lineLengthAwareSeps)', Context.currentPos()
			);
		final sepBeforeOptActive: Bool = sepBeforeOpt && ctx.ctx.trivia;
		// ω-condcomp-body-softfill: plain-mode
		// `@:sep + @:tryparse` Star with `@:fmt(padLeading[, padTrailing])`
		// can opt into Wadler `Fill(items, sep)` inter-element layout via
		// `@:fmt(softFill)`. Items pack inline up to the current line
		// budget and break the sep before any overflow item at the
		// surrounding Nest's indent. Handles
		// `#if air, p1, p2, …, pN #end` inside an outer function-
		// signature Star whose source wraps the body across multiple
		// lines. The flat sep is `Concat([Text(sepText), Line(' ')])` —
		// flat=`,` + ` `, break=`,` + newline+indent. The current
		// outer-Group Nest from `wrapRules('functionSignatureWrap')`
		// supplies the break-mode indent (matches `#if`'s column in
		// every fork-corpus shape observed for cond-comp params).
		// Mutually exclusive with `lineLengthAwareSeps` — the latter
		// owns its own break primitive and the two would double-decide
		// the wrap.
		final softFill: Bool = starNode.fmtHasFlag('softFill');
		if (softFill && lineLengthAwareSeps)
			Context.fatalError('WriterLowering: @:fmt(softFill) is not compatible with @:fmt(lineLengthAwareSeps)', Context.currentPos());
		if (softFill && !(padLeading || padTrailing))
			Context.fatalError('WriterLowering: @:fmt(softFill) requires @:fmt(padLeading) or @:fmt(padTrailing)', Context.currentPos());
		final padFlags: PadFlags = {
			padLeading: padLeading,
			padTrailing: padTrailing,
			lineLengthAwareSeps: lineLengthAwareSeps,
			sepBeforeOptActive: sepBeforeOptActive,
			softFill: softFill
		};
		emitTryparsePadEmit(c, padFlags, parts);
	}

	/**
	 * `@:trivia` Star dispatch (the whole `if (isTriviaStar)` block of
	 * `emitWriterStarField`). Validates the trivia sep/raw/tryparse combinations,
	 * builds the `TriviaStarCtx` via `buildTriviaStarCtx`, then routes to the
	 * tryparse / close / EOF trivia emit helper. Extracted to keep the orchestrator
	 * under the complexity gate.
	 */
	@:access(anyparse.macro.WriterTriviaStarDispatch)
	private static function emitTriviaStar(ctx: StarEmitCtx, args: StarFieldArgs, parts: Array<Expr>): Void {
		final starNode: ShapeNode = args.starNode;
		final isLastField: Bool = args.isLastField;
		final isRaw: Bool = args.isRaw;
		final closeText: Null<String> = args.closeText;
		final sepText: Null<String> = args.sepText;
		if (isRaw) Context.fatalError('WriterLowering: @:trivia Star does not support @:raw', Context.currentPos());
		// ω-blockended-trivia-tryparse (Session 3): @:trivia + @:sep +
		// @:tryparse is now allowed when the `blockEnded` flag is
		// present (sole consumer: HxCaseBranch.body / HxDefaultBranch.stmts).
		// EOF mode (closeText == null, no @:tryparse) still rejects.
		final writerBlockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		// ω-sep-faithful: valid alternative to blockEnded — sep re-emission
		// keyed purely on the captured per-element `sepAfter`.
		final writerSepFaithful: Bool = starNode.annotations['lit.sepFaithful'] == true;
		if (sepText != null && closeText == null && !starNode.hasMeta(':tryparse'))
			Context.fatalError('WriterLowering: @:trivia + @:sep requires close-peek (@:trail) or @:tryparse', Context.currentPos());
		if (sepText != null && starNode.hasMeta(':tryparse') && !writerBlockEnded && !writerSepFaithful)
			Context.fatalError(
				'WriterLowering: @:trivia + @:sep + @:tryparse requires blockEnded flag (@:sep(text, tailRelax, blockEnded)) '
				+ 'or sepFaithful',
				Context.currentPos()
			);
		// ω-orphan-trivia / ω-close-trailing: Seq-struct call sites
		// drive the trailing slots synthesised on the paired type.
		// Alt-branch Star call sites (`HxStatement.BlockStmt`) have
		// no synth slots and pass null — writer falls back to pre-
		// slice behaviour. `TrailingClose` is only synthesised for
		// close-peek Stars (those with `lit.trailText`); EOF-mode
		// Stars forward null to preserve the post-loop emission
		// shape without a dangling slot access.
		final triviaCtx: TriviaStarCtx = buildTriviaStarCtx(args);
		if (starNode.hasMeta(':tryparse')) {
			emitTriviaTryparseStar(ctx, triviaCtx, parts);
			return;
		}
		if (closeText != null) {
			WriterTriviaStarDispatch.emitTriviaCloseStar(ctx.triviaStar, triviaCtx, parts);
		} else if (isLastField) {
			emitTriviaEofStar(ctx, triviaCtx, parts);
		} else {
			Context.fatalError('WriterLowering: @:trivia Star without @:trail must be the last field', Context.currentPos());
		}
	}

	/**
	 * Trivia `@:tryparse` Star dispatch (the `if (starNode.hasMeta(':tryparse'))`
	 * branch of `emitWriterStarField`). Reads the per-construct `@:fmt` flags and
	 * sep-override switches, then pushes the `triviaTryparseStarExpr` emit onto
	 * `parts`. Extracted so the orchestrator stays under the complexity gate.
	 */
	@:access(anyparse.macro.TriviaTryparseLowering, anyparse.macro.WriterCtorBlankLowering)
	private static function emitTriviaTryparseStar(ctx: StarEmitCtx, c: TriviaStarCtx, parts: Array<Expr>): Void {
		// noqa: complexity
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final elemRefName: String = c.elemRefName;
		final isLastField: Bool = c.isLastField;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final prevBareRefBody: Null<PrevBodyInfo> = c.prevBareRefBody;
		final prevTrailFieldName: Null<String> = c.prevTrailFieldName;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		final trailBAAccess: Null<Expr> = c.trailBAAccess;
		if (closeText != null) Context.fatalError('WriterLowering: @:trivia + @:tryparse must not have @:trail', Context.currentPos());
		// Non-last-field @:trivia @:tryparse is supported only when
		// the Star is bare (no `@:lead`). The emitted Doc then
		// stands alone (empty array → `_de()`), and the next
		// sibling's leading separator in `lowerStruct` already gates
		// on `prevAnyStarNonEmpty` via the bare-tryparse-Star
		// tracker, so the space between Star output and next
		// field never leaks when the Star was empty. Required by
		// `HxMemberDecl.modifiers` (not last — `member` follows).
		//
		// `@:lead` on a non-last bare-tryparse Star would emit the
		// lead text unconditionally even on empty input, leaking
		// the literal across an otherwise-empty member position.
		// Reject loudly until a grammar needs it AND the empty-
		// input case is gated.
		if (!isLastField && openText != null)
			Context.fatalError('WriterLowering: non-last @:trivia @:tryparse Star must be bare (no @:lead)', Context.currentPos());
		if (openText != null) parts.push(macro _dt($v{openText}));
		// sameLine-annotated Stars (catches against try body) emit
		// the separator before EVERY element — it's the boundary
		// with the preceding struct field. Non-sameLine Stars
		// (case / default bodies) emit it only between elements,
		// matching the plain-mode tryparse writer.
		final sameLineName: Null<String> = starNode.fmtReadString('sameLine');
		final sepExpr: Expr = if (sameLineName != null) {
			final optFlag: Expr = optFieldAccess(sameLineName);
			sameLinePolicySwitch(optFlag, macro _dt(' '));
		} else {
			macro _dt(' ');
		};
		final nestBody: Bool = starNode.fmtHasFlag('nestBody');
		// ω-cond-comp-branch-trail: conditional branch bodies (`@:fmt(padTrailing)`
		// tryparse Stars) also carry orphan trailing trivia before `#end`/`#else`
		// (the parser captures it on element-parse failure, same as nestBody). The
		// slots stay empty for every other padTrailing Star, so the emit is
		// byte-inert until the parser writes them.
		final branchTrail: Bool = starNode.fmtHasFlag('padTrailing');
		// Trailing slots carry orphan trivia when nestBody (case/default bodies)
		// or padTrailing (conditional branch bodies) is on — the parser gates
		// capture on the same flags. Otherwise zero; forward null to keep the
		// writer path byte-identical.
		final tryparseTrailBB: Null<Expr> = nestBody || branchTrail ? trailBBAccess : null;
		final tryparseTrailLC: Null<Expr> = nestBody || branchTrail ? trailLCAccess : null;
		final tryparseTrailBA: Null<Expr> = nestBody ? trailBAAccess : null;
		// ω-close-trailing-alt: when prev field was a bare-Ref to a
		// trivia-bearing type whose Alt has close-trailing branches
		// (currently `HxStatement.BlockStmt`), build a runtime
		// override on the FIRST element's separator. `BlockStmt(_, ct)`
		// with `ct != null` means the body's writer already
		// terminated its output with `\n` after the trailing line
		// comment — the normal space sep would leak ` ` between the
		// indent and the next sibling (e.g. `catch`). The override
		// emits `_de()` instead; non-matching ctors fall through.
		final sepOverrides: TryparseSepOverrides = buildTryparseSepOverrides(
			ctx, starNode, sameLineName, prevBareRefBody, elemRefName, sepExpr
		);
		final firstSepOverride: Null<Expr> = sepOverrides.firstSepOverride;
		final subsequentSepOverride: Null<Expr> = sepOverrides.subsequentSepOverride;
		// ω-case-body-policy / ω-case-body-keep:
		// `@:fmt(bodyPolicy('flag1', 'flag2', ...))` on a
		// `nestBody` Star opts the body field into runtime
		// single-stmt-flat emission. The runtime ORs all named
		// `BodyPolicy` flags across two predicates:
		//  - ANY flag == `Same` → flatten unconditionally (override).
		//  - ANY flag == `Keep` → flatten IFF the source had the
		//    body's first element on the same line as the lead
		//    (read off `Trivial<T>.newlineBefore`).
		// Either path gates on the body holding exactly one element
		// with no leading / orphan-trailing trivia; multi-stmt and
		// trivia-bearing bodies stay multiline. Consumed by
		// `HxCaseBranch.body` and `HxDefaultBranch.stmts` to
		// switch between `case X:\n\tstmt;` (Next) and
		// `case X: stmt;` (Same / Keep+sameLine).
		final caseBodyFlagNames: Array<String> = starNode.fmtReadStringArgs('bodyPolicy') ?? [];
		// ω-expression-case-flat-fanout: when `@:fmt(flatChildOpt('A=B', …))`
		// is present, parse each `'from=to'` arg into a [from, to] pair so
		// `triviaTryparseStarExpr` can emit a `Reflect.copy(opt)` + per-pair
		// override block in the runtime flat-case branch.
		final flatChildOptRaw: Null<Array<String>> = starNode.fmtReadStringArgs('flatChildOpt');
		final flatChildOptPairs: Array<Array<String>> = if (flatChildOptRaw == null)
			[]
		else {
			final out: Array<Array<String>> = [];
			for (raw in flatChildOptRaw) {
				final eq: Int = raw.indexOf('=');
				if (eq <= 0 || eq >= raw.length - 1)
					Context.fatalError(
						'WriterLowering: @:fmt(flatChildOpt(...)) arg must be "from=to", got "${raw}"', Context.currentPos()
					);
				out.push([raw.substr(0, eq), raw.substr(eq + 1)]);
			}
			out;
		};
		// ω-cond-mod-pad: `@:fmt(padLeading)`/`@:fmt(padTrailing)` on
		// a `@:trivia @:tryparse` Star emit a leading/trailing space
		// when non-empty (matches the non-trivia padLeading/padTrailing
		// branch), with the leading slot SWITCHING to `_dhl()` when
		// the source had a newline before the first element. Used by
		// `HxConditionalMod.body` so V1–V3 (single-line `#if X mods #end`)
		// stay on one line and V4 (newline-separated cond/mods/`#end`)
		// breaks all three pad slots together — the trail-side pad
		// follows the leading-side decision because the parser does
		// not capture a body→`#end` newline slot, but in legal source
		// shapes the two newlines are correlated.
		// ω-splice-op-fill: `@:fmt(fillItems)` hands the gap BEFORE the first
		// element to the enclosing struct's `@:fmt(fillParts)` run, so the
		// Star's own leading pad must not fire in trivia mode — including on
		// the comment fallback, which emits the ordinary Star body and would
		// otherwise spend a second separator on the same gap (`#if flash  'b'`,
		// measured). The PLAIN writer keeps the pad: it has no fill to take
		// the gap from it.
		final tryparsePadLeading: Bool = starNode.fmtHasFlag('padLeading') && !starNode.fmtHasFlag('fillItems');
		final tryparsePadTrailing: Bool = starNode.fmtHasFlag('padTrailing');
		// ω-cond-indent-policy: `@:fmt(conditionalBodyIndent)` on a
		// `@:trivia @:tryparse` cond-comp body / elseBody / elseif-body
		// Star opts the body content into the runtime
		// `opt.conditionalPolicy` indent rule. When the policy is
		// `AlignedIncrease`, the body content (leading pad hardline +
		// each body element) is wrapped in `_dn(_cols, …)` so it sits
		// one level deeper than the `#if`/`#else`/`#end` markers, while
		// the trailing pad hardline (the `\n` before `#else`/`#end`)
		// is emitted OUTSIDE the nest so the close marker stays at the
		// surrounding statement indent. Nesting accumulates per
		// conditional depth (a nested `#if` body re-enters the same
		// `_dn`). DEFAULT `Aligned` → the runtime gate is false → the
		// pre-policy `else` branch fires → byte-identical. Only the
		// cond-comp body Stars carry this flag, so every other tryparse
		// Star consumer is untouched.
		final tryparseCondBodyIndent: Bool = starNode.fmtHasFlag('conditionalBodyIndent');
		// ω-issue-423-mech-a: `@:fmt(propagateExprPosition)` on a
		// `@:trivia @:tryparse` Star marks the body as an expression-
		// position frame for descendants. The runtime block emits an
		// always-copy of `opt` with `_inExprPosition = true` set, so
		// the dual-flag `bodyPolicy('A','B')` flat-gate in nested
		// case-body sites picks the expression-position policy
		// (`expressionCase`) instead of the statement-position one
		// (`caseBody`). Mirrors fork's `isReturnExpression` walk-up
		// heuristic — currently wired only by `HxCaseBranch.body` /
		// `HxDefaultBranch.stmts` so a case nested in another case's
		// body inherits expression context.
		final propagateExprPosition: Bool = starNode.fmtHasFlag('propagateExprPosition');
		// ω-value-yielded-if-tail-barrier (case-body extension of SI-2):
		// `@:fmt(clearExprPositionNonTail)` on a case / default body Star
		// (paired with `propagateExprPosition`) clears `_inExprPosition`
		// for every NON-tail body statement, so a discarded statement-if
		// reverts to the statement-position `ifBody` policy while the
		// body's yielded tail keeps the expression frame. False → byte-
		// identical (every other tryparse-Star consumer is untouched).
		final clearExprPositionNonTail: Bool = starNode.fmtHasFlag('clearExprPositionNonTail');
		// ω-issue-423-mech-b: `@:fmt(refuseFlatOnComplexExpr)` AND-s the
		// runtime `_flatCase` gate with the generated typed
		// `caseBodyRefusesFlat` predicate of the build's AST family
		// (addressed by naming convention — the engine never references
		// the grammar plugin by name; a grammar carrying the meta must
		// provide the marker classes). Wired on `HxCaseBranch.body` /
		// `HxDefaultBranch.stmts` to mirror fork's
		// `MarkSameLine.markExpressionCase` body-shape check.
		final refuseFlatOnComplex: Bool = starNode.fmtHasFlag('refuseFlatOnComplexExpr');
		// omega-case-body-controlflow-glue: `@:fmt(refuseGlueOnControlFlowRoot)`
		// tells the `FitLine` case-body path to REFUSE the glue outcome when
		// the body's single statement is keyword-led control flow (the
		// generated `caseBodyControlFlowRoot` predicate of the build's AST
		// family). Such a construct's continuation lines are siblings of its
		// head, so glued they render at the head's indent, which under
		// `alignInlineSwitchCaseBody` is the LABEL's. Wired on
		// `HxCaseBranch.body` / `HxDefaultBranch.stmts` alongside
		// `refuseFlatOnComplexExpr`.
		//
		// The SAME meta gates the accompanying sibling FORCE in the case-LIST
		// Star's pre-pass - `caseSiblingControlFlowFnExpr` reads it back off this
		// body Star through `elemBodyStarHasFlag`, so the two halves cannot be
		// enabled apart. Flag off => byte-identical on BOTH.
		final refuseGlueOnControlFlow: Bool = starNode.fmtHasFlag('refuseGlueOnControlFlowRoot');
		// ω-metadata-line-end-function: `@:fmt(metaLineEndPolicy('<optField>'))`
		// on a `@:trivia @:tryparse` Star wires inter-element + post-Star
		// separator dispatch through `opt.<optField>:MetadataLineEndPolicy`.
		// Default `None` (and absent flag) is byte-identical to pre-slice.
		final metaLineEndOptField: Null<String> = starNode.fmtReadString('metaLineEndPolicy');
		// ω-bug-2c-inner-star — read the same cascade `@:fmt(blankLines*)`
		// metas that the EOF-Star branch reads, so an inner Star (e.g.
		// `HxConditionalDecl.body`) opted in via the metas drives the
		// blank-line cascade between its sibling elements.
		final cascadeInfos: CascadeInfos = WriterCtorBlankLowering.readCascadeInfosFromStar(ctx.ctorBlank, starNode, elemRefName);
		// ω-trivia-tryparse-linelength: when the Star carries
		// `@:fmt(lineLengthAwareSeps)`, swap inter-element + padLeading
		// hard spaces for `_dile` probes + wrap in `_dn(_cols, ...)`.
		// Sister to the non-trivia bare-Star `padLeading||padTrailing`
		// branch's lineLengthAware path.
		final tryparseLineLengthAware: Bool = starNode.fmtHasFlag('lineLengthAwareSeps');
		// B4 ω-implements-extends-wrap: `@:fmt(heritageWrap)` on a
		// `@:trivia @:tryparse` Star (HxClassDecl.heritage /
		// HxInterfaceDecl.heritage) routes a MULTI-clause heritage list
		// (`extends A implements B …`) through the fork's
		// `wrapping.implementsExtends` FillLine layout: when the full
		// glued decl line is long, pack clauses from the front and break
		// the overflow clause(s) at additionalIndent 2 (8 spaces). The
		// single-clause path stays on the existing `lineLengthAwareSeps`
		// 1-tab break-before-keyword (matches fork single-clause +
		// `extends_break_before_keyword_not_type_params`). Abstract
		// `clauses` (from/to) never carries this flag — its
		// `lineLengthAwareSeps` behaviour is untouched.
		final tryparseHeritageWrap: Bool = starNode.fmtHasFlag('heritageWrap');
		// ω-slice-45 / issue_626: `@:fmt(forceInlineSep)` on a `@:trivia
		// @:tryparse` Star collapses every source linebreak between
		// consecutive elements to a single space. First consumers are
		// the modifier Stars on `HxMemberDecl.modifiers` and
		// `HxTopLevelDecl.modifiers` so multi-line `static\n\toverload`
		// round-trips as `static overload`. Comment trivia between
		// elements is out of scope — flag's contract is "treat
		// inter-element whitespace trivia as one space".
		final tryparseForceInlineSep: Bool = starNode.fmtHasFlag('forceInlineSep');
		// ω-cond-comp-elseif-double-newline: set on the cond-comp `elseifs`
		// Stars (HxConditional*.elseifs) whose HxElseif* elements self-terminate
		// with a padTrailing newline. See triviaTryparseStarExpr's
		// elemSelfTrailsNewline param.
		final tryparseElemSelfTrailsNewline: Bool = starNode.fmtHasFlag('elemSelfTrailsNewline');
		// ω-typedef-intersection-operand-break: `@:fmt(
		// operandBreakAfterMultilineBrace)` on a `@:trivia @:tryparse`
		// Star makes each element whose PRECEDING element rendered
		// multi-line and ended with a close brace receive a per-element
		// opt copy with `_intersectionOperandBreak = true`. Consumer:
		// `HxTypedefDecl.intersections` (the `& Type` clause Star).
		final tryparseOperandBreakAfterMultilineBrace: Bool = starNode.fmtHasFlag('operandBreakAfterMultilineBrace');
		// ω-trivia-tryparse-prior-after-trail: when the PREV sibling
		// field has a synthesised `<priorField>AfterTrail:Null<String>`
		// slot (mandatory Ref with `@:trail` in trivia-bearing mode),
		// thread its access so the Star can inline-emit the captured
		// trail-of-prev-field comment cuddled to the prev token.
		final tryparsePriorAfterTrailExpr: Null<Expr> = prevTrailFieldName == null ? null : {
			expr: EField(macro value, prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-blockended-trivia-tryparse (Session 3): thread the Star's
		// `@:sep('text', tailRelax, blockEnded)` annotation into
		// `triviaTryparseStarExpr` so the helper can inject `;`
		// between two non-`}`-ending elements. Non-blockEnded
		// tryparse Stars (every existing consumer) pass null sepText
		// and the helper splices a no-op.
		final tryparseSepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final tryparseBlockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		final tryparseSepFaithful: Bool = starNode.annotations['lit.sepFaithful'] == true;
		// ω-sep-faithful: re-emit a source-captured LEADING sep
		// (`#if X, elem #end`) from the `<field>SepBefore` slot — the trivia
		// twin of the plain path's sepBeforeOptActive pad swap.
		final tryparseSepBeforeAccess: Null<Expr> = tryparseSepFaithful && starNode.fmtHasFlag('sepBeforeOpt')
			? switch fieldAccess.expr {
				case EField(b, n): { expr: EField(b, '${n}SepBefore'), pos: fieldAccess.pos };
				case _: null;
			}
			: null;
		// Typed nested-conditional element probe (alignedNestedIncrease
		// span lift + blockEnded sep suppression): built HERE, where the
		// Star's element rule is known, as the mode-family
		// `elementIsConditional_<ElemRule>` fn-ref. Built only for the
		// Stars whose emission paths can consult it (conditionalBodyIndent
		// / blockEnded) — the grammar generates the per-rule variants for
		// exactly those element rules. Formats without generated
		// predicates pass null and both consumer sites emit their inert
		// `false`.
		final tryparseElemCondFn: Null<Expr> = ctx.formatInfo.astPreds && (tryparseCondBodyIndent || tryparseBlockEnded)
			? AstPredLowering.predFnExpr(ctx.shape.root, true, false, 'elementIsConditional_${simpleName(c.elemRefName)}')
			: null;
		// omega-cond-expr-fit: `@:fmt(condExprFitBreak)` on the tryparse Star
		// (the expression-scope cond-comp `elseifs`) swaps its inter-element
		// and trailing-pad spaces for knob-gated soft `Line(' ')` seps.
		final tryparseCondExprFit: Bool = starNode.fmtHasFlag('condExprFitBreak');
		// ω-splice-op-fill: `@:fmt(fillItems)` routes the Star to the fill
		// bypass — soft `Line(' ')` between elements, no pad, source newlines
		// ignored. Sole consumer: `HxCondSpliceOpExpr.terms`.
		final tryparseFillItems: Bool = starNode.fmtHasFlag('fillItems');
		parts.push(TriviaTryparseLowering.triviaTryparseStarExpr(
			tryCatchesSymmetryWrap(ctx.braceSym, starNode, fieldAccess, elemRefName), elemFn, sepExpr, sameLineName != null, nestBody,
			tryparseTrailBB, tryparseTrailLC, tryparseTrailBA, firstSepOverride, subsequentSepOverride, caseBodyFlagNames,
			flatChildOptPairs, tryparsePadLeading, tryparsePadTrailing, propagateExprPosition, refuseFlatOnComplex,
			cascadeInfos.afterCtorInfos, cascadeInfos.beforeCtorInfos, cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos,
			cascadeInfos.headCtorInfos, metaLineEndOptField, cascadeInfos.betweenSameCtorIfNotInfos, tryparseLineLengthAware,
			tryparsePriorAfterTrailExpr, tryparseForceInlineSep, tryparseBlockEnded || tryparseSepFaithful ? tryparseSepText : null,
			tryparseBlockEnded, tryparseSepFaithful, tryparseHeritageWrap, tryparseCondBodyIndent, tryparseOperandBreakAfterMultilineBrace,
			clearExprPositionNonTail, tryparseSepBeforeAccess, tryparseElemSelfTrailsNewline, tryparseCondExprFit, tryparseElemCondFn,
			refuseGlueOnControlFlow, tryparseFillItems
		));
	}

	/**
	 * Emit writer steps for a Star struct field.
	 * Trivia `@:tryparse` Star dispatch (the `if (starNode.hasMeta(':tryparse'))`
	 * branch of `emitWriterStarField`). Reads the per-construct `@:fmt` flags and
	 * sep-override switches, then pushes the `triviaTryparseStarExpr` emit onto
	 * `parts`. Extracted so the orchestrator stays under the complexity gate.
	 * Builds the first / subsequent element separator overrides for a
	 * `@:trivia @:tryparse` Star (the close-trailing + block-shape-aware switches).
	 * Bundled for `emitTriviaTryparseStar`. Extracted to keep that helper under the
	 * complexity gate.
	 */
	private static function buildTryparseSepOverrides(
		ctx: StarEmitCtx, starNode: ShapeNode, sameLineName: Null<String>, prevBareRefBody: Null<PrevBodyInfo>, elemRefName: String,
		sepExpr: Expr
	): TryparseSepOverrides {
		final closeTrailingFirstOverride: Null<Expr> = sameLineName != null
			? buildCloseTrailingFirstSepOverride(ctx, prevBareRefBody, sepExpr)
			: null;
		// ω-block-shape-aware: when the Star carries
		// `@:fmt(blockBodyKeepsInline)` AND the prev body's enum has
		// block ctors, force the leading sep before each catch
		// element to `_dt(' ')` whenever the previous body (struct
		// field for the first iteration, prev element's body for
		// subsequent iterations) was a block ctor. Composes with the
		// close-trailing override above by using it as the non-block
		// fallback on the first iteration.
		//
		// ω-statement-bare-break: dual flag `@:fmt(bareBodyBreaks)`
		// flips the cases — block bodies fall through to the policy-
		// driven `sepExpr` (or close-trailing override on the first
		// iteration) and bare bodies force `_dhl()`. Both
		// `HxTryCatchStmt.catches` (block-form ctor with non-block
		// body via `ExprStmt(...)`) and `HxTryCatchStmtBare.catches`
		// (bare-form, body=HxExpr) opt in — non-block prev-body
		// pairs with `tryBody=Next` to keep the multi-line layout
		// coherent: `try\n\tBARE;\ncatch (...)`. Block bodies stay
		// under policy control (`sameLineCatch=Next` still breaks
		// `} catch` to `}\ncatch`). The block-ctor predicate is
		// `isBlockShapeEquivalentBranch` (sister of
		// `isBlockCtorBranch` that also accepts `@:fmt(blockShape)`
		// opt-in ctors like `UntypedBlockStmt(body:HxUntypedFnBody)`,
		// which emits `untyped { … }` — visually a block).
		final blockShapeAware: Bool = starNode.fmtHasFlag('blockBodyKeepsInline');
		final bareShapeAware: Bool = starNode.fmtHasFlag('bareBodyBreaks');
		// omega-try-brace-symmetry: the `BodyPolicy` knobs governing the two bodies this separator
		// can follow — the try body for the FIRST catch, the previous catch's body for every later
		// one. Absent (`@:fmt(bareBodyBreaks)` with no args) keeps the unconditional hardline.
		final barePolicyFields: Array<String> = starNode.fmtReadStringArgs('bareBodyBreaks') ?? [];
		final softSeam: Bool = starNode.fmtHasFlag('constructFitSep');
		final shapeAware: Bool = blockShapeAware || bareShapeAware;
		// `bareBodyBreaks` includes blockShape opt-in ctors (e.g.
		// `UntypedBlockStmt`) — they end with `}` and should be
		// treated as block for the catch-separator decision while
		// staying non-block in `bodyPolicyWrap`'s strict block-ctor
		// override path.
		final blockPatterns: Array<Expr> = sameLineName != null && prevBareRefBody != null && shapeAware
			? (
				bareShapeAware
					? collectBlockShapeEquivalentPatterns(ctx.ctorPat, prevBareRefBody.typePath)
					: collectBlockCtorPatterns(ctx.ctorPat, prevBareRefBody.typePath)
			)
			: [];
		final elemBodyField: Null<String> = sameLineName != null && blockPatterns.length > 0
			? findElementBodyField(ctx.ctorPat, elemRefName, prevBareRefBody.typePath)
			: null;
		final blockKeepsInlineBranch: Expr = blockBodyKeepsInlineBranch(starNode);
		final firstSepOverride: Null<Expr> = if (blockPatterns.length == 0)
			closeTrailingFirstOverride;
		else {
			final fallback: Expr = closeTrailingFirstOverride ?? sepExpr;
			final blockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : fallback;
			final bareBranch: Expr = blockShapeAware ? fallback : bareSepBreak(barePolicyFields[0], sepExpr, softSeam);
			final cases: Array<Case> = [
				{ values: blockPatterns, expr: blockBranch, guard: null },
				{ values: [macro _], expr: bareBranch, guard: null }
			];
			{ expr: ESwitch(prevBareRefBody.access, cases, null), pos: Context.currentPos() };
		};
		final subsequentSepOverride: Null<Expr> = if (elemBodyField == null)
			null;
		else {
			final prevElemBodyAccess: Expr = {
				expr: EField(macro _arr[_si - 1].node, elemBodyField),
				pos: Context.currentPos()
			};
			final blockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
			final bareBranch: Expr = blockShapeAware ? sepExpr : bareSepBreak(barePolicyFields[1], sepExpr, softSeam);
			final cases: Array<Case> = [
				{ values: blockPatterns, expr: blockBranch, guard: null },
				{ values: [macro _], expr: bareBranch, guard: null }
			];
			{ expr: ESwitch(prevElemBodyAccess, cases, null), pos: Context.currentPos() };
		};
		return { firstSepOverride: firstSepOverride, subsequentSepOverride: subsequentSepOverride };
	}

	/**
	 * ω-close-trailing-alt — runtime override for a Star's first-element
	 * separator when the immediately preceding struct field was a bare
	 * Ref to a trivia-bearing type. Iterates the prev body's Alt branches
	 * looking for close-trailing branches (Star + `@:trail` + `@:trivia`)
	 * — currently only `HxStatement.BlockStmt`. For each, emits a case
	 * `BlockStmt(_, _ct)` with guard `_ct != null` mapping to `_de()`
	 * (the body's writer already terminated with `\n`, so any sep would
	 * leak ` ` between the indent and the next sibling). The default
	 * case falls through to `sepExpr`. Returns `null` when no override
	 * is needed (no prev body, non-bearing target, or no close-trailing
	 * branches in the Alt) so the caller skips the override path.
	 */
	private static function buildCloseTrailingFirstSepOverride(
		ctx: StarEmitCtx, prevBareRefBody: Null<PrevBodyInfo>, sepExpr: Expr
	): Null<Expr> {
		if (prevBareRefBody == null) return null;
		final rule: Null<ShapeNode> = ctx.shape.rules[prevBareRefBody.typePath];
		if (rule == null || rule.kind != Alt) return null;
		final cases: Array<Case> = [];
		for (branch in rule.children) if (TriviaPairAltCtor.isAltCloseTrailingBranch(branch)) {
			final ctorName: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			final ctorPath: Array<String> = ctx.ruleCtorPath(prevBareRefBody.typePath, ctorName);
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
			// Pattern arity: child shape (1 Star) + the closeTrailing slot
			// (which we BIND as `_ct`) + any further synth extras
			// (currently only openTrailing for `:lead` branches; trailOpt /
			// captureSource predicates are disjoint from the close-trailing
			// shape, but the helper covers them for forward compatibility).
			final extras: Int = branchSynthExtraArity(ctx.ctorPat, prevBareRefBody.typePath, branch);
			final patternArgs: Array<Expr> = [macro _, macro _ct];
			for (_ in 0...extras - 1) patternArgs.push(macro _);
			final pattern: Expr = {
				expr: ECall(ctorRef, patternArgs),
				pos: Context.currentPos()
			};
			cases.push({ values: [pattern], guard: macro _ct != null, expr: macro _de() });
		}
		if (cases.length == 0) return null;
		cases.push({ values: [macro _], guard: null, expr: sepExpr });
		return { expr: ESwitch(prevBareRefBody.access, cases, null), pos: Context.currentPos() };
	}

	/**
	 * Trivia EOF Star dispatch (the `else if (isLastField)` branch of the
	 * `isTriviaStar` block in `emitWriterStarField`). Reads the cascade infos and
	 * file-header / line-comment blank flags, then pushes the `triviaEofStarExpr`
	 * emit onto `parts`. Extracted to keep the orchestrator under the complexity
	 * gate.
	 */
	@:access(anyparse.macro.TriviaEofLowering, anyparse.macro.WriterCtorBlankLowering)
	private static function emitTriviaEofStar(ctx: StarEmitCtx, c: TriviaStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final elemRefName: String = c.elemRefName;
		final openText: Null<String> = c.openText;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		if (openText != null) parts.push(macro _dt($v{openText}));
		// ω-measured-multiline-decl — this is the ONE Star kind whose scaffold
		// declares `_measMulti`, so this is the one caller that may hand the
		// cascade an accessor into it.
		final measuredMultiline: Bool = starNode.fmtHasFlag('measuredMultilineDecls');
		final cascadeInfos: CascadeInfos = WriterCtorBlankLowering.readCascadeInfosFromStar(
			ctx.ctorBlank, starNode, elemRefName, measuredMultiline ? (macro _measMulti[_si]) : null
		);
		final lineCommentTrailBlank: Bool = starNode.fmtHasFlag('blankBeforeOrphanLineCommentTrail');
		final lineCommentLedAddBlank: Bool = starNode.fmtHasFlag('blankBeforeLineCommentLed');
		final afterFileHeaderCommentBlanks: Bool = starNode.fmtHasFlag('afterFileHeaderCommentBlanks');
		final betweenMultilineCommentsBlanks: Bool = starNode.fmtHasFlag('betweenMultilineCommentsBlanks');
		parts.push(TriviaEofLowering.triviaEofStarExpr(
			fieldAccess, trailBBAccess, trailLCAccess, elemFn, cascadeInfos.afterCtorInfos, cascadeInfos.beforeCtorInfos,
			cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos, cascadeInfos.headCtorInfos, lineCommentTrailBlank,
			lineCommentLedAddBlank, afterFileHeaderCommentBlanks, betweenMultilineCommentsBlanks, cascadeInfos.betweenSameCtorIfNotInfos,
			measuredMultiline
		));
	}

	/**
	 * Emit an optional close-peek Star struct field (first consumer:
	 * `HxTypeRef.params`). Builds the inner Star emission against a narrowed
	 * `_optVal`, optionally splices the kw-led sep + kw-trivia layers, and pushes
	 * a `_optVal != null` runtime gate onto `parts`. The caller owns the post-push
	 * accumulator resets.
	 */
	private static function emitOptionalStarField(
		ctx: StarEmitCtx, child: ShapeNode, parts: Array<Expr>, node: ShapeNode, typePath: String, isFirstField: Bool, isRaw: Bool,
		stalePrevBareRefBody: Null<PrevBodyInfo>, prevTrailFieldName: Null<String>, kwLead: Null<String>, fieldName: String,
		prevBodyField: Null<PrevBodyInfo>, prevPadTrailing: Null<Expr>, fieldAccess: Expr
	): Void {
		final innerParts: Array<Expr> = [];
		emitWriterStarField(
			ctx, child, macro _optVal, innerParts, child == node.children[node.children.length - 1], typePath, isFirstField, isRaw,
			stalePrevBareRefBody, prevTrailFieldName
		);
		// ω-typeparam-spacing: when the typeParamOpen=Before/Both
		// path injects a leading-space Doc into innerParts, the
		// list grows to two elements. EBlock would evaluate to
		// the last Doc only and silently drop the space — use
		// `_dc([...])` so the writer concatenates both pieces.
		final innerExpr: Expr = innerParts.length == 1 ? innerParts[0] : dcCall(innerParts);
		if (kwLead != null) {
			// ω-cond-comp-engine: kw-led optional Star writer
			// mirror. Splices the kw-Ref optional path's
			// inter-field sep + kw-trivia layers (sameLineSeparator
			// + kwBeforeDoc + kwBeforeTrailingDoc) with the Star
			// body emitted by `emitWriterStarField`. The Star
			// helper already honours `@:fmt(padLeading, padTrailing)`
			// against the narrowed `_optVal:Array<T>`, so the gap
			// between the kw and the first body element comes
			// from the pad logic — no need for a literal trailing
			// space on the kw token. Empty body degrades to `_de()`
			// inside the helper, mirroring `HxConditionalMod.body`'s
			// non-optional precedent. First consumer:
			// `HxConditionalDecl.elseBody`.
			final useTriviaGap: Bool = ctx.ctx.trivia;
			final sepWithBeforeKwTrailingExpr: Expr = beforeKwSeparator(
				ctx.fieldSep, useTriviaGap, fieldName, child, prevBodyField, typePath, prevPadTrailing
			);
			final kwOptParts: Array<Expr> = [
				sepWithBeforeKwTrailingExpr,
				macro _dt($v{kwLead}),
				innerExpr
			];
			final kwOptBody: Expr = dcCall(kwOptParts);
			parts.push(macro {
				final _optVal = $fieldAccess;
				if (_optVal != null)
					$kwOptBody
				else
					_de();
			});
		} else {
			parts.push(macro {
				final _optVal = $fieldAccess;
				if (_optVal != null)
					$innerExpr
				else
					_de();
			});
		}
	}

	/**
	 * ω-member-meta: build the inter-Star leading separator Doc for a non-first
	 * bare-tryparse Star that follows another bare-tryparse Star. Gated at runtime
	 * on `prev && this.length > 0`; in trivia mode picks `_dhl()` / `_dt(' ')`
	 * from the first element's `newlineBefore` (suppressing a doubled hardline
	 * before a leading doc-comment), plain mode emits a space. Wrapped via
	 * `withPadTrailingDrop`.
	 */
	private static function buildInterStarSep(
		ctx: StarEmitCtx, prevAnyStarNonEmpty: Expr, fieldAccess: Expr, prevPadTrailing: Null<Expr>, ?keepBlankGate: Null<Expr>
	): Expr {
		final prev: Expr = prevAnyStarNonEmpty;
		// ω-region-prefix-blank: this seam already READS `_next[0].blankBefore` to
		// decide the leading-comment suppression, so keeping the blank needs no
		// new slot here — only the ctor gate that tells a `#if … #end` prefix from
		// an ordinary metadata one. Off (`false`) for every field that did not opt
		// in, which collapses the arm to the pre-slice `_dhl()`.
		final blankGate: Expr = keepBlankGate ?? macro false;
		final blankBreak: Expr = dcCall([macro _dhl(), macro _dhl()]);
		final baseExpr: Expr = ctx.ctx.trivia
			? macro {
				final _next = $fieldAccess;
				if ($prev && _next.length > 0) {
					if (_next[0].newlineBefore) {
						// ω-meta-leading-doc-no-blank: when the next bare-
						// tryparse Star's first element carries a leading
						// comment (e.g. a `/** */` doc-comment) directly after
						// the prior Star with NO source blank line between
						// them, suppress this inter-Star separator hardline.
						// The Star's own leading-comment emit already pushes a
						// single `_dhl()` before the comment; emitting both
						// here produces a spurious blank line (issue_578:
						// `@:jsRequire(...)\n/**` → `@:jsRequire(...)\n\n/**`).
						// Source-faithful: a real authored blank
						// (`blankBefore`) keeps the separator so the blank
						// round-trips. No leading comment → unchanged
						// `_dhl()` (the common meta→modifiers newline path).
						if (_next[0].leadingComments.length > 0 && !_next[0].blankBefore)
							_de();
						else if (_next[0].blankBefore && $blankGate)
							$blankBreak;
						else
							_dhl();
					} else
						_dt(' ');
				} else
					_de();
			}
			: macro $prev && $fieldAccess.length > 0 ? _dt(' ') : _de();
		return withPadTrailingDrop(prevPadTrailing, baseExpr);
	}

	/**
	 * ω-pad-trailing-ref / ω-metadata-line-end-function: compute the
	 * non-optional Star field's `thisPadTrailing` runtime expr (or `null`
	 * when the field fires no trailing pad). A `@:fmt(padTrailing)` Star
	 * pads when `_arr.length > 0` OR (ω-line-comment-directive-break) when it
	 * is EMPTY but its orphan trail ends in a `//` comment, since the Star then
	 * emits a break of its own; a `@:fmt(metaLineEndPolicy('<optField>'))`
	 * Star pads when the array is non-empty AND the runtime knob is non-None.
	 *
	 * The empty-arm disjunct is gated on `@:tryparse`: the break it stands for
	 * is emitted by `triviaTryparseStarExpr`, so a `@:fmt(padTrailing)` Star
	 * outside that path would drop its parent's separator with nothing in its
	 * place. Every `padTrailing` Star in the grammar is `@:tryparse` today.
	 */
	private static function starPadTrailing(ctx: StarEmitCtx, child: ShapeNode, fieldAccess: Expr, typePath: String): Null<Expr> {
		if (child.fmtHasFlag('padTrailing')) {
			final lineTrail: Null<Expr> = child.hasMeta(':tryparse') ? starTrailEndsLineExpr(ctx, child, typePath) : null;
			return lineTrail == null ? (macro $fieldAccess.length > 0) : (macro $fieldAccess.length > 0 || $lineTrail);
		}
		final metaLineEndField: Null<String> = child.fmtReadString('metaLineEndPolicy');
		if (metaLineEndField == null) return null;
		final optAccess: Expr = optFieldAccess(metaLineEndField);
		return macro $fieldAccess.length > 0 && $optAccess != 0;
	}

	/**
	 * ω-line-comment-directive-break: runtime "this trivia Star's orphan trail
	 * ends in a `//` comment", or `null` when the `<field>TrailingLeading` slot
	 * does not exist (plain mode, non-trivia-bearing rule, or a Star that does
	 * not collect trivia). The gate keys on `TRIVIA_STAR_COLLECTS`, the same
	 * annotation `TriviaTypeSynth.isTriviaStarField` synthesises the slot from -
	 * a bare `:trivia` meta check would miss the Stars that inherit it from an
	 * enclosing enum branch or from `@:postfix`.
	 *
	 * An EMPTY arm carrying only comments emits no `padTrailing` pad, so the
	 * parent used to follow it with the leading separator of the next field -
	 * a space. Once the Star terminates its own line comment (it must; a `#`
	 * directive glued after `//` becomes comment text) that space lands AFTER
	 * the break and indents the directive by one column. Folding this into the
	 * field's `padTrailing` signal drops the separator through the existing
	 * `withPadTrailingDrop` path. Block-comment trails leave the signal false,
	 * so their same-line separator is untouched.
	 */
	private static function starTrailEndsLineExpr(ctx: StarEmitCtx, child: ShapeNode, typePath: String): Null<Expr> {
		final fieldName: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final collectsTrivia: Bool = child.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		if (fieldName == null || !ctx.ctx.trivia || !ctx.isTriviaBearing(typePath) || !collectsTrivia) return null;
		final access: Expr = {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX),
			pos: Context.currentPos()
		};
		return macro {
			final _tlc: Array<String> = $access;
			_tlc.length > 0 && StringTools.startsWith(_tlc[_tlc.length - 1], '//');
		};
	}

	private static function lowerEnumStarTrivia(ctx: StarEmitCtx, c: EnumStarCtx): Expr {
		final branch: ShapeNode = c.branch;
		final argNames: Array<String> = c.argNames;
		final sepText: Null<String> = c.sepText;
		// ω-close-trailing-alt: same-line trailing comment captured
		// after the close literal (`} // catch`). The synth ctor
		// grew a positional arg (`closeTrailing`) and `argNames[1]`
		// is its writer-side binding. Plain mode keeps the pre-slice
		// null path (no extra arg, no extra binding).
		//
		// ω-open-trailing-alt: parallel slot for the same-line trailing
		// comment captured AFTER the open literal (`[ /* foo */]` for
		// empty arrays, `{ // foo` before first stmt). Synth appends
		// `openTrailing:Null<String>` as `argNames[2]` when the branch
		// also carries `@:lead`. Without this, an inline comment in an
		// otherwise-empty close-peek Star is dropped at parse — the
		// loop's terminal `_lead` is discarded on close-peek break, and
		// `collectTrivia`'s newline-anchored scan skips same-line
		// comments after the open lit anyway.
		final hasOrphan: Bool = TriviaPairAltCtor.isAltCloseTrailingBranch(branch) && branch.readMetaString(':lead') != null
			&& !branch.hasMeta(':tryparse');
		final trailCloseAccess: Null<Expr> = TriviaPairAltCtor.isAltCloseTrailingBranch(branch) ? macro $i{argNames[1]} : null;
		final trailOpenAccess: Null<Expr> = hasOrphan ? macro $i{argNames[2]} : null;
		// ω-orphan-trivia-alt: orphan trivia between the last Star
		// element and the close literal (e.g. trailing line comment
		// inside `try { p(); /* dropped */ }`). Synth grew two
		// positional args (`trailingBlankBefore` at `argNames[3]`,
		// `trailingLeading` at `argNames[4]`) for `isAltCloseTrailingBranch`
		// branches with `@:lead`. The Lowering Case 4 trivia loop
		// captures `_lead.blankBefore` / `_lead.leadingComments` on
		// close-peek break and forwards them. Without this, an inner
		// `// foo` between the last stmt and `}` is dropped at parse —
		// `collectTrivia` runs on the final iteration but its result is
		// discarded on the break.
		final trailBBAccess: Null<Expr> = hasOrphan ? macro $i{argNames[3]} : null;
		final trailLCAccess: Null<Expr> = hasOrphan ? macro $i{argNames[4]} : null;
		// ω-arraylit-source-trail-comma: enum-Alt sep+trail+lead+@:trivia
		// branches grow a 6th positional `trailPresent:Bool` (synth pushes
		// it inside the `isAltCloseTrailingBranch + @:lead + !@:tryparse`
		// block when `branch.readMetaString(':sep') != null`). Bind here so
		// the trivia branch of `triviaSepStarExpr` can preserve a source
		// trailing comma via `appendTrailingCommaExpr = trailPresent ||
		// knob`. Sister to struct-Star `<field>TrailPresent` binding in
		// `lowerStruct`.
		final hasSepTrailPresent: Bool = hasOrphan && sepText != null;
		final sepTrailPresentAccess: Null<Expr> = hasSepTrailPresent ? macro $i{argNames[5]} : null;
		final slots: TriviaAltSlots = {
			trailCloseAccess: trailCloseAccess,
			trailOpenAccess: trailOpenAccess,
			trailBBAccess: trailBBAccess,
			trailLCAccess: trailLCAccess,
			sepTrailPresentAccess: sepTrailPresentAccess
		};
		// ω-trivia-sep: sep-Star Alt branches (e.g. `HxExpr.ArrayExpr`)
		// route to the dedicated sep helper. Block-style (no sep)
		// stays on the always-multi-line path.
		//
		// ω-arraylit-wraprules: forward `@:fmt(wrapRules('<field>'))`
		// from the enum-Case branch to the helper so the no-trivia
		// branch can defer layout to `WrapList.emit` (mirrors the
		// struct-Star path in `lowerStruct`). First Alt-branch
		// consumer is `HxExpr.ArrayExpr.elems` (`arrayLiteralWrap`).
		// ω-blockended-trivia (Session 3): enum-Alt mirror — when the
		// trivia-mode `@:sep+@:lead+@:trail` branch carries the
		// `blockEnded` flag (HxStatement.BlockStmt / HxExpr.BlockExpr
		// after Session 3 migration), skip the `triviaSepStarExpr`
		// flat-or-multi dispatch and fall through to the block-mode
		// dispatch with sepText/blockEnded threaded into
		// `triviaBlockStarExpr`.
		final altBlockEndedFlag: Bool = branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		return sepText != null && !altBlockEndedFlag
			? triviaSepStarBuild(ctx, c, slots)
			: triviaBlockStarBuild(ctx, c, slots, altBlockEndedFlag);
	}

	@:access(anyparse.macro.TriviaSepLowering)
	private static function triviaSepStarBuild(ctx: StarEmitCtx, c: EnumStarCtx, slots: TriviaAltSlots): Expr {
		final branch: ShapeNode = c.branch;
		final wrapRulesField: Null<String> = branch.fmtReadString('wrapRules');
		// ω-mapwrap: enum-Alt branch reader for `@:fmt(mapWrapRules('<field>'))`
		// (`HxExpr.ArrayExpr`) — a MAP literal goes to `wrapping.mapWrap`, every
		// other bracket list to `wrapping.arrayWrap`, mirroring the fork's
		// `arrayWrapping` split on `getBkOpenType == MapLiteral`. Null on every
		// other Star.
		final mapWrap: Null<SepStarMapWrap> = ctx.mapWrapFor(branch.fmtReadString('mapWrapRules'));
		// ω-arraylit-trailing-comma-dispatch: enum-Alt branches
		// (e.g. `HxExpr.ArrayExpr`) carry `@:fmt(trailingComma(
		// '<knob>'))` but the trivia-mode emit at this site
		// must thread the knob into `triviaSepStarExpr`'s
		// 13th/14th params (hardcoded `null, null` ignores it). Sister
		// dispatch-dual-path gap —
		// the struct-Star path at `lowerStruct`
		// already threads `trailingCommaField`. Companion sibling
		// `ω-arraylit-source-trail-comma` adds the 13th param's
		// counterpart via a synth-side positional `trailPresent:
		// Bool` slot (no `<field>TrailPresent` named struct field —
		// Alt ctors are positional, so synth pushes the slot under
		// the `isAltCloseTrailingBranch + @:lead + !@:tryparse +
		// @:sep` gate; writer binds it via `argNames[5]` as
		// `sepTrailPresentAccess` below). With both, the trivia-
		// sep helper's `appendTrailingCommaExpr` engages identically
		// to the struct-Star path: `trailPresent || knob`.
		final trailingCommaField: Null<String> = branch.fmtReadString('trailingComma');
		// ω-trivia-sep-anontype-braces (Phase B1): forward the
		// `anonTypeBracesOpen/Close` policy via
		// `delimInsidePolicySpace` so the trivia-mode emit honours
		// inside-brace whitespace exactly like the non-trivia
		// branch (line ~1257). Branches without the flag get null
		// → helper falls back to `_de()` (no spaces inside).
		// ω-bracket-config: `@:fmt(bracketKindPad)` (`HxExpr.ArrayExpr`)
		// supersedes the static `anonTypeBraces*` path — the inside-space
		// depends on the first element's bracket kind, decided at runtime
		// by the generated typed classifier. Both override Docs reference
		// `_arr[0].node` — an identifier BOUND by the block that
		// `triviaSepStarExpr` emits (unhygienic cross-function coupling,
		// same as every other `_arr`/`_docs` splice fed to it) — which is
		// safe everywhere they are spliced: the empty-`[]` form
		// short-circuits before any emit that uses them
		// (`_arr.length == 0` guard near the `triviaSepStarExpr` tail and
		// `WrapList.emit`'s own `items.length == 0` guard).
		final bracketKindPadAlt: Bool = branch.fmtHasFlag('bracketKindPad');
		final openInsideExpr: Null<Expr> = bracketKindPadAlt
			? arrayBracketInsidePolicySpace(ctx, macro _arr[0].node, false)
			: delimInsidePolicySpace(branch, ['anonTypeBracesOpen'], false);
		final closeInsideExpr: Null<Expr> = bracketKindPadAlt
			? arrayBracketInsidePolicySpace(ctx, macro _arr[0].node, true)
			: delimInsidePolicySpace(branch, ['anonTypeBracesClose'], true);
		// ω-trivia-sep-doc-comment-cascade (Phase B2): forward the
		// `beforeDocCommentEmptyLines` flag so sep-Stars opt into
		// the cascade (currently only `HxType.Anon.fields`).
		final beforeDocComments: Bool = branch.fmtHasFlag('beforeDocCommentEmptyLines');
		// ω-anontype-left-curly: forward `@:fmt(leftCurly('<knob>'))`
		// from the enum-Alt branch so `HxType.Anon` honours per-
		// construct `anonTypeLeftCurly`. When `Next`, the helper's
		// trivia branch prepends `_doh()` (OptHardline) before the
		// `{`, and the no-trivia branch feeds the same Doc into
		// `WrapList.emit`'s `(leadFlat=_de(), leadBreak=_doh())`
		// pair so the wrap engine's flat/break decision picks
		// cuddled vs Allman per the anon-type's measured shape.
		// Mirrors the struct-Star `lowerStruct` path at
		// `HxObjectLit.fields`.
		final knobLeftCurly: Null<String> = branch.fmtReadString('leftCurly');
		// ω-anontype-right-curly: call-form `@:fmt(rightCurly('<knob>'))`
		// names a per-construct `RightCurlyPlacement` opt field that
		// the trivia branch of `triviaSepStarExpr` reads. Currently
		// consumed by `HxType.Anon` for `anonTypeRightCurly`. Null
		// (no opt-in or bare flag) falls back to unconditional
		// `_dhl()` before close.
		final knobRightCurly: Null<String> = branch.fmtReadString('rightCurly');
		// ω-typedef-anon-force-multi: enum-Alt branch reader for
		// `@:fmt(forceMultiInTypedef)` on `HxType.Anon`. Threads the
		// flag into `triviaSepStarExpr` so the no-trivia branch
		// emits a runtime `opt._inTypedefBody ? WrapMode.OnePerLine
		// : null` as `WrapList.emit`'s `forceMode` option. Closes
		// the `issue_301` typedef-anon source-flat → fork-multi
		// shape gap by forcing OnePerLine when the parent
		// `HxTypedefDecl.type` Ref has flipped `_inTypedefBody=true`
		// via `propagateTypedefContext`. Non-typedef anon callers
		// (var-type-hint, fn-return-type) stay cascade-driven.
		final forceMultiTypedef: Bool = branch.fmtHasFlag('forceMultiInTypedef');
		final bodyAware: Bool = branch.fmtHasFlag('bodyAwareCompactIndent');
		// ω-group-rest-probe slice 2: enum-Alt branch reader for
		// `@:fmt(groupRestProbe)`. Trivia-path mirror of the plain-
		// path read at lowerStruct's Star dispatch. Dual-dispatch
		// per [[feedback-wraprules-dispatch-dual-path]].
		final groupRestProbe: Bool = branch.fmtHasFlag('groupRestProbe');
		// ω-cascade-emits-comments: enum-Alt branch reader for
		// `@:fmt(ignoreSourceNewlinesForWrap)` — intrinsic
		// per-construct opt-in to fork's `Ignore` policy
		// (drop source newline signal, inline cascade-emittable
		// trivia). Currently no enum-Alt consumer opts in;
		// reader present for symmetry with the struct-path
		// dual-dispatch.
		final ignoreSourceNewlines: Bool = branch.fmtHasFlag('ignoreSourceNewlinesForWrap');
		// ω-typedef-between-fields: enum-Alt branch reader for
		// `@:fmt(typedefBodyBlanks)` (currently `HxType.Anon`).
		// When set AND the descendant anon sees
		// `opt._inTypedefBody == true`, the force-multi branch in
		// `triviaSepStarExpr` injects `opt.typedefBeginType` blanks
		// after `{` and `opt.typedefBetweenFields` blanks between
		// adjacent fields. Inline anon-type uses never carry the
		// flag, staying byte-identical to pre-slice.
		final typedefBodyBlanksAlt: Bool = branch.fmtHasFlag('typedefBodyBlanks');
		// ω-array-reflow: enum-Alt branch reader for
		// `@:fmt(reflowSourceMultiline)` — opt-in for source-
		// multiline lists (currently `HxExpr.ArrayExpr`) re-flowed
		// by the wrap cascade instead of forced one-per-line.
		// Threads into `triviaSepStarExpr`'s `_smlKeep` gate.
		final reflowSourceMultilineAlt: Bool = branch.fmtHasFlag('reflowSourceMultiline');
		// ω-arraymatrix-wrap: enum-Alt branch reader for
		// `@:fmt(arrayMatrixWrap)` (`HxExpr.ArrayExpr`). Marks the
		// Star as matrix-eligible so `triviaSepStarExpr` attempts a
		// source-grid layout before the wrap cascade.
		final matrixWrapAlt: Bool = branch.fmtHasFlag('arrayMatrixWrap');
		// ω-value-yielded-if-tail-barrier (array-element expr-position):
		// `@:fmt(propagateExprPosition)` on the ArrayExpr ctor flags each
		// element as expression-position so a value-if array element stays
		// glued (`expressionIfBody`). False on every other enum-Alt sep-Star.
		final propagateExprPositionAlt: Bool = branch.fmtHasFlag('propagateExprPosition');
		// ω-multiline-trailing-comma-remove / ω-uniform-element-blanks: enum-Alt
		// branch readers for the two `HxExpr.ArrayExpr` opt-ins — the first lets
		// `wrapping.trailingComma = remove` drop the break-mode trailing `,`, the
		// second extends `emptyLines.uniformStatementBlanks` to element gaps.
		final trailingCommaRemovableAlt: Bool = branch.fmtHasFlag('trailingCommaRemovable');
		final uniformStmtBlanksAlt: Bool = branch.fmtHasFlag('uniformStmtBlanks');
		// ω-complex-item-count: enum-Alt branch reader for `@:fmt(complexItems)`
		// (`HxExpr.ArrayExpr`) — classify each element (call / `new`,
		// call-bearing container literal, neither) so the cascade can send an
		// array of constructor calls one-per-line on a SEMANTIC counter rather
		// than a width proxy (which would also mangle `case [A, _]` patterns).
		final complexItemsAlt: Bool = branch.fmtHasFlag('complexItems');
		return TriviaSepLowering.triviaSepStarExpr(
			c.argsAccess, slots.trailBBAccess, slots.trailLCAccess, slots.trailCloseAccess, slots.trailOpenAccess, c.elemFn, c.leadText,
			c.trailText, c.sepText, wrapRulesField, knobLeftCurly, knobRightCurly, slots.sepTrailPresentAccess, trailingCommaField,
			openInsideExpr, closeInsideExpr, beforeDocComments, forceMultiTypedef, bodyAware, groupRestProbe, ignoreSourceNewlines,
			reflowSourceMultilineAlt, matrixWrapAlt, null, typedefBodyBlanksAlt, propagateExprPositionAlt, false,
			trailingCommaRemovableAlt, uniformStmtBlanksAlt, complexItemsAlt, mapWrap
		);
	}

	@:access(anyparse.macro.TriviaBlockLowering)
	private static function triviaBlockStarBuild(ctx: StarEmitCtx, c: EnumStarCtx, slots: TriviaAltSlots, altBlockEndedFlag: Bool): Expr {
		final branch: ShapeNode = c.branch;
		final sepText: Null<String> = c.sepText;
		// ω-bropen-keep: forward `@:fmt(keepCurlyBlanks)` from the
		// enum-Case branch so non-type block bodies (BlockStmt,
		// BlockExpr) honour `opt.afterLeftCurly` /
		// `opt.beforeRightCurly` Keep policy. Sister to the
		// struct-Star path's read at the `lowerStruct` call site.
		final keepCurlyBlanks: Bool = branch.fmtHasFlag('keepCurlyBlanks');
		// ω-arrow-lambda-body-context: forward the override-meta
		// presence so the helper clears `_inAnonFnBody` for the
		// per-element write — see helper docstring for rationale.
		final anonFnClear: Bool = branch.fmtHasFlag('leftCurlyAnonFnOverride');
		// ω-blockempty: enum-Case branch may opt into empty-curly
		// break dispatch via `@:fmt(emptyCurlyBreak)` (bare or with
		// knob-name arg). Used by `HxStatement.BlockStmt` and
		// `HxExpr.BlockExpr` to route empty bodies through
		// `opt.blockEmptyCurly`.
		final emptyCurlyBreak: Bool = branch.fmtHasFlag('emptyCurlyBreak');
		final emptyCurlyKnobArgs: Null<Array<String>> = branch.fmtReadStringArgs('emptyCurlyBreak');
		final emptyCurlyKnob: Null<String> = emptyCurlyKnobArgs != null && emptyCurlyKnobArgs.length >= 1 ? emptyCurlyKnobArgs[0] : null;
		// ω-blockright-curly: call-form `@:fmt(rightCurly('<knob>'))`
		// names a per-construct RightCurlyPlacement opt field. The
		// bare form returns null and falls back to unconditional
		// `_dhl()` before close inside `triviaBlockStarExpr`.
		final rightCurlyKnobArgs: Null<Array<String>> = branch.fmtReadStringArgs('rightCurly');
		final rightCurlyKnob: Null<String> = rightCurlyKnobArgs != null && rightCurlyKnobArgs.length >= 1 ? rightCurlyKnobArgs[0] : null;
		// ω-anonfunction-right-curly: call-form
		// `@:fmt(rightCurlyAnonFnOverride('<knob>'))` names a
		// RightCurlyPlacement opt field that the dispatch reads
		// only when `_inAnonFnBody=true`. Sister to
		// `leftCurlyAnonFnOverride`. Pre-slice (no opt-in) falls
		// through to `_dhl()` for non-anon-fn contexts.
		final rightCurlyAnonFnArgs: Null<Array<String>> = branch.fmtReadStringArgs('rightCurlyAnonFnOverride');
		final rightCurlyAnonFnKnob: Null<String> = rightCurlyAnonFnArgs != null && rightCurlyAnonFnArgs.length >= 1
			? rightCurlyAnonFnArgs[0]
			: null;
		return TriviaBlockLowering.triviaBlockStarExpr(
			c.argsAccess, slots.trailBBAccess, slots.trailLCAccess, slots.trailCloseAccess, slots.trailOpenAccess, c.elemFn, c.leadText,
			c.trailText, true, false, false, false, null, false, emptyCurlyBreak, false, keepCurlyBlanks, false, false, null, false, null,
			anonFnClear, emptyCurlyKnob, rightCurlyKnob, rightCurlyAnonFnKnob, altBlockEndedFlag ? sepText : null, altBlockEndedFlag,
			altBlockEndedFlag ? (branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE]: Null<String>) : null,
			altBlockEndedFlag ? ctx.formatInfo.schemaTypePath : null, null, branch.fmtHasFlag('clearExprPositionNonTail'), 'beginType',
			'endType', branch.fmtHasFlag('uniformStmtBlanks')
		);
	}

	private static function lowerEnumStarPlain(ctx: StarEmitCtx, c: EnumStarCtx): Expr {
		final branch: ShapeNode = c.branch;
		final sepText: Null<String> = c.sepText;
		final argsAccess: Expr = c.argsAccess;
		final elemCall: Expr = c.elemCall;
		final leadText: String = c.leadText;
		final trailText: String = c.trailText;
		final starNode: ShapeNode = c.starNode;
		if (sepText != null && branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true) {
			// Block-ended exemption (Session 2 pilot — mirror of
			// `emitWriterStarField`). Suppress between-element sep
			// emission when EITHER:
			//   (a) the prior element's rendered Doc ends with `}` or `;`
			//       (`DocMeasure.endsWithStmtTerminator` — Session 8 widened
			//       from `endsWithCloseBrace` to include `;` so per-stmt
			//       `@:trail/@:trailOpt(';')` baked terminators suppress
			//       sep too), OR
			//   (b) the blockEnded predicate (generated typed for astPreds
			//       formats; schema-instance for pilots, e.g. `Atom('end')`
			//       in MiniBlockStrict) returns true on the prior element's
			//       AST (Session 7 option b2 — `HxStatement.Conditional(#if…#end)`
			//       whose byte-end `d` misses (a) but the predicate matches
			//       the AST shape).
			// Mirrors the struct-field plain-mode site at L3845-3880 and
			// the parser-side blockEnded branch in `StarFieldLowering.emitStarFieldSteps`
			// (`b == '}'.code || b == ';'.code || $predicateCall`).
			// Strictly opt-in via `@:sep('text', tailRelax, blockEnded[('pred'[, sepStartsElement])])`.
			final predicateName: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE];
			final predicateCheckPrior: Expr = blockEndedPredCheck(ctx, predicateName, macro _args[_i - 1]);
			return macro {
				final _args = $argsAccess;
				final _docs: Array<anyparse.core.Doc> = [_dt($v{leadText})];
				var _i: Int = 0;
				while (_i < _args.length) {
					final _elemDoc: anyparse.core.Doc = $elemCall;
					if (_i > 0) {
						final _priorDoc: anyparse.core.Doc = _docs[_docs.length - 1];
						final _priorEnds: Bool = anyparse.core.DocMeasure.endsWithSemi(_priorDoc) || $predicateCheckPrior;
						if (!_priorEnds) {
							_docs.push(_dt($v{sepText}));
							_docs.push(_dt(' '));
						}
					}
					_docs.push(_elemDoc);
					_i++;
				}
				_docs.push(_dt($v{trailText}));
				_dc(_docs);
			};
		}
		if (sepText == null) return macro {
			final _args = $argsAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			var _i: Int = 0;
			while (_i < _args.length) {
				_docs.push($elemCall);
				_i++;
			}
			blockBody($v{leadText}, $v{trailText}, _docs, opt);
		};
		// See `emitWriterStarField` — `@:sep('\n')` routes to a flat
		// hardline-join emission (format-neutral).
		if (sepText == '\n') {
			return macro {
				final _args = $argsAccess;
				final _docs: Array<anyparse.core.Doc> = [_dt($v{leadText})];
				var _i: Int = 0;
				while (_i < _args.length) {
					if (_i > 0) _docs.push(_dhl());
					_docs.push($elemCall);
					_i++;
				}
				_docs.push(_dt($v{trailText}));
				_dc(_docs);
			};
		}
		final tcExpr: Expr = trailingCommaExpr(branch);
		// ω-bracket-config: `@:fmt(bracketKindPad)` (`HxExpr.ArrayExpr`,
		// plain-mode `sepList` path) overrides the static anonTypeBraces
		// inside-space with a runtime dispatch on the first element's
		// bracket kind. Reads `_args[0]` (the plain `HxExpr` element,
		// bound just below at the `final _args = $argsAccess` site).
		// The generated classifier's own `case null` arm answers the
		// default `ArrayLiteral` for an empty `[]`'s `_args[0]` → `_de()`,
		// keeping empty brackets tight.
		final bracketKindPad: Bool = branch.fmtHasFlag('bracketKindPad');
		final openInsideExpr: Expr = bracketKindPad
			? arrayBracketInsidePolicySpace(ctx, macro _args[0], false)
			: (delimInsidePolicySpace(branch, ['anonTypeBracesOpen'], false) ?? macro _de());
		final closeInsideExpr: Expr = bracketKindPad
			? arrayBracketInsidePolicySpace(ctx, macro _args[0], true)
			: (delimInsidePolicySpace(branch, ['anonTypeBracesClose'], true) ?? macro _de());
		// ω-anontype-wraprules: forward `@:fmt(wrapRules('<field>'))`
		// to `WrapList.emit` for non-trivia-collecting Alt-Star
		// nodes only. `@:trivia`-annotated branches (e.g.
		// `HxExpr.ArrayExpr`) keep the renderer-driven `sepList`
		// path here — their wrapRules dispatch already runs
		// through `triviaSepStarExpr` in trivia mode, and
		// switching the plain-mode path to `WrapList.emit` would
		// lose renderer-driven flat/break for callers that rely
		// on `lineWidth`-based natural breaking (verified by
		// `HxTrailingCommaOptionsTest.testArrayTrailingCommaOnBreak`,
		// which uses plain-mode `HxModuleWriter`). Type-position
		// nodes (`HxType.Anon.fields`) don't carry trivia, so the
		// plain-path dispatch is their only wrapRules surface —
		// a `@:trivia` flip would synthesize unused machinery.
		final isTriviaCollecting: Bool = starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		final wrapRulesField: Null<String> = isTriviaCollecting ? null : branch.fmtReadString('wrapRules');
		final listCall: Expr = if (wrapRulesField != null) {
			final rulesExpr: Expr = optFieldAccess(wrapRulesField);
			macro anyparse.format.wrap.WrapList.emit(
				$v{leadText}, $v{trailText}, $v{sepText}, _docs, opt, $openInsideExpr, $closeInsideExpr, false, $rulesExpr,
				{ appendTrailingComma: $tcExpr }
			);
		} else {
			macro sepList(
				$v{leadText}, $v{trailText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, false,
				$v{branch.fmtHasFlag('cuddle')}
			);
		};
		return macro {
			final _args = $argsAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			var _i: Int = 0;
			while (_i < _args.length) {
				_docs.push($elemCall);
				_i++;
			}
			$listCall;
		};
	}

	/**
	 * ω-bracket-config: runtime-dispatched sibling of
	 * `delimInsidePolicySpace` for the `HxExpr.ArrayExpr` `[…]` Star,
	 * whose ONE ctor covers three fork bracket kinds (array-literal /
	 * map-literal / comprehension). The kind is decided at write time by
	 * the generated `arrayBracketKind(<first element>)` classifier (on
	 * the first element's enum ctor: `Arrow`→map, `ForExpr`/`WhileExpr`→
	 * comprehension, else array-literal). The resolved kind selects one of
	 * the three `{arrayLiteral|mapLiteral|comprehension}Brackets<Open|
	 * Close>` policy fields, then the same open→After/Both / close→Before/
	 * Both → `_dt(' ')` collapse as `delimInsidePolicySpace` produces the
	 * inside-space Doc.
	 *
	 * `firstAccess` is the runtime Expr reading the first Star element
	 * (`_arr[0].node` in trivia mode, `_args[0]` in plain mode — the
	 * bare element enum either way). Emitted as a block so the
	 * classifier runs once per side. Default `None` on every kind keeps
	 * the tight `[1]` / `[1 => "a"]` / `[for …]` byte-identical to the
	 * pre-slice layout. Empty `[]` never reaches this helper — both emit
	 * paths short-circuit `items.length == 0` before padding.
	 */
	private static function arrayBracketInsidePolicySpace(ctx: StarEmitCtx, firstAccess: Expr, isClose: Bool): Expr {
		final suffix: String = isClose ? 'Close' : 'Open';
		final mapField: Expr = optFieldAccess('mapLiteralBrackets$suffix');
		final comprField: Expr = optFieldAccess('comprehensionBrackets$suffix');
		final arrayField: Expr = optFieldAccess('arrayLiteralBrackets$suffix');
		final kindCases: Array<Case> = [
			{ values: [macro 1], expr: mapField, guard: null },
			{ values: [macro 2], expr: comprField, guard: null }
		];
		final policyExpr: Expr = { expr: ESwitch(macro _abk, kindCases, arrayField), pos: Context.currentPos() };
		final spaceSwitch: Expr = buildPolicySwitch(['anyparse', 'format', 'WhitespacePolicy'], macro _abp, [
			{ values: isClose ? ['Before', 'Both'] : ['After', 'Both'], expr: macro _dt(' ') }
		], macro _de());
		// The classifier is the generated typed predicate of this build's
		// AST family (`AstPreds.arrayBracketKind` plain, `AstPredsT.…`
		// trivia — see `AstPredLowering.predClassParts`); a grammar that
		// opts into `bracketKindPad` must provide the marker classes.
		// Kind 0 (ArrayLiteral) is the predicate's own null/other default,
		// so the `arrayLiteralBrackets` policy applies — its `None`
		// default keeps the tight `[1]` form.
		final predCall: Expr = AstPredLowering.predCallExpr(
			ctx.shape.root, ctx.ctx.trivia, false, WriterLowering.ARRAY_BRACKET_KIND_PRED, [firstAccess]
		);
		return macro {
			final _abk: Int = $predCall;
			final _abp: anyparse.format.WhitespacePolicy = $policyExpr;
			$spaceSwitch;
		};
	}

}

/**
 * The build state both Star forks read, bundled once per `WriterLowering`
 * instance.
 *
 * Wider than the two layer bundles because a Star emit is where the writer's
 * concerns meet: the shape table and the format info, the trivia gate, four
 * sibling bundles it hands straight through, and the naming helpers plus the
 * one Seq-walker gate (`buildKeepBlankAfterCtorGate`) it shares with
 * `lowerStruct`. The bundle IS the surface: a Star leaf that needs something
 * else has to widen this literal, which is one visible edit in that
 * constructor.
 */
typedef StarEmitCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final formatInfo: FormatReader.FormatInfo;
	final ctx: LoweringCtx;
	final ctorPat: WriterCtorPatternLowering.CtorPatternCtx;
	final fieldSep: WriterFieldSepLowering.FieldSepCtx;
	final braceSym: WriterBraceSymmetryLowering.BraceSymmetryCtx;
	final ctorBlank: WriterCtorBlankLowering.CtorBlankCtx;
	final triviaStar: WriterTriviaStarDispatch.TriviaStarDispatchCtx;
	final buildKeepBlankAfterCtorGate: (child:ShapeNode, node:ShapeNode, typePath:String) -> Null<Expr>;
	final isSpacedLead: (openText:Null<String>) -> Bool;
	final isTriviaBearing: (refName:String) -> Bool;
	final mapWrapFor: (field:Null<String>) -> Null<SepStarMapWrap>;
	final ruleCtorPath: (typePath:String, ctor:String) -> Array<String>;
	final writeFnFor: (refName:String) -> String;
}
#end
