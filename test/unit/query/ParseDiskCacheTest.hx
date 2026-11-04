package unit.query;

import anyparse.query.CachingGrammarPlugin;
import anyparse.query.ParseDiskCache;
import anyparse.query.QueryNode;
import anyparse.query.SharedParseTier;
import anyparse.query.SpanTypeInfoProvider.SpanTypeInfo;
import anyparse.runtime.Span;
#if (sys || nodejs)
import anyparse.core.TempScratch;
import sys.FileSystem;
import sys.io.File;
#end
import unit.cli.CliFixture;

using StringTools;

/**
 * The disk level under the resolution library's parse tier (`ParseDiskCache`): a tree and a span-info bundle written by
 * one process and read by the next. What it must keep is that a read gives back exactly what a parse gave, and that
 * anything it is unsure of is a miss — a changed source, a torn file, an off switch — never a stale answer.
 */
class ParseDiskCacheTest extends Test {

	private static final SOURCE: String = 'package disk.cache;\n\nclass Holder<T> {\n\n\tvar items: Array<Int> = [];\n\n'
		+ '\tpublic function pick<U>(source: Map<String, T>, key: String): Null<U> {\n\t\tfinal made = new Map<String, Int>();\n'
		+ '\t\treturn null;\n\t}\n\n}\n';
	private static final OTHER: String = 'package disk.cache;\n\nclass Holder {\n\n\tpublic function new() {}\n\n}\n';

	/** A stored tree and bundle come back as what a parse gave: every node field, the declared-type slot, every map. */
	public function testReadGivesBackWhatTheParseGave(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.write('diskcacheround', SOURCE);
		final parsing: CachingGrammarPlugin = plugin();
		final tree: QueryNode = parsing.parseFile(SOURCE);
		final spans: SpanTypeInfo = parsing.spanTypeInfo(SOURCE);
		new ParseDiskCache('haxe').store(file, SOURCE, tree, spans);

		final read: Null<StoredProjections> = new ParseDiskCache('haxe').lookup(file, SOURCE);
		Assert.notNull(read, 'a second instance — a second process — finds the entry');
		if (read == null) return;
		Assert.isTrue(sameTree(tree, read.tree), 'the tree is node for node the parsed one');
		Assert.equals(haxe.Serializer.run(spans), haxe.Serializer.run(read.spans), 'every span-info map is the parsed one');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An entry is the text it was made from: other text at its path misses, and storing it replaces the entry. */
	public function testChangedSourceMissesAndReplacesTheEntry(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.write('diskcachechange', SOURCE);
		final cache: ParseDiskCache = stored(file, SOURCE);
		Assert.isNull(cache.lookup(file, OTHER), 'text that is not what the entry was made from misses');
		Assert.notNull(cache.lookup(file, SOURCE), 'the entry itself is still there');

		final entriesBefore: Int = entryFiles().length;
		final parsing: CachingGrammarPlugin = plugin();
		cache.store(file, OTHER, parsing.parseFile(OTHER), parsing.spanTypeInfo(OTHER));
		Assert.equals(entriesBefore, entryFiles().length, 'the new text replaced the path\'s entry instead of adding one');
		Assert.isNull(cache.lookup(file, SOURCE), 'the old text now misses');
		Assert.notNull(cache.lookup(file, OTHER), 'the new text hits');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A damaged entry — cut short, or not a cache file at all — is a miss, never an error or a partial tree. */
	public function testDamagedEntryMisses(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.write('diskcachetorn', SOURCE);
		final before: Array<String> = entryFiles();
		final cache: ParseDiskCache = stored(file, SOURCE);
		final entry: Null<String> = entryFiles().filter(path -> !before.contains(path)).pop();
		Assert.notNull(entry, 'the entry just stored is on disk');
		if (entry == null) return;
		final whole: String = File.getContent(entry);

		final first: Int = whole.indexOf('\n');
		final second: Int = whole.indexOf('\n', first + 1);
		File.saveContent(entry, whole.substr(0, first + 1 + Std.int((second - first) / 2)));
		Assert.isNull(cache.lookup(file, SOURCE), 'an entry cut inside the tree section misses');
		File.saveContent(entry, whole.substr(0, second + 1 + Std.int((whole.length - second) / 2)));
		Assert.isNull(cache.lookup(file, SOURCE), 'an entry cut inside the span-info section misses');
		File.saveContent(entry, 'not a cache file');
		Assert.isNull(cache.lookup(file, SOURCE), 'a foreign file misses');
		File.saveContent(entry, whole);
		Assert.notNull(cache.lookup(file, SOURCE), 'the whole entry hits again');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `APQ_PARSE_CACHE=0` reads nothing and writes nothing. */
	public function testSwitchedOffCacheStoresAndReadsNothing(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.write('diskcacheoff', SOURCE);
		final on: ParseDiskCache = stored(file, SOURCE);
		Sys.putEnv('APQ_PARSE_CACHE', '0');
		final off: ParseDiskCache = new ParseDiskCache('haxe');
		final writtenFile: String = CliFixture.write('diskcacheoffwritten', SOURCE);
		final parsing: CachingGrammarPlugin = plugin();
		off.store(writtenFile, SOURCE, parsing.parseFile(SOURCE), parsing.spanTypeInfo(SOURCE));
		final readOff: Null<StoredProjections> = off.lookup(file, SOURCE);
		Sys.putEnv('APQ_PARSE_CACHE', '1');

		Assert.isNull(readOff, 'a switched-off cache misses an entry that is there');
		Assert.notNull(on.lookup(file, SOURCE), 'the entry is still there');
		Assert.isNull(new ParseDiskCache('haxe').lookup(writtenFile, SOURCE), 'a switched-off cache stored nothing');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The tier reads the disk level before it parses: a second tier — a stand-in for the next process, whose memory holds
	 * nothing — takes the entry the first one stored, and the library parse count does not move for it.
	 */
	public function testTierFillsFromTheDiskLevelInsteadOfParsing(): Void {
		#if (sys || nodejs)
		final file: String = CliFixture.write('diskcachetier', SOURCE);
		final disk: ParseDiskCache = new ParseDiskCache('haxe');
		final parsing: CachingGrammarPlugin = plugin();

		final first: SharedParseTier = new SharedParseTier('disk-cache-tier-first', disk);
		final parsesBefore: Int = SharedParseTier.libraryParses;
		first.promote(new LibrarySources([{ file: file, source: SOURCE }]), parsing);
		Assert.equals(1, SharedParseTier.libraryParses - parsesBefore, 'the first tier parsed the library source');

		final second: SharedParseTier = new SharedParseTier('disk-cache-tier-second', disk);
		final parsesAfterFirst: Int = SharedParseTier.libraryParses;
		final hitsBefore: Int = SharedParseTier.diskHits;
		second.promote(new LibrarySources([{ file: file, source: SOURCE }]), parsing);
		Assert.equals(1, SharedParseTier.diskHits - hitsBefore, 'the second tier took the stored projections');
		Assert.equals(parsesAfterFirst, SharedParseTier.libraryParses, 'and parsed nothing into the library');
		final served: Null<QueryNode> = second.servedParse(SOURCE);
		Assert.notNull(served, 'the second tier serves the source');
		if (served != null) Assert.isTrue(sameTree(parsing.parseFile(SOURCE), served), 'with the tree a parse gives');
		Assert.notNull(second.servedSpanInfo(SOURCE), 'and its span info');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Making this engine's directory sweeps the directories of other engines the cache left behind: one whose `.used` marker is
	 * past the idle limit goes with its entries, one with a fresh marker stays, and one with no marker is not judged.
	 */
	public function testNewEngineDirectorySweepsOnlyIdleOnes(): Void {
		#if nodejs
		withPrivateTemp(root -> {
			final idle: String = '$root/apq-parse-cache-idle';
			final fresh: String = '$root/apq-parse-cache-fresh';
			final bare: String = '$root/apq-parse-cache-bare';
			for (directory in [idle, fresh, bare]) FileSystem.createDirectory(directory);
			File.saveContent('$idle/entry', 'left behind');
			File.saveContent('$idle/.used', '');
			File.saveContent('$fresh/.used', '');
			final longAgo: Date = Date.fromTime(Date.now().getTime() - 2 * 3600 * 1000);
			js.node.Fs.utimesSync('$idle/.used', longAgo, longAgo);

			final file: String = CliFixture.write('diskcachesweep', SOURCE);
			new ParseDiskCache('haxe').lookup(file, SOURCE);

			Assert.isFalse(FileSystem.exists(idle), 'a directory idle past the limit is removed with its entries');
			Assert.isTrue(FileSystem.exists(fresh), 'a directory used a moment ago stays');
			Assert.isTrue(FileSystem.exists(bare), 'a directory with no marker is not judged');
			final kept: Array<String> = FileSystem.readDirectory(root).filter(name -> name.startsWith('apq-parse-cache-'));
			Assert.equals(3, kept.length, 'the two survivors and this engine\'s new directory');
		});
		#else
		Assert.pass('mtime cannot be set outside node');
		#end
	}

	/** A directory that cannot be made — its name taken by a plain file — leaves the cache a silent miss, never an error. */
	public function testUnwritableEngineDirectoryIsAMissNotAnError(): Void {
		#if (sys || nodejs)
		withPrivateTemp(root -> {
			final file: String = CliFixture.write('diskcacheblocked', SOURCE);
			Assert.notNull(stored(file, SOURCE).lookup(file, SOURCE), 'the cache works while its directory can be made');
			final names: Array<String> = [
				for (name in FileSystem.readDirectory(root)) if (name.startsWith('apq-parse-cache-')) name
			];
			Assert.equals(1, names.length, 'the engine directory was made under the private root');
			final taken: String = '$root/${names[0]}';
			CliFixture.removeDir(taken);
			File.saveContent(taken, 'a plain file holds the name');

			final blocked: ParseDiskCache = new ParseDiskCache('haxe');
			Assert.isNull(blocked.lookup(file, SOURCE), 'a lookup in a directory that cannot be made misses');
			final parsing: CachingGrammarPlugin = plugin();
			blocked.store(file, SOURCE, parsing.parseFile(SOURCE), parsing.spanTypeInfo(SOURCE));
			Assert.isNull(blocked.lookup(file, SOURCE), 'a store there is silent and keeps nothing');
			Assert.equals('a plain file holds the name', File.getContent(taken), 'the occupant is left as it was');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function plugin(): CachingGrammarPlugin {
		return new CachingGrammarPlugin(new HaxeQueryPlugin());
	}

	/** Whether two trees are the same tree: kind, name, span, type arguments, the declared type and every child, recursively. */
	private static function sameTree(a: QueryNode, b: QueryNode): Bool {
		final spanA: Null<Span> = a.span;
		final spanB: Null<Span> = b.span;
		if (a.kind != b.kind || a.name != b.name || a.typeArgCount != b.typeArgCount || a.children.length != b.children.length)
			return false;
		if ((spanA == null) != (spanB == null) || (spanA != null && spanB != null && (spanA.from != spanB.from || spanA.to != spanB.to)))
			return false;
		final typeA: Null<QueryNode> = a.type;
		final typeB: Null<QueryNode> = b.type;
		if ((typeA == null) != (typeB == null) || (typeA != null && typeB != null && !sameTree(typeA, typeB))) return false;
		for (i in 0...a.children.length) if (!sameTree(a.children[i], b.children[i])) return false;
		return true;
	}

	private static function stored(file: String, source: String): ParseDiskCache {
		final cache: ParseDiskCache = new ParseDiskCache('haxe');
		final parsing: CachingGrammarPlugin = plugin();
		cache.store(file, source, parsing.parseFile(source), parsing.spanTypeInfo(source));
		return cache;
	}

	/** The entry files of every engine directory under the scratch root. */
	private static function entryFiles(): Array<String> {
		final entries: Array<String> = [];
		#if (sys || nodejs)
		final root: String = TempScratch.root();
		final names: Array<String> = FileSystem.readDirectory(root);
		for (name in names) {
			final directory: String = '$root/$name';
			if (!name.startsWith('apq-parse-cache-') || !FileSystem.isDirectory(directory)) continue;
			final inside: Array<String> = FileSystem.readDirectory(directory);
			for (entry in inside) if (!entry.startsWith('.')) entries.push('$directory/$entry');
		}
		#end
		return entries;
	}

	/** Runs `body` with `TMPDIR` pointing at a fresh private directory, then puts `TMPDIR` back and removes the directory. */
	private static function withPrivateTemp(body: (root:String) -> Void): Void {
		#if (sys || nodejs)
		final before: Null<String> = Sys.getEnv('TMPDIR');
		final root: String = CliFixture.writeDir('diskcacheprivate', []);
		Sys.putEnv('TMPDIR', root);
		CliFixture.always(() -> {
			Sys.putEnv('TMPDIR', before ?? '');
			CliFixture.removeDir(root);
		}, () -> body(root));
		#end
	}

}
