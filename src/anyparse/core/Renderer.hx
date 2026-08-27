package anyparse.core;

import anyparse.format.IndentChar;

using StringTools;

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
	// The trailing blank run held back from the last non-verbatim `Text`
	// committed on the current line. Already counted in `col` (so no layout
	// decision sees it move); written by the next content append, dropped by
	// the line break that would otherwise strand it. See `flushTrailBlank`.
	var pendingTrailBlank: Null<String>;
	var pendingHardline: Int;
	var lastEmit: LastEmit;
	var lineCount: Int;
	var markerZeroDepth: Int;
	var markerDecreaseDepth: Int;
};

/**
	The three widths `Renderer.embeddedLineWidths` reports for one Doc: the
	first and last physical line of a VERBATIM multi-line token (`first` /
	`last`, both `-1` when the shape does not apply), and `condSpliceFirstLine`
	— the same first-line measurement for a conditional-compilation splice
	operand whose break is a real hardline rather than a `Text`-embedded
	newline. Named because three signatures carry it; see the function's own
	doc for what each `-1` means and which caller reads which field.
**/
private typedef EmbeddedLineWidths = {
	final first: Int;
	final last: Int;
	final condSpliceFirstLine: Int;
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
	Index of the first byte of `s`'s trailing run of spaces and tabs, or
	`s.length` when it ends in neither. `0` means the whole string is blank.

	A String scan rather than a rendering step, so it sits at module level
	instead of on `Renderer` — where it would also be the member that pushes
	the type past its size cap.
**/
private function trailBlankStart(s: String): Int {
	var i: Int = s.length;
	while (i > 0) {
		final c: Int = s.fastCodeAt(i - 1);
		if (c != ' '.code && c != '\t'.code) break;
		i--;
	}
	return i;
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
		fillRest = null;
		fillIdx = 0;
		fillSep = null;
		fillTailReserve = 0;
		fillRestProbe = false;
		fillLineStart = -1;
		popMarkerZero = false;
		popMarkerDecrease = false;
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
			pendingTrailBlank: null,
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
				case Empty, Text(_), Line(_), OptSpace(_), OptSpaceSkipAfterHardline, OptHardline, OptHardlineSkipAtOpenDelim,
					OptHardlineSkipBeforeHardline:
					// Content-emitting leaf ctors — mutate the scalar layout
					// accumulators (buf / col / pending* / lastEmit / lineCount).
					// Delegated to the static `emitLeaf` on the `ctx` carrier.
					emitLeaf(ctx, f);
				case Nest(_, _), Concat(_), Group(_), BodyGroup(_), GroupWithRestProbe(_), Flatten(_), WrapBoundary(_), HardFlatten(_),
					CollapseProbe(_):
					// Structural / descend arms — no scalar layout mutation, only
					// frame pushes. Delegated to the static `pushStructural` (reads
					// `col`/`width`/`f`, writes `stack`). See that helper for each
					// per-ctor semantic.
					pushStructural(f, stack, ctx.col, pendingSpaceWidth(ctx), width);
				case IfBreak(_, _), IfWidthExceeds(_, _, _), IfFirstLineExceeds(_, _, _), IfLineExceeds(_, _, _),
					IfResidualLineExceeds(_, _, _), IfFullLineExceeds(_, _, _), IfNaturalFirstLineExceeds(_, _, _),
					IfNaturalFirstLineExceedsWithRest(_, _, _), IfNaturalFirstLineFitsOpenDelim(_, _, _),
					IfArrowContinuationFits(_, _, _, _, _), IfIndentWidthExceeds(_, _, _, _), IfGluedFirstLineExceeds(_, _, _, _):
					pushExceedsBranch(f, stack, ctx.col, pendingSpaceWidth(ctx), width, decisions);
				case Fill(_, _, _), FillWithRestProbe(_, _, _), FillBreakAfterWrap(_, _, _):
					// Fill family — per-item / all-flat layout, no scalar layout
					// mutation (reads `lineCount` for the break-after-wrap snapshot,
					// writes `stack`). Delegated to the static `pushFill`.
					pushFill(f, stack, ctx.lineCount);
				case CollapseAddProbe(_), CollapseBoolProbe(_), CollapseChainProbe(_):
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
		return finalNewline && !capped.endsWith(lineEnd) ? capped + lineEnd : capped;
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
	 * True when `s` ends with an open delimiter (`(`/`[`/`{`) — drives the
	 * `OpenDelim` `lastEmit` classification.
	 */
	private static inline function endsWithOpenDelim(s: String): Bool {
		if (s.length == 0) return false;
		final c: Int = s.fastCodeAt(s.length - 1);
		return c == '('.code || c == '['.code || c == '{'.code;
	}

	/**
	 * Classify the `lastEmit` state produced by emitting text `s`.
	 */
	private static inline function lastEmitFromText(s: String): LastEmit {
		return endsWithOpenDelim(s) ? OpenDelim : Other;
	}

	/**
	 * Width of the `OptSpace` still pending at the current pen — content that is
	 * NOT yet in `ctx.col` but lands on the same physical line as whatever is
	 * emitted next. Fed to the column-aware push helpers so their fit probes
	 * measure the full line (see `pushStructural` / `pushExceedsBranch`).
	 */
	private static inline function pendingSpaceWidth(ctx: RenderCtx): Int {
		return ctx.pendingOptSpace != null ? ctx.pendingOptSpace.length : 0;
	}

	/**
	 * ω-glue-width gates 2 and 3: would moving a glued body to `brokenIndent`
	 * be worth it? Answered off ONE natural first-line re-measure of the glued
	 * Doc, taken as if the pen sat one column LEFT of `brokenIndent` — the walk
	 * spends that column on the glue separator (`OptSpace(' ')`, which every
	 * `BodyFit.glueLayout` caller puts first in the glued shape) and the body
	 * then lands exactly on the indent it would break to. `broken -
	 * brokenIndent` is therefore the body's own first-line width there.
	 *
	 * Two ways to answer no, each closing a measured hole:
	 *
	 *  - `broken > n` — still over-wide after the move, so the move fixes
	 *    nothing and only costs a line and an indent level. Mirrors the fit-gate
	 *    in `collapseParenCommitsOpen`: when the inner cannot be made a single
	 *    fitting line, opening does not help. This is also what absorbs the
	 *    measurer's own slop — `naturalWidthStructural` resolves the
	 *    `IfFirstLineExceeds` probe family on its FLAT side, so a body whose
	 *    bracket opens through one measures a few columns too wide, and without
	 *    this test that slop broke a `return <ternary>` whose rendered line sat
	 *    exactly at the limit.
	 *  - `broken <= brokenIndent + 1` — the body would put at most ONE column on
	 *    that line: it breaks right after its own opening token. A statement
	 *    block, or a literal already committed to breaking, gives the header
	 *    back only those columns and strands its `{` on a line of its own. The
	 *    same reasoning `selfBreakingBraceBody` applies to the arrow-body
	 *    marker, though not the same predicate — that one also demands a
	 *    `{`-leading body and reads a flat measurer, while this is a pure width
	 *    test and refuses any one-column first line. Constructed (a `case` label
	 *    ALREADY past the limit whose body is a block) the move came out
	 *    strictly worse than the glue.
	 */
	private static inline function brokenBodyIsWorthMoving(flatDoc: Doc, brokenIndent: Int, n: Int, width: Int): Bool {
		final broken: Int = naturalFirstLineWidth(flatDoc, brokenIndent - 1, brokenIndent, width);
		return broken <= n && broken > brokenIndent + 1;
	}

	/**
	 * First-line-only view of `embeddedLineWidths`, for the `Fill` packing probe:
	 * lets a fill pack a verbatim multi-line token when its FIRST line fits the
	 * remaining budget (matching haxe-formatter, which re-flows the head of a
	 * token-splice operand onto the packed chain line) instead of breaking the
	 * whole operand onto its own line for its full flat width. A packed item's
	 * tail is the fill's own business, so the `last` half is not consulted.
	 *
	 * Falls back to `condSpliceFirstLine` — the same measurement over a REAL
	 * hardline rather than a `Text`-embedded newline — when the item is a
	 * conditional-compilation splice operand that carries no embedded newline.
	 * That population used to be empty: a `#if … #end` operand was reachable
	 * only as `HxCondSpliceRaw`'s verbatim capture, whose newline lives inside
	 * a `Text`. `HxCondSpliceOpExpr` models the same region as real nodes, so
	 * its newline is a genuine hardline and `first` reads `-1` there, which
	 * would send the fill to the full flat width and break an operand the fork
	 * packs. Widening the fallback to EVERY fill item was measured first and
	 * declined: five writer tests move, and the shapes they cover are ordinary
	 * multi-line arguments a fill is supposed to refuse.
	 */
	private static inline function embeddedFirstLineWidth(d: Doc): Int {
		final w: EmbeddedLineWidths = embeddedLineWidths(d);
		return w.first >= 0 ? w.first : w.condSpliceFirstLine;
	}

	/**
	 * omega-arrow-block-body-open: does `flatDoc` — the FLAT side of an
	 * `@:fmt(arrowBodyLineWrap)` arrow-body marker — open with `{` and break
	 * IMMEDIATELY after it, before any other token? That is the population whose head
	 * line the body terminates by itself, so an extra break after `->` shortens
	 * nothing: a multi-statement block, or a `{ … }` literal whose own wrap cascade
	 * committed to breaking at build time.
	 *
	 * All three conjuncts are load-bearing, each closing a measured hole:
	 *
	 *  - `{`-leading alone is NOT "is a block". `x -> { a: 1, b: 2 }` is an object
	 *    literal whose flat doc also starts with `{`, and a FLAT one rides the head
	 *    line in full, so breaking after `->` genuinely shortens it. Suppressing that
	 *    break pushed a fixture from 127 to 141 columns against a 140 budget.
	 *  - `hasForcedBreak` alone is not enough either, in BOTH directions. A non-brace
	 *    body that breaks internally still gains a shorter head line from the arrow
	 *    break; and a `{`-leading body can break somewhere OTHER than right after `{`
	 *    — under `wrapping.objectLiteral.defaultWrap: "keep"` a one-line source
	 *    literal reproduces its own layout, so `{ onDone: () -> { … }, tag: 1 }` has
	 *    a forced hardline (the inner block's) while its head line runs on. That took
	 *    a fixture from 108 to 146 columns.
	 *  - `flatTokenWidthFirstLine(flatDoc) <= 1` is what states "breaks before any
	 *    other token". MEASURED, not assumed: a statement block sits behind a
	 *    `BodyGroup` whose committed-prefix answer is its bare `{` (0 before W17
	 *    taught the walk to charge it), and a self-breaking object literal measures
	 *    exactly 1 (its `{`, then the hardline) — both stay in the population, while
	 *    the keep-mode literal above measures its whole head run and drops out.
	 *
	 * Read STRUCTURALLY — all three walkers resolve every conditional on its flat
	 * side — so no render-time width measurement can change which arm a construct
	 * takes. That is a deliberate limit: an object literal that breaks only AT RENDER
	 * TIME (its own `Group` losing a width probe) answers `false` here, takes the
	 * arrow break, and then breaks anyway, so its `{` still lands alone. Measured on
	 * a 40-case width sweep, the gate removes 40 of 56 stranded opens and adds zero
	 * over-width lines, and the 16 it leaves are all that band — byte-identical to
	 * the pre-slice writer, since no line of an object-literal rendering changes.
	 * Closing them needs a width-aware answer, which would make this guard disagree
	 * with the two natural walks that resolve the same marker without a rest-stack
	 * term; that trade is a separate slice.
	 */
	private static inline function selfBreakingBraceBody(flatDoc: Doc): Bool {
		return DocMeasure.firstVisibleTextStartsWith(flatDoc, '{'.code) && DocMeasure.hasForcedBreak(flatDoc)
			&& flatTokenWidthFirstLine(flatDoc) <= 1;
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
		return if (probe == null)
			fullLineCrosses
		else if (probe.hard)
			fullLineCrosses && restStackHasTrailingContent(restStack)
		else
			fullLineCrosses && indent + DocMeasure.flatTokenWidth(probe.inner) < n;
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
				case Nest(_, inner), Group(inner), GroupWithRestProbe(inner), BodyGroup(inner), Flatten(inner), WrapBoundary(inner),
					HardFlatten(inner), CollapseAddProbe(inner), CollapseBoolProbe(inner), CollapseChainProbe(inner),
					ConditionalMarkerZero(inner), ConditionalMarkerDecrease(inner):
					stack.push(inner);
				case Concat(items):
					for (it in items) stack.push(it);
				case IfIndentWidthExceeds(_, _, _, fl), IfGluedFirstLineExceeds(_, _, _, fl):
					// ω-case-sym-linear + ω-glue-width: both `BodyFit` width probes are
					// EXCLUDED from the both-branch descent. Their two branches wrap the
					// SAME body object and differ only in the separator before it, so a
					// walk asking about subtree CONTENT sees one answer either way, while
					// descending both doubles the visited node count per nested probe —
					// 2^depth for nested switches. See the ctor docs in `Doc` for the
					// per-walker branch contract; a walker that is NOT content-only must
					// decide for itself (`WrapList.startsWithHardline` reads the flat side
					// of the glue probe for exactly that reason).
					stack.push(fl);
				case IfBreak(brk, fl), IfWidthExceeds(_, brk, fl), IfFirstLineExceeds(_, brk, fl), IfLineExceeds(_, brk, fl),
					IfResidualLineExceeds(_, brk, fl), IfFullLineExceeds(_, brk, fl), IfNaturalFirstLineExceeds(_, brk, fl),
					IfNaturalFirstLineExceedsWithRest(_, brk, fl), IfNaturalFirstLineFitsOpenDelim(_, brk, fl),
					IfArrowContinuationFits(_, _, _, brk, fl):
					stack.push(brk);
					stack.push(fl);
				case Fill(items, sep, _), FillWithRestProbe(items, sep, _), FillBreakAfterWrap(items, sep, _):
					for (it in items) stack.push(it);
					stack.push(sep);
				case Empty, Text(_), Line(_), OptSpace(_), OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline,
					OptSpaceSkipAfterHardline:
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
		for (k in 0...needleLen) if (s.fastCodeAt(at + k) != needle.fastCodeAt(k)) return false;
		return true;
	}

	/**
	 * Returns `true` if rendering `d` in flat mode at the given indent fits
	 * `remaining` columns. Used to choose between flat and broken layout for a
	 * `Group` / `BodyGroup`.
	 *
	 * "Fits" is per PHYSICAL line, which for all but one shape is the same as
	 * "consumes at most `remaining` columns in total": only a VERBATIM
	 * multi-line token (`embeddedLineWidths`) puts more than one line into a
	 * flat rendering, and there the test is that the line the token opens on
	 * and the line it closes on each fit. Its interior lines are emitted byte
	 * for byte in either layout, so no caller's break can shorten them and
	 * none is measured.
	 */
	private static function fitsFlat(remaining: Int, indent: Int, d: Doc): Bool {
		if (remaining < 0) return false;
		// omega-verbatim-firstline: `d`'s flat projection reaches an embedded
		// `\n` inside a `Text` leaf before any break point -- a VERBATIM
		// multi-line token (a raw multi-line string literal, a `#if … #end`
		// token splice) whose interior lines are emitted byte-for-byte in
		// either layout. Its SUMMED width is not a line width, so the standard
		// budget walk refuses a token whose every physical line fits, and the
		// break it falls back to shortens nothing it measured. The two lines a
		// layout around the token still owns are the one it opens on and the
		// one it closes on -- both must fit.
		// Either width being -1 falls THROUGH to the standard walk, which is
		// the answer that stays correct: `first` of -1 means no embedded
		// newline at all, and `last` of -1 means a real hardline follows the
		// token -- content this measure cannot place, and content the walk
		// refuses outright (`fitsFlatStep` reports a hardline as `broke`).
		// Committing such a doc to flat would emit its hardlines unindented.
		final embedded: EmbeddedLineWidths = embeddedLineWidths(d);
		if (embedded.first >= 0 && embedded.last >= 0) return embedded.first <= remaining && embedded.last <= remaining;
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
	 * returned and the rest of the tree is ignored. TWO render arms read it:
	 * the `IfFirstLineExceeds` probe, to answer "would the first rendered line
	 * of `flatDoc` exceed `n` columns from the current pen?", and
	 * `selfBreakingBraceBody`, the `IfResidualLineExceeds` arrow-body guard,
	 * whose `<= 1` threshold this same charging answer feeds — see the bullet
	 * on that threshold further up this file.
	 *
	 * Departure from `DocMeasure.flatTokenWidth`: forced hardlines abort the
	 * walk instead of contributing zero width. `Group` descends as usual; a
	 * forced hardline anywhere in its inner aborts the first-line walk because
	 * such a Group must commit to break mode. A COMMITTED `BodyGroup` — one whose
	 * own first line already carries a forced hardline — is charged its first-line
	 * prefix and ENDS the walk (`bgPrefix == true`), the same answer
	 * `restNodeWidth` gives: `fitsFlat` can never answer flat for such a group, so
	 * render is guaranteed to break it and its leading ` {` really does land on
	 * this line. A BodyGroup with no forced hardline of its own stays deferred —
	 * its flat/break is genuinely decided later, at the live column.
	 *
	 * THE FAMILY ANSWERS ONE QUESTION — what does a `BodyGroup` put on the CURRENT
	 * line. `WrapList.flatLength` descends it, which is "can this be one line at
	 * all", a different question. `naturalWidthStructural` resolves it by its own
	 * fit at the running column, the same thing render does. Under
	 * `bgPrefix == true` this walker and `restNodeWidth` (`bgDescend == false`)
	 * apply the same POLICY — charge the prefix, end the line. Their
	 * committedness TEST still differs: the classifier's own probe passes
	 * `false` (next paragraph).
	 *
	 * `bgPrefix == false` is NOT a second question — do not read the flag as one.
	 * It is this same question answered LESS accurately: it lets a nested
	 * `BodyGroup` that is itself committed pass as zero width without ending the
	 * line, when render really does land that group's ` {` here. Two callers take
	 * it: `sepWidthBeforeBreak` (a Fill separator — the flag is inert there)
	 * and — the one that matters — `restNodeWidth`'s own
	 * committed-vs-movable classifier, which calls this walker to decide whether a
	 * BodyGroup is committed at all. Charging there makes a body read as committed
	 * whenever a nested COMMITTED body sits on its first line:
	 * `for (x in xs) if (c) { … }` charges the whole `if (c) {` header to the
	 * rest-of-stack lookahead, and the cond-wrap consumers downstream of it wrap
	 * the for-header.
	 *
	 * That cost is CALIBRATION debt, not a second question, and it belongs to the
	 * REST-STACK consumers — `flatTokenWidthOfRestStack`'s seven readers (the chain
	 * probe, `GroupWithRestProbe`, the Fill rest probes, `IfLineExceeds`,
	 * `IfNaturalFirstLineExceedsWithRest`), the only ones that reach this
	 * classifier. NOT `IfFirstLineExceeds`, which does not read the rest stack at
	 * all and is exactly the consumer W17 moved onto the charging answer. W16's
	 * recalibration verdict stands for the rest-stack readers; W17 did not retire
	 * it, it confined the disagreement to them. Measured (W17, 2026-08-25,
	 * re-measured at review): charging in BOTH walkers closes the same two Pony
	 * files, leaves Pony's drift set identical at 80 and the other five
	 * two-rewrite files untouched, and reformats SIX files here instead of three,
	 * three of them worse — `for (candidate in candidatesOf(\n\tsource, plugin\n))`,
	 * `if (index.skippedFiles()\n\t.length == 0)`,
	 * `for (group in coupled) if (group.exists(f ->\n\thit.contains(f)\n))`.
	 * Charging the prefix WITHOUT ending the line is free and closes nothing:
	 * 0 files here, 0 on Pony, census still 7.
	 *
	 * What the committed-prefix answer closed (W17): `ui/xml/PixiXmlUi.hx` and
	 * `tools/nodesrc/module/Bmfont.hx`, two of the seven Pony files that needed
	 * two writer rewrites — suite and corpus byte-unmoved, Pony's drift set
	 * unmoved at 80 (its OUTPUT moves for exactly those two files, which now
	 * settle on their pass-1 shape), and three files of this tree reformatted,
	 * each a call or ternary whose collection argument now GLUES instead of the
	 * head opening — the shape `WrapFlatSourceFixedPointTest` already pins as the
	 * correct fixed point for the same construct. The five that remain are that
	 * test's three pinned cases plus `net/http/modules/mmodels/Builder.hx` and
	 * `tools/nodesrc/module/Imagemin.hx`; none of them is a `BodyGroup` question —
	 * measured, charging in both walkers closes none of them either.
	 *
	 * Stack-based walk — items pushed in reverse so pop order matches
	 * left-to-right traversal. The `aborted` flag short-circuits
	 * remaining work once a hardline is seen.
	 */
	private static function flatTokenWidthFirstLine(d: Doc): Int {
		return flatTokenWidthFirstLineWithBreak(d, true).width;
	}

	/**
	 * Width of a `Fill` separator's content that survives on the CURRENT
	 * rendered line when the separator BREAKS — i.e. up to (not including) its
	 * first `Line` (soft OR hard). A broken soft `Line` drops its flat space,
	 * so a `,`-then-soft-space separator (commaPolicy:after) contributes only
	 * the leading `,`. `flatTokenWidthFirstLine` counts a soft `Line`'s space
	 * (it stops only at a HARD line), over-reporting the on-line separator
	 * width by one; the rest-stack lookahead — which is entered only from a
	 * FillCont frame already committed to break mode — needs the broken width.
	 */
	private static function sepWidthBeforeBreak(d: Doc): Int {
		final stack: Array<Doc> = [d];
		var total: Int = 0;
		var aborted: Bool = false;
		while (stack.length > 0 && !aborted) {
			final node: Doc = stack.pop();
			switch (node) {
				case Line(_):
					aborted = true;
				case _:
					final step: { add: Int, aborted: Bool } = flatFirstLineStep(node, stack, false);
					total += step.add;
					aborted = step.aborted;
			}
		}
		return total;
	}

	/**
	 * Flat width of `d`'s first physical line (up to but excluding its first
	 * hardline), paired with `broke` = whether such a hardline was reached
	 * (`false` means the walk drained with no hardline — the content is fully
	 * inline). `bgPrefix` selects what a NESTED `BodyGroup` contributes: `false`
	 * defers every one of them (zero width, no line end), `true` charges a
	 * COMMITTED one its own first-line prefix and ends the line. Under either, a
	 * directly cuddled block body reports just its leading ` {` prefix with
	 * `broke = true` while an inline body reports its whole first line with
	 * `broke = false` — the distinction the rest-probe uses to count a
	 * signature's trailing block brace without pulling an inline for/while body
	 * onto the header line. Which caller passes which, and why the two answers
	 * are ONE question and not two, is on `flatTokenWidthFirstLine` — the
	 * width-only projection of this under `bgPrefix == true`.
	 */
	private static function flatTokenWidthFirstLineWithBreak(d: Doc, bgPrefix: Bool): { width: Int, broke: Bool } {
		final stack: Array<Doc> = [d];
		var total: Int = 0;
		var broke: Bool = false;
		while (stack.length > 0 && !broke) {
			final node: Doc = stack.pop();
			final step: { add: Int, aborted: Bool } = flatFirstLineStep(node, stack, bgPrefix);
			total += step.add;
			broke = step.aborted;
		}
		return { width: total, broke: broke };
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
	 * "Naturally-produced hardline" also covers a newline a VERBATIM
	 * multi-line token carries INSIDE a `Text` leaf (a raw multi-line
	 * string literal, a `#if ... #end` token-splice raw): those bytes are
	 * emitted as-is, so the first physical line genuinely ends there and
	 * `naturalWidthStep` stops the walk on it. The flat-projection
	 * statement of the same rule is `embeddedLineWidths`.
	 *
	 * `BodyGroup` is NOT deferred here — `naturalWidthStructural` routes it
	 * through `pushNaturalGroup` exactly like a `Group`, resolving it by its own
	 * fit at the running column, because deferring it would under-measure a RHS
	 * whose own body breaks and hide the overflow from the parent `=`-probe. That
	 * makes this the MOST accurate of the family's answers to "what does a
	 * `BodyGroup` put on the current line", and `flatFirstLineStep`'s
	 * unconditional defer the least; `flatTokenWidthFirstLine`'s doc carries the
	 * verdict and what agreement would cost. (This paragraph used to claim the
	 * opposite — "DEFERRED... Departure 2, mirrors `fitsFlat` /
	 * `flatTokenWidthFirstLine`" — contradicting the arm directly below it.)
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
	 * `trailWidth` — flat width of the content that will ride the SAME rendered
	 * line after `d` (the statement's own `;`, a closing `)`, …). It lives in the
	 * enclosing render stack, so this walk cannot discover it; the caller reads it
	 * off that stack and passes it in. Only the rest-aware `GroupWithRestProbe`
	 * arm consumes it, so `0` (the default) keeps every other caller byte-inert.
	 */
	private static function naturalFirstLineWidth(
		d: Doc, startCol: Int, indent: Int, width: Int, resolveOpenDelim: Bool = false, trailWidth: Int = 0
	): Int {
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
			final step: { add: Int, aborted: Bool } = naturalWidthStep(node, stack, width, col, resolveOpenDelim, trailWidth);
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
	 *    would the line exceed?"); - `BodyGroup` is NOT deferred here, unlike `fitsFlat`: this walk goes
	 *    through `restNodeWidth` with `bgDescend == false`, which charges a
	 *    COMMITTED group its own first-line prefix and ends the walk on it. A
	 *    group with no forced hardline of its own is still deferred. (The doc
	 *    this bullet used to carry — "deferred, same Departure 2 as `fitsFlat`"
	 *    — was wrong about its own function; see `flatTokenWidthFirstLine`'s doc
	 *    for which of the two answers is right and what agreement costs.)
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
				// continuation.
				//
				// EXCEPTION — the Fill's pending SEPARATOR still lands on the
				// CURRENT rendered line (a trailing `,` under
				// commaPolicy:after) before that next-item hardline. A chain /
				// ternary element rendered INSIDE this Fill (a call argument
				// that is itself a `?:` / `+` construct) would otherwise stop
				// here at `rest = 0` and under-measure its physical line by the
				// separator width — the fork counts the trailing comma in the
				// element's line length. Add only the separator's FIRST-LINE
				// width (up to its own hardline: the comma, not the break),
				// then abort at the Fill boundary as before.
				if (f.fillSep != null) total += sepWidthBeforeBreak(f.fillSep);
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
	 * One step of `restStackHasTrailingContent`'s inner-doc scan. Pushes any
	 * structural children onto `inner` for continued scanning. Returns `null`
	 * to keep scanning, `true` when a non-trivial trailing token was found,
	 * `false` when a hardline boundary terminates the scan.
	 */
	private static function trailingScanStep(nd: { doc: Doc, mode: Mode }, inner: Array<{ doc: Doc, mode: Mode }>): Null<Bool> {
		switch nd.doc {
			case Empty, OptSpace(_), OptSpaceSkipAfterHardline:
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
				return flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code ? false : null;
			case OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline:
				return false;
			case Nest(_, innerDoc):
				inner.push({ doc: innerDoc, mode: nd.mode });
				return null;
			case Concat(items):
				var k: Int = items.length;
				while (--k >= 0) inner.push({ doc: items[k], mode: nd.mode });
				return null;
			case Group(innerDoc), BodyGroup(innerDoc), GroupWithRestProbe(innerDoc):
				inner.push({ doc: innerDoc, mode: MFlat });
				return null;
			case IfBreak(_, fl), IfWidthExceeds(_, _, fl), IfFirstLineExceeds(_, _, fl), IfLineExceeds(_, _, fl),
				IfResidualLineExceeds(_, _, fl), IfFullLineExceeds(_, _, fl), IfNaturalFirstLineExceeds(_, _, fl),
				IfNaturalFirstLineExceedsWithRest(_, _, fl), IfNaturalFirstLineFitsOpenDelim(_, _, fl),
				IfArrowContinuationFits(_, _, _, _, fl), IfIndentWidthExceeds(_, _, _, fl), IfGluedFirstLineExceeds(_, _, _, fl):
				inner.push({ doc: fl, mode: MFlat });
				return null;
			case Fill(items, sep, _), FillWithRestProbe(items, sep, _), FillBreakAfterWrap(items, sep, _):
				var k: Int = items.length;
				while (k > 0) {
					k--;
					inner.push({ doc: items[k], mode: MFlat });
					if (k > 0) inner.push({ doc: sep, mode: MFlat });
				}
				return null;
			case Flatten(innerDoc), WrapBoundary(innerDoc), HardFlatten(innerDoc), CollapseProbe(innerDoc), CollapseAddProbe(innerDoc),
				CollapseBoolProbe(innerDoc), CollapseChainProbe(innerDoc):
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
			final c: Int = s.fastCodeAt(ci);
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
	private static function flatFirstLineStep(node: Doc, stack: Array<Doc>, bgPrefix: Bool): { add: Int, aborted: Bool } {
		switch (node) {
			case Empty:
				return { add: 0, aborted: false };
			case BodyGroup(innerDoc):
				if (!bgPrefix) return { add: 0, aborted: false };
				final prefix: { width: Int, broke: Bool } = flatTokenWidthFirstLineWithBreak(innerDoc, true);
				return prefix.broke ? { add: prefix.width, aborted: true } : { add: 0, aborted: false };
			case OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline:
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
			case Fill(items, sep, _), FillWithRestProbe(items, sep, _), FillBreakAfterWrap(items, sep, _):
				var k: Int = items.length;
				while (k > 0) {
					k--;
					stack.push(items[k]);
					if (k > 0) stack.push(sep);
				}
				return { add: 0, aborted: false };
			case Nest(_, inner), Group(inner), GroupWithRestProbe(inner), IfBreak(_, inner), IfWidthExceeds(_, _, inner),
				IfFirstLineExceeds(_, _, inner), IfLineExceeds(_, _, inner), IfResidualLineExceeds(_, _, inner),
				IfFullLineExceeds(_, _, inner), IfNaturalFirstLineExceeds(_, _, inner), IfNaturalFirstLineExceedsWithRest(_, _, inner),
				IfNaturalFirstLineFitsOpenDelim(_, _, inner), IfArrowContinuationFits(_, _, _, _, inner),
				IfIndentWidthExceeds(_, _, _, inner), IfGluedFirstLineExceeds(_, _, _, inner), Flatten(inner), WrapBoundary(inner),
				HardFlatten(inner), CollapseProbe(inner), CollapseAddProbe(inner), CollapseBoolProbe(inner), CollapseChainProbe(inner),
				ConditionalMarkerZero(inner), ConditionalMarkerDecrease(inner):
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
			case OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline:
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
			case Fill(items, sep, _), FillWithRestProbe(items, sep, _), FillBreakAfterWrap(items, sep, _):
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
			case Group(inner), GroupWithRestProbe(inner), IfBreak(_, inner), IfWidthExceeds(_, _, inner), IfFirstLineExceeds(_, _, inner),
				IfLineExceeds(_, _, inner), IfResidualLineExceeds(_, _, inner), IfFullLineExceeds(_, _, inner),
				IfNaturalFirstLineExceeds(_, _, inner), IfNaturalFirstLineExceedsWithRest(_, _, inner),
				IfNaturalFirstLineFitsOpenDelim(_, _, inner), IfArrowContinuationFits(_, _, _, _, inner),
				IfIndentWidthExceeds(_, _, _, inner), IfGluedFirstLineExceeds(_, _, _, inner), Flatten(inner), WrapBoundary(inner),
				HardFlatten(inner), CollapseProbe(inner), CollapseAddProbe(inner), CollapseBoolProbe(inner), CollapseChainProbe(inner),
				ConditionalMarkerZero(inner), ConditionalMarkerDecrease(inner):
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
	 * `naturalRestStackWidth` (`bgDescend == true`). Pushes structural
	 * children onto `inner`. Returns the flat width contributed by `node.doc`
	 * and whether a hardline / broken `Line` boundary terminates the walk.
	 *
	 * `bgDescend` picks the `BodyGroup` arm: descend inline body content, or
	 * defer it (BG decides its own layout, Departure 2). Every RENDER probe
	 * defers — a trailing BG is a movable fitLine body and must not decide the
	 * header line's layout (ω-header-wrap-ladder).
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
			case OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline:
				return { add: 0, aborted: true };
			case BodyGroup(innerDoc):
				// The sister-walker differentiator: Full descends inline body
				// content; plain defers (BG decides own layout, Departure 2) —
				// EXCEPT a cuddled block body whose ` {` head rides the current
				// rendered line before the body's own hardline. Count that leading
				// prefix (the `{`) and terminate the trailing scan so the
				// functionSignature rest-probe sees the true line width: a
				// 141-column `):Ret {` signature must wrap, not hug at the 140
				// limit (its `{` was the missing column). A fully inline body
				// (no hardline on its first line) stays deferred, so the cond-wrap
				// rest-probe never pulls an inline for/while body onto the header.
				//
				// That EXCEPT is not a special case, it is the CURRENT-LINE
				// question answered correctly, and since W17 `flatFirstLineStep`
				// answers it the same way under `bgPrefix == true`. The call BELOW
				// deliberately passes `false` and keeps the LESS accurate answer:
				// it is this arm's own committed-vs-movable classifier, and a
				// nested body that is itself COMMITTED would otherwise make every
				// `for (…) if (…) { … }` read as committed here. That reading is
				// what render does; the REST-STACK consumers downstream — this arm
				// is reached only through `flatTokenWidthOfRestStack` — are simply
				// calibrated against the deferring one, so charging here wraps
				// headers that fit. `flatTokenWidthFirstLine`'s doc carries the
				// measurement and says why this is calibration debt rather than a
				// second question. Nothing in `test/` flips when this `false` is
				// flipped: what guards it is the whole-tree `apq fmt src test
				// --list` (6 files instead of 3, 3 of them worse) plus the Pony
				// A/B, not a fixture.
				if (bgDescend) {
					inner.push({ doc: innerDoc, mode: MFlat });
					return { add: 0, aborted: false };
				}
				final prefix: { width: Int, broke: Bool } = flatTokenWidthFirstLineWithBreak(innerDoc, false);
				return prefix.broke ? { add: prefix.width, aborted: true } : { add: 0, aborted: false };
			case Concat(items):
				var k: Int = items.length;
				while (--k >= 0) inner.push({ doc: items[k], mode: node.mode });
				return { add: 0, aborted: false };
			case Fill(items, sep, _), FillWithRestProbe(items, sep, _), FillBreakAfterWrap(items, sep, _):
				var k: Int = items.length;
				while (k > 0) {
					k--;
					inner.push({ doc: items[k], mode: MFlat });
					if (k > 0) inner.push({ doc: sep, mode: MFlat });
				}
				return { add: 0, aborted: false };
			case IfNaturalFirstLineExceeds(_, _, innerDoc), IfNaturalFirstLineExceedsWithRest(_, _, innerDoc):
				// An `IfNaturalFirstLineExceeds` relocates its content to its own
				// line when that content's natural first line overflows `lineWidth`
				// (the typed var-init `=`-break emitted by
				// `breakAfterLeadOnOverflowWrap`). A trailing-width lookahead
				// must treat it as a break boundary: abort here instead of
				// descending its flat branch, so the rest-probe stops at the `=`
				// (matching fork's post-`=`-break `lengthAfter`) rather than
				// counting a RHS that will actually break onto the next line, which
				// would over-wrap the LHS type-param list. The BG-descending walk
				// (`bgDescend == true`: the chain `IfFullLineExceeds` inline-body probe)
				// instead descends the flat branch -- the chain-wrap decision assumes a
				// flat body sharing the line, so it must measure the full trailing width
				// (same category as the `BodyGroup` Departure-2 split).
				if (bgDescend) {
					inner.push({ doc: innerDoc, mode: MFlat });
					return { add: 0, aborted: false };
				}
				return { add: 0, aborted: true };
			case IfBreak(brDoc, flDoc):
				// ω-fitline-body-glue: `IfBreak` is the ONE conditional this walk can
				// resolve — its selector IS the enclosing group's mode, which the
				// frame already carries. Descending the FLAT side inside a BROKEN
				// frame measures content the renderer will not put on this line: the
				// FitLine body-placement `IfBreak` (`buildBodyFitExpr`) hides a glue
				// probe on its break side, and a flat descend counted the body's
				// whole flat width as trailing width for the condition's own wrap
				// probe — which then wrapped a condition that fits.
				inner.push({ doc: node.mode == MBreak ? brDoc : flDoc, mode: node.mode });
				return { add: 0, aborted: false };
			case Group(innerDoc), GroupWithRestProbe(innerDoc), IfWidthExceeds(_, _, innerDoc), IfFirstLineExceeds(_, _, innerDoc),
				IfLineExceeds(_, _, innerDoc), IfResidualLineExceeds(_, _, innerDoc), IfFullLineExceeds(_, _, innerDoc),
				IfNaturalFirstLineFitsOpenDelim(_, _, innerDoc), IfArrowContinuationFits(_, _, _, _, innerDoc),
				IfIndentWidthExceeds(_, _, _, innerDoc), IfGluedFirstLineExceeds(_, _, _, innerDoc):
				// Static walk: descend in MFlat. Runtime Group decision is
				// unknowable here; flat-side measurement matches the cascade
				// rule semantic. The natural-first-line / rest-of-stack probes
				// are render-time decisions — this static walk sees only the
				// flat shape. GroupWithRestProbe shares semantic at static walk.
				inner.push({ doc: innerDoc, mode: MFlat });
				return { add: 0, aborted: false };
			case Nest(_, innerDoc), Flatten(innerDoc), WrapBoundary(innerDoc), HardFlatten(innerDoc), CollapseProbe(innerDoc),
				CollapseAddProbe(innerDoc), CollapseBoolProbe(innerDoc), CollapseChainProbe(innerDoc), ConditionalMarkerZero(innerDoc),
				ConditionalMarkerDecrease(innerDoc):
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
				if (s.length > 0) return { add: s.length, aborted: false, delim: DocMeasure.lastCharIsOpenDelim(s) };
				return { add: 0, aborted: false, delim: null };
			case Line(flat):
				if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) return { add: 0, aborted: true, delim: null };
				if (node.mode == MBreak) return { add: 0, aborted: true, delim: null };
				if (flat.length > 0) return { add: flat.length, aborted: false, delim: DocMeasure.lastCharIsOpenDelim(flat) };
				return { add: 0, aborted: false, delim: null };
			case OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline:
				return { add: 0, aborted: true, delim: null };
			case OptSpace(s):
				return { add: s.length, aborted: false, delim: DocMeasure.lastCharIsOpenDelim(s) };
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
		stack.push(
			if (node.forceFlat)
				{
					doc: flatDoc,
					indent: node.indent,
					mode: MFlat,
					forceFlat: true
				}
			else
				{
					doc: crosses ? breakDoc : flatDoc,
					indent: node.indent,
					mode: crosses ? MBreak : node.mode,
					forceFlat: false
				}
		);
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
		inner: Doc, width: Int, col: Int, restWidth: Int
	): Void {
		if (node.forceFlat) {
			stack.push({
				doc: inner,
				indent: node.indent,
				mode: MFlat,
				forceFlat: true
			});
		} else if (fitsFlat(width - col - restWidth, node.indent, inner)) {
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
			case Group(inner), GroupWithRestProbe(inner), BodyGroup(inner):
				pushNaturalGroup(stack, node, inner, width, col, 0);
			case IfBreak(breakDoc, flatDoc):
				final picked: Doc = node.forceFlat || node.mode == MFlat ? flatDoc : breakDoc;
				stack.push({
					doc: picked,
					indent: node.indent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case IfWidthExceeds(nn, breakDoc, flatDoc), IfLineExceeds(nn, breakDoc, flatDoc),
				IfResidualLineExceeds(nn, breakDoc, flatDoc), IfFullLineExceeds(nn, breakDoc, flatDoc):
				// No rest-stack lookahead is needed here: the cond's own
				// first line determines glue-vs-open; the trailing ` {`
				// lookahead is already covered by the width arm of the
				// sibling `naturalFirstLineWidth` probe in the render
				// decision. Resolve flat unless forced — these probes never
				// sit at the head of a cond's flatShape spine.
				pushNaturalExceeds(stack, node, breakDoc, flatDoc, col + DocMeasure.flatTokenWidth(flatDoc) >= nn);
			case IfNaturalFirstLineExceeds(nn, breakDoc, flatDoc), IfNaturalFirstLineExceedsWithRest(nn, breakDoc, flatDoc):
				// Self-class sibling: resolve recursively at the running col
				// over a strictly smaller subtree (mirror the width probe's
				// own arm; bounded by the finite tree).
				pushNaturalExceeds(stack, node, breakDoc, flatDoc, naturalFirstLineWidth(flatDoc, col, node.indent, width) >= nn);
			case Fill(items, sep, _), FillWithRestProbe(items, sep, _), FillBreakAfterWrap(items, sep, _):
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
					if (k > 0) stack.push({
						doc: sep,
						indent: node.indent,
						mode: node.mode,
						forceFlat: node.forceFlat
					});
				}
			case Flatten(inner), HardFlatten(inner):
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
			case IfFirstLineExceeds(_, _, inner), IfNaturalFirstLineFitsOpenDelim(_, _, inner),
				IfArrowContinuationFits(_, _, _, _, inner), IfIndentWidthExceeds(_, _, _, inner), IfGluedFirstLineExceeds(_, _, _, inner),
				CollapseProbe(inner), CollapseAddProbe(inner), CollapseBoolProbe(inner), CollapseChainProbe(inner),
				ConditionalMarkerZero(inner), ConditionalMarkerDecrease(inner):
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
			case Empty, Text(_), Line(_), OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline, OptSpace(_),
				OptSpaceSkipAfterHardline:
				// Leaf-content arms — handled by `naturalGluableStep`; never
				// reached here (this helper is its `case _` delegate).
				throw 'unreachable leaf in naturalGluableStructural';
		}
	}

	/**
	 * Rest-of-stack flat width over a `naturalFirstLineWidth` natural-frame
	 * `stack`: the same-line content the pending work-stack will still emit
	 * AFTER the current `If*Exceeds` node, up to the first hardline — our
	 * pending stack IS that lookahead. A chain's `IfFullLineExceeds` must see
	 * the trailing close-delims (`))`, `;`) that ride the same line, or it
	 * under-fires and the chain stays flat when render would break it. Walks
	 * with `bgDescend == true`, unlike render's own rest walk; the difference
	 * is inert for this walker's consumers (see the `IfLineExceeds` arm).
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
		width: Int, col: Int, resolveOpenDelim: Bool = false, trailWidth: Int = 0
	): { add: Int, aborted: Bool } {
		switch node.doc {
			case Empty:
				return { add: 0, aborted: false };
			case Text(s):
				// omega-verbatim-firstline (decl-init sibling): a VERBATIM
				// multi-line token -- a raw multi-line string literal, a
				// `#if ... #end` token-splice raw -- emits its own newlines
				// through ONE `Text`, so the first physical line ends at the
				// first of them and this walk stops there exactly as it does
				// on a hardline. Summing the whole token instead reports a
				// width no line ever reaches, and the lead-break the probe
				// then fires shortens nothing: every line after the first is
				// emitted byte for byte whatever the enclosing layout decides.
				// Flat-projection sibling of the same rule:
				// `embeddedLineWidths`, whose doc-comment carries why this arm
				// cannot delegate to it and why it needs no LAST-line half.
				final nl: Int = s.indexOf('\n');
				if (nl >= 0) return { add: nl, aborted: true };
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
			case OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline:
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
				naturalWidthStructural(node, stack, width, col, resolveOpenDelim, trailWidth);
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
		width: Int, col: Int, resolveOpenDelim: Bool = false, trailWidth: Int = 0
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
			case Group(inner), BodyGroup(inner):
				// THE natural decision: resolve THIS Group by its own fit at the
				// running column (`pushNaturalGroup`). BodyGroup is handled HERE
				// (same as render), NOT deferred — deferring it would under-
				// measure a RHS whose own body breaks, hiding the overflow from
				// the parent =-probe.
				pushNaturalGroup(stack, node, inner, width, col, 0);
			case GroupWithRestProbe(inner):
				// ω-natural-trailwidth: the rest-aware Group keeps its bias inside
				// the probe. Two sources feed it: `naturalRestStackWidth` for the
				// pending items of THIS walk, and `trailWidth` for what rides the
				// same rendered line AFTER the whole probed doc — content the walk
				// cannot see because it lives in the ENCLOSING render stack.
				//
				// The statement terminator is exactly that. `return [ … ];` puts
				// the `;` outside the probed value (`@:trailOpt(';')` on the ctor),
				// so a collection whose flat width equals the remaining budget
				// EXACTLY resolves flat here, the natural first line comes out as
				// the whole value, and the enclosing probe breaks after the keyword
				// — stranding a bare `return` while the value then fits the
				// continuation. Counting the terminator makes the collection break
				// instead: the natural first line is `return [`, the keyword stays
				// glued, and the value wraps inside its own brackets.
				// The whole mechanism is opt-in per probe: `trailWidth == 0` means
				// the caller did not ask for it, and the arm then measures exactly
				// as the plain `Group` one does — byte-parity for every consumer
				// that stayed on the legacy measure.
				pushNaturalGroup(stack, node, inner, width, col, trailWidth == 0 ? 0 : naturalRestStackWidth(stack) + trailWidth);
			case IfBreak(breakDoc, flatDoc):
				// Pick by mode (mirrors render IfBreak): forceFlat or MFlat
				// -> flat side; MBreak -> break side. Propagate forceFlat.
				final picked: Doc = node.forceFlat || node.mode == MFlat ? flatDoc : breakDoc;
				stack.push({
					doc: picked,
					indent: node.indent,
					mode: node.mode,
					forceFlat: node.forceFlat
				});
			case IfWidthExceeds(nn, breakDoc, flatDoc):
				pushNaturalExceeds(stack, node, breakDoc, flatDoc, col + DocMeasure.flatTokenWidth(flatDoc) >= nn);
			case IfLineExceeds(nn, breakDoc, flatDoc), IfFullLineExceeds(nn, breakDoc, flatDoc):
				// Own flat width PLUS the rest-of-stack lookahead (the same-line
				// content the pending work-stack will still emit). The lookahead
				// lets a chain probe see trailing close-delims that ride the same
				// line and break. APPROXIMATION: naturalRestStackWidth BG-DESCENDS
				// whereas render's rest walk defers. The canonical assignment-RHS
				// consumer never sits an IfLineExceeds head with a trailing
				// same-line body BodyGroup, so descend-vs-defer is inert here —
				// one rest walker suffices (YAGNI).
				pushNaturalExceeds(
					stack, node, breakDoc, flatDoc, col + DocMeasure.flatTokenWidth(flatDoc) + naturalRestStackWidth(stack) >= nn
				);
			case IfResidualLineExceeds(nn, breakDoc, flatDoc):
				// ω-arrow-residual-linewrap: the arrow-body wrap marker's natural
				// resolution DEFERS the rest-of-line to this enclosing measurer —
				// NO `naturalRestStackWidth` term (unlike the `IfLineExceeds` arm
				// above). The arrow contributes only its own flat body width, so an
				// enclosing `IfNaturalFirstLineFitsOpenDelim` (`&&`/`||` condition
				// chain) / `IfNaturalFirstLineExceeds` (assignment) sees the arrow's
				// FULL flat contribution and its own first-line overflow, and breaks
				// FIRST instead of the arrow's break-point pre-empting it (fork's
				// LATE-pass `applyArrowWrapping` — the arrow is last-resort).
				pushNaturalExceeds(stack, node, breakDoc, flatDoc, col + DocMeasure.flatTokenWidth(flatDoc) >= nn);
			case IfNaturalFirstLineExceeds(nn, breakDoc, flatDoc), IfNaturalFirstLineExceedsWithRest(nn, breakDoc, flatDoc):
				// Self-reference: resolve recursively at the running col
				// over a strictly smaller subtree (bounded by finite tree).
				pushNaturalExceeds(
					stack, node, breakDoc, flatDoc,
					naturalFirstLineWidth(flatDoc, col, node.indent, width, resolveOpenDelim, trailWidth) >= nn
				);
			case Fill(items, sep, _), FillWithRestProbe(items, sep, _), FillBreakAfterWrap(items, sep, _):
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
					if (k > 0) stack.push({
						doc: sep,
						indent: node.indent,
						mode: node.mode,
						forceFlat: node.forceFlat
					});
				}
			case Flatten(inner), HardFlatten(inner):
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
			case IfNaturalFirstLineFitsOpenDelim(nn, breakDoc, flatDoc) if (resolveOpenDelim):
				// ω-rhs-call-open: for a `return`/`=` RHS natural-first-line probe
				// (`resolveOpenDelim`), resolve this open-delim decision the way
				// render's own `IfNaturalFirstLineFitsOpenDelim` arm does — glue vs
				// OPEN at the running column — instead of descending the GLUED
				// `flatDoc` unconditionally. When the probe OPENS the delimiter
				// (not gluable), the natural first line must cap at that open delim
				// (the `breakDoc`'s leading `Line` terminates it), matching what
				// render emits — so the enclosing `IfNaturalFirstLineExceeds` keeps
				// the `return`/`=` glued and opens the call paren (fork parity)
				// rather than mis-measuring the value's full flat width and breaking
				// the operator. The `fitsD` sub-measure stays legacy (no resolve),
				// mirroring render's own glue probe. OUTSIDE a RHS probe
				// (`resolveOpenDelim == false`, e.g. a nested open-delim inside a
				// sibling expr-paren-open decision) the arm below keeps the flat
				// descend — byte-inert.
				final fitsD: Bool = naturalFirstLineWidth(flatDoc, col, node.indent, width) < nn;
				final gluableD: Bool = naturalFirstLineGluable(flatDoc, col, node.indent, width);
				final glueD: Bool = fitsD && gluableD;
				stack.push({
					doc: glueD ? flatDoc : breakDoc,
					indent: node.indent,
					mode: glueD ? node.mode : MBreak,
					forceFlat: node.forceFlat
				});
			case IfFirstLineExceeds(_, _, inner), IfNaturalFirstLineFitsOpenDelim(_, _, inner),
				IfArrowContinuationFits(_, _, _, _, inner), IfIndentWidthExceeds(_, _, _, inner), IfGluedFirstLineExceeds(_, _, _, inner),
				CollapseProbe(inner), CollapseAddProbe(inner), CollapseBoolProbe(inner), CollapseChainProbe(inner),
				ConditionalMarkerZero(inner), ConditionalMarkerDecrease(inner):
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
			case Empty, Text(_), Line(_), OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline, OptSpace(_),
				OptSpaceSkipAfterHardline:
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
		f: Frame, stack: Array<Frame>, col: Int, pendingSpace: Int, width: Int,
		decisions: Null<Array<{ node: Doc, crosses: Bool, ?indent: Int }>>
	): Void {
		switch (f.doc) {
			case IfBreak(_, _), IfWidthExceeds(_, _, _), IfFirstLineExceeds(_, _, _), IfLineExceeds(_, _, _), IfResidualLineExceeds(_, _, _):
				// Flat-width family — flat-token measurer feeds a `crosses`
				// test, no measure-only capture. Delegated to the static
				// `pushFlatWidthBranch`.
				pushFlatWidthBranch(f, stack, col, width);
			case IfFullLineExceeds(n, breakDoc, flatDoc):
				// Sibling of `IfLineExceeds`. Both the primitive's own
				// subtree (`flatTokenWidth`) and the rest-of-stack
				// lookahead (`restWidth` below) DEFER `BodyGroup`, so
				// neither a lambda body BG inside one of `flatDoc`'s
				// segments nor a movable fitLine body that follows on
				// the same source line inflates the probe. Slice
				// ω-iffulllineexceeds-primitive introduced the
				// primitive with a calibration-gated rest walk;
				// ω-header-wrap-ladder removed the gate — counting the
				// body broke a chain whose own header line fitted.
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
					decisions?.push({ node: f.doc, crosses: false });
				} else {
					// `pendingSpace` restores an un-flushed OptSpace preceding this
					// paren (`x = (chain) / 2` — the ` ` after `=` is pending, not
					// yet in `col`, but it lands on the flat line before the open
					// delim). Without it a paren-open probe under-counts the
					// physical line by one and a `(chain) OP y;` at exactly
					// maxLineLength + 1 stays glued (fork opens it).
					//
					// GATED on `n > width`: only the strict-`>` paren-open probes
					// (`expressionParenHardFlatten`, emitted at `lineWidth + 1`)
					// want it. Other IfFullLineExceeds consumers — e.g. a rest-aware
					// method-chain break emitted at `lineWidth` (n == width) — are
					// calibrated to the un-flushed column and would over-fire (wrap
					// a chain that fits) if the pending space were added.
					final effPending: Int = n > width ? pendingSpace : 0;
					// ω-header-wrap-ladder: EVERY `IfFullLineExceeds` consumer defers
					// a trailing `BodyGroup`. A BG after the probe is a MOVABLE
					// fitLine body (`case P if (c): BODY`, `for (cond) BODY`) that
					// drops to its own line whenever the shared line overflows, so
					// counting it decides the header's layout by the body's width:
					// it opens a paren whose own line fits (the case-guard label
					// tear) and — the reason this stopped being calibration-gated —
					// it breaks a FITTING method chain over its links, after which
					// the now-short last link happily re-glues the body onto its
					// `))`. Measuring the header ALONE is what makes the ladder's
					// step 2 (flat header, body on the next line) reachable.
					final restWidth: Int = flatTokenWidthOfRestStack(stack);
					// ω-chain-exact-limit-boundary: a chain probe (`n == lineWidth` —
					// bare `lineWidth` is the FAMILY DISCRIMINATOR selecting the
					// no-pending-space charge above)
					// whose glued tail is genuinely one-line-able measures the TRUE
					// physical line, and the fork keeps a flush-at-limit line — so its
					// exceed threshold is `n + 1` (a plain `>= n` dot-broke a chain
					// landing EXACTLY on the limit one column early). A tail carrying a
					// forced hardline (multi-line lambda body, trivia-bearing object
					// literal) measures a flattened PROXY instead (hardlines measure 0,
					// their flat-join space 1, a BG-deferred body 0), and the
					// explode-vs-cuddle decision for those shapes is
					// calibrated to the raw `>= n` — real fluent chains sit flush on the
					// proxy boundary (`HxMethodChainCuddledLinkTest`'s exploded
					// fixtures), so the `+ 1` applies ONLY to the true-width tails. The
					// strict probes (`n == lineWidth + 1`) already encode the exceed
					// threshold in `n`.
					final fireAt: Int = n > width || DocMeasure.hasForcedBreak(flatDoc) ? n : n + 1;
					final fullLineCrosses: Bool = col + effPending + DocMeasure.flatTokenWidth(flatDoc) + restWidth >= fireAt;
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
					decisions?.push({ node: f.doc, crosses: commits });
					final pushMode: Mode = commits ? MBreak : f.mode;
					stack.push(new Frame(f.indent, pushMode, commits ? breakDoc : flatDoc));
				}
			case IfNaturalFirstLineExceeds(_, _, _), IfNaturalFirstLineExceedsWithRest(_, _, _), IfNaturalFirstLineFitsOpenDelim(_, _, _),
				IfArrowContinuationFits(_, _, _, _, _), IfIndentWidthExceeds(_, _, _, _), IfGluedFirstLineExceeds(_, _, _, _):
				// Natural-shape family — inner Groups resolve by their own
				// `fitsFlat` (or a precomputed arrow width). Delegated to the
				// static `pushNaturalBranch`.
				pushNaturalBranch(f, stack, col, width);
			case _:
				// Unreachable: `render` routes only the eleven `If*` ctors here and
				// every one has an arm above. Same contract as `pushFlatWidthBranch`'s
				// tail — falling through would push no frame and silently delete the
				// node's subtree from the output, so an unrouted ctor throws instead.
				throw 'pushExceedsBranch: unrouted probe ctor ${f.doc.getName()}';
		}
	}

	/**
	 * Resolve and push the structural / descend arms of `render`'s dispatch
	 * switch — every `Doc` ctor that contributes no scalar layout mutation,
	 * only pushing the next frame(s) onto `stack` (reading `col`/`width`/`f`).
	 * Extracted verbatim from `render` — see each arm comment for the per-ctor
	 * semantic. Mutates no scalar accumulator (invariant #1).
	 *
	 * `pendingSpace` is the width of an un-flushed `OptSpace` sitting before this
	 * frame (see `RenderCtx.pendingOptSpace`) — it is NOT yet in `col` but lands
	 * on the same physical line. Consumed only by the `GroupWithRestProbe` arm;
	 * every other arm here is column-agnostic or keeps the plain `Group` budget.
	 */
	private static function pushStructural(f: Frame, stack: Array<Frame>, col: Int, pendingSpace: Int, width: Int): Void {
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
			case Group(inner), BodyGroup(inner):
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
				// ω-ternary-decl-init-pending-space: `pendingSpace` restores an
				// un-flushed `OptSpace` that PRECEDES this Group (the ` ` after
				// `=` in `final x:T = cond ? a : b;`, emitted by the
				// declaration's assign glue). It is not yet in `col` but lands
				// on the flat line before the Group, so without it the probe
				// under-counts the physical line by one and a declaration whose
				// initializer ternary sits at exactly maxLineLength + 1 stays
				// glued while the fork wraps it. Same convention as
				// `pushExceedsBranch`'s `effPending`.
				// UNGATED, unlike that sister: `IfFullLineExceeds` carries two
				// calibrations (`n == width` vs the paren-open `n == width + 1`)
				// and only the latter wants the pending space, so it needs the
				// `n > width` discriminator. This ctor has no such split — every
				// producer (`BinaryChainEmit`'s ternary-rest-aware pivot and
				// `WrapList.groupOrRestProbe`, i.e. every `@:fmt(groupRestProbe)`
				// Star: type-param lists, fn signatures, `Call` args, …) probes
				// against the same `width` and is by definition calibrated to the
				// FULL physical line — it already subtracts the trailing `;` / `,`,
				// so the leading pending space belongs to the same measurement.
				// Verified no output flip beyond the target shape: `fmt --list`
				// over anyparse `src`+`test` and over the whole TM tree moves only
				// the two `maxLineLength + 1` ternary declarations.
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, MFlat, inner, true, f.hardFlat));
				} else {
					final restW: Int = flatTokenWidthOfRestStack(stack);
					if (fitsFlat(width - col - pendingSpace - restW, f.indent, inner)) {
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
			case Fill(items, sep, tailReserveOpt), FillWithRestProbe(items, sep, tailReserveOpt),
				FillBreakAfterWrap(items, sep, tailReserveOpt):
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
						if (k > 0) stack.push(new Frame(f.indent, MFlat, sep, f.forceFlat, f.hardFlat));
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
							breakAfterWrap && !f.forceFlat ? lineCount : -1
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
				decisions?.push({ node: f.doc, crosses: f.mode == MBreak, indent: f.indent });
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
				decisions?.push({ node: f.doc, crosses: f.mode == MBreak, indent: col });
				stack.push(new Frame(f.indent, f.mode, inner, f.forceFlat, f.hardFlat));
			case CollapseChainProbe(inner):
				// ω-methodchain-reeval-after-callparam (CollapsePass increment 3,
				// subroot-E): a method-chain `IfFullLineExceeds(w, dotBreak, glued)`
				// tagged for the re-glue re-measure. Pure render pass-through (no
				// layout effect), EXACTLY like `CollapseBoolProbe`. In the
				// measure-only pass (`decisions != null`) record the ACTUAL VISUAL
				// COLUMN the marker sits at (`indent = col`, NOT `f.indent` — the
				// glued-first-line fit test needs the real column the chain tail is
				// measured against). Since ω-methodchain-all-or-nothing that column
				// is where the chain RECEIVER ENDS, not where it starts: `emit`
				// emits `Concat([receiver, <tagged decision>])`, so the pen has
				// already crossed the receiver when this frame is reached — which is
				// exactly why `CollapsePass.gluedFirstLineWidth` no longer adds the
				// receiver's own width. `CollapsePass.rewriteChainProbe` reads that
				// column and strips the chain dot-break (re-glues) when the full
				// glued flat overflows but the glued first line (last call's args
				// broken) fits at `col` — mirror fork
				// `reEvaluateMethodChainAfterCallParam`.
				if (decisions != null) {
					decisions.push({ node: f.doc, crosses: f.mode == MBreak, indent: col });
					// Sister entry keyed by the SAME probe node with `crosses ==
					// false` (`capturedIndent` requires `crosses`, so the two
					// probe-keyed entries never collide): the FRAME indent — the
					// base the dot-break shape's `Nest` is relative to.
					// `rewriteChainProbe` re-measures the last segment's own
					// continuation line against it (the visual `col` above
					// over-estimates a mid-line chain start). NOT keyed by `inner`
					// — the inner `IfFullLineExceeds` records its OWN decision
					// entry AFTER this one, and a find-first sister on the same
					// key would mask it for `opens()` (an isCandidate inner whose
					// dot-break branch embeds a `CollapseProbe` region).
					decisions.push({ node: f.doc, crosses: false, indent: f.indent });
				}
				stack.push(new Frame(f.indent, f.mode, inner, f.forceFlat, f.hardFlat));
			case _:
		}
	}

	/**
	 * Flush a pending `OptSpace` into `ctx.buf` at the current pen, first
	 * flushing any pending indent. A no-op when nothing is pending.
	 */
	private static function flushOptSpace(ctx: RenderCtx): Void {
		if (ctx.pendingOptSpace == null) return;
		// A held trailing blank run was emitted BEFORE this optional space, so it
		// has to reach the buffer first. Every path that commits an optional space
		// goes through here, which is what keeps the two slots ordered without each
		// caller knowing about both.
		flushTrailBlank(ctx);
		if (ctx.pendingIndent >= 0) {
			writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
			ctx.pendingIndent = -1;
		}
		ctx.buf.add(ctx.pendingOptSpace);
		ctx.col += ctx.pendingOptSpace.length;
		ctx.pendingOptSpace = null;
		ctx.lastEmit = Other;
	}

	/**
	 * Commit the blank run held back from the last non-verbatim `Text`.
	 *
	 * Called by every path that is about to append real content to the
	 * buffer, so the held bytes land in their original position; the line
	 * breaks call `ctx.pendingTrailBlank = null` instead, which is the whole
	 * mechanism — a trailing space only disappears when a newline is what
	 * follows it.
	 *
	 * The indent flush mirrors `flushOptSpace`: a run held from a leaf that
	 * committed no visible body (an all-blank `Text`) leaves `pendingIndent`
	 * standing, so the indent still has to precede these bytes.
	 */
	private static function flushTrailBlank(ctx: RenderCtx): Void {
		final held: Null<String> = ctx.pendingTrailBlank;
		if (held == null) return;
		if (ctx.pendingIndent >= 0) {
			writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
			ctx.pendingIndent = -1;
		}
		ctx.buf.add(held);
		ctx.pendingTrailBlank = null;
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
			// The newline is what follows the held blank run, so it never gets
			// written — this is the deferred hardline's share of the invariant.
			ctx.pendingTrailBlank = null;
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
	private static function emitText(ctx: RenderCtx, s: String, verbatim: Bool): Void {
		if (s.length <= 0) return;
		// ω-cond-indent-policy FixedZero: inside a
		// `ConditionalMarkerZero` scope, a fresh-line token that
		// starts with `#` is a preprocessor marker
		// (`#if`/`#elseif`/`#else`/`#end`) — flush it at column 0
		// regardless of the frame indent. Body lines (any other
		// first byte) keep their pending frame indent.
		final freshLine: Bool = ctx.lastEmit == Hardline && ctx.pendingOptSpace == null && ctx.pendingHardline < 0;
		if (ctx.markerZeroDepth > 0 && freshLine && ctx.pendingIndent > 0 && s.fastCodeAt(0) == '#'.code) {
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
		// Syntax carries its separator space INSIDE the token (`', '`, `': '`,
		// `'return '`, `'macro '`), so the only place that can stop such a space
		// from reaching a line end is here, where the run is still un-committed.
		// Verbatim content — a comment body's own trailing tab — is written whole:
		// the writer reproduces it, it is not the writer's to trim.
		final bodyEnd: Int = verbatim ? s.length : trailBlankStart(s);
		if (bodyEnd > 0) {
			flushTrailBlank(ctx);
			flushOptSpace(ctx);
			if (ctx.pendingIndent >= 0) {
				writeIndent(ctx.buf, ctx.pendingIndent, ctx.indentChar, ctx.tabWidth);
				ctx.pendingIndent = -1;
			}
			ctx.buf.add(bodyEnd == s.length ? s : s.substring(0, bodyEnd));
		} else if (ctx.pendingOptSpace != null) {
			// An all-blank leaf commits nothing, so a pending optional space would
			// be stranded AFTER the run it precedes. Fold it into the run instead
			// and charge its width here, which is what `flushOptSpace` would have
			// done — the two slots stay one ordered sequence and `col` is unmoved.
			ctx.pendingTrailBlank = (ctx.pendingTrailBlank ?? '') + ctx.pendingOptSpace;
			ctx.col += ctx.pendingOptSpace.length;
			ctx.pendingOptSpace = null;
		}
		if (bodyEnd < s.length) ctx.pendingTrailBlank = (ctx.pendingTrailBlank ?? '') + s.substring(bodyEnd);
		ctx.col += s.length;
		ctx.lastEmit = lastEmitFromText(s);
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
			// Only real bytes commit the held run: a zero-width flat `Line` writes
			// nothing, so a blank held before it stays held and the next break can
			// still drop it.
			if (flat.length > 0) flushTrailBlank(ctx);
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
			ctx.pendingTrailBlank = null;
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
					// Only the arm that actually writes `\n` drops the held blank
					// run; the two dropping arms above emit nothing, so a space
					// between two texts they sit between must survive.
					ctx.pendingTrailBlank = null;
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
							ctx.pendingTrailBlank = null;
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
				ctx.pendingOptSpace = if (!f.forceFlat && ctx.lastEmit == Hardline)
					null
				else if (ctx.pendingOptSpace == null)
					' '
				else
					'${ctx.pendingOptSpace} ';
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
			case Text(s, verbatim):
				emitText(ctx, s, verbatim == true);
			case Line(flat):
				emitLine(ctx, f, flat);
			case OptSpace(_), OptSpaceSkipAfterHardline, OptHardlineSkipBeforeHardline:
				emitOptSpaceVariants(ctx, f);
			case OptHardline, OptHardlineSkipAtOpenDelim:
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
		if (idx >= fillRest.length) return;
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
		final restW: Int = f.fillRestProbe && idx == fillRest.length - 1 ? flatTokenWidthOfRestStack(stack) : 0;
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
		// ω-fill-after-collection: a collection item dominates the line it
		// lands on, and its brackets are a structural boundary a reader
		// navigates by. Packing only SOME of the followers onto its tail puts
		// the break at an arbitrary width point instead — `[…], 155,` / `null`
		// rather than `[…],` / `155, null`. So once the previous item was a
		// collection, the rest either ALL fits on its line or ALL moves to the
		// next one.
		//
		// Scoped to the leading-break fill (`fillLineStart >= 0`, the
		// `FillBreakAfterWrap` ctor — the call-argument shape); a plain `Fill`
		// keeps its greedy packing byte-for-byte.
		// The LAST item of a leading-break fill (FillBreakAfterWrap;
		// `fillLineStart >= 0`) has no following item on its line -- the close
		// sits on its own line -- so the per-line trailing-comma component of
		// `tailReserve` must not bind it. Reserve only the genuine same-line
		// tail (an optional trailing comma, measured by
		// `flatTokenWidthOfRestStack`) plus the `+ 1` fork-`>=` boundary
		// alignment, the same term the shape's `sep.length + 1` reserve carries.
		// Without it a last param that fits broke onto its own line a column early.
		final effTailReserve: Int = f.fillLineStart >= 0 && idx == fillRest.length - 1 ? flatTokenWidthOfRestStack(stack) + 1 : tailReserve;
		// omega-fill-embedded-firstline: a fill item whose flat projection carries
		// an embedded `\n` inside a `Text` (a `#if … #end` token-splice raw) is a
		// multi-line token whose full flat width overflows any budget. Probe only
		// its FIRST line against the remaining column so the head packs onto the
		// current line (fork re-flows a splice operand this way) and the verbatim
		// newline breaks the rest; `-1` = no embedded break → the standard probe.
		// ω-fill-after-collection: the whole tail is measured against the
		// LAST item's reserve — the post-Fill content lands after it, not
		// after the item being probed now.
		final afterCollection: Bool = f.fillLineStart >= 0 && startsCollection(fillRest[idx - 1])
			&& !fitsFlat(width - ctx.col - flatTokenWidthOfRestStack(stack) - 1, f.indent, remainingFlat(fillRest, fillSep, idx));
		final embW: Int = embeddedFirstLineWidth(Concat([fillSep, fillRest[idx]]));
		final fits: Bool = !prevWrapped && !afterCollection && (
			embW >= 0
				? embW <= width - ctx.col
				: fitsFlat(width - ctx.col - effTailReserve - restW, f.indent, Concat([fillSep, fillRest[idx]]))
		);
		if (idx + 1 < fillRest.length) {
			// Snapshot the line where `fillRest[idx]` STARTS: when the
			// separator breaks (`!fits`) the item begins on the next
			// physical line, so the snapshot must account for that
			// break (which hasn't been emitted yet). Disabled-mode
			// (`fillLineStart < 0`) propagates `-1`.
			final nextStart: Int = if (f.fillLineStart < 0)
				-1
			else if (fits)
				ctx.lineCount
			else
				ctx.lineCount + 1;
			stack.push(
				Frame.fillCont(f.indent, fillRest, idx + 1, fillSep, tailReserve, f.forceFlat, f.fillRestProbe, f.hardFlat, nextStart)
			);
		}
		stack.push(new Frame(f.indent, MBreak, fillRest[idx], f.forceFlat, f.hardFlat));
		stack.push(new Frame(f.indent, fits ? MFlat : MBreak, fillSep, f.forceFlat, f.hardFlat));
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
				final picked: Doc = f.forceFlat || f.mode == MFlat ? flatDoc : breakDoc;
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
					final crosses: Bool = col + DocMeasure.flatTokenWidth(flatDoc) >= n;
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
					final firstLineCrosses: Bool = col + flatTokenWidthFirstLine(flatDoc) >= n;
					final pushMode: Mode = firstLineCrosses ? MBreak : f.mode;
					stack.push(new Frame(f.indent, pushMode, firstLineCrosses ? breakDoc : flatDoc));
				}
			case IfResidualLineExceeds(_, _, flatDoc) if (selfBreakingBraceBody(flatDoc)):
				// ω-arrow-block-body-open: an `IfResidualLineExceeds` is the
				// `@:fmt(arrowBodyLineWrap)` marker of a `->` / `=>` lambda
				// body. When that body opens with `{` and breaks IMMEDIATELY
				// after it — a multi-statement block, or a `{ … }` literal
				// whose own wrap cascade already committed to breaking — it
				// terminates the head line by itself. Take the flat side: the
				// break side buys nothing there, and the probe that would pick
				// it is measuring a different line.
				//
				// `selfBreakingBraceBody` states why each of its three
				// conjuncts is load-bearing, which fixture measured the hole
				// each one closes, and why a FLAT object-literal body — or one
				// whose hardline comes later than its `{` — must keep its break.
				//
				// Break side is useless for this population: it renders
				// `Nest(cols, Concat([hardline, body]))`, i.e. it moves the
				// body's opening `{` onto its own line and pushes the whole
				// body one indent deeper. The head line already ENDED at the
				// body's own forced hardline right after `{`, so nothing gets
				// shorter — the only effect is a stranded `->` / `{` pair
				// (`.onComplete(() ->\n\t{\n\t\t…`).
				//
				// Why the shared arm below mis-fires: its predicate adds
				// `flatTokenWidthOfRestStack(stack)`, the content that would
				// ride the SAME rendered line. For a self-breaking `{` body
				// that content actually lands on the body's CLOSING line
				// (`}).onUpdate(…)`), because the body hardlines right after
				// `{`. And `flatTokenWidth(flatDoc)` is ~0 for a statement
				// block (it sits behind a `BodyGroup`, which
				// `flatTokenWidthStep` defers to width 0), so the test
				// degenerates to `col + restOfStackWidth >= n` — the
				// discriminator becomes the TRAILING chain link's argument
				// width, which says nothing about the arrow.
				//
				// Why not at lowering: the emitted
				// `WrapBoundary(IfResidualLineExceeds(…))` signature is
				// load-bearing for `WrapList.isArrowBodyMarker` (8 consumer
				// sites) — `shapeMultiArgBlockLambda` WANTS block-bodied
				// arrows to match it, and `shapeSingleArgGlue` gates on
				// `!isArrowBodyMarker`. Dropping or reshaping the marker at
				// emit time silently flips both.
				//
				// The fork applies a related exclusion:
				// `MarkWrapping.applyArrowWrapping` skips arrows whose body
				// starts with `{` (`bodyFirst.match(BrOpen)`, issue_538), and
				// `WrapList` mirrors that `{`-only test in three sibling
				// paths — `shapeSoleArrowUniform`, the close-paren shape via
				// `arrowBodyIsBlock`, and the thin-arrow bare-ident leg. This
				// arm closes the one arrow path that never got the skip, but
				// deliberately asks the STRICTER question: those three siblings
				// pick between two shapes that both keep `{` glued, whereas
				// this one decides whether a break happens at all, so a flat
				// object literal must keep its break.
				//
				// The two NATURAL-walk resolutions of this marker
				// (`naturalGluableStructural` and the natural-width walk's
				// own `IfResidualLineExceeds` arm) need no gate for the
				// population this arm claims: neither carries a rest-stack
				// term, and a statement block sits behind a `BodyGroup` that
				// `flatTokenWidth` defers to 0, so their test reduces to
				// `col >= n` — already-blown lines only. MEASURED for that
				// population, not assumed: `final cb:Void->Void = () -> {`
				// with a ~340-char block body stays cuddled at col ~30. A
				// self-breaking OBJECT LITERAL body is not `BodyGroup`-
				// deferred, so those walks do see its width — which is why
				// the two conjuncts above must agree with them rather than
				// override them.
				//
				// Frame flags: `hardFlat` implies `forceFlat`, so forwarding
				// `f.forceFlat` / `f.hardFlat` reproduces BOTH pre-existing
				// flat paths byte-exactly — the `forceFlat` path pushes
				// `Frame(f.indent, f.mode, flatDoc, true, f.hardFlat)` and
				// the non-crossing path pushes
				// `Frame(f.indent, f.mode, flatDoc)` with both flags false.
				stack.push(new Frame(f.indent, f.mode, flatDoc, f.forceFlat, f.hardFlat));
			case IfLineExceeds(n, breakDoc, flatDoc), IfResidualLineExceeds(n, breakDoc, flatDoc):
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
					final lineCrosses: Bool = col + DocMeasure.flatTokenWidth(flatDoc) + flatTokenWidthOfRestStack(stack) >= n;
					final pushMode: Mode = lineCrosses ? MBreak : f.mode;
					stack.push(new Frame(f.indent, pushMode, lineCrosses ? breakDoc : flatDoc));
				}
			case _:
				// Unreachable: `pushExceedsBranch` routes only the five flat-width
				// probes here, and each has an arm above. A silent fall-through would
				// push NOTHING — the frame's whole subtree would vanish from the
				// output — so a new probe ctor routed here but not wired up must fail
				// loudly rather than delete code. (The compile-time net for adding a
				// `Doc` ctor sits on `render`'s own dispatch switch, which is
				// exhaustive; this guards the hand-written split BELOW it.)
				throw 'pushFlatWidthBranch: unrouted probe ctor ${f.doc.getName()}';
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
			case IfNaturalFirstLineExceeds(n, breakDoc, flatDoc), IfNaturalFirstLineExceedsWithRest(n, breakDoc, flatDoc):
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
					// ω-natural-trailwidth: hand the walk what rides the same line
					// after this probe's own doc — the statement terminator the
					// value's Doc does not contain. The rest-aware ctor is the
					// opt-in; which CONSUMER emitted it is the whole distinction
					// (the `return` body does, the assignment RHS does not), and
					// that cannot be read off the value, so it travels in the node.
					final trailWidth: Int = switch f.doc {
						case IfNaturalFirstLineExceedsWithRest(_, _, _): flatTokenWidthOfRestStack(stack);
						case _: 0;
					};
					final naturalCrosses: Bool = naturalFirstLineWidth(flatDoc, col, f.indent, width, true, trailWidth) >= n;
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
					final contFits: Bool = f.indent + extraIndent + flatWidth < n;
					final pushMode: Mode = contFits ? f.mode : MBreak;
					stack.push(new Frame(f.indent, pushMode, contFits ? flatDoc : breakDoc));
				}
			case IfGluedFirstLineExceeds(n, bodyIndent, breakDoc, flatDoc):
				// ω-glue-width: the body-glue width answer, three conjuncts deep.
				// Each one refuses a shape the previous two would have moved, and
				// each was measured on the two corpora before it went in.
				//
				// 1. Does the glued shape overflow? Same measurer as
				//    `IfNaturalFirstLineExceeds` — `naturalFirstLineWidth` folds
				//    `col` into its result, so the raw value is compared against `n`
				//    — but `<= n` FITS (the `Group` convention) where that sibling
				//    uses a strict `<`: this probe is calibrated to a whole rendered
				//    LINE against `maxLineLength`, and a line landing exactly on the
				//    limit is a line that fits.
				// 2/3. Is the move WORTH it? `brokenBodyIsWorthMoving` asks both
				//    remaining questions off one re-measure at the indent the break
				//    lands on, and it is called only when gate 1 fires — `&&` guards
				//    the second walk, not just its comparisons.
				//
				// `resolveOpenDelim` is left at its default `false`, where the
				// `IfNaturalFirstLineExceeds` sibling passes `true`. That flag makes
				// the walk resolve `IfNaturalFirstLineFitsOpenDelim` by its real
				// glue-vs-open predicate; turning it on here changes which shape one
				// probe family predicts, and no corpus site asked for it. Revisit it
				// with a measurement, not by matching the sibling.
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, f.mode, flatDoc, true, f.hardFlat));
				} else {
					final exceeds: Bool = naturalFirstLineWidth(flatDoc, col, f.indent, width) > n
						&& brokenBodyIsWorthMoving(flatDoc, f.indent + bodyIndent, n, width);
					stack.push(new Frame(f.indent, exceeds ? MBreak : f.mode, exceeds ? breakDoc : flatDoc));
				}
			case IfIndentWidthExceeds(flatWidth, n, breakDoc, flatDoc):
				// ω-case-sibling-symmetry: `flatWidth` is a build-time constant the
				// emitter supplies (the widest sibling's flat width), NOT a
				// measurement of `flatDoc` — that is what makes a set of siblings
				// rendered at the same indent reach ONE verdict without the
				// renderer seeing the set. Reads `f.indent`, never the live pen
				// column, so the answer is identical for every sibling and cannot
				// depend on the source's line shape. `<= n` fits, matching the
				// `Group` family (and unlike `IfArrowContinuationFits`'s strict
				// `<`, which is calibrated to a continuation line).
				if (f.forceFlat) {
					stack.push(new Frame(f.indent, f.mode, flatDoc, true, f.hardFlat));
				} else {
					final exceeds: Bool = f.indent + flatWidth > n;
					stack.push(new Frame(f.indent, exceeds ? MBreak : f.mode, exceeds ? breakDoc : flatDoc));
				}
			case _:
				// Unreachable, and the one of these tails most likely to be TESTED:
				// this helper owns the four PROBE FAMILY ctors the `Doc` header table
				// documents, so a new member lands here first. `pushExceedsBranch`
				// routes exactly five ctors in and every one has an arm above. Falling
				// through would push no frame and silently delete the node's subtree
				// from the output — same contract as its `pushFlatWidthBranch` sibling.
				throw 'pushNaturalBranch: unrouted probe ctor ${f.doc.getName()}';
		}
	}

	/**
	 * Widths of the FIRST and the LAST physical line of `d`'s flat projection
	 * WHEN that projection carries an embedded `\n` inside a `Text` leaf — a
	 * VERBATIM multi-line token such as a raw multi-line string literal or a
	 * `#if … #end` token-splice raw (`HxCondSpliceRaw`), whose bytes (source
	 * newlines included) are emitted through a single `Text`.
	 *
	 * `first` is the width up to (not including) the first embedded newline —
	 * what the token contributes to the line it starts on. `last` is the width
	 * accumulated after the token's final embedded newline: the token's own
	 * closing line plus everything the flat projection still emits after it,
	 * which rides that same physical line.
	 *
	 * `first` is `-1` when no embedded-`Text` newline is reached before a real
	 * hardline (`Line('\n')` / `OptHardline`) or the end of the walk. `last` is
	 * `-1` when a real hardline follows the embedded one — the tail is then laid
	 * out by that break rather than by the token, so this walk does not claim to
	 * know it and a caller reading `last` falls back to its standard probe.
	 *
	 * `condSpliceFirstLine` is the third measurement and answers the SAME
	 * question as `first` — how wide is the first physical line — for a doc
	 * whose break is a real hardline instead of a `Text`-embedded newline, and
	 * ONLY when a `#if` directive was emitted before that break. That gate is
	 * what keeps it a statement about conditional-compilation splice operands:
	 * `HxCondSpliceOpExpr` models a region `HxCondSpliceRaw` used to swallow
	 * verbatim, so the same operand now reaches a `Fill` with a hardline where
	 * it used to carry embedded bytes, and the packing probe has to recognise
	 * it as the same shape. `-1` when no such break was reached. `fitsFlat`
	 * does NOT read it: committing a hardline-bearing doc to flat would emit
	 * those hardlines unindented, which is exactly why `first`/`last` refuse.
	 *
	 * Interior lines are deliberately NOT measured: they are emitted byte for
	 * byte whatever the enclosing layout decides, so no wrap can shorten them.
	 *
	 * Constructor classification (what contributes width, what defers, what
	 * stops the walk) must stay in LOCKSTEP with `fitsFlatStep`: `fitsFlat`
	 * picks between the two per doc, so a divergence would answer the same
	 * question two ways.
	 *
	 * The NATURAL walk states the same rule for itself, in one arm rather than
	 * one function: `naturalWidthStep`'s `Text` arm stops its first-line
	 * accumulation at the embedded newline. It cannot delegate here — this walk
	 * resolves every `Group` flat while the natural one resolves each by its own
	 * `fitsFlat`, so the two disagree on where the first line ends whenever a
	 * Group breaks before the token. It needs no `last` either: an
	 * `IfNaturalFirstLineExceeds` measures only its own `flatDoc`, with no
	 * rest-stack lookahead, so nothing it can place rides the token's closing
	 * line.
	 *
	 * Consumers: `fitsFlat` (both halves — a `Group` around such a token stays
	 * flat when the line it opens and the line it closes both fit) and
	 * `embeddedFirstLineWidth` (the `Fill` packing probe, `first` alone).
	 */
	private static function embeddedLineWidths(d: Doc): EmbeddedLineWidths {
		final stack: Array<Doc> = [d];
		var total: Int = 0;
		var first: Int = -1;
		var condSpliceFirstLine: Int = -1;
		var sawCondDirective: Bool = false;
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			switch (node) {
				case Text(s):
					if (!sawCondDirective && s.ltrim().startsWith('#if')) sawCondDirective = true;
					final nl: Int = s.indexOf('\n');
					if (nl < 0) {
						total += s.length;
					} else {
						if (first < 0) first = total + nl;
						if (condSpliceFirstLine < 0 && sawCondDirective) condSpliceFirstLine = total + nl;
						// Restart the running width at the token's LAST verbatim
						// line: what follows rides that line, not a fresh indent.
						total = s.length - (s.lastIndexOf('\n') + 1);
					}
				case OptSpace(s):
					total += s.length;
				case OptSpaceSkipAfterHardline:
					total += 1;
				case Line(flat):
					if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) {
						if (condSpliceFirstLine < 0 && sawCondDirective) condSpliceFirstLine = total;
						return { first: first, last: -1, condSpliceFirstLine: condSpliceFirstLine };
					}
					total += flat.length;
				case OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline:
					if (condSpliceFirstLine < 0 && sawCondDirective) condSpliceFirstLine = total;
					return { first: first, last: -1, condSpliceFirstLine: condSpliceFirstLine };
				case Empty, BodyGroup(_):
					// Empty adds nothing; BodyGroup defers its own layout decision.
				case Concat(items):
					var i: Int = items.length;
					while (--i >= 0) stack.push(items[i]);
				case Fill(items, sep, _), FillWithRestProbe(items, sep, _), FillBreakAfterWrap(items, sep, _):
					var k: Int = items.length;
					while (k > 0) {
						k--;
						stack.push(items[k]);
						if (k > 0) stack.push(sep);
					}
				case Nest(_, inner), Group(inner), GroupWithRestProbe(inner), IfBreak(_, inner), IfWidthExceeds(_, _, inner),
					IfFirstLineExceeds(_, _, inner), IfLineExceeds(_, _, inner), IfResidualLineExceeds(_, _, inner),
					IfFullLineExceeds(_, _, inner), IfNaturalFirstLineExceeds(_, _, inner),
					IfNaturalFirstLineExceedsWithRest(_, _, inner), IfNaturalFirstLineFitsOpenDelim(_, _, inner),
					IfArrowContinuationFits(_, _, _, _, inner), IfIndentWidthExceeds(_, _, _, inner),
					IfGluedFirstLineExceeds(_, _, _, inner), Flatten(inner), WrapBoundary(inner), HardFlatten(inner),
					CollapseProbe(inner), CollapseAddProbe(inner), CollapseBoolProbe(inner), CollapseChainProbe(inner),
					ConditionalMarkerZero(inner), ConditionalMarkerDecrease(inner):
					stack.push(inner);
			}
		}
		return { first: first, last: total, condSpliceFirstLine: condSpliceFirstLine };
	}

	/**
	 * ω-fill-after-collection: does this fill item open with a collection
	 * delimiter (`[` array / comprehension, `{` object literal / anon type)?
	 *
	 * Structural, not width-based: the brackets are the boundary a reader
	 * navigates by, so the followers belong on one side of them or the other —
	 * never split across. `DocMeasure.firstVisibleTextStartsWith` walks to the
	 * first emitted byte, so a leading `Group` / `Nest` / wrap marker is
	 * transparent here.
	 */
	private static function startsCollection(item: Doc): Bool {
		final head: Null<String> = DocMeasure.firstVisibleText(item);
		if (head == null || head.length == 0) return false;
		final open: Int = StringTools.fastCodeAt(head, 0);
		if (open != '['.code && open != '{'.code) return false;
		// An EMPTY collection is not a boundary — `f({}, cb -> …)` has nothing
		// for the reader to navigate around, and pushing `cb` off its line only
		// strands a two-character `{},`. The writer emits an empty pair as ONE
		// `Text` carrying both delimiters, so it is exactly the token this walk
		// returns.
		final trimmed: String = StringTools.trim(head);
		return trimmed != '[]' && trimmed != '{}';
	}

	/**
	 * ω-fill-after-collection: `fillRest[idx…]` joined by `sep`, for the
	 * "does the WHOLE tail still fit on this line" probe.
	 */
	private static function remainingFlat(fillRest: Array<Doc>, sep: Doc, idx: Int): Doc {
		final parts: Array<Doc> = [];
		for (i in idx ... fillRest.length) {
			parts.push(sep);
			parts.push(fillRest[i]);
		}
		return Concat(parts);
	}

}
