package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxIfStmt;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.grammar.haxe.HxWhileStmt;

/**
 * Tests for slice κ₁: ??= operator, if/else, while, and block statements.
 *
 * New concept: `@:optional @:kw` on struct Ref fields — the keyword
 * is the commit point for the optional branch (matchKw instead of
 * matchLit). Used by `HxIfStmt.elseBody`.
 *
 * ??= is purely additive (one ctor, zero pipeline changes). BlockStmt
 * uses existing Case 4 pattern. WhileStmt uses only existing patterns.
 */
class HxControlFlowSliceTest extends HxTestHelpers {

	/** Parse function body statements from a single-function class. */
	private function parseBody(source:String):Array<HxStatement> {
		final fn:HxFnDecl = parseSingleFnDecl(source);
		return fn.body;
	}

	// --- ??= operator ---

	public function testNullCoalAssignSmoke():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Int = a ??= b; }');
		switch decl.init {
			case NullCoalAssign(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _: Assert.fail('expected NullCoalAssign(IdentExpr, IdentExpr), got ${decl.init}');
		}
	}

	public function testNullCoalAssignRightAssoc():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Int = a ??= b ??= c; }');
		switch decl.init {
			case NullCoalAssign(IdentExpr(l), NullCoalAssign(IdentExpr(m), IdentExpr(r))):
				Assert.equals('a', (l : String));
				Assert.equals('b', (m : String));
				Assert.equals('c', (r : String));
			case null, _: Assert.fail('expected NullCoalAssign(a, NullCoalAssign(b, c)), got ${decl.init}');
		}
	}

	public function testNullCoalStillWorks():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Int = a ?? b; }');
		switch decl.init {
			case NullCoal(_, _): Assert.pass();
			case null, _: Assert.fail('expected NullCoal, got ${decl.init}');
		}
	}

	// --- if statement ---

	public function testIfSingleStatement():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { if (x) a = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.cond {
					case IdentExpr(v): Assert.equals('x', (v : String));
					case null, _: Assert.fail('expected IdentExpr cond');
				}
				switch stmt.thenBody {
					case ExprStmt(_): Assert.pass();
					case null, _: Assert.fail('expected ExprStmt then');
				}
				Assert.isNull(stmt.elseBody);
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	public function testIfBlockBody():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { if (x) { a = 1; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case BlockStmt(stmts): Assert.equals(1, stmts.length);
					case null, _: Assert.fail('expected BlockStmt then');
				}
				Assert.isNull(stmt.elseBody);
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	public function testIfElseSingleStatements():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { if (x) a = 1; else b = 2; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case ExprStmt(_): Assert.pass();
					case null, _: Assert.fail('expected ExprStmt then');
				}
				switch stmt.elseBody {
					case ExprStmt(_): Assert.pass();
					case null, _: Assert.fail('expected ExprStmt else');
				}
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	public function testIfElseBlocks():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { if (x) { a = 1; } else { b = 2; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case BlockStmt(stmts): Assert.equals(1, stmts.length);
					case null, _: Assert.fail('expected BlockStmt then');
				}
				switch stmt.elseBody {
					case BlockStmt(stmts): Assert.equals(1, stmts.length);
					case null, _: Assert.fail('expected BlockStmt else');
				}
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	public function testIfElseIfElse():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():Void { if (a) x = 1; else if (b) x = 2; else x = 3; } }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.cond {
					case IdentExpr(v): Assert.equals('a', (v : String));
					case null, _: Assert.fail('expected IdentExpr a');
				}
				// else branch is another if
				switch stmt.elseBody {
					case IfStmt(inner):
						switch inner.cond {
							case IdentExpr(v): Assert.equals('b', (v : String));
							case null, _: Assert.fail('expected IdentExpr b');
						}
						switch inner.elseBody {
							case ExprStmt(_): Assert.pass();
							case null, _: Assert.fail('expected final else');
						}
					case null, _: Assert.fail('expected nested IfStmt');
				}
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	public function testIfExpressionCondition():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { if (a + b) x = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.cond {
					case Add(_, _): Assert.pass();
					case null, _: Assert.fail('expected Add in cond');
				}
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	public function testDanglingElse():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():Void { if (a) if (b) x = 1; else y = 2; } }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(outer):
				// else binds to inner if, not outer
				Assert.isNull(outer.elseBody);
				switch outer.thenBody {
					case IfStmt(inner):
						Assert.notNull(inner.elseBody);
					case null, _: Assert.fail('expected inner IfStmt');
				}
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	public function testIfWhitespace():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():Void {  if  (  x  )  a = 1 ;  else  b = 2 ;  } }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				Assert.notNull(stmt.elseBody);
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	// --- while statement ---

	public function testWhileSingleStatement():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { while (x) a = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case WhileStmt(stmt):
				switch stmt.cond {
					case IdentExpr(v): Assert.equals('x', (v : String));
					case null, _: Assert.fail('expected IdentExpr cond');
				}
				switch stmt.body {
					case ExprStmt(_): Assert.pass();
					case null, _: Assert.fail('expected ExprStmt body');
				}
			case null, _: Assert.fail('expected WhileStmt');
		}
	}

	public function testWhileBlockBody():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { while (x) { a = 1; b = 2; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case WhileStmt(stmt):
				switch stmt.body {
					case BlockStmt(stmts): Assert.equals(2, stmts.length);
					case null, _: Assert.fail('expected BlockStmt body');
				}
			case null, _: Assert.fail('expected WhileStmt');
		}
	}

	public function testWhileWhitespace():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():Void {  while  (  x  )  a = 1 ;  } }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case WhileStmt(_): Assert.pass();
			case null, _: Assert.fail('expected WhileStmt');
		}
	}

	// --- block statement ---

	public function testBlockInFunctionBody():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { { a = 1; b = 2; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case BlockStmt(stmts): Assert.equals(2, stmts.length);
			case null, _: Assert.fail('expected BlockStmt');
		}
	}

	public function testEmptyBlock():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { {} } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case BlockStmt(stmts): Assert.equals(0, stmts.length);
			case null, _: Assert.fail('expected BlockStmt');
		}
	}

	public function testNestedBlocks():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { { { a = 1; } } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case BlockStmt(outer):
				Assert.equals(1, outer.length);
				switch outer[0] {
					case BlockStmt(inner): Assert.equals(1, inner.length);
					case null, _: Assert.fail('expected inner BlockStmt');
				}
			case null, _: Assert.fail('expected outer BlockStmt');
		}
	}

	// --- integration ---

	public function testIfInModuleRoot():Void {
		final module:HxModule = HaxeModuleParser.parse(
			'class C { function f():Void { if (x) return 1; else return 2; } }'
		);
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		final fn:HxFnDecl = expectFnMember(cls.members[0].member);
		Assert.equals(1, fn.body.length);
		switch fn.body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case ReturnStmt(_): Assert.pass();
					case null, _: Assert.fail('expected ReturnStmt');
				}
				switch stmt.elseBody {
					case ReturnStmt(_): Assert.pass();
					case null, _: Assert.fail('expected ReturnStmt else');
				}
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	public function testMixedStatements():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():Void { var x:Int = 0; if (x) x = 1; while (x) x = x + 1; return x; } }'
		);
		Assert.equals(4, body.length);
		switch body[0] {
			case VarStmt(_): Assert.pass();
			case null, _: Assert.fail('expected VarStmt');
		}
		switch body[1] {
			case IfStmt(_): Assert.pass();
			case null, _: Assert.fail('expected IfStmt');
		}
		switch body[2] {
			case WhileStmt(_): Assert.pass();
			case null, _: Assert.fail('expected WhileStmt');
		}
		switch body[3] {
			case ReturnStmt(_): Assert.pass();
			case null, _: Assert.fail('expected ReturnStmt');
		}
	}

	public function testIfWithWhileBody():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():Void { if (a) while (b) x = 1; } }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case IfStmt(stmt):
				switch stmt.thenBody {
					case WhileStmt(_): Assert.pass();
					case null, _: Assert.fail('expected WhileStmt as if body');
				}
			case null, _: Assert.fail('expected IfStmt');
		}
	}

	public function testWordBoundaryIfx():Void {
		// "ifx" should not match "if" keyword
		final body:Array<HxStatement> = parseBody('class C { function f():Void { ifx = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(_): Assert.pass();
			case null, _: Assert.fail('expected ExprStmt (ifx is identifier)');
		}
	}

	public function testWordBoundaryWhiled():Void {
		// "whiled" should not match "while" keyword
		final body:Array<HxStatement> = parseBody('class C { function f():Void { whiled = 1; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(_): Assert.pass();
			case null, _: Assert.fail('expected ExprStmt (whiled is identifier)');
		}
	}
}
