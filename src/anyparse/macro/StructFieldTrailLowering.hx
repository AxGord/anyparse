package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.TriviaSlotNames.*;

using anyparse.macro.MetaInspect;

/**
 * Pass 3 — what surrounds ONE struct field.
 *
 * One question asked per field of a Seq typedef, in the order the
 * generated parser meets the answers: is this field's metadata
 * combination legal at all (`validateStructField` and its `@:absentOn`
 * half), which trivia sidecar locals does it need pre-declared, what
 * whitespace or trivia is consumed BEFORE it, what mandatory lead-in
 * (`@:kw` / `@:lead`) opens it, and what trailing literal closes it.
 *
 * Every member here takes the field and its already-computed flags as
 * arguments and appends to a `parseSteps` array — none reads the shape
 * tree, the format info or the build's `LoweringCtx`, which is what let
 * the whole family leave. The decisions those inputs encode
 * (`computeStructFieldFlags`, `computeBeforeSlots`, `lowerStruct`'s own
 * walk) stay in `Lowering`.
 *
 * Every member is static and `Lowering` reaches them unqualified through
 * `import anyparse.macro.StructFieldTrailLowering.*;` plus a class-level
 * `@:access`, so the move rewrote no call site.
 */
@:access(anyparse.macro.TriviaSlotNames)
final class StructFieldTrailLowering {

	/**
	 * Compile-time validation of a struct field's metadata-combination
	 * legality (`@:optional` / `@:kw` / `@:lead` / `@:trail` / `@:absentOn` /
	 * `@:absentOnEof`).
	 * Each illegal combination halts the build via `Context.fatalError`.
	 * Pure — no emit, no `ctx`; lifted out of `lowerStruct`'s per-field loop.
	 */
	private static function validateStructField(
		child: ShapeNode, fieldName: Null<String>, isOptional: Bool, isStar: Bool, kwLead: Null<String>, leadText: Null<String>,
		trailText: Null<String>, absentOnLits: Null<Array<String>>, absentOnEof: Bool
	): Void {
		if (isOptional && child.kind != Ref && child.kind != Star) {
			Context.fatalError(
				'Lowering: @:optional is only supported on Ref- or Star-shaped struct fields (field "$fieldName")', Context.currentPos()
			);
		}
		if (isOptional && !isStar && trailText != null && kwLead != null) {
			// `@:trail` on an optional kw-led Ref has no consumer yet
			// (the kw-led trivia capture path threads `_afterKw_*` /
			// `_kwLeading_*` slots whose layout assumes no per-field
			// trail). Defer until a grammar needs it; the lead-led
			// shape (`@:optional @:lead('(') @:trail(')')`) is
			// supported below — first consumer `@:coreType`
			// bare abstract via `HxAbstractDecl.underlyingType`.
			Context.fatalError('Lowering: @:optional @:kw combined with @:trail is deferred (field "$fieldName")', Context.currentPos());
		}
		if (absentOnLits != null || absentOnEof)
			validateAbsenceDispatch(child, fieldName, isOptional, kwLead, leadText, trailText, absentOnLits, absentOnEof);
		if (isStar && isOptional && kwLead == null && (leadText == null || trailText == null)) {
			Context.fatalError(
				'Lowering: @:optional Star field "$fieldName'
				+ '" requires either @:kw (tryparse mode) or both @:lead and @:trail (angle-bracket mode)',
				Context.currentPos()
			);
		}
	}

	/**
	 * The `@:absentOn` / `@:absentOnEof` half of `validateStructField`: one
	 * peek-ahead absence dispatch, so the two metas share every legality rule.
	 * Neither CONSUMES anything (the listed terminators belong to the enclosing
	 * context, and EOF is not a token at all). Combined with `@:lead` / `@:kw` the
	 * commit point would be ambiguous — which one decides absence? — and combined
	 * with `@:trail` it inherits the same "trail inside peek" gap as a plain
	 * `@:optional`; both are rejected. The field must be an optional Ref: a Star
	 * has its own commit semantics through `@:lead` / `@:trail` and absence
	 * dispatch adds nothing there. Split out of the caller because folding the EOF
	 * disjunct into every arm pushed that function past the complexity gate.
	 */
	private static function validateAbsenceDispatch(
		child: ShapeNode, fieldName: Null<String>, isOptional: Bool, kwLead: Null<String>, leadText: Null<String>, trailText: Null<String>,
		absentOnLits: Null<Array<String>>, absentOnEof: Bool
	): Void {
		if (!isOptional || child.kind != Ref) {
			Context.fatalError('Lowering: @:absentOn / @:absentOnEof requires @:optional Ref (field "$fieldName")', Context.currentPos());
		}
		if (kwLead != null || leadText != null) {
			Context.fatalError(
				'Lowering: @:absentOn / @:absentOnEof cannot combine with @:lead or @:kw (field "$fieldName")', Context.currentPos()
			);
		}
		if (trailText != null) {
			Context.fatalError(
				'Lowering: @:absentOn / @:absentOnEof cannot combine with @:trail (field "$fieldName")', Context.currentPos()
			);
		}
		if (!absentOnEof && (absentOnLits == null || absentOnLits.length == 0)) {
			Context.fatalError('Lowering: @:absentOn requires at least one terminator literal (field "$fieldName")', Context.currentPos());
		}
	}

	/**
	 * Pre-declare the six `@:optional @:kw(...)` trivia sidecar locals
	 * (`_afterKw_*` / `_kwLeading_*` / `_beforeKwNl_*` / `_bodyOnSameLine_*` /
	 * `_beforeKwLeading_*` / `_beforeKwTrailing_*`) that the optional-Ref /
	 * optional-kw-Star commit path assigns into. Pushes one `EVars` per local.
	 * Pure — lifted from `lowerStruct`'s per-field loop.
	 */
	private static function emitKwTriviaSlotDecls(
		afterKwLocal: String, kwLeadingLocal: String, beforeKwNlLocal: String, bodyOnSameLineLocal: String, beforeKwLeadingLocal: String,
		beforeKwTrailingLocal: String, parseSteps: Array<Expr>
	): Void {
		inline function pushVar(name: String, type: ComplexType, init: Expr): Void {
			parseSteps.push({
				expr: EVars([
					{
						name: name,
						type: type,
						expr: init,
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
		}
		pushVar(afterKwLocal, macro :Null<String>, macro null);
		pushVar(kwLeadingLocal, macro :Array<String>, macro []);
		pushVar(beforeKwNlLocal, macro :Bool, macro false);
		pushVar(bodyOnSameLineLocal, macro :Bool, macro false);
		pushVar(beforeKwLeadingLocal, macro :Array<String>, macro []);
		pushVar(beforeKwTrailingLocal, macro :Null<String>, macro null);
	}

	/**
	 * Emit the post-switch per-field trailing-literal steps for a non-Star,
	 * non-optional Ref field: the mandatory `@:trail` close (+ trivia
	 * `<field>AfterTrail` same-line-comment capture) and/or the `@:trailOpt`
	 * peek-consume-rewind close (+ `_trailPresent_<field>` capture). Both are
	 * gated `!isStar && !isOptional`; `trailText` drives the required path,
	 * `trailOptText` the optional path. Pure — lifted from `lowerStruct`.
	 */
	private static function emitFieldTrail(
		parseSteps: Array<Expr>, isStar: Bool, isOptional: Bool, trailText: Null<String>, hasAfterTrailSlot: Bool, afterTrailLocal: String,
		trailOptText: Null<String>, captureTrailPresentExpr: Expr, hasBeforeTrailSlot: Bool, beforeTrailLocal: String
	): Void {
		// @:fmt(captureTrailComment) Star: the trail literal (e.g. `:`) is
		// already consumed by `emitStarFieldSteps`, so capture the same-line
		// trailing comment here into the same `<field>AfterTrail` slot the next
		// sibling's writer reads. `collectTrailingFull` keeps the delimiters so
		// block and line styles both round-trip verbatim.
		if (isStar && !isOptional && trailText != null && hasAfterTrailSlot) {
			parseSteps.push({
				expr: EVars([
					{
						name: afterTrailLocal,
						type: macro :Null<String>,
						expr: macro collectTrailingFull(ctx),
						isFinal: true
					}
				]),
				pos: Context.currentPos()
			});
		}
		if (!isStar && !isOptional && trailText != null) {
			// ω-before-trail: capture a BLOCK comment sitting between the field's
			// last token and the trail literal, BEFORE `skipWs` swallows it as
			// whitespace. `collectTrailingBlock` never attempts the format's
			// line-terminated patterns, so a `// c` in that gap is left exactly
			// where it was — re-emitting one before the close literal would
			// comment the literal out.
			if (hasBeforeTrailSlot) {
				parseSteps.push({
					expr: EVars([
						{
							name: beforeTrailLocal,
							type: macro :Null<String>,
							expr: macro collectTrailingBlock(ctx),
							isFinal: true
						}
					]),
					pos: Context.currentPos()
				});
			}
			parseSteps.push(macro skipWs(ctx));
			parseSteps.push(macro expectLit(ctx, $v{trailText}));
			// ω-trivia-after-trail: in trivia-bearing rules, capture a
			// same-line `// comment` after the trail literal into a
			// sidecar local — pushed to the synth pair as
			// `<field>AfterTrail:Null<String>` for the next sibling's
			// `bodyPolicyWrap` to thread before its body emission.
			// `collectTrailing` returns null when no same-line comment
			// is present and does not consume any whitespace beyond
			// the optional space + `//<body>` match.
			if (hasAfterTrailSlot) {
				parseSteps.push({
					expr: EVars([
						{
							name: afterTrailLocal,
							type: macro :Null<String>,
							expr: macro collectTrailingFull(ctx),
							isFinal: true
						}
					]),
					pos: Context.currentPos()
				});
			}
		}
		if (!isStar && !isOptional && trailOptText != null) {
			// ω-trailopt-rewind-on-miss-struct (BlockBody Star Session 5):
			// trail-absence must REWIND pos to pre-trivia so trivia stays
			// observable to the next field/Star. Bare `skipWs(ctx)` (the
			// pre-Session-5 form) silently advances past whitespace and
			// comments even when the optional trail literal is absent —
			// breaking BOTH trivia-mode round-trip (statement-context
			// hosts where the field-level `@:trailOpt(';')` sits between
			// two statement siblings — HxIfStmt.thenBody / .elseBody /
			// HxWhileStmt.body / HxForStmt.body / HxDoWhileStmt.body
			// added in Session 5 Step 1) AND plain-mode block-ended Star
			// detection (the close-peek Star at L2796-2833 reads
			// `ctx.input.charCodeAt(_prevEndPos - 1) == '}'.code` to
			// decide if sep is exempt; if `skipWs` advanced `_prevEndPos`
			// past the closing `}` to the next token, the check reads a
			// space instead of `}` and the exemption misses). The
			// optional-kw pattern at L2296 uses the same `ctx.pos = _wsPos`
			// rewind on miss — this mirrors it for optional-trail. On
			// `;` hit: advance past it normally. On miss: rewind pos so
			// the preceding trivia is re-observable. Applied in BOTH
			// modes — plain mode also benefits (downstream block-ended
			// Star checks need pre-trivia pos). Existing expression-
			// context consumers (HxIfExpr.thenBranch, HxConditionalType.type,
			// HxConditionalTypeElse.type, HxTryCatchExpr.body,
			// HxFnBody.ExprBody) see no observable change — their
			// downstream parsers re-scan the same trivia via their own
			// skipWs / collectTrivia.
			//
			// ω-struct-trailopt-source-track (Session 14 Phase 3): when
			// the field's paired-T type carries a synth
			// `<field>TrailPresent:Null<Bool>` slot, capture `matchLit`'s
			// hit into `_trailPresent_<field>` for the writer (Phase 4
			// will read it). Pre-declared `false` above so the miss
			// branch leaves the local untouched. `captureTrailPresentExpr`
			// is the shared splice — disjoint from the optional-Ref arm
			// which feeds the same Expr into a different subCall body.
			parseSteps.push(macro {
				final _trailOptWsPos: Int = ctx.pos;
				skipWs(ctx);
				if (matchLit(ctx, $v{trailOptText}))
					$captureTrailPresentExpr;
				else
					ctx.pos = _trailOptWsPos;
			});
		}
	}

	/**
	 * Emit the pre-field whitespace / trivia handling for one struct field
	 * (skipped for the optional-Ref / optional-kw-Star / EOF-Star / optional-
	 * Star-with-lead paths that own their own ws). Three modes: capture
	 * `collectTrivia` into BeforeLeading+BeforeNewline slots, or just
	 * BeforeNewline, or a plain `skipWs`. Then, for an opted-in condWrap cond
	 * field, probe the `(`→cond newline gap into the CondOpenNewline slot.
	 * Pure — lifted from `lowerStruct`'s per-field loop.
	 */
	private static function emitPreFieldWs(
		parseSteps: Array<Expr>, triviaEofStar: Bool, isOptionalRef: Bool, isOptionalKwStar: Bool, optStarWithLead: Bool,
		hasBeforeLeadingSlot: Bool, hasBeforeNewlineSlot: Bool, beforeNlLocal: String, beforeLeadingLocal: String,
		hasCondOpenNewlineSlot: Bool, condOpenNewlineLocal: String, beforeBlankLocal: Null<String>
	): Void {
		if (!triviaEofStar && !isOptionalRef && !isOptionalKwStar && !optStarWithLead) {
			if (hasBeforeLeadingSlot) {
				// ω-598-member-leading-comment: capture the full
				// `collectTrivia` result once, then split into the
				// `newlineBefore` bool (BeforeNewline slot) and the
				// verbatim `leadingComments` array (BeforeLeading slot).
				// The array holds a comment dropped in the gap between the
				// last modifier and the member keyword; emitted by the
				// writer's bare-Ref non-first separator. Empty in the
				// common case (no inter-modifier comment) → byte-inert.
				final arrayStrCT: ComplexType = TPath({
					pack: [],
					name: 'Array',
					params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
				});
				parseSteps.push(macro final _beforeTrivia = collectTrivia(ctx));
				parseSteps.push({
					expr: EVars([
						{
							name: beforeNlLocal,
							type: macro :Bool,
							expr: macro _beforeTrivia.newlineBefore,
							isFinal: true
						}
					]),
					pos: Context.currentPos()
				});
				parseSteps.push({
					expr: EVars([
						{
							name: beforeLeadingLocal,
							type: arrayStrCT,
							expr: macro _beforeTrivia.leadingComments,
							isFinal: true
						}
					]),
					pos: Context.currentPos()
				});
				// ω-region-prefix-blank: third split of the SAME scan — whether
				// the gap held a blank line, which `newlineBefore` cannot say.
				// Null local = the field did not opt in, and no slot exists to
				// write it onto.
				if (beforeBlankLocal != null) parseSteps.push({
					expr: EVars([
						{
							name: beforeBlankLocal,
							type: macro :Bool,
							expr: macro _beforeTrivia.blankBefore,
							isFinal: true
						}
					]),
					pos: Context.currentPos()
				});
			} else if (hasBeforeNewlineSlot) {
				// Route through `collectTrivia` — drains any
				// `pendingTrivia` stash from a preceding empty
				// bare-tryparse Star and captures `newlineBefore` into
				// the local that the struct literal writes onto the
				// synth slot. `skipWs` would silently discard both.
				parseSteps.push({
					expr: EVars([
						{
							name: beforeNlLocal,
							type: macro :Bool,
							expr: macro collectTrivia(ctx).newlineBefore,
							isFinal: true
						}
					]),
					pos: Context.currentPos()
				});
			} else
				parseSteps.push(macro skipWs(ctx));
		}
		// ω-condition-wrap-keep: the pre-field `skipWs` above advanced
		// `ctx.pos` to the cond's first token, so `hasNewlineIn` over
		// `[_condLeadEnd, ctx.pos)` answers "did the source break right
		// after `(`?". Captured into the local that the struct literal
		// writes onto the `<field>CondOpenNewline:Bool` synth slot. Runs
		// only for the opted-in condWrap cond field; `_condLeadEnd` was
		// declared right after the lead `expectLit` above.
		if (hasCondOpenNewlineSlot) parseSteps.push({
			expr: EVars([
				{
					name: condOpenNewlineLocal,
					type: macro :Bool,
					expr: macro hasNewlineIn(ctx.input, _condLeadEnd, ctx.pos),
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

	/**
	 * Emit the mandatory per-field lead-in for a non-Star, non-optional field:
	 * the `@:kw` keyword (`skipWs` + `expectKw`) and/or the `@:lead` literal
	 * (`skipWs` + `expectLit`), in that order (D50). For an opted-in condWrap
	 * cond field, also record `_condLeadEnd` right after the lead so the
	 * `(`→cond newline probe in emitPreFieldWs spans the correct gap. Pure —
	 * lifted from `lowerStruct`.
	 */
	private static function emitFieldLeadIn(
		parseSteps: Array<Expr>, isStar: Bool, isOptional: Bool, kwLead: Null<String>, leadText: Null<String>, hasCondOpenNewlineSlot: Bool
	): Void {
		if (isStar || isOptional) return;
		if (kwLead != null) {
			parseSteps.push(macro skipWs(ctx));
			parseSteps.push(macro expectKw(ctx, $v{kwLead}));
		}
		if (leadText == null) return;
		parseSteps.push(macro skipWs(ctx));
		parseSteps.push(macro expectLit(ctx, $v{leadText}));
		// ω-condition-wrap-keep: record the byte position right
		// after the open paren (BEFORE the pre-field `skipWs` below)
		// so the `hasNewlineIn` probe spans exactly the `(`→cond gap.
		if (hasCondOpenNewlineSlot) parseSteps.push(macro final _condLeadEnd: Int = ctx.pos);
	}

	/**
	 * Push the trivia-Star sidecar slots (`<field>TrailingBlankBefore` /
	 * `TrailingNewlineBefore` / `TrailingLeading` / `TrailingClose` /
	 * `TrailingOpen` / `TrailingBlankAfter` / `TrailPresent`) onto the struct
	 * literal for a `@:trivia`-collecting Star field. Each slot is gated on the
	 * same annotation that `TriviaTypeSynth` uses to grow it, so the field set
	 * matches the synth-define exactly. Pure — lifted from `lowerStruct`'s
	 * per-field loop.
	 */
	private static function pushTrailingStarSlots(
		child: ShapeNode, localName: String, fieldName: Null<String>, structFields: Array<ObjectField>
	): Void {
		final trailBBLocal: String = trailingBlankBeforeLocalName(localName);
		final trailNLLocal: String = trailingNewlineBeforeLocalName(localName);
		final trailLCLocal: String = trailingLeadingLocalName(localName);
		structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_BLANK_BEFORE_SUFFIX, expr: macro $i{trailBBLocal} });
		// ω-keep-fnsig-newline: sibling close-newline push, unconditional
		// next to TrailingBlankBefore so the struct-literal field set
		// matches the synth-define exactly.
		structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_NEWLINE_BEFORE_SUFFIX, expr: macro $i{trailNLLocal} });
		structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX, expr: macro $i{trailLCLocal} });
		// ω-close-trailing: the synth slot exists only for close-peek
		// Stars (see `TriviaTypeSynth.buildStarTrailingSlots`). Gate
		// the push on the Star's own `lit.trailText` annotation so
		// EOF-mode Stars (e.g. `HxModule.decls`) skip the field.
		if (child.annotations[AnnotationKeys.LIT_TRAIL_TEXT] != null) {
			final trailCloseLocal: String = trailingCloseLocalName(localName);
			structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_CLOSE_SUFFIX, expr: macro $i{trailCloseLocal} });
		}
		// ω-open-trailing: synth slot exists only for Stars with
		// `@:lead` AND not `@:tryparse` (the tryparse writer helper
		// does not consume the slot — see TriviaTypeSynth gate +
		// `emitTriviaStarFieldSteps`'s open-text capture gate).
		if (child.annotations[AnnotationKeys.LIT_LEAD_TEXT] != null && !child.hasMeta(':tryparse')) {
			final trailOpenLocal: String = trailingOpenLocalName(localName);
			structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_OPEN_SUFFIX, expr: macro $i{trailOpenLocal} });
		}
		// ω-trail-blank-after: synth slot exists only for `@:tryparse +
		// @:fmt(nestBody)` Stars (see TriviaTypeSynth gate). Gate the
		// push the same way; emitTriviaStarFieldSteps's tryparse+nestBody
		// branch is the sole producer of `trailBALocal`.
		if (child.hasMeta(':tryparse') && child.fmtHasFlag('nestBody')) {
			final trailBALocal: String = trailingBlankAfterLocalName(localName);
			structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_BLANK_AFTER_SUFFIX, expr: macro $i{trailBALocal} });
		}
		// ω-objectlit-source-trail-comma: synth slot exists only for
		// sep-Stars with a close literal (see TriviaTypeSynth gate).
		// Both `lit.sepText` and `lit.trailText` are populated by the
		// Lit strategy before Lowering runs, so reading from
		// annotations here mirrors the close-trailing / open-trailing
		// gates above.
		if (child.annotations[AnnotationKeys.LIT_SEP_TEXT] == null || child.annotations[AnnotationKeys.LIT_TRAIL_TEXT] == null) return;
		final trailPresentLocal: String = trailPresentLocalName(localName);
		structFields.push({ field: fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX, expr: macro $i{trailPresentLocal} });
	}

	/**
	 * The `collectTrivia` run an `@:absentOn` field opted into `@:fmt(bareRefSepWhenPresent)`
	 * performs BEFORE its absence peek, split into the two locals the struct literal writes onto
	 * the `<field>BeforeNewline` / `<field>BeforeLeading` synth slots. Same split as
	 * `emitPreFieldWs`'s mandatory bare-Ref arm, which this field bypasses.
	 */
	private static function emitAbsentOnBeforeSlots(fieldName: String, parseSteps: Array<Expr>, hasBeforeBlankSlot: Bool): Void {
		final arrayStrCT: ComplexType = TPath({
			pack: [],
			name: 'Array',
			params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
		});
		parseSteps.push(macro final _absentWsPos: Int = ctx.pos);
		// The stash a PRECEDING empty bare-tryparse Star left behind lives in bytes
		// BEFORE `_absentWsPos`, so rewinding cannot make it re-scannable — it has to
		// be handed back verbatim on the absent branch. Snapshotted before
		// `collectTrivia` drains it. Same shape as the try-parse loop's `_savedPending`.
		parseSteps.push(macro final _absentPending = ctx.pendingTrivia);
		parseSteps.push(macro final _absentTrivia = collectTrivia(ctx));
		parseSteps.push({
			expr: EVars([
				{
					name: beforeNewlineLocalName(fieldName),
					type: macro :Bool,
					expr: macro _absentTrivia.newlineBefore,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
		parseSteps.push({
			expr: EVars([
				{
					name: beforeLeadingLocalName(fieldName),
					type: arrayStrCT,
					expr: macro _absentTrivia.leadingComments,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
		// ω-region-prefix-blank: same third split as the mandatory arm in
		// `emitPreFieldWs` — the absent branch rewinds past this trivia, but the
		// PRESENT branch's writer still needs to know the gap held a blank.
		if (hasBeforeBlankSlot) parseSteps.push({
			expr: EVars([
				{
					name: beforeBlankLocalName(fieldName),
					type: macro :Bool,
					expr: macro _absentTrivia.blankBefore,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

}
#end
