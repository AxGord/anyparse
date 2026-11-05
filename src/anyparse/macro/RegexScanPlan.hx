package anyparse.macro;

using Lambda;

/**
 * The one answer to "can this terminal's regex be scanned without backtracking": the pattern's tree when one
 * committed left-to-right pass reaches the very match a backtracking engine reports, `null` otherwise.
 *
 * Such a pass commits to the first branch or iteration that holds, so it is right only where undoing a commitment
 * could not have made a later part succeed. That holds when a loop's first set is disjoint from what may follow it,
 * or nothing that follows can fail; and when an alternation's branches begin with disjoint sets. A lookahead asks
 * whether ANY path matches, so its head alternation may overlap: each branch is tried with the tail after it.
 *
 * A null answer costs speed only; the terminal stays on the regex engine. Not `#if macro`, for the reason `CodeSet`
 * is not: `RegexScanPlanTest` compares each answer against the real regex.
 */
@:nullSafety(Strict)
final class RegexScanPlan {

	/** The tree of `pattern` when a committed pass matches what the regex matches, else `null`. */
	public static function of(pattern: String): Null<ScanNode> {
		final node: Null<ScanNode> = RegexScanReader.read(pattern);
		return node != null && holds(node, end()) ? node : null;
	}

	/** The branches and tail of a lookahead body that opens with an alternation, or `null` for any other body. */
	public static function headAlternation(body: ScanNode): Null<AheadBranches> {
		return switch body {
			case Alt(branches): { branches: branches, tail: [] };
			case Seq(items) if (items.length > 0):
				switch items[0] {
					case Alt(branches): { branches: branches, tail: items.slice(1) };
					case _: null;
				}
			case _: null;
		};
	}

	/** The code units a non-empty match of `node` may begin with. */
	public static function firstOf(node: ScanNode): CodeSet {
		return switch node {
			case Chars(set): set;
			case Seq(items):
				var first: CodeSet = CodeSet.empty();
				for (item in items) {
					first = first.union(firstOf(item));
					if (!nullable(item)) break;
				}
				first;
			case Alt(branches):
				var first: CodeSet = CodeSet.empty();
				for (branch in branches) first = first.union(firstOf(branch));
				first;
			case Repeat(body, _, _): firstOf(body);
			case Ahead(_, _), WordBoundary: CodeSet.empty();
		};
	}

	/** Whether `node` may match without consuming. */
	public static function nullable(node: ScanNode): Bool {
		return switch node {
			case Chars(_): false;
			case Seq(items): items.filter(item -> !nullable(item)).length == 0;
			case Alt(branches): branches.filter(nullable).length > 0;
			case Repeat(body, min, _):
				min == 0 || nullable(body);
			case Ahead(_, _), WordBoundary: true;
		};
	}

	/** The end of the pattern: nothing follows and nothing can fail. */
	private static function end(): Follow {
		return { first: CodeSet.empty(), infallible: true };
	}

	/** Whether committing inside `node` is safe when `follow` comes after it. */
	private static function holds(node: ScanNode, follow: Follow): Bool {
		return switch node {
			case Chars(_), WordBoundary: true;
			case Seq(items):
				var after: Follow = follow;
				var ok: Bool = true;
				var i: Int = items.length;
				while (ok && --i >= 0) {
					ok = holds(items[i], after);
					after = prepended(items[i], after);
				}
				ok;
			case Alt(branches):
				!overlaps(branches) && branches.filter(branch -> !holds(branch, follow)).length == 0;
			case Repeat(body, _, many):
				final first: CodeSet = firstOf(body);
				final inside: Follow = many ? { first: first.union(follow.first), infallible: follow.infallible } : follow;
				!nullable(body) && (follow.infallible || !first.intersects(follow.first)) && holds(body, inside);
			case Ahead(body, _): anyPathHolds(body);
		};
	}

	/** Whether a pass can answer "does any path of `body` match": a head alternation split per branch, else committed. */
	private static function anyPathHolds(body: ScanNode): Bool {
		final split: Null<AheadBranches> = headAlternation(body);
		return split == null ? holds(body, end()) : split.branches.foreach(branch -> holds(Seq([branch].concat(split.tail)), end()));
	}

	/** What may follow once `node` comes before `after`. */
	private static function prepended(node: ScanNode, after: Follow): Follow {
		return switch node {
			case Repeat(body, 0, _): { first: firstOf(body).union(after.first), infallible: after.infallible };
			case Ahead(body, false): { first: nullable(body) ? CodeSet.all() : firstOf(body), infallible: false };
			case Ahead(_, true), WordBoundary: { first: after.infallible ? CodeSet.all() : after.first, infallible: false };
			case Seq(items):
				var result: Follow = after;
				var i: Int = items.length;
				while (--i >= 0) result = prepended(items[i], result);
				result;
			case _: { first: nullable(node) ? CodeSet.all() : firstOf(node), infallible: false };
		};
	}

	/** Whether two of `branches` may begin alike, or one may match without consuming. */
	private static function overlaps(branches: Array<ScanNode>): Bool {
		var seen: CodeSet = CodeSet.empty();
		for (branch in branches) {
			final first: CodeSet = firstOf(branch);
			if (nullable(branch) || seen.intersects(first)) return true;
			seen = seen.union(first);
		}
		return false;
	}

}

/** What may come after a node in its pattern. */
private typedef Follow = {
	/** A superset of the code units the rest may begin with, an assertion's reach counted. */
	final first: CodeSet;

	/** The rest matches from anywhere: all of it optional, no assertion in it. */
	final infallible: Bool;
}

/** A lookahead body split at its head alternation. */
typedef AheadBranches = {
	final branches: Array<ScanNode>;
	final tail: Array<ScanNode>;
}
