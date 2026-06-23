package anyparse.query;

/**
 * Optional capability a `GrammarPlugin` may ALSO implement to expose declared-
 * type information the simplified `QueryNode` projection drops. A grammar that
 * does not implement it leaves every type unresolved, so consumers `Std.downcast`
 * to it and fall back to their conservative default when it is absent — never
 * required of a plugin.
 */
@:nullSafety(Strict)
interface TypeInfoProvider {

	/**
	 * Maps each declaration's binding-span start offset (the same `from` a
	 * scope-resolved reference binds to — see `Refs.RefHit.bindingSpan`) to the
	 * SIMPLE name of its declared type, for every local / parameter / field that
	 * carries an explicit nominal `:Type` annotation. A declaration with no
	 * annotation, or a non-nominal type (function / anonymous-inline /
	 * parametric / `Null<…>` wrapper), is absent — its receiver stays
	 * unresolved. Recovers a `recv.field` receiver's type without changing the
	 * shared `QueryNode` shape.
	 */
	public function declaredTypes(source: String): Map<Int, String>;

}
