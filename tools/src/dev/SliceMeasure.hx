package dev;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CallGraph;
import anyparse.query.graph.MemberGraphBuilder;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.TempDir;
import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * What one revision's own sources say for `dev slice-stats`, read from a copy of its roots that `git archive` writes: the
 * member call edges (the call graph lifted to members as `MemberGraphBuilder` lifts it) with the file each lands in, and the
 * findings of the two duplicate-code rules. A reading is kept in the cache under the revision, the roots and the binary that
 * took it, so a series of landings reads each commit once: a landing's base is the landing before it.
 */
@:nullSafety(Strict)
final class SliceMeasure {

	/** The roots a reading covers when the caller names none. */
	public static inline final DEFAULT_ROOTS: String = 'src';

	/** The hex digits of a cache key's digest a file name carries. */
	private static inline final KEY_LENGTH: Int = 16;

	/** The duplicate-code rules a clone reading counts the findings of: renamed (type-2) and exact (type-1) copies. */
	private static final CLONE_RULES: Array<String> = ['duplicate-code-renamed', 'duplicate-code'];

	/** The files beside the roots a lint of a copy reads its configuration from. */
	private static final CONFIG_FILES: Array<String> = ['apqlint.json', 'hxformat.json'];

	private final _repo: String;
	private final _roots: Array<String>;
	private final _cache: String;

	public function new(repo: String, roots: Array<String>, cache: String) {
		_repo = repo;
		_roots = roots;
		_cache = cache;
		FileSystem.createDirectory(cache);
	}

	/** The `.hx` files under the roots at `sha` and their member call edges. */
	public function edges(sha: String): EdgeReading {
		final file: String = cacheFile(sha, 'edges', js.Node.__filename);
		if (FileSystem.exists(file)) return decodeEdges(File.getContent(file));
		final reading: EdgeReading = withCopy(sha, copy -> edgesOf(copy, _roots));
		File.saveContent(file, encodeEdges(reading));
		return reading;
	}

	/** The findings of the duplicate-code rules over the roots at `sha`, by the engine of the tree the tool acts on. */
	public function clones(sha: String): Int {
		final engine: String = Path.join([_repo, 'bin/apq.js']);
		final file: String = cacheFile(sha, 'clones', engine);
		if (FileSystem.exists(file)) return Std.parseInt(File.getContent(file)) ?? 0;
		final count: Int = withCopy(sha, clonesOf);
		File.saveContent(file, '$count');
		return count;
	}

	/**
	 * The findings of the duplicate-code rules over the roots of the tree `copy`. The rules read syntax alone, so the lint
	 * runs without the compiler oracle, which would build a revision the tool never built.
	 */
	private function clonesOf(copy: String): Int {
		final roots: Array<String> = [for (root in _roots) if (FileSystem.exists(Path.join([copy, root]))) root];
		if (roots.length == 0) return 0;
		var count: Int = 0;
		for (rule in CLONE_RULES) {
			final args: Array<String> = ['lint'].concat(roots).concat(['--rule', rule, '--no-oracle', '--format', 'json']);
			final run: Result = GateTree.shim(_repo, copy, args).run().check();
			final report: String = Path.join([Path.directory(copy), '$rule.json']);
			File.saveContent(report, run.out);
			count += CloneCensus.parseReport(report).length;
		}
		return count;
	}

	/** `body` over a copy of the roots and the configuration files at `sha`, removed afterwards. */
	private function withCopy<T>(sha: String, body: String -> T): T {
		return TempDir.with(dir -> {
			final copy: String = dir.file('tree');
			FileSystem.createDirectory(copy);
			final paths: Array<String> = [
				for (path in _roots.concat(CONFIG_FILES)) if (cmd('git -C $_repo cat-file -e $sha:$path').run().ok) path
			];
			if (paths.length > 0) {
				final archive: String = dir.file('tree.tar');
				cmd('git -C $_repo archive --format=tar -o $archive $sha $paths').check();
				cmd('tar -xf $archive -C $copy').check();
			}
			body(copy);
		});
	}

	/** The cache file of the reading `kind` of `sha`, keyed by the roots and by the size and time of the `binary` that takes it. */
	private function cacheFile(sha: String, kind: String, binary: String): String {
		final stat: sys.FileStat = FileSystem.stat(binary);
		final key: String = Sha256.encode('${_roots.join(',')} $binary ${stat.size} ${stat.mtime.getTime()}').substr(0, KEY_LENGTH);
		return Path.join([_cache, '$sha-$kind-$key.json']);
	}

	/** The cache directory a reading is kept in when the caller names none. */
	public static function defaultCache(): String {
		return Path.join([anyparse.core.TempScratch.root(), 'anyparse-slice-stats']);
	}

	/**
	 * What the slice from `before` to `after` did to the call edges: the edges `after` holds and `before` does not, split by
	 * where they land — a module `before` already held, one the slice added, or outside the roots.
	 */
	public static function share(before: EdgeReading, after: EdgeReading): EdgeShare {
		final held: Map<String, Bool> = [for (f in before.files) f => true];
		final out: EdgeShare = { added: 0, existing: 0, fresh: 0 };
		for (key => target in after.edges) if (!before.edges.exists(key)) {
			out.added++;
			if (target == '') continue;
			if (held.exists(target))
				out.existing++
			else
				out.fresh++;
		}
		return out;
	}

	/**
	 * The `.hx` files under `roots` of the tree `copy`, relative to it, and every call edge between two members, keyed
	 * `<from> -> <to>` and valued by the file the target lives in — empty for a target outside the roots. A lambda or a local
	 * function counts as its member, and an edge inside one member is not counted.
	 */
	public static function edgesOf(copy: String, roots: Array<String>): EdgeReading {
		final files: Array<{ file: String, source: String }> = [];
		for (root in roots) EdgeDiff.collect(Path.join([copy, root]), files);
		final calls: CallGraph = CallGraph.build(files, new CachingGrammarPlugin(new HaxeQueryPlugin())); // noqa: owned-types
		final members: MemberGraphBuilder = new MemberGraphBuilder(calls);
		final edges: Map<String, String> = [];
		for (e in calls.edges) if (e.kind != Contains) {
			final from: String = members.member(e.from);
			final to: String = members.member(e.to);
			if (from == to) continue;
			final target: Null<FnNode> = calls.node(e.to);
			final key: String = '${members.graph.node(from)?.name ?? from} -> ${members.graph.node(to)?.name ?? to}';
			edges[key] = target == null || target.isExternal ? '' : relative(copy, target.file);
		}
		return { files: [for (f in files) relative(copy, f.file)], edges: edges };
	}

	private static function relative(root: String, file: String): String {
		return file.startsWith('$root/') ? file.substr(root.length + 1) : file;
	}

	private static function encodeEdges(reading: EdgeReading): String {
		return Json.stringify({ files: reading.files, edges: [for (key => target in reading.edges) [key, target]] });
	}

	private static function decodeEdges(text: String): EdgeReading {
		final parsed: { files: Array<String>, edges: Array<Array<String>> } = Json.parse(text);
		return { files: parsed.files, edges: [for (pair in parsed.edges) pair[0] => pair[1]] };
	}

}

/** The `.hx` files of a revision's roots and its member call edges, each valued by the file it lands in (empty: outside). */
typedef EdgeReading = {
	var files: Array<String>;
	var edges: Map<String, String>;
}

/** The call edges a slice added, and how many of them land in a module the base held, in one it added. */
typedef EdgeShare = {
	var added: Int;
	var existing: Int;
	var fresh: Int;
}
