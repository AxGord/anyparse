package anyparse.core;

import anyparse.format.IndentChar;

/**
	Render-local mutable carrier for the `render` layout loop's scalar
	accumulators plus the immutable run config. A fresh instance is built
	per `render` call (never a static / Renderer field — invariant #1), so
	the emit helpers can mutate the shared state by reference instead of
	threading eight accumulators through every signature.
**/
private typedef RenderCtx = {
	final buf: StringBuf;
	final indentChar: IndentChar;
	final tabWidth: Int;
	final lineEnd: String;
	final trailingWhitespace: Bool;
	// One indent level in columns under a `ConditionalMarkerDecrease` scope.
	final markerDecreaseUnit: Int;
	var col: Int;
	var pendingIndent: Int;
	var pendingOptSpace: Null<String>;
	var pendingHardline: Int;
	var lastEmit: LastEmit;
	var lineCount: Int;
	var markerZeroDepth: Int;
	var markerDecreaseDepth: Int;
};

/**
	Layout mode for a `Doc` frame: flat (line breaks become their flat
	replacement) or broken (line breaks become real newlines).
**/
private enum Mode {

	MFlat;
	MBreak;

}

/**
	Classifies the last byte committed to the output buffer. Drives the
	collision/glue decisions made by `OptHardline` and
	`OptHardlineSkipAtOpenDelim` when their `\n+indent` would be redundant
	or would break a deliberate open-delim glue.

	The three states are mutually exclusive — replaces a prior pair of
	parallel `lastEmittedWasHardline`/`lastEmittedWasOpenDelim` Bool flags
	whose mutex was a convention, not type-enforced.

	- `Other` — initial state and after any non-hardline, non-open-delim
	  emit (Text not ending in `(`/`[`/`{`, in-flat `Line` content,
	  `OptSpace` flush). Both opt-hardline ctors emit `\n+indent`.
	- `Hardline` — a `\n` was just written (break-mode `Line`,
	  `OptHardline` emit, or `OptHardlineSkipAtOpenDelim` emit). Both
	  opt-hardline ctors drop their own `\n` (collision avoidance) but
	  may still update `pendingIndent`/`col` to the inner emitter's more-
	  specific indent.
	- `OpenDelim` — last byte is `(`, `[`, or `{`.
	  `OptHardlineSkipAtOpenDelim` drops its `\n+indent` so the next
	  emission glues directly to the open delim (used by chain shapes
	  to honour source `(<chain>` vs `(\n<chain>` distinctions).
**/
private enum LastEmit {

	Other;
	Hardline;
	OpenDelim;

}

/**
	One frame on the rendering stack. Carries the indent and mode that applies
	to the doc it references.

	When `fillRest != null` the frame is a Fill continuation: the renderer
	resumes a `Doc.Fill` after `items[fillIdx-1]` has finished rendering and
	must decide how to lay out `items[fillIdx]` based on the current column.
	`doc` is `Empty` for these frames.
**/
private class Frame {

	public var indent: Int;
	public var mode: Mode;
	public var doc: Doc;
	public var fillRest: Null<Array<Doc>>;
	public var fillIdx: Int;
	public var fillSep: Null<Doc>;
	public var fillTailReserve: Int;

	/**
	 * ω-fill-break-after-wrap: the render's physical-line count at the moment
	 * item `fillIdx - 1` STARTS rendering (snapshotted when this continuation
	 * frame is pushed). At resumption the renderer compares it to the current
	 * `lineCount`: a higher count means item `fillIdx - 1` emitted a newline
	 * while rendering — it self-wrapped past its continuation line — so the
	 * separator before item `fillIdx` is forced to break, matching fork's
	 * flat-width `lineLength` overflow accounting. `-1` disables the check
	 * (the legacy per-item-fit probe alone decides), preserving byte-identical
	 * behavior for every Fill not opting in.
	 */
	public var fillLineStart: Int;

	/**
	 * Rest-of-stack-aware per-item-fit flag (ω-fill-rest-probe). When
	 * `true`, the FillCont resumption probe at the top of the dispatch
	 * loop subtracts `flatTokenWidthOfRestStack(stack)` from the budget
	 * so the LAST packed item leaves room for content trailing the Fill
	 * subtree on the same rendered line — mirrors fork's
	 * `wrapFillLine2AfterLast` `lengthAfter` accounting at the Fill
	 * primitive layer. Set by entry from `Doc.FillWithRestProbe` ctor;
	 * default `false` keeps every existing call-site unchanged.
	 */
	public var fillRestProbe: Bool;

	/**
	 * Force-flat propagation flag (ω-force-flat-engine, slice B). When
	 * `true`, the renderer treats every `Group` / `BodyGroup` as if it
	 * had chosen `MFlat` (skipping `fitsFlat`), picks the flat branch of
	 * every `IfBreak` / `If*Exceeds`, collapses `Fill` to a plain sep-
	 * joined emit, drops `OptHardline*` entirely, and renders `Line(flat)`
	 * as plain text regardless of `mode`. Entered via `Doc.Flatten(inner)`;
	 * reset via `Doc.WrapBoundary(inner)` so nested wrap-cascade outputs
	 * decide independently inside a parent's force-flat region. Default
	 * `false` keeps every existing call-site unchanged.
	 */
	public var forceFlat: Bool;

	/**
	 * Hard-force-flat flag (ω-hardflatten / increment-2). When `true`, the
	 * frame is inside a `Doc.HardFlatten` region: `forceFlat` is also `true`
	 * (the hard region is a force-flat region), BUT an inner `WrapBoundary`
	 * does NOT reset `forceFlat` — it keeps `forceFlat` (and `hardFlat`)
	 * propagating downward. Entered via `Doc.HardFlatten(inner)`; never
	 * reset (the region survives every `WrapBoundary` until the subtree
	 * drains). Default `false` keeps every existing call-site unchanged.
	 */
	public var hardFlat: Bool;

	/**
	 * Conditional-marker-zero pop sentinel (ω-cond-indent-policy FixedZero).
	 * A frame with `popMarkerZero = true` carries `doc = Empty` and exists
	 * solely to decrement the render-local `markerZeroDepth` counter once a
	 * `ConditionalMarkerZero(inner)`'s `inner` has fully drained.
	 * `ConditionalMarkerZero(inner)` pushes this sentinel FIRST, then `inner`
	 * — LIFO drains `inner` (and everything it pushes above the sentinel)
	 * before the sentinel surfaces, so the decrement lands exactly at scope
	 * exit. Default `false`.
	 */
	public var popMarkerZero: Bool;

	/**
	 * Conditional-marker-decrease pop sentinel (ω-cond-indent-policy
	 * AlignedDecrease). A frame with `popMarkerDecrease = true` carries
	 * `doc = Empty` and exists solely to decrement the render-local
	 * `markerDecreaseDepth` counter once a `ConditionalMarkerDecrease(inner)`'s
	 * `inner` has fully drained. `ConditionalMarkerDecrease(inner)` pushes this
	 * sentinel FIRST, then `inner` — LIFO drains `inner` (and everything it
	 * pushes above the sentinel) before the sentinel surfaces, so the
	 * decrement lands exactly at scope exit. Default `false`.
	 */
	public var popMarkerDecrease: Bool;

	public inline function new(indent: Int, mode: Mode, doc: Doc, forceFlat: Bool = false, hardFlat: Bool = false) {
		this.indent = indent;
		this.mode = mode;
		this.doc = doc;
		this.forceFlat = forceFlat;
		this.hardFlat = hardFlat;
		this.fillRest = null;
		this.fillIdx = 0;
		this.fillSep = null;
		this.fillTailReserve = 0;
		this.fillRestProbe = false;
		this.fillLineStart = -1;
		this.popMarkerZero = false;
		this.popMarkerDecrease = false;
	}

	public static inline function fillCont(
		indent: Int, rest: Array<Doc>, idx: Int, sep: Doc, tailReserve: Int, forceFlat: Bool = false, restProbe: Bool = false,
		hardFlat: Bool = false, lineStart: Int = -1
	): Frame {
		final f: Frame = new Frame(indent, MBreak, Empty, forceFlat, hardFlat);
		f.fillRest = rest;
		f.fillIdx = idx;
		f.fillSep = sep;
		f.fillTailReserve = tailReserve;
		f.fillRestProbe = restProbe;
		f.fillLineStart = lineStart;
		return f;
	}

}

/**
	Lays out a `Doc` into a string within a target line width.

	Algorithm: a single top-down traversal with an explicit stack. For each
	`Group`, the renderer runs `fitsFlat` — a fast simulation that counts the
	flat width of the group's content — and chooses between flat and broken
	mode based on whether it fits within `width - currentColumn`.

	This is simpler than Wadler's full continuation look-ahead and ignores
	what comes after a group when deciding; in exchange, it is straightforward
	and fast. Multi-group look-ahead can be added later if real-world
	grammars expose it as a problem.
**/
class Renderer {

	/**
		Render a `Doc` tree to a string at the given `width`, indenting with
		`indentChar` (tab width `tabWidth`). `lineEnd` is the newline sequence;
		`finalNewline` appends one trailing `lineEnd` when missing;
		`maxConsecutiveBlanks` (>= 0) caps runs of blank lines.

		The blank-line handling: a break-mode `Line` leaves its indent pending;
		if the next emit is another break-mode `Line` (an empty row) the prior
		pending indent is overwritten before any tab is written, so the blank
		row carries no trailing whitespace. The pending indent is only ever
		silently discarded — this is exactly what blank lines need (no
		trailing tabs on empty rows). Same effect every mature pretty-printer
		(prettier, black, rustfmt) achieves with a trailing-whitespace strip
		pass, but in O(1) extra space and a single traversal.

		`trailingWhitespace` inverts that blank-line discard: when `true`,
		a pending indent left by the prior break-mode `Line` is flushed
		before the next `lineEnd` instead of being overwritten, so blank
		rows carry the surrounding block's indent. Opt-in knob driven by
		`WriteOptions.trailingWhitespace` — haxe-formatter's
		`indentation.trailingWhitespace: true` layout.
	**/
	public static function render(
		doc: Doc, width: Int, indentChar: IndentChar = Space, tabWidth: Int = 1,
		// ω-cond-indent-policy AlignedDecrease: columns per indent level when
		// `indentChar == Space` (mirrors `WriteOptions.indentSize`). Only read to
		// size the uniform `-1` shift inside a `ConditionalMarkerDecrease` scope;
		// in Tab mode the level unit is `tabWidth` and this is ignored. Defaulted
		// so pre-existing callers stay source-compatible.
		indentSize: Int = 1,
		lineEnd: String = '\n', finalNewline: Bool = false, trailingWhitespace: Bool = false, maxConsecutiveBlanks: Int = -1,
		?decisions: Array<{ node: Doc, crosses: Bool, ?indent: Int }>
	): String {
		// ω-collapse-commit (increment-2): when `decisions != null` this is a
		// MEASURE-ONLY pass driven by `CollapsePass.run`. At every
		// `IfFullLineExceeds` node the renderer records the `crosses` boolean
		// keyed by the node's identity, so the Doc→Doc collapse pass can read
		// which expression parens WOULD open at their true render column —
		// then commit the open + chain-glue in a rewritten Doc (breaking the
		// branch-blind circular coupling between paren-open and chain-break).
		// `null` (the generated `write` call site) leaves render unchanged.
		final stack: Array<Frame> = [new Frame(0, MBreak, doc)];
		// Render-local mutable carrier of the scalar layout accumulators plus
		// the run config (NOT a static / Renderer field — invariant #1). The
		// emit helpers mutate it by reference; the push helpers read it. See
		// the `RenderCtx` typedef for the per-field semantic (pending-indent /
		// pending-opt-space / forward-hardline slots, the `lastEmit` byte
		// classifier, the physical `lineCount`, and the two marker-scope depths).
		final ctx: RenderCtx = {
			buf: new StringBuf(),
			indentChar: indentChar,
			tabWidth: tabWidth,
			lineEnd: lineEnd,
			trailingWhitespace: trailingWhitespace,
			// One indent level in columns under a `ConditionalMarkerDecrease`
			// scope: `indentSize` in Space mode, `tabWidth` in Tab mode (matches
			// the writer's `_dn(_cols, …)` body-nest unit).
			markerDecreaseUnit: indentChar == Space ? indentSize : tabWidth,
			col: 0,
			pendingIndent: -1,
			pendingOptSpace: null,
			pendingHardline: -1,
			lastEmit: Other,
			lineCount: 0,
			markerZeroDepth: 0,
			markerDecreaseDepth: 0
		};

		while (stack.length > 0) {
			final f: Frame = stack.pop();
			// ω-cond-indent-policy FixedZero: pop sentinel. A
			// `ConditionalMarkerZero` frame pushed this `doc=Empty` sentinel
			// BEFORE its `inner`; by the time it surfaces, `inner` has fully
			// drained, so the matching depth increment is undone here at scope
			// exit. Emit nothing.
			if (f.popMarkerZero) {
				if (ctx.markerZeroDepth > 0) ctx.markerZeroDepth--;
				continue;
			}
			// ω-cond-indent-policy AlignedDecrease: pop sentinel. A
			// `ConditionalMarkerDecrease` frame pushed this `doc=Empty` sentinel
			// BEFORE its `inner`; by the time it surfaces, `inner` has fully
			// drained, so the matching depth increment is undone here at scope
			// exit. Emit nothing.
			if (f.popMarkerDecrease) {
				if (ctx.markerDecreaseDepth > 0) ctx.markerDecreaseDepth--;
				continue;
			}
			if (f.fillRest != null) {
				// Fill continuation frame: decide whether the next item packs
				// onto the current line or breaks, pushing the item + separator
				// (+ next continuation) frames. Reads `ctx.col`/`ctx.lineCount`.
				resumeFill(ctx, f, stack, width);
				continue;
			}
			switch (f.doc) {
				case Empty | Text(_) | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
					| OptHardlineSkipBeforeHardline:
					// Content-emitting leaf ctors — mutate the scalar layout
					// accumulators (buf / col / pending* / lastEmit / lineCount).
					// Delegated to the static `emitLeaf` on the `ctx` carrier.
					emitLeaf(ctx, f);
				case Nest(_, _) | Concat(_) | Group(_) | BodyGroup(_) | GroupWithRestProbe(_) | Flatten(_) | WrapBoundary(_) | HardFlatten(
					_
				) | CollapseProbe(_):
					// Structural / descend arms — no scalar layout mutation, only
					// frame pushes. Delegated to the static `pushStructural` (reads
					// `col`/`width`/`f`, writes `stack`). See that helper for each
					// per-ctor semantic.
					pushStructural(f, stack, ctx.col, width);
				case IfBreak(_, _) | IfWidthExceeds(_, _, _) | IfFirstLineExceeds(_, _, _) | IfLineExceeds(_, _, _) | IfFullLineExceeds(
					_, _, _
				) | IfNaturalFirstLineExceeds(_, _, _) | IfNaturalFirstLineFitsOpenDelim(_, _, _) | IfArrowContinuationFits(_, _, _, _, _):
					pushExceedsBranch(f, stack, ctx.col, width, decisions);
				case Fill(_, _, _) | FillWithRestProbe(_, _, _) | FillBreakAfterWrap(_, _, _):
					// Fill family — per-item / all-flat layout, no scalar layout
					// mutation (reads `lineCount` for the break-after-wrap snapshot,
					// writes `stack`). Delegated to the static `pushFill`.
					pushFill(f, stack, ctx.lineCount);
				case CollapseAddProbe(_) | CollapseBoolProbe(_) | CollapseChainProbe(_):
					// Collapse-probe markers — pure render pass-through that records a
					// measure-only decision (reads `col`/`decisions`, writes
					// `decisions`/`stack`). Delegated to the static `pushCollapseProbe`.
					pushCollapseProbe(f, stack, ctx.col, decisions);
				case ConditionalMarkerZero(inner):
					// ω-cond-indent-policy FixedZero: enter a marker-zero scope.
					// Increment the render-local depth so the Text-flush re-indents
					// `#`-leading fresh lines to column 0, then push a
					// `popMarkerZero` sentinel BELOW `inner` so the depth unwinds
					// exactly at scope exit (LIFO: `inner` and everything it spawns
					// drain before the sentinel surfaces). Layout-transparent
					// otherwise — `inner` renders at the same indent/mode/force-flat
					// as the wrapper frame; only the `#`-marker lines move.
					ctx.markerZeroDepth++;
					final popMz: Frame = new Frame(f.indent, f.mode, Empty, f.forceFlat, f.hardFlat);
					popMz.popMarkerZero = true;
					stack.push(popMz);
					stack.push(new Frame(f.indent, f.mode, inner, f.forceFlat, f.hardFlat));
				case ConditionalMarkerDecrease(inner):
					// ω-cond-indent-policy AlignedDecrease: enter a marker-decrease
					// scope. Increment the render-local depth so the Text-flush
					// shifts EVERY fresh line one indent level shallower, then push a
					// `popMarkerDecrease` sentinel BELOW `inner` so the depth unwinds
					// exactly at scope exit (LIFO: `inner` and everything it spawns
					// drain before the sentinel surfaces). Layout-transparent
					// otherwise — `inner` renders at the same indent/mode/force-flat
					// as the wrapper frame; only the per-line `-1` shift applies.
					ctx.markerDecreaseDepth++;
					final popMd: Frame = new Frame(f.indent, f.mode, Empty, f.forceFlat, f.hardFlat);
					popMd.popMarkerDecrease = true;
					stack.push(popMd);
					stack.push(new Frame(f.indent, f.mode, inner, f.forceFlat, f.hardFlat));
			}
		}

		final raw: String = ctx.buf.toString();
		final capped: String = maxConsecutiveBlanks >= 0 ? capConsecutiveBlanks(raw, lineEnd, maxConsecutiveBlanks) : raw;
		return finalNewline && !StringTools.endsWith(capped, lineEnd) ? capped + lineEnd : capped;
	}

	/**
	 * Decide whether a collapse-candidate expression paren COMMITS to open
	 * for the `CollapsePass` decision list (ω-collapse-commit). `breakDoc` is
	 * the paren's OPEN branch from `IfFullLineExceeds(n, breakDoc, glued)`;
	 * `fullLineCrosses` is the raw full-line-overflow result; `indent` is the
	 * paren's render indent; `n` the line-width threshold.
	 *
	 * The open branch carries a `CollapseProbe` (the consumer's marker). The
	 * gate is operator-class-aware via the probe's payload:
	 *  - `CollapseProbe(HardFlatten(_))` (opAddSub inner) → commit iff
	 *    `fullLineCrosses` (unconditional once the line overflows — the
	 *    opened paren owns its content even past width).
	 *  - `CollapseProbe(plain)` (opBool / ternary inner) → commit iff
	 *    `fullLineCrosses` AND the inner rendered FLAT fits at the paren's
	 *    continuation indent (`indent + flatTokenWidth(inner) < n`). `indent`
	 *    is the paren node's render indent, which the chain's own `Nest`
	 *    already advanced to the continuation level — so the opened inner
	 *    sits at exactly `indent` (no extra `cols`). When the inner can't be
	 *    made a single fitting line, opening the paren does not help.
	 * When `breakDoc` carries no `CollapseProbe` (a non-candidate
	 * `IfFullLineExceeds`, e.g. a chain-emit probe), the raw `fullLineCrosses`
	 * is returned unchanged.
	 */
	private static function collapseParenCommitsOpen(
		breakDoc: Doc, fullLineCrosses: Bool, indent: Int, n: Int, restStack: Array<Frame>
	): Bool {
		final probe: Null<{ inner: Doc, hard: Bool }> = findCollapseProbe(breakDoc);
		return probe == null
			? fullLineCrosses
			: probe.hard
				? fullLineCrosses && restStackHasTrailingContent(restStack)
				: fullLineCrosses && indent + DocMeasure.flatTokenWidth(probe.inner) < n;
	}

	/**
	 * True iff the rest-of-stack (the work items still pending AFTER the
	 * current collapse-candidate paren frame) emits any real same-line content
	 * before the next hardline — "real" meaning a token that is NOT a closing
	 * delimiter (`)` / `]` / `}`), statement / element terminator (`;` / `,`),
	 * or whitespace. Used by `collapseParenCommitsOpen`'s opAddSub branch to
	 * distinguish a paren at the expression TAIL (only `));` / `,` trails →
	 * keep glued) from one with a trailing chain (`) / 2 - X` → open + collapse).
	 *
	 * Stack-iterative left-spine scan over each pending Frame's flat shape;
	 * aborts only at a FORCED hardline (a `\n` `Line` flat-replacement or an
	 * opt-hardline) — a soft `Line` is descended past, because whether it
	 * ultimately breaks is a not-yet-made Group verdict at the paren's render
	 * point (single-pass commit) and the STRUCTURAL "is there a binary
	 * continuation after `)`" question is mode-independent. Returns at the
	 * first real character found.
	 */
	private static function restStackHasTrailingContent(restStack: Array<Frame>): Bool {
		var i: Int = restStack.length - 1;
		while (i >= 0) {
			final f: Frame = restStack[i];
			i--;
			final inner: Array<{ doc: Doc, mode: Mode }> = [{ doc: f.doc, mode: f.mode }];
			while (inner.length > 0) {
				final nd: { doc: Doc, mode: Mode } = inner.pop();
				final step: Null<Bool> = trailingScanStep(nd, inner);
				if (step != null) return step;
			}
		}
		return false;
	}

	/**
	 * Locate the `CollapseProbe` in a candidate paren's open branch and
	 * report its inner Doc plus whether that inner is a `HardFlatten`
	 * (opAddSub) vs a plain chain (opBool / ternary). Returns null when no
	 * `CollapseProbe` is present (non-candidate node).
	 */
	private static function findCollapseProbe(d: Doc): Null<{ inner: Doc, hard: Bool }> {
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			final node: Doc = (cast stack.pop(): Doc);
			switch node {
				case CollapseProbe(inner):
					final hard: Bool = switch inner {
						case HardFlatten(_): true;
						case _: false;
					};
					return { inner: inner, hard: hard };
				case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
					inner
				) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(
					inner
				):
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
				case Empty | Text(_) | Line(_) | OptSpace(_) | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline
					| OptSpaceSkipAfterHardline:
			}
		}
		return null;
	}

	/**
		Collapses runs of consecutive `lineEnd` sequences down to
		`maxBlanks + 1` line-end occurrences — i.e. at most `maxBlanks`
		blank lines between any two non-empty lines. Drives the haxe-
		formatter `emptyLines.maxAnywhereInFile` knob (fed through
		`WriteOptions.maxConsecutiveBlanks`). With `maxBlanks = 0` the
		output has no blank lines at all; `maxBlanks = 1` allows one
		blank line at most, etc. Single-character `lineEnd` ("\n", "\r")
		and multi-character ("\r\n") are both handled.

		Pre-condition: `maxBlanks >= 0`; the caller guards `< 0` for
		unbounded (no-cap) mode.
	**/
	private static function capConsecutiveBlanks(s: String, lineEnd: String, maxBlanks: Int): String {
		final leLen: Int = lineEnd.length;
		if (leLen == 0) return s;
		final maxRunLen: Int = (maxBlanks + 1) * leLen;
		final buf: StringBuf = new StringBuf();
		final n: Int = s.length;
		var i: Int = 0;
		var segStart: Int = 0;
		while (i < n) {
			if (startsWithAt(s, i, lineEnd)) {
				if (i > segStart) buf.addSub(s, segStart, i - segStart);
				var runEnd: Int = i + leLen;
				while (runEnd <= n - leLen && startsWithAt(s, runEnd, lineEnd)) runEnd += leLen;
				final runLen: Int = runEnd - i;
				final emitLen: Int = runLen < maxRunLen ? runLen : maxRunLen;
				buf.addSub(s, i, emitLen);
				i = runEnd;
				segStart = i;
			} else {
				i++;
			}
		}
		if (segStart < n) buf.addSub(s, segStart, n - segStart);
		return buf.toString();
	}

	/**
		Returns true iff `s` contains `needle` starting at index `at`.
		Helper for `capConsecutiveBlanks` lineEnd-run detection — operates
		on code-unit boundaries (works for both single-char `\n` / `\r`
		and multi-char `\r\n` line-ends, since the needle is matched
		verbatim).
	**/
	private static function startsWithAt(s: String, at: Int, needle: String): Bool {
		final needleLen: Int = needle.length;
		if (at + needleLen > s.length) return false;
		for (k in 0...needleLen) if (StringTools.fastCodeAt(s, at + k) != StringTools.fastCodeAt(needle, k)) return false;
		return true;
	}

	/**
		Emits `indent` columns worth of leading whitespace. When
		`indentChar=Tab`, this is `floor(indent / tabWidth)` tabs followed
		by `indent mod tabWidth` spaces — in the clean case where every
		`Nest` value is a multiple of `tabWidth`, the remainder is zero
		and output is pure tabs.
	**/
	private static inline function writeIndent(buf: StringBuf, indent: Int, indentChar: IndentChar, tabWidth: Int): Void {
		if (indentChar == Tab && tabWidth > 0) {
			final tabs: Int = Std.int(indent / tabWidth);
			final rem: Int = indent - tabs * tabWidth;
			for (_ in 0...tabs) buf.add('\t');
			for (_ in 0...rem) buf.add(' ');
		} else {
			for (_ in 0...indent) buf.add(' ');
		}
	}

	/**
		Returns `true` if rendering `d` in flat mode at the given indent
		consumes at most `remaining` columns. Used to choose between flat and
		broken layout for a `Group`/`BodyGroup`.
	**/
	private static function fitsFlat(remaining: Int, indent: Int, d: Doc): Bool {
		if (remaining < 0) return false;
		final local: Array<Frame> = [new Frame(indent, MFlat, d)];
		var budget: Int = remaining;

		while (local.length > 0 && budget >= 0) {
			final f: Frame = local.pop();
			final step: { spend: Int, broke: Bool } = fitsFlatStep(f, local);
			if (step.broke) {
				budget = -1;
				break;
			}
			budget -= step.spend;
		}

		return budget >= 0;
	}

	/**
	 * First-line variant of `DocMeasure.flatTokenWidth`. Walks the same flat-shape
	 * tree but caps the measurement at the first forced hardline
	 * (`Line('\n')` or `OptHardline`): the running total at that point is
	 * returned and the rest of the tree is ignored. Used exclusively by
	 * the `IfFirstLineExceeds` probe to answer "would the first rendered
	 * line of `flatDoc` exceed `n` columns from the current pen?".
	 *
	 * Departure from `DocMeasure.flatTokenWidth`: forced hardlines abort the walk
	 * instead of contributing zero width. `BodyGroup` is still deferred
	 * (zero, no abort) — its content decides its own flat/break later
	 * and cannot be predicted at probe time. `Group` descends as usual;
	 * a forced hardline anywhere in its inner aborts the first-line walk
	 * because such a Group must commit to break mode.
	 *
	 * Stack-based walk — items pushed in reverse so pop order matches
	 * left-to-right traversal. The `aborted` flag short-circuits
	 * remaining work once a hardline is seen.
	 */
	private static function flatTokenWidthFirstLine(d: Doc): Int {
		final stack: Array<Doc> = [d];
		var total: Int = 0;
		var aborted: Bool = false;
		while (stack.length > 0 && !aborted) {
			final node: Doc = stack.pop();
			final step: { add: Int, aborted: Bool } = flatFirstLineStep(node, stack);
			total += step.add;
			aborted = step.aborted;
		}
		return total;
	}

	/**
	 * Natural-shape first-line measurer (ω-natural-first-line). Walks `d`
	 * resolving each inner `Group`/`BodyGroup`/`GroupWithRestProbe` by its
	 * OWN `fitsFlat` decision (the real flat/break choice the renderer
	 * would make at the running column), and returns the absolute column
	 * the FIRST physical line reaches — everything up to (not including)
	 * the first naturally-produced hardline.
	 *
	 * Differs from `flatTokenWidthFirstLine`, which descends every Group
	 * flat: here a Group that does NOT fit at the running column commits
	 * to break, its first inner soft `Line` renders as a hardline, and
	 * first-line accumulation stops there. A Group that fits stays flat
	 * and contributes its full flat width to the running line.
	 *
	 * `BodyGroup` is DEFERRED (zero width, no first-line termination) —
	 * its content decides its own flat/break later and is invisible to a
	 * parent's first-line probe (Departure 2, mirrors `fitsFlat` /
	 * `flatTokenWidthFirstLine`).
	 *
	 * `startCol` is folded into the accumulator so each per-Group
	 * `fitsFlat(width - col, ...)` budget uses the live running column —
	 * the same Group fits or breaks depending on where on the line it
	 * starts. The return value already includes `startCol`; the
	 * `IfNaturalFirstLineExceeds` render arm therefore compares the raw
	 * result against `n` (NOT `col + result`).
	 *
	 * Pure stack walk: allocates its own work-stack + `col`/`aborted`
	 * locals, reads only its args, mutates no render state (invariant #1).
	 *
	 * Used exclusively by the `IfNaturalFirstLineExceeds` render arm.
	 */
	private static function naturalFirstLineWidth(d: Doc, startCol: Int, indent: Int, width: Int): Int {
		var col: Int = startCol;
		var aborted: Bool = false;
		// Work items carry their own indent + mode + forceFlat — a faithful
		// mirror of `render`'s Frame fields (mode + forceFlat are independent:
		// MFlat means "a parent Group committed flat"; forceFlat means "inside
		// a `Flatten` region, suppress every Group's own fit decision"). A
		// `WrapBoundary` inside a `Flatten` resets forceFlat (mode preserved)
		// so a nested wrap-cascade's Group re-evaluates `fitsFlat` and may
		// break — exactly as the renderer does.
		final stack: Array<{
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		}> = [
			{
				doc: d,
				indent: indent,
				mode: MBreak,
				forceFlat: false
			}
		];
		while (stack.length > 0 && !aborted) {
			final node: {
				doc: Doc,
				indent: Int,
				mode: Mode,
				forceFlat: Bool
			} = stack.pop();
			final step: { add: Int, aborted: Bool } = naturalWidthStep(node, stack, width, col);
			col += step.add;
			aborted = step.aborted;
		}
		return col;
	}

	/**
	 * Natural-shape first-line END-DELIMITER probe (ω-cond-paren-glued,
	 * increment-4). Walks `d` exactly like `naturalFirstLineWidth` —
	 * resolving each inner `Group`/`BodyGroup`/`GroupWithRestProbe` by its
	 * OWN `fitsFlat` decision at the running column — and returns whether the
	 * LAST non-whitespace character emitted on the FIRST physical line is an
	 * open delimiter (`(`/`[`/`{` or an arrow `->`).
	 *
	 * Returns `true` ("glue is OK") when EITHER (a) the whole cond fit on the
	 * first line with NO inner break (the walk never hit a hardline — a short
	 * cond like `shortCond` stays flat), OR (b) an inner break DID happen and
	 * the last char before it is an open delimiter (`(`/`[`/`{` or arrow `->`)
	 * — the inner construct LEADING-broke right after it (`if (!list.exists(`
	 * then `\n`), so the cond prefix sits on the open line and the cond paren
	 * stays glued. Returns `false` when an inner break happened on packed args
	 * / an operand (the inner construct fillLine-packed, or the cond's own
	 * chain operator breaks) — `emitCondition` then opens the cond paren.
	 *
	 * Pure stack walk: own work-stack + locals, reads only its args, mutates
	 * no render state (invariant #1). Structure mirrors `naturalFirstLineWidth`
	 * minus the width accumulation; only the last-emitted-char class is kept.
	 */
	private static function naturalFirstLineGluable(d: Doc, startCol: Int, indent: Int, width: Int): Bool {
		var col: Int = startCol;
		var aborted: Bool = false;
		var lastOpenDelim: Bool = false;
		final stack: Array<{
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		}> = [
			{
				doc: d,
				indent: indent,
				mode: MBreak,
				forceFlat: false
			}
		];
		while (stack.length > 0 && !aborted) {
			final node: {
				doc: Doc,
				indent: Int,
				mode: Mode,
				forceFlat: Bool
			} = stack.pop();
			final step: { add: Int, aborted: Bool, delim: Null<Bool> } = naturalGluableStep(node, stack, width, col);
			col += step.add;
			aborted = step.aborted;
			if (step.delim != null) lastOpenDelim = step.delim;
		}
		// Glue is OK when the cond fit flat with no inner break (a short cond
		// stays glued), OR an inner break happened right after an open delimiter
		// (the inner construct leading-broke, cond prefix on the open line).
		return !aborted || lastOpenDelim;
	}

	/**
	 * Sums the flat-mode token width of every frame currently on the
	 * rendering stack, walking from top (next to emit) downward, until
	 * a forced hardline is encountered. Hardline detection is mode-aware:
	 * a frame in `MBreak` treats every `Line(_)` as a hardline (the
	 * renderer would emit `\n + indent`); a frame in `MFlat` treats only
	 * `Line(flat)` whose `flat` starts with `\n` (and `OptHardline` /
	 * `OptHardlineSkipAtOpenDelim`) as hardlines. Once a hardline is
	 * hit, the running total is returned and the rest of the stack is
	 * ignored — the lookahead never crosses a line boundary.
	 *
	 * Used exclusively by the `IfLineExceeds` probe to answer "would
	 * the rendered current line, including everything after this
	 * primitive, reach `n` columns?" (slice ω-iflineexceeds-infra).
	 *
	 * Departures from `DocMeasure.flatTokenWidth`:
	 *  - frames carry a mode (the mode they were pushed with) so MBreak
	 *    `Line` aborts immediately;
	 *  - nested `Group` content is descended in `MFlat` (static walk
	 *    can't predict the runtime Group decision; flat-side measurement
	 *    matches the cascade rule semantic "if everything stayed flat,
	 *    would the line exceed?");
	 *  - `BodyGroup` is deferred (zero width, no abort) — same Departure 2
	 *    as `fitsFlat`.
	 *
	 * Stack-based walk over a `(doc, mode)` pair list — items pushed in
	 * reverse so pop order matches left-to-right traversal of each
	 * frame's subtree.
	 */
	private static function flatTokenWidthOfRestStack(stack: Array<Frame>): Int {
		var total: Int = 0;
		var aborted: Bool = false;
		var i: Int = stack.length - 1;
		while (i >= 0 && !aborted) {
			final f: Frame = stack[i];
			i--;
			if (f.fillRest != null) {
				// FillCont frame: a `Doc.Fill` resumption point. In MBreak
				// mode (always — FillCont is constructed only for the
				// per-item path), the next emission likely starts with a
				// hardline at the Fill's indent. Treat as a hardline
				// boundary so the lookahead never crosses a Fill
				// continuation. Conservative under-count for the rare case
				// where Fill items still pack flat is acceptable here —
				// chain dispatch sites don't sit inside Fill primitives.
				aborted = true;
				continue;
			}
			final inner: Array<{ doc: Doc, mode: Mode }> = [{ doc: f.doc, mode: f.mode }];
			while (inner.length > 0 && !aborted) {
				final node: { doc: Doc, mode: Mode } = inner.pop();
				final step: { add: Int, aborted: Bool } = restNodeWidth(node, inner, false);
				total += step.add;
				aborted = step.aborted;
			}
		}
		return total;
	}

	/**
	 * BG-descending sibling of `flatTokenWidthOfRestStack`. Identical
	 * stack-walk + abort-at-hardline semantic except the
	 * `BodyGroup(innerDoc)` arm descends in `MFlat` (mirrors `Group`)
	 * instead of being deferred. Used exclusively by the
	 * `IfFullLineExceeds` probe — chain-emit's wrap decision needs to
	 * see inline body content that follows on the same rendered line
	 * (e.g. `for (cond) BODY` where `BODY` lives inside a `BodyGroup`
	 * from `forBody=fitLine`).
	 *
	 * The sister `flatTokenWidthOfRestStack` stays unchanged
	 * (Departure 2) for the cond-wrap `IfLineExceeds` site whose probe
	 * must NOT include body content (else trailing-comment cond-wrap
	 * fixtures regress — see `feedback_bg_descend_reststack_*` memory).
	 */
	private static function flatTokenWidthOfRestStackFull(stack: Array<Frame>): Int {
		var total: Int = 0;
		var aborted: Bool = false;
		var i: Int = stack.length - 1;
		while (i >= 0 && !aborted) {
			final f: Frame = stack[i];
			i--;
			if (f.fillRest != null) {
				aborted = true;
				continue;
			}
			final inner: Array<{ doc: Doc, mode: Mode }> = [{ doc: f.doc, mode: f.mode }];
			while (inner.length > 0 && !aborted) {
				final node: { doc: Doc, mode: Mode } = inner.pop();
				final step: { add: Int, aborted: Bool } = restNodeWidth(node, inner, true);
				total += step.add;
				aborted = step.aborted;
			}
		}
		return total;
	}

	/**
	 * One step of `restStackHasTrailingContent`'s inner-doc scan. Pushes any
	 * structural children onto `inner` for continued scanning. Returns `null`
	 * to keep scanning, `true` when a non-trivial trailing token was found,
	 * `false` when a hardline boundary terminates the scan.
	 */
	private static function trailingScanStep(nd: { doc: Doc, mode: Mode }, inner: Array<{ doc: Doc, mode: Mode }>): Null<Bool> {
		switch nd.doc {
			case Empty | OptSpace(_) | OptSpaceSkipAfterHardline:
				return null;
			case Text(s):
				return textHasTrailingContent(s) ? true : null;
			case Line(flat):
				// Only a FORCED hardline (`\n` flat-replacement) terminates
				// the trailing-content scan — a soft `Line` is mode-decided
				// by an enclosing Group whose break verdict is NOT yet made
				// at the paren's render point (single-pass commit). Whether
				// the trailing chain (`/ 2 - X`) ultimately rides the close
				// line or wraps is irrelevant to the STRUCTURAL question the
				// fork's `collapseChainBreaksAfter` asks: "is there a binary
				// continuation after the close `)` at all". So descend PAST a
				// soft Line and keep scanning for a real token.
				return (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) ? false : null;
			case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
				return false;
			case Nest(_, innerDoc):
				inner.push({ doc: innerDoc, mode: nd.mode });
				return null;
			case Concat(items):
				var k: Int = items.length;
				while (--k >= 0) inner.push({ doc: items[k], mode: nd.mode });
				return null;
			case Group(innerDoc) | BodyGroup(innerDoc) | GroupWithRestProbe(innerDoc):
				inner.push({ doc: innerDoc, mode: MFlat });
				return null;
			case IfBreak(_, fl) | IfWidthExceeds(_, _, fl) | IfFirstLineExceeds(_, _, fl) | IfLineExceeds(_, _, fl) | IfFullLineExceeds(
				_, _, fl
			) | IfNaturalFirstLineExceeds(_, _, fl) | IfNaturalFirstLineFitsOpenDelim(_, _, fl) | IfArrowContinuationFits(_, _, _, _, fl):
				inner.push({ doc: fl, mode: MFlat });
				return null;
			case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
				var k: Int = items.length;
				while (k > 0) {
					k--;
					inner.push({ doc: items[k], mode: MFlat });
					if (k > 0) inner.push({ doc: sep, mode: MFlat });
				}
				return null;
			case Flatten(innerDoc) | WrapBoundary(innerDoc) | HardFlatten(innerDoc) | CollapseProbe(innerDoc) | CollapseAddProbe(innerDoc) | CollapseBoolProbe(
				innerDoc
			) | CollapseChainProbe(innerDoc):
				inner.push({ doc: innerDoc, mode: nd.mode });
				return null;
			case ConditionalMarkerZero(innerDoc):
				// ω-cond-indent-policy FixedZero: render-time marker,
				// transparent to the trailing-content scan — descend `inner`.
				inner.push({ doc: innerDoc, mode: nd.mode });
				return null;
			case ConditionalMarkerDecrease(innerDoc):
				// ω-cond-indent-policy AlignedDecrease: render-time marker,
				// transparent to the trailing-content scan — descend `inner`.
				inner.push({ doc: innerDoc, mode: nd.mode });
				return null;
		}
	}

	/**
	 * `true` when `s` contains any character that counts as trailing content
	 * after a close `)` — i.e. a non-whitespace char other than a closing
	 * delimiter / `;` / `,`.
	 */
	private static function textHasTrailingContent(s: String): Bool {
		for (ci in 0...s.length) {
			final c: Int = StringTools.fastCodeAt(s, ci);
			if (c == ' '.code || c == '\t'.code) continue;
			if (c == ')'.code || c == ']'.code || c == '}'.code || c == ';'.code || c == ','.code) continue;
			return true;
		}
		return false;
	}

	/**
	 * One step of `flatTokenWidthFirstLine`'s walk. Pushes structural children
	 * onto `stack`. Returns the flat width contributed by `node` and whether
	 * the first line is terminated (a hardline was reached).
	 */
	private static function flatFirstLineStep(node: Doc, stack: Array<Doc>): { add: Int, aborted: Bool } {
		switch (node) {
			case Empty | BodyGroup(_):
				// Empty contributes nothing; BodyGroup is deferred — it decides
				// its own flat/break independently.
				return { add: 0, aborted: false };
			case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
				return { add: 0, aborted: true };
			case Text(s):
				return { add: s.length, aborted: false };
			case OptSpace(s):
				return { add: s.length, aborted: false };
			case OptSpaceSkipAfterHardline:
				return { add: 1, aborted: false };
			case Line(flat):
				if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) return { add: 0, aborted: true };
				return { add: flat.length, aborted: false };
			case Concat(items):
				var i: Int = items.length;
				while (--i >= 0) stack.push(items[i]);
				return { add: 0, aborted: false };
			case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
				var k: Int = items.length;
				while (k > 0) {
					k--;
					stack.push(items[k]);
					if (k > 0) stack.push(sep);
				}
				return { add: 0, aborted: false };
			case Nest(_, inner) | Group(inner) | GroupWithRestProbe(inner) | IfBreak(_, inner) | IfWidthExceeds(_, _, inner) | IfFirstLineExceeds(
				_, _, inner
			) | IfLineExceeds(_, _, inner) | IfFullLineExceeds(_, _, inner) | IfNaturalFirstLineExceeds(_, _, inner) | IfNaturalFirstLineFitsOpenDelim(
				_, _, inner
			) | IfArrowContinuationFits(_, _, _, _, inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(inner) | CollapseProbe(
				inner
			) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(
				inner
			):
				// Single-child transparent descend: structural wrappers (Nest /
				// Group), the flat side of every render-time `If*` probe, the
				// force-flat markers, and the cond-indent markers all contribute
				// no width of their own to the static first-line walk — descend
				// into the one inner doc.
				stack.push(inner);
				return { add: 0, aborted: false };
		}
	}

	/**
	 * One step of `fitsFlat`'s flat-width measurement. Pushes structural
	 * children (as `MFlat` frames) onto `local`. Returns the budget to spend
	 * for `f.doc` and whether the frame forces a non-flat verdict (a hardline,
	 * which can never flatten).
	 */
	private static function fitsFlatStep(f: Frame, local: Array<Frame>): { spend: Int, broke: Bool } {
		switch (f.doc) {
			case Empty:
				// nothing
				return { spend: 0, broke: false };
			case BodyGroup(_):
				// Defer nested BodyGroups out of the parent's flat
				// measurement: a child BodyGroup decides its own
				// flat/break independently when the renderer reaches
				// it, so its content must not contribute to the parent
				// Group's fit budget. This is what lets
				// `bodyPolicyWrap`'s chained FitLines (e.g.
				// `forBody=fitLine + ifBody=fitLine`) keep the outer
				// body inline while the inner body breaks — and lets
				// `triviaBlockStarExpr`'s BG-wrapped block bodies sit
				// inside a call arg without forcing the call's parens
				// onto separate lines (ω-break-group).
				return { spend: 0, broke: false };
			case Text(s):
				return { spend: s.length, broke: false };
			case OptSpace(s):
				// In flat measurement, OptSpace contributes its length —
				// flat layout always flushes the lead's optional trailing
				// space (the suppression only happens at render time on
				// break-mode `Line`).
				return { spend: s.length, broke: false };
			case OptSpaceSkipAfterHardline:
				// In flat measurement, treat as a single-byte space —
				// the runtime drop only fires when `lastEmit==Hardline`,
				// which by definition cannot happen inside a `fitsFlat`
				// probe (the probe walks pure flat shape).
				return { spend: 1, broke: false };
			case Line(flat):
				// A hard line (flat starts with "\n") forces the
				// measurement to refuse flatten regardless of remaining
				// budget — short hardline-bearing content (a switch
				// with one case body) would otherwise pass the budget
				// check by length alone and the parent Group would
				// commit to MFlat, causing the renderer to emit
				// hardlines without any indent. ω-break-group.
				if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) return { spend: 0, broke: true };
				return { spend: flat.length, broke: false };
			case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
				// All three opt-hardline variants are hardlines by intent
				// and can never flatten. Mirror the `Line('\n')`
				// budget=-1 path: any enclosing Group containing
				// one must commit to MBreak.
				return { spend: 0, broke: true };
			case Nest(n, inner):
				local.push(new Frame(f.indent + n, MFlat, inner));
				return { spend: 0, broke: false };
			case Concat(items):
				var j: Int = items.length;
				while (--j >= 0) local.push(new Frame(f.indent, MFlat, items[j]));
				return { spend: 0, broke: false };
			case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
				// Flat measurement of Fill: items joined by sep flat.
				// `tailReserve` is a render-time per-item-fit knob, NOT
				// a flat-width adjustment — irrelevant when the enclosing
				// Group asks "does the whole Fill fit on one line".
				// FillWithRestProbe shares semantic at static measurement —
				// rest-probe is a render-time decision, identical to plain
				// Fill in `fitsFlat`.
				var k: Int = items.length;
				while (k > 0) {
					k--;
					local.push(new Frame(f.indent, MFlat, items[k]));
					if (k > 0) local.push(new Frame(f.indent, MFlat, sep));
				}
				return { spend: 0, broke: false };
			case Group(inner) | GroupWithRestProbe(inner) | IfBreak(_, inner) | IfWidthExceeds(_, _, inner) | IfFirstLineExceeds(
				_, _, inner
			) | IfLineExceeds(_, _, inner) | IfFullLineExceeds(_, _, inner) | IfNaturalFirstLineExceeds(_, _, inner) | IfNaturalFirstLineFitsOpenDelim(
				_, _, inner
			) | IfArrowContinuationFits(_, _, _, _, inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(inner) | CollapseProbe(
				inner
			) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(
				inner
			):
				// Single-child transparent descend at the same indent in MFlat.
				// A `Group`'s nested flat content; the flat side of every
				// render-time `If*` probe (the column/first-line/rest-of-stack/
				// natural-first-line decisions are all render-time, transparent
				// to an enclosing Group's static flat-width measurement); the
				// ω-force-flat-engine markers (render-time state, slice B's
				// dispatch lives in `render`, not here); and the cond-indent
				// markers (col-0 / -1 re-indent is render-only and never
				// narrows the fit budget) — all contribute their inner doc flat.
				local.push(new Frame(f.indent, MFlat, inner));
				return { spend: 0, broke: false };
		}
	}

	/**
	 * One step of the rest-of-stack flat-width walk shared by
	 * `flatTokenWidthOfRestStack` (`bgDescend == false`) and
	 * `flatTokenWidthOfRestStackFull` (`bgDescend == true`). Pushes structural
	 * children onto `inner`. Returns the flat width contributed by `node.doc`
	 * and whether a hardline / broken `Line` boundary terminates the walk.
	 *
	 * The sole difference between the two sister walkers is the `BodyGroup`
	 * arm: the `Full` variant descends inline body content (`bgDescend`), the
	 * plain variant defers it (BG decides its own layout, Departure 2).
	 */
	private static function restNodeWidth(
		node: { doc: Doc, mode: Mode }, inner: Array<{ doc: Doc, mode: Mode }>, bgDescend: Bool
	): { add: Int, aborted: Bool } {
		switch node.doc {
			case Empty:
				return { add: 0, aborted: false };
			case Text(s):
				return { add: s.length, aborted: false };
			case OptSpace(s):
				return { add: s.length, aborted: false };
			case OptSpaceSkipAfterHardline:
				return { add: 1, aborted: false };
			case Line(flat):
				if (node.mode == MBreak) return { add: 0, aborted: true };
				if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) return { add: 0, aborted: true };
				return { add: flat.length, aborted: false };
			case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
				return { add: 0, aborted: true };
			case BodyGroup(innerDoc):
				// The sister-walker differentiator: Full descends inline body
				// content; plain defers (BG decides own layout, Departure 2).
				if (bgDescend) inner.push({ doc: innerDoc, mode: MFlat });
				return { add: 0, aborted: false };
			case Concat(items):
				var k: Int = items.length;
				while (--k >= 0) inner.push({ doc: items[k], mode: node.mode });
				return { add: 0, aborted: false };
			case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
				var k: Int = items.length;
				while (k > 0) {
					k--;
					inner.push({ doc: items[k], mode: MFlat });
					if (k > 0) inner.push({ doc: sep, mode: MFlat });
				}
				return { add: 0, aborted: false };
			case Group(innerDoc) | GroupWithRestProbe(innerDoc) | IfBreak(_, innerDoc) | IfWidthExceeds(_, _, innerDoc) | IfFirstLineExceeds(
				_, _, innerDoc
			) | IfLineExceeds(_, _, innerDoc) | IfFullLineExceeds(_, _, innerDoc) | IfNaturalFirstLineExceeds(_, _, innerDoc) | IfNaturalFirstLineFitsOpenDelim(
				_, _, innerDoc
			) | IfArrowContinuationFits(_, _, _, _, innerDoc):
				// Static walk: descend in MFlat. Runtime Group decision is
				// unknowable here; flat-side measurement matches the cascade
				// rule semantic. The natural-first-line / rest-of-stack probes
				// are render-time decisions — this static walk sees only the
				// flat shape. GroupWithRestProbe shares semantic at static walk.
				inner.push({ doc: innerDoc, mode: MFlat });
				return { add: 0, aborted: false };
			case Nest(_, innerDoc) | Flatten(innerDoc) | WrapBoundary(innerDoc) | HardFlatten(innerDoc) | CollapseProbe(innerDoc) | CollapseAddProbe(
				innerDoc
			) | CollapseBoolProbe(innerDoc) | CollapseChainProbe(innerDoc) | ConditionalMarkerZero(innerDoc) | ConditionalMarkerDecrease(
				innerDoc
			):
				// Mode-preserving transparent descend: Nest, the ω-force-flat-
				// engine markers (rest-of-stack probe measures structural
				// width — force-flat markers add none), and the cond-indent
				// markers all descend `inner` keeping the frame's mode.
				inner.push({ doc: innerDoc, mode: node.mode });
				return { add: 0, aborted: false };
		}
	}

	/**
	 * One step of `naturalFirstLineGluable`'s walk. Pushes next natural frames
	 * onto `stack`. Returns the column width contributed by `node.doc`, whether
	 * the first line is terminated, and — when a text run was emitted — the
	 * "ends at an open delimiter" verdict (`delim`, `null` when no text emitted
	 * this step) that drives the leading-break glue decision.
	 */
	private static function naturalGluableStep(
		node: {
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		},
		stack: Array<{
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		}>,
		width: Int, col: Int
	): { add: Int, aborted: Bool, delim: Null<Bool> } {
		switch node.doc {
			case Empty:
				return { add: 0, aborted: false, delim: null };
			case Text(s):
				if (s.length > 0) return { add: s.length, aborted: false, delim: lastCharIsOpenDelim(s) };
				return { add: 0, aborted: false, delim: null };
			case Line(flat):
				if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) return { add: 0, aborted: true, delim: null };
				if (node.mode == MBreak) return { add: 0, aborted: true, delim: null };
				if (flat.length > 0) return { add: flat.length, aborted: false, delim: lastCharIsOpenDelim(flat) };
				return { add: 0, aborted: false, delim: null };
			case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
				return { add: 0, aborted: true, delim: null };
			case OptSpace(s):
				return { add: s.length, aborted: false, delim: lastCharIsOpenDelim(s) };
			case OptSpaceSkipAfterHardline:
				return { add: 1, aborted: false, delim: null };
			case _:
				// Structural / descend arms contribute no width or delim of
				// their own — they only push the next natural frame(s).
				naturalGluableStructural(node, stack, width, col);
				return { add: 0, aborted: false, delim: null };
		}
	}

	/**
	 * The "ends at an open delimiter" verdict for the last non-whitespace char
	 * of `s`: `true` for `(` / `[` / `{` or an arrow `->`, `false` for any
	 * other char, and `null` when `s` has no non-whitespace char (all-space or
	 * empty) — in which case the caller must LEAVE its running glue state
	 * unchanged (mirrors the original `recordText`, whose `break` — and thus
	 * its `lastOpenDelim` write — was never reached for an all-whitespace run).
	 * Drives the leading-break glue state in `naturalFirstLineGluable`.
	 */
	private static function lastCharIsOpenDelim(s: String): Null<Bool> {
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
	 * Push the resolved frame for an `If*Exceeds` probe onto a natural-frame
	 * `stack`. Mirrors render's `If*Exceeds` arm: in a force-flat region the
	 * flat side is kept (MFlat); otherwise `crosses` picks the break or flat
	 * side, and a crossing commits the pushed frame to MBreak. Shared by
	 * `naturalGluableStep` and `naturalWidthStep`.
	 */
	private static function pushNaturalExceeds(
		stack: Array<{
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		}>,
		node: {
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		},
		breakDoc: Doc, flatDoc: Doc, crosses: Bool
	): Void {
		if (node.forceFlat) {
			stack.push({
				doc: flatDoc,
				indent: node.indent,
				mode: MFlat,
				forceFlat: true
			});
		} else {
			stack.push({
				doc: crosses ? breakDoc : flatDoc,
				indent: node.indent,
				mode: crosses ? MBreak : node.mode,
				forceFlat: false
			});
		}
	}

	/**
	 * Push a `Group` / `BodyGroup`'s inner onto a natural-frame `stack`,
	 * resolving its mode by its own fit at the running column — a faithful
	 * mirror of render's `Group`/`BodyGroup` arm (`forceFlat` short-circuits
	 * to flat, else `fitsFlat(width - col, ...)` decides). Shared by
	 * `naturalGluableStep` and `naturalWidthStep`. NOTE: BodyGroup is handled
	 * HERE (same as render), NOT deferred — deferring would under-measure a
	 * RHS whose own body breaks.
	 */
	private static function pushNaturalGroup(
		stack: Array<{
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		}>,
		node: {
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		},
		inner: Doc, width: Int, col: Int
	): Void {
		if (node.forceFlat) {
			stack.push({
				doc: inner,
				indent: node.indent,
				mode: MFlat,
				forceFlat: true
			});
		} else if (fitsFlat(width - col, node.indent, inner)) {
			stack.push({
				doc: inner,
				indent: node.indent,
				mode: MFlat,
				forceFlat: false
			});
		} else {
			stack.push({
				doc: inner,
				indent: node.indent,
				mode: MBreak,
				forceFlat: false
			});
		}
	}

	/**
	 * The structural / descend arms of `naturalGluableStep` — every `node.doc`
	 * that contributes no width or open-delim verdict of its own, only pushing
	 * the next natural frame(s) onto `stack`. Split out of the step so both it
	 * and the leaf-content half stay below the complexity bound.
	 */
	private static function naturalGluableStructural(
		node: {
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		},
		stack: Array<{
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		}>,
		width: Int, col: Int
	): Void {
		switch node.doc {
			case Nest(n, inner):
				final nextIndent: Int = node.mode == MBreak ? node.indent + n : node.indent;
				stack.push({
					doc: inner,
					indent: nextIndent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case Concat(items):
				var i: Int = items.length;
				while (--i >= 0) stack.push({
					doc: items[i],
					indent: node.indent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner):
				pushNaturalGroup(stack, node, inner, width, col);
			case IfBreak(breakDoc, flatDoc):
				final picked: Doc = (node.forceFlat || node.mode == MFlat) ? flatDoc : breakDoc;
				stack.push({
					doc: picked,
					indent: node.indent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case IfWidthExceeds(nn, breakDoc, flatDoc) | IfLineExceeds(nn, breakDoc, flatDoc) | IfFullLineExceeds(nn, breakDoc, flatDoc):
				// No rest-stack lookahead is needed here: the cond's own
				// first line determines glue-vs-open; the trailing ` {`
				// lookahead is already covered by the width arm of the
				// sibling `naturalFirstLineWidth` probe in the render
				// decision. Resolve flat unless forced — these probes never
				// sit at the head of a cond's flatShape spine.
				pushNaturalExceeds(stack, node, breakDoc, flatDoc, col + DocMeasure.flatTokenWidth(flatDoc) >= nn);
			case IfNaturalFirstLineExceeds(nn, breakDoc, flatDoc):
				// Self-class sibling: resolve recursively at the running col
				// over a strictly smaller subtree (mirror the width probe's
				// own arm; bounded by the finite tree).
				pushNaturalExceeds(stack, node, breakDoc, flatDoc, naturalFirstLineWidth(flatDoc, col, node.indent, width) >= nn);
			case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
				// Flat interleave tagged with node.mode (so a broken sep's
				// Line terminates the first line). Mirror `naturalFirstLine
				// Width`'s Fill arm; the canonical consumer does not place a
				// bare Fill as the probed flatDoc head.
				var k: Int = items.length;
				while (k > 0) {
					k--;
					stack.push({
						doc: items[k],
						indent: node.indent,
						mode: node.mode,
						forceFlat: node.forceFlat
					});
					if (k > 0)
						stack.push({
							doc: sep,
							indent: node.indent,
							mode: node.mode,
							forceFlat: node.forceFlat
						});
				}
			case Flatten(inner) | HardFlatten(inner):
				// Enter force-flat region (mirror render's Flatten arm):
				// push inner MFlat + forceFlat=true so every nested Group
				// stays flat until a WrapBoundary resets the flag.
				stack.push({
					doc: inner,
					indent: node.indent,
					mode: MFlat,
					forceFlat: true
				});
			case WrapBoundary(inner):
				// Reset force-flat (mirror render's WrapBoundary arm): mode
				// preserved, forceFlat=false so a nested wrap-cascade's
				// Groups re-evaluate their own fit and may break.
				stack.push({
					doc: inner,
					indent: node.indent,
					mode: node.mode,
					forceFlat: false
				});
			case IfFirstLineExceeds(_, _, inner) | IfNaturalFirstLineFitsOpenDelim(_, _, inner) | IfArrowContinuationFits(_, _, _, _, inner) | CollapseProbe(
				inner
			) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(
				inner
			):
				// Preserve-mode transparent descend to the flat / inner doc:
				// the callarg under-wrap probe (`IfFirstLineExceeds`), the
				// nested cond-paren-glue probes (render-time, seen flat here),
				// the collapse probes, and the cond-indent markers all forward
				// their inner doc keeping the frame's mode + forceFlat.
				stack.push({
					doc: inner,
					indent: node.indent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case Empty | Text(_) | Line(_) | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline | OptSpace(_) | OptSpaceSkipAfterHardline:
				// Leaf-content arms — handled by `naturalGluableStep`; never
				// reached here (this helper is its `case _` delegate).
				throw 'unreachable leaf in naturalGluableStructural';
		}
	}

	/**
	 * Rest-of-stack flat width over a `naturalFirstLineWidth` natural-frame
	 * `stack`: the same-line content the pending work-stack will still emit
	 * AFTER the current `If*Exceeds` node, up to the first hardline. Mirrors
	 * render's `flatTokenWidthOfRestStackFull` (BG-descend) — the difference
	 * being our pending stack IS that lookahead. A chain's `IfFullLineExceeds`
	 * must see the trailing close-delims (`))`, `;`) that ride the same line,
	 * or it under-fires and the chain stays flat when render would break it.
	 */
	private static function naturalRestStackWidth(stack: Array<{
		doc: Doc,
		indent: Int,
		mode: Mode,
		forceFlat: Bool
	}>): Int {
		var total: Int = 0;
		var i: Int = stack.length - 1;
		var aborted: Bool = false;
		while (i >= 0 && !aborted) {
			final f: {
				doc: Doc,
				indent: Int,
				mode: Mode,
				forceFlat: Bool
			} = stack[i];
			i--;
			final inner: Array<{ doc: Doc, mode: Mode }> = [{ doc: f.doc, mode: f.mode }];
			while (inner.length > 0 && !aborted) {
				final nd: { doc: Doc, mode: Mode } = inner.pop();
				final step: { add: Int, aborted: Bool } = restNodeWidth(nd, inner, true);
				total += step.add;
				aborted = step.aborted;
			}
		}
		return total;
	}

	/**
	 * One step of `naturalFirstLineWidth`'s walk. Pushes next natural frames
	 * onto `stack`. Returns the column width contributed by `node.doc` and
	 * whether the first line is terminated. Leaf-content arms are handled here;
	 * structural / descend arms forward to `naturalWidthStructural`.
	 */
	private static function naturalWidthStep(
		node: {
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		},
		stack: Array<{
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		}>,
		width: Int, col: Int
	): { add: Int, aborted: Bool } {
		switch node.doc {
			case Empty:
				return { add: 0, aborted: false };
			case Text(s):
				return { add: s.length, aborted: false };
			case Line(flat):
				if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code)
					// Forced hardline always terminates the first line.
					return { add: 0, aborted: true };
				if (node.mode == MBreak)
					// Soft line inside a BROKEN Group renders as a newline.
					return { add: 0, aborted: true };
				// Soft line inside a FLAT Group renders as its flat string.
				return { add: flat.length, aborted: false };
			case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
				// All three are hardlines by intent (mirror
				// `flatTokenWidthFirstLine`); treat as a first-line
				// terminator (their render-time drops can't be predicted).
				return { add: 0, aborted: true };
			case OptSpace(s):
				return { add: s.length, aborted: false };
			case OptSpaceSkipAfterHardline:
				return { add: 1, aborted: false };
			case _:
				// Structural / descend arms contribute no width of their own —
				// they only push the next natural frame(s).
				naturalWidthStructural(node, stack, width, col);
				return { add: 0, aborted: false };
		}
	}

	/**
	 * The structural / descend arms of `naturalWidthStep` — every `node.doc`
	 * that contributes no width of its own, only pushing the next natural
	 * frame(s) onto `stack`. Split out of the step so both halves stay below
	 * the complexity bound. Differs from `naturalGluableStructural` only in the
	 * rest-of-stack lookahead the `IfLineExceeds` / `IfFullLineExceeds` arms add
	 * to their crossing test.
	 */
	private static function naturalWidthStructural(
		node: {
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		},
		stack: Array<{
			doc: Doc,
			indent: Int,
			mode: Mode,
			forceFlat: Bool
		}>,
		width: Int, col: Int
	): Void {
		switch node.doc {
			case Nest(n, inner):
				// Indent bump observed only on a hardline in MBreak
				// (mirrors render loop Nest arm). Propagate mode + forceFlat.
				final nextIndent: Int = node.mode == MBreak ? node.indent + n : node.indent;
				stack.push({
					doc: inner,
					indent: nextIndent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case Concat(items):
				var i: Int = items.length;
				while (--i >= 0) stack.push({
					doc: items[i],
					indent: node.indent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case Group(inner) | GroupWithRestProbe(inner) | BodyGroup(inner):
				// THE natural decision: resolve THIS Group by its own fit at the
				// running column (`pushNaturalGroup`). BodyGroup is handled HERE
				// (same as render), NOT deferred — deferring it would under-
				// measure a RHS whose own body breaks, hiding the overflow from
				// the parent =-probe. (GroupWithRestProbe's rest-stack bias needs
				// the live render stack the probe lacks; treat as plain Group.)
				pushNaturalGroup(stack, node, inner, width, col);
			case IfBreak(breakDoc, flatDoc):
				// Pick by mode (mirrors render IfBreak): forceFlat or MFlat
				// -> flat side; MBreak -> break side. Propagate forceFlat.
				final picked: Doc = (node.forceFlat || node.mode == MFlat) ? flatDoc : breakDoc;
				stack.push({
					doc: picked,
					indent: node.indent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case IfWidthExceeds(nn, breakDoc, flatDoc):
				pushNaturalExceeds(stack, node, breakDoc, flatDoc, col + DocMeasure.flatTokenWidth(flatDoc) >= nn);
			case IfLineExceeds(nn, breakDoc, flatDoc) | IfFullLineExceeds(nn, breakDoc, flatDoc):
				// Own flat width PLUS the rest-of-stack lookahead (the same-line
				// content the pending work-stack will still emit). The lookahead
				// lets a chain probe see trailing close-delims that ride the same
				// line and break. APPROXIMATION: naturalRestStackWidth BG-DESCENDS
				// (mirrors render's flatTokenWidthOfRestStackFull), whereas
				// render's own IfLineExceeds uses the BG-DEFER variant. The
				// canonical assignment-RHS consumer never sits an IfLineExceeds
				// head with a trailing same-line body BodyGroup, so descend-vs-
				// defer is inert here — one rest walker suffices (YAGNI).
				pushNaturalExceeds(
					stack, node, breakDoc, flatDoc, col + DocMeasure.flatTokenWidth(flatDoc) + naturalRestStackWidth(stack) >= nn
				);
			case IfNaturalFirstLineExceeds(nn, breakDoc, flatDoc):
				// Self-reference: resolve recursively at the running col
				// over a strictly smaller subtree (bounded by finite tree).
				pushNaturalExceeds(stack, node, breakDoc, flatDoc, naturalFirstLineWidth(flatDoc, col, node.indent, width) >= nn);
			case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
				// Flat interleave tagged with node.mode (so a broken sep's
				// Line terminates the first line). Slight over-measure when
				// items pack onto multiple lines; the canonical consumer
				// (assignment RHS) does not place a bare Fill as the probed
				// flatDoc head. See Doc stanza.
				var k: Int = items.length;
				while (k > 0) {
					k--;
					stack.push({
						doc: items[k],
						indent: node.indent,
						mode: node.mode,
						forceFlat: node.forceFlat
					});
					if (k > 0)
						stack.push({
							doc: sep,
							indent: node.indent,
							mode: node.mode,
							forceFlat: node.forceFlat
						});
				}
			case Flatten(inner) | HardFlatten(inner):
				// Enter force-flat region (mirror render's Flatten arm):
				// push inner MFlat + forceFlat=true so every nested Group
				// stays flat until a WrapBoundary resets the flag.
				// `HardFlatten` is treated as `Flatten` here (documented
				// increment-2 approximation: this measurer tracks a single
				// `forceFlat` bool, not the WrapBoundary-surviving `hardFlat`
				// state; inert for the `IfNaturalFirstLineExceeds` consumer
				// whose flatDoc never contains HardFlatten).
				stack.push({
					doc: inner,
					indent: node.indent,
					mode: MFlat,
					forceFlat: true
				});
			case WrapBoundary(inner):
				// Reset force-flat (mirror render's WrapBoundary arm): mode
				// preserved, forceFlat=false so a nested wrap-cascade's
				// Groups re-evaluate their own fit and may break.
				stack.push({
					doc: inner,
					indent: node.indent,
					mode: node.mode,
					forceFlat: false
				});
			case IfFirstLineExceeds(_, _, inner) | IfNaturalFirstLineFitsOpenDelim(_, _, inner) | IfArrowContinuationFits(_, _, _, _, inner) | CollapseProbe(
				inner
			) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(
				inner
			):
				// Preserve-mode transparent descend to the flat / inner doc:
				// the callarg under-wrap probe (`IfFirstLineExceeds` — the
				// NoWrap-pinned call paren is measured kept-flat for the parent
				// =-break decision), the nested cond-paren-glue probes (render-
				// time, seen flat here), the collapse probes, and the cond-
				// indent markers all forward their inner doc keeping the frame's
				// mode + forceFlat. A genuinely WRAPPABLE sub-bracket inside the
				// IfFirstLineExceeds flatDoc still breaks via the Group arm
				// (forceFlat reset behind a WrapBoundary).
				stack.push({
					doc: inner,
					indent: node.indent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case Empty | Text(_) | Line(_) | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline | OptSpace(_) | OptSpaceSkipAfterHardline:
				// Leaf-content arms — handled by `naturalWidthStep`; never
				// reached here (this helper is its `case _` delegate).
				throw 'unreachable leaf in naturalWidthStructural';
		}
	}

	/**
	 * Resolve and push the chosen branch of an `If*Exceeds` family node onto
	 * the render `stack`. Pure: reads `col`/`width`/`f`, pushes onto the
	 * passed `stack` (and records measure-only decisions into `decisions`),
	 * mutates no scalar layout accumulator. Extracted verbatim from
	 * `render`'s dispatch switch — see each arm comment for the per-ctor
	 * semantic.
	 */
	private static function pushExceedsBranch(
		f: Frame, stack: Array<Frame>, col: Int, width: Int, decisions: Null<Array<{ node: Doc, crosses: Bool, ?indent: Int }>>
	): Void {
		switch (f.doc) {
			case IfBreak(_, _) | IfWidthExceeds(_, _, _) | IfFirstLineExceeds(_, _, _) | IfLineExceeds(_, _, _):
				// Flat-width family — flat-token measurer feeds a `crosses`
				// test, no measure-only capture. Delegated to the static
				// `pushFlatWidthBranch`.
				pushFlatWidthBranch(f, stack, col, width);
			case IfFullLineExceeds(n, breakDoc, flatDoc):
				// Sibling of `IfLineExceeds` with asymmetric BG
				// semantic: the primitive's own subtree uses the
				// regular `flatTokenWidth` (defers BG — so a lambda
				// body BG inside one of `flatDoc`'s segments stays
				// deferred and doesn't inflate the chain probe),
				// but the rest-of-stack lookahead descends BG via
				// `flatTokenWidthOfRestStackFull` so a sibling body
				// BG that follows on the same source line (e.g.
				// `for (cond) BODY` with `forBody=fitLine` BG-wrap)
				// is visible to the probe. Closes the chain-emit
				// blindspot at `condition_wrapping_method_chain`
				// while avoiding the chain-of-lambdas over-fire
				// (regression class of the symmetric-descend
				// approach). Slice ω-iffulllineexceeds-primitive.
				//
				// Mode propagation matches `IfLineExceeds`: brk-side
				// forces `MBreak` (slice ω-iflineexceeds-brk-mode
				// sister-arm sweep); flat-side preserves `f.mode`.
				// Kept inline (NOT in a push-family helper) because it
				// alone reads/writes the measure-only `decisions` side list.
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, f.mode, flatDoc, true, f.hardFlat));
					// Measure-only capture: inside a force-flat region the
					// flat branch is always taken (record `false` = no open).
					if (decisions != null)
						decisions.push({ node: f.doc, crosses: false });
				} else {
					final fullLineCrosses: Bool = (col + DocMeasure.flatTokenWidth(flatDoc) + flatTokenWidthOfRestStackFull(stack) >= n);
					// ω-collapse-commit: record the open/glued decision at
					// this node's true render column for the Doc→Doc pass.
					// Keyed by node identity (enum `==` is reference equality
					// on JS — see CollapsePass). `ObjectMap` rejects enum
					// keys (`K:{}` constraint), so a side list is used.
					//
					// For a collapse-candidate paren (`breakDoc` carries a
					// `CollapseProbe`), the recorded `crosses` (= "this paren
					// commits to open") is GATED by operator class:
					//  - opAddSub inner (probe wraps `HardFlatten`) → open
					//    iff `fullLineCrosses` (unconditional once the line
					//    overflows — fork `collapseInnerChainBreaks` owns the
					//    content even past width: the anchor's 117-wide inner
					//    opens at 120 even though it won't fit at the deeper
					//    indent).
					//  - opBool / ternary inner (probe wraps the plain inner)
					//    → open iff `fullLineCrosses` AND the inner rendered
					//    FLAT fits at the paren's continuation indent
					//    (`f.indent + flatWidth(inner) < n`). When the
					//    inner can't be made a single fitting line, opening
					//    the paren does not help (the fork keeps the paren
					//    glued and lets the inner chain break one-per-line at
					//    its own indent — issue_187's nested `((Y)||(Z))`,
					//    ternary_nested). This is the anyparse analogue of the
					//    fork's fit-gated `tryCollapseBreakBefore`.
					// The same operator-class gate drives BOTH the captured
					// decision AND the live render's open/glue: a candidate
					// paren whose opBool/ternary inner cannot be made a
					// fitting flat line must STAY GLUED in the emitted output
					// too (otherwise the final render would open it via the
					// raw `fullLineCrosses`, producing the `(\n inner` shape
					// the fork rejects — issue_187 nested / ternary_nested).
					// For a non-candidate `IfFullLineExceeds` (no
					// `CollapseProbe`) `collapseParenCommitsOpen` returns the
					// raw `fullLineCrosses`, so this is byte-identical to the
					// pre-slice behaviour off the collapse path.
					final commits: Bool = collapseParenCommitsOpen(breakDoc, fullLineCrosses, f.indent, n, stack);
					if (decisions != null) decisions.push({ node: f.doc, crosses: commits });
					final pushMode: Mode = commits ? MBreak : f.mode;
					stack.push(new Frame(f.indent, pushMode, commits ? breakDoc : flatDoc));
				}
			case IfNaturalFirstLineExceeds(_, _, _) | IfNaturalFirstLineFitsOpenDelim(_, _, _) | IfArrowContinuationFits(_, _, _, _, _):
				// Natural-shape family — inner Groups resolve by their own
				// `fitsFlat` (or a precomputed arrow width). Delegated to the
				// static `pushNaturalBranch`.
				pushNaturalBranch(f, stack, col, width);
			case _:
		}
	}

	/**
	 * Resolve and push the structural / descend arms of `render`'s dispatch
	 * switch — every `Doc` ctor that contributes no scalar layout mutation,
	 * only pushing the next frame(s) onto `stack` (reading `col`/`width`/`f`).
	 * Extracted verbatim from `render` — see each arm comment for the per-ctor
	 * semantic. Mutates no scalar accumulator (invariant #1).
	 */
	private static function pushStructural(f: Frame, stack: Array<Frame>, col: Int, width: Int): Void {
		switch (f.doc) {
			case Nest(n, inner):
				// Indent only matters when observed (i.e. on a hardline
				// in MBreak mode). Skip the bump in MFlat — otherwise a
				// nested Group inside a flat outer Group breaks at the
				// wrong indent (outer-flat-Nest + inner-Nest stacks).
				// haxe-formatter's chained-FitLine layout
				// (`for (...) if (...)\n\t\tbody;`) requires inner-only
				// indent; canonical Wadler cumulative nesting gives
				// outer+inner instead.
				final nextIndent: Int = f.mode == MBreak ? f.indent + n : f.indent;
				stack.push(new Frame(nextIndent, f.mode, inner, f.forceFlat, f.hardFlat));
			case Concat(items):
				var i: Int = items.length;
				while (--i >= 0) stack.push(new Frame(f.indent, f.mode, items[i], f.forceFlat, f.hardFlat));
			case Group(inner) | BodyGroup(inner):
				// Force-flat (slice B): skip `fitsFlat` entirely and push
				// the inner as MFlat with `forceFlat=true` propagated.
				// The `Flatten` region committed to flat for the whole
				// subtree at entry — local fit measurement is moot here.
				// `hardFlat` rides along so an inner `WrapBoundary` keeps
				// the force-flat region (HardFlatten semantic).
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, MFlat, inner, true, f.hardFlat));
				} else if (fitsFlat(width - col, f.indent, inner)) {
					stack.push(new Frame(f.indent, MFlat, inner));
				} else {
					stack.push(new Frame(f.indent, MBreak, inner));
				}
			case GroupWithRestProbe(inner):
				// ω-group-rest-probe: Group variant whose fit decision
				// subtracts `flatTokenWidthOfRestStack(stack)` from the
				// budget — same-line content emitted AFTER this Group by
				// parent frames is considered before committing to MFlat.
				// Mirrors fork's `wrapFillLine2AfterLast` `lengthAfter`
				// bias: when significant content trails on the same line
				// (e.g. typedef LHS typeParams followed by ` = RhsType<…>;`
				// on the same line), prefer MBreak over MFlat so the
				// trailing content has room. Sister to `IfLineExceeds`
				// rest-of-stack lookahead — same walker, different
				// consumer (Group-style fit instead of explicit branch).
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, MFlat, inner, true, f.hardFlat));
				} else {
					final restW: Int = flatTokenWidthOfRestStack(stack);
					if (fitsFlat(width - col - restW, f.indent, inner)) {
						stack.push(new Frame(f.indent, MFlat, inner));
					} else {
						stack.push(new Frame(f.indent, MBreak, inner));
					}
				}
			case Flatten(inner):
				// ω-force-flat-engine slice B: enter force-flat region.
				// Push `inner` with `MFlat` mode and `forceFlat=true` so
				// every descendant Group/IfBreak/Fill/etc. follows the
				// flat dispatch path until a `WrapBoundary` resets the
				// flag (or the subtree drains). Nested `Flatten` is a
				// no-op — pushing `forceFlat=true` when already `true`
				// is idempotent. Note: no emitter constructs `Flatten`
				// yet (slice D opt-in); this arm is exercise-tested
				// only after slice C/D land.
				stack.push(new Frame(f.indent, MFlat, inner, true, f.hardFlat));
			case WrapBoundary(inner):
				// ω-force-flat-engine slice B: reset force-flat — UNLESS
				// inside a `HardFlatten` region (`f.hardFlat`). Push
				// `inner` with the enclosing frame's mode preserved and
				// `forceFlat=false` so nested wrap-cascade outputs
				// evaluate their own conditions independently inside a
				// parent's force-flat region. When the enclosing context
				// did NOT have force-flat active, this is a no-op pass-
				// through (same shape as the prior slice-A arm).
				//
				// ω-hardflatten: when `f.hardFlat` is set the enclosing
				// region is a `HardFlatten` — its "the opened paren owns
				// its content, flatten unconditionally" semantic must
				// survive this boundary. Keep `forceFlat=true` and
				// `hardFlat=true` (mode pinned MFlat) so an inner chain's
				// `WrapBoundary(Group(IfBreak))` stays flat rather than
				// re-floating to its own fit (mirror fork's
				// `collapseInnerChainBreaks`).
				if (f.hardFlat) {
					stack.push(new Frame(f.indent, MFlat, inner, true, true));
				} else {
					// Escaping an active force-flat region (`f.forceFlat`
					// set by an enclosing `Flatten`, which pins mode MFlat):
					// restore `MBreak`. Past the boundary the inner content
					// re-decides its own layout — an inner Group re-resolves
					// flat via its own `fitsFlat`, so fitting content does
					// NOT break, but raw unconditional hardlines the inner
					// emits (e.g. an anon-struct TYPE field-list forced one-
					// per-line by its count rule, nested inside the
					// `Array<…>` type-param `Flatten`) now render in break
					// mode — their `Nest` observes the indent bump
					// (`f.indent + n`) instead of being skipped in MFlat, so
					// the field lands at the correct statement-relative
					// indent rather than the unbumped base (write was non-
					// idempotent: a re-write sees genuinely multiline source
					// and resolves MBreak, indenting correctly). Mirrors the
					// brk-side `MBreak` force the `If*Exceeds` arms already
					// apply for this "forced hardline under an enclosing
					// MFlat from a `Flatten`/`WrapBoundary`" case. When
					// `f.forceFlat` was already false (no enclosing force-
					// flat — the no-op pass-through), preserve `f.mode`.
					final boundaryMode: Mode = f.forceFlat ? MBreak : f.mode;
					stack.push(new Frame(f.indent, boundaryMode, inner, false, false));
				}
			case HardFlatten(inner):
				// ω-hardflatten: enter a force-flat region whose
				// `forceFlat` survives every inner `WrapBoundary`. Push
				// `inner` MFlat with `forceFlat=true` AND `hardFlat=true`
				// so the `WrapBoundary` arm above keeps the region instead
				// of resetting. This is the anyparse analogue of fork's
				// `collapseInnerChainBreaks` (the unconditional inner
				// opAddSub-chain flatten once an expression paren opens).
				stack.push(new Frame(f.indent, MFlat, inner, true, true));
			case CollapseProbe(inner):
				// ω-collapse-probe (increment-2): pure render pass-through.
				// Marks an expression-paren collapse-candidate open branch
				// for `CollapsePass` WITHOUT altering layout — `inner` is
				// pushed with the enclosing frame's mode and flags
				// unchanged, so a marked opBool/ternary inner keeps its own
				// wrap cascade (no force-flat) while a marked opAddSub inner
				// carries its `HardFlatten` underneath. The marker exists
				// solely so `CollapsePass.isCandidate` can recognise the
				// paren and commit the enclosing chain to glued (mirror
				// fork `collapseChainBreaksAfter`) regardless of operator
				// class. Transparent to every Doc walker.
				stack.push(new Frame(f.indent, f.mode, inner, f.forceFlat, f.hardFlat));
			case _:
		}
	}

	/**
	 * Resolve and push a `Fill` family node (`Fill` / `FillWithRestProbe` /
	 * `FillBreakAfterWrap`) onto `stack`. Reads `f` and the current physical
	 * `lineCount` (for the break-after-wrap snapshot); writes only `stack`.
	 * Extracted verbatim from `render`'s dispatch switch — mutates no scalar
	 * accumulator (invariant #1).
	 */
	private static function pushFill(f: Frame, stack: Array<Frame>, lineCount: Int): Void {
		switch (f.doc) {
			case Fill(items, sep, tailReserveOpt) | FillWithRestProbe(items, sep, tailReserveOpt) | FillBreakAfterWrap(
				items, sep, tailReserveOpt
			):
				// Shared arm: identical entry shape for all three ctors. The
				// rest-probe semantic lives in FillCont resumption (see
				// top of dispatch loop) — we just tag the FillCont frame
				// with the originating ctor's `restProbe` flag. The
				// force-flat / all-flat branches don't care which ctor
				// produced them — items collapse to a flat sep-joined
				// emit either way.
				final restProbe: Bool = switch f.doc {
					case FillWithRestProbe(_, _, _): true;
					case _: false;
				};
				if (items.length == 0) {
					// nothing
				} else if (f.forceFlat || f.mode == MFlat) {
					// All-flat: items joined by sep flat; reverse-push for
					// natural left-to-right pop order. Force-flat (slice B)
					// routes here too — items + sep propagate `forceFlat`
					// so nested wrap markers inside an item stay collapsed.
					var k: Int = items.length;
					while (k > 0) {
						k--;
						stack.push(new Frame(f.indent, MFlat, items[k], f.forceFlat, f.hardFlat));
						if (k > 0)
							stack.push(new Frame(f.indent, MFlat, sep, f.forceFlat, f.hardFlat));
					}
				} else {
					// Per-item fill: push items[0] first, then a FillCont
					// that resumes for items[1..] once item[0]'s frames
					// have drained and `col` reflects the post-item[0]
					// pen position. `tailReserve` (cols of post-Fill
					// same-line content; default 0) rides the FillCont
					// frame and tightens the per-item-fit budget on
					// each subsequent probe — see Fill case at the top
					// of the dispatch loop.
					final tailReserve: Int = tailReserveOpt ?? 0;
					// ω-fill-break-after-wrap: opt-in via the
					// `FillBreakAfterWrap` ctor only. When set, snapshot the
					// current physical-line count as the line where items[0]
					// starts; the continuation frame compares it on resume to
					// detect a self-wrapped item[0] and force the follower to
					// break. Plain `Fill` / `FillWithRestProbe` pass `-1`
					// (disabled) so every existing call-site stays byte-
					// identical. Disabled for force-flat (no breaks possible).
					final breakAfterWrap: Bool = switch f.doc {
						case FillBreakAfterWrap(_, _, _): true;
						case _: false;
					};
					if (items.length > 1)
						stack.push(Frame.fillCont(
							f.indent, items, 1, sep, tailReserve, f.forceFlat, restProbe, f.hardFlat,
							(breakAfterWrap && !f.forceFlat) ? lineCount : -1
						));
					stack.push(new Frame(f.indent, MBreak, items[0], f.forceFlat, f.hardFlat));
				}
			case _:
		}
	}

	/**
	 * Resolve and push a collapse-probe marker (`CollapseAddProbe` /
	 * `CollapseBoolProbe` / `CollapseChainProbe`) onto `stack`. Pure render
	 * pass-through: pushes `inner` with the frame's mode/flags unchanged and,
	 * in the measure-only pass (`decisions != null`), records the break-mode
	 * decision keyed by node identity. Reads `f`/`col`/`decisions`; writes
	 * `decisions`/`stack`. Extracted verbatim from `render` — mutates no
	 * scalar accumulator (invariant #1).
	 */
	private static function pushCollapseProbe(
		f: Frame, stack: Array<Frame>, col: Int, decisions: Null<Array<{ node: Doc, crosses: Bool, ?indent: Int }>>
	): Void {
		switch (f.doc) {
			case CollapseAddProbe(inner):
				// ω-unwrap-add-ops (inverse CollapsePass): an inner opAddSub
				// chain's BROKEN shape, reached ONLY when that chain's own
				// `IfBreak` picked `brk` — so arriving here means the inner
				// add-chain broke. Pure render pass-through (no layout effect),
				// EXACTLY like `CollapseProbe`. In the measure-only pass
				// (`decisions != null`) record the break-mode fact keyed by node
				// identity: `crosses = f.mode == MBreak` ("inner add-chain broke
				// in a break context"). `CollapsePass` reads this PLUS the
				// enclosing-chain-broke fact and rewrites this marker to
				// `HardFlatten(inner)` only inside a broken outer chain;
				// otherwise it unwraps to bare `inner` (byte-inert). On the
				// real emit pass (`decisions == null`) this never collapses on
				// its own — the marker is always already rewritten away by
				// `CollapsePass.run` before render, so reaching it here in the
				// emit pass is a defensive pass-through.
				//
				// ω-opadd-head-break-remeasure: also record `f.indent` — the
				// COLUMN the add-tail renders at (the chain's continuation
				// indent). `CollapsePass` uses it for an O(1) order-dependent
				// re-measure: keep the tail glued-flat on the continuation iff
				// it fits at this captured indent (mirror the forward
				// `collapseParenCommitsOpen` fit gate). Optional field — the
				// forward `IfFullLineExceeds` push sites leave it null.
				if (decisions != null) decisions.push({ node: f.doc, crosses: f.mode == MBreak, indent: f.indent });
				stack.push(new Frame(f.indent, f.mode, inner, f.forceFlat, f.hardFlat));
			case CollapseBoolProbe(inner):
				// ω-opbool-reeval-after-callparam (CollapsePass increment 2): an
				// opBool chain's operator-TRAILING FillLine shape emitted inside a
				// cond-wrap context. Pure render pass-through (no layout effect),
				// EXACTLY like `CollapseAddProbe`. In the measure-only pass
				// (`decisions != null`) record the break-mode fact (`crosses =
				// f.mode == MBreak` — the chain wrapped) AND the ACTUAL VISUAL
				// COLUMN the chain starts at (`indent = col`, NOT `f.indent` —
				// the fork's `calcLineLength` call-overflow test needs the real
				// column where the first operand begins, e.g. after `if (`).
				// `CollapsePass` reads the decision, walks the trailing FillLine's
				// operands, and flips the chain to operator-LEADING only when a
				// contained call operand overflows at its flat position (mirror
				// fork `reEvaluateOpBoolAfterCallParam`). On the real emit pass
				// (`decisions == null`) the marker is always already rewritten away
				// by `CollapsePass.run` before render — reaching it here is a
				// defensive pass-through.
				if (decisions != null) decisions.push({ node: f.doc, crosses: f.mode == MBreak, indent: col });
				stack.push(new Frame(f.indent, f.mode, inner, f.forceFlat, f.hardFlat));
			case CollapseChainProbe(inner):
				// ω-methodchain-reeval-after-callparam (CollapsePass increment 3,
				// subroot-E): a method-chain `IfFullLineExceeds(w, dotBreak, glued)`
				// tagged for the re-glue re-measure. Pure render pass-through (no
				// layout effect), EXACTLY like `CollapseBoolProbe`. In the
				// measure-only pass (`decisions != null`) record the ACTUAL VISUAL
				// COLUMN the chain receiver starts at (`indent = col`, NOT `f.indent`
				// — the glued-first-line fit test needs the real column the chain is
				// measured against). `CollapsePass.rewriteChainProbe` reads that
				// column and strips the chain dot-break (re-glues) when the full
				// glued flat overflows but the glued first line (last call's args
				// broken) fits at `col` — mirror fork
				// `reEvaluateMethodChainAfterCallParam`.
				if (decisions != null) decisions.push({ node: f.doc, crosses: f.mode == MBreak, indent: col });
				stack.push(new Frame(f.indent, f.mode, inner, f.forceFlat, f.hardFlat));
			case _:
		}
	}

	/**
	 * True when `s` ends with an open delimiter (`(`/`[`/`{`) — drives the
	 * `OpenDelim` `lastEmit` classification.
	 */
	private static inline function endsWithOpenDelim(s: String): Bool {
		if (s.length == 0) return false;
		final c: Int = StringTools.fastCodeAt(s, s.length - 1);
		return c == '('.code || c == '['.code || c == '{'.code;
	}

	/**
	 * Classify the `lastEmit` state produced by emitting text `s`.
	 */
	private static inline function lastEmitFromText(s: String): LastEmit {
		return endsWithOpenDelim(s) ? OpenDelim : Other;
	}

	/**
	 * Flush a pending `OptSpace` into `ctx.buf` at the current pen, first
	 * flushing any pending indent. A no-op when nothing is pending.
	 */
	private static function flushOptSpace(ctx: RenderCtx): Void {
		if (ctx.pendingOptSpace != null) {
			if (ctx.pendingIndent >= 0) {
				writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
				ctx.pendingIndent = -1;
			}
			ctx.buf.add(ctx.pendingOptSpace);
			ctx.col += ctx.pendingOptSpace.length;
			ctx.pendingOptSpace = null;
			ctx.lastEmit = Other;
		}
	}

	/**
	 * Flush a pending `OptHardlineSkipBeforeHardline` slot: emit `\n+indent`
	 * like a regular break-mode `Line` and drop the pending OptSpace (mirrors
	 * the break-mode-Line semantic — the optional trailing space disappears
	 * before a newline). Called at the top of every content-bearing case so
	 * the deferred hardline lands before its follower. A no-op when no slot
	 * pending. Distinct from the `drop` path (no flush, just clear) taken by
	 * incoming hardline-like emits.
	 */
	private static function flushPendingHardline(ctx: RenderCtx): Void {
		if (ctx.pendingHardline >= 0) {
			ctx.pendingOptSpace = null;
			if (ctx.trailingWhitespace && ctx.pendingIndent >= 0) {
				writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
			}
			ctx.buf.add(ctx.lineEnd);
			ctx.lineCount++;
			ctx.pendingIndent = ctx.pendingHardline;
			ctx.col = ctx.pendingHardline;
			ctx.lastEmit = Hardline;
			ctx.pendingHardline = -1;
		}
	}

	/**
	 * Emit a `Text(s)` node into `ctx` at the current pen — applying the
	 * `ConditionalMarkerZero` / `ConditionalMarkerDecrease` fresh-line indent
	 * policies, flushing pending hardline / opt-space / indent, then the text.
	 * Mutates `ctx` (invariant #1: render-local carrier, no static state).
	 */
	private static function emitText(ctx: RenderCtx, s: String): Void {
		if (s.length > 0) {
			// ω-cond-indent-policy FixedZero: inside a
			// `ConditionalMarkerZero` scope, a fresh-line token that
			// starts with `#` is a preprocessor marker
			// (`#if`/`#elseif`/`#else`/`#end`) — flush it at column 0
			// regardless of the frame indent. Body lines (any other
			// first byte) keep their pending frame indent.
			final freshLine: Bool = ctx.lastEmit == Hardline && ctx.pendingOptSpace == null && ctx.pendingHardline < 0;
			if (ctx.markerZeroDepth > 0 && freshLine && ctx.pendingIndent > 0 && StringTools.fastCodeAt(s, 0) == '#'.code) {
				ctx.pendingIndent = 0;
			}
			// ω-cond-indent-policy AlignedDecrease: inside a
			// `ConditionalMarkerDecrease` scope, EVERY fresh-line token —
			// both `#`-markers and guarded body — is re-indented one
			// indent level shallower (clamped at column 0), shifting the
			// whole increase-style layout `-1` uniformly. Applied once
			// per physical line (gated on the fresh-line flag), so a
			// nested conditional's marker/body lines each get the single
			// uniform shift rather than per-depth.
			if (ctx.markerDecreaseDepth > 0 && freshLine && ctx.pendingIndent > 0) {
				final shifted: Int = ctx.pendingIndent - ctx.markerDecreaseUnit;
				ctx.pendingIndent = shifted > 0 ? shifted : 0;
			}
			flushPendingHardline(ctx);
			flushOptSpace(ctx);
			if (ctx.pendingIndent >= 0) {
				writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
				ctx.pendingIndent = -1;
			}
			ctx.buf.add(s);
			ctx.col += s.length;
			ctx.lastEmit = lastEmitFromText(s);
		}
	}

	/**
	 * Emit a `Line(flat)` node into `ctx`. In flat mode (force-flat or
	 * `MFlat`) the line collapses to its `flat` replacement; in break mode it
	 * becomes a real `\n+indent`, dropping any pending OptSpace and forward
	 * hardline. Mutates `ctx`.
	 */
	private static function emitLine(ctx: RenderCtx, f: Frame, flat: String): Void {
		if (f.forceFlat || f.mode == MFlat) {
			flushPendingHardline(ctx);
			flushOptSpace(ctx);
			if (flat.length > 0 && ctx.pendingIndent >= 0) {
				writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
				ctx.pendingIndent = -1;
			}
			ctx.buf.add(flat);
			ctx.col += flat.length;
			if (flat.length > 0) {
				ctx.lastEmit = lastEmitFromText(flat);
			}
		} else {
			// Break-mode hardline: drop pending OptSpace so the
			// lead's optional trailing space disappears before
			// the newline (no `var x = \n{...}` artifact). Also
			// drop any pending `OptHardlineSkipBeforeHardline`
			// (collision: the deferred hardline's reason for
			// existing — "fire unless next is hardline" — fails
			// here because we ARE that hardline).
			ctx.pendingOptSpace = null;
			if (ctx.pendingHardline >= 0) ctx.pendingHardline = -1;
			if (ctx.trailingWhitespace && ctx.pendingIndent >= 0) {
				writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
			}
			ctx.buf.add(ctx.lineEnd);
			ctx.lineCount++;
			ctx.pendingIndent = f.indent;
			ctx.col = f.indent;
			ctx.lastEmit = Hardline;
		}
	}

	/**
	 * Emit the break-mode optional-hardline ctors `OptHardline` /
	 * `OptHardlineSkipAtOpenDelim` into `ctx` — collision-dropping against a
	 * prior hardline (or, for the open-delim variant, a prior open delim) and
	 * collapsing entirely inside a force-flat region. Mutates `ctx`.
	 */
	private static function emitOptHardline(ctx: RenderCtx, f: Frame): Void {
		switch (f.doc) {
			case OptHardline:
				// Optional break-mode hardline: drop if the previous
				// emit was already a `\n` (collision with sibling
				// hardline at the same insertion point), otherwise
				// emit `\n` + indent like a regular break-mode `Line`.
				// Both branches clear `pendingOptSpace` to mirror
				// real-hardline semantics. Even when dropped, update
				// `pendingIndent` to this node's own indent — the
				// dropping emitter is the "inner" one and its indent
				// is more specific (e.g. objectLit's leftCurly Next
				// inside a wrap-engine-driven multi-arg list).
				//
				// Drop any pending `OptHardlineSkipBeforeHardline`
				// (collision: incoming hardline-like emit clears the
				// deferred forward-looking hardline without write).
				//
				// Force-flat (slice B): inside a `Flatten(...)` region,
				// every optional hardline is collapsed — `pendingOptSpace`
				// is cleared (mirror real-hardline) but no `\n` is
				// emitted and `pendingIndent`/`col`/`lastEmit` stay put.
				ctx.pendingOptSpace = null;
				if (ctx.pendingHardline >= 0) ctx.pendingHardline = -1;
				if (f.forceFlat) {
					// drop entirely
				} else if (ctx.lastEmit == Hardline) {
					ctx.pendingIndent = f.indent;
					ctx.col = f.indent;
				} else {
					if (ctx.trailingWhitespace && ctx.pendingIndent >= 0) {
						writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
					}
					ctx.buf.add(ctx.lineEnd);
					ctx.lineCount++;
					ctx.pendingIndent = f.indent;
					ctx.col = f.indent;
					ctx.lastEmit = Hardline;
				}
			case OptHardlineSkipAtOpenDelim:
				// Open-delim-aware leading hardline. Three branches:
				//  1. Last emit was an open delim (`(`/`[`/`{`):
				//     drop the `\n+indent` so items[0] glues to the
				//     open delim. Leave `col` and `pendingIndent`
				//     untouched — the open delim's text already set
				//     col, and the next continuation `\n` (later
				//     break-mode `Line` for items[1]) will set its
				//     own pendingIndent at frame time.
				//     `lastEmit` stays `OpenDelim` so a redundant
				//     follow-up of the same ctor (defensive case)
				//     keeps dropping.
				//  2. Last emit was a hardline: mirror `OptHardline`'s
				//     collision drop (update pendingIndent + col to
				//     the more-specific inner indent).
				//  3. Otherwise: emit `\n+indent` like a regular
				//     break-mode `Line`. Used by chain shapes for
				//     the leading `\n` before items[0] in
				//     outer-context cases (`dirty = chain`).
				//
				// Drop any pending `OptHardlineSkipBeforeHardline`
				// (collision: incoming hardline-like emit clears the
				// deferred forward-looking hardline without write).
				//
				// Force-flat (slice B): same drop-entirely behaviour as
				// `OptHardline` — `pendingOptSpace` cleared, no `\n`
				// emitted, surrounding state untouched.
				ctx.pendingOptSpace = null;
				if (ctx.pendingHardline >= 0) ctx.pendingHardline = -1;
				if (f.forceFlat) {
					// drop entirely
				} else
					switch ctx.lastEmit {
						case OpenDelim:
							// drop, leave col / pendingIndent / lastEmit as-is
						case Hardline:
							ctx.pendingIndent = f.indent;
							ctx.col = f.indent;
						case Other:
							if (ctx.trailingWhitespace && ctx.pendingIndent >= 0) {
								writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
							}
							ctx.buf.add(ctx.lineEnd);
							ctx.lineCount++;
							ctx.pendingIndent = f.indent;
							ctx.col = f.indent;
							ctx.lastEmit = Hardline;
					}
			case _:
		}
	}

	/**
	 * Emit the deferred / inline optional-space ctors `OptSpace` /
	 * `OptSpaceSkipAfterHardline` / `OptHardlineSkipBeforeHardline` into `ctx`
	 * — all accumulate into the pending-space or pending-hardline slot rather
	 * than writing to `ctx.buf` directly. Mutates `ctx`.
	 */
	private static function emitOptSpaceVariants(ctx: RenderCtx, f: Frame): Void {
		switch (f.doc) {
			case OptSpace(s):
				// Defer; flushed by the next Text or in-flat Line, or
				// dropped by the next break-mode Line. Multiple
				// consecutive OptSpace nodes accumulate.
				if (s.length > 0) {
					ctx.pendingOptSpace = ctx.pendingOptSpace == null ? s : ctx.pendingOptSpace + s;
				}
			case OptSpaceSkipAfterHardline:
				// Inline single space, dropped when the last emitted
				// output ended with a hardline. Mirror of
				// `OptHardlineSkipAtOpenDelim`'s drop-on-state pattern
				// for the trailing-side. Pending `OptSpace` cleared on
				// drop; on emit, the space prints at the current
				// (post-flush) position via the same `pendingOptSpace`
				// channel as `OptSpace(' ')` would, so the flat-mode
				// `Line(' ')` collapse ordering still holds.
				//
				// Force-flat (slice B): inside a `Flatten(...)` region,
				// every preceding `OptHardline*` was dropped, so a
				// `Hardline` lastEmit can only carry over from OUTSIDE
				// the region. Force the space unconditionally — the
				// drop-on-state semantic is moot inside force-flat.
				if (!f.forceFlat && ctx.lastEmit == Hardline) {
					ctx.pendingOptSpace = null;
				} else {
					ctx.pendingOptSpace = ctx.pendingOptSpace == null ? ' ' : ctx.pendingOptSpace + ' ';
				}
			case OptHardlineSkipBeforeHardline:
				// Forward-looking opt-hardline (ω-opthardlineskipbeforehardline):
				// defer the `\n+indent` emit to the first content-bearing
				// follower (Text, in-flat Line, flushed OptSpace*). Sister
				// to `pendingOptSpace`'s deferred pattern but for the
				// trailing-side. An incoming hardline-like emit
				// (`Line` in MBreak, `OptHardline`,
				// `OptHardlineSkipAtOpenDelim`) clears the pending slot
				// without write — collision suppression for the
				// `} // comment\n + parent-Star sep \n` double-hardline
				// case at the `trailFollowExpr` site.
				//
				// Collision among consecutive `OptHardlineSkipBeforeHardline`
				// emits: overwrite the slot with the inner ctor's indent
				// (the latter is more specific). The prior pending's
				// emit was never committed, so no buf state to roll back.
				//
				// `pendingOptSpace` is intentionally NOT cleared on entry:
				// the deferred state hasn't committed to a hardline yet,
				// so the optional space stays alive until the slot
				// flushes (which drops it as break-mode-Line does) or
				// drops (collision — the incoming hardline will clear
				// pendingOptSpace via its own path).
				//
				// Force-flat (slice B): drop entirely. Mirror
				// `OptHardline`'s force-flat arm — inside a `Flatten(...)`
				// region the deferred emit is moot (force-flat collapses
				// every optional hardline).
				if (f.forceFlat) {
					// drop entirely
				} else {
					ctx.pendingHardline = f.indent;
				}
			case _:
		}
	}

	/**
	 * Dispatch a content-emitting leaf `Doc` ctor (`Empty` / `Text` / `Line`
	 * / the `OptSpace*` and `OptHardline*` family) to its emit helper, mutating
	 * `ctx`. The structural / probe / Fill ctors are handled by the push
	 * helpers in `render` and never reach here.
	 */
	private static function emitLeaf(ctx: RenderCtx, f: Frame): Void {
		switch (f.doc) {
			case Empty:
				// nothing
			case Text(s):
				emitText(ctx, s);
			case Line(flat):
				emitLine(ctx, f, flat);
			case OptSpace(_) | OptSpaceSkipAfterHardline | OptHardlineSkipBeforeHardline:
				emitOptSpaceVariants(ctx, f);
			case OptHardline | OptHardlineSkipAtOpenDelim:
				emitOptHardline(ctx, f);
			case _:
		}
	}

	/**
	 * Resume a `Doc.Fill` continuation frame: decide whether `fillRest[idx]`
	 * packs onto the current line or breaks, push the item + separator frames
	 * (and the next continuation frame), reading `ctx.col`/`ctx.lineCount`.
	 * Mutates `stack` only (the per-item fit probe reads `ctx` but does not
	 * mutate its accumulators). Extracted verbatim from `render`'s fillRest
	 * block.
	 */
	private static function resumeFill(ctx: RenderCtx, f: Frame, stack: Array<Frame>, width: Int): Void {
		final fillRest: Null<Array<Doc>> = f.fillRest;
		if (fillRest == null) return;
		final fillSep: Doc = f.fillSep;
		final idx: Int = f.fillIdx;
		final tailReserve: Int = f.fillTailReserve;
		if (idx < fillRest.length) {
			// `tailReserve` cols are reserved for post-Fill same-line
			// content (trailing comma + close delim emitted OUTSIDE
			// the Fill — see `Doc.Fill` doc-comment). Subtracting it
			// from the probe budget makes the LAST packed item leave
			// room for that tail, matching fork's `wrapFillLine2AfterLast`
			// `lineLength + tokenLength >= maxLineLength` accounting
			// where each item carries its trailing comma in
			// `firstLineLength` (slice ω-fill-tail-reserve).
			//
			// `restW` is the additional tail beyond the Fill subtree
			// itself (content trailing the Fill on the same rendered
			// line — e.g. typedef RHS `= RequestMethod<...>;` after a
			// typeParams Fill). Subtracted only when the originating
			// Fill ctor was `FillWithRestProbe` (ω-fill-rest-probe)
			// AND we're probing the LAST item (slice 4): fork's
			// `wrapFillLine2AfterLast` reserves the rest-of-line tail
			// for the AFTER-LAST decision, not every per-item probe.
			// Middle items break only when they themselves overflow;
			// the tail lands on whichever line the last item ends on,
			// so only the last item's probe must account for it.
			// Applying restW per-item is over-pessimistic (regresses
			// e.g. `wrapping/issue_494_type_parameter` — too-early
			// break, only 2 of 6 items packed instead of 5).
			// Default `restW=0` preserves byte-equivalent legacy
			// behavior; sister to `GroupWithRestProbe` at the Group
			// decision layer.
			final restW: Int = (f.fillRestProbe && idx == fillRest.length - 1) ? flatTokenWidthOfRestStack(stack) : 0;
			// ω-fill-break-after-wrap: the just-drained previous item
			// (`fillRest[idx - 1]`) self-wrapped when the render's
			// physical-line count advanced past the snapshot taken when
			// it started. A self-wrapped item overflowed its
			// continuation line, so fork's `lineLength` accounting would
			// push the follower onto its own line regardless of the
			// short post-wrap pen column. Force the separator to break
			// in that case, mirroring `wrapFillLine*2AfterLast`. Gated
			// on `fillLineStart >= 0` so non-opting / force-flat Fills
			// stay byte-identical via the legacy `fits` probe alone.
			final prevWrapped: Bool = f.fillLineStart >= 0 && ctx.lineCount > f.fillLineStart;
			final fits: Bool = !prevWrapped && fitsFlat(width - ctx.col - tailReserve - restW, f.indent, Concat([fillSep, fillRest[idx]]));
			if (idx + 1 < fillRest.length) {
				// Snapshot the line where `fillRest[idx]` STARTS: when the
				// separator breaks (`!fits`) the item begins on the next
				// physical line, so the snapshot must account for that
				// break (which hasn't been emitted yet). Disabled-mode
				// (`fillLineStart < 0`) propagates `-1`.
				final nextStart: Int = f.fillLineStart < 0 ? -1 : (fits ? ctx.lineCount : ctx.lineCount + 1);
				stack.push(Frame.fillCont(
					f.indent, fillRest, idx + 1, fillSep, tailReserve, f.forceFlat, f.fillRestProbe, f.hardFlat, nextStart
				));
			}
			stack.push(new Frame(f.indent, MBreak, fillRest[idx], f.forceFlat, f.hardFlat));
			stack.push(new Frame(f.indent, fits ? MFlat : MBreak, fillSep, f.forceFlat, f.hardFlat));
		}
	}

	/**
	 * Resolve and push the flat-width `If*Exceeds` family (`IfBreak`,
	 * `IfWidthExceeds`, `IfFirstLineExceeds`, `IfLineExceeds`) onto `stack`.
	 * Each shares the `if (forceFlat) flat else { crosses; pushMode; push }`
	 * shape, differing only in the flat-token measurer feeding `crosses`.
	 * Reads `f`/`col`/`width`; writes `stack`. Extracted verbatim from
	 * `pushExceedsBranch` — mutates no scalar accumulator (invariant #1).
	 */
	private static function pushFlatWidthBranch(f: Frame, stack: Array<Frame>, col: Int, width: Int): Void {
		switch (f.doc) {
			case IfBreak(breakDoc, flatDoc):
				// Force-flat (slice B): always pick `flatDoc`, propagate
				// `forceFlat=true` so the chosen branch keeps the region
				// semantic for its own descendants. `hardFlat` rides along.
				final picked: Doc = (f.forceFlat || f.mode == MFlat) ? flatDoc : breakDoc;
				stack.push(new Frame(f.indent, f.mode, picked, f.forceFlat, f.hardFlat));
			case IfWidthExceeds(n, breakDoc, flatDoc):
				// Column-aware probe: rule fires when `col +
				// DocMeasure.flatTokenWidth(flatDoc) >= n` (matches the
				// cascade `lineLength >= n` predicate). The width
				// measurement treats forced hardlines as zero width —
				// the cascade rule asks "does the natural inline width
				// reach n", not "does the flat shape budget-fit". Plain
				// `fitsFlat` would refuse-to-flatten on any hardline
				// inside flatDoc and incorrectly always pick brk;
				// here a chain-emit shape (OPLAfterFirst, contains
				// `Line('\n')` between operands) gets its real
				// flat-token width back, so cascade rule 5
				// (`itemCount>=4`) can win over rule 2
				// (`lineLength>=140`) when the rendered chain at the
				// current column wouldn't actually overflow.
				//
				// When `col >= n` already, the rule fires regardless
				// of width — short-circuited by the `>=` comparison.
				//
				// Brk-side mode: force `MBreak`. The break shape may
				// carry hardlines + Nest that must render as `\n +
				// indent` and drop pendingOptSpace — under an enclosing
				// `MFlat` context (e.g. inside a `Flatten` whose
				// `WrapBoundary` reset `forceFlat` but did not restore
				// mode), the inner `Line('\n')` would otherwise emit a
				// bare `\n` flat string without indent. Sister-arm
				// sweep mirrors the fix at `IfLineExceeds`
				// (slice ω-iflineexceeds-brk-mode).
				//
				// Flat-side mode: preserve `f.mode`. The flat shape is
				// the inline alternative; it respects the enclosing
				// context's mode.
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, f.mode, flatDoc, true, f.hardFlat));
				} else {
					final crosses: Bool = (col + DocMeasure.flatTokenWidth(flatDoc) >= n);
					final pushMode: Mode = crosses ? MBreak : f.mode;
					stack.push(new Frame(f.indent, pushMode, crosses ? breakDoc : flatDoc));
				}
			case IfFirstLineExceeds(n, breakDoc, flatDoc):
				// First-line-aware probe: rule fires when `col +
				// flatTokenWidthFirstLine(flatDoc) >= n`. Differs from
				// `IfWidthExceeds` in measurement semantic — the first-
				// line walk caps at the first forced hardline inside
				// `flatDoc`, so a multi-line subtree whose first line
				// fits stays inline (this branch picks `flatDoc`) even
				// though its total flat width would exceed `n`. Used
				// by `bodyPolicyWrap`'s width-aware path: e.g. `return
				// <multi-line if-expr>` keeps the if-expr's head glued
				// to `return` when the head fits, while subsequent
				// `else` branches keep their own hardlines.
				//
				// Mode propagation matches `IfWidthExceeds` and
				// `IfLineExceeds` — brk-side forces `MBreak` so a break
				// shape carrying hardlines + Nest renders correctly under
				// an enclosing `MFlat` context; flat-side preserves
				// `f.mode` as the inline alternative.
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, f.mode, flatDoc, true, f.hardFlat));
				} else {
					final firstLineCrosses: Bool = (col + flatTokenWidthFirstLine(flatDoc) >= n);
					final pushMode: Mode = firstLineCrosses ? MBreak : f.mode;
					stack.push(new Frame(f.indent, pushMode, firstLineCrosses ? breakDoc : flatDoc));
				}
			case IfLineExceeds(n, breakDoc, flatDoc):
				// Line-length-aware probe: rule fires when `col +
				// DocMeasure.flatTokenWidth(flatDoc) +
				// flatTokenWidthOfRestStack(stack) >= n`. The third term
				// is a lookahead over the rendering stack from this
				// point forward, summed up to the next forced hardline
				// — captures everything that would land on the SAME
				// rendered line if the flat branch fired here. Closes
				// the Wadler-style local-Group blindspot where an inner
				// `Group(IfBreak)` decides flat even though enclosing
				// expression pushes the line past threshold.
				//
				// Brk-side mode: force `MBreak`. The break shape carries
				// hardlines + Nest that must render as `\n + indent` and
				// drop pendingOptSpace — under an enclosing `MFlat`
				// context (e.g. inside a `Flatten` whose `WrapBoundary`
				// reset `forceFlat` but did not restore mode), the inner
				// `Line('\n')` would otherwise emit a bare `\n` flat
				// string without indent. Slice ω-iflineexceeds-brk-mode.
				//
				// Flat-side mode: preserve `f.mode`. The flat shape is
				// the inline alternative; it should respect the enclosing
				// context's mode. Slice ω-iflineexceeds-infra.
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, f.mode, flatDoc, true, f.hardFlat));
				} else {
					final lineCrosses: Bool = (col + DocMeasure.flatTokenWidth(flatDoc) + flatTokenWidthOfRestStack(stack) >= n);
					final pushMode: Mode = lineCrosses ? MBreak : f.mode;
					stack.push(new Frame(f.indent, pushMode, lineCrosses ? breakDoc : flatDoc));
				}
			case _:
		}
	}

	/**
	 * Resolve and push the natural-shape `If*Exceeds` family
	 * (`IfNaturalFirstLineExceeds`, `IfNaturalFirstLineFitsOpenDelim`,
	 * `IfArrowContinuationFits`) onto `stack`. Unlike the flat-width family,
	 * these resolve inner Groups by their own `fitsFlat` (or use a precomputed
	 * arrow width) to decide glue vs break. Reads `f`/`col`/`width`; writes
	 * `stack`. Extracted verbatim from `pushExceedsBranch` — mutates no scalar
	 * accumulator (invariant #1).
	 */
	private static function pushNaturalBranch(f: Frame, stack: Array<Frame>, col: Int, width: Int): Void {
		switch (f.doc) {
			case IfNaturalFirstLineExceeds(n, breakDoc, flatDoc):
				// Natural-shape first-line probe: render `flatDoc`
				// speculatively at the current pen, resolving each inner
				// Group/BodyGroup/GroupWithRestProbe by its OWN `fitsFlat`
				// decision, and measure the first physical line. Crosses
				// iff that line reaches `n`. Unlike `IfFirstLineExceeds`
				// (which walks flatDoc purely flat and over-measures any
				// RHS whose own call-args wrap), this picks `flatDoc` when
				// the RHS's natural first line is short (call-args wrap)
				// and `breakDoc` when the RHS stays wide (NoWrap-pinned).
				// Canonical consumer: assignment break-after-`=`.
				//
				// Mode propagation matches the other If*Exceeds: brk-side
				// forces MBreak so a break shape carrying hardlines + Nest
				// renders correctly under an enclosing MFlat context;
				// flat-side preserves f.mode.
				//
				// `naturalFirstLineWidth` already folds `col` into its
				// accumulator (per-Group `fitsFlat(width - col, ...)` needs
				// the live running column), so the compare RHS is bare `n`
				// — NOT `col + n`, unlike the flat siblings whose measurers
				// return a from-zero width.
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, f.mode, flatDoc, true, f.hardFlat));
				} else {
					final naturalCrosses: Bool = (naturalFirstLineWidth(flatDoc, col, f.indent, width) >= n);
					final pushMode: Mode = naturalCrosses ? MBreak : f.mode;
					stack.push(new Frame(f.indent, pushMode, naturalCrosses ? breakDoc : flatDoc));
				}
			case IfNaturalFirstLineFitsOpenDelim(n, breakDoc, flatDoc):
				// ω-cond-paren-glued (increment-4 a1): render `flatDoc` (the
				// GLUED `(cond)` shape) iff its NATURAL first line both fits
				// within `n` AND ends at an open delimiter (`(`/`[`/`{` or an
				// arrow `->`) — i.e. the inner construct (call / array / arrow
				// lambda) LEADING-broke right after that delimiter so the cond
				// prefix stays on the open line
				// (`if (!list.exists(\n\t…\n))`). Otherwise render `breakDoc`
				// (open the cond paren). The end-on-open-delim test separates
				// a leading-broken inner call (keep glued) from one that
				// fillLine-PACKS its first arg onto the open line, or a bare
				// chain whose own operator breaks (open the paren). Mirrors
				// `IfNaturalFirstLineExceeds`'s mode propagation.
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, f.mode, flatDoc, true, f.hardFlat));
				} else {
					final fits: Bool = naturalFirstLineWidth(flatDoc, col, f.indent, width) < n;
					final gluable: Bool = naturalFirstLineGluable(flatDoc, col, f.indent, width);
					final glue: Bool = fits && gluable;
					final pushMode: Mode = glue ? f.mode : MBreak;
					stack.push(new Frame(f.indent, pushMode, glue ? flatDoc : breakDoc));
				}
			case IfArrowContinuationFits(extraIndent, flatWidth, n, breakDoc, flatDoc):
				// ω-inc5-cont: render `flatDoc` (OPEN-paren shape, arrow on its
				// own continuation line) iff the arrow's flat `(params) -> body`
				// fits at the CONTINUATION indent `f.indent + extraIndent` — NOT
				// the current pen column. The decision is committed here (at the
				// open-paren column) but the relevant width is the body's own
				// continuation line, so the probe re-bases the measure to a fresh
				// line at `f.indent + extraIndent`. `flatWidth` is the arrow
				// item's flat token width, precomputed at lowering (column-
				// independent), so the arm needs no render-time measurer. Mirrors
				// fork `preferLambdaSignatureInlineOverWrap`: keep the signature
				// inline on the continuation when it fits, else pull it up onto
				// the open-paren line and break the body.
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, f.mode, flatDoc, true, f.hardFlat));
				} else {
					final contFits: Bool = (f.indent + extraIndent + flatWidth < n);
					final pushMode: Mode = contFits ? f.mode : MBreak;
					stack.push(new Frame(f.indent, pushMode, contFits ? flatDoc : breakDoc));
				}
			case _:
		}
	}

}
