package anyparse.query;

import anyparse.query.CallGraph.FnNode;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Whether what the compiler built is what the index and the text say: that every subtype a build typed is a declaration
 * the index holds (`subtypesIndexed`), and that a function's compiled body is its own text (`bodyIsSource`). Each answer
 * lets a question the syntax reads stand although a build may compile more — a type a macro defined, a body a build
 * macro may rewrite — and each is read off the compiler's facts (`FactsView`), so without them there is none.
 */
@:nullSafety(Strict)
final class FactsProvenance {

	/** The fact kinds of a type's own function body, as opposed to a function nested in one. */
	private static final OWN_BODY_KINDS: Array<String> = ['method', 'ctor'];

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
