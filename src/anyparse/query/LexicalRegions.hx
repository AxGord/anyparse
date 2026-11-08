package anyparse.query;

using Lambda;

import anyparse.runtime.Span;

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

	/**
	 * The code holes of an interpolating literal, in source order; absent on every other region. The bytes
	 * between the holes are the literal's text.
	 */
	@:optional final holes: Null<Array<LexHole>>;

};

/**
 * A code hole of an interpolating literal: `[from, to)` spans the hole's delimiters too (`${` through `}`), and
 * `regions` are the comments and literals written inside it, nested the same way.
 */
typedef LexHole = {
	final from: Int;
	final to: Int;
	final regions: Array<LexRegion>;
};

/**
 * A grammar's lexical walk: `onRegion(from, to, kind, depth)` for every region at every nesting depth and
 * `onHole(from, to, depth)` for every code hole, each reported AFTER everything nested inside it (a hole of a
 * depth-0 literal and the regions in it are at depth 1). A region or hole the walk ABANDONED (unterminated) is
 * reported with `to == -1`, and everything reported inside it is void.
 */
typedef LexWalk = (
	onRegion:(from:Int, to:Int, kind:LexRegionKind, depth:Int) -> Void, onHole:(from:Int, to:Int, depth:Int) -> Void
) -> Void;

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
 * They hardcoded `HaxeLexicalRegions` inside this grammar-agnostic package for the callers that held no
 * `GrammarPlugin` to ask. That debt was every `collectCommentTokens` call site, plus
 * `collectCommentRegions`, `collectNonCodeRegions`, `activeCodeIdentTokenOffset` and the private
 * `headerScan` behind `typeHeaderInsertOffset` / `typeBodyBraceOffset`; all of them moved and both
 * functions are gone. `unit.LexicalRegionsSeamTest.testNoQueryOrCheckModuleReachesTheHaxeGrammar` is the
 * pin that keeps them gone: it enumerates the `anyparse.query` + `anyparse.check` modules that name
 * `anyparse.grammar.haxe.*` and asserts the exact allow-list, so a new forwarder — or any other plugin-less
 * reach into one grammar's lexer — fails a test instead of passing review.
 *
 * ## The seam the consumers use instead, and WHICH of the three shapes to pick
 *
 * A helper that is grammar-agnostic once handed regions takes `regions: Array<LexRegion>`; its
 * caller asks `plugin.lexicalRegions(source)` ONCE and threads the array. That is the default, and
 * it is what `RefactorSupport.collectCommentTokens` / `collectCommentRegions` /
 * `collectNonCodeRegions` / `activeCodeIdentTokenOffset` / `docExtendedSpan` / `commentBlockAt` /
 * `headerScan` and the two wrappers over it now take.
 *
 * TWO deliberate exceptions, each of which would otherwise cost a scan nothing paid before:
 *
 *  - **A helper with its own CHEAP GUARD in front of the scan takes a `() -> Array<LexRegion>`**, so the
 *    guard keeps its saving. `RefactorSupport.trailingTrimmedSpan` is the sharpest case — its one-byte
 *    test keeps the whole-file lex off a path a caller may take once per MATCH — and
 *    `RefactorSupport.docSplittingEdit` (called once per file per `lint --fix` pass with an EMPTY edit
 *    set), `CondDirectives.scan`, `CondBranchProjection.branchAwareTree`, `MemberBranchScan.seamsOf`
 *    with its `eachTypeMember` / `isGuardedMember` / `declaresMemberNamed` / `exclusiveSpansAt`
 *    wrappers, `MissingVisibility.commentTokens` and `ConstantHoist.commentAbove` are the rest.
 *  - **A helper that reads MORE THAN ONE source takes the plugin's own method as a value**,
 *    `lexicalRegions: (String) -> Array<LexRegion>`, so regions can never be paired with the wrong text.
 *    `Suppression.apply`, `Json.renderRefs`, `Cli.blastRefsSection` / `emitMentionsRefs`,
 *    `MoveSymbol.buildImporterEdits` / `destinationImportEdits` and the `MoveMember` member-group family
 *    take it. That is not decoration: the one real defect this migration introduced was a single-array
 *    hop reaching the destination collision scan (`NameMentionScan.destinationNamesType`), where the
 *    CURSOR file's regions masked the DESTINATION file's text — invisible to every byte-identity gate,
 *    because no lint or `--fix` path runs `move`.
 *
 * The consumers that hold a plugin and ask it directly: `BodySlotGuard`, `Patch`,
 * `RefactorSupport.classifyOccurrences`, `RefactorSupport.nameBoundInRange` and
 * `RawSourceScan.sourceCarriesAllowGrant`.
 */
@:nullSafety(Strict)
final class LexicalRegions {

	/**
	 * The lexically-scanned non-code region containing `offset`, or null when `offset` is code.
	 *
	 * LEFT LINEAR deliberately. The regions are sorted and non-overlapping and two consumers call this
	 * inside a loop, so a binary search looks obvious — but a CPU profile of a full `lint --all --fix` over
	 * a large tree does not sample this function at all, nor `offsetWithinComment` beside it, and both loop
	 * consumers are bounded from outside. Ten lines of binary search would buy a quantity the instrument
	 * cannot see.
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

	/**
	 * The CODE spans of a source of `length` bytes: what lies between the sorted, non-overlapping `regions`, in source
	 * order, an empty run left out. A scan of the code bytes walks these and never meets a comment, a string or a regex.
	 */
	public static function codeSpans(length: Int, regions: Array<LexRegion>): Array<Span> {
		final out: Array<Span> = [];
		var at: Int = 0;
		for (region in regions) {
			if (region.from > at) out.push(new Span(at, region.from));
			if (region.to > at) at = region.to;
		}
		if (length > at) out.push(new Span(at, length));
		return out;
	}

	/**
	 * Does a COMMENT region open inside `[from, to)`? A `//` or `/*` inside a string literal is text, so it is no
	 * comment; one inside a `${ … }` hole of a string is code and counts. The one answer to "does this source range hold a
	 * comment" for a caller that must not splice over one and cannot accept the string-blind
	 * `SourceComments.hasCommentMarker`.
	 */
	public static function commentOpensIn(from: Int, to: Int, regions: Array<LexRegion>): Bool {
		return regions.exists(region -> region.from >= from && region.from < to && switch region.kind {
			case LineComment, BlockComment: true;
			case StringLit, RegexLit: false;
		});
	}

	/**
	 * The OUTERMOST regions `walk` reports, each interpolating literal carrying its holes and each hole the regions
	 * written inside it: the one answer to "which hole and which literal does a nested region belong to". A walk
	 * reports a region after everything nested in it, so the regions and holes still pending one level deeper
	 * are exactly the ones it encloses, and an abandoned one voids them before the next can claim them.
	 */
	public static function assemble(walk: LexWalk): Array<LexRegion> {
		final regionsAt: Array<Array<LexRegion>> = [];
		final holesAt: Array<Array<LexHole>> = [];
		walk((from, to, kind, depth) -> {
			if (to < 0) {
				drop(regionsAt, depth + 1);
				drop(holesAt, depth + 1);
				return;
			}
			final holes: Array<LexHole> = claim(holesAt, depth + 1);
			final region: LexRegion = holes.length == 0 ? { from: from, to: to, kind: kind } : {
				from: from,
				to: to,
				kind: kind,
				holes: holes
			};
			pending(regionsAt, depth).push(region);
		}, (from, to, depth) -> {
			if (to < 0) {
				drop(regionsAt, depth);
				drop(holesAt, depth + 1);
				return;
			}
			pending(holesAt, depth).push({ from: from, to: to, regions: claim(regionsAt, depth) });
		});
		return claim(regionsAt, 0);
	}

	/**
	 * Every comment of `regions` as `onComment(from, to)`, in source order, those written inside a literal's code holes
	 * included: the flat reading of the assembled tree, where an abandoned hole's comments are already void, so each comment
	 * is reported once by its own byte range.
	 */
	public static function eachComment(regions: Array<LexRegion>, onComment: (from:Int, to:Int) -> Void): Void {
		for (region in regions) switch region.kind {
			case LineComment, BlockComment:
				onComment(region.from, region.to);
			case StringLit, RegexLit:
				for (hole in region.holes ?? []) eachComment(hole.regions, onComment);
		}
	}

	/** The entries waiting at `depth`, the level created on first use. */
	private static function pending<T>(levels: Array<Array<T>>, depth: Int): Array<T> {
		while (levels.length <= depth) levels.push([]);
		return levels[depth];
	}

	/** The entries waiting at `depth`, handed over and the level emptied. */
	private static function claim<T>(levels: Array<Array<T>>, depth: Int): Array<T> {
		final out: Array<T> = pending(levels, depth);
		levels[depth] = [];
		return out;
	}

	/** Every entry waiting at `depth` or deeper discarded: what an abandoned region or hole reported inside itself. */
	private static function drop<T>(levels: Array<Array<T>>, depth: Int): Void {
		for (d in depth ... levels.length) levels[d] = [];
	}

}
