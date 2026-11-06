package unit.dev;

import dev.BaselineWarm;
import dev.PostLand;
import devkit.Summary.Outcome;
import devkit.TempDir;
import haxe.Exception;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/** `dev baseline-warm`: which gate runs a recipe makes, how a run follows the repository's tip, and the land step that starts it. */
final class BaselineWarmTest extends Test {

	public function testARecipeWithInfraTreesWarmsTheRuleCodeEntryFirstAndThePlainOneAfter(): Void {
		final recipe: WarmRecipe = { frozen: ['/pony'], infra: ['/a', '/b'] };
		Assert.same([
			['--frozen', '/pony', '--infra-tree', '/a', '--infra-tree', '/b'],
			['--frozen', '/pony']
		], BaselineWarm.variants(recipe));
	}

	public function testARecipeWithNoInfraTreesWarmsOnlyThePlainEntry(): Void {
		Assert.same([['--frozen', '/pony']], BaselineWarm.variants({ frozen: ['/pony'], infra: [] }));
	}

	public function testTheDetachedRunTakesItsLeaseFromThePoolAndCarriesTheRecipe(): Void {
		final argv: Array<String> = BaselineWarm.argvOf(Own('/plugin/scripts/wf-run', 8), '/cache/abc.dev.js', '/repo', 'abc', '/cache', {
			frozen: ['/pony'],
			infra: ['/a']
		});
		Assert.equals('/plugin/scripts/wf-run', argv[0]);
		Assert.isTrue(argv.contains('--threads'), argv.join(' '));
		final tail: Array<String> = argv.slice(argv.indexOf('--') + 1);
		Assert.same([
			'node',
			'/cache/abc.dev.js',
			'baseline-warm',
			'run',
			'abc',
			'--repo',
			'/repo',
			'--cache',
			'/cache',
			'--frozen=/pony',
			'--infra-tree=/a'
		], tail);
	}

	@:pin('control')
	@:killer('M-WARM-MOVED-KEEPS-GATE')
	public function testARunInFlightIsCancelledTheMomentTheTipMovesAndTheNextOneNeverStarts(): Void {
		final log: Array<String> = [];
		var asked: Int = 0;
		final outcome: Outcome = BaselineWarm.warm('a', [['one'], ['two']], () -> ++asked <= 2 ? 'a' : 'b', variant -> {
			log.push('begin ${variant[0]}');
			return running(log, variant[0], 100, Passed);
		}, () -> log.push('pause'));
		Assert.same(['begin one', 'pause', 'cancel one'], log);
		Assert.isTrue(outcome.match(Skipped(_)), Std.string(outcome));
	}

	public function testATipThatMovedBeforeAnyRunStartsStartsNone(): Void {
		final log: Array<String> = [];
		final outcome: Outcome = BaselineWarm.warm('a', [['one']], () -> 'b', variant -> {
			log.push('begin');
			return running(log, 'one', 0, Passed);
		}, () -> {});
		Assert.same([], log);
		Assert.isTrue(outcome.match(Skipped(_)), Std.string(outcome));
	}

	public function testEveryVariantRunsToItsEndWhileTheTipStays(): Void {
		final log: Array<String> = [];
		final outcome: Outcome = BaselineWarm.warm('a', [['one'], ['two']], () -> 'a', variant -> {
			log.push('begin ${variant[0]}');
			return running(log, variant[0], 2, Passed);
		}, () -> log.push('pause'));
		Assert.same(['begin one', 'pause', 'pause', 'begin two', 'pause', 'pause'], log);
		Assert.isTrue(outcome.match(Passed), Std.string(outcome));
	}

	public function testAFailedRunIsReportedAndDoesNotStopTheNextOne(): Void {
		final begun: Array<String> = [];
		final outcome: Outcome = BaselineWarm.warm('a', [['one'], ['two']], () -> 'a', variant -> {
			begun.push(variant[0]);
			return running([], variant[0], 0, variant[0] == 'one' ? Failed('suite red') : Failed('second'));
		}, () -> {});
		Assert.same(['one', 'two'], begun);
		Assert.isTrue(outcome.match(Failed('suite red')), Std.string(outcome));
	}

	public function testALandStepWithNoWarmRequestedIsSkipped(): Void {
		Assert.isTrue(BaselineWarm.afterwards(null, '/repo', 'abc', _ -> {}).match(Skipped(_)));
	}

	public function testALandStepNamesTheBackgroundRunItStarted(): Void {
		final notes: Array<String> = [];
		final started: Array<String> = [];
		final outcome: Outcome = BaselineWarm.afterwards((repo, sha) -> {
			started.push('$repo $sha');
			return Passed;
		}, '/repo', 'abc', notes.push);
		Assert.isTrue(outcome.match(Passed));
		Assert.same(['/repo abc'], started);
		Assert.equals(1, notes.length);
		Assert.stringContains('abc', notes[0]);
	}

	public function testALandStepWhoseWarmCannotStartIsSkippedWithTheCauseAndNeverFailed(): Void {
		final outcome: Outcome = BaselineWarm.afterwards((repo, sha) -> throw new Exception('no pool'), '/repo', 'abc', _ -> {});
		switch outcome {
			case Skipped(why):
				Assert.stringContains('no pool', why);
			case _:
				Assert.fail(Std.string(outcome));
		}
	}

	@:pin('control')
	@:killer('M-WARM-SETTLE-KEEPS-SCRIPT')
	public function testAFinishedRunLeavesNoScriptCopyWhateverItsVerdict(): Void {
		for (verdict in [Passed, Skipped('dropped'), Failed('suite red')]) TempDir.with(dir -> {
			final files: String = BaselineWarm.directory(dir.path);
			FileSystem.createDirectory(files);
			final script: String = PostLand.fileIn(files, 'abc', 'dev.js');
			File.saveContent(script, 'x');
			File.saveContent(PostLand.fileIn(files, 'abc', 'log'), 'x');
			BaselineWarm.settle(dir.path, 'abc', verdict);
			Assert.isFalse(FileSystem.exists(script), Std.string(verdict));
		});
	}

	public function testAFinishedRunKeepsItsLogOnlyWhenItFailed(): Void {
		for (verdict in [Passed, Skipped('dropped'), Failed('suite red')]) TempDir.with(dir -> {
			final files: String = BaselineWarm.directory(dir.path);
			FileSystem.createDirectory(files);
			final log: String = PostLand.fileIn(files, 'abc', 'log');
			File.saveContent(log, 'x');
			BaselineWarm.settle(dir.path, 'abc', verdict);
			Assert.equals(verdict.match(Failed(_)), FileSystem.exists(log), Std.string(verdict));
		});
	}

	/** A gate run that stays running for `ticks` polls and then ends with `result`; it logs its own cancellation. */
	private static function running(log: Array<String>, name: String, ticks: Int, result: Outcome): Warming {
		var left: Int = ticks;
		return {
			running: () -> left-- > 0,
			cancel: () -> log.push('cancel $name'),
			ended: () -> result
		};
	}

}
