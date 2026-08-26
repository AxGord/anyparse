package unit;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-packed-or-oneperline — `WrapMode.PackedOrOnePerLine`, the all-or-nothing
 * middle between `FillLine*` (packs greedily, leaves ragged lines) and
 * `OnePerLine` (never uses the continuation line even when everything fits).
 *
 * The fixture has three exact boundaries, all measured on the same source:
 * the flat line is 51 columns, the packed continuation line is 34.
 */
@:nullSafety(Strict)
class HxPackedOrOnePerLineTest extends Test {

	private static final SRC: String = 'class C {\n\tfunction f():Void {\n\t\tfinal v:Dynamic = {aaa: 1, bbb: 2, ccc: 3};\n\t}\n}';

	/** The whole statement on one line — 51 columns at 2 tabs of 4. */
	private static final FLAT: String = '\t\tfinal v:Dynamic = {aaa: 1, bbb: 2, ccc: 3};';

	/** Open delim broken, every field on the one continuation line — 34 columns. */
	private static final PACKED: String = 'final v:Dynamic = {\n\t\t\taaa: 1, bbb: 2, ccc: 3\n\t\t};';

	private static final ONE_PER_LINE: String = 'final v:Dynamic = {\n\t\t\taaa: 1,\n\t\t\tbbb: 2,\n\t\t\tccc: 3\n\t\t};';

	public function new(): Void {
		super();
	}

	public function testFlatWhenTheWholeStatementFits(): Void {
		final out: String = write(51);
		Assert.isTrue(out.indexOf(FLAT) != -1, 'expected the flat statement at maxLineLength 51 in:\n<$out>');
	}

	public function testPacksOntoOneContinuationLineWhenItFitsThere(): Void {
		// 50 is one column short of the flat statement but well past the
		// 34-column continuation line — the whole point of the mode.
		final out: String = write(50);
		Assert.isTrue(out.indexOf(PACKED) != -1, 'expected a single packed continuation line at maxLineLength 50 in:\n<$out>');
	}

	public function testStillPacksAtTheContinuationBoundary(): Void {
		final out: String = write(34);
		Assert.isTrue(out.indexOf(PACKED) != -1, 'expected the packed line to survive at its exact width 34 in:\n<$out>');
	}

	public function testOnePerLineWhenTheContinuationLineOverflows(): Void {
		// One column below the packed line's width. `FillLine*` would emit a
		// ragged `aaa: 1, bbb: 2,` / `ccc: 3` pair here; this mode must not.
		final out: String = write(33);
		Assert.isTrue(out.indexOf(ONE_PER_LINE) != -1, 'expected one field per line at maxLineLength 33 in:\n<$out>');
	}

	public function testItemWithAForcedHardlineNeverPacks(): Void {
		// A field whose value is itself multi-line makes the packed line
		// impossible — the "one continuation line" it promises would already
		// be several. The shape must not delegate that to the renderer's fit
		// probe, which walks the nested list's own Group and re-flattens it.
		final src: String =
			'class C {\n\tfunction f():Dynamic {\n\t\treturn {\n\t\t\taa: [\n\t\t\t\t1,\n\t\t\t\t2\n\t\t\t],\n\t\t\tbb: 3\n\t\t};\n\t}\n}';
		final out: String = writeSrc(src, 140);
		Assert.isTrue(out.indexOf('], bb: 3') == -1, 'expected no packing past a multi-line field in:\n<$out>');
		Assert.isTrue(out.indexOf('\n\t\t\tbb: 3\n') != -1, 'expected `bb` on its own line in:\n<$out>');
	}

	private static inline function write(maxLineLength: Int): String {
		return writeSrc(SRC, maxLineLength);
	}

	private static function writeSrc(src: String, maxLineLength: Int): String {
		final config: String = '{"wrapping": {"maxLineLength": $maxLineLength, "objectLiteral": {"defaultWrap": "ignore", "rules": ['
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]}}}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
