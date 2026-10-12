package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.CallGraphNames;
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

	/**
	 * The project natives whose graph id is also the name of a blocking library call (`Lock.wait` beside the runtime's
	 * `sys.thread.Lock.wait`): a call of the library one the graph cannot tell apart — a receiver typed where it reads no
	 * package — resolves to it, so no `nonBlocking` entry waives it (`waived`).
	 */
	public final shadowing: Array<String>;

	/** The sinks the `nonBlocking` entries of the run's chains removed (`waived`), for the notice. */
	private final _removed: Array<String> = [];

	/** The `nonBlocking` entries of the run's chains that removed a sink. */
	private final _removers: Array<String> = [];

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
		final named: Array<String> = [for (p in calls) CallGraphNames.lastSegments(p, 2)];
		shadowing = [
			for (id in natives) if (named.contains(id) || named.contains('${graph.node(id)?.typeName}.*')) id
		];
	}

	/**
	 * The builtin sinks and natives the `nonBlocking` entries of `options` waive; each entry that waives none, names a
	 * call of `configured` — the chain's own `sinks`, which keep it — or names a native that bears a library call's name
	 * (`shadowing`), which it keeps too, said in `found`.
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
			for (id in hit) if (shadowing.contains(id))
				found.push(
					'nonBlocking entry "$pattern" names the project native "$id", which bears the name of a blocking library call'
					+ ' — kept: a call of the library one the graph cannot tell apart from it resolves there'
				);
			final removed: Array<String> = [for (id in hit) if (!shadowing.contains(id)) id];
			for (id in removed) if (!out.contains(id)) out.push(id);
			// what the run's notice counts
			if ((removed.length > 0 || walked?.waives(pattern) == true) && !_removers.contains(pattern)) _removers.push(pattern);
			for (id in removed) if (!_removed.contains(id)) _removed.push(id);
		}
		return out;
	}

	/** The library calls whose bodies block, for a chain whose `options` walk the libraries (`libraryBodies`); none otherwise. */
	public inline function libraryFor(options: ThreadSafetyOptions): Array<String> {
		return walkedFor(options)?.ids ?? [];
	}

	/**
	 * The notice a reporting run gives once: how many blocking library calls there are, how many it makes, its natives, and
	 * how many of them the run's `nonBlocking` entries removed (`waived`, which a run calls first).
	 */
	public function notice(): String {
		final waivers: String = _removers.length == 0
			? ''
			: ' (here ${_removed.length} sink(s) by ${_removers.length} entr${_removers.length == 1 ? 'y' : 'ies'})';
		return
			'$NOTICE$patterns blocking calls of the runtime library (${builtin.length} of them called in this run) and ${natives.length}'
				+ ' project native(s)${library?.notice() ?? ''} — "sinks" adds to them, "nonBlocking" removes from them$waivers';
	}

	/** The libraries walked, for a chain whose `options` ask for them (`libraryBodies`); null otherwise. */
	private inline function walkedFor(options: ThreadSafetyOptions): Null<LibraryBodies> {
		return options.list(LibraryBodies.OPTION).length > 0 ? library : null;
	}

}
