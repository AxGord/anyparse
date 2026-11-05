package unit;

import utest.Assert;
import utest.Test;

/**
 * The kit's registry reads: a rule that leaves `Linter.builtins()` is no longer registered, and the id list the rule
 * tests share no longer holds it.
 */
@:nullSafety(Strict)
final class CheckFixtureTest extends Test {

	@:pin('control')
	@:killer('M-REGISTRY-DROPS-A-RULE')
	public function testARegisteredRuleIsReadAndAnAbsentOneIsNot(): Void {
		Assert.isTrue(CheckFixture.isRegistered('unused-import'));
		Assert.contains('unused-import', CheckFixture.builtinIds());
		Assert.isFalse(CheckFixture.isRegistered('no-such-rule'));
		CheckFixture.assertRegistered('unused-import');
	}

}
