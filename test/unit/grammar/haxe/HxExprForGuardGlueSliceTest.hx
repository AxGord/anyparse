package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * The `for (…) if (…) { … }` guard idiom in EXPRESSION position — an arrow-lambda
 * body, not a comprehension.
 *
 * `@:fmt(strictFitLineBody(...))` buys `comprehensionFor: fitLine` its staircase by
 * refusing the glue to every body that cannot render flat, and that refusal is
 * wider than the hazard it was written for. A head line that ENDS at an open
 * delimiter puts everything below it INSIDE the delimiter the head opened, so
 * nothing of the body ever reaches the container indent — which is the whole
 * reason an `if`/`else` body may not glue. Refusing the glue there split the guard
 * idiom the user's style rules mandate over `if (!cond) continue;`.
 *
 * So the refusal asks WHERE the body's continuation lands rather than whether the
 * body is flat. The comprehension staircase is the other half of that answer and is
 * re-asserted here, because it is what the restored glue must not take back; the
 * over-wide spine is the third, since the probe measures the whole glued first line
 * at the outermost link and so cannot glue a chain link by link.
 */
@:nullSafety(Strict)
final class HxExprForGuardGlueSliceTest extends Test {

	/** The user's own config, cut to the knobs these shapes read. */
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140, "comprehensionCuddledOpen": true}, "sameLine": {'
		+ '"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** Two statements, so `singleStatementBraces` has nothing to de-brace and the body keeps its `{`. */
	private static final BLOCK: String = '{ haxe.Timer.delay(() -> dispatchEvent(new MouseEvent(MouseEvent.CLICK)), 125); return; }';

	/** The reported site: arrow -> `for` -> `if` -> block, written flat. */
	private static final ARROW_FOR_IF: String = wrap(
		'_focusManager.addKeyDownListener((keyCode:Int) -> for (actionKey in _actionKeys) if (keyCode == actionKey) $BLOCK);'
	);

	/** Its glued head line — the whole spine ahead of the block's own `{`. */
	private static final ARROW_FOR_IF_HEAD: String = '(keyCode:Int) -> for (actionKey in _actionKeys) if (keyCode == actionKey) {';

	/** arrow -> `for` -> `for` -> block: the second broken cell, same shape one keyword over. */
	private static final ARROW_FOR_FOR: String = wrap(
		'_focusManager.addKeyDownListener((keyCode:Int) -> for (actionKey in _actionKeys) for (secondKey in _secondaryKeys) $BLOCK);'
	);

	private static final ARROW_FOR_FOR_HEAD: String = '(keyCode:Int) -> for (actionKey in _actionKeys) for (secondKey in _secondaryKeys) {';

	/** arrow -> `for` -> block: already glued before this slice, and the neighbour that proves the block ctor arm is untouched. */
	private static final ARROW_FOR: String = wrap(
		'_focusManager.addKeyDownListener((keyCode:Int) -> for (actionKey in _actionKeys) $BLOCK);'
	);

	/** arrow -> `if` -> `if` -> block and arrow -> `while` -> `if` -> block: the two spines that never carried the refusal. */
	private static final ARROW_IF_IF: String = wrap(
		'_focusManager.addKeyDownListener((keyCode:Int) -> if (isEnabled) if (keyCode == actionKey) $BLOCK);'
	);

	private static final ARROW_WHILE_IF: String = wrap(
		'_focusManager.addKeyDownListener((keyCode:Int) -> while (hasMore) if (keyCode == actionKey) $BLOCK);'
	);

	/** The statement twin of the reported site — glued throughout, so it is this class's vacuity guard. */
	private static final STMT_FOR_IF: String = wrap('for (actionKey in _actionKeys) if (keyCode == actionKey) $BLOCK');

	/** A comprehension whose body is an if/else: the shape the refusal exists for. */
	private static final COMPREHENSION_IF_ELSE: String = wrap(
		'final r = [for (elementValue in sourceCollectionValueName) if '
		+ '(elementValue.enabledFlagValue) elementValue.captionValue else elementValue.detailValue];'
	);

	/** Two comprehensions, one the body of the other — the `Matrix.hor` staircase. */
	private static final NESTED_COMPREHENSION: String = wrap(
		'final r = [for (rowValue in sourceMatrixValueName) [for '
		+ '(indexValue in 0...rowValue.length) if (indexValue > offsetValue) rowValue[indexValue] else fallbackValue]];'
	);

	public function new(): Void {
		super();
	}

	/** THE REGRESSION: the guard idiom keeps its head line under an arrow-lambda body. */
	@:pin('control')
	@:killer('M-STRICT-HEAD-DELIM-OFF')
	public function testArrowForIfBlockGluesTheWholeSpine(): Void {
		final out: String = write(ARROW_FOR_IF, CFG);
		Assert.isTrue(out.indexOf(ARROW_FOR_IF_HEAD) != -1, 'the `for (…) if (…) {` spine must share the arrow head line: <$out>');
	}

	/** The same for a `for` -> `for` spine: the refusal was never about which keyword follows. */
	@:pin('control')
	@:killer('M-STRICT-HEAD-DELIM-OFF')
	public function testArrowForForBlockGluesTheWholeSpine(): Void {
		final out: String = write(ARROW_FOR_FOR, CFG);
		Assert.isTrue(out.indexOf(ARROW_FOR_FOR_HEAD) != -1, 'the `for (…) for (…) {` spine must share the arrow head line: <$out>');
	}

	/** The three neighbouring spines that already glued must still glue — the fix widens nothing else. */
	public function testNeighbouringArrowSpinesStillGlue(): Void {
		Assert.isTrue(
			write(ARROW_FOR, CFG).indexOf('(keyCode:Int) -> for (actionKey in _actionKeys) {') != -1, 'arrow -> for -> block must glue'
		);
		Assert.isTrue(
			write(ARROW_IF_IF, CFG).indexOf('(keyCode:Int) -> if (isEnabled) if (keyCode == actionKey) {') != -1,
			'arrow -> if -> if -> block must glue'
		);
		Assert.isTrue(
			write(ARROW_WHILE_IF, CFG).indexOf('(keyCode:Int) -> while (hasMore) if (keyCode == actionKey) {') != -1,
			'arrow -> while -> if -> block must glue'
		);
	}

	/** VACUITY GUARD: the statement twin glues on the base engine, so a fix that glues everything cannot hide here. */
	public function testStatementForIfBlockStillGlues(): Void {
		final out: String = write(STMT_FOR_IF, CFG);
		Assert.isTrue(
			out.indexOf('for (actionKey in _actionKeys) if (keyCode == actionKey) {') != -1, 'the statement twin must glue: <$out>'
		);
	}

	/** The refusal's own population: an if/else comprehension body still leaves the `for` head line. */
	public function testComprehensionIfElseBodyStillLeavesTheHeadLine(): Void {
		final out: String = write(COMPREHENSION_IF_ELSE, CFG);
		Assert.isTrue(
			out.indexOf('for (elementValue in sourceCollectionValueName) if (') == -1,
			'an if/else comprehension body must not glue back onto the `for` head: <$out>'
		);
	}

	/** …and the nested staircase, where each `[ for` head owns its own line. */
	public function testNestedComprehensionStaircaseSurvives(): Void {
		final out: String = write(NESTED_COMPREHENSION, CFG);
		Assert.isTrue(out.indexOf('sourceMatrixValueName) [') == -1, 'the two comprehension heads must not share a line: <$out>');
		Assert.isTrue(out.indexOf('0...rowValue.length) if (') == -1, 'the inner if/else body must not glue: <$out>');
	}

	/**
	 * ANTI-RUNAWAY: the probe measures the whole glued first line at the outermost
	 * link, so a spine too wide for the budget drops as ONE shape instead of gluing
	 * link by link until the innermost condition is the only thing left to break.
	 */
	public function testOverWideSpineDropsWholeInsteadOfTearingTheCondition(): Void {
		for (limit in [70, 80, 100]) {
			final out: String = write(ARROW_FOR_IF, condWrapCfg(limit));
			Assert.isTrue(out.indexOf(ARROW_FOR_IF_HEAD) == -1, 'an over-wide spine must not glue at $limit: <$out>');
			Assert.isTrue(out.indexOf('if (\n') == -1, 'the innermost condition paren must not be torn open at $limit: <$out>');
		}
	}

	/** Every shape above must be a fixed point — the glue decision cannot oscillate between writes. */
	public function testEveryShapeIsAFixedPoint(): Void {
		for (src in [
			ARROW_FOR_IF,
			ARROW_FOR_FOR,
			ARROW_FOR,
			ARROW_IF_IF,
			ARROW_WHILE_IF,
			STMT_FOR_IF,
			COMPREHENSION_IF_ELSE,
			NESTED_COMPREHENSION
		]) {
			final once: String = write(src, CFG);
			Assert.equals(once, write(once, CFG), 'the writer must reach its fixed point in one pass');
		}
	}

	/** `CFG` at `width`, plus the `conditionWrapping` cascade that can tear a condition paren open. */
	private inline function condWrapCfg(width: Int): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": $width'
			+ ', "comprehensionCuddledOpen": true, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "sameLine": {'
			+ '"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';
	}

	private inline function write(src: String, json: String): String {
		return HxWriteFixture.triviaWrite(src, json);
	}

	/** One statement in a method body of a class, written flat — the writer owns every break below. */
	private static inline function wrap(statement: String): String {
		return 'class C {\n\tfunction test():Void {\n\t\t$statement\n\t}\n}\n';
	}

}
