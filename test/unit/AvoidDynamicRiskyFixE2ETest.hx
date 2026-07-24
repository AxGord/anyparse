package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.AvoidDynamic;
import anyparse.check.CompilerOracle;
import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.check.FixVerifier;
import anyparse.check.FixVerifier.FixVerifyResult;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * End-to-end coverage of `avoid-dynamic` as the first real `RiskyFix` consumer:
 * its usage-inference narrowing is driven through `FixVerifier` + the compiler
 * oracle, which APPLIES a narrowing that still typechecks and REVERTS one that
 * breaks the build (the report-only fallback). The revert fixture is the belt the
 * `RiskyFix` marker buys — the classifier's optional-param nullability blind spot
 * (`declaredTypes` records `?b:Good` as nominal `Good`) proposes a narrowing that
 * `@:nullSafety(Strict)` rejects, so the oracle catches what the classifier cannot.
 *
 * Spawns the real compiler, so each scenario probes availability and skips
 * gracefully when the host has no `haxe` on PATH.
 */
@:nullSafety(Strict)
final class AvoidDynamicRiskyFixE2ETest extends Test {

	#if (sys || nodejs)
	// A local `Dynamic` provably holding a `Good` (typed init) with a corroborating typed
	// sink — the narrowing to `Good` typechecks and is applied.
	// Trivia-writer-canonical (blank line between members) so RefactorSupport.canonicalize accepts it.
	private static final APPLIES: String = 'class Good {\n\tpublic function new() {}\n\n\tstatic function main() {\n\t\tfinal a:Good = new Good();\n\t\t'
		+ 'var x:Dynamic = a;\n\t\tvar y:Good = x;\n\t\ttrace(y);\n\t}\n}\n';

	// The optional-param nullability blind spot: `?b:Good` records nominal `Good` in
	// `declaredTypes` (its `Null<…>` is the projection's known lossy gap), so the classifier
	// proposes `x:Good` — but under `@:nullSafety(Strict)` the narrowed `x = b` is a
	// `Null<Good> -> Good` compile error the ORIGINAL `Dynamic` local tolerated. The oracle
	// rejects and reverts: precisely the residual the RiskyFix belt exists to catch.
	private static final REVERTS: String = '@:nullSafety(Strict)\nclass Good {\n\tpublic function new() {}\n\n\tstatic function main() {\n\t\t'
		+ 'run(new Good());\n\t}\n\n\tstatic function run(a:Good, ?b:Good):Void {\n\t\tvar x:Dynamic = a;\n\t\tx = b;\n\t\t'
		+ 'var y:Good = x;\n\t\ttrace(y);\n\t}\n}\n';

	private static final HXML: String = '-cp .\n-main Good\n';
	#end

	public function testNarrowingAppliedWhenValid(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('addyn', [{ name: 'Good.hx', source: APPLIES }, { name: 'check.hxml', source: HXML }]);
		final path: String = '$dir/Good.hx';
		final files: Array<{ file: String, source: String }> = [{ file: path, source: APPLIES }];
		final result: FixVerifyResult = FixVerifier.verify(
			files, [new AvoidDynamic()], new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
		);
		Assert.equals(1, result.applied.length, 'a valid Dynamic narrowing survives the typecheck and is applied');
		Assert.equals(0, result.reverted.length);
		final onDisk: String = File.getContent(path);
		Assert.isTrue(onDisk.indexOf('var x:Good = a;') != -1, 'disk carries the narrowed local');
		Assert.isTrue(onDisk.indexOf('Dynamic') == -1, 'no Dynamic remains');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testNarrowingRevertedWhenBroken(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('addyn', [{ name: 'Good.hx', source: REVERTS }, { name: 'check.hxml', source: HXML }]);
		final path: String = '$dir/Good.hx';
		final files: Array<{ file: String, source: String }> = [{ file: path, source: REVERTS }];
		final result: FixVerifyResult = FixVerifier.verify(
			files, [new AvoidDynamic()], new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
		);
		Assert.equals(0, result.applied.length, 'a narrowing that breaks the build is not applied');
		Assert.equals(1, result.reverted.length, 'it is reverted to a report-only fallback');
		final onDisk: String = File.getContent(path);
		Assert.isTrue(onDisk.indexOf('var x:Dynamic = a;') != -1, 'disk is restored to the original Dynamic local');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRiskyFixReportOnlyWithoutOracleViaCli(): Void {
		#if (sys || nodejs)
		// A RiskyFix check with NO safe subset (avoid-dynamic) driven through `lint --fix` WITHOUT a
		// compilerOracle must be left report-only — its unverified narrowing is never applied. Regression
		// guard for the oracle-gated risky/safe partition: only an OracleRelaxable RiskyFix (prefer-inline)
		// falls back to the safe loop without an oracle; a plain RiskyFix stays out of it. No oracle key,
		// so no haxe is spawned.
		final dir: String = CliFixture.writeDir('addynnooracle', [{ name: 'Good.hx', source: APPLIES }]);
		Cli.run(['lint', '--fix', '--rule', 'avoid-dynamic', '$dir/Good.hx']);
		final onDisk: String = File.getContent('$dir/Good.hx');
		Assert.isTrue(
			onDisk.indexOf('var x:Dynamic = a;') != -1,
			'without an oracle the risky narrowing is report-only — the Dynamic local is untouched'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('addyn', [{ name: 'Good.hx', source: APPLIES }, { name: 'check.hxml', source: HXML }]);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
