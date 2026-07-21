package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxLambdaParam;
import anyparse.grammar.haxe.HxLambdaParamBody;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice fn-param-C — per-parameter DEFAULT VALUE in a function
 * LITERAL: `function(a:Int = 1) {}`, `(b:Int = 2) -> b`.
 *
 * `HxParamBody` (the member-declaration side) has carried
 * `@:optional @:lead('=') var defaultValue` since the fn-decl slice, so
 * `class D { function f(a:Int = 1) {} }` always parsed. The
 * expression-side twin `HxLambdaParamBody` did not — its docstring
 * asserted that "arrow / anon-function lambdas in Haxe do not support
 * per-parameter default values at the syntactic level", which is simply
 * false (verified against Haxe 4.3: `function(a:Int = 1) return a` and
 * `(b:Int = 2) -> b` both compile and evaluate). The fix is the byte-twin
 * slot on `HxLambdaParamBody`, appended LAST because parse and emit walk
 * a struct rule's fields in declaration order and `name : Type = default`
 * is the Haxe surface token order.
 *
 * Note the gap covered BOTH the typed and the untyped default form —
 * `function(a = 1) {}` failed identically to `function(a:Int = 1) {}`,
 * because the param Star closed on `)` and never expected an `=`.
 *
 * Real-world source: 14 Haxe stdlib modules, all `@:overload` externs of
 * the shape
 * `@:overload(function(?type:String, replace:String = "") : HTMLDocument {})`.
 * The metadata wrapper is incidental. Representative sites:
 *  - `js/html/CanvasRenderingContext2D.hx:73` — `= NONZERO` (bare ident)
 *  - `js/html/Document.hx:471` — `= cast 4294967295` (a `cast` expr, not a literal)
 *  - `php/Global.hx:1052` — `= ""` (string literal)
 *
 * Exactly one AST shape moves, and it is pinned by
 * `testDefaultedParenLambdaAstMove`: `(a = 1) -> b` was
 * `ThinArrow(ParenExpr(Assign(a, 1)), b)` and is now a lambda with a
 * defaulted parameter — the reading Haxe itself takes.
 *
 * Everything else is a regression surface guarded below: the slot must
 * NOT let a parenthesised assignment be mistaken for a lambda. It cannot,
 * because `HxThinParenLambda` / `HxParenLambda` commit on the `->` / `=>`
 * lead only AFTER the param Star closes, and `lowerEnum`'s `tryBranch`
 * restores `ctx.pos` when that lead is absent — so `(a = 1)` still lands
 * on `ParenExpr`, `[(a = 1) => b]` still lands on the map-entry `Arrow`,
 * and the paren-less thin form `x -> x = 1` never reaches this body at
 * all.
 *
 * Known writer gap, deliberately not pinned here: a block comment written
 * between the `=` and the default expression is dropped, the same way
 * `HxLambdaParam` drops one in its `type` slot. It is a pre-existing
 * trivia gap of the lambda-param family that this slice makes reachable
 * (the input used to be a parse error); it belongs with the other
 * param-comment gaps around `HxParamCommentWriteTest`, not with a test
 * that would cement the loss.
 */
@:nullSafety(Strict)
class HxLambdaParamDefaultSliceTest extends HxTestHelpers {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 120}}';

	public function testTypedParamWithDefaultInAnonFn(): Void {
		final body: HxLambdaParamBody = soleAnonFnParam('class C { var f:Int = function(a:Int = 1) return a; }');
		Assert.equals('a', (body.name: String));
		Assert.equals('Int', (expectNamedType(body.type).name: String));
		Assert.notNull(body.defaultValue);
	}

	public function testUntypedParamWithDefaultInAnonFn(): Void {
		final body: HxLambdaParamBody = soleAnonFnParam('class C { var f:Int = function(a = 1) return a; }');
		Assert.equals('a', (body.name: String));
		Assert.isNull(body.type);
		Assert.notNull(body.defaultValue);
	}

	public function testTypedParamWithDefaultInThinArrowLambda(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Int = (b:Int = 2) -> b; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				final body: HxLambdaParamBody = lambdaParamBody(lambda.params[0]);
				Assert.equals('b', (body.name: String));
				Assert.equals('Int', (expectNamedType(body.type).name: String));
				Assert.notNull(body.defaultValue);
			case null, _:
				Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	public function testOptionalParamWithDefaultKeepsOptionalBranch(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Int = function(?a:Int = 1) return a; }');
		switch decl.init {
			case FnExpr(fn):
				Assert.equals(1, fn.params.length);
				switch fn.params[0] {
					case Optional(body):
						Assert.equals('a', (body.name: String));
						Assert.notNull(body.defaultValue);
					case _: Assert.fail('expected Optional, got ${fn.params[0]}');
				}
			case null, _:
				Assert.fail('expected FnExpr, got ${decl.init}');
		}
	}

	public function testNonLiteralDefaultsParse(): Void {
		// The three stdlib default-expression shapes: bare ident
		// (`= NONZERO`), `cast` expr (`= cast 4294967295`), string
		// literal (`= ""`). A literal-only default slot would reject the
		// middle one, so the slot is a full `HxExpr`.
		// `f(1, 2)` and `[1, 2]` carry a `,` (and `f(...)` a `)`) inside the
		// default expression, which a naive sep/close peek in the enclosing
		// param Star would mis-read as the end of the parameter; `x ? y : z`
		// carries a `:`, the lead token of the sibling type slot.
		for (def in [
			'NONZERO',
			'cast 4294967295',
			'""',
			'null',
			'[]',
			'{}',
			'Foo.BAR',
			'a + b',
			'f(1, 2)',
			'[1, 2]',
			'x ? y : z'
		]) roundTrip('class C { var f:Int = function(a:Int = $def) return a; }', 'default=$def');
	}

	public function testStdlibOverloadExternShape(): Void {
		// js/html/HTMLDocument.hx:47 verbatim shape — the motivating site.
		final source: String = '@:overload(function(?type:String, replace:String = "") : HTMLDocument {})\nextern class X {}';
		final module: HxModule = HaxeModuleParser.parse(source);
		Assert.equals(1, module.decls.length);
		roundTrip(source, 'overload extern');
	}

	public function testWriterEmitsSpacedEquals(): Void {
		// The default lead is emitted through the OPTIONAL-Ref path, which
		// consults `spacedLeads`/`tightLeads` — `=` is in neither, so it
		// spaces both sides regardless of how the source was written.
		writerEquals(
			'class C {\n\tvar f:Int = function(a:Int=1) return a;\n}', 'class C {\n\tvar f:Int = function(a:Int = 1) return a;\n}\n',
			'tight source spaces out'
		);
		writerEquals('class C {\n\tvar f:Int = (b:Int = 2) -> b;\n}', 'class C {\n\tvar f:Int = (b:Int = 2) -> b;\n}\n', 'thin arrow');
	}

	public function testLongAnonFnSignatureWraps(): Void {
		final src: String = 'class D {\n\tfunction f() {\n\t\tvar g = function(alphaChannel:Int = 1, betaChannel:Int = 2, gammaChannel:Int = 3, deltaChannel:Int = 4, epsilonChannel:Int = 5) {};\n\t}\n}';
		final expected: String = 'class D {\n\tfunction f() {\n\t\tvar g = function(alphaChannel:Int = 1, betaChannel:Int = 2, gammaChannel:Int = 3, deltaChannel:Int = 4,\n\t\t\tepsilonChannel:Int = 5) {};\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	public function testLongAnonFnSignatureWithoutDefaultsWrapsUnchanged(): Void {
		// Control: no default values anywhere, so this signature took an
		// identical writer path before and after the slice — a change
		// here would mean the slice moved anon-fn signature wrapping in
		// general rather than only for the new slot. It carries a sixth
		// param because dropping the five ` = N` fragments would
		// otherwise leave the line under the limit.
		final src: String = 'class D {\n\tfunction f() {\n\t\tvar g = function(alphaChannel:Int, betaChannel:Int, gammaChannel:Int, deltaChannel:Int, epsilonChannel:Int, zetaCh:Int) {};\n\t}\n}';
		final expected: String = 'class D {\n\tfunction f() {\n\t\tvar g = function(alphaChannel:Int, betaChannel:Int, gammaChannel:Int, deltaChannel:Int, epsilonChannel:Int,\n\t\t\tzetaCh:Int) {};\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	public function testNeighbouringFormsUnchanged(): Void {
		for (src in [
			'class C { var f:Int = function(a:Int) return a; }',
			'class C { var f:Int = function(a) return a; }',
			'class C { var f:Int = function(?a:Int) return a; }',
			'class C { var f:Int = function() return 1; }',
			'class C { var f:Int = (a:Int) -> a; }',
			'class C { var f:Int = (a) -> a; }',
			'class C { var f:Int = (?a:Int) -> a; }',
			'class C { var f:Int = x -> x; }',
			'class C { function m(a:Int = 1) {} }',
		]) roundTrip(src, src);
	}

	public function testParenAssignStaysParenExpr(): Void {
		// The one shape the new slot could plausibly steal: a
		// parenthesised assignment with no arrow after the `)`.
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Int = (a = 1); }');
		switch decl.init {
			case ParenExpr(inner):
				switch inner {
					case Assign(_, _): Assert.pass();
					case _: Assert.fail('expected ParenExpr(Assign), got ParenExpr($inner)');
				}
			case null, _:
				Assert.fail('expected ParenExpr, got ${decl.init}');
		}
	}

	public function testMapEntryArrowStaysInfix(): Void {
		// Both must stay map entries — the prec-0 infix `=>` over a
		// `ParenExpr` key, reached before `HxParenLambda` in the atom order.
		// `[(a = 1) => b]` is the shape actually at risk: it is the only one
		// whose key now ALSO parses as a defaulted param list.
		for (src in ['class C { var f:Int = [(a) => b]; }', 'class C { var f:Int = [(a = 1) => b]; }']) {
			final decl: HxVarDecl = parseSingleVarDecl(src);
			switch decl.init {
				case ArrayExpr(elems):
					switch elems[0] {
						case Arrow(ParenExpr(_), _): Assert.pass();
						case _: Assert.fail('expected Arrow(ParenExpr, _) for $src, got ${elems[0]}');
					}
				case null, _:
					Assert.fail('expected ArrayExpr for $src, got ${decl.init}');
			}
		}
	}

	public function testThinArrowSingleIdentDoesNotSwallowAssign(): Void {
		// `x -> x = 1` is the paren-LESS thin form on the Pratt infix
		// path; it must stay `ThinArrow(x, Assign(x, 1))` — the body is
		// an assignment, not a defaulted parameter.
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Int = x -> x = 1; }');
		switch decl.init {
			case ThinArrow(_, Assign(_, _)):
				Assert.pass();
			case null, _:
				Assert.fail('expected ThinArrow(_, Assign), got ${decl.init}');
		}
	}

	public function testRoundTripsOfEveryDefaultBearingForm(): Void {
		roundTrip('class C { var f:Int = function(a:Int = 1) return a; }', 'anon typed default');
		roundTrip('class C { var f:Int = function(a = 1) return a; }', 'anon untyped default');
		roundTrip('class C { var f:Int = function(?a:Int = 1) return a; }', 'anon optional default');
		roundTrip('class C { var f:Int = (b:Int = 2) -> b; }', 'thin arrow default');
		roundTrip('class C { var f:Int = (x, a = 1) => b; }', 'legacy => lambda default');
		roundTrip('class C { var f:Int = function(a:Int = 1, b:String = "x", c = null) return a; }', 'multi default');
	}

	public function testDefaultedParenLambdaAstMove(): Void {
		// The ONE shape the slice intentionally moves. Pre-slice,
		// `(a = 1) -> b` was `ThinArrow(ParenExpr(Assign(a, 1)), b)`; it is
		// now a lambda with a defaulted parameter, which is the reading Haxe
		// itself takes (`var i = (a = 1) -> a; i()` returns `1`). The `=>`
		// twin does NOT move, and the atom order is the whole reason:
		// `ThinParenLambdaExpr` sits BEFORE `ParenExpr` in `HxExpr`, while
		// `ParenLambdaExpr` sits after it.
		final thin: HxVarDecl = parseSingleVarDecl('class C { var f:Int = (a = 1) -> b; }');
		switch thin.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				final body: HxLambdaParamBody = lambdaParamBody(lambda.params[0]);
				Assert.equals('a', (body.name: String));
				Assert.isNull(body.type);
				Assert.notNull(body.defaultValue);
			case null, _:
				Assert.fail('expected ThinParenLambdaExpr, got ${thin.init}');
		}
		// A multi-param `=>` lambda DOES reach `HxParenLambda`, which shares
		// `HxLambdaParam`, so the slot lands there too. Note Haxe 4.3.7
		// rejects this shape outright (`Unexpected =>`) — `HxParenLambda` is
		// a permissive-superset rule, so this pins grammar behaviour, not
		// valid Haxe.
		final fat: HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x, a = 1) => b; }');
		switch fat.init {
			case ParenLambdaExpr(lambda):
				Assert.equals(2, lambda.params.length);
				Assert.notNull(lambdaParamBody(lambda.params[1]).defaultValue);
			case null, _:
				Assert.fail('expected ParenLambdaExpr, got ${fat.init}');
		}
	}

	private function soleAnonFnParam(source: String): HxLambdaParamBody {
		final decl: HxVarDecl = parseSingleVarDecl(source);
		final params: Array<HxLambdaParam> = switch decl.init {
			case FnExpr(fn): fn.params;
			case null, _: throw 'expected FnExpr, got ${decl.init}';
		};
		Assert.equals(1, params.length);
		return lambdaParamBody(params[0]);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
