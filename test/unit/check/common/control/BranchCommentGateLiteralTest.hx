package unit.check.common.control;

import anyparse.check.common.control.CollapseNestedSwitch;
import anyparse.check.common.control.HoistCommonBranchHead;
import anyparse.check.common.control.HoistCommonBranchTail;
import anyparse.check.common.control.PreferIfExpressionChain;

/**
 * The comment gates of the collapse, hoist and if-expression-chain rules ask for a REAL comment
 * in the text a rewrite drops or rebuilds: a `//` spelled inside a string literal there is code,
 * so it neither refuses the rewrite nor hides the finding.
 */
class BranchCommentGateLiteralTest extends Test {

	/** The enum the collapse fixtures match, so the switched binder is a typed constructor argument. */
	private static final ENUM: String = 'enum Constant {\n\tCString(s: String, kind: String);\n}\n';

	@:pin('control')
	@:killer('M-COLLAPSE-PATTERN-SUFFIX-STRING-BLIND')
	public function testCollapseNestedSwitchLiteralPatternSuffixFlagged(): Void {
		collapses('case CString(s, \'http://x\'):\n\t\t\t\tswitch s {\n\t\t\t\t\tcase \'a\': p();\n\t\t\t\t\tcase _:\n\t\t\t\t}');
	}

	@:pin('control')
	@:killer('M-COLLAPSE-PATTERN-PREFIX-STRING-BLIND')
	public function testCollapseNestedSwitchLiteralPatternPrefixFlagged(): Void {
		collapses('case CString(\'http://x\', kind):\n\t\t\t\tswitch kind {\n\t\t\t\t\tcase \'a\': p();\n\t\t\t\t\tcase _:\n\t\t\t\t}');
	}

	@:pin('control')
	@:killer('M-COLLAPSE-INNER-SUBJECT-STRING-BLIND')
	public function testCollapseNestedSwitchLiteralInnerSubjectFlagged(): Void {
		collapses(
			'case CString(s, kind):\n\t\t\t\tswitch tap(kind, \'http://x\') {\n\t\t\t\t\tcase \'a\': p();\n\t\t\t\t\tcase _: r();\n'
			+ '\t\t\t\t}'
		);
	}

	@:pin('control')
	@:killer('M-HCBH-HEAD-STRING-BLIND')
	public function testHoistCommonBranchHeadLiteralHeadFixed(): Void {
		final source: String = 'class C { function f(c:Bool) { if (c) { h(\'http://x\'); a(); } else { h(\'http://x\'); b(); } } }';
		Assert.equals(
			'class C { function f(c:Bool) { h(\'http://x\');\nif (c) { a(); } else { b(); } } }',
			CheckFixture.fixedSource(new HoistCommonBranchHead(), source)
		);
	}

	@:pin('control')
	@:killer('M-HCBH-ELSE-STRING-BLIND')
	public function testHoistCommonBranchHeadLiteralEmptiedElseDropped(): Void {
		final source: String = 'class C { function f(c:Bool) { if (c) { h(\'http://x\'); a(); } else { h(\'http://x\'); } } }';
		Assert.equals(
			'class C { function f(c:Bool) { h(\'http://x\');\nif (c) { a(); } } }',
			CheckFixture.fixedSource(new HoistCommonBranchHead(), source)
		);
	}

	@:pin('control')
	@:killer('M-HCBT-WHOLE-STRING-BLIND')
	public function testHoistCommonBranchTailLiteralWholeChainFixed(): Void {
		final source: String = 'class C { function f(c:Bool) { if (c) { t(\'http://x\'); } else { t(\'http://x\'); } } }';
		Assert.equals('class C { function f(c:Bool) { t(\'http://x\'); } }', CheckFixture.fixedSource(new HoistCommonBranchTail(), source));
	}

	@:pin('control')
	@:killer('M-PIEC-INVERT-STRING-BLIND')
	public function testPreferIfExpressionChainLiteralConditionInverted(): Void {
		final source: String =
			'class C {\n\tfunction f(d:Bool, s:String, b:Bool):Int {\n\t\treturn d ? 0 : s == \'http://x\' ? b ? 1 : 2 : 3;\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = CheckFixture.edits(new PreferIfExpressionChain(), source);
		Assert.equals(1, es.length);
		Assert.equals('if (d) 0 else if (s != \'http://x\') 3 else if (b) 1 else 2', es[0].text);
	}

	/** An unprovable ordered comparison beside a literal `//` still declines the `!( … )` inversion. */
	@:pin('control')
	@:killer('M-PIEC-WORTH-GATE-STRING-BLIND')
	public function testPreferIfExpressionChainLiteralWorthGateDeclines(): Void {
		final source: String = 'class C {\n\tfunction f(d:Bool, x:Float, y:Float, s:String, b:Bool):Int {\n'
			+ '\t\treturn d ? 0 : x < y && s == \'http://x\' ? b ? 1 : 2 : 3;\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = CheckFixture.edits(new PreferIfExpressionChain(), source);
		Assert.equals(1, es.length);
		Assert.equals('if (d) 0 else if (x < y && s == \'http://x\') b ? 1 : 2 else 3', es[0].text);
	}

	/** An inverted rung whose condition holds a literal `//` is negated by De Morgan, not wrapped. */
	@:pin('control')
	@:killer('M-PIEC-NEGATE-TEXT-STRING-BLIND')
	public function testPreferIfExpressionChainLiteralNegatedByDeMorgan(): Void {
		final source: String = 'class C {\n\tfunction f(d:Bool, s:String, b:Bool, c:Bool):Int {\n'
			+ '\t\treturn d ? 0 : s == \'http://x\' && b ? c ? 1 : 2 : 3;\n\t}\n}';
		final es: Array<{ span: Span, text: String }> = CheckFixture.edits(new PreferIfExpressionChain(), source);
		Assert.equals(1, es.length);
		Assert.equals('if (d) 0 else if (s != \'http://x\' || !b) 3 else if (c) 1 else 2', es[0].text);
	}

	/** The outer switch holding the one `arm` and an empty catch-all is flagged and its fix splices the arm. */
	private function collapses(arm: String): Void {
		final source: String =
			'class C {\n\tfunction f(s: String): Void {\n\t\tswitch s {\n\t\t\t$arm\n\t\t\tcase _:\n\t\t}\n\t}\n}\n$ENUM';
		Assert.equals(1, CheckFixture.violations(new CollapseNestedSwitch(), source).length);
		Assert.isTrue(CheckFixture.edits(new CollapseNestedSwitch(), source).length > 0);
	}

}
