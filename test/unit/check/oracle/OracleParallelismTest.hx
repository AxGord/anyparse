package unit.check.oracle;

import anyparse.check.oracle.HaxeSpawn;

/**
 * `HaxeSpawn.parallelism`: how many compiles of one project run at once. A compile is a single-threaded process the
 * caller only waits on, so the budget is the threads — a pool lease's, or the machine's performance cores, or every core
 * but one — bounded by memory and by the hard cap.
 */
@:nullSafety(Strict)
final class OracleParallelismTest extends Test {

	private static inline final GIB: Float = 1024.0 * 1024 * 1024;

	@:pin('control')
	@:killer('M-ORACLE-PARALLEL-HALF-THE-CORES')
	public function testTheBudgetIsEveryCoreButOne(): Void {
		Assert.equals(15, HaxeSpawn.threadsFor(16, 16), 'sixteen cores of one kind: fifteen compiles');
		Assert.equals(3, HaxeSpawn.threadsFor(4, 4));
		Assert.equals(15, HaxeSpawn.parallelismFor(15, 64 * GIB, false), 'room for all: every thread compiles');
	}

	@:pin('control')
	@:killer('M-ORACLE-PARALLEL-COUNTS-SLOW-CORES')
	public function testAMachineWithSlowerCoresBudgetsItsPerformanceCores(): Void {
		Assert.equals(12, HaxeSpawn.threadsFor(16, 12), 'twelve performance cores beside four efficiency ones: twelve compiles');
		Assert.equals(3, HaxeSpawn.threadsFor(4, 0), 'no performance cores reported: every core but one');
	}

	@:pin('control')
	@:killer('M-ORACLE-PARALLEL-IGNORES-LEASE')
	public function testAPoolLeaseIsTheBudget(): Void {
		final declared: Null<String> = Sys.getEnv('APQ_ORACLE_PARALLEL');
		final leased: Null<String> = Sys.getEnv('WF_THREADS');
		var parallel: Int = 0;
		CliFixture.always(() -> {
			Sys.putEnv('APQ_ORACLE_PARALLEL', declared ?? '');
			Sys.putEnv('WF_THREADS', leased ?? '');
		}, () -> {
			Sys.putEnv('APQ_ORACLE_PARALLEL', '');
			Sys.putEnv('WF_THREADS', '1');
			parallel = HaxeSpawn.parallelism();
		});
		Assert.equals(1, parallel, 'a lease of one thread runs one compile at a time');
	}

	@:pin('guard')
	public function testMemoryTheCapAndOneBoundTheBudget(): Void {
		Assert.equals(4, HaxeSpawn.parallelismFor(15, 8 * GIB, false), 'eight GiB hold four compiles at two each');
		Assert.equals(16, HaxeSpawn.parallelismFor(63, 256 * GIB, false), 'never past the cap');
		Assert.equals(1, HaxeSpawn.parallelismFor(0, 64 * GIB, false), 'never fewer than one');
		Assert.equals(1, HaxeSpawn.parallelismFor(7, GIB, false), 'never fewer than one, whatever the memory');
		Assert.equals(3, HaxeSpawn.residentFor(8 * GIB, true), 'a tuned collector budgets more memory per compile');
	}

	@:pin('guard')
	public function testALinuxCpuListIsCounted(): Void {
		Assert.equals(16, HaxeSpawn.cpuListCount('0-7,16-23\n'));
		Assert.equals(3, HaxeSpawn.cpuListCount('0,2-3'));
		Assert.isNull(HaxeSpawn.cpuListCount('0-x'), 'an unreadable list counts nothing');
		Assert.isNull(HaxeSpawn.cpuListCount('4-2'), 'nor does a reversed range');
	}

}
