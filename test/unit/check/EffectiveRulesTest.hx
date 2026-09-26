package unit.check;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.AvoidDynamic;
import anyparse.check.Check;
import anyparse.check.EffectiveRules;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * `EffectiveRules` — the rule state `apq lint --list-rules <scope>` prints, which a reviewer
 * subtracts a manual checklist by. Every case is a way the bare registry overstates what ran:
 * an ancestor config, `"inherit": false`, the project-root boundary, a default-off rule and the
 * `languageVersion` gate, plus the grouping that keeps two configs in one batch apart.
 */
@:nullSafety(Strict)
class EffectiveRulesTest extends Test {

	/** A default-on rule no fixture config mentions except where a case names it. */
	private static inline final PLAIN: String = 'unused-import';

	/** A default-off rule. */
	private static inline final OPT_IN: String = 'explicit-local-type';

	@:pin('control')
	@:killer('M-EFFECTIVE-IGNORES-CONFIG')
	@:killer('M-CHAIN-NEAREST-ONLY')
	public function testANestedConfigFoldsItsAncestors(): Void {
		#if (sys || nodejs)
		final root: String = project(
			'{"rules": {"$OPT_IN": {"enabled": true}, "magic-number": {"enabled": false}}}', '{"rules": {"$PLAIN": {"enabled": false}}}'
		);
		final group: RuleStateGroup = only('$root/nested/Probe.hx');
		Assert.same(['$root/nested/apqlint.json', '$root/apqlint.json'], group.chain, 'the chain is folded nearest first');
		assertState(group, OPT_IN, true, 'config');
		assertState(group, 'magic-number', false, 'config');
		assertState(group, PLAIN, false, 'config');
		assertState(group, 'dead-code', true, 'default');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-CHAIN-IGNORES-INHERIT')
	public function testInheritFalseEndsTheChain(): Void {
		#if (sys || nodejs)
		final root: String = project('{"rules": {"magic-number": {"enabled": false}}}', '{"inherit": false, "rules": {}}');
		final group: RuleStateGroup = only('$root/nested/Probe.hx');
		Assert.same(['$root/nested/apqlint.json'], group.chain, 'the ancestor is not folded');
		assertState(group, 'magic-number', true, 'default');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-CHAIN-UNBOUNDED')
	public function testTheChainStopsAtTheProjectRoot(): Void {
		#if (sys || nodejs)
		// The outer document sits ABOVE a directory holding `.git`, so it belongs to no project
		// the file is in: a lint never folds it, and neither may the listing.
		final root: String = project('{"rules": {"magic-number": {"enabled": false}}}', null);
		FileSystem.createDirectory('$root/nested/.git');
		final group: RuleStateGroup = only('$root/nested/Probe.hx');
		Assert.same([], group.chain, 'nothing is folded past the project root');
		assertState(group, 'magic-number', true, 'default');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-EFFECTIVE-IGNORES-DEFAULT-OFF')
	public function testADefaultOffRuleRunsOnlyWhereAConfigEnablesIt(): Void {
		#if (sys || nodejs)
		final root: String = project('{"rules": {}}', '{"rules": {"$OPT_IN": {"enabled": true}}}');
		File.saveContent('$root/Top.hx', 'class Top {}\n');
		assertState(only('$root/Top.hx'), OPT_IN, false, 'default-off');
		assertState(only('$root/nested/Probe.hx'), OPT_IN, true, 'config');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-EFFECTIVE-IGNORES-VERSION')
	public function testALanguageVersionBelowTheFixDropsTheRule(): Void {
		#if (sys || nodejs)
		final gated: Null<Check> = Linter.builtins().find(c -> c is VersionGated && !(c is DefaultOff));
		if (gated == null) {
			Assert.fail('the registry carries a default-on version-gated rule');
			return;
		}
		final check: Check = gated;
		final minimum: String = (cast check: VersionGated).minLanguageVersion();
		final root: String = project('{"languageVersion": "1.0"}', null);
		assertState(only('$root/nested/Probe.hx'), check.id(), false, 'needs-language-$minimum');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-EFFECTIVE-GROUPS-PER-DIR')
	public function testFilesGroupByChainNotByDirectory(): Void {
		#if (sys || nodejs)
		final root: String = project('{"rules": {}}', '{"rules": {"$PLAIN": {"enabled": false}}}');
		FileSystem.createDirectory('$root/other');
		File.saveContent('$root/Top.hx', 'class Top {}\n');
		File.saveContent('$root/other/Side.hx', 'class Side {}\n');
		final groups: Array<RuleStateGroup> = EffectiveRules.resolve(
			['$root/Top.hx', '$root/nested/Probe.hx', '$root/other/Side.hx'], Linter.builtins()
		);
		Assert.equals(2, groups.length, 'two chains, however many directories');
		Assert.same(['$root/Top.hx', '$root/other/Side.hx'], groups[0].files, 'directories sharing a chain share a group');
		Assert.same(['$root/nested/Probe.hx'], groups[1].files, 'the nested chain is its own group');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTheCliListsWithAndWithoutAScope(): Void {
		#if (sys || nodejs)
		final root: String = project('{"rules": {}}', null);
		Assert.equals(0, Cli.run(['lint', '--list-rules', '$root/nested/Probe.hx']), 'a scope lists effective state and exits 0');
		Assert.equals(1, Cli.run(['lint', '--list-rules', '$root/nested/Missing.hx']), 'a scope with no .hx is a runtime error');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-GATE-TS-SINKS-BLIND')
	@:killer('M-EFFECTIVE-IGNORES-FILEGATE')
	public function testARuleWithNothingToLookForIsOff(): Void {
		#if (sys || nodejs)
		final root: String = project('{"rules": {}}', null);
		assertState(only('$root/nested/Probe.hx'), 'thread-safety', false, 'needs-config');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-GATE-TS-EXCLUDE-BLIND')
	@:killer('M-GATE-AD-EXCLUDE-BLIND')
	public function testAPathARuleExcludesIsOffForThatFileOnly(): Void {
		#if (sys || nodejs)
		final root: String = project(
			'{"rules": {"thread-safety": {"sinks": ["Sys.sleep"], "exclude": ["nested"]}, "avoid-dynamic": {"excludePaths": ["nested/"]}}}',
			null
		);
		File.saveContent('$root/Top.hx', 'class Top {}\n');
		final groups: Array<RuleStateGroup> = EffectiveRules.resolve(['$root/Top.hx', '$root/nested/Probe.hx'], Linter.builtins());
		Assert.equals(2, groups.length, 'one chain, two rule states: two groups');
		assertState(groups[0], 'thread-safety', true, 'default');
		assertState(groups[0], 'avoid-dynamic', true, 'default');
		assertState(groups[1], 'thread-safety', false, 'config-excluded');
		assertState(groups[1], 'avoid-dynamic', false, 'config-excluded');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-GATE-NOOP-DOC')
	@:killer('M-GATE-NOOP-UNDERSCORE')
	public function testOptionsThatSwitchEveryFindingOffAreANoop(): Void {
		#if (sys || nodejs)
		final root: String = project(
			'{"rules": {"doc-coverage": {"requireTypeDoc": false, "requireMemberDoc": false},'
			+ ' "no-underscore-prefix": {"enabled": true, "params": false, "locals": false}}}',
			null
		);
		final group: RuleStateGroup = only('$root/nested/Probe.hx');
		assertState(group, 'doc-coverage', false, 'config-noop');
		assertState(group, 'no-underscore-prefix', false, 'config-noop');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The listing and the run answer from one predicate: a file the listing reports off yields no finding. */
	@:pin('control')
	@:killer('M-GATE-COLLECT-BYPASS')
	public function testTheRunSkipsWhatTheListingReportsOff(): Void {
		final config: LintConfig = LintConfig.parse('{"rules": {"avoid-dynamic": {"excludePaths": ["gen/"]}}}');
		final source: String = 'class C {\n\tvar x:Dynamic;\n}\n';
		final files: Array<{ file: String, source: String }> = [{ file: 'gen/C.hx', source: source }, { file: 'app/C.hx', source: source }];
		final found: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), [new AvoidDynamic()], _ -> config, true);
		Assert.same(['app/C.hx'], [for (v in found) v.file], 'only the file the listing reports on is scanned');
		Assert.isFalse(EffectiveRules.stateOf(new AvoidDynamic(), 'gen/C.hx', config).on, 'and the listing reports the other off');
	}

	@:pin('control')
	@:killer('M-EFFECTIVE-RENDER-HEADER')
	public function testTheListingOpensWithTheHeaderToolingDetects(): Void {
		final group: RuleStateGroup = {
			chain: ['/p/apqlint.json'],
			files: ['/p/A.hx'],
			rules: [
				{
					id: 'dead-code',
					on: true,
					reason: 'default',
					description: 'd'
				},
				{
					id: 'explicit-local-type',
					on: false,
					reason: 'default-off',
					description: 'e'
				}
			]
		};
		Assert.equals(
			'=== effective lint rules — config chain: /p/apqlint.json ===\nfile: /p/A.hx\ndead-code            on   default      d\n'
			+ 'explicit-local-type  off  default-off  e\n',
			EffectiveRules.render([group])
		);
	}

	public function testLintRunFlagsAreRefusedWithTheListing(): Void {
		#if (sys || nodejs)
		final root: String = project('{"rules": {}}', null);
		for (flag in [['--rule', 'dead-code'], ['--fix'], ['--all']])
			Assert.equals(
				2, Cli.run(['lint', '--list-rules'].concat(flag).concat(['$root/nested/Probe.hx'])), '${flag[0]} is a usage error'
			);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A fixture project: `rootConfig` at its root (a `.git` marks it), `nestedConfig` (if any) and a `Probe.hx` under `nested/`. */
	private function project(rootConfig: String, nestedConfig: Null<String>): String {
		final root: String = CliFixture.writeDir('effrules', [{ name: 'apqlint.json', source: rootConfig }]);
		FileSystem.createDirectory('$root/.git');
		FileSystem.createDirectory('$root/nested');
		if (nestedConfig != null) File.saveContent('$root/nested/apqlint.json', nestedConfig);
		File.saveContent('$root/nested/Probe.hx', 'class Probe {}\n');
		return root;
	}

	/** The one group a single file resolves to. */
	private function only(file: String): RuleStateGroup {
		final groups: Array<RuleStateGroup> = EffectiveRules.resolve([file], Linter.builtins());
		Assert.equals(1, groups.length, 'one file resolves to one group');
		return groups[0];
	}

	private function assertState(group: RuleStateGroup, id: String, on: Bool, reason: String): Void {
		final state: Null<RuleState> = group.rules.find(r -> r.id == id);
		if (state == null) {
			Assert.fail('"$id" is listed');
			return;
		}
		Assert.equals(on, state.on, '"$id" is ${on ? 'on' : 'off'}');
		Assert.equals(reason, state.reason, '"$id" is decided by $reason');
	}

}
