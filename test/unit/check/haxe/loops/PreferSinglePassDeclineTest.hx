package unit.check.haxe.loops;

import anyparse.check.haxe.loops.PreferSinglePass;

/**
 * A `prefer-single-pass` finding the fix leaves unrewritten carries the gate that held it back in
 * `Violation.declineReason`, so `lint --fix`'s ledger names the reason instead of "no edit, no reason".
 */
class PreferSinglePassDeclineTest extends Test {

	/** The reason reaches the finding the caller holds, so the `--fix` ledger can print it. */
	@:pin('control')
	@:killer('M-PSP-DECLINE-NOTE')
	public function testReportOnlyChainsSayWhy(): Void {
		for (statement in [
			'final ys = xs.filter(x -> one(x) > 1).map(x -> x * 2);',
			'final ys = xs.filter(x -> x % k == 0).map(x -> x % k);',
			'final ys = xs.map(x -> x + 1).filter(y -> y > 1);',
			'final ys = xs.filter(x -> x > 1) /* c */ .map(x -> x * 2);',
			'final ys = xs.filter(x -> x > 1).map((x: Int) -> x * 2);',
			'final ys = xs.filter(x -> x > 1).map(y -> y + x);',
			'same(xs.filter(x -> one(x) > 1).map(x -> x * 2));'
		]) Assert.notNull(declineOf(statement), statement);
	}

	public function testMergedChainSaysNothing(): Void {
		Assert.isNull(declineOf('final ys = xs.filter(x -> x > 1).map(x -> x * 2);'));
	}

	/** The decline note the fix leaves on the one finding of `statement`, or null when it took an edit. */
	private function declineOf(statement: String): Null<String> {
		final src: String = 'class C {\n\tfunction one(a: Int): Int {\n\t\treturn a;\n\t}\n\n\tfunction same(a: Array<Int>): Void {}\n\n'
			+ '\tfunction f(xs: Array<Int>, k: Int): Void {\n\t\t$statement\n\t}\n}';
		final run: FixRun = CheckFixture.fixRun(new PreferSinglePass(), [{ file: 'C.hx', source: src }]);
		Assert.equals(1, run.violations.length);
		return run.violations[0].declineReason;
	}

}
