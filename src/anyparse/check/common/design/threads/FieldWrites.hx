package anyparse.check.common.design.threads;

import anyparse.check.common.design.threads.ReflectiveReach.Capture;
import anyparse.check.common.design.threads.ReflectiveReach.Placement;
import anyparse.check.common.design.threads.ReflectiveValues.Entries;
import anyparse.check.common.design.threads.ReflectiveValues.StoredValue;
import anyparse.check.scan.CheckScan;
import anyparse.query.BoolExprShape;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphNames;
import anyparse.query.IndexScope;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;

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
	 * For a `reflective` write, the types whose fields it may reach (`ReflectiveReach.placeOf`); null when that is any type's, and for
	 * every other write.
	 */
	final reaches: Null<Array<String>>;

	/**
	 * For a `reflective` write on a value its declared type places on no class, the positive exclusion that bounds
	 * `reaches` all the same (`ReflectiveReach.placeOf`): a fresh structure or object, a type parameter its constraint or its
	 * instantiations bound; null for every other write.
	 */
	final placedBy: Null<String>;

	/** For a reflective write, what it stores in the field (`ReflectiveValues.typesOf`); `Unknown` for every other write. */
	final stored: StoredValue;
}

/**
 * Every write of a field-shaped target the run's files hold, by the name written, walked ONCE per run (`ObjectPaths`
 * asks which fields stay put, `AllocationSets` which classes a field may hold, `ExhaustiveSwitches` what a member is
 * assigned), and whether the run sees every write of the project at all (`complete`).
 *
 * A reflective write — `Reflect.setField` / `setProperty` / `deleteField`, called off `Reflect` or as a `using` extension
 * or handed on as a function value, `DynamicAccess.set` / `remove`, or an index write into a value not proven an array, a
 * map or a buffer (`ELEMENT_INDEXED_TYPES`) — names its field at run time and is not stopped by a `final`: a literal name
 * files it under that name, a computed one under every name (`of`), each bounded by the types its target may be an object of
 * (`ReflectiveReach.placeOf`: its declared class and the chains of its
 * subtypes, else what a positive exclusion proves — a `final` local bound
 * to a fresh structure or object, a type parameter its constraint or every instantiation of its type bounds, a `case` capture
 * typed by its enum constructor; any type for anything else: `Dynamic`, `Any`, an unbounded type parameter, a structure). A
 * value of such a type may be an instance of any class, and nothing here tracks which reach it — the cost is paid only by the
 * fields a consumer asks about (fields read through a lock path, a dispatched receiver, a switch subject, every lock member).
 * A write is positive evidence only in one direction: a write the index holds may change the field, and a field the
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

	private static inline final REFLECT: String = 'Reflect';
	private static inline final DYNAMIC_ACCESS: String = 'DynamicAccess';

	/** How many functions making an `unplaced` write the notice names (`notices`). */
	private static inline final NOTICE_NAMES: Int = 3;

	/**
	 * The reflective calls writing a field by name, off `Reflect` (`recordReflective`) -> how many arguments a direct
	 * call takes: the object, the name, and but for `deleteField` the value.
	 */
	private static final REFLECT_WRITES: Map<String, Int> = ['setField' => 3, 'setProperty' => 3, 'deleteField' => 2];

	/**
	 * The `DynamicAccess` methods writing the field their key names (`recordReflective`) -> how many arguments a call takes with
	 * its receiver: the object, the name, and but for `remove` the value.
	 */
	private static final DYNAMIC_ACCESS_WRITES: Map<String, Int> = ['set' => 3, 'remove' => 2];

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

	/** Whether the run sees every write of the project: every file's chain declares `closedWorld` and the run covers the project. */
	public final complete: Bool;

	/** The name written -> every write of it. */
	private final _byName: Map<String, Array<FieldWriteSite>> = [];

	/** The reflective writes whose name is computed: each may write a field of any name (`of`). */
	private final _computed: Array<FieldWriteSite> = [];

	/** Each file -> what types an expression of it, as far as the declarations say (`typeOf`); null when nothing can. */
	private final _typers: Map<String, Null<(QueryNode) -> Null<String>>> = [];

	/** Each lock member name -> the members of that name a lock call reads (`Owner.member`, `markLockMembers`). */
	private final _lockFields: Map<String, Array<String>> = [];

	private final _plugin: GrammarPlugin;

	/** What the target of a reflective write may be an object of. */
	private final _targets: ReflectiveReach;

	/** What a reflective write on a value the run places on no class stores (`storesLock`). */
	private final _values: ReflectiveValues;

	private final _graph: CallGraph;
	private final _shape: RefShape;

	/** What reads a plain string literal's content (`Reflect.setField(o, "name", v)`); null for a grammar with none. */
	private final _fold: Null<StringFoldSupport>;

	/** The index `typeOf` resolves through (`heldIndex`); null until first demanded. */
	private var _index: Null<SymbolIndex> = null;

	/** Each write `unplaced` holds, a literal name's included, with the types of what it stores (`storedTypes`); null until first asked. */
	private var _stores: Null<Array<{ site: FieldWriteSite, types: Null<Array<String>> }>> = null;

	/**
	 * The writes of the files `graph` holds; `complete` when the run sees every write of the project, `reflectiveClasses`
	 * and `methodHolders` as the project declares them, `entries` what may invoke a function from outside the graph's
	 * calls (`ReflectiveValues`).
	 */
	public function new(
		graph: CallGraph, plugin: GrammarPlugin, complete: Bool, ?reflectiveClasses: Array<String>, ?entries: Entries,
		?methodHolders: Array<String>
	) {
		_graph = graph;
		_plugin = plugin;
		_shape = plugin.refShape();
		_fold = plugin.stringFoldSupport();
		_targets = new ReflectiveReach(graph, plugin, complete, reflectiveClasses);
		_values = new ReflectiveValues(graph, plugin, _targets, complete, entries, methodHolders);
		this.complete = complete;
		for (held in graph.heldFiles()) collect(held.file, held.source, held.tree, false);
	}

	/**
	 * Whether a reflective write may store a value in a field named `name`: one filed under the name, or a computed one
	 * whose reach holds a type declaring a member so named on its chain — or that reaches any type's (`unplaced`), which
	 * may store anything in any field, a lock in any lock member included, unless what it stores holds no lock of the type
	 * of a lock member so named (`storesLock`). That is the sound default; what keeps a write on a value of no declared
	 * class off it is a POSITIVE exclusion (`ReflectiveReach.placeOf`, `ReflectiveValues.typesOf`), never the absence of a
	 * known class.
	 */
	public inline function reflectivelyWritten(name: String): Bool {
		return reflectiveWritersOf(name).length > 0;
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
	 * Whether `site` may write the field of that name `owner` declares: a reflective write when `owner` is among the types
	 * it may reach (`ReflectiveReach.placeOf`; any, when unknown); any other receiver's write always — what it is written on, nothing here
	 * can tell — and the running object's when its type declares the field as `owner`'s, declares none by the name (a local
	 * of that name included), or is unknown. An interface's field is declared again by every implementer, so any own write
	 * of the name may be one of it.
	 */
	public function mayWrite(site: FieldWriteSite, owner: String): Bool {
		final reaches: Null<Array<String>> = site.reaches;
		return site.reflective
			? reaches == null || reaches.contains(owner)
			: !site.own || !site.typed || site.declaring == null || site.declaring == owner || _graph.types.isInterface(owner);
	}

	/**
	 * Records `fields` (`Owner.member`) as the lock members of their names, the members a lock call reads: what an
	 * `unplaced` write stores counts against a name only when it may be a lock of the type one of them is declared of.
	 */
	public function markLockMembers(fields: Array<String>): Void {
		for (f in fields) {
			final name: String = LockSites.memberName(f);
			final known: Array<String> = _lockFields[name] ?? [];
			if (!known.contains(f)) known.push(f);
			_lockFields[name] = known;
		}
	}

	/**
	 * The functions making the reflective writes that may store a value in a field named `name` (`reflectivelyWritten`), each
	 * once — a write outside every function by its file.
	 */
	public function reflectiveWritersOf(name: String): Array<String> {
		final out: Array<String> = [];
		for (site in (_byName[name] ?? []).concat(_computed)) if (
			site.reflective && (site.reaches == null ? storesLock(site, _lockFields[name]) : reachesDeclarer(site, name))
		) {
			final at: String = site.fn ?? site.file;
			if (!out.contains(at)) out.push(at);
		}
		return out;
	}

	/**
	 * Why a lock call made on the member `field` (`CallEdge.receiverField`) names no lock — `lock` null — when reflective
	 * writes may store any lock in that member (`reflectiveWritersOf`): the member and the functions making them, said
	 * after a finding's message; null for a named lock, no member, or a member no reflective write reaches.
	 */
	public function unsealedNote(field: Null<String>, lock: Null<String>): Null<String> {
		final member: Null<String> = field == null || lock != null ? null : LockSites.memberName(field);
		final writers: Array<String> = member == null ? [] : reflectiveWritersOf(member);
		return writers.length == 0
			? null
			: ' — its lock member $member names no lock: a reflective write may store any lock in it (${firstNames(writers)})';
	}

	/**
	 * The reflective writes of a computed name on a value the run places on no class and no exclusion bounds (`ReflectiveReach.placeOf`:
	 * `Dynamic`, `Any`, a type parameter nothing bounds, a value the declarations do not type): each may store anything in
	 * any field, and `reflectivelyWritten` counts each for every name.
	 */
	public function unplaced(): Array<FieldWriteSite> {
		return _computed.filter(site -> site.reaches == null);
	}

	/**
	 * What the reflective writes cost the lock names (`reflectivelyWritten`): one line naming the functions making an
	 * `unplaced` write, which unseals every lock member, one naming each function whose write a positive exclusion bounds,
	 * with the exclusion — the first `NOTICE_NAMES` of each — and, when `unnamed` lock holds lost the name of their member to
	 * such a write, one counting them, with the preconditions of the instantiation bound the run fails
	 * (`ReflectiveReach.lacking`) when a write is unplaced; none when there is no such write.
	 */
	public function notices(unnamed: Int): Array<String> {
		final where: Array<String> = [];
		final typed: Array<String> = [];
		final kept: Array<String> = [];
		sortUnplaced(where, typed, kept);
		final placed: Array<String> = [];
		for (list in [_computed].concat([for (sites in _byName) sites])) for (w in list) {
			final by: Null<String> = w.placedBy;
			final entry: String = '${w.fn ?? w.file} ($by)';
			if (by != null && !placed.contains(entry)) placed.push(entry);
		}
		final out: Array<String> = [];
		if (where.length > 0)
			out.push(
				'a reflective write of a computed name on a value the run places on no class (Dynamic, Any, a type parameter'
				+ ' nothing bounds, or one the declarations do not type) may store any lock in any lock member, so no lock is'
				+ ' named by its member: ${firstNames(where)}'
			);
		if (typed.length > 0)
			out.push(
				'a reflective write of a computed name on a value the run places on no class may store a lock of the type it stores'
				+ ' in any lock member of that type, so no such member names its lock: ${firstNames(typed)}'
			);
		if (kept.length > 0)
			out.push(
				'reflective writes on a value the run places on no class kept off every lock member, since what each stores is no'
				+ ' lock of a lock member\'s type: ${firstNames(kept)}'
			);
		if (placed.length > 0)
			out.push(
				'reflective writes on a value whose declared type places it on no class, each bounded by what the value provably is:'
				+ ' ${firstNames(placed)}'
			);
		// what would have bounded an unplaced write on a type parameter: a run over a whole closed project declaring its reflection
		final missing: Array<String> = _targets.lacking();
		final lacking: String = where.length == 0 && typed.length == 0 || missing.length == 0
			? ''
			: '; a type parameter is bounded by its instantiations only in a run over a whole closedWorld project declaring'
				+ ' reflectiveClasses — here: ${missing.join(', ')}';
		if (unnamed > 0)
			out.push(
				'$unnamed lock hold(s) lost the name of their lock member to a reflective write — each is keyed by its pair\'s take'
				+ ' and its finding names the writers$lacking'
			);
		return out;
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
			reflectiveWrite(file, source, call, args[0], args[1], arity > 2 ? Value(args[2]) : Nothing);
	}

	/**
	 * Records `value`, in `file` of `source`, when it hands a reflective write on as a function value instead of calling it
	 * — `final set = Reflect.setField;`, `o.setField` under a `using`: wherever the value is called, it may write a field of
	 * any name, on any object off `Reflect`, on the receiver as an extension.
	 */
	private function recordHanded(file: String, source: String, value: QueryNode): Void {
		if (!accessKind(value.kind, _shape) || !REFLECT_WRITES.exists(value.name ?? '') || value.children.length == 0) return;
		final receiver: QueryNode = value.children[0];
		reflectiveWrite(
			file, source, value, receiver.kind == _shape.identKind && receiver.name == REFLECT ? null : receiver, null, Unknown
		);
	}

	/**
	 * Records the write `write` of `target`, in `file` of `source`, when the target names a field: a bare name, or a field
	 * read off any value; an index into a value not declared of an `ELEMENT_INDEXED_TYPES` type writes the field its key names.
	 */
	private function record(file: String, source: String, write: QueryNode, target: QueryNode): Void {
		if (target.kind == _shape.indexAccessKind && target.children.length == 2) {
			final plain: Bool = (write.kind == _shape.assignKind || write.kind == _shape.nullCoalAssignKind) && write.children.length > 1;
			if (!declaredAs(file, source, target.children[0], ELEMENT_INDEXED_TYPES))
				reflectiveWrite(file, source, write, target.children[0], target.children[1], plain ? Value(write.children[1]) : Unknown);
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
			reaches: null,
			placedBy: null,
			stored: Unknown
		});
	}

	/** Files `site` under the name `name` it writes. */
	private function push(name: String, site: FieldWriteSite): Void {
		final list: Array<FieldWriteSite> = _byName[name] ?? [];
		list.push(site);
		_byName[name] = list;
	}

	/**
	 * Records `write`, in `file` of `source`, of the field the key `key` names on the object `target` holds, storing
	 * `stored` there: a plain literal names one field, anything else — no key at all included — any field (`_computed`).
	 * Either reaches only fields of the types `target` may be an object of (`ReflectiveReach.placeOf`), any type's for no
	 * target.
	 */
	private function reflectiveWrite(
		file: String, source: String, write: QueryNode, target: Null<QueryNode>, key: Null<QueryNode>, stored: StoredValue
	): Void {
		final at: Null<Span> = write.span;
		if (at == null) return;
		final fn: Null<String> = _graph.functionAt(file, at.from);
		final literal: Null<StringLiteral> = key == null ? null : _fold?.literalOf(key, source);
		final declared: Null<String> = target == null ? null : declaredType(file, source, target);
		final capture: Null<Capture> = target == null || declared != null ? null : captureOf(file, source, fn, target);
		final place: Placement = target == null
			? { reaches: null, by: null }
			: _targets.placeOf(file, fn, target, declared ?? capture?.type, capture?.by);
		final site: FieldWriteSite = {
			write: write,
			file: file,
			own: false,
			fn: fn,
			declaring: null,
			typed: fn != null && _graph.node(fn)?.typeName != null,
			reflective: true,
			reaches: place.reaches,
			placedBy: place.by,
			stored: stored
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
	 * say (`CheckScan.typeNominalResolver`), a `case` capture by the enum constructor it is a parameter of (`ReflectiveReach.binderType`):
	 * the running type for the self reference; null when unknown.
	 */
	private function typeOf(file: String, source: String, fn: Null<String>, node: QueryNode): Null<String> {
		return declaredType(file, source, node) ?? captureOf(file, source, fn, node)?.type;
	}

	/** The type the value `node`, in `file` of `source` and the function `fn`, is declared of (`typeOf`), captures aside. */
	private function declaredType(file: String, source: String, node: QueryNode): Null<String> {
		final value: QueryNode = BoolExprShape.unwrapParens(node, _shape.parenKind);
		if (!_typers.exists(file)) {
			final tree: Null<QueryNode> = _graph.treeOf(file);
			_typers[file] = tree == null ? null : CheckScan.typeNominalResolver(source, _plugin, tree, file, heldIndex(), true, false);
		}
		final typer: Null<(QueryNode) -> Null<String>> = _typers[file];
		return typer == null ? null : typer(value);
	}

	/**
	 * What types the `case` capture `node`, in `file` of `source` and the function `fn`, by the enum constructor it is a
	 * parameter of (`ReflectiveReach.binderType`), its switch subject typed as any value is (`typeOf`); null for any other value.
	 */
	private function captureOf(file: String, source: String, fn: Null<String>, node: QueryNode): Null<Capture> {
		return _targets.binderType(file, BoolExprShape.unwrapParens(node, _shape.parenKind), typeOf.bind(file, source, fn));
	}

	/**
	 * The index of the files the graph holds, built on the first demand: what `typeOf` resolves a member type through. Not
	 * the resolution index (std + libraries): building that one cost more than the rest of the rule (decisions.md, FX3). A member chain
	 * through a library type stays unknown, which costs precision only: `ReflectiveReach` places only a project
	 * class, and an index write into a container of an unknown type is a reflective one (`record`).
	 */
	private function heldIndex(): SymbolIndex {
		final built: Null<SymbolIndex> = _index;
		if (built != null) return built;
		final index: SymbolIndex = IndexScope.over([for (held in _graph.heldFiles()) { file: held.file, source: held.source }], _plugin);
		_index = index;
		return index;
	}

	/**
	 * Whether the `unplaced` write `site` may store a lock in one of the lock members `fields` (any member, when null or
	 * none is known): what it stores may be any object (`storedTypes` null), or of a type that may be a lock of the type
	 * one of them is declared of (`ReflectiveValues.mayHold`).
	 */
	private function storesLock(site: FieldWriteSite, fields: Null<Array<String>>): Bool {
		final types: Null<Array<String>> = storedTypes(site);
		if (types == null) return true;
		final members: Array<Null<String>> = fields == null || fields.length == 0 ? [null] : [for (f in fields) _values.memberTypeOf(f)];
		return types.exists(t -> members.exists(m -> _values.mayHold(t, m)));
	}

	/**
	 * The types of the objects what the `unplaced` write `site` stores may be (`ReflectiveValues.typesOf`); null for any
	 * object. Each such write is typed once, on the first demand.
	 */
	private function storedTypes(site: FieldWriteSite): Null<Array<String>> {
		var stores: Null<Array<{ site: FieldWriteSite, types: Null<Array<String>> }>> = _stores;
		if (stores == null) {
			final typer: (
				String, Null<String>, QueryNode
			) -> Null<String> = (file, fn, node) -> typeOf(file, _graph.sourceOf(file) ?? '', fn, node);
			final all: Array<FieldWriteSite> = [for (sites in _byName) for (s in sites) if (s.reflective && s.reaches == null) s];
			stores = [
				for (s in all.concat(unplaced())) { site: s, types: _values.typesOf(s.file, s.fn, s.stored, typer) }
			];
			_stores = stores;
		}
		return stores.find(s -> s.site == site)?.types;
	}

	/** Whether the reflective write `site` reaches a known type declaring a member named `name` on its chain. */
	private function reachesDeclarer(site: FieldWriteSite, name: String): Bool {
		final reaches: Null<Array<String>> = site.reaches;
		return reaches != null && reaches.exists(t -> _graph.types.declaringTypeOf(t, name) != null);
	}

	/**
	 * Files each function making an `unplaced` write (`notices`) by what it stores: under `where` one that may store any
	 * object, under `typed` one storing a lock of some lock member's type, under `kept` one storing no lock of any — a
	 * write naming its field by a literal only there: it costs one member, and only keeping off it is news.
	 */
	private function sortUnplaced(where: Array<String>, typed: Array<String>, kept: Array<String>): Void {
		final locks: Array<String> = [for (fields in _lockFields) for (f in fields) f];
		final named: Array<FieldWriteSite> = [for (sites in _byName) for (w in sites) if (w.reflective && w.reaches == null) w];
		for (w in unplaced().concat(named)) {
			final types: Null<Array<String>> = storedTypes(w);
			final into: Null<Array<String>> = if (types != null && !storesLock(w, locks))
				kept
			else if (named.contains(w))
				null
			else if (types == null)
				where
			else
				typed;
			final entry: String = types == null ? w.fn ?? w.file : storing(w.fn ?? w.file, types);
			if (into != null && !into.contains(entry)) into.push(entry);
		}
	}

	/** Whether `kind` is a field access of `shape`: plain, null-safe or forced. */
	public static inline function accessKind(kind: String, shape: RefShape): Bool {
		return kind == shape.fieldAccessKind || kind == shape.nullSafeAccessKind || kind == shape.forceFieldAccessKind;
	}

	/** The first `NOTICE_NAMES` of `names`, and how many more there are. */
	public static function firstNames(names: Array<String>): String {
		final more: String = names.length > NOTICE_NAMES ? ' (+${names.length - NOTICE_NAMES} more)' : '';
		return names.slice(0, NOTICE_NAMES).join(', ') + more;
	}

	/** Whether `node` names a member of the running object under `shape`: a bare name, or a member read off `this`. */
	public static function ownMemberRead(node: QueryNode, shape: RefShape): Bool {
		return node.kind == shape.identKind
			? node.name != shape.selfReferenceText
			: accessKind(node.kind, shape) && node.children.length > 0 && node.children[0].kind == shape.identKind
				&& node.children[0].name == shape.selfReferenceText;
	}

	/** `at`, the function making a reflective write, with the types `types` of what it stores. */
	private static function storing(at: String, types: Array<String>): String {
		return '$at (${types.length == 0 ? 'it stores no object' : 'it stores ${types.join(', ')}'})';
	}

}
