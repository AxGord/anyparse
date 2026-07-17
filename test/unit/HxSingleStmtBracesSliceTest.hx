package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice ω-single-stmt-braces — `whitespace.bracesConfig.
 * singleStatementBraces: "remove"` drops the curly braces around a
 * single-statement `if` / `else` / `for` / `while` body
 * (`if (c) { return x; }` → `if (c) return x;`).
 *
 * Engine wiring: `@:fmt(dropSingleStmtBraces)` on `HxIfStmt.thenBody`
 * / `HxIfStmt.elseBody` / `HxForStmt.body` / `HxWhileStmt.body`
 * splices `SingleStmtBraces.unwrapStmt` around the body value in
 * `WriterLowering` (trivia mode only); the loader maps the JSON key
 * onto `HxModuleWriteOptions.dropSingleStmtBraces` (default `false` —
 * byte-inert, corpus flip-0).
 *
 * The battery locks every safety gate: multi-statement, dangling-else
 * (direct AND through a nested loop body via the `_ssbSuppress`
 * frame), comments, missing terminator, declaration scoping — each
 * fails closed (braces kept) — plus the else-if collapse, layout
 * parity, idempotence and default-off inertness.
 */
@:nullSafety(Strict)
class HxSingleStmtBracesSliceTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	private static final removeConfig: String = '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "remove" } },'
		+ ' "sameLine": { "ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine", "doWhileBody": "same" } }';

	public function testDefaultOptionsKeepBraces(): Void {
		Assert.isFalse(HaxeFormat.instance.defaultWriteOptions.dropSingleStmtBraces);
	}

	public function testLoaderMapsRemove(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		Assert.isTrue(opts.dropSingleStmtBraces);
	}

	public function testLoaderExplicitKeepStaysOff(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{ "whitespace": { "bracesConfig": { "singleStatementBraces": "keep" } } }'
		);
		Assert.isFalse(opts.dropSingleStmtBraces);
	}

	public function testLoaderOmittedStaysOff(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.isFalse(opts.dropSingleStmtBraces);
	}

	public function testSingleStmtIfUnbraced(): Void {
		assertFmt(
			'class F {\n\tfunction f(a:Bool):Bool {\n\t\tif (a) {\n\t\t\treturn true;\n\t\t}\n\t\treturn false;\n\t}\n}',
			'class F {\n\tfunction f(a:Bool):Bool {\n\t\tif (a) return true;\n\t\treturn false;\n\t}\n}'
		);
	}

	public function testMultiStmtKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tone();\n\t\t\ttwo();\n\t\t}\n\t}\n}');
	}

	public function testDanglingElseKeepsBraces(): Void {
		// KEY safety gate: dropping the outer braces would rebind `else`
		// to the inner else-less `if`.
		roundTrip('class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tif (b) x();\n\t\t} else\n\t\t\ty();\n\t}\n}');
	}

	public function testDanglingElseThroughLoopBodyKeepsBraces(): Void {
		// KEY safety gate (suppress frame): the loop body itself sees no
		// `else`, but unwrapping `{ if (b) x(); }` inside the then-body of
		// an if-with-else would rebind the outer `else` to `if (b)`.
		assertFmt(
			'class F {\n\tfunction f(a:Bool, b:Bool, c:Bool):Void {\n\t\tif (a) while (c) {\n\t\t\tif (b) x();\n\t\t} else y();\n\t}\n}',
			'class F {\n\tfunction f(a:Bool, b:Bool, c:Bool):Void {\n\t\tif (a)\n\t\t\twhile (c) {\n\t\t\t\tif (b) x();\n\t\t\t}\n\t\telse\n\t\t\ty();\n\t}\n}'
		);
	}

	public function testElseIfChainStaysValid(): Void {
		assertFmt(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tx();\n\t\t} else if (b) {\n\t\t\ty();\n\t\t} else {\n\t\t\tz();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a)\n\t\t\tx();\n\t\telse if (b)\n\t\t\ty();\n\t\telse\n\t\t\tz();\n\t}\n}'
		);
	}

	public function testElseBlockSingleIfCollapsesToElseIf(): Void {
		assertFmt(
			'class F {\n\tfunction f(a:Bool, c:Bool):Void {\n\t\tif (a) y(); else {\n\t\t\tif (c) x();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(a:Bool, c:Bool):Void {\n\t\tif (a)\n\t\t\ty();\n\t\telse if (c)\n\t\t\tx();\n\t}\n}'
		);
	}

	public function testLeadingCommentKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\t// keep me\n\t\t\tx();\n\t\t}\n\t}\n}');
	}

	public function testTrailingCommentKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tx(); // trailing\n\t\t}\n\t}\n}');
	}

	public function testCommentBeforeCloseKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tx();\n\t\t\t// before close\n\t\t}\n\t}\n}');
	}

	public function testMissingSemicolonKeepsBraces(): Void {
		// `{ return true }` — the braceless form would not re-parse
		// before a `}` (Slice-V statement boundary), so braces stay.
		roundTrip('class F {\n\tfunction f(a:Bool):Bool {\n\t\tif (a) {\n\t\t\treturn true\n\t\t}\n\t\treturn false;\n\t}\n}');
	}

	public function testVarDeclKeepsBraces(): Void {
		// The braces scope the binding — dropping them would widen it.
		roundTrip('class F {\n\tfunction f(a:Bool):Void {\n\t\tif (a) {\n\t\t\tvar t = 1;\n\t\t}\n\t}\n}');
	}

	public function testForBodyUnbraced(): Void {
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\tfor (i in 0...3) {\n\t\t\ttrace(i);\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\tfor (i in 0...3) trace(i);\n\t}\n}'
		);
	}

	public function testWhileBodyUnbraced(): Void {
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\twhile (cond()) {\n\t\t\tstep();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\twhile (cond()) step();\n\t}\n}'
		);
	}

	public function testNestedIfNoElseUnbraced(): Void {
		assertFmt(
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tif (b) x();\n\t\t}\n\t}\n}',
			'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) if (b) x();\n\t}\n}'
		);
	}

	public function testIdempotentAndReparses(): Void {
		final source: String = 'class F {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tif (b) x();\n\t\t} else\n\t\t\ty();\n\t\tif (a) {\n\t\t\treturn;\n\t\t}\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		final pass1: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		final pass2: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(pass1), opts);
		Assert.equals(pass1, pass2);
	}

	public function testDefaultConfigKeepsBracesByteIdentical(): Void {
		final source: String = 'class F {\n\tfunction f(a:Bool):Bool {\n\t\tif (a) {\n\t\t\treturn true;\n\t\t}\n\t\treturn false;\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		Assert.equals(source + '\n', out);
	}

	private static function assertFmt(source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		Assert.equals(expected + '\n', out);
	}

	private static function roundTrip(source: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(removeConfig);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		Assert.equals(source + '\n', out);
	}


	public function testDoWhileBodyUnbraced(): Void {
		// The mapped ExprBody drops the `;` — modern Haxe rejects
		// `do i++; while (…)` ("Expected while"); `do i++ while (…);` is
		// the valid braceless form.
		assertFmt(
			'class F {\n\tfunction f():Void {\n\t\tvar i = 0;\n\t\tdo {\n\t\t\ti++;\n\t\t} while (i < 3);\n\t}\n}',
			'class F {\n\tfunction f():Void {\n\t\tvar i = 0;\n\t\tdo i++ while (i < 3);\n\t}\n}'
		);
	}


	public function testDoWhileMultiStmtKeepsBraces(): Void {
		roundTrip('class F {\n\tfunction f():Void {\n\t\tdo {\n\t\t\tone();\n\t\t\ttwo();\n\t\t} while (cond());\n\t}\n}');
	}


	public function testDoWhileNonExprStmtKeepsBraces(): Void {
		// Only an ExprStmt has an `HxDoWhileBody.ExprBody` counterpart —
		// any other statement kind keeps its braces.
		roundTrip('class F {\n\tfunction f():Void {\n\t\tdo {\n\t\t\treturn;\n\t\t} while (cond());\n\t}\n}');
	}

}
