package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.query.Cli;
import haxe.Exception;
import haxe.io.Path;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * Two commands that used to answer one worker with another worker's data, because the
 * path they read or staged into was named once for the whole machine.
 *
 * This is the same defect class S170 closed for `apq probe` (T700), in the two other
 * commands that carried it, and the reason it is worth its own suite is that neither
 * failure has a symptom: both processes exit 0 and both answers look right.
 *
 *  1. `apq test-summary` with no positional source read the constant `/tmp/test.out`.
 *     Measured on the pre-fix binary, two workers each writing their own suite log
 *     there and each summarising it, 12 interleaved rounds: one read a transcript it
 *     had not written 7 times, the other 6, every one at exit 0 — and in one round
 *     BOTH read a TORN interleave (`6 tests / 5 assertions`) that neither had written.
 *     The fix is NOT a per-process path: a transcript is written by a different
 *     process, so nothing this one knows about itself can name it. `$APQ_TEST_OUT` or
 *     a usage error.
 *  2. `apq stdlib-dup` staged its generated probe as `<temp root>/apq-stdlib-dup/Probe.hx`
 *     — one directory and one fixed module name for the machine — and then spawned
 *     `haxe -cp <dir> --run Probe`. Two runs race between the write and the spawn.
 *     Measured, two one-candidate scopes, 12 rounds: both processes reported IDENTICAL
 *     findings every round, 7 of 12 wrong for one and 5 of 12 for the other, one of
 *     them naming `StringTools.endsWith` for a begins-with function and claiming
 *     agreement on 484 generated inputs. The work directory is per process now.
 *
 * `$TMPDIR` is NOT what separates two workers and no fixture here may assume it is: on
 * macOS every process of one user inherits the same `/var/folders/…/T` (verified equal to
 * `getconf DARWIN_USER_TEMP_DIR`), so the child-process fixtures hand both children ONE
 * root on purpose.
 */
@:nullSafety(Strict)
class ApqScratchPathCliTest extends Test {

	/** The env var `apq test-summary` reads when no positional source is given. */
	private static inline final TRANSCRIPT_ENV: String = 'APQ_TEST_OUT';

	/** The half of the stdlib-dup work directory's name that is a contract. */
	private static inline final WORK_DIR_STEM: String = 'apq-stdlib-dup';

	/** What the stdlib-dup run prints before the directory it staged into. */
	private static inline final WORK_DIR_MARKER: String = 'staging probes in ';

	/** A scope with no candidate at all, so the run resolves its work directory and spawns no compiler. */
	private static inline final NO_CANDIDATE_SOURCE: String = 'class NoCandidate {\n\tpublic var x: Int = 1;\n}\n';

	/** What a symlinked staging target must still hold after a refused run. */
	private static inline final VICTIM_CONTENT: String = 'ORIGINAL VICTIM CONTENT\n';

	/**
	 * No positional and no `$TRANSCRIPT_ENV` is a USAGE error, not a fallback.
	 *
	 * The fallback is the whole defect: a path default here can only ever be a constant,
	 * since the file is written by a different process, and a constant is what handed one
	 * worker another's transcript.
	 */
	@:pin('control')
	@:killer('M-TEST-SUMMARY-GLOBAL-DEFAULT')
	public function testTestSummaryWithoutASourceOrTheEnvVarIsAUsageError(): Void {
		#if (sys || nodejs)
		final stash: Null<String> = Sys.getEnv(TRANSCRIPT_ENV);
		var code: Int = -1;
		var err: String = '';
		var raised: Null<Exception> = null;
		try {
			Sys.putEnv(TRANSCRIPT_ENV, null);
			// Captured rather than printed: the refusal is three lines, and the suite's own
			// transcript is what `apq test-summary` is later asked to count.
			err = CliFixture.captureStderr(() -> code = Cli.run(['test-summary']));
		} catch (exception: Exception) {
			raised = exception;
		}
		Sys.putEnv(TRANSCRIPT_ENV, stash);
		if (raised != null) throw raised;
		Assert.equals(2, code, 'no source and no $TRANSCRIPT_ENV must be a usage error, never a machine-global default');
		Assert.isTrue(err.indexOf(TRANSCRIPT_ENV) != -1, 'and the refusal must name the env var, got: $err');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `$TRANSCRIPT_ENV` names the transcript, and the counts line names it back.
	 *
	 * Asserting the PATH in the output as well as the counts is what makes this
	 * discriminate: a machine-global default reachable at the same moment would still
	 * produce a plausible counts line, and only the source it names says which file
	 * answered.
	 */
	@:pin('control')
	@:killer('M-TEST-SUMMARY-GLOBAL-DEFAULT')
	public function testTestSummaryReadsTheTranscriptTheEnvVarNames(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.writeAs('scratch_transcript', 'log', '  testAlpha: OK .\n  testBeta: OK .\n  testGamma: OK .\n');
		final stash: Null<String> = Sys.getEnv(TRANSCRIPT_ENV);
		var code: Int = -1;
		var out: String = '';
		var raised: Null<Exception> = null;
		try {
			Sys.putEnv(TRANSCRIPT_ENV, path);
			out = CliFixture.captureStdout(() -> code = Cli.run(['test-summary']));
		} catch (exception: Exception) {
			raised = exception;
		}
		Sys.putEnv(TRANSCRIPT_ENV, stash);
		FileSystem.deleteFile(path);
		if (raised != null) throw raised;
		Assert.equals(0, code, 'the env-named transcript is read');
		Assert.isTrue(out.indexOf('3 tests / 3 assertions') != -1, 'the counts come from the env-named transcript, got: $out');
		Assert.isTrue(out.indexOf(path) != -1, 'and the report names the file it actually read, got: $out');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The stdlib-dup work directory carries this process's own id, so a second run cannot
	 * land its `Probe.hx` in the window between this one's write and its `haxe --run`.
	 *
	 * The assertion is on the STEM plus something after it, never on a whole path: the
	 * name past the stem belongs to the resolver, and spelling it here would pin the
	 * implementation instead of the property.
	 */
	@:pin('control')
	@:killer('M-STDLIB-DUP-WORKDIR-SHARED')
	public function testStdlibDupStagesItsProbesInAPerProcessDirectory(): Void {
		#if (sys || nodejs)
		final scope: String = CliFixture.writeDir('scratch_dup_scope', [{ name: 'NoCandidate.hx', source: NO_CANDIDATE_SOURCE }]);
		final root: String = CliFixture.writeDir('scratch_dup_root', []);
		final announced: String = stdlibDupWorkDirUnder(root, scope);
		Assert.equals(root, Path.directory(announced), 'the work directory sits under the temp root the run was handed, got $announced');
		final name: String = Path.withoutDirectory(announced);
		Assert.isTrue(name.startsWith('$WORK_DIR_STEM.'), 'and its name is the stem plus this process\'s own id, got "$name"');
		Assert.notEquals(WORK_DIR_STEM, name, 'the bare stem is the machine-global name two runs raced over');
		CliFixture.removeDir(announced);
		CliFixture.removeDir(root);
		CliFixture.removeDir(scope);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A work directory that is a SYMLINK is refused, not adopted.
	 *
	 * `FileSystem.exists` follows the link, so without the guard the run stages its probe
	 * through it AND — new in S171 — deletes every non-directory entry of whatever it points
	 * at when the run ends. The sibling command grew this guard in S170
	 * (`ProbeCommand.isStageTargetSafe`); this is the same one, and the victim file is what
	 * makes the fixture discriminate: under `M-STDLIB-DUP-WORK-ANY-TARGET` the link is
	 * adopted and `keepme.txt` is gone.
	 */
	@:pin('control')
	@:killer('M-STDLIB-DUP-WORK-ANY-TARGET')
	public function testStdlibDupRefusesAWorkDirectoryThatIsASymlink(): Void {
		#if nodejs
		final victim: String = CliFixture.writeDir('scratch_dup_victim', [{ name: 'keepme.txt', source: VICTIM_CONTENT }]);
		final scope: String = CliFixture.writeDir('scratch_dup_link_scope', [{ name: 'NoCandidate.hx', source: NO_CANDIDATE_SOURCE }]);
		final planted: String = '$victim.link';
		js.node.Fs.symlinkSync(victim, planted);
		final err: String = CliFixture.captureStderr(
			() -> Assert.equals(1, Cli.run(['stdlib-dup', scope, '--work', planted]), 'the run refuses rather than staging')
		);
		Assert.isTrue(err.indexOf('is not a real directory') != -1, 'the refusal must say why, got: $err');
		Assert.equals(VICTIM_CONTENT, File.getContent('$victim/keepme.txt'), 'staging must not reach through the link');
		FileSystem.deleteFile(planted);
		CliFixture.removeDir(victim);
		CliFixture.removeDir(scope);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/**
	 * Three `test-summary` PROCESSES under ONE shared temp root: two handed their own
	 * transcript read their own, and one handed none refuses instead of reaching for a
	 * machine-global file.
	 *
	 * `guard`, not `control`, for TWO independent reasons and either alone is enough. The
	 * one S170 recorded: `mutation-check.sh` builds an arm's worktree with
	 * `worker-build.sh <dir> test` — the runner only — and `bin/` is gitignored, so the
	 * fresh worktree has no `bin/apq.js` and this method takes its not-built branch. The
	 * one it did not: even WITH an engine there a child runs a PRE-BUILT binary, so a cut
	 * to `src/` could not reach it anyway. The two in-process fixtures above are what kill
	 * `M-TEST-SUMMARY-GLOBAL-DEFAULT`; this one is what proves the fix end to end.
	 *
	 * `engineOrSkip` names `bin/apq.js` and deliberately does NOT honour `$HXQ_BIN`: in an
	 * arm's harness that variable points at the UNMUTATED engine, so honouring it would make
	 * the fixture do real work against the wrong binary and report it as a pass.
	 */
	@:pin('guard')
	public function testThreeTestSummaryProcessesUnderOneTempRootEachAnswerFromTheirOwnSource(): Void {
		#if nodejs
		final engine: Null<String> = engineOrSkip();
		if (engine == null) return;
		final shared: String = CliFixture.writeDir('scratch_ts_shared', [
			{ name: 'a.log', source: '  testA1: OK .\n  testA2: OK .\n' },
			{ name: 'b.log', source: '  testB1: OK .\n  testB2: OK .\n  testB3: OK .\n  testB4: OK .\n' }
		]);
		final a: js.node.ChildProcess.ChildProcessSpawnSyncResult = spawnTestSummary(engine, shared, '$shared/a.log');
		final b: js.node.ChildProcess.ChildProcessSpawnSyncResult = spawnTestSummary(engine, shared, '$shared/b.log');
		final none: js.node.ChildProcess.ChildProcessSpawnSyncResult = spawnTestSummary(engine, shared, null);
		Assert.equals(0, a.status, 'the first process exits clean');
		Assert.equals(0, b.status, 'the second process exits clean');
		Assert.isTrue(text(a.stdout).indexOf('2 tests / 2 assertions') != -1, 'the first reads its OWN transcript, got: ${text(a.stdout)}');
		Assert.isTrue(
			text(b.stdout).indexOf('4 tests / 4 assertions') != -1, 'the second reads its OWN transcript, got: ${text(b.stdout)}'
		);
		Assert.equals(2, none.status, 'a process handed no source refuses rather than reading a machine-global file');
		Assert.isTrue(text(none.stderr).indexOf(TRANSCRIPT_ENV) != -1, 'and the refusal names the env var, got: ${text(none.stderr)}');
		CliFixture.removeDir(shared);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/**
	 * Two `stdlib-dup` PROCESSES under ONE shared temp root stage into two directories.
	 *
	 * One root on purpose: that is the shape the campaign runs in, and a temp-root base
	 * separates nothing there. `guard` for the same reason as the fixture above.
	 */
	@:pin('guard')
	public function testTwoStdlibDupProcessesUnderOneTempRootGetSeparateWorkDirectories(): Void {
		#if nodejs
		final engine: Null<String> = engineOrSkip();
		if (engine == null) return;
		final shared: String = CliFixture.writeDir('scratch_dup_shared', []);
		final scope: String = CliFixture.writeDir('scratch_dup_child_scope', [{ name: 'NoCandidate.hx', source: NO_CANDIDATE_SOURCE }]);
		final first: String = announcedWorkDir(spawnStdlibDup(engine, shared, scope));
		final second: String = announcedWorkDir(spawnStdlibDup(engine, shared, scope));
		Assert.notEquals(first, second, 'one shared temp root must still give two runs two work directories (got "$first" twice)');
		Assert.equals(shared, Path.directory(first), 'and both sit under the root they were handed, got $first');
		Assert.equals(shared, Path.directory(second), 'and both sit under the root they were handed, got $second');
		CliFixture.removeDir(shared);
		CliFixture.removeDir(scope);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	#if (sys || nodejs)
	/** Run `stdlib-dup` in-process with `root` as the temp root and return the directory it announced. */
	private function stdlibDupWorkDirUnder(root: String, scope: String): String {
		final tmpStash: Null<String> = Sys.getEnv('TMPDIR');
		final tempStash: Null<String> = Sys.getEnv('TEMP');
		var err: String = '';
		var raised: Null<Exception> = null;
		try {
			Sys.putEnv('TMPDIR', root);
			Sys.putEnv('TEMP', root);
			err = CliFixture.captureStderr(() -> Assert.equals(0, Cli.run(['stdlib-dup', scope]), 'stdlib-dup exits clean'));
		} catch (exception: Exception) {
			raised = exception;
		}
		Sys.putEnv('TMPDIR', tmpStash);
		Sys.putEnv('TEMP', tempStash);
		if (raised != null) throw raised;
		// The scope being candidate-free is what keeps a COMPILER out of the suite:
		// `StdlibDifferential.interpret` spawns `haxe` per candidate with a 300 000 ms
		// timeout. Nothing else here would notice a scan change that starts finding one —
		// the fixture would simply get slow, with no line saying why.
		Assert.isTrue(
			err.indexOf('drove 0 candidate(s)') != -1,
			'the fixture scope must stay candidate-free so no haxe is spawned inside the suite, got: $err'
		);
		return afterMarker(err, WORK_DIR_MARKER);
	}

	/** The rest of the first line carrying `marker`, or `''` (with the failure recorded) when there is none. */
	private function afterMarker(transcript: String, marker: String): String {
		final at: Int = transcript.indexOf(marker);
		if (at < 0) {
			Assert.fail('the run must announce its work directory, got: $transcript');
			return '';
		}
		final rest: String = transcript.substr(at + marker.length);
		final eol: Int = rest.indexOf('\n');
		return eol < 0 ? rest.trim() : rest.substr(0, eol).trim();
	}
	#end

	#if nodejs
	/**
	 * `bin/apq.js`, or null after passing. A child-process fixture needs the CLI as a
	 * process, and `haxe test-js.hxml` alone does not build one — an arm's worktree in
	 * particular never has it, which is why these fixtures are `guard` rather than `control`.
	 */
	private function engineOrSkip(): Null<String> {
		final engine: String = 'bin/apq.js';
		if (FileSystem.exists(engine)) return engine;
		Assert.pass('bin/apq.js is not built — a child-process fixture needs the CLI as a process');
		return null;
	}

	/** `node bin/apq.js test-summary` under `tmpRoot`, with `$TRANSCRIPT_ENV` set to `transcript` or cleared. */
	private function spawnTestSummary(
		engine: String, tmpRoot: String, transcript: Null<String>
	): js.node.ChildProcess.ChildProcessSpawnSyncResult {
		return spawn(engine, ['test-summary'], tmpRoot, TRANSCRIPT_ENV, transcript);
	}

	/** `node bin/apq.js stdlib-dup <scope>` under `tmpRoot`. */
	private function spawnStdlibDup(engine: String, tmpRoot: String, scope: String): js.node.ChildProcess.ChildProcessSpawnSyncResult {
		return spawn(engine, ['stdlib-dup', scope], tmpRoot, TRANSCRIPT_ENV, null);
	}

	/**
	 * One CLI child with `TMPDIR` / `TEMP` overridden and one env var either set or DELETED.
	 *
	 * Deleted rather than left alone: a value inherited from the suite process would answer
	 * the child that is meant to have none, and the fixture would then pass for a reason
	 * unrelated to what it asserts.
	 */
	private function spawn(
		engine: String, argv: Array<String>, tmpRoot: String, key: String, value: Null<String>
	): js.node.ChildProcess.ChildProcessSpawnSyncResult {
		final env: Any = {};
		for (name => existing in Sys.environment()) Reflect.setField(env, name, existing);
		Reflect.setField(env, 'TMPDIR', tmpRoot);
		Reflect.setField(env, 'TEMP', tmpRoot);
		if (value != null)
			Reflect.setField(env, key, value)
		else
			Reflect.deleteField(env, key);
		return js.node.ChildProcess.spawnSync('node', [engine].concat(argv), cast { encoding: 'utf8', env: env });
	}

	/** The work directory a child announced, and a removal of it so the fixture leaves nothing behind. */
	private function announcedWorkDir(result: js.node.ChildProcess.ChildProcessSpawnSyncResult): String {
		Assert.equals(0, result.status, 'the stdlib-dup child exits clean');
		final dir: String = afterMarker(text(result.stderr), WORK_DIR_MARKER);
		if (dir != '') CliFixture.removeDir(dir);
		return dir;
	}

	/** A spawn stream field (Buffer or String under utf8) as a String. */
	private function text(value: Dynamic): String { // noqa: avoid-dynamic
		return value == null ? '' : '$value';
	}
	#end

}
