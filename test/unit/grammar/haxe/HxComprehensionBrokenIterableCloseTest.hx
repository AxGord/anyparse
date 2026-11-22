package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A cuddled comprehension whose generator head iterates a multi-line literal closes like one whose head is a single
 * line: a `{ … }` body glued to the head's `)` lets the `]` ride its `}`, because the `}` is back at container indent.
 * A body pushed to a continuation line, and a head too wide for the bracket line, keep the close on its own line.
 */
@:nullSafety(Strict)
final class HxComprehensionBrokenIterableCloseTest extends Test {

	private static final CONFIG_HEAD: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": ';
	private static final CONFIG_TAIL: String = ', "comprehensionCuddledOpen": true}, "whitespace": {"bracketConfig": {'
		+ '"comprehensionBrackets": {"openingPolicy": "onlyAfter", "closingPolicy": "before"}}}, '
		+ '"sameLine": {"ifBody": "fitLine", "expressionIf": "next"}}';
	private static final PADDED: String = '${CONFIG_HEAD}140$CONFIG_TAIL';
	private static final NARROW: String = '${CONFIG_HEAD}20$CONFIG_TAIL';
	private static final TIGHT: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"comprehensionCuddledOpen": true}, "sameLine": {"ifBody": "fitLine", "expressionIf": "next"}}';
	private static final OFF: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, '
		+ '"whitespace": {"bracketConfig": {"comprehensionBrackets": {"openingPolicy": "onlyAfter", "closingPolicy": "before"}}}, '
		+ '"sameLine": {"ifBody": "fitLine", "expressionIf": "next"}}';
	private static final ITERABLE: String = '[\n\t\t\taaaaaaaaaaaaaaaaaaaa(1),\n\t\t\tbbbbbbbbbbbbbbbbbbbb(2),\n'
		+ '\t\t\tcccccccccccccccccccc(3),\n\t\t\tdddddddddddddddddddd(4)\n\t\t]';
	private static final BLOCK_BODY: String = ' {\n\t\t\tfinal v:Int = p * 2;\n\t\t\tv;\n\t\t}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-CUDDLE-GLUED-BRACE-CLOSE-OWN-LINE')
	public function testBrokenIterableCloserRidesBodyCurly(): Void {
		final expected: String = wrapInClass('return [ for (p in $ITERABLE)$BLOCK_BODY ];');
		Assert.equals(expected, triviaWrite(wrapInClass('return [ for (p in $ITERABLE)$BLOCK_BODY\n\t\t];'), PADDED));
	}

	@:pin('control')
	@:killer('M-CUDDLE-GLUE-READS-NESTED-BREAK')
	public function testBrokenIterableTightCloserRidesBodyCurly(): Void {
		final expected: String = wrapInClass('return [for (p in $ITERABLE)$BLOCK_BODY];');
		Assert.equals(expected, triviaWrite(expected, TIGHT));
	}

	public function testOneLineIterableKeepsItsCloser(): Void {
		final src: String = wrapInClass('return [ for (p in 0...10) {\n\t\t\tfinal v:Int = p * 2;\n\t\t\tv;\n\t\t} ];');
		Assert.equals(src, triviaWrite(src, PADDED));
	}

	public function testUncuddledLayoutKeepsItsCloserOwnLine(): Void {
		final src: String = 'class C {\n\tfunction f():Array<Int> {\n\t\treturn [\n\t\t\tfor (p in [\n\t\t\t\taaaaaaaaaaaaaaaaaaaa(1),\n'
			+ '\t\t\t\tbbbbbbbbbbbbbbbbbbbb(2),\n\t\t\t\tcccccccccccccccccccc(3),\n\t\t\t\tdddddddddddddddddddd(4)\n\t\t\t]) {\n'
			+ '\t\t\t\tfinal v:Int = p * 2;\n\t\t\t\tv;\n\t\t\t}\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, OFF));
	}

	public function testOpenBracketOnItsOwnLineKeepsCloserOwnLine(): Void {
		final src: String = 'class C {\n\tfunction f():Array<Int> {\n\t\treturn [\n\t\t\tfor (p in [\n\t\t\t\taaaaaaaaaaaaaaaaaaaa(1),\n'
			+ '\t\t\t\tbbbbbbbbbbbbbbbbbbbb(2),\n\t\t\t\tcccccccccccccccccccc(3),\n\t\t\t\tdddddddddddddddddddd(4)\n\t\t\t]) {\n'
			+ '\t\t\t\tfinal v:Int = p\n\t\t\t\t\t* 2;\n\t\t\t\tv;\n\t\t\t}\n\t\t];\n\t}\n}';
		Assert.equals(src, triviaWrite(src, NARROW));
	}

	public function testPushedSwitchBodyKeepsCloserOwnLine(): Void {
		final src: String = wrapInClass(
			'return [ for (p in $ITERABLE)\n\t\t\tswitch p {\n\t\t\t\tcase 1: 2;\n\t\t\t\tcase _: 3;\n\t\t\t}\n\t\t];'
		);
		Assert.equals(src, triviaWrite(src, PADDED));
	}

	public function testExpressionBodyKeepsCloserOwnLine(): Void {
		final src: String = wrapInClass('return [ for (p in $ITERABLE) p * 2\n\t\t];');
		Assert.equals(src, triviaWrite(src, PADDED));
	}

	@:pin('control')
	@:killer('M-RUN-DEPTH-OPEN-CLOSE-LEAF-NEGATIVE')
	public function testEmptyArgumentCallItemKeepsCloserOnBodyCurly(): Void {
		Assert.equals(closerOnCurly('bbbbbbbbbbbbbbbbbbbb()'), triviaWrite(closerOnCurly('bbbbbbbbbbbbbbbbbbbb()', '\n\t\t];'), PADDED));
	}

	@:pin('control')
	@:killer('M-RUN-DEPTH-OPEN-CLOSE-LEAF-NEGATIVE')
	public function testEmptyLiteralArgumentItemsKeepCloserOnBodyCurly(): Void {
		for (item in ['bbbbbbbbbbbbbbbbbbbb([])', 'bbbbbbbbbbbbbbbbbbbb({})'])
			Assert.equals(closerOnCurly(item), triviaWrite(closerOnCurly(item, '\n\t\t];'), PADDED));
	}

	private static function wrapInClass(statement: String): String {
		return 'class C {\n\tfunction f():Array<Int> {\n\t\t$statement\n\t}\n}';
	}

	private static function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	private static function closerOnCurly(secondItem: String, closer: String = ' ];'): String {
		final iterable: String =
			'[\n\t\t\taaaaaaaaaaaaaaaaaaaa(1),\n\t\t\t$secondItem,\n\t\t\tcccccccccccccccccccc(3),\n\t\t\tdddddddddddddddddddd(4)\n\t\t]';
		return wrapInClass('return [ for (p in $iterable)$BLOCK_BODY$closer');
	}

}
