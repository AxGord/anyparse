package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.OptionalParamShorthand;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `optional-param-shorthand` check, three arms. (1) `name:Null<T> = null` / `name:T = null`
 * is flagged Info and rewritten to `?name:T` — one `Null<>` layer unwrapped when present, the
 * ` = null` dropped, and `?` prepended. (2) An already-`?` parameter with a redundant `= null`
 * default is flagged too — its type stays verbatim (no unwrap) and only the ` = null` goes. (3) A
 * redundant-sigil arm: `?name:T = <non-null default>` is flagged and its fix drops only the
 * leading `?`, leaving `name:T = <non-null default>` byte-for-byte otherwise unchanged — a
 * non-null default already makes the parameter optional, and the `?` needlessly widens the body
 * type to `Null<T>`. Gated fail-closed: refused when the enclosing function cannot be found, is
 * body-less (an interface / abstract declaration), or the parameter is compared/assigned against
 * `null` or is a bare `switch` subject anywhere in the function; refused when the enclosing type
 * carries a supertype clause UNLESS the function is the constructor or `static` (neither can
 * override or implement), and always refused when the function carries an explicit `override`.
 * A non-null default, an already-`?` parameter without a `null` default, an untyped `a = null` /
 * `?a = null` (no type annotation), and a decorated `Null<T>` the unwrapper rejects (a comment
 * between the type and the `=`) are safe misses. Covers class methods, constructors, and local
 * functions; generic, nested `Null<Null<T>>` (one layer only), and function-type inner types
 * unwrap correctly for both the `Null<T>`-wrapped and bare-type forms. Note: parameter metadata is
 * not representable — the grammar does not parse `@:m` on a parameter — so there is no
 * metadata-preservation case to assert here.
 */
class OptionalParamShorthandCheckTest extends Test {

	public function testFlagged(): Void {
		final source: String = fn('a:Null<String> = null');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('optional-param-shorthand', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('prefer ?a:String over a:Null<String> = null', vs[0].message);
		Assert.equals('a:Null<String> = null', source.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testBasicFix(): Void {
		Assert.equals(fn('?a:String'), applyFix(fn('a:Null<String> = null')));
	}

	public function testNonNullDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fn('a:Null<Int> = 3')).length);
	}

	public function testPlainTypeNullDefaultFlagged(): Void {
		final source: String = fn('a:String = null');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('prefer ?a:String over a:String = null', vs[0].message);
		Assert.equals(fn('?a:String'), applyFix(source));
	}

	public function testBareTypeGenericFix(): Void {
		Assert.equals(fn('?a:Map<String, Int>'), applyFix(fn('a:Map<String, Int> = null')));
	}

	public function testBareTypeFunctionTypeFix(): Void {
		Assert.equals(fn('?cb:Int->Void'), applyFix(fn('cb:Int->Void = null')));
	}

	public function testNoTypeAnnotationNotFlagged(): Void {
		Assert.equals(0, violations(fn('a = null')).length);
	}

	public function testDecoratedNullTypeNotFlagged(): Void {
		// A `Null<T>` the unwrapper rejects (a comment between the type and the `=`) must
		// stay a safe miss, not fall through to the bare-type arm without unwrapping.
		Assert.equals(0, violations(fn('a:Null<Int> /* note */ = null')).length);
	}

	public function testMultipleParamsBareTypeFixedCommasIntact(): Void {
		final source: String = fn('a:String = null, ?b:Int, c:Int = 5');
		Assert.equals(1, violations(source).length);
		Assert.equals(fn('?a:String, ?b:Int, c:Int = 5'), applyFix(source));
	}

	public function testAlreadyOptionalNoDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fn('?a:String')).length);
		Assert.equals(0, violations(fn('?a:Null<String>')).length);
	}

	public function testRedundantSigilFlagged(): Void {
		final source: String = fnStatic('?a:Int = 5');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('optional-param-shorthand', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('?a:Int = 5', source.substring(vs[0].span.from, vs[0].span.to));
		Assert.equals(fnStatic('a:Int = 5'), applyFix(source));
	}

	public function testRedundantSigilStringFix(): Void {
		Assert.equals(fnStatic('s:String = "q"'), applyFix(fnStatic('?s:String = "q"')));
	}

	public function testRedundantSigilNegativeDefaultFix(): Void {
		Assert.equals(fnStatic('k:Int = -1'), applyFix(fnStatic('?k:Int = -1')));
	}

	public function testRedundantSigilNullDefaultStaysOldArm(): Void {
		final source: String = fn('?m:Map<String, Int> = null');
		Assert.equals(1, violations(source).length);
		Assert.equals(fn('?m:Map<String, Int>'), applyFix(source));
	}

	public function testRedundantSigilMixedParamsFixedCommasIntact(): Void {
		final source: String = fnStatic('a:Null<String> = null, ?b:Int = 5, c:Int = 1');
		Assert.equals(2, violations(source).length);
		Assert.equals(fnStatic('?a:String, b:Int = 5, c:Int = 1'), applyFix(source));
	}

	public function testRedundantSigilNullComparisonNotFlagged(): Void {
		Assert.equals(0, violations(fnBody('if (a == null) trace(a);')).length);
	}

	public function testRedundantSigilNullAssignNotFlagged(): Void {
		Assert.equals(0, violations(fnBody('a = null;')).length);
	}

	public function testRedundantSigilUnrelatedNullVarStillFlagged(): Void {
		Assert.equals(1, violations(fnBody('var x:Null<Int> = null;')).length);
	}

	public function testRedundantSigilSwitchSubjectNotFlagged(): Void {
		Assert.equals(0, violations(fnBody('switch a { case null: trace(1); case _: }')).length);
	}

	public function testRedundantSigilExtendsNotFlagged(): Void {
		Assert.equals(0, violations('class C extends B { function f(?a:Int = 5):Void {} }').length);
	}

	public function testRedundantSigilImplementsNotFlagged(): Void {
		Assert.equals(0, violations('class C implements I { function f(?a:Int = 5):Void {} }').length);
	}

	public function testRedundantSigilInterfaceNotFlagged(): Void {
		Assert.equals(0, violations('interface I { function h(?p:Bool = true):Void; }').length);
	}

	public function testRedundantSigilLocalFunctionFlaggedDespiteEnclosingExtends(): Void {
		final source: String = 'class C extends B {\n\tfunction f():Void {\n\t\tfunction g(?a:Int = 5):Void {}\n\t}\n}';
		Assert.equals(1, violations(source).length);
	}

	public function testRedundantSigilByteExactFix(): Void {
		Assert.equals('class C {\n\tstatic function f(a:Int = 5):Void {}\n}', applyFix(fnStatic('?a:Int = 5')));
	}

	public function testRedundantSigilAnonTypeNoDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fn('?a:{x:Int}')).length);
	}

	public function testRedundantSigilAnonTypeNullDefaultOldArm(): Void {
		final source: String = fn('?a:{x:Int} = null');
		Assert.equals(1, violations(source).length);
		Assert.equals(fn('?a:{x:Int}'), applyFix(source));
	}

	public function testRedundantSigilConstructorExemptFlagged(): Void {
		final source: String = 'class C extends B { public function new(?a:Int = 5) { super(); } }';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(applyFix(source).indexOf('new(a:Int = 5)') != -1);
	}

	public function testRedundantSigilStaticExemptFlagged(): Void {
		Assert.equals(1, violations('class C extends B { static function f(?a:Int = 5):Void {} }').length);
	}

	public function testRedundantSigilOverrideNotFlagged(): Void {
		Assert.equals(0, violations('class C extends B { override function f(?a:Int = 5):Void {} }').length);
	}

	public function testRedundantSigilPlainInstanceMethodNotFlagged(): Void {
		// G5: a plain instance method of a NON-extending, NON-implementing class is still
		// overridable from another file's subclass — G2 alone (which only looks at THIS
		// type's own supertype clause) cannot see that risk.
		Assert.equals(0, violations('class C { function f(?a:Int = 5):Void {} }').length);
	}

	public function testRedundantSigilOverridableBaseNotFlagged(): Void {
		// The exact shape that broke a real build: `Base` carries no supertype clause of its
		// own (G2 would not refuse it), but `Sub` overrides it — dropping `?` on `Base.ovr`
		// desyncs the two signatures (`Field ovr overrides parent class with different or
		// incomplete type`). Both members must be refused; 0 total is the discriminating
		// count (before G5, Base.ovr alone was flagged, making this 1).
		final source: String =
			'class Base { public function ovr(?a:Int = 5):Void {} } class Sub extends Base { override function ovr(?a:Int = 5):Void {} }';
		Assert.equals(0, violations(source).length);
	}

	public function testRedundantSigilFinalMemberFlagged(): Void {
		// G5 exemption: a `final` method can never be overridden further, regardless of
		// whether its enclosing class extends/implements anything.
		Assert.equals(1, violations('class C { public final function f(?a:Int = 5):Void {} }').length);
	}

	public function testRedundantSigilInlineMemberFlagged(): Void {
		// G5 exemption: `inline` — measured `Field mi is inlined and cannot be overridden`.
		Assert.equals(1, violations('class C { inline function f(?a:Int = 5):Void {} }').length);
	}

	public function testRedundantSigilSiblingCallArgsFlagged(): Void {
		// G3' narrowing proof: `a` and `null` are sibling ARGUMENTS of one call, not compared
		// or assigned to each other — this must be FLAGGED now (it was the single biggest
		// false-refusal cluster on a real tree: 10 of ~21 sites in one file, all shaped like
		// `new TextFormat(fontName, 12, color, false, null, null, null, null, ...)`).
		Assert.equals(1, violations(fnBody('foo(a, null);')).length);
	}

	public function testAlreadyOptionalUntypedNotFlagged(): Void {
		Assert.equals(0, violations(fn('?a = null')).length);
	}

	public function testAlreadyOptionalRedundantNullDefaultFlagged(): Void {
		final source: String = fn('?a:Float = null');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('prefer ?a:Float over ?a:Float = null', vs[0].message);
		Assert.equals(fn('?a:Float'), applyFix(source));
	}

	public function testAlreadyOptionalNullWrappedDropsDefaultKeepsType(): Void {
		// No unwrap on an already-optional parameter — only the redundant default goes.
		final source: String = fn('?a:Null<String> = null');
		Assert.equals(1, violations(source).length);
		Assert.equals(fn('?a:Null<String>'), applyFix(source));
	}

	public function testNoDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fn('a:Null<String>')).length);
	}

	public function testGenericUnwrapFix(): Void {
		Assert.equals(fn('?a:Map<String, Int>'), applyFix(fn('a:Null<Map<String, Int>> = null')));
	}

	public function testNestedNullUnwrapsOneLayer(): Void {
		Assert.equals(fn('?a:Null<Int>'), applyFix(fn('a:Null<Null<Int>> = null')));
	}

	public function testFunctionTypeUnwrapFix(): Void {
		Assert.equals(fn('?cb:Int->Void'), applyFix(fn('cb:Null<Int->Void> = null')));
	}

	public function testMultipleParamsOneFixedCommasIntact(): Void {
		final source: String = fn('a:Null<String> = null, ?b:Int, c:Int = 5');
		Assert.equals(1, violations(source).length);
		Assert.equals(fn('?a:String, ?b:Int, c:Int = 5'), applyFix(source));
	}

	public function testConstructorParam(): Void {
		final source: String = 'class C {\n\tpublic function new(a:Null<String> = null) {}\n}';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(applyFix(source).indexOf('new(?a:String)') != -1);
	}

	public function testLocalFunctionParam(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfunction g(a:Null<Int> = null):Void {}\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(applyFix(source).indexOf('g(?a:Int)') != -1);
	}

	public function testApplyFixByteExact(): Void {
		Assert.equals('class C {\n\tfunction f(?a:String):Void {}\n}', applyFix(fn('a:Null<String> = null')));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('optional-param-shorthand'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('optional-param-shorthand'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(').length);
	}

	private function fn(params: String): String {
		return 'class C {\n\tfunction f($params):Void {}\n}';
	}

	/**
	 * `fn(params)` with `static` on the member — G5 refuses a plain INSTANCE method (it
	 * could be overridden from another file), so the redundant-sigil arm's positive
	 * (flagged) fixtures need a provably un-overridable shape; `static` is the simplest one.
	 */
	private function fnStatic(params: String): String {
		return 'class C {\n\tstatic function f($params):Void {}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new OptionalParamShorthand().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new OptionalParamShorthand(), source);
	}

	/**
	 * `fn('?a:Int = 5')` with `bodyStmts` as the function body instead of an empty one — for
	 * the G3/G4 gates, which read the enclosing function's whole body for a null-comparison /
	 * switch-subject use of `a`.
	 */
	private function fnBody(bodyStmts: String): String {
		return 'class C {\n\tstatic function f(?a:Int = 5):Void {\n\t\t$bodyStmts\n\t}\n}';
	}

}
