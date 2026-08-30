package unit;

import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-max-anywhere-in-file — final-pass cap on consecutive `lineEnd` runs.
 * Drives haxe-formatter's `emptyLines.maxAnywhereInFile: @:default(1)`
 * knob. Lives on the generic base `WriteOptions` as
 * `maxConsecutiveBlanks:Int` so every grammar can opt in; the Haxe
 * loader maps the JSON key onto the runtime field.
 *
 * Semantics: any run of `N+1` or more consecutive `lineEnd` sequences
 * in the rendered output collapses to exactly `N+1` line-ends — i.e.
 * at most `N` blank lines between any two non-empty lines. Default
 * `1` matches the fork; `0` strips every blank line; `-1` disables
 * the cap entirely.
 */
@:nullSafety(Strict)
class HxMaxAnywhereInFileSliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testDefaultMatchesUpstream(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(1, defaults.maxConsecutiveBlanks);
	}

	public function testZeroStripsAllBlanks(): Void {
		final src: String = 'package;\n\n\nclass Main {\n\tpublic function new() {}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"maxAnywhereInFile": 0}}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('package;\nclass Main {\n\tpublic function new() {}\n}\n', out);
	}

	/**
	 * RE-FIXTURED (T324). The old fixture was a `package;` header followed by three
	 * blank lines, and its expected output came from the `afterPackage` default, not
	 * from the cap: disabling `capConsecutiveBlanks` entirely did not flip it, so the
	 * name claimed a mechanism the assertion never exercised.
	 *
	 * A statement-to-statement run inside a function body has no `emptyLines` section
	 * rule of its own, so the cap is the only thing that decides it. Mutation-checked
	 * both ways: with the cap disabled the three source blanks come through whole, and
	 * at `maxAnywhereInFile: 3` they survive as three.
	 */
	public function testOneCapsToOneBlank(): Void {
		final src: String = 'class Main {\n\tfunction f() {\n\t\ta();\n\n\n\n\t\tb();\n\t}\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class Main {\n\tfunction f() {\n\t\ta();\n\n\t\tb();\n\t}\n}\n', out);
	}

	public function testTwoAllowsTwoBlanks(): Void {
		// `afterPackage:3` requests 3 blanks; cap:2 trims to 2.
		final src: String = 'package;\nclass Main {}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterPackage": 3, "maxAnywhereInFile": 2}}'
		);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('package;\n\n\nclass Main {}\n', out);
	}

	public function testNegativeOneDisablesCap(): Void {
		// `afterPackage:4` requests 4 blanks; cap:-1 (off) lets them through.
		final src: String = 'package;\nclass Main {}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"afterPackage": 4}}');
		opts.maxConsecutiveBlanks = -1;
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('package;\n\n\n\n\nclass Main {}\n', out);
	}

	public function testCapsAcrossClassClassPair(): Void {
		// Source carries 4 blanks between two single-line classes; the
		// default cap:1 trims the inter-class gap down to 1 blank.
		final src: String = 'class A {}\n\n\n\n\nclass B {}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class A {}\n\nclass B {}\n', out);
	}

	public function testConfigLoaderMapsZero(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"maxAnywhereInFile": 0}}');
		Assert.equals(0, opts.maxConsecutiveBlanks);
	}

	public function testConfigLoaderMissingKeyKeepsDefault(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(1, opts.maxConsecutiveBlanks);
	}

	public function testCapOverridesAfterPackage(): Void {
		// `afterPackage:2` would emit 2 blanks; default `maxConsecutiveBlanks:1`
		// caps that back to 1 blank — fork's mark-then-cap ordering.
		final src: String = 'package;\nclass Main {}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"afterPackage": 2}}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('package;\n\nclass Main {}\n', out);
	}


	/**
	 * PIN. A blank run inside a multi-line STRING LITERAL is program content, not
	 * layout — the cap must not reach it, at any cap value.
	 *
	 * RED at `a727f9d1`: the cap was a text scan over the flattened render buffer,
	 * where a literal's newline is indistinguishable from a line break the renderer
	 * chose, so base answers `"one\nfive"` — all three blank lines gone and the
	 * string's VALUE changed.
	 *
	 * ONE assertion over the whole file so neither half can pass alone: the blank
	 * line BETWEEN the two members is gone (proving the cap actually ran at 0) while
	 * the literal's four newlines are all still there.
	 */
	public function testAStringLiteralBlankRunIsNotACapCandidate(): Void {
		final src: String = 'class Main {\n\tstatic var s = "one\n\n\n\nfive";\n\n\tstatic function f() {}\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"maxAnywhereInFile": 0}}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class Main {\n\tstatic var s = "one\n\n\n\nfive";\n\tstatic function f() {}\n}\n', out);
	}

	/**
	 * PIN. The same file under the DEFAULT cap of 1, with an over-long blank run on
	 * BOTH sides of the boundary: the code run collapses to one blank and the
	 * literal's own run survives whole, in one assertion.
	 *
	 * RED at `a727f9d1` (base answers `"one\n\nfive"`). The code half is what keeps
	 * the pin from passing on a build where the cap never runs at all.
	 */
	public function testTheCapTrimsCodeBlanksBesideALiteralThatKeepsItsOwn(): Void {
		final src: String = 'class Main {\n\tstatic var s = "one\n\n\n\nfive";\n\n\n\n\tstatic function f() {}\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class Main {\n\tstatic var s = "one\n\n\n\nfive";\n\n\tstatic function f() {}\n}\n', out);
	}


	/**
	 * PIN (T323). A blank run inside a GUTTER-LESS multi-line block comment is a
	 * line the AUTHOR wrote, and the cap must not reach it either — the other half
	 * of the same defect the string-literal pins above cover.
	 *
	 * The nested shape, which `BlockCommentNormalizer` assembles by hand
	 * (`firstInlineRebuildDoc`): the interior lines are re-indented, so the writer
	 * gets one `Text` PER LINE joined by breaks and the blank line is an EMPTY
	 * `Text` that emits nothing. Base therefore sees three bare layout line-ends
	 * and eats one.
	 *
	 * RED at `4ae8f42f`: base answers a comment body of `one` + ONE blank + `four`.
	 *
	 * ONE assertion so neither half passes alone — the comment keeps BOTH of its
	 * blank lines while the three-blank run between the two statements UNDER it, in
	 * the same block, is trimmed to one. That second half is the control that the
	 * fix does not protect a run merely for sitting near a comment, and it is
	 * cap-decided: at `maxAnywhereInFile: 9` the same source keeps three blanks
	 * there, and disabling the cap kills this test.
	 *
	 * (The first fixture written for this pin put the run between two class MEMBERS
	 * instead. It looked like the same control and was not — that gap is normalised
	 * by an `emptyLines` section rule, so the half survived the cap being disabled
	 * entirely. Same vacuity as the T324 fixture two methods up.)
	 */
	public function testAGutterlessBlockCommentBlankRunIsNotACapCandidate(): Void {
		final src: String = 'class Main {\n\tfunction f() {\n\t\t/* one\n\n\n\t\tfour */\n\t\ta();\n\n\n\n\t\tb();\n\t}\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class Main {\n\tfunction f() {\n\t\t/* one\n\n\n\t\t\tfour */\n\t\ta();\n\n\t\tb();\n\t}\n}\n', out);
	}


	/**
	 * PIN (T323), the OTHER assembly path. A gutter-less comment whose close sits
	 * at the wrap column routes through the MACRO writer
	 * (`BlockCommentWriter.writeDoc`, `@:sep('\n')` join) rather than through one
	 * of `BlockCommentNormalizer`'s hand-built Docs — a path no hand edit reaches,
	 * which is why the mark is applied by `D.verbatim` over the whole comment Doc
	 * instead of at each emitter.
	 *
	 * Cap 0 rather than the default, so the code side is unambiguous: every blank
	 * line outside the comment is gone while the comment keeps both of its own.
	 *
	 * The close line loses its own leading space on the way through (`normalize`
	 * has no interior frame to place it relative to, so `closeLineWs` sends it to
	 * the wrap column) — that is the writer's pre-existing shape here, unchanged by
	 * this slice, and the assertion carries it rather than papering over it.
	 *
	 * RED at `4ae8f42f`: base answers `one` + no blank at all + `four`.
	 */
	public function testTheMacroJoinedCommentPathKeepsItsBlankRun(): Void {
		final src: String = '/* one\n\n\n four */\n\n\nclass X {}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"maxAnywhereInFile": 0}}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('/* one\n\n\nfour */\nclass X {}\n', out);
	}


	/**
	 * PIN (T325). `indentation.trailingWhitespace: true` makes every blank row
	 * carry the block's indent, so the rendered run reads line-end, indent,
	 * line-end, indent, … — and the cap's scan, which looked for line-ends with
	 * nothing between them, matched no run at all.
	 *
	 * RED at `4ae8f42f`: base leaves all three blank rows standing under a cap of
	 * ZERO — two config keys silently mutually exclusive, with nothing said on
	 * either side.
	 */
	public function testTheCapSeesBlankRowsCarryingTrailingWhitespaceIndent(): Void {
		final src: String = 'class Main {\n\tfunction f() {\n\t\ta();\n\n\n\n\t\tb();\n\t}\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"maxAnywhereInFile": 0}, "indentation": {"trailingWhitespace": true}}'
		);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class Main {\n\tfunction f() {\n\t\ta();\n\t\tb();\n\t}\n}\n', out);
	}


	/**
	 * PIN (T325), the other direction: a cap that SEES an indented blank row must
	 * also keep the indent on the rows it keeps, not collapse them to bare
	 * line-ends. Under `trailingWhitespace: true` a bare one would be a row the
	 * knob says should carry the block's indent.
	 *
	 * Sister of the cap-0 pin above, and the pair is what makes the count matter:
	 * three source rows, one kept WITH its two tabs, two dropped WITH theirs.
	 *
	 * RED at `4ae8f42f`: base leaves all three rows standing.
	 */
	public function testTheCapKeepsTheIndentOnTheBlankRowItKeeps(): Void {
		final src: String = 'class Main {\n\tfunction f() {\n\t\ta();\n\n\n\n\t\tb();\n\t}\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"maxAnywhereInFile": 1}, "indentation": {"trailingWhitespace": true}}'
		);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class Main {\n\tfunction f() {\n\t\ta();\n\t\t\n\t\tb();\n\t}\n}\n', out);
	}


	/**
	 * PIN (T323), and the correction of a claim this campaign carried for a
	 * slice: a DOC comment is NOT exempt. Its blank lines are safe only where the
	 * author put the ` * ` gutter on them — a genuinely empty interior line goes
	 * through `javadocBytePreserveDoc`, which emits the same empty `Text` between
	 * two breaks as the gutter-less block does.
	 *
	 * RED at `4ae8f42f`: base answers `* one` immediately followed by `* four`,
	 * both blank lines gone out of a haxedoc block.
	 *
	 * The code half is cap-decided (`maxAnywhereInFile: 9` keeps three blanks
	 * between the two statements); the comment half is decided by the flag and is
	 * cap-independent by design, which is the whole point.
	 */
	public function testADocCommentsGenuinelyEmptyInteriorLinesAreContentToo(): Void {
		final src: String = 'class Main {\n\t/**\n\t * one\n\n\n\t * four\n\t */\n\tfunction f() {\n\t\ta();\n\n\n\n\t\tb();\n\t}\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"maxAnywhereInFile": 0}}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class Main {\n\t/**\n\t * one\n\n\n\t * four\n\t */\n\tfunction f() {\n\t\ta();\n\t\tb();\n\t}\n}\n', out);
	}


	/**
	 * PIN, where T323 and T325 meet: under `trailingWhitespace: true` a marked
	 * break writes the block's indent BEFORE its line end, so the offset
	 * `emitLine` records has to be the one the LINE END lands on, not the one the
	 * indent starts at. Recording it one indent too early leaves the cap unable to
	 * match any of the comment's own line ends, and the comment loses its blank
	 * lines exactly as it did before the flag existed.
	 *
	 * Nothing else in the suite renders a captured comment under
	 * `trailingWhitespace`: moving that push above `writeIndent` killed
	 * NOTHING in the whole suite until this pin existed.
	 *
	 * One assertion over the whole file: the comment keeps both blank rows WITH
	 * their two tabs, and the three-blank run between the two statements is gone
	 * at a cap of 0.
	 *
	 * READ THE RED CAREFULLY. This pin is RED at `4ae8f42f` on its CODE half
	 * only: base leaves all three statement rows standing, because under
	 * `trailingWhitespace` the cap matched no run at all (T325). Base happens to
	 * keep the COMMENT rows for the same reason, so this fixture is not a second
	 * base-RED witness for T323 — the gutter-less and doc-comment pins above are.
	 */
	public function testAMarkedBreakRecordsTheOffsetItsLineEndLandsOn(): Void {
		final src: String = 'class Main {\n\tfunction f() {\n\t\t/* one\n\n\n\t\tfour */\n\t\ta();\n\n\n\n\t\tb();\n\t}\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"maxAnywhereInFile": 0}, "indentation": {"trailingWhitespace": true}}'
		);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class Main {\n\tfunction f() {\n\t\t/* one\n\t\t\n\t\t\n\t\t\tfour */\n\t\ta();\n\t\tb();\n\t}\n}\n', out);
	}

}
