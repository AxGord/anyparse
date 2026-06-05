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
		doc:Doc, width:Int, indentChar:IndentChar, tabWidth:Int, indentSize:Int = 1
	):Doc {
		// Fast path: skip the measure render entirely when the Doc carries
		// NEITHER a forward collapse-candidate paren (`CollapseProbe`) NOR an
		// inverse inner-add-chain marker (`CollapseAddProbe`) — the
		// overwhelming common case. Keeps the pass cost ~one structural walk
		// for non-collapse outputs.
		final hasParenProbe:Bool = hasCandidate(doc);
		final hasAddProbe:Bool = hasAddCandidate(doc);
		if (!hasParenProbe && !hasAddProbe) return doc;

		final decisions:Array<{node:Doc, crosses:Bool}> = [];
		// Measure-only render: populates `decisions` at every
		// `IfFullLineExceeds` (forward) AND every reached `CollapseAddProbe`
		// (inverse — recorded `crosses = reached-in-break-mode`). The returned
		// string is discarded.
		Renderer.render(doc, width, indentChar, tabWidth, indentSize, '\n', false, false, -1, decisions);

		// ONE top-down rewrite over the ORIGINAL `doc` (so every decision —
		// `IfFullLineExceeds` forward, `CollapseAddProbe` inverse — is keyed by
		// the node identity the measure render saw). The walk threads
		// `insideBroken` for the inverse direction (outer-add-chain-broke ⇒
		// inner-add-chain-collapse). A separate second pass would rebuild the
		// tree and lose the other direction's node identities, so both are
		// resolved in this single pass.
		return rewrite(doc, decisions, false);
	}

	/**
	 * Structural top-down rewrite. Behaviours:
	 *  - INVERSE (ω-unwrap-add-ops): a tagged opAddSub chain
	 *    `WrapBoundary(Group(IfBreak(CollapseAddProbe(brk), flat)))` inside a
	 *    BROKEN outer add-chain (`insideBroken`) collapses to its `flat`
	 *    (NoWrap-glued-separators) branch; the outermost broken add-chain
	 *    keeps its IfBreak but marks its broken branch `insideBroken` so
	 *    nested add-chains collapse. See `rewriteTaggedAddChain`.
	 *  - FORWARD: an enclosing op-chain whose `flat` (NoWrap/glued) branch
	 *    contains a candidate paren that opens → commit chain to glued +
	 *    commit the inner paren.
	 *  - A standalone candidate paren that opens → commit it to its open
	 *    branch (no chain wrapper to glue).
	 *  - Everything else → rebuild structurally, recursing into children
	 *    (threading `insideBroken`).
	 */
	private static function rewrite(d:Doc, decisions:Array<{node:Doc, crosses:Bool}>, insideBroken:Bool):Doc {
		// FORWARD direction takes precedence: when the chain's flat (glued)
		// branch contains a candidate paren that WOULD open, commit the chain
		// to its glued shape (fork `collapseChainBreaksAfter`) via
		// `commitOpens`. This runs BEFORE the inverse add-probe intercept
		// because a tagged opAddSub chain (`CollapseAddProbe` on its brk) can
		// ALSO be a forward-glue candidate (the `expression_paren_wrapping`
		// anchor: `(paren) / 2 - …`). `chainGluedIfOpens` reads only the flat
		// branch, so the `CollapseAddProbe` on the discarded brk is moot here —
		// taking the inverse intercept first would re-`WrapBoundary` the chain
		// with the original brk and double-indent the opened paren.
		final glued:Null<Doc> = chainGluedIfOpens(d, decisions);
		if (glued != null) return WrapBoundary(commitOpens(glued, decisions));

		// INVERSE direction (ω-unwrap-add-ops): a tagged opAddSub chain that is
		// NOT a forward-glue candidate. Its helper decides collapse-vs-keep from
		// `insideBroken` + the chain's break decision and recurses through
		// `rewrite` so the forward paren-collapse still applies to inner parens.
		final tagged:Null<{marker:Doc, brk:Doc, flat:Doc}> = taggedAddChain(d);
		if (tagged != null) return rewriteTaggedAddChain(tagged, decisions, insideBroken);

		// Standalone candidate paren that opens (no enclosing chain
		// committed it): commit to the open branch directly.
		switch d {
			case IfFullLineExceeds(_, open, _) if (isCandidate(d) && opens(d, decisions)):
				return rewrite(open, decisions, insideBroken);
			case _:
		}

		return mapChildren(d, child -> rewrite(child, decisions, insideBroken));
	}

	/**
	 * Inverse-direction handler (ω-unwrap-add-ops): collapse an INNER
	 * opAddSub chain's `+`/`-` breaks when it sits inside an OUTER opAddSub
	 * chain that committed to its broken form. The anyparse analogue of fork
	 * `unwrapAddOps` (strip `+`/`-` line-ends inside a wrapped region).
	 *
	 * `tagged` is a destructured tagged chain
	 * `WrapBoundary(Group(IfBreak(CollapseAddProbe(brk), flat)))`. The chain
	 * BROKE iff the measure render reached its `CollapseAddProbe` in break
	 * mode (`opensAdd`). `insideBroken` = "an ancestor add-chain broke and
	 * owns this subtree":
	 *
	 *  - `insideBroken` → COLLAPSE: discard the broken branch, keep the
	 *    `flat` (NoWrap-glued-separators) branch. Each operand keeps its OWN
	 *    wrapping (a ternary / call operand still breaks via its own Group) —
	 *    exactly fork's `unwrapAddOps`, which glues `+`/`-` without touching
	 *    inner constructs. Recurse `flat` (back through `rewrite`) with
	 *    `insideBroken` still true (fork strips nested add-ops recursively).
	 *  - NOT `insideBroken` → an OUTER (outermost so far) add-chain: strip the
	 *    now-consumed marker but keep the IfBreak (the chain decides
	 *    break/flat itself at render). Recurse the broken branch with
	 *    `insideBroken = broke` so nested add-chains collapse only when THIS
	 *    chain actually broke; recurse `flat` with `insideBroken = false`.
	 *    Byte-inert when the chain did not break (marker stripped, structure
	 *    unchanged — and an un-stripped marker would render transparently
	 *    anyway).
	 *
	 * Only opAddSub chains are tagged (`BinaryChainEmit` gates on
	 * `isAddSubOps`). An enclosing opBool chain — which fork's `unwrapAddOps`
	 * does NOT trigger from (it strips ONLY `+`/`-`) — is NOT tagged, so its
	 * inner add-chains stay untouched (byte-inert). This is why
	 * `opbool_reeval_strips_opadd_breaks` (an opBool-outer re-measure case
	 * that would over-collapse to an overflowing single line) is NOT flipped.
	 */
	private static function rewriteTaggedAddChain(
		tagged:{marker:Doc, brk:Doc, flat:Doc},
		decisions:Array<{node:Doc, crosses:Bool}>, insideBroken:Bool
	):Doc {
		if (insideBroken)
			return WrapBoundary(rewrite(tagged.flat, decisions, true));
		final broke:Bool = opens(tagged.marker, decisions);
		return WrapBoundary(Group(IfBreak(
			rewrite(tagged.brk, decisions, broke),
			rewrite(tagged.flat, decisions, false)
		)));
	}

	/**
	 * If `d` is a tagged opAddSub chain
	 * `WrapBoundary(Group(IfBreak(CollapseAddProbe(brk), flat)))`, return the
	 * marker node (for the measure-decision lookup), the marked broken shape,
	 * and the sibling flat shape. Otherwise null.
	 */
	private static function taggedAddChain(d:Doc):Null<{marker:Doc, brk:Doc, flat:Doc}> {
		return switch d {
			case WrapBoundary(Group(IfBreak(marker, flat))):
				switch marker {
					case CollapseAddProbe(brk): {marker: marker, brk: brk, flat: flat};
					case _: null;
				}
			case _: null;
		};
	}

	/** True iff `d`'s subtree contains any `CollapseAddProbe` marker. */
	private static function hasAddCandidate(d:Doc):Bool {
		var found:Bool = false;
		walk(d, node -> {
			if (!found) switch node {
				case CollapseAddProbe(_): found = true;
				case _:
			}
		});
		return found;
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

	/**
	 * True iff the measure pass recorded `crosses == true` for node `d`.
	 * Used for BOTH the forward `IfFullLineExceeds` paren-open decision and
	 * the inverse `CollapseAddProbe` chain-broke decision — the lookup is the
	 * same node-identity match for either marker kind.
	 */
	private static function opens(d:Doc, decisions:Array<{node:Doc, crosses:Bool}>):Bool {
		// Node identity match — enum `==` is reference equality on JS, so this
		// finds the decision recorded for this exact node.
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
						| HardFlatten(inner) | CollapseProbe(inner) | CollapseAddProbe(inner)
						| ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfBreak(brk, fl) | IfWidthExceeds(_, brk, fl)
						| IfFirstLineExceeds(_, brk, fl) | IfLineExceeds(_, brk, fl)
						| IfFullLineExceeds(_, brk, fl) | IfNaturalFirstLineExceeds(_, brk, fl)
						| IfNaturalFirstLineFitsOpenDelim(_, brk, fl)
						| IfArrowContinuationFits(_, _, _, brk, fl):
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
			case CollapseAddProbe(inner): CollapseAddProbe(f(inner));
			case ConditionalMarkerZero(inner): ConditionalMarkerZero(f(inner));
			case ConditionalMarkerDecrease(inner): ConditionalMarkerDecrease(f(inner));
			case Concat(items): Concat([for (it in items) f(it)]);
			case IfBreak(brk, fl): IfBreak(f(brk), f(fl));
			case IfWidthExceeds(n, brk, fl): IfWidthExceeds(n, f(brk), f(fl));
			case IfFirstLineExceeds(n, brk, fl): IfFirstLineExceeds(n, f(brk), f(fl));
			case IfLineExceeds(n, brk, fl): IfLineExceeds(n, f(brk), f(fl));
			case IfFullLineExceeds(n, brk, fl): IfFullLineExceeds(n, f(brk), f(fl));
			case IfNaturalFirstLineExceeds(n, brk, fl): IfNaturalFirstLineExceeds(n, f(brk), f(fl));
			case IfNaturalFirstLineFitsOpenDelim(n, brk, fl): IfNaturalFirstLineFitsOpenDelim(n, f(brk), f(fl));
			case IfArrowContinuationFits(ei, fw, n, brk, fl): IfArrowContinuationFits(ei, fw, n, f(brk), f(fl));
			case Fill(items, sep, tr): Fill([for (it in items) f(it)], f(sep), tr);
			case FillWithRestProbe(items, sep, tr): FillWithRestProbe([for (it in items) f(it)], f(sep), tr);
		};
	}
}
