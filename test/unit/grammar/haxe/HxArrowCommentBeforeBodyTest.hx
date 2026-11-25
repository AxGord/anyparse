package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * Trivia-mode round trip of a comment between an arrow lambda's `->` and its body, for the paren form
 * `(a, b) -> body` and the bare form `x -> body`: the writer keeps it where the source wrote it. A block comment
 * stays inline; a line comment ends its line and the whole body goes below it one indent deeper, breaking ONCE even
 * where the body itself breaks after `->` (the arrow-body wrap, a call's sole-argument glue shape).
 */
class HxArrowCommentBeforeBodyTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;
	private static final LONG_LADDER: String =
		'if (alpha.someLongFieldName < beta.someLongFieldName) -1 else if (alpha.someLongFieldName > beta.someLongFieldName) 1 else 0';

	@:pin('control')
	@:killer('M-PAREN-ARROW-AFTER-LEAD-UNCAPTURED')
	public function testBlockCommentBeforeIfLadderBodyKept(): Void {
		final source: String = wrap('\t\tmodules.sort((a, b) -> /* c */ if (a < b) -1 else if (a > b) 1 else 0);');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-PAREN-ARROW-AFTER-LEAD-UNCAPTURED')
	public function testLineCommentBeforeIfLadderBodyKept(): Void {
		// The body sits below `->` as when it breaks by width, so the call's close paren takes its own line.
		final source: String = wrap('\t\tmodules.sort((a, b) -> // why\n\t\t\tif (a < b) -1 else if (a > b) 1 else 0\n\t\t);');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-AFTER-LEAD-BREAK-HARD')
	public function testLongBodyUnderLineCommentBreaksOnce(): Void {
		final source: String = wrap(
			'\t\tmodules.sort((alpha, beta) -> // why\n\t\t\t$LONG_LADDER\n\t\t\t\t+ alpha.someLongFieldName.length\n\t\t);'
		);
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-THIN-ARROW-AFTER-OP-UNCAPTURED')
	public function testBareArrowBlockCommentKept(): Void {
		final source: String = wrap('\t\tvar f = x -> /* c */ x;\n\t\tfoo(x -> /* c */ x);');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-THIN-ARROW-AFTER-OP-UNCAPTURED')
	public function testBareArrowLineCommentKept(): Void {
		final source: String = wrap('\t\tvar g = x -> // why\n\t\t\tif (x) 1 else 0;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-AFTER-LEAD-BREAK-HARD')
	public function testBareArrowLongBodyUnderLineCommentBreaksOnce(): Void {
		final source: String = wrap('\t\tvar rank = alpha -> // why\n\t\t\t$LONG_LADDER\n\t\t\t\t+ alpha.someLongFieldName.length;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-BARE-ARROW-SPLIT-RUN-IN-BODY')
	public function testSoleArgBareArrowKeepsLineComment(): Void {
		// A broken if/else body takes the sole-argument glue shape: the break after `->` and `)` on its own line.
		final source: String = wrap(
			'\t\tmodules.sort(alpha -> // why\n\t\t\tif (alpha.a) {\n\t\t\t\t-1;\n\t\t\t} else {\n\t\t\t\t1;\n\t\t\t}\n\t\t);'
		);
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-ARROW-MARKER-AFTER-RUN-UNFORCED')
	public function testBareArrowLineCommentNestsBlockIfBody(): Void {
		final source: String = wrap('\t\tvar g = x -> // why\n\t\t\tif (x) {\n\t\t\t\t1;\n\t\t\t} else {\n\t\t\t\t0;\n\t\t\t};');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-ARROW-MARKER-AFTER-RUN-UNFORCED')
	public function testParenArrowLineCommentNestsBlockIfBody(): Void {
		final source: String = wrap('\t\tvar p = (a, b) -> // why\n\t\t\tif (a) {\n\t\t\t\t1;\n\t\t\t} else {\n\t\t\t\t0;\n\t\t\t};');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-ARROW-MARKER-AFTER-RUN-UNFORCED')
	public function testParenArrowLineCommentNestsSwitchBody(): Void {
		final source: String = wrap('\t\tvar s = (a, b) -> // why\n\t\t\tswitch a {\n\t\t\t\tcase 1: b;\n\t\t\t\tcase _: a;\n\t\t\t};');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-ARROW-MARKER-AFTER-RUN-UNFORCED')
	public function testNonSoleArgLineCommentNestsBody(): Void {
		final source: String = wrap(
			'\t\tbar(1,\n\t\t\tx -> // why\n\t\t\t\tif (x) {\n\t\t\t\t\t1;\n\t\t\t\t} else {\n\t\t\t\t\t0;\n\t\t\t\t});'
		);
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-DECIDED-MARKER-BRACE-FLAT')
	public function testLineCommentNestsBraceBody(): Void {
		final source: String = wrap(
			'\t\tvar k = x -> // why\n\t\t\t{\n\t\t\t\tx;\n\t\t\t};\n\t\tvar q = (a, b) -> // why\n\t\t\t{\n\t\t\t\ta;\n\t\t\t};'
		);
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-DECIDED-MARKER-BLOCK-HUGGED')
	public function testSoleArgLineCommentNestsBraceBody(): Void {
		final source: String = wrap(
			'\t\tfoo(x -> // why\n\t\t\t{\n\t\t\t\tx;\n\t\t\t}\n\t\t);\n\t\tfoo((a, b) -> // why\n\t\t\t{\n\t\t\t\ta;\n\t\t\t}\n\t\t);'
		);
		Assert.equals('$source\n', roundTrip(source));
	}

	private function wrap(body: String): String {
		return 'class Foo {\n\tfunction bar() {\n$body\n\t}\n}';
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
