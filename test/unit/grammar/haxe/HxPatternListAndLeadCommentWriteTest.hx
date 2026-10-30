package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * Comments inside a `case` pattern list and right after a typedef's `=` / `&` survive the writer round trip.
 *
 * Both gaps had no capture slot: the pattern list was a plain separated Star, and the gap after a mandatory
 * `@:lead` literal was skipped as whitespace, so the comment was dropped and `writeRoundTrip` refused the
 * whole file. The pattern list now collects per-element trivia and keeps its wrap cascade
 * (`@:fmt(inlineElemTrivia)`); the lead gap fills the `<field>AfterLead` slot (`@:fmt(captureAfterLead)`).
 */
class HxPatternListAndLeadCommentWriteTest extends Test {

	public function testCommentAfterPatternSeparator(): Void {
		assertFixedPoint(inSwitch('case A, /*B,*/ C:'));
	}

	public function testCommentBeforePatternClose(): Void {
		assertFixedPoint(inSwitch('case A, B /*, C*/:'));
	}

	public function testCommentsOnEverySideOfAPattern(): Void {
		assertFixedPoint(inSwitch('case A /*x*/, /*B,*/ C /*y*/:'));
	}

	public function testCommentBeforeFirstPatternAndAfterColon(): Void {
		assertFixedPoint(inSwitch('case /* c */ X: // t\n\t\t\t\trun();'));
	}

	public function testLineCommentAfterSeparatorStaysBeforeTheNextPattern(): Void {
		// A line comment cannot share a line with the next pattern, so the list breaks; the comment keeps its place
		// after the separator, and the written form is a fixed point.
		final once: Null<String> = roundTrip(inSwitch('case A, // x\n\t\t\t\tC:'));
		Assert.equals(inSwitch('case A,\n\t\t\t\t// x\n\t\t\t\tC:'), once);
		Assert.equals(once, roundTrip(once ?? ''));
	}

	public function testCommentAfterTypedefAssign(): Void {
		assertFixedPoint('typedef T = /* c */ Int;\n');
	}

	public function testCommentAfterIntersectionAmpersand(): Void {
		assertFixedPoint('typedef T = A & /* c */ B;\n');
	}

	public function testLineCommentAfterTypedefAssign(): Void {
		assertFixedPoint('typedef T = // c\n\tA;\n');
	}

	public function testOwnLineCommentBeforePatternCloseRidesTheLastPattern(): Void {
		// An orphan the loop scans before `:` (the `TrailingLeading` slot) is written after the last pattern.
		assertSettles(inSwitch('case A, B\n\t\t\t// c\n\t\t\t:'), inSwitch('case A,\n\t\t\t\tB // c\n\t\t\t\t:'), '// c');
	}

	public function testInlineCommentBeforeFirstOfSeveralPatterns(): Void {
		// Today's layout, pinned on purpose: the first pattern's leading comment hangs the list below `case`.
		assertSettles(inSwitch('case /* a */ A, B:'), inSwitch('case\n\t\t\t\t/* a */ A, B\n\t\t\t:'), '/* a */');
	}

	public function testOwnLineCommentBeforeFirstOfSeveralPatterns(): Void {
		assertSettles(inSwitch('case\n\t\t\t// c\n\t\t\tA, B:'), inSwitch('case\n\t\t\t\t// c\n\t\t\t\tA,\n\t\t\t\tB\n\t\t\t:'), '// c');
	}

	public function testLineCommentAfterIntersectionAmpersand(): Void {
		assertSettles('typedef T = A & // c\n\tB;\n', 'typedef T = A & // c\n\tB;\n', '// c');
	}

	public function testMultiLineBlockCommentAfterTypedefAssign(): Void {
		// A block that spans lines cannot keep the type on its closing line, so the type breaks one indent deeper.
		assertSettles('typedef T = /* a\n\tb */ Int;\n', 'typedef T = /* a\n\tb */\n\tInt;\n', 'b */');
	}

	/** One round trip gives `expected`, a second gives it back unchanged, and the comment text is still there. */
	private function assertSettles(source: String, expected: String, comment: String): Void {
		final once: Null<String> = roundTrip(source);
		Assert.equals(expected, once);
		Assert.equals(once, roundTrip(once ?? ''));
		Assert.stringContains(comment, once ?? '');
	}

	/** The source is already what the writer produces for it — the byte contract a canonical file has. */
	private function assertFixedPoint(source: String): Void {
		Assert.equals(source, roundTrip(source));
	}

	private function inSwitch(caseBranch: String): String {
		return 'class Foo {\n\tfunction bar() {\n\t\tswitch v {\n\t\t\t$caseBranch\n\t\t}\n\t}\n}\n';
	}

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

}
