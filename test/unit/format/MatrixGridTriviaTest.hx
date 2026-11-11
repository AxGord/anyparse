package unit.format;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * A source grid of an array literal keeps its rows when a blank line or a comment sits between them.
 *
 * Under `arrayMatrixWrap` a uniform grid is laid out row by row, but a blank line or a comment anywhere in the list
 * used to send it down the one-element-per-line path, so a sixteen-column table came out one value per line. The
 * grid owns the row breaks; a blank line or an own-line comment sits before a row, a trailing comment after one.
 * A list that is not a grid still follows the `arrayWrap` rules.
 */
@:nullSafety(Strict)
class MatrixGridTriviaTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	/** The reported config: an unaligned grid, and lists of two complex items and a hundred columns go one per line. */
	private static final NO_ALIGN_JSON: String = '{"wrapping":{"arrayMatrixWrap":"matrixWrapNoAlign","arrayWrap":{"defaultWrap":"fillLine",'
		+ '"rules":[{"conditions":[{"cond":"complexItemCount >= n","value":2},{"cond":"totalItemLength >= n","value":100}],'
		+ '"type":"onePerLine"}]}}}';

	/** The same cascade with the default aligned grid. */
	private static final ALIGN_JSON: String = '{"wrapping":{"arrayWrap":{"defaultWrap":"fillLine",'
		+ '"rules":[{"conditions":[{"cond":"complexItemCount >= n","value":2},{"cond":"totalItemLength >= n","value":100}],'
		+ '"type":"onePerLine"}]}}}';

	/**
	 * A pure `noWrap` cascade, whose source-broken lists flatten unless they form a grid.
	 */
	private static final NO_WRAP_JSON: String =
		'{"wrapping":{"arrayMatrixWrap":"matrixWrapNoAlign","arrayWrap":{"defaultWrap":"noWrap","rules":[]}}}';

	/** The reported rules with no `defaultWrap`: the list falls back on `Ignore`, where the source rows are not read. */
	private static final IGNORE_JSON: String = '{"wrapping":{"arrayMatrixWrap":"matrixWrapNoAlign","arrayWrap":{'
		+ '"rules":[{"conditions":[{"cond":"complexItemCount >= n","value":2},{"cond":"totalItemLength >= n","value":100}],'
		+ '"type":"onePerLine"}]}}}';

	/** The reported cascade with the grid turned off. */
	private static final NO_MATRIX_JSON: String = '{"wrapping":{"arrayMatrixWrap":"noMatrixWrap","arrayWrap":{"defaultWrap":"fillLine",'
		+ '"rules":[{"conditions":[{"cond":"complexItemCount >= n","value":2},{"cond":"totalItemLength >= n","value":100}],'
		+ '"type":"onePerLine"}]}}}';

	/** A two-row grid with a blank line between its rows. */
	private static final SMALL_BLANK: String = 'class C {\n\tstatic final G:Array<Int> = [\n\t\t1, 2, 3,\n\n\t\t4, 5, 6\n\t];\n}\n';

	/** The same rows one element per line, the blank kept. */
	private static final SMALL_BLANK_ONE_PER_LINE: String =
		'class C {\n\tstatic final G:Array<Int> = [\n\t\t1,\n\t\t2,\n\t\t3,\n\n\t\t4,\n\t\t5,\n\t\t6\n\t];\n}\n';

	private static final ROW_0: String = '-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,';
	private static final ROW_1: String = '-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 62, -1, -1, -1, 63,';
	private static final ROW_2: String = '52, 53, 54, 55, 56, 57, 58, 59, 60, 61, -1, -1, -1, -1, -1, -1,';
	private static final ROW_3: String = '-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14';
	private static final NAMES_0: String = "'name01', 'name02', 'name03', 'name04', 'name05', 'name06', 'name07',";
	private static final NAMES_1: String = "'name11', 'name12', 'name13', 'name14', 'name15', 'name16', 'name17',";
	private static final NAMES_2: String = "'name21', 'name22', 'name23', 'name24', 'name25', 'name26', 'name27',";
	private static final NAMES_3: String = "'name31', 'name32', 'name33', 'name34', 'name35', 'name36', 'name37',";
	private static final NAMES_4: String = "'name41', 'name42', 'name43', 'name44', 'name45', 'name46', 'name47'";

	@:pin('guard')
	public function testUniformNumericGridKeepsItsRows(): Void {
		final source: String = table([ROW_0, ROW_1, ROW_2, ROW_3]);
		Assert.equals(source, write(source, NO_ALIGN_JSON));
	}

	@:pin('guard')
	public function testUniformStringGridKeepsItsRows(): Void {
		final source: String = names([NAMES_0, NAMES_1, NAMES_2, NAMES_3, NAMES_4]);
		Assert.equals(source, write(source, NO_ALIGN_JSON));
	}

	@:pin('control')
	@:killer('M-MATRIX-TRIVIA-GRID-OFF')
	public function testBlankLineBetweenRowsKeepsTheGrid(): Void {
		final source: String = table([ROW_0, ROW_1, '', ROW_2, ROW_3]);
		Assert.equals(source, write(source, NO_ALIGN_JSON));
	}

	@:pin('control')
	@:killer('M-MATRIX-TRIVIA-ROW-BREAKS')
	public function testTrailingCommentAfterARowKeepsTheGrid(): Void {
		final source: String = table(['$ROW_0 // invalid', '$ROW_1 // plus and slash', ROW_2, '$ROW_3 // last']);
		Assert.equals(source, write(source, NO_ALIGN_JSON));
	}

	@:pin('control')
	@:killer('M-MATRIX-TRIVIA-NO-LEAD-COMMENT')
	public function testOwnLineCommentBeforeARowKeepsTheGrid(): Void {
		final source: String = names([
			NAMES_0,
			NAMES_1,
			'// second group',
			NAMES_2,
			NAMES_3,
			'',
			'// third group',
			NAMES_4
		]);
		Assert.equals(source, write(source, NO_ALIGN_JSON));
	}

	@:pin('control')
	@:killer('M-MATRIX-TRIVIA-NO-PAD')
	public function testAlignedGridWithABlankLinePadsItsColumns(): Void {
		final source: String = 'class C {\n\tstatic final G:Array<Int> = [\n\t\t1, 22, 3,\n\n\t\t333, 4, 55\n\t];\n}\n';
		final expected: String = 'class C {\n\tstatic final G:Array<Int> = [\n\t\t  1, 22,  3,\n\n\t\t333,  4, 55\n\t];\n}\n';
		Assert.equals(expected, write(source, ALIGN_JSON));
	}

	/**
	 * A block comment glued to a cell inside a row rides in that row: the second of two comments after a comma leads the next cell.
	 */
	@:pin('control')
	@:killer('M-MATRIX-TRIVIA-GLUED-LEAD')
	public function testGluedCommentInsideARowKeepsTheGrid(): Void {
		final source: String = 'class C {\n\tstatic final G:Array<Int> = [\n\t\t1, 22, /* a */ /* b */ 3,\n\t\t444, 5, 66\n\t];\n}\n';
		Assert.equals(source, write(source, NO_ALIGN_JSON));
	}

	/** Under a pure `noWrap` cascade a grid holding a blank line or a trailing comment keeps its rows rather than flattening. */
	@:pin('control')
	@:killer('M-MATRIX-TRIVIA-NOWRAP-FLATTENS')
	public function testNoWrapCascadeKeepsAGridWithTrivia(): Void {
		Assert.equals(SMALL_BLANK, write(SMALL_BLANK, NO_WRAP_JSON));
		final commented: String = 'class C {\n\tstatic final H:Array<Int> = [\n\t\t1, 2, 3, // a\n\t\t4, 5, 6\n\t];\n}\n';
		Assert.equals(commented, write(commented, NO_WRAP_JSON));
	}

	/** The `Ignore` fallback reads no source rows, so a grid with a blank line goes one element per line. */
	@:pin('guard')
	public function testIgnoreFallbackDoesNotReadTheGrid(): Void {
		Assert.equals(SMALL_BLANK_ONE_PER_LINE, write(SMALL_BLANK, IGNORE_JSON));
	}

	/** `noMatrixWrap` reads no grid, so a grid with a blank line goes one element per line. */
	@:pin('guard')
	public function testNoMatrixWrapDoesNotReadTheGrid(): Void {
		Assert.equals(SMALL_BLANK_ONE_PER_LINE, write(SMALL_BLANK, NO_MATRIX_JSON));
	}

	@:pin('guard')
	public function testRaggedComplexListFollowsTheRules(): Void {
		final source: String = 'class C {\n\tstatic final L:Array<Int> = [\n\t\tcompute(1, 2), compute(2, 2), compute(3, 2), compute(4, '
			+ '2), compute(5, 2),\n\t\tcompute(6, 2), compute(7, 2), compute(8, 2)\n\t];\n}\n';
		final expected: String = 'class C {\n\tstatic final L:Array<Int> = [\n'
			+ [for (i in 1...9) '\t\tcompute($i, 2)' + (i < 8 ? ',' : '')].join('\n')
			+ '\n\t];\n}\n';
		Assert.equals(expected, write(source, NO_ALIGN_JSON));
	}

	@:pin('guard')
	public function testRaggedListWithABlankLineStaysOnePerLine(): Void {
		final source: String = 'class C {\n\tstatic final L:Array<Int> = [\n\t\t1, 2, 3,\n\n\t\t4, 5\n\t];\n}\n';
		final expected: String = 'class C {\n\tstatic final L:Array<Int> = [\n\t\t1,\n\t\t2,\n\t\t3,\n\n\t\t4,\n\t\t5\n\t];\n}\n';
		Assert.equals(expected, write(source, NO_ALIGN_JSON));
	}

	private static function table(rows: Array<String>): String {
		return wrapRows('BIG:Array<Int>', rows);
	}

	private static function names(rows: Array<String>): String {
		return wrapRows('NAMES:Array<String>', rows);
	}

	private static function wrapRows(head: String, rows: Array<String>): String {
		return 'class C {\n\tstatic final $head = [\n' + rows.map(row -> row == '' ? '' : '\t\t$row').join('\n') + '\n\t];\n}\n';
	}

	private static function write(source: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
