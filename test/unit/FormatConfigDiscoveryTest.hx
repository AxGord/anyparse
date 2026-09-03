package unit;

import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
import anyparse.query.FormatConfigDiscovery;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `FormatConfigDiscovery.discover` walks UP from a file's own directory to the
 * nearest `hxformat.json` and memoises the answer per DIRECTORY — including the
 * negative one, so a directory with no ancestor config is not re-walked.
 *
 * Both memos are pinned the same way: resolve once, then change what is on DISK and
 * resolve again. The process-scoped cache is content-blind by design, so the second
 * answer must be the FIRST one — that is the whole observable difference between a
 * memo and a re-walk. Every fixture builds its own uniquely named directory, since
 * the cache outlives the test.
 */
class FormatConfigDiscoveryTest extends Test {

	/** Every directory `makeTree` built, removed in `teardown` so a suite run leaves none behind. */
	private final _made: Array<String> = [];

	public function testFindsNearestAncestorConfig(): Void {
		final dir: String = makeTree('nearest');
		File.saveContent(Path.join([dir, 'hxformat.json']), '{"wrapping": {"maxLineLength": 111}}');
		Assert.equals('{"wrapping": {"maxLineLength": 111}}', FormatConfigDiscovery.discover(Path.join([dir, 'A.hx'])));
	}

	public function testWalksUpPastDirectoriesWithoutOne(): Void {
		final dir: String = makeTree('walkup');
		File.saveContent(Path.join([dir, 'hxformat.json']), '{"wrapping": {"maxLineLength": 122}}');
		final nested: String = Path.join([dir, 'a', 'b']);
		FileSystem.createDirectory(nested);
		Assert.equals('{"wrapping": {"maxLineLength": 122}}', FormatConfigDiscovery.discover(Path.join([nested, 'A.hx'])));
	}

	/** A second file in the SAME directory is answered from the memo — the config it names is gone by then. */
	public function testMemoisedByDirectory(): Void {
		final dir: String = makeTree('memo');
		final config: String = Path.join([dir, 'hxformat.json']);
		File.saveContent(config, '{"wrapping": {"maxLineLength": 133}}');
		Assert.equals('{"wrapping": {"maxLineLength": 133}}', FormatConfigDiscovery.discover(Path.join([dir, 'A.hx'])));
		FileSystem.deleteFile(config);
		Assert.equals('{"wrapping": {"maxLineLength": 133}}', FormatConfigDiscovery.discover(Path.join([dir, 'B.hx'])));
	}

	/**
	 * A BLANK `hxformat.json` — 0 bytes, or whitespace only — states no settings, so it
	 * resolves as NO config. Folding it HERE is what makes every hop downstream read it
	 * the same way; while only `layoutMetrics` folded it, a rule measured through that
	 * hop and wrote through `writeRoundTrip`, which raised `unexpected input` on it.
	 */
	public function testBlankConfigResolvesToNoConfig(): Void {
		final dir: String = makeTree('blank');
		File.saveContent(Path.join([dir, 'hxformat.json']), '  \n\t\n');
		Assert.isNull(FormatConfigDiscovery.discover(Path.join([dir, 'A.hx'])));
	}

	/** The NEGATIVE answer is memoised too: a config written after the first miss is not picked up. */
	public function testNegativeAnswerMemoised(): Void {
		final dir: String = makeTree('negative');
		final stray: Null<String> = ancestorConfig(dir);
		if (stray != null) Assert.fail('an hxformat.json above the system temp directory ($stray) invalidates this fixture');
		Assert.isNull(FormatConfigDiscovery.discover(Path.join([dir, 'A.hx'])));
		File.saveContent(Path.join([dir, 'hxformat.json']), '{"wrapping": {"maxLineLength": 144}}');
		Assert.isNull(FormatConfigDiscovery.discover(Path.join([dir, 'B.hx'])));
	}

	/**
	 * The unusable-settings report names the CONFIG's own path, not the source file that
	 * happened to resolve it.
	 *
	 * `discover` is the one place that holds both the config's text and the path it was read
	 * from, which is what lets the diagnostic point an author at the file to edit. Since the
	 * walk moved to `ConfigFinder.findUpFile` that path arrives as `found.path` rather than as
	 * the loop's own `candidate`, so the choice is now a hop that can be got wrong silently:
	 * `filePath` is in scope, is a String, and would report a config error against every `.hx`
	 * under the config instead of once against the config. Killer for exactly that arm.
	 */
	@:access(anyparse.grammar.haxe.HaxeFormatConfigDiagnostics)
	public function testTheUnusableSettingsReportNamesTheConfigNotTheFileItGoverns(): Void {
		final dir: String = makeTree('reportpath');
		File.saveContent(Path.join([dir, 'hxformat.json']), '{"noSuchKnobAtAll": 1}');
		final nested: String = Path.join([dir, 'a']);
		FileSystem.createDirectory(nested);
		Assert.notNull(FormatConfigDiscovery.discover(Path.join([nested, 'A.hx'])));
		final named: Array<String> = HaxeFormatConfigDiagnostics.reported.filter(p -> p.indexOf('apq-fcd-reportpath') >= 0);
		Assert.equals(1, named.length, 'expected exactly one reported path under the fixture, got ${named.join(', ')}');
		Assert.equals('hxformat.json', Path.withoutDirectory(named[0]), 'the report named ${named[0]} instead of the config it read');
	}

	/** Remove every directory the finished fixture built — the cache outlives the test, the files need not. */
	public function teardown(): Void {
		for (dir in _made) removeTree(dir);
		_made.resize(0);
	}

	/** A fresh, uniquely named directory under the system temp — no ancestor of it holds an `hxformat.json`. */
	private function makeTree(name: String): String {
		final dir: String = Path.join([tempRoot(), 'apq-fcd-$name-${Std.random(0x7FFFFFFF)}']);
		FileSystem.createDirectory(dir);
		_made.push(dir);
		return dir;
	}

	/** The directory the fixtures build under, created on first use. */
	private function tempRoot(): String {
		final root: String = Path.join([Sys.getEnv('TMPDIR') ?? '/tmp', 'apq-format-config-discovery-test']);
		if (!FileSystem.exists(root)) FileSystem.createDirectory(root);
		return root;
	}

	/** `dir` and everything under it, deleted. */
	private static function removeTree(dir: String): Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(path))
				removeTree(path);
			else
				FileSystem.deleteFile(path);
		}
		FileSystem.deleteDirectory(dir);
	}

	/**
	 * The nearest `hxformat.json` at or above `dir`, or null — `testNegativeAnswerMemoised`'s
	 * own precondition, CHECKED rather than left in prose: a stray config anywhere above
	 * the system temp directory would fail that fixture with nothing naming the cause.
	 */
	private static function ancestorConfig(dir: String): Null<String> {
		var cur: String = dir;
		while (cur != '') {
			final candidate: String = Path.join([cur, 'hxformat.json']);
			if (FileSystem.exists(candidate)) return candidate;
			final parent: String = Path.directory(cur);
			if (parent == cur) return null;
			cur = parent;
		}
		return null;
	}

}
