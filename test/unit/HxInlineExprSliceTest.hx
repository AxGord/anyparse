package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Phase 3 Slice 24 — `inline` keyword as expression-position prefix
 * on Call/New/Function expressions (`HxExpr.InlineExpr`).
 *
 * Corpus driver: `whitespace/inline_calls` — pre-slice the bare `inline`
 * before a call/new at expression position made the parser bail out
 * (`inline` ate as `IdentExpr` and the following call became a stray
 * statement). The new ctor mirrors the `ThrowExpr` / `CastExpr` precedent:
 * `@:kw('inline')` followed by a single `operand:HxExpr` payload — no
 * separators, no trail, single-Ref writer path. The decl-site `inline`
 * modifier on members and the `LocalInlineFnStmt @:kw('inline')
 * @:lead('function')` statement-position form are unchanged: a member
 * modifier never reaches `HxExpr`, and the `LocalInlineFnStmt` dispatch
 * commits on `inline function` before `ExprStmt → HxExpr` is tried.
 */
class HxInlineExprSliceTest extends HxTestHelpers {

	private function initOf(source: String): HxExpr {
		final decl: HxVarDecl = parseSingleVarDecl(source);
		return switch decl.init {
			case null: throw 'expected init expr, got null';
			case e: e;
		}
	}

	public function testInlineCallExpr(): Void {
		switch initOf('class C { var x = inline foo(); }') {
			case InlineExpr(Call(IdentExpr(v), _)):
				Assert.equals('foo', (v: String));
			case e:
				Assert.fail('expected InlineExpr(Call(IdentExpr(foo))), got $e');
		}
	}

	public function testInlineNewExpr(): Void {
		switch initOf('class C { var x = inline new E(); }') {
			case InlineExpr(NewExpr(_)):
				Assert.pass();
			case e:
				Assert.fail('expected InlineExpr(NewExpr), got $e');
		}
	}

	public function testInlineFnExpr(): Void {
		// `var x = inline function (i:Int) { return i + 1; }` —
		// previously parsed as `var x = (IdentExpr inline)` with the
		// FnExpr leaking out as a sibling statement (misparse). The new
		// ctor recombines them.
		switch initOf('class C { var x = inline function (i:Int) { return i + 1; }; }') {
			case InlineExpr(FnExpr(_)):
				Assert.pass();
			case e:
				Assert.fail('expected InlineExpr(FnExpr), got $e');
		}
	}

	public function testInlineAsCallArg(): Void {
		switch initOf('class C { var x = use(inline g(3)); }') {
			case Call(IdentExpr(name), [InlineExpr(Call(IdentExpr(inner), _))]):
				Assert.equals('use', (name: String));
				Assert.equals('g', (inner: String));
			case e:
				Assert.fail('expected Call(use, [InlineExpr(Call(g, _))]), got $e');
		}
	}

	public function testInlineExprStmtAtFunctionLevel(): Void {
		// `inline g();` as a body statement — the parser dispatches to
		// `LocalInlineFnStmt` first (requires `inline function`), rolls
		// back, then `ExprStmt → InlineExpr(Call)` matches.
		final ast = HaxeParser.parse('class C { function f():Void { inline g(); } }');
		Assert.equals(1, ast.members.length);
		// Just assert the body parses without throwing — the structural
		// shape is exercised by the round-trip test below.
		Assert.pass();
	}

	public function testLocalInlineFnStmtStillWins(): Void {
		// Regression: `inline function name(...) {}` must remain a
		// `LocalInlineFnStmt`, not collapse into `InlineExpr(FnExpr)`.
		final ast = HaxeParser.parse('class C { function f():Void { inline function g():Void {} } }');
		final fn = expectFnMember(ast.members[0].member);
		final body = fnBodyStmts(fn);
		Assert.equals(1, body.length);
		switch body[0] {
			case LocalInlineFnStmt(decl):
				Assert.equals('g', (decl.name: String));
			case _:
				Assert.fail('expected LocalInlineFnStmt, got ${body[0]}');
		}
	}

	public function testInlineCallRoundTrip(): Void {
		// Writer ripple: InlineExpr emits via the generic single-Ref
		// value:HxExpr path (ThrowExpr/CastExpr/ReturnExpr precedent).
		roundTrip(
			'class C { static function f() { var a = inline g(); var b = inline new E(""); inline g(); use(inline g(3)); } }',
			'inline-expr'
		);
	}

}
