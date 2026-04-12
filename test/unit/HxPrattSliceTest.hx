package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 Pratt-slice tests for the macro-generated Haxe parser.
 *
 * Covers the three pieces landed together: the Pratt strategy with
 * binary `+` `-` `*` `/` infix operators, the new `FloatLit` atom
 * branch with source-order precedence over `IntLit`, and the
 * word-boundary fix for `@:lit` Cases 1 and 2 that closes known
 * debt #7 (`trueish` / `nullable` no longer partial-match `true` /
 * `null`).
 *
 * Grammar coverage in this slice:
 *  - `a + b`, `a - b`, `a * b`, `a / b` — each operator alone.
 *  - `a + b * c`, `a * b + c` — precedence mixing.
 *  - `a + b + c`, `a - b - c` — left-associativity.
 *  - `1.5`, `0.5`, `1.0e10` — float literals.
 *  - `1.5 + 2` — float / int mixing under the operator loop.
 *  - `var x:Bool = trueish;` / `var x:Ty = nullable;` — word-
 *    boundary rejects the partial keyword match and falls through
 *    to `IdentExpr` (so the right-hand side is treated as an
 *    identifier and the parse succeeds with `IdentExpr("trueish")`
 *    rather than blowing up on a leftover `ish`).
 *  - `var x:Int = 1 +;` — operator with no right operand is a
 *    `ParseError` inside `parseHxExprAtom`.
 */
class HxPrattSliceTest extends Test {

	public function new() {
		super();
	}

	public function testAddTwoInts():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 1 + 2; }');
		switch decl.init {
			case Add(IntLit(l), IntLit(r)):
				Assert.equals(1, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected Add(IntLit(1), IntLit(2)), got ${decl.init}');
		}
	}

	public function testSubTwoInts():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 5 - 2; }');
		switch decl.init {
			case Sub(IntLit(l), IntLit(r)):
				Assert.equals(5, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected Sub(IntLit(5), IntLit(2)), got ${decl.init}');
		}
	}

	public function testMulTwoInts():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 3 * 4; }');
		switch decl.init {
			case Mul(IntLit(l), IntLit(r)):
				Assert.equals(3, (l : Int));
				Assert.equals(4, (r : Int));
			case null, _:
				Assert.fail('expected Mul(IntLit(3), IntLit(4)), got ${decl.init}');
		}
	}

	public function testDivTwoInts():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 10 / 2; }');
		switch decl.init {
			case Div(IntLit(l), IntLit(r)):
				Assert.equals(10, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected Div(IntLit(10), IntLit(2)), got ${decl.init}');
		}
	}

	public function testPrecedenceAddMul():Void {
		// 1 + 2 * 3 → Add(1, Mul(2, 3)) — `*` has precedence 9,
		// `+` has precedence 8; the higher-precedence operator
		// binds tighter to its operands.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 1 + 2 * 3; }');
		switch decl.init {
			case Add(IntLit(a), Mul(IntLit(b), IntLit(c))):
				Assert.equals(1, (a : Int));
				Assert.equals(2, (b : Int));
				Assert.equals(3, (c : Int));
			case null, _:
				Assert.fail('expected Add(1, Mul(2, 3)), got ${decl.init}');
		}
	}

	public function testPrecedenceMulAdd():Void {
		// 2 * 3 + 1 → Add(Mul(2, 3), 1) — same precedence rule in
		// the other order.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 2 * 3 + 1; }');
		switch decl.init {
			case Add(Mul(IntLit(a), IntLit(b)), IntLit(c)):
				Assert.equals(2, (a : Int));
				Assert.equals(3, (b : Int));
				Assert.equals(1, (c : Int));
			case null, _:
				Assert.fail('expected Add(Mul(2, 3), 1), got ${decl.init}');
		}
	}

	public function testLeftAssocAdd():Void {
		// 1 + 2 + 3 → Add(Add(1, 2), 3) — left-associative.
		// The operator at prec 8 recurses at minPrec 9, so the
		// second `+` fails the gate and is taken by the outer
		// loop iteration instead of the inner recursion.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 1 + 2 + 3; }');
		switch decl.init {
			case Add(Add(IntLit(a), IntLit(b)), IntLit(c)):
				Assert.equals(1, (a : Int));
				Assert.equals(2, (b : Int));
				Assert.equals(3, (c : Int));
			case null, _:
				Assert.fail('expected Add(Add(1, 2), 3), got ${decl.init}');
		}
	}

	public function testLeftAssocSub():Void {
		// 10 - 3 - 2 → Sub(Sub(10, 3), 2) — left-associativity for
		// subtraction matters because Sub(10, Sub(3, 2)) would
		// produce a semantically different result.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 10 - 3 - 2; }');
		switch decl.init {
			case Sub(Sub(IntLit(a), IntLit(b)), IntLit(c)):
				Assert.equals(10, (a : Int));
				Assert.equals(3, (b : Int));
				Assert.equals(2, (c : Int));
			case null, _:
				Assert.fail('expected Sub(Sub(10, 3), 2), got ${decl.init}');
		}
	}

	public function testFloatLit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Float = 3.14; }');
		switch decl.init {
			case FloatLit(v): Assert.floatEquals(3.14, (v : Float));
			case null, _: Assert.fail('expected FloatLit(3.14), got ${decl.init}');
		}
	}

	public function testFloatLitWithExponent():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Float = 1.0e3; }');
		switch decl.init {
			case FloatLit(v): Assert.floatEquals(1.0e3, (v : Float));
			case null, _: Assert.fail('expected FloatLit(1000), got ${decl.init}');
		}
	}

	public function testFloatPlusInt():Void {
		// FloatLit appears BEFORE IntLit in source order so the Pratt
		// atom dispatcher tries `1.5` as a float first and succeeds.
		// `2` fails the float regex on the missing `.` and rolls back
		// to IntLit.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Float = 1.5 + 2; }');
		switch decl.init {
			case Add(FloatLit(a), IntLit(b)):
				Assert.floatEquals(1.5, (a : Float));
				Assert.equals(2, (b : Int));
			case null, _:
				Assert.fail('expected Add(FloatLit(1.5), IntLit(2)), got ${decl.init}');
		}
	}

	public function testBareIntStillParses():Void {
		// Guard: adding FloatLit before IntLit must not break bare
		// integer parsing. `42` has no `.`, so FloatLit fails and
		// IntLit takes over.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 42; }');
		switch decl.init {
			case IntLit(v): Assert.equals(42, (v : Int));
			case null, _: Assert.fail('expected IntLit(42), got ${decl.init}');
		}
	}

	public function testTrueishIsIdentifier():Void {
		// Known debt #7 — `trueish` used to partial-match `true` at
		// the BoolLit branch and leave `ish` stranded. With matchKw
		// replacing matchLit in Case 2, the partial match is
		// rejected and the parser falls through to IdentExpr.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = trueish; }');
		switch decl.init {
			case IdentExpr(v): Assert.equals('trueish', (v : String));
			case null, _: Assert.fail('expected IdentExpr("trueish"), got ${decl.init}');
		}
	}

	public function testNullableIsIdentifier():Void {
		// Same guarantee for the single-lit zero-arg Case 1 branch
		// (`@:lit('null') NullLit`). `nullable` must be taken as an
		// identifier, not as `null` + stray `able`.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Ty = nullable; }');
		switch decl.init {
			case IdentExpr(v): Assert.equals('nullable', (v : String));
			case null, _: Assert.fail('expected IdentExpr("nullable"), got ${decl.init}');
		}
	}

	public function testFalseyIsIdentifier():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = falsey; }');
		switch decl.init {
			case IdentExpr(v): Assert.equals('falsey', (v : String));
			case null, _: Assert.fail('expected IdentExpr("falsey"), got ${decl.init}');
		}
	}

	public function testRejectsTrailingOperator():Void {
		// `1 +` — the `+` literal matches, skipWs runs, and then the
		// right-hand parseHxExpr tries every atom branch and fails
		// on the `;` terminator.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = 1 +; }'), ParseError);
	}

	public function testAddIdentAndInt():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a + 1; }');
		switch decl.init {
			case Add(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected Add(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testDeepLeftAssocChain():Void {
		// 1 + 2 * 3 + 4 → Add(Add(1, Mul(2, 3)), 4)
		// Precedence wraps the middle multiply, then left-associativity
		// groups the outer additions to the left.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 1 + 2 * 3 + 4; }');
		switch decl.init {
			case Add(Add(IntLit(a), Mul(IntLit(b), IntLit(c))), IntLit(d)):
				Assert.equals(1, (a : Int));
				Assert.equals(2, (b : Int));
				Assert.equals(3, (c : Int));
				Assert.equals(4, (d : Int));
			case null, _:
				Assert.fail('expected Add(Add(1, Mul(2, 3)), 4), got ${decl.init}');
		}
	}

	public function testExprThroughModuleRoot():Void {
		// Smoke-test the Pratt loop from the module root so the
		// second marker class (HaxeModuleFastParser) also exercises
		// the new rule pair.
		final source:String = 'class A { var x:Int = 1 + 2 * 3; } class B { var y:Float = 0.5; }';
		final module:HxModule = HaxeModuleFastParser.parse(source);
		Assert.equals(2, module.decls.length);

		final a:HxClassDecl = expectClassDecl(module.decls[0]);
		final aVar:HxVarDecl = expectVarMember(a.members[0].member);
		switch aVar.init {
			case Add(IntLit(_), Mul(IntLit(_), IntLit(_))): Assert.pass();
			case null, _: Assert.fail('expected Add(_, Mul(_, _)), got ${aVar.init}');
		}

		final b:HxClassDecl = expectClassDecl(module.decls[1]);
		final bVar:HxVarDecl = expectVarMember(b.members[0].member);
		switch bVar.init {
			case FloatLit(v): Assert.floatEquals(0.5, (v : Float));
			case null, _: Assert.fail('expected FloatLit(0.5), got ${bVar.init}');
		}
	}

	private function parseSingleVarDecl(source:String):HxVarDecl {
		final ast:HxClassDecl = HaxeFastParser.parse(source);
		Assert.equals(1, ast.members.length);
		return expectVarMember(ast.members[0].member);
	}

	private function expectVarMember(member:HxClassMember):HxVarDecl {
		return switch member {
			case VarMember(decl): decl;
			case _: throw 'expected VarMember, got $member';
		};
	}

	private function expectClassDecl(decl:HxDecl):HxClassDecl {
		return switch decl {
			case ClassDecl(c): c;
		};
	}
}
