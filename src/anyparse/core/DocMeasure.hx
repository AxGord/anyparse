package anyparse.core;

/**
 * Static `Doc` measurement utilities that don't depend on render-time
 * stack/mode state. Live in `core` so both `core.Renderer` and the
 * `format.wrap` engine can call them without crossing layering rules
 * (`format.wrap → core` is allowed; the reverse is not).
 *
 * Render-time probes that DO need stack/mode state
 * (`flatTokenWidthFirstLine`, `flatTokenWidthOfRestStack`) live in
 * `Renderer` because they're driven directly by frame iteration.
 */
final class DocMeasure {
	/**
	 * Walks a `Doc` tree and returns its visible-token width — the same
	 * width the renderer would emit in flat layout if forced hardlines
	 * didn't terminate that mode.
	 *
	 * Treats forced hardlines (`Line('\n')`, `OptHardline`,
	 * `OptHardlineSkipAtOpenDelim`) as zero width instead of aborting
	 * (which is what `Renderer.fitsFlat`'s budget walk does).
	 * `BodyGroup` content is deferred (zero width) — mirrors
	 * `Renderer.fitsFlat` Departure 2 and `MethodChainEmit.chainItemLength`.
	 *
	 * Used by:
	 *  - `Renderer`'s `IfWidthExceeds` / `IfLineExceeds` probes — answers
	 *    `col + flatTokenWidth(flatDoc) >= n`, the natural inline-width
	 *    predicate for cascade rules whose threshold is the rendered line
	 *    length.
	 *  - `WrapList.emit` and `BinaryChainEmit` — feeds clean widths into
	 *    cascade rule conditions (`LineLengthLargerThan` /
	 *    `TotalItemLengthLargerThan` / `AnyItemLengthLargerThan`) without
	 *    conflating them with the `anyHardline` break-commit signal —
	 *    derived from `flatLength(item) < 0` (unchanged) so existing call
	 *    sites and the legacy `flatLength==-1` semantic stay intact
	 *    (ω-flatlength-decouple-tokenwidth).
	 *
	 * Stack-based walk — items pushed in reverse so pop order matches
	 * left-to-right traversal.
	 */
	public static function flatTokenWidth(d:Doc):Int {
		final stack:Array<Doc> = [d];
		var total:Int = 0;
		while (stack.length > 0) {
			final node:Doc = stack.pop();
			switch (node) {
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim:
				case Text(s):
					total += s.length;
				case Line(flat):
					if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) {
						// Forced hardline contributes 0 to token width
						// (mirrors `MethodChainEmit.chainItemLength`).
					} else {
						total += flat.length;
					}
				case Nest(_, inner):
					stack.push(inner);
				case Concat(items):
					var i:Int = items.length;
					while (--i >= 0) stack.push(items[i]);
				case Group(inner):
					stack.push(inner);
				case BodyGroup(_):
					// Defer like `Renderer.fitsFlat`: BG content decides
					// its own flat/break and does not contribute to the
					// parent list's static width.
				case IfBreak(_, flatDoc):
					stack.push(flatDoc);
				case IfWidthExceeds(_, _, flatDoc):
					// Forward to flat side: token-width measurement uses
					// the flat shape, mirroring the `IfBreak` arm.
					stack.push(flatDoc);
				case IfFirstLineExceeds(_, _, flatDoc):
					// Mirror `IfWidthExceeds`: chain consumers walk the
					// flat side, ignoring the renderer-side first-line cap.
					stack.push(flatDoc);
				case IfLineExceeds(_, _, flatDoc):
					// Mirror `IfWidthExceeds`: chain consumers walk the
					// flat side; rest-of-stack lookahead is renderer-side
					// (slice ω-iflineexceeds-infra).
					stack.push(flatDoc);
				case IfFullLineExceeds(_, _, flatDoc):
					// Mirror `IfLineExceeds`: cascade-rule static walks
					// see the flat shape; the asymmetric BG semantic
					// only applies to the renderer-side rest-of-stack
					// probe (slice ω-iffulllineexceeds-primitive). The
					// primitive's own subtree width uses this same
					// `flatTokenWidth` (defer BG) — sister forwarding.
					stack.push(flatDoc);
				case Fill(items, sep, _):
					var k:Int = items.length;
					while (k > 0) {
						k--;
						stack.push(items[k]);
						if (k > 0) stack.push(sep);
					}
				case OptSpace(s):
					total += s.length;
				case OptSpaceSkipAfterHardline:
					total += 1;
			}
		}
		return total;
	}
}
