package anyparse.query;

import anyparse.core.ContentHash;
import anyparse.core.ParseProjectionEngine;
import anyparse.query.CallGraph.StoredCallGraph;
import haxe.Exception;

/**
 * The one answer to "is the call graph of these files already on disk": what `callers` / `callees` read of a graph
 * (`StoredCallGraph`), kept so a new process over the same files takes it back instead of collecting every file again.
 *
 * A call graph is not per-file — a call site resolves against the index of the whole scope — so an entry is one scope's
 * record in the parse store (`ParseDiskCache.lookupRecord` / `storeRecord`), named by the language, the working directory
 * and the scope's paths in place of a file, and made from the hash of every path and text it was built from: a scope where
 * any file changed, came or went misses and replaces its own entry. Its tag carries `ParseProjectionEngine.outlineDigest`,
 * the code that builds a graph, so another engine never reads it. Every doubt is a miss, so the store changes what a graph
 * COSTS, never what it answers; the process holds none of it (`docs/design-principles.md` § 2). `APQ_CALL_GRAPH_STORE=0`,
 * or the parse store switched off, turns it off.
 */
@:nullSafety(Strict)
@:access(anyparse.query.CallGraph)
final class CallGraphStore {

	/** The kind of the scope's record beside the parse store's entries. */
	private static final KIND: String = 'call-graph';

	/** The scheme tag opening every entry, with the digest of the code that builds a graph: bump it and every entry misses. */
	private static final TAG: String = 'apq-call-graph v2 ${ParseProjectionEngine.outlineDigest()}';

	private static final SWITCH_VARIABLE: String = 'APQ_CALL_GRAPH_STORE';

	private final _disk: ParseDiskCache;

	public function new(lang: String) {
		_disk = new ParseDiskCache(lang);
	}

	/** The graph stored for exactly `files`, each with the text it holds now, else null. */
	public function lookup(files: Array<{ file: String, source: String }>): Null<StoredCallGraph> {
		if (switchedOff()) return null;
		final record: Null<String> = _disk.lookupRecord(scopeName(files), contentOf(files), KIND, TAG);
		if (record == null) return null;
		return try haxe.Unserializer.run(record) catch (_: Exception) null;
	}

	/** Write what `graph`, built over `files` without compiler facts, answers `callers` / `callees` with. */
	public function keep(files: Array<{ file: String, source: String }>, graph: CallGraph): Void {
		if (switchedOff()) return;
		_disk.storeRecord(scopeName(files), contentOf(files), KIND, TAG, haxe.Serializer.run(storedOf(graph)));
	}

	/** What `restoreInto` takes back of `graph`. */
	public static function storedOf(graph: CallGraph): StoredCallGraph {
		return {
			nodes: graph.nodes,
			edges: graph.edges,
			unresolved: graph.unresolved,
			unresolvedAccess: graph.unresolvedAccess,
			skippedFiles: graph.skippedFiles,
			byMember: graph._byMember,
			bodies: graph._bodies,
			foreign: graph.types.imports.foreignTable()
		};
	}

	/**
	 * Fill `graph`, seeded with the index of the files `stored` was built over and nothing collected, with `stored`: what
	 * `callers` / `callees` read of it is then what collecting those files gives. Nothing else is collected — no declarations,
	 * trees or facts — so a graph restored is read and never grown.
	 */
	public static function restoreInto(graph: CallGraph, stored: StoredCallGraph): Void {
		for (id => node in stored.nodes) graph.nodes[id] = node;
		for (edge in stored.edges) graph.indexEdge(edge);
		for (call in stored.unresolved) graph.unresolved.push(call);
		for (access in stored.unresolvedAccess) graph.unresolvedAccess.push(access);
		for (file in stored.skippedFiles) graph.skippedFiles.push(file);
		for (name => ids in stored.byMember) graph._byMember[name] = ids;
		for (id => bodies in stored.bodies) graph._bodies[id] = bodies;
		graph.types.imports.restoreForeign(stored.foreign);
	}

	private static function switchedOff(): Bool {
		return #if (sys || nodejs) Sys.getEnv(SWITCH_VARIABLE) == '0' #else true #end;
	}

	private static function scopeName(files: Array<{ file: String, source: String }>): String {
		final cwd: String = #if (sys || nodejs) Sys.getCwd() #else '' #end;
		return '$cwd|${files.map(f -> f.file).join('\n')}';
	}

	/** The text an entry is made from: every path of the scope with the hash of the text it holds, in order. */
	private static function contentOf(files: Array<{ file: String, source: String }>): String {
		return files.map(f -> '${f.file}\n${ContentHash.md5(f.source)}').join('\n');
	}

}
