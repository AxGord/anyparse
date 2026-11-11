package anyparse.check.common.design.threads;

import anyparse.query.CallGraph;

/**
 * The one answer to "may two reads of a field disagree because another thread writes it": the functions a thread a
 * configured `spawns` call starts may run (`ThreadContexts`), set against the writes of a field name (`FieldWrites`).
 *
 * A field is at risk when a write of its name runs on a spawned thread, when a reflective write may reach it (one that stores a
 * lock-typed value, or whose target the run cannot bound to a class that declares it), or when its reader runs on one and any
 * function but a constructor writes it. A write outside every function (a field initializer) runs before any thread.
 */
@:nullSafety(Strict)
final class SpawnedWriters {

	private final _contexts: ThreadContexts;
	private final _graph: CallGraph;
	private final _writes: FieldWrites;
	private final _constructor: Null<String>;

	/** `constructorName`: how the grammar names a constructor. */
	public function new(graph: CallGraph, writes: FieldWrites, contexts: ThreadContexts, constructorName: Null<String>) {
		_graph = graph;
		_writes = writes;
		_contexts = contexts;
		_constructor = constructorName;
	}

	/** Whether the field named `name`, read in the function `reader`, may change under a reader that reads it twice. */
	public function mayChangeUnderRead(name: String, reader: Null<String>): Bool {
		if (_writes.reflectivelyWritten(name)) return true;
		final readerSpawned: Bool = _contexts.runsBackground(reader);
		for (site in _writes.of(name)) {
			final fn: Null<String> = site.fn;
			if (site.reflective && site.reaches == null) return true;
			if (_contexts.runsBackground(fn) || (readerSpawned && fn != null && !isConstructor(fn))) return true;
		}
		return false;
	}

	private function isConstructor(id: String): Bool {
		final name: Null<String> = _graph.node(id)?.name;
		return name != null && (name == _constructor || name == CallGraph.INIT_NAME);
	}

}
