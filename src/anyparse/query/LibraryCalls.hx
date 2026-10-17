package anyparse.query;

import anyparse.query.GrammarPlugin.ExecutionShape;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * What a call into LIBRARY code may run, read off the library's own declarations: a listed pure call
 * (`isPureLibrary`), a built-in container method that calls nothing it is handed (`runsNoUserCode`,
 * `callsItsArgument`), an extern whose target code can only have been handed inert values (`externClosed`,
 * `externQuiet`, `externTakesObject`), and which types are inert at all (`inertType`).
 *
 * Its own module rather than more of `ReachGraph` because none of it depends on how the graph grows: each answer is
 * a function of the project scope's declarations and the grammar's `ExecutionShape`, memoised per type. The graph
 * holds one (`ReachGraph.library`) and every reach analysis asks it there.
 */
@:nullSafety(Strict)
final class LibraryCalls {

	private final _scope: ReachProject;

	/** Extern type -> whether it is closed over inert values (`externClosed`). */
	private final _externClosed: Map<String, Bool> = [];

	/** Type -> whether a program type extending it overrides a method (`overriddenBelow`), settled on first need. */
	private final _overriddenBelow: Map<String, Bool> = [];

	public function new(scope: ReachProject) {
		_scope = scope;
	}

	/**
	 * Whether `type.name` is a library call known to run no user code (`ExecutionShape.pureLibraryCalls`): listed,
	 * declared by the indexed library type itself (not a type the project declares), and — read off that
	 * declaration — taking only parameters of a type whose values run nothing when the call converts or calls
	 * them (`inertType`). A parameter of a type parameter, `Dynamic` or an object type may be handed a value
	 * whose `toString` the call runs; `args`, when the call site is known, excuses one that is handed a string
	 * literal.
	 */
	public function isPureLibrary(g: CallGraph, type: String, name: String, ?args: Array<QueryNode>): Bool {
		if (
			!(
				(_scope.shape.execution?.pureLibraryCalls ?? []).contains('$type.$name')
				|| (_scope.shape.execution?.pureLibraryTypes ?? []).contains(type)
			)
		)
			return false;
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(type);
		final info: Null<MemberInfo> = g.types.memberOnChain(type, name);
		if (site == null || _scope.sources.exists(site.file) || info == null) return false;
		final params: Array<Null<String>> = info.paramTypeSources;
		final literals: Array<String> = _scope.shape.stringLiteralKinds ?? [];
		for (i => param in params) {
			final arg: Null<QueryNode> = args == null || i >= args.length ? null : args[i];
			if (!(param != null && inertType(param)) && !(arg != null && literals.contains(arg.kind))) return false;
		}
		return true;
	}

	/**
	 * Whether a call of the library member `type.name` runs no project code: a pure library call, or a method
	 * of the built-in array type that calls no argument and returns no string — any of them, or with `mutatorsToo`
	 * false only the non-mutating ones. A built-in map's own methods (`ExecutionShape.mapTypeNames`) answer the same way,
	 * while no project type extends the map type: a subclass may override what the method calls (`BalancedTree.compare`).
	 */
	public function runsNoUserCode(g: CallGraph, type: String, name: String, mutatorsToo: Bool): Bool {
		if (isPureLibrary(g, type, name)) return true;
		final execution: Null<ExecutionShape> = _scope.shape.execution;
		final array: Bool = (_scope.shape.arrayTypeNames ?? []).contains(type);
		final map: Bool = !array && (execution?.mapTypeNames ?? []).contains(type) && !projectSubtype(type);
		if (!(array || map) || callsItsArgument(g, type, name)) return false;
		// a method returning a string converts the elements to one (`join`): an element's `toString` runs
		if (g.types.memberOnChain(type, name)?.returnNominal == stringTypeName()) return false;
		final reads: Null<Array<String>> = array ? execution?.nonMutatingArrayMethods : execution?.nonMutatingMapMethods;
		final changes: Null<Array<String>> = array ? execution?.mutatingArrayMethods : execution?.mutatingMapMethods;
		return (reads ?? []).contains(name) || (mutatorsToo && (changes ?? []).contains(name));
	}

	/** Whether a type declared outside the standard library extends or implements `type`. */
	private function projectSubtype(type: String): Bool {
		return _scope.index.subtypes.subtypeFiles(type).exists(f -> !StdResolver.isStdFile(f));
	}

	/**
	 * Whether a call of `type.name` may CALL a value it is handed, read off the indexed declaration: a parameter
	 * whose written type is not a nominal (a function type `T->S`), a catch-all (`Dynamic`, `Any`), or a type
	 * that may alias a function (a typedef or abstract, or one the index does not declare — `holdsNoFunction`)
	 * can be called. A parameter typed by one of the declaring type's own type parameters cannot: nothing is
	 * known to be callable about it. True when the declaration is not indexed or a parameter is untyped.
	 */
	public function callsItsArgument(g: CallGraph, type: String, name: String): Bool {
		final info: Null<MemberInfo> = g.types.memberOnChain(type, name);
		if (info == null) return true;
		final catchAll: Array<String> = _scope.shape.catchAllTypeNames ?? [];
		final ownParams: Array<String> = g.types.generics.typeParamsOf(type);
		for (param in info.paramTypeSources) {
			final nominal: Null<String> = param == null
				? null
				: NominalTypes.outerNominalOf(
					NominalTypes.unwrapNullable(
						StringTools.trim(param), _scope.shape.memberTransparentWrapperTypeNames ?? [], _scope.plugin.typeSyntax
					),
					_scope.plugin.typeSyntax
				);
			if (nominal == null || catchAll.contains(nominal)) return true;
			if (!ownParams.contains(nominal) && !g.types.holdsNoFunction(nominal)) return true;
		}
		return false;
	}

	/**
	 * Whether the extern `type` is CLOSED over inert values: every member its declarations on the chain carry —
	 * field, parameter, return — is typed with an inert type (`inertType`), `Void`, or the type itself. Target
	 * code behind such a type can only have been handed numbers, strings and its own instances, so it holds no
	 * array or function value of the program to change or call. False when a declaration is not indexed.
	 */
	public function externClosed(g: CallGraph, type: String): Bool {
		final cached: Null<Bool> = _externClosed[type];
		if (cached != null) return cached;
		var closed: Bool = g.types.meta.isExtern(type);
		var t: Null<String> = type;
		final seen: Array<String> = [];
		while (closed && t != null && !seen.contains(t)) {
			final current: String = t;
			seen.push(current);
			final decl: Null<TypeDeclInfo> = _scope.declarationOf(current);
			if (decl == null) {
				closed = false;
				break;
			}
			final own: String -> Bool = written -> {
				final nominal: Null<String> = NominalTypes.outerNominalOf(StringTools.trim(written), _scope.plugin.typeSyntax);
				inertType(written) || nominal == current || nominal == type || nominal == _scope.shape.voidTypeName;
			};
			for (m in decl.members) {
				final written: Array<Null<String>> = m.paramTypeSources.concat([m.typeSource, m.returnNominal]);
				for (w in written) if (w != null && !own(w)) closed = false;
			}
			t = g.types.superclassOf(current);
		}
		_externClosed[type] = closed;
		return closed;
	}

	/**
	 * Whether the body-less extern member `type.name` runs no program code and changes no program value: its
	 * type is closed over inert values (`externClosed`), or it is a method the language calls IMPLICITLY — a
	 * conversion, an iteration step, an operator — that takes no value it could call (`callsItsArgument`). The
	 * second rests on a stated assumption: target code the language runs implicitly converts or steps its own
	 * receiver and calls back into the program only through a function value it is handed. Neither holds for an
	 * instance member whose receiver may be an instance of a program class overriding a method (`overriddenBelow`):
	 * target code running on it may call that method, as a virtual dispatch does.
	 */
	public function externQuiet(g: CallGraph, type: String, name: String): Bool {
		final info: Null<MemberInfo> = g.types.memberOnChain(type, name);
		if (info != null && !info.isStatic && overriddenBelow(type)) return false;
		if (externClosed(g, type)) return true;
		final byName: Bool = info != null && !info.isStatic && (_scope.shape.execution?.implicitCallNames ?? []).contains(name);
		return info != null && (info.isImplicitCall || byName) && !callsItsArgument(g, type, name);
	}

	/**
	 * Whether a type extending `type` that is no extern overrides a method — an instance of it is one of `type`, whose target
	 * code may call the override — or a type extending it is not declared once, so nothing here says.
	 */
	private function overriddenBelow(type: String): Bool {
		final cached: Null<Bool> = _overriddenBelow[type];
		if (cached != null) return cached;
		final found: Bool = _scope.index.subtypes.subtypeNames(type).exists(s -> {
			final decl: Null<TypeDeclInfo> = _scope.declarationOf(s);
			decl == null || (!decl.isExtern && decl.members.exists(m -> m.isOverride));
		});
		_overriddenBelow[type] = found;
		return found;
	}

	/**
	 * Whether the body-less extern member `type.name` may be HANDED a program object: a parameter written with a type
	 * that is neither inert (`inertType`) nor a function type, or with none. Target code reaches such an object's
	 * members by name — a `toJSON`, a `toString`, a `then` — without any call the graph can see.
	 */
	public function externTakesObject(g: CallGraph, type: String, name: String): Bool {
		final info: Null<MemberInfo> = g.types.memberOnChain(type, name);
		return info == null
			|| info.paramTypeSources.exists(p -> p == null || (_scope.plugin.typeSyntax(p)?.holdsFunction() != true && !inertType(p)));
	}

	/** The language's string type: what a string literal is (`RefShape.literalTypeNames`). */
	public function stringTypeName(): Null<String> {
		return (_scope.shape.literalTypeNames ?? [])[(_scope.shape.stringLiteralKinds ?? [])[0] ?? ''];
	}

	/** Whether a value written `typeSource` runs no code when a call converts it to a string: a string, number or boolean. */
	public function inertType(typeSource: String): Bool {
		final nominal: Null<String> = NominalTypes.outerNominalOf(
			NominalTypes.unwrapNullable(typeSource.trim(), _scope.shape.memberTransparentWrapperTypeNames ?? [], _scope.plugin.typeSyntax),
			_scope.plugin.typeSyntax
		);
		final values: Array<String> =
			[for (t in (_scope.shape.literalTypeNames ?? []).iterator()) t].concat(_scope.shape.nonNullableTypeNames ?? []);
		return _scope.plugin.typeSyntax(typeSource)?.holdsFunction() != true && nominal != null && values.contains(nominal);
	}

}
