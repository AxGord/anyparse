package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

using Lambda;

/** A method a constructor reaches: its type, that constructor, its span and the earliest point reaching it. */
typedef ReachedMethod = {
	final container: QueryNode;
	final ctor: QueryNode;
	final method: Span;
	final first: Int;
};

/**
 * The one answer to "may this method run from the constructor before a field is assigned": every method a type's
 * sole constructor reaches through own-method names, each with the earliest point reaching it — a field initializer
 * (-1) or the start of a top-level constructor statement. A method name spelled anywhere, called or passed as a value,
 * counts as a call, so the graph errs toward reaching; a field counts as assigned only by the top-level constructor
 * statement `CtorFieldWrite.soleConstructorFieldInit` finds, ending before that earliest point.
 */
@:nullSafety(Strict)
final class ConstructorReach {

	private final _reached: Array<ReachedMethod> = [];
	private final _shape: RefShape;

	/** Every reached method of the types (`typeKinds`) under `tree`. */
	public function new(tree: QueryNode, typeKinds: Array<String>, shape: RefShape) {
		_shape = shape;
		collect(tree, typeKinds);
	}

	/**
	 * Whether `node`, read through the receiver chain `receiver`, may run before the type assigns the own field that
	 * chain starts from (`h` of `h.a`, `this.h`); a node with no span may.
	 */
	public function unassignedAt(node: QueryNode, receiver: QueryNode): Bool {
		final at: Null<Span> = node.span;
		if (at == null) return true;
		final span: Span = at;
		final hit: Null<ReachedMethod> = _reached.find(r -> r.method.from <= span.from && span.to <= r.method.to);
		final name: Null<String> = rootName(receiver);
		if (hit == null || name == null) return false;
		final entry: ReachedMethod = hit;
		final field: Null<QueryNode> = dataField(entry.container, name);
		if (field == null) return false;
		final init: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = CtorFieldWrite.soleConstructorFieldInit(
			entry.container, entry.ctor, field, _shape
		);
		final stmtSpan: Null<Span> = init?.stmt.span;
		return stmtSpan == null || entry.first < stmtSpan.to;
	}

	/** The name a receiver chain starts from, or null for a bare `this`. */
	private function rootName(receiver: QueryNode): Null<String> {
		final self: Null<String> = _shape.selfReferenceText;
		var node: QueryNode = receiver;
		while (node.kind == _shape.fieldAccessKind && node.children.length == 1) {
			final inner: QueryNode = node.children[0];
			if (inner.kind == _shape.identKind) return inner.name == self ? node.name : inner.name;
			node = inner;
		}
		return node.kind == _shape.identKind && node.name != self ? node.name : null;
	}

	/** The data field `name` declared in `container`, or null. */
	private function dataField(container: QueryNode, name: String): Null<QueryNode> {
		final members: Array<String> = _shape.memberDeclKinds ?? [];
		final functions: Array<String> = _shape.functionKinds ?? [];
		var found: Null<QueryNode> = null;
		MemberKinds.eachMemberHost(container, host -> for (m in host.children)
			if (m.name == name && members.contains(m.kind) && !functions.contains(m.kind)) found = m);
		return found;
	}

	private function collect(node: QueryNode, typeKinds: Array<String>): Void {
		if (typeKinds.contains(node.kind)) reachIn(node);
		for (c in node.children) collect(c, typeKinds);
	}

	private function reachIn(container: QueryNode): Void {
		final ctor: Null<QueryNode> = CtorFieldWrite.soleConstructor(container, _shape);
		if (ctor == null) return;
		final built: QueryNode = ctor;
		final members: Array<String> = _shape.memberDeclKinds ?? [];
		final functions: Array<String> = _shape.functionKinds ?? [];
		final methods: Map<String, QueryNode> = [];
		final initializers: Array<QueryNode> = [];
		MemberKinds.eachMemberHost(container, host -> {
			for (m in host.children) {
				final name: Null<String> = m.name;
				if (name == null || name == _shape.constructorName || !members.contains(m.kind)) continue;
				if (functions.contains(m.kind))
					methods[name] = m
				else
					initializers.push(m);
			}
		});
		final first: Map<String, Int> = [];
		for (f in initializers) reach(f, -1, methods, first);
		final body: Null<QueryNode> = built.children.find(c -> c.kind == _shape.blockBodyKind);
		if (body != null) for (stmt in body.children) reach(stmt, stmt.span?.from ?? -1, methods, first);
		for (name => from in first) {
			final span: Null<Span> = methods[name]?.span;
			if (span == null) continue;
			final method: Span = span;
			_reached.push({
				container: container,
				ctor: built,
				method: method,
				first: from
			});
		}
	}

	/** Records every own method `node` names, and those their bodies name in turn, as reached from `from` unless reached earlier. */
	private function reach(node: QueryNode, from: Int, methods: Map<String, QueryNode>, first: Map<String, Int>): Void {
		final name: Null<String> = ownName(node);
		final method: Null<QueryNode> = name == null ? null : methods[name];
		if (name != null && method != null) {
			final known: Null<Int> = first[name];
			if (known == null || from < known) {
				first[name] = from;
				reach(method, from, methods, first);
			}
		}
		for (c in node.children) reach(c, from, methods, first);
	}

	/** The member name of a bare identifier or a `this.name` access, or null. */
	private function ownName(node: QueryNode): Null<String> {
		final self: Null<String> = _shape.selfReferenceText;
		if (node.kind == _shape.identKind) return node.name == self ? null : node.name;
		if (node.kind != _shape.fieldAccessKind || node.children.length != 1) return null;
		final inner: QueryNode = node.children[0];
		return inner.kind == _shape.identKind && inner.name == self ? node.name : null;
	}

}
