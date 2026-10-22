package unit.dev;

import dev.BenchAb;
import utest.Assert;
import utest.Test;

/**
 * `dev bench-ab`'s arithmetic: the reading it takes from a harness line, and the medians row — the LOWER middle of an
 * even count, every number to one decimal, as the shell version's `awk` printed it under a C locale.
 */
@:nullSafety(Strict)
final class BenchAbTest extends Test {

	public function testTheReadingIsTheMsPerRepFieldAsWritten(): Void {
		Assert.equals('76.30', BenchAb.msPerRep('MODE=tparse files=48 reps=1 ms=76.30 msPerRep=76.30 parsed=48'));
		Assert.isNull(BenchAb.msPerRep('unknown-mode=x'), 'a line with no reading');
	}

	public function testTheMedianRow(): Void {
		Assert.equals('a                median=     76.3  n=3  min=     74.9  max=     76.4', BenchAb.medianRow('a', [76.36, 74.89, 76.3]));
		Assert.equals('even             median=      2.0  n=4  min=      1.0  max=      4.0', BenchAb.medianRow('even', [4, 1, 3, 2]));
		Assert.equals('none             median=      0.0  n=0  min=      0.0  max=      0.0', BenchAb.medianRow('none', []));
	}

}
