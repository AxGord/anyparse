package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.macro.Lowering.*;
import anyparse.macro.ParseDispatchLowering.*;
import anyparse.macro.MacroNames.*;

using Lambda;
using StringTools;
using anyparse.macro.MetaInspect;

/**
 * Pass 3 helpers - the Terminal rule shape.
 *
 * One of the four shapes `Lowering.lowerRule` dispatches on: a rule whose
 * body is a regular expression, and whose generated parser runs that
 * `EReg` and decodes the matched slice into the declared underlying type.
 * The family is `lowerTerminal` (the emit), `lowerTerminalDecodeExpr`
 * (what the matched string becomes - `Int`, `Float`, `Bool`, a
 * `@:raw` slice or a schema call), `lowerStringEnumTerminal` (the
 * `enum abstract(String)` variant, matched as a literal alternation) and
 * `collectEregs` (the per-rule `EReg` the codegen must declare).
 *
 * Split out of `Lowering` by the STATE each member reads, the axis that
 * survived after the purity axis was exhausted. This family is the
 * cheapest of the three: it touches only `_formatInfo` and the
 * `_eregByRule` accumulator, and it calls NO member that stayed behind -
 * so its bundle carries two data fields and not one callback.
 */
@:access(anyparse.macro.BinaryParseLowering, anyparse.macro.KwBranchLowering, anyparse.macro.Lowering,
	anyparse.macro.OperatorLoopLowering, anyparse.macro.ParseDispatchLowering, anyparse.macro.SpanArgLowering,
	anyparse.macro.StarLoopLowering, anyparse.macro.StructFieldTrailLowering, anyparse.macro.TriviaSlotNames)
final class TerminalParseLowering {

	private static function collectEregs(tc: TerminalCtx, typePath: String): Array<GeneratedRule.EregSpec> {
		final eregs: Array<GeneratedRule.EregSpec> = [];
		if (tc.eregByRule.exists(typePath)) eregs.push(tc.eregByRule[typePath]);
		return eregs;
	}

	// -------- terminal rule --------

	private static function lowerTerminal(tc: TerminalCtx, node: ShapeNode, typePath: String, simple: String): Expr {
		final stringEnumValues: Null<Array<{ name: String, value: String }>> = node.annotations['base.stringEnumValues'];
		if (stringEnumValues != null) return lowerStringEnumTerminal(tc, typePath, simple, stringEnumValues);
		final pattern: Null<String> = node.annotations['re.pattern'];
		if (pattern == null) {
			Context.fatalError('Lowering: terminal $typePath missing @:re', Context.currentPos());
			throw 'unreachable';
		}
		final underlying: String = node.annotations['base.underlying'];
		final eregVar: String = '_re_$simple';
		tc.eregByRule[typePath] = { varName: eregVar, pattern: pattern };

		// `@:rawString` on a String-underlying Terminal means "the regex
		// match is already the raw value" — skip decoding entirely. Used
		// for identifier-like terminals (Haxe `HxIdentLit`) where the
		// matched slice IS the identifier text.
		final raw: Bool = node.hasMeta(':rawString');

		final decodeExpr: Expr = lowerTerminalDecodeExpr(tc, node, typePath, underlying, raw);

		// `@:captureGroup(N)` (N >= 1) picks the Nth capture group as the
		// stored value — position still advances by the full `matched(0)`
		// length, so any prefix matched but not stored (leading ws, style
		// markers like `* ` in a `/*...*/` body) is consumed. Default (no
		// meta) keeps the whole match as both stored value and advance
		// amount, preserving the existing behaviour for every other
		// terminal.
		final captureGroup: Null<Int> = node.annotations['re.captureGroup'];
		final matchedValueExpr: Expr = captureGroup == null ? macro $i{eregVar}.matched(0) : macro $i{eregVar}.matched($v{captureGroup});
		final advanceLenExpr: Expr = captureGroup == null ? macro _matched.length : macro $i{eregVar}.matched(0).length;
		// ω-terminal-anchor-guard: `EReg.match` returns true even when the
		// regex matches mid-string (the `^` anchor binds only to the FIRST
		// alternative without an explicit non-capturing group — `^A|B` ≡
		// `(^A)|B`, so the second alt silently scans the rest of input for
		// an arbitrary match). Caught by the `HxFloatLit` regex
		// extension: `^[0-9]+\.[0-9]+|[0-9]+\.(?![\w.])` matched `1.` mid-
		// buffer when the parser was sitting at an ident, overwriting the
		// ident's position with the float slice. Defensive runtime check
		// rejects any match that did not start at position 0 of `_rest` —
		// `matchedPos().pos != 0` ⇒ same `ParseError` as `!match`. Cheap
		// (one extra accessor call per terminal hit), universal (every
		// `@:re`-driven terminal gets it), and catches the bug class
		// instead of patching individual regexes after they leak into a
		// slice's sweep delta.
		final body: Expr = macro {
			final _rest: String = ctx.input.substring(ctx.pos, ctx.input.length);
			if (!$i{eregVar}.match(_rest) || $i{eregVar}.matchedPos().pos != 0) {
				ctx.recordFail(ctx.pos, $v{simple});
				throw anyparse.runtime.ParseError.backtrack;
			}
			final _matched: String = $matchedValueExpr;
			ctx.pos += $advanceLenExpr;
			return $decodeExpr;
		};
		// ω-terminal-first-byte: when `terminalFirstToken` reads a literal
		// head off the regex source, reject a wrong first byte BEFORE the
		// `substring` + `EReg.match` above.
		//
		// This is what makes the terminal's first-token CLAIM self-enforcing
		// rather than merely checked: the same fact that produces the claim
		// produces this reject, so the generated function CANNOT accept a
		// first byte outside the claim — `checkRuleFirstToken` then reads
		// this very statement back out of the emitted body as the fact.
		// What that buys is exactly one thing: the guard and the terminal can
		// never disagree, because one fact produces both. It is NOT soundness.
		// A classifier that answers a set too NARROW makes the terminal reject
		// input the regex accepts AND makes the guard skip that branch, so a
		// sibling branch can match instead and the parse succeeds down it with
		// no error anywhere. Soundness rests entirely on `RegexFirstBytes` being
		// right, which is what `RegexFirstBytesTest.testSoundnessAgainstTheRealRegex`
		// is the check for.
		//
		// `Input.charCodeAt` answers -1 outside `[0, length)`, so no bounds
		// test is needed — end-of-input fails the compare like any other
		// wrong byte. Free win on the hot literal terminals, which today pay
		// a `substring` plus a regex run before finding out the first byte
		// was never right.
		final first: BranchFirstToken = terminalFirstToken(node);
		final codes: Null<Array<Int>> = switch first {
			case FirstLit(cs): cs;
			case _: null;
		};
		if (codes == null) return body;
		final fail: Expr = macro {
			ctx.recordFail(ctx.pos, $v{simple});
			throw anyparse.runtime.ParseError.backtrack;
		};
		final steps: Array<Expr> = switch body.expr {
			case EBlock(exprs): exprs;
			case _: [body];
		};
		// One code keeps the bare compare it always had; a SET reads the
		// byte into a local first, so a class-shaped head costs one read
		// and a range test rather than one read per term.
		//
		// The single-code shape is kept rather than folded into the set one so that
		// every terminal the PREVIOUS classifier could already claim (`HxHexLit`,
		// `HxRegexLit`, the `@`- and `#`-led ones) emits the byte it always did —
		// which is what makes a diff of the generated parser show only the branches
		// this slice meant to change. The cost is `firstByteRejectCodes` carrying
		// two arms.
		if (codes.length == 1) {
			final reject: Expr = macro if (ctx.input.charCodeAt(ctx.pos) != $v{codes[0]}) $fail;
			return macro $b{[reject].concat(steps)};
		}
		final chain: Expr = orChain(byteSetTerms(TERMINAL_BYTE_LOCAL, codes));
		final peek: Expr = finalLocal(TERMINAL_BYTE_LOCAL, macro :Int, macro ctx.input.charCodeAt(ctx.pos));
		final reject: Expr = macro if (!$chain) $fail;
		return macro $b{[peek, reject].concat(steps)};
	}

	/**
	 * Lower an `enum abstract(String)` terminal — parses the format's
	 * string literal, then dispatches to the matching enum value via a
	 * macro-time switch over the declared `name → value` pairs. Unknown
	 * strings raise a `ParseError`. No regex is registered — the value
	 * set is closed at compile time, so a literal switch is both faster
	 * and cleaner than an `EReg` alternation.
	 */
	private static function lowerStringEnumTerminal(
		tc: TerminalCtx, typePath: String, simple: String, values: Array<{ name: String, value: String }>
	): Expr {
		final stringType: Null<String> = tc.formatInfo.stringType;
		if (stringType == null) {
			Context.fatalError(
				'Lowering: enum-abstract(String) terminal $typePath requires the format ${tc.formatInfo.schemaTypePath}'
				+ ' to declare stringType',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final pack: Array<String> = packOf(typePath);
		final errMsg: String = 'invalid $simple value';
		final cases: Array<Case> = [
			for (v in values)
				{
					values: [{ expr: EConst(CString(v.value)), pos: Context.currentPos() }],
					expr: MacroStringTools.toFieldExpr(pack.concat([simple, v.name]))
				}
		];
		final defaultExpr: Expr = macro throw new anyparse.runtime.ParseError(
			new anyparse.runtime.Span(_errPos, ctx.pos), $v{errMsg} + ': "' + _matched + '"'
		);
		final switchExpr: Expr = { expr: ESwitch(macro _matched, cases, defaultExpr), pos: Context.currentPos() };
		final stringFn: String = 'parse${simpleName(stringType)}';
		final stringCall: Expr = { expr: ECall(macro $i{stringFn}, [macro ctx]), pos: Context.currentPos() };
		return macro {
			skipWs(ctx);
			final _errPos: Int = ctx.pos;
			final _matched: String = $stringCall;
			return $switchExpr;
		};
	}

	private static function lowerTerminalDecodeExpr(
		tc: TerminalCtx, node: ShapeNode, typePath: String, underlying: String, raw: Bool
	): Expr {
		// `@:unescape` on a Terminal abstract generates an inline
		// walk-and-unescape loop using the `@:schema` format's
		// `unescapeChar`. Bare `@:unescape` strips surrounding quotes
		// first; `@:unescape("raw")` and `@:unescape("singleQuoteRaw")`
		// both use the matched string as-is (no quote strip) — they
		// differ only in writer-side escape table (see WriterLowering).
		final unescape: Bool = node.hasMeta(':unescape');
		final unescapeMode: Null<String> = node.readMetaString(':unescape');

		// `@:decode("pkg.Class.method")` on a Terminal abstract names a
		// static function that decodes the matched string into the
		// terminal's underlying type. The path is split on `.` and
		// emitted as `pkg.Class.method(_matched)`.
		final decodePath: Null<String> = node.readMetaString(':decode');

		if (unescape && decodePath != null)
			Context.fatalError('Lowering: terminal $typePath has both @:unescape and @:decode', Context.currentPos());
		if (unescape && raw) Context.fatalError('Lowering: terminal $typePath has both @:unescape and @:rawString', Context.currentPos());

		if (unescape) {
			final fmtParts: Array<String> = tc.formatInfo.schemaTypePath.split('.');
			final bodyExpr: Expr = if (unescapeMode == 'raw' || unescapeMode == 'singleQuoteRaw')
				macro _matched
			else
				macro _matched.substring(1, _matched.length - 1);
			return macro {
				final _body: String = $e{bodyExpr};
				final _buf: StringBuf = new StringBuf();
				var _i: Int = 0;
				while (_i < _body.length) {
					final _c: Int = StringTools.fastCodeAt(_body, _i);
					if (_c == '\\'.code) {
						final _res: anyparse.format.text.TextFormat.UnescapeResult = $p{fmtParts}.instance.unescapeChar(_body, _i + 1);
						_buf.addChar(_res.char);
						_i += 1 + _res.consumed;
					} else {
						_buf.addChar(_c);
						_i++;
					}
				}
				_buf.toString();
			};
		}
		if (decodePath == null) return switch underlying {
			case 'Float': macro Std.parseFloat(_matched);
			case 'Int':
				macro {
					final _v: Null<Int> = Std.parseInt(_matched);
					if (_v == null) {
						throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), 'invalid int literal');
					}
					_v;
				};
			case 'Bool': macro _matched == 'true';
			case 'String' if (raw): macro _matched;
			case 'String':
				Context.fatalError(
					'Lowering: String terminal $typePath requires @:unescape, @:decode, or @:rawString', Context.currentPos()
				);
				throw 'unreachable';
			case _:
				Context.fatalError('Lowering: no decoder for underlying type "$underlying"', Context.currentPos());
				throw 'unreachable';
		};
		final parts: Array<String> = decodePath.split('.');
		return { expr: ECall(macro $p{parts}, [macro _matched]), pos: Context.currentPos() };
	}

}

/**
 * The build state `TerminalParseLowering` reads, bundled once in
 * `Lowering`'s constructor. `eregByRule` is the SAME map instance the
 * owner declares - `lowerTerminal` writes the rule's `EReg` into it as a
 * side effect, exactly as before the split.
 */
typedef TerminalCtx = {
	final formatInfo: FormatReader.FormatInfo;
	final eregByRule: Map<String, GeneratedRule.EregSpec>;
}
#end
