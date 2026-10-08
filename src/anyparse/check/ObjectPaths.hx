package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * The object a call is made on, named relative to the object the calling function runs on, for the locks a hold
 * carries into its callees (`MustHeld`): a PATH of fields read off it — a bare field or one read off `this`, and at most
 * one field of that (`fileSystem.cloudDatabase`) — each STABLE: `final`, or a `var` that nothing writes outside its
 * type's constructor. A link is named by its member name, joined by `SEPARATOR`: one object holds one field of a name,
 * whichever type declares it. Positive: any other receiver names no object.
 */
@:nullSafety(Strict)
final class ObjectPaths {

	/** Joins the links of a path. */
	public static inline final SEPARATOR: String = '>';

	/** Each field id (`Type.member`) -> whether nothing changes the object it names after construction. */
	private final _stable: Map<String, Bool> = [];

	private final _graph: CallGraph;
	private final _sites: LockSites;
	private final _shape: RefShape;

	public function new(graph: CallGraph, plugin: GrammarPlugin, sites: LockSites) {
		_graph = graph;
		_sites = sites;
		_shape = plugin.refShape();
	}

	/**
	 * The path of the object the call `edge` is made on, relative to the running object: its receiver a stable field of
	 * it (`stable`), as `CallEdge.receiverField` names it, or a stable field of such a field; null for any other receiver.
	 */
	public function receiverPath(edge: CallEdge): Null<String> {
		final callee: Null<QueryNode> = _sites.calleeOf(edge);
		final receiver: Null<QueryNode> = callee != null && _sites.isAccess(callee.kind) && callee.children.length > 0
			? callee.children[0]
			: null;
		final field: String = edge.receiverField ?? '';
		if (receiver == null || field == '' || !stable(field)) return null;
		if (_sites.readsOwnMember(receiver)) return nameOf(field);
		final inner: Null<QueryNode> = _sites.isAccess(receiver.kind) && receiver.children.length > 0 ? receiver.children[0] : null;
		final first: Null<String> = inner != null && _sites.readsOwnMember(inner) ? ownField(edge.from, inner) : null;
		return first == null || !stable(first) ? null : nameOf(first) + SEPARATOR + nameOf(field);
	}

	/**
	 * Whether the field `field` (`Type.member`) names one object for good once its type's constructor ran: a `final`
	 * one, or a `var` no assignment, compound assignment, increment or decrement of any project file writes outside that
	 * constructor — any write of the name counts, whatever its receiver.
	 */
	public function stable(field: String): Bool {
		final known: Null<Bool> = _stable[field];
		if (known != null) return known;
		final dot: Int = field.lastIndexOf('.');
		final info: Null<MemberInfo> = dot <= 0 ? null : _graph.types.memberOnChain(field.substring(0, dot), field.substring(dot + 1));
		final kind: String = info?.kind ?? '';
		final fields: Array<String> = _shape.fieldDeclKinds ?? [];
		final answer: Bool = fields.contains(kind)
			&& (!(_shape.mutableFieldDeclKinds ?? []).contains(kind)
				|| writtenOnlyInConstructor(field.substring(0, dot), field.substring(dot + 1)));
		_stable[field] = answer;
		return answer;
	}

	/** The member name of the field id `field`. */
	private static inline function nameOf(field: String): String {
		return field.substring(field.lastIndexOf('.') + 1);
	}

	/** The id of the field of the type `from` runs in that `node` (a bare name or `this.name`) reads; null when none is. */
	private function ownField(from: String, node: QueryNode): Null<String> {
		final type: Null<String> = _graph.node(from)?.typeName;
		final name: Null<String> = node.name;
		if (type == null || name == null) return null;
		final owner: Null<String> = _graph.types.declaringTypeOf(type, name);
		return owner == null ? null : '$owner.$name';
	}

	/**
	 * Whether no write of the field `name` of `type` in any file the graph holds sits outside the constructor of `type`:
	 * a write of a bare `name` or `this.name` counts where `name` is that field of the type of the function around it,
	 * or where no function is; any other receiver's `.name` always — what it is written on, nothing here can tell.
	 */
	private function writtenOnlyInConstructor(type: String, name: String): Bool {
		final ctor: Null<FnNode> = _graph.node(_graph.ownMember(type, _shape.constructorName ?? 'new') ?? '');
		final field: { name: String, owner: String } = { name: name, owner: _graph.types.declaringTypeOf(type, name) ?? type };
		for (held in _graph.heldFiles()) {
			final allowed: Null<Span> = ctor != null && ctor.file == held.file ? ctor.span : null;
			if (writesOutside(held.file, held.tree, field, allowed)) return false;
		}
		return true;
	}

	/** Whether `node`'s subtree, in `file`, writes the field `field` outside the span `allowed`. */
	private function writesOutside(file: String, node: QueryNode, field: { name: String, owner: String }, allowed: Null<Span>): Bool {
		final at: Null<Span> = node.span;
		final write: Bool = _shape.writeParentKinds.contains(node.kind) && node.children.length > 0 && writes(file, node.children[0], field);
		if (write && !inside(at, allowed)) return true;
		return node.children.exists(c -> writesOutside(file, c, field, allowed));
	}

	/** Whether the span `at` lies within `allowed`; never when either is unknown. */
	private static inline function inside(at: Null<Span>, allowed: Null<Span>): Bool {
		return allowed != null && at != null && allowed.from <= at.from && at.to <= allowed.to;
	}

	/** Whether the write target `target` in `file` may be the field `field`. */
	private function writes(file: String, target: QueryNode, field: { name: String, owner: String }): Bool {
		if (target.name != field.name) return false;
		if (!(target.kind == _shape.identKind || _sites.readsOwnMember(target))) return _sites.isAccess(target.kind);
		// a bare name or `this.name` writes the field of the running type, when that type has one by the name
		final at: Null<Span> = target.span;
		final fn: Null<String> = at == null ? null : _graph.functionAt(file, at.from);
		final type: Null<String> = fn == null ? null : _graph.node(fn)?.typeName;
		final declared: Null<String> = type == null ? null : _graph.types.declaringTypeOf(type, field.name);
		return type == null || declared == null || declared == field.owner;
	}

}
