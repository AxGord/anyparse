package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import dev.BaseLint;
import dev.GateLint;
import dev.LintScope;
import devkit.Lease;
import devkit.Summary.Outcome;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `dev.GateLint`: a moved file's findings at the base are filed under the path the lint row compares them at, and the row lints every
 * module an `import.hx` above a touched file governs.
 */
@:nullSafety(Strict)
final class GateLintTest extends Test {

	private static final TREE: Map<String, Array<String>> = [
		'test/unit/check' => ['test/unit/check/import.hx', 'test/unit/check/ATest.hx'],
		'test/unit/check/common/imports' => [
			'test/unit/check/common/imports/import.hx',
			'test/unit/check/common/imports/XTest.hx'
		],
		'test/unit/check/scan' => ['test/unit/check/scan/STest.hx'],
		'test/unit/query' => ['test/unit/query/QTest.hx']
	];

	@:pin('control')
	@:killer('M-GATE-REBASE-NONE')
	public function testAMovedFilesBaseFindingsTakeItsNewPath(): Void {
		final report: String = '[{"file":"old/C.hx","rule":"r"},{"file":"a/B.hx","rule":"r"}]';
		final records: JValue = JValueParser.parse(GateLint.rebased(report, ['old/C.hx' => 'new/C.hx', 'a/B.hx' => 'a/B.hx']));
		Assert.same(['new/C.hx', 'a/B.hx'], JValueTools.items(records).map(JValueTools.stringAt.bind(_, 'file')));
	}

	public function testAReportWithNothingMovedIsAnsweredAsItIs(): Void {
		final report: String = '[{"file":"a/B.hx"}]';
		Assert.equals(report, GateLint.rebased(report, ['a/B.hx' => 'a/B.hx']));
	}

	public function testALintOfATreeWithoutAProjectAsksNoOracle(): Void {
		Assert.same(['lint', 'src', '--all', '--format', 'json'], GateLint.lintArgs(['src'], true));
		Assert.same(['lint', '.', '--all', '--format', 'json', '--no-oracle'], GateLint.lintArgs(['.'], false));
	}

	public function testALintOfNamedRulesRunsOnlyThose(): Void {
		Assert.same(
			['lint', 'src', '--all', '--format', 'json', '--rule', 'a', '--rule', 'b'], GateLint.lintArgs(['src'], true, ['a', 'b'])
		);
	}

	public function testARebasedRecordKeepsEveryOtherKeyAndSpellsAWholeNumberWithoutAFraction(): Void {
		final report: String = '[{"file":"old/C.hx","line":12,"data":{"a":[1,2.5]},"rule":"r"}]';
		Assert.equals(
			'[\n  {\n    "file": "new/C.hx",\n    "line": 12,\n    "data": {\n      "a": [\n        1,\n        2.5\n      ]\n    },\n'
			+ '    "rule": "r"\n  }\n]',
			GateLint.rebased(report, ['old/C.hx' => 'new/C.hx'])
		);
	}

	@:pin('guard')
	public function testAScopedComparisonThatPassesIsTheVerdictAndAnyOtherIsDecidedByTheWholeTree(): Void {
		var wholeRuns: Int = 0;
		final whole: () -> Outcome = () -> {
			wholeRuns++;
			return Failed('whole');
		};
		Assert.isTrue(GateLint.settle(() -> Passed, whole).match(Passed));
		Assert.equals(0, wholeRuns);
		Assert.isTrue(GateLint.settle(() -> Failed('scoped'), whole).match(Failed('whole')));
		Assert.isTrue(GateLint.settle(() -> NotRun('scoped'), whole).match(Failed('whole')));
		Assert.isTrue(GateLint.settle(null, whole).match(Failed('whole')));
		Assert.equals(3, wholeRuns);
	}

	@:pin('guard')
	public function testAReportOfSomeRulesIsNeverCachedUnderTheWholeTreesKey(): Void {
		final whole: Null<String> = GateLint.keyOf('engine', 'base', ['src']);
		final some: Null<String> = GateLint.keyOf('engine', 'base', ['src'], ['a']);
		Assert.notEquals(whole, some);
		Assert.notEquals(some, GateLint.keyOf('engine', 'base', ['src'], ['a', 'b']));
		Assert.equals(some, GateLint.keyOf('engine', 'base', ['src'], ['a']));
		Assert.isNull(GateLint.keyOf(null, 'base', ['src'], ['a']));
	}

	@:pin('control')
	@:killer('M-GATE-REJECTED-IN-NONE')
	public function testTheRejectedConfigurationsAreReadFromTheLintsStandardError(): Void {
		final stderr: String = [
			'apq lint: compiler oracle unavailable for gone.hxml — no haxe (skipped)',
			'apq lint: compiler oracle REJECTED tools/fixture-cache.hxml -D js — build does not typecheck:',
			'src/A.hx:3: characters 1-2 : Type not found',
			'apq lint: compiler oracle REJECTED build.hxml — build does not typecheck:',
			'apq lint: compiler oracle REJECTED build.hxml — build does not typecheck:'
		].join('\n');
		Assert.same(['tools/fixture-cache.hxml -D js', 'build.hxml'], GateLint.rejectedIn(stderr, []));
		Assert.same([], GateLint.rejectedIn('apq lint: compiler-confirmed\n', []));
	}

	@:pin('control')
	@:killer('M-GATE-REJECTION-NONE')
	public function testOnlyAConfigurationTheTipRejectsAndTheBaseAcceptsIsNew(): Void {
		Assert.same(['b.hxml'], GateLint.newRejections(['a.hxml', 'b.hxml'], ['a.hxml']));
		Assert.same([], GateLint.newRejections(['a.hxml'], ['a.hxml', 'b.hxml']));
		Assert.same([], GateLint.newRejections([], ['a.hxml']));
	}

	@:pin('control')
	@:killer('M-GATE-REJECTION-PASSES')
	public function testTheLintRowFailsNamingAConfigurationOnlyTheTipRejects(): Void {
		Assert.isTrue(GateLint.rejection(['a.hxml'], ['a.hxml'], 'tip.err').match(Passed));
		Assert.isTrue(GateLint.rejection([], [], 'tip.err').match(Passed));
		switch GateLint.rejection(['a.hxml', 'tools/b.hxml'], ['a.hxml'], 'tip.err') {
			case Failed(why):
				Assert.stringContains('tools/b.hxml', why);
				Assert.stringContains('tip.err', why);
			case other:
				Assert.fail('expected a failure, got $other');
		}
	}

	@:pin('control')
	@:killer('M-GATE-REJECTION-ROOT-BLIND')
	public function testAConfigurationBothTreesRejectIsTheSameUnderTheirDifferentRoots(): Void {
		final tip: String = 'apq lint: compiler oracle REJECTED /w/tip/tools/fixture-cache.hxml — build does not typecheck:\n';
		final base: String =
			'apq lint: compiler oracle REJECTED /private/var/T/base/tools/fixture-cache.hxml — build does not typecheck:\n';
		final tipRejected: Array<String> = GateLint.rejectedIn(tip, ['/w/tip']);
		final baseRejected: Array<String> = GateLint.rejectedIn(base, ['/var/T/base', '/private/var/T/base']);
		Assert.same(['tools/fixture-cache.hxml'], tipRejected);
		Assert.isTrue(GateLint.rejection(tipRejected, baseRejected, 'tip.err').match(Passed));
		final broken: String = '${tip}apq lint: compiler oracle REJECTED /w/tip/tools/other.hxml -D js — build does not typecheck:\n';
		switch GateLint.rejection(GateLint.rejectedIn(broken, ['/w/tip']), baseRejected, 'tip.err') {
			case Failed(why):
				Assert.stringContains('tools/other.hxml -D js', why);
				Assert.isFalse(why.indexOf('/w/tip') >= 0);
			case other:
				Assert.fail('expected a failure, got $other');
		}
		Assert.same(
			['/elsewhere/x.hxml'],
			GateLint.rejectedIn('apq lint: compiler oracle REJECTED /elsewhere/x.hxml — build does not typecheck:\n', ['/w/tip'])
		);
	}

	@:pin('control')
	@:killer('M-GATE-REBASE-MESSAGE-OLD')
	public function testAMessageNamingAMovedModuleReadsItsNewName(): Void {
		final report: String = '[{"file":"src/a/old/C.hx","message":"x.C belongs to a.old.C, a.old.CTest and a.old.C.Sub","rule":"r"}]';
		final moves: Map<String, String> = ['src/a/old/C.hx' => 'src/a/new/C.hx'];
		Assert.same(
			['x.C belongs to a.new.C, a.old.CTest and a.new.C.Sub'],
			JValueTools.items(JValueParser.parse(GateLint.rebased(report, moves))).map(JValueTools.stringAt.bind(_, 'message'))
		);
	}

	@:pin('control')
	@:killer('M-GATE-LINT-CORES-ONE')
	public function testTheLintBranchesLeaseTheNodeEnginesCpusAndTheOthersOne(): Void {
		Assert.equals(Lease.NODE_CORES, GateLint.coresOf(['lint']));
		Assert.equals(Lease.NODE_CORES, GateLint.coresOf([BaseLint.ROW]));
		Assert.equals(1, GateLint.coresOf(['jvm']));
		Assert.equals(1, GateLint.coresOf(['suite', 'corpus']));
	}

	@:pin('control')
	@:killer('M-LINT-SCOPE-GOVERNED-SIBLINGS-ONLY')
	public function testAChangeUnderANestedFolderLintsTheGoverningImportHxsWholeSet(): Void {
		final scope: Array<String> = LintScope.ofChange(['test/unit/check/common/imports/XTest.hx'], filesIn, below) ?? [];
		Assert.contains('test/unit/check/import.hx', scope);
		Assert.contains('test/unit/check/ATest.hx', scope);
		Assert.contains('test/unit/check/scan/STest.hx', scope);
		Assert.contains('test/unit/check/common/imports/import.hx', scope);
		Assert.notContains('test/unit/query/QTest.hx', scope);
	}

	@:pin('control')
	@:killer('M-LINT-SCOPE-TREE-BELOW-BLIND')
	public function testTheLintRowAddsEveryModuleBelowTheGoverningImportHxFromDisk(): Void {
		withTree([
			'test/a/import.hx',
			'test/a/A.hx',
			'test/a/b/B.hx',
			'test/a/b/c/C.hx',
			'test/x/X.hx'
		], root -> {
			Assert.same(
				['test/a/b/c/C.hx', 'test/a/A.hx', 'test/a/b/B.hx', 'test/a/import.hx'],
				GateLint.lintedFiles(root, ['test/a/b/c/C.hx'], same)
			);
		});
	}

	@:pin('control')
	@:killer('M-LINT-ROW-NULL-WHEN-LINT-INPUT')
	public function testAChangeUnderSrcLintsTheModulesItsImportHxGoverns(): Void {
		withTree(['src/a/import.hx', 'src/a/A.hx', 'src/a/b/X.hx', 'src/z/Z.hx'], root -> {
			Assert.same(['src/a/b/X.hx', 'src/a/A.hx', 'src/a/import.hx'], GateLint.lintedFiles(root, ['src/a/b/X.hx'], same));
		});
	}

	@:pin('control')
	@:killer('M-LINT-ROW-TOUCHED-ONLY')
	public function testASourceAndATestChangeWidenBothSides(): Void {
		withTree([
			'src/a/import.hx',
			'src/a/b/X.hx',
			'test/t/import.hx',
			'test/t/V.hx',
			'test/t/u/T.hx'
		], root -> {
			Assert.same([
				'src/a/b/X.hx',
				'test/t/u/T.hx',
				'src/a/import.hx',
				'test/t/V.hx',
				'test/t/import.hx'
			], GateLint.lintedFiles(root, ['src/a/b/X.hx', 'test/t/u/T.hx'], same));
		});
	}

	@:pin('control')
	@:killer('M-LINT-ROW-BASE-PATHS-DROPPED')
	public function testAMovedFilesOldFolderGovernsToo(): Void {
		withTree(['test/old/import.hx', 'test/old/Y.hx', 'test/old/deep/Z.hx', 'test/new/X.hx'], root -> {
			final files: Array<String> = GateLint.lintedFiles(
				root, ['test/new/X.hx'], path -> path == 'test/new/X.hx' ? 'test/old/X.hx' : path
			);
			Assert.same(['test/new/X.hx', 'test/old/Y.hx', 'test/old/deep/Z.hx', 'test/old/import.hx'], files);
		});
	}

	private static function filesIn(dir: String): Array<String> {
		return TREE[dir] ?? [];
	}

	private static function below(dir: String): Array<String> {
		return [
			for (folder => files in TREE) if (folder == dir || folder.startsWith('$dir/')) for (file in files) file
		];
	}

	private static function same(path: String): String {
		return path;
	}

	private static function withTree(files: Array<String>, body: String -> Void): Void {
		devkit.TempDir.with(dir -> {
			for (file in files) {
				final path: String = dir.file(file);
				FileSystem.createDirectory(Path.directory(path));
				File.saveContent(path, '');
			}
			body(dir.path);
		});
	}

}
