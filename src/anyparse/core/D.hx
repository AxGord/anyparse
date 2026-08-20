package anyparse.core;

/**
 * Builder helpers for `Doc`.
 *
 * Kept as a short `D` class so that grammar writers can write
 * `D.group(D.concat([D.text("["), ...]))` without ceremony. All helpers
 * are `inline`, so at the call site they compile into direct `Doc`
 * constructor applications — no runtime cost.
 */
class D {

	/** Nothing. */
	public static inline function empty(): Doc return Empty;

	/** Literal string with no line breaks. */
	public static inline function text(s: String): Doc return Text(s);

	/** A potential break. In flat mode becomes a single space. */
	public static inline function line(): Doc return Line(' ');

	/** A potential break. In flat mode collapses to nothing. */
	public static inline function softline(): Doc return Line('');

	/** A mandatory break. Always forces a newline, even in flat mode. */
	public static inline function hardline(): Doc return Line('\n');

	/** Adds `n` columns of indentation to breaks inside `inner`. */
	public static inline function nest(n: Int, inner: Doc): Doc return Nest(n, inner);

	/** Wraps `inner` as a unit that the renderer will try to flatten. */
	public static inline function group(inner: Doc): Doc return Group(inner);

	/** Concatenates several docs in order. */
	public static inline function concat(items: Array<Doc>): Doc return Concat(items);

	/**
	 * Wadler `fillSep`. Packs `items` left-to-right joined by `sep`, breaking
	 * before any item that would overflow the current line. The `sep`'s
	 * `Line` becomes a hardline at the Fill's indent on overflow, and stays
	 * flat between items that fit.
	 */
	public static inline function fill(items: Array<Doc>, sep: Doc): Doc return Fill(items, sep);

	/**
	 * A run of items that packs when the line cannot hold it and stays a
	 * plain space-joined `Concat` when it can — `IfLineExceeds(threshold,
	 * Fill(items, Line(' ')), Concat(items joined by ' '))`, over the items
	 * that carry output. An `Empty` item is dropped rather than kept: a fill
	 * puts its separator between EVERY adjacent pair, so an `Empty` left in
	 * the list spends one on nothing and doubles the space (or the break) at
	 * that seam.
	 *
	 * WHY THE GLUED SIDE EXISTS AT ALL, given that a `Fill` whose items fit
	 * renders exactly the same bytes. Because a `Fill` does not MEASURE the
	 * same. Several probes walk a doc with the frame in `MBreak` and read a
	 * `Line` as a committed break — `Renderer.naturalFirstLineGluable` is the
	 * one that bites: it aborts the natural first line at the fill's first
	 * separator, so `WrapList.emitCondition` concludes the condition breaks
	 * and opens `if (` / `)` onto their own lines around a condition that fit
	 * on one. Measured, on `lime/system/System.hx:590`,
	 * `openfl/filesystem/File.hx:2244` and both
	 * `openfl/geom/PerspectiveProjection.hx` sites: four regions of 89-120
	 * columns against a 140 limit, all four opened. Those walkers descend the
	 * FLAT side of an `If*` probe, so gating the fill behind one hands every
	 * measurement the glued shape it saw before and keeps the fill for the
	 * case it was built for.
	 *
	 * `threshold` is the caller's line budget in the `>= n` convention the
	 * `If*Exceeds` family uses (pass `lineWidth + 1` to break on a strict
	 * overflow, so a run landing exactly on the limit stays glued).
	 */
	public static function fillOnOverflow(items: Array<Doc>, threshold: Int): Doc {
		final kept: Array<Doc> = [];
		for (item in items) switch item {
			case Empty:
			case _:
				kept.push(item);
		}
		if (kept.length == 0) return Empty;
		if (kept.length == 1) return kept[0];
		return IfLineExceeds(threshold, Fill(kept, Line(' ')), Concat(intersperse(kept, Text(' '))));
	}

	/**
	 * Optional inline whitespace, dropped when immediately followed by a
	 * break-mode `Line`. Used for lead trailing spaces that must vanish
	 * before a hardline (e.g. `leftCurly=Next`).
	 */
	public static inline function optSpace(s: String): Doc return OptSpace(s);

	/**
	 * Inline single space that drops when the last emitted output
	 * was a hardline. See `Doc.OptSpaceSkipAfterHardline` for the
	 * trade-off vs `OptSpace`.
	 */
	public static inline function optSpaceSkipAfterHardline(): Doc return OptSpaceSkipAfterHardline;

	/** Places `sep` between each item of `items`. Returns a fresh array. */
	public static function intersperse(items: Array<Doc>, sep: Doc): Array<Doc> {
		if (items.length <= 1) return items.copy();
		final result = [];
		for (i in 0...items.length) {
			if (i > 0) result.push(sep);
			result.push(items[i]);
		}
		return result;
	}

	/**
	 * Wadler-style `flatten`: structurally rewrites `d` into a Doc that
	 * renders as if the renderer were forced into MFlat mode for every
	 * Group / IfBreak / threshold-conditional. Unconditional hardlines
	 * (`Line("\n")`) collapse to `Empty` since their flat output `"\n"`
	 * would still break. Optional whitespace primitives (`OptSpace`,
	 * `OptHardline`, `OptHardlineSkipAtOpenDelim`,
	 * `OptHardlineSkipBeforeHardline`) reduce to their
	 * no-break inline form (`Text(s)` or `Empty`). `Nest` indent is
	 * dropped — irrelevant in flat mode.
	 *
	 * Used by writer-side overrides that force inline collapse of a
	 * body sub-tree regardless of width — e.g. fork's
	 * `expressionIfWithBlocks` knob collapses an if-expression's block
	 * body to a single line.
	 *
	 * Caveat: the transform is line-oriented, not syntax-aware. Inputs
	 * containing `// line comments` (Trivia mode) collapse the comment
	 * marker against the next token and break syntax. Caller is
	 * responsible for guarding against such inputs (or accepting the
	 * limitation, mirroring fork's behaviour).
	 */
	public static function flatten(d: Doc): Doc {
		final conditional: Null<Doc> = flattenConditional(d);
		return conditional ?? switch d {
			case Empty: Empty;
			case Text(_): d;
			case Line(flat): flat == '\n' ? Empty : Text(flat);
			case Nest(_, inner): flatten(inner);
			case Group(inner), GroupWithRestProbe(inner): flatten(inner);
			case BodyGroup(inner): flatten(inner);
			case Concat(items): Concat([for (i in items) flatten(i)]);
			case Fill(items, sep, _), FillWithRestProbe(items, sep, _), FillBreakAfterWrap(items, sep, _):
				final flatSep: Doc = flatten(sep);
				Concat(intersperse([for (i in items) flatten(i)], flatSep));
			case OptSpace(s): Text(s);
			case OptHardline, OptHardlineSkipAtOpenDelim, OptHardlineSkipBeforeHardline: Empty;
			case OptSpaceSkipAfterHardline:
				Text(' ');
			// ω-force-flat-engine slice A: all four markers collapse —
			// outer `flatten` already applies the force-flat transform, so
			// a nested `Flatten`/`HardFlatten`/`CollapseProbe` is idempotent
			// and a nested `WrapBoundary` is moot (we commit to flat at the
			// structural level).
			case Flatten(inner), WrapBoundary(inner), HardFlatten(inner), CollapseProbe(inner), CollapseAddProbe(inner),
				CollapseBoolProbe(inner), CollapseChainProbe(inner):
				flatten(inner);
			// ω-cond-indent-policy FixedZero: render-time marker, structurally
			// transparent to the flatten transform — descend `inner`. The
			// `#`-marker col-0 re-indent is render-only and moot under a forced-
			// flat collapse.
			case ConditionalMarkerZero(inner):
				flatten(inner);
			// ω-cond-indent-policy AlignedDecrease: render-time marker,
			// structurally transparent to the flatten transform — descend
			// `inner`. The uniform -1 re-indent is render-only and moot under a
			// forced-flat collapse.
			case ConditionalMarkerDecrease(inner): flatten(inner);
			case IfBreak(_, _), IfWidthExceeds(_, _, _), IfFirstLineExceeds(_, _, _), IfLineExceeds(_, _, _),
				IfResidualLineExceeds(_, _, _), IfFullLineExceeds(_, _, _), IfNaturalFirstLineExceeds(_, _, _),
				IfNaturalFirstLineExceedsWithRest(_, _, _), IfNaturalFirstLineFitsOpenDelim(_, _, _),
				IfArrowContinuationFits(_, _, _, _, _), IfIndentWidthExceeds(_, _, _, _), IfGluedFirstLineExceeds(_, _, _, _):
				// Handled above by `flattenConditional`; unreachable here, kept
				// only for switch exhaustiveness.
				Empty;
		};
	}

	/**
	 * Flatten a conditional `If*` kind by descending into its flat branch, or
	 * `null` when `d` is not an `If*`. Every variant forwards to its flat side —
	 * the broken branch is moot once an outer `flatten` commits to flat shape.
	 * Split out of `flatten` to keep it under the complexity threshold.
	 */
	private static function flattenConditional(d: Doc): Null<Doc> {
		return switch d {
			case IfBreak(_, fl): flatten(fl);
			case IfWidthExceeds(_, _, fl): flatten(fl);
			case IfFirstLineExceeds(_, _, fl): flatten(fl);
			case IfLineExceeds(_, _, fl): flatten(fl);
			case IfResidualLineExceeds(_, _, fl): flatten(fl);
			case IfFullLineExceeds(_, _, fl): flatten(fl);
			case IfNaturalFirstLineExceeds(_, _, fl), IfNaturalFirstLineExceedsWithRest(_, _, fl): flatten(fl);
			case IfNaturalFirstLineFitsOpenDelim(_, _, fl): flatten(fl);
			case IfArrowContinuationFits(_, _, _, _, fl), IfIndentWidthExceeds(_, _, _, fl), IfGluedFirstLineExceeds(_, _, _, fl): flatten(
				fl
			);
			case _: null;
		};
	}

}
