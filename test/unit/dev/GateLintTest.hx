package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import dev.GateLint;
import devkit.RawJson;
import devkit.Summary.Outcome;
import utest.Assert;
import utest.Test;

/** `dev.GateLint`: a moved file's findings at the base are filed under the path the lint row compares them at. */
@:nullSafety(Strict)
final class GateLintTest extends Test {

	@:pin('control')
	@:killer('M-GATE-REBASE-NONE')
	public function testAMovedFilesBaseFindingsTakeItsNewPath(): Void {
		final report: String = '[{"file":"old/C.hx","rule":"r"},{"file":"a/B.hx","rule":"r"}]';
		final records: JValue = JValueParser.parse(GateLint.rebased(report, ['old/C.hx' => 'new/C.hx', 'a/B.hx' => 'a/B.hx']));
		Assert.same(['new/C.hx', 'a/B.hx'], RawJson.items(records).map(RawJson.stringAt.bind(_, 'file')));
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

}
