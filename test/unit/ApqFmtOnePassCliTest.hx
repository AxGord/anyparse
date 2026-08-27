package unit;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

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
 * The pair of assertions in `testTwoRewriteFileFailsOnlyUnderOnePass` is the
 * whole point: the SAME source, the SAME mode, exit 0 without the flag and
 * non-zero with it. Either assertion alone would also hold for a flag that
 * failed on any drifted file, which is what `testDriftingOneRewriteFilePasses`
 * refutes.
 */
@:nullSafety(Strict)
class ApqFmtOnePassCliTest extends Test {

	/**
	 * Pony's own `objectLiteral` cascade under a `sameLine.caseBody: fitLine`
	 * switch — one of the three shapes `unit.WrapFlatSourceFixedPointTest` pins
	 * as STILL divergent. Copied rather than shared because that class states
	 * the writer property and this one states the CLI's reaction to it; the
	 * copy carries its own precondition instead, and it is the test below: if
	 * this shape ever converges in one rewrite the `--one-pass` arm goes green
	 * and the test fails, telling you to re-pick the fixture rather than
	 * silently measuring nothing.
	 */
	private static final TWO_REWRITE_CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4, '
		+ '"alignInlineSwitchCaseBody": true}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}, '
		+ '"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": '
		+ '[{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}}}';

	private static final TWO_REWRITE_SRC: String = 'class C {\n\tfunction readNode(xml: Fast): Void {\n'
		+ '\t\tswitch xml.name {\n\t\t\tcase \'zip\':\n\t\t\t\tcfg.zips.push({ path: try '
		+ 'StringTools.trim(xml.innerData) catch (_: Any) \'\', file: xml.att.file, rm: xml.isTrue(\'rm\'), '
		+ 'log: !xml.isFalse(\'log\') });\n\t\t\tcase _:\n\t\t\t\tsuper.readNode(xml);\n\t\t}\n\t}\n}\n';

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

	/** The discriminating pair: one source, one mode, two verdicts. */
	public function testTwoRewriteFileFailsOnlyUnderOnePass(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_fmt_onepass_two', [
			{ name: 'A.hx', source: TWO_REWRITE_SRC },
			{ name: 'hxformat.json', source: TWO_REWRITE_CONFIG }
		]);
		Assert.equals(0, Cli.run(['fmt', dir, '--list']), 'without the flag a two-rewrite file is ordinary drift');
		Assert.notEquals(0, Cli.run(['fmt', dir, '--list', '--one-pass']), 'with the flag it is a failure');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--one-pass` is a MODIFIER, not a mode: `--write` still writes, and to the
	 * fixed point. Folding the finding into the ordinary failure count would have
	 * made `--write` report a file it had just rewritten as one it left alone.
	 */
	public function testWriteStillWritesTheFixedPointAndStillFails(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_fmt_onepass_write', [
			{ name: 'A.hx', source: TWO_REWRITE_SRC },
			{ name: 'hxformat.json', source: TWO_REWRITE_CONFIG }
		]);
		Assert.notEquals(0, Cli.run(['fmt', dir, '--write', '--one-pass']), 'the run reports the writer defect');
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
