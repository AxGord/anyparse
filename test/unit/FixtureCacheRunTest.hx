package unit;

import anyparse.proc.ProcessSpawn;
import devkit.TempDir;
import sys.FileSystem;
import testkit.FixtureCacheRun;
import utest.Assert;
import utest.Test;

/**
 * `testkit.FixtureCacheRun`, the wiring a run no runner set up gets: the shim and the answer module ahead of its probe
 * compiles while engaged, the environment as it was once released, and nothing touched when the process is wired
 * already or opted out.
 */
@:nullSafety(Strict)
final class FixtureCacheRunTest extends Test {

	private static inline final STORE: String = 'APQ_SUITE_FIXTURE_CACHE';
	private static inline final OPT_OUT: String = 'APQ_SUITE_NO_FIXTURE_CACHE';

	@:pin('control')
	@:killer('M-FIXTURE-CACHE-RUN-NO-WIRING')
	public function testAnEngagedRunHasTheShimAndTheAnswerModuleUntilItIsReleased(): Void {
		TempDir.with(store -> inEnvironment([ProcessSpawn.ANSWER_ENV => null, OPT_OUT => null, STORE => store.path], () -> {
			final path: String = Sys.getEnv('PATH') ?? '';
			Assert.isTrue(FixtureCacheRun.engage());
			final shimDir: String = (Sys.getEnv('PATH') ?? '').split(':')[0];
			Assert.isTrue(FileSystem.exists('$shimDir/haxe'), 'the shim leads the PATH');
			Assert.isTrue(FileSystem.exists(Sys.getEnv(ProcessSpawn.ANSWER_ENV) ?? ''), 'the answer module is named');
			Assert.isFalse(FixtureCacheRun.engage(), 'an engaged run is not engaged twice');
			Assert.notNull(FixtureCacheRun.release());
			Assert.equals(path, Sys.getEnv('PATH') ?? '');
			Assert.isNull(Sys.getEnv(ProcessSpawn.ANSWER_ENV));
			Assert.isFalse(FileSystem.exists(shimDir), 'the shim directory is gone');
			Assert.isNull(FixtureCacheRun.release(), 'a release of nothing says nothing');
		}));
	}

	public function testARunWiredAlreadyIsLeftAlone(): Void {
		inEnvironment([ProcessSpawn.ANSWER_ENV => '/wired/answer.js', OPT_OUT => null], () -> {
			final path: String = Sys.getEnv('PATH') ?? '';
			Assert.isFalse(FixtureCacheRun.engage());
			Assert.equals(path, Sys.getEnv('PATH') ?? '');
			Assert.equals('/wired/answer.js', Sys.getEnv(ProcessSpawn.ANSWER_ENV));
		});
	}

	public function testARunThatOptedOutIsLeftAlone(): Void {
		inEnvironment([ProcessSpawn.ANSWER_ENV => null, OPT_OUT => '1'], () -> {
			Assert.isFalse(FixtureCacheRun.engage());
			Assert.isNull(Sys.getEnv(ProcessSpawn.ANSWER_ENV));
		});
	}

	/** `body` with each variable of `set` put (null: taken away), and every one back as it was after. */
	private static function inEnvironment(set: Map<String, Null<String>>, body: () -> Void): Void {
		final before: Map<String, Null<String>> = [ for (name in set.keys()) name => Sys.getEnv(name) ];
		for (name => value in set) Sys.putEnv(name, value);
		try {
			body();
		} catch (exception: haxe.Exception) {
			restore(before);
			throw exception;
		}
		restore(before);
	}

	private static function restore(before: Map<String, Null<String>>): Void {
		Assert.isNull(FixtureCacheRun.release(), 'the body released what it engaged');
		for (name => value in before) Sys.putEnv(name, value);
	}

}
