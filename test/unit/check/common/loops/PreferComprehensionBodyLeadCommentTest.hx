package unit.check.common.loops;

import anyparse.check.common.loops.PreferComprehension;

using StringTools;

/**
 * A `//` comment that led a kept loop BODY stays inside the comprehension's block, before the
 * statement it led; it is not hoisted above the whole result.
 */
class PreferComprehensionBodyLeadCommentTest extends Test {

	@:pin('control')
	@:killer('M-BODY-LEAD-COMMENT-DROPPED')
	public function testBodyLeadCommentStaysInsideTheBlock(): Void {
		final fixed: String = CheckFixture.fixedSource(new PreferComprehension(), source('', '// half of the step'));
		final c: Int = fixed.indexOf('// half of the step');
		Assert.isTrue(c > fixed.indexOf('for (i in 0...3)'), fixed);
		Assert.isTrue(c < fixed.indexOf('final h'), fixed);
		Assert.equals('', fixed.substring(fixed.lastIndexOf('\n', c) + 1, c).trim(), fixed);
	}

	/** A comment above the loop is not the body's: it stays above the result. */
	@:pin('guard')
	public function testCommentAboveTheLoopStaysAbove(): Void {
		final fixed: String = CheckFixture.fixedSource(new PreferComprehension(), source('// above the loop', ''));
		Assert.isTrue(fixed.indexOf('// above the loop') < fixed.indexOf('for (i in 0...3)'), fixed);
		Assert.isTrue(fixed.indexOf('// above the loop') < fixed.indexOf('final out'), fixed);
	}

	/** A local read twice stays in the block, so the body-lead comment has a statement to stay before. */
	private function source(aboveLoop: String, bodyLead: String): String {
		return 'class C {\n\tfunction f():Array<Int> {\n\t\tfinal out:Array<Int> = [];\n\t\t$aboveLoop\n\t\tfor (i in 0...3) {\n\t\t\t'
			+ '$bodyLead\n\t\t\tfinal h:Int = i >> 1;\n\t\t\tout.push(h + h);\n\t\t}\n\t\treturn out;\n\t}\n}';
	}

}
