package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferMapType;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-map-type` check: a concrete `haxe.ds` map type (`IntMap` / `StringMap` /
 * `ObjectMap` / `EnumValueMap`) rewritten to the unified `Map<K, V>` syntax. Covers every
 * annotation position (field / local / parameter / return / nested type argument), the `new`
 * arm with and without an annotation pinning the target, the fully-qualified and wildcard
 * name proofs, and each refusal: a shadowed concrete name, a shadowed `Map`, the heritage /
 * `is` / `cast` / `catch` / type-parameter-constraint positions, a conditional region, and
 * `WeakMap`.
 */
class PreferMapTypeCheckTest extends Test {

	// --- report-only: the site is a haxe.ds map, the rewrite is not available ---

	public inline function testImportedForeignMapIsReportOnly(): Void {
		assertReportOnly('import haxe.ds.IntMap;\nimport foo.Map;\nclass C { var m:IntMap<Int>; }');
	}

	public inline function testLocallyDeclaredMapIsReportOnly(): Void {
		assertReportOnly('import haxe.ds.IntMap;\nclass Map {}\nclass C { var m:IntMap<Int>; }');
	}

	/**
	 * The pin's nominal is RESOLVED, not name-matched: a module declaring its own `IntMap` means the
	 * annotation is not a `haxe.ds` map at all, so the self-proving qualified construction beside it
	 * has nothing that determines `Map`'s parameters.
	 */
	public inline function testPinNominalIsResolvedNotNameMatched(): Void {
		assertReportOnly('class IntMap<T> {}\nclass C { var m:IntMap<Int> = new haxe.ds.IntMap(); }');
	}

	/** A module-declared abstract over `String` follows to the `K:String` selector — the key is not proven. */
	public inline function testModuleDeclaredAbstractOverStringKeyIsReportOnly(): Void {
		assertReportOnly(
			'import haxe.ds.ObjectMap;\nabstract LocalKey(String) from String to String {}\nclass C { var m:ObjectMap<LocalKey, Int>; }'
		);
	}

	public inline function testModuleDeclaredTypedefAliasOfStringKeyIsReportOnly(): Void {
		assertReportOnly('import haxe.ds.ObjectMap;\ntypedef LocalKey = String;\nclass C { var m:ObjectMap<LocalKey, Int>; }');
	}

	/** The chain is followed transitively within the file. */
	public inline function testTransitiveModuleAliasToStringKeyIsReportOnly(): Void {
		assertReportOnly(
			'import haxe.ds.ObjectMap;\nabstract Inner(String) {}\ntypedef LocalKey = Inner;\nclass C { var m:ObjectMap<LocalKey, Int>; }'
		);
	}

	/** A `using` binds the same simple name an `import` would — a foreign `Map` shadows just as hard. */
	public inline function testUsingBoundForeignMapIsReportOnly(): Void {
		assertReportOnly('import haxe.ds.IntMap;\nusing foo.Map;\nclass C { var m:IntMap<Int>; }');
	}

	// --- annotation positions ---

	public function testFieldIntMapRewritten(): Void {
		Assert.equals(imp('IntMap', 'class C { var m:Map<Int, Int>; }'), fixed(imp('IntMap', 'class C { var m:IntMap<Int>; }')));
	}

	public function testLocalStringMapRewritten(): Void {
		Assert.equals(
			imp('StringMap', 'class C { function f():Void { var m:Map<String, Int>; } }'),
			fixed(imp('StringMap', 'class C { function f():Void { var m:StringMap<Int>; } }'))
		);
	}

	public function testParameterRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'class C { function f(m:Map<Int, Int>):Void {} }'),
			fixed(imp('IntMap', 'class C { function f(m:IntMap<Int>):Void {} }'))
		);
	}

	public function testReturnTypeRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'class C { function f():Map<Int, Int> { return null; } }'),
			fixed(imp('IntMap', 'class C { function f():IntMap<Int> { return null; } }'))
		);
	}

	/** `ObjectMap` already writes its key as the first type parameter — only the name changes. */
	public function testObjectMapKeepsItsWrittenKey(): Void {
		Assert.equals(
			'import haxe.ds.ObjectMap;\nimport pkg.Foo;\nclass C { var m:Map<Foo, Int>; }',
			fixed('import haxe.ds.ObjectMap;\nimport pkg.Foo;\nclass C { var m:ObjectMap<Foo, Int>; }')
		);
	}

	/** A key the MODULE declares is proven without an import. */
	public function testObjectMapKeyDeclaredInModuleRewritten(): Void {
		Assert.equals(
			'import haxe.ds.ObjectMap;\nclass Key {}\nclass C { var m:Map<Key, Int>; }',
			fixed('import haxe.ds.ObjectMap;\nclass Key {}\nclass C { var m:ObjectMap<Key, Int>; }')
		);
	}

	/** A fully-qualified key proves itself. */
	public function testObjectMapWithQualifiedKeyRewritten(): Void {
		Assert.equals(
			'import haxe.ds.ObjectMap;\nclass C { var m:Map<pkg.Key, Int>; }',
			fixed('import haxe.ds.ObjectMap;\nclass C { var m:ObjectMap<pkg.Key, Int>; }')
		);
	}

	/**
	 * A type-PARAMETER key satisfies `K:{}` at the declaration site exactly as a class does, so the
	 * rewrite typechecks — but a monomorphised `Holder<String>` then selects a StringMap where the
	 * source named an object map. No oracle sees it; only the key proof does.
	 */
	public function testClassTypeParameterKeyIsReportOnly(): Void {
		assertReportOnly(imp('ObjectMap', 'class C<K> { var m:ObjectMap<K, Int>; }'));
	}

	public function testFunctionTypeParameterKeyIsReportOnly(): Void {
		assertReportOnly(imp('ObjectMap', 'class C { function g<T>(x:ObjectMap<T, Int>):Void {} }'));
	}

	/** An unimported, undeclared, unqualified key is not proven either — the same positive test. */
	public function testUnknownObjectMapKeyIsReportOnly(): Void {
		assertReportOnly(imp('ObjectMap', 'class C { var m:ObjectMap<Foo, Int>; }'));
	}

	/** The `EnumValueMap` arm — `Map` has a `@:to` for it but no `@:from`, so the edit rides on the `RiskyFix` oracle. */
	public function testEnumValueMapKeepsItsWrittenKey(): Void {
		Assert.equals(
			'import haxe.ds.EnumValueMap;\nimport pkg.E;\nclass C { var m:Map<E, Int>; }',
			fixed('import haxe.ds.EnumValueMap;\nimport pkg.E;\nclass C { var m:EnumValueMap<E, Int>; }')
		);
	}

	public function testNestedTypeArgumentRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'class C { var m:Array<Map<Int, Int>>; }'), fixed(imp('IntMap', 'class C { var m:Array<IntMap<Int>>; }'))
		);
	}

	/**
	 * A concrete map inside an anonymous structure inside a type argument. The check reads the
	 * type-refs projection, which dropped the whole struct — so the rewrite could not reach the
	 * site at all. The struct's own field NAME is asserted unchanged in the same string.
	 */
	public function testMapInsideAnAnonymousStructureRewritten(): Void {
		Assert.equals(
			imp('StringMap', 'class C { var m:Array<{ m:Map<String, Int> }>; }'),
			fixed(imp('StringMap', 'class C { var m:Array<{ m:StringMap<Int> }>; }'))
		);
	}

	/** Per-site edits compose: the outer head's key insert and the inner head's name replacement never overlap. */
	public function testMapOfMapsRewrittenAtBothLevels(): Void {
		Assert.equals(
			imp('IntMap', 'class C { var m:Map<Int, Map<Int, Int>>; }'), fixed(imp('IntMap', 'class C { var m:IntMap<IntMap<Int>>; }'))
		);
	}

	// --- the `new` arm ---

	public function testNewExprWithTypeArgumentsRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'class C { function f():Void { var m = new Map<Int, String>(); } }'),
			fixed(imp('IntMap', 'class C { function f():Void { var m = new IntMap<String>(); } }'))
		);
	}

	/** A bare `new IntMap()` carries no key type of its own — the annotation on the declaration pins it. */
	public function testBareNewPinnedByAnnotationRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'class C { var m:Map<Int, Int> = new Map(); }'),
			fixed(imp('IntMap', 'class C { var m:IntMap<Int> = new IntMap(); }'))
		);
	}

	/** The motivating real shape: an annotated field plus its typed construction, both rewritten in one pass. */
	public function testAnnotatedFieldWithTypedConstruction(): Void {
		Assert.equals(
			imp('IntMap', 'class C { private var _c:Map<Int, C> = new Map<Int, C>(); }'),
			fixed(imp('IntMap', 'class C { private var _c:IntMap<C> = new IntMap<C>(); }'))
		);
	}

	// --- name proofs ---

	public function testFullyQualifiedReferenceRewritten(): Void {
		Assert.equals('class C { var m:Map<Int, Int>; }', fixed('class C { var m:haxe.ds.IntMap<Int>; }'));
	}

	public function testFullyQualifiedNewRewritten(): Void {
		Assert.equals(
			'class C { function f():Void { var m = new Map<Int, Int>(); } }',
			fixed('class C { function f():Void { var m = new haxe.ds.IntMap<Int>(); } }')
		);
	}

	public function testWildcardImportProvesTheName(): Void {
		Assert.equals('import haxe.ds.*;\nclass C { var m:Map<Int, Int>; }', fixed('import haxe.ds.*;\nclass C { var m:IntMap<Int>; }'));
	}

	public function testImportStatementNeverRewritten(): Void {
		Assert.equals(0, fixed(imp('IntMap', 'class C { var m:IntMap<Int>; }')).indexOf('import haxe.ds.IntMap;'));
	}

	// --- refusals: the reference is not provably a haxe.ds map ---

	public function testLocallyDeclaredNameNotFlagged(): Void {
		Assert.equals(0, violations('import haxe.ds.*;\nclass IntMap {}\nclass C { var m:IntMap<Int>; }').length);
	}

	public function testWithoutAnyHaxeDsProofNotFlagged(): Void {
		Assert.equals(0, violations('class C { var m:IntMap<Int>; }').length);
	}

	public function testForeignImportOfTheSameSimpleNameNotFlagged(): Void {
		Assert.equals(0, violations('import foo.IntMap;\nclass C { var m:IntMap<Int>; }').length);
	}

	/** The wildcard would otherwise prove the name — the alias binding is what refuses it (the grammar does not expose what it aliases FROM). */
	public function testAliasedImportNotFlagged(): Void {
		Assert.equals(0, violations('import haxe.ds.*;\nimport foo.Bar as IntMap;\nclass C { var m:IntMap<Int>; }').length);
	}

	public function testWeakMapUntouched(): Void {
		Assert.equals(0, violations(imp('WeakMap', 'class C { var m:WeakMap<Foo, Int>; }')).length);
	}

	// --- refusals: positions where `Map` cannot stand ---

	public function testHeritageNotFlagged(): Void {
		Assert.equals(0, violations(imp('IntMap', 'class C extends IntMap<Int> {}')).length);
	}

	public function testIsCheckNotFlagged(): Void {
		Assert.equals(0, violations(imp('IntMap', 'class C { function f(x:Dynamic):Void { if (x is IntMap) trace(1); } }')).length);
	}

	public function testTypedCastNotFlagged(): Void {
		Assert.equals(0, violations(imp('IntMap', 'class C { function f(x:Dynamic):Void { var y = cast(x, IntMap); } }')).length);
	}

	public function testCatchTypeNotFlagged(): Void {
		Assert.equals(0, violations(imp('IntMap', 'class C { function f():Void { try {} catch (e:IntMap) {} } }')).length);
	}

	public function testTypeParameterConstraintNotFlagged(): Void {
		Assert.equals(0, violations(imp('IntMap', 'class C<K:IntMap<Int>> { }')).length);
	}

	/** With the return type omitted, a function's type-parameter constraint IS the child before the body — the parameter list between them is what tells them apart. */
	public function testFunctionTypeParameterConstraintNotFlagged(): Void {
		Assert.equals(0, violations(imp('IntMap', 'class C { function f<T:IntMap<Int>>() {} }')).length);
	}

	/** The same shape WITH a return type — the constraint is still out, the return type still in. */
	public function testReturnTypeRewrittenAlongsideAConstraint(): Void {
		Assert.equals(
			imp('IntMap', 'class C { function f<T:IntMap<Int>>():Map<Int, Int> { return null; } }'),
			fixed(imp('IntMap', 'class C { function f<T:IntMap<Int>>():IntMap<Int> { return null; } }'))
		);
	}

	/**
	 * A COMMENT between the return type and the body is not a parameter list, so the annotation is
	 * still a return type — `RefactorSupport.isReturnTypeSlot` skips comments before looking for the
	 * `(` that only a constraint's parameter list leaves in the gap. The constraint sibling still
	 * refuses, but note WHY, since the assertion is a regression guard rather than a discriminator:
	 * its `(` PRECEDES any comment that could follow it, so the scan answers before reaching the
	 * comment arm at all. The skip can only ever flip a return-type slot, never a constraint one.
	 */
	public function testReturnTypeRewrittenPastAComment(): Void {
		Assert.equals(
			imp('IntMap', 'class C { function f():Map<Int, Int> /* (n) */ { return null; } }'),
			fixed(imp('IntMap', 'class C { function f():IntMap<Int> /* (n) */ { return null; } }'))
		);
		Assert.equals(0, violations(imp('IntMap', 'class C { function f<T:IntMap<Int>>() /* (n) */ {} }')).length);
	}

	public function testConditionalRegionNotFlagged(): Void {
		Assert.equals(0, violations(imp('IntMap', 'class C {\n#if js\n\tvar m:IntMap<Int>;\n#end\n}')).length);
	}

	public function testConstructorArgumentsNotFlagged(): Void {
		Assert.equals(0, violations(imp('IntMap', 'class C { function f():Void { var m = new IntMap(3); } }')).length);
	}

	public function testAnnotationWithoutTypeParametersIsReportOnly(): Void {
		assertReportOnly(imp('IntMap', 'class C { var m:IntMap; }'));
	}

	public function testUnpinnedBareNewIsReportOnly(): Void {
		assertReportOnly(imp('IntMap', 'class C { function f():Void { var m = new IntMap(); } }'));
	}

	/**
	 * The real-tree find: `Map<Dynamic, V>` resolves through the `K:String` selector to a StringMap,
	 * so the rewrite would typecheck and then throw on the first object key.
	 */
	public function testObjectMapWithDynamicKeyIsReportOnly(): Void {
		assertReportOnly(imp('ObjectMap', 'class C { var m:ObjectMap<Dynamic, Int>; }'));
	}

	/** `ObjectMap<String, V>` is identity-keyed; `Map<String, V>` is a value-keyed StringMap. */
	public function testObjectMapWithStringKeyIsReportOnly(): Void {
		assertReportOnly(imp('ObjectMap', 'class C { var m:ObjectMap<String, Int>; }'));
	}

	public function testEnumValueMapWithDynamicKeyIsReportOnly(): Void {
		assertReportOnly(imp('EnumValueMap', 'class C { var m:EnumValueMap<Dynamic, Int>; }'));
	}

	/** A non-nominal key (a nested generic here) is not one this rule can judge. */
	public function testObjectMapWithNonNominalKeyIsReportOnly(): Void {
		assertReportOnly(imp('ObjectMap', 'class C { var m:ObjectMap<Array<Foo>, Int>; }'));
	}

	/** The pinning annotation carries the key, so an `ObjectMap` pair rewrites together. */
	public function testBareNewObjectMapPairRewritten(): Void {
		Assert.equals(
			'import haxe.ds.ObjectMap;\nimport pkg.Foo;\nclass C { var m:Map<Foo, Int> = new Map(); }',
			fixed('import haxe.ds.ObjectMap;\nimport pkg.Foo;\nclass C { var m:ObjectMap<Foo, Int> = new ObjectMap(); }')
		);
	}

	/**
	 * The `EnumValueMap` twin: `Map` has NO `@:from EnumValueMap`, so rewriting the annotation while
	 * leaving the construction would not compile — the pair moves together or not at all.
	 */
	public function testBareNewEnumValueMapPairRewritten(): Void {
		Assert.equals(
			'import haxe.ds.EnumValueMap;\nenum Col { A; }\nclass C { var m:Map<Col, Int> = new Map(); }',
			fixed('import haxe.ds.EnumValueMap;\nenum Col { A; }\nclass C { var m:EnumValueMap<Col, Int> = new EnumValueMap(); }')
		);
	}

	/** The other direction: an unproven key leaves BOTH halves of the pair alone. */
	public function testBareNewPairWithUnprovenKeyIsReportOnly(): Void {
		final src: String = imp('ObjectMap', 'class C { var m:ObjectMap<Dynamic, Int> = new ObjectMap(); }');
		Assert.equals(2, violations(src).length);
		Assert.equals(src, fixed(src));
	}

	/** `new Map()` needs an annotation that DETERMINES K and V — a `Dynamic` target determines neither. */
	public function testBareNewPinnedByDynamicIsReportOnly(): Void {
		final src: String = imp('IntMap', 'class C { function f():Void { var d:Dynamic = new IntMap(); } }');
		Assert.equals(1, violations(src).length);
		Assert.equals(src, fixed(src));
	}

	/** An interface-typed target does not determine the multi-type either. */
	public function testBareNewPinnedByInterfaceIsReportOnly(): Void {
		final src: String = imp('IntMap', 'class C { function f():Void { var a:IMap<Int, String> = new IntMap(); } }');
		Assert.equals(1, violations(src).length);
		Assert.equals(src, fixed(src));
	}

	/**
	 * The constructed name is found by TOKENISING past comments, not by a neighbour check on a raw
	 * substring: this comment supplies whitespace before and a `(` after, so a guard that only looks
	 * at the characters around the match edits the COMMENT, leaves the construction, and still
	 * compiles through `@:from` — invisible to any oracle.
	 */
	public function testCommentMimickingACallTokenIsNotRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'class C { var m:Map<Int, Int> = new /* see IntMap() below */ Map(); }'),
			fixed(imp('IntMap', 'class C { var m:IntMap<Int> = new /* see IntMap() below */ IntMap(); }'))
		);
	}

	/** The generic twin — a comment supplying a `<` after the match would draw BOTH edits into it. */
	public function testCommentMimickingAGenericTokenIsNotRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'class C { var m:Map<Int, Int> = new /* IntMap<Int> */ Map(); }'),
			fixed(imp('IntMap', 'class C { var m:IntMap<Int> = new /* IntMap<Int> */ IntMap(); }'))
		);
	}

	/** A line comment inside the construction is skipped by the same cursor. */
	public function testLineCommentMimickingATokenIsNotRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'class C {\n\tvar m:Map<Int, Int> = new // IntMap(\n\t\tMap();\n}'),
			fixed(imp('IntMap', 'class C {\n\tvar m:IntMap<Int> = new // IntMap(\n\t\tIntMap();\n}'))
		);
	}

	/**
	 * The real-corpus shape of the same thing — a module-local alias OF the type it shadows, which is
	 * also a self-referential alias chain. The alias TARGET is qualified, so it proves itself and is
	 * rewritten; the construction beside it is not, because the annotation pinning it resolves to the
	 * module's own `IntMap`, not to `haxe.ds.IntMap`.
	 */
	public function testModuleAliasOfTheShadowedTypeLeavesTheConstructionAlone(): Void {
		final src: String = 'typedef IntMap<T> = haxe.ds.IntMap<T>;\nclass C { var m:IntMap<Int> = new haxe.ds.IntMap(); }';
		Assert.equals(2, violations(src).length);
		Assert.equals('typedef IntMap<T> = Map<Int, T>;\nclass C { var m:IntMap<Int> = new haxe.ds.IntMap(); }', fixed(src));
	}

	/** A pin already spelling the unified type determines the multi-type on its own — no key proof needed. */
	public function testBareNewPinnedByUnifiedMapRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'class C { var m:Map<Int, Int> = new Map(); }'),
			fixed(imp('IntMap', 'class C { var m:Map<Int, Int> = new IntMap(); }'))
		);
	}

	/** ...but only while it determines the SAME implementation the construction names. */
	public function testUnifiedPinNamingAnotherImplementationIsReportOnly(): Void {
		assertReportOnly(imp('IntMap', 'class C { var m:Map<Dynamic, Int> = new IntMap(); }'));
	}

	/** A module-declared abstract over a plain class still routes to `K:{}` — proven, and still rewritten. */
	public function testModuleDeclaredAbstractOverClassKeyRewritten(): Void {
		Assert.equals(
			'import haxe.ds.ObjectMap;\nclass Inner {}\nabstract LocalKey(Inner) {}\nclass C { var m:Map<LocalKey, Int>; }',
			fixed('import haxe.ds.ObjectMap;\nclass Inner {}\nabstract LocalKey(Inner) {}\nclass C { var m:ObjectMap<LocalKey, Int>; }')
		);
	}

	/** `import haxe.ds.Map;` is the unified type itself — it leaves `Map` free. */
	public function testImportingHaxeDsMapKeepsItFree(): Void {
		Assert.equals(
			'import haxe.ds.IntMap;\nimport haxe.ds.Map;\nclass C { var m:Map<Int, Int>; }',
			fixed('import haxe.ds.IntMap;\nimport haxe.ds.Map;\nclass C { var m:IntMap<Int>; }')
		);
	}

	// --- further host positions ---

	public function testTypedefAliasRewritten(): Void {
		Assert.equals(imp('IntMap', 'typedef TD = Map<Int, Int>;'), fixed(imp('IntMap', 'typedef TD = IntMap<Int>;')));
	}

	public function testEnumConstructorParameterRewritten(): Void {
		Assert.equals(imp('IntMap', 'enum E { A(m:Map<Int, Int>); }'), fixed(imp('IntMap', 'enum E { A(m:IntMap<Int>); }')));
	}

	/** The inline anonymous structure — its fields project as parameter hosts. */
	public function testInlineAnonStructureFieldRewritten(): Void {
		Assert.equals(imp('IntMap', 'class C { var r:{f:Map<Int, Int>}; }'), fixed(imp('IntMap', 'class C { var r:{f:IntMap<Int>}; }')));
	}

	/** The full `{ var f:T; }` structure form — its fields project through the grammar's name/type pair. */
	public function testAnonStructureVarFieldRewritten(): Void {
		Assert.equals(imp('IntMap', 'typedef TD = { var f:Map<Int, Int>; }'), fixed(imp('IntMap', 'typedef TD = { var f:IntMap<Int>; }')));
	}

	/** A bodyless (interface / structure) function still has its return type in the child-before-the-body slot. */
	public function testNoBodyReturnTypeRewritten(): Void {
		Assert.equals(
			imp('IntMap', 'interface I { function m():Map<Int, Int>; }'), fixed(imp('IntMap', 'interface I { function m():IntMap<Int>; }'))
		);
	}

	public function testConditionalElseBranchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				imp('IntMap', 'class C {\n#if js\n\tvar a:Int;\n#elseif cpp\n\tvar m:IntMap<Int>;\n#else\n\tvar n:IntMap<Int>;\n#end\n}')
			).length
		);
	}

	/** `run` is a multi-file seam: each file resolves its own header, and findings carry their own path. */
	public function testMultipleFilesResolveIndependently(): Void {
		final vs: Array<Violation> = new PreferMapType().run([
			{ file: 'A.hx', source: imp('IntMap', 'class A { var m:IntMap<Int>; }') },
			{ file: 'B.hx', source: 'class B { var m:IntMap<Int>; }' }
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	// --- framework ---

	public function testSeverityAndRuleId(): Void {
		final vs: Array<Violation> = violations(imp('IntMap', 'class C { var m:IntMap<Int>; }'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-map-type', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testViolationSpanCoversTheWholeGenericRegion(): Void {
		final src: String = imp('IntMap', 'class C { var m:IntMap<Int>; }');
		final vs: Array<Violation> = violations(src);
		Assert.equals('IntMap<Int>', src.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-map-type'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-map-type'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function imp(type: String, body: String): String {
		return 'import haxe.ds.$type;\n$body';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferMapType().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** `src` with every edit the check offers applied — the check is a `RiskyFix`, so `fix` is called directly. */
	private function fixed(src: String): String {
		final check: PreferMapType = new PreferMapType();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return applyEdits(src, check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin));
	}

	/** Assert `src` is reported (one finding) yet gate-refused (no fix edit). */
	private function assertReportOnly(src: String): Void {
		Assert.equals(1, violations(src).length);
		Assert.equals(src, fixed(src));
	}

	private static inline function applyEdits(src: String, edits: Array<{ span: Span, text: String }>): String {
		return CheckFixture.applyEdits(src, edits);
	}

}
