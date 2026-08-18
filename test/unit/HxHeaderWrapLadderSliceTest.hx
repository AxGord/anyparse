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
 * Step 2 is the one this slice adds. Before it, the chain-emit
 * `IfFullLineExceeds` probe measured the header PLUS the glued body
 * (`flatTokenWidthOfRestStackFull` descends the body's `BodyGroup`), so
 * a fitting header broke over its links purely because of the body's
 * width — and the body then glued onto the last link's `))`, a shape
 * step 2 replaces and the ladder never produces again.
 */
@:nullSafety(Strict)
final class HxHeaderWrapLadderSliceTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak",'
		+ ' "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}},'
		+ ' "sameLine": {"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine"}}';

	private static final LADDER_FOR: String = 'class C {\n\tfunction f(text:String):Bool {\n'
		+ '\t\tfor (word in text.trim().toLowerCase().split(\' \'))\n'
		+ '\t\t\tif (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1) return false;\n'
		+ '\t\treturn true;\n\t}\n}';

	private static final LADDER_WHILE: String = 'class C {\n\tfunction f(text:String):Bool {\n'
		+ '\t\twhile (text.trim().toLowerCase().split(\' \').length > 0)\n'
		+ '\t\t\tif (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1) return false;\n'
		+ '\t\treturn true;\n\t}\n}';

	private static final LADDER_IF: String = 'class C {\n\tfunction f(text:String):Bool {\n'
		+ '\t\tif (text.trim().toLowerCase().split(\' \').length > 0)\n'
		+ '\t\t\tif (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1) return false;\n'
		+ '\t\treturn true;\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * Step 2 for `for`: the header alone is 57 columns and the whole
	 * construct is 147, so the chain stays flat and the body drops.
	 * Fed the OLD glued-to-`))` shape, so the assertion cannot be
	 * satisfied by leaving the input alone.
	 */
	public function testForChainHeaderFitsBodyDrops(): Void {
		final broken: String = 'class C {\n\tfunction f(text:String):Bool {\n'
			+ '\t\tfor (word in text.trim()\n\t\t\t.toLowerCase()\n'
			+ '\t\t\t.split(\' \')) if (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1) return false;\n'
			+ '\t\treturn true;\n\t}\n}';
		Assert.equals(LADDER_FOR, triviaWrite(broken));
	}

	public function testForLadderIsIdempotent(): Void {
		Assert.equals(LADDER_FOR, triviaWrite(LADDER_FOR));
	}

	public function testWhileChainHeaderFitsBodyDrops(): Void {
		final broken: String = 'class C {\n\tfunction f(text:String):Bool {\n'
			+ '\t\twhile (text.trim()\n\t\t\t.toLowerCase()\n'
			+ '\t\t\t.split(\' \').length > 0) if (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1) return false;\n'
			+ '\t\treturn true;\n\t}\n}';
		Assert.equals(LADDER_WHILE, triviaWrite(broken));
	}

	public function testIfChainHeaderFitsBodyDrops(): Void {
		final broken: String = 'class C {\n\tfunction f(text:String):Bool {\n'
			+ '\t\tif (text.trim()\n\t\t\t.toLowerCase()\n'
			+ '\t\t\t.split(\' \').length > 0) if (_questionText.indexOf(word) == -1 && _answerText.indexOf(word) == -1) return false;\n'
			+ '\t\treturn true;\n\t}\n}';
		Assert.equals(LADDER_IF, triviaWrite(broken));
	}

	/** Step 1 is preserved: a body that fits beside the header stays glued. */
	public function testShortBodyStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction f(text:String):Void {\n'
			+ '\t\tfor (word in text.trim().toLowerCase().split(\' \')) trace(word);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
