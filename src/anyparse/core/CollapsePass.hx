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
	public static function run(doc: Doc, width: Int, indentChar: IndentChar, tabWidth: Int, indentSize: Int = 1): Doc {
		// Fast path: skip the measure render entirely when the Doc carries
		// NONE of a forward collapse-candidate paren (`CollapseProbe`), an
		// inverse inner-add-chain marker (`CollapseAddProbe`), an opBool
		// re-eval direction marker (`CollapseBoolProbe`), or a method-chain
		// dot-break re-eval marker (`CollapseChainProbe`) — the overwhelming
		// common case. Keeps the pass cost ~one structural walk for non-collapse
		// outputs.
		final hasParenProbe: Bool = hasCandidate(doc);
		final hasAddProbe: Bool = hasAddCandidate(doc);
		final hasBoolProbe: Bool = hasBoolCandidate(doc);
		final hasChainProbe: Bool = hasChainCandidate(doc);
		if (!hasParenProbe && !hasAddProbe && !hasBoolProbe && !hasChainProbe) return doc;

		final decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }> = [];
		// Measure-only render: populates `decisions` at every
		// `IfFullLineExceeds` (forward) AND every reached `CollapseAddProbe`
		// (inverse — recorded `crosses = reached-in-break-mode`, plus `indent`
		// = the add-tail's continuation column for the head-break re-measure).
		// The returned string is discarded.
		Renderer.render(doc, width, indentChar, tabWidth, indentSize, '\n', false, false, -1, decisions);

		// ONE top-down rewrite over the ORIGINAL `doc` (so every decision —
		// `IfFullLineExceeds` forward, `CollapseAddProbe` inverse — is keyed by
		// the node identity the measure render saw). The walk threads
		// `insideBroken` for the inverse direction (outer-add-chain-broke ⇒
		// inner-add-chain-collapse) and `width` for the head-break re-measure
		// (does the glued-flat add-tail fit at its captured continuation
		// indent). A separate second pass would rebuild the tree and lose the
		// other direction's node identities, so both are resolved in this
		// single pass.
		return rewrite(doc, decisions, false, width);
	}

	/**
	 * Structural top-down rewrite. Behaviours:
	 *  - INVERSE (ω-unwrap-add-ops): a tagged opAddSub chain
	 *    `WrapBoundary(Group(IfBreak(CollapseAddProbe(brk), flat)))` inside a
	 *    BROKEN outer add-chain (`insideBroken`) collapses to its `flat`
	 *    (NoWrap-glued-separators) branch; the outermost broken add-chain
	 *    keeps its IfBreak but marks its broken branch `insideBroken` so
	 *    nested add-chains collapse. See `rewriteTaggedAddChain`.
	 *  - HEAD-BREAK (ω-opadd-head-break-remeasure): a tagged opAddSub chain
	 *    NOT inside a broken outer add-chain (its enclosing context is an
	 *    opBool / compare op, e.g. `… && <head> + a + b > …`) whose FillLine
	 *    `brk` over-packs operand 2 onto the head line. When the chain broke
	 *    and the glued-flat tail (`+ a + b`) fits at its captured continuation
	 *    indent, commit to a break-AFTER-HEAD shape (head on its own line, the
	 *    rest of the chain glued flat on the continuation). See
	 *    `rewriteTaggedAddChain`.
	 *  - COMPARE-OP-GLUE (ω-opadd-head-break-remeasure leg 2): a never-wrap-
	 *    marked compare/multiplicative operator Group whose LEFT operand is a
	 *    head-break-committing add-chain keeps the operator glued to the now-
	 *    flat add-tail (`… + a + b > limit`) instead of breaking onto its own
	 *    line. See `compareOpGluedToHeadBreak`.
	 *  - FORWARD: an enclosing op-chain whose `flat` (NoWrap/glued) branch
	 *    contains a candidate paren that opens → commit chain to glued +
	 *    commit the inner paren.
	 *  - A standalone candidate paren that opens → commit it to its open
	 *    branch (no chain wrapper to glue).
	 *  - Everything else → rebuild structurally, recursing into children
	 *    (threading `insideBroken`).
	 */
	private static function rewrite(
		d: Doc, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>, insideBroken: Bool, width: Int
	): Doc {
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
		final glued: Null<Doc> = chainGluedIfOpens(d, decisions);
		if (glued != null) return WrapBoundary(commitOpens(glued, decisions));

		// COMPARE-OP-GLUE (leg 2): a never-wrap-marked binary operator Group
		// `Group(Concat([<head-break add-chain>, Nest(cols, [Line, op, right])]))`
		// whose left operand commits to the head-break shape — keep the
		// operator glued to the flat add-tail. Detected at the PARENT (the
		// add-chain itself is descended via `commitHeadBreak` inside the
		// helper). Returns null when the shape / commit does not apply, so the
		// common path stays byte-inert.
		final compareGlued: Null<Doc> = compareOpGluedToHeadBreak(d, decisions, width);
		if (compareGlued != null) return compareGlued;

		// INVERSE / HEAD-BREAK direction: a tagged opAddSub chain that is NOT a
		// forward-glue candidate and not the left operand of a compare-op glue
		// (handled above). Its helper decides collapse / head-break / keep from
		// `insideBroken` + the chain's break decision + the captured continuation
		// indent, and recurses through `rewrite` so the forward paren-collapse
		// still applies to inner parens.
		final tagged: Null<{ marker: Doc, brk: Doc, flat: Doc }> = taggedAddChain(d);
		if (tagged != null) return rewriteTaggedAddChain(tagged, decisions, insideBroken, width);

		// OPBOOL-REEVAL direction (ω-opbool-reeval-after-callparam): a tagged
		// opBool chain `CollapseBoolProbe(<trailing FillLine shape>)`. When the
		// chain wrapped (marker crossed) AND a contained call operand overflows
		// at its flat position (the fork's `reEvaluateOpBoolAfterCallParam`
		// gate), flip the chain to operator-LEADING; otherwise unwrap to the
		// bare trailing shape (byte-inert). Returns null when `d` is not the
		// marker — falls through to the rest of the rewrite.
		final boolFlip: Null<Doc> = rewriteBoolProbe(d, decisions, insideBroken, width);
		if (boolFlip != null) return boolFlip;

		// METHODCHAIN-REEVAL re-glue (ω-methodchain-reeval-after-callparam,
		// subroot-E): a tagged method-chain
		// `CollapseChainProbe(IfFullLineExceeds(w, dotBreak, glued))`. When the
		// chain dot-broke ONLY because a segment's call args wrapped — i.e. the
		// glued FIRST line (with those args broken) still fits at the captured
		// column — STRIP the chain break (re-glue), mirroring fork
		// `reEvaluateMethodChainAfterCallParam`. Otherwise keep the width-driven
		// `IfFullLineExceeds`. Returns null when `d` is not the marker (the
		// common path stays byte-inert).
		final chainFlip: Null<Doc> = rewriteChainProbe(d, decisions, insideBroken, width);
		if (chainFlip != null) return chainFlip;

		// Standalone candidate paren that opens (no enclosing chain
		// committed it): commit to the open branch directly.
		switch d {
			case IfFullLineExceeds(_, open, _) if (isCandidate(d) && opens(d, decisions)):
				return rewrite(open, decisions, insideBroken, width);
			case _:
		}

		return mapChildren(d, child -> rewrite(child, decisions, insideBroken, width));
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
	 *  - NOT `insideBroken` → an OUTER (outermost so far) add-chain. Two
	 *    sub-cases:
	 *     * HEAD-BREAK (ω-opadd-head-break-remeasure): the chain BROKE and its
	 *       FillLine `brk` over-packs operand 2 onto the head line, but the
	 *       glued-flat tail (`+ a + b`) fits at the captured continuation
	 *       indent. The order-dependent re-measure: fork's opAdd first-line
	 *       budget includes the unbroken `&&` / `if (` prefix (tighter), so the
	 *       chain breaks after the FIRST operand (the call) and the rest rides
	 *       the continuation FLAT. anyparse's bottom-up Fill over-packs because
	 *       it measures after `&&` broke (looser budget). Commit to the
	 *       break-after-head shape (`commitHeadBreak`) — head on its own line,
	 *       tail glued flat at `indent`. The full-`flat` collapse is WRONG here
	 *       (NoWrap `<call> + a + b` overflows); head-break keeps only the head
	 *       on its line.
	 *     * KEEP: not a head-break candidate — strip the now-consumed marker but
	 *       keep the IfBreak (the chain decides break/flat itself at render).
	 *       Recurse the broken branch with `insideBroken = broke` so nested
	 *       add-chains collapse only when THIS chain actually broke; recurse
	 *       `flat` with `insideBroken = false`. Byte-inert when the chain did
	 *       not break (marker stripped, structure unchanged — and an un-stripped
	 *       marker would render transparently anyway).
	 *
	 * Only opAddSub chains are tagged (`BinaryChainEmit` gates on
	 * `isAddSubOps`). An enclosing opBool chain — which fork's `unwrapAddOps`
	 * does NOT trigger from (it strips ONLY `+`/`-`) — is NOT tagged, so its
	 * inner add-chains stay untouched for the COLLAPSE direction. The HEAD-BREAK
	 * direction, however, fires for an add-chain that itself broke regardless of
	 * the enclosing class — exactly the opBool-outer re-measure case
	 * `opbool_reeval_strips_opadd_breaks`.
	 */
	private static function rewriteTaggedAddChain(
		tagged: { marker: Doc, brk: Doc, flat: Doc }, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>, insideBroken: Bool,
		width: Int
	): Doc {
		if (insideBroken) return WrapBoundary(rewrite(tagged.flat, decisions, true, width));
		final broke: Bool = opens(tagged.marker, decisions);
		// HEAD-BREAK re-measure: when the chain broke and the glued-flat tail
		// fits at its captured continuation indent, commit to break-after-head.
		final headBreak: Null<Doc> = broke ? commitHeadBreak(tagged, decisions, width) : null;
		if (headBreak != null) return WrapBoundary(headBreak);
		return WrapBoundary(Group(IfBreak(rewrite(tagged.brk, decisions, broke, width), rewrite(tagged.flat, decisions, false, width))));
	}

	/**
	 * ω-opadd-head-break-remeasure. If the tagged add-chain's broken `brk`
	 * shape is the FillLine layout `Group(Nest(cols, Fill([head, tail…],
	 * Line(' '))))` produced by `BinaryChainEmit.shapeFillLine` (BeforeLast)
	 * AND the captured continuation indent + the glued-flat tail width fits in
	 * `width`, return the break-after-head shape:
	 *
	 *   Concat([ head, Nest(cols, Concat([Line('\n'), gluedFlatTail])) ])
	 *
	 * where `head` is Fill item 0 (rewritten through `rewrite` so its own inner
	 * parens / sub-chains still resolve) and `gluedFlatTail` is the remaining
	 * Fill items joined by single spaces (each item already carries its leading
	 * `op ` from `shapeFillLine`, so the join is a plain ` ` — `+ a` ` ` `+ b`
	 * → `+ a + b`).
	 *
	 * Returns null when the brk is not the recognised FillLine shape, the chain
	 * has < 2 tail operands, the continuation indent was not captured, or the
	 * flat tail does not fit — every non-matching case falls through to the
	 * legacy `Group(IfBreak)` (byte-inert).
	 *
	 * O(1) re-measure: `indent + DocMeasure.flatTokenWidth(gluedFlatTail)` —
	 * column-independent flat width + the captured continuation column. No
	 * recursive natural-first-line probe across the binary spine (mirror the
	 * forward `collapseParenCommitsOpen` fit gate).
	 */
	private static function commitHeadBreak(
		tagged: { marker: Doc, brk: Doc, flat: Doc }, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>, width: Int
	): Null<Doc> {
		final fill: Null<{ cols: Int, items: Array<Doc> }> = fillLineParts(tagged.brk);
		if (fill == null || fill.items.length < 2) return null;
		// ω-opadd-afterlast-cont-indent: the head-break re-measure GLUES the tail
		// operands assuming each carries a LEADING `op ` (the BeforeLast
		// enrichment). An AfterLast FillLine encodes the operator as a TRAILING
		// `Text(' op')` on each non-last item, so the same gluing would emit the
		// operators in the wrong slot. AfterLast also keeps its natural fillLine
		// packing (fork `wrapFillLine2AfterLast` breaks before the overflowing
		// item at `indent + 1`, never collapsing to a head-break). Skip the
		// re-measure for AfterLast so the underlying Fill renders verbatim — its
		// `Nest(indentUnit)` already lands continuation operands one level past
		// the chain base (the trailing operator leaves no leading marker, so the
		// +1 indent disambiguates the wrapped operand).
		if (fillItemsAreAfterLast(fill.items)) return null;
		// ω-methodchain-reeval-after-callparam (axis 2): a `cols == 0` FillLine brk
		// is a nest-suppressed add-chain — set when the chain is a CALL ARGUMENT
		// (`_callArgChainNest`, leading-break call args). In that context fork
		// keeps the natural fillLine-`beforeLast` packing (pack operands until the
		// next overflows, break before it) rather than the head-break shape (head
		// alone on line 1, whole tail glued on the continuation). Suppress the
		// head-break re-measure here so the underlying Fill renders beforeLast.
		// Non-call-arg add-chains (`cols != 0`, e.g. an `if (… && <opAdd> > …)`
		// compare operand handled by leg 2) keep the head-break.
		if (fill.cols == 0) return null;
		final indent: Null<Int> = capturedIndent(tagged.marker, decisions);
		if (indent == null) return null;
		final head: Doc = fill.items[0];
		// Glue the tail operands (each already prefixed with `op `) by single
		// spaces — the NoWrap continuation `+ a + b`.
		final tailParts: Array<Doc> = [];
		for (i in 1...fill.items.length) {
			if (i > 1) tailParts.push(Text(' '));
			tailParts.push(fill.items[i]);
		}
		final gluedTail: Doc = Concat(tailParts);
		if (indent + DocMeasure.flatTokenWidth(gluedTail) > width) return null;
		// Head keeps its own inner wrapping (the call may still break its args);
		// the tail rides one continuation line at the chain's one-tab indent.
		return Concat([
			rewrite(head, decisions, false, width),
			Nest(fill.cols, Concat([Line('\n'), gluedTail])),
		]);
	}

	/**
	 * Destructure the FillLine brk shape
	 * `Group(Nest(cols, Fill(items, Line(' '), _)))` (BeforeLast) into its
	 * Nest indent and the Fill operand array. Null when `d` is not that exact
	 * shape — so a non-FillLine `brk` (OnePerLine / OnePerLineAfterFirst) is
	 * not head-broken (those modes are not the over-pack case this targets).
	 */
	private static function fillLineParts(d: Doc): Null<{ cols: Int, items: Array<Doc> }> {
		return switch d {
			case Group(Nest(cols, Fill(items, _, _))): { cols: cols, items: items };
			case _: null;
		};
	}

	/**
	 * True iff the FillLine `items` carry the AfterLast enrichment from
	 * `BinaryChainEmit.shapeFillLine` — each non-last item is
	 * `Concat([operand, Text(' op')])` (the operator TRAILS the operand). The
	 * BeforeLast enrichment instead prefixes each continuation operand with a
	 * leading `Text('op ')`, so its first item is the bare head and continuation
	 * items START (not end) with a `Text`. Decisive signal: AfterLast's first
	 * item is a `Concat` whose LAST child is `Text(t)` with `t` beginning with a
	 * space (the ` op` suffix). A BeforeLast head operand — string literal,
	 * identifier, call (`…)`), nested sub-chain — never ends in a
	 * space-prefixed `Text`, so this stays specific to AfterLast.
	 */
	private static function fillItemsAreAfterLast(items: Array<Doc>): Bool {
		return switch items[0] {
			case Concat(parts) if (parts.length >= 2):
				switch parts[parts.length - 1] {
					case Text(t):
						t.length >= 2 && StringTools.fastCodeAt(t, 0) == ' '.code;
					case _: false;
				}
			case _: false;
		};
	}

	/**
	 * The captured continuation indent (column) for the add-chain marker, or
	 * null when the measure pass did not record one (the marker was not reached
	 * in break mode, or the decision predates the indent capture).
	 */
	private static function capturedIndent(marker: Doc, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>): Null<Int> {
		final entry: Null<{ node: Doc, crosses: Bool, ?indent: Int }> = decisions.find(e -> e.node == marker && e.crosses);
		return entry == null ? null : entry.indent;
	}

	/**
	 * ω-opadd-head-break-remeasure leg 2 — compare-op glue. The generic
	 * non-chain infix emit lays a never-wrap-marked operator (`>` / `<` / `*`
	 * / `/` / compare / shift / bitwise / `is` / `??`) as
	 *
	 *   Group(Concat([ <left>, Nest(cols, Concat([Line(' '), Text('op '), <right>])) ]))
	 *
	 * — the soft `Line(' ')` breaks whenever `<left>` carries a committed
	 * hardline. When `<left>` is an add-chain that commits to the head-break
	 * shape (head on one line, `+ a + b` flat on the continuation), the fork
	 * keeps the never-wrap-marked operator GLUED to the flat add-tail
	 * (`+ a + b > limit`) — the operator is never a wrap-point. Rewrite the
	 * Group to glue: commit the left to head-break, FLATTEN the operator
	 * continuation (its soft `Line(' )` → a single space), so `op right` rides
	 * the add-tail line.
	 *
	 * Returns null unless `d` is exactly that Group-of-two shape whose left
	 * operand commits head-break — every other Group / operator falls through
	 * to the normal rewrite (byte-inert). The right-hand `Nest` keeps its
	 * structure under the `Flatten` so a multi-line RIGHT operand still wraps
	 * inside its own brackets; only the leading operator `Line` is collapsed.
	 */
	private static function compareOpGluedToHeadBreak(
		d: Doc, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>, width: Int
	): Null<Doc> {
		final parts: Null<{ group: Doc, left: Doc, cont: Doc }> = switch d {
			case Group(Concat([left, cont])) | GroupWithRestProbe(Concat([left, cont])):
				{ group: d, left: left, cont: cont };
			case _: null;
		};
		if (parts == null) return null;
		// The continuation must be the never-wrap-marked operator layout
		// `Nest(cols, Concat([Line(' '), Text('op '), right]))` — a SOFT space
		// Line (not a hardline) leads it. A chain / call continuation has a
		// different shape and is left untouched.
		final isOpCont: Bool = switch parts.cont {
			case Nest(_, Concat(citems)) if (citems.length >= 1):
				switch citems[0] {
					case Line(s): s == ' ';
					case _: false;
				}
			case _: false;
		};
		if (!isOpCont) return null;
		final tagged: Null<{ marker: Doc, brk: Doc, flat: Doc }> = taggedAddChain(parts.left);
		if (tagged == null) return null;
		if (!opens(tagged.marker, decisions)) return null;
		final headBreak: Null<Doc> = commitHeadBreak(tagged, decisions, width);
		if (headBreak == null) return null;
		// Glue: left commits head-break (WrapBoundary preserved to match the
		// add-chain's own boundary scoping); the operator continuation is
		// flattened so its leading space-`Line` stays a space.
		return Group(Concat([
			WrapBoundary(headBreak),
			Flatten(rewrite(parts.cont, decisions, false, width)),
		]));
	}

	/**
	 * If `d` is a tagged opAddSub chain
	 * `WrapBoundary(Group(IfBreak(CollapseAddProbe(brk), flat)))`, return the
	 * marker node (for the measure-decision lookup), the marked broken shape,
	 * and the sibling flat shape. Otherwise null.
	 */
	private static function taggedAddChain(d: Doc): Null<{ marker: Doc, brk: Doc, flat: Doc }> {
		return switch d {
			case WrapBoundary(Group(IfBreak(marker, flat))):
				switch marker {
					case CollapseAddProbe(brk): { marker: marker, brk: brk, flat: flat };
					case _: null;
				}
			case _: null;
		};
	}

	/**
	 * ω-opbool-reeval-after-callparam (CollapsePass increment 2). When `d` is a
	 * `CollapseBoolProbe(trailingShape)` marker reached in the measure pass (the
	 * chain laid operator-TRAILING) AND a contained call operand overflows at
	 * its flat column, flip the chain to operator-LEADING (fork
	 * `reEvaluateOpBoolAfterCallParam` — strip the call breaks, re-apply opBool
	 * with `useTrailing: false`). Otherwise unwrap to the bare trailing shape
	 * (byte-inert). Returns null when `d` is not the marker.
	 *
	 * The `trailingShape` is the FillLine `AfterLast` layout
	 * `Group(Nest(cols, Fill(items, Line(' '))))` whose Fill items are operand
	 * Docs each suffixed by `Text(' op')` (last item bare). The flip rebuilds
	 * the same FillLine with `BeforeLast` enrichment (each continuation item
	 * prefixed by `Text('op ')`). The call-overflow test reuses the captured
	 * visual start column and `DocMeasure.flatTokenWidth` (O(1) per operand, no
	 * recursive natural-first-line probe).
	 */
	private static function rewriteBoolProbe(
		d: Doc, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>, insideBroken: Bool, width: Int
	): Null<Doc> {
		final inner: Null<Doc> = switch d {
			case CollapseBoolProbe(i): i;
			case _: null;
		};
		if (inner == null) return null;
		// Reaching the marker in the measure pass = the chain laid trailing.
		// Absent a recorded decision the marker was never measured (e.g. the
		// natural-first-line-fits-open-delim branch unwrapped flat) — keep the
		// trailing shape unchanged (recursed so nested operand parens resolve).
		final col: Null<Int> = capturedIndent(d, decisions);
		if (col == null) return rewrite(inner, decisions, insideBroken, width);
		final parts: Null<{ cols: Int, items: Array<Doc>, sep: Doc }> = afterLastFillParts(inner);
		if (parts == null) return rewrite(inner, decisions, insideBroken, width);
		// Recover the bare operands + their operators from the AfterLast-enriched
		// Fill items (item i<last = Concat([operand_i, Text(' op')]); last =
		// operand_last). Null when any item is not the expected shape.
		final chain: Null<{ operands: Array<Doc>, ops: Array<String> }> = splitAfterLastItems(parts.items);
		if (chain == null) return rewrite(inner, decisions, insideBroken, width);
		if (!callOperandOverflows(chain.operands, chain.ops, col, width)) return rewrite(inner, decisions, insideBroken, width);
		// Flip: rebuild the FillLine with BeforeLast enrichment (op leads each
		// continuation operand) — the fork `useTrailing: false` leading layout.
		// A call operand that fits flat at its continuation column is FORCE-FLAT
		// (fork `restoreInnerCallParamsAfterOpBoolWrap` keeps the call flat unless
		// `indent + callWidth > maxLen`), so the leading `&& call` rides one line
		// even though the `&& ` prefix pushes the visual line a few cols past the
		// width — matching the fork output. `col` (the chain's first-operand
		// column) is a conservative upper bound on the continuation indent for
		// `if (`/`while (`/`for (` conditions (prefix width >= one indent level),
		// so `col + callWidth <= width` implies the call fits at the continuation
		// — flatten only then; otherwise leave the call's own wrapping intact.
		// Each operand is recursed through `rewrite` first (so a nested paren /
		// add-chain operand still resolves its own collapse), then a fitting call
		// operand is force-flat.
		final beforeItems: Array<Doc> = [
			flattenIfFittingCall(rewrite(chain.operands[0], decisions, insideBroken, width), col, width),
		];
		for (i in 0...chain.ops.length) beforeItems.push(Concat([
			Text(chain.ops[i] + ' '),
			flattenIfFittingCall(rewrite(chain.operands[i + 1], decisions, insideBroken, width), col, width)
		]));
		return Group(Nest(parts.cols, Fill(beforeItems, parts.sep)));
	}

	/**
	 * ω-methodchain-reeval-after-callparam (CollapsePass increment 3, subroot-E).
	 * `d` is a `CollapseChainProbe(IfFullLineExceeds(w, breakShape, glueShape))`
	 * marker emitted by `MethodChainEmit.emit` for a chain whose width-driven
	 * BREAK shape is a dot-break and whose glued (`NoWrap`) shape's last segment
	 * is a breakable call. The marker carries the captured chain-receiver column
	 * (`decisions[*].indent`).
	 *
	 * Fork analogue: `MarkWrapping.reEvaluateMethodChainAfterCallParam` STRIPS
	 * method-chain breaks (re-glues the chain) when a contained callParameter
	 * actually wrapped — the chain dot-broke only because the segment's call
	 * args broke, not because the glued chain head itself overflowed. anyparse's
	 * `IfFullLineExceeds` probe sees the FULL glued flat width (including the
	 * call's now-breakable args) and over-eagerly dot-breaks. This re-measure
	 * fixes that:
	 *  - if the FULL glued flat fits at `col` → the renderer already picks the
	 *    glued branch; no flip needed (recurse `inner`, byte-inert).
	 *  - if the FULL glued flat OVERFLOWS but the glued FIRST LINE — receiver +
	 *    every segment with the last segment's call args broken (the line ends
	 *    at that call's open delim) — FITS at `col`, the overflow is absorbed by
	 *    the breakable call: STRIP the chain break (return the recursed
	 *    `glueShape`, whose call args wrap inside the glued chain).
	 *  - otherwise the chain genuinely needs the dot-break → keep `inner`.
	 *
	 * O(1) re-measure: `col + flatTokenWidth(prefix)` over the flat chain
	 * segments + the last call's prefix-to-open-delim — a flat token-width sum,
	 * NO recursive natural-FL probe across a spine (PERF TRAP). Returns null
	 * when `d` is not the marker.
	 */
	private static function rewriteChainProbe(
		d: Doc, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>, insideBroken: Bool, width: Int
	): Null<Doc> {
		final inner: Null<Doc> = switch d {
			case CollapseChainProbe(i): i;
			case _: null;
		};
		if (inner == null) return null;
		final col: Null<Int> = capturedIndent(d, decisions);
		// No recorded column → marker never measured (e.g. a flat-mode parent
		// short-circuited) → keep the glued/IfFLE shape unchanged.
		if (col == null) return rewrite(inner, decisions, insideBroken, width);
		final glueShape: Null<Doc> = switch inner {
			case IfFullLineExceeds(_, _, glue): glue;
			case _: null;
		};
		if (glueShape == null) return rewrite(inner, decisions, insideBroken, width);
		// The chain only needs re-glue if its full glued flat would overflow
		// (otherwise the IfFullLineExceeds already picks glued — no flip).
		if (col + DocMeasure.flatTokenWidth(glueShape) <= width) return rewrite(inner, decisions, insideBroken, width);
		// The glued first line ends at the last segment's call open delim (its
		// args break onto their own lines). It fits iff `col + prefix <= width`.
		final prefix: Null<Int> = gluedFirstLineWidth(glueShape);
		if (prefix == null || col + prefix > width) return rewrite(inner, decisions, insideBroken, width);
		// Re-glue: the call args wrap inside the glued chain (fork strips the
		// chain break, keeps the callParameter break). Recurse so inner parens /
		// sub-chains still resolve.
		return rewrite(glueShape, decisions, insideBroken, width);
	}

	/**
	 * ω-methodchain-reeval-after-callparam — the rendered width of the glued
	 * chain's FIRST line when the last segment's call args break. `glue` is the
	 * NoWrap `Concat([receiver, seg0, …, segN])`; the first line is every part
	 * flat EXCEPT the last segment, which contributes only its prefix up to (and
	 * including) the first open delimiter (`(`/`[`/`{`) — the point the call
	 * args break after. Null when `glue` is not the expected Concat shape or the
	 * last segment has no open delim (not a breakable call).
	 */
	private static function gluedFirstLineWidth(glue: Doc): Null<Int> {
		final parts: Null<Array<Doc>> = switch glue {
			case Concat(items) if (items.length >= 2): items;
			case _: null;
		};
		if (parts == null) return null;
		final last: Doc = parts[parts.length - 1];
		final lastPrefix: Null<Int> = flatPrefixToOpenDelim(last);
		if (lastPrefix == null) return null;
		var total: Int = lastPrefix;
		for (i in 0...parts.length - 1) total += DocMeasure.flatTokenWidth(parts[i]);
		return total;
	}

	/**
	 * The flat-text width of `seg` up to and including its first open delimiter
	 * (`(`/`[`/`{`). Null when the segment has no open delim. Used to size the
	 * `.field(` prefix of a chain's last call segment — the part that stays on
	 * the glued first line when the call's args break.
	 */
	private static function flatPrefixToOpenDelim(seg: Doc): Null<Int> {
		final flat: String = DocMeasure.flatText(seg);
		for (i in 0...flat.length) {
			final c: Int = StringTools.fastCodeAt(flat, i);
			if (c == '('.code || c == '['.code || c == '{'.code) return i + 1;
		}
		return null;
	}

	/**
	 * Destructure the trailing FillLine `Group(Nest(cols, Fill(items, sep, _)))`
	 * shape (the `CollapseBoolProbe` payload) into its Nest indent, Fill items,
	 * and separator. Null when `d` is not that exact shape.
	 */
	private static function afterLastFillParts(d: Doc): Null<{ cols: Int, items: Array<Doc>, sep: Doc }> {
		return switch d {
			case Group(Nest(cols, Fill(items, sep, _))): { cols: cols, items: items, sep: sep };
			case _: null;
		};
	}

	/**
	 * Recover the bare operand Docs and operator strings from an AfterLast-
	 * enriched Fill item array. Item `i` (i < last) is
	 * `Concat([operand_i, Text(' op')])`; the last item is `operand_last`. The
	 * trailing `Text(' op')` carries a leading space then the operator. Returns
	 * null when any non-last item is not that 2-element Concat shape (so a
	 * structurally-unexpected payload falls back to the trailing shape).
	 */
	private static function splitAfterLastItems(items: Array<Doc>): Null<{ operands: Array<Doc>, ops: Array<String> }> {
		if (items.length < 2) return null;
		final operands: Array<Doc> = [];
		final ops: Array<String> = [];
		for (i in 0...items.length) {
			if (i == items.length - 1) {
				operands.push(items[i]);
				break;
			}
			switch items[i] {
				case Concat([operand, Text(opText)]):
					operands.push(operand);
					final trimmed: String = StringTools.ltrim(opText);
					if (trimmed.length == 0) return null;
					ops.push(trimmed);
				case _:
					return null;
			}
		}
		return { operands: operands, ops: ops };
	}

	/**
	 * True iff some call operand's flat right edge overflows `width` at its flat
	 * column — the anyparse analogue of fork `hasSimpleCallParamBreaksBetween`
	 * (an inner `callParameter` that wrapped in the all-flat layout). `startCol`
	 * is the captured visual column where operand 0 begins; each subsequent
	 * operand sits at `prev + flatWidth(operand) + (' ' + op + ' ').length`.
	 * Only CALL operands count (mirror fork — a non-call overflowing operand
	 * just breaks the chain at its operators, no direction flip).
	 */
	private static function callOperandOverflows(operands: Array<Doc>, ops: Array<String>, startCol: Int, width: Int): Bool {
		var pos: Int = startCol;
		for (i in 0...operands.length) {
			final w: Int = DocMeasure.flatTokenWidth(operands[i]);
			if (DocMeasure.operandIsCall(operands[i]) && pos + w > width) return true;
			pos += w;
			if (i < ops.length) pos += ops[i].length + 2;
		}
		return false;
	}

	/**
	 * Force a call operand FLAT (`HardFlatten`, survives the operand's own
	 * `WrapBoundary`) when it fits flat at a continuation column conservatively
	 * bounded by `contColUpper` — the fork `restoreInnerCallParamsAfterOpBoolWrap`
	 * "keep the call flat unless it still overflows" decision. A non-call operand,
	 * or a call too long to fit flat, is returned unchanged (keeps its own
	 * wrapping). `HardFlatten` (not `Flatten`) because the call operand carries
	 * a `WrapBoundary` whose force-flat a plain `Flatten` would not survive.
	 */
	private static function flattenIfFittingCall(operand: Doc, contColUpper: Int, width: Int): Doc {
		if (!DocMeasure.operandIsCall(operand)) return operand;
		return contColUpper + DocMeasure.flatTokenWidth(operand) <= width ? HardFlatten(operand) : operand;
	}

	/** True iff `d`'s subtree contains any `CollapseAddProbe` marker. */
	private static function hasAddCandidate(d: Doc): Bool {
		var found: Bool = false;
		walk(
			d, node -> {
				if (!found)
					switch node {
						case CollapseAddProbe(_): found = true;
						case _:
					}
			}
		);
		return found;
	}

	/** True iff `d`'s subtree contains any `CollapseBoolProbe` marker. */
	private static function hasBoolCandidate(d: Doc): Bool {
		var found: Bool = false;
		walk(
			d, node -> {
				if (!found)
					switch node {
						case CollapseBoolProbe(_): found = true;
						case _:
					}
			}
		);
		return found;
	}

	/** True iff `d`'s subtree contains any `CollapseChainProbe` marker. */
	private static function hasChainCandidate(d: Doc): Bool {
		var found: Bool = false;
		walk(
			d, node -> {
				if (!found)
					switch node {
						case CollapseChainProbe(_): found = true;
						case _:
					}
			}
		);
		return found;
	}

	/**
	 * Commit every opening candidate paren inside `d` to its open branch,
	 * leaving non-opening parens and all other nodes rewritten normally.
	 * Used on a chain's committed-glued (`flat`) branch so the inner paren
	 * opens within the glued tail.
	 */
	private static function commitOpens(d: Doc, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>): Doc {
		switch d {
			case IfFullLineExceeds(_, open, _) if (isCandidate(d) && opens(d, decisions)):
				return commitOpens(open, decisions);
			case _:
		}
		final glued: Null<Doc> = chainGluedIfOpens(d, decisions);
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
	private static function chainGluedIfOpens(d: Doc, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>): Null<Doc> {
		final flat: Null<Doc> = switch d {
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
	private static function isCandidate(d: Doc): Bool {
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
	private static function opens(d: Doc, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>): Bool {
		// Node identity match — enum `==` is reference equality on JS, so this
		// finds the decision recorded for this exact node.
		final entry: Null<{ node: Doc, crosses: Bool, ?indent: Int }> = decisions.find(e -> e.node == d);
		return entry != null && entry.crosses;
	}

	/** True iff `d`'s subtree contains a candidate paren that opens. */
	private static function subtreeOpens(d: Doc, decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>): Bool {
		var found: Bool = false;
		walk(
			d, node -> {
				if (!found && isCandidate(node) && opens(node, decisions))
					found = true;
			}
		);
		return found;
	}

	/** True iff `d`'s subtree contains any collapse-candidate paren. */
	private static function hasCandidate(d: Doc): Bool {
		var found: Bool = false;
		walk(
			d, node -> {
				if (!found && isCandidate(node))
					found = true;
			}
		);
		return found;
	}

	/** True iff `d`'s subtree contains a `CollapseProbe` region. */
	private static function containsCollapseProbe(d: Doc): Bool {
		var found: Bool = false;
		walk(
			d, node -> {
				if (!found)
					switch node {
						case CollapseProbe(_): found = true;
						case _:
					}
			}
		);
		return found;
	}

	/**
	 * Pre-order structural walk applying `visit` to every node. Read-only;
	 * does not rebuild. Used by the candidate / open / hard-flatten probes.
	 */
	private static function walk(d: Doc, visit: Doc -> Void): Void {
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			// `stack.length > 0` guard proves non-null; Strict won't narrow
			// `Array.pop()` on the runtime invariant (lang-haxe gotcha).
			final node: Doc = (cast stack.pop(): Doc);
			visit(node);
			switch node {
				case Empty | Text(_) | Line(_) | OptSpace(_) | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline
					| OptSpaceSkipAfterHardline:
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
					inner
				) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
					inner
				) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfBreak(brk, fl) | IfWidthExceeds(_, brk, fl) | IfFirstLineExceeds(_, brk, fl) | IfLineExceeds(_, brk, fl) | IfFullLineExceeds(
					_, brk, fl
				) | IfNaturalFirstLineExceeds(_, brk, fl) | IfNaturalFirstLineFitsOpenDelim(_, brk, fl) | IfArrowContinuationFits(
					_, _, _, brk, fl
				):
					stack.push(brk);
					stack.push(fl);
				case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
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
	private static function mapChildren(d: Doc, f: Doc -> Doc): Doc {
		return switch d {
			case Empty | Text(_) | Line(_) | OptSpace(_) | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline
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
			case CollapseBoolProbe(inner): CollapseBoolProbe(f(inner));
			case CollapseChainProbe(inner): CollapseChainProbe(f(inner));
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
			case FillBreakAfterWrap(items, sep, tr): FillBreakAfterWrap([for (it in items) f(it)], f(sep), tr);
		};
	}

}
