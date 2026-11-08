package unit.dev;

import dev.ForkFmt;
import devkit.Command;
import utest.Assert;
import utest.Test;

/**
 * `dev.ForkFmt`: the verdict on the fork's tree, read off the verify's output and never off its exit status, and the slice trigger.
 * The engine is faked by a command printing what `fmt --verify --one-pass` prints.
 */
@:nullSafety(Strict)
final class ForkFmtTest extends Test {

	private static final CLEAN: String = 'apq fmt: /f/src/A.hx: unexpected input\n'
		+ 'apq fmt --verify: 0 of 10 reformatted file(s) changed more than whitespace (36 scanned, 1 could not be formatted)';

	@:pin('control')
	@:killer('M-FORK-FMT-DIVERGENCE-BLIND')
	public function testANonWhitespaceDivergenceFails(): Void {
		final verdict: ForkVerdict = ForkFmt.verify(
			_ ->
				printing(
					'/f/src/B.hx: formatting changed more than whitespace\n'
					+ 'apq fmt --verify: 1 of 10 reformatted file(s) changed more than whitespace'
				),
			'/f'
		);
		Assert.equals(1, verdict.why.length);
		Assert.stringContains('non-whitespace divergence in /f/src', verdict.why[0]);
		Assert.contains('/f/src/B.hx: formatting changed more than whitespace', verdict.shown);
	}

	@:pin('control')
	@:killer('M-FORK-FMT-ONE-PASS-BLIND')
	public function testAFileNeedingASecondRewriteFails(): Void {
		final verdict: ForkVerdict = ForkFmt.verify(
			_ ->
				printing(
					'apq fmt --one-pass: /f/src/C.hx: the writer needed 2 rewrites to reach its fixed point\n'
					+ 'apq fmt --verify: 0 of 10 reformatted file(s) changed more than whitespace'
				),
			'/f'
		);
		Assert.equals(1, verdict.why.length);
		Assert.stringContains('more than one rewrite', verdict.why[0]);
		Assert.equals(2, verdict.shown.length);
	}

	/** A file the grammar cannot parse exits non-zero on a clean tree; only the two failure lines are a verdict. */
	@:pin('control')
	@:killer('M-FORK-FMT-EXIT-STATUS')
	public function testACleanTreeHoldsWhateverTheExitStatus(): Void {
		final verdict: ForkVerdict = ForkFmt.verify(_ -> failing(CLEAN), '/f');
		Assert.same([], verdict.why);
		Assert.same([
			'apq fmt --verify: 0 of 10 reformatted file(s) changed more than whitespace (36 scanned, 1 could not be formatted)'
		], verdict.shown);
	}

	@:pin('control')
	@:killer('M-FORK-FMT-UNSET-PASSES')
	public function testWithoutAForkTheVerifyFailsAndRunsNothing(): Void {
		var ran: Bool = false;
		for (fork in [null, '']) {
			final verdict: ForkVerdict = ForkFmt.verify(_ -> {
				ran = true;
				return printing(CLEAN);
			}, fork);
			Assert.equals(1, verdict.why.length);
			Assert.stringContains('unset', verdict.why[0]);
		}
		Assert.isFalse(ran);
	}

	public function testTheVerifyRunsOverTheForkSrcOnePass(): Void {
		var seen: Array<String> = [];
		final verdict: ForkVerdict = ForkFmt.verify(args -> {
			seen = args;
			return printing(CLEAN);
		}, '/f');
		Assert.same(['fmt', '--verify', '--one-pass', '/f/src'], seen);
		Assert.same([], verdict.why);
	}

	@:pin('control')
	@:killer('M-FORK-FMT-OWED-NEVER')
	public function testASliceOwesTheVerifyWhenTheEngineOrAConfigMoved(): Void {
		Assert.isTrue(ForkFmt.owedBy(['docs/a.md', 'src/anyparse/core/A.hx']));
		Assert.isTrue(ForkFmt.owedBy(['apq.json']));
		Assert.isTrue(ForkFmt.owedBy(['hxformat.json']));
		Assert.isFalse(ForkFmt.owedBy(['test/unit/A.hx', 'tools/src/dev/B.hx', 'docs/a.md']));
		Assert.isFalse(ForkFmt.owedBy([]));
	}

	/** A command that prints `text` on its standard error. */
	private static function printing(text: String): Command {
		return Command.of(['sh', '-c', 'printf "%s\\n" "$$1" >&2', 'sh', text]);
	}

	/** A command that prints `text` on its standard error and exits non-zero. */
	private static function failing(text: String): Command {
		return Command.of(['sh', '-c', 'printf "%s\\n" "$$1" >&2; exit 1', 'sh', text]);
	}

}
