package anyparse.check;

import anyparse.query.BinderScan;
import anyparse.query.BoolExprShape;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphNames;
import anyparse.query.CasePatterns;
import anyparse.query.Glob;
import anyparse.query.NominalTypes;
import anyparse.query.StdTypes;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/** What a reflective write's target may be an object of (`ReflectiveReach.placeOf`). */
typedef Placement = {
	/** The types whose fields the write may reach; null when that is any type's. */
	final reaches: Null<Array<String>>;

	/** The positive exclusion bounding `reaches` though the target's declared type places it on no class; null when that type does. */
	final by: Null<String>;
}

/**
 * A `case` capture typed by the parameter of its enum constructor (`ReflectiveReach.binderType`).
 */
typedef Capture = {
	/** The written type of the constructor parameter the capture binds. */
	final type: String;

	/** The exclusion that typed it, for the run notice (`Placement.by`). */
	final by: String;
}

/**
 * What the target of a reflective write may be an object of (`FieldWrites`): the classes its declared type places it on,
 * with their subtypes and chains; else what a POSITIVE exclusion proves of a value whose declared type places it on no
 * class — each a whitelist entry with its reason (`Placement.by`), anything else any type's. The exclusions: a `final`
 * local bound to a fresh structure or object, a type parameter bounded by its constraint or by every instantiation of its
 * class, a `case` capture typed by the parameter of its enum constructor (`binderType`).
 */
@:nullSafety(Strict)
final class ReflectiveReach {

	/** The `Type` member making a class value of a name (`resolvedLiteral`). */
	private static inline final RESOLVE_CLASS: String = 'resolveClass';

	/** Each class or interface -> the types whose fields a write on a value of it may reach (`reachOf`). */
	private final _reach: Map<String, Array<String>> = [];

	/** Each class type parameter (`Type.T`) -> what its instantiations bound it to (`instantiated`); null for unbounded. */
	private final _instantiations: Map<String, Null<Array<String>>> = [];

	/** Each file -> the names a `case` pattern of it captures (`binderType`). */
	private final _captures: Map<String, Array<String>> = [];

	/** The names a `new` of the held files makes that resolve to no type (`unresolvedMade`), which may be an alias of any. */
	private final _unresolvedMade: Array<String> = [];

	/**
	 * The globs naming every class a class value made from a computed name may be of (`reflectiveClasses`, the one list
	 * every file of the run declares); null when undeclared, and such a value may then be of any class.
	 */
	private final _reflectiveClasses: Null<Array<String>>;

	private final _graph: CallGraph;
	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;

	/** Whether the run sees every type and every write of the project (`FieldWrites.complete`). */
	private final _complete: Bool;

	/** The types the held files make objects of or read as class values (`madeTypes`); null until first asked. */
	private var _made: Null<Array<String>> = null;

	public function new(graph: CallGraph, plugin: GrammarPlugin, complete: Bool, ?reflectiveClasses: Array<String>) {
		_graph = graph;
		_plugin = plugin;
		_shape = plugin.refShape();
		_complete = complete;
		_reflectiveClasses = reflectiveClasses;
	}

	/**
	 * The preconditions of the instantiation bound of a type parameter (`instantiated`, `neverMade`) the run fails: a run
	 * over the whole of a project declaring `closedWorld`, and one `reflectiveClasses` list every file declares.
	 */
	public function lacking(): Array<String> {
		final out: Array<String> = [];
		if (!_complete) out.push('no closedWorld over the whole project');
		if (_reflectiveClasses == null) out.push('no reflectiveClasses');
		return out;
	}

	/**
	 * What the target `target` of a reflective write, in `file` and the function `fn`, declared `type`, may be an object
	 * of: what that type places it on (`reachOf`) — for a `case` capture a constructor typed, the exclusion `capture` that
	 * typed it (`binderType`) — else what a POSITIVE exclusion proves: a type parameter its constraint or every
	 * instantiation of its type bounds (`typeParamPlacement`), a `final` local bound to a fresh structure or object
	 * (`freshPlacement`); any type's for anything else.
	 */
	public function placeOf(file: String, fn: Null<String>, target: QueryNode, type: Null<String>, ?capture: String): Placement {
		final param: Null<Placement> = type == null || fn == null || capture != null
			? null
			: typeParamPlacement(fn, CallGraphNames.lastSegments(type, 1));
		if (param != null) return param;
		final reaches: Null<Array<String>> = reachOf(type);
		return reaches != null ? { reaches: reaches, by: capture } : freshPlacement(file, fn, target) ?? { reaches: null, by: null };
	}

	/**
	 * Every type the name `written` may mean in `file`: as written, as the file's imports, aliases and wildcards bind it or
	 * may bind it (`keysOf`), and the type each typedef alias of those stands for — a superset, so no spelling of a type
	 * escapes it.
	 */
	public function namedTypes(file: String, written: String): Array<String> {
		final simple: String = CallGraphNames.lastSegments(written, 1);
		final out: Array<String> = [simple];
		for (key in keysOf(file, written)) for (t in [key, aliased(key)]) if (!out.contains(t)) out.push(t);
		return out;
	}

	/**
	 * The written type of the enum-constructor parameter a `case` capture `value`, in `file`, binds (`Ctor(a, b)`), with
	 * the exclusion that typed it: when the switch subject is declared of an indexed enum declaring a constructor of that
	 * name (`subjectEnum`, `subjectType` typing the subject), with as many parameters as the pattern, and the parameter
	 * names none of the enum's own type parameters; null for any other value.
	 */
	public function binderType(file: String, value: QueryNode, subjectType: (QueryNode) -> Null<String>): Null<Capture> {
		final name: Null<String> = value.name;
		final at: Null<Span> = value.span;
		final tree: Null<QueryNode> = _graph.treeOf(file);
		if (value.kind != _shape.identKind || name == null || at == null || tree == null) return null;
		if (!capturesOf(file, tree).contains(name)) return null;
		final from: Null<Int> = TypeResolver.resolveBindingFrom(name, at, tree, _shape);
		final pattern: Null<QueryNode> = from == null
			? null
			: holderOf(
				tree, from, n -> n.kind == _shape.callKind && n.children.exists(c -> c.kind == _shape.identKind && c.span?.from == from)
			);
		if (pattern == null) return null;
		final ctor: String = pattern.children[0].name ?? '';
		final owner: Null<String> = subjectEnum(file, tree, pattern, ctor, subjectType);
		if (owner == null) return null;
		final index: Null<SymbolIndex> = _graph.index;
		final enumDecl: Null<ResolvedType> = index == null ? null : onlyDeclaration(index, owner);
		final info: Null<MemberInfo> = enumDecl?.type.members.find(m -> m.name == ctor);
		if (enumDecl == null || info == null) return null;
		if (info.paramTypeSources.length != pattern.children.length - 1) return null;
		final written: Null<String> = info.paramTypeSources[pattern.children.findIndex(c -> c.span?.from == from) - 1];
		// a parameter of the enum's own type parameters is what the subject's arguments bind, which nothing here reads
		if (written == null || CallGraphNames.mentionsTypeName(written, enumDecl.type.typeParamNames, _plugin.typeSyntax)) return null;
		final outer: Null<String> = NominalTypes.outerNominalOf(written, _plugin.typeSyntax);
		return outer == null ? null : { type: outer, by: 'a capture of $owner.$ctor, typed by its parameter' };
	}

	/**
	 * What a value of the type parameter `name`, as the function `fn` sees it, may be an object of; null when `name` is
	 * no type parameter there. Bounded by its written bounds when it has any — a value of it is a value of each — else,
	 * for one the type of `fn` declares, by every instantiation of that type (`instantiated`); any type's otherwise, one a
	 * function declares included: what a call hands it, nothing here tracks.
	 */
	private function typeParamPlacement(fn: String, name: String): Null<Placement> {
		final own: Null<Array<String>> = _graph.typeParamBoundsOf(fn, name, true);
		final bounds: Null<Array<String>> = own ?? _graph.typeParamBoundsOf(fn, name);
		if (bounds == null) return null;
		if (bounds.length > 0) {
			final bounded: Null<Array<String>> = reachOfSources(bounds);
			return { reaches: bounded, by: bounded == null ? null : 'type parameter $name, bounded by its constraint' };
		}
		final owner: Null<String> = _graph.node(fn)?.typeName;
		final reaches: Null<Array<String>> = own != null || owner == null ? null : instantiated(owner, name);
		return { reaches: reaches, by: reaches == null ? null : 'type parameter $name of $owner, bounded by its instantiations' };
	}

	/**
	 * The types whose fields a write on a value declared `type` may reach: for a class or an interface the run declares
	 * once (through a typedef alias), every subtype of it and every type on the chain of each — the object is one of them,
	 * its fields declared along its chain. Null, any type's, for any other type: `Dynamic`, `Any`, a type parameter, a
	 * structure or an abstract (which a value of any class may be), a library type, an unknown
	 * one. A type parameter never arrives here: `placeOf` answers it first (`typeParamPlacement`).
	 */
	private function reachOf(type: Null<String>): Null<Array<String>> {
		final index: Null<SymbolIndex> = _graph.index;
		final named: Null<String> = type == null || index == null ? null : index.refs.aliasedName(CallGraphNames.lastSegments(type, 1));
		if (index == null || named == null) return null;
		if (!classLike(index, _shape, named)) return null;
		final known: Null<Array<String>> = _reach[named];
		if (known != null) return known;
		final out: Array<String> = index.subtypes.subtypeNamesClosure(named);
		final reach: Array<String> = closure(out, t -> index.subtypes.supertypeNamesClosure(t));
		_reach[named] = reach;
		return reach;
	}

	/**
	 * The types a value of one of the written types `sources` may be an object of, together (`reachOf`): none for the
	 * void type, which holds no value; null when one of them is any type's.
	 */
	private function reachOfSources(sources: Array<String>): Null<Array<String>> {
		final out: Array<String> = [];
		for (written in sources) {
			final outer: Null<String> = NominalTypes.outerNominalOf(written, _plugin.typeSyntax);
			if (outer != null && outer == _shape.voidTypeName) continue;
			final reach: Null<Array<String>> = reachOf(outer);
			if (reach == null) return null;
			for (t in reach) if (!out.contains(t)) out.push(t);
		}
		return out;
	}

	/**
	 * What a value of the type parameter `name` of the class or interface `type` may be an object of, bounded by every
	 * instantiation of it — null, any type's, unless the run sees every type
	 * and every write of the project (`complete`, as `FieldWrites` has it):
	 * an unseen subtype may bind the parameter to anything.
	 */
	private function instantiated(type: String, name: String): Null<Array<String>> {
		final key: String = '$type.$name';
		if (_instantiations.exists(key)) return _instantiations[key];
		final answer: Null<Array<String>> = _complete ? bindingsOf(type, name) : null;
		_instantiations[key] = answer;
		return answer;
	}

	/**
	 * Every type the parameter `name` of `type` may stand for, as the instantiations bind it: each subtype by its
	 * `extends` / `implements` chain — to a written type (`reachOfSources`), to a parameter of its own its constraint
	 * bounds, or to one it leaves free — and the type itself, which leaves it free too. An object of a type leaving it free
	 * is made with an argument of its maker's choosing, so the answer is bounded only when no such object is ever made
	 * (`neverMade`); null when it is any type's, a chain that writes no argument for it included.
	 */
	private function bindingsOf(type: String, name: String): Null<Array<String>> {
		final index: Null<SymbolIndex> = _graph.index;
		final decl: Null<ResolvedType> = index == null ? null : onlyDeclaration(index, type);
		final at: Int = decl == null ? -1 : decl.type.typeParamNames.indexOf(name);
		if (index == null || at < 0 || !classLike(index, _shape, type)) return null;
		final out: Array<String> = [];
		final free: Array<String> = [type];
		for (sub in index.subtypes.subtypeNamesClosure(type)) if (sub != type) {
			// the arguments a subtype's chain passes, read off the index's written supertypes as its subtypes are
			final args: Null<Array<String>> = index.subtypes.argumentsPassed(type, sub, _plugin.typeSyntax);
			final arg: Null<String> = args == null || at >= args.length ? null : args[at];
			if (arg == null) return null;
			final forwarded: Null<Array<String>> = _graph.typeParamBoundsOf(sub, arg);
			if (forwarded != null && forwarded.length == 0) {
				free.push(sub);
				continue;
			}
			final reach: Null<Array<String>> = reachOfSources(forwarded ?? [arg]);
			if (reach == null) return null;
			for (t in reach) if (!out.contains(t)) out.push(t);
		}
		return free.foreach(neverMade) ? out : null;
	}

	/**
	 * Whether no object of the type `type` is ever made, so none takes a type argument nothing here reads: no held file
	 * makes one or reads its name as a value under any name it means it by (`madeTypes` — a class value handed on may reach
	 * `Type.createInstance`), none makes an object of a name that resolves to no type (`unresolvedMade`, which may be an
	 * alias of it), and the project declares the classes a class value made from a computed name may be of
	 * (`reflectiveClasses`) without naming it — a library making one from such a name (an unserializer) is covered by that
	 * declaration too.
	 */
	private function neverMade(type: String): Bool {
		final globs: Null<Array<String>> = _reflectiveClasses;
		final paths: Array<String> = _graph.declaredPathsOf(type);
		if (globs == null || paths.length == 0 || paths.exists(p -> globs.exists(g -> Glob.qualifiedNames(g).match(p)))) return false;
		final made: Array<String> = madeTypes();
		return _unresolvedMade.length == 0 && !made.contains(type);
	}

	/**
	 * The types the held files make an object of, walked once (`collectMade`): by `new`, by a name of the type read as a
	 * value (a class value handed on may reach `Type.createInstance`), by a literal handed to `Type.resolveClass` — each
	 * name as its file means it, through its imports and typedef aliases (`namedTypes`). A `new` of a name that resolves
	 * to no type lands in `_unresolvedMade`.
	 */
	private function madeTypes(): Array<String> {
		final known: Null<Array<String>> = _made;
		if (known != null) return known;
		final out: Array<String> = [];
		for (held in _graph.heldFiles()) collectMade(held.file, held.source, held.tree, null, out);
		_made = out;
		return out;
	}

	/**
	 * Adds to `out` every type `node`'s subtree, in `file` of `source` and `parent` holding it, makes an object of or reads
	 * as a class value — a type name read as anything but the receiver of a member access, the static ones — and to
	 * `_unresolvedMade` every name a `new` there makes that resolves to no type (`unresolvedMade`).
	 */
	private function collectMade(file: String, source: String, node: QueryNode, parent: Null<QueryNode>, out: Array<String>): Void {
		final name: Null<String> = node.name;
		final written: Null<String> = if (node.kind == _shape.newExprKind)
			name
		else if (node.kind == _shape.callKind)
			resolvedLiteral(source, node)
		else if (
			(node.kind == _shape.identKind || FieldWrites.accessKind(node.kind, _shape)) && name != null && CallGraphNames.isTypeLike(name)
			&& !(parent != null && FieldWrites.accessKind(parent.kind, _shape) && parent.children[0] == node)
		)
			name
		else
			null;
		if (written != null) for (t in namedTypes(file, written)) if (!out.contains(t)) out.push(t);
		if (name != null && node.kind == _shape.newExprKind && unresolvedMade(file, name) && !_unresolvedMade.contains(name))
			_unresolvedMade.push(name);
		for (c in node.children) collectMade(file, source, c, node, out);
	}

	/**
	 * The class name a literal handed to `Type.resolveClass` names, in the call `call` of `source` — called off any
	 * receiver or bare, a literal names its one class whatever `reflectiveClasses` says; null for any other call.
	 */
	private function resolvedLiteral(source: String, call: QueryNode): Null<String> {
		final callee: Null<QueryNode> = call.children[0];
		final resolving: Bool = callee != null && callee.name == RESOLVE_CLASS && call.children.length > 1
			&& (callee.kind == _shape.identKind || FieldWrites.accessKind(callee.kind, _shape));
		return resolving ? _plugin.stringFoldSupport()?.literalOf(call.children[1], source)?.content : null;
	}

	/**
	 * The keys the name `written` may mean in `file` (`CallGraph.typeKeysOf`): the one the file binds it to, then each
	 * one an `#if`-guarded statement or a wildcard may bind it to instead — itself when nothing binds it.
	 */
	private function keysOf(file: String, written: String): Array<String> {
		final keys: Array<String> = _graph.typeKeysOf(file, written);
		return keys.length == 0 ? [written] : keys;
	}

	/**
	 * Whether the name `written` a `new` in `file` makes resolves to no type, so it may be an alias of any: a typedef alias
	 * it may mean standing for a name the run declares nowhere and the std core at none of its top-level modules (its target
	 * may be an alias its own file binds), or a name nothing in the file binds — no import, alias, `using`, guarded import or
	 * wildcard that may supply it — that the run declares nowhere and the std core at none of its top-level modules (a type
	 * parameter, a type the run does not hold). A path written out, and a name an import binds to a type outside the run,
	 * mean a library type, never an alias of a project one.
	 */
	private function unresolvedMade(file: String, written: String): Bool {
		for (key in keysOf(file, written)) {
			final named: String = aliased(key);
			if (named != key && !declared(named) && StdTypes.declaresModule('', named) != true) return true;
		}
		final bound: Bool = written.indexOf('.') >= 0 || _graph.typeKeysOf(file, written).length > 0;
		return !bound && !declared(written) && StdTypes.declaresModule('', written) != true;
	}

	/**
	 * What the target `target` of a reflective write, in `file` and the function `fn`, may be an object of when it is a
	 * `final` local bound to a fresh object for good — whatever it escapes to, the write stores into that object: none
	 * for a structure literal, which is no class's; for `new C(…)` of a class declared once, `C` and its chain. Null for
	 * any other target.
	 */
	private function freshPlacement(file: String, fn: Null<String>, target: QueryNode): Null<Placement> {
		final init: Null<QueryNode> = finalInitializer(file, target);
		if (init == null) return null;
		if (init.kind == _shape.objectLiteralKind) return { reaches: [], by: 'a fresh structure' };
		if (init.kind != _shape.newExprKind) return null;
		final index: Null<SymbolIndex> = _graph.index;
		final made: String = aliased(CallGraphNames.lastSegments(init.name ?? '', 1));
		final decl: Null<ResolvedType> = index == null ? null : onlyDeclaration(index, made);
		return index == null || decl == null || !(_shape.classDeclKinds ?? []).contains(decl.type.kind) || fn != null
			&& _graph.typeParamBoundsOf(fn, made) != null
			? null
			: { reaches: index.subtypes.supertypeNamesClosure(made), by: 'a fresh $made' };
	}

	/** The initializer of the `final` local the identifier `node`, in `file`, names; null for any other value. */
	private function finalInitializer(file: String, node: QueryNode): Null<QueryNode> {
		final value: QueryNode = BoolExprShape.unwrapParens(node, _shape.parenKind);
		final name: Null<String> = value.name;
		final at: Null<Span> = value.span;
		final tree: Null<QueryNode> = _graph.treeOf(file);
		if (value.kind != _shape.identKind || name == null || at == null || tree == null) return null;
		final from: Null<Int> = TypeResolver.resolveBindingFrom(name, at, tree, _shape);
		final mutable: Array<String> = (_shape.mutableLocalDeclKinds ?? []).concat(_shape.localDeclContinuationKinds ?? []);
		final finals: Array<String> = [for (k in _shape.localDeclKinds ?? []) if (!mutable.contains(k)) k];
		final decl: Null<QueryNode> = from == null ? null : holderOf(tree, from, n -> n.span?.from == from && finals.contains(n.kind));
		final init: Null<QueryNode> = decl == null || decl.children.length == 0 ? null : decl.children[decl.children.length - 1];
		return init == null ? null : BoolExprShape.unwrapParens(init, _shape.parenKind);
	}

	/**
	 * The enum a `case` pattern `pattern` of `file`, whose tree is `tree`, builds with the constructor `ctor`: the one the
	 * switch subject is declared of (`subjectType`, through the file's imports and typedef aliases), when it declares
	 * `ctor` and the pattern is a top-level one of its arm — an alternative of it included. Null otherwise: a constructor
	 * matched by name alone may be another enum's (a library `Option`'s `Some` beside a project enum's).
	 */
	private function subjectEnum(
		file: String, tree: QueryNode, pattern: QueryNode, ctor: String, subjectType: (QueryNode) -> Null<String>
	): Null<String> {
		final span: Null<Span> = pattern.span;
		if (span == null) return null;
		final at: Span = span;
		final switchKinds: Array<String> = _shape.switchKinds ?? [];
		final held: Null<QueryNode> = holderOf(tree, at.from, n -> switchKinds.contains(n.kind));
		if (held == null || held.children.length == 0) return null;
		final arm: Null<QueryNode> = held.children.find(c -> c.kind == _shape.caseBranchKind && holds(c, at));
		if (arm == null || !CasePatterns.patternRun(arm, _shape).exists(r -> r.children.exists(c -> topPattern(c, pattern)))) return null;
		final written: Null<String> = subjectType(BoolExprShape.unwrapParens(held.children[0], _shape.parenKind));
		final outer: Null<String> = written == null ? null : NominalTypes.outerNominalOf(written, _plugin.typeSyntax);
		// a subject type the file may mean another type by on some builds types no capture
		final keys: Array<String> = outer == null ? [] : keysOf(file, outer);
		final named: Null<String> = keys.length == 1 ? aliased(keys[0]) : null;
		final index: Null<SymbolIndex> = _graph.index;
		// the ONE enum declaration of the name declares the constructor: two enums of one name type no capture
		final decl: Null<ResolvedType> = index == null || named == null ? null : onlyDeclaration(index, named);
		final ctorKinds: Array<String> = _shape.execution?.enumConstructorKinds ?? [];
		return decl != null && decl.type.members.exists(m -> m.name == ctor && ctorKinds.contains(m.kind)) ? named : null;
	}

	/** Whether `node` is the pattern `pattern` or an alternative (`A(x) | B(x)`) holding it as one of its own. */
	private function topPattern(node: QueryNode, pattern: QueryNode): Bool {
		return node == pattern || node.kind == _shape.orPatternKind && node.children.exists(c -> topPattern(c, pattern));
	}

	/** The names a `case` pattern of `file`, whose tree is `tree`, captures. */
	private function capturesOf(file: String, tree: QueryNode): Array<String> {
		final known: Null<Array<String>> = _captures[file];
		if (known != null) return known;
		final names: Array<String> = BinderScan.casePatternCaptures(tree, _shape);
		_captures[file] = names;
		return names;
	}

	/** The simple name `name` stands for through its typedef aliases (`TypeRefIndex.aliasedName`); itself with no index. */
	private function aliased(name: String): String {
		return _graph.index?.refs.aliasedName(name) ?? name;
	}

	/** Whether the graph's index declares a type of the name `name`. */
	private function declared(name: String): Bool {
		return (_graph.index?.refs.declsNamed(name) ?? []).length > 0;
	}

	/**
	 * The classes a class value made from a computed name may be of, as the project declares them (`reflectiveClasses`,
	 * its responsibility): the one list the config of every file of `files` declares, each resolved by `resolve`; null when
	 * a file declares none or another list, and such a value may then be of any class.
	 */
	public static inline function declaredClasses(
		files: Array<{ file: String, source: String }>, resolve: Null<(String) -> LintConfig>
	): Null<Array<String>> {
		return declaredGlobs(files, resolve, c -> c.reflectiveClasses());
	}

	/**
	 * The classes whose methods a read of a computed name may obtain, as the project declares them
	 * (`reflectiveMethodHolders`): the one list the config of every file of `files` declares, each resolved by `resolve`;
	 * null when a file declares none or another list, and such a read may then obtain any method.
	 */
	public static inline function declaredMethodHolders(
		files: Array<{ file: String, source: String }>, resolve: Null<(String) -> LintConfig>
	): Null<Array<String>> {
		return declaredGlobs(files, resolve, c -> c.reflectiveMethodHolders());
	}

	/**
	 * Whether `name` is a class or an interface `index` declares once (`RefShape.classDeclKinds` / `interfaceDeclKinds`) —
	 * a type whose subtypes and chain the index lists, unlike an abstract, a structure or a library type.
	 */
	public static function classLike(index: SymbolIndex, shape: RefShape, name: String): Bool {
		final decl: Null<ResolvedType> = onlyDeclaration(index, name);
		return decl != null
			&& ((shape.classDeclKinds ?? []).contains(decl.type.kind) || (shape.interfaceDeclKinds ?? []).contains(decl.type.kind));
	}

	/** The ONE declaration `index` holds of the name `name`, null for none or several. */
	public static function onlyDeclaration(index: SymbolIndex, name: String): Null<ResolvedType> {
		final decls: Array<ResolvedType> = index.refs.resolvedDeclsNamed(name);
		return decls.length == 1 ? decls[0] : null;
	}

	/** `from` and every type `next` reaches from it, step by step: the closure of `next` over `from`. */
	public static function closure(from: Array<String>, next: (String) -> Array<String>): Array<String> {
		final out: Array<String> = from.copy();
		var at: Int = 0;
		while (at < out.length) {
			for (t in next(out[at])) if (!out.contains(t)) out.push(t);
			at++;
		}
		return out;
	}

	/** The innermost node `test` accepts whose span holds the offset `from`, in `node`'s subtree; null when none does. */
	public static function holderOf(node: QueryNode, from: Int, test: (QueryNode) -> Bool): Null<QueryNode> {
		final at: Null<Span> = node.span;
		if (at != null && (from < at.from || from >= at.to)) return null;
		for (c in node.children) {
			final hit: Null<QueryNode> = holderOf(c, from, test);
			if (hit != null) return hit;
		}
		return test(node) ? node : null;
	}

	/**
	 * The one list of globs `read` takes off the config of every file of `files`, each resolved by `resolve`; null when a
	 * file declares none or another list.
	 */
	private static function declaredGlobs(
		files: Array<{ file: String, source: String }>, resolve: Null<(String) -> LintConfig>, read: (LintConfig) -> Null<Array<String>>
	): Null<Array<String>> {
		final lists: Array<Null<Array<String>>> = [for (f in files) read(LintConfig.resolveWith(resolve, f.file))];
		final first: Null<Array<String>> = lists.length == 0 ? null : lists[0];
		return first != null && lists.foreach(l -> l != null && l.join('\n') == first.join('\n')) ? first : null;
	}

	/** Whether the span of `node` holds the span `at`. */
	private static function holds(node: QueryNode, at: Span): Bool {
		final own: Null<Span> = node.span;
		return own != null && own.from <= at.from && at.to <= own.to;
	}

}
