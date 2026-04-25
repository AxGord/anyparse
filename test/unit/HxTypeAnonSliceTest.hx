package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxAnonField;
import anyparse.grammar.haxe.HxAnonFieldBody;
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
 * `?optional` marker landed via Alt-enum split — `HxAnonField` is now
 * `Required(field:HxAnonFieldBody) | Optional(field:HxAnonFieldBody)`.
 * Existing accessors route through `expectRequired` / `expectOptional`
 * helpers that switch on the variant and return the shared body.
 */
class HxTypeAnonSliceTest extends HxTestHelpers {

	private function expectAnon(t:Null<HxType>):Array<HxAnonField> {
		return switch t {
			case null: throw 'expected HxType.Anon, got null';
			case Anon(fields): fields;
			case _: throw 'expected HxType.Anon, got non-Anon variant';
		};
	}

	private function expectRequired(field:HxAnonField):HxAnonFieldBody {
		return switch field {
			case Required(body): body;
			case Optional(_): throw 'expected HxAnonField.Required, got Optional';
		};
	}

	private function expectOptional(field:HxAnonField):HxAnonFieldBody {
		return switch field {
			case Optional(body): body;
			case Required(_): throw 'expected HxAnonField.Optional, got Required';
		};
	}

	public function testSingleField():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{x:Int}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(1, fields.length);
		final body = expectRequired(fields[0]);
		Assert.equals('x', (body.name : String));
		Assert.equals('Int', (expectNamedType(body.type).name : String));
	}

	public function testMultipleFields():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{x:Int, y:String}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(2, fields.length);
		final b0 = expectRequired(fields[0]);
		Assert.equals('x', (b0.name : String));
		Assert.equals('Int', (expectNamedType(b0.type).name : String));
		final b1 = expectRequired(fields[1]);
		Assert.equals('y', (b1.name : String));
		Assert.equals('String', (expectNamedType(b1.type).name : String));
	}

	public function testNestedAnon():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{f:{f:Int}}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final outer = expectAnon(v.type);
		Assert.equals(1, outer.length);
		final ob = expectRequired(outer[0]);
		Assert.equals('f', (ob.name : String));
		final inner = expectAnon(ob.type);
		Assert.equals(1, inner.length);
		final ib = expectRequired(inner[0]);
		Assert.equals('f', (ib.name : String));
		Assert.equals('Int', (expectNamedType(ib.type).name : String));
	}

	public function testAnonWithArrowField():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{cb:Int->Void}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(1, fields.length);
		final t = expectRequired(fields[0]).type;
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
		final ref = expectNamedType(expectRequired(fields[0]).type);
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
		Assert.equals('x', (expectRequired(fields[0]).name : String));
	}

	public function testAnonOnFnReturnType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():{i:Int} {} }');
		final fields = expectAnon(decl.returnType);
		Assert.equals(1, fields.length);
		Assert.equals('i', (expectRequired(fields[0]).name : String));
	}

	public function testAnonOnFnParamType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar(s:{i:Int}):Void {} }');
		Assert.equals(1, decl.params.length);
		final fields = expectAnon(decl.params[0].type);
		Assert.equals(1, fields.length);
		Assert.equals('i', (expectRequired(fields[0]).name : String));
	}

	public function testWhitespaceTolerant():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s : { x : Int , y : String } ; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(2, fields.length);
		Assert.equals('x', (expectRequired(fields[0]).name : String));
		Assert.equals('y', (expectRequired(fields[1]).name : String));
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

	public function testOptionalSingle():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{?name:String}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(1, fields.length);
		final body = expectOptional(fields[0]);
		Assert.equals('name', (body.name : String));
		Assert.equals('String', (expectNamedType(body.type).name : String));
	}

	public function testOptionalMixedHeadOptional():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{?a:Int, b:String}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(2, fields.length);
		final b0 = expectOptional(fields[0]);
		Assert.equals('a', (b0.name : String));
		Assert.equals('Int', (expectNamedType(b0.type).name : String));
		final b1 = expectRequired(fields[1]);
		Assert.equals('b', (b1.name : String));
		Assert.equals('String', (expectNamedType(b1.type).name : String));
	}

	public function testOptionalMixedTailOptional():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{a:Int, ?b:String}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(2, fields.length);
		final b0 = expectRequired(fields[0]);
		Assert.equals('a', (b0.name : String));
		final b1 = expectOptional(fields[1]);
		Assert.equals('b', (b1.name : String));
	}

	public function testOptionalNested():Void {
		// `{?outer:{?inner:Int}}` — both levels carry the marker.
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s:{?outer:{?inner:Int}}; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final outer = expectAnon(v.type);
		Assert.equals(1, outer.length);
		final ob = expectOptional(outer[0]);
		Assert.equals('outer', (ob.name : String));
		final inner = expectAnon(ob.type);
		Assert.equals(1, inner.length);
		final ib = expectOptional(inner[0]);
		Assert.equals('inner', (ib.name : String));
		Assert.equals('Int', (expectNamedType(ib.type).name : String));
	}

	public function testOptionalWhitespaceTolerant():Void {
		// `?` admits surrounding whitespace before the field name.
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var s : { ? a : Int , ? b : String } ; }');
		final v:HxVarDecl = expectVarMember(ast.members[0].member);
		final fields = expectAnon(v.type);
		Assert.equals(2, fields.length);
		Assert.equals('a', (expectOptional(fields[0]).name : String));
		Assert.equals('b', (expectOptional(fields[1]).name : String));
	}

	public function testOptionalRoundTrip():Void {
		// Defaults: tight colon, tight braces, no space between `?` and name.
		roundTrip('class Foo { var s:{?name:String}; }', 'single-optional');
		roundTrip('class Foo { var s:{?a:Int, b:String}; }', 'mixed-head-optional');
		roundTrip('class Foo { var s:{a:Int, ?b:String}; }', 'mixed-tail-optional');
		roundTrip('class Foo { var s:{?outer:{?inner:Int}}; }', 'nested-optional');
	}

	// Direct parse of issue_140_assignment_in_anon_type input (whitespace
	// corpus). Pre-slice this skipped at parse on `?` in the anon type.
	public function testIssue140RoundTrip():Void {
		final src = 'class Main {\n\tpublic static function main() {\n\t\tvar content:{?name:String} = Json.parse(File.getContent(haxelibFile));\n\t}\n}';
		roundTrip(src, 'issue_140');
	}
}
