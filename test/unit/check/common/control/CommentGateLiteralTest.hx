package unit.check.common.control;

import anyparse.check.Check;
import anyparse.check.common.control.EmptyCaseArm;
import anyparse.check.common.control.GuardReturn;
import anyparse.check.common.control.RedundantCaseBody;
import anyparse.check.common.control.UnnecessarySwitch;

/**
 * The comment gates of the guard and case-arm rules ask for a REAL comment in the text a
 * rewrite drops or moves: a `//` spelled inside a string literal in that text is code, so it
 * neither refuses the rewrite nor hides the finding.
 */
class CommentGateLiteralTest extends Test {

	@:pin('control')
	@:killer('M-GUARD-RETURN-TAIL-LINE-STRING-BLIND')
	public function testGuardReturnLiteralOnTailLineFlagged(): Void {
		final source: String = 'class C {\n\tfunction f(x:Int):Int {\n\t\t{\n\t\t\tif (x > 0) {\n\t\t\t\ttrace(1);\n\t\t\t\treturn 1;\n'
			+ '\t\t\t}\n\t\t\treturn 0; } trace(\'http://x\');\n\t\treturn 2;\n\t}\n}\n';
		flaggedAndFixed(new GuardReturn(), source);
	}

	@:pin('control')
	@:killer('M-EMPTY-CASE-ARM-STRING-BLIND')
	public function testEmptyCaseArmLiteralPatternFlagged(): Void {
		final source: String = 'class C {\n\tfunction f(s:String):Void {\n\t\tswitch (s) {\n\t\t\tcase \'a\':\n\t\t\t\ttrace(1);\n'
			+ '\t\t\tcase \'http://x\':\n\t\t}\n\t}\n}\n';
		flaggedAndFixed(new EmptyCaseArm(), source);
	}

	@:pin('control')
	@:killer('M-REDUNDANT-CASE-ALTERNATIVE-STRING-BLIND')
	public function testRedundantCaseBodyLiteralBodyFlagged(): Void {
		final source: String = 'class C {\n\tfunction f(n:Int):Void {\n\t\tswitch (n) {\n\t\t\tcase 1:\n\t\t\t\ttrace(\'http://x\');\n'
			+ '\t\t\tcase 2:\n\t\t\t\ttrace(\'http://x\');\n\t\t\tcase _:\n\t\t}\n\t}\n}\n';
		flaggedAndFixed(new RedundantCaseBody(), source);
	}

	@:pin('control')
	@:killer('M-UNNECESSARY-SWITCH-HEAD-STRING-BLIND')
	public function testUnnecessarySwitchLiteralSubjectFlagged(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn switch (\'http://x\') {\n\t\t\tcase _: 1;\n\t\t}\n\t}\n}\n';
		flaggedAndFixed(new UnnecessarySwitch(), source);
	}

	@:pin('control')
	@:killer('M-REDUNDANT-CASE-SUBSUMED-STRING-BLIND')
	public function testRedundantCaseBodySubsumedLiteralFlagged(): Void {
		final source: String = 'class C {\n\tfunction f(n:Int):Void {\n\t\tswitch (n) {\n\t\t\tcase 1:\n\t\t\t\ttrace(\'http://x\');\n'
			+ '\t\t\tcase _:\n\t\t\t\ttrace(\'http://x\');\n\t\t}\n\t}\n}\n';
		flaggedAndFixed(new RedundantCaseBody(), source);
	}

	@:pin('control')
	@:killer('M-UNNECESSARY-SWITCH-EMPTY-BODY-STRING-BLIND')
	public function testUnnecessarySwitchEmptyBodyLiteralSubjectFlagged(): Void {
		final source: String =
			'class C {\n\tfunction f():Void {\n\t\ttrace(0);\n\t\tswitch (\'http://x\') {\n\t\t\tcase _:\n\t\t}\n\t\ttrace(1);\n\t}\n}\n';
		flaggedAndFixed(new UnnecessarySwitch(), source);
	}

	/** `check` reports exactly one finding on `source` and its fix rewrites it. */
	private function flaggedAndFixed(check: Check, source: String): Void {
		Assert.equals(1, CheckFixture.violations(check, source).length);
		Assert.isTrue(CheckFixture.edits(check, source).length > 0);
	}

}
