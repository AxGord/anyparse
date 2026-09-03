package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Slice omega-try-brace-symmetry — `whitespace.bracesConfig.singleStatementBraces: "remove"` reaches
 * `try` / `catch` the way it already reaches `if` / `else`: ONE verdict for the try body and every
 * catch body together, wrapping the bare ones when any sibling stays braced and de-bracing the whole
 * group when every member can.
 *
 * Engine wiring: `@:fmt(tryBraceSymmetry(...))` on the body field and
 * `@:fmt(tryCatchBraceSymmetry(...))` on the `catches` Star splice
 * `SingleStmtBraces.trySymmetryBody` / `trySymmetryCatches` around the runtime values;
 * `@:fmt(tryDeBrace)` opts the STATEMENT form into the de-brace half (the value forms stay
 * wrap-only, like `valueBraceSymmetry`). `@:fmt(constructFitGroup('body', 'catches'))` puts the whole
 * construct in one `BodyGroup` so the seams answer the width question together.
 *
 * The battery locks the two directions, the position-sensitive terminator rule (Haxe rejects a `;`
 * in front of `catch`), every refusal, the seam-not-call break under overflow, idempotence and
 * default-off inertness.
 */
@:nullSafety(Strict)
class HxTryBraceSymmetrySliceTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;
	private static final removeConfig: String = '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "remove" } },'
		+ ' "sameLine": { "tryBody": "fitLine", "catchBody": "fitLine", "ifBody": "fitLine" } }';

	public inline function testBracedGroupDeBraces(): Void {
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp();\n\t\t} catch (e:Exception) {\n\t\t\tq();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\ttry p() catch (e:Exception) q();\n\t}\n}'
		);
	}

	public inline function testBareCatchDeBracesWithoutAWrapPass(): Void {
		// The verdict counts an ALREADY bare body as de-braced. Asking "is every body braced" instead
		// would wrap this catch and de-brace it again on the next pass — two rewrites for one answer.
		final source: String = 'class F {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp();\n\t\t} catch (e:Exception) q();\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		final pass1: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		Assert.equals('class F {\n\tfunction f():Void {\n\t\ttry p() catch (e:Exception) q();\n\t}\n}\n', pass1);
	}

	public inline function testMultiStatementCatchBracesTheBareTry(): Void {
		// The wrap direction: the catch cannot lose its braces, so the bare try body gains a block of
		// its own rather than the pair staying half-braced.
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\ttry p() catch (e:Exception) {\n\t\t\tq();\n\t\t\tr();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp();\n\t\t} catch (e:Exception) {\n\t\t\tq();\n\t\t\tr();\n\t\t}\n\t}\n}'
		);
	}

	public inline function testOnlyTheLastCatchKeepsItsTerminator(): Void {
		// KEY safety gate: Haxe rejects a `;` in front of `catch` (`try p(); catch (e) q();` is
		// "Expected }"), so every body but the last renders with its `@:trailOpt(';')` slot cleared.
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp();\n\t\t} catch (e:String) {\n\t\t\tq();\n\t\t} catch (e:Exception) {\n'
			+ '\t\t\tr();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\ttry p() catch (e:String) q() catch (e:Exception) r();\n\t}\n}'
		);
	}

	public inline function testDanglingElseKeepsBraces(): Void {
		// KEY safety gate: the last catch body ends the whole construct, so a de-braced tail ending on
		// an else-less `if` would capture the `else` that follows the try/catch. Those braces are
		// load-bearing and the group keeps all of them.
		roundTrip(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a)\n\t\t\ttry {\n\t\t\t\tp();\n\t\t\t} catch (e:Dynamic) {\n'
			+ '\t\t\t\tif (b) q();\n\t\t\t}\n\t\telse\n\t\t\tr();\n\t}\n}'
		);
	}

	public inline function testIfBodyKeepsBraces(): Void {
		// An `if` statement's own tail carries a `;` the try-body slot cannot clear, so the group
		// refuses rather than emitting `try if (a) b(); catch …`, which does not compile.
		roundTrip(
			'class F {\n\tfunction f(a:Bool):Void {\n\t\ttry {\n\t\t\tif (a) p();\n\t\t} catch (e:Exception) {\n\t\t\tq();\n\t\t}\n\t}\n}'
		);
	}

	public inline function testDeclarationBodyKeepsBraces(): Void {
		roundTrip(
			'class F {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tvar x = p();\n\t\t} catch (e:Exception) {\n\t\t\tq();\n\t\t}\n\t}\n}'
		);
	}

	public inline function testCommentInBodyKeepsBraces(): Void {
		roundTrip(
			'class F {\n\tfunction f():Void {\n\t\ttry {\n\t\t\t// keep me\n\t\t\tp();\n\t\t} catch (e:Exception) {\n\t\t\tq();\n\t\t}\n'
			+ '\t}\n}'
		);
	}

	public inline function testMultiStatementGroupKeepsBraces(): Void {
		roundTrip(
			'class F {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp();\n\t\t\tp2();\n\t\t} catch (e:Exception) {\n\t\t\tq();\n\t\t}\n\t}\n}'
		);
	}

	public inline function testOverflowBreaksAtTheSeamNotInsideTheCall(): Void {
		// The construct group asks the width question ONCE, before the body's own call group commits.
		// Without it the seam answered on the line the body had already broken, and the call had to
		// wrap inside itself to make room for the catch tail. The broken shape is the LADDER an `if`
		// with an `else` produces — each body on its own indented line, the keyword back at the
		// statement indent — because a `catch` follows a try body exactly as an `else` follows a then.
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\tif (saveAfterValidation && origin != result) {\n'
			+ '\t\t\ttry {\n\t\t\t\tsaveContentWithoutChangeTime(path, result);\n\t\t\t} catch (e:Exception) {\n'
			+ '\t\t\t\ttrace(\'DrillValidator::getContent - unable to save this path\');\n\t\t\t}\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\tif (saveAfterValidation && origin != result) try\n'
			+ '\t\t\tsaveContentWithoutChangeTime(path, result)\n\t\tcatch (e:Exception)\n'
			+ '\t\t\ttrace(\'DrillValidator::getContent - unable to save this path\');\n\t}\n}'
		);
	}

	public inline function testValueTryBracesTheBareBody(): Void {
		// The value forms are wrap-only, exactly as `valueBraceSymmetry` leaves a value-`if`: a
		// de-braced value body would need a terminator only the enclosing statement can supply.
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\tfinal v:Int = try p() catch (e:Exception) {\n\t\t\tq();\n\t\t\t0;\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\tfinal v:Int = try {\n\t\t\tp();\n\t\t} catch (e:Exception) {\n\t\t\tq();\n\t\t\t0;\n'
			+ '\t\t}\n\t}\n}'
		);
	}

	public inline function testDeBracedGroupIsIdempotent(): Void {
		final source: String =
			'class F {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp();\n\t\t} catch (e:Exception) {\n\t\t\tq();\n\t\t}\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		final pass1: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		final pass2: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(pass1), opts);
		Assert.equals(pass1, pass2);
	}

	public inline function testDefaultOptionsAreInert(): Void {
		final source: String =
			'class F {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp();\n\t\t} catch (e:Exception) {\n\t\t\tq();\n\t\t}\n\t}\n}';
		assertInert(source, '{}');
		assertInert(source, '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "keep" } } }');
	}

	private static inline function roundTrip(source: String): Void {
		assertInert(source, removeConfig);
	}

	private static function assertFmt(source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		Assert.equals('$expected\n', out);
	}

	/** `source` written back byte-identically under `configJson` — the shape every inertness claim shares. */
	private static function assertInert(source: String, configJson: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(configJson);
		Assert.equals('$source\n', HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
	}

}
