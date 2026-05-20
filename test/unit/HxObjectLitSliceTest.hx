package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxObjectLit;
import anyparse.grammar.haxe.HxObjectFieldBody;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Tests for slice χ₃: anonymous object literals `{name: value, ...}`.
 *
 * New grammar:
 *  - `HxObjectFieldBody` typedef: `name:HxIdentLit` + `@:lead(':') value:HxExpr`.
 *  - `HxObjectField` enum (Slice 18): `Field(body:HxObjectFieldBody)` +
 *    `@:kw('#if') Conditional(inner:HxConditionalObjectField)`.
 *  - `HxObjectLit` typedef: `@:lead('{') @:trail('}') @:sep(',') fields:Array<HxObjectField>`.
 *  - `HxExpr.ObjectLit(lit:HxObjectLit)` atom branch — bare-Ref dispatch,
 *    the inner `@:lead('{')` drives `tryBranch` peek.
 *
 * Zero Lowering changes expected for this slice (Slice 18 adds the
 * `@:sep+@:tryparse-no-close` branch used by `HxConditionalObjectField.body`,
 * tested separately in `HxConditionalObjectFieldSliceTest`).
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
				final body:HxObjectFieldBody = expectObjectFieldBody(lit.fields[0]);
				Assert.equals('a', (body.name : String));
				switch body.value {
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
				Assert.equals('a', (expectObjectFieldBody(lit.fields[0]).name : String));
				Assert.equals('b', (expectObjectFieldBody(lit.fields[1]).name : String));
				Assert.equals('c', (expectObjectFieldBody(lit.fields[2]).name : String));
			case null, _: Assert.fail('expected ObjectLit(3 fields)');
		}
	}

	public function testNestedObjectLit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {outer: {inner: 1}}; }');
		switch decl.init {
			case ObjectLit(outer):
				Assert.equals(1, outer.fields.length);
				switch expectObjectFieldBody(outer.fields[0]).value {
					case ObjectLit(inner):
						Assert.equals(1, inner.fields.length);
						Assert.equals('inner', (expectObjectFieldBody(inner.fields[0]).name : String));
					case null, _: Assert.fail('expected nested ObjectLit');
				}
			case null, _: Assert.fail('expected ObjectLit');
		}
	}

	public function testObjectLitWithExpressionValue():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {sum: a + b}; }');
		switch decl.init {
			case ObjectLit(lit):
				switch expectObjectFieldBody(lit.fields[0]).value {
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
				Assert.equals('major', (expectObjectFieldBody(lit.fields[0]).name : String));
			case null, _: Assert.fail('expected GtEq(v, ObjectLit)');
		}
	}

	/**
	 * Slice 12: a double-quoted string key is stored verbatim WITH its
	 * surrounding quotes (`@:rawString` on `HxObjectKeyLit`).
	 */
	public function testQuotedKey():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {"name": 1}; }');
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals(1, lit.fields.length);
				final body:HxObjectFieldBody = expectObjectFieldBody(lit.fields[0]);
				Assert.equals('"name"', (body.name : String));
				switch body.value {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
			case null, _: Assert.fail('expected ObjectLit({"name":1})');
		}
	}

	/**
	 * Mixed bare + quoted keys in one literal, including a key that is
	 * NOT a valid identifier (`"b-c"`) — the generalization payoff.
	 */
	public function testMixedBareAndQuotedKeys():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {a: 1, "b-c": 2}; }');
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals(2, lit.fields.length);
				Assert.equals('a', (expectObjectFieldBody(lit.fields[0]).name : String));
				Assert.equals('"b-c"', (expectObjectFieldBody(lit.fields[1]).name : String));
			case null, _: Assert.fail('expected ObjectLit(2 mixed-key fields)');
		}
	}

	/** Verbatim `whitespace/issue_60` shape + idempotent re-emit. */
	public function testQuotedKeyIssue60RoundTrip():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x = {"i":0}; }');
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals('"i"', (expectObjectFieldBody(lit.fields[0]).name : String));
			case null, _: Assert.fail('expected ObjectLit({"i":0})');
		}
		roundTrip('class C { function main() { var x = {"i":0}; } }', 'issue_60');
	}

	/**
	 * Regression sentinel: a string VALUE (`{ x: "v" }`) is unaffected —
	 * the key is bare, the value parses as a string-literal expression.
	 */
	public function testStringValueKeyUnaffected():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {x: "v"}; }');
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals('x', (expectObjectFieldBody(lit.fields[0]).name : String));
			case null, _: Assert.fail('expected ObjectLit({x:"v"})');
		}
	}
}
