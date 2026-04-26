package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxObjectField;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Tests for slice ω-block-expr: block-form expression atom in `HxExpr`.
 *
 * New grammar:
 *  - `HxExpr.BlockExpr(stmts:Array<HxStatement>)` — `{stmt1; stmt2; ...}`
 *    in expression position. Same shape as `HxStatement.BlockStmt`
 *    (Star with `@:lead('{') @:trail('}') @:trivia`, no sep).
 *  - Placed AFTER `ObjectLit` so the strict `key: value` shape is tried
 *    first; on inner-shape failure, `tryBranch` rolls back and
 *    `BlockExpr` is tried next. Empty `{}` is still consumed by
 *    `ObjectLit` (zero-field Star).
 *
 * Zero Lowering changes — Case 4 (Star Array<Ref> with lead/trail/no-sep)
 * already covered the shape; the macro pipeline auto-generated parser
 * and writer.
 */
class HxBlockExprSliceTest extends HxTestHelpers {

	// ======== ObjectLit regression — must still win for key:value shape ========

	public function testEmptyBracesStaysObjectLit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {}; }');
		switch decl.init {
			case ObjectLit(lit): Assert.equals(0, lit.fields.length);
			case null, _: Assert.fail('expected ObjectLit({}), got ${decl.init}');
		}
	}

	public function testSingleFieldStaysObjectLit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {a: 1}; }');
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals(1, lit.fields.length);
				final field:HxObjectField = lit.fields[0];
				Assert.equals('a', (field.name : String));
			case null, _: Assert.fail('expected ObjectLit({a:1})');
		}
	}

	public function testMultipleFieldsStaysObjectLit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = {a: 1, b: 2}; }');
		switch decl.init {
			case ObjectLit(lit): Assert.equals(2, lit.fields.length);
			case null, _: Assert.fail('expected ObjectLit(2 fields)');
		}
	}

	// ======== BlockExpr — new branch ========

	public function testBlockExprSingleExprStmt():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = { trace("hi"); }; }');
		switch decl.init {
			case BlockExpr(stmts):
				Assert.equals(1, stmts.length);
				switch stmts[0] {
					case ExprStmt(Call(IdentExpr(name), _)): Assert.equals('trace', (name : String));
					case null, _: Assert.fail('expected ExprStmt(Call(trace,...))');
				}
			case null, _: Assert.fail('expected BlockExpr, got ${decl.init}');
		}
	}

	public function testBlockExprVarStmtThenExprStmt():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Int = { var y = 1; y; }; }');
		switch decl.init {
			case BlockExpr(stmts):
				Assert.equals(2, stmts.length);
				switch stmts[0] {
					case VarStmt(d): Assert.equals('y', (d.name : String));
					case null, _: Assert.fail('expected VarStmt');
				}
				switch stmts[1] {
					case ExprStmt(IdentExpr(name)): Assert.equals('y', (name : String));
					case null, _: Assert.fail('expected ExprStmt(IdentExpr(y))');
				}
			case null, _: Assert.fail('expected BlockExpr');
		}
	}

	public function testBlockExprWithIfStmt():Void {
		final source:String = 'class C { var x:Int = { if (cond) trace(1); 0; }; }';
		final decl:HxVarDecl = parseSingleVarDecl(source);
		switch decl.init {
			case BlockExpr(stmts):
				Assert.equals(2, stmts.length);
				switch stmts[0] {
					case IfStmt(_): Assert.pass();
					case null, _: Assert.fail('expected IfStmt as first stmt');
				}
			case null, _: Assert.fail('expected BlockExpr, got ${decl.init}');
		}
	}

	public function testBlockExprWithSwitchStmt():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Int { return { switch (v) { case 1: 1; case _: 0; } }; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case ReturnStmt(BlockExpr(blockStmts)):
				Assert.equals(1, blockStmts.length);
				switch blockStmts[0] {
					case SwitchStmt(_): Assert.pass();
					case null, _: Assert.fail('expected SwitchStmt inside BlockExpr');
				}
			case null, _: Assert.fail('expected ReturnStmt(BlockExpr), got ${stmts[0]}');
		}
	}

	public function testBlockExprAsReturnValue():Void {
		final fn:HxFnDecl = parseSingleFnDecl('class C { function m():Int { return { var y = 1; y; }; } }');
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		switch stmts[0] {
			case ReturnStmt(BlockExpr(blockStmts)):
				Assert.equals(2, blockStmts.length);
			case null, _: Assert.fail('expected ReturnStmt(BlockExpr), got ${stmts[0]}');
		}
	}

	public function testBlockExprAsCallArgument():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x:Dynamic = f({ var y = 1; y; }); }');
		switch decl.init {
			case Call(IdentExpr(fname), [BlockExpr(stmts)]):
				Assert.equals('f', (fname : String));
				Assert.equals(2, stmts.length);
			case null, _: Assert.fail('expected Call(f, [BlockExpr]), got ${decl.init}');
		}
	}

	// ======== Round-trip — parsed AST round-trips through the writer ========

	public function testBlockExprRoundTrip():Void {
		roundTrip('class C { var x:Int = { var y = 1; y; }; }', 'block-expr var init');
		roundTrip('class C { function m():Int { return { var y = 1; y; }; } }', 'block-expr return');
		roundTrip('class C { var x:Dynamic = f({ trace(1); }); }', 'block-expr arg');
	}

	public function testObjectLitRoundTripPreserved():Void {
		roundTrip('class C { var x:Dynamic = {}; }', 'empty object');
		roundTrip('class C { var x:Dynamic = {a: 1, b: 2}; }', 'two-field object');
	}

}
