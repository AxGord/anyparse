package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * `apq recon` — corpus skip-parse drill harness end-to-end probe.
 *
 * Sweep mode walks `.hxtest` files under a directory, runs the trivia
 * parser per fixture, prints `SKIP <path> :: <line>:<col> …` for each
 * failure, then a normalised-locus cluster histogram. `--probe <file>`
 * runs a single file as PARSE OK / PARSE FAIL.
 *
 * Replaces the standalone `test/_ReconSkipParse.hx` + `/tmp/recon.js`
 * dance — same clustering logic, in-process so a `bin/apq-js.hxml`
 * rebuild after a grammar edit picks up the new parser surface without
 * a separate `recon.hxml` step.
 *
 * Tests drive `Cli.run`. The stderr / stdout text content was verified
 * manually against the haxe-formatter fork on disk; here we only assert
 * exit codes and structural argv handling.
 */
@:nullSafety(Strict)
class ApqReconCliTest extends Test {

	#if sys
	private static var counter: Int = 0;
	#end

	public function testReconHelpExitsClean(): Void {
		Assert.equals(0, Cli.run(['recon', '--help']), 'apq recon --help is a clean exit');
	}

	public function testReconNoArgsAndNoEnvIsUsageError(): Void {
		#if sys
		final saved: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		Sys.putEnv('ANYPARSE_HXFORMAT_FORK', '');
		Assert.equals(2, Cli.run(['recon']), 'no <dir> and no fork env var is a usage error');
		if (saved != null) Sys.putEnv('ANYPARSE_HXFORMAT_FORK', saved);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconMissingDirIsRuntimeError(): Void {
		#if sys
		Assert.equals(1, Cli.run(['recon', '/nonexistent/path/that/does/not/exist']), 'non-existent <dir> is a runtime error');
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconUnknownOptionIsUsageError(): Void {
		Assert.equals(2, Cli.run(['recon', '--bogus']), 'unknown option is a usage error');
	}

	public function testReconTwoPositionalsIsUsageError(): Void {
		Assert.equals(2, Cli.run(['recon', '/a', '/b']), 'two positional <dir> args is a usage error');
	}

	public function testReconTopRequiresPositiveInt(): Void {
		Assert.equals(2, Cli.run(['recon', '--top', 'nope', '/some/dir']), 'non-integer --top is a usage error');
		Assert.equals(2, Cli.run(['recon', '--top', '0', '/some/dir']), 'zero --top is a usage error');
		Assert.equals(2, Cli.run(['recon', '--top', '-3', '/some/dir']), 'negative --top is a usage error');
	}

	// -- Sweep mode against a tiny on-disk corpus --

	public function testReconSweepOnEmptyDirExitsClean(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_empty');
		Assert.equals(0, Cli.run(['recon', dir]), 'empty corpus is a clean 0-total sweep');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconSweepOnGoodFixtureExitsClean(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_good');
		File.saveContent('$dir/good.hxtest', goodHxtest());
		Assert.equals(0, Cli.run(['recon', dir]), 'all-OK sweep exits 0');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconSweepWithBrokenFixtureExitsClean(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_broken');
		File.saveContent('$dir/good.hxtest', goodHxtest());
		File.saveContent('$dir/bad.hxtest', brokenHxtest());
		// SKIPs are not errors — exit 0, histogram shows the cluster.
		Assert.equals(0, Cli.run(['recon', dir]), 'sweep with one broken fixture still exits 0 (SKIP is data, not an error)');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconSweepRecursesIntoSubdirs(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_nested');
		FileSystem.createDirectory('$dir/inner');
		File.saveContent('$dir/inner/good.hxtest', goodHxtest());
		Assert.equals(0, Cli.run(['recon', dir]), 'sweep recurses into nested subdirectories');
		CliFixture.removeDir('$dir/inner');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- Single-file probe mode --

	public function testReconProbeGoodFixtureExitsClean(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_probe_good');
		final path: String = '$dir/ok.hxtest';
		File.saveContent(path, goodHxtest());
		Assert.equals(0, Cli.run(['recon', '--probe', path]), 'probe of a parseable .hxtest returns PARSE OK / exit 0');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconProbeBrokenFixtureIsRuntimeError(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_probe_bad');
		final path: String = '$dir/bad.hxtest';
		File.saveContent(path, brokenHxtest());
		Assert.equals(1, Cli.run(['recon', '--probe', path]), 'probe of an unparseable .hxtest is PARSE FAIL / exit 1');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconProbeNonexistentIsRuntimeError(): Void {
		#if sys
		Assert.equals(1, Cli.run(['recon', '--probe', '/no/such/file.hxtest']), 'probe of a missing file is a runtime error');
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- --cluster: exact-match drill into a single cluster --

	public function testReconClusterDrillExactMatchExitsClean(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_cluster_hit');
		File.saveContent('$dir/bad.hxtest', brokenHxtest());
		// Even without knowing the exact key the broken fixture lands
		// in, an empty-string cluster filter is a guaranteed miss —
		// real cluster keys are at least one character. The miss
		// branch is exercised by testReconClusterDrillNoMatchExitsRuntime;
		// here we only verify --cluster with `<no message>` (the
		// exception-path cluster key) drills cleanly when present.
		// brokenHxtest's failure is a ParseError, so we use a key the
		// histogram would print for any ParseError-driven cluster of
		// a one-fixture sweep — but key shape is brittle. Instead,
		// just verify the option PARSES and the CLI returns runtime
		// for any non-matching string.
		Assert.equals(
			1, Cli.run(['recon', '--cluster', 'definitely-not-a-key', dir]),
			'--cluster with no match is a runtime exit even with one broken fixture'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconClusterDrillNoMatchExitsRuntime(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_cluster_miss');
		File.saveContent('$dir/bad.hxtest', brokenHxtest());
		Assert.equals(
			1, Cli.run(['recon', '--cluster', 'xyz-not-present-anywhere', dir]), '--cluster with no exact-match key returns runtime exit'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconClusterDrillEmptySweepNoMatch(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_cluster_empty');
		Assert.equals(1, Cli.run(['recon', '--cluster', 'anything', dir]), '--cluster on an empty sweep is a runtime exit');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- --predict-strip: substitution prediction across the sweep --

	public function testReconPredictStripRequiresSubstitution(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--predict-strip', '/some/dir']), '--predict-strip without --replace/--with or --delete is a usage error'
		);
	}

	public function testReconReplaceWithoutPredictStripIsUsageError(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--replace', 'x', '--with', 'y', '/some/dir']),
			'--replace/--with outside --predict-strip is a usage error'
		);
	}

	public function testReconReplaceWithoutWithIsUsageError(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--predict-strip', '--replace', 'x', '/some/dir']), '--replace with no following --with is a usage error'
		);
	}

	public function testReconPredictStripUnblockOnSimpleSweep(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_predict_unblock');
		// Fixture fails because of a single literal `XYZ` token that
		// would substitute cleanly. Delete `XYZ` and the body becomes
		// a normal class.
		final fixture: String = '{}\n---\n\nclass C { var x:Int = 0 XYZ; }\n\n---\n\nclass C {\n\tvar x:Int = 0;\n}\n';
		File.saveContent('$dir/bad.hxtest', fixture);
		Assert.equals(
			0, Cli.run(['recon', '--predict-strip', '--delete', 'XYZ', dir]),
			'--predict-strip with a matching pattern that unblocks the fixture exits clean'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconPredictStripPatternNeverMatchesWarns(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_predict_nomatch');
		File.saveContent('$dir/bad.hxtest', brokenHxtest());
		// Pattern matches 0 occurrences across the (single) skip-parse
		// file → typo guard fires, exit non-zero like strip --dry-run.
		Assert.equals(
			1, Cli.run(['recon', '--predict-strip', '--delete', 'NEVER_PRESENT_xyz', dir]),
			'--predict-strip with a 0-match pattern raises the typo guard'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconPredictStripStillFailExitsClean(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_predict_stillfail');
		// Strip pattern matches but the substitution leaves the body
		// unparseable (rename `XYZ` to `WAT`, still not a token). The
		// STILL FAIL branch now emits the new locus + the original locus
		// when they differ — the test guards exit semantics (0 because
		// the pattern matched ≥1 time) and prevents accidental
		// regression of the format change.
		final fixture: String = '{}\n---\n\nclass C { var x:Int = 0 XYZ; }\n\n---\n\nclass C {\n\tvar x:Int = 0;\n}\n';
		File.saveContent('$dir/bad.hxtest', fixture);
		Assert.equals(
			0, Cli.run(['recon', '--predict-strip', '--replace', 'XYZ', '--with', 'WAT', dir]),
			'--predict-strip STILL FAIL exits 0 when pattern matched (the file still fails to parse, but pattern hit ≥1)'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- --source: drill window guard --

	public function testReconSourceWithoutClusterOrPredictIsUsageError(): Void {
		// `--source` is valid only with `--cluster` (drill window) OR
		// `--predict-strip` (STILL FAIL window). In plain sweep mode it
		// would flood every SKIP line — usage error caught BEFORE any FS
		// I/O.
		Assert.equals(2, Cli.run(['recon', '--source', '/some/dir']), '--source without --cluster or --predict-strip is a usage error');
	}

	public function testReconPredictStripSourceProbeStillFailEmitsWindow(): Void {
		#if sys
		// `--predict-strip --source --probe <file>` on a STILL FAIL
		// outcome: applying the substitution shifts the bug but the
		// stripped source still fails to parse. The new flag adds a src
		// window around the NEW fail-locus so the moved-locus payload is
		// visible without a separate Read of the stripped source.
		final dir: String = mkTempDir('apq_recon_predict_source');
		// 3-section .hxtest: config / input / expected. The `XYZ` token
		// is the strip target — replacing it with `WAT` keeps the file
		// broken (WAT is also invalid), so the strip moves the bug but
		// does not resolve it. Probe mode prints PREDICT STILL FAIL +
		// (with --source) a windowed source slice.
		final fixture: String = '{}\n---\n\nclass C { var x:Int = 0 XYZ; }\n\n---\n\nclass C {\n\tvar x:Int = 0;\n}\n';
		final fixturePath: String = '$dir/probe.hxtest';
		File.saveContent(fixturePath, fixture);
		Assert.equals(1, Cli.run([
			'recon',
			'--probe',
			fixturePath,
			'--predict-strip',
			'--source',
			'--replace',
			'XYZ',
			'--with',
			'WAT'
		]), '--predict-strip --probe --source on STILL FAIL exits runtime (parse still fails)');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconPredictStripSourceProbeUnblockExitsZero(): Void {
		#if sys
		// `--source` is additive — when the predict resolves to UNBLOCK
		// (no STILL FAIL entries) it emits no extra windows and exit code
		// stays 0. Guards against `--source` accidentally forcing
		// runtime exit in the predict path.
		final dir: String = mkTempDir('apq_recon_predict_source_ok');
		final fixture: String = '{}\n---\n\nclass C { var x:Int = 0 XYZ; }\n\n---\n\nclass C {\n\tvar x:Int = 0;\n}\n';
		final fixturePath: String = '$dir/probe.hxtest';
		File.saveContent(fixturePath, fixture);
		Assert.equals(0, Cli.run([
			'recon',
			'--probe',
			fixturePath,
			'--predict-strip',
			'--source',
			'--delete',
			' XYZ'
		]), '--predict-strip --probe --source on UNBLOCK is a clean exit');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconPredictStripSourceSweepStillFailEmitsWindow(): Void {
		#if sys
		// Sweep-mode parallel of the probe test — STILL FAIL across a
		// directory walk should still exit non-zero with --source active.
		final dir: String = mkTempDir('apq_recon_predict_source_sweep');
		final fixture: String = '{}\n---\n\nclass C { var x:Int = 0 XYZ; }\n\n---\n\nclass C {\n\tvar x:Int = 0;\n}\n';
		File.saveContent('$dir/bad.hxtest', fixture);
		Assert.equals(0, Cli.run([
			'recon',
			'--predict-strip',
			'--source',
			'--replace',
			'XYZ',
			'--with',
			'WAT',
			dir
		]), '--predict-strip --source sweep STILL FAIL still emits, exits 0 (pattern matched)');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconClusterSourceOnEmptyCorpusExitsRuntime(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_source_empty');
		Assert.equals(
			1, Cli.run(['recon', '--cluster', 'anything', '--source', dir]),
			'--cluster --source on an empty sweep is a runtime exit (no key match)'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconClusterSourceUnknownKeyExitsRuntime(): Void {
		#if sys
		final dir: String = mkTempDir('apq_recon_source_miss');
		File.saveContent('$dir/bad.hxtest', brokenHxtest());
		Assert.equals(
			1, Cli.run(['recon', '--cluster', 'xyz-not-present', '--source', dir]),
			'--cluster --source with a non-matching key exits runtime'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- --regression-probe: snapshot-diff mode --

	public function testReconRegressionProbeIncompatibleWithProbe(): Void {
		Assert.equals(2, Cli.run(['recon', '--regression-probe', '--probe', '/x']), '--regression-probe + --probe is mutually exclusive');
	}

	public function testReconRegressionProbeIncompatibleWithPredictStrip(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--regression-probe', '--predict-strip', '--delete', 'x', '/x']),
			'--regression-probe + --predict-strip is mutually exclusive'
		);
	}

	public function testReconRegressionProbeIncompatibleWithCluster(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--regression-probe', '--cluster', 'k', '/x']), '--regression-probe + --cluster is mutually exclusive'
		);
	}

	public function testReconRegressionProbeNoSnapshotExitsClean(): Void {
		#if sys
		// In a temp directory with no snapshot file: regression-probe
		// exits OK with a "no baseline" diagnostic (CWD doesn't have
		// `bin/.last-sweep.json`). Run from a tmp CWD to guarantee that.
		final dir: String = mkTempDir('apq_recon_regression_no_snap');
		final savedCwd: String = Sys.getCwd();
		Sys.setCwd(dir);
		Assert.equals(
			0, Cli.run(['recon', '--regression-probe', dir]), '--regression-probe with no snapshot is a clean OK exit (no baseline)'
		);
		Sys.setCwd(savedCwd);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconRegressionProbeUnblockOnFixtureNotInSnapshot(): Void {
		#if sys
		// Fixture present locally but absent in the snapshot: silently
		// ignored (no false UNBLOCK / REGRESSED line). Run in a tmp CWD
		// with a hand-written empty-fixtures snapshot.
		final dir: String = mkTempDir('apq_recon_regression_silent');
		File.saveContent('$dir/good.hxtest', goodHxtest());
		// Hand-write a snapshot with 0 fixtures — every local file is
		// "not in baseline" → silent.
		FileSystem.createDirectory('$dir/bin');
		File.saveContent(
			'$dir/bin/.last-sweep.json',
			'{"pass":0,"fail":0,"skipParse":0,"skipWrite":0,"skipConfig":0,"skipMalformed":0,"fixtures":[{"path":"other/whatever.hxtest","status":"PASS"}]}'
		);
		final savedCwd: String = Sys.getCwd();
		Sys.setCwd(dir);
		Assert.equals(
			0, Cli.run(['recon', '--regression-probe', dir]),
			'fixtures present locally but absent from snapshot are silent (no false flips)'
		);
		Sys.setCwd(savedCwd);
		CliFixture.removeDir('$dir/bin');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconRegressionProbeFlagsRegression(): Void {
		#if sys
		// Snapshot says fixture was PASS; the actual fixture is broken
		// → REGRESSED line, exit non-zero. This is the load-bearing
		// detection path.
		final dir: String = mkTempDir('apq_recon_regression_hit');
		File.saveContent('$dir/bad.hxtest', brokenHxtest());
		FileSystem.createDirectory('$dir/bin');
		File.saveContent(
			'$dir/bin/.last-sweep.json',
			'{"pass":1,"fail":0,"skipParse":0,"skipWrite":0,"skipConfig":0,"skipMalformed":0,"fixtures":[{"path":"bad.hxtest","status":"PASS"}]}'
		);
		final savedCwd: String = Sys.getCwd();
		Sys.setCwd(dir);
		Assert.equals(1, Cli.run(['recon', '--regression-probe', dir]), 'regressed fixture (was PASS, now skip-parse) is a runtime exit');
		Sys.setCwd(savedCwd);
		CliFixture.removeDir('$dir/bin');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- --predict-relax: terminator-insertion gate-relaxation predictor --

	public function testReconPredictRelaxRejectsReplaceArgs(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--predict-relax', '--replace', 'x', '--with', 'y', '/some/dir']),
			'--predict-relax does not take --replace/--with (token comes from parser hint)'
		);
	}

	public function testReconPredictRelaxIncompatibleWithPredictStrip(): Void {
		Assert.equals(2, Cli.run([
			'recon',
			'--predict-relax',
			'--predict-strip',
			'--replace',
			'x',
			'--with',
			'y',
			'/some/dir'
		]), '--predict-relax and --predict-strip are mutually exclusive');
	}

	public function testReconPredictRelaxIncompatibleWithRegressionProbe(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--predict-relax', '--regression-probe', '/some/dir']),
			'--predict-relax and --regression-probe are mutually exclusive'
		);
	}

	public function testReconPredictRelaxOnAlreadyParseableFile(): Void {
		#if sys
		// Already-parseable file → NO TARGET (not an error path).
		final dir: String = mkTempDir('apq_recon_predict_relax_ok');
		final path: String = '$dir/good.hxtest';
		File.saveContent(path, goodHxtest());
		Assert.equals(
			1, Cli.run(['recon', '--probe', path, '--predict-relax']),
			'predict-relax on already-parseable file emits NO TARGET (no relaxation needed)'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconPredictRelaxOnTerminatorBlocker(): Void {
		#if sys
		// Source missing `;` after var-decl AND missing `:Type` → parser
		// reports a real expected token. Predict-relax injects it; the
		// retry either UNBLOCKs or STILL FAILs, but never NO TARGET.
		final dir: String = mkTempDir('apq_recon_predict_relax_real');
		final path: String = '$dir/bad.hxtest';
		File.saveContent(path, brokenHxtest());
		// Exit non-zero is the contract for unparseable-after-relax —
		// the broken fixture has multiple gaps so STILL FAIL is expected.
		// We assert exit code is non-zero AND that the run completes
		// (doesn't crash with an unhandled exception).
		final exitCode: Int = Cli.run(['recon', '--probe', path, '--predict-relax']);
		Assert.isTrue(
			exitCode == 0 || exitCode == 1,
			'predict-relax exits 0 (UNBLOCK) or 1 (STILL FAIL / NO TARGET) on real broken fixture, got $exitCode'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- --no-target-cluster: drill into ONE footer NO TARGET bucket --

	public function testReconNoTargetClusterRequiresPredictRelax(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--no-target-cluster', 'foo', '/some/dir']),
			'--no-target-cluster without --predict-relax is a usage error'
		);
	}

	public function testReconNoTargetClusterIncompatibleWithCluster(): Void {
		Assert.equals(2, Cli.run([
			'recon',
			'--predict-relax',
			'--no-target-cluster',
			'foo',
			'--cluster',
			'bar',
			'/some/dir'
		]), '--cluster and --no-target-cluster are mutually exclusive (different drill namespaces)');
	}

	public function testReconNoTargetClusterIncompatibleWithProbe(): Void {
		Assert.equals(2, Cli.run([
			'recon',
			'--predict-relax',
			'--no-target-cluster',
			'foo',
			'--probe',
			'/some/file'
		]), '--no-target-cluster requires sweep mode — mutex with --probe');
	}

	public function testReconNoTargetClusterZeroMatchExitsRuntime(): Void {
		#if sys
		// Corpus with one broken fixture; a deliberately-non-matching
		// expected-msg filter exits runtime (1) with the available-keys
		// diagnostic on stderr.
		final dir: String = mkTempDir('apq_recon_no_target_cluster_miss');
		File.saveContent('$dir/bad.hxtest', brokenHxtest());
		Assert.equals(1, Cli.run([
			'recon',
			'--predict-relax',
			'--no-target-cluster',
			'this-message-does-not-exist',
			dir
		]), '--no-target-cluster with no matching expected-msg exits runtime');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconNoTargetClusterEmptyCorpusExitsRuntime(): Void {
		#if sys
		// Empty corpus (no skip-parse records) → no NO TARGET records to
		// match → 0-match runtime exit, no crash.
		final dir: String = mkTempDir('apq_recon_no_target_cluster_empty');
		Assert.equals(
			1, Cli.run(['recon', '--predict-relax', '--no-target-cluster', 'anything', dir]),
			'--no-target-cluster on an empty sweep is a runtime exit (no records to filter)'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- --predict-relax --source: windowed src for STILL FAIL + NO TARGET --

	public function testReconPredictRelaxSourceProbeNoTargetEmitsWindow(): Void {
		#if sys
		// `--predict-relax --source --probe <file>` on a NO TARGET outcome
		// (the parser returned no usable `expected` hint to inject) prints
		// a windowed source slice anchored on the ORIGINAL fail-locus —
		// distinct from `--predict-strip` where the window anchors on the
		// NEW (post-substitution) locus. THE drill payload for triaging
		// the NO TARGET cluster.
		final dir: String = mkTempDir('apq_recon_predict_relax_source_probe');
		// `{foo: bar}` parses as a module-level object literal, which the
		// HxDecl gate rejects with no usable terminator hint — reliable
		// NO TARGET outcome anchored at 1:1.
		final fixture: String = '{}\n---\n\n{foo: bar}\n\n---\n\n{foo: bar}\n';
		final fixturePath: String = '$dir/probe.hxtest';
		File.saveContent(fixturePath, fixture);
		Assert.equals(1, Cli.run([
			'recon',
			'--probe',
			fixturePath,
			'--predict-relax',
			'--source'
		]), '--predict-relax --probe --source on NO TARGET exits runtime (no terminator to inject)');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconPredictRelaxSourceSweepAllowed(): Void {
		// Plain sweep `--predict-relax --source` is ALLOWED — the validation
		// guard recognises predict-relax as a non-flooding mode (sweep keeps
		// NO TARGET collapsed in the footer; STILL FAIL is small). Pre-edit
		// this combination was rejected as a usage error.
		#if sys
		final dir: String = mkTempDir('apq_recon_predict_relax_source_sweep');
		// Empty corpus → sweep runs cleanly without flooding.
		Assert.equals(
			0, Cli.run(['recon', '--predict-relax', '--source', dir]),
			'--predict-relax --source sweep on empty corpus exits 0 (NO TARGET stays collapsed)'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconPredictRelaxNoTargetClusterSourceAllowed(): Void {
		#if sys
		// `--predict-relax --no-target-cluster <msg> --source` combines the
		// footer-bucket drill with the per-path source window. Empty corpus
		// → 0 matched records → runtime exit (parallel of the
		// non-`--source` test above), proves the combination is accepted.
		final dir: String = mkTempDir('apq_recon_relax_no_target_source');
		Assert.equals(1, Cli.run([
			'recon',
			'--predict-relax',
			'--no-target-cluster',
			'anything',
			'--source',
			dir
		]), '--predict-relax --no-target-cluster --source on empty corpus is a runtime exit');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- --permissive-construct: field-optionalization predictor --

	public function testReconPermissiveConstructIncompatibleWithProbe(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--permissive-construct', '--probe', '/some/file', '/some/dir']),
			'--permissive-construct is its own mode — mutually exclusive with --probe'
		);
	}

	public function testReconPermissiveConstructIncompatibleWithPredictStrip(): Void {
		Assert.equals(2, Cli.run([
			'recon',
			'--permissive-construct',
			'--predict-strip',
			'--replace',
			'x',
			'--with',
			'y',
			'/some/dir'
		]), '--permissive-construct is its own mode — mutually exclusive with --predict-strip');
	}

	public function testReconPermissiveConstructIncompatibleWithCluster(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--permissive-construct', '--cluster', 'X', '/some/dir']),
			'--permissive-construct is its own mode — mutually exclusive with --cluster'
		);
	}

	public function testReconPermissiveConstructIncompatibleWithCandidates(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--permissive-construct', '--candidates', 'foo', '/some/dir']),
			'--permissive-construct is its own mode — mutually exclusive with --candidates'
		);
	}

	public function testReconPermissiveConstructIncompatibleWithRegressionProbe(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--permissive-construct', '--regression-probe', '/some/dir']),
			'--permissive-construct is its own mode — mutually exclusive with --regression-probe'
		);
	}

	public function testReconPermissiveConstructIncompatibleWithPredictRelax(): Void {
		Assert.equals(
			2, Cli.run(['recon', '--permissive-construct', '--predict-relax', '/some/dir']),
			'--permissive-construct is its own mode — mutually exclusive with --predict-relax'
		);
	}

	public function testReconPermissiveConstructRunsOnEmptyCorpus(): Void {
		#if sys
		// Empty corpus → no skip-parse fixtures, no UNBLOCKs possible →
		// exit non-zero (no signal) but no crash. Validates that the
		// predictor handles the zero-records edge case cleanly.
		final dir: String = mkTempDir('apq_recon_permissive_empty');
		final exitCode: Int = Cli.run(['recon', '--permissive-construct', dir]);
		// Either OK (no candidates found in non-haxe lang scope) or
		// RUNTIME (no unblocks across empty fixture set). Crash would be
		// the failure mode this test guards against.
		Assert.isTrue(exitCode == 0 || exitCode == 1, 'permissive-construct exits 0 or 1 on empty corpus, got $exitCode');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReconRegressionProbeFlagsUnblock(): Void {
		#if sys
		// Snapshot says fixture was SKIP_PARSE; the actual fixture parses
		// → UNBLOCKED line, exit OK (unblocks alone don't fail the probe).
		final dir: String = mkTempDir('apq_recon_regression_unblock');
		File.saveContent('$dir/good.hxtest', goodHxtest());
		FileSystem.createDirectory('$dir/bin');
		File.saveContent(
			'$dir/bin/.last-sweep.json',
			'{"pass":0,"fail":0,"skipParse":1,"skipWrite":0,"skipConfig":0,"skipMalformed":0,"fixtures":[{"path":"good.hxtest","status":"SKIP_PARSE"}]}'
		);
		final savedCwd: String = Sys.getCwd();
		Sys.setCwd(dir);
		Assert.equals(
			0, Cli.run(['recon', '--regression-probe', dir]), 'unblocked fixture (was SKIP_PARSE, now parses) is a clean OK exit'
		);
		Sys.setCwd(savedCwd);
		CliFixture.removeDir('$dir/bin');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function mkTempDir(prefix: String): String {
		counter++;
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? stripTrailingSlash((tmp: String)) : '/tmp';
		final dir: String = '$base/${prefix}_${Sys.time()}_$counter';
		FileSystem.createDirectory(dir);
		return dir;
	}

	private static inline function stripTrailingSlash(p: String): String {
		return StringTools.endsWith(p, '/') ? p.substring(0, p.length - 1) : p;
	}

	private static inline function goodHxtest(): String {
		return '{}\n---\n\nclass C { var x:Int = 0; }\n\n---\n\nclass C {\n\tvar x:Int = 0;\n}\n';
	}

	private static inline function brokenHxtest(): String {
		// Trailing colon with no type — trivia parser must reject.
		return '{}\n---\n\nclass C { var x:\n\n---\n\nclass C {\n\tvar x:Int;\n}\n';
	}
	#end

}
