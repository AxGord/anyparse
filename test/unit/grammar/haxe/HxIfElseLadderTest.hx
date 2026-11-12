package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A statement `if` with an `else` whose chain holds a branch body without braces of its own is a ladder in every config:
 * each brace-less body on its own line one indent deeper, `else` at the `if`'s indent. A chain whose every branch is
 * brace-delimited (a block, a `switch … { }`) keeps its glue, and an `if` without an `else` is left as it is. An `if` in
 * expression position (it yields a value) is placed by the expression knobs, never laddered.
 */
@:nullSafety(Strict)
final class HxIfElseLadderTest extends Test {

	/** fitLine bodies with fitLine kept for an `if` with an `else`. */
	private static final FIT_LINE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 80}, '
		+ '"sameLine": {"ifBody": "fitLine", "elseBody": "fitLine", "fitLineIfWithElse": true}}';

	/** Bodies on the head's line. */
	private static final SAME: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 80}, '
		+ '"sameLine": {"ifBody": "same", "elseBody": "same"}}';

	/** Bodies on the head's line and `else` cuddled to the then-body, even after a `;`. */
	private static final SAME_ELSE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 80}, '
		+ '"sameLine": {"ifBody": "same", "elseBody": "same", "ifElse": "same", "ifElseSemicolonNextLine": false}}';

	/** The loader's defaults. */
	private static final DEFAULTS: String = '{"indentation": {"character": "tab", "tabWidth": 4}}';

	/** A value-`if` placed by `expressionIf: fitLine`. */
	private static final VALUE_FIT: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "sameLine": {"expressionIf": "fitLine", "fitLineIfWithElse": true}}';

	private static final SHORT_SOURCE: Array<String> = ['if (c) foo(); else call();'];
	private static final SHORT_LADDER: Array<String> = ['if (c)', '\tfoo();', 'else', '\tcall();'];
	private static final CHAIN_SOURCE: Array<String> = ['if (a) x(); else if (b) y(); else z();'];
	private static final CHAIN_LADDER: Array<String> = ['if (a)', '\tx();', 'else if (b)', '\ty();', 'else', '\tz();'];
	private static final LINK_SOURCE: Array<String> = ['if (a) { p(); } else if (b) w();'];
	private static final LINK_LADDER: Array<String> = ['if (a) {', '\tp();', '} else if (b)', '\tw();'];
	private static final BRACED_SOURCE: Array<String> = [
		'if (v) switch a { case 1: x(); } else switch b { case 2: y(); }',
		'if (c) switch a { case 1: x(); } else { b(); }',
		'if (c) { a(); } else { b(); }'
	];
	private static final BRACED_GLUE: Array<String> = [
		'if (v) switch a {',
		'\tcase 1:',
		'\t\tx();',
		'} else switch b {',
		'\tcase 2:',
		'\t\ty();',
		'}',
		'if (c) switch a {',
		'\tcase 1:',
		'\t\tx();',
		'} else {',
		'\tb();',
		'}',
		'if (c) {',
		'\ta();',
		'} else {',
		'\tb();',
		'}'
	];
	private static final MIXED_SOURCE: Array<String> = ['if (c) { a(); } else bar();', 'if (c) switch a { case 1: x(); } else foo();'];
	private static final MIXED_LADDER: Array<String> = [
		'if (c) {',
		'\ta();',
		'} else',
		'\tbar();',
		'if (c) switch a {',
		'\tcase 1:',
		'\t\tx();',
		'} else',
		'\tfoo();'
	];
	private static final NO_ELSE: Array<String> = ['if (c) foo();'];
	private static final NESTED_SOURCE: Array<String> = ['if (a) for (i in xs) if (b) y(); else z(); else w();'];
	private static final NESTED_LADDER: Array<String> = [
		'if (a)',
		'\tfor (i in xs)',
		'\t\tif (b)',
		'\t\t\ty();',
		'\t\telse',
		'\t\t\tz();',
		'else',
		'\tw();'
	];
	private static final COMMENT_SOURCE: Array<String> = ['if (a) x(); // after then', 'else if (b) y(); // after link', 'else z();'];
	private static final COMMENT_LADDER: Array<String> = [
		'if (a)',
		'\tx(); // after then',
		'else if (b)',
		'\ty(); // after link',
		'else',
		'\tz();'
	];
	private static final VALUE_TAIL_SOURCE: Array<String> = ['final r = { if (a) 10; else 20; };'];
	private static final VALUE_TAIL_KEPT: Array<String> = ['final r = {', '\tif (a) 10; else 20;', '};'];
	private static final VALUE_SOURCE: Array<String> = ['var x = if (c) a else b;'];
	private static final VALUE_FIT_KEPT: Array<String> = ['var x = if (c) a', 'else b;'];

	public function new(): Void {
		super();
	}

	/** A short brace-less pair is a ladder whatever the placement. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testShortPairLaddersInEveryConfig(): Void {
		for (config in [FIT_LINE, SAME, DEFAULTS]) Assert.equals(fn(SHORT_LADDER), write(SHORT_SOURCE, config));
	}

	/** An `else if` chain is one ladder: every link stays an `else if (…)` head. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testElseIfChainIsOneLadder(): Void {
		for (config in [FIT_LINE, SAME]) Assert.equals(fn(CHAIN_LADDER), write(CHAIN_SOURCE, config));
	}

	/** The last `else if` link has no `else` of its own and still belongs to the chain. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-NO-LINK')
	public function testElseIfLinkWithoutElseLadders(): Void {
		Assert.equals(fn(LINK_LADDER), write(LINK_SOURCE, SAME));
	}

	/** Every branch brace-delimited: the glue stays, `} else switch b {` included. */
	@:pin('control')
	@:killer('M-IF-ELSE-SWITCH-LADDERS')
	public function testBraceDelimitedBranchesKeepTheGlue(): Void {
		for (config in [FIT_LINE, SAME]) Assert.equals(fn(BRACED_GLUE), write(BRACED_SOURCE, config));
	}

	/** A braced branch beside a brace-less one keeps `} else` and moves the brace-less body below. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testMixedPutsBraceLessBodyBelow(): Void {
		for (config in [FIT_LINE, SAME]) Assert.equals(fn(MIXED_LADDER), write(MIXED_SOURCE, config));
	}

	/** An `if` without an `else` is no chain: its body keeps its placement. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-NO-ELSE')
	public function testNoElseIsLeftAlone(): Void {
		for (config in [FIT_LINE, SAME]) Assert.equals(fn(NO_ELSE), write(NO_ELSE, config));
	}

	/** An if/else nested in a branch body is a ladder of its own. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testNestedChainLaddersOnItsOwn(): Void {
		Assert.equals(fn(NESTED_LADDER), write(NESTED_SOURCE, SAME));
	}

	/** A trailing comment after a branch body rides with the body onto its own line. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testCommentsBetweenBranchesStayWithTheirBodies(): Void {
		Assert.equals(fn(COMMENT_LADDER), write(COMMENT_SOURCE, SAME));
	}

	/** Under a `same` placement with `else` cuddled to its then-body, the `else` still leaves the laddered body's line. */
	@:pin('control')
	@:killer('M-IF-ELSE-SEP-INLINE')
	public function testElseStartsItsOwnLineUnderSame(): Void {
		Assert.equals(fn(SHORT_LADDER), write(SHORT_SOURCE, SAME_ELSE));
		Assert.equals(fn(CHAIN_LADDER), write(CHAIN_SOURCE, SAME_ELSE));
		Assert.equals(fn(MIXED_LADDER), write(MIXED_SOURCE, SAME_ELSE));
	}

	/** Every ladder is a fixed point of the writer. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testLaddersAreIdempotent(): Void {
		final ladders: Array<Array<String>> = [
			SHORT_LADDER,
			CHAIN_LADDER,
			LINK_LADDER,
			BRACED_GLUE,
			MIXED_LADDER,
			NESTED_LADDER,
			COMMENT_LADDER
		];
		for (ladder in ladders) Assert.equals(fn(ladder), write(ladder, SAME));
	}

	/** A value-`if` is no statement chain: `fitLineIfWithElse` still keeps its then-branch on the head. */
	@:pin('control')
	@:killer('M-VALUE-IF-FIT-WITH-ELSE')
	public function testValueIfStillReadsFitLineIfWithElse(): Void {
		Assert.equals(fn(VALUE_FIT_KEPT), write(VALUE_SOURCE, VALUE_FIT));
	}

	/** A statement `if` that yields a block's value sits in expression position: the expression knob places it, no ladder. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-IN-EXPR')
	public function testValueTailIfOfABlockIsLeftAlone(): Void {
		Assert.equals(fn(VALUE_TAIL_KEPT), write(VALUE_TAIL_SOURCE, DEFAULTS));
	}

	/** `lines` as the body of `function f()` in `class C`. */
	private static function fn(lines: Array<String>): String {
		return 'class C {\n\tfunction f() {\n' + lines.map(line -> '\t\t$line').join('\n') + '\n\t}\n}';
	}

	private static function write(lines: Array<String>, config: String): String {
		return HxWriteFixture.triviaWrite(fn(lines), config);
	}

}
