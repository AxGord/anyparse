package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.format.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/**
 * The fork fixture `issue_216_typedef_without_semicolon_unstable_comments` expects a typedef pair with the source
 * blank between them dropped; the writer keeps it, so the fixture is a registered fork defect, not an unexplained FAIL.
 */
class HxFormatterCorpusForkLossyTest extends Test {

	private static final FIXTURE: String = 'test/testcases/lineends/issue_216_typedef_without_semicolon_unstable_comments.hxtest';

	/** The premise of the listing: the writer keeps the blank, so the fork's expected text is the one that loses it. */
	@:pin('guard')
	public function testWriterKeepsTheSourceBlank(): Void {
		final input: String = 'typedef Bar = Float\n\ntypedef Foo = Int;\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterFieldsWithDocComments": "ignore"}}'
		);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(input), opts);
		Assert.isTrue(out.indexOf('typedef Bar = Float\n\ntypedef Foo = Int;') >= 0, out);
	}

	@:pin('guard')
	public function testFixtureIsRegisteredAsForkDefect(): Void {
		Assert.isTrue(HxFormatterCorpusHelpers.FORK_LOSSY.contains(FIXTURE));
	}

}
