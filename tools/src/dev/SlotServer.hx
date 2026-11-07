package dev;

import anyparse.check.oracle.CompilerServer;
import anyparse.proc.PendingRuns;
import anyparse.proc.ProcessSpawn;
import devkit.Cmd.cmd;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * A slot's `haxe --wait` server: started on first use, on a port `CompilerServer.freePort` gives, as a TETHERED job of a background
 * process batch, so it ends with the batch's driver however that goes, and the driver ends it when this process is gone.
 */
@:nullSafety(Strict)
final class SlotServer {

	/** Ports tried before the slot builds cold. */
	private static inline final PORT_ATTEMPTS: Int = 3;

	/** Looks whether a fresh server answers, and the pause between two. */
	private static inline final READY_ATTEMPTS: Int = 10;

	private static inline final READY_PAUSE_MS: Int = 500;

	/** The resident size past which a server is restarted before its next build, unless `APQ_MUTATION_SERVER_MAX_RSS_KB` says otherwise. */
	private static inline final MAX_RSS_KB: Int = 6291456;

	private static inline final BUFFER: Int = 16 * 1024 * 1024;

	private final _groupFile: String;

	/** Where a port candidate comes from, `CompilerServer.randomPort` unless a test holds one. */
	private final _candidate: Null<() -> Int>;

	private var _batch: Null<PendingRuns> = null;
	private var _port: Null<Int> = null;

	public function new(workroot: String, slot: Int, ?candidate: () -> Int) {
		_groupFile = Path.join([workroot, 'slot-$slot.server']);
		_candidate = candidate;
	}

	/** The port of the slot's live server, started in `wt` when there is none; null when none would start. */
	public function port(wt: String): Null<Int> {
		final live: Null<Int> = _port;
		final tether: Null<Int> = tetherPid();
		if (live != null && tether != null && MutationSlot.alive(tether)) return live;
		stop();
		for (_ in 0...PORT_ATTEMPTS) {
			final free: Null<Int> = CompilerServer.freePort([], _candidate);
			if (free == null) return null;
			final port: Int = free;
			if (FileSystem.exists(_groupFile)) FileSystem.deleteFile(_groupFile);
			final batch: PendingRuns = ProcessSpawn.startAll([
				{
					args: ['--wait', '127.0.0.1:$port'],
					cwd: wt,
					tethered: true,
					groupFile: _groupFile
				}
			], BUFFER, 1);
			if (ready(port, wt)) {
				_batch = batch;
				_port = port;
				return port;
			}
			batch.cancel();
		}
		return null;
	}

	/** Stop the server when its resident size passed the cap, so the next build starts a fresh one. */
	public function recycleIfLarge(): Void {
		final tether: Null<Int> = tetherPid();
		if (tether == null) return;
		final child: String = cmd('pgrep -P $tether').run().out.trim().split('\n')[0];
		if (child == '') return;
		final rss: Null<Int> = Std.parseInt(cmd('ps -o rss= -p $child').run().out.trim());
		final cap: Null<Int> = Std.parseInt(Sys.getEnv('APQ_MUTATION_SERVER_MAX_RSS_KB') ?? '');
		if (rss != null && rss > (cap ?? MAX_RSS_KB)) stop();
	}

	/** End the server; the next `port` starts a fresh one. */
	public function stop(): Void {
		_batch?.cancel();
		_batch = null;
		_port = null;
	}

	/** The pid of the tether the driver runs the server under (`SpawnJob.groupFile`), or null before it started. */
	private function tetherPid(): Null<Int> {
		return FileSystem.exists(_groupFile) ? Std.parseInt(File.getContent(_groupFile).split('\n')[0].trim()) : null;
	}

	/** Whether a compilation server answers on `port`: a display-protocol reply, which no other listener gives. */
	private static function ready(port: Int, wt: String): Bool {
		final hxml: String = Path.join([wt, 'test-js-common.hxml']);
		for (_ in 0...READY_ATTEMPTS) {
			final reply: Null<ConnectResult> =
				CompilerServer.connect(port, hxml, wt, ['--display', CompilerServer.invalidateRequest(hxml)]);
			if (reply == null) return false;
			if (CompilerServer.isServerReply(reply.output)) return true;
			MutationSlot.pause(READY_PAUSE_MS);
		}
		return false;
	}

}
