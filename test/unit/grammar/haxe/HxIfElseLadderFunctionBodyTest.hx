package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * The body of an anonymous function or a lambda is a statement position whatever site holds the function: a block
 * body's tail `if` / `else` with a brace-less branch ladders, and so does an expression body that is such an `if`,
 * placed on its own line whatever the body knob says, as a named function's body is. An arrow's block body is laid
 * out as a statement list too, although Haxe returns its last value; an arrow whose body is the `if` itself is an
 * expression and keeps the expression knobs' layout, and so does a value block inside a function body.
 */
@:nullSafety(Strict)
final class HxIfElseLadderFunctionBodyTest extends Test {

	private static final FIT_LINE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 80}, '
		+ '"sameLine": {"ifBody": "fitLine", "elseBody": "fitLine", "fitLineIfWithElse": true}}';
	private static final SAME: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 80}, '
		+ '"sameLine": {"ifBody": "same", "elseBody": "same"}}';
	private static final DEFAULTS: String = '{"indentation": {"character": "tab", "tabWidth": 4}}';
	private static final BLOCK_TAIL_SOURCE: Array<String> = [
		'var f = function() { foo(); if (c) a(); else b(); };',
		'var h = () -> { foo(); if (c) a(); else b(); };',
		'call(function() { foo(); if (c) a(); else b(); });'
	];
	private static final BLOCK_TAIL_LADDER: Array<String> = [
		'var f = function() {',
		'\tfoo();',
		'\tif (c)',
		'\t\ta();',
		'\telse',
		'\t\tb();',
		'};',
		'var h = () -> {',
		'\tfoo();',
		'\tif (c)',
		'\t\ta();',
		'\telse',
		'\t\tb();',
		'};',
		'call(function() {',
		'\tfoo();',
		'\tif (c)',
		'\t\ta();',
		'\telse',
		'\t\tb();',
		'});'
	];
	private static final FN_BODY_SAME: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "sameLine": {"functionBody": "same"}}';
	private static final FN_BODY_FIT_LINE: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "sameLine": {"functionBody": "fitLine"}}';
	private static final NAMED_FN_SOURCE: String = 'class C {\n\tfunction h() if (c) a(); else b();\n}';
	private static final NAMED_FN_LADDER: String = 'class C {\n\tfunction h()\n\t\tif (c)\n\t\t\ta();\n\t\telse\n\t\t\tb();\n}';
	private static final INFIX_ARROW_SOURCE: Array<String> = ['xs.map(x -> { foo(); if (c) a(); else b(); });'];
	private static final INFIX_ARROW_LADDER: Array<String> =
		['xs.map(x -> {', '\tfoo();', '\tif (c)', '\t\ta();', '\telse', '\t\tb();', '});'];
	private static final CASE_TAIL_FN_SOURCE: Array<String> =
		['switch k {', '\tcase 1: var q = function() { if (c) a(); else b(); };', '}'];
	private static final CASE_TAIL_FN_LADDER: Array<String> = [
		'switch k {',
		'\tcase 1:',
		'\t\tvar q = function() {',
		'\t\t\tif (c)',
		'\t\t\t\ta();',
		'\t\t\telse',
		'\t\t\t\tb();',
		'\t\t};',
		'}'
	];
	private static final EXPR_BODY_SOURCE: Array<String> = ['var g = function() if (c) a(); else b();'];
	private static final EXPR_BODY_LADDER: Array<String> = ['var g = function()', '\tif (c)', '\t\ta();', '\telse', '\t\tb();'];
	private static final VALUE_SOURCE: Array<String> = [
		'var k = () -> if (c) a() else b();',
		'var v = { foo(); if (c) 1 else 2; };',
		'var w = if (c) 1 else 2;'
	];
	private static final VALUE_KEPT: Array<String> = [
		'var k = () -> if (c) a() else b();',
		'var v = {',
		'\tfoo();',
		'\tif (c) 1 else 2;',
		'};',
		'var w = if (c) 1 else 2;'
	];
	private static final FN_BODIES_SAME: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "sameLine": {"functionBody": "same", "anonFunctionBody": "same"}}';
	private static final BRACED_NAMED_FN_SOURCE: String = 'class C {\n\tfunction h() if (c) { a(); } else { b(); }\n}';
	private static final BRACED_NAMED_FN_GLUED: String = 'class C {\n\tfunction h() if (c) {\n\t\ta();\n\t} else {\n\t\tb();\n\t}\n}';
	private static final BRACED_EXPR_BODY_SOURCE: Array<String> = ['var g = function() if (c) { a(); } else { b(); };'];
	private static final BRACED_EXPR_BODY_GLUED: Array<String> = ['var g = function() if (c) {', '\ta();', '} else {', '\tb();', '};'];
	private static final SWITCH_NAMED_FN_SOURCE: String =
		'class C {\n\tfunction h() if (c) switch x { case 1: a(); } else switch y { case 2: b(); }\n}';
	private static final SWITCH_NAMED_FN_GLUED: String =
		'class C {\n\tfunction h() if (c) switch x {\n\t\tcase 1: a();\n\t} else switch y {\n\t\tcase 2: b();\n\t}\n}';
	private static final SWITCH_EXPR_BODY_SOURCE: Array<String> = [
		'var g = function() if (c) switch x { case 1: a(); } else switch y { case 2: b(); };'
	];
	private static final SWITCH_EXPR_BODY_GLUED: Array<String> = [
		'var g = function() if (c) switch x {',
		'\tcase 1: a();',
		'} else switch y {',
		'\tcase 2: b();',
		'};'
	];
	private static final INNER_VALUE_SOURCE: Array<String> = [
		'var f = function() { var v = { foo(); if (c) 1; else 2; }; x = { if (c) 1; else 2; }; return { if (c) 1; else 2; }; };'
	];
	private static final INNER_VALUE_KEPT: Array<String> = [
		'var f = function() {',
		'\tvar v = {',
		'\t\tfoo();',
		'\t\tif (c) 1; else 2;',
		'\t};',
		'\tx = {',
		'\t\tif (c) 1; else 2;',
		'\t};',
		'\treturn {',
		'\t\tif (c) 1; else 2;',
		'\t};',
		'};'
	];

	public function new(): Void {
		super();
	}

	/**
	 * The tail of an anonymous function's or a lambda's block body ladders, as a variable's value or a call argument alike.
	 */
	@:pin('control')
	@:killer('M-STATEMENT-BODY-FOR-CTOR-OFF')
	public function testBlockBodyTailLadders(): Void {
		for (config in [DEFAULTS, SAME, FIT_LINE]) Assert.equals(fn(BLOCK_TAIL_LADDER), write(BLOCK_TAIL_SOURCE, config));
	}

	/** The single-parameter arrow `x -> { … }`, an infix operator, ladders its block body's tail as the parenthesised one does. */
	@:pin('control')
	@:killer('M-ARROW-OPERAND-STATEMENT-BODY-OFF')
	public function testInfixArrowBlockBodyTailLadders(): Void {
		for (config in [DEFAULTS, SAME, FIT_LINE]) Assert.equals(fn(INFIX_ARROW_LADDER), write(INFIX_ARROW_SOURCE, config));
	}

	/** An anonymous function inside a statement-case tail is no value of that tail: its block tail ladders. */
	@:pin('control')
	@:killer('M-STATEMENT-BODY-FOR-CTOR-OFF')
	public function testBlockBodyTailInACaseTailLadders(): Void {
		Assert.equals(fn(CASE_TAIL_FN_LADDER), write(CASE_TAIL_FN_SOURCE, DEFAULTS));
	}

	/** An anonymous function whose expression body is an `if` / `else` ladders it on the next line, as a named function does. */
	@:pin('control')
	@:killer('M-STATEMENT-IF-BODY-NEXT-OFF')
	public function testExpressionBodyIfLadders(): Void {
		for (config in [DEFAULTS, SAME, FIT_LINE]) Assert.equals(fn(EXPR_BODY_LADDER), write(EXPR_BODY_SOURCE, config));
	}

	/** A named function's `if` / `else` body ladders on the next line whatever `functionBody` placed it, as a loop body does. */
	@:pin('control')
	@:killer('M-STATEMENT-IF-BODY-NEXT-OFF')
	public function testNamedFunctionBodyLaddersOnTheNextLineWhateverItsBodyKnob(): Void {
		for (config in [FN_BODY_SAME, FN_BODY_FIT_LINE])
			Assert.equals(NAMED_FN_LADDER, HxWriteFixture.triviaWrite(NAMED_FN_SOURCE, config));
	}

	/** An arrow whose body is the `if`, and a block or `if` that is a variable's value, keep their layout. */
	@:pin('guard')
	public function testValuePositionsKeepTheirLayout(): Void {
		Assert.equals(fn(VALUE_KEPT), write(VALUE_SOURCE, DEFAULTS));
	}

	/**
	 * A function body whose `if` / `else` chain is braced in every branch, by a block or a brace-led `switch`, has no
	 * ladder: it keeps the placement its body knob chose, glued to the head under `same`.
	 */
	@:pin('control')
	@:killer('M-BARE-BRANCH-ALWAYS')
	public function testAnAllBracedIfElseFunctionBodyKeepsItsBodyKnob(): Void {
		Assert.equals(BRACED_NAMED_FN_GLUED, HxWriteFixture.triviaWrite(BRACED_NAMED_FN_SOURCE, FN_BODIES_SAME));
		Assert.equals(SWITCH_NAMED_FN_GLUED, HxWriteFixture.triviaWrite(SWITCH_NAMED_FN_SOURCE, FN_BODIES_SAME));
		for (config in [DEFAULTS, FN_BODIES_SAME]) {
			Assert.equals(fn(BRACED_EXPR_BODY_GLUED), write(BRACED_EXPR_BODY_SOURCE, config));
			Assert.equals(fn(SWITCH_EXPR_BODY_GLUED), write(SWITCH_EXPR_BODY_SOURCE, config));
		}
	}

	/** A value block inside an anonymous function's block body is the value of its own site: its tail stays inline. */
	@:pin('guard')
	public function testAValueBlockInsideAFunctionBodyKeepsItsTailInline(): Void {
		Assert.equals(fn(INNER_VALUE_KEPT), write(INNER_VALUE_SOURCE, DEFAULTS));
	}

	/** Every ladder is a fixed point of the writer. */
	@:pin('control')
	@:killer('M-STATEMENT-BODY-FOR-CTOR-OFF')
	public function testLaddersAreIdempotent(): Void {
		for (config in [DEFAULTS, SAME, FIT_LINE]) {
			Assert.equals(fn(BLOCK_TAIL_LADDER), write(BLOCK_TAIL_LADDER, config));
			Assert.equals(fn(INFIX_ARROW_LADDER), write(INFIX_ARROW_LADDER, config));
			Assert.equals(fn(EXPR_BODY_LADDER), write(EXPR_BODY_LADDER, config));
		}
		Assert.equals(fn(CASE_TAIL_FN_LADDER), write(CASE_TAIL_FN_LADDER, DEFAULTS));
	}

	/** `lines` as the body of `function f()` in `class C`. */
	private static function fn(lines: Array<String>): String {
		return 'class C {\n\tfunction f() {\n' + lines.map(line -> '\t\t$line').join('\n') + '\n\t}\n}';
	}

	private static function write(lines: Array<String>, config: String): String {
		return HxWriteFixture.triviaWrite(fn(lines), config);
	}

}
