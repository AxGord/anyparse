package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxForExpr;
import anyparse.grammar.haxe.HxForStmt;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice apq-P5-K2: map key-value `for (k => v in m)` iteration.
 *
 * `HxForStmt` and `HxForExpr` gained an optional `valueName` field
 * (`@:optional @:lead('=>') var valueName:Null<HxIdentLit>`) between
 * `varName` and the `in` keyword — the same optional-single-Ref-with-
 * literal-commit pattern as `HxParamBody.defaultValue`
 * (`@:optional @:lead('=')`) and `HxFnDecl.returnType`
 * (`@:optional @:lead(':')`). Additive: zero core/synth/writer change.
 *
 * Contract mirrors the probed single-iter precedent: plain
 * `for (v in m)` keeps `valueName == null` (the `=>` peek fails on
 * `in`), so the existing form is a strict regression guard. Both the
 * statement (`HxForStmt` via `HxStatement.ForStmt`) and the
 * expression-comprehension (`HxForExpr` via `HxExpr.ForExpr`) forms
 * are covered, since the single grammar edit was applied to both.
 */
class HxForKeyValueSliceTest extends HxTestHelpers {

	private function parseBody(source:String):Array<HxStatement> {
		return fnBodyStmts(parseSingleFnDecl(source));
	}

	private function expectForStmt(stmt:HxStatement):HxForStmt {
		return switch stmt {
			case ForStmt(s): s;
			case _: throw 'expected ForStmt, got $stmt';
		};
	}

	private function parseVarInit(source:String):HxExpr {
		final stmt:HxStatement = parseBody(source)[0];
		return switch stmt {
			case VarStmt(decl): decl.init ?? throw 'var has no init';
			case _: throw 'expected VarStmt, got $stmt';
		};
	}

	private function expectForExpr(e:HxExpr):HxForExpr {
		return switch e {
			case ForExpr(s): s;
			case _: throw 'expected ForExpr, got $e';
		};
	}

	private function expectArrayExpr(e:HxExpr):Array<HxExpr> {
		return switch e {
			case ArrayExpr(elems): elems;
			case _: throw 'expected ArrayExpr, got $e';
		};
	}

	// --- statement scope ---

	public function testForStmtKeyValue():Void {
		final body:Array<HxStatement> = parseBody('class C { function f(m:Map<Int,Int>):Void { for (k => v in m) trace(k); } }');
		Assert.equals(1, body.length);
		final fs:HxForStmt = expectForStmt(body[0]);
		Assert.equals('k', (fs.varName : String));
		Assert.notNull(fs.valueName);
		Assert.equals('v', (fs.valueName : String));
	}

	public function testForStmtSingleIterStillNull():Void {
		final body:Array<HxStatement> = parseBody('class C { function f(xs:Array<Int>):Void { for (v in xs) trace(v); } }');
		final fs:HxForStmt = expectForStmt(body[0]);
		Assert.equals('v', (fs.varName : String));
		Assert.isNull(fs.valueName);
	}

	public function testForStmtKeyValueBlockBodyUsesBoth():Void {
		final body:Array<HxStatement> = parseBody('class C { function f(m:Map<String,Int>):Void { for (key => val in m) { trace(key); trace(val); } } }');
		final fs:HxForStmt = expectForStmt(body[0]);
		Assert.equals('key', (fs.varName : String));
		Assert.equals('val', (fs.valueName : String));
	}

	public function testNestedForStmtKeyValue():Void {
		final body:Array<HxStatement> = parseBody('class C { function f(m:Map<Int,Int>, n:Map<Int,Int>):Void { for (k => v in m) for (k2 => v2 in n) trace(k); } }');
		final outer:HxForStmt = expectForStmt(body[0]);
		Assert.equals('k', (outer.varName : String));
		Assert.equals('v', (outer.valueName : String));
		final inner:HxForStmt = expectForStmt(outer.body);
		Assert.equals('k2', (inner.varName : String));
		Assert.equals('v2', (inner.valueName : String));
	}

	// --- expression-comprehension scope ---

	public function testForExprComprehensionKeyValue():Void {
		final init:HxExpr = parseVarInit('class C { function f(m:Map<Int,Int>):Void { var a = [for (k => v in m) v]; } }');
		final elems:Array<HxExpr> = expectArrayExpr(init);
		Assert.equals(1, elems.length);
		final fe:HxForExpr = expectForExpr(elems[0]);
		Assert.equals('k', (fe.varName : String));
		Assert.equals('v', (fe.valueName : String));
	}

	public function testForExprComprehensionSingleIterStillNull():Void {
		final init:HxExpr = parseVarInit('class C { function f():Void { var a = [for (i in 0...10) i]; } }');
		final fe:HxForExpr = expectForExpr(expectArrayExpr(init)[0]);
		Assert.equals('i', (fe.varName : String));
		Assert.isNull(fe.valueName);
	}
}
