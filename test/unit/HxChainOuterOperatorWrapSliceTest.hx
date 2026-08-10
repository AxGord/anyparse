package unit;

import utest.Assert;
import utest.Test;

/**
 * omega-opadd-trailing-paren-break, T37 widening: a 2-operand `a OP (bare
 * paren)` whose rendered line overflows wraps at its OWN operator whenever the
 * paren operand fits the continuation line it would land on — the delimited
 * group stays intact and the break lands at the outer seam. Before T37 the arm
 * was gated on the paren wrapping a same-class opAddSub subexpression, so the
 * `'literal' + (ternary)` family fell through to the glue probe and broke
 * INSIDE the parens.
 *
 * The fixtures are anonymised, LENGTH-PRESERVING renames of the reported
 * `CloudDatabase` family and its shape-siblings — every decision here is a
 * width decision, so a shorter identifier would silently move the boundary.
 * Config mirrors `HxCallParamOuterFirstWrapSliceTest`: the same three cascades
 * (`callParameter`, `expressionWrapping`, `opAddSubChain`) at
 * `maxLineLength` 140.
 */
@:nullSafety(Strict)
final class HxChainOuterOperatorWrapSliceTest extends Test {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140,'
		+ ' "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"},'
		+ '{"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]},'
		+ ' "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]},'
		+ ' "opAddSubChain": {"defaultWrap": "noWrap", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"},'
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}}}';
	private static final HEAD: String = 'class Sample {\n\tprivate function query():Void {\n\t\ttry {\n';
	private static final TAIL: String = "\t\t} catch (exception:Exception) {\n\t\t\tlog('boom');\n\t\t}\n\t}\n}";
	private static final TERNARY: String = "(bucket ? '1 AND bucket_entry_id = $entryId' : '0 AND entry_id = $entryId')";

	public function new(): Void {
		super();
	}

	/**
	 * THE REPORTED SHAPE. The sole argument is `'<58-char literal>' + (ternary)`;
	 * flat on its own continuation line it measures 154 columns, so T20's
	 * flat-argument rung declines. The argument carries a top-level `+` whose
	 * tail is a bare paren that DOES fit its continuation (77 columns at the
	 * chain's indent), so the chain wraps there and the ternary's parens stay
	 * whole. Pre-T37 this glued the call open and broke inside the parens.
	 */
	public function testOverflowingSoleArgWrapsAtItsTopLevelOperator(): Void {
		final src: String = HEAD
			+ "\t\t\tfinal queryRows:RowCursor = _datasource.execute('SELECT itempath_movedfromsource FROM items WHERE bucket = ' + "
			+ '$TERNARY);\n$TAIL';
		final expected: String = '$HEAD\t\t\tfinal queryRows:RowCursor = _datasource.execute(\n'
			+ '\t\t\t\t\'SELECT itempath_movedfromsource FROM items WHERE bucket = \'\n\t\t\t\t+ $TERNARY\n\t\t\t);\n$TAIL';
		assertWrite(expected, src);
	}

	/**
	 * IDEMPOTENCY, the other direction: the pre-T37 GLUE layout of the fixture
	 * above converts to the operator wrap and then stays. Source-shape
	 * independence — the writer reaches the same fixed point from either input.
	 */
	public function testGluedSourceConvertsToTheOperatorWrap(): Void {
		final src: String = HEAD
			+ "\t\t\tfinal queryRows:RowCursor = _datasource.execute('SELECT itempath_movedfromsource FROM items WHERE bucket = ' + (\n"
			+ '\t\t\t\tbucket ? \'1 AND bucket_entry_id = $$entryId\' : \'0 AND entry_id = $$entryId\'\n\t\t\t));\n$TAIL';
		final expected: String = '$HEAD\t\t\tfinal queryRows:RowCursor = _datasource.execute(\n'
			+ '\t\t\t\t\'SELECT itempath_movedfromsource FROM items WHERE bucket = \'\n\t\t\t\t+ $TERNARY\n\t\t\t);\n$TAIL';
		assertWrite(expected, src);
	}

	/**
	 * T20 REGRESSION PIN — green before and after this slice, by design. The
	 * shape-sibling with a 16-character shorter literal: the argument fits FLAT on
	 * its continuation line, so T20's rung wins and the chain must not wrap at its
	 * operator. This and the reported shape above differ only in the literal
	 * length, which is what makes the pair a boundary rather than two unrelated
	 * shapes.
	 */
	public function testSoleArgFittingItsContinuationKeepsTheFlatArgument(): Void {
		final src: String = '$HEAD\t\t\tfinal queryRows:RowCursor = _datasource.execute(\'SELECT itempath FROM items WHERE bucket = \' + '
			+ '$TERNARY);\n$TAIL';
		final expected: String = '$HEAD\t\t\tfinal queryRows:RowCursor = _datasource.execute(\n'
			+ '\t\t\t\t\'SELECT itempath FROM items WHERE bucket = \' + $TERNARY\n\t\t\t);\n$TAIL';
		assertWrite(expected, src);
	}

	/**
	 * WIDTH BOUNDARY, fits edge — and a BUGFIX pin. The argument line measures
	 * EXACTLY 140 columns at its continuation indent, so it fits and stays flat.
	 * The pre-T37 gate was `IfLineExceeds(maxLineLength)`, which fires on `>=`
	 * over a column that is exact in a call-argument continuation (no pending
	 * `OptSpace`, no trailing `;` on that line): it broke a line that fits. The
	 * gate is now `IfFullLineExceeds(maxLineLength + 1)`, whose `n > width` form
	 * charges the pending space, so BOTH contexts read the physical line.
	 * Reverting the `+ 1` turns this red (together with T20's continuation
	 * pin); the ctor half is pinned at the statement context by
	 * `HxOpAddParenInnerBreakTest.testOpAddSubInnerParenBreaksBeforeLast`.
	 */
	public function testOpAddSubTailExactlyAtLineLimitKeepsTheFlatArgument(): Void {
		final src: String = 'class Sample {\n\tprivate function query():Void {\n'
			+ "\t\tfinal row:RowCursor = store.select('SELECT itempath FROM items WHERE bucket = xxxxxxxxxxxxxxxxxx'"
			+ ' + (slidePointerTrackingHorizontalX - originTrackingPointerBaseXx));\n\t}\n}';
		final expected: String = 'class Sample {\n\tprivate function query():Void {\n\t\tfinal row:RowCursor = store.select(\n'
			+ "\t\t\t'SELECT itempath FROM items WHERE bucket = xxxxxxxxxxxxxxxxxx'"
			+ ' + (slidePointerTrackingHorizontalX - originTrackingPointerBaseXx)\n\t\t);\n\t}\n}';
		assertWrite(expected, src);
	}

	/**
	 * WIDTH BOUNDARY, exceeds-by-one edge: one column wider than the fixture
	 * above, so the chain wraps at its operator. This one does NOT discriminate
	 * against reverting the slice — the pre-T37 engine produced the same bytes
	 * here (an opAddSub tail was already on this arm, one column too eagerly). It
	 * bounds the boundary from the other side: the pair must never render the same
	 * shape, and only the at-limit sibling proves which side moved.
	 */
	public function testOpAddSubTailOneColumnPastLineLimitWrapsAtTheOperator(): Void {
		final src: String = 'class Sample {\n\tprivate function query():Void {\n'
			+ "\t\tfinal row:RowCursor = store.select('SELECT itempath FROM items WHERE bucket = xxxxxxxxxxxxxxxxxxx'"
			+ ' + (slidePointerTrackingHorizontalX - originTrackingPointerBaseXx));\n\t}\n}';
		final expected: String = 'class Sample {\n\tprivate function query():Void {\n\t\tfinal row:RowCursor = store.select(\n'
			+ "\t\t\t'SELECT itempath FROM items WHERE bucket = xxxxxxxxxxxxxxxxxxx'\n"
			+ '\t\t\t+ (slidePointerTrackingHorizontalX - originTrackingPointerBaseXx)\n\t\t);\n\t}\n}';
		assertWrite(expected, src);
	}

	/**
	 * RUNG-4 FALLBACK, static prune. The operator continuation (`contWidth`)
	 * measures 150 columns, so it could not fit at ANY indent and the arm is skipped at
	 * lowering (`contWidth > maxLineLength`): the glue probe keeps the call
	 * hugged and the paren opens, exactly as before T37. The prune is not merely
	 * a render-time optimisation — the fits probe is slot-inverted, so an emitted
	 * but unfirable arm would still be what flat-side walkers see.
	 */
	public function testTailTooWideForAnyContinuationKeepsTheGlue(): Void {
		final wide: String = "(bucket ? '1 AND bucket_entry_id = ' : '0 AND "
			+ "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy')";
		final src: String =
			'$HEAD\t\t\tfinal queryRows:RowCursor = _datasource.execute(\'SELECT itempath FROM items WHERE bucket = \' + $wide);\n$TAIL';
		final expected: String = HEAD
			+ "\t\t\tfinal queryRows:RowCursor = _datasource.execute('SELECT itempath FROM items WHERE bucket = ' + (\n"
			+ "\t\t\t\tbucket\n\t\t\t\t\t? '1 AND bucket_entry_id = '\n"
			+ "\t\t\t\t\t: '0 AND yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy'\n"
			+ '\t\t\t));\n' + TAIL;
		assertWrite(expected, src);
	}

	/**
	 * SCOPE PIN: three operands keep the glue. The forced `OnePerLineAfterFirst`
	 * shape equals the fillLine-beforeLast one only for a single gap, so the arm
	 * stays at `items.length == 2` and a longer chain falls through unchanged —
	 * the same scope `HxOpAddTrailingParenGlueSliceTest` pins from its own side.
	 */
	public function testThreeOperandChainKeepsTheGlue(): Void {
		final src: String = HEAD
			+ "\t\t\tfinal queryRows:RowCursor = _datasource.execute('SELECT itempath ' + 'FROM items WHERE bucket = ' + "
			+ '$TERNARY);\n$TAIL';
		final expected: String = HEAD
			+ "\t\t\tfinal queryRows:RowCursor = _datasource.execute('SELECT itempath ' + 'FROM items WHERE bucket = ' + (\n"
			+ '\t\t\t\tbucket ? \'1 AND bucket_entry_id = $$entryId\' : \'0 AND entry_id = $$entryId\'\n\t\t\t));\n$TAIL';
		assertWrite(expected, src);
	}

	/**
	 * KNOWN RESIDUAL, pinned so a later slice notices when it closes. The
	 * operator continuation (`contWidth`) measures 135 columns: narrow enough to
	 * survive the static prune, too wide to fit at THIS indent, so the render
	 * correctly declines and
	 * the chain glues. The enclosing sole-argument call does not see that
	 * decision — `naturalGluableStructural` resolves `IfArrowContinuationFits`
	 * on its flat side, which is the SLOT-INVERTED forced-break shape here — so
	 * it reads a first line that does not end at an open delimiter and opens its
	 * own parens, costing one indent level against the pre-T37 hug. The band is
	 * `maxLineLength - indent - cols < contWidth <= maxLineLength`; it cannot be
	 * closed statically (the chain does not know its render indent) and closing
	 * it at the walker belongs to the Doc.hx slot-inversion follow-up. Measured
	 * occurrences on the TM tree and on anyparse's own corpus: zero.
	 */
	public function testTailOverflowingThisContinuationGluesButOpensTheCall(): Void {
		final tail: String = "(bucket ? '1 AND bucket_entry_id = ' : '0 AND "
			+ "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy')";
		final src: String =
			'$HEAD\t\t\tfinal queryRows:RowCursor = _datasource.execute(\'SELECT itempath FROM items WHERE bucket = \' + $tail);\n$TAIL';
		final expected: String = '$HEAD\t\t\tfinal queryRows:RowCursor = _datasource.execute(\n'
			+ "\t\t\t\t'SELECT itempath FROM items WHERE bucket = ' + (\n\t\t\t\t\tbucket\n" + "\t\t\t\t\t\t? '1 AND bucket_entry_id = '\n"
			+ "\t\t\t\t\t\t: '0 AND yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy'\n"
			+ '\t\t\t\t)\n\t\t\t);\n$TAIL';
		assertWrite(expected, src);
	}

	/** Writes `src` under `CFG`, asserts it equals `expected`, and asserts the result is a fixed point. */
	private function assertWrite(expected: String, src: String): Void {
		final out: String = triviaWrite(src);
		Assert.equals(expected, out);
		Assert.equals(out, triviaWrite(out));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CFG);
	}

}
