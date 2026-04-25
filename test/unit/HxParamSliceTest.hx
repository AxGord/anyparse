package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxParam;
import anyparse.runtime.ParseError;

/**
 * Phase 3 function-parameter tests for the macro-generated Haxe parser.
 *
 * Validates the transition from `@:trail('()')` (fixed empty parens) to
 * real comma-separated parameter lists via `@:lead('(') @:trail(')')
 * @:sep(',') var params:Array<HxParam>`. This is the first struct Star
 * field in the Haxe grammar that uses the sep-peek termination mode in
 * `emitStarFieldSteps`.
 *
 * `HxParam` is an Alt-enum split — `Required(body:HxParamBody)` vs
 * `Optional(body:HxParamBody)` — to carry the `?name:Type` optional-
 * marker. Both branches share the same `name`/`type`/`defaultValue`
 * body and the `@:optional @:lead('=')` pattern from `HxVarDecl.init`
 * for default values. Test accessors route through
 * `expectRequiredParam` / `expectOptionalParam` (in `HxTestHelpers`).
 */
class HxParamSliceTest extends HxTestHelpers {

	public function testZeroParams():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Int {} }');
		Assert.equals('bar', (decl.name : String));
		Assert.equals(0, decl.params.length);
		Assert.equals('Int', (expectNamedType(decl.returnType).name : String));
	}

	public function testSingleParam():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar(x:Int):Bool {} }');
		Assert.equals('bar', (decl.name : String));
		Assert.equals(1, decl.params.length);
		final body = expectRequiredParam(decl.params[0]);
		Assert.equals('x', (body.name : String));
		Assert.equals('Int', (expectNamedType(body.type).name : String));
		Assert.isNull(body.defaultValue);
		Assert.equals('Bool', (expectNamedType(decl.returnType).name : String));
	}

	public function testTwoParams():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function add(a:Int, b:Int):Int {} }');
		Assert.equals('add', (decl.name : String));
		Assert.equals(2, decl.params.length);
		final b0 = expectRequiredParam(decl.params[0]);
		Assert.equals('a', (b0.name : String));
		Assert.equals('Int', (expectNamedType(b0.type).name : String));
		final b1 = expectRequiredParam(decl.params[1]);
		Assert.equals('b', (b1.name : String));
		Assert.equals('Int', (expectNamedType(b1.type).name : String));
	}

	public function testThreeParams():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(a:Int, b:String, c:Bool):Void {} }');
		Assert.equals(3, decl.params.length);
		final b0 = expectRequiredParam(decl.params[0]);
		Assert.equals('a', (b0.name : String));
		Assert.equals('Int', (expectNamedType(b0.type).name : String));
		final b1 = expectRequiredParam(decl.params[1]);
		Assert.equals('b', (b1.name : String));
		Assert.equals('String', (expectNamedType(b1.type).name : String));
		final b2 = expectRequiredParam(decl.params[2]);
		Assert.equals('c', (b2.name : String));
		Assert.equals('Bool', (expectNamedType(b2.type).name : String));
	}

	public function testParamWithDefaultValue():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(x:Int = 42):Void {} }');
		Assert.equals(1, decl.params.length);
		final body = expectRequiredParam(decl.params[0]);
		Assert.equals('x', (body.name : String));
		Assert.equals('Int', (expectNamedType(body.type).name : String));
		switch body.defaultValue {
			case IntLit(v): Assert.equals(42, (v : Int));
			case null, _: Assert.fail('expected IntLit(42)');
		}
	}

	public function testMixedDefaultValues():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(a:Int, b:Int = 0, c:Bool = true):Int {} }');
		Assert.equals(3, decl.params.length);

		final b0 = expectRequiredParam(decl.params[0]);
		Assert.equals('a', (b0.name : String));
		Assert.isNull(b0.defaultValue);

		final b1 = expectRequiredParam(decl.params[1]);
		Assert.equals('b', (b1.name : String));
		switch b1.defaultValue {
			case IntLit(v): Assert.equals(0, (v : Int));
			case null, _: Assert.fail('expected IntLit(0)');
		}

		final b2 = expectRequiredParam(decl.params[2]);
		Assert.equals('c', (b2.name : String));
		switch b2.defaultValue {
			case BoolLit(v): Assert.isTrue(v);
			case null, _: Assert.fail('expected BoolLit(true)');
		}
	}

	public function testDefaultValueExpression():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(x:Int = 1 + 2):Void {} }');
		Assert.equals(1, decl.params.length);
		final body = expectRequiredParam(decl.params[0]);
		switch body.defaultValue {
			case Add(left, right):
				switch left {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
				switch right {
					case IntLit(v): Assert.equals(2, (v : Int));
					case null, _: Assert.fail('expected IntLit(2)');
				}
			case null, _: Assert.fail('expected Add(IntLit(1), IntLit(2))');
		}
	}

	public function testWhitespaceTolerance():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f( a : Int , b : String ):Void {} }');
		Assert.equals(2, decl.params.length);
		final b0 = expectRequiredParam(decl.params[0]);
		Assert.equals('a', (b0.name : String));
		Assert.equals('Int', (expectNamedType(b0.type).name : String));
		final b1 = expectRequiredParam(decl.params[1]);
		Assert.equals('b', (b1.name : String));
		Assert.equals('String', (expectNamedType(b1.type).name : String));
	}

	public function testRejectsTrailingComma():Void {
		Assert.raises(() -> HaxeParser.parse('class Foo { function f(a:Int,):Bool {} }'), ParseError);
	}

	public function testRejectsMissingType():Void {
		Assert.raises(() -> HaxeParser.parse('class Foo { function f(x):Void {} }'), ParseError);
	}

	public function testParamsThroughModuleRoot():Void {
		final source:String = 'class A { function f(x:Int):Void {} } class B { function g(a:Int, b:Bool):Int {} }';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(2, module.decls.length);

		final a:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, a.members.length);
		final af:HxFnDecl = expectFnMember(a.members[0].member);
		Assert.equals('f', (af.name : String));
		Assert.equals(1, af.params.length);
		Assert.equals('x', (expectRequiredParam(af.params[0]).name : String));

		final b:HxClassDecl = expectClassDecl(module.decls[1]);
		Assert.equals(1, b.members.length);
		final bf:HxFnDecl = expectFnMember(b.members[0].member);
		Assert.equals('g', (bf.name : String));
		Assert.equals(2, bf.params.length);
		Assert.equals('a', (expectRequiredParam(bf.params[0]).name : String));
		Assert.equals('b', (expectRequiredParam(bf.params[1]).name : String));
	}

	public function testParamsWithModifiers():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { public static function bar(x:Int, y:Int):Void {} }');
		Assert.equals(1, ast.members.length);
		Assert.equals(2, ast.members[0].modifiers.length);
		final decl:HxFnDecl = expectFnMember(ast.members[0].member);
		Assert.equals('bar', (decl.name : String));
		Assert.equals(2, decl.params.length);
		Assert.equals('x', (expectRequiredParam(decl.params[0]).name : String));
		Assert.equals('y', (expectRequiredParam(decl.params[1]).name : String));
	}

	public function testOptionalSingleParam():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(?x:Int):Void {} }');
		Assert.equals(1, decl.params.length);
		final body = expectOptionalParam(decl.params[0]);
		Assert.equals('x', (body.name : String));
		Assert.equals('Int', (expectNamedType(body.type).name : String));
		Assert.isNull(body.defaultValue);
	}

	public function testOptionalParamWithDefault():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(?x:Int = 42):Void {} }');
		Assert.equals(1, decl.params.length);
		final body = expectOptionalParam(decl.params[0]);
		Assert.equals('x', (body.name : String));
		switch body.defaultValue {
			case IntLit(v): Assert.equals(42, (v : Int));
			case null, _: Assert.fail('expected IntLit(42)');
		}
	}

	public function testMixedHeadOptional():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(?a:Int, b:String):Void {} }');
		Assert.equals(2, decl.params.length);
		final b0 = expectOptionalParam(decl.params[0]);
		Assert.equals('a', (b0.name : String));
		Assert.equals('Int', (expectNamedType(b0.type).name : String));
		final b1 = expectRequiredParam(decl.params[1]);
		Assert.equals('b', (b1.name : String));
		Assert.equals('String', (expectNamedType(b1.type).name : String));
	}

	public function testMixedTailOptional():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(a:Int, ?b:String):Void {} }');
		Assert.equals(2, decl.params.length);
		final b0 = expectRequiredParam(decl.params[0]);
		Assert.equals('a', (b0.name : String));
		final b1 = expectOptionalParam(decl.params[1]);
		Assert.equals('b', (b1.name : String));
	}

	public function testOptionalWhitespaceTolerant():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f( ? x : Int , ? y : String ):Void {} }');
		Assert.equals(2, decl.params.length);
		Assert.equals('x', (expectOptionalParam(decl.params[0]).name : String));
		Assert.equals('y', (expectOptionalParam(decl.params[1]).name : String));
	}

	public function testOptionalRoundTrip():Void {
		// Defaults: tight colon, no space between `?` and name.
		roundTrip('class Foo { function f(?x:Int):Void {} }', 'single-optional');
		roundTrip('class Foo { function f(?x:Int = 42):Void {} }', 'optional-with-default');
		roundTrip('class Foo { function f(?a:Int, b:String):Void {} }', 'mixed-head-optional');
		roundTrip('class Foo { function f(a:Int, ?b:String):Void {} }', 'mixed-tail-optional');
	}
}
