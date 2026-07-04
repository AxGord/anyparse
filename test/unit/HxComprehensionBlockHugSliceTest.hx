package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-comprehension-block-hug: under `sameLine.comprehensionFor: fitLine`, an
 * array comprehension whose body is a BLOCK keeps `[ for (...) {` (or
 * `[ while (...) {`) glued on the head line, the block body indenting
 * underneath and `} ]` closing — instead of leading-breaking the `[`. A
 * single-expression comprehension body is untouched; under `comprehensionFor:
 * same` (tight, unpadded brackets) the comprehension leading-breaks as before.
 */
@:nullSafety(Strict)
final class HxComprehensionBlockHugSliceTest extends Test {

	private static final FIT: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "sameLine": {"comprehensionFor": "fitLine"}}';

	private static final SAME: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, "sameLine": {"comprehensionFor": "same"}}';

	public function new(): Void {
		super();
	}

	public function testForBlockBodyComprehensionHugsHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (typeKey => colorList in folderColorsMapValueHere) {\n\t\t\tfinal bitmap = makeBitmapFromColors(colorList);\n\t\t\tbitmap;\n\t\t} ];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, FIT));
	}

	public function testWhileBlockBodyComprehensionHugsHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ while (iteratorValue.hasNextElement()) {\n\t\t\tfinal item = iteratorValue.getNextElement();\n\t\t\ttransformItem(item);\n\t\t} ];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, FIT));
	}

	public function testSingleExprComprehensionStaysInline(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (indexValue in sourceCollectionValue) computeElement(indexValue) ];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, FIT));
	}

	public function testComprehensionForSameLeadingBreaksNoHug(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n\t\t\tfor (typeKey => colorList in folderColorsMapValueHere) {\n\t\t\t\tfinal bitmap = makeBitmapFromColors(colorList);\n\t\t\t\tbitmap;\n\t\t\t}\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, SAME));
	}

	private inline function triviaWrite(src: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
