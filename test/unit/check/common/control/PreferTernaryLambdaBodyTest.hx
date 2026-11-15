package unit.check.common.control;

import anyparse.check.common.control.PreferTernaryExpression;

/**
 * `prefer-ternary-expression` reads an arrow lambda's body as a value position: its expression
 * body, and the tail of its block body, which Haxe returns without `return`. A `function` block's
 * tail is not returned, and an `if` before the tail is a statement, so both stay unflagged.
 */
class PreferTernaryLambdaBodyTest extends Test {

	@:pin('control')
	@:killer('M-PTE-ARROW-EXPR-BODY-BLIND')
	public function testArrowExpressionBodyFixed(): Void {
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tvar v = () -> c ? 1 : 2;\n\t}\n}',
			fixed('class C {\n\tfunction f():Void {\n\t\tvar v = () -> if (c) 1 else 2;\n\t}\n}')
		);
	}

	/** One finding: the body is read from the lambda alone, never also as a delimited slot. */
	@:pin('control')
	@:killer('M-PTE-ARROW-EXPR-BODY-BLIND')
	public function testSingleParamArrowBodyFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg(x -> if (c) 1 else 2);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg(x -> c ? 1 : 2);\n\t}\n}', fixed(src));
	}

	/** The statement's terminator stays the ternary's. */
	@:pin('control')
	@:killer('M-PTE-ARROW-BLOCK-TAIL-BLIND')
	public function testArrowBlockTailFixed(): Void {
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tvar w = () -> { c ? 1 : 2; };\n\t}\n}',
			fixed('class C {\n\tfunction f():Void {\n\t\tvar w = () -> { if (c) 1 else 2; };\n\t}\n}')
		);
	}

	@:pin('control')
	@:killer('M-PTE-ARROW-BLOCK-TAIL-BLIND', 'M-PTE-ARROW-TAIL-FIRST')
	public function testArrowBlockTailAfterStatementFixed(): Void {
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tvar w = () -> {\n\t\t\tvar q = 1;\n\t\t\tc ? q : 2;\n\t\t};\n\t}\n}',
			fixed('class C {\n\tfunction f():Void {\n\t\tvar w = () -> {\n\t\t\tvar q = 1;\n\t\t\tif (c) q else 2;\n\t\t};\n\t}\n}')
		);
	}

	@:pin('control')
	@:killer('M-PTE-ARROW-READS-FUNCTION')
	public function testFunctionBlockTailNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar w = function() { if (c) 1 else 2; };\n\t}\n}').length);
	}

	@:pin('control')
	@:killer('M-PTE-ARROW-TAIL-FIRST')
	public function testArrowBlockNonTailNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar w = () -> {\n\t\t\tif (c) 1 else 2;\n\t\t\treturn 3;\n\t\t};\n\t}\n}')
				.length
		);
	}

	/** A branching lambda of calls keeps its `if` (`lambda-branching-body-braces` ladders it), in both body forms. */
	@:pin('control')
	@:killer('M-PTE-ARROW-CALLS-PLAIN')
	public function testArrowCallBranchesNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar v = () -> if (c) a() else b();\n\t}\n}').length);
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar w = () -> {\n\t\t\tif (c) a();\n\t\t\telse b();\n\t\t};\n\t}\n}').length
		);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferTernaryExpression(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new PreferTernaryExpression(), src);
	}

}
