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

	/** The run's library calls whose library bodies block (`LibraryBodies`), when a chain asked for them; null otherwise. */
	public final library: Null<LibraryBodies>;

	public function new(
		graph: CallGraph, plugin: GrammarPlugin, projectNatives: ProjectNatives, library: Null<LibraryBodies>
	) {
		final execution: Null<ExecutionShape> = plugin.refShape().execution;
		// a type every member of which blocks is the pattern naming them all
		final calls: Array<String> = (execution?.blockingLibraryCalls ?? []).concat([
			for (t in execution?.blockingLibraryTypes ?? []) '$t.*'
		]);
		final ids: Array<String> = [];
		for (p in calls) for (id in graph.matchIds(p)) if (graph.node(id)?.isExternal == true && !ids.contains(id)) ids.push(id);
		patterns = calls.length;
		builtin = ids;
		natives = projectNatives.ids;
		this.library = library;
	}

	/**
	 * The builtin sinks and natives the `nonBlocking` entries of `options` waive; each entry that waives none, or names a
	 * call of `configured` — the chain's own `sinks`, which keep it — said in `found`.
	 */
	public function waived(options: ThreadSafetyOptions, graph: CallGraph, configured: Array<String>, found: Array<String>): Array<String> {
		final out: Array<String> = [];
		final walked: Null<LibraryBodies> = walkedFor(options);
		final blocking: Array<String> = libraryFor(options);
		for (pattern in options.nonBlocking) {
			final ids: Array<String> = graph.matchIds(pattern);
			final hit: Array<String> = [
				for (id in ids) if (builtin.contains(id) || natives.contains(id) || blocking.contains(id)) id
			];
			if (hit.length == 0 && walked?.waives(pattern) != true)
				found.push('nonBlocking entry "$pattern" waives no builtin sink or project native of the run');
			if (ids.exists(id -> configured.contains(id)))
				found.push('nonBlocking entry "$pattern" names a call "sinks" lists too, which keeps it');
			for (id in hit) if (!out.contains(id)) out.push(id);
		}
		return out;
	}

	/** The library calls whose bodies block, for a chain whose `options` walk the libraries (`libraryBodies`); none otherwise. */
	public inline function libraryFor(options: ThreadSafetyOptions): Array<String> {
		return walkedFor(options)?.ids ?? [];
	}

	/** The notice a reporting run gives once: how many blocking library calls there are, how many it makes, and its natives. */
	public function notice(): String {
		return
			'$NOTICE$patterns blocking calls of the runtime library (${builtin.length} of them called in this run) and ${natives.length}'
				+ ' project native(s)${library?.notice() ?? ''} — "sinks" adds to them, "nonBlocking" removes from them';
	}

	/** The libraries walked, for a chain whose `options` ask for them (`libraryBodies`); null otherwise. */
	private inline function walkedFor(options: ThreadSafetyOptions): Null<LibraryBodies> {
		return options.list(LibraryBodies.OPTION).length > 0 ? library : null;
	}

}
