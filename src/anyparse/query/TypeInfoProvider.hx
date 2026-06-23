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

	/**
	 * Maps a property-bearing member's binding-span `from` to whether its read
	 * accessor is a getter (`get` / `dynamic` → true) vs a plain stored read. A
	 * plain field (no accessor clause) is ABSENT. Lets a consumer decide whether
	 * `value.field` is a side-effect-free read once the member is located.
	 */
	public function propertyAccessors(source: String): Map<Int, Bool>;

}
