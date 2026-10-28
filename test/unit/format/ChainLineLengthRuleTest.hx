package unit.format;

import unit.grammar.haxe.HxWriteFixture;

using StringTools;

/**
 * A chain cascade that merely CONTAINS a `lineLength` rule lays a chain out as the same cascade without it while the
 * rule's threshold is out of reach: the column-aware threshold partitions each side of the chain's `exceeds` pivot and
 * never replaces that pivot, whose rest-aware Group counts the line's trailing `;` and whose marker lets an inner
 * add-chain collapse inside a broken outer one.
 */
@:nullSafety(Strict)
final class ChainLineLengthRuleTest extends Test {

	/** Columns a tab occupies under the default config. */
	private static inline final TAB_WIDTH: Int = 4;

	/** The cascade's tail: no wrap while a short chain fits, one operand per line once the line exceeds the limit. */
	private static final TAIL: String = '{"conditions": [{"cond": "itemCount <= n", "value": 3}, {'
		+ '"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 1}], "type": "onePerLineAfterFirst", "location": "beforeLast"}';

	/** A `lineLength` rule no line in this class reaches. */
	private static final UNREACHED: String =
		'{"conditions": [{"cond": "lineLength >= n", "value": 1000}], "type": "fillLine", "location": "beforeLast"}, ';

	/** A `lineLength` rule at 100 columns: one operand per line once the line reaches it. */
	private static final AT_100: String =
		'{"conditions": [{"cond": "lineLength >= n", "value": 100}], "type": "onePerLineAfterFirst", "location": "beforeLast"}, ';

	/** A `lineLength` rule at 90 columns, past an 80-column limit: a fill once the line reaches it. */
	private static final AT_90: String =
		'{"conditions": [{"cond": "lineLength >= n", "value": 90}], "type": "fillLine", "location": "beforeLast"}, ';

	/** The two `lineLength` rules at 160 columns a 140-column fork config leads its `+` cascade with. */
	private static final SOFT_160: String = '{"conditions": [{"cond": "lineLength >= n", "value": 160}, {"cond": '
		+ '"anyItemLength >= n", "value": 60}], "type": "onePerLineAfterFirst", "location": "beforeLast"}, {"conditions": '
		+ '[{"cond": "lineLength >= n", "value": 160}], "type": "fillLine", "location": "beforeLast"}, ';

	public function new(): Void {
		super();
	}

	/**
	 * A two-operand `+` / `&&` statement whose line crosses the limit by one to a few columns, its trailing `;` among
	 * them, breaks exactly as it does without the unreached rule, and no written line is over the limit.
	 */
	@:pin('control')
	@:killer('M-CHAIN-THRESHOLD-WRAPS-PIVOT')
	public function testAnUnreachedLineLengthRuleKeepsTheExceedsBreak(): Void {
		for (op in ['+', '&&']) for (k in 0...8) {
			final src: String = statement(op, k);
			final plain: String = HxWriteFixture.triviaWrite(src, config(140, false));
			Assert.equals(plain, HxWriteFixture.triviaWrite(src, config(140, true)), 'op=$op k=$k');
			Assert.isTrue(widest(plain) <= 140, 'op=$op k=$k: a ${widest(plain)}-column line\n$plain');
		}
	}

	/** An add-chain inside a broken outer add-chain collapses back to one line as it does without the unreached rule. */
	@:pin('control')
	@:killer('M-CHAIN-THRESHOLD-WRAPS-PIVOT')
	public function testAnUnreachedLineLengthRuleKeepsTheInnerAddChainCollapse(): Void {
		final src: String = 'class Main {\n\tfunction test():Void {\n\t\tfinal h:Float = Dimensions.HEADER_HEIGHT * scale '
			+ '+ Dimensions.CELL_HEIGHT * scale * (rowIdx + 1 - (dayIdx == 0 ? 1 : 0));\n\t}\n}';
		final plain: String = HxWriteFixture.triviaWrite(src, config(80, false));
		Assert.isTrue(plain.contains('(rowIdx + 1 - (dayIdx == 0'), plain);
		Assert.equals(plain, HxWriteFixture.triviaWrite(src, config(80, true)));
	}

	/** A `lineLength` rule whose threshold the line DOES reach, below the limit, still picks its own shape. */
	@:pin('guard')
	public function testAReachedLineLengthRuleBelowTheLimitStillFires(): Void {
		final cfg: String = cascade(160, AT_100);
		final operand: String = ''.lpad('a', 30);
		final reached: String = HxWriteFixture.triviaWrite(
			'class M {\n\tfunction f() {\n\t\tfinal ok = $operand && $operand && $operand;\n\t}\n}', cfg
		);
		Assert.equals('class M {\n\tfunction f() {\n\t\tfinal ok = $operand\n\t\t\t&& $operand\n\t\t\t&& $operand;\n\t}\n}', reached);
		final short: String = ''.lpad('a', 20);
		final unreached: String = HxWriteFixture.triviaWrite(
			'class M {\n\tfunction f() {\n\t\tfinal ok = $short && $short && $short;\n\t}\n}', cfg
		);
		Assert.equals('class M {\n\tfunction f() {\n\t\tfinal ok = $short && $short && $short;\n\t}\n}', unreached);
	}

	/**
	 * Two `lineLength` rules in one cascade answer as each alone: a line reaching the lower one below the limit takes
	 * its shape exactly as the cascade holding only that rule does, and a line over the limit breaks exactly as the
	 * cascade without either.
	 */
	@:pin('control')
	@:killer('M-CHAIN-THRESHOLD-UNIFORM-BLIND')
	public function testTwoLineLengthRulesAnswerAsEachAlone(): Void {
		final both: String = AT_100 + UNREACHED;
		final operand: String = ''.lpad('a', 30);
		final src: String = 'class M {\n\tfunction f() {\n\t\tfinal ok = $operand && $operand && $operand;\n\t}\n}';
		final reached: String = HxWriteFixture.triviaWrite(src, cascade(160, both));
		Assert.equals('class M {\n\tfunction f() {\n\t\tfinal ok = $operand\n\t\t\t&& $operand\n\t\t\t&& $operand;\n\t}\n}', reached);
		Assert.equals(HxWriteFixture.triviaWrite(src, cascade(160, AT_100)), reached);
		for (op in ['+', '&&']) for (k in 1...8) {
			final over: String = statement(op, k);
			Assert.equals(
				HxWriteFixture.triviaWrite(over, cascade(140, '')), HxWriteFixture.triviaWrite(over, cascade(140, both)), 'op=$op k=$k'
			);
		}
	}

	/**
	 * The opBool re-eval tag survives an unreached `lineLength` rule: a trailing-operator fill chain whose call operand
	 * overflows flips to leading operators exactly as it does without the rule.
	 */
	@:pin('control')
	@:killer('M-CHAIN-THRESHOLD-WRAPS-PIVOT')
	@:killer('M-CHAIN-THRESHOLD-REEVAL-UNTAGGED')
	public function testAnUnreachedLineLengthRuleKeepsTheOpBoolReeval(): Void {
		final src: String = 'class Main {\n\tstatic function main() {\n\t\tif (conditionAlpha && functionWithManyParams(longParameterA, '
			+ 'longParameterB, longParameterC, longParameterD) && conditionBravo) {\n\t\t\tdoWork();\n\t\t}\n\t}\n}';
		final plain: String = HxWriteFixture.triviaWrite(src, reevalConfig(''));
		Assert.isTrue(plain.contains('\n\t\t\t&& functionWithManyParams('), plain);
		Assert.equals(plain, HxWriteFixture.triviaWrite(src, reevalConfig(UNREACHED)));
	}

	/**
	 * A paren holding a short `+` chain stays glued on a line a later argument list breaks, as it does without the
	 * `lineLength` rules: the chain's threshold cannot fire on that line, so the rest of it is measured up to where the
	 * argument list opens.
	 */
	@:pin('control')
	@:killer('M-PAREN-REST-THRESHOLD-INEXACT')
	public function testALineLengthRuleNeverOpensAGluedParen(): Void {
		final src: String = 'class M {\n\tfunction f() {\n\t\tfor (name in names) {\n\t\t\t(((base + name) : Path).stem : Path).text = '
			+ 'new Template(content).execute(titleArgument, applicationArgument, assetsArgument, dateArgument);\n\t\t\tx = '
			+ '(base + name).text = new Template(content).execute(titleArgument, applicationArgument, assetsArgument, '
			+ 'dateArgument, extraArgument);\n\t\t}\n\t}\n}';
		final plain: String = HxWriteFixture.triviaWrite(src, forkConfig(''));
		Assert.isTrue(plain.contains('\t(((base + name) : Path).stem : Path).text = new Template(content).execute(\n'), plain);
		Assert.isTrue(plain.contains('\tx = (base + name).text = new Template(content).execute(\n'), plain);
		Assert.equals(plain, HxWriteFixture.triviaWrite(src, forkConfig(SOFT_160)));
	}

	/**
	 * A `+` chain glued so that its last operand's paren opens stays glued under the `lineLength` rules, as it does
	 * without them, whether or not the chain sits in a paren of its own: the commit takes the side every threshold
	 * answers not-fired, so the comprehension in the paren is not pushed past the limit and broken.
	 */
	@:pin('control')
	@:killer('M-CHAIN-GLUE-THRESHOLD-FIRES')
	@:killer('M-CHAIN-GLUE-PAREN-THRESHOLD-FIRES')
	public function testALineLengthRuleKeepsAChainGluedToAnOpenedParen(): Void {
		final src: String = 'class M {\n\tfunction f() {\n\t\tfor (name in names) {\n\t\t\tif (x) {\n\t\t\t\ttrace(1);\n\t\t\t\thelp = '
			+ '(help == null ? \'\' : help + \'. \') + (\'Arguments:\'.foreground(ForegroundColour.DarkGrayColour) + \'; \' + '
			+ '[for (a in node.args) describeArgument(a)].join(\', \'));\n\t\t\t\thelp = ((help == null ? \'\' : help + \'. \') + '
			+ '(\'Arguments:\'.foreground(ForegroundColour.DarkGrayColour) + \'; \' + [for (a in node.args) describeArg(a)]'
			+ '.join(\', \')));\n\t\t\t}\n\t\t}\n\t}\n}';
		final plain: String = HxWriteFixture.triviaWrite(src, forkConfig(''));
		Assert.isTrue(plain.contains('\thelp = (help == null ? \'\' : help + \'. \') + (\n'), plain);
		Assert.isTrue(plain.contains('[for (a in node.args) describeArgument(a)].join(\', \')\n'), plain);
		Assert.isTrue(plain.contains('\t(help == null ? \'\' : help + \'. \') + (\n'), plain);
		Assert.isTrue(plain.contains('[for (a in node.args) describeArg(a)].join(\', \')\n'), plain);
		Assert.equals(plain, HxWriteFixture.triviaWrite(src, forkConfig(SOFT_160)));
	}

	/**
	 * An add-chain inside a broken outer add-chain collapses to one line under a `lineLength` rule past the limit, as it
	 * does without the rule, whether or not its last operand is a paren: a threshold past the limit never fires on a
	 * chain's flat side, and a collapse must not make it.
	 */
	@:pin('control')
	@:killer('M-CHAIN-COLLAPSE-THRESHOLD-FIRES')
	@:killer('M-CHAIN-COLLAPSE-PROBED-THRESHOLD-FIRES')
	public function testALineLengthRuleKeepsTheInnerAddChainCollapsedPastTheLimit(): Void {
		final src: String = 'class Main {\n\tfunction test():Void {\n\t\tfinal h:Float = Dimensions.HEADER_HEIGHT * scale + '
			+ 'Dimensions.CELL_HEIGHT * (rowIdxLonger + firstOffsetValue - secondOffsetValue - thirdOffsetValue + 1);\n\t\t'
			+ 'final h:Float = Dimensions.HEADER_HEIGHT * scale + Dimensions.CELL_HEIGHT * (rowIdxLonger + firstOffsetValue + '
			+ 'secondOffsetValue - (thirdOffsetValue + 1));\n\t}\n}';
		final plain: String = HxWriteFixture.triviaWrite(src, cascade(80, ''));
		Assert.isTrue(plain.contains('(rowIdxLonger + firstOffsetValue - secondOffsetValue - thirdOffsetValue + 1);'), plain);
		Assert.isTrue(plain.contains('(rowIdxLonger + firstOffsetValue + secondOffsetValue - (thirdOffsetValue + 1));'), plain);
		Assert.equals(plain, HxWriteFixture.triviaWrite(src, cascade(80, AT_90)));
	}

	/**
	 * A `lineLength` rule below the limit that an inner add-chain reaches, collapsed inside a broken outer add-chain,
	 * still fires: a threshold the line can reach without exceeding the limit stays a live decision after the collapse.
	 */
	@:pin('control')
	@:killer('M-CHAIN-GLUED-SIDE-DROPS-REACHED-THRESHOLD')
	public function testAReachedLineLengthRuleBelowTheLimitStillBreaksACollapsedInnerChain(): Void {
		final a: String = ''.lpad('a', 44);
		final b: String = ''.lpad('b', 37);
		final c: String = ''.lpad('c', 20);
		final d: String = ''.lpad('d', 30);
		final e: String = ''.lpad('e', 31);
		final f: String = ''.lpad('f', 29);
		final g: String = ''.lpad('g', 13);
		final src: String = 'class M {\n\tfunction f() {\n\t\tvar s = ($a + $b + $c) + ($d + $e + $f + $g);\n\t}\n}';
		Assert.equals(
			'class M {\n\tfunction f() {\n\t\tvar s = ($a\n\t\t\t+ $b\n\t\t\t+ $c)\n\t\t\t+ ($d\n\t\t\t\t+ $e\n\t\t\t\t+ $f\n\t\t\t\t+ $g'
			+ ');\n\t}\n}',
			HxWriteFixture.triviaWrite(src, forkConfig(AT_100))
		);
	}

	/** The opAdd and opBool cascades at `limit`: the tail, after the unreached `lineLength` rule when `unreached`. */
	private static function config(limit: Int, unreached: Bool): String {
		return cascade(limit, unreached ? UNREACHED : '');
	}

	/** The opAdd and opBool cascades at `limit`: the rules `prefix` spells, then the tail. */
	private static function cascade(limit: Int, prefix: String): String {
		final rules: String = '[$prefix$TAIL]';
		return '{"wrapping": {"maxLineLength": $limit, "opAddSubChain": {"defaultWrap": "noWrap", "rules": $rules}, '
			+ '"opBoolChain": {"defaultWrap": "noWrap", "rules": $rules}}}';
	}

	/**
	 * A 140-column config with a leading-break call wrap and expression wrap, whose `+` cascade is the rules `prefix`
	 * spells, then the tail.
	 */
	private static function forkConfig(prefix: String): String {
		return '{"wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": '
			+ '[{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount '
			+ '<= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "expressionWrapping": {'
			+ '"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], '
			+ '"type": "noWrap"}]}, "opAddSubChain": {"defaultWrap": "noWrap", "rules": [$prefix$TAIL]}}}';
	}

	/** An opBool cascade whose exceeds answer is a trailing-operator fill, after the rules `prefix` spells. */
	private static function reevalConfig(prefix: String): String {
		return '{"indentation": {"tabWidth": 4}, "wrapping": {"maxLineLength": 100, "callParameter": {"defaultWrap": '
			+ '"fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": '
			+ '"noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": [${prefix}{"conditions": [{"cond": '
			+ '"exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "afterLast"}]}}}';
	}

	/** A two-operand `op` statement whose line, its `;` included, is `k` columns past 140. */
	private static function statement(op: String, k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tfinal v = head${''.lpad('x', k)} $op \'${''.lpad('y', 112)}\';\n\t}\n}';
	}

	/** The widest line of `text` in columns, a tab counted at the default width. */
	private static function widest(text: String): Int {
		var out: Int = 0;
		for (line in text.split('\n')) {
			final width: Int = line.replace('\t', ''.lpad(' ', TAB_WIDTH)).length;
			if (width > out) out = width;
		}
		return out;
	}

}
