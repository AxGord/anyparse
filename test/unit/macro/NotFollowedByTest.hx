package unit.macro;

/** `@:notFollowedBy` keeps a Pratt operator from matching when a longer token starting with it follows. */
class NotFollowedByTest extends Test {

	@:pin('control')
	@:killer('M-PRATT-NOT-FOLLOWED-BY-IGNORED')
	public function testOperatorLeavesTheLongerTokenAlone(): Void {
		final wrap: NotFollowedByWrap = NotFollowedByWrapParser.parse('a && b');
		Assert.equals('b', (wrap.rest: String));
		switch wrap.type {
			case Named(name):
				Assert.equals('a', (name: String));
			case _:
				Assert.fail('expected a bare name before `&&`');
		}
	}

	public function testOperatorStillMatchesAlone(): Void {
		final wrap: NotFollowedByWrap = NotFollowedByWrapParser.parse('a & b && c');
		switch wrap.type {
			case Both(Named(l), Named(r)):
				Assert.equals('a', (l: String));
				Assert.equals('b', (r: String));
			case _:
				Assert.fail('expected `a & b`');
		}
		Assert.equals('c', (wrap.rest: String));
	}

}
