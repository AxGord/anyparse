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

	/**
	 * Without null-safety nothing typechecks the narrowing, so a Bool-local proof still gets its runtime-sound fix — in a
	 * project with no oracle build to read, since a build this check cannot rule out counts as enabling it.
	 */
	@:pin('control') @:killer('M-DSN-NULLSAFE-ALWAYS')
	public function testBoolLocalProofKeepsTheFixWithoutNullSafety(): Void {
		assertBuild([], false, '{}');
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
		assertBuild([{ name: 'build.hxml', source: '-cp .\n--macro nullSafety(\'\', Strict)\n' }], true);
	}

	/** A build of nothing but class paths, defines, a main class and a target cannot enable null-safety: the fix stays. */
	@:pin('control') @:killer('M-DSN-HXML-ALWAYS-ON')
	public function testPlainOracleBuildKeepsTheFix(): Void {
		assertBuild([
			{ name: 'build.hxml', source: '-cp .\n-D flag\n-main app.C\napp.C\n--js out.js\n' }
		], false);
	}

	/** A commented-out macro is not part of the build. */
	@:pin('control') @:killer('M-DSN-HXML-ALWAYS-ON', 'M-DSN-HXML-COMMENT-READ')
	public function testCommentedMacroKeepsTheFix(): Void {
		assertBuild([{ name: 'build.hxml', source: '-cp .\n#--macro nullSafety(\'\')\n' }], false);
	}

	/** `addGlobalMetadata` with `@:nullSafety` enables it as surely as the `nullSafety` macro does. */
	@:pin('control') @:killer('M-DSN-MACRO-BLIND')
	public function testGlobalMetadataMacroKeepsNoFix(): Void {
		assertBuild([
			{ name: 'build.hxml', source: '-cp .\n--macro addGlobalMetadata(\'app\', \'@:nullSafety(Strict)\')\n' }
		], true);
	}

	/** A `-lib`'s extraParams are not read, so it may enable null-safety. */
	@:pin('control') @:killer('M-DSN-MACRO-BLIND', 'M-DSN-HXML-LIB-PLAIN')
	public function testUnreadLibraryKeepsNoFix(): Void {
		assertBuild([{ name: 'build.hxml', source: '-cp .\n-lib somelib\n' }], true);
	}

	/** An hxml the oracle's hxml includes is read too. */
	@:pin('control') @:killer('M-DSN-HXML-INCLUDE-SKIPPED')
	public function testIncludedHxmlIsRead(): Void {
		assertBuild([
			{ name: 'build.hxml', source: '-cp .\ncommon.hxml\n' },
			{ name: 'common.hxml', source: '--macro nullSafety(\'\')\n' }
		], true);
	}

	/** An oracle hxml that cannot be read — not generated yet — cannot rule null-safety out. */
	@:pin('control') @:killer('M-DSN-HXML-UNREADABLE-PLAIN')
	public function testUnreadableOracleHxmlKeepsNoFix(): Void {
		assertBuild([], true);
	}

	/** A proof made inside a `try` does not survive it for the compiler, even with the catch exiting. */
	@:pin('control') @:killer('M-DSN-TRY-KEEPS-ALL')
	public function testTryProofKeepsNoFix(): Void {
		assertDeclined(nullSafe('try { x = new Foo(); } catch (e:Dynamic) { return; } var n = x?.bar;'));
		assertDeclined(nullSafe('try { if (x == null) return; } catch (e:Dynamic) { return; } var n = x?.bar;'));
	}

	/** A proof made before a `try` that writes nothing survives it. */
	@:pin('control') @:killer('M-DSN-TRY-HIDES-ALL')
	public function testProofBeforeTryKeepsTheFix(): Void {
		assertFixed(nullSafe('if (x == null) return; try { g(); } catch (e:Dynamic) { return; } var n = x?.bar;'));
	}

	/** Past a lone surviving `if` arm the compiler keeps nothing the arm's BODY proved. */
	@:pin('control') @:killer('M-DSN-LONE-ARM-KEEPS-BODY')
	public function testLoneArmBodyProofKeepsNoFix(): Void {
		assertDeclined(nullSafe('if (b) { x = new Foo(); } else return; var n = x?.bar;'));
		assertDeclined(nullSafe('if (!b) return; else { if (x == null) return; } var n = x?.bar;'));
	}

	/** Past a lone surviving `if` arm the condition's own narrowing still holds. */
	@:pin('control') @:killer('M-DSN-LONE-ARM-HIDES-ALL')
	public function testLoneArmConditionProofKeepsTheFix(): Void {
		assertFixed(nullSafe('if (x == null || b) { return; } else { g(); } var n = x?.bar;'));
	}

	/** Two live `if` arms that each prove the name visibly join into a visible proof. */
	@:pin('control') @:killer('M-DSN-JOIN-HIDES-ALL')
	public function testTwoLiveArmsKeepTheFix(): Void {
		assertFixed(nullSafe('if (b) { if (x == null) return; } else { if (x == null) return; } var n = x?.bar;'));
	}

	/** A lone live `switch` branch is the lone `if` arm again. */
	@:pin('control') @:killer('M-DSN-LONE-BRANCH-KEEPS-BODY')
	public function testLoneSwitchBranchProofKeepsNoFix(): Void {
		assertDeclined(nullSafe('switch k { case 0: if (x == null) return; case _: return; } var n = x?.bar;'));
	}

	/** Two live `switch` branches that each prove the name visibly join into a visible proof. */
	@:pin('control') @:killer('M-DSN-JOIN-HIDES-ALL')
	public function testTwoLiveSwitchBranchesKeepTheFix(): Void {
		assertFixed(nullSafe('switch k { case 0: x = new Foo(); case _: x = new Foo(); } var n = x?.bar;'));
	}

	/** An assignment nested in a call argument is evaluated in order, and the compiler follows it. */
	@:pin('control') @:killer('M-DSN-OWNS-NONE')
	public function testAssignmentInsideACallKeepsTheFix(): Void {
		assertFixed(nullSafe('g(x = new Foo()); var n = x?.bar;'));
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

	/** The plain Bool-local shape, run from a scratch project configured by `config` (an oracle `build.hxml` among `files`). */
	private function assertBuild(
		files: Array<{ name: String, source: String }>, declined: Bool, config: String = '{ "compilerOracle": "build.hxml" }'
	): Void {
		#if (sys || nodejs)
		final src: String = 'package app; class C { function f(x:Null<Foo>) { final ok = x != null; if (ok) { var n = x?.bar; } } }';
		final dir: String = CliFixture.writeDir('dsnbuild', [{ name: 'apqlint.json', source: config }].concat(files));
		final vs: Array<Violation> = new DeadSafeNav().run([{ file: '$dir/C.hx', source: src }], new HaxeQueryPlugin());
		CliFixture.removeDir(dir);
		Assert.equals(1, vs.length);
		Assert.equals(declined, vs[0].declineReason != null, declined ? 'the build may enable null-safety' : 'the build is plain');
		#else
		Assert.pass('non-sys target');
		#end
	}

	private function violations(src: String): Array<Violation> {
		return new DeadSafeNav().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** `body` as the body of a strictly null-safe method over a nullable `x`, a Bool `b` and an Int `k`. */
	private static function nullSafe(body: String): String {
		return '@:nullSafety(Strict) class C { function f(x:Null<Foo>, b:Bool, k:Int) { $body } }';
	}

}
