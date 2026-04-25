package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxParenLambda;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Tests for slice ξ₁: arrow operator (`=>`), array/map literals, and
 * parenthesised lambda expressions.
 *
 * Three new `HxExpr` branches:
 *
 *  - `Arrow` — `@:infix('=>', 0, 'Right')`. Handles single-ident
 *    lambdas and map entries inside array literals.
 *  - `ArrayExpr` — `@:lead('[') @:trail(']') @:sep(',')` Case 4 atom.
 *  - `ParenLambdaExpr` — bare-Ref Case 3 wrapping `HxParenLambda`
 *    typedef (tryBranch before `ParenExpr`).
 *
 * Zero Lowering changes expected.
 */
class HxArrowArraySliceTest extends HxTestHelpers {

	// ======== Arrow — single-ident lambda ========

	/** `x => x + 1` -> Arrow(IdentExpr("x"), Add(IdentExpr("x"), IntLit(1))). */
	public function testSingleIdentLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = x => x + 1; }');
		switch decl.init {
			case Arrow(IdentExpr(l), Add(IdentExpr(r1), IntLit(r2))):
				Assert.equals('x', (l : String));
				Assert.equals('x', (r1 : String));
				Assert.equals(1, (r2 : Int));
			case null, _: Assert.fail('expected Arrow(IdentExpr, Add), got ${decl.init}');
		}
	}

	/** `x => y => x + y` -> right-associative nesting. */
	public function testArrowRightAssoc():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = x => y => x + y; }');
		switch decl.init {
			case Arrow(IdentExpr(x), Arrow(IdentExpr(y), Add(_, _))):
				Assert.equals('x', (x : String));
				Assert.equals('y', (y : String));
			case null, _: Assert.fail('expected Arrow(x, Arrow(y, Add)), got ${decl.init}');
		}
	}

	/** `a = b => c` -> Assign(a, Arrow(b, c)). */
	public function testAssignVsArrow():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = a = b => c; }');
		switch decl.init {
			case Assign(IdentExpr(a), Arrow(IdentExpr(b), IdentExpr(c))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _: Assert.fail('expected Assign(a, Arrow(b, c)), got ${decl.init}');
		}
	}

	/** `x => x` — identity arrow in var initializer. */
	public function testArrowInVarInit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = x => x; }');
		switch decl.init {
			case Arrow(IdentExpr(l), IdentExpr(r)):
				Assert.equals('x', (l : String));
				Assert.equals('x', (r : String));
			case null, _: Assert.fail('expected Arrow(x, x), got ${decl.init}');
		}
	}

	/** Arrow in return statement. */
	public function testArrowInReturn():Void {
		final ast:HxClassDecl = HaxeParser.parse('class C { function f():Int { return x => x; } }');
		final fn:HxFnDecl = expectFnMember(ast.members[0].member);
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ReturnStmt(Arrow(IdentExpr(l), IdentExpr(r))):
				Assert.equals('x', (l : String));
				Assert.equals('x', (r : String));
			case null, _: Assert.fail('expected ReturnStmt(Arrow)');
		}
	}

	// ======== ParenLambdaExpr ========

	/** `() => 42` -> zero-param lambda. */
	public function testZeroParamLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = () => 42; }');
		switch decl.init {
			case ParenLambdaExpr(lambda):
				Assert.equals(0, lambda.params.length);
				switch lambda.body {
					case IntLit(v): Assert.equals(42, (v : Int));
					case null, _: Assert.fail('expected IntLit body');
				}
			case null, _: Assert.fail('expected ParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `(x) => x + 1` -> single-param paren lambda. */
	public function testSingleParenLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x) => x + 1; }');
		switch decl.init {
			case ParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
				Assert.isNull(lambda.params[0].type);
			case null, _: Assert.fail('expected ParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `(x, y) => x + y` -> multi-param lambda. */
	public function testMultiParamLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x, y) => x + y; }');
		switch decl.init {
			case ParenLambdaExpr(lambda):
				Assert.equals(2, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
				Assert.equals('y', (lambda.params[1].name : String));
				switch lambda.body {
					case Add(IdentExpr(l), IdentExpr(r)):
						Assert.equals('x', (l : String));
						Assert.equals('y', (r : String));
					case null, _: Assert.fail('expected Add body');
				}
			case null, _: Assert.fail('expected ParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `(x:Int) => x` -> typed param lambda. */
	public function testTypedParamLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x:Int) => x; }');
		switch decl.init {
			case ParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
				Assert.notNull(lambda.params[0].type);
			case null, _: Assert.fail('expected ParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `(x:Int, y:String) => x` -> multi typed params. */
	public function testMultiTypedParamLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x:Int, y:String) => x; }');
		switch decl.init {
			case ParenLambdaExpr(lambda):
				Assert.equals(2, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
				Assert.notNull(lambda.params[0].type);
				Assert.equals('y', (lambda.params[1].name : String));
				Assert.notNull(lambda.params[1].type);
			case null, _: Assert.fail('expected ParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `return (x) => x;` -> arrow in return. */
	public function testParenLambdaInReturn():Void {
		final ast:HxClassDecl = HaxeParser.parse('class C { function f():Int { return (x) => x; } }');
		final fn:HxFnDecl = expectFnMember(ast.members[0].member);
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ReturnStmt(ParenLambdaExpr(lambda)):
				Assert.equals(1, lambda.params.length);
			case null, _: Assert.fail('expected ReturnStmt(ParenLambdaExpr)');
		}
	}

	/** `(x + 1)` still parses as ParenExpr, not lambda. */
	public function testParenExprNotLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x + 1); }');
		switch decl.init {
			case ParenExpr(Add(_, _)): Assert.pass();
			case null, _: Assert.fail('expected ParenExpr(Add), got ${decl.init}');
		}
	}

	/** Lambda with whitespace around `=>`. */
	public function testLambdaWhitespace():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = ( x , y )  =>  x; }');
		switch decl.init {
			case ParenLambdaExpr(lambda):
				Assert.equals(2, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
				Assert.equals('y', (lambda.params[1].name : String));
			case null, _: Assert.fail('expected ParenLambdaExpr, got ${decl.init}');
		}
	}

	// ======== ArrayExpr ========

	/** `[1, 2, 3]` -> three-element array. */
	public function testSimpleArray():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var a:Int = [1, 2, 3]; }');
		switch decl.init {
			case ArrayExpr(elems):
				Assert.equals(3, elems.length);
				switch elems[0] {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
				switch elems[2] {
					case IntLit(v): Assert.equals(3, (v : Int));
					case null, _: Assert.fail('expected IntLit(3)');
				}
			case null, _: Assert.fail('expected ArrayExpr, got ${decl.init}');
		}
	}

	/** `[]` -> empty array. */
	public function testEmptyArray():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var a:Int = []; }');
		switch decl.init {
			case ArrayExpr(elems): Assert.equals(0, elems.length);
			case null, _: Assert.fail('expected ArrayExpr, got ${decl.init}');
		}
	}

	/** `[x]` -> single-element array. */
	public function testSingleElementArray():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var a:Int = [x]; }');
		switch decl.init {
			case ArrayExpr(elems):
				Assert.equals(1, elems.length);
				switch elems[0] {
					case IdentExpr(v): Assert.equals('x', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ArrayExpr, got ${decl.init}');
		}
	}

	/** `[1, 2, 3][0]` -> IndexAccess(ArrayExpr, IntLit). */
	public function testArrayThenIndex():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var a:Int = [1, 2, 3][0]; }');
		switch decl.init {
			case IndexAccess(ArrayExpr(elems), IntLit(idx)):
				Assert.equals(3, elems.length);
				Assert.equals(0, (idx : Int));
			case null, _: Assert.fail('expected IndexAccess(ArrayExpr, IntLit), got ${decl.init}');
		}
	}

	// ======== Map literals ========

	/** `[k => v]` -> ArrayExpr([Arrow(k, v)]). */
	public function testSingleEntryMap():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var m:Int = [k => v]; }');
		switch decl.init {
			case ArrayExpr(elems):
				Assert.equals(1, elems.length);
				switch elems[0] {
					case Arrow(IdentExpr(k), IdentExpr(v)):
						Assert.equals('k', (k : String));
						Assert.equals('v', (v : String));
					case null, _: Assert.fail('expected Arrow');
				}
			case null, _: Assert.fail('expected ArrayExpr, got ${decl.init}');
		}
	}

	/** `[1 => "a", 2 => "b"]` -> two-entry map. */
	public function testMultiEntryMap():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var m:Int = [1 => "a", 2 => "b"]; }');
		switch decl.init {
			case ArrayExpr(elems):
				Assert.equals(2, elems.length);
				switch elems[0] {
					case Arrow(IntLit(k), DoubleStringExpr(_)):
						Assert.equals(1, (k : Int));
					case null, _: Assert.fail('expected Arrow in first entry');
				}
				switch elems[1] {
					case Arrow(IntLit(k), DoubleStringExpr(_)):
						Assert.equals(2, (k : Int));
					case null, _: Assert.fail('expected Arrow in second entry');
				}
			case null, _: Assert.fail('expected ArrayExpr, got ${decl.init}');
		}
	}

	// ======== Module integration ========

	/** Arrow and array parsed through module root. */
	public function testArrowInModule():Void {
		final source:String = 'class A { var f:Int = x => x; } class B { var a:Int = [1, 2]; }';
		final mod:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(2, mod.decls.length);
		final a:HxClassDecl = expectClassDecl(mod.decls[0]);
		final b:HxClassDecl = expectClassDecl(mod.decls[1]);
		final va:HxVarDecl = expectVarMember(a.members[0].member);
		final vb:HxVarDecl = expectVarMember(b.members[0].member);
		switch va.init {
			case Arrow(_, _): Assert.pass();
			case null, _: Assert.fail('expected Arrow');
		}
		switch vb.init {
			case ArrayExpr(elems): Assert.equals(2, elems.length);
			case null, _: Assert.fail('expected ArrayExpr');
		}
	}

	/** `[(x) => x, (y) => y]` -> array of paren lambdas. */
	public function testArrayOfLambdas():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var a:Int = [(x) => x, (y) => y]; }');
		switch decl.init {
			case ArrayExpr(elems):
				Assert.equals(2, elems.length);
				switch elems[0] {
					case ParenLambdaExpr(l): Assert.equals('x', (l.params[0].name : String));
					case null, _: Assert.fail('expected ParenLambdaExpr in first');
				}
				switch elems[1] {
					case ParenLambdaExpr(l): Assert.equals('y', (l.params[0].name : String));
					case null, _: Assert.fail('expected ParenLambdaExpr in second');
				}
			case null, _: Assert.fail('expected ArrayExpr, got ${decl.init}');
		}
	}

	// ======== Rejection / disambiguation ========

	/** `arrowed` is just an identifier, not an arrow. */
	public function testWordBoundaryArrowed():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Int = arrowed; }');
		switch decl.init {
			case IdentExpr(v): Assert.equals('arrowed', (v : String));
			case null, _: Assert.fail('expected IdentExpr');
		}
	}

	/** Unclosed array `[1, 2` -> rejection. */
	public function testRejectsUnclosedArray():Void {
		Assert.raises(() -> HaxeParser.parse('class C { var a:Int = [1, 2; }'), ParseError);
	}
}
