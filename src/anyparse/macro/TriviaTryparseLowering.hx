package anyparse.macro;

#if macro
import anyparse.core.ShapeTree.ShapeNode;
import anyparse.macro.MacroNames.simpleName;
import anyparse.macro.WriterBlankLowering.*;
import anyparse.macro.WriterBraceSymmetryLowering.tryCatchesSymmetryWrap;
import anyparse.macro.WriterCascadeLowering.*;
import anyparse.macro.WriterLowering.CascadeInfos;
import anyparse.macro.WriterLowering.TryparseSepOverrides;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterPolicyLowering.*;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 3W helpers — the `@:trivia` + `@:tryparse` Star emit family.
 *
 * Builds the generated writer body for a tryparse Star (member lists,
 * case / default bodies, conditional-compilation branch bodies, class
 * heritage clauses): the per-iteration `while` loop, the inter-element
 * separator cascade, the ctor-blank cascade wiring, the case-body
 * flat / fit gates, the block-ended `;` re-emission, the heritage fill
 * layout, the shape / glue refusals, and the final assembly of the
 * Star's `Doc` parts.
 *
 * Split out of `WriterLowering` for size — the two are NOT independent.
 * The macro-time surface is small: one inbound call
 * (`triviaTryparseStarExpr`, from `WriterLowering.emitTriviaTryparseStar`)
 * and a short outbound list back into the shared lowering utilities
 * (`optFieldAccess`, `astPredCallT`, `buildCascadeEmit`,
 * `buildCaseBodyFlagPredicate`, `buildCaseBodyFitPredicate`,
 * `blankBefore2ExtrasExpr` — the last one is shared with the sibling
 * block-Star and sep-Star families, which is why it stayed behind). Both
 * directions run through `@:access` and every member here stays private.
 *
 * One instance is one Star's emit: the constructor reads the Star's `StarPlan` and builds the inputs that reach
 * outside this family, the instance builders read the plan and those fields directly, and the static builders take
 * only plain values. A new `@:fmt` input of a tryparse Star is a `StarPlan` method and its reader here.
 *
 * The GENERATED-code surface is the real contract, and no type carries it:
 * every helper splices identifiers declared elsewhere in the Star body —
 * `_arr` / `_t` / `_si` / `_elem` / `opt` from the Star scaffold, and the
 * Doc wrappers and opt helpers `WriterCodegen` emits on the generated
 * class (`_dt()` / `_dc()` / `_dn()` / `_de()` / `_dhl()` / `_dwb()` /
 * `_dile()` / `_dohsbh()`, `_copyOpt` / `_clearExprPosition` /
 * `_setIntersectionBreak`, `leadingCommentDocRun` /
 * `trailingCommentDoc*`). Rename one of those on either side and the
 * failure surfaces in the generated writer, not here.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterBraceSymmetryLowering, anyparse.macro.WriterCascadeLowering,
	anyparse.macro.WriterCtorBlankLowering, anyparse.macro.WriterLoweringSupport, anyparse.macro.WriterPolicyLowering,
	anyparse.macro.WriterTriviaStarEmitLowering)
final class TriviaTryparseLowering extends TriviaStarEmit<TryparseStarPlan> {

	private final _elemCalls: { triviaElemCall: Expr, triviaElemCallMaybeBreak: Expr, elemOptInit: Expr };
	private final _trailBASlot: Expr;
	private final _metaPolicyExpr: Expr;
	private final _priorAfterTrail: Null<Expr>;
	private final _elemCondFn: Null<Expr>;
	private final _cascade: WriterLowering.CascadeEmit;
	private final _cascadeBlanksCount: Expr;
	private final _flatGateExpr: Expr;
	private final _fitGateExpr: Expr;
	private final _writerOptExpr: Expr;
	private final _condIncreaseGateExpr: Expr;
	private final _shapeRefusalExpr: Expr;
	private final _glueRefusalExpr: Expr;
	private final _glueToPreviousExpr: Expr;
	private final _padLeadingSpaceDoc: Expr;
	private final _subsequentSepDoc: Expr;
	private final _firstSepExpr: Expr;

	/**
	 * Reads the Star's plan and builds every input its emit splices, in the order the emit has always built them: the
	 * parts that reach outside this family (`buildTryparseSepOverrides`, the meta line-end decls, the cascade, the
	 * predicate probes) run here once, so a branch of the emit that does not splice one still pays it, as before.
	 */
	private function new(ctx: WriterStarEmitLowering.StarEmitCtx, c: WriterLowering.TriviaStarCtx) {
		// noqa: complexity
		final starNode: ShapeNode = c.starNode;
		final plan: TryparseStarPlan = new TryparseStarPlan(StarPlan.metaOf(starNode));
		// Orphan trailing trivia is captured by the parser on the same flags: nestBody bodies and padTrailing branch bodies.
		final trailBody: Bool = plan.nestBody() || plan.padTrailing();
		final slots: TriviaStarEmit.TrailSlots = {
			trailBBAccess: trailBody ? c.trailBBAccess : null,
			trailLCAccess: trailBody ? c.trailLCAccess : null,
			trailCloseAccess: null,
			trailOpenAccess: null
		};
		// The lead is pushed by the caller before this emit, and a tryparse Star has no trail.
		super(plan, tryCatchesSymmetryWrap(ctx.braceSym, starNode, c.fieldAccess, c.elemRefName), slots, '', '');
		_trailBASlot = (_plan.nestBody() ? c.trailBAAccess : null) ?? macro false;
		// A sameLine Star (catches against the try body) separates before EVERY element; any other only between them.
		final sameLineName: Null<String> = _plan.sameLine();
		final sepExpr: Expr = sameLineName == null ? macro _dt(' ') : sameLinePolicySwitch(optFieldAccess(sameLineName));
		final sepOverrides: TryparseSepOverrides = WriterTriviaStarEmitLowering.buildTryparseSepOverrides(
			ctx, starNode, sameLineName, c.prevBareRefBody, c.elemRefName, sepExpr
		);
		final caseBodyFlagNames: Array<String> = _plan.bodyPolicy() ?? [];
		// `@:fmt(flatChildOpt('A=B', …))`: each arg is a `from=to` option pair the flat case body copies.
		final flatChildOptPairs: Array<Array<String>> = [
			for (raw in _plan.flatChildOpt() ?? []) {
				final eq: Int = raw.indexOf('=');
				if (eq <= 0 || eq >= raw.length - 1)
					Context.fatalError(
						'WriterLowering: @:fmt(flatChildOpt(...)) arg must be "from=to", got "${raw}"', Context.currentPos()
					);
				[raw.substr(0, eq), raw.substr(eq + 1)];
			}
		];
		// A run that annotates nothing answers `-2`, so it keeps its source layout and owes no break after its last element;
		// a run holding a comment, or followed by one before what it annotates, breaks as under `After`.
		final ownMetaPolicy: Null<Expr> = WriterMetaLineEndLowering.policyExpr(ctx.ctorPat, starNode, c.typePath);
		final metaAnnotates: Null<Expr> = ownMetaPolicy == null
			? null
			: WriterMetaLineEndLowering.annotatesExpr(ctx.ctorPat, starNode, c.typePath, c.fieldAccess);
		final metaLineEndPolicy: Null<Expr> = metaAnnotates == null ? ownMetaPolicy : macro ($metaAnnotates ? ($ownMetaPolicy: Int) : -2);
		final gapComment: Expr = WriterMetaLineEndLowering.gapCommentExpr(ctx.ctorPat, starNode, c.typePath, c.fieldAccess);
		final runComment: Expr = macro _trailLC.length > 0
			|| Lambda.exists(_arr, _fe -> _fe.leadingComments.length > 0 || _fe.trailingComment != null);
		_metaPolicyExpr = WriterMetaLineEndLowering.fitDecls(
			WriterMetaLineEndLowering.simplePred(starNode, ctx.ctorPat.shape.root, true), metaLineEndPolicy ?? macro -1, macro _arr,
			e -> macro $e.node, macro $gapComment || $runComment
		);
		final cascadeInfos: CascadeInfos = WriterCtorBlankLowering.readCascadeInfosFromStar(ctx.ctorBlank, starNode, c.elemRefName);
		_priorAfterTrail = c.prevTrailFieldName == null
			? null
			: WriterTriviaStarEmitLowering.priorAfterTrailExpr(ctx, c.typePath, c.prevTrailFieldName);
		// `<field>SepBefore`: a source-captured LEADING sep (`#if X, elem #end`) the pad re-emits.
		final sepBeforeAccess: Null<Expr> = _plan.sepFaithful() && _plan.sepBeforeOpt()
			? switch c.fieldAccess.expr {
				case EField(b, n):
					final slot: String = '${n}SepBefore';
					macro $b.$slot;
				case _: null;
			}
			: null;
		// The nested-conditional element probe, built only for the Stars whose emit consults it.
		_elemCondFn = ctx.formatInfo.astPreds && (_plan.conditionalBodyIndent() || _plan.blockEnded())
			? AstPredLowering.predFnExpr(ctx.shape.root, true, false, 'elementIsConditional_${simpleName(c.elemRefName)}')
			: null;

		_cascade = buildCascadeEmit(
			cascadeInfos.afterCtorInfos, cascadeInfos.beforeCtorInfos, cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos,
			cascadeInfos.headCtorInfos, cascadeInfos.betweenSameCtorIfNotInfos
		);
		// A forceInlineSep Star owes no cascade blank: its elements always join with one space.
		_cascadeBlanksCount = _plan.forceInlineSep() ? macro 0 : _cascade.blanksCount;
		_elemCalls = triviaTryparseElemCallExprs(c.elemFn, _plan.clearExprPositionNonTail(), _plan.operandBreakAfterMultilineBrace());
		_flatGateExpr = triviaTryparseCaseGateExpr(caseBodyFlagNames, false);
		_fitGateExpr = triviaTryparseCaseGateExpr(caseBodyFlagNames, true);
		_writerOptExpr = triviaTryparseWriterOptExpr(flatChildOptPairs, _plan.propagateExprPosition());
		_condIncreaseGateExpr = WriterLoweringSupport.condIncreaseGateExpr(_plan.conditionalBodyIndent());
		_shapeRefusalExpr = triviaTryparseShapeRefusalExpr(_plan.refuseFlatOnComplexExpr());
		_glueRefusalExpr = triviaTryparseGlueRefusalExpr(_plan.refuseGlueOnControlFlowRoot());
		_glueToPreviousExpr = WriterLoweringSupport.triviaGlueToPreviousExpr(_plan.glueToPrevious());
		// `@:fmt(lineLengthAwareSeps)` swaps the hard space separators for line-length probes; `@:fmt(condExprFitBreak)`
		// makes them soft lines of the region group, a space while it fits.
		final spaceDoc: Expr = _plan.lineLengthAwareSeps() ? macro _dile(opt.lineWidth, _dhl(), _dt(' ')) : macro _dt(' ');
		final sepText: Null<String> = blockSepText();
		_padLeadingSpaceDoc = sepBeforeAccess != null && sepText != null
			? macro ($sepBeforeAccess ? _dt($v{sepText + ' '}) : $spaceDoc)
			: spaceDoc;
		final subsequentSepExpr: Expr = sepOverrides.subsequentSepOverride ?? sepExpr;
		_subsequentSepDoc = if (_plan.lineLengthAwareSeps())
			spaceDoc
		else if (_plan.condExprFitBreak())
			macro (opt.conditionalExprFit ? _dl() : $subsequentSepExpr)
		else
			subsequentSepExpr;
		_firstSepExpr = sepOverrides.firstSepOverride ?? sepExpr;
	}

	/** The separator text a blockEnded or sepFaithful Star re-emits, null for every other Star. */
	private function blockSepText(): Null<String> {
		return _plan.blockEnded() || _plan.sepFaithful() ? _plan.sepText() : null;
	}

	/** The trailing pad's space: a soft line of the region group under `@:fmt(condExprFitBreak)`, else a hard space. */
	private function trailPadSpaceDoc(): Expr {
		return _plan.condExprFitBreak() ? macro (opt.conditionalExprFit ? _dl() : _dt(' ')) : macro _dt(' ');
	}

	/**
	 * ω-splice-op-fill — the `@:fmt(fillItems)` bypass emit.
	 *
	 * Lays the Star's elements out as `Fill(items, Line(' '))` and nothing
	 * else: no leading pad, no trailing pad, and — the point of the flag — no
	 * reading of `Trivial<T>.newlineBefore`. The enclosing struct's
	 * `@:fmt(fillParts)` assembly folds this fill in as one of its own items,
	 * so `#if c` , the operand run, `#end` and the tail all pack against a
	 * single budget and the same tree lays out the same way however the source
	 * spelled it.
	 *
	 * The pad is dropped rather than emitted as another soft `Line`: the gap
	 * between the condition and the first operand is a seam the STRUCT's fill
	 * already owns (`@:fmt(fillSeam)` on the field after it), and emitting a
	 * second one here would spend two separators on one gap.
	 *
	 * The run goes through `D.fillOnOverflow`, not a bare `Fill`, for the
	 * reason that helper documents: a bare `Fill` is measured as a committed
	 * break by every `MBreak` first-line probe, and an element run that still
	 * fits must keep the plain space-joined shape those probes saw before.
	 * Without the gate a fitting `if (#if neko … || #end …)` opens its parens
	 * onto three lines instead. `_dwb` restores the `WrapBoundary` the ordinary
	 * emit puts around the
	 * element run, so wrap-depth walkers (`WrapList.isTopLevelChain`) still
	 * count this run one level in.
	 *
	 * COMMENTS ARE THE REFUSAL. A fill re-decides where every break lands, and
	 * a line comment inside the run pins the break after itself; rather than
	 * teach the fill that, an element carrying ANY captured comment (leading or
	 * trailing) routes the whole Star back to `baseExpr` — the ordinary
	 * source-faithful emit, which already reproduces such a region byte for
	 * byte. The probe is a write-time scan of the element array, so a run
	 * without comments — every region seen so far — takes the fill and one with
	 * comments is untouched.
	 */
	private function triviaTryparseFillExpr(baseExpr: Expr): Expr {
		return macro {
			final _fillArr = $_fieldAccess;
			var _fillHasComments: Bool = false;
			var _fci: Int = 0;
			while (_fci < _fillArr.length) {
				if (_fillArr[_fci].leadingComments.length > 0 || _fillArr[_fci].trailingComment != null) _fillHasComments = true;
				_fci++;
			}
			if (_fillArr.length == 0 || _fillHasComments)
				$baseExpr;
			else {
				final _writerOpt = $_writerOptExpr;
				final _items: Array<anyparse.core.Doc> = [];
				var _fi: Int = 0;
				while (_fi < _fillArr.length) {
					final _t = _fillArr[_fi];
					_items.push(${_elemCalls.triviaElemCall});
					_fi++;
				}
				_dwb(anyparse.core.D.fillOnOverflow(_items, opt.lineWidth + 1));
			}
		};
	}

	/**
	 * Tryparse-Star heritage-wrap emit (B4 ω-implements-extends-wrap):
	 * dedicated heritage emit bypassing the shared incremental loop.
	 * MULTI-clause heritage packs clauses from the front via `Fill` and
	 * breaks the overflow clause(s) at additionalIndent 2; single-clause
	 * heritage stays byte-identical to the `lineLengthAwareSeps` path.
	 *
	 * Because it bypasses the shared loop it also owns COMMENT emission. It
	 * used to read the per-clause `leadingComments` / `trailingComment` slots
	 * only to set `_hasComments`, then build its Doc from the clause nodes
	 * alone — so every comment in a heritage list was dropped and
	 * `writeRoundTrip` refused the whole file: a block comment between the
	 * type name and its first `implements`, or a commented-out `extends`
	 * between two live ones. The comment branch now emits each clause's own
	 * trivia — a BLOCK comment with no internal newline stays on the
	 * declaration line, and a LINE comment takes a hardline on both sides,
	 * since a line comment runs to the newline and has no inline spelling.
	 */
	private function triviaTryparseHeritageExpr(listLayout: Array<String>): Expr {
		final layoutFn: Expr = hookFn(listLayout[0]);
		final rulesExpr: Expr = optFieldAccess(listLayout[1]);
		return macro {
			final _arr = $_fieldAccess;
			if (_arr.length == 0) {
				_de();
			} else {
				final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				final _writerOpt = $_writerOptExpr;
				var _hasComments: Bool = false;
				var _hci: Int = 0;
				while (_hci < _arr.length) {
					if (_arr[_hci].leadingComments.length > 0 || _arr[_hci].trailingComment != null) _hasComments = true;
					_hci++;
				}
				final _items: Array<anyparse.core.Doc> = [];
				var _hi: Int = 0;
				while (_hi < _arr.length) {
					final _t = _arr[_hi];
					_items.push(${_elemCalls.triviaElemCall});
					_hi++;
				}
				if (_hasComments) {
					final _docs: Array<anyparse.core.Doc> = [];
					var _hj: Int = 0;
					while (_hj < _items.length) {
						final _ht = _arr[_hj];
						final _hlc: Array<String> = _ht.leadingComments;
						if (_hlc.length == 0) {
							_docs.push(_dt(' '));
						} else {
							var _hc: Int = 0;
							while (_hc < _hlc.length) {
								_docs.push(StringTools.startsWith(_hlc[_hc], '/*') && _hlc[_hc].indexOf('\n') < 0 ? _dt(' ') : _dhl());
								_docs.push(leadingCommentDocRun(_hlc, _hc, opt));
								_hc++;
							}
							_docs.push(StringTools.startsWith(_hlc[_hlc.length - 1], '//') ? _dhl() : _dt(' '));
						}
						_docs.push(_items[_hj]);
						final _htc: Null<String> = _ht.trailingComment;
						if (_htc != null) _docs.push(trailingCommentDocVerbatim(_htc, opt));
						_hj++;
					}
					_dn(_cols, _dc(_docs));
				} else {
					$layoutFn(_items, _cols, $rulesExpr, opt.lineWidth);
				}
			}
		};
	}

	/**
	 * Tryparse-Star main (non-heritage) emit. Builds the per-element while
	 * loop (via triviaTryparseWhileExpr) and the trailing assembly (via
	 * triviaTryparseAssemblyExpr) inside the shared `_docs` scope.
	 *
	 */
	private function triviaTryparseMainExpr(): Expr {
		final metaRowWrap: Expr = WriterMetaLineEndLowering.fitRowWrapExpr(macro _metaRowAt);
		final priorAfterTrailRaw: Expr = _priorAfterTrail ?? macro (null: Null<String>);
		// A first element led by a comment breaks before it on its own, so its pad has nothing to add on a broken verdict.
		final leadPad: Expr = regionPadSlotExpr(
			_plan.siblingPad(), macro _padHardline, macro (_arr[0].leadingComments.length > 0 && !_padHardline ? _de() : _dhl()),
			_padLeadingSpaceDoc
		);
		final whileExpr: Expr = triviaTryparseWhileExpr();
		final assemblyExpr: Expr = triviaTryparseAssemblyExpr();
		final trailEndsLineDecl: Expr = triviaTryparseTrailEndsLineDecl();
		final emptyOwn: Expr = macro _patEmpty != null ? _dc([trailingCommentDocGuarded(_patEmpty, opt), _baseEmpty]) : _baseEmpty;
		final emptySlot: Expr = bodySlotExpr(emptyOwn, macro null);
		final caseGateDecls: Expr = triviaTryparseCaseGateDecls(_flatGateExpr, _fitGateExpr, priorAfterTrailRaw);
		return macro {
			final _arr = $_fieldAccess;
			final _trailLC: Array<String> = $_trailLCSlot;
			final _trailBB: Bool = $_trailBBSlot;
			final _trailBA: Bool = $_trailBASlot;
			final _sepFirst: Bool = $v{_plan.sameLine() != null};
			final _nestBody: Bool = $v{_plan.nestBody()};
			final _soleFlat: Bool = _nestBody && _arr.length == 1 && $_shapeRefusalExpr;
			$caseGateDecls;
			final _writerOpt = $_writerOptExpr;
			// ω-cond-mod-pad: padLeading/padTrailing emit a space (single-line
			// shape) or hardline (multi-line, when first element carries a
			// source newline) around the Star body. Trail-side decision
			// mirrors leading-side because the parser does not capture a
			// body[last]→outer-trail newline slot — in legal source shapes
			// the two are correlated. Empty arrays skip both pads.
			final _padLeading: Bool = $v{_plan.padLeading() && !_plan.fillItems()};
			final _padTrailing: Bool = $v{_plan.padTrailing()};
			// A body of several elements whose host puts each on its own line opens and closes on a line of its own too.
			final _padHardline: Bool = (_padLeading || _padTrailing)
				&& _arr.length > 0
				&& (_arr[0].newlineBefore || $v{_plan.elementPerLine()} && _arr.length > 1);
			$trailEndsLineDecl;
			$_metaPolicyExpr;
			// ω-condcomp-empty-body-newline (Stage A): an EMPTY cond-comp body
			// / elseBody Star (`HxConditionalStmt`/`Decl`/… `body` carries BOTH
			// `@:fmt(padLeading, padTrailing)`) must still emit a single
			// hardline so `#if(cond)\n#end` keeps its interior newline rather
			// than collapsing to `#if(cond)#end`. The `padLeading && padTrailing`
			// gate is cond-comp-EXCLUSIVE (the expr-position `elseifs` Star has
			// padTrailing ONLY) — every other tryparse-Star consumer leaves
			// both false, so the empty body stays `_de()` byte-identical.
			if (_arr.length == 0 && _trailLC.length == 0) {
				// ω-case-label-trail-comment: an EMPTY body (e.g. `case A: // c`
				// with no statements) still cuddles the captured after-trail
				// comment to the `:` token before the empty-body base Doc.
				final _patEmpty: Null<String> = $priorAfterTrailRaw;
				final _baseEmpty: anyparse.core.Doc = _padLeading && _padTrailing ? _dhl() : _de();
				// Head -> body seam: an EMPTY tryparse Star contributes no
				// break of its own (`abstract A(Int) // c` with no from/to
				// clauses), so the next struct field's `{` would glue onto
				// the comment line. Guarded emit breaks instead.
				$emptySlot;
			} else {
				final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				final _docs: Array<anyparse.core.Doc> = [];
				// ω-cond-indent-policy: when active, the trailing pad hardline
				// (the `\n` before `#else`/`#end`) is held OUT of `_docs` so it
				// lands at the surrounding statement indent; the body content
				// inside `_docs` is wrapped in `_dn(_cols, …)` at assembly.
				final _condIncrease: Bool = $_condIncreaseGateExpr;
				// ω-cond-indent-policy AlignedNestedIncrease: per-element gate.
				// True only on the cond-comp body Stars under that policy; each
				// element that is a nested `Conditional` (recognised via the
				// generated `elementIsConditional_<ElemRule>` probe threaded
				// through `elemCondFn`) is wrapped `+1` at the splice below.
				// Null probe (formats without generated predicates) ⇒ no wrap.
				final _condNestedIncrease: Bool = ${triviaTryparseCondNestedIncreaseGateExpr(_plan.conditionalBodyIndent())};
				var _condTrailPad: Null<anyparse.core.Doc> = null;
				// ω-line-comment-directive-break: set once a pad hardline has
				// already terminated the Star's last line comment, so the tail
				// guard below does not stack a second break on top of it.
				var _lineTrailBroken: Bool = false;
				${_cascade.initPrev};
				${_cascade.headEmit};
				${triviaTryparsePriorAfterTrailEmit(_priorAfterTrail)};
				if (_padLeading && _arr.length > 0) _docs.push($leadPad);
				// ω-blockended-trivia-tryparse (Session 3): see comment near
				// tryparseBlockEndedSepEmit construction. Always declared so
				// the splice site reads it safely; when sepText is null /
				// blockEnded false, the splice expands to `{}` (no read).
				var _priorElemDoc: Null<anyparse.core.Doc> = null;
				final _metaRowAt: Int = _docs.length;
				$whileExpr;
				$metaRowWrap;
				$assemblyExpr;
			}
		};
	}

	/**
	 * Tryparse-Star main per-element while-loop emit. Builds the cascade
	 * fire + leading-comment emit + inter-element separator cascade +
	 * element emit + cond-nested-increase splice + track, and returns the
	 * `EWhile` spliced into `triviaTryparseMainExpr`. Extracted so the main
	 * builder stays under the complexity gate.
	 */
	private function triviaTryparseWhileExpr(): Expr {
		final blockEndedSepEmit: Expr = triviaTryparseBlockEndedSepEmit(
			blockSepText(), _plan.blockEnded(), _plan.sepFaithful(), _elemCondFn
		);
		final sepCascade: Expr = triviaTryparseSepCascadeExpr();
		final elemCondFn: Null<Expr> = _elemCondFn;
		final elemCondProbe: Expr = elemCondFn == null ? macro false : macro $elemCondFn(_t.node);
		return macro {
			var _si: Int = 0;
			while (_si < _arr.length) {
				final _t = _arr[_si];
				// ω-cond-indent-policy AlignedNestedIncrease: remember where
				// THIS element's docs begin (its leading inter-element
				// separator + the element body) so the splice at loop tail
				// can wrap the whole span `+1` when the element is a nested
				// conditional. Captured before any separator push.
				final _condNestLen: Int = _docs.length;
				${_cascade.initCurr};
				${_cascade.currCompute};
				$blockEndedSepEmit;
				$sepCascade;
				${_elemCalls.elemOptInit};
				final _elem: anyparse.core.Doc = ${_elemCalls.triviaElemCallMaybeBreak};
				final _tc: Null<String> = _t.trailingComment;
				_docs.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDocVerbatim(_tc, opt)) : _elem);
				// ω-cond-indent-policy AlignedNestedIncrease: if this body
				// element is itself a nested `Conditional`, lift its whole
				// span (leading separator + markers + guarded body, captured
				// from `_condNestLen`) into a `_dn(_cols, …)` so the
				// `#if`/`#elseif`/`#else`/`#end` markers AND body render one
				// indent step deeper than the surrounding region. The leading
				// separator is inside the span so the `#if` marker line (which
				// renders at the PRECEDING hardline's indent) also shifts.
				// Recursion through the nested conditional's own body Star
				// accumulates the shift per depth. Formats without generated
				// predicates (null `elemCondFn`) and non-conditional elements
				// leave `_docs` untouched (byte-identical).
				if (_condNestedIncrease && $elemCondProbe && _docs.length > _condNestLen) {
					final _condNestSpan: Array<anyparse.core.Doc> = _docs.splice(_condNestLen, _docs.length - _condNestLen);
					_docs.push(_dn(_cols, _dc(_condNestSpan)));
				}
				_priorElemDoc = _elem;
				${_cascade.trackPrev};
				_si++;
			}
		};
	}

	/**
	 * Tryparse-Star inter-element separator cascade (the `if/else if` chain
	 * deciding the leading separator of element `_si`). Returns the spliced
	 * statement; references the runtime `_docs`/`_si`/`_t`/`_arr` locals
	 * declared in `triviaTryparseWhileExpr`'s emitted scope. Extracted so
	 * the while builder stays under the complexity gate.
	 */
	private function triviaTryparseSepCascadeExpr(): Expr {
		final leadCommentEmit: Expr = triviaTryparseLeadCommentSepExpr();
		final forceInlineCond: Expr = triviaTryparseForceInlineSepCond(_plan.forceInlineSep());
		final metaSep: Expr = WriterMetaLineEndLowering.fitSepExpr();
		return macro {
			if ($_glueToPreviousExpr) {
				// `@:fmt(glueToPrevious)`: no separator — the element continues the previous one's line.
			} else if (_t.leadingComments.length > 0) {
				$leadCommentEmit;
			} else if (_flatCase) {
				_docs.push(_dt(' '));
			} else if (_fitCase) {
				// ω-case-body-fitline-shared: NO separator here. `BodyFit.
				// fitLineLayout` (see `triviaTryparseCaseWrapExpr`) owns the whole
				// `<separator><body>` shape, because the separator it picks — a soft
				// `Line` inside a measured `BodyGroup` vs an `OptSpace` glue — is
				// part of the same decision as the wrap. Pushing one here would
				// force this cascade to duplicate that decision, which is exactly
				// the drift the shared emitter exists to prevent.
			} else if (_nestBody) {
				// ω-nestbody-blank: case / default body statements preserve a source
				// blank line between elements (fork keeps inter-statement blanks in
				// case / default bodies). Mirrors the `_t.newlineBefore` branch's
				// cascade-blanks loop, gated on `_si > 0` so the body's first
				// statement stays hugged under `case X:` / `default:` with no leading
				// blank. `$cascadeBlanksCount` reduces to `_t.blankBefore ? 1 : 0`
				// (case / default bodies carry no cascade infos).
				_docs.push(_dhl());
				if (_si > 0) {
					final _blanks: Int = $_cascadeBlanksCount;
					var _bli: Int = 0;
					while (_bli < _blanks) {
						_docs.push(_dhl());
						_bli++;
					}
				}
			} else if (_si > 0 && _metaPolicy == 1) {
				// ω-metadata-line-end-function: After policy collapses
				// source-driven inter-meta sep to a forced hardline,
				// emitting one metadata per line regardless of source
				// layout. Skips the cascade-blanks path — blank-line
				// separators between metas aren't a fork-supported shape
				// for the After policy.
				_docs.push(_dhl());
			} else if (_si > 0 && _metaPolicy >= 0) {
				// Every policy but After joins a metadata run with a space, a soft line inside a `Fit` row: its
				// layout never follows a source newline between metas.
				_docs.push($metaSep);
			} else if ($forceInlineCond) {
				_docs.push(_dt(' '));
			} else if (_si > 0 && (_t.newlineBefore || $v{_plan.elementPerLine()})) {
				// ω-cond-mod-newline: preserve a single source newline
				// between try-parse Star elements. Without this, the
				// default `sepExpr` (space) would collapse
				// `#if COND <mods> #end\n\tpublic` (issue_332 V1) down
				// to `#if COND <mods> #end public` on round-trip,
				// losing the author's modifier-list line break.
				//
				// ω-bug-2c-inner-star: cascade-blanks loop replaces the
				// pre-slice `if (_t.blankBefore) push(\\n)` source-driven
				// path. With no cascade infos active, `$cascadeBlanksCount`
				// reduces to `(_t.blankBefore ? 1 : 0)` — byte-identical
				// to the prior single-blank emit.
				if (!$v{_plan.elemSelfTrailsNewline()}) _docs.push(_dhl());
				final _blanks: Int = $_cascadeBlanksCount;
				var _bli: Int = 0;
				while (_bli < _blanks) {
					_docs.push(_dhl());
					_bli++;
				}
			} else if (_si > 0) {
				_docs.push($_subsequentSepDoc);
			} else if (_sepFirst) {
				_docs.push($_firstSepExpr);
			}
		};
	}

	/**
	 * Tryparse-Star main trailing assembly: the post-loop tail-sep emit,
	 * trailing pad / meta-policy hardline, orphan-trail-comment docs (via
	 * triviaTryparseTrailDocsExpr), and the wrap dispatch (via
	 * triviaTryparseWrapDispatchExpr). Returns the spliced statement;
	 * references the runtime locals declared in `triviaTryparseMainExpr`'s
	 * emitted scope. Extracted so the main builder stays under the
	 * complexity gate.
	 */
	private function triviaTryparseAssemblyExpr(): Expr {
		final lastTrailTerminatorEmit: Expr = macro {};
		// Only the body's shape votes: a line comment that ends the body breaks before the marker without moving its siblings.
		final condTrailPad: Expr = regionPadSlotExpr(
			_plan.siblingPad(), macro _padHardline, macro _dhl(), macro (_trailEndsLine ? _dhl() : _dt(' '))
		);
		final trailPad: Expr = regionPadSlotExpr(
			_plan.siblingPad(), macro _padHardline, macro _dhl(), macro (_trailEndsLine ? _dhl() : ${trailPadSpaceDoc()})
		);
		final trailDocsExpr: Expr = triviaTryparseTrailDocsExpr();
		final wrapDispatch: Expr = triviaTryparseWrapDispatchExpr();
		final metaAfterLast: Expr = WriterMetaLineEndLowering.fitAfterLastExpr();
		return macro {
			${triviaTryparseBlockEndedTrailEmit(blockSepText(), _plan.blockEnded(), _plan.sepFaithful())};
			// ω-cond-indent-policy: under AlignedIncrease hold the trailing
			// pad out of `_docs` so the close marker (`#else`/`#end`)
			// renders at the surrounding indent rather than at body+1. The
			// pad doc is identical to the pre-policy push; only its
			// placement (outside the `_dn`) changes. Other policies /
			// non-cond Stars keep the inline push (`_condIncrease` false →
			// byte-identical).
			// ω-line-comment-directive-break: `_trailEndsLine` upgrades the pad
			// from a space to a hardline. A space is right after code and wrong
			// after a `//` comment - it leaves the close marker on the comment's
			// line, which is exactly the single-line arm shape
			// (`#if a var q:Int; // t` + newline `#end`).
			if (_condIncrease && _padTrailing && _arr.length > 0) {
				_lineTrailBroken = _padHardline || _trailEndsLine;
				_condTrailPad = $condTrailPad;
			} else if (_padTrailing && _arr.length > 0 && _trailLC.length == 0) {
				_lineTrailBroken = _padHardline || _trailEndsLine;
				_docs.push($trailPad);
			} else if (_metaPolicy > 0 && _arr.length > 0) {
				_lineTrailBroken = _metaFit != 1;
				_docs.push($metaAfterLast);
			}
			// ω-trivia-tryparse-linelength: when the LAST element carries
			// a same-line `// trail`, a `//` line comment runs until the
			// next physical newline, so an inline ` ` separator before
			// the next sibling's lead literal (`{`/`}`/...) would inline
			// that sibling INSIDE the comment. Emit a terminating
			// hardline so the next field's lead lands on its own line.
			// Gated by `lineLengthAwareSeps` so non-opt-in callers stay
			// byte-identical. First consumer: HxAbstractDecl.clauses
			// terminating the last-clause trail before members `{` lead.
			$lastTrailTerminatorEmit;
			// Trail comments collected into a separate Doc array so the
			// nestBody branch can render them at parent indent when the
			// body has stmts (issue_392): a `// comment` on its own line
			// between case body's last stmt and the next `case` label
			// belongs at case-label level, not case-body level. Empty-
			// body cases (only-comment) keep body-level indent — the
			// trail concat fold below restores that path.
			final _trailDocs: Array<anyparse.core.Doc> = [];
			$trailDocsExpr;
			$wrapDispatch;
		};
	}

	/**
	 * The placed hook of `siblingSlot`. Plain arguments allocate nothing per branch; a target whose optimizer does not sink them
	 * past the hook's policy test reads the fit gate once and the glue predicate only behind `_soleFlat` and that gate.
	 */
	private function bodySlotExpr(own: Expr, last: Expr): Expr {
		final slot: Array<String> = _plan.siblingSlot() ?? return own;
		return macro {
			final _fitLine: Bool = $_fitGateExpr;
			${hookFn(slot[0])}(
				${optFieldAccess(slot[2])}, _fitLine, $own, _arr.length, _soleFlat, $last, _soleFlat && _fitLine && $_glueRefusalExpr
			);
		};
	}

	/**
	 * ω-case-body-fitline-shared — the terminal Doc for a single-statement
	 * case / default body that the resolved policy puts on the case line.
	 * Both such policies land here, split out of
	 * `triviaTryparseWrapDispatchExpr` so they share one arm.
	 *
	 * `_flatCase` (`Same`) is COMMITTED to the
	 * label line: the separator is already the hard `_dt(' ')` the cascade
	 * pushed, and the body may still wrap internally afterwards, so the
	 * `_dn(_cols, …)` gives those wrapped lines their `+1` continuation
	 * indent. `opt.alignInlineSwitchCaseBody` drops it for configs whose
	 * wrapped argument already indents relative to the case line (mirrors
	 * fork `Indenter.alignInlineSwitchCaseBody` skipping `mustIndent` on the
	 * case DblDot). Issue_121 fixtures pin the default.
	 *
	 * `_fitCase` (`FitLine`) hands the whole `<separator><body>` shape to
	 * `anyparse.format.BodyFit.fitLineBelowLabel`, through the fit hook of `siblingSlot` when
	 * the Star names one. The cascade pushes NO separator on this path, so `_docs` here is
	 * the body alone (`_fitCase` refuses a case label that captured a trailing comment,
	 * which is the only other thing that can precede the body in `_docs`).
	 *
	 * `c.glueRefusalExpr` is true when the body's single statement is keyword-led control
	 * flow, which turns the glue outcome into a break. It is read here, where
	 * `_arr.length == 1` holds by construction, and it is inert (`false`) for any Star that
	 * does not carry `@:fmt(refuseGlueOnControlFlowRoot)`.
	 *
	 * `_trailDocs` (the body Star's ORPHAN trailing comments) is appended
	 * AFTER the placement Doc, outside whatever `Nest` the placement chose, so
	 * the comment run renders at LABEL indent, as the `nestBody` arm renders a non-empty
	 * body's run (issue_392). On the `_flatCase` arm the run is provably empty.
	 *
	 * `alignInlineSwitchCaseBody` reaches the fit path as `nestGluedBody`: it is live on the
	 * GLUE outcome, whose own lines still need the `+1`; on the FIT outcome the body holds no
	 * hardline at all, so no inner line exists for a `Nest` to move.
	 */
	private function triviaTryparseCaseWrapExpr(): Expr {
		final slot: Null<Array<String>> = _plan.siblingSlot();
		final args: Array<Expr> = [
			macro _cols,
			macro _dc(_docs),
			macro !opt.alignInlineSwitchCaseBody,
			macro opt.lineWidth,
			_glueRefusalExpr,
			macro $v{_plan.belowWrappedLabel()}
		];
		final fn: Expr = slot == null ? macro anyparse.format.BodyFit.fitLineBelowLabel : hookFn(slot[1]);
		if (slot != null) args.unshift(optFieldAccess(slot[2]));
		return macro {
			final _caseBody: anyparse.core.Doc = if (_fitCase)
				$fn($a{args})
			else if (opt.alignInlineSwitchCaseBody)
				_dc(_docs)
			else
				_dn(_cols, _dc(_docs));
			_dwb(_trailDocs.length > 0 ? _dc([_caseBody, _dc(_trailDocs)]) : _caseBody);
		};
	}

	/**
	 * The `_nestBody` terminal: a body placed below its head, as a slot that leads unless it
	 * is one statement that could have fit, which is measured as if it stood beside the head.
	 */
	private function triviaTryparseNestWrapExpr(): Expr {
		final slot: Expr = bodySlotExpr(macro _nestDoc, macro _priorElemDoc);
		return macro {
			final _nestDoc: anyparse.core.Doc = if (_arr.length > 0 && _trailDocs.length > 0) {
				_dwb(_dc([_dn(_cols, _dc(_docs)), _dc(_trailDocs)]));
			} else {
				for (_d in _trailDocs) _docs.push(_d);
				_dwb(_dn(_cols, _dc(_docs)));
			};
			$slot;
		};
	}

	/**
	 * Tryparse-Star terminal wrap dispatch (the flat-case / nestBody /
	 * cond-increase / default `if/else` chain producing the final `_dwb`
	 * Doc). `finalWrapDocs` is the default-branch terminal. References the
	 * runtime `_docs`/`_trailDocs`/`_flatCase`/`_fitCase`/`_nestBody`/
	 * `_condIncrease`/`_cols`/`opt` locals. Extracted so
	 * `triviaTryparseAssemblyExpr` stays under the complexity gate.
	 *
	 * ω-line-comment-directive-break: only the `_condIncrease` and default arms
	 * carry the line-comment break guard. The case-body arms need none: no
	 * `nestBody` Star carries `padTrailing` (case / default bodies are always
	 * followed by a hardline-led sibling), and since
	 * omega-case-trail-comment-inline the `_fitCase` arm that may now hold an
	 * orphan trail run ends with that run's own hardline-led docs — so neither
	 * can glue a follower onto a `//` comment.
	 */
	private function triviaTryparseWrapDispatchExpr(): Expr {
		return macro {
			// ω-force-flat-engine sister-coverage: tryparse Star is used
			// for inner-Star bodies (case bodies, `HxConditionalDecl.body`)
			// which can sit under wrap-cascade Flatten parents in expression
			// position. Each leaf branch hand-rolls its terminal Doc — wrap
			// uniformly in `_dwb` so a nested wrap-engine reads its own
			// independent layout. `_dwb` is no-op outside Flatten frame.
			if (_flatCase || _fitCase) {
				${triviaTryparseCaseWrapExpr()};
			} else if (_nestBody) {
				${triviaTryparseNestWrapExpr()};
			} else if (_condIncrease) {
				// ω-cond-indent-policy: AlignedIncrease — body content
				// (leading pad + each body element, all inside `_docs`)
				// nests one level deeper; the trailing close-marker pad
				// (`_condTrailPad`, held out above) renders at the
				// surrounding indent. `_trailDocs` (orphan trail comments)
				// is empty for cond-comp bodies but appended defensively
				// inside the nest to preserve the pre-policy ordering.
				for (_d in _trailDocs) _docs.push(_d);
				// ω-line-comment-directive-break: under AlignedIncrease the close
				// marker's pad is held OUT of `_docs` so the marker renders at the
				// surrounding indent. The break a line comment forces must ride the
				// same channel - pushed into `_docs` it would capture the body's
				// `_dn` and land `#end` one level too deep. `_condTrailPad` is
				// provably null here: the only site that sets it also sets
				// `_lineTrailBroken` whenever `_trailEndsLine` holds.
				if (_trailEndsLine && !_lineTrailBroken) _condTrailPad = _dohsbh();
				final _nested: anyparse.core.Doc = _dn(_cols, _dc(_docs));
				_dwb(_condTrailPad != null ? _dc([_nested, _condTrailPad]) : _nested);
			} else {
				for (_d in _trailDocs) _docs.push(_d);
				// ω-cond-comp-branch-trail: the padTrailing pad (the newline before
				// the `#end`/`#else` close marker) was deferred past the orphan
				// trail comments so the marker lands on its own line instead of
				// being commented out by a trailing `//` line comment.
				if (_padTrailing && _trailLC.length > 0 && _arr.length > 0) {
					_lineTrailBroken = _padHardline || _trailEndsLine;
					_docs.push(_lineTrailBroken ? _dhl() : ${trailPadSpaceDoc()});
				}
				// ω-line-comment-directive-break: an arm that emits NO pad at all
				// (an EMPTY body holding only comments) still owes the break. The
				// guard is forward-looking, so it DROPS when the parent's next
				// emit is already a hardline - every sound seam stays byte-inert.
				if (_trailEndsLine && !_lineTrailBroken) _docs.push(_dohsbh());
				${triviaTryparseDefaultTerminal(triviaTryparseFinalWrapDocs(_plan.lineLengthAwareSeps()), _plan.condExprFitBreak())};
			}
		};
	}

	/** The generated writer body of a `@:trivia @:tryparse` Star: its plan read once, then the heritage, fill or main emit. */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseStarExpr(ctx: WriterStarEmitLowering.StarEmitCtx, c: WriterLowering.TriviaStarCtx): Expr {
		final emit: TriviaTryparseLowering = new TriviaTryparseLowering(ctx, c);
		final listLayout: Null<Array<String>> = emit._plan.listLayout();
		final baseExpr: Expr = listLayout != null ? emit.triviaTryparseHeritageExpr(listLayout) : emit.triviaTryparseMainExpr();
		return emit._plan.fillItems() ? emit.triviaTryparseFillExpr(baseExpr) : baseExpr;
	}

	/**
	 * ω-line-comment-directive-break: declare the tryparse-Star's
	 * `_lastTrailComment` / `_trailEndsLine` runtime locals.
	 *
	 * A `//` comment runs to the next PHYSICAL newline, so whatever the parent
	 * emits after this Star on the same Doc line becomes comment TEXT. On a
	 * cond-comp arm the swallowed token is the `#end` / `#else` / `#elseif`
	 * marker: the region never closes and the emitted file stops parsing -
	 * corruption, worse than losing the comment. `_trailEndsLine` is true when
	 * the LAST comment this Star emits is line-style: the orphan trail when
	 * there is one, else the last element's cuddled trailing comment. Block
	 * comments do not terminate at a newline, so their same-line glue is legal
	 * and stays.
	 *
	 * Emitted as a single `EVars` (NOT an `EBlock`) so both locals land in the
	 * caller's scope, and extracted so `triviaTryparseMainExpr` stays under the
	 * complexity gate.
	 */
	private static function triviaTryparseTrailEndsLineDecl(): Expr {
		final lastComment: Expr = macro _arr.length > 0 ? _arr[_arr.length - 1].trailingComment : null;
		final endsLine: Expr = macro _trailLC.length > 0
			? StringTools.startsWith(_trailLC[_trailLC.length - 1], '//')
			: (_lastTrailComment != null && StringTools.startsWith(_lastTrailComment, '//'));
		return macro final _lastTrailComment: Null<String> = $lastComment,
			_trailEndsLine: Bool = $endsLine;
	}

	/**
	 * ω-slice-45 — the `@:fmt(forceInlineSep)` arm's runtime condition, built
	 * here so its `&&` chain does not count against the cascade builder's
	 * complexity budget.
	 *
	 * `@:fmt(forceInlineSep)` collapses every source linebreak between
	 * consecutive SimpleCtor elements to a single space. Modifier Stars
	 * (`HxMemberDecl.modifiers`, `HxTopLevelDecl.modifiers`) opt in so
	 * multi-line `static\n\toverload` round-trips as `static overload`.
	 * ParamCtor elements (current consumers: `Conditional(inner:
	 * HxConditionalMod)` — the `#if … #end` modifier region) are gated OUT so
	 * the existing CondMod layout (issue_332 V1/V4: source newline between
	 * `#end` and the next keyword preserved) stays byte-identical.
	 * Plugin-agnostic ctor classification via `Type.enumParameters` — no
	 * reflection by ctor name. The `cast` suppresses macro-time type-checking
	 * on `.node` (struct-shaped Star elements like `HxMemberDeclT` /
	 * `HxTopLevelDeclT` would otherwise fail `EnumValue` unification —
	 * dead-code elimination runs AFTER type-check); the compile-time
	 * `$v{forceInlineSep}` short-circuit keeps the runtime reflection cost on
	 * opted-in modifier Stars only, where `.node` IS an enum
	 * (`HxMemberModifier` / `HxModifier`).
	 */
	private static function triviaTryparseForceInlineSepCond(forceInlineSep: Bool): Expr {
		return macro _si > 0
			&& $v{forceInlineSep}
			&& Type.enumParameters(cast _arr[_si - 1].node).length == 0
			&& Type.enumParameters(cast _t.node).length == 0;
	}

	/**
	 * Tryparse-Star leading-comment separator emit (the body of the
	 * `_t.leadingComments.length > 0` arm in the separator cascade):
	 * padLeading-dup guard + blank-before + per-comment hardline emit +
	 * blank-after. References the runtime `_si`/`_padLeading`/`_padHardline`/
	 * `_t`/`_docs`/`opt` locals declared in the emitted scope. Extracted so
	 * the separator cascade stays under the complexity gate.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseLeadCommentSepExpr(): Expr {
		final blankExtras: Expr = blankBefore2ExtrasExpr(macro _docs.push(_dhl()));
		return macro {
			// ω-D16-padleading-first-comment-no-dup: padLeading
			// already emitted `_dhl()` for the first element when
			// `_padHardline` is true (driven by `_arr[0].newlineBefore`).
			// Both reflect the SAME source newline between the
			// prior token and the stmt's trivia — a second `_dhl()`
			// here produces a spurious blank line (visible as
			// `#if sys\n\n\t\t// comment` for HxConditionalStmt.body
			// with `@:fmt(padLeading)` and a leading line comment
			// on the first body stmt). Skip the dup only on the
			// first iteration when padLeading fired as a hardline;
			// inter-stmt path (`_si > 0`) and non-padLeading
			// consumers stay byte-identical.
			if (!(_si == 0 && _padLeading && _padHardline)) _docs.push(_dhl());
			if (_t.blankBefore && _si > 0) {
				_docs.push(_dhl());
				$blankExtras;
			}
			var _ci: Int = 0;
			while (_ci < _t.leadingComments.length) {
				_docs.push(leadingCommentDocRun(_t.leadingComments, _ci, opt));
				_docs.push(_dhl());
				_ci++;
			}
			if (_t.blankAfterLeadingComments) _docs.push(_dhl());
		};
	}

	/**
	 * Tryparse-Star orphan-trail-comment docs build (the `_trailLC.length > 0`
	 * loop): pushes hardline + per-comment doc into `_trailDocs`, with the
	 * trailBB lead-blank and trailBA tail-blank. References the runtime
	 * `_trailDocs`/`_trailLC`/`_trailBB`/`_trailBA`/`_arr`/`opt` locals.
	 * Extracted so `triviaTryparseAssemblyExpr` stays under the complexity
	 * gate.
	 */
	private static function triviaTryparseTrailDocsExpr(): Expr {
		return macro {
			if (_trailLC.length > 0) {
				var _ti: Int = 0;
				while (_ti < _trailLC.length) {
					_trailDocs.push(_dhl());
					if (_trailBB && _ti == 0 && _arr.length > 0) _trailDocs.push(_dhl());
					_trailDocs.push(leadingCommentDocRun(_trailLC, _ti, opt));
					_ti++;
				}
				// ω-trail-blank-after: source had a blank line between this
				// trail comment and the next outer-Star sibling (e.g. case
				// label). Append an extra hardline at trail's tail; the
				// outer Star will then add its own element-leading hardline
				// for a true blank-line separator. Trailing whitespace on
				// the empty line is trimmed by the renderer (default).
				if (_trailBA) _trailDocs.push(_dhl());
			}
		};
	}

	/**
	 * The default branch's terminal Doc: `finalWrapDocs` behind the force-flat boundary every tryparse terminal carries —
	 * except, while `conditionalExprFit` is on, for a region's seams (`regionSeams`). They are lines of ONE group, and a
	 * boundary among them gave the region two modes inside an enclosing `Flatten` (a cuddled comprehension's glued body):
	 * the seams before it flattened and the ones after it broke, `… } #elseif c` on the head line and the `#elseif` body
	 * below it.
	 */
	private static function triviaTryparseDefaultTerminal(finalWrapDocs: Expr, regionSeams: Bool): Expr {
		return regionSeams ? macro (opt.conditionalExprFit ? $finalWrapDocs : _dwb($finalWrapDocs)) : macro _dwb($finalWrapDocs);
	}

	/**
	 * Tryparse-Star `writerOptExpr` builder (ω-expression-case-flat-fanout /
	 * ω-issue-423-mech-a). Builds the `_writerOpt` Expr: plain `opt`, a
	 * flat-only `_copyOpt` + per-pair field override, or (when
	 * `propagateExprPosition`) an unconditional copy setting
	 * `_inExprPosition = true`.
	 *
	 * ω-case-body-fitline-shared: the per-pair override stays gated on the
	 * COMMITTED `_flatCase`, NOT on `_flatCase || _fitCase`. `flatChildOpt`
	 * hands a child the shape the case body itself took; on the fit path that
	 * shape is still undecided at write time (the renderer picks it), so
	 * propagating it would be the blind fanout the `applyExpressionIfFanout`
	 * gate warns about. Widening the gate compiles and passes every other
	 * test, so the direction is pinned by
	 * `HxCaseBodyFitLineSliceTest.testFlatChildOptDoesNotFanOutOnTheFitPath`.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseWriterOptExpr(flatChildOptPairs: Null<Array<Array<String>>>, propagateExprPosition: Bool): Expr {
		final hasFlatChildOpt: Bool = flatChildOptPairs != null && flatChildOptPairs.length > 0;
		return if (!hasFlatChildOpt && !propagateExprPosition)
			macro opt;
		else if (propagateExprPosition) {
			// Wrap each `macro` expression in parens — array-literal `,` after
			// a `macro final ... = ...` reification fragment otherwise mis-parses
			// (the parser treats `macro` as a variable name in the next element).
			final block: Array<Expr> = [(macro final _wo = _copyOpt(opt)), macro _wo._inExprPosition = true];
			if (hasFlatChildOpt) {
				final flatOnlyParts: Array<Expr> = [
					for (pair in flatChildOptPairs) {
						final from: String = pair[0];
						final toAccess: Expr = optFieldAccess(pair[1]);
						macro _wo.$from = $toAccess;
					}
				];
				block.push(macro if (_flatCase) $b{flatOnlyParts});
			}
			block.push(macro _wo);
			macro $b{block};
		} else {
			final block: Array<Expr> = [macro final _wo = _copyOpt(opt)];
			for (pair in flatChildOptPairs) {
				final from: String = pair[0];
				final toAccess: Expr = optFieldAccess(pair[1]);
				block.push(macro _wo.$from = $toAccess);
			}
			block.push(macro _wo);
			macro (_flatCase ? $b{block} : opt);
		};
	}

	/**
	 * Shared body of the two case-body gate builders: arity validation plus
	 * the single-flag / dual-flag (`opt._inExprPosition` dispatch) shape.
	 * `fit` selects which per-flag predicate the arms are built from.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseCaseGateExpr(caseBodyFlagNames: Null<Array<String>>, fit: Bool): Expr {
		if (caseBodyFlagNames != null && caseBodyFlagNames.length > 2)
			Context.fatalError(
				'WriterLowering: @:fmt(bodyPolicy(...)) takes at most 2 args (stmtFlag, exprFlag), got ${caseBodyFlagNames.length}',
				Context.currentPos()
			);
		inline function pred(flagName: String): Expr
			return fit ? buildCaseBodyFitPredicate(flagName) : buildCaseBodyFlagPredicate(flagName);
		return if (caseBodyFlagNames == null || caseBodyFlagNames.length == 0)
			macro false;
		else if (caseBodyFlagNames.length == 1) {
			pred(caseBodyFlagNames[0]);
		} else {
			final stmtPred: Expr = pred(caseBodyFlagNames[0]);
			final exprPred: Expr = pred(caseBodyFlagNames[1]);
			macro (opt._inExprPosition ? $exprPred : $stmtPred);
		};
	}

	/**
	 * Tryparse-Star element-call Expr group (caseTailOptArg / triviaElemCall /
	 * triviaElemCallMaybeBreak / elemOptInit). Builds the per-element writer
	 * call and the operand-break opt init.
	 */
	@:access(anyparse.macro.WriterLowering)
	@:access(anyparse.macro.WriterOptFanout)
	private static function triviaTryparseElemCallExprs(
		elemFn: String, clearExprPositionNonTail: Bool, operandBreakAfterMultilineBrace: Bool
	): { triviaElemCall: Expr, triviaElemCallMaybeBreak: Expr, elemOptInit: Expr } {
		// ω-value-yielded-if-tail-barrier (case-body extension): the per-element
		// opt argument. When `clearExprPositionNonTail` is set (case / default
		// body Star), every body statement EXCEPT the tail gets
		// `_clearExprPosition` so a discarded statement-if reverts to the
		// statement-position `ifBody` policy; only the body's last statement
		// (the switch's yielded value at expression position) keeps the
		// inherited frame. `_si` / `_arr` are in scope at the element-call
		// splice. Flag off ⇒ the IDENTICAL `_writerOpt` Doc as before.
		// ω-if-tail-fork-parity: a case-body TAIL that is an `if` (IfStmt) reads
		// the case's OWN incoming `_inExprPosition` frame, NOT the force-propagated
		// one — a value-yielded case (`return switch …`, incoming true) keeps the
		// expression frame so the body breaks under `expressionIf:next`, while a
		// statement-switch case (incoming false) drops it so the body inlines under
		// `ifBody:fitLine`. Mirrors fork's `isExpression`→`isReturnExpression(case)`
		// dispatch. Non-`if` tails (nested switch for issue-423 flattening, `for` /
		// `while` bodies the fork breaks) keep the force-propagated `_writerOpt`.
		final caseTailOptArg: Expr = if (clearExprPositionNonTail) {
			final caseTailBarrier: Expr = WriterLowering.astPredCallT('tailStmtReadsExprPosition', [macro _t.node]);
			// omega-stmt-list-callarg-barrier: every element, tail included.
			final stmtOptExpr: Expr = WriterOptFanout.statementListElemOpt(macro _writerOpt);
			final tailOptExpr: Expr = macro (
				$caseTailBarrier && !opt._inExprPosition && (
					opt.expressionIfBody == anyparse.format.BodyPolicy.Next || opt.expressionIfBody == anyparse.format.BodyPolicy.FitLine
				) ? _clearExprPosition($stmtOptExpr) : $stmtOptExpr
			);
			// The tail of a STATEMENT-switch case (incoming frame false) is no value whatever frame it was handed:
			// `_statementFrame` says so to everything below it until a value site of its own resets the frame.
			macro (
				_si == _arr.length - 1
					? (opt._inExprPosition ? $tailOptExpr : _setStatementFrame($tailOptExpr))
					: _clearExprPosition($stmtOptExpr)
			);
		} else {
			macro _writerOpt;
		};
		final triviaElemCall: Expr = macro $i{elemFn}(_t.node, $caseTailOptArg);
		// ω-typedef-intersection-operand-break: per-iteration element call for
		// the MAIN inter-element loop only (the heritage/wrap fast paths keep
		// `triviaElemCall`/`_writerOpt`). Flag off (every Star but
		// `HxTypedefDecl.intersections`) ⇒ identical to `triviaElemCall`,
		// byte-inert. Flag on ⇒ when the prior element rendered multi-line AND
		// ended with a close delim, hand the element a `_copyOpt` with
		// `_intersectionOperandBreak = true` so its
		// `@:fmt(typedefIntersectionBreak)` lead breaks `&\n\t` before the
		// operand; otherwise the shared `_writerOpt` (stays glued — no copy,
		// no mutation of the shared opt).
		final triviaElemCallMaybeBreak: Expr = operandBreakAfterMultilineBrace ? macro $i{elemFn}(_t.node, _elemOpt) : triviaElemCall;
		// Single `final _elemOpt = …;` declaration spliced at loop scope (NOT a
		// nested EBlock — that would isolate `_elemOpt` from the element call).
		// Flag on ⇒ when the prior element rendered multi-line AND ended with a
		// close delim, fan the opt through `_setIntersectionBreak` (idempotent
		// `_copyOpt` + flag set), else the shared `_writerOpt` (no copy, shared
		// opt untouched). Flag off ⇒ `macro {}` (no local — `triviaElemCall`
		// uses `_writerOpt` directly, byte-identical to the pre-slice loop).
		final elemOptInit: Expr = operandBreakAfterMultilineBrace
			? macro final _elemOpt = _priorElemDoc != null
				&& anyparse.format.wrap.WrapList.flatLength(_priorElemDoc) < 0
				&& anyparse.format.wrap.WrapList.endsWithCloseDelim(_priorElemDoc)
				? _setIntersectionBreak(_writerOpt)
				: _writerOpt
			: macro {};
		return { triviaElemCall: triviaElemCall, triviaElemCallMaybeBreak: triviaElemCallMaybeBreak, elemOptInit: elemOptInit };
	}

	/**
	 * Tryparse-Star `priorAfterTrailEmit` builder
	 * (ω-trivia-tryparse-prior-after-trail): inline-emit the prev-field's
	 * same-line trail comment before padLeading. Null slot ⇒ no-op.
	 *
	 */
	private static function triviaTryparsePriorAfterTrailEmit(priorAfterTrailExpr: Null<Expr>): Expr {
		return priorAfterTrailExpr == null
			? macro {}
			: macro {
				final _pat: Null<String> = $priorAfterTrailExpr;
				// Head -> body seam: the Star's own padLeading may be a
				// SPACE (single-line source), so a line comment here would
				// swallow the first element. Guarded emit breaks instead.
				if (_pat != null) _docs.push(trailingCommentDocGuarded(_pat, opt));
			};
	}

	/**
	 * Tryparse-Star `finalWrapDocs` builder (ω-trivia-tryparse-linelength):
	 * the default-branch terminal Doc — `_dc(_docs)` plus, when
	 * `lineLengthAwareSeps`, a `_dn` nest and a last-element trail
	 * terminator.
	 */
	private static function triviaTryparseFinalWrapDocs(lineLengthAwareSeps: Bool): Expr {
		return lineLengthAwareSeps
			? macro _dc([
				_dn(_cols, _dc(_docs)),
				_arr.length > 0 && _arr[_arr.length - 1].trailingComment != null ? _dhl() : _de()
			])
			: macro _dc(_docs);
	}

	/**
	 * Tryparse-Star `shapeRefusalExpr` builder (ω-issue-423-mech-b): the
	 * extra `_flatCase` AND-clause deferring to the generated typed
	 * `caseBodyRefusesFlat` predicate. Flag off ⇒ `macro true`.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseShapeRefusalExpr(refuseFlatOnComplex: Bool): Expr {
		if (!refuseFlatOnComplex) return macro true;
		final refuses: Expr = WriterLowering.astPredCallT('caseBodyRefusesFlat', [macro _arr[0].node]);
		return macro !$refuses;
	}

	/**
	 * Tryparse-Star `glueRefusalExpr` builder
	 * (omega-case-body-controlflow-glue): the `refuseGlue` argument handed to
	 * `BodyFit.fitLineLayout` on the `_fitCase` path — the generated typed
	 * `caseBodyControlFlowRoot` predicate applied to the body's single
	 * statement. Flag off ⇒ `macro false`, which is `fitLineLayout`'s own
	 * default and therefore byte-inert.
	 *
	 * Read only inside the `_fitCase` arm, where `_arr.length == 1` holds by
	 * construction (`_caseBodyFlattenable`).
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseGlueRefusalExpr(refuseGlueOnControlFlow: Bool): Expr {
		return refuseGlueOnControlFlow ? WriterLowering.astPredCallT('caseBodyControlFlowRoot', [macro _arr[0].node]) : macro false;
	}

	/**
	 * Tryparse-Star `tryparseBlockEndedSepEmit` builder
	 * (ω-blockended-trivia-tryparse): inject `sepText` between two not-yet-
	 * statement-terminated elements. Null sepText / non-blockEnded ⇒ no-op.
	 *
	 */
	private static function triviaTryparseBlockEndedSepEmit(
		sepText: Null<String>, blockEnded: Bool, sepFaithful: Bool = false, ?elemCondFnExpr: Expr
	): Expr {
		// ω-sep-faithful: source-fidelity mode — the sep re-emits iff the
		// parser captured one after the prior element (`sepAfter`), with no
		// `}`/`;` shape heuristics. Used by comma-lists inside conditional
		// element groups (`HxConditionalArgs.body`), where a `}`-ending
		// object-literal element still needs its comma.
		final priorCondProbe: Expr = elemCondFnExpr == null ? macro false : macro $elemCondFnExpr(_arr[_si - 1].node);
		return sepText != null && sepFaithful
			? macro {
				if (_si > 0 && _arr[_si - 1].sepAfter) _docs.push(_dt($v{sepText}));
			}
			: sepText != null && blockEnded
				? macro {
					if (
						_si > 0
						&& _priorElemDoc != null
						&& (_arr[_si - 1].sepAfter || (!anyparse.core.DocMeasure.endsWithStmtTerminator(_priorElemDoc) && !$priorCondProbe))
					)
						_docs.push(_dt($v{sepText}));
				}
				: macro {};
	}

	/**
	 * Tryparse-Star `tryparseBlockEndedTrailEmit` builder
	 * (ω-blockended-trivia-tryparse-trail): post-loop tail sep so the last
	 * element keeps its source `;`. Null sepText / non-blockEnded ⇒ no-op.
	 *
	 */
	private static function triviaTryparseBlockEndedTrailEmit(sepText: Null<String>, blockEnded: Bool, sepFaithful: Bool = false): Expr {
		// ω-sep-faithful: trailing sep before the enclosing `#end`/`#else`
		// re-emits iff the source had it (`sepAfter` on the LAST element) —
		// the mandatory-comma case `[a, #if x b, #end c]`.
		return sepText != null && sepFaithful
			? macro {
				if (_arr.length > 0 && _arr[_arr.length - 1].sepAfter) _docs.push(_dt($v{sepText}));
			}
			: sepText != null && blockEnded
				? macro {
					if (
						_arr.length > 0
						&& _priorElemDoc != null
						&& _arr[_arr.length - 1].sepAfter
						&& !anyparse.core.DocMeasure.endsWithSemi(_priorElemDoc)
					)
						_docs.push(_dt($v{sepText}));
				}
				: macro {};
	}

	/**
	 * Tryparse-Star `condNestedIncreaseGateExpr` builder (ω-cond-indent-policy
	 * AlignedNestedIncrease): per-element gate true when `condBodyIndent` AND
	 * the active `opt.conditionalPolicy` is AlignedNestedIncrease.
	 */
	private static function triviaTryparseCondNestedIncreaseGateExpr(condBodyIndent: Bool): Expr {
		return condBodyIndent
			? macro (opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.AlignedNestedIncrease)
			: macro false;
	}

	/**
	 * ω-case-body-fitline-shared — declare the tryparse-Star's
	 * `_caseBodyFlattenable` / `_flatCase` / `_fitCase` runtime locals.
	 *
	 * One eligibility, two placement decisions. The eligibility is the body
	 * SHAPE: `_soleFlat`, a `nestBody` Star holding exactly one element not refused by
	 * `refuseFlatOnComplexExpr`, with no leading comment on that element. On top of it,
	 * `_flatCase` COMMITS the body to the case-header line at write time (`Same`)
	 * and `_fitCase` defers the same-vs-next choice to the renderer
	 * (`FitLine`). Every other policy — `Next` — leaves
	 * both false, which is the plain `nestBody` break.
	 *
	 * The two are mutually exclusive because one policy value cannot be both
	 * `Same` and `FitLine`; the explicit `!_flatCase` keeps that true
	 * by construction, so the two consumers may test them in either order.
	 *
	 * `_flatCase` additionally requires an EMPTY orphan trailing-comment run: it is the
	 * policy the fork corpus runs under, and its separator is already pushed by the cascade,
	 * so relaxing it there would be a parity change. `_fitCase` does not ask:
	 * `BodyFit.fitLineLayout` places the body and the wrap helper appends the trail docs
	 * after it at LABEL level (issue_392).
	 *
	 * `_fitCase` additionally refuses a case label that captured a same-line
	 * trailing comment. `BodyFit.fitLineLayout` owns the header→body
	 * separator, so it must receive the body ALONE; a captured comment sits
	 * in `_docs` AHEAD of the body and would land on the wrong side of that
	 * separator. Refusing costs nothing: a `//` comment runs to a physical newline, so the
	 * body could never share the label's line anyway.
	 *
	 * Emitted as a single `EVars` (NOT an `EBlock`) so all three locals land
	 * in the caller's scope, mirroring `triviaTryparseTrailEndsLineDecl`, and
	 * extracted so `triviaTryparseMainExpr` stays under the complexity gate.
	 */
	private static function triviaTryparseCaseGateDecls(flatGateExpr: Expr, fitGateExpr: Expr, priorAfterTrailRaw: Expr): Expr {
		return macro final _caseBodyFlattenable: Bool = _soleFlat && _arr[0].leadingComments.length == 0,
			_flatCase: Bool = _caseBodyFlattenable && _trailLC.length == 0 && $flatGateExpr,
			_fitCase: Bool = _caseBodyFlattenable && !_flatCase && $priorAfterTrailRaw == null && $fitGateExpr;
	}

}
#end
