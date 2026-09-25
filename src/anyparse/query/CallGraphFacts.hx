package anyparse.query;

import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.CallGraph.UnresolvedReason;
import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FieldFact;
import anyparse.query.CompilerFacts.NewFact;
import anyparse.query.CompilerFacts.TypeFact;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.runtime.Span;

using StringTools;

/**
 * What a FACETED function node (`FactsView.bodyFacts`) contributes to a `CallGraph`
 * beside the edges its syntax records, and in place of its syntax's unresolved sites:
 * an edge per call, construction, method read as a value and nested function the compiler typed — each instance call
 * with its override edges, over the typed subtypes and the ones the graph holds alike — an unresolved site per call
 * through a value, a structure, a dynamic receiver or a native identifier, and an unresolved access per property or
 * method named off a structure or a dynamic receiver. A target is named in the graph's terms (`FactsView.graphType`),
 * a nested or local function by the node declared where the compiler typed it.
 */
@:access(anyparse.query.CallGraph)
@:nullSafety(Strict)
final class CallGraphFacts {

	/** The prefix the compiler gives a native identifier (`` `trace ``), which the syntax spells without it. */
	private static inline final NATIVE_PREFIX: String = '`';

	/** The view over the table the graph reads. */
	public final view: FactsView;

	/**
	 * Node id -> the facts that replaced its syntax: its edges, unresolved sites and accesses come from them, every other
	 * node's from its syntax.
	 */
	public final faceted: Map<String, Array<FactNode>> = [];

	/**
	 * The faceted nodes of the file whose edges the graph is collecting: their syntax records its edges, which the facts
	 * only add to, but none of its unresolved sites and accesses, which the facts type.
	 */
	public var muted(default, null): Map<String, Bool> = [];

	public function new(view: FactsView) {
		this.view = view;
	}

	/**
	 * The facts of each function node `file` declares that replace its syntax (`FactsView.bodyFacts`), which are muted
	 * until `recordMuted`: none for a node the graph folded several declarations into (`fnBySpanFrom` names one id at
	 * several starts), or of a type declared more than once.
	 */
	public function mute(g: CallGraph, file: String, fnBySpanFrom: Map<Int, String>): Map<String, Array<FactNode>> {
		final out: Map<String, Array<FactNode>> = [];
		final declarations: Map<String, Int> = [];
		for (id in fnBySpanFrom) declarations[id] = (declarations[id] ?? 0) + 1;
		for (n in g._fileNodes[CallGraphNames.normalizePath(file)] ?? []) {
			final type: Null<String> = n.typeName;
			if (n.isExternal || n.isBodyless || (type != null && g.types.declarationCount(type) > 1)) continue;
			final found: Null<Array<FactNode>> = view.bodyFacts(g, n, declarations[n.id] ?? 0);
			if (found != null) out[n.id] = found;
		}
		muted = [for (id in out.keys()) id => true];
		return out;
	}

	/** Unmute, and record the facts `found` of each node `mute` muted in their syntax's place. */
	public function recordMuted(g: CallGraph, found: Map<String, Array<FactNode>>): Void {
		muted = [];
		for (id => facts in found) {
			final n: Null<FnNode> = g.nodes[id];
			if (n == null) continue;
			faceted[id] = facts;
			record(g, n, facts, view);
		}
	}

	/** Forget the text of `file`, which left the graph, and the `removed` nodes it declared. */
	public function forget(file: String, removed: Map<String, Bool>): Void {
		for (id in removed.keys()) faceted.remove(id);
		view.forget(file);
	}

	/**
	 * Record the facts of the faceted `node` into `g`. `deferred` facts belong to a function the compiler made inside
	 * `node` (a `.bind` closure) that the graph holds no node for: what it runs, it runs whenever the closure value is
	 * called, so each invocation is a `Ref` from `node`, as a method handed on as a value is.
	 */
	private static function record(g: CallGraph, node: FnNode, facts: Array<FactNode>, view: FactsView, deferred: Bool = false): Void {
		for (n in facts) {
			for (c in n.calls) call(g, node, c, view, deferred);
			for (x in n.news) construction(g, node, x, view, deferred);
			for (f in n.fields) field(g, node, f, view);
			for (id in n.fns) nested(g, node, id, view);
		}
	}

	private static function call(g: CallGraph, node: FnNode, c: CallFact, view: FactsView, deferred: Bool): Void {
		final run: EdgeKind = deferred ? Ref : Call;
		final span: Span = c.at.span;
		final target: Null<String> = c.target;
		function unresolved(reason: UnresolvedReason): Void {
			g.unresolved.push({
				file: node.file,
				span: span,
				from: node.id,
				reason: reason
			});
		}
		switch c.access {
			case 'FEnum':
			case 'value':
				unresolved(FunctionValue('a value of type ${c.receiver ?? '?'}'));
			case 'FAnon':
				unresolved(UnresolvedReceiver(target ?? ''));
			case 'FDynamic':
				unresolved(DynamicReceiver(target ?? ''));
			case 'ident':
				unresolved(UnboundName(target == null ? '' : target.replace(NATIVE_PREFIX, '')));
			case 'local':
				final id: Null<String> = target == null ? null : graphNodeOf(g, node, target, view);
				if (id == null)
					unresolved(Unseen('the local function `${target ?? '?'}`'))
				else
					g.addEdge(node.id, id, run, null, node.file, span);
			case 'super':
				superCall(g, node, view.graphType(ownerOf(target ?? '')), span, run);
			case 'FInstance', 'FStatic', 'FClosure', 'inlined', 'fieldValue' if (target != null):
				declaredCall(g, node, c, target, view, deferred, unresolved);
			case _:
				unresolved(Unseen('a call the facts record as `${c.access}`'));
		}
	}

	/** A `super(…)` call of the constructor of `type`: its edge and the run of the initializers it executes. */
	private static function superCall(g: CallGraph, node: FnNode, type: String, span: Span, run: EdgeKind): Void {
		final ctor: Null<String> = g.constructorTarget(type, g._shape.constructorName ?? 'new');
		g._wiring.record({
			typeName: type,
			from: node.id,
			kind: run,
			file: node.file,
			span: span,
			chainGrew: false,
			target: ctor
		});
		if (ctor != null) g.addEdge(node.id, ctor, run, null, node.file, span);
	}

	/**
	 * A call of the field `target` a type declares: its edge, the override edges of an instance call, and the value
	 * channel of a replaceable field. A string-conversion call is none (`FactsView.sitesIn`).
	 */
	private static function declaredCall(
		g: CallGraph, node: FnNode, c: CallFact, target: String, view: FactsView, deferred: Bool, unresolved: UnresolvedReason -> Void
	): Void {
		// a conversion call is the string-conversion site of its argument, not library code
		if (view.convertsToString(target)) return;
		final span: Span = c.at.span;
		final owner: String = ownerOf(target);
		final name: String = target.substr(target.lastIndexOf('.') + 1);
		final type: String = view.graphType(owner);
		final id: String = g.memberOnChain(type, name) ?? g.externalNode(g.types.declaringTypeOf(type, name) ?? type, name);
		final field: Bool = c.access == 'fieldValue';
		// the index knows a library member before the graph reads its body
		final known: Null<MemberInfo> = g.types.memberOnChain(type, name);
		final replaceable: Bool = g.nodes[id]?.isDynamic == true || known?.isDynamic == true;
		// a replaceable field runs whatever value it holds: a `dynamic` method's own body is one of them
		if (field) unresolved(FunctionValue(name));
		// a field no declaration read so far says is a `dynamic` method may still be one, whose body the edge reads
		if (field && !replaceable && known != null) return;
		final instance: Bool = c.access == 'FInstance' || c.access == 'FClosure' || field;
		final dispatch: Null<String> = instance ? dispatchType(c.receiver, owner, view) : null;
		g.addEdge(node.id, id, deferred ? Ref : Call, null, node.file, span, dispatch == null ? null : view.graphType(dispatch));
		if (dispatch != null) virtualEdges(g, node, dispatch, name, span, deferred ? Ref : Virtual, view);
		if (!field && replaceable) unresolved(FunctionValue(name));
	}

	/** A `new`: the edge to the constructor it names and the run of the initializers it executes, as `CallGraph` records one. */
	private static function construction(g: CallGraph, node: FnNode, x: NewFact, view: FactsView, deferred: Bool): Void {
		final run: EdgeKind = deferred ? Ref : New;
		final type: String = view.graphType(x.type);
		final ctor: Null<String> = g.constructorTarget(type, g._shape.constructorName ?? 'new');
		if (ctor != null) g.addEdge(node.id, ctor, run, null, node.file, x.at.span);
		g._wiring.record({
			typeName: type,
			from: node.id,
			kind: run,
			file: node.file,
			span: x.at.span,
			chainGrew: false,
			target: ctor
		});
	}

	/**
	 * A field read or write that is no call. A method read as a value is a `Ref` to it (and its overrides, off an
	 * instance). A name read off a dynamic receiver is an unresolved access when some type declares a property or a
	 * function of that name — an accessor may run there, or the method later as a value — and one read off a typed
	 * structure when the structure's own declaration gives the name an accessor, as `CallGraph` reads a typed receiver.
	 */
	private static function field(g: CallGraph, node: FnNode, f: FieldFact, view: FactsView): Void {
		final owner: Null<String> = f.owner;
		final access: Bool = switch f.access {
			case 'FDynamic':
				g.types.hasPropertyNamed(f.field) || g._byMember.exists(f.field) || g.types.hasFunctionNamed(f.field);
			case 'FAnon':
				final property: Null<{ info: MemberInfo, owner: String }> = g.types.propertyOnChain(view.graphType(f.receiver), f.field);
				property != null && (property.info.hasGetter || property.info.hasSetter);
			case _: false;
		};
		if (access) g.unresolvedAccess.push({
			file: node.file,
			span: f.at.span,
			from: node.id,
			member: f.field,
			write: f.write,
			dynamicReceiver: f.access == 'FDynamic'
		});
		if (owner == null || !view.isMethod(owner, f.field)) return;
		final type: String = view.graphType(owner);
		final id: String = g.memberOnChain(type, f.field) ?? g.externalNode(g.types.declaringTypeOf(type, f.field) ?? type, f.field);
		final dispatch: Null<String> = f.access == 'FClosure' ? dispatchType(f.receiver, owner, view) : null;
		g.addEdge(node.id, id, Ref, null, node.file, f.at.span, dispatch == null ? null : view.graphType(dispatch));
		if (dispatch != null) virtualEdges(g, node, dispatch, f.field, f.at.span, Ref, view);
	}

	/**
	 * A function nested in `node`: a value from the moment it is made, whoever runs it later — a `Ref` to the node the
	 * graph declares where it starts. One the compiler made (a `.bind` closure) has no such node: its facts are
	 * `node`'s own, deferred (`record`). One a macro placed is code nothing here can follow.
	 */
	private static function nested(g: CallGraph, node: FnNode, id: String, view: FactsView): Void {
		final fact: Null<FactNode> = view.table.node(id);
		final target: Null<String> = fact == null || fact.generated ? null : graphNodeOf(g, node, id, view);
		if (target != null)
			g.addEdge(node.id, target, Ref, null, node.file, g.nodes[target]?.span)
		else if (fact != null && !fact.generated)
			record(g, node, [fact], view, true)
		else
			g.unresolved.push({
				file: node.file,
				span: node.span,
				from: node.id,
				reason: Unseen('the nested function `$id`')
			});
	}

	/**
	 * The overrides a dispatch of `name` on a value of the typed type `dispatch` reaches: those of its subtypes the graph
	 * holds and those the facts type.
	 */
	private static function virtualEdges(
		g: CallGraph, node: FnNode, dispatch: String, name: String, span: Span, kind: EdgeKind, view: FactsView
	): Void {
		final type: String = view.graphType(dispatch);
		final targets: Array<String> = g.virtualTargets(type, name);
		for (v in view.overrides(g, dispatch, name)) if (!targets.contains(v)) targets.push(v);
		for (v in targets) g.addEdge(node.id, v, kind, null, node.file, span, type);
	}

	/**
	 * The typed type an instance call dispatches on: the receiver's static class or interface when the facts type one — a
	 * value of it is it or a subtype — else the declaring type.
	 */
	private static function dispatchType(receiver: Null<String>, owner: String, view: FactsView): String {
		final declared: Null<TypeFact> = receiver == null ? null : view.table.type(CompilerFacts.baseId(receiver));
		return declared != null && (declared.kind == 'class' || declared.kind == 'interface') ? declared.id : CompilerFacts.baseId(owner);
	}

	/**
	 * The graph node declared where the compiler typed the function `id` — a local or nested function of `node`'s own
	 * text — or null when no node of the graph starts where it does.
	 */
	private static function graphNodeOf(g: CallGraph, node: FnNode, id: String, view: FactsView): Null<String> {
		final fact: Null<FactNode> = view.table.node(id);
		if (fact == null || fact.generated) return null;
		final at: Span = fact.at.span;
		// a node's span may run on over trailing trivia the compiler's range stops before: the two share their start
		final found: Null<String> = g.functionAt(node.file, at.from);
		return found != null && g.nodes[found]?.span?.from == at.from ? found : null;
	}

	/** The declaring type of a call target `pack.Type.field`. */
	private static function ownerOf(target: String): String {
		final dot: Int = target.lastIndexOf('.');
		return dot < 0 ? target : target.substr(0, dot);
	}

}
