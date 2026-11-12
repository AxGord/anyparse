package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * Under `forBody`/`whileBody` `fitLine`, an object-literal comprehension body that does not fit beside a fitting head
 * moves one indent below the head before the head's own call wraps, for `for` and `while` alike; a literal that fits
 * beside the head stays there, and a head that alone overflows still wraps its call.
 */
@:nullSafety(Strict)
final class HxComprehensionObjectLitBodyMoveTest extends Test {

	private static final LITERAL: String =
		"{span: c.removeSpan, text: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx', other: c.otherrrrrrrrrrrrrrrrr}";
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"},{"conditions": ['
		+ '{"cond": "itemCount <= n", "value": 1}, {'
		+ '"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}},"sameLine": {'
		+ '"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine", "expressionIf": "next"}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ALLMAN-GLUE-NO-BELOW-FIT')
	public function testAForLiteralBodyMovesBelowAFittingHead(): Void {
		final head: String = 'for (c in Next(tree, source, seamsssssssssssssssssssssss))';
		Assert.equals(wrapped('$head\n\t\t\t\t$LITERAL'), HxWriteFixture.triviaWrite(oneLine('$head $LITERAL'), CFG));
	}

	@:pin('control')
	@:killer('M-ALLMAN-GLUE-NO-BELOW-FIT')
	public function testAWhileLiteralBodyMovesBelowAFittingHead(): Void {
		final head: String = 'while (hasNext(tree, source, seamsssssssssssssssssssssss))';
		Assert.equals(wrapped('$head\n\t\t\t\t$LITERAL'), HxWriteFixture.triviaWrite(oneLine('$head $LITERAL'), CFG));
	}

	@:pin('guard')
	public function testALiteralThatFitsBesideTheHeadStays(): Void {
		final element: String = 'for (c in Next(tree)) {span: c.removeSpan}';
		Assert.equals(oneLine(element), HxWriteFixture.triviaWrite(wrapped('for (c in Next(tree))\n\t\t\t\t{span: c.removeSpan}'), CFG));
	}

	@:pin('guard')
	public function testAHeadThatAloneOverflowsStillWrapsItsCall(): Void {
		final arguments: String =
			'firstScanArgumentWithALongName, secondScanArgumentWithALongName, thirdScanArgumentWithALongName, fourthScanArgumentName';
		final flat: String = oneLine('for (c in nextCandidateOfTheWholeTree($arguments)) {span: c}');
		final broken: String = wrapped('for (c in nextCandidateOfTheWholeTree(\n\t\t\t\t$arguments\n\t\t\t)) {span: c}');
		Assert.equals(broken, HxWriteFixture.triviaWrite(flat, CFG));
	}

	/** Under `comprehensionFor: same` a literal written below the head reaches its fixed point in one write. */
	@:pin('control')
	@:killer('M-ALLMAN-GLUE-MOVES-UNDER-ANY-POLICY')
	public function testComprehensionForSameSettlesALiteralBelowTheHeadInOneWrite(): Void {
		final config: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "objectLiteral": {'
			+ '"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": '
			+ '"noWrap"}]}},"sameLine": {"forBody": "fitLine", "comprehensionFor": "same"}}';
		final source: String = wrapped(
			'for (arg in branch.children)\n\t\t\t\t{ name: (arg.annotations.get(AnnotationKeys.BASE_FIELD_NAME): String), '
			+ 'type: shapeToComplexType(arg, synthPack) }'
		);
		final once: String = HxWriteFixture.triviaWrite(source, config);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, config));
	}

	/** The glue keeps a head-gap comment for a literal that cannot render flat. */
	@:pin('control')
	@:killer('M-ALLMAN-GLUE-NO-COMMENT-WRAP')
	public function testTheGlueKeepsAHeadGapCommentBeforeAMultiLineLiteral(): Void {
		final expected: String = wrapped('for (i in xs) // note\n\t\t\t\t{\n\t\t\t\t\t// lead\n\t\t\t\t\ta: i\n\t\t\t\t}');
		Assert.equals(
			expected, HxWriteFixture.triviaWrite(oneLine('for (i in xs) // note\n\t\t\t{\n\t\t\t\t// lead\n\t\t\t\ta: i\n\t\t\t}'), CFG)
		);
	}

	/** Another body under the glue knob that does not fit below the head still moves there and wraps its own call. */
	@:pin('control')
	@:killer('M-ALLMAN-GLUE-ANY-CTOR')
	public function testAnotherBodyTooWideForTheLineBelowStillMovesThere(): Void {
		final arguments: String =
			'firstArgumentWithALongName, secondArgumentWithALongName, thirdArgumentWithALongName, fourthArgumentWithALongName';
		final expected: String = wrapped('for (i in xs)\n\t\t\t\tsomeCall(\n\t\t\t\t\t$arguments,\n\t\t\t\t\tfifthArgument\n\t\t\t\t)');
		Assert.equals(expected, HxWriteFixture.triviaWrite(oneLine('for (i in xs) someCall($arguments, fifthArgument)'), CFG));
	}

	/** A comprehension written on the declaration's own line. */
	private static function oneLine(element: String): String {
		return 'class C {\n\tfunction f() {\n\t\tfinal edits = [$element];\n\t}\n}';
	}

	/** A comprehension element at the repo's array depth. */
	private static function wrapped(element: String): String {
		return 'class C {\n\tfunction f() {\n\t\tfinal edits = [\n\t\t\t$element\n\t\t];\n\t}\n}';
	}

}
