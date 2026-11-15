package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A lambda block's value tail `if` / `else` whose branches are plain values (a literal, a name, a field read) stays on one
 * line when it fits, an `else if` chain of them too; a chain with a call branch still ladders.
 */
@:nullSafety(Strict)
final class HxValueTailIfInlineTest extends Test {

	private static final DEFAULTS: String = '{"indentation": {"character": "tab", "tabWidth": 4}}';
	private static final INLINE_SOURCE: Array<String> = [
		'var w = () -> { if (c) 1 else 2; };',
		'var x = () -> { if (c) 1 else if (d) a.b else "s"; };'
	];
	private static final INLINE_KEPT: Array<String> = [
		'var w = () -> {',
		'\tif (c) 1 else 2;',
		'};',
		'var x = () -> {',
		'\tif (c) 1 else if (d) a.b else "s";',
		'};'
	];
	private static final CALL_SOURCE: Array<String> = ['var v = () -> { if (c) a.b() else 2; };'];
	private static final CALL_LADDER: Array<String> = ['var v = () -> {', '\tif (c)', '\t\ta.b()', '\telse', '\t\t2;', '};'];
	private static final MIXED_SOURCE: Array<String> = ['var z = () -> { if (c) a() else if (d) 1 else 2; };'];
	private static final MIXED_LADDER: Array<String> = [
		'var z = () -> {',
		'\tif (c)',
		'\t\ta()',
		'\telse if (d)',
		'\t\t1',
		'\telse',
		'\t\t2;',
		'};'
	];

	public function new(): Void {
		super();
	}

	/** A plain-value tail chain keeps its one line, and that line is a fixed point. */
	@:pin('control')
	@:killer('M-PLAIN-VALUE-CHAIN-NEVER')
	public function testValueTailIfStaysInline(): Void {
		Assert.equals(fn(INLINE_KEPT), write(INLINE_SOURCE));
		Assert.equals(fn(INLINE_KEPT), write(INLINE_KEPT));
	}

	/** A branch that calls is no plain value: the chain ladders. */
	@:pin('control')
	@:killer('M-PLAIN-VALUE-ANY-CTOR')
	public function testCallBranchStillLadders(): Void {
		Assert.equals(fn(CALL_LADDER), write(CALL_SOURCE));
	}

	/** An `else if` link of plain values follows a head that calls: the whole chain ladders. */
	@:pin('control')
	@:killer('M-PLAIN-VALUE-LINK-OWN-VERDICT')
	public function testMixedChainLaddersWhole(): Void {
		Assert.equals(fn(MIXED_LADDER), write(MIXED_SOURCE));
	}

	/** `lines` as the body of `function f()` in `class C`. */
	private static function fn(lines: Array<String>): String {
		return 'class C {\n\tfunction f() {\n' + lines.map(line -> '\t\t$line').join('\n') + '\n\t}\n}';
	}

	private static function write(lines: Array<String>): String {
		return HxWriteFixture.triviaWrite(fn(lines), DEFAULTS);
	}

}
