package anyparse.query;

import anyparse.query.AbstractReach.InferredRef;
import anyparse.query.AbstractReach.MemberRead;
import anyparse.query.AbstractReach.SignatureWords;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.CallGraph.UnresolvedAccess;
import anyparse.query.CallGraph.UnresolvedCall;
import anyparse.query.CompilerFacts.ReflectionFact;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.ImplicitSites.ImplicitSite;
import anyparse.query.ImplicitSites.SiteFamily;
import anyparse.query.MemberReach.ReachUnknown;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * The call graph `MemberReach` walks, and how it grows: built over the project on first demand, extended one
 * library file at a time when a walk reaches a target declared there (bounded by `maxLibraryFiles`, and not
 * at all once a question met a blind spot), with the per-node groupings of unresolved sites and the set of
 * implicitly-called functions recomputed whenever it grew.
 */
@:nullSafety(Strict)
final class ReachGraph {

	/** The kinds of a typed type (`CompilerFacts.TypeFact`) a value of which is an instance of it or of a subtype. */
	private static final NOMINAL_KINDS: Array<String> = ['class', 'interface'];

	/**
	 * How many placeholders for implicitly-called library members this analysis has added to the graph — a node the
	 * admission closure did not hold when it was computed, so a walk re-asks its admissions when this moves.
	 */
	public var placeholders(default, null): Int = 0;

	/** Where the language runs members implicitly, per file, and the static types of expressions there. */
	public final sites: ImplicitSites;

	/** Whether a value of one type may carry another type's member, and the types it may be at run time. */
	public final carriers: ValueCarriers;

	/** Set once the current question met a blind spot: the graph then stops growing, since `Proven` is out of reach anyway. */
	public var stopGrowing: Bool = false;

	/**
	 * The library files the current question has needed, whether it loaded them or an earlier question
	 * already had: the budget counts these, so an answer does not depend on which questions came first.
	 */
	private final _questionFiles: Map<String, Bool> = [];

	/** Extern type -> whether it is closed over inert values (`externClosed`). */
	private final _externClosed: Map<String, Bool> = [];

	/** Library class -> whether an instance of it may exist while the program runs (`constructible`), settled on first demand. */
	private final _inPlay: Map<String, Bool> = [];

	/** The members whose code the current question's walk entered (`enter`). */
	private final _entered: Map<String, Bool> = [];

	/** Type -> whether a build macro may rewrite it (`isBuilt`). */
	private final _built: Map<String, Bool> = [];

	/** Type -> whether the builds compiled its text (`FactsProvenance.typeIsItsText`), settled on first demand. */
	private final _textual: Map<String, Bool> = [];

	/** `file:Type.member` -> what that member's code can give it a type (`inferredFrom`), read on first demand. */
	private final _inferred: Map<String, Null<{ words: Array<String>, reads: Array<MemberRead> }>> = [];

	private final _scope: ReachProject;
	private final _maxLibraryFiles: Int;

	private var _graph: Null<CallGraph> = null;
	private var _questionFileCount: Int = 0;

	/** Node id -> the unresolved calls / accesses made from it, grouped on first demand. */
	private var _unresolvedFrom: Null<Map<String, Array<UnresolvedCall>>> = null;

	private var _accessFrom: Null<Map<String, Array<UnresolvedAccess>>> = null;

	/** The always-admitted implicitly-called functions (`alwaysIds`), dropped whenever the graph grows or the question enters new code. */
	private var _implicit: Null<Array<String>> = null;

	/** The implicitly-called members the index declares, computed on first demand. */
	private var _indexImplicit: Null<Array<ImplicitCandidate>> = null;

	/** Word -> file -> how often that indexed file spells it, for the words `constructible` asks about; counted on first demand. */
	private var _mentions: Null<Map<String, Map<String, Int>>> = null;

	/** The abstracts visible to the current question (`visibleAbstracts`), grown as its walk enters code. */
	private var _reach: Null<AbstractReach> = null;

	private var _signatureWords: Null<SignatureWords> = null;

	/** The members that produce an instance or a class value from a computed name (`reflectiveProducers`), read once. */
	private var _producers: Null<Array<{ name: String, file: String }>> = null;

	public function new(scope: ReachProject, carriers: ValueCarriers, maxLibraryFiles: Int) {
		_scope = scope;
		this.carriers = carriers;
		_maxLibraryFiles = maxLibraryFiles;
		sites = new ImplicitSites(scope.plugin, scope.index);
	}

	/** The text of `file` when the graph is built and holds it; never builds the graph. */
	public inline function sourceOf(file: String): Null<String> {
		return _graph?.sourceOf(file);
	}

	/**
	 * Start a new question: its own library budget, growth allowed again, and no code entered yet — every input an
	 * answer depends on is the question's own, so it does not depend on which questions came first.
	 */
	public function startQuestion(): Void {
		stopGrowing = false;
		_questionFiles.clear();
		_questionFileCount = 0;
		_entered.clear();
		_reach = null;
		_implicit = null;
	}

	/**
	 * The call graph over the project files a build may run, built on first demand and grown by the walk.
	 */
	public function graph(): CallGraph {
		final built: Null<CallGraph> = _graph;
		if (built != null) return built;
		// a project file no build runs (`ReachProject.runsInNoBuild`) holds no function that runs and no touch
		final running: Array<{ file: String, source: String }> = [for (f in _scope.files) if (!_scope.runsInNoBuild(f.file)) f];
		final g: CallGraph = CallGraph.build(running, _scope.plugin, _scope.index, _scope.facts);
		_graph = g;
		return g;
	}

	/** The parsed tree of project `file`, from the graph when it is built and from the plugin's parse cache otherwise. */
	public function treeOf(file: String): Null<QueryNode> {
		final held: Null<QueryNode> = _graph?.treeOf(file);
		if (held != null) return held;
		final source: Null<String> = _scope.sources[file];
		return source == null ? null : try _scope.plugin.parseFile(source) catch (exception: Exception) null;
	}

	/**
	 * Whether `type.name` is a library call known to run no user code (`ExecutionShape.pureLibraryCalls`): listed,
	 * declared by the indexed library type itself (not a type the project declares), and — read off that
	 * declaration — taking only parameters of a type whose values run nothing when the call converts or calls
	 * them (`inertType`). A parameter of a type parameter, `Dynamic` or an object type may be handed a value
	 * whose `toString` the call runs; `args`, when the call site is known, excuses one that is handed a string
	 * literal.
	 */
	public function isPureLibrary(g: CallGraph, type: String, name: String, ?args: Array<QueryNode>): Bool {
		if (
			!(
				(_scope.shape.execution?.pureLibraryCalls ?? []).contains('$type.$name')
				|| (_scope.shape.execution?.pureLibraryTypes ?? []).contains(type)
			)
		)
			return false;
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(type);
		final info: Null<MemberInfo> = g.types.memberOnChain(type, name);
		if (site == null || _scope.sources.exists(site.file) || info == null) return false;
		final params: Array<Null<String>> = info.paramTypeSources;
		final literals: Array<String> = _scope.shape.stringLiteralKinds ?? [];
		for (i => param in params) {
			final arg: Null<QueryNode> = args == null || i >= args.length ? null : args[i];
			if (!(param != null && inertType(param)) && !(arg != null && literals.contains(arg.kind))) return false;
		}
		return true;
	}

	/**
	 * Whether a call of the library member `type.name` runs no project code: a pure library call, or a method
	 * of the built-in array type that calls no argument and returns no string — any of them, or with `mutatorsToo`
	 * false only the non-mutating ones.
	 */
	public function runsNoUserCode(g: CallGraph, type: String, name: String, mutatorsToo: Bool): Bool {
		if (isPureLibrary(g, type, name)) return true;
		if (!(_scope.shape.arrayTypeNames ?? []).contains(type) || callsItsArgument(g, type, name)) return false;
		// a method returning a string converts the elements to one (`join`): an element's `toString` runs
		if (g.types.memberOnChain(type, name)?.returnNominal == stringTypeName()) return false;
		return (_scope.shape.execution?.nonMutatingArrayMethods ?? []).contains(name)
			|| (mutatorsToo && (_scope.shape.execution?.mutatingArrayMethods ?? []).contains(name));
	}

	/**
	 * Whether a call of `type.name` may CALL a value it is handed, read off the indexed declaration: a parameter
	 * whose written type is not a nominal (a function type `T->S`), a catch-all (`Dynamic`, `Any`), or a type
	 * that may alias a function (a typedef or abstract, or one the index does not declare — `holdsNoFunction`)
	 * can be called. A parameter typed by one of the declaring type's own type parameters cannot: nothing is
	 * known to be callable about it. True when the declaration is not indexed or a parameter is untyped.
	 */
	public function callsItsArgument(g: CallGraph, type: String, name: String): Bool {
		final info: Null<MemberInfo> = g.types.memberOnChain(type, name);
		if (info == null) return true;
		final catchAll: Array<String> = _scope.shape.catchAllTypeNames ?? [];
		final ownParams: Array<String> = g.types.generics.typeParamsOf(type);
		for (param in info.paramTypeSources) {
			final nominal: Null<String> = param == null
				? null
				: NominalTypes.outerNominalOf(
					NominalTypes.unwrapNullable(
						StringTools.trim(param), _scope.shape.memberTransparentWrapperTypeNames ?? [], _scope.plugin.typeSyntax
					),
					_scope.plugin.typeSyntax
				);
			if (nominal == null || catchAll.contains(nominal)) return true;
			if (!ownParams.contains(nominal) && !g.types.holdsNoFunction(nominal)) return true;
		}
		return false;
	}

	/**
	 * Whether the extern `type` is CLOSED over inert values: every member its declarations on the chain carry —
	 * field, parameter, return — is typed with an inert type (`inertType`), `Void`, or the type itself. Target
	 * code behind such a type can only have been handed numbers, strings and its own instances, so it holds no
	 * array or function value of the program to change or call. False when a declaration is not indexed.
	 */
	public function externClosed(g: CallGraph, type: String): Bool {
		final cached: Null<Bool> = _externClosed[type];
		if (cached != null) return cached;
		var closed: Bool = g.types.meta.isExtern(type);
		var t: Null<String> = type;
		final seen: Array<String> = [];
		while (closed && t != null && !seen.contains(t)) {
			final current: String = t;
			seen.push(current);
			final decl: Null<TypeDeclInfo> = declarationOf(current);
			if (decl == null) {
				closed = false;
				break;
			}
			final own: String -> Bool = written -> {
				final nominal: Null<String> = NominalTypes.outerNominalOf(StringTools.trim(written), _scope.plugin.typeSyntax);
				inertType(written) || nominal == current || nominal == type || nominal == _scope.shape.voidTypeName;
			};
			for (m in decl.members) {
				final written: Array<Null<String>> = m.paramTypeSources.concat([m.typeSource, m.returnNominal]);
				for (w in written) if (w != null && !own(w)) closed = false;
			}
			t = g.types.superclassOf(current);
		}
		_externClosed[type] = closed;
		return closed;
	}

	/**
	 * Whether the body-less extern member `type.name` runs no program code and changes no program value: its
	 * type is closed over inert values (`externClosed`), or it is a method the language calls IMPLICITLY — a
	 * conversion, an iteration step, an operator — that takes no value it could call (`callsItsArgument`). The
	 * second rests on a stated assumption: target code the language runs implicitly converts or steps its own
	 * receiver and calls back into the program only through a function value it is handed.
	 */
	public function externQuiet(g: CallGraph, type: String, name: String): Bool {
		if (externClosed(g, type)) return true;
		final info: Null<MemberInfo> = g.types.memberOnChain(type, name);
		final byName: Bool = info != null && !info.isStatic && (_scope.shape.execution?.implicitCallNames ?? []).contains(name);
		return info != null && (info.isImplicitCall || byName) && !callsItsArgument(g, type, name);
	}

	/**
	 * Whether the body-less extern member `type.name` may be HANDED a program object: a parameter written with a type
	 * that is neither inert (`inertType`) nor a function type, or with none. Target code reaches such an object's
	 * members by name — a `toJSON`, a `toString`, a `then` — without any call the graph can see.
	 */
	public function externTakesObject(g: CallGraph, type: String, name: String): Bool {
		final info: Null<MemberInfo> = g.types.memberOnChain(type, name);
		return info == null
			|| info.paramTypeSources.exists(p -> p == null || (_scope.plugin.typeSyntax(p)?.holdsFunction() != true && !inertType(p)));
	}

	/**
	 * The graph ids of every function member target code may reach BY NAME in a value of static type `type` it is
	 * handed — the members of each type the value may carry at run time (`runtimeTypes`), a placeholder for one of a
	 * library file not read yet — closed over what the value's instance fields
	 * and enum constructor arguments may hold: such code walks an object's
	 * fields as it walks the object (a `JSON.stringify` runs a nested value's `toJSON`). A field of an inert type or of
	 * a function type holds nothing it could call by name (a function value is the value channel's). Null when that set
	 * is not known: an abstract (the value at run time is its underlying one), a structure, a catch-all, a type parameter, a field
	 * whose type its declaration leaves to inference, a member of a kind nothing here reads, a type not declared exactly once.
	 */
	public function handedMemberIds(g: CallGraph, type: String): Null<Array<String>> {
		// noqa: complexity
		final functionKinds: Array<String> = _scope.shape.functionKinds ?? [];
		final fieldKinds: Array<String> = _scope.shape.fieldDeclKinds ?? [];
		final ctorKinds: Array<String> = _scope.shape.execution?.enumConstructorKinds ?? [];
		final wrappers: Array<String> = _scope.shape.memberTransparentWrapperTypeNames ?? [];
		final typeSyntax: TypeSyntaxReader = _scope.plugin.typeSyntax;
		final out: Array<String> = [];
		final seen: Map<String, Bool> = [];
		final written: Array<String> = [type];
		var wi: Int = 0;
		while (wi < written.length) {
			final source: String = NominalTypes.unwrapNullable(StringTools.trim(written[wi++]), wrappers, typeSyntax);
			final nominal: Null<String> = NominalTypes.outerNominalOf(source, typeSyntax);
			if (nominal == null) {
				// a function type holds a function value, which the value channel admits; any other shape is a structure
				if (typeSyntax(source)?.holdsFunction() == true) continue;
				return null;
			}
			if (inertType(source)) continue;
			final args: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(source, typeSyntax);
			for (arg in args ?? []) written.push(arg);
			if (seen.exists(nominal)) continue;
			seen[nominal] = true;
			final decl: Null<TypeDeclInfo> = declarationOf(nominal);
			if (decl == null || (_scope.shape.underlyingThisTypeKinds ?? []).contains(decl.kind)) return null;
			final types: Null<Array<String>> = runtimeTypes(g, nominal, Text);
			if (types == null) return null;
			for (t in types) {
				final d: Null<TypeDeclInfo> = declarationOf(t);
				if (d == null) return null;
				final ownParams: Array<String> = g.types.generics.typeParamsOf(t);
				for (m in d.members) {
					// what the value may hold: an instance field's value, an enum constructor's arguments
					final held: Array<Null<String>> = if (functionKinds.contains(m.kind)) {
						final id: String = g.ownMember(t, m.name) ?? placeholder(g, t, m.name);
						if (!out.contains(id)) out.push(id);
						[];
					} else if (fieldKinds.contains(m.kind))
						m.isStatic ? [] : [m.typeSource];
					else if (ctorKinds.contains(m.kind))
						m.paramTypeSources;
					else
						// a member kind nothing here reads may hold anything
						return null;
					for (heldType in held) {
						if (heldType == null) return null;
						// a value typed by one of the type's own parameters holds what the written argument says — known only
						// for the type written with its arguments, not for a supertype or subtype reached from it
						if (ownParams.contains(NominalTypes.outerNominalOf(StringTools.trim(heldType), typeSyntax) ?? '')) {
							if (t == nominal && args != null) continue;
							return null;
						}
						written.push(heldType);
					}
				}
			}
		}
		return out;
	}

	/** The language's string type: what a string literal is (`RefShape.literalTypeNames`). */
	public function stringTypeName(): Null<String> {
		return (_scope.shape.literalTypeNames ?? [])[(_scope.shape.stringLiteralKinds ?? [])[0] ?? ''];
	}

	/** Whether a value written `typeSource` runs no code when a call converts it to a string: a string, number or boolean. */
	public function inertType(typeSource: String): Bool {
		final nominal: Null<String> = NominalTypes.outerNominalOf(
			NominalTypes.unwrapNullable(
				StringTools.trim(typeSource), _scope.shape.memberTransparentWrapperTypeNames ?? [], _scope.plugin.typeSyntax
			),
			_scope.plugin.typeSyntax
		);
		final values: Array<String> =
			[for (t in (_scope.shape.literalTypeNames ?? []).iterator()) t].concat(_scope.shape.nonNullableTypeNames ?? []);
		return _scope.plugin.typeSyntax(typeSource)?.holdsFunction() != true && nominal != null && values.contains(nominal);
	}

	/**
	 * The implicitly-called functions a site of NO particular syntax may run: a conversion or a field-name fallback runs
	 * wherever a value flows, so every such member in play is admitted wherever code runs. The other families are
	 * admitted per site (`idsAt`).
	 */
	public function alwaysIds(g: CallGraph): Array<String> {
		final cached: Null<Array<String>> = _implicit;
		if (cached != null) return cached;
		final out: Array<String> = idsOf(g, [for (c in indexImplicit()) if (c.family == Always && counts(c)) c]);
		_implicit = out;
		return out;
	}

	/**
	 * The implicitly-called functions the site `at` may run: the members of its family declared on the types its
	 * operands may have at run time (`typesAt`, or `ownedTypesAt` where the facts name each operand's type) — a class's own
	 * chain and its subtypes, an abstract's own members — or, when an operand's type is not known, every member of the
	 * family in play (`counts`).
	 */
	public function idsAt(g: CallGraph, at: ImplicitSite): Array<String> {
		final out: Array<String> = [];
		for (o in ownedIdsAt(g, at)) if (!out.contains(o.id)) out.push(o.id);
		return out;
	}

	/**
	 * The implicitly-called functions the site `at` may run (`idsAt`), each with the typed type it is the member of when
	 * the facts name it (`ownedTypesAt`): which of the types sharing its type's simple name runs it — one entry for each of
	 * them that declares the member. One with no owner is reached by its simple name alone.
	 */
	public function ownedIdsAt(g: CallGraph, at: ImplicitSite): Array<OwnedId> {
		final owned: Null<Map<String, Null<Array<String>>>> = ownedTypesAt(g, at);
		final scope: Null<Array<String>> = owned == null ? typesAt(g, at) : [for (t in owned.keys()) t];
		final view: Null<FactsView> = _scope.facts;
		final out: Array<OwnedId> = [];
		function add(id: String, owner: Null<String>): Void {
			if (!out.exists(o -> o.id == id && o.owner == owner)) out.push({ id: id, owner: owner });
		}
		for (c in indexImplicit()) if (matches(c.family, at.family) && (scope == null ? counts(c) : scope.contains(c.type))) {
			final id: String = idsOf(g, [c])[0];
			final owners: Null<Array<String>> = owned == null ? null : owned[c.type];
			if (owners == null || view == null) {
				add(id, null);
				continue;
			}
			final facts: FactsView = view;
			// a type of the name that declares no such member runs none of the others'
			for (o in owners) if (facts.table.type(o)?.fields.exists(f -> facts.graphMember(o, f.name) == c.member) == true) add(id, o);
		}
		return out;
	}

	/**
	 * Every implicitly-called member that may run at all (`counts`), whatever its family: what code the walk does not
	 * read may run through the language's implicit channels on a value of any type.
	 */
	public function implicitIds(g: CallGraph): Array<String> {
		return idsOf(g, [for (c in indexImplicit()) if (counts(c)) c]);
	}

	/**
	 * The implicitly-called members code read through its compiler facts may run without a call the graph holds: those of a
	 * string conversion and of an iteration, which the facts keep as sites (`FactsView.sitesIn`) — every other implicit call
	 * is a call or a construction they name, an edge. Every such member that may run at all (`counts`).
	 */
	public function typedImplicitIds(g: CallGraph): Array<String> {
		return idsOf(g, [
			for (c in indexImplicit()) if (c.family.match(TextMember | IterationMember) && counts(c)) c
		]);
	}

	/**
	 * Record that the current question's walk entered the code at `span` of `file`, inside the type `typeName`; true
	 * when that widened what it had entered, which may widen the abstracts visible to it (`visibleAbstracts`) and so
	 * what an implicit-call site admits. What is recorded is the whole MEMBER enclosing `span` — the declarations of
	 * the locals and parameters code there reads live in it — and the enclosing type, whose own declaration types
	 * `this`.
	 */
	public function enter(g: CallGraph, file: String, span: Null<Span>, typeName: Null<String>): Bool {
		// noqa: complexity
		final tree: Null<QueryNode> = g.treeOf(file) ?? treeOf(file);
		final source: Null<String> = g.sourceOf(file) ?? _scope.sources[file];
		final member: Null<QueryNode> = span == null || tree == null ? null : outermostMember(tree, span);
		final at: Null<Span> = member?.span;
		final key: String = at == null ? '$file' : '$file:${at.from}';
		final reach: AbstractReach = abstractReach();
		var widened: Bool = false;
		function word(w: String): Void {
			if (reach.add(w)) widened = true;
		}
		if (!_entered.exists(key)) {
			_entered[key] = true;
			if (source != null) eachWord(at == null ? source : source.substring(at.from, at.to), word);
			if (tree != null && source != null)
				for (read in memberUses(file, tree, source, member ?? tree))
					if (reach.read(read)) widened = true;
			if (tree != null) for (t in literalAbstracts(member ?? tree)) word(t);
			// what the file imports is in scope in every member of it — a `using` brings in functions no code qualifies
			final fi: Null<FileInfo> = _scope.index.fileInfo(file);
			if (fi != null)
				for (group in [fi.imports].concat([for (a in fi.ambientImports) a.imports]))
					for (imp in group) eachWord(imp.raw, word);
		}
		if (typeName != null) word(typeName);
		if (widened) _implicit = null;
		return widened;
	}

	/**
	 * Whether the graph, when built, folds a node from a declaration in one of `changed` and one in another file
	 * (`CallGraph.foldsAcrossFiles`): taking the file out and back in (`refresh`) would lose what the other declaration
	 * recorded, so such an edit rebuilds the analysis instead.
	 */
	public function foldsAcrossFiles(changed: Array<{ file: String, source: String }>): Bool {
		final built: Null<CallGraph> = _graph;
		return built != null && changed.exists(f -> built.foldsAcrossFiles(f.file));
	}

	/**
	 * Take the new text of each of `changed` — project files whose declarations did not change — into the graph
	 * (when it is built): each leaves and re-enters it, and every grouping computed over the old graph is dropped.
	 */
	public function refresh(changed: Array<{ file: String, source: String }>, infos: Array<FileInfo>): Void {
		final built: Null<CallGraph> = _graph;
		if (built == null) return;
		for (f in changed) {
			built.removeFile(f.file);
		}
		built.addFiles(changed);
		for (fi in infos) built.types.refreshFile(fi);
		_unresolvedFrom = null;
		_accessFrom = null;
		_implicit = null;
		// what the index-wide scans read off the old text of those files
		_mentions = null;
		_inPlay.clear();
		_inferred.clear();
		for (f in changed) sites.forget(f.file);
	}

	/** What the generated constructor of `type` runs: each `<init>` up the superclass chain, then the first declared constructor. */
	public function generatedConstructor(g: CallGraph, type: String): Array<String> {
		final ctorName: String = _scope.shape.constructorName ?? 'new';
		final out: Array<String> = [];
		var t: Null<String> = type;
		final seen: Array<String> = [];
		while (t != null && !seen.contains(t)) {
			final current: String = t;
			seen.push(current);
			final init: String = '$current.${CallGraph.INIT_NAME}';
			if (g.node(init) != null) out.push(init);
			final declared: Null<String> = g.ownMember(current, ctorName);
			if (declared != null) {
				out.push(declared);
				break;
			}
			t = g.types.superclassOf(current);
		}
		return out;
	}

	/** Whether `type.name` constructs an instance of a class chosen at run time (`ExecutionShape.reflectiveInstantiationCalls`). */
	public function instantiates(type: String, name: String): Bool {
		final qualified: String = '$type.$name';
		return (_scope.shape.execution?.reflectiveInstantiationCalls ?? []).exists(c -> ReachHazards.lastSegments(c, 2) == qualified);
	}

	/** Add the file declaring `type` and those declaring its supertypes; a declaring file that does not parse is a blind spot. */
	public function loadType(g: CallGraph, type: String, seen: Array<String>): Null<ReachUnknown> {
		if (seen.contains(type)) return null;
		seen.push(type);
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(type);
		if (site == null) return null;
		final budget: Null<ReachUnknown> = loadFile(g, site.file);
		if (budget != null) return budget;
		if (g.skippedFiles.contains(site.file)) return SkipParse(site.file);
		for (s in g.types.supertypesOf(type)) {
			final up: Null<ReachUnknown> = loadType(g, s, seen);
			if (up != null) return up;
		}
		return null;
	}

	/**
	 * Add the library files declaring a subtype of `type` that spell `member` — the overrides a dispatch on
	 * `type` can reach — and the file of each superclass off `type`'s chain a subtype inherits the member from, which
	 * no file of the subtype spells (`CallGraph.virtualTargets`). The budget refusal of the first file past the cap is
	 * returned: an override not loaded is an override not seen. A library file that did not parse declares nothing the
	 * index could list, so one spelling `type` or `member` anywhere may hold an override: it is a blind spot.
	 */
	public function loadOverrides(g: CallGraph, type: String, member: String): Null<ReachUnknown> {
		final unparsed: Null<String> = unparsedLibraryMentioning([type, member]);
		if (unparsed != null) return SkipParse(unparsed);
		// a build compiling code the index does not hold may declare an override of it there
		if (!carriers.subtypesKnown(type))
			return OutOfScope(
				'a dispatch on the library type `$type` may reach an override the index does not hold — neither a complete '
				+ 'oracle list nor the builds\' compiler facts place every subtype of it in a file the index holds'
			);
		for (file in _scope.index.subtypes.subtypeFiles(type)) if (g.treeOf(file) == null) {
			if (g.skippedFiles.contains(file)) return SkipParse(file);
			final source: Null<String> = _scope.index.sourceOf(file);
			if (source == null || !RawSourceScan.mentionsWord(source, member)) continue;
			final budget: Null<ReachUnknown> = loadFile(g, file);
			if (budget != null) return budget;
		}
		for (sub in _scope.index.subtypes.subtypeNames(type)) {
			final holder: Null<String> = inheritedFrom(g, type, sub, member);
			final file: Null<String> = holder == null ? null : _scope.siteOf(holder)?.file;
			if (file == null || g.treeOf(file) != null) continue;
			if (g.skippedFiles.contains(file)) return SkipParse(file);
			final budget: Null<ReachUnknown> = loadFile(g, file);
			if (budget != null) return budget;
		}
		return null;
	}

	/**
	 * The superclass of `sub`, off `type`'s own chain, that the index says declares the `member` `sub` runs: the first on
	 * its superclass chain declaring one, when `sub` declares none itself. Null otherwise.
	 */
	private function inheritedFrom(g: CallGraph, type: String, sub: String, member: String): Null<String> {
		if (g.types.declaringTypeOf(sub, member) == sub) return null;
		final seen: Array<String> = [sub];
		var at: Null<String> = g.types.superclassOf(sub);
		while (at != null && !seen.contains(at)) {
			final holder: String = at;
			if (g.types.declaringTypeOf(holder, member) == holder)
				return g.types.firstOnChain(type, t -> t == holder) == null ? holder : null;
			seen.push(holder);
			at = g.types.superclassOf(holder);
		}
		return null;
	}

	/**
	 * Whether any supertype on `typeName`'s chain, itself included, carries a build macro — written on it, or recorded by
	 * the compiler facts, which also see one a supertype's `@:autoBuild` or a global macro applies; the site of the first
	 * one found.
	 */
	public function buildMacroOn(typeName: String): Null<ReachUnknown> {
		final seen: Array<String> = [];
		final queue: Array<String> = [typeName];
		while (queue.length > 0) {
			final t: String = queue.shift() ?? '';
			if (seen.contains(t)) continue;
			seen.push(t);
			final site: Null<{ file: String, span: Span }> = _scope.siteOf(t);
			final decl: Null<TypeDeclInfo> = site == null ? null : _scope.index.fileInfo(site.file)?.types.find(d -> d.name == t);
			if (site != null && decl != null && (decl.hasBuild || decl.hasAutoBuild)) return Reification(site.file, site.span);
			if (_scope.facts?.built(t) == true) return Reification(site?.file ?? '', site?.span);
			if (decl != null) for (s in decl.supertypes) queue.push(s);
		}
		return null;
	}

	/**
	 * The site of a build macro that may have made the code of `typeName` other than its text (`buildMacroOn`), or null.
	 * Where the compiler facts are the truth (`FactsView.truth`), they are the code every build compiled after its macros
	 * ran: a macro whose output they show is the text (`FactsProvenance.typeIsItsText`) changed nothing the text does not
	 * say, and is none.
	 */
	public function rewrittenBy(typeName: String): Null<ReachUnknown> {
		final built: Null<ReachUnknown> = buildMacroOn(typeName);
		final provenance: Null<FactsProvenance> = _scope.facts?.truth == true ? _scope.provenance() : null;
		if (built == null || provenance == null) return built;
		final g: CallGraph = graph();
		final held: Null<Bool> = _textual[typeName];
		final textual: Bool = held ?? provenance.typeIsItsText(g, typeName);
		// a type whose file the graph has not read yet is asked again once it has
		if (held == null && (textual || g.treeOf(_scope.siteOf(typeName)?.file ?? '') != null)) _textual[typeName] = textual;
		return textual ? null : built;
	}

	/**
	 * Read into the graph every file of the index declaring the type the typed type `owner` is written as, under the simple
	 * name of the node `id` (`FactsView.ownerFiles`): a call's fact names it as the target's owner, and the index, which
	 * holds several declarations of the name, names no one site to read (`ReachProject.siteOf`). The budget refusal of the
	 * first file past the cap is returned; null otherwise, and when the facts are not read.
	 */
	public function loadOwner(g: CallGraph, id: String, owner: String): Null<ReachUnknown> {
		final facts: Null<CallGraphFacts> = g.facts;
		final type: Null<String> = g.node(id)?.typeName;
		if (facts == null || type == null) return null;
		for (file in facts.view.ownerFiles(type, owner)) {
			final refused: Null<ReachUnknown> = loadFile(g, file);
			if (refused != null) return refused;
		}
		return null;
	}

	/**
	 * The node reading `id` as the member of the typed type `owner` alone (`CallGraphFacts.qualify`), once every file of the
	 * index declaring `owner`'s type is read into the graph; null when one cannot be, or the facts cannot read it so. Its
	 * unresolved sites and accesses join what every grouping here is computed over.
	 */
	public function qualified(g: CallGraph, id: String, owner: String): Null<FnNode> {
		final facts: Null<CallGraphFacts> = g.facts;
		final type: Null<String> = g.node(id)?.typeName;
		if (facts == null || type == null || loadOwner(g, id, owner) != null) return null;
		for (file in facts.view.ownerFiles(type, owner)) if (g.treeOf(file) == null) return null;
		final made: Null<String> = facts.qualify(g, id, owner);
		_unresolvedFrom = null;
		_accessFrom = null;
		return made == null ? null : g.node(made);
	}

	/**
	 * `rewrittenBy` of the node `node`, which reads the graph type `type`'s name as the typed type `owner`'s
	 * (`CallGraphFacts.qualify`): a build macro of that one type (`FactsView.builtAs`) whose output the facts do not show
	 * is its text (`FactsProvenance.typeIsItsTextAs`), sited at the node's file. The other types sharing the name are none
	 * of its code. A refusal is asked again once every file declaring that type is read, as `rewrittenBy`'s is.
	 */
	public function rewrittenAs(g: CallGraph, node: FnNode, type: String, owner: String): Null<ReachUnknown> {
		final view: Null<FactsView> = _scope.facts;
		if (view == null || !view.builtAs(type, owner)) return null;
		final key: String = '$type@$owner';
		final held: Null<Bool> = _textual[key];
		final textual: Bool = held ?? _scope.provenance()?.typeIsItsTextAs(g, type, owner) == true;
		if (held == null && (textual || view.ownerFiles(type, owner).foreach(f -> g.treeOf(f) != null))) _textual[key] = textual;
		return textual ? null : Reification(node.file, null);
	}

	public function unresolvedFrom(g: CallGraph, id: String): Array<UnresolvedCall> {
		var grouped: Null<Map<String, Array<UnresolvedCall>>> = _unresolvedFrom;
		if (grouped == null) {
			final built: Map<String, Array<UnresolvedCall>> = [];
			for (u in g.unresolved) {
				final list: Array<UnresolvedCall> = built[u.from] ?? [];
				list.push(u);
				built[u.from] = list;
			}
			_unresolvedFrom = built;
			grouped = built;
		}
		return grouped[id] ?? [];
	}

	public function accessFrom(g: CallGraph, id: String): Array<UnresolvedAccess> {
		var grouped: Null<Map<String, Array<UnresolvedAccess>>> = _accessFrom;
		if (grouped == null) {
			final built: Map<String, Array<UnresolvedAccess>> = [];
			for (a in g.unresolvedAccess) {
				final list: Array<UnresolvedAccess> = built[a.from] ?? [];
				list.push(a);
				built[a.from] = list;
			}
			_accessFrom = built;
			grouped = built;
		}
		return grouped[id] ?? [];
	}

	/** Whether `type` is declared once, as an abstract: a value of it is its underlying one at run time. */
	public function isAbstract(type: String): Bool {
		final decl: Null<TypeDeclInfo> = declarationOf(type);
		return decl != null && (_scope.shape.underlyingThisTypeKinds ?? []).contains(decl.kind);
	}

	/** The single indexed declaration of `type`, or null. */
	private function declarationOf(type: String): Null<TypeDeclInfo> {
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(type);
		return site == null ? null : _scope.index.fileInfo(site.file)?.types.find(d -> d.name == type);
	}

	/** The graph ids of `candidates`, deduped: the declared node, the initializer pseudo-node, or a placeholder the walk reads. */
	private function idsOf(g: CallGraph, candidates: Array<ImplicitCandidate>): Array<String> {
		final ctorName: String = _scope.shape.constructorName ?? 'new';
		final out: Array<String> = [];
		final held: Map<String, Bool> = [];
		for (c in candidates) {
			// a generated constructor runs the type's initializers: their pseudo-node once the file is read, else the
			// constructor's placeholder, which the walk expands
			final init: String = '${c.type}.${CallGraph.INIT_NAME}';
			final declared: Null<String> = c.member == CallGraph.INIT_NAME && g.node(init) != null
				? init
				: g.memberOnChain(c.type, c.member);
			final id: String = declared ?? placeholder(g, c.type, c.member == CallGraph.INIT_NAME ? ctorName : c.member);
			if (!held.exists(id)) {
				out.push(id);
				held[id] = true;
			}
		}
		return out;
	}

	/** The graph's placeholder for the library member `type.member`, counted in `placeholders` when it is new. */
	private function placeholder(g: CallGraph, type: String, member: String): String {
		if (g.node('$type.$member') == null) placeholders++;
		return g.externalNode(type, member);
	}

	/**
	 * Whether candidate `c` counts when nothing narrows its site: an abstract's member when the abstract is visible to
	 * the code entered (`visibleAbstracts`) — its own project code included, since a static call runs only where the
	 * static type is written — a project class's always, a library class's when its type is in play (`inPlay`).
	 */
	private function counts(c: ImplicitCandidate): Bool {
		if (c.isAbstract) return visibleAbstracts().exists(c.type);
		return _scope.sources.exists(c.file) || inPlay(c);
	}

	/**
	 * The types whose members the site `at` may run, or null for any: the union over its operands of `runtimeTypes`,
	 * an inert operand of a string conversion contributing none, an operand of exactly its class (`ImplicitSite.exact`) that
	 * class and the types it extends (`exactTypes`); for an iteration also the types the iterable's iterator methods
	 * return, whose `hasNext` / `next` the loop runs — under the truth only those `ExecutionShape.iterableMethodNames` return.
	 */
	private function typesAt(g: CallGraph, at: ImplicitSite): Null<Array<String>> {
		if (at.family == Literal) return null;
		// what `next` returns is an element, which the loop runs nothing on: under the truth only an iterable's iterator is
		// iterated in turn
		final iterables: Null<Array<String>> = _scope.facts?.truth == true ? _scope.shape.execution?.iterableMethodNames : null;
		final out: Array<String> = [];
		for (t in at.types) {
			if (t == null) return null;
			if (at.family == Text && inertType(t)) continue;
			final types: Null<Array<String>> = at.exact ? exactTypes(g, t) : runtimeTypes(g, t, at.family);
			if (types == null) return null;
			for (x in types) if (!out.contains(x)) out.push(x);
			if (at.family == Iteration) for (x in types) for (name in (_scope.shape.execution?.implicitCallNames ?? [])) {
				final returned: Null<String> = iterables == null || iterables.contains(name)
					? g.types.memberOnChain(x, name)?.returnNominal
					: null;
				if (returned == null) continue;
				final more: Null<Array<String>> = runtimeTypes(g, returned, at.family);
				if (more == null) return null;
				for (y in more) if (!out.contains(y)) out.push(y);
			}
		}
		return out;
	}

	/**
	 * Under the truth, the types whose members the site `at` — one the compiler facts typed (`ImplicitSite.owners`) — may
	 * run, by simple name, each with the typed types it stands for there, or null when its simple name alone is known: for
	 * each operand of a typed class or interface, that type and — unless it is an object of exactly its class — every
	 * subtype the builds typed, with every type they extend or implement; then every typed type whose instances may have
	 * left the type system (`ValueCarriers.escapedIds`), with the types it extends or implements; and for an iteration
	 * what its iterator methods return, by their simple names. Null — `typesAt` answers — when the facts are not the
	 * truth, some operand is of no such type, or the escapes are not known by type.
	 */
	private function ownedTypesAt(g: CallGraph, at: ImplicitSite): Null<Map<String, Null<Array<String>>>> {
		// noqa: complexity
		final view: Null<FactsView> = _scope.facts;
		final owners: Null<Array<Null<String>>> = at.owners;
		if (view == null || !view.truth || owners == null || !(at.family == Text || at.family == Iteration)) return null;
		final facts: FactsView = view;
		final out: Map<String, Null<Array<String>>> = [];
		function note(name: String, owner: Null<String>): Void {
			final held: Null<Array<String>> = out.exists(name) ? out[name] : [];
			if (held != null && owner != null && !held.contains(owner)) held.push(owner);
			out[name] = owner == null ? null : held;
		}
		function noteTyped(ids: Array<String>): Void {
			final typed: Array<String> = ids.copy();
			for (v in ids) for (s in facts.table.supertypesOf(v)) if (!typed.contains(s)) typed.push(s);
			for (id in typed) note(facts.graphType(id), id);
		}
		var escapes: Bool = false;
		for (i in 0...at.types.length) {
			final t: Null<String> = at.types[i];
			if (t == null) return null;
			if (at.family == Text && inertType(t)) continue;
			final owner: Null<String> = i < owners.length ? owners[i] : null;
			final kind: Null<String> = owner == null ? null : view.table.type(owner)?.kind;
			if (owner == null || !NOMINAL_KINDS.contains(kind ?? '')) return null;
			noteTyped(at.exact ? [owner] : [owner].concat(view.table.subtypesOf(owner)));
			if (!at.exact) escapes = true;
		}
		if (escapes) {
			final escaped: Null<Array<String>> = carriers.escapedIds();
			if (escaped == null) return null;
			noteTyped(escaped);
		}
		if (at.family == Iteration) {
			final iterables: Null<Array<String>> = _scope.shape.execution?.iterableMethodNames;
			for (x in [for (k in out.keys()) k]) for (name in (_scope.shape.execution?.implicitCallNames ?? [])) {
				final returned: Null<String> = iterables == null || iterables.contains(name)
					? g.types.memberOnChain(x, name)?.returnNominal
					: null;
				if (returned == null) continue;
				final more: Null<Array<String>> = runtimeTypes(g, returned, at.family);
				if (more == null) return null;
				for (y in more) note(y, null);
			}
		}
		return out;
	}

	/**
	 * The types an object built as an instance of exactly the class `type` names runs a member of: that class and every type
	 * it extends or implements — no subtype, and no instance that left the type system. Null (any) for anything but a class
	 * or an interface declared exactly once.
	 */
	private function exactTypes(g: CallGraph, type: String): Null<Array<String>> {
		final nominal: Null<String> = NominalTypes.outerNominalOf(StringTools.trim(type), _scope.plugin.typeSyntax);
		final decl: Null<TypeDeclInfo> = nominal == null ? null : declarationOf(nominal);
		if (nominal == null || decl == null) return null;
		final declared: TypeDeclInfo = decl;
		if (declared.isAnonStruct || (_scope.shape.aliasingDeclKinds ?? []).contains(declared.kind)) return null;
		final out: Array<String> = [nominal];
		var i: Int = 0;
		while (i < out.length) for (s in g.types.supertypesOf(out[i++])) if (!out.contains(s)) out.push(s);
		return out;
	}

	/**
	 * The types a value whose STATIC type is `type` may run a `family` member of: an alias is seen through; an abstract
	 * runs its own members — or, lacking one of the family, its underlying value's, which is any; a class or interface
	 * runs what its supertypes declare and its subtypes override, and — unless `escaped` is false — the value may be
	 * an instance that left the type system (`ValueCarriers.valueTypes`). Null (any) for a type not declared exactly once,
	 * a structure, a catch-all or a type parameter.
	 */
	private function runtimeTypes(g: CallGraph, type: String, family: SiteFamily, escaped: Bool = true): Null<Array<String>> {
		// an abstract's own member of the family runs on it — static calls the compiler puts where the static type is it; its
		// own conversion may convert the value it wraps in turn, as `Any`'s does, which may be anything
		final own: String = g.types.resolveAlias(NominalTypes.outerNominalOf(StringTools.trim(type), _scope.plugin.typeSyntax) ?? type);
		if (isAbstract(own) && indexImplicit().exists(c -> c.type == own && matches(c.family, family)))
			return family == Text ? null : [own];
		// otherwise the value is one of its value types, which run what they and their supertypes declare
		final values: Null<Array<String>> = escaped ? carriers.valueTypes(type) : carriers.declaredValueTypes(type);
		if (values == null) return null;
		final out: Array<String> = values.copy();
		var i: Int = 0;
		while (i < out.length) for (s in g.types.supertypesOf(out[i++])) if (!out.contains(s)) out.push(s);
		return out;
	}

	/**
	 * Whether the implicitly-called member `c` of a LIBRARY class may run at all: it runs on an instance, whatever the
	 * code holding it is typed (`Dynamic`, `Any`, a supertype, a structure), so it counts when an instance may exist at
	 * all (`constructible`). An extern's always does: target code may hand one out. (An abstract's member is a static
	 * call and is asked `visibleAbstracts` instead — see `counts`.)
	 */
	private function inPlay(c: ImplicitCandidate): Bool {
		return c.isExtern || constructible(c);
	}

	/**
	 * Whether an instance of the library class declaring `c` may exist while the program runs. Settled from the index
	 * alone, never from which files a walk happened to load, so an answer does not depend on the questions asked
	 * before it: some indexed file spells its name, or a subtype's, beyond its own declaration — a construction, a
	 * static access, an import all count — or spells a member that produces an instance or a class value from a
	 * computed name (`reflectiveProducers`), after which any class may be instantiated. A spelling is a whole word
	 * anywhere in a file's text, so the answer errs toward "in play". The stated gap: an instance made only by
	 * target-language code handed a class.
	 */
	private function constructible(c: ImplicitCandidate): Bool {
		final cached: Null<Bool> = _inPlay[c.type];
		if (cached != null) return cached;
		final answer: Bool = reflectiveProducers().exists(p -> mentioned(p.name, p.file)) || mentioned(c.type, c.file)
			|| _scope.index.subtypes.subtypeNames(c.type).exists(sub -> mentioned(sub, _scope.siteOf(sub)?.file));
		_inPlay[c.type] = answer;
		return answer;
	}

	/**
	 * The members `scope` of `tree` (the text of `file` is `source`) reads: every field access, by name and by the types
	 * its receiver may have at run time (`readOwners`; a receiver naming a type reads that type's statics), and every
	 * identifier that binds to a field of the enclosing type or to nothing at all (an import, an enum constructor — any
	 * owner). A local's name is not one: it names no declaration of another type.
	 */
	private function memberUses(file: String, tree: QueryNode, source: String, scope: QueryNode): Array<MemberRead> {
		// noqa: complexity
		final shape: RefShape = _scope.shape;
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final g: CallGraph = graph();
		final out: Array<MemberRead> = [];
		final seen: Map<String, Bool> = [];
		function push(name: String, owners: Null<Array<String>>): Void {
			final key: String = owners == null ? name : '$name@${owners.join(',')}';
			if (seen.exists(key)) return;
			seen[key] = true;
			out.push({ name: name, owners: owners });
		}
		function walk(node: QueryNode): Void {
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (name != null && span != null) {
				if (
					node.kind == shape.fieldAccessKind || node.kind == shape.nullSafeAccessKind || node.kind == shape.forceFieldAccessKind
				) {
					final receiver: Null<QueryNode> = node.children[0];
					final rs: Null<Span> = receiver?.span;
					final staticOwner: Null<String> = receiver != null && rs != null && receiver.kind == shape.identKind
						&& receiver.name != null && CallGraphNames.isTypeLike(receiver.name ?? '')
						&& TypeResolver.bindingNodeFrom(receiver.name ?? '', rs, tree, shape) == null
						? receiver.name
						: null;
					final t: Null<String> = staticOwner ?? (receiver == null ? null : sites.typeOf(file, tree, source, receiver));
					push(name, t == null ? null : readOwners(g, t, name));
				} else if (node.kind == shape.identKind || node.kind == shape.stringInterpIdentKind) {
					final decl: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, span, tree, shape);
					final enclosing: Null<String> = MemberTouchScan.typeAt(tree, span.from);
					if (decl == null)
						push(name, null);
					else if (fields.contains(decl.kind))
						push(name, enclosing == null ? null : readOwners(g, enclosing, name));
				}
			}
			for (c in node.children) walk(c);
		}
		walk(scope);
		return out;
	}

	/**
	 * The types whose declaration of the member `name` a read through a value of static type `type` may reach — its
	 * supertypes, itself and its subtypes, an alias seen through, and every type whose instances left the type system —
	 * or null (any) for an abstract, whose reads may forward to its underlying value, a structure, a catch-all or a type
	 * not declared exactly once. When the static type's own chain declares no `name`, only that chain is answered.
	 */
	private function readOwners(g: CallGraph, type: String, name: String): Null<Array<String>> {
		final decl: Null<TypeDeclInfo> = declarationOf(g.types.resolveAlias(type));
		if (decl == null || (_scope.shape.underlyingThisTypeKinds ?? []).contains(decl.kind)) return null;
		// whether the name is declared at all is the static type's question: an instance that left the type system and
		// declares it does not make a static extension, or a member a build macro generated, one the index describes
		final declared: Null<Array<String>> = runtimeTypes(g, type, Literal, false);
		if (declared == null || !declared.exists(t -> g.types.memberOnChain(t, name) != null)) return declared;
		return runtimeTypes(g, type, Literal);
	}

	/**
	 * The code of the member `r` names, as far as it can give the member a type: the words it spells (a construction,
	 * a cast, an annotation), the members it reads (`memberUses`), and the abstracts its syntax builds
	 * (`literalAbstracts`). Null when the file does not parse or does not declare that member.
	 */
	private function inferredFrom(r: InferredRef): Null<{ words: Array<String>, reads: Array<MemberRead> }> {
		final key: String = '${r.file}:${r.type}.${r.member}';
		if (_inferred.exists(key)) return _inferred[key];
		final source: Null<String> = _scope.sources[r.file] ?? _scope.index.sourceOf(r.file);
		var tree: Null<QueryNode> = _graph?.treeOf(r.file);
		if (tree == null && source != null) {
			final text: String = source;
			tree = try _scope.plugin.parseFile(text) catch (exception: Exception) null;
		}
		final kinds: Array<String> = (_scope.shape.functionKinds ?? []).concat(_scope.shape.fieldDeclKinds ?? []);
		var member: Null<QueryNode> = null;
		function find(node: QueryNode, inType: Bool): Void {
			if (member != null) return;
			final declared: Null<String> = CallGraphNames.typeNameOf(node);
			final within: Bool = declared == null ? inType : declared == r.type;
			if (within && kinds.contains(node.kind) && node.name == r.member) {
				member = node;
				return;
			}
			for (c in node.children) find(c, within);
		}
		if (tree != null) find(tree, false);
		final found: Null<QueryNode> = member;
		final span: Null<Span> = found?.span;
		final answer: Null<{ words: Array<String>, reads: Array<MemberRead> }> = if (
			tree == null || found == null || span == null || source == null
		)
			null
		else {
			final words: Array<String> = literalAbstracts(found);
			eachWord(source.substring(span.from, span.to), w -> if (!words.contains(w)) words.push(w));
			{ words: words, reads: memberUses(r.file, tree, source, found) };
		};
		_inferred[key] = answer;
		return answer;
	}

	/** The abstracts `scope` builds from syntax that writes no type name (`ExecutionShape.literalAbstractTypes`). */
	private function literalAbstracts(scope: QueryNode): Array<String> {
		final kinds: Map<String, String> = _scope.shape.execution?.literalAbstractTypes ?? [];
		final out: Array<String> = [];
		function walk(node: QueryNode): Void {
			final t: Null<String> = kinds[node.kind];
			if (t != null && !out.contains(t)) out.push(t);
			for (c in node.children) walk(c);
		}
		walk(scope);
		return out;
	}

	/** The outermost function or field declaration of `tree` whose span contains `span`, or null when none does. */
	private function outermostMember(tree: QueryNode, span: Span): Null<QueryNode> {
		final kinds: Array<String> = (_scope.shape.functionKinds ?? []).concat(_scope.shape.fieldDeclKinds ?? []);
		var node: QueryNode = tree;
		while (true) {
			var inner: Null<QueryNode> = null;
			for (c in node.children) {
				final s: Null<Span> = c.span;
				if (s != null && s.from <= span.from && span.to <= s.to) {
					inner = c;
					break;
				}
			}
			if (inner == null) return null;
			final found: QueryNode = inner;
			if (kinds.contains(found.kind)) return found;
			node = found;
		}
	}

	/**
	 * The abstract types a value may have at a site in code the current question's walk entered (`enter`): a whole word
	 * of an entered member's text; a word of the declared signature of a member that code reads (a field, a method's
	 * parameters and return, an enum constructor's arguments) — the declaration on the receiver's types when they are
	 * known, else any declaration of the name on a type already found or a supertype of one, since the receiver's
	 * static type comes from these same declarations; a member whose type is left to inference reads as its own code;
	 * the language's abstracts a value has without its name being written (`RefShape.literalAbstractTypeNames`); and,
	 * closed over each type so found, the words of its own declared signature — its alias target, supertypes,
	 * constructor, and the members the language calls on it implicitly, whose names no code spells. A static type
	 * always comes from one of these declarations, so an abstract outside the set is the static type of nothing the
	 * entered code evaluates.
	 */
	private function visibleAbstracts(): Map<String, Bool> {
		final reach: AbstractReach = abstractReach();
		reach.settle();
		return reach.found;
	}

	/** The current question's `AbstractReach`, started on first demand. */
	private function abstractReach(): AbstractReach {
		final held: Null<AbstractReach> = _reach;
		if (held != null) return held;
		var everything: Null<Array<String>> = null;
		final made: AbstractReach = new AbstractReach(
			signatureWords(), graph().types, [for (t in (_scope.shape.execution?.literalAbstractTypes ?? []).iterator()) t],
			() -> {
				final all: Array<String> = everything ?? [for (fi in _scope.index.allFiles()) for (t in fi.types) t.name];
				everything = all;
				all;
			},
			isBuilt, inferredFrom
		);
		_reach = made;
		return made;
	}

	/** Whether a build macro may rewrite `typeName` (`rewrittenBy`), answered once per type. */
	private function isBuilt(typeName: String): Bool {
		final held: Null<Bool> = _built[typeName];
		if (held != null) return held;
		final built: Bool = rewrittenBy(typeName) != null;
		_built[typeName] = built;
		return built;
	}

	/**
	 * The words of the index's declared signatures, computed once: by member NAME (every member so named, the
	 * constructor excepted — a construction spells its type), and by type name (alias target, supertypes, constructor,
	 * implicitly-called members).
	 */
	private function signatureWords(): SignatureWords {
		// noqa: complexity
		final cached: Null<SignatureWords> = _signatureWords;
		if (cached != null) return cached;
		final ctorName: String = _scope.shape.constructorName ?? 'new';
		final implicitNames: Array<String> = _scope.shape.execution?.implicitCallNames ?? [];
		final functionKinds: Array<String> = _scope.shape.functionKinds ?? [];
		final ctorKinds: Array<String> = _scope.shape.execution?.enumConstructorKinds ?? [];
		final out: SignatureWords = {
			byMember: [],
			byType: [],
			owners: [],
			inferredMember: [],
			inferredType: []
		};
		function words(into: Map<String, Array<String>>, key: String, text: Null<String>): Void {
			if (text == null) return;
			final list: Array<String> = into[key] ?? [];
			eachWord(text, w -> if (!list.contains(w)) list.push(w));
			into[key] = list;
		}
		for (fi in _scope.index.allFiles()) {
			for (t in fi.types) {
				words(out.byType, t.name, t.aliasTargetRaw);
				for (sup in t.supertypesRaw) words(out.byType, t.name, sup);
				for (m in t.members) {
					final implicit: Bool = m.isImplicitCall || implicitNames.contains(m.name) || m.name == ctorName;
					final key: String = implicit ? t.name : '${m.name}@${t.name}';
					final into: Map<String, Array<String>> = implicit ? out.byType : out.byMember;
					words(into, key, m.typeSource);
					words(into, key, m.returnNominal);
					for (p in m.paramTypeSources) words(into, key, p);
					if (!implicit) {
						final owners: Array<String> = out.owners[m.name] ?? [];
						if (!owners.contains(t.name)) owners.push(t.name);
						out.owners[m.name] = owners;
					}
					// a value of an enum constructor, or of an enum abstract's value, has the declaring type itself
					words(into, key, t.name);
					// a type the declaration does not write is inferred from the member's own code (`inferredFrom`)
					final written: Null<String> = functionKinds.contains(m.kind) ? m.returnNominal : m.typeSource;
					if (written == null && m.name != ctorName && !ctorKinds.contains(m.kind)) {
						final inferredInto: Map<String, Array<InferredRef>> = implicit ? out.inferredType : out.inferredMember;
						final list: Array<InferredRef> = inferredInto[key] ?? [];
						list.push({ file: fi.file, type: t.name, member: m.name });
						inferredInto[key] = list;
					}
				}
			}
		}
		_signatureWords = out;
		return out;
	}

	/**
	 * Whether an indexed file spells `word` beyond the one spelling that DECLARES it in `declaringFile` (a type's name
	 * in its header, a member's name in its signature): any spelling in another file, or a second one in that file.
	 */
	private function mentioned(word: String, declaringFile: Null<String>): Bool {
		final byFile: Null<Map<String, Int>> = mentions()[word];
		if (byFile == null) return false;
		for (file => count in byFile) if (file != declaringFile || count > 1) return true;
		return false;
	}

	/**
	 * The members the index declares that may yield an instance, or a class value, out of something other than the
	 * class's own name — read off the declarations: every member returning the language's class-value type
	 * (`ExecutionShape.classValueTypeName`; the std `Type.resolveClass`) or taking one (the std `Type.createInstance`,
	 * `Type.createEmptyInstance`). Over-approximated on purpose: a member that merely reads a class value only adds
	 * to what counts as in play.
	 */
	private function reflectiveProducers(): Array<{ name: String, file: String }> {
		final cached: Null<Array<{ name: String, file: String }>> = _producers;
		if (cached != null) return cached;
		final classType: Null<String> = _scope.shape.execution?.classValueTypeName;
		if (classType == null) return [];
		final functionKinds: Array<String> = _scope.shape.functionKinds ?? [];
		final isClass: Null<String> -> Bool = t ->
			t != null && NominalTypes.outerNominalOf(StringTools.trim(t), _scope.plugin.typeSyntax) == classType;
		final out: Array<{ name: String, file: String }> = [
			for (fi in _scope.index.allFiles()) for (t in fi.types) for (m in t.members)
				if (functionKinds.contains(m.kind) && (m.returnNominal == classType || m.paramTypeSources.exists(isClass)))
					{ name: m.name, file: fi.file }
		];
		_producers = out;
		return out;
	}

	/**
	 * Word -> file -> spelling count over every indexed file, for exactly the words `inPlay` can ask about: the names
	 * of the library types declaring an implicitly-called member, of their subtypes, and of the reflective producers.
	 */
	private function mentions(): Map<String, Map<String, Int>> {
		final cached: Null<Map<String, Map<String, Int>>> = _mentions;
		if (cached != null) return cached;
		final wanted: Map<String, Bool> = [];
		for (c in indexImplicit()) {
			wanted[c.type] = true;
			for (sub in _scope.index.subtypes.subtypeNames(c.type)) wanted[sub] = true;
		}
		for (p in reflectiveProducers()) wanted[p.name] = true;
		final out: Map<String, Map<String, Int>> = [];
		for (fi in _scope.index.allFiles()) {
			final source: Null<String> = _scope.sources[fi.file] ?? _scope.index.sourceOf(fi.file);
			if (source != null) eachWord(
				source, word -> if (wanted.exists(word)) {
					final byFile: Map<String, Int> = out[word] ?? [];
					byFile[fi.file] = (byFile[fi.file] ?? 0) + 1;
					out[word] = byFile;
				}
			);
		}
		_mentions = out;
		return out;
	}

	/**
	 * Every member the INDEX declares that the language may call implicitly — one carrying an implicit-call
	 * metadata, one named like an implicitly-called method, the constructor of a type constructed from a
	 * literal — as `type` and `member`, computed once: the index does not change.
	 */
	private function indexImplicit(): Array<ImplicitCandidate> {
		// noqa: complexity
		final cached: Null<Array<ImplicitCandidate>> = _indexImplicit;
		if (cached != null) return cached;
		final names: Array<String> = _scope.shape.execution?.implicitCallNames ?? [];
		final textNames: Array<String> = _scope.shape.execution?.stringConversionMethodNames ?? [];
		final functionKinds: Array<String> = _scope.shape.functionKinds ?? [];
		final ctorName: String = _scope.shape.constructorName ?? 'new';
		final indexMeta: Null<String> = _scope.shape.execution?.indexAccessMetaName;
		final indexKind: Null<String> = _scope.shape.execution?.indexOperatorOverloadKind;
		final abstractKinds: Array<String> = _scope.shape.underlyingThisTypeKinds ?? [];
		final out: Array<ImplicitCandidate> = [];
		for (fi in _scope.index.allFiles()) for (t in fi.types) {
			for (m in t.members) if (functionKinds.contains(m.kind)) {
				final add: CandidateFamily -> Void = family -> out.push({
					type: t.name,
					member: m.name,
					file: fi.file,
					family: family,
					isAbstract: abstractKinds.contains(t.kind),
					isExtern: t.isExtern
				});
				// the language calls a method by NAME only on an instance: a static `toString(x)` is an ordinary call
				if (names.contains(m.name) && !m.isStatic) add(textNames.contains(m.name) ? TextMember : IterationMember);
				if (m.operatorOverloads.length > 0) add(OperatorMember(m.operatorOverloads));
				// an index-access overload, by annotation or by the operator annotation's index form (`@:op([])`)
				final indexOperator: Bool = indexKind != null && m.operatorOverloads.contains(indexKind);
				if (indexOperator || (indexMeta != null && m.implicitCallMetas.contains(indexMeta))) add(IndexMember);
				// a conversion or a field-name fallback: any annotation that is neither an operator nor an index access
				if (m.isImplicitCall && (
					m.isImplicitConversion || m.implicitCallMetas.exists(meta ->
						meta != indexMeta && meta != _scope.shape.operatorOverloadMetaName
					)
				))
					add(Always);
			}
			if (t.constructsFromLiteral) out.push({
				type: t.name,
				member: t.members.exists(m -> m.name == ctorName) ? ctorName : CallGraph.INIT_NAME,
				file: fi.file,
				family: LiteralMember,
				isAbstract: abstractKinds.contains(t.kind),
				isExtern: t.isExtern
			});
		}
		_indexImplicit = out;
		return out;
	}

	private function loadFile(g: CallGraph, file: String): Null<ReachUnknown> {
		if (!_scope.sources.exists(file) && !_questionFiles.exists(file)) {
			_questionFiles[file] = true;
			if (++_questionFileCount > _maxLibraryFiles) return Budget('the walk grew into more than $_maxLibraryFiles library files');
		}
		if (g.skippedFiles.contains(file)) return SkipParse(file);
		if (g.treeOf(file) != null) return null;
		final source: Null<String> = _scope.sources[file] ?? _scope.index.sourceOf(file);
		if (source == null) return null;
		// past a blind spot the answer is not `Proven` whatever the library holds; a path is looked for in what is loaded
		if (stopGrowing) return Budget('the walk stopped reading library files after a blind spot');
		g.addFiles([{ file: file, source: source }]);
		_unresolvedFrom = null;
		_accessFrom = null;
		_implicit = null;
		return null;
	}

	/** The first library file of the index that did not parse, a build may compile, and spells one of `words`, or null. */
	private function unparsedLibraryMentioning(words: Array<String>): Null<String> {
		for (file in _scope.index.skippedFiles()) if (!_scope.sources.exists(file) && _scope.mayCompile(file)) {
			final source: Null<String> = _scope.index.sourceOf(file);
			if (source == null || words.exists(w -> RawSourceScan.mentionsWord(source, w))) return file;
		}
		return null;
	}

	/** Whether a member of `family` runs from a site of `site`'s family. */
	private static function matches(family: CandidateFamily, site: SiteFamily): Bool {
		return switch [family, site] {
			case [TextMember, Text], [IterationMember, Iteration], [IndexMember, Index], [LiteralMember, Literal]: true;
			case [OperatorMember(kinds), Operator(kind)]: kinds.contains(kind);
			case _: false;
		};
	}

	/** Call `visit` with each whole word of `text`, in order. */
	private static function eachWord(text: String, visit: String -> Void): Void {
		var i: Int = 0;
		final n: Int = text.length;
		while (i < n) {
			if (!RawSourceScan.isWordChar(StringTools.fastCodeAt(text, i))) {
				i++;
				continue;
			}
			final from: Int = i;
			while (i < n && RawSourceScan.isWordChar(StringTools.fastCodeAt(text, i))) i++;
			visit(text.substring(from, i));
		}
	}

	/**
	 * Under the truth, what a reflective access by a name it computes may reach on the object it acts on, which
	 * `receivers` — the fact of it each build recorded (`ReflectionFact.receiver`) — type: the simple names of the types
	 * whose members it may read, write or call, and their methods, an accessor a property access runs among them, each with
	 * the typed type it is a member of. The object is an instance of the typed class or interface its type names
	 * (`FactsView.objectClass`), of a typed subtype of it unless it is an object of exactly that class, and — unless it is
	 * `this`, which only a dispatch on an instance of its method's class or of a subclass binds — of a type whose instances
	 * escaped the type system (`ValueCarriers.escapedIds`); with each type those extend or implement. Null — any member of
	 * any object — when the facts are not the truth, no fact names a receiver, one is of no such type, or the escapes are
	 * not known.
	 */
	public function reflectedMembers(g: CallGraph, receivers: Array<ReflectionFact>): Null<ReflectedMembers> {
		final view: Null<FactsView> = _scope.facts;
		if (view == null || !view.truth || receivers.length == 0) return null;
		final facts: FactsView = view;
		final typed: Array<String> = [];
		function note(id: String): Void {
			if (!typed.contains(id)) typed.push(id);
		}
		var escapes: Bool = false;
		for (r in receivers) {
			final receiver: Null<String> = r.receiver;
			final id: Null<String> = receiver == null ? null : facts.objectClass(receiver);
			if (id == null) return null;
			note(id);
			if (r.receiverExact) continue;
			for (sub in facts.table.subtypesOf(id)) note(sub);
			if (!r.receiverSelf) escapes = true;
		}
		if (escapes) {
			final escaped: Null<Array<String>> = carriers.escapedIds();
			if (escaped == null) return null;
			for (id in escaped) note(id);
		}
		for (id in typed.copy()) for (sup in facts.table.supertypesOf(id)) note(sup);
		final types: Array<String> = [];
		final ids: Array<OwnedId> = [];
		for (id in typed) {
			final type: String = facts.graphType(id);
			if (!types.contains(type)) types.push(type);
			for (member in facts.methodsOf(id)) ids.push({ id: g.ownMember(type, member) ?? placeholder(g, type, member), owner: id });
		}
		return { types: types, ids: ids };
	}

}

/**
 * A function an implicit-call site may run (`ReachGraph.ownedIdsAt`): its graph id, and the typed type whose member it is
 * when the compiler facts say so — null when only its simple name says.
 */
typedef OwnedId = {
	final id: String;
	final owner: Null<String>;
}

/**
 * What a reflective access by a computed name may reach (`ReachGraph.reflectedMembers`): the simple names of the types
 * whose members it may touch, and the methods it may run, each with the typed type it is a member of.
 */
typedef ReflectedMembers = {
	final types: Array<String>;
	final ids: Array<OwnedId>;
}

/** An implicitly-called member the index declares, and the file declaring it. */
private typedef ImplicitCandidate = {
	var type: String;
	var member: String;
	var file: String;
	var family: CandidateFamily;

	/** Whether the declaring type is an abstract (its members are static calls) / an extern (target code may make one). */
	var isAbstract: Bool;
	var isExtern: Bool;
}

/** Which implicit channel runs a member — the family of `ImplicitSites.SiteFamily` it answers, or none in particular. */
private enum CandidateFamily {

	TextMember;
	IterationMember;
	IndexMember;
	OperatorMember(kinds: Array<String>);
	LiteralMember;

	/** A conversion or a field-name fallback: runs wherever a value flows. */
	Always;

}
