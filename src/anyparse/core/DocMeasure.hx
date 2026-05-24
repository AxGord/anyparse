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
	 * `OptHardlineSkipAtOpenDelim`, `OptHardlineSkipBeforeHardline`)
	 * as zero width instead of aborting
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
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
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
				case Group(inner) | GroupWithRestProbe(inner):
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
				case Fill(items, sep, _) | FillWithRestProbe(items, sep, _):
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
				case Flatten(inner) | WrapBoundary(inner):
					// ω-force-flat-engine slice A: pass-through. Both
					// markers are render-time state; structural token-width
					// measurement is independent of force-flat propagation.
					stack.push(inner);
			}
		}
		return total;
	}

	/**
	 * Right-spine walk: does this `Doc` render with its last visible
	 * non-whitespace character equal to `}`? Used by the BlockBody Star
	 * primitive (`@:sep(';', tailRelax, blockEnded)`) to decide whether
	 * the separator can be omitted between two elements — when the prior
	 * element ends with `}` (block, object literal, anon struct, etc.) the
	 * Haxe-style grammar permits the next element to follow directly.
	 *
	 * Whitespace-only fragments (`Line(' ')`, `OptHardline`, blank
	 * `Text`) are transparently skipped. `IfBreak` / `IfWidthExceeds` /
	 * `IfLineExceeds` / `IfFullLineExceeds` / `IfFirstLineExceeds` use
	 * the flat-side representative — mirrors `flatTokenWidth`. `Fill`
	 * scans its items right-to-left, ignoring the inter-item separator
	 * (its text would not appear after the last item).
	 */
	public static function endsWithCloseBrace(d:Doc):Bool {
		final stack:Array<Doc> = [d];
		while (stack.length > 0) {
			final node:Doc = stack.pop();
			switch node {
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim
						| OptHardlineSkipBeforeHardline | OptSpaceSkipAfterHardline:
				case Text(s) | OptSpace(s) | Line(s):
					final t:String = StringTools.rtrim(s);
					if (t.length > 0) return StringTools.fastCodeAt(t, t.length - 1) == '}'.code;
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner)
						| BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfBreak(_, flatDoc) | IfWidthExceeds(_, _, flatDoc)
						| IfFirstLineExceeds(_, _, flatDoc) | IfLineExceeds(_, _, flatDoc)
						| IfFullLineExceeds(_, _, flatDoc):
					stack.push(flatDoc);
				case Fill(items, _, _) | FillWithRestProbe(items, _, _):
					for (it in items) stack.push(it);
			}
		}
		return false;
	}

	/**
	 * True iff the rightmost emitted byte of `d` is `}` (block-closed)
	 * OR `;` (already-statement-terminated). Used by Session-3
	 * `@:sep(';', tailRelax, blockEnded)` Star writers to suppress
	 * between-element sep emission when the prior element's rendered
	 * Doc already terminates a statement — covers both block-shaped
	 * forms (`if (c) {...}`) and inner-statement forms whose own
	 * `@:trail(';')` already emitted `;` (e.g. `if (c) return;`,
	 * `VoidReturnStmt`).
	 *
	 * Sibling of `endsWithCloseBrace`; same right-spine walk + same
	 * whitespace-skipping semantics. Two-byte fallback (`}` or `;`)
	 * keeps the inter-stmt model correct without requiring the parser
	 * side to know when an inner construct consumed `;`.
	 */
	public static function endsWithStmtTerminator(d:Doc):Bool {
		final stack:Array<Doc> = [d];
		while (stack.length > 0) {
			final node:Doc = stack.pop();
			switch node {
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim
						| OptHardlineSkipBeforeHardline | OptSpaceSkipAfterHardline:
				case Text(s) | OptSpace(s) | Line(s):
					final t:String = StringTools.rtrim(s);
					if (t.length > 0) {
						final c:Int = StringTools.fastCodeAt(t, t.length - 1);
						return c == '}'.code || c == ';'.code;
					}
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner)
						| BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfBreak(_, flatDoc) | IfWidthExceeds(_, _, flatDoc)
						| IfFirstLineExceeds(_, _, flatDoc) | IfLineExceeds(_, _, flatDoc)
						| IfFullLineExceeds(_, _, flatDoc):
					stack.push(flatDoc);
				case Fill(items, _, _) | FillWithRestProbe(items, _, _):
					for (it in items) stack.push(it);
			}
		}
		return false;
	}

	/**
	 * Stricter sister of `endsWithStmtTerminator`: returns true only when
	 * the rightmost non-whitespace byte is `;`. Used by BlockBody Star
	 * trail / between-element sep emission to skip a redundant `;`
	 * already baked by an inner stmt's own `@:trail(';')` /
	 * `@:trailOpt(';')`. Crucially does NOT treat `}` as a terminator —
	 * with the BlockBody Star sep-ownership model (Session 9/10), a
	 * trailing `}` belongs to the stmt's inner value expression (e.g.
	 * `var x = {a:1}`) and the Star still owns the trailing `;`. Compare:
	 * `endsWithStmtTerminator` was correct under the pre-Session-10 model
	 * where every brace-ending stmt was self-contained; after migration,
	 * the `}` arm conflates value-block-close with stmt-block-close.
	 */
	public static function endsWithSemi(d:Doc):Bool {
		final stack:Array<Doc> = [d];
		while (stack.length > 0) {
			final node:Doc = stack.pop();
			switch node {
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim
						| OptHardlineSkipBeforeHardline | OptSpaceSkipAfterHardline:
				case Text(s) | OptSpace(s) | Line(s):
					final t:String = StringTools.rtrim(s);
					if (t.length > 0) {
						final c:Int = StringTools.fastCodeAt(t, t.length - 1);
						return c == ';'.code;
					}
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner)
						| BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfBreak(_, flatDoc) | IfWidthExceeds(_, _, flatDoc)
						| IfFirstLineExceeds(_, _, flatDoc) | IfLineExceeds(_, _, flatDoc)
						| IfFullLineExceeds(_, _, flatDoc):
					stack.push(flatDoc);
				case Fill(items, _, _) | FillWithRestProbe(items, _, _):
					for (it in items) stack.push(it);
			}
		}
		return false;
	}
}
