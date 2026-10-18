package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddElement;
import anyparse.query.CanonicalEdit.EditResult;
import utest.Assert;
import utest.Test;

/**
 * `AddElement.insertSorted` — `add-element --sorted`: string entries land at their sorted positions in
 * an array of constant strings, the shape of the hand-kept registries (`TestDiscoveryParityTest`'s class list,
 * the pin census parts in `unit.census`) agents used to edit with a script. Every accepted case asserts the whole
 * canonical file; every refusal names why, because a refused insert must not look like a silent one.
 */
class AddElementSortedTest extends Test {

	/** Two entries, given out of order, each land in their own gap. */
	public function testEachEntryLandsAtItsSortedPosition(): Void {
		assertSorted(list("'a', 'c', 'e'"), "'d', 'b'", list("'a', 'b', 'c', 'd', 'e'"));
	}

	/** An entry sorting before every element goes first, one sorting after every element last. */
	public function testEntriesAtBothEnds(): Void {
		assertSorted(list("'b', 'c'"), "'z', 'a'", list("'a', 'b', 'c', 'z'"));
	}

	/** Code-unit order, as `TestDiscovery` sorts: an upper-case letter sorts before every lower-case one. */
	public function testCodeUnitOrder(): Void {
		assertSorted(list("'a', 'b'"), "'Z'", list("'Z', 'a', 'b'"));
	}

	/**
	 * An empty array takes the entries in order — one gap, so the order is the sort's, not the argument's.
	 */
	@:pin('control')
	@:killer('M-SORTED-UNSORTED-ENTRIES')
	public function testEmptyArray(): Void {
		assertSorted(list(''), "'b', 'a'", list("'a', 'b'"));
	}

	/** A one-per-line list keeps its layout, and an entry copied with its separator is accepted. */
	public function testMultiLineListKeepsItsLayout(): Void {
		final source: String = 'class C {\n\tstatic final A:Array<String> = [\n\t\t\'unit.a.FirstTest\',\n\t\t\'unit.c.ThirdTest\',\n'
			+ '\t\t\'unit.d.FourthTestWithAVeryLongNameThatKeepsTheListOnSeveralLines\'\n\t];\n}\n';
		final expected: String = 'class C {\n\tstatic final A:Array<String> = [\n\t\t\'unit.a.FirstTest\',\n\t\t\'unit.b.SecondTest\',\n'
			+ '\t\t\'unit.c.ThirdTest\',\n\t\t\'unit.d.FourthTestWithAVeryLongNameThatKeepsTheListOnSeveralLines\'\n\t];\n}\n';
		assertSorted(source, "'unit.b.SecondTest',", expected);
	}

	/** An entry landing before a documented element goes above that element's doc, which stays its own. */
	@:pin('control')
	@:killer('M-SORTED-SPLITS-DOC')
	public function testEntryLandsAboveTheNextElementsDoc(): Void {
		final source: String = 'class C {\n\tstatic final A:Array<String> = [\n\t\t\'a\',\n\t\t/** The c group. */\n\t\t\'c\',\n'
			+ '\t\t\'unit.d.FourthTestWithAVeryLongNameThatKeepsTheListOnSeveralLines\'\n\t];\n}\n';
		final expected: String = 'class C {\n\tstatic final A:Array<String> = [\n\t\t\'a\',\n\t\t\'b\',\n\t\t/** The c group. */\n'
			+ '\t\t\'c\',\n\t\t\'unit.d.FourthTestWithAVeryLongNameThatKeepsTheListOnSeveralLines\'\n\t];\n}\n';
		assertSorted(source, "'b'", expected);
	}

	/** A concatenated entry — the spelling of an entry too wide for its line — sorts by its whole value. */
	@:pin('control')
	@:killer('M-SORTED-NO-CONCAT')
	public function testConcatenatedEntriesSortByTheirValue(): Void {
		assertSorted(list("'a' + 'c', 'b'"), "'a' + 'b'", list("'a' + 'b', 'a' + 'c', 'b'"));
	}

	/** An entry the list already holds is refused, and so is one given twice. */
	@:pin('control')
	@:killer('M-SORTED-DUP-UNCHECKED')
	public function testDuplicateIsRefused(): Void {
		assertRefused(list("'a', 'b'"), "'b'", 'already in the list');
		assertRefused(list("'a', 'c'"), "'b', 'b'", 'already in the list');
	}

	/** A list that is not already sorted is not reordered behind the caller's back. */
	@:pin('control')
	@:killer('M-SORTED-ORDER-UNCHECKED')
	public function testUnsortedListIsRefused(): Void {
		assertRefused(list("'b', 'a'"), "'c'", 'not sorted');
	}

	/** A non-string element, existing or new, has no place in a sorted string list. */
	public function testNonStringElementIsRefused(): Void {
		assertRefused(list("'a', 1"), "'b'", 'not a constant string');
		assertRefused(list("'a'"), '1', 'not a constant string');
	}

	/** An escape or an interpolation makes a literal's raw text differ from its value, so its position would be a guess. */
	@:pin('control')
	@:killer('M-SORTED-RAW-ESCAPES')
	public function testEscapedOrInterpolatedEntryIsRefused(): Void {
		assertRefused(list("'a'"), "'b\\n'", 'not a constant string');
		assertRefused(list("'a'"), "'$$x'", 'not a constant string');
	}

	/** The address must be an array literal. */
	@:pin('control')
	@:killer('M-SORTED-ANY-CONTAINER')
	public function testNonArrayContainerIsRefused(): Void {
		assertRefused(
			'class C {\n\tfunction f():Void {\n\t\tg(\'a\');\n\t}\n}\n', "'b'", 'not on the first token of an array literal', 3, 3
		);
	}

	/** `class C { static final A:Array<String> = [<items>]; }`, canonical, its array at 2:33. */
	private static function list(items: String): String {
		return 'class C {\n\tstatic final A:Array<String> = [$items];\n}\n';
	}

	private static function assertSorted(source: String, code: String, expected: String): Void {
		switch insert(source, code, 2, 33) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected the insert to apply, got: $message');
		}
	}

	private static function assertRefused(source: String, code: String, reason: String, line: Int = 2, col: Int = 33): Void {
		switch insert(source, code, line, col) {
			case Ok(text):
				Assert.fail('expected a refusal naming "$reason", got:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf(reason) >= 0, 'refusal "$message" should name "$reason"');
		}
	}

	private static function insert(source: String, code: String, line: Int, col: Int): EditResult {
		return AddElement.insertSorted(source, line, col, code, false, new HaxeQueryPlugin());
	}

}
