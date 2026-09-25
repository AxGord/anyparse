package unit.check;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig;
import anyparse.check.OracleGeneration;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A `compilerOracle` entry's `generate` command (`OracleGeneration`), against a real shell: the
 * command runs exactly when its recorded generation is not current — the hxml missing, an input's
 * content changed, the command itself changed — and a command that fails makes its configuration
 * unavailable instead of letting a stale hxml answer.
 *
 * Every fixture counts its runs in `runs.txt`, which the command appends to, so "ran" and "did not
 * run" are both observed rather than inferred from a note.
 */
@:nullSafety(Strict)
final class OracleGenerationTest extends Test {

	#if (sys || nodejs)
	private static final MAIN: String = 'class Main {\n\n\tpublic static function main() {\n\t\ttrace(1);\n\t}\n\n}\n';

	/** Writes a valid hxml and appends one line to `runs.txt`. */
	private static final WRITE: String = "printf '%s\\n' '-cp .' '-main Main' > gen.hxml && echo run >> runs.txt";
	#end

	/**
	 * A changed `generateInputs` file regenerates; the SAME call with the input unchanged does not —
	 * without that half a generation that ran every time would pass.
	 */
	@:pin('control')
	@:killer('M-GENERATE-NEVER-STALE-BY-INPUT')
	public function testAChangedInputRegeneratesAndAnUnchangedOneDoesNot(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		OracleGeneration.prepare([config]);
		Assert.equals(1, runs(dir), 'the first use generates the missing hxml');
		OracleGeneration.prepare([config]);
		Assert.equals(1, runs(dir), 'an unchanged input leaves the recorded generation current');
		File.saveContent('$dir/input.txt', 'two');
		final notes: Array<String> = OracleGeneration.prepare([config]).notes;
		Assert.equals(2, runs(dir), 'a changed input regenerates');
		Assert.isTrue(notes.length == 1 && notes[0].contains('input.txt changed'), 'and says which input: $notes');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A different command string regenerates even though no input changed. */
	@:pin('control')
	@:killer('M-GENERATE-NEVER-STALE-BY-COMMAND')
	public function testAChangedCommandRegenerates(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		OracleGeneration.prepare([entry(dir, WRITE, ['$dir/input.txt'])]);
		OracleGeneration.prepare([entry(dir, WRITE, ['$dir/input.txt'])]);
		Assert.equals(1, runs(dir), 'the same command over the same input runs once');
		OracleGeneration.prepare([entry(dir, '$WRITE # changed', ['$dir/input.txt'])]);
		Assert.equals(2, runs(dir), 'a changed command runs again');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An hxml deleted after its generation was recorded is regenerated, not reported current. */
	@:pin('control')
	@:killer('M-GENERATE-TRUSTS-A-MISSING-HXML')
	public function testAMissingHxmlRegenerates(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		OracleGeneration.prepare([config]);
		FileSystem.deleteFile('$dir/gen.hxml');
		OracleGeneration.prepare([config]);
		Assert.equals(2, runs(dir), 'the missing hxml is regenerated');
		Assert.isTrue(FileSystem.exists('$dir/gen.hxml'), 'and exists again');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A failing command makes its configuration UNAVAILABLE with the command's output quoted, and
	 * the typecheck answers so — although a valid hxml from an earlier generation is still on disk
	 * and would typecheck green. Reading that stale file is exactly the silent answer this forbids.
	 */
	@:pin('control')
	@:killer('M-GENERATE-FAILURE-USES-THE-STALE-HXML')
	public function testAFailedGenerationIsUnavailableNeverTheStaleHxml(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		File.saveContent('$dir/gen.hxml', '-cp .\n-main Main\n');
		final stale: OracleConfig = entry(dir, 'echo boom-from-the-command; exit 3', null);
		if (!CompilerOracle.typecheck(stale.hxml, stale.dir).match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final ready: Array<OracleConfig> = OracleGeneration.prepare([stale]).oracles;
		final reason: String = ready[0].unavailable ?? '';
		Assert.isTrue(reason.contains('exited 3') && reason.contains('boom-from-the-command'), 'the failure is quoted: $reason');
		final verdict: OracleOutcome = CompilerOracle.typecheckAll(ready);
		Assert.isTrue(verdict.match(Unavailable(_)), 'the configuration could not run — the stale hxml is not asked: $verdict');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function fixture(): String {
		return CliFixture.writeDir('oraclegen', [{ name: 'Main.hx', source: MAIN }, { name: 'input.txt', source: 'one' }]);
	}

	/** One configuration whose hxml `command` writes in `dir`. */
	private static function entry(dir: String, command: String, inputs: Null<Array<String>>): OracleConfig {
		return {
			hxml: '$dir/gen.hxml',
			dir: dir,
			defines: [],
			generate: {
				command: command,
				root: dir,
				inputs: inputs,
				probeDir: false
			}
		};
	}

	/** How many times the fixture's command ran. */
	private static function runs(dir: String): Int {
		final path: String = '$dir/runs.txt';
		return FileSystem.exists(path) ? [for (line in File.getContent(path).split('\n')) if (line != '') line].length : 0;
	}
	#end

	/**
	 * An input edited WHILE the command runs is a change the next run sees: the recorded hash is the one taken BEFORE
	 * the command, which is what the hxml was built from. The command here edits its own input to stand in for an
	 * editor saving mid-generation; the third call, with nothing edited since, stays current.
	 */
	@:pin('control')
	@:killer('M-GENERATE-HASHES-INPUTS-AFTER-THE-RUN')
	public function testAnInputEditedDuringTheGenerationIsSeenNextRun(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, '$WRITE && echo two > input.txt', ['$dir/input.txt']);
		OracleGeneration.prepare([config]);
		OracleGeneration.prepare([config]);
		Assert.equals(2, runs(dir), 'the hxml was built from `one`, so the `two` written during the run is stale');
		OracleGeneration.prepare([config]);
		Assert.equals(2, runs(dir), 'and a generation that started from `two` is current');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The record of the previous generation is gone BEFORE a stale command starts, so a command killed half way (here
	 * observed from inside it) leaves nothing that reads as current.
	 */
	@:pin('control')
	@:killer('M-GENERATE-RECORD-OUTLIVES-THE-RUN')
	public function testAStaleGenerationRunsWithoutItsOldRecord(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final first: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		OracleGeneration.prepare([first]);
		final record: String = OracleGeneration.recordFile(OracleGeneration.groupsOf([first])[0]);
		Assert.isTrue(FileSystem.exists(record), 'the first generation is recorded');
		final probe: String = '$WRITE && if [ -e "$record" ]; then echo present > seen.txt; fi';
		OracleGeneration.prepare([entry(dir, probe, ['$dir/input.txt'])]);
		Assert.isFalse(FileSystem.exists('$dir/seen.txt'), 'the command ran with no record left to trust if it died');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A directory input is hashed by its tree: a file added under it regenerates. */
	@:pin('control')
	@:killer('M-GENERATE-DIRECTORY-INPUT-CONSTANT')
	public function testADirectoryInputIsHashedByItsContent(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		FileSystem.createDirectory('$dir/fonts');
		File.saveContent('$dir/fonts/a.ttf', 'a');
		final config: OracleConfig = entry(dir, WRITE, ['$dir/fonts']);
		OracleGeneration.prepare([config]);
		OracleGeneration.prepare([config]);
		Assert.equals(1, runs(dir), 'an unchanged directory is current');
		File.saveContent('$dir/fonts/b.ttf', 'b');
		OracleGeneration.prepare([config]);
		Assert.equals(2, runs(dir), 'a file added under it regenerates');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Two entries sharing one command are one generation over the UNION of their inputs. */
	@:pin('control')
	@:killer('M-GENERATE-FIRST-ENTRY-INPUTS')
	public function testEntriesSharingACommandMergeTheirInputs(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		File.saveContent('$dir/other.txt', 'x');
		final pair: Array<OracleConfig> = [entry(dir, WRITE, ['$dir/input.txt']), entry(dir, WRITE, ['$dir/other.txt'])];
		OracleGeneration.prepare(pair);
		OracleGeneration.prepare(pair);
		Assert.equals(1, runs(dir), 'one command, one generation');
		File.saveContent('$dir/other.txt', 'y');
		OracleGeneration.prepare(pair);
		Assert.equals(2, runs(dir), 'the SECOND entry\'s input counts too');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The library state the generated hxml resolves to is an input nobody declares: a library classpath outside the
	 * project makes its `haxelib.json` and the repository's `.current` inputs, and an included hxml is one too. The
	 * fixture is a scratch haxelib layout `<repo>/mylib/<version>/src`.
	 */
	@:pin('control')
	@:killer('M-GENERATE-IGNORES-LIBRARY-STATE')
	public function testTheLibraryStateTheHxmlNamesIsAnInput(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final repo: String = CliFixture.writeTree('oraclegenrepo', [
			{ name: 'mylib/.current', source: '1.0.0' },
			{ name: 'mylib/1,0,0/haxelib.json', source: '{"name":"mylib","version":"1.0.0"}' },
			{ name: 'mylib/1,0,0/src/Lib.hx', source: 'class Lib {}\n' }
		]);
		File.saveContent('$dir/extra.hxml', '-D extra\n');
		final command: String = "printf '%s\\n' '-cp .' '-main Main' '-cp " + repo
			+ "/mylib/1,0,0/src' 'extra.hxml' > gen.hxml && echo run >> runs.txt";
		final config: OracleConfig = entry(dir, command, ['$dir/input.txt']);
		OracleGeneration.prepare([config]);
		OracleGeneration.prepare([config]);
		Assert.equals(1, runs(dir), 'unchanged library state is current');
		File.saveContent('$repo/mylib/.current', '1.0.1');
		OracleGeneration.prepare([config]);
		Assert.equals(2, runs(dir), 'switching the library version regenerates');
		File.saveContent('$repo/mylib/1,0,0/haxelib.json', '{"name":"mylib","version":"1.0.2"}');
		OracleGeneration.prepare([config]);
		Assert.equals(3, runs(dir), 'so does its haxelib.json');
		File.saveContent('$dir/extra.hxml', '-D extra2\n');
		OracleGeneration.prepare([config]);
		Assert.equals(4, runs(dir), 'and an hxml the generated one includes');
		CliFixture.removeDir(repo);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A lock held by a LIVE other run makes the configuration unavailable once the wait runs out. */
	@:pin('control')
	@:killer('M-GENERATE-LOCK-IGNORED')
	public function testALockHeldByALiveRunMakesTheConfigurationUnavailable(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		final lock: String = OracleGeneration.lockDir(OracleGeneration.groupsOf([config])[0]);
		final other: Dynamic = js.node.ChildProcess.spawn('sleep', ['30']);
		FileSystem.createDirectory(lock);
		File.saveContent('$lock/owner', '${other.pid} ${Date.now().getTime()}');
		final ready: Array<OracleConfig> = OracleGeneration.prepare([config], 300).oracles;
		other.kill();
		Assert.isTrue(
			(ready[0].unavailable ?? '').contains('holds its generation lock'), 'the live owner is waited for: ${ready[0].unavailable}'
		);
		Assert.equals(0, runs(dir), 'and nothing was generated under it');
		CliFixture.removeDir(lock);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A lock whose owner is gone is taken over rather than waited for. */
	@:pin('control')
	@:killer('M-GENERATE-LOCK-NEVER-RECOVERED')
	public function testAnAbandonedLockIsTakenOver(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		final lock: String = OracleGeneration.lockDir(OracleGeneration.groupsOf([config])[0]);
		final gone: Dynamic = js.node.ChildProcess.spawnSync('sh', ['-c', "echo $$"]);
		final pid: Null<Int> = Std.parseInt(Std.string(gone.stdout).trim());
		Assert.notNull(pid, 'a real pid, of a process that has exited');
		FileSystem.createDirectory(lock);
		File.saveContent('$lock/owner', '$pid ${Date.now().getTime()}');
		final ready: Array<OracleConfig> = OracleGeneration.prepare([config], 300).oracles;
		Assert.isNull(ready[0].unavailable, 'the dead owner\'s lock was taken over');
		Assert.equals(1, runs(dir), 'and the generation ran');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** `generateInputs: []` regenerates every run like an absent list, and a missing input is named, not silent. */
	@:pin('control')
	@:killer('M-GENERATE-EMPTY-INPUTS-NEVER')
	@:killer('M-GENERATE-MISSING-INPUT-SILENT')
	public function testAnEmptyOrMissingInputIsNeverSilentlyConstant(): Void {
		final empty: LintConfig = LintConfig.parse('{"compilerOracle":[{"hxml":"g.hxml","generate":"true","generateInputs":[]}]}', '/tmp');
		Assert.isNull(empty.compilerOracles()[0].generate?.inputs, 'an empty list is no list');
		final missing: LintConfig = LintConfig.parse(
			'{"compilerOracle":[{"hxml":"g.hxml","generate":"true","generateInputs":["no-such-input.txt"]}]}', '/tmp'
		);
		Assert.equals(1, missing.compilerOracles()[0].generate?.inputs?.length, 'the missing input is kept');
		Assert.isTrue(Lambda.exists(missing.drops(), d -> d.contains('no-such-input.txt')), 'and named: ${missing.drops()}');
	}

}
