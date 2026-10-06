package anyparse.query;

import anyparse.check.FactsTypeText;
import anyparse.check.FactsTypeTree;
import anyparse.check.FactsTypeTree.FactsType;
import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FieldDeclFact;
import anyparse.query.CompilerFacts.FieldFact;
import anyparse.query.CompilerFacts.ReflectionFact;
import anyparse.query.CompilerFacts.TypeFact;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * The code a null guard of a parameter keeps from running, read off the compiler's facts under the truth
 * (`FactsView.truth`): the branch an `if (p != null)` takes — one whose condition is such a test, or an `&&` holding one —
 * and the `else` of an `if (p == null)` never run when `p` holds null in every run of its function (`nullOnly`).
 *
 * A parameter holds null in every run of a static method when nothing replaces what a call hands it (`FactNode.keptParams`:
 * no assignment, no default value; no target code names it) and every way the method is invoked hands it the literal
 * `null`. Its invocations are exactly the typed calls of it (`CallFact`, `FStatic`) — each must hand `null` there, read off
 * the call's text at its own range — when nothing else may run it: no read by a name off a value of no type, or by
 * reflection (`FactsMethodValues.obtainedUntyped`), no target code naming it, no `@:expose`, and every read of it as a
 * value goes where no code ever calls it (`neverCalled`). A positive whitelist, followed through the text of the code the
 * value reaches: a function value read as an argument of a typed call of a method the builds compiled (each override of
 * an instance one too) is that method's parameter, which holds it for the run (`keptParams`); each read of that parameter,
 * outside every function nested in the method, must be an argument of such a call in turn, or the value an assignment
 * statement stores into a static variable no code reads but by a comparison (`fieldSealed`) or into an element of a static
 * `Array` or `Map` whose every write builds the container right there and whose every read is a comparison or the receiver
 * of such a store (`containerSealed`) — a value stored there is never read again, so never called. Any other use — a
 * capture, a return, a store elsewhere, an argument of a call of a value, of an extern or of an inlined method, a body a
 * macro expanded into — keeps the method's invocations unknown, and the guard decides nothing.
 */
@:nullSafety(Strict)
final class NullGuardedCode {

	/** The field accesses of a typed call of a method a parameter of whose holds what the call hands it (`CallFact.access`). */
	private static final FORWARDING: Array<String> = ['FStatic', 'FInstance'];

	/** The access of a typed call of a static method (`CallFact.access`). */
	private static inline final STATIC_ACCESS: String = 'FStatic';

	/** The use of a field read that only compares the value (`FieldFact.use`). */
	private static inline final COMPARE: String = 'compare';

	/** The use of a field read whose value goes on (`FieldFact.use`): a method's value. */
	private static inline final VALUE: String = 'value';

	/** The kind of a typed class (`TypeFact.kind`) and of a method's node (`FactNode.kind`). */
	private static inline final CLASS_KIND: String = 'class';

	private static inline final METHOD_KIND: String = 'method';

	/** The reflective members that write a member by its name: a value they store replaces the one it held. */
	private static final WRITERS: Array<String> = ['Reflect.setField', 'Reflect.setProperty'];

	/** The kinds of a typed type a test of whose values against null is the language's own (`builtinEquality`). */
	private static final NOMINAL_KINDS: Array<String> = ['class', 'interface', 'enum'];

	/** The nullable wrapper: a value of it is one of its argument's, or null. */
	private static inline final NULLABLE: String = 'Null';

	/** The type of a class as a value, and of an abstract as one: their statics. */
	private static inline final CLASS_VALUE: String = 'Class';

	private static inline final ABSTRACT_VALUE: String = 'Abstract';

	/** The catch-all type. */
	private static inline final CATCH_ALL: String = 'Dynamic';

	/** What the facts spell a type the compiler left unbound with: no operator of any type applies to it. */
	private static inline final UNBOUND: String = '?';

	/** The kind of a typed typedef (`TypeFact.kind`). */
	private static inline final TYPEDEF_KIND: String = 'typedef';

	/** The metadata making a field callable by code outside the program. */
	private static inline final EXPOSE: String = ':expose';

	/** The containers whose element store holds the value stored and calls nothing (`containerSealed`), by typed id. */
	private static final CONTAINERS: Array<String> = ['Array', 'haxe.ds.Map'];

	/** A variable no accessor runs a body for: each of its read and write accesses (`FieldDeclFact.kinds`). */
	private static final PLAIN_VARIABLE: EReg = ~/^var\((default|null|never|ctor),(default|null|never|ctor)\)$/;

	/** A word of target code. */
	private static final WORD: EReg = ~/[A-Za-z_][A-Za-z0-9_]*/g;

	/** The prefix a target gives a Haxe name it cannot spell as it is: the name stands behind it. */
	private static inline final MANGLED: String = '_hx_';

	/** How many calls a function value is followed through before its uses count as unknown. */
	private static inline final MAX_DEPTH: Int = 8;

	/** How many typedefs a container's type is read through. */
	private static inline final MAX_ALIASES: Int = 8;

	private final _view: FactsView;
	private final _scope: ReachProject;
	private final _shape: RefShape;

	/** The types whose instances may have escaped, by typed id (`ValueEscapes.escapedIds`), or null for any. */
	private final _escapedTypes: () -> Null<Array<String>>;

	/** The types a value of a type parameter may have (`ValueEscapes.parameterBindings`), or null when not known. */
	private final _bindings: (path:String) -> Null<Array<FactsType>>;

	/** Which methods the program may obtain as values (`FactsMethodValues`). */
	private final _methods: () -> FactsMethodValues;

	/** Graph file -> the ranges of its text no run reaches (`deadSpans`). */
	private final _dead: Map<String, Array<Span>> = [];

	/** `node id:index` -> whether that parameter holds null in every run (`nullOnly`). */
	private final _nullOnly: Map<String, Bool> = [];

	/** `hypothesis|owner.field:element` -> whether a value stored into it, or into an element of it, is never read again. */
	private final _sealed: Map<String, Bool> = [];

	/** A table key -> its text and tree, or null when it does not read. */
	private final _parsed: Map<String, Null<ParsedText>> = [];

	/** The facts read once (`gathered`): calls by target, field accesses by `owner.field`, the words of all target code. */
	private var _index: Null<FactsIndex> = null;

	/** The parameter whose holding null in every run is being asked (`nullOnly`), as `keyOf` spells it; null between questions. */
	private var _assumed: Null<String> = null;

	/** A table key -> the branches of its text a null guard decides (`guardedBranches`), read once. */
	private final _branches: Map<String, Array<{ param: MemberParam, branch: Span }>> = [];

	public function new(
		view: FactsView, scope: ReachProject, escapedTypes: () -> Null<Array<String>>, bindings: (path:String) -> Null<Array<FactsType>>,
		methods: () -> FactsMethodValues
	) {
		_view = view;
		_scope = scope;
		_shape = scope.shape;
		_escapedTypes = escapedTypes;
		_bindings = bindings;
		_methods = methods;
	}

	/** Whether code at `span` of the graph file `file`, whose tree is `tree`, lies in a branch a null guard keeps from running. */
	public function dead(file: String, tree: Null<QueryNode>, span: Null<Span>): Bool {
		if (span == null || tree == null) return false;
		var spans: Null<Array<Span>> = _dead[file];
		if (spans == null) {
			spans = [for (g in guardedBranches(tree)) if (nullOnly(g.param)) g.branch];
			_dead[file] = spans;
		}
		return spans.exists(d -> span.from >= d.from && span.to <= d.to);
	}

	/**
	 * The branches of `tree` a null guard of a member method's parameter decides: the taken branch of a test that it is not
	 * null — `p != null`, alone or in an `&&` — and the `else` of `p == null`, each with the parameter.
	 */
	private function guardedBranches(tree: QueryNode): Array<{ param: MemberParam, branch: Span }> {
		final out: Array<{ param: MemberParam, branch: Span }> = [];
		final branches: Array<String> = _shape.branchConditionKinds ?? [];
		final guards: Array<{ node: QueryNode, ident: QueryNode, branch: Int }> = [];
		function walk(node: QueryNode): Void {
			if (branches.contains(node.kind) && node.children.length > 1) {
				final condition: QueryNode = unwrap(node.children[0]);
				final tested: Null<QueryNode> = testedNotNull(condition);
				if (tested != null) guards.push({ node: node, ident: tested, branch: 1 });
				final equal: Null<QueryNode> = comparedWithNull(condition, _shape.eqKind);
				if (equal != null && node.children.length > 2) guards.push({ node: node, ident: equal, branch: 2 });
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		if (guards.length == 0) return out;
		final params: Map<QueryNode, MemberParam> = memberParams(tree);
		for (g in guards) {
			final at: Null<Span> = g.ident.span;
			final name: Null<String> = g.ident.name;
			final branch: Null<Span> = g.node.children[g.branch].span;
			if (at == null || name == null || branch == null) continue;
			final hit: Null<RefHit> = Refs.find(name, tree, _shape)
				.find(h -> h.kind == Read && h.span.from == at.from && h.span.to == at.to);
			final declared: Null<QueryNode> = hit?.bindingNode;
			final param: Null<MemberParam> = declared == null ? null : params.get(declared);
			if (param != null) out.push({ param: param, branch: branch });
		}
		return out;
	}

	/** The identifier `condition` tests is not null, alone or as an operand of an `&&`, or null. */
	private function testedNotNull(condition: QueryNode): Null<QueryNode> {
		final direct: Null<QueryNode> = comparedWithNull(condition, _shape.notEqKind);
		if (direct != null || condition.kind != _shape.logicalAndKind) return direct;
		for (c in condition.children) {
			final inner: Null<QueryNode> = testedNotNull(unwrap(c));
			if (inner != null) return inner;
		}
		return null;
	}

	/** The identifier `condition`, a comparison of the kind `kind`, compares with the null literal, or null. */
	private function comparedWithNull(condition: QueryNode, kind: Null<String>): Null<QueryNode> {
		if (kind == null || condition.kind != kind || condition.children.length != 2) return null;
		final a: QueryNode = unwrap(condition.children[0]);
		final b: QueryNode = unwrap(condition.children[1]);
		if (b.kind == _shape.nullLiteralKind && a.kind == _shape.identKind) return a;
		if (a.kind == _shape.nullLiteralKind && b.kind == _shape.identKind) return b;
		return null;
	}

	/**
	 * Every parameter node of a member method of `tree` — a function of a type no function encloses — with its method's
	 * name, its type's simple name, its position and the count of the method's parameters.
	 */
	private function memberParams(tree: QueryNode): Map<QueryNode, MemberParam> {
		final out: Map<QueryNode, MemberParam> = [];
		final functions: Array<String> = (_shape.functionKinds ?? []).concat(_shape.lambdaKinds ?? []);
		final kinds: Array<String> = _shape.paramKinds ?? [];
		function walk(node: QueryNode, nested: Bool): Void {
			final isFunction: Bool = functions.contains(node.kind);
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (isFunction && !nested && name != null && span != null && (_shape.functionKinds ?? []).contains(node.kind)) {
				final type: Null<String> = MemberTouchScan.typeAt(tree, span.from);
				final own: Array<QueryNode> = [for (c in node.children) if (kinds.contains(c.kind)) c];
				final method: String = name;
				if (type != null) {
					final typeName: String = type;
					for (i => p in own) out.set(p, {
						type: typeName,
						method: method,
						index: i,
						count: own.length
					});
				}
			}
			for (c in node.children) walk(c, nested || isFunction);
		}
		walk(tree, false);
		return out;
	}

	/**
	 * Whether the parameter `param` holds null in every run of its method, a static one of the one typed type its type's
	 * name stands for (see the type doc). Asked under the hypothesis that it does (`_assumed`): a fact the hypothesis keeps
	 * from running — code its own guards decide — is no way to invoke the method, since no run before a first one handed it
	 * another value runs that code. Read once per parameter.
	 */
	private function nullOnly(param: MemberParam): Bool {
		final key: Null<String> = keyOf(param);
		if (key == null || _assumed != null) return false;
		final held: Null<Bool> = _nullOnly[key];
		if (held != null) return held;
		_assumed = key;
		final answer: Bool = staticInvocations(key.substr(0, key.lastIndexOf('.')), param.method, param.index, param.count);
		_assumed = null;
		_nullOnly[key] = answer;
		return answer;
	}

	/** The facts node id of the method declaring `param` and its position, `<id>:<index>`, or null when the type's name is ambiguous. */
	private function keyOf(param: MemberParam): Null<String> {
		final typed: Array<String> = _view.bySimpleName()[param.type] ?? [];
		return typed.length == 1 ? '${typed[0]}.${param.method}:${param.index}' : null;
	}

	/**
	 * Whether the static method `name` of the class `owner` is invoked only by typed calls handing its `index`-th of `count`
	 * parameters the literal `null`, which nothing replaces (see the type doc).
	 */
	private function staticInvocations(owner: String, name: String, index: Int, count: Int): Bool {
		final table: CompilerFacts = _view.table;
		final id: String = '$owner.$name';
		final node: Null<FactNode> = table.node(id);
		final fact: Null<TypeFact> = table.type(owner);
		final field: Null<FieldDeclFact> = fact?.fields.find(f -> f.name == name);
		if (node == null || fact == null || field == null || !field.isStatic || !node.keptParams.contains(index)) return false;
		if (!callable(fact, field) || node.params.length != count || node.variants.exists(v -> v.params.length != count)) return false;
		final param: String = node.params[index].name;
		// a test against null is the language's own only for a value of no abstract, which may define its own `!=`
		final types: Array<String> = [node.params[index].type].concat([for (v in node.variants) v.params[index].type]);
		if (!types.foreach(t -> FactsTypeText.unwrapNull(t) == UNBOUND || builtinEquality(FactsTypeTree.read(t), 0))) return false;
		if (namedByTargetCode(name) || namesInNode(node, param)) return false;
		final hierarchy: Array<String> = [owner].concat(table.subtypesOf(owner));
		if (_methods().obtainedUntyped(name, hierarchy, _escapedTypes(), _bindings, true)) return false;
		final facts: FactsIndex = gathered();
		for (call in facts.calls[id] ?? []) if (call.access != STATIC_ACCESS || !handsNull(call.at, index, count)) return false;
		for (read in facts.fields['$owner.$name'] ?? []) {
			if (read.fact.write || read.fact.use == COMPARE) continue;
			if (read.fact.use != VALUE || read.fact.held || !neverCalled(read.node, read.fact.at, 0)) return false;
		}
		return true;
	}

	/**
	 * Whether a method of a class the builds declare alike may run only as its code reads: a method every build declares so,
	 * with one signature, not exposed to code outside the program, of a class that is not extern.
	 */
	private function callable(type: TypeFact, field: FieldDeclFact): Bool {
		return type.kind == CLASS_KIND && type.alike && !type.isExtern && field.kinds.foreach(k -> k == METHOD_KIND)
			&& !field.overloads.exists(o -> o > 0) && !field.meta.contains(EXPOSE) && !type.meta.contains(EXPOSE);
	}

	/** Whether the call at `at` hands the literal `null` as its `index`-th of `count` arguments, read off its text. */
	private function handsNull(at: FactPos, index: Int, count: Int): Bool {
		final read: Null<ParsedText> = parsed(at.file);
		final call: Null<QueryNode> = read == null ? null : exactly(read.tree, at.span, _shape.callKind);
		return call != null && call.children.length == count + 1 && unwrap(call.children[index + 1]).kind == _shape.nullLiteralKind;
	}

	/**
	 * Whether the function value the code of `node` reads at `at` is never called (see the type doc): it is an argument of a
	 * typed call of a method the builds compiled, whose parameter it becomes in every method that call may run, and no use
	 * of that parameter calls it.
	 */
	private function neverCalled(node: FactNode, at: FactPos, depth: Int): Bool {
		if (depth > MAX_DEPTH) return false;
		final read: Null<ParsedText> = parsed(at.file);
		if (read == null) return false;
		final chain: Null<Array<QueryNode>> = ancestors(read.tree, at.span);
		final argument: Null<{ call: QueryNode, index: Int }> = chain == null ? null : argumentOf(chain);
		final callSpan: Null<Span> = argument?.call.span;
		if (argument == null || callSpan == null) return false;
		final call: Null<CallFact> = node.calls.find(c ->
			c.at.file == at.file && c.at.span.from == callSpan.from && c.at.span.to == callSpan.to
		);
		final target: Null<String> = call?.target;
		if (call == null || target == null || !FORWARDING.contains(call.access)) return false;
		final dot: Int = target.lastIndexOf('.');
		final owner: String = target.substr(0, dot);
		final name: String = target.substr(dot + 1);
		final table: CompilerFacts = _view.table;
		final declaring: Null<TypeFact> = table.type(owner);
		final field: Null<FieldDeclFact> = declaring?.fields.find(f -> f.name == name);
		if (declaring == null || field == null) return false;
		if (!callable(declaring, field)) return false;
		final count: Int = argument.call.children.length - 1;
		// a dispatch on an instance may run each override of the method
		final runs: Array<String> = [owner];
		if (call.access != STATIC_ACCESS) for (sub in table.subtypesOf(owner)) {
			final declared: Null<TypeFact> = table.type(sub);
			final own: Null<FieldDeclFact> = declared?.fields.find(f -> f.name == name && !f.isStatic);
			if (declared == null || own == null) continue;
			if (!callable(declared, own)) return false;
			runs.push(sub);
		}
		for (o in runs) if (!parameterNeverCalls('$o.$name', argument.index, count, depth + 1)) return false;
		return true;
	}

	/**
	 * Whether the `index`-th of the `count` parameters of the method whose facts node is `id` holds what its calls hand it
	 * for the whole run, and no read of it calls it (see the type doc).
	 */
	private function parameterNeverCalls(id: String, index: Int, count: Int, depth: Int): Bool {
		final node: Null<FactNode> = _view.table.node(id);
		if (node == null || node.kind != METHOD_KIND || node.params.length != count || !node.keptParams.contains(index)) return false;
		if (node.variants.exists(v -> v.params.length != count) || FactMarkers.carries(node, m -> !m.match(InlineSite))) return false;
		final name: String = node.params[index].name;
		if (namesInNode(node, name)) return false;
		final read: Null<ParsedText> = parsed(node.at.file);
		if (read == null) return false;
		final fn: Null<QueryNode> = enclosingFunction(read.tree, node.at.span);
		final fnSpan: Null<Span> = fn?.span;
		if (fn == null || fnSpan == null) return false;
		final params: Array<QueryNode> = [for (c in fn.children) if ((_shape.paramKinds ?? []).contains(c.kind)) c];
		if (params.length != count || params[index].name != name) return false;
		final binding: QueryNode = params[index];
		final functions: Array<String> = (_shape.functionKinds ?? []).concat(_shape.lambdaKinds ?? []);
		for (hit in Refs.find(name, read.tree, _shape)) if (hit.bindingNode == binding && hit.kind != Decl) {
			if (hit.kind != Read) return false;
			final chain: Null<Array<QueryNode>> = ancestors(read.tree, hit.span);
			if (chain == null) return false;
			// a read from a function nested in the method captures the value
			final inner: Array<QueryNode> = chain.slice(chain.indexOf(fn) + 1);
			if (!chain.contains(fn) || inner.exists(a -> functions.contains(a.kind))) return false;
			if (!storedNowhereRead(node, read.tree, chain, { file: node.at.file, span: hit.span }, depth)) return false;
		}
		return true;
	}

	/**
	 * Whether the value the read at `at` — the last of `chain`, its ancestors in `tree` — yields is never called: the value an
	 * assignment statement stores into a sealed static variable or an element of a sealed static container, or an argument
	 * a call hands on to a method none of whose runs calls it (`neverCalled`).
	 */
	private function storedNowhereRead(node: FactNode, tree: QueryNode, chain: Array<QueryNode>, at: FactPos, depth: Int): Bool {
		final i: Int = outermostParen(chain, chain.length - 1);
		final parent: Null<QueryNode> = i > 0 ? chain[i - 1] : null;
		if (parent == null) return false;
		if (parent.kind == _shape.callKind) return neverCalled(node, at, depth);
		final statement: Null<QueryNode> = i > 1 ? chain[i - 2] : null;
		if (parent.kind != _shape.assignKind || parent.children.length != 2 || parent.children[1] != chain[i]) return false;
		if (statement == null || statement.kind != _shape.exprStatementKind) return false;
		final place: QueryNode = unwrap(parent.children[0]);
		final element: Bool = place.kind == _shape.indexAccessKind && place.children.length == 2;
		final holder: QueryNode = element ? unwrap(place.children[0]) : place;
		final span: Null<Span> = holder.span;
		if (span == null) return false;
		final accessed: Null<FieldFact> = node.fields.find(
			f -> f.at.file == at.file && f.at.span.from == span.from && f.at.span.to == span.to && f.write != element
		);
		final owner: Null<String> = accessed?.owner;
		if (accessed == null || owner == null || accessed.access != STATIC_ACCESS) return false;
		return sealed(owner, accessed.field, element);
	}

	/**
	 * Whether a value stored into the static variable `field` of `owner` — into an element of the container it holds, when
	 * `element` — is never read again (see the type doc). Read once per variable, kind and hypothesis.
	 */
	private function sealed(owner: String, field: String, element: Bool): Bool {
		// read under the hypothesis asked (`assumedDead`): another question may not reuse it
		final key: String = '${_assumed ?? ''}|$owner.$field:$element';
		final held: Null<Bool> = _sealed[key];
		if (held != null) return held;
		_sealed[key] = false;
		final answer: Bool = element ? containerSealed(owner, field) : fieldSealed(owner, field);
		_sealed[key] = answer;
		return answer;
	}

	/** Whether the static variable `field` of `owner` is a plain variable no code reads but by a comparison. */
	private function fieldSealed(owner: String, field: String): Bool {
		if (!plainStatic(owner, field)) return false;
		return (gathered().fields['$owner.$field'] ?? []).foreach(a -> a.fact.write || a.fact.use == COMPARE);
	}

	/**
	 * Whether the static variable `field` of `owner` holds an `Array` or a `Map` only it holds — every write builds it right
	 * there (`FieldFact.fresh`) — and every read of it is a comparison or the receiver of an element store statement.
	 */
	private function containerSealed(owner: String, field: String): Bool {
		if (!plainStatic(owner, field)) return false;
		final declared: Null<FieldDeclFact> = _view.table.type(owner)?.fields.find(f -> f.name == field);
		if (declared == null || !declared.types.foreach(t -> container(t))) return false;
		for (a in gathered().fields['$owner.$field'] ?? []) {
			if (a.fact.write ? !a.fact.fresh : a.fact.use != COMPARE && !elementStoreReceiver(a.fact.at)) return false;
		}
		return true;
	}

	/**
	 * Whether the static `field` of the class `owner` is a variable no accessor runs code for, whose value no call reads,
	 * read by no name off a value of no type or by reflection, and named by no target code.
	 */
	private function plainStatic(owner: String, field: String): Bool {
		final type: Null<TypeFact> = _view.table.type(owner);
		final declared: Null<FieldDeclFact> = type?.fields.find(f -> f.name == field);
		if (type == null || declared == null) return false;
		if (type.kind != CLASS_KIND || !type.alike || type.isExtern || !declared.isStatic) return false;
		if (!declared.kinds.foreach(k -> PLAIN_VARIABLE.match(k)) || namedByTargetCode(field)) return false;
		// a call of the value it holds reads it too
		if (gathered().calls.exists('$owner.$field')) return false;
		final hierarchy: Array<String> = [owner].concat(_view.table.subtypesOf(owner));
		return !reachedByName(field, hierarchy);
	}

	/**
	 * Whether code may read or replace the static `field` of a class `hierarchy` names by a name, off a value of no class
	 * or by reflection, naming it or computing the name: an access by name off a value that may be such a class as a value
	 * (`holdsClassValue`), any reflection but one that reads no member's value and writes none
	 * (`FactsMethodValues.memberless`, `WRITERS` aside), or one any read may obtain (`FactsMethodValues.unknownReason`).
	 * The code the parameter asked about keeps from running (`assumedDead`) runs none.
	 */
	private function reachedByName(field: String, hierarchy: Array<String>): Bool {
		final methods: FactsMethodValues = _methods();
		if (methods.unknownReason() != null) return true;
		final escaped: Null<Array<String>> = _escapedTypes();
		final facts: FactsIndex = gathered();
		final table: CompilerFacts = _view.table;
		for (a in facts.byName[field] ?? []) {
			if (!assumedDead(a.at) && holdsClassValue(a.receiver, hierarchy, escaped)) return true;
		}
		for (r in facts.reflection) {
			if (FactsMethodValues.memberless(table, r.target) && !WRITERS.contains(r.target)) continue;
			// the member the literal at the call's NAME argument names; null — a computed name, or a call naming no member — is any
			final named: Null<String> = r.memberName;
			if ((named != null && named != field) || assumedDead(r.at)) continue;
			if (r.isValue || holdsClassValue(r.receiver, hierarchy, escaped)) return true;
		}
		return false;
	}

	/**
	 * Whether a value of the facts type `type` may be a class `hierarchy` names as a value: one of them, or a class whose
	 * value it may be the type of — `Class<C>` / `Abstract<C>` of one of them, of a subtype of one, of a type the builds do not
	 * type as a class, or of no named type — or, of any other type, an escaped one (`escaped`). A class value reaches a place
	 * of another type only by a flow the escapes count (`FactsEscapes`: into a catch-all, a type parameter, a structure, an
	 * abstract, an unknown), so a place no class value types holds an escaped one alone. A type that does not read, and
	 * escapes that are not known, may hold any.
	 */
	private function holdsClassValue(type: Null<String>, hierarchy: Array<String>, escaped: Null<Array<String>>): Bool {
		if (escaped == null || escaped.exists(e -> hierarchy.contains(e))) return true;
		final read: Null<FactsType> = type == null ? null : FactsTypeTree.read(type);
		if (read == null) return true;
		final table: CompilerFacts = _view.table;
		return switch unwrapNullable(read) {
			case Named(CLASS_VALUE | ABSTRACT_VALUE, [Named(id, _)]):
				hierarchy.contains(id) || table.type(id)?.kind != CLASS_KIND || table.subtypesOf(id).exists(s -> hierarchy.contains(s));
			case Named(CLASS_VALUE | ABSTRACT_VALUE, _): true;
			case _: false;
		};
	}

	/** `t` seen through `Null<T>`. */
	private static function unwrapNullable(t: FactsType): FactsType {
		var current: FactsType = t;
		while (true) switch current {
			case Named(NULLABLE, [inner]):
				current = inner;
			case _:
				return current;
		}
	}

	/**
	 * Whether the code at `at` lies in a branch a guard of the parameter asked about decides (`_assumed`): code no run before
	 * a first one handed the parameter another value runs.
	 */
	private function assumedDead(at: FactPos): Bool {
		final assumed: Null<String> = _assumed;
		if (assumed == null) return false;
		var branches: Null<Array<{ param: MemberParam, branch: Span }>> = _branches[at.file];
		if (branches == null) {
			final read: Null<ParsedText> = parsed(at.file);
			branches = read == null ? [] : guardedBranches(read.tree);
			_branches[at.file] = branches;
		}
		return branches.exists(b -> keyOf(b.param) == assumed && at.span.from >= b.branch.from && at.span.to <= b.branch.to);
	}

	/**
	 * Whether a test of a value of the type `t` against null is the language's own: the type is a class, an interface or an
	 * enum the builds declare alike, the catch-all, a structure or a function type — read through `Null<T>` and typedefs —
	 * and no abstract, whose `!=` may be its own operator.
	 */
	private function builtinEquality(t: Null<FactsType>, depth: Int): Bool {
		if (t == null || depth > MAX_ALIASES) return false;
		return switch t {
			case Named(NULLABLE, [inner]): builtinEquality(inner, depth + 1);
			case Named(CATCH_ALL, []) | Structure(_) | Function(_, _): true;
			case Named(id, _):
				final fact: Null<TypeFact> = _view.table.type(id);
				fact != null && fact.alike
					&& (NOMINAL_KINDS.contains(fact.kind) || fact.kind == TYPEDEF_KIND && fact.targets.length > 0
						&& fact.targets.foreach(target -> builtinEquality(FactsTypeTree.read(target), depth + 1)));
			case _: false;
		};
	}

	/** Whether the facts type `text`, read through typedefs of one target, is an `Array` or a `Map` (`CONTAINERS`). */
	private function container(text: String): Bool {
		var current: Null<FactsType> = FactsTypeTree.read(text);
		for (_ in 0...MAX_ALIASES) switch current {
			case Named(id, _) if (CONTAINERS.contains(id)):
				return true;
			case Named(id, _):
				final fact: Null<TypeFact> = _view.table.type(id);
				if (fact == null || fact.kind != TYPEDEF_KIND || fact.targets.length != 1) return false;
				current = FactsTypeTree.read(fact.targets[0]);
			case _:
				return false;
		}
		return false;
	}

	/** Whether the read at `at` is the container of an element store statement: `x[k] = v;`, read off its text. */
	private function elementStoreReceiver(at: FactPos): Bool {
		final read: Null<ParsedText> = parsed(at.file);
		final chain: Null<Array<QueryNode>> = read == null ? null : ancestors(read.tree, at.span);
		if (chain == null) return false;
		final i: Int = outermostParen(chain, chain.length - 1);
		if (i < 3) return false;
		final place: QueryNode = chain[i - 1];
		final assign: QueryNode = chain[i - 2];
		return place.kind == _shape.indexAccessKind && place.children[0] == chain[i] && assign.kind == _shape.assignKind
			&& assign.children[0] == place && chain[i - 3].kind == _shape.exprStatementKind;
	}

	/**
	 * The call `chain` — the ancestors of a read, itself last — hands the read to as an argument, and its position among the
	 * arguments; null when it is none, or is the call's callee.
	 */
	private function argumentOf(chain: Array<QueryNode>): Null<{ call: QueryNode, index: Int }> {
		final i: Int = outermostParen(chain, chain.length - 1);
		if (i < 1) return null;
		final call: QueryNode = chain[i - 1];
		final position: Int = call.children.indexOf(chain[i]);
		return call.kind != _shape.callKind || position < 1 ? null : { call: call, index: position - 1 };
	}

	/** The index in `chain` of the outermost parenthesis holding `chain[i]` directly, or `i`. */
	private function outermostParen(chain: Array<QueryNode>, i: Int): Int {
		var at: Int = i;
		while (at > 0 && chain[at - 1].kind == _shape.parenKind && chain[at - 1].children.length == 1) at--;
		return at;
	}

	/** Whether target code inside the node `node` or a function nested in it names `name`, or its text is computed. */
	private function namesInNode(node: FactNode, name: String): Bool {
		final pending: Array<String> = [node.id];
		while (pending.length > 0) {
			final next: Null<FactNode> = _view.table.node(pending.pop() ?? '');
			if (next == null) return true;
			for (x in next.natives) if (x.computed || wordsOf(x.code ?? '').contains(name)) return true;
			for (f in next.fns) pending.push(f);
		}
		return false;
	}

	/** Whether some target code of the builds — a native call's, a metadata's — names `name`, or is of a computed text. */
	private function namedByTargetCode(name: String): Bool {
		final facts: FactsIndex = gathered();
		return facts.computedTargetCode || facts.targetWords.exists(name);
	}

	/** The words of the target code `code`, a name a target mangled (`MANGLED`) standing for the name behind it too. */
	private static function wordsOf(code: String): Array<String> {
		final out: Array<String> = [];
		var at: Int = 0;
		while (WORD.matchSub(code, at)) {
			final word: String = WORD.matched(0);
			out.push(word);
			if (StringTools.startsWith(word, MANGLED)) out.push(word.substr(MANGLED.length));
			final pos: { pos: Int, len: Int } = WORD.matchedPos();
			at = pos.pos + pos.len;
		}
		return out;
	}

	/** The facts the questions read, gathered once over every node and type the builds typed. */
	private function gathered(): FactsIndex {
		final held: Null<FactsIndex> = _index;
		if (held != null) return held;
		final out: FactsIndex = {
			calls: [],
			fields: [],
			byName: [],
			reflection: [],
			targetWords: [],
			computedTargetCode: false
		};
		_index = out;
		final table: CompilerFacts = _view.table;
		function words(code: Null<String>): Void {
			if (code == null) {
				out.computedTargetCode = true;
				return;
			}
			for (w in wordsOf(code)) out.targetWords[w] = true;
		}
		for (id in table.nodeIds()) {
			final n: Null<FactNode> = table.node(id);
			if (n == null) {
				out.computedTargetCode = true;
				continue;
			}
			for (c in n.calls) {
				final target: Null<String> = c.target;
				if (target == null) continue;
				final list: Array<CallFact> = out.calls[target] ?? [];
				list.push(c);
				out.calls[target] = list;
			}
			for (r in n.reflection) out.reflection.push(r);
			for (f in n.fields) {
				final owner: Null<String> = f.owner;
				if (owner == null) {
					final list: Array<FieldFact> = out.byName[f.field] ?? [];
					list.push(f);
					out.byName[f.field] = list;
					continue;
				}
				final key: String = '$owner.${f.field}';
				final list: Array<{ node: FactNode, fact: FieldFact }> = out.fields[key] ?? [];
				list.push({ node: n, fact: f });
				out.fields[key] = list;
			}
			for (x in n.natives) {
				// a site whose text is no literal names its own identifier, and what it is handed
				if (x.computed)
					out.computedTargetCode = true
				else
					words(x.code ?? x.name);
			}
		}
		for (id in table.typeIds()) {
			final t: Null<TypeFact> = table.type(id);
			if (t == null) continue;
			for (c in t.code) words(c);
			for (f in t.fields) for (c in f.code) words(c);
		}
		return out;
	}

	/** The function node of `tree` of a function-declaration kind whose range holds `span`, innermost. */
	private function enclosingFunction(tree: QueryNode, span: Span): Null<QueryNode> {
		final kinds: Array<String> = _shape.functionKinds ?? [];
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			final s: Null<Span> = node.span;
			if (s != null && (span.from < s.from || span.to > s.to)) return;
			if (s != null && kinds.contains(node.kind)) found = node;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/** The nodes of `tree` from its root down to the one spanning exactly `span`, the deepest such, or null. */
	private static function ancestors(tree: QueryNode, span: Span): Null<Array<QueryNode>> {
		final path: Array<QueryNode> = [];
		var found: Null<Array<QueryNode>> = null;
		function walk(node: QueryNode): Void {
			final s: Null<Span> = node.span;
			if (s != null && (span.from < s.from || span.to > s.to)) return;
			path.push(node);
			if (s != null && s.from == span.from && s.to == span.to) found = path.copy();
			for (c in node.children) walk(c);
			path.pop();
		}
		walk(tree);
		return found;
	}

	/** The node of `tree` of the kind `kind` spanning exactly `span`, or null. */
	private static function exactly(tree: QueryNode, span: Span, kind: Null<String>): Null<QueryNode> {
		final chain: Null<Array<QueryNode>> = ancestors(tree, span);
		if (chain == null) return null;
		for (i in 0...chain.length) {
			final n: QueryNode = chain[chain.length - 1 - i];
			final s: Null<Span> = n.span;
			if (s == null || s.from != span.from || s.to != span.to) return null;
			if (n.kind == kind) return n;
		}
		return null;
	}

	/** `node` seen through parentheses. */
	private function unwrap(node: QueryNode): QueryNode {
		return BoolExprShape.unwrapParens(node, _shape.parenKind);
	}

	/** The text the facts of the file keyed `key` were read off and its tree, parsed once; null when it does not read. */
	private function parsed(key: String): Null<ParsedText> {
		if (_parsed.exists(key)) return _parsed[key];
		final source: Null<String> = _view.table.sourceOf(key);
		final tree: Null<QueryNode> = source == null ? null : try _scope.plugin.parseFile(source) catch (exception: Exception) null;
		final read: Null<ParsedText> = source == null || tree == null ? null : { source: source, tree: tree };
		_parsed[key] = read;
		return read;
	}

}

/** A file's text and its tree (`NullGuardedCode.parsed`). */
private typedef ParsedText = {
	final source: String;
	final tree: QueryNode;
}

/** A parameter of a member method: the method's type's simple name and its own, the parameter's position and their count. */
private typedef MemberParam = {
	final type: String;
	final method: String;
	final index: Int;
	final count: Int;
}

/** The facts `NullGuardedCode` reads, gathered once. */
private typedef FactsIndex = {
	final calls: Map<String, Array<CallFact>>;
	final fields: Map<String, Array<{ node: FactNode, fact: FieldFact }>>;

	/** Field name -> the accesses of a field so named off a value no class types (`FieldFact.owner` null). */
	final byName: Map<String, Array<FieldFact>>;

	final reflection: Array<ReflectionFact>;
	final targetWords: Map<String, Bool>;
	var computedTargetCode: Bool;
}
