package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxIdentLit;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxTypedefDecl;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 type-parameter tests for `HxTypeRef`.
 *
 * Validates the optional close-peek Star added to `HxTypeRef.params` —
 * `@:optional @:lead('<') @:trail('>') @:sep(',')` — covering bare types
 * (`Int`), single-arg generics (`Array<Int>`), multi-arg generics
 * (`Map<String, Int>`), and recursive composition (`Foo<Bar<Baz>>`).
 *
 * The optional Star pattern is the first non-Ref consumer of `@:optional`
 * in the grammar — generated via `Lowering.emitOptionalStarFieldSteps`
 * on the parser side and a null-check wrapper in `WriterLowering` on the
 * writer side. Recursion composes naturally because the element rule is
 * `HxTypeRef` itself.
 */
class HxTypeParamSliceTest extends HxTestHelpers {

	public function testBareTypeHasNoParams():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Int {} }');
		Assert.equals('Int', (expectNamedType(decl.returnType).name : String));
		Assert.isNull(expectNamedType(decl.returnType).params);
	}

	public function testSingleTypeParam():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Array<Int> {} }');
		Assert.equals('Array', (expectNamedType(decl.returnType).name : String));
		final params:Null<Array<HxType>> = expectNamedType(decl.returnType).params;
		Assert.notNull(params);
		Assert.equals(1, params.length);
		Assert.equals('Int', (expectNamedType(params[0]).name : String));
		Assert.isNull(expectNamedType(params[0]).params);
	}

	public function testTwoTypeParams():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Map<String, Int> {} }');
		Assert.equals('Map', (expectNamedType(decl.returnType).name : String));
		final params:Null<Array<HxType>> = expectNamedType(decl.returnType).params;
		Assert.notNull(params);
		Assert.equals(2, params.length);
		Assert.equals('String', (expectNamedType(params[0]).name : String));
		Assert.equals('Int', (expectNamedType(params[1]).name : String));
	}

	public function testNestedTypeParams():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Array<Array<Int>> {} }');
		Assert.equals('Array', (expectNamedType(decl.returnType).name : String));
		final outer:Null<Array<HxType>> = expectNamedType(decl.returnType).params;
		Assert.notNull(outer);
		Assert.equals(1, outer.length);
		Assert.equals('Array', (expectNamedType(outer[0]).name : String));
		final inner:Null<Array<HxType>> = expectNamedType(outer[0]).params;
		Assert.notNull(inner);
		Assert.equals(1, inner.length);
		Assert.equals('Int', (expectNamedType(inner[0]).name : String));
	}

	public function testDoubleNestedClosingBrackets():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Foo<Bar<Baz>> {} }');
		final outer:Null<Array<HxType>> = expectNamedType(decl.returnType).params;
		Assert.notNull(outer);
		Assert.equals(1, outer.length);
		final mid:Null<Array<HxType>> = expectNamedType(outer[0]).params;
		Assert.notNull(mid);
		Assert.equals(1, mid.length);
		Assert.equals('Baz', (expectNamedType(mid[0]).name : String));
	}

	public function testParamTypeOnFnArgument():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar(xs:Array<Int>):Void {} }');
		Assert.equals(1, decl.params.length);
		Assert.equals('Array', (expectNamedType(decl.params[0].type).name : String));
		final inner:Null<Array<HxType>> = expectNamedType(decl.params[0].type).params;
		Assert.notNull(inner);
		Assert.equals(1, inner.length);
		Assert.equals('Int', (expectNamedType(inner[0]).name : String));
	}

	public function testParamTypeOnVar():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var xs:Array<String>; }');
		Assert.equals(1, ast.members.length);
		final decl:HxVarDecl = expectVarMember(ast.members[0].member);
		Assert.equals('Array', (expectNamedType(decl.type).name : String));
		final inner:Null<Array<HxType>> = expectNamedType(decl.type).params;
		Assert.notNull(inner);
		Assert.equals(1, inner.length);
		Assert.equals('String', (expectNamedType(inner[0]).name : String));
	}

	public function testWhitespaceTolerance():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Map < String , Int > {} }');
		final params:Null<Array<HxType>> = expectNamedType(decl.returnType).params;
		Assert.notNull(params);
		Assert.equals(2, params.length);
		Assert.equals('String', (expectNamedType(params[0]).name : String));
		Assert.equals('Int', (expectNamedType(params[1]).name : String));
	}

	public function testRejectsTrailingComma():Void {
		Assert.raises(() -> HaxeParser.parse('class Foo { function bar():Map<String, Int,> {} }'), ParseError);
	}

	public function testEmptyParamsParsesAsEmptyList():Void {
		// `Foo<>` is invalid Haxe but the sep+close macro pattern mirrors
		// the paren-list shape and accepts an empty list. Treated as a
		// permissive degenerate input — the corpus never produces it,
		// and the round-trip preserves the same empty-list shape.
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Foo<> {} }');
		final params:Null<Array<HxType>> = expectNamedType(decl.returnType).params;
		Assert.notNull(params);
		Assert.equals(0, params.length);
	}

	public function testRoundTripBare():Void {
		roundTrip('class F { var x:Int; }');
	}

	public function testRoundTripSingleParam():Void {
		roundTrip('class F { var xs:Array<Int>; }');
	}

	public function testRoundTripTwoParams():Void {
		roundTrip('class F { var m:Map<String, Int>; }');
	}

	public function testRoundTripNested():Void {
		roundTrip('class F { var x:Array<Array<Int>> = []; }');
	}

	public function testRoundTripFnReturnType():Void {
		roundTrip('class F { function get():Array<Int> {} }');
	}

	public function testRoundTripFnArgType():Void {
		roundTrip('class F { function take(xs:Array<Int>):Void {} }');
	}

	public function testDeclareSiteAbsentIsNull():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Int {} }');
		Assert.isNull(decl.typeParams);
	}

	public function testDeclareSiteSingleParam():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar<T>():T {} }');
		final tps:Null<Array<HxIdentLit>> = decl.typeParams;
		Assert.notNull(tps);
		Assert.equals(1, tps.length);
		Assert.equals('T', (tps[0] : String));
	}

	public function testDeclareSiteMultipleParams():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar<T, U>():Map<T, U> {} }');
		final tps:Null<Array<HxIdentLit>> = decl.typeParams;
		Assert.notNull(tps);
		Assert.equals(2, tps.length);
		Assert.equals('T', (tps[0] : String));
		Assert.equals('U', (tps[1] : String));
	}

	public function testDeclareSiteWhitespaceTolerance():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar < T , U > ():Void {} }');
		final tps:Null<Array<HxIdentLit>> = decl.typeParams;
		Assert.notNull(tps);
		Assert.equals(2, tps.length);
		Assert.equals('T', (tps[0] : String));
		Assert.equals('U', (tps[1] : String));
	}

	public function testRoundTripDeclareSiteSingle():Void {
		roundTrip('class F { function get<T>():T {} }');
	}

	public function testRoundTripDeclareSiteMulti():Void {
		roundTrip('class F { function pair<T, U>():Map<T, U> {} }');
	}

	public function testClassDeclareSiteSingle():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Box<T> { }');
		final tps:Null<Array<HxIdentLit>> = ast.typeParams;
		Assert.notNull(tps);
		Assert.equals(1, tps.length);
		Assert.equals('T', (tps[0] : String));
	}

	public function testClassDeclareSiteAbsentIsNull():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Box { }');
		Assert.isNull(ast.typeParams);
	}

	public function testClassDeclareSiteMulti():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Pair<A, B> { }');
		final tps:Null<Array<HxIdentLit>> = ast.typeParams;
		Assert.notNull(tps);
		Assert.equals(2, tps.length);
		Assert.equals('A', (tps[0] : String));
		Assert.equals('B', (tps[1] : String));
	}

	public function testTypedefDeclareSite():Void {
		final ast:HxModule = HaxeModuleParser.parse('typedef List<T> = Array<T>;');
		Assert.equals(1, ast.decls.length);
		final td:HxTypedefDecl = expectTypedefDecl(ast.decls[0]);
		final tps:Null<Array<HxIdentLit>> = td.typeParams;
		Assert.notNull(tps);
		Assert.equals(1, tps.length);
		Assert.equals('T', (tps[0] : String));
	}

	public function testEnumDeclareSite():Void {
		final ast:HxModule = HaxeModuleParser.parse('enum Option<T> { None; Some; }');
		Assert.equals(1, ast.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(ast.decls[0]);
		final tps:Null<Array<HxIdentLit>> = ed.typeParams;
		Assert.notNull(tps);
		Assert.equals(1, tps.length);
		Assert.equals('T', (tps[0] : String));
	}

	public function testAbstractDeclareSite():Void {
		final ast:HxModule = HaxeModuleParser.parse('abstract MyInt<T>(Int) { }');
		Assert.equals(1, ast.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(ast.decls[0]);
		final tps:Null<Array<HxIdentLit>> = ad.typeParams;
		Assert.notNull(tps);
		Assert.equals(1, tps.length);
		Assert.equals('T', (tps[0] : String));
	}

	public function testRoundTripClassDeclareSite():Void {
		roundTrip('class Box<T> { var v:T; }');
	}

	public function testRoundTripTypedefDeclareSite():Void {
		roundTrip('typedef List<T> = Array<T>;');
	}

	public function testRoundTripEnumDeclareSite():Void {
		roundTrip('enum Option<T> { None; Some; }');
	}

	public function testRoundTripAbstractDeclareSite():Void {
		roundTrip('abstract MyInt<T>(Int) { }');
	}

	public function testInterfaceDeclareSite():Void {
		final ast:HxModule = HaxeModuleParser.parse('interface Iterable<T> { }');
		Assert.equals(1, ast.decls.length);
		final id:HxInterfaceDecl = expectInterfaceDecl(ast.decls[0]);
		final tps:Null<Array<HxIdentLit>> = id.typeParams;
		Assert.notNull(tps);
		Assert.equals(1, tps.length);
		Assert.equals('T', (tps[0] : String));
	}

	public function testRoundTripInterfaceDeclareSite():Void {
		roundTrip('interface Iterable<T> { }');
	}

	public function testModuleQualifiedTwoSegments():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():pkg.Type {} }');
		Assert.equals('pkg.Type', (expectNamedType(decl.returnType).name : String));
		Assert.isNull(expectNamedType(decl.returnType).params);
	}

	public function testModuleQualifiedThreeSegments():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():haxe.io.Bytes {} }');
		Assert.equals('haxe.io.Bytes', (expectNamedType(decl.returnType).name : String));
	}

	public function testModuleQualifiedWithTypeParams():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():haxe.ds.Map<String, Int> {} }');
		Assert.equals('haxe.ds.Map', (expectNamedType(decl.returnType).name : String));
		final params:Null<Array<HxType>> = expectNamedType(decl.returnType).params;
		Assert.notNull(params);
		Assert.equals(2, params.length);
		Assert.equals('String', (expectNamedType(params[0]).name : String));
		Assert.equals('Int', (expectNamedType(params[1]).name : String));
	}

	public function testModuleQualifiedAsTypeParam():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Array<haxe.io.Bytes> {} }');
		Assert.equals('Array', (expectNamedType(decl.returnType).name : String));
		final params:Null<Array<HxType>> = expectNamedType(decl.returnType).params;
		Assert.notNull(params);
		Assert.equals(1, params.length);
		Assert.equals('haxe.io.Bytes', (expectNamedType(params[0]).name : String));
	}

	public function testRoundTripModuleQualified():Void {
		roundTrip('class F { var x:haxe.io.Bytes; }');
	}

	public function testRoundTripModuleQualifiedWithParams():Void {
		roundTrip('class F { var m:haxe.ds.Map<String, Int>; }');
	}
}
