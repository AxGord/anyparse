package anyparse.core;

/**
 * The threads a workflow pool lease granted this process (`WF_THREADS`): under a lease the pool owns the machine's
 * budget, and every tool that sizes a fan-out of its own processes takes this in place of its own measure of the machine.
 */
@:nullSafety(Strict)
final class PoolLease {

	/** The threads the lease grants, or null outside a lease: unset, empty, or not a positive integer. */
	public static function threads(): Null<Int> {
		#if (sys || nodejs)
		final threads: Null<Int> = Std.parseInt(Sys.getEnv('WF_THREADS') ?? '');
		return threads != null && threads > 0 ? threads : null;
		#else
		return null;
		#end
	}

}
