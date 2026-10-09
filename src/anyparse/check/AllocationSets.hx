package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.CallGraphNames;
import anyparse.query.CondRegionScan;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * The classes a dispatched call's receiver may be an instance of, where the code says: the running object's (handed
 * down a call path), or a field every value of which is a `new` the project writes — a SEALED allocation set. A
 * dispatch no class of the set resolves to the call's target never runs on that path (`BaseNativeURLLoader.load`'s
 * `go()` on a loader `APIRequest2.doRequest` only ever builds as a thread or simple loader is never the blocking one).
 * Positive: any other receiver, any other write or declared value, a class the index does not hold — unknown, every
 * target runs.
 */
@:nullSafety(Strict)
final class AllocationSets {

	/** Joins the classes of a set handed down a path. */
	public static inline final SEPARATOR: String = ',';

	/** Each field id -> its sealed allocation set, null when it has none. */
	private final _fields: Map<String, Null<Array<String>>> = [];

	private final _graph: CallGraph;
	private final _sites: LockSites;
	private final _shape: RefShape;

	public function new(graph: CallGraph, plugin: GrammarPlugin, sites: LockSites) {
		_graph = graph;
		_sites = sites;
		_shape = plugin.refShape();
	}

	/**
	 * The classes the object the call `edge` runs its target on may be, `self` the running object's (joined by
	 * `SEPARATOR`, null when unknown): the class a `new` names, the running object's for a call on it, a field's sealed
	 * allocation set for a dispatched call on a field of it (`fieldClasses`); null for any other call.
	 */
	public function receiverClasses(edge: CallEdge, self: Null<String>): Null<String> {
		if (edge.kind == New) return constructedAt(edge);
		if (!edge.kind.isInvocation()) return null;
		if (_sites.selfCall(edge)) return self;
		if (edge.dispatchType == null) return null;
		final callee: Null<QueryNode> = _sites.calleeOf(edge);
		final receiver: Null<QueryNode> = callee != null && _sites.isAccess(callee.kind) && callee.children.length > 0
			? callee.children[0]
			: null;
		final field: Null<String> = edge.receiverField;
		if (receiver == null || field == null || !_sites.readsOwnMember(receiver)) return null;
		return fieldClasses(field)?.join(SEPARATOR);
	}

	/**
	 * Whether the call `edge` may run its target on an object of `classes`: a call no type dispatches always does; a
	 * dispatched one or a construction when some class of them resolves to it (`resolves`).
	 */
	public function dispatches(edge: CallEdge, classes: Null<String>): Bool {
		if (classes == null || edge.dispatchType == null && edge.kind != New) return true;
		return classes.split(SEPARATOR).exists(c -> resolves(c, edge));
	}

	/** The classes of `classes` the dispatched call `edge` runs its target on: the target's own running object. */
	public function into(edge: CallEdge, classes: Null<String>): Null<String> {
		if (classes == null) return null;
		final kept: Array<String> = classes.split(SEPARATOR).filter(c -> resolves(c, edge));
		return kept.length == 0 ? null : kept.join(SEPARATOR);
	}

	/** The class the `new` at the site of the construction `edge` names; null when the tree cannot place it. */
	private function constructedAt(edge: CallEdge): Null<String> {
		final at: Null<Span> = edge.span;
		var node: Null<QueryNode> = at == null ? null : _graph.treeOf(edge.file);
		while (node != null && at != null) {
			final span: Null<Span> = node.span;
			if (node.kind == _shape.newExprKind && span != null && span.from == at.from && span.to == at.to)
				return constructed(node)?.join(SEPARATOR);
			node = node.children.find(c -> c.span != null && c.span.from <= at.from && c.span.to >= at.to);
		}
		return null;
	}

	/**
	 * The classes every value of the field `field` (`Type.member`) is constructed as: its declared value, if any, and every
	 * write of it a `new` (through `?:` and conditional compilation), each write a plain assignment; null otherwise, or
	 * when nothing gives it a value.
	 */
	public function fieldClasses(field: String): Null<Array<String>> {
		if (_fields.exists(field)) return _fields[field];
		final dot: Int = field.lastIndexOf('.');
		final type: String = field.substring(0, dot);
		final name: String = field.substring(dot + 1);
		final info: Null<MemberInfo> = dot <= 0 ? null : _graph.types.memberOnChain(type, name);
		final owner: String = _graph.types.declaringTypeOf(type, name) ?? type;
		final own: Null<Array<String>> = info == null ? null : declared(owner, info);
		final found: Array<String> = own ?? [];
		var sealed: Bool = own != null;
		for (held in _graph.heldFiles()) if (sealed && !collect(held.file, held.tree, name, owner, found)) sealed = false;
		final answer: Null<Array<String>> = !sealed || found.length == 0 ? null : found;
		_fields[field] = answer;
		return answer;
	}

	/**
	 * Whether the class `c` resolves the method `edge` dispatches to `edge.to`. A class the index holds no declaration of
	 * is a library's, which cannot inherit a project type: it never runs a project function by dispatch, while what a
	 * library function it may run is unknown.
	 */
	private function resolves(c: String, edge: CallEdge): Bool {
		final target: Null<FnNode> = _graph.node(edge.to);
		final name: Null<String> = target?.name;
		if (target == null || name == null) return true;
		if (_graph.types.declarationCount(c) == 0) return target.isExternal;
		final owner: Null<String> = _graph.types.declaringTypeOf(c, name);
		return owner == null || '$owner.$name' == edge.to;
	}

	/**
	 * The classes the declaration of the field `info` of `owner` constructs its own value as: none for a declaration with
	 * no value, a `new`'s for one (`constructed`); null for any other value, or a declaration the tree cannot place.
	 */
	private function declared(owner: String, info: MemberInfo): Null<Array<String>> {
		final file: Null<String> = fileOf(owner);
		final tree: Null<QueryNode> = file == null ? null : _graph.treeOf(file);
		final decl: Null<QueryNode> = tree == null ? null : declarationAt(tree, info.declFrom);
		if (decl == null || decl.children.length > 1) return null;
		return decl.children.length == 0 ? [] : constructed(decl.children[0]);
	}

	/** The node of `tree` starting at `from` that declares a member; null when none does. */
	private function declarationAt(tree: QueryNode, from: Int): Null<QueryNode> {
		var node: QueryNode = tree;
		while (true) {
			final at: Null<Span> = node.span;
			if (at != null && at.from == from && (_shape.fieldDeclKinds ?? []).contains(node.kind)) return node;
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= from && from < c.span.to);
			if (child == null) return null;
			node = child;
		}
	}

	/**
	 * Adds to `found` the classes the writes of the field `name` of `owner` in `node`'s subtree, in `file`, construct;
	 * false when one writes anything else.
	 */
	private function collect(file: String, node: QueryNode, name: String, owner: String, found: Array<String>): Bool {
		if (_shape.writeParentKinds.contains(node.kind) && node.children.length > 0 && writes(file, node.children[0], name, owner)) {
			final values: Null<Array<String>> = node.kind == _shape.assignKind && node.children.length == 2
				? constructed(node.children[1])
				: null;
			if (values == null) return false;
			for (v in values) if (!found.contains(v)) found.push(v);
		}
		return node.children.foreach(c -> collect(file, c, name, owner, found));
	}

	/** The file declaring the type `owner`, as the file of one of its functions; null when the graph holds none. */
	private function fileOf(owner: String): Null<String> {
		for (node in _graph.nodes) if (node.typeName == owner) return node.file;
		return null;
	}

	/** The classes the value `node` constructs: a `new`, either side of a `?:`, every branch of a conditional region; null for anything else. */
	private function constructed(node: QueryNode): Null<Array<String>> {
		final name: Null<String> = node.name;
		if (node.kind == _shape.newExprKind) return name == null ? null : [CallGraphNames.lastSegments(name, 1)];
		final parts: Array<QueryNode> = if (node.kind == _shape.ternaryKind && node.children.length == 3)
			node.children.slice(1)
		else if (node.kind == _shape.parenKind || CondRegionScan.isConditionalKind(node.kind, _shape))
			node.children
		else
			[];
		if (parts.length == 0) return null;
		final out: Array<String> = [];
		for (p in parts) {
			final inner: Null<Array<String>> = constructed(p);
			if (inner == null) return null;
			for (c in inner) if (!out.contains(c)) out.push(c);
		}
		return out;
	}

	/** Whether the write target `target` in `file` may be the field `name` of `owner` (as `ObjectPaths` reads a write). */
	private function writes(file: String, target: QueryNode, name: String, owner: String): Bool {
		if (target.name != name) return false;
		if (!(target.kind == _shape.identKind || _sites.readsOwnMember(target))) return _sites.isAccess(target.kind);
		final at: Null<Span> = target.span;
		final fn: Null<String> = at == null ? null : _graph.functionAt(file, at.from);
		final type: Null<String> = fn == null ? null : _graph.node(fn)?.typeName;
		final declared: Null<String> = type == null ? null : _graph.types.declaringTypeOf(type, name);
		return type == null || declared == null || declared == owner;
	}

}
