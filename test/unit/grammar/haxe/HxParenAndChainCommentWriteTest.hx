package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A comment on an expression paren's open line, and a line comment between a chain operand and its operator under
 * an `afterLast` chain, survive the writer round trip in one pass.
 */
class HxParenAndChainCommentWriteTest extends Test {

	public function testLineCommentAfterParenOpenKeepsItsLine(): Void {
		assertSettles(
			body('if (a && ( // c\n\t\t\tb || d)) {\n\t\t\tx();\n\t\t}'),
			body('if (a && ( // c\n\t\t\tb || d\n\t\t)) {\n\t\t\tx();\n\t\t}')
		);
	}

	public function testLineCommentAfterParenOpenInAValue(): Void {
		assertSettles(body('var w = ( // q\n\t\t\ta + b) * 2;'), body('var w = ( // q\n\t\t\ta + b\n\t\t) * 2;'));
	}

	public function testBlockCommentAfterParenOpenRidesTheDelimiter(): Void {
		assertSettles(body('var y = ( /* k */ a + b) * 2;'), body('var y = (/* k */ a + b) * 2;'));
	}

	public function testLineCommentBeforeAnAfterLastOperatorBreaksBeforeIt(): Void {
		final config: String = '{"wrapping": {"opBoolChain": {"defaultLocation": "afterLast", "rules": []}}}';
		final source: String = body('return a == 1 // c\n\t\t\t&& b == 2;');
		final once: String = HxWriteFixture.triviaWrite(source, config);
		Assert.equals(source.rtrim(), once);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, config));
	}

	/** One round trip gives `expected`, and a second gives it back unchanged. */
	private function assertSettles(source: String, expected: String): Void {
		final once: Null<String> = new HaxeQueryPlugin().writeRoundTrip(source);
		Assert.equals(expected, once);
		Assert.equals(once, new HaxeQueryPlugin().writeRoundTrip(once ?? ''));
	}

	private function body(stmt: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$stmt\n\t}\n}\n';
	}

}
