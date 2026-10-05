package anyparse.query;

import anyparse.check.FactsTypeText;
import anyparse.check.FactsTypeTree;
import anyparse.check.FactsTypeTree.FactsType;
import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.TypeFact;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * Which functions a call of a value may run, read off the compiler's facts under the truth (`FactsView.truth`): only the
 * function values that may reach it, where the facts say which (`admitted`). Any function value is admitted otherwise.
 *
 * A value called that is a PARAMETER of an instance method, which the method never assigns, holds what the invocations of
 * the method hand it (`argumentValues`). When the method's class and its subclasses never left the type system (no escaped
 * type is one, `ValueEscapes.escapedIds`) — reading a method as a value, or any field by a name, lets the object it is read
 * off escape (`FactsEscapes`), and target code reaches only the objects handed to it — the method runs only where a typed
 * call of it, or of a member of a supertype it overrides, is written: each such call fact (`CallFact`, `INVOKING`) names it.
 * Each must
 * hand that parameter a function expression, read off the call's text at the call's own range with exactly as many
 * arguments as the method takes; the parameter then holds exactly those functions, by where each is written. A call of
 * the method an inline splice or a macro's expansion wrote, of an unread text or with another argument there, leaves the
 * values to the type.
 *
 * By its TYPE, a value reaches a place only as a value of a type the compiler unified with the place's, unless it passed
 * through a place no function type types — `Dynamic`, `Any`, a type parameter, a structure, target code — or an unchecked
 * cast: there it left the type system (`FactsEscapes.functionTypes`), and from there it may arrive at any call. A method
 * read by a name off a value of no type, or by reflection, is such a value from the start
 * (`FactsMethodValues.obtainedUntyped`). So a call of a value of a function type runs a function whose own type may unify
 * with the called one (`mayUnify`) and one that may have escaped, and nothing else (`mayRun`). A function whose type the
 * facts do not give, a called type that is no function type, and escapes that are not known admit any function.
 *
 * `mayUnify` over-approximates the compiler's unification of two function types by the positive reasons it refuses one: a
 * different number of arguments; no result where the called type wants one (`Void` unifies with no other result); an
 * argument or a result whose two types are each a class, an interface or an enum the builds typed, neither a subtype of
 * the other. Any other pair — an abstract, which may convert, a type parameter, `Dynamic`, a structure, a typedef that does
 * not read through to one type — may unify. The relation it decides holds along a chain of places, as unification does, so a
 * value placed in a place of another function type still reaches only what that type admits.
 */
@:nullSafety(Strict)
final class FunctionValueTypes {

	/** The kinds of a typed type no value of another such type unifies with but its subtypes' (`TypeFact.kind`). */
	private static final NOMINAL_KINDS: Array<String> = ['class', 'interface', 'enum'];

	/** The call accesses that may run an instance method a type declares (`CallFact.access`). */
	private static final INVOKING: Array<String> = ['FInstance', 'FClosure', 'super'];

	/** The kind of a typed class (`TypeFact.kind`). */
	private static inline final CLASS_KIND: String = 'class';

	/** The field kind of a method no assignment replaces (`FieldDeclFact.kinds`). */
	private static inline final METHOD_KIND: String = 'method';

	/** The kind of a typed typedef (`TypeFact.kind`). */
	private static inline final TYPEDEF_KIND: String = 'typedef';

	/** The nullable wrapper: it unifies as what it wraps. */
	private static inline final NULLABLE: String = 'Null';

	/** The result type of a function that returns nothing. */
	private static inline final VOID: String = 'Void';

	/** How many typedefs are read through to a type before it counts as unread. */
	private static inline final MAX_ALIASES: Int = 8;

	/** What the facts spell a type parameter with (`FactsTypeTree`). */
	private static inline final PARAMETER: String = '$$';

	/** The facts node kinds of a function expression and of a local function (`TypedFactsProbe`). */
	private static final EXPRESSION_KINDS: Array<String> = ['fn', 'local'];

	/** What a nested function's graph id holds (`FactsView.NESTED_MARK`): a lambda's or a local function's value is typed. */
	private static inline final NESTED: String = '#';

	private final _view: FactsView;
	private final _scope: ReachProject;

	/** The function types of the function values that may have escaped (`ValueEscapes.escapedFunctions`), or null for any. */
	private final _escapedFunctions: () -> Null<Array<FactsType>>;

	/** The types whose instances may have escaped, by typed id (`ValueEscapes.escapedIds`), or null for any. */
	private final _escapedTypes: () -> Null<Array<String>>;

	/** Which methods the program may obtain as values (`FactsMethodValues`). */
	private final _methods: () -> FactsMethodValues;

	/** The types a value of a type parameter may have (`ValueEscapes.parameterBindings`), or null when not known. */
	private final _bindings: (path:String) -> Null<Array<FactsType>>;

	/** A called value's range -> the function values it may hold (`argumentValues`), or null for those its type admits. */
	private final _arguments: Map<String, Null<Array<FactPos>>> = [];

	/** A table key -> its text and tree (`parsed`), or null when it does not read. */
	private final _parsed: Map<String, Null<ParsedFile>> = [];

	/** A facts type -> every type a value of it may be held as (`typedAs`). */
	private final _typedAs: Map<String, Array<String>> = [];

	/** The flows of the facts by the type of the value (`flowGraph`), built on first need. */
	private var _flows: Null<Map<String, Array<String>>> = null;

	/** The escaped function types as the facts spell them (`escapedTexts`), read on first need. */
	private var _escapedText: Null<Array<String>> = null;

	/** Facts node id -> the signatures of the function expressions calling it (`callerSignatures`), built on first need. */
	private var _callers: Null<Map<String, Array<String>>> = null;

	/** Graph node id -> whether its function may be obtained as a value of no type (`obtainedUntyped`). */
	private final _untyped: Map<String, Bool> = [];

	/** Field name -> the call facts that may run an instance method of it (`invocationsOf`), built on first need. */
	private var _invocations: Null<Map<String, Array<CallFact>>> = null;

	public function new(
		view: FactsView, scope: ReachProject, escapedFunctions: () -> Null<Array<FactsType>>, escapedTypes: () -> Null<Array<String>>,
		bindings: (path:String) -> Null<Array<FactsType>>, methods: () -> FactsMethodValues
	) {
		_bindings = bindings;
		_view = view;
		_scope = scope;
		_escapedFunctions = escapedFunctions;
		_escapedTypes = escapedTypes;
		_methods = methods;
	}

	/**
	 * Of `candidates`, the functions a call of a value of the facts type `called` may run (see the type doc): those its
	 * argument values say (`argumentValues`) when the value called, at `at`, is a parameter they bind; else those its type
	 * admits (`mayRun`).
	 */
	public function admitted(g: CallGraph, candidates: Array<String>, called: String, at: Null<FactPos>): Array<String> {
		final values: Null<Array<FactPos>> = at == null || !_view.truth ? null : argumentValues(at);
		if (values == null) return [for (id in candidates) if (mayRun(g, id, called)) id];
		final table: CompilerFacts = _view.table;
		return [
			for (id in candidates)
				if (g.declarationsOf(id).exists(d -> values.exists(v -> v.file == table.keyOf(d.file) && v.span.from == d.span.from))) id
		];
	}

	/**
	 * Whether a call of a value of the facts type `called` may run the function the graph node `id` is, by type (see the type
	 * doc): always but under the truth, for a called type that reads as no function type, while the escapes are not known,
	 * and for a function the facts give no type of.
	 */
	public function mayRun(g: CallGraph, id: String, called: String): Bool {
		final target: String = FactsTypeText.unwrapNull(called);
		final escaped: Null<Array<String>> = escapedTexts();
		if (!_view.truth || functionOf(FactsTypeTree.read(target)) == null || escaped == null) return true;
		final own: Null<Array<String>> = valueTypes(g, id);
		if (own == null) return true;
		for (s in own) for (t in typedAs(s)) if (sameOrGeneric(t, target) || escaped.exists(e -> sameOrGeneric(t, e))) return true;
		return obtainedUntyped(g, id);
	}

	/**
	 * Whether a value held where the facts type `held` types it may be held where `place` does: the two are the same type —
	 * a value moves between two others only by a flow the facts record (`typedAs`) — or one names a type parameter, which an
	 * instantiation binds to a type no text spells, and the two may unify (`mayUnify`).
	 */
	private function sameOrGeneric(held: String, place: String): Bool {
		if (held == place) return true;
		if (held.indexOf(PARAMETER) < 0 && place.indexOf(PARAMETER) < 0) return false;
		final a: Null<FactsType> = functionOf(FactsTypeTree.read(held));
		final b: Null<FactsType> = functionOf(FactsTypeTree.read(place));
		if (a == null || b == null) return true;
		return mayUnify(a, b);
	}

	/**
	 * Every type a value first held where the facts type `type` types it may be held as: that type, and each a flow the
	 * facts record carries a value of one of them into (`FlowFact`) — the compiler records one wherever a value moves between
	 * two types it spells differently. Read through `Null<T>`; built once per type.
	 */
	private function typedAs(type: String): Array<String> {
		final start: String = FactsTypeText.unwrapNull(type);
		final held: Null<Array<String>> = _typedAs[start];
		if (held != null) return held;
		final flows: Map<String, Array<String>> = flowGraph();
		final out: Array<String> = [start];
		var i: Int = 0;
		while (i < out.length) for (to in flows[out[i++]] ?? []) if (!out.contains(to)) out.push(to);
		_typedAs[start] = out;
		return out;
	}

	/** Facts type -> the types the flows the facts record carry a value of it into, read through `Null<T>`; built once. */
	private function flowGraph(): Map<String, Array<String>> {
		final held: Null<Map<String, Array<String>>> = _flows;
		if (held != null) return held;
		final out: Map<String, Array<String>> = [];
		final table: CompilerFacts = _view.table;
		for (id in table.nodeIds()) for (f in table.node(id)?.flows ?? []) {
			final from: String = FactsTypeText.unwrapNull(f.from);
			final to: String = FactsTypeText.unwrapNull(f.to);
			final list: Array<String> = out[from] ?? [];
			if (!list.contains(to)) list.push(to);
			out[from] = list;
		}
		_flows = out;
		return out;
	}

	/** The function types of the function values that may have escaped (`_escapedFunctions`), spelled as the facts do; null for any. */
	private function escapedTexts(): Null<Array<String>> {
		final held: Null<Array<String>> = _escapedText;
		if (held != null) return held;
		final types: Null<Array<FactsType>> = _escapedFunctions();
		if (types == null) return null;
		final out: Array<String> = [for (t in types) FactsTypeText.unwrapNull(FactsTypeTree.text(t))];
		_escapedText = out;
		return out;
	}

	/**
	 * The function values a call of the value read at `at` may run, by where each is written, when that value is a parameter
	 * of an instance method only its typed calls invoke, each handing it a function expression (see the type doc); null
	 * otherwise, and when the code there does not read. Read once per range.
	 */
	private function argumentValues(at: FactPos): Null<Array<FactPos>> {
		final key: String = '${at.file}:${at.span.from}:${at.span.to}';
		if (_arguments.exists(key)) return _arguments[key];
		final found: Null<Array<FactPos>> = readArguments(at);
		_arguments[key] = found;
		return found;
	}

	/**
	 * `argumentValues`, read: the identifier at `at` reads a parameter its function never writes (`Refs`), of a member
	 * function of the one typed type its type's name stands for, whose invocations then answer (`invokedWith`).
	 */
	private function readArguments(at: FactPos): Null<Array<FactPos>> {
		final read: Null<ParsedFile> = parsed(at.file);
		final shape: RefShape = _scope.shape;
		if (read == null) return null;
		final name: String = StringTools.trim(read.source.substring(at.span.from, at.span.to));
		final hits: Array<RefHit> = Refs.find(name, read.tree, shape);
		final hit: Null<RefHit> = hits.find(h -> h.kind == Read && h.span.from == at.span.from && h.span.to == at.span.to);
		final declared: Null<QueryNode> = hit?.bindingNode;
		final binding: Null<Span> = hit?.bindingSpan;
		if (declared == null || binding == null) return null;
		if (!(shape.paramKinds ?? []).contains(declared.kind)) return null;
		// a parameter the function writes holds what it is assigned as well
		if (hits.exists(h -> h.kind == Write && h.bindingSpan?.from == binding.from && h.bindingSpan?.to == binding.to)) return null;
		final method: Null<{ fn: QueryNode, index: Int, count: Int }> = declaringFunction(read.tree, declared);
		final fnSpan: Null<Span> = method?.fn.span;
		final fnName: Null<String> = method?.fn.name;
		if (method == null || fnSpan == null || fnName == null || !(shape.functionKinds ?? []).contains(method.fn.kind)) return null;
		final typeName: Null<String> = MemberTouchScan.typeAt(read.tree, fnSpan.from);
		final typed: Array<String> = typeName == null ? [] : _view.bySimpleName()[typeName] ?? [];
		if (typed.length != 1) return null;
		return invokedWith(typed[0], fnName, method.index, method.count);
	}

	/**
	 * Where the function expressions each invocation of the instance method `name` of the typed class `owner` hands its
	 * `index`-th of `count` parameters are written; null when the method may be invoked otherwise (see the type doc) or an
	 * invocation hands it anything else.
	 */
	private function invokedWith(owner: String, name: String, index: Int, count: Int): Null<Array<FactPos>> {
		final table: CompilerFacts = _view.table;
		final fact: Null<TypeFact> = table.type(owner);
		final field: Null<FieldDeclFact> = fact?.fields.find(f -> f.name == name);
		if (fact == null || field == null) return null;
		if (fact.kind != CLASS_KIND || !fact.alike || field.isStatic) return null;
		// a `dynamic` method's field holds whatever is assigned to it: a call of the field runs that
		if (!field.kinds.foreach(k -> k == METHOD_KIND)) return null;
		if (!field.types.foreach(t -> arity(t) == count)) return null;
		final hierarchy: Array<String> = [owner].concat(table.subtypesOf(owner));
		final escaped: Null<Array<String>> = _escapedTypes();
		// an object no flow let leave the type system is invoked only where its type is written: a method read as a value, or a
		// field read by a name off it, lets it escape (`FactsEscapes`)
		if (escaped == null || escaped.exists(e -> hierarchy.contains(e))) return null;
		final callers: Array<String> = [owner].concat(table.supertypesOf(owner));
		final out: Array<FactPos> = [];
		for (call in invocationsOf(name)) {
			final target: String = call.target ?? '';
			if (!callers.contains(CompilerFacts.baseId(target.substr(0, target.lastIndexOf('.'))))) continue;
			final value: Null<FactPos> = handed(call.at, index, count);
			if (value == null) return null;
			out.push(value);
		}
		return out;
	}

	/**
	 * Where the function expression the call at `at` hands as its `index`-th of `count` arguments is written; null when the
	 * call does not read as one with `count` arguments, or that one is no function expression.
	 */
	private function handed(at: FactPos, index: Int, count: Int): Null<FactPos> {
		final read: Null<ParsedFile> = parsed(at.file);
		final shape: RefShape = _scope.shape;
		final call: Null<QueryNode> = read == null ? null : callAt(read.tree, at.span);
		if (call == null || call.children.length != count + 1) return null;
		final value: QueryNode = BoolExprShape.unwrapParens(call.children[index + 1], shape.parenKind);
		final span: Null<Span> = value.span;
		return span == null || !(shape.lambdaKinds ?? []).contains(value.kind) ? null : { file: at.file, span: span };
	}

	/** Every call fact naming a field `name` that may run an instance method: the calls of the builds, by field name, read once. */
	private function invocationsOf(name: String): Array<CallFact> {
		var index: Null<Map<String, Array<CallFact>>> = _invocations;
		if (index == null) {
			final built: Map<String, Array<CallFact>> = [];
			final table: CompilerFacts = _view.table;
			for (id in table.nodeIds()) for (c in table.node(id)?.calls ?? []) {
				final target: Null<String> = c.target;
				if (target == null || !INVOKING.contains(c.access)) continue;
				final field: String = target.substr(target.lastIndexOf('.') + 1);
				final list: Array<CallFact> = built[field] ?? [];
				list.push(c);
				built[field] = list;
			}
			_invocations = built;
			index = built;
		}
		return index[name] ?? [];
	}

	/** The function node of `tree` declaring the parameter `param`, its position among the function's parameters and their count. */
	private function declaringFunction(tree: QueryNode, param: QueryNode): Null<{ fn: QueryNode, index: Int, count: Int }> {
		final kinds: Array<String> = _scope.shape.paramKinds ?? [];
		var found: Null<{ fn: QueryNode, index: Int, count: Int }> = null;
		function walk(node: QueryNode): Void {
			if (found != null) return;
			final params: Array<QueryNode> = [for (c in node.children) if (kinds.contains(c.kind)) c];
			final index: Int = params.indexOf(param);
			if (index >= 0) {
				found = { fn: node, index: index, count: params.length };
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/** The call node of `tree` spanning exactly `span`, or null. */
	private function callAt(tree: QueryNode, span: Span): Null<QueryNode> {
		final kind: Null<String> = _scope.shape.callKind;
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			final s: Null<Span> = node.span;
			if (found != null || (s != null && (span.from < s.from || span.to > s.to))) return;
			if (s != null && s.from == span.from && s.to == span.to && node.kind == kind) {
				found = node;
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/** The text the facts of the file keyed `key` were read off and its tree, parsed once; null when it does not read. */
	private function parsed(key: String): Null<ParsedFile> {
		if (_parsed.exists(key)) return _parsed[key];
		final source: Null<String> = _view.table.sourceOf(key);
		final tree: Null<QueryNode> = source == null ? null : try _scope.plugin.parseFile(source) catch (exception: Exception) null;
		final read: Null<ParsedFile> = source == null || tree == null ? null : { source: source, tree: tree };
		_parsed[key] = read;
		return read;
	}

	/**
	 * The function types the builds gave the function the graph node `id` is, as the facts spell them: the signatures of
	 * the bodies its facts are (`CallGraphFacts.faceted`), each build's, or — for a member read by its syntax — the types each
	 * typed type of its type's name declares it with; and the signature of every function the facts hold that calls it, a
	 * `.bind` closure the compiler made of it among them (`callerSignatures`), whose value runs it. Null when none is known.
	 */
	private function valueTypes(g: CallGraph, id: String): Null<Array<String>> {
		final node: Null<CallGraph.FnNode> = g.node(id);
		if (node == null) return null;
		final texts: Array<String> = [];
		final ids: Array<String> = [];
		final bodies: Null<Array<FactNode>> = g.facts?.faceted[id];
		if (bodies != null)
			for (b in bodies) {
				ids.push(b.id);
				texts.push(b.signature);
				for (v in b.variants) texts.push(v.signature);
			}
		else {
			final type: Null<String> = node.typeName;
			final name: Null<String> = node.name;
			if (type == null || name == null || id.indexOf(NESTED) >= 0) return null;
			for (typed in _view.bySimpleName()[type] ?? []) for (f in _view.table.type(typed)?.fields ?? []) if (f.name == name) {
				ids.push('$typed.$name');
				for (t in f.types) texts.push(t);
			}
		}
		if (texts.length == 0) return null;
		final callers: Map<String, Array<String>> = callerSignatures();
		for (own in ids) for (t in callers[own] ?? []) if (!texts.contains(t)) texts.push(t);
		return texts;
	}

	/** Facts node id -> the signatures of the function expressions the facts hold that call it; built once. */
	private function callerSignatures(): Map<String, Array<String>> {
		final held: Null<Map<String, Array<String>>> = _callers;
		if (held != null) return held;
		final out: Map<String, Array<String>> = [];
		final table: CompilerFacts = _view.table;
		for (id in table.nodeIds()) {
			final n: Null<FactNode> = table.node(id);
			if (n == null || !EXPRESSION_KINDS.contains(n.kind)) continue;
			for (c in n.calls) {
				final target: Null<String> = c.target;
				if (target == null) continue;
				final list: Array<String> = out[target] ?? [];
				if (!list.contains(n.signature)) list.push(n.signature);
				out[target] = list;
			}
		}
		_callers = out;
		return out;
	}

	/**
	 * Whether the function the graph node `id` is may be obtained as a value of no type, under the truth: a method read by its
	 * name off a value of no class or by reflection (`FactsMethodValues.obtainedUntyped`), off an object that may be of a type
	 * its type's name stands for or of a subtype. Such a value may be called wherever a value of any type is: code the walk
	 * cannot follow may run it. A lambda or a local function is obtained only as the typed value its expression makes. Read
	 * once per node.
	 */
	public function obtainedUntyped(g: CallGraph, id: String): Bool {
		if (!_view.truth || id.indexOf(NESTED) >= 0) return false;
		final held: Null<Bool> = _untyped[id];
		if (held != null) return held;
		final node: Null<CallGraph.FnNode> = g.node(id);
		final type: Null<String> = node?.typeName;
		final name: Null<String> = node?.name;
		final owners: Array<String> = type == null ? [] : _view.bySimpleName()[type] ?? [];
		final hierarchy: Array<String> = [];
		for (o in owners) for (t in [o].concat(_view.table.subtypesOf(o))) if (!hierarchy.contains(t)) hierarchy.push(t);
		// a constructor and the pseudo-nodes running a type's initializers are no field any read names
		final initializers: Bool = name == CallGraph.INIT_NAME || name == CallGraph.STATIC_INIT_NAME
			|| name == (_scope.shape.constructorName ?? 'new');
		final statics: Bool = name != null
			&& owners.exists(o -> _view.table.type(o)?.fields.exists(f -> f.name == name && f.isStatic) == true);
		final answer: Bool = !initializers
			&& (name == null || hierarchy.length == 0 || _methods().obtainedUntyped(name, hierarchy, _escapedTypes(), _bindings, statics));
		_untyped[id] = answer;
		return answer;
	}

	/**
	 * Whether a function value of the type `value` may unify with a place of the type `place`, both read through
	 * `functionOf` (see the type doc).
	 */
	private function mayUnify(value: FactsType, place: FactsType): Bool {
		return switch [value, place] {
			case [Function(given, result), Function(wanted, expected)]:
				if (given.length != wanted.length) return false;
				final wantsResult: Bool = !isVoid(expected);
				if (wantsResult && isVoid(result)) return false;
				for (i in 0...given.length) if (unrelated(wanted[i].type, given[i].type)) return false;
				!wantsResult || !unrelated(result, expected);
			case _: true;
		};
	}

	/**
	 * Whether no value of the type `a` unifies with the type `b`, nor one of `b` with `a`: each is a class, an interface or
	 * an enum the builds typed (`nominalId`), and neither is the other or a subtype of it.
	 */
	private function unrelated(a: FactsType, b: FactsType): Bool {
		final x: Null<String> = nominalId(a);
		final y: Null<String> = nominalId(b);
		if (x == null || y == null || x == y) return false;
		final table: CompilerFacts = _view.table;
		return !table.subtypesOf(x).contains(y) && !table.subtypesOf(y).contains(x);
	}

	/**
	 * The id of the class, interface or enum every build typed the type `t` as, read through `Null<T>` and typedefs
	 * (`aliased`); null for any other type.
	 */
	private function nominalId(t: FactsType): Null<String> {
		return switch aliased(t) {
			case Named(id, _):
				final fact: Null<TypeFact> = _view.table.type(id);
				fact != null && fact.alike && NOMINAL_KINDS.contains(fact.kind) ? id : null;
			case _: null;
		};
	}

	/** `t` read through `Null<T>` and through typedefs of one target each, `MAX_ALIASES` deep at most. */
	private function aliased(t: FactsType): FactsType {
		var current: FactsType = t;
		for (_ in 0...MAX_ALIASES) {
			final next: Null<FactsType> = switch current {
				case Named(NULLABLE, [inner]): inner;
				case Named(id, _):
					final fact: Null<TypeFact> = _view.table.type(id);
					fact != null && fact.kind == TYPEDEF_KIND && fact.targets.length == 1 ? FactsTypeTree.read(fact.targets[0]) : null;
				case _: null;
			};
			if (next == null) return current;
			current = next;
		}
		return current;
	}

	/** The function type `t` is, read through `Null<T>` and typedefs (`aliased`); null when it is none, or does not read. */
	private function functionOf(t: Null<FactsType>): Null<FactsType> {
		if (t == null) return null;
		final read: FactsType = aliased(t);
		return read.match(Function(_, _)) ? read : null;
	}

	/** How many arguments the function type `text` takes, read through `functionOf`; null for no function type. */
	private function arity(text: String): Null<Int> {
		return switch functionOf(FactsTypeTree.read(text)) {
			case Function(args, _): args.length;
			case _: null;
		};
	}

	/** Whether `t` is the result type of a function that returns nothing. */
	private function isVoid(t: FactsType): Bool {
		return aliased(t).match(Named(VOID, []));
	}

}

/** A file's text and its tree (`FunctionValueTypes.parsed`). */
private typedef ParsedFile = {
	final source: String;
	final tree: QueryNode;
}
