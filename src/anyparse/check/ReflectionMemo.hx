package anyparse.check;

import anyparse.check.ReflectionScan.ReflectionSurface;
import anyparse.check.ReflectionScan.ScopeFile;

/**
 * Run-scoped memoization of `ReflectionScan.reflectionSurface`, keyed by the SOURCES it was collected from.
 *
 * The surface is one walk of every file in the name-keyed reflection scope — report files UNION the resolution sources —
 * and five of the six registered checks that reach it demand it per run on Pony (a READING of that tree: its
 * config disables `unused-public-member`), each having recomputed the whole thing (`ReflectionScan.scopeFiles`
 * documents the scope; `LintCommand.partitionChecks` lists the checks). Measured on Pony (680 report files against a
 * resolution scope of 2764, eleven `resolutionLibs` declared): the FIRST demand pays the library parses, every later one
 * pays the re-walk alone, at ~0.12s each — `lint src --rule unused-private` 7.75s, the same plus `inline-constant` 7.92s,
 * plus `static-constant` and `orphan-accessor` 8.10s. Four of the five demands in a full `lint src` were that
 * re-walk. Measured as a MARGINAL cost, alternating both engines over one Pony copy: three extra demands cost
 * 7.50s -> 8.10s before the memo and 7.47s -> 7.60s after, reports byte-identical in every cell. Wall clock
 * on the whole run cannot resolve it (±0.4s between rounds), so the marginal pair is the reading to trust.
 *
 * VALIDATED, not expired. The memo holds the source STRING of every scope entry it read, and a later demand is answered only
 * when that list still matches element for element. A `--fix` pass mutates a report entry's `source` IN PLACE, so an expiry
 * hook would have to fire on every path that rewrites one — the safe-pass loop, the risky verifier, the cross-file commit —
 * and a missed hook is a gate answering about the PREVIOUS pass's text, which is the silent direction: a name a pass just
 * introduced into a `Reflect` call would not refuse the next rewrite. Comparing the sources instead makes staleness
 * unrepresentable, and costs one string compare per scope file on a hit — a pointer compare on JS while callers
 * hand back the same instances, a byte compare on a static target or a caller that rebuilds its entries. ONE slot:
 * a demand over a DIFFERENT scope evicts it (`prefer-enum-abstract` hands a filtered report set, so on a read-only
 * Pony `lint src` two of four repeat demands hit; `--fix` is unaffected, 24 of 32 hit) — a small ring is T926.
 *
 * Instance state, no statics — one per lint / fix run, never shared across threads, the same lifecycle as `CachingGrammarPlugin`'s
 * parse caches and `RefsCache`. A process-scoped memo here would be a scope from an earlier run answering this run's gates.
 *
 * Handed out SHARED, where `RefsCache.find` copies: a surface's two arrays are read by every consumer and written by none — censused
 * over the six checks that reach `reflectionSurface` (`inline-constant`, `static-constant`, `prefer-enum-abstract`, `orphan-accessor`,
 * `unused-public-member`, `unused-private`), each of which passes `whole` / `fragments` straight into a containment or
 * occurrence-count test. A consumer that MUTATES one has to copy here instead, since before this memo every call built its own.
 */
@:nullSafety(Strict)
final class ReflectionMemo {

	// The source of every scope entry the memo was filled from, in scope order — the whole
	// staleness proof. Null until the first fill, which is also the answer "nothing memoised".
	private var _surfaceSources: Null<Array<String>> = null;
	private var _surface: Null<ReflectionSurface> = null;

	public function new() {}

	/**
	 * The memoised surface for `scope`, or null when nothing was memoised yet or any file's source
	 * has been rewritten since. The caller then collects and offers the result to `setSurface`.
	 */
	public function surfaceFor(scope: Array<ScopeFile>): Null<ReflectionSurface> {
		final sources: Null<Array<String>> = _surfaceSources;
		if (sources == null || sources.length != scope.length) return null;
		for (i in 0...sources.length) if (sources[i] != scope[i].source) return null;
		return _surface;
	}

	/** Memoise `surface` as the answer for exactly the sources `scope` carries now. */
	public function setSurface(scope: Array<ScopeFile>, surface: ReflectionSurface): Void {
		_surfaceSources = [for (entry in scope) entry.source];
		_surface = surface;
	}

}
