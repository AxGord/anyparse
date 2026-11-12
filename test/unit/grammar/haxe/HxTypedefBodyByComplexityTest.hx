package unit.grammar.haxe;

import anyparse.format.BracePlacement;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A typedef body lays out by the `anonType` rules like any anon type: a simple body that fits stays on one line
 * whatever its field count, a structure extension counting as one element like a field, and a complex or too wide
 * body wraps by rule. Under a `Next` left curly the typedef body, an intersection operand included, goes one field
 * per line, while the anon parameter or return of a function type under the typedef is not its body.
 */
final class HxTypedefBodyByComplexityTest extends Test {

	private static final NEXT_CURLY: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.leftCurly = BracePlacement.Next;
		edited.objectLiteralLeftCurly = BracePlacement.Next;
		edited.anonTypeLeftCurly = BracePlacement.Next;
		edited.anonFunctionLeftCurly = BracePlacement.Next;
		edited.blockLeftCurly = BracePlacement.Next;
	});

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-TYPEDEF-BODY-FORCED-PER-LINE')
	public function testASimpleTwoFieldBodyStaysOnOneLine(): Void {
		for (src in [
			'typedef T = {a:Int, b:Int}',
			'typedef U = {var a:Int; var b:Int;}',
			'typedef V = A & {a:Int, b:Int}'
		]) Assert.equals(src, HxWriteFixture.triviaWrite(src, HaxeFormatConfigLoader.loadHxFormatJson('{}')));
	}

	@:pin('control')
	@:killer('M-TYPEDEF-BODY-FORCED-PER-LINE')
	public function testStructureExtensionsStayOnOneLine(): Void {
		Assert.equals(
			'typedef T = {> A, > B}', HxWriteFixture.triviaWrite('typedef T = {>A, >B}', HaxeFormatConfigLoader.loadHxFormatJson('{}'))
		);
		Assert.equals(
			'typedef U = {> A, var x:Int;}',
			HxWriteFixture.triviaWrite('typedef U = {>A, var x:Int;}', HaxeFormatConfigLoader.loadHxFormatJson('{}'))
		);
	}

	@:pin('control')
	@:killer('M-TYPEDEF-BODY-NEVER-WRAPS')
	public function testAWideBodyWrapsByRule(): Void {
		Assert.equals(
			'typedef L = {\n\ta:Int,\n\tb:Int,\n\tc:Int,\n\td:Int,\n\te:Int\n}',
			HxWriteFixture.triviaWrite('typedef L = {a:Int, b:Int, c:Int, d:Int, e:Int}', HaxeFormatConfigLoader.loadHxFormatJson('{}'))
		);
		Assert.equals(
			'typedef L = {\n\taVeryLongFieldNameNumberOne:SomeVeryLongTypeName<WithParameter>,\n'
			+ '\taVeryLongFieldNameNumberTwo:AnotherLongType,\n\taThirdField:YetAnotherLongTypeName,\n\tzzzzzzzzzzz:Int\n}',
			HxWriteFixture.triviaWrite(
				'typedef L = {aVeryLongFieldNameNumberOne:SomeVeryLongTypeName<WithParameter>, '
				+ 'aVeryLongFieldNameNumberTwo:AnotherLongType, aThirdField:YetAnotherLongTypeName, zzzzzzzzzzz:Int}',
				HaxeFormatConfigLoader.loadHxFormatJson('{}')
			)
		);
	}

	@:pin('control')
	@:killer('M-INTERSECTION-OPERAND-NOT-TYPEDEF-BODY')
	public function testAnIntersectionOperandIsTheBodyUnderANextCurly(): Void {
		Assert.equals('typedef T = A &\n{\n\ta:Int,\n\tb:Int\n}', HxWriteFixture.triviaWrite('typedef T = A & {a:Int, b:Int}', NEXT_CURLY));
	}

	@:pin('control')
	@:killer('M-ARROW-TYPE-IN-TYPEDEF-BODY')
	public function testAnOldStyleFunctionTypeAnonIsNotTheBody(): Void {
		for (src in ['typedef F = Int->{a:Int, b:Int}', 'typedef G = {x:Float, y:Float}->Void'])
			Assert.equals(src, HxWriteFixture.triviaWrite(src, NEXT_CURLY));
	}

	@:pin('control')
	@:killer('M-ARROW-FN-TYPE-IN-TYPEDEF-BODY')
	public function testAFunctionTypeParameterAnonIsNotTheBody(): Void {
		for (src in [
			'typedef H = (a:{x:Int, y:Int}) -> Void',
			'typedef K = ({a:Int, b:Int}, Int) -> Void'
		]) Assert.equals(src, HxWriteFixture.triviaWrite(src, NEXT_CURLY));
	}

}
