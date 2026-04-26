package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxSwitchStmtBare;

/**
 * Tests for slice ω-switch-bare: switch with no parens around the
 * subject — `switch v { case A: 1; }`.
 *
 * Pure grammar additivity. Two new ctors (`HxStatement.SwitchStmtBare`
 * and `HxExpr.SwitchExprBare`) sharing `@:kw('switch')` with the
 * existing parens-form ctors. Source-order disambiguation via
 * `tryBranch` rolls the parser back to before `switch` when the
 * parens-form's `@:lead('(')` fails on the bare subject.
 *
 * No Lowering / WriterCodegen / runtime changes — same precedent as
 * the `TypedCastExpr` / `CastExpr` and `TryCatchStmt` /
 * `TryCatchStmtBare` pairs.
 */
class HxSwitchBareSliceTest extends HxTestHelpers {

	private function parseBody(source:String):Array<HxStatement> {
		final fn:HxFnDecl = parseSingleFnDecl(source);
		return fnBodyStmts(fn);
	}

	private function parseBareSwitch(source:String):HxSwitchStmtBare {
		final body:Array<HxStatement> = parseBody(source);
		Assert.equals(1, body.length);
		return switch body[0] {
			case SwitchStmtBare(stmt): stmt;
			case null, _: throw 'expected SwitchStmtBare, got ${body[0]}';
		};
	}

	// ---- Statement-position bare switch ----

	public function testSwitchStmtBareIdentSubject():Void {
		final sw:HxSwitchStmtBare = parseBareSwitch('class C { function f():Void { switch x { case 1: y; } } }');
		switch sw.expr {
			case IdentExpr(v): Assert.equals('x', (v : String));
			case null, _: Assert.fail('expected IdentExpr');
		}
		Assert.equals(1, sw.cases.length);
	}

	public function testSwitchStmtBareCallSubject():Void {
		final sw:HxSwitchStmtBare = parseBareSwitch('class C { function f():Void { switch foo() { case 1: y; } } }');
		switch sw.expr {
			case Call(operand, args):
				switch operand {
					case IdentExpr(v): Assert.equals('foo', (v : String));
					case null, _: Assert.fail('expected IdentExpr operand');
				}
				Assert.equals(0, args.length);
			case null, _: Assert.fail('expected Call subject');
		}
		Assert.equals(1, sw.cases.length);
	}

	public function testSwitchStmtBareFieldAccessSubject():Void {
		final sw:HxSwitchStmtBare = parseBareSwitch('class C { function f():Void { switch x.y { case 1: a; } } }');
		switch sw.expr {
			case FieldAccess(operand, field):
				Assert.equals('y', (field : String));
				switch operand {
					case IdentExpr(v): Assert.equals('x', (v : String));
					case null, _: Assert.fail('expected IdentExpr operand');
				}
			case null, _: Assert.fail('expected FieldAccess subject');
		}
	}

	public function testSwitchStmtBareIsSubject():Void {
		// `is` is asymmetric infix at prec 5; the Pratt loop terminates on `{`
		// because `{` is not an infix op in HxExpr.
		final sw:HxSwitchStmtBare = parseBareSwitch('class C { function f():Void { switch x is Int { case true: a; } } }');
		switch sw.expr {
			case Is(_, _): Assert.pass();
			case null, _: Assert.fail('expected Is subject');
		}
	}

	public function testSwitchStmtBareWithDefault():Void {
		final sw:HxSwitchStmtBare = parseBareSwitch('class C { function f():Void { switch x { case 1: a; default: b; } } }');
		Assert.equals(2, sw.cases.length);
		switch sw.cases[1] {
			case DefaultBranch(_): Assert.pass();
			case null, _: Assert.fail('expected DefaultBranch');
		}
	}

	public function testSwitchStmtBareEmptyCases():Void {
		final sw:HxSwitchStmtBare = parseBareSwitch('class C { function f():Void { switch x {} } }');
		Assert.equals(0, sw.cases.length);
	}

	// ---- Expression-position bare switch ----

	public function testSwitchExprBareInReturn():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():String { return switch x { case 1: "a"; case _: "b"; }; } }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case ReturnStmt(expr):
				switch expr {
					case SwitchExprBare(stmt): Assert.equals(2, stmt.cases.length);
					case null, _: Assert.fail('expected SwitchExprBare in return, got $expr');
				}
			case null, _: Assert.fail('expected ReturnStmt');
		}
	}

	public function testSwitchExprBareInVarInit():Void {
		final body:Array<HxStatement> = parseBody(
			'class C { function f():Void { var y:String = switch x { case 1: "a"; case _: "b"; }; } }'
		);
		Assert.equals(1, body.length);
		switch body[0] {
			case VarStmt(decl):
				switch decl.init {
					case SwitchExprBare(stmt): Assert.equals(2, stmt.cases.length);
					case null, _: Assert.fail('expected SwitchExprBare in var init');
				}
			case null, _: Assert.fail('expected VarStmt');
		}
	}

	// ---- Source-order disambiguation: parens form still wins ----

	public function testSwitchWithParensStillRoutesToSwitchStmt():Void {
		// Regression — `switch (x) { … }` must continue to parse as
		// `HxStatement.SwitchStmt` (parens-form) via source-order
		// precedence, not be absorbed by the new `SwitchStmtBare`.
		final body:Array<HxStatement> = parseBody('class C { function f():Void { switch (x) { case 1: y; } } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case SwitchStmt(_): Assert.pass();
			case SwitchStmtBare(_): Assert.fail('parens form must route to SwitchStmt, not SwitchStmtBare');
			case null, _: Assert.fail('expected SwitchStmt');
		}
	}

	public function testSwitchExprWithParensStillRoutesToSwitchExpr():Void {
		// Regression — `return switch (x) { … }` must continue to parse
		// as `HxExpr.SwitchExpr`, not `SwitchExprBare`.
		final body:Array<HxStatement> = parseBody(
			'class C { function f():String { return switch (x) { case 1: "a"; case _: "b"; }; } }'
		);
		switch body[0] {
			case ReturnStmt(expr):
				switch expr {
					case SwitchExpr(_): Assert.pass();
					case SwitchExprBare(_): Assert.fail('parens form must route to SwitchExpr, not SwitchExprBare');
					case null, _: Assert.fail('expected SwitchExpr');
				}
			case null, _: Assert.fail('expected ReturnStmt');
		}
	}

	// ---- Round-trip ----

	public function testSwitchStmtBareRoundTrip():Void {
		roundTrip('class C { function f():Void { switch x { case 1: a; case 2: b; } } }', 'switch-stmt-bare');
	}

	public function testSwitchExprBareRoundTrip():Void {
		roundTrip(
			'class C { function f():String { return switch x { case 1: "a"; case _: "b"; }; } }',
			'switch-expr-bare'
		);
	}

	public function testSwitchBareNestedRoundTrip():Void {
		roundTrip(
			'class C { function f():Void { switch x { case 1: switch y { case 2: a; } } } }',
			'switch-stmt-bare-nested'
		);
	}
}
