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

	public static function emit(
		rules:Array<GeneratedRule>, rootTypePath:String, rootReturnCT:ComplexType,
		formatInfo:FormatReader.FormatInfo, ?trivia:Bool = false, ?rootFnName:Null<String> = null
	):Array<Field> {
		final fields:Array<Field> = [];
		fields.push(formatInfo.isBinary
			? binaryEntry(rootTypePath, rootReturnCT, rootFnName)
			: publicEntry(rootTypePath, rootReturnCT, rootFnName));
		for (rule in rules) {
			for (ereg in rule.eregs) fields.push(eregField(ereg));
			fields.push(ruleField(rule));
		}
		fields.push(skipWsField(formatInfo));
		fields.push(matchLitField());
		fields.push(peekLitField());
		fields.push(matchKwField());
		fields.push(expectLitField());
		fields.push(expectKwField());
		if (trivia) {
			fields.push(collectTriviaField(formatInfo));
			fields.push(collectTrailingField(formatInfo));
			fields.push(collectTrailingFullField(formatInfo));
			fields.push(hasNewlineInField());
		}
		return fields;
	}

	// -------- public entry point --------

	private static function publicEntry(rootTypePath:String, rootReturnCT:ComplexType, ?rootFnName:Null<String>):Field {
		final rootFn:String = rootFnName ?? 'parse${simpleName(rootTypePath)}';
		final parseCall:Expr = {
			expr: ECall(macro $i{rootFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final body:Expr = macro {
			final ctx:anyparse.runtime.Parser = new anyparse.runtime.Parser(new anyparse.runtime.StringInput(source));
			final _v = $parseCall;
			skipWs(ctx);
			if (ctx.pos != ctx.input.length) {
				throw new anyparse.runtime.ParseError(
					new anyparse.runtime.Span(ctx.pos, ctx.pos),
					'trailing data after value'
				);
			}
			return _v;
		};
		return {
			name: 'parse',
			access: [APublic, AStatic],
			kind: FFun({
				args: [{name: 'source', type: macro : String}],
				ret: rootReturnCT,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function binaryEntry(rootTypePath:String, rootReturnCT:ComplexType, ?rootFnName:Null<String>):Field {
		final rootFn:String = rootFnName ?? 'parse${simpleName(rootTypePath)}';
		final parseCall:Expr = {
			expr: ECall(macro $i{rootFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final body:Expr = macro {
			final ctx:anyparse.runtime.Parser = new anyparse.runtime.Parser(new anyparse.runtime.BytesInput(source));
			final _v = $parseCall;
			if (ctx.pos != ctx.input.length) {
				throw new anyparse.runtime.ParseError(
					new anyparse.runtime.Span(ctx.pos, ctx.pos),
					'trailing data after value'
				);
			}
			return _v;
		};
		return {
			name: 'parse',
			access: [APublic, AStatic],
			kind: FFun({
				args: [{name: 'source', type: macro : haxe.io.Bytes}],
				ret: rootReturnCT,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	// -------- per-rule fields --------

	private static function ruleField(rule:GeneratedRule):Field {
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
		final args:Array<FunctionArg> = [{name: 'ctx', type: macro : anyparse.runtime.Parser}];
		if (rule.hasMinPrec) {
			args.push({
				name: 'minPrec',
				type: macro : Int,
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

	private static function eregField(spec:GeneratedRule.EregSpec):Field {
		final anchored:String = '^${spec.pattern}';
		return {
			name: spec.varName,
			access: [APrivate, AStatic, AFinal],
			kind: FVar(macro : EReg, {expr: EConst(CRegexp(anchored, '')), pos: Context.currentPos()}),
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
	private static function skipWsField(formatInfo:FormatReader.FormatInfo):Field {
		final body:Expr = buildSkipWsBody(formatInfo.commentPatterns);
		return {
			name: 'skipWs',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'ctx', type: macro : anyparse.runtime.Parser}],
				ret: macro : Void,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function buildSkipWsBody(patterns:Array<FormatReader.CommentPattern>):Expr {
		final commentStmts:Array<Expr> = [for (p in patterns) commentSkipBlock(p)];
		return macro while (ctx.pos < ctx.input.length) {
			final c:Int = ctx.input.charCodeAt(ctx.pos);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
				ctx.pos++;
				continue;
			}
			$b{commentStmts};
			break;
		};
	}

	private static function commentSkipBlock(p:FormatReader.CommentPattern):Expr {
		final open:String = p.open;
		if (p.lineTerminated) return macro if (matchLit(ctx, $v{open})) {
			while (ctx.pos < ctx.input.length) {
				if (ctx.input.charCodeAt(ctx.pos) == '\n'.code) break;
				ctx.pos++;
			}
			continue;
		}
		final close:String = p.close;
		return macro if (matchLit(ctx, $v{open})) {
			while (ctx.pos < ctx.input.length) {
				if (matchLit(ctx, $v{close})) break;
				ctx.pos++;
			}
			continue;
		}
	}

	private static function matchLitField():Field {
		return {
			name: 'matchLit',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'ctx', type: macro : anyparse.runtime.Parser},
					{name: 'lit', type: macro : String},
				],
				ret: macro : Bool,
				expr: macro {
					final len:Int = lit.length;
					if (ctx.pos + len > ctx.input.length) return false;
					if (ctx.input.substring(ctx.pos, ctx.pos + len) != lit) return false;
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
	private static function peekLitField():Field {
		return {
			name: 'peekLit',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'ctx', type: macro : anyparse.runtime.Parser},
					{name: 'lit', type: macro : String},
				],
				ret: macro : Bool,
				expr: macro {
					final len:Int = lit.length;
					if (ctx.pos + len > ctx.input.length) return false;
					return ctx.input.substring(ctx.pos, ctx.pos + len) == lit;
				},
			}),
			pos: Context.currentPos(),
		};
	}

	private static function expectLitField():Field {
		return {
			name: 'expectLit',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'ctx', type: macro : anyparse.runtime.Parser},
					{name: 'lit', type: macro : String},
				],
				ret: macro : Void,
				expr: macro {
					if (!matchLit(ctx, lit)) {
						throw new anyparse.runtime.ParseError(
							new anyparse.runtime.Span(ctx.pos, ctx.pos),
							'expected "' + lit + '"'
						);
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
	private static function matchKwField():Field {
		return {
			name: 'matchKw',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'ctx', type: macro : anyparse.runtime.Parser},
					{name: 'keyword', type: macro : String},
				],
				ret: macro : Bool,
				expr: macro {
					final _savedPos:Int = ctx.pos;
					if (!matchLit(ctx, keyword)) return false;
					if (ctx.pos < ctx.input.length) {
						final c:Int = ctx.input.charCodeAt(ctx.pos);
						final isWord:Bool = (c >= 'a'.code && c <= 'z'.code)
							|| (c >= 'A'.code && c <= 'Z'.code)
							|| (c >= '0'.code && c <= '9'.code)
							|| c == '_'.code;
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
	private static function expectKwField():Field {
		return {
			name: 'expectKw',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'ctx', type: macro : anyparse.runtime.Parser},
					{name: 'keyword', type: macro : String},
				],
				ret: macro : Void,
				expr: macro {
					if (!matchLit(ctx, keyword)) {
						throw new anyparse.runtime.ParseError(
							new anyparse.runtime.Span(ctx.pos, ctx.pos),
							'expected keyword "' + keyword + '"'
						);
					}
					if (ctx.pos < ctx.input.length) {
						final c:Int = ctx.input.charCodeAt(ctx.pos);
						final isWord:Bool = (c >= 'a'.code && c <= 'z'.code)
							|| (c >= 'A'.code && c <= 'Z'.code)
							|| (c >= '0'.code && c <= '9'.code)
							|| c == '_'.code;
						if (isWord) {
							throw new anyparse.runtime.ParseError(
								new anyparse.runtime.Span(ctx.pos, ctx.pos),
								'expected keyword "' + keyword + '"'
							);
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
	private static function collectTriviaField(formatInfo:FormatReader.FormatInfo):Field {
		final commentStmts:Array<Expr> = [for (p in formatInfo.commentPatterns) commentCaptureBlock(p)];
		final body:Expr = macro {
			var _blankBefore:Bool = false;
			var _newlineBefore:Bool = false;
			final _leading:Array<String> = [];
			// Drain any trivia that a previous rule captured between an
			// @:optional @:kw commit and its sub-rule call (slice ω₆b).
			final _pt = ctx.pendingTrivia;
			if (_pt != null) {
				_blankBefore = _pt.blankBefore;
				_newlineBefore = _pt.newlineBefore;
				for (_c in _pt.leadingComments) _leading.push(_c);
				ctx.pendingTrivia = null;
			}
			var _nl:Int = 0;
			while (ctx.pos < ctx.input.length) {
				final c:Int = ctx.input.charCodeAt(ctx.pos);
				if (c == '\n'.code) {
					ctx.pos++;
					_nl++;
					_newlineBefore = true;
					if (_nl >= 2) _blankBefore = true;
					continue;
				}
				if (c == ' '.code || c == '\t'.code || c == '\r'.code) {
					ctx.pos++;
					continue;
				}
				$b{commentStmts};
				break;
			}
			return {blankBefore: _blankBefore, newlineBefore: _newlineBefore, leadingComments: _leading};
		};
		return {
			name: 'collectTrivia',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'ctx', type: macro : anyparse.runtime.Parser}],
				ret: macro : {blankBefore:Bool, newlineBefore:Bool, leadingComments:Array<String>},
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
	private static function collectTrailingField(formatInfo:FormatReader.FormatInfo):Field {
		final attempts:Array<Expr> = [for (p in formatInfo.commentPatterns) trailingAttemptBlock(p)];
		final body:Expr = macro {
			final _savedPos:Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				final c:Int = ctx.input.charCodeAt(ctx.pos);
				if (c == ' '.code || c == '\t'.code || c == '\r'.code) {
					ctx.pos++;
					continue;
				}
				break;
			}
			$b{attempts};
			ctx.pos = _savedPos;
			return (null : Null<String>);
		};
		return {
			name: 'collectTrailing',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'ctx', type: macro : anyparse.runtime.Parser}],
				ret: macro : Null<String>,
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
	private static function hasNewlineInField():Field {
		final body:Expr = macro {
			var i:Int = from;
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
					{name: 'input', type: macro : anyparse.runtime.Input},
					{name: 'from', type: macro : Int},
					{name: 'to', type: macro : Int},
				],
				ret: macro : Bool,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
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
	private static function commentCaptureBlock(p:FormatReader.CommentPattern):Expr {
		final open:String = p.open;
		if (p.lineTerminated) return macro if (matchLit(ctx, $v{open})) {
			final _start:Int = ctx.pos - $v{open.length};
			while (ctx.pos < ctx.input.length) {
				if (ctx.input.charCodeAt(ctx.pos) == '\n'.code) break;
				ctx.pos++;
			}
			_leading.push(ctx.input.substring(_start, ctx.pos));
			_nl = 0;
			continue;
		}
		final close:String = p.close;
		return macro if (matchLit(ctx, $v{open})) {
			final _start:Int = ctx.pos - $v{open.length};
			var _end:Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				if (matchLit(ctx, $v{close})) {
					_end = ctx.pos;
					break;
				}
				ctx.pos++;
			}
			_leading.push(ctx.input.substring(_start, _end));
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
	private static function trailingAttemptBlock(p:FormatReader.CommentPattern):Expr {
		final open:String = p.open;
		if (p.lineTerminated) return macro if (matchLit(ctx, $v{open})) {
			final _start:Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				if (ctx.input.charCodeAt(ctx.pos) == '\n'.code) break;
				ctx.pos++;
			}
			return ctx.input.substring(_start, ctx.pos);
		}
		final close:String = p.close;
		final closeLen:Int = close.length;
		return macro if (matchLit(ctx, $v{open})) {
			final _start:Int = ctx.pos;
			var _found:Bool = false;
			var _end:Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				final _c:Int = ctx.input.charCodeAt(ctx.pos);
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
			return (null : Null<String>);
		}
	}

	/**
	 * Generate `collectTrailingFull` — structural twin of `collectTrailing`
	 * that returns the captured comment VERBATIM including its delimiters
	 * (e.g. `// foo` or `/* foo *\/`). Used exclusively by close-trailing
	 * slots (ω-close-trailing / ω-close-trailing-alt) where the writer
	 * must preserve source style — a captured `/* catch *\/` round-trips
	 * as `/* catch *\/`, not as `// catch` (the pre-slice behaviour of
	 * feeding the stripped body through the line-style-only
	 * `trailingCommentDoc`). Per-element and AfterKw slots keep
	 * `collectTrailing` because their writer helpers deliberately
	 * normalise to line style — a stronger contract only applies to the
	 * close-trailing slot.
	 */
	private static function collectTrailingFullField(formatInfo:FormatReader.FormatInfo):Field {
		final attempts:Array<Expr> = [for (p in formatInfo.commentPatterns) trailingFullAttemptBlock(p)];
		final body:Expr = macro {
			final _savedPos:Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				final c:Int = ctx.input.charCodeAt(ctx.pos);
				if (c == ' '.code || c == '\t'.code || c == '\r'.code) {
					ctx.pos++;
					continue;
				}
				break;
			}
			$b{attempts};
			ctx.pos = _savedPos;
			return (null : Null<String>);
		};
		return {
			name: 'collectTrailingFull',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'ctx', type: macro : anyparse.runtime.Parser}],
				ret: macro : Null<String>,
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
	private static function trailingFullAttemptBlock(p:FormatReader.CommentPattern):Expr {
		final open:String = p.open;
		if (p.lineTerminated) return macro if (matchLit(ctx, $v{open})) {
			final _start:Int = ctx.pos - $v{open.length};
			while (ctx.pos < ctx.input.length) {
				if (ctx.input.charCodeAt(ctx.pos) == '\n'.code) break;
				ctx.pos++;
			}
			return ctx.input.substring(_start, ctx.pos);
		}
		final close:String = p.close;
		return macro if (matchLit(ctx, $v{open})) {
			final _start:Int = ctx.pos - $v{open.length};
			var _found:Bool = false;
			var _end:Int = ctx.pos;
			while (ctx.pos < ctx.input.length) {
				final _c:Int = ctx.input.charCodeAt(ctx.pos);
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
			return (null : Null<String>);
		}
	}

	private static function simpleName(typePath:String):String {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}
}
#end
