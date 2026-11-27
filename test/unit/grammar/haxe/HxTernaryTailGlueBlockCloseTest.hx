package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import utest.Assert;
import utest.Test;

/**
 * `sameLine.ternaryTailGlueMaxLength` — a ternary whose condition breaks only inside the construct it ends in puts a
 * short `? a : b` on that construct's closing line, an `&&` / `||` condition keeping its head on the first line
 * (`return k != null && xs.exists(x ->` … `) ? k : null;`). Each gate failing alone keeps the `?` / `:` ladder: a wide
 * tail, a call or two-step field branch, a nested ternary, a condition that does not end in a closer, a construct that
 * fits on one line, a closing line past the limit. An `if` condition and an unset key are untouched.
 */
@:nullSafety(Strict)
final class HxTernaryTailGlueBlockCloseTest extends Test {

	/** A lambda whose body does not fit one line. */
	private static final LAMBDA: String = 'x -> x > 0 && k.length > x && k.charCodeAt(x) == 32 && k.charCodeAt(x) == 33';

	/** The key set. */
	private static final ON: String = config(80, true);

	/** The key unset. */
	private static final OFF: String = config(80, false);

	public function new(): Void {
		super();
	}

	public function testTheDefaultIsOff(): Void {
		Assert.equals(0, HaxeFormat.instance.defaultWriteOptions.ternaryTailGlueMaxLength, 'hxq keeps the ladder it always wrote');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-NONE')
	public function testATailRidesTheClosingLine(): Void {
		final chain: String = glued('k != null && xs.exists(x ->', ') ? k : null;');
		Assert.equals(chain, write('return k != null && xs.exists($LAMBDA) ? k : null;', ON));
		Assert.equals(chain, HxWriteFixture.triviaWrite(chain, ON), 'the glued layout is stable');
		Assert.equals(
			chain, HxWriteFixture.plainWrite(fn('\t\treturn k != null && xs.exists($LAMBDA) ? k : null;\n'), ON),
			'the plain writer glues too'
		);
		Assert.equals(glued('xs.exists(x ->', ') ? k : null;'), write('return xs.exists($LAMBDA) ? k : null;', ON));
		Assert.equals(
			fn('\t\treturn k != null && xs.exists(x -> {\n\t\t\ttrace(x);\n\t\t\treturn x > 0;\n\t\t}) ? k : null;\n'),
			write('return k != null && xs.exists(x -> {trace(x); return x > 0;}) ? k : null;', ON)
		);
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-ALL-BREAKS')
	public function testAConstructBrokenByWidthGlues(): Void {
		Assert.equals(glued('xs.exists(x ->', ') ? k : null;'), write('return xs.exists($LAMBDA) ? k : null;', ON));
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-NO-HEAD-LIFT')
	public function testTheChainHeadStaysOnTheFirstLine(): Void {
		Assert.equals(
			glued('k != null && xs.exists(x ->', ') ? k : null;'), write('return k != null && xs.exists($LAMBDA) ? k : null;', ON)
		);
		Assert.equals(
			glued('k == null || xs.exists(x ->', ') ? k : null;'), write('return k == null || xs.exists($LAMBDA) ? k : null;', ON)
		);
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-NO-CAP')
	public function testAWideTailKeepsTheLadder(): Void {
		Assert.equals(glued('xs.exists(x ->', ') ? aaaaaaaa : bbbbbbb;'), write('return xs.exists($LAMBDA) ? aaaaaaaa : bbbbbbb;', ON));
		assertLadder('return xs.exists($LAMBDA) ? aaaaaaaaa : bbbbbbb;');
		assertLadder('return k != null && xs.exists($LAMBDA) ? someLongerName : otherLongName;');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-ANY-BRANCH')
	public function testACallBranchKeepsTheLadder(): Void {
		assertLadder('return k != null && xs.exists($LAMBDA) ? k.foo(1) : null;');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-DEEP-FIELD')
	public function testATwoStepFieldKeepsTheLadder(): Void {
		Assert.equals(glued('xs.exists(x ->', ') ? a.b : this.c;'), write('return xs.exists($LAMBDA) ? a.b : this.c;', ON));
		assertLadder('return xs.exists($LAMBDA) ? a.b.c : null;');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-NESTED')
	public function testATernaryInABranchKeepsItsLayout(): Void {
		assertLadder('return c ? a : k != null && xs.exists($LAMBDA) ? k : null;');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-NESTED-COND')
	public function testATernaryInAConditionKeepsItsLayout(): Void {
		final inner: String = '\t\t\tk != null\n\t\t\t\t&& xs.exists(x ->\n${body(5)}\t\t\t\t)\n\t\t\t\t? true\n\t\t\t\t: false\n';
		Assert.equals(
			fn('\t\treturn ys.exists(y ->\n$inner\t\t) ? k : null;\n'),
			write('return ys.exists(y -> k != null && xs.exists($LAMBDA) ? true : false) ? k : null;', ON),
			'the outer ternary glues, the one in its condition keeps the ladder'
		);
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-IN-PAREN')
	public function testATernaryInAParenKeepsItsLayout(): Void {
		assertLadder('final v = (k != null && xs.exists($LAMBDA) ? k : null);');
		final run: String = '(last && tc ? args[j].afterSepComment : null) ?? (afterSepExpr(c, macro j) ? tc : null)';
		final deep: String = 'return macro {\n\t\t\tfor (x in y) {\n\t\t\t\tif (z) {\n\t\t\t\t\tfinal afterSep: Null<String> = $run;\n'
			+ '\t\t\t\t}\n\t\t\t}\n\t\t};';
		Assert.equals(write(deep, config(140, false)), write(deep, config(140, true)), 'the paren owns the wrap');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-NO-CLOSER')
	public function testAConditionNotEndingInACloserKeepsTheLadder(): Void {
		assertLadder('return k != null && xs.filter($LAMBDA).length > 0 ? k : null;');
		assertLadder('return k != null && xs.length > 0 && k.length > 2 && k.charCodeAt(0) == 32 && k.charCodeAt(1) == 33 ? k : null;');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-ONE-LINE-OPERAND')
	public function testALastOperandFittingItsLineKeepsTheLadder(): Void {
		assertLadder('return k != null && xs.exists(x -> x > 0 && k.length > x && k.charCodeAt(x) == 32) ? k : null;');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-NO-HEAD-WIDTH')
	public function testAConditionFittingTheHeadLineKeepsTheLadder(): Void {
		assertLadder('return xs.exists(x -> x > 0 && k.length > x && k.charCodeAt(x) == 32222) ? k : null;');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-NO-CLOSING-WIDTH')
	public function testAClosingLinePastTheLimitKeepsTheLadder(): Void {
		final src: String = 'return xs.exists(x -> x > 0 && k.length > x) ? aaaaaaaa : bbbbbbb;';
		Assert.equals(
			fn('\t\treturn xs.exists(x ->\n\t\t\tx > 0\n\t\t\t\t&& k.length > x\n\t\t) ? aaaaaaaa : bbbbbbb;\n'),
			write(src, config(31, true)), 'the closing line is exactly the limit'
		);
		Assert.equals(write(src, config(30, false)), write(src, config(30, true)));
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-GLUE-EARLY-OPERAND-DECIDED')
	public function testAnEarlierOperandTheBaseBreaksKeepsTheLadder(): Void {
		assertLadder(
			'return (aaaaaaaaaaaa || bbbbbbbbbbbbbbb || cccccccccccccccccccc || dddddddddddddddddd) && xs.exists($LAMBDA) ? k : null;'
		);
	}

	@:pin('guard')
	public function testAnIfConditionIsUntouched(): Void {
		final src: String = 'if (k != null && xs.exists($LAMBDA)) return k;';
		Assert.equals(write(src, OFF), write(src, ON));
	}

	@:pin('guard')
	public function testAnUnsetKeyKeepsTheLadder(): Void {
		final ladder: String = fn('\t\treturn k != null\n\t\t\t&& xs.exists(x ->\n${body(4)}\t\t\t)\n\t\t\t? k\n\t\t\t: null;\n');
		Assert.equals(ladder, write('return k != null && xs.exists($LAMBDA) ? k : null;', OFF));
		Assert.equals(
			ladder, HxWriteFixture.triviaWrite(glued('k != null && xs.exists(x ->', ') ? k : null;'), OFF), 'the source layout is not read'
		);
	}

	/** `stmt` under `ON` and `OFF` alike: the key leaves it as the plain writer lays it out. */
	private static function assertLadder(stmt: String): Void {
		Assert.equals(write(stmt, OFF), write(stmt, ON), stmt);
	}

	/** `stmt`, one statement, written in a function body under `config`. */
	private static function write(stmt: String, config: String): String {
		return HxWriteFixture.triviaWrite(fn('\t\t$stmt\n'), config);
	}

	/** The glued statement: `head` on the return line, the lambda body one level in, `close` at the statement's indent. */
	private static function glued(head: String, close: String): String {
		return fn('\t\treturn $head\n${body(3)}\t\t$close\n');
	}

	/** `LAMBDA`'s body broken at its `&&`, its first operand at `depth` tabs and the rest one deeper. */
	private static function body(depth: Int): String {
		final at: String = [ for (_ in 0...depth) '\t' ].join('');
		return '${at}x > 0\n$at\t&& k.length > x\n$at\t&& k.charCodeAt(x) == 32\n$at\t&& k.charCodeAt(x) == 33\n';
	}

	/** A class holding one function whose body is `stmts`. */
	private static function fn(stmts: String): String {
		return 'class T {\n\tfunction f() {\n$stmts\t}\n}';
	}

	/** Tab indentation at `width` columns, with the key at 20 when `on`. */
	private static function config(width: Int, on: Bool): String {
		final sameLine: String = on ? ', "sameLine": {"ternaryTailGlueMaxLength": 20}' : '';
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": $width}$sameLine}';
	}

}
