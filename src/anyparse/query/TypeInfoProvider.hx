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
	 * Maps each FUNCTION declaration's binding-span `from` (the same `from` a
	 * scope-resolved call callee binds to) to the SIMPLE outer-nominal name of its
	 * declared return type — `function f():Null<Foo>` → `Null`, `:Array<Int>` →
	 * `Array`. The return-type counterpart of `declaredTypes` (which covers
	 * value-carrying `:Type` fields, whose grammar field is `type`, NOT a
	 * function's `returnType`). A function with no explicit return annotation, or a
	 * non-nominal return, is absent. Lets a consumer resolve a call result's
	 * nullability without the `QueryNode` projection carrying return types.
	 */
	public function returnTypes(source: String): Map<Int, String>;

	/**
	 * Maps a property-bearing member's binding-span `from` to whether its read
	 * accessor is a getter (`get` / `dynamic` → true) vs a plain stored read. A
	 * plain field (no accessor clause) is ABSENT. Lets a consumer decide whether
	 * `value.field` is a side-effect-free read once the member is located.
	 */
	public function propertyAccessors(source: String): Map<Int, Bool>;

	/**
	 * Maps a property-bearing member's binding-span `from` to whether its WRITE
	 * accessor is a setter (`set` / `dynamic` -> true) vs a plain stored write
	 * (`default` / `null` / `never`). A plain field (no accessor clause) is ABSENT.
	 * The write-side counterpart of `propertyAccessors`: lets a consumer decide
	 * whether a located member has a real set-accessor.
	 */
	public function propertyWriteAccessors(source: String): Map<Int, Bool>;

	/**
	 * Maps each declaration's binding-span `from` (the `declaredTypes` key) to the
	 * VERBATIM source text of its `:Type` annotation — `var x: Array<Int>` → the
	 * substring `Array<Int>`. Lets a consumer compare two annotations by their
	 * written form (sound within one file: a byte-identical type source denotes the
	 * same type) instead of a package-stripped simple name. A declaration with no
	 * recoverable type-annotation span is absent.
	 */
	public function declaredTypeSources(source: String): Map<Int, String>;

	/**
	 * Maps each typed-cast / type-check node's payload `span.from` to the VERBATIM
	 * source text of its TARGET type — `cast(expr, Array<Int>)` / `(expr : Array<Int>)`
	 * → `Array<Int>`. The written-form counterpart of `declaredTypes` for casts,
	 * recovered from the grammar AST that the `QueryNode` projection drops. A grammar
	 * without typed casts returns an empty map.
	 */
	public function castTargetSources(source: String): Map<Int, String>;

	/**
	 * Maps each simple type name brought into scope by a plain `import a.b.X;` to
	 * its fully-qualified path (`X` → `a.b.X`). Aliased imports (`import a.b.X as Y;` —
	 * the original path is not exposed by the grammar), wildcard imports, and `using`
	 * are excluded. Lets a consumer canonicalize a bare type reference to an FQN and
	 * thus tell `Eof` (imported `haxe.io.Eof`) from a qualified `sys.io.Eof`.
	 */
	public function importMap(source: String): Map<String, String>;

}
