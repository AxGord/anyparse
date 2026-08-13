package unit;

import utest.Assert;
import utest.Test;

/**
 * A call whose SOLE argument is an `if`-EXPRESSION, under `sameLine.expressionIf: next` -- the
 * policy that breaks such an expression across lines. Every OTHER host indents the pieces it
 * produces: a parenthesized one, a multi-argument call, an array literal, an object literal. The
 * sole-argument call is the one that did not, because a `noWrap` cascade rule (`itemCount <= 1`)
 * glues the argument to the open paren and the flat shape stripped the indent context its hard
 * breaks need, rendering them at column 0.
 *
 * The expectation mirrors the parenthesized form, which is the same "glued delimiters, inner
 * breaks" shape: values one indent deeper than the statement, `else` back at the statement indent,
 * the closing delimiter glued to the last value.
 */
@:nullSafety(Strict)
final class HxCallParamIfExpressionArgSliceTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {'
		+ '"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", '
		+ '"value": 100}], "type": "noWrap"}]}}, "sameLine": {"expressionIf": "next"}}';

	public function new(): Void {
		super();
	}

	/** The bug: the sole argument's hard breaks must indent under the glued call paren. */
	public function testSoleIfExpressionArgIndentsUnderGluedParen(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\twrite(if (hasCData)\n\t\t\t\'</\'\n\t\telse\n\t\t\t\'$$tabs</\');\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** An `else if` chain in the same position -- the shape `join-branch-call` emits for 3+ branches. */
	public function testSoleIfExpressionChainArgIndents(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\titems.push(if (i < 10)\n\t\t\t\'a\'\n\t\telse if (i < 100)\n\t\t\t\'b\'\n'
			+ '\t\telse\n\t\t\t\'c\');\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** The reference shape the fix mirrors: a parenthesized if-expression already indents correctly. */
	public function testParenthesizedIfExpressionUnchanged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a:Int = (if (c)\n\t\t\t1\n\t\telse\n\t\t\t2);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** A MULTI-argument call leading-breaks instead of gluing, and already indents -- must stay untouched. */
	public function testMultiArgIfExpressionUnchanged(): Void {
		final src: String =
			'class C {\n\tfunction test() {\n\t\tg(\n\t\t\t9,\n\t\t\tif (c)\n\t\t\t\t1\n\t\t\telse\n\t\t\t\t2\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** A sole argument with NO inner break keeps its plain glued one-liner. */
	public function testSoleFlatArgUnchanged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\twrite(value);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
