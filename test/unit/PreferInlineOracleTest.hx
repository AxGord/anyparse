package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle;
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
		final src: String = 'class Main {\n\n\tstatic function main() {\n\t\ttrace(make());\n\t}\n\n\tstatic function make():Dynamic\n\t\treturn {a: 1, b: 2};\n\n}\n';
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
		final main: String = '@:nullSafety(Strict)\nclass Main {\n\n\tstatic function main() {\n\t\tfinal n:Null<Int> = Std.random(2) == 0 ? 1 : null;\n\t\ttrace(Lib.box(n));\n\t}\n\n}\n';
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
