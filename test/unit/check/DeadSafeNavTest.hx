package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.DeadSafeNav;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

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

	public function testConjunctNarrowedSafeNavFlagged(): Void {
		// The `&&` right side sees the left conjunct's narrowing — the `?.` can never short-circuit.
		Assert.equals(1, violations('class C { function f(?x:String) { if (x != null && x?.length == 1) trace(x); } }').length);
	}

	public function testOrChainWriteNotFlagged(): Void {
		// A disjunct writes x after the `== null` comparison — the stale narrowing must not flag the `?.`.
		Assert.equals(
			0, violations('class C { function f(?x:String) { if (x == null || (x = null) != null || x?.length == 0) trace(1); } }').length
		);
	}

	/**
	 * `CallGraph`'s `under?.name == null ? null : f(under?.name)`: the else-arm proves `under` non-null only through
	 * the safe-navigation comparison, which strict null-safety does not narrow on — reported, but no `.` rewrite.
	 */
	@:pin('control') @:killer('M-DSN-UNSEEN-DROPPED')
	public function testSafeNavComparisonProofKeepsNoFixUnderNullSafety(): Void {
		assertDeclined('@:nullSafety(Strict) class C { function f(u:Null<Foo>) { var a = u?.name == null ? null : g(u?.name); } }');
	}

	/** `CallGraph`'s `final writeSlot = parent != null && …; … writeSlot && parent?.kind`: a proof through a Bool local. */
	@:pin('control') @:killer('M-DSN-UNSEEN-DROPPED')
	public function testBoolLocalProofKeepsNoFixUnderNullSafety(): Void {
		assertDeclined(
			'@:nullSafety(Strict) class C { function f(parent:Null<Foo>, b:Bool) {'
			+ ' final w = parent != null && b; final r = !(w && parent?.kind == k); } }'
		);
	}

	/** An alias copy narrowed through its original: the compiler narrows `u`, never `v`. */
	@:pin('control') @:killer('M-DSN-UNSEEN-DROPPED')
	public function testAliasProofKeepsNoFixUnderNullSafety(): Void {
		assertDeclined('@:nullSafety(Strict) class C { function f(u:Null<Foo>) { var v = u; if (u != null) { var n = v?.bar; } } }');
	}

	/** The control: an early-return guard is a narrowing the compiler performs too, so the fix stays. */
	@:pin('control') @:killer('M-DSN-UNSEEN-ALL')
	public function testDirectGuardKeepsTheFixUnderNullSafety(): Void {
		assertFixed('@:nullSafety(Strict) class C { function f(x:Null<Foo>) { if (x == null) return; var n = x?.bar; } }');
	}

	/** Without null-safety nothing typechecks the narrowing, so a Bool-local proof still gets its runtime-sound fix. */
	@:pin('control') @:killer('M-DSN-NULLSAFE-ALWAYS')
	public function testBoolLocalProofKeepsTheFixWithoutNullSafety(): Void {
		assertFixed('class C { function f(x:Null<Foo>) { final ok = x != null; if (ok) { var n = x?.bar; } } }');
	}

	/** A join keeps a proof visible only when BOTH arms made it visibly: here one arm narrowed through a Bool local. */
	@:pin('control') @:killer('M-DSN-JOIN-EITHER')
	public function testJoinWithOneUnseenArmKeepsNoFix(): Void {
		assertDeclined(
			'@:nullSafety(Strict) class C { function f(x:Null<Foo>, b:Bool) { if (b) { if (x == null) return; } else {'
			+ ' final ok = x != null; if (ok) {} else return; } var n = x?.bar; } }'
		);
	}

	/** A receiver the compiler already narrowed stays narrowed when a Bool local proves it again. */
	@:pin('control') @:killer('M-DSN-RENARROW-HIDES')
	public function testVisibleProofSurvivesAnUnseenRenarrowing(): Void {
		assertFixed(
			'@:nullSafety(Strict) class C { function f(x:Null<Foo>) { if (x == null) return; final ok = x != null; if (ok) {'
			+ ' var n = x?.bar; } } }'
		);
	}

	/** A non-null assignment is a narrowing the compiler sees, whatever proved the name before it. */
	@:pin('control') @:killer('M-DSN-ASSIGN-KEEPS-UNSEEN')
	public function testNonNullAssignmentMakesTheProofVisible(): Void {
		assertFixed(
			'@:nullSafety(Strict) class C { function f(x:Null<Foo>) { final ok = x != null; if (ok) { x = new Foo(); var n = x?.bar; } } }'
		);
	}

	/** A `--macro nullSafety('')` in the oracle hxml turns null-safety on for a file that carries no `@:nullSafety`. */
	@:pin('control') @:killer('M-DSN-MACRO-BLIND')
	public function testOracleMacroNullSafetyKeepsNoFix(): Void {
		#if (sys || nodejs)
		assertDeclinedIn('--macro nullSafety(\'\', Strict)');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A macro naming another package leaves this module plain, so the fix stays. */
	@:pin('control') @:killer('M-DSN-MACRO-COVERS-ALL')
	public function testOracleMacroOnAnotherPackageKeepsTheFix(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = runIn('--macro nullSafety(\'other.pkg\')');
		Assert.equals(1, vs.length);
		Assert.isNull(vs[0].declineReason);
		#else
		Assert.pass('non-sys target');
		#end
	}

	private function assertDeclined(src: String): Void {
		final check: DeadSafeNav = new DeadSafeNav();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length, 'the redundant `?.` is still reported');
		Assert.notNull(vs[0].declineReason, 'and says why it gets no fix');
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length, 'no `.` rewrite the compiler would reject');
	}

	private function assertFixed(src: String): Void {
		final check: DeadSafeNav = new DeadSafeNav();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(1, check.fix(src, vs, new HaxeQueryPlugin()).length, 'the `?.` is rewritten to `.`');
	}

	private function violations(src: String): Array<Violation> {
		return new DeadSafeNav().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	#if (sys || nodejs)
	private function assertDeclinedIn(hxmlLine: String): Void {
		final vs: Array<Violation> = runIn(hxmlLine);
		Assert.equals(1, vs.length);
		Assert.notNull(vs[0].declineReason, 'the macro makes the Bool-local proof one the compiler rejects');
	}

	/** The plain Bool-local shape, run from a scratch project whose oracle hxml carries `hxmlLine`. */
	private function runIn(hxmlLine: String): Array<Violation> {
		final src: String = 'package app; class C { function f(x:Null<Foo>) { final ok = x != null; if (ok) { var n = x?.bar; } } }';
		final dir: String = CliFixture.writeDir('dsnmacro', [
			{ name: 'apqlint.json', source: '{ "compilerOracle": "build.hxml" }' },
			{ name: 'build.hxml', source: '-cp .\n$hxmlLine\n' }
		]);
		final vs: Array<Violation> = new DeadSafeNav().run([{ file: '$dir/C.hx', source: src }], new HaxeQueryPlugin());
		CliFixture.removeDir(dir);
		return vs;
	}
	#end

}
