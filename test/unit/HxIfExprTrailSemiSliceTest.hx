package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice apq-P5-R: `;` before `else` in an `if`-expression.
 *
 * `HxExpr.IfExpr(HxIfExpr)` already parsed `if (c) a else b` in value
 * position; the gap was that `HxIfExpr.thenBranch:HxExpr` did not
 * absorb the optional `;` Haxe accepts between the then-branch and
 * `else` (or before the enclosing context with no `else`) —
 * `final x = if (c) a; else b;`, `g(if (c) a; else b)`. Closed by
 * adding `@:trailOpt(';')` to `thenBranch` (the established
 * `HxStatement.VarStmt`/`HxDecl`/`HxConditionalStmt` meta). The `;`
 * is consumed, not stored — the AST is identical to the
 * no-semicolon form, so the no-`;` cases are pure regression guards.
 *
 * Build.hx L105-113 (`if (c) TPath({...}); else if (c) ...; else
 * ...;`) was the offset-25 self-parse blocker this closes.
 */
class HxIfExprTrailSemiSliceTest extends HxTestHelpers {

	private function initOf(source: String): HxExpr {
		final decl: HxVarDecl = parseSingleVarDecl(source);
		return switch decl.init {
			case null: throw 'expected init expr, got null';
			case e: e;
		}
	}

	private function parseBody(source: String): Array<HxStatement> {
		final fn: HxFnDecl = parseSingleFnDecl(source);
		return fnBodyStmts(fn);
	}

	private function identName(e: HxExpr): String {
		return switch e {
			case IdentExpr(v): (v: String);
			case other: throw 'expected IdentExpr, got $other';
		}
	}

	public function testThenSemiBeforeElse(): Void {
		switch initOf('class C { var x = if (a) b; else c; }') {
			case IfExpr(ie):
				Assert.equals('b', identName(ie.thenBranch));
				switch ie.elseBranch {
					case null: Assert.fail('expected elseBranch');
					case eb: Assert.equals('c', identName(eb));
				}
			case other:
				Assert.fail('expected IfExpr, got $other');
		}
	}

	public function testNoSemiRegression(): Void {
		// The previously-working form must be unaffected (@:trailOpt is
		// optional → no-op when no `;` is present).
		switch initOf('class C { var x = if (a) b else c; }') {
			case IfExpr(ie):
				Assert.equals('b', identName(ie.thenBranch));
				switch ie.elseBranch {
					case null: Assert.fail('expected elseBranch');
					case eb: Assert.equals('c', identName(eb));
				}
			case other:
				Assert.fail('expected IfExpr, got $other');
		}
	}

	public function testThenSemiNoElse(): Void {
		// Two semicolons: the first is consumed by @:trailOpt(';') on
		// thenBranch; the second terminates the VarMember @:trail(';').
		switch initOf('class C { var x = if (a) b;; }') {
			case IfExpr(ie):
				Assert.equals('b', identName(ie.thenBranch));
				switch ie.elseBranch {
					case null: Assert.pass();
					case _: Assert.fail('expected null elseBranch');
				}
			case other:
				Assert.fail('expected IfExpr, got $other');
		}
	}

	public function testElseIfChainWithSemis(): Void {
		// The Build.hx shape: nested if-expr in each else, `;` per branch.
		// Each branch is a Call (e.g. `k()`), so match Call and check callee.
		switch initOf('class C { var x = if (a) g(); else if (b) h(); else k(); }') {
			case IfExpr(ie):
				switch ie.elseBranch {
					case null: Assert.fail('expected elseBranch');
					case IfExpr(inner):
						switch inner.elseBranch {
							case null: Assert.fail('expected inner elseBranch');
							case Call(callee, _): Assert.equals('k', identName(callee));
							case other: Assert.fail('expected Call in inner else, got $other');
						}
					case other: Assert.fail('expected nested IfExpr in else, got $other');
				}
			case other:
				Assert.fail('expected IfExpr, got $other');
		}
	}

	public function testCallArgSemiBeforeElse(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f():Void { g(if (a) b; else c); } }');
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(expr):
				switch expr {
					case Call(_, args):
						Assert.equals(1, args.length);
						switch args[0] {
							case IfExpr(_): Assert.pass();
							case other: Assert.fail('expected IfExpr arg, got $other');
						}
					case other: Assert.fail('expected Call, got $other');
				}
			case null, _:
				Assert.fail('expected ExprStmt');
		}
	}

	public function testTrailSemiRoundTrip(): Void {
		roundTrip('class C { function f() { final x = if (a) b; else c; } }', 'if-expr-semi-before-else');
		roundTrip('class C { function f() { final x = if (a) g(); else if (b) h(); else k(); } }', 'if-expr-else-if-chain-semis');
		// No-`;` regression form must also stay idempotent.
		roundTrip('class C { function f() { final x = if (a) b else c; } }', 'if-expr-no-semi');
	}

}
