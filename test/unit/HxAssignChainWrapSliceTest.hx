package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-assign-chain-fill: a right-associative `=` chain (`a = b = c = v`) had NO
 * wrap point at all -- the lowering flattened it into one glued `Concat`, so a
 * chain past `maxLineLength` rendered on a single over-long line and the writer
 * still called the file canonical. It now breaks AFTER an `=`, packed fill-style
 * (`AfterLast` -- the operator suffixes the previous operand), continuation at
 * one indent level.
 *
 * OVERFLOW-ONLY: the gate is `IfNaturalFirstLineExceeds`, whose probe resolves
 * inner `Group`s by their own `fitsFlat`. A single assignment whose RHS call
 * folds its OWN arguments therefore keeps a SHORT natural first line (it ends at
 * the call's open paren) and stays glued -- a plain `Group` / `IfLineExceeds`
 * would measure the whole flat RHS and over-break every such site.
 *
 * The config below is a real 140-column project `hxformat.json`, not the
 * compiled defaults: the wrap cascade a chain meets in practice is config-driven
 * and the defaults are blind to it.
 */
@:nullSafety(Strict)
final class HxAssignChainWrapSliceTest extends Test {

	private static final CONFIG: String =
		'{"indentation": {"character": "tab", "tabWidth": 4, "trailingWhitespace": false, "alignInlineSwitchCaseBody": true}, "emptyLines": {"maxAnywhereInFile": 1, "afterBlocks": "remove", "afterLeftCurly": "remove", "beforeRightCurly": "remove", "classEmptyLines": {"beginType": 1, "endType": 1}, "interfaceEmptyLines": {"beginType": 1, "endType": 1}, "abstractEmptyLines": {"beginType": 1, "endType": 1}, "uniformStatementBlanks": "collapse"}, "wrapping": {"comprehensionCuddledOpen": true, "functionSignature": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 100}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}], "type": "noWrap"}]}, "maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "opAddSubChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "whitespace": {"addLineCommentSpace": false, "normalizeLineCommentIndent": true, "commaPolicy": "after", "ifPolicy": "around", "forPolicy": "around", "whilePolicy": "around", "switchPolicy": "around", "catchPolicy": "around", "arrowFunctionsPolicy": "around", "functionTypeHaxe3Policy": "none", "functionTypeHaxe4Policy": "none", "binopPolicy": "around", "intervalPolicy": "around", "openingBracketPolicy": "none", "closingBracketPolicy": "none", "bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before", "arrowBodyOpenPad": true, "arrowBodyReflow": true}, "anonTypeBraces": {"openingPolicy": "after", "closingPolicy": "before"}, "typedefBraces": {"openingPolicy": "after", "closingPolicy": "before"}, "blockBraces": {"openingPolicy": "around", "closingPolicy": "before"}, "unknownBraces": {"openingPolicy": "after", "closingPolicy": "before"}, "singleStatementBraces": "remove"}, "parenConfig": {"callParens": {"openingPolicy": "none", "closingPolicy": "none"}, "funcParamParens": {"openingPolicy": "none", "closingPolicy": "none"}, "conditionParens": {"openingPolicy": "before", "closingPolicy": "after"}, "anonFuncParamParens": {"openingPolicy": "none", "closingPolicy": "none"}, "forLoopParens": {"openingPolicy": "before", "closingPolicy": "after"}, "expressionParens": {"openingPolicy": "none", "closingPolicy": "none"}, "switchSubjectParens": "remove"}}, "lineEnds": {"emptyCurly": "noBreak"}, "sameLine": {"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine", "functionBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	public function new(): Void {
		super();
	}

	public function testOverflowingAssignChainBreaksAfterEquals(): Void {
		// Glued statement line = 157 columns at tab=4 (8 cols of indent + 149
		// chars). Six operands pack onto the head line (121 cols), the fill
		// breaks after the sixth `=` and the tail lands at +1 indent (47 cols).
		final flat: String =
			'class Sample {\n\n\tfunction run() {\n\t\t_seg1.onFinished = _seg2.onFinished = _seg3.onFinished = _seg4.onFinished = _seg5.onFinished = _seg6.onFinished = _seg7.onFinished = stopTheSequence;\n\t}\n\n}';
		final wrapped: String =
			'class Sample {\n\n\tfunction run() {\n\t\t_seg1.onFinished = _seg2.onFinished = _seg3.onFinished = _seg4.onFinished = _seg5.onFinished = _seg6.onFinished =\n\t\t\t_seg7.onFinished = stopTheSequence;\n\t}\n\n}';
		Assert.equals(wrapped, triviaWrite(flat));
		Assert.equals(wrapped, triviaWrite(wrapped));
	}

	public function testFittingAssignChainStaysFlat(): Void {
		// Two `=` operators, 50 columns -- comfortably inside the limit. The
		// probe must not fire: a chain only wraps on overflow.
		final src: String = 'class Sample {\n\n\tfunction run() {\n\t\t_seg1.onDone = _seg2.onDone = _seg3.onDone = pickHandler;\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testAssignChainAtExactlyMaxLineLengthStaysFlat(): Void {
		// Statement line = exactly 140 columns. Stays flat.
		// HONEST SCOPE: this fixture does NOT discriminate the probe threshold.
		// The probe measures the chain EXPRESSION only -- the statement `;` is a
		// sibling `Text`, outside the measured Doc -- so a 140-column line is a
		// 139-column measurement and stays flat under `lineWidth` and
		// `lineWidth + 1` alike. It guards the boundary against a probe that
		// fires one column EARLY (a `<=`/`>` slip inside the natural walk), not
		// against the choice of constant.
		final src: String =
			'class Sample {\n\n\tfunction run() {\n\t\t_seg1.onFinished = _seg2.onFinished = _seg3.onFinished = _seg4.onFinished = _seg5.onFinished = _seg6.onFinished = terminateSequence;\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testSingleAssignWithWrappingCallStaysUnchanged(): Void {
		// 141 columns flat. The RHS call owns the wrap (leading break after its
		// open paren), so the natural first line is short and the `=` must NOT
		// break -- the `IfNaturalFirstLineExceeds` gate over a plain `Group`.
		assertCallAbsorbsTheOverflow(
			'class Sample {\n\n\tfunction run() {\n\t\t_target.handlerSlot = buildTheHandlerForSequence(firstArgumentValue, secondArgumentValue, thirdArgumentValue, fourthArgumentValueXy);\n\t}\n\n}'
		);
	}

	public function testAssignChainWithWrappingCallStaysUnchanged(): Void {
		// Same guard with a genuine 2-operator chain (144 columns flat): the
		// chain routes through the new emit, the call still absorbs the overflow.
		assertCallAbsorbsTheOverflow(
			'class Sample {\n\n\tfunction run() {\n\t\t_target.slotA = _target.slotB = buildTheHandlerForSequence(firstArgumentValue, secondArgumentValue, thirdArgumentValue, fourthArgValue);\n\t}\n\n}'
		);
	}

	/**
	 * Assert that the RHS call -- not the `=` -- owns the wrap: the call's
	 * arguments leading-break and no line ends on an assignment operator.
	 */
	private inline function assertCallAbsorbsTheOverflow(src: String): Void {
		final out: String = triviaWrite(src);
		Assert.isTrue(out.indexOf('buildTheHandlerForSequence(\n') != -1);
		Assert.isTrue(out.indexOf('=\n') == -1);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
