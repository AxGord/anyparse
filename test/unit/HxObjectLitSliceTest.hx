package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxObjectLit;
import anyparse.grammar.haxe.HxObjectField;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Tests for slice χ₃: anonymous object literals `{name: value, ...}`.
 *
 * New grammar:
 *  - `HxObjectField` typedef: `name:HxIdentLit` + `@:lead(':') value:HxExpr`.
 *  - `HxObjectLit` typedef: `@:lead('{') @:trail('}') @:sep(',') fields:Array<HxObjectField>`.
 *  - `HxExpr.ObjectLit(lit:HxObjectLit)` atom branch — bare-Ref dispatch,
 *    the inner `@:lead('{')` drives `tryBranch` peek.
 *
 * Zero Lowering changes expected.
 */
class HxObjectLitSliceTest extends HxTestHelpers {

	public function testEmptyObjectLit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {}; }');
		switch decl.init {
			case ObjectLit(lit): Assert.equals(0, lit.fields.length);
			case null, _: Assert.fail('expected ObjectLit({}), got ${decl.init}');
		}
	}

	public function testSingleField():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {a: 1}; }');
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals(1, lit.fields.length);
				final field:HxObjectField = lit.fields[0];
				Assert.equals('a', (field.name : String));
				switch field.value {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
			case null, _: Assert.fail('expected ObjectLit({a:1})');
		}
	}

	public function testMultipleFields():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {a: 1, b: 2, c: 3}; }');
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals(3, lit.fields.length);
				Assert.equals('a', (lit.fields[0].name : String));
				Assert.equals('b', (lit.fields[1].name : String));
				Assert.equals('c', (lit.fields[2].name : String));
			case null, _: Assert.fail('expected ObjectLit(3 fields)');
		}
	}

	public function testNestedObjectLit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {outer: {inner: 1}}; }');
		switch decl.init {
			case ObjectLit(outer):
				Assert.equals(1, outer.fields.length);
				switch outer.fields[0].value {
					case ObjectLit(inner):
						Assert.equals(1, inner.fields.length);
						Assert.equals('inner', (inner.fields[0].name : String));
					case null, _: Assert.fail('expected nested ObjectLit');
				}
			case null, _: Assert.fail('expected ObjectLit');
		}
	}

	public function testObjectLitWithExpressionValue():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {sum: a + b}; }');
		switch decl.init {
			case ObjectLit(lit):
				switch lit.fields[0].value {
					case Add(IdentExpr(a), IdentExpr(b)):
						Assert.equals('a', (a : String));
						Assert.equals('b', (b : String));
					case null, _: Assert.fail('expected Add(a, b)');
				}
			case null, _: Assert.fail('expected ObjectLit');
		}
	}

	public function testObjectLitMixedValueTypes():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {n: 1, s: "hi", b: true, arr: [1, 2]}; }');
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals(4, lit.fields.length);
			case null, _: Assert.fail('expected ObjectLit(4 fields)');
		}
	}

	public function testObjectLitInBinop():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Bool = v >= {major: 4}; }');
		switch decl.init {
			case GtEq(IdentExpr(v), ObjectLit(lit)):
				Assert.equals('v', (v : String));
				Assert.equals('major', (lit.fields[0].name : String));
			case null, _: Assert.fail('expected GtEq(v, ObjectLit)');
		}
	}
}
