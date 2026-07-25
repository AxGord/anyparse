package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.UniformStatementBlanksPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * `uniformStatementBlanks` collapse policy — "separators that separate
 * everything separate nothing". Inside one statement block (function /
 * if / for / while / plain-block body, never a type member list), when
 * every interior gap between adjacent statements is blank the blanks
 * carry no grouping information and `Collapse` strips them all; a
 * selective mix (or any comment between statements) is left byte-exact.
 *
 * Driving cases mirror TM `src/common/ui/DatePicker.hx`:
 * `onNextMonthClick` [guard; blank; A; blank; B] fully collapses,
 * `onDateClick` [A; blank; B] collapses (2-statement uniform),
 * `onPreviousMonthClick` [guard; blank; A; B] stays untouched, and the
 * `_focusManager` cleanup if-body [cleanup; blank; = null] collapses.
 */
class HxUniformStatementBlanksSliceTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	// onNextMonthClick shape: guard; blank; A; blank; B (uniform, 2/2 gaps blank).
	private static final UNIFORM: String = 'class C {\n\tfunction f() {\n\t\tguard();\n\n\t\ta();\n\n\t\tb();\n\t}\n}\n';

	// onDateClick shape: A; blank; B (uniform, single gap blank).
	private static final TWO: String = 'class C {\n\tfunction f() {\n\t\ta();\n\n\t\tb();\n\t}\n}\n';

	// onPreviousMonthClick shape: guard; blank; A; B (selective, 1/2 gaps blank).
	private static final SELECTIVE: String = 'class C {\n\tfunction f() {\n\t\tguard();\n\n\t\ta();\n\t\tb();\n\t}\n}\n';

	// A; blank; //header; B; blank; C — uniform gaps but a comment between statements.
	private static final COMMENT: String = 'class C {\n\tfunction f() {\n\t\ta();\n\n\t\t// header\n\t\tb();\n\n\t\tc();\n\t}\n}\n';

	// Outer fn body uniform (a; if; b); inner if-body mixed (p; q; blank; r).
	private static final NESTED: String =
		'class C {\n\tfunction f() {\n\t\ta();\n\n\t\tif (x) {\n\t\t\tp();\n\t\t\tq();\n\n\t\t\tr();\n\t\t}\n\n\t\tb();\n\t}\n}\n';

	// if-body 2-statement uniform (cleanup; blank; = null); outer fn body has one stmt.
	private static final IF_BODY: String =
		'class C {\n\tfunction f() {\n\t\tif (m != null) {\n\t\t\tm.cleanup();\n\n\t\t\tm = null;\n\t\t}\n\t}\n}\n';

	public function testDefaultOptionKeepsUniformBlanks(): Void {
		Assert.equals(UniformStatementBlanksPolicy.Keep, HaxeFormat.instance.defaultWriteOptions.uniformStatementBlanks);
	}

	public function testConfigCollapseParsed(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{ "emptyLines": { "uniformStatementBlanks": "collapse" } }'
		);
		Assert.equals(UniformStatementBlanksPolicy.Collapse, opts.uniformStatementBlanks);
	}

	public function testConfigKeepParsed(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{ "emptyLines": { "uniformStatementBlanks": "keep" } }'
		);
		Assert.equals(UniformStatementBlanksPolicy.Keep, opts.uniformStatementBlanks);
	}

	public function testConfigOmittedDefaultsKeep(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(UniformStatementBlanksPolicy.Keep, opts.uniformStatementBlanks);
	}

	public function testUniformThreeStatementCollapses(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tguard();\n\t\ta();\n\t\tb();\n\t}\n}\n';
		Assert.equals(expected, collapse(UNIFORM));
	}

	public function testUniformTwoStatementCollapses(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\ta();\n\t\tb();\n\t}\n}\n';
		Assert.equals(expected, collapse(TWO));
	}

	public function testSelectiveStaysByteExact(): Void {
		Assert.equals(keep(SELECTIVE), collapse(SELECTIVE));
		Assert.isTrue(collapse(SELECTIVE).indexOf('guard();\n\n\t\ta();\n\t\tb();') >= 0);
	}

	public function testCommentBetweenStatementsBails(): Void {
		Assert.equals(keep(COMMENT), collapse(COMMENT));
		Assert.isTrue(collapse(COMMENT).indexOf('a();\n\n\t\t// header') >= 0);
	}

	public function testNestedBlocksEvaluatedIndependently(): Void {
		final expected: String =
			'class C {\n\tfunction f() {\n\t\ta();\n\t\tif (x) {\n\t\t\tp();\n\t\t\tq();\n\n\t\t\tr();\n\t\t}\n\t\tb();\n\t}\n}\n';
		Assert.equals(expected, collapse(NESTED));
	}

	public function testIfBodyUniformCollapses(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tif (m != null) {\n\t\t\tm.cleanup();\n\t\t\tm = null;\n\t\t}\n\t}\n}\n';
		Assert.equals(expected, collapse(IF_BODY));
	}

	public function testKnobOffLeavesUniformBlanksIntact(): Void {
		Assert.notEquals(collapse(UNIFORM), keep(UNIFORM));
		Assert.isTrue(keep(UNIFORM).indexOf('guard();\n\n\t\ta();\n\n\t\tb();') >= 0);
	}

	private static function collapse(source: String): String {
		final base: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final opts: HxModuleWriteOptions = cast Reflect.copy(base);
		opts.uniformStatementBlanks = UniformStatementBlanksPolicy.Collapse;
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast, opts);
	}

	private static function keep(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
