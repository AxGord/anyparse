package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * expr-paren-open pending-space: an `x = (chain) / lit;` whose parenthesised
 * opAddSub chain makes the physical line exceed maxLineLength OPENS the paren,
 * matching the fork. The paren-open probe restores the un-flushed OptSpace after
 * `=` (not yet in the pen column when the probe fires) so a line at exactly
 * maxLineLength + 1 opens rather than staying glued.
 *
 * Of several paren operands on one overflowing line, the one whose span crosses the limit opens: a later paren-open
 * probe is a break point of the line, so a leading paren that fits up to it stays glued. Identifiers are synthetic.
 */
@:nullSafety(Strict)
final class HxExprParenDivOpenBoundaryTest extends Test {

	private static final CFG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,'
		+ '"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove",'
		+ '"afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},'
		+ '"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,'
		+ '"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{'
		+ '"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},'
		+ '{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},'
		+ '"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],'
		+ '"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap",'
		+ '"rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength",'
		+ '"value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{'
		+ '"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine",'
		+ '"location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},'
		+ '"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength",'
		+ '"value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],'
		+ '"type":"fillLine","location":"beforeLast"}]},' + '"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},'
		+ '"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around",'
		+ '"forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around",'
		+ '"arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none",'
		+ '"functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around",'
		+ '"openingBracketPolicy":"none","closingBracketPolicy":"none",'
		+ '"bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},'
		+ '"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},'
		+ '"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},'
		+ '"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},'
		+ '"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},'
		+ '"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},'
		+ '"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},'
		+ '"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},' + '"lineEnds":{"emptyCurly":"noBreak"},'
		+ '"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine",'
		+ '"functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';
	private static final SOLE_ARRAY_SECTION: String = '"maxLineLength":140,"soleItemCuddledBrackets":true,"arrayWrap":'
		+ '{"defaultWrap":"ignore","rules":[{"conditions":[{"cond":"complexItemCount >= n","value":2}'
		+ ',{"cond":"totalItemLength >= n","value":100}],"type":"onePerLine"},{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],'
		+ '"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},';
	private static final EXPR_WRAP_SECTION: String = '"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},';

	public function new(): Void {
		super();
	}

	/** Physical line 141 (maxLineLength + 1): the paren OPENS. */
	public function testDivParenOpensWhenLineOverflows(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tcontainerBox.y = (\n\t\t\tWINDOW_SPAN_TOTAL - Metrics.PANEL_WINDOW_FOOTER_SPAN - '
			+ 'Metrics.PANEL_WINDOW_HEADER_SPAN - PREVIEW_PANE_SPAN\n\t\t) / 2.0;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tcontainerBox.y = (WINDOW_SPAN_TOTAL - Metrics.PANEL_WINDOW_FOOTER_SPAN - '
				+ 'Metrics.PANEL_WINDOW_HEADER_SPAN - PREVIEW_PANE_SPAN) / 2.0;\n\t}\n}',
				CFG
			)
		);
	}

	/** BOUNDARY: physical line EXACTLY 140 stays glued (a line at the limit does not exceed it) -- guards the pending-space off-by-one. */
	public function testDivParenFlatAtExactLimit(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tcontainerBox.y = (WINDOW_SPAN_TOTAL - Metrics.PANEL_WINDOW_FOOTER_SPAN - '
			+ 'Metrics.PANEL_WINDOW_HEADER_SPAN - PREVIEW_PANE_SPA) / 2.0;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tcontainerBox.y = (WINDOW_SPAN_TOTAL - Metrics.PANEL_WINDOW_FOOTER_SPAN - '
				+ 'Metrics.PANEL_WINDOW_HEADER_SPAN - PREVIEW_PANE_SPA) / 2.0;\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * Two paren operands of `/` on a 141-column line: the first closes well inside the
	 * limit, the second crosses it. Only the crossing paren opens; the fitting one stays
	 * glued, since the line fits up to the second paren's open delimiter.
	 */
	@:pin('control')
	@:killer('M-PAREN-SIBLING-FLAT')
	public function testSecondParenOpensWhenOnlyItCrossesDiv(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tratioValue = (hxxxxxxxxx.top - baseSpan.top) / (\n'
			+ '\t\t\ttailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tratioValue = (hxxxxxxxxx.top - baseSpan.top) / ('
				+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * Same shape with `*`: the operator is not a wrap seam, so the parens are the only
	 * break points and the one whose span crosses is the one that opens.
	 */
	public function testSecondParenOpensWhenOnlyItCrossesMul(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tratioValue = (hxxxxxxxxx.top - baseSpan.top) * (\n'
			+ '\t\t\ttailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tratioValue = (hxxxxxxxxx.top - baseSpan.top) * ('
				+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * The first paren holds a ternary (its own open arm): it glues all the same, because
	 * the break point the line needs is the second paren's.
	 */
	public function testTernaryFirstParenStaysGluedWhenSecondCrosses(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tratioValue = (isHead ? hxxxx.top : base.top) / (\n'
			+ '\t\t\ttailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tratioValue = (isHead ? hxxxx.top : base.top) / ('
				+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * Three paren operands: the two leading ones fit and glue, the trailing one opens.
	 */
	public function testThreeParensOnlyTheCrossingOneOpens(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tratioValue = (hxxxxxxxxxxxxxx - b) / (c - d) / (\n'
			+ '\t\t\ttailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tratioValue = (hxxxxxxxxxxxxxx - b) / (c - d) / ('
				+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * Inside an opened condition the same rule holds for the paren operands of the
	 * condition content.
	 */
	public function testConditionOperandSecondParenOpens(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tif (\n\t\t\t(hxxxxxxxxxxxxxxxxxxx.top - base.top) / ('
			+ '\n\t\t\t\ttailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top\n'
			+ '\t\t\t) > 2\n\t\t) {\n\t\t\trun();\n\t\t\trun();\n\t\t}\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tif (\n'
				+ '\t\t\t(hxxxxxxxxxxxxxxxxxxx.top - base.top) / (tailSpanValues[tailSpanValues.length - 1].top -'
				+ ' baseSpans[baseSpans.length - 1].top) > 2\n\t\t) {\n\t\t\trun();\n\t\t\trun();\n\t\t}\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * BOUNDARY: a first paren whose own span crosses the limit opens, and the second one,
	 * which then fits on the close line, stays glued (leftmost-first, as every group).
	 */
	public function testFirstParenThatCrossesStillOpens(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tratioValue = (\n\t\t\ttailSpanValues[tailSpanValues.length - 1].top - '
			+ 'baseSpans[baseSpans.length - 1].top - headSpanValue.top + hxxxxxxxxx\n\t\t) / (a - b);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tratioValue = (tailSpanValues[tailSpanValues.length - 1].top - '
				+ 'baseSpans[baseSpans.length - 1].top - headSpanValue.top + hxxxxxxxxx) / (a - b);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * BOUNDARY: the same two parens on a line of exactly 140 columns stay flat.
	 */
	public function testTwoFittingParensStayFlat(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tratioValue = (hxxxxxxxx.top - baseSpan.top) / ('
			+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tratioValue = (hxxxxxxxx.top - baseSpan.top) / ('
				+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * Without `expressionWrapping` the trailing paren is a collapse candidate that stays
	 * glued at the expression tail, so it is no break point of the line: the first paren
	 * still opens, as the only thing that can shorten it.
	 */
	@:pin('control')
	@:killer('M-PAREN-SIBLING-COLLAPSE')
	public function testCollapseTailParenIsNotABreakPoint(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tratioValue = (\n\t\t\thxxxxxxxxx.top - baseSpan.top\n'
			+ '\t\t) / (tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tratioValue = (hxxxxxxxxx.top - baseSpan.top) / ('
				+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n}',
				CFG.replace(EXPR_WRAP_SECTION, '')
			)
		);
	}

	/**
	 * The later break point may be a method chain: the leading paren fits up to the first
	 * `.concat(` link, so it stays glued and the chain wraps instead.
	 */
	public function testParenBeforeAMethodChainStaysGlued(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal kinds:Array<String> = (hxxxxxxxxxxxxxxxxxxxxxxx.headKinds ??'
			+ ' []).concat(shape.middleKinds ?? [])\n\t\t\t.concat(shape.tailKinds ?? []);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal kinds:Array<String> = (hxxxxxxxxxxxxxxxxxxxxxxx.headKinds ??'
				+ ' []).concat(shape.middleKinds ?? []).concat(shape.tailKinds ?? []);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * The crossing paren sits inside a call's argument list: the list is what crosses, so it
	 * breaks after its `(`, and the leading paren, which fits, stays glued.
	 */
	@:pin('control')
	@:killer('M-PAREN-LIST-BREAK')
	public function testCallArgumentListBreaksInsteadOfTheFirstParen(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvalue = (aaaa.top - baseSpan.top) / Math.max(\n'
			+ '\t\t\t1, (tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top)\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvalue = (aaaa.top - baseSpan.top) / Math.max(1, ('
				+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top));\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * Same through a `new` expression's argument list.
	 */
	public function testNewArgumentListBreaksInsteadOfTheFirstParen(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvalue = (aaaa.top - baseSpan.top) / new Wrapper(\n'
			+ '\t\t\t(tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top)\n\t\t).v;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvalue = (aaaa.top - baseSpan.top) '
				+ '/ new Wrapper((tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top)).v;\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * A nested call: the OUTER argument list is the first construct that breaks by itself.
	 */
	public function testNestedCallBreaksItsOuterArgumentList(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvalue = (aaaa.top - baseSpan.top) / outer(\n'
			+ '\t\t\tinner(1, (tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top))\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvalue = (aaaa.top - baseSpan.top) / outer(inner(1, ('
				+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top)));\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * An array comprehension that crosses breaks after its head; the leading paren stays glued.
	 */
	public function testComprehensionBreaksInsteadOfTheFirstParen(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvalue = (aaaa.top - baseSpan.top) / [\n\t\t\tfor (i in 0...n) ('
			+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top)\n\t\t][0];\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvalue = (aaaa.top - baseSpan.top) / [for (i in 0...n)'
				+ ' (tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top)][0];\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * An object literal that crosses breaks after `{`.
	 */
	public function testObjectLiteralBreaksInsteadOfTheFirstParen(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvalueQQQQQ = (aaaa.top - baseSpan.top) / {\n'
			+ '\t\t\tv: (tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top)\n\t\t}.v;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvalueQQQQQ = (aaaa.top - baseSpan.top) / {v: ('
				+ 'tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top)}.v;\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * A crossing paren that is the sole item of an array literal (cuddled brackets) opens
	 * inside `[(`; the leading one stays glued.
	 */
	public function testSoleItemArrayOpensTheCrossingParen(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvalueQQQQQQQQQQQQQQQQQQQQ = (aaaa.top - baseSpan.top) / [(\n'
			+ '\t\t\ttailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top\n\t\t)][0];\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvalueQQQQQQQQQQQQQQQQQQQQ = (aaaa.top - baseSpan.top) /'
				+ ' [(tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top)][0];\n\t}\n}',
				CFG.replace('"maxLineLength":140,', SOLE_ARRAY_SECTION)
			)
		);
	}

	/**
	 * The reported site shape: an opAddSub paren followed by a `Math.min` call whose arguments
	 * cross; the call breaks and the paren stays glued.
	 */
	public function testTransitionShapeBreaksTheMinArguments(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal fromFrame:Float = _isTransitioning\n'
			+ '\t\t\t? _transitionFromFrame + (_transitionToFrame - _transitionFromFrame) * Math.min(\n\t\t\t\t(Lib.getTimer() '
			+ '/ 1000.0 - _transitionStartTime) / Frames.FRAME_TRANSITION, 1.0\n\t\t\t)\n\t\t\t: _animationState.frame;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal fromFrame:Float = _isTransitioning ? _transitionFromFrame + ('
				+ '_transitionToFrame - _transitionFromFrame) * Math.min((Lib.getTimer() / 1000.0 - _transitionStartTime) /'
				+ ' Frames.FRAME_TRANSITION, 1.0) : _animationState.frame;\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * A `.concat(` argument that crosses breaks; the `(x ?? [])` head paren stays glued.
	 */
	public function testParenBeforeAnArgumentOfAChainLink(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal kinds:Array<String> = (shape.functionKinds ?? []).concat(\n'
			+ '\t\t\tshape.finalModifierMemberKind == null ? [] : [shape.finalModifierMemberKind]\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal kinds:Array<String> = (shape.functionKinds ??'
				+ ' []).concat(shape.finalModifierMemberKind == null ? [] : [shape.finalModifierMemberKind]);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * A chain whose lambda body forces a break fires at the bare limit, a later paren one
	 * column past it; the paren still ends the chain's line, since a line it leaves unbroken
	 * is never wider than the limit.
	 */
	public function testForcedBreakChainGluesALaterParenLine(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\ttotalQQQQQQQQQQQQQQQQQ = items.map(v -> {\n\t\t\ttrace(v);\n\t\t\treturn v;\n'
			+ '\t\t}).filter(v -> v != null).length + (aaaaaaaaaaaaaaaaaaaaaaaa - bbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\ttotalQQQQQQQQQQQQQQQQQ = items.map(v -> { trace(v); return v; }).filter(v -> v '
				+ '!= null).length + (aaaaaaaaaaaaaaaaaaaaaaaa - bbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * A single short argument is pinned flat (`itemCount <= 1` noWrap), so the paren inside it
	 * can never open: it is no break point, and the leading paren opens.
	 */
	@:pin('control')
	@:killer('M-PAREN-FLATTEN-REGION')
	public function testPinnedArgumentListIsMeasuredFlat(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tratioValueQQQQQQQQQQQQQQ = (\n\t\t\taaaa - bbbb\n'
			+ '\t\t) / compute((tailSpanValues[tailSpanValues.length - 1].top - baseSpans[0].top)) * scaleFactor;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tratioValueQQQQQQQQQQQQQQ = (aaaa - bbbb) /'
				+ ' compute((tailSpanValues[tailSpanValues.length - 1].top - baseSpans[0].top)) * scaleFactor;\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * A paren around a lambda may break inside itself, so the columns after it are not the
	 * measured ones and the argument list after it is no break point: the lambda paren opens.
	 */
	@:pin('control')
	@:killer('M-PAREN-EXACT-CONTENT')
	public function testLambdaParenMeasuresItsOwnBreakableContent(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvalueQQQQQQQQQQQQQQQQQQQQQQQQQ = (aaaa - bbbb) / (\n'
			+ '\t\t\tv -> v.someLongFieldName + anotherFieldRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR\n'
			+ '\t\t)(1) / (tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvalueQQQQQQQQQQQQQQQQQQQQQQQQQ = (aaaa - bbbb) / (v -> v.someLongFieldName +'
				+ ' anotherFieldRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR)(1) /'
				+ ' (tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * Without `expressionWrapping` the lambda paren is a collapse candidate measured flat in
	 * the rest, so every column after it is a guess and the call after it predicts nothing.
	 */
	@:pin('control')
	@:killer('M-PAREN-EXACT-REST')
	public function testUnmeasuredRestNodeEndsColumnPredictions(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvalueQQQQQQQQQQQQQQQQQQQQQQQQQ = (\n\t\t\taaaa - bbbb\n\t\t) / (\n'
			+ '\t\t\tv -> v.someLongFieldName + anotherFieldRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR\n'
			+ '\t\t)(1) / (tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvalueQQQQQQQQQQQQQQQQQQQQQQQQQ = (aaaa - bbbb) / (v -> v.someLongFieldName +'
				+ ' anotherFieldRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR)(1) /'
				+ ' (tailSpanValues[tailSpanValues.length - 1].top - baseSpans[baseSpans.length - 1].top);\n\t}\n}',
				CFG.replace(EXPR_WRAP_SECTION, '')
			)
		);
	}

	/**
	 * A method-chain probe keeps the plain rest: its own link break is better than a short
	 * argument list its flat width pushed past the limit.
	 */
	@:pin('control')
	@:killer('M-PAREN-CHAIN-PREDICTS')
	public function testChainProbeKeepsBreakingItsOwnLink(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal max:Int = LintConfig.resolveWith(_resolveConfig, entry.file)\n'
			+ '\t\t\t.intOption(\'complexity\', \'max\') ?? plugin.maxComplexity(entry.file) ?? DEFAULT_MAX_COMPLEXITY;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal max:Int = LintConfig.resolveWith(_resolveConfig, '
				+ 'entry.file).intOption(\'complexity\', \'max\') ?? plugin.maxComplexity(entry.file) ?? DEFAULT_MAX_COMPLEXITY;\n\t}\n}',
				CFG
			)
		);
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		return HxWriteFixture.triviaWrite(src, cfg);
	}

}
