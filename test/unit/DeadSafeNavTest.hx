package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DeadSafeNav;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `dead-safe-nav` check: a null-safe access `a?.b` whose receiver is already
 * non-null **by flow** (a prior `!= null` guard, an `== null` guard's else-arm, or
 * a non-null assignment). The flow-only complement of `unnecessary-safe-nav` — a
 * receiver the declared type already proves non-null is left to that check.
 * Conservative: a reassignment, a non-identifier receiver, or a missing narrowing
 * suppresses the finding.
 */
class DeadSafeNavTest extends Test {

	public function testNarrowedThenFlagged(): Void {
		Assert.equals(1, violations('class C { function f(?x:String) { if (x != null) { var n = x?.length; } } }').length);
	}

	public function testElseBranchNarrowingFlagged(): Void {
		// `if (x == null) {} else { … }` narrows `x` to non-null in the else arm.
		Assert.equals(1, violations('class C { function f(?x:String) { if (x == null) trace(0); else { var n = x?.length; } } }').length);
	}

	public function testNonNullAssignmentFlagged(): Void {
		Assert.equals(1, violations('class C { function f(?x:Foo) { x = new Foo(); var n = x?.bar; } }').length);
	}

	public function testNoGuardNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(?x:String) { var n = x?.length; } }').length);
	}

	public function testDeclaredNonNullNotFlagged(): Void {
		// `s:String` under `@:nullSafety` is non-null by declaration — owned by `unnecessary-safe-nav`.
		Assert.equals(0, violations('@:nullSafety(Strict) class C { function f(s:String) { var n = s?.length; } }').length);
	}

	public function testReassignmentKills(): Void {
		Assert.equals(0, violations('class C { function f(?x:String) { if (x != null) { x = mk(); var n = x?.length; } } }').length);
	}

	public function testNonIdentReceiverNotFlagged(): Void {
		// The receiver of the `?.` is a field access, not a plain identifier.
		Assert.equals(0, violations('class C { function f(?x:Foo) { if (x != null) { var n = x.foo?.bar; } } }').length);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(?x:String) { if (x != null) { var n = x?.length; } } }');
		Assert.equals(1, vs.length);
		Assert.equals('dead-safe-nav', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixRewritesToDot(): Void {
		final check: DeadSafeNav = new DeadSafeNav();
		final src: String = 'class C { function f(?x:String) { if (x != null) { var n = x?.length; } } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(1, edits.length);
		Assert.equals('.', edits[0].text);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new DeadSafeNav().run([{ file: 'Bad.hx', source: 'class Bad { function f() { x?. ' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('dead-safe-nav'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('dead-safe-nav'));
	}

	/**
	 * Early-return narrowing reaches a `?.` after the guard.
	 */
	public function testEarlyReturnNarrowing(): Void {
		Assert.equals(1, violations('class C { function f(?x:String) { if (x == null) return; var n = x?.length; } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return new DeadSafeNav().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
