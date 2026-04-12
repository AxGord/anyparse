package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 ternary + null-coalescing slice tests for the macro-generated
 * Haxe parser.
 *
 * Covers:
 *  - `??` (null-coalescing, binary infix, prec 2, right-assoc)
 *  - `? :` (ternary, mixfix, prec 1, right-assoc by construction)
 *  - Precedence renumber (assignments from prec 1 to prec 0)
 *  - D33 longest-match disambiguation: `??` (len 2) before `?` (len 1)
 */
class HxTernarySliceTest extends HxTestHelpers {

	// ---- ?? basics ----

	public function testNullCoalSmoke():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ?? b; }');
		switch decl.init {
			case NullCoal(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected NullCoal, got ${decl.init}');
		}
	}

	public function testNullCoalRightAssoc():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ?? b ?? c; }');
		switch decl.init {
			case NullCoal(IdentExpr(l), NullCoal(IdentExpr(m), IdentExpr(r))):
				Assert.equals('a', (l : String));
				Assert.equals('b', (m : String));
				Assert.equals('c', (r : String));
			case null, _:
				Assert.fail('expected NullCoal(a, NullCoal(b, c)), got ${decl.init}');
		}
	}

	public function testNullCoalLooserThanAdd():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ?? b + c; }');
		switch decl.init {
			case NullCoal(IdentExpr(_), Add(IdentExpr(_), IdentExpr(_))):
				Assert.pass();
			case null, _:
				Assert.fail('expected NullCoal(a, Add(b, c)), got ${decl.init}');
		}
	}

	public function testAddTighterThanNullCoal():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a + b ?? c; }');
		switch decl.init {
			case NullCoal(Add(IdentExpr(_), IdentExpr(_)), IdentExpr(r)):
				Assert.equals('c', (r : String));
			case null, _:
				Assert.fail('expected NullCoal(Add(a, b), c), got ${decl.init}');
		}
	}

	public function testOrTighterThanNullCoal():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a || b ?? c; }');
		switch decl.init {
			case NullCoal(Or(IdentExpr(_), IdentExpr(_)), IdentExpr(r)):
				Assert.equals('c', (r : String));
			case null, _:
				Assert.fail('expected NullCoal(Or(a, b), c), got ${decl.init}');
		}
	}

	// ---- ternary basics ----

	public function testTernarySmoke():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c; }');
		switch decl.init {
			case Ternary(IdentExpr(cond), IdentExpr(then), IdentExpr(els)):
				Assert.equals('a', (cond : String));
				Assert.equals('b', (then : String));
				Assert.equals('c', (els : String));
			case null, _:
				Assert.fail('expected Ternary(a, b, c), got ${decl.init}');
		}
	}

	public function testTernaryRightAssoc():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c ? d : e; }');
		switch decl.init {
			case Ternary(IdentExpr(cond), IdentExpr(then), Ternary(IdentExpr(c2), IdentExpr(t2), IdentExpr(e2))):
				Assert.equals('a', (cond : String));
				Assert.equals('b', (then : String));
				Assert.equals('c', (c2 : String));
				Assert.equals('d', (t2 : String));
				Assert.equals('e', (e2 : String));
			case null, _:
				Assert.fail('expected Ternary(a, b, Ternary(c, d, e)), got ${decl.init}');
		}
	}

	public function testTernaryOperatorInMiddle():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b + c : d; }');
		switch decl.init {
			case Ternary(IdentExpr(_), Add(IdentExpr(_), IdentExpr(_)), IdentExpr(e)):
				Assert.equals('d', (e : String));
			case null, _:
				Assert.fail('expected Ternary(a, Add(b, c), d), got ${decl.init}');
		}
	}

	public function testTernaryOperatorInCondition():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a + b ? c : d; }');
		switch decl.init {
			case Ternary(Add(IdentExpr(_), IdentExpr(_)), IdentExpr(t), IdentExpr(e)):
				Assert.equals('c', (t : String));
				Assert.equals('d', (e : String));
			case null, _:
				Assert.fail('expected Ternary(Add(a, b), c, d), got ${decl.init}');
		}
	}

	public function testTernaryOperatorInRight():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c + d; }');
		switch decl.init {
			case Ternary(IdentExpr(_), IdentExpr(_), Add(IdentExpr(_), IdentExpr(r))):
				Assert.equals('d', (r : String));
			case null, _:
				Assert.fail('expected Ternary(a, b, Add(c, d)), got ${decl.init}');
		}
	}

	// ---- cross-operator ----

	public function testNullCoalTighterThanTernary():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ?? b ? c : d; }');
		switch decl.init {
			case Ternary(NullCoal(IdentExpr(_), IdentExpr(_)), IdentExpr(t), IdentExpr(e)):
				Assert.equals('c', (t : String));
				Assert.equals('d', (e : String));
			case null, _:
				Assert.fail('expected Ternary(NullCoal(a, b), c, d), got ${decl.init}');
		}
	}

	public function testNullCoalInTernaryRight():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c ?? d; }');
		switch decl.init {
			case Ternary(IdentExpr(_), IdentExpr(_), NullCoal(IdentExpr(_), IdentExpr(r))):
				Assert.equals('d', (r : String));
			case null, _:
				Assert.fail('expected Ternary(a, b, NullCoal(c, d)), got ${decl.init}');
		}
	}

	public function testAssignInTernaryRight():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c = d; }');
		switch decl.init {
			case Ternary(IdentExpr(_), IdentExpr(_), Assign(IdentExpr(_), IdentExpr(r))):
				Assert.equals('d', (r : String));
			case null, _:
				Assert.fail('expected Ternary(a, b, Assign(c, d)), got ${decl.init}');
		}
	}

	// ---- integration ----

	public function testTernaryInReturnStmt():Void {
		final ast:HxClassDecl = HaxeFastParser.parse('class Foo { function f():Int { return a ? b : c; } }');
		Assert.equals(1, ast.members.length);
		final fn:HxFnDecl = expectFnMember(ast.members[0].member);
		Assert.equals(1, fn.body.length);
		switch fn.body[0] {
			case ReturnStmt(Ternary(IdentExpr(cond), IdentExpr(then), IdentExpr(els))):
				Assert.equals('a', (cond : String));
				Assert.equals('b', (then : String));
				Assert.equals('c', (els : String));
			case _:
				Assert.fail('expected ReturnStmt with Ternary');
		}
	}

	public function testTernaryThroughModuleRoot():Void {
		final mod:HxModule = HaxeModuleFastParser.parse('class A { var x:Int = a ?? b ? c : d; }');
		Assert.equals(1, mod.decls.length);
		final cls:HxClassDecl = expectClassDecl(mod.decls[0]);
		Assert.equals(1, cls.members.length);
		final decl:HxVarDecl = expectVarMember(cls.members[0].member);
		switch decl.init {
			case Ternary(NullCoal(_, _), _, _): Assert.pass();
			case null, _: Assert.fail('expected Ternary(NullCoal(...), ..., ...), got ${decl.init}');
		}
	}

	// ---- assignment renumber sanity ----

	public function testAssignStillWorks():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a = b; }');
		switch decl.init {
			case Assign(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected Assign, got ${decl.init}');
		}
	}

	public function testAssignRightAssocChainStillWorks():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a = b = c; }');
		switch decl.init {
			case Assign(IdentExpr(_), Assign(IdentExpr(_), IdentExpr(r))):
				Assert.equals('c', (r : String));
			case null, _:
				Assert.fail('expected Assign(a, Assign(b, c)), got ${decl.init}');
		}
	}

	// ---- rejections ----

	public function testRejectsMissingMiddleAndColon():Void {
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = a ? ; }'), ParseError);
	}

	public function testRejectsMissingColon():Void {
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = a ? b ; }'), ParseError);
	}

	public function testRejectsMissingRightOperand():Void {
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = a ? b : ; }'), ParseError);
	}
}
