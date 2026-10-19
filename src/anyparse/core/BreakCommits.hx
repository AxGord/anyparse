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
	 * A COMMITTED break: `source`, the layout the next rewrite reads from its own source and every walker reads, with
	 * `bare` kept for `followBare`. A `BreakCommit` with no token, which no measure render can resolve to `brk`.
	 */
	public static inline function committed(bare: Doc, source: Doc): Doc {
		return BreakCommit(bare, source, null);
	}

	/**
	 * `doc` with every `BreakCommit` resolved, or `doc` itself when it holds none. A layout one round committed can move a
	 * break the round before saw at another column (a list that opens pushes a literal in it past the limit), so the
	 * committed layout is measured again, and resolved again from `doc` with every break taken so far, until a round
	 * takes no new break.
	 */
	public static function resolve(doc: Doc, width: Int, indentChar: IndentChar, tabWidth: Int, indentSize: Int): Doc {
		if (nested(doc).length == 0) return doc;
		final tokens: Array<BreakToken> = [];
		var measured: Doc = doc;
		for (_ in 0...MEASURE_ROUNDS) {
			if (!tookNewBreaks(measured, width, indentChar, tabWidth, indentSize, tokens)) break;
			measured = commit(doc, tokens, new DocIdentityMap());
		}
		return measured == doc ? commit(doc, tokens, new DocIdentityMap()) : measured;
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

	/** `d` with every occurrence of the node `target` replaced by `by`. */
	public static function replaced(d: Doc, target: Doc, by: Doc): Doc {
		final memo: DocIdentityMap<Doc> = new DocIdentityMap();
		function walk(n: Doc): Doc {
			if (n == target) return by;
			final hit: Null<Doc> = memo.get(n);
			if (hit != null) return hit;
			final out: Doc = D.mapChildren(n, walk);
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
	 * into bodies as `nested` does. Each alternative commits only its own break: when two are taken, the one offered last
	 * wins and the other stays a live decision inside it.
	 */
	public static function offerItemBreaks(
		items: Array<Doc>, plain: Doc, laidOut: (items:Array<Doc>, committed:Int) -> Doc, ?wanted: (item:Doc, i:Int, broken:Doc) -> Bool,
		throughBodies: Bool = false
	): Doc {
		var out: Doc = plain;
		for (i => item in items) for (inner in outermostPerToken(nested(item, throughBodies))) switch inner {
			case BreakCommit(brk, _, token) if (token != null):
				final broken: Doc = replaced(item, inner, brk);
				if (wanted == null || wanted(item, i, broken)) {
					final with: Array<Doc> = items.copy();
					with[i] = broken;
					out = BreakCommit(laidOut(with, i), out, token);
				}
			case _:
		}
		return out;
	}

	/**
	 * `shape(inner)`, offered once more per break nested in `inner` — `shape` laid out with that break committed, and
	 * every COMMITTED break (a token-less `BreakCommit`) read as its bare `brk` rather than as the source form a next
	 * rewrite reads. For a host whose next rewrite does not measure that break at all: an expression paren keeps the
	 * open/glued layout its own source line shape states, so its first write must measure the break as it always has,
	 * or it settles on the other of its two fixed points.
	 */
	public static function followBare(inner: Doc, shape: Doc -> Doc): Doc {
		return offerItemBreaks([inner], shape(inner), (with, _) -> shape(bare(with[0])), true);
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
		final hit: Null<Doc> = memo.get(d);
		if (hit != null) return hit;
		final out: Doc = switch d {
			case BreakCommit(brk, flat, token): commit(token != null && tokens.contains(token) ? brk : flat, tokens, memo);
			case _: D.mapChildren(d, c -> commit(c, tokens, memo));
		};
		memo.set(d, out);
		return out;
	}

	/** `d` with every committed break (a `BreakCommit` with no token) replaced by its bare `brk`. */
	private static function bare(d: Doc): Doc {
		final memo: DocIdentityMap<Doc> = new DocIdentityMap();
		function walk(n: Doc): Doc {
			final hit: Null<Doc> = memo.get(n);
			if (hit != null) return hit;
			final out: Doc = switch n {
				case BreakCommit(brk, _, null): walk(brk);
				case _: D.mapChildren(n, walk);
			};
			memo.set(n, out);
			return out;
		}
		return walk(d);
	}

	/**
	 * Renders `doc` to measure and appends to `tokens` every break it takes (a `LeadingBreak` or a `BreakMark`) that
	 * `tokens` does not hold yet; `true` when it appended one.
	 */
	private static function tookNewBreaks(
		doc: Doc, width: Int, indentChar: IndentChar, tabWidth: Int, indentSize: Int, tokens: Array<BreakToken>
	): Bool {
		final taken: Array<{ node: Doc, crosses: Bool, ?indent: Int }> = [];
		// The measure render's text is not the answer; the breaks it records in `taken` are.
		Renderer.render(doc, width, indentChar, tabWidth, indentSize, '\n', false, false, -1, taken); // noqa: unused-return-value
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
			case Concat(_) | Nest(_, _): D.mapChildren(d, hardSeams);
			case _: d;
		};
	}

}
