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
 * The callers still on the forwarder, counted at the commit that split this file:
 *
 *  - `RefactorSupport.collectCommentTokens` — 69 call sites across 50 files, and not one of
 *    them passes a plugin to the static helper it calls. Threading one is a cascade through
 *    `docExtendedSpan` / `trailingTrimmedSpan` / `commentBlockAt` and every check that
 *    reaches them: that is the rest of the debt, deliberately not this commit.
 *  - `RefactorSupport.collectNonCodeRegions` and `activeCodeIdentTokenOffset` — one caller
 *    each, both inside `RefactorSupport`.
 *  - `RefactorSupport.carriesAllowGrant` — left untouched while a concurrent slice holds it.
 *  - `RefactorSupport`'s own private token walk, which needs `skipStringLiteral` alone.
 *
 * The consumers that DO hold a plugin ask it instead: `BodySlotGuard`, `Patch`,
 * `RefactorSupport.classifyOccurrences` and `RefactorSupport.nameBoundInRange`.
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
