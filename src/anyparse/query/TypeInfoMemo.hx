package anyparse.query;

/**
 * Lazily memoized per-file tables off a `TypeInfoProvider`. Each member answers a thunk that computes its
 * table on the first call and caches it, so a caller that never reaches the resolution path never pays
 * for the parse behind it, and a null provider (a grammar without type information) yields the empty map.
 * The cache lives in the thunk alone — run-scoped, never a static (`docs/design-principles.md` § 2).
 */
@:nullSafety(Strict)
final class TypeInfoMemo {

	/** The span→written-type-source table the identifier-type resolvers consume. */
	public static function declaredTypeSources(provider: Null<TypeInfoProvider>, source: String): () -> Map<Int, String> {
		return table(provider, source, (p, s) -> p.declaredTypeSources(s));
	}

	/** The span→cast-target table a cast-aware proof reads; recovering it costs a second full parse of the file. */
	public static function castTargetSources(provider: Null<TypeInfoProvider>, source: String): () -> Map<Int, String> {
		return table(provider, source, (p, s) -> p.castTargetSources(s));
	}

	/** The binding-span→accessor table of every property declared with an accessor clause, whatever it names. */
	public static function propertyAccessors(provider: Null<TypeInfoProvider>, source: String): () -> Map<Int, Bool> {
		return table(provider, source, (p, s) -> p.propertyAccessors(s));
	}

	private static function table<V>(
		provider: Null<TypeInfoProvider>, source: String, read: (provider: TypeInfoProvider, source: String) -> Map<Int, V>
	): () -> Map<Int, V> {
		var cache: Null<Map<Int, V>> = null;
		return function(): Map<Int, V> {
			final existing: Null<Map<Int, V>> = cache;
			if (existing != null) return existing;
			final p: Null<TypeInfoProvider> = provider;
			final computed: Map<Int, V> = p != null ? read(p, source) : [];
			cache = computed;
			return computed;
		};
	}

}
