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
	 */
	public static function nested(d: Doc): Array<Doc> {
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
	 * `shape(inner)`, offered once more per break nested in `inner` — `shape` laid out with that break committed, and
	 * every COMMITTED break (a token-less `BreakCommit`) read as its bare `brk` rather than as the source form a next
	 * rewrite reads. For a host whose next rewrite does not measure that break at all: an expression paren keeps the
	 * open/glued layout its own source line shape states, so its first write must measure the break as it always has,
	 * or it settles on the other of its two fixed points.
	 */
	public static function followBare(inner: Doc, shape: Doc -> Doc): Doc {
		var out: Doc = shape(inner);
		for (c in outermostPerToken(nested(inner))) switch c {
			case BreakCommit(brk, _, token) if (token != null):
				out = BreakCommit(shape(bare(replaced(inner, c, brk))), out, token);
			case _:
		}
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
	 * A COMMITTED break: `source`, the layout the next rewrite reads from its own source and every walker reads, with
	 * `bare` kept for `followBare`. A `BreakCommit` with no token, which no measure render can resolve to `brk`.
	 */
	public static inline function committed(bare: Doc, source: Doc): Doc {
		return BreakCommit(bare, source, null);
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
	 * `body` with the width decision it wholly is — `IfFirstLineExceeds(n, brk, flat)` or
	 * `GroupWithRestProbe(IfBreak(brk, flat))` behind `WrapBoundary` / one-element `Concat` wrappers, the shapes an object
	 * literal's own wrap rule emits — replaced by `f(brk, rebuild)`, where `rebuild(b)` is that decision with `b` for its
	 * break side; `null` when `body` is anything else.
	 */
	public static function decisionMapped(body: Doc, f: (brk:Doc, rebuild:Doc -> Doc) -> Doc): Null<Doc> {
		return switch body {
			case IfFirstLineExceeds(n, brk, flat):
				f(brk, b -> IfFirstLineExceeds(n, b, flat));
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
			if (token != null && !tokens.contains(token)) {
				tokens.push(token);
				added = true;
			}
		}
		return added;
	}

}
