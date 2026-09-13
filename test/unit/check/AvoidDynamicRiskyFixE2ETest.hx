package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.AvoidDynamic;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

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
	/**
	 * A local `Dynamic` provably holding a `Good` (typed init) with a corroborating typed
	 * sink — the narrowing to `Good` typechecks and is applied.
	 * Trivia-writer-canonical (blank line between members) so RefactorSupport.canonicalize accepts it.
	 */
	private static final APPLIES: String = 'class Good {\n\tpublic function new() {}\n\n\tstatic function main() {\n\t\tfinal a:Good = new '
		+ 'Good();\n\t\tvar x:Dynamic = a;\n\t\tvar y:Good = x;\n\t\ttrace(y);\n\t}\n}\n';

	/**
	 * The optional-param nullability blind spot: `?b:Good` records nominal `Good` in
	 * `declaredTypes` (its `Null<…>` is the projection's known lossy gap), so the classifier
	 * proposes `x:Good` — but under `@:nullSafety(Strict)` the narrowed `x = b` is a
	 * `Null<Good> -> Good` compile error the ORIGINAL `Dynamic` local tolerated. The oracle
	 * rejects and reverts: precisely the residual the RiskyFix belt exists to catch.
	 */
	private static final REVERTS: String = '@:nullSafety(Strict)\nclass Good {\n\tpublic function new() {}\n\n\tstatic function main() {\n'
		+ '\t\trun(new Good());\n\t}\n\n\tstatic function run(a:Good, ?b:Good):Void {\n'
		+ '\t\tvar x:Dynamic = a;\n\t\tx = b;\n\t\tvar y:Good = x;\n\t\ttrace(y);\n\t}\n}\n';

	/**
	 * A `Dynamic` parameter whose ONLY read ascribes it to a std abstract that declares no
	 * `@:from` member: the ascription arm moves `haxe.DynamicAccess<Int>` into the signature and
	 * unwraps the read, one atomic group through the verifier. Proves the std half of the
	 * conversion-free gate: the index the gates consult is the report files plus the std, so a std
	 * abstract resolves while a sibling project file outside the lint scope stays invisible to the
	 * override-family proof.
	 *
	 * The call argument is written `{a: 1}` and not `{ a: 1 }` deliberately: a `--fix` pass
	 * canonicalises the file it writes and SKIPS one the writer would reformat, so a
	 * non-canonical fixture reports no finding at all and the scenario passes vacuously.
	 */
	private static final PARAM_APPLIES: String = 'class Param {\n\n\tstatic function main() {\n\t\tread({a: 1});\n\t}\n\n\t'
		+ 'static function read(p:Dynamic):Void {\n\t\ttrace((p : haxe.DynamicAccess<Int>).keys());\n\t}\n\n}\n';

	private static final PARAM_HXML: String = '-cp .\n-main Param\n';
	private static final PARAM_APQLINT: String = '{"compilerOracle":"check.hxml","rules":{"avoid-dynamic":{"enabled":true}}}';
	private static final HXML: String = '-cp .\n-main Good\n';
	#end

	public function testParameterAscriptionAppliedViaCli(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('addynparam', [
			{ name: 'Param.hx', source: PARAM_APPLIES },
			{ name: 'check.hxml', source: PARAM_HXML },
			{ name: 'apqlint.json', source: PARAM_APQLINT }
		]);
		Cli.run(['lint', '--fix', '--rule', 'avoid-dynamic', '$dir/Param.hx']);
		final onDisk: String = File.getContent('$dir/Param.hx');
		Assert.isTrue(onDisk.indexOf('read(p:haxe.DynamicAccess<Int>)') != -1, 'the ascribed std abstract lands in the signature');
		Assert.isTrue(onDisk.indexOf('trace(p.keys());') != -1, 'the ascription is gone from the body');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

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
			files,
			[new AvoidDynamic()],
			new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
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
			files,
			[new AvoidDynamic()],
			new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
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
