package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * Comments inside a class / interface HERITAGE list survive the writer round trip.
 *
 * The heritage Star has its own emit (`TriviaTryparseLowering.triviaTryparseHeritageExpr`,
 * opted in by `@:fmt(heritageWrap)`) which bypasses the shared incremental loop. It read the
 * per-clause `leadingComments` / `trailingComment` slots only to set a `_hasComments` flag and
 * then built its Doc from the clause nodes alone, so every comment in the list was dropped and
 * `writeRoundTrip` refused the whole file — `apq fmt` and every canonicalising op with it.
 *
 * A BLOCK comment stays on the declaration line; a LINE comment owns its line, because a `//`
 * runs to the newline and cannot be re-emitted inline.
 */
class HxHeritageCommentWriteTest extends Test {

	public inline function testBlockCommentBeforeFirstClause(): Void {
		assertFixedPoint('class A /* n */ implements B {}\n');
	}

	public inline function testBlockCommentBetweenClauses(): Void {
		assertFixedPoint('class A implements B /* n */ implements C {}\n');
	}

	public inline function testBlockCommentAfterExtendsBeforeImplements(): Void {
		assertFixedPoint('class A extends P /* n */ implements B {}\n');
	}

	public inline function testBlockCommentBeforeExtends(): Void {
		assertFixedPoint('class A /* n */ extends P {}\n');
	}

	public inline function testTrailingBlockCommentOnLastClause(): Void {
		assertFixedPoint('class A implements B /* n */ {}\n');
	}

	public function testInterfaceExtendsRunWithLineComment(): Void {
		// The report's shape: a commented-out `extends` between two live ones. The clauses pack
		// onto the declaration line until the `//` forces its own; re-running the writer on that
		// output changes nothing, which is what makes the file canonical.
		final written: Null<String> =
			roundTrip('interface FullMagic\n\textends HasAbstract\n\t// extends Declarator\n\textends SuperPuper\n{}\n');
		Assert.equals('interface FullMagic extends HasAbstract\n\t// extends Declarator\n\textends SuperPuper {}\n', written);
		assertFixedPoint(written);
	}

	/** `source` is already what the writer produces for it — the byte-identical contract every canonical file has. */
	private function assertFixedPoint(source: Null<String>): Void {
		Assert.notNull(source);
		if (source != null) Assert.equals(source, roundTrip(source));
	}

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

}
