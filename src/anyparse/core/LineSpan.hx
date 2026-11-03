package anyparse.core;

/**
 * The one answer to "has the pen left the line this construct began on".
 *
 * Only the renderer knows that, and only once what precedes has been written: `begin` records the line, `ifLeft`
 * reads it. Both are `IfIndentWidthExceeds` widths in the negative band no width can reach, so every static walker
 * reads them as the flat form it already forwards to, and only the render loop tells them apart (`holds`). A
 * multi-line token counts as leaving the line. A construct nested in the span overwrites the record with a later
 * line, and it ends on a later line still, so the reader's answer stands.
 */
final class LineSpan {

	private static inline final BEGIN: Int = -2;
	private static inline final LEFT: Int = -3;

	/** Records the line the pen is on; renders nothing. */
	public static inline function begin(): Doc {
		return Doc.IfIndentWidthExceeds(BEGIN, 0, Doc.Empty, Doc.Empty);
	}

	/** `left` when a line break was written since the last `begin`, else `same`; `same` too with no `begin` in this render. */
	public static inline function ifLeft(left: Doc, same: Doc): Doc {
		return Doc.IfIndentWidthExceeds(LEFT, 0, left, same);
	}

	/** Whether an `IfIndentWidthExceeds` width is one of these rather than a width or a sibling vote. */
	public static inline function holds(width: Int): Bool {
		return width == BEGIN || width == LEFT;
	}

	/** Whether `width`, which `holds`, is the record rather than the read. */
	public static inline function isBegin(width: Int): Bool {
		return width == BEGIN;
	}

}
