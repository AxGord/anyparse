package anyparse.query;

import anyparse.query.CallGraph.FnNode;
import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FlowFact;
import anyparse.query.CompilerFacts.IterationFact;
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
 * keeps the syntactic reading: absence of facts is never "no code".
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
 * directive or lying in a conditional region is faceted, and nothing it resolved its sites through is examined. What
 * stays is what holds in every build as much as in one: the facts are whole and placed, the graph node stands for one
 * declaration, and a body another graph node starts at is that node's. A faceted body's syntax then records an edge
 * only at a site its facts do not type (`CallGraphFacts.holdsBack`): at one they type, the compiler resolved the site
 * in every build there is. A local `inline function` keeps its edge under it: the compiler splices its body at its
 * declaration and types nothing at the site of its call.
 */
@:nullSafety(Strict)
final class FactsView {

	/** What the graph puts in the id of a function nested in another (`CallGraph`): a local function or a lambda. */
	public static inline final NESTED_MARK: String = '#';

	/** The node kinds that are the body of a function (`TypedFactsProbe`). */
	public static final FUNCTION_KINDS: Array<String> = ['method', 'ctor', 'fn', 'local'];

	/** The marker of a body a macro expanded into: it may run code no fact names. */
	private static inline final MACRO_EXPANSION: String = 'macro-expansion';

	/** The suffix of an abstract's implementation class: its statics are the abstract's members. */
	private static inline final IMPL_SUFFIX: String = '_Impl_';

	/** The markers that leave some fact of a node without a place: its body keeps the syntactic reading. */
	private static final UNPLACED: Array<String> = [MACRO_EXPANSION, 'inline-site-unknown', 'stale-foreign'];

	/** The call accesses whose target is a field a type declares. */
	private static final DECLARED_ACCESSES: Array<String> = ['FInstance', 'FStatic', 'FClosure', 'super', 'inlined', 'fieldValue'];

	/** The field kinds that are methods (`TypedFactsProbe`): a read of one is a function value. */
	private static final METHOD_KINDS: Array<String> = ['method', 'inline', 'dynamic'];

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

	/** File -> its conditional directives and regions, scanned once. */
	private final _conditional: Map<String, ConditionalText> = [];

	/** `Type.member` or `Type` -> whether every build resolves it the same (`resolvedAlike`), settled once. */
	private final _alike: Map<String, Bool> = [];

	private final _scope: ReachProject;

	/** Graph type name -> the typed types standing for it, built on first need. */
	private var _bySimpleName: Null<Map<String, Array<String>>> = null;

	/** The names of the project's members declared in a conditional region (`guardedNames`), read on first need. */
	private var _guarded: Null<Map<String, Bool>> = null;

	/** The table keys of the project's files, built on first need. */
	private var _projectKeys: Null<Map<String, Bool>> = null;

	/** Table key -> the index's file, built on first need. */
	private var _byKey: Null<Map<String, FileInfo>> = null;

	private function new(table: CompilerFacts, scope: ReachProject, truth: Bool) {
		this.table = table;
		_scope = scope;
		this.truth = truth;
	}

	/** Drop what was read off the text of `file`, which changed. */
	public function forget(file: String): Void {
		_conditional.remove(file);
		_alike.clear();
	}

	/**
	 * The facts of the function the graph node `node` declares when they replace its syntax (see the type
	 * doc; under the truth, whatever a build the list does not name might read otherwise): the outermost
	 * typed function bodies inside its span. Null keeps the syntactic reading. `declarations` is how many
	 * declarations the graph folded into the node.
	 */
	public function bodyFacts(g: CallGraph, node: FnNode, declarations: Int): Null<Array<FactNode>> {
		final outer: Null<Array<FactNode>> = declarations == 1 ? typedBodies(g, node) : null;
		if (outer == null) return null;
		for (n in outer) if (n.incomplete.exists(m -> UNPLACED.contains(m))) return null;
		// under the truth no build the list does not name exists, to resolve the sites otherwise
		return truth || contextAlike(g, node, outer) ? outer : null;
	}

	/**
	 * The implicit-call sites the code in `span` of `file` runs, from its facts: a string conversion of each non-String
	 * operand and of each argument a conversion call (`ExecutionShape.stringConversionCalls`) is handed, and the
	 * iteration of each `for` the compiler kept. Every other implicit call — an operator, a conversion, an index, an
	 * accessor, a literal construction — is a call or a construction the facts name, an edge of the graph. Null when
	 * the innermost graph node holding `span` is not faceted: the syntactic sites answer.
	 */
	public function sitesIn(g: CallGraph, file: String, span: Span): Null<Array<ImplicitSite>> {
		if (!faceted(g, file, span)) return null;
		final strings: Null<Array<StringFact>> = table.within(file, span, n -> n.strings, s -> s.at);
		final iterations: Null<Array<IterationFact>> = table.within(file, span, n -> n.iterations, i -> i.at);
		final calls: Null<Array<CallFact>> = table.callsIn(file, span);
		final flows: Null<Array<FlowFact>> = table.flowsIn(file, span);
		if (strings == null || iterations == null || calls == null || flows == null) return null;
		final out: Array<ImplicitSite> = [
			for (s in strings) { family: Text, span: s.at.span, types: [simpleSource(s.operand)] }
		];
		for (c in calls) {
			final target: Null<String> = c.target;
			if (target == null || !convertsToString(target)) continue;
			final argument: Null<FlowFact> = flows.find(f ->
				f.via == 'arg' && c.at.span.from <= f.at.span.from && f.at.span.to <= c.at.span.to
			);
			out.push({ family: Text, span: c.at.span, types: [argument == null ? null : simpleSource(argument.from)] });
		}
		for (i in iterations) out.push({ family: Iteration, span: i.at.span, types: [simpleSource(i.iterated)] });
		return out;
	}

	/** Whether the innermost graph node holding `span` of `file` is faceted: its facts replace its syntax. */
	public function faceted(g: CallGraph, file: String, span: Span): Bool {
		final id: Null<String> = g.functionAt(file, span.from);
		final at: Null<Span> = id == null ? null : g.node(id)?.span;
		return id != null && at != null && span.to <= at.to && g.facts?.faceted.exists(id) == true;
	}

	/**
	 * A mark of code meeting `span` of `file` that makes any question about it Unknown, whether the code is faceted or
	 * not: a macro's expansion, which may run code no fact and no syntax names, and a reflective member or class read as a
	 * value, which whatever later calls it runs by a name nothing here sees. An inlined reflection body
	 * (`reflection-inlined`) is none: it is a splice (`inline-site-unknown`), whose node keeps its syntax, which spells
	 * the reflective call or the call of the function holding it.
	 */
	public function blindIn(file: String, span: Span): Null<ReachUnknown> {
		for (n in table.nodesIn(file)) {
			if (n.generated || !meets(n.at.span, span)) continue;
			if (n.incomplete.contains(MACRO_EXPANSION)) return Reification(file, span);
			for (r in n.reflection) if (r.isValue && meets(r.at.span, span)) return DynamicName(file, r.at.span);
		}
		return null;
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

	/** The typed subtypes of `type` that declare an instance method `name`, by graph id: overrides a dispatch on it reaches. */
	public function overrides(g: CallGraph, type: String, name: String): Array<String> {
		final out: Array<String> = [];
		for (sub in table.subtypesOf(CompilerFacts.baseId(type))) {
			final declared: Null<TypeFact> = table.type(sub);
			if (declared == null || !declared.fields.exists(f -> f.name == name && !f.isStatic && METHOD_KINDS.contains(f.kind))) continue;
			final graphed: String = graphType(sub);
			final id: String = g.ownMember(graphed, name) ?? g.externalNode(graphed, name);
			if (!out.contains(id)) out.push(id);
		}
		return out;
	}

	/** Whether the typed type `owner` declares `name` as a method: a read of it is a function value. */
	public function isMethod(owner: String, name: String): Bool {
		return table.type(CompilerFacts.baseId(owner))?.fields.exists(f -> f.name == name && METHOD_KINDS.contains(f.kind)) ?? false;
	}

	/** Whether a call of `target` converts its argument to a string (`ExecutionShape.stringConversionCalls`). */
	public function convertsToString(target: String): Bool {
		return (_scope.shape.execution?.stringConversionCalls ?? []).contains(target);
	}

	/** Whether a build macro may rewrite a typed type the graph calls `type`: one of them records a `@:build`-family call. */
	public function built(type: String): Bool {
		return (bySimpleName()[type] ?? []).exists(id -> (table.type(id)?.builds.length ?? 0) > 0);
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
	 * The outermost typed function bodies inside the span of `node`, when its text holds no directive and
	 * lies in no conditional region, or the facts are the truth; null otherwise, or when none was typed.
	 */
	private function typedBodies(g: CallGraph, node: FnNode): Null<Array<FactNode>> {
		final span: Null<Span> = node.span;
		final source: Null<String> = g.sourceOf(node.file);
		if (span == null || source == null) return null;
		// every build typed its own branch: under the truth their union is every branch that runs
		if (!truth && conditional(node.file, source, span)) return null;
		final inside: Array<FactNode> = [
			for (n in table.nodesIn(node.file)) if (FUNCTION_KINDS.contains(n.kind) && !n.generated && within(n.at.span, span)) n
		];
		final outer: Array<FactNode> = [
			for (n in inside) if (!inside.exists(o -> within(n.at.span, o.at.span) && wider(o.at.span, n.at.span))) n
		];
		// a body another graph node starts at is that node's: one nested in this one, whose own facts this one has none of
		// (a local `inline function`, which the compiler types into its caller)
		for (n in outer) {
			final owner: Null<String> = g.functionAt(node.file, n.at.span.from);
			if (owner != node.id && g.node(owner ?? '')?.span?.from == n.at.span.from) return null;
		}
		return outer.length == 0 ? null : outer;
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
		final id: Null<String> = span.from > 0 ? g.functionAt(node.file, span.from - 1) : null;
		final found: Null<FnNode> = id == null ? null : g.node(id);
		final at: Null<Span> = found?.span;
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

	/** Whether `a` and `b` share a position. */
	private static inline function meets(a: Span, b: Span): Bool {
		return a.from < b.to && b.from < a.to;
	}

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
