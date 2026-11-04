package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * A comment that forces a line break keeps its place in one writer pass: a block comment spanning lines stays after
 * the token it followed, and a chain breaks ahead of an operand whose first line ends on a note.
 */
class HxCommentBreakWriteTest extends Test {

	public function testMultilineBlockCommentStaysAfterItsOperand(): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\ts = "a" /*+ b +\n\t\t\tc */\n\t\t\t+ "d";\n\t}\n}\n';
		Assert.equals(source, roundTrip(source));
	}

	public function testMultilineBlockCommentBeforeANextLineTerminatorSettlesInOnePass(): Void {
		for (stmt in ['foo(1, 2)', 'var t3 = foo(1, 2)']) {
			final once: String = roundTrip('class A {\n\tfunction f() {\n\t\t$stmt /* m\n\t\t\tn */\n\t\t;\n\t}\n}\n') ?? '';
			Assert.stringContains('/* m\n\t\t\tn */', once);
			Assert.equals(once, roundTrip(once));
		}
	}

	public function testMultilineBlockCommentAfterAnOpenParenIsKept(): Void {
		final once: Null<String> = roundTrip('class Foo {\n\tfunction bar() {\n\t\tvar x = (/* a\nb */ x);\n\t}\n}\n');
		Assert.notNull(once);
		Assert.stringContains('/* a\nb */', once ?? '');
		Assert.equals(once, roundTrip(once ?? ''));
	}

	public function testMultilineBlockCommentBeforeTernaryQuestionStaysAfterTheCondition(): Void {
		final canonical: String = 'class A {\n\tfunction f() {\n\t\treturn a /* m\n\t\t\tn */\n\t\t\t? b\n\t\t\t: c;\n\t}\n}\n';
		Assert.equals(canonical, roundTrip(canonical));
		Assert.equals(canonical, roundTrip('class A {\n\tfunction f() {\n\t\treturn a /* m\n\t\t\tn */\n\t\t\t? b : c;\n\t}\n}\n'));
	}

	public function testMultilineBlockCommentBeforeTernaryColonStaysAfterTheThenBranch(): Void {
		final canonical: String = 'class A {\n\tfunction f() {\n\t\treturn a\n\t\t\t? b /* m\n\t\t\tn */\n\t\t\t: c;\n\t}\n}\n';
		Assert.equals(canonical, roundTrip(canonical));
		Assert.equals(canonical, roundTrip('class A {\n\tfunction f() {\n\t\treturn a ? b /* m\n\t\t\tn */\n\t\t\t: c;\n\t}\n}\n'));
	}

	public function testChainBreaksAheadOfAnOperandOpeningOnANote(): Void {
		final cond: String = 'aaaaaaaaaaa && bbbbbbbbbbbbbbbbbbb > ccccccccccccc && ( // note\n\t\t\tddddddddddddddddd != '
			+ 'eeeeeeeeeeeeeeeeeeeeeeeee || fffffffffffffffffffffffffffffffffff.gggggggggggggggggggggggg(hhhhhhhhhh, '
			+ 'true) == iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii)';
		final once: Null<String> = roundTrip('class Foo {\n\tfunction bar() {\n\t\tif ($cond) {\n\t\t\tx();\n\t\t}\n\t}\n}\n');
		Assert.stringContains('\n\t\t\t&& ( // note\n', once ?? '');
		Assert.equals(once, roundTrip(once ?? ''));
	}

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

}
