package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxAnonField;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice `ω-hxtype-anon` — anonymous-structure type variant on `HxType`.
 *
 * Validates the new `Anon(fields:Array<HxAnonField>)` Alt branch
 * activated by `@:lead('{') @:trail('}') @:sep(',')`. Reuses the same
 * Case 4 sep-peek Star pattern as `HxObjectLit`. Type-position
 * dispatch is unambiguous because anon types only appear after `:`,
 * so no Alt-level conflict with `HxStatement.BlockStmt` or
 * `HxExpr.ObjectLit` exists.
 *
 * Optional-field marker `?name:Type` is deferred to a follow-up
 * slice — it requires either a Boolean presence-flag on `HxAnonField`
 * or splitting `HxAnonField` into an Alt enum with two branches.
 */
class HxTypeAnonSliceTest extends HxTestHelpers {

	private function expectAnon(t:Null<HxType>):Array<HxAnonField> {
		return switch t {
			case null: throw 'expected HxType.Anon, got null';
			case Anon(fields): fields;
			case _: throw 'expected HxType.Anon, got non-Anon variant';
		};
	}

	public function testSingleField():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{x:Int}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(1, fields.length);
		Assert.equals('x', (fields[0].name : String));
		Assert.equals('Int', (expectNamedType(fields[0].type).name : String));
	}

	public function testMultipleFields():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{x:Int, y:String}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(2, fields.length);
		Assert.equals('x', (fields[0].name : String));
		Assert.equals('Int', (expectNamedType(fields[0].type).name : String));
		Assert.equals('y', (fields[1].name : String));
		Assert.equals('String', (expectNamedType(fields[1].type).name : String));
	}

	public function testNestedAnon():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{f:{f:Int}}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final outer = expectAnon(v.type);
		Assert.equals(1, outer.length);
		Assert.equals('f', (outer[0].name : String));
		final inner = expectAnon(outer[0].type);
		Assert.equals(1, inner.length);
		Assert.equals('f', (inner[0].name : String));
		Assert.equals('Int', (expectNamedType(inner[0].type).name : String));
	}

	public function testAnonWithArrowField():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{cb:Int->Void}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(1, fields.length);
		final t = fields[0].type;
		switch t {
			case Arrow(l, r):
				Assert.equals('Int', (expectNamedType(l).name : String));
				Assert.equals('Void', (expectNamedType(r).name : String));
			case _: Assert.fail('expected Arrow inside anon');
		}
	}

	public function testAnonWithTypeParam():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{xs:Array<Int>}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(1, fields.length);
		final ref = expectNamedType(fields[0].type);
		Assert.equals('Array', (ref.name : String));
		Assert.equals(1, ref.params.length);
		Assert.equals('Int', (expectNamedType(ref.params[0]).name : String));
	}

	public function testAnonInsideTypeParam():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var xs:Array<{x:Int}>; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final outerRef = expectNamedType(v.type);
		Assert.equals('Array', (outerRef.name : String));
		Assert.equals(1, outerRef.params.length);
		final fields = expectAnon(outerRef.params[0]);
		Assert.equals(1, fields.length);
		Assert.equals('x', (fields[0].name : String));
	}

	public function testAnonOnFnReturnType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():{i:Int} {} }');
		final fields = expectAnon(decl.returnType);
		Assert.equals(1, fields.length);
		Assert.equals('i', (fields[0].name : String));
	}

	public function testAnonOnFnParamType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar(s:{i:Int}):Void {} }');
		Assert.equals(1, decl.params.length);
		final fields = expectAnon(decl.params[0].type);
		Assert.equals(1, fields.length);
		Assert.equals('i', (fields[0].name : String));
	}

	public function testWhitespaceTolerant():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s : { x : Int , y : String } ; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(2, fields.length);
		Assert.equals('x', (fields[0].name : String));
		Assert.equals('y', (fields[1].name : String));
	}

	public function testRoundTripTight():Void {
		// Default: tight colon (`x:Int`), tight braces (`{x:Int}`).
		roundTrip('class Foo { var s:{x:Int}; }', 'single-field');
		roundTrip('class Foo { var s:{x:Int, y:String}; }', 'multi-field');
		roundTrip('class Foo { var s:{f:{f:Int}}; }', 'nested-anon');
		roundTrip('class Foo { var s:{cb:Int->Void}; }', 'anon-with-arrow');
		roundTrip('class Foo { var xs:Array<{x:Int}>; }', 'anon-inside-type-param');
		roundTrip('class Foo { function bar():{i:Int} {} }', 'anon-return-type');
		roundTrip('class Foo { function bar(s:{i:Int}):Void {} }', 'anon-param-type');
	}
}
