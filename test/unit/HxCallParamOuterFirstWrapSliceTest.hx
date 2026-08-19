package unit;

import utest.Assert;
import utest.Test;

/**
 * omega-outer-first-wrap: for a call whose SOLE argument overflows, the writer
 * prefers the OUTERMOST break boundary. Breaking at the call's own parens with
 * the argument rendered FLAT on its continuation line wins over hugging the
 * call and letting a nested paren group break inside the argument.
 *
 * The defect this closes: `WrapList.shapeSingleArgGlue` resolved a sole
 * `fillLineWithLeadingBreak` argument with `IfNaturalFirstLineFitsOpenDelim`
 * alone, which glues the prefix whenever the argument's natural first line
 * ends at an open delimiter. A `'literal' + (ternary)` argument satisfies that
 * test for the wrong reason — the first line ends at `(` only BECAUSE the inner
 * paren decided to open at the hugged column. The call therefore stayed glued
 * and the break landed one level too deep, even though opening the call parens
 * would have put the whole argument on one fitting line.
 *
 * The fix is an outer-first probe ahead of the glue decision: when
 * `indent + oneIndent + flatWidth(arg)` fits `maxLineLength`, commit to the
 * open-paren shape; otherwise fall through to the unchanged glue decision.
 * `flatLength` is the measure — it DESCENDS `BodyGroup` and answers `-1` on a
 * forced hardline, so an argument that cannot be one line never qualifies.
 *
 * SCOPE. The priority governs a CALL-level wrap competing with a nested PAREN
 * group. A `[`-leading sole argument (array literal / comprehension) is
 * excluded: a bracket-delimited collection owns its own multi-line layout and
 * the call hugs it — that policy predates this slice and is pinned by
 * `HxComprehensionDeclRhsBracketWrapTest` plus the negative fixture below.
 * `{`-leading object literals already took an equivalent continuation-fit
 * probe before this slice and are untouched.
 *
 * BOUNDARY. The threshold is `maxLineLength + 1` against the arm's strict
 * `<`, i.e. a continuation line landing exactly ON the limit still fits. Both
 * edges are pinned: at the limit the parens open, one column past them the
 * decision falls through. Neither fixture is redundant — narrowing the
 * threshold to `maxLineLength` turns the at-limit fixture red, widening it to
 * `maxLineLength + 2` turns the past-limit one red (verified by editing the
 * constant, not only by reverting the slice).
 *
 * Fixture sources are anonymised, length-preserving renames of a real project
 * tree; every case asserts a fixed point as well as the shape.
 *
 * The fixture literals are DOUBLE-quoted on purpose and stay that way: several
 * carry a `$entryId` / `$rowId` that single quotes would interpolate, silently
 * changing the bytes under test. `prefer-single-quotes` and
 * `fold-adjacent-string-literals` therefore report ~130 advisories against
 * this file (info severity, hidden without `--all`). They are left
 * unsuppressed deliberately: the only region-scoped suppression the linter
 * offers takes no rule names, so silencing them would blind every other check
 * over the fixtures too.
 */
@:nullSafety(Strict)
final class HxCallParamOuterFirstWrapSliceTest extends Test {

	/**
	 * Project-shaped config: tab indent, `maxLineLength` 140, and the three
	 * cascades this decision reads — `callParameter` (fillLineWithLeadingBreak
	 * with the noWrap-when-it-fits and single-short-arg rules),
	 * `expressionWrapping` (what opens the nested paren) and `opAddSubChain`.
	 */
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140,'
		+ ' "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"},'
		+ '{"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]},'
		+ ' "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]},'
		+ ' "opAddSubChain": {"defaultWrap": "noWrap", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"},'
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}}}';

	public function new(): Void {
		super();
	}

	/**
	 * The motivating shape. The argument is `'literal' + (ternary)`; hugged, its
	 * natural first line ends at the nested `(` so the pre-slice engine glued the
	 * call and broke inside the paren. Opening the call parens instead puts the
	 * whole argument on one 138-column line, so that is what the writer now picks.
	 */
	public function testSoleArgFittingAtContinuationOpensTheCallParens(): Void {
		final src: String = 'class OuterFits {\n\tprivate function load():Void {\n\t\ttry {\n\t\t\tfinal resultSet:ResultSet = '
			+ "_datasource.execute('SELECT filepath FROM files WHERE bucket = ' + (bucket ? '1 AND bucket_plain_id = $entryId' : '0 AND "
			+ "plain_id = $entryId'));\n\t\t} catch (exception:Exception) {\n\t\t\tlog('boom');\n\t\t}\n\t}\n}";
		final expected: String = 'class OuterFits {\n\tprivate function load():Void {\n\t\ttry {\n'
			+ '\t\t\tfinal resultSet:ResultSet = _datasource.execute(\n'
			+ "\t\t\t\t'SELECT filepath FROM files WHERE bucket = ' + (bucket ? '1 AND bucket_plain_id = $entryId' : '0 AND "
			+ "plain_id = $entryId')\n\t\t\t);\n\t\t} catch (exception:Exception) {\n\t\t\tlog('boom');\n\t\t}\n\t}\n}";
		assertWrite(expected, src);
	}

	/**
	 * The counter-case, from the same real file: a three-operand chain whose
	 * argument is far too wide for any continuation line. The outer-first probe
	 * declines, the decision falls through unchanged, and the nested paren keeps
	 * the break. NEGATIVE pin — byte-identical round-trip, it holds with the
	 * slice reverted; it exists to state that an argument that cannot be flattened
	 * onto its own line is not dragged into the new shape.
	 */
	public function testSoleArgOverflowingContinuationKeepsTheNestedParenBreak(): Void {
		final src: String = 'class OuterOverflows {\n\tprivate function assign():Void {\n\t\ttry {\n\t\t\t_datasource.execute(\'UPDATE '
			+ "files SET ' + (\n\t\t\t\tbucket\n\t\t\t\t\t? 'plain_id = NULL, bucket_plain_id = $entryId WHERE bucket = 1'\n"
			+ "\t\t\t\t\t: 'bucket_plain_id = NULL, plain_id = $entryId WHERE bucket = 0'\n\t\t\t) + ' AND filepath = "
			+ "${_datasource.quote(itemPath)}');\n\t\t} catch (exception:Exception) {\n\t\t\tlog('boom');\n\t\t}\n\t}\n}";
		assertWrite(src, src);
	}

	/**
	 * Fits edge: the argument's continuation line measures EXACTLY
	 * `maxLineLength`. It fits, so the parens open. Narrowing the probe's
	 * threshold to `maxLineLength` (dropping the `+ 1`) turns this red.
	 */
	public function testContinuationExactlyAtLineLimitOpensTheCallParens(): Void {
		final src: String = 'class EdgeAtLimit {\n\tprivate function edge():Void {\n'
			+ "\t\tfinal row:ResultRow = store.query('SELECT filepath FROM files WHERE folder = xxxxxxxxxxxxxxxxxxx' + ("
			+ 'flag ? \'1 AND folder_id = $$rowId\' : \'0 AND plain_id = $$rowX\'));\n\t}\n}';
		final expected: String = 'class EdgeAtLimit {\n\tprivate function edge():Void {\n\t\tfinal row:ResultRow = store.query(\n'
			+ "\t\t\t'SELECT filepath FROM files WHERE folder = xxxxxxxxxxxxxxxxxxx' + ("
			+ 'flag ? \'1 AND folder_id = $$rowId\' : \'0 AND plain_id = $$rowX\')\n\t\t);\n\t}\n}';
		assertWrite(expected, src);
	}

	/**
	 * Fits+1 edge, RE-PINNED (T37). One column wider than the fixture above, so the
	 * argument would be 141 columns on its continuation line and T20 flat-argument
	 * rung declines. The argument carries a top-level binary seam whose tail is a bare
	 * paren, so the next rung applies: the call still opens and the argument wraps at
	 * its own `+`, leaving the paren group intact — instead of the pre-T37 glue that
	 * broke INSIDE the paren. The at-limit sibling above is the discriminator for the
	 * boundary: these two must never render the same shape.
	 */
	public function testContinuationOneColumnPastLineLimitWrapsAtTheOperator(): Void {
		final src: String = 'class EdgePastLimit {\n\tprivate function edge():Void {\n'
			+ "\t\tfinal row:ResultRow = store.query('SELECT filepath FROM files WHERE folder = xxxxxxxxxxxxxxxxxxxx' + ("
			+ 'flag ? \'1 AND folder_id = $$rowId\' : \'0 AND plain_id = $$rowX\'));\n\t}\n}';
		final expected: String = 'class EdgePastLimit {\n\tprivate function edge():Void {\n\t\tfinal row:ResultRow = store.query(\n'
			+ "\t\t\t'SELECT filepath FROM files WHERE folder = xxxxxxxxxxxxxxxxxxxx'\n"
			+ "\t\t\t+ (flag ? '1 AND folder_id = $rowId' : '0 AND plain_id = $rowX')\n\t\t);\n\t}\n}";
		assertWrite(expected, src);
	}

	/**
	 * The other side of the fall-through edge. A bare over-long literal has no
	 * open delimiter to glue at, so the glue decision opens the parens on its own.
	 * NEGATIVE pin: the outer-first probe must not change a shape the fall-through
	 * already got right.
	 */
	public function testNonGluableSoleArgStillOpensTheCallParens(): Void {
		final src: String = 'class NonGluable {\n\tprivate function plain():Void {\n\t\tfinal row:ResultRow = store.query(\'SELECT '
			+ 'filepath FROM files WHERE folder = 1 AND folder_id AND some AND more AND yet AND plenty AND still\');\n\t}\n}';
		final expected: String = 'class NonGluable {\n\tprivate function plain():Void {\n\t\tfinal row:ResultRow = store.query(\n'
			+ "\t\t\t'SELECT filepath FROM files WHERE folder = 1 AND folder_id AND some AND more AND yet AND plenty AND still'\n\t\t);\n"
			+ '\t}\n}';
		assertWrite(expected, src);
	}

	/**
	 * A REDUNDANT paren around the sole argument (`f(('...'))`) stays WHOLE on the
	 * continuation line — `f(\n\t('...')\n)` — instead of the call break splitting
	 * the paren pair away from its content (`f((\n\t'...'\n))`). The paren group is
	 * `flatLength`-flat, so the outer-first probe fires on it like any other
	 * argument and the pair rides the same line as the string it wraps.
	 *
	 * Pinned because it is a REAL behaviour change this slice made under the
	 * project config and nothing else asserts it — a later wrap slice could revert
	 * it silently. It is a shape change only: both the old and the new output
	 * reparse and are fixed points. (The slice report originally described this as
	 * a fix for column-0 un-indented output; that symptom does not reproduce on the
	 * pre-slice binary at any width and the claim was withdrawn — what changed is
	 * only WHERE the paren pair sits.)
	 *
	 * One column wider and the argument stops fitting its continuation line, the
	 * probe declines, and the pre-slice `f((\n\t…\n))` shape returns — the same
	 * fall-through the at-limit / past-limit pair above pins directly.
	 */
	public function testRedundantParenSoleArgStaysWholeAtTheContinuation(): Void {
		final src: String = 'class RedundantParen {\n\tprivate function wrap():Void {\n\t\tfinal payload:String = '
			+ "encodeIt(('zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'));\n"
			+ '\t}\n}';
		final expected: String = 'class RedundantParen {\n\tprivate function wrap():Void {\n\t\tfinal payload:String = encodeIt(\n'
			+ "\t\t\t('zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz')\n"
			+ '\t\t);\n\t}\n}';
		assertWrite(expected, src);
	}

	/**
	 * The `flatLength(arg) < 0` gate, anonymised from the one real-tree site that
	 * proves it. The sole argument is a `cast [ … ].concat(…)` whose array has
	 * already exploded, so it carries hardlines and no continuation line could
	 * ever hold it flat. `flatLength` answers `-1`, the probe is skipped and the
	 * established hug survives. Without the gate the `-1` flows into the arm as a
	 * NEGATIVE width, trivially "fits", and the call opens — costing an indent
	 * level and forcing a nested `new Caption(...)` to break as well. This is the
	 * only fixture that turns red on removing the gate; a lambda-body argument
	 * does not (its list takes `WrapList.emit`'s `anyHardline` path first).
	 */
	public function testHardlineBearingSoleArgKeepsTheHug(): Void {
		final src: String = 'class HardlineArg {\n\tprivate function build():Void {\n\t\tpanel.content = new Column(cast [\n'
			+ '\t\t\tnew Caption(message, Styles.dialogText(), width, LINE_HEIGHT, HorizontalAlign.LEFT, VerticalAlign.TOP),\n'
			+ '\t\t\tnew Caption(headline, Styles.dialogText(), width, LINE_HEIGHT, HorizontalAlign.LEFT, VerticalAlign.TOP)\n'
			+ '\t\t].concat(entries.map(\n\t\t\tpath -> new Caption(shortenPath(path), Styles.dialogPlain(), width, LINE_HEIGHT, '
			+ 'HorizontalAlign.LEFT, VerticalAlign.TOP)\n\t\t)));\n\t}\n}';
		assertWrite(src, src);
	}

	/**
	 * Consequence of the probe's branch layout, pinned deliberately. The inner
	 * call's own decision node now presents its OPEN shape to the enclosing
	 * natural-first-line walk, so the outer call sees a first line ending at the
	 * inner `(` and keeps its prefix glued. Pre-slice the walk measured the inner
	 * call's glued shape instead and both levels broke, costing an indent level
	 * and two lines for no gain.
	 */
	public function testNestedCallSoleArgHugsWhenTheInnerCallLeadingBreaks(): Void {
		final src: String = 'class NestedCall {\n\tprivate function nested():Void {\n'
			+ "\t\tassertNull(narrowIt('class C {\\n\\tfunction f(s:String):Void {\\n\\t\\tvar x:Dynamic = "
			+ 's;\\n\\t\\tx.trim();\\n\\t\\tvar y:String = x;\\n\\t\\tvar z:String = y;\\n\\t}\\n}\'));\n\t}\n}';
		final expected: String = 'class NestedCall {\n\tprivate function nested():Void {\n\t\tassertNull(narrowIt(\n'
			+ "\t\t\t'class C {\\n\\tfunction f(s:String):Void {\\n\\t\\tvar x:Dynamic = s;\\n\\t\\tx.trim();\\n\\t\\tvar y:String = "
			+ 'x;\\n\\t\\tvar z:String = y;\\n\\t}\\n}\'\n\t\t));\n\t}\n}';
		assertWrite(expected, src);
	}

	/**
	 * SCOPE pin: a `[`-leading sole argument is excluded from the outer-first
	 * priority — the bracket IS the collection's own wrap point, so the call hugs
	 * it and only the bracket opens.
	 *
	 * This fixture STATES the scope; it does not prove the `[` gate. An array
	 * literal's own `OnePerLine` shape carries hardlines, so `flatLength` already
	 * answers `-1` and the earlier hardline gate rejects it — removing the `[`
	 * gate leaves these bytes unchanged. The gate's discriminating fixture is
	 * `HxComprehensionDeclRhsBracketWrapTest.testCallArgComprehensionHugsTheCallAndOpensBracket`,
	 * whose comprehension IS flattenable and DOES fit its continuation line; that
	 * one turns red when the gate is removed (verified by removing it, not only
	 * by reverting the slice).
	 */
	public function testBracketSoleArgKeepsTheCallHugged(): Void {
		final src: String = 'class BracketArg {\n\tprivate function register():Void {\n\t\tregisterHandlers([alphaHandler, betaHandler, '
			+ 'gammaHandler, deltaHandler, epsilonHandler, zetaHandler, etaHandlerx, thetaHandler]);\n\t}\n}';
		final expected: String = 'class BracketArg {\n\tprivate function register():Void {\n\t\tregisterHandlers([\n\t\t\talphaHandler,\n'
			+ '\t\t\tbetaHandler,\n\t\t\tgammaHandler,\n\t\t\tdeltaHandler,\n\t\t\tepsilonHandler,\n\t\t\tzetaHandler,\n'
			+ '\t\t\tetaHandlerx,\n\t\t\tthetaHandler\n\t\t]);\n\t}\n}';
		assertWrite(expected, src);
	}

	/**
	 * A `#if`-bearing argument participates like any other: the conditional region
	 * renders every branch inline, so `flatLength` measures exactly the bytes that
	 * will be emitted and the fit answer is honest. Pre-slice the call hugged and
	 * the nested paren broke ACROSS the `#else`, splitting the directive line.
	 */
	public function testCondCompSoleArgOpensTheCallParens(): Void {
		final src: String = 'class CondCompArg {\n\tprivate function guarded():Void {\n'
			+ "\t\tfinal row:ResultRow = store.query(#if debug 'SELECT filepath FROM files WHERE bucket = ' + ("
			+ 'flag ? \'1 AND fx\' : \'0 AND gx\') #else \'x\' #end);\n\t}\n}';
		final expected: String = 'class CondCompArg {\n\tprivate function guarded():Void {\n\t\tfinal row:ResultRow = store.query(\n'
			+ "\t\t\t#if debug 'SELECT filepath FROM files WHERE bucket = ' + (flag ? '1 AND fx' : '0 AND gx') #else 'x' #end\n\t\t);\n"
			+ '\t}\n}';
		assertWrite(expected, src);
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CFG);
	}

	/** Writes `src` under `CFG`, asserts it equals `expected`, and asserts the result is a fixed point. */
	private function assertWrite(expected: String, src: String): Void {
		final out: String = triviaWrite(src);
		Assert.equals(expected, out);
		Assert.equals(out, triviaWrite(out));
	}

}
