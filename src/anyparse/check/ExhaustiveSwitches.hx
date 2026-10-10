package anyparse.check;

import anyparse.check.HeldTrees.HeldDecl;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphTypes;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * The catch-all branch (`case _`, `default`) of a `switch` over an `enum abstract` whose every value an earlier guard-free
 * case names: no value reaches it. Only for a run that sees every write of the project (`FieldWrites.complete`), and a
 * positive whitelist on every count:
 * - the subject is a member of the running type read off `this`, or bare where nothing in the function binds its name,
 *   declared as the abstract itself (not `Null<…>`), the abstract the one type of the project of that name;
 * - the abstract is CLOSED: no `from` clause, no build macro, no conditional-compilation region, no constructor; a
 *   function of it with a written return type naming it is the abstract alone and hands back only its values (through
 *   `switch` arms, `?:`, parentheses and blocks), one with no written return type hands back nothing;
 * - the member HOLDS only values (`holdsValues`): through its getter, or through its initializer — with none, the default
 *   `0` of a counting abstract that has a `0` value — and every assignment to a field of its name in the project; a value
 *   is a value constant (never a static field of the abstract), a parameter written as the abstract that every call of
 *   its function hands a value (`callersPassValues`), a member holding only values, or a call converted by a `@:from`
 *   function.
 * The holes the source cannot show are a `cast` into the abstract and a constructor the runtime calls (reflection), taken
 * as absent: the project's word that it builds the abstract's values only through its constants. The default `0` is a
 * TARGET's: a static target (hxcpp, where TM ships) starts an `Int` field at `0`, a dynamic one (JS) at `null`, so on JS
 * an uninitialized member may hold no value at all — `zeroIsValue` is read as the static targets have it.
 */
@:nullSafety(Strict)
final class ExhaustiveSwitches {

	/** A whole decimal or hexadecimal integer literal. */
	private static final INTEGER: EReg = ~/^(?:[0-9]+|0[xX][0-9a-fA-F]+)$/;

	/** Each abstract's name -> what makes it closed (`closedOf`); null when it is not. */
	private final _closed: Map<String, Null<ClosedAbstract>> = [];

	/** `<type>.<member>` -> whether the member holds only values of its abstract (`holdsValues`), judged with nothing assumed. */
	private final _holds: Map<String, Bool> = [];

	/** The members `holdsValues` is judging: each is assumed to hold only values while it is, so nothing judged then is kept. */
	private final _judging: Array<String> = [];

	private final _graph: CallGraph;
	private final _shape: RefShape;
	private final _nestedFnKinds: Array<String>;
	private final _metaKinds: Array<String>;
	private final _typeKinds: Array<String>;

	/** Name -> every write in the run to a bare name or a field so named, with where it sits (`writesTo`), filled per name on first use. */
	private final _writesOf: Map<String, Array<WriteSite>> = [];

	/** The graph's held trees, and the lookups made in them. */
	private final _trees: HeldTrees;

	/** Every write of the run (`FieldWrites`), and whether it is every write of the project. */
	private final _writes: FieldWrites;

	/** Whether code outside the run may call a function of the graph, so what its parameters hold is not the run's to tell. */
	private final _seedable: (String) -> Bool;

	/** `<function id>#<parameter index>` of the parameters `callersPassValues` is judging: each is taken to pass values meanwhile. */
	private final _passing: Array<String> = [];

	public function new(graph: CallGraph, plugin: GrammarPlugin, writes: FieldWrites, seedable: (String) -> Bool) {
		_graph = graph;
		_trees = new HeldTrees(graph);
		_writes = writes;
		_seedable = seedable;
		_shape = plugin.refShape();
		_nestedFnKinds = MemberKinds.nestedFunctionKinds(_shape);
		_metaKinds = plugin.metaShape().metaKinds;
		_typeKinds = _shape.typeAnnotationKinds ?? [];
	}

	/** The type tables of the graph this reads: what a `catch` clause's written type is checked against (`CatchTypes`). */
	public inline function types(): CallGraphTypes {
		return _graph.types;
	}

	/**
	 * Whether `branch`, a branch of the `switch` node `switchNode` in the function node `fn` (graph id `fnId`), is a
	 * catch-all no value reaches: the subject holds only values of a closed enum abstract and the guard-free cases
	 * before it name every value. Never for a run that may miss a write of the project (`FieldWrites.complete`): what a
	 * member holds is read off every write of its name.
	 */
	public function dead(fn: QueryNode, fnId: String, switchNode: QueryNode, branch: QueryNode): Bool {
		final kids: Array<QueryNode> = switchNode.children;
		final at: Int = kids.indexOf(branch);
		if (!_writes.complete || at < 1 || !catchAll(branch)) return false;
		final closed: Null<ClosedAbstract> = subjectAbstract(fn, fnId, kids[0]);
		if (closed == null) return false;
		final named: Array<String> = [];
		// a guarded case runs only where its guard holds: it names no value for sure
		for (k in kids.slice(1, at)) if (k.kind == _shape.caseBranchKind && !guarded(k)) for (v in plainValues(k)) named.push(v);
		return closed.values.foreach(v -> named.contains(v));
	}

	private inline function isAccess(kind: String): Bool {
		return kind == _shape.fieldAccessKind || kind == _shape.nullSafeAccessKind || kind == _shape.forceFieldAccessKind;
	}

	/** Whether `branch` matches whatever is left: a default branch, or a case whose one pattern is `_`. */
	private function catchAll(branch: QueryNode): Bool {
		if (branch.kind == _shape.defaultBranchKind) return true;
		final pattern: Null<QueryNode> = branch.kind == _shape.caseBranchKind && branch.children.length > 0 ? branch.children[0] : null;
		return pattern != null && pattern.kind == _shape.plainCasePatternKind && pattern.children.length == 1
			&& pattern.children[0].kind == _shape.identKind && pattern.children[0].name == '_';
	}

	/** The bare names the patterns of the case `branch` match, its guard-free `Plain` patterns only. */
	private function plainValues(branch: QueryNode): Array<String> {
		return [
			for (p in branch.children) if (
				p.kind == _shape.plainCasePatternKind && p.children.length == 1 && p.children[0].kind == _shape.identKind
			)
				p.children[0].name ?? ''
		];
	}

	/**
	 * The closed abstract the subject `subject` of a `switch` in the function node `fn` (graph id `fnId`) holds only
	 * values of: a member of the running type read off `this`, or bare where nothing in `fn` binds its name, declared
	 * as the abstract itself (`closedOf`) and holding only its values (`holdsValues`). Null otherwise.
	 */
	private function subjectAbstract(fn: QueryNode, fnId: String, subject: QueryNode): Null<ClosedAbstract> {
		final read: QueryNode = subject.kind == _shape.parenKind && subject.children.length == 1 ? subject.children[0] : subject;
		final name: Null<String> = read.name;
		final type: Null<String> = _graph.node(fnId)?.typeName;
		if (name == null || type == null) return null;
		final own: Bool = read.kind == _shape.identKind && BareNames.bindsNothing(fn, name, _shape) || isSelf(read);
		final owner: Null<String> = own ? _graph.types.declaringTypeOf(type, name) : null;
		// a written type naming no enum abstract — `Null<T>` among them — is no closed one (`closedOf`)
		final declared: Null<String> = _graph.types.memberOnChain(type, name)?.typeSource;
		final closed: Null<ClosedAbstract> = owner == null || declared == null ? null : closedOf(declared);
		return closed != null && owner != null && holdsValues(owner, name, closed) ? closed : null;
	}

	/**
	 * The enum abstract named `type` when it is closed (`closedDecl`), and the one type of the project of that name —
	 * two declarations of it leave which one a written `type` names to imports this does not read. Null otherwise.
	 */
	private function closedOf(type: String): Null<ClosedAbstract> {
		if (_closed.exists(type)) return _closed[type];
		final held: Null<HeldDecl> = _graph.types.meta.isBuilt(type) ? null : _trees.typeDecl(type);
		final found: Null<ClosedAbstract> = held == null || held.node.kind != _shape.enumAbstractDeclKind ? null : closedDecl(held, type);
		_closed[type] = found;
		return found;
	}

	/**
	 * The enum abstract `held` (named `type`) as a closed one, when every member of it is one this knows to build no
	 * value but its own (`membersOf`) and every function of it builds nothing else (`buildsNoOther`); null otherwise.
	 */
	private function closedDecl(held: HeldDecl, type: String): Null<ClosedAbstract> {
		final kids: Array<QueryNode> = held.node.children;
		final underlying: Null<String> = kids.length > 0 && _typeKinds.contains(kids[0].kind) ? kids[0].name : null;
		final members: Null<AbstractMembers> = membersOf(kids.slice(underlying == null ? 0 : 1));
		if (members == null || members.values.length == 0) return null;
		final names: Array<String> = [for (v in members.values) v.name ?? ''];
		if (!members.functions.foreach(f -> buildsNoOther(f.fn, type, names))) return null;
		final fromTypes: Array<String> = [];
		for (f in members.functions) {
			final taken: Null<String> = f.from ? fromType(f.fn) : null;
			if (taken != null) fromTypes.push(taken);
		}
		return {
			name: type,
			values: names,
			fromTypes: fromTypes,
			zeroIsValue: underlying != null && countsFromZero(underlying, members.values, held.source)
		};
	}

	/**
	 * The values (its non-static fields) and the functions of the members `kids` of an enum abstract, when
	 * every other one is a modifier, metadata or a static field — whose value no read accepts as one of
	 * the abstract's (`valueExpr` takes a value constant off the abstract's name only). Null for any other
	 * member: a `from` clause, a conditional-compilation region (a value of another build), anything not listed.
	 */
	private function membersOf(kids: Array<QueryNode>): Null<AbstractMembers> {
		final fields: Array<String> = _shape.fieldDeclKinds ?? [];
		final members: AbstractMembers = { values: [], functions: [] };
		var isStatic: Bool = false;
		var isFrom: Bool = false;
		for (k in kids) {
			if ((_shape.modifierKinds ?? []).contains(k.kind) || _metaKinds.contains(k.kind)) {
				isStatic = isStatic || k.kind == _shape.staticModifierKind;
				isFrom = isFrom || _metaKinds.contains(k.kind) && k.name == _shape.execution?.implicitConversionMetaName;
				continue;
			}
			if (fields.contains(k.kind) && !isStatic && k.name != null)
				members.values.push(k)
			else if ((_shape.functionKinds ?? []).contains(k.kind))
				members.functions.push({ fn: k, from: isFrom })
			else if (!fields.contains(k.kind))
				return null;
			isStatic = false;
			isFrom = false;
		}
		return members;
	}

	/**
	 * Whether the function `fn` of the enum abstract `type` (with the values `values`) builds no value of it but those:
	 * never a constructor; a function whose written return type names the abstract is the abstract alone and hands
	 * back only its values (`handsBackValuesOnly`); one whose written return type does not name it builds none; one
	 * with no written return type hands back nothing at all.
	 */
	private function buildsNoOther(fn: QueryNode, type: String, values: Array<String>): Bool {
		if (fn.name == (_shape.constructorName ?? 'new')) return false;
		final declared: Null<QueryNode> = fn.children.find(c -> _typeKinds.contains(c.kind));
		if (declared == null) {
			final returns: Array<QueryNode> = [];
			collectReturns(fn, returns, true);
			return returns.length == 0;
		}
		if (!mentions(declared, type)) return true;
		return declared.name == type && declared.children.length == 0 && handsBackValuesOnly(fn, values);
	}

	/** Whether every `return` of the function `fn`, outside a function nested in it, hands back one of `values`. */
	private function handsBackValuesOnly(fn: QueryNode, values: Array<String>): Bool {
		final returns: Array<QueryNode> = [];
		collectReturns(fn, returns, true);
		return returns.length > 0 && returns.foreach(r -> r.children.length == 1 && valueOnly(r.children[0], values));
	}

	private function collectReturns(node: QueryNode, into: Array<QueryNode>, top: Bool): Void {
		if (!top && (_nestedFnKinds.contains(node.kind) || (_shape.functionKinds ?? []).contains(node.kind))) return;
		if ((_shape.valueReturnKinds ?? []).contains(node.kind)) into.push(node);
		for (c in node.children) collectReturns(c, into, false);
	}

	/** Whether `expr` evaluates to one of `values`: a bare value, or arms of a `switch` / `?:` / block / parentheses that do. */
	private function valueOnly(expr: QueryNode, values: Array<String>): Bool {
		final kids: Array<QueryNode> = expr.kind == _shape.exprStatementKind && expr.children.length == 1 ? expr.children : [expr];
		final e: QueryNode = kids[0];
		if (e.kind == _shape.identKind) return values.contains(e.name ?? '');
		if (e.kind == _shape.parenKind && e.children.length == 1) return valueOnly(e.children[0], values);
		if (e.kind == _shape.ternaryKind && e.children.length == 3)
			return valueOnly(e.children[1], values) && valueOnly(e.children[2], values);
		if ((_shape.switchKinds ?? []).contains(e.kind)) {
			final branches: Array<QueryNode> = [for (b in e.children.slice(1)) b];
			return branches.length > 0
				&& branches.foreach(b -> b.children.length > 0 && valueOnly(b.children[b.children.length - 1], values));
		}
		return false;
	}

	/** Whether the case `branch` carries a guard (`case A if (c):`): the parenthesised expression right after its patterns. */
	private function guarded(branch: QueryNode): Bool {
		final kids: Array<QueryNode> = branch.children;
		var at: Int = 0;
		while (at < kids.length && kids[at].kind == _shape.plainCasePatternKind) at++;
		return at < kids.length && kids[at].kind == _shape.parenKind;
	}

	/** Whether `read` reads a field off `this`. */
	private function isSelf(read: QueryNode): Bool {
		return isAccess(read.kind) && read.children.length == 1 && read.children[0].kind == _shape.identKind
			&& read.children[0].name == _shape.selfReferenceText;
	}

	/** Whether the written type `declared` names `type` anywhere, a type argument included. */
	private function mentions(declared: QueryNode, type: String): Bool {
		return declared.name == type || declared.children.exists(c -> mentions(c, type));
	}

	/** The written type of the first parameter of the function `fn` (`CatchTypes.writtenType`); null when none is rendered. */
	private function fromType(fn: QueryNode): Null<String> {
		final param: Null<QueryNode> = fn.children.find(c -> (_shape.paramKinds ?? []).contains(c.kind));
		final declared: Null<QueryNode> = param?.type;
		return declared == null ? null : CatchTypes.writtenType(declared, _shape);
	}

	/**
	 * Whether a field of the enum abstract over `underlying` that nothing initializes — `0`, the default of a counting
	 * underlying type (`RefShape.enumAbstractImplicitValues`) — is one of its `values`: each value written without an
	 * initializer is the previous one plus one (the first `0`), each other one its integer literal read in `source`.
	 */
	private function countsFromZero(underlying: String, values: Array<QueryNode>, source: String): Bool {
		if (!(_shape.enumAbstractImplicitValues?.counting ?? []).contains(underlying)) return false;
		var next: Null<Int> = 0;
		for (v in values) {
			final init: Null<QueryNode> = v.children.length == 1 ? v.children[0] : null;
			final span: Null<Span> = init?.span;
			final text: Null<String> = span == null ? null : source.substring(span.from, span.to);
			final value: Null<Int> = if (v.children.length == 0)
				next
			else if (text != null && INTEGER.match(text))
				Std.parseInt(text)
			else
				null;
			if (value == 0) return true;
			next = value == null ? null : value + 1;
		}
		return false;
	}

	/**
	 * Whether the member `member` of the type `owner` holds only values of the closed abstract `closed`: declared as
	 * the abstract, read through a getter every `return` of which hands back a value, or with no getter, initialized
	 * with a value — or, with no initializer, defaulting to one (`ClosedAbstract.zeroIsValue`) — and assigned only
	 * values (`=`, never a compound assignment or an increment) wherever a bare name or a field of its name is written.
	 * A member being judged counts as holding values meanwhile: a value cycle through members builds nothing new.
	 */
	private function holdsValues(owner: String, member: String, closed: ClosedAbstract): Bool {
		final key: String = '$owner.$member';
		final known: Null<Bool> = _holds[key];
		if (known != null) return known;
		if (_judging.contains(key)) return true;
		_judging.push(key);
		final info: Null<MemberInfo> = _graph.types.memberOnChain(owner, member);
		final decl: Null<HeldDecl> = _trees.typeDecl(owner);
		final holds: Bool = info != null && decl != null && info.typeSource == closed.name
			&& (info.hasGetter ? getterHolds(decl, owner, member, closed) : storedHolds(decl, owner, member, closed));
		_judging.pop();
		// an answer that leaned on a member or a parameter still being judged is kept only once nothing is
		if (_judging.length == 0 && _passing.length == 0 || !holds) _holds[key] = holds;
		return holds;
	}

	/**
	 * Whether every `return` of the getter of the member `member` of `owner` (declared in `decl`) hands back a value; a
	 * return of the member's own stored field (`@:isVar`) is judged by what that field holds (`storedHolds`).
	 */
	private function getterHolds(decl: HeldDecl, owner: String, member: String, closed: ClosedAbstract): Bool {
		final prefix: Null<String> = (_shape.accessorMethodPrefixes ?? [])[0];
		final getter: Null<QueryNode> = prefix == null
			? null
			: decl.node.children.find(c -> (_shape.functionKinds ?? []).contains(c.kind) && c.name == prefix + member);
		if (getter == null) return false;
		final returns: Array<QueryNode> = [];
		collectReturns(getter, returns, true);
		final at: ValueContext = { file: decl.file, fn: getter, owner: owner };
		return returns.length > 0 && returns.foreach(r ->
			r.children.length == 1 && (
				readsOwnField(r.children[0], getter, member)
					? storedHolds(decl, owner, member, closed)
					: valueExpr(r.children[0], at, closed)
			)
		);
	}

	/** Whether the stored member `member` of `owner` (declared in `decl`) starts with a value and is assigned only values. */
	private function storedHolds(decl: HeldDecl, owner: String, member: String, closed: ClosedAbstract): Bool {
		final field: Null<QueryNode> = decl.node.children.find(c -> (_shape.fieldDeclKinds ?? []).contains(c.kind) && c.name == member);
		if (field == null || field.children.length > 1) return false;
		final init: Null<QueryNode> = field.children.length == 1 ? field.children[0] : null;
		final starts: Bool = init == null ? closed.zeroIsValue : valueExpr(init, { file: decl.file, fn: null, owner: owner }, closed);
		final assigned: Bool = writesTo(member).foreach(w -> assignsValue(w, closed));
		return starts && assigned;
	}

	/**
	 * Whether `expr`, evaluated at `at`, is a value of the closed abstract `closed`: a value (bare, or off the
	 * abstract's name), arms of parentheses, `?:` or a `switch` that are, a parameter of the function written as the
	 * abstract, `p ?? v` of an optional such parameter or a value, a member holding only values (`holdsValues`), or a
	 * call whose every target returns a type a `@:from` function of the abstract takes (that function hands back only
	 * values). Anything else — a cast, a `Dynamic` read, a local — may be any value.
	 */
	private function valueExpr(expr: QueryNode, at: ValueContext, closed: ClosedAbstract): Bool {
		final kids: Array<QueryNode> = expr.children;
		final kind: String = expr.kind;
		if (kind == _shape.parenKind && kids.length == 1) return valueExpr(kids[0], at, closed);
		if (kind == _shape.ternaryKind && kids.length == 3) return valueExpr(kids[1], at, closed) && valueExpr(kids[2], at, closed);
		if ((_shape.switchKinds ?? []).contains(kind)) {
			final arms: Array<QueryNode> = kids.slice(1);
			return arms.length > 0
				&& arms.foreach(b -> b.children.length > 0 && valueExpr(unwrapped(b.children[b.children.length - 1]), at, closed));
		}
		if (kind == _shape.nullCoalesceKind && kids.length == 2)
			return valueExpr(kids[1], at, closed) && (valueExpr(kids[0], at, closed) || parameterOf(kids[0], at, closed, true));
		if (kind == _shape.identKind) return identValue(expr, at, closed);
		if (isAccess(kind) && kids.length == 1) return accessValue(expr, at, closed);
		return kind == _shape.callKind && convertedCall(expr, at, closed);
	}

	/** `node` without the expression statement around it, as a `switch` arm's value is written. */
	private function unwrapped(node: QueryNode): QueryNode {
		return node.kind == _shape.exprStatementKind && node.children.length == 1 ? node.children[0] : node;
	}

	/**
	 * Whether the bare name `read` at `at` is a value of `closed`: a parameter of the function written as the abstract when the function
	 * binds the name (a `case` pattern naming it excepted), else one of its values (no member of the running type so named), else a member
	 * of the running type holding only values.
	 */
	private function identValue(read: QueryNode, at: ValueContext, closed: ClosedAbstract): Bool {
		final name: String = read.name ?? '';
		final fn: Null<QueryNode> = at.fn;
		final named: Array<QueryNode> = [];
		if (fn != null) BareNames.collectNamed(fn, name, _shape, named);
		// a case naming a value compares with it: only another binding of the name hides the value
		if (named.exists(n -> n.kind != _shape.caseBranchKind)) return parameterOf(read, at, closed, false);
		final owner: Null<String> = at.owner;
		final declaring: Null<String> = owner == null ? null : _graph.types.declaringTypeOf(owner, name);
		if (declaring == null) return closed.values.contains(name);
		return holdsValues(declaring, name, closed);
	}

	/**
	 * Whether the field read `read` at `at` is a value of `closed`: a value off the abstract's own name, or a member
	 * holding only values read off `this`, off a type's name, or off a member of the running type, by its written type.
	 */
	private function accessValue(read: QueryNode, at: ValueContext, closed: ClosedAbstract): Bool {
		final name: String = read.name ?? '';
		final receiver: QueryNode = read.children[0];
		final via: Null<String> = receiver.name;
		if (receiver.kind != _shape.identKind || via == null) return false;
		if (via == closed.name) return closed.values.contains(name);
		final fn: Null<QueryNode> = at.fn;
		if (fn != null && !BareNames.bindsNothing(fn, via, _shape)) return false;
		final owner: Null<String> = at.owner;
		// off `this`: the running type; off a member: its written type; off a name no member holds: the type of that name
		final member: Null<MemberInfo> = owner == null ? null : _graph.types.memberOnChain(owner, via);
		final type: Null<String> = if (via == _shape.selfReferenceText)
			owner
		else if (member != null)
			member.typeSource
		else
			_graph.types.declarationCount(via) == 1 ? via : null;
		final bare: Null<String> = type == null ? null : type.split('<')[0];
		final declaring: Null<String> = bare == null ? null : _graph.types.declaringTypeOf(bare, name);
		return declaring != null && holdsValues(declaring, name, closed);
	}

	/**
	 * Whether `read` at `at` is the one binding in its function of its name, a parameter written as the abstract
	 * itself — a required one with no default, or an optional one (`?p`, null when left out) where `optional` allows it —
	 * that every call hands a value (`callersPassValues`).
	 */
	private function parameterOf(read: QueryNode, at: ValueContext, closed: ClosedAbstract, optional: Bool): Bool {
		final fn: Null<QueryNode> = at.fn;
		final name: Null<String> = read.name;
		if (fn == null || name == null || read.kind != _shape.identKind) return false;
		final named: Array<QueryNode> = [];
		BareNames.collectNamed(fn, name, _shape, named);
		final param: Null<QueryNode> = named.length == 1 ? named[0] : null;
		final declared: Null<QueryNode> = param?.type;
		if (param == null || declared == null) return false;
		if (declared.name != closed.name || declared.children.length > 0) return false;
		final shaped: Bool = if (param.kind == _shape.optionalParamKind)
			optional
		else
			(_shape.paramKinds ?? []).contains(param.kind) && param.kind != _shape.restParamKind && param.children.length == 0;
		return shaped && callersPassValues(fn, param, at.file, closed);
	}

	/**
	 * Whether every call of the function `fn` of `file` hands its parameter `param` a value of `closed`: `fn` is the
	 * graph's function at exactly its span, which code outside the run cannot call (`_seedable`; a constructor excepted —
	 * a runtime construction is the hole this takes as absent), never handed on as a value, and each invocation's
	 * argument for `param` (`argumentsAt`) is a value where it is written, or left out of an optional parameter, which
	 * then holds null. A function nothing calls hands nothing.
	 */
	private function callersPassValues(fn: QueryNode, param: QueryNode, file: String, closed: ClosedAbstract): Bool {
		final params: Array<QueryNode> = [for (c in fn.children) if ((_shape.paramKinds ?? []).contains(c.kind)) c];
		final index: Int = params.indexOf(param);
		final id: Null<String> = _trees.functionOf(file, fn);
		if (index < 0 || id == null) return false;
		if (_graph.node(id)?.name != (_shape.constructorName ?? 'new') && _seedable(id)) return false;
		final key: String = '$id#$index';
		if (_passing.contains(key)) return true;
		_passing.push(key);
		// an optional parameter before this one may be skipped by type, moving a later argument here
		final skippable: Bool = params.slice(0, index).exists(p -> p.kind == _shape.optionalParamKind || p.children.length > 0);
		final optional: Bool = param.kind == _shape.optionalParamKind;
		final passes: Bool = _graph.inEdges(id).foreach(e -> e.kind == Contains || e.kind.isInvocation() && {
			final args: Null<{ values: Array<QueryNode>, at: ValueContext }> = argumentsAt(e);
			args != null && (args.values.length == params.length || args.values.length == 0 || !skippable)
				&& (index >= args.values.length ? optional : handsValue(args.values[index], args.at, closed, optional));
		});
		_passing.pop();
		return passes;
	}

	/**
	 * The arguments the invocation `edge` hands its target, in order, and where they are evaluated: a call's (never a
	 * static extension's, which hands its receiver first), a construction's, or the value a plain `=` assigns through a
	 * setter. Null for any other site.
	 */
	private function argumentsAt(edge: CallEdge): Null<{ values: Array<QueryNode>, at: ValueContext }> {
		final span: Null<Span> = edge.span;
		final path: Array<QueryNode> = span == null ? [] : _trees.pathTo(edge.file, span);
		final site: Null<QueryNode> = path[path.length - 1];
		if (site == null) return null;
		final parent: Null<QueryNode> = path[path.length - 2];
		final values: Null<Array<QueryNode>> = if (site.kind == _shape.callKind && site.children.length > 0)
			ArgumentValues.receiverPassesNothing(_graph, _shape, site, edge.to) ? site.children.slice(1) : null
		else if (site.kind == _shape.newExprKind)
			[for (c in site.children) if (!_typeKinds.contains(c.kind)) c]
		else if (parent != null && parent.kind == _shape.assignKind && parent.children.length == 2 && parent.children[0] == site)
			[parent.children[1]]
		else
			null;
		return values == null ? null : { values: values, at: contextOf(edge.file, site) };
	}


	/**
	 * Whether the call `call` at `at` hands back a value of `closed` through an implicit conversion: the graph resolves
	 * it, and every target's written return type is one a `@:from` function of the abstract takes (or the type such a
	 * function takes as `Null<…>`).
	 */
	private function convertedCall(call: QueryNode, at: ValueContext, closed: ClosedAbstract): Bool {
		final span: Null<Span> = call.span;
		final fnId: Null<String> = span == null ? null : _graph.functionAt(at.file, span.from);
		if (span == null || fnId == null) return false;
		final targets: Array<String> = [
			for (e in _graph.outEdges(fnId)) if (e.kind.isInvocation() && e.span?.from == span.from && e.span?.to == span.to) e.to
		];
		return targets.length > 0 && targets.foreach(t -> {
			final target: Null<FnNode> = _graph.node(t);
			final type: Null<String> = target?.typeName;
			final name: Null<String> = target?.name;
			final returned: Null<String> = type == null || name == null ? null : _graph.types.memberOnChain(type, name)?.returnSource;
			final text: Null<String> = returned == null ? null : ~/\s+/g.replace(returned, '');
			text != null && (closed.fromTypes.contains(text) || closed.fromTypes.contains('Null<$text>'));
		});
	}

	/**
	 * Every write in the run whose target is the bare name `name` or a field so named (`FieldWrites.of`) — an assignment,
	 * a compound one, an increment — with the outermost function around it (`contextOf`).
	 */
	private function writesTo(name: String): Array<WriteSite> {
		final known: Null<Array<WriteSite>> = _writesOf[name];
		if (known != null) return known;
		final sites: Array<WriteSite> = [for (w in _writes.of(name)) { node: w.write, at: contextOf(w.file, w.write) }];
		_writesOf[name] = sites;
		return sites;
	}

	/**
	 * Where the node `node` of `file` is evaluated: the outermost function of the file's tree around it, of the type
	 * declaring that function; no function and no type outside every function.
	 */
	private function contextOf(file: String, node: QueryNode): ValueContext {
		final span: Null<Span> = node.span;
		final path: Array<QueryNode> = span == null ? [] : _trees.pathTo(file, span);
		final functions: Array<String> = _shape.functionKinds ?? [];
		for (i in 1...path.length) if (functions.contains(path[i].kind)) return { file: file, fn: path[i], owner: path[i - 1].name };
		return { file: file, fn: null, owner: null };
	}

	/** Whether the write `w` assigns a value of `closed`: a plain `=` of a value (`valueExpr`), never a compound one or an increment. */
	private function assignsValue(w: WriteSite, closed: ClosedAbstract): Bool {
		return w.node.kind == _shape.assignKind && w.node.children.length == 2 && valueExpr(w.node.children[1], w.at, closed);
	}

	/** Whether `expr`, a return of the accessor `getter`, reads the member `member` itself: bare where the getter binds nothing of its name, or off `this`. */
	private function readsOwnField(expr: QueryNode, getter: QueryNode, member: String): Bool {
		final read: QueryNode = expr.kind == _shape.parenKind && expr.children.length == 1 ? expr.children[0] : expr;
		return read.name == member && (read.kind == _shape.identKind && BareNames.bindsNothing(getter, member, _shape) || isSelf(read));
	}

	/**
	 * Whether the argument `arg` at `at` hands a parameter a value of `closed`: a value (`valueExpr`), or — to an `optional`
	 * parameter, which this reads only through `??` — `null`, or an optional parameter of the caller its own calls hand a
	 * value or `null`.
	 */
	private function handsValue(arg: QueryNode, at: ValueContext, closed: ClosedAbstract, optional: Bool): Bool {
		return valueExpr(arg, at, closed) || optional && (arg.kind == _shape.nullLiteralKind || parameterOf(arg, at, closed, true));
	}

}

/** A closed enum abstract: its name, its values, the types its `@:from` functions take, and whether `0` is a value. */
private typedef ClosedAbstract = {
	final name: String;
	final values: Array<String>;
	final fromTypes: Array<String>;
	final zeroIsValue: Bool;
}

/** The members of an enum abstract that can build a value: its values, and its functions (whether each is a `@:from`). */
private typedef AbstractMembers = {
	final values: Array<QueryNode>;
	final functions: Array<{ fn: QueryNode, from: Bool }>;
}

/** Where an expression is evaluated: its file, the outermost function around it (null outside one) and that function's type. */
private typedef ValueContext = {
	final file: String;
	final fn: Null<QueryNode>;
	final owner: Null<String>;
}

/** A write in the project (an assignment, a compound one, an increment) and where it sits. */
private typedef WriteSite = {
	final node: QueryNode;
	final at: ValueContext;
}
