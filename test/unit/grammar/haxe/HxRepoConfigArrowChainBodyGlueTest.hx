package unit.grammar.haxe;

import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * Under this repository's `hxformat.json` a call whose sole argument is an arrow lambda with a binary-chain body that
 * overflows the continuation line keeps `call(param ->` on the opening line, as a call body does, and breaks the
 * chain one indent deeper.
 */
@:nullSafety(Strict)
final class HxRepoConfigArrowChainBodyGlueTest extends Test {

	public function new(): Void {
		super();
	}

	/** An `||` chain of parenthesised operands glues the arrow head and breaks under it. */
	@:pin('control')
	@:killer('M-ARROW-CONT-GLUE-CHAIN-GATE')
	public function testOrChainBodyGluesArrowHead(): Void {
		final expected: String = inMethod([
			'return node.children.exists(c ->',
			'\t(aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbb && cccccccccccccccccccc.dddddddddddddd)',
			'\t|| (eeeeeeeeeeeeeeeeeeeeee.ffffffffffff && gggggggggggggggggg.hhhhhhhhhhhh)',
			');'
		]);
		Assert.equals(expected, repoWrite(expected));
	}

	/** An `&&` chain of simple operands glues the arrow head as well. */
	@:pin('control')
	@:killer('M-ARROW-CONT-GLUE-CHAIN-GATE')
	public function testAndChainBodyGluesArrowHead(): Void {
		final expected: String = inMethod([
			'return node.children.exists(c ->',
			'\taaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbb && cccccccccccccccccccc.dddddddddddddd && eeeeeeeeeeeeeeeeeeeeee.ffffffffffff',
			'\t&& gggggggggggggggggg',
			');'
		]);
		Assert.equals(expected, repoWrite(expected));
	}

	private function repoWrite(src: String): String {
		return #if (sys || nodejs) HxWriteFixture.triviaWrite(src, File.getContent('hxformat.json')) #else src #end;
	}

	private static function inMethod(lines: Array<String>): String {
		return 'class C {\n\n\tfunction test() {\n\t\t${lines.join('\n\t\t')}\n\t}\n\n}';
	}

}
