package unit.cli;

import anyparse.query.Cli;

/**
 * End-to-end probe for `apq fmt --one-pass` — the gate for the one class no
 * other tree-level check can see.
 *
 * `fmt` writes the writer's FIXED POINT, not one round trip, so a file the
 * writer settles only on its SECOND rewrite is reported CANONICAL by `--list`
 * once it has been written — while the next writer-emit mutation op refuses it,
 * because that op's gate is `writeRoundTrip(s) == s` after ONE pass. The flag
 * closes the gap by turning the stderr note `fmt` already prints into a
 * non-zero exit.
 *
 * A flag that failed on any drifted file is what `testDriftingOneRewriteFilePasses` refutes.
 */
@:nullSafety(Strict)
class ApqFmtOnePassCliTest extends Test {

	/**
	 * Pony's own `objectLiteral` cascade over an object literal whose array field holds two parenthesised
	 * type-checks under a rules-free `fillLine` array (the stacked mechanisms) — the last shape that needed a second
	 * rewrite. Once no array read its source breaks it settles in one, as `unit.format.WrapFlatSourceFixedPointTest` pins,
	 * and no known source needs two: the failing verdict of `--one-pass` has no fixture until one turns up.
	 */
	private static final TWO_REWRITE_CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": '
		+ '140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "'
		+ 'type": "noWrap"}]}, "arrayWrap": {"defaultWrap": "fillLine", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 0}], '
		+ '"type": "noWrap"}]}}}';

	private static final TWO_REWRITE_SRC: String = 'class A {\n\tpublic static function createElectron(output: String): Void {\n'
		+ '\t\tfinal data = { version: \'0.2.0\', configurations: [\n\t\t\t({ type: \'node\', request: \'launch\', name: '
		+ 'mainConfName, protocol: \'inspector\', runtimeExecutable: electronExecutable, runtimeArgs: ['
		+ 'output, \'--remote-debugging-port\'], windows: { runtimeExecutable: electronExecutable\n'
		+ '\t\t\t\t+ \'.cmd\' }, preLaunchTask: PRELAUNCH_TASK, internalConsoleOptions: \'neverOpen\' }: Dynamic),\n\t\t'
		+ '\t({ name: renderConfName, type: \'chrome\', request: \'attach\', port: port, webRoot: resultDir, timeout: 20000, '
		+ 'internalConsoleOptions: \'openOnSessionStart\' }: Dynamic)\n\t\t], compounds: [{ name: \'AllConfigurations\', '
		+ 'configurations: [mainConfName, renderConfName] }] };\n\t\tUtils.saveJson(\'.vscode/launch.json\', data);\n\t}\n}\n';

	/** A canonical tree answers the flag exactly as it answers `--list`. */
	public function testCanonicalFilePassesOnePass(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_fmt_onepass_ok', [{ name: 'A.hx', source: 'class A {}\n' }]);
		Assert.equals(0, Cli.run(['fmt', dir, '--list', '--one-pass']));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The must-not-fire half. A file that DRIFTS is not a file the writer failed
	 * to settle — one rewrite reaches its fixed point, which is the healthy case
	 * and by far the common one. Without this, a flag that simply failed on any
	 * non-canonical file would pass the test below.
	 */
	public function testDriftingOneRewriteFilePasses(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_fmt_onepass_drift', [{ name: 'A.hx', source: 'class A{function f(){g();}}\n' }]);
		Assert.equals(0, Cli.run(['fmt', dir, '--list', '--one-pass']), 'a drifted file that settles in ONE rewrite is not a finding');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The formerly divergent shape settles in one rewrite, so the flag answers it like `--list`. */
	public function testFormerlyTwoRewriteFilePassesOnePass(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_fmt_onepass_two', [
			{ name: 'A.hx', source: TWO_REWRITE_SRC },
			{ name: 'hxformat.json', source: TWO_REWRITE_CONFIG }
		]);
		Assert.equals(0, Cli.run(['fmt', dir, '--list']), 'without the flag a two-rewrite file is ordinary drift');
		Assert.equals(0, Cli.run(['fmt', dir, '--list', '--one-pass']), 'with the flag it settles in one rewrite too');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--one-pass` is a MODIFIER, not a mode: `--write` still writes, and to the fixed point. */
	public function testWriteStillWritesTheFixedPoint(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_fmt_onepass_write', [
			{ name: 'A.hx', source: TWO_REWRITE_SRC },
			{ name: 'hxformat.json', source: TWO_REWRITE_CONFIG }
		]);
		Assert.equals(0, Cli.run(['fmt', dir, '--write', '--one-pass']), 'a one-rewrite file is no finding');
		Assert.notEquals(TWO_REWRITE_SRC, sys.io.File.getContent('$dir/A.hx'), '--write must still have rewritten the file');
		// The written bytes ARE the fixed point, so the same gate is green on them —
		// which is exactly why the flag has to be asked on the pre-canonical source
		// and cannot be inferred from an already-formatted tree.
		Assert.equals(0, Cli.run(['fmt', dir, '--list', '--one-pass']), 'the written file is its own fixed point');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
