package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.ReachHazards;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The calls of the run that run NATIVE code the project itself declares — code the target supplies, which no analysis
 * can read — so `thread-safety` counts each as blocking until the project's `nonBlocking` says otherwise: an unknown
 * native blocks (a positive whitelist). Read off the run's own source only: a library's externs and natives are not
 * the project's (the runtime's blocking calls are `ExecutionShape.blockingLibraryCalls`); a call of one stays a call
 * of library code.
 *
 * Five shapes, each named by the grammar (`ExecutionShape`): a body-less member of an extern type the run declares,
 * its constructor included; a member the run annotates with a `nativeCodeMetaNames` entry, whatever its body (`@:native`
 * stands for the symbol it names); a call of a member whose initializer makes a `nativeLoaderCalls` call, or of a member
 * read off one (`prim.call(…)`); a call of a `targetCodeNameAffix` name (`untyped __cpp__(…)`) or of a member read off
 * one (`untyped __global__.f(…)`); and a `nativeCodeCalls` call (`cpp.Syntax.code`). The third and fourth have no node
 * of their own: each such site gains an edge into a node standing for the native — `untyped.__cpp__`, `__global__.f`,
 * `Owner.member` — and keeps the unresolved record it had.
 */
@:nullSafety(Strict)
final class ProjectNatives {

	/** The type of the node a call of a bare target-code name (`__cpp__`) stands for: the code under `untyped`. */
	public static inline final TARGET_CODE_TYPE: String = 'untyped';

	/** The graph ids of the natives of the run, the nodes made for their call sites included. */
	public final ids: Array<String> = [];

	/** The member names whose initializer makes a native loader call -> the types declaring one of that name. */
	private final _loaded: Map<String, Array<String>> = [];

	/** `<file>:<offset>:<target>` of each edge made for a site, so a site met twice gains one. */
	private final _made: Array<String> = [];

	private final _graph: CallGraph;
	private final _shape: RefShape;

	public function new(graph: CallGraph, plugin: GrammarPlugin) {
		_graph = graph;
		_shape = plugin.refShape();
		final execution: Null<ExecutionShape> = _shape.execution;
		if (execution == null) return;
		final metaNames: Array<String> = execution.nativeCodeMetaNames ?? [];
		// a member's annotations sit among its modifiers, in whatever order they are written
		final leadKinds: Array<String> = (_shape.modifierKinds ?? []).concat(plugin.metaShape().metaKinds);
		for (id => node in graph.nodes) if (declaredNative(node, metaNames, leadKinds)) push(id);
		for (p in execution.nativeCodeCalls ?? []) for (id in graph.matchIds(p)) if (graph.node(id)?.isExternal == true) push(id);
		final loaders: Array<String> = [for (p in execution.nativeLoaderCalls ?? []) ReachHazards.lastSegments(p, 2)];
		if (loaders.length > 0) for (held in graph.heldFiles()) collectLoaded(held.tree, null, loaders);
		final affix: Null<String> = execution.targetCodeNameAffix;
		for (u in graph.unresolved) siteNative(u.file, u.span, u.from, affix, u.spliced);
		// a loaded function called through a member of the value the loader hands back (`cpp.Callable.call`)
		if (_loaded.keys().hasNext())
			for (e in graph.edges.copy())
				if (e.kind == Call && graph.node(e.to)?.isExternal == true) siteNative(e.file, e.span, e.from, null, e.spliced);
	}

	private inline function push(id: String): Void {
		if (!ids.contains(id)) ids.push(id);
	}

	/**
	 * Whether the node `node` is a function the run declares that runs target code: a body-less member of an extern type,
	 * or one carrying a `metaNames` annotation on some declaration.
	 */
	private function declaredNative(node: FnNode, metaNames: Array<String>, leadKinds: Array<String>): Bool {
		final type: Null<String> = node.typeName;
		if (node.isExternal || type == null || node.id.indexOf('#') >= 0) return false;
		if (node.isBodyless && _graph.types.meta.isExtern(type)) return true;
		if (metaNames.length == 0) return false;
		for (d in _graph.declarationsOf(node.id)) {
			final tree: Null<QueryNode> = _graph.treeOf(d.file);
			final leading: Null<Array<QueryNode>> = tree == null ? null : MemberKinds.precedingAt(tree, d.span, leadKinds);
			if (leading != null && leading.exists(m -> metaNames.contains(m.name ?? ''))) return true;
		}
		return false;
	}

	/** Records, under `node` of a type `type`, every member whose initializer makes one of the `loaders` calls. */
	private function collectLoaded(node: QueryNode, type: Null<String>, loaders: Array<String>): Void {
		final declared: Null<String> = RefactorSupport.typeDeclOf(node)?.name;
		final owner: Null<String> = declared ?? type;
		final name: Null<String> = node.name;
		if (owner != null && name != null && (_shape.fieldDeclKinds ?? []).contains(node.kind) && makesLoaderCall(node, loaders)) {
			final owners: Array<String> = _loaded[name] ?? [];
			if (!owners.contains(owner)) owners.push(owner);
			_loaded[name] = owners;
		}
		for (c in node.children) collectLoaded(c, owner, loaders);
	}

	/** Whether `node`'s subtree makes a call whose callee path ends in one of `loaders`. */
	private function makesLoaderCall(node: QueryNode, loaders: Array<String>): Bool {
		if (node.kind == _shape.callKind && node.children.length > 0) {
			final path: Null<Array<String>> = calleePath(node.children[0]);
			if (path != null && loaders.contains(ReachHazards.lastSegments(path.join('.'), 2))) return true;
		}
		return node.children.exists(c -> makesLoaderCall(c, loaders));
	}

	/**
	 * Gives the call site at `span` of `file`, in the function `from`, an edge into the native it runs, when its callee
	 * names one: a target-code name spelled with `affix` (bare, or as the receiver of the member called), or a member a
	 * loader call initialised (called, or the receiver of the member called).
	 */
	private function siteNative(file: String, span: Null<Span>, from: String, affix: Null<String>, spliced: Null<SplicedSite>): Void {
		if (span == null) return;
		final tree: Null<QueryNode> = _graph.treeOf(file);
		final call: Null<QueryNode> = tree == null ? null : callAt(tree, span);
		if (call == null) return;
		final path: Null<Array<String>> = calleePath(call.children[0]);
		if (path == null) return;
		final targets: Array<String> = [];
		final head: String = path[0];
		if (affix != null && head.length > affix.length * 2 && head.startsWith(affix) && head.endsWith(affix))
			targets.push(path.length == 1 ? _graph.externalNode(TARGET_CODE_TYPE, head) : _graph.externalNode(head, path[path.length - 1]));
		for (i in 0...path.length) {
			final owners: Null<Array<String>> = _loaded[path[i]];
			// the loaded member itself, or the member called on its value: a deeper path reads a field of what it returns
			if (owners != null && i >= path.length - 2) for (o in owners) targets.push(_graph.externalNode(o, path[i]));
		}
		for (target in targets) {
			final key: String = '$file:${span.from}:$target';
			if (_made.contains(key)) continue;
			_made.push(key);
			_graph.deriveEdge({
				from: from,
				to: target,
				kind: Call,
				via: null,
				file: file,
				span: span,
				dispatchType: null,
				receiverField: null,
				spliced: spliced
			});
			push(target);
		}
	}

	/** `node`'s dotted path with grouping parentheses peeled (`NominalTypes.pathOf`); null for any other callee. */
	private function calleePath(node: QueryNode): Null<Array<String>> {
		var at: QueryNode = node;
		while (at.kind == _shape.parenKind && at.children.length == 1) at = at.children[0];
		return NominalTypes.pathOf(at, _shape.identKind, _shape.fieldAccessKind ?? '');
	}

	/**
	 * The call of `tree` an unresolved site at `span` stands for: the call spanning it, or the call whose callee does —
	 * the graph records a bare callee it cannot bind at the callee's own span. Null when neither is there.
	 */
	private function callAt(tree: QueryNode, span: Span): Null<QueryNode> {
		var parent: Null<QueryNode> = null;
		var node: Null<QueryNode> = tree;
		while (node != null) {
			final at: Null<Span> = node.span;
			if (at != null && at.from == span.from && at.to == span.to) {
				return if (node.kind == _shape.callKind && node.children.length > 0)
					node
				else if (parent != null && parent.kind == _shape.callKind && parent.children[0] == node)
					parent
				else
					null;
			}
			parent = node;
			node = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
		}
		return null;
	}

}
