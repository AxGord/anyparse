package anyparse.format.wrap;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.format.ArrayMatrixWrap;

/**
 * Bottom-up grid layout for matrix-shaped array literals.
 *
 * Mirrors haxe-formatter's `MarkWrapping.tryMatrixWrap`: an array
 * literal whose source rows each carry the same number of elements is
 * laid out as a grid — one source row per output line — instead of
 * being reflowed one-element-per-line or width-packed. With the
 * `MatrixWrapWithAlign` policy each column is right-aligned by leading-
 * padding shorter cells to the column's widest element.
 *
 * The layout is a single pass: row boundaries come from the per-element
 * `rowStart` flags (derived from `Trivial<T>.newlineBefore` upstream),
 * column widths from each rendered cell's flat token width. No re-
 * measurement of the surrounding context is required — the helper never
 * inspects column position or parent layout, so it stays off the
 * single-pass-commit re-measure frontier.
 *
 * `tryLayout` returns `null` when the elements do not form a matrix
 * (fewer than two columns, ragged rows, or any multi-line cell); the
 * caller then falls through to the normal wrap cascade.
 */
final class MatrixWrap {

	/**
	 * Attempts a grid layout. Returns the grid `Doc` on success or
	 * `null` when the input is not a uniform matrix.
	 *
	 *  - `items` — rendered per-element Docs, in source order.
	 *  - `rowStart` — length-aligned with `items`; `rowStart[i]` is true
	 *    when element `i` began a new source line (element 0 is always
	 *    a row start). Drives row segmentation.
	 *  - `mode` — `MatrixWrapNoAlign` keeps the grid without column
	 *    padding; `MatrixWrapWithAlign` right-aligns columns. `NoMatrix-
	 *    Wrap` must be filtered by the caller (never reaches here).
	 *  - `open` / `close` / `sep` — the bracket and separator literals.
	 *  - `appendTrailingComma` — emit a separator after the final element.
	 *  - `cols` — continuation indent (columns) for the grid body Nest.
	 */
	public static function tryLayout(
		items: Array<Doc>, rowStart: Array<Bool>, mode: ArrayMatrixWrap, open: String, close: String, sep: String,
		appendTrailingComma: Bool, cols: Int
	): Null<Doc> {
		final n: Int = items.length;
		if (n < 2) return null;

		// Column count = run length of the first source row. All
		// subsequent rows (including the final one) must match.
		var lineRun: Int = 0;
		for (i in 0...n) {
			if (rowStart[i] && lineRun == 0 && i > 0) lineRun = i;
			if (isMultiline(items[i])) return null;
		}
		// Single row (no interior break) → not a matrix.
		if (lineRun <= 1) return null;
		// Total must split into whole rows of `lineRun` columns, and
		// every interior break must land exactly on a row boundary.
		if (n % lineRun != 0) return null;
		for (i in 0...n) if (rowStart[i] != (i % lineRun == 0)) return null;

		// Per-column max bare width (no separator).
		final widths: Array<Int> = [for (i in 0...n) DocMeasure.flatTokenWidth(items[i])];
		final maxCols: Array<Int> = [for (c in 0...lineRun) 0];
		for (i in 0...n) {
			final c: Int = i % lineRun;
			if (widths[i] > maxCols[c]) maxCols[c] = widths[i];
		}

		final align: Bool = mode == MatrixWrapWithAlign;
		final body: Array<Doc> = [];
		final lastIdx: Int = n - 1;
		for (i in 0...n) {
			final c: Int = i % lineRun;
			if (c == 0) body.push(Line('\n'));
			if (align) {
				final pad: Int = maxCols[c] - widths[i];
				if (pad > 0) body.push(Text(spaces(pad)));
			}
			body.push(items[i]);
			final isLast: Bool = i == lastIdx;
			if (!isLast || appendTrailingComma) body.push(Text(sep));
			// Single space between cells within a row (after the sep),
			// never at the row's trailing edge.
			if (!isLast && c != lineRun - 1) body.push(Text(' '));
		}
		return Concat([Text(open), Nest(cols, Concat(body)), Line('\n'), Text(close)]);
	}

	private static function spaces(n: Int): String {
		final buf: StringBuf = new StringBuf();
		for (_ in 0...n) buf.add(' ');
		return buf.toString();
	}

	/**
	 * True when the rendered cell carries a forced line break and so
	 * cannot sit inline in a grid row. Mirrors fork's `item.multiline`.
	 */
	private static function isMultiline(d: Doc): Bool {
		final stack: Array<Doc> = [d];
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			switch node {
				case Empty | Text(_) | OptSpace(_) | OptSpaceSkipAfterHardline:
				case Line(flat):
					if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code)
						return true;
				case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
					return true;
				case Nest(_, inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
					inner
				) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
					inner
				) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
				case Concat(parts):
					for (p in parts) stack.push(p);
				case Fill(parts, sep, _) | FillWithRestProbe(parts, sep, _) | FillBreakAfterWrap(parts, sep, _):
					for (p in parts) stack.push(p);
					stack.push(sep);
				case IfBreak(brk, flat) | IfWidthExceeds(_, brk, flat) | IfFirstLineExceeds(_, brk, flat) | IfLineExceeds(_, brk, flat) | IfFullLineExceeds(
					_, brk, flat
				) | IfNaturalFirstLineExceeds(_, brk, flat) | IfNaturalFirstLineFitsOpenDelim(_, brk, flat) | IfArrowContinuationFits(
					_, _, _, brk, flat
				):
					stack.push(brk);
					stack.push(flat);
			}
		}
		return false;
	}

}
