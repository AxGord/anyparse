package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.WriterCascadeLowering.*;
import anyparse.macro.WriterBlankLowering.*;

/**
 * Pass 3W helpers — the EOF-mode trivia Star emit family.
 *
 * Builds the generated writer body for a last-field `@:trivia` Star with no
 * `@:trail` — the module-level statement/member list that runs to end of
 * file. Single hardline between elements (the plain-mode path forces a
 * double), the extra blank driven by each element's `blankBefore`, the file-header blank run and its head-decl package/import/using
 * classification, the
 * line-comment-led and orphan-trail blank gates, the
 * blank-after-leading-comments emit, and the orphan trailing-trivia emit
 * past the last element.
 *
 * Split out of `WriterLowering` for size — the two are NOT independent. The
 * macro-time surface is small: one inbound call (`triviaEofStarExpr`, from
 * `WriterLowering.emitTriviaEofStar`) and one outbound call
 * (`WriterCascadeLowering.buildCascadeEmit`, for the shared ctor-blank cascade).
 * Both directions run through `@:access` and every member here stays
 * private.
 *
 * Parameters typed by a `WriterLowering` sub-module typedef stay qualified:
 * the extraction moved the functions, not the typedefs, so the whole
 * sub-module typedef block still lives in `WriterLowering`'s module and
 * this file imports nothing from it. The ctor-blank infos are also read by
 * the cascade members that stayed behind; `EofStarCtx` is now read only
 * from here.
 *
 * The GENERATED-code surface is the real contract, and no type carries it:
 * every helper splices identifiers declared elsewhere in the Star body —
 * `_arr` / `_t` / `_si` / `_elem` / `opt` from the Star scaffold and the
 * `_dhl()` / `_dc()` / `_de()` / `_dwb()` Doc wrappers (plus
 * `leadingCommentDocRun` / `trailingCommentDoc*`) emitted by
 * `WriterCodegen` on the generated class.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterCascadeLowering)
final class TriviaEofLowering {

	/**
	 * Build the Doc expression for an EOF-mode trivia Star field
	 * (last field, no `@:trail`). Single hardline between elements
	 * instead of the plain mode's forced double hardline, with the extra
	 * hardline driven by each element's `blankBefore` flag. Leading
	 * comments emit above the element at the outer indent level;
	 * trailing comment attaches inline after.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaEofStarExpr(
		fieldAccess: Expr, trailBBAccess: Null<Expr>, trailLCAccess: Null<Expr>, elemFn: String,
		?afterCtorInfos: Array<WriterLowering.AfterCtorBlankInfo>, ?beforeCtorInfos: Array<WriterLowering.BeforeCtorBlankInfo>,
		?betweenCtorInfos: Array<WriterLowering.BetweenCtorBlankInfo>, ?transitionAcrossInfos: Array<WriterLowering.TransitionAcrossInfo>,
		?headCtorInfos: Array<WriterLowering.HeadCtorBlankInfo>, lineCommentTrailBlank: Bool = false, lineCommentLedAddBlank: Bool = false,
		afterFileHeaderCommentBlanks: Bool = false, betweenMultilineCommentsBlanks: Bool = false,
		?betweenSameCtorIfNotInfos: Array<WriterLowering.BetweenSameCtorIfNotInfo>, measuredMultiline: Bool = false
	): Expr {
		final triviaElemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, macro opt]),
			pos: Context.currentPos()
		};
		// ω-measured-multiline-decl — the same call with the comprehension
		// binder as receiver, for the `_elemDocs` pre-pass. Docs are built
		// ONCE either way: with the flag on, the loop reads `_elemDocs[_si]`
		// instead of calling the element writer again.
		final measuredElemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro _e.node, macro opt]),
			pos: Context.currentPos()
		};
		final trailBB: Expr = trailBBAccess ?? macro false;
		final trailLC: Expr = trailLCAccess ?? macro ([]: Array<String>);
		final afterInfos: Array<WriterLowering.AfterCtorBlankInfo> = afterCtorInfos ?? [];
		final beforeInfos: Array<WriterLowering.BeforeCtorBlankInfo> = beforeCtorInfos ?? [];
		final betweenInfos: Array<WriterLowering.BetweenCtorBlankInfo> = betweenCtorInfos ?? [];
		final transitionInfos: Array<WriterLowering.TransitionAcrossInfo> = transitionAcrossInfos ?? [];
		final headInfos: Array<WriterLowering.HeadCtorBlankInfo> = headCtorInfos ?? [];
		final betweenIfNotInfos: Array<WriterLowering.BetweenSameCtorIfNotInfo> = betweenSameCtorIfNotInfos ?? [];
		final pos: Position = Context.currentPos();
		// ω-bug-2c-inner-star — cascade emit machinery (per-info trackers
		// + cascade ternary) extracted into `buildCascadeEmit` so the
		// inner-Star path (`triviaTryparseStarExpr`, e.g.
		// `HxConditionalDecl.body`) can opt in too. See `buildCascadeEmit`
		// for cascade priority semantics, transparent-wrapper handling,
		// and the runtime locals (`_t`, `_v0`, `opt`) the emitted Exprs
		// reference.
		final emit: WriterLowering.CascadeEmit = buildCascadeEmit(
			afterInfos, beforeInfos, betweenInfos, transitionInfos, headInfos, betweenIfNotInfos
		);
		final c: WriterLowering.EofStarCtx = {
			fieldAccess: fieldAccess,
			triviaElemCall: triviaElemCall,
			measuredMultiline: measuredMultiline,
			measuredElemCall: measuredElemCall,
			trailBB: trailBB,
			trailLC: trailLC,
			emit: emit,
			pos: pos,
			lineCommentTrailBlank: lineCommentTrailBlank,
			lineCommentLedAddBlank: lineCommentLedAddBlank,
			afterFileHeaderCommentBlanks: afterFileHeaderCommentBlanks,
			betweenMultilineCommentsBlanks: betweenMultilineCommentsBlanks
		};
		final whileExpr: Expr = triviaEofWhileExpr(c);
		final elseBody: Expr = triviaEofElseBody(c, whileExpr);
		return macro {
			final _arr = $fieldAccess;
			final _trailLC: Array<String> = $trailLC;
			final _trailBB: Bool = $trailBB;
			if (_arr.length == 0 && _trailLC.length == 0)
				_de()
			else
				$elseBody;
		};
	}

	/**
	 * EOF-Star per-element while-loop emit. Builds `whileBodyParts` and
	 * returns the `EWhile` spliced into `triviaEofElseBody`. Per element: cascade fire + leading-comment emit + element emit + track.
	 */
	private static function triviaEofWhileExpr(c: WriterLowering.EofStarCtx): Expr {
		final blanksCountExpr: Expr = c.emit.blanksCount;
		final triviaElemCall: Expr = c.triviaElemCall;
		final whileBodyParts: Array<Expr> = [];
		whileBodyParts.push(macro final _t = _arr[_si]);
		if (c.afterFileHeaderCommentBlanks || c.betweenMultilineCommentsBlanks) whileBodyParts.push(macro var _suppressBalc: Bool = false);
		whileBodyParts.push(c.emit.initCurr);
		whileBodyParts.push(c.emit.currCompute);
		// ω-line-comment-led-blank: opt-in via `@:fmt(blankBeforeLineCommentLed)`
		// on the EOF Star — when the next sibling's `leadingComments[0]` starts
		// with `//`, force at least 1 blank line between previous element and
		// the line-comment chain regardless of source-blank capture or cascade
		// rules. Mirrors fork's `markLineCommentsAfter(typeToken, 1)` always-1
		// rule (MarkEmptyLines.hx:823) for top-level type→line-comment-led-type
		// boundaries. Only fires when the cascade-determined `_blanks` count
		// is 0 — cascade priorities (afterCtor / betweenCtor / transition /
		// beforeCtor / source-blank) are otherwise preserved.
		final lineCommentLedExpr: Expr = triviaEofLineCommentLedExpr(c.lineCommentLedAddBlank);
		whileBodyParts.push(macro if (_si > 0) {
			_docs.push(_dhl());
			final _blanks: Int = $blanksCountExpr;
			final _bln: Int = $lineCommentLedExpr && _blanks == 0 ? 1 : _blanks;
			var _bli: Int = 0;
			while (_bli < _bln) {
				_docs.push(_dhl());
				_bli++;
			}
		});
		final fileheaderCommentBlanksExpr: Expr = triviaEofFileheaderBlanksExpr(
			c.afterFileHeaderCommentBlanks, c.betweenMultilineCommentsBlanks
		);
		final balcExpr: Expr = triviaEofBalcExpr(c.afterFileHeaderCommentBlanks, c.betweenMultilineCommentsBlanks);
		whileBodyParts.push(macro {
			var _ci: Int = 0;
			while (_ci < _t.leadingComments.length) {
				_docs.push(leadingCommentDocRun(_t.leadingComments, _ci, opt));
				_docs.push(_dhl());
				$fileheaderCommentBlanksExpr;
				_ci++;
			}
		});
		whileBodyParts.push(balcExpr);
		whileBodyParts.push(
			c.measuredMultiline
				? (macro final _elem: anyparse.core.Doc = _elemDocs[_si])
				: (macro final _elem: anyparse.core.Doc = $triviaElemCall)
		);
		whileBodyParts.push(macro final _tc: Null<String> = _t.trailingComment);
		whileBodyParts.push(macro _docs.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDocVerbatim(_tc, opt)) : _elem));
		whileBodyParts.push(c.emit.trackPrev);
		whileBodyParts.push(macro _si++);
		final whileBodyBlock: Expr = { expr: EBlock(whileBodyParts), pos: c.pos };
		return {
			expr: EWhile(macro _si < _arr.length, whileBodyBlock, true),
			pos: c.pos
		};
	}

	/**
	 * EOF-Star empty-and-trail emit. Builds `elseBodyParts` (the non-empty
	 * branch) and returns its `EBlock`: `_docs` init, the optional `_headIsPiu`
	 * head-decl classification, head emit, the per-element `$whileExpr`, and the
	 * orphan-trail emit.
	 */
	private static function triviaEofElseBody(c: WriterLowering.EofStarCtx, whileExpr: Expr): Expr {
		final headEmitExpr: Expr = c.emit.headEmit;
		final elseBodyParts: Array<Expr> = [];
		elseBodyParts.push(macro final _docs: Array<anyparse.core.Doc> = []);
		// ω-measured-multiline-decl — build every element's Doc up front and
		// record, per element, whether it RENDERS across more than one line.
		// The question fork `MarkEmptyLines.getTypeInfo` answers with
		// `isSameLine` over the whitespace `MarkWrapping` has already
		// committed; here it is answered from the built Doc, in three terms:
		//  - a COMMITTED break — exact, the same `hasForcedBreak` term
		//    `WriterBlankLowering.blankAroundMultilineExprs` uses for members;
		//  - a flat width the module-level pen (column 0) cannot hold —
		//    the sibling's second term;
		//  - AND a break OPPORTUNITY to spend it on. Without the third term
		//    the width test is a prediction the renderer can refuse: an
		//    unbreakable 164-column header (`implementsExtends` configured
		//    `noWrap`, or a long `typedef A = B;`) renders on ONE over-wide
		//    line, and `isSameLine` would call it one line. `breakableHead`
		//    stops at the first break opportunity and returns the whole flat
		//    width when there is none, so the comparison is exactly "is
		//    there anywhere to break".
		// Residual imprecision, recorded rather than chased: a Doc whose
		// only break opportunities sit inside groups that each fit can still
		// render as one over-wide line and be counted multi-line here. Only
		// a speculative render answers that, which is not worth a second
		// pass over every module.
		// The cascade's `multiline` predicate reads `_measMulti` through
		// `_measMulti[_si]`; the loop reuses `_elemDocs[_si]` rather than
		// writing each element twice. Flag off ⇒ neither array is emitted
		// and the loop keeps its own per-element call.
		if (c.measuredMultiline) {
			final measuredElemCall: Expr = c.measuredElemCall;
			elseBodyParts.push(macro final _elemDocs: Array<anyparse.core.Doc> = [for (_e in _arr) $measuredElemCall]);
			elseBodyParts.push(macro final _measMulti: Array<Bool> = [
				for (_d in _elemDocs) {
					final _w: Int = anyparse.core.DocMeasure.flatTokenWidth(_d);
					anyparse.core.DocMeasure.hasForcedBreak(_d)
					|| (_w > opt.lineWidth && anyparse.core.DocMeasure.breakableHead(_d).width < _w);
				}
			]);
		}
		elseBodyParts.push(c.emit.initPrev);
		// ω-fileheader-multiline-comments: `_headIsPiu` flags whether the
		// decl that the module's first leading comment ACTUALLY LEADS is a
		// `package` / `import` / `using` decl. When it is true OR when that
		// decl carries 2+ leading comments, the fileheader rule fires at
		// `_si == 0 && _ci == 0` and replaces the source-driven blank slot
		// with `opt.afterFileHeaderComment`.
		// It used to answer from a scan of the WHOLE decl array (mirroring
		// fork's `markFileHeader`, whose `packagesAndImports` filter walks
		// the whole root), so a module whose first decl is a DOCUMENTED TYPE
		// and whose `import` sits BELOW it had a blank line pushed between
		// the doc comment and the declaration it documents — and since the
		// detached form is a fixed point, `fmt --list`, the corpus and
		// `writeRoundTrip` all called it canonical. A file header introduces
		// the module's package / import section; a comment that leads a type
		// is that type's doc, whatever else the module holds further down.
		// This is a DELIBERATE divergence from fork `markFileHeader`, which
		// keeps the whole-root filter: a future corpus fixture of that shape
		// would fail here, and the failure is the divergence, not a
		// regression.
		if (c.afterFileHeaderCommentBlanks || c.betweenMultilineCommentsBlanks) elseBodyParts.push(macro var _headIsPiu: Bool = false);
		if (c.afterFileHeaderCommentBlanks) elseBodyParts.push(triviaEofHeadIsPiuExpr());
		elseBodyParts.push(headEmitExpr);
		elseBodyParts.push(macro var _si: Int = 0);
		elseBodyParts.push(whileExpr);
		final extraTrailBlankExpr: Expr = triviaEofExtraTrailBlankExpr(c.lineCommentTrailBlank);
		final eofTrailBetweenExpr: Expr = triviaEofTrailBetweenExpr(c.betweenMultilineCommentsBlanks);
		elseBodyParts.push(macro if (_trailLC.length > 0) {
			if (_arr.length > 0) _docs.push(_dhl());
			if ($extraTrailBlankExpr) _docs.push(_dhl());
			var _ti: Int = 0;
			while (_ti < _trailLC.length) {
				_docs.push(leadingCommentDocRun(_trailLC, _ti, opt));
				if (_ti < _trailLC.length - 1) _docs.push(_dhl());
				$eofTrailBetweenExpr;
				_ti++;
			}
		});
		// ω-force-flat-engine sister-coverage: EOF Star is top-level
		// (`HxModule.decls`) so its parent frame is the document root,
		// not a wrap-cascade Flatten. `_dwb` is a defensive no-op here —
		// kept for invariant symmetry with the other trivia dispatchers
		// so a future caller that places EOF-style emit under a Flatten
		// parent doesn't silently lose its hand-rolled hardlines.
		elseBodyParts.push(macro _dwb(_dc(_docs)));
		return { expr: EBlock(elseBodyParts), pos: c.pos };
	}

	/**
	 * EOF-Star `lineCommentLedExpr` predicate (ω-line-comment-led-blank):
	 * true when the next sibling's first leading comment is line-style.
	 */
	private static function triviaEofLineCommentLedExpr(lineCommentLedAddBlank: Bool): Expr {
		return lineCommentLedAddBlank
			? macro (_t.leadingComments.length > 0 && StringTools.startsWith(_t.leadingComments[0], '//'))
			: macro false;
	}

	/**
	 * EOF-Star `fileheaderCommentBlanksExpr` (ω-fileheader-multiline-comments):
	 * opt-in via `@:fmt(afterFileHeaderCommentBlanks)` / `@:fmt(
	 * betweenMultilineCommentsBlanks)`. Overrides the source-driven blank
	 * slot at the c[last]→decl boundary; sets `_suppressBalc` when the
	 * fileheader rule applied this iteration.
	 */
	private static function triviaEofFileheaderBlanksExpr(afterFileHeaderCommentBlanks: Bool, betweenMultilineCommentsBlanks: Bool): Expr {
		return afterFileHeaderCommentBlanks || betweenMultilineCommentsBlanks
			? macro {
				final _lc: String = _t.leadingComments[_ci];
				final _isBlock: Bool = StringTools.startsWith(_lc, '/*');
				final _isLast: Bool = _ci + 1 == _t.leadingComments.length;
				var _override: Int = 0;
				final _firstSlot: Bool = $v{afterFileHeaderCommentBlanks} && _si == 0 && _ci == 0 && _isBlock
					&& (_headIsPiu || _t.leadingComments.length >= 2);
				if (_firstSlot) {
					_override = opt.afterFileHeaderComment;
					_suppressBalc = true;
				} else if (
					$v{betweenMultilineCommentsBlanks} && !_isLast && _isBlock && StringTools.startsWith(_t.leadingComments[_ci + 1], '/*')
				) {
					_override = opt.betweenMultilineComments;
				}
				var _bi: Int = 0;
				while (_bi < _override) {
					_docs.push(_dhl());
					_bi++;
				}
			}
			: macro {};
	}

	/**
	 * EOF-Star `balcExpr` (blankAfterLeadingComments emit): pushes a hardline
	 * after the leading-comment chain when the source captured a blank, with
	 * the `_suppressBalc` fileheader override branch.
	 */
	private static function triviaEofBalcExpr(afterFileHeaderCommentBlanks: Bool, betweenMultilineCommentsBlanks: Bool): Expr {
		return afterFileHeaderCommentBlanks || betweenMultilineCommentsBlanks ? macro if (
			_t.blankAfterLeadingComments && _t.leadingComments.length > 0 && !_suppressBalc
		)
			_docs.push(_dhl()) : macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _docs.push(_dhl());
	}

	/**
	 * EOF-Star `_headIsPiu` head-decl classification (ω-fileheader-multiline-
	 * comments): flips `_headIsPiu` when the decl the module's first leading
	 * comment leads is a package / import / using decl — i.e. when that comment
	 * introduces the module header rather than documenting a type.
	 *
	 * A module-head `#if … #end` is TRANSPARENT here: the comment still leads
	 * whatever the guarded region opens with, so the classification reaches one
	 * level into `HxConditionalDecl.body`. One level only — a `#if` whose first
	 * inner decl is itself a `#if`, and the `#elseif` / `#else` clauses of an
	 * empty `#if` body, stay opaque (no fixture reaches them).
	 */
	private static function triviaEofHeadIsPiuExpr(): Expr {
		inline function classify(subject: Expr): Expr {
			return macro switch ($subject) {
				case PackageDecl(_) | PackageEmpty | ImportDecl(_) | ImportAliasDecl(_) | ImportAliasInDecl(_) | ImportWildDecl(_) | UsingDecl(
					_
				) | UsingWildDecl(_):
					_headIsPiu = true;
				case _:
			};
		}
		final headClassify: Expr = classify(macro _arr[0].node.decl);
		final condHeadClassify: Expr = classify(macro _c.body[0].node.decl);
		return macro if (_arr.length > 0) switch (_arr[0].node.decl) {
			case Conditional(_c):
				if (_c.body.length > 0)
					$condHeadClassify;
			case _:
				$headClassify;
		};
	}

	/**
	 * EOF-Star `extraTrailBlankExpr` (ω-orphan-trail-blank): gate for the
	 * extra blank between the last decl and a line-comment-led orphan trail.
	 */
	private static function triviaEofExtraTrailBlankExpr(lineCommentTrailBlank: Bool): Expr {
		return lineCommentTrailBlank
			? macro (_arr.length > 0 && (_trailBB || (_trailLC.length > 0 && StringTools.startsWith(_trailLC[0], '//'))))
			: macro (_trailBB && _arr.length > 0);
	}

	/**
	 * EOF-Star `eofTrailBetweenExpr` (ω-fileheader-multiline-comments): emits
	 * `betweenMultilineComments` blanks between adjacent block-style comments
	 * in the orphan trail.
	 */
	private static function triviaEofTrailBetweenExpr(betweenMultilineCommentsBlanks: Bool): Expr {
		return betweenMultilineCommentsBlanks
			? macro {
				if (
					_ti < _trailLC.length - 1 && StringTools.startsWith(_trailLC[_ti], '/*')
					&& StringTools.startsWith(_trailLC[_ti + 1], '/*')
				) {
					var _bbi: Int = 0;
					while (_bbi < opt.betweenMultilineComments) {
						_docs.push(_dhl());
						_bbi++;
					}
				}
			}
			: macro {};
	}

}
#end
