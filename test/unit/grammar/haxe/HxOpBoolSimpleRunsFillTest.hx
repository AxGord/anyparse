package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Under an `opBoolChain` rule of type `fillSimpleRuns` a broken `&&` / `||` chain fills each run of consecutive simple
 * operands onto its lines, while a call, a parenthesised or indexed operand starts a line and ends it; in a chain mixing
 * `&&` with `||` every `||` starts a line.
 */
@:nullSafety(Strict)
class HxOpBoolSimpleRunsFillTest extends Test {

	private static final CALL: String = '!BoolExprShape.refusesNullNarrowingBoolCollapse(value, m.init, cond, d.shape)';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-FILL-SIMPLE-RUNS-NO-JOIN')
	public function testSimpleRunFillsAndCallTakesItsOwnLine(): Void {
		final out: String = write(
			'if (value != null && condSpan != null && valueSpan != null && initSpan != null && $CALL) {}', 'beforeLast'
		);
		final want: String = '\t\tif (value != null && condSpan != null && valueSpan != null && initSpan != null\n\t\t\t&& $CALL) {}';
		Assert.isTrue(out.indexOf(want) != -1, 'expected the simple run on one line and the call on its own in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-FILL-SIMPLE-RUNS-NO-JOIN')
	public function testOrChainInReturnFillsTheSameWay(): Void {
		final out: String = write(
			'return value != null || condSpan != null || valueSpan != null || initSpan != null || $CALL;', 'beforeLast'
		);
		final want: String = '\t\treturn value != null || condSpan != null || valueSpan != null || initSpan != null\n\t\t\t|| $CALL;';
		Assert.isTrue(out.indexOf(want) != -1, 'expected the || run on the return line in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-FILL-SIMPLE-RUNS-NO-JOIN')
	public function testAfterLastKeepsTheOperatorOnTheFilledLine(): Void {
		final out: String = write(
			'final r = value != null && condSpan != null && valueSpan != null && initSpan != null && $CALL;', 'afterLast'
		);
		final want: String = '\t\tfinal r = value != null && condSpan != null && valueSpan != null && initSpan != null &&\n\t\t\t$CALL;';
		Assert.isTrue(out.indexOf(want) != -1, 'expected the trailing && after the filled run in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-OPERAND-SIMPLE-ALWAYS')
	public function testComplexOperandsEndTheirLines(): Void {
		final parens: String = write(
			'if (aaaaaaaaaaaaaaaaaa != null && (cond ? a : b) && bbbbbbbbbbbbbbbbbbbb != null && cccccccccccccccc && !(x || y) '
			+ '&& !ddddddddddddddd && 1 < 2) {}',
			'beforeLast'
		);
		Assert.isTrue(
			parens.indexOf(
				'\t\tif (aaaaaaaaaaaaaaaaaa != null\n\t\t\t&& (cond ? a : b)\n\t\t\t&& bbbbbbbbbbbbbbbbbbbb != null && cccccccccccccccc\n'
				+ '\t\t\t&& !(x || y)\n\t\t\t&& !ddddddddddddddd && 1 < 2) {}'
			) != -1,
			'expected each parenthesised operand on its own line in:\n<$parens>'
		);
		final calls: String = write(
			'if (aaaaaaaaaaaaaaaaaa != null && arr[i] != null && bbbbbbbbbbbbbbbbbbbb != null && new Foo() '
			+ '!= null && cccccccccccccccc && !dddddddddd && s == "x") {}',
			'beforeLast'
		);
		Assert.isTrue(
			calls.indexOf(
				'\t\tif (aaaaaaaaaaaaaaaaaa != null\n\t\t\t&& arr[i] != null\n\t\t\t&& bbbbbbbbbbbbbbbbbbbb != null\n'
				+ '\t\t\t&& new Foo() != null\n\t\t\t&& cccccccccccccccc && !dddddddddd && s == "x") {}'
			) != -1,
			'expected the index and the constructor call on their own lines in:\n<$calls>'
		);
	}

	@:pin('control')
	@:killer('M-MIXED-BOOL-OR-JOINS')
	public function testMixedChainBreaksAtEveryOr(): Void {
		final out: String = write(
			'if (alpha != null && bravo != null && charlie != null && delta != null || echo != null && foxtrot != null && golf != null '
			+ '&& hotel != null && india) {}',
			'beforeLast'
		);
		final want: String = '\t\tif (alpha != null && bravo != null && charlie != null && delta != null\n'
			+ '\t\t\t|| echo != null && foxtrot != null && golf != null && hotel != null && india) {}';
		Assert.isTrue(out.indexOf(want) != -1, 'expected each && group on its own line in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-FILL-SIMPLE-RUNS-NO-JOIN')
	public function testFilledRunIsAFixedPoint(): Void {
		final once: String = write(
			'if (value != null && condSpan != null && valueSpan != null && initSpan != null && $CALL) {}', 'beforeLast'
		);
		Assert.isTrue(once.indexOf('valueSpan != null && initSpan != null\n') != -1, 'expected the filled run in:\n<$once>');
		Assert.equals(once, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(once), options('beforeLast')));
	}

	private static function write(statement: String, location: String): String {
		return HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('class C {\n\tfunction f():Void {\n\t\t$statement\n\t}\n}'), options(location)
		);
	}

	private static function options(location: String): HxModuleWriteOptions {
		return HxWriteOptionsKit.strictJson(
			'{"wrapping": {"maxLineLength": 120, "opBoolChain": {"defaultWrap": "noWrap", "rules": ['
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillSimpleRuns", "location": "$location"}]}}}'
		);
	}

}
