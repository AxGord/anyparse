package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.AvoidDynamic;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import haxe.io.Path;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

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
	/** An unused import (a safe fix) and a narrowable `Dynamic` local (a risky one) in one class; `C` is the class name. */
	private static final DISABLED_SUBDIR: String = 'import haxe.io.Bytes;\n\nclass C {\n\tpublic function new() {}\n\n'
		+ '\tpublic static function run():Void {\n\t\tfinal a:C = new C();\n'
		+ '\t\tvar x:Dynamic = a;\n\t\tvar y:C = x;\n\t\ttrace(y);\n\t}\n}\n';

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
			new HaxeQueryPlugin(), [{ hxml: 'check.hxml', dir: dir, defines: [] }], (p, c) -> File.saveContent(p, c)
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

	/**
	 * The run's config resolver decides which files a `FileGated` risky check scans: a resolver excluding the
	 * fixture's directory leaves the narrowing `testNarrowingAppliedWhenValid` applies unfound, whatever the disk says.
	 */
	@:pin('control') @:killer('M-FIXVERIFY-DISCOVERS-CONFIG')
	public function testTheRunResolverGatesTheScannedFiles(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('addyn', [{ name: 'Good.hx', source: APPLIES }, { name: 'check.hxml', source: HXML }]);
		final path: String = '$dir/Good.hx';
		final excluding: LintConfig = LintConfig.parse('{"rules":{"avoid-dynamic":{"excludePaths":["${Path.withoutDirectory(dir)}"]}}}');
		final result: FixVerifyResult = FixVerifier.verify(
			[{ file: path, source: APPLIES }],
			[new AvoidDynamic()],
			new HaxeQueryPlugin(), [{ hxml: 'check.hxml', dir: dir, defines: [] }],
			(p, c) -> File.saveContent(p, c), null, null, _ -> excluding
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — otherwise the zero below is vacuous');
		Assert.equals(0, result.applied.length, 'the resolver excludes the file, so nothing is found to narrow');
		Assert.isTrue(File.getContent(path).indexOf('var x:Dynamic = a;') != -1, 'disk keeps the Dynamic local');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The run's config resolver also reaches the risky check's OWN options: the same narrowing is left alone under a
	 * resolver whose `excludeMeta` names the member's metadata, and applied under one that names nothing.
	 */
	@:pin('control') @:killer('M-FIXVERIFY-CHECK-DISCOVERS-CONFIG')
	public function testTheRunResolverReachesTheCheckOptions(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final kept: String = APPLIES.replace('\tstatic function main()', '\t@:keep static function main()');
		for (arm in [
			{ config: '{"rules":{"avoid-dynamic":{"excludeMeta":["@:keep"]}}}', applied: 0 },
			{ config: '{}', applied: 1 }
		]) {
			final dir: String = CliFixture.writeDir('addyn', [{ name: 'Good.hx', source: kept }, { name: 'check.hxml', source: HXML }]);
			final config: LintConfig = LintConfig.parse(arm.config);
			final result: FixVerifyResult = FixVerifier.verify(
				[{ file: '$dir/Good.hx', source: kept }],
				[new AvoidDynamic()],
				new HaxeQueryPlugin(), [{ hxml: 'check.hxml', dir: dir, defines: [] }],
				(p, c) -> File.saveContent(p, c), null, null, _ -> config
			);
			Assert.isTrue(result.baseline.match(Confirmed));
			Assert.equals(arm.applied, result.applied.length, 'applied under ${arm.config}');
			CliFixture.removeDir(dir);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--fix` writes nothing a file's own config switched off: `b/` disables a risky rule (`avoid-dynamic`) and a safe
	 * one (`unused-import`), and keeps both findings while `a/` gets both fixes.
	 */
	@:pin('control') @:killer('M-COLLECT-NO-ENABLEMENT', 'M-FIXVERIFY-ENABLEMENT-DROPPED')
	public function testAFixNeverLandsWhereItsRuleIsDisabled(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final root: String = CliFixture.writeTree('addynoff', [
			{ name: 'a/Good.hx', source: DISABLED_SUBDIR.replace('C', 'Good') },
			{ name: 'b/Bad.hx', source: DISABLED_SUBDIR.replace('C', 'Bad') },
			{ name: 'a/Main.hx', source: 'class Main {\n\tstatic function main():Void {\n\t\tGood.run();\n\t\tBad.run();\n\t}\n}\n' },
			{ name: 'check.hxml', source: '-cp a\n-cp b\n-main Main\n' },
			{
				name: 'apqlint.json',
				source: '{"compilerOracle":"check.hxml","rules":{"avoid-dynamic":{"enabled":true},"prefer-final":{"enabled":false},'
				+ '"join-single-use-local":{"enabled":false}}}'
			},
			{ name: 'b/apqlint.json', source: '{"rules":{"avoid-dynamic":{"enabled":false},"unused-import":{"enabled":false}}}' }
		]);
		Cli.run(['lint', '--fix', '$root/a', '$root/b']);
		final good: String = File.getContent('$root/a/Good.hx');
		final bad: String = File.getContent('$root/b/Bad.hx');
		Assert.isTrue(good.indexOf('var x:Good = a;') != -1 && good.indexOf('import') == -1, 'a/ takes both fixes: $good');
		Assert.isTrue(bad.indexOf('import haxe.io.Bytes;') != -1, 'b/ disables the safe unused-import: $bad');
		Assert.isTrue(bad.indexOf('var x:Dynamic = a;') != -1, 'b/ disables the risky avoid-dynamic: $bad');
		CliFixture.removeDir(root);
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
			new HaxeQueryPlugin(), [{ hxml: 'check.hxml', dir: dir, defines: [] }], (p, c) -> File.saveContent(p, c)
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
