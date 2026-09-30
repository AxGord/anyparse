package anyparse.core;

import anyparse.format.IndentChar;

using Lambda;

/**
 * Resolves every `Doc.BreakCommit` before the collapse pass and the emit render see the Doc.
 *
 * A `BreakCommit` offers two layouts of one construct and answers by a `LeadingBreak` decided at render time, so the
 * pass renders once to MEASURE — the renderer records each `LeadingBreak` it takes, at its true column, with every
 * decision around it resolved as the emit render will — and then REWRITES each node to the layout its break asked
 * for. The render-twice model `CollapsePass` uses, for the same reason: the choice depends on a column only the
 * renderer knows. Every node is answered from the one measure render, with every other node on its `flat`
 * side. Two limits follow from that: the measure runs BEFORE the collapse pass, so a collapse that later moves
 * a column can in principle fire a still-live `LeadingBreak` the measure did not see; and each alternative
 * forces only its own break, so when a list and a node nested in it both break, only the outermost is forced
 * and the rest stay live decisions. Neither reproduced over the multi-break and collapse-context sweeps.
 */
@:nullSafety(Strict)
final class BreakCommits {

	/** `doc` with every `BreakCommit` resolved, or `doc` itself when it holds none. */
	public static function resolve(doc: Doc, width: Int, indentChar: IndentChar, tabWidth: Int, indentSize: Int): Doc {
		if (nested(doc).length == 0) return doc;
		final taken: Array<{ node: Doc, crosses: Bool, ?indent: Int }> = [];
		// The measure render's text is not the answer; the breaks it records in `taken` are.
		Renderer.render(doc, width, indentChar, tabWidth, indentSize, '\n', false, false, -1, taken); // noqa: unused-return-value
		final tokens: Array<BreakToken> = [];
		for (e in taken) switch e.node {
			case LeadingBreak(_, _, token) if (token != null):
				tokens.push(token);
			case _:
		}
		return commit(doc, tokens, new DocIdentityMap());
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

}
