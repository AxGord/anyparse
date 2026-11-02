package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLoweringSupport.*;
import haxe.macro.Context;
import haxe.macro.Expr;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W — the blank-line and width probes shared by the Star
 * families.
 *
 * These are the `Expr` fragments a Star emit body splices when it has
 * to ask a question about the SOURCE rather than about the grammar:
 * how many blank lines the input had around a multi-line member
 * (`blankAroundMultilineExprs`, `blankBefore2ExtrasExpr`), whether a
 * uniform-collapse run is still uniform
 * (`triviaUniformCollapseInitExpr`, `triviaBalcEmitExpr`), and the small
 * seam builders an arrow body or a bare separator needs.
 *
 * They live here rather than in any one Star family because each is
 * read by two or more of them — the tryparse, block, sep and eof
 * modules plus `WriterLowering` itself — which is exactly why they had
 * stayed behind in `WriterLowering` when those four families were
 * extracted. Callers reach them unqualified through
 * `import anyparse.macro.WriterBlankLowering.*;`.
 */
@:access(anyparse.macro.WriterLoweringSupport)
final class WriterBlankLowering {

	/**
	 * ω-uniform-statement-blanks / ω-uniform-element-blanks: pre-pass Expr
	 * declaring `_uniformCollapse` over the captured element array — shared by
	 * the block-Star (statement list) and sep-Star (array literal) emitters.
	 * `true` when the runtime knob is `Collapse` AND every interior gap between
	 * adjacent elements is blank AND no INTERIOR element carries a leading
	 * comment. Uniformity is measured over INTERIOR gaps only, so the edge blank
	 * right after the open delimiter never participates.
	 *
	 * A leading comment bails from an INTERIOR element only, because only there
	 * can a blank line detach it from the element above and make it a group
	 * header — and under uniformity that blank is always present. Element 0 has
	 * nothing above it but the open delimiter, so its comment annotates its own
	 * element and carries no grouping intent; the blank it may hold
	 * (`blankAfterLeadingComments`) is stripped by `triviaBalcEmitExpr`.
	 *
	 * Declared as a bare `EVars` so the var lands in the enclosing emit scope the
	 * per-element blank guard reads. `macro {}` (no declaration) for every
	 * non-opted Star, keeping the pre-slice emit byte-identical.
	 *
	 * The declare/read pair now spans three modules: this declaration is spliced
	 * by `TriviaSepLowering.triviaSepDispatchExpr` and
	 * `TriviaBlockLowering.triviaBlockElseBody`, and `_uniformCollapse` is read by
	 * the blank guards in both. Parity is held only by every one of those sites
	 * passing the same `uniformStmtBlanks` flag — gate one side and not the other
	 * and the generated writer either reads an undeclared local or declares a dead
	 * one, with nothing in any module's types to catch it.
	 */
	private static function triviaUniformCollapseInitExpr(uniformStmtBlanks: Bool): Expr {
		return uniformStmtBlanks
			? macro var _uniformCollapse: Bool = opt.uniformStatementBlanks == anyparse.format.UniformStatementBlanksPolicy.Collapse && {
				var _ok: Bool = true;
				var _uci: Int = 0;
				while (_uci < _arr.length) {
					if (_uci > 0 && (!_arr[_uci].blankBefore || _arr[_uci].leadingComments.length > 0)) {
						_ok = false;
						break;
					}
					_uci++;
				}
				_ok;
			}
			: macro {};
	}

	/**
	 * ω-uniform-statement-blanks / ω-uniform-element-blanks: the
	 * `blankAfterLeadingComments` emit, shared by the block-Star and sep-Star
	 * force-multi loops. A collapsed element list must also drop the blank a
	 * leading comment holds before its own element — the pre-pass only lets a
	 * comment through at element 0, so this reaches exactly the "note glued to
	 * the open delimiter, then a stray blank" shape and never an interior group
	 * header. The pre-slice expression for every non-opted Star.
	 */
	private static function triviaBalcEmitExpr(uniformStmtBlanks: Bool): Expr {
		return uniformStmtBlanks ? macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0 && !_uniformCollapse)
			_inner.push(_dhl()) : macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _inner.push(_dhl());
	}

	/**
	 * ω-blank-around-multiline-members — the three fragments that force a blank
	 * line into the gap between two adjacent members when either of them renders
	 * across more than one line.
	 *
	 * Why it cannot reuse the `multiline` predicate the module level already
	 * has: that one is resolved STRUCTURALLY at macro time from
	 * `@:fmt(multilineWhen…)` on the payload type, and a member has no such
	 * shape — `final a = ['x'];` and `final a = [… twenty …];` are the same
	 * node and differ only by width. So the question is asked of the built Doc
	 * instead, which forces the split into three splice points: the gap's
	 * position is known BEFORE the element is written, the answer only AFTER.
	 *
	 * `mark` records the insert index (ahead of the element's leading comments,
	 * so a doc-comment stays attached to its member); `seen` notes whether the
	 * source-driven rules already filled the gap, so the pass tops up to the
	 * knob rather than adding to it; `apply` measures both neighbours and
	 * splices the hardlines in at the recorded index.
	 *
	 * The measure is the runtime `anyparse.format.MemberGap.multiline` (ONE
	 * indent level of width), the same predicate the `member-order` check reads
	 * through `GrammarPlugin.memberGapPolicy`, so the check never demands a
	 * tight gap this pass would open again.
	 */
	private static function blankAroundMultilineExprs(optField: Null<String>): {
		final markExpr: Expr;
		final seenExpr: Expr;
		final applyExpr: Expr;
	} {
		if (optField == null) return { markExpr: macro {}, seenExpr: macro {}, applyExpr: macro {} };
		final knob: Expr = { expr: EField(macro opt, optField), pos: Context.currentPos() };
		return {
			// ONE `EVars` node, not `macro { var …; var …; }` — a reified block
			// is an `EBlock`, i.e. its own scope, and the two sibling splices
			// below would not see the vars.
			markExpr: {
				expr: EVars([
					{ name: '_bamAt', type: macro : Int, expr: macro _inner.length },
					{ name: '_bamHad', type: macro : Bool, expr: macro false }
				]),
				pos: Context.currentPos()
			},
			seenExpr: macro _bamHad = _inner.length > _bamAt,
			applyExpr: macro {
				if (_si > 0 && !_bamHad && $knob > 0) {
					if (
						anyparse.format.MemberGap.multiline(_elem, opt)
						|| (_priorElemDoc != null && anyparse.format.MemberGap.multiline(_priorElemDoc, opt))
					) {
						var _bami: Int = 0;
						while (_bami < $knob) {
							_inner.insert(_bamAt, _dhl());
							_bami++;
						}
					}
				}
			}
		};
	}

	/**
	 * ω-blank2: emit `_t.blankBefore2` extra hardlines — the blank lines
	 * beyond the first (already emitted for `blankBefore`) — via `pushExpr`.
	 * `blankBefore2` is `@:optional` on the trivia struct, so a construction
	 * site that never set it reads `null`, treated as zero. The Renderer caps
	 * the run at `opt.maxConsecutiveBlanks`, so an over-emit collapses back;
	 * this only widens a >1 source blank gap up to the configured maximum.
	 * References the runtime `_t`; splice right after the `blankBefore` push.
	 */
	private static function blankBefore2ExtrasExpr(pushExpr: Expr): Expr {
		return macro {
			final _bb2: Int = _t.blankBefore2 ?? 0;
			var _bbi: Int = 0;
			while (_bbi < _bb2) {
				$pushExpr;
				_bbi++;
			}
		};
	}

	/**
	 * The `arrowBodyLineWrap` emit for a lambda body: wrap `bodyCall` in the
	 * `_dwb(_dilr(...))` arrow-body marker, so at render time the body either stays
	 * glued to the arrow (while the line stays inside `opt.lineWidth`), or — under
	 * `opt.fitLineBodyGlue` on a hardline-free body — is rescued onto the
	 * continuation by `BodyFit.continuationRescuesArrowBody`, or else breaks after
	 * the arrow and nests one level.
	 *
	 * Shared verbatim by the Pratt infix `->` branch (`lowerInfixTightAssign`) and the
	 * bare-Ref field path (`emitBareRefNonBodyPolicy`).
	 */
	private static function arrowBodyLineWrapExpr(bodyCall: Expr): Expr {
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _doc: anyparse.core.Doc = $bodyCall;
			final _flat: Int = anyparse.format.wrap.WrapList.flatLength(_doc);
			_dwb(_dilr(
				opt.lineWidth,
				opt.fitLineBodyGlue && _flat >= 0
					? anyparse.format.BodyFit.continuationRescuesArrowBody(_cols, _doc, _flat, opt.lineWidth)
					: _dn(_cols, _dc([_dhl(), _doc])),
				_doc
			));
		};
	}

	/**
	 * omega-try-brace-symmetry: the leading separator a `catch` takes after a NON-block body. The
	 * unconditional `_dhl()` is haxe-formatter's statement-context convention and stays the default;
	 * naming a `BodyPolicy` knob adds the FitLine escape, so `} catch` cuddles while the line fits and
	 * breaks when it does not — the separator answering the same width question the body's own policy
	 * answers, so the two agree about whether the construct rendered flat.
	 */
	private static function bareSepBreak(policyField: Null<String>, sepExpr: Expr, softSeam: Bool): Expr {
		if (policyField == null) return macro _dhl();
		final policy: Expr = optFieldAccess(policyField);
		// Under `@:fmt(constructFitSep)` the seam is a SOFT line owned by the enclosing construct
		// group, so it breaks with the body's own seam rather than answering for itself. Asking here
		// is what put a flat ` catch` after a body that had already broken, which then squeezed the
		// body's call into a width it had to wrap inside.
		final flatSeam: Expr = softSeam ? macro _dl() : macro _dfle(opt.lineWidth, _dhl(), $sepExpr);
		return macro $policy == anyparse.format.BodyPolicy.FitLine ? $flatSeam : _dhl();
	}

	/**
	 * The `opt` expression threaded into the RIGHT operand's write call of a Pratt
	 * infix branch, or null when the branch flags no fanout.
	 *
	 * ω-arrow-body-objlit-pad: `@:fmt(propagateArrowLambdaBody)` on the infix `->`
	 * branch (HxExpr.ThinArrow) flags the RIGHT operand write. Composed outside
	 * `_setExprPosition` so its descent clear does not wipe the just-set flag. Left
	 * operand passes `opt` unchanged, so the flag survives leftmost descents —
	 * replicating the fork's token-adjacency (`{` directly after `->`) for free.
	 */
	private static function rightOperandOptExpr(branch: ShapeNode): Null<Expr> {
		final rightOptBase: Null<Expr> = branch.fmtHasFlag('propagateExprPosition') ? macro _setExprPosition(opt) : null;
		return branch.fmtHasFlag('propagateArrowLambdaBody') ? macro _setArrowLambdaBody(${rightOptBase ?? macro opt}, opt) : rightOptBase;
	}

	/**
	 * `@:writeNormalize('reindentBlock')` on a `@:rawString` terminal: emit the captured bytes as
	 * a run of LINES at the writer's own indent instead of one `_dt` whose embedded newlines
	 * splice the SOURCE indentation verbatim.
	 *
	 * A raw multi-line capture is byte-exact only while it stays where it was written. The one
	 * construct that needs it — a self-terminating `#if … ; #end` region that is the value of a
	 * `return` (`HxCondSpliceClosedRaw`) — MOVES: the writer glues the `#if` onto the `return`,
	 * which shifts every following line of the region one level left. Verbatim re-emission then
	 * leaves the body indented as if the `#if` were still on its own line, which is how admitting
	 * the shape turned the fork's `sameline/issue_54_return_sharp_multiple_passes` fixture from
	 * SKIP_PARSE into a round-trip FAIL.
	 *
	 * The transform keeps the first line verbatim (it follows the `#if` keyword on the same line)
	 * and re-emits each later line at the CURRENT indent plus its own indentation RELATIVE to the
	 * region: the longest common leading-whitespace prefix of those lines is the region's own base
	 * and is stripped, so `#elseif` / `#else` / `#end` land at the writer's indent and a branch
	 * body one deeper — exactly the fork's layout. Tab / space mixes are safe because the base is
	 * a common PREFIX, never a computed width. A blank line contributes no indentation evidence and
	 * is emitted empty, so it cannot leave trailing whitespace behind.
	 *
	 * A single-line capture is returned unchanged, which is every other site of this terminal.
	 */
	private static function reindentBlockEmit(): Expr {
		return macro {
			final _s: String = (cast value: String);
			if (_s.indexOf('\n') < 0) return _dt(_s);
			final _lines: Array<String> = _s.split('\n');
			var _base: Null<String> = null;
			for (_li in 1..._lines.length) {
				final _line: String = _lines[_li];
				var _w: Int = 0;
				while (_w < _line.length && (_line.charCodeAt(_w) == ' '.code || _line.charCodeAt(_w) == '\t'.code)) _w++;
				if (_w == _line.length) continue;
				final _ws: String = _line.substr(0, _w);
				final _seen: Null<String> = _base;
				if (_seen == null)
					_base = _ws
				else {
					var _k: Int = 0;
					while (_k < _seen.length && _k < _ws.length && _seen.charCodeAt(_k) == _ws.charCodeAt(_k)) _k++;
					_base = _seen.substr(0, _k);
				}
			}
			final _prefix: String = _base == null ? '' : _base;
			final _docs: Array<anyparse.core.Doc> = [_dt(_lines[0])];
			for (_li in 1..._lines.length) {
				final _line: String = _lines[_li];
				_docs.push(_dhl());
				_docs.push(_dt(StringTools.startsWith(_line, _prefix) ? _line.substr(_prefix.length) : StringTools.ltrim(_line)));
			}
			return _dc(_docs);
		};
	}

}
#end
