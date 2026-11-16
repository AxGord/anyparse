package unit.check.common.expressions;

import anyparse.check.common.expressions.PreferLambdaExpressionBody;

/**
 * `prefer-lambda-expression-body` reads a `//` inside a string literal on the last interior
 * line of a de-braced lambda as text, not as the start of a comment.
 */
class PreferLambdaExpressionBodyStringMarkerTest extends Test {

	/**
	 * The last interior line `tokenError("a//b");` loses only its terminator under the collapse,
	 * exactly like `tokenError("ab");` — the `//` is inside a string, so it opens no comment.
	 */
	@:pin('control')
	@:killer('M-LAMBDA-STRING-SLASHES-ARE-COMMENT')
	public function testSlashesInsideStringOnTheLastInteriorLineStillCollapse(): Void {
		Assert.equals(1, violations(source('"ab"')).length);
		Assert.equals(1, violations(source('"a//b"')).length);
	}

	/**
	 * A block comment INSIDE the code of the last interior line is not the trailing comment run: the `;` to
	 * drop is the one after it, so the collapse is not refused.
	 */
	@:pin('control')
	@:killer('M-LAMBDA-FIRST-COMMENT-CUTS-CODE')
	public function testBlockCommentInsideTheCodeStillCollapses(): Void {
		Assert.equals(1, violations(source('a /* x */')).length);
		Assert.equals(1, violations(source('/* x */ a')).length);
	}

	private function source(arg: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\twaitToken(success -> {\n\t\t\tif (success)\n\t\t\t\tdoRequest();\n\t\t\telse\n'
			+ '\t\t\t\ttokenError($arg);\n\t\t});\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferLambdaExpressionBody(), src);
	}

}
