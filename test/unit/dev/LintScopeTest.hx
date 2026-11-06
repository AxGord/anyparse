package unit.dev;

import dev.LintScope;
import utest.Assert;
import utest.Test;

using StringTools;

/** `dev.LintScope`: the files a landing re-lints and the report it keeps, the whole lint's check of that carrying. */
@:nullSafety(Strict)
final class LintScopeTest extends Test {

	private static final TREE: Map<String, Array<String>> = [
		'test' => ['test/import.hx', 'test/RunTests.hx'],
		'test/unit' => ['test/unit/import.hx'],
		'test/unit/dev' => ['test/unit/dev/ATest.hx', 'test/unit/dev/BTest.hx'],
		'test/unit/other' => ['test/unit/other/CTest.hx'],
		'src/anyparse' => ['src/anyparse/import.hx']
	];

	@:pin('guard')
	public function testATestLandLintsItsFolderAndTheImportsAboveIt(): Void {
		Assert.same([
			'test/import.hx',
			'test/unit/dev/ATest.hx',
			'test/unit/dev/BTest.hx',
			'test/unit/import.hx'
		], LintScope.ofChange(['test/unit/dev/ATest.hx', 'docs/testing.md'], filesIn, below));
	}

	@:pin('guard')
	public function testADeletedFileStillLintsItsFolder(): Void {
		final scope: Null<Array<String>> = LintScope.ofChange(['test/unit/dev/Gone.hx'], filesIn, below);
		Assert.contains('test/unit/dev/BTest.hx', scope ?? []);
		Assert.notContains('test/unit/other/CTest.hx', scope ?? []);
	}

	@:pin('guard')
	public function testAToolsOnlyLandLintsNothing(): Void {
		Assert.same([], LintScope.ofChange(['tools/src/dev/Battery.hx', 'docs/testing.md', 'tools/data/x.json'], filesIn, below));
	}

	@:pin('guard')
	public function testAnEngineInputOrALintConfigLintsTheWholeTree(): Void {
		for (path in [
			'src/anyparse/query/Cli.hx',
			'apq.json',
			'bin/apq-js.hxml',
			'apqlint.json',
			'test/apq.json',
			'test/fixtures/apqlint.json',
			'test-js-common.hxml',
			'tools/dev.hxml',
			'hxformat.json',
			'tools/hxformat.json',
			'haxelib.json'
		]) Assert.isNull(LintScope.ofChange(['test/unit/dev/ATest.hx', path], filesIn, below), path);
	}

	@:pin('guard')
	public function testTheCarriedReportKeepsTheBasesFindingsOfTheFilesOutsideTheScope(): Void {
		final base: String = report([['a.hx', 'old'], ['b.hx', 'kept'], ['gone.hx', 'dropped']]);
		final carried: Null<String> = LintScope.carried(base, report([['a.hx', 'new']]), ['a.hx'], file -> file != 'gone.hx');
		Assert.same([], LintScope.moved(carried ?? '', report([['b.hx', 'kept'], ['a.hx', 'new']])));
	}

	@:pin('guard')
	public function testAFreshLintThatPrintedNoReportIsAnsweredAsItIs(): Void {
		Assert.equals('boom', LintScope.carried(report([]), 'boom', ['a.hx'], _ -> true));
		Assert.isNull(LintScope.carried('boom', report([]), ['a.hx'], _ -> true));
	}

	@:pin('guard')
	public function testAWholeTreeLintIsKeptAsItIs(): Void {
		Assert.equals(report([['a.hx', 'r']]), LintScope.whole(null, ['a.hx'], report([['a.hx', 'r']]), _ -> true));
		Assert.equals(report([['a.hx', 'r']]), LintScope.whole('base.json', null, report([['a.hx', 'r']]), _ -> true));
	}

	@:pin('guard')
	public function testAnEmptyScopeHasNoLintToRun(): Void {
		Assert.isNull(LintScope.lintArgs([]));
		Assert.same(['lint', '--format', 'json', '--all', 'a.hx'], LintScope.lintArgs(['a.hx']));
		Assert.same(['lint', '--format', 'json', '--all'].concat(LintScope.ROOTS), LintScope.lintArgs(null));
	}

	@:pin('guard')
	public function testOnlyAnImpactRunWithABaseIsScoped(): Void {
		Assert.isNull(LintScope.ofImpact('.', 'abc', false));
		Assert.isNull(LintScope.ofImpact('.', null, true));
	}

	@:pin('guard')
	public function testTheBackstopNamesAFindingThatMovedOutsideTheScope(): Void {
		final recorded: String = report([['a.hx', 'r'], ['b.hx', 'unused-import']]);
		Assert.isNull(LintScope.backstop(recorded, report([['b.hx', 'unused-import'], ['a.hx', 'r']])));
		final refusal: String = LintScope.backstop(recorded, report([['a.hx', 'r'], ['c.hx', 'doc-length']])) ?? '';
		Assert.isTrue(refusal.contains('- b.hx unused-import'), refusal);
		Assert.isTrue(refusal.contains('+ c.hx doc-length'), refusal);
	}

	@:pin('guard')
	public function testASecondFindingOfTheSameRecordIsAMovement(): Void {
		Assert.same(['+ a.hx r'], LintScope.moved(report([['a.hx', 'r']]), report([['a.hx', 'r'], ['a.hx', 'r']])));
	}

	@:pin('guard')
	public function testAChangedImportHxLintsEveryFolderBelowIt(): Void {
		final scope: Array<String> = LintScope.ofChange(['test/unit/import.hx'], filesIn, below) ?? [];
		Assert.contains('test/unit/dev/ATest.hx', scope);
		Assert.contains('test/unit/other/CTest.hx', scope);
		Assert.contains('test/unit/import.hx', scope);
		Assert.contains('test/import.hx', scope);
		Assert.notContains('test/RunTests.hx', scope);
	}

	private static function filesIn(dir: String): Array<String> {
		return TREE[dir] ?? [];
	}

	private static function report(records: Array<Array<String>>): String {
		return '[' + records.map(r -> '{"file":"${r[0]}","rule":"${r[1]}","line":1}').join(',') + ']';
	}

	private static function below(dir: String): Array<String> {
		return [
			for (folder => files in TREE) if (folder == dir || folder.startsWith('$dir/')) for (file in files) file
		];
	}

}
