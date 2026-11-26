package unit.devkit;

import devkit.Cmd.cmd;
import devkit.Result;

/**
 * The silence watchdog of a leased command: the wait for the pool's grant is queueing, not silence; only a command that holds
 * its grant and writes nothing is cut. A stand-in wrapper sleeps before it hands over, as a busy pool does.
 */
@:nullSafety(Strict)
final class LeaseWaitWatchdogTest extends Test {

	/** Prints one line and ends. */
	private static final PRINT_X: String = 'console.log("x")';

	/** Never ends by itself. */
	private static final HANG: String = 'setInterval(() => {}, 1000)';

	private final _node: String = js.Node.process.execPath;

	/** A leased command waiting longer than its idle time for the grant is not stalled, and runs to its end. */
	@:pin('control')
	@:killer('M-LEASE-WAIT-COUNTS-AS-SILENCE')
	public function testAPoolWaitLongerThanTheIdleTimeIsNotAStall(): Void {
		TempDir.with(dir -> {
			final run: Result = cmd('$_node -e $PRINT_X')
				.timeout(60000)
				.watched(1000, dir.file('never-written'))
				.leasedUnder(['sh', '-c', 'sleep 2.5; exec "$@"', 'sh'])
				.run();
			Assert.equals('', run.failure);
			Assert.equals(0, run.status);
			Assert.equals('x\n', run.out);
		});
	}

	/** The same wait with `awaitProgress` and a progress file that already moved before the grant. */
	@:pin('control')
	@:killer('M-LEASE-WAIT-COUNTS-AS-SILENCE')
	public function testAPoolWaitAfterTheProgressFileMovedIsNotAStall(): Void {
		TempDir.with(dir -> {
			final progress: String = dir.file('progress');
			final run: Result = cmd('$_node -e $PRINT_X')
				.timeout(60000)
				.watched(1000, progress, true)
				.leasedUnder(['sh', '-c', 'sleep 0.3; echo moved > "$0"; sleep 2.5; exec "$@"', progress])
				.run();
			Assert.equals('', run.failure);
			Assert.equals(0, run.status);
		});
	}

	/** A leased command that holds its grant and stays silent is still cut at its idle time. */
	@:pin('guard')
	public function testAGrantedCommandThatStaysSilentIsCut(): Void {
		TempDir.with(dir -> {
			final run: Result = cmd('$_node -e $HANG')
				.timeout(60000)
				.watched(1000, dir.file('never-written'))
				.leasedUnder(['sh', '-c', 'exec "$@"', 'sh'])
				.run();
			Assert.isNull(run.status);
			Assert.stringContains('no progress for 1 s', run.failure);
		});
	}

}
