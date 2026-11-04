package unit.check.common.design;

import anyparse.check.LintConfig;
import anyparse.check.common.design.GuardPinArmReach;
import anyparse.query.Cli;
import unit.cli.CliFixture;

using StringTools;

/**
 * The `guard-pin-arm-reach` check: a guard-pinned test naming both the type and the member an arm of its class cuts is
 * reported; an arm the guard names as its own killer and a same-named member of another type are not; what the registry
 * cannot use is a finding of its own. The registry is resolved by absolute path and beside the config that names it.
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
			{ name: 'apq.json', source: config },
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

	/** A record that lacks its `method` is named with the field, and a registry that is no JSON is named, neither with a throw. */
	public function testAMalformedRegistryIsAFindingNamingTheArmAndTheField(): Void {
		final noMethod: String = '{"arms": [{"name": "M-ONE", "type": "pkg.Widget", "force": "0", "note": "the widget stops"}]}';
		final badArm: Array<Violation> = violationsOf('@:pin(\'guard\')', 'Widget.spin();', noMethod);
		Assert.equals(1, badArm.length);
		Assert.equals('WidgetTest.hx', badArm[0].file);
		Assert.isNull(badArm[0].span);
		Assert.isTrue(badArm[0].message.contains('arm #1 "M-ONE": "method" is not a string'), badArm[0].message);
		final noJson: Array<Violation> = violationsOf('@:pin(\'guard\')', 'Widget.spin();', 'arms: [ M-ONE ]');
		Assert.equals(1, noJson.length);
		Assert.isTrue(noJson[0].message.contains('arms.json is not JSON: '), noJson[0].message);
	}

	/** One bad record costs only itself: the arm beside it still reports, in every file, and the problem is reported once per run. */
	public function testABadRecordLeavesTheOtherArmsApplying(): Void {
		final dir: String = CliFixture.writeTree('guardpin', [
			{
				name: 'arms.json',
				source: '{"arms": [{"name": "M-BAD", "type": "pkg.Widget", "method": 1},'
				+ ' {"name": "M-ONE", "type": "pkg.Widget", "method": "spin"}]}'
			}
		]);
		final config: String = configNaming('$dir/arms.json');
		final source: String = fixture('@:pin(\'guard\')', 'Widget.spin();');
		final vs: Array<Violation> = CheckFixture.violationsIn(new GuardPinArmReach(), [
			{ file: 'WidgetTest.hx', source: source },
			{ file: 'OtherTest.hx', source: source }
		], null, _ -> LintConfig.parse(config));
		CliFixture.removeDir(dir);
		Assert.same(['WidgetTest.hx', 'WidgetTest.hx', 'OtherTest.hx'], vs.map(v -> v.file));
		Assert.isTrue(vs[0].message.contains('arm #1 "M-BAD": "method" is not a string'), vs[0].message);
		Assert.isTrue(vs[1].message.contains('M-ONE'), vs[1].message);
		Assert.isTrue(vs[2].message.contains('M-ONE'), vs[2].message);
	}

	/** Through the linter's own gates, which read a finding's config by its file: a default-off rule keeps the finding under `--all`. */
	public function testTheFindingSurvivesTheEnablementGate(): Void {
		final dir: String = CliFixture.writeTree('guardpin', [
			{
				name: 'apq.json',
				source: '{"rules":{"guard-pin-arm-reach":{"enabled":true,"pinMeta":"@:pin","guardArgument":"guard","killerMeta":"@:killer",'
				+ '"armRegistry":"arms.json"}}}'
			},
			{ name: 'arms.json', source: '{"arms": [{"name": "M-BAD", "type": "pkg.Widget"}]}' },
			{ name: 'src/WidgetTest.hx', source: fixture('@:pin(\'guard\')', 'Widget.spin();') }
		]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			final printed: String = CliFixture.captureStdout(() -> Cli.run(['lint', '$dir/src', '--all', '--no-oracle']));
			Assert.isTrue(printed.contains('arm #1 "M-BAD": "method" is not a string'), printed);
		});
	}

	/** A registry named as a DIRECTORY is every document in it, and one unreadable document is a finding that costs only itself. */
	public function testARegistryDirectoryIsReadDocumentByDocument(): Void {
		final other: String =
			'{"arms": [{"name": "M-TWO", "type": "pkg.Gadget", "method": "turn", "force": "0", "note": "the gadget stops"}]}';
		final dir: String = CliFixture.writeTree('guardpin', [
			{ name: 'arms/a-other.json', source: other },
			{ name: 'arms/b-widget.json', source: ARMS },
			{ name: 'arms/notes.txt', source: 'not a document' }
		]);
		final config: String = configNaming('$dir/arms');
		final vs: Array<Violation> = CheckFixture.violationsIn(
			new GuardPinArmReach(),
			[{ file: 'WidgetTest.hx', source: fixture('@:pin(\'guard\')', 'Widget.spin();') }],
			null, _ -> LintConfig.parse(config)
		);
		CliFixture.removeDir(dir);
		Assert.equals(1, vs.length, 'the arm of the second document is found');
		final broken: String = CliFixture.writeTree('guardpin', [
			{ name: 'arms/a-other.json', source: 'arms: [' },
			{ name: 'arms/b-widget.json', source: ARMS }
		]);
		final brokenConfig: String = configNaming('$broken/arms');
		final kept: Array<Violation> = CheckFixture.violationsIn(
			new GuardPinArmReach(),
			[{ file: 'WidgetTest.hx', source: fixture('@:pin(\'guard\')', 'Widget.spin();') }],
			null, _ -> LintConfig.parse(brokenConfig)
		);
		CliFixture.removeDir(broken);
		Assert.equals(2, kept.length, 'the other document still applies');
		Assert.isTrue(kept[0].message.contains('a-other.json is not JSON: '), kept[0].message);
		Assert.isTrue(kept[1].message.contains('M-ONE'), kept[1].message);
	}

	/**
	 * A document the file system will not hand over is a finding that costs
	 * only itself; a directory named like a document is one on every platform.
	 */
	public function testADocumentThatCannotBeReadIsAFinding(): Void {
		final dir: String = CliFixture.writeTree('guardpin', [
			{ name: 'arms/a.json', source: ARMS },
			{ name: 'arms/b.json/inner.txt', source: 'a directory, not a document' }
		]);
		final config: String = configNaming('$dir/arms');
		final vs: Array<Violation> = CheckFixture.violationsIn(
			new GuardPinArmReach(),
			[{ file: 'WidgetTest.hx', source: fixture('@:pin(\'guard\')', 'Widget.spin();') }],
			null, _ -> LintConfig.parse(config)
		);
		CliFixture.removeDir(dir);
		Assert.equals(2, vs.length, 'the finding and the arm of the other document');
		Assert.isTrue(vs[0].message.startsWith('arm registry $dir/arms/b.json cannot be read: '), vs[0].message);
		Assert.isTrue(vs[1].message.contains('M-ONE'), vs[1].message);
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
