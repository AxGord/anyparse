package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;
import anyparse.runtime.ParseError;

/**
 * Phase 3 function-body tests for the macro-generated Haxe parser.
 *
 * Validates the transition from `@:trail('{}')` (fixed empty braces) to
 * real statement bodies via `@:lead('{') @:trail('}') var
 * body:Array<HxStatement>`. This is the close-peek Star field pattern
 * already used by `HxClassDecl.members` — zero new Lowering concepts.
 *
 * `HxStatement` has three branches: `VarStmt` (`var ... ;`),
 * `ReturnStmt` (`return expr;`), and `ExprStmt` (`expr;` catch-all).
 * All three are Case 3 in `Lowering.lowerEnumBranch`.
 */
class HxBodySliceTest extends HxTestHelpers {

	public function testEmptyBody():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function bar():Void {} }');
		Assert.equals('bar', (decl.name : String));
		Assert.equals('Void', (decl.returnType.name : String));
		Assert.equals(0, fnBodyStmts(decl).length);
	}

	public function testSingleExprStmt():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Void { 1; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ExprStmt(expr):
				switch expr {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testReturnStmt():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Int { return 42; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ReturnStmt(value):
				switch value {
					case IntLit(v): Assert.equals(42, (v : Int));
					case null, _: Assert.fail('expected IntLit(42)');
				}
			case null, _: Assert.fail('expected ReturnStmt');
		}
	}

	public function testVarStmt():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Void { var x:Int = 1; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case VarStmt(vd):
				Assert.equals('x', (vd.name : String));
				Assert.equals('Int', (vd.type.name : String));
				switch vd.init {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
			case null, _: Assert.fail('expected VarStmt');
		}
	}

	public function testVarWithoutInit():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Void { var x:Int; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case VarStmt(vd):
				Assert.equals('x', (vd.name : String));
				Assert.equals('Int', (vd.type.name : String));
				Assert.isNull(vd.init);
			case null, _: Assert.fail('expected VarStmt');
		}
	}

	public function testMixedStatements():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Int { var x:Int = 1; x; return x; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(3, stmts.length);
		switch stmts[0] {
			case VarStmt(vd): Assert.equals('x', (vd.name : String));
			case null, _: Assert.fail('expected VarStmt');
		}
		switch stmts[1] {
			case ExprStmt(expr):
				switch expr {
					case IdentExpr(v): Assert.equals('x', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
		switch stmts[2] {
			case ReturnStmt(value):
				switch value {
					case IdentExpr(v): Assert.equals('x', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ReturnStmt');
		}
	}

	public function testExprWithOperators():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Void { a + b; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ExprStmt(expr):
				switch expr {
					case Add(left, right):
						switch left {
							case IdentExpr(v): Assert.equals('a', (v : String));
							case null, _: Assert.fail('expected IdentExpr(a)');
						}
						switch right {
							case IdentExpr(v): Assert.equals('b', (v : String));
							case null, _: Assert.fail('expected IdentExpr(b)');
						}
					case null, _: Assert.fail('expected Add');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testMethodCall():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Void { foo(); } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ExprStmt(expr):
				switch expr {
					case Call(operand, args):
						switch operand {
							case IdentExpr(v): Assert.equals('foo', (v : String));
							case null, _: Assert.fail('expected IdentExpr(foo)');
						}
						Assert.equals(0, args.length);
					case null, _: Assert.fail('expected Call');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testMethodCallChain():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Void { a.b(); } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ExprStmt(expr):
				switch expr {
					case Call(operand, args):
						switch operand {
							case FieldAccess(inner, field):
								switch inner {
									case IdentExpr(v): Assert.equals('a', (v : String));
									case null, _: Assert.fail('expected IdentExpr(a)');
								}
								Assert.equals('b', (field : String));
							case null, _: Assert.fail('expected FieldAccess');
						}
						Assert.equals(0, args.length);
					case null, _: Assert.fail('expected Call');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testAssignmentStmt():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Void { x = 1; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ExprStmt(expr):
				switch expr {
					case Assign(left, right):
						switch left {
							case IdentExpr(v): Assert.equals('x', (v : String));
							case null, _: Assert.fail('expected IdentExpr(x)');
						}
						switch right {
							case IntLit(v): Assert.equals(1, (v : Int));
							case null, _: Assert.fail('expected IntLit(1)');
						}
					case null, _: Assert.fail('expected Assign');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testMultipleExprStmts():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Void { 1; 2; 3; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(3, stmts.length);
		switch stmts[0] {
			case ExprStmt(IntLit(v)): Assert.equals(1, (v : Int));
			case null, _: Assert.fail('expected ExprStmt(IntLit(1))');
		}
		switch stmts[1] {
			case ExprStmt(IntLit(v)): Assert.equals(2, (v : Int));
			case null, _: Assert.fail('expected ExprStmt(IntLit(2))');
		}
		switch stmts[2] {
			case ExprStmt(IntLit(v)): Assert.equals(3, (v : Int));
			case null, _: Assert.fail('expected ExprStmt(IntLit(3))');
		}
	}

	public function testReturnExpression():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Int { return a + 1; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ReturnStmt(value):
				switch value {
					case Add(left, right):
						switch left {
							case IdentExpr(v): Assert.equals('a', (v : String));
							case null, _: Assert.fail('expected IdentExpr(a)');
						}
						switch right {
							case IntLit(v): Assert.equals(1, (v : Int));
							case null, _: Assert.fail('expected IntLit(1)');
						}
					case null, _: Assert.fail('expected Add');
				}
			case null, _: Assert.fail('expected ReturnStmt');
		}
	}

	public function testWhitespaceTolerance():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f():Void {  var  x : Int ;  1 ;  } }');
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(2, stmts.length);
		switch stmts[0] {
			case VarStmt(vd): Assert.equals('x', (vd.name : String));
			case null, _: Assert.fail('expected VarStmt');
		}
		switch stmts[1] {
			case ExprStmt(IntLit(v)): Assert.equals(1, (v : Int));
			case null, _: Assert.fail('expected ExprStmt(IntLit(1))');
		}
	}

	public function testRejectsMissingSemicolon():Void {
		Assert.raises(() -> HaxeParser.parse('class Foo { function f():Void { 1 } }'), ParseError);
	}

	public function testRejectsUnclosedBrace():Void {
		Assert.raises(() -> HaxeParser.parse('class Foo { function f():Void { 1;'), ParseError);
	}

	public function testBodyThroughModuleRoot():Void {
		final source:String = 'class A { function f():Int { return 1; } } class B { function g():Void { x; } }';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(2, module.decls.length);

		final a:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, a.members.length);
		final af:HxFnDecl = expectFnMember(a.members[0].member);
		Assert.equals('f', (af.name : String));
		final aStmts:Array<HxStatement> = fnBodyStmts(af);
		Assert.equals(1, aStmts.length);
		switch aStmts[0] {
			case ReturnStmt(IntLit(v)): Assert.equals(1, (v : Int));
			case null, _: Assert.fail('expected ReturnStmt(IntLit(1))');
		}

		final b:HxClassDecl = expectClassDecl(module.decls[1]);
		Assert.equals(1, b.members.length);
		final bf:HxFnDecl = expectFnMember(b.members[0].member);
		Assert.equals('g', (bf.name : String));
		final bStmts:Array<HxStatement> = fnBodyStmts(bf);
		Assert.equals(1, bStmts.length);
		switch bStmts[0] {
			case ExprStmt(IdentExpr(v)): Assert.equals('x', (v : String));
			case null, _: Assert.fail('expected ExprStmt(IdentExpr(x))');
		}
	}

	public function testFnDeclNoReturnType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function main() {} }');
		Assert.equals('main', (decl.name : String));
		Assert.isNull(decl.returnType);
		Assert.equals(0, fnBodyStmts(decl).length);
	}

	public function testFnDeclNoReturnTypeWithBody():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function main() { return 1; } }');
		Assert.equals('main', (decl.name : String));
		Assert.isNull(decl.returnType);
		final stmts:Array<HxStatement> = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ReturnStmt(IntLit(v)): Assert.equals(1, (v : Int));
			case null, _: Assert.fail('expected ReturnStmt(IntLit(1))');
		}
	}

	public function testFnDeclOptionalReturnTypeStillAcceptsExplicit():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function main():Void {} }');
		Assert.equals('main', (decl.name : String));
		Assert.equals('Void', (decl.returnType.name : String));
	}
}
