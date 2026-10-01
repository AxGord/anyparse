package anyparse.query;

import anyparse.query.FactText.NodeHead;
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
 * `access` is `FInstance`, `FStatic`, `FAnon`, `FDynamic`, `FClosure`, `FEnum`, `fieldValue`, `super`, `local`, `ident`,
 * `value`, or `inlined` — a call of a method the compiler spliced in (an `inline` one, or one its call site inlines),
 * positioned at the callee's body.
 */
typedef CallFact = {
	final target: Null<String>;
	final access: String;
	final receiver: Null<String>;
	final receiverAt: Null<FactPos>;
	final result: String;
	final at: FactPos;

	/** The signature the compiler chose, for a call of an overloaded field; null otherwise. */
	final signature: Null<String>;

	/**
	 * For an `inlined` call, where it ran: the range of the node's own innermost expression around the call site the
	 * compiler replaced (the whole body when none is); null otherwise, and in facts that do not record it.
	 */
	final site: Null<FactPos>;

	/** For an `inlined` call, the called method's declared range, which holds the code it spliced in; null otherwise. */
	final body: Null<FactPos>;

	/**
	 * For a call handing its first argument to a `Dynamic` parameter, the argument's type — `Dynamic` when it has none —
	 * and whether it is an object of exactly the class that type names (`operandExact`); null for any other call.
	 */
	final operand: Null<String>;

	final operandExact: Bool;
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

	/**
	 * How a read's value is used (null for a write): `call` (the receiver of a call of `method`, an inlined one's too:
	 * the local the compiler binds it to is the method's code, not a value handed on), `index`, `elemWrite`,
	 * `member` (the receiver of a field read), `memberWrite`, `compare`, `iter`, `update` (the read half of a compound
	 * write of the field) or `value` — anything else, an escape. A value the compiler holds in a local is read once per
	 * use of that local, each a fact of its own at the same position (`TypedFactsProbe`).
	 */
	final use: Null<String>;

	/** For a read used as a call receiver, the called field; null otherwise. */
	final method: Null<String>;

	/**
	 * For a write, whether the field alone holds what it stores: every value the right side produces is built right
	 * there (an array literal, a `new Array`, `null`), and the assignment's own value goes nowhere.
	 */
	final fresh: Bool;
}

/**
 * An element write through an array — `a[i] = v`, `a[i] += v`, `a[i]++` — on any receiver: `receiverAt` is the position
 * of the array's own read, the field read or local read found there; null when its file was lost (`stale-foreign`).
 */
typedef ElementWriteFact = {
	final receiver: String;
	final receiverAt: Null<FactPos>;
	final at: FactPos;
}

/** A value of type `from` reaching a place of type `to` through `via`: `var`, `assign`, `arg`, `ret`, `arr`, `obj` or `cast`. */
typedef FlowFact = {
	final from: String;
	final to: String;
	final via: String;
	final at: FactPos;

	/**
	 * Whether the value is an object of exactly the class `from` names: a construction, or a local initialized with one of
	 * its own type and never written again. False in facts that do not record it.
	 */
	final exact: Bool;
}

/**
 * A value of type `from` handed to `target` (`pack.Type.field`), a field of an extern class — target code, which no fact
 * describes — at a parameter the field declares of type `to`, its own type parameters unapplied (`$pack.Type.T`).
 */
typedef HandFact = {
	final target: String;
	final from: String;
	final to: String;
	final at: FactPos;
}

/**
 * A field declaring type parameters of its own (a generic method), read or called at `at`: its declared type `declared`,
 * spelling them (`$name.T`), and the type `applied` the compiler instantiated it at there.
 */
typedef InstantiationFact = {
	final declared: String;
	final applied: String;
	final at: FactPos;
}

/**
 * A non-String operand of a String concatenation, or a non-String thrown value
 * (the exception wrapping hands it to `Std.string`): converted by its `toString`.
 */
typedef StringFact = {
	final operand: String;
	final at: FactPos;

	/**
	 * Whether the operand is an object built as an instance of exactly the class `operand` names: a construction, or a
	 * local initialized with one of its own type and never written again. False in facts that do not record it.
	 */
	final exact: Bool;
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

	/** Whether the member (or the class itself) is read as a value, not called: whatever calls it later is reflection. */
	final isValue: Bool;
	final at: FactPos;

	/**
	 * The type of the call's first argument — the object a reflective access by name acts on — or null when it has none
	 * or the facts do not record it; `receiverExact` when that argument is an object of exactly the class its type names,
	 * `receiverSelf` when it is `this`.
	 */
	final receiver: Null<String>;

	final receiverExact: Bool;
	final receiverSelf: Bool;

	/**
	 * The id of the node whose code holds the call (`FactNode.id`): the function a `this` argument (`receiverSelf`) is the
	 * `this` of — its outermost enclosing field's, for a nested function, which captures it.
	 */
	final holder: String;
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

	/**
	 * The node's range: the body the compiler typed (a method's function, a variable's initializer), not the whole
	 * declaration. For a function spliced in by inlining, the range it was declared at, in its callee.
	 */
	final at: FactPos;

	/**
	 * The channels this node's facts do not capture exactly; a consumer answers Unknown for a question resting on one
	 * (`TypedFactsProbe` lists them). The range queries `callsIn`/`flowsIn` already do.
	 */
	final incomplete: Array<String>;

	/** Whether a macro placed the body outside its type's file: such a node is found by id, never by range. */
	final generated: Bool;

	/** The node an inlined body spliced this function into: it runs there, not where it was declared. Null otherwise. */
	final inlinedFrom: Null<String>;

	/** For the `n`-th further overload of a field, `n`; 0 for the field's own body. */
	final overloadIndex: Int;

	/** The parameters, in order: the compiler gives a parameter no position of its own. */
	final params: Array<{ name: String, type: String }>;

	/**
	 * The signature and parameters each configuration gave the node, one entry per distinct pair: `signature` and
	 * `params` are the first configuration's, and a second entry is a build that typed the node differently.
	 */
	final variants: Array<FactSignature>;

	final calls: Array<CallFact>;
	final news: Array<NewFact>;
	final fields: Array<FieldFact>;
	final elementWrites: Array<ElementWriteFact>;
	final flows: Array<FlowFact>;
	final handed: Array<HandFact>;
	final instantiations: Array<InstantiationFact>;
	final strings: Array<StringFact>;
	final iterations: Array<IterationFact>;
	final reflection: Array<ReflectionFact>;
	final natives: Array<NativeFact>;
	final vars: Array<VarFact>;
	final reads: Array<LocalReadFact>;
	final fns: Array<String>;

	/** The bodies inlined calls spliced into this node, one per method's declared range (`spliceOf`). */
	final splices: Array<SpliceFact>;

	/** The expansions of expression macros written in this node's code or in code an inlined call spliced into it. */
	final expansions: Array<ExpansionFact>;
}

/**
 * The expansion of the expression macro `expander` (`pack.Type.method`): the code it built lies in its declared range
 * (`declared`), and the call of it the compiler replaced in the innermost expression around the expansion of the code it
 * was written in (`anchor`) — the node's own, or a method's an inlined call spliced in. Code spliced in that no inlined
 * method and no macro is declared around has neither `expander` nor `declared`.
 */
typedef ExpansionFact = {
	final expander: Null<String>;
	final anchor: FactPos;
	final declared: Null<FactPos>;
}

/**
 * The body of the method `callee` as inlined calls spliced it into a node: `body` is the method's declared range, which
 * holds every fact of that code, and `sites` the ranges of the node's file its calls ran at, each holding a call site the
 * compiler replaced — the code runs at one of them, never elsewhere in the node.
 */
typedef SpliceFact = {
	final callee: String;
	final body: FactPos;
	final sites: Array<Span>;
} /** A node's signature and parameters as one configuration typed them. */

typedef FactSignature = {
	final signature: String;
	final params: Array<{ name: String, type: String }>;
}

/** A declared field of a typed type. `kind` is `method`, `inline`, `dynamic`, `macro` or `var(<read>,<write>)`. */
typedef FieldDeclFact = {
	final name: String;

	/** The first configuration's kind of the field (`var(get,set)`, `method`, `dynamic`, …): `kinds` holds every one. */
	final kind: String;

	/**
	 * Every kind a configuration gave the field, `kind` first: more than one when builds declare it differently — a
	 * variable in one branch of a conditional region and a property with an accessor in another. A reader deciding by
	 * the kind reads them all.
	 */
	final kinds: Array<String>;

	final type: String;
	final isStatic: Bool;
	final meta: Array<String>;

	/** Every type a configuration gave the field, `type` first: more than one when the builds disagree. */
	final types: Array<String>;

	/** Every count of further overloads a configuration gave the field (`overload`): `type` is the first signature only. */
	final overloads: Array<Int>;
}

/**
 * A type the compiler typed: `kind` is `class`, `interface`, `impl` (an abstract's implementation class), `abstract`,
 * `enum` or `typedef`. `superClass` and `interfaces` carry their type arguments
 * as written; `meta` and `interfaces` hold what any configuration recorded.
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

	/** For a `@:generic` instance, the generic class at the arguments it was built for; null otherwise. */
	final genericOf: Null<String>;

	/** The printed macro calls of the type's `@:build`/`@:autoBuild`/`@:genericBuild`: compile-time code run over it. */
	final builds: Array<String>;

	/**
	 * Whether every configuration that typed it recorded one declaration: one kind, extern in all or in none. `kind` and
	 * `isExtern` are the first configuration's, so a question about either needs this too.
	 */
	var alike: Bool;

	/** For a `typedef`, every type a configuration aliased it to; empty for any other kind. */
	final targets: Array<String>;

	/** For an `abstract`, every type a configuration gave the value it wraps; empty for any other kind. */
	final underlying: Array<String>;

	/**
	 * For an `enum`, every constructor a configuration declared, with its type: a function type returning the enum for one
	 * taking arguments, the enum itself for one taking none. Empty for any other kind.
	 */
	final constructors: Array<{ name: String, type: String }>;
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

	/** The access of a call of a method the compiler spliced in (`CallFact.access`). */
	private static inline final INLINED: String = 'inlined';

	/** The marker of a node an inlined function was spliced into (`TypedFactsProbe`). */
	private static inline final INLINE_SITE_UNKNOWN: String = 'inline-site-unknown';

	/** The configurations that contributed nothing, and why — the table then holds less, and absence answers for it. */
	public final dropped: Array<{ name: String, reason: String }> = [];

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
	private final _expected: Map<String, String> = [];
	private final _stale: Map<String, Bool> = [];

	/** Table key -> the text a rewritten file had when the run started, when it is the text the compile read. */
	private final _originals: Map<String, String> = [];

	private final _dumps: Array<DumpFiles> = [];

	/** Typed type id -> the ids of its field nodes (`nodeIdsOf`), built on first need and dropped by `add`. */
	private var _byOwner: Null<Map<String, Array<String>>> = null;

	private final _read: (String) -> Null<String>;
	private final _key: (String) -> String;

	private function new(read: (String) -> Null<String>, key: (String) -> String) {
		this._read = read;
		this._key = key;
	}

	/** The table key of `file`: what a fact's `FactPos.file` spells it as. */
	public inline function keyOf(file: String): String {
		return _key(file);
	}

	/** Whether any configuration typed code of `file`. */
	public function compiled(file: String): Bool {
		return _nodeFiles.exists(_key(file));
	}

	/**
	 * Whether a configuration may compile `file` as it is now: one read it — the file holds code or a type some
	 * configuration typed, whose record names its text — or the run wrote it after the compiles (`invalidate`), so what a
	 * build makes of the text it has now is not known: a fix may have created it. False only for a file no configuration
	 * read, which no build the table holds compiles.
	 */
	public function mayCompileNow(file: String): Bool {
		final key: String = _key(file);
		return _expected.exists(key) || _stale.exists(key);
	}

	/**
	 * Drop every fact of `file`: the run rewrote it (`--fix`), so no position the compile recorded names its text any more.
	 * The file answers as never compiled from here on. `original` is the text it had before the run wrote it: kept when it is
	 * the text the compile read, so `asCompiled` can still place its facts.
	 *
	 * Facts certified for the text the file has on disk NOW are not the rewrite's to drop: a compile started on demand after
	 * the run wrote reads the new text, and a file written while a compile ran is never certified (`TypedFactsMacro`
	 * marks it). Any other text leaves the file stale and keeps nothing.
	 */
	public function invalidate(file: String, ?original: String): Void {
		final key: String = _key(file);
		final expected: Null<String> = _expected[key];
		final matches: Bool = original != null && (expected == null || FactText.contentHash(original) == expected);
		if (original != null && !matches && expected != null && !_stale.exists(key)) {
			final now: Null<String> = _read(key);
			if (now != null && FactText.contentHash(now) == expected) return;
		}
		if (original != null && matches && !_stale.exists(key) && !_originals.exists(key)) _originals[key] = original;
		_stale[key] = true;
		_sources.remove(key);
		_indexes.remove(key);
		_nodeCache.clear();
	}

	/**
	 * The table read against the text each file had when the compile read it: a file the run rewrote (`invalidate`) answers
	 * at its original text when that was kept, instead of as never compiled. Positions it answers are in that original
	 * text, not in the file as it is now — only a caller that maps between the two may ask it.
	 */
	public function asCompiled(): CompilerFacts {
		if (!_originals.keys().hasNext()) return this;
		final originals: Map<String, String> = _originals;
		final read: (String) -> Null<String> = _read;
		final twin: CompilerFacts = new CompilerFacts(file -> originals[file] ?? read(file), _key);
		for (d in dropped) twin.dropped.push(d);
		for (c in configurations) twin.configurations.push(c);
		for (d in _dumps) twin._dumps.push(d);
		for (k => v in _nodeLines) twin._nodeLines[k] = v;
		for (k => v in _nodeFiles) twin._nodeFiles[k] = v;
		for (k => v in _types) twin._types[k] = v;
		for (k => v in _typeHomes) twin._typeHomes[k] = v;
		for (k => v in _supers) twin._supers[k] = v;
		for (k => v in _subs) twin._subs[k] = v;
		for (k => v in _expected) twin._expected[k] = v;
		for (k in _stale.keys()) if (!originals.exists(k)) twin._stale[k] = true;
		return twin;
	}

	/** The node `id`, its facts unioned over every configuration that typed it; null when none did. */
	public function node(id: String): Null<FactNode> {
		if (_nodeCache.exists(id)) return _nodeCache[id];
		final lines: Null<Array<NodeLine>> = _nodeLines[id];
		final made: Null<FactNode> = lines == null ? null : materialize(id, lines);
		_nodeCache[id] = made;
		return made;
	}

	/** The id of every node some configuration typed: every function and initializer, nested ones included. */
	public inline function nodeIds(): Iterator<String> {
		return _nodeLines.keys();
	}

	/**
	 * The ids of the nodes of the typed type `typeId`'s fields — each field's body or initializer, its further overloads,
	 * its static initializer (`__init__`) — a macro-generated one among them, whichever file it lies in; not the functions
	 * nested in them, which their `fns` list.
	 */
	public function nodeIdsOf(typeId: String): Array<String> {
		var byOwner: Null<Map<String, Array<String>>> = _byOwner;
		if (byOwner == null) {
			final built: Map<String, Array<String>> = [];
			for (id in _nodeLines.keys()) {
				final dot: Int = id.lastIndexOf('.');
				// a nested function's id carries its offset after the field's: `<field id>@<min>`
				if (dot <= 0 || id.indexOf('@', dot) >= 0) continue;
				final owner: String = id.substr(0, dot);
				final ids: Array<String> = built[owner] ?? [];
				ids.push(id);
				built[owner] = ids;
			}
			_byOwner = built;
			byOwner = built;
		}
		return byOwner[typeId] ?? [];
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

	/**
	 * Every call site within `span` in `file`; null — Unknown — when a node there holds facts no range places: a spliced
	 * body (`inline-site-unknown`, `macro-expansion`) not wholly inside `span`, or facts lost to a stale file. With
	 * `spliced`, a body an inlined function was spliced into answers as `within` says, `harmless` too.
	 */
	public function callsIn(file: String, span: Span, spliced: Bool = false, ?harmless: (callee:String) -> Bool): Null<Array<CallFact>> {
		return within(file, span, n -> n.calls, c -> c.at, spliced, harmless);
	}

	/** Every value flow within `span` in `file`; null — Unknown — as `callsIn` says. */
	public function flowsIn(file: String, span: Span, spliced: Bool = false, ?harmless: (callee:String) -> Bool): Null<Array<FlowFact>> {
		return within(file, span, n -> n.flows, f -> f.at, spliced, harmless);
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
		final bare: Bool = FactText.bare(text);
		for (n in nodesAround(file, span)) for (site in FactText.typedSites(n, bare)) {
			final at: Null<FactPos> = site.at;
			final member: Null<String> = site.member;
			if (
				at != null && same(at, file, span) && site.type != '?' && !seen.contains(site.type)
				&& (member == null || FactText.mentions(text, member))
			)
				seen.push(site.type);
		}
		return seen.length == 1 ? seen[0] : null;
	}

	/** The type `id` (`pack.Name`); null when no configuration typed it. */
	public function type(id: String): Null<TypeFact> {
		return _types[id];
	}

	/** The id of every type some configuration typed. */
	public inline function typeIds(): Iterator<String> {
		return _types.keys();
	}

	/** Where the type `id` is declared; null when no configuration typed it or its file cannot be read. */
	public function typePosition(id: String): Null<FactPos> {
		final declared: Null<{ home: String, p: Array<Int> }> = _typeHomes[id];
		return declared == null ? null : position(declared.home, declared.p, []);
	}

	/** Every type `id` extends or implements, directly or not, over the whole typed set; by id, without type arguments. */
	public function supertypesOf(id: String): Array<String> {
		return FactMerge.closure(_supers, id);
	}

	/** Every typed type that extends or implements `id`, directly or not; by id. */
	public function subtypesOf(id: String): Array<String> {
		return FactMerge.closure(_subs, id);
	}

	/** Add one configuration's facts; a dump that is not a complete facts file joins `dropped` instead. */
	public function add(dump: FactsDump): Void {
		final lines: Array<String> = dump.text.split('\n');
		while (lines.length > 0 && lines[lines.length - 1] == '') lines.pop();
		if (lines.length < 2 || !lines[0].startsWith('{"k":"facts","v":1,') || !lines[lines.length - 1].startsWith('{"k":"end"')) {
			dropped.push({ name: dump.name, reason: 'its facts file is not complete' });
			return;
		}
		_byOwner = null;
		final index: Int = _dumps.length;
		final files: DumpFiles = { paths: [], file: dump.file };
		_dumps.push(files);
		configurations.push(dump.name);

		for (raw in lines) {
			final line: String = FactText.detached(raw);
			if (line.startsWith('{"k":"node"'))
				addNode(line, index, dump)
			else if (line.startsWith('{"k":"type"'))
				addType(Json.parse(line), dump)
			else if (line.startsWith('{"k":"src"'))
				addSource(Json.parse(line), dump)
			else if (line.startsWith('{"k":"file"')) {
				final record: FileRecord = Json.parse(line);
				files.paths[record.i] = dump.file(record.path);
			}
		}
	}

	private function addNode(line: String, index: Int, dump: FactsDump): Void {
		final head: Null<NodeHead> = FactText.nodeHead(line);
		if (head == null) return;
		final id: String = head.id;
		final variants: Array<NodeLine> = _nodeLines[id] ?? [];
		_nodeLines[id] = variants;
		if (!variants.exists(v -> v.text == line && (!head.foreign || v.dump == index))) variants.push({ dump: index, text: line });
		// a macro-generated body lies outside its type's file, where no range of that file may claim it
		if (head.generated) return;
		final home: String = dump.file(head.file);
		final ranges: Array<NodeRange> = _nodeFiles[home] ?? [];
		_nodeFiles[home] = ranges;
		// keyed by range too: two `#if` variants of one node sit at different ranges and both must be found
		if (!ranges.exists(r -> r.id == id && r.min == head.min && r.max == head.max))
			ranges.push({ id: id, min: head.min, max: head.max });
	}

	/** Record the text a configuration read of a file; two configurations that read different texts leave it stale. */
	private function addSource(record: SourceRecord, dump: FactsDump): Void {
		final file: String = dump.file(record.path);
		final hash: String = '${record.len}:${record.md5}';
		final known: Null<String> = _expected[file];
		// a file written while the compile ran: the hash names a text the positions may not come from
		if (record.changed == true || (known != null && known != hash))
			_stale[file] = true
		else
			_expected[file] = hash;
	}

	private function addType(record: TypeRecord, dump: FactsDump): Void {
		final made: TypeFact = {
			id: record.id,
			kind: record.kind,
			pack: record.pack,
			params: record.params ?? [],
			meta: record.meta ?? [],
			isExtern: record.ext ?? false,
			superClass: record.sup,
			interfaces: record.ifaces ?? [],
			fields: [
				for (f in record.fields ?? [])
					{
						name: f.n,
						kind: f.k,
						kinds: [f.k],
						type: f.t,
						isStatic: f.s ?? false,
						meta: f.meta ?? [],
						types: [f.t],
						overloads: [f.over ?? 0]
					}
			],
			genericOf: record.of,
			builds: record.builds ?? [],
			alike: true,
			targets: record.target == null ? [] : [record.target],
			underlying: record.under == null ? [] : [record.under],
			constructors: [for (c in record.ctors ?? []) { name: c.n, type: c.t }]
		};
		final known: Null<TypeFact> = _types[record.id];
		if (known == null) {
			_types[record.id] = made;
			_typeHomes[record.id] = { home: dump.file(record.f), p: record.p };
		} else
			FactMerge.type(known, made);
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
	public function nodesAround(file: String, span: Span, ?touching: Bool): Array<FactNode> {
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

	/**
	 * The facts `pick` takes from the nodes of `file` meeting `span` that lie inside it; a node wholly inside `span`
	 * gives all of them, wherever the compiler placed them. Null — Unknown — when one of those nodes cannot say where
	 * some of its facts run (`callsIn`). With `spliced`, a node an inlined function was spliced into (`inline-site-unknown`)
	 * gives, beside those inside `span`, each fact it holds outside its own range (`placed`) that may run in `span`: one
	 * a splice brought (`spliceOf`) when a site of that splice meets `span` and the method is not `harmless` — it runs no
	 * project code, and the `inlined` call of it answers for all it does — and one no splice brought wherever it lies, since
	 * it may run anywhere in the node. What a macro expanded into, and facts lost to a stale file, stay Unknown.
	 */
	public function within<F>(
		file: String, span: Span, pick: (FactNode) -> Array<F>, at: (F) -> FactPos, spliced: Bool = false,
		?harmless: (callee:String) -> Bool
	): Null<Array<F>> {
		final key: String = _key(file);
		final dropped: (callee:String) -> Bool = harmless ?? callee -> false;
		function inside(where: FactPos): Bool return where.file == key && span.from <= where.span.from && where.span.to <= span.to;
		function runsIn(n: FactNode, where: FactPos): Bool {
			final splice: Null<SpliceFact> = spliceOf(n, where);
			if (splice == null) return true;
			return !dropped(splice.callee) && splice.sites.exists(s -> s.from < span.to && span.from < s.to);
		}
		final out: Array<F> = [];
		for (n in nodesAround(file, span, true)) {
			if (n.incomplete.contains('stale-foreign')) return null;
			final whole: Bool = inside(n.at);
			final splice: Bool = n.incomplete.contains(INLINE_SITE_UNKNOWN);
			if (!whole && (n.incomplete.contains('macro-expansion') || (splice && !spliced))) return null;
			for (fact in pick(n)) {
				final where: FactPos = at(fact);
				if (splice && spliced && !placed(n, where) ? runsIn(n, where) : whole || inside(where)) out.push(fact);
			}
		}
		return out;
	}

	private function indexOf(file: String): Null<CodepointIndex> {
		if (_indexes.exists(file)) return _indexes[file];
		final source: Null<String> = sourceOf(file);
		final index: Null<CodepointIndex> = source == null ? null : CodepointIndex.of(source);
		_indexes[file] = index;
		return index;
	}

	/** The source of the file keyed `file` when it is the text the compile read, read once; null otherwise. */
	public function sourceOf(file: String): Null<String> {
		if (_sources.exists(file)) return _sources[file];
		final read: Null<String> = _stale.exists(file) ? null : _read(file);
		final expected: Null<String> = _expected[file];
		// facts of a text other than the one on disk describe no position in it: the file's facts are absent
		final source: Null<String> = read == null || expected == null || FactText.contentHash(read) == expected ? read : null;
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

	/** The node `id` as `record` heads it, at `at`, with no facts yet. */
	private static function emptyNode(id: String, record: NodeRecord, at: FactPos): FactNode {
		return {
			id: id,
			kind: record.kind,
			owner: record.owner,
			isStatic: record.s ?? false,
			signature: record.t,
			name: record.name,
			at: at,
			incomplete: (record.inc ?? []).copy(),
			generated: record.gen ?? false,
			inlinedFrom: record.inl,
			overloadIndex: record.ov ?? 0,
			params: [for (p in record.params ?? []) { name: p.n, type: p.t }],
			variants: [],
			calls: [],
			news: [],
			fields: [],
			elementWrites: [],
			flows: [],
			handed: [],
			instantiations: [],
			strings: [],
			iterations: [],
			reflection: [],
			natives: [],
			vars: [],
			reads: [],
			fns: [],
			splices: [],
			expansions: []
		};
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
			final node: FactNode = made ?? emptyNode(id, record, at);
			made = node;
			FactMerge.variant(node.variants, record.t, [for (p in record.params ?? []) { name: p.n, type: p.t }]);
			for (channel in record.inc ?? []) if (!node.incomplete.contains(channel)) node.incomplete.push(channel);

			// a fact whose file the table cannot read any more — rewritten, or of another text — is lost to the node: say so. A
			// position the record leaves out is none
			function place(p: Null<Array<Int>>): Null<FactPos> {
				if (p == null) return null;
				final where: Null<FactPos> = position(home, p, files.paths);
				if (where == null && !node.incomplete.contains('stale-foreign')) node.incomplete.push('stale-foreign');
				return where;
			}
			// a fact is identified by its resolved text, so the same site from two configurations is one fact
			function fresh(category: String, fact: Any, where: FactPos): Bool {
				final identity: String = category + ' ' + where.file + ' ' + where.span.from + ' ' + where.span.to + ' '
					+ Json.stringify(fact);
				if (seen.exists(identity)) return false;
				seen[identity] = true;
				return true;
			}
			FactMerge.collect(
				record.calls, c -> place(c.p), fresh.bind('call'), (c, where) -> ({
					target: c.t,
					access: c.a,
					receiver: c.r,
					receiverAt: place(c.rp),
					result: c.rt,
					at: where,
					signature: c.sig,
					site: place(c.s),
					body: place(c.d),
					operand: c.o,
					operandExact: c.x == true
				}: CallFact),
				node.calls
			);
			FactMerge.collect(
				record.news, x -> place(x.p), fresh.bind('new'), (x, where) -> ({type: x.t, instance: x.ty, at: where }: NewFact),
				node.news
			);
			FactMerge.collect(
				record.fields, f -> place(f.p), fresh.bind('field'), (f, where) -> ({
					owner: f.o,
					field: f.f,
					access: f.a,
					receiver: f.r,
					type: f.t,
					write: f.w ?? false,
					at: where,
					use: f.u,
					method: f.m,
					fresh: f.fresh ?? false
				}: FieldFact),
				node.fields
			);
			FactMerge.collect(
				record.elems, x -> place(x.p), fresh.bind('elem'),
				(x, where) -> ({receiver: x.r, receiverAt: place(x.rp), at: where }: ElementWriteFact), node.elementWrites
			);
			FactMerge.collect(
				record.flows, f -> place(f.p), fresh.bind('flow'), (f, where) -> ({
					from: f.s,
					to: f.d,
					via: f.c,
					at: where,
					exact: f.x == true
				}: FlowFact),
				node.flows
			);
			FactMerge.collect(
				record.hands, h -> place(h.p), fresh.bind('hand'), (h, where) -> ({
					target: h.t,
					from: h.s,
					to: h.d,
					at: where
				}: HandFact),
				node.handed
			);
			FactMerge.collect(
				record.gens, x -> place(x.p), fresh.bind('gen'),
				(x, where) -> ({declared: x.d, applied: x.s, at: where }: InstantiationFact), node.instantiations
			);
			FactMerge.collect(
				record.strs, s -> place(s.p), fresh.bind('str'),
				(s, where) -> ({operand: s.o, at: where, exact: s.x == true }: StringFact), node.strings
			);
			FactMerge.collect(
				record.iters, i -> place(i.p), fresh.bind('iter'), (i, where) -> ({binder: i.v, iterated: i.i, at: where }: IterationFact),
				node.iterations
			);
			FactMerge.collect(
				record.refl, r -> place(r.p), fresh.bind('refl'), (r, where) -> ({
					target: r.t,
					name: r.n,
					typeArgument: r.c,
					isValue: r.v ?? false,
					at: where,
					receiver: r.r,
					receiverExact: r.x == true,
					receiverSelf: r.h == true,
					holder: id
				}: ReflectionFact),
				node.reflection
			);
			FactMerge.collect(
				record.native, n -> place(n.p), fresh.bind('native'), (n, where) -> ({kind: n.w, name: n.n, at: where }: NativeFact),
				node.natives
			);
			FactMerge.collect(
				record.vars, v -> place(v.p), fresh.bind('var'), (v, where) -> ({name: v.n, type: v.t, at: where }: VarFact), node.vars
			);
			FactMerge.collect(
				record.reads, r -> place([for (i in 0...r.length - 1) (r[i]: Int)]), fresh.bind('read'), (r, where) -> ({
					type: (r[r.length - 1]: String),
					at: where
				}: LocalReadFact),
				node.reads
			);
			for (x in record.exps ?? []) {
				final root: Null<FactPos> = place(x.p);
				final anchor: Null<FactPos> = place(x.a);
				final declared: Null<FactPos> = place(x.d);
				if (root == null || anchor == null || (x.d != null && declared == null)) continue;
				final written: FactPos = anchor;
				// the root tells one expansion from another, and no question asks it
				if (fresh('exp', x, root)) node.expansions.push({ expander: x.t, anchor: written, declared: declared });
			}
			for (f in record.fns ?? []) if (!node.fns.contains(f)) node.fns.push(f);
		}
		collectSplices(made);
		return made;
	}

	/** The bodies the `inlined` calls of `node` spliced in, one per declared range with every site a call of it ran at. */
	private static function collectSplices(node: Null<FactNode>): Void {
		if (node == null) return;
		for (c in node.calls) {
			final body: Null<FactPos> = c.body;
			final site: Null<FactPos> = c.site;
			if (c.access == INLINED && body != null && site != null) {
				final declared: FactPos = body;
				final ran: Span = site.span;
				final known: Null<SpliceFact> = node.splices.find(s ->
					s.body.file == declared.file && sameSpan(s.body.span, declared.span)
				);
				if (known == null)
					node.splices.push({ callee: c.target ?? '', body: declared, sites: [ran] })
				else if (!known.sites.exists(s -> sameSpan(s, ran)))
					known.sites.push(ran);
			}
		}
	}

	/**
	 * The table over `dumps`. `read` gives the source of a file by its table key (null when it cannot be read: its facts
	 * are then absent), and `key` maps a path a caller asks about to a table key. A dump that is not a complete facts
	 * file of this version — no header, no closing record — contributes nothing.
	 */
	public static function build(
		dumps: Array<FactsDump>, read: (String) -> Null<String>, key: (String) -> String, ?dropped: Array<{ name: String, reason: String }>
	): CompilerFacts {
		final facts: CompilerFacts = create(read, key);
		for (d in dropped ?? []) facts.dropped.push(d);
		for (dump in dumps) facts.add(dump);
		return facts;
	}

	/** An empty table, which `add` fills one dump at a time: each dump's text can then be freed before the next is read. */
	public static function create(read: (String) -> Null<String>, key: (String) -> String): CompilerFacts {
		return new CompilerFacts(read, key);
	}

	/**
	 * Whether the fact at `at` lies in the range of its node `n`: one outside it — in another file, or elsewhere in the
	 * node's own — was spliced in by inlining, at its callee's positions (`TypedFactsProbe`), and runs at a site of the node
	 * no range names.
	 */
	public static function placed(n: FactNode, at: FactPos): Bool {
		return at.file == n.at.file && n.at.span.from <= at.span.from && at.span.to <= n.at.span.to;
	}

	/**
	 * The splice that brought the fact at `at` into `n`: the innermost declared range of a method an inlined call of `n`
	 * spliced in that holds it (`FactNode.splices`) — the code runs at a site of that splice, and nowhere else in `n`. Null
	 * for a fact `n` places itself, and for one no such range holds: the compiler put it where no method is declared, or
	 * the facts record no site for the call (`CallFact.site`), and it may run anywhere in `n`.
	 */
	public static function spliceOf(n: FactNode, at: FactPos): Null<SpliceFact> {
		if (placed(n, at)) return null;
		var best: Null<SpliceFact> = null;
		for (s in n.splices) {
			final body: Span = s.body.span;
			final holds: Bool = s.body.file == at.file && body.from <= at.span.from && at.span.to <= body.to;
			if (holds && (best == null || body.to - body.from < best.body.span.to - best.body.span.from)) best = s;
		}
		return best;
	}

	/** Whether `a` and `b` are the same range. */
	private static inline function sameSpan(a: Span, b: Span): Bool {
		return a.from == b.from && a.to == b.to;
	}

	/** The id of type string `type` without its type arguments. */
	public static function baseId(type: String): String {
		final open: Int = type.indexOf('<');
		return open < 0 ? type : type.substr(0, open);
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

private typedef SourceRecord = {
	final path: String;
	final len: Int;
	final md5: String;
	final ?changed: Bool;
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
	final ?over: Int;
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
	final ?of: String;
	final ?builds: Array<String>;
	final ?ifaces: Array<String>;
	final ?fields: Array<FieldRecord>;
	final ?target: String;
	final ?under: String;
	final ?ctors: Array<{ n: String, t: String }>;
}

private typedef CallRecord = {
	final ?t: String;
	final a: String;
	final ?r: String;
	final ?rp: Array<Int>;
	final rt: String;
	final ?sig: String;
	final p: Array<Int>;
	final ?s: Array<Int>;
	final ?d: Array<Int>;
	final ?o: String;
	final ?x: Bool;
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
	final ?inc: Array<String>;
	final ?gen: Bool;
	final ?inl: String;
	final ?ov: Int;
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
		p: Array<Int>,
		?u: String,
		?m: String,
		?fresh: Bool
	}>;
	final ?elems: Array<{ r: String, rp: Array<Int>, p: Array<Int> }>;
	final ?flows: Array<{
		s: String,
		d: String,
		c: String,
		p: Array<Int>,
		?x: Bool
	}>;
	final ?hands: Array<{
		t: String,
		s: String,
		d: String,
		p: Array<Int>
	}>;
	final ?gens: Array<{ d: String, s: String, p: Array<Int> }>;
	final ?strs: Array<{ o: String, p: Array<Int>, ?x: Bool }>;
	final ?iters: Array<{ v: String, i: String, p: Array<Int> }>;
	final ?refl: Array<{
		t: String,
		?n: String,
		?c: String,
		?v: Bool,
		?r: String,
		?x: Bool,
		?h: Bool,
		p: Array<Int>
	}>;
	final ?native: Array<{ w: String, n: String, p: Array<Int> }>;
	final ?vars: Array<{ n: String, t: String, p: Array<Int> }>;

	/** `[min, max, type]`, or `[file index, min, max, type]` for a foreign position. */
	final ?reads: Array<Array<Any>>;
	final ?exps: Array<{
		?t: String,
		p: Array<Int>,
		a: Array<Int>,
		?d: Array<Int>
	}>;
	final ?fns: Array<String>;
}
