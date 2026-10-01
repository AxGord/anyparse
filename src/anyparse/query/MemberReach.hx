package anyparse.query;

import anyparse.check.OracleCoverage;
import anyparse.query.CallGraph.CallEdge;
import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.CallGraph.FnDeclaration;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.CallGraph.SplicedSite;
import anyparse.query.CallGraph.UnresolvedAccess;
import anyparse.query.CallGraph.UnresolvedCall;
import anyparse.query.CallGraphFacts.QualifiedRead;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.FactsView.TruthSites;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.ImplicitSites.ImplicitSite;
import anyparse.query.MemberTouchScan.FreshContext;
import anyparse.query.MemberTouchScan.MemberTouches;
import anyparse.query.MemberTouchScan.Occurrence;
import anyparse.query.ReachAdmission.Admission;
import anyparse.query.ReachGraph.OwnedId;
import anyparse.query.ReachHazards.ReachHazard;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.ReachLiveness.ReachConfiguration;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.ValueCarriers.CarryRelation;
import anyparse.runtime.Span;

using Lambda;

/**
 * What the question asks the reached code to do to the member. `Mutate` is a
 * write, or a change to the object the member holds through ANY alias of it.
 */
enum ReachAccess {

	Read;
	Write;
	Mutate;

}

/**
 * Where execution starts: the invocations at `sites` in `file` (a call, a `new`, a property access whose
 * accessor runs code), or everything a `Region` of `file` runs — its calls, constructors, accessors and the
 * lambdas it creates, plus its own direct touches of the member.
 */
enum ReachEntry {

	Calls(file: String, sites: Array<QueryNode>);
	Region(file: String, span: Span);

}

/** One hop of a `Reached` path: an edge of the call graph, or a site the walk admitted through a blind channel (`kind` says which). */
typedef ReachStep = {
	var from: String;
	var to: String;
	var kind: String;
	var file: String;
	var span: Null<Span>;
}

/** Why `Proven` could not be reached although no path to the member was found either. Every variant names where it was met. */
enum ReachUnknown {

	/** A file the member's touchers or the reached code may live in did not parse. */
	SkipParse(file: String);

	/** A conditional-compilation region the parser kept raw sits on the path or spells the member. */
	OpaqueCond(file: String, span: Span);

	/** A build macro can rewrite a type on the path, or the member's owner. */
	Reification(file: String, span: Null<Span>);

	/** Reached code switches the typer off. */
	Untyped(file: String, span: Span);

	/** A reached call names a target no indexed type declares. */
	UnresolvedDispatch(file: String, span: Null<Span>, what: String);

	/** Reached code reflects on a member whose name it computes. */
	DynamicName(file: String, span: Span);

	/**
	 * The member's value is shared: it flows out of the member or arrives
	 * from elsewhere, so an alias may be changed by code that never names it.
	 */
	Escape(file: String, span: Span);

	/** A value shared at `shared` of `file` meets code at `culprit` of `culpritFile` that may change it through another name. */
	Aliased(file: String, shared: Span, culpritFile: String, culprit: Span);

	/** Reached code hands text to the target language. */
	NativeCode(file: String, span: Span);

	/** Reached code holds a construct the grammar does not declare modelled (`ExecutionShape.modelledKinds`). */
	Unmodelled(file: String, span: Span, kind: String);

	/**
	 * A type on the path shares its simple name with another declaration, so its members are
	 * not provably its own. Under the truth a declaration in a file no build read is none,
	 * declarations of the one type the builds typed are that type (`FactsView.soleType`), and
	 * a call whose fact names the type it calls enters that type's member alone
	 * (`CallGraphFacts.qualify`), as does an implicit-call site whose facts name its operands'
	 * types (`ReachGraph.ownedIdsAt`): the name stays shared only where the walk enters it by
	 * an edge or an admission no fact names an owner of — the syntax's, a dispatch's, one of a
	 * value of any type.
	 */
	Ambiguous(typeName: String);

	/** The run does not hold every file a toucher could live in. */
	OutOfScope(what: String);

	/** The walk into library code grew past its bound. */
	Budget(what: String);

}

/** The answer: no reached code can do the asked thing to the member, a path that does, or the first blind spot that stops a proof. */
enum ReachResult {

	Proven;
	Reached(path: Array<ReachStep>);
	Unknown(reason: ReachUnknown);

}

/** A member by its declaring owner's simple name and its own name. */
typedef MemberRef = {
	var owner: String;
	var name: String;
}

/**
 * "May the code this entry runs read / write / mutate member M?" — one analysis with three answers, for
 * every check whose fix is sound only when nothing it cannot see reaches M.
 *
 * TOUCHERS are the functions that access M BY BINDING (a bare `M` that is not a local, `this.M`, `obj.M`
 * whose receiver resolves to a type M's declaration belongs to, or does not resolve at all). For `Mutate`
 * a toucher also changes the object M holds (`M.push`, `M[i] = v`), and a read that lets M's value go
 * anywhere else — an argument, a store, a `return` — or an assignment of a value that was not freshly
 * built, is an ESCAPE: an alias exists that code which never names M can change.
 *
 * `Proven` is POSITIVE: the entry and every body the walk reaches — each declaration a graph node folds, one per branch
 * of a conditional region (`CallGraph.declarationsOf`), and every field initializer a construction runs — pass
 * `ReachHazards`' whitelist of modelled node kinds, and every way the graph shows them running code was followed. The walk goes forward
 * over calls, constructors, overrides, accessors and function values, and grows the graph into library
 * files only when it reaches a target declared there. Code the graph cannot follow is admitted through
 * channels: an unresolved call (a function value, a Dynamic or untyped receiver, a body-less extern) may run
 * any function used as a value or overriding a library method, a call through an unknown receiver any
 * function of the same name, and ANY code any function the language calls implicitly — an operator,
 * conversion, index, string conversion, iteration, literal construction; every admission is narrowed to the
 * functions that can themselves reach a toucher, and re-run whenever the graph grew. Where the compiler facts are
 * the truth, code read through them runs an implicitly-called member without a call the graph holds only at a
 * string conversion — a thrown value is one — or an iteration, so a channel that can run no code read by its syntax
 * admits only those (`ReachAdmission.runsSyntaxRead`, `ReachGraph.typedImplicitIds`). Reflection by a literal
 * name is a hand-off it follows; by a computed name, native code, untyped code, a raw conditional region, an unmodelled
 * construct, a build macro, an ambiguous type name or an unparsed file is `Unknown` — a build macro, where the compiler facts
 * are the truth (`FactsView.truth`), only when they show the code it made of a type is not the text (`ReachGraph.rewrittenBy`);
 * what they show a method it made or placed elsewhere touching is found all the same (`CallGraphFacts.adopt`). Under the
 * truth a call whose fact names which of the types sharing a name it calls enters that one's member alone — its
 * declarations, facts, touches and build macros (`qualifiedNode`) — and so does a member a string conversion or an
 * iteration the facts typed admits, of each type a value of the operand's type may be (`ReachGraph.ownedIdsAt`): the name
 * is ambiguous only where no fact says. A node every declaration of which lies in code no configured build compiles
 * runs nothing (`ReachLiveness.live`), however the walk came to it.
 */
@:nullSafety(Strict)
final class MemberReach {

	/** How many library files the walk may add to the graph before it gives up on a proof, by default. */
	public static inline final MAX_LIBRARY_FILES: Int = 600;

	/** How many graph nodes the walk may visit before it gives up on a proof, by default. */
	public static inline final MAX_VISITED: Int = 60000;

	/** How deep a chain of calls handing a fresh value on (`freshCall`) is followed before the value counts as shared. */
	private static inline final MAX_FRESH_DEPTH: Int = 4;

	/** The step kind of a constructor the walk admitted through reflective instantiation. */
	private static inline final REFLECTIVE_CONSTRUCTOR: String = 'reflective constructor';

	/**
	 * A typed variable's kind (`FieldDeclFact.kind`) read straight from its storage (`readStraight`): a `default` or `null`
	 * read, and a write that is a field write, a setter call, or none.
	 */
	private static final STRAIGHT_PROPERTY: EReg = ~/^var\((default|null),(default|null|never|ctor|call)\)$/;

	private final _projectSources: Map<String, String> = [];

	/** This analysis's visited-node cap. */
	private final _maxVisited: Int;

	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;
	private final _index: SymbolIndex;
	private final _project: Array<{ file: String, source: String }>;
	private final _scopeKnown: Bool;
	private final _hazards: ReachHazards;
	private final _touches: MemberTouchScan;

	/** The call graph and its on-demand growth into the library. */
	private final _g: ReachGraph;

	/** What every part of the analysis reads the project through. */
	private final _scope: ReachProject;

	/** Which functions code the graph cannot follow may enter. */
	private final _admission: ReachAdmission;

	/** Which code the configured builds may compile: the rest is never walked. */
	private final _live: ReachLiveness;

	/** Whether a value of one type may carry another type's member: the one relation every part of the analysis asks. */
	private final _carriers: ValueCarriers;

	/** The types whose instances may have left the type system, which `_carriers` adds to every value's. */
	private final _escapes: ValueEscapes;

	/** Builds the analysis under the run's configured builds (`escalation`), or answers null when the run has none; dropped once called. */
	private var _configure: Null<() -> Null<MemberReach>> = null;

	/** The analysis `_configure` built, once a question escalated. */
	private var _configured: Null<MemberReach> = null;

	/** Set when the current question met a raw conditional region: the configured builds may decide it (`escalation`). */
	private var _metRawRegion: Bool = false;

	/**
	 * Set when the current question entered code read by its syntax rather than its compiler facts: a conversion or a
	 * field-name fallback may run there without a call the graph holds, so every such function is admitted. An admission of code the walk
	 * never enters sets it too, unless the facts are the truth and that code is all read through them (`ReachAdmission.runsSyntaxRead`).
	 */
	private var _syntaxEntered: Bool = false;

	/** What `_configure` was set to, for building the analysis under the builds again after a refresh it could not take. */
	private var _reconfigure: Null<() -> Null<MemberReach>> = null;

	/**
	 * Whether the run's compiler facts may be the truth under its builds (`FactsView.truth`): every question this analysis
	 * cannot prove is then asked under them (`escalation`), where the facts may prove it.
	 */
	private var _factsTruthAvailable: Bool = false;

	/**
	 * `project` is every file a toucher of a project member can live in; `index` resolves types over at
	 * least that and, when wider, over the libraries the walk may grow into. `scopeKnown` false means the
	 * project may hold files `project` does not, so only a fresh unshared local is ever `Proven`. `configurations`
	 * are the builds an answer must hold under: a conditional branch none of them compiles is not walked, and with
	 * none every branch is. `facts` are the compiler's facts of the run's builds: a function they describe whole is read
	 * through them (`FactsView`), every other one through its syntax; facts naming exactly `configurations` are the
	 * truth (`factsAreTruth`), and then a project file no build read is out of `index` too (`ReachProject.readThrough`).
	 */
	public function new(
		plugin: GrammarPlugin, project: Array<{ file: String, source: String }>, index: SymbolIndex, scopeKnown: Bool,
		maxLibraryFiles: Int = MAX_LIBRARY_FILES, maxVisited: Int = MAX_VISITED, ?configurations: Array<ReachConfiguration>,
		?classpathComplete: () -> Bool, ?facts: CompilerFacts
	) {
		_maxVisited = maxVisited;
		final cached: GrammarPlugin = plugin is CachingGrammarPlugin ? plugin : new CachingGrammarPlugin(plugin);
		_plugin = cached;
		_shape = _plugin.refShape();
		_project = project;
		_scopeKnown = scopeKnown;
		for (f in project) _projectSources[f.file] = f.source;
		_hazards = new ReachHazards(_plugin);
		final scope: ReachProject = new ReachProject(cached, index, project);
		final live: ReachLiveness = new ReachLiveness(cached, configurations ?? []);
		_scope = scope;
		_live = live;
		// a touch in code no configured build compiles touches nothing; the project's current text decides
		// no answer about the classpath is the answer that some compiled code is outside the index
		var escapes: Null<ValueEscapes> = null;
		final carriers: ValueCarriers = new ValueCarriers(scope, classpathComplete ?? () -> false, () -> {
			final held: Null<ValueEscapes> = escapes;
			held == null ? null : held.escaped();
		}, configurations != null && configurations.length > 0);
		_carriers = carriers;
		_touches = new MemberTouchScan(scope, _hazards, carriers, (file, span) -> {
			final source: Null<String> = scope.sources[file];
			source == null || live.live(file, source, span);
		});
		// under the truth a project file no build runs declares nothing: the index the analysis reads leaves it out
		final view: Null<FactsView> = FactsView.of(facts, scope, factsAreTruth(facts, configurations));
		scope.readThrough(view);
		_index = scope.index;
		final reachGraph: ReachGraph = new ReachGraph(_scope, carriers, maxLibraryFiles);
		_g = reachGraph;
		// an inlined call of a method that runs no project code answers for what it spliced in, as any call of it does
		if (view != null) view.runsNoUserCode = (g, type, name) -> reachGraph.runsNoUserCode(g, type, name, true);
		_admission = new ReachAdmission(_scope, _g);
		final built: ValueEscapes = new ValueEscapes(scope, _g, _hazards, live, carriers, scopeKnown);
		escapes = built;
		_escapes = built;
		carriers.escapedIds = built.escapedIds;
		built.onRaw = () -> _metRawRegion = true;
	}

	/** The call graph over the project, built on first demand and grown by the walk. */
	public inline function graph(): CallGraph {
		return _g.graph();
	}

	/**
	 * May the code `entry` runs do `access` to `member`? See the type doc. `member.owner` must be the
	 * type that declares the member or one that inherits it. A question that met a raw conditional region is
	 * asked again under the configured builds (`escalation`).
	 */
	public function mayReach(entry: ReachEntry, member: MemberRef, access: ReachAccess): ReachResult {
		_metRawRegion = false;
		_syntaxEntered = false;
		_carriers.startQuestion();
		final answer: ReachResult = answerReach(entry, member, access);
		final configured: Null<MemberReach> = escalation(answer);
		return configured == null ? answer : configured.mayReach(entry, member, access);
	}

	/**
	 * The LOCAL-collection question: may the code in `region` change the object the local (or parameter) declared by
	 * `declaration` in `fn` holds? See `answerLocal`; a question that met a raw conditional region is asked again under
	 * the configured builds (`escalation`).
	 */
	public function localMutation(file: String, fn: QueryNode, declaration: QueryNode, region: Span): ReachResult {
		_metRawRegion = false;
		_syntaxEntered = false;
		_carriers.startQuestion();
		final answer: ReachResult = answerLocal(file, fn, declaration, region);
		final configured: Null<MemberReach> = escalation(answer);
		return configured == null ? answer : configured.localMutation(file, fn, declaration, region);
	}

	/**
	 * May the code in `region` of `file` change the collection the identifier `name` read at `at`
	 * binds to? A local or a parameter takes `localMutation`, a field `mayReach` with a `Region` entry
	 * and `Mutate`, owned by the type enclosing `region`. A name that binds to nothing and that the enclosing
	 * type does not declare (an imported static, a module-level value) is not a member this can follow.
	 */
	public function mayMutateNamed(file: String, name: String, at: Span, region: Span): ReachResult {
		final tree: Null<QueryNode> = _g.treeOf(file);
		if (tree == null) return Unknown(SkipParse(file));
		final decl: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, at, tree, _shape);
		final declSpan: Null<Span> = decl?.span;
		if (decl != null && declSpan != null && !(_shape.fieldDeclKinds ?? []).contains(decl.kind)) {
			final fn: Null<QueryNode> = enclosingFunctionNode(tree, declSpan);
			return fn == null ? Unknown(Escape(file, declSpan)) : localMutation(file, fn, decl, region);
		}
		final owner: Null<String> = MemberTouchScan.typeAt(tree, region.from);
		if (owner == null) return Unknown(OutOfScope('`$name` belongs to no type the analysis can name'));
		final ownerName: String = owner;
		if (graph().types.declaringTypeOf(ownerName, name) == null)
			return Unknown(OutOfScope('`$name` is not a member of `$ownerName` or its supertypes — an import or a module-level value'));
		return mayReach(Region(file, region), { owner: ownerName, name: name }, Mutate);
	}

	/** One line saying why `result` is not `Proven`, with `file:line` positions; empty for `Proven`. */
	public function explain(result: ReachResult): String {
		return switch result {
			case Proven: '';
			case Reached(path): 'a call can reach code that changes it: ${pathText(path)}';
			case Unknown(reason): blindText(reason);
		};
	}

	/**
	 * The analysis a question this one could not prove is asked again under — the configured builds' (`_configure`),
	 * built on first need — or null. Only a question that met a raw conditional region, or whose answer rested on the
	 * classpath (`ValueCarriers.metIncomplete`), escalates: the builds decide which branches any of them compiles and
	 * which library code they compile at all, and learning them costs a compile per configuration, so every other
	 * question keeps this analysis's answer, which holds under every build since it walks every branch. With compiler
	 * facts (`_factsTruthAvailable`) every unproved question escalates: under the builds the facts may be the truth.
	 */
	private function escalation(answer: ReachResult): Null<MemberReach> {
		final builds: Bool = _metRawRegion || _carriers.metIncomplete || answer.match(Unknown(OpaqueCond(_, _)));
		if (answer == Proven || !(builds || _factsTruthAvailable)) return null;
		final configure: Null<() -> Null<MemberReach>> = _configure;
		if (configure != null) {
			_configure = null;
			_configured = configure();
		}
		return _configured;
	}

	/** `mayReach` under this analysis alone. */
	private function answerReach(entry: ReachEntry, member: MemberRef, access: ReachAccess): ReachResult {
		_g.startQuestion();
		final entryFile: String = switch entry {
			case Region(f, _), Calls(f, _): f;
		};
		final idle: Null<ReachUnknown> = idleEntry(entryFile);
		if (idle != null) return Unknown(idle);
		final g: CallGraph = graph();
		final seeds: Seeds = seedsOf(g, entry);
		final declaring: String = g.types.declaringTypeOf(member.owner, member.name) ?? member.owner;
		final arrayTyped: Bool = memberIsArray(g, declaring, member.name);
		final scan: MemberTouches = _touches.scan(g, member.name, declaring, access, arrayTyped, seeds.file, seeds.region);
		if (scan.inRegion != null) return Reached([scan.inRegion]);
		if (!_scopeKnown)
			return Unknown(
				OutOfScope('the run declared no project roots that all matched, so a toucher may live in a file it did not read')
			);
		// declarations of the one type the builds typed, a copy per build, are that type (`FactsView.soleType`)
		if (g.types.declarationCount(declaring) > 1 && _scope.facts?.soleType(declaring) == null) return Unknown(Ambiguous(declaring));
		final ownerFile: Null<String> = _scope.siteOf(declaring)?.file;
		if (ownerFile == null || !_projectSources.exists(ownerFile))
			return Unknown(OutOfScope('`$declaring` is not declared in the project, so library code may name `${member.name}`'));
		final info: Null<MemberInfo> = g.types.memberOnChain(declaring, member.name);
		if (info != null && (info.hasGetter || info.hasSetter) && !readStraight(declaring, member.name))
			return Unknown(UnresolvedDispatch(
				ownerFile, null, '`${member.name}` is a property whose accessor stands between the reader and the storage'
			));
		final built: Null<ReachUnknown> = _g.rewrittenBy(declaring) ?? entryRewritten(entryFile, entrySpans(entry));
		if (built != null) return Unknown(built);
		if (access == Mutate && scan.escapes.length > 0) {
			final at: Occurrence = scan.escapes[0];
			return Unknown(Escape(at.file, at.span));
		}
		final marked: Null<ReachUnknown> = enterEntry(g, entry);
		if (marked != null) return Unknown(marked);
		final question: TouchQuestion = {
			name: member.name,
			declaring: declaring,
			access: access,
			arrayTyped: arrayTyped
		};
		return walk(g, seeds, entryHazards(g, entry), entrySites(g, entry), scan, member, question);
	}

	/**
	 * The LOCAL-collection question: may the code in `region` change the object the local (or parameter)
	 * declared by `declaration` in `fn` holds, under this analysis alone? Target-language code, untyped code, a raw conditional region or
	 * an unmodelled construct in `fn` from the declaration on refuses at once — any of them can name a local.
	 * Then `Proven` without the graph when the local has a FRESH initializer and nothing up to the last point
	 * the region can run lets the value escape (no argument, store, `return`, reassignment or closure capture):
	 * no other code holds a reference. A shared value — a parameter, an escaped local — is `Proven` only when
	 * the run declares its whole project and the region runs nothing that could change it: every array change
	 * there must be confined to a fresh local of `fn`, and nothing the region runs — a function it calls, constructs
	 * or reads a property through, or one the language calls implicitly — may change any array other than a fresh
	 * local of its own (`reachedArrayChange`). Which array such code changes is not asked: an array handed to library
	 * code, the receiver of a built-in array method included, leaves the type system (`ValueEscapes`), and then an array
	 * of any element type may be this one.
	 */
	private function answerLocal(file: String, fn: QueryNode, declaration: QueryNode, region: Span): ReachResult {
		_g.startQuestion();
		final idle: Null<ReachUnknown> = idleEntry(file);
		if (idle != null) return Unknown(idle);
		final tree: Null<QueryNode> = _g.treeOf(file);
		final source: Null<String> = _projectSources[file];
		final declSpan: Null<Span> = declaration.span;
		final name: Null<String> = declaration.name;
		if (tree == null || source == null) return Unknown(SkipParse(file));
		if (declSpan == null || name == null) return Unknown(OutOfScope('the declaration of the collection carries no span'));
		final rebuilt: Null<ReachUnknown> = entryRewritten(file, [region]);
		if (rebuilt != null) return Unknown(rebuilt);
		final rerun: Span = new Span(declSpan.from, _touches.rerunEnd(fn, region));
		final blind: Null<ReachUnknown> = firstBlind(file, liveHazards(file, tree, source, rerun)) ?? _scope.facts?.blindIn(file, rerun);
		if (blind != null) return Unknown(blind);
		final escape: Null<Span> = _touches.localEscape(tree, source, fn, declaration, name, region, freshCall.bind(file, _, 0));
		if (escape == null) return Proven;
		if (!_scopeKnown)
			return Unknown(OutOfScope(
				'the run declared no project roots that all matched, so a function called implicitly may live in a file it did not read'
			));
		final shared: Span = escape;
		// a project file that did not parse may hold a function the language calls implicitly
		final g: CallGraph = graph();
		for (skipped in g.skippedFiles) if (_projectSources.exists(skipped)) return Unknown(SkipParse(skipped));
		final callees: Array<CallEdge> = [];
		final culprit: Null<Span> = regionCulprit(file, tree, source, fn, region, callees);
		if (culprit != null) return Unknown(Aliased(file, shared, file, culprit));
		final change: Null<Occurrence> = reachedArrayChange(g, file, tree, region, callees);
		return change == null ? Proven : Unknown(Aliased(file, shared, change.file, change.span));
	}

	/**
	 * Whether the call `call` of `file` returns an object nothing else holds, so a local initialised by it starts
	 * unshared: the call runs exactly one function (`soleTarget`), whose text answers for it (`answersByText`) and whose
	 * every `return` hands out a fresh value (`returnsFresh`). The run must hold its whole project, every file of it
	 * parsed: a file it does not read may declare an override the graph cannot see. `depth` bounds a chain of such calls.
	 */
	private function freshCall(file: String, call: QueryNode, depth: Int): Bool {
		final at: Null<Span> = call.span;
		if (at == null || depth >= MAX_FRESH_DEPTH || !_scopeKnown) return false;
		if (graph().skippedFiles.exists(f -> _projectSources.exists(f))) return false;
		final target: Null<FnNode> = soleTarget(file, at);
		return target != null && answersByText(target) && returnsFresh(target, depth);
	}

	/**
	 * The one function the call site `at` of `file` runs: every edge the graph records there is a plain `Call` to it — no
	 * override reachable by dispatch, no function value, no unresolved reading of the site. Null otherwise.
	 */
	private function soleTarget(file: String, at: Span): Null<FnNode> {
		final g: CallGraph = graph();
		final from: Null<String> = g.functionAt(file, at.from);
		if (from == null) return null;
		final sited: Array<CallEdge> = [for (e in g.outEdges(from)) if (e.file == file && sameSpan(e.span, at)) e];
		// a faceted body records the site twice, its syntax's edge and its facts', both to the one function
		if (sited.length == 0 || !sited.foreach(e -> e.kind == Call && e.to == sited[0].to)) return null;
		return g.unresolved.exists(u -> u.file == file && sameSpan(u.span, at)) ? null : g.node(sited[0].to);
	}

	/**
	 * Whether the text of `target` is what runs: a project function with a body, not `dynamic`, declared once and outside
	 * any conditional region in a type named once — the one declaration the graph node stands for (`CallGraph.declarationsOf`)
	 * — whose every subtype the builds compile is known (`subtypesKnown`) and none of which the index or the compiler facts
	 * see overriding it — and, under a build macro, a compiled body the facts show is its text (`FactsProvenance.bodyIsSource`).
	 */
	private function answersByText(target: FnNode): Bool {
		final type: Null<String> = target.typeName;
		final name: Null<String> = target.name;
		if (type == null || name == null || target.isExternal || target.isBodyless || target.isDynamic) return false;
		final g: CallGraph = graph();
		if (!_projectSources.exists(target.file) || g.types.declarationCount(type) != 1 || !declaredOnce(target.file, type, name))
			return false;
		if (g.declarationsOf(target.id).length != 1) return false;
		if (!_carriers.subtypesKnown(type) || g.virtualTargets(type, name).length > 0 || overriddenInFacts(g, type, name)) return false;
		return _g.rewrittenBy(type) == null || _scope.provenance()?.bodyIsSource(g, target) == true;
	}

	/**
	 * Whether the type `type` of `file` declares `name` exactly once and outside any conditional region: a graph node
	 * folds every declaration of a name into the first one's body, so a twin in another branch, or an overload, would go
	 * unread.
	 */
	private function declaredOnce(file: String, type: String, name: String): Bool {
		final members: Array<MemberInfo> = [
			for (t in _index.fileInfo(file)?.types ?? []) if (t.name == type) for (m in t.members) if (m.name == name) m
		];
		return members.length == 1 && !members[0].guarded;
	}

	/** Whether the compiler facts know a subtype of any typed type the graph calls `type` that overrides `name`. */
	private function overriddenInFacts(g: CallGraph, type: String, name: String): Bool {
		final view: Null<FactsView> = _scope.facts;
		return view != null && (view.bySimpleName()[type] ?? []).exists(id -> view.overrides(g, id, name).length > 0);
	}

	/**
	 * Whether every `return` of the project function `target` hands out a fresh value (`returnHandsOutFresh`). A function
	 * with no value `return`, or holding code the analysis is blind to, answers false.
	 */
	private function returnsFresh(target: FnNode, depth: Int): Bool {
		final tree: Null<QueryNode> = _g.treeOf(target.file);
		final source: Null<String> = _projectSources[target.file];
		final span: Null<Span> = target.span;
		if (tree == null || source == null || span == null) return false;
		final fn: Null<QueryNode> = enclosingFunctionNode(tree, span);
		if (fn == null || !sameSpan(fn.span, span)) return false;
		if (
			firstBlind(target.file, liveHazards(target.file, tree, source, span)) != null
			|| _scope.facts?.blindIn(target.file, span) != null
		)
			return false;
		final returns: Array<QueryNode> = valueReturns(fn);
		final read: QueryNode = tree;
		final text: String = source;
		final ctx: FreshContext = { tree: read, source: text, call: freshCall.bind(target.file, _, depth + 1) };
		final fnSpan: Span = span;
		return returns.length > 0 && returns.foreach(r -> returnHandsOutFresh(r, ctx, fn, fnSpan));
	}

	/** The value `return`s of the function `fn`, outside the functions and lambdas nested in it: those return their own. */
	private function valueReturns(fn: QueryNode): Array<QueryNode> {
		final returnKinds: Array<String> = _shape.valueReturnKinds ?? [];
		final nested: Array<String> = (_shape.functionKinds ?? []).concat(_shape.lambdaKinds ?? []).concat(_shape.localFunctionKinds ?? []);
		final out: Array<QueryNode> = [];
		function collect(node: QueryNode): Void {
			for (c in node.children) if (!nested.contains(c.kind)) {
				if (returnKinds.contains(c.kind)) out.push(c);
				collect(c);
			}
		}
		collect(fn);
		return out;
	}

	/**
	 * Whether the `return` `r` of the function `fn` (at `fnSpan`) hands out a fresh value: one `isFresh` accepts — a further
	 * call through `ctx.call` included — or a local of `fn` whose initializer is fresh and which nothing lets go before
	 * that `return` runs (`MemberTouchScan.localEscape`).
	 */
	private function returnHandsOutFresh(r: QueryNode, ctx: FreshContext, fn: QueryNode, fnSpan: Span): Bool {
		final at: Null<Span> = r.span;
		final raw: Null<QueryNode> = r.children.length > 0 ? r.children[0] : null;
		if (at == null || raw == null) return false;
		final value: QueryNode = BoolExprShape.unwrapParens(raw, _shape.parenKind);
		if (_touches.isFresh(value, ctx)) return true;
		final local: Null<String> = value.kind == _shape.identKind ? value.name : null;
		final valueSpan: Null<Span> = value.span;
		if (local == null || valueSpan == null) return false;
		final decl: Null<QueryNode> = TypeResolver.bindingNodeFrom(local, valueSpan, ctx.tree, _shape);
		if (decl == null || !within(decl.span, fnSpan)) return false;
		return _touches.localEscape(ctx.tree, ctx.source, fn, decl, local, new Span(at.from, at.from), ctx.call) == null;
	}

	/** The innermost function or lambda node of `tree` whose span contains `span`. */
	private function enclosingFunctionNode(tree: QueryNode, span: Span): Null<QueryNode> {
		final kinds: Array<String> = (_shape.functionKinds ?? []).concat(_shape.lambdaKinds ?? []);
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			final s: Null<Span> = node.span;
			if (s != null && (span.from < s.from || span.to > s.to)) return;
			if (s != null && kinds.contains(node.kind)) found = node;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/** One line naming a blind spot and where it was met. */
	private function blindText(reason: ReachUnknown): String {
		return switch reason {
			case SkipParse(file): '$file did not parse';
			case OpaqueCond(file, span): 'an unparsed conditional region at ${at(file, span)}';
			case Reification(file, span): 'a build macro can rewrite code at ${at(file, span)}';
			case Untyped(file, span): 'untyped code at ${at(file, span)}';
			case UnresolvedDispatch(file, span, what): '$what (${at(file, span)})';
			case DynamicName(file, span): 'a member named at run time at ${at(file, span)}';
			case Escape(file, span): 'its value is shared at ${at(file, span)}';
			case Aliased(file, shared, culpritFile, culprit):
				'its value is shared at ${at(file, shared)} and code at ${at(culpritFile, culprit)} may change it';
			case NativeCode(file, span): 'target-language code at ${at(file, span)}';
			case Unmodelled(file, span, kind): 'a `$kind` the analysis does not model at ${at(file, span)}';
			case Ambiguous(typeName): 'more than one type is named `$typeName`';
			case OutOfScope(what), Budget(what): what;
		};
	}

	/** `file:line` of `span`, `file` alone when the line cannot be read, or a note that the code has no file the run read. */
	private function at(file: String, span: Null<Span>): String {
		if (file == '') return 'library code the run did not read';
		// an escalated answer names code of the analysis under the builds
		final source: Null<String> = _projectSources[file] ?? _g.sourceOf(file) ?? _index.sourceOf(file) ?? _configured?.sourceAt(file);
		if (span == null || source == null) return file;
		var line: Int = 1;
		for (i in 0...span.from) if (StringTools.fastCodeAt(source, i) == '\n'.code) line++;
		return '$file:$line';
	}

	private function pathText(path: Array<ReachStep>): String {
		if (path.length == 0) return '';
		final names: Array<String> = [path[0].from];
		for (step in path) if (step.from != step.to) names.push(step.to);
		final last: ReachStep = path[path.length - 1];
		return '${names.join(' -> ')} (${at(last.file, last.span)})';
	}

	// -- entry ------------------------------------------------------------------------------------

	/**
	 * The graph facts the entry starts from: the edges, unresolved calls
	 * and accesses at its sites, and the region its own touches are read in —
	 * with, where the facts are the truth, those of a faceted body meeting it that
	 * have no site of their own and may run there (`splicedInto`, `splicedAt`).
	 */
	private function seedsOf(g: CallGraph, entry: ReachEntry): Seeds {
		return switch entry {
			case Region(file, span): seedsWhere(
				g, file, span, s -> s != null && s.from >= span.from && s.to <= span.to && isLive(g, file, s),
				splicedInto(g, file, [span]), [span]
			);
			case Calls(file, sites):
				final starts: Array<Int> = [for (s in sites) if (s.span != null) s.span.from];
				final spans: Array<Span> = [for (s in sites) if (s.span != null) s.span];
				seedsWhere(
					g, file, null, s -> s != null && starts.contains(s.from) && isLive(g, file, s), splicedInto(g, file, spans), spans
				);
		};
	}

	/**
	 * The faceted nodes of `file` meeting one of `spans`, when the facts are the truth (`FactsView.truth`): what an inlined
	 * body spliced into one of them runs, it runs at a site of it no range names (`CallGraphFacts.siteOf`), which may lie
	 * in `spans`. Empty otherwise: such a body is read by its syntax.
	 */
	private function splicedInto(g: CallGraph, file: String, spans: Array<Span>): Array<String> {
		final facts: Null<CallGraphFacts> = g.facts;
		if (_scope.facts?.truth != true || facts == null) return [];
		final out: Array<String> = [];
		final key: String = CallGraphNames.normalizePath(file);
		// every declaration the node folds is its code: a range meeting any of them may run what its facts filed off it
		for (id in facts.faceted.keys()) if (
			g.declarationsOf(id)
				.exists(d -> CallGraphNames.normalizePath(d.file) == key && spans.exists(s -> d.span.from < s.to && s.from < d.span.to))
		)
			out.push(id);
		return out;
	}

	/**
	 * Whether the member `name` of `declaring` holds an array: its declaration types it one, or — an unannotated
	 * `var items = []` included, which the index cannot type — the facts, being the truth (`FactsView.truth`), type it one
	 * in every build: each typed type standing for `declaring` declares it, and every type a build gave it is the array type.
	 */
	private function memberIsArray(g: CallGraph, declaring: String, name: String): Bool {
		final arrays: Array<String> = _shape.arrayTypeNames ?? [];
		final typeSource: Null<String> = g.types.memberOnChain(declaring, name)?.typeSource;
		final outer: Null<String> = typeSource == null ? null : NominalTypes.outerNominalOf(typeSource, _plugin.typeSyntax);
		if (outer != null && arrays.contains(outer)) return true;
		final fields: Null<Array<FieldDeclFact>> = typedFields(declaring, name);
		return fields != null && fields.foreach(f -> f.types.foreach(t -> arrays.contains(outerTypeName(t))));
	}

	/**
	 * Whether the facts, being the truth (`FactsView.truth`), say every build reads the property `name` of `declaring`
	 * straight from its storage: each typed type standing for `declaring` declares it with a `default` or `null` read — a
	 * physical field, read by a field access — and a write that is a field write, never, or a setter call. A setter then
	 * stands between a writer and the storage only as a call the facts name, whose body writes the storage by a field
	 * access (`MemberTouchScan.typedAccesses`). A getter decides what a reader sees whatever the storage holds, so a
	 * property with one is never read straight, `@:isVar` or not.
	 */
	private function readStraight(declaring: String, name: String): Bool {
		final fields: Null<Array<FieldDeclFact>> = typedFields(declaring, name);
		// every kind a build gave it: a property one build declares with an accessor is read through it there
		return fields != null && fields.foreach(f -> f.kinds.foreach(k -> STRAIGHT_PROPERTY.match(k)));
	}

	/**
	 * The declarations of the member `name` by every typed type standing for `declaring` (`FactsView.bySimpleName`), when
	 * the facts are the truth and each of them declares it; null otherwise.
	 */
	private function typedFields(declaring: String, name: String): Null<Array<FieldDeclFact>> {
		final view: Null<FactsView> = _scope.facts;
		if (view == null || !view.truth) return null;
		final ids: Array<String> = view.bySimpleName()[declaring] ?? [];
		final out: Array<FieldDeclFact> = [];
		for (id in ids) {
			final declared: Null<FieldDeclFact> = view.table.type(id)?.fields.find(f -> f.name == name);
			if (declared == null) return null;
			out.push(declared);
		}
		return out.length == 0 ? null : out;
	}

	/**
	 * Why a question about code of `file` has no answer here, or null: the file runs in no build (`ReachProject.runsInNoBuild`),
	 * so the graph holds none of it and whatever it calls is never walked — the code runs nowhere a proof would hold.
	 */
	private function idleEntry(file: String): Null<ReachUnknown> {
		return _scope.runsInNoBuild(file) ? OutOfScope('`$file` is compiled by no build the list names') : null;
	}

	/** The hazards inside the entry itself — the whole region, or each call site's own subtree. */
	private function entryHazards(g: CallGraph, entry: ReachEntry): Array<{ file: String, hazard: ReachHazard }> {
		return switch entry {
			case Region(file, span): hazardsOf(g, file, [span]);
			case Calls(file, sites): hazardsOf(g, file, [for (s in sites) if (s.span != null) s.span]);
		};
	}

	/** The spans of the entry's own code: the region, or each call site. */
	private static function entrySpans(entry: ReachEntry): Array<Span> {
		return switch entry {
			case Region(_, span): [span];
			case Calls(_, sites): [for (s in sites) if (s.span != null) s.span];
		};
	}

	/**
	 * Under the truth (`FactsView.truth`), the site of the build macro that made the code of a type holding one of `spans`
	 * of `file` other than its text (`ReachGraph.rewrittenBy`), or null: an entry is text, which may be none of what the
	 * builds compiled there. Without the truth, null: the walk asks every build macro of the code it enters, the entry's
	 * among it only as the member's owner.
	 */
	private function entryRewritten(file: String, spans: Array<Span>): Null<ReachUnknown> {
		final tree: Null<QueryNode> = _g.treeOf(file);
		if (_scope.facts?.truth != true || tree == null) return null;
		for (span in spans) {
			final type: Null<String> = MemberTouchScan.typeAt(tree, span.from);
			final built: Null<ReachUnknown> = type == null ? null : _g.rewrittenBy(type);
			if (built != null) return built;
		}
		return null;
	}

	/** Record the code of the body `node` as entered (`ReachGraph.enter`); true when that widened what was. */
	private function enterBody(g: CallGraph, node: FnNode): Bool {
		var widened: Bool = false;
		for (d in bodySpans(g, node) ?? []) if (_g.enter(g, d.file, d.span, node.typeName)) widened = true;
		return widened;
	}

	/**
	 * Record the entry's own code as entered: the region, or each call site; and answer the compiler-facts mark on it that
	 * makes any answer about it Unknown (`FactsView.blindIn`), or null.
	 */
	private function enterEntry(g: CallGraph, entry: ReachEntry): Null<ReachUnknown> {
		final file: String = switch entry {
			case Region(f, _), Calls(f, _): f;
		};
		final spans: Array<Span> = entrySpans(entry);
		final tree: Null<QueryNode> = g.treeOf(file);
		var marked: Null<ReachUnknown> = null;
		for (span in spans) {
			_g.enter(g, file, span, tree == null ? null : MemberTouchScan.typeAt(tree, span.from));
			marked = marked ?? _scope.facts?.blindIn(file, span);
		}
		return marked;
	}

	/**
	 * The hazards of `tree` (the text of `file` is `source`) inside `span` that some configuration may compile
	 * (`ReachLiveness`): one inside a branch no configuration takes is skipped, and a raw conditional region only
	 * counts when code some configuration compiles is left in it.
	 */
	private function liveHazards(file: String, tree: QueryNode, source: String, span: Span): Array<ReachHazard> {
		final out: Array<ReachHazard> = [
			for (h in _hazards.hazardsIn(file, tree, source, span))
				if (_live.live(file, source, h.span) && (h.kind != Opaque || _live.holdsLiveCode(file, source, h.span))) h
		];
		if (out.exists(h -> h.kind == Opaque)) _metRawRegion = true;
		return out;
	}

	/** Whether code at `span` of `file` may be compiled by some configuration. */
	private function isLive(g: CallGraph, file: String, span: Null<Span>): Bool {
		final source: Null<String> = g.sourceOf(file) ?? _projectSources[file];
		return source == null || _live.live(file, source, span);
	}

	/** The edges out of node `id` that run code — lexical containment aside — at a site some configuration compiles. */
	private function liveEdges(g: CallGraph, id: String): Array<CallEdge> {
		return [for (e in g.outEdges(id)) if (e.kind != Contains && isLive(g, e.file, e.span)) e];
	}

	private function liveUnresolved(g: CallGraph, id: String): Array<UnresolvedCall> {
		return [for (u in _g.unresolvedFrom(g, id)) if (isLive(g, u.file, u.span)) u];
	}

	private function liveAccess(g: CallGraph, id: String): Array<UnresolvedAccess> {
		return [for (a in _g.accessFrom(g, id)) if (isLive(g, a.file, a.span)) a];
	}

	/** The implicit-call sites inside the entry itself — the whole region, or each call site's own subtree. */
	private function entrySites(g: CallGraph, entry: ReachEntry): Array<ImplicitSite> {
		return switch entry {
			case Region(file, span): sitesOf(g, file, [span]);
			case Calls(file, sites): sitesOf(g, file, [for (s in sites) if (s.span != null) s.span]);
		};
	}

	/**
	 * The implicit-call sites of the code at `spans` of `file`: its compiler facts' where they replace its syntax
	 * (`FactsView.sitesIn`), else its syntax's — which marks the question as having entered code read by its syntax.
	 */
	private function sitesOf(g: CallGraph, file: String, spans: Array<Span>, ?node: String): Array<ImplicitSite> {
		final read: Null<{ tree: QueryNode, source: String }> = readOf(g, file);
		if (read == null) return [];
		final out: Array<ImplicitSite> = [];
		for (span in spans) {
			final typed: Null<Array<ImplicitSite>> = _scope.facts?.sitesIn(g, file, span, node);
			if (typed != null) {
				for (at in typed) out.push(at);
				continue;
			}
			_syntaxEntered = true;
			for (at in _g.sites.sitesIn(file, read.tree, read.source, span)) if (_live.live(file, read.source, at.span)) out.push(at);
		}
		return out;
	}

	/**
	 * The implicit-call sites of the code `declared` spans (`bodySpans`), each read in its own file (`sitesOf`) — as the
	 * node `node` reads it, when given.
	 */
	private function declaredSites(g: CallGraph, declared: Array<Occurrence>, ?node: String): Array<ImplicitSite> {
		return [for (d in declared) for (at in sitesOf(g, d.file, [d.span], node)) at];
	}

	/**
	 * The hazards of the code at `spans` of `file` some configuration may compile (`liveHazards`), read off its syntax —
	 * or, where its compiler facts are the truth, off them wherever they record what a hazard stands for (`FactsView.truthSites`,
	 * `ReachHazards.underTruth`) — as the node `node` reads it, when given (`FactsView.faceted`).
	 */
	private function hazardsOf(
		g: CallGraph, file: String, spans: Array<Span>, ?node: String
	): Array<{ file: String, hazard: ReachHazard }> {
		final read: Null<{ tree: QueryNode, source: String }> = readOf(g, file);
		if (read == null) return [];
		final out: Array<{ file: String, hazard: ReachHazard }> = [];
		for (span in spans) {
			final syntactic: Array<ReachHazard> = liveHazards(file, read.tree, read.source, span);
			final typed: Null<TruthSites> = _scope.facts?.truthSites(g, file, span, node);
			final hazards: Array<ReachHazard> = typed == null ? syntactic : _hazards.underTruth(syntactic, typed, read.tree);
			for (h in hazards) out.push({ file: file, hazard: h });
		}
		return out;
	}

	/**
	 * The first site in `region` that may change a SHARED collection by itself: a reflective access, an array change on a
	 * receiver that is not a fresh unshared local of `fn`, a function value handed on, or an unresolved call or access
	 * other than a built-in array method on such a fresh local. Every other resolved invocation — of project code, or of
	 * library code that is not a method of the built-in array type calling no function argument
	 * (`ExecutionShape.nonMutatingArrayMethods`, or a mutating one on such a fresh local) or a
	 * `ExecutionShape.pureLibraryCalls` target — goes to `callees`, whose code `reachedArrayChange` walks. Null when the
	 * region itself holds no such site.
	 */
	private function regionCulprit(
		file: String, tree: QueryNode, source: String, fn: QueryNode, region: Span, callees: Array<CallEdge>
	): Null<Span> {
		for (h in liveHazards(file, tree, source, region)) switch h.kind {
			case ArrayChange:
				if (!receiverIsFreshLocal(tree, source, fn, h.node, region)) return h.span;
			case _:
				return h.span;
		}
		final calls: Array<QueryNode> = _hazards.callsIn(tree, region);
		final g: CallGraph = graph();
		final seeds: Seeds = seedsOf(g, Region(file, region));
		for (u in seeds.unresolved) if (!onFreshLocalArray(tree, source, fn, u, calls, region)) return u.span ?? region;
		if (seeds.access.length > 0) return seeds.access[0].span ?? region;
		for (e in seeds.edges) {
			// a function value the region hands on may be run by whatever receives it, whenever it does
			final target: Null<FnNode> = g.node(e.to);
			if (target == null || e.kind == Ref) return e.span ?? region;
			final call: Null<QueryNode> = calls.find(c -> c.span?.from == e.span?.from);
			// code a body spliced in is asked where that body is written
			final benign: Bool = e.spliced == null ? benignCall(g, tree, source, fn, target, call, region) : benignWhereWritten(g, e);
			if (!target.isExternal || !benign) callees.push(e);
		}
		return null;
	}

	/**
	 * Whether the unresolved call `u` is an array method on a fresh unshared local of `fn` — an unannotated
	 * `final out = [];` leaves the graph no type to resolve `out.push` with, but a fresh local holds a new array.
	 */
	private function onFreshLocalArray(
		tree: QueryNode, source: String, fn: QueryNode, u: UnresolvedCall, calls: Array<QueryNode>, region: Span
	): Bool {
		final method: Null<String> = switch u.reason {
			case UnresolvedReceiver(m): m;
			case _: null;
		};
		if (method == null) return false;
		final arrayMethod: Bool = (_shape.execution?.nonMutatingArrayMethods ?? []).contains(method)
			|| (_shape.execution?.mutatingArrayMethods ?? []).contains(method);
		final call: Null<QueryNode> = calls.find(c -> c.span?.from == u.span?.from);
		return arrayMethod && call != null && receiverIsFreshLocal(tree, source, fn, call, region);
	}

	/** Whether a call of the external `target` (at `call`) cannot change a collection some other code shares. */
	private function benignCall(
		g: CallGraph, tree: QueryNode, source: String, fn: QueryNode, target: FnNode, call: Null<QueryNode>, region: Span
	): Bool {
		final type: Null<String> = target.typeName;
		final name: Null<String> = target.name;
		if (type == null || name == null) return false;
		if (_g.isPureLibrary(g, type, name, call?.children.slice(1))) return true;
		if (!(_shape.arrayTypeNames ?? []).contains(type) || _g.callsItsArgument(g, type, name)) return false;
		// a method returning a string converts the elements to one (`join`), and an element's `toString` may run anything
		if (g.types.memberOnChain(type, name)?.returnNominal == _g.stringTypeName()) return false;
		if ((_shape.execution?.nonMutatingArrayMethods ?? []).contains(name)) return true;
		if (!(_shape.execution?.mutatingArrayMethods ?? []).contains(name) || call == null) return false;
		return receiverIsFreshLocal(tree, source, fn, call, region);
	}

	/**
	 * Whether the receiver the call or element write `site` acts on is a local of `fn` with a fresh initializer
	 * that never escapes before the region can run again — no other code can hold it.
	 */
	private function receiverIsFreshLocal(tree: QueryNode, source: String, fn: QueryNode, site: QueryNode, region: Span): Bool {
		if (site.children.length == 0) return false;
		final head: QueryNode = site.children[0];
		final receiver: Null<QueryNode> = head.children.length > 0 ? head.children[0] : null;
		final ident: Null<QueryNode> = receiver == null ? null : BoolExprShape.unwrapParens(receiver, _shape.parenKind);
		final name: Null<String> = ident?.name;
		final span: Null<Span> = ident?.span;
		if (ident == null || name == null || span == null || ident.kind != _shape.identKind) return false;
		final decl: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, span, tree, _shape);
		final declSpan: Null<Span> = decl?.span;
		final fnSpan: Null<Span> = fn.span;
		if (decl == null || declSpan == null || fnSpan == null) return false;
		final d: Span = declSpan;
		final f: Span = fnSpan;
		if (d.from < f.from || d.to > f.to) return false;
		return _touches.localEscape(tree, source, fn, decl, name, region) == null;
	}

	/**
	 * Where code the region runs can change ANY array, or null when none can: the invocations `callees` resolved for it
	 * (`regionCulprit`) and every function the language may call IMPLICITLY from an operator, conversion, index, string
	 * conversion, iteration or literal construction it may spell. Walks what those functions reach — calls, overrides,
	 * accessors, function values, implicit calls — into library bodies as the main walk does; an array change on anything
	 * but a fresh unshared local of the function doing it, a blind spot, an unresolved site (a call of a `dynamic`
	 * function is one), a body a build macro may rewrite or an ambiguous type holds, and a body-less target
	 * that is not `ExecutionShape.pureLibraryCalls` all count as a change.
	 */
	private function reachedArrayChange(
		g: CallGraph, file: String, tree: QueryNode, region: Span, callees: Array<CallEdge>
	): Null<Occurrence> {
		final queue: Array<String> = [];
		final seen: Map<String, Bool> = [];
		final sites: Array<ImplicitSite> = sitesOf(g, file, [region]);
		function push(id: String): Void {
			if (seen.exists(id)) return;
			seen[id] = true;
			queue.push(id);
		}
		// entering more code may widen what a site admits (`ReachGraph.enter`), so every site is asked again then; the
		// functions no site narrows run only from code read by its syntax
		function admitAll(): Void {
			if (_syntaxEntered) for (id in _g.alwaysIds(g)) push(id);
			for (at in sites) for (id in _g.idsAt(g, at)) push(id);
		}
		// whether it widened anything does not matter: every site is asked right after
		_g.enter(g, file, region, MemberTouchScan.typeAt(tree, region.from)); // noqa: unused-return-value
		admitAll();
		for (e in callees) {
			final unknown: Null<Occurrence> = followEdge(g, e, push);
			if (unknown != null) return unknown;
		}
		var qi: Int = 0;
		while (qi < queue.length) {
			if (qi >= _maxVisited) return { file: '', span: new Span(0, 0) };
			final id: String = queue[qi++];
			final found: Null<FnNode> = g.node(id);
			if (found == null) return { file: '', span: new Span(0, 0) };
			var node: FnNode = found;
			if (node.isExternal) {
				final target: ImplicitTarget = libraryBody(g, node, false);
				switch target {
					case Harmless:
						continue;
					case Opaque:
						return { file: node.file, span: new Span(0, 0) };
					case Body(body):
						node = body;
						// the placeholder upgraded in place IS this id; another declaration found for it may be seen already
						if (body.id != id && seen.exists(body.id)) continue;
						seen[body.id] = true;
				}
			}
			if (bodyNotItsSource(g, node)) return { file: node.file, span: node.span ?? new Span(0, 0) };
			final syntaxBefore: Bool = _syntaxEntered;
			final change: Null<Occurrence> = reachedChangeIn(g, node, push, sites);
			if (change != null) return change;
			if (enterBody(g, node) || _syntaxEntered != syntaxBefore) admitAll();
		}
		return null;
	}

	/**
	 * Where `reachedArrayChange`'s `node` may change an array other code holds, or null after queueing (`push`) what it
	 * runs and recording its implicit-call sites in `sites`: a body-less declaration dispatches to its implementations (an abstract's
	 * operator forwards to its underlying value) unless it is extern, whose code the walk cannot see, and a body
	 * counts its own array changes, blind spots and unresolved sites. A call of library code the region itself could
	 * make freely (`benignCall`: a pure call, a built-in array method on a fresh local of the body) is not followed.
	 */
	private function reachedChangeIn(g: CallGraph, node: FnNode, push: String -> Void, sites: Array<ImplicitSite>): Null<Occurrence> {
		final type: Null<String> = node.typeName;
		final name: Null<String> = node.name;
		final next: Array<String> = if (node.isBodyless) {
			if (type == null || name == null) return { file: node.file, span: node.span ?? new Span(0, 0) };
			final member: String = name;
			if (g.types.meta.isExtern(type) && !_g.externQuiet(g, type, member))
				return { file: node.file, span: node.span ?? new Span(0, 0) };
			g.virtualTargets(type, member);
		} else {
			final changed: Null<Occurrence> = bodyChangesSharedArray(g, node);
			if (changed != null) return changed;
			if (liveUnresolved(g, node.id).length > 0 || liveAccess(g, node.id).length > 0)
				return { file: node.file, span: node.span ?? new Span(0, 0) };
			// what the body runs implicitly runs too, in every declaration of it
			final bodySites: Array<ImplicitSite> = declaredSites(g, bodySpans(g, node) ?? []);
			for (at in bodySites) {
				sites.push(at);
				for (id in _g.idsAt(g, at)) push(id);
			}
			for (e in liveEdges(g, node.id)) if (!benignEdge(g, node, e)) {
				final unknown: Null<Occurrence> = followEdge(g, e, push);
				if (unknown != null) return unknown;
			}
			[];
		};
		for (id in next) push(id);
		return null;
	}

	/**
	 * Queue (`push`) the target of `e` and, for an instance dispatch, every override of it the graph holds once the
	 * library subtypes are read (`ReachGraph.loadOverrides`) — or answer the site when they cannot all be known.
	 */
	private function followEdge(g: CallGraph, e: CallEdge, push: String -> Void): Null<Occurrence> {
		push(e.to);
		final dispatch: Null<String> = e.dispatchType;
		final target: Null<String> = g.node(e.to)?.name;
		if (dispatch == null || target == null) return null;
		if (!_projectSources.exists(_scope.siteOf(dispatch)?.file ?? '') && _g.loadOverrides(g, dispatch, target) != null)
			return { file: e.file, span: e.span ?? new Span(0, 0) };
		for (v in g.virtualTargets(dispatch, target)) push(v);
		return null;
	}

	/**
	 * Whether the edge `e` out of the body `node` invokes library code that cannot change an array other code holds (`benignCall`).
	 * One the facts filed off a spliced body is asked where that body is written (`benignWhereWritten`).
	 */
	private function benignEdge(g: CallGraph, node: FnNode, e: CallEdge): Bool {
		if (e.spliced != null) return benignWhereWritten(g, e);
		final target: Null<FnNode> = g.node(e.to);
		final at: Null<Span> = e.span;
		final site: String = CallGraphNames.normalizePath(e.file);
		// the declaration of the node the edge's site lies in: its locals are the ones the call may hold fresh
		final body: Null<FnDeclaration> = at == null
			? null
			: g.declarationsOf(node.id).find(d -> CallGraphNames.normalizePath(d.file) == site && within(at, d.span));
		final tree: Null<QueryNode> = body == null ? null : g.treeOf(body.file);
		final source: Null<String> = body == null ? null : g.sourceOf(body.file);
		if (target == null || !target.isExternal || e.kind == Ref || tree == null || source == null || body == null || at == null)
			return false;
		final fn: Null<QueryNode> = enclosingFunctionNode(tree, body.span);
		final call: Null<QueryNode> = _hazards.callsIn(tree, at).find(c -> c.span?.from == at.from);
		return fn != null && benignCall(g, tree, source, fn, target, call, body.span);
	}

	/**
	 * Whether the edge `e`, which the facts filed off a body an inlined call spliced into its function, is benign in the
	 * method that body is written in (`SplicedSite.origin`), asked as that method's own edge at the code's own range: the
	 * spliced code is that method's text, so a receiver it holds fresh there is a fresh one each time it is spliced in.
	 * False when the graph holds no such method, or holds it in another file than the one the code lies in.
	 */
	private function benignWhereWritten(g: CallGraph, e: CallEdge): Bool {
		final origin: Null<{ node: String, file: String, span: Span }> = e.spliced?.origin;
		final written: Null<FnNode> = origin == null ? null : g.node(origin.node);
		if (origin == null || written == null) return false;
		final file: String = written.file;
		if (_scope.facts?.table.keyOf(file) != origin.file) return false;
		return benignEdge(g, written, {
			from: written.id,
			to: e.to,
			kind: e.kind,
			via: e.via,
			file: written.file,
			span: origin.span,
			dispatchType: e.dispatchType,
			receiverField: e.receiverField
		});
	}

	/** Whether the code that runs for `node` may not be its source: a build macro may rewrite its type, or two types share the name. */
	private function bodyNotItsSource(g: CallGraph, node: FnNode): Bool {
		final type: Null<String> = node.typeName;
		return type != null && (sharedName(g, node) || _g.rewrittenBy(type) != null);
	}

	/**
	 * Whether `node` may be another type's member than the one its body is: its type's simple name has several
	 * declarations, unless, where the facts are the truth, every one of them is the one type the builds typed
	 * (`FactsView.soleType`), only one type the builds typed declares a member so named (`FactsView.soleMember`), or the
	 * node reads the name as one of them (`CallGraphFacts.qualify`).
	 */
	private function sharedName(g: CallGraph, node: FnNode): Bool {
		final type: Null<String> = node.typeName;
		final name: Null<String> = node.name;
		if (type == null || g.types.declarationCount(type) <= 1 || g.facts?.qualified.exists(node.id) == true) return false;
		final facts: Null<FactsView> = _scope.facts;
		return facts == null || (facts.soleType(type) == null && (name == null || facts.soleMember(type, name) == null));
	}

	/**
	 * The site of the build macro that may have made the code of `node`, of the type `type`, other than its text
	 * (`ReachGraph.rewrittenBy`) — for a node whose code is one typed type's alone, of that type alone
	 * (`ReachGraph.rewrittenAs`): a node reading the name as one type's member (`CallGraphFacts.qualify`), or, of a name
	 * declared more than once, one the facts read as the one type every declaration is (`FactsView.soleType`) or as the
	 * one type declaring the member (`FactsView.soleMember`) — or null.
	 */
	private function rewrittenAt(g: CallGraph, node: FnNode, type: String): Null<ReachUnknown> {
		final read: Null<QualifiedRead> = g.facts?.qualified[node.id];
		final name: Null<String> = node.name;
		final facts: Null<FactsView> = _scope.facts;
		final sole: Null<String> = facts == null || g.types.declarationCount(type) <= 1
			? null
			: facts.soleType(type) ?? (name == null ? null : facts.soleMember(type, name));
		final owner: Null<String> = read?.owner ?? sole;
		return owner == null ? _g.rewrittenBy(type) : _g.rewrittenAs(g, node, type, owner);
	}

	/**
	 * Whether a fact naming the owner of the target `id` may tell which of the types sharing its name runs: the facts are
	 * the truth and the index declares that name more than once.
	 */
	private function mayShare(g: CallGraph, id: String): Bool {
		final type: Null<String> = g.node(id)?.typeName;
		return type != null && _scope.facts?.truth == true && g.types.declarationCount(type) > 1;
	}

	/**
	 * The node reading the graph node `node`, of a name several types share (`sharedName`), as the member of the typed type
	 * `owner` a fact names its target's (`ReachGraph.qualified`) — when the facts read it so, and say how its body, if the
	 * project's, touches the member `question` asks of (`MemberTouchScan.scanNode`), which `scan` then records. Null
	 * otherwise: the name stays shared.
	 */
	private function qualifiedNode(
		g: CallGraph, node: FnNode, owner: String, question: TouchQuestion, scan: MemberTouches, seeds: Seeds
	): Null<FnNode> {
		final made: Null<FnNode> = _g.qualified(g, node.id, owner);
		if (made == null || !_projectSources.exists(made.file)) return made;
		final touched: Bool = _touches.scanNode(
			g, made.id, question.name, question.declaring, question.access, question.arrayTyped, scan, seeds.file, seeds.region
		);
		return touched ? made : null;
	}

	/** What the external `node` stands for once its library file is read: harmless, a body to walk, or nothing the walk can see. */
	private function libraryBody(g: CallGraph, node: FnNode, mutatorsToo: Bool): ImplicitTarget {
		final type: Null<String> = node.typeName;
		final name: Null<String> = node.name;
		if (type == null || name == null) return Opaque;
		if (_g.runsNoUserCode(g, type, name, mutatorsToo)) return Harmless;
		if (_g.loadType(g, type, []) != null) return Opaque;
		final resolved: Null<String> = g.memberOnChain(type, name);
		final loaded: Null<FnNode> = resolved == null ? null : g.node(resolved);
		return loaded == null || loaded.isExternal ? Opaque : Body(loaded);
	}

	/**
	 * Where `node`'s own body — each declaration of it (`bodySpans`) — changes an array other code may hold, or holds a
	 * blind spot; null when none does.
	 */
	private function bodyChangesSharedArray(g: CallGraph, node: FnNode): Null<Occurrence> {
		final declared: Null<Array<Occurrence>> = bodySpans(g, node);
		if (declared == null) return { file: node.file, span: node.span ?? new Span(0, 0) };
		for (d in declared) {
			final tree: Null<QueryNode> = g.treeOf(d.file);
			final source: Null<String> = g.sourceOf(d.file);
			if (tree == null || source == null || _scope.facts?.blindIn(d.file, d.span) != null) return d;
			// the function this declaration is, whose fresh locals it may change freely: an initializer is none
			final fn: Null<QueryNode> = node.span == null ? null : enclosingFunctionNode(tree, d.span);
			for (h in liveHazards(d.file, tree, source, d.span)) switch h.kind {
				case ArrayChange:
					if (fn == null || !receiverIsFreshLocal(tree, source, fn, h.node, d.span)) return { file: d.file, span: h.span };
				case ReflectiveName(literal) if (literal != null):
				case _:
					return { file: d.file, span: h.span };
			}
		}
		return null;
	}

	// -- the walk ---------------------------------------------------------------------------------

	private function walk(
		g: CallGraph, seeds: Seeds, entry: Array<{ file: String, hazard: ReachHazard }>, entryImplicit: Array<ImplicitSite>,
		scan: MemberTouches, member: MemberRef, question: TouchQuestion
	): ReachResult {
		// noqa: complexity
		final touchers: Map<String, Occurrence> = scan.touchers;
		var blind: Null<ReachUnknown> = scan.hidden;
		final reach: Map<String, Null<ReachStep>> = [];
		final queue: Array<String> = [];
		// per queued node: the typed type a fact names its owner (`CallEdge.typed`) where its name may be shared, and the step
		// that queued it then — such a node is queued once per owner, apart from its queueing by name
		final queueTyped: Array<Null<String>> = [];
		final queueSteps: Array<Null<ReachStep>> = [];
		final queued: Map<String, Bool> = [];
		// a warm-up for its side effect: the members admitted anywhere become graph placeholders before the admission
		// closure below is computed, so the closure can hold them
		_g.alwaysIds(g); // noqa: unused-return-value
		for (at in entryImplicit) _g.idsAt(g, at);
		var admission: Admission = _admission.of(g, touchers);
		var admittedAt: Int = g.edges.length;
		var placeholdersAt: Int = _g.placeholders;
		final sites: Array<AdmissionSite> = [];
		var widened: Bool = false;

		function enqueueTyped(id: String, step: ReachStep, typed: Null<String>): Void {
			final owner: Null<String> = typed != null && mayShare(g, id) ? typed : null;
			final key: String = owner == null ? id : '$id@$owner';
			if (queued.exists(key)) return;
			queued[key] = true;
			if (!reach.exists(id)) reach[id] = step;
			queue.push(id);
			queueTyped.push(owner);
			queueSteps.push(step);
		}
		function enqueue(id: String, step: ReachStep): Void {
			enqueueTyped(id, step, null);
		}
		function edgeStep(e: CallEdge): ReachStep {
			return {
				from: e.from,
				to: e.to,
				kind: e.kind.label(),
				file: e.file,
				span: e.span
			};
		}
		function apply(site: AdmissionSite): Void {
			final ids: Array<String> = site.values ? admission.value.copy() : [];
			if (site.all == true)
				for (id in admission.closure.keys())
					if (g.node(id)?.isExternal == false && !ids.contains(id)) ids.push(id);
			for (id in site.ids ?? []) if (admission.closure.exists(id) && !ids.contains(id)) ids.push(id);
			for (n in site.names)
				for (target in g.resolveTarget(n))
					if (admission.closure.exists(target.id) && !ids.contains(target.id)) ids.push(target.id);
			if (site.constructors) for (c in admission.constructors) if (!ids.contains(c)) ids.push(c);
			final implicit: Array<String> = site.always ? _g.alwaysIds(g).copy() : [];
			// a member the facts name the typed owner of is that type's, not every type's of its simple name
			final owned: Array<OwnedId> = [];
			for (at in site.implicit) for (o in _g.ownedIdsAt(g, at)) if (o.owner == null)
				implicit.push(o.id)
			else
				owned.push(o);
			for (id in implicit) if (admission.closure.exists(id) && !ids.contains(id)) ids.push(id);
			function step(id: String): ReachStep {
				return {
					from: site.from,
					to: id,
					kind: site.kind,
					file: site.file,
					span: site.span
				};
			}
			for (id in ids) enqueue(id, step(id));
			for (o in owned) if (admission.closure.exists(o.id)) enqueueTyped(o.id, step(o.id), o.owner);
		}
		// a conversion or a field-name fallback can run from any code the walk enters that is read by its syntax — code read
		// through its compiler facts spells each as a call — and every other implicitly-called function from a site of its
		// own family: the entry's here, each body's as it is entered
		var alwaysAdmitted: Bool = false;
		var unreadAdmitted: Bool = false;
		// the sites whose unread admission was narrowed to what the facts leave implicit, one per set of channels: each is asked
		// again whenever the graph grew, and widened once it holds code read by its syntax one of them may run (`admitUnread`)
		final narrowed: Array<AdmissionSite> = [];
		final narrowedChannels: Array<String> = [];
		function admitAlways(): Void {
			if (alwaysAdmitted || !_syntaxEntered) return;
			alwaysAdmitted = true;
			final always: AdmissionSite = {
				from: 'entry',
				file: seeds.file,
				span: seeds.region,
				kind: 'implicit',
				names: [],
				values: false,
				constructors: false,
				always: true,
				implicit: []
			};
			sites.push(always);
			apply(always);
		}
		// a channel may run code the walk never enters, since it reaches no toucher by an edge — code read by its syntax, a
		// library's — which may run any implicitly-called member on any value it holds: a conversion, an iteration, an
		// operator, an index access, a literal construction. Code read through its compiler facts, where they are the truth,
		// runs one without a call the graph holds only at a string conversion or an iteration (`ReachGraph.typedImplicitIds`)
		function admitUnread(site: AdmissionSite, again: Bool): Void {
			if (unreadAdmitted || !runsUnreadCode(site)) return;
			final channels: String = '${site.values} ${site.constructors} ${site.all == true}';
			if (!again && narrowedChannels.contains(channels)) return;
			final read: Bool = _admission.runsSyntaxRead(g, site.values, site.constructors, site.all == true);
			if (!read && again) return;
			if (read) {
				unreadAdmitted = true;
				_syntaxEntered = true;
			} else {
				narrowed.push(site);
				narrowedChannels.push(channels);
			}
			final unread: AdmissionSite = {
				from: site.from,
				file: site.file,
				span: site.span,
				kind: 'implicit',
				names: [],
				values: false,
				constructors: false,
				always: true,
				implicit: [],
				ids: read ? _g.implicitIds(g) : _g.typedImplicitIds(g)
			};
			sites.push(unread);
			apply(unread);
		}
		function admit(site: AdmissionSite): Void {
			sites.push(site);
			apply(site);
			admitUnread(site, false);
			admitAlways();
		}
		function follow(e: CallEdge): Void {
			enqueueTyped(e.to, edgeStep(e), e.typed);
			final dispatch: Null<String> = e.dispatchType;
			final target: Null<String> = g.node(e.to)?.name;
			if (dispatch == null || target == null) return;
			if (!_projectSources.exists(_scope.siteOf(dispatch)?.file ?? '')) {
				final grown: Null<ReachUnknown> = _g.loadOverrides(g, dispatch, target);
				if (grown != null) blind = blind ?? grown;
			}
			for (v in g.virtualTargets(dispatch, target)) enqueue(v, {
				from: e.from,
				to: v,
				kind: EdgeKind.Virtual.label(),
				file: e.file,
				span: e.span
			});
		}
		function admitUnresolved(u: UnresolvedCall): Void {
			switch u.reason {
				case Unseen(what):
					// code the compiler resolved and the graph holds no node for: nothing can say what it touches
					blind = blind ?? UnresolvedDispatch(u.file, u.span, what);
				case _:
					admit(site(u.from, u.file, u.span, 'unresolved', ReachAdmission.admittedNames(u), true));
			}
		}
		function admitAccess(a: UnresolvedAccess): Void {
			// the member's accessors, and the member itself: a method read off an untyped receiver runs later as a value
			admit(site(a.from, a.file, a.span, 'unresolved access', _admission.accessNames(a.member), false));
		}
		// an access of the member by its own name in library code — project code's are touches of the scan already
		var libraryTouchAt: Null<{ from: String, file: String, span: Span }> = null;
		final ownNames: Array<String> = [for (p in _shape.accessorMethodPrefixes ?? []) p + member.name].concat([member.name]);
		function libraryTouch(from: String, file: String, span: Span, relation: CarryRelation): Void {
			switch relation {
				case Carries:
					if (libraryTouchAt == null) libraryTouchAt = { from: from, file: file, span: span };
				case MayCarry:
					blind = blind ?? DynamicName(file, span);
				case CannotCarry:
			}
		}
		function inspectAll(from: String, hazards: Array<{ file: String, hazard: ReachHazard }>): Void {
			for (entry in hazards) {
				final h: ReachHazard = entry.hazard;
				switch h.kind {
					case ReflectiveName(literal) if (literal != null):
						final named: String = literal;
						if (ownNames.contains(named) && !_projectSources.exists(entry.file))
							libraryTouch(
								from, entry.file, h.span, receiverRelation(g, entry.file, _hazards.reflectiveReceiverOf(h.node), member)
							);
						final names: Array<String> = [for (p in _shape.accessorMethodPrefixes ?? []) p + named];
						names.push(named);
						admit(site(from, entry.file, h.span, 'reflection', names, false));
					case ArrayChange:
					case _:
						blind = blind ?? firstBlind(entry.file, [h]);
				}
			}
		}

		admit({
			from: 'entry',
			file: seeds.file,
			span: seeds.region,
			kind: 'implicit',
			names: [],
			values: false,
			constructors: false,
			always: false,
			implicit: entryImplicit
		});
		inspectAll('entry', entry);
		for (e in seeds.edges) follow(e);
		for (u in seeds.unresolved) admitUnresolved(u);
		for (a in seeds.access) admitAccess(a);

		var qi: Int = 0;
		while (true) {
			while (qi < queue.length) {
				if (qi >= _maxVisited) return Unknown(blind ?? Budget('the walk visited more than $_maxVisited functions'));
				final id: String = queue[qi];
				final typed: Null<String> = queueTyped[qi];
				final step: Null<ReachStep> = typed == null ? reach[id] : queueSteps[qi];
				qi++;
				if (blind != null) _g.stopGrowing = true;
				// the files of the type a fact names are read first: a name two types share names no one file to read
				final unread: Null<ReachUnknown> = typed == null ? null : _g.loadOwner(g, id, typed);
				if (unread != null) blind = blind ?? unread;
				final found: Null<FnNode> = g.node(id);
				// a qualified visit of a name two types share touches as the node read as its owner's member, below
				final shared: Bool = typed != null && found != null && !found.isExternal && sharedName(g, found);
				if (!shared && touchers.exists(id) && !freshlyConstructed(g, id, step, scan, member))
					return Reached(pathTo(reach, id, touchers[id]));
				if (found == null) continue;
				var node: FnNode = found;
				if (node.isExternal) {
					final more: Null<ReachUnknown> = expandExternal(g, node, reach[id], enqueue, (from, file, span, type, name) -> {
						admit(externSite(g, from, file, span, type, name));
					});
					if (more != null) blind = blind ?? more;
					// the file just read may have declared this very id, which is then a body to walk
					final upgraded: Null<FnNode> = g.node(id);
					if (upgraded == null || upgraded.isExternal) continue;
					node = upgraded;
				}
				final type: Null<String> = node.typeName;
				// code no configuration compiles runs in no build: a node every declaration of which lies there runs nothing
				final declared: Array<FnDeclaration> = g.declarationsOf(node.id);
				if (declared.length > 0 && !declared.exists(d -> isLive(g, d.file, d.span))) continue;
				if (node.isBodyless) {
					// an interface or abstract declaration only dispatches — its implementations came through the edge — and an
					// abstract's operator forwards to its underlying value; an extern runs target code, which may call any
					// function value it was handed
					final name: Null<String> = node.name;
					if (type == null || name == null)
						blind = blind ?? UnresolvedDispatch(node.file, null, 'a call to `${node.id}`');
					else if (g.types.meta.isExtern(type) && !_g.externQuiet(g, type, name))
						admit(externSite(g, node.id, reach[id]?.file ?? node.file, reach[id]?.span, type, name));
					continue;
				}
				// a name two types share is read as the one a fact names the target's owner, or not at all (`ReachGraph.qualified`)
				if (type != null && sharedName(g, node)) {
					final escaped: Int = scan.escapes.length;
					final read: Null<FnNode> = typed == null ? null : qualifiedNode(g, node, typed, question, scan, seeds);
					// unread as its owner's, the name touches as every declaration of it does
					if (read == null && shared && touchers.exists(id) && !freshlyConstructed(g, id, step, scan, member))
						return Reached(pathTo(reach, id, touchers[id]));
					if (read == null)
						blind = blind ?? Ambiguous(type);
					else {
						final as: FnNode = read;
						// an escape its facts show, which the question was asked before
						final shown: Null<Occurrence> = scan.escapes.length > escaped ? scan.escapes[escaped] : null;
						if (shown != null) blind = blind ?? Escape(shown.file, shown.span);
						reach[as.id] = step == null ? null : {
							from: step.from,
							to: as.id,
							kind: step.kind,
							file: step.file,
							span: step.span
						};
						if (touchers.exists(as.id) && !freshlyConstructed(g, as.id, reach[as.id], scan, member))
							return Reached(pathTo(reach, as.id, touchers[as.id]));
						node = as;
					}
				}
				final rebuilt: Null<ReachUnknown> = type == null ? null : rewrittenAt(g, node, type);
				if (rebuilt != null) blind = blind ?? rebuilt;
				final spans: Null<Array<Occurrence>> = bodySpans(g, node);
				if (spans == null)
					blind = blind ?? UnresolvedDispatch(node.file, null, 'the body of `${node.id}`, which the graph cannot locate');
				else {
					if (enterBody(g, node)) widened = true;
					// every declaration the node folds runs as it: each is read whole
					for (d in spans) {
						inspectAll(node.id, hazardsOf(g, d.file, [d.span], node.id));
						blind = blind ?? _scope.facts?.blindIn(d.file, d.span);
						if (!_projectSources.exists(d.file)) for (access in libraryAccesses(g, d.file, [d.span], member))
							libraryTouch(node.id, d.file, access.span, access.relation);
					}
					final touch: Null<{ from: String, file: String, span: Span }> = libraryTouchAt;
					if (touch != null) return Reached(pathTo(reach, touch.from, { file: touch.file, span: touch.span }));
					final implicit: Array<ImplicitSite> = declaredSites(g, spans, node.id);
					admitAlways();
					if (implicit.length > 0) admit({
						from: node.id,
						file: node.file,
						span: node.span,
						kind: 'implicit',
						names: [],
						values: false,
						constructors: false,
						always: false,
						implicit: implicit
					});
				}
				for (e in liveEdges(g, node.id)) follow(e);
				for (u in liveUnresolved(g, node.id)) admitUnresolved(u);
				for (a in liveAccess(g, node.id)) admitAccess(a);
			}
			// the graph grew into library files or placeholders — a function there may now reach a toucher — or the walk
			// entered code that widens what an implicit-call site admits: every admission is re-asked
			final edgeCount: Int = g.edges.length;
			final grew: Bool = edgeCount != admittedAt || _g.placeholders != placeholdersAt;
			if (!grew && !widened) break;
			if (grew) admission = _admission.of(g, touchers);
			admittedAt = edgeCount;
			placeholdersAt = _g.placeholders;
			widened = false;
			for (s in sites) apply(s);
			for (s in narrowed) admitUnread(s, true);
			admitAlways();
			if (qi >= queue.length) break;
		}
		final stop: Null<ReachUnknown> = blind;
		return stop == null ? Proven : Unknown(stop);
	}

	/**
	 * The code `node` runs, as spans of files: every declaration the graph folded into it (`CallGraph.declarationsOf`) —
	 * a member declared in each branch of a conditional region, an overload, a copy of its type per build — or, for a
	 * field-initializer pseudo-node, the initializers of its type in every file holding some (`CallGraph.initializerFiles`).
	 * A positive list: null — nothing the walk may prove — when some of that code cannot be located.
	 */
	private function bodySpans(g: CallGraph, node: FnNode): Null<Array<Occurrence>> {
		final declared: Array<FnDeclaration> = g.declarationsOf(node.id);
		if (declared.length > 0) return [for (d in declared) { file: d.file, span: d.span }];
		final type: Null<String> = node.typeName;
		final files: Array<String> = g.initializerFiles(node.id);
		final isStatic: Bool = node.name == CallGraph.STATIC_INIT_NAME;
		if (type == null || files.length == 0 || !(isStatic || node.name == CallGraph.INIT_NAME)) return null;
		final out: Array<Occurrence> = [];
		for (file in files) {
			final tree: Null<QueryNode> = g.treeOf(file);
			final source: Null<String> = g.sourceOf(file);
			final spans: Null<Array<Span>> =
				tree == null || source == null ? null : _hazards.initializerSpans(tree, source, type, isStatic);
			if (spans == null) return null;
			for (span in spans) out.push({ file: file, span: span });
		}
		return out;
	}

	/**
	 * Grow the graph with the file declaring the external target's type (and its supertypes'), then follow
	 * the declaration found there: a body is enqueued, a field of function type or a body-less extern member
	 * admits the value channel, and a type no indexed file declares is a blind spot.
	 */
	private function expandExternal(
		g: CallGraph, node: FnNode, via: Null<ReachStep>, enqueue: (String, ReachStep) -> Void,
		admitValue: (String, String, Null<Span>, String, String) -> Void
	): Null<ReachUnknown> {
		final type: Null<String> = node.typeName;
		final name: Null<String> = node.name;
		final file: String = via?.file ?? '';
		final span: Null<Span> = via?.span;
		if (type == null || name == null) return UnresolvedDispatch(file, span, 'a call to `${node.id}`');
		if (_g.runsNoUserCode(g, type, name, true)) return null;
		final loaded: Null<ReachUnknown> = _g.loadType(g, type, []);
		return loaded ?? followLoaded(g, node, type, name, via, enqueue, admitValue);
	}

	/**
	 * Follow the external target `node` (`type.name`) once its type's file is read: the declaration found there
	 * and every override loaded, the generated constructor of a type that declares none, or — for a declaration
	 * with no body — the value channel (`bodyless`).
	 */
	private function followLoaded(
		g: CallGraph, node: FnNode, type: String, name: String, via: Null<ReachStep>, enqueue: (String, ReachStep) -> Void,
		admitValue: (String, String, Null<Span>, String, String) -> Void
	): Null<ReachUnknown> {
		final file: String = via?.file ?? '';
		final span: Null<Span> = via?.span;
		final resolved: Null<String> = g.memberOnChain(type, name);
		final step: ReachStep = {
			from: node.id,
			to: resolved ?? node.id,
			kind: via?.kind == EdgeKind.New.label() ? EdgeKind.New.label() : 'declared',
			file: file,
			span: span
		};
		if (resolved != null && g.node(resolved)?.isExternal == false) enqueue(resolved, step);
		var grown: Null<ReachUnknown> = null;
		if (!_projectSources.exists(_scope.siteOf(type)?.file ?? '')) grown = _g.loadOverrides(g, type, name);
		for (v in g.virtualTargets(type, name)) enqueue(v, step);
		if (resolved != null && g.node(resolved)?.isExternal == false) return grown;
		// a type that declares no constructor has a generated one: its initializers, then its superclass's constructor
		if (resolved == null && name == (_shape.constructorName ?? 'new') && g.types.declarationCount(type) > 0) {
			for (id in _g.generatedConstructor(g, type)) enqueue(id, step);
			return grown;
		}
		return grown ?? bodyless(g, node.id, type, name, file, span, admitValue);
	}

	/**
	 * A target whose declaration has no body the graph holds: a field of function type or an extern member
	 * admits the value channel, implicitly-called methods and — for a reflective instantiation — the
	 * constructors; a name no indexed type declares is a blind spot.
	 */
	private function bodyless(
		g: CallGraph, id: String, type: String, name: String, file: String, span: Null<Span>,
		admitValue: (String, String, Null<Span>, String, String) -> Void
	): Null<ReachUnknown> {
		final info: Null<MemberInfo> = g.types.memberOnChain(type, name);
		if (_scope.siteOf(type) == null || info == null)
			return UnresolvedDispatch(file, span, 'a call to `$type.$name`, which no indexed type declares');
		admitValue(id, file, span, type, name);
		return null;
	}

	/**
	 * The admission of a call into target code — `type.name`, invoked at `span` of `file`. Target code may call any
	 * function value it was handed (`values`) and, for a reflective instantiation, any constructor. It also reaches a
	 * program object's members BY NAME — a `toJSON`, a `toString`, a `then` — so every object the call hands it is a
	 * reflective access with a computed name: the members its static type may carry at run time (`memberIdsOf`),
	 * or every function the admission closure holds when that is not known. And a member that
	 * returns the language's string type converts what it is handed, its receiver included, to one: a string
	 * conversion of each of them.
	 */
	private function externSite(g: CallGraph, from: String, file: String, span: Null<Span>, type: String, name: String): AdmissionSite {
		// noqa: complexity
		final site: AdmissionSite = {
			from: from,
			file: file,
			span: span,
			kind: 'extern',
			names: [],
			values: true,
			constructors: _g.instantiates(type, name),
			always: false,
			implicit: [],
			all: false
		};
		final tree: Null<QueryNode> = g.treeOf(file);
		final source: Null<String> = g.sourceOf(file);
		final call: Null<QueryNode> = span == null || tree == null ? null : invocationAt(tree, span);
		final takesObject: Bool = _g.externTakesObject(g, type, name);
		final onInstance: Bool = g.types.memberOnChain(type, name)?.isStatic == false;
		if (call == null || tree == null || source == null || call.children.length == 0) {
			// the site is not in code the analysis read: nothing narrows what the call is handed, its receiver included
			site.all = takesObject || onInstance;
			return site;
		}
		final args: Array<QueryNode> = call.children.slice(1);
		final callee: QueryNode = call.children[0];
		final receiver: Null<QueryNode> = _hazards.isAccess(callee.kind) && callee.children.length > 0 ? callee.children[0] : null;
		final lambdas: Array<String> = _shape.lambdaKinds ?? [];
		function hand(t: Null<String>): Void {
			if (t != null && _g.inertType(t)) return;
			final members: Null<Array<String>> = t == null ? null : _g.handedMemberIds(g, t);
			if (members == null) {
				site.all = true;
				return;
			}
			final ids: Array<String> = site.ids ?? [];
			for (id in members) if (!ids.contains(id)) ids.push(id);
			site.ids = ids;
		}
		if (takesObject) for (arg in args) if (!lambdas.contains(arg.kind)) hand(_g.sites.typeOf(file, tree, source, arg));
		// an instance member's target code holds its receiver too — a program subclass's `this` when the call is bare —
		// and reaches its members by name as it does an argument's (a native `toJSON` runs `this.toISOString()`)
		if (onInstance)
			hand(receiver == null ? MemberTouchScan.typeAt(tree, call.span?.from ?? 0) : _g.sites.typeOf(file, tree, source, receiver));
		// a type taking type parameters is a container whose elements a conversion reaches too: any
		function containerFree(t: Null<String>): Null<String> {
			return t == null || g.types.generics.typeParamsOf(t).length > 0 ? null : t;
		}
		final returned: Null<String> = g.types.memberOnChain(type, name)?.returnNominal;
		final stringType: Null<String> = _g.stringTypeName();
		final at: Null<Span> = call.span;
		if (returned != null && returned == stringType && at != null) {
			final converted: Array<QueryNode> = receiver == null ? args : [receiver].concat(args);
			final callSpan: Span = at;
			site.implicit.push({
				family: Text,
				span: callSpan,
				types: [for (o in converted) containerFree(_g.sites.typeOf(file, tree, source, o))],
				exact: false
			});
		}
		return site;
	}

	/** The call or constructor node of `tree` spanning exactly `span` — a chained call starting there is another node. */
	private function invocationAt(tree: QueryNode, span: Span): Null<QueryNode> {
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			final s: Null<Span> = node.span;
			if (found != null || (s != null && (span.from < s.from || span.from >= s.to))) return;
			if (s != null && s.from == span.from && s.to == span.to && (node.kind == _shape.callKind || node.kind == _shape.newExprKind)) {
				found = node;
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/**
	 * Whether toucher `id` is a constructor the walk entered to build a NEW object, and it touches an
	 * instance member only on that object's own `this`: the object under construction is not the one the
	 * entry runs on, so those touches cannot reach it. A static member has no per-object copy and is never
	 * excused.
	 */
	private function freshlyConstructed(g: CallGraph, id: String, step: Null<ReachStep>, scan: MemberTouches, member: MemberRef): Bool {
		if (step == null || !(step.kind == EdgeKind.New.label() || step.kind == REFLECTIVE_CONSTRUCTOR) || scan.notOnSelf.exists(id))
			return false;
		if (g.node(id)?.name != (_shape.constructorName ?? 'new')) return false;
		return g.types.memberOnChain(member.owner, member.name)?.isStatic == false;
	}

	/** The files of `project` whose text differs from this analysis's, or null when the set of files itself differs. */
	private function changedFiles(project: Array<{ file: String, source: String }>): Null<Array<{ file: String, source: String }>> {
		if (project.length != _project.length) return null;
		final out: Array<{ file: String, source: String }> = [];
		for (f in project) {
			final held: Null<String> = _projectSources[f.file];
			if (held == null) return null;
			if (held != f.source) out.push(f);
		}
		return out;
	}

	/**
	 * Take the new text of `changed` into this analysis when none of them changed a declaration (`signatureOf`):
	 * the graph re-reads just those files and every cache over them is dropped. False, touching nothing, when one
	 * did, or when one holds a declaration of a graph node another file declares too (`ReachGraph.foldsAcrossFiles`) —
	 * the caller builds a new analysis.
	 */
	private function refresh(changed: Array<{ file: String, source: String }>): Bool {
		if (_g.foldsAcrossFiles(changed)) return false;
		final infos: Array<FileInfo> = [];
		for (f in changed) {
			final before: Null<FileInfo> = _index.fileInfo(f.file);
			final after: Null<FileInfo> = SymbolIndex.build([f], _plugin).fileInfo(f.file);
			if (before == null || after == null) return false;
			final rebuilt: FileInfo = after;
			if (signatureOf(before) != signatureOf(rebuilt)) return false;
			infos.push(rebuilt);
		}
		for (f in changed) {
			_projectSources[f.file] = f.source;
			_scope.sources[f.file] = f.source;
			for (i in 0..._project.length) if (_project[i].file == f.file) _project[i] = { file: f.file, source: f.source };
			_hazards.forget(f.file);
			_live.forget(f.file);
		}
		// a value may leave the type system anywhere in a body, and a file may have stopped or started parsing
		_carriers.forget();
		_escapes.forget();
		_g.refresh(changed, infos);
		final configured: Null<MemberReach> = _configured;
		// the analysis under the builds takes the same text, or is dropped and built again on the next escalation
		if (configured != null && !configured.refresh(changed)) {
			_configured = null;
			_configure = _reconfigure;
		}
		return true;
	}

	/** The text of `file` as this analysis read it, or null. */
	private function sourceAt(file: String): Null<String> {
		return _projectSources[file] ?? _g.sourceOf(file) ?? _index.sourceOf(file);
	}

	/**
	 * Every access of `member` by its own name inside `spans` of the library file `file`, with how its value relates to
	 * the member: a field access by its receiver's static type, a bare name that binds to no local by the enclosing type
	 * (a library class may extend a project one). Project files are scanned by `MemberTouchScan`; library code only as
	 * the walk enters it.
	 */
	private function libraryAccesses(
		g: CallGraph, file: String, spans: Array<Span>, member: MemberRef
	): Array<{ span: Span, relation: CarryRelation }> {
		final tree: Null<QueryNode> = g.treeOf(file);
		final out: Array<{ span: Span, relation: CarryRelation }> = [];
		final owner: String = g.types.declaringTypeOf(member.owner, member.name) ?? member.owner;
		if (tree == null) return out;
		final root: QueryNode = tree;
		function walk(node: QueryNode): Void {
			final at: Null<Span> = node.span;
			if (at != null && !spans.exists(s -> at.to > s.from && at.from < s.to)) return;
			if (node.name == member.name && at != null) {
				if (_hazards.isAccess(node.kind) && node.children.length > 0)
					out.push({ span: at, relation: receiverRelation(g, file, node.children[0], member) });
				else if (node.kind == _shape.identKind && TypeResolver.bindingNodeFrom(member.name, at, root, _shape) == null)
					out.push({ span: at, relation: _carriers.relation(MemberTouchScan.typeAt(root, at.from), owner) });
			}
			for (c in node.children) walk(c);
		}
		walk(root);
		return out;
	}

	/**
	 * Whether the value `receiver` of library code in `file` evaluates to may be an object carrying `member`, by its
	 * static type (`ValueCarriers.relation`); an untyped receiver, or none, may be anything.
	 */
	private function receiverRelation(g: CallGraph, file: String, receiver: Null<QueryNode>, member: MemberRef): CarryRelation {
		final tree: Null<QueryNode> = g.treeOf(file);
		final source: Null<String> = g.sourceOf(file);
		if (tree == null || source == null || receiver == null) return MayCarry;
		final owner: String = g.types.declaringTypeOf(member.owner, member.name) ?? member.owner;
		return _carriers.relation(_g.sites.typeOf(file, tree, source, receiver), owner);
	}

	/**
	 * The analysis for one lint run over `file` (whose current text is `source`): the project is the
	 * report UNION the declared `resolutionRoots` when the run's host declared roots that ALL matched, else
	 * `file` alone with the scope marked unknown; types resolve through the host's resolution index
	 * (libraries included) when there is one. Memoised on the host for the rest of the pass.
	 */
	public static function forRun(plugin: GrammarPlugin, file: String, source: String): MemberReach {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		final scoped: Null<Array<{ file: String, source: String }>> = host?.completeProjectFiles();
		final project: Array<{ file: String, source: String }> = scoped == null
			? [{ file: file, source: source }]
			: [for (f in scoped) f.file == file ? { file: file, source: source } : f];
		if (scoped != null && !project.exists(f -> f.file == file)) project.push({ file: file, source: source });
		// an edit applied earlier in the pass to ANY project file makes the memoised graph describe code that is gone:
		// taken in place when it changed no declaration, else the analysis is rebuilt
		final memo: Null<MemberReach> = host?.memberReach();
		final changed: Null<Array<{ file: String, source: String }>> = memo?.changedFiles(project);
		if (memo != null && changed != null && (changed.length == 0 || memo.refresh(changed))) return memo;
		final index: SymbolIndex = host?.resolutionIndex() ?? SymbolIndex.build(project, plugin);
		// the resolution scope is what the project declares, not what its builds compile: only the builds can say that no
		// subtype or override lies outside the index (`configuredFor`)
		final built: MemberReach = new MemberReach(
			plugin, project, index, scoped != null, MAX_LIBRARY_FILES, MAX_VISITED, null, () -> false, host?.compilerFacts()
		);
		// the builds are probed only once a question needs them (`escalation`), and read the project's text as it is then
		if (host != null) {
			final configure: () -> Null<MemberReach> = configuredFor.bind(plugin, project, scoped != null, host);
			built._configure = configure;
			built._reconfigure = configure;
			built._factsTruthAvailable = built._scope.facts != null;
			if (scoped != null) host.setMemberReach(built);
		}
		return built;
	}

	/** Whether `inner` lies within `outer`. */
	private static inline function within(inner: Null<Span>, outer: Span): Bool {
		return inner != null && outer.from <= inner.from && inner.to <= outer.to;
	}

	/** Whether the site `span` is exactly `at`. */
	private static inline function sameSpan(span: Null<Span>, at: Span): Bool {
		return span != null && span.from == at.from && span.to == at.to;
	}

	/**
	 * Whether what the admission `site` lets run may be a function the walk never enters, as it reaches no toucher by an
	 * edge: a function value (a lambda read by its syntax, a library function such as `Std.string`), a reflectively
	 * constructed object, any code at all. Such a function may run any implicitly-called member on any value it is handed.
	 */
	private static inline function runsUnreadCode(site: AdmissionSite): Bool {
		return !site.always && (site.values || site.all == true || site.constructors);
	}

	/** The tree and text of `file` as the graph holds them, or null when it holds neither. */
	private static function readOf(g: CallGraph, file: String): Null<{ tree: QueryNode, source: String }> {
		final tree: Null<QueryNode> = g.treeOf(file);
		final source: Null<String> = g.sourceOf(file);
		return tree == null || source == null ? null : { tree: tree, source: source };
	}

	/**
	 * Every declaration fact of `fi` a call graph or the reach walk reads, offsets aside: the imports, and each
	 * type's kind, flags, parameters, supertypes, alias target and forwarded members, and its members with their
	 * kinds, modifiers (`dynamic` included), accessors, implicit-call annotations and types. Another file's edges and
	 * unresolved sites were resolved against these facts, so a change to any of them rebuilds the analysis.
	 */
	private static function signatureOf(fi: FileInfo): String {
		final parts: Array<String> = [fi.pkg, fi.module];
		for (group in [fi.imports].concat([for (g in fi.ambientImports) g.imports])) for (imp in group)
			parts.push('import ${imp.kind} ${imp.raw} ${imp.alias} ${imp.aliasTarget}');
		for (t in fi.types) {
			parts.push(
				'type ${t.name} ${t.kind} ${t.isExtern} ${t.isPrivate} ${t.typeParamNames} ${t.supertypesWritten} ${t.interfaces} '
				+ '${t.aliasTargetRaw} ${t.hasBuild} ${t.hasAutoBuild} ${t.hasRtti} ${t.hasKeep} ${t.constructsFromLiteral} '
				+ '${t.isAnonStruct} ${t.abstractForwardUnderlying} ${t.forwardedMembers} ${t.aliasTargetNominal} ${t.abstractSelfRebind}'
			);
			for (m in t.members)
				parts.push(
					'member ${m.name} ${m.kind} ${m.isStatic} ${m.isInline} ${m.isMacro} ${m.isOverride} ${m.visibility} '
					+ '${m.hasGetter} ${m.hasSetter} ${m.isImplicitCall} ${m.isImplicitConversion} ${m.operatorOverloads} ${m.typeSource} '
					+ '${m.returnNominal} ${m.paramTypeSources} ${m.guarded} ${m.isDynamic} ${m.implicitCallMetas}'
				);
		}
		return parts.join('\n');
	}

	/**
	 * The index over the project and exactly the library files the configured builds parse (`ReachBuilds.library`):
	 * other library code runs in none of the builds an answer must hold under, and the copy of a std type a build
	 * compiles — a target's own `_std` one — is the one the walk must read. A compiled file that is a project file
	 * stays the project's.
	 */
	private static function compiledIndex(
		project: Array<{ file: String, source: String }>, builds: ReachBuilds, plugin: GrammarPlugin
	): SymbolIndex {
		final cwd: String = Sys.getCwd();
		final projectPaths: Map<String, Bool> = [for (f in project) OracleCoverage.canonical(cwd, f.file) => true];
		final library: Array<{ file: String, source: String }> = [for (f in builds.library) if (!projectPaths.exists(f.file)) f];
		return SymbolIndex.build(project.concat(library), plugin, [for (f in library) f.file]);
	}

	// -- locals -----------------------------------------------------------------------------------

	/** The first blind spot among `hazards` of `file` — anything but an array change and a literal reflective name. */
	private static function firstBlind(file: String, hazards: Array<ReachHazard>): Null<ReachUnknown> {
		for (h in hazards) switch h.kind {
			case Native:
				return NativeCode(file, h.span);
			case Untyped:
				return Untyped(file, h.span);
			case Opaque:
				return OpaqueCond(file, h.span);
			case Unmodelled(kind):
				return Unmodelled(file, h.span, kind);
			case ReflectiveName(null):
				return DynamicName(file, h.span);
			case ReflectiveName(_), ArrayChange:
		}
		return null;
	}

	/** One admission of the walk: the site, and which functions it may enter. */
	private static function site(
		from: String, file: String, span: Null<Span>, kind: String, names: Array<String>, values: Bool
	): AdmissionSite {
		return {
			from: from,
			file: file,
			span: span,
			kind: kind,
			names: names,
			values: values,
			constructors: false,
			always: false,
			implicit: []
		};
	}

	/**
	 * The graph facts of `file` whose site `keep` admits, and those with no site of the nodes `spliced` names (`splicedInto`)
	 * that may run at one of `spans` (`splicedAt`).
	 */
	private static function seedsWhere(
		g: CallGraph, file: String, region: Null<Span>, keep: Null<Span> -> Bool, spliced: Array<String>, spans: Array<Span>
	): Seeds {
		function admits(from: String, span: Null<Span>, where: Null<SplicedSite>): Bool
			return keep(span) || (span == null && spliced.contains(from) && splicedAt(where, spans));
		return {
			file: file,
			region: region,
			edges: [
				for (e in g.edges) if (e.file == file && e.kind != Contains && admits(e.from, e.span, e.spliced)) e
			],
			unresolved: [
				for (u in g.unresolved) if (u.file == file && admits(u.from, u.span, u.spliced)) u
			],
			access: [
				for (a in g.unresolvedAccess) if (a.file == file && admits(a.from, a.span, a.spliced)) a
			]
		};
	}

	/**
	 * Whether what the facts filed off a body spliced in at `where` may run at one of `spans`: a site of its splice meets
	 * one, or no site is known — code no inlined call's body holds, or a fact filed without one, may run anywhere in its
	 * function.
	 */
	private static function splicedAt(where: Null<SplicedSite>, spans: Array<Span>): Bool {
		final sites: Null<Array<Span>> = where?.sites;
		return sites == null || sites.exists(s -> spans.exists(r -> s.from < r.to && r.from < s.to));
	}

	/** The path the walk took to `id`, ending with the touch it found there. */
	private static function pathTo(reach: Map<String, Null<ReachStep>>, id: String, touch: Null<Occurrence>): Array<ReachStep> {
		final path: Array<ReachStep> = [];
		var cursor: String = id;
		final seen: Array<String> = [];
		while (!seen.contains(cursor)) {
			seen.push(cursor);
			final step: Null<ReachStep> = reach[cursor];
			if (step == null) break;
			path.unshift(step);
			cursor = step.from;
		}
		if (touch != null) path.push({
			from: id,
			to: id,
			kind: 'touch',
			file: touch.file,
			span: touch.span
		});
		return path;
	}

	/**
	 * The analysis of `project` under the builds `host`'s configured compiler oracles describe (`ReachDefinesProbe`), over
	 * exactly the library files they compile (`compiledIndex`); null when the run has none. Its classpath is complete when
	 * that index declares every type the builds typed (`declaresEveryType`).
	 */
	private static function configuredFor(
		plugin: GrammarPlugin, project: Array<{ file: String, source: String }>, scopeKnown: Bool, host: SymbolIndexHost
	): Null<MemberReach> {
		final builds: Null<ReachBuilds> = host.reachBuilds();
		if (builds == null) return null;
		final compiled: ReachBuilds = builds;
		final index: SymbolIndex = compiledIndex(project, compiled, plugin);
		return new MemberReach(
			plugin, [for (f in project) f],
			index, scopeKnown, MAX_LIBRARY_FILES, MAX_VISITED, compiled.configurations, declaresEveryType.bind(compiled, index),
			host.compilerFacts()
		);
	}

	/**
	 * Whether `facts` are the truth under `configurations` (`FactsView.truth`): the configurations are the analysis's list
	 * of builds — a run's is every build it ships (`configuredFor`) — and the facts name exactly them, as both probes name
	 * a configuration (`OracleDeclaration.describeOracle`). A table that dropped one is no view at all (`FactsView.of`).
	 */
	private static function factsAreTruth(facts: Null<CompilerFacts>, configurations: Null<Array<ReachConfiguration>>): Bool {
		if (facts == null || configurations == null) return false;
		final typed: Array<String> = facts.configurations.copy();
		final listed: Array<String> = [for (c in configurations) c.name];
		typed.sort(Reflect.compare);
		listed.sort(Reflect.compare);
		if (typed.length != listed.length) return false;
		for (i in 0...typed.length) if (typed[i] != listed[i]) return false;
		return true;
	}

	/** The outer type a facts type string names, by its simple name: `Array` for `Array<Int>`, `Map` for `haxe.ds.Map<K,V>`. */
	private static function outerTypeName(type: String): String {
		final open: Int = type.indexOf('<');
		final path: String = open < 0 ? type : type.substr(0, open);
		return path.substr(path.lastIndexOf('.') + 1);
	}

	/**
	 * Whether `index` declares every type `builds` typed, in the file the compiler read it from: a type it does not hold
	 * — a file it could not read, a type a macro defined — may be a subtype or an override nothing here can see.
	 */
	private static function declaresEveryType(builds: ReachBuilds, index: SymbolIndex): Bool {
		final cwd: String = Sys.getCwd();
		final byPath: Map<String, FileInfo> = [for (fi in index.allFiles()) OracleCoverage.canonical(cwd, fi.file) => fi];
		for (c in builds.configurations) for (t in c.types) {
			final declaring: Null<FileInfo> = byPath[t.file];
			if (declaring == null || !declaring.types.exists(d -> d.name == t.name)) return false;
		}
		return true;
	}

}

/** What an external target of the implicit walk turns out to be. */
private enum ImplicitTarget {

	Harmless;
	Opaque;
	Body(node: FnNode);

}

/** What the entry runs, as graph facts. `region` is set for a `Region` entry, whose own touches count too. */
/** What `MemberTouchScan.scan` was asked of the member: the walk asks it again of a node it makes (`MemberReach.qualifiedNode`). */
private typedef TouchQuestion = {
	final name: String;
	final declaring: String;
	final access: ReachAccess;
	final arrayTyped: Bool;
}

private typedef Seeds = {
	var file: String;
	var region: Null<Span>;
	var edges: Array<CallEdge>;
	var unresolved: Array<UnresolvedCall>;
	var access: Array<UnresolvedAccess>;
}

/**
 * A site that admits functions the graph cannot name: those called `names`, the value channel (`values`), the
 * constructors, the implicitly-called functions no syntax narrows (`always`) and those the implicit-call sites
 * `implicit` may run — re-applied whenever the graph grew.
 */
private typedef AdmissionSite = {
	var from: String;
	var file: String;
	var span: Null<Span>;
	var kind: String;
	var names: Array<String>;
	var values: Bool;
	var constructors: Bool;
	var always: Bool;
	var implicit: Array<ImplicitSite>;

	/** Every function the admission closure holds: code that reaches members by a name it computes. */
	@:optional var all: Bool;

	/** These functions: the members of an object handed to code that reaches them by name. */
	@:optional var ids: Array<String>;
}
