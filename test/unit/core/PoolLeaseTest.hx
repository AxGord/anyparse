package unit.core;

import anyparse.core.PoolLease;
import unit.cli.CliFixture;

/** `PoolLease.threads`: the threads a pool lease grants, read from `WF_THREADS`; anything but a positive integer is no lease. */
@:nullSafety(Strict)
final class PoolLeaseTest extends Test {

	@:pin('guard')
	public function testOnlyAPositiveIntegerIsALease(): Void {
		final leased: Null<String> = Sys.getEnv('WF_THREADS');
		final read: Array<Null<Int>> = [];
		CliFixture.always(() -> Sys.putEnv('WF_THREADS', leased ?? ''), () -> {
			for (value in ['6', '', '0', '-2', 'many']) {
				Sys.putEnv('WF_THREADS', value);
				read.push(PoolLease.threads());
			}
		});
		Assert.same([6, null, null, null, null], read);
	}

}
