package anyparse.query;

import anyparse.query.CondDirectives.CondDirective;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

/**
 * Which conditional-compilation BRANCH a source position sits in, for checks that compare
 * sibling constructs.
 *
 * A `#if` region projects as ONE node whose children are every branch's constructs flattened
 * into a single sibling list — the tree carries no branch boundary at all. A check that reads
 * that list as neighbours concludes things about code that is never compiled together:
 * `duplicate-case` read `#if new … case X … #else … case X … #end` as a repeated label and
 * its fix deleted the `#else` arm, removing the arm entirely from every build that takes it.
 *
 * The boundaries ARE recoverable — from the construct's own directive lines, which
 * `CondDirectives` already reads without needing a parse. This class replays them into a
 * per-position PATH: one `(region, branch)` frame per region open at that position.
 *
 * Two positions are ALTERNATIVES when some region they are both inside assigns them different
 * branch indices. Anything else is comparable — including a position outside a region against
 * one inside it, since a build that takes that branch really does see both.
 *
 * A frame carries its branch's CONDITION as well as its region's ordinal, because the two questions the
 * class answers need different keys: `comparable` asks "is this the same region" and `sameBranch` asks
 * "do these guard the same builds". Only the second is true of two sibling regions spelling one condition.
 *
 * Grammar-agnostic (the keyword vocabulary is `RefShape`'s) and parse-free, so it works on a
 * file the grammar cannot parse.
 */
@:nullSafety(Strict)
final class CondBranchPath {

	/**
	 * Replay `source`'s directives into a lookup: for each directive, its start offset and the
	 * region/branch stack in force just after it. `pathAt` binary-free-scans this.
	 *
	 * `#if` pushes a fresh region at branch 0, `#elseif` / `#else` advance the innermost
	 * region's branch, `#end` pops. An unbalanced `#end` (nothing open) is ignored rather than
	 * throwing: a file whose directives do not nest is one this class cannot model, and the
	 * empty path it then reports makes every position comparable — the pre-existing behaviour.
	 */
	public static function scan(source: String, shape: RefShape, regions: Array<LexRegion>): CondBranchIndex {
		final marks: Array<{ at: Int, path: Array<CondFrame> }> = [];
		final stack: Array<CondFrame> = [];
		var nextRegion: Int = 0;
		final elseKeywords: Array<String> = shape.conditionalElseKeywords ?? [];
		final endKeyword: Null<String> = shape.conditionalEndKeyword;
		for (directive in CondDirectives.scan(source, shape, () -> regions)) {
			if (directive.keyword == shape.conditionalIfKeyword) {
				stack.push({ region: nextRegion, branch: 0, condition: conditionText(source, directive) });
				nextRegion++;
			} else if (endKeyword != null && directive.keyword == endKeyword) {
				if (stack.length > 0) stack.pop();
			} else if (elseKeywords.contains(directive.keyword) && stack.length > 0) {
				final top: CondFrame = stack[stack.length - 1];
				stack[stack.length - 1] = {
					region: top.region,
					branch: top.branch + 1,
					condition: '${top.condition}|${conditionText(source, directive)}'
				};
			}
			marks.push({ at: directive.span.from, path: stack.copy() });
		}
		return marks;
	}

	/** The region/branch stack in force at `pos` — the state left by the last directive at or before it. */
	public static function pathAt(index: CondBranchIndex, pos: Int): Array<CondFrame> {
		var path: Array<CondFrame> = [];
		for (mark in index) {
			if (mark.at > pos) break;
			path = mark.path;
		}
		return path;
	}

	/**
	 * Whether two positions can be reasoned about together: false only when some region holds
	 * both and puts them in DIFFERENT branches. A region that holds only one of them imposes
	 * nothing — the build taking that branch sees the other position too.
	 */
	public static function comparable(a: Array<CondFrame>, b: Array<CondFrame>): Bool {
		for (frameA in a) for (frameB in b) if (frameA.region == frameB.region && frameA.branch != frameB.branch) return false;
		return true;
	}

	/**
	 * Whether two positions sit in the SAME branch of the SAME regions — the strict form of
	 * `comparable`, for a caller whose question is "is this an illegal DUPLICATE" rather than
	 * "may these be compared". The two differ on every shape where one position is inside a
	 * region the other is not: `comparable` says yes, because a build taking that branch sees
	 * both, and that is the right answer for a duplicate-case report. It is the wrong answer
	 * for a REFUSAL, because this class cannot see that `#if js` and `#if !js` are alternatives
	 * — they are two regions, not two branches of one — and refusing that pair would reject the
	 * conditional-twin shape the callers exist to serve. Identical paths carry no such doubt: no
	 * build compiles one without the other.
	 *
	 * Keyed by the branch's CONDITION CHAIN, not by region occurrence, which is what lets two
	 * SIBLING regions spelling one condition (`#if a … #end #if a … #end`) answer true. They are
	 * two regions and no build compiles one without the other, so a caller refusing on this
	 * question has to see them as one branch — the shape a `replace-node` that duplicates a whole
	 * guarded group produces, and the half `remove-member` reported as uncatchable while a frame
	 * carried only its region's ordinal. Each frame's key is every condition its region has
	 * spelled up to and including the branch in force (`a`, `a|b` for an `#elseif b`, `a|` for an
	 * `#else`), so branch INDEX alone cannot equate two differently-conditioned `#elseif` arms.
	 *
	 * FALSE is still not a licence — it means only "not provably always together". Two chains that
	 * are logically equivalent but spelled differently (`#if a #if b` against `#if b #if a`, or
	 * `#if !a` against an `#else`) are different keys, and answer false.
	 */
	public static function sameBranch(a: Array<CondFrame>, b: Array<CondFrame>): Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i].branch != b[i].branch || a[i].condition != b[i].condition) return false;
		return true;
	}

	/**
	 * The directive's condition as a comparison key: normalised whitespace, outer parentheses
	 * stripped, empty for a keyword that carries none (`#else`, and a malformed `#if` whose tail
	 * the reader could not delimit).
	 *
	 * Two spellings of one condition have to compare equal or the widening below buys nothing —
	 * `#if (js)` and `#if js` guard the same builds — and the two normalisers `CondDirectives`
	 * already exposes for `MemberSlots` are exactly that pair.
	 */
	private static function conditionText(source: String, directive: CondDirective): String {
		final span: Null<Span> = directive.condition;
		return span == null ? '' : CondDirectives.stripOuterParens(CondDirectives.normalizeCondition(source.substring(span.from, span.to)));
	}

}

/**
 * One open conditional region at a position: which region, which of its branches, and that
 * branch's condition chain.
 *
 * `region` is an occurrence ordinal — it answers "is this the SAME region", which is what
 * `comparable` needs and what `sameBranch` must NOT use. `condition` answers "does this branch
 * guard the same builds", which is what a REFUSAL needs; the two questions differ exactly on a
 * pair of sibling regions spelling one condition.
 */
typedef CondFrame = {
	final region: Int;
	final branch: Int;

	/**
	 * Every condition the region has spelled up to and including this branch, normalised and
	 * joined with `|` — `a` for the `#if` arm, `a|b` for an `#elseif b`, `a|` for an `#else`.
	 * Empty where the directive carries no condition the reader could delimit.
	 */
	final condition: String;
};

/** The replayed directive marks of one source, in source order — `CondBranchPath.scan`'s result. */
typedef CondBranchIndex = Array<{ at: Int, path: Array<CondFrame> }>;
