package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Bracket-whitespace parity for array comprehensions vs plain array /
 * map literals. haxe-formatter couples a comprehension's bracket
 * padding to `sameLine.comprehensionFor`: `fitLine` pads the brackets
 * (`[ for (x in y) x ]`, overriding any `bracketConfig` policy) while
 * `same` (the fork default) leaves them tight (`[for (x in y) x]`).
 * Plain array (`[1, 2, 3]`) and map (`[k => v]`) literals stay tight
 * regardless — the three kinds share one grammar ctor
 * (`HxExpr.ArrayExpr`) and the writer dispatches on the first element.
 */
@:nullSafety(Strict)
class HxComprehensionBracketPolicyTest extends Test {

	public function new(): Void {
		super();
	}

	public function testDefaultComprehensionBracketsTight(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(WhitespacePolicy.None, opts.comprehensionBracketsOpen);
		Assert.equals(WhitespacePolicy.None, opts.comprehensionBracketsClose);
	}

	public function testDefaultComprehensionFormatsTight(): Void {
		final out: String = write('class M { static function f() { var a = [for (x in y) x]; } }', '{}');
		Assert.isTrue(out.indexOf('[for (x in y) x]') != -1, 'expected tight comprehension in: <$out>');
	}

	public function testComprehensionForFitLinePadsOptions(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine":{"comprehensionFor":"fitLine"}}');
		Assert.equals(WhitespacePolicy.After, opts.comprehensionBracketsOpen);
		Assert.equals(WhitespacePolicy.Before, opts.comprehensionBracketsClose);
	}

	public function testComprehensionForFitLineFormatsPadded(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"fitLine"}}';
		final out: String = write('class M { static function f() { var a = [for (x in y) x]; } }', json);
		Assert.isTrue(out.indexOf('[ for (x in y) x ]') != -1, 'expected padded comprehension in: <$out>');
	}

	public function testWhileComprehensionForFitLineFormatsPadded(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"fitLine"}}';
		final out: String = write('class M { static function f() { var a = [while (c) x]; } }', json);
		Assert.isTrue(out.indexOf('[ while (c) x ]') != -1, 'expected padded while-comprehension in: <$out>');
	}

	public function testComprehensionForSameKeepsTight(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"same"}}';
		final out: String = write('class M { static function f() { var a = [for (x in y) x]; } }', json);
		Assert.isTrue(out.indexOf('[for (x in y) x]') != -1, 'expected tight comprehension under comprehensionFor=same in: <$out>');
	}

	public function testArrayLiteralStaysTightUnderFitLine(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"fitLine"}}';
		final out: String = write('class M { static function f() { var a = [1, 2, 3]; } }', json);
		Assert.isTrue(out.indexOf('[1, 2, 3]') != -1, 'expected tight array literal in: <$out>');
	}

	public function testMapLiteralStaysTightUnderFitLine(): Void {
		final json: String = '{"sameLine":{"comprehensionFor":"fitLine"}}';
		final out: String = write('class M { static function f() { var a = [k => v, k2 => v2]; } }', json);
		Assert.isTrue(out.indexOf('[k => v, k2 => v2]') != -1, 'expected tight map literal in: <$out>');
	}

	public function testExplicitBracketConfigPadsComprehension(): Void {
		final json: String = '{"whitespace":{"bracketConfig":{"comprehensionBrackets":{"openingPolicy":"after","closingPolicy":"before"}}}}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(WhitespacePolicy.After, opts.comprehensionBracketsOpen);
		Assert.equals(WhitespacePolicy.Before, opts.comprehensionBracketsClose);
	}

	private inline function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
