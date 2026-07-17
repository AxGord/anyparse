package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DeadNullCoalescing;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `dead-null-coalescing` check: a null-coalescing `a ?? b` whose left operand is
 * already non-null **by flow** (a prior `!= null` guard, an `== null` guard's
 * else-arm, or a non-null assignment), so the fallback is dead. The flow-only
 * complement of `redundant-null-coalescing` — a left operand the declared type
 * already proves non-null is left to that check. Conservative: a reassignment, a
 * non-identifier left operand, or a missing narrowing suppresses the finding.
 */
class DeadNullCoalescingTest extends Test {

	public function testNarrowedThenFlagged(): Void {
		Assert.equals(1, violations('class C { function f(?x:String) { if (x != null) { var n = x ?? "d"; } } }').length);
	}

	public function testElseBranchNarrowingFlagged(): Void {
		Assert.equals(1, violations('class C { function f(?x:String) { if (x == null) trace(0); else { var n = x ?? "d"; } } }').length);
	}

	public function testNonNullAssignmentFlagged(): Void {
		Assert.equals(1, violations('class C { function f(?x:Foo) { x = new Foo(); var n = x ?? mk(); } }').length);
	}

	public function testNoGuardNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(?x:String) { var n = x ?? "d"; } }').length);
	}

	public function testDefaultNullParamNoGuardNotFlagged(): Void {
		// `x:Foo = null` is implicitly Null<Foo>; with no narrowing, the fallback is live.
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(x:Foo = null) { var n = x ?? mk(); } }').length);
	}

	public function testDefaultNullValueParamNoGuardNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(x:Int = null) { var n = x ?? 0; } }').length);
	}

	public function testDefaultNullParamGuardedStillFlagged(): Void {
		// A flow-narrowed default-null param IS dead — the rule stays useful.
		Assert.equals(1, violations('class C { function f(x:Foo = null) { if (x != null) { var n = x ?? mk(); } } }').length);
	}

	public function testDeclaredNonNullNotFlagged(): Void {
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(s:String) { var n = s ?? "d"; } }').length);
	}

	public function testReassignmentKills(): Void {
		Assert.equals(0, violations('class C { function f(?x:String) { if (x != null) { x = mk(); var n = x ?? "d"; } } }').length);
	}

	public function testNonIdentLeftNotFlagged(): Void {
		// The left operand is a call, not a plain identifier.
		Assert.equals(0, violations('class C { function f() { var n = foo() ?? "d"; } }').length);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(?x:String) { if (x != null) { var n = x ?? "d"; } } }');
		Assert.equals(1, vs.length);
		Assert.equals('dead-null-coalescing', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixUnwrapsToLeft(): Void {
		final check: DeadNullCoalescing = new DeadNullCoalescing();
		final src: String = 'class C { function f(?x:String) { if (x != null) { var n = x ?? "d"; } } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(1, edits.length);
		Assert.equals('x', edits[0].text);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new DeadNullCoalescing().run([{ file: 'Bad.hx', source: 'class Bad { function f() { x ?? ' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('dead-null-coalescing'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('dead-null-coalescing'));
	}

	/**
	 * Early-return narrowing reaches a `??` after the guard.
	 */
	public function testEarlyReturnNarrowing(): Void {
		Assert.equals(1, violations('class C { function f(?x:String) { if (x == null) return; var n = x ?? "d"; } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return new DeadNullCoalescing().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
