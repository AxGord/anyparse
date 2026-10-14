package anyparse.check;

import anyparse.query.CallGraph;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/** A `final` field a constructor stores a parameter into: the class declaring it, its file, and its name. */
private typedef StoredField = {
	final type: String;
	final file: String;
	final name: String;
}

/** A call of a stored field: the function making it, its file and its span. */
private typedef FieldCall = {
	final from: String;
	final file: String;
	final span: Span;
}

/** A node of a file's tree, the node holding it (null at the root), and the file. */
private typedef Placed = {
	final node: QueryNode;
	final parent: Null<QueryNode>;
	final file: String;
}

/**
 * Function values handed to a constructor that only STORES them. A value passed as an argument to a constructor whose
 * parameter is used in its body only as the right-hand side of assignment statements to `final` fields its own class
 * declares runs nowhere at the `new` — it runs where such a field is called. So the `Ref` the graph records where the
 * value is handed runs nothing (`stored`), and every call of the field gets a derived `Call` edge to the value: the walk
 * under a hold around the `new` reaches the value only through a call of the field the hold itself makes (TM's
 * `FileList.reload` hands `_source.getThumbnail` to `new FileListGrid(...)` under the tree lock; `FileListItemGrid`
 * calls it later, from `requestThumbnail`).
 *
 * A positive whitelist; any other shape keeps the `Ref` running where it is handed, as before:
 * - the target is a project constructor of one declaration, the argument a whole argument of a `new` resolving to it,
 *   the `new` passing exactly as many arguments as the constructor declares parameters and none of them a rest one —
 *   so the argument binds the parameter at its position;
 * - in the constructor body the parameter is read only bare, as the right-hand side of an assignment statement to
 *   `F` or `this.F`, `F` a `final` field the constructor's class declares; any other node of the parameter's name — a
 *   call of it, a read in a nested function, the name declared again — refuses;
 * - every node of the held files carrying the field's name is a declaration of a field of that name, the target of an
 *   assignment, a call of it (`F(...)`, `x.F(...)`) made in a function the graph holds — the value runs there — or a
 *   whole argument of a `new` of another constructor storing it the same way, whose own field is then followed alike;
 *   any other node carrying the name (a local or a parameter of that name too: a local shadowing the field refuses so),
 *   a string literal spelling it, or a class whose members a read of a computed name may obtain
 *   (`reflectiveMethodHolders`, `ReflectiveValues.obtainableMember`) refuses;
 * - the class's file is under `closedWorld`: every read of the field is in the held files.
 */
@:nullSafety(Strict)
final class StoredValues {

	/** The receiver naming the object a member runs on. */
	private static inline final THIS: String = 'this';

	/** The `Ref` edges whose value only a constructor's stores keep, by `keyOf`. */
	private final _stored: Map<String, Bool> = [];

	/** The constructors some stored value is handed to: what `stored` checks before it builds a key. */
	private final _constructors: Map<String, Bool> = [];

	/** By `<constructor>|<position>|<arguments>`, the fields that constructor stores that parameter into; null when it does more. */
	private final _stores: Map<String, Null<Array<StoredField>>> = [];

	/** By field name, every node of the held files carrying it (`index`). */
	private final _occurrences: Map<String, Array<Placed>> = [];

	private final _graph: CallGraph;
	private final _trees: FunctionTrees;
	private final _shape: RefShape;
	private final _plugin: GrammarPlugin;
	private final _holders: Null<Array<String>>;
	private final _closed: (String) -> Bool;

	/** Every string literal of the held files, walked the first time a field is judged (`ReflectiveValues.literalsOf`). */
	private var _literals: Null<Array<String>> = null;

	/**
	 * Derives the calls of every stored value of `graph` (`trees` its functions' trees), with `holders` the declared
	 * `reflectiveMethodHolders` (null when undeclared) and `closed` whether a file is under `closedWorld`.
	 */
	public function new(
		graph: CallGraph, trees: FunctionTrees, plugin: GrammarPlugin, holders: Null<Array<String>>, closed: (String) -> Bool
	) {
		_graph = graph;
		_trees = trees;
		_plugin = plugin;
		_shape = plugin.refShape();

		_holders = holders;
		_closed = closed;
		derive();
	}

	/** Whether the value of the `Ref` edge `edge` only a constructor's stores keep, its runs derived where they call it. */
	public function stored(edge: CallEdge): Bool {
		return _constructors.exists(edge.via ?? '') && _stored.exists(keyOf(edge));
	}

	/** Whether a read of a name may obtain `field` as a value (`ReflectiveValues.obtainableMember`). */
	private inline function obtainable(field: StoredField): Bool {
		return ReflectiveValues.obtainableMember(_graph, _holders, literals, field.type, field.name);
	}

	/** Every handed value a constructor only stores: its `Ref` recorded, a `Call` edge derived from each call of the field. */
	private function derive(): Void {
		final handed: Array<{ edge: CallEdge, fields: Array<StoredField> }> = [];
		for (e in _graph.edges) if (e.kind == Ref && e.storedInto == null && e.spliced == null) {
			final fields: Null<Array<StoredField>> = handedFields(e);
			if (fields != null) handed.push({ edge: e, fields: fields });
		}
		index([for (h in handed) for (f in h.fields) f.name]);
		for (h in handed) {
			final calls: Null<Array<FieldCall>> = callsOf(h.fields, []);
			if (calls == null) continue;
			for (c in calls) _graph.deriveEdge({
				from: c.from,
				to: h.edge.to,
				kind: Call,
				via: null,
				file: c.file,
				span: c.span,
				dispatchType: null,
				receiverField: null
			});
			_stored[keyOf(h.edge)] = true;
			_constructors[h.edge.via ?? ''] = true;
		}
	}

	/**
	 * The fields the constructor `edge` hands its value to stores it into; null when the value is not a whole argument
	 * of a `new` resolving to that constructor, or the constructor does more with it (`storesOf`).
	 */
	private function handedFields(edge: CallEdge): Null<Array<StoredField>> {
		final via: Null<String> = edge.via;
		final span: Null<Span> = edge.span;
		if (via == null || span == null || !isConstructor(via)) return null;
		final placed: Null<Placed> = placedAt(_trees.ofEdge(edge), span, edge.file);
		final made: Null<QueryNode> = placed?.parent;
		if (placed == null || made == null) return null;
		if (made.kind != _shape.newExprKind) return null;
		final args: Array<QueryNode> = argumentsOf(made);
		final at: Int = args.indexOf(placed.node);
		return at < 0 || newTarget(made, edge.file) != via ? null : storesOf(via, at, args.length);
	}

	/**
	 * The `final` fields the constructor `id` stores its parameter `at` into, a `new` passing `count` arguments; null
	 * unless the parameter's every use is such a store (see the class doc).
	 */
	private function storesOf(id: String, at: Int, count: Int): Null<Array<StoredField>> {
		final key: String = '$id|$at|$count';
		if (_stores.exists(key)) return _stores[key];
		_stores[key] = null;
		final fn: Null<QueryNode> = _trees.ofId(id);
		final node: Null<FnNode> = _graph.node(id);
		final type: Null<String> = node?.typeName;
		if (fn == null || node == null || type == null) return null;
		final params: Array<QueryNode> = [for (c in fn.children) if ((_shape.paramKinds ?? []).contains(c.kind)) c];
		if (at < 0 || params.length != count || params.exists(p -> p.kind == _shape.restParamKind)) return null;
		final name: Null<String> = params[at].name;
		if (name == null) return null;
		final into: Null<Array<String>> = parameterStores(fn, params, name, finalFieldsBeside(node.file, fn));
		if (into == null) return null;
		final owner: String = type;
		final out: Array<StoredField> = [for (f in into) { type: owner, file: node.file, name: f }];
		_stores[key] = out;
		return out;
	}

	/**
	 * The fields of `finals` the body of the function `fn` (`params` its parameters) stores its parameter `name` into;
	 * null when it reads the parameter any other way. A name the body declares again, as a local or a nested function's
	 * parameter, is a node of that name too and refuses; one a store targets that a local declares is refused by the
	 * field's own reads (`occurrenceCalls`), the declaration being one.
	 */
	private function parameterStores(fn: QueryNode, params: Array<QueryNode>, name: String, finals: Array<String>): Null<Array<String>> {
		final out: Array<String> = [];
		var refused: Bool = false;
		function walk(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>): Void {
			if (refused) return;
			if (node.name == name) {
				final field: Null<String> = node.kind == _shape.identKind ? storedField(node, parent, grand) : null;
				if (field == null || !finals.contains(field)) {
					refused = true;
					return;
				}
				if (!out.contains(field)) out.push(field);
			}
			for (c in node.children) walk(c, node, parent);
		}
		for (c in fn.children) if (!params.contains(c)) walk(c, fn, null);
		return refused || out.length == 0 ? null : out;
	}

	/**
	 * The field `node`, a bare read of a parameter whose holder is `parent` and its holder `grand`, is stored into: the
	 * `F` of an assignment statement `F = node` or `this.F = node`; null for any other use.
	 */
	private function storedField(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>): Null<String> {
		if (parent == null || grand == null) return null;
		if (parent.kind != _shape.assignKind || grand.kind != _shape.exprStatementKind) return null;
		if (parent.children.length != 2 || parent.children[1] != node) return null;
		final target: QueryNode = parent.children[0];
		final own: Bool = target.kind == _shape.identKind || target.kind == _shape.fieldAccessKind && target.children.length == 1
			&& target.children[0].kind == _shape.identKind && target.children[0].name == THIS;
		return own ? target.name : null;
	}

	/**
	 * The calls of the stored `fields`, every value forwarded to another constructor's store followed; null when a
	 * field is read any other way (see the class doc). `seen` the fields followed so far.
	 */
	private function callsOf(fields: Array<StoredField>, seen: Array<String>): Null<Array<FieldCall>> {
		final out: Array<FieldCall> = [];
		for (field in fields) {
			final id: String = '${field.type}.${field.name}';
			if (seen.contains(id)) continue;
			seen.push(id);
			if (!_closed(field.file) || obtainable(field)) return null;
			index([field.name]);
			for (o in _occurrences[field.name] ?? []) {
				final found: Null<Array<FieldCall>> = occurrenceCalls(o, seen);
				if (found == null) return null;
				for (c in found) out.push(c);
			}
		}
		return out;
	}

	/**
	 * What the node `o` carrying a stored field's name does with the field: nothing (a field declaration, an assignment
	 * target), a call of it, or a forwarding to another constructor's store, whose calls it answers; null for anything else.
	 */
	private function occurrenceCalls(o: Placed, seen: Array<String>): Null<Array<FieldCall>> {
		final parent: Null<QueryNode> = o.parent;
		if ((_shape.fieldDeclKinds ?? []).contains(o.node.kind)) return [];
		if (parent == null) return null;
		final at: Int = parent.children.indexOf(o.node);
		if (parent.kind == _shape.assignKind && at == 0) return [];
		final span: Null<Span> = parent.span;
		final from: Null<String> = span == null ? null : _graph.functionAt(o.file, span.from);
		if (span == null || from == null) return null;
		final site: Span = span;
		final caller: String = from;
		if (parent.kind == _shape.callKind && at == 0) return [{ from: caller, file: o.file, span: site }];
		final target: Null<String> = parent.kind == _shape.newExprKind ? newTarget(parent, o.file) : null;
		final args: Array<QueryNode> = argumentsOf(parent);
		final next: Null<Array<StoredField>> = target == null ? null : storesOf(target, args.indexOf(o.node), args.length);
		return next == null ? null : callsOf(next, seen);
	}

	/** The one project constructor the `new` expression `made` of `file` resolves to; null for none or several. */
	private function newTarget(made: QueryNode, file: String): Null<String> {
		final span: Null<Span> = made.span;
		final from: Null<String> = span == null ? null : _graph.functionAt(file, span.from);
		if (span == null || from == null) return null;
		final targets: Array<String> = [
			for (e in _graph.outEdges(from)) if (e.kind == New && e.span?.from == span.from && e.span?.to == span.to) e.to
		];
		return targets.length == 1 && isConstructor(targets[0]) ? targets[0] : null;
	}

	/** The arguments of the `new` expression `made`: its children but the type it names and that type's parameters. */
	private function argumentsOf(made: QueryNode): Array<QueryNode> {
		final types: Array<String> = _shape.typeAnnotationKinds ?? [];
		return [for (c in made.children) if (!types.contains(c.kind)) c];
	}

	/** Whether `id` is a project constructor of one declaration, its body held. */
	private function isConstructor(id: String): Bool {
		final node: Null<FnNode> = _graph.node(id);
		return node != null && !node.isExternal && !node.isBodyless && node.name == (_shape.constructorName ?? 'new')
			&& _graph.declarationsOf(id).length == 1;
	}

	/** The names of the `final` fields declared beside the member `fn` in its type's body, in the tree of `file`. */
	private function finalFieldsBeside(file: String, fn: QueryNode): Array<String> {
		final body: Null<QueryNode> = holderOf(_trees.ofFile(file), fn);
		final kinds: Array<String> = _shape.fieldDeclKinds ?? [];
		final mutable: Array<String> = _shape.mutableFieldDeclKinds ?? [];
		return body == null ? [] : [
			for (c in body.children) if (kinds.contains(c.kind) && !mutable.contains(c.kind) && c.name != null) c.name
		];
	}

	/** Every node of the held files carrying one of `names` not yet indexed, with its holder, filed by name in `_occurrences`. */
	private function index(names: Array<String>): Void {
		final wanted: Array<String> = [];
		for (n in names) if (!_occurrences.exists(n) && !wanted.contains(n)) {
			wanted.push(n);
			_occurrences[n] = [];
		}
		if (wanted.length == 0) return;
		for (held in _graph.heldFiles()) {
			final file: String = held.file;
			function walk(node: QueryNode, parent: Null<QueryNode>): Void {
				final name: Null<String> = node.name;
				if (name != null && wanted.contains(name)) _occurrences[name]?.push({ node: node, parent: parent, file: file });
				for (c in node.children) walk(c, node);
			}
			final tree: Null<QueryNode> = _trees.ofFile(file);
			if (tree != null) walk(tree, null);
		}
	}

	/** Every string literal of the held files, walked once. */
	private function literals(): Array<String> {
		final known: Null<Array<String>> = _literals;
		if (known != null) return known;
		final out: Array<String> = ReflectiveValues.literalsOf(_graph, _plugin);
		_literals = out;
		return out;
	}

	/** One `Ref` edge as `stored` files it: the function handing the value, the value, the file and the site. */
	private static inline function keyOf(edge: CallEdge): String {
		return '${edge.from}|${edge.to}|${edge.file}|${edge.span?.from}';
	}

	/** The node of the tree under `root` (in `file`) spanning exactly `span`, with its holder; null when there is none. */
	private static function placedAt(root: Null<QueryNode>, span: Span, file: String): Null<Placed> {
		var parent: Null<QueryNode> = null;
		var node: Null<QueryNode> = root;
		while (node != null) {
			final at: Null<Span> = node.span;
			if (at != null && at.from == span.from && at.to == span.to) return { node: node, parent: parent, file: file };
			parent = node;
			node = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
		}
		return null;
	}

	/** The node directly holding `target` under `root`; null when `target` is not under it. */
	private static function holderOf(root: Null<QueryNode>, target: QueryNode): Null<QueryNode> {
		final span: Null<Span> = target.span;
		var node: Null<QueryNode> = root;
		while (node != null && span != null) {
			if (node.children.contains(target)) return node;
			node = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
		}
		return null;
	}

}
