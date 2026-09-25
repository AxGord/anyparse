package anyparse.query;

import anyparse.runtime.Span;
import haxe.Json;

using Lambda;
using StringTools;

/**
 * One compile's facts as `TypedFactsProbe` wrote them: the configuration's `name`, the JSON Lines `text`, and `file`,
 * which maps a path as the compiler spelled it to the key the table files it under.
 */
typedef FactsDump = {
	final name: String;
	final text: String;
	final file: (String) -> String;
}

/** Where a fact sits: the table's key of its file, and its range in anyparse `Span` units. */
typedef FactPos = {
	final file: String;
	final span: Span;
}

/**
 * A call site. `target` is the called field's declaring type and name (`pack.Type.field`), a structure or dynamic
 * field's bare name, a local function's node id, or the identifier of a native call; absent for a call of a value.
 * `access` is `FInstance`, `FStatic`, `FAnon`, `FDynamic`, `FClosure`, `FEnum`, `super`, `local`, `ident` or `value`.
 */
typedef CallFact = {
	final target: Null<String>;
	final access: String;
	final receiver: Null<String>;
	final receiverAt: Null<FactPos>;
	final result: String;
	final at: FactPos;
}

/** A `new`: the class and the instance type it makes. */
typedef NewFact = {
	final type: String;
	final instance: String;
	final at: FactPos;
}

/** A field read or write that is not the callee of a call; a compound assignment is both. */
typedef FieldFact = {
	final owner: Null<String>;
	final field: String;
	final access: String;
	final receiver: String;
	final type: String;
	final write: Bool;
	final at: FactPos;
}

/** A value of type `from` reaching a place of type `to` through `via`: `var`, `assign`, `arg`, `ret`, `arr`, `obj` or `cast`. */
typedef FlowFact = {
	final from: String;
	final to: String;
	final via: String;
	final at: FactPos;
}

/** A non-String operand of a String concatenation: converted by its `toString`. */
typedef StringFact = {
	final operand: String;
	final at: FactPos;
}

/** A `for` loop the compiler kept as one: the binder's type and the iterated value's. */
typedef IterationFact = {
	final binder: String;
	final iterated: String;
	final at: FactPos;
}

/** A `Reflect`/`Type` call, with its first literal string argument and its first type argument. */
typedef ReflectionFact = {
	final target: String;
	final name: Null<String>;
	final typeArgument: Null<String>;
	final at: FactPos;
}

/** A native-code site: `syntax` for a `*.Syntax` call, `ident` for a `__js__`-style identifier. */
typedef NativeFact = {
	final kind: String;
	final name: String;
	final at: FactPos;
}

/** A local, parameter or loop binder, with the type the compiler gave it. */
typedef VarFact = {
	final name: String;
	final type: String;
	final at: FactPos;
}

/** A read of a local, parameter or loop binder, with its type: the identifier's own range. */
typedef LocalReadFact = {
	final type: String;
	final at: FactPos;
}

/**
 * One function or initializer the compiler typed: a type's field (`pack.Type.field`) or a nested function
 * (`<parent id>@<offset>`), with every fact of its body. Nested functions are nodes of their own, listed in `fns`.
 */
typedef FactNode = {
	final id: String;
	final kind: String;
	final owner: String;
	final isStatic: Bool;
	final signature: String;
	final name: Null<String>;
	final at: FactPos;

	/** The parameters, in order: the compiler gives a parameter no position of its own. */
	final params: Array<{ name: String, type: String }>;

	final calls: Array<CallFact>;
	final news: Array<NewFact>;
	final fields: Array<FieldFact>;
	final flows: Array<FlowFact>;
	final strings: Array<StringFact>;
	final iterations: Array<IterationFact>;
	final reflection: Array<ReflectionFact>;
	final natives: Array<NativeFact>;
	final vars: Array<VarFact>;
	final reads: Array<LocalReadFact>;
	final fns: Array<String>;
}

/** A declared field of a typed type. `kind` is `method`, `inline`, `dynamic`, `macro` or `var(<read>,<write>)`. */
typedef FieldDeclFact = {
	final name: String;
	final kind: String;
	final type: String;
	final isStatic: Bool;
	final meta: Array<String>;
}

/**
 * A type the compiler typed: `kind` is `class`, `interface`, `impl` (an abstract's implementation class), `abstract`,
 * `enum` or `typedef`. `superClass` and `interfaces` carry their type arguments as written.
 */
typedef TypeFact = {
	final id: String;
	final kind: String;
	final pack: String;
	final params: Array<String>;
	final meta: Array<String>;
	final isExtern: Bool;
	final superClass: Null<String>;
	final interfaces: Array<String>;
	final fields: Array<FieldDeclFact>;
}

/**
 * The union of the facts every configuration of one run wrote (`TypedFactsProbe`), looked up by node id, by file and
 * anyparse `Span`, or by type. A node, a type or a call site present in ANY configuration is in the table; one present
 * in none — code no configuration compiled, a conditional branch every one of them left out, a file the table could
 * not read — is ABSENT, and every lookup answers null or empty for it. Absence means "no facts", never "no code": the
 * caller falls back to what it knew without the table. Where configurations disagree, every answer is kept.
 *
 * Lines are kept as text and parsed on first demand, and a node line the same in two configurations is kept once, so
 * a run's cost is the lines its questions read.
 */
@:nullSafety(Strict)
final class CompilerFacts {

	/** The `NODE_HEAD` groups of a node's range. */
	private static inline final HEAD_MIN: Int = 3;

	private static inline final HEAD_MAX: Int = 4;

	/** The length of an accessor's `get_`/`set_` prefix. */
	private static inline final ACCESSOR_PREFIX: Int = 4;

	/** The prefix every node line starts with, which the writer guarantees: id, home file, range. */
	private static final NODE_HEAD: EReg = ~/^\{"k":"node","id":("(?:[^"\\]|\\.)*"),"f":("(?:[^"\\]|\\.)*"),"p":\[(\d+),(\d+)\]/;

	/** A bare identifier. */
	private static final IDENTIFIER: EReg = ~/^[A-Za-z_][A-Za-z0-9_]*$/;

	/** A three-number position: one in a file other than its record's. */
	private static final FOREIGN_POSITION: EReg = ~/\[\d+,\d+,\d+\]/;

	/** The configurations whose facts the table holds, by name. */
	public final configurations: Array<String> = [];

	private final _nodeLines: Map<String, Array<NodeLine>> = [];
	private final _nodeFiles: Map<String, Array<NodeRange>> = [];
	private final _nodeCache: Map<String, Null<FactNode>> = [];
	private final _types: Map<String, TypeFact> = [];
	private final _typeHomes: Map<String, { home: String, p: Array<Int> }> = [];
	private final _supers: Map<String, Array<String>> = [];
	private final _subs: Map<String, Array<String>> = [];
	private final _indexes: Map<String, Null<CodepointIndex>> = [];
	private final _sources: Map<String, Null<String>> = [];
	private final _dumps: Array<DumpFiles> = [];
	private final _read: (String) -> Null<String>;
	private final _key: (String) -> String;

	private function new(read: (String) -> Null<String>, key: (String) -> String) {
		this._read = read;
		this._key = key;
	}

	/** Whether any configuration typed code of `file`. */
	public function compiled(file: String): Bool {
		return _nodeFiles.exists(_key(file));
	}

	/** The node `id`, its facts unioned over every configuration that typed it; null when none did. */
	public function node(id: String): Null<FactNode> {
		if (_nodeCache.exists(id)) return _nodeCache[id];
		final lines: Null<Array<NodeLine>> = _nodeLines[id];
		final made: Null<FactNode> = lines == null ? null : materialize(id, lines);
		_nodeCache[id] = made;
		return made;
	}

	/** Every node of `file`, outermost first. */
	public function nodesIn(file: String): Array<FactNode> {
		final ranges: Array<NodeRange> = _nodeFiles[_key(file)] ?? [];
		final out: Array<FactNode> = [];
		for (range in ranges) {
			final made: Null<FactNode> = node(range.id);
			if (made != null) out.push(made);
		}
		return out;
	}

	/** The innermost node of `file` whose range contains `span`; null when no configuration typed code there. */
	public function nodeAt(file: String, span: Span): Null<FactNode> {
		final containing: Array<FactNode> = nodesAround(file, span);
		return containing.length == 0 ? null : containing[containing.length - 1];
	}

	/** Every call site at exactly `span` in `file` — one per distinct answer the configurations gave. */
	public function callsAt(file: String, span: Span): Array<CallFact> {
		return [
			for (n in nodesAround(file, span)) for (c in n.calls) if (same(c.at, file, span)) c
		];
	}

	/** Every call site within `span` in `file`. */
	public function callsIn(file: String, span: Span): Array<CallFact> {
		return [
			for (n in nodesAround(file, span, true)) for (c in n.calls) if (inside(c.at, file, span)) c
		];
	}

	/** Every value flow within `span` in `file`. */
	public function flowsIn(file: String, span: Span): Array<FlowFact> {
		return [
			for (n in nodesAround(file, span, true)) for (f in n.flows) if (inside(f.at, file, span)) f
		];
	}

	/**
	 * The type the compiler gave the expression at exactly `span` in `file` — a call's result, a field access, a receiver,
	 * a local's read or declaration, an argument, a concatenated operand — when the facts record one there and every
	 * configuration agrees; null otherwise. The facts record expressions where they carry a question, not every expression.
	 *
	 * The compiler also puts code of its own at a source range — a lowered loop's `length` read sits at the whole `for` —
	 * so a call or field fact answers only when the text at `span` names its member, and a read only when that text is a
	 * bare identifier.
	 */
	public function typeOfExpressionAt(file: String, span: Span): Null<String> {
		final source: Null<String> = sourceOf(_key(file));
		if (source == null) return null;
		final text: String = StringTools.trim(source.substring(span.from, span.to));
		final seen: Array<String> = [];
		final bare: Bool = IDENTIFIER.match(text);
		for (n in nodesAround(file, span)) for (site in typedSites(n, bare)) {
			final at: Null<FactPos> = site.at;
			final member: Null<String> = site.member;
			if (
				at != null && same(at, file, span) && site.type != '?' && !seen.contains(site.type)
				&& (member == null || mentions(text, member))
			)
				seen.push(site.type);
		}
		return seen.length == 1 ? seen[0] : null;
	}

	/** The type `id` (`pack.Name`); null when no configuration typed it. */
	public function type(id: String): Null<TypeFact> {
		return _types[id];
	}

	/** Where the type `id` is declared; null when no configuration typed it or its file cannot be read. */
	public function typePosition(id: String): Null<FactPos> {
		final declared: Null<{ home: String, p: Array<Int> }> = _typeHomes[id];
		return declared == null ? null : position(declared.home, declared.p, []);
	}

	/** Every type `id` extends or implements, directly or not, over the whole typed set; by id, without type arguments. */
	public function supertypesOf(id: String): Array<String> {
		return closure(_supers, id);
	}

	/** Every typed type that extends or implements `id`, directly or not; by id. */
	public function subtypesOf(id: String): Array<String> {
		return closure(_subs, id);
	}

	/**
	 * Every positioned type `n` records for an expression, with the member name the expression's text must spell for it
	 * to count (null when any text may carry it); a local's reads only when the asked text is a bare identifier (`bare`).
	 */
	private function typedSites(n: FactNode, bare: Bool): Array<{ at: Null<FactPos>, type: String, member: Null<String> }> {
		final out: Array<{ at: Null<FactPos>, type: String, member: Null<String> }> = [];
		for (c in n.calls) {
			out.push({ at: c.at, type: c.result, member: calledMember(c) });
			final receiver: Null<String> = c.receiver;
			if (receiver != null) out.push({ at: c.receiverAt, type: receiver, member: null });
		}
		for (f in n.fields) out.push({ at: f.at, type: f.type, member: f.field });
		for (v in n.vars) out.push({ at: v.at, type: v.type, member: v.name });
		if (bare) for (r in n.reads) out.push({ at: r.at, type: r.type, member: null });
		for (s in n.strings) out.push({ at: s.at, type: s.operand, member: null });
		for (f in n.flows) if (f.via == 'arg' || f.via == 'arr' || f.via == 'obj') out.push({ at: f.at, type: f.from, member: null });
		for (x in n.news) out.push({ at: x.at, type: x.instance, member: baseId(x.type).substr(baseId(x.type).lastIndexOf('.') + 1) });
		return out;
	}

	/** The name a call site's text spells for what it calls — an accessor's property, a local function's binder — or null. */
	private function calledMember(c: CallFact): Null<String> {
		final target: Null<String> = c.target;
		if (target == null || c.access == 'local' || c.access == 'value') return null;
		if (c.access == 'super') return 'super';
		final name: String = target.substr(target.lastIndexOf('.') + 1);
		return StringTools.startsWith(name, 'get_') || StringTools.startsWith(name, 'set_') ? name.substr(ACCESSOR_PREFIX) : name;
	}

	private function add(dump: FactsDump): Void {
		final lines: Array<String> = dump.text.split('\n');
		while (lines.length > 0 && lines[lines.length - 1] == '') lines.pop();
		if (lines.length < 2 || !lines[0].startsWith('{"k":"facts","v":1,') || !lines[lines.length - 1].startsWith('{"k":"end"')) return;
		final index: Int = _dumps.length;
		final files: DumpFiles = { paths: [], file: dump.file };
		_dumps.push(files);
		configurations.push(dump.name);
		for (line in lines) {
			if (line.startsWith('{"k":"node"')) {
				if (!NODE_HEAD.match(line)) continue;
				final id: String = Json.parse(NODE_HEAD.matched(1));
				final home: String = dump.file(Json.parse(NODE_HEAD.matched(2)));
				final variants: Array<NodeLine> = _nodeLines[id] ?? [];
				_nodeLines[id] = variants;
				final foreign: Bool = FOREIGN_POSITION.match(line);
				if (!variants.exists(v -> v.text == line && (!foreign || v.dump == index))) variants.push({ dump: index, text: line });
				final ranges: Array<NodeRange> = _nodeFiles[home] ?? [];
				_nodeFiles[home] = ranges;
				if (!ranges.exists(r -> r.id == id)) ranges.push({
					id: id,
					min: Std.parseInt(NODE_HEAD.matched(HEAD_MIN)) ?? 0,
					max: Std.parseInt(NODE_HEAD.matched(HEAD_MAX)) ?? 0
				});
			} else if (line.startsWith('{"k":"type"'))
				addType(Json.parse(line), dump);
			else if (line.startsWith('{"k":"file"')) {
				final record: FileRecord = Json.parse(line);
				files.paths[record.i] = dump.file(record.path);
			}
		}
	}

	private function addType(record: TypeRecord, dump: FactsDump): Void {
		final home: String = dump.file(record.f);
		final fields: Array<FieldDeclFact> = [
			for (f in record.fields ?? [])
				{
					name: f.n,
					kind: f.k,
					type: f.t,
					isStatic: f.s ?? false,
					meta: f.meta ?? []
				}
		];
		final known: Null<TypeFact> = _types[record.id];
		if (known == null) {
			final made: TypeFact = {
				id: record.id,
				kind: record.kind,
				pack: record.pack,
				params: record.params ?? [],
				meta: record.meta ?? [],
				isExtern: record.ext ?? false,
				superClass: record.sup,
				interfaces: record.ifaces ?? [],
				fields: fields
			};
			_types[record.id] = made;
			_typeHomes[record.id] = { home: home, p: record.p };
		} else {
			// a configuration that typed more of the type (a conditional member) adds what the others lacked
			for (f in fields) if (!known.fields.exists(k -> k.name == f.name && k.isStatic == f.isStatic)) known.fields.push(f);
			for (i in record.ifaces ?? []) if (!known.interfaces.contains(i)) known.interfaces.push(i);
		}
		final parents: Array<String> = (record.ifaces ?? []).copy();
		final sup: Null<String> = record.sup;
		if (sup != null) parents.push(sup);
		for (parent in parents) link(record.id, baseId(parent));
	}

	private function link(child: String, parent: String): Void {
		final up: Array<String> = _supers[child] ?? [];
		_supers[child] = up;
		if (!up.contains(parent)) up.push(parent);
		final down: Array<String> = _subs[parent] ?? [];
		_subs[parent] = down;
		if (!down.contains(child)) down.push(child);
	}

	/**
	 * The nodes of `file` whose range contains `span` — or, when `touching`,
	 * meets it — outermost first; none when the file cannot be read.
	 */
	private function nodesAround(file: String, span: Span, ?touching: Bool): Array<FactNode> {
		final home: String = _key(file);
		final index: Null<CodepointIndex> = indexOf(home);
		if (index == null) return [];
		final from: Int = index.toCodepoint(span.from);
		final to: Int = index.toCodepoint(span.to);
		final meets: (NodeRange) -> Bool = touching == true ? r -> r.min < to && from < r.max : r -> r.min <= from && to <= r.max;
		final ranges: Array<NodeRange> = [for (r in _nodeFiles[home] ?? []) if (meets(r)) r];
		ranges.sort((a, b) -> a.min != b.min ? a.min - b.min : b.max - a.max);
		final out: Array<FactNode> = [];
		for (r in ranges) {
			final made: Null<FactNode> = node(r.id);
			if (made != null) out.push(made);
		}
		return out;
	}

	private function same(at: Null<FactPos>, file: String, span: Span): Bool {
		return at != null && at.file == _key(file) && at.span.from == span.from && at.span.to == span.to;
	}

	private function inside(at: FactPos, file: String, span: Span): Bool {
		return at.file == _key(file) && span.from <= at.span.from && at.span.to <= span.to;
	}

	private function indexOf(file: String): Null<CodepointIndex> {
		if (_indexes.exists(file)) return _indexes[file];
		final source: Null<String> = sourceOf(file);
		final index: Null<CodepointIndex> = source == null ? null : CodepointIndex.of(source);
		_indexes[file] = index;
		return index;
	}

	/** The source of the file keyed `file`, read once. */
	private function sourceOf(file: String): Null<String> {
		if (_sources.exists(file)) return _sources[file];
		final source: Null<String> = _read(file);
		_sources[file] = source;
		return source;
	}

	/** `p` of a record homed in `home`, in `Span` units; null when its file cannot be read or is not announced. */
	private function position(home: String, p: Array<Int>, paths: Array<Null<String>>): Null<FactPos> {
		final file: Null<String> = p.length == 3 ? paths[p[0]] : home;
		if (file == null) return null;
		final index: Null<CodepointIndex> = indexOf(file);
		if (index == null) return null;
		final min: Int = p[p.length - 2];
		final max: Int = p[p.length - 1];
		return { file: file, span: new Span(index.toNative(min), index.toNative(max)) };
	}

	private function materialize(id: String, lines: Array<NodeLine>): Null<FactNode> {
		var made: Null<FactNode> = null;
		final seen: Map<String, Bool> = [];
		for (line in lines) {
			final record: NodeRecord = Json.parse(line.text);
			final files: DumpFiles = _dumps[line.dump];
			final home: String = files.file(record.f);
			final at: Null<FactPos> = position(home, record.p, files.paths);
			if (at == null) continue;
			final node: FactNode = made ?? {
				id: id,
				kind: record.kind,
				owner: record.owner,
				isStatic: record.s ?? false,
				signature: record.t,
				name: record.name,
				at: at,
				params: [for (p in record.params ?? []) { name: p.n, type: p.t }],
				calls: [],
				news: [],
				fields: [],
				flows: [],
				strings: [],
				iterations: [],
				reflection: [],
				natives: [],
				vars: [],
				reads: [],
				fns: []
			};
			made = node;
			function place(p: Array<Int>): Null<FactPos> {
				return position(home, p, files.paths);
			}
			// a fact is identified by its resolved text, so the same site from two configurations is one fact
			function fresh(category: String, fact: Any, where: FactPos): Bool {
				final identity: String = category + ' ' + where.file + ' ' + where.span.from + ' ' + where.span.to + ' '
					+ Json.stringify(fact);
				if (seen.exists(identity)) return false;
				seen[identity] = true;
				return true;
			}
			collect(
				record.calls, c -> place(c.p), fresh.bind('call'), (c, where) -> ({
					target: c.t,
					access: c.a,
					receiver: c.r,
					receiverAt: c.rp == null ? null : place(c.rp),
					result: c.rt,
					at: where
				}: CallFact),
				node.calls
			);
			collect(
				record.news, x -> place(x.p), fresh.bind('new'), (x, where) -> ({type: x.t, instance: x.ty, at: where }: NewFact),
				node.news
			);
			collect(
				record.fields, f -> place(f.p), fresh.bind('field'), (f, where) -> ({
					owner: f.o,
					field: f.f,
					access: f.a,
					receiver: f.r,
					type: f.t,
					write: f.w ?? false,
					at: where
				}: FieldFact),
				node.fields
			);
			collect(
				record.flows, f -> place(f.p), fresh.bind('flow'), (f, where) -> ({
					from: f.s,
					to: f.d,
					via: f.c,
					at: where
				}: FlowFact),
				node.flows
			);
			collect(record.strs, s -> place(s.p), fresh.bind('str'), (s, where) -> ({operand: s.o, at: where }: StringFact), node.strings);
			collect(
				record.iters, i -> place(i.p), fresh.bind('iter'), (i, where) -> ({binder: i.v, iterated: i.i, at: where }: IterationFact),
				node.iterations
			);
			collect(
				record.refl, r -> place(r.p), fresh.bind('refl'), (r, where) -> ({
					target: r.t,
					name: r.n,
					typeArgument: r.c,
					at: where
				}: ReflectionFact),
				node.reflection
			);
			collect(
				record.native, n -> place(n.p), fresh.bind('native'), (n, where) -> ({kind: n.w, name: n.n, at: where }: NativeFact),
				node.natives
			);
			collect(
				record.vars, v -> place(v.p), fresh.bind('var'), (v, where) -> ({name: v.n, type: v.t, at: where }: VarFact), node.vars
			);
			collect(
				record.reads, r -> place([for (i in 0...r.length - 1) (r[i]: Int)]), fresh.bind('read'), (r, where) -> ({
					type: (r[r.length - 1]: String),
					at: where
				}: LocalReadFact),
				node.reads
			);
			for (f in record.fns ?? []) if (!node.fns.contains(f)) node.fns.push(f);
		}
		return made;
	}

	/**
	 * The table over `dumps`. `read` gives the source of a file by its table key (null when it cannot be read: its facts
	 * are then absent), and `key` maps a path a caller asks about to a table key. A dump that is not a complete facts
	 * file of this version — no header, no closing record — contributes nothing.
	 */
	public static function build(dumps: Array<FactsDump>, read: (String) -> Null<String>, key: (String) -> String): CompilerFacts {
		final facts: CompilerFacts = new CompilerFacts(read, key);
		for (dump in dumps) facts.add(dump);
		return facts;
	}

	/** The id of type string `type` without its type arguments. */
	public static function baseId(type: String): String {
		final open: Int = type.indexOf('<');
		return open < 0 ? type : type.substr(0, open);
	}

	/** Whether `text` holds `name` as a whole word. */
	private static function mentions(text: String, name: String): Bool {
		var from: Int = text.indexOf(name);
		while (from >= 0) {
			final before: Int = from == 0 ? ' '.code : StringTools.fastCodeAt(text, from - 1);
			final end: Int = from + name.length;
			final after: Int = end >= text.length ? ' '.code : StringTools.fastCodeAt(text, end);
			if (!isWordChar(before) && !isWordChar(after)) return true;
			from = text.indexOf(name, from + 1);
		}
		return false;
	}

	private static function isWordChar(c: Int): Bool {
		return c == '_'.code || (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code);
	}

	private static function closure(edges: Map<String, Array<String>>, from: String): Array<String> {
		final out: Array<String> = [];
		final work: Array<String> = [from];
		while (work.length > 0) {
			final next: String = work.pop() ?? '';
			for (to in edges[next] ?? []) if (to != from && !out.contains(to)) {
				out.push(to);
				work.push(to);
			}
		}
		return out;
	}

	/** Every record of `records` whose position resolves and is `fresh`, made into a fact and appended to `into`. */
	private static function collect<R, F>(
		records: Null<Array<R>>, position: (R) -> Null<FactPos>, fresh: (Any, FactPos) -> Bool, make: (R, FactPos) -> F, into: Array<F>
	): Void {
		if (records == null) return;
		for (record in records) {
			final where: Null<FactPos> = position(record);
			if (where != null && fresh(record, where)) into.push(make(record, where));
		}
	}

}

/** A node's line in one dump: the text, and the dump whose file table its foreign positions index. */
private typedef NodeLine = {
	final dump: Int;
	final text: String;
}

/** A node's range in its home file, in the compiler's codepoints. */
private typedef NodeRange = {
	final id: String;
	final min: Int;
	final max: Int;
}

/** One dump's file table and path mapping. */
private typedef DumpFiles = {
	final paths: Array<Null<String>>;
	final file: (String) -> String;
}

private typedef FileRecord = {
	final i: Int;
	final path: String;
}

private typedef FieldRecord = {
	final n: String;
	final k: String;
	final t: String;
	final ?s: Bool;
	final ?meta: Array<String>;
}

private typedef TypeRecord = {
	final id: String;
	final f: String;
	final p: Array<Int>;
	final kind: String;
	final pack: String;
	final ?params: Array<String>;
	final ?meta: Array<String>;
	final ?ext: Bool;
	final ?sup: String;
	final ?ifaces: Array<String>;
	final ?fields: Array<FieldRecord>;
}

private typedef CallRecord = {
	final ?t: String;
	final a: String;
	final ?r: String;
	final ?rp: Array<Int>;
	final rt: String;
	final p: Array<Int>;
}

private typedef NodeRecord = {
	final id: String;
	final f: String;
	final p: Array<Int>;
	final kind: String;
	final owner: String;
	final t: String;
	final ?s: Bool;
	final ?name: String;
	final ?params: Array<{ n: String, t: String }>;
	final ?calls: Array<CallRecord>;
	final ?news: Array<{ t: String, ty: String, p: Array<Int> }>;
	final ?fields: Array<{
		?o: String,
		f: String,
		a: String,
		r: String,
		t: String,
		?w: Bool,
		p: Array<Int>
	}>;
	final ?flows: Array<{
		s: String,
		d: String,
		c: String,
		p: Array<Int>
	}>;
	final ?strs: Array<{ o: String, p: Array<Int> }>;
	final ?iters: Array<{ v: String, i: String, p: Array<Int> }>;
	final ?refl: Array<{
		t: String,
		?n: String,
		?c: String,
		p: Array<Int>
	}>;
	final ?native: Array<{ w: String, n: String, p: Array<Int> }>;
	final ?vars: Array<{ n: String, t: String, p: Array<Int> }>;

	/** `[min, max, type]`, or `[file index, min, max, type]` for a foreign position. */
	final ?reads: Array<Array<Any>>;
	final ?fns: Array<String>;
}
