package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLowering.PrevBodyInfo;
import anyparse.macro.WriterLowering.StarFieldArgs;
import anyparse.macro.WriterLowering.TriviaStarCtx;
import anyparse.macro.WriterLoweringSupport.*;
import haxe.macro.Context;
import haxe.macro.Expr;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W — which synthesized trivia slot a field reads, and what accessor
 * expression reaches it.
 *
 * `TriviaTypeSynth` grows a paired `*T` type with one extra field per
 * captured-trivia slot, and the writer's job at each site is the same
 * question in three shapes: WHICH slot exists for this field, and what
 * `EField(macro value, …)` reaches it. `buildTriviaStarCtx` answers it for
 * a Star's seven trailing slots, each gated on the very condition
 * `TriviaTypeSynth` gates the slot's synthesis on — a mismatch there is an
 * access to a field that does not exist. `collectFollowingNewlineSignals`
 * answers it for the boundary AFTER a field: it walks the later siblings
 * until one can carry the newline signal and returns the guard/signal pairs
 * in that order. `buildBeforeLeadingSep` answers it for the `BeforeLeading`
 * comment run a bare non-first `Ref` carries.
 *
 * All three are pure functions of the shape node and the caller's
 * accessors — they build `Expr`s, they do not consult the build state.
 */
@:access(anyparse.macro.WriterLoweringSupport)
final class WriterTriviaSlotLowering {

	/**
	 * `@:trivia` Star dispatch (the whole `if (isTriviaStar)` block of
	 * `emitWriterStarField`). Validates the trivia sep/raw/tryparse combinations,
	 * builds the trailing-slot accessors + `TriviaStarCtx`, then routes to the
	 * tryparse / close / EOF trivia emit helper. Extracted to keep the orchestrator
	 * under the complexity gate.
	 * Builds the trailing-slot accessors + the `TriviaStarCtx` for a `@:trivia`
	 * Star, from the resolved `StarFieldArgs`.
	 */
	private static function buildTriviaStarCtx(args: StarFieldArgs): TriviaStarCtx {
		final starNode: ShapeNode = args.starNode;
		final fieldAccess: Expr = args.fieldAccess;
		final elemFn: String = args.elemFn;
		final elemRefName: String = args.elemRefName;
		final isFirstField: Bool = args.isFirstField;
		final isLastField: Bool = args.isLastField;
		final typePath: String = args.typePath;
		final openText: Null<String> = args.openText;
		final closeText: Null<String> = args.closeText;
		final sepText: Null<String> = args.sepText;
		final prevBareRefBody: Null<PrevBodyInfo> = args.prevBareRefBody;
		final prevTrailFieldName: Null<String> = args.prevTrailFieldName;
		final fieldName: Null<String> = starNode.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final trailBBAccess: Null<Expr> = fieldName == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_BLANK_BEFORE_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-keep-fnsig-newline: accessor for the close-newline slot, threaded
		// into `triviaSepStarExpr` for the `_keepEmit` close placement.
		final trailNLAccess: Null<Expr> = fieldName == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_NEWLINE_BEFORE_SUFFIX),
			pos: Context.currentPos()
		};
		final trailLCAccess: Null<Expr> = fieldName == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX),
			pos: Context.currentPos()
		};
		final trailCloseAccess: Null<Expr> = fieldName == null || closeText == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_CLOSE_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-open-trailing: same-line `// comment` captured right after
		// the open literal. Synthesised only when the Star carries
		// `@:lead` AND not `@:tryparse` (parallel to TrailingClose's
		// `@:trail` gate; tryparse writer helper does not consume the
		// slot, and the synth gate omits it for tryparse Stars — see
		// `TriviaTypeSynth.buildStarTrailingSlots`).
		final trailOpenAccess: Null<Expr> = fieldName == null || openText == null || starNode.hasMeta(':tryparse') ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_OPEN_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-trail-blank-after: synth slot is only present on tryparse +
		// nestBody Stars. Forward null elsewhere so the slot access
		// doesn't reference a non-existent field.
		final trailBAAccess: Null<Expr> =
			fieldName == null || !starNode.hasMeta(':tryparse') || !starNode.fmtHasFlag('nestBody') ? null : {
				expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_BLANK_AFTER_SUFFIX),
				pos: Context.currentPos()
			};
		// ω-objectlit-source-trail-comma: synth slot is only present on
		// sep-Stars with a close literal. Forward null elsewhere so the
		// slot access doesn't reference a non-existent field. Mirrors
		// the `@:trail` / `@:sep` parser-side gate in TriviaTypeSynth.
		final trailPresentAccess: Null<Expr> = fieldName == null || sepText == null || closeText == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX),
			pos: Context.currentPos()
		};
		return {
			starNode: starNode,
			fieldAccess: fieldAccess,
			elemFn: elemFn,
			elemRefName: elemRefName,
			isFirstField: isFirstField,
			isLastField: isLastField,
			typePath: typePath,
			openText: openText,
			closeText: closeText,
			sepText: sepText,
			prevBareRefBody: prevBareRefBody,
			prevTrailFieldName: prevTrailFieldName,
			fieldName: fieldName,
			trailBBAccess: trailBBAccess,
			trailNLAccess: trailNLAccess,
			trailLCAccess: trailLCAccess,
			trailCloseAccess: trailCloseAccess,
			trailOpenAccess: trailOpenAccess,
			trailBAAccess: trailBAAccess,
			trailPresentAccess: trailPresentAccess
		};
	}

	/**
	 * ω-cond-comp-expr-multiline — walk the children of `parent`
	 * that follow `child`, collecting one `(guard, signal)` pair
	 * per downstream field whose presence is runtime-guarded AND
	 * whose leading-newline source-shape was captured by the
	 * trivia parser. Stops at the first mandatory non-transparent
	 * field — that field always emits visible content, so any
	 * further signal is irrelevant to `child`'s pad-emit site.
	 *
	 * Slot precedence (matches `TriviaTypeSynth`): a field that
	 * is BOTH `@:trivia` Star AND optional-kw routes through the
	 * opt-kw branch — `BeforeKwNewline` describes the kw-position
	 * newline (the boundary `child`'s pad is closing), while the
	 * Star's first-element `newlineBefore` describes a post-kw
	 * boundary one layer deeper.
	 *
	 * Optional fields (Ref or Star) without `@:kw` and without
	 * `@:trivia` carry no captured-newline slot — they're walked
	 * past as "transparent if absent" but contribute no entry; a
	 * downstream signal-bearing field still gets to win when the
	 * intervening transparent field is empty/absent at runtime.
	 */
	private static function collectFollowingNewlineSignals(parent: ShapeNode, child: ShapeNode): Array<{ guard: Expr, signal: Expr }> {
		final out: Array<{ guard: Expr, signal: Expr }> = [];
		final startIdx: Int = parent.children.indexOf(child);
		if (startIdx < 0) return out;
		for (i in (startIdx + 1) ... parent.children.length) {
			final next: ShapeNode = parent.children[i];
			final nextFieldName: Null<String> = next.annotations[AnnotationKeys.BASE_FIELD_NAME];
			if (nextFieldName == null) continue;
			final nextAccess: Expr = { expr: EField(macro value, nextFieldName), pos: Context.currentPos() };
			final isOptional: Bool = next.annotations[AnnotationKeys.BASE_OPTIONAL] == true;
			final isOptKw: Bool = (next.kind == Ref || next.kind == Star) && isOptional && next.readMetaString(':kw') != null;
			if (isOptKw) {
				final slotAccess: Expr = {
					expr: EField(macro value, nextFieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX),
					pos: Context.currentPos()
				};
				out.push({ guard: macro $nextAccess != null, signal: slotAccess });
				continue;
			}
			final isTriviaStar: Bool = next.kind == Star && next.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
			if (isTriviaStar) {
				final firstNl: Expr = macro $nextAccess[0].newlineBefore;
				final guard: Expr = isOptional ? macro $nextAccess != null && $nextAccess.length > 0 : macro $nextAccess.length > 0;
				out.push({ guard: guard, signal: firstNl });
				continue;
			}
			// Non-signal field. Optional/transparent kinds without a
			// captured-newline slot fall through to the next iteration —
			// when absent at runtime they contribute no signal, when
			// present they emit visible content and the boundary is
			// theirs (a downstream signal would describe a different
			// boundary). Mandatory non-transparent fields stop the walk
			// outright.
			if (!isOptional && next.kind != Star) break;
		}
		// ω-cond-comp-expr-multiline (sub-slice 5): terminal-fallback
		// signal on `child` itself when opted in via
		// `@:fmt(captureSourceNewlineAfter)`. The signal describes the
		// newline AFTER `child`'s last token — used when every preceding
		// downstream signal is absent at runtime (Star empty + optional
		// Refs all null), i.e. when the boundary is `child → parent
		// trail-literal`. Always-on guard (`macro true`) — a runtime
		// ternary `g₀ ? s₀ : (g₁ ? s₁ : … (true ? s_n : false))`
		// folds to `(present ? signal : … : s_n)`, so this entry is
		// the chain's tail and only fires when no earlier guard
		// matched a present downstream field.
		final childFieldName: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		if (childFieldName != null && child.kind == Ref && child.fmtHasFlag('captureSourceNewlineAfter')) {
			final terminalSlot: Expr = {
				expr: EField(macro value, childFieldName + TriviaTypeSynth.NEWLINE_AFTER_SUFFIX),
				pos: Context.currentPos()
			};
			// Always-on guard. For an optional `child` the slot stores
			// whatever `collectTrivia` saw at the post-rewind position
			// when absent, which still describes the gap that `child`'s
			// pad-trailing emit site is closing.
			out.push({ guard: macro true, signal: terminalSlot });
		}
		return out;
	}

	/**
	 * ω-598-member-leading-comment: wrap a bare non-first Ref field's trivia
	 * separator so own-line comments the parser captured in the gap (e.g. a
	 * block comment between a member modifier and the `var` keyword) are emitted
	 * glued to the preceding line, each followed by a hardline. Returns the
	 * unmodified separator when the field is not a Ref (no `BeforeLeading` slot)
	 * or the slot is empty.
	 */
	private static function buildBeforeLeadingSep(child: ShapeNode, fieldName: String, triviaSepExpr: Expr): Expr {
		// Gated on `child.kind == Ref` to match `TriviaTypeSynth.isBareNonFirstRef`,
		// the only host that grows the `BeforeLeading` slot.
		return child.kind == Ref ? {
			final leadAccess: Expr = beforeLeadingAccess(fieldName);
			macro {
				final _sep598: anyparse.core.Doc = $triviaSepExpr;
				final _leadCm598: Array<String> = $leadAccess;
				if (_leadCm598.length == 0)
					_sep598;
				else {
					final _p598: Array<anyparse.core.Doc> = [_sep598];
					for (_ci598 in 0..._leadCm598.length) {
						_p598.push(leadingCommentDocRun(_leadCm598, _ci598, opt));
						_p598.push(_dhl());
					}
					_dc(_p598);
				}
			}
		} : triviaSepExpr;
	}

}
#end
