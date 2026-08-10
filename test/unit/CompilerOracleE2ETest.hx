package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
#if (sys || nodejs)
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

	/** The nested project's main, in `src/`: it names a type reachable ONLY through the hxml's `-cp lib`, which the default cwd classpath cannot stand in for. */
	private static final NESTED_MAIN: String =
		'class Good {\n\tstatic function main() {\n\t\tvar x:Int = 1;\n\t\ttrace(x + Helper.bump());\n\t}\n}\n';

	/** The nested project's library type, in `lib/` — off the default cwd classpath of every candidate compile directory. */
	private static final NESTED_HELPER: String = 'class Helper {\n\tpublic static function bump():Int {\n\t\treturn 2;\n\t}\n}\n';

	/** The nested project's hxml: its `-cp` entries are written relative to the HXML's own directory, so only a compile run from there resolves them. */
	private static final NESTED_HXML: String = '-cp lib\n-cp src\n-main Good\n';

	/** The nested project's `apqlint.json`, living in `src/` and naming the hxml one level up. */
	private static final NESTED_CONFIG: String = '{"compilerOracle":"../build.hxml"}';
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
			files, [new TestRiskyLiteralRewrite('2')], new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
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
			files, [new TestRiskyLiteralRewrite('"broken"')], new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
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
			[new TestRiskyLiteralRewrite('2')], new HaxeQueryPlugin(), hxml, config.compilerOracleDir(), (p, c) -> File.saveContent(p, c)
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the nested-config baseline typechecks');
		Assert.equals(1, result.applied.length, 'the risky fix survives the typecheck and is applied');
		Assert.isTrue(File.getContent(path).indexOf('= 2;') != -1, 'disk carries the rewritten literal');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A miniature of this project's own layout: `build.hxml` at the root, the sources and their `apqlint.json` in `src/`. */
	private function writeNestedProject(): String {
		final dir: String = CliFixture.writeDir('oracle_nested', [{ name: 'build.hxml', source: NESTED_HXML }]);
		FileSystem.createDirectory('$dir/lib');
		File.saveContent('$dir/lib/Helper.hx', NESTED_HELPER);
		FileSystem.createDirectory('$dir/src');
		File.saveContent('$dir/src/Good.hx', NESTED_MAIN);
		File.saveContent('$dir/src/apqlint.json', NESTED_CONFIG);
		return dir;
	}

	private function writeOracleDir(main: String): String {
		return CliFixture.writeDir('oracle', [{ name: 'Good.hx', source: main }, { name: 'check.hxml', source: HXML }]);
	}

	private function writeLintDir(main: String, withKey: Bool): String {
		final files: Array<{ name: String, source: String }> = [
			{ name: 'Good.hx', source: main },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: withKey ? '{"compilerOracle":"check.hxml"}' : '{"rules":{}}' }
		];
		return CliFixture.writeDir('oracle', files);
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
