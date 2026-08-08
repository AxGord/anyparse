package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-blank-around-multiline-members — a member that renders across more than
 * one line is separated from its neighbours by a blank line.
 *
 * The discriminating case is `testSourceMultilineThatCollapsesGetsNoBlank`:
 * the predicate has to be asked of the RENDERED Doc, not of the source shape.
 * A source-shape answer would put a blank around a declaration that ends up
 * on one line — separating nothing from nothing.
 */
@:nullSafety(Strict)
class HxBlankAroundMultilineMembersTest extends Test {

	private static inline final WIDE: String = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

	/** Knob on: one blank line around any multi-line member. */
	private static final ON: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, '
		+ '"emptyLines": {"aroundMultilineFields": 1}}';

	/** Same config with the knob absent — the pre-slice behaviour. */
	private static final OFF: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}}';

	/**
	 * Knob on, plus the array config that lets a fitting literal collapse —
	 * the only way a source-multiline member can come back single-line, which
	 * is what separates a Doc-measured predicate from a source-shape one.
	 */
	private static final ON_COLLAPSING: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"wrapping": {"maxLineLength": 140, "arrayWrap": {"defaultWrap": "ignore", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, '
		+ '"emptyLines": {"aroundMultilineFields": 1}}';

	public function new(): Void {
		super();
	}

	public function testBlankAppearsBetweenMultilineAndSingleLine(): Void {
		final src: String =
			'class C {\n\tstatic final a:Array<String> = [\n\t\t\'$WIDE\',\n\t\t\'$WIDE\'\n\t];\n\tstatic final b:Int = 1;\n}';
		Assert.isTrue(
			write(src, ON).indexOf('];\n\n\tstatic final b') != -1, 'expected a blank after the multi-line member in:\n<${write(src, ON)}>'
		);
	}

	public function testBlankAppearsBeforeAMultilineMember(): Void {
		final src: String =
			'class C {\n\tstatic final a:Int = 1;\n\tstatic final b:Array<String> = [\n\t\t\'$WIDE\',\n\t\t\'$WIDE\'\n\t];\n}';
		Assert.isTrue(
			write(src, ON).indexOf('= 1;\n\n\tstatic final b') != -1,
			'expected a blank before the multi-line member in:\n<${write(src, ON)}>'
		);
	}

	public function testTwoSingleLineMembersStayTogether(): Void {
		final src: String = 'class C {\n\tstatic final a:Int = 1;\n\tstatic final b:Int = 2;\n}';
		Assert.isTrue(write(src, ON).indexOf('= 1;\n\tstatic final b') != -1, 'single-line neighbours must not gain a blank');
	}

	public function testExistingBlankIsNotDoubled(): Void {
		final src: String =
			'class C {\n\tstatic final a:Array<String> = [\n\t\t\'$WIDE\',\n\t\t\'$WIDE\'\n\t];\n\n\tstatic final b:Int = 1;\n}';
		Assert.isTrue(write(src, ON).indexOf('];\n\n\n') == -1, 'the knob tops the gap up, it does not add to it');
	}

	public function testSourceMultilineThatCollapsesGetsNoBlank(): Void {
		// Written across lines but short enough to come back as one — no blank.
		final src: String = 'class C {\n\tstatic final a:Array<Int> = [\n\t\t1,\n\t\t2\n\t];\n\tstatic final b:Int = 1;\n}';
		final out: String = write(src, ON_COLLAPSING);
		Assert.isTrue(out.indexOf('[1, 2];') != -1, 'precondition: the literal must collapse in:\n<$out>');
		Assert.isTrue(out.indexOf('];\n\n') == -1, 'a collapsed member is single-line and separates nothing');
	}

	public function testKnobOffIsByteIdentical(): Void {
		final src: String =
			'class C {\n\tstatic final a:Array<String> = [\n\t\t\'$WIDE\',\n\t\t\'$WIDE\'\n\t];\n\tstatic final b:Int = 1;\n}';
		Assert.isTrue(write(src, OFF).indexOf('];\n\tstatic final b') != -1, 'with the knob absent the gap stays as authored');
	}

	public function testWriterIsItsOwnFixedPoint(): Void {
		final src: String =
			'class C {\n\tstatic final a:Array<String> = [\n\t\t\'$WIDE\',\n\t\t\'$WIDE\'\n\t];\n\tstatic final b:Int = 1;\n}';
		final once: String = write(src, ON);
		Assert.equals(once, write(once, ON), 'a second pass must reproduce the first');
	}

	private static inline function write(src: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
