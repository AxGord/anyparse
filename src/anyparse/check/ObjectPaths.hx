package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex.MemberInfo;

using Lambda;

/**
 * The object a call is made on, named relative to the object the calling function runs on, for the locks a hold
 * carries into its callees (`MustHeld`): a PATH of fields read off it — a bare field or one read off `this`, and at most
 * one field of that (`fileSystem.cloudDatabase`) — each STABLE: `final`, or an instance `var` that nothing writes outside
 * its type's constructor. A link is named by its member name, joined by `SEPARATOR`: one object holds one field of a
 * name, whichever type declares it. Positive: any other receiver names no object, and a `var` is stable only when the
 * run sees every write of the project (`FieldWrites.complete`).
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

	/** The run's field writes. */
	private final _writes: FieldWrites;

	public function new(graph: CallGraph, plugin: GrammarPlugin, sites: LockSites, writes: FieldWrites) {
		_graph = graph;
		_sites = sites;
		_shape = plugin.refShape();
		_writes = writes;
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
	 * one, or an instance `var` the run sees every write of (`FieldWrites.complete`) and none outside that constructor's
	 * own body — any write of the name counts, whatever its receiver, and one in a lambda or a local function the
	 * constructor makes runs later. A field read through a getter (`get`, `dynamic`) names whatever the getter returns,
	 * and a `static var` is written anew by every write of it, the instance constructor's included: neither is stable.
	 */
	public function stable(field: String): Bool {
		final known: Null<Bool> = _stable[field];
		if (known != null) return known;
		final dot: Int = field.lastIndexOf('.');
		final type: String = field.substring(0, dot);
		final name: String = field.substring(dot + 1);
		final info: Null<MemberInfo> = dot <= 0 ? null : _graph.types.memberOnChain(type, name);
		final answer: Bool = info != null && (_shape.fieldDeclKinds ?? []).contains(info.kind) && !info.hasGetter
			&& (!(_shape.mutableFieldDeclKinds ?? []).contains(info.kind) || writtenOnlyInConstructor(type, name, info.isStatic));
		_stable[field] = answer;
		return answer;
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
	 * Whether the run sees every write of the field `name` of `type` and each sits in the body of the constructor of
	 * `type` itself, on the running object (a bare `name` or `this.name`) — never for a `static` one, which no
	 * constructor owns. A write in a lambda or a local function sits in that function, which may run any time later.
	 */
	private function writtenOnlyInConstructor(type: String, name: String, isStatic: Bool): Bool {
		if (!_writes.complete) return false;
		final ctor: Null<String> = isStatic ? null : _graph.ownMember(type, _shape.constructorName ?? 'new');
		final owner: String = _graph.types.declaringTypeOf(type, name) ?? type;
		return _writes.of(name).foreach(w -> !FieldWrites.mayWrite(w, owner) || w.own && ctor != null && w.fn == ctor);
	}

	/** The member name of the field id `field`. */
	private static inline function nameOf(field: String): String {
		return field.substring(field.lastIndexOf('.') + 1);
	}

}
