package unit.check;

import anyparse.check.HaxeSpawn;
import utest.Assert;
import utest.Test;

/**
 * `HaxeSpawn.parallelismFor`: how many compiles of one project run at once. A compile is a single-threaded process the
 * caller only waits on, so the budget is every core but one, bounded by memory and by the hard cap.
 */
@:nullSafety(Strict)
final class OracleParallelismTest extends Test {

	private static inline final GIB: Float = 1024.0 * 1024 * 1024;

	@:pin('control')
	@:killer('M-ORACLE-PARALLEL-HALF-THE-CORES')
	public function testTheBudgetIsEveryCoreButOne(): Void {
		Assert.equals(15, HaxeSpawn.parallelismFor(16, 64 * GIB), 'sixteen cores and room for all: fifteen compiles');
		Assert.equals(3, HaxeSpawn.parallelismFor(4, 64 * GIB));
	}

	@:pin('guard')
	public function testMemoryTheCapAndOneBoundTheBudget(): Void {
		Assert.equals(4, HaxeSpawn.parallelismFor(16, 8 * GIB), 'eight GiB hold four compiles at two each');
		Assert.equals(16, HaxeSpawn.parallelismFor(64, 256 * GIB), 'never past the cap');
		Assert.equals(1, HaxeSpawn.parallelismFor(1, 64 * GIB), 'never fewer than one');
		Assert.equals(1, HaxeSpawn.parallelismFor(8, GIB), 'never fewer than one, whatever the memory');
	}

}
