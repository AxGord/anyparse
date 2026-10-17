package unit.grammar.haxe;

import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxNamedFnExpr;
import anyparse.grammar.haxe.HxStatement;
import utest.Assert;

/**
 * Slice 32: named function expression `function NAME(…)` in
 * expression position.
 *
 * Mirrors the `HxStatement.LocalFnStmt` precedent at expression
 * level. `HxExpr` gains one additive ctor:
 *
 *   `@:kw('function') NamedFnExpr(decl:HxNamedFnExpr);`
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
 * `HxNamedFnExpr` is `HxFnDecl`'s signature (the payload of
 * `LocalFnStmt` / `HxClassMember.FnMember`) over the expression-position
 * `HxFnExprBody`, so an expression body leaves the statement's `;` to
 * the statement; mandatory body.
 */
class HxNamedFnExprSliceTest extends HxTestHelpers {

	// --- writer round-trip ---

	public inline function testWriterRoundTripNamedFnExpr(): Void {
		writerEquals(
			'class C { static function main() { var g = function compute(x:Int):Int { return x; } } }',
			'class C {\n\tstatic function main() {\n\t\tvar g = function compute(x:Int):Int {\n\t\t\treturn x;\n\t\t};\n\t}\n}\n'
		);
	}

	public inline function testWriterRoundTripIssue557(): Void {
		// Idempotency over the exact fixture shape — guards that the
		// trivia pipeline (corpus harness path) keeps the named-fn
		// expression byte-stable across reparse.
		roundTrip('class C { static function main() { var example:{ function test():Void; } = { test: function test():Void {} }; } }');
	}

	// --- basic forms ---

	public function testNamedFnExprBasic(): Void {
		final init: HxExpr = varStmtInit(parseBody('class C { function f():Void { var g = function inner():Void {}; } }')[0]);
		final decl: HxNamedFnExpr = expectNamedFnExpr(init);
		Assert.equals('inner', (decl.name: String));
		Assert.equals(0, decl.params.length);
	}

	public function testNamedFnExprParamsAndReturn(): Void {
		final init: HxExpr = varStmtInit(
			parseBody('class C { function f():Void { var g = function compute(x:Int):Int { return x; }; } }')[0]
		);
		final decl: HxNamedFnExpr = expectNamedFnExpr(init);
		Assert.equals('compute', (decl.name: String));
		Assert.equals(1, decl.params.length);
	}

	public function testNamedFnExprTypeParamsExprBody(): Void {
		final init: HxExpr = varStmtInit(parseBody('class C { function f():Void { var g = function id<T>(x:T):T return x; } }')[0]);
		final decl: HxNamedFnExpr = expectNamedFnExpr(init);
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
		final body: Array<HxStatement> = parseBody(
			'class C { static function main() { var example:{ function test():Void; } = { test: function test():Void {} }; } }'
		);
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

	/**
	 * The `;` after a named function expression's EXPRESSION body is the enclosing statement's, as it is for the
	 * compiler (`haxe --interp` 4.3.7 runs all three): it used to be swallowed by the body, so a comment between it and
	 * the next statement hid the statement boundary and an assignment statement had no `;` of its own left to match.
	 */
	public function testNamedFnExprExprBodyLeavesTheSemicolonToItsStatement(): Void {
		for (src in [
			'class C { function f():Void { final g = function named() return 1; /*c*/ trace(g()); } }',
			'class C { function f():Void { final g = function named() return 1; // c\n trace(g()); } }',
			'class C { function f():Void { g = function named() return 1; trace(g()); } }'
		]) {
			final body: Array<HxStatement> = parseBody(src);
			Assert.equals(2, body.length, src);
		}
	}

	/** A comment after the statement's `;` stays where it was written, as it does after an anonymous function. */
	public function testNamedFnExprExprBodyKeepsATrailingComment(): Void {
		final opts: String = '{"sameLine": {"functionBody": "fitLine"}}';
		for (src in [
			'class C {\n\tfunction f():Void {\n\t\tfinal g = function named() return 1; /*c*/\n\t\ttrace(g());\n\t}\n}',
			'class C {\n\tfunction f():Void {\n\t\tfinal g = function named() return 1; // c\n\t\ttrace(g());\n\t}\n}',
			'class C {\n\tfunction f():Void {\n\t\tg = function named() return 1;\n\t\ttrace(g());\n\t}\n}'
		]) Assert.equals(src, HxWriteFixture.triviaWrite(src, opts), src);
	}

	private function parseBody(source: String): Array<HxStatement> {
		final fn: HxFnDecl = parseSingleFnDecl(source);
		return fnBodyStmts(fn);
	}

	private function expectNamedFnExpr(e: HxExpr): HxNamedFnExpr {
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

}
