package unit;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-objectlit-rest-probe — `HxObjectLit.fields` opts into
 * `@:fmt(groupRestProbe)` so the flat-fit decision subtracts the width of
 * whatever trails the closing `}` on the same line (`;`, `,`, `);`, …).
 *
 * A plain `Group` measures only the literal's own flat width from its
 * column, so a literal that ends exactly AT `maxLineLength` was kept flat
 * and its trailing `;` then pushed the rendered line past the limit.
 * `HxType.Anon` already carried the flag; the object literal did not, and
 * a real tree produced lines 1-2 columns over as a result.
 */
@:nullSafety(Strict)
class HxObjectLitRestProbeTest extends Test {

	/** `final v:Dynamic = {aa: 1, bb: 22};` renders flat at exactly 42 columns (2 tabs of 4 + 34). */
	private static final SRC: String =
		'class C {\n\tfunction f():Void {\n\t\tfinal v:Dynamic = {\n\t\t\taa: 1,\n\t\t\tbb: 22\n\t\t};\n\t}\n}';

	private static final FLAT: String = 'final v:Dynamic = {aa: 1, bb: 22};';

	public function new(): Void {
		super();
	}

	public function testStaysFlatWhenTheWholeLineFits(): Void {
		final out: String = write(42);
		Assert.isTrue(out.indexOf(FLAT) != -1, 'expected flat literal at maxLineLength 42 in:\n<$out>');
	}

	public function testBreaksWhenOnlyTheTrailingSemicolonOverflows(): Void {
		// At 41 the literal itself still ends within budget (41 columns up to
		// `}`) — only the trailing `;` pushes the line over. Without the
		// rest probe the cascade kept it flat and emitted a 42-column line.
		final out: String = write(41);
		Assert.isTrue(out.indexOf(FLAT) == -1, 'expected the literal to break at maxLineLength 41 in:\n<$out>');
		Assert.isTrue(out.indexOf('final v:Dynamic = {\n') != -1, 'expected a leading break after `{` in:\n<$out>');
	}

	private static function write(maxLineLength: Int): String {
		final config: String = '{"wrapping": {"maxLineLength": $maxLineLength, "objectLiteral": {"defaultWrap": "ignore", "rules": ['
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLineWithLeadingBreak"}]}}}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(SRC), opts);
	}

}
