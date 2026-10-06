package anyparse.query;

import anyparse.check.FactsTypeTree;
import anyparse.check.FactsTypeTree.FactsType;
import anyparse.query.CallGraph.FnDeclaration;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.FieldFact;
import anyparse.query.CompilerFacts.HandFact;
import anyparse.query.CompilerFacts.IterationFact;
import anyparse.query.CompilerFacts.NativeFact;
import anyparse.query.CompilerFacts.NewFact;
import anyparse.query.CompilerFacts.ReflectionFact;
import anyparse.query.CompilerFacts.StringFact;
import anyparse.query.CompilerFacts.TypeFact;
import anyparse.query.CondDirectives.CondBlock;
import anyparse.query.CondDirectives.CondDirective;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.ImplicitSites.ImplicitSite;
import anyparse.query.MemberReach.ReachUnknown;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The reach analysis's reading of the compiler's facts (`CompilerFacts`): which function bodies the facts describe
 * completely enough to REPLACE the name-based reading of them, what those bodies run implicitly, and the markers that
 * make a question about them Unknown.
 *
 * A body is FACETED (`bodyFacts`) when its facts are whole and hold for every build, not only the listed ones: no
 * configuration was dropped, no marker says a fact of it has no place, its text holds no conditional directive and lies
 * in no conditional region, its graph node stands for one declaration, and nothing the compiler resolved its sites through
 * may differ in a build the list does not name: every project type it names has a header with no directive (a typedef:
 * no directive anywhere) in a file that imports nothing under a condition, every project member it names is declared
 * once, outside any conditional region, with no directive in what types it, no member it names is declared conditionally
 * anywhere in the project, and a function nested in it was typed against a body that passes the same test. A library
 * declaration is read as the index reads it, one copy for every build, as the syntactic reading reads it. Anything else
 * keeps the syntactic reading: absence of facts is never "no code". Under the truth, the pseudo-node running a type's
 * field initializers is faceted by the initializer nodes of the one typed type its name stands for (`initializerBodies`).
 *
 * A faceted body keeps the edges its syntax records (`CallGraph.addEdge`): the facts add to them, never take one away,
 * so a name a build the list does not name resolves the way the syntax reads it is still followed. A local `inline
 * function` needs no test of its own for the same reason: its body is a graph node read by its syntax, and each use of
 * it is such an edge.
 *
 * Under a list of builds declared to be every build the project ships (`reachConfigurationsComplete`), a table holding
 * exactly the listed builds, none dropped, is the TRUTH (`truth`): a build the list does not name does not exist, so no
 * declaration can read differently in one, and the facts hold every branch of a conditional region some build takes,
 * the union of what each typed. Every test above that guards against such a build is then skipped: a body holding a
 * directive or lying in a conditional region is faceted, and nothing it resolved its sites through is examined. What stays is what
 * holds in every build as much as in one: the facts are whole, none lost to a macro's expansion or a stale file, and a body another
 * graph node starts at is that node's. A node the graph folded from several declarations - of a member, one per branch of a region, or
 * of its type, one per build - is read by its id, the union of what every build typed under it, whichever declaration each read
 * (`foldedBodies`), when every declaration of its type is the one type the builds typed (`soleType`); a node of a name two types share
 * keeps its syntax — unless only one of those types declares the member, which
 * the node then is (`soleMember`). A call whose fact names one of those types as its target's owner reads the node as
 * that type's member alone (`CallGraphFacts.qualify`): of the declarations the node folds, those of that type
 * (`qualifiedDeclarations`), every one of which the graph holds, faceted by the facts of the type's own member
 * (`ownerBodies`). A body an inlined function was spliced into is
 * faceted too: the splice's facts are the body's, at the callee's positions, each run at a site of the `inlined` call whose method
 * declares it — the innermost expression of the body around the call — so a range question meeting such a site takes it, and one
 * no call's method declares from every body it meets (`CompilerFacts.within`, `CallGraphFacts.siteOf`): more than the range runs,
 * never less. What a method that runs no project code spliced in is none of the body's (`harmlessSplice`); the `inlined` call is an
 * edge to the callee's own node, whose text still answers for it. A `Reflect`/`Type` body spliced in (`reflection-inlined`) leaves
 * neither the call nor its name among the facts: a name computed at run time (`blindIn`), unless the facts name each
 * member spliced in and none reaches a member (`splicedReachesNoMember`). A faceted body's syntax then records an edge
 * only at a site its facts do not type (`CallGraphFacts.holdsBack`): at one they type, the compiler resolved the site
 * in every build there is. A local `inline function` keeps its edge under it: the compiler splices its body at its
 * declaration and types nothing at the site of its call. A faceted body's natives and reflective calls are then its
 * facts' (`truthSites`), and a project file no listed build read runs in none (`ReachProject.runsInNoBuild`) and declares nothing: the
 * index the analysis reads leaves it out (`ReachProject.readThrough`), so no type of it makes a name a build compiles a second declaration.
 */
@:nullSafety(Strict)
final class FactsView {

	/** What the graph puts in the id of a function nested in another (`CallGraph`): a local function or a lambda. */
	public static inline final NESTED_MARK: String = '#';

	/** The node kind of a field's initializer (`TypedFactsProbe`). */
	private static inline final VAR_KIND: String = 'var';

	/** The node kinds that are the body of a function (`TypedFactsProbe`). */
	public static final FUNCTION_KINDS: Array<String> = ['method', 'ctor', 'fn', 'local'];

	/** The classes whose members are reflection (`TypedFactsProbe`). */
	private static final REFLECTION_CLASSES: Array<String> = ['Reflect', 'Type'];

	/** The access of a call of a method the compiler spliced in (`CallFact.access`). */
	private static inline final INLINED: String = 'inlined';

	/** The suffix of an abstract's implementation class: its statics are the abstract's members. */
	private static inline final IMPL_SUFFIX: String = '_Impl_';

	/** The kind of an abstract's implementation class (`TypeFact.kind`). */
	private static inline final IMPL_KIND: String = 'impl';

	/** The name an abstract's constructor takes in its implementation class. */
	private static inline final IMPL_CONSTRUCTOR: String = '_new';

	/** The access of a call of a static field (`CallFact.access`): it runs on no receiver. */
	private static inline final STATIC_ACCESS: String = 'FStatic';

	/** The kind of a typed typedef (`TypeFact.kind`). */
	private static inline final TYPEDEF_KIND: String = 'typedef';

	/** The catch-all type: a value of it is an object of no class unless it escaped (`classless`). */
	private static inline final CATCH_ALL: String = 'Dynamic';

	/** The nullable wrapper: a value of it is one of its argument's, or null. */
	private static inline final NULLABLE: String = 'Null';

	/** How many typedefs `classless` reads through before it answers that a type may be a class. */
	private static inline final MAX_TYPEDEF_DEPTH: Int = 8;

	/**
	 * The reflective accesses by name that act on a field of the object itself and run nothing it holds. A property access
	 * (`getProperty`, `setProperty`) runs an accessor, which a structure may hold as a function value (js reads it off
	 * `__properties__`), so it is none.
	 */
	public static final FIELD_ACCESSES: Array<String> = ['Reflect.field', 'Reflect.setField', 'Reflect.hasField', 'Reflect.deleteField'];

	/** The call accesses whose target is a field a type declares. */
	private static final DECLARED_ACCESSES: Array<String> = ['FInstance', 'FStatic', 'FClosure', 'super', 'inlined', 'fieldValue'];

	/** The field kinds that are methods (`TypedFactsProbe`): a read of one is a function value. */
	private static final METHOD_KINDS: Array<String> = ['method', 'inline', 'dynamic'];

	/** The typed kinds (`TypeFact.kind`) a value of which is an object of a class: its members are what that class declares. */
	private static final OBJECT_KINDS: Array<String> = ['class', 'interface'];

	/** A package-qualified path's package prefix, in a type string. */
	private static final PACKAGE_PREFIX: EReg = ~/([A-Za-z_][A-Za-z0-9_]*\.)+(?=[A-Za-z_])/g;

	/** An abstract implementation class's name, in a type string. */
	private static final IMPL_NAME: EReg = ~/([A-Za-z0-9_]+)_Impl_/g;

	/** The table read. */
	public final table: CompilerFacts;

	/**
	 * Whether the table holds every build the project ships: the analysis runs under a list of builds declared complete
	 * (`reachConfigurationsComplete`) and the table holds exactly those, none dropped. The union of the facts is then
	 * what every build resolves, not only the listed ones.
	 */
	public final truth: Bool;

	/**
	 * Whether a call of `type.name` runs no project code, as the analysis owning the view classifies one
	 * (`ReachGraph.runsNoUserCode`): what an inlined call of such a method spliced in is none of the body's own code
	 * (`harmlessSplice`). None does until the analysis says so.
	 */
	public var runsNoUserCode: (g:CallGraph, type:String, name:String) -> Bool = (g, type, name) -> false;

	/** File -> its conditional directives and regions, scanned once. */
	private final _conditional: Map<String, ConditionalText> = [];

	/** `Type.member` or `Type` -> whether every build resolves it the same (`resolvedAlike`), settled once. */
	private final _alike: Map<String, Bool> = [];

	/** Graph type name -> the one typed type every declaration of it is (`soleType`), or null, settled once. */
	private final _sole: Map<String, Null<String>> = [];

	/** Graph type name -> the typed type the index's one declaration of it is (`declaredTyped`), or null, settled once. */
	private final _declaredTyped: Map<String, Null<String>> = [];

	/** `Type.member` of the graph -> the typed type whose member it is alone (`soleMember`), or null, settled once. */
	private final _soleMember: Map<String, Null<String>> = [];

	private final _scope: ReachProject;

	/** Graph type name -> the typed types standing for it, built on first need. */
	private var _bySimpleName: Null<Map<String, Array<String>>> = null;

	/** Typed id -> the simple names of the typedefs aliasing it (`typedefsOf`), built on first demand. */
	private var _typedefs: Null<Map<String, Array<String>>> = null;

	/** The names of the project's members declared in a conditional region (`guardedNames`), read on first need. */
	private var _guarded: Null<Map<String, Bool>> = null;

	/** The table keys of the project's files, built on first need. */
	private var _projectKeys: Null<Map<String, Bool>> = null;

	/** Table key -> the index's file, built on first need. */
	private var _byKey: Null<Map<String, FileInfo>> = null;

	/** What the code an argument is handed to does with it (`argumentUses`), made on first need. */
	private var _argumentUses: Null<ArgumentUses> = null;

	private function new(table: CompilerFacts, scope: ReachProject, truth: Bool) {
		this.table = table;
		_scope = scope;
		this.truth = truth;
	}

	/** Drop what was read off the text of `file`, which changed. */
	public function forget(file: String): Void {
		_conditional.remove(file);
		_alike.clear();
		_sole.clear();
		_soleMember.clear();
		_argumentUses = null;
	}

	/** What the code a value is handed to as an argument does with it, read off the table once per argument (`ArgumentUses`). */
	public function argumentUses(): ArgumentUses {
		final made: ArgumentUses = _argumentUses ?? new ArgumentUses(table);
		_argumentUses = made;
		return made;
	}

	/**
	 * The facts of the function the graph node `node` declares when they replace its syntax (see the type
	 * doc; under the truth, whatever a build the list does not name might read otherwise): the outermost
	 * typed function bodies inside its span. Null keeps the syntactic reading. `declarations` is how many
	 * declarations the graph folded into `node`, in any file (`CallGraph.declarationsOf`): a node folding several — or
	 * of a type the index declares more than once — is read, under the truth only, by its id (`foldedBodies`).
	 */
	public function bodyFacts(g: CallGraph, node: FnNode, declarations: Int): Null<Array<FactNode>> {
		final type: Null<String> = node.typeName;
		// the graph folded several declarations into the node, of the member or of its type: under the truth, read by id
		final single: Bool = declarations == 1 && (type == null || g.types.declarationCount(type) <= 1);
		final outer: Null<Array<FactNode>> = if (single)
			typedBodies(g, node)
		else if (truth && declarations > 0)
			foldedBodies(node) ?? (nestedOwner(g, node) == null ? null : typedBodies(g, node))
		else
			null;
		if (outer == null) return null;
		for (n in outer) if (n.incomplete.exists(unplaced)) return null;
		// under the truth no build the list does not name exists, to resolve the sites otherwise
		return truth || contextAlike(g, node, outer) ? outer : null;
	}

	/**
	 * The implicit-call sites the code in `span` of `file` runs, from its facts: a string conversion of each non-String operand, of
	 * each non-String value thrown and of each argument a conversion call (`ExecutionShape.stringConversionCalls`) is handed, and the
	 * iteration of each `for` the compiler kept. Every other implicit call — an operator, a conversion, an index, an
	 * accessor, a literal construction — is a call or a construction the facts name, an edge of the graph. An operand the
	 * facts show is an object of exactly its own class (`StringFact.exact`) makes its site `exact`. A conversion call's
	 * argument is of the type its fact names (`CallFact.operand`) — the whole value's, which a flow at its range would
	 * not name when it is of the parameter's own type, nor find when an inlined body spliced the call in from another
	 * file — and of any type when it names none. Each site names the typed type of each operand where the facts give
	 * one (`ImplicitSite.owners`, `typedOwner`). Null when the innermost graph node holding `span` — read as `node`
	 * when it is that one read as one type's member (`CallGraphFacts.qualify`) — is not faceted: the syntactic sites answer.
	 */
	public function sitesIn(g: CallGraph, file: String, span: Span, ?node: String): Null<Array<ImplicitSite>> {
		if (!faceted(g, file, span, node)) return null;
		final harmless: (callee:String) -> Bool = harmlessSplice.bind(g);
		final strings: Null<Array<StringFact>> = table.within(file, span, n -> n.strings, s -> s.at, truth, harmless);
		final iterations: Null<Array<IterationFact>> = table.within(file, span, n -> n.iterations, i -> i.at, truth, harmless);
		final calls: Null<Array<CallFact>> = table.callsIn(file, span, truth, harmless);
		if (strings == null || iterations == null || calls == null) return null;
		final out: Array<ImplicitSite> = [
			for (s in strings)
				{
					family: Text,
					span: s.at.span,
					types: [simpleSource(s.operand)],
					exact: s.exact,
					owners: [typedOwner(s.operand)]
				}
		];
		for (c in calls) {
			final target: Null<String> = c.target;
			if (target == null || !convertsToString(target)) continue;
			// the value converted, as the call's fact names it: an object of exactly its class when it says so
			final operand: Null<String> = c.operand;
			out.push({
				family: Text,
				span: c.at.span,
				types: [operand == null ? null : simpleSource(operand)],
				exact: c.operandExact,
				owners: [operand == null ? null : typedOwner(operand)]
			});
		}
		for (i in iterations) out.push({
			family: Iteration,
			span: i.at.span,
			types: [simpleSource(i.iterated)],
			exact: false,
			owners: [typedOwner(i.iterated)]
		});
		return out;
	}

	/**
	 * The typed type a facts type string `type` names, seen through a wrapper that keeps its members (`Null<T>`): its id
	 * (`pack.Name`) when the table holds it, null for any other type — a function or structure type, a type parameter, an
	 * unknown, or a type no build typed.
	 */
	public function typedOwner(type: String): Null<String> {
		final t: String = unwrapped(type);
		if (t.indexOf('?') >= 0 || t.indexOf('$') >= 0) return null;
		final id: String = CompilerFacts.baseId(t);
		return table.type(id) == null ? null : id;
	}


	/**
	 * The native sites and the reflective calls the compiler typed in the code at `span` of `file`, when the facts are the
	 * truth (`truth`) and the innermost graph node holding `span` is faceted: every build's reading of that code is then
	 * among them. Null otherwise, and when a fact there has no place (`CompilerFacts.within`): the syntax answers.
	 */
	public function truthSites(g: CallGraph, file: String, span: Span, ?node: String): Null<TruthSites> {
		if (!truth || !faceted(g, file, span, node)) return null;
		final harmless: (callee:String) -> Bool = harmlessSplice.bind(g);
		final natives: Null<Array<NativeFact>> = table.within(file, span, n -> n.natives, f -> f.at, true, harmless);
		final reflection: Null<Array<ReflectionFact>> = table.within(file, span, n -> n.reflection, r -> r.at, true, harmless);
		return natives == null || reflection == null ? null : { natives: natives, reflection: reflection };
	}

	/**
	 * What the code at `span` of `file` hands the target code of the extern members `targets` (`pack.Type.field`), when the
	 * facts are the truth and the innermost graph node holding `span` is faceted: the type of each value an argument hands it
	 * (`HandFact.from`), and of each call or construction of one of them, its receiver — null for none: a static call, a
	 * construction (whose receiver is the object it makes) — and how many there are. Every splice is read, a harmless one's
	 * too. Null otherwise, and when a fact there has no place (`CompilerFacts.within`).
	 */
	public function externCalls(g: CallGraph, file: String, span: Span, targets: Array<String>, ?node: String): Null<ExternCalls> {
		if (!truth || !faceted(g, file, span, node)) return null;
		final constructor: String = _scope.shape.constructorName ?? 'new';
		function handedTo(n: FactNode): Array<HandFact> {
			return [for (h in n.handed) if (targets.contains(h.target)) h];
		}
		function callsOf(n: FactNode): Array<CallFact> {
			return [for (c in n.calls) if (targets.contains(c.target ?? '')) c];
		}
		function constructionsOf(n: FactNode): Array<NewFact> {
			return [
				for (x in n.news) if (targets.contains('${CompilerFacts.baseId(x.type)}.$constructor')) x
			];
		}
		final hands: Null<Array<HandFact>> = table.within(file, span, handedTo, h -> h.at, true);
		final calls: Null<Array<CallFact>> = table.within(file, span, callsOf, c -> c.at, true);
		final made: Null<Array<NewFact>> = table.within(file, span, constructionsOf, x -> x.at, true);
		if (hands == null || calls == null || made == null) return null;
		final receivers: Array<Null<String>> = [for (c in calls) c.access == STATIC_ACCESS ? null : c.receiver];
		return { handed: [for (h in hands) h.from], receivers: receivers, count: calls.length + made.length };
	}

	/**
	 * Whether what an inlined call of `callee` (`pack.Type.field`) spliced into a body is none of the body's own code: the
	 * method runs no project code (`runsNoUserCode`), so the `inlined` call of it, which the walk judges as any call of it,
	 * answers for all it does.
	 */
	public function harmlessSplice(g: CallGraph, callee: String): Bool {
		final dot: Int = callee.lastIndexOf('.');
		return dot > 0 && runsNoUserCode(g, graphType(callee.substr(0, dot)), callee.substr(dot + 1));
	}

	/**
	 * Whether the innermost graph node holding `span` of `file` is faceted: its facts replace its syntax. What holds `span`
	 * is one declaration of the node (`CallGraph.declarationAt`), which may be another than the one its `span` names. A
	 * node reading that one as one type's member (`CallGraphFacts.qualify`) is asked instead when `node` names it and that
	 * declaration is one it reads.
	 */
	public function faceted(g: CallGraph, file: String, span: Span, ?node: String): Bool {
		// a field initializer the pseudo-node of its type's initializers runs: faceted when a body that node is read by
		// (`initializerBodies`) holds it whole
		final pseudo: Null<FnNode> = node == null ? null : g.node(node);
		final initializers: Null<Array<FactNode>> = pseudo != null && initializerNode(pseudo) ? g.facts?.faceted[pseudo.id] : null;
		if (initializers != null) {
			final key: String = table.keyOf(file);
			return initializers.exists(n -> n.at.file == key && within(span, n.at.span));
		}
		final at: Null<FnDeclaration> = g.declarationAt(file, span.from);
		if (at == null || span.to > at.span.to) return false;
		final key: String = CallGraphNames.normalizePath(file);
		final reads: Bool = node != null && g.facts?.qualified[node]?.node == at.id
			&& g.declarationsOf(node).exists(d -> CallGraphNames.normalizePath(d.file) == key && sameRange(d.span, at.span));
		return g.facts?.faceted.exists(reads && node != null ? node : at.id) == true;
	}

	/**
	 * A mark of code meeting `span` of `file` that makes any question about it Unknown, whether the code is faceted or
	 * not: a macro's expansion, which may run code no fact and no syntax names, and a reflective member or class read as a
	 * value, which whatever later calls it runs by a name nothing here sees. An inlined reflection body
	 * (`reflection-inlined`) is none without the truth: it is a splice (`inline-site-unknown`), whose node keeps its
	 * syntax, which spells the reflective call or the call of the function holding it. Under the truth it is one: its node
	 * is faceted, and neither its facts, which lost the call and its name, nor its syntax, which spells the call only
	 * where it is written in the body and by that name, says what it reaches — unless the facts name every member whose
	 * body was spliced in and none reaches a member (`splicedReachesNoMember`). A macro's expansion is none either, under the
	 * truth, to a reader `g` hands its graph for — one reading a faceted body through its facts alone, its touches, edges,
	 * hazards and implicit calls — when the graph node holding the expansion's body is faceted (`faceted`): the facts hold the
	 * expanded code every build compiled, which runs where the call of the macro was (`CompilerFacts.expansionSites`). A
	 * reader of the syntax gets no graph: a macro's code may name a local of the code calling it, which no fact relates.
	 */
	public function blindIn(file: String, span: Span, ?g: CallGraph): Null<ReachUnknown> {
		for (n in table.nodesIn(file)) {
			if (n.generated || !meets(n.at.span, span)) continue;
			final blind: Null<ReachUnknown> = FactMarkers.first(
				n, m -> switch m {
					case MacroExpansion: truth && g != null && faceted(g, file, n.at.span) ? null : Reification(file, span);
					case ReflectionInlined:
						truth && !splicedReachesNoMember(n) ? DynamicName(file, span) : null;
					// a marker no reader knows may stand for code no text holds, as an expansion does
					case Unknown(text): Unmodelled(file, span, 'facts marker $text');
					case StaleForeign | InlineSite | ReflectionUnattributed | ReflectionFrom(_): null;
				}
			);
			if (blind != null) return blind;
			for (r in n.reflection) if (r.isValue && meets(r.at.span, span)) return DynamicName(file, r.at.span);
		}
		return null;
	}

	/**
	 * Whether no `Reflect`/`Type` body spliced into `n` reaches a member: each is of a member the facts name
	 * (`splicedReflection`) that is no access by name (`ExecutionShape.reflectiveNameCalls`, whose lost call the reading of
	 * the node's facts would miss) and reads no member's value (`FactsMethodValues.memberless`). What else the bodies run,
	 * their calls and accesses, is among the node's facts.
	 */
	private function splicedReachesNoMember(n: FactNode): Bool {
		final members: Null<Array<String>> = splicedReflection(n);
		final named: Map<String, Int> = _scope.shape.execution?.reflectiveNameCalls ?? [];
		return members != null
			&& members.foreach(m -> !named.exists(ReachHazards.lastSegments(m, 2)) && FactsMethodValues.memberless(table, m));
	}

	/**
	 * The `Reflect`/`Type` members whose bodies were spliced into `n` (`reflection-inlined`): every method a fact of that
	 * code lies in the declared code of (`reflection-from:`, `TypedFactsWalk`) and every one an `inlined` call of the node
	 * names. Null when a fact of such code lies in no method's declared code (`reflection-unattributed`), or none is named:
	 * what that code stands in for is lost.
	 */
	public static function splicedReflection(n: FactNode): Null<Array<String>> {
		if (FactMarkers.carries(n, m -> m.match(ReflectionUnattributed))) return null;
		final out: Array<String> = [];
		for (c in n.incomplete) switch FactMarkers.read(c) {
			case ReflectionFrom(method):
				out.push(method);
			case StaleForeign | InlineSite | MacroExpansion | ReflectionInlined | ReflectionUnattributed | Unknown(_):
		}
		if (out.length == 0) return null;
		for (c in n.calls) {
			final target: Null<String> = c.target;
			final dot: Int = target == null ? -1 : target.lastIndexOf('.');
			if (
				target != null && c.access == INLINED && dot > 0 && REFLECTION_CLASSES.contains(target.substr(0, dot))
				&& !out.contains(target)
			)
				out.push(target);
		}
		return out;
	}

	/**
	 * The graph's name for the typed type `id`: its simple name, the generic class for a `@:generic` instance, the
	 * abstract for its implementation class.
	 */
	public function graphType(id: String): String {
		var base: String = CompilerFacts.baseId(id);
		final generic: Null<String> = table.type(base)?.genericOf;
		if (generic != null) base = CompilerFacts.baseId(generic);
		final simple: String = base.substr(base.lastIndexOf('.') + 1);
		return simple.endsWith(IMPL_SUFFIX) ? simple.substr(0, simple.length - IMPL_SUFFIX.length) : simple;
	}

	/**
	 * The graph's name for the field `field` of the typed type `typeId`: its own, save an abstract's constructor, which is
	 * `_new` in its implementation class.
	 */
	public function graphMember(typeId: String, field: String): String {
		return field == IMPL_CONSTRUCTOR && table.type(typeId)?.kind == IMPL_KIND ? _scope.shape.constructorName ?? 'new' : field;
	}

	/** The typed subtypes of `type` that declare an instance method `name`, by graph id: overrides a dispatch on it reaches. */
	public function overrides(g: CallGraph, type: String, name: String): Array<String> {
		final out: Array<String> = [];
		for (sub in table.subtypesOf(CompilerFacts.baseId(type))) {
			final declared: Null<TypeFact> = table.type(sub);
			if (declared == null || !declared.fields.exists(f ->
				f.name == name && !f.isStatic && f.kinds.exists(k -> METHOD_KINDS.contains(k))
			))
				continue;
			final graphed: String = graphType(sub);
			final id: String = g.ownMember(graphed, name) ?? g.externalNode(graphed, name);
			if (!out.contains(id)) out.push(id);
		}
		return out;
	}

	/** Whether the typed type `owner` declares `name` as a method in some build: a read of it there is a function value. */
	public function isMethod(owner: String, name: String): Bool {
		return
			table.type(CompilerFacts.baseId(owner))?.fields.exists(f ->
				f.name == name && f.kinds.exists(k -> METHOD_KINDS.contains(k))
			) ?? false;
	}

	/** Whether a call of `target` converts its argument to a string (`ExecutionShape.stringConversionCalls`). */
	public function convertsToString(target: String): Bool {
		return (_scope.shape.execution?.stringConversionCalls ?? []).contains(target);
	}

	/**
	 * Whether a build macro may rewrite a typed type the graph calls `type`, of those whose code its text is
	 * (`provenanceTypes`): one of them records a `@:build`-family call.
	 */
	public function built(type: String): Bool {
		return provenanceTypes(type).exists(id -> (table.type(id)?.builds.length ?? 0) > 0);
	}

	/**
	 * The typed types the graph type `type` stands for in a question of whether its code is its text (`built`,
	 * `FactsProvenance.typeIsItsText`): under the truth, the ones standing for the type the index's one declaration of
	 * the name is, when the builds typed it (`declaredTyped`) — a type of the name the index does not hold (lime's `Endian`
	 * beside openfl's) is none of that text's code, and its build macro rewrites none of it. Every typed type of the name
	 * otherwise: without the truth a build no list names may type another one there.
	 */
	public function provenanceTypes(type: String): Array<String> {
		final own: Null<String> = declaredTyped(type);
		return own == null ? bySimpleName()[type] ?? [] : standingFor(type, own);
	}

	/**
	 * Under the truth, the typed type every declaration of the graph type `type` the index holds is — one declaration, or a
	 * copy of it per build, all naming one type (`declaredIds`) — when the builds typed it; null otherwise. Unlike `soleType`,
	 * a typed type of the name the index does not hold may stand beside it.
	 */
	public function declaredTyped(type: String): Null<String> {
		if (!truth) return null;
		if (_declaredTyped.exists(type)) return _declaredTyped[type];
		final declared: Array<String> = declaredIds(type);
		final own: Null<String> = declared.length == 1 && standingFor(type, declared[0]).length > 0 ? declared[0] : null;
		_declaredTyped[type] = own;
		return own;
	}

	/**
	 * The type the compiler gave the expression at `span` of `file`, spelled as a declaration would (`simpleSource`), when
	 * the graph node holding it is faceted; null otherwise.
	 */
	public function typeSourceAt(g: CallGraph, file: String, span: Span): Null<String> {
		if (!faceted(g, file, span)) return null;
		final type: Null<String> = table.typeOfExpressionAt(file, span);
		return type == null ? null : simpleSource(type);
	}

	/** The property an accessor name serves (`get_x` -> `x`), or null for a name no accessor prefix starts. */
	public function accessorProperty(name: String): Null<String> {
		for (prefix in _scope.shape.accessorMethodPrefixes ?? []) if (name.startsWith(prefix)) return name.substr(prefix.length);
		return null;
	}

	/** The index's file whose table key is `key`, or null. */
	public function indexedFile(key: String): Null<FileInfo> {
		var byKey: Null<Map<String, FileInfo>> = _byKey;
		if (byKey == null) {
			final built: Map<String, FileInfo> = [for (fi in _scope.index.allFiles()) table.keyOf(fi.file) => fi];
			_byKey = built;
			byKey = built;
		}
		return byKey[key];
	}

	/**
	 * The one type the builds typed that every declaration of the graph type `type` the index holds is, when the facts are
	 * the truth: each declaration names it — a copy of it per target, a declaration of it in each branch of a conditional
	 * region — and every typed type the graph calls `type` is it, an instance of it (`@:generic`), its implementation
	 * class or a typedef aliasing it. Null otherwise: two types share the simple name, a declaration no build typed may
	 * run under another name (`@:genericBuild`), or the facts are not the truth.
	 */
	public function soleType(type: String): Null<String> {
		if (!truth) return null;
		if (_sole.exists(type)) return _sole[type];
		final declared: Array<String> = declaredIds(type);
		final id: Null<String> = declared.length == 1 ? declared[0] : null;
		final typed: Array<String> = bySimpleName()[type] ?? [];
		final sole: Null<String> = id != null && table.type(id) != null && typed.foreach(t -> standsFor(t, id)) ? id : null;
		_sole[type] = sole;
		return sole;
	}

	/**
	 * The typed type whose member `name` the graph's `type.name` is, when the facts are the truth and the simple name `type`
	 * stands for several typed types (`soleType` answers null) of which only one holds a function body for a member so named,
	 * and every declaration of a type so named the index holds that declares `name` is that one — itself, the class of a
	 * `@:generic` instance, the abstract of an implementation class: the graph folded no other declaration's member into the
	 * node, and a declaration no build typed, which may run under another name (`@:genericBuild`), declares none. A typed
	 * type the index does not hold declaring the member with no body (an interface's) is none of it: a dispatch on it reaches
	 * the implementations through the facts' own edges (`CallGraphFacts.virtualEdges`). Answers that typed type, whose node
	 * the member's body is read by (`foldedBodies`); null otherwise.
	 */
	public function soleMember(type: String, name: String): Null<String> {
		if (!truth) return null;
		final key: String = '$type.$name';
		if (_soleMember.exists(key)) return _soleMember[key];
		final holders: Array<String> = [];
		for (t in bySimpleName()[type] ?? []) {
			final fact: Null<TypeFact> = table.type(t);
			if (fact == null || !fact.fields.exists(f -> graphMember(t, f.name) == name)) continue;
			final own: String = fact.kind == IMPL_KIND && name == (_scope.shape.constructorName ?? 'new') ? IMPL_CONSTRUCTOR : name;
			final body: Null<FactNode> = table.node('$t.$own');
			if (body != null && FUNCTION_KINDS.contains(body.kind) && !body.generated) holders.push(t);
		}
		final holder: Null<String> = holders.length == 1 ? holders[0] : null;
		final root: Null<String> = holder == null ? null : rootOf(holder);
		var sole: Null<String> = root == null ? null : holder;
		for (fi in _scope.index.allFiles())
			for (t in fi.types)
				if (t.name == type && !CallGraphNames.selfAlias(t) && t.members.exists(m -> m.name == name) && declaredId(fi, t) != root)
					sole = null;
		_soleMember[key] = sole;
		return sole;
	}

	/**
	 * The typed type declaring the member `name` whose read at `span` of `file` the compiler resolved, when the facts are the
	 * truth and pin it as one of the types the graph's simple name `type` stands for: every field fact of `name` placed at
	 * exactly that range — at least one — names the same declaring type, written (`rootOf`) as a type the index declares
	 * under the name `type` (`ownerFiles`). Null otherwise: no build typed the read there, the builds typed it on different
	 * types, or on one the index declares under another name — a supertype's member, a typedef.
	 */
	public function pinnedOwner(g: CallGraph, file: String, span: Span, type: String, name: String): Null<String> {
		if (!truth) return null;
		final key: String = table.keyOf(file);
		final facts: Null<Array<FieldFact>> = table.within(file, span, n -> n.fields, f -> f.at, true, harmlessSplice.bind(g));
		var owner: Null<String> = null;
		for (f in facts ?? []) if (f.field == name && f.at.file == key && sameRange(f.at.span, span)) {
			final declared: Null<String> = f.owner;
			final root: Null<String> = declared == null ? null : rootOf(declared);
			if (root == null || (owner != null && owner != root)) return null;
			owner = root;
		}
		final pinned: Null<String> = owner;
		return pinned != null && ownerFiles(type, pinned).length > 0 ? pinned : null;
	}

	/**
	 * Every typed type whose member `name` the graph's `type.name` may be, when the facts are the truth: each type the simple
	 * name `type` stands for (`bySimpleName`) that declares a method so named in some build — a variable so named is no code
	 * of the node: a read of it runs nothing, a call of it what it holds — when every declaration of a type so named the
	 * index holds that declares `name` is a type the builds typed (`rootOf`). Null otherwise, and when none declares it.
	 */
	public function ownersDeclaring(type: String, name: String): Null<Array<String>> {
		if (!truth) return null;
		final typed: Array<String> = bySimpleName()[type] ?? [];
		final owners: Array<String> = [
			for (t in typed)
				if (
					table.type(t)?.fields.exists(f ->
						graphMember(t, f.name) == name && f.kinds.exists(k -> METHOD_KINDS.contains(k))
					) == true
				)
					t
		];
		if (owners.length == 0) return null;
		final roots: Array<Null<String>> = [for (t in typed) rootOf(t)];
		for (fi in _scope.index.allFiles())
			for (t in fi.types)
				if (t.name == type && !CallGraphNames.selfAlias(t) && t.members.exists(m ->
					m.name == name
				) && !roots.contains(declaredId(fi, t)))
					return null;
		return owners;
	}

	/**
	 * The simple names of the typedefs the builds typed as an alias of the type `type` (a typed id): the name a text may
	 * write for it — a typedef each build points at its own platform's class.
	 */
	public function typedefsOf(type: String): Array<String> {
		var held: Null<Map<String, Array<String>>> = _typedefs;
		if (held == null) {
			final built: Map<String, Array<String>> = [];
			for (ids in bySimpleName()) for (id in ids) {
				final fact: Null<TypeFact> = table.type(id);
				if (fact == null || fact.kind != TYPEDEF_KIND) continue;
				for (target in fact.targets) {
					final base: String = CompilerFacts.baseId(target);
					final names: Array<String> = built[base] ?? [];
					final name: String = graphType(id);
					if (!names.contains(name)) names.push(name);
					built[base] = names;
				}
			}
			_typedefs = built;
			held = built;
		}
		return held[CompilerFacts.baseId(type)] ?? [];
	}

	/** Graph type name -> the typed types standing for it. */
	public function bySimpleName(): Map<String, Array<String>> {
		final held: Null<Map<String, Array<String>>> = _bySimpleName;
		if (held != null) return held;
		final out: Map<String, Array<String>> = [];
		for (id in table.typeIds()) {
			final simple: String = graphType(id);
			final list: Array<String> = out[simple] ?? [];
			list.push(id);
			out[simple] = list;
		}
		_bySimpleName = out;
		return out;
	}

	/**
	 * The facts of the member `node` the graph folded from several declarations of one typed type (`soleType`), read by
	 * id rather than by range — or, where the name stands for several typed types, of the one of them that alone declares
	 * the member (`soleMember`): its body and each further overload of it, every one the union over the builds that typed
	 * it, whichever declaration each build read. Null when the node is a nested function, which has no id of its own to
	 * read by, when the type is not one (`soleType`), or when one of those bodies was not typed as a function or was
	 * placed by a macro.
	 */
	private function foldedBodies(node: FnNode): Null<Array<FactNode>> {
		final type: Null<String> = node.typeName;
		final name: Null<String> = node.name;
		if (type == null || name == null || node.id.indexOf(NESTED_MARK) >= 0) return null;
		final member: String = name;
		final whole: Null<String> = soleType(type);
		// a name several typed types share may still name one type's member (`soleMember`)
		final sole: Null<String> = whole != null && table.type(whole)?.fields.exists(f -> f.name == member) == true
			? whole
			: soleMember(type, member);
		return sole == null ? null : ownerBodies(sole, member);
	}

	/**
	 * Under the truth, the facts of the field initializers the pseudo-node `node` runs (`CallGraph.INIT_NAME`: the instance
	 * ones; `STATIC_INIT_NAME`: the static ones): every initializer (`VAR_KIND`) of that staticness of each typed type its
	 * type name stands for (`initializerOwners`) — the union over the builds, every branch some build takes. Null — the
	 * syntax reads them — otherwise, and when one was placed by a macro or lost a fact's place. An initializer the syntax
	 * holds that none of them holds whole stays the syntax's (`faceted`).
	 */
	public function initializerBodies(node: FnNode): Null<Array<FactNode>> {
		final type: Null<String> = node.typeName;
		if (!truth || type == null || !initializerNode(node)) return null;
		final isStatic: Bool = node.name == CallGraph.STATIC_INIT_NAME;
		final owners: Null<Array<String>> = initializerOwners(type);
		if (owners == null) return null;
		final out: Array<FactNode> = [];
		for (typed in owners) for (id in table.nodeIdsOf(typed)) {
			final n: Null<FactNode> = table.node(id);
			if (n == null) return null;
			if (n.kind != VAR_KIND || n.isStatic != isStatic) continue;
			if (n.generated || n.incomplete.exists(unplaced)) return null;
			out.push(n);
		}
		return out;
	}

	/**
	 * Under the truth, the typed types whose field initializers the pseudo-nodes of the graph type `type` run
	 * (`CallGraph.INIT_NAME`, `STATIC_INIT_NAME`): the one type every declaration of the name is (`soleType`) — or, of a name
	 * several typed types share, every one of them, when each declaration of the name the index holds is one of them
	 * (`rootOf`). Such a node no call names by a member of its type: a construction or an admission by its name runs the
	 * initializers of whichever type so named it is, so the union of theirs is all it may run. Null otherwise: a declaration
	 * no build typed may run under another name (`@:genericBuild`).
	 */
	public function initializerOwners(type: String): Null<Array<String>> {
		if (!truth) return null;
		final sole: Null<String> = soleType(type);
		if (sole != null) return [sole];
		final owners: Array<String> = bySimpleName()[type] ?? [];
		final roots: Array<Null<String>> = [for (o in owners) rootOf(o)];
		for (fi in _scope.index.allFiles())
			for (t in fi.types)
				if (t.name == type && !CallGraphNames.selfAlias(t) && !roots.contains(declaredId(fi, t))) return null;
		return owners.length == 0 ? null : owners;
	}

	/** Whether `node` is a pseudo-node running its type's field initializers (`CallGraph.INIT_NAME`, `STATIC_INIT_NAME`). */
	public static function initializerNode(node: FnNode): Bool {
		return node.span == null && (node.name == CallGraph.INIT_NAME || node.name == CallGraph.STATIC_INIT_NAME);
	}

	/**
	 * The facts of the member the graph calls `member` of the typed type `owner`: its body and each further overload of it,
	 * every one the union over the builds that typed it, whichever declaration each build read. Null when `owner` declares
	 * no such field, or one of those bodies was not typed as a function or was placed by a macro.
	 */
	public function ownerBodies(owner: String, member: String): Null<Array<FactNode>> {
		final field: Null<FieldDeclFact> = table.type(owner)?.fields.find(f -> graphMember(owner, f.name) == member);
		if (field == null) return null;
		final own: String = field.name;
		var overloads: Int = 0;
		for (n in field.overloads) if (n > overloads) overloads = n;
		final out: Array<FactNode> = [];
		for (i in 0...overloads + 1) {
			final found: Null<FactNode> = table.node(i == 0 ? '$owner.$own' : '$owner.$own~$i');
			if (found == null || found.generated || !FUNCTION_KINDS.contains(found.kind)) return null;
			out.push(found);
		}
		return out;
	}

	/**
	 * Of the declarations the graph node `node` folds (`CallGraph.declarationsOf`), the ones of the type `owner` is written
	 * as (`rootOf`), when every one of them can be told: each lies in a type of the node's name its text declares and the
	 * index lists in its file — every copy of a type in one module, one per branch of a region, being that one type — whose
	 * package-qualified id is that type's or another's — and every declaration of `owner`'s type the index holds that
	 * declares the member lies in a file among them, so none of its code is missing from the graph. Null otherwise, or when
	 * none is `owner`'s.
	 */
	public function qualifiedDeclarations(g: CallGraph, node: FnNode, owner: String): Null<Array<FnDeclaration>> {
		final type: Null<String> = node.typeName;
		final name: Null<String> = node.name;
		final root: Null<String> = rootOf(owner);
		if (type == null || name == null || root == null) return null;
		final out: Array<FnDeclaration> = [];
		for (d in g.declarationsOf(node.id)) {
			// the type its text declares it in: the index lists a type once per file, whatever branch of a region each copy is in
			final fi: Null<FileInfo> = _scope.index.fileInfo(d.file);
			final tree: Null<QueryNode> = g.treeOf(d.file);
			final holder: Null<String> = tree == null ? null : MemberTouchScan.typeAt(tree, d.span.from);
			final listed: Null<TypeDeclInfo> = fi?.types.find(t -> t.name == type);
			if (fi == null || listed == null || holder != type) return null;
			if (declaredId(fi, listed) == root) out.push(d);
		}
		final read: Array<String> = [for (d in out) CallGraphNames.normalizePath(d.file)];
		for (file in ownerFiles(type, owner, name)) if (!read.contains(CallGraphNames.normalizePath(file))) return null;
		return out.length == 0 ? null : out;
	}

	/**
	 * Under the truth, the typed type whose code the function nested in a member (`NESTED_MARK`) the graph node `node` is,
	 * read off where its text lies: its one declaration lies in the type of the node's simple name its file declares, and the
	 * builds typed that type (`typedIn`). Such a node no call names: a function value, a local function, reached from the
	 * code holding it or by the value channel, so the name other types share stands for none of theirs. Null otherwise — a
	 * node several declarations fold, one in a type of another name, a file whose type no build typed.
	 */
	public function nestedOwner(g: CallGraph, node: FnNode): Null<String> {
		final type: Null<String> = node.typeName;
		final declared: Array<FnDeclaration> = g.declarationsOf(node.id);
		if (!truth || type == null || node.id.indexOf(NESTED_MARK) < 0 || declared.length != 1) return null;
		final tree: Null<QueryNode> = g.treeOf(declared[0].file);
		if (tree == null || MemberTouchScan.typeAt(tree, declared[0].span.from) != type) return null;
		return typedIn(declared[0].file, type);
	}

	/**
	 * The package-qualified id of the type the index lists in `file` under the simple name `type`, when the builds typed it
	 * (`standingFor`); null otherwise — the file declares no type so named, or no build typed the one it does.
	 */
	public function typedIn(file: String, type: String): Null<String> {
		final fi: Null<FileInfo> = _scope.index.fileInfo(file);
		final listed: Null<TypeDeclInfo> = fi?.types.find(t -> t.name == type);
		if (fi == null || listed == null) return null;
		final id: String = declaredId(fi, listed);
		return standingFor(type, id).length > 0 ? id : null;
	}

	/** The typed types of the graph type `type` standing for the type `owner` is written as (`rootOf`, `standsFor`). */
	public function standingFor(type: String, owner: String): Array<String> {
		final root: Null<String> = rootOf(owner);
		return root == null ? [] : [for (id in bySimpleName()[type] ?? []) if (standsFor(id, root)) id];
	}

	/**
	 * Whether a build macro may rewrite the type the typed type `owner` is written as, of the several the graph type `type`
	 * names: a typed type standing for it (`standingFor`), or one it extends or implements, records a `@:build`-family call.
	 */
	public function builtAs(type: String, owner: String): Bool {
		for (id in standingFor(type, owner))
			for (t in [id].concat(table.supertypesOf(CompilerFacts.baseId(id))))
				if ((table.type(t)?.builds.length ?? 0) > 0) return true;
		return false;
	}

	/**
	 * The files of the index declaring the type `owner` is written as (`rootOf`) under the simple name `type` — only those
	 * declaring a member `name` of it, when given.
	 */
	public function ownerFiles(type: String, owner: String, ?name: String): Array<String> {
		final root: Null<String> = rootOf(owner);
		final out: Array<String> = [];
		function declares(fi: FileInfo, t: TypeDeclInfo): Bool {
			return t.name == type && declaredId(fi, t) == root && (name == null || t.members.exists(m -> m.name == name));
		}
		if (root != null) for (fi in _scope.index.allFiles()) if (fi.types.exists(declares.bind(fi))) out.push(fi.file);
		return out;
	}

	/**
	 * Whether a build typed the code of the graph node `node`, whose declarations are `declared`, in a file none of them
	 * lies in: a copy of its type each build reads from its own (`CompilerFacts.typeHomes`) the graph does not hold. Each
	 * copy's code is read at its own ranges (`CompilerFacts.nodesIn`), which no declaration here asks of. Asked of the
	 * typed types the declarations' own types are written as (`rootOf`) — the graph's other types of the name are none of
	 * the node's — each body and overload of the member they type at a range of a file; one a macro placed, at no range,
	 * is read by its id. False for a nested function, whose enclosing node answers.
	 */
	public function typedElsewhere(g: CallGraph, node: FnNode, declared: Array<FnDeclaration>): Bool {
		final type: Null<String> = node.typeName;
		final name: Null<String> = node.name;
		if (type == null || name == null || node.id.indexOf(NESTED_MARK) >= 0) return false;
		final keys: Array<String> = [];
		final roots: Array<String> = [];
		for (d in declared) {
			keys.push(table.keyOf(d.file));
			final fi: Null<FileInfo> = _scope.index.fileInfo(d.file);
			final t: Null<TypeDeclInfo> = fi?.types.find(x -> x.name == type);
			final id: Null<String> = fi == null || t == null ? null : declaredId(fi, t);
			if (id != null && !roots.contains(id)) roots.push(id);
		}
		for (t in bySimpleName()[type] ?? []) {
			final root: Null<String> = rootOf(t);
			final field: Null<FieldDeclFact> = root == null || !roots.contains(root)
				? null
				: table.type(t)?.fields.find(f -> graphMember(t, f.name) == name);
			if (field == null) continue;
			var overloads: Int = 0;
			for (n in field.overloads) if (n > overloads) overloads = n;
			for (i in 0...overloads + 1)
				for (home in table.rangedHomes(i == 0 ? '$t.${field.name}' : '$t.${field.name}~$i'))
					if (!keys.contains(home)) return true;
		}
		return false;
	}

	/**
	 * The package-qualified ids of the index's declarations of the graph type `type`, each once: a copy per build, or one in
	 * each branch of a conditional region, is one. A typedef aliasing a type of its own name (`CallGraphNames.selfAlias`)
	 * declares none.
	 */
	private function declaredIds(type: String): Array<String> {
		final declared: Array<String> = [];
		for (fi in _scope.index.allFiles()) for (t in fi.types) if (t.name == type && !CallGraphNames.selfAlias(t)) {
			final named: String = declaredId(fi, t);
			if (!declared.contains(named)) declared.push(named);
		}
		return declared;
	}

	/**
	 * The type a declaration of the typed type `typed` is written as: itself, the class of a `@:generic` instance, the
	 * abstract of an implementation class; null for a typedef, which declares no member of its own.
	 */
	private function rootOf(typed: String): Null<String> {
		final fact: Null<TypeFact> = table.type(typed);
		if (fact == null || fact.kind == TYPEDEF_KIND) return null;
		final generic: Null<String> = fact.genericOf;
		return generic != null ? CompilerFacts.baseId(generic) : fact.kind == IMPL_KIND ? implemented(typed) : typed;
	}

	/**
	 * Whether the typed type `typed` is the type `id` as the graph reads it: itself, an instance of it (`@:generic`), its
	 * implementation class (an abstract's), or a typedef aliasing it.
	 */
	private function standsFor(typed: String, id: String): Bool {
		final fact: Null<TypeFact> = table.type(typed);
		if (typed == id || fact == null) return typed == id;
		final generic: Null<String> = fact.genericOf;
		if (generic != null) return CompilerFacts.baseId(generic) == id;
		if (fact.kind == IMPL_KIND) return implemented(typed) == id;
		return fact.kind == TYPEDEF_KIND && fact.targets.length > 0 && fact.targets.foreach(t -> CompilerFacts.baseId(t) == id);
	}

	/**
	 * Whether the marker `m` leaves some fact of its node without a place, so its body keeps the syntactic reading. A
	 * POSITIVE list of the markers that do not: a spliced `Reflect`/`Type` body's (`blindIn` answers for what it lost), and
	 * under the truth neither a splice nor an expression macro's expansion — the expansion is code every build compiled,
	 * typed among the node's facts, and they are the node's, which a range question takes where they run (`within`). Any
	 * other — a fact lost with its file (`stale-foreign`), a marker the facts producer has grown since — leaves one.
	 */
	private function unplaced(m: String): Bool {
		return switch FactMarkers.read(m) {
			case ReflectionInlined | ReflectionUnattributed | ReflectionFrom(_): false;
			case InlineSite | MacroExpansion: !truth;
			case StaleForeign | Unknown(_): true;
		};
	}

	/**
	 * The outermost typed function bodies inside the span of `node`, when it is the one declaration the node stands for
	 * (`CallGraph.declarationsOf`: a node folding several is read by id, `foldedBodies`) and its text holds no directive and
	 * lies in no conditional region, or the facts are the truth; null otherwise, or when none was typed. A typed body is
	 * placed by its range in `node`'s own file — from the declaration's first modifier, where the compiler places an
	 * abstract's constructor (`declarationRange`): one a configuration read from another file is none of this text.
	 */
	private function typedBodies(g: CallGraph, node: FnNode): Null<Array<FactNode>> {
		final span: Null<Span> = node.span;
		final source: Null<String> = g.sourceOf(node.file);
		if (span == null || source == null || g.declarationsOf(node.id).length != 1) return null;
		// every build typed its own branch: under the truth their union is every branch that runs
		if (!truth && conditional(node.file, source, span)) return null;
		final key: String = table.keyOf(node.file);
		// the compiler places an abstract's constructor at the declaration's first modifier
		final declared: Span = declaredIn(g.treeOf(node.file), span);
		final inside: Array<FactNode> = [
			for (n in table.nodesIn(node.file))
				if (FUNCTION_KINDS.contains(n.kind) && !n.generated && n.at.file == key && within(n.at.span, declared)) n
		];
		final outer: Array<FactNode> = [
			for (n in inside) if (!inside.exists(o -> within(n.at.span, o.at.span) && wider(o.at.span, n.at.span))) n
		];
		// a body another graph node starts at is that node's: one nested in this one, whose own facts this one has none of
		// (a local `inline function`, which the compiler types into its caller)
		for (n in outer) {
			final owner: Null<FnDeclaration> = g.declarationAt(node.file, n.at.span.from);
			if (owner != null && owner.id != node.id && owner.span.from == n.at.span.from) return null;
		}
		return outer.length == 0 ? null : outer;
	}

	/** `span` from its declaration's first modifier (`declarationRange`), as it is where `tree` is not read. */
	private static function declaredIn(tree: Null<QueryNode>, span: Span): Span {
		return (tree == null ? null : declarationRange(tree, span.from)) ?? span;
	}

	/**
	 * The range of the declaration starting at `from` in `tree`, from the start of the `@:meta` and modifier run before it
	 * (`ElementSpan.declRunStart`): the compiler places a field from its first modifier, and an abstract's constructor —
	 * `this = …` lowered into a function of the implementation class — at that very start. Null when no node starts there.
	 */
	public static function declarationRange(tree: QueryNode, from: Int): Null<Span> {
		var found: Null<{ node: QueryNode, parent: Null<QueryNode> }> = null;
		function walk(node: QueryNode, parent: Null<QueryNode>): Void {
			if (found != null) return;
			if (node.span?.from == from) {
				found = { node: node, parent: parent };
				return;
			}
			for (c in node.children) walk(c, node);
		}
		walk(tree, null);
		final held: Null<{ node: QueryNode, parent: Null<QueryNode> }> = found;
		final span: Null<Span> = held?.node.span;
		return held == null || span == null ? null : new Span(ElementSpan.declRunStart(held.node, held.parent, span), span.to);
	}

	/**
	 * Whether what the compiler typed `node`'s bodies `bodies` against reads alike in every build (`resolvedAlikeIn`) —
	 * and, for a function nested in another, what it typed the enclosing one against, which gave the nested one its
	 * expected type: a lambda's parameters are typed by the call it is handed to.
	 */
	private function contextAlike(g: CallGraph, node: FnNode, bodies: Array<FactNode>): Bool {
		if (!bodies.foreach(resolvedAlikeIn)) return false;
		final span: Null<Span> = node.span;
		if (span == null || node.id.indexOf(NESTED_MARK) < 0) return true;
		// the innermost function holding the text just before this one's: a sibling ends before a separator
		final holding: Null<FnDeclaration> = span.from > 0 ? g.declarationAt(node.file, span.from - 1) : null;
		final found: Null<FnNode> = holding == null ? null : g.node(holding.id);
		final at: Null<Span> = holding?.span;
		final enclosing: Null<FnNode> = at != null && within(span, at) && wider(at, span) ? found : null;
		final typed: Null<Array<FactNode>> = enclosing == null ? null : typedBodies(g, enclosing);
		return enclosing != null && typed != null && contextAlike(g, enclosing, typed);
	}

	/**
	 * Whether every declaration the facts of `n` resolved a site through reads the same in every build (see the type
	 * doc): each member a call or a field read names, each type a receiver, a result, a construction, a local, a
	 * parameter or a flow names.
	 */
	private function resolvedAlikeIn(n: FactNode): Bool {
		final members: Array<{ target: String, receiver: Null<String> }> = [];
		final statics: Array<String> = [];
		final types: Array<String> = [];
		for (c in n.calls) {
			final target: Null<String> = c.target;
			if (target != null && DECLARED_ACCESSES.contains(c.access)) members.push({ target: target, receiver: c.receiver });
			if (target != null && c.access == 'FStatic') statics.push(target.substr(target.lastIndexOf('.') + 1));
			types.push(c.receiver ?? c.result);
			types.push(c.result);
		}
		for (f in n.fields) {
			final owner: Null<String> = f.owner;
			members.push({ target: '${owner ?? ''}.${f.field}', receiver: f.receiver });
			types.push(f.receiver);
			types.push(f.type);
		}
		for (x in n.news) types.push(x.type);
		for (v in n.vars) types.push(v.type);
		for (p in n.params) types.push(p.type);
		for (f in n.flows) types.push(f.from + ',' + f.to);
		// a static a build calls as an extension may be shadowed there by a member another build declares
		final guarded: Map<String, Bool> = guardedNames();
		for (name in statics) if (guarded.exists(name)) return false;
		return members.foreach(m -> m.target.charAt(0) == '.' || memberAlike(m.target, m.receiver)) && types.foreach(typeAlike);
	}

	/**
	 * The names of the members the project declares inside a conditional region, and of the properties such accessors
	 * serve: a site naming one may resolve to another declaration in a build the list does not name. Read once.
	 */
	private function guardedNames(): Map<String, Bool> {
		final held: Null<Map<String, Bool>> = _guarded;
		if (held != null) return held;
		final out: Map<String, Bool> = [];
		for (f in _scope.files) for (t in _scope.index.fileInfo(f.file)?.types ?? []) for (m in t.members) if (m.guarded) {
			out[m.name] = true;
			for (prefix in _scope.shape.accessorMethodPrefixes ?? []) out[prefix + m.name] = true;
		}
		_guarded = out;
		return out;
	}

	/**
	 * Whether the member `target` (`pack.Type.field`) resolves alike in every build: its type does, it is declared once,
	 * outside any conditional region, with no directive in what types it — its signature when that is written in full,
	 * else its whole declaration — and no type on the receiver's chain declares a member of the name conditionally, which
	 * some build would resolve to instead.
	 */
	private function memberAlike(target: String, receiver: Null<String>): Bool {
		final key: String = '$target@${receiver ?? ''}';
		final held: Null<Bool> = _alike[key];
		if (held != null) return held;
		final dot: Int = target.lastIndexOf('.');
		final owner: String = CompilerFacts.baseId(target.substr(0, dot));
		final name: String = target.substr(dot + 1);
		var answer: Bool = typeAlike(owner) && declaredAlike(owner, name, true);
		if (answer && receiver != null) {
			final base: String = CompilerFacts.baseId(receiver);
			for (t in [base].concat(table.supertypesOf(base))) if (!declaredAlike(t, name, false)) answer = false;
		}
		_alike[key] = answer;
		return answer;
	}

	/**
	 * Whether the typed type `type` declares `name` alike in every build: no declaration of it lies in a conditional
	 * region, and — when `required` — exactly one exists and what types it holds no directive. A type the facts do not
	 * hold (a built-in) answers true, one whose declaration cannot be read false.
	 */
	private function declaredAlike(type: String, name: String, required: Bool): Bool {
		if (table.type(type) == null || !project(type)) return true;
		final text: Null<TypeText> = typeText(type);
		if (text == null) return false;
		final info: Null<TypeDeclInfo> = text.info;
		// a declaration the index does not hold is read whole
		if (info == null) return !conditional(text.file, text.source, text.span);
		final found: Array<MemberInfo> = [for (m in info.members) if (m.name == name) m];
		// an accessor the index does not list is its property's: `get_x` of `x(get, …)`
		final property: Null<String> = accessorProperty(name);
		if (found.length == 0 && property != null) for (m in info.members) if (m.name == property) found.push(m);
		if (found.exists(m -> m.guarded)) return false;
		if (!required) return true;
		if (found.length != 1) return false;
		final m: MemberInfo = found[0];
		final tree: Null<QueryNode> = try _scope.plugin.parseFile(text.source) catch (exception: haxe.Exception) null;
		final decl: Null<QueryNode> = tree == null ? null : RefactorSupport.nodeAtFrom(tree, m.declFrom);
		final at: Null<Span> = decl?.span;
		if (decl == null || at == null) return false;
		return !conditional(text.file, text.source, typingSpan(decl, at, m));
	}

	/**
	 * The part of the member declaration `decl` (at `at`) that decides what the member's uses are typed: a function's
	 * signature when every parameter and its result are written, a field's declaration up to its initializer when its
	 * type is written, else the whole declaration — an inferred type is read off the body.
	 */
	private function typingSpan(decl: QueryNode, at: Span, m: MemberInfo): Span {
		final shape: RefShape = _scope.shape;
		if ((shape.functionKinds ?? []).contains(decl.kind)) {
			final written: Null<QueryNode> = decl.children.find(c -> (shape.typeAnnotationKinds ?? []).contains(c.kind));
			final end: Null<Span> = written?.span;
			return end != null && !m.paramTypeSources.contains(null) ? new Span(at.from, end.to) : at;
		}
		if (m.typeSource == null) return at;
		final init: Null<Span> = decl.children.length > 0 ? decl.children[0].span : null;
		return init == null ? at : new Span(at.from, init.from);
	}

	/**
	 * Whether every path in the type string `type` names a type whose header holds no directive and lies in no
	 * conditional region — a typedef's whole declaration; a path the facts hold no type for (a built-in, a structure's
	 * field name) passes.
	 */
	private function typeAlike(type: String): Bool {
		final held: Null<Bool> = _alike[type];
		if (held != null) return held;
		var answer: Bool = true;
		final paths: EReg = ~/[A-Za-z_][A-Za-z0-9_.]*/;
		var rest: String = type;
		while (answer && paths.match(rest)) {
			final id: String = paths.matched(0);
			rest = paths.matchedRight();
			// a type that brings extensions in (`@:using`) may resolve a call on it to one the facts do not name, in a build
			// the list does not name when the annotation is conditional: the syntax refuses such a call
			if (table.type(id) != null && extendedOnChain(id)) {
				answer = false;
				continue;
			}
			if (table.type(id) == null || !project(id)) continue;
			final text: Null<TypeText> = typeText(id);
			final info: Null<TypeDeclInfo> = text?.info;
			if (text == null) {
				answer = false;
				continue;
			}
			final alias: Bool = info != null && (_scope.shape.aliasingDeclKinds ?? []).contains(info.kind)
				&& !(_scope.shape.underlyingThisTypeKinds ?? []).contains(info.kind);
			final header: Span = if (info == null || alias)
				text.span
			else
				new Span(info.span.from, info.members.fold((m, least) -> m.declFrom < least ? m.declFrom : least, info.span.to));
			// a file, or an ambient import source, importing under a condition may resolve every name in the type otherwise
			final fi: Null<FileInfo> = indexedFile(text.file);
			final guarded: Bool = fi != null
				&& (fi.imports.exists(i -> i.guarded) || fi.ambientImports.exists(a -> a.imports.exists(i -> i.guarded)));
			if (guarded || conditional(text.file, text.source, header)) answer = false;
		}
		_alike[type] = answer;
		return answer;
	}

	/** Whether the typed type `id`, or a type it extends, is declared bringing static extensions in (`@:using`). */
	private function extendedOnChain(id: String): Bool {
		final names: Array<String> = [id].concat(table.supertypesOf(CompilerFacts.baseId(id))).map(graphType);
		// read afresh: what `typeAlike` answers is kept per type
		return _scope.index.allFiles().exists(fi -> fi.types.exists(t -> t.bringsExtensions && names.contains(t.name)));
	}

	/**
	 * Whether the typed type `id` is declared in a file of the project. A library declaration is read as the index reads
	 * it, one copy for every build, as the syntactic reading reads it: its per-build variants are the library's API.
	 */
	private function project(id: String): Bool {
		var keys: Null<Map<String, Bool>> = _projectKeys;
		if (keys == null) {
			final built: Map<String, Bool> = [for (f in _scope.files) table.keyOf(f.file) => true];
			_projectKeys = built;
			keys = built;
		}
		final pos: Null<FactPos> = table.typePosition(id);
		return pos == null || keys.exists(pos.file);
	}

	/**
	 * Where the typed type `id` is declared — its file (a table key), text, range and the index's declaration of it when
	 * the index holds that file — or null when its text cannot be read as the compile read it.
	 */
	private function typeText(id: String): Null<TypeText> {
		final pos: Null<FactPos> = table.typePosition(id);
		final source: Null<String> = pos == null ? null : table.sourceOf(pos.file);
		if (pos == null || source == null) return null;
		final from: Int = pos.span.from;
		final fi: Null<FileInfo> = indexedFile(pos.file);
		var info: Null<TypeDeclInfo> = null;
		for (t in fi?.types ?? []) if (t.span.from <= from && from < t.span.to && (info == null || t.span.from >= info.span.from)) info = t;
		return {
			file: pos.file,
			source: source,
			span: pos.span,
			info: info
		};
	}

	/** Whether `span` of `file` holds a conditional directive or lies inside a conditional region. */
	private function conditional(file: String, source: String, span: Span): Bool {
		final held: ConditionalText = _conditional[file] ?? scanConditional(file, source);
		return held.whole || held.directives.exists(d -> meets(d, span)) || held.regions.exists(r -> within(span, r));
	}

	/** The directives and top-level conditional regions of `source`, kept for `file`. */
	private function scanConditional(file: String, source: String): ConditionalText {
		final directives: Array<CondDirective> = CondDirectives.scan(source, _scope.shape, _scope.plugin.lexicalRegions.bind(source));
		final blocks: Array<CondBlock> = CondDirectives.topLevelBlocks(source, directives, _scope.shape);
		final regions: Array<Span> = [for (b in blocks) b.span];
		// an unbalanced scan stops at the first region it cannot close: what follows may lie in any region
		final whole: Bool = directives.exists(d -> !regions.exists(r -> within(d.span, r)));
		final out: ConditionalText = { directives: [for (d in directives) d.span], regions: regions, whole: whole };
		_conditional[file] = out;
		return out;
	}

	/**
	 * The view of `table` for `scope`, the table holding every build when `truth`; null when there is none, or a
	 * configuration left no facts: the table then holds less.
	 */
	public static function of(table: Null<CompilerFacts>, scope: ReachProject, truth: Bool): Null<FactsView> {
		if (table == null || table.dropped.length > 0 || table.configurations.length == 0) return null;
		return new FactsView(table, scope, truth);
	}

	/**
	 * A facts type string spelled as source declares it: every path by its simple name, an implementation class by its
	 * abstract. Null for a type carrying an unknown or a type parameter, which names no declaration.
	 */
	public static function simpleSource(type: String): Null<String> {
		if (type.indexOf('?') >= 0 || type.indexOf('$') >= 0) return null;
		return IMPL_NAME.replace(PACKAGE_PREFIX.replace(type, ''), '$1');
	}

	/** Whether `inner` lies within `outer`. */
	private static inline function within(inner: Span, outer: Span): Bool {
		return outer.from <= inner.from && inner.to <= outer.to;
	}

	/** Whether `a` is wider than `b`. */
	private static inline function wider(a: Span, b: Span): Bool {
		return a.to - a.from > b.to - b.from;
	}

	/** Whether `a` and `b` are one range. */
	private static inline function sameRange(a: Span, b: Span): Bool {
		return a.from == b.from && a.to == b.to;
	}

	/** Whether `a` and `b` share a position. */
	private static inline function meets(a: Span, b: Span): Bool {
		return a.from < b.to && b.from < a.to;
	}

	/**
	 * The id the compiler gives the type `t` the indexed file `fi` declares (`TypedFactsMacro.typeId`): its package, then its
	 * name — a private type's package ends in its module's name, prefixed `_`.
	 */
	private static function declaredId(fi: FileInfo, t: TypeDeclInfo): String {
		final path: Array<String> = fi.pkg == '' ? [] : fi.pkg.split('.');
		if (t.isPrivate) path.push('_' + fi.module.substr(fi.module.lastIndexOf('.') + 1));
		path.push(t.name);
		return path.join('.');
	}

	/**
	 * The abstract the implementation class `impl` (`pack._Module.Name_Impl_`) implements: `pack.Name`, or `impl` itself
	 * when the id is not spelled so.
	 */
	private static function implemented(impl: String): String {
		final dot: Int = impl.lastIndexOf('.');
		final name: String = impl.substr(dot + 1);
		final pack: String = dot < 0 ? '' : impl.substr(0, dot);
		final module: Int = pack.lastIndexOf('.');
		if (!name.endsWith(IMPL_SUFFIX) || !pack.substr(module + 1).startsWith('_')) return impl;
		final abstractName: String = name.substr(0, name.length - IMPL_SUFFIX.length);
		return module < 0 ? abstractName : '${pack.substr(0, module)}.$abstractName';
	}

	/**
	 * The typed class or interface whose instances — its own, or a subtype's — a value of the facts type string `type` is,
	 * seen through a wrapper that keeps its members (`Null<T>`): its id, whatever type arguments it is written with, since
	 * they change no member an instance has. Null for every other type — `Dynamic`, a structure, a function type, a type
	 * parameter, an unknown, an abstract (a value of which is its underlying one), an enum — and for an extern class, whose
	 * instances target code makes and may make of anything, or one the builds declare unalike.
	 */
	public function objectClass(type: String): Null<String> {
		final id: String = CompilerFacts.baseId(unwrapped(type));
		final declared: Null<TypeFact> = table.type(id);
		return declared != null && declared.alike && !declared.isExtern && OBJECT_KINDS.contains(declared.kind) ? id : null;
	}

	/**
	 * Whether a value of the facts type string `type` is an object of no class unless it is an instance that left the type
	 * system (`ValueEscapes`): a structure, the catch-all, or a typedef every build declares alike whose every target is one,
	 * seen through `Null<T>`. A class instance reaches a place of such a type only by escaping, so what a name computed at
	 * run time reaches on it is a structure's own field — no class member — or a member of an escaped class. A positive
	 * whitelist: an unknown, a type parameter, an abstract, a function type, an enum and every other type are not.
	 */
	public function classless(type: String): Bool {
		final read: Null<FactsType> = FactsTypeTree.read(StringTools.trim(type));
		return read != null && classlessType(read, 0);
	}

	private function classlessType(t: FactsType, depth: Int): Bool {
		return switch t {
			case Structure(_): true;
			case Named(CATCH_ALL, []): true;
			case Named(NULLABLE, [inner]): classlessType(inner, depth);
			case Named(id, _) if (depth < MAX_TYPEDEF_DEPTH):
				final declared: Null<TypeFact> = table.type(id);
				declared != null && declared.alike && declared.kind == TYPEDEF_KIND && declared.targets.length > 0
					&& declared.targets.foreach(target -> {
						final read: Null<FactsType> = FactsTypeTree.read(target);
						read != null && classlessType(read, depth + 1);
					});
			case _: false;
		};
	}

	/** The facts type string `type` seen through every wrapper that keeps its members (`Null<T>`). */
	private function unwrapped(type: String): String {
		final wrappers: Array<String> = _scope.shape.memberTransparentWrapperTypeNames ?? [];
		var t: String = StringTools.trim(type);
		while (t.endsWith('>') && wrappers.contains(CompilerFacts.baseId(t))) t = t.substring(t.indexOf('<') + 1, t.length - 1);
		return t;
	}

	/** The graph's names (`graphMember`) of every method the typed type `id` declares, an accessor among them. */
	public function methodsOf(id: String): Array<String> {
		return [
			for (f in table.type(id)?.fields ?? []) if (f.kinds.exists(k -> METHOD_KINDS.contains(k))) graphMember(id, f.name)
		];
	}

}

/** The sites the syntax cannot be trusted to see in code whose facts are the truth (`FactsView.truthSites`). */
typedef TruthSites = {
	final natives: Array<NativeFact>;
	final reflection: Array<ReflectionFact>;
}

/**
 * What code hands the target code of extern members (`FactsView.externCalls`): the type of each value an argument hands
 * it, each call's receiver (null for none), and how many calls and constructions of them there are.
 */
typedef ExternCalls = {
	final handed: Array<String>;
	final receivers: Array<Null<String>>;
	final count: Int;
}

/** The conditional compilation of a text: its directives, its top-level regions, and whether a region never closes. */
private typedef ConditionalText = {
	final directives: Array<Span>;
	final regions: Array<Span>;
	final whole: Bool;
}

/** A typed type's declaration as the compile read it: its file (a table key), the text, its range, the index's reading. */
private typedef TypeText = {
	final file: String;
	final source: String;
	final span: Span;
	final info: Null<TypeDeclInfo>;
}
