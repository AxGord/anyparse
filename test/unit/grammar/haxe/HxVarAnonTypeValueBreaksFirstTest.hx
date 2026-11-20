package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A `var` / `final` whose anonymous type hint fits by itself keeps the hint
 * whole when the statement overflows: the initializer breaks at its own seam.
 * The hint breaks only when it does not fit by itself.
 */
@:nullSafety(Strict)
class HxVarAnonTypeValueBreaksFirstTest extends Test {

	private static final HINT: String = 'final status:{ready:Bool, phase:String, seconds:Float} = ';
	private static final FIELDS: Array<String> = [
		'ready: _ready',
		'phase: _phase',
		'seconds: Math.round((Timer.stamp() - _phaseSince) * 10) / 10'
	];

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-GROUP-YIELDS-TO-REST')
	public function testFlatLiteralBreaksBeforeTheTypeThatFits(): Void {
		final out: String = write('$HINT{ ' + FIELDS.join(', ') + ' };');
		Assert.isTrue(out.indexOf('$HINT{\n') != -1, 'expected the type hint whole and the literal opened in:\n<$out>');
		Assert.isTrue(out.indexOf('final status:{\n') == -1, 'expected the type hint not to break in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-GROUP-YIELDS-TO-REST')
	public function testOnePerLineLiteralIsNotFoldedBackBehindABrokenType(): Void {
		final out: String = write('$HINT{\n\t\t\t' + FIELDS.join(',\n\t\t\t') + '\n\t\t};');
		Assert.isTrue(out.indexOf('$HINT{\n') != -1, 'expected the type hint whole and the literal opened in:\n<$out>');
		Assert.isTrue(out.indexOf('final status:{\n') == -1, 'expected the type hint not to break in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-GROUP-YIELDS-TO-REST')
	@:killer('M-FLAT-ASKER-FILL-FLAT')
	public function testCallValueBreaksBeforeTheTypeThatFits(): Void {
		final round: String = 'Math.round((Timer.stamp() - _phaseSince) * 10) / 10';
		final out: String = write('${HINT}someFunction(_ready, _phase, $round, $round);');
		Assert.isTrue(out.indexOf('final status:{\n') == -1, 'expected the type hint not to break in:\n<$out>');
		Assert.isTrue(out.indexOf('${HINT}someFunction(') != -1, 'expected the type hint whole before the call in:\n<$out>');
	}

	@:pin('guard')
	public function testTypeThatDoesNotFitByItselfStillBreaks(): Void {
		final out: String = write(
			'final x:{aaaaaaaaaaaaaaaaaaaaa:Bool, bbbbbbbbbbbbbbbbbbbbbbbbbbb:String, cccccccccccccccccccccc:Float, '
			+ 'dddddddddddddddddddddddd:Int, eeeeeeeeeeeeeeeeee:Int} = f();'
		);
		Assert.isTrue(out.indexOf('final x:{\n') != -1, 'expected the long type hint to break in:\n<$out>');
		Assert.isTrue(out.indexOf('} = f();') != -1, 'expected the value to stay on the closing line in:\n<$out>');
	}

	/** A value with no seam of its own cannot take the break, so the hint still opens for it. */
	@:pin('guard')
	public function testValueWithoutASeamStillBreaksTheType(): Void {
		final out: String = write(
			'${HINT}someVeryLongIdentifierNameThatCannotBreakAnywhereAtAllBecauseItIsOneTokenOnlyAndItIsReallyQuiteLong;'
		);
		Assert.isTrue(out.indexOf('final status:{\n') != -1, 'expected the type hint to break for a value with no seam in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-GROUP-YIELDS-TO-REST')
	public function testOperatorChainValueBreaksBeforeTheTypeThatFits(): Void {
		final round: String = 'Math.round((Timer.stamp() - _phaseSince) * 10) / 10';
		final out: String = write('$HINT$round + $round;');
		Assert.isTrue(
			out.indexOf('${HINT + round}\n') != -1, 'expected the type hint whole and the chain broken at its operator in:\n<$out>'
		);
	}

	/** The value-first layout is what the next rewrite reads, and it keeps it. */
	@:pin('control')
	@:killer('M-GROUP-YIELDS-TO-REST')
	public function testTheValueFirstLayoutIsAFixedPoint(): Void {
		final once: String = write('$HINT{ ' + FIELDS.join(', ') + ' };');
		final twice: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(once), options());
		Assert.isTrue(once.indexOf('$HINT{\n') != -1, 'expected the type hint whole in:\n<$once>');
		Assert.equals(once, twice);
	}

	/** A hint kept flat is flat as a whole: the anon type nested in it does not take the break the hint yielded. */
	@:pin('control')
	@:killer('M-YIELDED-HINT-NOT-WHOLE')
	public function testNestedAnonHintStaysWholeBeforeALiteral(): Void {
		final hint: String = 'final hit:{pos:{x:Int, y:Int}, name:String} = ';
		final once: String = write(
			'$hint{ pos: locate(_target, _origin), name: describeTheTarget(_target, _locale, _fallbackName, true) };'
		);
		Assert.isTrue(once.indexOf('$hint{\n') != -1, 'expected the nested hint on one line and the literal opened in:\n<$once>');
		Assert.equals(once, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(once), options()));
	}

	@:pin('control')
	@:killer('M-YIELDED-HINT-NOT-WHOLE')
	public function testNestedAnonHintStaysWholeBeforeACall(): Void {
		final hint: String = 'final box:{pos:{x:Int, y:Int}, name:String} = computeTheBox(';
		final out: String = write('${hint}_target, _origin, describeTheTarget(_target, _locale), _fallbackName, true);');
		Assert.isTrue(out.indexOf(hint) != -1, 'expected the nested hint on one line in:\n<$out>');
		Assert.isTrue(out.indexOf('_fallbackName,\n') != -1, 'expected the call to wrap its arguments in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-YIELDED-HINT-NOT-WHOLE')
	public function testFunctionTypedFieldHintStaysWhole(): Void {
		final hint: String = 'final fn:{ready:Bool, cb:(Int, String) -> Void} = makeHandler(';
		final out: String = write('${hint}_target, _origin, describeTheTarget(_target, _locale), _fallbackName, tr);');
		Assert.isTrue(out.indexOf(hint) != -1, 'expected the function-typed hint on one line in:\n<$out>');
		Assert.isTrue(out.indexOf('_fallbackName,\n') != -1, 'expected the call to wrap its arguments in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-YIELDED-HINT-NOT-WHOLE')
	public function testAnonInsideTypeParametersHintStaysWhole(): Void {
		final hint: String = 'final arr:{items:Array<{id:Int, tag:String}>, n:Int} = collectAll(';
		final out: String = write('${hint}_target, _origin, describeTheTarget(_target, _locale), _fallbackN, 1);');
		Assert.isTrue(out.indexOf(hint) != -1, 'expected the hint with an anon type argument on one line in:\n<$out>');
		Assert.isTrue(out.indexOf('_fallbackN,\n') != -1, 'expected the call to wrap its arguments in:\n<$out>');
	}

	private static function write(statement: String): String {
		return HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('class C {\n\tfunction f():Void {\n\t\t$statement\n\t}\n}'), options()
		);
	}

	private static function options(): HxModuleWriteOptions {
		final fitPair: String = '{"defaultWrap": "ignore", "rules": ['
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
			+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]}';
		return HxWriteOptionsKit.strictJson(
			HxWriteFixture.listsKeepSource('{"wrapping": {"maxLineLength": 140, "anonType": $fitPair, "objectLiteral": $fitPair}}')
		);
	}

}
