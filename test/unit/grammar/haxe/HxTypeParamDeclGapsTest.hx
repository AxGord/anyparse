package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * Declare-site type-parameter forms Haxe accepts parse, format and reach the writer's fixed point in one pass:
 * metadata on a parameter (`<@:const N>`) and a comment after the constraint colon or the default's `=`
 * (`<T:/*k*\/ Foo = /*d*\/ Bar>`). The plain forms `T:Foo`, `T = D` and `T:Foo = D` keep their bytes.
 */
@:nullSafety(Strict)
final class HxTypeParamDeclGapsTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-META-UNDECLARED')
	public function testMetadataOnATypeParameter(): Void {
		assertCanonical('class C<T:Foo = Bar, @:const N> {}\n');
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-META-UNDECLARED')
	public function testAMetadataRunOnAFunctionTypeParameter(): Void {
		assertCanonical('class C {\n\tfunction f<@:const N, @:a(1) @:b T:Foo>():Void {}\n}\n');
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-CONSTRAINT-AFTER-LEAD-OFF', 'M-AFTER-LEAD-MANDATORY-ONLY', 'M-OPTIONAL-AFTER-LEAD-UNPARSED',
		'M-OPTIONAL-AFTER-LEAD-UNWRITTEN')
	public function testCommentAfterTheConstraintColon(): Void {
		final written: Null<String> = roundTrip('class D<T:/*k*/Foo> {}\n');
		Assert.equals('class D<T:/*k*/ Foo> {}\n', written);
		if (written != null) Assert.equals(written, roundTrip(written));
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-CONSTRAINT-AFTER-LEAD-OFF', 'M-OPTIONAL-AFTER-LEAD-UNPARSED')
	public function testLineCommentAfterTheConstraintColon(): Void {
		assertCanonical('class C<U:// k\n\tFoo> {}\n');
	}

	@:pin('control')
	@:killer('M-TYPEPARAM-DEFAULT-AFTER-LEAD-OFF')
	public function testCommentAfterTheDefaultEquals(): Void {
		assertCanonical('class C<T:Foo = /*d*/ Bar> {}\n');
	}

	@:pin('guard')
	public function testPlainFormsKeepTheirBytes(): Void {
		assertCanonical('class C<T:Foo, S = D, U:Foo = D> {}\n');
	}

	private function assertCanonical(source: String): Void {
		Assert.equals(source, roundTrip(source));
	}

	private function roundTrip(source: String): Null<String> {
		try {
			return new HaxeQueryPlugin().writeRoundTrip(source);
		} catch (exception: haxe.Exception) {
			Assert.fail('${exception.message}: $source');
			return null;
		}
	}

}
