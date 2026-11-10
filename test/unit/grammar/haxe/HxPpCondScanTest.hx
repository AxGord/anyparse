package unit.grammar.haxe;

import anyparse.grammar.haxe.HxPpCondScan;
import anyparse.runtime.StringInput;
import utest.Assert;

/**
 * `HxPpCondScan`, the reader generated from the declared condition `HxPpCond`, read directly: the operand forms a
 * regex once read differently and the edges of a group. Every expected offset is spelled from the fixture text.
 */
@:nullSafety(Strict)
final class HxPpCondScanTest extends utest.Test {

	/** A number keeps its dots, so `4.2` is one operand. */
	@:pin('control')
	@:killer('M-COND-NUMBER-DOTTED')
	public function testANumberOperandKeepsItsDot(): Void {
		final source: String = '4.2 x';
		Assert.equals(source.indexOf(' '), end(source));
	}

	/** A quoted string is an operand of its own. */
	@:pin('control')
	@:killer('M-COND-QUOTED-OPERAND')
	public function testAQuotedStringIsAnOperand(): Void {
		final source: String = "'a b' x";
		Assert.equals(source.lastIndexOf(' '), end(source));
	}

	/** A dotted flag ends at a dot not followed by an identifier start, and an escaped quote stays inside its string. */
	@:pin('guard')
	public function testAFlagAndAStringEndWhereHaxeEndsThem(): Void {
		Assert.equals('target.sys'.length, end('target.sys x'));
		Assert.equals(1, end('a.1'));
		final escaped: String = '"a\\"b" x';
		Assert.equals(escaped.lastIndexOf(' '), end(escaped));
	}

	/** A block comment inside a group is comment text, and one that never closes leaves no condition. */
	@:pin('guard')
	public function testABlockCommentInsideAGroupOpensNothing(): Void {
		final closed: String = '(a /* ) */ b) x';
		Assert.equals(closed.lastIndexOf(' '), end(closed));
		Assert.equals(0, end('(a /* b ) x'));
	}

	private static function end(source: String): Int {
		return HxPpCondScan.endAt(new StringInput(source), 0);
	}

}
