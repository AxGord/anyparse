package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DeadNullGuard;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `dead-null-guard` check: a null comparison whose operand is already
 * non-null **by flow** (a prior `!= null` guard narrowed it, or a non-null
 * assignment) on every path reaching it. Strictly the flow-only complement of
 * `unnecessary-null-check` — an operand the declared type already proves
 * non-null is left to that check. Conservative: a reassignment, a closure
 * capture, a loop back-edge, or a macro subtree all suppress the finding.
 */
class DeadNullGuardTest extends Test {

	public function testInnerGuardFlagged(): Void {
		// Outer guard narrows the optional `x`; the inner re-check is dead. Only the inner is flagged.
		Assert.equals(1, violations('class C { function f(?x:String) { if (x != null) { if (x != null) trace(x); } } }').length);
	}

	public function testEqNullAlsoFlagged(): Void {
		// `x == null` under a non-null path is constantly false — also dead.
		Assert.equals(1, violations('class C { function f(?x:String) { if (x != null) { if (x == null) trace(x); } } }').length);
	}

	public function testNonNullAssignmentFlagged(): Void {
		// A constructor assignment makes the nullable `x` non-null by flow.
		Assert.equals(1, violations('class C { function f(?x:Foo) { x = new Foo(); if (x != null) trace(x); } }').length);
	}

	public function testReassignmentKills(): Void {
		// A nullable reassignment between the narrowing guard and the inner check clears the fact.
		Assert.equals(0, violations('class C { function f(?x:String) { if (x != null) { x = mk(); if (x != null) trace(x); } } }').length);
	}

	public function testDeclaredNonNullNotFlagged(): Void {
		// `s:String` under `@:nullSafety` is non-null by declaration — owned by `unnecessary-null-check`, not this check.
		Assert.equals(
			0, violations('@:nullSafety(Strict) class C { function f(s:String) { if (s != null) { if (s != null) trace(s); } } }').length
		);
	}

	public function testClosureCaptureNotFlagged(): Void {
		// `x` is mutated inside a closure — never narrowable.
		Assert.equals(
			0,
			violations('class C { function f(?x:String) { var g = () -> x = null; if (x != null) { if (x != null) trace(x); } } }').length
		);
	}

	public function testLoopBackEdgeKills(): Void {
		// The loop reassigns `x`, so the narrowing from the outer guard cannot survive the back-edge.
		Assert.equals(
			0,
			violations('class C { function f(?x:String) { if (x != null) { while (cond()) { if (x != null) trace(x); x = mk(); } } } }').length
		);
	}

	public function testMacroSubtreeNotDescended(): Void {
		// A comparison inside a `macro { … }` reification is opaque — not analyzed.
		Assert.equals(
			0, violations('class C { function f(?x:String) { if (x != null) { var e = macro { if (x != null) trace(x); }; } } }').length
		);
	}

	public function testOuterGuardAloneNotFlagged(): Void {
		// A single legitimate guard on a nullable value is not redundant.
		Assert.equals(0, violations('class C { function f(?x:String) { if (x != null) trace(x); } }').length);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(?x:String) { if (x != null) { if (x != null) trace(x); } } }');
		Assert.equals(1, vs.length);
		Assert.equals('dead-null-guard', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixIsNoop(): Void {
		final check: DeadNullGuard = new DeadNullGuard();
		final src: String = 'class C { function f(?x:String) { if (x != null) { if (x != null) trace(x); } } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new DeadNullGuard().run([{ file: 'Bad.hx', source: 'class Bad { function f() { if (x != ' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('dead-null-guard'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('dead-null-guard'));
	}

	/**
	 * After `if (x == null) return;` the fall-through path has x non-null.
	 */
	public function testEarlyReturnNarrowing(): Void {
		Assert.equals(1, violations('class C { function f(?x:String) { if (x == null) return; if (x != null) trace(x); } }').length);
	}

	/**
	 * Both arms assign a non-null value, so x is non-null after the if/else (join).
	 */
	public function testIfElseJoinNarrowing(): Void {
		Assert.equals(
			1,
			violations('class C { function f(?x:Foo) { if (c()) x = new Foo(); else x = new Foo(); if (x != null) trace(x); } }').length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new DeadNullGuard().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
