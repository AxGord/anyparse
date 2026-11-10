package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A typedef body of two or more fields goes one field per line under any config, an intersection operand included;
 * a one-field body, an anon type argument and an anon inside a function type follow the `anonType` cascade like an
 * inline type hint.
 */
final class HxTypedefBodyOnePerLineTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-TYPEDEF-BODY-ONE-PER-LINE')
	public function testTwoFieldsGoOnePerLine(): Void {
		Assert.equals('typedef T = {\n\ta:Int,\n\tb:Int\n}', HxWriteFixture.triviaWrite('typedef T = {a:Int, b:Int}', '{}'));
		Assert.equals(
			'typedef U = {\n\tvar a:Int;\n\tvar b:Int;\n}', HxWriteFixture.triviaWrite('typedef U = {var a:Int; var b:Int;}', '{}')
		);
	}

	@:pin('control')
	@:killer('M-INTERSECTION-OPERAND-NOT-TYPEDEF-BODY')
	public function testAnIntersectionOperandGoesOnePerLine(): Void {
		Assert.equals('typedef T = A & {\n\ta:Int,\n\tb:Int\n}', HxWriteFixture.triviaWrite('typedef T = A & {a:Int, b:Int}', '{}'));
	}

	@:pin('control')
	@:killer('M-TYPEDEF-NESTED-ANON-FORCED')
	public function testAnAnonTypeArgumentFollowsTheCascade(): Void {
		final src: String = 'typedef T = Array<{a:Int, b:Int}>';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

	@:pin('guard')
	public function testOneFieldFollowsTheCascade(): Void {
		Assert.equals('typedef T = {a:Int}', HxWriteFixture.triviaWrite('typedef T = {\n\ta:Int\n}', '{}'));
	}

	@:pin('control')
	@:killer('M-ARROW-TYPE-IN-TYPEDEF-BODY')
	public function testAnOldStyleFunctionTypeAnonFollowsTheCascade(): Void {
		for (src in ['typedef F = Int->{a:Int, b:Int}', 'typedef G = {x:Float, y:Float}->Void'])
			Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

	@:pin('control')
	@:killer('M-ARROW-FN-TYPE-IN-TYPEDEF-BODY')
	public function testAFunctionTypeParameterAnonFollowsTheCascade(): Void {
		for (src in [
			'typedef H = (a:{x:Int, y:Int}) -> Void',
			'typedef K = ({a:Int, b:Int}, Int) -> Void'
		]) Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

}
