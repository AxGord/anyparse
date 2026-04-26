package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Tests for slice ω-try-expr: try-catch in expression position.
 *
 * New grammar:
 *  - `HxExpr.TryExpr(stmt:HxTryCatchExpr)` — `@:kw('try')` atom in
 *    `HxExpr`, parallel to `IfExpr` / `SwitchExpr`. Placed among the
 *    keyword atoms so the `try` keyword commits the branch before the
 *    `IdentExpr` catch-all is tried.
 *  - `HxTryCatchExpr` typedef — body + catches, both `HxExpr` (mirror
 *    of `HxTryCatchStmt` whose bodies are `HxStatement`).
 *  - `HxCatchClauseExpr` typedef — mirror of `HxCatchClause` with
 *    `body:HxExpr`.
 *
 * Statement-position `try { ... } catch (...) { ... }` is unaffected:
 * `HxStatement.TryCatchStmt` is tried before `ExprStmt` in the
 * statement enum-branch dispatch loop, so the `try` keyword is
 * consumed by the statement branch first.
 */
class HxTryExprSliceTest extends HxTestHelpers {

	// ======== Bare-expression bodies ========

	/** `var x = try foo() catch (e:Any) null;` — minimal expression form. */
	public function testTryExprSimpleCatch():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = try foo() catch (e:Any) null; }');
		switch decl.init {
			case TryExpr(stmt):
				switch stmt.body {
					case Call(IdentExpr(name), []): Assert.equals('foo', (name : String));
					case _: Assert.fail('expected Call(foo,[]), got ${stmt.body}');
				}
				Assert.equals(1, stmt.catches.length);
				Assert.equals('e', (stmt.catches[0].name : String));
				switch stmt.catches[0].body {
					case NullLit: Assert.pass();
					case _: Assert.fail('expected NullLit catch body');
				}
			case _: Assert.fail('expected TryExpr, got ${decl.init}');
		}
	}

	/** `try Xml.parse(data).firstElement() catch (_:Any) null` — body is a postfix chain. */
	public function testTryExprFieldAccessBody():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = try Xml.parse(data).firstElement() catch (_:Any) null; }');
		switch decl.init {
			case TryExpr(stmt):
				switch stmt.body {
					case Call(FieldAccess(_, fname), []):
						Assert.equals('firstElement', (fname : String));
					case _: Assert.fail('expected Call(FieldAccess(...), []) body');
				}
				Assert.equals(1, stmt.catches.length);
			case _: Assert.fail('expected TryExpr');
		}
	}

	/** Multi-catch `try x catch (e:A) y catch (e:B) z`. */
	public function testTryExprMultiCatch():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = try a catch (e:A) b catch (f:B) c; }');
		switch decl.init {
			case TryExpr(stmt):
				Assert.equals(2, stmt.catches.length);
				Assert.equals('e', (stmt.catches[0].name : String));
				Assert.equals('f', (stmt.catches[1].name : String));
			case _: Assert.fail('expected TryExpr');
		}
	}

	// ======== Block-form bodies (BlockExpr absorbs `{ ... }` in expression position) ========

	/** `try { foo(); } catch (e:Any) { bar; }` — both bodies are BlockExpr. */
	public function testTryExprBlockBodies():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = try { foo(); } catch (e:Any) { bar; }; }');
		switch decl.init {
			case TryExpr(stmt):
				switch stmt.body {
					case BlockExpr(_): Assert.pass();
					case _: Assert.fail('expected BlockExpr body, got ${stmt.body}');
				}
				Assert.equals(1, stmt.catches.length);
				switch stmt.catches[0].body {
					case BlockExpr(_): Assert.pass();
					case _: Assert.fail('expected BlockExpr catch body');
				}
			case _: Assert.fail('expected TryExpr');
		}
	}

	// ======== Containment in larger expressions ========

	/** `return try foo() catch (e:Any) null;` — TryExpr as ReturnStmt's value. */
	public function testTryExprAsReturnValue():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Dynamic { return try foo() catch (e:Any) null; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case ReturnStmt(TryExpr(_)): Assert.pass();
			case _: Assert.fail('expected ReturnStmt(TryExpr), got ${stmts[0]}');
		}
	}

	/** `f(try a catch (e:Any) null)` — TryExpr as call argument. */
	public function testTryExprAsCallArgument():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = f(try a catch (e:Any) null); }');
		switch decl.init {
			case Call(IdentExpr(fname), [TryExpr(stmt)]):
				Assert.equals('f', (fname : String));
				Assert.equals(1, stmt.catches.length);
			case _: Assert.fail('expected Call(f, [TryExpr]), got ${decl.init}');
		}
	}

	// ======== Statement-form regression ========

	/** `try { ... } catch (...) { ... }` at statement level stays TryCatchStmt. */
	public function testStatementFormUnaffected():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Void { try { foo(); } catch (e:Any) { bar; } } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case TryCatchStmt(_): Assert.pass();
			case _: Assert.fail('expected TryCatchStmt at statement level, got ${stmts[0]}');
		}
	}

	// ======== Round-trip ========

	public function testRoundTripSimple():Void {
		roundTrip('class C { var x:Dynamic = try foo() catch (e:Any) null; }', 'try-expr simple');
	}

	public function testRoundTripFieldAccess():Void {
		roundTrip('class C { var x:Dynamic = try Xml.parse(data).firstElement() catch (_:Any) null; }', 'try-expr field-access');
	}

	public function testRoundTripBlockBody():Void {
		roundTrip('class C { var x:Dynamic = try { foo(); } catch (e:Any) { bar; }; }', 'try-expr block bodies');
	}

	public function testRoundTripReturn():Void {
		roundTrip('class C { function m():Dynamic { return try foo() catch (e:Any) null; } }', 'try-expr return');
	}

	public function testRoundTripStatementForm():Void {
		roundTrip('class C { function m():Void { try { foo(); } catch (e:Any) { bar; } } }', 'try-stmt regression');
	}

}
