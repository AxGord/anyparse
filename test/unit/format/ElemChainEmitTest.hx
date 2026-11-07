package unit.format;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriter;

using StringTools;

/**
 * `case a | b, c:` lays out as one chain over both separators (`ElemChainEmit`): a fill packs across `|` and `,`, the
 * `casePattern` location places both, and what follows the last element's chain stays out of its measure.
 */
@:nullSafety(Strict)
final class ElemChainEmitTest extends Test {

	private static final NARROW: String = '{"wrapping": {"maxLineLength": 60}}';
	private static final WIDTH_40: String = '{"wrapping": {"maxLineLength": 40}}';
	private static final BEFORE_LAST: String =
		'{"wrapping": {"maxLineLength": 60, "casePattern": {"defaultWrap": "fillLine", "defaultLocation": "beforeLast"}}}';
	private static final NO_WRAP: String = '{"wrapping": {"maxLineLength": 60, "casePattern": {"defaultWrap": "noWrap"}}}';
	private static final ONE_PER_LINE: String = '{"wrapping": {"maxLineLength": 60, "casePattern": {"defaultWrap": "onePerLine"}}}';
	private static final AFTER_FIRST: String =
		'{"wrapping": {"maxLineLength": 60, "casePattern": {"defaultWrap": "onePerLineAfterFirst"}}}';
	private static final IGNORE: String = '{"wrapping": {"maxLineLength": 60, "casePattern": {"defaultWrap": "ignore"}}}';
	private static final CURLY_BEFORE: String = '{"wrapping": {"maxLineLength": 40}, "lineEnds": {"leftCurly": "before"}}';
	private static final CURLY_BEFORE_LEADING: String = '{"wrapping": {"maxLineLength": 40, "casePattern": {"defaultWrap": "fillLine", '
		+ '"defaultLocation": "beforeLast"}}, "lineEnds": {"leftCurly": "before"}}';
	private static final RULE_INDENT: String = '{"wrapping": {"maxLineLength": 60, "casePattern": {"defaultWrap": "noWrap", "rules": '
		+ '[{"type": "onePerLineAfterFirst", "additionalIndent": 2, "conditions": [{"cond": "itemCount >= n", "value": 2}]}]}}}';
	private static final DEFAULT_INDENT: String =
		'{"wrapping": {"maxLineLength": 40, "casePattern": {"defaultWrap": "fillLine", "defaultAdditionalIndent": 1}}}';
	private static final CURLY_LABEL: String = '{aaaa: 1} | {bbbbbbbbbbbbbbbbbbbbbbb: 2} | {ccccccccccccccccc: 3}';
	private static final INDENT_LABEL: String = '"aaaaaaaaaaaaaaaa" | "bbbbbbbbbbbbbbbbbb", "cccccccccccccccccc" | "dddddddddddddd"';
	private static final WIDE_A: String = '"aaaaaaaaaaaaaaaaaaaaaaaaaaa"';
	private static final WIDE_B: String = '"bbbbbbbbbbbbbbbbbbbbbbbbbbbbb"';
	private static final WIDE_C: String = '"cccccccccccccccccc"';
	private static final NINE: String = '"aaaa" | "bbbb" | "cccc" | "dddd" | "eeee" | "ffff" | "gggg" | "hhhh" | "iiii"';
	private static final MIXED: String = '"aaaa" | "bbbb", "cccc" | "dddd", "eeee" | "ffff", "gggg" | "hhhh", "iiii" | "jjjj"';

	@:pin('control')
	@:killer('M-ELEM-CHAIN-OFF')
	public function testAlternativesFillWithTheOperatorEndingTheLine(): Void {
		assertLabel(NINE, NARROW, 'case "aaaa" | "bbbb" | "cccc" | "dddd" |\n\t\t\t\t"eeee" | "ffff" | "gggg" | "hhhh" |\n\t\t\t\t"iiii":');
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-OFF')
	public function testPlainWriterFillsTheSameWay(): Void {
		final plain: String = HxModuleWriter.write(HaxeModuleParser.parse(caseOf(NINE)), HaxeFormatConfigLoader.loadHxFormatJson(NARROW));
		Assert.stringContains('"dddd" |\n\t\t\t\t"eeee"', plain);
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-OFF')
	public function testFillPacksAcrossBothSeparators(): Void {
		assertLabel(
			MIXED, NARROW, 'case "aaaa" | "bbbb", "cccc" | "dddd",\n\t\t\t\t"eeee" | "ffff", "gggg" | "hhhh", "iiii" |\n\t\t\t\t"jjjj":'
		);
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-OFF')
	public function testLocationPlacesTheOperatorAtTheLineHead(): Void {
		assertLabel(
			NINE, BEFORE_LAST, 'case "aaaa" | "bbbb" | "cccc" | "dddd"\n\t\t\t\t| "eeee" | "ffff" | "gggg" | "hhhh"\n\t\t\t\t| "iiii":'
		);
	}

	@:pin('control')
	@:killer('M-LIST-SEP-TIGHT-OFF')
	public function testLeadingSeparatorHugsItsOperandWhileTheLineHolds(): Void {
		assertLabel(
			MIXED, BEFORE_LAST,
			'case "aaaa" | "bbbb", "cccc" | "dddd", "eeee"\n\t\t\t\t| "ffff", "gggg" | "hhhh", "iiii"\n\t\t\t\t| "jjjj":'
		);
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-LEADS-OFF')
	public function testCommaListHonoursTheLocationWithoutAnyAlternative(): Void {
		assertLabel(
			'"aaaa", "bbbb", "cccc", "dddd", "eeee", "ffff", "gggg", "hhhh", "iiii"', BEFORE_LAST,
			'case "aaaa", "bbbb", "cccc", "dddd", "eeee"\n\t\t\t\t, "ffff", "gggg", "hhhh", "iiii":'
		);
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-GUARD-MEASURED')
	public function testGuardWrapsItselfRatherThanTheChain(): Void {
		assertLabel(
			'"aa" | "bb" if (cond(aaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbb, ccccccccccccccc))', NARROW,
			'case "aa" | "bb" if (cond(aaaaaaaaaaaaaaaaa,\n\t\t\t\tbbbbbbbbbbbbbbbb, ccccccccccccccc)):'
		);
	}

	@:pin('control')
	@:killer('M-LIST-CHAIN-RESERVE-TIGHT')
	public function testSeparatorReachingTheBudgetStaysOnTheLine(): Void {
		final head: String = quoted(20);
		final fits: String = quoted(16);
		assertLabel('$head | $fits | "zzz"', NARROW, 'case $head | $fits |\n\t\t\t\t"zzz":');
	}

	@:pin('control')
	@:killer('M-LIST-CHAIN-RESERVE-LOOSE')
	public function testSeparatorPastTheBudgetBreaksBeforeItsOperand(): Void {
		final head: String = quoted(20);
		final over: String = quoted(17);
		assertLabel('$head | $over | "zzz"', NARROW, 'case $head |\n\t\t\t\t$over | "zzz":');
	}

	@:pin('control')
	@:killer('M-CASE-PATTERN-RULES-KEPT')
	public function testConfiguredDefaultWrapDropsTheBuiltInRules(): Void {
		assertLabel(NINE, NO_WRAP, 'case $NINE:');
	}

	@:pin('control')
	@:killer('M-LIST-CHAIN-CLOSER-GLUED')
	public function testOnePerLineOpensAChainAndPutsItsCloserAlone(): Void {
		assertLabel('"aaaa" | "bbbb", "cccc"', ONE_PER_LINE, 'case\n\t\t\t\t"aaaa" |\n\t\t\t\t"bbbb",\n\t\t\t\t"cccc"\n\t\t\t:');
	}

	@:pin('control')
	@:killer('M-LIST-CHAIN-CLOSER-GLUED')
	public function testOnePerLineKeepsAGuardOnTheLastOperand(): Void {
		assertLabel('"aaaa" | "cccc" if (x)', ONE_PER_LINE, 'case\n\t\t\t\t"aaaa" |\n\t\t\t\t"cccc" if (x)\n\t\t\t:');
	}

	@:pin('guard')
	public function testOnePerLineOpensAPlainListTheSameWay(): Void {
		assertLabel('"aaaa", "bbbb", "cccc"', ONE_PER_LINE, 'case\n\t\t\t\t"aaaa",\n\t\t\t\t"bbbb",\n\t\t\t\t"cccc"\n\t\t\t:');
	}

	@:pin('guard')
	public function testOnePerLineOpensASingleOperandLabel(): Void {
		assertLabel('_', ONE_PER_LINE, 'case\n\t\t\t\t_\n\t\t\t:');
	}

	@:pin('guard')
	public function testOnePerLineAfterFirstGluesTheCloser(): Void {
		assertLabel('"aaaa" | "cccc"', AFTER_FIRST, 'case "aaaa" |\n\t\t\t\t"cccc":');
		assertLabel('"aaaa", "cccc"', AFTER_FIRST, 'case "aaaa",\n\t\t\t\t"cccc":');
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-HARDLINE-OPERAND')
	public function testOperandOpeningItsOwnLineLeavesTheListLayout(): Void {
		assertNoStrandedSpace(CURLY_LABEL, CURLY_BEFORE);
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-HARDLINE-OPERAND')
	public function testOperandOpeningItsOwnLineLeavesTheListLayoutUnderBeforeLast(): Void {
		assertNoStrandedSpace(CURLY_LABEL, CURLY_BEFORE_LEADING);
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-INDENT-DROPPED')
	public function testRuleAdditionalIndentKeepsTheListLayout(): Void {
		assertLabel(
			INDENT_LABEL, RULE_INDENT,
			'case "aaaaaaaaaaaaaaaa" | "bbbbbbbbbbbbbbbbbb",\n\t\t\t\t\t\t"cccccccccccccccccc"\n\t\t\t\t\t\t\t| "dddddddddddddd":'
		);
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-INDENT-DROPPED')
	public function testDefaultAdditionalIndentKeepsTheListLayout(): Void {
		assertLabel(
			INDENT_LABEL, DEFAULT_INDENT,
			'case "aaaaaaaaaaaaaaaa"\n\t\t\t\t\t\t| "bbbbbbbbbbbbbbbbbb",\n\t\t\t\t\t"cccccccccccccccccc"\n\t\t\t\t\t\t| "dddddddddddddd":'
		);
	}

	@:pin('guard')
	public function testManyCommentedAlternativesFinish(): Void {
		final label: String = [for (i in 0...40) '"a$i" /* c */'].join(' | ');
		Assert.stringContains('"a39"', rewrite(caseOf(label), NARROW));
	}

	@:pin('control')
	@:killer('M-CASE-PATTERN-IGNORE-CLEARS-RULES')
	public function testIgnoreStaysOnTheBuiltInRules(): Void {
		assertLabel('$WIDE_A,\n\t\t\t\t$WIDE_B, $WIDE_C', IGNORE, 'case $WIDE_A,\n\t\t\t\t$WIDE_B,\n\t\t\t\t$WIDE_C:');
	}

	@:pin('control')
	@:killer('M-ELEM-CHAIN-TAKES-IGNORE')
	public function testIgnoreLeavesAlternativesInTheirElement(): Void {
		assertLabel('$WIDE_A | $WIDE_B | $WIDE_C', IGNORE, 'case $WIDE_A\n\t\t\t\t| $WIDE_B\n\t\t\t\t| $WIDE_C:');
	}

	/** The label's continuation carries every operand, the first included, so an operand's own break sits one unit past it. */
	@:pin('guard')
	public function testFirstOperandBreaksLikeAnElementOfTheList(): Void {
		final call: String = 'Fooooooooooo(aaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbb)';
		final broken: String = 'case Fooooooooooo(aaaaaaaaaaaaaaaaaaaa,\n\t\t\t\t\tbbbbbbbbbbbbbbbbbbbbb)';
		assertLabel('$call | Bar', WIDTH_40, '$broken |\n\t\t\t\tBar:');
		assertLabel('$call, Bar', WIDTH_40, '$broken,\n\t\t\t\tBar:');
	}

	@:pin('guard')
	public function testFittingChainStaysOnOneLine(): Void {
		assertLabel('"a" | "b", "c" | "d"', NARROW, 'case "a" | "b", "c" | "d":');
	}

	@:pin('guard')
	public function testAlternativesInsideDelimitersStayWithTheirOperand(): Void {
		Assert.stringContains('case Foo("aaaa" | "bbbb" | "cccc" | "dddd"\n\t\t\t\t| "eeee"', rewrite(caseOf('Foo($NINE)'), NARROW));
		Assert.stringContains('case ("aaaa" | "bbbb" | "cccc" | "dddd" | "eeee"\n\t\t\t\t| "ffff"', rewrite(caseOf('($NINE)'), NARROW));
	}

	@:pin('guard')
	public function testBlockCommentStaysOnItsOperand(): Void {
		assertLabel(
			'"aaaa" | "bbbb" | "cccc" | "dddd" | "eeee" | "ffff" /* note */ | "gggg" | "hhhh" | "iiii"', NARROW,
			'case "aaaa" | "bbbb" | "cccc" | "dddd" |\n\t\t\t\t"eeee" | "ffff" /* note */ | "gggg" |\n\t\t\t\t"hhhh" | "iiii":'
		);
	}

	@:pin('guard')
	public function testLineCommentAfterAnElementEndsItsLine(): Void {
		assertLabel('"aaa" | "bbb", // four\n\t\t\t\t"ccc"', NARROW, 'case "aaa" | "bbb", // four\n\t\t\t\t"ccc":');
	}

	private function assertLabel(label: String, config: String, expected: String): Void {
		final out: String = rewrite(caseOf(label), config);
		Assert.stringContains('\t\t\t$expected\n\t\t\t\ta();', out);
		Assert.equals(out, rewrite(out, config), 'a second pass must not move anything');
	}

	private function assertNoStrandedSpace(label: String, config: String): Void {
		final out: String = rewrite(caseOf(label), config);
		Assert.equals(-1, out.indexOf(' \n'), out);
		Assert.equals(out, rewrite(out, config), 'a second pass must not move anything');
	}

	private function rewrite(src: String, config: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(config));
	}

	private static function caseOf(label: String): String {
		return 'class M {\n\tfunction f() {\n\t\tswitch x {\n\t\t\tcase $label:\n\t\t\t\ta();\n\t\t\tcase _:\n\t\t}\n\t}\n}\n';
	}

	/** A string literal `width` columns wide, quotes included. */
	private static function quoted(width: Int): String {
		return '"' + ''.rpad('x', width - 2) + '"';
	}

}
