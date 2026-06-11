package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice apq-P5-K1: named local function statement.
 *
 * `HxStatement` gained two additive ctors that reuse `HxFnDecl` (the
 * exact payload of `HxClassMember.FnMember`, so no new grammar types):
 *
 *  - `LocalFnStmt(decl:HxFnDecl)` — `@:kw('function')` — `function g(){}`
 *  - `LocalInlineFnStmt(decl:HxFnDecl)` — `@:kw('inline') @:lead('function')`
 *    — `inline function g(){}`
 *
 * Tests assert the SAME contract the class-member `function` precedent
 * supports (probed against the pre-slice binary): no-arg, params +
 * return type, type parameters, AND the bare-expression body form
 * `function g() return x;` (HxFnBody's `ExprBody` branch). The
 * anonymous function expression `function() {}` / `function(x) e` has
 * no name, so `HxFnDecl.name` fails on `(` and `tryBranch` rolls back
 * to `ExprStmt` → `HxExpr.FnExpr` — that rollback is pinned here so the
 * new ctors cannot hijack anonymous functions.
 *
 * The no-local-fn regression case guards that the two new ctors do not
 * perturb existing statement dispatch.
 */
class HxLocalFnStmtSliceTest extends HxTestHelpers {

	/** Parse function body statements from a single-function class. */
	private function parseBody(source: String): Array<HxStatement> {
		final fn: HxFnDecl = parseSingleFnDecl(source);
		return fnBodyStmts(fn);
	}

	private function expectLocalFn(stmt: HxStatement): HxFnDecl {
		return switch stmt {
			case LocalFnStmt(decl): decl;
			case _: throw 'expected LocalFnStmt, got $stmt';
		};
	}

	private function expectInlineLocalFn(stmt: HxStatement): HxFnDecl {
		return switch stmt {
			case LocalInlineFnStmt(decl): decl;
			case _: throw 'expected LocalInlineFnStmt, got $stmt';
		};
	}

	// --- plain local function ---

	public function testLocalFnBasic(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { function g() {} g(); } }');
		Assert.equals(2, body.length);
		final decl: HxFnDecl = expectLocalFn(body[0]);
		Assert.equals('g', (decl.name: String));
		switch body[1] {
			case ExprStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected ExprStmt after local fn, got ${body[1]}');
		}
	}

	public function testLocalFnParamsAndReturn(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { function g(x:Int):Void { return; } } }');
		Assert.equals(1, body.length);
		final decl: HxFnDecl = expectLocalFn(body[0]);
		Assert.equals('g', (decl.name: String));
		Assert.equals(1, decl.params.length);
	}

	// --- mirror precedent: type params + bare-expression body ---

	public function testLocalFnTypeParamsExprBody(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { function g<T>(x:T):T return x; } }');
		Assert.equals(1, body.length);
		final decl: HxFnDecl = expectLocalFn(body[0]);
		Assert.equals('g', (decl.name: String));
		switch decl.body {
			case ExprBody(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected ExprBody (bare-expr body), got ${decl.body}');
		}
	}

	// --- inline local function ---

	public function testInlineLocalFn(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { inline function g():Void {} g(); } }');
		Assert.equals(2, body.length);
		final decl: HxFnDecl = expectInlineLocalFn(body[0]);
		Assert.equals('g', (decl.name: String));
	}

	// --- dogfood shape: typed inline helper between statements ---

	public function testDogfoodInlineHelperPattern(): Void {
		final body: Array<HxStatement> =
			parseBody(
				'class C { function f():Void { inline function addEdge(from:String, to:String):Void { trace(from); } addEdge("a", "b"); } }'
			);
		Assert.equals(2, body.length);
		final decl: HxFnDecl = expectInlineLocalFn(body[0]);
		Assert.equals('addEdge', (decl.name: String));
		Assert.equals(2, decl.params.length);
	}

	// --- nested local function ---

	public function testNestedLocalFn(): Void {
		final body: Array<HxStatement> =
			parseBody('class C { function f():Void { function outer():Void { function inner() {} inner(); } } }');
		Assert.equals(1, body.length);
		final outer: HxFnDecl = expectLocalFn(body[0]);
		final inner: Array<HxStatement> = fnBodyStmts(outer);
		Assert.equals(2, inner.length);
		Assert.equals('inner', (expectLocalFn(inner[0]).name: String));
	}

	// --- rollback: anonymous function expression is NOT a local-fn stmt ---

	public function testAnonFnExprAssignedStaysVarStmt(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { var h = function() { return 1; }; h(); } }');
		switch body[0] {
			case LocalFnStmt(_) | LocalInlineFnStmt(_):
				Assert.fail('anonymous fn assigned to var must not parse as a local-fn statement');
			case VarStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected VarStmt, got ${body[0]}');
		}
	}

	public function testAnonFnExprAsCallArgStaysExprStmt(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f(xs:Array<Int>):Void { xs.map(function(x) return x); } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case LocalFnStmt(_) | LocalInlineFnStmt(_):
				Assert.fail('anonymous fn call arg must not parse as a local-fn statement');
			case ExprStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected ExprStmt, got ${body[0]}');
		}
	}

	// --- regression: a body with no local fn parses unchanged ---

	public function testNoLocalFnRegression(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { if (a) b = 1; while (c) d(); return; } }');
		Assert.equals(3, body.length);
		switch body[0] {
			case IfStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected IfStmt, got ${body[0]}');
		}
	}

}
