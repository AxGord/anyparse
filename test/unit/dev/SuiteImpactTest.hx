package unit.dev;

import dev.ArmRegistry.ArmRecord;
import dev.SuiteImpact;
import utest.Assert;
import utest.Test;

/**
 * `SuiteImpact` over a small invented tree: the test classes a change reaches through the names its files spell, and the
 * touches that run every class.
 */
@:nullSafety(Strict)
final class SuiteImpactTest extends Test {

	/** A check rule, the registry naming it, the engine importing the registry, an unrelated module, and their tests. */
	private static final TREE: Array<ImpactSource> = [
		source('src/anyparse/check/common/naming/Rule.hx', 'package anyparse.check.common.naming;\nclass Rule {}'),
		source('src/anyparse/check/Registry.hx', 'package anyparse.check;\nimport anyparse.check.common.naming.Rule;\nclass Registry {}'),
		source('src/anyparse/query/Cli.hx', 'package anyparse.query;\nimport anyparse.check.Registry;\nclass Cli {}'),
		source('src/anyparse/query/Other.hx', 'package anyparse.query;\nclass Other {}'),
		source('test/unit/check/common/naming/RuleTest.hx', 'package unit.check.common.naming;\nimport anyparse.check.common.naming.Rule;'),
		source('test/unit/check/RegistryTest.hx', 'package unit.check;\nimport anyparse.check.Registry;'),
		source('test/unit/query/OtherTest.hx', 'package unit.query;\nimport anyparse.query.Other;'),
		source('test/unit/cli/EngineTest.hx', 'package unit.cli;\nclass EngineTest { function run() Sys.command(\'node bin/apq.js\'); }')
	];

	/** The engine's build, whose output runs the engine's main module, and the suite's, whose output runs the runner. */
	private static final ENTRIES: Map<String, String> = ['apq.js' => 'anyparse.query.Cli', 'test.js' => 'RunTests'];

	@:pin('control')
	@:killer('M-SUITE-IMPACT-NOTHING-REACHED')
	public function testACheckRuleReachesItsCategoryTestsAndEveryImporterDownToTheEngine(): Void {
		Assert.same(Selected([
			'unit.check.RegistryTest',
			'unit.check.common.naming.RuleTest',
			'unit.cli.EngineTest'
		]), SuiteImpact.scope(TREE, ENTRIES, ['src/anyparse/check/common/naming/Rule.hx']));
		Assert.same(Selected(['unit.query.OtherTest']), SuiteImpact.scope(TREE, ENTRIES, ['src/anyparse/query/Other.hx']));
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-MACRO-BOUNDED')
	@:killer('M-SUITE-IMPACT-RUNNER-BOUNDED')
	public function testAMacroTouchRunsEveryClass(): Void {
		for (path in [
			'src/anyparse/macro/Codegen.hx',
			'src/anyparse/runtime/Parser.hx',
			'src/anyparse/grammar/haxe/HxExpr.hx',
			'test/testkit/TestDiscovery.hx',
			'test-js.hxml',
			'apq.json',
			'test/RunTests.hx'
		]) Assert.isTrue(SuiteImpact.scope(TREE, ENTRIES, [path]).match(WholeSuite(_)), path);
		Assert.same(Selected([]), SuiteImpact.scope(TREE, ENTRIES, ['test/_Recon.hx']), 'a module beside the runner is not the runner');
		Assert.same(Selected([]), SuiteImpact.scope(TREE, ENTRIES, ['test/testkit/arms/dev.json']), 'a data file has readers that name it');
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-NOTHING-REACHED')
	public function testATestClassReachesTheTestsThatCallItAndNothingBelowTheTestLayer(): Void {
		final tree: Array<ImpactSource> = TREE.concat([
			source('test/unit/query/SiblingTest.hx', 'package unit.query;\n// after OtherTest\nclass SiblingTest {}'),
			source('test/unit/query/CallerTest.hx', 'package unit.query;\nclass CallerTest { final lock = OtherTest.MUTEX; }'),
			source('test/unit/query/deep/DeepTest.hx', 'package unit.query.deep;\nclass DeepTest { final lock = OtherTest.MUTEX; }'),
			source('test/unit/queryx/NearTest.hx', 'package unit.queryx;\nclass NearTest { final lock = OtherTest.MUTEX; }'),
			source(
				'src/anyparse/query/Plan.hx', 'package anyparse.query;\nclass Plan { static final STICKY = [\'unit.query.OtherTest\']; }'
			),
			source('test/unit/query/PlanTest.hx', 'package unit.query;\nimport anyparse.query.Plan;\nclass PlanTest {}')
		]);
		Assert.same(
			Selected(['unit.query.CallerTest', 'unit.query.OtherTest', 'unit.query.deep.DeepTest']),
			SuiteImpact.scope(tree, ENTRIES, ['test/unit/query/OtherTest.hx'])
		);
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-MACRO-DEPENDENT-BOUNDED')
	public function testAModuleAMacroDependsOnRunsEveryClass(): Void {
		final tree: Array<ImpactSource> = TREE.concat([
			source('src/anyparse/macro/Build.hx', 'package anyparse.macro;\nimport anyparse.query.Other;')
		]);
		switch SuiteImpact.scope(tree, ENTRIES, ['src/anyparse/query/Other.hx']) {
			case WholeSuite(why):
				Assert.stringContains('src/anyparse/macro/Build.hx', why);
			case Selected(classes):
				Assert.fail('selected ${classes.join(', ')}');
		}
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-NOTHING-REACHED')
	public function testASamePackageNameNeedsNoImportAndACommentIsNoUse(): Void {
		final tree: Array<ImpactSource> = TREE.concat([
			source('src/anyparse/query/Uses.hx', 'package anyparse.query;\nclass Uses { final o = new Other(); }'),
			source('src/anyparse/query/Docs.hx', 'package anyparse.query;\n/**\n * Unlike Other.\n */\nclass Docs {}'),
			source('test/unit/query/UsesTest.hx', 'package unit.query;\nimport anyparse.query.Uses;'),
			source('test/unit/query/DocsTest.hx', 'package unit.query;\nimport anyparse.query.Docs;')
		]);
		Assert.same(
			Selected(['unit.query.OtherTest', 'unit.query.UsesTest']), SuiteImpact.scope(tree, ENTRIES, ['src/anyparse/query/Other.hx'])
		);
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-NOTHING-REACHED')
	public function testAnAmbientImportReachesOnlyTheFilesBelowThatUseIt(): Void {
		final tree: Array<ImpactSource> = TREE.concat([
			source('test/unit/check/import.hx', 'import anyparse.check.Registry;'),
			source('test/unit/check/AmbientUserTest.hx', 'package unit.check;\nclass AmbientUserTest { final r = Registry; }'),
			source('test/unit/check/AmbientIdleTest.hx', 'package unit.check;\nclass AmbientIdleTest {}')
		]);
		Assert.same(
			Selected(['unit.check.AmbientUserTest', 'unit.check.RegistryTest', 'unit.cli.EngineTest']),
			SuiteImpact.scope(tree, ENTRIES, ['src/anyparse/check/Registry.hx'])
		);
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-NOTHING-REACHED')
	public function testALowerLayerNamingAHigherOnesModuleHoldsItAsData(): Void {
		final tree: Array<ImpactSource> = TREE.concat([
			source('tools/src/dev/Tool.hx', 'package dev;\nclass Tool {}'),
			source('src/anyparse/query/Help.hx', 'package anyparse.query;\nclass Help { final usage = \'see dev.Tool\'; }'),
			source('test/unit/query/HelpTest.hx', 'package unit.query;\nimport anyparse.query.Help;'),
			source('test/unit/dev/ToolTest.hx', 'package unit.dev;\nimport dev.Tool;')
		]);
		Assert.same(Selected(['unit.dev.ToolTest']), SuiteImpact.scope(tree, ENTRIES, ['tools/src/dev/Tool.hx']));
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-STATE-BLIND')
	public function testAHelperThatWritesTheEnvironmentRunsEveryClass(): Void {
		final putEnv: String = 'Sys.putEnv(\'HXQ_BIN\', null);';
		final tree: Array<ImpactSource> = TREE.concat([
			source('test/unit/dev/ArmHelper.hx', 'package unit.dev;\nclass ArmHelper { function f() $putEnv }'),
			source('test/unit/dev/PinsEnvTest.hx', 'package unit.dev;\nclass PinsEnvTest { function f() $putEnv }')
		]);
		Assert.isTrue(SuiteImpact.scope(tree, ENTRIES, ['test/unit/dev/ArmHelper.hx']).match(WholeSuite(_)));
		Assert.same(Selected(['unit.dev.PinsEnvTest']), SuiteImpact.scope(tree, ENTRIES, ['test/unit/dev/PinsEnvTest.hx']));
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-NOTHING-REACHED')
	public function testADataFileReachesTheFilesThatNameItsPath(): Void {
		final tree: Array<ImpactSource> = TREE.concat([
			source('test/unit/GuideTest.hx', 'package unit;\nclass GuideTest { final dir = \'docs/guide\'; }'),
			source('test/unit/DocsWordTest.hx', 'package unit;\nclass DocsWordTest { final dir = \'docs\'; final f = \'nametypes.md\'; }')
		]);
		Assert.same(Selected(['unit.GuideTest']), SuiteImpact.scope(tree, ENTRIES, ['docs/guide/lint/types.md']));
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-NOTHING-REACHED')
	public function testARemovedModuleReachesItsImporters(): Void {
		final tree: Array<ImpactSource> = TREE.filter(s -> s.path != 'src/anyparse/query/Other.hx');
		Assert.same(Selected(['unit.query.OtherTest']), SuiteImpact.scope(tree, ENTRIES, ['src/anyparse/query/Other.hx']));
	}

	@:pin('guard')
	public function testABuildNamesTheModuleItsOutputRuns(): Void {
		Assert.same(
			{ main: 'anyparse.query.Cli', output: 'bin/apq.js' },
			SuiteImpact.entryOf(['-cp', 'src', '-main', 'anyparse.query.Cli', '-D', 'x', '-js', 'bin/apq.js'])
		);
		Assert.isNull(SuiteImpact.entryOf(['-cp', 'src', '-main', 'anyparse.query.Cli']));
	}

	@:pin('guard')
	public function testOnlyACommentThatStartsALineIsDroppedAndAnUnclosedOneStays(): Void {
		Assert.equals('a;\nb; // c\n\n\td;', SuiteImpact.uncommented('a;\n// x\nb; // c\n/**\n * y\n */\n\td;'));
		Assert.equals('a;\n/* x\nb;', SuiteImpact.uncommented('a;\n/* x\nb;'));
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-UNPARSED-BOUNDED')
	public function testASourceThatDoesNotParseRunsEveryClass(): Void {
		final tree: Array<ImpactSource> = TREE.concat([
			source('src/anyparse/query/Broken.hx', 'package anyparse.query;\nclass Broken {')
		]);
		switch SuiteImpact.scope(tree, ENTRIES, ['src/anyparse/query/Other.hx']) {
			case WholeSuite(why):
				Assert.stringContains('src/anyparse/query/Broken.hx', why);
			case Selected(classes):
				Assert.fail('selected ${classes.join(', ')}');
		}
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-ARM-MISS-BLIND')
	public function testAPinnedClassOutsideTheReachOfTheArmsFileIsAMissAndOneInsideIsNot(): Void {
		final pinned: Map<String, String> = [
			'M-ARM' => 'unit.check.common.naming.RuleTest,unit.query.OtherTest',
			'M-OTHER' => 'unit.query.OtherTest'
		];
		final arms: Array<ArmRecord> = [
			arm('M-ARM', 'anyparse.check.common.naming.Rule'),
			arm('M-OTHER', 'anyparse.query.Other')
		];
		final reach: ArmReach = SuiteImpact.armMisses(TREE, ENTRIES, arms, pinned);
		Assert.same(['M-ARM src/anyparse/check/common/naming/Rule.hx unit.query.OtherTest'], reach.misses);
		Assert.equals(2, reach.files);
		Assert.equals(0, reach.whole);
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-ARM-WHOLE-MISSED')
	public function testAnArmWhoseFileRunsEveryClassMissesNone(): Void {
		final tree: Array<ImpactSource> = TREE.concat([
			source('src/anyparse/macro/Codegen.hx', 'package anyparse.macro;\nclass Codegen {}')
		]);
		final reach: ArmReach = SuiteImpact.armMisses(
			tree, ENTRIES,
			[arm('M-MACRO', 'anyparse.macro.Codegen')],
			['M-MACRO' => 'unit.query.OtherTest']
		);
		Assert.same([], reach.misses);
		Assert.equals(1, reach.whole);
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-ARM-MISS-BLIND')
	public function testAnArmWhoseTypeNoFileDeclaresNamesTheTypeAndAnArmWithoutPinsNothing(): Void {
		final arms: Array<ArmRecord> = [arm('M-GONE', 'anyparse.query.Gone'), arm('M-UNPINNED', 'anyparse.query.Other')];
		final reach: ArmReach = SuiteImpact.armMisses(TREE, ENTRIES, arms, ['M-GONE' => 'unit.query.OtherTest']);
		Assert.same(['M-GONE anyparse.query.Gone unit.query.OtherTest'], reach.misses);
		Assert.equals(0, reach.files, 'an unpinned arm\'s file is not scoped and an unlocated type adds none');
	}

	@:pin('control')
	@:killer('M-SUITE-IMPACT-GRAPH-LEAKS-BETWEEN-FILES')
	public function testOneGraphSharedAcrossArmsCarriesNoReachFromAnEarlierFileToALaterOne(): Void {
		final pinned: Map<String, String> = [
			'M-FIRST' => 'unit.check.common.naming.RuleTest',
			'M-SECOND' => 'unit.check.RegistryTest'
		];
		final arms: Array<ArmRecord> = [
			arm('M-FIRST', 'anyparse.check.common.naming.Rule'),
			arm('M-SECOND', 'anyparse.query.Other')
		];
		Assert.same(
			['M-SECOND src/anyparse/query/Other.hx unit.check.RegistryTest'], SuiteImpact.armMisses(TREE, ENTRIES, arms, pinned).misses
		);
	}

	private static function source(path: String, text: String): ImpactSource {
		return { path: path, text: text };
	}

	private static function arm(name: String, type: String): ArmRecord {
		return { key: name, text: '{"name":"$name","type":"$type","method":"run"}' };
	}

}
