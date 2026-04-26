package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxForExpr;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxWhileExpr;

/**
 * Tests for the ω-array-comp slice — `for` and `while` as expression-
 * position atoms in `HxExpr`, enabling Haxe array comprehension
 * (`[for (x in xs) bodyExpr]`, `[while (cond) bodyExpr]`) plus any
 * value-position for/while.
 *
 * Adds two new typedefs (`HxForExpr`, `HxWhileExpr`) — mirrors of
 * `HxForStmt`/`HxWhileStmt` with `body:HxExpr` instead of `HxStatement` —
 * and two new ctors in `HxExpr` (`ForExpr`, `WhileExpr`) dispatched by
 * `@:kw('for')` / `@:kw('while')`.
 *
 * Statement-level `for (i in xs) body;` keeps parsing through
 * `HxStatement.ForStmt(HxForStmt)` because enum-branch source order in
 * `HxStatement` puts `ForStmt` ahead of `ExprStmt`. The two paths are
 * mutually exclusive at the dispatch level — the kw atom only fires
 * inside an HxExpr-position parse (var initialiser RHS, array element,
 * call argument, etc.).
 *
 * Unblocks 17 fork fixtures whose only parse-blocker is array
 * comprehension; not all flip to pass because most have additional
 * orthogonal blockers (regex literals, postfix `++`, etc.).
 */
class HxArrayComprehensionSliceTest extends HxTestHelpers {

	public function new():Void {
		super();
	}

	// ======== Basic for-comprehension ========

	public function testArrayCompForBasic():Void {
		// `[for (i in 0...10) i]` — the canonical Haxe array comprehension.
		final init:HxExpr = parseVarInit('class M { static function f() { var a = [for (i in 0...10) i]; } }');
		final elems:Array<HxExpr> = expectArrayExpr(init);
		Assert.equals(1, elems.length);
		final fe:HxForExpr = expectForExpr(elems[0]);
		Assert.equals('i', (fe.varName : String));
	}

	public function testArrayCompForBodyMul():Void {
		// `[for (i in 0...10) i * i]` — body is a binary expression, must
		// reach Pratt loop within the for-expr body parse.
		final init:HxExpr = parseVarInit('class M { static function f() { var a = [for (i in 0...10) i * i]; } }');
		final elems:Array<HxExpr> = expectArrayExpr(init);
		Assert.equals(1, elems.length);
		final fe:HxForExpr = expectForExpr(elems[0]);
		switch fe.body {
			case Mul(_, _):
			case _: Assert.fail('expected Mul body in for-comp, got ${fe.body}');
		}
	}

	public function testArrayCompForWithIfBody():Void {
		// `[for (x in xs) if (x > 0) x else 0]` — body is a value-position
		// if-expression. Reaches `HxExpr.IfExpr` through standard Pratt
		// dispatch on the for-comp body.
		final init:HxExpr = parseVarInit('class M { static function f() { var a = [for (x in xs) if (x > 0) x else 0]; } }');
		final elems:Array<HxExpr> = expectArrayExpr(init);
		final fe:HxForExpr = expectForExpr(elems[0]);
		switch fe.body {
			case IfExpr(_):
			case _: Assert.fail('expected IfExpr body, got ${fe.body}');
		}
	}

	public function testArrayCompForBlockBody():Void {
		// Block-body comprehension — `[for (x in xs) { trace(x); x; }]` —
		// the body is `HxExpr.BlockExpr` not a bare expression.
		final init:HxExpr = parseVarInit('class M { static function f() { var a = [for (x in xs) { trace(x); x; }]; } }');
		final elems:Array<HxExpr> = expectArrayExpr(init);
		final fe:HxForExpr = expectForExpr(elems[0]);
		switch fe.body {
			case BlockExpr(_):
			case _: Assert.fail('expected BlockExpr body, got ${fe.body}');
		}
	}

	public function testArrayCompForNested():Void {
		// `[for (a in xs) for (b in ys) a * b]` — issue_498 fork-fixture
		// shape. The outer ForExpr's body is itself a ForExpr, parsed via
		// the same kw atom because `body:HxExpr` accepts any expression.
		final init:HxExpr = parseVarInit('class M { static function f() { var a = [for (a in xs) for (b in ys) a * b]; } }');
		final elems:Array<HxExpr> = expectArrayExpr(init);
		final outer:HxForExpr = expectForExpr(elems[0]);
		final inner:HxForExpr = expectForExpr(outer.body);
		Assert.equals('b', (inner.varName : String));
	}

	// ======== Basic while-comprehension ========

	public function testArrayCompWhileBasic():Void {
		// `[while (cond) v]` — issue_81 fork-fixture shape (sans the i++
		// postfix which is a separate slice).
		final init:HxExpr = parseVarInit('class M { static function f() { var b = [while (cond) v]; } }');
		final elems:Array<HxExpr> = expectArrayExpr(init);
		Assert.equals(1, elems.length);
		final we:HxWhileExpr = expectWhileExpr(elems[0]);
		switch we.body {
			case IdentExpr(name): Assert.equals('v', (name : String));
			case _: Assert.fail('expected IdentExpr body, got ${we.body}');
		}
	}

	// ======== Standalone (non-array) for/while as expression ========

	public function testForExprAsVarInit():Void {
		// `var x = for (i in 0...10) i;` — for-expr in var initialiser
		// position (RHS of `=`). Less common than array comprehension but
		// the same dispatch path.
		final init:HxExpr = parseVarInit('class M { static function f() { var x = for (i in 0...10) i; } }');
		final fe:HxForExpr = expectForExpr(init);
		Assert.equals('i', (fe.varName : String));
	}

	public function testWhileExprAsVarInit():Void {
		final init:HxExpr = parseVarInit('class M { static function f() { var y = while (cond) v; } }');
		final we:HxWhileExpr = expectWhileExpr(init);
		switch we.body {
			case IdentExpr(name): Assert.equals('v', (name : String));
			case _: Assert.fail('expected IdentExpr body');
		}
	}

	// ======== Statement-position regression ========

	public function testStatementForStillParsesAsForStmt():Void {
		// `for (i in 0...10) trace(i);` at statement position must keep
		// dispatching through HxStatement.ForStmt — NOT ExprStmt(ForExpr).
		// HxForStmt's body is HxStatement (with bodyPolicy wrapping);
		// HxForExpr's body is HxExpr (no bodyPolicy). The two paths produce
		// different AST shapes and different writer output.
		final stmts:Array<HxStatement> = fnBodyStmts(parseSingleFnDecl('class M { static function f() { for (i in 0...10) trace(i); } }'));
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ForStmt(_):
			case _: Assert.fail('expected ForStmt at statement position, got ${stmts[0]}');
		}
	}

	public function testStatementWhileStillParsesAsWhileStmt():Void {
		final stmts:Array<HxStatement> = fnBodyStmts(parseSingleFnDecl('class M { static function f() { while (cond) trace(); } }'));
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case WhileStmt(_):
			case _: Assert.fail('expected WhileStmt at statement position, got ${stmts[0]}');
		}
	}

	// ======== Round-trip ========

	public function testArrayCompRoundTrip():Void {
		roundTrip('class M {\n\tstatic function f() {\n\t\tvar a = [for (i in 0...10) i];\n\t}\n}');
		roundTrip('class M {\n\tstatic function f() {\n\t\tvar a = [for (i in 0...10) i * i];\n\t}\n}');
		roundTrip('class M {\n\tstatic function f() {\n\t\tvar b = [while (cond) v];\n\t}\n}');
		roundTrip('class M {\n\tstatic function f() {\n\t\tvar c = [for (a in xs) for (b in ys) a * b];\n\t}\n}');
		roundTrip('class M {\n\tstatic function f() {\n\t\tvar d = [for (x in xs) if (x > 0) x else 0];\n\t}\n}');
	}

	// ======== helpers ========

	private function parseVarInit(source:String):HxExpr {
		final stmt:HxStatement = fnBodyStmts(parseSingleFnDecl(source))[0];
		return switch stmt {
			case VarStmt(decl): decl.init ?? throw 'var has no init';
			case _: throw 'expected VarStmt, got $stmt';
		};
	}

	private function expectArrayExpr(e:HxExpr):Array<HxExpr> {
		return switch e {
			case ArrayExpr(elems): elems;
			case _: throw 'expected ArrayExpr, got $e';
		};
	}

	private function expectForExpr(e:HxExpr):HxForExpr {
		return switch e {
			case ForExpr(stmt): stmt;
			case _: throw 'expected ForExpr, got $e';
		};
	}

	private function expectWhileExpr(e:HxExpr):HxWhileExpr {
		return switch e {
			case WhileExpr(stmt): stmt;
			case _: throw 'expected WhileExpr, got $e';
		};
	}
}
