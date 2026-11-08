package anyparse.proc;

/**
 * Blocking the calling thread for a span without spawning anything: the one answer to "how does this thread wait
 * `ms` milliseconds". The js target waits on a shared-memory cell, which parks the thread instead of spinning on
 * the clock the way `Sys.sleep` does there; the other `sys` targets call `Sys.sleep`.
 */
final class Sleep {

	private static inline final MS_PER_SECOND: Int = 1000;

	/** Block this thread for `ms` milliseconds; returns once they have passed. */
	public static inline function pause(ms: Int): Void {
		#if nodejs
		js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, {0})', ms);
		#elseif sys
		Sys.sleep(ms / MS_PER_SECOND);
		#end
	}

}
