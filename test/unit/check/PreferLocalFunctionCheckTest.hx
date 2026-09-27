package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferLocalFunction;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `prefer-local-function` check: a function literal bound to a local is flagged `Info` and
 * the binding is rewritten into a local function declaration sitting where the literal was.
 * Each refusal fixture below is aimed at ONE gate — a local function cannot be reassigned, is
 * invisible above its own declaration, and loses the expected type its declaration supplied.
 */
class PreferLocalFunctionCheckTest extends Test {

	// ---- the three rewritable shapes ----

	/**
	 * The shape that motivated the rule: the literal sits inside a call argument, so the hoist
	 * inserts the declaration BEFORE the host statement and the argument collapses to the name.
	 */
	public function testArgumentPositionHoisted(): Void {
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void;\n\t\tg(1, h = function(e:Int):Void { p(e); }, 2);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tfunction h(e:Int):Void { p(e); }\ng(1, h, 2);\n\t}\n}', fixed(src));
	}

	/**
	 * When the assignment IS the whole statement the declaration REPLACES it. Rewriting only the
	 * assignment would leave a `h;` no-op behind — only an applied edit pins that.
	 */
	public function testStatementPositionReplacesTheStatement(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar h:Void->Void;\n\t\th = function():Void { p(); };\n\t\tg(h);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tfunction h():Void { p(); }\n\t\tg(h);\n\t}\n}', fixed(src));
	}

	/** A declaration whose initializer IS the literal becomes the declaration outright — one edit, no hoist. */
	public function testInitializerFormBecomesDeclaration(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar g = function(x:Int):Int return x;\n\t\tp(g(1));\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tfunction g(x:Int):Int return x;\n\t\tp(g(1));\n\t}\n}', fixed(src));
	}

	/** The definite-assignment placeholder a non-nullable declared type needed is dropped with the declaration. */
	public function testNullPlaceholderDeclarationAccepted(): Void {
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\tvar h:Void->Void = null;\n\t\th = function():Void { p(); };\n\t\tg(h);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tfunction h():Void { p(); }\n\t\tg(h);\n\t}\n}', fixed(src));
	}

	/** A comment INSIDE the literal's body rides along — the body span is copied verbatim. */
	public function testBodyCommentRidesAlong(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void;\n\t\tg(h = function(e:Int):Void {\n\t\t\t// note\n'
			+ '\t\t\tp(e);\n\t\t});\n\t}\n}';
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tfunction h(e:Int):Void {\n\t\t\t// note\n\t\t\tp(e);\n\t\t}\ng(h);\n\t}\n}', fixed(src)
		);
	}

	/** A binding inside a nested lambda belongs to THAT lambda's statement list — the scope stop must not lose it. */
	public function testBindingInsideNestedLambdaFound(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg(function():Void {\n\t\t\tvar q:Void->Void;\n'
			+ '\t\t\tq = function():Void { p(); };\n\t\t\tr(q);\n\t\t});\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(fixed(src).indexOf('function q():Void { p(); }') >= 0);
	}

	// ---- arrow lambdas ----

	/**
	 * The shape that motivated the arrow support: an event handler whose lambda closes over the timer
	 * it detaches. The declaration's `->Void` result is what lets a block body move at all.
	 */
	public function testArrowBlockBodyWithVoidResultHoisted(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void = null;\n\t\tg(1, h = (e:Int) -> { p(e); }, 2);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tfunction h(e:Int):Void { p(e); }\ng(1, h, 2);\n\t}\n}', fixed(src));
	}

	/**
	 * A lambda's expression body IS its value — the declaration regains the `return` the arrow implied, and
	 * the declared result as its hint.
	 */
	public function testArrowExpressionBodyGainsReturn(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar h:Int->Int = null;\n\t\tg(h = (x:Int) -> x * 2);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tfunction h(x:Int):Int return x * 2;\ng(h);\n\t}\n}', fixed(src));
	}

	/**
	 * The hoisted fixture with `Void` swapped for `Int`: a `{ … }` arrow body is an EXPRESSION whose
	 * value is its last expression, and a declaration's block body has none — so the hoist would retype
	 * the binding and the annotation no longer proves it may.
	 */
	public function testArrowBlockBodyWithNonVoidResultRefused(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar h:Int->Int = null;\n\t\tg(1, h = (e:Int) -> { p(e); }, 2);\n\t}\n}')
				.length
		);
	}

	/** The initializer form reads the same proof out of the same annotation slot. */
	public function testArrowInitializerWithVoidResultHoisted(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void = (e:Int) -> { p(e); };\n\t\tg(h);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tfunction h(e:Int):Void { p(e); }\n\t\tg(h);\n\t}\n}', fixed(src));
	}

	/**
	 * The declared result is carried as the return hint: without it the declaration infers its type
	 * from the body, and an inferred `{ a: 1 }` does not unify with a declared structure of `final`
	 * fields (`Cannot unify final and non-final fields`).
	 */
	@:pin('control')
	@:killer('M-LOCALFN-RESULT-DROPPED')
	public function testDeclaredResultIsCarried(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfinal s:() -> R = () -> { a: 1 };\n\t\tg(s);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tfunction s():R return { a: 1 };\n\t\tg(s);\n\t}\n}', fixed(src));
	}

	/**
	 * A literal whose parameters do not spell the declared ones — another type, another optionality,
	 * another count — would be hoisted with a type the binding never had.
	 */
	@:pin('control')
	@:killer('M-LOCALFN-SIGNATURE-ANY')
	public function testSignatureMismatchRefused(): Void {
		final cls: String = 'class C {\n\tfunction f():Void {\n\t\tfinal h:TYPE = LIT;\n\t\tg(h);\n\t}\n}';
		Assert.equals(0, violations(cls.replace('TYPE', '(x:Int) -> Int').replace('LIT', '(x:Float) -> 1')).length);
		Assert.equals(0, violations(cls.replace('TYPE', '(?x:Int) -> Int').replace('LIT', '(x:Int) -> 1')).length);
		Assert.equals(0, violations(cls.replace('TYPE', '(Int, Int) -> Int').replace('LIT', '(x:Int) -> 1')).length);
		Assert.equals(1, violations(cls.replace('TYPE', '(?x:Int, s:String) -> Int').replace('LIT', '(?x:Int, s:String) -> 1')).length);
		Assert.equals(1, violations(cls.replace('TYPE', 'Int -> String -> Int').replace('LIT', '(x:Int, s:String) -> 1')).length);
	}

	/**
	 * A parenthesised parameter list is ONE function per list: `(Int) -> (Int) -> Int` takes one
	 * `Int` and returns a function. Read as a chain of arrows it looked like two parameters, so the
	 * one-parameter literal that spells it exactly was refused.
	 */
	public function testParenthesisedListReturningAFunctionIsHoisted(): Void {
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\tfinal add:(Int) -> (Int) -> Int = (a:Int) -> (b:Int) -> a + b;\n\t\tg(add);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tfunction add(a:Int):(Int) -> Int return (b:Int) -> a + b;\n\t\tg(add);\n\t}\n}',
			fixed(src)
		);
	}

	/**
	 * An expression body under a `Void` result is wrapped in a block, not returned: `return x + 1` in a
	 * `:Void` function is `Int should be Void`, while the lambda's value was simply discarded.
	 */
	@:pin('control')
	@:killer('M-LOCALFN-VOID-RETURNED')
	public function testVoidExpressionBodyIsWrapped(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfinal h:Int -> Void = (x:Int) -> x + 1;\n\t\tg(h);\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tfunction h(x:Int):Void {\nx + 1;\n}\n\t\tg(h);\n\t}\n}', fixed(src));
	}

	/**
	 * The literal reads an OUTER `g`: the local is not in scope in its own initializer. Hoisted to
	 * `function g`, the same `g` is the function itself and the call recurses without end.
	 */
	@:pin('control')
	@:killer('M-LOCALFN-OUTER-NAME-READ')
	public function testLiteralReadingItsOwnNameRefused(): Void {
		final src: String = 'class C {\n\tstatic function g(x:Int):Int return x * 10;\n\tfunction f():Void {\n'
			+ '\t\tfinal g:(x:Int) -> Int = (x:Int) -> g(x) + 1;\n\t\ttrace(g(2));\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** The same initializer with its type REMOVED: nothing proves the block's value was `Void`. */
	public function testUnannotatedArrowBlockBodyRefused(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar h = (e:Int) -> { p(e); };\n\t\tg(h);\n\t}\n}').length);
	}

	/**
	 * An arrow parameter without a type: the expected type its declaration supplied dies with the hoist.
	 * The paren-less form is refused one step earlier — it projects its parameter as a plain identifier
	 * rather than a parameter node at all.
	 */
	public function testUntypedArrowParameterRefused(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void = null;\n\t\tg(h = (e) -> p(e));\n\t}\n}').length
		);
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void = null;\n\t\tg(h = e -> p(e));\n\t}\n}').length);
	}

	// ---- gates ----

	/**
	 * THE gate the mutually-recursive-closure idiom needs. `other` is declared ABOVE the hoist
	 * point and calls `h`; a local function is invisible there, so the rewrite would not compile.
	 * A `var` is exactly what that idiom uses the mutability for.
	 */
	public function testReadBeforeTheHoistPointRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tvar h:Void->Void;\n\t\tfunction other():Void { h(); }\n'
				+ '\t\th = function():Void { other(); };\n\t}\n}'
			).length
		);
	}

	/**
	 * The same fixture with the early read REMOVED is flagged — so the refusal above is the
	 * read-before-hoist gate deciding it, not some other gate the shape also trips.
	 */
	public function testSiblingLocalFunctionWithoutTheReadIsFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tvar h:Void->Void;\n\t\tfunction other():Void { p(); }\n'
				+ '\t\th = function():Void { other(); };\n\t}\n}'
			).length
		);
	}

	/** A local function cannot be reassigned — a second write keeps the binding a variable. */
	public function testReassignedLocalRefused(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar h:Void->Void;\n\t\th = function():Void { p(); };\n\t\th = null;\n\t}\n}')
				.length
		);
	}

	/** A same-named second declaration in the list means the occurrences do not all belong to one binding. */
	public function testRedeclaredNameRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tvar h:Void->Void;\n\t\th = function():Void { p(); };\n\t\tvar h:Int = 1;\n\t}\n}'
			).length
		);
	}

	/** A FIELD target has no local declaration to consume — the assignment stays an assignment. */
	public function testFieldTargetRefused(): Void {
		Assert.equals(
			0, violations('class C {\n\tvar h:Void->Void;\n\tfunction f():Void {\n\t\th = function():Void { p(); };\n\t}\n}').length
		);
	}

	/** A qualified l-value is not an identifier binding at all. */
	public function testQualifiedTargetRefused(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\to.h = function():Void { p(); };\n\t}\n}').length);
	}

	/**
	 * The declaration's `:T` supplied the parameter's expected type; after the hoist nothing does,
	 * and a body that dereferences the parameter stops typing.
	 */
	public function testUnannotatedParameterRefused(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void;\n\t\tg(h = function(e):Void { p(e); });\n\t}\n}').length
		);
	}

	/** A rest parameter is refused outright — its written form is not a plain declaration parameter. */
	public function testRestParameterRefused(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar h:Dynamic;\n\t\tg(h = function(...rest:Int):Void { p(rest); });\n\t}\n}')
				.length
		);
	}

	/** A declaration carrying a REAL initializer would lose it — only a bare one (or a null placeholder) qualifies. */
	public function testInitializedDeclarationRefused(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void = q;\n\t\tg(h = function(e:Int):Void { p(e); });\n\t}\n}')
				.length
		);
	}

	/**
	 * A NOMINAL declared type is dropped by the hoist and the binding silently changes type. Pony's
	 * `Listener1<Int>` is an abstract whose `@:from` wraps the literal ONCE at the assignment; hoisted,
	 * every use site wraps the raw function again, so an add / remove pair stops sharing a wrapper —
	 * and it still compiles.
	 */
	public function testNominalDeclaredTypeRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tvar h:Listener1<Int> = null;\n\t\th = function(e:Int):Void { p(e); };\n\t\tg(h);\n'
				+ '\t}\n}'
			).length
		);
	}

	/**
	 * The same fixture with a written FUNCTION type is flagged — so the refusal above is the
	 * declared-type gate, and a `->` annotation the literal's own signature reproduces still passes.
	 */
	public function testArrowDeclaredTypeAccepted(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void = null;\n\t\th = function(e:Int):Void { p(e); };\n\t\tg(h);\n\t}\n}'
			).length
		);
	}

	/** A nominal type that merely HOLDS functions carries no top-level arrow — its wrapping is the same hazard. */
	public function testArrowInsideTypeArgumentsRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tvar h:Null<Int->Void> = null;\n\t\th = function(e:Int):Void { p(e); };\n'
				+ '\t\tg(h);\n\t}\n}'
			).length
		);
	}

	/** The initializer form reads the same annotation slot — a nominal one refuses there too. */
	public function testNominalDeclaredTypeOnInitializerRefused(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar h:Listener1<Int> = function(e:Int):Void { p(e); };\n\t\tg(h);\n\t}\n}')
				.length
		);
	}

	/** A multi-declarator list cannot give up one of its bindings. */
	public function testMultiDeclaratorRefused(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void, k:Int;\n\t\tg(h = function(e:Int):Void { p(e); });\n\t}\n}')
				.length
		);
	}

	/** A comment in the dropped `h = ` head would be lost by the rewrite. */
	public function testCommentInDroppedHeadRefused(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void;\n\t\tg(h /* keep */ = function(e:Int):Void { p(e); });\n\t}\n}'
			).length
		);
	}

	/**
	 * A conditionally-evaluated position: hoisting the literal out of a ternary branch would build
	 * the closure on the path that chose the other branch.
	 */
	public function testConditionalPositionRefused(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Void {\n\t\tvar h:Void->Void;\n\t\tg(c ? (h = function():Void { p(); }) : null);\n\t}\n}')
				.length
		);
	}

	/**
	 * The same fixture with the ternary REMOVED — the parenthesis alone — is flagged, so the
	 * refusal above is the conditional-evaluation gate, not the wrapping parenthesis.
	 */
	public function testParenthesizedBindingWithoutTheTernaryIsFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f():Void {\n\t\tvar h:Void->Void;\n\t\tg((h = function():Void { p(); }));\n\t}\n}').length
		);
	}

	/** A reification subtree is spliced code, not source anyone reads — its bindings resolve elsewhere. */
	public function testMacroSubtreeNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\treturn macro {\n\t\t\tvar h = function(e:Int):Void { p(e); };\n\t\t};\n\t}\n}'
			).length
		);
	}

	// ---- framework contract ----

	public function testFindingShape(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f():Void {\n\t\tvar h:Int->Void;\n\t\tg(h = function(e:Int):Void { p(e); });\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-local-function', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-local-function'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-local-function'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	// ---- helpers ----

	private function violations(src: String): Array<Violation> {
		return new PreferLocalFunction().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferLocalFunction = new PreferLocalFunction();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
	}

	private function fixed(src: String): String {
		return CanonicalEdit.applyEdits(src, edits(src));
	}

}
