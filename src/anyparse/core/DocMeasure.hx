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
	public static function flatTokenWidth(d: Doc): Int {
		final stack: Array<Doc> = [d];
		var total: Int = 0;
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			total += flatTokenWidthStep(node, stack);
		}
		return total;
	}

	/**
	 * The leading token run that precedes `d`'s FIRST break opportunity —
	 * what the renderer keeps on the CURRENT line once `d`'s own outermost
	 * wrap fires (`new Foo(` for a call whose arguments leading-break).
	 * Reports that run's flat `width` and whether it ENDS AT an open
	 * delimiter (`endsAtOpenDelim`, the same `(`/`[`/`{`/`->` verdict the
	 * renderer's leading-break glue state reads through
	 * `lastCharIsOpenDelim`).
	 *
	 * PESSIMISTIC by construction: every conditional (`IfBreak` /
	 * `If*Exceeds`) resolves to its BREAK side, every `Line` (soft or
	 * forced), `OptHardline*` and deferred `BodyGroup` terminates the run,
	 * and a `Fill` contributes only its first item (every inter-item
	 * separator is a break point). `width` is therefore a LOWER bound on the
	 * rendered head, and a consumer that fires a last-resort break when the
	 * head STILL overflows can only under-fire, never over-fire. Two
	 * documented approximations: a `Line` inside a `Flatten` / `HardFlatten`
	 * region stops the run even though that region never breaks, and a
	 * branch-asymmetric conditional with no `Line` at all can make `width`
	 * exceed `flatTokenWidth(d)` — both stay on the conservative side of the
	 * consumer's "does the head STILL overflow" question.
	 *
	 * Consumer: the decl-header arm of `breakAfterLeadOnOverflow`
	 * (`WriterLowering.breakAfterLeadOnOverflowWrap`) — a `var` / `final`
	 * whose RHS already wraps its own call arguments but whose remaining
	 * header line still exceeds `maxLineLength` breaks after the `=`. The
	 * glued-shape probes (`IfNaturalFirstLineExceeds`) cannot answer that
	 * question: they resolve such a RHS flat and measure the ONE-LINE width,
	 * which reaches the limit for every declaration whose call args wrap.
	 * `endsAtOpenDelim` is what keeps that consumer off a head that ends at
	 * an OPERAND — an operator chain led by a literal or an identifier
	 * carries its wrap on its own LATER lines, and breaking the `=` there
	 * double-breaks it. A chain whose FIRST operand is itself a bracketed
	 * construct does end at an open delimiter and does arm: its head is a
	 * real over-wide line that nothing else can shorten (pinned by
	 * `HxDeclHeaderEqBreakOverflowTest.testCallLedChainHeadBreaksAfterEq`).
	 *
	 * Stack-based walk — items pushed in reverse so pop order matches
	 * left-to-right traversal; the walk stops at the first break point.
	 */
	public static function breakableHead(d: Doc): { width: Int, endsAtOpenDelim: Bool } {
		final stack: Array<Doc> = [d];
		var total: Int = 0;
		var delim: Bool = false;
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			final step: { add: Int, stop: Bool, delim: Null<Bool> } = breakableHeadStep(node, stack);
			total += step.add;
			if (step.delim != null) delim = step.delim;
			if (step.stop) break;
		}
		return { width: total, endsAtOpenDelim: delim };
	}

	/**
	 * The "ends at an open delimiter" verdict for the last non-whitespace char
	 * of `s`: `true` for `(` / `[` / `{` or an arrow `->`, `false` for any
	 * other char, and `null` when `s` has no non-whitespace char (all-space or
	 * empty) — in which case the caller must LEAVE its running glue state
	 * unchanged (a whitespace-only run is not a verdict). Two consumers read
	 * it in the SAME direction (`true` = keep the construct on this line /
	 * arm the head probe), so it stays tightenable in one place:
	 * `Renderer.naturalFirstLineGluable`'s leading-break glue state and
	 * `breakableHead`'s `endsAtOpenDelim`.
	 */
	public static function lastCharIsOpenDelim(s: String): Null<Bool> {
		var i: Int = s.length - 1;
		while (i >= 0) {
			final c: Int = StringTools.fastCodeAt(s, i);
			if (c == ' '.code || c == '\t'.code) {
				i--;
				continue;
			}
			final arrow: Bool = c == '>'.code && i > 0 && StringTools.fastCodeAt(s, i - 1) == '-'.code;
			return c == '('.code || c == '['.code || c == '{'.code || arrow;
		}
		return null;
	}

	/**
	 * True when `d`'s flat rendering contains a FORCED hardline — a
	 * `Line('\n'…)` on the flat path or inside a deferred `BodyGroup`
	 * (multi-statement lambda body, trivia-bearing object literal). Walks
	 * the same flat-side arms as `flatTokenWidth` but DESCENDS into
	 * `BodyGroup` content (which `flatTokenWidth` defers as zero-width):
	 * the question here is "does this content force its own line breaks",
	 * not "how wide is it". Soft separators (`Line(' ')`, `OptSpace`,
	 * `OptHardline*`) do not count — only an unconditional `'\n'`.
	 */
	public static function hasForcedBreak(d: Doc): Bool {
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			final node: Doc = (cast stack.pop(): Doc);
			switch (node) {
				case Line(flat) if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code):
					return true;
				case Empty | Text(_) | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
					| OptHardlineSkipBeforeHardline:
				case Concat(items):
					for (item in items) stack.push(item);
				case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
					stack.push(sep);
					for (item in items) stack.push(item);
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner) | IfBreak(_, inner) | IfWidthExceeds(
					_, _, inner
				) | IfFirstLineExceeds(_, _, inner) | IfLineExceeds(_, _, inner) | IfResidualLineExceeds(_, _, inner) | IfFullLineExceeds(
					_, _, inner
				) | IfNaturalFirstLineExceeds(_, _, inner) | IfNaturalFirstLineFitsOpenDelim(_, _, inner) | IfArrowContinuationFits(
					_, _, _, _, inner
				) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(inner) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(
					inner
				) | CollapseChainProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
			}
		}
		return false;
	}

	/**
	 * True iff `d` contains an `OptHardline` / `OptHardlineSkipAtOpenDelim` /
	 * `OptHardlineSkipBeforeHardline` atom - the three ctors
	 * `Renderer.fitsFlat` classifies as "hardlines by intent" that can never
	 * flatten. Sister of `hasForcedBreak`, which deliberately answers `false`
	 * for all three: they are OPTIONAL breaks (each drops when the next emit
	 * is already a hardline), so on their own they must not push an enclosing
	 * cascade into break mode.
	 *
	 * The distinction a caller needs: dropping is legal only where a real
	 * hardline follows. Inside a force-flat region (`Flatten` / `HardFlatten`)
	 * `Renderer.emitOptHardline` / `emitOptSpaceVariants` drop them
	 * UNCONDITIONALLY, which deletes breaks their emitter required - notably
	 * the `trailingCommentDocGuarded` break that keeps a group's closing
	 * delimiter off a captured `//` comment's line. A caller about to build a
	 * force-flat region checks here first.
	 *
	 * Walks the flat side of every `If*` probe and DESCENDS into `BodyGroup`
	 * and the force-flat markers themselves - both mirror `hasForcedBreak`,
	 * and a nested marker is no proof the atom is dead (an inner
	 * `WrapBoundary` resets force-flat). Over-reporting only costs a caller
	 * its flat layout; under-reporting costs a dropped break.
	 */
	public static function hasOptHardline(d: Doc): Bool {
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			final node: Doc = (cast stack.pop(): Doc);
			switch (node) {
				case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
					return true;
				case Empty | Text(_) | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline:
				case Concat(items):
					for (item in items) stack.push(item);
				case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
					stack.push(sep);
					for (item in items) stack.push(item);
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner) | IfBreak(_, inner) | IfWidthExceeds(
					_, _, inner
				) | IfFirstLineExceeds(_, _, inner) | IfLineExceeds(_, _, inner) | IfResidualLineExceeds(_, _, inner) | IfFullLineExceeds(
					_, _, inner
				) | IfNaturalFirstLineExceeds(_, _, inner) | IfNaturalFirstLineFitsOpenDelim(_, _, inner) | IfArrowContinuationFits(
					_, _, _, _, inner
				) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(inner) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(
					inner
				) | CollapseChainProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
			}
		}
		return false;
	}

	/**
	 * Concatenates the visible flat text of `d` left-to-right (forced
	 * hardlines contribute nothing). Stack-based walk mirroring
	 * `flatTokenWidth` but accumulating the characters rather than just the
	 * width — used by `operandIsCall` to scan an operand for a call `(`.
	 */
	public static function flatText(d: Doc): String {
		final buf: StringBuf = new StringBuf();
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			final node: Doc = (cast stack.pop(): Doc);
			switch node {
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline | OptSpaceSkipAfterHardline:
				case Text(s):
					buf.add(s);
				case Line(flat):
					if (!(flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code)) buf.add(flat);
				case OptSpace(s):
					buf.add(s);
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
					inner
				) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
					inner
				) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
				case Concat(items):
					var k: Int = items.length;
					while (--k >= 0) stack.push(items[k]);
				case IfBreak(_, fl) | IfWidthExceeds(_, _, fl) | IfFirstLineExceeds(_, _, fl) | IfLineExceeds(_, _, fl) | IfResidualLineExceeds(
					_, _, fl
				) | IfFullLineExceeds(_, _, fl) | IfNaturalFirstLineExceeds(_, _, fl) | IfNaturalFirstLineFitsOpenDelim(_, _, fl) | IfArrowContinuationFits(
					_, _, _, _, fl
				):
					stack.push(fl);
				case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
					var k: Int = items.length;
					while (k > 0) {
						k--;
						stack.push(items[k]);
						if (k > 0) stack.push(sep);
					}
			}
		}
		return buf.toString();
	}

	/**
	 * True iff operand `d`'s flat text is a TOP-LEVEL function call —
	 * `<ident-chain>(…)` (incl. `obj.method(…)` / `Type.fn(…)`). The operand's
	 * FIRST visible char must be an identifier start (letter / `_` / `$`); a
	 * leading paren-expression (`(a && b)`), array, object, or prefix-op
	 * operand is NOT a simple call (its inner `(` is ENCLOSED by the operand,
	 * which fork `hasSimpleCallParamBreaksBetween` does not treat as a wrapping
	 * callParameter). Then any `(` preceded by an identifier / `)` / `>` char
	 * marks the call. Pure flat-text scan (O(operand width), no recursion
	 * across the binary spine). Shared by `BinaryChainEmit` (the
	 * ω-opbool-reeval marker gate) and `CollapsePass` (the flip + flatten
	 * decision).
	 */
	public static function operandIsCall(d: Doc): Bool {
		final s: String = flatText(d);
		var prevNonWs: Int = -1;
		for (i in 0...s.length) {
			final c: Int = StringTools.fastCodeAt(s, i);
			if (c == ' '.code || c == '\t'.code) continue;
			if (prevNonWs == -1 && !isIdentStart(c)) return false;
			if (c == '('.code && prevNonWs != -1 && isCallPrefixChar(prevNonWs)) return true;
			prevNonWs = c;
		}
		return false;
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
	public static function endsWithCloseBrace(d: Doc): Bool {
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			switch node {
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline | OptSpaceSkipAfterHardline:
				case Text(s) | OptSpace(s) | Line(s):
					final t: String = StringTools.rtrim(s);
					if (t.length > 0) return StringTools.fastCodeAt(t, t.length - 1) == '}'.code;
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
					inner
				) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
					inner
				) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfBreak(_, flatDoc) | IfWidthExceeds(_, _, flatDoc) | IfFirstLineExceeds(_, _, flatDoc) | IfLineExceeds(_, _, flatDoc) | IfResidualLineExceeds(
					_, _, flatDoc
				) | IfFullLineExceeds(_, _, flatDoc) | IfNaturalFirstLineExceeds(_, _, flatDoc) | IfNaturalFirstLineFitsOpenDelim(
					_, _, flatDoc
				) | IfArrowContinuationFits(_, _, _, _, flatDoc):
					stack.push(flatDoc);
				case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
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
	public static function endsWithStmtTerminator(d: Doc): Bool {
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			switch node {
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline | OptSpaceSkipAfterHardline:
				case Text(s) | OptSpace(s) | Line(s):
					final t: String = StringTools.rtrim(s);
					if (t.length > 0) {
						final c: Int = StringTools.fastCodeAt(t, t.length - 1);
						return c == '}'.code || c == ';'.code;
					}
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
					inner
				) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
					inner
				) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfBreak(_, flatDoc) | IfWidthExceeds(_, _, flatDoc) | IfFirstLineExceeds(_, _, flatDoc) | IfLineExceeds(_, _, flatDoc) | IfResidualLineExceeds(
					_, _, flatDoc
				) | IfFullLineExceeds(_, _, flatDoc) | IfNaturalFirstLineExceeds(_, _, flatDoc) | IfNaturalFirstLineFitsOpenDelim(
					_, _, flatDoc
				) | IfArrowContinuationFits(_, _, _, _, flatDoc):
					stack.push(flatDoc);
				case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
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
	public static function endsWithSemi(d: Doc): Bool {
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			switch node {
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline | OptSpaceSkipAfterHardline:
				case Text(s) | OptSpace(s) | Line(s):
					final t: String = StringTools.rtrim(s);
					if (t.length > 0) {
						final c: Int = StringTools.fastCodeAt(t, t.length - 1);
						return c == ';'.code;
					}
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
					inner
				) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
					inner
				) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfBreak(_, flatDoc) | IfWidthExceeds(_, _, flatDoc) | IfFirstLineExceeds(_, _, flatDoc) | IfLineExceeds(_, _, flatDoc) | IfResidualLineExceeds(
					_, _, flatDoc
				) | IfFullLineExceeds(_, _, flatDoc) | IfNaturalFirstLineExceeds(_, _, flatDoc) | IfNaturalFirstLineFitsOpenDelim(
					_, _, flatDoc
				) | IfArrowContinuationFits(_, _, _, _, flatDoc):
					stack.push(flatDoc);
				case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
					for (it in items) stack.push(it);
			}
		}
		return false;
	}

	/**
	 * Right-spine walk: does `d`'s rendered tail consist of a FORCED hardline
	 * followed only by close delimiters (`)` / `}` / `]`) and whitespace? In
	 * other words, does `d` end on a dedented closing line that some following
	 * token could legally ride?
	 *
	 * Sister of `endsWithCloseBrace`, which asks only about the LAST visible
	 * character and cannot tell a one-line `{ a: 1 }` from a broken-open block.
	 * The extra fact here is that the close was reached across a break, so the
	 * answer is a property of the SHAPE, not of the final byte.
	 *
	 * The question is answered STRUCTURALLY, never by width: only an
	 * unconditional `Line('\n')` counts, and every conditional ctor is read on
	 * its FLAT side (mirroring `hasForcedBreak` / `flatText` /
	 * `endsWithCloseBrace`), so a construct the RENDERER would break for being
	 * too wide answers `false`. `BodyGroup` is DESCENDED, and that descent is
	 * the point: a lambda block body's own forced hardline is the signal.
	 *
	 * What actually forces such a hardline in the Haxe writer, measured:
	 *  - a lambda / function BLOCK body with at least one statement — always,
	 *    even when the source wrote it on one line;
	 *  - a bracketed literal exactly when its OWN wrap cascade already committed
	 *    to breaking it at build time. Which is why is the cascade's business,
	 *    not this walk's: under the stock object-literal rules an item count
	 *    above the threshold breaks a one-line source literal, while at or below
	 *    it `Keep` semantics reproduce the source's own line breaks — so the
	 *    same AST can answer either way depending on how it was written. What
	 *    the cascade defers to the RENDERER (`ExceedsMaxLineLength`) never
	 *    reaches here, since conditionals are read flat. A trailing comma is an
	 *    OUTPUT of a break, never a cause of one.
	 *
	 * Introduced for the cuddled-link gate
	 * (`WriteOptions.methodChainCuddledLinks`), where the closes-only
	 * requirement additionally pins the ride-along point to a low column.
	 */
	public static function endsWithForcedCloseLine(d: Doc): Bool {
		return scanTail(d) == TailBreak;
	}

	/**
	 * Tri-state right-to-left walker behind `endsWithForcedCloseLine`:
	 * `TailCloses` while only close delimiters and whitespace have been seen,
	 * `TailBreak` once a forced hardline is reached with such a tail,
	 * `TailOther` as soon as substantive content appears.
	 *
	 * Arms are grouped as in `endsWithCloseBrace` (its right-spine model) and
	 * enumerate every `Doc` ctor with no catch-all, so a new ctor breaks
	 * compilation here rather than silently taking a default. Unlike the
	 * stack-based walks in this class this one recurses, because the verdict of
	 * a child decides whether its left siblings are visited at all — the same
	 * reason `MethodChainEmit.endsWithLineComment` recurses; depth is bounded
	 * by expression nesting.
	 *
	 * The `Fill*` separator is skipped, matching `endsWithCloseBrace`: it never
	 * renders after the last item. Skipping it can only UNDER-report (a
	 * hardline separator is not seen), never manufacture a false `TailBreak`.
	 */
	private static function scanTail(d: Doc): DocTailScan {
		return switch d {
			// No visible tail content. A trailing `OptHardline*` is treated as
			// transparent rather than as a break — no emitter produces one in
			// tail position, and reading it as a break would claim a closing
			// line that the atom has already terminated.
			case Empty | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline | OptSpaceSkipAfterHardline:
				TailCloses;
			case Line(flat) if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code):
				TailBreak;
			case Text(s) | OptSpace(s) | Line(s):
				closesOnly(s) ? TailCloses : TailOther;
			case Concat(items) | Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
				scanTailItems(items);
			case Nest(_, inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
				inner
			) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
				inner
			) | ConditionalMarkerDecrease(inner):
				scanTail(inner);
			case IfBreak(_, flatDoc) | IfWidthExceeds(_, _, flatDoc) | IfFirstLineExceeds(_, _, flatDoc) | IfLineExceeds(_, _, flatDoc) | IfResidualLineExceeds(
				_, _, flatDoc
			) | IfFullLineExceeds(_, _, flatDoc) | IfNaturalFirstLineExceeds(_, _, flatDoc) | IfNaturalFirstLineFitsOpenDelim(_, _, flatDoc) | IfArrowContinuationFits(
				_, _, _, _, flatDoc
			):
				scanTail(flatDoc);
		};
	}

	/**
	 * Scan a container's children right-to-left, stopping at the first child
	 * that is not `TailCloses` — that child's own verdict is the container's. A
	 * container whose every child is closes-only is itself closes-only.
	 */
	private static function scanTailItems(items: Array<Doc>): DocTailScan {
		var i: Int = items.length - 1;
		while (i >= 0) {
			final r: DocTailScan = scanTail(items[i]);
			if (r != TailCloses) return r;
			i--;
		}
		return TailCloses;
	}

	/** True iff `s` holds nothing but close delimiters (`)` / `}` / `]`) and whitespace. */
	private static function closesOnly(s: String): Bool {
		final t: String = StringTools.rtrim(s);
		for (i in 0...t.length) {
			final c: Int = StringTools.fastCodeAt(t, i);
			if (c == ' '.code || c == '\t'.code) continue;
			if (c != ')'.code && c != '}'.code && c != ']'.code) return false;
		}
		return true;
	}

	/** True iff char code `c` may start an identifier (letter / `_` / `$`). */
	private static inline function isIdentStart(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code || c == '$'.code;
	}

	/**
	 * True iff char code `c` (the char immediately before a `(`) marks that `(`
	 * as a CALL open paren rather than a grouping paren — an identifier char,
	 * a close `)` (`f()()`), or a type-param close `>` (`f<T>()`).
	 */
	private static inline function isCallPrefixChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code
			|| c == '$'.code || c == ')'.code || c == '>'.code;
	}

	/**
	 * Token-width contribution of a single `node`, pushing its measurable
	 * children onto `stack` for the caller's walk to drain. Split out of
	 * `flatTokenWidth` to keep the walk loop under the complexity threshold.
	 */
	private static function flatTokenWidthStep(node: Doc, stack: Array<Doc>): Int {
		switch (node) {
			// Zero-width: forced hardlines contribute nothing, and `BodyGroup`
			// content is deferred (decides its own flat/break at render time and
			// must not inflate the parent's static width — mirrors
			// `Renderer.fitsFlat`).
			case Empty | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline | BodyGroup(_):
				return 0;
			case Text(s):
				return s.length;
			case Line(flat):
				// A forced hardline (`'\n'`) contributes 0; an `OptSpace`-style
				// flat string contributes its own length.
				return flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code ? 0 : flat.length;
			case Concat(items):
				var i: Int = items.length;
				while (--i >= 0) stack.push(items[i]);
				return 0;
			// Single-child descend: every wrapper and conditional `If*` kind
			// contributes no width of its own and forwards measurement to its
			// flat-side child. `If*` arms walk the flat shape (render-side
			// thresholds are decided at layout, not here); the force-flat /
			// conditional-indent markers are render-time state transparent to
			// static token-width measurement.
			case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | IfBreak(_, inner) | IfWidthExceeds(_, _, inner) | IfFirstLineExceeds(
				_, _, inner
			) | IfLineExceeds(_, _, inner) | IfResidualLineExceeds(_, _, inner) | IfFullLineExceeds(_, _, inner) | IfNaturalFirstLineExceeds(
				_, _, inner
			) | IfNaturalFirstLineFitsOpenDelim(_, _, inner) | IfArrowContinuationFits(_, _, _, _, inner) | Flatten(inner) | WrapBoundary(
				inner
			) | HardFlatten(inner) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
				inner
			) | ConditionalMarkerDecrease(inner):
				stack.push(inner);
				return 0;
			case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
				var k: Int = items.length;
				while (k > 0) {
					k--;
					stack.push(items[k]);
					if (k > 0) stack.push(sep);
				}
				return 0;
			case OptSpace(s):
				return s.length;
			case OptSpaceSkipAfterHardline:
				return 1;
		}
	}

	/**
	 * One step of `breakableHead`'s walk: the node's own width plus
	 * whether it TERMINATES the head run. Split out of the loop to keep both
	 * halves under the complexity threshold, mirroring `flatTokenWidthStep`.
	 */
	private static function breakableHeadStep(node: Doc, stack: Array<Doc>): { add: Int, stop: Bool, delim: Null<Bool> } {
		switch (node) {
			case Empty:
				return { add: 0, stop: false, delim: null };
			case Text(s) | OptSpace(s):
				return { add: s.length, stop: false, delim: lastCharIsOpenDelim(s) };
			case OptSpaceSkipAfterHardline:
				return { add: 1, stop: false, delim: null };
			// Every break point ends the head. A soft `Line` counts even
			// though its Group may render flat — the head is a lower bound.
			// `BodyGroup` is deferred content that lays itself out on the
			// lines below, so its `{` (a preceding `Text`) closes the head.
			case Line(_) | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline | BodyGroup(_):
				return { add: 0, stop: true, delim: null };
			case Concat(items):
				var i: Int = items.length;
				while (--i >= 0) stack.push(items[i]);
				return { add: 0, stop: false, delim: null };
			case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
				// Only the first item can share the head's line; the
				// separator before every later item is a break point.
				if (items.length > 1) stack.push(OptHardline);
				if (items.length > 0) stack.push(items[0]);
				return { add: 0, stop: false, delim: null };
			// Break-side descend: the head is measured as if every
			// conditional took its wrapping branch.
			case IfBreak(brk, _) | IfWidthExceeds(_, brk, _) | IfFirstLineExceeds(_, brk, _) | IfLineExceeds(_, brk, _) | IfResidualLineExceeds(
				_, brk, _
			) | IfFullLineExceeds(_, brk, _) | IfNaturalFirstLineExceeds(_, brk, _) | IfNaturalFirstLineFitsOpenDelim(_, brk, _):
				stack.push(brk);
				return { add: 0, stop: false, delim: null };
			case IfArrowContinuationFits(_, _, _, _, fl):
				// The ONE probe whose `breakDoc` is the wider shape (the arrow
				// head GLUED to the open paren, body broken) while `flatDoc`
				// opens the paren first — descending the break side here would
				// make `width` an UPPER bound and break the lower-bound
				// invariant this walk promises.
				stack.push(fl);
				return { add: 0, stop: false, delim: null };
			case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(inner) | CollapseProbe(
				inner
			) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(
				inner
			):
				stack.push(inner);
				return { add: 0, stop: false, delim: null };
		}
	}

}

/**
 * Tri-state verdict of `DocMeasure.scanTail`'s right-to-left walk over a
 * `Doc`'s rendered tail.
 */
private enum abstract DocTailScan(Int) {

	/** A forced hardline was reached and everything to its right was close delimiters / whitespace. */
	final TailBreak = 0;

	/** Only close delimiters and whitespace seen so far; keep scanning left. */
	final TailCloses = 1;

	/** Substantive content sits to the right of any hardline — the tail is not a closing line. */
	final TailOther = 2;

}
