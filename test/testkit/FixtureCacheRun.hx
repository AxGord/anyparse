package testkit;

import anyparse.proc.ProcessSpawn;
import dev.Shard;
import devkit.FixtureCache;
import devkit.TempDir;
import sys.FileSystem;

/**
 * The one answer to "how does a run that no runner wired get the fixture compile cache": `engage` puts the shim and the
 * in-process answer module `devkit.FixtureCache` writes ahead of the probe compiles of THIS process, the way `dev shard`
 * and `dev mutation-check` do for theirs, over the same content-keyed store; `release` takes them away again.
 *
 * A process a runner already wired (`ProcessSpawn.ANSWER_ENV` set) or one that opted out (`APQ_SUITE_NO_FIXTURE_CACHE`) is
 * left alone, and so is one that cannot build the replay program: the compiles then run for real, as they always did.
 */
@:nullSafety(Strict)
final class FixtureCacheRun {

	private static var scratch: Null<TempDir>;
	private static var tally: Null<String>;
	private static var path: Null<String>;

	/** Whether this call wired the cache; false when it was wired already, opted out or unavailable. */
	public static function engage(): Bool {
		if (scratch != null || (Sys.getEnv(ProcessSpawn.ANSWER_ENV) ?? '') != '') return false;
		final store: Null<String> = Shard.fixtureCacheOfEnv();
		final repo: String = Sys.getCwd();
		if (store == null || !FileSystem.exists('$repo/tools/fixture-cache-common.hxml')) return false;
		FixtureCache.prune(store, FixtureCache.maxAgeDays());
		final dir: TempDir = TempDir.create();
		final shimmed: Null<String> = try
			FixtureCache.shim(repo, store, dir.path, dir.file('tally'))
		catch (exception: haxe.Exception)
			'unavailable';
		if (shimmed != null) {
			dir.dispose();
			return false;
		}
		scratch = dir;
		tally = dir.file('tally');
		path = Sys.getEnv('PATH');
		Sys.putEnv('PATH', '${dir.path}:${path ?? ''}');
		Sys.putEnv(ProcessSpawn.ANSWER_ENV, FixtureCache.answer(dir.path));
		return true;
	}

	/** Takes the wiring `engage` made away; answers what the compiles did (`3 hit, 1 miss`), or null when none was made. */
	public static function release(): Null<String> {
		final dir: Null<TempDir> = scratch;
		if (dir == null) return null;
		final counts: Null<String> = FixtureCache.tally(tally ?? '');
		Sys.putEnv('PATH', path);
		Sys.putEnv(ProcessSpawn.ANSWER_ENV, null);
		dir.dispose();
		scratch = null;
		tally = null;
		path = null;
		return counts ?? '';
	}

}
