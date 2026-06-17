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

}
