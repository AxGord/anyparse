package unit.devkit;

import devkit.TempDir;
import devkit.TmpLifecycle;
import haxe.io.Path;
import js.Node;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `TmpLifecycle` — which scratch directories a sweep may take: a claimed name directly under the root, no keep marker,
 * no live owner, and silent for the grace period (the legacy one when unstamped).
 */
@:nullSafety(Strict)
final class TmpLifecycleTest extends Test {

	private static inline final GRACE: Int = 300;
	private static inline final LEGACY: Int = 21600;

	/** A pid no process holds: above every default `pid_max`. */
	private static inline final DEAD_PID: String = '99999999';

	/** Seconds of silence past the grace period and short of the legacy one. */
	private static inline final PAST_GRACE: Int = 600;

	/** Seconds of silence past the legacy period. */
	private static inline final PAST_LEGACY: Int = 30000;

	private static inline final MS_PER_SECOND: Float = 1000;

	public function testOnlyAClaimNameDirectlyUnderTheRootIsOurs(): Void {
		TempDir.with(dir -> {
			final dirs: TmpLifecycle = lifecycle(dir.path);
			Assert.isNull(dirs.refusal('${dir.path}/apq-x.abc123'));
			Assert.notNull(dirs.refusal('/elsewhere/apq-x.abc123'), 'not under the root');
			Assert.notNull(dirs.refusal('${dir.path}/apq-x.abc123/sub'), 'not a direct child');
			Assert.notNull(dirs.refusal('${dir.path}/apq-x.abc1234'), 'seven characters after the prefix');
			Assert.notNull(dirs.refusal('${dir.path}/other.abc123'), 'not a prefix of ours');
		});
	}

	public function testTheSweepTakesTheOrphansAndNothingElse(): Void {
		TempDir.with(dir -> {
			final dirs: TmpLifecycle = lifecycle(dir.path);
			final now: Int = TmpLifecycle.now();
			final cases: Array<{
				name: String,
				owner: Null<String>,
				idle: Int,
				kept: Bool,
				orphan: Bool
			}> = [
				{
					name: 'apq-x.dead01',
					owner: DEAD_PID,
					idle: PAST_GRACE,
					kept: false,
					orphan: true
				},
				{
					name: 'apq-x.live02',
					owner: '${Node.process.pid}',
					idle: PAST_GRACE,
					kept: false,
					orphan: false
				},
				{
					name: 'apq-x.keep03',
					owner: DEAD_PID,
					idle: PAST_GRACE,
					kept: true,
					orphan: false
				},
				{
					name: 'apq-x.young4',
					owner: DEAD_PID,
					idle: 0,
					kept: false,
					orphan: false
				},
				{
					name: 'apq-y.nopid5',
					owner: 'notapid',
					idle: PAST_GRACE,
					kept: false,
					orphan: true
				},
				{
					name: 'apq-y.legcy6',
					owner: null,
					idle: PAST_GRACE,
					kept: false,
					orphan: false
				},
				{
					name: 'apq-y.legcy7',
					owner: null,
					idle: PAST_LEGACY,
					kept: false,
					orphan: true
				}
			];
			for (c in cases) {
				final path: String = '${dir.path}/${c.name}';
				FileSystem.createDirectory(path);
				File.saveContent('$path/log', 'x');
				if (c.owner != null) File.saveContent('$path/.apq-owner', 'pid ${c.owner}\ntool x\nstarted 1\n');
				if (c.kept) dirs.markKeep(path);
				age(path, now - c.idle);
			}
			for (c in cases) {
				final path: String = '${dir.path}/${c.name}';
				Assert.equals(c.orphan, dirs.isOrphan(path, now), c.name);
			}
			Assert.equals(3, dirs.sweep(now));
			Assert.same(['apq-x.keep03', 'apq-x.live02', 'apq-x.young4', 'apq-y.legcy6'], [
				for (path in dirs.claimed()) Path.withoutDirectory(path)
			], 'the sweep takes the orphans and nothing else');
		});
	}

	public function testAClaimIsStampedWithThisProcess(): Void {
		TempDir.with(dir -> {
			final dirs: TmpLifecycle = lifecycle(dir.path);
			final claimed: String = dirs.claim('apq-x');
			Assert.isNull(dirs.refusal(claimed));
			Assert.equals('${Node.process.pid}', dirs.ownerPid(claimed));
			Assert.isFalse(dirs.isOrphan(claimed, TmpLifecycle.now() + LEGACY), 'a live owner keeps it at any age');
			Assert.isNull(dirs.discard(claimed));
			Assert.isFalse(FileSystem.exists(claimed));
			Assert.notNull(dirs.discard(dir.path), 'the root itself is refused');
		});
	}

	private static function lifecycle(root: String): TmpLifecycle {
		return new TmpLifecycle(root, ['apq-x', 'apq-y'], '.apq-owner', '.apq-keep', GRACE, LEGACY);
	}

	/** Set the mtime of `path` and of everything directly in it to `at` (seconds). */
	private static function age(path: String, at: Int): Void {
		final when: Date = Date.fromTime(at * MS_PER_SECOND);
		for (name in FileSystem.readDirectory(path)) Fs.utimesSync('$path/$name', when, when);
		Fs.utimesSync(path, when, when);
	}

}
