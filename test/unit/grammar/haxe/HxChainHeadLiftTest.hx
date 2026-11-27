package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import utest.Assert;
import utest.Test;

/**
 * `sameLine.chainHeadLift` — an `&&` / `||` chain whose last operand opens a multi-line construct, too wide for its own
 * continuation line, keeps its earlier operands on the head line (`return k != null && xs.exists(x ->`), in a `return`,
 * an initializer and an `if` condition alike. Each gate failing alone keeps the chain's own break: a last operand that fits
 * its line, a tail after the construct, a bare paren last operand, a block operand whose head does not fit flat, a chain
 * inside an explicit paren. An unset key is untouched.
 */
@:nullSafety(Strict)
final class HxChainHeadLiftTest extends Test {

	/** A lambda whose body does not fit one line. */
	private static final LAMBDA: String = 'x -> x > 0 && k.length > x && k.charCodeAt(x) == 32 && k.charCodeAt(x) == 33';

	/** The key set, at a width of 80. */
	private static final ON: String = config(80, true, false);

	/** The key unset, at a width of 80. */
	private static final OFF: String = config(80, false, false);

	/** The key set, at a width of 140 with an `&&` / `||` chain filling its simple runs, operator first. */
	private static final ON_RUNS: String = config(140, true, true);

	/** `ON_RUNS` with the key unset. */
	private static final OFF_RUNS: String = config(140, false, true);

	/** The key beside `sameLine.ternaryTailGlueMaxLength`: a short ternary tail stays on the lifted chain's closing line. */
	private static final WITH_TAIL_GLUE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 80}, '
		+ '"sameLine": {"ternaryTailGlueMaxLength": 20, "chainHeadLift": true}}';

	public function new(): Void {
		super();
	}

	public function testTheDefaultIsOff(): Void {
		Assert.isFalse(HaxeFormat.instance.defaultWriteOptions.chainHeadLift, 'hxq keeps the ladder it always wrote');
	}

	@:pin('control')
	@:killer('M-CHAIN-HEAD-LIFT-NONE')
	public function testAChainKeepsItsHeadOnTheFirstLine(): Void {
		final chain: String = lifted('return k != null && xs.exists(x ->', ');');
		Assert.equals(chain, write('return k != null && xs.exists($LAMBDA);', ON));
		Assert.equals(chain, HxWriteFixture.triviaWrite(chain, ON), 'the lifted layout is stable');
		Assert.equals(
			chain, HxWriteFixture.plainWrite(fn('\t\treturn k != null && xs.exists($LAMBDA);\n'), ON), 'the plain writer lifts too'
		);
		Assert.equals(lifted('return k == null || xs.exists(x ->', ');'), write('return k == null || xs.exists($LAMBDA);', ON));
		Assert.equals(lifted('final ok = k != null && xs.exists(x ->', ');'), write('final ok = k != null && xs.exists($LAMBDA);', ON));
		Assert.equals(
			fn('\t\tif (k != null && xs.exists(x ->\n${body(3)}\t\t))\n\t\t\treturn k;\n'),
			write('if (k != null && xs.exists($LAMBDA)) return k;', ON)
		);
	}

	@:pin('control')
	@:killer('M-CHAIN-HEAD-LIFT-NO-FIT')
	public function testALastOperandFittingItsLineKeepsTheBreak(): Void {
		final stmt: String = 'return k != null && xs.exists(x -> x > 0 && k.length > x && k.charCodeAt(x) == 32);';
		Assert.equals(
			fn('\t\treturn k != null\n\t\t\t&& xs.exists(x -> x > 0 && k.length > x && k.charCodeAt(x) == 32);\n'), write(stmt, ON)
		);
	}

	@:pin('control')
	@:killer('M-CHAIN-HEAD-LIFT-NO-CLOSE-LINE')
	public function testATailAfterTheConstructKeepsTheBreak(): Void {
		assertUnchanged('return k != null && xs.filter($LAMBDA).length == n;', ON, OFF);
	}

	@:pin('control')
	@:killer('M-CHAIN-HEAD-LIFT-PAREN-TAIL')
	public function testABareParenLastOperandKeepsItsLayout(): Void {
		assertUnchanged(
			'return child.kind == Star && (child.annotations[KEY] != true && (child.readMetaString(\':kw\') '
			+ '== null && (child.readMetaString(\':lead\') == null && (child == parent.children[0] '
			+ '&& child.fmtHasFlag(\'beforeNewlineSlotFirst\')))));',
			ON_RUNS, OFF_RUNS
		);
	}

	@:pin('control')
	@:killer('M-CHAIN-HEAD-LIFT-HARDLINE-FLAT')
	public function testABlockOperandWhoseHeadDoesNotFitKeepsTheBreak(): Void {
		assertUnchanged(
			'return g.lock == cover && given <= pos && runs(id, valuation, g.edge) && runsBefore(g.edge, valuation, pos) && '
			+ '!(holdsIn[id] ?? []).exists(a -> {trace(a); return a.lock == cover;});',
			ON_RUNS, OFF_RUNS
		);
	}

	@:pin('control')
	@:killer('M-CHAIN-HEAD-LIFT-IN-PAREN')
	public function testAChainInAParenKeepsItsLayout(): Void {
		assertUnchanged('final v = (k != null && xs.exists($LAMBDA));', ON, OFF);
		assertUnchanged('final w = cc && (k != null && xs.exists($LAMBDA));', ON, OFF);
	}

	@:pin('control')
	@:killer('M-CHAIN-HEAD-LIFT-TAIL-GLUE')
	public function testBothKeysKeepTheTernaryTailOnTheCloser(): Void {
		final glued: String = lifted('return k != null && xs.exists(x ->', ') ? k : null;');
		Assert.equals(glued, write('return k != null && xs.exists($LAMBDA) ? k : null;', WITH_TAIL_GLUE));
		Assert.equals(glued, HxWriteFixture.triviaWrite(glued, WITH_TAIL_GLUE), 'the glued layout is stable');
	}

	@:pin('guard')
	public function testAnUnsetKeyKeepsTheLadder(): Void {
		final ladder: String = fn('\t\treturn k != null\n\t\t\t&& xs.exists(x ->\n${body(4)}\t\t\t);\n');
		Assert.equals(ladder, write('return k != null && xs.exists($LAMBDA);', OFF));
		Assert.equals(
			ladder, HxWriteFixture.triviaWrite(lifted('return k != null && xs.exists(x ->', ');'), OFF), 'the source layout is not read'
		);
	}

	/** `stmt` under `on` and `off` alike: the key leaves it as the plain writer lays it out. */
	private static function assertUnchanged(stmt: String, on: String, off: String): Void {
		Assert.equals(write(stmt, off), write(stmt, on), stmt);
	}

	/** `stmt`, one statement, written in a function body under `config`. */
	private static function write(stmt: String, config: String): String {
		return HxWriteFixture.triviaWrite(fn('\t\t$stmt\n'), config);
	}

	/** The lifted statement: `head` on its first line, the lambda body one level in, `close` at the statement's indent. */
	private static function lifted(head: String, close: String): String {
		return fn('\t\t$head\n${body(3)}\t\t$close\n');
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

	private static function config(width: Int, on: Bool, runs: Bool): String {
		final sameLine: String = on ? ', "sameLine": {"chainHeadLift": true}' : '';
		final opBool: String = runs
			? ', "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], '
				+ '"type": "fillSimpleRuns", "location": "beforeLast"}]}'
			: '';
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": $width$opBool}$sameLine}';
	}

}
