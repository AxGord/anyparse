package anyparse.query;

import anyparse.query.CompilerFacts.ExpansionFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.SpliceFact;
import anyparse.runtime.Span;

using StringTools;

/**
 * Where a fact of a node RUNS, read off the node alone: in the node's own range (`placed`), at the
 * sites of the inlined call that spliced it in (`spliceOf`), or where the expression macro that
 * built it was expanded (`expansionOf`, `expansionSites`).
 *
 * Its own module rather than statics of `CompilerFacts` because none of it reads the table — a
 * `FactNode` carries its ranges, splices and expansions — so the answers belong to the node, and
 * every reader that already holds one (the call graph's facts edges, provenance, `FactsView`) asks
 * here without going through the table.
 */
@:nullSafety(Strict)
final class FactSites {

	/**
	 * Whether the fact at `at` lies in the range of its node `n`: one outside it — in another file, or elsewhere in the
	 * node's own — was spliced in by inlining, at its callee's positions (`TypedFactsProbe`), and runs at a site of the node
	 * no range names.
	 */
	public static function placed(n: FactNode, at: FactPos): Bool {
		return at.file == n.at.file && n.at.span.from <= at.span.from && at.span.to <= n.at.span.to;
	}

	/**
	 * The splice that brought the fact at `at` into `n`: the innermost declared range of a method an inlined call of `n`
	 * spliced in that holds it (`FactNode.splices`) — the code runs at a site of that splice, and nowhere else in `n`. Null
	 * for a fact `n` places itself, and for one no such range holds: the compiler put it where no method is declared, or
	 * the facts record no site for the call (`CallFact.site`), and it may run anywhere in `n`.
	 */
	public static function spliceOf(n: FactNode, at: FactPos): Null<SpliceFact> {
		if (placed(n, at)) return null;
		var best: Null<SpliceFact> = null;
		for (s in n.splices) {
			final body: Span = s.body.span;
			final holds: Bool = s.body.file == at.file && body.from <= at.span.from && at.span.to <= body.to;
			if (holds && (best == null || body.to - body.from < best.body.span.to - best.body.span.from)) best = s;
		}
		return best;
	}

	/**
	 * The expansion of an expression macro that brought the fact at `at` into `n`: the innermost one whose macro's declared
	 * range holds it (`ExpansionFact.declared`) — the code that macro built, which runs where the compiler replaced the call
	 * of it (`expansionSites`). Null for a fact `n` places itself, for one a splice brought (`spliceOf`), and for one no such
	 * range holds.
	 */
	public static function expansionOf(n: FactNode, at: FactPos): Null<ExpansionFact> {
		if (placed(n, at) || spliceOf(n, at) != null) return null;
		var best: Null<ExpansionFact> = null;
		for (x in n.expansions) {
			final declared: Null<FactPos> = x.declared;
			if (declared == null || declared.file != at.file || at.span.from < declared.span.from || declared.span.to < at.span.to)
				continue;
			final size: Int = declared.span.to - declared.span.from;
			final known: Null<FactPos> = best?.declared;
			if (known == null || size < known.span.to - known.span.from) best = x;
		}
		return best;
	}

	/**
	 * Where in the file of `n` the code the expansion `x` built runs: at its anchor, the expression around the call of the
	 * macro the compiler replaced, when `n` places it; at the sites of the inlined call whose method's code holds the anchor
	 * (`spliceOf`); or where the expansion whose code holds the anchor runs, in turn. Null when none of these says: the code
	 * may run anywhere in `n`.
	 */
	public static function expansionSites(n: FactNode, x: ExpansionFact): Null<Array<Span>> {
		final seen: Array<ExpansionFact> = [];
		var current: ExpansionFact = x;
		while (!seen.contains(current)) {
			seen.push(current);
			final anchor: FactPos = current.anchor;
			if (placed(n, anchor)) return [anchor.span];
			final splice: Null<SpliceFact> = spliceOf(n, anchor);
			if (splice != null) return splice.sites;
			final outer: Null<ExpansionFact> = expansionOf(n, anchor);
			if (outer == null) return null;
			current = outer;
		}
		return null;
	}

}
