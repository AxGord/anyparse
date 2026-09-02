package anyparse.query;

import anyparse.grammar.haxe.HaxeLexicalRegions;

using Lambda;

/**
 * Kind of a lexically-scanned non-code source region (comment, string or regex literal).
 */
enum abstract LexRegionKind(Int) {

	final LineComment = 0;
	final BlockComment = 1;
	final StringLit = 2;
	final RegexLit = 3;

}

/** A lexically-scanned non-code region: `[from, to)` and its kind. */
typedef LexRegion = {
	final from: Int;
	final to: Int;
	final kind: LexRegionKind;
};

/**
 * The grammar-agnostic half of the lexical-region model: the region TYPES above, and the two
 * pure helpers over a region ARRAY that every consumer shares.
 *
 * The SCAN that produces the array is a property of the GRAMMAR, and now lives with it —
 * `HaxeLexicalRegions` in the Haxe grammar package, reached through
 * `GrammarPlugin.lexicalRegions(source)`, the seam beside `controlFlowSupport()`. Everything
 * the scan knows is Haxe syntax: single-quote interpolation, `${ … }` holes, `~/ … /`
 * literals, `//` and block comments. A grammar-agnostic package was the wrong home for it —
 * invariant 4 says a new language is a new package, never a core change, and a second
 * grammar could not have answered the same question without editing this file.
 *
 * ## `scan` / `skipStringLiteral` below are a DEPRECATED forwarder, not the seam
 *
 * Both call `HaxeLexicalRegions` directly and so hardcode one grammar. They exist for the
 * callers that hold no `GrammarPlugin` to ask; where you have one, ask it.
 *
 * The callers still on the forwarder, RE-MEASURED, with what each one would cost to move:
 *
 *  - `RefactorSupport.collectCommentTokens` — 65 call sites across 49 files: 55 sites in 41
 *    `check/` classes, whose `Check.run` / `Check.fix` already carry a plugin, 8 in 6 `query/`
 *    modules and 2 in tests. Most of it is therefore argument-passing rather than design — but
 *    `CondBranchProjection` and `MemberBranchScan` name no `GrammarPlugin` in ANY signature, so
 *    those two need a hop from their own callers first. It is 65 sites on the path that gates
 *    every DELETE in the tool, which is why it wants its own slice and not the tail of another,
 *    and it carries `collectCommentRegions` (6 sites / 5 files) and `InertRegions` with it.
 *  - `RefactorSupport.collectNonCodeRegions` — ONE caller, `CondDirectives.scan(source, shape)`,
 *    which is itself called from 24 sites across 9 files. Moving it is an improvement rather
 *    than a cost, since `scan` would take the plugin INSTEAD of the `RefShape` it derives from
 *    it — but it is those 24 sites, so it belongs with the item above.
 *  - `RefactorSupport.activeCodeIdentTokenOffset` — 4 call sites in 3 files, two of which reach
 *    it through a struct (`ExplicitType.ReturnSeams`) that would have to carry the plugin.
 *  - `RefactorSupport`'s own private token walk (`headerScan`), which needs `skipStringLiteral`
 *    alone. Private, but its two public callers `typeHeaderInsertOffset` / `typeBodyBraceOffset`
 *    have 2 sites each, in `ExtractInterface` / `ExtractSuperclass` and `ConstantHoist` /
 *    `FieldInitInConstructor`.
 *
 * `RefactorSupport.carriesAllowGrant` is OFF this forwarder as of S55: it had exactly one caller
 * (`SymbolIndex.sourceCarriesAllowGrant`) and `SymbolIndex.build` already receives the plugin, so
 * the index — the one run-scoped object that consumer already holds — now carries it. That is the
 * shape the rest of the debt should take where a run-scoped holder exists.
 *
 * The recommended seam for the remainder is `Array<LexRegion>`, not `GrammarPlugin`: these
 * helpers are grammar-agnostic once they are handed regions, the caller then hoists ONE scan per
 * file (which these docs already ask for on performance grounds), and the plugin stops appearing
 * in signatures that have no other use for it.
 *
 * The consumers that DO hold a plugin ask it instead: `BodySlotGuard`, `Patch`,
 * `RefactorSupport.classifyOccurrences`, `RefactorSupport.nameBoundInRange` and — since S55 —
 * `SymbolIndex.sourceCarriesAllowGrant`.
 */
@:nullSafety(Strict)
final class LexicalRegions {

	/**
	 * DEPRECATED — `GrammarPlugin.lexicalRegions(source)` is the seam; this forwards to the HAXE
	 * scanner unconditionally. Kept for the plugin-less callers listed on the class.
	 */
	public static inline function scan(source: String): Array<LexRegion> {
		return HaxeLexicalRegions.scan(source);
	}

	/**
	 * DEPRECATED, and Haxe-only for the same reason as `scan`: index of the closing `quote` of the
	 * string opened at `open`. `RefactorSupport`'s own token walk is the one caller.
	 */
	public static inline function skipStringLiteral(text: String, open: Int, quote: Int): Int {
		return HaxeLexicalRegions.skipStringLiteral(text, open, quote);
	}

	/**
	 * The lexically-scanned non-code region containing `offset`, or null when `offset` is code.
	 *
	 * MEASURED AND LEFT LINEAR (T219). The standing proposal was a binary search — the regions are
	 * sorted and non-overlapping, and two consumers call this inside a loop. In a `--cpu-prof` of
	 * `lint --all --fix --no-oracle` over 869 Pony files (30.16 s, 22 752 samples, 2466 distinct
	 * frames, smallest sampled frame 0.041 ms) this function is NOT SAMPLED AT ALL, and neither is
	 * `offsetWithinComment` beside it. Its two loop consumers bound it from outside:
	 * `RefactorSupport.carriesAllowGrant` costs 28.8 ms inclusive — 0.095 % — and
	 * `activeCodeIdentTokenOffset` is not sampled either. Ten lines of binary search would be
	 * buying a quantity the instrument cannot see.
	 */
	public static function regionAt(offset: Int, regions: Array<LexRegion>): Null<LexRegion> {
		return regions.find(region -> offset >= region.from && offset < region.to);
	}

	/**
	 * Is `offset` inside a COMMENT region? The first lexical region that
	 * contains it decides; a string literal is not a comment, so code
	 * interpolated inside one stays eligible.
	 */
	public static function offsetWithinComment(offset: Int, regions: Array<LexRegion>): Bool {
		final region: Null<LexRegion> = regionAt(offset, regions);
		return region != null && switch region.kind {
			case LineComment, BlockComment: true;
			case StringLit, RegexLit: false;
		};
	}

}
