package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A statement `if` / `else` with a brace-less branch ladders. The loop body of an anonymous function's expression body
 * is such a statement; a comprehension's or a returned loop's `if` is a value and keeps its line. A block wrapped in
 * metadata or parentheses is written on its own line by the `if` like a brace-less branch, so a chain of them ladders
 * as well, while a chain braced in every branch by plain blocks keeps its body knob's placement.
 */
@:nullSafety(Strict)
final class HxIfElseLadderLoopBodyTest extends Test {

	private static final DEFAULTS: String = '{"indentation": {"character": "tab", "tabWidth": 4}}';
	private static final FN_BODIES_SAME: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "sameLine": {"functionBody": "same", "anonFunctionBody": "same"}}';
	private static final LOOP_SOURCE: Array<String> = [
		'var q = function() for (x in xs) if (c) a(); else b();',
		'var r = function() while (x) if (c) a(); else b();',
		'var n = function() for (x in xs) for (y in ys) if (c) a(); else b();',
		'var e = function() while (x) if (c) a(); else if (d) b(); else e();'
	];
	private static final LOOP_LADDER: Array<String> = [
		'var q = function()',
		'\tfor (x in xs)',
		'\t\tif (c)',
		'\t\t\ta();',
		'\t\telse',
		'\t\t\tb();',
		'var r = function()',
		'\twhile (x)',
		'\t\tif (c)',
		'\t\t\ta();',
		'\t\telse',
		'\t\t\tb();',
		'var n = function()',
		'\tfor (x in xs)',
		'\t\tfor (y in ys)',
		'\t\t\tif (c)',
		'\t\t\t\ta();',
		'\t\t\telse',
		'\t\t\t\tb();',
		'var e = function()',
		'\twhile (x)',
		'\t\tif (c)',
		'\t\t\ta();',
		'\t\telse if (d)',
		'\t\t\tb();',
		'\t\telse',
		'\t\t\te();'
	];
	private static final VALUE_SOURCE: Array<String> = [
		'var v = for (x in xs) if (c) 1 else 2;',
		'call(for (x in xs) if (c) 1 else 2);',
		'x = for (x in xs) if (c) 1 else 2;',
		'var y = function() return for (x in xs) if (c) 1 else 2;',
		'var z = [for (x in xs) if (c) 1 else 2];'
	];
	private static final BRACED_LOOP_SOURCE: Array<String> = ['var q = function() for (x in xs) if (c) { a(); } else { b(); };'];
	private static final BRACED_LOOP_GLUED: Array<String> = [
		'var q = function() for (x in xs) if (c) {',
		'\ta();',
		'} else {',
		'\tb();',
		'};'
	];
	private static final WRAPPED_SOURCE: Array<String> = [
		'var s = function() if (c) @:m {a();} else @:m {b();};',
		'var t = function() if (c) ({a();}) else ({b();});'
	];
	private static final WRAPPED_LADDER: Array<String> = [
		'var s = function()',
		'\tif (c)',
		'\t\t@:m {',
		'\t\t\ta();',
		'\t\t}',
		'\telse',
		'\t\t@:m {',
		'\t\t\tb();',
		'\t\t};',
		'var t = function()',
		'\tif (c)',
		'\t\t({',
		'\t\t\ta();',
		'\t\t})',
		'\telse',
		'\t\t({',
		'\t\t\tb();',
		'\t\t});'
	];
	private static final NAMED_WRAPPED_SOURCE: String = 'class C {\n\tfunction h() if (c) @:m {a();} else @:m {b();}\n}';
	private static final NAMED_WRAPPED_LADDER: String =
		'class C {\n\tfunction h()\n\t\tif (c)\n\t\t\t@:m {\n\t\t\t\ta();\n\t\t\t}\n\t\telse\n\t\t\t@:m {\n\t\t\t\tb();\n\t\t\t}\n}';

	public function new(): Void {
		super();
	}

	/** The loop body of an anonymous function's expression body ladders its `if` / `else` as a statement loop does. */
	@:pin('control')
	@:killer('M-STATEMENT-TAIL-IGNORES-LOOPS', 'M-STATEMENT-TAIL-LOOKS-THROUGH-ONE-LOOP')
	public function testLoopBodyIfElseInAnExpressionBodyLadders(): Void {
		for (config in [DEFAULTS, FN_BODIES_SAME]) {
			Assert.equals(fn(LOOP_LADDER), write(LOOP_SOURCE, config));
			Assert.equals(fn(LOOP_LADDER), write(LOOP_LADDER, config));
		}
	}

	/** A loop that is a value (initialiser, argument, assignment, return, comprehension) keeps its `if` / `else` on its line. */
	@:pin('guard')
	public function testValueLoopsKeepTheirLine(): Void {
		Assert.equals(fn(VALUE_SOURCE), write(VALUE_SOURCE, DEFAULTS));
	}

	/** A loop body braced in every branch keeps the placement the body knob chose. */
	@:pin('control')
	@:killer('M-BARE-BRANCH-ALWAYS')
	public function testABracedLoopBodyKeepsItsBodyKnob(): Void {
		Assert.equals(fn(BRACED_LOOP_GLUED), write(BRACED_LOOP_SOURCE, FN_BODIES_SAME));
	}

	/** Blocks wrapped in metadata or parentheses are written on their own lines, so a chain of them ladders like a bare one. */
	@:pin('control')
	@:killer('M-WRAPPED-BLOCK-COUNTS-BRACED')
	public function testWrappedBlocksLadderTheFunctionBody(): Void {
		Assert.equals(fn(WRAPPED_LADDER), write(WRAPPED_SOURCE, FN_BODIES_SAME));
		Assert.equals(NAMED_WRAPPED_LADDER, HxWriteFixture.triviaWrite(NAMED_WRAPPED_SOURCE, FN_BODIES_SAME));
	}

	/** `lines` as the body of `function f()` in `class C`. */
	private static function fn(lines: Array<String>): String {
		return 'class C {\n\tfunction f() {\n' + lines.map(line -> '\t\t$line').join('\n') + '\n\t}\n}';
	}

	private static function write(lines: Array<String>, config: String): String {
		return HxWriteFixture.triviaWrite(fn(lines), config);
	}

}
