package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LambdaBranchingBodyBlock;
import anyparse.check.PreferLambdaExpressionBody;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * `lambda-branching-body-braces` — the ADD half of the lambda-body brace policy: an arrow
 * whose body is a brace-less `if`-with-`else` or `switch` gets its block back.
 *
 * The pair with `prefer-lambda-expression-body` is what these tests mostly pin: that check
 * refuses exactly this population, so running BOTH to a fixpoint has to converge rather than
 * oscillate — `testFixpointWithTheRemoveHalf` is that guarantee, and it is the test that
 * fails first if either side's boundary moves.
 *
 * Identifiers are fully synthetic and bear no relation to any downstream code.
 */
@:nullSafety(Strict)
class LambdaBranchingBodyBlockCheckTest extends Test {

	/** An `if`/`else` body with no block is flagged. */
	public function testIfElseBodyFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f():Void {\n\t\tpost(ok -> if (ok) finish(); else abort(), onError);\n\t}\n}').length
		);
	}

	/** … and the fix wraps it, adding the `;` a block statement needs. */
	public function testIfElseBodyWrapped(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tpost(ok -> if (ok) finish(); else abort(), onError);\n\t}\n}';
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tpost(ok -> {\n\t\t\tif (ok) finish(); else abort();\n\t\t}, onError);\n\t}\n}\n',
			applied(src)
		);
	}

	/** An `else if` chain is caught by its outer `if`, whose else-branch child is the nested one. */
	public function testElseIfChainBodyFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f():Void {\n\t\tpost(v -> if (a) x() else if (b) y() else z(), onError);\n\t}\n}').length
		);
	}

	/** A `switch` body is flagged too — several arms, same reason. */
	public function testSwitchBodyFlagged(): Void {
		Assert.equals(
			1,
			violations('class C {\n\tfunction f():Void {\n\t\tpost(v -> switch v { case 1: f(); case _: g(); }, onError);\n\t}\n}').length
		);
	}

	/** A `switch` body already ends on `}`, so the wrap adds no `;`. */
	public function testSwitchBodyWrappedWithoutExtraSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tpost(v -> switch v { case 1: f(); case _: g(); }, onError);\n\t}\n}';
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tpost(v -> {\n\t\t\tswitch v {\n\t\t\t\tcase 1: f();\n\t\t\t\tcase _: g();\n\t\t\t}\n'
			+ '\t\t}, onError);\n\t}\n}\n',
			applied(src)
		);
	}

	/**
	 * GUARD: the TRAILING argument slot is left alone however the body branches — nothing
	 * follows it but `)`, so the remove half owns that slot instead.
	 */
	public function testTrailingSlotNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tpost(ok -> if (ok) finish(); else abort());\n\t}\n}').length);
	}

	/** GUARD: an else-LESS `if` has one arm — it is the shape the remove half may produce, so it is left alone. */
	public function testElseLessIfBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tpost(ok -> if (ok) finish());\n\t}\n}').length);
	}

	/** GUARD: a loop body has one arm too. */
	public function testLoopBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tpost(xs -> for (x in xs) use(x));\n\t}\n}').length);
	}

	/** GUARD: a body that is ALREADY a block carries its braces — nothing to add. */
	public function testBlockBodyNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tpost(ok -> {\n\t\t\tif (ok) finish();\n\t\t\telse abort();\n\t\t}, onError);\n\t}\n}'
			).length
		);
	}

	/** GUARD: a plain expression body is not branching. */
	public function testExpressionBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tpost(v -> compute(v));\n\t}\n}').length);
	}

	/**
	 * THE PAIR. The remove half must refuse what this check claims, or `lint --fix` would
	 * de-brace and re-brace the same site forever: with braces neither check fires, and
	 * without them only this one does.
	 */
	public function testFixpointWithTheRemoveHalf(): Void {
		final braced: String =
			'class C {\n\tfunction f():Void {\n\t\tpost(ok -> {\n\t\t\tif (ok) finish();\n\t\t\telse abort();\n\t\t}, onError);\n\t}\n}';
		Assert.equals(0, violations(braced).length);
		Assert.equals(0, removeHalf(braced).length);
		final bare: String = 'class C {\n\tfunction f():Void {\n\t\tpost(ok -> if (ok) finish(); else abort(), onError);\n\t}\n}';
		Assert.equals(1, violations(bare).length);
		Assert.equals(0, removeHalf(bare).length);
		// The TRAILING slot inverts both answers, and must invert BOTH: this check lets it be,
		// the remove half collapses it, and neither fires on the other's output.
		final tailBare: String = 'class C {\n\tfunction f():Void {\n\t\tpost(ok -> if (ok) finish(); else abort());\n\t}\n}';
		Assert.equals(0, violations(tailBare).length);
		Assert.equals(0, removeHalf(tailBare).length);
		final tailBraced: String =
			'class C {\n\tfunction f():Void {\n\t\tpost(ok -> {\n\t\t\tif (ok) finish();\n\t\t\telse abort();\n\t\t});\n\t}\n}';
		Assert.equals(0, violations(tailBraced).length);
		Assert.equals(1, removeHalf(tailBraced).length);
	}

	private function violations(src: String): Array<Violation> {
		return new LambdaBranchingBodyBlock().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function removeHalf(src: String): Array<Violation> {
		return new PreferLambdaExpressionBody().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applied(src: String): String {
		final check: LambdaBranchingBodyBlock = new LambdaBranchingBodyBlock();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		return switch RefactorSupport.canonicalize(src, edits, true, plugin) {
			case Ok(text): text;
			case Err(message): 'ERR: $message';
		};
	}

}
