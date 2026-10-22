package unit.devkit;

import devkit.FixtureCache;
import devkit.TempDir;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `FixtureCache` upkeep: the tally a run prints, and which store entries a prune takes — only the store's own kinds of
 * file, only past the age limit in WHOLE days, as `find -mtime +N` counts them. The shim itself needs a compiler and a
 * replay build, so it is proven against the shell twin by running both, not here.
 */
@:nullSafety(Strict)
final class FixtureCacheTest extends Test {

	private static inline final DAY_MS: Float = 86400000;

	public function testTheTallyCountsEachOutcomeInSortedOrder(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('tally');
			File.saveContent(file, 'miss\nhit\nhit\npass\nhit\nmiss\n');
			Assert.equals('3 hit, 2 miss, 1 pass', FixtureCache.tally(file));
			File.saveContent(file, '');
			Assert.equals('', FixtureCache.tally(file), 'an empty tally says nothing');
			Assert.isNull(FixtureCache.tally(dir.file('none')), 'and a missing one says less');
		});
	}

	public function testAPruneTakesOnlyTheStoresOwnFilesPastTheLimit(): Void {
		TempDir.with(dir -> {
			final store: String = dir.file('store');
			FileSystem.createDirectory('$store/sub');
			final now: Float = Date.now().getTime();
			// the store's kinds of file, then two it does not own
			final kinds: Array<String -> String> = [
				age -> '$age.json.gz',
				age -> 'fixture-cache-$age.js',
				age -> 'build-$age.log',
				age -> '$age.tmp',
				age -> '$age.txt',
				age -> 'other-$age.js'
			];
			for (kind in kinds) {
				aged('$store/${kind('old')}', now - 9 * DAY_MS);
				// eight days less an hour is seven WHOLE days: not past a seven-day limit
				aged('$store/${kind('edge')}', now - 8 * DAY_MS + DAY_MS / 24);
				aged('$store/${kind('new')}', now);
			}
			aged('$store/sub/old.json.gz', now - 9 * DAY_MS);
			FixtureCache.prune(store, 7);
			final left: Array<String> = FileSystem.readDirectory(store);
			left.sort(Reflect.compare);
			final expected: Array<String> = ['sub', 'old.txt', 'other-old.js'];
			for (kind in kinds) for (age in ['edge', 'new']) expected.push(kind(age));
			expected.sort(Reflect.compare);
			Assert.same(expected, left);
			Assert.isTrue(FileSystem.exists('$store/sub/old.json.gz'), 'a prune never descends');
		});
	}

	private static function aged(path: String, at: Float): Void {
		File.saveContent(path, 'x');
		final when: Date = Date.fromTime(at);
		Fs.utimesSync(path, when, when);
	}

}
