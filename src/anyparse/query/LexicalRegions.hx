package anyparse.query;

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
 * The SCAN that produces the array is a property of the GRAMMAR, and lives with it —
 * `HaxeLexicalRegions` in the Haxe grammar package, reached through
 * `GrammarPlugin.lexicalRegions(source)`, the seam beside `controlFlowSupport()`. Everything
 * the scan knows is Haxe syntax: single-quote interpolation, `${ … }` holes, `~/ … /`
 * literals, `//` and block comments. A grammar-agnostic package was the wrong home for it —
 * invariant 4 says a new language is a new package, never a core change, and a second
 * grammar could not have answered the same question without editing this file.
 *
 * ## There is NO forwarder any more — the deprecated `scan` / `skipStringLiteral` are GONE
 *
 * They hardcoded `HaxeLexicalRegions` inside this grammar-agnostic package for the callers that
 * held no `GrammarPlugin` to ask. S55 measured that debt at 65 `collectCommentTokens` call sites
 * across 49 files, plus `collectCommentRegions`, `collectNonCodeRegions`,
 * `activeCodeIdentTokenOffset` and the private `headerScan` behind `typeHeaderInsertOffset` /
 * `typeBodyBraceOffset`; S60 moved every one of them and deleted both functions.
 * `unit.LexicalRegionsSeamTest.testNoQueryOrCheckModuleReachesTheHaxeGrammar` is the pin that keeps
 * them gone: it enumerates the `anyparse.query` + `anyparse.check` modules that name
 * `anyparse.grammar.haxe.*` and asserts the exact allow-list, so a new forwarder — or any other
 * plugin-less reach into one grammar's lexer — fails a test instead of passing review.
 *
 * ## The seam the consumers use instead, and WHICH of the three shapes to pick
 *
 * A helper that is grammar-agnostic once handed regions takes `regions: Array<LexRegion>`; its
 * caller asks `plugin.lexicalRegions(source)` ONCE and threads the array. That is the default, and
 * it is what `RefactorSupport.collectCommentTokens` / `collectCommentRegions` /
 * `collectNonCodeRegions` / `activeCodeIdentTokenOffset` / `docExtendedSpan` / `commentBlockAt` /
 * `headerScan` and the two wrappers over it now take.
 *
 * TWO deliberate exceptions, each of which would otherwise cost a scan the pre-S60 code never paid:
 *
 *  - **A helper with its own CHEAP GUARD in front of the scan takes a `() -> Array<LexRegion>`**,
 *    so the guard keeps its saving. `RefactorSupport.trailingTrimmedSpan` is the sharpest case —
 *    its one-byte test keeps the whole-file lex off a path a caller may take once per MATCH (14337
 *    times on one `ast --select --source` run, measured) — and `RefactorSupport.docSplittingEdit`
 *    (called once per file per `lint --fix` pass with an EMPTY edit set), `CondDirectives.scan`,
 *    `CondBranchProjection.branchAwareTree`, `MemberBranchScan.seamsOf` with its `eachTypeMember` /
 *    `isGuardedMember` / `declaresMemberNamed` / `exclusiveSpansAt` wrappers,
 *    `MissingVisibility.commentTokens` and `ConstantHoist.commentAbove` are the rest.
 *  - **A helper that reads MORE THAN ONE source takes the plugin's own method as a value**,
 *    `lexicalRegions: (String) -> Array<LexRegion>`, so regions can never be paired with the wrong
 *    text. `Suppression.apply`, `Json.renderRefs`, `Cli.blastRefsSection` / `emitMentionsRefs`,
 *    `MoveSymbol.buildImporterEdits` / `destinationImportEdits` and the `MoveMember` member-group
 *    family take it. That is not decoration: the one real defect this migration introduced was a
 *    single-array hop reaching `MoveSymbol.referencedInDest`, where the CURSOR file's regions
 *    masked the DESTINATION file's text — invisible to every byte-identity gate, because no lint or
 *    `--fix` path runs `move`.
 *
 * The consumers that hold a plugin and ask it directly: `BodySlotGuard`, `Patch`,
 * `RefactorSupport.classifyOccurrences`, `RefactorSupport.nameBoundInRange` and — since S55 —
 * `RawSourceScan.sourceCarriesAllowGrant`.
 */
@:nullSafety(Strict)
final class LexicalRegions {

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
