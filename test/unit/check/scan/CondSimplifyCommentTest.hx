package unit.check.scan;

import anyparse.check.common.nullsafety.DeadNullGuard;
import anyparse.query.CanonicalEdit;

/**
 * The constant-condition rewrite (`CheckScan.simplifyConditionFixes`, reached through `dead-null-guard`): a `//`
 * spelled inside a string literal of the text it drops is no comment, a real comment there refuses the rewrite.
 */
class CondSimplifyCommentTest extends Test {

	@:pin('control')
	@:killer('M-IF-SHAPE-DROPPED-ANY-TEXT')
	public function testDeletedIfHoldingStringMarkerIsRewritten(): Void {
		final out: String = fixText(wrap('if (x == null) {\n\t\t\tfinal s = "http://a";\n\t\t\tx.g();\n\t\t}'));
		Assert.isTrue(out.indexOf('http://a') == -1, 'expected the dead `if` gone in: $out');
		Assert.isTrue(out.indexOf('new Foo()') >= 0, 'expected the rest kept in: $out');
	}

	@:pin('control')
	@:killer('M-IF-SHAPE-DROPPED-NEVER')
	public function testDeletedIfHoldingCommentIsRefused(): Void {
		assertRefused(wrap('if (x == null) {\n\t\t\t// note\n\t\t\tx.g();\n\t\t}'));
	}

	@:pin('control')
	@:killer('M-OPERAND-DROP-NEVER')
	public function testDroppedConjunctHoldingCommentIsRefused(): Void {
		assertRefused(wrap('if (cond() && /* keep */ x != null) x.g();'));
	}

	private function wrap(body: String): String {
		return 'class Foo {\n\tpublic function new() {}\n\tpublic function g():Void {}\n}\n\n@:nullSafety(Strict)\nclass C {\n'
			+ '\tfunction cond():Bool\n\t\treturn true;\n\n\tfunction f():Void {\n\t\tvar x = new Foo();\n\t\t$body\n\t}\n}\n';
	}

	private function fixText(src: String): String {
		final check: DeadNullGuard = new DeadNullGuard();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		return switch CanonicalEdit.canonicalize(src, CheckFixture.fixOf(check, src, vs), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
				src;
		};
	}

	private function assertRefused(src: String): Void {
		final check: DeadNullGuard = new DeadNullGuard();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.isTrue(vs.length > 0, 'expected a finding to exist');
		Assert.equals(0, CheckFixture.fixOf(check, src, vs).length);
	}

}
