package unit;

/**
 * The `explicit-local-type` autofix where the annotation is recovered from a READ
 * rather than from the initializer's own literal shape: a fixed-return method call
 * on a provable-String receiver (a string literal OR a variable whose declared type
 * resolves to `String`, `Null<String>` included), a plain identifier read whose
 * binding — local, parameter or own-class field — carries a written type, copied
 * VERBATIM so `Null<…>` is preserved, a cross-class `Type.staticField` read whose
 * field's builtin (always-in-scope) written type is recovered from the cross-file `SymbolIndex`, `Null<…>` preserved, and a tabled `Type.staticMethod()` call.
 *
 * Every inference-resolved shape stays report-only: a generic `.map()`, an
 * unresolved / non-String receiver, an untabled method, an identifier whose binding
 * carries no written type or is a parameter whose body type differs from its source
 * (optional-no-default, `= null` default, or rest), a static field read with no
 * index / an unknown-or-ambiguous type / an inference-typed or non-builtin-typed
 * member / an instance-access receiver, and a receiver shadowed by a local.
 */
class ExplicitLocalTypeReadFixTest extends ExplicitLocalTypeCheckTestBase {

	// --- fix: method call on a provable-String receiver (literal or typed variable) ---

	public inline function testFixStringLiteralMethodCall(): Void {
		// string-literal receiver is provably String → tabled `split` return.
		assertFixContains("final parts = 'a,b'.split(',');", ':Array<String>');
	}

	public inline function testFixTypedStringReceiverSplit(): Void {
		assertFixContains("var s:String = 'x';\n\t\tfinal p = s.split('/');", ':Array<String>');
	}

	public inline function testFixNullableStringReceiverSplit(): Void {
		// the real case: a `Null<String>` receiver, a String at the call — split types Array<String>.
		assertFixContains("var entityStr:Null<String> = 'x';\n\t\tfinal parts = entityStr.split('/');", ':Array<String>');
	}

	public inline function testFixStringReceiverIndexOf(): Void {
		assertFixContains("var s:String = 'x';\n\t\tfinal i = s.indexOf('/');", ':Int');
	}

	// --- fix: identifier read (own field / parameter / typed local) ---

	public inline function testFixOwnFieldRead(): Void {
		assertFixContainsSrc('class C {\n\tfinal entity:String;\n\tfunction f():Void {\n\t\tfinal v = entity;\n\t}\n}', 'v:String');
	}

	public inline function testFixNullableFieldReadPreservesNull(): Void {
		// The soundness case: a `Null<String>` field read stays `Null<String>`, NOT flattened to `String`.
		assertFixContainsSrc('class C {\n\tfinal amt:Null<String>;\n\tfunction f():Void {\n\t\tfinal v = amt;\n\t}\n}', 'v:Null<String>');
	}

	public inline function testFixUserTypeFieldRead(): Void {
		assertFixContainsSrc('class C {\n\tfinal dep:Foo;\n\tfunction f():Void {\n\t\tfinal v = dep;\n\t}\n}', 'v:Foo');
	}

	public inline function testFixParameterRead(): Void {
		assertFixContainsSrc('class C {\n\tfunction f(p:String):Void {\n\t\tfinal v = p;\n\t}\n}', 'v:String');
	}

	public inline function testFixOptionalParamWithDefaultRead(): Void {
		// `?p:String = "x"` has a default -> body type String (non-null) -> copy verbatim.
		assertFixContainsSrc('class C {\n\tfunction f(?p:String = "x"):Void {\n\t\tfinal v = p;\n\t}\n}', 'v:String');
	}

	public inline function testFixRequiredParamWithDefaultRead(): Void {
		// `p:Int = 3` (required, NON-null default) -> body type Int -> copy verbatim.
		assertFixContainsSrc('class C {\n\tfunction f(p:Int = 3):Void {\n\t\tfinal v = p;\n\t}\n}', 'v:Int');
	}

	public inline function testFixTypedLocalRead(): Void {
		assertFixContains('var a:Int = 5;\n\t\tfinal v = a;', 'v:Int');
	}

	// --- fix: inference-resolved shapes stay report-only ---

	public inline function testSkipGenericMethodCall(): Void {
		assertNoFix("final mapped = ['a'].map(z -> z);");
	}

	public inline function testSkipUnknownReceiverMethodCall(): Void {
		// receiver's type does not resolve → report-only, no fix.
		assertNoFix("final parts = unknownVar.split(',');");
	}

	public inline function testSkipNonStringReceiverTabledMethod(): Void {
		// `indexOf` is tabled for String, but the receiver is an Array — not provably String → report-only.
		assertNoFix('var xs:Array<Int> = [1];\n\t\tfinal i = xs.indexOf(1);');
	}

	public inline function testSkipUntabledStringMethod(): Void {
		// `charCodeAt` returns Null<Int>, deliberately absent from the table → report-only.
		assertNoFix("var s:String = 'x';\n\t\tfinal c = s.charCodeAt(0);");
	}

	public inline function testSkipReshadowedReceiver(): Void {
		// CF-1: `s` re-shadowed in the same scope. The first-wins resolver would pick the
		// String declaration, but Haxe binds to the nearer `Foo` (Foo.split -> Int), so a
		// written Array<String> would be a compile error. Stay report-only.
		assertNoFix("var s:String = 'x';\n\t\tvar s:Foo = new Foo();\n\t\tfinal p = s.split('/');");
	}

	public inline function testSkipUntypedFieldRead(): Void {
		// The field source has no written type (inference-typed) → nothing to copy → report-only.
		assertNoFixSrc('class C {\n\tfinal raw = 5;\n\tfunction f():Void {\n\t\tfinal v = raw;\n\t}\n}');
	}

	public inline function testSkipUnresolvedIdentRead(): Void {
		// `mystery` binds to no declaration → report-only.
		assertNoFix('final v = mystery;');
	}

	public inline function testSkipOptionalParamRead(): Void {
		// `?p:String` (no default) has body type Null<String> but written source `String`;
		// a verbatim copy would drop the nullability, so stay report-only.
		assertNoFixSrc('class C {\n\tfunction f(?p:String):Void {\n\t\tfinal v = p;\n\t}\n}');
	}

	public inline function testSkipRequiredNullDefaultParamRead(): Void {
		// `p:String = null` -> body type Null<String> (null default is nullable per Haxe
		// null-safety), but written source `String` -> report-only.
		assertNoFixSrc('class C {\n\tfunction f(p:String = null):Void {\n\t\tfinal v = p;\n\t}\n}');
	}

	public inline function testSkipOptionalNullDefaultParamRead(): Void {
		// `?p:String = null` -> body type Null<String>, written source `String` -> report-only.
		assertNoFixSrc('class C {\n\tfunction f(?p:String = null):Void {\n\t\tfinal v = p;\n\t}\n}');
	}

	public inline function testSkipRestParamRead(): Void {
		// `...p:Int` -> body type haxe.Rest<Int>, not the written `Int` -> report-only.
		assertNoFixSrc('class C {\n\tfunction f(...p:Int):Void {\n\t\tfinal v = p;\n\t}\n}');
	}

	public inline function testSkipReshadowedIdentRead(): Void {
		// CF-1 shadow guard on the plain-read path: `s` re-shadowed in a visible scope.
		assertNoFix("var s:String = 'x';\n\t\tvar s:Int = 5;\n\t\tfinal v = s;");
	}

	// --- fix: static-method call whose Type.method return is tabled (macro-API + stdlib) ---

	public inline function testFixStaticMethodCallResolvePath(): Void {
		// Context.resolvePath(path):String inside a (macro) function body — display-oracle blind,
		// pinned structurally by the static-method-return table.
		assertFixContains('final p = Context.resolvePath(path);', 'p:String');
	}

	public inline function testFixStaticMethodCallCurrentPosDotted(): Void {
		// A dotted `haxe.macro.Context` receiver still resolves by simple type name.
		assertFixContains('final pos = haxe.macro.Context.currentPos();', 'pos:haxe.macro.Expr.Position');
	}

	public inline function testFixStaticMethodDateNow(): Void {
		// stdlib static return, non-generic.
		assertFixContains('final n = Date.now();', 'n:Date');
	}

	public inline function testFixStaticMethodFileAppend(): Void {
		assertFixContains("final f = sys.io.File.append('x', false);", 'f:sys.io.FileOutput');
	}

	public inline function testSkipUntabledStaticMethod(): Void {
		// `Context.getType` returns a generic-dependent `Type`, deliberately absent from the table.
		assertNoFix("final t = Context.getType('Foo');");
	}

	public inline function testSkipStaticMethodReceiverShadowedByLocal(): Void {
		// A local named `Date` shadows the type: `Date.now()` reads the local's field, not the
		// static. The receiver resolves to a value binding -> report-only.
		assertNoFix('var Date:C = this;\n\t\tfinal n = Date.now();');
	}

	// --- fix: cross-class static field read (Type.field, via SymbolIndex) ---

	public function testFixCrossClassStaticFieldRead(): Void {
		assertFixIdx(wrap('var v = API.API_URL;'), [
			{ file: 'API.hx', source: 'class API {\n\tpublic static final API_URL:String = "x";\n}' }
		], 'v:String');
	}

	public function testFixCrossClassStaticNullableFieldPreservesNull(): Void {
		// The soundness case: a `Null<String>` static field read stays `Null<String>`.
		assertFixIdx(wrap('var v = API.TOKEN;'), [
			{ file: 'API.hx', source: 'class API {\n\tpublic static final TOKEN:Null<String> = null;\n}' }
		], 'v:Null<String>');
	}

	public function testFixSameFileStaticFieldRead(): Void {
		// Both types in one module file — the index still carries the sibling type.
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\tvar v = API.API_URL;\n\t}\n}\nclass API {\n\tpublic static final API_URL:Int = 5;\n}';
		assertFixIdx(src, [], 'v:Int');
	}

	public function testFixStaticFieldReadUnderConditional(): Void {
		// `#if`/`#else` static field, SAME type in both branches -> unanimous -> resolves.
		final api: String = 'class API {\n#if release\n\tpublic static final API_URL:String = "a";\n#else\n'
			+ '\tpublic static final API_URL:String = "b";\n#end\n}';
		assertFixIdx(wrap('var v = API.API_URL;'), [{ file: 'API.hx', source: api }], 'v:String');
	}

	// --- fix: static field read report-only cases ---

	public function testSkipStaticFieldNoIndex(): Void {
		// Without a threaded index the cross-file receiver cannot resolve -> report-only.
		assertNoFixSrc(wrap('var v = API.API_URL;'));
	}

	public function testSkipStaticFieldUnknownType(): Void {
		assertNoFixIdx(wrap('var v = Unknown.FOO;'), [
			{ file: 'API.hx', source: 'class API {\n\tpublic static final API_URL:String = "x";\n}' }
		]);
	}

	public function testSkipStaticFieldAmbiguousType(): Void {
		// Two indexed `class API` disagree on the member type -> ambiguous -> report-only.
		assertNoFixIdx(wrap('var v = API.API_URL;'), [
			{ file: 'A.hx', source: 'class API {\n\tpublic static final API_URL:String = "x";\n}' },
			{ file: 'B.hx', source: 'class API {\n\tpublic static final API_URL:Int = 5;\n}' }
		]);
	}

	public function testSkipStaticFieldUntypedMember(): Void {
		// The member has no written type (inference-typed) -> nothing to copy -> report-only.
		assertNoFixIdx(wrap('var v = API.API_URL;'), [{ file: 'API.hx', source: 'class API {\n\tpublic static final API_URL = 5;\n}' }]);
	}

	public function testSkipStaticFieldNonBuiltinType(): Void {
		// The field type `Token` is spelled in API.hx's import scope; copying it into C.hx
		// (which does not import Token) would not resolve -> report-only.
		assertNoFixIdx(wrap('var v = API.CURRENT;'), [
			{ file: 'API.hx', source: 'class API {\n\tpublic static final CURRENT:Token = null;\n}' }
		]);
	}

	public function testSkipStaticFieldConditionalDiffers(): Void {
		// `#if`/`#else` static field of DIFFERING types -> not unanimous -> report-only.
		final api: String =
			'class API {\n#if release\n\tpublic static final API_URL:String = "a";\n#else\n\tpublic static final API_URL:Int = 1;\n#end\n}';
		assertNoFixIdx(wrap('var v = API.API_URL;'), [{ file: 'API.hx', source: api }]);
	}

	public function testSkipInstanceFieldAccess(): Void {
		// A lower-initial VALUE receiver is an instance access, not a static one -> report-only.
		assertNoFixIdx(wrap("final obj:String = 'x';\n\t\tfinal v = obj.length;"), []);
	}

	public function testSkipStaticFieldReceiverShadowedByLocal(): Void {
		// A local named `API` shadows the type: `API.API_URL` now reads the local's field, not
		// the static. The receiver resolves to a value binding -> report-only.
		assertNoFixIdx(wrap('var API:C = this;\n\t\tvar v = API.API_URL;'), [
			{ file: 'API.hx', source: 'class API {\n\tpublic static final API_URL:String = "x";\n}' }
		]);
	}

	public function testSkipStaticMethodIndexShadowedType(): Void {
		// An indexed project type named `Date` shadows the stdlib -> its `now()` may differ -> report-only.
		assertNoFixIdx(wrap('final n = Date.now();'), [
			{ file: 'Date.hx', source: 'class Date {\n\tpublic static function now():Int return 0;\n}' }
		]);
	}

}
