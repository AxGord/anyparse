package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 4 of the macro pipeline — codegen.
 *
 * Takes the list of `GeneratedRule`s produced by `Lowering`, the root
 * rule name (so we know where the public `parse` entry point dispatches
 * to), and the format constants needed by runtime helpers, and returns
 * a full `Array<Field>` ready to be plugged into a `TypeDefinition`
 * via `Context.defineType`.
 *
 * What Codegen owns, specifically:
 *  - Lifting every rule's static `EReg` into a `(APrivate, AStatic,
 *    AFinal)` field keyed by the name the rule's body refers to.
 *  - Writing the `parse(source)` public entry point that constructs a
 *    `Parser`, calls the root rule, and verifies trailing input.
 *  - Emitting the per-rule `parseXxx(ctx)` functions.
 *  - Emitting the runtime helpers (`skipWs`, `matchLit`, `expectLit`)
 *    used by the generated bodies. These are
 *    deliberately duplicated per generated class rather than pulled
 *    from a shared utility module — each generated parser is
 *    self-contained so swapping or regenerating one parser does not
 *    affect others.
 */
class Codegen {

	/** Byte-order mark code point, skipped as whitespace by generated parsers. */
	private static inline final BOM: Int = 0xFEFF;

	public static function emit(
		rules: Array<GeneratedRule>, rootTypePath: String, rootReturnCT: ComplexType, formatInfo: FormatReader.FormatInfo,
		?trivia: Bool = false, ?rootFnName: Null<String> = null
	): Array<Field> {
		final fields: Array<Field> = [];
		fields.push(
			formatInfo.isBinary ? binaryEntry(rootTypePath, rootReturnCT, rootFnName) : publicEntry(rootTypePath, rootReturnCT, rootFnName)
		);
		for (rule in rules) {
			for (ereg in rule.eregs) fields.push(eregField(ereg));
			fields.push(ruleField(rule));
		}
		fields.push(skipWsField(formatInfo));
		fields.push(matchLitField());
		fields.push(peekLitField());
		fields.push(matchKwField());
		fields.push(peekKwField());
		fields.push(expectLitField());
		fields.push(expectKwField());
		// `hasNewlineIn` moved out of the trivia gate (ω-cond-splice): the
		// word-op postfix dispatch's same-line gate reads it in EVERY build.
		fields.push(hasNewlineInField());
		fields.push(endsWithBlockCloseField());
		fields.push(spliceFragmentIsInfixField());
		if (trivia) {
			fields.push(collectTriviaField(formatInfo));
			fields.push(collectTrailingField(formatInfo));
			fields.push(collectTrailingFullField(formatInfo));
			if (formatInfo.commentPatterns.length > 0) fields.push(skipWsAndStashField(formatInfo));
		}
		return fields;
	}

	// -------- public entry point --------

	private static function publicEntry(rootTypePath: String, rootReturnCT: ComplexType, ?rootFnName: Null<String>): Field {
		final rootFn: String = rootFnName ?? 'parse${simpleName(rootTypePath)}';
		final parseCall: Expr = {
			expr: ECall(macro $i{rootFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		// Span-mode (`{spans:true}`) routes the root function through the
		// paired `*S` typed AST whose enum values each carry a `_span`
		// arg — the public entry just forwards the value, no side-channel
		// envelope. Trivia and plain modes share the same return shape.
		// On any thrown `ParseError`, re-surface it at the farthest
		// terminal-failure position when that is deeper than where the
		// outermost rule bailed. Recursive-descent backtracking discards
		// inner failure positions, so the raw throw's span collapses to
		// the file head ("expected <root>"); `ctx.maxFailPos` recovers
		// the real innermost blocker for recon / diagnostics. Success
		// path is unchanged — only the error path is rewritten.
		final body: Expr = macro {
			final ctx: anyparse.runtime.Parser = new anyparse.runtime.Parser(new anyparse.runtime.StringInput(source));
			try {
				final _v = $parseCall;
				skipWs(ctx);
				if (ctx.pos != ctx.input.length) {
					throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), 'trailing data after value');
				}
				return _v;
			} catch (e: anyparse.runtime.ParseError) {
				// Decorate the error with the source string so
				// `ParseError.toString` can render `line:col` instead of
				// the raw byte offset. The entry point is the natural
				// attachment site — the in-body construction sites in
				// generated code have no `source` reference, and only
				// the top-level catch is what callers actually see.
				if (ctx.maxFailPos > e.span.from) {
					final farthest: anyparse.runtime.ParseError = new anyparse.runtime.ParseError(
						new anyparse.runtime.Span(ctx.maxFailPos, ctx.maxFailPos), 'unexpected input', ctx.maxFailExpected
					);
					farthest.source = source;
					throw farthest;
				}
				e.source = source;
				throw e;
			}
		};
		return {
			name: 'parse',
			access: [APublic, AStatic],
			kind: FFun({
				args: [{ name: 'source', type: macro :String }],
				ret: rootReturnCT,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function binaryEntry(rootTypePath: String, rootReturnCT: ComplexType, ?rootFnName: Null<String>): Field {
		final rootFn: String = rootFnName ?? 'parse${simpleName(rootTypePath)}';
		final parseCall: Expr = {
			expr: ECall(macro $i{rootFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final body: Expr = macro {
			final ctx: anyparse.runtime.Parser = new anyparse.runtime.Parser(new anyparse.runtime.BytesInput(source));
			final _v = $parseCall;
			if (ctx.pos != ctx.input.length) {
				throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), 'trailing data after value');
			}
			return _v;
		};
		return {
			name: 'parse',
			access: [APublic, AStatic],
			kind: FFun({
				args: [{ name: 'source', type: macro :haxe.io.Bytes }],
				ret: rootReturnCT,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	// -------- per-rule fields --------

	private static function ruleField(rule: GeneratedRule): Field {
		// Pratt-loop rules take an extra `minPrec:Int = 0` parameter so the
		// loop can know when to stop climbing precedence. Every other rule
		// takes just the context. The default value keeps external call
		// sites (`parseHxExpr(ctx)` from other rules) unchanged.
		//
		// The default-value-is-enough-for-optional form (`minPrec:Int = 0`,
		// no `opt: true`) keeps the parameter typed as non-nullable `Int`.
		// `opt: true` with a default value still widens the type to
		// `Null<Int>` under strict null safety — which would make the
		// `_savedPos` rollback branch's `precValue < minPrec` comparison
		// fail the null-safety binop check inside the generated parser.
		final args: Array<FunctionArg> = [{ name: 'ctx', type: macro :anyparse.runtime.Parser }];
		if (rule.hasMinPrec) {
			args.push({
				name: 'minPrec',
				type: macro :Int,
				value: macro 0,
			});
		}
		return {
			name: rule.fnName,
			access: [APrivate, AStatic],
			kind: FFun({
				args: args,
				ret: rule.returnCT,
				expr: rule.body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function eregField(spec: GeneratedRule.EregSpec): Field {
		final anchored: String = '^${spec.pattern}';
		return {
			name: spec.varName,
			access: [APrivate, AStatic, AFinal],
			kind: FVar(macro :EReg, { expr: EConst(CRegexp(anchored, '')), pos: Context.currentPos() }),
			pos: Context.currentPos(),
		};
	}

	// -------- runtime helpers --------

	/**
	 * Generate `skipWs` — the whitespace-and-comment skipper called
	 * between every terminal match and at the public entry's tail check.
	 *
	 * Base behaviour: consume spaces, tabs, LF, CR.
	 *
	 * When `formatInfo.commentPatterns` is non-empty (e.g. Haxe with
	 * `//` and `/* *\/`), each pattern contributes an inline match block:
	 *  - Line-terminated: consume open literal, scan to next `\n` or
	 *    EOF (newline itself is left for the next iteration's whitespace
	 *    branch — keeps blank-line counting trivially derivable from
	 *    consecutive `\n` consumption for Trivia mode in step 3).
	 *  - Block-terminated: consume open literal, scan until the close
	 *    literal matches (`matchLit` consumes it), then resume the loop.
	 *    No nesting semantics — matches standard C/C++/Java/Haxe block
	 *    comments; formats that need nesting can add it via a dedicated
	 *    CommentPattern flag later.
	 *
	 * Binary formats skip this entirely (empty patterns plus binary
	 * entries never call `skipWs`).
	 */
	private static function skipWsField(formatInfo: FormatReader.FormatInfo): Field {
		final body: Expr = buildSkipWsBody(formatInfo.commentPatterns);
		return {
			name: 'skipWs',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{ name: 'ctx', type: macro :anyparse.runtime.Parser }],
				ret: macro :Void,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function buildSkipWsBody(patterns: Array<FormatReader.CommentPattern>): Expr {
		final commentStmts: Array<Expr> = [for (p in patterns) commentSkipBlock(p)];
		// 0xFEFF is the UTF-8 BOM codepoint, treated as invisible
		// horizontal whitespace anywhere in the input. Real-world editors
		// emit it at the file head; tolerating it inline costs nothing.
		return macro while (ctx.pos < ctx.input.length) {
			final c: Int = ctx.input.charCodeAt(ctx.pos);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code || c == $v{BOM}) {
				ctx.pos++;
				continue;
			}
			$b{commentStmts};
			break;
		};
	}

	private static function commentSkipBlock(p: FormatReader.CommentPattern): Expr {
		final open: String = p.open;
		if (p.lineTerminated) return macro if (matchLit(ctx, $v{open})) {
			while (ctx.pos < ctx.input.length) {
				if (ctx.input.charCodeAt(ctx.pos) == '\n'.code) break;
				ctx.pos++;
			}
			continue;
		}
		final close: String = p.close;
		return macro if (matchLit(ctx, $v{open})) {
			while (ctx.pos < ctx.input.length) {
				if (matchLit(ctx, $v{close})) break;
				ctx.pos++;
			}
			continue;
		}
	}

	/**
	 * ω-pratt-comment-stash — Trivia-mode twin of `skipWs` that captures
	 * each consumed comment VERBATIM (open + body + optional close) into
	 * `ctx.pendingTrivia.leadingComments`. Used by `Lowering.lowerPrattLoop`
	 * (and `lowerPostfixLoop`) inside the matched-branch body where the
	 * outer Pratt rewind-on-no-match cannot reach: once an operator has
	 * matched, the post-op `skipWs` would otherwise drop any line/block
	 * comment between the operator token and the next operand. Stashing
	 * into `pendingTrivia` lets the next `collectTrivia` drain them as
	 * leading-of-next-thing — orphan trivia rather than data loss.
	 */
	private static function skipWsAndStashField(formatInfo: FormatReader.FormatInfo): Field {
		final commentStmts: Array<Expr> = [for (p in formatInfo.commentPatterns) commentSkipAndStashBlock(p)];
		final body: Expr = macro while (ctx.pos < ctx.input.length) {
			final c: Int = ctx.input.charCodeAt(ctx.pos);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code || c == $v{BOM}) {
				ctx.pos++;
				continue;
			}
			$b{commentStmts};
			break;
		};
		return {
			name: 'skipWsAndStash',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{ name: 'ctx', type: macro :anyparse.runtime.Parser }],
				ret: macro :Void,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function commentSkipAndStashBlock(p: FormatReader.CommentPattern): Expr {
		final open: String = p.open;
		if (p.lineTerminated) return macro if (matchLit(ctx, $v{open})) {
			final _start: Int = ctx.pos - $v{open.length};
			while (ctx.pos < ctx.input.length) {
				if (ctx.input.charCodeAt(ctx.pos) == '\n'.code) break;
				ctx.pos++;
			}
			final _verbatim: String = ctx.input.substring(_start, ctx.pos);
			final _pt = ctx.pendingTrivia;
			if (_pt == null) {
				ctx.pendingTrivia = {
					blankBefore: false,
					blankAfterLeadingComments: false,
					newlineBefore: false,
					leadingComments: [_verbatim],
				};
			} else {
				_pt.leadingComments.push(_verbatim);
			}
			continue;
		}
		final close: String = p.close;
		return macro if (matchLit(ctx, $v{open})) {
			final _start: Int = ctx.pos - $v{open.length};
			var _end: Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				if (matchLit(ctx, $v{close})) {
					_end = ctx.pos;
					break;
				}
				ctx.pos++;
			}
			final _verbatim: String = ctx.input.substring(_start, _end);
			final _pt = ctx.pendingTrivia;
			if (_pt == null) {
				ctx.pendingTrivia = {
					blankBefore: false,
					blankAfterLeadingComments: false,
					newlineBefore: false,
					leadingComments: [_verbatim],
				};
			} else {
				_pt.leadingComments.push(_verbatim);
			}
			continue;
		}
	}

	private static function matchLitField(): Field {
		return {
			name: 'matchLit',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'ctx', type: macro :anyparse.runtime.Parser },
					{ name: 'lit', type: macro :String },
				],
				ret: macro :Bool,
				expr: macro {
					final len: Int = lit.length;
					if (ctx.pos + len > ctx.input.length) {
						ctx.recordFail(ctx.pos, lit);
						return false;
					}
					if (ctx.input.substring(ctx.pos, ctx.pos + len) != lit) {
						ctx.recordFail(ctx.pos, lit);
						return false;
					}
					ctx.pos += len;
					return true;
				},
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Non-consuming `lit` check: returns `true` if `lit` is at `ctx.pos`
	 * without advancing the cursor. Used by Star entry guards that need
	 * to distinguish "body continues" from "close delimiter is next"
	 * when the close's first byte can legitimately appear inside an
	 * element (e.g. `@:trail('*\/')` with element content that may
	 * contain `*`). The single-byte `charCodeAt` peek the Star used
	 * before cannot disambiguate multi-byte close delimiters from
	 * element content sharing the same first byte.
	 */
	private static function peekLitField(): Field {
		return {
			name: 'peekLit',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'ctx', type: macro :anyparse.runtime.Parser },
					{ name: 'lit', type: macro :String },
				],
				ret: macro :Bool,
				expr: macro {
					final len: Int = lit.length;
					return ctx.pos + len <= ctx.input.length && ctx.input.substring(ctx.pos, ctx.pos + len) == lit;
				},
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Non-consuming keyword peek: `peekLit` plus a trailing word-boundary
	 * check, without ever advancing the cursor. Returns `true` only when
	 * `keyword` is at `ctx.pos` AND the character immediately after it is
	 * not a word character (`[A-Za-z0-9_]`), so `else` does not peek-match
	 * the prefix of `elsewhere`. Distinct from `matchKw` (which consumes
	 * on a successful boundary-checked match) — `peekKw` leaves `ctx.pos`
	 * untouched in every path. Sole consumer: the `ExprStmt` trail-`;`
	 * gate in `Lowering` (ω-slice-V, ω-slice-X2/X3/X4), which treats `;`
	 * as optional when `else` / `case` / `default` follows the just-parsed
	 * expression (each keyword is reserved and unambiguously signals a
	 * statement-arm separator — if-then-body, switch case label, switch
	 * default label respectively).
	 */
	private static function peekKwField(): Field {
		return {
			name: 'peekKw',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'ctx', type: macro :anyparse.runtime.Parser },
					{ name: 'keyword', type: macro :String },
				],
				ret: macro :Bool,
				expr: macro {
					final len: Int = keyword.length;
					if (ctx.pos + len > ctx.input.length) return false;
					if (ctx.input.substring(ctx.pos, ctx.pos + len) != keyword) return false;
					if (ctx.pos + len < ctx.input.length) {
						final c: Int = ctx.input.charCodeAt(ctx.pos + len);
						final isWord: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code)
						|| (c >= '0'.code && c <= '9'.code) || c == '_'.code;
						if (isWord) return false;
					}
					return true;
				},
			}),
			pos: Context.currentPos(),
		};
	}

	private static function expectLitField(): Field {
		return {
			name: 'expectLit',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'ctx', type: macro :anyparse.runtime.Parser },
					{ name: 'lit', type: macro :String },
				],
				ret: macro :Void,
				expr: macro {
					if (!matchLit(ctx, lit)) {
						throw anyparse.runtime.ParseError.backtrack;
					}
				},
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * `matchKw` is the peek variant of `expectKw`: on a successful match
	 * AND a passing word-boundary check it consumes the literal and
	 * returns `true`; on either failure it rewinds `ctx.pos` to the
	 * pre-call position and returns `false`. Used by enum-branch Case 2
	 * (multi-`@:lit` on a Bool arg) where the dispatch is a sequence of
	 * `if (matchKw(...)) return Ctor(value)` attempts and a partial
	 * match on the prefix of an identifier (`trueish`) must not consume
	 * `true`. Symbolic literals route through plain `matchLit` — the
	 * word-boundary check is emitted only when the literal ends with a
	 * word character, determined at macro time by `Lowering`.
	 */
	private static function matchKwField(): Field {
		return {
			name: 'matchKw',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'ctx', type: macro :anyparse.runtime.Parser },
					{ name: 'keyword', type: macro :String },
				],
				ret: macro :Bool,
				expr: macro {
					final _savedPos: Int = ctx.pos;
					if (!matchLit(ctx, keyword)) return false;
					if (ctx.pos < ctx.input.length) {
						final c: Int = ctx.input.charCodeAt(ctx.pos);
						final isWord: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code)
						|| (c >= '0'.code && c <= '9'.code) || c == '_'.code;
						if (isWord) {
							ctx.pos = _savedPos;
							return false;
						}
					}
					return true;
				},
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * `expectKw` is `expectLit` plus a trailing word-boundary check. After
	 * the literal match succeeds it peeks at the next input character and
	 * throws `ParseError` if it is a word character (`[A-Za-z0-9_]`), so
	 * that e.g. `class` does not match the prefix of `classify`. Rollback
	 * of the consumed characters on word-boundary failure is the caller's
	 * responsibility — the enum-branch `tryBranch` wrapper in `Lowering`
	 * captures `ctx.pos` before invoking the branch and resets it on any
	 * thrown `ParseError`, which covers this case automatically.
	 */
	private static function expectKwField(): Field {
		return {
			name: 'expectKw',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'ctx', type: macro :anyparse.runtime.Parser },
					{ name: 'keyword', type: macro :String },
				],
				ret: macro :Void,
				expr: macro {
					if (!matchLit(ctx, keyword)) {
						throw anyparse.runtime.ParseError.backtrack;
					}
					if (ctx.pos < ctx.input.length) {
						final c: Int = ctx.input.charCodeAt(ctx.pos);
						final isWord: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code)
						|| (c >= '0'.code && c <= '9'.code) || c == '_'.code;
						if (isWord) {
							throw anyparse.runtime.ParseError.backtrack;
						}
					}
				},
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Generate `collectTrivia` — the Trivia-mode twin of `skipWs`. Walks
	 * horizontal whitespace and newlines as `skipWs` does, but captures
	 * every recognised comment verbatim (open + body + close delimiters
	 * included) into an `Array<String>` and sets `blankBefore = true`
	 * when two or more
	 * consecutive newlines appear anywhere in the collected run (before
	 * any comment, between comments, or after the last comment). The
	 * per-newline counter resets to zero after each comment match so a
	 * blank line strictly means ≥2 newlines with nothing but spaces/tabs
	 * between them.
	 *
	 * Return shape mirrors `Trivial<T>`'s leading slots so the Star loop
	 * can splat the result into a struct literal without intermediate
	 * renaming.
	 *
	 * Emitted only when `buildParser` was called with `{trivia: true}`.
	 * Non-trivia parsers keep `skipWs` as their single whitespace
	 * handler.
	 */
	private static function collectTriviaField(formatInfo: FormatReader.FormatInfo): Field {
		final commentStmts: Array<Expr> = [for (p in formatInfo.commentPatterns) commentCaptureBlock(p)];
		final body: Expr = macro {
			var _blankBefore: Bool = false;
			// ω-blank2: extra blank lines (beyond the first) preceding the
			// node when no leading comment intervenes. Lets the writer
			// reproduce a >1 blank gap up to `maxAnywhereInFile`; a single
			// bool could only carry 0/1. 0 = one-or-fewer blanks.
			var _blankBefore2: Int = 0;
			var _blankAfterLeadingComments: Bool = false;
			var _newlineBefore: Bool = false;
			final _leading: Array<String> = [];
			// Drain any trivia that a previous rule captured between an
			// @:optional @:kw commit and its sub-rule call (ω₆b).
			final _pt = ctx.pendingTrivia;
			if (_pt != null) {
				_blankBefore = _pt.blankBefore;
				_blankAfterLeadingComments = _pt.blankAfterLeadingComments;
				_newlineBefore = _pt.newlineBefore;
				for (_c in _pt.leadingComments) _leading.push(_c);
				ctx.pendingTrivia = null;
			}
			var _nl: Int = 0;
			while (ctx.pos < ctx.input.length) {
				final c: Int = ctx.input.charCodeAt(ctx.pos);
				if (c == '\n'.code) {
					ctx.pos++;
					_nl++;
					_newlineBefore = true;
					// Blank lines split into two slots: those preceding any
					// captured leading comment go to `blankBefore`, those
					// after go to `blankAfterLeadingComments`. The split
					// lets the writer reproduce `\n\n// c\n\nnode` faithfully
					// — single-bool flag would conflate both gaps.
					if (_nl >= 2) {
						if (_leading.length == 0) {
							_blankBefore = true;
							if (_nl >= 3) _blankBefore2 = _nl - 2; // noqa: magic-number
						} else
							_blankAfterLeadingComments = true;
					}
					continue;
				}
				if (c == ' '.code || c == '\t'.code || c == '\r'.code || c == $v{BOM}) {
					ctx.pos++;
					continue;
				}
				$b{commentStmts};
				break;
			}
			// ω-643-leading-block-glue: `_nl` was reset to 0 by the last
			// `commentCaptureBlock` and then counts every newline between
			// that comment's close and the node's first token. When the
			// run held ≥1 captured comment AND no newline followed the last
			// one, the comment is glued to the node on the same source line
			// (`/* c */ field`). The writer keeps a same-line block comment
			// on the field's line instead of force-breaking. False whenever
			// `_leading` is empty (no leading comment to glue).
			final _newlineAfterLeadingComments: Bool = _nl > 0;
			return {
				blankBefore: _blankBefore,
				blankBefore2: _blankBefore2,
				blankAfterLeadingComments: _blankAfterLeadingComments,
				newlineBefore: _newlineBefore,
				newlineAfterLeadingComments: _leading.length > 0 && _newlineAfterLeadingComments,
				leadingComments: _leading,
			};
		};
		return {
			name: 'collectTrivia',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{ name: 'ctx', type: macro :anyparse.runtime.Parser }],
				ret: macro :{
					blankBefore: Bool,
					blankBefore2: Int,
					blankAfterLeadingComments: Bool,
					newlineBefore: Bool,
					newlineAfterLeadingComments: Bool,
					leadingComments: Array<String>
				},
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Generate `collectTrailing` — probe for a single same-line comment
	 * immediately after a just-parsed Trivia-mode element. Horizontal
	 * whitespace (`' '`, `'\t'`, `'\r'`) before the comment is consumed
	 * regardless of whether a comment is found; a newline on the same
	 * line means no trailing (position is rewound so the outer
	 * `collectTrivia` picks the newlines up as leading of the next
	 * element). For block comments, an internal newline disqualifies the
	 * match — a newline-bearing block is left for the next element's
	 * leading capture. Returns the comment body (delimiters stripped)
	 * or `null`.
	 */
	private static function collectTrailingField(formatInfo: FormatReader.FormatInfo): Field {
		final attempts: Array<Expr> = [for (p in formatInfo.commentPatterns) trailingAttemptBlock(p)];
		final body: Expr = macro {
			final _savedPos: Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				final c: Int = ctx.input.charCodeAt(ctx.pos);
				if (c == ' '.code || c == '\t'.code || c == '\r'.code || c == $v{BOM}) {
					ctx.pos++;
					continue;
				}
				break;
			}
			$b{attempts};
			ctx.pos = _savedPos;
			return (null: Null<String>);
		};
		return {
			name: 'collectTrailing',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{ name: 'ctx', type: macro :anyparse.runtime.Parser }],
				ret: macro :Null<String>,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * ω-keep-policy — tiny helper for source-shape capture. Scans the
	 * input range `[from, to)` for a newline byte; used by the optional-
	 * kw path in `Lowering.lowerStruct` to populate the synth
	 * `<field>BeforeKwNewline` / `<field>BodyOnSameLine` slots that
	 * drive the writer's `Keep` branches. Trivia-mode only.
	 */
	private static function hasNewlineInField(): Field {
		final body: Expr = macro {
			var i: Int = from;
			while (i < to) {
				if (input.charCodeAt(i) == '\n'.code) return true;
				i++;
			}
			return false;
		};
		return {
			name: 'hasNewlineIn',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'input', type: macro :anyparse.runtime.Input },
					{ name: 'from', type: macro :Int },
					{ name: 'to', type: macro :Int },
				],
				ret: macro :Bool,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Companion predicate to `hasNewlineIn` for the word-op postfix
	 * dispatch's own-line gate (`Lowering.buildPostfixOpMatchExpr`).
	 * Reports whether the last non-whitespace byte BEFORE `pos` is a
	 * block close `}`.
	 *
	 * WHY `}` specifically: an own-line `#if` following a complete operand
	 * is a STATEMENT-scope conditional exactly when the statement before it
	 * was already terminable, and in Haxe a statement that needs no `;`
	 * always ends with `}` -- a block, an `if`/`for`/`while`/`switch`/`try`
	 * whose last branch is a block, or a metadata-prefixed block statement.
	 * Any other trailing byte leaves the enclosing expression incomplete, so
	 * a following `#if` can only be an infix splice tail.
	 *
	 * The backward whitespace skip is defensive: the caller passes the
	 * postfix loop's `_preWsPos`, saved immediately after the previously
	 * consumed token, so in practice `pos - 1` is already the operand's last
	 * byte.
	 */
	private static function endsWithBlockCloseField(): Field {
		final body: Expr = macro {
			var i: Int = pos - 1;
			while (i >= 0) {
				final c: Int = input.charCodeAt(i);
				if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
					i--;
					continue;
				}
				return c == '}'.code;
			}
			return false;
		};
		return {
			name: 'endsWithBlockClose',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'input', type: macro :anyparse.runtime.Input },
					{ name: 'pos', type: macro :Int },
				],
				ret: macro :Bool,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Second half of the word-op postfix own-line gate
	 * (`Lowering.buildPostfixOpMatchExpr`). `from` is the byte just past the
	 * matched operator (`#if`); the scan skips the preprocessor CONDITION
	 * ATOM and reports whether the fragment that follows it opens with an
	 * INFIX operator byte.
	 *
	 * That is the discriminator between the two things an own-line `#if` can
	 * be. A splice TAIL continues the operand expression, so its fragment
	 * necessarily opens with an operator:
	 *   `return __idleThreads` + `#if lime_threads - __queuedExitEvents #end`
	 *   `if (intf != null`     + `#if (js_es >= 6) && (...) #end)`
	 * Every other own-line `#if` opens a SCOPE-level region whose fragment
	 * starts with a declaration, statement, list separator or metadata:
	 *   `#if debug final t1:Float = Sys.time(); #end`  (statement scope)
	 *   `#if (haxe_ver >= 4.10) if (...) #else ... #end` (statement scope)
	 *   `#if air, commandKey:Bool = false, ... #end`   (param-list scope)
	 *   `#if debug @doc("...") ["--check-stability"] => ... #end` (array scope)
	 * All four of those were live PASS shapes that a newline-blind relaxation
	 * broke; the infix test is what keeps them with their own productions.
	 *
	 * CONDITION-ATOM SKIP. The atom is a `(`-balanced group or a run of
	 * identifier / dot bytes, optionally preceded by `!`. An unparenthesised
	 * multi-term condition (`#if a && b`) is deliberately read as atom `a`
	 * plus an infix fragment: both readings agree that nothing scope-level
	 * follows, which is all this predicate has to decide. Comments between
	 * the atom and the fragment are skipped so a leading `/` is unambiguously
	 * a division operator.
	 */
	private static function spliceFragmentIsInfixField(): Field {
		final skipCondAtom: Expr = spliceCondAtomSkipExpr();
		final skipGap: Expr = spliceGapSkipExpr();
		final infixTest: Expr = infixOpByteTestExpr();
		final body: Expr = macro {
			var i: Int = from;
			$skipCondAtom;
			$skipGap;
			if (i >= input.length) return false;
			final c: Int = input.charCodeAt(i);
			return $infixTest;
		};
		return {
			name: 'spliceFragmentIsInfix',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'input', type: macro :anyparse.runtime.Input },
					{ name: 'from', type: macro :Int },
				],
				ret: macro :Bool,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Statement fragment of `spliceFragmentIsInfix`: advance the cursor `i`
	 * past the preprocessor CONDITION ATOM. Leading whitespace and `!`
	 * negations are skipped, then either a `(`-balanced group or a run of
	 * identifier / digit / `_` / `.` bytes. Bails out at end of input, which
	 * the caller reads as "no infix fragment".
	 */
	private static function spliceCondAtomSkipExpr(): Expr {
		final atomByteTest: Expr = condAtomByteTestExpr();
		return macro {
			while (i < input.length) {
				final c: Int = input.charCodeAt(i);
				if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code || c == '!'.code) {
					i++;
					continue;
				}
				break;
			}
			if (i >= input.length) return false;
			if (input.charCodeAt(i) == '('.code) {
				var depth: Int = 0;
				while (i < input.length) {
					final c: Int = input.charCodeAt(i);
					i++;
					if (c == '('.code) {
						depth++;
					} else if (c == ')'.code) {
						depth--;
						if (depth == 0) break;
					}
				}
			} else {
				while (i < input.length) {
					final c: Int = input.charCodeAt(i);
					if (!$atomByteTest) break;
					i++;
				}
			}
		};
	}

	/**
	 * Statement fragment of `spliceFragmentIsInfix`: advance the cursor `i`
	 * past whitespace AND comments between the condition atom and the
	 * fragment. Skipping comments is what makes a leading `/` unambiguously
	 * a division operator in the byte test that follows.
	 */
	private static function spliceGapSkipExpr(): Expr {
		return macro while (i < input.length) {
			final c: Int = input.charCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
				i++;
				continue;
			}
			if (c == '/'.code && i + 1 < input.length && input.charCodeAt(i + 1) == '/'.code) {
				while (i < input.length && input.charCodeAt(i) != '\n'.code) i++;
				continue;
			}
			if (c == '/'.code && i + 1 < input.length && input.charCodeAt(i + 1) == '*'.code) {
				i += 2;
				while (i + 1 < input.length && !(input.charCodeAt(i) == '*'.code && input.charCodeAt(i + 1) == '/'.code)) i++;
				i += 2;
				continue;
			}
			break;
		};
	}

	/**
	 * Expression fragment of `spliceCondAtomSkipExpr`: is byte `c` part of an
	 * unparenthesised preprocessor condition atom? Identifier bytes plus `.`,
	 * which covers the dotted `#if haxe.something` form.
	 */
	private static function condAtomByteTestExpr(): Expr {
		return macro (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code)
			|| c == '_'.code || c == '.'.code;
	}

	/**
	 * Expression fragment of `spliceFragmentIsInfix`: is byte `c` a legal
	 * FIRST byte of a Haxe infix (or chain) operator? The set is deliberately
	 * over-broad on the accept side -- every byte here is one no declaration,
	 * statement, list separator or metadata tag can start with, which is the
	 * only property the own-line gate needs.
	 */
	private static function infixOpByteTestExpr(): Expr {
		return macro c == '+'.code || c == '-'.code || c == '*'.code || c == '/'.code || c == '%'.code || c == '='.code || c == '!'.code
			|| c == '<'.code || c == '>'.code || c == '&'.code || c == '|'.code || c == '^'.code || c == '?'.code || c == ':'.code
			|| c == '.'.code;
	}

	/**
	 * One inline block inside `collectTrivia` for a specific comment
	 * pattern. Captures the comment VERBATIM — open delimiter + body +
	 * close delimiter — so the writer can round-trip source style
	 * without style-guessing heuristics. Line-style returns
	 * `<open><body>` (no trailing `\n`); block-style returns
	 * `<open><body><close>`. Resets the `_nl` newline counter so a
	 * subsequent blank line is still recognised.
	 */
	private static function commentCaptureBlock(p: FormatReader.CommentPattern): Expr {
		final open: String = p.open;
		if (p.lineTerminated) return macro if (matchLit(ctx, $v{open})) {
			final _start: Int = ctx.pos - $v{open.length};
			while (ctx.pos < ctx.input.length) {
				if (ctx.input.charCodeAt(ctx.pos) == '\n'.code) break;
				ctx.pos++;
			}
			_leading.push(ctx.input.substring(_start, ctx.pos));
			// ω-D14-blank-between-leading-clear: a blank captured before this
			// comment (when _leading was non-empty) was conflated with
			// "blank AFTER the last leading comment" via the _nl >= 2 +
			// _leading.length > 0 branch above. With a NEW comment now
			// captured, that earlier blank is actually "blank BETWEEN
			// comments" — clear the slot so it doesn't propagate to the
			// writer's blank-before-body emit gate.
			_blankAfterLeadingComments = false;
			_nl = 0;
			continue;
		}
		final close: String = p.close;
		return macro if (matchLit(ctx, $v{open})) {
			final _start: Int = ctx.pos - $v{open.length};
			var _end: Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				if (matchLit(ctx, $v{close})) {
					_end = ctx.pos;
					break;
				}
				ctx.pos++;
			}
			_leading.push(ctx.input.substring(_start, _end));
			// ω-D14-blank-between-leading-clear: see line-terminated branch.
			_blankAfterLeadingComments = false;
			_nl = 0;
			continue;
		}
	}

	/**
	 * One attempt block inside `collectTrailing` for a specific comment
	 * pattern. Line-style returns the remainder of the line (without the
	 * trailing `\n`). Block-style bails on internal newline — the caller
	 * treats a newline-bearing block comment as leading-of-next.
	 */
	private static function trailingAttemptBlock(p: FormatReader.CommentPattern): Expr {
		final open: String = p.open;
		if (p.lineTerminated) return macro if (matchLit(ctx, $v{open})) {
			final _start: Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				if (ctx.input.charCodeAt(ctx.pos) == '\n'.code) break;
				ctx.pos++;
			}
			return ctx.input.substring(_start, ctx.pos);
		}
		final close: String = p.close;
		final closeLen: Int = close.length;
		return macro if (matchLit(ctx, $v{open})) {
			final _start: Int = ctx.pos;
			var _found: Bool = false;
			var _end: Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				final _c: Int = ctx.input.charCodeAt(ctx.pos);
				if (_c == '\n'.code) break;
				if (matchLit(ctx, $v{close})) {
					_end = ctx.pos - $v{closeLen};
					_found = true;
					break;
				}
				ctx.pos++;
			}
			if (_found) return ctx.input.substring(_start, _end);
			ctx.pos = _savedPos;
			return (null: Null<String>);
		}
	}

	/**
	 * Generate `collectTrailingFull` — structural twin of `collectTrailing`
	 * that returns the captured comment VERBATIM including its delimiters
	 * (e.g. `// foo` or `/* foo *\/`). Used exclusively by close-trailing
	 * slots (ω-close-trailing / ω-close-trailing-alt) where the writer
	 * must preserve source style — a captured `/* catch *\/` round-trips
	 * as `/* catch *\/`, not as `// catch` (which feeding the stripped body through the line-style-only `trailingCommentDoc` would produce). Per-element and AfterKw slots keep
	 * `collectTrailing` because their writer helpers deliberately
	 * normalise to line style — a stronger contract only applies to the
	 * close-trailing slot.
	 */
	private static function collectTrailingFullField(formatInfo: FormatReader.FormatInfo): Field {
		final attempts: Array<Expr> = [for (p in formatInfo.commentPatterns) trailingFullAttemptBlock(p)];
		final body: Expr = macro {
			final _savedPos: Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				final c: Int = ctx.input.charCodeAt(ctx.pos);
				if (c == ' '.code || c == '\t'.code || c == '\r'.code || c == $v{BOM}) {
					ctx.pos++;
					continue;
				}
				break;
			}
			$b{attempts};
			ctx.pos = _savedPos;
			return (null: Null<String>);
		};
		return {
			name: 'collectTrailingFull',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{ name: 'ctx', type: macro :anyparse.runtime.Parser }],
				ret: macro :Null<String>,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Twin of `trailingAttemptBlock` that captures the open delimiter +
	 * body + close delimiter verbatim. Line-style returns `open + body`
	 * (no trailing `\n`); block-style returns `open + body + close` and
	 * rejects internal newlines identically to the stripped variant.
	 */
	private static function trailingFullAttemptBlock(p: FormatReader.CommentPattern): Expr {
		final open: String = p.open;
		if (p.lineTerminated) return macro if (matchLit(ctx, $v{open})) {
			final _start: Int = ctx.pos - $v{open.length};
			while (ctx.pos < ctx.input.length) {
				if (ctx.input.charCodeAt(ctx.pos) == '\n'.code) break;
				ctx.pos++;
			}
			return ctx.input.substring(_start, ctx.pos);
		}
		final close: String = p.close;
		return macro if (matchLit(ctx, $v{open})) {
			final _start: Int = ctx.pos - $v{open.length};
			var _found: Bool = false;
			var _end: Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				final _c: Int = ctx.input.charCodeAt(ctx.pos);
				if (_c == '\n'.code) break;
				if (matchLit(ctx, $v{close})) {
					_end = ctx.pos;
					_found = true;
					break;
				}
				ctx.pos++;
			}
			if (_found) return ctx.input.substring(_start, _end);
			ctx.pos = _savedPos;
			return (null: Null<String>);
		}
	}

	private static function simpleName(typePath: String): String {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

}
#end
