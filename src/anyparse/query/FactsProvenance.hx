package anyparse.query;

import anyparse.query.CallGraph.FnNode;
import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.ExpansionFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.SpliceFact;
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

	/** The marker of a node a fact of which lies in a file whose text the table no longer has (`CompilerFacts`). */
	private static inline final STALE_FOREIGN: String = 'stale-foreign';

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

	/** The kind of a typedef (`TypeFact.kind`). */
	private static inline final TYPEDEF_KIND: String = 'typedef';

	/** The kind of a variable's initializer (`FactNode.kind`). */
	private static inline final VAR_KIND: String = 'var';

	/** The flow of a value handed to a call as an argument (`FlowFact.via`). */
	private static inline final ARG_FLOW: String = 'arg';

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
	 * fails it outright. The node must stand for that one declaration (`CallGraph.declarationsOf`): the body of another
	 * the graph folded into it is text the test never read.
	 */
	public function bodyIsSource(g: CallGraph, node: FnNode): Bool {
		final span: Null<Span> = node.span;
		final source: Null<String> = g.sourceOf(node.file);
		final tree: Null<QueryNode> = g.treeOf(node.file);
		final name: Null<String> = node.name;
		if (span == null || source == null || tree == null || name == null || g.declarationsOf(node.id).length != 1) return false;
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
	 * (`ReachGraph.rewrittenBy`): the one declaration of it the index holds is in a file each typed type standing for it
	 * (`FactsView.bySimpleName`) was read from, and every file a build read one from is one the index holds (`textual`) —
	 * a typedef aliasing it declares no code, wherever it is (`aliasOnly`) — every field those declare is one the text
	 * declares alike
	 * (`declaredAlike`), and every body and initializer the compiler typed for them lies in its field's declaration with
	 * every fact on text that writes it (`factsOnText`) — save the constructor the compiler made for a class the text
	 * gives none, which only calls its super's. What the compiler writes for the text in code no text holds counts: the
	 * body of a method an inlined call spliced in, the expansion of an expression macro a call the text writes built,
	 * a range it joined from such code. A body a macro placed elsewhere, rewrote to code its text does not write or put
	 * where no declaration of its field is fails the test, and so does a type no build typed.
	 */
	public function typeIsItsText(g: CallGraph, type: String): Bool {
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(type);
		final ids: Array<String> = _view.bySimpleName()[type] ?? [];
		return site != null && ids.length > 0 && g.types.declarationCount(type) == 1 && textual(g, type, [site.file], ids);
	}

	/**
	 * `typeIsItsText` of the one type, of the several the graph type `type` names, the typed type `owner` is written as
	 * (`FactsView.ownerFiles`): the typed types standing for it alone (`FactsView.standingFor`), against its files of the
	 * index — one, or a copy per build (`textual`) — what a node reading the name as that type's (`CallGraphFacts.qualify`)
	 * runs.
	 */
	public function typeIsItsTextAs(g: CallGraph, type: String, owner: String): Bool {
		final files: Array<String> = _view.ownerFiles(type, owner);
		final ids: Array<String> = _view.standingFor(type, owner);
		return files.length > 0 && ids.length > 0 && textual(g, type, files, ids);
	}

	/**
	 * `typeIsItsText` of the typed types `ids`, which the graph calls `type`, against its declarations of the index in
	 * `files`: one, or one per build where each build reads its own copy (a source it generates into its own directory). The
	 * facts carry, for each typed type, every file a build read it from and which builds read it there
	 * (`CompilerFacts.typeHomes`): each such file must be one of `files`, readable as the compile read it, and what those
	 * builds alone typed of the type must be that copy's text (`builtAsText`) — each build's facts judged against its own
	 * copy, never against another build's, whose text may differ. Every one of `files` must be a copy some build read: a
	 * declaration no build's facts vouch for is text no build compiled, which the graph, folding every declaration of the
	 * name, would read as the type's.
	 */
	private function textual(g: CallGraph, type: String, files: Array<String>, ids: Array<String>): Bool {
		final table: CompilerFacts = _view.table;
		final keys: Array<String> = [for (f in files) table.keyOf(f)];
		final vouched: Array<String> = [];
		var coded: Bool = false;
		for (id in ids) {
			final typed: Null<TypeFact> = table.type(id);
			if (typed != null && aliasOnly(typed)) continue;
			if (typed == null) return false;
			coded = true;
			// every build that typed code of it typed the type too, so its homes hold every build's code
			for (home in table.typeHomes(id)) {
				final at: Int = keys.indexOf(home.file);
				if (at < 0 || home.at == null || !builtAsText(g, type, files[at], typed, home.builds)) return false;
				if (!vouched.contains(home.file)) vouched.push(home.file);
			}
		}
		// aliases alone declare no code: each file need only declare the type
		return coded ? keys.foreach(k -> vouched.contains(k)) : files.foreach(f -> declarationIn(type, f) != null);
	}

	/**
	 * Whether what the builds `builds` typed of the typed type `typed` is the text of its declaration in `file`, which the
	 * graph calls `type` and holds: every field they declare is one that text declares alike (`declaredAlike`) and every
	 * node they typed of it is that text (`nodeOnText`), read as those builds alone typed it (`CompilerFacts.nodeAsBuiltBy`).
	 */
	private function builtAsText(g: CallGraph, type: String, file: String, typed: TypeFact, builds: Array<Int>): Bool {
		final decl: Null<TypeDeclInfo> = declarationIn(type, file);
		final source: Null<String> = g.sourceOf(file);
		final tree: Null<QueryNode> = g.treeOf(file);
		if (decl == null || source == null || tree == null) return false;
		final declared: TypeDeclInfo = decl;
		if (!typed.fields.foreach(f -> declaredAlike(typed, f, declared))) return false;
		final table: CompilerFacts = _view.table;
		final key: String = table.keyOf(file);
		for (nodeId in table.nodeIdsOf(typed.id)) {
			if (!table.buildsTyping(nodeId).exists(b -> builds.contains(b))) continue;
			final n: Null<FactNode> = table.nodeAsBuiltBy(nodeId, builds);
			if (n == null || !nodeOnText(n, typed, declared, key, source, tree, builds)) return false;
		}
		return true;
	}

	/** The index's declaration of the graph type `type` in `file`, or null. */
	private function declarationIn(type: String, file: String): Null<TypeDeclInfo> {
		return _scope.index.fileInfo(file)?.types.find(d -> d.name == type);
	}

	/**
	 * Whether the typed type `typed` is a typedef aliasing the type, declared wherever (tink's `typedef Any = std.Any`): it
	 * declares no field and the builds typed no code of it.
	 */
	private function aliasOnly(typed: TypeFact): Bool {
		return typed.kind == TYPEDEF_KIND && typed.fields.length == 0 && _view.table.nodeIdsOf(typed.id).length == 0;
	}

	/**
	 * Whether the field `f` of the typed type `typed` is one `decl` declares alike: for every kind a build gave it, a
	 * member of its name — an abstract's constructor is `_new` in its implementation class — that is a variable where that
	 * kind is one, with a getter and a setter exactly where it reads and writes through a call, or a function where it is
	 * one; or the constructor the compiler made for a class `decl` gives none.
	 */
	private function declaredAlike(typed: TypeFact, f: FieldDeclFact, decl: TypeDeclInfo): Bool {
		final name: String = _view.graphMember(typed.id, f.name);
		final found: Array<MemberInfo> = [for (m in decl.members) if (m.name == name) m];
		if (found.length == 0) return name == constructorName();
		final variables: Array<String> = _scope.shape.fieldDeclKinds ?? [];
		return f.kinds.foreach(kind -> {
			final variable: Bool = kind.startsWith('var(');
			found.exists(
				m ->
					variables.contains(m.kind) == variable
					&& (!variable || (throughCall(kind, 0) == m.hasGetter && throughCall(kind, 1) == m.hasSetter))
			);
		});
	}

	/**
	 * Whether the typed node `n` of a field of `typed` is text of `decl`, the declaration read from `source` (parsed as
	 * `tree`) whose file the facts key as `key`: it starts in a
	 * declaration of its field — from its first modifier, where the compiler places an abstract's constructor
	 * (`FactsView.declarationRange`) — and every fact of it sits on that declaration's text, spelling it (`factsOnText`);
	 * or it is an initializer that is wholly the inlined call of a method its declaration's text calls (`inlinedWhole`);
	 * or it is the constructor the compiler made for a class the text gives none (`madeConstructor`). A body a macro
	 * placed elsewhere (`FactNode.generated`) is text of no declaration here: every fact of it lies in another file,
	 * which no text of `key` holds.
	 */
	private function nodeOnText(
		n: FactNode, typed: TypeFact, decl: TypeDeclInfo, key: String, source: String, tree: QueryNode, builds: Array<Int>
	): Bool {
		final name: String = _view.graphMember(typed.id, fieldOf(n.id));
		final declared: Array<MemberInfo> = [for (m in decl.members) if (m.name == name) m];
		if (declared.length == 0) return name == constructorName() && madeConstructor(n);
		final bodies: Array<BodyText> = [];
		for (m in declared) {
			final at: Null<Span> = FactsView.declarationRange(tree, m.declFrom);
			if (at == null) continue;
			final body: BodyText = BodyText.of(key, at, source, tree, _scope.shape);
			if (n.at.file == key && at.from <= n.at.span.from && n.at.span.from < at.to) return factsOnText(n, body, null, builds);
			bodies.push(body);
		}
		for (body in bodies) {
			final inlined: Null<(FactPos) -> Bool> = inlinedWhole(n, body);
			if (inlined != null) return factsOnText(n, body, inlined, builds);
		}
		return false;
	}

	/**
	 * Where the initializer `n` is wholly the inlined call of a method the declaration's text `body` calls, the test of a
	 * position being in the body of such a method — called by name, through the property it is an accessor of, by the
	 * construct the compiler calls it for (`implicitlyCalled`), or, an abstract's constructor, by a construction of it: the compiler types such an initializer as the callee's
	 * spliced code, at the callee's positions, and records no call; a build of another initializer — a `#if` operand
	 * more — splices the body of another such method. Null for any other node.
	 */
	private function inlinedWhole(n: FactNode, body: BodyText): Null<(FactPos) -> Bool> {
		if (n.kind != VAR_KIND) return null;
		final verdicts: Map<String, Bool> = [];
		function written(p: FactPos): Bool {
			var callee: Null<FactNode> = null;
			for (m in _view.table.nodesIn(p.file)) if (m != n && FactsView.FUNCTION_KINDS.contains(m.kind) && holds(m.at, p)) {
				final best: Null<FactNode> = callee;
				if (best == null || m.at.span.to - m.at.span.from < best.at.span.to - best.at.span.from) callee = m;
			}
			final method: Null<FactNode> = callee;
			if (method == null) return false;
			final known: Null<Bool> = verdicts[method.id];
			if (known != null) return known;
			final field: String = fieldOf(method.id);
			final owner: String = method.id.substr(0, method.id.lastIndexOf('.'));
			final property: Null<String> = _view.accessorProperty(field);
			// an abstract's constructor, which the text calls by constructing the abstract
			final constructed: Bool = _view.graphMember(owner, field) == constructorName()
				&& body.spellsConstruction(constructorName(), _view.graphType(owner));
			final verdict: Bool = body.spellsCall(field) || (property != null && body.spellsName(property)) || implicitlyCalled(method.id)
				|| constructed;
			verdicts[method.id] = verdict;
			return verdict;
		}
		return written(n.at) ? written : null;
	}

	/**
	 * Whether the typed constructor `n` is one the compiler made for a class the text gives none: it calls its super's —
	 * handing it its own parameters, every such flow at the constructor's own range — and does nothing else: no
	 * construction, field access, other flow, conversion, iteration, reflection, native code or function.
	 */
	private static function madeConstructor(n: FactNode): Bool {
		final own: (FactPos) -> Bool = p -> p.file == n.at.file && p.span.from == n.at.span.from && p.span.to == n.at.span.to;
		return n.kind == 'ctor' && n.calls.foreach(c -> c.access == SUPER) && n.news.length == 0 && n.fields.length == 0
			&& n.elementWrites.length == 0 && n.flows.foreach(f -> f.via == ARG_FLOW && own(f.at)) && n.strings.length == 0
			&& n.iterations.length == 0 && n.reflection.length == 0 && n.natives.length == 0 && n.fns.length == 0;
	}

	/**
	 * Whether every fact of the typed body `n` sits on `body`'s text as its own — as `factsMatch` asks, save that what an
	 * inlined method spliced in, positioned in that method's declared range (`CompilerFacts.spliceOf`), in the body of a
	 * method `n` is wholly the inlined call of (`outer`, `inlinedWhole`)
	 * or on a range the compiler joined from such code (`joined`), and the `inlined` call itself are that method's text;
	 * that the code an expression macro built, positioned in that macro's declared range, is the text of the call of it
	 * the compiler replaced (`expansionWritten`); that a native site and a reflective read count where `body` holds them;
	 * that a call the compiler makes of an abstract's operator, conversion or index access (`implicitlyCalled`), of a
	 * super constructor, of a conversion or a library function that runs no project code (`runsNoCode`), of the string
	 * conversion of a value the text converts (`BodyText.converts`), for an element a comprehension yields
	 * (`BodyText.comprehends`), a construction of a literal (`BodyText.builds`) and one of a type the text names by a
	 * typedef the builds alias it to — an import alias among them, which the compiler types as one
	 * (`FactsView.typedefsOf`) — and one of the class a `@:genericBuild` class the text constructs built there, at the
	 * type arguments the text writes (`NewFact.generic`), sit on text
	 * writing the construct; that a local the compiler binds a value the text writes to — a `??` operand, an inlined
	 * call's argument, a partial application's bound value (`BodyText.binds`) — or one whose range is its declaration's
	 * keyword (`BodyText.declares`) is the text's, and so is a read at an expression the text writes, which the compiler
	 * reads a local it bound there at — a partial application's function reads what it binds, and its parameters, at the
	 * application; and that each function nested in `n` passes the same test or was spliced in with an inlined
	 * body (`FactNode.inlinedFrom`).
	 */
	private function factsOnText(n: FactNode, body: BodyText, outer: Null<(FactPos) -> Bool>, builds: Array<Int>): Bool {
		// noqa: complexity
		// a marker says a fact was lost with its file: no position shows it. Code a macro expanded carries its own
		// (`ExpansionFact`), and is the text's only where a call the text writes built it
		if (n.incomplete.contains(STALE_FOREIGN)) return false;
		final written: Array<ExpansionFact> = [for (x in n.expansions) if (expansionWritten(n, x, body, outer)) x];
		final inlined: (FactPos) -> Bool = outer ?? (_ -> false);
		function own(p: FactPos, onText: Bool, ?name: String): Bool {
			return onText || CompilerFacts.spliceOf(n, p) != null || inlined(p) || joined(n, p, name, body)
				|| written.exists(x -> holds(x.declared, p));
		}
		final iterationCalls: Array<String> = _scope.shape.execution?.implicitCallNames ?? [];
		for (c in n.calls) if (c.access != INLINED) {
			final onText: Bool = callOnText(c, body, iterationCalls) || convertsJoined(n, c, body) || body.comprehends(c)
				|| (convertsToString(c) && body.converts(c.at));
			if (!own(c.at, onText, calledName(c))) return false;
		}
		final constructions: Map<String, String> = _scope.shape.execution?.literalConstructions ?? [];
		for (x in n.news) {
			final built: String = _view.graphType(x.type);
			final generic: Null<String> = x.generic;
			final onText: Bool = body.spells(x.at, built) || body.builds(x.at, built, constructions)
				|| _view.typedefsOf(x.type).exists(name -> body.mentions(x.at, name))
				|| (generic != null && body.spells(x.at, _view.graphType(generic)));
			if (!own(x.at, onText)) return false;
		}
		for (f in n.fields) if (!own(f.at, body.holds(f.at) && (body.mentions(f.at, f.field) || (!f.write && body.lowered(f.at))), f.field))
			return false;
		for (v in n.vars) if (!own(v.at, body.spells(v.at, v.name) || body.binds(v.at) || body.declares(v.at, v.name))) return false;
		for (r in n.reads) if (!own(r.at, body.holds(r.at) && (body.bare(r.at) || body.lowered(r.at) || body.binds(r.at)))) return false;
		final placed: Array<FactPos> = [for (f in n.flows) f.at].concat([for (s in n.strings) s.at])
			.concat([for (i in n.iterations) i.at])
			.concat([for (x in n.natives) x.at])
			.concat([for (r in n.reflection) r.at])
			.concat([for (e in n.elementWrites) e.at]);
		if (!placed.foreach(p -> own(p, body.holds(p) || readJoined(n, p, body)))) return false;
		for (child in n.fns) {
			// as the same builds typed it: another build's copy places its code in its own file
			final nested: Null<FactNode> = _view.table.nodeAsBuiltBy(child, builds);
			if (nested == null || (nested.inlinedFrom == null && !factsOnText(nested, body, outer, builds))) return false;
		}
		return true;
	}

	/**
	 * Whether the call `c` is a string conversion the compiler makes of a value (`ExecutionShape.stringConversionMethodNames`
	 * — an abstract's `toString`, called statically on the value).
	 */
	private function convertsToString(c: CallFact): Bool {
		final target: Null<String> = c.target;
		return target != null && (_scope.shape.execution?.stringConversionMethodNames ?? []).contains(memberOf(target));
	}

	/**
	 * Whether the expansion `x` of `n` is the text's: an expression macro (`ExpansionFact.expander`) whose call its anchor
	 * spells — text of `body`, or of the declared range of a method an inlined call spliced into `n` (of `splices`), where
	 * the compiler replaced that call — or, with the anchor in such a method's code, whose call a site of that inlined
	 * call writes in `body`, or the code of another such method spliced at the same site writes (a setter inlined into
	 * the method that assigns the macro's value): the macro's call is an argument the compiler put into the method's
	 * code in place of a parameter. The anchor in a method the node is wholly the inlined call of (`outer`) is written
	 * by the declaration's text. Code no macro is declared around is no text's.
	 */
	private function expansionWritten(n: FactNode, x: ExpansionFact, body: BodyText, outer: Null<(FactPos) -> Bool>): Bool {
		final expander: Null<String> = x.expander;
		if (expander == null) return false;
		final macroName: String = simpleName(expander);
		if (body.holds(x.anchor)) return FactText.spellsCall(body.textAt(x.anchor), macroName);
		if (outer != null && outer(x.anchor)) return body.spellsCall(macroName);
		final splice: Null<SpliceFact> = CompilerFacts.spliceOf(n, x.anchor);
		if (splice == null) return false;
		function spells(at: FactPos): Bool {
			final text: Null<String> = _view.table.sourceOf(at.file)?.substring(at.span.from, at.span.to);
			return switch text {
				case null: false;
				case written: FactText.spellsCall(written, macroName);
			};
		}
		if (spells(x.anchor)) return true;
		for (site in splice.sites) {
			final at: FactPos = { file: n.at.file, span: site };
			if (body.holds(at) && FactText.spellsCall(body.textAt(at), macroName)) return true;
		}
		return n.splices.exists(
			other ->
				other != splice && other.sites.exists(o -> splice.sites.exists(site -> site.from == o.from && site.to == o.to))
				&& spells(other.body)
		);
	}

	/**
	 * Whether the range of `p` is one the compiler joined from code an inlined call spliced into `n` and a part of other
	 * code — it keeps the file of the first part, the smallest start and the largest end, whatever their files — and the
	 * part it joined is that code again, text of a site of that inlined call in `body` that spells the member `name`
	 * (`siteSpells`) — a field of what an inlined getter or index access returned, or an assignment of one, whose value
	 * the text writes there — or the access of `name` the code of another inlined call writes there, ending at the range's
	 * end or starting at its start (`accessEnds`).
	 */
	private function joined(n: FactNode, p: FactPos, name: Null<String>, body: BodyText): Bool {
		function spliced(offset: Int): Bool {
			return n.splices.exists(s -> s.body.file == p.file && s.body.span.from <= offset && offset <= s.body.span.to);
		}
		if (name == null) return spliced(p.span.from) && spliced(p.span.to);
		final member: String = name;
		if (spliced(p.span.from)) {
			return spliced(p.span.to) || siteSpells(n, p, p.span.from, p.span.to, member, body) || accessEnds(n, p.span.to, member);
		}
		return spliced(p.span.to)
			&& (siteSpells(n, p, p.span.to, p.span.from, member, body) || accessEnds(n, p.span.from + member.length, member));
	}

	/**
	 * Whether the code another inlined call spliced into `n` ends, at the offset `end`, with an access of the member `name`
	 * (`FactText.endsAccess`): the compiler joined a field read from one inlined body to the access another one writes, the
	 * offset of whose file it kept under the first one's (openfl-style `list[i].frame` inside an inline method).
	 */
	private function accessEnds(n: FactNode, end: Int, name: String): Bool {
		return n.splices.exists(s -> {
			final text: Null<String> = s.body.span.from < end && end <= s.body.span.to ? _view.table.sourceOf(s.body.file) : null;
			text != null && FactText.endsAccess(text, end, name);
		});
	}

	/**
	 * Whether the offset `other` of the range `p`, whose offset `spliced` lies in the code an inlined call spliced into `n`,
	 * lies in a site of that call in `body` whose text spells the member `name`.
	 */
	private static function siteSpells(n: FactNode, p: FactPos, spliced: Int, other: Int, name: String, body: BodyText): Bool {
		return n.splices.exists(s ->
			s.body.file == p.file && s.body.span.from <= spliced && spliced <= s.body.span.to && s.sites.exists(site -> {
				final at: FactPos = { file: n.at.file, span: site };
				site.from <= other && other <= site.to && body.holds(at) && body.mentions(at, name);
			})
		);
	}

	/**
	 * Whether the call `c` of `n` is a conversion the compiler writes where the text writes one (`runsNoCode`) of a field read
	 * at the very range it sits at, which the compiler joined from code an inlined call spliced in (`readJoined`): the read
	 * the text writes — `${map[key].field}` — is what it converts.
	 */
	private function convertsJoined(n: FactNode, c: CallFact, body: BodyText): Bool {
		final target: Null<String> = c.target;
		return target != null && runsNoCode(target) && readJoined(n, c.at, body);
	}

	/**
	 * Whether `p` is the range of a field read of `n` the compiler joined from code an inlined call spliced in and the text of
	 * `body` (`joined`): a fact there — the read's conversion, the value it flows as — is that read's.
	 */
	private function readJoined(n: FactNode, p: FactPos, body: BodyText): Bool {
		return n.fields.exists(
			f ->
				!f.write && f.at.file == p.file && f.at.span.from == p.span.from && f.at.span.to == p.span.to
				&& joined(n, f.at, f.field, body)
		);
	}

	/** Whether the range `outer` holds `p`; false for none. */
	private static function holds(outer: Null<FactPos>, p: FactPos): Bool {
		return outer != null && outer.file == p.file && outer.span.from <= p.span.from && p.span.to <= outer.span.to;
	}

	/** The member the text spells for the call `c`: an accessor's property; null for a call of no field. */
	private function calledName(c: CallFact): Null<String> {
		final target: Null<String> = c.target;
		if (target == null || c.access == SUPER || c.access == 'value' || c.access == 'local' || c.access == 'ident') return null;
		final member: String = memberOf(target);
		return _view.accessorProperty(member) ?? member;
	}

	/**
	 * The member the text spells for the function `target` (`pack.Type.field`) — an abstract's constructor, which its
	 * implementation class holds as `_new`, as `new` (`FactsView.graphMember`).
	 */
	private function memberOf(target: String): String {
		final dot: Int = target.lastIndexOf('.');
		return dot <= 0 ? target : _view.graphMember(target.substr(0, dot), target.substr(dot + 1));
	}

	/**
	 * Whether the call `c` sits on `body`'s text as its own: a call of a value or of a local or native function where the
	 * text holds it, a super constructor's where it spells `super`, and a field's where it spells the field — the property,
	 * for an accessor, or the accessor itself, `new` for an abstract's constructor (`memberOf`) — or is a lowered loop running an iteration call (`iterationCalls`), the
	 * construct the compiler calls an abstract's field for (`implicitlyCalled`), or a call of a function that runs no project
	 * code (`runsNoCode`).
	 */
	private function callOnText(c: CallFact, body: BodyText, iterationCalls: Array<String>): Bool {
		final target: Null<String> = c.target;
		if (!body.holds(c.at)) return false;
		if (c.access == SUPER) return body.mentions(c.at, SUPER);
		if (target == null || c.access == 'value' || c.access == 'local' || c.access == 'ident') return true;
		final member: String = memberOf(target);
		final spelled: String = _view.accessorProperty(member) ?? member;
		return body.mentions(c.at, spelled) || body.mentions(c.at, member) || (body.lowered(c.at) && iterationCalls.contains(member))
			|| implicitlyCalled(target) || runsNoCode(target);
	}

	/**
	 * Whether the function `target` (`pack.Type.field`, as the compiler resolved it) converts a value to a string the way
	 * the language does (`stringConversionCalls`), which the truth reads as a conversion site, or is library code that runs
	 * no project code (`pureLibraryCalls`): the compiler calls such a function where the text writes an operator or a
	 * conversion (`is`, a string concatenation or interpolation), and where the text writes nothing, it does nothing the
	 * text does not show. The compiler's id is qualified, so a project's own type of the same simple name is none of them.
	 */
	private function runsNoCode(target: String): Bool {
		final execution: Null<GrammarPlugin.ExecutionShape> = _scope.shape.execution;
		return execution != null
			&& ((execution.stringConversionCalls ?? []).contains(target) || (execution.pureLibraryCalls ?? []).contains(target));
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

/**
 * The text of one function a fact is checked against: its file's table key, its span, the loops inside it, and what the
 * compiler writes there that the text does not spell — the nodes it binds values at, the comprehensions it calls for, the
 * values it converts to strings, and the positions it gives code inside an interpolated string (`Interpolation`).
 */
@:nullSafety(Strict)
private final class BodyText {

	/** What may follow the range the compiler gives a literal's construction, inside the literal: a regular expression's flags. */
	private static final FLAGS: EReg = ~/^[A-Za-z]*$/;

	private final _key: String;
	private final _span: Span;
	private final _text: String;
	private final _loops: Array<Span>;

	/** The literals inside the function whose construction the compiler may write as one (`builds`), with their kinds. */
	private final _literals: Array<{ kind: String, span: Span }>;

	/** Every node's range inside the function, as `from:to` (`binds`). */
	private final _nodes: Array<String>;

	/** The names of the named nodes inside the function, by their start (`declares`). */
	private final _starts: Map<Int, Array<String>>;

	/** The comprehensions inside the function, with the call the compiler makes for each element (`comprehends`). */
	private final _comprehensions: Array<{ span: Span, call: String }>;

	/** The interpolated strings inside the function holding an escape, with where the compiler places their code. */
	private final _interpolations: Array<Interpolation>;

	/** The ranges of the operands of the concatenations inside the function, which the text converts to strings. */
	private final _operands: Array<Span>;

	/** The ranges of the interpolated strings inside the function, quotes included. */
	private final _strings: Array<Span>;

	private function new(
		key: String, span: Span, text: String, loops: Array<Span>, literals: Array<{ kind: String, span: Span }>, nodes: Array<String>,
		starts: Map<Int, Array<String>>, comprehensions: Array<{ span: Span, call: String }>, interpolations: Array<Interpolation>,
		operands: Array<Span>, strings: Array<Span>
	) {
		_key = key;
		_span = span;
		_text = text;
		_loops = loops;
		_literals = literals;
		_nodes = nodes;
		_starts = starts;
		_comprehensions = comprehensions;
		_interpolations = interpolations;
		_operands = operands;
		_strings = strings;
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

	/** Whether the whole text of this function writes a call of `name` (`FactText.spellsCall`). */
	public function spellsCall(name: String): Bool {
		return FactText.spellsCall(_text.substring(_span.from, _span.to), name);
	}

	/** Whether the whole text of this function constructs the type `name` with `keyword` (`FactText.spellsConstruction`). */
	public function spellsConstruction(keyword: String, name: String): Bool {
		return FactText.spellsConstruction(_text.substring(_span.from, _span.to), keyword, name);
	}

	/** Whether the whole text of this function holds `name` as a whole word. */
	public function spellsName(name: String): Bool {
		return FactText.mentions(_text.substring(_span.from, _span.to), name);
	}

	/**
	 * Whether `p`, in this function, is a literal of a kind whose construction the compiler writes as one of the type
	 * `built` (`constructions`: `ExecutionShape.literalConstructions`): exactly its range, or that range followed by
	 * nothing but letters — the flags of a regular expression, which the compiler's position of the construction leaves out.
	 */
	public function builds(p: FactPos, built: String, constructions: Map<String, String>): Bool {
		return holds(p)
			&& _literals.exists(
				l ->
					l.span.from == p.span.from && p.span.to <= l.span.to && FLAGS.match(_text.substring(p.span.to, l.span.to))
					&& constructions[l.kind] == built
			);
	}

	/**
	 * Whether the call `c` is the one the compiler makes for an element a comprehension in this function yields: its
	 * receiver is the comprehension's literal, exactly, and it calls what the literal's kind is lowered to call
	 * (`ExecutionShape.comprehensionCalls`).
	 */
	public function comprehends(c: CallFact): Bool {
		final receiver: Null<FactPos> = c.receiverAt;
		return receiver != null && holds(c.at) && holds(receiver)
			&& _comprehensions.exists(x -> x.span.from == receiver.span.from && x.span.to == receiver.span.to && x.call == c.target);
	}

	/**
	 * Whether `p` is exactly the range of a node of this function — an expression the text writes, whose value a local the
	 * compiler binds there holds (a `??` operand, an inlined call's argument, a partial application's bound value).
	 */
	public function binds(p: FactPos): Bool {
		if (!holds(p)) return false;
		final at: Span = sourceSpan(p);
		return at.to > at.from && _nodes.contains('${at.from}:${at.to}');
	}

	/** Whether a node of this function naming `name` starts where `p` does: a declaration the compiler places at its keyword. */
	public function declares(p: FactPos, name: String): Bool {
		return holds(p) && (_starts[sourceSpan(p).from] ?? []).contains(name);
	}

	/**
	 * Whether the value at `p` is one the text converts to a string: inside an interpolated string, or exactly an operand
	 * of a concatenation (`ExecutionShape.concatenationKinds`).
	 */
	public function converts(p: FactPos): Bool {
		if (!holds(p)) return false;
		final at: Span = sourceSpan(p);
		return _operands.exists(c -> c.from == at.from && c.to == at.to) || _strings.exists(s -> s.from < at.from && at.to < s.to);
	}

	/** Whether `p`, in this function, spells `name` or is a lowered loop's own. */
	public function spells(p: FactPos, name: String): Bool {
		return holds(p) && (mentions(p, name) || lowered(p));
	}

	/** Whether `p` is where the compiler put a lowered loop's own code: from a loop's start, without its terminator. */
	public function lowered(p: FactPos): Bool {
		return _loops.exists(l -> l.from == p.span.from && p.span.to <= l.to);
	}

	/** The text at `p`, which lies in this function's file — inside an interpolated string, where it is in the text. */
	public function textAt(p: FactPos): String {
		final at: Span = sourceSpan(p);
		return _text.substring(at.from, at.to);
	}

	/**
	 * Where the range `p` of this function's file is in its text: as it is, but inside an interpolated string holding an
	 * escape, where the compiler counts what the escapes stand for (`Interpolation.source`).
	 */
	private function sourceSpan(p: FactPos): Span {
		if (p.file != _key) return p.span;
		for (i in _interpolations) if (i.span.from < p.span.from && p.span.from < i.span.to) {
			final from: Null<Int> = i.source(p.span.from);
			final to: Null<Int> = i.source(p.span.to);
			return from == null || to == null ? p.span : new Span(from, to);
		}
		return p.span;
	}

	/** The text at `span` of `source` (parsed as `tree`), whose file the facts key as `key`. */
	public static function of(key: String, span: Span, source: String, tree: QueryNode, shape: GrammarPlugin.RefShape): BodyText {
		// noqa: complexity
		final loopKinds: Array<String> = (shape.loopStatementKinds ?? []).concat(shape.iterationBindingKinds ?? []);
		final constructed: Map<String, String> = shape.execution?.literalConstructions ?? [];
		final comprehended: Map<String, String> = shape.execution?.comprehensionCalls ?? [];
		final comprehensionLoops: Array<String> = (shape.iterationBindingKinds ?? []).concat([for (k in [shape.whileExprKind]) if (
			k != null
		) k]);
		final interpolating: Array<String> = shape.interpolatingStringKinds ?? [];
		final loops: Array<Span> = [];
		final literals: Array<{ kind: String, span: Span }> = [];
		final nodes: Array<String> = [];
		final starts: Map<Int, Array<String>> = [];
		final comprehensions: Array<{ span: Span, call: String }> = [];
		final interpolations: Array<Interpolation> = [];
		final concatenations: Array<String> = shape.execution?.concatenationKinds ?? [];
		final operands: Array<Span> = [];
		final strings: Array<Span> = [];
		final body: Span = span;
		function collect(n: QueryNode): Void {
			final at: Null<Span> = n.span;
			if (at != null && (at.to <= body.from || at.from >= body.to)) return;
			if (at != null) {
				if (loopKinds.contains(n.kind)) loops.push(at);
				if (constructed.exists(n.kind)) literals.push({ kind: n.kind, span: at });
				nodes.push('${at.from}:${trimmedEnd(source, at)}');
				final name: Null<String> = n.name;
				if (name != null) {
					final named: Array<String> = starts[at.from] ?? [];
					named.push(name);
					starts[at.from] = named;
				}
				final call: Null<String> = comprehended[n.kind];
				if (call != null && n.children.length == 1 && comprehensionLoops.contains(n.children[0].kind))
					comprehensions.push({ span: at, call: call });
				if (interpolating.contains(n.kind)) {
					final read: Null<Interpolation> = Interpolation.read(source, at);
					if (read != null) interpolations.push(read);
					strings.push(at);
					// the compiler places the concatenation an interpolated string is from inside its opening quote to the end of
					// its last part: the text before the closing quote, or the code of a `${…}` ending it
					final last: Null<QueryNode> = n.children.length == 0 ? null : n.children[n.children.length - 1];
					final code: Null<QueryNode> = last != null && last.kind == shape.stringInterpBlockKind && last.children.length > 0
						? last.children[0]
						: last;
					final end: Null<Span> = code?.span;
					// a text segment ends where its text does, spaces and all; code, where its last token does
					if (end != null) nodes.push('${at.from + 1}:${code == last ? end.to : trimmedEnd(source, end)}');
				}
				if (concatenations.contains(n.kind)) for (operand in n.children) {
					final o: Null<Span> = operand.span;
					if (o != null) operands.push(new Span(o.from, trimmedEnd(source, o)));
				}
			}
			for (c in n.children) collect(c);
		}
		collect(tree);
		return new BodyText(key, span, source, loops, literals, nodes, starts, comprehensions, interpolations, operands, strings);
	}

	/** The end of `span` of `source` without the whitespace after the node: the compiler's position of an expression has none. */
	private static function trimmedEnd(source: String, span: Span): Int {
		var end: Int = span.to;
		while (end > span.from && StringTools.isSpace(source, end - 1)) end--;
		return end;
	}

}

/**
 * An interpolated string holding an escape or a character past ASCII, and where the compiler places the code inside it
 * (`format_string` in Haxe's `typer.ml`): from one past the opening quote it counts the BYTES of the string's value — its
 * escapes resolved, its characters in UTF-8 — where the text counts characters, adding one for each `'` outside a
 * `${…}`, which an escaped quote `\'` spells with two characters. Past any other escape the compiler's offsets fall
 * short of the text's, and past a character UTF-8 writes in several bytes they run beyond it. Read on a positive
 * whitelist: a string of characters of the basic plane whose escapes are the one-character `\n` `\r` `\t` `\\` `\"`
 * `\'`; any other string is not read, and code inside it stays where the compiler put it.
 */
@:nullSafety(Strict)
private final class Interpolation {

	/** The escapes read, by the character after the backslash. */
	private static final ESCAPES: Array<Int> = ['n'.code, 'r'.code, 't'.code, '\\'.code, '"'.code, '\''.code];

	/** The first code UTF-8 writes in two bytes, the first it writes in three, and the bytes a basic-plane code takes at most. */
	private static inline final TWO_BYTES: Int = 0x80;

	private static inline final THREE_BYTES: Int = 0x800;

	private static inline final MAX_WIDTH: Int = 3;

	/** The first and the last code unit of a surrogate pair: a character past the basic plane. */
	private static inline final SURROGATE_FIRST: Int = 0xd800;

	private static inline final SURROGATE_LAST: Int = 0xdfff;

	/** The string's range, quotes included. */
	public final span: Span;

	/** The compiler's offset -> the text's offset, for each character of the value and its end. */
	private final _source: Map<Int, Int>;

	private function new(span: Span, source: Map<Int, Int>) {
		this.span = span;
		_source = source;
	}

	/** Where in the text the compiler's offset `at` in this string lies; null for an offset it gives no character. */
	public function source(at: Int): Null<Int> {
		return _source[at];
	}

	/** The string at `span` of `text` read so, or null where its offsets are the text's or it is not read. */
	public static function read(text: String, span: Span): Null<Interpolation> {
		// noqa: complexity
		final raw: String = text.substring(span.from, span.to);
		final close: Int = raw.length == 0 ? -1 : raw.lastIndexOf(raw.charAt(0));
		if (close <= 0) return null;
		// the value's characters, where each stands in the text, and the bytes UTF-8 writes it in
		final chars: Array<Int> = [];
		final at: Array<Int> = [];
		final widths: Array<Int> = [];
		var shifted: Bool = false;
		var i: Int = 1;
		while (i < close) {
			final code: Int = raw.fastCodeAt(i);
			if (code >= SURROGATE_FIRST && code <= SURROGATE_LAST) return null;
			if (code != '\\'.code) {
				chars.push(code);
				at.push(span.from + i);
				final width: Int = code < TWO_BYTES ? 1 : code < THREE_BYTES ? 2 : MAX_WIDTH;
				widths.push(width);
				if (width > 1) shifted = true;
				i++;
				continue;
			}
			if (i + 1 >= close) return null;
			final escaped: Int = raw.fastCodeAt(i + 1);
			if (!ESCAPES.contains(escaped)) return null;
			chars.push(escaped == 'n'.code || escaped == 'r'.code || escaped == 't'.code ? ' '.code : escaped);
			at.push(span.from + i);
			widths.push(1);
			shifted = true;
			i += 2;
		}
		if (!shifted) return null;
		final source: Map<Int, Int> = [];
		var quotes: Int = 0;
		var bytes: Int = 0;
		var pos: Int = 0;
		final length: Int = chars.length;
		function place(k: Int): Void {
			source[span.from + 1 + bytes + quotes] = at[k];
			bytes += widths[k];
		}
		while (pos < length) {
			final code: Int = chars[pos];
			place(pos);
			if (code == '\''.code) quotes++;
			pos++;
			if (code != "$".code || pos == length) continue;
			final next: Int = chars[pos];
			if (next == "$".code) {
				place(pos);
				pos++;
			} else if (next == '{'.code) {
				// the group's code is placed as the value's offsets past the quotes counted before it
				var depth: Int = 0;
				var end: Int = pos;
				while (end < length) {
					if (chars[end] == '{'.code) depth++;
					if (chars[end] == '}'.code && --depth == 0) break;
					end++;
				}
				if (end >= length) return null;
				for (k in pos ... end + 1) place(k);
				pos = end + 1;
			}
		}
		source[span.from + 1 + bytes + quotes] = span.from + close;
		return new Interpolation(span, source);
	}

}
