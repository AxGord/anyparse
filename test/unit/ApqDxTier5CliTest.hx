package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
import haxe.Exception;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

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
 *  3. `apq probe` always stages the source bytes to
 *     `/tmp/anyparse-last-probe.hx` so a follow-up `strip` / `recon
 *     --probe` / `writer-equals` can target them without re-heredoc-ing.
 *     Stdin source path also stages (avoids a second stdin read).
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
		Assert.equals(
			0, Cli.run([
				'probe',
				'class C {}',
				'--select',
				'HxCatchClause'
			]),
			'ast --select on a TypeName not present in source exits clean'
		);
	}

	public function testAstSelectLowercaseSelectorStillExitsClean(): Void {
		// Lowercase selector — the cross-project hint stays silent
		// (field-shape, not a TypeName). The existing kinds-present
		// fallback fires.
		Assert.equals(
			0, Cli.run([
				'probe',
				'class C {}',
				'--select',
				'unknownField'
			]),
			'ast --select on a lowercase token exits clean with kinds-present fallback'
		);
	}

	// --- 3. probe staging ---

	#if (sys || nodejs)
	public function testProbeStagesSourceToTmp(): Void {
		final stagedPath: String = '/tmp/anyparse-last-probe.hx';
		// Pre-clean — guarantee we observe a fresh write, not a stale
		// file lingering from an earlier probe.
		if (FileSystem.exists(stagedPath)) FileSystem.deleteFile(stagedPath);
		final source: String = 'class StagedProbe { var x:Int = 42; }';
		final code: Int = Cli.run(['probe', source]);
		Assert.equals(0, code, 'probe exits clean');
		Assert.isTrue(FileSystem.exists(stagedPath), 'probe stages source to $stagedPath');
		final staged: String = File.getContent(stagedPath);
		Assert.equals(source, staged, 'staged file content matches the probe source byte-for-byte');
	}

	public function testProbeRestagingOverwritesPreviousScratch(): Void {
		final stagedPath: String = '/tmp/anyparse-last-probe.hx';
		Assert.equals(0, Cli.run(['probe', 'class First {}']), 'first probe exits clean');
		final firstStaged: String = FileSystem.exists(stagedPath) ? File.getContent(stagedPath) : '';
		Assert.equals('class First {}', firstStaged, 'first probe staged');
		Assert.equals(0, Cli.run(['probe', 'class Second { var b:Bool; }']), 'second probe exits clean');
		Assert.equals(
			'class Second { var b:Bool; }', File.getContent(stagedPath),
			'second probe overwrites the scratch file (single-slot by design)'
		);
	}
	#end

	// --- 4. ANYPARSE_HXFORMAT_FORK cache (write-on-resolve, read-on-fallback) ---

	#if (sys || nodejs)
	public function testReconCacheFileWritesOnEnvResolution(): Void {
		final home: Null<String> = Sys.getEnv('HOME');
		if (home == null || home.length == 0) {
			Assert.pass('HOME unset — cache write path skipped');
			return;
		}
		final cachePath: String = '$home/.config/anyparse/fork_path';
		// Stash BOTH env + cache file state before mutating. utest does
		// not run teardown on assertion failure, so the restore block is
		// wrapped in try/catch — any throw re-raises after restore.
		final envStash: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		final cacheStash: Null<String> = FileSystem.exists(cachePath) ? File.getContent(cachePath) : null;
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
			Sys.putEnv('ANYPARSE_HXFORMAT_FORK', trimmed);
			// Trigger defaultReconRoot via a recon invocation — exit code is
			// whatever recon decides; we only care about the side effect on
			// disk. The cache write fires regardless of recon's own success.
			Cli.run(['recon', '--top', '1']);
			Assert.isTrue(FileSystem.exists(cachePath), 'cache file written');
			final cached: String = StringTools.trim(File.getContent(cachePath));
			Assert.equals(trimmed, cached, 'cache holds the env-supplied path verbatim');
		} catch (exception: Exception) {
			raised = exception;
		}
		// Restore env first (always — the env mutation is process-wide).
		Sys.putEnv('ANYPARSE_HXFORMAT_FORK', envStash ?? '');
		// Restore cache file: stash present → write it back; stash absent
		// → delete the file we created.
		if (cacheStash != null)
			File.saveContent(cachePath, cacheStash);
		else if (FileSystem.exists(cachePath)) FileSystem.deleteFile(cachePath);
		if (raised != null) throw raised;
	}
	#end

	// --- 5. self-status --source ---

	public function testSelfStatusSourceFlagAccepted(): Void {
		// `--source` parses as a known flag. The walk against the project's
		// own src/ either finds 0 skip-parse (clean tree → exit 0) or some
		// — we don't pin a count, just that the flag is wired up.
		Assert.equals(0, Cli.run(['self-status', '--source']), 'self-status --source is a known flag');
	}

	public function testSelfStatusUnknownFlagStillRejected(): Void {
		Assert.equals(2, Cli.run(['self-status', '--bogus']), 'self-status rejects unknown flags as usage error');
	}

	// --- 6. stale test.js mtime warning ---

	#if (sys || nodejs)
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
	#end

}
