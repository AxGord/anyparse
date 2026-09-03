package unit.grammar.haxe;

import anyparse.format.comment.FormatterOff;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-formatter-off — `// @formatter:off` freezes the source bytes it covers.
 *
 * The cases that matter are the ones where the marker must NOT fire: a
 * near-miss spelling, the same text inside a string literal. A restore that
 * triggers where the fork's would not turns the corpus from an oracle into
 * noise, and freezes layout the author never asked to freeze.
 */
@:nullSafety(Strict)
class HxFormatterOffTest extends Test {

	/** A layout no rule would produce, so a reflow is unmistakable. */
	private static final HAND_LAID: String = '\t\tfinal a = [ 1,2,3,\n\t\t             4,5,6 ];';

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}}';

	public function new(): Void {
		super();
	}

	public function testRegionRunsToEndOfFileWithoutOn(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t// @formatter:off\n$HAND_LAID\n\t}\n}';
		Assert.isTrue(format(src).indexOf(HAND_LAID) != -1, 'an unterminated region must reach the last line');
	}

	public function testFormattingResumesAfterOn(): Void {
		final src: String =
			'class C {\n\tfunction f() {\n\t\t// @formatter:off\n$HAND_LAID\n\t\t// @formatter:on\n\t\tfinal b = [ 1,2,3 ];\n\t}\n}';
		final out: String = format(src);
		Assert.isTrue(out.indexOf(HAND_LAID) != -1, 'the region must survive verbatim in:\n<$out>');
		Assert.isTrue(out.indexOf('final b = [1, 2, 3];') != -1, 'the code after `on` must be formatted in:\n<$out>');
	}

	public function testFileWithoutMarkersIsUntouched(): Void {
		final src: String = 'class C {\n\tfunction f() {\n$HAND_LAID\n\t}\n}';
		Assert.isTrue(format(src).indexOf(HAND_LAID) == -1, 'without a marker the hand layout must be reflowed');
	}

	public function testMarkerInsideStringLiteralIsNotAMarker(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal s = "// @formatter:off";\n$HAND_LAID\n\t}\n}';
		Assert.isTrue(format(src).indexOf(HAND_LAID) == -1, 'a marker spelt inside a string must not open a region');
	}

	public function testMarkerWithoutTheSpaceIsNotAMarker(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t//@formatter:off\n$HAND_LAID\n\t}\n}';
		Assert.isTrue(format(src).indexOf(HAND_LAID) == -1, '`//@formatter:off` is not the fork\'s marker');
	}

	public function testTrailingMarkerFreezesFromItsOwnLine(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal z = 0; // @formatter:off\n$HAND_LAID\n\t}\n}';
		final out: String = format(src);
		Assert.isTrue(out.indexOf('final z = 0; // @formatter:off') != -1, 'the marker\'s own line is part of the region in:\n<$out>');
		Assert.isTrue(out.indexOf(HAND_LAID) != -1, 'the region must survive verbatim in:\n<$out>');
	}

	public function testSecondOffInsideARegionIsPlainText(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t// @formatter:off\n$HAND_LAID\n\t\t// @formatter:off\n\t\t// @formatter:on\n'
			+ '\t\tfinal b = [ 1,2,3 ];\n\t}\n}';
		final out: String = format(src);
		Assert.isTrue(out.indexOf(HAND_LAID) != -1, 'the first `off` opens the only region in:\n<$out>');
		Assert.isTrue(out.indexOf('final b = [1, 2, 3];') != -1, 'the first `on` closes it in:\n<$out>');
	}

	public function testOnWithoutOffIsIgnored(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t// @formatter:on\n$HAND_LAID\n\t}\n}';
		Assert.isTrue(format(src).indexOf(HAND_LAID) == -1, 'a bare `on` must not freeze anything');
	}

	public function testRestoreIsIdentityWhenTheSourceDeclaresNoRegion(): Void {
		final written: String = 'class C {}\n';
		Assert.equals(written, FormatterOff.restore('class  C  {}\n', written, HaxeLexicalRegions.scanComments));
	}

	/**
	 * A marker spelt on its OWN LINE inside a MULTI-LINE string literal is still not a marker.
	 *
	 * This is the discriminating twin of `testMarkerInsideStringLiteralIsNotAMarker`, and it
	 * exists because that one is NOT discriminating: its marker sits on a single-line literal,
	 * so a line-only scanner that knew nothing of strings would read the comment body as
	 * `// @formatter:off";` — trailing quote and semicolon included — which is not the exact
	 * marker text and opens nothing. MEASURED: replacing `FormatterOff`'s `CommentScan` with a
	 * naive `//`-to-end-of-line walk left the whole suite green. Here the marker line ends at a
	 * real newline INSIDE the literal, so the naive body is exactly the marker and the region
	 * opens — which is what makes the seam observable.
	 */
	public function testMarkerOnItsOwnLineInsideAMultiLineStringIsNotAMarker(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal s = "x\n// @formatter:off\ny";\n$HAND_LAID\n\t}\n}';
		Assert.isTrue(format(src).indexOf(HAND_LAID) == -1, 'a marker line inside a string literal must not open a region');
	}

	private static inline function format(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		return FormatterOff.restore(
			src, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts), HaxeLexicalRegions.scanComments
		);
	}

}
