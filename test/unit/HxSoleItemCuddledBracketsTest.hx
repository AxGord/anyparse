package unit;

import utest.Assert;
import utest.Test;

/**
 * omega-solitem-cuddled-brackets: `wrapping.soleItemCuddledBrackets` (default
 * `false`) keeps both brackets of a ONE-element `[ … ]` list cuddled to that
 * element — `[makeEntryRecord({` … `})]` — instead of breaking the `[` onto its
 * own line and nesting the element one level deeper.
 *
 * The claim under test is about what a leading break BUYS: for a sole element
 * that lays out across lines anyway, it rescues no line and costs two of them.
 * The decision is the renderer's (`IfNaturalFirstLineFitsOpenDelim`), so the
 * refusals below are the interesting half — an element with no wrap point of
 * its own must never be pinned flat past `maxLineLength`.
 *
 * With the knob absent / `false` the writer is byte-identical to the pre-knob
 * leading-break layout.
 */
@:nullSafety(Strict)
final class HxSoleItemCuddledBracketsTest extends Test {

	/** project-shaped config (tab indent, maxLineLength 140, ifBody/comprehensionFor fitLine, expressionIf next) with the knob OFF. */
	private static final OFF: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** Same config with `wrapping.soleItemCuddledBrackets` turned on. */
	private static final ON: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "soleItemCuddledBrackets": true},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** A sole `for` comprehension whose body is a call with an object-literal argument, in the exploded leading-break layout. */
	private static final COMPREHENSION_EXPLODED: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n'
		+ '\t\t\tfor (indexValue in sourceCollectionValue) makeEntryRecord({\n'
		+ '\t\t\t\tcaptionValue: indexValue.captionValue,\n\t\t\t\tdetailValue: '
		+ 'indexValue.detailValue,\n\t\t\t\torderValue: indexValue.orderValue\n\t\t\t})\n\t\t];\n\t}\n}';

	/** The same comprehension cuddled — padded brackets, since `comprehensionFor: fitLine` pads them. */
	private static final COMPREHENSION_CUDDLED: String = 'class C {\n\tfunction test() {\n'
		+ '\t\tfinal r = [ for (indexValue in sourceCollectionValue) makeEntryRecord({\n'
		+ '\t\t\tcaptionValue: indexValue.captionValue,\n\t\t\tdetailValue: '
		+ 'indexValue.detailValue,\n\t\t\torderValue: indexValue.orderValue\n\t\t}) ];\n\t}\n}';

	/** A sole plain call element in the exploded leading-break layout. */
	private static final SOLE_CALL_EXPLODED: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n\t\t\tmakeEntryRecord({\n'
		+ '\t\t\t\tcaptionValue: sourceValue.captionValue,\n' + '\t\t\t\tdetailValue: sourceValue.detailValue,\n'
		+ '\t\t\t\torderValue: sourceValue.orderValue\n\t\t\t})\n\t\t];\n\t}\n}';

	/** The same call cuddled — tight brackets, since an array literal pads nothing. */
	private static final SOLE_CALL_CUDDLED: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [makeEntryRecord({\n'
		+ '\t\t\tcaptionValue: sourceValue.captionValue,\n\t\t\tdetailValue: sourceValue.detailValue,\n'
		+ '\t\t\torderValue: sourceValue.orderValue\n\t\t})];\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** Knob absent (`false`): the exploded list keeps its leading-break layout — byte-inert default. */
	public function testKnobOffKeepsLeadingBreak(): Void {
		Assert.equals(COMPREHENSION_EXPLODED, triviaWrite(COMPREHENSION_EXPLODED, OFF));
		Assert.equals(SOLE_CALL_EXPLODED, triviaWrite(SOLE_CALL_EXPLODED, OFF));
	}

	/** Knob on: a sole comprehension element rides the `[` line and the `]` glues to its closing `)`. */
	public function testComprehensionElementCuddles(): Void {
		Assert.equals(COMPREHENSION_CUDDLED, triviaWrite(COMPREHENSION_EXPLODED, ON));
	}

	/** Knob on: a sole plain CALL element cuddles the same way — the shape is not comprehension-specific. */
	public function testSoleCallElementCuddles(): Void {
		Assert.equals(SOLE_CALL_CUDDLED, triviaWrite(SOLE_CALL_EXPLODED, ON));
	}

	/** The cuddled layout is a fixed point (no oscillation between writes). */
	public function testCuddledLayoutIsIdempotent(): Void {
		final once: String = triviaWrite(COMPREHENSION_EXPLODED, ON);
		Assert.equals(once, triviaWrite(once, ON));
		final callOnce: String = triviaWrite(SOLE_CALL_EXPLODED, ON);
		Assert.equals(callOnce, triviaWrite(callOnce, ON));
	}

	/**
	 * An element with NO wrap point of its own keeps the exploded layout: cuddling would pin its whole width onto the `[` line, past
	 * `maxLineLength`. This is the probe's fit conjunct — the one that makes the knob safe rather than merely compact.
	 */
	public function testElementWithoutWrapPointNotCuddled(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n'
			+ '\t\t\tfor (candidateEntry in collectionOwnerReferenceValue.candidateEntryCollection) if ('
			+ 'candidateEntry is PrimaryEntryKind)\n\t\t\t\tcandidateEntry\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** An element that breaks at an OPERATOR rather than at an open delimiter keeps the exploded layout — the probe's second conjunct. */
	public function testOperatorBreakElementNotCuddled(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n\t\t\tfirstLongOperandIdentifierValueName + '
			+ 'secondLongOperandIdentifierValueName + thirdLongOperandIdentifierValueName\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** An element whose last token is an OPERAND, not a close delimiter, would strand the `]` at body indent — refused. */
	public function testOperandTailElementNotCuddled(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n'
			+ '\t\t\tfor (actionEntry in incrementalCloudActionCollection) if (actionEntry.actionKind == DELETED\n'
			+ '\t\t\t\t&& actionEntry.filePathValue.startsWith(SharedConstants.SHARED_PREFIX_VALUE))\n'
			+ '\t\t\t\tactionEntry.filePathValue\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A trailing LINE comment on the element is refused: a cuddled `]` would be swallowed by the comment. */
	public function testTrailingLineCommentNotCuddled(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n\t\t\tmakeEntryRecord({\n\t\t\t\tcaptionValue: '
			+ 'sourceValue.captionValue,\n\t\t\t\tdetailValue: sourceValue.detailValue\n\t\t\t}) // keep me\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A MULTI-element list is untouched — cuddling one element would strand its siblings. */
	public function testMultiElementListNotCuddled(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n'
			+ '\t\t\tmakeEntryRecord({captionValue: \'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\', detailValue: \'bbbbbbbbbbbbbbbbbbbb\'}),'
			+ '\n\t\t\tmakeEntryRecord({captionValue: \'cccccccccccccccccccccccccccccccccccccccc\', detailValue: '
			+ '\'dddddddddddddddddddd\'})\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A `{`-delimited list with a sole field is untouched: the knob is bracket-gated, so an object literal keeps its own policies. */
	public function testObjectLiteralDelimiterNotCuddled(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = {\n\t\t\tcaptionValue: makeEntryRecord({\n'
			+ '\t\t\t\tcaptionValue: sourceValue.captionValue,\n\t\t\t\tdetailValue: sourceValue.detailValue,\n'
			+ '\t\t\t\torderValue: sourceValue.orderValue\n\t\t\t})\n\t\t};\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A sole element carrying a FORCED hardline (a block-bodied local function) cuddles too — its `}` is already at container indent. */
	public function testBlockBodyElementCuddles(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n\t\t\tfunction():Void {\n'
			+ '\t\t\t\tdoSomethingUsefulHere(sourceValue);\n\t\t\t\tdoSomethingElseHere(sourceValue);\n\t\t\t}\n\t\t];\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [function():Void {\n'
			+ '\t\t\tdoSomethingUsefulHere(sourceValue);\n\t\t\tdoSomethingElseHere(sourceValue);\n\t\t}];\n\t}\n}';
		Assert.equals(expected, triviaWrite(src, ON));
	}

	/** A list that already fits one line is untouched by the knob — `NoWrap` cuddles on its own and the shape declines for it. */
	public function testFittingListStaysFlat(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [makeEntryRecord(sourceValue)];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}
