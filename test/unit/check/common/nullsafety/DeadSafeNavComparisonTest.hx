package unit.check.common.nullsafety;

import anyparse.check.common.nullsafety.DeadSafeNav;
import unit.cli.CliFixture;

/**
 * `dead-safe-nav` and a `?.` comparison: `a?.f != null` does not narrow `a` for the compiler, so under null-safety the
 * `?.` of a later `a?.g` is not redundant to it and gets no finding.
 */
class DeadSafeNavComparisonTest extends Test {

	/** The reproduction: the `?.` comparison does not narrow `m` for the compiler, so the second `?.` is required. */
	@:pin('control')
	@:killer('M-DSN-UNSEEN-DROPPED')
	public function testSafeNavComparisonConjunctGetsNoFindingUnderNullSafety(): Void {
		Assert.equals(
			0, violations('@:nullSafety(Strict) class C { function f(m:Null<Foo>) { final r = m?.g != null && m?.p == true; } }').length
		);
	}

	/** A chain rooted at the receiver proves nothing either: `m?.a.b` and a call `m?.load()` leave `m` unnarrowed. */
	@:pin('control')
	@:killer('M-DSN-UNSEEN-DROPPED')
	public function testSafeNavChainComparisonGetsNoFindingUnderNullSafety(): Void {
		Assert.equals(
			0, violations('@:nullSafety(Strict) class C { function f(m:Null<Foo>) { final r = m?.a.b != null && m?.p; } }').length
		);
		Assert.equals(
			0, violations('@:nullSafety(Strict) class C { function f(m:Null<Foo>) { final r = m?.load() != null && m?.p; } }').length
		);
	}

	/** A plain `m != null` still narrows `m` for the compiler, so the later `m?.p` stays reported and fixable. */
	@:pin('control')
	@:killer('M-DSN-UNSEEN-ALL')
	public function testPlainGuardConjunctStillReportedUnderNullSafety(): Void {
		final src: String = '@:nullSafety(Strict) class C { function f(m:Null<Foo>) { final r = m != null && m?.p == true; } }';
		final check: DeadSafeNav = new DeadSafeNav();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length);
		Assert.equals(1, CheckFixture.fixOf(check, src, vs).length);
	}

	/** Without null-safety nothing typechecks the narrowing, and `m?.g != null` does imply `m != null` at run time. */
	@:pin('control')
	@:killer('M-DSN-NULLSAFE-ALWAYS')
	public function testSafeNavComparisonConjunctStillReportedWithoutNullSafety(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('dsncmp', [{ name: 'apq.json', source: '{}' }]);
		final src: String = 'class C { function f(m:Null<Foo>) { final r = m?.g != null && m?.p == true; } }';
		final vs: Array<Violation> = CheckFixture.violationsIn(new DeadSafeNav(), [{ file: '$dir/C.hx', source: src }]);
		CliFixture.removeDir(dir);
		Assert.equals(1, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new DeadSafeNav(), src);
	}

}
