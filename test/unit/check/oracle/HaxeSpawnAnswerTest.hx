package unit.check.oracle;

import anyparse.check.oracle.HaxeRun;
import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.oracle.SpawnJob;
import haxe.DynamicAccess;
import sys.FileSystem;
import sys.io.File;

/**
 * The lookup seam of `HaxeSpawn` (`ANSWER_ENV`): a job whose answer the named module has recorded is answered from it
 * without a process, in this process and in the process driver alike; a job it has no answer for is spawned as it always
 * was, and with the variable empty nothing is loaded.
 */
@:nullSafety(Strict)
final class HaxeSpawnAnswerTest extends Test {

	private static inline final ROOMY: Int = 8 * 1024 * 1024;

	@:pin('control')
	@:killer('M-SPAWN-ANSWER-NEVER-ASKED')
	public function testARecordedAnswerIsReplayedWithoutASpawn(): Void {
		#if nodejs
		withModule((log, _) -> {
			final run: HaxeRun = HaxeSpawn.run(['--version'], null, ROOMY);
			// the compiler itself would exit 0 on `--version`
			Assert.equals(7, run.status);
			Assert.equals('recorded out', run.out);
			Assert.equals('recorded err', run.err);
			Assert.equals('', run.failure);
			Assert.isFalse(run.overflowed);
			Assert.equals(1, asked(log).length);
		});
		#else
		Assert.pass('the seam needs the node target');
		#end
	}

	@:pin('control')
	@:killer('M-DRIVER-NEVER-ASKS')
	public function testTheProcessDriverAsksToo(): Void {
		#if nodejs
		withModule((log, _) -> {
			final jobs: Array<SpawnJob> = [{ args: ['--version'] }, { args: ['--version'] }];
			final runs: Array<HaxeRun> = HaxeSpawn.runAll(jobs, ROOMY, 2);
			Assert.equals(2, runs.length);
			for (run in runs) {
				Assert.equals(7, run.status);
				Assert.equals('recorded out', run.out);
				Assert.equals('recorded err', run.err);
				Assert.equals('', run.failure);
			}
			Assert.equals(2, asked(log).length);
		});
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	public function testAJobWithNoAnswerIsSpawned(): Void {
		#if nodejs
		withModule((log, _) -> {
			final run: HaxeRun = HaxeSpawn.run(['miss'], null, ROOMY);
			Assert.notEquals(7, run.status);
			Assert.equals(1, asked(log).length, 'asked once, then spawned');
			final driven: Array<HaxeRun> = HaxeSpawn.runAll([{ args: ['miss'] }, { args: ['miss'] }], ROOMY, 2);
			for (r in driven) Assert.notEquals(7, r.status);
			Assert.equals(3, asked(log).length);
		});
		#else
		Assert.pass('the seam needs the node target');
		#end
	}

	public function testAnEmptyVariableLoadsNothing(): Void {
		#if nodejs
		withModule((log, _) -> {
			Sys.putEnv(HaxeSpawn.ANSWER_ENV, '');
			Assert.notEquals(7, HaxeSpawn.run(['--version'], null, ROOMY).status);
			for (r in HaxeSpawn.runAll([{ args: ['--version'] }, { args: ['--version'] }], ROOMY, 2)) Assert.notEquals(7, r.status);
			Assert.isFalse(FileSystem.exists(log), 'the module was never required');
		});
		#else
		Assert.pass('the seam needs the node target');
		#end
	}

	public function testAnAnswerPastTheBufferIsLeftToTheSpawn(): Void {
		#if nodejs
		withModule((log, _) -> {
			final run: HaxeRun = HaxeSpawn.run(['--version'], null, 5);
			Assert.notEquals(7, run.status);
			Assert.equals(1, asked(log).length);
		});
		#else
		Assert.pass('the seam needs the node target');
		#end
	}

	public function testTheRequestCarriesTheJobsProgramDirectoryAndVariables(): Void {
		#if nodejs
		withModule((log, dir) -> {
			final env: DynamicAccess<String> = {};
			env['ANSWER_PROBE'] = 'set';
			final run: HaxeRun = HaxeSpawn.exec({ args: ['--version'], cwd: dir, env: HaxeSpawn.environment(env) }, ROOMY);
			Assert.equals(7, run.status);
			final request: Asked = haxe.Json.parse(asked(log)[0]); // noqa: avoid-haxe-json
			Assert.equals('haxe', request.cmd);
			Assert.same(['--version'], request.args);
			Assert.equals(dir, request.cwd);
			Assert.equals('set', request.env.get('ANSWER_PROBE'));
		});
		#else
		Assert.pass('the seam needs the node target');
		#end
	}

	/**
	 * The process driver answers every job of a long run of recorded hits: a hit settles inside the driver's start loop, so
	 * the stack does not grow with the number of consecutive hits.
	 */
	@:pin('control')
	@:killer('M-DRIVER-ANSWER-REENTERS-START')
	public function testALongRunOfAnswersIsAllAnswered(): Void {
		#if nodejs
		final count: Int = 4000;
		withModule((log, _) -> {
			final runs: Array<HaxeRun> = HaxeSpawn.runAll([for (_ in 0...count) { args: ['--version'] }], ROOMY, 4);
			Assert.equals(count, runs.length);
			Assert.equals(count, runs.filter(run -> run.status == 7 && run.failure == '').length);
		});
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/** A job with a program of its own, a standard input, a shell or a tether is not the compile a recording stands for: never asked. */
	@:pin('control')
	@:killer('M-SPAWN-ANSWER-ASKS-ANY-JOB')
	public function testAJobThatIsNotAPlainCompileIsNeverAskedInProcess(): Void {
		#if nodejs
		withModule((log, dir) -> {
			final input: String = '$dir/input.txt';
			File.saveContent(input, '');
			Assert.notEquals(7, HaxeSpawn.exec({ args: ['-e', '0'], cmd: js.Node.process.execPath }, ROOMY).status);
			Assert.notEquals(7, HaxeSpawn.exec({ args: ['--version'], stdin: input }, ROOMY).status);
			Assert.notEquals(7, HaxeSpawn.exec({ args: [], shell: 'exit 0' }, ROOMY).status);
			Assert.isFalse(FileSystem.exists(log), 'the module was never required');
		});
		#else
		Assert.pass('the seam needs the node target');
		#end
	}

	/** The same four kinds of job in the process driver. */
	@:pin('control')
	@:killer('M-DRIVER-ASKS-ANY-JOB')
	public function testAJobThatIsNotAPlainCompileIsNeverAskedInTheDriver(): Void {
		#if nodejs
		withModule((log, dir) -> {
			final input: String = '$dir/input.txt';
			File.saveContent(input, '');
			final jobs: Array<SpawnJob> = [
				{ args: ['-e', '0'], cmd: js.Node.process.execPath },
				{ args: ['--version'], stdin: input },
				{ args: [], shell: 'exit 0' },
				{ args: ['--version'], tethered: true }
			];
			for (run in HaxeSpawn.runAll(jobs, ROOMY, 2)) Assert.notEquals(7, run.status);
			Assert.isFalse(FileSystem.exists(log), 'the module was never required');
		});
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/** An answer is measured in bytes, as a spawn's output is: a multi-byte one under the limit in characters is past it. */
	public function testAnAnswerIsMeasuredInBytes(): Void {
		#if nodejs
		withModule((log, _) -> {
			Assert.notEquals(7, HaxeSpawn.run(['wide'], null, 10).status);
			for (run in HaxeSpawn.runAll([{ args: ['wide'] }, { args: ['wide'] }], 10, 2)) Assert.notEquals(7, run.status);
			Assert.equals(3, asked(log).length);
			Assert.equals(7, HaxeSpawn.run(['wide'], null, 12).status, 'and at the limit it is returned');
		});
		#else
		Assert.pass('the seam needs the node target');
		#end
	}

	@:pin('control')
	@:killer('M-DRIVER-FLUSH-TWICE')
	public function testAnUnopenableStdinIsAnsweredWhetherOrNoModuleIsSet(): Void {
		#if nodejs
		withModule((log, dir) -> {
			final lost: SpawnJob = { args: ['--version'], stdin: '$dir/absent/in.txt' };
			final lostToo: SpawnJob = { args: ['--version'], stdin: '$dir/absent/in2.txt' };
			Sys.putEnv(HaxeSpawn.ANSWER_ENV, '');
			for (run in HaxeSpawn.runAll([lost, lostToo], ROOMY, 2)) Assert.stringContains('could not open', run.failure);
			Sys.putEnv(HaxeSpawn.ANSWER_ENV, '$dir/answer.js');
			for (run in HaxeSpawn.runAll([lost, lostToo], ROOMY, 2)) Assert.stringContains('could not open', run.failure);
			final mixed: Array<HaxeRun> = HaxeSpawn.runAll([lost, { args: ['--version'] }], ROOMY, 2);
			Assert.stringContains('could not open', mixed[0].failure);
			Assert.equals(7, mixed[1].status);
		});
		#else
		Assert.pass('the process driver needs the node target');
		#end
	}

	/** Answers `7` for every request but one whose first argument is `miss`, and logs what it was asked, load included. */
	private static function module(log: String): String {
		return 'const fs = require("fs"); fs.appendFileSync(${quote(log)}, "loaded\\n");\nexports.answer = request => { fs.appendFileSync('
			+ '${quote(log)}, JSON.stringify(request) + "\\n");\n  if (request.args[0] === "wide") return { status: 7, out: "éééééé", err: '
			+ '"" };\n  return request.args[0] === "miss" ? null : { status: 7, out: "recorded out", err: "recorded err" }; };\n';
	}

	/** Runs `body` with `ANSWER_ENV` naming a fresh module; its log file is `log` (not yet there), its directory `dir`. */
	private static function withModule(body: (log:String, dir:String) -> Void): Void {
		final dir: String = CliFixture.writeDir('hs_answer', []);
		final log: String = '$dir/asked.log';
		File.saveContent('$dir/answer.js', module(log));
		final before: String = Sys.getEnv(HaxeSpawn.ANSWER_ENV) ?? '';
		CliFixture.always(() -> {
			Sys.putEnv(HaxeSpawn.ANSWER_ENV, before);
			CliFixture.removeDir(dir);
		}, () -> {
			Sys.putEnv(HaxeSpawn.ANSWER_ENV, '$dir/answer.js');
			body(log, dir);
		});
	}

	/** The requests the module was asked, one JSON document per line. */
	private static function asked(log: String): Array<String> {
		return FileSystem.exists(log) ? File.getContent(log).split('\n').filter(line -> line != '' && line != 'loaded') : [];
	}

	private static function quote(text: String): String {
		return haxe.Json.stringify(text); // noqa: avoid-haxe-json
	}

}

/** A request as the module logged it. */
private typedef Asked = {
	var cmd: String;
	var args: Array<String>;
	var cwd: String;
	var env: DynamicAccess<String>;
}
