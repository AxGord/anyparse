package unit.cli;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * End-to-end probe for `apq fmt --verify` — the audit that formats each file in
 * memory and requires the output to differ from the input by WHITESPACE only.
 *
 * The last case is the positive control: a source whose reformat legitimately
 * changes a TOKEN (the trailing comma policy drops one). Without it the suite
 * would only ever show this check passing, which is indistinguishable from a
 * check that can no longer fail.
 */
@:nullSafety(Strict)
class ApqFmtVerifyCliTest extends Test {

	public function testCanonicalFileVerifies(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_fmt_verify_ok', [{ name: 'A.hx', source: 'class A {}\n' }]);
		Assert.equals(0, Cli.run(['fmt', dir, '--verify']));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testWhitespaceOnlyReformatVerifies(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_fmt_verify_ws', [{ name: 'A.hx', source: 'class A{function f(){g();}}\n' }]);
		Assert.equals(0, Cli.run(['fmt', dir, '--verify']));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testVerifyNeverWrites(): Void {
		#if (sys || nodejs)
		final source: String = 'class A{function f(){g();}}\n';
		final dir: String = CliFixture.writeDir('apq_fmt_verify_ro', [{ name: 'A.hx', source: source }]);
		Assert.equals(0, Cli.run(['fmt', dir, '--verify', '--write']));
		Assert.equals(source, sys.io.File.getContent('$dir/A.hx'), '--verify must not rewrite the file even alongside --write');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTokenChangingReformatFailsVerification(): Void {
		#if (sys || nodejs)
		// The trailing comma in `g(a, b,)` is dropped by the writer — a real token
		// change, and exactly the class of divergence the audit exists to surface.
		final dir: String = CliFixture.writeDir(
			'apq_fmt_verify_token', [{ name: 'A.hx', source: 'class A {\n\tfunction f() {\n\t\tg(a, b,);\n\t}\n}\n' }]
		);
		Assert.notEquals(0, Cli.run(['fmt', dir, '--verify']));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
