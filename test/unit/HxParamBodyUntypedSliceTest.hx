package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxParamBody;

/**
 * Slice O (apq-P5 self-parse tail): untyped function-declaration
 * parameters.
 *
 * `HxParamBody.type` was a mandatory `@:lead(':') var type:HxType`,
 * so `function f(x)` (no `:Type`) failed to parse — yet it is valid
 * Haxe (the parameter type is inferred). The field is now the exact
 * `HxVarDecl.type` shape: `@:optional @:fmt(typeHintColon)
 * @:lead(':') var type:Null<HxType>`. The sibling `HxLambdaParam`
 * was already untyped-tolerant, so untyped function-declaration
 * parameters now round-trip on the same footing.
 *
 * This is a precedent-matched additive grammar widening — no
 * `Lowering` / writer / synth change (generic optional-Ref `@:lead`
 * path, identical to `HxVarDecl.type` and `HxParamBody.defaultValue`).
 * The reject-guard `HxParamSliceTest.testRejectsMissingType` was
 * flipped to the positive contract `testAcceptsMissingType` in the
 * same slice (it encoded the pre-slice wrong contract).
 */
class HxParamBodyUntypedSliceTest extends HxTestHelpers {

	/** `function f(x)` — single untyped param, no `:Type`. */
	public function testUntypedSingleParam(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function f(x):Void {} }');
		Assert.equals(1, decl.params.length);
		final body: HxParamBody = expectRequiredParam(decl.params[0]);
		Assert.equals('x', (body.name: String));
		Assert.isNull(body.type);
		Assert.isNull(body.defaultValue);
	}

	/** `function f(a, b)` — two untyped params. */
	public function testTwoUntypedParams(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function f(a, b):Void {} }');
		Assert.equals(2, decl.params.length);
		final b0: HxParamBody = expectRequiredParam(decl.params[0]);
		final b1: HxParamBody = expectRequiredParam(decl.params[1]);
		Assert.equals('a', (b0.name: String));
		Assert.isNull(b0.type);
		Assert.equals('b', (b1.name: String));
		Assert.isNull(b1.type);
	}

	/** `function g(x, y:Int)` — mixed untyped + typed. */
	public function testMixedTypedUntyped(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function g(x, y:Int):Void {} }');
		Assert.equals(2, decl.params.length);
		final b0: HxParamBody = expectRequiredParam(decl.params[0]);
		final b1: HxParamBody = expectRequiredParam(decl.params[1]);
		Assert.equals('x', (b0.name: String));
		Assert.isNull(b0.type);
		Assert.equals('y', (b1.name: String));
		Assert.equals('Int', (expectNamedType(b1.type).name: String));
	}

	/** Regression: a fully-typed param still carries its `HxType`. */
	public function testTypedParamStillWorks(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function h(x:Int):Void {} }');
		Assert.equals(1, decl.params.length);
		final body: HxParamBody = expectRequiredParam(decl.params[0]);
		Assert.equals('x', (body.name: String));
		Assert.equals('Int', (expectNamedType(body.type).name: String));
	}

	/** `function f(?x)` — optional marker, untyped. */
	public function testUntypedOptionalParam(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function f(?x):Void {} }');
		Assert.equals(1, decl.params.length);
		final body: HxParamBody = expectOptionalParam(decl.params[0]);
		Assert.equals('x', (body.name: String));
		Assert.isNull(body.type);
	}

	/** `function f(...x)` — rest / varargs marker, untyped. */
	public function testUntypedRestParam(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function f(...x):Void {} }');
		Assert.equals(1, decl.params.length);
		final body: HxParamBody = expectRestParam(decl.params[0]);
		Assert.equals('x', (body.name: String));
		Assert.isNull(body.type);
	}

	/** `function f(x = 0)` — untyped param with a default value. */
	public function testUntypedParamWithDefault(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function f(x = 0):Void {} }');
		Assert.equals(1, decl.params.length);
		final body: HxParamBody = expectRequiredParam(decl.params[0]);
		Assert.equals('x', (body.name: String));
		Assert.isNull(body.type);
		switch body.defaultValue {
			case IntLit(v):
				Assert.equals(0, (v: Int));
			case null, _:
				Assert.fail('expected IntLit default, got ${body.defaultValue}');
		}
	}

	/**
	 * The exact shape that blocked self-parse: an untyped param with
	 * an expression body and no return type — `function f(x) return x;`.
	 */
	public function testUntypedExprBodyNoReturnType(): Void {
		final decl: HxFnDecl = parseSingleFnDecl('class Foo { function f(x) return x; }');
		Assert.equals(1, decl.params.length);
		final body: HxParamBody = expectRequiredParam(decl.params[0]);
		Assert.equals('x', (body.name: String));
		Assert.isNull(body.type);
		switch decl.body {
			case ExprBody(ReturnExpr(IdentExpr(name))):
				Assert.equals('x', (name: String));
			case _:
				Assert.fail('expected ExprBody(ReturnExpr(IdentExpr)), got ${decl.body}');
		}
	}

	/** Untyped params survive the write -> reparse -> write idempotency. */
	public function testUntypedParamRoundTrip(): Void {
		roundTrip('class C { function f(x) return x; function g(a, b:Int):Int { return b; } }');
	}

	/** Untyped params parse through the module root in multiple classes. */
	public function testUntypedParamThroughModuleRoot(): Void {
		final source: String = 'class A { function f(x):Void {} } class B { function g(a, b:Bool):Int { return 0; } }';
		final module: HxModule = HaxeModuleParser.parse(source);
		Assert.equals(2, module.decls.length);
		final a: HxClassDecl = expectClassDecl(module.decls[0]);
		final b: HxClassDecl = expectClassDecl(module.decls[1]);
		final af: HxFnDecl = expectFnMember(a.members[0].member);
		final bf: HxFnDecl = expectFnMember(b.members[0].member);
		Assert.isNull(expectRequiredParam(af.params[0]).type);
		Assert.isNull(expectRequiredParam(bf.params[0]).type);
		Assert.equals('Bool', (expectNamedType(expectRequiredParam(bf.params[1]).type).name: String));
	}

}
