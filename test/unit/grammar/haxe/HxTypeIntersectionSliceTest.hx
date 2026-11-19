package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.decl.HxTypedefDecl;
import anyparse.grammar.haxe.types.HxType;
import utest.Assert;

/**
 * Intersection type `A & B` on a typedef right-hand side: the typedef's `type` is one right-folded
 * `HxType.Intersection` (`A & B & C` is `Intersection(A, Intersection(B, C))`), read here operand by operand.
 * `@:notFollowedBy('&')` on the operator keeps the type operand of `x is T && y` from taking the first `&`.
 */
@:nullSafety(Strict)
class HxTypeIntersectionSliceTest extends HxTestHelpers {

	public function testTwoNamedOperands(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = A & B;');
		Assert.equals(1, module.decls.length);
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('X', (td.name: String));
		Assert.same(['A', 'B'], intersectionNames(td.type));
	}

	public function testNamedAndEmptyAnon(): Void {
		// The dominant corpus shape: `typedef X = WriteOptions & {};`.
		final module: HxModule = HaxeModuleParser.parse('typedef X = WriteOptions & {};');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final operands: Array<HxType> = intersectionOperands(td.type);
		Assert.equals(2, operands.length);
		Assert.equals('WriteOptions', (expectNamedType(operands[0]).name: String));
		Assert.equals(0, expectAnonFieldCount(operands[1]));
	}

	public function testNamedAndNonEmptyAnon(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = A & { a:Int };');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final operands: Array<HxType> = intersectionOperands(td.type);
		Assert.equals(2, operands.length);
		Assert.equals('A', (expectNamedType(operands[0]).name: String));
		Assert.equals(1, expectAnonFieldCount(operands[1]));
	}

	public function testChainFoldsRight(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = A & B & C;');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.same(['A', 'B', 'C'], intersectionNames(td.type));
		switch td.type {
			case Intersection(left, Intersection(_, _)):
				Assert.equals('A', (expectNamedType(left).name: String));
			case t:
				Assert.fail('expected Intersection(A, Intersection(B, C)), got $t');
		}
	}

	public function testBareTypedefNotAffected(): Void {
		// A non-intersection typedef RHS still resolves to `Named`.
		final module: HxModule = HaxeModuleParser.parse('typedef X = Int;');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Int', (expectNamedType(td.type).name: String));
	}

	public function testWriterEmitsAroundSpacedAmpersand(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('typedef X = A&B;'));
		Assert.isTrue(out.indexOf('A & B') != -1, 'expected `A & B` in: <$out>');
	}

	public function testWriterEmitsAroundSpacedWithAnon(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('typedef X = WriteOptions&{};'));
		Assert.isTrue(out.indexOf('WriteOptions & {') != -1, 'expected `WriteOptions & {` in: <$out>');
	}

	public function testIsOperatorNotBrokenByAmpersand(): Void {
		// The `is` right operand is an HxType, whose `&` must not take the first `&` of the `&&` after it.
		final src: String = 'class C { static function m():Void { if (xxxx is SomeType && yyyy is OtherType) trace(0); } }';
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('xxxx is SomeType') != -1, '`is` operand pair stayed glued in: <$out>');
		Assert.isTrue(out.indexOf('&&') != -1, 'logical `&&` preserved in: <$out>');
	}

	public function testRoundTrip(): Void {
		roundTrip('typedef X = A & B;', 'two-named');
		roundTrip('typedef X = WriteOptions & {};', 'named-empty-anon');
		roundTrip('typedef X = A & { a:Int };', 'named-nonempty-anon');
		roundTrip('typedef X = A & B & C;', 'chain');
		roundTrip('typedef X = Int;', 'bare-unaffected');
	}

	private function expectAnonFieldCount(t: HxType): Int {
		return switch t {
			case Anon(fields): fields.length;
			case _: throw 'expected HxType.Anon, got ${t}';
		};
	}

}
