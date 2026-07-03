package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-condwrap-fitline-construct-group: `sameLine.ifBody: fitLine` decides
 * same-vs-next by whether the WHOLE construct fits one line — the cond
 * and body are spliced into one construct-level group, so a condition
 * that committed to its wrapped shape (`if (\n\tcond\n)`) forces the
 * body onto the next line instead of gluing `) return x;`, and a flat
 * condition whose line would overflow once the body rides it also
 * pushes the body down. Short constructs keep the same-line glue.
 */
@:nullSafety(Strict)
final class HxCondWrapFitLineSliceTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "sameLine": {"ifBody": "fitLine"}}';

	public function new(): Void {
		super();
	}

	public function testWrappedCondForcesBodyNextLine(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (\n\t\t\tcounterLocalDeleted > counterLocalUpdated && counterLocalDeleted > counterCloudDeleted\n\t\t\t&& counterLocalDeleted > counterCloudUpdatedNotSynced\n\t\t)\n\t\t\treturn ACTION_ONE;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testFlatCondWithFittingBodyStaysSameLine(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (counterPathValue == Config.READONLY_SEGMENT || counterPathValue.startsWith(Config.READONLY_SEGMENT_SLASH)) return null;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testTrailingCommentCountsIntoFit(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (counterPathValue == Config.READONLY_SEGMENT || counterPathValue.startsWith(Config.READONLY_SEGMENT_SLASH))\n\t\t\treturn null; // operation not available on this resource\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testShortConstructKeepsSameLine(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (shortCond) return quick();\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
