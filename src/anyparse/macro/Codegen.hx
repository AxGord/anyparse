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
		fields.push(expectLitField());
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
		return {
			name: rule.fnName,
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'ctx', type: macro : anyparse.runtime.Parser}],
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
