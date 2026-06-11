package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 32: named function expression `function NAME(…)` in
 * expression position.
 *
 * Mirrors the `HxStatement.LocalFnStmt` precedent at expression
 * level. `HxExpr` gains one additive ctor:
 *
 *   `@:kw('function') NamedFnExpr(decl:HxFnDecl);`
 *
 * Placed BEFORE `FnExpr` so the longer-prefix-first rule applies —
 * the parser tries to consume an identifier after `function`; on
 * success, NamedFnExpr wins; otherwise the branch rolls back and
 * `FnExpr` (anonymous) takes over.
 *
 * Sole-blocker for the haxe-formatter fork fixture
 * `indentation/issue_557_anon_struct_with_assignment` — the value
 * side `test: function test():Void {}` previously skip-parsed.
 *
 * Reuses `HxFnDecl` (same payload as `LocalFnStmt` /
 * `HxClassMember.FnMember`) — no new typedef, mandatory body.
 */
class HxNamedFnExprSliceTest extends HxTestHelpers {

	private function parseBody(source: String): Array<HxStatement> {
		final fn: HxFnDecl = parseSingleFnDecl(source);
		return fnBodyStmts(fn);
	}

	private function expectNamedFnExpr(e: HxExpr): HxFnDecl {
		return switch e {
			case NamedFnExpr(decl): decl;
			case _: throw 'expected NamedFnExpr, got $e';
		};
	}

	private function expectFnExpr(e: HxExpr): Bool {
		return switch e {
			case FnExpr(_): true;
			case _: false;
		};
	}

	private function varStmtInit(stmt: HxStatement): HxExpr {
		return switch stmt {
			case VarStmt(decl):
				if (decl.init == null) throw 'expected VarStmt with init, got null init';
				decl.init;
			case _: throw 'expected VarStmt, got $stmt';
		};
	}

	// --- basic forms ---

	public function testNamedFnExprBasic(): Void {
		final init: HxExpr = varStmtInit(parseBody('class C { function f():Void { var g = function inner():Void {}; } }')[0]);
		final decl: HxFnDecl = expectNamedFnExpr(init);
		Assert.equals('inner', (decl.name: String));
		Assert.equals(0, decl.params.length);
	}

	public function testNamedFnExprParamsAndReturn(): Void {
		final init: HxExpr = varStmtInit(
			parseBody('class C { function f():Void { var g = function compute(x:Int):Int { return x; }; } }')[0]
		);
		final decl: HxFnDecl = expectNamedFnExpr(init);
		Assert.equals('compute', (decl.name: String));
		Assert.equals(1, decl.params.length);
	}

	public function testNamedFnExprTypeParamsExprBody(): Void {
		final init: HxExpr = varStmtInit(parseBody('class C { function f():Void { var g = function id<T>(x:T):T return x; } }')[0]);
		final decl: HxFnDecl = expectNamedFnExpr(init);
		Assert.equals('id', (decl.name: String));
		switch decl.body {
			case ExprBody(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected ExprBody (bare-expr body), got ${decl.body}');
		}
	}

	// --- issue_557 fixture shape: named fn in object-literal field value ---

	public function testNamedFnExprInObjectLitFieldValue(): Void {
		// Whole-module round-trip — exact shape from
		// indentation/issue_557_anon_struct_with_assignment.hxtest.
		final body: Array<HxStatement> =
			parseBody('class C { static function main() { var example:{ function test():Void; } = { test: function test():Void {} }; } }');
		Assert.equals(1, body.length);
		Assert.pass();
	}

	// --- rollback: anonymous function expression stays FnExpr ---

	public function testAnonFnExprFallback(): Void {
		final init: HxExpr = varStmtInit(parseBody('class C { function f():Void { var g = function():Void {}; } }')[0]);
		Assert.isTrue(expectFnExpr(init), 'anonymous function must parse as FnExpr, not NamedFnExpr');
	}

	public function testAnonFnExprWithTypeParamsFallback(): Void {
		final init: HxExpr = varStmtInit(parseBody('class C { function f():Void { var g = function<T>(t:T):T return t; } }')[0]);
		Assert.isTrue(expectFnExpr(init), 'anonymous function<T>(...) must parse as FnExpr');
	}

	// --- writer round-trip ---

	public function testWriterRoundTripNamedFnExpr(): Void {
		writerEquals(
			'class C { static function main() { var g = function compute(x:Int):Int { return x; } } }',
			'class C {\n\tstatic function main() {\n\t\tvar g = function compute(x:Int):Int {\n\t\t\treturn x;\n\t\t};\n\t}\n}\n'
		);
	}

	public function testWriterRoundTripIssue557(): Void {
		// Idempotency over the exact fixture shape — guards that the
		// trivia pipeline (corpus harness path) keeps the named-fn
		// expression byte-stable across reparse.
		roundTrip('class C { static function main() { var example:{ function test():Void; } = { test: function test():Void {} }; } }');
	}

}
