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

	public function testHoistSoleCoalescingReadFlagged(): Void {
		final source: String = fnConst('?a:Int', 'final x:Int = a ?? 7;');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('optional-param-shorthand', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('prefer a:Int = 7 over ?a:Int with a ?? 7', vs[0].message);
		Assert.equals('?a:Int', source.substring(vs[0].span.from, vs[0].span.to));
		Assert.equals(fnConst('a:Int = 7', 'final x:Int = a;'), applyFix(source));
	}

	public function testHoistInlineConstantDefaultFlagged(): Void {
		// The `DEFAULT_LIST_WIDTH` shape: a bare identifier bound to a same-class `static
		// inline final`, which Haxe accepts as a parameter default.
		final source: String = fnConst('?a:Int', 'final x:Int = a ?? D;');
		Assert.equals(1, violations(source).length);
		Assert.equals(fnConst('a:Int = D', 'final x:Int = a;'), applyFix(source));
	}

	public function testHoistEnumAbstractDefaultFlagged(): Void {
		final source: String = 'enum abstract Fmt(Int) {\n\tfinal JSON = 0;\n}\n\n'
			+ 'class C {\n\tstatic function f(?a:Fmt):Void {\n\t\tfinal x:Fmt = a ?? Fmt.JSON;\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(applyFix(source).indexOf('f(a:Fmt = Fmt.JSON)') != -1);
	}

	public function testHoistFloatDefaultOnIntParamNotFlagged(): Void {
		// `w ?? 0.` widens to `Float` and compiles; `w:Int = 0.` does not. The `??` the arm
		// replaces is not evidence that the fallback fits the DECLARED type.
		Assert.equals(0, violations(fnConst('?w:Int', 'final x:Float = w ?? 0.;')).length);
	}

	public function testHoistFloatDefaultOnFloatParamFlagged(): Void {
		final source: String = fnConst('?w:Float', 'final x:Float = w ?? 0.;');
		Assert.equals(1, violations(source).length);
		Assert.equals(fnConst('w:Float = 0.', 'final x:Float = w;'), applyFix(source));
	}

	public function testHoistIntLiteralOnUnmappedTypeFlagged(): Void {
		// `UInt` is a type the grammar's literal map never produces, so whether an integer
		// literal converts is the compiler's question, not the map's — and refusing there
		// would lose every enum-abstract and `UInt` default.
		final source: String = fnConst('?c:UInt', 'final x:UInt = c ?? 0x10;');
		Assert.equals(1, violations(source).length);
		Assert.equals(fnConst('c:UInt = 0x10', 'final x:UInt = c;'), applyFix(source));
	}

	public function testHoistCallDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fnConst('?a:Int', 'final x:Int = a ?? g();')).length);
	}

	public function testHoistNonInlineStaticFinalDefaultNotFlagged(): Void {
		// A non-inline `static final` is not a legal parameter default (`Default argument value
		// should be constant`), so the rewrite would not compile.
		final source: String =
			'class C {\n\tstatic final N:Int = 7;\n\tstatic function f(?a:Int):Void {\n\t\tfinal x:Int = a ?? N;\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testHoistFieldSubjectNotFlagged(): Void {
		// The `BreadCrumbs` shape: `boxHeight ?? 0.` reads a FIELD, syntactically
		// indistinguishable from a parameter read. A same-named parameter on ANOTHER
		// function must not claim it.
		final source: String = 'class C {\n\tvar boxHeight:Float = 0;\n\tstatic function g(?boxHeight:Float):Void {}\n'
			+ '\tfunction h():Float {\n\t\treturn boxHeight ?? 0.;\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testHoistTwoDifferentDefaultsNotFlagged(): Void {
		Assert.equals(0, violations(fnConst('?a:Int', 'final x:Int = a ?? 7;\n\t\tfinal y:Int = a ?? 8;')).length);
	}

	public function testHoistSameDefaultTwiceFlagged(): Void {
		final source: String = fnConst('?a:Int', 'final x:Int = a ?? 7;\n\t\tfinal y:Int = a ?? 7;');
		Assert.equals(1, violations(source).length);
		Assert.equals(fnConst('a:Int = 7', 'final x:Int = a;\n\t\tfinal y:Int = a;'), applyFix(source));
	}

	public function testHoistNullComparisonElsewhereNotFlagged(): Void {
		Assert.equals(0, violations(fnConst('?a:Int', 'if (a == null) trace(1);\n\t\tfinal x:Int = a ?? 7;')).length);
	}

	public function testHoistOverrideNotFlagged(): Void {
		Assert.equals(0, violations('class C extends B {\n\toverride function f(?a:Int):Void {\n\t\tfinal x:Int = a ?? 7;\n\t}\n}').length);
	}

	public function testHoistInterfaceDeclarationNotFlagged(): Void {
		Assert.equals(0, violations('interface I {\n\tfunction f(?a:Int):Void;\n}').length);
	}

	public function testHoistPlainInstanceMethodNotFlagged(): Void {
		// G5, shared with the redundant-sigil arm: a plain instance method can be overridden
		// from another file's subclass, and the rewrite changes the parameter's declared type.
		Assert.equals(0, violations('class C {\n\tfunction f(?a:Int):Void {\n\t\tfinal x:Int = a ?? 7;\n\t}\n}').length);
	}

	public function testHoistFieldWriteOfSameNameFlagged(): Void {
		// The commonest constructor idiom, `this.a = a ?? CONST`: `this.a` is a FIELD
		// reference, not a read of the parameter, so it must not block the hoist. The
		// completeness scan skips a DOT-QUALIFIED occurrence for exactly this reason — a
		// parameter is never reached through a `.`.
		final source: String = 'class C {\n\tpublic var a:Int;\n\n\tpublic function new(?a:Int) {\n\t\tthis.a = a ?? 7;\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(applyFix(source).indexOf('new(a:Int = 7)') != -1);
	}

	public function testHoistUnaccountedReadNotFlagged(): Void {
		// Completeness: a read that is NOT a coalescing left operand still observes `null`,
		// which the hoist removes from the parameter's value range.
		Assert.equals(0, violations(fnConst('?a:Int', 'trace(a);\n\t\tfinal x:Int = a ?? 7;')).length);
	}

	public function testHoistAssignedParamNotFlagged(): Void {
		Assert.equals(0, violations(fnConst('?a:Int', 'a = 3;\n\t\tfinal x:Int = a ?? 7;')).length);
	}

	public function testHoistNullDefaultNotFlagged(): Void {
		// `a:Int = null` is the FIRST arm's input shape — hoisting a `?? null` would make the
		// two arms rewrite each other forever.
		Assert.equals(0, violations(fnConst('?a:Int', 'final x:Null<Int> = a ?? null;')).length);
	}

	public function testHoistNullWrappedTypeUnwrapped(): Void {
		// `a:Null<Int> = 7` would leave the body type nullable and the reads it feeds broken;
		// one `Null<>` layer comes off, exactly as the first arm's rewrite does.
		final source: String = fnConst('?a:Null<Int>', 'final x:Int = a ?? 7;');
		Assert.equals(1, violations(source).length);
		Assert.equals(fnConst('a:Int = 7', 'final x:Int = a;'), applyFix(source));
	}

	public function testHoistUntypedColonDefaultNotFlagged(): Void {
		// An UNTYPED optional parameter whose default spells a colon of its own. Reading the
		// annotation with a plain `indexOf(':')` would take that one and emit `c:" = 7`.
		Assert.equals(0, violations(fnConst('?c = ":"', 'final x:Int = c ?? 7;')).length);
	}

	public function testHoistShadowedOuterParamNotFlagged(): Void {
		// The inner local function's own `?a:Int` shadows the outer parameter, so the
		// coalescing read belongs to the INNER one: only it is rewritten.
		final source: String = fnConst('?a:Int', 'function g(?a:Int):Void {\n\t\t\tfinal y:Int = a ?? 7;\n\t\t}\n\t\tg();');
		Assert.equals(1, violations(source).length);
		final fixed: String = applyFix(source);
		Assert.isTrue(fixed.indexOf('function g(a:Int = 7)') != -1);
		Assert.isTrue(fixed.indexOf('f(?a:Int)') != -1);
	}

	public function testHoistDefaultedParamStaysRedundantSigilArm(): Void {
		// `?a:Int = 5` already carries a default, so the redundant-sigil arm owns it; the
		// hoist arm requires a parameter with NONE.
		final source: String = fnConst('?a:Int = 5', 'final x:Int = a ?? 7;');
		Assert.equals(1, violations(source).length);
		Assert.equals(fnConst('a:Int = 5', 'final x:Int = a ?? 7;'), applyFix(source));
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

	/**
	 * The hoist arm's fixture: a `static` function taking `params` with `body` as its body,
	 * alongside a `static inline final D` to default from. `static` because G5 refuses a
	 * plain instance method — a subclass in another file could override it.
	 */
	private function fnConst(params: String, body: String): String {
		return 'class C {\n\tstatic inline final D:Int = 7;\n\tstatic function f($params):Void {\n\t\t$body\n\t}\n}';
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
