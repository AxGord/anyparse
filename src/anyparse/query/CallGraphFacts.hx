package anyparse.query;

import anyparse.query.CallGraph.CallEdge;
import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.CallGraph.FnDeclaration;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.CallGraph.SplicedSite;
import anyparse.query.CallGraph.UnresolvedReason;
import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FieldFact;
import anyparse.query.CompilerFacts.NewFact;
import anyparse.query.CompilerFacts.SpliceFact;
import anyparse.query.CompilerFacts.TypeFact;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * What a FACETED function node (`FactsView.bodyFacts`) contributes to a `CallGraph`
 * beside the edges its syntax records — or, when the facts are the truth (`FactsView.truth`), in place
 * of those at a site the facts type (`holdsBack`) — and in place of its syntax's unresolved sites:
 * an edge per call, construction, method read as a value and nested function the compiler typed — each instance call
 * with its override edges, over the typed subtypes and the ones the graph holds alike — an unresolved site per call
 * through a value, a structure, a dynamic receiver or a native identifier, and an unresolved access per property or
 * method named off a structure or a dynamic receiver. A target is named in the graph's terms (`FactsView.graphType`),
 * a nested or local function by the node declared where the compiler typed it. A fact an inlined body spliced in sits at its
 * callee's range, maybe in another file: its edge, unresolved site or access has no site in the node's file
 * (`siteOf`), which no dead branch of the file drops, and says where it runs instead (`SplicedSite`, `filed`): at the sites
 * of the inlined calls whose method declares it, which a range question meeting one takes (`MemberReach.splicedAt`), or
 * anywhere in the node when no such method does. What a method that runs no project code spliced in is not filed
 * (`FactsView.harmlessSplice`): the `inlined` call of it answers for all it does. A function nested in a spliced
 * body is the node the graph declares in the callee's file. Under the truth, a method a build macro made — placed
 * outside its type's file, or where no declaration of the text is — is a node too, read by its id alone (`adopt`).
 */
@:access(anyparse.query.CallGraph)
@:nullSafety(Strict)
final class CallGraphFacts {

	/** The prefix the compiler gives a native identifier (`` `trace ``), which the syntax spells without it. */
	private static inline final NATIVE_PREFIX: String = '`';

	/** The access of a call of a method the compiler spliced in (`CompilerFacts.CallFact`). */
	private static inline final INLINED: String = 'inlined';

	/** The fact kind of a method's body (`TypedFactsProbe`): the one kind a build macro's own method is taken in as. */
	private static inline final METHOD_KIND: String = 'method';

	/** The field kind of a macro function (`TypeFact.fields`): its body runs while compiling, in no program. */
	private static inline final MACRO_FIELD: String = 'macro';

	/** The field kind of a method the program may reassign (`TypeFact.fields`). */
	private static inline final DYNAMIC_FIELD: String = 'dynamic';

	/** The view over the table the graph reads. */
	public final view: FactsView;

	/**
	 * Node id -> the facts that replaced its syntax: its edges, unresolved sites and accesses come from them, every other
	 * node's from its syntax.
	 */
	public final faceted: Map<String, Array<FactNode>> = [];

	/**
	 * The faceted nodes of the file whose edges the graph is collecting: their syntax records its
	 * edges, which the facts only add to — under the truth, only those at a site the facts do not
	 * type (`holdsBack`) — but none of its unresolved sites and accesses, which the facts type.
	 */
	public var muted(default, null): Map<String, Bool> = [];

	/**
	 * Node id -> the body a build macro made for it (`adopt`), which the facts describe and no text holds: it is read by
	 * that id alone, never by a range of its file. It is faceted too (`faceted`).
	 */
	public final adopted: Map<String, FactNode> = [];

	/** The edges the syntax of a muted node recorded while the facts are the truth, until `recordMuted` sorts them. */
	private final _heldBack: Array<CallEdge> = [];

	public function new(view: FactsView) {
		this.view = view;
	}

	/**
	 * The facts of each function node `file` declares that replace its syntax (`FactsView.bodyFacts`), which are muted
	 * until `recordMuted`: under the truth only, those of a node the graph folded several declarations into, in this
	 * file or another (`CallGraph.declarationsOf`), or of a type declared more than once, and then only when every
	 * declaration is the one type the builds typed (`FactsView.soleType`).
	 */
	public function mute(g: CallGraph, file: String): Map<String, Array<FactNode>> {
		final out: Map<String, Array<FactNode>> = [];
		for (n in g._fileNodes[CallGraphNames.normalizePath(file)] ?? []) if (!n.isExternal && !n.isBodyless) {
			final found: Null<Array<FactNode>> = view.bodyFacts(g, n, g.declarationsOf(n.id).length);
			if (found != null) out[n.id] = found;
		}
		muted = [for (id in out.keys()) id => true];
		return out;
	}

	/**
	 * Unmute, and record the facts `found` of each node `mute` muted in their syntax's place — and of the syntax's edges
	 * held back (`holdsBack`), those at a site the facts do not type.
	 */
	public function recordMuted(g: CallGraph, found: Map<String, Array<FactNode>>): Void {
		muted = [];
		final typed: Map<String, Array<String>> = [];
		for (id => facts in found) {
			final n: Null<FnNode> = g.nodes[id];
			if (n == null) continue;
			faceted[id] = facts;
			typed[id] = typedSites(facts, view);
			record(g, n, facts, view);
		}
		for (e in _heldBack) {
			final at: Null<Span> = e.span;
			if (at == null || !(typed[e.from] ?? []).contains(siteKey(at))) g.indexEdge(e);
		}
		_heldBack.resize(0);
	}

	/**
	 * Whether the syntax's `edge` waits for `recordMuted` instead of joining the graph: when the facts are the truth
	 * (`FactsView.truth`), an edge a muted node's syntax records at a site its facts type is the syntax's reading of a
	 * site the compiler resolved in every build there is, and is dropped. Lexical containment is no reading of a site.
	 */
	public function holdsBack(edge: CallEdge): Bool {
		if (!view.truth || edge.kind == Contains || !muted.exists(edge.from)) return false;
		_heldBack.push(edge);
		return true;
	}

	/**
	 * Under the truth (`FactsView.truth`), take into the graph every method a build macro made for a type `file` declares:
	 * one whose compiled body the macro placed outside that file (`FactNode.generated`), or that no declaration of the text
	 * holds (`CallGraph.adoptNode`). Neither has a range of the file to be found by: its body is read by its id (`adopted`)
	 * and recorded from its facts once every file's nodes exist (`recordAdopted`), so what it runs and what it touches are
	 * seen. Such a type's text is not its code (`FactsProvenance.typeIsItsText`), so the walk answers Unknown wherever it
	 * enters code of it; what the facts show it doing is still found. A type named twice, and one no build macro ran over,
	 * takes nothing in. Answers the ids taken in.
	 */
	public function adopt(g: CallGraph, file: String): Array<String> {
		if (!view.truth) return [];
		final key: String = view.table.keyOf(file);
		final out: Array<String> = [];
		for (t in view.indexedFile(key)?.types ?? []) {
			if (g.types.declarationCount(t.name) != 1) continue;
			for (id in view.bySimpleName()[t.name] ?? []) adoptType(g, file, key, t.name, id, out);
		}
		return out;
	}

	/** Record the body of each method `adopt` took in (`ids`) as a faceted node's facts (`record`). */
	public function recordAdopted(g: CallGraph, ids: Array<String>): Void {
		for (id in ids) {
			final node: Null<FnNode> = g.nodes[id];
			final found: Null<FactNode> = adopted[id];
			if (node == null || found == null) continue;
			final bodies: Array<FactNode> = [found];
			faceted[id] = bodies;
			record(g, node, bodies, view);
		}
	}

	/** Forget the text of `file`, which left the graph, and the `removed` nodes it declared. */
	public function forget(file: String, removed: Map<String, Bool>): Void {
		for (id in removed.keys()) {
			faceted.remove(id);
			adopted.remove(id);
		}
		view.forget(file);
	}

	/**
	 * Record the facts of the faceted `node` into `g`. `deferred` facts belong to a function the compiler made inside
	 * `node` (a `.bind` closure) that the graph holds no node for: what it runs, it runs whenever the closure value is
	 * called, so each invocation is a `Ref` from `node`, as a method handed on as a value is.
	 */
	private static function record(g: CallGraph, node: FnNode, facts: Array<FactNode>, view: FactsView, deferred: Bool = false): Void {
		for (n in facts) {
			for (c in n.calls) {
				final own: Null<FactPos> = c.site;
				final inlined: Null<Array<Span>> = c.access != INLINED ? null : own == null ? [] : [own.span];
				filed(g, node, n, c.at, view, inlined, span -> call(g, node, c, span, view, deferred));
			}
			for (x in n.news) filed(g, node, n, x.at, view, null, span -> construction(g, node, x, span, view, deferred));
			for (f in n.fields) filed(g, node, n, f.at, view, null, span -> field(g, node, f, span, view));
			for (id in n.fns) nested(g, node, n, id, view);
		}
	}

	/**
	 * Record through `add` the fact of `node`'s body `n` at `at`, handed its site in `node`'s file (`siteOf`). What `add`
	 * files for a fact a body spliced in carries where that runs (`splicedSite`) — or is not filed at all when the method
	 * that spliced it in runs no project code (`FactsView.harmlessSplice`): the `inlined` call of the method answers for all
	 * it does. That call itself (`inlined`: its own site, empty when the facts record none) runs where it was called.
	 */
	private static function filed(
		g: CallGraph, node: FnNode, n: FactNode, at: FactPos, view: FactsView, inlined: Null<Array<Span>>, add: Null<Span> -> Void
	): Void {
		final span: Null<Span> = siteOf(node, n, at, view);
		if (span != null) {
			add(span);
			return;
		}
		final splice: Null<SpliceFact> = CompilerFacts.spliceOf(n, at);
		if (inlined == null && splice != null && view.harmlessSplice(g, splice.callee)) return;
		final edges: Int = g.edges.length;
		final unresolved: Int = g.unresolved.length;
		final access: Int = g.unresolvedAccess.length;
		add(null);
		final where: SplicedSite = inlined == null
			? splicedSite(g, at, splice, view)
			: { sites: inlined.length == 0 ? null : inlined, origin: null };
		for (i in edges ... g.edges.length) g.edges[i].spliced = where;
		for (i in unresolved ... g.unresolved.length) g.unresolved[i].spliced = where;
		for (i in access ... g.unresolvedAccess.length) g.unresolvedAccess[i].spliced = where;
	}

	/**
	 * Where a fact at `at` that `splice` brought into a body runs: at a site of the splice, written in the graph node of its
	 * method when the graph names one. No splice brought one the compiler put where no method is declared: anywhere.
	 */
	private static function splicedSite(g: CallGraph, at: FactPos, splice: Null<SpliceFact>, view: FactsView): SplicedSite {
		if (splice == null) return { sites: null, origin: null };
		final owner: String = ownerOf(splice.callee);
		final written: Null<String> = g.memberOnChain(view.graphType(owner), splice.callee.substr(owner.length + 1));
		return { sites: splice.sites, origin: written == null ? null : { node: written, file: at.file, span: at.span } };
	}

	/** The call `c` of `node`'s facts, at `span` of `node`'s file, or anywhere in `node` when null (`siteOf`). */
	private static function call(g: CallGraph, node: FnNode, c: CallFact, span: Null<Span>, view: FactsView, deferred: Bool): Void {
		final run: EdgeKind = deferred ? Ref : Call;
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
				declaredCall(g, node, c, target, span, view, deferred, unresolved);
			case _:
				unresolved(Unseen('a call the facts record as `${c.access}`'));
		}
	}

	/** A `super(…)` call of the constructor of `type`: its edge and the run of the initializers it executes. */
	private static function superCall(g: CallGraph, node: FnNode, type: String, span: Null<Span>, run: EdgeKind): Void {
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
		g: CallGraph, node: FnNode, c: CallFact, target: String, span: Null<Span>, view: FactsView, deferred: Bool,
		unresolved: UnresolvedReason -> Void
	): Void {
		// a conversion call is the string-conversion site of its argument, not library code
		if (view.convertsToString(target)) return;
		final owner: String = ownerOf(target);
		// an abstract's constructor is `_new` in its implementation class
		final name: String = view.graphMember(owner, target.substr(target.lastIndexOf('.') + 1));
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
	private static function construction(g: CallGraph, node: FnNode, x: NewFact, span: Null<Span>, view: FactsView, deferred: Bool): Void {
		final run: EdgeKind = deferred ? Ref : New;
		final type: String = view.graphType(x.type);
		final ctor: Null<String> = g.constructorTarget(type, g._shape.constructorName ?? 'new');
		if (ctor != null) g.addEdge(node.id, ctor, run, null, node.file, span);
		g._wiring.record({
			typeName: type,
			from: node.id,
			kind: run,
			file: node.file,
			span: span,
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
	private static function field(g: CallGraph, node: FnNode, f: FieldFact, span: Null<Span>, view: FactsView): Void {
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
			span: span,
			from: node.id,
			member: f.field,
			write: f.write,
			dynamicReceiver: f.access == 'FDynamic'
		});
		if (owner == null || !view.isMethod(owner, f.field)) return;
		final type: String = view.graphType(owner);
		final id: String = g.memberOnChain(type, f.field) ?? g.externalNode(g.types.declaringTypeOf(type, f.field) ?? type, f.field);
		final dispatch: Null<String> = f.access == 'FClosure' ? dispatchType(f.receiver, owner, view) : null;
		g.addEdge(node.id, id, Ref, null, node.file, span, dispatch == null ? null : view.graphType(dispatch));
		if (dispatch != null) virtualEdges(g, node, dispatch, f.field, span, Ref, view);
	}

	/**
	 * A function nested in `node`'s body `n`: a value from the moment it is made, whoever runs it later — a `Ref` to the
	 * node the graph declares where it starts, which for one spliced in with an inlined body lies in its callee (`siteOf`).
	 * One the compiler made (a `.bind` closure) has no such node: its facts are `node`'s own, deferred (`record`). One a
	 * macro placed is code nothing here can follow.
	 */
	private static function nested(g: CallGraph, node: FnNode, n: FactNode, id: String, view: FactsView): Void {
		final fact: Null<FactNode> = view.table.node(id);
		final target: Null<String> = fact == null || fact.generated ? null : graphNodeOf(g, node, id, view);
		if (fact != null && target != null)
			filed(
				g, node, n, fact.at, view, null,
				span -> g.addEdge(node.id, target, Ref, null, node.file, span == null ? null : g.declarationAt(node.file, span.from)?.span)
			)
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
		g: CallGraph, node: FnNode, dispatch: String, name: String, span: Null<Span>, kind: EdgeKind, view: FactsView
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
	 * text, or of the callee an inlined body spliced it in from — or null when no node of the graph starts where it does.
	 */
	public static function graphNodeOf(g: CallGraph, node: FnNode, id: String, view: FactsView): Null<String> {
		final fact: Null<FactNode> = view.table.node(id);
		final file: Null<String> = fact == null || fact.generated ? null : graphFile(g, node, fact.at.file, view);
		if (fact == null || file == null) return null;
		final at: Span = fact.at.span;
		// a node's span may run on over trailing trivia the compiler's range stops before: the two share their start — the
		// start of the declaration holding it, which for a node folding several may be another than its first
		final found: Null<FnDeclaration> = g.declarationAt(file, at.from);
		return found != null && found.span.from == at.from ? found.id : null;
	}

	/** The file of the graph whose table key is `key` — `node`'s own, or another the graph holds — or null for none. */
	private static function graphFile(g: CallGraph, node: FnNode, key: String, view: FactsView): Null<String> {
		if (view.table.keyOf(node.file) == key) return node.file;
		for (file in g._entries.keys()) if (view.table.keyOf(file) == key) return file;
		return null;
	}

	/**
	 * Where in `node`'s file a fact of its body `n` at `at` sits: its range when `n` places it there (`CompilerFacts.placed`),
	 * else null — a fact an inlined body spliced in sits at its callee, maybe in another file, and runs at a site of `node`
	 * no range names. Such an edge, unresolved site or access belongs to the whole of `node`: no range of its file may
	 * claim it, or drop it (`MemberReach.isLive`).
	 */
	private static function siteOf(node: FnNode, n: FactNode, at: FactPos, view: FactsView): Null<Span> {
		return at.file == view.table.keyOf(node.file) && CompilerFacts.placed(n, at) ? at.span : null;
	}

	/**
	 * The sites the compiler typed in the bodies `facts` (`siteKey`): each call, construction and field access, and each
	 * function nested there. A site the facts place elsewhere, or not at all, is none of them — nor is one an inlined body
	 * spliced in, which sits at its callee's range (`CompilerFacts.placed`).
	 */
	private static function typedSites(facts: Array<FactNode>, view: FactsView): Array<String> {
		final out: Array<String> = [];
		for (n in facts) {
			for (c in n.calls) if (CompilerFacts.placed(n, c.at)) out.push(siteKey(c.at.span));
			for (x in n.news) if (CompilerFacts.placed(n, x.at)) out.push(siteKey(x.at.span));
			for (f in n.fields) if (CompilerFacts.placed(n, f.at)) out.push(siteKey(f.at.span));
			for (id in n.fns) {
				final nested: Null<FactNode> = view.table.node(id);
				if (nested != null && CompilerFacts.placed(n, nested.at)) out.push(siteKey(nested.at.span));
			}
		}
		return out;
	}

	/** A site by its exact range: a syntax edge is dropped only at a range the compiler typed itself. */
	private static inline function siteKey(span: Span): String {
		return '${span.from}:${span.to}';
	}

	/** The declaring type of a call target `pack.Type.field`. */
	private static function ownerOf(target: String): String {
		final dot: Int = target.lastIndexOf('.');
		return dot < 0 ? target : target.substr(0, dot);
	}

	/**
	 * Take in (`adopt`) the methods a build macro made of the typed type `id`, which the graph calls `type`, declared in
	 * `file` (keyed `key`), adding their ids to `out`: none unless a build macro ran over it and it was typed from that file.
	 */
	private function adoptType(g: CallGraph, file: String, key: String, type: String, id: String, out: Array<String>): Void {
		final table: CompilerFacts = view.table;
		final typed: Null<TypeFact> = table.type(id);
		if (typed == null || typed.builds.length == 0 || table.typePosition(id)?.file != key) return;
		for (nodeId in table.nodeIdsOf(id)) {
			final n: Null<FactNode> = table.node(nodeId);
			final field: String = nodeId.substr(nodeId.lastIndexOf('.') + 1);
			final kinds: Array<String> = typed.fields.find(f -> f.name == field)?.kinds ?? [];
			// a macro function in every build runs in no program; one a build may replace is a value there
			if (n == null || n.kind != METHOD_KIND || n.overloadIndex > 0 || (kinds.length > 0 && kinds.foreach(k -> k == MACRO_FIELD)))
				continue;
			final name: String = view.graphMember(id, field);
			final graphId: String = '$type.$name';
			final declared: Bool = g.nodes[graphId]?.isExternal == false;
			if (declared && !n.generated) continue;
			if (!declared) g.adoptNode(graphId, file, type, name, kinds.contains(DYNAMIC_FIELD));
			adopted[graphId] = n;
			out.push(graphId);
		}
	}

}
