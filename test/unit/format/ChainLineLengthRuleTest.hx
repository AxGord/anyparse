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
