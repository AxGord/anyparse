package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * An `if` / `else` with a brace-less branch is a ladder in every statement position: the tail of a case of a
 * statement `switch`, a loop body inside that tail, and a function whose body is the `if` itself. A value
 * position (the tail of a case of a value `switch`, a block that is a variable's value) keeps the expression
 * knobs' layout, and so does an expression `if` nothing marks as a statement.
 */
@:nullSafety(Strict)
final class HxIfElseLadderStatementPositionTest extends Test {

	private static final FIT_LINE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 80}, '
		+ '"sameLine": {"ifBody": "fitLine", "elseBody": "fitLine", "fitLineIfWithElse": true}}';
	private static final SAME: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 80}, '
		+ '"sameLine": {"ifBody": "same", "elseBody": "same"}}';
	private static final DEFAULTS: String = '{"indentation": {"character": "tab", "tabWidth": 4}}';
	private static final EXPR_FIT_LINE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 80}, '
		+ '"sameLine": {"expressionIf": "fitLine", "ifBody": "fitLine", "elseBody": "fitLine"}}';
	private static final EXPR_FIT_LINE_ONLY: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "sameLine": {"expressionIf": "fitLine"}}';
	private static final CASE_TAIL_SOURCE: Array<String> = [
		'switch k {',
		'\tcase 1: if (c) a(); else b();',
		'\tdefault: for (i in xs) { if (c) a(); else b(); }',
		'}'
	];
	private static final CASE_TAIL_LADDER: Array<String> = [
		'switch k {',
		'\tcase 1:',
		'\t\tif (c)',
		'\t\t\ta();',
		'\t\telse',
		'\t\t\tb();',
		'\tdefault:',
		'\t\tfor (i in xs) {',
		'\t\t\tif (c)',
		'\t\t\t\ta();',
		'\t\t\telse',
		'\t\t\t\tb();',
		'\t\t}',
		'}'
	];
	private static final VALUE_CASE_SOURCE: Array<String> = ['var x = switch k { case 1: if (c) a() else b(); default: 2; };'];
	private static final VALUE_CASE_KEPT: Array<String> = ['var x = switch k {', '\tcase 1: if (c) a() else b();', '\tdefault: 2;', '};'];
	private static final VALUE_SITE_SOURCE: Array<String> = ['switch k {', '\tcase 1: final r = { if (a) 10; else 20; };', '}'];
	private static final VALUE_SITE_KEPT: Array<String> = [
		'switch k {',
		'\tcase 1:',
		'\t\tfinal r = {',
		'\t\t\tif (a) 10; else 20;',
		'\t\t};',
		'}'
	];
	private static final LOCAL_FN_SOURCE: Array<String> = ['switch k {', '\tcase 2: function g() if (c) a(); else b();', '}'];
	private static final LOCAL_FN_LADDER: Array<String> = [
		'switch k {',
		'\tcase 2:',
		'\t\tfunction g()',
		'\t\t\tif (c)',
		'\t\t\t\ta();',
		'\t\t\telse',
		'\t\t\t\tb();',
		'}'
	];
	private static final FN_BODY_SOURCE: String = 'class C {\n\tfunction h() if (c) a(); else b();\n}';
	private static final FN_BODY_LADDER: String = 'class C {\n\tfunction h()\n\t\tif (c)\n\t\t\ta();\n\t\telse\n\t\t\tb();\n}';
	private static final OPERAND_SOURCE: String = 'class C {\n\tfunction t() throw if (c) a else b;\n}';
	private static final OPERAND_KEPT: String = 'class C {\n\tfunction t()\n\t\tthrow if (c) a else b;\n}';
	private static final CHAIN_SOURCE: String = 'class C {\n\tfunction g() if (a) x() else if (b) y();\n}';
	private static final CHAIN_LADDER: String = 'class C {\n\tfunction g()\n\t\tif (a)\n\t\t\tx()\n\t\telse if (b)\n\t\t\ty();\n}';
	private static final VALUE_CHAIN_SOURCE: Array<String> =
		['var x = if (a) 1 else if (b) 2;', 'var f = () -> if (a) x() else if (b) y();'];
	private static final VALUE_IF_SOURCE: Array<String> = ['var v = if (a) 1 else 3;', 'return if (a) 1 else if (b) 2 else 3;'];
	private static final VALUE_IF_KEPT: Array<String> = [
		'var v = if (a)',
		'\t1',
		'else 3;',
		'return if (a)',
		'\t1',
		'else if (b)',
		'\t2',
		'else 3;'
	];
	private static final VALUE_CHAIN_KEPT: Array<String> = [
		'var x = if (a)',
		'\t1',
		'else if (b) 2;',
		'var f = () -> if (a)',
		'\tx()',
		'else if (b) y();'
	];

	public function new(): Void {
		super();
	}

	/** The tail of a statement-switch case, and a loop body inside such a tail, ladder like any other statement. */
	@:pin('control')
	@:killer('M-CASE-TAIL-STATEMENT-FRAME-OFF')
	public function testStatementCaseTailLadders(): Void {
		for (config in [DEFAULTS, SAME, FIT_LINE]) Assert.equals(fn(CASE_TAIL_LADDER), write(CASE_TAIL_SOURCE, config));
	}

	/** The tail of a value-switch case yields the switch's value: the expression knobs keep it inline. */
	@:pin('control')
	@:killer('M-CASE-TAIL-STATEMENT-FRAME-ALWAYS')
	public function testValueCaseTailIsLeftAlone(): Void {
		for (config in [DEFAULTS, SAME, FIT_LINE]) Assert.equals(fn(VALUE_CASE_KEPT), write(VALUE_CASE_SOURCE, config));
	}

	/** A block that is a variable's value is a value again inside a statement-case tail: its tail `if` stays inline. */
	@:pin('control')
	@:killer('M-STATEMENT-FRAME-SURVIVES-VALUE-SITE')
	public function testAValueSiteInsideACaseTailKeepsItsLayout(): Void {
		Assert.equals(fn(VALUE_SITE_KEPT), write(VALUE_SITE_SOURCE, DEFAULTS));
	}

	/** A function whose body is an `if` / `else` ladders both branches. */
	@:pin('control')
	@:killer('M-STATEMENT-IF-BODY-OFF')
	public function testFunctionBodyIfLadders(): Void {
		for (config in [DEFAULTS, SAME, FIT_LINE]) Assert.equals(FN_BODY_LADDER, HxWriteFixture.triviaWrite(FN_BODY_SOURCE, config));
	}

	/** A local function's body is no value of the case tail it sits in: its `if` / `else` ladders there too. */
	@:pin('control')
	@:killer('M-STATEMENT-IF-BODY-KEEPS-FRAME')
	public function testLocalFunctionInACaseTailLadders(): Void {
		Assert.equals(fn(LOCAL_FN_LADDER), write(LOCAL_FN_SOURCE, DEFAULTS));
	}

	/** An expression `if` no statement frame marks, such as a `throw` operand, keeps the expression knobs' layout. */
	@:pin('control')
	@:killer('M-EXPR-IF-LADDER-WITHOUT-FRAME')
	public function testAnExpressionIfOutsideAStatementFrameKeepsItsLayout(): Void {
		Assert.equals(OPERAND_KEPT, HxWriteFixture.triviaWrite(OPERAND_SOURCE, SAME));
	}

	/** A function body that is an `else if` chain whose last link has no `else` ladders every link. */
	@:pin('control')
	@:killer('M-EXPR-ELSE-IF-LINK-UNMARKED')
	public function testFunctionBodyElseIfChainLaddersEveryLink(): Void {
		for (config in [DEFAULTS, SAME, FIT_LINE, EXPR_FIT_LINE_ONLY])
			Assert.equals(CHAIN_LADDER, HxWriteFixture.triviaWrite(CHAIN_SOURCE, config));
	}

	/** An `else if` link of a value chain, a variable's value or an arrow body, is not marked a statement chain. */
	@:pin('control')
	@:killer('M-EXPR-ELSE-IF-LINK-UNGATED')
	public function testValueElseIfChainKeepsItsLayout(): Void {
		Assert.equals(fn(VALUE_CHAIN_KEPT), write(VALUE_CHAIN_SOURCE, EXPR_FIT_LINE));
	}

	/** A value `if`'s `else` branch under `expressionIf: fitLine` keeps its fit-line glue: the ladder adds no `else` channel to it. */
	@:pin('control')
	@:killer('M-EXPR-LADDER-FEEDS-ELSE-CHANNEL')
	public function testValueIfElseBranchKeepsItsFitLine(): Void {
		Assert.equals(fn(VALUE_IF_KEPT), write(VALUE_IF_SOURCE, EXPR_FIT_LINE_ONLY));
	}

	/** Every ladder is a fixed point of the writer. */
	@:pin('control')
	@:killer('M-CASE-TAIL-STATEMENT-FRAME-OFF')
	public function testLaddersAreIdempotent(): Void {
		for (config in [DEFAULTS, SAME, FIT_LINE]) {
			Assert.equals(fn(CASE_TAIL_LADDER), write(CASE_TAIL_LADDER, config));
			Assert.equals(FN_BODY_LADDER, HxWriteFixture.triviaWrite(FN_BODY_LADDER, config));
			Assert.equals(CHAIN_LADDER, HxWriteFixture.triviaWrite(CHAIN_LADDER, config));
		}
		Assert.equals(fn(LOCAL_FN_LADDER), write(LOCAL_FN_LADDER, DEFAULTS));
	}

	/** `lines` as the body of `function f()` in `class C`. */
	private static function fn(lines: Array<String>): String {
		return 'class C {\n\tfunction f() {\n' + lines.map(line -> '\t\t$line').join('\n') + '\n\t}\n}';
	}

	private static function write(lines: Array<String>, config: String): String {
		return HxWriteFixture.triviaWrite(fn(lines), config);
	}

}
