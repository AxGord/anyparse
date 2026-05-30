package anyparse.core;

import anyparse.format.IndentChar;

using Lambda;

/**
 * Doc→Doc pre-render collapse pass (increment-2 chain-collapse).
 *
 * Breaks the branch-blind circular coupling between an expression paren's
 * open decision (`IfFullLineExceeds(open, glued)`) and the enclosing
 * op-chain's break decision (`WrapBoundary(Group(IfBreak(brk, flat)))`):
 * these are mutually dependent two-branch `If*` Docs that the renderer
 * resolves INDEPENDENTLY and LATE with no shared state, so a single
 * bottom-up Doc construction cannot co-resolve them — the paren's open
 * depends on the column, which depends on whether the chain broke, which
 * depends on whether the paren opened.
 *
 * This pass runs BEFORE the main render and COMMITS the decisions:
 *
 *  1. MEASURE — run the renderer once in decision-capture mode
 *     (`Renderer.render(doc, …, decisions)`), recording at every
 *     `IfFullLineExceeds` node whether it crosses (would open) at its
 *     true render column. This reuses the renderer's real fit logic
 *     (the "render-twice" model — render to measure, rewrite to commit,
 *     render to emit), so the column/rest-stack context is exact, not
 *     re-derived by a hand-rolled left-context tracker.
 *
 *  2. REWRITE — walk the Doc top-down. Where an enclosing op-chain
 *     (`WrapBoundary(Group(IfBreak(brk, flat)))`, or the threshold-split
 *     variants `Group(IfWidthExceeds/IfFullLineExceeds(...))`) contains a
 *     collapse-candidate paren that the measure pass said WOULD open,
 *     commit the chain to its glued (`flat`) shape AND commit the inner
 *     paren to its open (`HardFlatten`-bearing) branch. The chain's glued
 *     shape is the anyparse analogue of fork `collapseChainBreaksAfter`
 *     (the `) / 2 - D` tail rides the close-paren line); the paren's
 *     `HardFlatten` inner is the analogue of fork
 *     `collapseInnerChainBreaks` (the inner opAddSub chain stays flat
 *     unconditionally once the paren opens). Where a candidate paren opens
 *     with no enclosing chain, commit the paren alone.
 *
 *  3. The normal renderer then emits the rewritten, fully-committed Doc.
 *     Because the paren-open is now a committed fact (not a branch-blind
 *     `If*`), the chain's glue decision reads a committed child — the
 *     circularity is gone.
 *
 * INVARIANT #1: the pass is pure (Doc→Doc, no global mutable state, no
 * AST mutation). It reads the immutable Doc IR and constructs a NEW Doc.
 * The only side channel is the per-call `decisions` list populated by the
 * measure render and discarded after the rewrite.
 *
 * Node identity: `IfFullLineExceeds` decisions are keyed by the node's
 * reference identity (Haxe enum `==` is reference equality on JS, NOT the
 * structural `Type.enumEq`). `haxe.ds.ObjectMap` rejects enum keys (its
 * `K:{}` constraint excludes enums), so the decisions are carried in a
 * side `Array<{node, crosses}>` and looked up by `==`.
 */
@:nullSafety(Strict)
final class CollapsePass {

	/**
	 * Entry point. Returns a rewritten Doc with expression-paren collapse
	 * decisions committed. When no collapse-candidate paren is present the
	 * returned Doc is structurally equivalent to `doc` (render-identical).
	 */
	public static function run(
		doc:Doc, width:Int, indentChar:IndentChar, tabWidth:Int
	):Doc {
		// Fast path: skip the measure render entirely when the Doc has no
		// collapse-candidate paren — the overwhelming common case. Keeps
		// the pass cost ~one structural walk for non-collapse outputs.
		if (!hasCandidate(doc)) return doc;

		final decisions:Array<{node:Doc, crosses:Bool}> = [];
		// Measure-only render: populates `decisions` at every
		// `IfFullLineExceeds`. The returned string is discarded.
		Renderer.render(doc, width, indentChar, tabWidth, '\n', false, false, -1, decisions);

		return rewrite(doc, decisions);
	}

	/**
	 * Structural top-down rewrite. Three behaviours:
	 *  - An enclosing op-chain whose `flat` (NoWrap/glued) branch contains
	 *    a candidate paren that opens → commit chain to glued + commit the
	 *    inner paren.
	 *  - A standalone candidate paren that opens → commit it to its open
	 *    branch (no chain wrapper to glue).
	 *  - Everything else → rebuild structurally, recursing into children.
	 */
	private static function rewrite(d:Doc, decisions:Array<{node:Doc, crosses:Bool}>):Doc {
		// Op-chain emitted by `BinaryChainEmit.emit`. When the chain's flat
		// (glued) branch contains a candidate paren that WOULD open, commit
		// the chain to its glued shape so the post-close-paren operands ride
		// the close-paren line (fork `collapseChainBreaksAfter`); the inner
		// paren then opens within it via `commitOpens`.
		final glued:Null<Doc> = chainGluedIfOpens(d, decisions);
		if (glued != null) return WrapBoundary(commitOpens(glued, decisions));

		// Standalone candidate paren that opens (no enclosing chain
		// committed it): commit to the open branch directly.
		switch d {
			case IfFullLineExceeds(_, open, _) if (isCandidate(d) && opens(d, decisions)):
				return rewrite(open, decisions);
			case _:
		}

		return mapChildren(d, child -> rewrite(child, decisions));
	}

	/**
	 * Commit every opening candidate paren inside `d` to its open branch,
	 * leaving non-opening parens and all other nodes rewritten normally.
	 * Used on a chain's committed-glued (`flat`) branch so the inner paren
	 * opens within the glued tail.
	 */
	private static function commitOpens(d:Doc, decisions:Array<{node:Doc, crosses:Bool}>):Doc {
		switch d {
			case IfFullLineExceeds(_, open, _) if (isCandidate(d) && opens(d, decisions)):
				return commitOpens(open, decisions);
			case _:
		}
		final glued:Null<Doc> = chainGluedIfOpens(d, decisions);
		if (glued != null) return WrapBoundary(commitOpens(glued, decisions));

		// A per-binary `Group` cascade on the spine between the committed
		// chain and the opened paren (e.g. `(paren) / 2` — the `/` is a
		// plain binary Group, NOT a `BinaryChainEmit` chain) would BREAK at
		// render because the opened paren injects hardlines into its
		// subtree, pushing the continuation (`/ 2`) onto its own line. The
		// anyparse analogue of fork `collapseChainBreaksAfter` extending past
		// `)` to the multiplicative operator: DROP the Group fit-gate and
		// flatten ONLY the non-paren siblings (the operator continuation),
		// while the paren-bearing child keeps its committed-open shape
		// (rendered MBreak — Nest indents, internal hardlines survive). This
		// glues `/ 2` onto the close-paren line without collapsing the
		// paren's own indent (which a blanket `Flatten` over the whole Group
		// would destroy). Gated on `subtreeOpens` so only the spine carrying
		// an opened paren is rewritten; sibling Groups are untouched.
		switch d {
			case Group(Concat(items)) | GroupWithRestProbe(Concat(items)) if (subtreeOpens(d, decisions)):
				return Concat([
					for (it in items)
						subtreeOpens(it, decisions) ? commitOpens(it, decisions) : Flatten(commitOpens(it, decisions))
				]);
			case Group(inner) | GroupWithRestProbe(inner) if (subtreeOpens(d, decisions)):
				return commitOpens(inner, decisions);
			case _:
		}

		return mapChildren(d, child -> commitOpens(child, decisions));
	}

	/**
	 * If `d` is a `BinaryChainEmit`-shaped op-chain whose glued (flat)
	 * branch contains a candidate paren that opens, return that glued
	 * branch (to be committed). Otherwise null.
	 *
	 * Chain emit signatures (all wrapped in `WrapBoundary`):
	 *  - `WrapBoundary(Group(IfBreak(brk, flat)))` — 0 extra thresholds.
	 *  - `WrapBoundary(Group(IfWidthExceeds(_, brk, flat)))` — 1 threshold
	 *    below lineWidth; `flat` is the no-fire (glued) shape.
	 *  - `WrapBoundary(Group(IfBreak(IfWidthExceeds(...), flat)))` — 1
	 *    threshold above lineWidth; outer `IfBreak.flat` is the glued shape.
	 * The glued branch is always the flat/no-fire side, which for the
	 * anchor's `opAddSubChain` config (`defaultWrap: noWrap`) is the
	 * NoWrap shape `items[0] op items[1] …`.
	 */
	private static function chainGluedIfOpens(d:Doc, decisions:Array<{node:Doc, crosses:Bool}>):Null<Doc> {
		final flat:Null<Doc> = switch d {
			case WrapBoundary(Group(IfBreak(_, fl))): fl;
			case WrapBoundary(Group(IfWidthExceeds(_, _, fl))): fl;
			case WrapBoundary(Group(IfFullLineExceeds(_, _, fl))): fl;
			case _: null;
		};
		if (flat == null) return null;
		return subtreeOpens(flat, decisions) ? flat : null;
	}

	/**
	 * A collapse-candidate paren is `IfFullLineExceeds(_, open, _)` whose
	 * `open` (break) branch contains a `CollapseProbe` region — the C2a/B
	 * ParenExpr consumer's emit signature. The `CollapseProbe` marks "this
	 * is an expression-paren-collapse open branch", distinguishing it from
	 * every other `IfFullLineExceeds` (chain-emit probes etc.) REGARDLESS of
	 * the inner's operator class. For an opAddSub inner the probe wraps a
	 * `HardFlatten` (the inner collapses to one line unconditionally); for an
	 * opBool/ternary inner it wraps the plain inner (which keeps its own wrap
	 * cascade) — but the candidate is recognised the same way in both cases,
	 * so the enclosing chain is committed to glued identically.
	 */
	private static function isCandidate(d:Doc):Bool {
		return switch d {
			case IfFullLineExceeds(_, open, _): containsCollapseProbe(open);
			case _: false;
		};
	}

	/** True iff the measure pass recorded `crosses == true` for node `d`. */
	private static function opens(d:Doc, decisions:Array<{node:Doc, crosses:Bool}>):Bool {
		// Node identity match — enum `==` is reference equality on JS, so this
		// finds the decision recorded for this exact `IfFullLineExceeds` node.
		final entry:Null<{node:Doc, crosses:Bool}> = decisions.find(e -> e.node == d);
		return entry != null && entry.crosses;
	}

	/** True iff `d`'s subtree contains a candidate paren that opens. */
	private static function subtreeOpens(d:Doc, decisions:Array<{node:Doc, crosses:Bool}>):Bool {
		var found:Bool = false;
		walk(d, node -> {
			if (!found && isCandidate(node) && opens(node, decisions)) found = true;
		});
		return found;
	}

	/** True iff `d`'s subtree contains any collapse-candidate paren. */
	private static function hasCandidate(d:Doc):Bool {
		var found:Bool = false;
		walk(d, node -> {
			if (!found && isCandidate(node)) found = true;
		});
		return found;
	}

	/** True iff `d`'s subtree contains a `CollapseProbe` region. */
	private static function containsCollapseProbe(d:Doc):Bool {
		var found:Bool = false;
		walk(d, node -> {
			if (!found) switch node {
				case CollapseProbe(_): found = true;
				case _:
			}
		});
		return found;
	}

	/**
	 * Pre-order structural walk applying `visit` to every node. Read-only;
	 * does not rebuild. Used by the candidate / open / hard-flatten probes.
	 */
	private static function walk(d:Doc, visit:Doc -> Void):Void {
		final stack:Array<Doc> = [d];
		while (stack.length > 0) {
			// `stack.length > 0` guard proves non-null; Strict won't narrow
			// `Array.pop()` on the runtime invariant (lang-haxe gotcha).
			final node:Doc = (cast stack.pop() : Doc);
			visit(node);
			switch node {
				case Empty | Text(_) | Line(_) | OptSpace(_) | OptHardline
						| OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline
						| OptSpaceSkipAfterHardline:
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner)
						| BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner)
						| HardFlatten(inner) | CollapseProbe(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfBreak(brk, fl) | IfWidthExceeds(_, brk, fl)
						| IfFirstLineExceeds(_, brk, fl) | IfLineExceeds(_, brk, fl)
						| IfFullLineExceeds(_, brk, fl) | IfNaturalFirstLineExceeds(_, brk, fl)
						| IfNaturalFirstLineFitsOpenDelim(_, brk, fl):
					stack.push(brk);
					stack.push(fl);
				case Fill(items, sep, _) | FillWithRestProbe(items, sep, _):
					for (it in items) stack.push(it);
					stack.push(sep);
			}
		}
	}

	/**
	 * Rebuild `d` applying `f` to each direct child. Leaf nodes return
	 * `d` unchanged. Preserves every ctor's structure — pure
	 * structure-preserving map (no decision logic here).
	 */
	private static function mapChildren(d:Doc, f:Doc -> Doc):Doc {
		return switch d {
			case Empty | Text(_) | Line(_) | OptSpace(_) | OptHardline
					| OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline
					| OptSpaceSkipAfterHardline:
				d;
			case Nest(n, inner): Nest(n, f(inner));
			case Group(inner): Group(f(inner));
			case GroupWithRestProbe(inner): GroupWithRestProbe(f(inner));
			case BodyGroup(inner): BodyGroup(f(inner));
			case Flatten(inner): Flatten(f(inner));
			case WrapBoundary(inner): WrapBoundary(f(inner));
			case HardFlatten(inner): HardFlatten(f(inner));
			case CollapseProbe(inner): CollapseProbe(f(inner));
			case Concat(items): Concat([for (it in items) f(it)]);
			case IfBreak(brk, fl): IfBreak(f(brk), f(fl));
			case IfWidthExceeds(n, brk, fl): IfWidthExceeds(n, f(brk), f(fl));
			case IfFirstLineExceeds(n, brk, fl): IfFirstLineExceeds(n, f(brk), f(fl));
			case IfLineExceeds(n, brk, fl): IfLineExceeds(n, f(brk), f(fl));
			case IfFullLineExceeds(n, brk, fl): IfFullLineExceeds(n, f(brk), f(fl));
			case IfNaturalFirstLineExceeds(n, brk, fl): IfNaturalFirstLineExceeds(n, f(brk), f(fl));
			case IfNaturalFirstLineFitsOpenDelim(n, brk, fl): IfNaturalFirstLineFitsOpenDelim(n, f(brk), f(fl));
			case Fill(items, sep, tr): Fill([for (it in items) f(it)], f(sep), tr);
			case FillWithRestProbe(items, sep, tr): FillWithRestProbe([for (it in items) f(it)], f(sep), tr);
		};
	}
}
