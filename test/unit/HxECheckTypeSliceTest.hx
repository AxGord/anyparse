package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;

/**
 * Tests for the SMALL slice adding the type-check expression atom
 * `(expr : Type)` to `HxExpr` (`ECheckTypeExpr(info:HxECheckType)`).
 *
 * Shape mirrors `HxTypedCast` — two-`Ref` field pair `(expr, type)`
 * separated by `:` instead of `,`. Placement in `HxExpr` is AFTER
 * `ParenLambdaExpr` and BEFORE `ParenExpr`: the lambda branch tries
 * first (so `(x : Int) => body` keeps its `ParenLambdaExpr` shape),
 * the bare-paren branch tries last (so `(expr)` falls through to
 * `ParenExpr` after `tryBranch` rolls back the missing `:`).
 *
 * Writer side defaults to `WhitespacePolicy.Both` via the new
 * `typeCheckColon` knob, so default-config output spaces the `:`
 * (`("" : String)`) — matches haxe-formatter's
 * `whitespace.typeCheckColonPolicy: @:default(Around)`.
 *
 * Unblocks corpus fixtures including
 * `whitespace/issue_284_type_check_in_array_comprehension.hxtest`.
 */
class HxECheckTypeSliceTest extends HxTestHelpers {

	public function testECheckTypeStringLit():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = ("" : String); }');
		switch decl.init {
			case ECheckTypeExpr(info):
				switch info.expr {
					case DoubleStringExpr(_): Assert.pass();
					case _: Assert.fail('expected DoubleStringExpr inner');
				}
				Assert.equals('String', (expectNamedType(info.type).name : String));
			case null, _: Assert.fail('expected ECheckTypeExpr, got ${decl.init}');
		}
	}

	public function testECheckTypeIdent():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = (x : Int); }');
		switch decl.init {
			case ECheckTypeExpr(info):
				switch info.expr {
					case IdentExpr(name): Assert.equals('x', (name : String));
					case _: Assert.fail('expected IdentExpr inner');
				}
				Assert.equals('Int', (expectNamedType(info.type).name : String));
			case null, _: Assert.fail('expected ECheckTypeExpr');
		}
	}

	public function testECheckTypeComplexExpr():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = (a + b : Float); }');
		switch decl.init {
			case ECheckTypeExpr(info):
				switch info.expr {
					case Add(IdentExpr(a), IdentExpr(b)):
						Assert.equals('a', (a : String));
						Assert.equals('b', (b : String));
					case _: Assert.fail('expected Add(a, b) inner');
				}
				Assert.equals('Float', (expectNamedType(info.type).name : String));
			case null, _: Assert.fail('expected ECheckTypeExpr');
		}
	}

	public function testECheckTypeGenericType():Void {
		final decl = parseSingleVarDecl('class C { var f:Int = (x : Map<String, Int>); }');
		switch decl.init {
			case ECheckTypeExpr(info):
				final ref = expectNamedType(info.type);
				Assert.equals('Map', (ref.name : String));
				Assert.notNull(ref.params);
				Assert.equals(2, ref.params.length);
			case null, _: Assert.fail('expected ECheckTypeExpr(Map<...>)');
		}
	}

	public function testECheckTypeEmptyArrayLiteral():Void {
		// Common idiom: `([] : Array<Int>)` — type-check around an empty
		// array literal so the type-checker resolves the element type.
		final decl = parseSingleVarDecl('class C { var f:Int = ([] : Array<Int>); }');
		switch decl.init {
			case ECheckTypeExpr(info):
				switch info.expr {
					case ArrayExpr(elems): Assert.equals(0, elems.length);
					case _: Assert.fail('expected ArrayExpr inner');
				}
				Assert.equals('Array', (expectNamedType(info.type).name : String));
			case null, _: Assert.fail('expected ECheckTypeExpr');
		}
	}

	public function testECheckTypeFollowedByPostfix():Void {
		// The postfix loop runs after the atom — ECheckType wraps the
		// inner; `.length` lands on the wrapper as `FieldAccess`.
		final decl = parseSingleVarDecl('class C { var f:Int = ("" : String).length; }');
		switch decl.init {
			case FieldAccess(ECheckTypeExpr(info), field):
				Assert.equals('length', (field : String));
				Assert.equals('String', (expectNamedType(info.type).name : String));
			case null, _: Assert.fail('expected FieldAccess(ECheckTypeExpr, length)');
		}
	}

	// ======== Negative / disambiguation ========

	public function testParenExprStillParses():Void {
		// Bare `(x)` must keep parsing as ParenExpr — ECheckType requires
		// the inner `:`, so without it `tryBranch` rolls back and the
		// next atom (ParenExpr) commits.
		final decl = parseSingleVarDecl('class C { var f:Int = (x); }');
		switch decl.init {
			case ParenExpr(IdentExpr(name)): Assert.equals('x', (name : String));
			case null, _: Assert.fail('expected ParenExpr(IdentExpr), got ${decl.init}');
		}
	}

	public function testParenLambdaStillParses():Void {
		// `(x : Int) => x + 1` must keep parsing as ParenLambdaExpr —
		// the lambda branch is BEFORE ECheckType in source order, so it
		// gets first try and consumes the typed param + `=>` body.
		final decl = parseSingleVarDecl('class C { var f:Int = (x : Int) => x + 1; }');
		switch decl.init {
			case ParenLambdaExpr(_): Assert.pass();
			case null, _: Assert.fail('expected ParenLambdaExpr, got ${decl.init}');
		}
	}

	// ======== Round-trip ========

	public function testECheckTypeRoundTrip():Void {
		roundTrip('class C { var f:Int = ("" : String); }', '("" : String)');
		roundTrip('class C { var f:Int = (x : Int); }', '(x : Int)');
		roundTrip('class C { var f:Int = (a + b : Float); }', '(a + b : Float)');
		roundTrip('class C { var f:Int = (x : Map<String, Int>); }', '(x : Map<...>)');
		roundTrip('class C { var f:Int = ([] : Array<Int>); }', '([] : Array<Int>)');
		roundTrip('class C { var f:Int = ("" : String).length; }', '("" : String).length');
	}

}
