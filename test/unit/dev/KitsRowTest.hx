package unit.dev;

import dev.KitsRow;
import dev.Probe.KitsReport;
import devkit.Summary;
import devkit.TempDir;
import utest.Assert;
import utest.Test;

/** `dev.KitsRow`: the text a failed kit run leaves for the worker, and the skip of a tree that holds no kit. */
@:nullSafety(Strict)
final class KitsRowTest extends Test {

	public function testAFailureNamesTheCommandThatRecordsEachFailedArea(): Void {
		final text: String = KitsRow.failure(report(['move', 'cli'], ['[move] DEVIATES #3 a: hxq b', '  exit: 0 → 1']));
		Assert.stringContains('2 row(s) in move, cli;', text);
		Assert.stringContains('node bin/dev.js probe move --record --compile; node bin/dev.js probe cli --record --compile', text);
		Assert.stringContains('[move] DEVIATES #3 a: hxq b', text);
		Assert.equals(-1, text.indexOf('<area>'), 'no placeholder is left for the reader to fill');
		Assert.equals(-1, text.indexOf('knownDefect'), 'nothing moved that was known');
	}

	public function testAMovedKnownDefectRowAlsoTellsToDeleteItsField(): Void {
		final text: String = KitsRow.failure(
			report(['move'], ['[move] KNOWN-DEFECT ROW MOVED (maybe fixed) #1 k: refuses', '  exit: 1 → 0'])
		);
		Assert.stringContains('delete the knownDefect field', text);
		Assert.stringContains('probe move --record --compile', text);
	}

	public function testATreeWithoutKitsSkipsTheRow(): Void {
		TempDir.with(dir -> {
			final outcome: Outcome = KitsRow.outcome(dir.file(''), new Summary(), _ -> Assert.fail('nothing to show'));
			Assert.isTrue(outcome.match(Skipped(_)), '$outcome');
		});
	}

	/** The kits row can only move when the engine they probe or a kit moved. */
	@:pin('guard')
	public function testTheKitsRowIsReachedByTheEngineOrAKit(): Void {
		Assert.isTrue(KitsRow.reached(['docs/a.md', 'src/anyparse/core/A.hx']));
		Assert.isTrue(KitsRow.reached(['apq.json']));
		Assert.isTrue(KitsRow.reached(['bin/apq']), 'the launch shim runs every kit invocation');
		Assert.isTrue(KitsRow.reached(['bin/hxq']));
		Assert.isTrue(KitsRow.reached(['test/probes/cli/kit.json']));
		Assert.isFalse(KitsRow.reached(['test/unit/dev/A.hx', 'tools/src/dev/A.hx', 'docs/a.md', 'test/probesx/a.json']));
		Assert.isFalse(KitsRow.reached([]));
	}

	private static function report(failed: Array<String>, lines: Array<String>): KitsReport {
		return {
			areas: 5,
			invocations: 100,
			failing: failed.length,
			failed: failed,
			lines: lines
		};
	}

}
