package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;

/**
 * Pass 3 — the operator-loop emit leaves (`@:infix` Pratt, `@:postfix`).
 *
 * One question, asked of a loop whose iteration count is decided by an
 * OPERATOR rather than by a separator: what does the loop emit on the
 * paths where the operator does not match — the no-match handler, the
 * scan-back that rewinds a speculative trivia read, the position-restore
 * guard for the plain word-operator path — and what trivia bookkeeping
 * does one iteration owe (`@:blank` newline scans, the stash
 * save/restore, the call-argument trivia loop)?
 *
 * `collectAllOps` sits here for the same reason: it is the operator
 * inventory both loops dispatch on, and it reads nothing but the
 * annotations already on the branch.
 *
 * The loop's own SHAPE decisions stay in `Lowering` — `lowerPrattLoop`,
 * `lowerPostfixLoop`, `buildPrattLoopExpr`, `buildPostfixLoopExpr` and
 * the suffix branches all read the build's `LoweringCtx`, so what moved
 * here is the leaf emission below them. Every member is static and
 * `Lowering` reaches them unqualified through
 * `import anyparse.macro.OperatorLoopLowering.*;` plus a class-level
 * `@:access`, so the move rewrote no call site.
 */
final class OperatorLoopLowering {

	private static function buildPrattNoMatchHandlerExpr(): Expr {
		return macro if (!_matched) {
			var _scanI: Int = _preWsPos;
			var _hadComment: Bool = false;
			var _hadNewline: Bool = false;
			// ω-keep-pratt-blank: track a blank line (≥2 newlines with
			// only horizontal whitespace between them) inside the
			// Pratt-consumed run, mirroring `collectTrivia`'s `_nl >= 2`
			// semantics so the source-blank signal survives the no-op
			// tail loop the same way the single-newline signal does.
			var _nlRun: Int = 0;
			var _hadBlank: Bool = false;
			while (_scanI < ctx.pos) {
				final _ch: Int = ctx.input.charCodeAt(_scanI);
				if (_ch == '\n'.code) {
					_hadNewline = true;
					_nlRun++;
					if (_nlRun >= 2) _hadBlank = true;
				} else if (_ch != ' '.code && _ch != '\t'.code && _ch != '\r'.code) {
					_nlRun = 0;
				}
				if (_ch == '/'.code && _scanI + 1 < ctx.pos) {
					final _c2: Int = ctx.input.charCodeAt(_scanI + 1);
					if (_c2 == '/'.code || _c2 == '*'.code) {
						_hadComment = true;
						break;
					}
				}
				_scanI++;
			}
			if (_hadComment) {
				ctx.pos = _preWsPos;
				final _pt = ctx.pendingTrivia;
				if (_pt != null) {
					while (_pt.leadingComments.length > _stashCount0) _pt.leadingComments.pop();
				}
			} else if (_hadNewline) {
				// ω-untyped-keep: when no operator matches AND the consumed
				// WS contained a newline (no comment, no rewind), stash the
				// newline signal into `pendingTrivia` so the next sibling's
				// `collectTrivia` drain captures `newlineBefore=true`. Without
				// this, Pratt silently consumes the newline and downstream
				// `bodyBeforeNewline` slots never fire (e.g. function-body
				// `untyped` after `:Type\n\tuntyped {…}` — the body field's
				// pre-field collectTrivia sees pos already past the `\n`).
				// ω-keep-pratt-blank: also carry `blankBefore` when the run
				// held a blank line, so a `var b = function(){…}\n\nfinal a`
				// brace-terminated `@:trailOpt(';')`-absent decl preserves
				// its source blank line (issue_644). Without this the bit was
				// hardcoded `false` and the blank collapsed to a single `\n`.
				final _pt = ctx.pendingTrivia;
				if (_pt == null) {
					ctx.pendingTrivia = {
						blankBefore: _hadBlank,
						blankAfterLeadingComments: false,
						newlineBefore: true,
						leadingComments: [],
					};
				} else {
					_pt.newlineBefore = true;
					if (_hadBlank) _pt.blankBefore = true;
				}
			}
			break;
		};
	}

	private static function buildPostfixCallArgsTriviaLoop(
		elemCT: ComplexType, elemCall: Expr, wrappedCT: ComplexType, closeNotNextExpr: Expr, sepCharCode: Int, sepText: String,
		close: String, ctorCallTrivia: Expr
	): Expr {
		// noqa: complexity
		// Per-element loop: leading-trivia → close-peek break → parse →
		// multi-line trailing scan → matchLit(sep). Trailing comments are
		// captured up to the next sep or close, even across newlines
		// (mirrors fork's `arg \n /* c */, b` interpretation: the comment
		// is trailing-of-arg, not leading-of-next). Sep-after-newline
		// (`arg\n,bar`) tolerance: when the post-sweep position landed past
		// `\n` whitespace and no comments need preserving, KEEP that swept
		// position so `matchLit(sep)` finds the sep; only when the sweep
		// yielded comments NOT at sep do we rewind for the next iter's `_lead`.
		return macro {
			// ω-D9A-keep-callargs-v2: capture source-vertical signal
			// BEFORE per-iter `skipWs`/`collectTrivia` so the
			// post-open `\n` is preserved as a dedicated bool slot.
			// Reading `Trivial.newlineBefore` for args[0] would be
			// polluted by `ctx.pendingTrivia` drained from upstream
			// kw-Ref rules (see project_phase3_slice_d9a_revert).
			// `_openPos` sits right after the outer postfix
			// dispatch consumed the open lit (e.g. `(`); after
			// `skipWs(ctx)` `ctx.pos` lands at the first
			// non-whitespace byte, so the byte range covers exactly
			// the post-open inter-token whitespace.
			final _openPos: Int = ctx.pos;
			// ω-callarg-empty-inner-comment: skip only whitespace (not comments)
			// before the args loop, so the loop's `collectTrivia` can capture a
			// leading comment on the first argument or an empty-parens inner
			// comment. For comment-free calls this lands at the identical byte
			// `skipWs` did, keeping the `argsOpenNewline` signal byte-identical.
			while (ctx.pos < ctx.input.length) {
				final _wc: Int = ctx.input.charCodeAt(ctx.pos);
				if (_wc == ' '.code || _wc == '\t'.code || _wc == '\n'.code || _wc == '\r'.code) {
					ctx.pos++;
					continue;
				}
				break;
			}
			final _argsOpenNewline: Bool = hasNewlineIn(ctx.input, _openPos, ctx.pos);
			var _argsInnerComment: Null<String> = null;
			// ω-keep-call-leading-comment: a pre-callee inline block comment leaked
			// into `ctx.pendingTrivia` by the upstream operator/keyword
			// `skipWsAndStash` (`a * /* c */ f()`, `/* c */ f()`) would otherwise be
			// drained by this loop's `collectTrivia` into args[0]'s leading / the
			// inner slot — relocating it INSIDE the parens. Claim it here, BEFORE
			// the loop, so the writer emits it before the operand. Only inline block
			// comments (mirrors the argsInnerComment gate); a line / multi-line
			// block stays in pendingTrivia (existing drop behavior, unchanged). The
			// newline / blank signals on pendingTrivia are preserved for args[0].
			var _callLeadingComment: Null<String> = null;
			{
				final _clPending = ctx.pendingTrivia;
				if (_clPending != null && _clPending.leadingComments.length > 0) {
					var _clInline: Bool = true;
					for (_c in _clPending.leadingComments) if (!StringTools.startsWith(_c, '/*') || _c.indexOf('\n') >= 0)
						_clInline = false;
					if (_clInline) {
						_callLeadingComment = _clPending.leadingComments.join(' ');
						while (_clPending.leadingComments.length > 0) _clPending.leadingComments.pop();
					}
				}
			}
			final _args: Array<$wrappedCT> = [];
			// ω-keep-callclose-newline: source-vertical signal for the
			// gap before the postfix close literal. `collectTrivia`'s
			// final iteration (the close-peek break) reports whether a
			// newline preceded the close in `_lead.newlineBefore`
			// (`arg\n)` vs `arg)`). Captured on the break and threaded
			// to the writer's Keep-mode chain close placement. Default
			// `false` for the never-iterated impossible path.
			var _argsCloseNewline: Bool = false;
			while (true) {
				final _lead = collectTrivia(ctx);
				if (!($closeNotNextExpr)) {
					_argsCloseNewline = _lead.newlineBefore;
					// ω-callarg-empty-inner-comment: an empty argument list whose
					// only content is a comment (`f(/* c */)`) — the comment
					// captured by `collectTrivia` belongs to no argument. Route it
					// to the inner-comment slot so the writer emits it between the
					// open and close literals. Only inline block comments are
					// captured (mirrors the ω-callarg-leading-comment gate): a
					// line comment or multi-line block would be emitted inline
					// before `)` and swallow it, producing unparseable output.
					if (_args.length == 0 && _lead.leadingComments.length > 0) {
						var _icInline: Bool = true;
						for (_c in _lead.leadingComments) if (!StringTools.startsWith(_c, '/*') || _c.indexOf('\n') >= 0) _icInline = false;
						if (_icInline) _argsInnerComment = _lead.leadingComments.join(' ');
					}
					break;
				}
				final _node: $elemCT = $elemCall;
				var _trailing: Null<String> = null;
				// Step 1: same-line trail capture. Returns
				// captured slice with delimiters or null.
				final _sameLine: Null<String> = collectTrailingFull(ctx);
				if (_sameLine != null) _trailing = _sameLine;
				// Step 2: multi-line trail look-ahead.
				final _preSweepPos: Int = ctx.pos;
				final _swept = collectTrivia(ctx);
				final _atSep: Bool = ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode};
				if (_atSep && _swept.leadingComments.length > 0) {
					final _addl: String = _swept.leadingComments.join('\n');
					_trailing = _trailing != null ? _trailing + '\n' + _addl : _addl;
				} else if (_swept.leadingComments.length > 0) {
					// Comments belong to next iter's _lead —
					// rewind so they're re-captured (and to
					// avoid losing them through `matchLit`'s
					// no-skip behaviour).
					ctx.pos = _preSweepPos;
				}
				// Else: no comments swept — keep cursor at
				// post-sweep pos. This crosses `\n` and any
				// horizontal ws, so `matchLit(sep)` finds a
				// sep on a different line than the arg
				// (`arg\n,bar`) — fork-supported pattern.
				final _sepAfter: Bool = matchLit(ctx, $v{sepText});
				// ω-callarg-after-sep-comment: a same-line comment sitting AFTER
				// the separator (`arg, // note`) belongs to THIS argument's line,
				// not to the next argument it would otherwise reach as a leading
				// comment. Restricted to LINE style: a `//` in a leading slot is
				// unemittable inline (it would swallow the argument that follows)
				// and was silently DROPPED, so claiming it here is pure recovery.
				// A block comment after the separator already round-trips through
				// the next element's leading slot (`f(a, /* c */ b)`) — leaving it
				// there keeps every existing layout byte-identical.
				final _postSepPos: Int = ctx.pos;
				final _afterSepRaw: Null<String> = _sepAfter && _trailing == null ? collectTrailingFull(ctx) : null;
				final _afterSep: Null<String> = _afterSepRaw != null && StringTools.startsWith(_afterSepRaw, '//') ? _afterSepRaw : null;
				if (_afterSep == null)
					ctx.pos = _postSepPos
				else
					_trailing = _afterSep;
				_args.push({
					blankBefore: _lead.blankBefore,
					blankBefore2: _lead.blankBefore2,
					blankAfterLeadingComments: _lead.blankAfterLeadingComments,
					newlineBefore: _lead.newlineBefore,
					leadingComments: _lead.leadingComments,
					trailingComment: _trailing,
					trailingBeforeSep: _afterSep == null,
					sepAfter: _sepAfter,
					node: _node,
				});
			}
			skipWs(ctx);
			expectLit(ctx, $v{close});
			// Capture trailing comment between `close` and the
			// next postfix iteration's leading trivia. Same-line
			// only — multi-line look-ahead would steal comments
			// belonging to the next chain segment's `_lead` slot
			// (or to the enclosing statement's trailing slot
			// when the chain ends here). The Pratt loop's
			// outer skipWs-rewind handles the chain-end case
			// (no postfix matches → rewind on `_hadComment`).
			final _trailClose: Null<String> = collectTrailingFull(ctx);
			left = $ctorCallTrivia;
		};
	}

	private static function buildPostfixNoMatchScanback(): Expr {
		// ω-cond-comp-expr-multiline / ω-keep-pratt-blank: when no postfix op
		// matched, scan the `[_preWsPos, ctx.pos)` run consumed by the last
		// skipWs. A comment rewinds to `_preWsPos` so the enclosing loop
		// re-captures it; a bare newline (or a blank line, ≥2 newlines) is
		// stashed into `ctx.pendingTrivia` so downstream `collectTrivia` reads
		// the source-vertical signal the postfix loop otherwise drops.
		return macro {
			var _scanI: Int = _preWsPos;
			var _hadComment: Bool = false;
			var _hadNewline: Bool = false;
			// ω-keep-pratt-blank: mirror the Pratt-loop blank tracking —
			// a blank line (≥2 newlines separated only by horizontal
			// whitespace) inside the postfix-consumed run must survive
			// the no-op tail so a brace-terminated value followed by a
			// blank line (`var b = function(){…}\n\nfinal a`, issue_644)
			// carries `blankBefore` to the next decl's `collectTrivia`.
			var _nlRun: Int = 0;
			var _hadBlank: Bool = false;
			while (_scanI < ctx.pos) {
				final _ch: Int = ctx.input.charCodeAt(_scanI);
				if (_ch == '\n'.code) {
					_hadNewline = true;
					_nlRun++;
					if (_nlRun >= 2) _hadBlank = true;
				} else if (_ch != ' '.code && _ch != '\t'.code && _ch != '\r'.code) {
					_nlRun = 0;
				}
				if (_ch == '/'.code && _scanI + 1 < ctx.pos) {
					final _c2: Int = ctx.input.charCodeAt(_scanI + 1);
					if (_c2 == '/'.code || _c2 == '*'.code) {
						_hadComment = true;
						break;
					}
				}
				_scanI++;
			}
			if (_hadComment) {
				ctx.pos = _preWsPos;
			} else if (_hadNewline) {
				final _pt = ctx.pendingTrivia;
				if (_pt == null) {
					ctx.pendingTrivia = {
						blankBefore: _hadBlank,
						blankAfterLeadingComments: false,
						newlineBefore: true,
						leadingComments: [],
					};
				} else {
					_pt.newlineBefore = true;
					if (_hadBlank) _pt.blankBefore = true;
				}
			}
		};
	}

	private static function collectAllOps(node: ShapeNode): Array<String> {
		// Cross-category longer-prefix resolution: a postfix op that is a
		// strict prefix of another op in the same enum (postfix, infix, or
		// ternary) must lose to that longer op. Collecting ALL op literals on
		// the enum lets us emit a `!peekLit(longer)` guard per conflict so the
		// postfix dispatch declines and Pratt picks up the longer op.
		final allOps: Array<String> = [];
		for (b in node.children) {
			final po: Null<String> = b.annotations.get(AnnotationKeys.POSTFIX_OP);
			if (po != null) allOps.push(po);
			final pr: Null<String> = b.annotations.get(AnnotationKeys.PRATT_OP);
			if (pr != null) allOps.push(pr);
			final tr: Null<String> = b.annotations.get(AnnotationKeys.TERNARY_OP);
			if (tr != null) allOps.push(tr);
		}
		return allOps;
	}

	private static function buildPostfixSingleBranch(close: Null<String>, ctorRef: Expr): Expr {
		final ctorCall: Expr = { expr: ECall(ctorRef, [macro left]), pos: Context.currentPos() };
		return close == null
			? macro {
				left = $ctorCall;
			}
			: macro {
				skipWs(ctx);
				expectLit(ctx, $v{close});
				left = $ctorCall;
			};
	}

	/**
	 * ω-cond-splice: no-match position-restore guard for the plain
	 * Pratt/postfix loops. Restores `ctx.pos` to the pre-skipWs save iff
	 * the next token is one of the enum's WORD-LIKE op literals (`#if`)
	 * — those dispatch on a same-line gate that needs the operand↔op gap
	 * intact when an enclosing loop re-probes. Empty/absent word-op set
	 * emits `{}` — grammars without word ops keep the historical
	 * consumed-whitespace exit byte-for-byte (string-interpolation `@:raw`
	 * siblings depend on it).
	 */
	private static function buildWordOpRestoreExpr(wordOps: Null<Array<String>>): Expr {
		if (wordOps == null || wordOps.length == 0) return macro {};
		var cond: Null<Expr> = null;
		for (op in wordOps) {
			final peek: Expr = macro peekKw(ctx, $v{op});
			cond = cond == null ? peek : macro $cond || $peek;
		}
		return macro if ($cond) ctx.pos = _preWsPos;
	}

}
#end
