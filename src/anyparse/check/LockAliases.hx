package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/** One occurrence of a lock member's name that unseals the member, unless a proven alias accounts for it. */
typedef Occurrence = {
	final file: String;
	final node: QueryNode;
	final parent: Null<QueryNode>;
}

/**
 * A lock member (`target`) that only ever holds what another one (`source`) hands it through a constructor parameter:
 * the two name one lock. `keys` are the occurrences the hand-off accounts for — the constructor's write of the target
 * and every read of the source passed to a construction.
 */
private typedef LockAlias = {
	final target: String;
	final source: String;
	final keys: Array<String>;
}

/** A constructor's write of a lock member (`Owner.member`) from its parameter at `param`; `key` names the write. */
private typedef ConstructorWrite = {
	final member: String;
	final ctor: String;
	final param: Int;
	final key: String;
}

/** A read of the lock member `member` (`Owner.member`) handed to a construction; `key` names the read. */
private typedef MemberRead = {
	final key: String;
	final member: String;
}

/**
 * The lock members of a call graph that ALIAS another (`LockSites`): a member written once, in its type's constructor,
 * from a parameter used nowhere else, where every construction the graph can see — each `new`, each subclass
 * constructor forwarding a parameter of its own through `super(...)` — passes that parameter a read of one other
 * member, and nothing else can construct the type: no read of it or a subtype as a value (reflection may construct it
 * with anything), no subtype constructor the graph does not see call it. An alias stands only while every occurrence
 * unsealing either of its members is one of the hand-offs the standing aliases account for.
 */
@:nullSafety(Strict)
final class LockAliases {

	/** Each aliased lock member (`Owner.member`) -> the member it holds the lock of, which names the lock of both. */
	public final targets: Map<String, String> = [];

	/** The locks some alias names. */
	public final locks: Array<String> = [];

	/** `occurrenceKey` of every occurrence a settled alias accounts for. */
	private final _explained: Array<String> = [];

	private final _graph: CallGraph;
	private final _shape: RefShape;
	private final _sites: LockSites;
	private final _ctorName: String;
	private final _files: Array<String>;

	private var _candidates: Array<LockAlias> = [];

	/** Every declared type some expression reads as a value; null until asked. */
	private var _typesAsValues: Null<Array<String>> = null;

	public function new(graph: CallGraph, shape: RefShape, sites: LockSites, ctorName: String, files: Array<String>) {
		_graph = graph;
		_shape = shape;
		_sites = sites;
		_ctorName = ctorName;
		_files = files;
	}

	/** Whether a settled alias accounts for the occurrence `o`. */
	public inline function accounts(o: Occurrence): Bool {
		return _explained.contains(occurrenceKey(o.file, o.node));
	}

	/**
	 * Proposes every alias the `breaking` occurrences suggest — a lock member written exactly once, in its type's
	 * constructor, from a parameter used nowhere else (`constructorWrite`), whose every construction passes that
	 * parameter a read of one and the same other member (`handOffs`) — and returns the names of those other members:
	 * they must be walked too, since an alias needs its source sealed apart from its hand-offs.
	 */
	public function propose(breaking: Map<String, Array<Occurrence>>): Array<String> {
		final writes: Array<ConstructorWrite> = [];
		for (found in breaking) for (o in found) {
			final write: Null<ConstructorWrite> = constructorWrite(o);
			if (write != null) writes.push(write);
		}
		_candidates = [];
		for (w in writes) if (writes.count(x -> x.member == w.member) == 1) {
			final reads: Array<MemberRead> = [];
			if (!handOffs(w.ctor, w.param, [], reads) || reads.length == 0) continue;
			final source: String = reads[0].member;
			if (source != w.member && reads.foreach(r -> r.member == source))
				_candidates.push({ target: w.member, source: source, keys: [w.key].concat([for (r in reads) r.key]) });
		}
		final sources: Array<String> = [];
		for (a in _candidates) {
			final name: String = LockSites.memberName(a.source);
			if (!sources.contains(name)) sources.push(name);
		}
		return sources;
	}

	/**
	 * Keeps the proposed aliases that hold together, dropped a round at a time until none is — every occurrence unsealing
	 * either member of an alias accounted for by the aliases still standing, and no alias's source itself an alias's
	 * target — and records them.
	 */
	public function settle(breaking: Map<String, Array<Occurrence>>): Void {
		var live: Array<LockAlias> = _candidates;
		while (true) {
			final keys: Array<String> = [for (a in live) for (k in a.keys) k];
			final aliased: Array<String> = [for (a in live) a.target];
			function accounted(member: String): Bool {
				return (breaking[LockSites.memberName(member)] ?? []).foreach(o -> keys.contains(occurrenceKey(o.file, o.node)));
			}
			final next: Array<LockAlias> = live.filter(a -> !aliased.contains(a.source) && accounted(a.target) && accounted(a.source));
			if (next.length == live.length) break;
			live = next;
		}
		for (a in live) {
			targets[a.target] = a.source;
			if (!locks.contains(a.source)) locks.push(a.source);
			for (k in a.keys) _explained.push(k);
		}
	}

	/**
	 * The member `o` writes when `o` is the target of `<member> = <parameter>` (`storedParameter`) in its own type's
	 * constructor, the parameter without a default and read nowhere else there (`parameterIndex`), and nothing there
	 * shadowing the member; null for anything else.
	 */
	private function constructorWrite(o: Occurrence): Null<ConstructorWrite> {
		final param: Null<String> = storedParameter(o);
		final at: Null<Span> = o.node.span;
		final name: Null<String> = o.node.name;
		final id: Null<String> = at == null ? null : _graph.functionAt(o.file, at.from);
		final fn: Null<FnNode> = id == null ? null : _graph.node(id);
		final type: Null<String> = fn?.typeName;
		final decl: Null<QueryNode> = fn == null ? null : declarationOf(fn);
		if (param == null || name == null || id == null || type == null || decl == null || fn?.name != _ctorName) return null;
		if (id.indexOf('#') >= 0) return null;
		final index: Int = parameterIndex(decl, param);
		final member: Null<String> = plainField(type, name);
		return index < 0 || member == null || !unshadowed(decl, name) ? null : {
			member: member,
			ctor: id,
			param: index,
			key: occurrenceKey(o.file, o.node)
		};
	}

	/** The name `o` is assigned from when `o`, bare or off `this`, is the target of `<member> = <name>`; null otherwise. */
	private function storedParameter(o: Occurrence): Null<String> {
		final assign: Null<QueryNode> = o.parent;
		if (
			assign == null || assign.kind != _shape.assignKind || assign.children.length != 2 || assign.children[0] != o.node
			|| !_sites.readsOwnMember(o.node)
		)
			return null;
		final value: QueryNode = assign.children[1];
		return value.kind == _shape.identKind ? value.name : null;
	}

	/**
	 * Whether every run of the constructor `ctor` is seen and passes its parameter `index` a member read, collected into
	 * `reads`: each `new` of it (`newHandOff`), and each subclass constructor handing it a parameter of its own through
	 * `super(...)` (`superHandOff`), with no other construction possible (`constructedOnlyThrough`).
	 */
	private function handOffs(ctor: String, index: Int, visited: Array<String>, reads: Array<MemberRead>): Bool {
		final type: Null<String> = _graph.node(ctor)?.typeName;
		if (type == null || visited.contains(ctor) || !constructedOnlyThrough(type, ctor)) return false;
		visited.push(ctor);
		for (e in _graph.inEdges(ctor)) {
			final at: Null<Span> = e.span;
			if (at == null || e.from.indexOf('#') >= 0) return false;
			final seen: Bool = switch e.kind {
				case New: newHandOff(e, at, index, reads);
				case Call: superHandOff(e, at, index, visited, reads);
				case _: false;
			};
			if (!seen) return false;
		}
		return true;
	}

	/** Whether the `new` at `at` passes argument `index` a member read (`memberRead`), which joins `reads`. */
	private function newHandOff(e: CallEdge, at: Span, index: Int, reads: Array<MemberRead>): Bool {
		final typeKinds: Array<String> = _shape.typeAnnotationKinds ?? [];
		final made: Null<QueryNode> = _shape.newExprKind == null ? null : nodeAt(e.file, at, _shape.newExprKind);
		final args: Array<QueryNode> = made == null ? [] : made.children.filter(c -> !typeKinds.contains(c.kind));
		final read: Null<MemberRead> = index < args.length ? memberRead(args[index], e) : null;
		if (read == null) return false;
		reads.push(read);
		return true;
	}

	/**
	 * Whether the call at `at` is a subclass constructor's `super(...)` passing argument `index` a parameter of its own
	 * (`parameterIndex`) that every run of that constructor hands a member read in turn (`handOffs`).
	 */
	private function superHandOff(e: CallEdge, at: Span, index: Int, visited: Array<String>, reads: Array<MemberRead>): Bool {
		final caller: Null<FnNode> = _graph.node(e.from);
		final decl: Null<QueryNode> = caller == null ? null : declarationOf(caller);
		final call: Null<QueryNode> = _shape.callKind == null ? null : nodeAt(e.file, at, _shape.callKind);
		if (caller == null || decl == null || call == null || caller.name != _ctorName) return false;
		final args: Array<QueryNode> = call.children;
		if (args.length <= index + 1 || args[0].kind != _shape.identKind || args[0].name != _shape.superReferenceText) return false;
		final forwarded: Null<String> = args[index + 1].kind == _shape.identKind ? args[index + 1].name : null;
		final from: Int = forwarded == null ? -1 : parameterIndex(decl, forwarded);
		return from >= 0 && handOffs(e.from, from, visited, reads);
	}

	/**
	 * Whether `ctor`, `type`'s constructor, runs only where the graph shows it: `type` declared once, no extern, never
	 * read as a value, and every subtype either inheriting the constructor under the same terms or declaring its own
	 * that the graph sees call `ctor`.
	 */
	private function constructedOnlyThrough(type: String, ctor: String): Bool {
		if (_graph.types.declarationCount(type) != 1 || _graph.types.meta.isExtern(type) || typesAsValues().contains(type)) return false;
		for (sub in _graph.types.subtypesOf(type)) {
			final own: Null<String> = _graph.ownMember(sub, _ctorName);
			if (own == null ? !constructedOnlyThrough(sub, ctor) : !_graph.inEdges(ctor).exists(e -> e.kind == Call && e.from == own))
				return false;
		}
		return true;
	}

	/**
	 * `arg`, a construction argument in the function `e` leaves, as the member it reads — bare or off `this`, a plain
	 * field of that function's type that no parameter or local there shadows; null for any other value.
	 */
	private function memberRead(arg: QueryNode, e: CallEdge): Null<MemberRead> {
		final fn: Null<FnNode> = _graph.node(e.from);
		final type: Null<String> = fn?.typeName;
		final decl: Null<QueryNode> = fn == null ? null : declarationOf(fn);
		final name: Null<String> = arg.name;
		if (type == null || decl == null || name == null || !(arg.kind == _shape.identKind || _sites.isAccess(arg.kind))) return null;
		if (!_sites.readsOwnMember(arg) || !unshadowed(decl, name)) return null;
		final member: Null<String> = plainField(type, name);
		return member == null ? null : { key: occurrenceKey(e.file, arg), member: member };
	}

	/**
	 * The position of `fn`'s parameter `name` when it has no default value, and the body reads it exactly once, bare,
	 * with nothing else there carrying the name; -1 otherwise.
	 */
	private function parameterIndex(fn: QueryNode, name: String): Int {
		final paramKinds: Array<String> = _shape.paramKinds ?? [];
		final typeKinds: Array<String> = _shape.typeAnnotationKinds ?? [];
		final params: Array<QueryNode> = fn.children.filter(c -> paramKinds.contains(c.kind));
		final index: Int = params.findIndex(p -> p.name == name);
		if (index < 0 || !params[index].children.foreach(c -> typeKinds.contains(c.kind))) return -1;
		final named: Array<QueryNode> = [];
		collectNamed(fn, name, named);
		return named.length == 2 && named.count(n -> n.kind == _shape.identKind) == 1 ? index : -1;
	}

	/** Whether every node of `fn` carrying `name` is a bare name or a member access: no parameter or local declares it there. */
	private function unshadowed(fn: QueryNode, name: String): Bool {
		final named: Array<QueryNode> = [];
		collectNamed(fn, name, named);
		return named.foreach(n -> n.kind == _shape.identKind || _sites.isAccess(n.kind));
	}

	/** `Owner.name` for the plain field `name` of `type` — declared on its chain, no property with an accessor; null otherwise. */
	private function plainField(type: String, name: String): Null<String> {
		final owner: Null<String> = _graph.types.declaringTypeOf(type, name);
		return owner == null || !_graph.types.fieldOnChain(type, name) || _graph.types.propertyOnChain(type, name) != null
			? null
			: '$owner.$name';
	}

	/** Every declared type some file of the graph reads as a value: a bare type name anywhere but as a member access's receiver. */
	private function typesAsValues(): Array<String> {
		final known: Null<Array<String>> = _typesAsValues;
		if (known != null) return known;
		final found: Array<String> = [];
		function walk(node: QueryNode, parent: Null<QueryNode>): Void {
			final name: Null<String> = node.name;
			if (
				node.kind == _shape.identKind && name != null && !found.contains(name) && _graph.types.declarationCount(name) > 0
				&& !(parent != null && _sites.isAccess(parent.kind) && parent.children[0] == node)
			)
				found.push(name);
			for (c in node.children) walk(c, node);
		}
		for (file in _files) {
			final tree: Null<QueryNode> = _graph.treeOf(file);
			if (tree != null) walk(tree, null);
		}
		_typesAsValues = found;
		return found;
	}

	/** The declaration of `fn` in its file's tree, found by its exact span; null when the graph holds none. */
	private function declarationOf(fn: FnNode): Null<QueryNode> {
		final span: Null<Span> = fn.span;
		return span == null ? null : nodeAt(fn.file, span, null);
	}

	/** The outermost node of `file`'s tree spanning exactly `span` — of `kind` when one is given; null when there is none. */
	private function nodeAt(file: String, span: Span, kind: Null<String>): Null<QueryNode> {
		var node: Null<QueryNode> = _graph.treeOf(file);
		while (node != null) {
			final at: Null<Span> = node.span;
			if (at != null && at.from == span.from && at.to == span.to && (kind == null || node.kind == kind)) return node;
			node = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
		}
		return null;
	}

	/** `<file>:<start>:<name>` of the occurrence `node`. */
	private static inline function occurrenceKey(file: String, node: QueryNode): String {
		return '$file:${node.span?.from}:${node.name}';
	}

	/** Adds every node of `node`'s subtree carrying `name` to `into`, `node` itself included. */
	private static function collectNamed(node: QueryNode, name: String, into: Array<QueryNode>): Void {
		if (node.name == name) into.push(node);
		for (c in node.children) collectNamed(c, name, into);
	}

}
