package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A comment in front of a parameter is that parameter's leading comment, and where it lands decides
 * what the next parse reads: one written on the previous parameter's line comes back as THAT
 * parameter's trailing comment, one written on a line of its own comes back own-line. The writer
 * places it so the next write reads the same thing: a single-line block comment the source glued to
 * the parameter stays glued, any other leading comment ends its line.
 */
class HxParamLeadingCommentWriteTest extends Test {

	@:pin('control')
	@:killer('M-CASCADE-LEAD-BREAKS')
	@:killer('M-CLOSE-LOOP-LEAD-UNGLUED')
	public function testAGluedBlockCommentStaysOnItsParameterLine(): Void {
		// Laid out one per line, the comment after `a:Int,` moves to the next line, where it reads as `b`'s
		// leading comment: broken after it there, the second write moved `b` to a line of its own.
		final source: String = 'class A {\n\tfunction p(a:Int, /* c */ b:Int) {}\n}\n\nenum E {\n\tA(a:Int, /* c */ b:Int);\n}\n';
		final expected: String = 'class A {\n\tfunction p(\n\t\ta:Int,\n\t\t/* c */ b:Int\n\t) {}\n}\n\n'
			+ 'enum E {\n\tA(\n\t\ta:Int,\n\t\t/* c */ b:Int\n\t);\n}\n';
		assertWritesOnce('{"wrapping": {"functionSignature": {"defaultWrap": "onePerLine", "rules": []}}}', source, expected);
	}

	@:pin('control')
	@:killer('M-NOWRAP-LEAD-IN-CASCADE')
	public function testAnOwnLineCommentUnderNoWrapLaysTheParametersOutOnePerLine(): Void {
		// A flat `noWrap` cascade put `// c` after `a:Int,`, where the next parse reads it as `a`'s trailing comment.
		final source: String =
			'class A {\n\tfunction p(a:Int,\n\t\t// c\n\t\tb:Int) {}\n\n\tfunction q(a:Int,\n\t\t/* c */ #if x b:Int #end) {}\n}\n';
		final expected: String =
			'class A {\n\tfunction p(\n\t\ta:Int,\n\t\t// c\n\t\tb:Int\n\t) {}\n\n\tfunction q(a:Int, /* c */ #if x b:Int #end) {}\n}\n';
		assertWritesOnce('{"wrapping": {"functionSignature": {"defaultWrap": "noWrap", "rules": []}}}', source, expected);
	}

	/** Under `config`, `source` writes as `expected`, and `expected` writes as itself. */
	private function assertWritesOnce(config: String, source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(expected), opts));
	}

}
