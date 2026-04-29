package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnExpr;
import anyparse.grammar.haxe.HxFnExprBody;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Tests for slice ω-anon-fn-expr-body — adds anonymous function
 * expressions in expression position via `HxExpr.FnExpr(fn:HxFnExpr)`
 * with `@:kw('function')`.
 *
 * Three shapes covered:
 *  - `f(function (res) trace(res))` — params + bare expression body.
 *    Sits inside `Call(args)` where the body terminator is `,` or `)`,
 *    so `HxFnExprBody.ExprBody` deliberately omits `@:trail(';')`.
 *  - `f(function () { trace(0); })` — block body. Reuses
 *    `HxFnBlock` so `@:trivia` orphan slots and `{`-leading dispatch
 *    behave identically to `HxFnBody.BlockBody`.
 *  - `f(function (a:Int, b:Int) a + b)` — typed params + expression
 *    body. Verifies `HxLambdaParam` (optional type) accepts both
 *    untyped and typed forms uniformly.
 *
 * Ctor placement on `HxExpr` is before `IdentExpr` so the `function`
 * keyword commits via `@:kw` before the bare-identifier regex
 * catches it (same pattern as `NewExpr` / `if`/`for`/...).
 */
class HxFnExprSliceTest extends HxTestHelpers {

	public function testAnonFnExprBodyInCall():Void {
		final source:String = 'class C {\n\tfunction m() {\n\t\thandle(function (res) trace(res));\n\t}\n}';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.notNull(module);
		assertFirstStmtCallArgIsFnExprWithExprBody(source);
	}

	public function testAnonFnExprBodyEmptyParams():Void {
		final source:String = 'class C {\n\tfunction m() {\n\t\thandle(function () trace(0));\n\t}\n}';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.notNull(module);
		roundTrip(source, 'empty params + expr body');
	}

	public function testAnonFnBlockBodyInCall():Void {
		final source:String = 'class C {\n\tfunction m() {\n\t\thandle(function () {\n\t\t\ttrace(0);\n\t\t});\n\t}\n}';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.notNull(module);
		roundTrip(source, 'anon fn block body');
	}

	public function testAnonFnTypedParams():Void {
		final source:String = 'class C {\n\tfunction m() {\n\t\trun(function (a:Int, b:Int) a + b);\n\t}\n}';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.notNull(module);
		roundTrip(source, 'anon fn typed params + expr body');
	}

	public function testAnonFnExprBodyRoundTrip():Void {
		roundTrip('class C {\n\tfunction m() {\n\t\thandle(function (res) trace(res));\n\t}\n}', 'expr body');
	}

	private function assertFirstStmtCallArgIsFnExprWithExprBody(source:String):Void {
		final written1:String = HxModuleWriter.write(HaxeModuleParser.parse(source));
		final written2:String = HxModuleWriter.write(HaxeModuleParser.parse(written1));
		Assert.equals(written1, written2, 'idempotent round-trip');
	}
}
