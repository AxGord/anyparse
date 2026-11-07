package unit.cli;

import anyparse.query.Cli;

/**
 * End-to-end probe for `apq fmt --verify` — the audit that formats each file in
 * memory and requires the output to differ from the input by WHITESPACE only.
 *
 * The token-change case is the positive control: a source whose reformat
 * legitimately changes a TOKEN (`singleStatementBraces: remove` drops a brace
 * pair). Without it the suite would only ever show this check passing, which is
 * indistinguishable from a check that can no longer fail. A trailing comma the
 * `trailingComma` knob drops is the one token change verify does not report.
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
		// A dropped brace pair is a real token change, exactly the class of
		// divergence the audit exists to surface.
		final dir: String = CliFixture.writeDir('apq_fmt_verify_token', [
			{ name: 'hxformat.json', source: '{"whitespace": {"bracesConfig": {"singleStatementBraces": "remove"}}}\n' },
			{ name: 'A.hx', source: 'class A {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tb();\n\t\t}\n\t}\n}\n' }
		]);
		Assert.notEquals(0, Cli.run(['fmt', dir, '--verify']));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-VERIFY-TRAILING-COMMA-EXEMPT-OFF')
	public function testDroppedTrailingCommasVerify(): Void {
		#if (sys || nodejs)
		// The default `remove` drops the trailing comma of a flat and of a multi-line list; neither is a divergence.
		final dir: String = CliFixture.writeDir('apq_fmt_verify_comma', [
			{ name: 'A.hx', source: 'class A {\n\tstatic var x = [1, 2,];\n\tstatic var y = [\n\t\t1,\n\t\t2,\n\t];\n}\n' }
		]);
		Assert.equals(0, Cli.run(['fmt', dir, '--verify']));
		CliFixture.removeDir(dir);
		// the commonest multi-line layout keeps a comment between the comma and the closer
		final commented: String = CliFixture.writeDir('apq_fmt_verify_comma_comment', [
			{
				name: 'A.hx',
				source: 'class A {\n\tstatic var y = [\n\t\t1,\n\t\t2, // two\n\t];\n\tstatic var z = [\n\t\t1,\n\t\t2,\n\t\t// tail\n'
				+ '\t];\n}\n'
			}
		]);
		Assert.equals(0, Cli.run(['fmt', commented, '--verify']));
		CliFixture.removeDir(commented);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLiteralsAreComparedVerbatimWhileTheRestIsReformatted(): Void {
		#if (sys || nodejs)
		// strings holding `,]` and runs of spaces, an interpolation hole (its code is re-laid) and a regex survive the reformat untouched
		final dir: String = CliFixture.writeDir('apq_fmt_verify_literals', [
			{
				name: 'A.hx',
				source: 'class A{static var s="a,]  b";static var t=\'x $${ s+1 } ,] y\';static var r=~/a  ,]/;static var l=[1,2,];}\n'
			}
		]);
		Assert.equals(0, Cli.run(['fmt', dir, '--verify']));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
