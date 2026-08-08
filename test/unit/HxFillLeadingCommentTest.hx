package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-fill-leading-comment — a fill whose FIRST item opens with the comment that
 * preceded it in the source must break after the open delimiter.
 *
 * Packed flat the comment lands glued to the delimiter (`[// note`), and that
 * is not a cosmetic defect: re-parsed, a `//` sitting on the open line is a
 * TRAILING comment of the delimiter rather than a LEADING comment of the first
 * element. The list then lays out differently on the next pass — the writer
 * stops being its own fixed point, and every writer-emit op refuses the file
 * it just wrote.
 */
@:nullSafety(Strict)
class HxFillLeadingCommentTest extends Test {

	/** Enough items to select the fill rule, with a line comment before the first. */
	private static final SRC: String = 'class C {\n\tstatic final data:Array<Int> = [\n\t\t// a leading line comment\n'
		+ [for (i in 0...24) '\t\t${i}'].join(',\n') + '\n\t];\n}';

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"arrayWrap": {"defaultWrap": "ignore", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "itemCount >= n", "value": 20}], "type": "fillLine"}]}}}';

	public function new(): Void {
		super();
	}

	public function testCommentKeepsItsOwnLine(): Void {
		final out: String = write(SRC);
		Assert.isTrue(out.indexOf('[//') == -1, 'the comment must not be glued to the open delimiter in:\n<$out>');
		Assert.isTrue(out.indexOf('[\n\t\t// a leading line comment\n') != -1, 'expected the comment on its own line in:\n<$out>');
	}

	public function testWriterIsItsOwnFixedPoint(): Void {
		final once: String = write(SRC);
		Assert.equals(once, write(once), 'a second pass must reproduce the first');
	}

	private static inline function write(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
