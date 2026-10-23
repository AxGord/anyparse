package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `wrapping.ternaryMultilineBranch` — the layout of a ternary whose branch holds a multi-line block.
 * `"break"` (hxq's default) puts `?` and `:` on lines of their own; `"inline"` keeps `cond ? macro {`
 * on the condition's line while that line fits. The key, its spellings and the set of ternaries it
 * acts on are haxe-formatter's (`MarkWrapping.hasMultilineBlockBranch`): a statement block, a
 * function body, a `switch` body anywhere in a branch, but not an object or array literal, and not
 * the brace or bracket group a branch opens with. Every expected layout below is byte-equal to the
 * fork's output under the same config.
 */
@:nullSafety(Strict)
final class HxTernaryMultilineBranchTest extends Test {

	/** The `macro {…}` branch the key is named for. */
	private static final SRC_MACRO: String =
		'class T {\n\tfunction f() {\n\t\treturn beforeDoc ? macro {\n\t\t\tfoo();\n\t\t} : macro {};\n\t}\n}';

	/** The same ternary broken, `?` and `:` on lines of their own. */
	private static final MACRO_BROKEN: String =
		'class T {\n\tfunction f() {\n\t\treturn beforeDoc\n\t\t\t? macro {\n\t\t\t\tfoo();\n\t\t\t}\n\t\t\t: macro {};\n\t}\n}';

	/** A function body inside a call argument — a block below the branch's own top node. */
	private static final SRC_FN_IN_CALL: String =
		'class T {\n\tfunction f() {\n\t\tvar w = cond ? run(function() {\n\t\t\tfoo();\n\t\t}) : null;\n\t}\n}';

	/** A function body inside an object literal inside a call: the literal is no block, the body in it is. */
	private static final SRC_OBJECT_FN_IN_CALL: String =
		'class T {\n\tfunction f() {\n\t\tvar q = cond ? f({a: function() {\n\t\t\tfoo();\n\t\t}}) : x;\n\t}\n}';

	/** The previous source under `inline`. */
	private static final OBJECT_FN_IN_CALL_INLINE: String =
		'class T {\n\tfunction f() {\n\t\tvar q = cond ? f({\n\t\t\ta: function() {\n\t\t\t\tfoo();\n\t\t\t}\n\t\t}) : x;\n\t}\n}';

	/** A branch that opens with an array group and goes on to a function body after it. */
	private static final SRC_HEAD_ARRAY_THEN_FN: String =
		'class T {\n\tfunction f() {\n\t\tvar t = cond ? [a, b].map(function(v) {\n\t\t\treturn v;\n\t\t}) : null;\n\t}\n}';

	/** An object-literal branch. */
	private static final OBJECT_THEN: String =
		'class T {\n\tfunction f() {\n\t\tvar o = cond ? {\n\t\t\ta: 1,\n\t\t\tb: 2\n\t\t} : null;\n\t}\n}';

	/** A branch that is itself a block. */
	private static final BLOCK_ELSE: String =
		'class T {\n\tfunction f() {\n\t\tvar b = cond ? macro {} : {\n\t\t\tfinal x = 1;\n\t\t\tfoo(x);\n\t\t};\n\t}\n}';

	/** A branch that opens with an array group holding a function body. */
	private static final ARRAY_OF_FN_ELSE: String =
		'class T {\n\tfunction f() {\n\t\tvar k = cond ? x : [\n\t\t\tfunction() {\n\t\t\t\tfoo();\n\t\t\t}\n\t\t];\n\t}\n}';

	/** An object literal inside a call, wide enough to break: multi-line, but no block anywhere. */
	private static final SRC_OBJECT_IN_CALL: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tvar q = cond ? make({alpha: 1, beta: 2, gamma: 3, delta: 4, epsilon: 5, zeta: 6, eta: '
		+ '7, theta: 8, iota: 9, kappa: 10, lambda: 11, mu: 12}) : null;\n\t}\n}';

	/** The key set to `inline`. */
	private static final INLINE: String = config('"ternaryMultilineBranch": "inline", ');

	/** The key set to `break`. */
	private static final BREAK: String = config('"ternaryMultilineBranch": "break", ');

	/** The key absent. */
	private static final ABSENT: String = config('');

	public function new(): Void {
		super();
	}

	public function testTheDefaultIsBreak(): Void {
		Assert.isFalse(HaxeFormat.instance.defaultWriteOptions.ternaryMultilineBranchInline, 'hxq keeps the layout it always wrote');
	}

	@:pin('control')
	@:killer('M-TERNARY-MLB-INLINE-NONE')
	public function testInlineKeepsTheBlockOnTheConditionLine(): Void {
		Assert.equals(SRC_MACRO, triviaWrite(SRC_MACRO, INLINE));
		Assert.equals(SRC_MACRO, triviaWrite(MACRO_BROKEN, INLINE), 'the source layout is not read');
	}

	@:pin('control')
	@:killer('M-TERNARY-MLB-OPTION-IGNORED')
	public function testBreakAndAnAbsentKeyBreakTheTernary(): Void {
		Assert.equals(MACRO_BROKEN, triviaWrite(SRC_MACRO, BREAK));
		Assert.equals(MACRO_BROKEN, triviaWrite(SRC_MACRO, ABSENT));
	}

	@:pin('control')
	@:killer('M-TERNARY-MLB-NO-DESCENT')
	public function testABlockBelowTheBranchTopCounts(): Void {
		Assert.equals(SRC_FN_IN_CALL, triviaWrite(SRC_FN_IN_CALL, INLINE));
		Assert.equals(OBJECT_FN_IN_CALL_INLINE, triviaWrite(SRC_OBJECT_FN_IN_CALL, INLINE));
	}

	@:pin('control')
	@:killer('M-TERNARY-MLB-PATH-UNSEARCHED')
	public function testWhatFollowsTheOpeningGroupIsSearched(): Void {
		Assert.equals(SRC_HEAD_ARRAY_THEN_FN, triviaWrite(SRC_HEAD_ARRAY_THEN_FN, INLINE));
	}

	@:pin('guard')
	public function testCollectionsAndOpeningGroupsAreNotActedOn(): Void {
		for (src in [OBJECT_THEN, BLOCK_ELSE, ARRAY_OF_FN_ELSE, SRC_OBJECT_IN_CALL])
			Assert.equals(triviaWrite(src, BREAK), triviaWrite(src, INLINE), 'the key must not act on: <$src>');
		Assert.equals(OBJECT_THEN, triviaWrite(OBJECT_THEN, INLINE));
		Assert.equals(BLOCK_ELSE, triviaWrite(BLOCK_ELSE, INLINE));
		Assert.equals(ARRAY_OF_FN_ELSE, triviaWrite(ARRAY_OF_FN_ELSE, INLINE));
	}

	@:pin('control')
	@:killer('M-TERNARY-MLB-NO-WIDTH-GUARD')
	public function testInlineBreaksAFirstLinePastTheLimit(): Void {
		final fits: String = widthSource(140);
		Assert.equals(fits, triviaWrite(fits, INLINE), 'a first line of exactly the limit stays glued');
		final over: String = widthSource(141);
		Assert.equals(
			'class T {\n\tfunction f() {\n\t\tvar v = ${''.lpad('c', 115)}\n\t\t\t? macro {\n\t\t\t\tfoo();\n\t\t\t}\n'
			+ '\t\t\t: macro {};\n\t}\n}',
			triviaWrite(over, INLINE)
		);
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/** A `var v = c… ? macro {` ternary whose first line is `cols` columns at a four-column tab. */
	private static function widthSource(cols: Int): String {
		final cond: String = ''.lpad('c', cols - '\t\tvar v = '.length - 6 - ' ? macro {'.length);
		return 'class T {\n\tfunction f() {\n\t\tvar v = $cond ? macro {\n\t\t\tfoo();\n\t\t} : macro {};\n\t}\n}';
	}

	/** The shared config with `extraWrapping` (a comma-terminated JSON fragment) spliced into its `wrapping` section. */
	private static function config(extraWrapping: String): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {$extraWrapping"maxLineLength": 140}}';
	}

}
