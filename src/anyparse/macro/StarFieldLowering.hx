package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.StructSeqLowering.StructSeqCtx;
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.StarLoopLowering.*;
import anyparse.macro.TriviaSlotNames.*;
import anyparse.macro.ParseDispatchLowering.*;

using anyparse.macro.MetaInspect;

/**
 * Pass 3 helpers - what ONE repetition emits, on both halves of the fork.
 *
 * `StructSeqLowering.emitFieldValueByKind` reaches exactly three of these -
 * the plain, the `@:optional` and the `@:optional`-plus-keyword Star - and
 * each one decides the same four things for its own shape: where the
 * accumulator is declared, what one iteration parses, what ends the loop
 * (a close literal, a separator that is not followed by an element, a
 * block-ended predicate, or end of input) and what the field's value
 * expression finally is. `emitTriviaStarFieldSteps` is the Trivia-mode
 * variant of the plain one, `emitNonTriviaCloseSteps` the Fast-mode close
 * detection it forks away from, and `buildOptKwStarInnerCommit` the
 * post-commit keyword-trivia capture the keyword variant needs.
 *
 * The six struct-field emitters came out of `StructSeqLowering` for SIZE,
 * not for a new responsibility: same rule shape, same state, so they take
 * that module's `StructSeqCtx` bundle unchanged rather than declaring one
 * here. The five `lowerStar*Branch` leaves came from `Lowering` and are the
 * five members S83 measured as reading NO state at all, so they are static
 * with no bundle and are reached from `Lowering` unqualified. Nothing in
 * either group reaches back into its former home.
 *
 * Star emission FORKS across four sites, and this module is where the parse
 * side's two halves are kept TOGETHER so the audit is one read:
 * `emitStarFieldSteps` is the struct-field half and the five
 * `lowerStar*Branch` shape leaves are the enum-ctor half. Only the
 * dispatch between them (`Lowering.lowerEnumBranch`'s Case 4) stays
 * behind. The other two sites are the twins in `WriterLowering`, which
 * that module's header keeps together for the same reason - so a change
 * here is a question about all four.
 */
@:access(anyparse.macro.BinaryParseLowering, anyparse.macro.KwBranchLowering, anyparse.macro.Lowering,
	anyparse.macro.OperatorLoopLowering, anyparse.macro.ParseDispatchLowering, anyparse.macro.SpanArgLowering,
	anyparse.macro.StarLoopLowering, anyparse.macro.StructFieldTrailLowering, anyparse.macro.TriviaSlotNames)
final class StarFieldLowering {

	/**
	 * Emit the parse steps for a struct field of shape `Star<Ref>`. The
	 * Star node's own `lit.*` annotations carry the surrounding wrappers
	 * (`@:lead` open, `@:trail` close, optional `@:sep`). The accumulator
	 * is declared with the given `localName` so the enclosing `lowerStruct`
	 * can reference it in the final struct literal.
	 *
	 * Four termination modes are selected by the metadata on the Star
	 * node and by the `isLastField` flag:
	 *
	 *  - `@:trail("X")` **without** `@:sep` — loop terminates when the
	 *    next non-whitespace char is the close literal's first char.
	 *  - `@:trail("X")` **with** `@:sep(",")` — loop terminates when the
	 *    next char is not a separator. The first element is parsed only
	 *    when the next char is not already the close char (empty-list
	 *    case).
	 *  - No `@:trail`, **not last field** (or `@:tryparse`) — try-parse
	 *    mode. Loop attempts to parse an element on each iteration; on
	 *    `ParseError` restores position and breaks. Used by modifier
	 *    arrays where the loop stops when the next token is not a
	 *    recognised keyword, and by switch-case bodies where the loop
	 *    stops at the next `case` / `default` / `}` (D49).
	 *  - No `@:trail`, **last field**, no `@:tryparse` — EOF mode. Loop
	 *    terminates when `ctx.pos` reaches `ctx.input.length`. Used by
	 *    module-root Star fields where the top level has no close
	 *    delimiter.
	 *  - No `@:trail`, **with** `@:sep(",")` + `@:tryparse` — try-parse
	 *    with sep peek. Loop attempts to parse an element; on success,
	 *    peeks the separator: if present, consumes it and continues; if
	 *    absent, breaks. On element-parse fail, rewinds to before any
	 *    whitespace skip and breaks (so the enclosing rule's close
	 *    literal — e.g. `#end` on the wrapping ctor — sees the next
	 *    token at its original position). Use case:
	 *    `HxConditionalObjectField.body` — comma-separated object-literal
	 *    fields inside a `#if … #end` block, where `#end` is consumed by
	 *    the enclosing `HxObjectField.Conditional` ctor, not by this
	 *    Star.
	 *
	 * `@:sep` combined with no `@:trail` AND no `@:tryparse` is rejected
	 * at compile time because there is no unambiguous way to stop a
	 * sep-peek loop at EOF without a fail-rewind signal.
	 */
	private static function emitStarFieldSteps(
		sc: StructSeqCtx, starNode: ShapeNode, ownerPath: Null<String>, fieldName: Null<String>, localName: String,
		parseSteps: Array<Expr>, isLastField: Bool
	): Void {
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: Star struct field must contain a Ref', Context.currentPos());
		}
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = sc.parseFnName(elemRefName);
		final elemCT: ComplexType = sc.ruleReturnCT(elemRefName);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos()
		};
		final openText: Null<String> = starNode.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final closeText: Null<String> = starNode.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		// ω-star-call-gate: the element rule's first-token fact, used to
		// SKIP the trial in a `@:tryparse` loop whose termination is a
		// deliberate parse failure. That failure is the loop's normal exit,
		// so its `throw` is pure waste — measured at ~310 ns plus per-frame
		// cost on V8, ~186 746 times over the corpus.
		//
		// SEMANTICS: skipping the trial also skips its `ctx.recordFail`
		// bookkeeping, so on MALFORMED input the farthest-fail diagnostic
		// can move — the same accepted behaviour change `lowerEnum`
		// documents at length for the Alt dispatch guards. For the Haxe
		// grammar the enclosing `collectTrivia` / `skipWs` comment probes
		// record at the position first, so the reported locus is unchanged.
		//
		// `Unknown` leaves every loop byte-identical to what it was before
		// the gate existed.
		//
		// A `@:raw` OWNER is the one shape that must refuse the gate outright.
		// `lowerRule` ends by running `stripSkipWs` over the whole body, which
		// erases the loop's own `skipWs` — but NOT the gate, and not the
		// ELEMENT rule's internal one when the element is not itself raw. The
		// gate would then peek un-skipped bytes and end the loop at the first
		// inter-element gap. A binary format is safe by symmetry: there EVERY
		// rule is stripped, so the element still starts exactly where the gate
		// peeks. An owner we cannot resolve is refused for the same reason we
		// refuse anything unproven — `Unknown` costs only the guard.
		final ownerNode: Null<ShapeNode> = ownerPath == null ? null : sc.shape.rules[ownerPath];
		final gateableOwner: Bool = ownerNode != null && !ownerNode.hasMeta(':raw');
		final elemFirst: BranchFirstToken = gateableOwner ? ruleFirstToken(sc.shape.rules, elemRefName, []) : Unknown;
		final triviaStar: Bool = sc.ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		final tryparseLoop: Bool = triviaStar
			? starNode.hasMeta(':tryparse')
			: closeText == null && (!isLastField || starNode.hasMeta(':tryparse'));
		if (tryparseLoop) sc.starGates.push({
			rule: ownerPath,
			field: fieldName,
			elem: elemRefName,
			first: elemFirst
		});
		if (closeText == null && sepText != null && !starNode.hasMeta(':tryparse')) {
			Context.fatalError(
				'Lowering: Star struct field with @:sep without @:trail requires @:tryparse for fail-rewind termination',
				Context.currentPos()
			);
		}
		// Trivia-mode branch — @:trivia-annotated Star accumulates
		// `Trivial<T>` wrappers instead of plain element values. Supports
		// close-peek mode (HxClassDecl.members / HxFnDecl.body) and EOF
		// mode (HxModule.decls). `@:sep` and `@:tryparse` combined with
		// @:trivia are rejected — no current grammar combines them and the
		// semantics of "trivia around a sep-separated list" are undecided.
		if (triviaStar) {
			emitTriviaStarFieldSteps(sc, starNode, localName, parseSteps, isLastField, elemCT, elemCall, openText, closeText, elemFirst);
			return;
		}
		if (openText != null) {
			parseSteps.push(macro expectLit(ctx, $v{openText}));
			parseSteps.push(macro skipWs(ctx));
		}
		final accumCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(elemCT)] });
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: accumCT,
					expr: macro [],
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
		final accumRef: Expr = macro $i{localName};
		if (closeText == null && sepText != null && starNode.hasMeta(':tryparse')) {
			// Try-parse with sep peek. After each successful
			// element, peeks the next non-whitespace char: if it equals
			// the sep, consumes it and continues; otherwise breaks. On
			// element-parse fail, restores `_savedPos` (taken BEFORE
			// `skipWs`) so the enclosing rule's close literal sees the
			// pre-whitespace position — matches the rewind discipline of
			// the regular tryparse-no-sep branch below. Empty input is
			// accepted (zero-element Star) for the same reason: first
			// `$elemCall` throws on `#end`, the rewind hits the original
			// position, the enclosing `@:trail('#end')` consumes the
			// directive at its native offset. The trailing-sep tolerance
			// of the sep+close branch (consume sep then check close) is
			// folded inline: after consuming the sep, the next iteration's
			// element parse will fail on `#end` and rewind to just AFTER
			// the consumed sep, so the enclosing close still sees `#end`.
			//
			// `@:fmt(sepBeforeOpt)` opt-in: BEFORE entering the
			// element loop, peek-and-consume a single leading sep INSIDE
			// the body (between enclosing kw and first element). Captures
			// true/false into `<localName>SepBefore` for the writer's
			// padLeading runtime gate to re-emit the leading sep. Without
			// this, `#if X, body #end` parses by other means only if the
			// body Star tolerates a leading `,` — which it does NOT (no
			// HxParam dispatch matches `,`, fail-rewind sticks at `,`).
			// First consumer: `HxConditionalParam.body`
			// (`whitespace/issue_582_type_hints_conditionals`).
			final sepCharCode: Int = sepText.charCodeAt(0);
			final hasSepBeforeOpt: Bool = starNode.fmtHasFlag('sepBeforeOpt');
			if (hasSepBeforeOpt) emitSepBeforeOptStep(localName, parseSteps, sepCharCode);
			final sepBlockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
			final predicateName: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE];
			final predicateCall: Expr = predicateName != null ? sc.buildBlockEndedPredicateCall(predicateName, accumRef) : macro false;
			parseSteps.push(buildTryparseSepLoop(elemCall, accumRef, sepCharCode, sepBlockEnded, predicateCall, elemFirst));
			return;
		}
		emitNonTriviaCloseSteps(sc, starNode, parseSteps, isLastField, elemCall, accumRef, closeText, sepText, elemFirst);
	}

	/**
	 * Emit the parse steps for an `@:optional` Star struct field with
	 * `@:lead` / `@:trail` (and optionally `@:sep`). The local is typed
	 * `Null<Array<elemCT>>`; absent input leaves it `null`, present input
	 * parses the bracketed list and assigns the array.
	 *
	 * First consumer: `HxTypeRef.params` (`@:optional @:lead('<')
	 * @:trail('>') @:sep(',')`). The element rule may recurse into the
	 * containing rule — composition is handled by the parser dispatcher,
	 * not by this emitter.
	 *
	 * Termination is close-peek with an optional sep loop, mirroring
	 * `emitStarFieldSteps`'s sep+close branch. Trivia-mode trailing slots
	 * and tryparse / EOF modes are not supported — the bracketed list
	 * shape commits to a close delimiter on `matchLit` hit.
	 */
	private static function emitOptionalStarFieldSteps(
		sc: StructSeqCtx, starNode: ShapeNode, localName: String, parseSteps: Array<Expr>
	): Void {
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: @:optional Star struct field must contain a Ref', Context.currentPos());
		}
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = sc.parseFnName(elemRefName);
		final elemCT: ComplexType = sc.ruleReturnCT(elemRefName);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos()
		};
		// `@:lead` and `@:trail` are guaranteed non-null at this point —
		// the validation block in `lowerStruct` rejects optional Star
		// without both before the field-value switch fires.
		final openText: String = starNode.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final closeText: String = starNode.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final accumCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(elemCT)] });
		final optAccumCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(accumCT)] });
		final closeCharCode: Int = closeText.charCodeAt(0);
		final closeNotNextExpr: Expr = closeText.length == 1
			? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
			: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{closeText});
		final loopBody: Expr = if (sepText != null) {
			final sepCharCode: Int = sepText.charCodeAt(0);
			macro {
				skipWs(ctx);
				if ($closeNotNextExpr) {
					_items.push($elemCall);
					skipWs(ctx);
					while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
						_items.push($elemCall);
						skipWs(ctx);
					}
				}
			};
		} else {
			macro {
				skipWs(ctx);
				while ($closeNotNextExpr) {
					_items.push($elemCall);
					skipWs(ctx);
				}
			};
		}
		// ω-optional-star-rewind: save cursor BEFORE the pre-peek
		// `skipWs`, then attempt the open-lit match. On miss, rewind to
		// the saved pos so any consumed trivia (whitespace OR comments)
		// stays in the source for the next field / outer Star to pick
		// up. The caller (`lowerStruct`) suppresses its per-field
		// pre-`skipWs` for this branch so we don't double-skip.
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: optAccumCT,
					expr: macro {
						final _savedPosOptStar: Int = ctx.pos;
						skipWs(ctx);
						if (matchLit(ctx, $v{openText})) {
							final _items: $accumCT = [];
							$loopBody;
							skipWs(ctx);
							expectLit(ctx, $v{closeText});
							_items;
						} else {
							ctx.pos = _savedPosOptStar;
							null;
						}
					},
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

	/**
	 * Emit the parse steps for an `@:optional @:kw + @:tryparse Star`
	 * struct field. The kw is the commit point — on `matchKw` hit the
	 * tryparse loop runs until element parse fails; on miss `ctx.pos`
	 * rewinds to before the pre-commit ws scan so any trivia we just
	 * skipped becomes visible again to the enclosing `@:trivia` Star's
	 * next `collectTrivia` (mirrors the optional-Ref miss-rewind at
	 * `lowerStruct` ~1825).
	 *
	 * First consumer: `HxConditionalDecl.elseBody` (`#if … #else <decls>
	 * #end`). Splices two known-working components: kw-led commit +
	 * miss-rewind + trivia-slot machinery from the optional-Ref path
	 * (`lowerStruct` ~1744-1839) and the tryparse Star loop body from
	 * the non-optional Star path (`emitStarFieldSteps` ~2071 plain /
	 * `emitTriviaStarFieldSteps` ~2438 trivia).
	 *
	 * The local is typed `Null<Array<elemCT>>` (plain) or
	 * `Null<Array<Trivial<elemCT>>>` (trivia + `trivia.starCollects`) —
	 * absent input leaves it `null`, present input commits and runs the
	 * loop. This preserves the round-trip distinction between absent
	 * `#else` (null) and present-but-empty `#else #end` (empty array).
	 *
	 * Trivia-mode orphan-trail slots (`<localName>Trailing*`) are
	 * declared at outer scope with zero-init. Regular tryparse rewinds
	 * uncapture trivia on element-parse failure, so the slots stay at
	 * their defaults — orphan trivia propagates outward through the
	 * enclosing Star's `collectTrivia`. `@:fmt(nestBody)` is rejected
	 * (no current consumer; semantics inside an optional kw guard are
	 * undecided).
	 */
	private static function emitOptionalKwStarFieldSteps(
		sc: StructSeqCtx, starNode: ShapeNode, localName: String, parseSteps: Array<Expr>, kwLead: String, hasKwTriviaSlots: Bool,
		afterKwLocal: String, beforeKwNlLocal: String, bodyOnSameLineLocal: String, beforeKwLeadingLocal: String,
		beforeKwTrailingLocal: String
	): Void {
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) Context.fatalError('Lowering: @:optional @:kw Star struct field must contain a Ref', Context.currentPos());
		if (starNode.fmtHasFlag('nestBody'))
			Context.fatalError('Lowering: @:optional @:kw Star + @:fmt(nestBody) is not supported', Context.currentPos());
		if (!starNode.hasMeta(':tryparse')) Context.fatalError('Lowering: @:optional @:kw Star requires @:tryparse', Context.currentPos());
		// Slice D4: `@:sep('text', tailRelax, blockEnded(...))` is supported
		// on kw-led optional Stars. Pre-D4 the engine silently ignored sep
		// on this path — `HxConditionalStmt.elseBody` (`#if … #else <stmt>;
		// #end`) decomposed `final x = 1;` into `FinalStmt + EmptyStmt(';')`
		// and the writer's sep-less inter-element pad produced `final x = 1 ;`.
		// Mirror of the sister `emitTriviaStarFieldSteps` (3422) /
		// WriterLowering (3380) contract: sep without `blockEnded` is rejected
		// because termination semantic is undefined without it.
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final blockEndedFlag: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		// ω-sep-faithful: valid alternative — same permissive-matchLit +
		// per-element `sepAfter` capture (the D4 loop below), writer-side
		// re-emission keyed purely on that captured signal.
		final kwStarSepFaithful: Bool = starNode.annotations['lit.sepFaithful'] == true;
		if (sepText != null && !blockEndedFlag && !kwStarSepFaithful) {
			Context.fatalError(
				'Lowering: @:optional @:kw Star + @:sep requires the blockEnded flag (@:sep(text, tailRelax, blockEnded)) '
				+ 'or sepFaithful — termination semantic undefined otherwise',
				Context.currentPos()
			);
		}
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = sc.parseFnName(elemRefName);
		final elemCT: ComplexType = sc.ruleReturnCT(elemRefName);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos()
		};
		final isTriviaCollects: Bool = sc.ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		// Element wrap and accumulator types — Trivial<T> in trivia mode.
		final accumElemCT: ComplexType = isTriviaCollects
			? TPath({ pack: ['anyparse', 'runtime'], name: 'Trivial', params: [TPType(elemCT)] })
			: elemCT;
		final accumCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(accumElemCT)] });
		final optAccumCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(accumCT)] });
		// Trivia-mode orphan-trail slots — zero-init at outer scope so
		// the writer's struct-literal at end-of-fn can read them. Regular
		// tryparse never writes here (rewind-on-fail uncaptures trivia);
		// slots exist purely to satisfy synth-paired-type field shape.
		if (isTriviaCollects) {
			final trailBBLocal: String = trailingBlankBeforeLocalName(localName);
			final trailNLLocal: String = trailingNewlineBeforeLocalName(localName);
			final trailLCLocal: String = trailingLeadingLocalName(localName);
			final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
			final arrayStrCT: ComplexType = TPath({
				pack: [],
				name: 'Array',
				params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
			});
			parseSteps.push({
				expr: EVars([
					{
						name: trailBBLocal,
						type: boolCT,
						expr: macro false,
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
			// ω-keep-fnsig-newline: sibling zero-init local so the struct-literal
			// push of TrailingNewlineBefore has a defined value on this path too.
			parseSteps.push({
				expr: EVars([
					{
						name: trailNLLocal,
						type: boolCT,
						expr: macro false,
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
			parseSteps.push({
				expr: EVars([
					{
						name: trailLCLocal,
						type: arrayStrCT,
						expr: macro [],
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
		}
		final loopBody: Expr = buildOptKwStarLoopBody(
			elemCT, elemCall, isTriviaCollects, sepText, starNode.fmtHasFlag('padTrailing'), trailingBlankBeforeLocalName(localName),
			trailingLeadingLocalName(localName)
		);
		final innerCommitAction: Expr = buildOptKwStarInnerCommit(sc, hasKwTriviaSlots, afterKwLocal, bodyOnSameLineLocal);
		final preCommitCapture: Expr = if (hasKwTriviaSlots)
			macro $i{beforeKwNlLocal} = hasNewlineIn(ctx.input, _prevEnd, _kwStartPos);
		else
			macro {};
		final commitCheck: Expr = macro matchKw(ctx, $v{kwLead});
		// Pre-commit ws scan + commit + miss-rewind. Trivia mode does the
		// scan-back + collectTrailing + collectTrivia capture; plain mode
		// just `skipWs`. Both rewind `ctx.pos = _wsPos` on miss.
		final valueExpr: Expr = if (hasKwTriviaSlots)
			macro {
				final _wsPos: Int = ctx.pos;
				var _prevEnd: Int = _wsPos;
				while (_prevEnd > 0) {
					final _wsCh: Int = ctx.input.charCodeAt(_prevEnd - 1);
					if (_wsCh == ' '.code || _wsCh == '\t'.code || _wsCh == '\n'.code || _wsCh == '\r'.code)
						_prevEnd--;
					else
						break;
				}
				final _trailComment: Null<String> = collectTrailing(ctx);
				final _preTrivia = collectTrivia(ctx);
				final _kwStartPos: Int = ctx.pos;
				if ($commitCheck) {
					$i{beforeKwTrailingLocal} = _trailComment;
					for (_c in _preTrivia.leadingComments) $i{beforeKwLeadingLocal}.push(_c);
					$preCommitCapture;
					$innerCommitAction;
					final _items: $accumCT = [];
					$loopBody;
					_items;
				} else {
					ctx.pos = _wsPos;
					null;
				}
			}
		else
			macro {
				final _wsPos: Int = ctx.pos;
				skipWs(ctx);
				final _kwStartPos: Int = ctx.pos;
				if ($commitCheck) {
					$preCommitCapture;
					$innerCommitAction;
					final _items: $accumCT = [];
					$loopBody;
					_items;
				} else {
					ctx.pos = _wsPos;
					null;
				}
			};
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: optAccumCT,
					expr: valueExpr,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

	/**
	 * Emit the Trivia-mode variant of a Star struct field — each element
	 * goes through `collectTrivia` (leading comments + blank-before
	 * detection) before being parsed, then `collectTrailing` probes for
	 * a same-line comment after the element. The result is pushed into
	 * `_items:Array<Trivial<elemCT>>` as a struct literal that mirrors
	 * `Trivial<T>`'s four fields.
	 *
	 * Supported termination modes:
	 *  - Close-peek (`closeText != null`, no `@:sep`) — reuses the
	 *    `charCodeAt == closeChar` peek from the plain-mode path.
	 *  - EOF (`closeText == null`, `isLastField`, no `@:tryparse`) —
	 *    terminates at `ctx.pos >= ctx.input.length`.
	 *  - Try-parse (`@:tryparse`, no close) — attempts element parse in
	 *    a try/catch; on failure rewinds `ctx.pos` to the start of the
	 *    iteration (before `collectTrivia`) so the enclosing Star
	 *    re-scans the bytes and attaches trivia to the correct site.
	 *    Trailing slots stay at defaults — orphan trivia propagates
	 *    outward, not into `TrailingLeading`.
	 *
	 * `@:sep` combined with `@:trivia` is rejected upstream in
	 * `emitStarFieldSteps` — no current grammar combines them and its
	 * semantics for trivia placement (before or after the separator)
	 * is undecided.
	 */
	private static function emitTriviaStarFieldSteps(
		sc: StructSeqCtx, starNode: ShapeNode, localName: String, parseSteps: Array<Expr>, isLastField: Bool, elemCT: ComplexType,
		elemCall: Expr, openText: Null<String>, closeText: Null<String>, elemFirst: BranchFirstToken
	): Void {
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final blockEndedFlag: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		// ω-blockended-trivia-tryparse (Session 3): the historical
		// `@:trivia + @:sep + (EOF | @:tryparse)` reject is relaxed for
		// the specific shape `@:sep(text, tailRelax, blockEnded) +
		// @:tryparse`. The blockEnded flag supplies the missing
		// termination signal: between two elements, sep may be absent
		// when the prior element ended with `}`, and sep-absent +
		// non-blockEnded gracefully exits the tryparse loop (tryparse
		// semantic: element is valid but no-more-sep means we're done).
		// First consumers: HxCaseBranch.body, HxDefaultBranch.stmts —
		// the case/default-body Stars where per-
		// statement `@:trailOpt(';')` consuming `;` and element-
		// parse failure alone cannot terminate at next `case`/`default`/`}`.
		if (sepText != null && closeText == null && !starNode.hasMeta(':tryparse')) {
			Context.fatalError('Lowering: @:trivia + @:sep requires @:trail (close-peek) or @:tryparse', Context.currentPos());
		}
		// ω-sep-faithful: `@:sep(text, sepFaithful)` supplies the same
		// termination semantic as blockEnded for the tryparse loop
		// (sep-absent exits via element-parse fail-rewind), so it is a
		// valid alternative — the difference is writer-side only
		// (source-faithful sep re-emission instead of `}`/`;` elision).
		final sepFaithfulFlag: Bool = starNode.annotations['lit.sepFaithful'] == true;
		if (sepText != null && starNode.hasMeta(':tryparse') && !blockEndedFlag && !sepFaithfulFlag) {
			Context.fatalError(
				'Lowering: @:trivia + @:sep + @:tryparse requires the blockEnded flag (@:sep(text, tailRelax, blockEnded)) '
				+ 'or sepFaithful (@:sep(text, sepFaithful)) — termination semantic undefined otherwise',
				Context.currentPos()
			);
		}
		if (closeText == null && !isLastField && !starNode.hasMeta(':tryparse')) {
			// Defensive — the Star shape would reject on the plain path too.
			Context.fatalError('Lowering: @:trivia Star without @:trail requires the field to be terminal', Context.currentPos());
		}
		final tryparse: Bool = starNode.hasMeta(':tryparse');
		final nestBody: Bool = starNode.fmtHasFlag('nestBody');
		if (openText != null) {
			parseSteps.push(macro expectLit(ctx, $v{openText}));
			// ω-open-delim-interiority: mirror of the Alt-branch barrier in
			// `lowerTriviaStarBranch` — a stash captured before the open literal
			// is not the first element's leading gap.
			parseSteps.push(sc.stashNewlineClearExpr());
			// ω-open-trailing: capture a same-line `// comment` (or
			// `/* … */`) sitting right after the open literal (e.g.
			// `{ // foo` before the first element). Stored in a synth
			// `<field>TrailingOpen` slot on the paired Seq type; the
			// writer emits it inline after the open lit so it stays on
			// the same line as `{` rather than being mis-bucketed as
			// own-line leading of the first element. Captured via
			// `collectTrailingFull` (content WITH delimiters) so block-
			// style trailings round-trip as `/* foo */`, mirroring the
			// `<field>TrailingClose` slot's verbatim contract.
			//
			// Skipped for `@:tryparse` Stars: their writer helper
			// (`triviaTryparseStarExpr`) does not consume the slot —
			// capturing here would silently drop the comment at write
			// time. The synth gate in `TriviaTypeSynth.buildStarTrailingSlots`
			// matches; without it the struct-literal push below would
			// also reference a non-existent field.
			if (!tryparse) {
				final trailOpenLocal: String = trailingOpenLocalName(localName);
				final nullStrCT: ComplexType = TPath({
					pack: [],
					name: 'Null',
					params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
				});
				parseSteps.push({
					expr: EVars([
						{
							name: trailOpenLocal,
							type: nullStrCT,
							expr: macro collectTrailingFull(ctx),
							isFinal: true
						}
					]),
					pos: Context.currentPos()
				});
			}
		}
		final wrappedCT: ComplexType = TPath({
			pack: ['anyparse', 'runtime'],
			name: 'Trivial',
			params: [TPType(elemCT)]
		});
		final accumCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(wrappedCT)] });
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: accumCT,
					expr: macro [],
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
		// ω-orphan-trivia: two mutable locals capture the trivia scanned
		// on the final iteration (the one that hits the termination
		// check). Without these, orphan comments between the last
		// element and the close literal (or EOF) would be silently
		// dropped. Paired with the two synth slots on the parent Seq
		// type (see `TriviaTypeSynth.buildStarTrailingSlots`).
		//
		// In `@:tryparse` mode the rewind-on-fail path uncaptures any
		// trivia the failed iteration had already scanned, so the
		// trailing slots stay at their zero-initialised defaults — orphan
		// trivia propagates outward through the enclosing Star's own
		// `collectTrivia` scan rather than being stashed here.
		final trailBBLocal: String = trailingBlankBeforeLocalName(localName);
		final trailNLLocal: String = trailingNewlineBeforeLocalName(localName);
		final trailLCLocal: String = trailingLeadingLocalName(localName);
		final trailBALocal: String = trailingBlankAfterLocalName(localName);
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		final arrayStrCT: ComplexType = TPath({
			pack: [],
			name: 'Array',
			params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
		});
		parseSteps.push({
			expr: EVars([
				{
					name: trailBBLocal,
					type: boolCT,
					expr: macro false,
					isFinal: false
				}
			]),
			pos: Context.currentPos()
		});
		// ω-keep-fnsig-newline: sibling close-newline local, declared
		// unconditionally next to `trailBBLocal`. Assigned from the terminal
		// `_lead.newlineBefore` at each close-peek break below.
		parseSteps.push({
			expr: EVars([
				{
					name: trailNLLocal,
					type: boolCT,
					expr: macro false,
					isFinal: false
				}
			]),
			pos: Context.currentPos()
		});
		parseSteps.push({
			expr: EVars([
				{
					name: trailLCLocal,
					type: arrayStrCT,
					expr: macro [],
					isFinal: false
				}
			]),
			pos: Context.currentPos()
		});
		// ω-trail-blank-after: tryparse + nestBody Stars carry an extra Bool
		// slot that records whether the source had a blank line BETWEEN the
		// stashed orphan trail comment and the next outer-Star sibling. Set
		// from `_lead.blankAfterLeadingComments` on the failed iteration
		// (the parse attempt that triggered trail capture); other tryparse
		// shapes either rewind on failure or have no nestBody wrap so the
		// signal is meaningless. Default `false` matches the no-blank case.
		if (tryparse && nestBody) {
			parseSteps.push({
				expr: EVars([
					{
						name: trailBALocal,
						type: boolCT,
						expr: macro false,
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
		}
		// ω-objectlit-source-trail-comma: sep-Stars with a close literal
		// declare an extra mutable Bool that records whether the LAST
		// `matchLit(sepText)` call inside the loop succeeded. After the
		// loop terminates via the close-peek check, the local holds
		// `true` iff the final parsed element was followed by a separator
		// (i.e. source had a trailing comma). Default `false` covers the
		// empty-list case and the no-trailing-sep case identically.
		final trailPresentLocal: String = trailPresentLocalName(localName);
		if (sepText != null) {
			parseSteps.push({
				expr: EVars([
					{
						name: trailPresentLocal,
						type: boolCT,
						expr: macro false,
						isFinal: false
					}
				]),
				pos: Context.currentPos()
			});
		}
		final accumRef: Expr = macro $i{localName};
		if (tryparse) {
			// ω-blockended-trivia-tryparse (Session 3): `@:tryparse +
			// @:sep(text, tailRelax, blockEnded)` fork — permissive
			// matchLit on sep (consistent with the close-peek trivia
			// path's existing semantics). Element-parse failure still
			// rewinds + breaks via the existing try/catch. The
			// `blockEnded` flag does NOT affect parsing — it lives on
			// the writer side (suppress sep emission when prior ends
			// with `}` / `;`). Both nestBody and non-nestBody variants
			// emit; nestBody keeps the orphan-trail capture on parse
			// failure.
			if (sepText != null) {
				// ω-sep-faithful: mirror the plain path's `@:fmt(sepBeforeOpt)`
				// pre-loop leading-sep peek so trivia-collecting
				// conditional element bodies (`#if X, elem #end`) capture the
				// leading sep into the `<localName>SepBefore` slot the ctor
				// call references.
				if (starNode.fmtHasFlag('sepBeforeOpt')) emitSepBeforeOptStep(localName, parseSteps, sepText.charCodeAt(0));
				parseSteps.push(buildTriviaTryparseSepBody(
					elemCT, elemCall, accumRef, sepText, trailPresentLocal, trailBBLocal, trailLCLocal, trailBALocal, nestBody, elemFirst
				));
				return;
			}
			// Try-parse termination: each iteration saves `ctx.pos` before
			// `collectTrivia`, attempts the element parse, and rewinds to
			// the saved pos on failure so the captured trivia is fully
			// uncaptured. The enclosing `@:trivia` Star's next
			// `collectTrivia` re-scans the same bytes and attaches them
			// correctly (e.g. as leading of the next sibling element).
			//
			// `@:fmt(nestBody)` Stars (case/default bodies) add a trailing-
			// orphan capture: when parse fails AFTER scanning own-line
			// comments without a blank-line separator, those comments
			// belong to THIS body (rendered at body-indent), not to the
			// next sibling. We stash them in the trailing slots and
			// advance cursor past the trivia so the enclosing Star does
			// not re-capture. Comments separated by a blank line still
			// flow outward via rewind — preserving "blank line = belongs
			// to next entity" convention.
			parseSteps.push(buildTriviaTryparseNoSepBody(
				elemCT, elemCall, accumRef, trailBBLocal, trailLCLocal, trailBALocal, nestBody, starNode.fmtHasFlag('padTrailing'),
				elemFirst
			));
			return;
		}
		final terminationCheck: Expr = buildTriviaCloseTerminationCheck(closeText);
		// ω-trivia-sep: when the trivia Star carries `@:sep`, an
		// optional separator (e.g. `,`) is matched after each element
		// before the trailing-comment capture. Trailing same-line
		// comments after the sep (e.g. `field: 1, // comment`) attach
		// to the just-pushed element. Without sep, the close-peek loop
		// falls through unchanged.
		//
		// The pre-sep horizontal-whitespace skip avoids consuming
		// newlines / comments (`skipWs` would swallow the trailing
		// `// comment` before `collectTrailing` could see it). Inlines
		// the same `' ' | '\t' | '\r'` walk that `collectTrailing`
		// uses internally.
		// ω-objectlit-source-trail-comma: capture the per-iteration
		// `matchLit` result into the slice's source-trail-presence local.
		// After the loop's close-peek terminates, the local holds the
		// LAST iteration's sep result — `true` iff the source committed
		// to a trailing separator before the close.
		//
		// ω-objectlit-source-inter-sep: additionally capture per-
		// iteration into `_sepAfter` for the per-element
		// `Trivial.sepAfter` slot. The writer's trivia-branch sep gate
		// (`TriviaSepLowering.triviaSepStarExpr`) consults this to suppress inter-
		// element seps the source intentionally omitted
		// (lineends/issue_111). Sep-less Stars push `sepAfter: true`
		// (default declared just inside the loop body) so the writer's
		// always-emit branch fires unchanged.
		// ω-blockended-trivia (Session 3): Stars carrying
		// `@:sep('text', tailRelax, blockEnded)` keep the existing
		// matchLit-permissive sep loop on the parser side — sep is
		// optional, source-fidelity flows through `_sepAfter` to the
		// per-element wrapper. The `blockEnded` flag controls
		// WRITER-side sep emission (suppress `;` when prior ends with
		// `}` or `;`). Trying to enforce strict expectLit-on-miss here
		// fails on shapes like `if (c) return;` where the inner stmt's
		// own `;` was already consumed by an inner `@:trail(';')` /
		// embedded VoidReturnStmt — the byte at `_prevEndPos - 1` is
		// `;` not `}`. Permissive parser keeps backwards-compatibility
		// with the old per-stmt-@:trailOpt model byte-for-byte.
		final blockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		final sepMatchExpr: Expr = buildTriviaCloseSepMatchExpr(sepText, trailPresentLocal);
		// ω-trivia-trailing-before-sep: capture trailing same-line comment
		// BEFORE the optional sep-match. Source shape `elem /*c*/, next`
		// would break sep-match (`,` not found after h-ws skip stops
		// at `/`) and then `collectTrailing` consumed `/*c*/` AFTER the
		// failed sep-match — the `,` was never matched and the next
		// iteration's element parse failed on `,`. Reorder: first probe
		// `collectTrailing` (rewinds on miss), then run sep-match. The
		// post-sep `collectTrailing` still fires when the source carried
		// the trailing after the sep (`elem, // c\n`) — covered by the
		// `_trailingBeforeSep == null && _sepAfter` gate so we don't
		// double-capture.
		parseSteps.push(
			buildTriviaCloseLoopBody(elemCT, elemCall, accumRef, terminationCheck, sepMatchExpr, trailBBLocal, trailNLLocal, trailLCLocal)
		);
		if (closeText == null) return;
		parseSteps.push(macro skipWs(ctx));
		parseSteps.push(macro expectLit(ctx, $v{closeText}));
		// ω-close-trailing: capture a same-line trailing comment sitting
		// right after the close literal (e.g. `} // catch` before the
		// next `catch` clause). Stored in a synth `<field>TrailingClose`
		// slot on the paired Seq type; the writer emits
		// `trailingCommentDocVerbatim(...)` after the close when non-
		// null. ω-trailing-block-style: captured via `collectTrailingFull`
		// (content WITH delimiters) so block-style trailing comments
		// round-trip as `/* foo */`, not as `// foo`. EOF mode and
		// try-parse mode have no close literal and skip this capture
		// entirely.
		final trailCloseLocal: String = trailingCloseLocalName(localName);
		final nullStrCT: ComplexType = TPath({
			pack: [],
			name: 'Null',
			params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
		});
		parseSteps.push({
			expr: EVars([
				{
					name: trailCloseLocal,
					type: nullStrCT,
					expr: macro collectTrailingFull(ctx),
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

	private static function buildOptKwStarInnerCommit(
		sc: StructSeqCtx, hasKwTriviaSlots: Bool, afterKwLocal: String, bodyOnSameLineLocal: String
	): Expr {
		// Post-commit kw-trivia capture — mirrors the optional-Ref path.
		return hasKwTriviaSlots
			? macro {
				final _kwEndPos: Int = ctx.pos;
				$i{afterKwLocal} = collectTrailing(ctx);
				final _t = collectTrivia(ctx);
				$i{bodyOnSameLineLocal} = !hasNewlineIn(ctx.input, _kwEndPos, ctx.pos);
				// ω-cond-comp-elseBody-leading: route the own-line leading comments
				// after the kw into pendingTrivia so the body Star's first
				// collectTrivia attaches them to body[0] and emits them (the
				// kw-Leading slot is NOT emitted for kw-Star fields — only kw-Ref).
				// Mirrors the non-kw branch below; keeps the newline/blank signal.
				// ω-cond-comp-elseBody-pad-stash: propagate the post-kw
				// newline/blank signal forward so the loop's first-iteration
				// `collectTrivia` (which drains `ctx.pendingTrivia`) sees it
				// and sets `_arr[0].newlineBefore = true`. Without this stash
				// the writer's `_padHardline` switch (`triviaTryparseStarExpr`)
				// reads false on the first body element and `#else\nimport\n
				// #end` round-trips flat as `#else import #end`. Sister non-kw
				// branch below already does the equivalent stash; the kw
				// branch lacked the producer despite sharing the downstream
				// drainer (`Codegen.collectTriviaField`). leadingComments
				// drained into kwLeading above — re-stashing would emit them
				// twice (once attached to the kw, once on body[0]).
				if (_t.newlineBefore || _t.blankBefore || _t.blankAfterLeadingComments || _t.leadingComments.length > 0)
					ctx.pendingTrivia = _t;
			}
			: sc.ctx.trivia
				? macro {
					final _t = collectTrivia(ctx);
					if (_t.leadingComments.length > 0 || _t.blankBefore || _t.blankAfterLeadingComments || _t.newlineBefore)
						ctx.pendingTrivia = _t;
				}
				: macro skipWs(ctx);
	}

	private static function emitNonTriviaCloseSteps(
		sc: StructSeqCtx, starNode: ShapeNode, parseSteps: Array<Expr>, isLastField: Bool, elemCall: Expr, accumRef: Expr,
		closeText: Null<String>, sepText: Null<String>, elemFirst: BranchFirstToken
	): Void {
		if (closeText == null && (!isLastField || starNode.hasMeta(':tryparse'))) {
			// Try-parse mode: loop until element parse fails. Used by Star
			// fields that are NOT the last field in a struct, OR by fields
			// annotated with `@:tryparse` (D49) — the loop terminates when the
			// next token cannot be parsed as an element (e.g. a modifier loop
			// stopping at `var`/`function`, or a switch-case body stopping at
			// the next `case`/`default`).
			//
			// The termination bookkeeping lives in ONE `Expr` spliced into
			// both the catch arm and the first-token gate, so the two exits
			// cannot drift apart.
			final exitArm: Expr = macro {
				ctx.pos = _savedPos;
				break;
			};
			final gate: Null<Expr> = starGateExpr(elemFirst, exitArm);
			// `skipWs` moves out of the `try` when the gate is emitted: the
			// gate must peek where the ELEMENT starts, and `skipWs` cannot
			// throw (its body is a bounded scan plus `matchLit` comment
			// probes, none of which raise), so the two shapes are
			// observationally identical.
			// ω-orphan-prefix-member: plain-mode twin of the trivia loop's
			// zero-width success guard — an element rule whose every field can
			// be absent consumes nothing and this loop's only exit is a parse
			// failure, so the backtrack sentinel is rethrown to reach it.
			parseSteps.push(gate == null
				? macro {
					while (true) {
						final _savedPos: Int = ctx.pos;
						try {
							skipWs(ctx);
							final _elemStart: Int = ctx.pos;
							final _elem = $elemCall;
							if (ctx.pos == _elemStart) throw anyparse.runtime.ParseError.backtrack;
							$accumRef.push(_elem);
						} catch (_e: anyparse.runtime.ParseError)
							$exitArm;
					}
				}
				: macro {
					while (true) {
						final _savedPos: Int = ctx.pos;
						skipWs(ctx);
						$gate;
						final _elemStart: Int = ctx.pos;
						try {
							final _elem = $elemCall;
							if (ctx.pos == _elemStart) throw anyparse.runtime.ParseError.backtrack;
							$accumRef.push(_elem);
						} catch (_e: anyparse.runtime.ParseError)
							$exitArm;
					}
				});
			return;
		}
		if (closeText == null) {
			// EOF mode: last field, no trail — loop until end of input.
			parseSteps.push(macro {
				skipWs(ctx);
				while (ctx.pos < ctx.input.length) {
					$accumRef.push($elemCall);
					skipWs(ctx);
				}
			});
			return;
		}
		// Close-peek entry guard for the Star loop.
		//
		// When `closeText` is a single byte, a `charCodeAt` peek is the
		// fastest way to decide "are we at the close or at an element?".
		// When `closeText` is longer, the single-byte peek false-positives
		// on elements whose first byte happens to equal `closeText[0]` —
		// concretely, `@:trail('*\/')` on a block-comment body lets `*`
		// appear inside line content, and a `charCodeAt != '*'` guard
		// skips the Star entirely the moment body begins with `*` (e.g.
		// `/**` javadoc). The full-string `peekLit` call eats a substring
		// comparison instead of a byte compare, which is negligible
		// outside of very hot inner loops.
		final closeCharCode: Int = closeText.charCodeAt(0);
		final closeNotNextExpr: Expr = closeText.length == 1
			? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
			: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{closeText});
		final blockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		if (sepText != null && blockEnded) {
			final sepCharCode: Int = sepText.charCodeAt(0);
			final predicateName: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE];
			final predicateCall: Expr = predicateName != null ? sc.buildBlockEndedPredicateCall(predicateName, accumRef) : macro false;
			final sepStartsElement: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_STARTS_ELEMENT] == true;
			parseSteps.push(
				buildCloseBlockEndedBody(elemCall, accumRef, closeNotNextExpr, sepCharCode, sepText, predicateCall, sepStartsElement)
			);
		} else {
			parseSteps.push(buildClosePeekBody(elemCall, accumRef, closeNotNextExpr, sepText));
		}
		parseSteps.push(macro skipWs(ctx));
		parseSteps.push(macro expectLit(ctx, $v{closeText}));
	}

	/**
	 * Case 4 (no-sep): `@:lead`/`@:trail` Star with no separator. The loop
	 * terminates by peeking at the close literal instead of consuming a
	 * separator between items.
	 */
	private static function lowerStarNoSepBranch(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			while ($closeNotNextExpr) {
				_items.push($elemCall);
				skipWs(ctx);
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			return $ctorCall;
		};
	}

	/**
	 * Case 4 (plain @:sep): close-driven Star loop that consumes one
	 * separator between elements and tolerates a trailing sep before the
	 * close literal.
	 */
	private static function lowerStarSepBranch(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr, sepCharCode: Int
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			if ($closeNotNextExpr) {
				_items.push($elemCall);
				skipWs(ctx);
				// Permissive sep (ω-span-sep-permissive): consume one optional
				// separator between elements and keep looping until the close —
				// aligning with the trivia build's close-peek loop, which has
				// always tolerated an omitted sep (`[1 2]`, `f(a b)`). Required
				// for `#if`-guarded element groups whose commas live INSIDE the
				// conditional body (`[a, #if x b, #end c]`) — the span build
				// otherwise stops at the group boundary. Garbage input still
				// fails: the element parse throws on anything that is not an
				// element, and the close expect catches the rest.
				while ($closeNotNextExpr) {
					if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
					}
					_items.push($elemCall);
					skipWs(ctx);
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			return $ctorCall;
		};
	}

	/**
	 * Case 4 (@:sepAlt): tolerant close-driven loop that consumes an
	 * OPTIONAL separator (sepText or sepAltText) between elements. Mirrors
	 * the trivia-build close-peek loop in plain mode so multi `;`-separated
	 * anon fields parse under the non-trivia builds. Sole consumer:
	 * `HxType.Anon`.
	 */
	private static function lowerStarSepAltBranch(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr, sepCharCode: Int,
		sepAltCharCode: Int
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			while ($closeNotNextExpr) {
				_items.push($elemCall);
				skipWs(ctx);
				if (ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode} || ctx.input.charCodeAt(ctx.pos) == $v{sepAltCharCode}) {
					ctx.pos++;
					skipWs(ctx);
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			return $ctorCall;
		};
	}

	/**
	 * Case 4 block-ended Star with `sepStartsElement` — the sep byte at pos
	 * belongs to the NEXT element when the prior element is block-ended.
	 *
	 */
	private static function lowerStarBlockEndedSepStarts(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr, sepCharCode: Int,
		sepText: String, predicateCall: Expr
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			if ($closeNotNextExpr) {
				var _prevEndPos: Int = ctx.pos;
				_items.push($elemCall);
				_prevEndPos = ctx.pos;
				skipWs(ctx);
				while ($closeNotNextExpr) {
					final _isBE: Bool = _prevEndPos > 0 && {
						var _pebRew: Int = _prevEndPos - 1;
						while (_pebRew > 0) {
							final _bc: Int = ctx.input.charCodeAt(_pebRew);
							if (_bc == ' '.code || _bc == '\t'.code || _bc == '\n'.code || _bc == '\r'.code)
								_pebRew--;
							else
								break;
						}
						final _b: Int = ctx.input.charCodeAt(_pebRew);
						_b == ';'.code || $predicateCall;
					};
					if (_isBE) {
						// block-ended: sep byte at pos belongs to next element
						_items.push($elemCall);
						_prevEndPos = ctx.pos;
						skipWs(ctx);
					} else if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
						_items.push($elemCall);
						_prevEndPos = ctx.pos;
						skipWs(ctx);
					} else {
						expectLit(ctx, $v{sepText});
					}
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			return $ctorCall;
		};
	}

	/**
	 * Case 4 block-ended Star, sep-first policy — sep is consumed between
	 * elements; block-ended exemption tolerates an omitted sep when the
	 * prior element ended with `;`/`}` or the predicate matches.
	 */
	private static function lowerStarBlockEndedSepLast(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr, sepCharCode: Int,
		sepText: String, predicateCall: Expr
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			if ($closeNotNextExpr) {
				var _prevEndPos: Int = ctx.pos;
				_items.push($elemCall);
				_prevEndPos = ctx.pos;
				skipWs(ctx);
				while ($closeNotNextExpr) {
					if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
						_items.push($elemCall);
						_prevEndPos = ctx.pos;
						skipWs(ctx);
					} else if (
						_prevEndPos > 0 && {
							var _pebRew: Int = _prevEndPos - 1;
							while (_pebRew > 0) {
								final _bc: Int = ctx.input.charCodeAt(_pebRew);
								if (_bc == ' '.code || _bc == '\t'.code || _bc == '\n'.code || _bc == '\r'.code)
									_pebRew--;
								else
									break;
							}
							final _b: Int = ctx.input.charCodeAt(_pebRew);
							_b == ';'.code || $predicateCall;
						}
					) {
						_items.push($elemCall);
						_prevEndPos = ctx.pos;
						skipWs(ctx);
					} else {
						expectLit(ctx, $v{sepText});
					}
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			return $ctorCall;
		};
	}

}
#end
