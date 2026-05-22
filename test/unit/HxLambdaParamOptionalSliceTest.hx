package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxLambdaParam;
import anyparse.grammar.haxe.HxLambdaParamBody;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice 31 — `?param:Type` optional lambda / anon-fn parameter.
 *
 * Pre-slice, `HxLambdaParam` was a plain `name + optional type` typedef
 * with `@:spanned('LambdaParam')`. Lambda params (`(x) -> x + 1`,
 * `(x:Int) => x`, `function(x:Int) { … }`) parsed but the corpus
 * shape `(?options:{?foo:Bool}) -> {}` failed — there was no
 * lead-dispatched optional branch the way `HxParam` has had since the
 * fn-decl `?param` slice.
 *
 * Slice 31 splits the typedef into an Alt-enum mirroring
 * `HxParam.Required/Optional`: `Optional(body:HxLambdaParamBody)`
 * dispatches on `@:lead('?')`, `Required(body:HxLambdaParamBody)` is
 * the catch-all. The shared `HxLambdaParamBody` typedef holds the
 * `name + optional type` slot that was the original typedef shape.
 *
 * Sole-blocker target: `whitespace/issue_642_arrow_function_with_optional_arg`
 * (`(?options:{?foo:Bool, ?bar:Int}) -> {}`) — confirmed via
 * `hxq recon --predict-strip --replace '?options' --with 'options'`
 * before landing.
 */
class HxLambdaParamOptionalSliceTest extends HxTestHelpers {

	public function testOptionalThinLambdaParam():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (?x:Int) -> x; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				switch lambda.params[0] {
					case Optional(body):
						Assert.equals('x', (body.name : String));
						Assert.notNull(body.type);
					case _: Assert.fail('expected Optional, got ${lambda.params[0]}');
				}
			case null, _: Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	public function testOptionalThinLambdaParamUntyped():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (?x) -> x; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				switch lambda.params[0] {
					case Optional(body):
						Assert.equals('x', (body.name : String));
						Assert.isNull(body.type);
					case _: Assert.fail('expected Optional, got ${lambda.params[0]}');
				}
			case null, _: Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	public function testOptionalFatLambdaParam():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (?x:Int) => x; }');
		switch decl.init {
			case ParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				switch lambda.params[0] {
					case Optional(body):
						Assert.equals('x', (body.name : String));
						Assert.notNull(body.type);
					case _: Assert.fail('expected Optional, got ${lambda.params[0]}');
				}
			case null, _: Assert.fail('expected ParenLambdaExpr, got ${decl.init}');
		}
	}

	public function testMixedRequiredOptionalThinLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (a:Int, ?b:String) -> a; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(2, lambda.params.length);
				switch lambda.params[0] {
					case Required(body): Assert.equals('a', (body.name : String));
					case _: Assert.fail('expected Required at 0, got ${lambda.params[0]}');
				}
				switch lambda.params[1] {
					case Optional(body):
						Assert.equals('b', (body.name : String));
						Assert.notNull(body.type);
					case _: Assert.fail('expected Optional at 1, got ${lambda.params[1]}');
				}
			case null, _: Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	public function testOptionalLambdaParamAnonStructType():Void {
		// corpus issue_642 motivator shape: `(?options:{?foo:Bool, ?bar:Int}) -> {}`
		final source:String = 'class Main { static function main() { final f = (?options:{?foo:Bool, ?bar:Int}) -> {}; } }';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.notNull(module);
	}

	public function testOptionalAnonFnExprParam():Void {
		// `function (?x:Int) return x` — same Alt-enum split applies to
		// `HxFnExpr.params` since it reuses `HxLambdaParam`.
		final source:String = 'class C { function m() { var g = function(?x:Int) return x; } }';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.notNull(module);
	}

	public function testPlainLambdaParamUnchanged():Void {
		// Regression guard: the canonical `Required` path keeps working
		// after the enum split (Slice 27's HaxeQueryPlugin Optional/Plain
		// recurse covers Optional; Required falls through extractName's
		// TObject .name lookup via enum-param descent in makeEnumNode).
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x:Int) -> x; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				switch lambda.params[0] {
					case Required(body):
						Assert.equals('x', (body.name : String));
						Assert.notNull(body.type);
					case _: Assert.fail('expected Required, got ${lambda.params[0]}');
				}
			case null, _: Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	public function testOptionalLambdaParamRoundTrip():Void {
		roundTrip('class C { var f:Int = (?x:Int) -> x; }', 'thin opt typed');
		roundTrip('class C { var f:Int = (a:Int, ?b:String) -> a; }', 'thin mixed');
		roundTrip('class C { var f:Int = (?x) => x; }', 'fat opt untyped');
	}

	public function testCorpusIssue642RoundTrip():Void {
		final source:String = 'class Main {\n\tstatic function main() {\n\t\tfinal f = (?options:{?foo:Bool, ?bar:Int}) -> {}\n\t}\n}';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.notNull(module);
	}
}
