package anyparse.query;

/**
 * Optional batched capability a `GrammarPlugin` may ALSO implement alongside
 * `TypeInfoProvider`: it returns the six span-indexed type-info maps from ONE
 * parse of a source, where the per-map `TypeInfoProvider` accessors each re-parse
 * independently. A caching decorator uses it to memoize a file's six maps at the
 * cost of a single span-parse; a plugin that does not implement it just keeps the
 * per-map accessors. Separated from `TypeInfoProvider` so the two capabilities are
 * independently optional and a plugin can opt into the batched form on its own.
 */
@:nullSafety(Strict)
interface SpanTypeInfoProvider {

	/**
	 * The six span-indexed maps (`declaredTypes` / `returnTypes` / `propertyAccessors` /
	 * `propertyWriteAccessors` / `declaredTypeSources` / `castTargetSources`) computed in
	 * one parse. Each map is byte-for-byte the like-named `TypeInfoProvider`
	 * accessor's result.
	 */
	public function spanTypeInfo(source: String): SpanTypeInfo;

}

/**
 * The six span-indexed type-info maps a `SpanTypeInfoProvider` derives from ONE
 * parse of a source. Each field is exactly the map the like-named
 * `TypeInfoProvider` accessor returns; bundling them lets a caching decorator
 * compute a file's six maps from a single span-parse instead of six.
 */
typedef SpanTypeInfo = {
	final declaredTypes: Map<Int, String>;
	final returnTypes: Map<Int, String>;
	final propertyAccessors: Map<Int, Bool>;
	final propertyWriteAccessors: Map<Int, Bool>;
	final declaredTypeSources: Map<Int, String>;
	final castTargetSources: Map<Int, String>;
};
