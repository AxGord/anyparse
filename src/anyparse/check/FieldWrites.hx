package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/** One write of a field-shaped target in a file of the run. */
typedef FieldWriteSite = {
	/** The write itself: an assignment, a compound assignment, an increment or a decrement. */
	final write: QueryNode;

	/** The file the write sits in. */
	final file: String;

	/** Whether the target is the running object's own: a bare name, or one read off `this`. */
	final own: Bool;

	/** The function the write runs in (a lambda's or a local function's own id); null outside every function. */
	final fn: Null<String>;

	/**
	 * For an `own` target, the type declaring the field the name binds in the type of `fn` (`declaringTypeOf`); null when
	 * that type declares none by the name, or no function is around the write.
	 */
	final declaring: Null<String>;

	/** Whether a function is around the write and the graph knows its type. */
	final typed: Bool;
}

/**
 * Every write of a field-shaped target the run's files hold, by the name written, walked ONCE per run (`ObjectPaths`
 * asks which fields stay put, `AllocationSets` which classes a field may hold, `ExhaustiveSwitches` what a member is
 * assigned), and whether the run sees every write of the project at all (`complete`).
 *
 * A write is positive evidence only in one direction: a write the index holds may change the field, and a field the
 * index holds no write of is unwritten only when `complete` — the run covers the whole project a `closedWorld`
 * declaration closes (`ThreadSafety.listsByFile`). Anything else, a consumer reads as unknown.
 *
 * Why not `FieldWriteIndex`: it re-parses every file it is handed, records a write's span but neither the function it
 * runs in nor its value, and attributes a write by the receiver's DECLARED type, which for this question needs the
 * subtype closure on top to stay sound. The graph already holds every tree; a write of the name through any receiver
 * but the running object is taken to write every field of that name, which over-counts only toward unstable.
 */
@:nullSafety(Strict)
final class FieldWrites {

	/** Whether the run sees every write of the project: every file's chain declares `closedWorld` and the run covers the project. */
	public final complete: Bool;

	/** The name written -> every write of it. */
	private final _byName: Map<String, Array<FieldWriteSite>> = [];

	private final _graph: CallGraph;
	private final _shape: RefShape;

	public function new(graph: CallGraph, plugin: GrammarPlugin, complete: Bool) {
		_graph = graph;
		_shape = plugin.refShape();
		this.complete = complete;
		for (held in graph.heldFiles()) collect(held.file, held.tree);
	}

	/** Every write of a target named `name`, in the order the files were walked. */
	public inline function of(name: String): Array<FieldWriteSite> {
		return _byName[name] ?? [];
	}

	/** Records every write in `node`'s subtree, in `file`. */
	private function collect(file: String, node: QueryNode): Void {
		if (_shape.writeParentKinds.contains(node.kind) && node.children.length > 0) record(file, node, node.children[0]);
		for (c in node.children) collect(file, c);
	}

	/** Records the write `write` of `target` when the target names a field: a bare name, or a field read off any value. */
	private function record(file: String, write: QueryNode, target: QueryNode): Void {
		final name: Null<String> = target.name;
		final at: Null<Span> = target.span;
		final own: Bool = target.kind == _shape.identKind || LockSites.ownMemberRead(target, _shape);
		if (name == null || at == null || !(own || LockSites.accessKind(target.kind, _shape))) return;
		final fn: Null<String> = _graph.functionAt(file, at.from);
		final type: Null<String> = fn == null ? null : _graph.node(fn)?.typeName;
		final list: Array<FieldWriteSite> = _byName[name] ?? [];
		list.push({
			write: write,
			file: file,
			own: own,
			fn: fn,
			declaring: type == null ? null : _graph.types.declaringTypeOf(type, name),
			typed: type != null
		});
		_byName[name] = list;
	}

	/**
	 * Whether `site` may write the field of that name `owner` declares: any receiver's but the running object's always —
	 * what it is written on, nothing here can tell — and the running object's when its type declares the field as
	 * `owner`'s, declares none by the name (a local of that name included), or is unknown.
	 */
	public static inline function mayWrite(site: FieldWriteSite, owner: String): Bool {
		return !site.own || !site.typed || site.declaring == null || site.declaring == owner;
	}

}
