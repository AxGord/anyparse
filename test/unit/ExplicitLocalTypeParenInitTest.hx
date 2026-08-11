package unit;

import utest.Assert;

/**
 * The `explicit-local-type` autofix on an initializer wrapped in parentheses or in
 * an `(expr : T)` check-type: the wrapper is unwrapped before the initializer's own
 * shape decides, so every structurally-pinned form still annotates and every
 * inference-resolved form still stays report-only. A bare check-type initializer is
 * left intact, and a parenthesised local with no fixable shape is still reported.
 */
class ExplicitLocalTypeParenInitTest extends ExplicitLocalTypeCheckTestBase {

	public inline function testFixParenBareNew(): Void {
		assertFixContains('final sb = (new StringBuf());', ':StringBuf');
	}

	public inline function testFixParenArrayLiteral(): Void {
		assertFixContains('final arr = ([1, 2]);', ':Array<Int>');
	}

	public inline function testFixParenTypedCast(): Void {
		assertFixContains('final c = (cast(v, Int));', ':Int');
	}

	public inline function testFixParenStringLiteral(): Void {
		assertFixContains("final s = ('x');", ':String');
	}

	public inline function testFixParenBoolLiteral(): Void {
		assertFixContains('final b = (true);', ':Bool');
	}

	public inline function testFixParenNegIntLiteral(): Void {
		// The motivating real site: `final m = (-1);` must annotate `:Int`.
		assertFixContains('final m = (-1);', 'm:Int');
	}

	public inline function testFixDoubleParenIntLiteral(): Void {
		assertFixContains('final n = ((1));', 'n:Int');
	}

	public inline function testFixParenNewWithWrittenGenerics(): Void {
		assertFixContains('final m = (new Map<String, Int>());', ':Map<String, Int>');
	}

	public inline function testFixParenHomogeneousStringArray(): Void {
		assertFixContains("var strs = (['a', 'b']);", ':Array<String>');
	}

	public inline function testFixParenStringLiteralMethodCall(): Void {
		assertFixContains("final parts = ('a,b'.split(','));", ':Array<String>');
	}

	public inline function testFixParenTypedLocalRead(): Void {
		assertFixContains('var a:Int = 5;\n\t\tfinal v = (a);', 'v:Int');
	}

	public inline function testCheckTypeUnwrapLeavesBareFormIntact(): Void {
		// `(x : Int)` IS the check-type node — its parens belong to the node, not a wrapper.
		// The unwrap must not disturb it.
		assertFixContains('final a = (x : Int);', 'a:Int');
	}

	public inline function testParenWrappedCheckTypeFixed(): Void {
		// An EXTRA paren around a check-type must peel back to the check-type node.
		assertFixContains('final b = ((x : Int));', 'b:Int');
	}

	public inline function testSkipParenEmptyArray(): Void {
		// Unwrapping exposes the arm, but an empty array still pins nothing -> report-only.
		assertNoFix('final empty = ([]);');
	}

	public inline function testSkipParenReshadowedIdentRead(): Void {
		// CF-1 shadow guard survives the unwrap: the unwrapped ident carries its OWN span,
		// so the re-shadow check sees the same visible declarations as the bare form.
		assertNoFix("var s:String = 'x';\n\t\tvar s:Int = 5;\n\t\tfinal v = (s);");
	}

	public inline function testSkipParenOptionalParamRead(): Void {
		// The optional-param soundness guard survives the unwrap (body type Null<String>
		// differs from the written source `String`) -> report-only.
		assertNoFixSrc('class C {\n\tfunction f(?p:String):Void {\n\t\tfinal v = (p);\n\t}\n}');
	}

	public function testFixParenCrossClassStaticFieldRead(): Void {
		assertFixIdx(wrap('var v = (API.API_URL);'), [
			{ file: 'API.hx', source: 'class API {\n\tpublic static final API_URL:String = "x";\n}' }
		], 'v:String');
	}

	public function testParenLocalStillReported(): Void {
		// The report side never needed the unwrap — a wrapped initializer was always flagged.
		Assert.equals(1, violations(wrap('final m = (-1);')).length);
	}

}
