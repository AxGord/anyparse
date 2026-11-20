package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A paren-param arrow (`(a, b) -> …`) that is the sole call argument and whose if/else body stays multi-line breaks AFTER
 * `->` exactly as the bare-ident arrow does: the ladder is one indented block and the call's `)` sits on its own line.
 * A simple value chain that `sameLine.expressionIfFit` collapses stays on one line.
 */
@:nullSafety(Strict)
final class HxParenArrowIfElseBreakSliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final OFF: String = '$BASE, "sameLine": {"expressionIf": "next"}}';
	private static final ON: String = '$BASE, "sameLine": {"expressionIf": "next", "expressionIfFit": true}}';
	private static final LADDER: String = 'class C {\n\tfunction test() {\n\t\tmodules.sort((a, b) ->\n\t\t\tif (a < b)\n\t\t\t\t-1\n'
		+ '\t\t\telse if (a > b)\n\t\t\t\t1\n\t\t\telse\n\t\t\t\t0\n\t\t);\n\t}\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-PAREN-ARROW-SPLIT-OFF')
	public function testParenArrowIfElseBreaksAfterArrowWithKnobOff(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmodules.sort((a, b) -> if (a < b) -1 else if (a > b) 1 else 0);\n\t}\n}';
		Assert.equals(LADDER, triviaWrite(src, OFF));
	}

	@:pin('control')
	@:killer('M-PAREN-ARROW-SPLIT-OFF')
	public function testParenArrowLadderIsStable(): Void {
		Assert.equals(LADDER, triviaWrite(LADDER, OFF));
	}

	@:pin('control')
	@:killer('M-PAREN-ARROW-SPLIT-OFF')
	public function testTypedParenArrowBreaksAfterArrowWithKnobOff(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmodules.sort((a:String, b:String) -> if (a < b) -1 else 0);\n\t}\n}';
		final want: String = 'class C {\n\tfunction test() {\n\t\tmodules.sort((a:String, b:String) ->\n\t\t\tif (a < b)\n\t\t\t\t-1\n'
			+ '\t\t\telse\n\t\t\t\t0\n\t\t);\n\t}\n}';
		Assert.equals(want, triviaWrite(src, OFF));
	}

	@:pin('guard')
	public function testSimpleChainStaysOnOneLineWithKnobOn(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tmodules.sort((a, b) -> if (a < b) -1 else if (a > b) 1 else 0);\n\t}\n}';
		Assert.equals(src, triviaWrite(src, ON));
	}

	/** A head so wide that the arrow body would break on its own: the break after `->` is taken once, not twice. */
	@:pin('control')
	@:killer('M-ARROW-GLUE-BODY-KEEPS-MARKER')
	public function testWideBareArrowBreaksAfterArrowOnce(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\titemCollection.rankEntries(primaryEntryxxxxxxxxxxxxxxxxxxxxx -> if '
			+ '(primaryEntry.orderKeyValue < secondaryEntry.orderKeyValue.anotherLongField.yetAnotherOne) -1 else if '
			+ '(primaryEntry.orderKeyValue > secondaryEntry.orderKeyValue) 1 else 0);\n\t}\n}';
		final want: String = 'class C {\n\tfunction test() {\n\t\titemCollection.rankEntries(primaryEntryxxxxxxxxxxxxxxxxxxxxx ->\n'
			+ '\t\t\tif (primaryEntry.orderKeyValue < secondaryEntry.orderKeyValue.anotherLongField.yetAnotherOne)\n\t\t\t\t-1\n'
			+ '\t\t\telse if (primaryEntry.orderKeyValue > secondaryEntry.orderKeyValue)\n\t\t\t\t1\n\t\t\telse\n\t\t\t\t0\n\t\t);\n\t}\n}';
		Assert.equals(want, triviaWrite(src, OFF));
	}

	@:pin('guard')
	public function testWideParenArrowBreaksAfterArrowOnce(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\titemCollection.rankEntries((primaryEntry, secondaryEntryxxxxxxxxxxx) '
			+ '-> if (primaryEntry.orderKeyValue < secondaryEntry.orderKeyValue.anotherLongField.yetAnotherOne) '
			+ '-1 else if (primaryEntry.orderKeyValue > secondaryEntry.orderKeyValue) 1 else 0);\n\t}\n}';
		final want: String = 'class C {\n\tfunction test() {\n\t\titemCollection.rankEntries((primaryEntry, secondaryEntryxxxxxxxxxxx) ->\n'
			+ '\t\t\tif (primaryEntry.orderKeyValue < secondaryEntry.orderKeyValue.anotherLongField.yetAnotherOne)\n\t\t\t\t-1\n'
			+ '\t\t\telse if (primaryEntry.orderKeyValue > secondaryEntry.orderKeyValue)\n\t\t\t\t1\n\t\t\telse\n\t\t\t\t0\n\t\t);\n\t}\n}';
		Assert.equals(want, triviaWrite(src, OFF));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}
