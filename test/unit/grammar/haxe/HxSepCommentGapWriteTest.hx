package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * A comment between a list element and a separator the source put on a later line, a glued block comment ahead of
 * a list's first element, and a block comment before an optional keyword all survive the writer round trip in one
 * pass, each keeping its kind.
 */
class HxSepCommentGapWriteTest extends Test {

	public function testLineCommentBeforeSeparatorOnTheNextLine(): Void {
		assertSettles(inSwitch('case A // c\n\t\t\t, B:'), inSwitch('case A // c\n\t\t\t\t, B:'));
	}

	public function testEachLineCommentStaysOnItsOwnPatternsLine(): Void {
		assertSettles(
			inSwitch('case A // c1\n\t\t\t, B // c2\n\t\t\t, C:'), inSwitch('case A // c1\n\t\t\t\t,\n\t\t\t\tB // c2\n\t\t\t\t, C:')
		);
	}

	public function testBlockCommentBeforeSeparatorOnTheNextLine(): Void {
		assertSettles(inSwitch('case A /* c */\n\t\t\t, B:'), inSwitch('case A, /* c */ B:'));
	}

	public function testOwnLineBlockCommentGluedToTheSeparator(): Void {
		assertSettles(inSwitch('case A\n\t\t\t/* c */, B:'), inSwitch('case A, /* c */ B:'));
	}

	public function testArrayLineCommentBeforeSeparator(): Void {
		assertSettles('class Foo {\n\tvar a = [1 // c\n\t, 2];\n}\n', 'class Foo {\n\tvar a = [\n\t\t1, // c\n\t\t2\n\t];\n}\n');
	}

	public function testArrayOwnLineCommentBeforeSeparator(): Void {
		assertSettles('class Foo {\n\tvar a = [1\n\t/* c */, 2];\n}\n', 'class Foo {\n\tvar a = [\n\t\t1,\n\t\t/* c */ 2\n\t];\n}\n');
	}

	public function testArrayCommentBeforeTrailingSeparatorJoinsTheOrphans(): Void {
		assertSettles('class Foo {\n\tvar a = [1\n\t// c\n\t,];\n}\n', 'class Foo {\n\tvar a = [\n\t\t1,\n\t\t// c\n\t];\n}\n');
	}

	public function testParameterLineCommentBeforeSeparator(): Void {
		assertSettles(
			'class Foo {\n\tfunction f(a:Int // c\n\t, b:Int) {}\n}\n',
			'class Foo {\n\tfunction f(\n\t\ta:Int, // c\n\t\tb:Int\n\t) {}\n}\n'
		);
	}

	public function testGluedBlockCommentOnFirstOfSeveralPatternsStaysOnTheCaseLine(): Void {
		assertFixedPoint(inSwitch('case /* a */ A, B:'));
	}

	public function testGluedBlockCommentOnFirstArgumentStaysOnTheOpenLine(): Void {
		final args: String = 'aaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccccccccccc, ddddddddddddddd';
		final tail: String = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeee, fffffffffffffffffffff';
		assertSettles(
			'class Foo {\n\tvar a = ffffffffffffffffffffffffff(/* a */ $args, $tail);\n}\n',
			'class Foo {\n\tvar a = ffffffffffffffffffffffffff(/* a */ $args,\n\t\t$tail);\n}\n'
		);
	}

	public function testBlockCommentBeforeGuardKeepsItsKind(): Void {
		assertFixedPoint(inSwitch('case A /* x */ if (y):'));
	}

	public function testBlockCommentBeforeElseKeepsItsKind(): Void {
		assertFixedPoint('class Foo {\n\tfunction bar() {\n\t\tif (a) {\n\t\t\tb();\n\t\t} /* c */ else {\n\t\t\td();\n\t\t}\n\t}\n}\n');
	}

	/** One round trip gives `expected`, and a second gives it back unchanged. */
	private function assertSettles(source: String, expected: String): Void {
		final once: Null<String> = roundTrip(source);
		Assert.equals(expected, once);
		Assert.equals(once, roundTrip(once ?? ''));
	}

	/** The source is already what the writer produces for it. */
	private function assertFixedPoint(source: String): Void {
		Assert.equals(source, roundTrip(source));
	}

	private function inSwitch(caseBranch: String): String {
		return 'class Foo {\n\tfunction bar() {\n\t\tswitch v {\n\t\t\t$caseBranch\n\t\t}\n\t}\n}\n';
	}

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

}
