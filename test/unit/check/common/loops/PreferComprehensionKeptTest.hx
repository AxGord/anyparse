package unit.check.common.loops;

import anyparse.check.common.loops.PreferComprehension;

/**
 * The kept-statement arm of `prefer-comprehension`: a loop body whose statements ahead of the push are
 * single-assignment `final` locals and bare `if (c) continue;` guards folds to a block-bodied comprehension
 * that keeps them, `{ final y = f(x); if (y != null) y; }`, where the chain form would have inlined or refused.
 * The refusals pin what the arm must not admit: a second push, a `var`, a break, the array read by a kept
 * local or guard, a comment inside a kept statement.
 */
class PreferComprehensionKeptTest extends Test {

	/** A local read twice cannot be inlined, so it stays: the binding-and-push shape. */
	@:pin('control')
	@:killer('M-KEPT-BLOCK-DECLINED')
	public function testALocalReadTwiceStaysInTheBlock(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) { final y = f(x); y + y; }];'),
			applyFix(fnRet(body('final y = f(x);\n\t\t\tout.push(y + y);')))
		);
	}

	/** The guard-continue shape: the guard becomes the negated `if` around the element. */
	@:pin('control')
	@:killer('M-KEPT-GUARD-BLIND')
	public function testAGuardContinueBecomesTheNegatedIf(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) { final y = f(x); if (y != null) y; }];'),
			applyFix(fnRet(body('final y = f(x);\n\t\t\tif (y == null) continue;\n\t\t\tout.push(y);')))
		);
	}

	public function testALeadingGuardBracesTheLocalsAfterIt(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) if (!(x < 2)) { final z = x * 2; z + z; }];'),
			applyFix(fnRet(body('if (x < 2) continue;\n\t\t\tfinal z = x * 2;\n\t\t\tout.push(z + z);')))
		);
	}

	public function testGuardsAfterLocalsNestInOrder(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) { final z = x * 2; if (!(z < 2)) { final w = z + 1; if (!(w > 9)) w; } }];'),
			applyFix(fnRet(
				body('final z = x * 2;\n\t\t\tif (z < 2) continue;\n\t\t\tfinal w = z + 1;\n\t\t\tif (w > 9) continue;\n\t\t\tout.push(w);')
			))
		);
	}

	public function testGuardsAloneNestWithoutBraces(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) if (!(x < 2)) if (!(x > 9)) x];'),
			applyFix(fnRet(body('if (x < 2) continue;\n\t\t\tif (x > 9) continue;\n\t\t\tout.push(x);')))
		);
	}

	/** A second push is a second effect per step; no comprehension element expresses it. */
	@:pin('guard')
	public function testAMultiPushBodyIsDeclined(): Void {
		Assert.equals(0, violations(fnRet(body('final y = f(x);\n\t\t\tout.push(y);\n\t\t\tout.push(y + 1);'))).length);
	}

	@:pin('guard')
	public function testABreakIsDeclined(): Void {
		Assert.equals(0, violations(fnRet(body('final y = f(x);\n\t\t\tif (y == 0) break;\n\t\t\tout.push(y);'))).length);
	}

	public function testAVarLocalIsDeclined(): Void {
		Assert.equals(0, violations(fnRet(body('var y = f(x);\n\t\t\tif (y == 0) continue;\n\t\t\tout.push(y);'))).length);
	}

	/** The comprehension's own array is not the one being read, so a local reading `out` would change the result. */
	@:pin('control')
	@:killer('M-KEPT-INIT-UNGATED')
	public function testALocalReadingTheArrayIsDeclined(): Void {
		Assert.equals(0, violations(fnRet(body('final y = out.length + x;\n\t\t\tif (y == 3) continue;\n\t\t\tout.push(y);'))).length);
	}

	@:pin('control')
	@:killer('M-KEPT-GUARD-UNGATED')
	public function testAGuardReadingTheArrayIsDeclined(): Void {
		Assert.equals(0, violations(fnRet(body('final y = f(x);\n\t\t\tif (out.length > y) continue;\n\t\t\tout.push(y);'))).length);
	}

	public function testACommentInsideAKeptStatementIsDeclined(): Void {
		Assert.equals(0, violations(fnRet(body('final y = f(x) /* c */;\n\t\t\tif (y == 0) continue;\n\t\t\tout.push(y);'))).length);
	}

	/** A statement between the locals and the push is a side effect the comprehension element cannot carry. */
	@:pin('control')
	@:killer('M-KEPT-ANY-STATEMENT')
	public function testAnotherStatementIsDeclined(): Void {
		Assert.equals(0, violations(fnRet(body('final y = f(x);\n\t\t\ttrace(y);\n\t\t\tout.push(y);'))).length);
	}

	/** A local named after the array would shadow it in the block, so the comprehension's own array is not the one the element reads. */
	@:pin('control')
	@:killer('M-KEPT-LOCAL-NAMED-AFTER-ARRAY')
	public function testALocalNamedAfterTheArrayIsDeclined(): Void {
		Assert.equals(0, violations(fnRet(body('final out = x;\n\t\t\tout.push(1);'))).length);
	}

	/** Only the first declarator's initializer reaches the self-reference gate, so a multi-declarator local must decline. */
	@:pin('control')
	@:killer('M-KEPT-MULTI-DECLARATOR')
	public function testAMultiDeclaratorLocalIsDeclined(): Void {
		Assert.equals(0, violations(fnRet(body('final y = x * 2, w = 3;\n\t\t\tout.push(y + y + w);'))).length);
	}

	private function body(stmts: String): String {
		return 'final out:Array<Int> = [];\n\t\tfor (x in xs) {\n\t\t\t$stmts\n\t\t}';
	}

	private function fnRet(stmts: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>):Array<Int> {\n\t\t$stmts\n\t\treturn out;\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return CheckFixture.violations(new PreferComprehension(), source);
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new PreferComprehension(), source);
	}

}
