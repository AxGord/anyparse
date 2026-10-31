package unit.check.common.design;

import anyparse.check.LintConfig;
import anyparse.check.common.design.GuardPinArmReach;
import unit.cli.CliFixture;

/**
 * The `guard-pin-arm-reach` check: a guard-pinned test naming both the type and the member an arm of its class cuts is
 * reported; an arm the guard names as its own killer, a same-named member of another type and an unread registry are
 * not. The registry is resolved by absolute path and beside the config that names it.
 */
class GuardPinArmReachCheckTest extends Test {

	private static final ARMS: String =
		'{"arms": [{"name": "M-ONE", "type": "pkg.Widget", "method": "spin", "force": "0", "note": "the widget stops"}]}';

	public function testAGuardCallingTheCutMemberIsReported(): Void {
		final vs: Array<Violation> = violationsOf('@:pin(\'guard\')', 'Widget.spin();');
		Assert.equals(1, vs.length);
		Assert.equals('guard-pin-arm-reach', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('M-ONE') != -1, vs[0].message);
	}

	@:pin('control')
	@:killer('M-GUARD-PIN-OWN-KILLER-COUNTED')
	public function testAGuardNamingTheArmItselfIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('@:pin(\'guard\')\n\t@:killer(\'M-ONE\')', 'Widget.spin();').length);
	}

	@:pin('control')
	@:killer('M-GUARD-PIN-TYPE-UNREAD')
	public function testASameNamedMemberOfAnotherTypeIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('@:pin(\'guard\')', 'Gadget.spin();').length);
	}

	public function testAControlPinIsLeftAlone(): Void {
		Assert.equals(0, violationsOf('@:pin(\'control\')\n\t@:killer(\'M-ONE\')', 'Widget.spin();').length);
	}

	public function testARelativeRegistryResolvesBesideTheConfigThatNamesIt(): Void {
		final config: String = configNaming('arms.json');
		final dir: String = CliFixture.writeTree('guardpin', [
			{ name: 'apqlint.json', source: config },
			{ name: 'arms.json', source: ARMS }
		]);
		final vs: Array<Violation> = CheckFixture.violationsIn(new GuardPinArmReach(), [
			{ file: '$dir/WidgetTest.hx', source: fixture('@:pin(\'guard\')', 'Widget.spin();') }
		], null, _ -> LintConfig.parse(config));
		CliFixture.removeDir(dir);
		Assert.equals(1, vs.length);
	}

	public function testAMissingRegistryReadsNothing(): Void {
		final vs: Array<Violation> = CheckFixture.violationsIn(
			new GuardPinArmReach(),
			[{ file: 'WidgetTest.hx', source: fixture('@:pin(\'guard\')', 'Widget.spin();') }],
			null, _ -> LintConfig.parse(configNaming('/no/such/dir/arms.json'))
		);
		Assert.equals(0, vs.length);
		Assert.equals('needs-config', new GuardPinArmReach().skipReason('T.hx', LintConfig.parse('{}')));
	}

	/** A record that lacks its `method`, and a registry that is no JSON, are dropped without a finding or a throw. */
	public function testAMalformedRegistryReadsNothing(): Void {
		final noMethod: String = '{"arms": [{"name": "M-ONE", "type": "pkg.Widget", "force": "0", "note": "the widget stops"}]}';
		Assert.equals(0, violationsOf('@:pin(\'guard\')', 'Widget.spin();', noMethod).length);
		Assert.equals(0, violationsOf('@:pin(\'guard\')', 'Widget.spin();', 'arms: [ M-ONE ]').length);
	}

	/** A config naming the pin spellings and `registry`. */
	private function configNaming(registry: String): String {
		return '{"rules":{"guard-pin-arm-reach":{"pinMeta":"@:pin","guardArgument":"guard","killerMeta":"@:killer",'
			+ '"armRegistry":"$registry"}}}';
	}

	/** A test class whose killed control names `M-ONE` and whose second test carries `metas` and calls `call`. */
	private function fixture(metas: String, call: String): String {
		return
			'class WidgetTest {\n\t@:pin(\'control\')\n\t@:killer(\'M-ONE\')\n\tfunction testKilled():Void {\n\t\tWidget.spin();\n\t}\n\n'
				+ '\t$metas\n\tfunction testOther():Void {\n\t\t$call\n\t}\n}\n';
	}

	/**
	 * The findings over `fixture(metas, call)` with `registry` (default
	 * `ARMS`) written to a scratch directory and named by its absolute path.
	 */
	private function violationsOf(metas: String, call: String, ?registry: String): Array<Violation> {
		final dir: String = CliFixture.writeTree('guardpin', [{ name: 'arms.json', source: registry ?? ARMS }]);
		final config: String = configNaming('$dir/arms.json');
		final vs: Array<Violation> = CheckFixture.violationsIn(
			new GuardPinArmReach(),
			[{ file: 'WidgetTest.hx', source: fixture(metas, call) }],
			null, _ -> LintConfig.parse(config)
		);
		CliFixture.removeDir(dir);
		return vs;
	}

}
