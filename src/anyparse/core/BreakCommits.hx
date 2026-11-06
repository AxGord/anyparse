package anyparse.core;

import anyparse.format.IndentChar;

/**
 * Resolves every `Doc.BreakCommit` before the collapse pass and the emit render see the Doc.
 *
 * A `BreakCommit` offers two layouts of one construct and answers by a break decided at render time — a `LeadingBreak`
 * the renderer adds, or a `BreakMark` on the break side of a construct's own width decision (`named`) — so the pass
 * renders once to MEASURE — the renderer records each such break it takes, at its true column, with every decision
 * around it resolved as the emit render will — and then REWRITES each node to the layout its break asked for. The
 * render-twice model `CollapsePass` uses, for the same reason: the choice depends on a column only the renderer knows.
 * A committed layout can move a break the measure saw at another column (a call that opens around a comprehension
 * pushes a literal in it past the limit), so the committed layout is measured again until a round takes no new break
 * (`MEASURE_ROUNDS` at most); a break taken once stays taken. Two limits remain: the measure runs BEFORE the collapse
 * pass, so a collapse that later moves a column can in principle fire a still-live break the measure did not see; and
 * each alternative forces only its own break, so when a list and a node nested in it both break, only the outermost is
 * forced and the rest stay live decisions. Neither reproduced over the multi-break and collapse-context sweeps.
 */
@:nullSafety(Strict)
final class BreakCommits {

	/** The most measure renders `resolve` runs: each one past the first only follows a layout the one before committed. */
	private static inline final MEASURE_ROUNDS: Int = 4;

	/**
	 * The most breaks `offerItemBreaks` offers in every combination. Each combination is one more layout of the host, so
	 * the alternatives double with every break offered; past this count each alternative commits only its own break.
	 */
	private static inline final COMBINED_OFFERS: Int = 2;

	/**
	 * A COMMITTED break: `source`, the layout the next rewrite reads from its own source and every walker reads, with
	 * `bare` kept for `followBare`. A `BreakCommit` with no token, which no measure render can resolve to `brk`.
	 */
	public static inline function committed(bare: Doc, source: Doc): Doc {
		return BreakCommit(bare, source, null);
	}

	/**
	 * `decision`, a list's own width decision the next rewrite takes again rather than reading its break from the source:
	 * it drops the list's source newlines (`WrapMode.Ignore`, a value-`if` branch's literal). So no host may lay itself out
	 * for that break, and this `committed` form, which holds the decision on both sides, is what `named` leaves alone.
	 */
	public static inline function redecided(decision: Doc): Doc {
		return committed(decision, decision);
	}

	/**
	 * `doc` with every `BreakCommit` resolved, or `doc` itself when it holds none. A layout one round committed can move a
	 * break the round before saw at another column (a list that opens pushes a literal in it past the limit), so the
	 * committed layout is measured again, and resolved again from `doc` with every break taken so far, until a round
	 * takes no new break.
	 */
	public static function resolve(doc: Doc, width: Int, indentChar: IndentChar, tabWidth: Int, indentSize: Int): Doc {
		return resolveMeasured(doc, width, indentChar, tabWidth, indentSize).doc;
	}

	/**
	 * `resolve`, with the decisions of the measure render that laid out the Doc it returns. Every measure renders a fully
	 * committed Doc, the first one with every offer on its plain side, so a round that takes no new break has measured the
	 * Doc the emit render gets, and its decisions are the ones `CollapsePass` measures that Doc for.
	 */
	public static function resolveMeasured(doc: Doc, width: Int, indentChar: IndentChar, tabWidth: Int, indentSize: Int): ResolvedDoc {
		final settled: Null<Doc> = settledWithoutMeasure(doc);
		if (settled != null) {
			final out: Doc = settled;
			return { doc: out, decisions: null };
		}
		final tokens: Array<BreakToken> = [];
		var measured: Doc = commit(doc, tokens, new DocIdentityMap());
		for (_ in 0...MEASURE_ROUNDS) {
			final taken: Array<{ node: Doc, crosses: Bool, ?indent: Int }> = [];
			// The measure render's text is not the answer; the decisions it records in `taken` are.
			Renderer.render(measured, width, indentChar, tabWidth, indentSize, '\n', false, false, -1, taken); // noqa: unused-return-value
			if (!tookNewBreaks(taken, tokens)) return { doc: measured, decisions: taken };
			measured = commit(doc, tokens, new DocIdentityMap());
		}
		return { doc: measured, decisions: null };
	}

	/**
	 * Every `BreakCommit` in `d`, including the ones on the `flat` side of another, which is the layout they stand in
	 * until resolved — and none on a `brk` side, which only exists once its own node resolves to it.
	 *
	 * With `throughBodies` false none inside a `BodyGroup` either: a fit body's own seam is a decision the next rewrite
	 * takes again from the body it reads back (a comprehension body that breaks goes to the next line), so a list cannot
	 * lay itself out for a break inside one from the committed break alone.
	 */
	public static function nested(d: Doc, throughBodies: Bool = true): Array<Doc> {
		final found: Array<Doc> = [];
		final seen: DocIdentityMap<Bool> = new DocIdentityMap();
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			final node: Null<Doc> = stack.pop();
			if (node == null || seen.exists(node)) continue;
			seen.set(node, true);
			switch node {
				case BreakCommit(_, flat, _):
					found.push(node);
					stack.push(flat);
				case BodyGroup(_) if (!throughBodies):
				case _:
					for (c in CollapsePass.children(node)) stack.push(c);
			}
		}
		return found;
	}

	/**
	 * `d` with every occurrence of the node `target` replaced by `by` on the side every walker reads: a `BreakCommit`'s
	 * `brk` is another break's alternative and comes back as it is, the way `nested` never looks there, so each offer
	 * copies only the path to its own break and nested hosts stay polynomial in depth. `holds`, when given, records which
	 * nodes have a `BreakCommit` anywhere below them: a subtree with none comes back unwalked, one map for every target.
	 */
	public static function replaced(d: Doc, target: Doc, by: Doc, ?holds: DocIdentityMap<Bool>): Doc {
		final memo: DocIdentityMap<Doc> = new DocIdentityMap();
		final pruned: Bool = holds != null;
		final index: DocIdentityMap<Bool> = holds ?? new DocIdentityMap();
		function walk(n: Doc): Doc {
			if (n == target) return by;
			if (pruned && !holdsCommit(n, index)) return n;
			final hit: Null<Doc> = memo.get(n);
			if (hit != null) return hit;
			final out: Doc = switch n {
				case BreakCommit(brk, flat, token):
					final f: Doc = walk(flat);
					f == flat ? n : BreakCommit(brk, f, token);
				case _: D.mapChildrenShared(n, walk);
			};
			memo.set(n, out);
			return out;
		}
		return walk(d);
	}

	/**
	 * `commits` (in `nested` order) keeping, for each `BreakToken`, only its FIRST node: the outermost one, whose `brk`
	 * side already holds every list nested under it laid out for the same break. The nodes of one token resolve
	 * together, so one alternative per token is the whole answer; offering one per node makes every list re-offer the
	 * alternatives of each list nested in it, which grows the Doc exponentially with the nesting depth.
	 */
	public static function outermostPerToken(commits: Array<Doc>): Array<Doc> {
		final kept: Array<Doc> = [];
		final seen: Array<BreakToken> = [];
		for (c in commits) switch c {
			case BreakCommit(_, _, token) if (token != null && !seen.contains(token)):
				seen.push(token);
				kept.push(c);
			case _:
		}
		return kept;
	}

	/**
	 * `plain`, offered once more per break nested in one of `items` — for each token its outermost node, and by default none
	 * inside a `BodyGroup` (`nested(item, false)`) — as `laidOut(with, i)`: the host laid out again from `with`, `items` with
	 * item `i` holding that break committed. A host whose layout reads its items' Docs at build time so lays itself out the
	 * way the next rewrite will, which reads the break from the source. `wanted(item, i, broken)` keeps an offer only when
	 * the committed item changes what the host reads from it; without it every break is offered. `throughBodies` reaches
	 * into bodies as `nested` does. Up to `COMBINED_OFFERS` breaks are offered in every combination, so two that are both
	 * taken (a literal in each branch of a ternary) lay the host out with both committed; past it each alternative commits
	 * only its own break, the one offered last wins and the other stays a live decision inside it.
	 */
	public static function offerItemBreaks(
		items: Array<Doc>, plain: Doc, laidOut: (items:Array<Doc>, committed:Int) -> Doc, ?wanted: (item:Doc, i:Int, broken:Doc) -> Bool,
		throughBodies: Bool = false
	): Doc {
		final holds: DocIdentityMap<Bool> = new DocIdentityMap();
		final offers: Array<ItemBreak> = [];
		for (i => item in items) for (inner in outermostPerToken(nested(item, throughBodies))) switch inner {
			case BreakCommit(brk, _, token) if (token != null):
				offers.push({
					item: i,
					node: inner,
					brk: brk,
					token: token
				});
			case _:
		}
		final combined: Bool = offers.length <= COMBINED_OFFERS;
		final keep: (item:Doc, i:Int, broken:Doc) -> Bool = wanted ?? (_, _, _) -> true;
		// The alternative for offer `k` holds the offers before it, laid out on top of its own committed break: the
		// measure resolves the outermost taken token first, so every taken subset reaches the layout committing it whole.
		function offered(with: Array<Doc>, host: Doc, upTo: Int): Doc {
			var out: Doc = host;
			for (k in 0...upTo) {
				final offer: ItemBreak = offers[k];
				final broken: Doc = replaced(with[offer.item], offer.node, offer.brk, holds);
				if (broken == with[offer.item] || !keep(with[offer.item], offer.item, broken)) continue;
				final next: Array<Doc> = with.copy();
				next[offer.item] = broken;
				final alone: Doc = laidOut(next, offer.item);
				out = BreakCommit(combined ? offered(next, alone, k) : alone, out, offer.token);
			}
			return out;
		}
		return offered(items, plain, offers.length);
	}

	/**
	 * `shape(inner)`, offered once more per break nested in `inner` — `shape` laid out with that break committed, and
	 * every COMMITTED break (a token-less `BreakCommit`) read as its bare `brk` rather than as the source form a next
	 * rewrite reads. For a host whose next rewrite does not measure that break at all: an expression paren keeps the
	 * open/glued layout its own source line shape states, so its first write must measure the break as it always has,
	 * or it settles on the other of its two fixed points.
	 */
	public static function followBare(inner: Doc, shape: Doc -> Doc): Doc {
		// One memo for every alternative: they share all but the path to their own break, so each shared subtree is
		// stripped once.
		final memo: DocIdentityMap<Doc> = new DocIdentityMap();
		return offerItemBreaks([inner], shape(inner), (with, _) -> shape(bare(with[0], memo)), true);
	}

	/**
	 * `body` with its own width decision offered as the next rewrite reads it back, or `body` itself when it is not wholly
	 * one of the decisions `decisionMapped` reads. The decision stays where it was, with a `BreakMark` on its break side;
	 * around it a `BreakCommit` on the same token holds the broken body as that rewrite reads the newlines it printed (a
	 * source-multi-line literal, `committed(brk, BodyGroup(brk))`). Every walker keeps reading the decision until the
	 * measure render shows it breaking, and then every host around it — a list measuring its items, the item's own
	 * first line — reads the broken body the next rewrite will read.
	 */
	public static function named(body: Doc): Doc {
		return decisionMapped(body, (brk, rebuild) -> {
			final token: BreakToken = new BreakToken();
			BreakCommit(committed(brk, BodyGroup(brk)), rebuild(BreakMark(brk, token)), token);
		}) ?? body;
	}

	/**
	 * A `sameLine.conditionalExprFit` region — the group `inner` whose soft seams break together — offered as the next
	 * rewrite reads it back once it breaks. That rewrite reads every seam newline the broken group printed from the source
	 * and writes it as a hardline, so it measures the region as multi-line where the first write measured an undecided
	 * group: a list holding the region (call arguments filling a line) laid its items out from the flat width and opened
	 * before the `#if`, and the next rewrite, reading the first line `#if cond` only, glued it to the previous argument.
	 * The group stays where it was, with a `BreakMark` on its break side; around it a `BreakCommit` on the same token holds
	 * the region with its seams as hardlines, committed (`bare` keeps the undecided group for `followBare`).
	 */
	public static function namedRegion(inner: Doc): Doc {
		final token: BreakToken = new BreakToken();
		final readBack: Doc = committed(GroupWithRestProbe(inner), GroupWithRestProbe(hardSeams(inner)));
		// The mark is an empty probe the group's own mode picks, so every walker measures the group exactly as before.
		return BreakCommit(readBack, GroupWithRestProbe(Concat([IfBreak(BreakMark(Empty, token), Empty), inner])), token);
	}

	/**
	 * `body` with the width decision it wholly is — `IfFirstLineExceeds(n, brk, flat)`,
	 * `GroupWithRestProbe(IfBreak(brk, flat))` or `Group(IfWidthExceeds(n, brk, flat))` (a
	 * `lineLength` rule) behind `WrapBoundary` / one-element `Concat` wrappers, the shapes an object
	 * literal's own wrap rule emits — replaced by `f(brk, rebuild)`, where `rebuild(b)` is that decision with `b` for its
	 * break side; `null` when `body` is anything else.
	 */
	public static function decisionMapped(body: Doc, f: (brk:Doc, rebuild:Doc -> Doc) -> Doc): Null<Doc> {
		return switch body {
			case IfFirstLineExceeds(n, brk, flat):
				f(brk, b -> IfFirstLineExceeds(n, b, flat));
			case Group(IfWidthExceeds(n, brk, flat)):
				f(brk, b -> Group(IfWidthExceeds(n, b, flat)));
			case GroupWithRestProbe(IfBreak(brk, flat)):
				f(brk, b -> GroupWithRestProbe(IfBreak(b, flat)));
			case WrapBoundary(inner):
				final mapped: Null<Doc> = decisionMapped(inner, f);
				mapped == null ? null : WrapBoundary(mapped);
			case Concat([inner]):
				final mapped: Null<Doc> = decisionMapped(inner, f);
				mapped == null ? null : Concat([mapped]);
			case _:
				null;
		};
	}

	private static function commit(d: Doc, tokens: Array<BreakToken>, memo: DocIdentityMap<Doc>): Doc {
		function walk(n: Doc): Doc {
			if (D.isLeaf(n)) return n;
			final hit: Null<Doc> = memo.get(n);
			if (hit != null) return hit;
			final out: Doc = switch n {
				case BreakCommit(brk, flat, token): walk(token != null && tokens.contains(token) ? brk : flat);
				case _: D.mapChildrenShared(n, walk);
			};
			memo.set(n, out);
			return out;
		}
		return walk(d);
	}

	/** `d` with every committed break (a `BreakCommit` with no token) replaced by its bare `brk`, through `memo`. */
	private static function bare(d: Doc, memo: DocIdentityMap<Doc>): Doc {
		function walk(n: Doc): Doc {
			final hit: Null<Doc> = memo.get(n);
			if (hit != null) return hit;
			final out: Doc = switch n {
				case BreakCommit(brk, _, null): walk(brk);
				case _: D.mapChildrenShared(n, walk);
			};
			memo.set(n, out);
			return out;
		}
		return walk(d);
	}

	/**
	 * Appends to `tokens` every break a measure render recorded in `taken` (a `LeadingBreak` or a `BreakMark`) that
	 * `tokens` does not hold yet; `true` when it appended one.
	 */
	private static function tookNewBreaks(taken: Array<{ node: Doc, crosses: Bool, ?indent: Int }>, tokens: Array<BreakToken>): Bool {
		var added: Bool = false;
		for (e in taken) {
			final token: Null<BreakToken> = switch e.node {
				case LeadingBreak(_, _, token): token;
				case BreakMark(_, token): token;
				case _: null;
			};
			if (token == null || tokens.contains(token)) continue;
			tokens.push(token);
			added = true;
		}
		return added;
	}

	/**
	 * `d` with every soft `Line` the enclosing group decides written as a hardline — the seams a broken group prints and
	 * the next rewrite reads back as source newlines. Only a `Concat` or a `Nest` is walked: every other node either
	 * decides its own lines (a nested group, a fill, a width decision) or is kept as it is, which renders the same inside
	 * the now-broken group.
	 */
	private static function hardSeams(d: Doc): Doc {
		return switch d {
			case Line(flat, verbatim) if (flat != '\n'): Line('\n', verbatim);
			case Concat(_), Nest(_, _): D.mapChildren(d, hardSeams);
			case _: d;
		};
	}

	/** True iff `n` is a `BreakCommit` or has one anywhere below it, on either side of every node; memoized in `holds`. */
	private static function holdsCommit(n: Doc, holds: DocIdentityMap<Bool>): Bool {
		final hit: Null<Bool> = holds.get(n);
		if (hit != null) return hit;
		var found: Bool = n.match(BreakCommit(_, _, _));
		if (!found) D.mapChildren(n, c -> {
			if (!found && holdsCommit(c, holds)) found = true;
			c;
		});
		holds.set(n, found);
		return found;
	}

	/**
	 * `d` with every committed break (a `BreakCommit` with no token) resolved to its `flat` side, or null when `d` holds a
	 * `BreakCommit` with a token, which only a measure render resolves. Only the nodes above a committed break are rebuilt,
	 * so a Doc holding none comes back as itself and the walk costs no more than `nested`.
	 */
	private static function settledWithoutMeasure(d: Doc): Null<Doc> {
		final memo: DocIdentityMap<Doc> = new DocIdentityMap();
		var measured: Bool = false;
		function walk(n: Doc): Doc {
			if (measured || D.isLeaf(n)) return n;
			final hit: Null<Doc> = memo.get(n);
			if (hit != null) return hit;
			final kids: Array<Doc> = CollapsePass.children(n);
			final out: Doc = switch n {
				case BreakCommit(_, flat, null): walk(flat);
				case BreakCommit(_, _, _):
					measured = true;
					n;
				case _:
					var changed: Bool = false;
					for (c in kids) if (walk(c) != c) changed = true;
					changed ? D.mapChildren(n, walk) : n;
			};
			memo.set(n, out);
			return out;
		}
		final out: Doc = walk(d);
		return measured ? null : out;
	}

}

/** One break `offerItemBreaks` offers: the `BreakCommit` `node` nested in item `item`, resolved to `brk` when `token` is taken. */
private typedef ItemBreak = {
	var item: Int;
	var node: Doc;
	var brk: Doc;
	var token: Null<BreakToken>;
}
