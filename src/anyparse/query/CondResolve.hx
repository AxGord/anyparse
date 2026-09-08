package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.CondQuery.CondBranch;
import anyparse.query.CondQuery.CondRegion;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * FOLDING a conditional-compilation region a define DECIDES — the write-twin of `apq cond`, the
 * same relation `comment-rewrite` has to `lit`.
 *
 * A define that is always set, or never set, turns every region mentioning it into noise: the
 * reader still has to evaluate the condition to know which branch ships. Retiring one is a
 * one-time procedure, not a lint policy, which is why it is an OP — `apq resolve-define X <scope>`
 * replaces each such region with the body of the branch it keeps.
 *
 * ## DECIDED, and what a region that is not gets instead
 *
 * A region is DECIDED when every one of its branches is provably live or provably dead under the
 * hypothesis the caller states — `X is defined`, or `X is not defined` with the negative polarity.
 * `CondQuery.regionsMentioning` answers that per branch and this class only reads the verdict, so
 * the op and the report `apq cond` prints cannot disagree about which branch a define selects.
 *
 * A region with a `maybe` branch — `#if (mobile && X)`, or an `#elseif X` after an `#if other`
 * nothing refuted — is LEFT ALONE and reported by position. Simplifying its condition
 * (`(mobile && X)` to `mobile`) is deliberately out of scope: that is a rewrite of the condition
 * text, a different job with different failure modes, and mixing it in would make a refusal
 * indistinguishable from a partial edit.
 *
 * ## Nesting, and the one shape that reads backwards
 *
 * A decided region inside a decided region is folded by RECURSION into its parent's replacement,
 * never as an edit of its own: `CanonicalEdit.applyEdits` splices non-overlapping spans, and a
 * nested span is not one. A decided region inside an UNDECIDED one is the shape that reads
 * backwards and is edited normally — the parent contributes no edit at all, so nothing collides.
 *
 * The report follows the same rule. A region left standing inside a branch some decided region
 * DROPS is not reported, because the rewrite deleted it: naming it `left as is` would point at a
 * site the output no longer has.
 *
 * ## The write path is the shared gate, and that is the point
 *
 * Every result goes through `CanonicalEdit.canonicalize`, never `applyEdits` directly. Three of
 * its gates matter here specifically: a region that was the whole body slot of a brace-less `if`
 * is refused by `BodySlotGuard` rather than silently handing that `if` the next statement; a
 * non-canonical input is refused with `apq fmt --write` as the remedy unless `--reformat`; and a
 * source the grammar cannot parse is refused outright. That last one is the deliberate difference
 * from `cond`, which walks an unparseable file happily — reading a region needs no tree, but a
 * WRITE op cannot validate what it cannot re-parse.
 *
 * Pure: no filesystem, no process, no state between calls.
 */
@:nullSafety(Strict)
final class CondResolve {

	/**
	 * `source` with every region `define` decides folded to the body of the branch it keeps, the
	 * count of regions that folded, and every region left standing.
	 *
	 * `undefined` states the negative hypothesis — the define is asserted ABSENT rather than set —
	 * which is the polarity a never-defined flag needs. `reformat` waives the canonical-input gate
	 * and `optsJson` is the writer config discovered near the file, both handed straight to
	 * `CanonicalEdit.canonicalize`.
	 *
	 * A file with nothing to fold answers `Ok(source)` WITHOUT touching the writer: there is no
	 * edit to validate, and paying for a whole-file round trip per walked file is what would make
	 * a directory scan cost more than the walk it replaces.
	 */
	public static function resolve(
		source: String, plugin: GrammarPlugin, define: String, undefined: Bool, reformat: Bool, ?optsJson: String
	): CondResolveResult {
		final shape: RefShape = plugin.refShape();
		// No `tree`: every branch here is delimited by its own directives and spliced as BYTES, so
		// the `raw` flag a tree would answer says nothing this op reads.
		final all: Array<CondRegion> = CondQuery.regionsMentioning(
			source, null, shape, plugin.lexicalRegions.bind(source), define, undefined
		);
		final decided: Array<CondRegion> = all.filter(isDecided);
		final undecided: Array<UndecidedRegion> = [
			for (region in all) if (!isDecided(region) && survivesTheFold(region, decided))
				{ at: region.branches[0].at, directive: region.branches[0].directive }
		];
		final edits: Array<{ span: Span, text: String }> = [];
		var resolved: Int = 0;
		for (region in outermost(decided)) {
			final folded: FoldedRegion = fold(source, region, decided);
			resolved += folded.count;
			edits.push({ span: editSpan(source, region.span.from, region.span.to, folded.text), text: folded.text });
		}
		return {
			result: edits.length == 0 ? Ok(source) : CanonicalEdit.canonicalize(source, edits, reformat, plugin, optsJson),
			resolved: resolved,
			undecided: undecided
		};
	}

	/** Whether `live` is the provable YES: the one branch a decided region keeps. */
	private static inline function isLive(live: Null<Bool>): Bool {
		return live != null && live;
	}

	/** Whether every branch of `region` is provably live or provably dead — the condition for folding it. */
	private static function isDecided(region: CondRegion): Bool {
		return region.branches.foreach(branch -> branch.live != null);
	}

	/**
	 * `region`'s replacement text — the body of the branch it keeps, with every decided region
	 * nested in that body folded the same way — and how many regions the whole fold accounted for,
	 * this one included.
	 *
	 * The nested pass splices into the BODY SUBSTRING rather than into the file, so its offsets are
	 * local and its own line structure is the one whole-line hygiene is asked about. Scanning that
	 * substring standalone is sound because a body never straddles a comment or a string:
	 * `CondDirectives.scan` skips non-code regions, so a directive is never found inside one.
	 *
	 * No live branch means the region compiles to nothing, and the replacement is empty.
	 */
	private static function fold(source: String, region: CondRegion, decided: Array<CondRegion>): FoldedRegion {
		final live: Null<CondBranch> = region.branches.find(branch -> isLive(branch.live));
		if (live == null) return { text: '', count: 1 };
		final body: Span = live.body;
		final text: String = source.substring(body.from, body.to);
		final inner: Array<CondRegion> = decided.filter(candidate -> candidate.span.from >= body.from && candidate.span.to <= body.to);
		final edits: Array<{ span: Span, text: String }> = [];
		var count: Int = 1;
		for (nested in outermost(inner)) {
			final folded: FoldedRegion = fold(source, nested, decided);
			count += folded.count;
			edits.push({
				span: editSpan(text, nested.span.from - body.from, nested.span.to - body.from, folded.text),
				text: folded.text
			});
		}
		return { text: CanonicalEdit.applyEdits(text, edits).trim(), count: count };
	}

	/**
	 * The span an edit covers when `replacement` stands in for the region at `[from, to)` of `text`.
	 *
	 * Two loose offsets rather than the region's own `Span`: the recursive pass asks this about a body
	 * SUBSTRING, where the offsets are local, so a `Span` argument would be one throwaway allocation per
	 * nested region and a reader would have to check which coordinate space it was in.
	 *
	 * A NON-EMPTY replacement takes exactly the region, so its first line inherits the directive's
	 * own indentation and the writer re-indents the rest — code layout is the writer's job and
	 * nothing here should pre-empt it.
	 *
	 * An EMPTY one — no branch is live — widens to the whole LINES the region owns, when it owns
	 * them: an `#if` that starts its line and an `#end` that ends one leave a blank line behind
	 * otherwise, and no writer pass removes it. A region sharing its lines with code keeps the
	 * narrow span, because those bytes belong to the code.
	 */
	private static function editSpan(text: String, from: Int, to: Int, replacement: String): Span {
		if (replacement != '' || !SourceText.startsItsLine(text, from) || !CondDirectives.endsItsLine(text, to)) return new Span(from, to);
		var end: Int = to;
		while (end < text.length && text.fastCodeAt(end) != '\n'.code) end++;
		return new Span(SourceText.startOfLine(text, from), end < text.length ? end + 1 : end);
	}

	/**
	 * The regions of `regions` that no other region of `regions` encloses.
	 *
	 * The containment question is `CanonicalEdit.isContainedEdit`'s, asked of one placeholder edit
	 * per region rather than re-implemented: it is the same predicate the `--fix` batcher uses to
	 * keep a nested span out of an edit set, and two distinct regions never share a span, so its
	 * equal-span tie-break cannot fire here.
	 */
	private static function outermost(regions: Array<CondRegion>): Array<CondRegion> {
		final placeholders: Array<{ span: Span, text: String }> = [for (region in regions) { span: region.span, text: '' }];
		return [
			for (i in 0...regions.length) if (!CanonicalEdit.isContainedEdit(placeholders, i)) regions[i]
		];
	}

	/**
	 * Whether `region` is still in the output once every decided region has folded — false when one
	 * of them DROPS the branch `region` sits in.
	 *
	 * Transitive without a recursion, because the test runs over EVERY enclosing decided region: a
	 * parent kept inside a grandparent's dead branch fails the grandparent's own test, and so does
	 * anything inside it.
	 */
	private static function survivesTheFold(region: CondRegion, decided: Array<CondRegion>): Bool {
		for (outer in decided) if (outer.span.from <= region.span.from && region.span.to <= outer.span.to) {
			final live: Null<CondBranch> = outer.branches.find(branch -> isLive(branch.live));
			if (live == null || region.span.from < live.body.from || live.body.to < region.span.to) return false;
		}
		return true;
	}

}

/**
 * One conditional-compilation region `CondResolve.resolve` refused to fold: `at` is its OPENING
 * directive's span, which is what a caller renders as `file:line:col`, and `directive` that
 * directive's verbatim text.
 */
typedef UndecidedRegion = {
	final at: Span;
	final directive: String;
};

/**
 * What `CondResolve.resolve` answers: the write `result` for the whole file, how many regions
 * folded (`resolved`, nested ones counted individually), and every region left standing
 * (`undecided`) for the caller to report.
 */
typedef CondResolveResult = {
	final result: EditResult;
	final resolved: Int;
	final undecided: Array<UndecidedRegion>;
};

/** One region's replacement text, and how many regions producing it accounted for — itself included. */
private typedef FoldedRegion = {
	final text: String;
	final count: Int;
};
