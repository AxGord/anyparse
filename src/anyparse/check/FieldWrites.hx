package anyparse.check;

import anyparse.query.BoolExprShape;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphNames;
import anyparse.query.CallGraphTypes;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/** One write of a field-shaped target in a file of the run. */
typedef FieldWriteSite = {
	/** The write itself: an assignment, a compound assignment, an increment or a decrement. */
	final write: QueryNode;

	/** The file the write sits in. */
	final file: String;

	/** Whether the target is the running object's own: a bare name, or one read off `this`. */
	final own: Bool;

	/** The function the write runs in (a lambda's or a local function's own id); null outside every function. */
	final fn: Null<String>;

	/**
	 * For an `own` target, the type declaring the field the name binds in the type of `fn` (`declaringTypeOf`); null when
	 * that type declares none by the name, or no function is around the write.
	 */
	final declaring: Null<String>;

	/** Whether a function is around the write and the graph knows its type. */
	final typed: Bool;

	/**
	 * Whether the write names its field at run time (`recordReflective`, an index write into a dynamic value): a `final`
	 * field is no bar to it.
	 */
	final reflective: Bool;

	/**
	 * For a `reflective` write, the types whose fields it may reach (`reachOf`); null when that is any type's, and for
	 * every other write.
	 */
	final reaches: Null<Array<String>>;
}

/**
 * Every write of a field-shaped target the run's files hold, by the name written, walked ONCE per run (`ObjectPaths`
 * asks which fields stay put, `AllocationSets` which classes a field may hold, `ExhaustiveSwitches` what a member is
 * assigned), and whether the run sees every write of the project at all (`complete`).
 *
 * A reflective write — `Reflect.setField` / `setProperty` / `deleteField`, called off `Reflect` or as a `using` extension
 * or handed on as a function value, `DynamicAccess.set` / `remove`, or an index write into a value not proven an array, a
 * map or a buffer (`ELEMENT_INDEXED_TYPES`) — names its field at run time and is not stopped by a `final`: a literal name
 * files it under that name, a computed one under every name (`of`), each bounded by the types its target may be a value of
 * (`reachOf`; any type for a target of a type the run cannot place on a class: `Dynamic`, `Any`, a type parameter, a structure).
 * There is no narrower sound bound for those: a value of such a type may be an instance of any class, and nothing here tracks which
 * reach it — the cost is paid only by the fields a consumer asks about (fields read through a lock path, a dispatched receiver, a
 * switch subject). A write is positive evidence only in one direction: a write the index holds may change the field, and a field the
 * index holds no write of is unwritten only when `complete` — the run covers the whole project a `closedWorld`
 * declaration closes (`ThreadSafety.listsByFile`). Anything else, a consumer reads as unknown.
 *
 * Why not `FieldWriteIndex`: it re-parses every file it is handed, records a write's span but neither the function it
 * runs in nor its value, and attributes a write by the receiver's DECLARED type, which for this question needs the
 * subtype closure on top to stay sound. The graph already holds every tree; a write of the name through any receiver
 * but the running object is taken to write every field of that name, which over-counts only toward unstable.
 */
@:nullSafety(Strict)
final class FieldWrites {

	/**
	 * The reflective calls writing a field by name, off `Reflect` (`recordReflective`) -> how many arguments a direct
	 * call takes: the object, the name, and but for `deleteField` the value.
	 */
	private static final REFLECT_WRITES: Map<String, Int> = ['setField' => 3, 'setProperty' => 3, 'deleteField' => 2];

	private static inline final REFLECT: String = 'Reflect';

	/**
	 * The `DynamicAccess` methods writing the field their key names (`recordReflective`) -> how many arguments a call takes with
	 * its receiver: the object, the name, and but for `remove` the value.
	 */
	private static final DYNAMIC_ACCESS_WRITES: Map<String, Int> = ['set' => 3, 'remove' => 2];

	private static inline final DYNAMIC_ACCESS: String = 'DynamicAccess';

	/**
	 * The types, by simple name, whose index write `o[k] = v` stores an element and writes no field (`record`): the array, the
	 * maps, the vectors, the byte buffers and the typed arrays. An index write into a value of any other type — `Dynamic`,
	 * `DynamicAccess`, an abstract's own `@:arrayAccess`, an `untyped` or unknown one — is a reflective write.
	 */
	private static final ELEMENT_INDEXED_TYPES: Array<String> = [
		'Array',
		'Map',
		'IntMap',
		'StringMap',
		'ObjectMap',
		'EnumValueMap',
		'WeakMap',
		'BalancedTree',
		'Vector',
		'Bytes',
		'BytesData',
		'ByteArray',
		'Int8Array',
		'Int16Array',
		'Int32Array',
		'UInt8Array',
		'UInt8ClampedArray',
		'UInt16Array',
		'UInt32Array',
		'Float32Array',
		'Float64Array'
	];

	/** How many functions making an `unplaced` write the notice names (`notices`). */
	private static inline final NOTICE_NAMES: Int = 3;

	/** Whether the run sees every write of the project: every file's chain declares `closedWorld` and the run covers the project. */
	public final complete: Bool;

	/** The name written -> every write of it. */
	private final _byName: Map<String, Array<FieldWriteSite>> = [];

	/** The reflective writes whose name is computed: each may write a field of any name (`of`). */
	private final _computed: Array<FieldWriteSite> = [];

	/** Each class or interface -> the types whose fields a write on a value of it may reach (`reachOf`). */
	private final _reach: Map<String, Array<String>> = [];

	/** Each file -> what types an expression of it, as far as the declarations say (`typeOf`); null when nothing can. */
	private final _typers: Map<String, Null<(QueryNode) -> Null<String>>> = [];

	/** The index `typeOf` resolves through (`heldIndex`); null until first demanded. */
	private var _index: Null<SymbolIndex> = null;

	private final _plugin: GrammarPlugin;

	private final _graph: CallGraph;
	private final _shape: RefShape;

	/** What reads a plain string literal's content (`Reflect.setField(o, "name", v)`); null for a grammar with none. */
	private final _fold: Null<StringFoldSupport>;

	public function new(graph: CallGraph, plugin: GrammarPlugin, complete: Bool) {
		_graph = graph;
		_plugin = plugin;
		_shape = plugin.refShape();
		_fold = plugin.stringFoldSupport();
		this.complete = complete;
		for (held in graph.heldFiles()) collect(held.file, held.source, held.tree, false);
	}

	/**
	 * Every write that may write a target named `name`: those naming it, in the order the files were walked, then every
	 * reflective write of a computed name.
	 */
	public function of(name: String): Array<FieldWriteSite> {
		final named: Array<FieldWriteSite> = _byName[name] ?? [];
		return _computed.length == 0 ? named : named.concat(_computed);
	}

	/**
	 * Records every write in `node`'s subtree, in `file` of `source`: an assignment or an increment, a reflective write — a
	 * reflective function handed on as a value (`recordHanded`) included, `callee` saying `node` is a call's callee.
	 */
	private function collect(file: String, source: String, node: QueryNode, callee: Bool): Void {
		if (_shape.writeParentKinds.contains(node.kind) && node.children.length > 0) record(file, source, node, node.children[0]);
		if (node.kind == _shape.callKind)
			recordReflective(file, source, node);
		else if (!callee)
			recordHanded(file, source, node);
		for (i => c in node.children) collect(file, source, c, i == 0 && node.kind == _shape.callKind);
	}

	/**
	 * Records the call `call` of `file` (of `source`) when it writes a field by name: `Reflect.setField(o, name, v)`,
	 * `setProperty` or `deleteField`, called off `Reflect` or as a `using` extension (`o.setField(name, v)` — any call of
	 * that shape and arity, the run cannot tell a `using Reflect` from a method so named, and over-counting only makes a
	 * field unstable) — or `set` / `remove` on a value declared `DynamicAccess`.
	 */
	private function recordReflective(file: String, source: String, call: QueryNode): Void {
		final callee: Null<QueryNode> = call.children[0];
		if (callee == null || !accessKind(callee.kind, _shape) || callee.children.length == 0) return;
		final name: String = callee.name ?? '';
		final arity: Null<Int> = REFLECT_WRITES[name] ?? DYNAMIC_ACCESS_WRITES[name];
		final receiver: QueryNode = callee.children[0];
		final direct: Bool = receiver.kind == _shape.identKind && receiver.name == REFLECT;
		final args: Array<QueryNode> = direct ? call.children.slice(1) : [receiver].concat(call.children.slice(1));
		if (arity == null || args.length != arity) return;
		if (REFLECT_WRITES.exists(name) || declaredAs(file, source, receiver, [DYNAMIC_ACCESS]))
			reflectiveWrite(file, source, call, args[0], args[1]);
	}

	/**
	 * Records `value`, in `file` of `source`, when it hands a reflective write on as a function value instead of calling it
	 * — `final set = Reflect.setField;`, `o.setField` under a `using`: wherever the value is called, it may write a field of
	 * any name, on any object off `Reflect`, on the receiver as an extension.
	 */
	private function recordHanded(file: String, source: String, value: QueryNode): Void {
		if (!accessKind(value.kind, _shape) || !REFLECT_WRITES.exists(value.name ?? '') || value.children.length == 0) return;
		final receiver: QueryNode = value.children[0];
		reflectiveWrite(file, source, value, receiver.kind == _shape.identKind && receiver.name == REFLECT ? null : receiver, null);
	}

	/**
	 * Records the write `write` of `target`, in `file` of `source`, when the target names a field: a bare name, or a field
	 * read off any value; an index into a value not declared of an `ELEMENT_INDEXED_TYPES` type writes the field its key names.
	 */
	private function record(file: String, source: String, write: QueryNode, target: QueryNode): Void {
		if (target.kind == _shape.indexAccessKind && target.children.length == 2) {
			if (!declaredAs(file, source, target.children[0], ELEMENT_INDEXED_TYPES))
				reflectiveWrite(file, source, write, target.children[0], target.children[1]);
			return;
		}
		final name: Null<String> = target.name;
		final at: Null<Span> = target.span;
		final own: Bool = target.kind == _shape.identKind || ownMemberRead(target, _shape);
		if (name == null || at == null || !(own || accessKind(target.kind, _shape))) return;
		final fn: Null<String> = _graph.functionAt(file, at.from);
		final type: Null<String> = fn == null ? null : _graph.node(fn)?.typeName;
		push(name, {
			write: write,
			file: file,
			own: own,
			fn: fn,
			declaring: type == null ? null : _graph.types.declaringTypeOf(type, name),
			typed: type != null,
			reflective: false,
			reaches: null
		});
	}

	/** Files `site` under the name `name` it writes. */
	private function push(name: String, site: FieldWriteSite): Void {
		final list: Array<FieldWriteSite> = _byName[name] ?? [];
		list.push(site);
		_byName[name] = list;
	}

	/**
	 * Records `write`, in `file` of `source`, of the field the key `key` names on the object `target` holds: a plain literal
	 * names one field, anything else — no key at all included — any field (`_computed`). Either reaches only fields of the
	 * types `target` may be a value of (`reachOf`), any type's for no target.
	 */
	private function reflectiveWrite(file: String, source: String, write: QueryNode, target: Null<QueryNode>, key: Null<QueryNode>): Void {
		final at: Null<Span> = write.span;
		if (at == null) return;
		final fn: Null<String> = _graph.functionAt(file, at.from);
		final literal: Null<StringLiteral> = key == null ? null : _fold?.literalOf(key, source);
		final site: FieldWriteSite = {
			write: write,
			file: file,
			own: false,
			fn: fn,
			declaring: null,
			typed: fn != null && _graph.node(fn)?.typeName != null,
			reflective: true,
			reaches: target == null ? null : reachOf(typeOf(file, source, fn, target), fn)
		};
		if (literal == null)
			_computed.push(site);
		else
			push(literal.content, site);
	}

	/** Whether `value`, in `file` of `source`, is declared of a type one of `types` names by its simple name. */
	private function declaredAs(file: String, source: String, value: QueryNode, types: Array<String>): Bool {
		final type: Null<String> = typeOf(file, source, null, value);
		return type != null && types.contains(CallGraphNames.lastSegments(type, 1));
	}

	/**
	 * The type the value `node`, in `file` of `source` and the function `fn`, is declared of, as far as the declarations
	 * say (`CheckScan.typeNominalResolver`): the running type for the self reference; null when unknown.
	 */
	private function typeOf(file: String, source: String, fn: Null<String>, node: QueryNode): Null<String> {
		final value: QueryNode = BoolExprShape.unwrapParens(node, _shape.parenKind);
		if (value.kind == _shape.identKind && value.name == _shape.selfReferenceText) return fn == null ? null : _graph.node(fn)?.typeName;
		if (!_typers.exists(file)) {
			final tree: Null<QueryNode> = _graph.treeOf(file);
			_typers[file] = tree == null ? null : CheckScan.typeNominalResolver(source, _plugin, tree, file, heldIndex(), true, false);
		}
		final typer: Null<(QueryNode) -> Null<String>> = _typers[file];
		return typer == null ? null : typer(value);
	}

	/**
	 * The index of the files the graph holds, built on the first demand: what `typeOf` resolves a member type through. Not
	 * the resolution index (std + libraries): building that one took 5 of TM's 10 s. A member chain
	 * through a library type stays unknown, which costs precision only: `reachOf` places only a project
	 * class, and an index write into a container of an unknown type is a reflective one (`record`).
	 */
	private function heldIndex(): SymbolIndex {
		final built: Null<SymbolIndex> = _index;
		if (built != null) return built;
		final index: SymbolIndex = SymbolIndex.build([for (held in _graph.heldFiles()) { file: held.file, source: held.source }], _plugin);
		_index = index;
		return index;
	}

	/**
	 * The types whose fields a write on a value declared `type` may reach: for a class or an interface the run declares
	 * once (through a typedef alias), every subtype of it and every type on the chain of each — the object is one of them,
	 * its fields declared along its chain. Null, any type's, for any other type: `Dynamic`, `Any`, a type parameter, a
	 * structure or an abstract (which a value of any class may be), a library type, an unknown one — and a name a type
	 * parameter of the function `fn` the write runs in, or of its type, takes over.
	 */
	private function reachOf(type: Null<String>, fn: Null<String>): Null<Array<String>> {
		final types: CallGraphTypes = _graph.types;
		final named: Null<String> = type == null ? null : types.resolveAlias(CallGraphNames.lastSegments(type, 1));
		if (named == null || types.declarationCount(named) != 1 || !(types.meta.isClass(named) || types.isInterface(named))) return null;
		if (fn != null && _graph.typeParamBoundsOf(fn, named) != null) return null;
		final known: Null<Array<String>> = _reach[named];
		if (known != null) return known;
		final out: Array<String> = closure([named], types.subtypesOf);
		final reach: Array<String> = closure(out, types.supertypesOf);
		_reach[named] = reach;
		return reach;
	}

	/** `from` and every type `next` reaches from it, step by step: the closure of `next` over `from`. */
	private static function closure(from: Array<String>, next: (String) -> Array<String>): Array<String> {
		final out: Array<String> = from.copy();
		var at: Int = 0;
		while (at < out.length) {
			for (t in next(out[at])) if (!out.contains(t)) out.push(t);
			at++;
		}
		return out;
	}

	/**
	 * Whether `site` may write the field of that name `owner` declares: a reflective write when `owner` is among the types
	 * it may reach (`reachOf`; any, when unknown); any other receiver's write always — what it is written on, nothing here
	 * can tell — and the running object's when its type declares the field as `owner`'s, declares none by the name (a local
	 * of that name included), or is unknown. An interface's field is declared again by every implementer, so any own write
	 * of the name may be one of it.
	 */
	public function mayWrite(site: FieldWriteSite, owner: String): Bool {
		final reaches: Null<Array<String>> = site.reaches;
		if (site.reflective) return reaches == null || reaches.contains(owner);
		return !site.own || !site.typed || site.declaring == null || site.declaring == owner || _graph.types.isInterface(owner);
	}

	/**
	 * Whether a reflective write may store a value in a field named `name`: one filed under the name, or a
	 * computed one whose reach holds a type declaring a member so named on its chain. A computed one on a value
	 * of no known class (`unplaced`) is not counted: on TM such writes (a `Node<T>`'s `targetObject:T`, `Dynamic`
	 * locals) would make every lock member hold any lock, which names no lock at all — the run says so instead.
	 */
	public function reflectivelyWritten(name: String): Bool {
		return (_byName[name] ?? []).exists(site -> site.reflective && (site.reaches == null || reachesDeclarer(site, name)))
			|| _computed.exists(site -> reachesDeclarer(site, name));
	}

	/** Whether the reflective write `site` reaches a known type declaring a member named `name` on its chain. */
	private function reachesDeclarer(site: FieldWriteSite, name: String): Bool {
		final reaches: Null<Array<String>> = site.reaches;
		return reaches != null && reaches.exists(t -> _graph.types.declaringTypeOf(t, name) != null);
	}

	/**
	 * The reflective writes of a computed name on a value of no class the run can place (`reachOf` null: `Dynamic`, `Any`, a
	 * type parameter, an unknown container): each may store anything in any field, and `reflectivelyWritten` does not count
	 * them.
	 */
	public function unplaced(): Array<FieldWriteSite> {
		return _computed.filter(site -> site.reaches == null);
	}

	/**
	 * What the lock names assume (`reflectivelyWritten`): that no `unplaced` write stores a lock in a lock member — one line
	 * naming the functions making such writes, the first `NOTICE_NAMES` of them; none when there is no such write.
	 */
	public function notices(): Array<String> {
		final where: Array<String> = [];
		for (w in unplaced()) if (!where.contains(w.fn ?? w.file)) where.push(w.fn ?? w.file);
		if (where.length == 0) return [];
		final more: String = where.length > NOTICE_NAMES ? ' (+${where.length - NOTICE_NAMES} more)' : '';
		return [
			'a reflective write of a computed name on a value of no known class may store any lock in any lock member — the lock'
				+ ' names assume none does: ${where.slice(0, NOTICE_NAMES).join(', ')}$more'
		];
	}

	/** Whether `kind` is a field access of `shape`: plain, null-safe or forced. */
	public static inline function accessKind(kind: String, shape: RefShape): Bool {
		return kind == shape.fieldAccessKind || kind == shape.nullSafeAccessKind || kind == shape.forceFieldAccessKind;
	}

	/** Whether `node` names a member of the running object under `shape`: a bare name, or a member read off `this`. */
	public static function ownMemberRead(node: QueryNode, shape: RefShape): Bool {
		return node.kind == shape.identKind
			? node.name != shape.selfReferenceText
			: accessKind(node.kind, shape) && node.children.length > 0 && node.children[0].kind == shape.identKind
				&& node.children[0].name == shape.selfReferenceText;
	}

}
