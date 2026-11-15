package unit.check.common.loops;

import anyparse.check.common.loops.WhileTrueCondition;
import anyparse.runtime.Span;

/**
 * The loops family's negation reads the file's lexical regions: a `//` spelled inside a string operand is not a
 * comment, so the lifted `while (true)` condition De Morgans instead of wrapping the text verbatim.
 */
class LoopNegationRegionsTest extends Test {

	@:pin('control')
	@:killer('M-WHILE-TRUE-REGIONS-DROPPED')
	public function testWhileTrueStringMarkerDeMorgans(): Void {
		final src: String = 'class C {\n\tfunction f(x:String, y:Bool) {\n\t\twhile (true) {\n\t\t\tif (x == \'a//b\' && y) break;\n'
			+ '\t\t\tg();\n\t\t}\n\t}\n}\n';
		final t: String = joined(CheckFixture.edits(new WhileTrueCondition(), src));
		Assert.isTrue(t.indexOf("while (x != 'a//b' || !y)") != -1, t);
	}

	private function joined(es: Array<{ span: Span, text: String }>): String {
		return es.map(e -> e.text).join('\n');
	}

}
