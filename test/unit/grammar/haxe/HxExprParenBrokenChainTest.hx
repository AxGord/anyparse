package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * An expression paren around a `+`/`-` chain that is ALREADY broken when the paren is laid out — an operand whose
 * wrap rule broke it statically, like an array one item per line — opens with the chain at its own indent.
 *
 * The open side of such a paren pins its chain flat (`HardFlatten`) under a config with no `expressionWrapping`
 * rule, which is right for a chain that CAN be one line and wrong for one that cannot: a force-flat region renders a
 * hardline as a bare newline, so every continuation line landed at column 0 and the next write, reading the paren
 * opened in the source, re-indented them. A chain that is already broken therefore opens like it does under an
 * `expressionWrapping` rule: the paren's indent, the chain's own breaks, still decided by the paren's width probe.
 */
@:nullSafety(Strict)
final class HxExprParenBrokenChainTest extends Test {

	/** Columns a tab occupies under every config here. */
	private static inline final TAB_WIDTH: Int = 4;

	/** `maxLineLength` of the compiled defaults. */
	private static inline final LIMIT_DEFAULT: Int = 160;

	/** `maxLineLength` of `CFG_ARRAY_RULE`. */
	private static inline final LIMIT_ARRAY_RULE: Int = 140;

	/** The compiled defaults: no `expressionWrapping` rule, 160 columns. */
	private static final CFG_DEFAULT: String = '{}';

	/** An array rule that breaks a list one item per line from its item widths alone, at 140 columns. */
	private static final CFG_ARRAY_RULE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140, "arrayWrap": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": '
		+ '"anyItemLength >= n", "value": 30}], "type": "onePerLine"}]}}}';

	/** `opAddSubChain` kept: every chain reproduces the line breaks its source put at its own operators. */
	private static final CFG_KEEP: String = '{"wrapping": {"opAddSubChain": {"defaultWrap": "keep", "rules": []}}}';

	/** A parenthesised `-` chain, one operand of the kept chains below. */
	private static final TERM: String = '(aaaaaaaaaaaaaaaaaaaa - bbbbbbbbbbbbbbbbbbbb)';

	/** An array the compiled defaults break one item per line, inside a parenthesised chain that has to open. */
	private static final ARRAY_OPERAND: String = 'class M {\n\tfunction f() {\n\t\tvar v = (\n\t\t\tbaseValue + [\n'
		+ '\t\t\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n\t\t\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n'
		+ '\t\t\t\tccccccccccccccccccccccccccccccccccccccccc,\n\t\t\t\tdddddddddddddddddddddddddd\n'
		+ '\t\t\t].length\n\t\t) * factorValue;\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** The broken chain keeps its indent inside the opened paren, and that layout is a fixed point. */
	@:pin('control')
	@:killer('M-PAREN-BROKEN-CHAIN-PINNED')
	public function testABrokenChainOpensAtItsIndent(): Void {
		final src: String = 'class M {\n\tfunction f() {\n\t\tvar v = (baseValue + [aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '
			+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, ccccccccccccccccccccccccccccccccccccccccc, '
			+ 'dddddddddddddddddddddddddd].length) * factorValue;\n\t}\n}';
		Assert.equals(ARRAY_OPERAND, HxWriteFixture.triviaWrite(src, CFG_DEFAULT));
		Assert.equals(ARRAY_OPERAND, HxWriteFixture.triviaWrite(ARRAY_OPERAND, CFG_DEFAULT));
	}

	/**
	 * One write is a fixed point within the limit for every width of a comprehension operand, across the boundary
	 * where its object literal breaks into Allman position as well, up to the width where the literal's last field
	 * alone no longer fits its line.
	 */
	@:pin('control')
	@:killer('M-PAREN-BROKEN-CHAIN-PINNED')
	public function testOneWriteIsAFixedPointAcrossTheBoundary(): Void {
		for (k in 20...101) {
			assertOneWriteWithinLimit(comprehensionShape(k), CFG_DEFAULT, LIMIT_DEFAULT, k);
			assertOneWriteWithinLimit(comprehensionShape(k), CFG_ARRAY_RULE, LIMIT_ARRAY_RULE, k);
		}
	}

	/**
	 * A kept chain its source broke stays in the paren its source glued, past the line limit, with its continuation lines
	 * at the value's indent after a source break following `return`.
	 */
	@:pin('control')
	@:killer('M-PAREN-KEPT-CHAIN-OPENS')
	public function testAKeptBrokenChainAfterAReturnBreakStaysGlued(): Void {
		final expected: String = keptShape('return\n\t\t\t1 * (', '\t\t\t', ');');
		Assert.equals(expected, HxWriteFixture.triviaWrite(keptShape('return\n\t\t\t\t1 * (', '\t\t\t\t\t\t', ');'), CFG_KEEP));
		Assert.equals(expected, HxWriteFixture.triviaWrite(expected, CFG_KEEP));
	}

	/**
	 * The glued layout reads no source bit the `return` policy may overrule, so one write is a fixed point whether the
	 * policy keeps, drops or adds the break after `return`.
	 */
	@:pin('control')
	@:killer('M-PAREN-KEPT-CHAIN-SOURCE-NEST')
	public function testAKeptChainInAParenIsOneWriteUnderEveryReturnPolicy(): Void {
		for (policy in ['same', 'next', 'keep', 'fitLine']) {
			final config: String = '{"wrapping": {"opAddSubChain": {"defaultWrap": "keep", "rules": []}}, '
				+ '"sameLine": {"returnBody": "$policy", "returnBodySingleLine": "$policy"}}';
			for (head in ['return\n\t\t\t(', 'return (']) {
				final once: String = HxWriteFixture.triviaWrite(
					'class M {\n\tfunction f() {\n\t\t${head}aaaa +\n\t\t\tbbbb);\n\t}\n}', config
				);
				Assert.equals(once, HxWriteFixture.triviaWrite(once, config), '$policy: ${head.replace('\n', '\\n')}');
			}
		}
	}

	/**
	 * A kept chain whose only break is inside an operand — an array laid out one item per line — is not a chain its source
	 * broke: its paren opens as it does without `keep`.
	 */
	@:pin('control')
	@:killer('M-PAREN-KEPT-CHAIN-OPERAND')
	public function testAChainOnlyAnOperandBrokeOpensAsWithoutKeep(): Void {
		final src: String = 'class M {\n\tfunction f() {\n\t\tvar v = (baseValue + [aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '
			+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, ccccccccccccccccccccccccccccccccccccccccc, '
			+ 'dddddddddddddddddddddddddd].length) * factorValue;\n\t}\n}';
		final expected: String = 'class M {\n\tfunction f() {\n\t\tvar v = (\n\t\t\tbaseValue + [\n'
			+ '\t\t\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n\t\t\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n'
			+ '\t\t\t\tccccccccccccccccccccccccccccccccccccccccc,\n\t\t\t\tdddddddddddddddddddddddddd\n'
			+ '\t\t\t].length\n\t\t) * factorValue;\n\t}\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(src, CFG_KEEP));
		Assert.equals(expected, HxWriteFixture.triviaWrite(expected, CFG_KEEP));
	}

	private static function assertOneWriteWithinLimit(src: String, config: String, limit: Int, k: Int): Void {
		final once: String = HxWriteFixture.triviaWrite(src, config);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, config), 'k=$k config=$config\n$src');
		var widest: Int = 0;
		for (line in once.split('\n')) {
			final width: Int = line.replace('\t', ''.lpad(' ', TAB_WIDTH)).length;
			if (width > widest) widest = width;
		}
		Assert.isTrue(widest <= limit, 'k=$k config=$config: a $widest-column line\n$once');
	}

	private static function comprehensionShape(k: Int): String {
		return 'class M {\n\tfunction f() {\n\t\tvar y = (baseValue + [for (x in xs) {alpha: x.aaaaaaaaaaaaaaaaaaaaa, k: \''
			+ ''.lpad('k', k) + '\'}].length) * factorValue;\n\t}\n}';
	}

	/** `head`, four `TERM`s and a source break, `indent`, two more `TERM`s and `tail`: a statement over the line limit. */
	private static function keptShape(head: String, indent: String, tail: String): String {
		final four: String = [for (_ in 0...4) TERM].join(' + ');
		return 'class M {\n\tfunction f() {\n\t\t$head$four +\n$indent$TERM + $TERM$tail\n\t}\n}';
	}

}
