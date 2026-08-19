package unit;

import utest.Assert;
import utest.Test;

/**
 * ω-comprehension-closer: a comprehension body is a BLOCK body — the shape
 * whose `}` the closing `]` may ride (`[ for (…) {` … `} ]`) — only when the
 * `{` is GLUED to the generator head. Before this slice the test was the
 * item's last token alone (`lastVisibleText == '}'`), so every body PUSHED to
 * a continuation line that merely ENDS in a curly read as a block: a macro
 * reification (`macro if (…) $p{['sourceObject', f.slot]}`), a ternary whose
 * else-branch is an object literal or a `switch`. Those took the head-hug
 * shape and got their `]` glued to a BODY line at body indent — while the
 * sibling comprehension one screen up, whose body happened to end in `)`,
 * dropped its `]` to container indent. Two canonical closers for one
 * construct.
 *
 * PLACEMENT, not construct: the same `switch` written so it opens ON the head
 * line keeps `} ]` — `testHeadGluedSwitchBodyKeepsBlockHug` and
 * `testTernarySwitchBodyDropsCloser` are the two directions.
 *
 * Width does not enter the decision on either side of the fix (both shapes fit
 * `maxLineLength` comfortably), and neither does the body's line COUNT — a
 * two-continuation-line body with a curly tail glued exactly like a one-line
 * one (`testTwoLineReifiedBodyAlsoDropsCloser` pins that direction).
 *
 * Byte-inert for genuine block bodies (`HxComprehensionBlockHugSliceTest`,
 * `HxComprehensionCuddledOpenTest.testBlockBodyComprehensionKeepsBlockHug`,
 * plus the trailing-comment variants pinned here) and for comprehensions that
 * fit one line (`…CuddledOpenTest.testFittingComprehensionStaysFlat`, plus the
 * curly-tailed variant pinned here).
 *
 * Every fixture segment carrying `$p{` / `$v{` is DOUBLE-quoted — a
 * single-quoted Haxe literal would try to interpolate it. The `$`-free config
 * literals keep the house single quotes.
 */
@:nullSafety(Strict)
final class HxComprehensionCloserSliceTest extends Test {

	/** TM-shaped config with `wrapping.comprehensionCuddledOpen` ON — the regime TM formats under. */
	private static final ON: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** Same config with the cuddled-open knob absent — the pre-knob leading-break regime. */
	private static final OFF: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** Knob ON but TIGHT (unpadded) comprehension brackets — `comprehensionFor: same`, where `shapeComprehensionBlockHug` declines. */
	private static final TIGHT_ON: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "same"}}';

	/** The reported shape (anonymised from a macro-generating build macro): reified body, curly tail, `];` glued to the body line. */
	private static final REIFIED_GLUED: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (fieldEntry in '
		+ 'fieldEntryCollection)\n\t\t\tmacro if ($$p{[\'sourceObject\', fieldEntry.slot]} != null) '
		+ '$$p{[fieldEntry.slot]} = $$p{[\'sourceObject\', fieldEntry.slot]} ];\n\t}\n}';

	/** Same comprehension with the closer on its own line at the declaration's indent — head-glue kept. */
	private static final REIFIED_OWN_LINE: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for ('
		+ 'fieldEntry in fieldEntryCollection)\n\t\t\tmacro if ($$p{[\'sourceObject\', fieldEntry.slot]} '
		+ '!= null) $$p{[fieldEntry.slot]} = $$p{[\'sourceObject\', fieldEntry.slot]}\n\t\t];\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * The reported site: a reification-tailed body is an EXPRESSION body, so its `]` drops to the opener's indent. The head-glue
	 * `= [ for (…)` is untouched — only the closer moves.
	 */
	public function testReifiedBraceTailComprehensionDropsCloser(): Void {
		Assert.equals(REIFIED_OWN_LINE, triviaWrite(REIFIED_GLUED, ON));
	}

	/** The new layout is a fixed point — re-writing it does not pull the closer back up. */
	public function testReifiedCloserLayoutIsIdempotent(): Void {
		Assert.equals(REIFIED_OWN_LINE, triviaWrite(REIFIED_OWN_LINE, ON));
	}

	/**
	 * The rule is not macro-specific: a plain ternary whose else-branch is an object literal has the same curly tail and the same
	 * expression body, so it gets the same closer.
	 */
	public function testPlainExprBraceTailComprehensionDropsCloser(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (elementValue in sourceCollectionValue)\n'
			+ '\t\t\tresolveCaption(elementValue) == null ? fallbackDescriptor : {'
			+ 'caption: elementValue.caption, detail: elementValue.detail} ];\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (elementValue in sourceCollectionValue)\n'
			+ '\t\t\tresolveCaption(elementValue) == null ? fallbackDescriptor : {'
			+ 'caption: elementValue.caption, detail: elementValue.detail}\n\t\t];\n\t}\n}';
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/**
	 * The body's line COUNT is not the gate. A curly-tailed body that renders across TWO continuation lines glued its closer exactly
	 * like the one-line body above — so the fix must move this one too, not just the single-line case.
	 */
	public function testTwoLineReifiedBodyAlsoDropsCloser(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection)\n'
			+ '\t\t\tmacro if (checkEntryIsAssignable(sourceObject, fieldEntry.slot, fallbackDescriptorValue, comparisonStrategyValue)) '
			+ '$$p{[fieldEntry.slot]} = $$p{[\'sourceObject\', fieldEntry.slot]} ];\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection)\n'
			+ '\t\t\tmacro if (checkEntryIsAssignable(sourceObject, fieldEntry.slot, fallbackDescriptorValue, comparisonStrategyValue))\n'
			+ "\t\t\t\t$p{[fieldEntry.slot]} = $p{['sourceObject', fieldEntry.slot]}\n\t\t];\n\t}\n}";
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** The precedent this slice converges on: a body ending in `)` already dropped its closer and must stay byte-identical. */
	public function testNonBraceTailBodyCloserUnchanged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection)\n'
			+ "\t\t\tmacro o.put($v{fieldEntry.tag}, resolveEntryValue(sourceObject, fieldEntry.slot, fallbackDescriptorValue, "
			+ 'strategyValue))\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A curly-tailed comprehension that FITS one line never reaches either shape (no hardline) — byte-identical. */
	public function testFittingBraceTailComprehensionStaysFlat(): Void {
		final src: String = 'class C {\n\tfunction test() {\n'
			+ "\t\tfinal resultList = [ for (fieldEntry in fieldEntryCollection) macro $p{[fieldEntry.slot]} ];\n\t}\n}";
		Assert.equals(src, triviaWrite(src, ON));
	}

	/**
	 * Knob OFF, same misclassification: the curly tail used to buy a head-hug that the pre-knob regime grants no other expression
	 * body. It now leading-breaks like every one of them.
	 */
	public function testKnobOffBraceTailLeadingBreaks(): Void {
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [\n\t\t\tfor ('
			+ 'fieldEntry in fieldEntryCollection)\n\t\t\t\tmacro if ($$p{[\'sourceObject\', fieldEntry.slot]} != null) '
			+ '$$p{[fieldEntry.slot]} = $$p{[\'sourceObject\', fieldEntry.slot]}\n\t\t];\n\t}\n}';
		Assert.equals(expected, triviaWrite(REIFIED_GLUED, OFF));
	}

	/**
	 * A GENUINE block body whose `{` carries a trailing LINE comment. The comment is its own Text atom after the `{`, so a
	 * comment-blind head-glue probe would read the comment's last char, call the body an expression body, and split `}` and `];`
	 * onto two lines at the SAME indent — the exact shape `isCuddleableComprehensionItem`'s block gate exists to prevent, and worse
	 * than the pre-slice output. `firstBreakIsDelimChar` skips comment atoms, so this is byte-identical to base.
	 */
	public function testBlockBodyWithTrailingLineCommentKeepsBlockHug(): Void {
		final src: String = 'class C {\n\tfunction test() {\n'
			+ '\t\tfinal resultList = [ for (typeKey => colorList in folderColorsMapValueHere) { // note\n'
			+ '\t\t\tfinal bitmapValue = makeBitmapFromColors(colorList);\n\t\t\tbitmapValue;\n\t\t} ];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** Same hazard with a trailing BLOCK comment — a second atom shape the head-glue probe must see through. */
	public function testBlockBodyWithTrailingBlockCommentKeepsBlockHug(): Void {
		final src: String = 'class C {\n\tfunction test() {\n'
			+ '\t\tfinal resultList = [ for (typeKey => colorList in folderColorsMapValueHere) { /* note */\n'
			+ '\t\t\tfinal bitmapValue = makeBitmapFromColors(colorList);\n\t\t\tbitmapValue;\n\t\t} ];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** The comment-free control for the two above — the shape they must stay byte-identical to. */
	public function testBlockBodyWithoutCommentKeepsBlockHug(): Void {
		final src: String = 'class C {\n\tfunction test() {\n'
			+ '\t\tfinal resultList = [ for (typeKey => colorList in folderColorsMapValueHere) {\n'
			+ '\t\t\tfinal bitmapValue = makeBitmapFromColors(colorList);\n\t\t\tbitmapValue;\n\t\t} ];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A `switch` body that OPENS on the head line is head-glued, so its `}` is already at container indent and `} ]` stays. */
	public function testHeadGluedSwitchBodyKeepsBlockHug(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (elementValue in sourceCollectionValue) '
			+ 'switch elementValue.kindValue {\n\t\t\tcase KAlpha: alphaDescriptor;\n\t\t\tcase _: betaDescriptor;\n\t\t} ];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/**
	 * The same `switch` buried in a ternary sits on a CONTINUATION line, so its `}` is at body indent. Base glued `} ];` there;
	 * the closer now drops to the declaration's indent.
	 */
	public function testTernarySwitchBodyDropsCloser(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (elementValue in sourceCollectionValue)\n'
			+ '\t\t\tresolveCaption(elementValue) == null\n\t\t\t\t? fallbackDescriptorValue\n\t\t\t\t: switch elementValue.kindValue {\n'
			+ '\t\t\t\t\tcase KAlpha: alphaDescriptor;\n\t\t\t\t\tcase _: betaDescriptor;\n\t\t\t\t} ];\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (elementValue in sourceCollectionValue)\n'
			+ '\t\t\tresolveCaption(elementValue) == null\n\t\t\t\t? fallbackDescriptorValue\n\t\t\t\t: switch elementValue.kindValue {\n'
			+ '\t\t\t\t\tcase KAlpha: alphaDescriptor;\n\t\t\t\t\tcase _: betaDescriptor;\n\t\t\t\t}\n\t\t];\n\t}\n}';
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/**
	 * A `while` comprehension satisfies NEITHER predicate — the block gate no longer claims it (its body is on a continuation line)
	 * and `isCuddleableComprehensionItem` is `for`-only — so it reaches the generic cascade and leading-breaks. Base head-glued it
	 * (`} ];`) with the body dedented BELOW the declaration, which the `HxWhileExpr`-has-no-body-policy exclusion exists to avoid.
	 */
	public function testWhileComprehensionBraceTailLeadingBreaks(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ while (iteratorValue.hasNextElement())\n'
			+ "\t\t\tmacro if ($p{['sourceObject', fieldEntry.slot]} != null) $p{[fieldEntry.slot]} "
			+ '= $$p{[\'sourceObject\', fieldEntry.slot]} ];\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [\n\t\t\twhile (iteratorValue.hasNextElement())\n'
			+ "\t\t\tmacro if ($p{['sourceObject', fieldEntry.slot]} != null) $p{[fieldEntry.slot]} "
			+ '= $$p{[\'sourceObject\', fieldEntry.slot]}\n\t\t];\n\t}\n}';
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** A NESTED-generator comprehension is the second neither-predicate shape: base head-glued the curly tail, it now leading-breaks. */
	public function testNestedGeneratorBraceTailLeadingBreaks(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [ for (outerElement in outerCollectionValue) for ('
			+ 'innerElement in innerCollectionValue)\n\t\t\tmacro if ($$p{[\'sourceObject\', innerElement.slot]} != null) '
			+ '$$p{[outerElement.slot]} = $$p{[\'sourceObject\', innerElement.slot]} ];\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [\n'
			+ '\t\t\tfor (outerElement in outerCollectionValue) for (innerElement in innerCollectionValue)\n'
			+ "\t\t\t\tmacro if ($p{['sourceObject', innerElement.slot]} != null) $p{[outerElement.slot]} "
			+ '= $$p{[\'sourceObject\', innerElement.slot]}\n\t\t];\n\t}\n}';
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/**
	 * TIGHT brackets, knob ON: `shapeComprehensionBlockHug` declines there regardless, so the curly tail used to fall through to
	 * the generic cascade and leading-break the `[`. It now cuddles like every other expression body under the knob.
	 */
	public function testTightBracketBraceTailCuddles(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [\n\t\t\tfor (fieldEntry in fieldEntryCollection)\n'
			+ "\t\t\t\tmacro if ($p{['sourceObject', fieldEntry.slot]} != null) $p{[fieldEntry.slot]} "
			+ '= $$p{[\'sourceObject\', fieldEntry.slot]}\n\t\t];\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal resultList = [for (fieldEntry in fieldEntryCollection)\n'
			+ "\t\t\tmacro if ($p{['sourceObject', fieldEntry.slot]} != null) $p{[fieldEntry.slot]} "
			+ '= $$p{[\'sourceObject\', fieldEntry.slot]}\n\t\t];\n\t}\n}';
		Assert.equals(expected, triviaWrite(src, TIGHT_ON));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}
