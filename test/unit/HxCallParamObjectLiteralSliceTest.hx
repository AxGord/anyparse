package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-callparam-single-objectlit: under `callParameter.defaultWrap:
 * fillLineWithLeadingBreak`, a call whose SOLE arg is an object literal
 * LEADING-BREAKS the call and keeps the object FLAT on its own indented
 * line when the object fits there; if the object exceeds its own line it
 * stays brace-hugged (`({`) and its fields explode one-per-line. A short
 * object that fits inline is untouched; a block-body lambda arg still
 * hugs (contrast — an object literal is not an arrow-body marker).
 */
@:nullSafety(Strict)
final class HxCallParamObjectLiteralSliceTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testSingleObjectArgFlatFitsLeadingBreaks(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tlist.push(\n\t\t\t{Key: \'134\', Value: \'Are you sure you want to permanently delete your account and all content in cloud?\', Description: \'\'}\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testSingleObjectArgExceedsOwnLineHugsExplodes(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tlist.push({\n\t\t\talpha: source.alphaFieldValue,\n\t\t\tbetaKey: source.betaFieldValue,\n\t\t\tgamma: source.gammaFieldValue,\n\t\t\tdeltaItem: source.deltaFieldValue,\n\t\t\tepsilonKey: source.epsField\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testShortObjectArgStaysInline(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tlist.push({Key: \'1\', Value: \'short\', Description: \'\'});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testBlockLambdaArgStillHugs(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tlist.registerHandlerCallbackHereWithName((resultParameterValueHere) -> {\n\t\t\tprocess(resultParameterValueHere);\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
