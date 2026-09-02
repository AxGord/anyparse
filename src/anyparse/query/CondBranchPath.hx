package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;

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
				stack.push({ region: nextRegion, branch: 0 });
				nextRegion++;
			} else if (endKeyword != null && directive.keyword == endKeyword) {
				if (stack.length > 0) stack.pop();
			} else if (elseKeywords.contains(directive.keyword) && stack.length > 0) {
				final top: CondFrame = stack[stack.length - 1];
				stack[stack.length - 1] = { region: top.region, branch: top.branch + 1 };
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

}

/** One open conditional region at a position: which region, and which of its branches. */
typedef CondFrame = {
	final region: Int;
	final branch: Int;
};

/** The replayed directive marks of one source, in source order — `CondBranchPath.scan`'s result. */
typedef CondBranchIndex = Array<{ at: Int, path: Array<CondFrame> }>;
