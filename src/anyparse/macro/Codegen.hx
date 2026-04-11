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
 *  - Emitting the runtime helpers (`skipWs`, `matchLit`, `expectLit`,
 *    `decodeJsonString`) used by the generated bodies. These are
 *    deliberately duplicated per generated class rather than pulled
 *    from a shared utility module — each generated parser is
 *    self-contained so swapping or regenerating one parser does not
 *    affect others.
 */
class Codegen {

	public static function emit(rules:Array<GeneratedRule>, rootTypePath:String, rootReturnCT:ComplexType):Array<Field> {
		final fields:Array<Field> = [];
		fields.push(publicEntry(rootTypePath, rootReturnCT));
		for (rule in rules) {
			for (ereg in rule.eregs) fields.push(eregField(ereg));
			fields.push(ruleField(rule));
		}
		fields.push(skipWsField());
		fields.push(matchLitField());
		fields.push(matchKwField());
		fields.push(expectLitField());
		fields.push(expectKwField());
		fields.push(decodeJsonStringField());
		return fields;
	}

	// -------- public entry point --------

	private static function publicEntry(rootTypePath:String, rootReturnCT:ComplexType):Field {
		final rootFn:String = 'parse${simpleName(rootTypePath)}';
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

	private static function skipWsField():Field {
		return {
			name: 'skipWs',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'ctx', type: macro : anyparse.runtime.Parser}],
				ret: macro : Void,
				expr: macro {
					while (ctx.pos < ctx.input.length) {
						final c:Int = ctx.input.charCodeAt(ctx.pos);
						if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) ctx.pos++;
						else break;
					}
				},
			}),
			pos: Context.currentPos(),
		};
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

	private static function decodeJsonStringField():Field {
		return {
			name: 'decodeJsonString',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'raw', type: macro : String}],
				ret: macro : String,
				expr: macro {
					final body:String = raw.substring(1, raw.length - 1);
					final buf:StringBuf = new StringBuf();
					var i:Int = 0;
					while (i < body.length) {
						final c:Int = StringTools.fastCodeAt(body, i);
						if (c == '\\'.code) {
							final res = anyparse.format.text.JsonFormat.instance.unescapeChar(body, i + 1);
							buf.addChar(res.char);
							i += 1 + res.consumed;
						} else {
							buf.addChar(c);
							i++;
						}
					}
					return buf.toString();
				},
			}),
			pos: Context.currentPos(),
		};
	}

	private static function simpleName(typePath:String):String {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}
}
#end
