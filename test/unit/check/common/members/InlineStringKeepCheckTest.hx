package unit.check.common.members;

import anyparse.check.common.members.InlineConstant;

/**
 * What keeps a String constant `inline` beyond the name positions of `InlineConstantCheckTest`:
 * a shape whose plain form does not compile or reads an unset field.
 */
class InlineStringKeepCheckTest extends Test {

	/** A `__init__` calling a helper runs before the constant is assigned: the plain form reads it unset through the helper. */
	@:pin('control')
	@:killer('M-INLSTR-INIT-FUNCTION-RUNS')
	public function testStaticInitFunctionCallingHelperHoldsString(): Void {
		Assert.equals(
			0,
			violations(
				"class C { static inline final S: String = 'x'; static function g() { trace(S); } static function __init__() { g(); } }"
			).length
		);
	}

	/** A `__init__` that calls nothing cannot reach the constant through code. */
	@:pin('control')
	@:killer('M-DEMAND-INIT-RUNS-BODY')
	public function testStaticInitFunctionWithoutCallDoesNotHoldString(): Void {
		Assert.equals(1, violations("class C { static inline final S: String = 'x'; static function __init__() { var v = 1; } }").length);
	}

	/** A call inside an ordinary function runs at no static-init time. */
	@:pin('control')
	@:killer('M-DEMAND-INIT-ONLY-INIT')
	public function testOrdinaryFunctionCallDoesNotHoldString(): Void {
		Assert.equals(
			1, violations("class C { static inline final S: String = 'x'; static function f() { g(); } static function g() {} }").length
		);
	}

	/** A visibility modifier between a class-level `@:keep` and the class carries the pin. */
	@:pin('control')
	@:killer('M-INLSTR-VISIBILITY-CARRIES-PIN')
	public function testKeepPrivateClassHoldsString(): Void {
		Assert.equals(0, violations("@:keep private class C { static inline final S: String = 'x'; }").length);
	}

	/** The native-interop flag crosses it too, on the add-inline arm. */
	@:pin('control')
	@:killer('M-INLSTR-VISIBILITY-CARRIES-PIN')
	public function testNativeInteropPrivateClassPublicConstantSkipped(): Void {
		Assert.equals(0, violations('@:nativeGen private class C { public static final A:Int = 5; }').length);
	}

	/** `extern private class` holds like `private extern class`: `on extern non-inline variable`. */
	@:pin('control')
	@:killer('M-INLSTR-VISIBILITY-CARRIES-PIN')
	public function testExternPrivateClassHoldsString(): Void {
		Assert.equals(0, violations("extern private class C { public static inline final S: String = 'x'; }").length);
	}

	/** A legacy `@:enum abstract` projects as a plain abstract, and its value refuses a non-inline read just the same. */
	@:pin('control')
	@:killer('M-DEMAND-LEGACY-ENUM-ABSTRACT')
	public function testLegacyEnumAbstractValueHoldsString(): Void {
		Assert.equals(
			0, violations("class K { public static inline final A1: String = 'a'; }\n@:enum abstract E(String) { var A = K.A1; }").length
		);
	}

	/** The code argument of a `Syntax.code` call must be a string constant. */
	@:pin('control')
	@:killer('M-DEMAND-TARGET-CODE')
	public function testSyntaxCodeArgumentHoldsString(): Void {
		Assert.equals(0, violations("class C { static inline final F: String = 'x'; static function m() { js.Syntax.code(F); } }").length);
	}

	/** So must a target intrinsic's. */
	@:pin('control')
	@:killer('M-DEMAND-TARGET-CODE')
	public function testCodeIntrinsicArgumentHoldsString(): Void {
		Assert.equals(0, violations("class C { static inline final F: String = 'x'; static function m() { untyped __js__(F); } }").length);
	}

	/** Only the first argument is target code; a later one is an ordinary runtime value. */
	@:pin('control')
	@:killer('M-DEMAND-TARGET-CODE-FIRST-ONLY')
	public function testSyntaxCodeLaterArgumentDoesNotHoldString(): Void {
		Assert.equals(
			1, violations("class C { static inline final F: String = 'x'; static function m() { js.Syntax.code('{0}', F); } }").length
		);
	}

	/** A local `static var` is initialised among the statics, so a non-inline read sees the field unset. */
	@:pin('control')
	@:killer('M-DEMAND-STATIC-LOCAL')
	public function testLocalStaticVarHoldsString(): Void {
		Assert.equals(
			0, violations("class C { static inline final S: String = 'x'; static function f() { static var v = S; return v; } }").length
		);
	}

	/** A local `static final` likewise. */
	@:pin('control')
	@:killer('M-DEMAND-STATIC-LOCAL')
	public function testLocalStaticFinalHoldsString(): Void {
		Assert.equals(
			0, violations("class C { static inline final S: String = 'x'; static function f() { static final v = S; return v; } }").length
		);
	}

	/** Every binding of a multi-binding local static holds what it reads, not only the last one. */
	@:pin('control')
	@:killer('M-DEMAND-STATIC-LOCAL-EVERY-BINDING')
	public function testLocalStaticEveryBindingHoldsString(): Void {
		Assert.equals(
			0,
			violations("class C { static inline final S: String = 'x'; static function f() { static var v = S, w = 2; return v; } }").length
		);
	}

	/** A read spelled only as a shorthand inside an interpolated static initializer holds, like a plain read. */
	@:pin('control')
	@:killer('M-DEMAND-SPELLS-DESCENDANTS')
	public function testInterpolatedShorthandReadHoldsString(): Void {
		Assert.equals(0, violations("class C { static inline final S: String = 'x'; static final T: String = 'a$S'; }").length);
	}

	/** So does a qualified read inside a braced segment. */
	@:pin('control')
	@:killer('M-DEMAND-SPELLS-DESCENDANTS')
	public function testInterpolatedQualifiedReadHoldsString(): Void {
		Assert.equals(0, violations("class C { static inline final S: String = 'x'; static final T: String = 'a${C.S}'; }").length);
	}

	/** And an argument of a call inside a braced segment. */
	@:pin('control')
	@:killer('M-DEMAND-SPELLS-DESCENDANTS')
	public function testInterpolatedCallArgumentHoldsString(): Void {
		Assert.equals(0, violations("class C { static inline final S: String = 'x'; static final T: String = 'a${f(S)}'; }").length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new InlineConstant(), src);
	}

}
