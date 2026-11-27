package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A `var` / `final` / field / parameter whose function-type hint fits by itself keeps the hint whole when
 * the statement overflows: the initializer breaks at its own seam. The hint's parameter list opens only
 * when the hint does not fit by itself.
 */
@:nullSafety(Strict)
class HxFnTypeHintValueBreaksFirstTest extends Test {

	private static final HINT: String = '(String, Int) -> Bool';
	private static final LAMBDA: String =
		'(name, bindingFrom) -> isProven(name, bindingFrom, entry.file, entry.source, root, valueSeams, resolveSymbols(), plugin, proven)';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-YIELDS-TO-REST-CONCAT-OFF')
	public function testFinalBreaksAfterTheLambdaArrowUnderTheProjectConfig(): Void {
		final out: String = write('final proofOf: $HINT = $LAMBDA;', projectOptions());
		Assert.isTrue(
			out.indexOf('final proofOf: $HINT = (name, bindingFrom) ->\n') != -1,
			'expected the hint whole and the break after the arrow in:\n<$out>'
		);
	}

	@:pin('control')
	@:killer('M-YIELDS-TO-REST-CONCAT-OFF')
	public function testFinalBreaksAfterTheLambdaArrowUnderThePlainConfig(): Void {
		final out: String = write('final proofOf: $HINT = $LAMBDA;', HxWriteFixture.listsKeepSourceOptions());
		Assert.isTrue(
			out.indexOf('$HINT = (name, bindingFrom) ->\n') != -1, 'expected the hint whole and the break after the arrow in:\n<$out>'
		);
	}

	@:pin('control')
	@:killer('M-YIELDS-TO-REST-CONCAT-OFF')
	public function testVarBreaksAfterTheLambdaArrow(): Void {
		final out: String = write('var proofOf: $HINT = $LAMBDA;', projectOptions());
		Assert.isTrue(out.indexOf('var proofOf: $HINT = (name, bindingFrom) ->\n') != -1, 'expected the hint whole in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-YIELDS-TO-REST-CONCAT-OFF')
	public function testCallValueBreaksItsArgumentsBeforeTheHint(): Void {
		final out: String = write(
			'final b: $HINT = foo(name, bindingFrom, entry.file, entry.source, root, valueSeams, resolveSymbols(), plugin, proven, more);',
			projectOptions()
		);
		Assert.isTrue(out.indexOf('final b: $HINT = foo(name, ') != -1, 'expected the hint whole before the call in:\n<$out>');
		Assert.isTrue(out.indexOf('proven, more') != -1 && out.indexOf(',\n') != -1, 'expected the call to wrap its arguments in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-YIELDS-TO-REST-CONCAT-OFF')
	public function testParameterHintStaysWhole(): Void {
		final out: String = HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('class C {\n\tfunction g(cb: $HINT = $LAMBDA) {}\n}'), projectOptions()
		);
		Assert.isTrue(out.indexOf('function g(cb: $HINT = (name, bindingFrom) ->\n') != -1, 'expected the hint whole in:\n<$out>');
	}

	@:pin('control')
	@:killer('M-YIELDS-TO-REST-CONCAT-OFF')
	public function testClassFieldBreaksAfterTheLambdaArrow(): Void {
		final out: String = HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('class C {\n\tfinal proofOf: $HINT = $LAMBDA;\n}'), projectOptions()
		);
		Assert.isTrue(out.indexOf('final proofOf: $HINT = (name, bindingFrom) ->\n') != -1, 'expected the hint whole in:\n<$out>');
	}

	@:pin('guard')
	public function testTheValueFirstLayoutIsAFixedPoint(): Void {
		final once: String = write('final proofOf: $HINT = $LAMBDA;', projectOptions());
		Assert.equals(once, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(once), projectOptions()));
	}

	@:pin('guard')
	public function testHintThatDoesNotFitByItselfStillOpens(): Void {
		final params: String = [ for (_ in 0...30) 'Int' ].join(', ');
		final out: String = write('final c: ($params) -> Bool = x;', projectOptions());
		Assert.isTrue(out.indexOf(',\n') != -1, 'expected the long hint to break inside its parameter list in:\n<$out>');
		Assert.isTrue(out.indexOf(') -> Bool = x;') != -1, 'expected the value on the closing line in:\n<$out>');
	}

	private static function write(statement: String, options: HxModuleWriteOptions): String {
		return HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse('class C {\n\tfunction f():Void {\n\t\t$statement\n\t}\n}'), options
		);
	}

	private static function projectOptions(): HxModuleWriteOptions {
		return HxWriteOptionsKit.strictJson(
			HxWriteFixture.listsKeepSource('{"whitespace": {"typeHintColonPolicy": "after"}, "wrapping": {"maxLineLength": 140}}')
		);
	}

}
