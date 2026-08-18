package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.check.CompilerServer;
#if (sys || nodejs)
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
#end

/**
 * End-to-end coverage of the compiler-oracle (`apqlint.json` `compilerOracle`):
 * report-mode confirm/reject, the fix-verification apply/revert of a `RiskyFix`
 * check, and the gate-invariant that no `haxe` is spawned without the key.
 *
 * Every haxe-dependent scenario spawns the real compiler, so it first probes
 * availability (`oracleWorks`) and skips gracefully (Assert.pass) when the host
 * has no `haxe` on PATH — the gate-invariant test needs no haxe and always runs.
 * Fixtures are temp dirs laid out CliFixture-style: a root-package `Good.hx` a
 * `-cp .` hxml, and (for the report scenarios) an `apqlint.json`; cleaned per test.
 */
@:nullSafety(Strict)
final class CompilerOracleE2ETest extends Test {

	#if (sys || nodejs)
	private static final VALID: String = 'class Good {\n\tstatic function main() {\n\t\tvar x:Int = 1;\n\t\ttrace(x);\n\t}\n}\n';
	private static final BROKEN: String = 'class Good {\n\tstatic function main() {\n\t\tvar x:Int = "no";\n\t\ttrace(x);\n\t}\n}\n';
	private static final HXML: String = '-cp .\n-main Good\n';

	/** The convention fixtures' main, in `src/`: it names a type reachable ONLY through the hxml's `-cp lib`, which the default cwd classpath cannot stand in for. */
	private static final NESTED_MAIN: String =
		'class Good {\n\tstatic function main() {\n\t\tvar x:Int = 1;\n\t\ttrace(x + Helper.bump());\n\t}\n}\n';

	/** The convention fixtures' library type, in `lib/` — off the default cwd classpath of every candidate compile directory. */
	private static final NESTED_HELPER: String = 'class Helper {\n\tpublic static function bump():Int {\n\t\treturn 2;\n\t}\n}\n';

	/**
	 * The convention fixtures' hxml: its `-cp` entries are cwd-relative, so each fixture's
	 * LAYOUT decides which compile dir resolves them — the hxml's own directory when it sits
	 * at the root next to `lib`/`src` (`writeNestedProject`), the project root when the same
	 * hxml is generated under `dist/haxe/` (`writeLimeShapedProject`).
	 */
	private static final NESTED_HXML: String = '-cp lib\n-cp src\n-main Good\n';

	/** The nested project's `apqlint.json`, living in `src/` and naming the hxml one level up. */
	private static final NESTED_CONFIG: String = '{"compilerOracle":"../build.hxml"}';

	/** A pid far above any process a machine can run — the planted record a warm run must refuse to connect to. */
	private static final DEAD_SERVER_PID: String = '2147480000';

	/** A recorded warm server whose process cannot exist: the fixture for the dead-record recovery path. */
	private static final DEAD_SERVER_RECORD: String = '{"port":1,"pid":$DEAD_SERVER_PID,"compiledAt":1000000000}';

	/** How far ahead of now a pinned modification time is set, so a later write can be pinned back to the value the server already recorded. */
	private static inline final FUTURE_MTIME_MS: Float = 5000;
	#end

	public function testOracleConfirmsValidBuild(): Void {
		#if (sys || nodejs)
		final dir: String = writeOracleDir(VALID);
		final outcome: OracleOutcome = CompilerOracle.typecheck('check.hxml', dir);
		switch outcome {
			case Confirmed:
				Assert.pass();
			case Unavailable(reason):
				Assert.pass('haxe unavailable ($reason) — skipped');
			case Rejected(errors):
				Assert.fail('a valid build should confirm, got: $errors');
		}
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testOracleRejectsBrokenBuild(): Void {
		#if (sys || nodejs)
		final dir: String = writeOracleDir(BROKEN);
		final outcome: OracleOutcome = CompilerOracle.typecheck('check.hxml', dir);
		switch outcome {
			case Rejected(errors):
				Assert.isTrue(errors.length > 0, 'a rejection carries the compiler error text');
			case Unavailable(reason):
				Assert.pass('haxe unavailable ($reason) — skipped');
			case Confirmed:
				Assert.fail('a type-broken build must not confirm');
		}
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReportModeConfirmsAndRejects(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final good: String = writeLintDir(VALID, true);
		Assert.equals(0, Cli.run(['lint', '$good/Good.hx']), 'a valid build with the oracle exits 0');
		CliFixture.removeDir(good);
		final bad: String = writeLintDir(BROKEN, true);
		Assert.equals(1, Cli.run(['lint', '$bad/Good.hx']), 'a broken build with the oracle exits 1 (rejected)');
		CliFixture.removeDir(bad);
		final badNoKey: String = writeLintDir(BROKEN, false);
		Assert.equals(0, Cli.run(['lint', '$badNoKey/Good.hx']), 'a broken build WITHOUT the key exits 0 (no compile check)');
		CliFixture.removeDir(badNoKey);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testGateInvariantNoKeyNeverSpawnsHaxe(): Void {
		#if (sys || nodejs)
		final noKey: String = writeLintDir(VALID, false);
		final before: Int = CompilerOracle.invocations;
		Cli.run(['lint', '$noKey/Good.hx']);
		Assert.equals(before, CompilerOracle.invocations, 'no compilerOracle key means haxe is never spawned');
		CliFixture.removeDir(noKey);

		final withKey: String = writeLintDir(VALID, true);
		final beforeKeyed: Int = CompilerOracle.invocations;
		Cli.run(['lint', '$withKey/Good.hx']);
		Assert.isTrue(CompilerOracle.invocations > beforeKeyed, 'the key makes the oracle run');
		CliFixture.removeDir(withKey);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRiskyFixAppliedWhenValid(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = writeOracleDir(VALID);
		final path: String = '$dir/Good.hx';
		final files: Array<{ file: String, source: String }> = [{ file: path, source: VALID }];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new TestRiskyLiteralRewrite('2')],
			new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
		);
		Assert.equals(1, result.applied.length, 'a valid risky fix survives the typecheck and is applied');
		Assert.equals(0, result.reverted.length);
		final onDisk: String = File.getContent(path);
		Assert.isTrue(onDisk.indexOf('= 2;') != -1, 'disk carries the rewritten literal');
		Assert.isTrue(onDisk.indexOf('= 1;') == -1, 'the original literal is gone');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRiskyFixRevertedWhenBroken(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = writeOracleDir(VALID);
		final path: String = '$dir/Good.hx';
		final files: Array<{ file: String, source: String }> = [{ file: path, source: VALID }];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new TestRiskyLiteralRewrite('"broken"')],
			new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
		);
		Assert.equals(0, result.applied.length, 'a compile-breaking risky fix is not applied');
		Assert.equals(1, result.reverted.length, 'it is reverted to a report-only fallback');
		final onDisk: String = File.getContent(path);
		Assert.isTrue(onDisk.indexOf('= 1;') != -1, 'disk is restored to the original literal');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A nested `apqlint.json` — the config in a SUBDIRECTORY, its `compilerOracle` naming an
	 * `.hxml` one level up. The hxml's `-cp src` is written relative to the hxml, so the compile
	 * must run from the HXML's directory; running it from the CONFIG's directory resolves the
	 * classpath as `src/src` and every type goes missing, so report mode failed the lint of every
	 * file under such a config, permanently.
	 */
	public function testNestedConfigReportModeConfirms(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = writeNestedProject();
		Assert.equals(0, Cli.run(['lint', '$dir/src/Good.hx']), 'a config naming a parent-directory hxml still typechecks');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The OPPOSITE convention: a lime/openfl-generated hxml lives NESTED
	 * (`dist/haxe/build.hxml`) but writes its `-cp` entries relative to the PROJECT
	 * root the build is invoked from — the config's directory. Compiling from the
	 * hxml's own directory resolves `src` as `dist/haxe/src` and every type goes
	 * missing, so the oracle spuriously rejected every such project (TM's layout).
	 * The compile dir is probed from the hxml's own relative classpaths: the
	 * candidate that resolves strictly more of them wins.
	 */
	public function testLimeShapedConfigCompilesFromConfigDir(): Void {
		#if (sys || nodejs)
		final dir: String = writeLimeShapedProject();
		final cfg: LintConfig = LintConfig.discover('$dir/src/Good.hx');
		Assert.equals(
			Path.normalize(dir), Path.normalize(cfg.compilerOracleDir() ?? ''), 'a root-relative hxml compiles from the config dir'
		);
		if (oracleWorks()) Assert.equals(0, Cli.run(['lint', '$dir/src/Good.hx']), 'a lime-shaped project typechecks through its oracle');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The same layout on the FIX side: a rejected baseline makes `FixVerifier` bail before it
	 * touches anything, so every `RiskyFix` under a nested config was silently left report-only.
	 * The oracle is threaded through the real `LintConfig` rather than a hand-built pair — it is
	 * the config that decides both the hxml and the directory the compile runs from.
	 */
	public function testNestedConfigRiskyFixApplies(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = writeNestedProject();
		final path: String = '$dir/src/Good.hx';
		final config: LintConfig = LintConfig.discover(path);
		final hxml: Null<String> = config.compilerOracle();
		if (hxml == null) {
			Assert.fail('the nested apqlint.json declares a compilerOracle');
			CliFixture.removeDir(dir);
			return;
		}
		final result: FixVerifyResult = FixVerifier.verify(
			[{ file: path, source: NESTED_MAIN }],
			[new TestRiskyLiteralRewrite('2')],
			new HaxeQueryPlugin(), hxml, config.compilerOracleDir(), (p, c) -> File.saveContent(p, c)
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the nested-config baseline typechecks');
		Assert.equals(1, result.applied.length, 'the risky fix survives the typecheck and is applied');
		Assert.isTrue(File.getContent(path).indexOf('= 2;') != -1, 'disk carries the rewritten literal');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Three verdicts through ONE reused server: the first lint spawns it and confirms, a
	 * break is REJECTED, and restoring the source confirms again — so reuse is idempotent
	 * rather than a first-run accident, and the warm path (not a silent fall-back to the
	 * cold one) is what answered.
	 *
	 * The middle verdict also covers the STALENESS guard, deterministically. Pinning the
	 * modification time to one value across both compiles is what does it: the server decides
	 * staleness by that value, so the break is invisible to it BY CONSTRUCTION and only the
	 * pre-typecheck `server/invalidate` can catch it. Without pinning, the two writes straddle
	 * a wall-clock second by luck and the hazard is never reached.
	 */
	public function testWarmServerReportModeConfirmsAndRejects(): Void {
		#if nodejs
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = writeLintDir(VALID, true, true);
		final path: String = '$dir/Good.hx';
		final warmBefore: Int = CompilerServer.invocations;
		final coldBefore: Int = CompilerOracle.invocations;
		final stamp: Date = Date.fromTime(Date.now().getTime() + FUTURE_MTIME_MS);
		pinMtime(path, stamp);
		Assert.equals(0, Cli.run(['lint', path]), 'a valid build confirms through the warm server');
		Assert.isTrue(CompilerServer.invocations > warmBefore, 'the warm path is the one that answered');
		Assert.equals(coldBefore, CompilerOracle.invocations, 'a warm confirm never falls back to the cold compiler');
		File.saveContent(path, BROKEN);
		pinMtime(path, stamp);
		Assert.equals(1, Cli.run(['lint', path]), 'a break the server cannot see by modification time is still rejected');
		File.saveContent(path, VALID);
		Assert.equals(0, Cli.run(['lint', path]), 'restoring the source confirms again');
		stopWarmServer(path);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('the warm server is a nodejs path');
		#end
	}

	/**
	 * The warm server is opt-in: a `compilerOracle` config WITHOUT `compilerOracleServer`
	 * starts no daemon, so a project that asked only for a typecheck never gets one — while
	 * the cold oracle still runs and still decides the verdict.
	 */
	public function testWarmServerNotSpawnedWithoutTheKey(): Void {
		#if nodejs
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = writeLintDir(VALID, true, false);
		final warmBefore: Int = CompilerServer.invocations;
		final coldBefore: Int = CompilerOracle.invocations;
		Assert.equals(0, Cli.run(['lint', '$dir/Good.hx']), 'the cold path still confirms a valid build');
		Assert.equals(warmBefore, CompilerServer.invocations, 'no compilerOracleServer key means no warm server');
		Assert.isTrue(CompilerOracle.invocations > coldBefore, 'the cold oracle ran instead');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('the warm server is a nodejs path');
		#end
	}

	/**
	 * A recorded server whose process is gone must not be believed. The fixture plants a
	 * record naming a pid no machine can be running; the run has to notice, establish a real
	 * server, and still produce the cold path's verdict.
	 */
	public function testWarmServerReplacesADeadRecordedServer(): Void {
		#if nodejs
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = writeLintDir(VALID, true, true);
		final path: String = '$dir/Good.hx';
		final config: LintConfig = LintConfig.discover(path);
		final hxml: Null<String> = config.compilerOracle();
		if (hxml == null) {
			Assert.fail('the fixture apqlint.json declares a compilerOracle');
			CliFixture.removeDir(dir);
			return;
		}
		final record: String = CompilerServer.stateFile(hxml, config.compilerOracleDir());
		File.saveContent(record, DEAD_SERVER_RECORD);
		Assert.equals(0, Cli.run(['lint', path]), 'a dead recorded server does not change the verdict');
		Assert.isTrue(File.getContent(record).indexOf(DEAD_SERVER_PID) == -1, 'the dead record is replaced by a live one');
		stopWarmServer(path);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('the warm server is a nodejs path');
		#end
	}

	/**
	 * An unrelated listener accepts `--connect` and lets the compiler client exit 0 having
	 * compiled nothing, which would read as a clean build — so an exit status alone can
	 * never be believed. Only a display-protocol reply proves a real compilation server is
	 * on the port.
	 */
	public function testServerReplyProvesACompilationServer(): Void {
		Assert.isTrue(CompilerServer.isServerReply('{"jsonrpc":"2.0","id":1,"result":{"result":null}}'), 'a real reply carries a result');
		Assert.isFalse(CompilerServer.isServerReply(''), 'a stray listener answers with nothing at all');
		Assert.isFalse(
			CompilerServer.isServerReply('{"jsonrpc":"2.0","id":1,"method":"server/invalidate","params":{"file":"A.hx"}}'),
			'a listener echoing the request back is not a compilation server'
		);
		Assert.isFalse(CompilerServer.isServerReply('Couldn\'t connect on 127.0.0.1:29999 (Connection refused)'));
	}

	#if (sys || nodejs)
	/** A miniature of this project's own layout: `build.hxml` at the root, the sources and their `apqlint.json` in `src/`. */
	private function writeNestedProject(): String {
		final dir: String = CliFixture.writeDir('oracle_nested', [{ name: 'build.hxml', source: NESTED_HXML }]);
		writeSharedSources(dir);
		File.saveContent('$dir/src/apqlint.json', NESTED_CONFIG);
		return dir;
	}

	/**
	 * A miniature of a lime/openfl project: the config at the root, the generated hxml
	 * nested under `dist/haxe/` with its `-cp` entries written relative to the ROOT.
	 */
	private function writeLimeShapedProject(): String {
		final dir: String = CliFixture.writeDir(
			'oracle_lime', [{ name: 'apqlint.json', source: '{"compilerOracle":"dist/haxe/build.hxml"}' }]
		);
		writeSharedSources(dir);
		FileSystem.createDirectory('$dir/dist/haxe');
		File.saveContent('$dir/dist/haxe/build.hxml', NESTED_HXML);
		return dir;
	}

	/** The `lib/Helper.hx` + `src/Good.hx` pair both convention fixtures share. */
	private function writeSharedSources(dir: String): Void {
		FileSystem.createDirectory('$dir/lib');
		File.saveContent('$dir/lib/Helper.hx', NESTED_HELPER);
		FileSystem.createDirectory('$dir/src');
		File.saveContent('$dir/src/Good.hx', NESTED_MAIN);
	}

	private function writeOracleDir(main: String): String {
		return CliFixture.writeDir('oracle', [{ name: 'Good.hx', source: main }, { name: 'check.hxml', source: HXML }]);
	}

	private function writeLintDir(main: String, withKey: Bool, warmServer: Bool = false): String {
		final keyed: String = warmServer
			? '{"compilerOracle":"check.hxml","compilerOracleServer":true}'
			: '{"compilerOracle":"check.hxml"}';
		final files: Array<{ name: String, source: String }> = [
			{ name: 'Good.hx', source: main },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: withKey ? keyed : '{"rules":{}}' }
		];
		return CliFixture.writeDir('oracle', files);
	}

	/** Force `path`'s modification time to `stamp` — the device that makes the server's staleness comparison deterministic instead of a race with the wall clock. */
	private inline function pinMtime(path: String, stamp: Date): Void {
		js.node.Fs.utimesSync(path, stamp, stamp);
	}

	/** Reap the warm server a fixture started, keyed through the config exactly as the CLI keyed it. */
	private function stopWarmServer(path: String): Void {
		final config: LintConfig = LintConfig.discover(path);
		final hxml: Null<String> = config.compilerOracle();
		if (hxml != null) CompilerServer.stopShared(hxml, config.compilerOracleDir());
	}

	private function oracleWorks(): Bool {
		final dir: String = writeOracleDir(VALID);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
