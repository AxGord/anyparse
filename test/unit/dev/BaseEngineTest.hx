package unit.dev;

import dev.BaseEngine;
import devkit.TempDir;
import haxe.Exception;
import haxe.io.Path;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev.BaseEngine`: a cached engine is reused only while its checksum and its compiler stamp hold, a failed build leaves no
 * entry, and the prune takes only entries unused past the age limit.
 */
@:nullSafety(Strict)
final class BaseEngineTest extends Test {

	private static inline final MS_PER_DAY: Float = 86400000;

	/** Days past the age limit an aged entry is given. */
	private static inline final STALE_DAYS: Int = 10;

	@:pin('control')
	@:killer('M-BASE-ENGINE-CHECKSUM-BLIND')
	public function testAKeptEngineIsReusedUntilItsChecksumOrCompilerMoves(): Void {
		TempDir.with(dir -> {
			final cache: String = dir.file('cache');
			var builds: Int = 0;
			final build: String -> Void = out -> {
				builds++;
				File.saveContent(Path.join([out, BaseEngine.ENGINE]), 'engine $builds');
			};
			final engine: String = BaseEngine.ensure(cache, 'abc', 'haxe 1', build);
			Assert.equals(Path.join([cache, 'abc', BaseEngine.ENGINE]), engine);
			Assert.equals('engine 1', File.getContent(engine));
			Assert.equals(engine, BaseEngine.ensure(cache, 'abc', 'haxe 1', build));
			Assert.equals(1, builds, 'a valid entry is reused');
			File.saveContent(engine, 'tampered');
			Assert.equals(engine, BaseEngine.ensure(cache, 'abc', 'haxe 1', build));
			Assert.equals(2, builds, 'an engine that no longer matches its checksum is rebuilt');
			Assert.equals('engine 2', File.getContent(engine));
			Assert.equals(engine, BaseEngine.ensure(cache, 'abc', 'haxe 2', build));
			Assert.equals(3, builds, 'an engine another compiler built is rebuilt');
			Assert.same(['abc'], FileSystem.readDirectory(cache), 'no staging directory is left behind');
		});
	}

	public function testAFailedBuildLeavesNoEntry(): Void {
		TempDir.with(dir -> {
			final cache: String = dir.file('cache');
			Assert.raises(
				() -> BaseEngine.ensure(cache, 'abc', 'haxe 1', out -> {
					File.saveContent(Path.join([out, BaseEngine.ENGINE]), 'half');
					throw new Exception('does not build');
				}),
				Exception
			);
			Assert.same([], FileSystem.readDirectory(cache));
		});
	}

	public function testThePruneTakesOnlyEntriesUnusedPastTheLimit(): Void {
		TempDir.with(dir -> {
			final cache: String = dir.file('cache');
			for (name in ['fresh', 'stale']) FileSystem.createDirectory(Path.join([cache, name]));
			final then: Date = Date.fromTime(Date.now().getTime() - STALE_DAYS * MS_PER_DAY);
			Fs.utimesSync(Path.join([cache, 'stale']), then, then);
			BaseEngine.prune(cache, BaseEngine.MAX_AGE_DAYS);
			Assert.same(['fresh'], FileSystem.readDirectory(cache));
		});
	}

}
