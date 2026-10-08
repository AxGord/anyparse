package unit.check;

/**
 * What a lifetime fixture asks of the machine's process table: which processes run a command line, whether a pid still
 * runs, and a bounded wait for a set of pids to be gone. Off node, and off a machine with `ps`, every answer is empty.
 */
@:nullSafety(Strict)
final class ProcessProbe {

	/** Milliseconds a tethered process is given to end once its driver is gone: the tether notices at once. */
	private static inline final GONE_MS: Int = 3000;

	/** Milliseconds between two looks while `awaitGone` waits. */
	private static inline final POLL_MS: Int = 100;

	/** The pids of every process whose command line contains `fragment`. */
	public static function pidsRunning(fragment: String): Array<Int> {
		#if nodejs
		final res: Dynamic = js.node.ChildProcess.spawnSync('ps', ['-A', '-o', 'pid=,command='], { encoding: 'utf8' });
		final out: String = res.stdout == null ? '' : '${res.stdout}';
		final pids: Array<Int> = [];
		for (line in out.split('\n')) {
			final row: String = StringTools.trim(line);
			final gap: Int = row.indexOf(' ');
			if (gap <= 0 || row.indexOf(fragment, gap) < 0) continue;
			final pid: Null<Int> = Std.parseInt(row.substring(0, gap));
			if (pid != null) pids.push(pid);
		}
		return pids;
		#else
		return [];
		#end
	}

	/** The pids of every process descending from `root` whose command line contains `fragment`. */
	public static function descendantsRunning(root: Int, fragment: String): Array<Int> {
		#if nodejs
		final res: Dynamic = js.node.ChildProcess.spawnSync('ps', ['-A', '-o', 'pid=,ppid=,command='], { encoding: 'utf8' });
		final out: String = res.stdout == null ? '' : '${res.stdout}';
		final rows: Array<{ pid: Int, ppid: Int, command: String }> = [];
		final row: EReg = ~/^\s*(\d+)\s+(\d+)\s+(.*)$/;
		for (line in out.split('\n')) if (row.match(line)) rows.push({
			pid: Std.parseInt(row.matched(1)) ?? 0,
			ppid: Std.parseInt(row.matched(2)) ?? 0,
			command: row.matched(3)
		});
		final found: Array<Int> = [];
		var front: Array<Int> = [root];
		while (front.length > 0) {
			final next: Array<Int> = [for (r in rows) if (front.contains(r.ppid)) r.pid];
			for (r in rows) if (front.contains(r.ppid) && r.command.indexOf(fragment) >= 0) found.push(r.pid);
			front = next;
		}
		return found;
		#else
		return [];
		#end
	}

	/** Whether `pid` still runs: a zombie nobody reaped yet counts as gone. */
	public static function alive(pid: Int): Bool {
		#if nodejs
		final res: Dynamic = js.node.ChildProcess.spawnSync('ps', ['-o', 'stat=', '-p', '$pid'], { encoding: 'utf8' });
		final state: String = StringTools.trim(res.stdout == null ? '' : '${res.stdout}');
		return state != '' && !StringTools.startsWith(state, 'Z');
		#else
		return false;
		#end
	}

	/** The ones of `pids` still running after waiting up to `ms` milliseconds for all of them to end. */
	public static function awaitGone(pids: Array<Int>, ms: Int): Array<Int> {
		final until: Float = Sys.time() + ms / 1000;
		var left: Array<Int> = pids.filter(alive);
		while (left.length > 0 && Sys.time() < until) {
			Sys.sleep(POLL_MS / 1000);
			left = left.filter(alive);
		}
		return left;
	}

	/**
	 * SIGKILL `driver` — what a SIGKILL of the process group it shares with `apq` does to it, leaving it no handler to run
	 * — and answer the ones of `pids` still running a few seconds later, SIGKILLed in turn so a red run leaks nothing.
	 */
	public static function outlivingKilledDriver(driver: Int, pids: Array<Int>): Array<Int> {
		#if nodejs
		js.Node.process.kill(driver, 'SIGKILL');
		#end
		final left: Array<Int> = awaitGone(pids, GONE_MS);
		killAll(left);
		return left;
	}

	/** SIGKILL every one of `pids` — a fixture's cleanup of what it failed to see end, so a red run leaks nothing. */
	public static function killAll(pids: Array<Int>): Void {
		#if nodejs
		for (pid in pids) try js.Node.process.kill(pid, 'SIGKILL') catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// already gone
		}
		#end
	}

}
