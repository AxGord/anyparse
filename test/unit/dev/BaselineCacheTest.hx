package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonFormat;
import dev.Baseline;
import dev.BaselineCache;
import dev.BaselineLists;
import dev.BaselineParser;
import dev.BaselineWriter;
import dev.FrozenTree;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/** `dev.BaselineCache`: which `--baseline` run may reuse a kept baseline, and that a reused one carries nothing tree-bound. */
@:nullSafety(Strict)
final class BaselineCacheTest extends Test {

	/** Every part of what a baseline measures moves the key, and an unset corpus differs from a set one. */
	@:pin('guard')
	public function testTheKeyFollowsEveryReadingItsBaselineDependsOn(): Void {
		final key: String = BaselineCache.key('abc', 'fork s1', ['t1 s1'], 'haxe 4');
		Assert.equals(key, BaselineCache.key('abc\n', 'fork s1', ['t1 s1'], 'haxe 4'));
		Assert.notEquals(key, BaselineCache.key('abd', 'fork s1', ['t1 s1'], 'haxe 4'));
		Assert.notEquals(key, BaselineCache.key('abc', 'fork s2', ['t1 s1'], 'haxe 4'));
		Assert.notEquals(key, BaselineCache.key('abc', '', ['t1 s1'], 'haxe 4'));
		Assert.notEquals(key, BaselineCache.key('abc', 'fork s1', ['t1 s2'], 'haxe 4'));
		Assert.notEquals(key, BaselineCache.key('abc', 'fork s1', [], 'haxe 4'));
		Assert.notEquals(key, BaselineCache.key('abc', 'fork s1', ['t1 s1'], 'haxe 5'));
	}

	/** A tree already edited, or a row waived by `--allow`, neither takes nor leaves an entry; the corpus tree's content moves the key. */
	@:pin('guard')
	public function testARunThatIsNotTheCommitsOwnMeasurementHasNoKey(): Void {
		TempDir.with(dir -> {
			final fork: String = dir.file('fork');
			FileSystem.createDirectory(fork);
			File.saveContent(Path.join([fork, 'a.txt']), 'one');
			final key: Null<String> = BaselineCache.keyOfRun('abc', fork, [], [], true, 'haxe 4');
			Assert.notNull(key);
			Assert.isNull(BaselineCache.keyOfRun('abc', fork, [], [], false, 'haxe 4'));
			Assert.isNull(BaselineCache.keyOfRun('abc', fork, [], ['corpus'], true, 'haxe 4'));
			Assert.equals(key, BaselineCache.keyOfRun('abc', fork, [], [], true, 'haxe 4'));
			File.saveContent(Path.join([fork, 'a.txt']), 'twice');
			Assert.notEquals(key, BaselineCache.keyOfRun('abc', fork, [], [], true, 'haxe 4'));
		});
	}

	/** A stored baseline is restored whole into another logs directory, pointing at the copies, with the frozen digests of the new run. */
	@:pin('guard')
	public function testAKeptBaselineIsRestoredIntoAnotherRunsLogs(): Void {
		TempDir.with(dir -> {
			final cache: String = dir.file('cache');
			BaselineCache.store(cache, 'k1', recorded(dir.file('logs-a'), 'abc'));
			final frozen: Array<FrozenTree> = [{ dir: '/frozen/a', digest: 'new' }];
			final logs: String = dir.file('logs-b');
			FileSystem.createDirectory(logs);
			final got: Null<Baseline> = BaselineCache.restore(cache, 'k1', logs, frozen);
			Assert.notNull(got);
			if (got == null) return;
			Assert.equals('abc', got.base);
			Assert.equals(7, got.tests);
			Assert.equals(9, got.assertions);
			Assert.equals(3, BaselineLists.count(got.lists, 'classes'));
			Assert.same(frozen, got.frozen);
			Assert.equals(Path.join([logs, 'sweep-base.json']), got.sweep);
			Assert.equals('sweep', File.getContent(got.sweep ?? ''));
			Assert.equals('lint', File.getContent(got.lint));
			Assert.equals('/some/tree', got.infra[0].tree);
			Assert.equals(Path.join([logs, 'infra-0.json']), got.infra[0].snapshot);
			Assert.equals('infra', File.getContent(got.infra[0].snapshot));
		});
	}

	/** An unknown key, an entry without its record and one with a file missing are no hit. */
	@:pin('guard')
	public function testAnEntryThatIsNotWholeIsNotUsed(): Void {
		TempDir.with(dir -> {
			final cache: String = dir.file('cache');
			final logs: String = dir.file('logs');
			FileSystem.createDirectory(logs);
			Assert.isNull(BaselineCache.restore(cache, 'none', logs, []));
			FileSystem.createDirectory(Path.join([cache, 'half']));
			Assert.isNull(BaselineCache.restore(cache, 'half', logs, []));
			BaselineCache.store(cache, 'k2', recorded(dir.file('logs-a'), 'abc'));
			FileSystem.deleteFile(Path.join([cache, 'k2', 'infra-0.json']));
			Assert.isNull(BaselineCache.restore(cache, 'k2', logs, []));
		});
	}

	/** Storing drops the entries no run used for longer than the age limit, and keeps a fresh one. */
	@:pin('guard')
	public function testStoringPrunesEntriesNoRunUsed(): Void {
		TempDir.with(dir -> {
			final cache: String = dir.file('cache');
			BaselineCache.store(cache, 'old', recorded(dir.file('logs-a'), 'abc'));
			BaselineCache.store(cache, 'fresh', recorded(dir.file('logs-b'), 'abd'));
			final aged: Date = Date.fromTime(Date.now().getTime() - 30.0 * 86400000.0);
			js.node.Fs.Fs.utimesSync(Path.join([cache, 'old']), aged, aged);
			BaselineCache.store(cache, 'next', recorded(dir.file('logs-c'), 'abe'));
			final names: Array<String> = FileSystem.readDirectory(cache);
			names.sort(Reflect.compare);
			Assert.same(['fresh', 'next'], names);
		});
	}

	/** A restored record survives the JSON round trip the gate writes it through, its sweep null when no corpus was set. */
	@:pin('guard')
	public function testARestoredRecordSurvivesTheBaselineFileRoundTrip(): Void {
		TempDir.with(dir -> {
			final cache: String = dir.file('cache');
			final record: Baseline = recorded(dir.file('logs-a'), 'abc');
			record.sweep = null;
			BaselineCache.store(cache, 'k4', record);
			final logs: String = dir.file('logs-b');
			FileSystem.createDirectory(logs);
			final got: Null<Baseline> = BaselineCache.restore(cache, 'k4', logs, [{ dir: '/frozen/a', digest: 'new' }]);
			Assert.notNull(got);
			if (got == null) return;
			final again: Baseline = BaselineParser.parse(BaselineWriter.write(got, JsonFormat.instance.defaultWriteOptions));
			Assert.isNull(again.sweep);
			Assert.isFalse(FileSystem.exists(Path.join([logs, 'sweep-base.json'])));
			Assert.same(got, again);
		});
	}

	/** An entry already kept is not overwritten, and storing leaves no staging directory behind. */
	@:pin('guard')
	public function testTheFirstEntryOfAKeyStays(): Void {
		TempDir.with(dir -> {
			final cache: String = dir.file('cache');
			BaselineCache.store(cache, 'k3', recorded(dir.file('logs-a'), 'first'));
			BaselineCache.store(cache, 'k3', recorded(dir.file('logs-b'), 'second'));
			final kept: Baseline = BaselineParser.parse(File.getContent(Path.join([cache, 'k3', 'baseline.json'])));
			Assert.equals('first', kept.base);
			Assert.same(['k3'], FileSystem.readDirectory(cache));
		});
	}

	/** A baseline document an earlier engine wrote, `lists` an object of counts and `sweep` null, reads as it did. */
	public function testADocumentOfAnEarlierEngineIsRead(): Void {
		final kept: Baseline = BaselineParser.parse(
			'{"base":"b","tests":1,"assertions":2,"lists":{"classes":3},"sweep":null,"lint":"l","infra":[],"frozen":[]}'
		);
		Assert.equals(3, BaselineLists.count(kept.lists, 'classes'));
		Assert.isNull(BaselineLists.count(kept.lists, 'absent'));
		Assert.isNull(kept.sweep);
		Assert.isNull(BaselineLists.count(JArray([]), 'classes'));
	}

	/** A recorded baseline of `base` whose files live in `logs`, with one infra tree. */
	private static function recorded(logs: String, base: String): Baseline {
		FileSystem.createDirectory(logs);
		File.saveContent(Path.join([logs, 'sweep-base.json']), 'sweep');
		File.saveContent(Path.join([logs, 'lint-base.json']), 'lint');
		File.saveContent(Path.join([logs, 'infra-0.json']), 'infra');
		return {
			base: base,
			tests: 7,
			assertions: 9,
			lists: BaselineLists.of(['classes'], _ -> 3),
			sweep: Path.join([logs, 'sweep-base.json']),
			lint: Path.join([logs, 'lint-base.json']),
			infra: [{ tree: '/some/tree', snapshot: Path.join([logs, 'infra-0.json']) }],
			frozen: [{ dir: '/frozen/a', digest: 'old' }]
		};
	}

}
