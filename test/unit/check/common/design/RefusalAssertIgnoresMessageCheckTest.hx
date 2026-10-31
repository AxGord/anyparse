package unit.check.common.design;

import anyparse.check.LintConfig;
import anyparse.check.common.design.RefusalAssertIgnoresMessage;

/**
 * The `refusal-assert-ignores-message` check: a `case` arm over a declared refusal constructor that passes without
 * reading what the refusal carries is reported; an arm that reads its binder, fails, carries a guard or matches another
 * constructor is not, and nothing is read until the config names both lists.
 */
class RefusalAssertIgnoresMessageCheckTest extends Test {

	private static final CONFIG: String =
		'{"rules":{"refusal-assert-ignores-message":{"refusalConstructors":["Err"],"passCalls":["Assert.pass"]}}}';

	public function testAnArmPassingOnAnyRefusalIsReported(): Void {
		final vs: Array<Violation> = violationsOf('case Err(_):\n\t\t\t\tAssert.pass();');
		Assert.equals(1, vs.length);
		Assert.equals('refusal-assert-ignores-message', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('any Err') != -1, vs[0].message);
	}

	public function testAnUnreadBinderIsNoReading(): Void {
		Assert.equals(1, violationsOf('case Err(message):\n\t\t\t\tAssert.pass();').length);
	}

	@:pin('control')
	@:killer('M-REFUSAL-ASSERT-BINDER-READ-IGNORED')
	public function testAnArmReadingTheRefusalIsLeftAlone(): Void {
		Assert.equals(
			0,
			violationsOf('case Err(message):\n\t\t\t\tAssert.isTrue(message.indexOf(\'refused\') != -1);\n\t\t\t\tAssert.pass();').length
		);
	}

	@:pin('control')
	@:killer('M-REFUSAL-ASSERT-PASS-UNREQUIRED')
	public function testAnArmThatFailsIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('case Err(_):\n\t\t\t\tAssert.fail(\'expected Ok\');').length);
	}

	public function testAGuardedArmIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('case Err(_) if (strict):\n\t\t\t\tAssert.pass();').length);
	}

	public function testAnotherConstructorIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('case Done(_):\n\t\t\t\tAssert.pass();').length);
	}

	public function testNothingIsReadWithoutTheConfig(): Void {
		Assert.equals(0, violationsOf('case Err(_):\n\t\t\t\tAssert.pass();', '{}').length);
		Assert.equals('needs-config', new RefusalAssertIgnoresMessage().skipReason('T.hx', LintConfig.parse('{}')));
		Assert.isNull(new RefusalAssertIgnoresMessage().skipReason('T.hx', LintConfig.parse(CONFIG)));
	}

	/** A run mixing a refusal with another constructor is no refusal arm: every pattern of the run must be one. */
	public function testARunMixingAnotherConstructorIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('case Err(_), Done(_):\n\t\t\t\tAssert.pass();').length);
	}

	/** The findings over a helper whose switch carries an `Ok` arm and `arm`. */
	private function violationsOf(arm: String, ?config: String): Array<Violation> {
		final source: String = 'class T {\n\tvar strict:Bool = true;\n\n\tfunction check(r:R):Void {\n\t\tswitch r {\n\t\t\tcase Ok(_):\n'
			+ '\t\t\t\tAssert.fail(\'x\');\n\t\t\t$arm\n\t\t}\n\t}\n}\n';
		final text: String = config ?? CONFIG;
		return CheckFixture.violationsIn(
			new RefusalAssertIgnoresMessage(), [{ file: 'T.hx', source: source }], null, _ -> LintConfig.parse(text)
		);
	}

}
