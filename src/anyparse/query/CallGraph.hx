package anyparse.query;

import anyparse.query.CallGraphImports.ImportedName;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
 * it could name.
 *
 * The graph GROWS: `addFiles` adds files after the build, upgrading the external
 * placeholders the new files declare. Edges already collected keep the targets they
 * were resolved to, so a consumer that grows the graph re-resolves an external target
 * through `memberOnChain` / `virtualTargets`.
 *
 * Simple type names only (`SymbolIndex` models no packages): two types with
 * the same simple name merge into one graph node — acceptable for a finder,
 * listed as a known limit.
 */
@:nullSafety(Strict)
final class CallGraph {

	/** The name of the INSTANCE field-initializer pseudo-node every type's constructor runs first. */
	public static inline final INIT_NAME: String = '<init>';

	/** The name of the STATIC field-initializer pseudo-node, which no constructor runs. */
	public static inline final STATIC_INIT_NAME: String = '<static>';

	/** What a type parameter nothing binds becomes in a written type: text that names no type. */
	private static inline final UNKNOWN_TYPE: String = '?';

	public final nodes: Map<String, FnNode> = [];
	public final edges: Array<CallEdge> = [];
	public final unresolved: Array<UnresolvedCall> = [];
	public final unresolvedAccess: Array<UnresolvedAccess> = [];
	public final skippedFiles: Array<String> = [];

	/** The type facts edges resolve against, seeded from the index `build` was given. */
	public final types: CallGraphTypes;

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

	/** File -> the function-like nodes declared in it, for `functionAt`. */
	private final _fileNodes: Map<String, Array<FnNode>> = [];

	/** File -> its parsed entry, for every file the graph holds. */
	private final _entries: Map<String, ParsedEntry> = [];

	/** The constructor runs recorded while walking, and their wiring to the `<init>` nodes. */
	private final _wiring: ConstructorWiring;

	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;
	private final _provider: Null<TypeInfoProvider>;

	private function new(
		plugin: GrammarPlugin, shape: RefShape, provider: Null<TypeInfoProvider>, types: CallGraphTypes, facts: Null<CallGraphFacts>
	) {
		_plugin = plugin;
		_shape = shape;
		_provider = provider;
		this.types = types;
		this.facts = facts;
		_wiring = new ConstructorWiring(this, shape.constructorName ?? 'new');
	}

	public inline function node(id: String): Null<FnNode> {
		return nodes[id];
	}

	/** The node of `member` that `typeName` itself declares — not an inherited one — or null. */
	public inline function ownMember(typeName: String, member: String): Null<String> {
		return _members[typeName]?.get(member);
	}

	/** Every type the graph holds a declaration of. */
	public inline function declaringTypes(): Iterator<String> {
		return _members.keys();
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

	/** The source of `file`, or null when the graph does not hold it. */
	public function sourceOf(file: String): Null<String> {
		return _entries[CallGraphNames.normalizePath(file)]?.source;
	}

	/** The innermost function-like node of `file` whose span contains `offset`, or null outside every function. */
	public function functionAt(file: String, offset: Int): Null<String> {
		var best: Null<FnNode> = null;
		for (n in _fileNodes[CallGraphNames.normalizePath(file)] ?? []) {
			final span: Null<Span> = n.span;
			if (span == null || offset < span.from || offset >= span.to) continue;
			final current: Null<Span> = best?.span;
			if (current == null || span.to - span.from < current.to - current.from) best = n;
		}
		return best?.id;
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
	 * Resolve a user-facing target query to nodes: `Type.method` (a qualified
	 * config entry `pkg.Type.method` matches by its last two segments), or a
	 * bare `method` name (every type's member with that name). More than one
	 * result means the query is ambiguous — the caller decides how to present
	 * the candidates.
	 */
	public function resolveTarget(query: String): Array<FnNode> {
		final simple: String = CallGraphNames.lastSegments(query, 2);
		final direct: Null<FnNode> = nodes[simple];
		if (direct != null) return [direct];
		if (simple.indexOf('.') != -1) return [];
		final ids: Array<String> = _byMember[simple] ?? [];
		return [
			for (id in ids) {
				final n: Null<FnNode> = nodes[id];
				if (n != null) n;
			}
		];
	}

	/**
	 * All node ids matching a config pattern: `pkg.Type.method` (last two
	 * segments), `Type.*` (every recorded member of `Type`, external nodes
	 * included), or a bare `method`. Missing types / members yield [].
	 */
	public function matchIds(pattern: String): Array<String> {
		if (!pattern.endsWith('.*')) return [for (n in resolveTarget(pattern)) n.id];
		final typeName: String = CallGraphNames.lastSegments(pattern.substring(0, pattern.length - 2), 1);
		return [for (id => n in nodes) if (n.typeName == typeName && n.name != null) id];
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
			final tree: Null<QueryNode> =
				try _plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
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
			for (p in parsed) if (!types.holdsFile(p.file)) { file: p.file, source: p.source }
		];
		if (unindexed.length > 0) types.merge(SymbolIndex.build(unindexed, _plugin));
		_grownTypes.resize(0);
		for (p in parsed) collectNodes(p);
		for (p in parsed) {
			final reading: Null<CallGraphFacts> = facts;
			// a function the facts replace records nothing from its syntax (`CallGraphFacts.mute`)
			final faceted: Map<String, Array<FactNode>> = reading == null ? [] : reading.mute(this, p.file, p.fnBySpanFrom);
			collectEdges(p);
			if (reading != null) reading.recordMuted(this, faceted);
		}
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
		final removed: Map<String, Bool> = [for (n in _fileNodes[key] ?? []) n.id => true];
		_fileNodes.remove(key);
		for (id in removed.keys()) {
			nodes.remove(id);
			_facts.forget(id);
		}
		facts?.forget(file, removed);
		for (table in _members) for (member in [for (m => id in table) if (removed.exists(id)) m]) table.remove(member);
		for (name => ids in _byMember) _byMember[name] = [for (id in ids) if (!removed.exists(id)) id];
		purgeSites(key, removed);
	}

	/**
	 * Member lookup on `typeName` walking the supertype chain (BFS, cycle-safe) — also the query-time
	 * re-resolution a consumer that grew the graph uses for an external target.
	 */
	public function memberOnChain(typeName: String, member: String): Null<String> {
		final owner: Null<String> = types.firstOnChain(typeName, t -> _members[t]?.exists(member) == true);
		return owner == null ? null : _members[owner]?.get(member);
	}

	/** Transitive loaded subtypes of `typeName` that declare `member` — virtual dispatch targets, recomputable after the graph grew. */
	public function virtualTargets(typeName: String, member: String): Array<String> {
		final result: Array<String> = [];
		final queue: Array<String> = [typeName];
		final visited: Array<String> = [];
		var qi: Int = 0;
		while (qi < queue.length) {
			final t: String = queue[qi++];
			if (visited.contains(t)) continue;
			visited.push(t);
			for (sub in types.subtypesOf(t)) {
				queue.push(sub);
				final table: Null<Map<String, String>> = _members[sub];
				final hit: Null<String> = table == null ? null : table[member];
				if (hit != null && !result.contains(hit)) result.push(hit);
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

	/** Drop every edge made at a site of `file` or from one of the `removed` nodes, its unresolved records and its constructor runs. */
	private function purgeSites(key: String, removed: Map<String, Bool>): Void {
		final kept: Array<CallEdge> = [
			for (e in edges) if (CallGraphNames.normalizePath(e.file) != key && !removed.exists(e.from)) e
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

	private function collectNodes(entry: ParsedEntry): Void {
		// noqa: complexity
		final shape: RefShape = _shape;
		final returnTypes: Map<Int, String> = _provider == null ? [] : _provider.returnTypes(entry.source);
		// a local `inline function` is a function of its own like any local one, though the grammar gives it a kind apart
		final fnKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final macroKind: Null<String> = shape.macroModifierKind;
		final dynamicKind: Null<String> = shape.dynamicModifierKind;
		final noBodyKind: Null<String> = shape.noBodyKind;
		final moduleType: String = CallGraphNames.moduleTypeName(entry.file);
		var lambdaCounter: Int = 0;
		final modifierBoundary: QueryNode -> Bool = c -> c.children.length > 0 || c.name != null;

		final underlyingKinds: Array<String> = shape.underlyingThisTypeKinds ?? [];
		final annotationKinds: Array<String> = shape.typeAnnotationKinds ?? [];

		/** The written return type of the function `fn`: its last type annotation that is its own child, not a parameter's. */
		function returnSourceOf(fn: QueryNode, source: String): Null<String> {
			var found: Null<String> = null;
			for (c in fn.children) {
				final at: Null<Span> = c.span;
				if (at != null && annotationKinds.contains(c.kind)) found = source.substring(at.from, at.to);
			}
			return found;
		}

		function walk(node: QueryNode, currentType: Null<String>, parentFn: Null<String>, isDynamic: Bool): Void {
			// a macro-reification subtree is generated-code emission, not runtime
			// calls — walking it would fabricate nodes and edges (mirrors Refs)
			if (opaqueKinds.contains(node.kind)) return;
			final declared: Null<String> = CallGraphNames.typeNameOf(node);
			final typeName: Null<String> = declared ?? currentType;
			if (declared != null && underlyingKinds.contains(node.kind)) {
				final under: Null<QueryNode> = node.children.find(c -> annotationKinds.contains(c.kind));
				_facts.abstracts[declared] = under?.name == null ? null : CallGraphNames.lastSegments(under?.name ?? '', 1);
			}

			var fnId: Null<String> = parentFn;
			final span: Null<Span> = node.span;
			final name: Null<String> = node.name;
			if (span != null && name != null && fnKinds.contains(node.kind)) {
				final owner: String = typeName ?? moduleType;
				fnId = parentFn == null ? '$owner.$name' : '$parentFn#$name';
				registerNode(
					fnId, entry, parentFn == null ? owner : typeName, name, span, isDynamic && parentFn == null,
					noBodyKind != null && node.children.exists(c -> c.kind == noBodyKind)
				);
				if (parentFn == null) registerMember(owner, name, fnId);
				final params: Array<String> = CallGraphNames.declaredTypeParams(entry.source, span, name);
				if (params.length > 0) _facts.typeParams[fnId] = params;
				final returned: Null<String> = returnTypes[span.from];
				if (returned != null && !_facts.returns.exists(fnId)) _facts.returns[fnId] = returned;
				final written: Null<String> = returnSourceOf(node, entry.source);
				if (written != null && !_facts.returnSources.exists(fnId)) _facts.returnSources[fnId] = written;
			} else if (span != null && lambdaKinds.contains(node.kind)) {
				lambdaCounter++;
				fnId = '${parentFn ?? (typeName ?? moduleType)}#$lambdaCounter';
				registerNode(fnId, entry, typeName, null, span, false, false);
				final returned: Null<String> = returnTypes[span.from];
				if (returned != null && !_facts.returns.exists(fnId)) _facts.returns[fnId] = returned;
			}
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final c: QueryNode = kids[i];
				if (macroKind != null && c.kind == macroKind) continue;
				if (fnKinds.contains(c.kind) && MemberKinds.macroModifierPrecedes(kids, i, macroKind, modifierBoundary)) {
					// `macro` function body — compile-time code, not runtime calls
					continue;
				}
				final dyn: Bool = fnKinds.contains(c.kind) && MemberKinds.macroModifierPrecedes(kids, i, dynamicKind, modifierBoundary);
				walk(c, typeName, fnId, dyn);
			}
		}
		walk(entry.tree, null, null, false);
	}

	private function registerNode(
		id: String, entry: ParsedEntry, typeName: Null<String>, name: Null<String>, span: Span, isDynamic: Bool, isBodyless: Bool
	): Void {
		// a declaration replaces the placeholder an earlier file's call left for it
		if (!nodes.exists(id) || nodes[id]?.isExternal == true) {
			final created: FnNode = {
				id: id,
				file: entry.file,
				typeName: typeName,
				name: name,
				span: span,
				isExternal: false,
				isDynamic: isDynamic,
				isBodyless: isBodyless
			};
			nodes[id] = created;
			if (typeName != null && !_grownTypes.contains(typeName)) _grownTypes.push(typeName);
			final key: String = CallGraphNames.normalizePath(entry.file);
			final inFile: Array<FnNode> = _fileNodes[key] ?? [];
			inFile.push(created);
			_fileNodes[key] = inFile;
		}
		entry.fnBySpanFrom[span.from] = id;
		if (name == null) return;
		final ids: Array<String> = _byMember[name] ?? [];
		if (!ids.contains(id)) ids.push(id);
		_byMember[name] = ids;
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
		if (owner == null && types.chainFullyIndexed(typeName)) return null;
		return externalNode(owner ?? typeName, ctorName);
	}

	/**
	 * The written types of the parameters of function `id`, in order (`null` for one written without a
	 * type), read off its declaration; for an external target only the first, from the index. Null when the
	 * declaration cannot be read.
	 */
	private function paramTypesOf(id: String): Null<Array<Null<String>>> {
		final cached: Null<Array<Null<String>>> = _facts.paramTypes[id];
		if (cached != null) return cached;
		final n: Null<FnNode> = nodes[id];
		if (n == null) return null;
		final span: Null<Span> = n.span;
		final entry: Null<ParsedEntry> = _entries[CallGraphNames.normalizePath(n.file)];
		if (span == null || entry == null) {
			final type: Null<String> = n.typeName;
			final name: Null<String> = n.name;
			return type == null || name == null ? null : [types.memberOnChain(type, name)?.firstParamTypeSource];
		}
		final paramKinds: Array<String> = _shape.paramKinds ?? [];
		final found: Null<QueryNode> = CallGraphNames.functionNodeAt(entry.tree, span.from, _shape.functionKinds ?? []);
		if (found == null) return null;
		final sources: Map<Int, String> = _provider?.declaredTypeSources(entry.source) ?? [];
		final params: Array<QueryNode> = [for (c in found.children) if (paramKinds.contains(c.kind)) c];
		final out: Array<Null<String>> = [
			for (c in params) {
				final at: Null<Span> = c.span;
				at == null ? null : sources[at.from];
			}
		];
		if (params.length > 0 && params[params.length - 1].kind == _shape.restParamKind) _facts.restParams[id] = true;
		_facts.paramTypes[id] = out;
		return out;
	}

	/** Pseudo-node holding calls made from the instance (or, `isStatic`, the static) field initializers of `typeName`. */
	private function initNode(typeName: String, file: String, isStatic: Bool = false): String {
		final name: String = isStatic ? STATIC_INIT_NAME : INIT_NAME;
		final id: String = '$typeName.$name';
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

	private function addEdge(
		from: String, to: String, kind: EdgeKind, via: Null<String>, file: String, span: Null<Span>, ?dispatchType: String
	): Void {
		if (kind != Contains && facts?.muted.exists(from) == true) return;
		indexEdge({
			from: from,
			to: to,
			kind: kind,
			via: via,
			file: file,
			span: span,
			dispatchType: dispatchType
		});
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

	private function collectEdges(entry: ParsedEntry): Void {
		// noqa: complexity
		final shape: RefShape = _shape;
		final provider: Null<TypeInfoProvider> = _provider;
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (callKind == null || fieldAccessKind == null) return;
		final identKind: String = shape.identKind;
		final selfText: Null<String> = shape.selfReferenceText;
		final safeAccessKind: Null<String> = shape.nullSafeAccessKind;
		final forceAccessKind: Null<String> = shape.forceFieldAccessKind;
		final newExprKind: Null<String> = shape.newExprKind;
		final parenKind: Null<String> = shape.parenKind;
		final ternaryKind: Null<String> = shape.ternaryKind;
		final indexKind: Null<String> = shape.indexAccessKind;
		final assignKind: Null<String> = shape.assignKind;
		final writeParentKinds: Array<String> = shape.writeParentKinds;
		final macroKind: Null<String> = shape.macroModifierKind;
		// a local `inline function` is a function of its own like any local one, though the grammar gives it a kind apart
		final fnKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		final localFnKinds: Array<String> = (shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final nullableWrappers: Array<String> = shape.nullableWrapperTypeNames ?? [];
		final transparentWrappers: Array<String> = shape.memberTransparentWrapperTypeNames ?? [];
		final elementParams: Map<String, Int> = shape.indexedElementTypeParams ?? [];
		final accessorPrefixes: Array<String> = shape.accessorMethodPrefixes ?? [];
		final ctorName: String = shape.constructorName ?? 'new';
		final objectLiteralKind: Null<String> = shape.objectLiteralKind;
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final returnKinds: Array<String> = shape.valueReturnKinds ?? [];
		final arrayLiteralKind: Null<String> = shape.arrayLiteralKind;
		final ifExprKinds: Array<String> = shape.ifExpressionKinds ?? [];
		final switchKinds: Array<String> = shape.switchKinds ?? [];
		final caseBranchKind: Null<String> = shape.caseBranchKind;
		final blockKinds: Array<String> = [for (k in [shape.blockStmtKind, shape.exprStatementKind]) if (k != null) k];
		final mapEntryKind: Null<String> = shape.mapLiteralEntryKind;
		final objectFieldKind: Null<String> = shape.objectFieldKind;
		// call / `new` site `span.from` -> the target it resolved to and the receiver it was made on, for typing its arguments
		final sites: Map<Int, CallSite> = [];
		// the ancestors of the node being walked, outermost first, and the child index leading down from each
		final lineage: Array<QueryNode> = [];
		final lineageIndex: Array<Int> = [];
		final tree: QueryNode = entry.tree;
		final file: String = entry.file;
		final source: String = entry.source;
		final moduleType: String = CallGraphNames.moduleTypeName(file);
		final declaredTypes: Map<Int, String> = provider == null ? [] : provider.declaredTypes(source);
		final typeSources: Map<Int, String> = provider == null ? [] : provider.declaredTypeSources(source);
		final bindCache: Map<String, Map<Int, Int>> = [];
		final consumedBindCalls: Array<Int> = [];
		final frames: Array<Frame> = [];
		final staticKind: Null<String> = shape.staticModifierKind;
		final modifierBoundary: QueryNode -> Bool = c -> c.children.length > 0 || c.name != null;
		// true while the walk is inside a STATIC member's initializer, whose calls land on `<static>`
		var inStaticInit: Bool = false;

		// one Refs pass for EVERY identifier name in the file — per-name find()
		// walks made the graph build quadratic on large files
		final identNames: Array<String> = [];
		function scanIdents(node: QueryNode): Void {
			final name: Null<String> = node.name;
			if (node.kind == identKind && name != null) identNames.push(name);
			for (c in node.children) scanIdents(c);
		}
		scanIdents(tree);
		final multiHits: Map<String, Array<RefHit>> = Refs.findMulti(identNames, tree, shape);

		function bindFor(name: String): Map<Int, Int> {
			final hit: Null<Map<Int, Int>> = bindCache[name];
			if (hit != null) return hit;
			final map: Map<Int, Int> = [];
			for (h in multiHits[name] ?? []) {
				final b: Null<Span> = h.bindingSpan;
				map[h.span.from] = b == null ? -1 : b.from;
			}
			bindCache[name] = map;
			return map;
		}

		function frameId(currentType: Null<String>): String {
			return frames.length > 0 ? frames[frames.length - 1].id : initNode(currentType ?? moduleType, file, inStaticInit);
		}

		function localFn(name: String): Null<String> {
			var i: Int = frames.length - 1;
			while (i >= 0) {
				final hit: Null<String> = frames[i].localFns[name];
				if (hit != null) return hit;
				i--;
			}
			return null;
		}

		/** Whether `name` is a type parameter in scope — of a function on the frame stack or of `currentType` — naming no indexed type. */
		function isTypeParam(name: String, currentType: Null<String>): Bool {
			if (currentType != null && types.generics.declaresTypeParam(currentType, name)) return true;
			for (f in frames) if ((_facts.typeParams[f.id] ?? []).contains(name)) return true;
			return false;
		}

		/** Whether a binding at `from` lies inside a function on the frame stack — a local or a parameter, not a member. */
		function bindsLocally(from: Int): Bool {
			for (f in frames) {
				final span: Null<Span> = nodes[f.id]?.span;
				if (span != null && from >= span.from && from < span.to) return true;
			}
			return false;
		}

		function unwrap(node: QueryNode): QueryNode {
			return BoolExprShape.unwrapParens(node, parenKind);
		}

		function unresolvedAt(span: Null<Span>, reason: UnresolvedReason, currentType: Null<String>): Void {
			if (facts?.muted.exists(frameId(currentType)) == true) return;
			unresolved.push({
				file: file,
				span: span,
				from: frameId(currentType),
				reason: reason
			});
		}

		/** Declared simple type of a value identifier, `Null<T>` unwrapped to `T`. */
		function identDeclaredType(name: String, span: Span): Null<String> {
			final bindingFrom: Null<Int> = bindFor(name)[span.from];
			if (bindingFrom == null || bindingFrom < 0) return null;
			final typeName: Null<String> = declaredTypes[bindingFrom];
			return if (typeName == null)
				null
			else if (typeName == 'Null')
				CallGraphNames.unwrapNullable(typeSources[bindingFrom])
			else if (nullableWrappers.contains(typeName))
				null
			else
				typeName;
		}

		/** True for every field-access spelling a callee can wear: plain, null-safe, force-unwrapped. */
		function isAccessKind(kind: String): Bool {
			return kind == fieldAccessKind || (safeAccessKind != null && kind == safeAccessKind)
				|| (forceAccessKind != null && kind == forceAccessKind);
		}

		/** Resolve an identifier that NAMES a function — a local one, a scope-bound declaration, or a member on the type chain. */
		function identTarget(name: String, span: Null<Span>, currentType: Null<String>): Null<String> {
			if (span == null) return null;
			final local: Null<String> = localFn(name);
			if (local != null) return local;
			final bound: Null<Int> = bindFor(name)[span.from];
			return if (bound != null && bound >= 0)
				entry.fnBySpanFrom[bound]
			else if (currentType == null)
				null
			else
				memberOnChain(currentType, name);
		}

		/** The written `:Type` of `member` on `typeName`'s chain, from the index — null when no indexed type declares it. */
		function memberTypeSource(typeName: String, member: String): Null<String> {
			return types.memberOnChain(typeName, member)?.typeSource;
		}

		/**
		 * The nominal a written type denotes in member-lookup position: a member-transparent wrapper peeled, a
		 * typedef alias followed, the outer name kept. Null for a type parameter in scope — its members belong
		 * to whatever type argument the value carries, which a declared annotation does not name.
		 */
		function nominalOf(typeSource: String, currentType: Null<String>): Null<String> {
			final outer: Null<String> = NominalTypes.outerNominalOf(NominalTypes.unwrapNullable(typeSource.trim(), transparentWrappers));
			return outer == null || isTypeParam(outer, currentType) ? null : types.resolveAlias(outer);
		}

		/**
		 * `inherited`, arguments written in `viewType`'s own terms, as a value of `viewType` sees them: `viewType`'s
		 * parameters take `valueArgs` (the value's written arguments), stay when `viewType` is the enclosing type,
		 * and are unknown otherwise.
		 */
		function viewedArgs(
			inherited: Null<Array<String>>, viewType: String, valueArgs: Null<Array<String>>, currentType: Null<String>
		): Null<Array<String>> {
			final viewParams: Array<String> = types.generics.typeParamsOf(viewType);
			if (inherited == null || viewParams.length == 0 || viewType == currentType) return inherited;
			final bound: Array<String> = valueArgs != null && valueArgs.length >= viewParams.length
				? valueArgs
				: [for (_ in viewParams) UNKNOWN_TYPE];
			return [for (a in inherited) CallGraphNames.substituteTypeParams(a, viewParams, bound)];
		}

		/**
		 * `written`, a type declared on `owner`, as a value of `receiverType` (written `receiverSource`) — or, for
		 * an inherited member read without a receiver, `currentType` — sees it: every type parameter of `owner` it
		 * spells, at any depth (`Array<T>` and `Null<T>` as much as `T`), replaced by the argument the receiver
		 * writes for it or the one the viewing type's `extends` chain passes (`Box<W>.item` declared `T` is `W`).
		 * Inside `owner` itself the parameters are in scope and stay, for `nominalOf` to refuse; anywhere else a
		 * parameter nothing binds becomes `UNKNOWN_TYPE`, which names no type — so a class that happens to be
		 * named like the parameter is never taken for it, while the written outer type still resolves.
		 */
		function throughParams(
			written: String, owner: Null<String>, receiverSource: Null<String>, receiverType: Null<String>, currentType: Null<String>
		): String {
			final params: Array<String> = owner == null ? [] : types.generics.typeParamsOf(owner);
			if (owner == null || !CallGraphNames.mentionsTypeName(written, params)) return written;
			final viewType: Null<String> = receiverType ?? currentType;
			final ownArgs: Null<Array<String>> = receiverSource == null
				? null
				: NominalTypes.typeArgumentSourcesOf(NominalTypes.unwrapNullable(receiverSource.trim(), transparentWrappers));
			final args: Null<Array<String>> = if (owner == receiverType)
				ownArgs
			else if (viewType == null || viewType == owner)
				null
			else
				viewedArgs(types.generics.argumentsFor(owner, viewType), viewType, viewType == receiverType ? ownArgs : null, currentType);
			return if (args != null && args.length >= params.length)
				CallGraphNames.substituteTypeParams(written, params, args)
			else if (owner == currentType)
				written
			else
				CallGraphNames.substituteTypeParams(written, params, [for (_ in params) UNKNOWN_TYPE]);
		}

		/** `member`'s written type on `receiverType`'s chain as a value written `receiverSource` sees it (`throughParams`). */
		function memberTypeThrough(
			receiverSource: Null<String>, receiverType: String, member: String, currentType: Null<String>
		): Null<String> {
			final declared: Null<String> = memberTypeSource(receiverType, member);
			if (declared == null) return null;
			return throughParams(declared, types.declaringTypeOf(receiverType, member), receiverSource, receiverType, currentType);
		}

		/**
		 * The nominal the DECLARED return type of `target` denotes for a call made on a value of `receiverType`
		 * written `receiverSource`: a type parameter the function declares itself is unknown, one of its owner
		 * is the receiver's argument for it (`throughParams`), and a nullable or dynamic wrapper names no
		 * dispatchable type.
		 */
		function returnedNominal(
			target: String, receiverSource: Null<String>, receiverType: Null<String>, currentType: Null<String>
		): Null<String> {
			final returned: Null<String> = _facts.returns[target];
			if (returned == null || nullableWrappers.contains(returned) || (_facts.typeParams[target] ?? []).contains(returned))
				return null;
			final owner: Null<String> = nodes[target]?.typeName;
			final nominal: Null<String> = nominalOf(throughParams(returned, owner, receiverSource, receiverType, currentType), currentType);
			return nominal == null || nullableWrappers.contains(nominal) ? null : nominal;
		}

		/** The element type an index access into a value of `container`'s written type yields, per `indexedElementTypeParams`. */
		function elementTypeSource(container: String): Null<String> {
			final peeled: String = NominalTypes.unwrapNullable(container.trim(), transparentWrappers);
			final outer: Null<String> = NominalTypes.outerNominalOf(peeled);
			final at: Null<Int> = outer == null ? null : elementParams[outer];
			final args: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(peeled);
			if (at == null || args == null) return null;
			final list: Array<String> = args;
			return at >= list.length ? null : list[at];
		}

		/**
		 * What `this` denotes inside `currentType`: the type itself, or — inside an abstract — its UNDERLYING type,
		 * seen through a typedef alias, whose members a `this.m()` there reaches. Null for an abstract whose underlying
		 * type is unreadable.
		 */
		function selfTypeOf(currentType: Null<String>): Null<String> {
			if (currentType == null || !_facts.abstracts.exists(currentType)) return currentType;
			final underlying: Null<String> = _facts.abstracts[currentType];
			return underlying == null ? null : types.resolveAlias(underlying);
		}

		/** The type `recvRaw` names when it is a bare type-like identifier that binds to nothing, else null. */
		function typeNameReceiver(recvRaw: QueryNode): Null<String> {
			final recv: QueryNode = unwrap(recvRaw);
			final raw: Null<String> = recv.name;
			final span: Null<Span> = recv.span;
			if (recv.kind != identKind || raw == null || span == null) return null;
			final name: String = raw;
			if (!CallGraphNames.isTypeLike(name)) return null;
			final bound: Null<Int> = bindFor(name)[span.from];
			return bound == null || bound < 0 ? name : null;
		}

		// bound once `receiverType` exists (below): the target of a call and the receiver it was made on
		var callTargetOf: (QueryNode, Null<String>) -> Null<CallTarget> = (call, currentType) -> null;

		/**
		 * The DECLARED type source of a value expression the receiver arms below do not name: an
		 * identifier's own annotation, an inherited field read without `this` (through the index),
		 * each link of a field path, and an element `a[i]` of a container whose written type names
		 * its element. Never an inferred type: an unannotated link answers null.
		 */
		function typeSourceOf(exprRaw: QueryNode, currentType: Null<String>): Null<String> {
			final expr: QueryNode = unwrap(exprRaw);
			final name: Null<String> = expr.name;
			if (expr.kind == identKind && name != null) {
				if (name == selfText) return selfTypeOf(currentType);
				final span: Null<Span> = expr.span;
				if (span == null) return null;
				final bound: Null<Int> = bindFor(name)[span.from];
				if (bound != null && bound >= 0) return typeSources[bound];
				return currentType == null || CallGraphNames.isTypeLike(name)
					? null
					: memberTypeThrough(null, currentType, name, currentType);
			}
			if (isAccessKind(expr.kind) && name != null && expr.children.length > 0) {
				// `Type.field`: a static member, read off a type name no local shadows
				final staticOwner: Null<String> = typeNameReceiver(expr.children[0]);
				if (staticOwner != null && types.isStatic(staticOwner, name)) return memberTypeSource(staticOwner, name);
				final inner: Null<String> = typeSourceOf(expr.children[0], currentType);
				if (inner == null) return null;
				final innerSource: String = inner;
				final innerType: Null<String> = nominalOf(innerSource, currentType);
				return innerType == null ? null : memberTypeThrough(innerSource, innerType, name, currentType);
			}
			if (indexKind != null && expr.kind == indexKind && expr.children.length > 0) {
				final container: Null<String> = typeSourceOf(expr.children[0], currentType);
				return container == null ? null : elementTypeSource(container);
			}
			if (expr.kind == callKind && expr.children.length > 0) {
				// a call's written return type, as the receiver it was made on sees it
				final call: Null<CallTarget> = callTargetOf(expr, currentType);
				final returned: Null<String> = call == null ? null : _facts.returnSources[call.target];
				if (call == null || returned == null) return null;
				final written: String = returned;
				if (CallGraphNames.mentionsTypeName(written, _facts.typeParams[call.target] ?? [])) return null;
				return throughParams(written, nodes[call.target]?.typeName, call.receiverSource, call.onType, currentType);
			}
			return null;
		}

		/**
		 * Receiver classification: the simple type name plus whether the
		 * receiver is a VALUE (instance dispatch — virtual expansion applies)
		 * or a TYPE (static dispatch), and whether it is declared `Dynamic` /
		 * `Any` (dispatch by name). Null when unrecoverable.
		 */
		function receiverType(recvRaw: QueryNode, currentType: Null<String>): Null<Receiver> {
			final recv: QueryNode = unwrap(recvRaw);
			final name: Null<String> = recv.name;
			// a receiver that is itself a CALL takes the callee's DECLARED return type —
			// an annotation the source carries, never an inferred one; a nullable /
			// dynamic wrapper names no dispatchable type and stays unresolved
			if (recv.kind == callKind && recv.children.length > 0) {
				final call: Null<CallTarget> = callTargetOf(recv, currentType);
				final returned: Null<String> = call == null
					? null
					: returnedNominal(call.target, call.receiverSource, call.onType, currentType);
				return returned == null ? null : {
					typeName: returned,
					isValue: true,
					isDynamic: false
				};
			}
			if (recv.kind == identKind && name != null) {
				final span: Null<Span> = recv.span;
				if (name == selfText) {
					final self: Null<String> = selfTypeOf(currentType);
					return self == null ? null : {
						typeName: self,
						isValue: true,
						isDynamic: false
					};
				}
				if (name == 'super') {
					final superclass: Null<String> = currentType == null ? null : types.superclassOf(currentType);
					return superclass == null ? null : {
						typeName: superclass,
						isValue: false,
						isDynamic: false
					};
				}
				if (span != null) {
					final declared: Null<String> = identDeclaredType(name, span);
					if (declared != null && isTypeParam(declared, currentType)) return null;
					if (declared != null) return {
						typeName: types.resolveAlias(declared),
						isValue: true,
						isDynamic: false
					};
					final bound: Null<Int> = bindFor(name)[span.from];
					if ((bound == null || bound < 0) && CallGraphNames.isTypeLike(name)) return {
						typeName: name,
						isValue: false,
						isDynamic: false
					};
				}
			} else if (
				isAccessKind(recv.kind) && name != null && CallGraphNames.isTypeLike(name) && typeSourceOf(recv, currentType) == null
			) {
				return {
					typeName: name,
					isValue: false,
					isDynamic: false
				};
			}
			final written: Null<String> = typeSourceOf(recv, currentType);
			final nominal: Null<String> = written == null ? null : nominalOf(written, currentType);
			return nominal == null ? null : {
				typeName: nominal,
				isValue: true,
				isDynamic: nullableWrappers.contains(nominal)
			};
		}

		callTargetOf = (call, currentType) -> {
			final inner: QueryNode = unwrap(call.children[0]);
			final innerName: Null<String> = inner.name;
			if (innerName == null) return null;
			if (inner.kind == identKind) {
				final target: Null<String> = identTarget(innerName, inner.span, currentType);
				return target == null ? null : { target: target, receiverSource: null, onType: currentType };
			}
			if (!isAccessKind(inner.kind) || inner.children.length == 0) return null;
			final innerRecv: Null<Receiver> = receiverType(inner.children[0], currentType);
			final target: Null<String> = innerRecv == null || innerRecv.isDynamic ? null : memberOnChain(innerRecv.typeName, innerName);
			return target == null ? null : {
				target: target,
				receiverSource: typeSourceOf(inner.children[0], currentType),
				onType: innerRecv?.typeName
			};
		};

		/**
		 * Resolve a method referenced as a VALUE (`handler`, `this.m`, `obj?.m`) to its node — an external
		 * placeholder when the declaring type's body is not loaded yet, upgraded if it arrives — together with
		 * the receiver type an instance reference dispatches on.
		 */
		function methodRef(argRaw: QueryNode, currentType: Null<String>): Null<MethodRef> {
			final arg: QueryNode = unwrap(argRaw);
			final name: Null<String> = arg.name;
			if (name == null) return null;
			if (arg.kind == identKind) {
				final target: Null<String> = identTarget(name, arg.span, currentType);
				if (target == null) return null;
				final member: Bool = currentType != null && memberOnChain(currentType, name) == target;
				final dispatch: Null<String> = member && !types.isStatic(nodes[target]?.typeName ?? '', name) ? currentType : null;
				return { id: target, dispatch: dispatch };
			}
			if (!isAccessKind(arg.kind) || arg.children.length <= 0) return null;
			final recv: Null<Receiver> = receiverType(arg.children[0], currentType);
			if (recv == null || recv.isDynamic) return null;
			final resolved: Null<String> = memberOnChain(recv.typeName, name);
			final dispatch: Null<String> = recv.isValue ? recv.typeName : null;
			if (resolved != null) return { id: resolved, dispatch: dispatch };
			return types.functionOnChain(recv.typeName, name) || !types.chainFullyIndexed(recv.typeName)
				? { id: externalNode(types.declaringTypeOf(recv.typeName, name) ?? recv.typeName, name), dispatch: dispatch }
				: null;
		}

		function methodValue(argRaw: QueryNode, currentType: Null<String>): Null<String> {
			return methodRef(argRaw, currentType)?.id;
		}

		/** A `Ref` edge to the method `ref` names, plus one to each override an instance reference may dispatch to. */
		function refEdges(from: String, ref: MethodRef, via: Null<String>, span: Null<Span>): Void {
			addEdge(from, ref.id, Ref, via, file, span, ref.dispatch);
			final dispatch: Null<String> = ref.dispatch;
			final name: Null<String> = nodes[ref.id]?.name;
			if (dispatch != null && name != null) for (v in virtualTargets(dispatch, name))
				addEdge(from, v, Ref, via, file, span, dispatch);
		}

		function resolveBareCallee(name: String, span: Null<Span>, currentType: Null<String>): Null<String> {
			if (name == 'super') {
				final found: Null<String> = currentType == null ? null : types.superclassOf(currentType);
				if (found == null) return null;
				final superclass: String = found;
				// two declarations of the name: which one the header means is not provable by simple name
				if (types.declarationCount(superclass) > 1) {
					unresolvedAt(span, UnresolvedReceiver(ctorName), currentType);
					return null;
				}
				final target: Null<String> = constructorTarget(superclass, ctorName);
				if (facts?.muted.exists(frameId(currentType)) != true) _wiring.record({
					typeName: superclass,
					from: frameId(currentType),
					kind: Call,
					file: file,
					span: span,
					chainGrew: false,
					target: target
				});
				return target;
			}
			final local: Null<String> = localFn(name);
			if (local != null) return local;
			if (span != null) {
				final bound: Null<Int> = bindFor(name)[span.from];
				if (bound != null && bound >= 0) {
					final fn: Null<String> = entry.fnBySpanFrom[bound];
					if (fn != null) return fn;
					unresolvedAt(span, FunctionValue(name), currentType);
					return null;
				}
			}
			final inherited: Null<String> = memberOnChain(currentType ?? moduleType, name);
			if (inherited != null) return inherited;
			// a module-level function is registered under the module pseudo-type,
			// which the enclosing-type chain does not reach from inside a class
			if (currentType != null) {
				final moduleFn: Null<String> = memberOnChain(moduleType, name);
				if (moduleFn != null) return moduleFn;
				// an inherited FIELD called as a function: its value is a function the program stored
				if (types.fieldOnChain(currentType, name)) {
					unresolvedAt(span, FunctionValue(name), currentType);
					return null;
				}
				// a method a supertype the graph has not loaded declares: a placeholder, upgraded when that file arrives
				final declaring: Null<String> = types.functionOnChain(currentType, name) ? types.declaringTypeOf(currentType, name) : null;
				if (declaring != null) return externalNode(declaring, name);
			}
			// an imported static: `import p.T.f;` or `import p.T.*;` — every type that may be meant, a placeholder for one the
			// index does not list
			final imported: ImportedName = types.imports.importedStatics(file, name);
			final targets: Array<String> = [
				for (s in imported.statics) memberOnChain(s.owner, s.member) ?? externalNode(s.owner, s.member)
			];
			if (targets.length > 0) {
				for (i in 1...targets.length) addEdge(frameId(currentType), targets[i], Call, null, file, span);
				if (imported.unknown) unresolvedAt(span, UnboundName(name), currentType);
				return targets[0];
			}
			// an enum constructor builds a value and runs nothing — the language finds one by the expected type, imported or
			// not — but only when nothing else can supply the name: a static function the index holds, or a wildcard import
			// of a type whose statics it cannot list; any other unbound bare call may be a function the graph did not see
			if (imported.unknown || !types.imports.isEnumConstructor(name) || types.hasStaticFunctionNamed(name))
				unresolvedAt(span, UnboundName(name), currentType);
			return null;
		}

		/**
		 * Whether `field` read off `recv` is a stored value that can never be a method: `recv` is written as an
		 * anonymous structure (inline or through a typedef) whose `field` is declared with a type no function has.
		 */
		function storedField(recv: QueryNode, field: String, currentType: Null<String>): Bool {
			final declared: Null<String> = typeSourceOf(recv, currentType);
			if (declared == null) return false;
			final peeled: String = NominalTypes.unwrapNullable(StringTools.trim(declared), transparentWrappers);
			final outer: Null<String> = NominalTypes.outerNominalOf(peeled);
			final anon: Null<String> = outer == null ? peeled : types.resolveAlias(outer);
			final fieldType: Null<String> = if (anon == peeled)
				CallGraphNames.anonFieldTypeSource(peeled, field)
			else if (anon != null && types.holdsNoFunction(anon) && types.declarationCount(anon) > 0)
				types.memberOnChain(anon, field)?.typeSource
			else
				null;
			if (fieldType == null || fieldType.indexOf('->') >= 0) return false;
			final nominal: Null<String> = nominalOf(fieldType, currentType);
			return nominal != null && types.holdsNoFunction(nominal);
		}

		/** A method read off a receiver the graph cannot type: whatever runs the value later may run any function so named. */
		function untypedMethodRead(node: QueryNode, currentType: Null<String>): Void {
			final rawName: Null<String> = node.name;
			if (rawName == null || !isAccessKind(node.kind) || node.children.length == 0) return;
			final name: String = rawName;
			if (!(_byMember.exists(name) || types.hasFunctionNamed(name))) return;
			if (storedField(node.children[0], name, currentType)) return;
			final recv: Null<Receiver> = receiverType(node.children[0], currentType);
			if ((recv == null || recv.isDynamic) && facts?.muted.exists(frameId(currentType)) != true) unresolvedAccess.push({
				file: file,
				span: node.span,
				from: frameId(currentType),
				member: name,
				write: false,
				dynamicReceiver: recv != null
			});
		}

		/**
		 * The function values `args` (from `first` on) hand the callee
		 * `calleeId`: lambdas, method values, `.bind` results, both ternary arms.
		 */
		function scanArgs(args: Array<QueryNode>, first: Int, calleeId: Null<String>, currentType: Null<String>): Void {
			final from: String = frameId(currentType);
			function refArg(argRaw: QueryNode): Void {
				final arg: QueryNode = unwrap(argRaw);
				// a ternary-valued argument hands BOTH branch function-values to
				// the callee — each branch is a callback in its own right
				if (ternaryKind != null && arg.kind == ternaryKind && arg.children.length == 3) {
					refArg(arg.children[1]);
					refArg(arg.children[2]);
					return;
				}
				final argSpan: Null<Span> = arg.span;
				if (argSpan != null && lambdaKinds.contains(arg.kind)) {
					final lambdaId: Null<String> = entry.fnBySpanFrom[argSpan.from];
					if (lambdaId != null) addEdge(from, lambdaId, Ref, calleeId, file, argSpan);
					return;
				}
				if (arg.kind == callKind && arg.children.length > 0) {
					final inner: QueryNode = unwrap(arg.children[0]);
					if (isAccessKind(inner.kind) && inner.name == 'bind' && inner.children.length > 0) {
						final ref: Null<MethodRef> = methodRef(inner.children[0], currentType);
						if (ref != null && argSpan != null) {
							refEdges(from, ref, calleeId, argSpan);
							consumedBindCalls.push(argSpan.from);
						}
					}
					return;
				}
				if (arg.kind != identKind && !isAccessKind(arg.kind)) return;
				final ref: Null<MethodRef> = methodRef(arg, currentType);
				if (ref != null)
					refEdges(from, ref, calleeId, argSpan);
				else
					untypedMethodRead(arg, currentType);
			}
			for (i in first ... args.length) refArg(args[i]);
		}

		/**
		 * Virtual dispatch targets for a BARE call inside `typeName` — the implicit-`this` case,
		 * where `resolved` is the node the bare name already resolved to. Empty unless that node
		 * is a NON-STATIC member on the type's own chain: a local function, a module-level
		 * function and `super` each yield an id `memberOnChain` never returns, and Haxe neither
		 * inherits nor overrides a static, so a same-named static on a subtype is a DIFFERENT
		 * function that dispatch can never reach.
		 */
		function implicitThisTargets(typeName: Null<String>, member: String, resolved: String): Array<String> {
			if (typeName == null || memberOnChain(typeName, member) != resolved) return [];
			final owner: String = nodes[resolved]?.typeName ?? typeName;
			return types.isStatic(owner, member) ? [] : virtualTargets(typeName, member);
		}

		function handleCall(call: QueryNode, currentType: Null<String>): Void {
			final from: String = frameId(currentType);
			final span: Null<Span> = call.span;
			final callee: QueryNode = unwrap(call.children[0]);
			final calleeName: Null<String> = callee.name;
			var calleeId: Null<String> = null;
			if (callee.kind == identKind && calleeName != null) {
				calleeId = resolveBareCallee(calleeName, callee.span, currentType);
				if (calleeId != null) {
					final implicitThis: Array<String> = implicitThisTargets(currentType, calleeName, calleeId);
					// a placeholder for a member a supertype not loaded yet declares is on the chain too
					final placeholder: Bool = nodes[calleeId]?.isExternal == true && currentType != null
						&& types.declaringTypeOf(currentType, calleeName) == nodes[calleeId]?.typeName;
					final dispatched: Bool = currentType != null && (memberOnChain(currentType, calleeName) == calleeId || placeholder)
						&& !types.isStatic(nodes[calleeId]?.typeName ?? currentType, calleeName);
					addEdge(from, calleeId, Call, null, file, span, dispatched ? currentType : null);
					// a bare call to an instance member IS `this.m()` — same dispatch, same edges
					for (v in implicitThis) addEdge(from, v, Virtual, null, file, span, currentType);
					if (nodes[calleeId]?.isDynamic == true) unresolvedAt(span, FunctionValue(calleeName), currentType);
				}
			} else if (isAccessKind(callee.kind)) {
				if (calleeName != null && callee.children.length > 0) {
					if (calleeName == 'bind') {
						final callSpan: Null<Span> = call.span;
						if (callSpan == null || !consumedBindCalls.contains(callSpan.from)) {
							final ref: Null<MethodRef> = methodRef(callee.children[0], currentType);
							if (ref != null) refEdges(from, ref, null, span);
						}
					} else {
						final written: Null<Receiver> = receiverType(callee.children[0], currentType);
						if (written == null) {
							unresolvedAt(span, UnresolvedReceiver(calleeName), currentType);
						} else if (written.isDynamic) {
							unresolvedAt(span, DynamicReceiver(calleeName), currentType);
						} else {
							// a `@:forward` abstract routes a member it does not declare to its underlying value
							final forwarded: Null<String> = memberOnChain(written.typeName, calleeName) == null
								&& types.memberOnChain(written.typeName, calleeName) == null
								? types.meta.forwardedTo(written.typeName, calleeName)
								: null;
							final recv: Receiver = forwarded == null ? written : { typeName: forwarded, isValue: true, isDynamic: false };
							final resolved: Null<String> = memberOnChain(recv.typeName, calleeName);
							if (resolved == null && types.fieldOnChain(recv.typeName, calleeName)) {
								unresolvedAt(span, FunctionValue(calleeName), currentType);
							} else if (
								resolved == null && recv.isValue && types.chainFullyIndexed(recv.typeName)
								&& types.memberOnChain(recv.typeName, calleeName) == null
							) {
								// no indexed type on the chain declares it: a static extension a `using` brings in, else unresolved
								final extensions: Array<String> = types.imports.staticExtensionsOf(file, calleeName);
								if (extensions.length == 0) unresolvedAt(span, UnresolvedReceiver(calleeName), currentType);
								for (extension in extensions) {
									calleeId = memberOnChain(extension, calleeName) ?? externalNode(extension, calleeName);
									addEdge(from, calleeId, Call, null, file, span);
								}
							} else {
								// a placeholder names the type the index says declares it, which is the node its file upgrades
								calleeId = resolved ?? externalNode(
									types.declaringTypeOf(recv.typeName, calleeName) ?? recv.typeName, calleeName
								);
								addEdge(from, calleeId, Call, null, file, span, recv.isValue ? recv.typeName : null);
								if (recv.isValue) for (v in virtualTargets(recv.typeName, calleeName))
									addEdge(from, v, Virtual, null, file, span, recv.typeName);
								if (nodes[calleeId]?.isDynamic == true) unresolvedAt(span, FunctionValue(calleeName), currentType);
							}
						}
					}
				} else {
					unresolvedAt(span, ComplexCallee(callee.kind), currentType);
				}
			} else if (callee.kind == callKind || (newExprKind != null && callee.kind == newExprKind)) {
				unresolvedAt(span, FunctionValue('expression result'), currentType);
			} else {
				unresolvedAt(span, ComplexCallee(callee.kind), currentType);
			}
			if (span != null) sites[span.from] = {
				target: calleeId,
				receiver: isAccessKind(callee.kind) && callee.children.length > 0 ? callee.children[0] : null
			};
			scanArgs(call.children, 1, calleeId, currentType);
		}

		/** A constructor run on `typeName` at `span`: the `New` edge to the constructor it names, and the wiring to its initializers. */
		function constructionRun(typeName: String, span: Null<Span>, currentType: Null<String>): Null<String> {
			final from: String = frameId(currentType);
			final target: Null<String> = constructorTarget(typeName, ctorName);
			if (target != null) addEdge(from, target, New, null, file, span);
			if (facts?.muted.exists(from) != true) _wiring.record({
				typeName: typeName,
				from: from,
				kind: New,
				file: file,
				span: span,
				chainGrew: false,
				target: target
			});
			return target;
		}

		function handleNew(node: QueryNode, currentType: Null<String>): Void {
			final rawName: Null<String> = node.name;
			if (rawName == null) return;
			final typeName: String = CallGraphNames.lastSegments(rawName, 1);
			final target: Null<String> = constructionRun(typeName, node.span, currentType);
			final span: Null<Span> = node.span;
			if (span != null) sites[span.from] = { target: target, receiver: null };
			// constructor args can carry callbacks / lambdas too
			scanArgs(node.children, 0, target, currentType);
		}

		/** The written type of parameter `index` of the call target `site` resolved to, as its receiver sees it. */
		function argumentTypeSource(site: CallSite, index: Int, currentType: Null<String>): Null<String> {
			final target: Null<String> = site.target;
			final params: Null<Array<Null<String>>> = target == null ? null : paramTypesOf(target);
			// a rest parameter takes every argument from its position on
			final at: Int = params != null && target != null && _facts.restParams.exists(target)
				? Std.int(Math.min(index, params.length - 1))
				: index;
			final param: Null<String> = params == null || at >= params.length ? null : params[at];
			if (target == null || param == null) return null;
			final written: String = param;
			if (CallGraphNames.mentionsTypeName(written, _facts.typeParams[target] ?? [])) return null;
			final receiver: Null<QueryNode> = site.receiver;
			final receiverSource: Null<String> = receiver == null ? null : typeSourceOf(receiver, currentType);
			final onType: Null<String> = receiver == null ? null : receiverType(receiver, currentType)?.typeName;
			return throughParams(written, nodes[target]?.typeName, receiverSource, onType, currentType);
		}

		/**
		 * The type a `return` at `lineage[level]` is expected to have: the declared return type of the function
		 * or lambda enclosing it, or for an unannotated lambda the return type of the function type the lambda is
		 * itself expected to be (`expected`, which is `expectedAt`, asked strictly further out).
		 */
		function returnExpectation(level: Int, currentType: Null<String>, expected: (Int, Null<String>) -> Null<String>): Null<String> {
			var at: Int = level - 1;
			while (at >= 0 && !(fnKinds.contains(lineage[at].kind) || lambdaKinds.contains(lineage[at].kind))) at--;
			if (at < 0) return null;
			final span: Null<Span> = lineage[at].span;
			final id: Null<String> = span == null ? null : entry.fnBySpanFrom[span.from];
			final declared: Null<String> = id == null ? null : _facts.returns[id];
			if (declared != null || !lambdaKinds.contains(lineage[at].kind)) return declared;
			return CallGraphNames.functionReturnSource(expected(at - 1, currentType) ?? '');
		}

		/** The written type of field `field` of a value written `outer`: an inline anonymous structure's, or a typedef's or class's member. */
		function fieldTypeSource(outer: String, field: String, currentType: Null<String>): Null<String> {
			final peeled: String = NominalTypes.unwrapNullable(outer.trim(), transparentWrappers);
			final written: Null<String> = CallGraphNames.anonFieldTypeSource(peeled, field);
			if (written != null) return written;
			final nominal: Null<String> = nominalOf(peeled, currentType);
			return nominal == null ? null : memberTypeThrough(peeled, nominal, field, currentType);
		}

		/**
		 * The written type the value at child `lineage[level].index` of `lineage[level].node` is expected to have:
		 * a declaration's annotation, an assignment's target, the enclosing function's return type (a lambda's
		 * from the function type it is typed as), the parameter of the call or constructor it is an argument of
		 * (every element of a rest parameter), the element of the array or the value of the map literal it sits
		 * in, the field of the object literal it initialises — through parentheses, ternary / `if` / `switch`
		 * arms and the value a block ends with. Null where nothing written says.
		 */
		function expectedAt(level: Int, currentType: Null<String>): Null<String> {
			if (level < 0) return null;
			final holder: QueryNode = lineage[level];
			final index: Int = lineageIndex[level];
			final span: Null<Span> = holder.span;
			final kind: String = holder.kind;
			final last: Bool = index == holder.children.length - 1;
			return if (localDeclKinds.contains(kind) || fieldKinds.contains(kind))
				span == null ? null : typeSources[span.from]
			else if (kind == assignKind && index == 1)
				typeSourceOf(holder.children[0], currentType)
			else if (returnKinds.contains(kind))
				returnExpectation(level, currentType, expectedAt)
			else if (lambdaKinds.contains(kind) && last)
				CallGraphNames.functionReturnSource(expectedAt(level - 1, currentType) ?? '')
			else if (
				kind == parenKind || (kind == ternaryKind && index >= 1) || (ifExprKinds.contains(kind) && index >= 1)
				|| (switchKinds.contains(kind) && index >= 1) || ((kind == caseBranchKind || blockKinds.contains(kind)) && last)
			)
				expectedAt(level - 1, currentType)
			else if (kind == arrayLiteralKind) {
				final outer: Null<String> = expectedAt(level - 1, currentType);
				outer == null ? null : elementTypeSource(outer);
			} else if (kind == mapEntryKind && index == 1 && level > 0 && lineage[level - 1].kind == arrayLiteralKind) {
				final outer: Null<String> = expectedAt(level - 2, currentType);
				outer == null ? null : elementTypeSource(outer);
			} else if (kind == objectFieldKind && level > 0 && lineage[level - 1].kind == objectLiteralKind) {
				final outer: Null<String> = expectedAt(level - 2, currentType);
				final field: Null<String> = holder.name;
				outer == null || field == null ? null : fieldTypeSource(outer, field, currentType);
			} else if ((kind == callKind && index >= 1) || kind == newExprKind) {
				final site: Null<CallSite> = span == null ? null : sites[span.from];
				site == null ? null : argumentTypeSource(site, kind == callKind ? index - 1 : index, currentType);
			} else
				null;
		}

		/**
		 * An object literal whose expected type (`expectedAt`) is a class the language CONSTRUCTS from a literal
		 * (`ExecutionShape.implicitConstructionTypeMetaNames`): the `New` edge and constructor run a `new` would carry.
		 */
		function handleConstructionLiteral(node: QueryNode, currentType: Null<String>): Void {
			final written: Null<String> = expectedAt(lineage.length - 1, currentType);
			final found: Null<String> = written == null ? null : nominalOf(written, currentType);
			if (found != null && types.meta.constructsFromLiteral(found)) constructionRun(found, node.span, currentType);
		}

		/**
		 * Whether the innermost frame is the accessor `accessor` itself: inside a getter, reading its property
		 * on `this` reads the stored field; inside a setter, WRITING it writes the field — but a read there still
		 * runs the getter.
		 */
		function insideAccessor(accessor: String): Bool {
			return frames.length > 0 && nodes[frames[frames.length - 1].id]?.name == accessor;
		}

		/**
		 * A read or write of a property whose accessor runs code: an `Accessor` edge to `get_x` /
		 * `set_x` (plus the overrides an instance dispatch reaches), resolved through the receiver's
		 * static type. A name no indexed type declares as such a property is skipped outright; one
		 * whose receiver cannot be typed is recorded in `unresolvedAccess`.
		 */
		function handleAccess(node: QueryNode, parent: Null<QueryNode>, childIndex: Int, currentType: Null<String>): Void {
			final rawName: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (rawName == null || span == null || accessorPrefixes.length < 2 || !types.hasPropertyNamed(rawName)) return;
			final name: String = rawName;
			final writeSlot: Bool = parent != null && childIndex == 0 && writeParentKinds.contains(parent.kind);
			final reads: Bool = !(writeSlot && parent?.kind == assignKind);
			var owner: Null<String> = null;
			var isValue: Bool = true;
			// the stored field is what the name can mean inside its own accessor — on `this`, never on another object
			var ownStorage: Bool = false;
			if (node.kind == identKind) {
				final bound: Null<Int> = bindFor(name)[span.from];
				if (bound != null && bound >= 0 && bindsLocally(bound)) return;
				owner = currentType;
				ownStorage = true;
			} else if (isAccessKind(node.kind) && node.children.length > 0) {
				ownStorage = unwrap(node.children[0]).kind == identKind && unwrap(node.children[0]).name == selfText;
				final recv: Null<Receiver> = receiverType(node.children[0], currentType);
				if (recv == null || recv.isDynamic) {
					if (facts?.muted.exists(frameId(currentType)) == true) return;
					unresolvedAccess.push({
						file: file,
						span: span,
						from: frameId(currentType),
						member: name,
						write: writeSlot,
						dynamicReceiver: recv != null
					});
					return;
				}
				owner = recv.typeName;
				isValue = recv.isValue;
			}
			if (owner == null) return;
			final ownerType: String = owner;
			final found: Null<{ info: MemberInfo, owner: String }> = types.propertyOnChain(ownerType, name);
			if (found == null) return;
			final prop: { info: MemberInfo, owner: String } = found;
			final from: String = frameId(currentType);
			final dispatch: Null<String> = isValue ? ownerType : null;
			function accessorEdge(prefix: String): Void {
				final accessor: String = prefix + name;
				final declared: Null<String> = memberOnChain(ownerType, accessor);
				// an interface declares the property but no accessor body: the edge names a body-less declaration,
				// which a consumer follows for dispatch to the implementations only
				final target: String = if (declared != null)
					declared
				else if (types.isInterface(prop.owner))
					externalNode(prop.owner, accessor, true)
				else
					externalNode(prop.owner, accessor);
				addEdge(from, target, Accessor, null, file, span, dispatch);
				if (isValue) for (v in virtualTargets(ownerType, accessor)) addEdge(from, v, Virtual, null, file, span, ownerType);
			}
			if (reads && prop.info.hasGetter && !(ownStorage && insideAccessor(accessorPrefixes[0] + name)))
				accessorEdge(accessorPrefixes[0]);
			if (writeSlot && prop.info.hasSetter && !(ownStorage && insideAccessor(accessorPrefixes[1] + name)))
				accessorEdge(accessorPrefixes[1]);
		}

		/**
		 * A function used as a VALUE anywhere a call argument does not already cover — an assignment
		 * right-hand side, a `return`, an array or object literal, a local initializer: the `Ref` edge
		 * a later invocation of that value needs. Callee, argument, constructor-argument and receiver
		 * positions are skipped; their own handlers own them.
		 */
		function handleValueUse(node: QueryNode, parent: Null<QueryNode>, childIndex: Int, currentType: Null<String>): Void {
			if (parent != null) {
				final pk: String = parent.kind;
				if ((pk == callKind && childIndex == 0) || isAccessKind(pk)) return;
				if (childIndex == 0 && writeParentKinds.contains(pk)) return;
			}
			final span: Null<Span> = node.span;
			if (span == null) return;
			if (lambdaKinds.contains(node.kind)) {
				final lambdaId: Null<String> = entry.fnBySpanFrom[span.from];
				if (lambdaId != null) addEdge(frameId(currentType), lambdaId, Ref, null, file, span);
				return;
			}
			final rawName: Null<String> = node.name;
			if (rawName == null || !(_byMember.exists(rawName) || localFn(rawName) != null || types.hasFunctionNamed(rawName))) return;
			final name: String = rawName;
			final ref: Null<MethodRef> = methodRef(node, currentType);
			if (ref != null)
				refEdges(frameId(currentType), ref, null, span);
			else
				untypedMethodRead(node, currentType);
		}


		/** Whether child `i` of `node` is a call / constructor ARGUMENT value slot, which `scanArgs` / `handleNew` own. */
		function argumentSlot(node: QueryNode, i: Int, inArgument: Bool): Bool {
			return (node.kind == callKind && i >= 1) || (newExprKind != null && node.kind == newExprKind)
				|| (inArgument && (node.kind == parenKind || (node.kind == ternaryKind && i >= 1)));
		}

		function walk(
			node: QueryNode, currentType: Null<String>, parent: Null<QueryNode>, childIndex: Int, inArgument: Bool
		): Void {
			// symmetric with collectNodes: reified code is not runtime calls
			if (opaqueKinds.contains(node.kind)) return;
			final typeName: Null<String> = CallGraphNames.typeNameOf(node) ?? currentType;

			if (!inArgument && (node.kind == identKind || isAccessKind(node.kind) || lambdaKinds.contains(node.kind)))
				handleValueUse(node, parent, childIndex, typeName);

			final span: Null<Span> = node.span;
			var pushed: Bool = false;
			if (span != null && (fnKinds.contains(node.kind) || lambdaKinds.contains(node.kind))) {
				final id: Null<String> = entry.fnBySpanFrom[span.from];
				if (id != null) {
					final ownId: String = id;
					final name: Null<String> = node.name;
					if (name != null && localFnKinds.contains(node.kind) && frames.length > 0)
						frames[frames.length - 1].localFns[name] = ownId;
					if (frames.length > 0)
						addEdge(frames[frames.length - 1].id, ownId, Contains, null, file, span);
					else if (lambdaKinds.contains(node.kind))
						// a member-initializer lambda (`final onTick = () -> ...`) has no
						// enclosing frame — anchor it to the type's <init> pseudo-node so
						// reach/callers can still traverse into its body
						addEdge(initNode(typeName ?? moduleType, file, inStaticInit), ownId, Contains, null, file, span);
					frames.push({ id: ownId, localFns: [] });
					pushed = true;
				}
			}

			if (node.kind == callKind && node.children.length > 0)
				handleCall(node, typeName);
			else if (newExprKind != null && node.kind == newExprKind)
				handleNew(node, typeName);
			if (node.kind == identKind || isAccessKind(node.kind)) handleAccess(node, parent, childIndex, typeName);
			if (objectLiteralKind != null && node.kind == objectLiteralKind) handleConstructionLiteral(node, typeName);

			var macroPending: Bool = false;
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final c: QueryNode = kids[i];
				if (macroKind != null && c.kind == macroKind) {
					macroPending = true;
					continue;
				}
				if (macroPending && fnKinds.contains(c.kind)) {
					// `macro` function body — compile-time code, not runtime calls
					macroPending = false;
					continue;
				}
				if (c.children.length > 0 || c.name != null) macroPending = false;
				final savedStatic: Bool = inStaticInit;
				if (frames.length == 0 && MemberKinds.macroModifierPrecedes(kids, i, staticKind, modifierBoundary)) inStaticInit = true;
				lineage.push(node);
				lineageIndex.push(i);
				walk(c, typeName, node, i, argumentSlot(node, i, inArgument));
				lineage.pop();
				lineageIndex.pop();
				inStaticInit = savedStatic;
			}
			if (pushed) frames.pop();
		}
		walk(tree, null, null, 0, false);
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
			return new CallGraph(cached, shape, provider, new CallGraphTypes(null, shape), null);
		final types: CallGraphTypes = new CallGraphTypes(index ?? SymbolIndex.build(files, cached), shape);
		final graph: CallGraph = new CallGraph(cached, shape, provider, types, facts == null ? null : new CallGraphFacts(facts));
		graph.addFiles(files);
		return graph;
	}

}

private typedef ParsedEntry = {
	var file: String;
	var source: String;
	var tree: QueryNode;
	var fnBySpanFrom: Map<Int, String>;
}

private typedef Frame = {
	var id: String;
	var localFns: Map<String, String>;
}

/** A method referenced as a value: its node, and the receiver type an instance reference dispatches on (null for a static one). */
private typedef MethodRef = {
	var id: String;
	var dispatch: Null<String>;
}

/** What a call or `new` site resolved to: the target, and the receiver expression a call through a field access was made on. */
private typedef CallSite = {
	var target: Null<String>;
	var receiver: Null<QueryNode>;
}

private typedef Receiver = {
	var typeName: String;
	var isValue: Bool;
	var isDynamic: Bool;
}

/** A call's resolved target, and the written type and type of the receiver it was made on (null for a bare call). */
private typedef CallTarget = {
	var target: String;
	var receiverSource: Null<String>;
	var onType: Null<String>;
}
