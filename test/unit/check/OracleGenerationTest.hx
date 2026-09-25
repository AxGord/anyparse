package unit.check;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.CompilerOracle;
import anyparse.check.HaxeSpawn;
import anyparse.check.LintConfig;
import anyparse.check.OracleGeneration;
import anyparse.check.OracleGenerationLock;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;
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
	@:killer('M-GENERATE-TEMPLATES-UNTRACKED')
	public function testTheLibraryStateTheHxmlNamesIsAnInput(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final repo: String = CliFixture.writeTree('oraclegenrepo', [
			{ name: 'mylib/.current', source: '1.0.0' },
			{ name: 'mylib/1,0,0/haxelib.json', source: '{"name":"mylib","version":"1.0.0"}' },
			{ name: 'mylib/1,0,0/src/Lib.hx', source: 'class Lib {}\n' },
			{ name: 'mylib/1,0,0/templates/haxe/ApplicationMain.hx', source: '// template\n' }
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
		File.saveContent('$repo/mylib/1,0,0/templates/haxe/ApplicationMain.hx', '// template 2\n');
		OracleGeneration.prepare([config]);
		Assert.equals(5, runs(dir), 'and the code templates of the library that generated it');
		CliFixture.removeDir(repo);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A generation held EXCLUSIVELY by a live other run makes the configuration unavailable once the wait runs out. */
	@:pin('control')
	@:killer('M-GENERATE-LOCK-IGNORED')
	public function testALockHeldByALiveRunMakesTheConfigurationUnavailable(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		final lock: String = lockOf(config);
		final other: Dynamic = js.node.ChildProcess.spawn('sleep', ['30']);
		holdAsWriter(lock, other.pid, OracleGenerationLock.startTime(other.pid));
		final ready: Array<OracleConfig> = OracleGeneration.prepare([config], 300).oracles;
		other.kill();
		Assert.isTrue(
			(ready[0].unavailable ?? '').contains('is regenerating it'), 'the live writer is waited for: ${ready[0].unavailable}'
		);
		Assert.equals(0, runs(dir), 'and nothing was generated under it');
		CliFixture.removeDir(lock);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A generation lock whose owner is gone is taken over rather than waited for. */
	@:pin('control')
	@:killer('M-GENERATE-LOCK-NEVER-RECOVERED')
	public function testAnAbandonedLockIsTakenOver(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		final lock: String = lockOf(config);
		holdAsWriter(lock, exitedPid(), '');
		final ready: Array<OracleConfig> = OracleGeneration.prepare([config], 300).oracles;
		Assert.isNull(ready[0].unavailable, 'the dead owner\'s lock was taken over');
		Assert.equals(1, runs(dir), 'and the generation ran');
		CliFixture.removeDir(lock);
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

	/**
	 * Readers never wait for each other: a CURRENT generation another live run is compiling (a shared hold) is used at
	 * once, with nothing regenerated — two concurrent lint runs over a current tree each take their own time, not twice it.
	 */
	@:pin('control')
	@:killer('M-GENERATE-READERS-EXCLUDE-EACH-OTHER')
	public function testALiveReaderDoesNotBlockACurrentGeneration(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		OracleGeneration.prepare([config]);
		OracleGeneration.release([config]);
		final lock: String = lockOf(config);
		final other: Dynamic = js.node.ChildProcess.spawn('sleep', ['30']);
		holdAsReader(lock, other.pid, OracleGenerationLock.startTime(other.pid));
		final started: Float = Date.now().getTime();
		final ready: Array<OracleConfig> = OracleGeneration.prepare([config], 3000).oracles;
		final spent: Float = Date.now().getTime() - started;
		other.kill();
		Assert.isNull(ready[0].unavailable, 'the current generation is usable beside another reader');
		Assert.isTrue(spent < 2000, 'without waiting for it: ${spent} ms');
		Assert.equals(1, runs(dir), 'and nothing regenerated');
		CliFixture.removeDir(lock);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A regeneration waits for every OTHER live run still compiling the group, and gives up at the deadline. */
	@:pin('control')
	@:killer('M-GENERATE-WRITER-IGNORES-READERS')
	public function testALiveReaderHoldsOffARegeneration(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		final lock: String = lockOf(config);
		final other: Dynamic = js.node.ChildProcess.spawn('sleep', ['30']);
		holdAsReader(lock, other.pid, OracleGenerationLock.startTime(other.pid));
		final ready: Array<OracleConfig> = OracleGeneration.prepare([config], 300).oracles;
		other.kill();
		Assert.isTrue((ready[0].unavailable ?? '').contains('still compiling'), 'the reader is waited for: ${ready[0].unavailable}');
		Assert.equals(0, runs(dir), 'and its tree was not regenerated under it');
		CliFixture.removeDir(lock);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A writer whose owner file is still empty (between its `mkdir` and its write) is not abandoned inside the grace. */
	@:pin('control')
	@:killer('M-GENERATE-OWNERLESS-ABANDONED-AT-ONCE')
	public function testAHalfWrittenOwnerIsNotTakenOver(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		final lock: String = lockOf(config);
		FileSystem.createDirectory('$lock/writer');
		File.saveContent('$lock/writer/owner', '');
		final ready: Array<OracleConfig> = OracleGeneration.prepare([config], 300).oracles;
		Assert.notNull(ready[0].unavailable, 'the fresh writer is waited for');
		Assert.equals(0, runs(dir), 'and nothing was generated past it');
		CliFixture.removeDir(lock);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/**
	 * Two runs that judged the same owner dead cannot both take over: the one that comes second, after the first already
	 * took the lock and a new writer holds it, leaves that writer alone.
	 */
	@:pin('control')
	@:killer('M-GENERATE-TAKEOVER-UNVERIFIED')
	public function testOnlyOneRunTakesOverADeadLock(): Void {
		#if nodejs
		final dir: String = fixture();
		final lock: String = lockOf(entry(dir, WRITE, ['$dir/input.txt']));
		holdAsWriter(lock, exitedPid(), '');
		final seen: Null<LockOwner> = OracleGenerationLock.writerOf(lock);
		Assert.isTrue(seen?.abandoned == true, 'the owner is dead');
		Assert.isTrue(seen != null && OracleGenerationLock.takeOver(lock, seen), 'the first run takes over');
		final other: Dynamic = js.node.ChildProcess.spawn('sleep', ['30']);
		holdAsWriter(lock, other.pid, OracleGenerationLock.startTime(other.pid));
		Assert.isFalse(seen != null && OracleGenerationLock.takeOver(lock, seen), 'the second, acting on the same dead owner, loses');
		Assert.equals(other.pid, OracleGenerationLock.writerOf(lock)?.pid, 'and the new writer still holds the lock');
		other.kill();
		CliFixture.removeDir(lock);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A live pid that started at another time than its owner file says is a reused pid: that owner is gone. */
	@:pin('control')
	@:killer('M-GENERATE-PID-ALONE')
	public function testAReusedPidDoesNotHoldTheLock(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		final lock: String = lockOf(config);
		final other: Dynamic = js.node.ChildProcess.spawn('sleep', ['30']);
		holdAsWriter(lock, other.pid, 'Thu Jan  1 00:00:00 1970');
		final ready: Array<OracleConfig> = OracleGeneration.prepare([config], 300).oracles;
		other.kill();
		Assert.isNull(ready[0].unavailable, 'the start time does not match: the lock is taken over');
		Assert.equals(1, runs(dir), 'and the generation ran');
		CliFixture.removeDir(lock);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/**
	 * A DEV install is tracked through the repository directory whose `.dev` points at it, not through the name its
	 * `haxelib.json` declares — here `my-lib` in the repository, `my_lib` in the json, as `mac-utils` / `mac_utils` in the
	 * wild. `HAXELIB_PATH` points the run at a scratch repository.
	 */
	@:pin('control')
	@:killer('M-GENERATE-REPO-DIR-FROM-NAME')
	public function testADevLibraryIsTrackedThroughItsRepositoryDirectory(): Void {
		#if nodejs
		final dir: String = fixture();
		final repo: String = CliFixture.writeTree('oraclegendevrepo', [
			{ name: '.repo-version', source: '1' },
			{ name: 'my-lib/.current', source: 'dev' }
		]);
		final lib: String = CliFixture.writeTree('oraclegendevlib', [
			{ name: 'haxelib.json', source: '{"name":"my_lib","version":"1.0.0"}' },
			{ name: 'src/Lib.hx', source: 'class Lib {}\n' }
		]);
		File.saveContent('$repo/my-lib/.dev', lib);
		final command: String = "printf '%s\\n' '-cp .' '-main Main' '-cp " + lib + "/src' > gen.hxml && echo run >> runs.txt";
		final config: OracleConfig = entry(dir, command, ['$dir/input.txt']);
		final declared: Null<String> = Sys.getEnv('HAXELIB_PATH');
		Sys.putEnv('HAXELIB_PATH', repo);
		CliFixture.always(() -> Sys.putEnv('HAXELIB_PATH', declared ?? ''), () -> {
			OracleGeneration.prepare([config]);
			OracleGeneration.prepare([config]);
			Assert.equals(1, runs(dir), 'unchanged dev state is current');
			File.saveContent('$repo/my-lib/.dev', '$lib/');
			OracleGeneration.prepare([config]);
			Assert.equals(2, runs(dir), 'repointing the dev install regenerates');
		});
		CliFixture.removeDir(lib);
		CliFixture.removeDir(repo);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/**
	 * A library the command's own run switched is not recorded as current: the version the hxml was built against is
	 * not the one on disk afterwards, so the next run regenerates.
	 */
	@:pin('control')
	@:killer('M-GENERATE-IMPLICIT-HASHED-AFTER-THE-RUN')
	public function testALibrarySwitchedDuringTheGenerationIsSeenNextRun(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final repo: String = CliFixture.writeTree('oraclegenracerepo', [
			{ name: 'mylib/.current', source: '1.0.0' },
			{ name: 'mylib/1,0,0/haxelib.json', source: '{"name":"mylib","version":"1.0.0"}' },
			{ name: 'mylib/1,0,0/src/Lib.hx', source: 'class Lib {}\n' }
		]);
		final write: String = "printf '%s\\n' '-cp .' '-main Main' '-cp " + repo + "/mylib/1,0,0/src' > gen.hxml && echo run >> runs.txt";
		OracleGeneration.prepare([entry(dir, write, ['$dir/input.txt'])]);
		final switching: OracleConfig = entry(dir, '$write && echo 1.0.1 > $repo/mylib/.current', ['$dir/input.txt']);
		OracleGeneration.prepare([switching]);
		Assert.equals(2, runs(dir), 'the changed command ran');
		OracleGeneration.prepare([switching]);
		Assert.equals(3, runs(dir), 'and its generation, raced by the library switch it made, was not taken as current');
		CliFixture.removeDir(repo);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One `prepare` reads a file once, however many generations name it. */
	@:pin('control')
	@:killer('M-GENERATE-HASH-MEMO-UNUSED')
	public function testAFileNamedByTwoGenerationsIsReadOnce(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		FileSystem.createDirectory('$dir/fonts');
		for (name in ['a', 'b', 'c']) File.saveContent('$dir/fonts/$name.ttf', name);
		final pair: Array<OracleConfig> = [
			entry(dir, WRITE, ['$dir/fonts']),
			{
				hxml: '$dir/gen2.hxml',
				dir: dir,
				defines: [],
				generate: {
					command: "printf '%s\\n' '-cp .' '-main Main' > gen2.hxml",
					root: dir,
					inputs: ['$dir/fonts'],
					probeDir: false
				}
			}
		];
		OracleGeneration.prepare(pair);
		final before: Int = OracleGeneration.hashReads;
		OracleGeneration.prepare(pair);
		Assert.equals(5, OracleGeneration.hashReads - before, 'three fonts once, and each hxml: 3 + 2 reads, not 3 + 1 + 3 + 1');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if nodejs
	/** The generation lock of `config`'s group. */
	private static function lockOf(config: OracleConfig): String {
		return OracleGeneration.lockDir(OracleGeneration.groupsOf([config])[0]);
	}

	/** Stand `pid` / `start` in as the exclusive holder of `lock`, as another run would. */
	private static function holdAsWriter(lock: String, pid: Null<Int>, start: String): Void {
		FileSystem.createDirectory('$lock/writer');
		File.saveContent('$lock/writer/owner', '$pid\n$start\n${Date.now().getTime()}');
	}

	/** Stand `pid` / `start` in as a shared holder of `lock`. */
	private static function holdAsReader(lock: String, pid: Null<Int>, start: String): Void {
		FileSystem.createDirectory('$lock/readers');
		File.saveContent('$lock/readers/$pid', start);
	}

	/** The pid of a process that has already exited. */
	private static function exitedPid(): Null<Int> {
		final gone: Dynamic = js.node.ChildProcess.spawnSync('sh', ['-c', "echo $$"]);
		return Std.parseInt(Std.string(gone.stdout).trim());
	}
	#end

	/** The `APQ_ORACLE_LOCK_WAIT` this suite found, restored after every test. */
	private var _declaredLockWait: Null<String> = null;

	/** A lock nobody releases fails a test in seconds, not after the ten-minute production wait. */
	public function setup(): Void {
		_declaredLockWait = Sys.getEnv('APQ_ORACLE_LOCK_WAIT');
		Sys.putEnv('APQ_ORACLE_LOCK_WAIT', '5000');
	}

	public function teardown(): Void {
		Sys.putEnv('APQ_ORACLE_LOCK_WAIT', _declaredLockWait ?? '');
	}

	/**
	 * An hxml the generation itself writes and includes (lime's iOS `Build.hxml`) is an OUTPUT, not an input that moved
	 * while the command ran: the generation that rewrote it is recorded, and the next run finds it current.
	 */
	@:pin('control')
	@:killer('M-GENERATE-PRODUCED-INCLUDE-IS-INPUT')
	public function testAnHxmlTheGenerationWritesIsNotARacedInput(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final command: String = "echo run >> runs.txt && printf '%s\\n' \"-D n$(wc -l < runs.txt | tr -d ' ')\" > inc.hxml"
			+ " && printf '%s\\n' '-cp .' '-main Main' 'inc.hxml' > gen.hxml";
		final config: OracleConfig = entry(dir, command, ['$dir/input.txt']);
		OracleGeneration.prepare([config]);
		File.saveContent('$dir/input.txt', 'two');
		OracleGeneration.prepare([config]);
		Assert.equals(2, runs(dir), 'the changed input regenerated, rewriting the included hxml');
		OracleGeneration.prepare([config]);
		Assert.equals(2, runs(dir), 'and that generation was recorded: nothing moved under it but its own output');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two runs that both find two generations stale finish in about one generation's time, both with every
	 * configuration usable: waits happen in one global order and nothing is held across groups while judging, so neither
	 * run can hold what the other waits for. Two child processes of this binary are the two runs (`testkit.TestChild`).
	 */
	@:pin('control')
	@:killer('M-GENERATE-SHARED-HELD-INTO-PHASE-TWO')
	public function testTwoRunsOverTwoStaleGenerationsDoNotDeadlock(): Void {
		#if nodejs
		final dir: String = fixture();
		final configs: Array<OracleConfig> = [
			for (name in ['g1', 'g2'])
				{
					hxml: '$dir/$name.hxml',
					dir: dir,
					defines: [],
					generate: {
						command: "sleep 1 && printf '%s\\n' '-cp .' '-main Main' > " + name + ".hxml && echo run >> runs.txt",
						root: dir,
						inputs: ['$dir/$name.input'],
						probeDir: false
					}
				}
		];
		// Each generation already ran once and its (large) input then changed: judging it hashes that input under the
		// shared hold, which keeps both runs judging long enough to overlap — the window the deadlock needs.
		for (name in ['g1', 'g2']) js.node.ChildProcess.spawnSync('dd', ['if=/dev/zero', 'of=$dir/$name.input', 'bs=1048576', 'count=64']);
		OracleGeneration.prepare(configs);
		OracleGeneration.release(configs);
		for (name in ['g1', 'g2']) js.Syntax.code("require('fs').appendFileSync({0}, 'x')", '$dir/$name.input');
		File.saveContent('$dir/configs.json', haxe.Json.stringify(configs));
		final child: String = 'APQ_TEST_CHILD=prepare APQ_TEST_CHILD_INPUT=$dir/configs.json APQ_ORACLE_LOCK_WAIT=10000 '
			+ '"${js.Node.process.execPath}" "${js.Syntax.code('process.argv[1]')}"';
		final started: Float = Date.now().getTime();
		final children: Array<HaxeRun> = HaxeSpawn.runAll([
			{ args: [], cwd: dir, shell: 'APQ_TEST_CHILD_OUTPUT=$dir/a.json $child' },
			{ args: [], cwd: dir, shell: 'APQ_TEST_CHILD_OUTPUT=$dir/b.json $child' }
		], 1024 * 1024, 2);
		final spent: Float = Date.now().getTime() - started;
		for (run in children) Assert.equals(0, run.status, 'each run completed: ${run.err}');
		if (children.exists(run -> run.status != 0)) {
			CliFixture.removeDir(dir);
			return;
		}
		final answers: String = File.getContent('$dir/a.json') + File.getContent('$dir/b.json');
		Assert.equals('[null,null][null,null]', answers, 'no configuration was lost to a lock');
		Assert.isTrue(spent < 8000, 'and neither run waited for the other\'s deadline: $spent ms');
		Assert.equals(4, runs(dir), 'each generation ran once more, for both runs');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/**
	 * A takeover claim left by a run that died mid-takeover is cleared, not spun on: the next run takes the dead
	 * writer over well inside the grace period.
	 */
	@:pin('control')
	@:killer('M-GENERATE-CLAIM-NEVER-CLEARED')
	public function testALeftoverTakeoverClaimIsCleared(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		final lock: String = lockOf(config);
		final dead: Null<Int> = exitedPid();
		holdAsWriter(lock, dead, '');
		final stale: Null<LockOwner> = OracleGenerationLock.writerOf(lock);
		final claim: String = '$lock/takeover-${haxe.crypto.Md5.encode(stale?.identity ?? '')}';
		FileSystem.createDirectory(claim);
		File.saveContent('$claim/owner', '$dead\n\n${Date.now().getTime()}');
		final started: Float = Date.now().getTime();
		final ready: Array<OracleConfig> = OracleGeneration.prepare([config], 5000).oracles;
		Assert.isNull(ready[0].unavailable, 'the dead claim was cleared and the writer taken over');
		Assert.isTrue(Date.now().getTime() - started < 3000, 'at once, not at the deadline');
		Assert.equals(1, runs(dir), 'and the generation ran');
		CliFixture.removeDir(lock);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/**
	 * A takeover ends the generation job the dead run left: its process group is killed before the writer is removed,
	 * so the dead run's build tool cannot write on into the tree the next generation owns. The job here is a group
	 * leader outside this process's children, as a dead run's would be.
	 */
	@:pin('control')
	@:killer('M-GENERATE-TAKEOVER-LEAVES-THE-JOB')
	public function testATakeOverEndsTheJobTheDeadRunLeft(): Void {
		#if nodejs
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		final lock: String = lockOf(config);
		holdAsWriter(lock, exitedPid(), '');
		final started: Dynamic = js.node.ChildProcess.spawnSync(
			'sh', ['-c', "perl -e 'setpgrp(0, 0); exec q(sleep), 30' >/dev/null 2>&1 & echo $!"], { encoding: 'utf8' }
		);
		final job: Null<Int> = Std.parseInt(StringTools.trim('${started.stdout}'));
		Assert.notNull(job, 'the left-over job runs');
		js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200)');
		File.saveContent('$lock/writer/job', '$job\n${job == null ? '' : OracleGenerationLock.startTime(job)}');
		OracleGeneration.prepare([config], 5000);
		final alive: Bool = job != null && OracleGenerationLock.startTime(job) != '';
		if (alive && job != null) js.Syntax.code('process.kill({0}, "SIGKILL")', job);
		Assert.isFalse(alive, 'the dead run\'s job was ended by the takeover');
		CliFixture.removeDir(lock);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A record written under an older record scheme is never current. */
	@:pin('control')
	@:killer('M-GENERATE-FORMAT-UNCHECKED')
	public function testARecordOfAnOlderSchemeIsStale(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final config: OracleConfig = entry(dir, WRITE, ['$dir/input.txt']);
		OracleGeneration.prepare([config]);
		final record: String = OracleGeneration.recordFile(OracleGeneration.groupsOf([config])[0]);
		final held: Dynamic = haxe.Json.parse(File.getContent(record));
		held.format = 'apq-oracle-generate v1';
		File.saveContent(record, haxe.Json.stringify(held));
		OracleGeneration.prepare([config]);
		Assert.equals(2, runs(dir), 'the v1 record was not trusted');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * An included hxml OUTSIDE the output tree of the hxml that includes it is an input like any other: one that moved
	 * while the command ran leaves the generation unrecorded. Only the output tree itself is the command's to write.
	 */
	@:pin('control')
	@:killer('M-GENERATE-PRODUCED-BY-ROOT')
	public function testAnIncludeOutsideTheHxmlTreeIsAnInput(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		File.saveContent('$dir/extra.hxml', '-D a\n');
		final write: String = "mkdir -p out && printf '%s\\n' '-cp .' '-main Main' 'extra.hxml' > out/gen.hxml && echo run >> runs.txt";
		inline function at(command: String): OracleConfig {
			return {
				hxml: '$dir/out/gen.hxml',
				dir: dir,
				defines: [],
				generate: {
					command: command,
					root: dir,
					inputs: ['$dir/input.txt'],
					probeDir: false
				}
			};
		}
		OracleGeneration.prepare([at(write)]);
		final editing: OracleConfig = at(write + " && echo '-D b' > extra.hxml");
		OracleGeneration.prepare([editing]);
		Assert.equals(2, runs(dir), 'the changed command ran and edited the include');
		OracleGeneration.prepare([editing]);
		Assert.equals(3, runs(dir), 'so that generation was not recorded: the include moved under it');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
