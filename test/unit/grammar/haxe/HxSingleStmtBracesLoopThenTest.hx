package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Gate 8 of `SingleStmtBraces.unwrapStmt` for a loop: under `singleStatementBraces: "remove"` a bare `for` / `while`
 * in then-position gains braces when an `else` follows it, since `if (a) for (…) g(); else h();` reads as if the
 * `else` might bind to the loop - and the `else` gains its own by gate 7. A braced source keeps those braces, a loop
 * with no `else` after it still de-braces, and the `symmetric` policy, which never removes braces, is left alone.
 */
@:nullSafety(Strict)
final class HxSingleStmtBracesLoopThenTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;
	private static final removeConfig: String = '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "remove" } } }';
	private static final symmetricConfig: String = '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "symmetric" } } }';

	@:pin('control')
	@:killer('M-SSB-LOOP-THEN-OFF')
	public function testBareForThenBeforeElseGainsBraces(): Void {
		assertWrites(
			'class C {\n\tfunction f(a:Bool, xs:Array<Int>) {\n\t\tif (a)\n\t\t\tfor (x in xs)\n\t\t\t\tg(x);\n\t\telse\n\t\t\th();\n'
			+ '\t}\n}',
			'class C {\n\tfunction f(a:Bool, xs:Array<Int>) {\n\t\tif (a) {\n\t\t\tfor (x in xs)\n\t\t\t\tg(x);\n\t\t} else {\n'
			+ '\t\t\th();\n\t\t}\n\t}\n}',
			removeConfig
		);
	}

	/** A `while` in the then-position of an `else if` link braces the whole chain, as any brace-keeping link does. */
	@:pin('control')
	@:killer('M-SSB-LOOP-THEN-OFF')
	public function testBareWhileInAnElseIfLinkBracesTheChain(): Void {
		assertWrites(
			'class C {\n\tfunction f(a:Bool, b:Bool) {\n\t\tif (a)\n\t\t\tg();\n\t\telse if (b)\n\t\t\twhile (b)\n\t\t\t\tg();\n'
			+ '\t\telse\n\t\t\th();\n\t}\n}',
			'class C {\n\tfunction f(a:Bool, b:Bool) {\n\t\tif (a) {\n\t\t\tg();\n\t\t} else if (b) {\n\t\t\twhile (b)\n\t\t\t\tg();\n'
			+ '\t\t} else {\n\t\t\th();\n\t\t}\n\t}\n}',
			removeConfig
		);
	}

	/** The keep direction: a braced loop before an `else` is not de-braced, so `fmt` does not undo its own repair. */
	@:pin('control')
	@:killer('M-SSB-LOOP-THEN-KEEP-OFF')
	public function testBracedLoopThenBeforeElseKeepsBraces(): Void {
		final source: String = 'class C {\n\tfunction f(a:Bool, xs:Array<Int>) {\n\t\tif (a) {\n\t\t\tfor (x in xs)\n\t\t\t\tg(x);\n'
			+ '\t\t} else {\n\t\t\th();\n\t\t}\n\t}\n}';
		assertWrites(source, source, removeConfig);
	}

	/** With no `else` after it nothing can seem to bind to the loop, so it de-braces as before. */
	@:pin('control')
	@:killer('M-SSB-LOOP-THEN-WITHOUT-ELSE')
	public function testLoopThenWithoutElseStillDeBraces(): Void {
		assertWrites(
			'class C {\n\tfunction f(a:Bool, xs:Array<Int>) {\n\t\tif (a) {\n\t\t\tfor (x in xs)\n\t\t\t\tg(x);\n\t\t}\n\t}\n}',
			'class C {\n\tfunction f(a:Bool, xs:Array<Int>) {\n\t\tif (a)\n\t\t\tfor (x in xs)\n\t\t\t\tg(x);\n\t}\n}', removeConfig
		);
	}

	/** `symmetric` repairs only an asymmetry, and two bare branches are symmetric: the gate belongs to `remove`. */
	@:pin('control')
	@:killer('M-SSB-LOOP-THEN-SYMMETRIC')
	public function testSymmetricPolicyLeavesABareLoopThen(): Void {
		final source: String = 'class C {\n\tfunction f(a:Bool, xs:Array<Int>) {\n\t\tif (a)\n\t\t\tfor (x in xs)\n\t\t\t\tg(x);\n'
			+ '\t\telse\n\t\t\th();\n\t}\n}';
		assertWrites(source, source, symmetricConfig);
	}

	/**
	 * A loop whose last statement the `else` closes (`for (x in xs) g(x) else`) gets that `;` inside the braces gate 8
	 * builds, and so does an `if` / `else` there: `{ for (x in xs) g(x) }` does not compile.
	 */
	@:pin('control')
	@:killer('M-SSB-WRAP-SPINE-TERMINATOR')
	public function testWrappedThenWritesTheTerminatorTheElseClosed(): Void {
		assertWrites(
			'class C {\n\tfunction f(a:Bool, xs:Array<Int>) {\n\t\tif (a) for (x in xs) g(x) else h();\n\t}\n}',
			'class C {\n\tfunction f(a:Bool, xs:Array<Int>) {\n\t\tif (a) {\n\t\t\tfor (x in xs)\n\t\t\t\tg(x);\n\t\t} else {\n'
			+ '\t\t\th();\n\t\t}\n\t}\n}',
			removeConfig
		);
		assertWrites(
			'class C {\n\tfunction f(a:Bool, b:Bool) {\n\t\tif (a) if (b) g(1) else k() else h();\n\t}\n}',
			'class C {\n\tfunction f(a:Bool, b:Bool) {\n\t\tif (a) {\n\t\t\tif (b)\n\t\t\t\tg(1)\n\t\t\telse\n\t\t\t\tk();\n'
			+ '\t\t} else {\n\t\t\th();\n\t\t}\n\t}\n}',
			removeConfig
		);
	}

	private static function assertWrites(source: String, expected: String, configJson: String): Void {
		final opts: HxModuleWriteOptions = HxWriteOptionsKit.strictJson(configJson);
		final once: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts);
		Assert.equals('$expected\n', once);
		Assert.equals(once, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(once), opts), 'idempotent');
	}

}
