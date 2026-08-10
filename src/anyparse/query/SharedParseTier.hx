package anyparse.query;

import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.query.SpanTypeInfoProvider;
import haxe.Exception;

/**
 * The PROCESS-scoped second tier behind a `CachingGrammarPlugin`'s run-scoped parse caches,
 * written by `promote` and by nothing else, so only RESOLUTION-LIBRARY sources ever enter it.
 *
 * A blanket static tier would be wrong: a `--fix` loop rewrites a report file every pass, so
 * every intermediate source would be retained for the life of the process. Library sources have
 * no such churn — they are read-only for the whole run — and keying on (language, source
 * CONTENT) means an entry can only ever be served for byte-identical input, so a library
 * directory deleted and recreated with different content under the SAME path misses and
 * re-parses. The file SET is never cached (each run re-expands its own scan roots), so two runs
 * configuring different scopes cannot see each other's library. Single-threaded by the same rule
 * as the wrapper's instance caches. The language is the OUTER key rather than part of a
 * composite one: two grammars parse the same bytes into different trees, but folding the
 * language into the key would mean building a fresh string per lookup and re-hashing the whole
 * source on every `parseFile` call.
 *
 * The five counters are this tier's instrument panel — three measure what it serves, two the
 * inner work it exists to avoid — and `ResolutionLibraryCacheTest` reads them as one set. Split
 * out of `CachingGrammarPlugin`, which keeps the run-scoped memoization and the delegation.
 */
@:nullSafety(Strict)
final class SharedParseTier {

	/** Library sources actually parsed into the shared tier — a served entry leaves this untouched (the caching-invariant tests read it). */
	public static var libraryParses(default, null): Int = 0;

	/**
	 * Shared-tier SERVES from `parseFile` — incremented inside the serve lookup itself, so it
	 * measures the lookup that saves the work rather than `promote`'s own bookkeeping. That
	 * distinction is the whole point: an earlier version counted hits in the promotion's `exists`
	 * short-circuit, so BOTH serve lookups could be deleted with the suite still green while the
	 * run got 4.5x slower.
	 */
	public static var libraryHits(default, null): Int = 0;

	/** The `spanTypeInfo` half of `libraryHits`, counted in its own serve lookup for the same reason. */
	public static var librarySpanHits(default, null): Int = 0;

	/**
	 * Wrapped-plugin `parseFile` invocations — the work the tier exists to avoid. Two runs over
	 * the same scope pay the same cost for everything EXCEPT the library the first one promoted
	 * (the report sources, and the retries of any library file that does not parse, recur
	 * identically), so run 2's delta must equal run 1's delta minus run 1's `libraryParses`.
	 * That subtraction is what "zero inner parses of library sources" means arithmetically, and
	 * it is the identity `ResolutionLibraryCacheTest` pins.
	 */
	public static var innerParses(default, null): Int = 0;

	/** Wrapped-plugin `spanTypeInfo` (or the five-accessor fallback) invocations — the span-parse twin of `innerParses`. */
	public static var innerSpanParses(default, null): Int = 0;

	private static final PARSE_TIERS: Map<String, Map<String, QueryNode>> = [];
	private static final SPAN_TIERS: Map<String, Map<String, SpanTypeInfo>> = [];

	// One wrapper's language slices of the two process-scoped tiers above, resolved once in the
	// constructor so a lookup is one map read against the caller's own source string.
	private final _parses: Map<String, QueryNode>;
	private final _spans: Map<String, SpanTypeInfo>;

	// The library array instance `promote` has already walked. The scope thunk memoises its
	// library, so every `resolutionFiles()` call after the first in a run hands back the SAME
	// array — one per `--fix` pass — and re-walking it would re-hash every library source for
	// nothing. Reference identity, not content: a different array is a different library.
	private var _promotedLibrary: Null<Array<{ file: String, source: String }>> = null;

	public function new(lang: String) {
		_parses = tier(PARSE_TIERS, lang);
		_spans = tier(SPAN_TIERS, lang);
	}

	/** The tier's parse of `source` — counting the serve — or null when it holds none. */
	public function servedParse(source: String): Null<QueryNode> {
		final shared: Null<QueryNode> = _parses[source];
		if (shared != null) libraryHits++;
		return shared;
	}

	/** The span-info twin of `servedParse`. */
	public function servedSpanInfo(source: String): Null<SpanTypeInfo> {
		final shared: Null<SpanTypeInfo> = _spans[source];
		if (shared != null) librarySpanHits++;
		return shared;
	}

	/**
	 * PROMOTE every library source's parse and span-info into this tier, so the next `Cli.run`
	 * over the same library serves them instead of re-parsing 200+ std files from scratch.
	 * Idempotent and content-addressed: an entry already present is a HIT and costs nothing, and
	 * only a byte-identical source can serve it.
	 *
	 * A source that does not parse is left out entirely (`SymbolIndexBuilder.extract` re-tries
	 * it and records the file as skipped) — the same treatment the instance parse cache gives a
	 * throwing parse, over a negligible minority of library files.
	 */
	public function promote(library: LibrarySources, plugin: CachingGrammarPlugin): Void {
		final entries: Array<{ file: String, source: String }> = library.entries();
		if (_promotedLibrary == entries) return;
		_promotedLibrary = entries;
		for (entry in entries) {
			// Routed through the wrapper's `parseFile` — NOT short-circuited on `_parses.exists` —
			// so an already-promoted entry goes through the SERVE branch, the one thing this tier
			// exists for. Short-circuiting here is what made the serve path deletable with a green
			// suite: the counters then measured this loop, never the lookup.
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (exception: Exception) null;
			if (tree == null || _parses.exists(entry.source)) continue;
			_parses[entry.source] = tree;
			_spans[entry.source] = plugin.spanTypeInfo(entry.source);
			libraryParses++;
		}
	}

	/** Record one wrapped-plugin parse — the miss `servedParse` did not cover. */
	public static inline function noteInnerParse(): Void {
		innerParses++;
	}

	/** Record one wrapped-plugin span-parse — the span twin of `noteInnerParse`. */
	public static inline function noteInnerSpanParse(): Void {
		innerSpanParses++;
	}

	/** The `lang` slice of a process-scoped `tiers` map, created empty on first use. */
	private static function tier<T>(tiers: Map<String, Map<String, T>>, lang: String): Map<String, T> {
		final existing: Null<Map<String, T>> = tiers[lang];
		if (existing != null) return existing;
		final created: Map<String, T> = [];
		tiers[lang] = created;
		return created;
	}

}
