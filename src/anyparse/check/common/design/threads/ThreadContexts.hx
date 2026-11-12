package anyparse.check.common.design.threads;

import anyparse.check.LintConfig.ConfigNote;
import anyparse.check.common.design.ThreadSafety;
import anyparse.check.common.design.threads.LockTaint.ChainLists;
import anyparse.query.CallGraph;
import anyparse.query.MemberKinds;
import anyparse.query.ReachAdmission;

using StringTools;

/**
 * The one answer to "which threads may run each function of the project": the call graph settled into contexts
 * (`ThreadStates`) from every chain's `spawns`, `marshals`, `quietRoots` and `closedWorld`, with the conditions, inert
 * references and outside callers the solve is judged by. `ThreadSafety.run` and every rule asking whether another thread
 * may run a function ask this component.
 *
 * A function stored into a `dynamic` member runs where that member runs (`deriveStoredCalls`): those edges join the graph
 * the contexts are solved over.
 */
@:nullSafety(Strict)
final class ThreadContexts {

	/** Each function's contexts. */
	public final states: ThreadStates;

	public final trees: FunctionTrees;
	public final conditions: EdgeConditions;

	/** Whether the `Ref` edge runs its value from nowhere (`runsNothing`). */
	public final inertRef: (CallEdge) -> Bool;

	/** Whether a function no edge reaches may still run (`mayRunFromOutside`). */
	public final seedable: (String) -> Bool;

	public final unresolvedNames: Array<String>;

	/** The `ChainLists` of every file of the run. */
	public final byFile: Map<String, ChainLists>;

	/** `byFile`: the `ChainLists` of every file of `files` (`ThreadSafety.listsByFile`). */
	public function new(
		graph: CallGraph, plugin: GrammarPlugin, files: Array<{ file: String, source: String }>, resolve: Null<(String) -> LintConfig>,
		byFile: Map<String, ChainLists>
	) {
		this.byFile = byFile;
		final listsOf: (String) -> ChainLists = ThreadSafety.listsOfFile.bind(byFile);
		unresolvedNames = [for (u in graph.unresolved) for (n in ReachAdmission.admittedNames(u)) n];
		final sealedSlots: Array<String> = deriveStoredCalls(graph, unresolvedNames);
		trees = new FunctionTrees(graph, plugin);
		conditions = new EdgeConditions(
			graph, trees, plugin, file -> listsOf(file).mainCheckIds, new DeadCatches(graph, trees, plugin, listsOf).holds
		);
		// a value a constructor only stores runs where the field is called: those calls derived, its `Ref` running nothing
		final stored: StoredValues = new StoredValues(
			graph, trees, plugin, ReflectiveReach.declaredMethodHolders(files, resolve), file -> byFile[file]?.closedWorld == true
		);
		inertRef = runsNothing.bind(graph, sealedSlots, stored, listsOf);
		seedable = mayRunFromOutside.bind(graph, plugin, unresolvedNames, byFile);
		// a quiet root is judged by the chain of the file declaring it
		states = settleContexts(graph, listsOf, [
			for (id => node in graph.nodes) if (byFile[node.file]?.quietIds.contains(id) == true) id
		], conditions, inertRef, seedable);
	}

	/** Whether the function `id` may run on a thread a `spawns` call starts. */
	public function runsBackground(id: Null<String>): Bool {
		return id != null && ((states.contexts[id] ?? 0) & ThreadSafety.CTX_BG) != 0;
	}

	/**
	 * The contexts of the project `files` over `graph` (`ThreadGraph.build`), no library body read: what a rule outside
	 * `thread-safety` asks. The derived stores of `deriveStoredCalls` join `graph`.
	 */
	public static function ofGraph(
		graph: CallGraph, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, resolve: Null<(String) -> LintConfig>,
		notes: Null<Array<ConfigNote>>
	): ThreadContexts {
		final lists: Map<String, ChainLists> = ThreadSafety.listsByFile(
			files, resolve, graph, [], new PositiveSinks(graph, plugin, new ProjectNatives(graph, plugin), null),
			plugin.refShape().accessorMethodPrefixes ?? [], [], notes
		);
		return new ThreadContexts(graph, plugin, files, resolve, lists);
	}

	/**
	 * Whether no supertype of `type` may declare `name` (`MemberLookup.supertypesDeclareNone`, by declaration): every one
	 * the index resolves declares none, and every one it does not is the superclass of a class — whose members the class can
	 * only reach by an `override`, which a sealed member never carries. An interface the index does not hold may declare
	 * anything; a graph with no index proves nothing.
	 */
	private static inline function inheritsNothingNamed(graph: CallGraph, type: String, name: String): Bool {
		return graph.index?.typing.members.supertypesDeclareNone(type, name) == true;
	}

	/**
	 * Whether the `Ref` edge `edge` runs its value from nowhere: a value stored into a member of `sealedSlots`, which
	 * runs where that member runs (`deriveStoredCalls`), one a constructor only stores into a field, which runs where the
	 * field is called (`StoredValues`), one handed to a call that never runs it (`neverInvoked`), or the compiler facts'
	 * record of a value made at a site the syntax already records handing it to a call — the same value at the same span,
	 * said once with its `via` (`ThreadGraph.madeWhereHanded`).
	 */
	private static function runsNothing(
		graph: CallGraph, sealedSlots: Array<String>, stored: StoredValues, listsOf: (String) -> ChainLists, edge: CallEdge
	): Bool {
		return sealedSlots.contains(edge.storedInto ?? '')
			|| stored.stored(edge)
			|| neverInvoked(edge, listsOf(edge.file))
			|| ThreadGraph.madeWhereHanded(graph, edge);
	}

	/**
	 * Whether a function the walk reaches through no edge may still run, ASSUMED on the main thread: any function, unless
	 * its file's chain declares `closedWorld` and nothing outside the run can invoke it (`sealedFromOutside`).
	 */
	private static function mayRunFromOutside(
		graph: CallGraph, plugin: GrammarPlugin, unresolvedNames: Array<String>, byFile: Map<String, ChainLists>, id: String
	): Bool {
		return !(byFile[graph.node(id)?.file ?? '']?.closedWorld == true && sealedFromOutside(graph, plugin, unresolvedNames, id));
	}

	/**
	 * Whether the call the value of the `Ref` edge `edge` is handed to never runs it: one its chain's `neverInvokes`
	 * names — a `Type.member` entry by the graph's target, a bare member name by the name the call is written with,
	 * resolved or not.
	 */
	private static function neverInvoked(edge: CallEdge, lists: ChainLists): Bool {
		final via: String = edge.via ?? '';
		final member: String = edge.viaMember ?? '';
		return lists.neverInvokeIds.contains(via) || lists.neverInvokeNames.contains(member);
	}

	/**
	 * The context a callback `edge` of `graph` registers from `ctx` runs in: a `spawns` target's BG — MAIN at an argument
	 * its object entry names `main` (`ThreadStates.runsOnMain`) —, a `marshals` target's MAIN, any other the registrar's
	 * own — quiet never among them: a callback runs later, from whatever invokes it.
	 */
	private static function callbackContext(graph: CallGraph, edge: CallEdge, lists: ChainLists, ctx: Int): Int {
		final via: Null<String> = edge.via;
		final loud: Int = (
			(ctx & ThreadSafety.CTX_QUIET) != 0 ? ThreadSafety.CTX_MAIN : 0
		) | (ctx & (ThreadSafety.CTX_MAIN | ThreadSafety.CTX_BG));
		return if (ThreadStates.runsOnMain(graph, edge, lists))
			ThreadSafety.CTX_MAIN
		else if (via != null && lists.spawnIds.contains(via))
			ThreadSafety.CTX_BG
		else if (via != null && lists.marshalIds.contains(via))
			ThreadSafety.CTX_MAIN
		else
			loud;
	}

	/**
	 * The contexts (`ThreadStates`) with the `quiet` roots only the main thread never enters loud: a root some invocation
	 * reaches from loud MAIN code is dropped, and the contexts are solved again until none is. A root's registration as a
	 * callback (a `Ref`, as a handler is) does not make it loud: declaring how such a callback runs is what the list is for.
	 */
	private static function settleContexts(
		graph: CallGraph, listsOf: (String) -> ChainLists, quiet: Array<String>, conditions: EdgeConditions, inertRef: (CallEdge) -> Bool,
		seedable: (String) -> Bool
	): ThreadStates {
		var roots: Array<String> = quiet;
		while (true) {
			final states: ThreadStates = new ThreadStates(
				graph, conditions, roots, (e, ctx) -> callbackContext(graph, e, listsOf(e.file), ctx), inertRef, seedable
			);
			final loud: Array<String> = [
				for (q in roots)
					if (graph.inEdges(q).exists(e -> e.kind.isInvocation() && (states.edgeContext(e) & ThreadSafety.CTX_MAIN) != 0)) q
			];
			if (loud.length == 0) return states;
			roots = roots.filter(q -> !loud.contains(q));
		}
	}

	/**
	 * A function value assigned to a `dynamic` method (`CallEdge.storedInto`) runs wherever that member runs: each
	 * invocation of the member, or of an override of it, is a call of the value too, and each read of the member as a
	 * value a reference to it. Those edges join the graph, at the member's own sites. Returns the members whose every
	 * run the graph sees — no call or read of their name it could not resolve — where the assignment itself runs nothing.
	 */
	private static function deriveStoredCalls(graph: CallGraph, unresolvedNames: Array<String>): Array<String> {
		final sealed: Array<String> = [];
		final stores: Array<CallEdge> = [for (e in graph.edges) if (e.kind == Ref && e.storedInto != null) e];
		for (store in stores) {
			final slotId: String = store.storedInto ?? '';
			final slot: Null<FnNode> = graph.node(slotId);
			final name: Null<String> = slot?.name;
			final type: Null<String> = slot?.typeName;
			if (slot == null || name == null || type == null) continue;
			final runs: Array<String> = [slotId].concat(graph.virtualTargets(type, name));
			for (id in runs) for (e in graph.inEdges(id).copy()) if (e.kind != Contains) graph.deriveEdge({
				from: e.from,
				to: store.to,
				kind: e.kind,
				via: e.via,
				file: e.file,
				span: e.span,
				dispatchType: null,
				receiverField: null
			});
			if (!sealed.contains(slotId) && !unresolvedNames.contains(name) && graph.unresolvedAccessesRunning([slot]).length == 0)
				sealed.push(slotId);
		}
		return sealed;
	}

	/**
	 * Whether nothing outside the run's files can invoke `id`, so that under `closedWorld` a function nothing in them
	 * reaches runs on no thread at all: a member method (no lambda, no local function, no constructor, no field
	 * initializer, no `main`) no supertype may declare (`inheritsNothingNamed`), carrying no `override` and no metadata,
	 * whose name no unresolved call or access may mean.
	 */
	private static function sealedFromOutside(graph: CallGraph, plugin: GrammarPlugin, unresolvedNames: Array<String>, id: String): Bool {
		final node: Null<FnNode> = graph.node(id);
		final name: Null<String> = node?.name;
		final type: Null<String> = node?.typeName;
		if (node == null || name == null || type == null || node.isExternal || node.isBodyless || id.indexOf('#') >= 0) return false;
		final shape: RefShape = plugin.refShape();
		if (name == (shape.constructorName ?? 'new') || name == ThreadSafety.ENTRY_POINT || name.startsWith('<')) return false;
		if (graph.ownMember(type, name) != id || !inheritsNothingNamed(graph, type, name)) return false;
		if (unresolvedNames.contains(name) || graph.unresolvedAccessesRunning([node]).length > 0) return false;
		final declarations: Array<FnDeclaration> = graph.declarationsOf(id);
		return declarations.length > 0 && declarations.foreach(d -> plainMember(graph, plugin, d));
	}

	/** Whether the member declared at `d` carries neither `override` nor any metadata. */
	private static function plainMember(graph: CallGraph, plugin: GrammarPlugin, d: FnDeclaration): Bool {
		final tree: Null<QueryNode> = graph.treeOf(d.file);
		if (tree == null) return false;
		final shape: RefShape = plugin.refShape();
		final kinds: Array<String> = (shape.modifierKinds ?? []).concat(plugin.metaShape().metaKinds);
		final leading: Null<Array<QueryNode>> = MemberKinds.precedingAt(tree, d.span, kinds);
		return leading != null
			&& !leading.exists(m -> m.kind == shape.overrideModifierKind || plugin.metaShape().metaKinds.contains(m.kind));
	}

}
