package anyparse.query;

import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * One function-like unit in the graph: a method, a module-level function, a
 * local function, a lambda, or an EXTERNAL member (a call target outside the
 * scanned scope — `Sys.sleep`, an openfl method — that has no body here).
 * External nodes carry a null `span` and an empty `file`. An external node is
 * upgraded in place when `addFiles` later brings in the file that declares it.
 *
 * `isDynamic` marks a method the language lets the program REASSIGN (Haxe
 * `dynamic function`): a call to it runs whatever function value the member
 * holds at that moment, not necessarily this body.
 */
typedef FnNode = {
	var id: String;
	var file: String;
	var typeName: Null<String>;
	var name: Null<String>;
	var span: Null<Span>;
	var isExternal: Bool;
	var isDynamic: Bool;

	/**
	 * True for a declaration with NO body (`RefShape.noBodyKind`): an interface or abstract member, which
	 * only dispatch reaches, or an extern one, whose code lives in the target.
	 */
	var isBodyless: Bool;
}

/**
 * One declaration a graph node stands for. A node folds every declaration of its id into one — a member declared in
 * each branch of a conditional region, an overload, a copy of its type per build — and each of them is code the node
 * runs: its `span` of `file`, the body a reader of the node's text reads beside the node's own `span`.
 */
typedef FnDeclaration = {
	var id: String;
	var file: String;
	var span: Span;
}

/**
 * One directed edge. `via` is set on `Ref` edges only: the id of the call
 * TARGET that received the callback (`Worker.spawn` for a lambda passed
 * to it) — the seam a thread-context analysis needs to classify callback
 * execution contexts. `span` is the call / reference site in `file`.
 *
 * `dispatchType` is set on an INSTANCE dispatch — a value receiver or an implicit
 * `this` — and names the receiver's static type, so a consumer that grows the graph
 * later can recompute the override targets against the subtypes it has loaded since.
 */
typedef CallEdge = {
	var from: String;
	var to: String;
	var kind: EdgeKind;
	var via: Null<String>;
	var file: String;
	var span: Null<Span>;
	var dispatchType: Null<String>;

	/**
	 * The member a call's receiver names directly — a bare field, `this.f`, a static `T.f` — as `Owner.f`, set on the
	 * edges of that call site; null for every other receiver (a local, a parameter, an expression) and every other edge.
	 * What names one lock OBJECT for a lock-discipline analysis: the receiver's type alone merges every lock of a class.
	 */
	var receiverField: Null<String>;

	/** For an edge the compiler facts file off a body an inlined call spliced into `from`: where it runs (`SplicedSite`). */
	@:optional var spliced: Null<SplicedSite>;

	/**
	 * For an edge the compiler facts record of a call or a method read as a value, the typed type they name as the
	 * target's owner (`pack._Module.Name_Impl_` for an abstract's member): which of the types sharing the simple name
	 * `to` is keyed by declares the code that runs (`CallGraphFacts.qualify`). Null on every other edge.
	 */
	@:optional var typed: Null<String>;

	/**
	 * For an edge the compiler facts record of a call they inlined at a known site, its body's facts filed in `from` as
	 * the splice they made there (`CallGraphFacts.declaredCall`): what that body runs at the call is what `from`'s facts
	 * say, at the types this call instantiated it at. Null on every other edge.
	 */
	@:optional var inlined: Null<Bool>;

	/**
	 * For a `Ref` edge whose site is the right-hand side of an assignment to a `dynamic` method (`w.onDone = handler`), that
	 * member's node: the value runs wherever the member is invoked, never at the assignment. Null on every other edge.
	 */
	@:optional var storedInto: Null<String>;

	/**
	 * For a `Ref` edge whose value is an argument of a call, the member name the call is written with (`removeEventListener`
	 * in `x.removeEventListener(t, handler)`), set whether or not the graph resolves the call. Null on every other edge.
	 */
	@:optional var viaMember: Null<String>;
}

/**
 * Why a call site has no resolved target. The distinction a reachability consumer
 * needs: a FUNCTION VALUE can be any function the program ever handed out as a value,
 * a Dynamic receiver dispatches by NAME to any member so named, and an unresolved
 * receiver is a static type the graph could not recover.
 */
enum UnresolvedReason {

	/** A call through a value — a local, a field of function type, a `dynamic` method, an expression result. */
	FunctionValue(what: String);

	/** `recv.m()` on a receiver declared `Dynamic` / `Any`: the target is chosen by name at run time. */
	DynamicReceiver(member: String);

	/** `recv.m()` whose receiver's static type the graph cannot recover. */
	UnresolvedReceiver(member: String);

	/** A bare call to a name that binds to nothing the graph knows. */
	UnboundName(name: String);

	/** A callee of another shape (`kind` names the projected node kind). */
	ComplexCallee(kind: String);

	/** A call the compiler resolved to code the graph holds no node for (`what` names it): nothing here can follow it. */
	Unseen(what: String);

}

/**
 * A call whose target could not be resolved even approximately. Kept per-site, with
 * the enclosing function node `from`, so consumers can report honest coverage and a
 * reachability walk can tell whether the site lies on its path.
 */
typedef UnresolvedCall = {
	var file: String;
	var span: Null<Span>;
	var from: String;
	var reason: UnresolvedReason;

	/**
	 * For a call of a value the compiler facts typed (`FunctionValue`): the facts type of the value called, which says which
	 * functions it may be (`FunctionValueTypes`).
	 */
	@:optional var called: Null<String>;

	/** With `called`: the range of the expression whose value is called, in the file of the facts (`CallFact.receiverAt`). */
	@:optional var calledAt: Null<FactPos>;

	/**
	 * For a call of a `dynamic` method the compiler facts name (`pack.Type.field`): the values stored into that field, which
	 * the facts may say (`FunctionValueTypes.storedIn`), are what it may run beside its declared bodies.
	 */
	@:optional var stored: Null<String>;

	/** For a site the compiler facts file off a body an inlined call spliced into `from`: where it runs (`SplicedSite`). */
	@:optional var spliced: Null<SplicedSite>;
}

/**
 * A read or write of a member NAMED like a property with an accessor somewhere in the
 * index, on a receiver whose type the graph could not recover — an accessor call the
 * graph could not attribute. `dynamicReceiver` is true when the receiver is declared
 * `Dynamic` / `Any`.
 */
typedef UnresolvedAccess = {
	var file: String;
	var span: Null<Span>;
	var from: String;
	var member: String;
	var write: Bool;
	var dynamicReceiver: Bool;

	/** For an access the compiler facts file off a body an inlined call spliced into `from`: where it runs (`SplicedSite`). */
	@:optional var spliced: Null<SplicedSite>;
}

/**
 * Where the code of an edge, unresolved call or access the compiler facts file off a body an inlined call spliced into a
 * function runs, which no span of the function's file says (`CallGraphFacts.siteOf`): `sites`, ranges of that file each
 * holding a call site that spliced the body in — null when no inlined call's body holds the code, which may then run
 * anywhere in the function — and `origin`, the graph node of the inlined method the code is written in, with the code's
 * own range (`span`) in the file the compiler facts key as `file`; null when the graph names no such node.
 */
typedef SplicedSite = {
	final sites: Null<Array<Span>>;
	final origin: Null<{ node: String, file: String, span: Span }>;
}

/**
 * Edge classification. `Call` / `New` are direct invocations; `Virtual` is an
 * over-approximated dispatch to a subtype override; `Ref` is a function VALUE
 * reference (callback registration, `.bind`, a lambda or method used as a value
 * anywhere) — invoked later by whoever received it; `Contains` links an enclosing
 * function to a lambda / local function declared inside it (lexical containment,
 * not execution); `Accessor` is a property read or write that runs its getter or
 * setter.
 */
enum abstract EdgeKind(Int) {

	final Call = 0;
	final Ref = 1;
	final New = 2;
	final Virtual = 3;
	final Contains = 4;
	final Accessor = 5;

	public function label(): String {
		return switch (cast this: EdgeKind) {
			case Call: 'call';
			case Ref: 'ref';
			case New: 'new';
			case Virtual: 'virtual';
			case Contains: 'contains';
			case Accessor: 'accessor';
		};
	}

	/** Whether the edge RUNS its target at the site — a call, a constructor, an override, an accessor. */
	public function isInvocation(): Bool {
		return switch (cast this: EdgeKind) {
			case Call, New, Virtual, Accessor: true;
			case Ref, Contains: false;
		};
	}

}

/**
 * Project-wide approximate call graph over the `QueryNode` projection — the
 * shared core of the `callees` / `callers` / `reach` subcommands, the
 * `thread-safety` check and `MemberReach`.
 *
 * Resolution is name-based (no typer): bare calls resolve through the `Refs`
 * scope resolver to same-file methods and local functions; `this.m()` and
 * inherited bare calls resolve through the member table + `SymbolIndex`
 * supertypes; `obj.m()` resolves when the receiver identifier carries an
 * explicit nominal type annotation (`TypeInfoProvider.declaredTypes`), with
 * `Null<T>` unwrapped to `T` via `declaredTypeSources`; `Type.m()` resolves as
 * a static member; `f().m()` resolves through the DECLARED return type of `f`
 * (`TypeInfoProvider.returnTypes`) — an annotation the source carries, never an
 * inferred one, and a nullable / dynamic wrapper names no dispatchable type. A
 * receiver none of those name — a field path, an element `a[i]`, an inherited
 * field read without `this` — is typed through the DECLARED member types the index
 * records, again never an inferred one: a typedef alias is seen through, a member
 * declared as a type parameter takes the receiver's argument for it, a value typed
 * by a type parameter in scope stays unresolved, `this` inside an abstract is its
 * underlying value, `super` is the superclass however the header orders it, and a
 * method no type on a fully indexed chain declares resolves to the static extension
 * a `using` brings in, or stays unresolved.
 * Instance calls additionally emit `Virtual` edges to subtype overrides, and a
 * BARE call to a non-static member of the enclosing type IS one — it is an
 * implicit-`this` call, so it dispatches exactly like `this.m()`. A property read
 * or write whose accessor is a getter / setter emits an `Accessor` edge; a `new T()`
 * and a `super()` reach the field-initializer pseudo-node `T.<init>` of every type
 * whose constructor runs. Everything unresolvable is recorded in `unresolved` /
 * `unresolvedAccess` — the graph over-approximates but never silently drops a call
 * it could name. Each file's nodes are collected by `CallGraphNodes`, its edges by
 * `CallGraphEdges`.
 *
 * The graph GROWS: `addFiles` adds files after the build, upgrading the external
 * placeholders the new files declare. Edges already collected keep the targets they
 * were resolved to, so a consumer that grows the graph re-resolves an external target
 * through `memberOnChain` / `virtualTargets`.
 *
 * Node ids are simple type names: two types with the same simple name merge into one graph node —
 * acceptable for a finder, a known limit kept so finding keys stay stable (`docs/decisions.md`). What a
 * written type name means is the shared binding's (`TypeNameBinding.bindingsOf`), a library type a project
 * type's simple name bears keyed apart by its path. Where the compiler facts are the truth, an edge they
 * record names the typed owner of its target (`CallEdge.typed`), and a node of
 * such a name may be read as that one type's member (`CallGraphFacts.qualify`).
 *
 * A node FOLDS every declaration of its id: a member declared in each branch of a conditional region, an overload, a
 * copy of its type per build or per package. Each is code the node runs (`declarationsOf`), a site inside any of them
 * is the node's (`functionAt`, `declarationAt`), a `dynamic` or bodied declaration makes the node so, and what the
 * declarations say of its types — the return, the parameters, their bounds — is the node's only where they all say
 * it alike. A field initializer is code too, whether it calls anything or not: a type holding one has its
 * `<init>` / `<static>` node, which runs the initializers of every file declaring the type (`initializerFiles`).
 */
@:nullSafety(Strict)
final class CallGraph {

	/** The name of the INSTANCE field-initializer pseudo-node every type's constructor runs first. */
	public static inline final INIT_NAME: String = '<init>';

	/** The name of the STATIC field-initializer pseudo-node, which no constructor runs. */
	public static inline final STATIC_INIT_NAME: String = '<static>';

	/** What joins a module-level function's id and the ordinal of a further body of it (`Mod.f@2`, `bodiesOf`). */
	public static inline final BODY_MARK: String = '@';

	/** What a type parameter nothing binds becomes in a written type: text that names no type. */
	private static inline final UNKNOWN_TYPE: String = '$$_';

	public final nodes: Map<String, FnNode> = [];
	public final edges: Array<CallEdge> = [];
	public final unresolved: Array<UnresolvedCall> = [];
	public final unresolvedAccess: Array<UnresolvedAccess> = [];
	public final skippedFiles: Array<String> = [];

	/** The type facts edges resolve against, seeded from the index `build` was given. */
	public final types: CallGraphTypes;

	/**
	 * The index the graph was built over (`build`: the one handed, else the report index of its files), whose layers answer a
	 * consumer's type question by declaration; null for a grammar without call seams.
	 */
	public final index: Null<SymbolIndex>;

	/**
	 * How the graph reads compiler facts (`CallGraphFacts`): which functions they replace the syntax of, and the view
	 * over the table (`FactsView`); null for syntax alone.
	 */
	public final facts: Null<CallGraphFacts>;

	private final _out: Map<String, Array<CallEdge>> = [];
	private final _in: Map<String, Array<CallEdge>> = [];
	private final _byMember: Map<String, Array<String>> = [];
	private final _members: Map<String, Map<String, String>> = [];

	/** What the declarations of the graph's functions and abstracts say: return and parameter types, type parameters, underlying types. */
	private final _facts: DeclarationFacts = new DeclarationFacts();

	/** The types that gained a node during the current `addFiles`. */
	private final _grownTypes: Array<String> = [];

	/** File -> the function-like nodes whose first declaration it holds: what taking the file out removes. */
	private final _fileNodes: Map<String, Array<FnNode>> = [];

	/** Node id -> every declaration it stands for (`declarationsOf`). */
	private final _declarations: Map<String, Array<FnDeclaration>> = [];

	/** File -> every declaration of a function-like node it holds, for `declarationAt`. */
	private final _fileDeclarations: Map<String, Array<FnDeclaration>> = [];

	/**
	 * Module-level function id -> the ids of its further bodies in its file, one per `#if` branch declaring it again, each a
	 * node of its own (`CallGraphNodes.bodyId`, `bodiesOf`).
	 */
	private final _bodies: Map<String, Array<String>> = [];

	/** Field-initializer pseudo-node id -> the files holding initializers it runs (`initializerFiles`). */
	private final _initFiles: Map<String, Array<String>> = [];

	/** File -> its parsed entry, for every file the graph holds. */
	private final _entries: Map<String, ParsedEntry> = [];

	/** The constructor runs recorded while walking, and their wiring to the `<init>` nodes. */
	private final _wiring: ConstructorWiring;

	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;
	private final _provider: Null<TypeInfoProvider>;

	private function new(
		plugin: GrammarPlugin, shape: RefShape, provider: Null<TypeInfoProvider>, types: CallGraphTypes, facts: Null<CallGraphFacts>,
		index: Null<SymbolIndex>
	) {
		_plugin = plugin;
		_shape = shape;
		_provider = provider;
		this.types = types;
		this.facts = facts;
		this.index = index;
		_wiring = new ConstructorWiring(this, shape.constructorName ?? 'new');
	}

	public inline function node(id: String): Null<FnNode> {
		return nodes[id];
	}

	/** The node of `member` that `typeName` itself declares — not an inherited one — or null. */
	public inline function ownMember(typeName: String, member: String): Null<String> {
		return _members[typeName]?.get(member);
	}

	/**
	 * Every node a reference naming `id` may run: `id`, then — for a module-level function its file declares in several `#if`
	 * branches — each further body (`Mod.f@2`, …), a node of its own. A bare use the graph binds per build names the bodies
	 * it runs; anything else naming the function — an import, a qualified access, a query — runs every one (`addEdge`).
	 */
	public inline function bodiesOf(id: String): Array<String> {
		return [id].concat(_bodies[id] ?? []);
	}

	/** Every type the graph holds a declaration of. */
	public inline function declaringTypes(): Iterator<String> {
		return _members.keys();
	}

	/** The innermost function-like node of `file` a declaration of which contains `offset`, or null outside every function. */
	public inline function functionAt(file: String, offset: Int): Null<String> {
		return declarationAt(file, offset)?.id;
	}

	/**
	 * Every declaration the node `id` stands for, in the order the graph read them: the one its `span` names first, then
	 * every other the graph folded into it — each of them code the node runs. Empty for a node no text declares: an
	 * external placeholder, a field-initializer pseudo-node (`initializerFiles`), a method a build macro made.
	 */
	public inline function declarationsOf(id: String): Array<FnDeclaration> {
		return _declarations[id] ?? [];
	}

	/**
	 * The files whose field initializers the pseudo-node `id` (`INIT_NAME`
	 * / `STATIC_INIT_NAME`) runs, in the order the graph read them.
	 */
	public inline function initializerFiles(id: String): Array<String> {
		return _initFiles[id] ?? [];
	}

	/**
	 * Every key the type name `written` may mean in `file` (`CallGraphImports.keysOf`): the type the file binds it to, then
	 * each one a `#if`-guarded statement or a package wildcard may bind it to instead; none when nothing binds it.
	 */
	public inline function typeKeysOf(file: String, written: String): Array<String> {
		return types.imports.keysOf(file, written);
	}

	/** The paths the type keyed `type` is declared under: its module's, the module's and its own, the package's and its own. */
	public inline function declaredPathsOf(type: String): Array<String> {
		return types.imports.declaredPathsOf(type);
	}

	/**
	 * Adds an edge a consumer derived from what the graph already holds (`thread-safety`'s calls of a value stored into a
	 * `dynamic` method, at the member's own call sites): it is indexed as any other, and only the consumer's own graph
	 * carries it.
	 */
	public inline function deriveEdge(edge: CallEdge): Void {
		indexEdge(edge);
	}

	/**
	 * The written bounds of type parameter `name` as `id` sees it: a function, its own or an enclosing one's (a lambda's) or —
	 * unless `functionsOnly` — its type's; a type, its own (empty if declarations differ). Empty if unbounded, null for none.
	 */
	public function typeParamBoundsOf(id: String, name: String, functionsOnly: Bool = false): Null<Array<String>> {
		var at: String = id;
		while (!(_facts.typeParams[at] ?? []).contains(name) && at.indexOf('#') >= 0) at = at.substring(0, at.lastIndexOf('#'));
		if ((_facts.typeParams[at] ?? []).contains(name)) return _facts.typeParamBounds[at]?.get(name) ?? [];
		final fn: Null<FnNode> = nodes[id];
		final type: String = fn?.typeName ?? (fn == null ? id : '');
		if (functionsOnly || !types.generics.declaresTypeParam(type, name)) return null;
		final file: Null<String> = fn == null ? null : DeclarationFacts.boundsKey(fn.file, type);
		final written: Array<Array<String>> = [
			for (k => b in _facts.typeBounds) if (file == null ? k.endsWith('#$type') : k == file) b[name] ?? []
		];
		return written.length == 0 || written.exists(w -> w.join('&') != written[0].join('&')) ? [] : written[0];
	}

	public function outEdges(id: String): Array<CallEdge> {
		return _out[id] ?? [];
	}

	public function inEdges(id: String): Array<CallEdge> {
		return _in[id] ?? [];
	}

	/** The parsed tree of `file`, or null when the graph does not hold it. */
	public function treeOf(file: String): Null<QueryNode> {
		return _entries[CallGraphNames.normalizePath(file)]?.tree;
	}

	/** Every file the graph holds, with its text and its tree. */
	public function heldFiles(): Array<{ file: String, source: String, tree: QueryNode }> {
		return [for (e in _entries) { file: e.file, source: e.source, tree: e.tree }];
	}

	/** The source of `file`, or null when the graph does not hold it. */
	public function sourceOf(file: String): Null<String> {
		return _entries[CallGraphNames.normalizePath(file)]?.source;
	}

	/** The innermost declaration of a function-like node in `file` whose span contains `offset`, or null outside every function. */
	public function declarationAt(file: String, offset: Int): Null<FnDeclaration> {
		var best: Null<FnDeclaration> = null;
		for (d in _fileDeclarations[CallGraphNames.normalizePath(file)] ?? []) {
			final span: Span = d.span;
			if (offset < span.from || offset >= span.to) continue;
			final current: Null<Span> = best?.span;
			if (current == null || span.to - span.from < current.to - current.from) best = d;
		}
		return best;
	}

	/**
	 * Whether a node with a declaration in `file` has one in another file too: taking `file` out of the graph drops that
	 * node, with every edge the other declaration's code recorded, which re-adding `file` alone does not bring back.
	 */
	public function foldsAcrossFiles(file: String): Bool {
		final key: String = CallGraphNames.normalizePath(file);
		for (d in _fileDeclarations[key] ?? []) if (declarationsOf(d.id).exists(o -> CallGraphNames.normalizePath(o.file) != key))
			return true;
		return Lambda.exists(_initFiles, files -> files.length > 1 && files.exists(f -> CallGraphNames.normalizePath(f) == key));
	}

	/**
	 * The untyped-receiver accesses that may run one of `targets`: a read or write of the property an accessor
	 * serves (`p.x` for `get_x`), or a read of the method itself as a value.
	 */
	public function unresolvedAccessesRunning(targets: Array<FnNode>): Array<UnresolvedAccess> {
		final names: Array<String> = [];
		for (t in targets) {
			final name: Null<String> = t.name;
			if (name == null) continue;
			names.push(name);
			for (prefix in _shape.accessorMethodPrefixes ?? []) if (name.startsWith(prefix)) names.push(name.substr(prefix.length));
		}
		return [for (a in unresolvedAccess) if (names.contains(a.member)) a];
	}

	/**
	 * Resolve a user-facing target query to nodes: `Type.method` (every type keyed by that simple name), `pkg.Type.method`
	 * (the type declared at that path only — a project type of the same simple name elsewhere is another type, `pathKey`), or
	 * a bare `method` name (every type's member with that name). More than one result means the query is ambiguous — the
	 * caller decides how to present the candidates.
	 */
	public function resolveTarget(query: String): Array<FnNode> {
		final simple: String = CallGraphNames.lastSegments(query, 2);
		final ids: Array<String> = simple.indexOf('.') == -1 ? _byMember[simple] ?? [] : types.imports.memberIds(query);
		final out: Array<FnNode> = [];
		for (id in ids) for (body in bodiesOf(id)) {
			final n: Null<FnNode> = nodes[body];
			if (n != null && !out.contains(n)) out.push(n);
		}
		return out;
	}

	/**
	 * All node ids matching a config pattern: `Type.method` or `pkg.Type.method` (`resolveTarget`), `Type.*` (every recorded
	 * member of every type keyed by that simple name, external nodes included), `pkg.Type.*` (of the type declared at that
	 * path only), or a bare `method`. Missing types / members yield [].
	 */
	public function matchIds(pattern: String): Array<String> {
		if (!pattern.endsWith('.*')) return [for (n in resolveTarget(pattern)) n.id];
		final named: Array<String> = types.imports.typeKeys(pattern.substring(0, pattern.length - 2));
		return [
			for (id => n in nodes) if (n.name != null && named.contains(n.typeName ?? '')) id
		];
	}

	/**
	 * Parse and add `files` the graph does not hold yet: their nodes first, then their
	 * edges, then the constructor wiring over every file. A file already held (or already
	 * skipped) is ignored, so a caller may pass a closure that overlaps what it added before.
	 */
	public function addFiles(files: Array<{ file: String, source: String }>): Void {
		final parsed: Array<ParsedEntry> = [];
		for (entry in files) {
			final key: String = CallGraphNames.normalizePath(entry.file);
			if (_entries.exists(key) || skippedFiles.exists(f -> CallGraphNames.normalizePath(f) == key)) continue;
			final tree: Null<QueryNode> = ParseGate.parseOrNull(_plugin, entry.source);
			if (tree == null) {
				skippedFiles.push(entry.file);
				continue;
			}
			final parsedTree: QueryNode = tree;
			final p: ParsedEntry = {
				file: entry.file,
				source: entry.source,
				tree: parsedTree,
				fnBySpanFrom: []
			};
			_entries[key] = p;
			parsed.push(p);
		}
		final unindexed: Array<{ file: String, source: String }> = [
			for (p in parsed) if (types.heldFile(p.file) == null) { file: p.file, source: p.source }
		];
		if (unindexed.length > 0) types.merge(IndexScope.over(unindexed, _plugin));
		_grownTypes.resize(0);
		for (p in parsed) CallGraphNodes.collect(this, p);
		final reading: Null<CallGraphFacts> = facts;
		// a method a build macro made has no declaration to collect: the facts make its node (`CallGraphFacts.adopt`)
		final adopted: Array<String> = reading == null ? [] : [for (p in parsed) for (id in reading.adopt(this, p.file)) id];
		for (p in parsed) {
			// a function the facts describe records its syntax's edges alone, none of its unresolved sites (`CallGraphFacts.mute`)
			final faceted: Map<String, Array<FactNode>> = reading == null ? [] : reading.mute(this, p.file);
			CallGraphEdges.collect(this, p);
			reading?.recordMuted(this, faceted);
		}
		reading?.recordAdopted(this, adopted);
		// the field initializers of every type read so far, which the facts read whole once its files are in
		reading?.recordInitializers(this, [for (id in _initFiles.keys()) id]);
		_wiring.markGrownChains(_grownTypes);
		_wiring.wire((from, to, kind, file, span) -> addEdge(from, to, kind, null, file, span));
	}

	/**
	 * Take `file` back out of the graph, as if it had never been added: its entry, the nodes it declares, every
	 * edge made at one of its sites or from one of its nodes, its unresolved calls and accesses, and its constructor
	 * runs. The type tables keep what the file declared — the caller re-adds a file whose declarations did not change.
	 */
	public function removeFile(file: String): Void {
		final key: String = CallGraphNames.normalizePath(file);
		skippedFiles.remove(file);
		if (!_entries.exists(key)) return;
		_entries.remove(key);
		final removed: Map<String, Bool> = nodesLeavingWith(key);
		// a body's edges from other files are copies of the function's, made again when the file is read again
		final bodies: Array<String> = [for (ids in _bodies) for (id in ids) if (removed.exists(id)) id];
		_fileNodes.remove(key);
		_fileDeclarations.remove(key);
		forgetDeclarationsIn(key);
		forgetNodes(file, removed);
		purgeSites(key, removed, bodies);
	}

	/**
	 * Member lookup on `typeName` walking the supertype chain (BFS, cycle-safe) — also the query-time
	 * re-resolution a consumer that grew the graph uses for an external target.
	 */
	public function memberOnChain(typeName: String, member: String): Null<String> {
		final owner: Null<String> = types.firstOnChain(typeName, t -> _members[t]?.exists(member) == true);
		return owner == null ? null : _members[owner]?.get(member);
	}

	/**
	 * The virtual dispatch targets of `member` on `typeName`, recomputable after the graph grew: for each transitive loaded
	 * subtype, the member it declares — or, lacking one, the one it inherits from a superclass off `typeName`'s own chain (a
	 * class implementing an interface with a method its superclass declares), which a dispatch on `typeName` runs too.
	 */
	public function virtualTargets(typeName: String, member: String): Array<String> {
		final result: Array<String> = [];
		// sets beside the lists, whose order is the answer: the `contains` scans were quadratic over a wide hierarchy (TM's
		// display list), and this runs per call site
		final found: Map<String, Bool> = [];
		final queue: Array<String> = [typeName];
		final visited: Map<String, Bool> = [];
		var qi: Int = 0;
		while (qi < queue.length) {
			final t: String = queue[qi++];
			if (visited.exists(t)) continue;
			visited[t] = true;
			for (sub in types.subtypesOf(t)) {
				queue.push(sub);
				final hit: Null<String> = _members[sub]?.get(member) ?? inheritedOffChain(typeName, sub, member);
				if (hit == null || found.exists(hit)) continue;
				found[hit] = true;
				result.push(hit);
			}
		}
		return result;
	}

	/**
	 * The placeholder for `typeName.member`, a target whose body the graph does not hold (upgraded in place when
	 * the file declaring it arrives) — or, with
	 * `interfaceDeclared`, the body-less node standing for an accessor an interface's property implies but never
	 * declares: a call of it dispatches to the implementations and runs nothing of its own.
	 */
	public function externalNode(typeName: String, member: String, interfaceDeclared: Bool = false): String {
		final id: String = '$typeName.$member';
		if (!nodes.exists(id)) nodes[id] = {
			id: id,
			file: '',
			typeName: typeName,
			name: member,
			span: null,
			isExternal: !interfaceDeclared,
			isDynamic: false,
			isBodyless: interfaceDeclared
		};
		return id;
	}

	/**
	 * The nodes that leave the graph with the file keyed `key` (`removeFile`): those it declares, and each read as one of the
	 * types sharing a name (`CallGraphFacts.qualify`) whose node leaves or any declaration it reads lies in the file — whose
	 * declarations go with it.
	 */
	private function nodesLeavingWith(key: String): Map<String, Bool> {
		final removed: Map<String, Bool> = [for (n in _fileNodes[key] ?? []) n.id => true];
		final reading: Null<CallGraphFacts> = facts;
		if (reading != null) for (variant => read in reading.qualified) if (
			removed.exists(read.node) || declarationsOf(variant).exists(d -> CallGraphNames.normalizePath(d.file) == key)
		) {
			removed[variant] = true;
			_declarations.remove(variant);
		}
		return removed;
	}

	/**
	 * Drop every declaration the file keyed `key` holds, and the file from the files whose field initializers a node runs —
	 * the initializers of a file read again are recorded again (`CallGraphFacts.recordInitializers`).
	 */
	private function forgetDeclarationsIn(key: String): Void {
		for (id in [for (id in _declarations.keys()) id]) {
			final kept: Array<FnDeclaration> = [for (d in declarationsOf(id)) if (CallGraphNames.normalizePath(d.file) != key) d];
			if (kept.length == 0)
				_declarations.remove(id)
			else
				_declarations[id] = kept;
		}
		for (id => files in _initFiles) {
			if (files.exists(f -> CallGraphNames.normalizePath(f) == key)) facts?.faceted.remove(id);
			_initFiles[id] = [for (f in files) if (CallGraphNames.normalizePath(f) != key) f];
		}
	}

	/** Drop the nodes `removed`, which leave with `file`, from the node table, the facts and the member tables. */
	private function forgetNodes(file: String, removed: Map<String, Bool>): Void {
		for (id in removed.keys()) {
			nodes.remove(id);
			_facts.forget(id);
		}
		facts?.forget(file, removed);
		for (table in _members) for (member in [for (m => id in table) if (removed.exists(id)) m]) table.remove(member);
		for (name => ids in _byMember) _byMember[name] = [for (id in ids) if (!removed.exists(id)) id];
		for (id in [for (id in _bodies.keys()) id]) if (removed.exists(id)) _bodies.remove(id);
	}

	/**
	 * The `member` the superclass chain of `sub` declares first, when that superclass is off `typeName`'s own chain — one on
	 * it is the dispatched member itself — or null.
	 */
	private function inheritedOffChain(typeName: String, sub: String, member: String): Null<String> {
		final seen: Array<String> = [sub];
		var at: Null<String> = types.superclassOf(sub);
		while (at != null && !seen.contains(at)) {
			final holder: String = at;
			final hit: Null<String> = _members[holder]?.get(member);
			if (hit != null) return types.firstOnChain(typeName, t -> t == holder) == null ? hit : null;
			seen.push(holder);
			at = types.superclassOf(holder);
		}
		return null;
	}

	/**
	 * Drop every edge made at a site of `file`, from one of the `removed` nodes or into one of the further `bodies` among them,
	 * its unresolved records and its constructor runs.
	 */
	private function purgeSites(key: String, removed: Map<String, Bool>, bodies: Array<String>): Void {
		final kept: Array<CallEdge> = [
			for (e in edges) if (CallGraphNames.normalizePath(e.file) != key && !removed.exists(e.from) && !bodies.contains(e.to)) e
		];
		edges.resize(0);
		_out.clear();
		_in.clear();
		for (e in kept) indexEdge(e);
		final calls: Array<UnresolvedCall> = [for (u in unresolved) if (CallGraphNames.normalizePath(u.file) != key) u];
		unresolved.resize(0);
		for (u in calls) unresolved.push(u);
		final accesses: Array<UnresolvedAccess> = [for (a in unresolvedAccess) if (CallGraphNames.normalizePath(a.file) != key) a];
		unresolvedAccess.resize(0);
		for (a in accesses) unresolvedAccess.push(a);
		_wiring.removeFile(key, removed);
	}

	private function registerMember(typeName: String, member: String, id: String): Void {
		final table: Map<String, String> = _members[typeName] ?? [];
		if (!table.exists(member)) table[member] = id;
		_members[typeName] = table;
	}

	/**
	 * The node a constructor run on `typeName` names: the declared constructor on its chain, a placeholder for
	 * the one the index says the chain declares, or — when the chain is fully indexed and declares none — null:
	 * the generated constructor runs only initializers, which the wiring adds.
	 */
	private function constructorTarget(typeName: String, ctorName: String): Null<String> {
		final declared: Null<String> = memberOnChain(typeName, ctorName);
		if (declared != null) return declared;
		final owner: Null<String> = types.declaringTypeOf(typeName, ctorName);
		return owner == null && types.chainFullyIndexed(typeName) ? null : externalNode(owner ?? typeName, ctorName);
	}

	/** Pseudo-node holding calls made from the instance (or, `isStatic`, the static) field initializers of `typeName`. */
	private function initNode(typeName: String, file: String, isStatic: Bool = false): String {
		final name: String = isStatic ? STATIC_INIT_NAME : INIT_NAME;
		final id: String = '$typeName.$name';
		final key: String = CallGraphNames.normalizePath(file);
		final files: Array<String> = _initFiles[id] ?? [];
		if (!files.exists(f -> CallGraphNames.normalizePath(f) == key)) files.push(file);
		_initFiles[id] = files;
		if (!nodes.exists(id) && !_grownTypes.contains(typeName)) _grownTypes.push(typeName);
		if (!nodes.exists(id)) nodes[id] = {
			id: id,
			file: file,
			typeName: typeName,
			name: name,
			span: null,
			isExternal: false,
			isDynamic: false,
			isBodyless: false
		};
		return id;
	}

	/**
	 * Add the edge `from` -> `to`, and — unless it is `exact`, naming the one body of a module-level function a bare use binds
	 * per build — one to each further body `to` has (`bodiesOf`): a reference naming the function runs whichever its build has.
	 */
	private function addEdge(
		from: String, to: String, kind: EdgeKind, via: Null<String>, file: String, span: Null<Span>, ?dispatchType: String,
		?receiverField: String, ?typed: String, ?inlined: Bool, ?storedInto: String, ?viaMember: String, exact: Bool = false
	): Void {
		final edge: CallEdge = {
			from: from,
			to: to,
			kind: kind,
			via: via,
			file: file,
			span: span,
			dispatchType: dispatchType,
			receiverField: receiverField
		};
		if (typed != null) edge.typed = typed;
		if (inlined == true) edge.inlined = true;
		if (storedInto != null) edge.storedInto = storedInto;
		if (viaMember != null) edge.viaMember = viaMember;
		// a faceted function's syntax still records every edge it names, which the facts only add to — unless they are the
		// truth: then its edge at a site they type is dropped (`CallGraphFacts.holdsBack`)
		for (e in [edge].concat(exact ? [] : [for (body in _bodies[to] ?? []) retargeted(edge, body)])) if (facts?.holdsBack(e) != true)
			indexEdge(e);
	}

	/** Record `edge` in the edge list and the per-node indexes. */
	private function indexEdge(edge: CallEdge): Void {
		edges.push(edge);
		final out: Array<CallEdge> = _out[edge.from] ?? [];
		out.push(edge);
		_out[edge.from] = out;
		final into: Array<CallEdge> = _in[edge.to] ?? [];
		into.push(edge);
		_in[edge.to] = into;
	}

	/**
	 * Build the graph over `files`. The plugin is wrapped in a
	 * `CachingGrammarPlugin` unless it already is one, so each file parses
	 * once; a prebuilt `SymbolIndex` is reused when supplied — and one wider than
	 * `files` (a resolution index that also covers libraries) gives the graph the
	 * supertypes, member kinds and property accessors of types it holds no file for.
	 * A grammar without call/ident/field-access shape seams yields an empty graph.
	 */
	public static function build(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?index: SymbolIndex, ?facts: FactsView
	): CallGraph {
		final cached: GrammarPlugin = plugin is CachingGrammarPlugin ? plugin : new CachingGrammarPlugin(plugin);
		final shape: RefShape = cached.refShape();
		final provider: Null<TypeInfoProvider> = cached is TypeInfoProvider ? cast cached : null;
		if (shape.callKind == null || shape.fieldAccessKind == null)
			return new CallGraph(cached, shape, provider, new CallGraphTypes(null, shape), null, null);
		final seed: SymbolIndex = index ?? IndexScope.report(files, cached);
		final types: CallGraphTypes = new CallGraphTypes(seed, shape);
		final graph: CallGraph = new CallGraph(cached, shape, provider, types, facts == null ? null : new CallGraphFacts(facts), seed);
		graph.addFiles(files);
		return graph;
	}

	/** `edge` made into `to`, every other field kept. */
	private static function retargeted(edge: CallEdge, to: String): CallEdge {
		final out: CallEdge = {
			from: edge.from,
			to: to,
			kind: edge.kind,
			via: edge.via,
			file: edge.file,
			span: edge.span,
			dispatchType: edge.dispatchType,
			receiverField: edge.receiverField
		};
		if (edge.spliced != null) out.spliced = edge.spliced;
		if (edge.typed != null) out.typed = edge.typed;
		if (edge.inlined != null) out.inlined = edge.inlined;
		if (edge.storedInto != null) out.storedInto = edge.storedInto;
		if (edge.viaMember != null) out.viaMember = edge.viaMember;
		return out;
	}

}

/**
 * A file the graph holds: its path and text, its tree, and the node of each function-like declaration in it by
 * the offset its span starts at, which `CallGraphNodes.collect` records and `CallGraphEdges.collect` reads.
 */
typedef ParsedEntry = {
	var file: String;
	var source: String;
	var tree: QueryNode;
	var fnBySpanFrom: Map<Int, String>;
}
