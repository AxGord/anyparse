package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ExplicitLocalType;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;

/**
 * The `explicit-local-type` check: a local `var` / `final` with no `:Type`
 * annotation is flagged (statement-position locals only; a typed local, a macro-
 * reification local, and non-local bindings are exempt). Default OFF — dropped from
 * the default set unless `apqlint.json` opts in (`enabled:true`) or an explicit rule
 * selection bypasses enablement. The autofix annotates ONLY a structurally-pinned
 * initializer type (literal / neg-numeric / written-generic `new` / homogeneous
 * array literal / a fixed-return method call on a provable-String receiver — a string
 * literal OR a variable whose declared type resolves to `String`, `Null<String>`
 * included / a plain identifier read whose binding — local, parameter or own-class
 * field — carries a written type, copied VERBATIM so `Null<…>` is preserved / a
 * cross-class `Type.staticField` read whose field's builtin (always-in-scope) written
 * type is recovered from the cross-file `SymbolIndex`, `Null<…>` preserved), re-stating
 * the compiler's own inference; every inference-resolved shape (empty / heterogeneous
 * array, bare `new`, `new Map()`, `null`, a generic `.map()`, an unresolved / non-String
 * receiver, an untabled method, an identifier whose binding carries no written type or is
 * a parameter whose body type differs from its source (optional-no-default, `= null`
 * default, or rest), a static field read with no index / an unknown-or-ambiguous type /
 * an inference-typed or non-builtin-typed member / an instance-access receiver) stays
 * report-only.
 */
class ExplicitLocalTypeCheckTest extends Test {

	// --- detection ---

	public function testUntypedVarFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('var a = 5;'));
		Assert.equals(1, vs.length);
		Assert.equals('explicit-local-type', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testUntypedFinalFlagged(): Void {
		Assert.equals(1, violations(wrap('final a = 5;')).length);
	}

	public function testTypedLocalNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var a:Int = 5;')).length);
	}

	public function testTypedFinalNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final a:String = "x";')).length);
	}

	public function testParameterNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(p):Void {}\n}').length);
	}

	public function testNoInitUntypedFlaggedNoFix(): Void {
		final src: String = wrap('var a;');
		Assert.equals(1, violations(src).length);
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	public function testMacroLocalSkipped(): Void {
		final src: String = 'class C {\n\tmacro static function f() {\n\t\treturn macro {\n\t\t\tvar inside = 5;\n\t\t};\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	// --- fix: structurally-pinned shapes annotated ---

	public function testFixString(): Void {
		assertFixContains("final s = 'hello';", ':String');
	}

	public function testFixInt(): Void {
		assertFixContains('var a = 5;', ':Int');
	}

	public function testFixFloat(): Void {
		assertFixContains('var d = 1.5;', ':Float');
	}

	public function testFixBool(): Void {
		assertFixContains('final b = true;', ':Bool');
	}

	public function testFixNegInt(): Void {
		assertFixContains('var e = -3;', ':Int');
	}

	public function testFixHomogeneousIntArray(): Void {
		assertFixContains('final arr = [1, 2, 3];', ':Array<Int>');
	}

	public function testFixHomogeneousStringArray(): Void {
		assertFixContains("var strs = ['a', 'b'];", ':Array<String>');
	}

	public function testFixNewWithWrittenGenerics(): Void {
		assertFixContains('final m = new Map<String, Int>();', ':Map<String, Int>');
	}

	// --- fix: method call on a provable-String receiver (literal or typed variable) ---

	public function testFixStringLiteralMethodCall(): Void {
		// string-literal receiver is provably String → tabled `split` return.
		assertFixContains("final parts = 'a,b'.split(',');", ':Array<String>');
	}

	public function testFixTypedStringReceiverSplit(): Void {
		assertFixContains("var s:String = 'x';\n\t\tfinal p = s.split('/');", ':Array<String>');
	}

	public function testFixNullableStringReceiverSplit(): Void {
		// the real case: a `Null<String>` receiver, a String at the call — split types Array<String>.
		assertFixContains("var entityStr:Null<String> = 'x';\n\t\tfinal parts = entityStr.split('/');", ':Array<String>');
	}

	public function testFixStringReceiverIndexOf(): Void {
		assertFixContains("var s:String = 'x';\n\t\tfinal i = s.indexOf('/');", ':Int');
	}

	// --- fix: identifier read (own field / parameter / typed local) ---

	public function testFixOwnFieldRead(): Void {
		assertFixContainsSrc('class C {\n\tfinal entity:String;\n\tfunction f():Void {\n\t\tfinal v = entity;\n\t}\n}', 'v:String');
	}

	public function testFixNullableFieldReadPreservesNull(): Void {
		// The soundness case: a `Null<String>` field read stays `Null<String>`, NOT flattened to `String`.
		assertFixContainsSrc('class C {\n\tfinal amt:Null<String>;\n\tfunction f():Void {\n\t\tfinal v = amt;\n\t}\n}', 'v:Null<String>');
	}

	public function testFixUserTypeFieldRead(): Void {
		assertFixContainsSrc('class C {\n\tfinal dep:Foo;\n\tfunction f():Void {\n\t\tfinal v = dep;\n\t}\n}', 'v:Foo');
	}

	public function testFixParameterRead(): Void {
		assertFixContainsSrc('class C {\n\tfunction f(p:String):Void {\n\t\tfinal v = p;\n\t}\n}', 'v:String');
	}

	public function testFixOptionalParamWithDefaultRead(): Void {
		// `?p:String = "x"` has a default -> body type String (non-null) -> copy verbatim.
		assertFixContainsSrc('class C {\n\tfunction f(?p:String = "x"):Void {\n\t\tfinal v = p;\n\t}\n}', 'v:String');
	}

	public function testFixRequiredParamWithDefaultRead(): Void {
		// `p:Int = 3` (required, NON-null default) -> body type Int -> copy verbatim.
		assertFixContainsSrc('class C {\n\tfunction f(p:Int = 3):Void {\n\t\tfinal v = p;\n\t}\n}', 'v:Int');
	}

	public function testFixTypedLocalRead(): Void {
		assertFixContains('var a:Int = 5;\n\t\tfinal v = a;', 'v:Int');
	}

	// --- fix: cross-class static field read (Type.field, via SymbolIndex) ---

	public function testFixCrossClassStaticFieldRead(): Void {
		assertFixIdx(wrap('var v = API.API_URL;'), [{ file: 'API.hx', source: 'class API {\n\tpublic static final API_URL:String = "x";\n}' }], 'v:String');
	}

	public function testFixCrossClassStaticNullableFieldPreservesNull(): Void {
		// The soundness case: a `Null<String>` static field read stays `Null<String>`.
		assertFixIdx(
			wrap('var v = API.TOKEN;'), [{ file: 'API.hx', source: 'class API {\n\tpublic static final TOKEN:Null<String> = null;\n}' }],
			'v:Null<String>'
		);
	}

	public function testFixSameFileStaticFieldRead(): Void {
		// Both types in one module file — the index still carries the sibling type.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = API.API_URL;\n\t}\n}\nclass API {\n\tpublic static final API_URL:Int = 5;\n}';
		assertFixIdx(src, [], 'v:Int');
	}

	public function testFixStaticFieldReadUnderConditional(): Void {
		// `#if`/`#else` static field, SAME type in both branches -> unanimous -> resolves.
		final api: String = 'class API {\n#if release\n\tpublic static final API_URL:String = "a";\n#else\n\tpublic static final API_URL:String = "b";\n#end\n}';
		assertFixIdx(wrap('var v = API.API_URL;'), [{ file: 'API.hx', source: api }], 'v:String');
	}

	// --- fix: static field read report-only cases ---

	public function testSkipStaticFieldNoIndex(): Void {
		// Without a threaded index the cross-file receiver cannot resolve -> report-only.
		assertNoFixSrc(wrap('var v = API.API_URL;'));
	}

	public function testSkipStaticFieldUnknownType(): Void {
		assertNoFixIdx(wrap('var v = Unknown.FOO;'), [{ file: 'API.hx', source: 'class API {\n\tpublic static final API_URL:String = "x";\n}' }]);
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
		assertNoFixIdx(wrap('var v = API.CURRENT;'), [{ file: 'API.hx', source: 'class API {\n\tpublic static final CURRENT:Token = null;\n}' }]);
	}

	public function testSkipStaticFieldConditionalDiffers(): Void {
		// `#if`/`#else` static field of DIFFERING types -> not unanimous -> report-only.
		final api: String = 'class API {\n#if release\n\tpublic static final API_URL:String = "a";\n#else\n\tpublic static final API_URL:Int = 1;\n#end\n}';
		assertNoFixIdx(wrap('var v = API.API_URL;'), [{ file: 'API.hx', source: api }]);
	}

	public function testSkipInstanceFieldAccess(): Void {
		// A lower-initial VALUE receiver is an instance access, not a static one -> report-only.
		assertNoFixIdx(wrap("final obj:String = 'x';\n\t\tfinal v = obj.length;"), []);
	}

	public function testSkipStaticFieldReceiverShadowedByLocal(): Void {
		// A local named `API` shadows the type: `API.API_URL` now reads the local's field, not
		// the static. The receiver resolves to a value binding -> report-only.
		assertNoFixIdx(wrap('var API:C = this;\n\t\tvar v = API.API_URL;'), [{ file: 'API.hx', source: 'class API {\n\tpublic static final API_URL:String = "x";\n}' }]);
	}


	// --- fix: inference-resolved shapes stay report-only ---

	public function testSkipEmptyArray(): Void {
		assertNoFix('final empty = [];');
	}

	public function testSkipHeterogeneousArray(): Void {
		assertNoFix("var hetero = [1, 'x'];");
	}

	public function testSkipBareNew(): Void {
		assertNoFix('final bare = new Map();');
	}

	public function testSkipNullInit(): Void {
		assertNoFix('final nul = null;');
	}

	public function testSkipGenericMethodCall(): Void {
		assertNoFix("final mapped = ['a'].map(z -> z);");
	}

	public function testSkipUnknownReceiverMethodCall(): Void {
		// receiver's type does not resolve → report-only, no fix.
		assertNoFix("final parts = unknownVar.split(',');");
	}

	public function testSkipNonStringReceiverTabledMethod(): Void {
		// `indexOf` is tabled for String, but the receiver is an Array — not provably String → report-only.
		assertNoFix("var xs:Array<Int> = [1];\n\t\tfinal i = xs.indexOf(1);");
	}

	public function testSkipUntabledStringMethod(): Void {
		// `charCodeAt` returns Null<Int>, deliberately absent from the table → report-only.
		assertNoFix("var s:String = 'x';\n\t\tfinal c = s.charCodeAt(0);");
	}

	public function testSkipReshadowedReceiver(): Void {
		// CF-1: `s` re-shadowed in the same scope. The first-wins resolver would pick the
		// String declaration, but Haxe binds to the nearer `Foo` (Foo.split -> Int), so a
		// written Array<String> would be a compile error. Stay report-only.
		assertNoFix("var s:String = 'x';\n\t\tvar s:Foo = new Foo();\n\t\tfinal p = s.split('/');");
	}

	public function testSkipUntypedFieldRead(): Void {
		// The field source has no written type (inference-typed) → nothing to copy → report-only.
		assertNoFixSrc('class C {\n\tfinal raw = 5;\n\tfunction f():Void {\n\t\tfinal v = raw;\n\t}\n}');
	}

	public function testSkipUnresolvedIdentRead(): Void {
		// `mystery` binds to no declaration → report-only.
		assertNoFix('final v = mystery;');
	}

	public function testSkipOptionalParamRead(): Void {
		// `?p:String` (no default) has body type Null<String> but written source `String`;
		// a verbatim copy would drop the nullability, so stay report-only.
		assertNoFixSrc('class C {\n\tfunction f(?p:String):Void {\n\t\tfinal v = p;\n\t}\n}');
	}

	public function testSkipRequiredNullDefaultParamRead(): Void {
		// `p:String = null` -> body type Null<String> (null default is nullable per Haxe
		// null-safety), but written source `String` -> report-only.
		assertNoFixSrc('class C {\n\tfunction f(p:String = null):Void {\n\t\tfinal v = p;\n\t}\n}');
	}

	public function testSkipOptionalNullDefaultParamRead(): Void {
		// `?p:String = null` -> body type Null<String>, written source `String` -> report-only.
		assertNoFixSrc('class C {\n\tfunction f(?p:String = null):Void {\n\t\tfinal v = p;\n\t}\n}');
	}

	public function testSkipRestParamRead(): Void {
		// `...p:Int` -> body type haxe.Rest<Int>, not the written `Int` -> report-only.
		assertNoFixSrc('class C {\n\tfunction f(...p:Int):Void {\n\t\tfinal v = p;\n\t}\n}');
	}

	public function testSkipReshadowedIdentRead(): Void {
		// CF-1 shadow guard on the plain-read path: `s` re-shadowed in a visible scope.
		assertNoFix("var s:String = 'x';\n\t\tvar s:Int = 5;\n\t\tfinal v = s;");
	}

	public function testIdempotentOnTyped(): Void {
		final src: String = wrap('var a:Int = 5;');
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	// --- enablement gate ---

	public function testDefaultOffSuppressed(): Void {
		Assert.equals(0, runGated(wrap('var a = 5;'), '{}', true).length);
	}

	public function testOptInEnabled(): Void {
		final json: String = '{"rules":{"explicit-local-type":{"enabled":true}}}';
		Assert.equals(1, runGated(wrap('var a = 5;'), json, true).length);
	}

	public function testExplicitSelectionBypassesGate(): Void {
		// applyEnablement=false is the --rule path: a DefaultOff rule runs regardless.
		Assert.equals(1, runGated(wrap('var a = 5;'), '{}', false).length);
	}

	public function testNoqaSuppression(): Void {
		final json: String = '{"rules":{"explicit-local-type":{"enabled":true}}}';
		Assert.equals(0, runGated(wrap('var a = 5; // noqa'), json, true).length);
	}

	// --- registry / robustness ---

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('explicit-local-type'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('explicit-local-type'));
		Assert.equals(92, Linter.builtins().length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { var a = 5;').length);
	}

	// --- helpers ---

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t' + body + '\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new ExplicitLocalType().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function runGated(source: String, json: String, applyEnablement: Bool): Array<Violation> {
		final resolver: (String) -> LintConfig = function(file: String): LintConfig return LintConfig.parse(json);
		return Linter.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin(), [new ExplicitLocalType()], resolver, applyEnablement);
	}

	private function assertFixContains(body: String, expected: String): Void {
		assertFixContainsSrc(wrap(body), expected);
	}

	private function assertFixContainsSrc(src: String, expected: String): Void {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length >= 1);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(expected) >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertNoFix(body: String): Void {
		assertNoFixSrc(wrap(body));
	}

	private function assertNoFixSrc(src: String): Void {
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	/**
	 * Fix `fixSrc` (as `C.hx`) with a `SymbolIndex` built over it plus `otherFiles`, and
	 * assert the canonicalized result contains `expected` — the cross-file resolution path.
	 */
	private function assertFixIdx(fixSrc: String, otherFiles: Array<{ file: String, source: String }>, expected: String): Void {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final fixFile: { file: String, source: String } = { file: 'C.hx', source: fixSrc };
		final index: SymbolIndex = SymbolIndex.build([fixFile].concat(otherFiles), plugin);
		final vs: Array<Violation> = check.run([fixFile], plugin);
		Assert.isTrue(vs.length >= 1);
		switch RefactorSupport.canonicalize(fixSrc, check.fix(fixSrc, vs, plugin, index), true, plugin) {
			case Ok(text):
				Assert.isTrue(text.indexOf(expected) >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/** As `assertFixIdx`, but asserts no edit is produced (report-only). */
	private function assertNoFixIdx(fixSrc: String, otherFiles: Array<{ file: String, source: String }>): Void {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final fixFile: { file: String, source: String } = { file: 'C.hx', source: fixSrc };
		final index: SymbolIndex = SymbolIndex.build([fixFile].concat(otherFiles), plugin);
		Assert.equals(0, check.fix(fixSrc, check.run([fixFile], plugin), plugin, index).length);
	}

}
