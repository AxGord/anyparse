package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A comprehension under `fitLine` whose head, filter and body do not fit on one line moves the body to the next line
 * before it wraps the head's own iterable call: a head that fits flat stays flat, and only a head that alone overflows
 * breaks its call.
 */
@:nullSafety(Strict)
final class HxComprehensionHeadWrapTest extends Test {

	private static final HEAD: String = 'for (c in scan(tree, source, seams))';
	private static final FILTER_AND_BODY: String =
		"if (c.fixable && flagged.contains(keyOfSpan(c.tailSpan.from, c.tailSpan.to))) { span: c.removeSpan, text: '' }";

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-COMPREHENSION-REST-CUT-OFF')
	public function testTheBodyMovesBeforeTheHeadCallWrapsUnderFitLine(): Void {
		Assert.equals(
			wrapped('$HEAD\n\t\t\t\t$FILTER_AND_BODY'),
			HxWriteFixture.triviaWrite(wrapped('$HEAD $FILTER_AND_BODY'), cfg('"comprehensionFor": "fitLine", '))
		);
	}

	@:pin('control')
	@:killer('M-COMPREHENSION-REST-CUT-OFF')
	public function testTheBodyMovesBeforeTheHeadCallWrapsWhenTheKeyIsAbsent(): Void {
		Assert.equals(wrapped('$HEAD\n\t\t\t\t$FILTER_AND_BODY'), HxWriteFixture.triviaWrite(wrapped('$HEAD $FILTER_AND_BODY'), cfg('')));
	}

	@:pin('control')
	@:killer('M-COMPREHENSION-BODY-ALWAYS-NEXT')
	public function testAShortComprehensionStaysOnOneLine(): Void {
		final broken: String = wrapped('for (c in scan(tree, source, seams)) if (c.fixable) c.removeSpan');
		final oneLine: String =
			'class C {\n\tfunction f() {\n\t\tfinal edits = [for (c in scan(tree, source, seams)) if (c.fixable) c.removeSpan];\n\t}\n}';
		Assert.equals(oneLine, HxWriteFixture.triviaWrite(broken, cfg('')));
	}

	@:pin('guard')
	public function testAHeadThatAloneOverflowsStillWrapsItsCall(): Void {
		final arguments: String =
			'firstScanArgumentWithALongName, secondScanArgumentWithALongName, thirdScanArgumentWithALongName, fourthScanArgumentName';
		final flat: String = wrapped('for (c in scanEveryCandidateOfTheTree($arguments)) if (c.fixable) c.removeSpan');
		final broken: String = wrapped('for (c in scanEveryCandidateOfTheTree(\n\t\t\t\t$arguments\n\t\t\t)) if (c.fixable) c.removeSpan');
		Assert.equals(broken, HxWriteFixture.triviaWrite(flat, cfg('')));
	}

	/** A comprehension element at the repo's array depth. */
	private static function wrapped(element: String): String {
		return 'class C {\n\tfunction f() {\n\t\tfinal edits = [\n\t\t\t$element\n\t\t];\n\t}\n}';
	}

	/** The wrapping and body keys of this repository's own `hxformat.json`; `sameLine` optionally names `comprehensionFor`. */
	private static function cfg(comprehensionFor: String): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {'
			+ '"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
			+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"},{"conditions": [{"cond": "itemCount <= n", "value": 1}, {'
			+ '"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}, "whitespace": {"bracesConfig": {'
			+ '"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}}}, "sameLine": {$comprehensionFor'
			+ '"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine", "expressionIf": "next"}}';
	}

}
