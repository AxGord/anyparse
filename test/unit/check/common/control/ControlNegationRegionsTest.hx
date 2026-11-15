package unit.check.common.control;

import anyparse.check.common.control.GuardReturn;
import anyparse.check.common.control.PreferIfExpressionReturn;

/**
 * The control family's negation reads the file's lexical regions: a `//` spelled inside a string operand is not a
 * comment, so an inversion De Morgans or flips instead of wrapping the text verbatim, and the guard report gate sees
 * the declined flip a comment marker would have hidden.
 */
class ControlNegationRegionsTest extends Test {

	@:pin('control')
	@:killer('M-GUARD-SPLICE-REGIONS-DROPPED')
	public function testGuardReturnStringMarkerDeMorgans(): Void {
		final src: String = "class C {\n\tfunction f(x:String, y:Bool):Bool {\n\t\tif ('a//b' == x && y) {\n\t\t\tlog(x);\n"
			+ '\t\t\treturn true;\n\t\t}\n\t\treturn false;\n\t}\n}\n';
		Assert.isTrue(joined(CheckFixture.edits(new GuardReturn(), src)).indexOf("if ('a//b' != x || !y) return false;") != -1);
	}

	/**
	 * A Float ordered comparison declines its flip; a `//` spelled in a string beside it no longer waves the site through.
	 */
	@:pin('control')
	@:killer('M-GUARD-REPORT-REGIONS-DROPPED')
	public function testGuardReturnStringMarkerKeepsDeclinedFlipUnreported(): Void {
		final src: String = "class C {\n\tfunction f(s:String, p:Float, q:Float):Bool {\n\t\tif ('a//b' == s && p < q) {\n\t\t\tlog(s);\n"
			+ '\t\t\treturn true;\n\t\t}\n\t\treturn false;\n\t}\n}\n';
		Assert.equals(0, CheckFixture.violations(new GuardReturn(), src).length);
	}

	@:pin('control')
	@:killer('M-PIER-OUTER-REGIONS-DROPPED')
	public function testIfExpressionReturnOuterMergeFlipsStringOperand(): Void {
		final src: String =
			"class C {\n\tfunction f() {\n\t\tif (m == 'a//b' && k) return null;\n\t\treturn (g ? m.a : m.b) ? p : null;\n\t}\n}";
		final es: Array<{ span: Span, text: String }> = CheckFixture.edits(new PreferIfExpressionReturn(), src);
		Assert.equals(1, es.length);
		Assert.isTrue(es[0].text.indexOf("m != 'a//b' || !k") != -1, es[0].text);
	}

	private function joined(es: Array<{ span: Span, text: String }>): String {
		return es.map(e -> e.text).join('\n');
	}

}
