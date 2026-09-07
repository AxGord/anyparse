package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * End-to-end probes for the DX Tier-5 batch — six hxq usability wins
 * collected from a Slice-51 retrospective:
 *  1. `refs`/`uses` 0-hit + lowercase camelCase name → sniff
 *     `src/anyparse/macro/*.hx` for a `<name>Field` Field-builder; when
 *     found, append a "macro-emitted helper" hint pointing at the
 *     emit site. Closes the trap where searching for `peekKw` /
 *     `matchLit` / etc. in `src/anyparse/runtime/` returns 0 because
 *     those names live as String literals inside `Codegen` builders.
 *  2. `apq ast --select` 0-match + TypeName-shaped first kind token →
 *     append a cross-project hint (`refs --decls src/` / `uses` /
 *     `blast`) since `ast` is single-file by design and the user is
 *     likely hunting a decl that lives in a different module.
 *  3. `apq probe` always stages the source bytes to a scratch slot so a
 *     follow-up `strip` / `recon --probe` / `writer-equals` can target them
 *     without re-heredoc-ing, and prints the RESOLVED path. Stdin source
 *     path also stages (avoids a second stdin read). Since S170 the slot is
 *     `$APQ_PROBE_PATH`, else `<temp root>/anyparse-last-probe.<pid>.hx` —
 *     it used to be one hard-coded `/tmp` path for the whole machine, which
 *     handed a second worker's source to the first one's `strip` (T700).
 *  4. `ANYPARSE_HXFORMAT_FORK` persistent cache — `defaultReconRoot`
 *     writes the env-supplied path to `~/.config/anyparse/fork_path`
 *     on every successful resolution AND falls back to that cache when
 *     the env is unset. Env always wins; stale cached paths (no longer
 *     a directory) drop silently.
 *  5. `apq self-status --source` — mirror `recon --probe --source`,
 *     append a `:: src="<window>"` tail with the bytes around each
 *     skip-parse fail-locus. Same output shape as the recon family.
 *  6. `apq sweep` / `apq test-summary` emit a stderr WARNING when any
 *     `.hx` under `src/` or `test/` is newer than `bin/test.js` —
 *     closes the documented `[[feedback-rebuild-test-js-after-macro-edit]]`
 *     trap where a stale `bin/test.js` reports a 0-delta sweep that the
 *     user might trust.
 */
@:nullSafety(Strict)
class ApqDxTier5CliTest extends Test {

	/** The half of the staging slot's name that is a contract; the rest belongs to the resolver. */
	private static inline final PROBE_SLOT_STEM: String = 'anyparse-last-probe';

	/** The env var that names the staging slot outright. */
	private static inline final PROBE_PATH_ENV: String = 'APQ_PROBE_PATH';

	/** What a symlinked staging target must still hold after a probe. */
	private static inline final VICTIM_CONTENT: String = 'ORIGINAL VICTIM CONTENT\n';

	// --- 1. refs/uses macro-emit nudge ---

	public function testRefsRuntimeHelperZeroHitExitsClean(): Void {
		// Searching for a macro-emitted runtime helper inside
		// `src/anyparse/runtime/` (where the helper does NOT have a
		// value-binding — the FFun is built by `Codegen.peekKwField`)
		// returns 0 hits. The nudge sniffs `src/anyparse/macro/` and
		// appends a "macro-emitted helper" hint. Exit stays clean (0 is
		// the contract for walker subcommands with 0 hits).
		Assert.equals(0, Cli.run(['refs', 'peekKw', 'src/anyparse/runtime/']), 'refs on macro-emitted helper exits clean even with 0 hits');
	}

	public function testRefsUnknownLowercaseNameStillExitsClean(): Void {
		// Sniff has no match — the name is not a macro-emitted helper.
		// Output should still be valid (no crash, exit 0). The hint
		// silently drops to the existing lowercase nudge.
		Assert.equals(
			0, Cli.run(['refs', 'no_such_macro_helper_zzz', 'src/anyparse/runtime/']),
			'refs on a non-macro lowercase name exits clean without crashing'
		);
	}

	// --- 2. ast --select cross-project hint ---

	public function testAstSelectTypeNameNoMatchExitsClean(): Void {
		// `HxCatchClause` is a typedef declared in a different file —
		// `ast --select` on a single file where the kind is not present
		// surfaces "Kinds present here: …" plus the new cross-project
		// hint. Exit stays clean (the walker is read-only).
		Assert.equals(0, Cli.run([
			'probe',
			'class C {}',
			'--select',
			'HxCatchClause'
		]), 'ast --select on a TypeName not present in source exits clean');
	}

	public function testAstSelectLowercaseSelectorStillExitsClean(): Void {
		// Lowercase selector — the cross-project hint stays silent
		// (field-shape, not a TypeName). The existing kinds-present
		// fallback fires.
		Assert.equals(0, Cli.run([
			'probe',
			'class C {}',
			'--select',
			'unknownField'
		]), 'ast --select on a lowercase token exits clean with kinds-present fallback');
	}

	// --- 5. self-status --source ---

	public function testSelfStatusUnknownFlagStillRejected(): Void {
		Assert.equals(2, Cli.run(['self-status', '--bogus']), 'self-status rejects unknown flags as usage error');
	}

	#if (sys || nodejs)
	public function testSelfStatusSourceFlagAccepted(): Void {
		// `--source` parses as a known flag and the walk covers the <dir> it
		// is given. This used to walk the project's whole `src/` to assert
		// one exit code, which made it the most expensive method in the
		// suite. `--strict` is what proves the walk really visited THIS
		// fixture: the exit flips only because `Broken.hx` was counted as
		// skip-parse, which neither an empty nor a wrong directory produces.
		final dir: String = CliFixture.writeDir('self_status', [
			{ name: 'Good.hx', source: 'class Good {}\n' },
			{ name: 'Broken.hx', source: 'class Broken { var x: }\n' }
		]);
		Assert.equals(0, Cli.run(['self-status', dir, '--source']), 'self-status --source is a known flag');
		Assert.equals(
			1, Cli.run(['self-status', dir, '--source', '--strict']), 'self-status --strict exits non-zero on the fixture skip-parse'
		);
		CliFixture.removeDir(dir);
	}

	/**
	 * `self-status` was the one multi-file walker that refused a second
	 * positional (`only one positional <dir> supported`), so `src test` had to
	 * be two runs. It now goes through `resolveInputPaths` like `fmt` and the
	 * rest: several specs, each a file / dir / glob, deduped and unioned. The
	 * `--strict` exit is the proof BOTH dirs were walked — the skip-parse
	 * fixture lives in the second one, and a run that stopped at the first
	 * would exit 0.
	 */
	public function testSelfStatusAcceptsSeveralPositionals(): Void {
		final good: String = CliFixture.writeDir('self_status_multi_a', [{ name: 'Good.hx', source: 'class Good {}\n' }]);
		final bad: String = CliFixture.writeDir('self_status_multi_b', [{ name: 'Broken.hx', source: 'class Broken { var x: }\n' }]);
		Assert.equals(0, Cli.run(['self-status', good, bad]), 'self-status accepts two positional paths');
		Assert.equals(1, Cli.run(['self-status', good, bad, '--strict']), 'the second path really was walked');
		Assert.equals(0, Cli.run(['self-status', good, '--strict']), 'the first path alone is clean');
		// A single concrete FILE is a legal spec too — the old walker required a
		// directory and answered `"<path>" is not a directory.`
		Assert.equals(0, Cli.run(['self-status', '$good/Good.hx', '--strict']), 'a single .hx file is a legal spec');
		Assert.equals(1, Cli.run(['self-status', 'no_such_dir_for_self_status']), 'a spec matching no .hx is a runtime error');
		CliFixture.removeDir(good);
		CliFixture.removeDir(bad);
	}

	// --- 3. probe staging ---
	/**
	 * The staging slot RESOLVES — it is not a constant this test may re-derive.
	 * The probe lands under whatever temp root the caller is running with, which
	 * is what makes the suite's own private root (`CliFixture.isolateTempDir`)
	 * reach it and what lets two workers stay apart; the assertion therefore
	 * names the ROOT and finds the file by its stem, never by a full path.
	 */
	@:pin('control')
	@:killer('M-PROBE-SLOT-CONST')
	public function testProbeStagesSourceUnderTheCurrentTempRoot(): Void {
		#if nodejs
		final root: String = CliFixture.writeDir('probe_stage_root', []);
		final source: String = 'class StagedProbe { var x:Int = 42; }';
		final staged: Array<String> = stagedUnder(root, [source]);
		Assert.equals(1, staged.length, 'exactly one slot under the temp root the probe was handed');
		Assert.equals(source, File.getContent('$root/${staged[0]}'), 'staged file content matches the probe source byte-for-byte');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/**
	 * Single-slot is preserved, at the scope it was always about: WITHIN one
	 * process a chained `recon --probe` targets the LAST probe, never a history.
	 * What changed is that the slot no longer spans processes.
	 */
	@:pin('control')
	@:killer('M-PROBE-SLOT-CONST')
	public function testProbeRestagingOverwritesPreviousScratch(): Void {
		#if nodejs
		final root: String = CliFixture.writeDir('probe_restage_root', []);
		final staged: Array<String> = stagedUnder(root, ['class First {}', 'class Second { var b:Bool; }']);
		Assert.equals(1, staged.length, 'a second probe reuses this process\'s slot rather than adding one');
		Assert.equals(
			'class Second { var b:Bool; }', File.getContent('$root/${staged[0]}'),
			'second probe overwrites the scratch file (single-slot by design)'
		);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/**
	 * `APQ_PROBE_PATH` names the slot outright — the escape hatch for a caller
	 * that cannot isolate its temp root — and a target that is not a regular
	 * file is REFUSED rather than written through. `File.saveContent` follows a
	 * symlink, so without the refusal a planted link under a shared temp root is
	 * a write-anywhere primitive with this process's rights.
	 */
	@:pin('control')
	@:killer('M-PROBE-STAGE-ANY-TARGET')
	public function testProbeStagingRefusesANonRegularTargetAndHonoursTheEnvPath(): Void {
		#if nodejs
		final root: String = CliFixture.writeDir('probe_env_slot', []);
		final victim: String = '$root/victim.txt';
		final slot: String = '$root/planted-slot.hx';
		final stash: Null<String> = Sys.getEnv(PROBE_PATH_ENV);
		var raised: Null<Exception> = null;
		try {
			File.saveContent(victim, VICTIM_CONTENT);
			symlink(victim, slot);
			Sys.putEnv(PROBE_PATH_ENV, slot);
			Assert.equals(0, Cli.run(['probe', 'class Attacker {}']), 'the probe still answers when staging is refused');
			Assert.equals(VICTIM_CONTENT, File.getContent(victim), 'staging must not write through a symlink');
			// Same env path, now a free name: the override itself is honoured.
			FileSystem.deleteFile(slot);
			Assert.equals(0, Cli.run(['probe', 'class Explicit {}']), 'probe exits clean with the env-named slot');
			Assert.equals('class Explicit {}', File.getContent(slot), 'APQ_PROBE_PATH names the slot outright');
		} catch (exception: Exception) {
			raised = exception;
		}
		Sys.putEnv(PROBE_PATH_ENV, stash);
		CliFixture.removeDir(root);
		if (raised != null) throw raised;
		#else
		Assert.pass('non-nodejs target');
		#end
	}
	/**
	 * Two `probe` PROCESSES, each with its own private temp root, must stage to
	 * two different files — the S150 isolation mechanism (`RunTests.main` ->
	 * `CliFixture.isolateTempDir`) applied to the probe slot. A hard-coded
	 * absolute slot makes both processes name one path, so whichever ran second
	 * owns the bytes and the first one's follow-up `strip` / `recon --probe`
	 * silently parses a source it never wrote.
	 *
	 * The assertion is on the path the probe RESOLVED and announced, never on a
	 * constant: the nudge is the only thing a caller can chain from.
	 *
	 * `guard`, not `control`, and the reason is worth knowing before you write
	 * another child-process fixture: NO source cut can kill this one.
	 * `mutation-check.sh` builds the arm's worktree with `worker-build.sh <dir>
	 * test` — the test runner only — and `bin/` is gitignored, so the fresh
	 * worktree has no `bin/apq.js` at all and this method takes its not-built
	 * branch. Measured: under `M-PROBE-SLOT-CONST` the three IN-PROCESS probe
	 * fixtures go red and this pair stays green. Those three kill the arm; this
	 * pair is what proves the fix end to end.
	 */
	@:pin('guard')
	public function testTwoProbeProcessesGetSeparateScratchSlots(): Void {
		#if nodejs
		final engine: String = 'bin/apq.js';
		if (!FileSystem.exists(engine)) {
			Assert.pass('bin/apq.js is not built — a per-process slot needs the CLI as a process');
			return;
		}
		final rootA: String = CliFixture.writeDir('probe_slot_a', []);
		final rootB: String = CliFixture.writeDir('probe_slot_b', []);
		final sourceA: String = 'class AlphaOwnedByWorkerA { var alpha:Int = 1; }';
		final sourceB: String = 'class BetaOwnedByWorkerB { var beta:Bool; }';
		final slotA: String = probeChildSlot(engine, rootA, sourceA);
		final slotB: String = probeChildSlot(engine, rootB, sourceB);
		Assert.notEquals(slotA, slotB, 'two probe processes must not name one scratch slot (got "$slotA" twice)');
		Assert.equals(sourceA, File.getContent(slotA), 'the first process reads back its OWN bytes');
		Assert.equals(sourceB, File.getContent(slotB), 'the second process reads back its OWN bytes');
		CliFixture.removeDir(rootA);
		CliFixture.removeDir(rootB);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/**
	 * The shape the campaign actually runs in: two workers share ONE `$TMPDIR`
	 * (measured — on macOS every process of one user inherits the same
	 * `/var/folders/…/T`, and no worker sets its own). A temp-root base alone
	 * therefore separates nothing; the slot name has to carry the writing
	 * process's own identity too.
	 */
	@:pin('guard')
	public function testTwoProbeProcessesUnderOneTempRootStillGetSeparateSlots(): Void {
		#if nodejs
		final engine: String = 'bin/apq.js';
		if (!FileSystem.exists(engine)) {
			Assert.pass('bin/apq.js is not built — a per-process slot needs the CLI as a process');
			return;
		}
		final shared: String = CliFixture.writeDir('probe_slot_shared', []);
		final sourceA: String = 'class AlphaSharedRoot { var alpha:Int = 1; }';
		final sourceB: String = 'class BetaSharedRoot { var beta:Bool; }';
		final slotA: String = probeChildSlot(engine, shared, sourceA);
		final slotB: String = probeChildSlot(engine, shared, sourceB);
		Assert.notEquals(slotA, slotB, 'one shared temp root must still give two processes two slots');
		Assert.equals(sourceA, File.getContent(slotA), 'the first process reads back its OWN bytes');
		Assert.equals(sourceB, File.getContent(slotB), 'the second process reads back its OWN bytes');
		CliFixture.removeDir(shared);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	/**
	 * `sys.io.File.saveContent` FOLLOWS a symlink, so a slot in a world-writable
	 * directory is a write-anywhere primitive with this process's rights. Staging
	 * refuses a target that is not a regular file and says so; the probe itself
	 * still answers.
	 */
	@:pin('guard')
	public function testProbeRefusesToStageOntoASymlink(): Void {
		#if nodejs
		final engine: String = 'bin/apq.js';
		if (!FileSystem.exists(engine)) {
			Assert.pass('bin/apq.js is not built — the refusal needs the CLI as a process');
			return;
		}
		final root: String = CliFixture.writeDir('probe_slot_symlink', []);
		final victim: String = '$root/victim.txt';
		File.saveContent(victim, 'ORIGINAL VICTIM CONTENT\n');
		final planted: String = '$root/planted-slot.hx';
		js.node.Fs.symlinkSync(victim, planted);
		final result: js.node.ChildProcess.ChildProcessSpawnSyncResult = spawnProbe(engine, root, 'class Attacker {}', planted);
		Assert.equals(0, result.status, 'the probe still answers even when staging is refused');
		Assert.equals('ORIGINAL VICTIM CONTENT\n', File.getContent(victim), 'staging must not write through a symlink');
		final err: String = result.stderr == null ? '' : Std.string(result.stderr);
		Assert.isTrue(err.indexOf('not a regular file') != -1, 'the refusal must say why, got: $err');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	// --- 4. ANYPARSE_HXFORMAT_FORK cache (write-on-resolve, read-on-fallback) ---

	public function testReconCacheFileWritesOnEnvResolution(): Void {
		// A private HOME for the duration. The cache is ONE file per USER, so two suite
		// processes each write their own cwd into it and read back the other's — and the
		// stash-and-restore this used to do around the REAL file was a second cross-process
		// write of the same path. Under a private HOME the developer's own cache is never
		// touched at all, and the assertion below answers for this process alone.
		final homeStash: Null<String> = Sys.getEnv('HOME');
		final home: String = CliFixture.writeDir('recon_home', []);
		final cachePath: String = '$home/.config/anyparse/fork_path';
		// utest does not run teardown on assertion failure, so the restore block is wrapped
		// in try/catch — any throw re-raises after restore.
		final envStash: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		// Use a synthetic path that exists (the project root itself —
		// guaranteed present, never a haxe-formatter fork). The cache
		// write logic doesn't care whether the path is a real fork; it
		// only persists what the env supplied.
		final synthetic: String = Sys.getCwd();
		final trimmed: String = synthetic.length > 1 && synthetic.charAt(synthetic.length - 1) == '/'
			? synthetic.substr(0, synthetic.length - 1)
			: synthetic;
		var raised: Null<Exception> = null;
		try {
			Sys.putEnv('HOME', home);
			Sys.putEnv('ANYPARSE_HXFORMAT_FORK', trimmed);
			// Trigger defaultReconRoot via a recon invocation — exit code is
			// whatever recon decides; we only care about the side effect on
			// disk. The cache write fires regardless of recon's own success.
			Cli.run(['recon', '--top', '1']);
			Assert.isTrue(FileSystem.exists(cachePath), 'cache file written');
			final cached: String = File.getContent(cachePath).trim();
			Assert.equals(trimmed, cached, 'cache holds the env-supplied path verbatim');
		} catch (exception: Exception) {
			raised = exception;
		}
		// Restore both env mutations (always — they are process-wide), then drop the
		// private HOME with the cache file inside it.
		Sys.putEnv('HOME', homeStash);
		Sys.putEnv('ANYPARSE_HXFORMAT_FORK', envStash);
		CliFixture.removeDir(home);
		if (raised != null) throw raised;
	}

	// --- 6. stale test.js mtime warning ---

	public function testSweepReadsCleanlyWithCurrentSnapshot(): Void {
		// `apq sweep` reads bin/.last-sweep.json — when test.js is up to
		// date relative to src/ + test/, the WARNING is silent. We can't
		// control mtimes here without touching the user's tree, so the
		// assertion is just "doesn't crash on the warn-check path".
		if (!FileSystem.exists('bin/.last-sweep.json')) {
			Assert.pass('bin/.last-sweep.json missing — sweep cannot run');
			return;
		}
		Assert.equals(0, Cli.run(['sweep']), 'sweep exits clean with warn-check in the path');
	}

	#if nodejs
	/** Run `probe` as a child process under `tmpRoot` and return the slot path it announced. */
	private function probeChildSlot(engine: String, tmpRoot: String, source: String): String {
		final result: js.node.ChildProcess.ChildProcessSpawnSyncResult = spawnProbe(engine, tmpRoot, source, null);
		Assert.equals(0, result.status, 'probe child exits clean');
		final err: String = result.stderr == null ? '' : Std.string(result.stderr);
		final marker: String = 'staged source -> ';
		final at: Int = err.indexOf(marker);
		if (at < 0) {
			Assert.fail('the probe nudge must name the staged path, got: $err');
			return '';
		}
		final rest: String = err.substr(at + marker.length);
		final close: Int = rest.indexOf(' (');
		return close < 0 ? rest.trim() : rest.substr(0, close);
	}

	/** `node bin/apq.js probe <source>` with `TMPDIR` (and optionally `APQ_PROBE_PATH`) overridden. */
	private function spawnProbe(
		engine: String, tmpRoot: String, source: String, slot: Null<String>
	): js.node.ChildProcess.ChildProcessSpawnSyncResult {
		final env: Any = {};
		for (key => value in Sys.environment()) Reflect.setField(env, key, value);
		Reflect.setField(env, 'TMPDIR', tmpRoot);
		Reflect.setField(env, 'TEMP', tmpRoot);
		if (slot != null) Reflect.setField(env, 'APQ_PROBE_PATH', slot);
		return js.node.ChildProcess.spawnSync('node', [
			engine,
			'probe',
			source,
			'--lang',
			'haxe'
		], cast { encoding: 'utf8', env: env });
	}

	/** There is no `sys.FileSystem` symlink, and the guard under test only means anything against a real one. */
	private inline function symlink(target: String, link: String): Void {
		js.node.Fs.symlinkSync(target, link);
	}

	/**
	 * Run `probe` in-process once per source with `root` as the temp root, and
	 * return the slot basenames it left behind. The stem is the contract; the
	 * rest of the name belongs to the resolver, so a test that spelled the whole
	 * path would be pinning the implementation instead of the behaviour.
	 */
	private function stagedUnder(root: String, sources: Array<String>): Array<String> {
		final tmpStash: Null<String> = Sys.getEnv('TMPDIR');
		final tempStash: Null<String> = Sys.getEnv('TEMP');
		var raised: Null<Exception> = null;
		var slots: Array<String> = [];
		try {
			Sys.putEnv('TMPDIR', root);
			Sys.putEnv('TEMP', root);
			for (source in sources) Assert.equals(0, Cli.run(['probe', source]), 'probe exits clean');
			slots = FileSystem.readDirectory(root).filter(name -> name.startsWith(PROBE_SLOT_STEM));
		} catch (exception: Exception) {
			raised = exception;
		}
		Sys.putEnv('TMPDIR', tmpStash);
		Sys.putEnv('TEMP', tempStash);
		if (raised != null) throw raised;
		return slots;
	}
	#end
	#end

}
