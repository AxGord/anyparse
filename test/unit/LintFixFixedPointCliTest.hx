package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * End-to-end proof that `apq lint --fix` iterates to a FIXED POINT in a
 * single invocation. Each fixture is a cascade where the first fix exposes a
 * finding only a later pass can see: a `redundant-else` `else if` chain (the
 * inner else surfaces once the outer is de-nested) and a dead-code deletion
 * that leaves a local unused. Methods are `public` so `unused-private` does
 * not subsume the whole method, and each fixture is byte-canonical under
 * default writer opts (trailing newline included) so the first-pass canonical
 * gate admits it.
 */
class LintFixFixedPointCliTest extends Test {

	public function testElseIfChainConverges(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass C {\n\tpublic function f():Int {\n\t\tif (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixfp', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--fix', path]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('else') == -1, 'every else de-nested in one invocation: $out');
		cleanup(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testDeadCodeExposesUnusedLocal(): Void {
		#if (sys || nodejs)
		final src: String = 'package p;\n\nclass C {\n\tpublic function f():Void {\n\t\tvar x = 1;\n\t\treturn;\n\t\ttrace(x);\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixfp', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--fix', path]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('trace') == -1, 'dead trace deleted: $out');
		Assert.isTrue(out.indexOf('var x') == -1, 'now-unused local deleted in the same invocation: $out');
		cleanup(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function cleanup(dir: String): Void {
		final p: String = '$dir/Foo.hx';
		if (FileSystem.exists(p)) FileSystem.deleteFile(p);
		if (FileSystem.exists(dir)) FileSystem.deleteDirectory(dir);
	}
	#end

	public function testCrossFileConfinementSafeAcrossPasses(): Void {
		#if (sys || nodejs)
		// A.hx holds a private method `m` with an unused parameter PLUS a
		// redundant-else fixed on pass 1 — which makes A active for pass 2. B.hx
		// overrides `m`, so A is NOT confined (it has a subtype). `unused-parameter`
		// is registered in the --fix loop's `fullScopeIds`, so even on the pass-2
		// subset {A} the cross-file index still includes B and `m`'s parameter stays
		// `Info`. Were the check active-scope, pass 2 would re-lint {A} alone,
		// wrongly conclude `m` confined, and silently break B's override.
		final a: String = 'package p;\n\nclass A {\n\tprivate function m(a:Int, unused:Int):Int {\n\t\treturn a;\n\t}\n\n\tpublic function u():Int {\n\t\tif (c) return 1;\n\t\telse return m(1, 2);\n\t}\n}\n';
		final b: String = 'package p;\n\nclass B extends A {\n\toverride private function m(a:Int, unused:Int):Int {\n\t\treturn a;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixconfine', [{ name: 'A.hx', source: a }, { name: 'B.hx', source: b }]);
		Assert.equals(0, Cli.run(['lint', '--fix', dir]), 'lint --fix exits ok');
		final outA: String = File.getContent('$dir/A.hx');
		Assert.isTrue(outA.indexOf('else') == -1, 'redundant else de-nested (pass 1 ran): $outA');
		Assert.isTrue(outA.indexOf('unused:Int') != -1, 'm parameter kept — A is unconfined via subtype B: $outA');
		if (FileSystem.exists('$dir/A.hx')) FileSystem.deleteFile('$dir/A.hx');
		if (FileSystem.exists('$dir/B.hx')) FileSystem.deleteFile('$dir/B.hx');
		if (FileSystem.exists(dir)) FileSystem.deleteDirectory(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testParamRemovalConflictWithTernaryStaysConsistent(): Void {
		#if (sys || nodejs)
		// `caller`'s `if (flag) return helper(...); return helper(...);` is a
		// prefer-ternary-return candidate whose helper calls sit inside the rewritten
		// region; `helper`'s first parameter is unused. In one pass prefer-ternary's
		// region-rewrite and unused-parameter's call-arg removal collided — the param
		// was dropped from the signature but the call kept all three args
		// (`Too many arguments`). The --fix loop must converge to an arity-consistent
		// (compiling) result.
		final src: String = 'package p;\n\nclass C {\n\tpublic static function caller(flag:Bool):Int {\n\t\tif (flag) return helper(1, 10, 20);\n\t\treturn helper(2, 30, 40);\n\t}\n\n\tstatic function helper(unused:Int, b:Int, c:Int):Int {\n\t\treturn b + c;\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('fixfp', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--fix', path]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		Assert.isFalse(
			out.indexOf('helper(b:Int, c:Int)') != -1 && out.indexOf('helper(1, 10, 20)') != -1,
			'unused-parameter dropped the param but prefer-ternary kept the call arg -> arity mismatch: $out'
		);
		cleanup(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
