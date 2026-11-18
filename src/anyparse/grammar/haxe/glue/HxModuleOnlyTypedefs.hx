package anyparse.grammar.haxe.glue;

using Lambda;

/**
 * The one answer to "does a module declare nothing but typedefs" — the fact the `moduleOnlyTypedefs` wrap condition reads
 * (`WrapListOptions.moduleOnlyTypedefs`).
 *
 * `package`, `import` and `using` lines do not count against the answer, and neither does a top-level element that holds
 * no declaration (a trailing metadata-only region). A `#if` region holds when every one of its arms does; any other
 * declaration (a class, interface, enum, abstract, function, variable, a shared-body region or a parse error) refuses.
 * Where the walk cannot tell (past `MAX_DEPTH`) it answers "no", the direction that leaves a layout as it is.
 *
 * Reached from the writer lowering as the `moduleHoldsOnlyTypedefs` predicate (`HxAstPredLowering.moduleOnlyTypedefsField`).
 * Untyped input for the same reason as `HxTypeParamItems`: the plain and the trivia-synth module types both arrive here,
 * the latter with each Star element in its `{node: …}` wrapper, so the walk goes by constructor and field names.
 */
final class HxModuleOnlyTypedefs {

	/** Depth ceiling of the `#if` nesting walk. */
	private static inline final MAX_DEPTH: Int = 64;

	/** Whether every top-level element of `decls` is a typedef, or a `package` / `import` / `using` line. */
	public static inline function holds(decls: Array<Any>): Bool {
		return elementsHold(decls, 0);
	}

	private static function elementsHold(elements: Null<Any>, depth: Int): Bool {
		return !Std.isOfType(elements, Array) || (cast elements: Array<Any>).foreach(element -> elementHolds(element, depth));
	}

	private static function elementHolds(element: Any, depth: Int): Bool {
		final decl: Null<Any> = Reflect.field(unwrap(element), 'decl');
		if (decl == null) return true;
		if (depth > MAX_DEPTH) return false;
		return switch Type.enumConstructor(decl) {
			case 'TypedefDecl', 'PackageDecl', 'PackageEmpty', 'ImportDecl', 'ImportWildDecl', 'ImportAliasDecl', 'ImportAliasInDecl',
				'UsingDecl', 'UsingWildDecl':
				true;
			case 'Conditional': armsHold(Type.enumParameters(decl)[0], depth + 1);
			case _: false;
		};
	}

	/** Every arm of one `#if` region — its body, each `#elseif` body and the `#else` body — holds. */
	private static function armsHold(region: Any, depth: Int): Bool {
		final elseifs: Null<Any> = Reflect.field(region, 'elseifs');
		return elementsHold(Reflect.field(region, 'body'), depth)
			&& (!Std.isOfType(elseifs, Array)
				|| (cast elseifs: Array<Any>).foreach(arm -> elementsHold(Reflect.field(unwrap(arm), 'body'), depth)))
			&& elementsHold(Reflect.field(region, 'elseBody'), depth);
	}

	/** The element a trivia-synth Star wraps in `{node: …}`, or the value itself. */
	private static function unwrap(v: Any): Any {
		return Reflect.field(v, 'node') ?? v;
	}

}
