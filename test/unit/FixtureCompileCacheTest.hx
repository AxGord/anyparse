package unit;

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
 * `testkit.FixtureCompileCache`, the replay `tools/mutation-check.sh` puts in front of the probe compiles: a replay at
 * another place answers what the compiler answers THERE, any changed input — the probe macro's source included — is a
 * compile, and nothing outside the whitelist is ever replayed.
 */
@:nullSafety(Strict)
class FixtureCompileCacheTest extends Test {

	/** A probe macro that prints and writes paths of both roots, so a replay that keeps the recorded run's paths shows. */
	private static inline final PROBE: String = 'class AnyparseReachDefinesProbe {\n' + '\tpublic static function run(out:String):Void {\n'
		+ '\t\tSys.println("cwd " + Sys.getCwd());\n' + '\t\tSys.println("out " + out);\n'
		+ '\t\tsys.io.File.saveContent(out, "main " + sys.FileSystem.fullPath("Main.hx"));\n' + '\t}\n}\n';

	private static inline final MAIN: String = 'class Main { static function main() {} }\n';

	private static inline final BUILD: String = '-cp .\n-main Main\n--interp\n';

	public function testAReplayElsewhereAnswersWhatTheCompilerAnswersThere(): Void {
		final cache: String = CliFixture.writeTree('fcc_cache', []);
		final first: Fixture = fixture(PROBE, MAIN);
		final second: Fixture = fixture(PROBE, MAIN);
		final real: Fixture = fixture(PROBE, MAIN);
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
		final base: Fixture = fixture(PROBE, MAIN);
		// a mutated facts macro reaches the probe directory as different text, exactly like this
		final probe: Fixture = fixture(PROBE + '// mutated\n', MAIN);
		final main: Fixture = fixture(PROBE, MAIN + '// edited\n');
		CliFixture.always(
			() -> for (dir in [cache, base.dir, base.probe, probe.dir, probe.probe, main.dir, main.probe]) CliFixture.removeDir(dir),
			() -> {
				for (f in [base, probe, main]) FixtureCompileCache.run('haxe', 'stamp', cache, f.dir, args(f));
				Assert.equals('miss,miss,miss', tally(cache));
			}
		);
	}

	public function testOnlyAWhitelistedProbeCompileInsideItsRootsIsReplayed(): Void {
		final f: Fixture = fixture(PROBE, MAIN);
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

	private static function fixture(probe: String, main: String): Fixture {
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

}

private typedef Fixture = {
	var dir: String;
	var probe: String;
}
