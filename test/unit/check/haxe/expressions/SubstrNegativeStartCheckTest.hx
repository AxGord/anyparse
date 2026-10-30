package unit.check.haxe.expressions;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Severity;
import anyparse.check.haxe.expressions.SubstrNegativeStart;

/**
 * The `substr-negative-start` check: a `substr` whose start is a subtraction is flagged `Warning`, report-only — a
 * negative result counts from the end of the string. A plain, a literal-negative or a length-slot subtraction, and
 * `substring`, are left alone.
 */
class SubstrNegativeStartCheckTest extends Test {

	public function testSubtractedStartFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('s.substr(n - 3, 2)'));
		Assert.equals(1, vs.length);
		Assert.equals('substr-negative-start', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(1, violations(wrap('s.substr(s.length - n)')).length);
	}

	/** A literal negative start is the from-the-end reading on purpose; a subtraction in the length slot is not a start. */
	@:pin('control')
	@:killer('M-SUBSTR-ANY-START')
	public function testOtherStartsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('s.substr(n)')).length);
		Assert.equals(0, violations(wrap('s.substr(n + 1)')).length);
		Assert.equals(0, violations(wrap('s.substr(-3)')).length);
		Assert.equals(0, violations(wrap('s.substr(0, n - 3)')).length);
		Assert.equals(0, violations(wrap('s.substring(n - 3)')).length);
	}

	public function testNoFix(): Void {
		Assert.equals(0, CheckFixture.edits(new SubstrNegativeStart(), wrap('s.substr(n - 3, 2)')).length);
	}

	/** Opt-in: the rule cannot see a guard that keeps the start non-negative. */
	public function testRegisteredAsDefaultOff(): Void {
		Assert.notNull(Linter.byId('substr-negative-start'));
		Assert.isTrue(Std.isOfType(new SubstrNegativeStart(), DefaultOff));
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f(s:String, n:Int):Void {\n\t\tvar x = $expr;\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new SubstrNegativeStart(), src);
	}

}
