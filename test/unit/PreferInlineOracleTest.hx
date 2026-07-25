package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.FixVerifier.FixVerifyResult;
import anyparse.check.FixVerifier.FixVerifyPartial;
import anyparse.check.PreferInline;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * The `prefer-inline` compiler-oracle path (its `RiskyFix` integration). WITHOUT an oracle the
 * check keeps its structural null-safety gate, so an object-literal / null-value / block-lambda
 * single-expression method is suppressed (report byte-identical). WITH an oracle configured,
 * `Cli.applyLintFixes` moves the check into the verified `RiskyFix` path, calls `setOracleRelaxed`
 * to widen the candidate set, and routes every insertion through the per-file typecheck-and-revert
 * pipeline: a typechecking object-literal factory is inlined, a null-unsafe one is reverted. The
 * pure tests exercise the relaxed candidate selection without a compiler; the E2E cases drive the
 * real compiler and skip gracefully when no `haxe` is on the host.
 */
class PreferInlineOracleTest extends Test {

	#if (sys || nodejs)
	// A Lib with THREE relaxed inline candidates: `box` binds a `Null<Int>` into a
	// non-nullable object-literal field (sound in Lib's off mode, rejected once inlined
	// into Main's Strict mode) while `one` / `two` inline cleanly. The full-set inline
	// fails, so the per-edit bisect must keep `one` / `two` and revert only `box`.
	private static final PARTIAL_LIB: String = 'class Lib {\n\n\tpublic static function box(x:Null<Int>):{v:Int}\n\t\treturn {v: x};\n\n'
		+ '\tpublic static function one():Int\n\t\treturn 1;\n\n\tpublic static function two():Int\n\t\treturn 2;\n\n}\n';

	private static final PARTIAL_MAIN: String = '@:nullSafety(Strict)\nclass Main {\n\n\tstatic function main() {\n\t\t'
		+ 'final n:Null<Int> = Std.random(2) == 0 ? 1 : null;\n\t\ttrace(Lib.box(n));\n\t\ttrace(Lib.one());\n\t\ttrace(Lib.two());\n\t}\n\n}\n';
	#end

	public function testDefaultRunSuppressesObjectLiteralBody(): Void {
		final src: String = 'class C {\n\tpublic function make():Dynamic return {a: 1};\n\tpublic function plain():Int return 1;\n}';
		final vs: Array<Violation> = new PreferInline().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isFalse(mentions(vs, 'make'), 'gate on: the object-literal method is suppressed (byte-identical report)');
		Assert.isTrue(mentions(vs, 'plain'), 'a plain single-expression method is still flagged');
	}

	public function testOracleRelaxedRunFlagsObjectLiteralBody(): Void {
		final src: String = 'class C {\n\tpublic function make():Dynamic return {a: 1};\n\tpublic function plain():Int return 1;\n}';
		final check: PreferInline = new PreferInline();
		check.setOracleRelaxed(true);
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(mentions(vs, 'make'), 'relaxed: the object-literal method becomes a candidate');
		Assert.isTrue(mentions(vs, 'plain'), 'the plain method stays a candidate too');
	}

	public function testCliFixInlinesObjectLiteralWithOracle(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		// Default-config canonical form (a fixture in $TMPDIR discovers no hxformat.json, so the
		// writer-emit canonical gate measures against the compiled defaults, not the project style).
		final src: String =
			'class Main {\n\n\tstatic function main() {\n\t\ttrace(make());\n\t}\n\n\tstatic function make():Dynamic\n\t\treturn {a: 1, b: 2};\n\n}\n';
		final dir: String = CliFixture.writeDir('preferinlineoracle', [
			{ name: 'Main.hx', source: src },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n' },
			{ name: 'apqlint.json', source: '{"compilerOracle":"check.hxml"}' }
		]);
		Cli.run(['lint', '--fix', '--rule', 'prefer-inline', '$dir/Main.hx']);
		final out: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(out.indexOf('inline function make') >= 0, 'the typechecking object-literal factory is inlined');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCliFixRevertsNullUnsafeInline(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		// `Lib.box` binds a `Null<Int>` into a non-nullable object-literal field — sound in Lib's
		// default (off) null-safety mode, but re-checked in Main's `Strict` mode once inlined, so the
		// compiler rejects the relaxed inline and the pipeline reverts `Lib.hx` to report-only.
		final lib: String = 'class Lib {\n\n\tpublic static function box(x:Null<Int>):{v:Int}\n\t\treturn {v: x};\n\n}\n';
		final main: String =
			'@:nullSafety(Strict)\nclass Main {\n\n\tstatic function main() {\n\t\tfinal n:Null<Int> = Std.random(2) == 0 ? 1 : null;\n\t\ttrace(Lib.box(n));\n\t}\n\n}\n';
		final dir: String = CliFixture.writeDir('preferinlineoracle', [
			{ name: 'Lib.hx', source: lib },
			{ name: 'Main.hx', source: main },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n' },
			{ name: 'apqlint.json', source: '{"compilerOracle":"check.hxml"}' }
		]);
		Cli.run(['lint', '--fix', '--rule', 'prefer-inline', '$dir/Lib.hx', '$dir/Main.hx']);
		final out: String = File.getContent('$dir/Lib.hx');
		Assert.isTrue(out.indexOf('inline function box') == -1, 'the null-unsafe relaxed inline is reverted to report-only');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testBisectAppliesSafeInlinesAndRevertsUnsafeOne(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('preferinlinebisect', [
			{ name: 'Lib.hx', source: PARTIAL_LIB },
			{ name: 'Main.hx', source: PARTIAL_MAIN },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n' },
			{ name: 'apqlint.json', source: '{"compilerOracle":"check.hxml"}' }
		]);
		Cli.run(['lint', '--fix', '--rule', 'prefer-inline', '$dir/Lib.hx', '$dir/Main.hx']);
		final out: String = File.getContent('$dir/Lib.hx');
		Assert.isTrue(out.indexOf('inline function one') >= 0, 'the safe `one` inline survives the bisect');
		Assert.isTrue(out.indexOf('inline function two') >= 0, 'the safe `two` inline survives the bisect');
		Assert.isTrue(out.indexOf('inline function box') == -1, 'only the null-unsafe `box` inline is reverted');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testBisectResultReportsPartialCountsAndCost(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('preferinlinebisect', [
			{ name: 'Lib.hx', source: PARTIAL_LIB },
			{ name: 'Main.hx', source: PARTIAL_MAIN },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n' }
		]);
		final libPath: String = '$dir/Lib.hx';
		final check: PreferInline = new PreferInline();
		check.setOracleRelaxed(true);
		final files: Array<{ file: String, source: String }> = [
			{ file: libPath, source: PARTIAL_LIB },
			{ file: '$dir/Main.hx', source: PARTIAL_MAIN }
		];
		final result: FixVerifyResult = FixVerifier.verify(
			files, [check], new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
		);
		Assert.equals(1, result.applied.length, 'Lib.hx changed on disk (partially applied)');
		Assert.equals(0, result.reverted.length, 'no file is fully reverted');
		Assert.equals(1, result.partials.length, 'exactly one file was bisected');
		final partial: FixVerifyPartial = result.partials[0];
		Assert.equals(libPath, partial.file);
		Assert.equals('prefer-inline', partial.rule);
		Assert.equals(2, partial.appliedEdits, 'two safe inlines applied');
		Assert.equals(1, partial.revertedEdits, 'one unsafe inline reverted');
		// Cap for N=3 candidates: 2*ceil(log2(3)) + 2 == 6 oracle spawns.
		Assert.isTrue(partial.oracleInvocations <= 6, 'oracle spawns stay within the per-file cap (spent ${partial.oracleInvocations})');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	private function mentions(vs: Array<Violation>, name: String): Bool {
		for (v in vs) if (v.message.indexOf('\'$name\'') >= 0) return true;
		return false;
	}

	#if (sys || nodejs)
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('preferinlineoracle', [
			{ name: 'Main.hx', source: 'class Main {\n\tstatic function main() {}\n}\n' },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n' }
		]);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
