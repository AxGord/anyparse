package anyparse.check;

import anyparse.query.BinderScan;
import anyparse.query.BoolExprShape;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphNames;
import anyparse.query.CallGraphTypes;
import anyparse.query.Glob;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex.MemberInfo;
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
 * What the target of a reflective write may be an object of (`FieldWrites`): the classes its declared type places it on,
 * with their subtypes and chains; else what a POSITIVE exclusion proves of a value whose declared type places it on no
 * class — each a whitelist entry with its reason (`Placement.by`), anything else any type's. The exclusions: a `final`
 * local bound to a fresh structure or object, a type parameter bounded by its constraint or by every instantiation of its
 * class, a `case` capture typed by the parameter of its enum constructor (`binderType`).
 */
@:nullSafety(Strict)
final class ReflectiveReach {

	/**
	 * The globs naming every class a class value made from a computed name may be of (`reflectiveClasses`, the one list
	 * every file of the run declares); null when undeclared, and such a value may then be of any class.
	 */
	private final _reflectiveClasses: Null<Array<String>>;

	/** Each class or interface -> the types whose fields a write on a value of it may reach (`reachOf`). */
	private final _reach: Map<String, Array<String>> = [];

	/** Each class type parameter (`Type.T`) -> what its instantiations bound it to (`instantiated`); null for unbounded. */
	private final _instantiations: Map<String, Null<Array<String>>> = [];

	/** Each file -> the names a `case` pattern of it captures (`binderType`). */
	private final _captures: Map<String, Array<String>> = [];

	private final _graph: CallGraph;

	private final _plugin: GrammarPlugin;

	private final _shape: RefShape;

	/** Whether the run sees every type and every write of the project (`FieldWrites.complete`). */
	private final _complete: Bool;

	public function new(graph: CallGraph, plugin: GrammarPlugin, complete: Bool, ?reflectiveClasses: Array<String>) {
		_graph = graph;
		_plugin = plugin;
		_shape = plugin.refShape();
		_complete = complete;
		_reflectiveClasses = reflectiveClasses;
	}

	/**
	 * The classes a class value made from a computed name may be of, as the project declares them (`reflectiveClasses`,
	 * its responsibility): the one list the config of every file of `files` declares, each resolved by `resolve`; null when
	 * a file declares none or another list, and such a value may then be of any class.
	 */
	public static function declaredClasses(
		files: Array<{ file: String, source: String }>, resolve: Null<(String) -> LintConfig>
	): Null<Array<String>> {
		final lists: Array<Null<Array<String>>> = [for (f in files) LintConfig.resolveWith(resolve, f.file).reflectiveClasses()];
		final first: Null<Array<String>> = lists.length == 0 ? null : lists[0];
		return first != null && lists.foreach(l -> l != null && l.join('\n') == first.join('\n')) ? first : null;
	}

	/**
	 * What the target `target` of a reflective write, in `file` and the function `fn`, declared `type`, may be an object
	 * of: what that type places it on (`reachOf`), else what a POSITIVE exclusion proves — a type parameter its
	 * constraint or every instantiation of its type bounds (`typeParamPlacement`), a `final` local bound to a fresh
	 * structure or object (`freshPlacement`); any type's for anything else.
	 */
	public function placeOf(file: String, fn: Null<String>, target: QueryNode, type: Null<String>): Placement {
		final param: Null<Placement> = type == null || fn == null ? null : typeParamPlacement(fn, CallGraphNames.lastSegments(type, 1));
		if (param != null) return param;
		final reaches: Null<Array<String>> = reachOf(type, fn);
		if (reaches != null) return { reaches: reaches, by: null };
		return freshPlacement(file, fn, target) ?? { reaches: null, by: null };
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

	/**
	 * The types a value of one of the written types `sources` may be an object of, together (`reachOf`): none for the
	 * void type, which holds no value; null when one of them is any type's.
	 */
	private function reachOfSources(sources: Array<String>): Null<Array<String>> {
		final out: Array<String> = [];
		for (written in sources) {
			final outer: Null<String> = NominalTypes.outerNominalOf(written, _plugin.typeSyntax);
			if (outer != null && outer == _shape.voidTypeName) continue;
			final reach: Null<Array<String>> = reachOf(outer, null);
			if (reach == null) return null;
			for (t in reach) if (!out.contains(t)) out.push(t);
		}
		return out;
	}

	/**
	 * What a value of the type parameter `name` of the class or interface `type` may be an object of, bounded by every
	 * instantiation of it — null, any type's, unless the run sees every type and every write of the project (`complete`, as `FieldWrites` has it):
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
		final types: CallGraphTypes = _graph.types;
		final at: Int = types.generics.typeParamsOf(type).indexOf(name);
		if (at < 0 || types.declarationCount(type) != 1 || !(types.meta.isClass(type) || types.isInterface(type))) return null;
		final out: Array<String> = [];
		final free: Array<String> = [type];
		for (sub in closure([type], types.subtypesOf)) if (sub != type) {
			final args: Null<Array<String>> = types.generics.argumentsFor(type, sub, _plugin.typeSyntax);
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
	 * Whether no object of the type `type` is ever made, so none takes a type argument nothing here reads: no `new` of
	 * it, its name read as no value (a class value handed on may reach `Type.createInstance`), and the project declares
	 * the classes a class value made from a computed name may be of (`reflectiveClasses`) without naming it — a library
	 * making one from such a name (an unserializer) is covered by that declaration too.
	 */
	private function neverMade(type: String): Bool {
		final globs: Null<Array<String>> = _reflectiveClasses;
		final paths: Array<String> = _graph.types.imports.declaredPathsOf(type);
		if (globs == null || paths.length == 0 || paths.exists(p -> globs.exists(g -> Glob.qualifiedNames(g).match(p)))) return false;
		return !_graph.heldFiles().exists(held -> makes(held.tree, null, type));
	}

	/**
	 * Whether `node`'s subtree, `parent` holding it, makes an object of `type` by `new` or reads its name as a value — as
	 * anything but the receiver of a member access, the static ones.
	 */
	private function makes(node: QueryNode, parent: Null<QueryNode>, type: String): Bool {
		final made: Bool = node.kind == _shape.newExprKind
			? CallGraphNames.lastSegments(node.name ?? '', 1) == type
			: (node.kind == _shape.identKind || FieldWrites.accessKind(node.kind, _shape)) && node.name == type
				&& !(parent != null && FieldWrites.accessKind(parent.kind, _shape) && parent.children[0] == node);
		return made || node.children.exists(c -> makes(c, node, type));
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
		final types: CallGraphTypes = _graph.types;
		final made: String = types.resolveAlias(CallGraphNames.lastSegments(init.name ?? '', 1));
		if (types.declarationCount(made) != 1 || !types.meta.isClass(made) || fn != null && _graph.typeParamBoundsOf(fn, made) != null)
			return null;
		return { reaches: closure([made], types.supertypesOf), by: 'a fresh $made' };
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
	 * The written type of the enum-constructor parameter a `case` capture `value`, in `file`, binds (`Ctor(a, b)`): when
	 * one indexed enum declares a constructor of that name, with as many parameters as the pattern; null for any other
	 * value.
	 */
	public function binderType(file: String, value: QueryNode): Null<String> {
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
		final enums: Array<String> = _graph.types.imports.enumsDeclaring(ctor);
		final info: Null<MemberInfo> = enums.length == 1 ? _graph.types.memberOnChain(enums[0], ctor) : null;
		final arity: Int = pattern.children.length - 1;
		if (info == null || info.paramTypeSources.length != arity) return null;
		final written: Null<String> = info.paramTypeSources[pattern.children.findIndex(c -> c.span?.from == from) - 1];
		return written == null ? null : NominalTypes.outerNominalOf(written, _plugin.typeSyntax);
	}

	/** The names a `case` pattern of `file`, whose tree is `tree`, captures. */
	private function capturesOf(file: String, tree: QueryNode): Array<String> {
		final known: Null<Array<String>> = _captures[file];
		if (known != null) return known;
		final names: Array<String> = BinderScan.casePatternCaptures(tree, _shape);
		_captures[file] = names;
		return names;
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

	/** The innermost node `test` accepts whose span holds the offset `from`, in `node`'s subtree; null when none does. */
	private static function holderOf(node: QueryNode, from: Int, test: (QueryNode) -> Bool): Null<QueryNode> {
		final at: Null<Span> = node.span;
		if (at != null && (from < at.from || from >= at.to)) return null;
		for (c in node.children) {
			final hit: Null<QueryNode> = holderOf(c, from, test);
			if (hit != null) return hit;
		}
		return test(node) ? node : null;
	}

}
