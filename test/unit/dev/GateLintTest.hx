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
		Assert.same(['new/C.hx', 'a/B.hx'], [for (r in RawJson.items(records)) RawJson.stringAt(r, 'file')]);
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

}
