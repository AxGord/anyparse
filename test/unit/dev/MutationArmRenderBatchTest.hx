package unit.dev;

import dev.ArmRegistry;
import dev.ArmSweep;
import dev.MutationArm;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * A render batch of `dev mutation-arm` that dies is the run's failure, not a verdict over its arms: it is run once more
 * alone, and when it dies again the run is refused rather than answered as `APPLY-FAIL` rows.
 */
@:nullSafety(Strict)
final class MutationArmRenderBatchTest extends Test {

	/** What one batch may take in these tests before it is killed. */
	private static inline final TIMEOUT_MS: Int = 3000;

	@:pin('control')
	@:killer('M-ARM-RENDER-BATCH-DEATH-IGNORED')
	public function testABatchThatDiesOnceIsRunAgainAlone(): Void {
		TempDir.with(dir -> Assert.equals(0, armRun(dir, 1), 'the second attempt applies the cut, so no arm is a failure'));
	}

	@:pin('control')
	@:killer('M-ARM-RENDER-LOST-BATCH-ANSWERS-ROWS')
	public function testABatchThatDiesTwiceRefusesTheRun(): Void {
		TempDir.with(dir -> Assert.equals(2, armRun(dir, 2), 'a refusal, not an APPLY-FAIL row (exit 1) for each arm of the lost batch'));
	}

	/** A batch killed at its timeout is a death as any other: the run once more alone, whose answer stands. */
	@:pin('control')
	@:killer('M-ARM-RENDER-BATCH-DEATH-IGNORED')
	public function testABatchKilledAtItsTimeoutIsRunAgainAlone(): Void {
		TempDir.with(dir -> {
			final file: String = batchFile(dir);
			final stub: String = stubIn(
				dir,
				'const hang = fs.existsSync(counter) ? false : true; fs.writeFileSync(counter, "1"); if (hang) setTimeout(() '
				+ '=> {}, 120000);'
			);
			Assert.isNull(MutationArm.applyBatches(stub, [file], dir.file('repo'), 1, TIMEOUT_MS));
		});
	}

	/** The batches run no more at once than the threads the lease gives. */
	@:pin('control')
	@:killer('M-ARM-RENDER-BATCHES-UNCAPPED')
	public function testBatchesRunNoMoreAtOnceThanTheThreads(): Void {
		TempDir.with(dir -> {
			final trace: String = dir.file('trace');
			final stub: String = stubIn(dir, 'fs.appendFileSync("$trace", "S"); setTimeout(() => fs.appendFileSync("$trace", "E"), 400);');
			final files: Array<String> = [ for (i in 0...3) batchFile(dir, '$i') ];
			Assert.isNull(MutationArm.applyBatches(stub, files, dir.file('repo'), 1, 60000));
			Assert.equals('SESESE', File.getContent(trace));
		});
	}

	/** One batch a thread, and more batches when one would take more rows than a batch may. */
	@:pin('control')
	@:killer('M-ARM-RENDER-BATCH-ROWS-UNBOUNDED')
	public function testARegistryIsDealtIntoBatchesThatStayWithinTheRowLimit(): Void {
		Assert.equals(1, MutationArm.batchCount(5, 1));
		Assert.equals(4, MutationArm.batchCount(5, 4));
		Assert.isTrue(
			MutationArm.batchCount(5600, 1) >= 5600 / 500, 'a registry of thousands of rows is more than a few batches, whatever the lease'
		);
	}

	/**
	 * A batch killed twice names itself and its log, and the log stays as
	 * a file beside the batch: nothing of it is lost with the work root.
	 */
	@:pin('control')
	@:killer('M-ARM-RENDER-BATCH-LOSS-SILENT')
	@:killer('M-ARM-RENDER-BATCH-LOG-LOST')
	public function testABatchKilledTwiceIsRefusedNamingItAndKeepsItsLog(): Void {
		TempDir.with(dir -> {
			final file: String = batchFile(dir);
			final stub: String = stubIn(dir, 'console.log("stub engine stuck"); setTimeout(() => {}, 120000);');
			final lost: Array<String> = MutationArm.applyBatches(stub, [file], dir.file('repo'), 1, TIMEOUT_MS) ?? [];
			Assert.isTrue(lost.length > 0, 'the batch is refused');
			Assert.isTrue((lost[0] ?? '').contains(file), 'the refusal names the batch file');
			Assert.isTrue(FileSystem.exists('$file.log'));
			Assert.isTrue(File.getContent('$file.log').contains('stub engine stuck'), 'the log holds what the batch printed');
		});
	}

	/** The sweep reads a refused render as a run with no verdict (its `.failed` text names the batch), not as arms that held. */
	public function testTheSweepEndsFailedOnARefusedRender(): Void {
		final records: Array<ArmRecord> = ArmRegistry.parse('{"arms": [{"name": "M-X", "type": "a.B", "method": "f", "force": "7"}]}');
		final log: String =
			'dev mutation-arm: render batch /w/render-batch.0 failed twice (timed out); its log is /w/render-batch.0.log:\n';
		final refused: Null<String> = ArmSweep.refusal(2, '', log, records);
		Assert.stringContains('render-batch.0 failed twice', refused ?? '');
	}

	/** Once a batch has failed twice the run is refused, so the batches after it are not run again: a rerun can take a whole timeout. */
	@:pin('control')
	@:killer('M-ARM-RENDER-RERUN-AFTER-LOSS')
	public function testNoBatchIsRunAgainOnceOneHasBeenLost(): Void {
		TempDir.with(dir -> {
			final trace: String = dir.file('trace');
			final stub: String = stubIn(dir, 'fs.appendFileSync("$trace", "S"); process.exit(1);');
			final files: Array<String> = [ for (i in 0...2) batchFile(dir, '$i') ];
			Assert.notNull(MutationArm.applyBatches(stub, files, dir.file('repo'), 1, TIMEOUT_MS));
			Assert.equals('SSS', File.getContent(trace), 'both first runs and the one rerun of the first batch');
		});
	}

	/** `--apply-only` over a one-arm repo whose engine is a stub that dies on its first `deaths` batch runs. */
	private static function armRun(dir: TempDir, deaths: Int): Int {
		final repo: String = dir.file('repo');
		FileSystem.createDirectory(Path.join([repo, 'src/a']));
		FileSystem.createDirectory(Path.join([repo, 'test/testkit/arms']));
		File.saveContent(
			Path.join([repo, 'src/a/B.hx']), 'package a;\n\nclass B {\n\n\tpublic static function f():Int {\n\t\treturn 1;\n\t}\n\n}\n'
		);
		File.saveContent(
			Path.join([repo, 'test/testkit/arms/a.json']),
			'{"arms": [{"name": "M-X", "type": "a.B", "method": "f", "find": "return 1;", "replace": "return 2;"}]}'
		);
		final engine: String = dir.file('engine');
		FileSystem.createDirectory(engine);
		File.saveContent(Path.join([engine, 'test.js']), '');
		File.saveContent(Path.join([engine, 'apq.js']), stubEngine(Path.join([engine, 'runs']), deaths));
		return ArmApply.runOn(Path.join([engine, 'apq.js']), repo, ['M-X', '--apply-only']);
	}

	/**
	 * An `apq` whose `patch --batch` exits 1 until it has been started `deaths`
	 * times, then writes each row's file with `return 1` read as `return 2`.
	 */
	private static function stubEngine(counter: String, deaths: Int): String {
		return [
			"const fs = require('fs');",
			'const counter = \'$counter\';',
			"const runs = (fs.existsSync(counter) ? Number(fs.readFileSync(counter, 'utf8')) : 0) + 1;",
			'fs.writeFileSync(counter, String(runs));',
			'if (runs <= $deaths) { console.error(\'engine died\'); process.exit(1); }',
			"const rows = fs.readFileSync(process.argv[process.argv.indexOf('--batch') + 1], 'utf8').split('\\n').filter(l => l != '');",
			'for (const row of rows) {',
			"  const cells = row.split('\\t');",
			"  fs.writeFileSync(cells[3], fs.readFileSync(cells[0], 'utf8').replace('return 1', 'return 2'));",
			'}',
			''
		].join('\n');
	}

	/** A batch file in `dir` (its rows are the stub's business) and a `repo` directory to run in. */
	private static function batchFile(dir: TempDir, name: String = 'only'): String {
		FileSystem.createDirectory(dir.file('repo'));
		final file: String = dir.file('batch-${name}');
		File.saveContent(file, '');
		return file;
	}

	/** An engine in `dir` whose every start runs `body`, with `fs` and `counter` (a file that persists between its starts) in scope. */
	private static function stubIn(dir: TempDir, body: String): String {
		final stub: String = dir.file('stub.js');
		File.saveContent(stub, 'const fs = require("fs"); const counter = "' + dir.file('counter') + '";\n$body\n');
		return stub;
	}

}
