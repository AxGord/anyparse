package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

using StringTools;

/**
 * omega-arrow-block-body-open: an arrow lambda's `{` never lands alone on a
 * line after `->`. The `@:fmt(arrowBodyLineWrap)` marker
 * (`WrapBoundary(IfResidualLineExceeds(...))`) is resolved at render time by
 * `Renderer.pushFlatWidthBranch`, whose shared arm adds a rest-of-stack
 * lookahead. When the body opens with `{` AND forces its own hardline that
 * lookahead measures the wrong line -- the body hardlines right after `{`, so
 * the summed content lands on the body's CLOSING line -- and the break side it
 * selects only strands `{` one indent deeper without shortening anything. A
 * guarded arm (`Renderer.selfBreakingBraceBody`) forces the flat side for
 * exactly that population.
 *
 * Both halves of the guard are exercised here. A FLAT object-literal body also
 * starts with `{` but rides the head line in full, so it must KEEP its break;
 * `testFlatObjectLiteralArrowBodyStillBreaks` pins that, and it is the only
 * case that flips when the `hasForcedBreak` conjunct is removed.
 *
 * Each test states its revert behaviour: DISCRIMINATES (fails with the guarded
 * arm reverted), DISCRIMINATES the second conjunct (fails only when
 * `hasForcedBreak` is dropped), or CONTROL (byte-identical in every
 * configuration). Measured, not assumed: reverting the arm fails exactly the
 * five DISCRIMINATES tests; dropping the conjunct fails exactly one.
 * Identifiers and strings are synthetic or length-preserving anonymizations and
 * bear no relation to any downstream code.
 */
@:nullSafety(Strict)
final class HxArrowBlockBodyOpenSliceTest extends Test {

	private static final CFG: String =
		'{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

	/**
	 * Shared by the two shape-B tests (gate alone, and gate with
	 * `methodChainCuddledLinks` on). The whole point of that pair is that both
	 * configs see the SAME input, so it is written once.
	 */
	private static final PANEL_FOLD_SRC: String = 'class Sample {\n\n\tfunction set_foldedNow(state:Bool):Bool {\n\t\tfoldedNow = state;\n'
		+ '\t\tMotions.blend(_sectionPanel, 0.3, { shade: state ? 0.0 : 1, shiftY: state ? 0.0 : 1 }).onFinished(() -> {\n'
		+ '\t\t\t_sectionPanel.enabled = !state;\n\t\t\tdispatchAlert(new Alert(Alert.FINISHED));\n'
		+ '\t\t}).onTicked(() -> dispatchAlert(new Alert(Alert.MUTATE)));\n\t\treturn state;\n\t}\n\n}';

	public function new(): Void {
		super();
	}

	/** DISCRIMINATES: a chain whose LAST link carries a wide expression-bodied arrow keeps the block-bodied `.onFinished` link cuddled (`-> {`); without the gate the rest-of-stack lookahead strands the `{` on its own line. */
	public function testChainWideTrailingLinkKeepsArrowCuddled(): Void {
		final src: String = 'class Sample {\n\n\tfunction run() {\n'
			+ '\t\tMotions.blend(_sectionPanel, 0.3, { shade: state ? 0.0 : 1, shiftY: state ? 0.0 : 1 }).onFinished(() -> {\n'
			+ '\t\t\t_sectionPanel.enabled = !state;\n\t\t\tdispatchAlert(new Alert(Alert.FINISHED));\n'
			+ '\t\t}).onTicked(() -> dispatchAlert(new Alert(Alert.MUTATE)));\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** CONTROL: the same chain with a NARROW trailing-link argument -- the rest-of-stack sum stays under `maxLineLength`, so the arrow was already cuddled before the gate. */
	public function testChainNarrowTrailingLinkStaysCuddled(): Void {
		final src: String = 'class Sample {\n\n\tfunction run() {\n'
			+ '\t\tMotions.blend(_sectionPanel, 0.3, { shade: state ? 0.0 : 1, shiftY: state ? 0.0 : 1 }).onFinished(() -> {\n'
			+ '\t\t\t_sectionPanel.enabled = !state;\n\t\t\tdispatchAlert(new Alert(Alert.FINISHED));\n\t\t}).onTicked(() -> d(1));\n\t}\n'
			+ '\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** CONTROL (boundary, fits side): trailing-link argument one char SHORTER than the sibling below -- the chain cascade breaks the chain one link per line first, so the arrow marker never surfaces and the rendering is byte-identical with the gate reverted. */
	public function testBoundaryFitsChainBreaksArrowStillCuddled(): Void {
		final src: String = 'class Sample {\n\n\tfunction run() {\n\t\tObjName.tweenValue(_groupField, 0.3, { alpha: 1 })\n'
			+ '\t\t\t.onComplete(() -> {\n\t\t\t\t_groupField.visible = true;\n\t\t\t})\n'
			+ '\t\t\t.onUpdate(() -> handlerName(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa));\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** DISCRIMINATES (boundary, fits+1 side): ONE more char in the trailing-link argument re-glues the chain and hands the decision to the arrow marker -- without the gate that is exactly where `-> \n {` appears. */
	public function testBoundaryFitsPlusOneKeepsArrowCuddled(): Void {
		final src: String = 'class Sample {\n\n\tfunction run() {\n'
			+ '\t\tObjName.tweenValue(_groupField, 0.3, { alpha: 1 }).onComplete(() -> {\n'
			+ '\t\t\t_groupField.visible = true;\n\t\t}).onUpdate(() -> handlerName(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa));\n' + '\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** DISCRIMINATES: real-tree shape A (anonymized) -- a `put(...).success(block arrow).error(expression arrow)` crash-report chain whose last link was collapsed to an expression body. */
	public function testCrashReportChainExpressionBodyLastLink(): Void {
		final src: String = 'class Sample {\n\n\tfunction run() {\n\t\tSVC.data.recordEvent.put(null, {\n\t\t\t"MainAlias": alias,\n'
			+ '\t\t\t"TagIndex": 4,\n\t\t\t"TagPayload": [ov, issue, hexa.LineStack.toSource(hexa.LineStack.fullStack())].join(\', \'),\n'
			+ '\t\t\t"Timestamp": Date.now().toString(),\n\t\t}).success((outVal:net.proto.ResultantData) -> {\n'
			+ '\t\t\tif (!outVal.Allowed) trace(\': recordEvent: \', SVC.readFailMessages2(outVal));\n'
			+ '\t\t}).error((faultVal:net.proto.FaultOutcomes) -> trace(\': recordEvent: \', SVC.readFailMessages(faultVal)));\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** DISCRIMINATES: real-tree shape B (anonymized) -- a tween `.onFinished(block arrow).onTicked(expression arrow)` chain inside a property setter. */
	public function testPanelFoldChainExpressionBodyLastLink(): Void {
		Assert.equals(PANEL_FOLD_SRC, triviaWrite(PANEL_FOLD_SRC));
	}

	/** DISCRIMINATES: shape B again with `wrapping.methodChainCuddledLinks` ON -- the gate composes with the cuddled-links knob, same cuddled rendering. */
	public function testCuddledLinksKnobKeepsArrowCuddled(): Void {
		final cuddledCfg: String = CFG.replace(
			'"wrapping":{"functionSignature"', '"wrapping":{"methodChainCuddledLinks":true,"functionSignature"'
		);
		Assert.equals(PANEL_FOLD_SRC, triviaWrite(PANEL_FOLD_SRC, cuddledCfg));
	}

	/** CONTROL (narrowness pin): an EXPRESSION-bodied sole arrow arg still breaks after `->` with its close `)` on its own line -- the gate keys on a `{`-leading body only and did not disable the marker wholesale. */
	public function testSoleArrowArgStillBreaksWithCloseOnOwnLine(): Void {
		final src: String = 'class Sample {\n\n\tfunction run() {\n'
			+ '\t\tfinal picked:Null<WrapperResultType> = elementCollectionValue.find((element:MemberEntryType) ->\n'
			+ '\t\t\tScoringHelperName.computeRankValueFor(element) == 1\n\t\t);\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** CONTROL: block-bodied arrows in NON-chain over-wide contexts (`+` operand, `==`/`||` operand, `&&` condition, `??` operand) keep `{` cuddled either way -- measured byte-identical with the gate reverted. The two-indent-level body of the first two is a SEPARATE known nest-depth quirk, pinned here so a later fix is visible. */
	public function testNonChainBlockBodiedArrowsUnchanged(): Void {
		final src: String = 'class Sample {\n\n\tfunction c1() {\n\t\tfinal resultValue:Int = receiverObjectName.methodNameHere(() -> {\n'
			+ '\t\t\t\t_groupField.visible = true;\n'
			+ '\t\t\t}) + someOtherRatherLongExpressionName + yetAnotherLongExpressionValue + finalTailVal;\n\t}\n\n\tfunction c2() {\n'
			+ '\t\tfinal resultValue:Bool = receiverName.methodName(idValue, () -> {\n\t\t\t\t_groupField.visible = true;\n'
			+ '\t\t\t}) == someRatherLongComparisonValueName || fallbackFlagValueName || tailFlagValue;\n\t}\n\n\tfunction c3() {\n'
			+ '\t\tif (\n\t\t\tflagValueName && registerHandlerName(() -> {\n\t\t\t\t_groupField.visible = true;\n'
			+ '\t\t\t}) && anotherRatherLongConditionValue && yetAnotherLongConditionName\n\t\t)\n\t\t\tinvokeTask();\n\t}\n\n'
			+ '\tfunction c4() {\n\t\treturn receiverName.methodName(idValue, () -> {\n\t\t\t_groupField.visible = true;\n'
			+ '\t\t}) ?? someRatherLongFallbackValueName ?? anotherFallbackValueName ?? tailValue;\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * DISCRIMINATES the guard's SECOND conjunct (`hasForcedBreak`): a FLAT object-literal arrow body also starts with `{`, but it rides the head line in full, so breaking after `->` genuinely shortens that line and must still happen. A `{`-only guard suppressed the break and pushed this fixture from 127 to 141 columns against the 140 budget. Reverting the whole arm leaves this test PASSING -- it pins the guard's width, not its existence.
	 */
	public function testFlatObjectLiteralArrowBodyStillBreaks(): Void {
		final src: String = 'class Sample {\n\n\tfunction run() {\n\t\tfinal resultName = collectionNameValue.mapEntriesHere(\n'
			+ '\t\t\tentryValueName ->\n'
			+ '\t\t\t\t{primaryKeyFieldNamexxxxxxxxxx: entryValueName.identifierName, secondaryLabelName: entryValueName.captionName }\n'
			+ '\t\t);\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * CONTROL (outcome pin, byte-identical with the arm reverted AND with its second conjunct removed): an object literal whose OWN wrap cascade already committed to breaking hardlines right after `{`, so it terminates the head line itself and keeps `{` cuddled -- exactly as a statement block does. It pins the slice OUTCOME for the second, non-block half of the gated population, not the gate.
	 */
	public function testSelfBreakingObjectLiteralArrowBodyStaysCuddled(): Void {
		final src: String = 'class Sample {\n\n\tfunction run() {\n'
			+ '\t\tfinal resultName = collectionNameValue.mapEntriesHere(entryValueName -> {\n'
			+ '\t\t\tprimaryKeyFieldNamexxxxxxxxxx: entryValueName.identifierName,\n'
			+ '\t\t\tsecondaryLabelName: entryValueName.captionName,\n\t\t});\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * DISCRIMINATES the guard's THIRD conjunct (`flatTokenWidthFirstLine <= 1`): under
	 * `objectLiteral.defaultWrap: "keep"` a one-line source literal reproduces its own
	 * layout, so `{ onDone: () -> { ... }, tag: 1 }` DOES force a hardline (the inner
	 * block's) while its own head run continues past the `{`. `hasForcedBreak` alone
	 * therefore admitted it and suppressed a break the head line needed -- 108 to 146
	 * columns against a 140 budget. Reverting the whole arm leaves this PASSING.
	 */
	public function testKeepModeLiteralBreakingLaterStillBreaks(): Void {
		final src: String = 'class Sample {\n\n\tfunction run() {\n'
			+ '\t\tfinal resultValueName = receiverObjectNameHereLongerStill.methodNameGoesHereTooNow(entryValueName ->\n'
			+ '\t\t\t{onDoneCallbackNameValueLong: () -> {\n\t\t\t\tperformActionNow(entryValueName);\n\t\t\t}, tagLabelValue: 1 }\n'
			+ '\t\t);\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src, keepModeCfg()));
	}

	private inline function triviaWrite(src: String, ?cfg: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg ?? CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

	/**
	 * `CFG` with `wrapping.objectLiteral.defaultWrap` and `sameLine.functionBody` set to
	 * `keep`, the combination under which an object-literal arrow body reproduces its
	 * source layout instead of breaking open -- the config that separates "forces a
	 * hardline somewhere" from "breaks before any other token".
	 */
	private static inline function keepModeCfg(): String {
		return CFG.replace(
			'"wrapping":{"functionSignature"', '"wrapping":{"objectLiteral":{"defaultWrap":"keep","rules":[]},"functionSignature"'
		)
			.split('"functionBody":"fitLine"')
			.join('"functionBody":"keep"');
	}

}
