package unit.grammar.haxe;

import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.Suppression;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * ω-line-comment-indent — the writer knob
 * `whitespace.normalizeLineCommentIndent` (default `false`, absent =
 * byte-inert).
 *
 * When on, `//` bodies whose first non-whitespace character is an ASCII
 * letter or digit lose their run's COMMON post-`//` indent and get exactly
 * one space; relative indentation inside a contiguous run survives, so a
 * block of commented-out code keeps its structure while the shared
 * over-indent goes. Bodies that are empty or start (after whitespace) with
 * any other character — dividers, markers, `///` — are skipped: they
 * neither contribute to nor break the run and fall through to the
 * pre-existing `addLineCommentSpace` path.
 *
 * Every case drives the real entry points (`HaxeModuleTriviaParser.parse`
 * -> `HaxeFormatConfigLoader.loadHxFormatJson` ->
 * `HaxeModuleTriviaWriter.write`), so the pins cover the writer's actual
 * line-comment chokepoints rather than the normalizer in isolation.
 */
class HxLineCommentIndentSliceTest extends Test {

	private static final KNOB_ON: String = '{"whitespace": {"normalizeLineCommentIndent": true}}';
	private static final KNOB_ABSENT: String = '{}';
	private static final KNOB_ON_NO_SPACE: String = '{"whitespace": {"normalizeLineCommentIndent": true, "addLineCommentSpace": false}}';
	private static final FILE: String = 'unit/Roster.hx';

	/**
	 * Two contiguous `//` lines at an identical 8-space post-`//` indent.
	 * Shape anonymised from a real file-list controller body.
	 */
	private static final UNIFORM_RUN: String =
		'class Roster {\n\tfunction sweep() {\n\t\t//        total -= batch.length;\n\t\t//        batch.resize(0);\n\t\trender();\n\t}\n}';

	/** Three `//` lines whose post-`//` indents differ by one nesting step. */
	private static final RELATIVE_RUN: String =
		'class Roster {\n\tfunction sweep() {\n\t\t//    alpha();\n\t\t//        beta();\n\t\t//    gamma();\n\t\trender();\n\t}\n}';

	/** A run with no common prefix because one member sits flush against the slashes. */
	private static final FLUSH_MIX: String = 'class Roster {\n\t// alpha detail line\n\t//beta();\n\tvar x:Int;\n}';

	/** A run with no common prefix because its members disagree on tab-vs-space. */
	private static final TAB_MIX: String = 'class Roster {\n\t// prose head line\n\t//\tcontinuation line\n\tvar x:Int;\n}';

	/**
	 * The knob is absent from the config, so the writer must emit exactly the
	 * pre-knob bytes: an over-indented `//` body starts with whitespace, hits
	 * the legacy decoration branch and survives verbatim.
	 */
	public function testKnobAbsentIsByteInert(): Void {
		Assert.equals('$UNIFORM_RUN\n', formatted(UNIFORM_RUN, KNOB_ABSENT));
		Assert.equals('$RELATIVE_RUN\n', formatted(RELATIVE_RUN, KNOB_ABSENT));
	}

	/**
	 * Knob on: a run at one uniform post-`//` indent collapses to exactly one
	 * space on every line, so the two comments stay aligned with each other.
	 */
	public function testUniformRunCollapsesToOneSpace(): Void {
		final out: String = formatted(UNIFORM_RUN, KNOB_ON);
		Assert.equals(
			'class Roster {\n\tfunction sweep() {\n\t\t// total -= batch.length;\n\t\t// batch.resize(0);\n\t\trender();\n\t}\n}\n', out
		);
	}

	/**
	 * Only the run's COMMON indent is stripped, so the nesting step between
	 * the lines survives: 4/8/4 spaces become 0/4/0 on top of the single
	 * space every normalised body gets.
	 */
	public function testRelativeIndentPreservedInRun(): Void {
		final out: String = formatted(RELATIVE_RUN, KNOB_ON);
		Assert.equals(
			'class Roster {\n\tfunction sweep() {\n\t\t// alpha();\n\t\t//     beta();\n\t\t// gamma();\n\t\trender();\n\t}\n}\n', out
		);
	}

	/**
	 * The `}` closer heads a non-alnum body, so it never feeds the run's
	 * common-indent fold — but it shares that prefix, so it rides the same
	 * shift and stays aligned with the `for` it closes. Leaving it at the
	 * original indent would make every commented-out block ragged.
	 */
	public function testClosingBraceLineRidesTheRunShift(): Void {
		final source: String = 'class Roster {\n\tfunction sweep() {\n\t\t//    for (i in items) {\n\t\t//        step(i);\n\t\t//    }\n'
			+ '\t\trender();\n\t}\n}';
		Assert.equals(
			'class Roster {\n\tfunction sweep() {\n\t\t// for (i in items) {\n\t\t//     step(i);\n\t\t// }\n\t\trender();\n\t}\n}\n',
			formatted(source, KNOB_ON)
		);
	}

	/**
	 * A run of one: its own indent IS the common indent, so an isolated
	 * over-indented comment collapses all the way down to a single space.
	 */
	public function testLoneOverIndentedCommentCollapses(): Void {
		final source: String = 'class Roster {\n\tfunction sweep() {\n\t\t//            lonely();\n\t\trender();\n\t}\n}';
		Assert.equals('class Roster {\n\tfunction sweep() {\n\t\t// lonely();\n\t\trender();\n\t}\n}\n', formatted(source, KNOB_ON));
	}

	/**
	 * Tabs after `//` count as whitespace and fold into the common prefix
	 * exactly like spaces: a two-tab / three-tab run keeps the one-tab step.
	 */
	public function testTabIndentedRunNormalizes(): Void {
		final source: String = 'class Roster {\n\tfunction sweep() {\n\t\t//\t\talpha();\n\t\t//\t\t\tbeta();\n\t\trender();\n\t}\n}';
		Assert.equals(
			'class Roster {\n\tfunction sweep() {\n\t\t// alpha();\n\t\t// \tbeta();\n\t\trender();\n\t}\n}\n', formatted(source, KNOB_ON)
		);
	}

	/**
	 * A body with no leading whitespace still gets its single space — and it
	 * gets it even with `addLineCommentSpace` off, because a normalisable
	 * body always emits `'// ' + rest` while the indent knob is on.
	 */
	public function testTightBodyGetsOneSpace(): Void {
		final source: String = 'class Roster {\n\tfunction sweep() {\n\t\t//text\n\t\trender();\n\t}\n}';
		final expected: String = 'class Roster {\n\tfunction sweep() {\n\t\t// text\n\t\trender();\n\t}\n}\n';
		Assert.equals(expected, formatted(source, KNOB_ON));
		Assert.equals(expected, formatted(source, KNOB_ON_NO_SPACE));
	}

	/**
	 * Dividers, markers, `///` bodies and the empty `//` are all skipped by
	 * the indent pass — their output is byte-identical to the knob-off run,
	 * which is what "untouched" has to mean here (the legacy
	 * `addLineCommentSpace` pass still owns them).
	 */
	public function testSkippedBodiesUntouchedByIndentPass(): Void {
		final source: String = 'class Roster {\n\t//====\n\t//----\n\t//***\n\t//!marker\n\t///doc\n\t//\n\tvar x:Int;\n}';
		Assert.equals(
			'class Roster {\n\t// ====\n\t//----\n\t//***\n\t// !marker\n\t///doc\n\t//\n\tvar x:Int;\n}\n', formatted(source, KNOB_ON)
		);
		Assert.equals(formatted(source, KNOB_ABSENT), formatted(source, KNOB_ON));
	}

	/**
	 * A divider sitting between two code comments neither breaks the run nor
	 * contributes to its common indent: both code lines still collapse
	 * against their shared 4-space prefix, and the divider stays as it was.
	 */
	public function testDividerInsideRunNeitherBreaksNorContributes(): Void {
		final source: String = 'class Roster {\n\t//    alpha();\n\t//----\n\t//    beta();\n\tvar x:Int;\n}';
		Assert.equals('class Roster {\n\t// alpha();\n\t//----\n\t// beta();\n\tvar x:Int;\n}\n', formatted(source, KNOB_ON));
	}

	/**
	 * The trailing same-line comment slot goes through the same chokepoint,
	 * so an over-indented `// note` collapses there too.
	 */
	public function testTrailingCommentSlotNormalizes(): Void {
		final source: String = 'class Roster {\n\tfunction sweep() {\n\t\tvar x:Int = 1; //   note\n\t}\n}';
		Assert.equals('class Roster {\n\tfunction sweep() {\n\t\tvar x:Int = 1; // note\n\t}\n}\n', formatted(source, KNOB_ON));
	}

	/**
	 * Rewriting a comment's leading whitespace must not break inline
	 * suppression: `noqa` and `CHECKSTYLE:OFF`/`ON` are matched on the
	 * trimmed comment body, so both survive the pass. Exercised through
	 * `Suppression.apply` on the FORMATTED output — the finding on the
	 * `noqa` line and the one inside the region are filtered, the one after
	 * `CHECKSTYLE:ON` is kept.
	 */
	public function testSuppressionDirectivesStillParse(): Void {
		final source: String = 'class Roster {\n\tfunction sweep() {\n\t\tvar gamma:Int = 1; //    noqa: some-rule\n'
			+ '\t\t//CHECKSTYLE:OFF\n\t\tvar delta:Int = 2;\n\t\t//CHECKSTYLE:ON\n\t\tvar epsilon:Int = 3;\n\t}\n}';
		final out: String = formatted(source, KNOB_ON);
		Assert.stringContains('// noqa: some-rule', out);
		Assert.stringContains('// CHECKSTYLE:OFF', out);
		Assert.stringContains('// CHECKSTYLE:ON', out);
		final kept: Array<Violation> = Suppression.apply([
			violationAt(out, 'var gamma'),
			violationAt(out, 'var delta'),
			violationAt(out, 'var epsilon')
		], [{ file: FILE, source: out }], new HaxeQueryPlugin().lexicalRegions);
		Assert.equals(1, kept.length);
		Assert.equals('var epsilon', kept[0].message);
	}

	/**
	 * Formatting twice is a fixed point: after one pass a normalised body
	 * reads `' ' + rest`, so the next pass's common prefix is that same
	 * single space and stripping it reproduces the identical string. Covered
	 * for both the uniform run and the relative-indent run.
	 */
	public function testFormattingIsIdempotent(): Void {
		for (source in [UNIFORM_RUN, RELATIVE_RUN, FLUSH_MIX, TAB_MIX]) {
			final pass1: String = formatted(source, KNOB_ON);
			Assert.equals(pass1, formatted(pass1, KNOB_ON));
		}
	}

	/**
	 * A run with NO common indent — one member flush against `//`, or
	 * members disagreeing on tab-vs-space — has nothing to strip, so the
	 * pass must not ADD width: every already-indented body is re-emitted
	 * as authored and only the flush one picks up its separating space.
	 */
	public function testNoCommonIndentNeverAddsWidth(): Void {
		Assert.equals('class Roster {\n\t// alpha detail line\n\t// beta();\n\tvar x:Int;\n}\n', formatted(FLUSH_MIX, KNOB_ON));
		Assert.equals('$TAB_MIX\n', formatted(TAB_MIX, KNOB_ON));
		Assert.equals(formatted(TAB_MIX, KNOB_ABSENT), formatted(TAB_MIX, KNOB_ON));
	}

	/**
	 * A block-comment entry BREAKS the run: the two groups fold their own
	 * common indent instead of one shared prefix. Without the break the
	 * 8-space line would keep 4 of them (the 4-space group's prefix would
	 * win the fold), so this pins the boundary walk in `runCommonIndent`.
	 */
	public function testBlockCommentEntryBreaksTheRun(): Void {
		final source: String = 'class Roster {\n\t//        alpha();\n\t/* block */\n\t//    beta();\n\t//    gamma();\n\tvar x:Int;\n}';
		Assert.equals(
			'class Roster {\n\t// alpha();\n\t/* block */\n\t// beta();\n\t// gamma();\n\tvar x:Int;\n}\n', formatted(source, KNOB_ON)
		);
	}

	/**
	 * The keyword-gap slot (`} else //...`) historically bypassed the comment
	 * adapter altogether, so it is routed only while the knob is on. Knob off
	 * must therefore stay byte-identical; knob on hands the body to the same
	 * chokepoint as every other slot, `addLineCommentSpace` included.
	 */
	public function testKeywordGapCommentSlotIsKnobGated(): Void {
		final source: String =
			'class Roster {\n\tfunction sweep() {\n\t\tif (cond) {\n\t\t\ta();\n\t\t} else //====\n\t\t{\n\t\t\tb();\n\t\t}\n\t}\n}';
		Assert.equals('$source\n', formatted(source, KNOB_ABSENT));
		Assert.stringContains('} else // ====\n', formatted(source, KNOB_ON));
	}

	private static function formatted(source: String, configJson: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(configJson);
		return HaxeModuleTriviaWriter.write(ast, opts);
	}

	private static function violationAt(source: String, marker: String): Violation {
		final from: Int = source.indexOf(marker);
		return {
			file: FILE,
			span: new Span(from, from + marker.length),
			rule: 'some-rule',
			severity: Severity.Warning,
			message: marker
		};
	}

}
