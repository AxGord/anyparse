package anyparse.format;

/**
 * Layout policy for matrix-shaped array literals (array-of-rows where
 * every source row carries the same number of elements).
 *
 * A matrix is detected from the original source line structure: when an
 * array literal is written with N elements per source line over two or
 * more uniform rows (e.g. a 4x4 transform laid out one row per line),
 * the writer can preserve that grid instead of reflowing the elements
 * one-per-line or width-packing them.
 *
 * `MatrixWrapWithAlign` — preserve the grid AND right-align each column:
 * every cell is leading-padded so the column's elements line up on their
 * right edge. This is the default; it matches haxe-formatter's
 * `wrapping.arrayMatrixWrap = "matrixWrapWithAlign"`.
 *
 * `MatrixWrapNoAlign` — preserve the grid (rows kept as in source) but
 * emit no column padding; cells are separated by a single space after
 * the separator.
 *
 * `NoMatrixWrap` — disable matrix detection entirely. The array literal
 * falls through to the normal wrap cascade: it collapses flat when it
 * fits and width-packs (fill) when it overflows, ignoring the source
 * grid.
 *
 * Format-neutral — lives in `anyparse.format` so grammars for other
 * curly-brace languages reusing array-of-rows literals can share it.
 */
enum abstract ArrayMatrixWrap(Int) from Int to Int {

	final NoMatrixWrap = 0;

	final MatrixWrapNoAlign = 1;

	final MatrixWrapWithAlign = 2;

	/**
	 * Resolves the config string (`hxformat.json`
	 * `wrapping.arrayMatrixWrap`) into a policy value. Unknown strings
	 * return `null` so callers fall back to the runtime default.
	 */
	@:from public static function resolve(name: String): Null<ArrayMatrixWrap> {
		return switch name {
			case 'noMatrixWrap': NoMatrixWrap;
			case 'matrixWrapNoAlign': MatrixWrapNoAlign;
			case 'matrixWrapWithAlign': MatrixWrapWithAlign;
			case _: null;
		};
	}

}
