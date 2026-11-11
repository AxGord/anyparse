package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A `while` comprehension lays out like a `for` one: under `fitLine`, a body that does not fit beside the head moves
 * to the next line before the head's own condition call wraps; a head that fits flat stays flat, and only a head
 * that alone overflows breaks its call. `sameLine.comprehensionFor` reaches its body as it reaches a `for` body.
 */
@:nullSafety(Strict)
final class HxComprehensionWhileHeadWrapTest extends Test {

	private static final HEAD: String = 'while (hasNext(tree, source, seams))';
	private static final FILTER_AND_BODY: String =
		"if (c.fixable && flagged.contains(keyOfSpan(c.tailSpan.from, c.tailSpan.to))) { span: c.removeSpan, text: '' }";

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-WHILE-COMPREHENSION-NOT-STRICT')
	public function testTheBodyMovesBeforeTheHeadCallWrapsUnderFitLine(): Void {
		Assert.equals(
			wrapped('$HEAD\n\t\t\t\t$FILTER_AND_BODY'),
			HxWriteFixture.triviaWrite(wrapped('$HEAD $FILTER_AND_BODY'), cfg('"comprehensionFor": "fitLine", '))
		);
	}

	@:pin('control')
	@:killer('M-WHILE-COMPREHENSION-NOT-STRICT')
	public function testTheBodyMovesBeforeTheHeadCallWrapsWhenTheKeyIsAbsent(): Void {
		Assert.equals(wrapped('$HEAD\n\t\t\t\t$FILTER_AND_BODY'), HxWriteFixture.triviaWrite(wrapped('$HEAD $FILTER_AND_BODY'), cfg('')));
	}

	@:pin('control')
	@:killer('M-COMPREHENSION-BODY-ALWAYS-NEXT')
	public function testAShortComprehensionStaysOnOneLine(): Void {
		final broken: String = wrapped('while (hasNext(tree, source, seams)) if (c.fixable) c.removeSpan');
		final oneLine: String =
			'class C {\n\tfunction f() {\n\t\tfinal edits = [while (hasNext(tree, source, seams)) if (c.fixable) c.removeSpan];\n\t}\n}';
		Assert.equals(oneLine, HxWriteFixture.triviaWrite(broken, cfg('')));
	}

	@:pin('control')
	@:killer('M-WHILE-COMPREHENSION-NO-BODY-POLICY')
	public function testComprehensionForNextPutsTheBodyOneIndentBelowTheHead(): Void {
		final expected: String = wrapped('while (hasNext(tree))\n\t\t\t\tnext(tree)');
		Assert.equals(
			expected, HxWriteFixture.triviaWrite(oneLine('while (hasNext(tree)) next(tree)'), cfg('"comprehensionFor": "next", '))
		);
	}

	@:pin('control')
	@:killer('M-WHILE-COMPREHENSION-NO-BODY-POLICY')
	public function testComprehensionForSameKeepsTheBodyBesideTheHead(): Void {
		final expected: String = oneLine('while (hasNext(tree)) next(tree)');
		Assert.equals(
			expected, HxWriteFixture.triviaWrite(wrapped('while (hasNext(tree))\n\t\t\tnext(tree)'), cfg('"comprehensionFor": "same", '))
		);
	}

	@:pin('guard')
	public function testAHeadThatAloneOverflowsStillWrapsItsCall(): Void {
		final arguments: String =
			'firstScanArgumentWithALongName, secondScanArgumentWithALongName, thirdScanArgumentWithALongName, fourthScanArgumentName';
		final flat: String = wrapped('while (hasNextCandidateOfTheWholeTree($arguments)) if (c.fixable) c.removeSpan');
		final broken: String = wrapped('while (hasNextCandidateOfTheWholeTree(\n\t\t\t\t$arguments\n\t\t\t)) if (c.fixable) c.removeSpan');
		Assert.equals(broken, HxWriteFixture.triviaWrite(flat, cfg('')));
	}

	/** A comprehension written on the declaration's own line. */
	private static function oneLine(element: String): String {
		return 'class C {\n\tfunction f() {\n\t\tfinal edits = [$element];\n\t}\n}';
	}

	/** A comprehension element at the repo's array depth. */
	private static function wrapped(element: String): String {
		return 'class C {\n\tfunction f() {\n\t\tfinal edits = [\n\t\t\t$element\n\t\t];\n\t}\n}';
	}

	/** The wrapping and body keys of this repository's own `hxformat.json`; `comprehensionFor` optionally names that key. */
	private static function cfg(comprehensionFor: String): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {'
			+ '"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
			+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"},{"conditions": [{"cond": "itemCount <= n", "value": 1}, {'
			+ '"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}, "whitespace": {"bracesConfig": {'
			+ '"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}}}, "sameLine": {$comprehensionFor'
			+ '"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine", "expressionIf": "next"}}';
	}

}
