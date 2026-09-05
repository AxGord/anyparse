package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.ParseDispatchLowering.*;

using anyparse.macro.MetaInspect;

/**
 * Pass 3 — the Alt branches whose head is a KEYWORD or a LITERAL.
 *
 * One question: an Alt branch commits on a fixed word or a fixed literal
 * at its head — what parse steps does it emit? Four shapes answer it:
 * Case 0 (zero-arg ctor with `@:kw`), Case 1 (zero-arg ctor with a single
 * `@:lit`), Case 2 (single-arg ctor whose `@:lit` list maps to an
 * identifier), and the `@:kwRef` branch's lead / trail / ctor / negative
 * lookahead steps.
 *
 * The Star-headed branches deliberately did NOT come along:
 * `lowerStarBranch` and its five shape helpers are the enum-ctor half of
 * the four-site Star+sep audit and stay in `Lowering` next to
 * `emitStarFieldSteps`, its struct-field half.
 *
 * Every member is static and `Lowering` reaches them unqualified through
 * `import anyparse.macro.KwBranchLowering.*;` plus a class-level
 * `@:access`, so the move rewrote no call site.
 */
@:access(anyparse.macro.ParseDispatchLowering)
final class KwBranchLowering {

	/**
	 * Case 0: zero-arg ctor with `@:kw` (no `@:lit`). Emits `expectKw` with
	 * word-boundary enforcement; when `@:trail` is present the trail literal
	 * is emitted unconditionally after the keyword (D48).
	 */
	private static function lowerKwZeroArgBranch(branch: ShapeNode, ctorRef: Expr, kwLeadBranch: String): Expr {
		final trailBranch: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		return trailBranch != null
			? macro {
				skipWs(ctx);
				expectKw(ctx, $v{kwLeadBranch});
				skipWs(ctx);
				expectLit(ctx, $v{trailBranch});
				return $ctorRef;
			}
			: macro {
				skipWs(ctx);
				expectKw(ctx, $v{kwLeadBranch});
				return $ctorRef;
			};
	}

	/**
	 * Case 1: zero-arg ctor with `@:lit(single)`. A word-ending literal
	 * routes through the word-boundary-checking `expectKw`; a symbolic
	 * literal through plain `expectLit`.
	 */
	private static function lowerSingleLitBranch(ctorRef: Expr, lit: String): Expr {
		final expectCall: Expr = endsWithWordChar(lit) ? macro expectKw(ctx, $v{lit}) : macro expectLit(ctx, $v{lit});
		return macro {
			skipWs(ctx);
			$expectCall;
			return $ctorRef;
		};
	}

	/**
	 * Case 2: single-arg ctor with `@:lit(multi)` — literals map to ident
	 * values of the field type. Each literal dispatches via `matchKw` (word-
	 * like set) or `matchLit` (symbolic set); a mixed set is rejected at
	 * macro time.
	 */
	private static function lowerMultiLitBranch(ctorRef: Expr, litList: Array<String>): Expr {
		final wordLike: Bool = endsWithWordChar(litList[0]);
		for (lit in litList) {
			if (endsWithWordChar(lit) != wordLike) {
				Context.fatalError(
					'Lowering: multi-@:lit set mixes word-like and symbolic literals: ${litList.join(', ')}', Context.currentPos()
				);
			}
		}
		final matchFnName: String = wordLike ? 'matchKw' : 'matchLit';
		final attempts: Array<Expr> = [];
		for (lit in litList) {
			final valueExpr: Expr = { expr: EConst(CIdent(lit)), pos: Context.currentPos() };
			final call: Expr = { expr: ECall(ctorRef, [valueExpr]), pos: Context.currentPos() };
			final matchCall: Expr = {
				expr: ECall(macro $i{matchFnName}, [macro ctx, macro $v{lit}]),
				pos: Context.currentPos()
			};
			attempts.push(macro if ($matchCall) return $call);
		}
		final failExpr: Expr = macro throw anyparse.runtime.ParseError.backtrack;
		final body: Array<Expr> = [macro skipWs(ctx)].concat(attempts).concat([failExpr]);
		return macro $b{body};
	}

	/**
	 * Branch-level `@:rejectFollowKw('<kw>')`: a negative lookahead that makes an
	 * otherwise-successful branch backtrack when the named keyword is the next token.
	 *
	 * The case it exists for is a branch whose trailing `@:tryparse` Star can legally
	 * match ZERO elements. Such a branch reports success on input the NEXT branch was
	 * meant to take, and `tryBranch` never gets to roll back — it only rolls back on
	 * failure. `HxStatement.TryCatchStmt` is exactly that shape: `catches` is a
	 * `@:tryparse` Star and a catch-less `try {…}` is valid Haxe, so a `try` whose
	 * catch bodies are bare expressions (`catch (e:E) f(e) catch (e2:F) g(e2);` — no
	 * `;` before the second `catch`, hence no `HxStatement` to match) parsed as a
	 * catch-less try and left the `catch` chain for the enclosing block, which fails.
	 * Rejecting a following `catch` hands that input to `TryCatchStmtBare`, whose
	 * `HxExpr` bodies do match it.
	 *
	 * The peek runs on a saved position that is restored either way: the branch either
	 * throws, or returns with `ctx.pos` exactly where the parse left it, so the trivia
	 * scan of whatever comes next is unaffected.
	 */
	private static function appendRejectFollowKwStep(steps: Array<Expr>, branch: ShapeNode): Void {
		final rejectKw: Null<String> = branch.readMetaString(':rejectFollowKw');
		if (rejectKw == null) return;

		steps.push(macro {
			final _rejectPos: Int = ctx.pos;
			skipWs(ctx);
			final _rejectHit: Bool = peekKw(ctx, $v{rejectKw});
			ctx.pos = _rejectPos;
			if (_rejectHit) throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/**
	 * Append the kw/lead literal-consume steps (plus the trivia-mode newline
	 * / source-position probes) to a `lowerKwRefBranch` step list. Either or
	 * both of kw and lead may be absent.
	 */
	private static function appendKwRefLeadSteps(
		steps: Array<Expr>, kwLead: Null<String>, leadText: Null<String>, triviaKwNewline: Bool, triviaBodyPolicyKw: Bool,
		forwardNewlineForBody: Bool, triviaWrapOpenNewline: Bool
	): Void {
		// ω-keep-kw-newline (increment 1b): track the byte position right
		// after the LAST consumed keyword / lead literal (BEFORE its post-
		// literal `skipWs`) so the `_varKwNewline` probe spans the gap up to
		// the inner `decl` Ref's first token. Reassigned after each
		// `expectKw` / `expectLit` so the last one wins (`static var` →
		// after `var`). Declared only when the branch opts in.
		if (triviaKwNewline) steps.push(macro var _lastLitEnd: Int = ctx.pos);
		if (kwLead != null) {
			steps.push(macro expectKw(ctx, $v{kwLead}));
			if (triviaKwNewline) steps.push(macro _lastLitEnd = ctx.pos);
			// ω-issue-257-firstline: capture `_kwEndPos` BEFORE the
			// post-kw `skipWs` so `_bodyOnSameLine` can probe whether
			// the gap up to the body's first token crossed a newline.
			// Mirrors the struct-side `_bodyOnSameLine_<field>` capture
			// in `lowerStruct`'s `@:optional @:kw` path.
			if (triviaBodyPolicyKw) steps.push(macro final _kwEndPos: Int = ctx.pos);
			if (!forwardNewlineForBody) steps.push(macro skipWs(ctx));
			if (triviaBodyPolicyKw) steps.push(macro final _bodyOnSameLine: Bool = !hasNewlineIn(ctx.input, _kwEndPos, ctx.pos));
		}
		if (leadText != null) {
			steps.push(macro expectLit(ctx, $v{leadText}));
			if (triviaKwNewline) steps.push(macro _lastLitEnd = ctx.pos);
			// omega-paren-wrap-source-newline: capture _leadEndPos BEFORE
			// the post-lead skipWs so _wrapOpenNewline can probe whether
			// the gap up to the inner sub-rule's first token crossed a
			// newline. Mirrors the kw-led _kwEndPos / _bodyOnSameLine
			// pattern above.
			if (triviaWrapOpenNewline) steps.push(macro final _leadEndPos: Int = ctx.pos);
			steps.push(macro skipWs(ctx));
			if (triviaWrapOpenNewline) steps.push(macro final _wrapOpenNewline: Bool = hasNewlineIn(ctx.input, _leadEndPos, ctx.pos));
		}
		// ω-keep-kw-newline (increment 1b): the gap probe runs AFTER both the
		// kw and lead skipWs but BEFORE `_raw = callSub`, so `ctx.pos` sits at
		// the inner `decl` Ref's first token. `_lastLitEnd` holds the end of
		// the last literal before its skipWs, so `hasNewlineIn` spans exactly
		// the `var`→head gap.
		if (triviaKwNewline) steps.push(macro final _varKwNewline: Bool = hasNewlineIn(ctx.input, _lastLitEnd, ctx.pos));
	}

	/**
	 * Append the optional trail-literal consume step to a `lowerKwRefBranch`
	 * step list, threading the trivia-mode trailing-trivia stash, the
	 * source-text slice, and the parse-gated optional-`;` decision (Slices
	 * V/X2/X3/X4).
	 */
	private static function appendKwRefTrailStep(
		steps: Array<Expr>, trailText: String, triviaTrailOpt: Bool, triviaCaptureSource: Bool, trailOptional: Bool,
		parseGateCall: Null<Expr>
	): Void {
		// noqa: complexity
		// ω-trailopt-stash-trivia: in trivia mode + `@:trailOpt`, use
		// `skipWsAndStash` so trailing comments between the body and
		// the optional trail literal land in `ctx.pendingTrivia`.
		// When the trail is ABSENT (e.g. `typedef Foo = Int\n/** doc
		// **/\ntypedef Bar`), the parent Star's next `collectTrivia`
		// drains the stash and the doc-comment becomes leading of the
		// next decl. The plain `skipWs` path silently dropped it.
		// Cases: issue_216 / issue_321 closures. Mandatory `@:trail`
		// paths keep the original `skipWs` — comments before a
		// required trail literal are intra-decl close trivia and the
		// downstream writer handles them via close-trail slots.
		if (triviaTrailOpt) {
			// ω-trailopt-stash-trivia: capture the gap between the
			// inner Ref's last byte and the (optional) trail literal
			// via `collectTrivia` — captures `newlineBefore` /
			// `blankBefore` AND any line/block comments. Re-stash
			// into `ctx.pendingTrivia` when anything was captured so
			// the parent Star's next `collectTrivia` drains them as
			// leading of the next sibling decl (the trail literal
			// was absent so there's no intra-decl trailing slot to
			// route to). Plain `skipWsAndStash` would lose the
			// blank/newline signal.
			steps.push(macro {
				final _trailOptCap = collectTrivia(ctx);
				if (
					_trailOptCap.newlineBefore || _trailOptCap.blankBefore || _trailOptCap.blankAfterLeadingComments
					|| _trailOptCap.leadingComments.length > 0
				) {
					ctx.pendingTrivia = {
						blankBefore: _trailOptCap.blankBefore,
						blankAfterLeadingComments: _trailOptCap.blankAfterLeadingComments,
						newlineBefore: _trailOptCap.newlineBefore,
						leadingComments: _trailOptCap.leadingComments,
					};
				}
			});
		} else
			steps.push(macro skipWs(ctx));
		// Capture _end_pos AFTER the post-Ref skipWs but BEFORE the
		// trail-literal match, so trailing whitespace inside the
		// braces (e.g. `${ i + 1 }`) is included in the verbatim
		// slice. In `@:raw` rules the skipWs is stripped at post-
		// process time and the capture lands at the position of
		// the trail literal directly.
		if (triviaCaptureSource) {
			steps.push(macro final _end_pos: Int = ctx.pos);
			steps.push(macro final _sourceText: String = ctx.input.substring(_start_pos, _end_pos));
		}
		// `@:trailOpt` annotates `lit.trailOptional:true` alongside
		// `lit.trailText`. The trail literal becomes optional on
		// parse — `matchLit` peeks + consumes if present, but does
		// NOT throw if absent. In trivia mode the captured presence
		// flag flows into the synth ctor's extra `trailPresent:Bool`
		// arg (ω-trailopt-source-track). Plain
		// mode keeps the original ctor arity and falls back to
		// AST-shape gates such as `@:fmt(trailOptShapeGate(...))`
		// in the writer.
		// Consumers: `HxDecl.TypedefDecl` for `typedef Foo = T`
		// without trailing `;` (ω-typedef-trailOpt);
		// `HxStatement.VarStmt` / `FinalStmt` for `var foo =
		// switch (x) { case _: 1 }` without trailing `;` (slice
		// ω-vardecl-trailOpt — the `}`-terminated rhs idiom).
		// ω-slice-V: when `@:fmt(trailOptParseGate(...))` is present
		// (parseGateCall != null) the matchLit/expectLit choice is
		// made at runtime from the parsed child shape, so a
		// non-brace expr still hits `expectLit` (throws → statement
		// boundary preserved). Without the gate the emission is
		// unchanged (byte-identical for
		// every other ctor).
		// ω-slice-X2: extend the ω-slice-V gate so the trail `;` is
		// ALSO optional when an `else` keyword immediately follows.
		// An `ExprStmt` followed by `else` is only ever an
		// if-then-body in valid Haxe (a stray `else` after any other
		// statement was already a parse error), so relaxing the `;`
		// there only newly-accepts the valid `if (c) bareExpr else
		// …` form — it cannot regress a previously-valid input. The
		// `peekKw` is non-consuming (the `else` belongs to
		// `HxIfStmt.elseBody`'s own `@:optional @:kw('else')`). Still
		// `parseGateCall`-guarded (sole consumer `HxStatement.
		// ExprStmt`) → byte-identical for every other ctor.
		// ω-slice-X3 (`}`-terminator): extend the gate
		// further so the trail `;` is optional when the next non-
		// trivia byte is `}`. An `ExprStmt` followed by `}` is only
		// ever the last stmt of an enclosing block in valid Haxe —
		// the closing brace itself is unambiguously the statement
		// separator, regardless of the just-parsed expr's kind. This
		// generalises the earlier per-ctor extensions
		// (BlockExpr / MetaExpr-ReturnExpr /
		// ObjectLit / ArrayExpr / DollarBlockExpr / Is) — each only
		// got `;` elision because its OWN tail token happened to
		// close a brace/bracket; the principled invariant is
		// extrinsic, not intrinsic. Cascade-safe: `f(); g();` keeps
		// the inter-stmt `;` because `peekLit("}")` only succeeds
		// when `}` is genuinely next; `f() g()` (no `;`, no `}`)
		// still throws on the missing `;`. The `peekLit` is
		// non-consuming — the `}` belongs to the enclosing block's
		// Star `@:trail('}')`. Sole consumer remains `HxStatement.
		// ExprStmt`.
		//
		// ω-slice-X4 (`case`/`default`-terminator): extend
		// the gate further so the trail `;` is optional when the
		// next non-trivia bytes form a word-boundary-checked
		// `case` or `default` keyword. `case` and `default` are
		// reserved in Haxe and legal ONLY as switch arm labels, so
		// an `ExprStmt` followed by either keyword can only be the
		// last stmt of a switch arm — the next `case`/`default`
		// label itself is unambiguously the arm separator,
		// regardless of the just-parsed expr's kind.
		// Motivating shape: try-expr-catch `try x = foo()
		// catch (e:Exception) { … }` as the body of a switch arm
		// followed by another `case`. Byte-twin of the `peekKw("else")`
		// disjunct above — same word-boundary check, same
		// non-consuming nature (the `case`/`default` belongs to the
		// enclosing switch's `Star` of case clauses). Sole consumer
		// remains `HxStatement.ExprStmt`. Cascade-safe: `f() g()`
		// inside a switch arm still throws (`g` is neither `case`
		// nor `default`).
		//
		// `#end` / `#else` / `#elseif` disjuncts (ω-cond-body-nosemi):
		// a no-semi last statement inside a `#if` conditional BODY is legal
		// Haxe (dogfood shape: `haxe.Log.trace = (v) -> {…}` directly
		// before `#end`). The conditional-body Star has no `}` close for the
		// `peekLit` disjunct to see, so the preprocessor terminators must be
		// first-class gate exits like `case`/`default` are for switch arms.
		final gateCond: Null<Expr> = parseGateCall != null
			? (macro ($parseGateCall || peekKw(ctx, 'else') || peekLit(ctx, '}') || peekKw(ctx, 'case') || peekKw(ctx, 'default')
				|| peekKw(ctx, '#end') || peekKw(ctx, '#else') || peekKw(ctx, '#elseif')))
			: null;
		steps.push(
			if (parseGateCall != null && triviaTrailOpt)
				macro final _trailPresent: Bool = $gateCond ? matchLit(ctx, $v{trailText}) : {
					expectLit(ctx, $v{trailText});
					true;
				}
			else if (parseGateCall != null && trailOptional)
				macro if ($gateCond)
					matchLit(ctx, $v{trailText})
				else
					expectLit(ctx, $v{trailText})
			else if (triviaTrailOpt)
				macro final _trailPresent: Bool = matchLit(ctx, $v{trailText})
			else if (trailOptional)
				macro matchLit(ctx, $v{trailText})
			else
				macro expectLit(ctx, $v{trailText})
		);
	}

	/**
	 * Build the synth-ctor call for a `lowerKwRefBranch` ctor, appending the
	 * trivia-mode positional args (`_trailPresent` / `_sourceText` /
	 * `_bodyOnSameLine` / `_wrapOpenNewline` / `_varKwNewline`) the active
	 * capture channels carry.
	 */
	private static function buildKwRefCtorCall(
		ctorRef: Expr, triviaTrailOpt: Bool, triviaCaptureSource: Bool, triviaBodyPolicyKw: Bool, triviaWrapOpenNewline: Bool,
		triviaKwNewline: Bool
	): Expr {
		final ctorArgs: Array<Expr> = [macro _raw];
		if (triviaTrailOpt) ctorArgs.push(macro _trailPresent);
		if (triviaCaptureSource) ctorArgs.push(macro _sourceText);
		if (triviaBodyPolicyKw) ctorArgs.push(macro _bodyOnSameLine);
		if (triviaWrapOpenNewline) ctorArgs.push(macro _wrapOpenNewline);
		if (triviaKwNewline) ctorArgs.push(macro _varKwNewline);
		return { expr: ECall(ctorRef, ctorArgs), pos: Context.currentPos() };
	}

}
#end
