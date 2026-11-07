package anyparse.query;

import anyparse.core.ContentHash;
import anyparse.core.ParseProjectionEngine;
import anyparse.core.TempScratch;
import anyparse.grammar.json.JsonFormat;
import anyparse.query.SpanTypeInfoProvider.SpanTypeInfo;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.io.Path;

/** What `ParseDiskCache` keeps of one source: the two projections a resolution-library parse yields. */
typedef StoredProjections = {
	final tree: QueryNode;
	final spans: SpanTypeInfo;
};

/**
 * The one answer to "is the parse of this source already on disk": a content-addressed, engine-keyed store of the
 * `QueryNode` tree and `SpanTypeInfo` bundle a resolution-library source parses to, so a new process reads them instead
 * of parsing the library again (`SharedParseTier.promote`).
 *
 * A file is what its source hashes to under the engine that wrote it. The directory is named by
 * `ParseProjectionEngine.digest`, so another engine never reads it; an entry is named by its path and holds the hash of
 * the text it was made from, so a changed file misses and replaces its own entry instead of leaving a stale one behind.
 * Every doubt is a miss — a missing, torn or foreign file, a hash that differs, a store that cannot write — so the
 * cache changes what a parse COSTS, never what it answers. State lives on disk, written atomically; the process holds
 * none beyond the directory it resolved (`docs/design-principles.md` § 2). `APQ_PARSE_CACHE=0` turns it off.
 */
@:nullSafety(Strict)
final class ParseDiskCache {

	/** The scheme tag opening every entry: bump it and every stored entry misses. */
	private static inline final FORMAT_TAG: String = 'apq-parse-cache v1';

	private static inline final DIR_PREFIX: String = 'apq-parse-cache-';

	/** The file whose modification time says when an engine's directory was last used. */
	private static inline final MARKER: String = '.used';

	/** How long an engine's directory may sit unused before the next new one sweeps it away. */
	private static inline final IDLE_SECONDS: Float = 3600;

	private static inline final SWITCH_VARIABLE: String = 'APQ_PARSE_CACHE';
	private static inline final MILLISECONDS: Float = 1000;

	// One node is NODE_WIDTH integers, at these offsets from where it starts.
	private static inline final KIND: Int = 0;
	private static inline final NAME: Int = 1;
	private static inline final SPAN_FROM: Int = 2;
	private static inline final SPAN_TO: Int = 3;
	private static inline final TYPE_ARGS: Int = 4;
	private static inline final CHILD_COUNT: Int = 5;
	private static inline final HAS_TYPE: Int = 6;
	private static inline final NODE_WIDTH: Int = 7;
	private static final ENGINE: String = ParseProjectionEngine.digest();

	private final _lang: String;

	private var _directory: Null<String> = null;
	private var _resolved: Bool = false;

	public function new(lang: String) {
		_lang = lang;
	}

	/** The projections stored for `file` when `source` is the text they were made from, else null. */
	public function lookup(file: String, source: String): Null<StoredProjections> {
		#if (sys || nodejs)
		final directory: Null<String> = directoryOrNull();
		if (directory == null) return null;
		try {
			final text: String = sys.io.File.getContent(entryPath(directory, file));
			final first: Int = text.indexOf('\n');
			final second: Int = text.indexOf('\n', first + 1);
			if (first < 0 || second < 0 || text.substr(0, first) != header(source)) return null;
			final spans: SpanTypeInfo = haxe.Unserializer.run(text.substr(second + 1));
			return { tree: decodeTree(text.substring(first + 1, second)), spans: spans };
		} catch (_: Exception) {
			return null;
		}
		#else
		return null;
		#end
	}

	/** Keep `tree` and `spans` as the projections of `source` at `file`, replacing what the entry held; a failure is silent. */
	public function store(file: String, source: String, tree: QueryNode, spans: SpanTypeInfo): Void {
		#if (sys || nodejs)
		final directory: Null<String> = directoryOrNull();
		if (directory == null) return;
		final path: String = entryPath(directory, file);
		// Staged under this process's name and renamed over the entry, so a concurrent reader sees the old entry or the new one whole.
		final temporary: String = TempScratch.slot(entryName(file), '.staged');
		try {
			sys.io.File.saveContent(temporary, '${header(source)}\n${encodeTree(tree)}\n${haxe.Serializer.run(spans)}');
			sys.FileSystem.rename(temporary, path);
		} catch (_: Exception) {
			// A cache that cannot write costs the next run a parse and nothing else.
		}
		#end
	}

	private function entryName(file: String): String {
		return ContentHash.md5('$_lang|$file');
	}

	private static function encodeTree(tree: QueryNode): String {
		final stored: StoredTree = { strings: [], ints: [] };
		final interned: Map<String, Int> = [];
		writeNode(tree, stored, interned);
		return StoredTreeWriter.write(stored, JsonFormat.instance.compactWriteOptions);
	}

	private static function writeNode(node: QueryNode, into: StoredTree, interned: Map<String, Int>): Void {
		final span: Null<Span> = node.span;
		final type: Null<QueryNode> = node.type;
		// The order is the `KIND` .. `HAS_TYPE` offsets `readNode` reads back.
		into.ints.push(intern(node.kind, into.strings, interned));
		into.ints.push(node.name == null ? -1 : intern(node.name, into.strings, interned));
		into.ints.push(span == null ? -1 : span.from);
		into.ints.push(span == null ? -1 : span.to);
		into.ints.push(node.typeArgCount);
		into.ints.push(node.children.length);
		into.ints.push(type == null ? 0 : 1);
		for (child in node.children) writeNode(child, into, interned);
		if (type != null) writeNode(type, into, interned);
	}

	private static function intern(text: String, strings: Array<String>, interned: Map<String, Int>): Int {
		final known: Null<Int> = interned[text];
		if (known != null) return known;
		strings.push(text);
		interned[text] = strings.length - 1;
		return strings.length - 1;
	}

	/** The tree `encodeTree` wrote; throws on a text that is not exactly one tree. */
	private static function decodeTree(text: String): QueryNode {
		final stored: StoredTree = StoredTreeParser.parse(text);
		final cursor: Array<Int> = [0];
		final tree: QueryNode = readNode(stored, cursor);
		if (cursor[0] != stored.ints.length) throw new Exception('trailing data in a stored tree');
		return tree;
	}

	private static function readNode(from: StoredTree, cursor: Array<Int>): QueryNode {
		final ints: Array<Int> = from.ints;
		final at: Int = cursor[0];
		cursor[0] = at + NODE_WIDTH;
		final nameIndex: Int = ints[at + NAME];
		final spanFrom: Int = ints[at + SPAN_FROM];
		final children: Array<QueryNode> = [for (_ in 0...ints[at + CHILD_COUNT]) readNode(from, cursor)];
		final type: Null<QueryNode> = ints[at + HAS_TYPE] == 1 ? readNode(from, cursor) : null;
		return new QueryNode(
			from.strings[ints[at + KIND]], nameIndex < 0 ? null : from.strings[nameIndex], children,
			spanFrom < 0 ? null : new Span(spanFrom, ints[at + SPAN_TO]), type, ints[at + TYPE_ARGS]
		);
	}

	#if (sys || nodejs)
	/** This engine's directory, created and marked used on first ask; null when the cache is off or the directory cannot be made. */
	private function directoryOrNull(): Null<String> {
		if (_resolved) return _directory;
		_resolved = true;
		if (Sys.getEnv(SWITCH_VARIABLE) == '0') return null;
		final root: String = TempScratch.root();
		final directory: String = Path.join([root, DIR_PREFIX + ENGINE]);
		try {
			if (!sys.FileSystem.exists(directory)) {
				sweep(root, directory);
				sys.FileSystem.createDirectory(directory);
			}
			sys.io.File.saveContent(Path.join([directory, MARKER]), '');
		} catch (_: Exception) {
			// Another process may have created it between the check and the call; the directory test below decides.
		}
		if (sys.FileSystem.exists(directory) && sys.FileSystem.isDirectory(directory)) _directory = directory;
		return _directory;
	}

	private function entryPath(directory: String, file: String): String {
		return Path.join([directory, entryName(file)]);
	}

	/** Remove every other engine's directory under `root` that has sat unused past the idle limit. */
	private static function sweep(root: String, keep: String): Void {
		for (name in sys.FileSystem.readDirectory(root)) {
			final other: String = Path.join([root, name]);
			if (!name.startsWith(DIR_PREFIX) || other == keep) continue;
			try {
				final marker: String = Path.join([other, MARKER]);
				final idle: Float = (Date.now().getTime() - sys.FileSystem.stat(marker).mtime.getTime()) / MILLISECONDS;
				if (idle > IDLE_SECONDS) removeTree(other);
			} catch (_: Exception) {
				// A directory without a marker is not ours to judge.
			}
		}
	}

	private static function removeTree(path: String): Void {
		for (name in sys.FileSystem.readDirectory(path)) {
			final child: String = Path.join([path, name]);
			if (sys.FileSystem.isDirectory(child))
				removeTree(child)
			else
				sys.FileSystem.deleteFile(child);
		}
		sys.FileSystem.deleteDirectory(path);
	}

	private static function header(source: String): String {
		return '$FORMAT_TAG ${ContentHash.md5(source)}';
	}
	#end

}
