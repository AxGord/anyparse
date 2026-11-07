package unit.grammar.haxe;

import anyparse.format.TrailingCommaPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/**
 * `wrapping.trailingComma: split` — the trailing comma as the author's only lever on list layout. A list whose
 * source writes a separator after its last element is laid out one element per line however short it is; a
 * list without one is laid out by policy and width exactly as under the default `keep`, which stays byte-inert.
 */
@:nullSafety(Strict)
class HxTrailingCommaSplitTest extends Test {

	private static final SPLIT: String = '{"wrapping":{"trailingComma":"split"}}';
	private static final KEEP: String = '{}';
	private static final LITERALS: String =
		'class C {\n\tfunction f() {\n\t\tvar a = [1, 2,];\n\t\tvar o = {x: 1, y: 2,};\n\t\tvar n = new T(a, b,);\n\t}\n}';
	private static final CALL: String = 'class C {\n\tfunction f() {\n\t\tg(a, b,);\n\t}\n}';
	private static final NO_TRAIL: String =
		'class C {\n\tfunction f() {\n\t\tvar a = [1, 2];\n\t\tvar o = {x: 1, y: 2};\n\t\tvar n = new T(a, b);\n\t\tg(a, b);\n\t}\n}';
	private static final LONG_ARRAY: String = 'class C {\n\tfunction f() {\n\t\tvar a = [1111111111, 2222222222, 3333333333, 4444444444, '
		+ '5555555555, 6666666666, 7777777777, 8888888888, 9999999999, 1010101010, 1212121212];\n\t}\n}';
	private static final LONG_OBJECT: String = 'class C {\n\tfunction f() {\n\t\tvar o = {alphaAlpha: 1111111111, betaBeta: 2222222222, '
		+ 'gammaGamma: 3333333333, deltaDelta: 4444444444, epsilonEpsilon: 5555555555, zetaZeta: 66666};\n\t}\n}';
	private static final LONG_CALL: String = 'class C {\n\tfunction f() {\n\t\tsomeFunction(1111111111, 2222222222, 3333333333, '
		+ '4444444444, 5555555555, 6666666666, 7777777777, 8888888888, 9999999999, 1010101010, 1212121212, 1313131313);\n\t}\n}';

	@:pin('control')
	@:killer('HX-TRAILING-COMMA-SPLIT-UNMAPPED')
	public function testConfigSplitParsed(): Void {
		Assert.equals(TrailingCommaPolicy.Split, HaxeFormatConfigLoader.loadHxFormatJson(SPLIT).trailingComma);
	}

	/** Array literal, object literal and `new` arguments: one element per line, the source comma kept. */
	@:pin('control')
	@:killer('M-TRAILING-COMMA-SPLIT-SEP-STAR-OFF')
	public function testSplitBreaksLiteralsWithATrailingComma(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar a = [\n\t\t\t1,\n\t\t\t2,\n\t\t];\n'
			+ '\t\tvar o = {\n\t\t\tx: 1,\n\t\t\ty: 2,\n\t\t};\n\t\tvar n = new T(\n\t\t\ta,\n\t\t\tb,\n\t\t);\n\t}\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(LITERALS, SPLIT));
	}

	/** Call arguments take the postfix-Star path, not the separated-list one, and split the same way. */
	@:pin('control')
	@:killer('M-TRAILING-COMMA-SPLIT-CALL-OFF')
	public function testSplitBreaksCallArgumentsWithATrailingComma(): Void {
		final expected: String = 'class C {\n\tfunction f() {\n\t\tg(\n\t\t\ta,\n\t\t\tb,\n\t\t);\n\t}\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(CALL, SPLIT));
	}

	@:pin('guard')
	public function testSplitLeavesListsWithoutATrailingCommaToPolicy(): Void {
		Assert.equals(NO_TRAIL, HxWriteFixture.triviaWrite(NO_TRAIL, SPLIT));
	}

	@:pin('guard')
	public function testKeepLeavesShortTrailingCommaListsFlat(): Void {
		Assert.equals(LITERALS, HxWriteFixture.triviaWrite(LITERALS, KEEP));
		Assert.equals(CALL, HxWriteFixture.triviaWrite(CALL, KEEP));
	}

	@:pin('guard')
	public function testSplitIsIdempotent(): Void {
		for (source in [LITERALS, CALL]) {
			final once: String = HxWriteFixture.triviaWrite(source, SPLIT);
			Assert.equals(once, HxWriteFixture.triviaWrite(once, SPLIT));
		}
	}

	/**
	 * An add-knob under `split` writes its comma only in the one-per-line shape: an array that breaks by width into a
	 * filled layout carries none, so the next pass does not read a comma the writer added as the lever.
	 */
	@:pin('control')
	@:killer('M-TRAILING-COMMA-SPLIT-SEP-KNOB-ANY-MODE')
	public function testSplitArrayKnobReachesTheFixedPointInOneWrite(): Void {
		final once: String = HxWriteFixture.triviaWrite(LONG_ARRAY, splitWithKnob('arrayLiteralDefault'));
		Assert.equals(once, HxWriteFixture.triviaWrite(once, splitWithKnob('arrayLiteralDefault')));
	}

	/** The call-argument knob on the postfix-Star path holds the same contract. */
	@:pin('control')
	@:killer('M-TRAILING-COMMA-SPLIT-CALL-KNOB-ANY-MODE')
	public function testSplitCallKnobReachesTheFixedPointInOneWrite(): Void {
		final once: String = HxWriteFixture.triviaWrite(LONG_CALL, splitWithKnob('callArgumentDefault'));
		Assert.equals(once, HxWriteFixture.triviaWrite(once, splitWithKnob('callArgumentDefault')));
	}

	/** An object literal's cascade breaks only into one-per-line, where its knob comma stays. */
	@:pin('guard')
	public function testSplitObjectKnobReachesTheFixedPointInOneWrite(): Void {
		final once: String = HxWriteFixture.triviaWrite(LONG_OBJECT, splitWithKnob('objectLiteralDefault'));
		Assert.equals(once, HxWriteFixture.triviaWrite(once, splitWithKnob('objectLiteralDefault')));
	}

	private static function splitWithKnob(knob: String): String {
		return '{"wrapping":{"trailingComma":"split"},"trailingCommas":{"$knob":"yes"}}';
	}

}
