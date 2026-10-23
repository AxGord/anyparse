package unit.check;

import anyparse.check.DeadNullCoalescing;
import anyparse.check.NullSafetyGate;
import anyparse.check.Severity;
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

	/** A loop binder shadows the outer proof: `(x ?? d).bar` on the binder is a live fallback, not a dead one. */
	@:pin('control') @:killer('M-NULLFLOW-BINDER-BLIND')
	public function testLoopBinderShadowsTheOuterProof(): Void {
		Assert.equals(
			0,
			violations(
				'class C { function f(x:Null<Foo>, xs:Array<Null<Foo>>, d:Foo) { if (x == null) return; for (x in xs) g((x ?? d).bar); } }'
			).length
		);
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
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		final edits: Array<{ span: Span, text: String }> = CheckFixture.fixOf(check, src, vs);
		Assert.equals(1, edits.length);
		Assert.equals('x', edits[0].text);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, CheckFixture.violationsIn(new DeadNullCoalescing(), [{ file: 'Bad.hx', source: 'class Bad { function f() { x ?? ' }]).length
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

	/**
	 * A `??` whose left operand only a Bool local proves non-null: Haxe 4.3.7's null-safety does not narrow through it, so
	 * `return node ?? other` rewritten to `return node` fails with `Cannot return nullable value of Null<String> as String`
	 * (probed). It was a SAFE fix with no net at all — the one rewrite in this family that broke a build outright.
	 */
	@:pin('control') @:killer('M-DNC-UNSEEN-DROPPED', 'M-NSG-GATE-NEVER', 'M-DNC-DECLINED-FIXED')
	public function testBoolLocalProofKeepsNoFixUnderNullSafety(): Void {
		final src: String = '@:nullSafety(Strict) class C { static function f(node: Null<String>, other: String): String {'
			+ ' final ok: Bool = node != null; if (ok) return node ?? other; return other; } }';
		final check: DeadNullCoalescing = new DeadNullCoalescing();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length, 'the dead fallback is still reported');
		Assert.isTrue(vs[0].declineReason?.indexOf(NullSafetyGate.UNSEEN_PROOF) == 0, 'and says why it gets no fix');
		Assert.equals(0, CheckFixture.fixOf(check, src, vs).length, 'no unwrap the compiler would reject');
	}

	/** The control: a direct guard is a narrowing the compiler performs, so the fallback still goes under null-safety. */
	@:pin('control') @:killer('M-DSN-UNSEEN-ALL', 'M-NSG-VISIBLE-IGNORED')
	public function testDirectGuardKeepsTheFixUnderNullSafety(): Void {
		final src: String = '@:nullSafety(Strict) class C { static function f(node: Null<String>, other: String): String {'
			+ ' if (node != null) return node ?? other; return other; } }';
		final check: DeadNullCoalescing = new DeadNullCoalescing();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length);
		Assert.isNull(vs[0].declineReason);
		Assert.equals(1, CheckFixture.fixOf(check, src, vs).length, 'the fallback is dropped');
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new DeadNullCoalescing(), src);
	}

}
