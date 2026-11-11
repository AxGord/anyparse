package unit.check.scan;

import anyparse.check.common.members.InlineConstant;

/**
 * A demand position keeps `inline` only on the constant it names: a qualifier or the enclosing type resolves the
 * spelled name to its declaration, and an unresolved qualifier stays conservative.
 */
class ConstantDemandByNameTest extends Test {

	private static final L_DECL: String = "package pkg;\nclass L {\n\tpublic static inline final GET: String = 'get';\n"
		+ '\tpublic static function f(x: String): Bool return x == GET;\n}';
	private static final M_DECL: String = "package pkg;\nclass M {\n\tpublic static final GET: String = 'g';\n}";

	@:pin('control')
	@:killer('M-DEMAND-QUALIFIER-NAMES-ITS-TYPE')
	public function testForeignQualifiedDefaultDoesNotHoldIt(): Void {
		Assert.equals(1, flaggedInL('package pkg;\nclass U { static function f(m: String = M.GET) {} }'));
	}

	@:pin('control')
	@:killer('M-DEMAND-QUALIFIER-OWN-HOLDS')
	public function testOwnQualifiedDefaultHoldsIt(): Void {
		Assert.equals(0, flaggedInL('package pkg;\nclass U { static function f(m: String = L.GET) {} }'));
	}

	@:pin('control')
	@:killer('M-DEMAND-BARE-OWN-HOLDS')
	public function testBareDefaultInsideOwnTypeHoldsIt(): Void {
		Assert.equals(
			0,
			flagged(
				"package pkg;\nclass L {\n\tpublic static inline final GET: String = 'get';\n"
				+ '\tpublic static function f(x: String = GET): Bool return x == GET;\n}',
				'package pkg;\nclass U {}'
			)
		);
	}

	@:pin('control')
	@:killer('M-DEMAND-BARE-OTHER-OWN-MEMBER')
	public function testBareDefaultInsideAnotherTypeWithItsOwnDoesNotHoldIt(): Void {
		Assert.equals(
			1,
			flagged(
				L_DECL, "package pkg;\nclass M {\n\tpublic static final GET: String = 'g';\n\tstatic function f(m: String = GET) {}\n}",
				false
			)
		);
	}

	@:pin('control')
	@:killer('M-DEMAND-QUALIFIER-UNKNOWN-HOLDS')
	public function testUnresolvedQualifierHoldsIt(): Void {
		Assert.equals(0, flaggedInL('package pkg;\nclass U { static function f(m: String = X.GET) {} }'));
	}

	private function flaggedInL(user: String): Int {
		return flagged(L_DECL, user);
	}

	private function flagged(l: String, user: String, withM: Bool = true): Int {
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/L.hx', source: l }, { file: 'pkg/U.hx', source: user }];
		if (withM) files.push({ file: 'pkg/M.hx', source: M_DECL });
		return CheckFixture.violationsIn(new InlineConstant(), files).filter(v -> v.file == 'pkg/L.hx').length;
	}

}
