package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `sameLine.ternaryTailBlockMaxThenLength` — a ternary whose else branch ends in the block or collection that is its
 * only multi-line part keeps `cond ? then : f(a -> {` on one line when the then branch is no wider than the key, so
 * the block breaks and the ternary does not. Anything else keeps the `?` / `:` ladder: a wider then branch, an unset
 * key, a block in the then branch, an else prefix that breaks before the block, a head line past the limit.
 */
@:nullSafety(Strict)
final class HxTernaryTailBlockHugTest extends Test {

	/** A sole call argument ending in an object-bodied lambda, and a call ending in a function body. */
	private static final HUG_SRC: String = 'class T {\n\tfunction f() {\n\t\tcallback(ready ? [] : updates.map(u -> {id: u.id, name: '
		+ 'u.name}));\n\t\tfinal y = ready ? null : run(function() {\n\t\t\ttrace(1);\n\t\t});\n\t}\n}';

	/** Both hug their tail block; the sole-argument call closes `}))` on one line. */
	private static final HUG: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tcallback(ready ? [] : updates.map(u -> {\n\t\t\tid: u.id,\n\t\t\tname: u.name\n\t\t}));\n'
		+ '\t\tfinal y = ready ? null : run(function() {\n\t\t\ttrace(1);\n\t\t});\n\t}\n}';

	/** The same ternaries on the ladder. */
	private static final HUG_LADDER: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tcallback(ready\n\t\t\t? []\n\t\t\t: updates.map(u -> {\n\t\t\t\tid: u.id,\n\t\t\t\tname: u.name\n\t\t\t}));\n'
		+ '\t\tfinal y = ready\n\t\t\t? null\n\t\t\t: run(function() {\n\t\t\t\ttrace(1);\n\t\t\t});\n\t}\n}';

	/** A then branch wider than the key. */
	private static final LONG_SRC: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tfinal z = ready ? someMuchLongerThenBranchValue : updates.map(u -> {id: u.id, name: u.name});\n\t}\n}';

	private static final LONG_LADDER: String = 'class T {\n\tfunction f() {\n\t\tfinal z = ready\n\t\t\t? someMuchLongerThenBranchValue\n'
		+ '\t\t\t: updates.map(u -> {\n\t\t\t\tid: u.id,\n\t\t\t\tname: u.name\n\t\t\t});\n\t}\n}';

	/** The mirrored case: the THEN branch ends in the block. */
	private static final MIRROR_SRC: String =
		'class T {\n\tfunction f() {\n\t\tfinal m = ready ? updates.map(u -> {id: u.id, name: u.name}) : x;\n\t}\n}';

	private static final MIRROR_LADDER: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tfinal m = ready\n\t\t\t? updates.map(u -> {\n\t\t\t\tid: u.id,\n\t\t\t\tname: u.name\n\t\t\t})\n\t\t\t: x;\n\t}\n}';

	/** An else prefix whose call puts its arguments one per line (`ARGS_ON`). */
	private static final PREFIX_SRC: String =
		'class T {\n\tfunction f() {\n\t\tfinal q = ready ? [] : someFunc(one, two, three, u -> {id: u.id, name: u.name});\n\t}\n}';

	private static final PREFIX_LADDER: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tfinal q = ready\n\t\t\t? []\n\t\t\t: someFunc(\n\t\t\t\tone,\n\t\t\t\ttwo,\n\t\t\t\tthree,\n'
		+ '\t\t\t\tu -> {\n\t\t\t\t\tid: u.id,\n\t\t\t\t\tname: u.name\n\t\t\t\t}\n\t\t\t);\n\t}\n}';

	/** A block in an argument ahead of the tail. */
	private static final BLOCK_AHEAD_SRC: String =
		'class T {\n\tfunction f() {\n\t\tfinal b = ready ? [] : both(function() {trace(1);}, u -> {id: u.id, name: u.name});\n\t}\n}';

	private static final BLOCK_AHEAD_LADDER: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tfinal b = ready\n\t\t\t? []\n\t\t\t: both(function() {\n\t\t\t\ttrace(1);\n'
		+ '\t\t\t}, u -> {\n\t\t\t\tid: u.id,\n\t\t\t\tname: u.name\n\t\t\t});\n\t}\n}';

	/** A flat collection ahead of the tail does not stop the hug. */
	private static final FLAT_AHEAD_SRC: String =
		'class T {\n\tfunction f() {\n\t\tfinal s = ready ? [] : someFunc([one], u -> {id: u.id, name: u.name});\n\t}\n}';

	private static final FLAT_AHEAD_HUG: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tfinal s = ready ? [] : someFunc([one], u -> {\n\t\t\tid: u.id,\n\t\t\tname: u.name\n\t\t});\n\t}\n}';

	/** The key set. */
	private static final ON: String = config('', '"ternaryTailBlockMaxThenLength": 20');

	/** The key unset. */
	private static final OFF: String = config('', '');

	/** The key set, with a call of four or more arguments laid one per line. */
	private static final ARGS_ON: String = config(
		'"callParameter": {"rules": [{"conditions": [{"cond": "itemCount >= n", "value": 4}], "type": "onePerLine"}]}, ',
		'"ternaryTailBlockMaxThenLength": 20'
	);

	/** Array literals ending a call: the sole argument of a method call and of a `new`. */
	private static final ARRAY_SRC: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tfinal a = ready ? [] : xs.concat([one, two]);\n\t\tfinal c = ready ? [] : new Foo([one, two]);\n\t}\n}';

	private static final ARRAY_HUG: String = 'class T {\n\tfunction f() {\n\t\tfinal a = ready ? [] : xs.concat([\n\t\t\tone,\n\t\t\ttwo\n'
		+ '\t\t]);\n\t\tfinal c = ready ? [] : new Foo([\n\t\t\tone,\n\t\t\ttwo\n\t\t]);\n\t}\n}';

	/** A function-body else branch under a then branch wider than the key. */
	private static final INLINE_SRC: String =
		'class T {\n\tfunction f() {\n\t\tfinal z = ready ? someMuchLongerThenBranchValue : run(function() {trace(1);});\n\t}\n}';

	/** `ternaryMultilineBranch: inline` keeps it glued whatever the then width. */
	private static final INLINE_HUG: String = 'class T {\n\tfunction f() {\n'
		+ '\t\tfinal z = ready ? someMuchLongerThenBranchValue : run(function() {\n\t\t\ttrace(1);\n\t\t});\n\t}\n}';

	/** The key set, with every array literal laid one item per line. */
	private static final ARRAYS_ON: String = config(
		'"arrayWrap": {"rules": [{"conditions": [], "type": "onePerLine"}]}, ', '"ternaryTailBlockMaxThenLength": 20'
	);

	/** The key set beside `wrapping.ternaryMultilineBranch: inline`. */
	private static final INLINE_ON: String = config('"ternaryMultilineBranch": "inline", ', '"ternaryTailBlockMaxThenLength": 20');

	public function new(): Void {
		super();
	}

	public function testTheDefaultIsOff(): Void {
		Assert.equals(0, HaxeFormat.instance.defaultWriteOptions.ternaryTailBlockMaxThenLength, 'hxq keeps the ladder it always wrote');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-HUG-NONE')
	public function testAShortThenHugsTheTailBlock(): Void {
		Assert.equals(HUG, HxWriteFixture.triviaWrite(HUG_SRC, ON));
		Assert.equals(HUG, HxWriteFixture.triviaWrite(HUG_LADDER, ON), 'the source layout is not read');
		Assert.equals(HUG, HxWriteFixture.plainWrite(HUG_SRC, ON), 'the plain writer hugs too');
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-HUG-NO-THEN-CAP')
	public function testALongThenKeepsTheLadder(): Void {
		Assert.equals(LONG_LADDER, HxWriteFixture.triviaWrite(LONG_SRC, ON));
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-HUG-OPTION-IGNORED')
	public function testAnUnsetKeyKeepsTheLadder(): Void {
		Assert.equals(HUG_LADDER, HxWriteFixture.triviaWrite(HUG_SRC, OFF));
		Assert.equals(HUG_LADDER, HxWriteFixture.triviaWrite(HUG, OFF));
	}

	@:pin('guard')
	public function testTheMirroredCaseIsUntouched(): Void {
		Assert.equals(MIRROR_LADDER, HxWriteFixture.triviaWrite(MIRROR_SRC, ON));
		Assert.equals(MIRROR_LADDER, HxWriteFixture.triviaWrite(MIRROR_SRC, OFF));
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-HUG-ANY-TAIL-CLOSE')
	public function testAMultiLinePrefixKeepsTheLadder(): Void {
		Assert.equals(PREFIX_LADDER, HxWriteFixture.triviaWrite(PREFIX_SRC, ARGS_ON));
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-HUG-BLOCK-AHEAD')
	public function testABlockAheadOfTheTailKeepsTheLadder(): Void {
		Assert.equals(BLOCK_AHEAD_LADDER, HxWriteFixture.triviaWrite(BLOCK_AHEAD_SRC, ARGS_ON));
		Assert.equals(FLAT_AHEAD_HUG, HxWriteFixture.triviaWrite(FLAT_AHEAD_SRC, ARGS_ON));
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-HUG-NO-WIDTH-GUARD')
	public function testAHeadPastTheLimitKeepsTheLadder(): Void {
		final fits: String = ''.lpad('c', 100);
		Assert.equals(
			'class T {\n\tfunction f() {\n\t\tfinal w = $fits ? [] : xs.map(u -> {\n\t\t\tid: u.id\n\t\t});\n\t}\n}',
			HxWriteFixture.triviaWrite(widthSource(fits), ON)
		);
		final over: String = ''.lpad('c', 110);
		Assert.equals(
			'class T {\n\tfunction f() {\n\t\tfinal w = $over\n\t\t\t? []\n\t\t\t: xs.map(u -> {\n\t\t\t\tid: u.id\n\t\t\t});\n\t}\n}',
			HxWriteFixture.triviaWrite(widthSource(over), ON)
		);
	}

	@:pin('control')
	@:killer('M-TERNARY-TAIL-HUG-ARRAY-CLOSE')
	public function testAnArrayTailHugs(): Void {
		Assert.equals(ARRAY_HUG, HxWriteFixture.triviaWrite(ARRAY_SRC, ARRAYS_ON));
	}

	@:pin('control')
	@:killer('M-TERNARY-MLB-INLINE-NONE')
	public function testTheInlineLayoutWinsOverTheKey(): Void {
		Assert.equals(INLINE_HUG, HxWriteFixture.triviaWrite(INLINE_SRC, INLINE_ON));
	}

	/** A `final w = <cond> ? [] : xs.map(u -> {…})` ternary; its head line is `cond.length + 39` columns at a four-column tab. */
	private static function widthSource(cond: String): String {
		return 'class T {\n\tfunction f() {\n\t\tfinal w = $cond ? [] : xs.map(u -> {id: u.id});\n\t}\n}';
	}

	/** The shared config: `extraWrapping` (a comma-terminated JSON fragment) spliced into `wrapping`, `sameLine` as its body. */
	private static function config(extraWrapping: String, sameLine: String): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {$extraWrapping"maxLineLength": 140, '
			+ '"objectLiteral": {"rules": [{"conditions": [], "type": "onePerLine"}]}}, "sameLine": {$sameLine}}';
	}

}
