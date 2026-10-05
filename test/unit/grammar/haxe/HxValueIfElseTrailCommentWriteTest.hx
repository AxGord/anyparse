package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * A `//` comment trailing a value `if`'s then-branch, before its `else`, survives the round trip
 * under every `sameLine.expressionIf` value.
 *
 * The comment lands in the `elseBranchBeforeKwTrailing` slot and `kwBeforeTrailingDoc` emits it
 * ahead of the pre-`else` gap. Under `same` (the compiled default) that gap is a plain space, so
 * the writer put `else` on the comment's own line, the comment swallowed it, and `writeRoundTrip`
 * refused the file. `next` / `fitLine` / `keep` answer a hardline there and never met the defect.
 * It was the writer half of `prefer-if-expression-assignment`'s trailing-comment carry: the rule's
 * edit text was right and every `--fix` under the default config refused it.
 */
class HxValueIfElseTrailCommentWriteTest extends Test {

	/**
	 * The compiled default, `same`: the comment keeps its line and `else` starts the next one.
	 * RED at base, where the round trip throws `CommentLossException`.
	 */
	@:pin('control')
	@:killer('M-KWTRAIL-FLAT-GAP-KEPT')
	public function testUnderSameTheCommentKeepsItsLine(): Void {
		assertFixedPoint('x = if (a) 1 // one\n\t\telse 3;');
	}

	/** The shape the rule writes: an `else if` chain behind the commented branch. RED at base. */
	public function testAChainBehindTheCommentKeepsIt(): Void {
		assertFixedPoint('x = if (a) 1 // one\n\t\telse if (b) 2 else 3;');
	}

	/**
	 * A gap that already opens with a line break is left exactly as it was: a trailing comment plus
	 * an own-line comment before a STATEMENT `else`. Green at base; killed by an arm that answers
	 * every non-flat gap with a hardline of its own instead of the guard that drops before one.
	 */
	@:pin('control')
	@:killer('M-KWTRAIL-GUARD-HARD')
	public function testAGapOpeningWithABreakIsUnchanged(): Void {
		assertFixedPoint('if (a) x = 1; // s\n\t\t// own\n\t\telse x = 2;');
	}

	/** The statement is already what the writer produces for it — the byte contract a canonical file has. */
	private function assertFixedPoint(statements: String): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\t$statements\n\t}\n}\n';
		Assert.equals(source, new HaxeQueryPlugin().writeRoundTrip(source));
	}

}
