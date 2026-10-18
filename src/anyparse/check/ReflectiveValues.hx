package anyparse.check;

import anyparse.check.ReflectiveReach.closure;
import anyparse.check.ReflectiveReach.holderOf;
import anyparse.query.BoolExprShape;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphGenerics;
import anyparse.query.CallGraphNames;
import anyparse.query.Glob;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberLookup.MemberDeclaration;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.SourceText;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/** What a reflective write stores in the field it writes (`FieldWriteSite.stored`). */
enum StoredValue {
	/** It stores no value: it deletes the field (`Reflect.deleteField`, `DynamicAccess.remove`). */
	Nothing;

	/** It stores the value of the expression `node`. */
	Value(node: QueryNode);

	/** What it stores is out of sight: the writing function handed on as a value, a write of any other shape. */
	Unknown;
}

/**
 * What may invoke a function from outside the calls the graph holds (`ThreadSafety`): `seedable` whether code outside the
 * run may, `inertRef` whether a function value handed on runs nothing.
 */
typedef Entries = {
	final seedable: (String) -> Bool;
	final inertRef: (CallEdge) -> Bool;
}

/**
 * What a function writes to one of its parameters (`ReflectiveValues.writesOf`): the values its `=` and `??=` writes store,
 * and the types the values its operator writes store may be.
 */
typedef Writes = {
	final values: Array<QueryNode>;
	final types: Array<String>;
}

/**
 * The locals and parameters (`<file>:<binding>`) and the field NAMES some initializer or write hands a value its declared
 * type was never checked against (`ReflectiveValues.claims`).
 */
typedef Claims = {
	final bindings: Array<String>;
	final fields: Array<String>;
}

/**
 * What a reflective write on a value the run places on no class STORES, and whether that may be a lock of the type a lock
 * member is declared of (`FieldWrites.reflectiveWritersOf`). Such a write may store its value in any member of any object;
 * what keeps a member's lock its own is that the value provably holds no lock of the member's type, read off what the value
 * is — a POSITIVE list, anything else may be any object (`typesOf`).
 */
@:nullSafety(Strict)
final class ReflectiveValues {

	/** How many parameters deep a value is followed into the calls handing it (`parameterTypes`). */
	private static inline final MAX_DEPTH: Int = 8;

	/** Each parameter followed (`<file>:<start>`) -> the types of what every call hands it (`parameterTypes`); null for any. */
	private final _parameters: Map<String, Null<Array<String>>> = [];

	/** The types a literal is of (`RefShape.literalTypeNames`): no value of one is a lock. */
	private final _basic: Array<String> = [];

	private final _graph: CallGraph;
	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;
	private final _reach: ReflectiveReach;

	/** Whether the run sees every type and every write of the project (`FieldWrites.complete`). */
	private final _complete: Bool;

	/**
	 * What may invoke a function from outside the graph's calls (`callersSeen`); null when the run cannot tell, and no
	 * parameter is then followed.
	 */
	private final _entries: Null<Entries>;

	/**
	 * The globs naming every class whose methods a read of a computed name may obtain (`reflectiveMethodHolders`, the one
	 * list every file of the run declares); null when undeclared, and such a read may then obtain any method.
	 */
	private final _methodHolders: Null<Array<String>>;

	/** Every string literal the held files spell (`spelled`); null until first asked. */
	private var _literals: Null<Array<String>> = null;

	/**
	 * Each local or parameter (`<file>:<binding>`) and each field NAME a write or an initializer may hand a value its declared
	 * type was never checked against (`unchecked`); null until first asked.
	 */
	private var _claims: Null<Claims> = null;

	public function new(
		graph: CallGraph, plugin: GrammarPlugin, reach: ReflectiveReach, complete: Bool, ?entries: Entries, ?methodHolders: Array<String>
	) {
		_graph = graph;
		_plugin = plugin;
		_shape = plugin.refShape();
		_reach = reach;
		_complete = complete;
		_entries = entries;
		_methodHolders = methodHolders;
		for (t in _shape.literalTypeNames ?? []) if (!_basic.contains(t)) _basic.push(t);
	}

	/**
	 * The types of the objects the value `stored`, written in `file` and the function `fn`, may be (`typer` typing an
	 * expression as the declarations say): none for no value or `null`, a literal's type for a literal, the declared type
	 * of a typed expression, and for a parameter of a function every call of which the run sees, what each call hands it
	 * (`parameterTypes`). Null — any object — for anything else: `Dynamic`, `Any`, an untyped or unseen value.
	 */
	public function typesOf(
		file: String, fn: Null<String>, stored: StoredValue, typer: (String, Null<String>, QueryNode) -> Null<String>
	): Null<Array<String>> {
		return switch stored {
			case Nothing: [];
			case Unknown: null;
			case Value(node): valueTypes(file, fn, node, typer, []);
		};
	}

	/**
	 * Whether a value declared `type` may be a lock of `member`, the type a lock member is declared of (null: unknown):
	 * never for a literal's type or an enum the run declares once, which no class's object is; else when one object may be
	 * of both — a project class or interface shares objects with another only through a common subtype, all of which the
	 * run sees, and with a library type only through a project subtype of it unless its own chain leaves the run. Any other
	 * type (a library one, a structure, an abstract) may be the lock.
	 */
	public function mayHold(type: String, member: Null<String>): Bool {
		if (type == member) return true;
		if (_basic.contains(type) || enumType(type)) return false;
		final index: Null<SymbolIndex> = _graph.index;
		if (index == null || member == null) return true;
		if (!classLike(type) || !classLike(member) && declared(member)) return true;
		if (!classLike(member) && index.subtypes.supertypeNamesClosure(type).exists(t -> !declared(t))) return true;
		final under: Array<String> = index.subtypes.subtypeNamesClosure(member);
		return index.subtypes.subtypeNamesClosure(type).exists(t -> under.contains(t));
	}

	/**
	 * The type the member `field` (`Owner.member`) is declared of, read where it is declared and `Null<…>` peeled, through
	 * its typedef aliases; null when it declares none, a type parameter of its owner, or two declarations write it apart.
	 */
	public function memberTypeOf(field: String): Null<String> {
		final dot: Int = field.lastIndexOf('.');
		if (dot <= 0) return null;
		final index: Null<SymbolIndex> = _graph.index;
		final found: Null<{ member: MemberInfo, host: ResolvedType }> = index?.members.declaringHost(
			field.substring(0, dot), field.substring(dot + 1)
		);
		final written: Null<String> = found?.member.typeSource;
		if (index == null || found == null || written == null) return null;
		final params: Array<String> = found.host.type.typeParamNames;
		final peeled: String = NominalTypes.unwrapNullable(written, _shape.nullableWrapperTypeNames ?? [], _plugin.typeSyntax);
		final path: Null<String> = switch _plugin.typeSyntax(peeled)?.shape {
			case Nominal(p, _): p;
			case _: null;
		};
		if (path == null || params.contains(path)) return null;
		// the name read where the member is declared, its file's imports binding it
		final decl: Null<ResolvedType> = index.refs.resolveTypeRef(path, found.host.file, found.host.type.span.from);
		return index.refs.aliasedName(decl == null ? SourceText.lastSegment(path) : decl.type.name);
	}

	/** Whether `type` is a class or an interface the run declares once. */
	private function classLike(type: String): Bool {
		final index: Null<SymbolIndex> = _graph.index;
		return index != null && ReflectiveReach.classLike(index, _shape, type);
	}

	/** Whether the graph's index declares a type of the name `type`. */
	private function declared(type: String): Bool {
		return (_graph.index?.refs.declsNamed(type) ?? []).length > 0;
	}

	/**
	 * Whether `type` is an enum the run declares once (`ReflectiveReach.onlyDeclaration`), asked of its declaration's KIND
	 * (`RefShape.runtimeTaggedTypeKinds`): a typedef of a structure holds any object with its fields, an abstract whatever it
	 * wraps.
	 */
	private function enumType(type: String): Bool {
		final index: Null<SymbolIndex> = _graph.index;
		final decl: Null<ResolvedType> = index == null ? null : ReflectiveReach.onlyDeclaration(index, type);
		return decl != null && (_shape.runtimeTaggedTypeKinds ?? []).contains(decl.type.kind);
	}

	/**
	 * The types of the objects the expression `node`, in `file` and the function `fn`, may be (`typesOf`); `visiting` holds
	 * the parameters followed on the way here. A declared type counts only in a run that sees every type of the project —
	 * a literal's type always: no subtype of one is a lock.
	 */
	private function valueTypes(
		file: String, fn: Null<String>, node: QueryNode, typer: (String, Null<String>, QueryNode) -> Null<String>, visiting: Array<String>
	): Null<Array<String>> {
		final value: QueryNode = BoolExprShape.unwrapParens(node, _shape.parenKind);
		if (value.kind == _shape.nullLiteralKind) return [];
		final literal: Null<String> = (_shape.literalTypeNames ?? [])[value.kind];
		if (literal != null) return [literal];
		final written: Null<String> = value.kind == _shape.newExprKind ? value.name : typer(file, fn, value);
		return if (written != null && typeParameter(file, value, written))
			null
		else if (written != null && value.kind != _shape.newExprKind && claimed(file, value, typer))
			null
		else if (written != null && !catchAll(written))
			typedAs(file, written)
		else if (value.kind == _shape.identKind)
			parameterTypes(file, value, typer, visiting)
		else
			null;
	}

	/**
	 * Whether `written`, the type the value `node` of `file` is declared of, names a type parameter in scope at it — the
	 * enclosing type's or function's (`CallGraphGenerics.inScopeAt`): whatever it is instantiated with, a lock included, never
	 * the project type the name may also name.
	 */
	private function typeParameter(file: String, node: QueryNode, written: String): Bool {
		final outer: Null<String> = NominalTypes.outerNominalOf(written, _plugin.typeSyntax);
		final tree: Null<QueryNode> = _graph.treeOf(file);
		final source: Null<String> = _graph.sourceOf(file);
		final at: Null<Int> = node.span?.from;
		if (outer == null || outer.indexOf('.') >= 0 || tree == null || source == null || at == null) return false;
		final kinds: Array<String> = (_shape.functionKinds ?? []).concat(_shape.inlineFunctionKinds ?? []);
		return CallGraphGenerics.inScopeAt(tree, at, RunScan.typeParamNamesOf(_plugin, source), kinds).contains(outer);
	}

	/**
	 * Whether `node`, read in `file`, is a local, a parameter or a field some initializer or write hands a value its declared
	 * type was never checked against (`claims`): its declared type is then a claim, not a fact.
	 */
	private function claimed(file: String, node: QueryNode, typer: (String, Null<String>, QueryNode) -> Null<String>): Bool {
		final value: QueryNode = BoolExprShape.unwrapParens(node, _shape.parenKind);
		final name: Null<String> = value.name;
		final at: Null<Span> = value.span;
		final tree: Null<QueryNode> = _graph.treeOf(file);
		if (name == null || at == null || tree == null) return false;
		final known: Claims = claims(typer);
		if (FieldWrites.accessKind(value.kind, _shape)) return known.fields.contains(name);
		if (value.kind != _shape.identKind) return false;
		final bound: Null<Int> = TypeResolver.resolveBindingFrom(name, at, tree, _shape);
		return bound == null || bound < 0 ? known.fields.contains(name) : known.bindings.contains('$file:$bound');
	}

	/**
	 * The locals, parameters and field names of the held files an initializer or a write hands a value its declared type was
	 * never checked against, walked once (`unchecked`): a local by its binding, a field by its name, whoever declares it.
	 */
	private function claims(typer: (String, Null<String>, QueryNode) -> Null<String>): Claims {
		final known: Null<Claims> = _claims;
		if (known != null) return known;
		final out: Claims = { bindings: [], fields: [] };
		_claims = out;
		for (held in _graph.heldFiles()) {
			final file: String = held.file;
			final tree: QueryNode = held.tree;
			function walk(node: QueryNode): Void {
				for (c in node.children) walk(c);
				claimDeclared(file, node, out, typer);
				if (_shape.writeParentKinds.contains(node.kind) && node.children.slice(1).exists(c -> unchecked(file, c, typer)))
					claimWritten(file, tree, node.children[0], out);
			}
			walk(tree);
		}
		return out;
	}

	/**
	 * Records `node`, of `file`, in `out` when it declares a local (by its binding: its own start) or a field (by its name)
	 * whose initializer may hand a value its declared type was never checked against (`unchecked`).
	 */
	private function claimDeclared(
		file: String, node: QueryNode, out: Claims, typer: (String, Null<String>, QueryNode) -> Null<String>
	): Void {
		final name: Null<String> = node.name;
		final at: Null<Span> = node.span;
		final local: Bool = (_shape.localDeclKinds ?? []).concat(_shape.localDeclExprKinds ?? [])
			.concat(_shape.staticLocalDeclKinds ?? [])
			.contains(node.kind);
		final field: Bool = (_shape.fieldDeclKinds ?? []).contains(node.kind);
		if (name == null || at == null || !(local || field) || !node.children.exists(c -> unchecked(file, c, typer))) return;
		noteClaim(field ? out.fields : out.bindings, field ? name : '$file:${at.from}');
	}

	/**
	 * Records the write target `node` of `tree`, the file `file`, in `out`: a local or a parameter by its binding, a bare
	 * member or a field read off a value by its name.
	 */
	private function claimWritten(file: String, tree: QueryNode, node: QueryNode, out: Claims): Void {
		final target: QueryNode = BoolExprShape.unwrapParens(node, _shape.parenKind);
		final written: Null<String> = target.name;
		final span: Null<Span> = target.span;
		if (written == null || span == null) return;
		final ident: Bool = target.kind == _shape.identKind;
		final bound: Null<Int> = ident ? TypeResolver.resolveBindingFrom(written, span, tree, _shape) : null;
		if (bound != null && bound >= 0)
			noteClaim(out.bindings, '$file:$bound')
		else if (ident || FieldWrites.accessKind(target.kind, _shape))
			noteClaim(out.fields, written);
	}

	/**
	 * Whether the expression `node` of `file` may hand on a value its declared type was never checked against: it holds an
	 * unchecked `cast` (`uncheckedCastKind`) or an `untyped` (`untypedKinds`) anywhere, or is itself declared of a catch-all
	 * type (`Dynamic`, `Any`), which the compiler lets into a variable of any type.
	 */
	private function unchecked(file: String, node: QueryNode, typer: (String, Null<String>, QueryNode) -> Null<String>): Bool {
		final untypedKinds: Array<String> = _shape.untypedKinds ?? [];
		function holds(n: QueryNode): Bool {
			return n.kind == _shape.uncheckedCastKind || untypedKinds.contains(n.kind) || n.children.exists(holds);
		}
		if ((_shape.typeAnnotationKinds ?? []).contains(node.kind)) return false;
		final typed: Null<String> = typer(file, null, node);
		return holds(node) || typed != null && catchAll(typed);
	}

	/**
	 * The types of the value a write of the kind `kind` to `target`, in `file` and the function `id`, stores when it is a
	 * write by an operator (`operatorWriteKinds`): a value of the target's declared type, none for a catch-all one (an
	 * operator on `Dynamic` makes a number, a string or a boolean). Null — anything — for a write of any other kind, or a
	 * declared type out of sight or a type parameter.
	 */
	private function operatorStores(
		file: String, id: String, kind: String, target: QueryNode, typer: (String, Null<String>, QueryNode) -> Null<String>
	): Null<Array<String>> {
		final typed: Null<String> = (_shape.operatorWriteKinds ?? []).contains(kind) ? typer(file, id, target) : null;
		final written: Null<String> = typed == null || typeParameter(file, target, typed) ? null : typed;
		return if (written == null)
			null
		else if (catchAll(written))
			[]
		else
			typedAs(file, written);
	}

	/** Whether `written` names a catch-all type (`Dynamic`, `Any`), which any value is of. */
	private function catchAll(written: String): Bool {
		return (_shape.catchAllTypeNames ?? []).contains(CallGraphNames.lastSegments(written, 1));
	}

	/**
	 * The types a value declared `written` in `file` may be (`ReflectiveReach.namedTypes`), in a run that sees every type of
	 * the project — a literal's type in any run: no subtype of one is a lock. Null for any other.
	 */
	private function typedAs(file: String, written: String): Null<Array<String>> {
		final named: Array<String> = _reach.namedTypes(file, written);
		return _complete || named.foreach(t -> _basic.contains(t)) ? named : null;
	}

	/**
	 * When `ident`, in `file`, names a parameter of a member function every call of which the run sees (`callersSeen`), and
	 * no read of a name may obtain the function as a value (`obtainable`): the types of what each call hands it
	 * (`argumentTypes`). Null for any other name, a run that does not see the whole project, or a parameter followed too
	 * deep or round a cycle.
	 */
	private function parameterTypes(
		file: String, ident: QueryNode, typer: (String, Null<String>, QueryNode) -> Null<String>, visiting: Array<String>
	): Null<Array<String>> {
		final name: Null<String> = ident.name;
		final at: Null<Span> = ident.span;
		final tree: Null<QueryNode> = _graph.treeOf(file);
		if (name == null || at == null || tree == null) return null;
		final paramKinds: Array<String> = _shape.paramKinds ?? [];
		final from: Null<Int> = TypeResolver.resolveBindingFrom(name, at, tree, _shape);
		final param: Null<QueryNode> = from == null ? null : holderOf(tree, from, n -> paramKinds.contains(n.kind));
		final start: Null<Int> = param?.span?.from;
		if (param == null || start == null || from == null) return null;
		final key: String = '$file:$start';
		if (_parameters.exists(key)) return _parameters[key];
		if (visiting.contains(key) || visiting.length >= MAX_DEPTH) return null;
		final fnKinds: Array<String> = _shape.functionKinds ?? [];
		final decl: Null<QueryNode> = holderOf(tree, start, n -> fnKinds.contains(n.kind) && n.children.contains(param));
		final found: Null<String> = _graph.functionAt(file, start);
		if (decl == null || found == null) return null;
		final id: String = found;
		if (id.indexOf('#') >= 0 || !callersSeen(id) || obtainable(id)) return null;
		final writes: Null<Writes> = writesOf(file, id, tree, decl, name, from, typer);
		final answer: Null<Array<String>> = writes == null ? null : argumentTypes(id, decl, param, writes, typer, visiting.concat([key]));
		_parameters[key] = answer;
		return answer;
	}

	/**
	 * What the function `id`, declared by `decl` in `file`, writes to its parameter `name` bound at `from` in `tree` —
	 * closures and local functions included, each write target resolved to its binding (`TypeResolver.resolveBindingFrom`):
	 * the right side of every `=` and `??=` as a value, and for a write by an operator (`operatorWriteKinds`) the types of
	 * the target's declared type, none for a catch-all one (an operator on `Dynamic` makes a number, a string or a boolean).
	 * Null when a write of any other shape binds it, or an operator writes it with a type out of sight: it may store anything.
	 */
	private function writesOf(
		file: String, id: String, tree: QueryNode, decl: QueryNode, name: String, from: Int,
		typer: (String, Null<String>, QueryNode) -> Null<String>
	): Null<Writes> {
		final out: Writes = { values: [], types: [] };
		final writeKinds: Array<String> = _shape.writeParentKinds;
		var unknown: Bool = false;
		function walk(node: QueryNode): Void {
			for (c in node.children) walk(c);
			if (unknown || !writeKinds.contains(node.kind) || node.children.length == 0) return;
			final target: QueryNode = BoolExprShape.unwrapParens(node.children[0], _shape.parenKind);
			final at: Null<Span> = target.span;
			if (target.kind != _shape.identKind || target.name != name || at == null) return;
			if (TypeResolver.resolveBindingFrom(name, at, tree, _shape) != from) return;
			if ((node.kind == _shape.assignKind || node.kind == _shape.nullCoalAssignKind) && node.children.length == 2) {
				out.values.push(node.children[1]);
				return;
			}
			final types: Null<Array<String>> = operatorStores(file, id, node.kind, target, typer);
			if (types == null)
				unknown = true
			else
				for (t in types) if (!out.types.contains(t)) out.types.push(t);
		}
		walk(decl);
		return unknown ? null : out;
	}

	/**
	 * The types of what each call of the function `id`, declared by `decl`, hands its parameter `param`, and of the
	 * parameter's default: the argument at its index — or, when an optional parameter comes before it, any argument up to
	 * it, a skipped one moving the rest along — of every call the graph holds (`argumentsAt`). Null when a call of it is one
	 * the tree holds no call at (an accessor), or a rest parameter comes up to it. What the function itself writes to the
	 * parameter (`writes`, `writesOf`) counts as well.
	 */
	private function argumentTypes(
		id: String, decl: QueryNode, param: QueryNode, writes: Writes, typer: (String, Null<String>, QueryNode) -> Null<String>,
		visiting: Array<String>
	): Null<Array<String>> {
		final params: Array<QueryNode> = [for (c in decl.children) if ((_shape.paramKinds ?? []).contains(c.kind)) c];
		final index: Int = params.indexOf(param);
		if (params.slice(0, index + 1).exists(p -> p.kind == _shape.restParamKind)) return null;
		final annotations: Array<String> = _shape.typeAnnotationKinds ?? [];
		final fixed: Bool = params.slice(0, index)
			.foreach(p -> p.kind != _shape.optionalParamKind && !p.children.exists(c -> !annotations.contains(c.kind)));
		final fallback: Null<QueryNode> = param.children.find(c -> !annotations.contains(c.kind));
		final own: String = _graph.node(id)?.file ?? '';
		final sources: Array<{ file: String, fn: Null<String>, node: QueryNode }> = fallback == null
			? []
			: [{ file: own, fn: id, node: fallback }];
		for (v in writes.values) sources.push({ file: own, fn: id, node: v });
		for (e in _graph.inEdges(id)) if (e.kind.isInvocation()) {
			final args: Null<Array<QueryNode>> = argumentsAt(e, id);
			if (args == null) return null;
			final handed: Array<QueryNode> = fixed ? args.slice(index, index + 1) : args.slice(0, index + 1);
			for (a in handed) sources.push({ file: e.file, fn: e.from, node: a });
		}
		final out: Array<String> = writes.types.copy();
		for (s in sources) {
			final types: Null<Array<String>> = valueTypes(s.file, s.fn, s.node, typer, visiting);
			if (types == null) return null;
			for (t in types) if (!out.contains(t)) out.push(t);
		}
		return out;
	}

	/**
	 * The arguments the call `edge` of the function `id` hands it, in order: those of the call the tree holds at its exact
	 * span, its receiver first for a static function called off a value (a `using` extension). Null when the tree holds no
	 * call there, or a static one is called off a type name other than its own (an import alias, which may be either).
	 */
	private function argumentsAt(edge: CallEdge, id: String): Null<Array<QueryNode>> {
		final at: Null<Span> = edge.span;
		final tree: Null<QueryNode> = _graph.treeOf(edge.file);
		if (at == null || tree == null) return null;
		final call: Null<QueryNode> = holderOf(
			tree, at.from, n -> n.kind == _shape.callKind && n.span?.from == at.from && n.span?.to == at.to
		);
		if (call == null || call.children.length == 0) return null;
		final args: Array<QueryNode> = call.children.slice(1);
		final callee: QueryNode = call.children[0];
		final named: Null<{ type: String, name: String }> = memberOf(id);
		if (named == null) return args;
		final type: String = named.type;
		final declarations: Array<MemberDeclaration> = _graph.index?.members.memberDeclarationsOf(type, named.name) ?? [];
		final isStatic: Bool = declarations.length > 0 && declarations.foreach(d -> d.member.isStatic);
		if (!isStatic || !FieldWrites.accessKind(callee.kind, _shape) || callee.children.length == 0) return args;
		final receiver: Null<String> = callee.children[0].name;
		return if (receiver == CallGraphNames.lastSegments(type, 1))
			args
		else if (receiver != null && CallGraphNames.isTypeLike(receiver))
			null
		else
			[callee.children[0]].concat(args);
	}

	/**
	 * Whether every invocation of the function `id` is a call the graph holds: the run can tell (`entries`), nothing outside
	 * it may invoke the function (`seedable`: a closed project, no call of its name the graph resolved to nothing), and no
	 * value of it is handed on to run (`inertRef`).
	 */
	private function callersSeen(id: String): Bool {
		final entries: Null<Entries> = _entries;
		return entries != null && !entries.seedable(id) && !_graph.inEdges(id).exists(e -> e.kind == Ref && !entries.inertRef(e));
	}

	/**
	 * Whether a read of a name may obtain the function `id` as a value, to be called with anything (`Reflect.callMethod`):
	 * a string literal of the held files spells its name, or a read of a computed name may obtain a method of its type or
	 * a subtype (`reflectiveMethodHolders` undeclared, or naming one of them).
	 */
	private function obtainable(id: String): Bool {
		final named: Null<{ type: String, name: String }> = memberOf(id);
		return named == null || obtainableMember(_graph, _methodHolders, spelled, named.type, named.name);
	}

	/** The type and the name of the member function `id`; null for a node without either. */
	private function memberOf(id: String): Null<{ type: String, name: String }> {
		final node: Null<FnNode> = _graph.node(id);
		final type: Null<String> = node?.typeName;
		final name: Null<String> = node?.name;
		return type == null || name == null ? null : { type: type, name: name };
	}

	/** Every string literal the held files spell, walked once. */
	private function spelled(): Array<String> {
		final known: Null<Array<String>> = _literals;
		if (known != null) return known;
		final out: Array<String> = literalsOf(_graph, _plugin);
		_literals = out;
		return out;
	}

	/**
	 * Whether a read of a name may obtain the member `name` of `type` as a value: `holders` (the declared
	 * `reflectiveMethodHolders`) is null, a string literal of the held files (`literals`) spells the name, or a read of a
	 * computed name may obtain a member of `type` or a subtype — one `holders` names, or one no declared path names.
	 */
	public static function obtainableMember(
		graph: CallGraph, holders: Null<Array<String>>, literals: () -> Array<String>, type: String, name: String
	): Bool {
		if (holders == null) return true;
		final globs: Array<String> = holders;
		if (literals().contains(name)) return true;
		final subtypes: Array<String> = graph.index?.subtypes.subtypeNamesClosure(type) ?? [type];
		return subtypes.exists(t -> {
			final paths: Array<String> = graph.declaredPathsOf(t);
			paths.length == 0 || paths.exists(p -> globs.exists(g -> Glob.qualifiedNames(g).match(p)));
		});
	}

	/** Every string literal the held files of `graph` spell, read through `plugin`'s string folding (none without one). */
	public static function literalsOf(graph: CallGraph, plugin: GrammarPlugin): Array<String> {
		final out: Array<String> = [];
		final kinds: Array<String> = plugin.refShape().stringLiteralKinds ?? [];
		final support: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (support == null) return out;
		final fold: StringFoldSupport = support;
		for (held in graph.heldFiles()) {
			final source: String = held.source;
			function walk(node: QueryNode): Void {
				final content: Null<String> = kinds.contains(node.kind) ? fold.literalOf(node, source)?.content : null;
				if (content != null) out.push(content);
				for (c in node.children) walk(c);
			}
			walk(held.tree);
		}
		return out;
	}

	/** Adds `key` to `claims` once. */
	private static inline function noteClaim(claims: Array<String>, key: String): Void {
		if (!claims.contains(key)) claims.push(key);
	}

}
