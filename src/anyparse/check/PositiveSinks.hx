package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;

using Lambda;

/**
 * The sinks every reporting `thread-safety` chain starts from, with no configuration: the grammar's blocking library
 * calls the run makes (`ExecutionShape.blockingLibraryCalls`) — on a target the run holds no body for, so a project
 * function of the same name is read through its body — and the project's natives (`ProjectNatives`). A chain's `sinks`
 * adds to them, its `nonBlocking` entries waive them (`waived`).
 */
@:nullSafety(Strict)
final class PositiveSinks {

	/** How the one notice a reporting run gives of the sinks it applied begins (`notice`). */
	public static inline final NOTICE: String = 'builtin sinks applied: ';

	/** How many blocking library calls the grammar names. */
	public final patterns: Int;

	/** The graph ids of the blocking library calls the run makes. */
	public final builtin: Array<String>;

	/** The graph ids of the project's natives. */
	public final natives: Array<String>;

	public function new(graph: CallGraph, plugin: GrammarPlugin, projectNatives: ProjectNatives) {
		final calls: Array<String> = plugin.refShape().execution?.blockingLibraryCalls ?? [];
		final ids: Array<String> = [];
		for (p in calls) for (id in graph.matchIds(p)) if (graph.node(id)?.isExternal == true && !ids.contains(id)) ids.push(id);
		patterns = calls.length;
		builtin = ids;
		natives = projectNatives.ids;
	}

	/**
	 * The builtin sinks and natives the `nonBlocking` entries of `options` waive; each entry that waives none, or names a
	 * call of `configured` — the chain's own `sinks`, which keep it — said in `found`.
	 */
	public function waived(options: ThreadSafetyOptions, graph: CallGraph, configured: Array<String>, found: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (pattern in options.nonBlocking) {
			final ids: Array<String> = graph.matchIds(pattern);
			final hit: Array<String> = [for (id in ids) if (builtin.contains(id) || natives.contains(id)) id];
			if (hit.length == 0) found.push('nonBlocking entry "$pattern" waives no builtin sink or project native of the run');
			if (ids.exists(id -> configured.contains(id)))
				found.push('nonBlocking entry "$pattern" names a call "sinks" lists too, which keeps it');
			for (id in hit) if (!out.contains(id)) out.push(id);
		}
		return out;
	}

	/** The notice a reporting run gives once: how many blocking library calls there are, how many it makes, and its natives. */
	public function notice(): String {
		return
			'$NOTICE$patterns blocking calls of the runtime library (${builtin.length} of them called in this run) and ${natives.length}'
				+ ' project native(s) — "sinks" adds to them, "nonBlocking" removes from them';
	}

}
