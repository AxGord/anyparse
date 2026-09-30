package anyparse.query;

import anyparse.query.CallGraph.FnNode;
import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.TypeFact;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Whether what the compiler built is what the index and the text say: that every subtype a build typed is a declaration
 * the index holds (`subtypesIndexed`), that a function's compiled body is its own text (`bodyIsSource`), and that what
 * the builds compiled of a whole type, after every build macro ran over it, is its text (`typeIsItsText`). Each answer
 * lets a question the syntax reads stand although a build may compile more — a type a macro defined, a body a build
 * macro may rewrite — and each is read off the compiler's facts (`FactsView`), so without them there is none.
 */
@:nullSafety(Strict)
final class FactsProvenance {

	/** The fact kinds of a type's own function body, as opposed to a function nested in one. */
	private static final OWN_BODY_KINDS: Array<String> = ['method', 'ctor'];

	/** The markers of a node some code of which a macro expanded into it or no text holds any more: its facts are no text's. */
	private static final UNTEXTUAL_MARKERS: Array<String> = ['macro-expansion', 'stale-foreign'];

	/**
	 * The metadata of an abstract's field the compiler calls where the text writes an operator, a conversion, an index
	 * access or a field no declaration names, and never the field's name.
	 */
	private static final IMPLICITLY_CALLED_META: Array<String> = [':op', ':from', ':to', ':arrayAccess', ':resolve'];

	/** The kind of an abstract's implementation class (`TypeFact.kind`). */
	private static inline final IMPL_KIND: String = 'impl';

	/** The access of a call of a method the compiler spliced in (`CompilerFacts.CallFact`). */
	private static inline final INLINED: String = 'inlined';

	/** The access of a call of a super constructor (`CompilerFacts.CallFact`). */
	private static inline final SUPER: String = 'super';

	private final _view: FactsView;
	private final _scope: ReachProject;

	public function new(view: FactsView, scope: ReachProject) {
		_view = view;
		_scope = scope;
	}

	/**
	 * Whether every typed subtype of every typed type the graph calls `type` is declared in the index, in the file the
	 * compiler read it from. A subtype a macro defined, or one in a file the index does not hold, may override what the
	 * index cannot see; a type no build typed has no typed subtype.
	 */
	public function subtypesIndexed(type: String): Bool {
		final table: CompilerFacts = _view.table;
		for (id in _view.bySimpleName()[type] ?? []) for (sub in table.subtypesOf(CompilerFacts.baseId(id))) {
			final at: Null<FactPos> = table.typePosition(sub);
			final declaring: Null<FileInfo> = at == null ? null : _view.indexedFile(at.file);
			final simple: String = _view.graphType(sub);
			if (declaring == null || !declaring.types.exists(d -> d.name == simple)) return false;
		}
		return true;
	}

	/**
	 * Whether the compiled body of the graph node `node` is its source text, so a question answered by reading that text
	 * holds although a build macro may rewrite its type. Every function the compiler typed inside the node's span must be
	 * placed, whole and not generated — the function's own body among them — and every fact of it must sit in that span
	 * of the node's own file on text that names what the fact names: a call's or a field's member, a `new`'s class, a
	 * local's name, a read's identifier. The one text allowed to carry a fact it does not spell is a loop's own: the
	 * compiler lowers a loop into reads, locals and iteration calls positioned at the whole loop. Code a macro put in —
	 * positioned elsewhere, or on text that does not spell it — fails the test; a native site or a reflective value read
	 * fails it outright.
	 */
	public function bodyIsSource(g: CallGraph, node: FnNode): Bool {
		final span: Null<Span> = node.span;
		final source: Null<String> = g.sourceOf(node.file);
		final tree: Null<QueryNode> = g.treeOf(node.file);
		final name: Null<String> = node.name;
		if (span == null || source == null || tree == null || name == null) return false;
		final body: BodyText = BodyText.of(_view.table.keyOf(node.file), span, source, tree, _scope.shape);
		final bodies: Array<FactNode> = [
			for (n in _view.table.nodesIn(node.file)) if (FactsView.FUNCTION_KINDS.contains(n.kind) && body.holds(n.at)) n
		];
		// the function's own body must be among them: a body a macro replaced is typed elsewhere, and only what it kept is here
		final own: Bool = bodies.exists(n -> OWN_BODY_KINDS.contains(n.kind) && simpleName(n.id) == name);
		return own && bodies.foreach(n -> factsMatch(n, body));
	}

	/**
	 * Whether what the builds compiled of the graph type `type` is its text, whatever build macro ran over it
	 * (`ReachGraph.rewrittenBy`): the one declaration of it the index holds is in the file each typed type standing for it
	 * (`FactsView.bySimpleName`) was read from, every field those declare is one the text declares alike
	 * (`declaredAlike`), and every body and initializer the compiler typed for them lies in its field's declaration with
	 * every fact on text that spells it (`factsOnText`) — save the constructor the compiler made for a class the text
	 * gives none, which only calls its super's. A body a macro placed elsewhere, expanded code into or put where no
	 * declaration of its field is fails the test, and so does a type no build typed.
	 */
	public function typeIsItsText(g: CallGraph, type: String): Bool {
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(type);
		final ids: Array<String> = _view.bySimpleName()[type] ?? [];
		if (site == null || ids.length == 0 || g.types.declarationCount(type) != 1) return false;
		final file: String = site.file;
		final decl: Null<TypeDeclInfo> = _scope.index.fileInfo(file)?.types.find(d -> d.name == type);
		final source: Null<String> = g.sourceOf(file);
		final tree: Null<QueryNode> = g.treeOf(file);
		if (decl == null || source == null || tree == null) return false;
		final table: CompilerFacts = _view.table;
		final key: String = table.keyOf(file);
		for (id in ids) {
			final typed: Null<TypeFact> = table.type(id);
			if (typed == null || table.typePosition(id)?.file != key) return false;
			final declared: TypeFact = typed;
			if (!declared.fields.foreach(f -> declaredAlike(declared, f, decl))) return false;
			for (nodeId in table.nodeIdsOf(id)) {
				final n: Null<FactNode> = table.node(nodeId);
				if (n == null || !nodeOnText(n, declared, decl, key, source, tree)) return false;
			}
		}
		return true;
	}

	/**
	 * Whether the field `f` of the typed type `typed` is one `decl` declares alike: a member of its name — an abstract's
	 * constructor is `_new` in its implementation class — that is a variable where `f` is one, with a getter and a setter
	 * exactly where `f` reads and writes through a call, or a function where `f` is one; or the constructor the compiler
	 * made for a class `decl` gives none.
	 */
	private function declaredAlike(typed: TypeFact, f: FieldDeclFact, decl: TypeDeclInfo): Bool {
		final name: String = _view.graphMember(typed.id, f.name);
		final found: Array<MemberInfo> = [for (m in decl.members) if (m.name == name) m];
		if (found.length == 0) return name == constructorName();
		final variable: Bool = f.kind.startsWith('var(');
		final variables: Array<String> = _scope.shape.fieldDeclKinds ?? [];
		return found.exists(
			m ->
				variables.contains(m.kind) == variable
				&& (!variable || (throughCall(f.kind, 0) == m.hasGetter && throughCall(f.kind, 1) == m.hasSetter))
		);
	}

	/**
	 * Whether the typed node `n` of a field of `typed` is text of `decl`, the declaration read from `source` (parsed as
	 * `tree`) whose file the facts key as `key`: it starts in a declaration of its field and every fact of it sits on that
	 * declaration's text, spelling it (`factsOnText`) — or it is the constructor the compiler made for a class the text
	 * gives none (`madeConstructor`). A body a macro placed elsewhere (`FactNode.generated`) is text of no declaration
	 * here: every fact of it lies in another file, which no text of `key` holds.
	 */
	private function nodeOnText(n: FactNode, typed: TypeFact, decl: TypeDeclInfo, key: String, source: String, tree: QueryNode): Bool {
		final name: String = _view.graphMember(typed.id, fieldOf(n.id));
		final declared: Array<MemberInfo> = [for (m in decl.members) if (m.name == name) m];
		if (declared.length == 0) return name == constructorName() && madeConstructor(n);
		for (m in declared) {
			final at: Null<Span> = RefactorSupport.nodeAtFrom(tree, m.declFrom)?.span;
			if (at != null && at.from <= n.at.span.from && n.at.span.from < at.to)
				return factsOnText(n, BodyText.of(key, at, source, tree, _scope.shape));
		}
		return false;
	}

	/**
	 * Whether the typed constructor `n` is one the compiler made for a class the text gives none: it calls its super's and
	 * does nothing else — no construction, field access, flow, conversion, iteration, reflection, native code or function.
	 */
	private static function madeConstructor(n: FactNode): Bool {
		return n.kind == 'ctor' && n.calls.foreach(c -> c.access == SUPER) && n.news.length == 0 && n.fields.length == 0
			&& n.elementWrites.length == 0 && n.flows.length == 0 && n.strings.length == 0 && n.iterations.length == 0
			&& n.reflection.length == 0 && n.natives.length == 0 && n.fns.length == 0;
	}

	/**
	 * Whether every fact of the typed body `n` sits on `body`'s text as its own — as `factsMatch` asks, save that what an
	 * inlined method spliced in, positioned in that method's declared range (`CompilerFacts.spliceOf`), and the `inlined`
	 * call itself are that method's text; that a native site and a reflective read count where `body` holds them; that a
	 * call the compiler makes of an abstract's operator, conversion or index access (`implicitlyCalled`) or of a super
	 * constructor sits on text spelling the construct; and that each function nested in `n` passes the same test or was
	 * spliced in with an inlined body (`FactNode.inlinedFrom`).
	 */
	private function factsOnText(n: FactNode, body: BodyText): Bool {
		// noqa: complexity
		// a marker says code of `n` came from a macro's expansion or was lost with its file: no position shows it
		if (n.incomplete.exists(m -> UNTEXTUAL_MARKERS.contains(m))) return false;
		function own(p: FactPos, onText: Bool): Bool {
			return onText || CompilerFacts.spliceOf(n, p) != null;
		}
		final iterationCalls: Array<String> = _scope.shape.execution?.implicitCallNames ?? [];
		for (c in n.calls) if (c.access != INLINED && !own(c.at, callOnText(c, body, iterationCalls))) return false;
		for (x in n.news) if (!own(x.at, body.spells(x.at, simpleName(CompilerFacts.baseId(x.type))))) return false;
		for (f in n.fields) if (!own(f.at, body.holds(f.at) && (body.mentions(f.at, f.field) || (!f.write && body.lowered(f.at)))))
			return false;
		for (v in n.vars) if (!own(v.at, body.spells(v.at, v.name))) return false;
		for (r in n.reads) if (!own(r.at, body.holds(r.at) && (body.bare(r.at) || body.lowered(r.at)))) return false;
		final placed: Array<FactPos> = [for (f in n.flows) f.at].concat([for (s in n.strings) s.at])
			.concat([for (i in n.iterations) i.at])
			.concat([for (x in n.natives) x.at])
			.concat([for (r in n.reflection) r.at])
			.concat([for (e in n.elementWrites) e.at]);
		if (!placed.foreach(p -> own(p, body.holds(p)))) return false;
		for (child in n.fns) {
			final nested: Null<FactNode> = _view.table.node(child);
			if (nested == null || (nested.inlinedFrom == null && !factsOnText(nested, body))) return false;
		}
		return true;
	}

	/**
	 * Whether the call `c` sits on `body`'s text as its own: a call of a value or of a local or native function where the
	 * text holds it, a super constructor's where it spells `super`, and a field's where it spells the field — the property,
	 * for an accessor — or is a lowered loop running an iteration call (`iterationCalls`), or the construct the compiler
	 * calls an abstract's field for (`implicitlyCalled`).
	 */
	private function callOnText(c: CallFact, body: BodyText, iterationCalls: Array<String>): Bool {
		final target: Null<String> = c.target;
		if (!body.holds(c.at)) return false;
		if (c.access == SUPER) return body.mentions(c.at, SUPER);
		if (target == null || c.access == 'value' || c.access == 'local' || c.access == 'ident') return true;
		final member: String = simpleName(target);
		final spelled: String = _view.accessorProperty(member) ?? member;
		return body.mentions(c.at, spelled) || (body.lowered(c.at) && iterationCalls.contains(member)) || implicitlyCalled(target);
	}

	/**
	 * Whether the field `target` (`pack.Type_Impl_.field`) is an abstract's operator, conversion, index access or
	 * field-name fallback (`IMPLICITLY_CALLED_META`), which the compiler calls where the text writes the construct.
	 */
	private function implicitlyCalled(target: String): Bool {
		final dot: Int = target.lastIndexOf('.');
		final owner: Null<TypeFact> = dot <= 0 ? null : _view.table.type(target.substr(0, dot));
		final field: Null<FieldDeclFact> = owner == null || owner.kind != IMPL_KIND
			? null
			: owner.fields.find(f -> f.name == target.substr(dot + 1));
		return field != null && field.meta.exists(m -> IMPLICITLY_CALLED_META.contains(m));
	}


	/** The name of a constructor (`RefShape.constructorName`). */
	private inline function constructorName(): String {
		return _scope.shape.constructorName ?? 'new';
	}

	/** Whether every fact of the typed body `n` sits on `body`'s text as its own (see `bodyIsSource`). */
	private function factsMatch(n: FactNode, body: BodyText): Bool {
		return !n.generated && n.incomplete.length <= 0 && n.natives.length <= 0 && !n.reflection.exists(r -> r.isValue)
			&& callsMatch(n, body) && n.news.foreach(x -> body.spells(x.at, simpleName(CompilerFacts.baseId(x.type))))
			&& n.fields.foreach(f -> body.holds(f.at) && (body.mentions(f.at, f.field) || (!f.write && body.lowered(f.at))))
			&& n.vars.foreach(v -> body.spells(v.at, v.name))
			&& n.reads.foreach(r -> body.holds(r.at) && (body.bare(r.at) || body.lowered(r.at))) && n.flows.foreach(f -> body.holds(f.at))
			&& n.strings.foreach(x -> body.holds(x.at)) && n.iterations.foreach(i -> body.holds(i.at));
	}

	/**
	 * Whether every call of the typed body `n` sits on text spelling its member — the property, for an accessor it runs —
	 * or is an iteration call of a lowered loop. A local function's id names no text; its body is typed on its own.
	 */
	private function callsMatch(n: FactNode, body: BodyText): Bool {
		final iterationCalls: Array<String> = _scope.shape.execution?.implicitCallNames ?? [];
		for (c in n.calls) {
			final target: Null<String> = c.target;
			if (!body.holds(c.at)) return false;
			if (target == null || target.indexOf(FactsView.NESTED_MARK) >= 0) continue;
			final member: String = simpleName(target);
			// a property read or write runs its accessor: the text spells the property
			final spelled: String = _view.accessorProperty(member) ?? member;
			if (!body.mentions(c.at, spelled) && !(body.lowered(c.at) && iterationCalls.contains(member))) return false;
		}
		return true;
	}

	/** The last dot-separated segment of `path`. */
	private static inline function simpleName(path: String): String {
		return path.substr(path.lastIndexOf('.') + 1);
	}

	/** The field a node id names (`pack.Type.field`, `pack.Type.field~n` for a further overload). */
	private static function fieldOf(id: String): String {
		final field: String = simpleName(id);
		final mark: Int = field.indexOf('~');
		return mark < 0 ? field : field.substr(0, mark);
	}

	/**
	 * Whether the variable kind `kind` (`var(<read>,<write>)`) reads (`slot` 0) or writes (`slot` 1) through an accessor
	 * call.
	 */
	private static function throughCall(kind: String, slot: Int): Bool {
		final accessors: Array<String> = kind.substring(kind.indexOf('(') + 1, kind.length - 1).split(',');
		return accessors[slot] == 'call';
	}

}

/** The text of one function a fact is checked against: its file's table key, its span, and the loops inside it. */
@:nullSafety(Strict)
private final class BodyText {

	private final _key: String;
	private final _span: Span;
	private final _text: String;
	private final _loops: Array<Span>;

	private function new(key: String, span: Span, text: String, loops: Array<Span>) {
		_key = key;
		_span = span;
		_text = text;
		_loops = loops;
	}

	/** Whether `p` lies in this function, in its own file. */
	public inline function holds(p: FactPos): Bool {
		return p.file == _key && _span.from <= p.span.from && p.span.to <= _span.to;
	}

	/** Whether the text at `p` holds `name` as a whole word. */
	public function mentions(p: FactPos, name: String): Bool {
		return FactText.mentions(textAt(p), name);
	}

	/** Whether the text at `p` is a bare identifier. */
	public function bare(p: FactPos): Bool {
		return FactText.bare(textAt(p).trim());
	}

	/** Whether `p`, in this function, spells `name` or is a lowered loop's own. */
	public function spells(p: FactPos, name: String): Bool {
		return holds(p) && (mentions(p, name) || lowered(p));
	}

	/** Whether `p` is where the compiler put a lowered loop's own code: from a loop's start, without its terminator. */
	public function lowered(p: FactPos): Bool {
		return _loops.exists(l -> l.from == p.span.from && p.span.to <= l.to);
	}

	private inline function textAt(p: FactPos): String {
		return _text.substring(p.span.from, p.span.to);
	}

	/** The text at `span` of `source` (parsed as `tree`), whose file the facts key as `key`. */
	public static function of(key: String, span: Span, source: String, tree: QueryNode, shape: GrammarPlugin.RefShape): BodyText {
		final loopKinds: Array<String> = (shape.loopStatementKinds ?? []).concat(shape.iterationBindingKinds ?? []);
		final loops: Array<Span> = [];
		final body: Span = span;
		function collect(n: QueryNode): Void {
			final at: Null<Span> = n.span;
			if (at != null && (at.to <= body.from || at.from >= body.to)) return;
			if (at != null && loopKinds.contains(n.kind)) loops.push(at);
			for (c in n.children) collect(c);
		}
		collect(tree);
		return new BodyText(key, span, source, loops);
	}

}
