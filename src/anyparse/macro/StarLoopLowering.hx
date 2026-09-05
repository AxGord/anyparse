package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.ParseDispatchLowering.*;

/**
 * Pass 3 — the repetition-loop body and close-detection leaves.
 *
 * Two halves of one question: what does the BODY of one Star iteration
 * emit (the `@:tryparse` sep and no-sep bodies, the optional-`@:kw` Star
 * body and its horizontal-whitespace skip, the trivia close loop), and
 * how does that loop decide it has reached the CLOSE (the block-ended
 * byte check, the close peek, the termination check, the separator
 * match)?
 *
 * What is NOT here is the DISPATCH that picks between those shapes.
 * `emitStarFieldSteps`, `emitOptionalStarFieldSteps`,
 * `emitOptionalKwStarFieldSteps`, `emitTriviaStarFieldSteps`,
 * `emitNonTriviaCloseSteps` and the `lowerStar*Branch` family all read
 * the build's `LoweringCtx` and stay in `Lowering`, beside the
 * struct-field Star emitter they pair with — the four-site Star+sep
 * audit (`Lowering.emitStarFieldSteps` + Case 4, `WriterLowering`'s two)
 * keeps both of its `Lowering` halves in one file. Every member is
 * static and `Lowering` reaches them unqualified through
 * `import anyparse.macro.StarLoopLowering.*;` plus a class-level
 * `@:access`, so the move rewrote no call site.
 */
@:access(anyparse.macro.ParseDispatchLowering)
final class StarLoopLowering {

	private static function buildOptKwStarLoopBody(
		elemCT: ComplexType, elemCall: Expr, isTriviaCollects: Bool, sepText: Null<String>, branchTrail: Bool, trailBBLocal: String,
		trailLCLocal: String
	): Expr {
		final hWsSkip: Expr = buildOptKwStarHWsSkipExpr();
		// ω-cond-comp-branch-trail: on the terminating parse failure at
		// `#end`/`#elseif`/`#else`, an orphan own-line comment (no blank-line
		// separator) belongs to THIS branch body — capture it into the trailing
		// slots and advance past it (mirror of the `nestBody` catch) instead of
		// rewind+discard. Gated on `branchTrail` (`@:fmt(padTrailing)`).
		final triviaCatch: Expr = branchTrail
			? macro {
				if (!_lead.blankBefore && _lead.leadingComments.length > 0) {
					$i{trailBBLocal} = _lead.blankBefore;
					$i{trailLCLocal} = _lead.leadingComments;
					ctx.pos = _afterTriviaPos;
				} else {
					ctx.pos = _savedPos;
				}
				break;
			}
			: macro {
				ctx.pos = _savedPos;
				break;
			};
		return if (isTriviaCollects && sepText != null)
			macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					final _lead = collectTrivia(ctx);
					final _afterTriviaPos: Int = ctx.pos;
					try {
						final _node: $elemCT = $elemCall;
						final _trailingBeforeSep: Null<String> = collectTrailingFull(ctx);
						var _sepAfter: Bool = false;
						$hWsSkip;
						_sepAfter = matchLit(ctx, $v{sepText});
						final _trailing: Null<String> = _trailingBeforeSep ?? (_sepAfter ? collectTrailingFull(ctx) : null);
						_items.push({
							blankBefore: _lead.blankBefore,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							trailingBeforeSep: _trailingBeforeSep != null,
							sepAfter: _sepAfter,
							node: _node,
						});
					} catch (_e: anyparse.runtime.ParseError)
						$triviaCatch;
				}
			}
		else if (isTriviaCollects)
			macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					final _lead = collectTrivia(ctx);
					final _afterTriviaPos: Int = ctx.pos;
					try {
						final _node: $elemCT = $elemCall;
						final _trailing: Null<String> = collectTrailingFull(ctx);
						_items.push({
							blankBefore: _lead.blankBefore,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							trailingBeforeSep: false,
							sepAfter: true,
							node: _node,
						});
					} catch (_e: anyparse.runtime.ParseError)
						$triviaCatch;
				}
			}
		else if (sepText != null)
			macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					try {
						skipWs(ctx);
						_items.push($elemCall);
						$hWsSkip;
						matchLit(ctx, $v{sepText});
					} catch (_e: anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
				}
			}
		else
			macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					try {
						skipWs(ctx);
						_items.push($elemCall);
					} catch (_e: anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
				}
			};
	}

	private static function buildOptKwStarHWsSkipExpr(): Expr {
		return macro while (ctx.pos < ctx.input.length) {
			final _hwc: Int = ctx.input.charCodeAt(ctx.pos);
			if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code)
				ctx.pos++;
			else
				break;
		};
	}

	private static function buildTriviaTryparseSepBody(
		elemCT: ComplexType, elemCall: Expr, accumRef: Expr, sepText: String, trailPresentLocal: String, trailBBLocal: String,
		trailLCLocal: String, trailBALocal: String, nestBody: Bool, elemFirst: BranchFirstToken
	): Expr {
		// ω-blockended-trivia-tryparse (Session 3): `@:tryparse +
		// @:sep(text, tailRelax, blockEnded)` fork — permissive matchLit
		// on sep. Element-parse failure rewinds + breaks via the try/catch.
		// nestBody keeps the orphan-trail capture on parse failure.
		// ω-star-call-gate: every sep local is written only AFTER a
		// successful element parse, so a gate break leaves them exactly
		// where the catch arm would. Both exits splice the same `Expr`.
		final exitArm: Expr = nestBody
			? starNestExitArm(trailBBLocal, trailLCLocal, trailBALocal)
			: macro {
				ctx.pos = _savedPos;
				break;
			};
		final gate: Expr = starGateStep(elemFirst, exitArm);
		// ω-orphan-prefix-member: the sep twin of the no-sep loops' zero-width
		// guard. Here "no progress" means neither the element NOR the separator
		// consumed anything — a successful `matchLit` would have moved `ctx.pos`
		// past `_afterTriviaPos`, so reaching the push still parked there is the
		// whole test, and it also proves `_sepAfter` is false. Latent for every
		// grammar today (no element rule can match zero-width once `HxMemberDecl`
		// is excluded), placed because this loop family's only exit is a parse
		// failure and the module-scope twin of the member fix would arrive here.
		//
		// nestBody used to fork the whole loop, but the ONLY thing it varied was the
		// `_afterTriviaPos` declaration the guard now needs on both sides — every
		// other difference already travels through the spliced `$exitArm`. One body.
		return macro {
			while (true) {
				final _savedPos: Int = ctx.pos;
				final _lead = collectTrivia(ctx);
				final _afterTriviaPos: Int = ctx.pos;
				$gate;
				try {
					final _node: $elemCT = $elemCall;
					final _trailingBeforeSep: Null<String> = collectTrailingFull(ctx);
					var _sepAfter: Bool = false;
					while (ctx.pos < ctx.input.length) {
						final _hwc: Int = ctx.input.charCodeAt(ctx.pos);
						if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code)
							ctx.pos++;
						else
							break;
					}
					_sepAfter = matchLit(ctx, $v{sepText});
					final _trailing: Null<String> = _trailingBeforeSep ?? (_sepAfter ? collectTrailingFull(ctx) : null);
					$i{trailPresentLocal} = _sepAfter;
					if (ctx.pos == _afterTriviaPos) throw anyparse.runtime.ParseError.backtrack;
					$accumRef.push({
						blankBefore: _lead.blankBefore,
						blankBefore2: _lead.blankBefore2,
						blankAfterLeadingComments: _lead.blankAfterLeadingComments,
						newlineBefore: _lead.newlineBefore,
						leadingComments: _lead.leadingComments,
						trailingComment: _trailing,
						trailingBeforeSep: _trailingBeforeSep != null,
						sepAfter: _sepAfter,
						node: _node,
					});
				} catch (_e: anyparse.runtime.ParseError)
					$exitArm;
			}
		};
	}

	private static function buildTriviaTryparseNoSepBody(
		elemCT: ComplexType, elemCall: Expr, accumRef: Expr, trailBBLocal: String, trailLCLocal: String, trailBALocal: String,
		nestBody: Bool, branchTrail: Bool, elemFirst: BranchFirstToken
	): Expr {
		// Try-parse termination: each iteration saves `ctx.pos` before
		// `collectTrivia`, attempts the element parse, and rewinds to the
		// saved pos on failure so the captured trivia is fully uncaptured.
		// `@:fmt(nestBody)` Stars (case/default bodies) add a trailing-orphan
		// capture; the non-nestBody path carries the ω-keep-pratt-blank stash.
		if (nestBody) {
			// ω-star-call-gate: `collectTrivia` already ran OUTSIDE the try,
			// so the gate peeks exactly where the element parse would start,
			// and the orphan-trail bookkeeping is spliced from ONE `Expr`
			// into both the catch arm and the gate.
			final nestExitArm: Expr = starNestExitArm(trailBBLocal, trailLCLocal, trailBALocal);
			final nestGate: Expr = starGateStep(elemFirst, nestExitArm);
			return macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					final _lead = collectTrivia(ctx);
					final _afterTriviaPos: Int = ctx.pos;
					$nestGate;
					try {
						final _node: $elemCT = $elemCall;
						// ω-orphan-prefix-member: an element rule every one of whose
						// fields can be absent (a Seq of empty Stars plus an
						// `@:absentOn` Ref) parses successfully having consumed
						// NOTHING — and this loop's only exit is a parse failure, so
						// a zero-width success spins forever. Rethrowing the
						// backtrack sentinel routes it through the loop's own
						// termination path.
						if (ctx.pos == _afterTriviaPos) throw anyparse.runtime.ParseError.backtrack;
						final _trailing: Null<String> = collectTrailingFull(ctx);
						$accumRef.push({
							blankBefore: _lead.blankBefore,
							blankBefore2: _lead.blankBefore2,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							trailingBeforeSep: false,
							sepAfter: true,
							node: _node,
						});
					} catch (_e: anyparse.runtime.ParseError)
						$nestExitArm;
				}
			};
		}
		final nlAfterSepScan: Expr = buildPrattBlankNlAfterSepScan();
		final restoreStash: Expr = buildPrattBlankRestoreStash();
		// ω-cond-comp-branch-trail: for a `@:fmt(padTrailing)` conditional branch
		// body (no `#else` — the `#if` body Star before `#end`), capture the
		// orphan own-line trailing comment into the trail slots on the
		// terminating parse failure (mirror the nestBody branch) instead of
		// rewind+discard. Non-branchTrail Stars keep the plain rewind+stash.
		final nonNestCatch: Expr = branchTrail
			? macro {
				if (!_lead.blankBefore && _lead.leadingComments.length > 0) {
					$i{trailBBLocal} = _lead.blankBefore;
					$i{trailLCLocal} = _lead.leadingComments;
					ctx.pos = _leadStart;
				} else {
					ctx.pos = _savedPos;
					$restoreStash;
				}
				break;
			}
			: macro {
				ctx.pos = _savedPos;
				$restoreStash;
				break;
			};
		final nonNestGate: Expr = starGateStep(elemFirst, nonNestCatch);
		return macro {
			while (true) {
				final _savedPos: Int = ctx.pos;
				// ω-keep-pratt-blank: snapshot the incoming `pendingTrivia`
				// BEFORE `collectTrivia` drains it. On element-parse failure
				// the cursor rewinds to `_savedPos`, but `collectTrivia`
				// already nulled `pendingTrivia` — a stash-only blank-line
				// signal (left by a brace-terminated value's Pratt / postfix
				// no-op tail, living in bytes BEFORE `_savedPos` and NOT
				// re-scannable) would otherwise be lost. Restored on rollback
				// ONLY when the just-parsed value ended with `}`. See
				// `buildPrattBlankRestoreStash` for the brace-terminated rule.
				final _savedPending = ctx.pendingTrivia;
				final _lead = collectTrivia(ctx);
				// ω-keep-newline-after-sep (increment 1): `collectTrivia`
				// leaves the cursor at the element's first token — for a
				// `@:lead(LIT)`-prefixed link (e.g. `HxVarMore`'s
				// `@:lead(',')`) that token IS the separator literal.
				// Record it so we can probe the newline AFTER the
				// separator (before the link payload): `_lead.newlineBefore`
				// only sees the gap BEFORE the comma (usually empty —
				// `getRaw(read),`), while the source break the writer's
				// `Keep` wrap must reproduce lands `,\n  next`. Additive
				// (an `@:optional Trivial.newlineAfterSep` slot, read only
				// under `WrapMode.Keep`) → byte-inert for non-keep.
				final _leadStart: Int = ctx.pos;
				$nonNestGate;
				try {
					final _node: $elemCT = $elemCall;
					// ω-orphan-prefix-member: zero-width success guard — see the
					// nestBody arm above.
					if (ctx.pos == _leadStart) throw anyparse.runtime.ParseError.backtrack;
					final _trailing: Null<String> = collectTrailingFull(ctx);
					var _nlAfterSep: Bool = false;
					$nlAfterSepScan;
					$accumRef.push({
						blankBefore: _lead.blankBefore,
						blankBefore2: _lead.blankBefore2,
						blankAfterLeadingComments: _lead.blankAfterLeadingComments,
						newlineBefore: _lead.newlineBefore,
						leadingComments: _lead.leadingComments,
						trailingComment: _trailing,
						trailingBeforeSep: false,
						sepAfter: true,
						newlineAfterSep: _nlAfterSep,
						node: _node,
					});
				} catch (_e: anyparse.runtime.ParseError)
					$nonNestCatch;
			}
		};
	}

	private static function buildPrattBlankNlAfterSepScan(): Expr {
		// Skip the contiguous non-whitespace separator punctuation, then
		// OR-in any newline in the immediately-following whitespace run.
		return macro {
			var _nlScan: Int = _leadStart;
			while (_nlScan < ctx.input.length) {
				final _sc: Int = ctx.input.charCodeAt(_nlScan);
				if (_sc == ' '.code || _sc == '\t'.code || _sc == '\r'.code || _sc == '\n'.code) break;
				_nlScan++;
			}
			while (_nlScan < ctx.input.length) {
				final _wc: Int = ctx.input.charCodeAt(_nlScan);
				if (_wc == '\n'.code) {
					_nlAfterSep = true;
					break;
				}
				if (_wc != ' '.code && _wc != '\t'.code && _wc != '\r'.code) break;
				_nlScan++;
			}
		};
	}

	private static function buildPrattBlankRestoreStash(): Expr {
		// ω-keep-pratt-blank: restore the pre-iteration stash only when the
		// just-parsed value ended with `}` — scan back from `_savedPos` past
		// trailing whitespace to the last content byte. Brace-terminated →
		// preserve the source blank to the next sibling (issue_644 /
		// typedef_fields); otherwise keep the baseline drop (issue_216).
		return macro {
			if (_savedPending != null) {
				var _bpRew: Int = _savedPos - 1;
				while (_bpRew > 0) {
					final _bpc: Int = ctx.input.charCodeAt(_bpRew);
					if (_bpc == ' '.code || _bpc == '\t'.code || _bpc == '\n'.code || _bpc == '\r'.code)
						_bpRew--;
					else
						break;
				}
				if (_bpRew >= 0 && ctx.input.charCodeAt(_bpRew) == '}'.code) ctx.pendingTrivia = _savedPending;
			}
		};
	}

	private static function buildTriviaCloseTerminationCheck(closeText: Null<String>): Expr {
		if (closeText == null) return macro ctx.pos >= ctx.input.length;
		// See emitStarFieldSteps for why we flip to full-string `peekLit` when
		// close is multi-byte (single-byte peek false-positives when close's
		// first byte can legitimately appear inside element content).
		final closeCharCode: Int = closeText.charCodeAt(0);
		return closeText.length == 1
			? macro ctx.pos >= ctx.input.length || ctx.input.charCodeAt(ctx.pos) == $v{closeCharCode}
			: macro ctx.pos >= ctx.input.length || peekLit(ctx, $v{closeText});
	}

	private static function buildTriviaCloseSepMatchExpr(sepText: Null<String>, trailPresentLocal: String): Expr {
		// ω-trivia-sep: when the trivia Star carries `@:sep`, an optional
		// separator is matched after each element. The pre-sep horizontal-
		// whitespace skip avoids consuming newlines / comments (`skipWs` would
		// swallow the trailing `// comment` before `collectTrailing` could see
		// it). Sep-less Stars get a no-op.
		return sepText != null
			? macro {
				while (ctx.pos < ctx.input.length) {
					final _hwc: Int = ctx.input.charCodeAt(ctx.pos);
					if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code)
						ctx.pos++;
					else
						break;
				}
				_sepAfter = matchLit(ctx, $v{sepText});
				$i{trailPresentLocal} = _sepAfter;
			}
			: macro {};
	}

	private static function buildTriviaCloseLoopBody(
		elemCT: ComplexType, elemCall: Expr, accumRef: Expr, terminationCheck: Expr, sepMatchExpr: Expr, trailBBLocal: String,
		trailNLLocal: String, trailLCLocal: String
	): Expr {
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
		return macro {
			while (true) {
				final _lead = collectTrivia(ctx);
				if ($terminationCheck) {
					$i{trailBBLocal} = _lead.blankBefore;
					// ω-keep-fnsig-newline: capture the close-newline alongside
					// the close-blank so a kept signature reproduces a glued vs
					// own-line close.
					$i{trailNLLocal} = _lead.newlineBefore;
					$i{trailLCLocal} = _lead.leadingComments;
					break;
				}
				final _node: $elemCT = $elemCall;
				final _trailingBeforeSep: Null<String> = collectTrailingFull(ctx);
				var _sepAfter: Bool = true;
				$sepMatchExpr;
				final _trailing: Null<String> = _trailingBeforeSep ?? (_sepAfter ? collectTrailingFull(ctx) : null);
				$accumRef.push({
					blankBefore: _lead.blankBefore,
					blankBefore2: _lead.blankBefore2,
					blankAfterLeadingComments: _lead.blankAfterLeadingComments,
					newlineBefore: _lead.newlineBefore,
					leadingComments: _lead.leadingComments,
					trailingComment: _trailing,
					trailingBeforeSep: _trailingBeforeSep != null,
					sepAfter: _sepAfter,
					node: _node,
				});
			}
		};
	}

	private static function buildTryparseSepLoop(
		elemCall: Expr, accumRef: Expr, sepCharCode: Int, sepBlockEnded: Bool, predicateCall: Expr, elemFirst: BranchFirstToken
	): Expr {
		// Try-parse with sep peek. After each successful element,
		// peeks the next non-whitespace char: if it equals the sep, consumes
		// it and continues; otherwise breaks. On element-parse fail, rewinds
		// to `_savedPos` (taken BEFORE `skipWs`) so the enclosing close sees
		// the pre-whitespace position. The block-ended variant additionally
		// tolerates an omitted sep when the prior element ended with `;` (or
		// the schema predicate matches).
		// ω-star-call-gate: the sep bookkeeping all runs AFTER a successful
		// element parse, so breaking at the gate leaves every sep local
		// exactly where the catch arm would — the two exits share one
		// spliced `Expr`.
		final exitArm: Expr = macro {
			ctx.pos = _savedPos;
			break;
		};
		final gate: Null<Expr> = starGateExpr(elemFirst, exitArm);
		final elemStep: Expr = gate == null
			? macro {
				try {
					skipWs(ctx);
					$accumRef.push($elemCall);
				} catch (_e: anyparse.runtime.ParseError)
					$exitArm;
			}
			: macro {
				skipWs(ctx);
				$gate;
				try {
					$accumRef.push($elemCall);
				} catch (_e: anyparse.runtime.ParseError)
					$exitArm;
			};
		return sepBlockEnded
			? macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					$elemStep;
					final _prevEndPos: Int = ctx.pos;
					skipWs(ctx);
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
					if (_isBE) continue;
					if (ctx.pos >= ctx.input.length || ctx.input.charCodeAt(ctx.pos) != $v{sepCharCode}) break;
					ctx.pos++;
				}
			}
			: macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					$elemStep;
					skipWs(ctx);
					if (ctx.pos >= ctx.input.length || ctx.input.charCodeAt(ctx.pos) != $v{sepCharCode}) break;
					ctx.pos++;
				}
			};
	}

	private static function buildCloseBlockEndedBody(
		elemCall: Expr, accumRef: Expr, closeNotNextExpr: Expr, sepCharCode: Int, sepText: String, predicateCall: Expr,
		sepStartsElement: Bool
	): Expr {
		// Block-ended exemption: after a successful element, sep may be
		// omitted if the element ended with `}` / `;` (byte-level check on
		// `_prevEndPos - 1`) — or, when the predicate matches. Tail-relax
		// (trailing sep tolerated before close) is folded in. `sepStartsElement`
		// flips byte-ambiguity policy: when block-ended is TRUE, the sep byte
		// at pos belongs to the NEXT element, never a separator (needed where
		// the sep char can ALSO be a valid element body — Haxe `EmptyStmt`).
		final beCheck: Expr = buildBlockEndedByteCheck(predicateCall);
		return sepStartsElement
			? macro {
				skipWs(ctx);
				if ($closeNotNextExpr) {
					var _prevEndPos: Int = ctx.pos;
					$accumRef.push($elemCall);
					_prevEndPos = ctx.pos;
					skipWs(ctx);
					while ($closeNotNextExpr) {
						final _isBE: Bool = $beCheck;
						if (_isBE) {
							// block-ended: sep byte at pos belongs to next element
							$accumRef.push($elemCall);
							_prevEndPos = ctx.pos;
							skipWs(ctx);
						} else if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
							ctx.pos++;
							skipWs(ctx);
							if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
							$accumRef.push($elemCall);
							_prevEndPos = ctx.pos;
							skipWs(ctx);
						} else {
							expectLit(ctx, $v{sepText}); // throws expected-sep
						}
					}
				}
			}
			: macro {
				skipWs(ctx);
				if ($closeNotNextExpr) {
					var _prevEndPos: Int = ctx.pos;
					$accumRef.push($elemCall);
					_prevEndPos = ctx.pos;
					skipWs(ctx);
					while ($closeNotNextExpr) {
						if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
							ctx.pos++;
							skipWs(ctx);
							if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
							$accumRef.push($elemCall);
							_prevEndPos = ctx.pos;
							skipWs(ctx);
						} else if ($beCheck) {
							// Block-ended: prior element ended with `;`
							// (byte-check after walking back over
							// whitespace — covers stmts whose own
							// `@:trailOpt(';')` consumed `;` and then
							// the trailing `skipWs` advanced past it)
							// or the AST-shape predicate returned true.
							// No sep needed; parse next.
							$accumRef.push($elemCall);
							_prevEndPos = ctx.pos;
							skipWs(ctx);
						} else {
							expectLit(ctx, $v{sepText}); // throws expected-sep
						}
					}
				}
			};
	}

	private static function buildBlockEndedByteCheck(predicateCall: Expr): Expr {
		// `true` iff the just-parsed element is block-ended: scan back from
		// `_prevEndPos` over trailing whitespace to the last content byte and
		// accept `;` (covers stmts whose own `@:trailOpt(';')` consumed the
		// terminator), or the schema predicate matches.
		return macro _prevEndPos > 0 && {
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
	}

	private static function buildClosePeekBody(elemCall: Expr, accumRef: Expr, closeNotNextExpr: Expr, sepText: Null<String>): Expr {
		// Close-peek loop: parse elements until the close literal is the next
		// non-whitespace token. With `@:sep`, consume one separator between
		// elements and tolerate a trailing sep before the close.
		if (sepText == null) return macro {
			skipWs(ctx);
			while ($closeNotNextExpr) {
				$accumRef.push($elemCall);
				skipWs(ctx);
			}
		};
		final sepCharCode: Int = sepText.charCodeAt(0);
		return macro {
			skipWs(ctx);
			if ($closeNotNextExpr) {
				$accumRef.push($elemCall);
				skipWs(ctx);
				// Permissive sep (ω-span-sep-permissive) — see
				// lowerStarSepBranch for rationale; same trivia-loop
				// alignment applied to the field-Star close loop
				// (fn params, new-expr args).
				while ($closeNotNextExpr) {
					if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
					}
					$accumRef.push($elemCall);
					skipWs(ctx);
				}
			}
		};
	}

	private static function emitSepBeforeOptStep(localName: String, parseSteps: Array<Expr>, sepCharCode: Int): Void {
		// `@:fmt(sepBeforeOpt)` opt-in: BEFORE entering the
		// element loop, peek-and-consume a single leading sep INSIDE the body
		// (between enclosing kw and first element). Captures true/false into
		// `<localName>SepBefore` for the writer's padLeading runtime gate to
		// re-emit the leading sep.
		final sepBeforeLocal: String = '${localName}SepBefore';
		parseSteps.push({
			expr: EVars([
				{
					name: sepBeforeLocal,
					type: macro :Bool,
					expr: macro false,
					isFinal: false
				}
			]),
			pos: Context.currentPos()
		});
		parseSteps.push(macro {
			final _savedPos: Int = ctx.pos;
			skipWs(ctx);
			if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
				ctx.pos++;
				$i{sepBeforeLocal} = true;
			} else {
				ctx.pos = _savedPos;
			}
		});
	}

}
#end
