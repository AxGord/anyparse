package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxIntersectionClause;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypedefDecl;

/**
 * Slice ω-type-intersection — intersection type `A & B` on a typedef
 * right-hand side.
 *
 * `&` is scoped to the typedef RHS (a bare
 * `@:trivia @:tryparse var intersections:Array<HxIntersectionClause>`
 * Star on `HxTypedefDecl`, structural sibling of `HxClassDecl.heritage`)
 * rather than added as an `HxType` Pratt operator: the latter makes the
 * `is`-operator right operand parser greedily eat the first `&` of a
 * following expression-level `&&`. The first operand stays in
 * `td.type`; every subsequent `& Type` is one flat
 * `HxIntersectionClause` (a `{ type:HxType }` struct) in
 * `td.intersections` (no nesting — `A & B & C` → two clauses `B`, `C`).
 *
 * Closes the `typedef X = WriteOptions & {};` parse gap (8 sole-blocker
 * `*WriteOptions.hx` files in the apq dogfood corpus).
 */
@:nullSafety(Strict)
class HxTypeIntersectionSliceTest extends HxTestHelpers {

	private function expectAnonFieldCount(t: HxType): Int {
		return switch t {
			case Anon(fields): fields.length;
			case _: throw 'expected HxType.Anon, got ${t}';
		};
	}

	public function testTwoNamedOperands(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = A & B;');
		Assert.equals(1, module.decls.length);
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('X', (td.name: String));
		Assert.equals('A', (expectNamedType(td.type).name: String));
		Assert.equals(1, td.intersections.length);
		Assert.equals('B', (expectNamedType(td.intersections[0].type).name: String));
	}

	public function testNamedAndEmptyAnon(): Void {
		// The dominant corpus shape: `typedef X = WriteOptions & {};`.
		final module: HxModule = HaxeModuleParser.parse('typedef X = WriteOptions & {};');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('WriteOptions', (expectNamedType(td.type).name: String));
		Assert.equals(1, td.intersections.length);
		Assert.equals(0, expectAnonFieldCount(td.intersections[0].type));
	}

	public function testNamedAndNonEmptyAnon(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = A & { a:Int };');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('A', (expectNamedType(td.type).name: String));
		Assert.equals(1, td.intersections.length);
		Assert.equals(1, expectAnonFieldCount(td.intersections[0].type));
	}

	public function testFlatChain(): Void {
		// `A & B & C` is a flat tail: type=A, intersections=[B, C].
		final module: HxModule = HaxeModuleParser.parse('typedef X = A & B & C;');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('A', (expectNamedType(td.type).name: String));
		Assert.equals(2, td.intersections.length);
		Assert.equals('B', (expectNamedType(td.intersections[0].type).name: String));
		Assert.equals('C', (expectNamedType(td.intersections[1].type).name: String));
	}

	public function testBareTypedefNotAffected(): Void {
		// A non-intersection typedef RHS still resolves to `Named` with
		// an empty intersection tail.
		final module: HxModule = HaxeModuleParser.parse('typedef X = Int;');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Int', (expectNamedType(td.type).name: String));
		Assert.equals(0, td.intersections.length);
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
		// Regression guard: `is` right operand is HxType (no `&`), so a
		// following expression-level `&&` is NOT consumed as intersection.
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

}
