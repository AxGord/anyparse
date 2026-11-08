package unit.proc;

import anyparse.proc.Sleep;

/** `Sleep.pause`: the calling thread waits the whole span, and parks while it does. */
@:nullSafety(Strict)
final class SleepTest extends Test {

	/** Milliseconds paused: long enough to read off a clock, short enough to cost nothing. */
	private static inline final SPAN_MS: Int = 150;

	/** Microseconds in a millisecond. */
	private static inline final MICROS_PER_MS: Int = 1000;

	/** The call returns only after the span has passed. */
	@:pin('control')
	@:killer('M-SLEEP-RETURNS-AT-ONCE')
	public function testPauseBlocksForTheSpan(): Void {
		final began: Float = Date.now().getTime();
		Sleep.pause(SPAN_MS);
		Assert.isTrue(Date.now().getTime() - began >= SPAN_MS, 'the thread waited the whole span');
	}

	/** The wait parks the thread: the process spends a small share of the span on a CPU, where a clock-polling wait spends all of it. */
	@:pin('control')
	@:killer('M-SLEEP-SPINS')
	public function testPauseParksTheThread(): Void {
		#if nodejs
		final before: Float = cpuMicros();
		Sleep.pause(SPAN_MS);
		Assert.isTrue((cpuMicros() - before) / MICROS_PER_MS < SPAN_MS / 2, 'the CPU time spent is under half the span');
		#else
		Assert.pass('no parked wait to measure on this target');
		#end
	}

	#if nodejs
	/** User plus system CPU time this process has spent, in microseconds. */
	private static function cpuMicros(): Float {
		return js.Syntax.code('(function () { const u = process.cpuUsage(); return u.user + u.system; })()');
	}
	#end

}
