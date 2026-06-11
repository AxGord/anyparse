package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxCaseBranch;
import anyparse.grammar.haxe.HxCasePattern;
import anyparse.grammar.haxe.HxCasePatternBody;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxSwitchCase;
import anyparse.grammar.haxe.HxSwitchStmt;

/**
 * Slice apq-P5-M: switch-guard `case P if (cond):`.
 *
 * `HxCaseBranch.patterns` widened its element type from `HxExpr` to
 * `HxCasePattern = { expr:HxExpr; @:optional @:kw('if') guard }`.
 * The Star's `@:sep(',') @:trail(':')` shape is unchanged — only the
 * element type changed (K3 element-widening precedent), so no
 * `Lowering` constraint is touched and the guard is the exact
 * `@:optional @:kw('else')` word-keyword shape of `HxIfStmt.elseBody`
 * / `HxIfExpr.elseBranch`.
 *
 * Haxe binds a single guard to the whole list, so it attaches to the
 * last parsed element (`case A, B if (c):` → `[0].guard == null`,
 * `[1].guard != null`). Asserts the probed contract: guard presence /
 * absence, expr shape, multi-pattern last-element binding, a ternary
 * inside the guard (proves `HxExpr` stops at the trailing `:` even
 * with an internal `?:`), the K3 non-guard regression, and round-trip
 * idempotency.
 */
class HxSwitchGuardSliceTest extends HxTestHelpers {

	private function parseSwitch(source: String): HxSwitchStmt {
		final body: Array<HxStatement> = fnBodyStmts(parseSingleFnDecl(source));
		Assert.equals(1, body.length);
		return switch body[0] {
			case SwitchStmt(stmt): stmt;
			case null, _: throw 'expected SwitchStmt, got ${body[0]}';
		};
	}

	private function caseBranch(c: HxSwitchCase): HxCaseBranch {
		return switch c {
			case CaseBranch(b): b;
			case null, _: throw 'expected CaseBranch, got $c';
		};
	}

	private function identName(e: HxExpr): String {
		return switch e {
			case IdentExpr(v): (v: String);
			case e: throw 'expected IdentExpr, got $e';
		};
	}

	private function plainExpr(p: HxCasePattern): HxExpr {
		return switch p.expr {
			case Plain(e): e;
			case body: throw 'expected Plain pattern body, got $body';
		};
	}

	public function testCaseWithGuardPresent(): Void {
		final sw: HxSwitchStmt = parseSwitch('class C { function f(x:E):Void { switch (x) { case A if (b): y(); case _: z(); } } }');
		final p: HxCasePattern = caseBranch(sw.cases[0]).patterns[0];
		Assert.equals('A', identName(plainExpr(p)));
		switch p.guard {
			case ParenExpr(inner):
				Assert.equals('b', identName(inner));
			case null:
				Assert.fail('expected guard ParenExpr, got null');
			case e:
				Assert.fail('expected guard ParenExpr, got $e');
		}
	}

	public function testCaseWithoutGuardIsNull(): Void {
		final sw: HxSwitchStmt = parseSwitch('class C { function f(x:Int):Void { switch (x) { case 1: y(); case _: z(); } } }');
		final p: HxCasePattern = caseBranch(sw.cases[0]).patterns[0];
		Assert.isNull(p.guard);
		switch plainExpr(p) {
			case IntLit(v):
				Assert.equals(1, v);
			case e:
				Assert.fail('expected IntLit pattern, got $e');
		}
	}

	public function testMultiPatternGuardBindsLast(): Void {
		final sw: HxSwitchStmt = parseSwitch('class C { function f(x:E):Void { switch (x) { case A, B if (b): y(); case _: z(); } } }');
		final ps: Array<HxCasePattern> = caseBranch(sw.cases[0]).patterns;
		Assert.equals(2, ps.length);
		Assert.equals('A', identName(plainExpr(ps[0])));
		Assert.isNull(ps[0].guard);
		Assert.equals('B', identName(plainExpr(ps[1])));
		Assert.notNull(ps[1].guard);
	}

	public function testGuardWithCallPattern(): Void {
		final sw: HxSwitchStmt = parseSwitch('class C { function f(x:E):Void { switch (x) { case Foo(a) if (b): y(); case _: z(); } } }');
		final p: HxCasePattern = caseBranch(sw.cases[0]).patterns[0];
		Assert.notNull(p.guard);
		switch plainExpr(p) {
			case Call(operand, _):
				Assert.equals('Foo', identName(operand));
			case e:
				Assert.fail('expected Call pattern Foo(a), got $e');
		}
	}

	public function testTernaryInsideGuard(): Void {
		// Guard parses `(a ? b : c)`; the inner ternary `:` must not be
		// mistaken for the case `:` trail (HxExpr has no bare-`:` op).
		final sw: HxSwitchStmt = parseSwitch(
			'class C { function f(x:Int):Void { switch (x) { case 1 if (a ? b : c): y(); case _: z(); } } }'
		);
		final p: HxCasePattern = caseBranch(sw.cases[0]).patterns[0];
		switch plainExpr(p) {
			case IntLit(v):
				Assert.equals(1, v);
			case e:
				Assert.fail('expected IntLit 1, got $e');
		}
		switch p.guard {
			case ParenExpr(_):
				Assert.pass();
			case null:
				Assert.fail('expected guard ParenExpr, got null');
			case e:
				Assert.fail('expected guard ParenExpr, got $e');
		}
		Assert.equals(1, caseBranch(sw.cases[0]).body.length);
	}

	public function testNonGuardMultiRegression(): Void {
		// K3 contract: a non-guarded multi-value case is unaffected.
		final sw: HxSwitchStmt = parseSwitch('class C { function f(x:Int):Void { switch (x) { case 1, 2: y(); case _: z(); } } }');
		final ps: Array<HxCasePattern> = caseBranch(sw.cases[0]).patterns;
		Assert.equals(2, ps.length);
		Assert.isNull(ps[0].guard);
		Assert.isNull(ps[1].guard);
	}

	public function testGuardRoundTrip(): Void {
		roundTrip(
			'class C { function f(x:E):Void { switch (x) { case A if (b): y(); case C, D if (e): z(); case _: w(); } } }', 'switch-guard'
		);
	}

}
