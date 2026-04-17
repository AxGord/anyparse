package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxCatchClause;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxDoWhileStmt;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxTryCatchStmt;
import anyparse.runtime.ParseError;

/**
 * Tests for slice mu_2: throw, do-while, and try-catch statements.
 *
 * Throw: zero Lowering changes — Case 3 with `@:kw` + `@:trail`.
 *
 * Do-while: one Lowering change (D50) — `@:kw` and `@:lead` on the
 * same non-Star, non-optional struct field now both emit sequentially.
 * First consumer: `HxDoWhileStmt.cond` (`@:kw('while') @:lead('(')
 * @:trail(')')`).
 *
 * Try-catch: zero additional Lowering changes. `@:tryparse` (D49) on
 * `catches` array, `@:kw('catch') @:lead('(')` (D50) on
 * `HxCatchClause.name`.
 */
class HxDoWhileThrowTryCatchSliceTest extends HxTestHelpers {

	/** Parse function body statements from a single-function class. */
	private function parseBody(source:String):Array<HxStatement> {
		final fn:HxFnDecl = parseSingleFnDecl(source);
		return fn.body;
	}

	/** Extract first statement as ThrowStmt expression. */
	private function parseThrow(source:String):HxExpr {
		final body:Array<HxStatement> = parseBody(source);
		Assert.equals(1, body.length);
		return switch body[0] {
			case ThrowStmt(expr): expr;
			case null, _: throw 'expected ThrowStmt';
		};
	}

	/** Extract first statement as DoWhileStmt. */
	private function parseDoWhile(source:String):HxDoWhileStmt {
		final body:Array<HxStatement> = parseBody(source);
		Assert.equals(1, body.length);
		return switch body[0] {
			case DoWhileStmt(stmt): stmt;
			case null, _: throw 'expected DoWhileStmt';
		};
	}

	/** Extract first statement as TryCatchStmt. */
	private function parseTryCatch(source:String):HxTryCatchStmt {
		final body:Array<HxStatement> = parseBody(source);
		Assert.equals(1, body.length);
		return switch body[0] {
			case TryCatchStmt(stmt): stmt;
			case null, _: throw 'expected TryCatchStmt';
		};
	}

	// ---- Throw tests ----

	public function testThrowSmoke():Void {
		final expr:HxExpr = parseThrow('class C { function f():Void { throw x; } }');
		switch expr {
			case IdentExpr(v): Assert.equals('x', (v : String));
			case null, _: Assert.fail('expected IdentExpr');
		}
	}

	public function testThrowExpression():Void {
		final expr:HxExpr = parseThrow('class C { function f():Void { throw a + b; } }');
		switch expr {
			case Add(left, right):
				switch left {
					case IdentExpr(v): Assert.equals('a', (v : String));
					case null, _: Assert.fail('expected IdentExpr left');
				}
				switch right {
					case IdentExpr(v): Assert.equals('b', (v : String));
					case null, _: Assert.fail('expected IdentExpr right');
				}
			case null, _: Assert.fail('expected Add');
		}
	}

	public function testThrowInBlock():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { { throw x; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case BlockStmt(stmts):
				Assert.equals(1, stmts.length);
				switch stmts[0] {
					case ThrowStmt(expr):
						switch expr {
							case IdentExpr(v): Assert.equals('x', (v : String));
							case null, _: Assert.fail('expected IdentExpr');
						}
					case null, _: Assert.fail('expected ThrowStmt');
				}
			case null, _: Assert.fail('expected BlockStmt');
		}
	}

	public function testThrowInModule():Void {
		final module:HxModule = HaxeModuleParser.parse('class C { function f():Void { throw 42; } }');
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, cls.members.length);
		final fn:HxFnDecl = expectFnMember(cls.members[0].member);
		Assert.equals(1, fn.body.length);
		switch fn.body[0] {
			case ThrowStmt(expr):
				switch expr {
					case IntLit(v): Assert.equals(42, (v : Int));
					case null, _: Assert.fail('expected IntLit');
				}
			case null, _: Assert.fail('expected ThrowStmt');
		}
	}

	public function testWordBoundaryThrowing():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { throwing; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case IdentExpr(v): Assert.equals('throwing', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	// ---- Do-while tests ----

	public function testDoWhileSmoke():Void {
		final dw:HxDoWhileStmt = parseDoWhile('class C { function f():Void { do { x; } while (y); } }');
		switch dw.body {
			case BlockStmt(stmts):
				Assert.equals(1, stmts.length);
				switch stmts[0] {
					case ExprStmt(expr):
						switch expr {
							case IdentExpr(v): Assert.equals('x', (v : String));
							case null, _: Assert.fail('expected IdentExpr');
						}
					case null, _: Assert.fail('expected ExprStmt');
				}
			case null, _: Assert.fail('expected BlockStmt body');
		}
		switch dw.cond {
			case IdentExpr(v): Assert.equals('y', (v : String));
			case null, _: Assert.fail('expected IdentExpr cond');
		}
	}

	public function testDoWhileSingleStatement():Void {
		final dw:HxDoWhileStmt = parseDoWhile('class C { function f():Void { do x = 1; while (y); } }');
		switch dw.body {
			case ExprStmt(expr):
				switch expr {
					case Assign(left, right):
						switch left {
							case IdentExpr(v): Assert.equals('x', (v : String));
							case null, _: Assert.fail('expected IdentExpr');
						}
						switch right {
							case IntLit(v): Assert.equals(1, (v : Int));
							case null, _: Assert.fail('expected IntLit');
						}
					case null, _: Assert.fail('expected Assign');
				}
			case null, _: Assert.fail('expected ExprStmt body');
		}
		switch dw.cond {
			case IdentExpr(v): Assert.equals('y', (v : String));
			case null, _: Assert.fail('expected IdentExpr cond');
		}
	}

	public function testDoWhileExpressionCond():Void {
		final dw:HxDoWhileStmt = parseDoWhile('class C { function f():Void { do { } while (a + b); } }');
		switch dw.body {
			case BlockStmt(stmts): Assert.equals(0, stmts.length);
			case null, _: Assert.fail('expected BlockStmt');
		}
		switch dw.cond {
			case Add(left, right):
				switch left {
					case IdentExpr(v): Assert.equals('a', (v : String));
					case null, _: Assert.fail('expected IdentExpr left');
				}
				switch right {
					case IdentExpr(v): Assert.equals('b', (v : String));
					case null, _: Assert.fail('expected IdentExpr right');
				}
			case null, _: Assert.fail('expected Add');
		}
	}

	public function testDoWhileNested():Void {
		final dw:HxDoWhileStmt = parseDoWhile(
			'class C { function f():Void { do do x; while (a); while (b); } }'
		);
		switch dw.body {
			case DoWhileStmt(inner):
				switch inner.body {
					case ExprStmt(expr):
						switch expr {
							case IdentExpr(v): Assert.equals('x', (v : String));
							case null, _: Assert.fail('expected IdentExpr');
						}
					case null, _: Assert.fail('expected ExprStmt inner body');
				}
				switch inner.cond {
					case IdentExpr(v): Assert.equals('a', (v : String));
					case null, _: Assert.fail('expected IdentExpr inner cond');
				}
			case null, _: Assert.fail('expected DoWhileStmt inner');
		}
		switch dw.cond {
			case IdentExpr(v): Assert.equals('b', (v : String));
			case null, _: Assert.fail('expected IdentExpr outer cond');
		}
	}

	public function testDoWhileWhitespace():Void {
		final dw:HxDoWhileStmt = parseDoWhile(
			'class C { function f():Void { do  {  x ;  }  while  (  y  )  ; } }'
		);
		switch dw.body {
			case BlockStmt(stmts): Assert.equals(1, stmts.length);
			case null, _: Assert.fail('expected BlockStmt');
		}
		switch dw.cond {
			case IdentExpr(v): Assert.equals('y', (v : String));
			case null, _: Assert.fail('expected IdentExpr');
		}
	}

	public function testWordBoundaryDoable():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { doable; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case IdentExpr(v): Assert.equals('doable', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	// ---- Try-catch tests ----

	public function testTryCatchSmoke():Void {
		final tc:HxTryCatchStmt = parseTryCatch(
			'class C { function f():Void { try { x; } catch (e:E) { y; } } }'
		);
		switch tc.body {
			case BlockStmt(stmts):
				Assert.equals(1, stmts.length);
				switch stmts[0] {
					case ExprStmt(expr):
						switch expr {
							case IdentExpr(v): Assert.equals('x', (v : String));
							case null, _: Assert.fail('expected IdentExpr');
						}
					case null, _: Assert.fail('expected ExprStmt');
				}
			case null, _: Assert.fail('expected BlockStmt body');
		}
		Assert.equals(1, tc.catches.length);
		final c:HxCatchClause = tc.catches[0];
		Assert.equals('e', (c.name : String));
		Assert.equals('E', (c.type.name : String));
		switch c.body {
			case BlockStmt(stmts):
				Assert.equals(1, stmts.length);
			case null, _: Assert.fail('expected BlockStmt catch body');
		}
	}

	public function testTryCatchSingleStatement():Void {
		final tc:HxTryCatchStmt = parseTryCatch(
			'class C { function f():Void { try x; catch (e:E) y; } }'
		);
		switch tc.body {
			case ExprStmt(expr):
				switch expr {
					case IdentExpr(v): Assert.equals('x', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ExprStmt body');
		}
		Assert.equals(1, tc.catches.length);
		switch tc.catches[0].body {
			case ExprStmt(expr):
				switch expr {
					case IdentExpr(v): Assert.equals('y', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ExprStmt catch body');
		}
	}

	public function testMultipleCatches():Void {
		final tc:HxTryCatchStmt = parseTryCatch(
			'class C { function f():Void { try { } catch (e1:E1) { a; } catch (e2:E2) { b; } } }'
		);
		Assert.equals(2, tc.catches.length);
		Assert.equals('e1', (tc.catches[0].name : String));
		Assert.equals('E1', (tc.catches[0].type.name : String));
		Assert.equals('e2', (tc.catches[1].name : String));
		Assert.equals('E2', (tc.catches[1].type.name : String));
	}

	public function testTryCatchNested():Void {
		final tc:HxTryCatchStmt = parseTryCatch(
			'class C { function f():Void { try { } catch (e:E) { try { } catch (e2:E2) { } } } }'
		);
		Assert.equals(1, tc.catches.length);
		switch tc.catches[0].body {
			case BlockStmt(stmts):
				Assert.equals(1, stmts.length);
				switch stmts[0] {
					case TryCatchStmt(inner):
						Assert.equals(1, inner.catches.length);
						Assert.equals('e2', (inner.catches[0].name : String));
					case null, _: Assert.fail('expected TryCatchStmt');
				}
			case null, _: Assert.fail('expected BlockStmt');
		}
	}

	public function testTryCatchInModule():Void {
		final module:HxModule = HaxeModuleParser.parse(
			'class C { function f():Void { try { } catch (ex:Exception) { } } }'
		);
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		final fn:HxFnDecl = expectFnMember(cls.members[0].member);
		Assert.equals(1, fn.body.length);
		switch fn.body[0] {
			case TryCatchStmt(tc):
				Assert.equals(1, tc.catches.length);
				Assert.equals('ex', (tc.catches[0].name : String));
				Assert.equals('Exception', (tc.catches[0].type.name : String));
			case null, _: Assert.fail('expected TryCatchStmt');
		}
	}

	public function testTryCatchWhitespace():Void {
		final tc:HxTryCatchStmt = parseTryCatch(
			'class C { function f():Void { try  {  }  catch  (  e  :  E  )  {  }  } }'
		);
		Assert.equals(1, tc.catches.length);
		Assert.equals('e', (tc.catches[0].name : String));
		Assert.equals('E', (tc.catches[0].type.name : String));
	}

	public function testWordBoundaryTrying():Void {
		final body:Array<HxStatement> = parseBody('class C { function f():Void { trying; } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case IdentExpr(v): Assert.equals('trying', (v : String));
					case null, _: Assert.fail('expected IdentExpr');
				}
			case null, _: Assert.fail('expected ExprStmt');
		}
	}

	public function testWordBoundaryCatching():Void {
		final tc:HxTryCatchStmt = parseTryCatch(
			'class C { function f():Void { try { catching; } catch (e:E) { } } }'
		);
		switch tc.body {
			case BlockStmt(stmts):
				Assert.equals(1, stmts.length);
				switch stmts[0] {
					case ExprStmt(expr):
						switch expr {
							case IdentExpr(v): Assert.equals('catching', (v : String));
							case null, _: Assert.fail('expected IdentExpr');
						}
					case null, _: Assert.fail('expected ExprStmt');
				}
			case null, _: Assert.fail('expected BlockStmt');
		}
	}

	public function testThrowInCatchBody():Void {
		final tc:HxTryCatchStmt = parseTryCatch(
			'class C { function f():Void { try { } catch (e:E) { throw e; } } }'
		);
		Assert.equals(1, tc.catches.length);
		switch tc.catches[0].body {
			case BlockStmt(stmts):
				Assert.equals(1, stmts.length);
				switch stmts[0] {
					case ThrowStmt(expr):
						switch expr {
							case IdentExpr(v): Assert.equals('e', (v : String));
							case null, _: Assert.fail('expected IdentExpr');
						}
					case null, _: Assert.fail('expected ThrowStmt');
				}
			case null, _: Assert.fail('expected BlockStmt');
		}
	}
}
