package unit;

import utest.Assert;
import utest.Test;

/**
 * omega-header-wrap-ladder: a `for` / `while` / `if` HEADER is measured
 * ALONE, without the fitLine body that may ride its line.
 *
 * The construct's layout follows a priority ladder:
 *
 *  1. header + body fit one line -> one line;
 *  2. the HEADER ALONE fits -> the header stays FLAT (a method chain in
 *     it does NOT break over its links) and the body drops to the next
 *     line;
 *  3. the header alone does NOT fit -> the paren opens
 *     (`fillLineWithLeadingBreak`), the clause sits one indent deeper,
 *     `)` returns to the construct's indent and the body glues after it;
 *  4. the clause does not fit even one indent deeper -> it breaks over
 *     its own links there, `)` and the body as in 3.
 *
 * Step 2 is the one this slice adds; 1, 3 and 4 are pinned here because
 * they are the shapes the change had to preserve. Before it, the
 * chain-emit `IfFullLineExceeds` probe measured the header PLUS the
 * glued body (`flatTokenWidthOfRestStackFull` descends the body's
 * `BodyGroup`), so a fitting header broke over its links purely because
 * of the body's width — and the now-short last link then re-glued the
 * body onto its `))`. A body is never again glued to a multi-line
 * header: once the header opens (steps 3 and 4) the body follows the
 * `)` that closed it, at the construct's own indent.
 */
@:nullSafety(Strict)
final class HxHeaderWrapLadderSliceTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak",'
		+ ' "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}},'
		+ ' "sameLine": {"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine"}}';

	private static final LADDER_FOR: String = 'class C {\n\tfunction f(text:String):Bool {\n'
		+ '\t\tfor (word in text.trim().toLowerCase().split(\' \')) if (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1)\n'
		+ '\t\t\treturn false;\n\t\treturn true;\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * Step 2 on the case that motivated the slice. The header alone is 57
	 * columns and the whole construct 148, so the chain stays flat and the
	 * body drops. Fed the OLD chain-broken shape, so the assertion cannot
	 * be satisfied by leaving the input alone, and the expected text holds
	 * the flat chain and the dropped body in ONE string.
	 */
	public function testForChainHeaderFitsBodyDrops(): Void {
		final broken: String = 'class C {\n\tfunction f(text:String):Bool {\n' + '\t\tfor (word in text.trim()\n\t\t\t.toLowerCase()\n'
			+ '\t\t\t.split(\' \')) if (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1) return false;\n'
			+ '\t\treturn true;\n\t}\n}';
		Assert.equals(LADDER_FOR, triviaWrite(broken));
	}

	public function testForLadderIsIdempotent(): Void {
		Assert.equals(LADDER_FOR, triviaWrite(LADDER_FOR));
	}

	/**
	 * Step 2 for `while`. The body is a nested construct on purpose: its
	 * OWN body sits behind a `BodyGroup` the enclosing fit measure defers,
	 * so the header line stays under the limit and the header's chain is
	 * the only thing that can move it. A plain-call body does NOT
	 * discriminate here — it is fully counted, the whole construct group
	 * breaks first, and the chain sees a hardline instead of a body.
	 */
	public function testWhileChainHeaderFitsBodyDrops(): Void {
		final broken: String = 'class C {\n\tfunction f(text:String):Void {\n' + '\t\twhile (text.trim()\n\t\t\t.toLowerCase()\n'
			+ '\t\t\t.split(\' \').length > 0) if (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1) return false;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f(text:String):Void {\n'
			+ '\t\twhile (text.trim().toLowerCase().split(\' \').length > 0) if (_questionText.indexOf(word) == -1'
			+ ' && _answerText.indexOf(word) == -1)\n\t\t\treturn false;\n\t}\n}';
		Assert.equals(expected, triviaWrite(broken));
	}

	/** Step 2 for `if` — same nested-construct body as the `while` case above. */
	public function testIfChainHeaderFitsBodyDrops(): Void {
		final broken: String = 'class C {\n\tfunction f(text:String):Void {\n' + '\t\tif (text.trim()\n\t\t\t.toLowerCase()\n'
			+ '\t\t\t.split(\' \').length > 0) if (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1) return false;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f(text:String):Void {\n'
			+ '\t\tif (text.trim().toLowerCase().split(\' \').length > 0) if (_questionText.indexOf(word) == -1'
			+ ' && _answerText.indexOf(word) == -1)\n\t\t\treturn false;\n\t}\n}';
		Assert.equals(expected, triviaWrite(broken));
	}

	/** Step 1: a body that fits beside the header keeps the same line. */
	public function testWholeConstructFitsStaysOneLine(): Void {
		final src: String = 'class C {\n\tfunction f(text:String):Void {\n'
			+ '\t\tfor (word in text.trim().toLowerCase().split(\' \')) dispatchSomeEventToTheListener(word, extraArgumentValue, anotherArgumentValueX);\n'
			+ '\t\tfor (word in text.trim().toLowerCase().split(\' \')) trace(word);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * Step 3: the header alone does not fit, so the paren opens and the
	 * clause — which DOES fit one indent deeper — stays flat there. The
	 * body glues after the `)` at the `for`'s own indent, never onto a
	 * chain link.
	 */
	public function testHeaderTooWideOpensParenAndBodyFollowsCloseParen(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfor (\n'
			+ '\t\t\twordItem in someLongerReceiverNameXXXXXXXX.trimTheString().toLowerCaseVariant().splitOnTheSeparator(\' \').filterOutEmptyEntries()\n'
			+ '\t\t) trace(wordItem);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
