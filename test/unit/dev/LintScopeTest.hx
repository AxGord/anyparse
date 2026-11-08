package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.util.Compare;
import dev.LintScope;
import devkit.RawJson;
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

	@:pin('control')
	@:killer('M-LINTSCOPE-CARRIED-KEEPS-UNMARKED-RULE')
	public function testTheCarriedReportKeepsTheBasesFindingsOfTheFilesOutsideTheScope(): Void {
		final base: String = report([['a.hx', 'old'], ['b.hx', 'kept'], ['gone.hx', 'dropped']]);
		final carried: Null<String> = LintScope.carried(base, report([['a.hx', 'new']]), ['a.hx'], file -> file != 'gone.hx', []);
		Assert.same(findings(report([['b.hx', 'kept'], ['a.hx', 'new']])), findings(carried ?? ''));
	}

	@:pin('control')
	@:killer('M-LINTSCOPE-CARRIED-LOSES-FAILED-LINT')
	public function testAFreshLintThatPrintedNoReportIsAnsweredAsItIs(): Void {
		Assert.equals('boom', LintScope.carried(report([]), 'boom', ['a.hx'], _ -> true, []));
		Assert.isNull(LintScope.carried('boom', report([]), ['a.hx'], _ -> true, []));
	}

	@:pin('guard')
	public function testAWholeTreeLintIsKeptAsItIs(): Void {
		Assert.equals(
			report([['a.hx', 'r']]), LintScope.whole(null, ['a.hx'], report([['a.hx', 'r']]), _ -> true, () -> 'not asked').report
		);
		Assert.equals(
			report([['a.hx', 'r']]), LintScope.whole('base.json', null, report([['a.hx', 'r']]), _ -> true, () -> 'not asked').report
		);
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
		Assert.isNull(LintScope.backstop({
			added: 0,
			removed: 0,
			first: '',
			rows: []
		}));
		final refusal: String = LintScope.backstop({
			added: 1,
			removed: 1,
			first: '+ c.hx  doc-length  m',
			rows: ['+ c.hx  doc-length  m', '- b.hx  unused-import  m']
		}) ?? '';
		Assert.isTrue(refusal.contains('moved 2 finding'), refusal);
		Assert.isTrue(refusal.contains('- b.hx  unused-import'), refusal);
		Assert.isTrue(refusal.contains('+ c.hx  doc-length'), refusal);
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

	@:pin('control')
	@:killer('M-LINTSCOPE-CARRIED-DROPS-NARROW-RULE')
	public function testAScopeDependentRuleKeepsTheBasesFindingsOfARelintedFile(): Void {
		final base: String = report([['a.hx', 'blind'], ['a.hx', 'plain'], ['b.hx', 'plain']]);
		final carried: Null<String> = LintScope.carried(base, report([['a.hx', 'plain']]), ['a.hx'], _ -> true, ['blind']);
		Assert.same(findings(base), findings(carried ?? ''));
	}

	@:pin('control')
	@:killer('M-LINTSCOPE-CARRIED-KEEPS-UNMARKED-RULE')
	public function testAnUnmarkedRuleOfARelintedFileIsStillReplaced(): Void {
		final carried: Null<String> = LintScope.carried(
			report([['a.hx', 'plain'], ['a.hx', 'blind']]), report([['a.hx', 'other']]), ['a.hx'], _ -> true, ['blind']
		);
		Assert.same(findings(report([['a.hx', 'blind'], ['a.hx', 'other']])), findings(carried ?? ''));
	}

	@:pin('control')
	@:killer('M-LINTSCOPE-CARRIED-KEEPS-DELETED-FILE')
	public function testADeletedFileLosesItsScopeDependentFindings(): Void {
		final carried: Null<String> = LintScope.carried(report([['gone.hx', 'blind']]), report([]), ['gone.hx'], _ -> false, ['blind']);
		Assert.same([], findings(carried ?? ''));
	}

	/** The shape of the land the backstop refused: the scoped lint is blind to a marked rule's findings in files it re-lints. */
	@:pin('control')
	@:killer('M-LINTSCOPE-CARRIED-DROPS-NARROW-RULE')
	public function testAReportCarriedOverAScopeBlindRuleHoldsTheWholeLintsFindings(): Void {
		final truth: String = report([
			['t.hx', 'unused-return-value'],
			['t.hx', 'naming'],
			['import.hx', 'hoist-common-import'],
			['u.hx', 'naming']
		]);
		final carried: Null<String> = LintScope.carried(
			truth, report([['t.hx', 'naming']]), ['t.hx', 'import.hx'], _ -> true, ['unused-return-value', 'hoist-common-import']
		);
		Assert.same(findings(truth), findings(carried ?? ''));
	}

	@:pin('control')
	@:killer('M-LINTSCOPE-LISTING-IGNORES-MARKER')
	public function testTheScopeDependentRulesAreReadFromTheEnginesListing(): Void {
		final listing: String = '[{"id":"a","scopeDependent":true},{"id":"b","scopeDependent":false},{"id":"c"}]';
		Assert.same(['a'], LintScope.scopeDependent(listing));
		Assert.isNull(LintScope.scopeDependent('no listing'));
	}

	@:pin('guard')
	public function testAScopedRunThatCannotReadTheListingSaysSo(): Void {
		final refused: WholeReport = LintScope.whole('base.json', ['a.hx'], report([]), _ -> true, () -> 'boom');
		Assert.isNull(refused.report);
		Assert.isTrue(refused.why?.contains('rule listing') ?? false);
	}

	@:pin('control')
	@:killer('M-LINTSCOPE-CARRIED-DOUBLES-NARROW-RULE')
	public function testAScopeDependentRulesFreshFindingDoesNotDoubleTheBases(): Void {
		final base: String = report([['a.hx', 'blind']]);
		final carried: Null<String> = LintScope.carried(base, report([['a.hx', 'blind']]), ['a.hx'], _ -> true, ['blind']);
		Assert.same(findings(base), findings(carried ?? ''));
	}

	@:pin('control')
	@:killer('M-LINTSCOPE-JUDGED-KEEPS-CARRIED')
	public function testTheJudgedReportLeavesOutACarriedRuleOnARelintedFile(): Void {
		Assert.same(
			findings(report([['b.hx', 'blind']])),
			findings(LintScope.judged(report([['a.hx', 'blind'], ['b.hx', 'blind']]), ['a.hx'], ['blind']))
		);
	}

	@:pin('control')
	@:killer('M-LINTSCOPE-JUDGED-DROPS-UNMARKED-RULE')
	public function testTheJudgedReportKeepsAnUnmarkedRuleOnARelintedFile(): Void {
		Assert.same(findings(report([['a.hx', 'plain']])), findings(LintScope.judged(report([['a.hx', 'plain']]), ['a.hx'], ['blind'])));
	}

	@:pin('control')
	@:killer('M-LINTSCOPE-JUDGED-DROPS-OUTSIDE-SCOPE')
	public function testTheJudgedReportKeepsACarriedRuleOutsideTheScope(): Void {
		Assert.same(findings(report([['b.hx', 'blind']])), findings(LintScope.judged(report([['b.hx', 'blind']]), ['a.hx'], ['blind'])));
	}

	@:pin('control')
	@:killer('M-LINTSCOPE-JUDGED-BLANKS-MALFORMED')
	public function testAJudgedTextThatIsNoReportIsLeftAsItIs(): Void {
		Assert.equals('boom', LintScope.judged('boom', ['a.hx'], ['blind']));
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

	/**
	 * The `<file> <rule>` of each finding of report `text`, sorted.
	 */
	private static function findings(text: String): Array<String> {
		final records: Array<JValue> = switch JValueParser.parse(text) {
			case JArray(items): items;
			case _: [];
		}
		final rows: Array<String> = records.map(record -> '${RawJson.stringAt(record, 'file')} ${RawJson.stringAt(record, 'rule')}');
		rows.sort(Compare.compareString);
		return rows;
	}

}
