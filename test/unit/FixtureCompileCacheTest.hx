package unit;

import haxe.DynamicAccess;
import haxe.io.Path;
import js.node.ChildProcess;
import sys.FileSystem;
import sys.io.File;
import testkit.FixtureCompileCache;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `testkit.FixtureCompileCache`, the replay `dev mutation-check` puts in front of the probe compiles: a replay at
 * another place answers what the compiler answers THERE, any changed input — the probe macro's source included — is a
 * compile, and nothing outside the whitelist is ever replayed.
 */
@:nullSafety(Strict)
class FixtureCompileCacheTest extends Test {

	/** A probe macro that prints and writes paths of both roots, so a replay that keeps the recorded run's paths shows. */
	private static inline final PROBE: String = 'class AnyparseReachDefinesProbe {\n'
		+ '\tpublic static function run(out:String):Void {\n'
		+ '\t\tSys.println("cwd " + Sys.getCwd());\n'
		+ '\t\tSys.println("out " + out);\n'
		+ '\t\tsys.io.File.saveContent(out, "main " + sys.FileSystem.fullPath("Main.hx"));\n'
		+ '\t}\n}\n';

	private static inline final MAIN: String = 'class Main { static function main() {} }\n';
	private static inline final BUILD: String = '-cp .\n-main Main\n--interp\n';

	public function testAReplayElsewhereAnswersWhatTheCompilerAnswersThere(): Void {
		final cache: String = CliFixture.writeTree('fcc_cache', []);
		final first: Fixture = fixture(PROBE);
		final second: Fixture = fixture(PROBE);
		final real: Fixture = fixture(PROBE);
		CliFixture.always(
			() -> for (dir in [cache, first.dir, first.probe, second.dir, second.probe, real.dir, real.probe]) CliFixture.removeDir(dir),
			() -> {
				FixtureCompileCache.run('haxe', 'stamp', cache, first.dir, args(first));
				final replayed: CompileOutcome = FixtureCompileCache.run('haxe', 'stamp', cache, second.dir, args(second));
				Assert.equals('miss,hit', tally(cache), 'the second fixture is the first one elsewhere');
				// the compiler itself at a third place: the replay must answer as it does, modulo that place
				final compiled: ChildProcessSpawnSyncResult = ChildProcess.spawnSync(
					'haxe', args(real), { cwd: real.dir, encoding: 'utf8' }
				);
				final out: String = replayed.out.toString();
				Assert.equals(0, replayed.status);
				Assert.equals(moved(Std.string(compiled.stdout), real, second), out);
				Assert.isTrue(out.indexOf(resolved(second.dir)) >= 0, 'the replay names its own cwd: $out');
				Assert.isTrue(out.indexOf(first.probe) < 0, 'nothing of the recorded run survives: $out');
				Assert.equals(
					moved(File.getContent(Path.join([real.probe, 'dump.txt'])), real, second),
					File.getContent(Path.join([second.probe, 'dump.txt']))
				);
			}
		);
	}

	public function testAChangedProbeSourceOrFixtureIsACompile(): Void {
		final cache: String = CliFixture.writeTree('fcc_cache', []);
		final base: Fixture = fixture(PROBE);
		// a mutated facts macro reaches the probe directory as different text, exactly like this
		final probe: Fixture = fixture('$PROBE// mutated\n');
		final main: Fixture = fixture(PROBE, '$MAIN// edited\n');
		CliFixture.always(
			() -> for (dir in [cache, base.dir, base.probe, probe.dir, probe.probe, main.dir, main.probe]) CliFixture.removeDir(dir),
			() -> {
				for (f in [base, probe, main]) FixtureCompileCache.run('haxe', 'stamp', cache, f.dir, args(f));
				Assert.equals('miss,miss,miss', tally(cache));
			}
		);
	}

	/**
	 * A key another live process is compiling is waited for and replayed (`shared`) — a sweep's concurrent tracks ask for
	 * the same fixture together — and one whose holder died is compiled here, unrecorded, its claim cleared for the next.
	 */
	public function testAKeyAnotherProcessHoldsIsWaitedForThenShared(): Void {
		final cache: String = CliFixture.writeTree('fcc_cache', []);
		final first: Fixture = fixture(PROBE);
		final second: Fixture = fixture(PROBE);
		final third: Fixture = fixture(PROBE);
		final probe: Any = js.Syntax.code('process.kill');
		CliFixture.always(() -> {
			js.Syntax.code('process.kill = {0}', probe);
			for (dir in [cache, first.dir, first.probe, second.dir, second.probe, third.dir, third.probe]) CliFixture.removeDir(dir);
		}, () -> {
			FixtureCompileCache.run('haxe', 'stamp', cache, first.dir, args(first));
			final entry: String = Path.join([
				cache,
				[for (f in FileSystem.readDirectory(cache)) if (f.endsWith('.json.gz')) f][0]
			]);
			// A live holder: this process. It records and releases the key the first time the waiter probes whether it is
			// alive, so the record lands while the waiter waits — however slow the machine — and nothing of the holder is
			// still running once the waiter returns, to race the dead-holder claim below.
			FileSystem.rename(entry, '$entry.aside');
			FileSystem.createDirectory('$entry.lock');
			File.saveContent('$entry.lock/pid', Std.string(js.Node.process.pid));
			function holder(): Void {
				FileSystem.rename('$entry.aside', entry);
				FileSystem.deleteFile('$entry.lock/pid');
				FileSystem.deleteDirectory('$entry.lock');
			}
			js.Syntax.code(
				'process.kill = function(pid, signal) { process.kill = {0}; {1}(); return {0}.call(process, pid, signal); }', probe, holder
			);
			final shared: CompileOutcome = FixtureCompileCache.run('haxe', 'stamp', cache, second.dir, args(second));
			Assert.equals(0, shared.status);
			Assert.isTrue(shared.out.toString().indexOf(resolved(second.dir)) >= 0, 'the shared replay names its own cwd');
			// a dead holder: its claim is cleared, the compile runs here unrecorded, and the next one claims the key again
			FileSystem.deleteFile(entry);
			FileSystem.createDirectory('$entry.lock');
			File.saveContent('$entry.lock/pid', '999999999');
			FixtureCompileCache.run('haxe', 'stamp', cache, third.dir, args(third));
			Assert.isFalse(FileSystem.exists('$entry.lock'));
			FixtureCompileCache.run('haxe', 'stamp', cache, third.dir, args(third));
			Assert.equals('miss,shared,pass,miss', tally(cache));
		});
	}

	/**
	 * A probe macro that ran the switch of the live arm (`APQ_MUTANT`) answered for that arm alone: never recorded, and a
	 * recorded compile that ran it is compiled again for it — while every other arm still replays it.
	 */
	public function testACompileThatRanTheLiveArmsSwitchAnswersForThatArmAlone(): Void {
		// what a schema build's `__mutOn(7)` does, compiled into a macro, when the compile runs the switched method
		final switched: String = PROBE.replace(
			'\t\tSys.println("cwd " + Sys.getCwd());\n',
			'\t\tfinal log = Sys.getEnv("APQ_MUTANT_MACRO_LOG");\n\t\tif (log != null) sys.io.File.saveContent(log, "7\\n");\n'
			+ '\t\tSys.println("cwd " + Sys.getCwd());\n'
		);
		final cache: String = CliFixture.writeTree('fcc_cache', []);
		final fixtures: Array<Fixture> = [for (_ in 0...4) fixture(switched)];
		final before: Null<String> = Sys.getEnv('APQ_MUTANT');
		CliFixture.always(() -> {
			Sys.putEnv('APQ_MUTANT', before ?? '');
			for (f in fixtures) for (dir in [f.dir, f.probe]) CliFixture.removeDir(dir);
			CliFixture.removeDir(cache);
		}, () -> {
			Sys.putEnv('APQ_MUTANT', '7');
			FixtureCompileCache.run('haxe', 'stamp', cache, fixtures[0].dir, args(fixtures[0]));
			Sys.putEnv('APQ_MUTANT', '3');
			FixtureCompileCache.run('haxe', 'stamp', cache, fixtures[1].dir, args(fixtures[1]));
			FixtureCompileCache.run('haxe', 'stamp', cache, fixtures[2].dir, args(fixtures[2]));
			Sys.putEnv('APQ_MUTANT', '7');
			final armed: CompileOutcome = FixtureCompileCache.run('haxe', 'stamp', cache, fixtures[3].dir, args(fixtures[3]));
			Assert.equals(0, armed.status);
			Assert.equals('pass,miss,hit,armed', tally(cache));
		});
	}

	public function testOnlyAWhitelistedProbeCompileInsideItsRootsIsReplayed(): Void {
		final f: Fixture = fixture(PROBE);
		final outside: String = CliFixture.writeTree('fcc_outside', [{ name: 'Lib.hx', source: 'class Lib {}\n' }]);
		CliFixture.always(() -> for (dir in [f.dir, f.probe, outside]) CliFixture.removeDir(dir), () -> {
			final planned: Null<CompilePlan> = FixtureCompileCache.plan(f.dir, args(f));
			Assert.notNull(planned);
			if (planned != null) Assert.equals([f.dir, f.probe].map(resolved).join(','), planned.roots.join(','));
			for (line in [
				'-lib utest',
				'-cp ../elsewhere',
				'-cp $outside',
				'--cmd echo',
				'--resource x.txt@x'
			]) Assert.isNull(planWith(f, BUILD + line + '\n'), 'refused: $line');
			Assert.isNull(FixtureCompileCache.plan(f.dir, args(f).filter(a -> a != '--no-output')), 'a compile with output');
			Assert.isNull(FixtureCompileCache.plan(f.dir, ['build.hxml', '--no-output']), 'no probe macro');
			FileSystem.createDirectory(Path.join([f.dir, 'sub']));
			Assert.isNull(FixtureCompileCache.plan(f.dir, args(f).concat(['-cp', Path.join([f.dir, 'sub'])])), 'a root inside another');
		});
	}

	public function testBothSpellingsOfATempPathMoveTogether(): Void {
		final from: Array<String> = ['/private/var/x/A'];
		final to: Array<String> = ['/private/var/y/B'];
		final text: String = 'a /var/x/A/f b /private/var/x/A/g';
		final encoded: String = FixtureCompileCache.encode(text, from);
		Assert.isTrue(encoded.indexOf('/x/A') < 0, encoded);
		Assert.equals('a /var/y/B/f b /private/var/y/B/g', FixtureCompileCache.decode(encoded, to));
	}

	/**
	 * A probe compile that writes into its cwd — the fixture, which a compile running beside it may append to as well — is
	 * never recorded: a replay rewrites whole files, so the other writer's lines would be lost (`OracleRunMemoTest` counts
	 * compiles through exactly such a log, and read 1 where two compiles ran).
	 */
	@:pin('control') @:killer('M-FIXTURE-CACHE-CWD-WRITE')
	public function testACompileWritingIntoItsCwdIsNotRecorded(): Void {
		final cache: String = CliFixture.writeTree('fcc_cache', []);
		final writer: String = 'class AnyparseReachDefinesProbe {\n\tpublic static function run(out:String):Void {\n'
			+ '\t\tsys.io.File.saveContent(out, "x");\n\t\tsys.io.File.saveContent("log.txt", "ran");\n\t}\n}\n';
		final first: Fixture = fixture(writer);
		final second: Fixture = fixture(writer);
		CliFixture.always(() -> for (dir in [cache, first.dir, first.probe, second.dir, second.probe]) CliFixture.removeDir(dir), () -> {
			final recorded: CompileOutcome = FixtureCompileCache.run('haxe', 'stamp', cache, first.dir, args(first));
			final answered: CompileOutcome = FixtureCompileCache.run('haxe', 'stamp', cache, second.dir, args(second));
			Assert.isTrue(recorded.exited && answered.exited, 'both compiled for real');
			Assert.equals('pass,pass', tally(cache));
			Assert.equals('ran', File.getContent(Path.join([second.dir, 'log.txt'])));
		});
	}

	/**
	 * `lookup`, the in-process ask `HaxeSpawn` makes before it starts a process, answers a recorded compile with exactly
	 * the bytes and files the shim's `run` replays for it, counts it as a hit, and answers nothing for any other compile —
	 * a changed input, a program that is not `haxe`, a compile that is no probe.
	 */
	@:pin('control')
	@:killer('M-FIXTURE-CACHE-LOOKUP-NEVER-SERVES')
	public function testALookupAnswersARecordedCompileAsTheShimReplaysIt(): Void {
		final cache: String = CliFixture.writeTree('fcc_cache', []);
		final first: Fixture = fixture(PROBE);
		final second: Fixture = fixture(PROBE);
		final third: Fixture = fixture(PROBE);
		final edited: Fixture = fixture(PROBE, '$MAIN// edited\n');
		CliFixture.always(() -> for (dir in [
			cache,
			first.dir,
			first.probe,
			second.dir,
			second.probe,
			third.dir,
			third.probe,
			edited.dir,
			edited.probe
		]) CliFixture.removeDir(dir), () -> {
			final recorded: CompileOutcome = FixtureCompileCache.run('haxe', 'stamp', cache, first.dir, args(first));
			Assert.equals(0, recorded.status);
			final dump: String = Path.join([second.probe, 'dump.txt']);
			final answer: Null<SpawnAnswer> = FixtureCompileCache.lookup('stamp', cache, null, request(second, 'haxe'));
			Assert.notNull(answer);
			// the shim's replay of the same fixture elsewhere: a replay writes into the roots, so the same one would be a new key
			final replayed: CompileOutcome = FixtureCompileCache.run('haxe', 'stamp', cache, third.dir, args(third));
			if (answer != null) {
				Assert.equals(replayed.status, answer.status);
				Assert.equals(replayed.out.toString(), moved(answer.out, second, third));
				Assert.equals(replayed.err.toString(), moved(answer.err, second, third));
				Assert.isTrue(answer.out.indexOf(resolved(second.dir)) >= 0, 'it names its own cwd: ${answer.out}');
			}
			Assert.equals(
				File.getContent(Path.join([third.probe, 'dump.txt'])), moved(File.getContent(dump), second, third),
				'and writes the files the replay writes'
			);
			Assert.equals('miss,hit,hit', tally(cache));
			Assert.isNull(FixtureCompileCache.lookup('stamp', cache, null, request(edited, 'haxe')), 'a changed input');
			Assert.isNull(FixtureCompileCache.lookup('other', cache, null, request(second, 'haxe')), 'another compiler');
			Assert.isNull(FixtureCompileCache.lookup('stamp', cache, null, request(second, 'neko')), 'another program');
			final plain: SpawnRequest = {
				cmd: 'haxe',
				args: ['--version'],
				cwd: second.dir,
				env: null
			};
			Assert.isNull(FixtureCompileCache.lookup('stamp', cache, null, plain), 'no probe macro');
			Assert.equals('miss,hit,hit', tally(cache), 'a lookup that answers nothing counts nothing');
		});
	}

	/** A lookup reads the arm and the compiler's variables from the request's environment, not from this process's. */
	@:pin('control')
	@:killer('M-FIXTURE-CACHE-LOOKUP-IGNORES-REQUEST-ENV')
	public function testALookupReadsTheLiveArmFromTheRequestsEnvironment(): Void {
		final switched: String = PROBE.replace(
			'\t\tSys.println("cwd " + Sys.getCwd());\n',
			'\t\tfinal log = Sys.getEnv("APQ_MUTANT_MACRO_LOG");\n\t\tif (log != null) sys.io.File.saveContent(log, "7\\n");\n'
			+ '\t\tSys.println("cwd " + Sys.getCwd());\n'
		);
		final cache: String = CliFixture.writeTree('fcc_cache', []);
		final fixtures: Array<Fixture> = [for (_ in 0...2) fixture(switched)];
		final before: Null<String> = Sys.getEnv('APQ_MUTANT');
		CliFixture.always(() -> {
			Sys.putEnv('APQ_MUTANT', before ?? '');
			for (f in fixtures) for (dir in [f.dir, f.probe]) CliFixture.removeDir(dir);
			CliFixture.removeDir(cache);
		}, () -> {
			Sys.putEnv('APQ_MUTANT', '3');
			final recorded: CompileOutcome = FixtureCompileCache.run('haxe', 'stamp', cache, fixtures[0].dir, args(fixtures[0]));
			Assert.equals(0, recorded.status);
			Assert.isNull(
				FixtureCompileCache.lookup('stamp', cache, null, armed(fixtures[1], '7')), 'the compile ran the live arm\'s switch'
			);
			Assert.notNull(FixtureCompileCache.lookup('stamp', cache, null, armed(fixtures[1], '4')), 'every other arm replays it');
			Assert.equals('miss,hit', tally(cache));
		});
	}

	/** The probe compile of `f`, as `ReachDefinesProbe` spells one: the probe directory on the command line. */
	private static function args(f: Fixture): Array<String> {
		return [
			'-cp',
			f.probe,
			'--macro',
			'AnyparseReachDefinesProbe.run("${f.probe}/dump.txt")',
			'build.hxml',
			'--no-output'
		];
	}

	private static function fixture(probe: String, main: String = MAIN): Fixture {
		return {
			dir: CliFixture.writeTree('fcc_fixture', [{ name: 'Main.hx', source: main }, { name: 'build.hxml', source: BUILD }]),
			probe: CliFixture.writeTree('fcc_probe', [{ name: 'AnyparseReachDefinesProbe.hx', source: probe }])
		};
	}

	/** `plan` of `f` with its hxml replaced by `hxml`. */
	private static function planWith(f: Fixture, hxml: String): Null<CompilePlan> {
		File.saveContent(Path.join([f.dir, 'build.hxml']), hxml);
		final planned: Null<CompilePlan> = FixtureCompileCache.plan(f.dir, args(f));
		File.saveContent(Path.join([f.dir, 'build.hxml']), BUILD);
		return planned;
	}

	/** `text` a compile of `from` printed, as a compile of `to` would print it. */
	private static function moved(text: String, from: Fixture, to: Fixture): String {
		final pairs: Array<{ a: String, b: String }> = [
			{ a: resolved(from.dir), b: resolved(to.dir) },
			{ a: resolved(from.probe), b: resolved(to.probe) },
			{ a: from.dir, b: to.dir },
			{ a: from.probe, b: to.probe }
		];
		var out: String = text;
		for (p in pairs) out = out.split(p.a).join(p.b);
		return out;
	}

	/** `path` resolved; bridged, because a compilation server reads hxnodejs' inlined `fullPath` as nullable. */
	private static function resolved(path: String): String {
		final full: Null<String> = FileSystem.fullPath(path);
		return full ?? path;
	}

	private static function tally(cache: String): String {
		final path: String = Path.join([cache, 'tally']);
		return FileSystem.exists(path) ? File.getContent(path).trim().split('\n').join(',') : '';
	}

	/** The `lookup` request for the probe compile of `f`. */
	private static function request(f: Fixture, cmd: String): SpawnRequest {
		return {
			cmd: cmd,
			args: args(f),
			cwd: f.dir,
			env: null
		};
	}

	/** The `lookup` request for the probe compile of `f` with the arm `id` switched on in its environment. */
	private static function armed(f: Fixture, id: String): SpawnRequest {
		final env: DynamicAccess<Null<String>> = {};
		env['APQ_MUTANT'] = id;
		return {
			cmd: 'haxe',
			args: args(f),
			cwd: f.dir,
			env: env
		};
	}

}

private typedef Fixture = {
	var dir: String;
	var probe: String;
}
