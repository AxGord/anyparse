package unit.dev;

import anyparse.core.TempScratch;
import dev.TrapFixSweep;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/** `dev trap-fix-sweep`'s verdict of one probe, which verdicts fail the sweep, and one probe swept end to end. */
@:nullSafety(Strict)
final class TrapFixSweepTest extends Test {

	@:pin('control')
	@:killer('M-SWEEP-FIX-RESULT-IGNORED')
	public function testAFailedEngineRunIsAnErrorThatFailsTheSweep(): Void {
		Assert.equals('ERROR', TrapFixSweep.verdictOf(true, true, false, false, false), 'a lint --fix that did not exit 0');
		Assert.isTrue(TrapFixSweep.fails('ERROR'), 'it fails the sweep');
	}

	/** The run the fix is compared with is taken after the formatter, so the formatter is checked against the text as written. */
	@:pin('control')
	@:killer('M-SWEEP-FORMAT-UNCHECKED')
	public function testAFormatThatChangedTheProgramFailsTheSweep(): Void {
		Assert.equals('FORMAT-CHANGED', TrapFixSweep.verdictOf(true, false, true, true, true), 'the formatted project prints otherwise');
		Assert.isTrue(TrapFixSweep.fails('FORMAT-CHANGED'), 'it fails the sweep');
	}

	public function testEachVerdictAndWhetherItFails(): Void {
		Assert.same(['SKIPPED', 'BROKE', 'CHANGED', 'SAME'], [
			TrapFixSweep.verdictOf(false, true, false, false, false),
			TrapFixSweep.verdictOf(true, true, true, false, false),
			TrapFixSweep.verdictOf(true, true, true, true, false),
			TrapFixSweep.verdictOf(true, true, true, true, true)
		]);
		Assert.same([false, true, true, false], [for (v in ['SKIPPED', 'BROKE', 'CHANGED', 'SAME']) TrapFixSweep.fails(v)]);
	}

	public function testTheEditCountIsReadOffTheFixTranscript(): Void {
		Assert.same(['3', '?'], [
			TrapFixSweep.editsOf('apq lint --fix: 3 edit(s) in 1 file(s) over 2 pass(es)\n'),
			TrapFixSweep.editsOf('apq lint: no argument names a file of a known language\n')
		]);
	}

	@:pin('control')
	@:killer('M-SWEEP-TRACE-LINE-COMPARED')
	public function testATraceIsComparedWithoutTheLineItSitsOn(): Void {
		Assert.equals(TrapFixSweep.printed('a/b/Main.hx:2: 1\nplain\n'), TrapFixSweep.printed('a/b/Main.hx:7: 1\nplain\n'));
		Assert.notEquals(TrapFixSweep.printed('Main.hx:2: 1\n'), TrapFixSweep.printed('Main.hx:2: 2\n'));
	}

	public function testTheRulesThatEditedAreReadOffTheCensus(): Void {
		Assert.same([['explicit-type', 'prefer-map-type'], []], [
			TrapFixSweep.exercisedOf('apq lint --fix: rule census\n  exercised: explicit-type, prefer-map-type\n'),
			TrapFixSweep.exercisedOf('apq lint --fix: 0 edit(s)\n')
		]);
	}

	/**
	 * One probe swept by the engine: the project's own build is the oracle, so a risky fix (`prefer-map-type`, which needs a
	 * compiler to vouch for it) runs, and the program still prints what it printed. Needs the built engine, which an arm's
	 * worktree lacks, so no arm can be judged by it.
	 */
	public function testAProbeIsSweptWithItsOwnBuildAsTheOracle(): Void {
		final engine: Null<String> = CliFixture.engineOrSkip();
		if (engine == null) return;
		final dir: String = Path.join([TempScratch.root(), 'apq-trap-sweep-${Std.random(0x7fffffff)}']);
		FileSystem.createDirectory(dir);
		final catalog: String = Path.join([dir, 'catalog.json']);
		final main: Array<String> = [
			'class Main {',
			'\tstatic function main() {',
			'\t\tfinal m:haxe.ds.StringMap<Int> = new haxe.ds.StringMap();',
			'\t\tm.set(\'a\', 1);',
			'\t\tSys.println(m.get(\'a\'));',
			'\t}',
			'}'
		];
		File.saveContent(
			catalog, '{"traps": [{"name": "map", "files": {"Main.hx": ${Json.stringify(main)}}, "probes": [{"file": "Main.hx"}]}]}'
		);
		final swept: Array<SweptProbe> = TrapFixSweep.sweep(catalog, FileSystem.absolutePath(engine), ['--all']);
		FileSystem.deleteFile(catalog);
		FileSystem.deleteDirectory(dir);
		Assert.same(['SAME'], [for (s in swept) s.verdict]);
		Assert.isTrue(swept.length == 1 && swept[0].exercised.contains('prefer-map-type'), [for (s in swept) s.exercised.join(', ')].join(
			' | '
		));
	}

}
